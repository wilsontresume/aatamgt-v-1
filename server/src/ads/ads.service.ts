import {
  BadRequestException,
  ConflictException,
  GoneException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { randomBytes } from 'node:crypto';
import { AdSession, WalletTransaction } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { WalletService } from '../wallet/wallet.service';
import { NotificationsService } from '../notifications/notifications.service';
import { AdVerifierRegistry } from './ad-verifier';
import { AppConfig } from '../config/configuration';
import { SystemConfigService } from '../config/system-config.service';

export const AD_TIERS = ['BONUS', 'STANDARD'] as const;
export type AdTier = (typeof AD_TIERS)[number];
export const INTERSTITIAL_KIND = 'INTERSTITIAL';

export type InterstitialReason =
  | 'ROYAL_PASS'
  | 'IN_PROGRESS'
  | 'WINS'
  | 'LOSSES'
  | 'COOLDOWN'
  | 'NOT_YET';

export interface InterstitialConfig {
  afterWins: number;
  afterLosses: number;
  cooldownMatches: number;
}

export interface InterstitialState {
  royalPassActive: boolean;
  inProgress: boolean;
  winsSinceLastShow: number;
  consecutiveLosses: number;
  matchesSinceLastShow: number;
}

export interface InterstitialEvaluation extends InterstitialState {
  eligible: boolean;
  reason: InterstitialReason;
  config: InterstitialConfig;
}

/**
 * Pure decision function for the interstitial frequency rules — kept
 * side-effect free so every rule is unit-testable without a database.
 * The config comes from the server (ADS_INTERSTITIAL_*), never the client.
 */
export function evaluateInterstitial(
  state: InterstitialState,
  config: InterstitialConfig,
): { eligible: boolean; reason: InterstitialReason } {
  if (state.royalPassActive) return { eligible: false, reason: 'ROYAL_PASS' };
  if (state.inProgress) return { eligible: false, reason: 'IN_PROGRESS' };
  const winTrigger = state.winsSinceLastShow >= config.afterWins;
  const lossTrigger = state.consecutiveLosses >= config.afterLosses;
  if (!winTrigger && !lossTrigger) return { eligible: false, reason: 'NOT_YET' };
  if (state.matchesSinceLastShow < config.cooldownMatches) {
    return { eligible: false, reason: 'COOLDOWN' };
  }
  return { eligible: true, reason: winTrigger ? 'WINS' : 'LOSSES' };
}

const RECENT_MATCH_SCAN = 20;
const REPLAY_POLL_ATTEMPTS = 6;
const REPLAY_POLL_MS = 100;

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

@Injectable()
export class AdsService {
  private readonly ads: AppConfig['ads'];

  constructor(
    private readonly prisma: PrismaService,
    private readonly wallet: WalletService,
    private readonly notifications: NotificationsService,
    private readonly verifiers: AdVerifierRegistry,
    private readonly systemConfig: SystemConfigService,
    config: ConfigService,
  ) {
    const cfg = config.get<AppConfig>('app') as AppConfig;
    this.ads = cfg.ads;
  }

  /** Public ad configuration: providers and unit IDs come from the
   *  server env — the client hardcodes nothing. Reward tiers and
   *  interstitial thresholds are the live admin-configured values. */
  async configView() {
    return {
      provider: this.ads.provider,
      rewardedUnitId: this.ads.rewardedUnitId,
      interstitialUnitId: this.ads.interstitialUnitId,
      sessionTtlSeconds: this.ads.sessionTtlSeconds,
      rewardedTiers: {
        BONUS: await this.systemConfig.number('ads.rewarded_bonus'),
        STANDARD: await this.systemConfig.number('ads.rewarded_standard'),
      },
      interstitial: {
        afterWins: await this.systemConfig.number('ads.interstitial_after_wins'),
        afterLosses: await this.systemConfig.number('ads.interstitial_after_losses'),
        cooldownMatches: await this.systemConfig.number('ads.interstitial_cooldown_matches'),
      },
    };
  }

  // --- Rewarded ads -----------------------------------------------------

  /**
   * Step 1 of the rewarded flow: the BACKEND mints the opportunity.
   * Without one of these sessions a client callback can never redeem.
   */
  async createRewardedSession(userId: string, tier: string): Promise<AdSession> {
    if (!AD_TIERS.includes(tier as AdTier)) {
      throw new BadRequestException('Unknown ad tier — expected BONUS or STANDARD');
    }
    const expiresAt = new Date(Date.now() + this.ads.sessionTtlSeconds * 1000);
    return this.prisma.adSession.create({
      data: {
        userId,
        provider: this.ads.provider,
        tier,
        nonce: randomBytes(24).toString('base64url'),
        expiresAt,
      },
    });
  }

  /**
   * Step 3+ of the rewarded flow: validates the reward (provider
   * verifier + server-side session state), then issues coins through
   * the idempotent wallet ledger. A fabricated nonce, an expired or
   * already-redeemed session, or a failed verification never pays.
   */
  async redeemRewarded(
    userId: string,
    nonce: string,
    payload?: Record<string, unknown>,
  ): Promise<{
    tier: string;
    coins: number;
    balance: number;
    transactionId: string;
    replayed: boolean;
  }> {
    if (typeof nonce !== 'string' || nonce.length === 0) {
      throw new BadRequestException('nonce is required');
    }
    const session = await this.prisma.adSession.findUnique({ where: { nonce } });
    // Missing and foreign sessions fail identically: no existence oracle.
    if (!session || session.userId !== userId) {
      throw new NotFoundException('Unknown ad session');
    }
    if (session.expiresAt.getTime() < Date.now()) {
      throw new GoneException('Ad session expired');
    }

    // Provider verification runs BEFORE the session is consumed so a
    // transient verifier failure can be retried on the same session.
    await this.verifiers.get(session.provider).verify({
      provider: session.provider,
      tier: session.tier,
      sessionId: session.id,
      userId,
      payload,
    });

    const claimed = await this.prisma.adSession.updateMany({
      where: { id: session.id, status: 'OPEN' },
      data: { status: 'REDEEMED', redeemedAt: new Date() },
    });
    if (claimed.count === 0) {
      return this.redeemReplay(session);
    }

    const coins = await this.tierCoins(session.tier);
    const result = await this.wallet.credit(userId, coins, {
      type: 'REWARDED_AD',
      refType: 'rewarded_ad',
      refId: session.tier,
      idempotencyKey: `ad:${session.id}`,
      memo: `Rewarded ad (${session.tier.toLowerCase()}, ${session.provider})`,
    });

    await this.notifications.notify({
      userId,
      type: 'rewarded_ad',
      title: 'Rewarded ad bonus',
      body: `You received ${coins} coins for watching an ad.`,
      data: { coins, tier: session.tier, transactionId: result.transaction.id },
    });

    return {
      tier: session.tier,
      coins: result.transaction.amount,
      balance: result.wallet.balance,
      transactionId: result.transaction.id,
      replayed: false,
    };
  }

  /** Lost race / retried redeem: surface the original credit, mint nothing. */
  private async redeemReplay(session: AdSession) {
    const key = `ad:${session.id}`;
    for (let attempt = 0; attempt < REPLAY_POLL_ATTEMPTS; attempt++) {
      const existing = await this.findCreditByKey(key);
      if (existing) {
        return {
          tier: session.tier,
          coins: existing.amount,
          balance: existing.wallet.balance,
          transactionId: existing.id,
          replayed: true,
        };
      }
      await sleep(REPLAY_POLL_MS);
    }
    throw new ConflictException('Reward is being processed');
  }

  private async findCreditByKey(
    key: string,
  ): Promise<(WalletTransaction & { wallet: { balance: number } }) | null> {
    return this.prisma.walletTransaction.findUnique({
      where: { idempotencyKey: key },
      include: { wallet: { select: { balance: true } } },
    });
  }

  private async tierCoins(tier: string): Promise<number> {
    const key = tier === 'BONUS' ? 'ads.rewarded_bonus' : 'ads.rewarded_standard';
    return this.systemConfig.number(key);
  }

  // --- Interstitial ads -------------------------------------------------

  async interstitialEligibility(userId: string): Promise<InterstitialEvaluation> {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      select: { royalPassExpiresAt: true },
    });
    const royalPassActive =
      user?.royalPassExpiresAt != null && user.royalPassExpiresAt.getTime() > Date.now();

    const inProgress =
      (await this.prisma.gameMatch.findFirst({
        where: { status: { in: ['ACTIVE', 'PAUSED'] }, players: { some: { userId } } },
        select: { id: true },
      })) !== null;

    const lastShow = await this.prisma.adShow.findFirst({
      where: { userId, kind: INTERSTITIAL_KIND },
      orderBy: { shownAt: 'desc' },
      select: { shownAt: true },
    });
    const since = lastShow?.shownAt ?? null;

    const [winsSinceLastShow, matchesSinceLastShow, recent] = await Promise.all([
      this.prisma.gameMatch.count({
        where: {
          status: 'COMPLETED',
          completedAt: since ? { gt: since } : undefined,
          players: { some: { userId, result: 'WIN' } },
        },
      }),
      this.prisma.gameMatch.count({
        where: {
          status: 'COMPLETED',
          completedAt: since ? { gt: since } : undefined,
          players: { some: { userId } },
        },
      }),
      this.prisma.gameMatch.findMany({
        where: { status: 'COMPLETED', players: { some: { userId } } },
        orderBy: { completedAt: 'desc' },
        take: RECENT_MATCH_SCAN,
        select: {
          completedAt: true,
          players: { where: { userId }, select: { result: true } },
        },
      }),
    ]);

    let consecutiveLosses = 0;
    for (const match of recent) {
      if (match.players[0]?.result === 'LOSS') consecutiveLosses += 1;
      else break;
    }

    const config: InterstitialConfig = {
      afterWins: await this.systemConfig.number('ads.interstitial_after_wins'),
      afterLosses: await this.systemConfig.number('ads.interstitial_after_losses'),
      cooldownMatches: await this.systemConfig.number('ads.interstitial_cooldown_matches'),
    };
    const state: InterstitialState = {
      royalPassActive: Boolean(royalPassActive),
      inProgress,
      winsSinceLastShow,
      consecutiveLosses,
      matchesSinceLastShow,
    };
    const verdict = evaluateInterstitial(state, config);
    return { ...state, ...verdict, config };
  }

  /**
   * The client reports a completed presentation; this record drives the
   * cooldown so interstitials never appear after every match.
   */
  async recordInterstitialShow(userId: string, matchId?: string): Promise<{ shownAt: string }> {
    let storedMatchId: string | null = null;
    if (typeof matchId === 'string' && matchId.length > 0) {
      const match = await this.prisma.gameMatch.findFirst({
        where: { id: matchId, players: { some: { userId } } },
        select: { id: true },
      });
      if (!match) throw new BadRequestException('Unknown match');
      storedMatchId = match.id;
    }
    const show = await this.prisma.adShow.create({
      data: { userId, kind: INTERSTITIAL_KIND, matchId: storedMatchId },
    });
    return { shownAt: show.shownAt.toISOString() };
  }
}

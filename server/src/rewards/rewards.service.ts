import { BadRequestException, ConflictException, Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PrismaService } from '../prisma/prisma.service';
import { WalletService } from '../wallet/wallet.service';
import { NotificationsService } from '../notifications/notifications.service';
import { AppConfig } from '../config/configuration';
import { Prisma } from '@prisma/client';

/** Ad tiers recognised by POST /rewards/ad (Phase 7 — no ad SDK yet). */
export const AD_TIERS = ['BONUS', 'STANDARD'] as const;
export type AdTier = (typeof AD_TIERS)[number];

const AD_KEY_PATTERN = /^[A-Za-z0-9_-]{8,64}$/;

function utcToday(): Date {
  const now = new Date();
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
}

function previousDay(date: Date): Date {
  return new Date(date.getTime() - 24 * 60 * 60 * 1000);
}

@Injectable()
export class RewardsService {
  private readonly coins: AppConfig['coins'];

  constructor(
    private readonly prisma: PrismaService,
    private readonly wallet: WalletService,
    private readonly notifications: NotificationsService,
    config: ConfigService,
  ) {
    this.coins = (config.get<AppConfig>('app') as AppConfig).coins;
  }

  async status(userId: string) {
    const today = utcToday();
    const claimedToday = await this.prisma.dailyReward.findUnique({
      where: { userId_rewardDate: { userId, rewardDate: today } },
    });
    const last = await this.prisma.dailyReward.findFirst({
      where: { userId, rewardDate: { lt: today } },
      orderBy: { rewardDate: 'desc' },
    });
    const yesterdayStreak =
      last && last.rewardDate.getTime() === previousDay(today).getTime() ? last.streakDay : 0;
    const nextStreak = claimedToday ? claimedToday.streakDay : yesterdayStreak + 1;

    return {
      todayClaimed: Boolean(claimedToday),
      currentStreak: claimedToday ? claimedToday.streakDay : yesterdayStreak,
      nextRewardCoins: this.coins.dailyLoginBonus,
      nextStreakDay: nextStreak,
    };
  }

  /**
   * Daily login grant: one claim per UTC day, amount comes from server
   * config (COINS_DAILY_LOGIN_BONUS, default 100). Duplicate claims are
   * rejected by the unique (userId, rewardDate) constraint and the credit
   * itself is idempotent, so a retry can never double-pay.
   */
  async claim(userId: string) {
    const today = utcToday();
    const existing = await this.prisma.dailyReward.findUnique({
      where: { userId_rewardDate: { userId, rewardDate: today } },
    });
    if (existing) throw new ConflictException('Daily reward already claimed today');

    const last = await this.prisma.dailyReward.findFirst({
      where: { userId, rewardDate: { lt: today } },
      orderBy: { rewardDate: 'desc' },
    });
    const streakDay =
      last && last.rewardDate.getTime() === previousDay(today).getTime() ? last.streakDay + 1 : 1;
    const coins = this.coins.dailyLoginBonus;
    const dateKey = today.toISOString().slice(0, 10);

    const result = await this.wallet.credit(userId, coins, {
      type: 'DAILY_LOGIN',
      refType: 'daily_login',
      refId: `${userId}:${dateKey}`,
      idempotencyKey: `daily:${userId}:${dateKey}`,
      memo: `Daily login bonus (day ${streakDay})`,
    });

    let row;
    try {
      row = await this.prisma.dailyReward.create({
        data: { userId, rewardDate: today, streakDay, rewardCoins: coins },
      });
    } catch (error) {
      if (error instanceof Prisma.PrismaClientKnownRequestError && error.code === 'P2002') {
        throw new ConflictException('Daily reward already claimed today');
      }
      throw error;
    }

    await this.notifications.notify({
      userId,
      type: 'daily_reward',
      title: 'Daily reward claimed',
      body: `You received ${coins} coins (day ${streakDay}).`,
      data: { coins, streakDay, transactionId: result.transaction.id },
    });

    return {
      claimedAt: row.claimedAt.toISOString(),
      coins,
      streakDay,
      balance: result.wallet.balance,
    };
  }

  /**
   * Rewarded-ad grant (Phase 7 stub — no ad SDK yet). The client presents
   * a per-view idempotency key; the server maps the tier to a configured
   * amount and credits the wallet. Replaying the same key returns the
   * original transaction without paying twice. When an ad SDK lands, the
   * key becomes the SDK's verified callback/reward token.
   */
  async claimRewardedAd(userId: string, tier: string, idempotencyKey: string) {
    if (!AD_TIERS.includes(tier as AdTier)) {
      throw new BadRequestException('Unknown ad tier — expected BONUS or STANDARD');
    }
    if (!AD_KEY_PATTERN.test(idempotencyKey)) {
      throw new BadRequestException('idempotencyKey must be 8-64 characters (A-Z a-z 0-9 _ -)');
    }
    const coins = tier === 'BONUS' ? this.coins.rewardedAdBonus : this.coins.rewardedAdStandard;

    const result = await this.wallet.credit(userId, coins, {
      type: 'REWARDED_AD',
      refType: 'rewarded_ad',
      refId: tier,
      idempotencyKey: `ad:${userId}:${idempotencyKey}`,
      memo: `Rewarded ad (${tier.toLowerCase()})`,
    });

    if (!result.replayed) {
      await this.notifications.notify({
        userId,
        type: 'rewarded_ad',
        title: 'Rewarded ad bonus',
        body: `You received ${coins} coins for watching an ad.`,
        data: { coins, tier, transactionId: result.transaction.id },
      });
    }

    return {
      tier,
      coins: result.transaction.amount,
      balance: result.wallet.balance,
      transactionId: result.transaction.id,
      replayed: result.replayed,
    };
  }
}

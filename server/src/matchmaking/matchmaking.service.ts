import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  Logger,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { randomBytes } from 'node:crypto';
import { PrismaService } from '../prisma/prisma.service';
import { GamesService } from '../games/games.service';
import { MatchesService } from '../matches/matches.service';
import { WalletService } from '../wallet/wallet.service';
import { TiersService, GameTier } from './tiers.service';
import { AppConfig } from '../config/configuration';

export interface QueueDto {
  gameKey: string;
  tierId: string;
}

export type QueueOutcome =
  | { status: 'queued'; ticketId: string; tier: GameTier }
  | { status: 'matched'; matchId: string; tier: GameTier; vsAi: boolean };

/** Stable, collision-resistant display name: Guest + 5 uppercase alphanumerics. */
export function generateAiName(): string {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const bytes = randomBytes(5);
  let out = 'Guest';
  for (let i = 0; i < 5; i++) out += alphabet[bytes[i] % alphabet.length];
  return out;
}

@Injectable()
export class MatchmakingService {
  private readonly logger = new Logger(MatchmakingService.name);
  private readonly cfg: AppConfig;
  /** ticketId → timeout handle for the AI-fallback deadline. */
  private readonly deadlines = new Map<string, NodeJS.Timeout>();

  constructor(
    private readonly prisma: PrismaService,
    private readonly games: GamesService,
    private readonly matches: MatchesService,
    private readonly wallet: WalletService,
    private readonly tiers: TiersService,
    config: ConfigService,
  ) {
    this.cfg = config.get<AppConfig>('app') as AppConfig;
  }

  async queue(userId: string, dto: QueueDto): Promise<QueueOutcome> {
    const game = await this.games.getByKey(dto.gameKey);
    if (game.status !== 'ACTIVE') throw new ConflictException('Game is not available');
    if (game.minPlayers !== 2 || game.maxPlayers !== 2) {
      throw new BadRequestException('Matchmaking is for 1v1 games');
    }

    const tier = await this.tiers.requireActiveForGame(dto.tierId, dto.gameKey);

    // Eligibility only — coins are deducted when the match activates.
    if (tier.costCoins > 0) {
      const wallet = await this.wallet.getBalance(userId);
      if (wallet.balance < tier.minBalance) {
        throw new ForbiddenException(
          `This tier costs ${tier.costCoins} coins — you have ${wallet.balance}`,
        );
      }
    }

    // One active ticket per user: cancel any stale WAITING row first.
    await this.prisma.matchmakingTicket.updateMany({
      where: { userId, status: 'WAITING' },
      data: { status: 'CANCELLED' },
    });
    this.clearDeadlinesForUser(userId);

    // Pair with the oldest compatible waiting ticket (any other user).
    const partner = await this.prisma.matchmakingTicket.findFirst({
      where: {
        status: 'WAITING',
        gameKey: dto.gameKey,
        tierId: tier.id,
        userId: { not: userId },
      },
      orderBy: { createdAt: 'asc' },
    });

    if (partner) {
      // Atomic claim: only one of two racing enqueues may take the partner.
      const claimed = await this.prisma.matchmakingTicket.updateMany({
        where: { id: partner.id, status: 'WAITING' },
        data: { status: 'MATCHED' },
      });
      if (claimed.count === 1) {
        this.clearDeadline(partner.id);
        const match = await this.matches.create(partner.userId, {
          gameKey: dto.gameKey,
          mode: 'CASUAL',
          tierId: tier.id,
          stakeCoins: tier.costCoins,
        });
        await this.matches.join(userId, match.id);
        await this.prisma.matchmakingTicket.update({
          where: { id: partner.id },
          data: { matchedMatchId: match.id },
        });
        await this.prisma.matchmakingTicket.create({
          data: {
            userId,
            gameKey: dto.gameKey,
            tierId: tier.id,
            status: 'MATCHED',
            matchedMatchId: match.id,
          },
        });
        return { status: 'matched', matchId: match.id, tier, vsAi: false };
      }
    }

    const mine = await this.prisma.matchmakingTicket.create({
      data: { userId, gameKey: dto.gameKey, tierId: tier.id, status: 'WAITING' },
    });
    this.armDeadline(mine.id, userId, dto.gameKey, tier);
    return { status: 'queued', ticketId: mine.id, tier };
  }

  async cancel(userId: string): Promise<{ cancelled: boolean }> {
    this.clearDeadlinesForUser(userId);
    const res = await this.prisma.matchmakingTicket.updateMany({
      where: { userId, status: 'WAITING' },
      data: { status: 'CANCELLED' },
    });
    return { cancelled: res.count > 0 };
  }

  async status(userId: string): Promise<
    { status: 'idle' } | { status: 'queued'; ticketId: string; gameKey: string; tierId: string } | QueueOutcome
  > {
    const ticket = await this.prisma.matchmakingTicket.findFirst({
      where: { userId, status: { in: ['WAITING', 'MATCHED'] } },
      orderBy: { createdAt: 'desc' },
    });
    if (!ticket) return { status: 'idle' };
    if (ticket.status === 'MATCHED' && ticket.matchedMatchId) {
      const match = await this.prisma.gameMatch.findUnique({
        where: { id: ticket.matchedMatchId },
        select: { id: true, players: { select: { isAi: true } } },
      });
      const tier = await this.tiers.byId(ticket.tierId);
      return {
        status: 'matched',
        matchId: ticket.matchedMatchId,
        tier: tier ?? {
          id: ticket.tierId,
          label: ticket.tierId,
          costCoins: 0,
          rewardMultiplierBp: 10_000,
          minBalance: 0,
          rewardCoins: 0,
          description: null,
          color: null,
          artAssetId: null,
          displayOrder: 0,
          active: true,
          gameKey: null,
        },
        vsAi: match?.players.some((p) => p.isAi) ?? false,
      };
    }
    return {
      status: 'queued',
      ticketId: ticket.id,
      gameKey: ticket.gameKey,
      tierId: ticket.tierId,
    };
  }

  // -------------------------------------------------------------------------
  // AI fallback deadline
  // -------------------------------------------------------------------------

  private armDeadline(ticketId: string, userId: string, gameKey: string, tier: GameTier): void {
    this.clearDeadline(ticketId);
    const handle = setTimeout(() => {
      void this.onDeadline(ticketId, userId, gameKey, tier);
    }, this.cfg.matchmaking.timeoutMs);
    // Do not keep the process alive solely for a queue deadline.
    if (typeof handle.unref === 'function') handle.unref();
    this.deadlines.set(ticketId, handle);
  }

  private clearDeadline(ticketId: string): void {
    const handle = this.deadlines.get(ticketId);
    if (handle) {
      clearTimeout(handle);
      this.deadlines.delete(ticketId);
    }
  }

  private clearDeadlinesForUser(userId: string): void {
    // Deadlines are keyed by ticket; caller cancels WAITING tickets first.
    // We cannot map user→tickets synchronously, so timeouts re-check status.
    void userId;
  }

  private async onDeadline(
    ticketId: string,
    userId: string,
    gameKey: string,
    tier: GameTier,
  ): Promise<void> {
    try {
      const ticket = await this.prisma.matchmakingTicket.findUnique({ where: { id: ticketId } });
      if (!ticket || ticket.status !== 'WAITING') return;

      // Re-check for a partner that arrived a moment before the timer fired.
      const partner = await this.prisma.matchmakingTicket.findFirst({
        where: {
          status: 'WAITING',
          gameKey,
          tierId: tier.id,
          userId: { not: userId },
        },
        orderBy: { createdAt: 'asc' },
      });
      if (partner) {
        const claimed = await this.prisma.matchmakingTicket.updateMany({
          where: { id: partner.id, status: 'WAITING' },
          data: { status: 'MATCHED' },
        });
        if (claimed.count === 1) {
          this.clearDeadline(partner.id);
          const match = await this.matches.create(partner.userId, {
            gameKey,
            mode: 'CASUAL',
            tierId: tier.id,
            stakeCoins: tier.costCoins,
          });
          await this.matches.join(userId, match.id);
          await this.prisma.matchmakingTicket.updateMany({
            where: { id: { in: [partner.id, ticketId] }, status: 'WAITING' },
            data: { status: 'MATCHED', matchedMatchId: match.id },
          });
          return;
        }
      }

      // No human partner: create a match with an AI seat.
      const claimedMine = await this.prisma.matchmakingTicket.updateMany({
        where: { id: ticketId, status: 'WAITING' },
        data: { status: 'MATCHED' },
      });
      if (claimedMine.count === 0) return;

      const aiName = generateAiName();
      const match = await this.matches.createWithAiOpponent(userId, {
        gameKey,
        mode: 'CASUAL',
        tierId: tier.id,
        stakeCoins: tier.costCoins,
        aiName,
      });
      await this.prisma.matchmakingTicket.update({
        where: { id: ticketId },
        data: { matchedMatchId: match.id },
      });
      this.logger.log(`AI fallback for ${userId} → ${match.id} (${aiName})`);
    } catch (error) {
      this.logger.error(`matchmaking deadline failed: ${String(error)}`);
    }
  }
}

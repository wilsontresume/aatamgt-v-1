import { Injectable, BadRequestException, NotFoundException } from '@nestjs/common';
import { Prisma, RatingEvent } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  RATED_GAME_KEYS,
  RANK_TIERS,
  START_RATING,
  eloDelta,
  isRatedGame,
  rankForRating,
} from './ranks';

const MAX_LEADERBOARD = 100;
const MAX_HISTORY = 50;

type Tx = Prisma.TransactionClient;
type MatchResult = 'WIN' | 'LOSS' | 'DRAW';

@Injectable()
export class RankingsService {
  constructor(private readonly prisma: PrismaService) {}

  // --- Season ------------------------------------------------------------

  /** The active season, created lazily on first ranking use. */
  async currentSeason(tx: Tx = this.prisma) {
    const existing = await tx.season.findFirst({
      where: { isActive: true },
      orderBy: { startsAt: 'desc' },
    });
    if (existing) return existing;
    const count = await tx.season.count();
    return tx.season.create({
      data: { key: `season-${count + 1}`, name: `Season ${count + 1}` },
    });
  }

  /** Admin rollover: closes the active season and opens the next one. */
  async startNextSeason() {
    const current = await this.currentSeason();
    const count = await this.prisma.season.count();
    const next = await this.prisma.season.create({
      data: { key: `season-${count + 1}`, name: `Season ${count + 1}` },
    });
    await this.prisma.season.update({
      where: { id: current.id },
      data: { isActive: false, endsAt: new Date() },
    });
    return next;
  }

  private async resolveSeason(seasonKey?: string | null) {
    if (!seasonKey) return this.currentSeason();
    const season = await this.prisma.season.findUnique({ where: { key: seasonKey } });
    if (!season) throw new NotFoundException('Season not found');
    return season;
  }

  // --- Ratings -----------------------------------------------------------

  /** Creates the default rating rows for a player in a season (idempotent). */
  private async ensureRatings(tx: Tx, seasonId: string, userId: string) {
    await tx.gameRating.createMany({
      data: RATED_GAME_KEYS.map((gameKey) => ({ seasonId, userId, gameKey })),
      skipDuplicates: true,
    });
    return tx.gameRating.findMany({
      where: { seasonId, userId },
      orderBy: { gameKey: 'asc' },
    });
  }

  /**
   * Applies a completed server-authoritative match to the per-game
   * ratings. MUST be called inside the same transaction that flips the
   * match to COMPLETED. Idempotent per participant: the unique
   * (matchId, userId) key means a duplicated submission cannot move a
   * rating twice. Non-rated games are ignored.
   */
  async applyMatchResult(
    tx: Tx,
    match: { id: string; gameKey: string },
    completion: { winnerSeat: number | null; reason?: string },
    results: Map<string, MatchResult>,
  ): Promise<RatingEvent[]> {
    if (!isRatedGame(match.gameKey)) return [];
    const season = await this.currentSeason(tx);
    const userIds = [...results.keys()];
    const ratings = new Map<string, { id: string; rating: number }>();
    for (const userId of userIds) {
      const rows = await this.ensureRatings(tx, season.id, userId);
      const row = rows.find((r) => r.gameKey === match.gameKey);
      if (row) ratings.set(userId, { id: row.id, rating: row.rating });
    }

    const created: RatingEvent[] = [];
    for (const userId of userIds) {
      const mine = ratings.get(userId);
      if (!mine) continue;
      const opponentId = userIds.find((id) => id !== userId) ?? userId;
      const opponent = ratings.get(opponentId);
      if (!opponent) continue;
      const result = results.get(userId)!;
      const score = result === 'WIN' ? 1 : result === 'LOSS' ? 0 : 0.5;
      const delta = eloDelta(mine.rating, opponent.rating, score);

      const duplicate = await tx.ratingEvent.findUnique({
        where: { matchId_userId: { matchId: match.id, userId } },
      });
      if (duplicate) continue;

      const event = await tx.ratingEvent.create({
        data: {
          seasonId: season.id,
          matchId: match.id,
          userId,
          gameKey: match.gameKey,
          result,
          reason: completion.reason ?? 'UNKNOWN',
          ratingBefore: mine.rating,
          delta,
          ratingAfter: mine.rating + delta,
        },
      });
      await tx.gameRating.update({
        where: { id: mine.id },
        data: {
          rating: { increment: delta },
          gamesPlayed: { increment: 1 },
          ...(result === 'WIN'
            ? { wins: { increment: 1 } }
            : result === 'LOSS'
              ? { losses: { increment: 1 } }
              : { draws: { increment: 1 } }),
        },
      });
      created.push(event);
    }
    return created;
  }

  // --- Read APIs ---------------------------------------------------------

  /** Per-game rating, rank tier, record and leaderboard position for a player. */
  async summary(userId: string) {
    const season = await this.currentSeason();
    const rows = await this.ensureRatings(this.prisma, season.id, userId);
    const games = await Promise.all(
      RATED_GAME_KEYS.map(async (gameKey) => {
        const row = rows.find((r) => r.gameKey === gameKey)!;
        const ahead = await this.prisma.gameRating.count({
          where: { seasonId: season.id, gameKey, rating: { gt: row.rating } },
        });
        const rank = rankForRating(row.rating);
        return {
          gameKey,
          rating: row.rating,
          rank: { key: rank.key, name: rank.name, min: rank.min, index: rank.index },
          wins: row.wins,
          losses: row.losses,
          draws: row.draws,
          gamesPlayed: row.gamesPlayed,
          position: ahead + 1,
        };
      }),
    );
    return {
      season: this.serializeSeason(season),
      games,
    };
  }

  /** Top rated competitors for one game in one season. */
  async leaderboard(gameKey: string, seasonKey?: string | null, limit = 50) {
    if (!isRatedGame(gameKey)) {
      throw new BadRequestException('Unknown rated game');
    }
    const season = await this.resolveSeason(seasonKey);
    const take = Math.min(Math.max(limit, 1), MAX_LEADERBOARD);
    const rows = await this.prisma.gameRating.findMany({
      where: { seasonId: season.id, gameKey, gamesPlayed: { gt: 0 } },
      orderBy: [{ rating: 'desc' }, { updatedAt: 'asc' }],
      take,
      include: { user: { select: { username: true } } },
    });
    return {
      season: this.serializeSeason(season),
      gameKey,
      updatedAt: rows[0]?.updatedAt.toISOString() ?? null,
      items: rows.map((row, index) => {
        const rank = rankForRating(row.rating);
        return {
          position: index + 1,
          userId: row.userId,
          username: row.user.username,
          rating: row.rating,
          wins: row.wins,
          losses: row.losses,
          rank: { key: rank.key, name: rank.name },
        };
      }),
    };
  }

  /** A player's rating movement history, newest first. */
  async history(userId: string, gameKey?: string | null, limit = 20) {
    if (gameKey && !isRatedGame(gameKey)) {
      throw new BadRequestException('Unknown rated game');
    }
    const take = Math.min(Math.max(limit, 1), MAX_HISTORY);
    const events = await this.prisma.ratingEvent.findMany({
      where: { userId, ...(gameKey ? { gameKey } : {}) },
      orderBy: { createdAt: 'desc' },
      take,
      include: { season: { select: { key: true } } },
    });
    const matchIds = [...new Set(events.map((e) => e.matchId))];
    const opponents = new Map<string, string>();
    if (matchIds.length > 0) {
      const rows = await this.prisma.matchPlayer.findMany({
        where: { matchId: { in: matchIds }, userId: { not: userId } },
        select: { matchId: true, user: { select: { username: true } } },
      });
      for (const row of rows) {
        opponents.set(row.matchId, row.user.username);
      }
    }
    return {
      items: events.map((event) => ({
        id: event.id,
        matchId: event.matchId,
        gameKey: event.gameKey,
        result: event.result,
        reason: event.reason,
        ratingBefore: event.ratingBefore,
        delta: event.delta,
        ratingAfter: event.ratingAfter,
        seasonKey: event.season.key,
        opponent: opponents.get(event.matchId) ?? null,
        createdAt: event.createdAt.toISOString(),
      })),
    };
  }

  // --- Shared --------------------------------------------------------------

  static readonly startRating = START_RATING;
  static readonly rankTiers = RANK_TIERS;

  private serializeSeason(season: { key: string; name: string; startsAt: Date; endsAt: Date | null }) {
    return {
      key: season.key,
      name: season.name,
      startsAt: season.startsAt.toISOString(),
      endsAt: season.endsAt ? season.endsAt.toISOString() : null,
    };
  }
}

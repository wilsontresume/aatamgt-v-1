import { BadRequestException, Injectable, NotFoundException } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';

export interface DashboardQuery {
  from?: string;
  to?: string;
  gameKey?: string;
}

const DAY_MS = 86_400_000;
const DEFAULT_RANGE_DAYS = 14;
const MAX_RANGE_DAYS = 366;
const RECENT_LIMIT = 6;
const TOP_GAMES_LIMIT = 10;

function utcToday(): string {
  return new Date().toISOString().slice(0, 10);
}

function parseDay(value: string, field: string): Date {
  const parsed = new Date(`${value}T00:00:00.000Z`);
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) {
    throw new BadRequestException(`\`${field}\` must be a valid YYYY-MM-DD date`);
  }
  return parsed;
}

function shiftDays(day: string, deltaDays: number): string {
  const parsed = parseDay(day, 'day');
  return new Date(parsed.getTime() + deltaDays * DAY_MS).toISOString().slice(0, 10);
}

/** Iterates every UTC day of [from, to] inclusive. */
function eachDay(from: string, to: string): string[] {
  const days: string[] = [];
  let cursor = parseDay(from, 'from');
  const end = parseDay(to, 'to');
  while (cursor.getTime() <= end.getTime()) {
    days.push(cursor.toISOString().slice(0, 10));
    cursor = new Date(cursor.getTime() + DAY_MS);
  }
  return days;
}

/**
 * Admin dashboard aggregation. Every number is read from the database in
 * one round of queries — nothing here is estimated, sampled or fabricated.
 */
@Injectable()
export class AdminDashboardService {
  constructor(private readonly prisma: PrismaService) {}

  async summary(query: DashboardQuery, actorRole: string) {
    const to = query.to ?? utcToday();
    const from = query.from ?? shiftDays(to, -(DEFAULT_RANGE_DAYS - 1));
    const fromDate = parseDay(from, 'from');
    const toDate = parseDay(to, 'to');
    if (fromDate.getTime() > toDate.getTime()) {
      throw new BadRequestException('`from` must be on or before `to`');
    }
    if (toDate.getTime() - fromDate.getTime() > (MAX_RANGE_DAYS - 1) * DAY_MS) {
      throw new BadRequestException(`Date range cannot exceed ${MAX_RANGE_DAYS} days`);
    }
    const start = fromDate;
    const endExclusive = new Date(toDate.getTime() + DAY_MS);
    const gameKey = query.gameKey?.trim() ? query.gameKey.trim() : undefined;
    if (gameKey) {
      const game = await this.prisma.game.findUnique({ where: { key: gameKey } });
      if (!game) throw new NotFoundException('Unknown gameKey');
    }

    const matchWhere: Prisma.GameMatchWhereInput = {
      createdAt: { gte: start, lt: endExclusive },
      ...(gameKey ? { gameKey } : {}),
    };
    const txWhere: Prisma.WalletTransactionWhereInput = {
      createdAt: { gte: start, lt: endExclusive },
    };

    const dbStartedAt = Date.now();
    await this.prisma.$queryRaw`SELECT 1`;
    const dbLatencyMs = Date.now() - dbStartedAt;

    const [
      matchStatusGroups,
      aiMatches,
      humanMatches,
      matchesByGame,
      matchTotalInRange,
      activeNow,
      pendingNow,
      userStatusGroups,
      guestCount,
      registeredInRange,
      registrationRows,
      circulation,
      txByType,
      issuedAgg,
      spentAgg,
      grantRows,
      recentUsers,
      queueDepth,
      recentAudit,
      gameNames,
    ] = await Promise.all([
      this.prisma.gameMatch.groupBy({
        by: ['status'],
        where: matchWhere,
        _count: true,
      }),
      this.prisma.gameMatch.count({
        where: { ...matchWhere, players: { some: { isAi: true } } },
      }),
      this.prisma.gameMatch.count({
        where: { ...matchWhere, players: { none: { isAi: true } } },
      }),
      this.prisma.gameMatch.groupBy({
        by: ['gameKey'],
        where: matchWhere,
        _count: true,
      }),
      this.prisma.gameMatch.count({ where: matchWhere }),
      this.prisma.gameMatch.count({ where: { status: { in: ['ACTIVE', 'PAUSED'] } } }),
      this.prisma.gameMatch.count({ where: { status: 'PENDING' } }),
      this.prisma.user.groupBy({
        by: ['status'],
        where: { deletedAt: null },
        _count: true,
      }),
      this.prisma.user.count({ where: { isGuest: true, deletedAt: null } }),
      this.prisma.user.count({
        where: { deletedAt: null, createdAt: { gte: start, lt: endExclusive } },
      }),
      this.prisma.$queryRaw<{ day: string; count: bigint }[]>`
        SELECT DATE_FORMAT(createdAt, '%Y-%m-%d') AS day, COUNT(*) AS count
        FROM User
        WHERE deletedAt IS NULL AND createdAt >= ${start} AND createdAt < ${endExclusive}
        GROUP BY DATE_FORMAT(createdAt, '%Y-%m-%d')
        ORDER BY day ASC`,
      this.prisma.wallet.aggregate({
        where: { currency: 'COIN' },
        _sum: { balance: true },
        _count: { _all: true },
      }),
      this.prisma.walletTransaction.groupBy({
        by: ['type'],
        where: txWhere,
        _count: true,
        _sum: { amount: true },
      }),
      // Gross flows: issued = sum of positive rows, spent = |sum of negative rows|.
      // Per-type net sums would net mixed-sign types (e.g. MATCH_REWARD stakes
      // against payouts) and understate both directions.
      this.prisma.walletTransaction.aggregate({
        where: { ...txWhere, amount: { gt: 0 } },
        _sum: { amount: true },
      }),
      this.prisma.walletTransaction.aggregate({
        where: { ...txWhere, amount: { lt: 0 } },
        _sum: { amount: true },
      }),
      this.prisma.$queryRaw<{ day: string; count: bigint; amount: bigint }[]>`
        SELECT DATE_FORMAT(createdAt, '%Y-%m-%d') AS day,
               COUNT(*) AS count,
               SUM(amount) AS amount
        FROM WalletTransaction
        WHERE createdAt >= ${start} AND createdAt < ${endExclusive} AND amount > 0
        GROUP BY DATE_FORMAT(createdAt, '%Y-%m-%d')
        ORDER BY day ASC`,
      this.prisma.user.findMany({
        orderBy: { createdAt: 'desc' },
        take: RECENT_LIMIT,
        select: {
          id: true,
          username: true,
          isGuest: true,
          status: true,
          createdAt: true,
        },
      }),
      this.prisma.matchmakingTicket.count({ where: { status: 'WAITING' } }),
      actorRole === 'ADMIN'
        ? this.prisma.adminAuditLog.findMany({
            orderBy: { createdAt: 'desc' },
            take: RECENT_LIMIT,
            include: { actor: { select: { username: true } } },
          })
        : Promise.resolve(null),
      this.prisma.game.findMany({ select: { key: true, name: true } }),
    ]);

    const statusCounts: Record<string, number> = {
      PENDING: 0,
      ACTIVE: 0,
      PAUSED: 0,
      COMPLETED: 0,
      ABANDONED: 0,
      CANCELLED: 0,
    };
    for (const row of matchStatusGroups) statusCounts[row.status] = row._count;

    const userCounts: Record<string, number> = { ACTIVE: 0, SUSPENDED: 0, BANNED: 0 };
    for (const row of userStatusGroups) userCounts[row.status] = row._count;

    const gameNameByKey = new Map(gameNames.map((game) => [game.key, game.name]));
    const topGames = [...matchesByGame].sort((a, b) => b._count - a._count).slice(0, TOP_GAMES_LIMIT);
    const registrations = fillDays(from, to, registrationRows, { count: 0 }, (row) => ({
      count: Number(row.count),
    }));
    const grantsPerDay = fillDays(
      from,
      to,
      grantRows,
      { count: 0, amount: 0 },
      (row) => ({ count: Number(row.count), amount: Number(row.amount) }),
    );

    const issuedInRange = Number(issuedAgg._sum.amount ?? 0);
    const spentInRange = Math.abs(Number(spentAgg._sum.amount ?? 0));
    const byType = txByType
      .map((row) => ({
        type: row.type,
        count: row._count,
        amount: Number(row._sum.amount ?? 0),
      }))
      .sort((a, b) => Math.abs(b.amount) - Math.abs(a.amount));

    return {
      range: { from, to, gameKey: gameKey ?? null },
      users: {
        total: Object.values(userCounts).reduce((sum, count) => sum + count, 0),
        guests: guestCount,
        active: userCounts.ACTIVE,
        suspended: userCounts.SUSPENDED,
        banned: userCounts.BANNED,
        registeredInRange,
        registrations,
      },
      matches: {
        activeNow,
        pendingNow,
        totalInRange: matchTotalInRange,
        byStatus: statusCounts,
        humanVsHuman: humanMatches,
        humanVsAi: aiMatches,
        byGame: topGames.map((row) => ({
          gameKey: row.gameKey,
          name: gameNameByKey.get(row.gameKey) ?? row.gameKey,
          matches: row._count,
        })),
      },
      economy: {
        coinsCirculation: circulation._sum.balance ?? 0,
        wallets: circulation._count._all,
        issuedInRange,
        spentInRange,
        transactionsInRange: txByType.reduce((sum, row) => sum + row._count, 0),
        byType,
        grantsPerDay,
      },
      health: {
        status: 'ok',
        dbLatencyMs,
        uptimeSeconds: Math.round(process.uptime()),
        queueDepth,
        serverTime: new Date().toISOString(),
      },
      recent: {
        registrations: recentUsers,
        audit:
          recentAudit === null
            ? null
            : recentAudit.map((row) => ({
                id: row.id,
                action: row.action,
                actorUsername: row.actor.username,
                targetType: row.targetType,
                targetId: row.targetId,
                createdAt: row.createdAt.toISOString(),
              })),
      },
    };
  }
}

/** Expands sparse daily query rows into a gap-free day series. */
function fillDays<T extends object>(
  from: string,
  to: string,
  rows: Array<T & { day: string }>,
  empty: Record<string, number>,
  pick: (row: T & { day: string }) => Record<string, number>,
): Array<{ date: string } & Record<string, number>> {
  const byDay = new Map(rows.map((row) => [row.day, pick(row)]));
  const series: Array<{ date: string } & Record<string, number>> = [];
  for (const date of eachDay(from, to)) {
    const values = byDay.get(date) ?? { ...empty };
    series.push({ ...values, date } as { date: string } & Record<string, number>);
  }
  return series;
}

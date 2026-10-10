import { BadRequestException, Injectable, NotFoundException } from '@nestjs/common';
import { CosmeticCategory, MatchResult, Prisma, UserStatus, WalletTxType } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { WalletService } from '../wallet/wallet.service';
import { SystemConfigService } from '../config/system-config.service';
import { PaginationQuery, Paginated } from '../common/dto/pagination.query';

export interface PlayerResultInput {
  userId: string;
  result: MatchResult;
  score?: number;
}

export interface CompleteMatchInput {
  status: 'COMPLETED' | 'ABANDONED' | 'CANCELLED' | 'PAUSED' | 'ACTIVE';
  players?: PlayerResultInput[];
  reason?: string;
}

@Injectable()
export class AdminService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly wallet: WalletService,
    private readonly systemConfig: SystemConfigService,
  ) {}

  async stats() {
    const [users, activeMatches, games, transactions] = await Promise.all([
      this.prisma.user.count({ where: { deletedAt: null } }),
      this.prisma.gameMatch.count({ where: { status: 'ACTIVE' } }),
      this.prisma.game.count(),
      this.prisma.walletTransaction.count(),
    ]);
    return { users, activeMatches, games, transactions };
  }

  async users(query: PaginationQuery & { q?: string }) {
    const where: Prisma.UserWhereInput = {
      deletedAt: null,
      ...(query.q
        ? {
            OR: [{ username: { contains: query.q } }, { email: { contains: query.q } }],
          }
        : {}),
    };
    const [items, total] = await Promise.all([
      this.prisma.user.findMany({
        where,
        orderBy: { createdAt: 'desc' },
        skip: query.skip,
        take: query.limit,
        select: {
          id: true,
          username: true,
          email: true,
          role: true,
          status: true,
          createdAt: true,
          lastLoginAt: true,
        },
      }),
      this.prisma.user.count({ where }),
    ]);
    return { items, page: query.page, limit: query.limit, total };
  }

  async setUserStatus(actorId: string, userId: string, status: UserStatus, reason?: string) {
    const user = await this.prisma.user.findUnique({ where: { id: userId } });
    if (!user) throw new NotFoundException('User not found');
    if (user.id === actorId && status !== 'ACTIVE') {
      throw new BadRequestException('You cannot change your own status');
    }

    const updated = await this.prisma.user.update({
      where: { id: userId },
      data: { status },
      select: { id: true, username: true, status: true },
    });
    await this.audit(actorId, 'user.status', 'user', userId, { status, reason });
    return updated;
  }

  async matches(query: PaginationQuery & { status?: string }) {
    const where: Prisma.GameMatchWhereInput = query.status
      ? { status: query.status as Prisma.EnumMatchStatusFilter['equals'] }
      : {};
    const [items, total] = await Promise.all([
      this.prisma.gameMatch.findMany({
        where,
        orderBy: { createdAt: 'desc' },
        skip: query.skip,
        take: query.limit,
        include: {
          players: { include: { user: { select: { username: true } } } },
          game: { select: { key: true, name: true } },
        },
      }),
      this.prisma.gameMatch.count({ where }),
    ]);
    return { items, page: query.page, limit: query.limit, total };
  }

  /**
   * Operator-driven match finalisation. Results are supplied explicitly by an
   * admin — the platform never invents winners, and no rules engine exists yet.
   */
  async finalizeMatch(actorId: string, matchId: string, input: CompleteMatchInput) {
    const match = await this.prisma.gameMatch.findUnique({
      where: { id: matchId },
      include: { players: true },
    });
    if (!match) throw new NotFoundException('Match not found');

    if (input.status === 'COMPLETED' || input.status === 'ABANDONED') {
      if (!input.players || input.players.length === 0) {
        throw new BadRequestException('Explicit player results are required');
      }
      const known = new Set(match.players.map((p) => p.userId));
      for (const row of input.players) {
        if (!known.has(row.userId)) {
          throw new BadRequestException(`User ${row.userId} is not in this match`);
        }
        if (row.result === 'PENDING') {
          throw new BadRequestException('result must be WIN, LOSS, DRAW or ABANDONED');
        }
      }
    }

    const wasCompleted = match.status === 'COMPLETED';
    const updated = await this.prisma.$transaction(async (tx) => {
      if (input.players && input.players.length > 0) {
        for (const row of input.players) {
          await tx.matchPlayer.updateMany({
            where: { matchId, userId: row.userId },
            data: { result: row.result, score: row.score ?? 0 },
          });
        }
        if (!wasCompleted && input.status === 'COMPLETED') {
          for (const row of input.players) {
            const data: Prisma.ProfileUpdateInput = { gamesPlayed: { increment: 1 } };
            if (row.result === 'WIN') data.wins = { increment: 1 };
            if (row.result === 'LOSS') data.losses = { increment: 1 };
            if (row.result === 'DRAW') data.draws = { increment: 1 };
            await tx.profile.update({ where: { userId: row.userId }, data });
          }
        }
      }
      return tx.gameMatch.update({
        where: { id: matchId },
        data: {
          status: input.status,
          completedAt:
            input.status === 'COMPLETED' || input.status === 'ABANDONED'
              ? (match.completedAt ?? new Date())
              : null,
          stateVersion: { increment: 1 },
        },
        include: { players: true },
      });
    });

    await this.audit(actorId, 'match.finalize', 'match', matchId, {
      status: input.status,
      players: input.players,
      reason: input.reason,
    });
    return updated;
  }

  async adjustWallet(actorId: string, userId: string, amount: number, memo?: string) {
    if (!Number.isInteger(amount) || amount === 0) {
      throw new BadRequestException('amount must be a non-zero integer');
    }
    const result = await this.wallet.apply({
      userId,
      amount,
      type: 'ADMIN_ADJUSTMENT',
      refType: 'admin',
      refId: actorId,
      memo,
      idempotencyKey: undefined,
    });
    await this.audit(actorId, 'wallet.adjust', 'user', userId, { amount, memo });
    return {
      balance: result.wallet.balance,
      transactionId: result.transaction.id,
      amount,
    };
  }

  // --- Phase 15: player detail ------------------------------------------------

  async player(userId: string) {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      select: {
        id: true,
        username: true,
        email: true,
        role: true,
        status: true,
        isGuest: true,
        royalPassExpiresAt: true,
        lastLoginAt: true,
        createdAt: true,
        profile: {
          select: {
            displayName: true,
            level: true,
            xp: true,
            rating: true,
            wins: true,
            losses: true,
            draws: true,
            gamesPlayed: true,
          },
        },
        wallets: { select: { currency: true, balance: true, lockedBalance: true } },
      },
    });
    if (!user) throw new NotFoundException('User not found');
    return user;
  }

  async playerWallet(userId: string, query: PaginationQuery): Promise<
    Paginated<{
      id: string;
      amount: number;
      balanceAfter: number;
      type: string;
      memo: string | null;
      createdAt: string;
    }> & { balance: number }
  > {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      select: { id: true },
    });
    if (!user) throw new NotFoundException('User not found');
    const wallet = await this.prisma.wallet.findUnique({
      where: { userId_currency: { userId, currency: 'COIN' } },
    });
    const where: Prisma.WalletTransactionWhereInput = { wallet: { userId } };
    const [rows, total] = await Promise.all([
      this.prisma.walletTransaction.findMany({
        where,
        orderBy: { createdAt: 'desc' },
        skip: query.skip,
        take: query.limit,
      }),
      this.prisma.walletTransaction.count({ where }),
    ]);
    return {
      balance: wallet?.balance ?? 0,
      items: rows.map((row) => ({
        id: row.id,
        amount: row.amount,
        balanceAfter: row.balanceAfter,
        type: row.type,
        memo: row.memo,
        createdAt: row.createdAt.toISOString(),
      })),
      page: query.page,
      limit: query.limit,
      total,
    };
  }

  async playerMatches(userId: string, query: PaginationQuery) {
    const where: Prisma.GameMatchWhereInput = { players: { some: { userId } } };
    const [items, total] = await Promise.all([
      this.prisma.gameMatch.findMany({
        where,
        orderBy: { createdAt: 'desc' },
        skip: query.skip,
        take: query.limit,
        include: {
          players: {
            include: { user: { select: { username: true } } },
          },
          game: { select: { key: true, name: true } },
        },
      }),
      this.prisma.gameMatch.count({ where }),
    ]);
    return { items, page: query.page, limit: query.limit, total };
  }

  // --- Phase 15: economy ------------------------------------------------------

  async economySummary() {
    const txCount = this.prisma.walletTransaction.count();
    const issued = this.prisma.walletTransaction.aggregate({
      where: { amount: { gt: 0 } },
      _sum: { amount: true },
    });
    const spent = this.prisma.walletTransaction.aggregate({
      where: { amount: { lt: 0 } },
      _sum: { amount: true },
    });
    const rewardedCount = this.prisma.walletTransaction.count({
      where: { type: 'REWARDED_AD' },
    });
    const rewardedCoins = this.prisma.walletTransaction.aggregate({
      where: { type: 'REWARDED_AD' },
      _sum: { amount: true },
    });
    const adSessions = this.prisma.adSession.count();
    const adRedeemed = this.prisma.adSession.count({ where: { status: 'REDEEMED' } });
    const purchases = await this.prisma.purchase.groupBy({ by: ['state'], _count: true });
    const [txTotal, issuedAgg, spentAgg, rewarded, rewardedSum, sessions, redeemed] =
      await Promise.all([txCount, issued, spent, rewardedCount, rewardedCoins, adSessions, adRedeemed]);

    const byState: Record<string, number> = {};
    for (const row of purchases) byState[row.state] = row._count;
    const purchaseTotal = purchases.reduce((sum, row) => sum + row._count, 0);

    return {
      coinsIssued: issuedAgg._sum.amount ?? 0,
      coinsSpent: Math.abs(spentAgg._sum.amount ?? 0),
      transactions: txTotal,
      rewardedAds: {
        sessions,
        redeemed,
        coinsGranted: rewardedSum._sum.amount ?? 0,
        grants: rewarded,
      },
      purchases: { count: purchaseTotal, byState },
    };
  }

  async economyTransactions(
    query: PaginationQuery & { userId?: string; type?: string },
  ): Promise<Paginated<unknown>> {
    const where: Prisma.WalletTransactionWhereInput = {
      ...(query.userId ? { wallet: { userId: query.userId } } : {}),
      ...(query.type ? { type: query.type as WalletTxType } : {}),
    };
    const [rows, total] = await Promise.all([
      this.prisma.walletTransaction.findMany({
        where,
        orderBy: { createdAt: 'desc' },
        skip: query.skip,
        take: query.limit,
        include: { wallet: { select: { user: { select: { id: true, username: true } } } } },
      }),
      this.prisma.walletTransaction.count({ where }),
    ]);
    return {
      items: rows.map((row) => ({
        id: row.id,
        userId: row.wallet.user.id,
        username: row.wallet.user.username,
        amount: row.amount,
        balanceAfter: row.balanceAfter,
        type: row.type,
        memo: row.memo,
        createdAt: row.createdAt.toISOString(),
      })),
      page: query.page,
      limit: query.limit,
      total,
    };
  }

  async economyAdShows(query: PaginationQuery): Promise<Paginated<unknown>> {
    const where = {};
    const [rows, total] = await Promise.all([
      this.prisma.adShow.findMany({
        where,
        orderBy: { shownAt: 'desc' },
        skip: query.skip,
        take: query.limit,
        include: { user: { select: { username: true } } },
      }),
      this.prisma.adShow.count({ where }),
    ]);
    return {
      items: rows.map((row) => ({
        id: row.id,
        userId: row.userId,
        username: row.user.username,
        kind: row.kind,
        matchId: row.matchId,
        shownAt: row.shownAt.toISOString(),
      })),
      page: query.page,
      limit: query.limit,
      total,
    };
  }

  async economyPurchases(query: PaginationQuery): Promise<Paginated<unknown>> {
    const where = {};
    const [rows, total] = await Promise.all([
      this.prisma.purchase.findMany({
        where,
        orderBy: { createdAt: 'desc' },
        skip: query.skip,
        take: query.limit,
        include: { user: { select: { username: true } } },
      }),
      this.prisma.purchase.count({ where }),
    ]);
    return {
      items: rows.map((row) => ({
        id: row.id,
        userId: row.userId,
        username: row.user.username,
        productKey: row.productKey,
        platform: row.platform,
        state: row.state,
        coinAmount: row.coinAmount,
        passDays: row.passDays,
        createdAt: row.createdAt.toISOString(),
        grantedAt: row.grantedAt ? row.grantedAt.toISOString() : null,
      })),
      page: query.page,
      limit: query.limit,
      total,
    };
  }

  // --- Phase 15: content (cosmetics) ------------------------------------------

  async cosmetics(query: PaginationQuery & { category?: string }) {
    const where: Prisma.CosmeticWhereInput = query.category
      ? { category: query.category as CosmeticCategory }
      : {};
    const [items, total] = await Promise.all([
      this.prisma.cosmetic.findMany({
        where,
        orderBy: [{ category: 'asc' }, { sortOrder: 'asc' }, { key: 'asc' }],
        skip: query.skip,
        take: query.limit,
        include: { _count: { select: { userCosmetics: true } } },
      }),
      this.prisma.cosmetic.count({ where }),
    ]);
    return {
      items: items.map((row) => ({
        id: row.id,
        key: row.key,
        category: row.category,
        name: row.name,
        tier: row.tier,
        price: row.price,
        active: row.active,
        grantedByDefault: row.grantedByDefault,
        sortOrder: row.sortOrder,
        owners: row._count.userCosmetics,
      })),
      page: query.page,
      limit: query.limit,
      total,
    };
  }

  async updateCosmetic(
    actorId: string,
    id: string,
    patch: { price?: number; active?: boolean; name?: string },
  ) {
    const existing = await this.prisma.cosmetic.findUnique({ where: { id } });
    if (!existing) throw new NotFoundException('Cosmetic not found');
    const data: Prisma.CosmeticUpdateInput = {};
    if (patch.price !== undefined) {
      if (!Number.isInteger(patch.price) || patch.price < 0 || patch.price > 100_000) {
        throw new BadRequestException('price must be an integer between 0 and 100000');
      }
      data.price = patch.price;
    }
    if (patch.active !== undefined) data.active = patch.active;
    if (patch.name !== undefined) {
      const name = patch.name.trim();
      if (!name || name.length > 120) {
        throw new BadRequestException('name must be 1-120 characters');
      }
      data.name = name;
    }
    if (Object.keys(data).length === 0) {
      throw new BadRequestException('No changes supplied');
    }
    const updated = await this.prisma.cosmetic.update({ where: { id }, data });
    await this.audit(actorId, 'cosmetic.update', 'cosmetic', id, {
      before: { price: existing.price, active: existing.active, name: existing.name },
      after: { price: updated.price, active: updated.active, name: updated.name },
    });
    return updated;
  }

  // --- Phase 15: configuration ------------------------------------------------

  async configEntries() {
    return { items: await this.systemConfig.entries() };
  }

  async saveConfig(actorId: string, entries: { key: string; value: unknown }[]) {
    if (entries.length === 0) throw new BadRequestException('No entries supplied');
    // Pass 1: validate everything before writing anything, so a single
    // bad key can never leave the config half-applied.
    const current = await this.systemConfig.entries();
    const byKey = new Map(current.map((entry) => [entry.key, entry]));
    const changes: Array<{ key: string; before: unknown; after: unknown }> = [];
    const normalized: Array<{ key: string; value: number | boolean }> = [];
    for (const entry of entries) {
      const before = byKey.get(entry.key);
      if (before === undefined) {
        throw new BadRequestException(`Unknown config key '${entry.key}'`);
      }
      const value = this.systemConfig.validate(entry.key, entry.value);
      if (value !== before.value) {
        changes.push({ key: entry.key, before: before.value, after: value });
      }
      normalized.push({ key: entry.key, value });
    }
    for (const entry of normalized) {
      await this.systemConfig.set(entry.key, entry.value);
    }
    if (changes.length > 0) {
      await this.audit(actorId, 'config.set', 'config', null, { changes });
    }
    return { items: await this.systemConfig.entries(), changes: changes.length };
  }

  async auditLog(query: PaginationQuery): Promise<Paginated<unknown>> {
    const where = {};
    const [items, total] = await Promise.all([
      this.prisma.adminAuditLog.findMany({
        where,
        orderBy: { createdAt: 'desc' },
        skip: query.skip,
        take: query.limit,
        include: { actor: { select: { username: true } } },
      }),
      this.prisma.adminAuditLog.count({ where }),
    ]);
    return {
      items: items.map((row) => ({
        id: row.id,
        action: row.action,
        actor: row.actor.username,
        targetType: row.targetType,
        targetId: row.targetId,
        data: row.data,
        createdAt: row.createdAt.toISOString(),
      })),
      page: query.page,
      limit: query.limit,
      total,
    };
  }

  async audit(
    actorUserId: string,
    action: string,
    targetType: string | null,
    targetId: string | null,
    data?: Record<string, unknown>,
  ) {
    return this.prisma.adminAuditLog.create({
      data: {
        actorUserId,
        action,
        targetType,
        targetId,
        data: data as Prisma.InputJsonValue | undefined,
      },
    });
  }
}

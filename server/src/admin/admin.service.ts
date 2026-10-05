import { BadRequestException, Injectable, NotFoundException } from '@nestjs/common';
import { MatchResult, Prisma, UserStatus } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { WalletService } from '../wallet/wallet.service';
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

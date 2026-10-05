import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { GameMatch, MatchPlayer, Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { GamesService } from '../games/games.service';
import { MatchEventsService } from '../events/match-events.service';

export interface CreateMatchDto {
  gameKey: string;
  mode?: 'CASUAL' | 'RANKED' | 'PRIVATE';
  stakeCoins?: number;
}

export interface SubmitMoveDto {
  payload: Record<string, unknown>;
  clientSeq?: number;
}

export type MatchWithPlayers = GameMatch & {
  players: (MatchPlayer & { user: { username: string } })[];
};

@Injectable()
export class MatchesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly games: GamesService,
    private readonly events: MatchEventsService,
  ) {}

  async create(userId: string, dto: CreateMatchDto): Promise<MatchWithPlayers> {
    const game = await this.games.getByKey(dto.gameKey);
    if (game.status !== 'ACTIVE') throw new ConflictException('Game is not available');
    if ((dto.stakeCoins ?? 0) !== 0) {
      throw new ConflictException('Stakes are disabled until gameplay ships');
    }

    const match = await this.prisma.gameMatch.create({
      data: {
        gameId: game.id,
        gameKey: game.key,
        mode: dto.mode ?? 'CASUAL',
        createdByUserId: userId,
        players: { create: { userId, seat: 0 } },
      },
      include: { players: { include: { user: { select: { username: true } } } } },
    });

    if (game.minPlayers <= 1) return this.activate(match.id);
    return match;
  }

  async join(userId: string, matchId: string): Promise<MatchWithPlayers> {
    const match = await this.requireMatch(matchId, {
      players: { include: { user: { select: { username: true } } } },
    });
    const game = await this.games.getByKey(match.gameKey);

    if (match.status !== 'PENDING') throw new ConflictException('Match is not joinable');
    if (match.players.some((p) => p.userId === userId)) return match;
    if (match.players.length >= game.maxPlayers) throw new ConflictException('Match is full');

    const seat = this.nextSeat(match.players);
    await this.prisma.matchPlayer.create({ data: { matchId: match.id, userId, seat } });

    const count = match.players.length + 1;
    if (count >= game.minPlayers) return this.activate(match.id);
    return this.requireMatch(matchId, {
      players: { include: { user: { select: { username: true } } } },
    });
  }

  async activate(matchId: string): Promise<MatchWithPlayers> {
    const match = await this.prisma.gameMatch.update({
      where: { id: matchId },
      data: { status: 'ACTIVE', startedAt: new Date(), stateVersion: { increment: 1 } },
      include: { players: { include: { user: { select: { username: true } } } } },
    });
    this.events.publish({
      kind: 'status',
      data: {
        matchId: match.id,
        status: match.status,
        stateVersion: match.stateVersion,
        at: new Date().toISOString(),
      },
    });
    return match;
  }

  async leave(userId: string, matchId: string): Promise<MatchWithPlayers> {
    const match = await this.requireMatch(matchId, {
      players: { include: { user: { select: { username: true } } } },
    });
    const player = match.players.find((p) => p.userId === userId);
    if (!player) throw new ForbiddenException('You are not in this match');

    if (match.status === 'PENDING') {
      if (match.players.length === 1 && match.createdByUserId === userId) {
        const cancelled = await this.prisma.gameMatch.update({
          where: { id: matchId },
          data: { status: 'CANCELLED' },
          include: { players: { include: { user: { select: { username: true } } } } },
        });
        this.publishStatus(cancelled);
        return cancelled;
      }
      await this.prisma.matchPlayer.delete({ where: { id: player.id } });
      return this.requireMatch(matchId, {
        players: { include: { user: { select: { username: true } } } },
      });
    }

    if (match.status === 'ACTIVE') {
      await this.prisma.matchPlayer.update({
        where: { id: player.id },
        data: { result: 'ABANDONED', leftAt: new Date() },
      });
      const abandoned = await this.prisma.gameMatch.update({
        where: { id: matchId },
        data: {
          status: 'ABANDONED',
          completedAt: new Date(),
          stateVersion: { increment: 1 },
        },
        include: { players: { include: { user: { select: { username: true } } } } },
      });
      this.publishStatus(abandoned);
      return abandoned;
    }

    throw new ConflictException('Match is already finished');
  }

  /**
   * Server-authoritative move intake. The server assigns the sequence number,
   * validates seat/turn-independent invariants and persists the move log.
   * Game rules (and any result computation) arrive in a later phase.
   */
  async submitMove(userId: string, matchId: string, dto: SubmitMoveDto) {
    if (!dto.payload || typeof dto.payload !== 'object') {
      throw new BadRequestException('payload must be an object');
    }
    if (dto.clientSeq !== undefined && (!Number.isInteger(dto.clientSeq) || dto.clientSeq < 1)) {
      throw new BadRequestException('clientSeq must be a positive integer');
    }

    const match = await this.requireMatch(matchId, { players: true });
    if (match.status !== 'ACTIVE') throw new ConflictException('Match is not active');

    const player = match.players.find((p) => p.userId === userId);
    if (!player) throw new ForbiddenException('Only match participants can move');
    if (player.result === 'ABANDONED') throw new ForbiddenException('You left this match');

    const existing = await this.prisma.matchMove.count({ where: { matchId } });
    const seq = existing + 1;
    if (dto.clientSeq !== undefined && dto.clientSeq !== seq) {
      throw new ConflictException(`Out of order move: expected seq ${seq}`);
    }

    const created = await this.prisma.$transaction(async (tx) => {
      const move = await tx.matchMove.create({
        data: {
          matchId,
          seq,
          matchPlayerId: player.id,
          userId,
          payload: dto.payload as Prisma.InputJsonValue,
        },
      });
      const updated = await tx.gameMatch.update({
        where: { id: matchId },
        data: {
          stateVersion: { increment: 1 },
          serverState: {
            lastSeq: seq,
            lastMoveBy: userId,
            lastMoveAt: new Date().toISOString(),
            moveCount: seq,
          },
        },
      });
      return { move, stateVersion: updated.stateVersion };
    });

    const event = {
      matchId,
      seq,
      stateVersion: created.stateVersion,
      userId,
      payload: dto.payload,
      at: created.move.serverAt.toISOString(),
    };
    this.events.publish({ kind: 'move', data: event });

    return {
      move: {
        id: created.move.id,
        seq,
        userId,
        payload: created.move.payload,
        serverAt: created.move.serverAt.toISOString(),
      },
      stateVersion: created.stateVersion,
    };
  }

  async getMatch(matchId: string, opts: { includeHistory?: number } = {}) {
    const match = await this.requireMatch(matchId, {
      players: { include: { user: { select: { username: true } } } },
    });
    const take = Math.min(Math.max(opts.includeHistory ?? 50, 0), 200);
    const moves = await this.prisma.matchMove.findMany({
      where: { matchId },
      orderBy: { seq: 'asc' },
      take,
    });
    return { ...match, moves };
  }

  listMy(userId: string) {
    return this.prisma.gameMatch.findMany({
      where: { players: { some: { userId } } },
      orderBy: { createdAt: 'desc' },
      take: 25,
      include: { players: { include: { user: { select: { username: true } } } } },
    });
  }

  serialize(match: MatchWithPlayers) {
    return {
      id: match.id,
      gameKey: match.gameKey,
      status: match.status,
      mode: match.mode,
      stateVersion: match.stateVersion,
      serverState: match.serverState,
      stakeCoins: match.stakeCoins,
      players: match.players.map((p) => ({
        userId: p.userId,
        username: p.user.username,
        seat: p.seat,
        team: p.team,
        color: p.color,
        result: p.result,
        score: p.score,
      })),
      startedAt: match.startedAt?.toISOString() ?? null,
      completedAt: match.completedAt?.toISOString() ?? null,
      createdAt: match.createdAt.toISOString(),
    };
  }

  private publishStatus(match: GameMatch): void {
    this.events.publish({
      kind: 'status',
      data: {
        matchId: match.id,
        status: match.status,
        stateVersion: match.stateVersion,
        at: new Date().toISOString(),
      },
    });
  }

  private nextSeat(players: { seat: number }[]): number {
    const taken = new Set(players.map((p) => p.seat));
    let seat = 0;
    while (taken.has(seat)) seat++;
    return seat;
  }

  private async requireMatch<T extends Prisma.GameMatchInclude>(
    matchId: string,
    include: T,
  ): Promise<Prisma.GameMatchGetPayload<{ include: T }>> {
    if (!matchId) throw new BadRequestException('matchId is required');
    const match = await this.prisma.gameMatch.findUnique({ where: { id: matchId }, include });
    if (!match) throw new NotFoundException('Match not found');
    return match;
  }
}

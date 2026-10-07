import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { GameMatch, MatchPlayer, Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { GamesService } from '../games/games.service';
import { MatchEventsService } from '../events/match-events.service';
import { MatchClockService } from './match-clock.service';
import { AppConfig } from '../config/configuration';
import {
  AaduPuliRules,
  GameResult,
  GameState,
  Move,
  Side,
  errorText,
  stateHash,
  validate,
} from '../aadu-puli';

/** The only game with a server-side rules engine (Phase 6). */
export const AADU_PULI_GAME_KEY = 'aadu-puli-aattam';

export type CompletionReason = 'RULES' | 'RESIGN' | 'TIMEOUT' | 'DISCONNECT';

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

/** Server-owned match state for Aadu Puli Aattam (stored as JSON). */
export interface AaduPuliServerState {
  game: typeof AADU_PULI_GAME_KEY;
  state: unknown;
  turnDeadlineAt: string;
  turnNumber: number;
  completed?: { reason: CompletionReason; winnerSeat: number | null };
  rematchMatchId?: string;
}

interface MatchCompletion {
  winnerSeat: number | null;
  reason: CompletionReason;
}

const ELO_K = 16;

@Injectable()
export class MatchesService {
  private readonly logger = new Logger(MatchesService.name);
  private readonly cfg: AppConfig;

  constructor(
    private readonly prisma: PrismaService,
    private readonly games: GamesService,
    private readonly events: MatchEventsService,
    private readonly clock: MatchClockService,
    config: ConfigService,
  ) {
    this.cfg = config.get<AppConfig>('app') as AppConfig;
  }

  async create(userId: string, dto: CreateMatchDto): Promise<MatchWithPlayers> {
    const game = await this.games.getByKey(dto.gameKey);
    if (game.status !== 'ACTIVE') throw new ConflictException('Game is not available');
    if ((dto.stakeCoins ?? 0) !== 0) {
      throw new ConflictException('Stakes are disabled');
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
    const previous = await this.prisma.gameMatch.findUnique({ where: { id: matchId } });
    if (!previous) throw new NotFoundException('Match not found');

    let deadline: Date | null = null;
    const data: Prisma.GameMatchUpdateInput = {
      status: 'ACTIVE',
      startedAt: new Date(),
      stateVersion: { increment: 1 },
    };
    if (previous.gameKey === AADU_PULI_GAME_KEY) {
      deadline = new Date(Date.now() + this.cfg.match.turnTimeoutMs);
      data.serverState = {
        game: AADU_PULI_GAME_KEY,
        state: GameState.initial().serialize(),
        turnDeadlineAt: deadline.toISOString(),
        turnNumber: 0,
      } satisfies AaduPuliServerState;
    }

    const match = await this.prisma.gameMatch.update({
      where: { id: matchId },
      data,
      include: { players: { include: { user: { select: { username: true } } } } },
    });
    this.publishStatus(match, { status: match.status });
    if (deadline) this.armTurn(matchId, deadline);
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
        this.publishStatus(cancelled, { status: cancelled.status });
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
      this.clock.disarmMatch(matchId);
      this.publishStatus(abandoned, { status: abandoned.status });
      return abandoned;
    }

    throw new ConflictException('Match is already finished');
  }

  // -------------------------------------------------------------------------
  // Moves — server-authoritative intake
  // -------------------------------------------------------------------------

  /**
   * Single move intake shared by REST and the WebSocket gateway.
   * Aadu Puli moves are validated against the authoritative engine
   * inside a row lock; other games keep the generic envelope rules.
   * The client never determines legality, turn order or a result.
   */
  async submitMove(userId: string, matchId: string, dto: SubmitMoveDto) {
    if (!dto.payload || typeof dto.payload !== 'object') {
      throw new BadRequestException('payload must be an object');
    }
    if (dto.clientSeq !== undefined && (!Number.isInteger(dto.clientSeq) || dto.clientSeq < 1)) {
      throw new BadRequestException('clientSeq must be a positive integer');
    }
    const preview = await this.requireMatch(matchId, { players: true });
    if (preview.gameKey === AADU_PULI_GAME_KEY) {
      return this.submitAaduPuliMove(userId, matchId, dto);
    }
    return this.submitGenericMove(userId, preview, dto);
  }

  /** Legacy envelope rules for games without a rules engine. */
  private async submitGenericMove(userId: string, match: GameMatch & { players: MatchPlayer[] }, dto: SubmitMoveDto) {
    if (match.status !== 'ACTIVE') throw new ConflictException('Match is not active');

    const player = match.players.find((p) => p.userId === userId);
    if (!player) throw new ForbiddenException('Only match participants can move');
    if (player.result === 'ABANDONED') throw new ForbiddenException('You left this match');

    const existing = await this.prisma.matchMove.count({ where: { matchId: match.id } });
    const seq = existing + 1;
    if (dto.clientSeq !== undefined && dto.clientSeq !== seq) {
      throw new ConflictException(`Out of order move: expected seq ${seq}`);
    }

    const created = await this.prisma.$transaction(async (tx) => {
      const move = await tx.matchMove.create({
        data: {
          matchId: match.id,
          seq,
          matchPlayerId: player.id,
          userId,
          payload: dto.payload as Prisma.InputJsonValue,
        },
      });
      const updated = await tx.gameMatch.update({
        where: { id: match.id },
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
      matchId: match.id,
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

  /**
   * Aadu Puli intake: everything happens under a row lock so two
   * simultaneous submits cannot both observe the same position —
   * exactly one is accepted, the other fails on turn/sequence checks.
   */
  private async submitAaduPuliMove(userId: string, matchId: string, dto: SubmitMoveDto) {
    const outcome = await this.prisma.$transaction(async (tx) => {
      await tx.$queryRaw`SELECT id FROM GameMatch WHERE id = ${matchId} FOR UPDATE`;
      const match = await tx.gameMatch.findUnique({
        where: { id: matchId },
        include: { players: true },
      });
      if (!match) throw new NotFoundException('Match not found');
      if (match.status !== 'ACTIVE') throw new ConflictException('Match is not active');

      const player = match.players.find((p) => p.userId === userId);
      if (!player) throw new ForbiddenException('Only match participants can move');
      if (player.result === 'ABANDONED') throw new ForbiddenException('You left this match');

      const serverState = match.serverState as AaduPuliServerState | null;
      if (!serverState || serverState.game !== AADU_PULI_GAME_KEY || !serverState.state) {
        throw new ConflictException('Match state is not initialised');
      }
      const state = GameState.deserialize(serverState.state);
      if (!state) throw new ConflictException('Match state is corrupt');
      if (state.result !== GameResult.NONE) throw new ConflictException('Match is already finished');

      const moveCount = await tx.matchMove.count({ where: { matchId } });
      const seq = moveCount + 1;
      if (dto.clientSeq !== undefined && dto.clientSeq !== seq) {
        throw new ConflictException(`Out of order move: expected seq ${seq}`);
      }

      const mySide = sideForSeat(player.seat);
      if (state.sideToMove !== mySide) throw new ForbiddenException('Not your turn');

      const move = Move.fromWire(dto.payload);
      if (!move) throw new BadRequestException('Malformed move payload');
      const verdict = validate(state, move);
      if (!verdict.ok) throw new BadRequestException(errorText(verdict.issue));
      const next = AaduPuliRules.apply(state, move);
      if (!next) throw new BadRequestException('Illegal move');

      const completion = completionFor(next);
      const deadline = new Date(Date.now() + this.cfg.match.turnTimeoutMs);
      const nextState: AaduPuliServerState = {
        game: AADU_PULI_GAME_KEY,
        state: next.serialize(),
        turnDeadlineAt: deadline.toISOString(),
        turnNumber: next.ply,
        ...(serverState.rematchMatchId ? { rematchMatchId: serverState.rematchMatchId } : {}),
        ...(completion
          ? { completed: { reason: completion.reason, winnerSeat: completion.winnerSeat } }
          : {}),
      };

      const moveRow = await tx.matchMove.create({
        data: {
          matchId,
          seq,
          matchPlayerId: player.id,
          userId,
          payload: dto.payload as Prisma.InputJsonValue,
          stateHash: stateHash(next.serialize()),
        },
      });

      const updated = await tx.gameMatch.update({
        where: { id: matchId },
        data: {
          stateVersion: { increment: 1 },
          serverState: nextState as unknown as Prisma.InputJsonValue,
          ...(completion ? { status: 'COMPLETED', completedAt: new Date() } : {}),
        },
      });

      let results: Map<string, 'WIN' | 'LOSS' | 'DRAW'> | null = null;
      if (completion) {
        results = await this.applyCompletion(tx, match.players, completion);
      }

      return {
        seq,
        stateVersion: updated.stateVersion,
        notation: move.notation(),
        state: next.serialize(),
        sideToMove: (next.sideToMove === Side.GOATS ? 'goats' : 'tigers') as 'goats' | 'tigers',
        turnDeadlineAt: nextState.turnDeadlineAt,
        ply: next.ply,
        serverAt: moveRow.serverAt.toISOString(),
        completion,
        results,
      };
    });

    if (outcome.completion) {
      this.clock.disarmMatch(matchId);
      this.publishCompletion(matchId, outcome.stateVersion, outcome.completion, outcome.results!);
    } else {
      this.armTurn(matchId, new Date(outcome.turnDeadlineAt));
    }

    this.events.publish({
      kind: 'move',
      data: {
        matchId,
        seq: outcome.seq,
        stateVersion: outcome.stateVersion,
        userId,
        payload: dto.payload,
        at: outcome.serverAt,
        notation: outcome.notation,
        state: outcome.state,
        sideToMove: outcome.sideToMove,
        turnDeadlineAt: outcome.turnDeadlineAt,
      },
    });

    return {
      move: {
        seq: outcome.seq,
        userId,
        payload: dto.payload,
        notation: outcome.notation,
        serverAt: outcome.serverAt,
      },
      stateVersion: outcome.stateVersion,
      state: outcome.state,
      sideToMove: outcome.sideToMove,
      turnDeadlineAt: outcome.turnDeadlineAt,
      ply: outcome.ply,
      ...(outcome.completion
        ? {
            completed: {
              reason: outcome.completion.reason,
              winnerSeat: outcome.completion.winnerSeat,
              results: Object.fromEntries(outcome.results!),
            },
          }
        : {}),
    };
  }

  // -------------------------------------------------------------------------
  // Match endings — every path is server-decided
  // -------------------------------------------------------------------------

  /** A participant resigns: the opponent wins, server records everything. */
  async resign(userId: string, matchId: string) {
    const outcome = await this.prisma.$transaction(async (tx) => {
      await tx.$queryRaw`SELECT id FROM GameMatch WHERE id = ${matchId} FOR UPDATE`;
      const match = await tx.gameMatch.findUnique({ where: { id: matchId }, include: { players: true } });
      if (!match) throw new NotFoundException('Match not found');
      if (match.status !== 'ACTIVE') throw new ConflictException('Match is not active');
      const player = match.players.find((p) => p.userId === userId);
      if (!player) throw new ForbiddenException('You are not in this match');

      const winnerSeat = player.seat === 0 ? 1 : 0;
      const completion: MatchCompletion = { winnerSeat, reason: 'RESIGN' };
      const results = await this.applyCompletion(tx, match.players, completion);
      const updated = await tx.gameMatch.update({
        where: { id: matchId },
        data: {
          status: 'COMPLETED',
          completedAt: new Date(),
          stateVersion: { increment: 1 },
          serverState: this.completedServerState(match.serverState, completion),
        },
      });
      return { stateVersion: updated.stateVersion, completion, results };
    });

    this.clock.disarmMatch(matchId);
    this.publishCompletion(matchId, outcome.stateVersion, outcome.completion, outcome.results);
    return outcome;
  }

  /** Turn deadline passed: the side to move loses on time. */
  async onTurnTimeout(matchId: string): Promise<void> {
    try {
      const outcome = await this.prisma.$transaction(async (tx) => {
        await tx.$queryRaw`SELECT id FROM GameMatch WHERE id = ${matchId} FOR UPDATE`;
        const match = await tx.gameMatch.findUnique({ where: { id: matchId }, include: { players: true } });
        if (!match || match.status !== 'ACTIVE') return null;
        const serverState = match.serverState as AaduPuliServerState | null;
        if (!serverState?.turnDeadlineAt) return null;
        const deadline = Date.parse(serverState.turnDeadlineAt);
        if (Number.isFinite(deadline) && Date.now() + 25 < deadline) {
          return { rearm: new Date(deadline), completion: null, results: null, stateVersion: 0 };
        }
        const state = GameState.deserialize(serverState.state);
        if (!state || state.result !== GameResult.NONE) return null;
        const loserSeat = seatForSide(state.sideToMove);
        const completion: MatchCompletion = { winnerSeat: loserSeat === 0 ? 1 : 0, reason: 'TIMEOUT' };
        const results = await this.applyCompletion(tx, match.players, completion);
        const updated = await tx.gameMatch.update({
          where: { id: matchId },
          data: {
            status: 'COMPLETED',
            completedAt: new Date(),
            stateVersion: { increment: 1 },
            serverState: this.completedServerState(match.serverState, completion),
          },
        });
        return { rearm: null, completion, results, stateVersion: updated.stateVersion };
      });

      if (!outcome) return;
      if (outcome.completion) {
        this.clock.disarmMatch(matchId);
        this.publishCompletion(matchId, outcome.stateVersion, outcome.completion, outcome.results!);
      } else if (outcome.rearm) {
        this.armTurn(matchId, outcome.rearm);
      }
    } catch (error) {
      this.logger.error(`turn timeout failed for ${matchId}: ${String(error)}`);
    }
  }

  /** Disconnect grace expired with the player still absent: they lose. */
  async forfeitByDisconnect(matchId: string, userId: string): Promise<void> {
    try {
      const outcome = await this.prisma.$transaction(async (tx) => {
        await tx.$queryRaw`SELECT id FROM GameMatch WHERE id = ${matchId} FOR UPDATE`;
        const match = await tx.gameMatch.findUnique({ where: { id: matchId }, include: { players: true } });
        if (!match || match.status !== 'ACTIVE') return null;
        const player = match.players.find((p) => p.userId === userId);
        if (!player) return null;
        const completion: MatchCompletion = {
          winnerSeat: player.seat === 0 ? 1 : 0,
          reason: 'DISCONNECT',
        };
        const results = await this.applyCompletion(tx, match.players, completion);
        const updated = await tx.gameMatch.update({
          where: { id: matchId },
          data: {
            status: 'COMPLETED',
            completedAt: new Date(),
            stateVersion: { increment: 1 },
            serverState: this.completedServerState(match.serverState, completion),
          },
        });
        return { completion, results, stateVersion: updated.stateVersion };
      });
      if (!outcome) return;
      this.clock.disarmMatch(matchId);
      this.publishCompletion(matchId, outcome.stateVersion, outcome.completion, outcome.results);
    } catch (error) {
      this.logger.error(`disconnect forfeit failed for ${matchId}: ${String(error)}`);
  }
  }

  /**
   * Rematch: creates a fresh match with the same players and swapped
   * seats (the previous loser gets the goats, which move first).
   * Idempotent per completed match — a second request returns the
   * existing rematch.
   */
  async rematch(userId: string, matchId: string): Promise<MatchWithPlayers> {
    const match = await this.requireMatch(matchId, {
      players: { include: { user: { select: { username: true } } } },
    });
    if (match.status !== 'COMPLETED') {
      throw new ConflictException('Only a completed match can be rematched');
    }
    if (!match.players.some((p) => p.userId === userId)) {
      throw new ForbiddenException('You are not in this match');
    }

    const previous = match.serverState as AaduPuliServerState | null;
    if (previous?.rematchMatchId) {
      const existing = await this.prisma.gameMatch.findUnique({
        where: { id: previous.rematchMatchId },
        include: { players: { include: { user: { select: { username: true } } } } },
      });
      if (existing) return existing;
    }

    const ordered = [...match.players].sort((a, b) => a.seat - b.seat);
    const created = await this.prisma.$transaction(async (tx) => {
      await tx.$queryRaw`SELECT id FROM GameMatch WHERE id = ${matchId} FOR UPDATE`;
      const locked = await tx.gameMatch.findUnique({ where: { id: matchId } });
      const lockedState = locked?.serverState as AaduPuliServerState | null;
      if (lockedState?.rematchMatchId) return { existingId: lockedState.rematchMatchId as string };
      const newMatch = await tx.gameMatch.create({
        data: {
          gameId: match.gameId,
          gameKey: match.gameKey,
          mode: match.mode,
          createdByUserId: userId,
          players: { create: ordered.map((p) => ({ userId: p.userId, seat: 1 - p.seat })) },
        },
        include: { players: { include: { user: { select: { username: true } } } } },
      });
      await tx.gameMatch.update({
        where: { id: matchId },
        data: {
          serverState: {
            ...(lockedState ?? {}),
            rematchMatchId: newMatch.id,
          } as unknown as Prisma.InputJsonValue,
        },
      });
      return { newMatch };
    });

    if ('existingId' in created) {
      const existing = await this.prisma.gameMatch.findUnique({
        where: { id: created.existingId },
        include: { players: { include: { user: { select: { username: true } } } } },
      });
      if (existing) return existing;
    }

    const newMatch = (created as { newMatch: MatchWithPlayers }).newMatch;
    const active = await this.activate(newMatch.id);
    this.events.publish({
      kind: 'rematch',
      data: { matchId, newMatchId: active.id, at: new Date().toISOString() },
    });
    return active;
  }

  // -------------------------------------------------------------------------
  // Snapshots and helpers
  // -------------------------------------------------------------------------

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

  /** Re-arms a missing turn clock (called on every (re)subscribe). */
  async ensureTurnClock(matchId: string): Promise<void> {
    const match = await this.prisma.gameMatch.findUnique({ where: { id: matchId } });
    if (!match || match.status !== 'ACTIVE' || match.gameKey !== AADU_PULI_GAME_KEY) return;
    const serverState = match.serverState as AaduPuliServerState | null;
    if (!serverState?.turnDeadlineAt) return;
    this.armTurn(matchId, new Date(serverState.turnDeadlineAt));
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

  /** Records WIN/LOSS/DRAW for both players and updates profiles (server-side only). */
  private async applyCompletion(
    tx: Prisma.TransactionClient,
    players: MatchPlayer[],
    completion: MatchCompletion,
  ): Promise<Map<string, 'WIN' | 'LOSS' | 'DRAW'>> {
    const results = new Map<string, 'WIN' | 'LOSS' | 'DRAW'>();
    for (const player of players) {
      const result: 'WIN' | 'LOSS' | 'DRAW' =
        completion.winnerSeat === null
          ? 'DRAW'
          : player.seat === completion.winnerSeat
            ? 'WIN'
            : 'LOSS';
      results.set(player.userId, result);
      await tx.matchPlayer.update({ where: { id: player.id }, data: { result } });
    }

    // Rating + record: computed and written exclusively on the server.
    const userIds = players.map((p) => p.userId);
    const profiles = await tx.profile.findMany({ where: { userId: { in: userIds } } });
    const ratingOf = (userId: string): number =>
      profiles.find((p) => p.userId === userId)?.rating ?? 1000;
    const ratings = new Map(userIds.map((id) => [id, ratingOf(id)]));

    for (const player of players) {
      const opponentId = userIds.find((id) => id !== player.userId) ?? player.userId;
      const my = ratings.get(player.userId)!;
      const opp = ratings.get(opponentId)!;
      const result = results.get(player.userId)!;
      const score = result === 'WIN' ? 1 : result === 'LOSS' ? 0 : 0.5;
      const expected = 1 / (1 + Math.pow(10, (opp - my) / 400));
      const delta = Math.round(ELO_K * (score - expected));
      await tx.profile.updateMany({
        where: { userId: player.userId },
        data: {
          gamesPlayed: { increment: 1 },
          ...(result === 'WIN'
            ? { wins: { increment: 1 } }
            : result === 'LOSS'
              ? { losses: { increment: 1 } }
              : { draws: { increment: 1 } }),
          rating: { increment: delta },
        },
      });
    }
    return results;
  }

  private armTurn(matchId: string, deadline: Date): void {
    this.clock.armTurn(matchId, deadline, () => {
      void this.onTurnTimeout(matchId);
    });
  }

  private completedServerState(
    previous: unknown,
    completion: MatchCompletion,
  ): Prisma.InputJsonValue {
    const base = (previous ?? {}) as AaduPuliServerState;
    return {
      ...base,
      completed: { reason: completion.reason, winnerSeat: completion.winnerSeat },
    } as Prisma.InputJsonValue;
  }

  private publishCompletion(
    matchId: string,
    stateVersion: number,
    completion: MatchCompletion,
    results: Map<string, 'WIN' | 'LOSS' | 'DRAW'>,
  ): void {
    this.events.publish({
      kind: 'status',
      data: {
        matchId,
        status: 'COMPLETED',
        stateVersion,
        at: new Date().toISOString(),
        completed: {
          reason: completion.reason,
          winnerSeat: completion.winnerSeat,
          results: Object.fromEntries(results),
        },
      },
    });
  }

  private publishStatus(match: GameMatch, extra: { status: string }): void {
    this.events.publish({
      kind: 'status',
      data: {
        matchId: match.id,
        status: extra.status,
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

/** Seat 0 plays the goats (which move first); seat 1 plays the tigers. */
export function sideForSeat(seat: number): Side {
  return seat === 0 ? Side.GOATS : Side.TIGERS;
}

export function seatForSide(side: Side): number {
  return side === Side.GOATS ? 0 : 1;
}

/** Server-decided result for a finished engine state. */
export function completionFor(state: GameState): MatchCompletion | null {
  if (state.result === GameResult.NONE) return null;
  if (state.result === GameResult.DRAW) return { winnerSeat: null, reason: 'RULES' };
  return {
    winnerSeat: state.result === GameResult.GOATS_WIN ? 0 : 1,
    reason: 'RULES',
  };
}

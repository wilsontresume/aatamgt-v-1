import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { GameMatch, MatchPlayer, MatchStatus, Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { GamesService } from '../games/games.service';
import { MatchEventsService } from '../events/match-events.service';
import { MatchClockService } from './match-clock.service';
import { RankingsService } from '../rankings/rankings.service';
import { AnalyticsService } from '../analytics/analytics.service';
import { WalletService } from '../wallet/wallet.service';
import { TiersService } from '../matchmaking/tiers.service';
import { AppConfig } from '../config/configuration';
import {
  CompletionReason,
  EngineAdapter,
  MatchCompletion,
  getAdapter,
  isEngineGame,
} from './engine-adapters';

export { AADU_PULI_GAME_KEY, SOLAH_SEEDI_GAME_KEY } from './engine-adapters';
export type { CompletionReason } from './engine-adapters';

export interface CreateMatchDto {
  gameKey: string;
  mode?: 'CASUAL' | 'RANKED' | 'PRIVATE';
  stakeCoins?: number;
  /** Tier identifier preserved on the match row (matchmaking/challenges). */
  tierId?: string;
}

export interface CreateWithAiDto extends CreateMatchDto {
  /** Stable display name for the AI seat, e.g. GuestA7K2P. */
  aiName: string;
}

export interface SubmitMoveDto {
  payload: Record<string, unknown>;
  clientSeq?: number;
}

export type MatchWithPlayers = GameMatch & {
  players: (MatchPlayer & { user: { username: string } | null })[];
};

/** Server-owned match state for a rules-engine game (stored as JSON). */
export interface EngineServerState {
  game: string;
  state: unknown;
  turnDeadlineAt: string;
  turnNumber: number;
  completed?: { reason: CompletionReason; winnerSeat: number | null };
  rematchMatchId?: string;
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
    private readonly rankings: RankingsService,
    private readonly analytics: AnalyticsService,
    private readonly wallet: WalletService,
    private readonly tiers: TiersService,
    config: ConfigService,
  ) {
    this.cfg = config.get<AppConfig>('app') as AppConfig;
  }

  async create(userId: string, dto: CreateMatchDto): Promise<MatchWithPlayers> {
    const game = await this.games.getByKey(dto.gameKey);
    if (game.status !== 'ACTIVE') throw new ConflictException('Game is not available');

    // Server-authoritative stake: when a tier is selected the DB tier is the
    // only source of the stake amount — client-sent stakeCoins is ignored.
    let stakeCoins = Math.max(0, Math.floor(dto.stakeCoins ?? 0));
    let tierId: string | null = dto.tierId ?? null;
    if (tierId) {
      const tier = await this.tiers.requireActiveForGame(tierId, game.key);
      stakeCoins = tier.costCoins;
      tierId = tier.id;
    }

    const match = await this.prisma.gameMatch.create({
      data: {
        gameId: game.id,
        gameKey: game.key,
        mode: dto.mode ?? 'CASUAL',
        stakeCoins,
        tierId,
        createdByUserId: userId,
        players: { create: { userId, seat: 0 } },
      },
      include: { players: { include: { user: { select: { username: true } } } } },
    });

    if (game.minPlayers <= 1) return this.activate(match.id);
    return match;
  }

  /**
   * Matchmaking AI fallback: creates a PENDING match with the human in
   * seat 0 and an AI seat (no User row), then activates immediately.
   * The AI is flagged in MatchPlayer.isAi and never counted as a human
   * account.
   */
  async createWithAiOpponent(userId: string, dto: CreateWithAiDto): Promise<MatchWithPlayers> {
    const game = await this.games.getByKey(dto.gameKey);
    if (game.status !== 'ACTIVE') throw new ConflictException('Game is not available');
    if (!getAdapter(game.key)) throw new ConflictException('Game has no server engine');

    // Server-authoritative stake (same rule as create()).
    let stakeCoins = Math.max(0, Math.floor(dto.stakeCoins ?? 0));
    let tierId: string | null = dto.tierId ?? null;
    if (tierId) {
      const tier = await this.tiers.requireActiveForGame(tierId, game.key);
      stakeCoins = tier.costCoins;
      tierId = tier.id;
    }

    const match = await this.prisma.gameMatch.create({
      data: {
        gameId: game.id,
        gameKey: game.key,
        mode: dto.mode ?? 'CASUAL',
        stakeCoins,
        tierId,
        createdByUserId: userId,
        players: {
          create: [
            { userId, seat: 0 },
            { userId: null, seat: 1, isAi: true, aiName: dto.aiName },
          ],
        },
      },
      include: { players: { include: { user: { select: { username: true } } } } },
    });
    return this.activate(match.id);
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
    const engine = getAdapter(previous.gameKey);
    if (engine) {
      deadline = new Date(Date.now() + this.cfg.match.turnTimeoutMs);
      data.serverState = {
        game: engine.gameKey,
        state: engine.initialState() as Prisma.InputJsonValue,
        turnDeadlineAt: deadline.toISOString(),
        turnNumber: 0,
      } satisfies EngineServerState;
    }

    const match = await this.prisma.gameMatch.update({
      where: { id: matchId },
      data,
      include: { players: { include: { user: { select: { username: true } } } } },
    });

    // Stake debit is server-authoritative and idempotent per match.
    if (previous.stakeCoins > 0) {
      for (const player of match.players) {
        if (player.isAi || !player.userId) continue;
        try {
          await this.wallet.debit(player.userId, previous.stakeCoins, {
            type: 'MATCH_REWARD',
            refType: 'match_stake',
            refId: match.id,
            idempotencyKey: `match_stake:${match.id}:${player.userId}`,
            memo: `Stake for match ${match.id}`,
          });
        } catch (error) {
          this.logger.error(`stake debit failed for ${player.userId}: ${String(error)}`);
          throw new ConflictException('Unable to lock stake coins for this match');
        }
      }
    }

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
      // Voluntary mid-match leave is a resignation. The server decides
      // the result — the opponent wins, records and ratings update — so
      // a losing player cannot dodge a recorded loss by leaving instead
      // of resigning, which is exactly the penalty the disconnect-grace
      // path applies to players who merely drop their socket.
      try {
        await this.completeByResignation(userId, matchId);
      } catch (error) {
        // The match finished while we raced it (turn clock, resign,
        // admin finalize): surface its current state instead of failing.
        const fresh = await this.requireMatch(matchId, {
          players: { include: { user: { select: { username: true } } } },
        });
        if (fresh.status === 'ACTIVE') throw error;
        return fresh;
      }
      return this.requireMatch(matchId, {
        players: { include: { user: { select: { username: true } } } },
      });
    }

    throw new ConflictException('Match is already finished');
  }

  // -------------------------------------------------------------------------
  // Moves — server-authoritative intake
  // -------------------------------------------------------------------------

  /**
   * Single move intake shared by REST and the WebSocket gateway.
   * Rules-engine games are validated by their adapter inside a row
   * lock; other games keep the generic envelope rules.
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
    const engine = getAdapter(preview.gameKey);
    if (engine) {
      return this.submitEngineMove(userId, matchId, dto, engine);
    }
    return this.submitGenericMove(userId, preview, dto);
  }

  /**
   * Server-driven AI move. Only the AI driver calls this; the payload is
   * generated from the same engine and re-validated inside the row lock
   * exactly like a human move. The AI MatchPlayer row (isAi=true) must
   * exist and be the side to move.
   */
  async submitAiMove(matchId: string, matchPlayerId: string, payload: Record<string, unknown>) {
    const engine = getAdapter(
      (await this.requireMatch(matchId, { players: false })).gameKey,
    );
    if (!engine) throw new ConflictException('Game has no server engine');
    const outcome = await this.prisma.$transaction(async (tx) => {
      await tx.$queryRaw`SELECT id FROM GameMatch WHERE id = ${matchId} FOR UPDATE`;
      const match = await tx.gameMatch.findUnique({
        where: { id: matchId },
        include: { players: true },
      });
      if (!match) throw new NotFoundException('Match not found');
      if (match.status !== 'ACTIVE') throw new ConflictException('Match is not active');
      const seat = match.players.find((p) => p.id === matchPlayerId && p.isAi);
      if (!seat) throw new ForbiddenException('Not an AI seat');
      return this.engineTurn(tx, match, seat, payload, undefined, engine, null);
    });

    if (outcome.completion) {
      this.clock.disarmMatch(matchId);
      this.publishCompletion(
        matchId,
        outcome.stateVersion,
        outcome.completion,
        outcome.results!,
        engine.gameKey,
      );
      await this.creditMatchRewards(matchId, outcome.completion);
    } else {
      this.armTurn(matchId, new Date(outcome.turnDeadlineAt));
      this.events.publish({
        kind: 'move',
        data: {
          matchId,
          seq: outcome.seq,
          stateVersion: outcome.stateVersion,
          userId: null,
          payload,
          at: outcome.serverAt,
          notation: outcome.notation,
          state: outcome.state,
          sideToMove: outcome.sideToMove,
          turnDeadlineAt: outcome.turnDeadlineAt,
        },
      });
    }

    // When the AI seat is next to move, the driver reacts to the move event.
    // Publishing here (completion path already returned) keeps the event
    // stream consistent for AI and human moves alike.

    return {
      move: {
        seq: outcome.seq,
        userId: null,
        payload,
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

  /**
   * Shared authoritative engine turn: parse → check → apply → persist
   * under the caller's row lock. `userId` is the acting user for human
   * moves, or null for server-driven AI moves.
   */
  private async engineTurn(
    tx: Prisma.TransactionClient,
    match: GameMatch & { players: MatchPlayer[] },
    player: MatchPlayer,
    payload: Record<string, unknown>,
    clientSeq: number | undefined,
    engine: EngineAdapter,
    userId: string | null,
  ) {
    const matchId = match.id;
    const serverState = match.serverState as EngineServerState | null;
    if (!serverState || serverState.game !== engine.gameKey || !serverState.state) {
      throw new ConflictException('Match state is not initialised');
    }
    const view = engine.load(serverState.state);
    if (!view) throw new ConflictException('Match state is corrupt');
    if (view.finished) throw new ConflictException('Match is already finished');

    const moveCount = await tx.matchMove.count({ where: { matchId } });
    const seq = moveCount + 1;
    if (clientSeq !== undefined && clientSeq !== seq) {
      throw new ConflictException(`Out of order move: expected seq ${seq}`);
    }

    if (view.seatToMove !== player.seat) throw new ForbiddenException('Not your turn');

    const move = engine.parseMove(payload);
    if (!move) throw new BadRequestException('Malformed move payload');
    const issue = engine.check(view, move);
    if (issue) throw new BadRequestException(issue);
    const nextView = engine.apply(view, move);
    if (!nextView) throw new BadRequestException('Illegal move');

    const completion = engine.completion(nextView);
    const deadline = new Date(Date.now() + this.cfg.match.turnTimeoutMs);
    const nextState: EngineServerState = {
      game: engine.gameKey,
      state: nextView.raw,
      turnDeadlineAt: deadline.toISOString(),
      turnNumber: nextView.ply,
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
        payload: payload as Prisma.InputJsonValue,
        stateHash: nextView.hash,
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
      results = await this.applyCompletion(tx, match, completion);
    }

    return {
      seq,
      stateVersion: updated.stateVersion,
      notation: engine.notation(move),
      state: nextView.raw,
      sideToMove: nextView.sideKey,
      turnDeadlineAt: nextState.turnDeadlineAt,
      ply: nextView.ply,
      serverAt: moveRow.serverAt.toISOString(),
      completion,
      results,
    };
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
   * Rules-engine intake: everything happens under a row lock so two
   * simultaneous submits cannot both observe the same position —
   * exactly one is accepted, the other fails on turn/sequence checks.
   */
  private async submitEngineMove(
    userId: string,
    matchId: string,
    dto: SubmitMoveDto,
    engine: EngineAdapter,
  ) {
    const outcome = await this.prisma.$transaction(async (tx) => {
      await tx.$queryRaw`SELECT id FROM GameMatch WHERE id = ${matchId} FOR UPDATE`;
      const match = await tx.gameMatch.findUnique({
        where: { id: matchId },
        include: { players: true },
      });
      if (!match) throw new NotFoundException('Match not found');
      if (match.status !== 'ACTIVE') throw new ConflictException('Match is not active');

      const player = match.players.find((p) => p.userId === userId && !p.isAi);
      if (!player) throw new ForbiddenException('Only match participants can move');
      if (player.result === 'ABANDONED') throw new ForbiddenException('You left this match');

      return this.engineTurn(tx, match, player, dto.payload, dto.clientSeq, engine, userId);
    });

    if (outcome.completion) {
      this.clock.disarmMatch(matchId);
      this.publishCompletion(
        matchId,
        outcome.stateVersion,
        outcome.completion,
        outcome.results!,
        engine.gameKey,
      );
      await this.creditMatchRewards(matchId, outcome.completion);
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
    return this.completeByResignation(userId, matchId);
  }

  /**
   * Shared server-decided completion for voluntary exits (resign, and
   * REST leave during an ACTIVE match): row-locked, opponent wins,
   * profiles/ratings/rankings updated in the same transaction.
   */
  private async completeByResignation(userId: string, matchId: string) {
    const outcome = await this.prisma.$transaction(async (tx) => {
      await tx.$queryRaw`SELECT id FROM GameMatch WHERE id = ${matchId} FOR UPDATE`;
      const match = await tx.gameMatch.findUnique({ where: { id: matchId }, include: { players: true } });
      if (!match) throw new NotFoundException('Match not found');
      if (match.status !== 'ACTIVE') throw new ConflictException('Match is not active');
      const player = match.players.find((p) => p.userId === userId);
      if (!player) throw new ForbiddenException('You are not in this match');

      const winnerSeat = player.seat === 0 ? 1 : 0;
      const completion: MatchCompletion = { winnerSeat, reason: 'RESIGN' };
      const results = await this.applyCompletion(tx, match, completion);
      const updated = await tx.gameMatch.update({
        where: { id: matchId },
        data: {
          status: 'COMPLETED',
          completedAt: new Date(),
          stateVersion: { increment: 1 },
          serverState: this.completedServerState(match.serverState, completion),
        },
      });
      return { stateVersion: updated.stateVersion, completion, results, gameKey: match.gameKey };
    });

    this.clock.disarmMatch(matchId);
    this.publishCompletion(
      matchId,
      outcome.stateVersion,
      outcome.completion,
      outcome.results,
      outcome.gameKey,
    );
    await this.creditMatchRewards(matchId, outcome.completion);
    return outcome;
  }

  /** Turn deadline passed: the side to move loses on time. */
  async onTurnTimeout(matchId: string): Promise<void> {
    try {
      const outcome = await this.prisma.$transaction(async (tx) => {
        await tx.$queryRaw`SELECT id FROM GameMatch WHERE id = ${matchId} FOR UPDATE`;
        const match = await tx.gameMatch.findUnique({ where: { id: matchId }, include: { players: true } });
        if (!match || match.status !== 'ACTIVE') return null;
        const engine = getAdapter(match.gameKey);
        if (!engine) return null;
        const serverState = match.serverState as EngineServerState | null;
        if (!serverState?.turnDeadlineAt) return null;
        const deadline = Date.parse(serverState.turnDeadlineAt);
        if (Number.isFinite(deadline) && Date.now() + 25 < deadline) {
          return {
            rearm: new Date(deadline),
            completion: null,
            results: null,
            stateVersion: 0,
            gameKey: match.gameKey,
          };
        }
        const view = engine.load(serverState.state);
        if (!view || view.finished) return null;
        const loserSeat = view.seatToMove;
        const completion: MatchCompletion = { winnerSeat: loserSeat === 0 ? 1 : 0, reason: 'TIMEOUT' };
        const results = await this.applyCompletion(tx, match, completion);
        const updated = await tx.gameMatch.update({
          where: { id: matchId },
          data: {
            status: 'COMPLETED',
            completedAt: new Date(),
            stateVersion: { increment: 1 },
            serverState: this.completedServerState(match.serverState, completion),
          },
        });
        return {
          rearm: null,
          completion,
          results,
          stateVersion: updated.stateVersion,
          gameKey: match.gameKey,
        };
      });

      if (!outcome) return;
      if (outcome.completion) {
        this.clock.disarmMatch(matchId);
        this.publishCompletion(
          matchId,
          outcome.stateVersion,
          outcome.completion,
          outcome.results!,
          outcome.gameKey,
        );
        await this.creditMatchRewards(matchId, outcome.completion);
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
        const results = await this.applyCompletion(tx, match, completion);
        const updated = await tx.gameMatch.update({
          where: { id: matchId },
          data: {
            status: 'COMPLETED',
            completedAt: new Date(),
            stateVersion: { increment: 1 },
            serverState: this.completedServerState(match.serverState, completion),
          },
        });
        return { completion, results, stateVersion: updated.stateVersion, gameKey: match.gameKey };
      });
      if (!outcome) return;
      this.clock.disarmMatch(matchId);
      this.publishCompletion(
        matchId,
        outcome.stateVersion,
        outcome.completion,
        outcome.results,
        outcome.gameKey,
      );
      await this.creditMatchRewards(matchId, outcome.completion);
    } catch (error) {
      this.logger.error(`disconnect forfeit failed for ${matchId}: ${String(error)}`);
    }
  }

  /**
   * Rematch: creates a fresh match with the same players and swapped
   * seats (the previous loser takes seat 0, which moves first in every
   * engine game — goats in Aadu Puli, red in Solah Seedi).
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

    const previous = match.serverState as EngineServerState | null;
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
      const lockedState = locked?.serverState as EngineServerState | null;
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
    void this.analytics.record({
      type: 'rematch',
      userId,
      gameKey: active.gameKey,
      dedupeKey: `rematch:${active.id}`,
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
    if (!match || match.status !== 'ACTIVE' || !isEngineGame(match.gameKey)) return;
    const serverState = match.serverState as EngineServerState | null;
    if (!serverState?.turnDeadlineAt) return;
    this.armTurn(matchId, new Date(serverState.turnDeadlineAt));
  }

  listMy(userId: string, status?: string) {
    if (status && !Object.values(MatchStatus).includes(status as MatchStatus)) {
      throw new BadRequestException('Unknown match status');
    }
    return this.prisma.gameMatch.findMany({
      where: {
        players: { some: { userId } },
        ...(status ? { status: status as MatchStatus } : {}),
      },
      orderBy: { createdAt: 'desc' },
      take: status === 'COMPLETED' ? 50 : 25,
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
      tierId: match.tierId,
      players: match.players.map((p) => ({
        userId: p.userId,
        username: p.isAi ? (p.aiName ?? 'AI') : (p.user?.username ?? ''),
        seat: p.seat,
        team: p.team,
        color: p.color,
        result: p.result,
        score: p.score,
        isAi: p.isAi,
        aiName: p.aiName,
      })),
      startedAt: match.startedAt?.toISOString() ?? null,
      completedAt: match.completedAt?.toISOString() ?? null,
      createdAt: match.createdAt.toISOString(),
    };
  }

  /**
   * Records WIN/LOSS/DRAW for both players and updates profiles
   * (server-side only). AI seats are recorded for the result board but
   * never receive ratings, profile stats or wallet credits — only human
   * participants are ranked and paid.
   */
  private async applyCompletion(
    tx: Prisma.TransactionClient,
    match: { id: string; gameKey: string; players: MatchPlayer[] },
    completion: MatchCompletion,
  ): Promise<Map<string, 'WIN' | 'LOSS' | 'DRAW'>> {
    const players = match.players;
    const results = new Map<string, 'WIN' | 'LOSS' | 'DRAW'>();
    for (const player of players) {
      const result: 'WIN' | 'LOSS' | 'DRAW' =
        completion.winnerSeat === null
          ? 'DRAW'
          : player.seat === completion.winnerSeat
            ? 'WIN'
            : 'LOSS';
      // Key results by a stable participant id; AI seats use their row id.
      const key = player.userId ?? `ai:${player.id}`;
      results.set(key, result);
      await tx.matchPlayer.update({ where: { id: player.id }, data: { result } });
    }

    // Rating + record: computed and written exclusively on the server.
    // AI seats are excluded — they have no User row and must not appear
    // in multiplayer rankings or analytics as real players.
    const humanPlayers = players.filter((p) => !p.isAi && p.userId);
    const userIds = humanPlayers.map((p) => p.userId as string);
    const profiles = await tx.profile.findMany({ where: { userId: { in: userIds } } });
    const ratingOf = (userId: string): number =>
      profiles.find((p) => p.userId === userId)?.rating ?? 1000;
    const ratings = new Map(userIds.map((id) => [id, ratingOf(id)]));

    for (const player of humanPlayers) {
      const uid = player.userId as string;
      // Opponent rating: prefer the other human; fall back to a neutral
      // 1000 when the opponent is AI so Elo still moves sensibly.
      const opponentId =
        userIds.find((id) => id !== uid) ?? null;
      const my = ratings.get(uid)!;
      const opp = opponentId ? ratings.get(opponentId)! : 1000;
      const result = results.get(uid)!;
      const score = result === 'WIN' ? 1 : result === 'LOSS' ? 0 : 0.5;
      const expected = 1 / (1 + Math.pow(10, (opp - my) / 400));
      const delta = Math.round(ELO_K * (score - expected));
      await tx.profile.updateMany({
        where: { userId: uid },
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

    // Competitive per-game ratings (Phase 14): same transaction, guarded
    // by the unique (matchId, userId) event key, rated games only.
    // AI seats are stripped so they never receive competitive ratings.
    const humanResults = new Map(
      [...results.entries()].filter(([key]) => !key.startsWith('ai:')),
    ) as Map<string, 'WIN' | 'LOSS' | 'DRAW'>;
    await this.rankings.applyMatchResult(tx, match, completion, humanResults);
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
    const base = (previous ?? {}) as EngineServerState;
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
    gameKey?: string,
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
    if (gameKey) this.trackCompletionAnalytics(matchId, gameKey, completion, results);
  }

  /**
   * Credits the human winner (if any) with stake × tier multiplier after a
   * completed match. Free tier (stakeCoins 0) is a no-op. Draws refund both
   * stakes; human losses vs AI and AI wins credit nothing. Idempotent per
   * match so completion-path retries cannot double-pay.
   */
  private async creditMatchRewards(matchId: string, completion: MatchCompletion): Promise<void> {
    try {
      const match = await this.prisma.gameMatch.findUnique({
        where: { id: matchId },
        include: { players: true },
      });
      if (!match || !match.tierId || match.stakeCoins <= 0) return;

      const tier = await this.tiers.byId(match.tierId);
      const multBp = tier?.rewardMultiplierBp ?? 10_000;

      const winner =
        completion.winnerSeat === null
          ? null
          : match.players.find((p) => p.seat === completion.winnerSeat);
      if (winner?.userId) {
        const payout = Math.floor((match.stakeCoins * multBp) / 10_000);
        if (payout > 0) {
          await this.wallet.credit(winner.userId, payout, {
            type: 'MATCH_REWARD',
            refType: 'match_reward',
            refId: match.id,
            idempotencyKey: `match_reward:${match.id}`,
            memo: `Winnings for match ${match.id}`,
          });
        }
        return;
      }

      // Draw: refund every human seat's stake.
      if (completion.winnerSeat === null) {
        for (const player of match.players) {
          if (player.isAi || !player.userId) continue;
          await this.wallet.credit(player.userId, match.stakeCoins, {
            type: 'MATCH_REWARD',
            refType: 'match_refund',
            refId: match.id,
            idempotencyKey: `match_refund:${match.id}:${player.userId}`,
            memo: `Draw refund for match ${match.id}`,
          });
        }
      }
    } catch (error) {
      this.logger.error(`reward credit failed for ${matchId}: ${String(error)}`);
    }
  }

  /**
   * Product metrics for a finished online match: one match_completed
   * event per participant (result + completion reason) plus a one-time
   * first_match for anyone completing their first ever match. Fire and
   * forget — analytics never breaks match flow.
   */
  private trackCompletionAnalytics(
    matchId: string,
    gameKey: string,
    completion: MatchCompletion,
    results: Map<string, 'WIN' | 'LOSS' | 'DRAW'>,
  ): void {
    for (const [userId, result] of results) {
      if (userId.startsWith('ai:')) continue;
      void this.analytics.record({
        type: 'match_completed',
        userId,
        gameKey,
        data: { result, reason: completion.reason },
        dedupeKey: `match_completed:${matchId}:${userId}`,
      });
      void this.recordFirstMatch(userId, matchId);
    }
  }

  private async recordFirstMatch(userId: string, matchId: string): Promise<void> {
    try {
      const prior = await this.prisma.analyticsEvent.count({
        where: {
          type: 'match_completed',
          userId,
          NOT: { dedupeKey: `match_completed:${matchId}:${userId}` },
        },
      });
      if (prior === 0) {
        void this.analytics.record({
          type: 'first_match',
          userId,
          dedupeKey: `first_match:${userId}`,
        });
      }
    } catch (error) {
      this.logger.warn(`first_match check failed for ${userId}: ${String(error)}`);
    }
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

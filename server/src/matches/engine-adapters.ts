/**
 * Pluggable server-side rules engines behind the single authoritative
 * match pipeline (MatchesService).
 *
 * Adding a game means implementing one EngineAdapter and registering it
 * below — authentication, wallets, turn clocks, presence, matchmaking
 * and rating stay in the shared layer and are never duplicated per
 * game. Every adapter is a thin façade over a pure rules module: it
 * never mutates state, never decides a result on its own (results come
 * from the engine) and never trusts a client payload.
 */

import {
  AaduPuliRules,
  GameResult as ApGameResult,
  GameState as ApGameState,
  Move as ApMove,
  Side as ApSide,
  errorText as apErrorText,
  stateHash as apStateHash,
  validate as apValidate,
} from '../aadu-puli';
import {
  NineMensMorrisRules,
  GameResult as NmGameResult,
  GameState as NmGameState,
  Move as NmMove,
  Side as NmSide,
  errorText as nmErrorText,
  stateHash as nmStateHash,
  validate as nmValidate,
} from '../nine-mens-morris';
import {
  SolahSeediRules,
  GameResult as SsGameResult,
  GameState as SsGameState,
  Move as SsMove,
  Side as SsSide,
  errorText as ssErrorText,
  stateHash as ssStateHash,
  validate as ssValidate,
} from '../solah-seedi';

/** Game keys with a server-side rules engine. */
export const AADU_PULI_GAME_KEY = 'aadu-puli-aattam';
export const NINE_MENS_MORRIS_GAME_KEY = 'nine-mens-morris';
export const SOLAH_SEEDI_GAME_KEY = 'solah-seedi';

export type CompletionReason = 'RULES' | 'RESIGN' | 'TIMEOUT' | 'DISCONNECT';

/** Server-decided outcome of a finished match. */
export interface MatchCompletion {
  winnerSeat: number | null;
  reason: CompletionReason;
}

/** Side names as they appear on the wire, per game. */
export type EngineSideKey = 'goats' | 'tigers' | 'red' | 'green';

/**
 * One authoritative position as the match pipeline sees it.
 * `opaque` holds the engine's own state object; only the adapter that
 * built the view is allowed to interpret it.
 */
export interface EngineView {
  readonly opaque: unknown;
  /** Serialized position exactly as stored on the match row. */
  readonly raw: unknown;
  /** Side to move, as its wire key. */
  readonly sideKey: EngineSideKey;
  /** Seat to move (seat 0 always moves first in every engine game). */
  readonly seatToMove: number;
  readonly ply: number;
  readonly finished: boolean;
  /** Canonical hash recorded on the move row. */
  readonly hash: string;
}

export interface EngineAdapter {
  readonly gameKey: string;
  /** Serialized opening position written when a match activates. */
  initialState(): unknown;
  /** Rebuilds a stored position; null when the payload is corrupt. */
  load(raw: unknown): EngineView | null;
  /** Wire payload → engine move; null when the payload is malformed. */
  parseMove(payload: unknown): unknown | null;
  /** Legality of `move` in `view`: a user-facing message, or null. */
  check(view: EngineView, move: unknown): string | null;
  /** Applies a checked move; null when the engine rejects it. */
  apply(view: EngineView, move: unknown): EngineView | null;
  /** Canonical notation recorded in history and events. */
  notation(move: unknown): string;
  /** Server-decided result for a finished position, else null. */
  completion(view: EngineView): MatchCompletion | null;
  /** Wire side key for a seat (seat 0 moves first). */
  sideKeyForSeat(seat: number): EngineSideKey;
}

// ---------------------------------------------------------------------------
// Aadu Puli Aattam
// ---------------------------------------------------------------------------

function apView(state: ApGameState): EngineView {
  const raw = state.serialize();
  const goats = state.sideToMove === ApSide.GOATS;
  return {
    opaque: state,
    raw,
    sideKey: goats ? 'goats' : 'tigers',
    seatToMove: goats ? 0 : 1,
    ply: state.ply,
    finished: state.result !== ApGameResult.NONE,
    hash: apStateHash(raw),
  };
}

const aaduPuliAdapter: EngineAdapter = {
  gameKey: AADU_PULI_GAME_KEY,
  initialState: () => ApGameState.initial().serialize(),
  load(raw: unknown) {
    const state = ApGameState.deserialize(raw);
    return state ? apView(state) : null;
  },
  parseMove: (payload) => ApMove.fromWire(payload),
  check(view, move) {
    const verdict = apValidate(view.opaque as ApGameState, (move ?? null) as ApMove | null);
    return verdict.ok ? null : apErrorText(verdict.issue);
  },
  apply(view, move) {
    const next = AaduPuliRules.apply(view.opaque as ApGameState, move as ApMove);
    return next ? apView(next) : null;
  },
  notation: (move) => (move as ApMove).notation(),
  completion(view) {
    const result = (view.opaque as ApGameState).result;
    if (result === ApGameResult.NONE) return null;
    if (result === ApGameResult.DRAW) return { winnerSeat: null, reason: 'RULES' };
    return { winnerSeat: result === ApGameResult.GOATS_WIN ? 0 : 1, reason: 'RULES' };
  },
  sideKeyForSeat: (seat) => (seat === 0 ? 'goats' : 'tigers'),
};

// ---------------------------------------------------------------------------
// Solah Seedi (16 Soldiers)
// ---------------------------------------------------------------------------

function ssView(state: SsGameState): EngineView {
  const raw = state.serialize();
  const red = state.sideToMove === SsSide.RED;
  return {
    opaque: state,
    raw,
    sideKey: red ? 'red' : 'green',
    seatToMove: red ? 0 : 1,
    ply: state.ply,
    finished: state.result !== SsGameResult.NONE,
    hash: ssStateHash(raw),
  };
}

const solahSeediAdapter: EngineAdapter = {
  gameKey: SOLAH_SEEDI_GAME_KEY,
  initialState: () => SsGameState.initial().serialize(),
  load(raw: unknown) {
    const state = SsGameState.deserialize(raw);
    return state ? ssView(state) : null;
  },
  parseMove: (payload) => SsMove.fromWire(payload),
  check(view, move) {
    const verdict = ssValidate(view.opaque as SsGameState, (move ?? null) as SsMove | null);
    return verdict.ok ? null : ssErrorText(verdict.issue);
  },
  apply(view, move) {
    const next = SolahSeediRules.apply(view.opaque as SsGameState, move as SsMove);
    return next ? ssView(next) : null;
  },
  notation: (move) => SolahSeediRules.notation(move as SsMove),
  completion(view) {
    const result = (view.opaque as SsGameState).result;
    if (result === SsGameResult.NONE) return null;
    if (result === SsGameResult.DRAW) return { winnerSeat: null, reason: 'RULES' };
    return { winnerSeat: result === SsGameResult.RED_WIN ? 0 : 1, reason: 'RULES' };
  },
  sideKeyForSeat: (seat) => (seat === 0 ? 'red' : 'green'),
};

// ---------------------------------------------------------------------------
// Nine Men's Morris
// ---------------------------------------------------------------------------

function nmView(state: NmGameState): EngineView {
  const raw = state.serialize();
  const red = state.sideToMove === NmSide.RED;
  return {
    opaque: state,
    raw,
    sideKey: red ? 'red' : 'green',
    seatToMove: red ? 0 : 1,
    ply: state.ply,
    finished: state.result !== NmGameResult.NONE,
    hash: nmStateHash(raw),
  };
}

const nineMensMorrisAdapter: EngineAdapter = {
  gameKey: NINE_MENS_MORRIS_GAME_KEY,
  initialState: () => NmGameState.initial().serialize(),
  load(raw: unknown) {
    const state = NmGameState.deserialize(raw);
    return state ? nmView(state) : null;
  },
  parseMove: (payload) => NmMove.fromWire(payload),
  check(view, move) {
    const verdict = nmValidate(view.opaque as NmGameState, (move ?? null) as NmMove | null);
    return verdict.ok ? null : nmErrorText(verdict.issue);
  },
  apply(view, move) {
    const next = NineMensMorrisRules.apply(view.opaque as NmGameState, move as NmMove);
    return next ? nmView(next) : null;
  },
  notation: (move) => NineMensMorrisRules.notation(move as NmMove),
  completion(view) {
    const result = (view.opaque as NmGameState).result;
    if (result === NmGameResult.NONE) return null;
    if (result === NmGameResult.DRAW) return { winnerSeat: null, reason: 'RULES' };
    return { winnerSeat: result === NmGameResult.RED_WIN ? 0 : 1, reason: 'RULES' };
  },
  sideKeyForSeat: (seat) => (seat === 0 ? 'red' : 'green'),
};

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

const ADAPTERS: Record<string, EngineAdapter> = {
  [AADU_PULI_GAME_KEY]: aaduPuliAdapter,
  [NINE_MENS_MORRIS_GAME_KEY]: nineMensMorrisAdapter,
  [SOLAH_SEEDI_GAME_KEY]: solahSeediAdapter,
};

/** The rules engine behind a game key, or null for envelope-only games. */
export function getAdapter(gameKey: string): EngineAdapter | null {
  return ADAPTERS[gameKey] ?? null;
}

/** True when the game key has a server-side rules engine. */
export function isEngineGame(gameKey: string): boolean {
  return ADAPTERS[gameKey] !== undefined;
}

/**
 * Side name for a participant's seat in a given game. Engine-less games
 * keep the legacy goats/tigers labels so old snapshots stay valid.
 */
export function sideKeyForSeat(gameKey: string, seat: number): EngineSideKey {
  const adapter = getAdapter(gameKey);
  return adapter ? adapter.sideKeyForSeat(seat) : seat === 0 ? 'goats' : 'tigers';
}

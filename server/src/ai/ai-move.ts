/**
 * Server-side AI opponent for matchmaking fallback.
 *
 * Every chosen move is generated from the same authoritative rules
 * engine used for human play (legalMoves + apply) and is re-validated
 * by MatchesService before it is applied — the AI can never inject an
 * illegal move or decide a result. Search is intentionally simple
 * (greedy with a one-ply opponent reply) so it is fast, deterministic-
 * enough for tests and tunable later without touching the match
 * pipeline.
 */

import {
  AaduPuliRules,
  Cell as ApCell,
  GameResult as ApResult,
  GameState as ApState,
  Move as ApMove,
  Side as ApSide,
} from '../aadu-puli';
import {
  NineMensMorrisRules,
  Cell as NmCell,
  GameResult as NmResult,
  GameState as NmState,
  MILLS,
  Move as NmMove,
  Side as NmSide,
} from '../nine-mens-morris';
import {
  GameResult as SsResult,
  GameState as SsState,
  Move as SsMove,
  Cell as SsCell,
  RED_TRIANGLE,
  GREEN_TRIANGLE,
  Side as SsSide,
  SolahSeediRules,
} from '../solah-seedi';
import { getAdapter } from '../matches/engine-adapters';

const WIN_SCORE = 1_000_000;
const JITTER = 0.25;

/** Picks a legal move payload for the AI side in `rawState`, or null. */
export function chooseAiMove(gameKey: string, rawState: unknown): Record<string, unknown> | null {
  const adapter = getAdapter(gameKey);
  if (!adapter) return null;
  const view = adapter.load(rawState);
  if (!view || view.finished) return null;

  switch (gameKey) {
    case 'aadu-puli-aattam': {
      const state = ApState.deserialize(rawState);
      if (!state) return null;
      const move = pickAaduPuliMove(state);
      return move ? (move.toJSON() as unknown as Record<string, unknown>) : null;
    }
    case 'solah-seedi': {
      const state = SsState.deserialize(rawState);
      if (!state) return null;
      const move = pickSolahSeediMove(state);
      return move ? (move.toJSON() as unknown as Record<string, unknown>) : null;
    }
    case 'nine-mens-morris': {
      const state = NmState.deserialize(rawState);
      if (!state) return null;
      const move = pickNineMensMorrisMove(state);
      return move ? (move.toWire() as unknown as Record<string, unknown>) : null;
    }
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------
// Shared helper: score each legal move, assume the opponent answers best
// ---------------------------------------------------------------------------

interface ScoredGame<S, M> {
  legalMoves(state: S): M[];
  apply(state: S, move: M): S | null;
  /** Result for the side that just moved (win/loss/draw from mover's view). */
  resultBonus(state: S, rootMoverWon: boolean, rootMoverLost: boolean, draw: boolean): number | null;
  /** Static evaluation: positive favours the root mover. */
  evaluate(state: S): number;
}

function pickMove<S, M>(state: S, game: ScoredGame<S, M>): M | null {
  const moves = game.legalMoves(state);
  if (moves.length === 0) return null;
  if (moves.length === 1) return moves[0];

  let best = moves[0];
  let bestScore = -Infinity;
  for (const move of moves) {
    const next = game.apply(state, move);
    if (!next) continue;
    let score = game.evaluate(next) + Math.random() * JITTER;
    const terminal = game.resultBonus(next, true, false, false);
    if (terminal !== null) {
      score = terminal;
    } else {
      // Opponent's best immediate reply, from the root mover's view.
      const replies = game.legalMoves(next);
      let worstForRoot = Infinity;
      for (const reply of replies) {
        const after = game.apply(next, reply);
        if (!after) continue;
        const replyTerminal = game.resultBonus(after, false, true, false);
        const s = replyTerminal !== null ? replyTerminal : game.evaluate(after);
        if (s < worstForRoot) worstForRoot = s;
      }
      if (worstForRoot !== Infinity) score += worstForRoot * 0.6;
    }
    if (score > bestScore) {
      bestScore = score;
      best = move;
    }
  }
  return best;
}

// ---------------------------------------------------------------------------
// Aadu Puli Aattam (tigers capture goats; goats immobilise tigers)
// ---------------------------------------------------------------------------

function pickAaduPuliMove(state: ApState): ApMove | null {
  return pickMove<ApState, ApMove>(state, {
    legalMoves: (s) => AaduPuliRules.legalMoves(s),
    apply: (s, m) => AaduPuliRules.apply(s, m),
    resultBonus: (s) => {
      if (s.result === ApResult.NONE) return null;
      if (s.result === ApResult.DRAW) return 0;
      // Root mover is whoever moved first into this state's predecessor;
      // we evaluate relative to the side that just moved by checking the
      // flipped sideToMove vs result winner.
      const winner = s.result === ApResult.GOATS_WIN ? ApSide.GOATS : ApSide.TIGERS;
      const justMoved = s.sideToMove === ApSide.GOATS ? ApSide.TIGERS : ApSide.GOATS;
      return winner === justMoved ? WIN_SCORE : -WIN_SCORE;
    },
    evaluate: (s) => {
      // Positive = good for the side that just moved.
      const justMoved = s.sideToMove === ApSide.GOATS ? ApSide.TIGERS : ApSide.GOATS;
      const tigerMobility = countTigerMobility(s);
      const goatMobility = countGoatMobility(s);
      const tigerScore = s.goatsCaptured * 50 + tigerMobility * 2;
      const goatScore = -s.goatsCaptured * 40 + goatMobility * 1 + s.goatsInHand * 2;
      return justMoved === ApSide.TIGERS ? tigerScore - goatScore : goatScore - tigerScore;
    },
  });
}

function countTigerMobility(s: ApState): number {
  let n = 0;
  for (const tiger of s.tigerPoints()) {
    n += AaduPuliRules.legalMovesFrom(s, tiger).length;
  }
  return n;
}

function countGoatMobility(s: ApState): number {
  if (s.goatsInHand > 0) {
    let empty = 0;
    for (let p = 0; p < s.board.length; p++) if (s.board[p] === ApCell.EMPTY) empty++;
    return empty > 0 ? 1 : 0;
  }
  let n = 0;
  for (const goat of s.goatPoints()) {
    n += AaduPuliRules.legalMovesFrom(s, goat).length;
  }
  return n;
}

// ---------------------------------------------------------------------------
// Solah Seedi (reach the enemy triangle or wipe the enemy out)
// ---------------------------------------------------------------------------

function pickSolahSeediMove(state: SsState): SsMove | null {
  return pickMove<SsState, SsMove>(state, {
    legalMoves: (s) => SolahSeediRules.legalMoves(s),
    apply: (s, m) => SolahSeediRules.apply(s, m),
    resultBonus: (s) => {
      if (s.result === SsResult.NONE) return null;
      if (s.result === SsResult.DRAW) return 0;
      const winner = s.result === SsResult.RED_WIN ? SsSide.RED : SsSide.GREEN;
      const justMoved = s.sideToMove === SsSide.RED ? SsSide.GREEN : SsSide.RED;
      return winner === justMoved ? WIN_SCORE : -WIN_SCORE;
    },
    evaluate: (s) => {
      const justMoved = s.sideToMove === SsSide.RED ? SsSide.GREEN : SsSide.RED;
      const redScore = ssSideScore(s, SsSide.RED);
      const greenScore = ssSideScore(s, SsSide.GREEN);
      return justMoved === SsSide.RED ? redScore - greenScore : greenScore - redScore;
    },
  });
}

function ssSideScore(s: SsState, side: SsSide): number {
  const mine = side === SsSide.RED ? SsCell.RED : SsCell.GREEN;
  // Red wins by landing in the green triangle; green in the red triangle.
  const target = side === SsSide.RED ? GREEN_TRIANGLE : RED_TRIANGLE;
  const home = side === SsSide.RED ? RED_TRIANGLE : GREEN_TRIANGLE;
  let onBoard = 0;
  let inTarget = 0;
  let stuck = 0;
  for (let p = 0; p < s.board.length; p++) {
    const cell = s.board[p];
    if (cell !== mine) continue;
    onBoard++;
    if (target.includes(p)) inTarget++;
    if (home.includes(p)) stuck++;
  }
  return onBoard * 10 + inTarget * 25 - stuck * 3;
}

// ---------------------------------------------------------------------------
// Nine Men's Morris (form mills, starve the opponent below three pieces)
// ---------------------------------------------------------------------------

function pickNineMensMorrisMove(state: NmState): NmMove | null {
  return pickMove<NmState, NmMove>(state, {
    legalMoves: (s) => NineMensMorrisRules.legalMoves(s),
    apply: (s, m) => NineMensMorrisRules.apply(s, m),
    resultBonus: (s) => {
      if (s.result === NmResult.NONE) return null;
      if (s.result === NmResult.DRAW) return 0;
      const winner = s.result === NmResult.RED_WIN ? NmSide.RED : NmSide.GREEN;
      const justMoved = s.sideToMove === NmSide.RED ? NmSide.GREEN : NmSide.RED;
      return winner === justMoved ? WIN_SCORE : -WIN_SCORE;
    },
    evaluate: (s) => {
      const justMoved = s.sideToMove === NmSide.RED ? NmSide.GREEN : NmSide.RED;
      const redScore = nmSideScore(s, NmSide.RED);
      const greenScore = nmSideScore(s, NmSide.GREEN);
      return justMoved === NmSide.RED ? redScore - greenScore : greenScore - redScore;
    },
  });
}

function nmSideScore(s: NmState, side: NmSide): number {
  const cell = side === NmSide.RED ? NmCell.RED : NmCell.GREEN;
  const enemy = side === NmSide.RED ? NmCell.GREEN : NmCell.RED;
  let pieces = 0;
  let mills = 0;
  for (let p = 0; p < s.board.length; p++) {
    if (s.board[p] === cell) pieces++;
  }
  for (const mill of MILLS) {
    if (mill.every((p: number) => s.board[p] === cell)) mills++;
  }
  const hand = s.handOf(side);
  const enemyPieces = s.countPieces(enemy);
  return pieces * 12 + mills * 8 + hand * 6 + (pieces < 3 ? -50 : 0) - enemyPieces * 2;
}

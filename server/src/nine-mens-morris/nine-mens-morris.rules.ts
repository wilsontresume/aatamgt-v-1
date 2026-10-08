/**
 * Board topology, move generation, state transitions and outcome
 * evaluation for Nine Men's Morris. Pure, deterministic rules engine —
 * no I/O, no clocks, no hidden state.
 *
 * Implements docs/nine_mens_morris_rules.md exactly: 24 points, 32
 * edges, 16 mills, three phases, mandatory mill captures and the draw
 * rules of §8.
 */

import { Move, NONE_CAPTURE } from './nine-mens-morris.move';
import {
  Cell,
  GameResult,
  GameState,
  PLIES_TO_DRAW,
  POINT_COUNT,
  Side,
} from './nine-mens-morris.state';
import { validate, Verdict } from './nine-mens-morris.validator';

/** The 32 board edges, each listed once (spec §2). */
export const EDGES: readonly (readonly [number, number])[] = [
  // Outer square.
  [0, 1], [1, 2], [2, 3], [3, 4], [4, 5], [5, 6], [6, 7], [7, 0],
  // Middle square.
  [8, 9], [9, 10], [10, 11], [11, 12], [12, 13], [13, 14], [14, 15], [15, 8],
  // Inner square.
  [16, 17], [17, 18], [18, 19], [19, 20], [20, 21], [21, 22], [22, 23], [23, 16],
  // Radial arms.
  [1, 9], [9, 17], [3, 11], [11, 19], [5, 13], [13, 21], [7, 15], [15, 23],
];

/** The 16 mill lines (spec §5). */
export const MILLS: readonly (readonly number[])[] = [
  [0, 1, 2], [2, 3, 4], [4, 5, 6], [6, 7, 0],
  [8, 9, 10], [10, 11, 12], [12, 13, 14], [14, 15, 8],
  [16, 17, 18], [18, 19, 20], [20, 21, 22], [22, 23, 16],
  [1, 9, 17], [3, 11, 19], [5, 13, 21], [7, 15, 23],
];

export type Phase = 'placement' | 'movement' | 'flying';

export class NineMensMorrisRules {
  private static readonly adjacency = new Map<number, number[]>();
  private static readonly millsThrough = new Map<number, (readonly number[])[]>();

  /** Neighbors of `point` along a single edge, in EDGES order. */
  static neighbors(point: number): number[] {
    NineMensMorrisRules.ensureTables();
    return (NineMensMorrisRules.adjacency.get(point) ?? []).slice();
  }

  static areAdjacent(a: number, b: number): boolean {
    NineMensMorrisRules.ensureTables();
    return (NineMensMorrisRules.adjacency.get(a) ?? []).includes(b);
  }

  /** Mill lines that contain `point`. */
  static millsAt(point: number): readonly (readonly number[])[] {
    NineMensMorrisRules.ensureTables();
    return NineMensMorrisRules.millsThrough.get(point) ?? [];
  }

  /**
   * The phase a side is in (spec §4). Derived from hand and piece
   * count; sides differ while one is still placing.
   */
  static phaseOf(state: GameState, side: Side): Phase {
    if (state.handOf(side) > 0) return 'placement';
    if (state.countSide(side) === 3) return 'flying';
    return 'movement';
  }

  /** True when `mine` occupying `point` completes a mill (spec §5). */
  static millFormedAt(board: readonly number[], point: number, mine: number): boolean {
    NineMensMorrisRules.ensureTables();
    for (const mill of NineMensMorrisRules.millsAt(point)) {
      if (board[mill[0]] === mine && board[mill[1]] === mine && board[mill[2]] === mine) {
        return true;
      }
    }
    return false;
  }

  /**
   * Legal capture targets for `mine` after its mill formed (spec §6):
   * enemy pieces outside mills; when every enemy piece sits in a mill,
   * all of them; empty when the enemy has no piece on the board.
   */
  static captureTargets(board: readonly number[], mine: number): number[] {
    const enemy = mine === Cell.RED ? Cell.GREEN : Cell.RED;
    const enemyPieces: number[] = [];
    const outside: number[] = [];
    for (let p = 0; p < POINT_COUNT; p++) {
      if (board[p] !== enemy) continue;
      enemyPieces.push(p);
      let inMill = false;
      for (const mill of NineMensMorrisRules.millsAt(p)) {
        if (board[mill[0]] === enemy && board[mill[1]] === enemy && board[mill[2]] === enemy) {
          inMill = true;
          break;
        }
      }
      if (!inMill) outside.push(p);
    }
    if (enemyPieces.length === 0) return [];
    return outside.length > 0 ? outside : enemyPieces;
  }

  /**
   * Notation for a validated move (spec §10): `P17`, `P17*22`,
   * `17-18`, `17-18*22` — `*` marks a capture and the number after it
   * is the removed point.
   */
  static notation(move: Move): string {
    if (move.kind === 'place') {
      const base = `P${move.point}`;
      return move.capture === NONE_CAPTURE ? base : `${base}*${move.capture}`;
    }
    const base = `${move.from}-${move.to}`;
    return move.capture === NONE_CAPTURE ? base : `${base}*${move.capture}`;
  }

  /**
   * All legal moves for the side to move, in deterministic order:
   * every placement / step / flight, each paired with every legal
   * capture when its landing forms a mill (mandatory — with the empty
   * exception of a foe-less board). Empty when the game is over.
   */
  static legalMoves(state: GameState | null): Move[] {
    const moves: Move[] = [];
    if (state === null || state.result !== GameResult.NONE) return moves;
    const mine = state.moverCell();
    const phase = NineMensMorrisRules.phaseOf(state, state.sideToMove);

    if (phase === 'placement') {
      for (let p = 0; p < POINT_COUNT; p++) {
        if (!state.isEmpty(p)) continue;
        NineMensMorrisRules.collectForLanding(state.board, mine, 'place', p, NONE_CAPTURE, moves);
      }
      return moves;
    }

    const flying = phase === 'flying';
    for (let origin = 0; origin < POINT_COUNT; origin++) {
      if (state.board[origin] !== mine) continue;
      for (let dest = 0; dest < POINT_COUNT; dest++) {
        if (!state.isEmpty(dest)) continue;
        if (!flying && !NineMensMorrisRules.areAdjacent(origin, dest)) continue;
        NineMensMorrisRules.collectForLanding(state.board, mine, 'move', dest, origin, moves);
      }
    }
    return moves;
  }

  /** Legal moves whose landing point is `point`. */
  static legalMovesLanding(state: GameState, point: number): Move[] {
    return NineMensMorrisRules.legalMoves(state).filter((m) => m.land === point);
  }

  /**
   * Applies a legal move to a fresh state (the input is never mutated).
   * Returns null when the move is not legal. The forced capture happens
   * inside the same turn, then the side toggles, the repetition history
   * grows and the outcome is evaluated (spec §6–§8).
   */
  static apply(state: GameState | null, move: Move): GameState | null {
    const verdict: Verdict = validate(state, move);
    if (state === null || !verdict.ok) return null;

    const next = state.duplicate();
    const mover = state.sideToMove;
    const mine = state.moverCell();

    if (move.kind === 'place') {
      next.board[move.point] = mine;
      next.hands[GameState.sideIndex(mover)] -= 1;
    } else {
      next.board[move.from] = Cell.EMPTY;
      next.board[move.to] = mine;
    }

    const landed = move.land;
    const formed = NineMensMorrisRules.millFormedAt(next.board, landed, mine);
    if (formed && move.capture !== NONE_CAPTURE) {
      next.board[move.capture] = Cell.EMPTY;
    }

    next.ply += 1;
    next.pliesSinceCapture = formed && move.capture !== NONE_CAPTURE
      ? 0
      : state.pliesSinceCapture + 1;
    next.sideToMove = mover === Side.RED ? Side.GREEN : Side.RED;
    next.history.push(next.repetitionKey());
    next.result = NineMensMorrisRules.evaluate(next);
    return next;
  }

  /**
   * Outcome for `state` (spec §7–§8, in order: starvation →
   * immobilisation → threefold → fifty-ply limit). Called after every
   * applied move; also safe on any deserialised position.
   */
  static evaluate(state: GameState): GameResult {
    if (state.result !== GameResult.NONE) return state.result;

    const next = state.sideToMove;
    const mover = next === Side.RED ? Side.GREEN : Side.RED;
    const nextCell = next === Side.RED ? Cell.RED : Cell.GREEN;

    if (state.handOf(next) === 0 && state.countPieces(nextCell) < 3) {
      return mover === Side.RED ? GameResult.RED_WIN : GameResult.GREEN_WIN;
    }
    if (NineMensMorrisRules.legalMoves(state).length === 0) {
      return mover === Side.RED ? GameResult.RED_WIN : GameResult.GREEN_WIN;
    }
    if (state.repetitionCount() >= 3) return GameResult.DRAW;
    if (state.pliesSinceCapture >= PLIES_TO_DRAW) return GameResult.DRAW;
    return GameResult.NONE;
  }

  /** Convenience: legal move notations, for logs and tests. */
  static legalNotations(state: GameState): string[] {
    return NineMensMorrisRules.legalMoves(state).map((m) => NineMensMorrisRules.notation(m));
  }

  /**
   * Pushes the move(s) whose landing is `land` on a scratch copy of the
   * board — one variant per legal capture when a mill forms, exactly
   * one otherwise.
   */
  private static collectForLanding(
    board: readonly number[],
    mine: number,
    kind: 'place' | 'move',
    land: number,
    origin: number,
    moves: Move[],
  ): void {
    const scratch = board.slice();
    if (kind === 'move') scratch[origin] = Cell.EMPTY;
    scratch[land] = mine;
    if (!NineMensMorrisRules.millFormedAt(scratch, land, mine)) {
      moves.push(kind === 'place' ? Move.place(land) : Move.step(origin, land));
      return;
    }
    const targets = NineMensMorrisRules.captureTargets(scratch, mine);
    if (targets.length === 0) {
      moves.push(kind === 'place' ? Move.place(land) : Move.step(origin, land));
      return;
    }
    for (const target of targets) {
      moves.push(kind === 'place' ? Move.place(land, target) : Move.step(origin, land, target));
    }
  }

  private static ensureTables(): void {
    if (NineMensMorrisRules.adjacency.size > 0) return;
    for (const [a, b] of EDGES) {
      const ab = NineMensMorrisRules.adjacency.get(a) ?? [];
      const ba = NineMensMorrisRules.adjacency.get(b) ?? [];
      if (!ab.includes(b)) ab.push(b);
      if (!ba.includes(a)) ba.push(a);
      NineMensMorrisRules.adjacency.set(a, ab);
      NineMensMorrisRules.adjacency.set(b, ba);
    }
    for (const mill of MILLS) {
      for (const point of mill) {
        const list = NineMensMorrisRules.millsThrough.get(point) ?? [];
        list.push(mill);
        NineMensMorrisRules.millsThrough.set(point, list);
      }
    }
  }
}

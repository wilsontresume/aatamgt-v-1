/**
 * Board topology, move generation, state transitions and outcome
 * evaluation for Aadu Puli Aattam. Pure, deterministic rules engine —
 * no I/O, no clocks, no hidden state.
 *
 * Deterministic port of src/games/aadu_puli/aadu_puli_rules.gd, which
 * implements docs/aadu_puli_aattam_rules.md exactly.
 */

import { Move, MoveKind } from './aadu-puli.move';
import {
  CAPTURES_TO_WIN,
  Cell,
  GameResult,
  GameState,
  PLIES_TO_DRAW,
  POINT_COUNT,
  Side,
} from './aadu-puli.state';
import { validate, Verdict } from './aadu-puli.validator';

/** Ordered polylines of the chart (spec §2). */
export const LINES: readonly (readonly number[])[] = [
  [0, 2, 8, 14, 19],
  [0, 3, 9, 15, 20],
  [0, 4, 10, 16, 21],
  [0, 5, 11, 17, 22],
  [1, 2, 3, 4, 5, 6],
  [7, 8, 9, 10, 11, 12],
  [13, 14, 15, 16, 17, 18],
  [19, 20, 21, 22],
  [1, 7, 13],
  [6, 12, 18],
];

export class AaduPuliRules {
  private static readonly adjacency = new Map<number, number[]>();
  private static readonly jumps = new Map<number, Move[]>();

  /** Neighbors of `point` in deterministic edge-insertion order. */
  static neighbors(point: number): number[] {
    AaduPuliRules.ensureTables();
    return (AaduPuliRules.adjacency.get(point) ?? []).slice();
  }

  static areAdjacent(a: number, b: number): boolean {
    AaduPuliRules.ensureTables();
    return (AaduPuliRules.adjacency.get(a) ?? []).includes(b);
  }

  /** True when (a, b, c) form a geometrically legal tiger jump. */
  static isJumpLine(a: number, b: number, c: number): boolean {
    for (const move of AaduPuliRules.jumpsFrom(a)) {
      if (move.over === b && move.to === c) return true;
    }
    return false;
  }

  /** Every geometrically possible jump starting at `point` (state-free). */
  static jumpsFrom(point: number): Move[] {
    AaduPuliRules.ensureTables();
    return (AaduPuliRules.jumps.get(point) ?? []).slice();
  }

  /**
   * All legal moves for the side to move, in deterministic order.
   * Empty when the game is over.
   */
  static legalMoves(state: GameState | null): Move[] {
    const moves: Move[] = [];
    if (state === null || state.result !== GameResult.NONE) return moves;
    if (state.sideToMove === Side.GOATS) {
      if (state.goatsInHand > 0) {
        // Placement phase: any empty point (spec §4.1).
        for (let point = 0; point < POINT_COUNT; point++) {
          if (state.isEmpty(point)) AaduPuliRules.keepIfLegal(state, Move.place(point), moves);
        }
      } else {
        // Slide phase (spec §4.2).
        for (const goat of state.goatPoints()) {
          for (const neighbor of AaduPuliRules.neighbors(goat)) {
            AaduPuliRules.keepIfLegal(state, Move.step(goat, neighbor), moves);
          }
        }
      }
    } else {
      // Tigers: steps and optional single jumps (spec §4.3).
      for (const tiger of state.tigerPoints()) {
        for (const neighbor of AaduPuliRules.neighbors(tiger)) {
          AaduPuliRules.keepIfLegal(state, Move.step(tiger, neighbor), moves);
        }
        for (const jump of AaduPuliRules.jumpsFrom(tiger)) {
          AaduPuliRules.keepIfLegal(state, jump, moves);
        }
      }
    }
    return moves;
  }

  /** Legal moves whose origin is `point` (placements excluded). */
  static legalMovesFrom(state: GameState, point: number): Move[] {
    return AaduPuliRules.legalMoves(state).filter((m) => m.from === point);
  }

  /**
   * Applies a legal move to a fresh state (the input is never mutated).
   * Returns null when the move is not legal.
   */
  static apply(state: GameState, move: Move): GameState | null {
    const verdict: Verdict = validate(state, move);
    if (!verdict.ok) return null;
    const next = state.duplicate();
    switch (move.kind) {
      case MoveKind.PLACE:
        next.board[move.to] = Cell.GOAT;
        next.goatsInHand -= 1;
        break;
      case MoveKind.STEP:
        next.board[move.to] = next.board[move.from];
        next.board[move.from] = Cell.EMPTY;
        break;
      case MoveKind.JUMP:
        next.board[move.to] = Cell.TIGER;
        next.board[move.from] = Cell.EMPTY;
        next.board[move.over] = Cell.EMPTY;
        next.goatsCaptured += 1;
        break;
      default:
        return null;
    }
    next.ply += 1;
    next.sideToMove = state.sideToMove === Side.GOATS ? Side.TIGERS : Side.GOATS;
    next.result = AaduPuliRules.evaluate(next);
    return next;
  }

  /**
   * Outcome for `state` after it becomes the side to move (spec §5,
   * in order: capture win → immobilisation wins → draw).
   */
  static evaluate(state: GameState): GameResult {
    if (state.result !== GameResult.NONE) return state.result;
    if (state.goatsCaptured >= CAPTURES_TO_WIN) return GameResult.TIGERS_WIN;
    const moves = AaduPuliRules.legalMoves(state);
    if (state.sideToMove === Side.TIGERS) {
      if (moves.length === 0) return GameResult.GOATS_WIN;
    } else if (state.goatsInHand === 0 && moves.length === 0) {
      return GameResult.TIGERS_WIN;
    }
    if (state.ply >= PLIES_TO_DRAW) return GameResult.DRAW;
    return GameResult.NONE;
  }

  private static keepIfLegal(state: GameState, move: Move, moves: Move[]): void {
    if (validate(state, move).ok) moves.push(move);
  }

  private static ensureTables(): void {
    if (AaduPuliRules.adjacency.size > 0) return;
    for (const line of LINES) {
      // Adjacency: consecutive pairs (deduplicated, insertion-ordered).
      for (let i = 0; i < line.length - 1; i++) {
        AaduPuliRules.addEdge(line[i], line[i + 1]);
      }
      // Jumps: consecutive triples, in both directions.
      for (let i = 0; i < line.length - 2; i++) {
        const a = line[i];
        const over = line[i + 1];
        const c = line[i + 2];
        AaduPuliRules.addJump(a, over, c);
        AaduPuliRules.addJump(c, over, a);
      }
    }
  }

  private static addEdge(a: number, b: number): void {
    const ab = AaduPuliRules.adjacency.get(a) ?? [];
    const ba = AaduPuliRules.adjacency.get(b) ?? [];
    if (!ab.includes(b)) ab.push(b);
    if (!ba.includes(a)) ba.push(a);
    AaduPuliRules.adjacency.set(a, ab);
    AaduPuliRules.adjacency.set(b, ba);
  }

  private static addJump(from: number, over: number, to: number): void {
    const list = AaduPuliRules.jumps.get(from) ?? [];
    list.push(Move.jump(from, over, to));
    AaduPuliRules.jumps.set(from, list);
  }
}

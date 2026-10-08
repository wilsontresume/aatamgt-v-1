/**
 * Board topology, move generation, state transitions and outcome
 * evaluation for Solah Seedi (16 Soldiers). Pure, deterministic rules
 * engine — no I/O, no clocks, no hidden state.
 *
 * Implements docs/solah_seedi_rules.md exactly. The board is the 37-point
 * chart of §2: 20 straight polylines expanding to 76 segments
 * (40 orthogonal, 16 alquerque checkerboard diagonals, 20 triangle).
 */

import { Move } from './solah-seedi.move';
import {
  Cell,
  GameResult,
  GameState,
  GREEN_TRIANGLE,
  PLIES_TO_DRAW,
  POINT_COUNT,
  RED_TRIANGLE,
  Side,
} from './solah-seedi.state';
import { validate, Verdict } from './solah-seedi.validator';

/** Ordered polylines of the chart (spec §2). */
export const LINES: readonly (readonly number[])[] = [
  // Horizontal lattice rows.
  [6, 7, 8, 9, 10],
  [11, 12, 13, 14, 15],
  [16, 17, 18, 19, 20],
  [21, 22, 23, 24, 25],
  [26, 27, 28, 29, 30],
  // Triangle horizontals.
  [0, 1, 2],
  [3, 4, 5],
  [31, 32, 33],
  [34, 35, 36],
  // Vertical lattice columns + the whole-board centre vertical.
  [6, 11, 16, 21, 26],
  [7, 12, 17, 22, 27],
  [1, 4, 8, 13, 18, 23, 28, 32, 35],
  [9, 14, 19, 24, 29],
  [10, 15, 20, 25, 30],
  // Diagonals: down-right chains.
  [0, 3, 8, 14, 20],
  [6, 12, 18, 24, 30],
  [20, 24, 28, 31, 34],
  // Diagonals: down-left chains.
  [2, 5, 8, 12, 16],
  [10, 14, 18, 22, 26],
  [16, 22, 28, 33, 36],
];

export interface JumpOption {
  /** Landing point (two steps along one polyline). */
  to: number;
  /** The single point jumped over. */
  over: number;
}

export class SolahSeediRules {
  private static readonly adjacency = new Map<number, number[]>();
  private static readonly jumpMiddles = new Map<string, number>();
  private static readonly jumpOptions = new Map<number, JumpOption[]>();

  /** Neighbors of `point` in deterministic edge-insertion order. */
  static neighbors(point: number): number[] {
    SolahSeediRules.ensureTables();
    return (SolahSeediRules.adjacency.get(point) ?? []).slice();
  }

  static areAdjacent(a: number, b: number): boolean {
    SolahSeediRules.ensureTables();
    return (SolahSeediRules.adjacency.get(a) ?? []).includes(b);
  }

  /**
   * The unique middle point of a two-step jump from `a` to `b`, or null
   * when (a, b) is not a legal jump pair (spec §2 proves it unique:
   * the middle of three consecutive straight points lies strictly
   * between them).
   */
  static jumpMiddle(a: number, b: number): number | null {
    SolahSeediRules.ensureTables();
    return SolahSeediRules.jumpMiddles.get(`${a},${b}`) ?? null;
  }

  /** Every geometrically possible jump starting at `point` (state-free). */
  static jumpOptionsFrom(point: number): JumpOption[] {
    SolahSeediRules.ensureTables();
    return (SolahSeediRules.jumpOptions.get(point) ?? []).map((o) => ({ ...o }));
  }

  /**
   * Notation for a validated move: `6-7`, `6-18*`, `6-18-30*`
   * (`*` marks any move containing at least one capture).
   */
  static notation(move: Move): string {
    const path = move.path;
    if (path.length === 0) return '';
    const capture =
      path.length > 2 ||
      (path.length === 2 && !SolahSeediRules.areAdjacent(path[0], path[1]));
    return capture ? `${path.join('-')}*` : `${path.join('-')}`;
  }

  /**
   * All legal moves for the side to move, in deterministic order:
   * every step, plus every capture chain prefix (a chain may be stopped
   * after any hop, but never extended past a hop that ends the game).
   * Empty when the game is over.
   */
  static legalMoves(state: GameState | null): Move[] {
    const moves: Move[] = [];
    if (state === null || state.result !== GameResult.NONE) return moves;
    const mine = state.moverCell();
    for (let point = 0; point < POINT_COUNT; point++) {
      if (state.board[point] !== mine) continue;
      for (const neighbor of SolahSeediRules.neighbors(point)) {
        if (state.isEmpty(neighbor)) moves.push(Move.step(point, neighbor));
      }
      SolahSeediRules.collectChains(state.board.slice(), mine, point, [point], moves);
    }
    return moves;
  }

  /** Legal moves whose origin is `point`. */
  static legalMovesFrom(state: GameState, point: number): Move[] {
    return SolahSeediRules.legalMoves(state).filter((m) => m.from === point);
  }

  /**
   * Applies a legal move to a fresh state (the input is never mutated).
   * Returns null when the move is not legal. Wins are evaluated after
   * every hop (spec §4.3/§5): a hop that wins ends the move.
   */
  static apply(state: GameState, move: Move): GameState | null {
    const verdict: Verdict = validate(state, move);
    if (!verdict.ok) return null;
    const next = state.duplicate();
    const mover = state.sideToMove;
    const mine = mover === Side.RED ? Cell.RED : Cell.GREEN;
    const path = move.path;

    next.board[path[0]] = Cell.EMPTY;
    let captured = 0;
    for (let i = 1; i < path.length; i++) {
      const from = path[i - 1];
      const to = path[i];
      if (!SolahSeediRules.areAdjacent(from, to)) {
        const middle = SolahSeediRules.jumpMiddle(from, to);
        if (middle === null) return null; // unreachable: validated
        if (next.board[middle] !== Cell.EMPTY) {
          next.board[middle] = Cell.EMPTY;
          captured += 1;
        }
      }
      next.board[from] = Cell.EMPTY;
      next.board[to] = mine;
      if (SolahSeediRules.positionWins(mine, to, next.board)) {
        next.result = mover === Side.RED ? GameResult.RED_WIN : GameResult.GREEN_WIN;
        break;
      }
    }

    next.ply += 1;
    next.pliesSinceCapture = captured > 0 ? 0 : state.pliesSinceCapture + 1;
    next.sideToMove = mover === Side.RED ? Side.GREEN : Side.RED;
    next.result = SolahSeediRules.evaluate(next);
    return next;
  }

  /**
   * Outcome for `state` (spec §5, in order: capture-all → breakthrough
   * → immobilisation → draw). Called after every applied move; also
   * safe on any deserialised position.
   */
  static evaluate(state: GameState): GameResult {
    if (state.result !== GameResult.NONE) return state.result;
    if (state.countPieces(Cell.GREEN) === 0) return GameResult.RED_WIN;
    if (state.countPieces(Cell.RED) === 0) return GameResult.GREEN_WIN;
    // Breakthrough is positional: any open position with a piece on the
    // enemy triangle can only arise from the hop that just won.
    for (const point of GREEN_TRIANGLE) {
      if (state.board[point] === Cell.RED) return GameResult.RED_WIN;
    }
    for (const point of RED_TRIANGLE) {
      if (state.board[point] === Cell.GREEN) return GameResult.GREEN_WIN;
    }
    if (SolahSeediRules.legalMoves(state).length === 0) {
      return state.sideToMove === Side.RED ? GameResult.GREEN_WIN : GameResult.RED_WIN;
    }
    if (state.pliesSinceCapture >= PLIES_TO_DRAW) return GameResult.DRAW;
    return GameResult.NONE;
  }

  /**
   * True when `mine` has just landed on `point` and thereby won
   * (spec §5.1 capture-all, §5.2 breakthrough). Positional and pure.
   */
  static positionWins(mine: number, point: number, board: number[]): boolean {
    const enemy = mine === Cell.RED ? Cell.GREEN : Cell.RED;
    let enemyCount = 0;
    for (const cell of board) if (cell === enemy) enemyCount++;
    if (enemyCount === 0) return true;
    const target = mine === Cell.RED ? GREEN_TRIANGLE : RED_TRIANGLE;
    return target.includes(point);
  }

  /**
   * Extends `path` with every further legal hop from `from`, mutating
   * `board` (a scratch copy) as the chain progresses so occupancy
   * reflects earlier hops. Every prefix is pushed — the chain may stop
   * after any hop — but a hop that wins is never extended.
   */
  private static collectChains(
    board: number[],
    mine: number,
    from: number,
    path: readonly number[],
    moves: Move[],
  ): void {
    const enemy = mine === Cell.RED ? Cell.GREEN : Cell.RED;
    for (const option of SolahSeediRules.jumpOptionsFrom(from)) {
      if (board[option.over] !== enemy) continue;
      if (board[option.to] !== Cell.EMPTY) continue;
      const chainPath = [...path, option.to];
      board[option.over] = Cell.EMPTY;
      board[from] = Cell.EMPTY;
      board[option.to] = mine;
      moves.push(Move.fromPath(chainPath));
      if (!SolahSeediRules.positionWins(mine, option.to, board)) {
        SolahSeediRules.collectChains(board, mine, option.to, chainPath, moves);
      }
      board[option.to] = Cell.EMPTY;
      board[option.over] = enemy;
      board[from] = mine;
    }
  }

  private static ensureTables(): void {
    if (SolahSeediRules.adjacency.size > 0) return;
    for (const line of LINES) {
      // Adjacency: consecutive pairs (deduplicated, insertion-ordered).
      for (let i = 0; i < line.length - 1; i++) {
        SolahSeediRules.addEdge(line[i], line[i + 1]);
      }
      // Jumps: consecutive triples, in both directions.
      for (let i = 0; i < line.length - 2; i++) {
        const a = line[i];
        const over = line[i + 1];
        const c = line[i + 2];
        SolahSeediRules.addJump(a, over, c);
        SolahSeediRules.addJump(c, over, a);
      }
    }
  }

  private static addEdge(a: number, b: number): void {
    const ab = SolahSeediRules.adjacency.get(a) ?? [];
    const ba = SolahSeediRules.adjacency.get(b) ?? [];
    if (!ab.includes(b)) ab.push(b);
    if (!ba.includes(a)) ba.push(a);
    SolahSeediRules.adjacency.set(a, ab);
    SolahSeediRules.adjacency.set(b, ba);
  }

  private static addJump(from: number, over: number, to: number): void {
    SolahSeediRules.jumpMiddles.set(`${from},${to}`, over);
    const list = SolahSeediRules.jumpOptions.get(from) ?? [];
    list.push({ to, over });
    SolahSeediRules.jumpOptions.set(from, list);
  }
}

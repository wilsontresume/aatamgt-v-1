/**
 * Complete position of a Solah Seedi (16 Soldiers) game: board, side to
 * move, counters and result. Pure data — no rules logic (see
 * solah-seedi.rules).
 *
 * Deterministic TypeScript port of the client engine; serialization
 * contract: docs/solah_seedi_rules.md §8.
 */

export enum Cell {
  EMPTY = 0,
  RED = 1,
  GREEN = 2,
}

export enum Side {
  RED = 0,
  GREEN = 1,
}

export enum GameResult {
  NONE = 0,
  RED_WIN = 1,
  GREEN_WIN = 2,
  DRAW = 3,
}

export const POINT_COUNT = 37;
export const PIECES_PER_SIDE = 16;

/** Red starts on the top triangle (0–5) + lattice rows 0–1 (6–15). */
export const RED_START_POINTS: readonly number[] = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
];
/** Green starts on lattice rows 3–4 (21–30) + the bottom triangle (31–36). */
export const GREEN_START_POINTS: readonly number[] = [
  21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36,
];

/** Red wins by landing on any of these (the opponent's triangle). */
export const GREEN_TRIANGLE: readonly number[] = [31, 32, 33, 34, 35, 36];
/** Green wins by landing on any of these. */
export const RED_TRIANGLE: readonly number[] = [0, 1, 2, 3, 4, 5];

export const PLIES_TO_DRAW = 60;
export const SERIAL_VERSION = 1;

export const SIDE_KEYS = ['red', 'green'] as const;
export const RESULT_KEYS = ['none', 'red_win', 'green_win', 'draw'] as const;

/** The published starting position (docs/solah_seedi_rules.md §8). */
export const INITIAL_BOARD = 'RRRRRRRRRRRRRRRR.....GGGGGGGGGGGGGGGG';

export type SerializedState = {
  version: number;
  board: string;
  side_to_move: string;
  ply: number;
  plies_since_capture: number;
  result: string;
};

export class GameState {
  board: number[] = new Array<number>(POINT_COUNT).fill(Cell.EMPTY);
  sideToMove: Side = Side.RED;
  ply = 0;
  pliesSinceCapture = 0;
  result: GameResult = GameResult.NONE;

  /** The published starting position: red 0–15, green 21–36, red first. */
  static initial(): GameState {
    const state = new GameState();
    for (const point of RED_START_POINTS) state.board[point] = Cell.RED;
    for (const point of GREEN_START_POINTS) state.board[point] = Cell.GREEN;
    return state;
  }

  inBounds(point: number): boolean {
    return point >= 0 && point < POINT_COUNT;
  }

  cell(point: number): number {
    return this.inBounds(point) ? this.board[point] : Cell.EMPTY;
  }

  isEmpty(point: number): boolean {
    return this.inBounds(point) && this.board[point] === Cell.EMPTY;
  }

  isTerminal(): boolean {
    return this.result !== GameResult.NONE;
  }

  countPieces(cell: number): number {
    let total = 0;
    for (let i = 0; i < POINT_COUNT; i++) if (this.board[i] === cell) total++;
    return total;
  }

  pointsOf(cell: number): number[] {
    const points: number[] = [];
    for (let i = 0; i < POINT_COUNT; i++) if (this.board[i] === cell) points.push(i);
    return points;
  }

  /** Cell of the side to move. */
  moverCell(): number {
    return this.sideToMove === Side.RED ? Cell.RED : Cell.GREEN;
  }

  enemyCell(): number {
    return this.sideToMove === Side.RED ? Cell.GREEN : Cell.RED;
  }

  /**
   * Structural sanity per §8: piece counts and conservation, counter
   * ranges, and result/board agreement (a side at zero pieces has a
   * decided game; no piece may sit on the enemy triangle while the game
   * is still open).
   */
  countsConsistent(): boolean {
    const reds = this.countPieces(Cell.RED);
    const greens = this.countPieces(Cell.GREEN);
    if (reds > PIECES_PER_SIDE || greens > PIECES_PER_SIDE) return false;
    if (!Number.isInteger(this.ply) || this.ply < 0) return false;
    if (!Number.isInteger(this.pliesSinceCapture)) return false;
    if (this.pliesSinceCapture < 0 || this.pliesSinceCapture > this.ply) return false;
    if (reds === 0 && this.result !== GameResult.GREEN_WIN) return false;
    if (greens === 0 && this.result !== GameResult.RED_WIN) return false;
    if ((this.result === GameResult.NONE || this.result === GameResult.DRAW) && (reds === 0 || greens === 0)) {
      return false;
    }
    if (this.result === GameResult.RED_WIN && reds === 0) return false;
    if (this.result === GameResult.GREEN_WIN && greens === 0) return false;
    if (this.result === GameResult.NONE || this.result === GameResult.DRAW) {
      for (const point of GREEN_TRIANGLE) if (this.board[point] === Cell.RED) return false;
      for (const point of RED_TRIANGLE) if (this.board[point] === Cell.GREEN) return false;
    }
    return true;
  }

  duplicate(): GameState {
    const copy = new GameState();
    copy.board = this.board.slice();
    copy.sideToMove = this.sideToMove;
    copy.ply = this.ply;
    copy.pliesSinceCapture = this.pliesSinceCapture;
    copy.result = this.result;
    return copy;
  }

  boardString(): string {
    let chars = '';
    for (let i = 0; i < POINT_COUNT; i++) {
      switch (this.board[i]) {
        case Cell.RED:
          chars += 'R';
          break;
        case Cell.GREEN:
          chars += 'G';
          break;
        default:
          chars += '.';
      }
    }
    return chars;
  }

  serialize(): SerializedState {
    return {
      version: SERIAL_VERSION,
      board: this.boardString(),
      side_to_move: SIDE_KEYS[this.sideToMove],
      ply: this.ply,
      plies_since_capture: this.pliesSinceCapture,
      result: RESULT_KEYS[this.result],
    };
  }

  /** Returns a validated state, or null when the payload is malformed. */
  static deserialize(data: unknown): GameState | null {
    if (typeof data !== 'object' || data === null) return null;
    const d = data as Record<string, unknown>;
    if (d.version !== SERIAL_VERSION) return null;
    const boardText = typeof d.board === 'string' ? d.board : '';
    if (boardText.length !== POINT_COUNT) return null;
    const state = new GameState();
    for (let i = 0; i < POINT_COUNT; i++) {
      const ch = boardText[i];
      if (ch === 'R') state.board[i] = Cell.RED;
      else if (ch === 'G') state.board[i] = Cell.GREEN;
      else if (ch === '.') state.board[i] = Cell.EMPTY;
      else return null;
    }
    if (d.side_to_move === 'red') state.sideToMove = Side.RED;
    else if (d.side_to_move === 'green') state.sideToMove = Side.GREEN;
    else return null;
    const resultIndex = RESULT_KEYS.indexOf((d.result ?? 'none') as (typeof RESULT_KEYS)[number]);
    if (resultIndex < 0) return null;
    state.result = resultIndex as GameResult;
    state.ply = typeof d.ply === 'number' ? d.ply : -1;
    state.pliesSinceCapture = typeof d.plies_since_capture === 'number' ? d.plies_since_capture : -1;
    if (!state.countsConsistent()) return null;
    return state;
  }
}

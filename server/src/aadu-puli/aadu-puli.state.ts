/**
 * Complete position of an Aadu Puli Aattam game: board, side to move,
 * counters and result. Pure data — no rules logic (see aadu-puli.rules).
 *
 * Deterministic port of src/games/aadu_puli/aadu_puli_game_state.gd.
 * Serialization contract: docs/aadu_puli_aattam_rules.md §8.
 */

export enum Cell {
  EMPTY = 0,
  TIGER = 1,
  GOAT = 2,
}

export enum Side {
  GOATS = 0,
  TIGERS = 1,
}

export enum GameResult {
  NONE = 0,
  GOATS_WIN = 1,
  TIGERS_WIN = 2,
  DRAW = 3,
}

export const POINT_COUNT = 23;
export const GOAT_TOTAL = 15;
export const TIGER_TOTAL = 3;
export const TIGER_START_POINTS: readonly number[] = [0, 3, 4];
export const CAPTURES_TO_WIN = 5;
export const PLIES_TO_DRAW = 60;
export const SERIAL_VERSION = 1;

export const SIDE_KEYS = ['goats', 'tigers'] as const;
export const RESULT_KEYS = ['none', 'goats_win', 'tigers_win', 'draw'] as const;

export type SerializedState = {
  version: number;
  board: string;
  side_to_move: string;
  goats_in_hand: number;
  goats_captured: number;
  ply: number;
  result: string;
};

export class GameState {
  board: number[] = new Array<number>(POINT_COUNT).fill(Cell.EMPTY);
  sideToMove: Side = Side.GOATS;
  goatsInHand: number = GOAT_TOTAL;
  goatsCaptured: number = 0;
  ply = 0;
  result: GameResult = GameResult.NONE;

  /** The published starting position: tigers on 0, 3, 4; 15 goats in hand. */
  static initial(): GameState {
    const state = new GameState();
    for (const point of TIGER_START_POINTS) state.board[point] = Cell.TIGER;
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

  goatsOnBoard(): number {
    return this.board.filter((c) => c === Cell.GOAT).length;
  }

  tigerPoints(): number[] {
    const points: number[] = [];
    for (let i = 0; i < POINT_COUNT; i++) if (this.board[i] === Cell.TIGER) points.push(i);
    return points;
  }

  goatPoints(): number[] {
    const points: number[] = [];
    for (let i = 0; i < POINT_COUNT; i++) if (this.board[i] === Cell.GOAT) points.push(i);
    return points;
  }

  /**
   * Structural sanity: hand + board + captured must always total 15 and
   * exactly 3 tigers must be on the board.
   */
  countsConsistent(): boolean {
    return (
      this.goatsInHand >= 0 &&
      this.goatsInHand <= GOAT_TOTAL &&
      this.goatsCaptured >= 0 &&
      this.goatsCaptured <= GOAT_TOTAL &&
      this.goatsInHand + this.goatsOnBoard() + this.goatsCaptured === GOAT_TOTAL &&
      this.tigerPoints().length === TIGER_TOTAL
    );
  }

  duplicate(): GameState {
    const copy = new GameState();
    copy.board = this.board.slice();
    copy.sideToMove = this.sideToMove;
    copy.goatsInHand = this.goatsInHand;
    copy.goatsCaptured = this.goatsCaptured;
    copy.ply = this.ply;
    copy.result = this.result;
    return copy;
  }

  boardString(): string {
    let chars = '';
    for (let i = 0; i < POINT_COUNT; i++) {
      switch (this.board[i]) {
        case Cell.TIGER:
          chars += 't';
          break;
        case Cell.GOAT:
          chars += 'g';
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
      goats_in_hand: this.goatsInHand,
      goats_captured: this.goatsCaptured,
      ply: this.ply,
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
      if (ch === 't') state.board[i] = Cell.TIGER;
      else if (ch === 'g') state.board[i] = Cell.GOAT;
      else if (ch === '.') state.board[i] = Cell.EMPTY;
      else return null;
    }
    if (d.side_to_move === 'goats') state.sideToMove = Side.GOATS;
    else if (d.side_to_move === 'tigers') state.sideToMove = Side.TIGERS;
    else return null;
    const resultIndex = RESULT_KEYS.indexOf((d.result ?? 'none') as (typeof RESULT_KEYS)[number]);
    if (resultIndex < 0) return null;
    state.result = resultIndex as GameResult;
    state.goatsInHand = typeof d.goats_in_hand === 'number' ? d.goats_in_hand : -1;
    state.goatsCaptured = typeof d.goats_captured === 'number' ? d.goats_captured : -1;
    state.ply = typeof d.ply === 'number' ? d.ply : -1;
    if (!Number.isInteger(state.ply) || state.ply < 0 || !state.countsConsistent()) return null;
    return state;
  }

  /** Published FEN: board, side to move, goats in hand, ply (§8). */
  toFen(): string {
    return `${this.boardString()} ${SIDE_KEYS[this.sideToMove][0]} ${this.goatsInHand} ${this.ply}`;
  }

  static fromFen(fen: string): GameState | null {
    const parts = fen.trim().split(/\s+/);
    if (parts.length !== 4) return null;
    const sideKey = parts[1];
    if (sideKey !== 'g' && sideKey !== 't') return null;
    if (!/^-?\d+$/.test(parts[2]) || !/^-?\d+$/.test(parts[3])) return null;
    const boardText = parts[0];
    if (boardText.length !== POINT_COUNT) return null;
    const state = new GameState();
    for (let i = 0; i < POINT_COUNT; i++) {
      const ch = boardText[i];
      if (ch === 't') state.board[i] = Cell.TIGER;
      else if (ch === 'g') state.board[i] = Cell.GOAT;
      else if (ch === '.') state.board[i] = Cell.EMPTY;
      else return null;
    }
    state.sideToMove = sideKey === 'g' ? Side.GOATS : Side.TIGERS;
    state.goatsInHand = Number(parts[2]);
    state.ply = Number(parts[3]);
    if (state.ply < 0) return null;
    // Derive captures from the conservation law (not part of the FEN).
    state.goatsCaptured = GOAT_TOTAL - state.goatsInHand - state.goatsOnBoard();
    if (state.goatsCaptured < 0 || !state.countsConsistent()) return null;
    return state;
  }
}

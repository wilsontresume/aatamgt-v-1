/**
 * Complete position of a Nine Men's Morris game: board, side to move,
 * hands, counters, repetition history and result. Pure data — no rules
 * logic (see nine-mens-morris.rules).
 *
 * Deterministic TypeScript port of the client engine; serialization
 * matches docs/nine_mens_morris_rules.md §9 exactly.
 */

export enum Cell {
  EMPTY = 0,
  RED = 1,
  GREEN = 2,
}

export enum Side {
  RED = 'red',
  GREEN = 'green',
}

export enum GameResult {
  NONE = 'none',
  RED_WIN = 'red_win',
  GREEN_WIN = 'green_win',
  DRAW = 'draw',
}

export const POINT_COUNT = 24;
export const PIECES_PER_SIDE = 9;
export const PLIES_TO_DRAW = 50;
export const SERIAL_VERSION = 1;

export const SIDE_KEYS = ['red', 'green'] as const;
export const RESULT_KEYS = ['none', 'red_win', 'green_win', 'draw'] as const;

export const INITIAL_BOARD = '........................';

export type SerializedState = {
  version: number;
  board: string;
  to_move: Side;
  hand_red: number;
  hand_green: number;
  ply: number;
  plies_since_capture: number;
  result: GameResult;
  history: string[];
};

const BOARD_CHARS = ['.', 'R', 'G'] as const;

export class GameState {
  board: number[];
  sideToMove: Side;
  hands: [number, number];
  ply: number;
  pliesSinceCapture: number;
  result: GameResult;
  history: string[];

  constructor(
    board: number[],
    sideToMove: Side,
    hands: [number, number],
    ply: number,
    pliesSinceCapture: number,
    result: GameResult,
    history: string[],
  ) {
    this.board = board;
    this.sideToMove = sideToMove;
    this.hands = hands;
    this.ply = ply;
    this.pliesSinceCapture = pliesSinceCapture;
    this.result = result;
    this.history = history;
  }

  static initial(): GameState {
    const state = new GameState(
      new Array<number>(POINT_COUNT).fill(Cell.EMPTY),
      Side.RED,
      [PIECES_PER_SIDE, PIECES_PER_SIDE],
      0,
      0,
      GameResult.NONE,
      [],
    );
    state.history = [state.repetitionKey()];
    return state;
  }

  static sideIndex(side: Side): 0 | 1 {
    return side === Side.RED ? 0 : 1;
  }

  cellSide(cell: number): Side | null {
    if (cell === Cell.RED) return Side.RED;
    if (cell === Cell.GREEN) return Side.GREEN;
    return null;
  }

  moverCell(): number {
    return this.sideToMove === Side.RED ? Cell.RED : Cell.GREEN;
  }

  moverHand(): number {
    return this.hands[GameState.sideIndex(this.sideToMove)];
  }

  handOf(side: Side): number {
    return this.hands[GameState.sideIndex(side)];
  }

  enemyCell(mine: number): number {
    return mine === Cell.RED ? Cell.GREEN : Cell.RED;
  }

  inBounds(point: number): boolean {
    return Number.isInteger(point) && point >= 0 && point < POINT_COUNT;
  }

  isEmpty(point: number): boolean {
    return this.board[point] === Cell.EMPTY;
  }

  countPieces(cell: number): number {
    let n = 0;
    for (const c of this.board) if (c === cell) n++;
    return n;
  }

  countSide(side: Side): number {
    return this.countPieces(side === Side.RED ? Cell.RED : Cell.GREEN);
  }

  /** Repetition key of this position (docs §8.1). */
  repetitionKey(): string {
    const board = this.board.map((c) => BOARD_CHARS[c]).join('');
    return `${board}|${this.sideToMove}|${this.hands[0]}|${this.hands[1]}`;
  }

  /** Occurrences of `key` (or of the current key) in the history. */
  repetitionCount(key?: string): number {
    const target = key ?? this.repetitionKey();
    let n = 0;
    for (const k of this.history) if (k === target) n++;
    return n;
  }

  serialize(): SerializedState {
    return {
      version: SERIAL_VERSION,
      board: this.board.map((c) => BOARD_CHARS[c]).join(''),
      to_move: this.sideToMove,
      hand_red: this.hands[0],
      hand_green: this.hands[1],
      ply: this.ply,
      plies_since_capture: this.pliesSinceCapture,
      result: this.result,
      history: [...this.history],
    };
  }

  static deserialize(data: unknown): GameState | null {
    if (typeof data !== 'object' || data === null) return null;
    const raw = data as Record<string, unknown>;
    if (raw.version !== SERIAL_VERSION) return null;
    if (typeof raw.board !== 'string' || raw.board.length !== POINT_COUNT) return null;
    const board: number[] = [];
    for (const ch of raw.board) {
      const idx = BOARD_CHARS.indexOf(ch as (typeof BOARD_CHARS)[number]);
      if (idx < 0) return null;
      board.push(idx);
    }
    if (raw.to_move !== Side.RED && raw.to_move !== Side.GREEN) return null;
    const handRed = raw.hand_red;
    const handGreen = raw.hand_green;
    if (
      typeof handRed !== 'number' ||
      !Number.isInteger(handRed) ||
      handRed < 0 ||
      handRed > PIECES_PER_SIDE ||
      typeof handGreen !== 'number' ||
      !Number.isInteger(handGreen) ||
      handGreen < 0 ||
      handGreen > PIECES_PER_SIDE
    ) {
      return null;
    }
    const ply = raw.ply;
    const since = raw.plies_since_capture;
    if (
      typeof ply !== 'number' ||
      !Number.isInteger(ply) ||
      ply < 0 ||
      typeof since !== 'number' ||
      !Number.isInteger(since) ||
      since < 0
    ) {
      return null;
    }
    if (!RESULT_KEYS.includes(raw.result as GameResult)) return null;
    const history = raw.history;
    if (
      !Array.isArray(history) ||
      history.length === 0 ||
      !history.every((k) => typeof k === 'string')
    ) {
      return null;
    }
    return new GameState(
      board,
      raw.to_move as Side,
      [handRed, handGreen],
      ply,
      since,
      raw.result as GameResult,
      [...history],
    );
  }

  duplicate(): GameState {
    return new GameState(
      [...this.board],
      this.sideToMove,
      [this.hands[0], this.hands[1]],
      this.ply,
      this.pliesSinceCapture,
      this.result,
      [...this.history],
    );
  }
}

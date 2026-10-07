/**
 * One requested move in Aadu Puli Aattam — a pure value object.
 *
 * Deterministic TypeScript port of the client engine
 * (src/games/aadu_puli/aadu_puli_move.gd) so server and client agree
 * byte-for-byte on notation and wire shape. It carries no rules
 * knowledge: AaduPuliValidator decides legality against a state.
 *
 * Notation (docs/aadu_puli_aattam_rules.md): place `12`, step `0-2`,
 * jump `0-8*`.
 */

export enum MoveKind {
  PLACE = 0,
  STEP = 1,
  JUMP = 2,
}

/** Sentinel for unused fields (a placement has no origin/capture). */
export const NONE_POINT = -1;

export interface WireMove {
  kind: number;
  from?: number;
  to: number;
  over?: number;
}

export class Move {
  readonly kind: MoveKind;
  readonly from: number;
  readonly to: number;
  readonly over: number;

  constructor(kind: MoveKind, from = NONE_POINT, to = NONE_POINT, over = NONE_POINT) {
    this.kind = kind;
    this.from = from;
    this.to = to;
    this.over = over;
  }

  static place(to: number): Move {
    return new Move(MoveKind.PLACE, NONE_POINT, to, NONE_POINT);
  }

  static step(from: number, to: number): Move {
    return new Move(MoveKind.STEP, from, to, NONE_POINT);
  }

  static jump(from: number, over: number, to: number): Move {
    return new Move(MoveKind.JUMP, from, to, over);
  }

  isCapture(): boolean {
    return this.kind === MoveKind.JUMP;
  }

  notation(): string {
    switch (this.kind) {
      case MoveKind.PLACE:
        return String(this.to);
      case MoveKind.STEP:
        return `${this.from}-${this.to}`;
      case MoveKind.JUMP:
        return `${this.from}-${this.to}*`;
      default:
        return '';
    }
  }

  toJSON(): WireMove {
    return { kind: this.kind, from: this.from, to: this.to, over: this.over };
  }

  equals(other: Move | null): boolean {
    return (
      other !== null &&
      this.kind === other.kind &&
      this.from === other.from &&
      this.to === other.to &&
      this.over === other.over
    );
  }

  /**
   * Strict wire parser. Returns null for anything that is not exactly
   * {kind, to} with optional integer from/over — the server must never
   * guess at a client payload.
   */
  static fromWire(data: unknown): Move | null {
    if (typeof data !== 'object' || data === null) return null;
    const raw = data as Record<string, unknown>;
    if (!Number.isInteger(raw.kind) || !Number.isInteger(raw.to)) return null;
    const kind = raw.kind as number;
    if (kind < MoveKind.PLACE || kind > MoveKind.JUMP) return null;
    const from = raw.from === undefined ? NONE_POINT : raw.from;
    const over = raw.over === undefined ? NONE_POINT : raw.over;
    if (!Number.isInteger(from) || !Number.isInteger(over)) return null;
    return new Move(kind, from as number, raw.to as number, over as number);
  }
}

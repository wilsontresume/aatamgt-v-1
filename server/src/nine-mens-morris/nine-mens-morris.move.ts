/**
 * One requested move in Nine Men's Morris — a pure value object.
 *
 * A wire move is a complete turn: a placement or a movement plus the
 * capture it forced, if any (docs/nine_mens_morris_rules.md §10).
 * `capture` of NONE_CAPTURE means the turn ends without a removal.
 */

export const NONE_CAPTURE = -1;

export interface WireMove {
  kind: 'place' | 'move';
  point?: number;
  from?: number;
  to?: number;
  capture?: number;
}

export type MoveKind = 'place' | 'move';

export class Move {
  readonly kind: MoveKind;
  readonly point: number;
  readonly from: number;
  readonly to: number;
  readonly capture: number;

  constructor(kind: MoveKind, point: number, from: number, to: number, capture: number) {
    this.kind = kind;
    this.point = point;
    this.from = from;
    this.to = to;
    this.capture = capture;
  }

  static place(point: number, capture: number = NONE_CAPTURE): Move {
    return new Move('place', point, NONE_CAPTURE, NONE_CAPTURE, capture);
  }

  static step(from: number, to: number, capture: number = NONE_CAPTURE): Move {
    return new Move('move', NONE_CAPTURE, from, to, capture);
  }

  /** Wire payload → Move; null when the payload is malformed. */
  static fromWire(payload: unknown): Move | null {
    if (typeof payload !== 'object' || payload === null) return null;
    const wire = payload as Record<string, unknown>;
    const capture = wire.capture === undefined || wire.capture === null
      ? NONE_CAPTURE
      : wire.capture;
    if (typeof capture !== 'number' || !Number.isInteger(capture)) return null;

    if (wire.kind === 'place') {
      const point = wire.point;
      if (typeof point !== 'number' || !Number.isInteger(point)) return null;
      return Move.place(point, capture);
    }
    if (wire.kind === 'move') {
      const from = wire.from;
      const to = wire.to;
      if (typeof from !== 'number' || !Number.isInteger(from)) return null;
      if (typeof to !== 'number' || !Number.isInteger(to)) return null;
      return Move.step(from, to, capture);
    }
    return null;
  }

  toWire(): WireMove {
    if (this.kind === 'place') {
      const wire: WireMove = { kind: 'place', point: this.point };
      if (this.capture !== NONE_CAPTURE) wire.capture = this.capture;
      return wire;
    }
    const wire: WireMove = { kind: 'move', from: this.from, to: this.to };
    if (this.capture !== NONE_CAPTURE) wire.capture = this.capture;
    return wire;
  }

  /** Landing point of the placement or movement (before capture). */
  get land(): number {
    return this.kind === 'place' ? this.point : this.to;
  }

  equals(other: Move): boolean {
    return (
      this.kind === other.kind &&
      this.point === other.point &&
      this.from === other.from &&
      this.to === other.to &&
      this.capture === other.capture
    );
  }
}

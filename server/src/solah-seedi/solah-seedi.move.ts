/**
 * One requested move in Solah Seedi — a pure value object.
 *
 * A move is the full path of the moved piece: the origin point followed
 * by every landing point (docs/salah_seedi_rules.md §4.4). A two-point
 * path is a step when its endpoints are adjacent and a single jump
 * otherwise; longer paths are capture chains. Classification needs the
 * board topology and therefore lives in the rules/validator — this
 * class carries no rules knowledge.
 *
 * Notation: step `6-7`, jump `6-18*`, chain `6-18-30*`
 * (produced by SolahSeediRules.notation).
 */

/** Sentinel for unused fields. */
export const NONE_POINT = -1;

/** 1 origin + at most 15 chain hops (one per enemy piece). */
export const MAX_PATH_POINTS = 16;

export interface WireMove {
  path: number[];
}

export class Move {
  readonly path: readonly number[];

  constructor(path: readonly number[]) {
    this.path = path;
  }

  static step(from: number, to: number): Move {
    return new Move([from, to]);
  }

  static fromPath(path: readonly number[]): Move {
    return new Move(path);
  }

  get from(): number {
    return this.path[0];
  }

  get to(): number {
    return this.path[this.path.length - 1];
  }

  equals(other: Move | null): boolean {
    if (other === null || this.path.length !== other.path.length) return false;
    for (let i = 0; i < this.path.length; i++) {
      if (this.path[i] !== other.path[i]) return false;
    }
    return true;
  }

  toJSON(): WireMove {
    return { path: [...this.path] };
  }

  /**
   * Strict wire parser. Returns null for anything that is not exactly
   * {path: [integer, integer, ...]} with 2..16 entries — the server
   * must never guess at a client payload. Point range and legality are
   * the validator's job.
   */
  static fromWire(data: unknown): Move | null {
    if (typeof data !== 'object' || data === null) return null;
    const raw = data as Record<string, unknown>;
    const path = raw.path;
    if (!Array.isArray(path)) return null;
    if (path.length < 2 || path.length > MAX_PATH_POINTS) return null;
    const points: number[] = [];
    for (const entry of path) {
      if (!Number.isInteger(entry)) return null;
      points.push(entry as number);
    }
    return new Move(points);
  }
}

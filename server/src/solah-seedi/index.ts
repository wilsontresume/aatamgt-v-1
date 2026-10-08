/**
 * Deterministic server-side Solah Seedi (16 Soldiers) rules engine.
 *
 * Single authority for legality, state transitions and results on the
 * server. The Godot client ships an identical port for offline play and
 * advisory highlighting — every online move is re-validated here before
 * it is applied, and the client never determines a result.
 */

export { Move, NONE_POINT, MAX_PATH_POINTS, WireMove } from './solah-seedi.move';
export {
  GameState,
  SerializedState,
  Cell,
  Side,
  GameResult,
  POINT_COUNT,
  PIECES_PER_SIDE,
  RED_START_POINTS,
  GREEN_START_POINTS,
  RED_TRIANGLE,
  GREEN_TRIANGLE,
  PLIES_TO_DRAW,
  SERIAL_VERSION,
  INITIAL_BOARD,
} from './solah-seedi.state';
export { SolahSeediRules, LINES, JumpOption } from './solah-seedi.rules';
export { validate, errorText, Issue, Verdict } from './solah-seedi.validator';

import { createHash } from 'node:crypto';
import { SolahSeediRules } from './solah-seedi.rules';
import { GameState, SerializedState } from './solah-seedi.state';

/** Canonical hash of a serialized state (stored on every move row). */
export function stateHash(serialized: SerializedState): string {
  const canonical = [
    serialized.version,
    serialized.board,
    serialized.side_to_move,
    serialized.ply,
    serialized.plies_since_capture,
    serialized.result,
  ].join('|');
  return createHash('sha256').update(canonical).digest('hex');
}

/** Convenience: legal move notations, for logs and tests. */
export function legalNotations(state: GameState): string[] {
  return SolahSeediRules.legalMoves(state).map((m) => SolahSeediRules.notation(m));
}

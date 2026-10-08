/**
 * Deterministic server-side Nine Men's Morris rules engine.
 *
 * Single authority for legality, state transitions and results on the
 * server. The Godot client ships an identical port for offline play,
 * AI and advisory highlighting — every online move is re-validated
 * here before it is applied, and the client never determines a result.
 */

export { Move, NONE_CAPTURE, MoveKind, WireMove } from './nine-mens-morris.move';
export {
  GameState,
  SerializedState,
  Cell,
  Side,
  GameResult,
  POINT_COUNT,
  PIECES_PER_SIDE,
  PLIES_TO_DRAW,
  SERIAL_VERSION,
  SIDE_KEYS,
  RESULT_KEYS,
  INITIAL_BOARD,
} from './nine-mens-morris.state';
export { NineMensMorrisRules, EDGES, MILLS, Phase } from './nine-mens-morris.rules';
export { validate, errorText, Issue, Verdict } from './nine-mens-morris.validator';

import { createHash } from 'node:crypto';
import { NineMensMorrisRules } from './nine-mens-morris.rules';
import { GameState, SerializedState } from './nine-mens-morris.state';

/** Canonical hash of a serialized state (stored on every move row). */
export function stateHash(serialized: SerializedState): string {
  const canonical = [
    serialized.version,
    serialized.board,
    serialized.to_move,
    serialized.hand_red,
    serialized.hand_green,
    serialized.ply,
    serialized.plies_since_capture,
    serialized.result,
  ].join('|');
  return createHash('sha256').update(canonical).digest('hex');
}

/** Convenience: legal move notations, for logs and tests. */
export function legalNotations(state: GameState): string[] {
  return NineMensMorrisRules.legalMoves(state).map((m) => NineMensMorrisRules.notation(m));
}

/**
 * Deterministic server-side Aadu Puli Aattam rules engine.
 *
 * This is the single authority for legality, state transitions and
 * results on the server. The Godot client ships an identical port for
 * offline play and advisory highlighting — every online move is
 * re-validated here before it is applied, and the client never
 * determines a result.
 */

export { Move, MoveKind, NONE_POINT, WireMove } from './aadu-puli.move';
export {
  GameState,
  SerializedState,
  Cell,
  Side,
  GameResult,
  POINT_COUNT,
  GOAT_TOTAL,
  TIGER_TOTAL,
  TIGER_START_POINTS,
  CAPTURES_TO_WIN,
  PLIES_TO_DRAW,
  SERIAL_VERSION,
} from './aadu-puli.state';
export { AaduPuliRules, LINES } from './aadu-puli.rules';
export { validate, errorText, Issue, Verdict } from './aadu-puli.validator';

import { createHash } from 'node:crypto';
import { AaduPuliRules } from './aadu-puli.rules';
import { GameState, SerializedState } from './aadu-puli.state';

/** Canonical hash of a serialized state (stored on every move row). */
export function stateHash(serialized: SerializedState): string {
  const canonical = [
    serialized.version,
    serialized.board,
    serialized.side_to_move,
    serialized.goats_in_hand,
    serialized.goats_captured,
    serialized.ply,
    serialized.result,
  ].join('|');
  return createHash('sha256').update(canonical).digest('hex');
}

/** Convenience: legal move notations, for logs and tests. */
export function legalNotations(state: GameState): string[] {
  return AaduPuliRules.legalMoves(state).map((m) => m.notation());
}

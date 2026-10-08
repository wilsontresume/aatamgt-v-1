/**
 * Decides whether a requested Move is legal in a given state.
 * Pure function of (state, move) — no mutation of the inputs.
 *
 * Error precedence (tests assert on it, docs §10): game over → move
 * shape → point bounds → phase/ownership → geometry → mill/capture
 * consistency. Scratch boards mirror the mover's action so mill
 * detection always sees the position after the landing.
 */

import { Move, NONE_CAPTURE } from './nine-mens-morris.move';
import { NineMensMorrisRules } from './nine-mens-morris.rules';
import { Cell, GameResult, GameState } from './nine-mens-morris.state';

export enum Issue {
  OK = 0,
  GAME_OVER = 1,
  INVALID_KIND = 2,
  OUT_OF_RANGE = 3,
  HAND_EMPTY = 4,
  MOVE_WITH_HAND = 5,
  EMPTY_ORIGIN = 6,
  NOT_YOUR_PIECE = 7,
  OCCUPIED = 8,
  NOT_ADJACENT = 9,
  CAPTURE_REQUIRED = 10,
  CAPTURE_FORBIDDEN = 11,
  CAPTURE_TARGET = 12,
}

export interface Verdict {
  ok: boolean;
  issue: Issue;
}

const OK_RESULT: Verdict = { ok: true, issue: Issue.OK };

function fail(issue: Issue): Verdict {
  return { ok: false, issue };
}

export function validate(state: GameState | null, move: Move | null): Verdict {
  if (state === null) return fail(Issue.INVALID_KIND);
  if (state.result !== GameResult.NONE) return fail(Issue.GAME_OVER);
  if (move === null) return fail(Issue.INVALID_KIND);
  if (move.kind !== 'place' && move.kind !== 'move') return fail(Issue.INVALID_KIND);

  if (move.kind === 'place') {
    if (!state.inBounds(move.point)) return fail(Issue.OUT_OF_RANGE);
  } else {
    if (!state.inBounds(move.from) || !state.inBounds(move.to)) return fail(Issue.OUT_OF_RANGE);
  }
  if (move.capture !== NONE_CAPTURE && !state.inBounds(move.capture)) {
    return fail(Issue.OUT_OF_RANGE);
  }

  const mine = state.moverCell();
  const scratch = state.board.slice();

  if (move.kind === 'place') {
    if (state.moverHand() === 0) return fail(Issue.HAND_EMPTY);
    if (!state.isEmpty(move.point)) return fail(Issue.OCCUPIED);
    scratch[move.point] = mine;
  } else {
    if (state.moverHand() > 0) return fail(Issue.MOVE_WITH_HAND);
    if (state.board[move.from] === Cell.EMPTY) return fail(Issue.EMPTY_ORIGIN);
    if (state.board[move.from] !== mine) return fail(Issue.NOT_YOUR_PIECE);
    if (!state.isEmpty(move.to)) return fail(Issue.OCCUPIED);
    const flying = NineMensMorrisRules.phaseOf(state, state.sideToMove) === 'flying';
    if (!flying && !NineMensMorrisRules.areAdjacent(move.from, move.to)) {
      return fail(Issue.NOT_ADJACENT);
    }
    scratch[move.from] = Cell.EMPTY;
    scratch[move.to] = mine;
  }

  const formed = NineMensMorrisRules.millFormedAt(scratch, move.land, mine);
  if (!formed) {
    return move.capture === NONE_CAPTURE ? OK_RESULT : fail(Issue.CAPTURE_FORBIDDEN);
  }
  const targets = NineMensMorrisRules.captureTargets(scratch, mine);
  if (targets.length === 0) {
    return move.capture === NONE_CAPTURE ? OK_RESULT : fail(Issue.CAPTURE_TARGET);
  }
  if (move.capture === NONE_CAPTURE) return fail(Issue.CAPTURE_REQUIRED);
  return targets.includes(move.capture) ? OK_RESULT : fail(Issue.CAPTURE_TARGET);
}

export function errorText(issue: Issue): string {
  switch (issue) {
    case Issue.OK:
      return '';
    case Issue.GAME_OVER:
      return 'The game is over. Restart to play again.';
    case Issue.INVALID_KIND:
      return 'That is not a valid move.';
    case Issue.OUT_OF_RANGE:
      return 'That point is not on the board.';
    case Issue.HAND_EMPTY:
      return 'You have no pieces left to place.';
    case Issue.MOVE_WITH_HAND:
      return 'You must place your remaining pieces before moving.';
    case Issue.EMPTY_ORIGIN:
      return 'There is no piece on that point.';
    case Issue.NOT_YOUR_PIECE:
      return "You cannot move your opponent's piece.";
    case Issue.OCCUPIED:
      return 'That point is already occupied.';
    case Issue.NOT_ADJACENT:
      return 'A piece may only step to an adjacent point.';
    case Issue.CAPTURE_REQUIRED:
      return 'You formed a mill and must remove an enemy piece.';
    case Issue.CAPTURE_FORBIDDEN:
      return 'No mill was formed, so no piece may be removed.';
    case Issue.CAPTURE_TARGET:
      return 'You may only remove an enemy piece that is not in a mill.';
    default:
      return 'That move is not allowed.';
  }
}

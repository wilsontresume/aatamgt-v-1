/**
 * Decides whether a requested Move is legal in a given state.
 * Pure function of (state, move) — no mutation.
 *
 * Deterministic port of src/games/aadu_puli/aadu_puli_validator.gd.
 * Error precedence (tests assert on it): game over → move sanity →
 * phase and side rules → piece ownership → geometry → destination.
 */

import { Move, MoveKind } from './aadu-puli.move';
import { Cell, GameResult, GameState, Side } from './aadu-puli.state';
import { AaduPuliRules } from './aadu-puli.rules';

export enum Issue {
  OK = 0,
  GAME_OVER = 1,
  INVALID_KIND = 2,
  OUT_OF_RANGE = 3,
  WRONG_SIDE = 4,
  PLACEMENT_PHASE_REQUIRED = 5,
  SLIDE_PHASE_REQUIRED = 6,
  OCCUPIED = 7,
  EMPTY_ORIGIN = 8,
  NOT_YOUR_PIECE = 9,
  NOT_ADJACENT = 10,
  JUMP_GEOMETRY = 11,
  JUMP_NOT_A_GOAT = 12,
  JUMP_LANDING = 13,
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

  switch (move.kind) {
    case MoveKind.PLACE:
      return validatePlacement(state, move);
    case MoveKind.STEP:
      return validateStep(state, move);
    case MoveKind.JUMP:
      return validateJump(state, move);
    default:
      return fail(Issue.INVALID_KIND);
  }
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
    case Issue.WRONG_SIDE:
      return "It is not that side's turn.";
    case Issue.PLACEMENT_PHASE_REQUIRED:
      return 'Goats must still be placed before they can slide.';
    case Issue.SLIDE_PHASE_REQUIRED:
      return 'All goats are on the board — move a goat instead.';
    case Issue.OCCUPIED:
      return 'That point is already occupied.';
    case Issue.EMPTY_ORIGIN:
      return 'There is no piece on that point.';
    case Issue.NOT_YOUR_PIECE:
      return "You cannot move your opponent's piece.";
    case Issue.NOT_ADJACENT:
      return 'Pieces move along the lines to the next point.';
    case Issue.JUMP_GEOMETRY:
      return 'A jump must follow one straight line.';
    case Issue.JUMP_NOT_A_GOAT:
      return 'A tiger can only jump over a goat.';
    case Issue.JUMP_LANDING:
      return 'The landing point must be empty.';
    default:
      return 'That move is not allowed.';
  }
}

function validatePlacement(state: GameState, move: Move): Verdict {
  if (state.sideToMove !== Side.GOATS) return fail(Issue.WRONG_SIDE);
  if (state.goatsInHand <= 0) return fail(Issue.SLIDE_PHASE_REQUIRED);
  if (!state.inBounds(move.to)) return fail(Issue.OUT_OF_RANGE);
  if (!state.isEmpty(move.to)) return fail(Issue.OCCUPIED);
  return OK_RESULT;
}

function validateStep(state: GameState, move: Move): Verdict {
  if (!state.inBounds(move.from) || !state.inBounds(move.to)) return fail(Issue.OUT_OF_RANGE);
  // Goats may only slide once every goat is on the board.
  if (state.sideToMove === Side.GOATS && state.goatsInHand > 0) {
    return fail(Issue.PLACEMENT_PHASE_REQUIRED);
  }
  if (state.cell(move.from) === Cell.EMPTY) return fail(Issue.EMPTY_ORIGIN);
  const expected =
    state.sideToMove === Side.GOATS ? Cell.GOAT : Cell.TIGER;
  if (state.cell(move.from) !== expected) return fail(Issue.NOT_YOUR_PIECE);
  if (!AaduPuliRules.areAdjacent(move.from, move.to)) return fail(Issue.NOT_ADJACENT);
  if (!state.isEmpty(move.to)) return fail(Issue.OCCUPIED);
  return OK_RESULT;
}

function validateJump(state: GameState, move: Move): Verdict {
  if (
    !state.inBounds(move.from) ||
    !state.inBounds(move.to) ||
    !state.inBounds(move.over)
  ) {
    return fail(Issue.OUT_OF_RANGE);
  }
  if (state.sideToMove !== Side.TIGERS) return fail(Issue.WRONG_SIDE);
  if (state.cell(move.from) !== Cell.TIGER) return fail(Issue.NOT_YOUR_PIECE);
  if (state.cell(move.over) !== Cell.GOAT) return fail(Issue.JUMP_NOT_A_GOAT);
  if (!AaduPuliRules.isJumpLine(move.from, move.over, move.to)) {
    return fail(Issue.JUMP_GEOMETRY);
  }
  if (!state.isEmpty(move.to)) return fail(Issue.JUMP_LANDING);
  return OK_RESULT;
}

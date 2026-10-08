/**
 * Decides whether a requested Move is legal in a given state.
 * Pure function of (state, move) — no mutation of the inputs.
 *
 * Error precedence (tests assert on it): game over → move sanity →
 * bounds → side/ownership → geometry → destination → chain progress.
 * Chains are verified on a scratch board so occupancy reflects every
 * earlier hop of the same move (docs/solah_seedi_rules.md §4).
 */

import { MAX_PATH_POINTS, Move } from './solah-seedi.move';
import { SolahSeediRules } from './solah-seedi.rules';
import { Cell, GameResult, GameState } from './solah-seedi.state';

export enum Issue {
  OK = 0,
  GAME_OVER = 1,
  INVALID_KIND = 2,
  OUT_OF_RANGE = 3,
  EMPTY_ORIGIN = 4,
  NOT_YOUR_PIECE = 5,
  OCCUPIED = 6,
  CHAIN_STEP = 7,
  JUMP_GEOMETRY = 8,
  JUMP_NOT_ENEMY = 9,
  JUMP_LANDING = 10,
  PATH_AFTER_WIN = 11,
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
  const path = move.path;
  if (path.length < 2 || path.length > MAX_PATH_POINTS) return fail(Issue.INVALID_KIND);
  for (const point of path) {
    if (!state.inBounds(point)) return fail(Issue.OUT_OF_RANGE);
  }

  const mine = state.moverCell();
  const enemy = mine === Cell.RED ? Cell.GREEN : Cell.RED;
  if (state.board[path[0]] === Cell.EMPTY) return fail(Issue.EMPTY_ORIGIN);
  if (state.board[path[0]] !== mine) return fail(Issue.NOT_YOUR_PIECE);

  // Two adjacent points: a simple step (spec §4.1).
  if (path.length === 2 && SolahSeediRules.areAdjacent(path[0], path[1])) {
    if (state.board[path[1]] !== Cell.EMPTY) return fail(Issue.OCCUPIED);
    return OK_RESULT;
  }

  // Everything else is a jump or a chain of jumps (spec §4.2–4.3).
  const scratch = state.board.slice();
  scratch[path[0]] = Cell.EMPTY;
  for (let i = 1; i < path.length; i++) {
    const from = path[i - 1];
    const to = path[i];
    if (SolahSeediRules.areAdjacent(from, to)) return fail(Issue.CHAIN_STEP);
    const middle = SolahSeediRules.jumpMiddle(from, to);
    if (middle === null) return fail(Issue.JUMP_GEOMETRY);
    if (scratch[middle] !== enemy) return fail(Issue.JUMP_NOT_ENEMY);
    if (scratch[to] !== Cell.EMPTY) return fail(Issue.JUMP_LANDING);
    scratch[middle] = Cell.EMPTY;
    scratch[from] = Cell.EMPTY;
    scratch[to] = mine;
    const decided = SolahSeediRules.positionWins(mine, to, scratch);
    if (decided && i < path.length - 1) return fail(Issue.PATH_AFTER_WIN);
  }
  return OK_RESULT;
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
    case Issue.EMPTY_ORIGIN:
      return 'There is no piece on that point.';
    case Issue.NOT_YOUR_PIECE:
      return "You cannot move your opponent's piece.";
    case Issue.OCCUPIED:
      return 'That point is already occupied.';
    case Issue.CHAIN_STEP:
      return 'Every hop of a chain must be a jump over an enemy piece.';
    case Issue.JUMP_GEOMETRY:
      return 'A jump must follow one straight line.';
    case Issue.JUMP_NOT_ENEMY:
      return 'You can only jump over an enemy piece.';
    case Issue.JUMP_LANDING:
      return 'The landing point must be empty.';
    case Issue.PATH_AFTER_WIN:
      return 'An earlier hop already ends the game.';
    default:
      return 'That move is not allowed.';
  }
}

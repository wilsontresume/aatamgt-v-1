class_name NineMensMorrisValidator
extends RefCounted
## Decides whether a requested NineMensMorrisMove is legal in a given
## state. Pure function of (state, move) — no UI, no mutation.
##
## Error precedence (tests assert on it, spec §10): game over → move
## shape → point bounds → phase/ownership → geometry → mill/capture
## consistency. Scratch boards mirror the mover's action so mill
## detection always sees the position after the landing.

enum Issue {
	OK,
	GAME_OVER,
	INVALID_KIND,
	OUT_OF_RANGE,
	HAND_EMPTY,
	MOVE_WITH_HAND,
	EMPTY_ORIGIN,
	NOT_YOUR_PIECE,
	OCCUPIED,
	NOT_ADJACENT,
	CAPTURE_REQUIRED,
	CAPTURE_FORBIDDEN,
	CAPTURE_TARGET,
}

const OK_RESULT := {"ok": true, "issue": Issue.OK}


static func validate(state: NineMensMorrisGameState,
		move: NineMensMorrisMove) -> Dictionary:
	if state == null:
		return _fail(Issue.INVALID_KIND)
	if state.result != NineMensMorrisGameState.Result.NONE:
		return _fail(Issue.GAME_OVER)
	if move == null:
		return _fail(Issue.INVALID_KIND)
	if move.kind != NineMensMorrisMove.KIND_PLACE \
			and move.kind != NineMensMorrisMove.KIND_MOVE:
		return _fail(Issue.INVALID_KIND)

	if move.kind == NineMensMorrisMove.KIND_PLACE:
		if not state.in_bounds(move.point):
			return _fail(Issue.OUT_OF_RANGE)
	else:
		if not state.in_bounds(move.from_point) \
				or not state.in_bounds(move.to_point):
			return _fail(Issue.OUT_OF_RANGE)
	if move.capture != NineMensMorrisMove.NONE_CAPTURE \
			and not state.in_bounds(move.capture):
		return _fail(Issue.OUT_OF_RANGE)

	var mine := state.mover_cell()
	var scratch: Array[int] = []
	scratch.assign(state.board)

	if move.kind == NineMensMorrisMove.KIND_PLACE:
		if state.mover_hand() == 0:
			return _fail(Issue.HAND_EMPTY)
		if not state.is_empty(move.point):
			return _fail(Issue.OCCUPIED)
		scratch[move.point] = mine
	else:
		if state.mover_hand() > 0:
			return _fail(Issue.MOVE_WITH_HAND)
		if state.board[move.from_point] == NineMensMorrisGameState.Cell.EMPTY:
			return _fail(Issue.EMPTY_ORIGIN)
		if state.board[move.from_point] != mine:
			return _fail(Issue.NOT_YOUR_PIECE)
		if not state.is_empty(move.to_point):
			return _fail(Issue.OCCUPIED)
		var flying := NineMensMorrisRules.phase_of(state,
				state.side_to_move) == NineMensMorrisRules.PHASE_FLYING
		if not flying and not NineMensMorrisRules.are_adjacent(
				move.from_point, move.to_point):
			return _fail(Issue.NOT_ADJACENT)
		scratch[move.from_point] = NineMensMorrisGameState.Cell.EMPTY
		scratch[move.to_point] = mine

	var formed := NineMensMorrisRules.mill_formed_at(scratch, move.land(), mine)
	if not formed:
		if move.capture == NineMensMorrisMove.NONE_CAPTURE:
			return OK_RESULT
		return _fail(Issue.CAPTURE_FORBIDDEN)
	var targets := NineMensMorrisRules.capture_targets(scratch, mine)
	if targets.is_empty():
		if move.capture == NineMensMorrisMove.NONE_CAPTURE:
			return OK_RESULT
		return _fail(Issue.CAPTURE_TARGET)
	if move.capture == NineMensMorrisMove.NONE_CAPTURE:
		return _fail(Issue.CAPTURE_REQUIRED)
	return OK_RESULT if targets.has(move.capture) else _fail(Issue.CAPTURE_TARGET)


static func error_text(issue: int) -> String:
	match issue:
		Issue.OK:
			return ""
		Issue.GAME_OVER:
			return "The game is over. Restart to play again."
		Issue.INVALID_KIND:
			return "That is not a valid move."
		Issue.OUT_OF_RANGE:
			return "That point is not on the board."
		Issue.HAND_EMPTY:
			return "You have no pieces left to place."
		Issue.MOVE_WITH_HAND:
			return "You must place your remaining pieces before moving."
		Issue.EMPTY_ORIGIN:
			return "There is no piece on that point."
		Issue.NOT_YOUR_PIECE:
			return "You cannot move your opponent's piece."
		Issue.OCCUPIED:
			return "That point is already occupied."
		Issue.NOT_ADJACENT:
			return "A piece may only step to an adjacent point."
		Issue.CAPTURE_REQUIRED:
			return "You formed a mill and must remove an enemy piece."
		Issue.CAPTURE_FORBIDDEN:
			return "No mill was formed, so no piece may be removed."
		Issue.CAPTURE_TARGET:
			return "You may only remove an enemy piece that is not in a mill."
		_:
			return "That move is not allowed."


static func _fail(issue: int) -> Dictionary:
	return {"ok": false, "issue": issue}

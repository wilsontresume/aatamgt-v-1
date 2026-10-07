class_name AaduPuliValidator
extends RefCounted
## Decides whether a requested AaduPuliMove is legal in a given state.
## Pure function of (state, move) — no UI, no mutation.
##
## Error precedence (also what tests assert on): game over → move
## sanity/out-of-range → phase and side rules → piece ownership →
## geometry → destination occupancy.

enum Issue {
	OK,
	GAME_OVER,
	INVALID_KIND,
	OUT_OF_RANGE,
	WRONG_SIDE,
	PLACEMENT_PHASE_REQUIRED,  # goats still in hand: must place, not slide
	SLIDE_PHASE_REQUIRED,      # hand empty: goats must slide, not place
	OCCUPIED,
	EMPTY_ORIGIN,
	NOT_YOUR_PIECE,
	NOT_ADJACENT,
	JUMP_GEOMETRY,
	JUMP_NOT_A_GOAT,
	JUMP_LANDING,
}

const OK_RESULT := {"ok": true, "issue": Issue.OK}


static func validate(state: AaduPuliGameState, move: AaduPuliMove) -> Dictionary:
	if state == null:
		return _fail(Issue.INVALID_KIND)
	if state.result != AaduPuliGameState.Result.NONE:
		return _fail(Issue.GAME_OVER)
	if move == null:
		return _fail(Issue.INVALID_KIND)

	match move.kind:
		AaduPuliMove.Kind.PLACE:
			return _validate_placement(state, move)
		AaduPuliMove.Kind.STEP:
			return _validate_step(state, move)
		AaduPuliMove.Kind.JUMP:
			return _validate_jump(state, move)
	return _fail(Issue.INVALID_KIND)


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
		Issue.WRONG_SIDE:
			return "It is not that side's turn."
		Issue.PLACEMENT_PHASE_REQUIRED:
			return "Goats must still be placed before they can slide."
		Issue.SLIDE_PHASE_REQUIRED:
			return "All goats are on the board — move a goat instead."
		Issue.OCCUPIED:
			return "That point is already occupied."
		Issue.EMPTY_ORIGIN:
			return "There is no piece on that point."
		Issue.NOT_YOUR_PIECE:
			return "You cannot move your opponent's piece."
		Issue.NOT_ADJACENT:
			return "Pieces move along the lines to the next point."
		Issue.JUMP_GEOMETRY:
			return "A jump must follow one straight line."
		Issue.JUMP_NOT_A_GOAT:
			return "A tiger can only jump over a goat."
		Issue.JUMP_LANDING:
			return "The landing point must be empty."
		_:
			return "That move is not allowed."


# ----------------------------------------------------------------------

static func _validate_placement(state: AaduPuliGameState,
		move: AaduPuliMove) -> Dictionary:
	if state.side_to_move != AaduPuliGameState.Side.GOATS:
		return _fail(Issue.WRONG_SIDE)
	if state.goats_in_hand <= 0:
		return _fail(Issue.SLIDE_PHASE_REQUIRED)
	if not state.in_bounds(move.to_point):
		return _fail(Issue.OUT_OF_RANGE)
	if not state.is_empty(move.to_point):
		return _fail(Issue.OCCUPIED)
	return OK_RESULT


static func _validate_step(state: AaduPuliGameState,
		move: AaduPuliMove) -> Dictionary:
	if not state.in_bounds(move.from_point) or not state.in_bounds(move.to_point):
		return _fail(Issue.OUT_OF_RANGE)
	# Goats may only slide once every goat is on the board.
	if state.side_to_move == AaduPuliGameState.Side.GOATS \
			and state.goats_in_hand > 0:
		return _fail(Issue.PLACEMENT_PHASE_REQUIRED)
	if state.cell(move.from_point) == AaduPuliGameState.Cell.EMPTY:
		return _fail(Issue.EMPTY_ORIGIN)
	var is_goat_turn := state.side_to_move == AaduPuliGameState.Side.GOATS
	var expected := AaduPuliGameState.Cell.GOAT if is_goat_turn \
			else AaduPuliGameState.Cell.TIGER
	if state.cell(move.from_point) != expected:
		return _fail(Issue.NOT_YOUR_PIECE)
	if not AaduPuliRules.are_adjacent(move.from_point, move.to_point):
		return _fail(Issue.NOT_ADJACENT)
	if not state.is_empty(move.to_point):
		return _fail(Issue.OCCUPIED)
	return OK_RESULT


static func _validate_jump(state: AaduPuliGameState,
		move: AaduPuliMove) -> Dictionary:
	if not state.in_bounds(move.from_point) or not state.in_bounds(move.to_point) \
			or not state.in_bounds(move.over_point):
		return _fail(Issue.OUT_OF_RANGE)
	if state.side_to_move != AaduPuliGameState.Side.TIGERS:
		return _fail(Issue.WRONG_SIDE)
	if state.cell(move.from_point) != AaduPuliGameState.Cell.TIGER:
		return _fail(Issue.NOT_YOUR_PIECE)
	if state.cell(move.over_point) != AaduPuliGameState.Cell.GOAT:
		return _fail(Issue.JUMP_NOT_A_GOAT)
	if not AaduPuliRules.is_jump_line(move.from_point, move.over_point,
			move.to_point):
		return _fail(Issue.JUMP_GEOMETRY)
	if not state.is_empty(move.to_point):
		return _fail(Issue.JUMP_LANDING)
	return OK_RESULT


static func _fail(issue: int) -> Dictionary:
	return {"ok": false, "issue": issue}

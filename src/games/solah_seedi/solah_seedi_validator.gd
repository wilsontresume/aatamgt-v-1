class_name SolahSeediValidator
extends RefCounted
## Decides whether a requested SolahSeediMove is legal in a given state.
## Pure function of (state, move) — no UI, no mutation.
##
## Error precedence (tests assert on it): game over → move sanity →
## bounds → side/ownership → geometry → destination → chain progress.
## Chains are verified on a scratch board so occupancy reflects every
## earlier hop of the same move (docs/solah_seedi_rules.md §4).

enum Issue {
	OK,
	GAME_OVER,
	INVALID_KIND,
	OUT_OF_RANGE,
	EMPTY_ORIGIN,
	NOT_YOUR_PIECE,
	OCCUPIED,
	CHAIN_STEP,
	JUMP_GEOMETRY,
	JUMP_NOT_ENEMY,
	JUMP_LANDING,
	PATH_AFTER_WIN,
}

const OK_RESULT := {"ok": true, "issue": Issue.OK}


static func validate(state: SolahSeediGameState,
		move: SolahSeediMove) -> Dictionary:
	if state == null:
		return _fail(Issue.INVALID_KIND)
	if state.result != SolahSeediGameState.Result.NONE:
		return _fail(Issue.GAME_OVER)
	if move == null:
		return _fail(Issue.INVALID_KIND)
	var path := move.path
	if path.size() < 2 or path.size() > SolahSeediMove.MAX_PATH_POINTS:
		return _fail(Issue.INVALID_KIND)
	for point in path:
		if not state.in_bounds(point):
			return _fail(Issue.OUT_OF_RANGE)

	var mine := state.mover_cell()
	var enemy: int = SolahSeediGameState.Cell.GREEN \
			if mine == SolahSeediGameState.Cell.RED \
			else SolahSeediGameState.Cell.RED
	if state.board[path[0]] == SolahSeediGameState.Cell.EMPTY:
		return _fail(Issue.EMPTY_ORIGIN)
	if state.board[path[0]] != mine:
		return _fail(Issue.NOT_YOUR_PIECE)

	# Two adjacent points: a simple step (spec §4.1).
	if path.size() == 2 and SolahSeediRules.are_adjacent(path[0], path[1]):
		if state.board[path[1]] != SolahSeediGameState.Cell.EMPTY:
			return _fail(Issue.OCCUPIED)
		return OK_RESULT

	# Everything else is a jump or a chain of jumps (spec §4.2–4.3).
	var scratch: Array[int] = []
	scratch.assign(state.board)
	scratch[path[0]] = SolahSeediGameState.Cell.EMPTY
	for i in range(1, path.size()):
		var from_point := path[i - 1]
		var to_point := path[i]
		if SolahSeediRules.are_adjacent(from_point, to_point):
			return _fail(Issue.CHAIN_STEP)
		var middle := SolahSeediRules.jump_middle(from_point, to_point)
		if middle == SolahSeediMove.NONE_POINT:
			return _fail(Issue.JUMP_GEOMETRY)
		if scratch[middle] != enemy:
			return _fail(Issue.JUMP_NOT_ENEMY)
		if scratch[to_point] != SolahSeediGameState.Cell.EMPTY:
			return _fail(Issue.JUMP_LANDING)
		scratch[middle] = SolahSeediGameState.Cell.EMPTY
		scratch[from_point] = SolahSeediGameState.Cell.EMPTY
		scratch[to_point] = mine
		var decided := SolahSeediRules.position_wins(mine, to_point, scratch)
		if decided and i < path.size() - 1:
			return _fail(Issue.PATH_AFTER_WIN)
	return OK_RESULT


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
		Issue.EMPTY_ORIGIN:
			return "There is no piece on that point."
		Issue.NOT_YOUR_PIECE:
			return "You cannot move your opponent's piece."
		Issue.OCCUPIED:
			return "That point is already occupied."
		Issue.CHAIN_STEP:
			return "Every hop of a chain must be a jump over an enemy piece."
		Issue.JUMP_GEOMETRY:
			return "A jump must follow one straight line."
		Issue.JUMP_NOT_ENEMY:
			return "You can only jump over an enemy piece."
		Issue.JUMP_LANDING:
			return "The landing point must be empty."
		Issue.PATH_AFTER_WIN:
			return "An earlier hop already ends the game."
		_:
			return "That move is not allowed."


static func _fail(issue: int) -> Dictionary:
	return {"ok": false, "issue": issue}

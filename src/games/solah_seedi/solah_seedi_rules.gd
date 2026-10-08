class_name SolahSeediRules
extends RefCounted
## Board topology, move generation, state transitions and outcome
## evaluation for Solah Seedi (16 Soldiers). Pure rules engine — it
## never touches the UI and is fully deterministic.
##
## Implements docs/solah_seedi_rules.md exactly.

## Ordered polylines of the chart (spec §2). The board renderer draws
## these; adjacency and jump geometry derive from them.
const LINES: Array = [
	# Horizontal lattice rows.
	[6, 7, 8, 9, 10],
	[11, 12, 13, 14, 15],
	[16, 17, 18, 19, 20],
	[21, 22, 23, 24, 25],
	[26, 27, 28, 29, 30],
	# Triangle horizontals.
	[0, 1, 2],
	[3, 4, 5],
	[31, 32, 33],
	[34, 35, 36],
	# Vertical lattice columns + the whole-board centre vertical.
	[6, 11, 16, 21, 26],
	[7, 12, 17, 22, 27],
	[1, 4, 8, 13, 18, 23, 28, 32, 35],
	[9, 14, 19, 24, 29],
	[10, 15, 20, 25, 30],
	# Diagonals: down-right chains.
	[0, 3, 8, 14, 20],
	[6, 12, 18, 24, 30],
	[20, 24, 28, 31, 34],
	# Diagonals: down-left chains.
	[2, 5, 8, 12, 16],
	[10, 14, 18, 22, 26],
	[16, 22, 28, 33, 36],
]

static var _adjacency: Dictionary = {}
static var _jump_middles: Dictionary = {}
static var _jump_options: Dictionary = {}


# --- Topology -----------------------------------------------------------

## Neighbors of `point` in deterministic edge-insertion order.
static func neighbors(point: int) -> Array[int]:
	_ensure_tables()
	var result: Array[int] = []
	if _adjacency.has(point):
		for value in _adjacency[point] as Array:
			result.append(int(value))
	return result


static func are_adjacent(a: int, b: int) -> bool:
	_ensure_tables()
	if not _adjacency.has(a):
		return false
	return (_adjacency[a] as Array).has(b)


## The unique middle point of a two-step jump from `a` to `b`, or -1
## when (a, b) is not a legal jump pair (spec §2 proves it unique: the
## middle of three consecutive straight points lies strictly between
## them, so a jump can be written by its landings alone).
static func jump_middle(a: int, b: int) -> int:
	_ensure_tables()
	if not _jump_middles.has(_jump_key(a, b)):
		return SolahSeediMove.NONE_POINT
	return int(_jump_middles[_jump_key(a, b)])


## Every geometrically possible jump starting at `point` (state-free):
## dictionaries {"to": landing, "over": jumped point}.
static func jump_options_from(point: int) -> Array[Dictionary]:
	_ensure_tables()
	var result: Array[Dictionary] = []
	if _jump_options.has(point):
		for option in _jump_options[point] as Array:
			result.append((option as Dictionary).duplicate())
	return result


## Notation for a move (spec §4.4): `6-7`, `6-18*`, `6-18-30*`
## (`*` marks any move containing at least one capture).
static func notation(move: SolahSeediMove) -> String:
	if move == null or move.path.is_empty():
		return ""
	var text := ""
	for i in move.path.size():
		if i > 0:
			text += "-"
		text += str(move.path[i])
	return text + "*" if move.is_capture() else text


# --- Move generation ----------------------------------------------------

## All legal moves for the side to move, in deterministic order:
## every step, plus every capture-chain prefix (a chain may be stopped
## after any hop, but never extended past a hop that ends the game).
## Empty when the game is over.
static func legal_moves(state: SolahSeediGameState) -> Array[SolahSeediMove]:
	var moves: Array[SolahSeediMove] = []
	if state == null or state.result != SolahSeediGameState.Result.NONE:
		return moves
	var mine := state.mover_cell()
	for point in SolahSeediGameState.POINT_COUNT:
		if state.board[point] != mine:
			continue
		for neighbor in neighbors(point):
			if state.is_empty(neighbor):
				moves.append(SolahSeediMove.step(point, neighbor))
		var scratch: Array[int] = []
		scratch.assign(state.board)
		var start: Array[int] = [point]
		_collect_chains(scratch, mine, point, start, moves)
	return moves


## Legal moves whose origin is `point`.
static func legal_moves_from(state: SolahSeediGameState,
		point: int) -> Array[SolahSeediMove]:
	var moves: Array[SolahSeediMove] = []
	for move in legal_moves(state):
		if move.from_point() == point:
			moves.append(move)
	return moves


# --- Transitions --------------------------------------------------------

## Applies a validated move to a fresh state (the input is never
## mutated). Returns null when the move is not legal. Wins are
## evaluated after every hop (spec §4.3/§5): a hop that wins ends the
## move immediately, whatever longer path was intended.
static func apply(state: SolahSeediGameState,
		move: SolahSeediMove) -> SolahSeediGameState:
	var verdict := SolahSeediValidator.validate(state, move)
	if not verdict.ok:
		return null
	var next := state.duplicate()
	var mover := state.side_to_move
	var mine := state.mover_cell()
	var path := move.path

	next.board[path[0]] = SolahSeediGameState.Cell.EMPTY
	var captured := 0
	for i in range(1, path.size()):
		var from_point := path[i - 1]
		var to_point := path[i]
		if not are_adjacent(from_point, to_point):
			var middle := jump_middle(from_point, to_point)
			if middle == SolahSeediMove.NONE_POINT:
				return null  # unreachable: validated
			if next.board[middle] != SolahSeediGameState.Cell.EMPTY:
				next.board[middle] = SolahSeediGameState.Cell.EMPTY
				captured += 1
		next.board[from_point] = SolahSeediGameState.Cell.EMPTY
		next.board[to_point] = mine
		if position_wins(mine, to_point, next.board):
			next.result = SolahSeediGameState.Result.RED_WIN \
					if mover == SolahSeediGameState.Side.RED \
					else SolahSeediGameState.Result.GREEN_WIN
			break

	next.ply += 1
	next.plies_since_capture = 0 if captured > 0 \
			else state.plies_since_capture + 1
	next.side_to_move = SolahSeediGameState.Side.GREEN \
			if mover == SolahSeediGameState.Side.RED \
			else SolahSeediGameState.Side.RED
	next.result = evaluate(next)
	return next


# --- Outcomes -----------------------------------------------------------

## Outcome for `state` (spec §5, in order: capture-all → breakthrough →
## immobilisation → draw). Called after every applied move; also safe on
## any deserialised position.
static func evaluate(state: SolahSeediGameState) -> int:
	if state.result != SolahSeediGameState.Result.NONE:
		return state.result
	if state.count_pieces(SolahSeediGameState.Cell.GREEN) == 0:
		return SolahSeediGameState.Result.RED_WIN
	if state.count_pieces(SolahSeediGameState.Cell.RED) == 0:
		return SolahSeediGameState.Result.GREEN_WIN
	# Breakthrough is positional: any open position with a piece on the
	# enemy triangle can only arise from the hop that just won.
	for point in SolahSeediGameState.GREEN_TRIANGLE:
		if state.board[int(point)] == SolahSeediGameState.Cell.RED:
			return SolahSeediGameState.Result.RED_WIN
	for point in SolahSeediGameState.RED_TRIANGLE:
		if state.board[int(point)] == SolahSeediGameState.Cell.GREEN:
			return SolahSeediGameState.Result.GREEN_WIN
	if legal_moves(state).is_empty():
		return SolahSeediGameState.Result.GREEN_WIN \
				if state.side_to_move == SolahSeediGameState.Side.RED \
				else SolahSeediGameState.Result.RED_WIN
	if state.plies_since_capture >= SolahSeediGameState.PLIES_TO_DRAW:
		return SolahSeediGameState.Result.DRAW
	return SolahSeediGameState.Result.NONE


## True when `mine` has just landed on `point` and thereby won
## (spec §5.1 capture-all, §5.2 breakthrough). Positional and pure.
static func position_wins(mine: int, point: int, board: Array[int]) -> bool:
	var enemy: int = SolahSeediGameState.Cell.GREEN \
			if mine == SolahSeediGameState.Cell.RED \
			else SolahSeediGameState.Cell.RED
	var enemy_count := 0
	for cell_value in board:
		if cell_value == enemy:
			enemy_count += 1
	if enemy_count == 0:
		return true
	var target: Array = SolahSeediGameState.GREEN_TRIANGLE \
			if mine == SolahSeediGameState.Cell.RED \
			else SolahSeediGameState.RED_TRIANGLE
	return target.has(point)


# --- internals ----------------------------------------------------------

## Extends `path` with every further legal hop from `from_point`,
## mutating `board` (a scratch copy) as the chain progresses so
## occupancy reflects earlier hops. Every prefix is pushed — the chain
## may stop after any hop — but a hop that wins is never extended.
static func _collect_chains(board: Array[int], mine: int, from_point: int,
		path: Array[int], moves: Array[SolahSeediMove]) -> void:
	var enemy: int = SolahSeediGameState.Cell.GREEN \
			if mine == SolahSeediGameState.Cell.RED \
			else SolahSeediGameState.Cell.RED
	for option in jump_options_from(from_point):
		var landing := int(option["to"])
		var over := int(option["over"])
		if board[over] != enemy:
			continue
		if board[landing] != SolahSeediGameState.Cell.EMPTY:
			continue
		var chain_path: Array[int] = []
		chain_path.assign(path)
		chain_path.append(landing)
		board[over] = SolahSeediGameState.Cell.EMPTY
		board[from_point] = SolahSeediGameState.Cell.EMPTY
		board[landing] = mine
		moves.append(SolahSeediMove.from_path(chain_path))
		if not position_wins(mine, landing, board):
			_collect_chains(board, mine, landing, chain_path, moves)
		board[landing] = SolahSeediGameState.Cell.EMPTY
		board[over] = enemy
		board[from_point] = mine


static func _ensure_tables() -> void:
	if not _adjacency.is_empty():
		return
	for line in LINES:
		# Adjacency: consecutive pairs (deduplicated, insertion-ordered).
		for i in line.size() - 1:
			_add_edge(int(line[i]), int(line[i + 1]))
		# Jumps: consecutive triples, in both directions.
		for i in line.size() - 2:
			var a := int(line[i])
			var over := int(line[i + 1])
			var c := int(line[i + 2])
			_add_jump(a, over, c)
			_add_jump(c, over, a)


static func _add_edge(a: int, b: int) -> void:
	if not _adjacency.has(a):
		_adjacency[a] = []
	if not _adjacency.has(b):
		_adjacency[b] = []
	if not (_adjacency[a] as Array).has(b):
		(_adjacency[a] as Array).append(b)
	if not (_adjacency[b] as Array).has(a):
		(_adjacency[b] as Array).append(a)


static func _add_jump(from_point: int, over_point: int, to_point: int) -> void:
	_jump_middles[_jump_key(from_point, to_point)] = over_point
	if not _jump_options.has(from_point):
		_jump_options[from_point] = []
	(_jump_options[from_point] as Array).append(
			{"to": to_point, "over": over_point})


static func _jump_key(a: int, b: int) -> String:
	return "%d,%d" % [a, b]

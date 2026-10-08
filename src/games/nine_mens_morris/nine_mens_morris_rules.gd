class_name NineMensMorrisRules
extends RefCounted
## Board topology, move generation, state transitions and outcome
## evaluation for Nine Men's Morris. Pure rules engine — it never
## touches the UI and is fully deterministic.
##
## Implements docs/nine_mens_morris_rules.md exactly.

## The 32 board edges, each listed once (spec §2).
const EDGES: Array = [
	# Outer square.
	[0, 1], [1, 2], [2, 3], [3, 4], [4, 5], [5, 6], [6, 7], [7, 0],
	# Middle square.
	[8, 9], [9, 10], [10, 11], [11, 12], [12, 13], [13, 14], [14, 15], [15, 8],
	# Inner square.
	[16, 17], [17, 18], [18, 19], [19, 20], [20, 21], [21, 22], [22, 23], [23, 16],
	# Radial arms.
	[1, 9], [9, 17], [3, 11], [11, 19], [5, 13], [13, 21], [7, 15], [15, 23],
]

## The 16 mill lines (spec §5).
const MILLS: Array = [
	[0, 1, 2], [2, 3, 4], [4, 5, 6], [6, 7, 0],
	[8, 9, 10], [10, 11, 12], [12, 13, 14], [14, 15, 8],
	[16, 17, 18], [18, 19, 20], [20, 21, 22], [22, 23, 16],
	[1, 9, 17], [3, 11, 19], [5, 13, 21], [7, 15, 23],
]

const PHASE_PLACEMENT := "placement"
const PHASE_MOVEMENT := "movement"
const PHASE_FLYING := "flying"

static var _adjacency: Dictionary = {}
static var _mills_through: Dictionary = {}


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


## Mill lines that contain `point`.
static func mills_at(point: int) -> Array:
	_ensure_tables()
	return (_mills_through[point] as Array).duplicate() \
			if _mills_through.has(point) else []


## Notation for a move (spec §10): `P17`, `P17*22`, `17-18`, `17-18*22`.
static func notation(move: NineMensMorrisMove) -> String:
	if move == null:
		return ""
	if move.kind == NineMensMorrisMove.KIND_PLACE:
		var base := "P%d" % move.point
		return "%s*%d" % [base, move.capture] if move.has_capture() else base
	var base := "%d-%d" % [move.from_point, move.to_point]
	return "%s*%d" % [base, move.capture] if move.has_capture() else base


# --- Phases (spec §4) ---------------------------------------------------

## The phase a side is in. Derived from hand and piece count; sides
## differ while one is still placing.
static func phase_of(state: NineMensMorrisGameState, side: int) -> String:
	if state.hand_of(side) > 0:
		return PHASE_PLACEMENT
	if state.count_side(side) == 3:
		return PHASE_FLYING
	return PHASE_MOVEMENT


# --- Mills and captures (spec §5–§6) ------------------------------------

## True when `mine` occupying `point` completes a mill.
static func mill_formed_at(board: Array, point: int, mine: int) -> bool:
	_ensure_tables()
	for mill in mills_at(point):
		var triple := mill as Array
		if board[int(triple[0])] == mine \
				and board[int(triple[1])] == mine \
				and board[int(triple[2])] == mine:
			return true
	return false


## Legal capture targets for `mine` after its mill formed: enemy
## pieces outside mills; when every enemy piece sits in a mill, all of
## them; empty when the enemy has no piece on the board.
static func capture_targets(board: Array, mine: int) -> Array[int]:
	var enemy: int = NineMensMorrisGameState.Cell.GREEN \
			if mine == NineMensMorrisGameState.Cell.RED \
			else NineMensMorrisGameState.Cell.RED
	var enemy_pieces: Array[int] = []
	var outside: Array[int] = []
	for p in NineMensMorrisGameState.POINT_COUNT:
		if board[p] != enemy:
			continue
		enemy_pieces.append(p)
		var in_mill := false
		for mill in mills_at(p):
			var triple := mill as Array
			if board[int(triple[0])] == enemy \
					and board[int(triple[1])] == enemy \
					and board[int(triple[2])] == enemy:
				in_mill = true
				break
		if not in_mill:
			outside.append(p)
	if enemy_pieces.is_empty():
		return []
	return outside if not outside.is_empty() else enemy_pieces


# --- Move generation ----------------------------------------------------

## All legal moves for the side to move, in deterministic order: every
## placement / step / flight, each paired with every legal capture when
## its landing forms a mill (mandatory — with the empty exception of a
## foe-less board). Empty when the game is over.
static func legal_moves(state: NineMensMorrisGameState) -> Array[NineMensMorrisMove]:
	var moves: Array[NineMensMorrisMove] = []
	if state == null or state.result != NineMensMorrisGameState.Result.NONE:
		return moves
	var mine := state.mover_cell()
	var phase := phase_of(state, state.side_to_move)

	if phase == PHASE_PLACEMENT:
		for p in NineMensMorrisGameState.POINT_COUNT:
			if not state.is_empty(p):
				continue
			_collect_for_landing(state.board, mine,
					NineMensMorrisMove.KIND_PLACE, p, NineMensMorrisMove.NONE_POINT, moves)
		return moves

	var flying := phase == PHASE_FLYING
	for origin in NineMensMorrisGameState.POINT_COUNT:
		if state.board[origin] != mine:
			continue
		for dest in NineMensMorrisGameState.POINT_COUNT:
			if not state.is_empty(dest):
				continue
			if not flying and not are_adjacent(origin, dest):
				continue
			_collect_for_landing(state.board, mine,
					NineMensMorrisMove.KIND_MOVE, dest, origin, moves)
	return moves


## Legal moves whose landing point is `point`.
static func legal_moves_landing(state: NineMensMorrisGameState,
		point: int) -> Array[NineMensMorrisMove]:
	var result: Array[NineMensMorrisMove] = []
	for move in legal_moves(state):
		if move.land() == point:
			result.append(move)
	return result


# --- Transitions --------------------------------------------------------

## Applies a legal move to a fresh state (the input is never mutated).
## Returns null when the move is not legal. The forced capture happens
## inside the same turn, then the side toggles, the repetition history
## grows and the outcome is evaluated (spec §6–§8).
static func apply(state: NineMensMorrisGameState,
		move: NineMensMorrisMove) -> NineMensMorrisGameState:
	var verdict := NineMensMorrisValidator.validate(state, move)
	if not verdict.ok:
		return null
	var next := state.duplicate()
	var mover := state.side_to_move
	var mine := state.mover_cell()

	if move.kind == NineMensMorrisMove.KIND_PLACE:
		next.board[move.point] = mine
		next.hands[NineMensMorrisGameState.side_index(mover)] -= 1
	else:
		next.board[move.from_point] = NineMensMorrisGameState.Cell.EMPTY
		next.board[move.to_point] = mine

	var landed := move.land()
	var formed := mill_formed_at(next.board, landed, mine)
	if formed and move.has_capture():
		next.board[move.capture] = NineMensMorrisGameState.Cell.EMPTY

	next.ply += 1
	next.plies_since_capture = 0 if formed and move.has_capture() \
			else state.plies_since_capture + 1
	next.side_to_move = NineMensMorrisGameState.Side.GREEN \
			if mover == NineMensMorrisGameState.Side.RED \
			else NineMensMorrisGameState.Side.RED
	next.history.append(next.repetition_key())
	next.result = evaluate(next)
	return next


# --- Outcomes -----------------------------------------------------------

## Outcome for `state` (spec §7–§8, in order: starvation →
## immobilisation → threefold → fifty-ply limit). Called after every
## applied move; also safe on any deserialised position.
static func evaluate(state: NineMensMorrisGameState) -> int:
	if state.result != NineMensMorrisGameState.Result.NONE:
		return state.result

	var next_side := state.side_to_move
	var mover: int = NineMensMorrisGameState.Side.GREEN \
			if next_side == NineMensMorrisGameState.Side.RED \
			else NineMensMorrisGameState.Side.RED
	var next_cell: int = NineMensMorrisGameState.Cell.RED \
			if next_side == NineMensMorrisGameState.Side.RED \
			else NineMensMorrisGameState.Cell.GREEN

	if state.hand_of(next_side) == 0 and state.count_pieces(next_cell) < 3:
		return NineMensMorrisGameState.Result.RED_WIN \
				if mover == NineMensMorrisGameState.Side.RED \
				else NineMensMorrisGameState.Result.GREEN_WIN
	if legal_moves(state).is_empty():
		return NineMensMorrisGameState.Result.RED_WIN \
				if mover == NineMensMorrisGameState.Side.RED \
				else NineMensMorrisGameState.Result.GREEN_WIN
	if state.repetition_count() >= 3:
		return NineMensMorrisGameState.Result.DRAW
	if state.plies_since_capture >= NineMensMorrisGameState.PLIES_TO_DRAW:
		return NineMensMorrisGameState.Result.DRAW
	return NineMensMorrisGameState.Result.NONE


## Convenience: legal move notations, for logs and tests.
static func legal_notations(state: NineMensMorrisGameState) -> Array[String]:
	var result: Array[String] = []
	for move in legal_moves(state):
		result.append(notation(move))
	return result


# --- internals ----------------------------------------------------------

## Pushes the move(s) whose landing is `land` on a scratch copy of the
## board — one variant per legal capture when a mill forms, exactly one
## otherwise.
static func _collect_for_landing(board: Array, mine: int, kind: String,
		land: int, origin: int, moves: Array[NineMensMorrisMove]) -> void:
	var scratch: Array[int] = []
	scratch.assign(board)
	if kind == NineMensMorrisMove.KIND_MOVE:
		scratch[origin] = NineMensMorrisGameState.Cell.EMPTY
	scratch[land] = mine
	if not mill_formed_at(scratch, land, mine):
		moves.append(NineMensMorrisMove.place(land) \
				if kind == NineMensMorrisMove.KIND_PLACE \
				else NineMensMorrisMove.step(origin, land))
		return
	var targets := capture_targets(scratch, mine)
	if targets.is_empty():
		moves.append(NineMensMorrisMove.place(land) \
				if kind == NineMensMorrisMove.KIND_PLACE \
				else NineMensMorrisMove.step(origin, land))
		return
	for target in targets:
		moves.append(NineMensMorrisMove.place(land, target) \
				if kind == NineMensMorrisMove.KIND_PLACE \
				else NineMensMorrisMove.step(origin, land, target))


static func _ensure_tables() -> void:
	if not _adjacency.is_empty():
		return
	for edge in EDGES:
		_add_edge(int((edge as Array)[0]), int((edge as Array)[1]))
	for mill in MILLS:
		for point in mill:
			var key := int(point)
			if not _mills_through.has(key):
				_mills_through[key] = []
			(_mills_through[key] as Array).append(mill)


static func _add_edge(a: int, b: int) -> void:
	if not _adjacency.has(a):
		_adjacency[a] = []
	if not _adjacency.has(b):
		_adjacency[b] = []
	if not (_adjacency[a] as Array).has(b):
		(_adjacency[a] as Array).append(b)
	if not (_adjacency[b] as Array).has(a):
		(_adjacency[b] as Array).append(a)

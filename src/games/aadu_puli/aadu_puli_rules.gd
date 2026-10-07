class_name AaduPuliRules
extends RefCounted
## Board topology, move generation, state transitions and outcome
## evaluation for Aadu Puli Aattam. Pure rules engine — it never touches
## the UI and is fully deterministic.
##
## Implements docs/aadu_puli_aattam_rules.md exactly.

## Ordered polylines of the chart (spec §2). The board renderer draws
## these; adjacency and jump geometry derive from them.
const LINES: Array = [
	[0, 2, 8, 14, 19],
	[0, 3, 9, 15, 20],
	[0, 4, 10, 16, 21],
	[0, 5, 11, 17, 22],
	[1, 2, 3, 4, 5, 6],
	[7, 8, 9, 10, 11, 12],
	[13, 14, 15, 16, 17, 18],
	[19, 20, 21, 22],
	[1, 7, 13],
	[6, 12, 18],
]

static var _adjacency: Dictionary = {}
static var _jumps: Dictionary = {}


# --- Topology -----------------------------------------------------------

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


## True when (a, b, c) are three consecutive points of one line, in
## either direction — the legal geometry of a tiger jump.
static func is_jump_line(a: int, b: int, c: int) -> bool:
	for move in jumps_from(a):
		if move.over_point == b and move.to_point == c:
			return true
	return false


## Every geometrically possible jump starting at `point` (state-free).
static func jumps_from(point: int) -> Array[AaduPuliMove]:
	_ensure_tables()
	var result: Array[AaduPuliMove] = []
	if _jumps.has(point):
		for move in _jumps[point] as Array:
			result.append(move as AaduPuliMove)
	return result


# --- Move generation ----------------------------------------------------

## All legal moves for the side to move, in deterministic order.
## Empty when the game is over.
static func legal_moves(state: AaduPuliGameState) -> Array[AaduPuliMove]:
	var moves: Array[AaduPuliMove] = []
	if state == null or state.result != AaduPuliGameState.Result.NONE:
		return moves
	if state.side_to_move == AaduPuliGameState.Side.GOATS:
		if state.goats_in_hand > 0:
			# Placement phase: any empty point (spec §4.1).
			for point in AaduPuliGameState.POINT_COUNT:
				if state.is_empty(point):
					_keep_if_legal(state, AaduPuliMove.place(point), moves)
		else:
			# Slide phase (spec §4.2).
			for goat in state.goat_points():
				for neighbor in neighbors(goat):
					_keep_if_legal(state, AaduPuliMove.step(goat, neighbor), moves)
	else:
		# Tigers: steps and optional single jumps (spec §4.3).
		for tiger in state.tiger_points():
			for neighbor in neighbors(tiger):
				_keep_if_legal(state, AaduPuliMove.step(tiger, neighbor), moves)
			for jump in jumps_from(tiger):
				_keep_if_legal(state, jump, moves)
	return moves


## Legal moves whose origin is `point` (placements are not attached to
## an origin; ask the validator about those directly).
static func legal_moves_from(state: AaduPuliGameState, point: int) -> Array[AaduPuliMove]:
	var moves: Array[AaduPuliMove] = []
	for move in legal_moves(state):
		if move.from_point == point:
			moves.append(move)
	return moves


# --- Transitions --------------------------------------------------------

## Applies a validated move to a fresh state (the input is never
## mutated). Returns null when the move is not legal.
static func apply(state: AaduPuliGameState, move: AaduPuliMove) -> AaduPuliGameState:
	var verdict := AaduPuliValidator.validate(state, move)
	if not verdict.ok:
		return null
	var next := state.duplicate()
	match move.kind:
		AaduPuliMove.Kind.PLACE:
			next.board[move.to_point] = AaduPuliGameState.Cell.GOAT
			next.goats_in_hand -= 1
		AaduPuliMove.Kind.STEP:
			next.board[move.to_point] = next.board[move.from_point]
			next.board[move.from_point] = AaduPuliGameState.Cell.EMPTY
		AaduPuliMove.Kind.JUMP:
			next.board[move.to_point] = AaduPuliGameState.Cell.TIGER
			next.board[move.from_point] = AaduPuliGameState.Cell.EMPTY
			next.board[move.over_point] = AaduPuliGameState.Cell.EMPTY
			next.goats_captured += 1
	next.ply += 1
	next.side_to_move = AaduPuliGameState.Side.TIGERS \
			if state.side_to_move == AaduPuliGameState.Side.GOATS \
			else AaduPuliGameState.Side.GOATS
	next.result = evaluate(next)
	return next


# --- Outcomes -----------------------------------------------------------

## Outcome for `state` after it becomes the side to move (spec §5,
## checked in order: capture win → immobilisation wins → draw).
static func evaluate(state: AaduPuliGameState) -> int:
	if state.result != AaduPuliGameState.Result.NONE:
		return state.result
	if state.goats_captured >= AaduPuliGameState.CAPTURES_TO_WIN:
		return AaduPuliGameState.Result.TIGERS_WIN
	var moves := legal_moves(state)
	if state.side_to_move == AaduPuliGameState.Side.TIGERS:
		if moves.is_empty():
			return AaduPuliGameState.Result.GOATS_WIN
	elif state.goats_in_hand == 0 and moves.is_empty():
		return AaduPuliGameState.Result.TIGERS_WIN
	if state.ply >= AaduPuliGameState.PLIES_TO_DRAW:
		return AaduPuliGameState.Result.DRAW
	return AaduPuliGameState.Result.NONE


# --- internals ----------------------------------------------------------

static func _keep_if_legal(state: AaduPuliGameState, move: AaduPuliMove,
		moves: Array[AaduPuliMove]) -> void:
	if AaduPuliValidator.validate(state, move).ok:
		moves.append(move)


static func _ensure_tables() -> void:
	if not _adjacency.is_empty():
		return
	for line in LINES:
		# Adjacency: consecutive pairs.
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
	if not _jumps.has(from_point):
		_jumps[from_point] = []
	(_jumps[from_point] as Array).append(
			AaduPuliMove.jump(from_point, over_point, to_point))

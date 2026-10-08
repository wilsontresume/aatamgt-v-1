class_name SolahSeediGameState
extends RefCounted
## Complete position of a Solah Seedi (16 Soldiers) game: board, whose
## turn it is, counters and result. Pure data — no rules logic lives
## here (see SolahSeediRules / SolahSeediValidator).
##
## Serialization contract is defined in docs/solah_seedi_rules.md §8.

enum Cell { EMPTY, RED, GREEN }
enum Side { RED, GREEN }
enum Result { NONE, RED_WIN, GREEN_WIN, DRAW }

const POINT_COUNT := 37
const PIECES_PER_SIDE := 16

## Red owns the top triangle (0–5) plus lattice rows 0–1 (6–15).
const RED_START_POINTS: Array = [
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
]
## Green owns lattice rows 3–4 (21–30) plus the bottom triangle (31–36).
const GREEN_START_POINTS: Array = [
	21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36,
]

## Red wins by landing on any of these; green wins on the top triangle.
const GREEN_TRIANGLE: Array = [31, 32, 33, 34, 35, 36]
const RED_TRIANGLE: Array = [0, 1, 2, 3, 4, 5]

const PLIES_TO_DRAW := 60
const SERIAL_VERSION := 1

## The published starting position: 16 R, 5 empty, 16 G.
const INITIAL_BOARD := "RRRRRRRRRRRRRRRR.....GGGGGGGGGGGGGGGG"

const SIDE_KEYS := ["red", "green"]
const RESULT_KEYS := ["none", "red_win", "green_win", "draw"]

var board: Array[int] = []
var side_to_move: int = Side.RED
var ply: int = 0
var plies_since_capture: int = 0
var result: int = Result.NONE


func _init() -> void:
	board.resize(POINT_COUNT)
	board.fill(Cell.EMPTY)


## The published starting position (spec §3): red 0–15, green 21–36,
## middle row empty, red to move.
static func initial() -> SolahSeediGameState:
	var state := SolahSeediGameState.new()
	for point in RED_START_POINTS:
		state.board[int(point)] = Cell.RED
	for point in GREEN_START_POINTS:
		state.board[int(point)] = Cell.GREEN
	return state


# --- Read helpers -------------------------------------------------------

func in_bounds(point: int) -> bool:
	return point >= 0 and point < POINT_COUNT


func cell(point: int) -> int:
	if not in_bounds(point):
		return Cell.EMPTY
	return board[point]


func is_empty(point: int) -> bool:
	return in_bounds(point) and board[point] == Cell.EMPTY


func is_terminal() -> bool:
	return result != Result.NONE


func count_pieces(cell: int) -> int:
	var total := 0
	for i in POINT_COUNT:
		if board[i] == cell:
			total += 1
	return total


func points_of(cell: int) -> Array[int]:
	var points: Array[int] = []
	for i in POINT_COUNT:
		if board[i] == cell:
			points.append(i)
	return points


## Cell of the side to move.
func mover_cell() -> int:
	return Cell.RED if side_to_move == Side.RED else Cell.GREEN


func enemy_cell() -> int:
	return Cell.GREEN if side_to_move == Side.RED else Cell.RED


## Structural sanity per §8: piece conservation, counter ranges and
## agreement between the result and the board.
func counts_consistent() -> bool:
	var reds := count_pieces(Cell.RED)
	var greens := count_pieces(Cell.GREEN)
	if reds > PIECES_PER_SIDE or greens > PIECES_PER_SIDE:
		return false
	if ply < 0 or plies_since_capture < 0 or plies_since_capture > ply:
		return false
	if reds == 0 and result != Result.GREEN_WIN:
		return false
	if greens == 0 and result != Result.RED_WIN:
		return false
	if (result == Result.NONE or result == Result.DRAW) and (reds == 0 or greens == 0):
		return false
	if result == Result.RED_WIN and reds == 0:
		return false
	if result == Result.GREEN_WIN and greens == 0:
		return false
	if result == Result.NONE or result == Result.DRAW:
		for point in GREEN_TRIANGLE:
			if board[int(point)] == Cell.RED:
				return false
		for point in RED_TRIANGLE:
			if board[int(point)] == Cell.GREEN:
				return false
	return true


func duplicate() -> SolahSeediGameState:
	var copy := SolahSeediGameState.new()
	copy.board = board.duplicate()
	copy.side_to_move = side_to_move
	copy.ply = ply
	copy.plies_since_capture = plies_since_capture
	copy.result = result
	return copy


# --- Serialization ------------------------------------------------------

func board_string() -> String:
	var chars := ""
	for i in POINT_COUNT:
		match board[i]:
			Cell.RED:
				chars += "R"
			Cell.GREEN:
				chars += "G"
			_:
				chars += "."
	return chars


func serialize() -> Dictionary:
	return {
		"version": SERIAL_VERSION,
		"board": board_string(),
		"side_to_move": SIDE_KEYS[side_to_move],
		"ply": ply,
		"plies_since_capture": plies_since_capture,
		"result": RESULT_KEYS[result],
	}


## Returns a validated state, or null when the payload is malformed.
static func deserialize(data: Variant) -> SolahSeediGameState:
	if not (data is Dictionary):
		return null
	var d := data as Dictionary
	if int(d.get("version", -1)) != SERIAL_VERSION:
		return null
	var board_text := str(d.get("board", ""))
	if board_text.length() != POINT_COUNT:
		return null
	var state := SolahSeediGameState.new()
	for i in POINT_COUNT:
		match board_text[i]:
			"R":
				state.board[i] = Cell.RED
			"G":
				state.board[i] = Cell.GREEN
			".":
				state.board[i] = Cell.EMPTY
			_:
				return null
	var side_key := str(d.get("side_to_move", ""))
	var side_index := SIDE_KEYS.find(side_key)
	if side_index < 0:
		return null
	state.side_to_move = side_index
	var result_index := RESULT_KEYS.find(str(d.get("result", "none")))
	if result_index < 0:
		return null
	state.result = result_index
	state.ply = int(d.get("ply", -1))
	state.plies_since_capture = int(d.get("plies_since_capture", -1))
	if state.ply < 0 or not state.counts_consistent():
		return null
	return state


## Published FEN: board, side to move, ply and the quiet-ply counter.
func to_fen() -> String:
	return "%s %s %d %d" % [board_string(), SIDE_KEYS[side_to_move][0],
			ply, plies_since_capture]


static func from_fen(fen: String) -> SolahSeediGameState:
	var parts := fen.split(" ", false)
	if parts.size() != 4:
		return null
	var side_key := str(parts[1])
	if side_key != "r" and side_key != "g":
		return null
	var ply_text := str(parts[2])
	var quiet_text := str(parts[3])
	if not ply_text.is_valid_int() or not quiet_text.is_valid_int():
		return null
	var board_text := str(parts[0])
	if board_text.length() != POINT_COUNT:
		return null
	var state := SolahSeediGameState.new()
	for i in POINT_COUNT:
		match board_text[i]:
			"R":
				state.board[i] = Cell.RED
			"G":
				state.board[i] = Cell.GREEN
			".":
				state.board[i] = Cell.EMPTY
			_:
				return null
	state.side_to_move = Side.RED if side_key == "r" else Side.GREEN
	state.ply = int(ply_text)
	state.plies_since_capture = int(quiet_text)
	if state.ply < 0 or state.plies_since_capture < 0 \
			or state.plies_since_capture > state.ply:
		return null
	if not state.counts_consistent():
		return null
	return state

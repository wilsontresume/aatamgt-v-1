class_name AaduPuliGameState
extends RefCounted
## Complete position of an Aadu Puli Aattam game: board, whose turn it
## is, counters and result. Pure data — no rules logic lives here
## (see AaduPuliRules / AaduPuliValidator).
##
## Serialization contract is defined in docs/aadu_puli_aattam_rules.md §8.

enum Cell { EMPTY, TIGER, GOAT }
enum Side { GOATS, TIGERS }
enum Result { NONE, GOATS_WIN, TIGERS_WIN, DRAW }

const POINT_COUNT := 23
const GOAT_TOTAL := 15
const TIGER_TOTAL := 3
const TIGER_START_POINTS: Array = [0, 3, 4]
const CAPTURES_TO_WIN := 5
const PLIES_TO_DRAW := 60
const SERIAL_VERSION := 1

const SIDE_KEYS := ["goats", "tigers"]
const RESULT_KEYS := ["none", "goats_win", "tigers_win", "draw"]

var board: Array[int] = []
var side_to_move: int = Side.GOATS
var goats_in_hand: int = GOAT_TOTAL
var goats_captured: int = 0
var ply: int = 0
var result: int = Result.NONE


func _init() -> void:
	board.resize(POINT_COUNT)
	board.fill(Cell.EMPTY)


## The published starting position: tigers on 0, 3, 4; 15 goats in hand.
static func initial() -> AaduPuliGameState:
	var state := AaduPuliGameState.new()
	for point in TIGER_START_POINTS:
		state.board[int(point)] = Cell.TIGER
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


func goats_on_board() -> int:
	return board.count(Cell.GOAT)


func tiger_points() -> Array[int]:
	var points: Array[int] = []
	for i in POINT_COUNT:
		if board[i] == Cell.TIGER:
			points.append(i)
	return points


func goat_points() -> Array[int]:
	var points: Array[int] = []
	for i in POINT_COUNT:
		if board[i] == Cell.GOAT:
			points.append(i)
	return points


## Structural sanity: hand + board + captured must always total 15 and
## exactly 3 tigers must be on the board.
func counts_consistent() -> bool:
	return goats_in_hand >= 0 and goats_in_hand <= GOAT_TOTAL \
			and goats_captured >= 0 and goats_captured <= GOAT_TOTAL \
			and goats_in_hand + goats_on_board() + goats_captured == GOAT_TOTAL \
			and tiger_points().size() == TIGER_TOTAL


func duplicate() -> AaduPuliGameState:
	var copy := AaduPuliGameState.new()
	copy.board = board.duplicate()
	copy.side_to_move = side_to_move
	copy.goats_in_hand = goats_in_hand
	copy.goats_captured = goats_captured
	copy.ply = ply
	copy.result = result
	return copy


# --- Serialization ------------------------------------------------------

func board_string() -> String:
	var chars := ""
	for i in POINT_COUNT:
		match board[i]:
			Cell.TIGER:
				chars += "t"
			Cell.GOAT:
				chars += "g"
			_:
				chars += "."
	return chars


func serialize() -> Dictionary:
	return {
		"version": SERIAL_VERSION,
		"board": board_string(),
		"side_to_move": SIDE_KEYS[side_to_move],
		"goats_in_hand": goats_in_hand,
		"goats_captured": goats_captured,
		"ply": ply,
		"result": RESULT_KEYS[result],
	}


## Returns a validated state, or null when the payload is malformed.
static func deserialize(data: Variant) -> AaduPuliGameState:
	if not (data is Dictionary):
		return null
	var d := data as Dictionary
	if int(d.get("version", -1)) != SERIAL_VERSION:
		return null
	var board_text := str(d.get("board", ""))
	if board_text.length() != POINT_COUNT:
		return null
	var state := AaduPuliGameState.new()
	for i in POINT_COUNT:
		match board_text[i]:
			"t":
				state.board[i] = Cell.TIGER
			"g":
				state.board[i] = Cell.GOAT
			".":
				state.board[i] = Cell.EMPTY
			_:
				return null
	var side_key := str(d.get("side_to_move", ""))
	if side_key == "goats":
		state.side_to_move = Side.GOATS
	elif side_key == "tigers":
		state.side_to_move = Side.TIGERS
	else:
		return null
	var result_key := str(d.get("result", "none"))
	var result_index := RESULT_KEYS.find(result_key)
	if result_index < 0:
		return null
	state.result = result_index
	state.goats_in_hand = int(d.get("goats_in_hand", -1))
	state.goats_captured = int(d.get("goats_captured", -1))
	state.ply = int(d.get("ply", -1))
	if state.ply < 0 or not state.counts_consistent():
		return null
	return state


## Published FEN: board, side to move, goats in hand, ply. The captured
## counter is derived (it is not part of the FEN), and the result is
## positional state that FEN does not carry.
func to_fen() -> String:
	return "%s %s %d %d" % [board_string(), SIDE_KEYS[side_to_move][0],
			goats_in_hand, ply]


static func from_fen(fen: String) -> AaduPuliGameState:
	var parts := fen.split(" ", false)
	if parts.size() != 4:
		return null
	var side_key := str(parts[1])
	if side_key != "g" and side_key != "t":
		return null
	var hand_text := str(parts[2])
	var ply_text := str(parts[3])
	if not hand_text.is_valid_int() or not ply_text.is_valid_int():
		return null
	var board_text := str(parts[0])
	if board_text.length() != POINT_COUNT:
		return null
	var state := AaduPuliGameState.new()
	for i in POINT_COUNT:
		match board_text[i]:
			"t":
				state.board[i] = Cell.TIGER
			"g":
				state.board[i] = Cell.GOAT
			".":
				state.board[i] = Cell.EMPTY
			_:
				return null
	state.side_to_move = Side.GOATS if side_key == "g" else Side.TIGERS
	state.goats_in_hand = int(hand_text)
	state.ply = int(ply_text)
	if state.ply < 0:
		return null
	# Derive captures from the conservation law (not part of the FEN).
	state.goats_captured = GOAT_TOTAL - state.goats_in_hand - state.goats_on_board()
	if state.goats_captured < 0 or not state.counts_consistent():
		return null
	return state

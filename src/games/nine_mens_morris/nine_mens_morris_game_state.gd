class_name NineMensMorrisGameState
extends RefCounted
## Complete position of a Nine Men's Morris game: board, whose turn it
## is, hands, counters, repetition history and result. Pure data — no
## rules logic lives here (see NineMensMorrisRules /
## NineMensMorrisValidator).
##
## Serialization contract is defined in docs/nine_mens_morris_rules.md
## §9 and matches the server port byte for byte.

enum Cell { EMPTY, RED, GREEN }
enum Side { RED, GREEN }
enum Result { NONE, RED_WIN, GREEN_WIN, DRAW }

const POINT_COUNT := 24
const PIECES_PER_SIDE := 9
const PLIES_TO_DRAW := 50
const SERIAL_VERSION := 1

## The published starting position: a fully empty board.
const INITIAL_BOARD := "........................"

## One repetition key per completed turn plus the initial position, so
## the longest well-formed game can hold at most 1 + 18 placements and
## movement plies: every segment of 50 plies without a capture ends the
## game and at most 16 captures ever happen (18 + 16 * 50 + 50 + 1).
const MAX_HISTORY := 869
## A save whose history exceeds twice that length is corrupt; keep only
## the most recent keys (spec §9 — this cannot occur in real play).
const HISTORY_LOAD_LIMIT := MAX_HISTORY * 2

const SIDE_KEYS := ["red", "green"]
const RESULT_KEYS := ["none", "red_win", "green_win", "draw"]

var board: Array[int] = []
var side_to_move: int = Side.RED
var hands: Array[int] = [PIECES_PER_SIDE, PIECES_PER_SIDE]
var ply: int = 0
var plies_since_capture: int = 0
var result: int = Result.NONE
var history: Array[String] = []


func _init() -> void:
	board.resize(POINT_COUNT)
	board.fill(Cell.EMPTY)


## The published starting position (spec §3): empty board, 9 in each
## hand, red to move, history holding the initial position once.
static func initial() -> NineMensMorrisGameState:
	var state := NineMensMorrisGameState.new()
	state.history.append(state.repetition_key())
	return state


# --- Read helpers -------------------------------------------------------

static func side_index(side: int) -> int:
	return 0 if side == Side.RED else 1


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


func count_side(side: int) -> int:
	return count_pieces(Cell.RED if side == Side.RED else Cell.GREEN)


func points_of(cell: int) -> Array[int]:
	var points: Array[int] = []
	for i in POINT_COUNT:
		if board[i] == cell:
			points.append(i)
	return points


## Cell of the side to move.
func mover_cell() -> int:
	return Cell.RED if side_to_move == Side.RED else Cell.GREEN


func mover_hand() -> int:
	return hands[side_index(side_to_move)]


func hand_of(side: int) -> int:
	return hands[side_index(side)]


## Structural sanity per §9: piece conservation, counter ranges and
## agreement between the result and the position.
func counts_consistent() -> bool:
	var reds := count_pieces(Cell.RED)
	var greens := count_pieces(Cell.GREEN)
	if reds > PIECES_PER_SIDE or greens > PIECES_PER_SIDE:
		return false
	if hands[0] < 0 or hands[0] > PIECES_PER_SIDE:
		return false
	if hands[1] < 0 or hands[1] > PIECES_PER_SIDE:
		return false
	# Captured pieces free nothing: board + hand may never exceed the
	# nine pieces a side owns.
	if reds + hands[0] > PIECES_PER_SIDE:
		return false
	if greens + hands[1] > PIECES_PER_SIDE:
		return false
	if ply < 0 or plies_since_capture < 0 or plies_since_capture > ply:
		return false
	# A decided win always came from the loser's empty hand (§7).
	if result == Result.RED_WIN and hands[1] != 0:
		return false
	if result == Result.GREEN_WIN and hands[0] != 0:
		return false
	# An open game never leaves a side stranded below three pieces.
	if result == Result.NONE or result == Result.DRAW:
		if hand_of(Side.RED) == 0 and reds < 3:
			return false
		if hand_of(Side.GREEN) == 0 and greens < 3:
			return false
	return true


func duplicate() -> NineMensMorrisGameState:
	var copy := NineMensMorrisGameState.new()
	copy.board = board.duplicate()
	copy.side_to_move = side_to_move
	copy.hands = hands.duplicate()
	copy.ply = ply
	copy.plies_since_capture = plies_since_capture
	copy.result = result
	copy.history = history.duplicate()
	return copy


# --- Repetition (§8.1) --------------------------------------------------

## Repetition key of this position: board | to_move | hand_red |
## hand_green.
func repetition_key() -> String:
	return "%s|%s|%d|%d" % [board_string(), SIDE_KEYS[side_to_move],
			hands[0], hands[1]]


## Occurrences of `key` (or of the current key) in the history.
func repetition_count(key: String = "") -> int:
	var target := key if key != "" else repetition_key()
	var total := 0
	for entry in history:
		if entry == target:
			total += 1
	return total


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
		"to_move": SIDE_KEYS[side_to_move],
		"hand_red": hands[0],
		"hand_green": hands[1],
		"ply": ply,
		"plies_since_capture": plies_since_capture,
		"result": RESULT_KEYS[result],
		"history": history.duplicate(),
	}


## Returns a validated state, or null when the payload is malformed.
## Unknown keys are ignored (spec §9).
static func deserialize(data: Variant) -> NineMensMorrisGameState:
	if not (data is Dictionary):
		return null
	var d := data as Dictionary
	if int(d.get("version", -1)) != SERIAL_VERSION:
		return null
	var board_text := str(d.get("board", ""))
	if board_text.length() != POINT_COUNT:
		return null
	var state := NineMensMorrisGameState.new()
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
	var side_index_value := SIDE_KEYS.find(str(d.get("to_move", "")))
	if side_index_value < 0:
		return null
	state.side_to_move = side_index_value
	var result_index := RESULT_KEYS.find(str(d.get("result", "none")))
	if result_index < 0:
		return null
	state.result = result_index
	var hand_red := _whole_number(d.get("hand_red"))
	var hand_green := _whole_number(d.get("hand_green"))
	state.ply = _whole_number(d.get("ply"))
	state.plies_since_capture = _whole_number(d.get("plies_since_capture"))
	if hand_red < 0 or hand_red > PIECES_PER_SIDE:
		return null
	if hand_green < 0 or hand_green > PIECES_PER_SIDE:
		return null
	if state.ply < 0 or state.plies_since_capture < 0:
		return null
	state.hands[0] = hand_red
	state.hands[1] = hand_green
	var raw_history: Variant = d.get("history")
	if not (raw_history is Array):
		return null
	var keys := raw_history as Array
	if keys.is_empty():
		return null
	for entry in keys:
		if not (entry is String):
			return null
		state.history.append(entry)
	if state.history.size() > HISTORY_LOAD_LIMIT:
		var trimmed := state.history.slice(
				state.history.size() - HISTORY_LOAD_LIMIT)
		state.history.assign(trimmed)
	if not state.counts_consistent():
		return null
	return state


## Whole-number reader for JSON values (socket payloads deliver every
## number as a float); returns -1 for anything that is not a whole
## number — every caller rejects negatives anyway.
static func _whole_number(value: Variant) -> int:
	if value is int:
		return int(value)
	if value is float:
		var as_int := int(value)
		if float(as_int) == float(value):
			return as_int
	return -1

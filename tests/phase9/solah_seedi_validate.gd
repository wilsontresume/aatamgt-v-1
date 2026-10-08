extends SceneTree
## Phase 9 rule-engine test suite for Solah Seedi (16 Soldiers)
## (no UI involved).
## Run: godot --headless --path . -s res://tests/phase9/solah_seedi_validate.gd
## Exit code 0 = all checks passed.
##
## Covers: chart topology, opening, steps, captures, chains, outcomes
## (capture-all / breakthrough / immobilisation / draw), serialization
## contract, wire shape, purity and engine isolation. The suite mirrors
## server/test/unit/salah-seedi.spec.ts so both ports of
## docs/solah_seedi_rules.md must agree.

var _checks := 0
var _failures := 0
var _started := false


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run()
	return false


func _run() -> void:
	await _frame()
	_test_topology()
	_test_initial_state()
	_test_steps()
	_test_captures()
	_test_chains()
	_test_outcomes()
	_test_serialization()
	_test_wire_shape()
	_test_purity_and_determinism()
	_test_engine_has_no_ui()
	_finish()


# --- Fixtures -----------------------------------------------------------

## Builds a state directly from piece lists (white-box, like the
## Phase 4 suite).
func _state(red: Array, green: Array, side: int, ply: int,
		plies_since_capture: int = 0) -> SolahSeediGameState:
	var state := SolahSeediGameState.new()
	for point in red:
		state.board[int(point)] = SolahSeediGameState.Cell.RED
	for point in green:
		state.board[int(point)] = SolahSeediGameState.Cell.GREEN
	state.side_to_move = side
	state.ply = ply
	state.plies_since_capture = plies_since_capture
	return state


const RED := SolahSeediGameState.Side.RED
const GREEN := SolahSeediGameState.Side.GREEN
const CELL_RED := SolahSeediGameState.Cell.RED
const CELL_GREEN := SolahSeediGameState.Cell.GREEN
const CELL_EMPTY := SolahSeediGameState.Cell.EMPTY

const ISSUE := SolahSeediValidator.Issue


## Red 11 can jump green 16 onto 21 (line V0).
func _fixture_jump() -> SolahSeediGameState:
	return _state([11], [16, 30], RED, 1)


## Red 6 can chain 6→16→26 over greens 11 and 21 (line V0).
func _fixture_chain() -> SolahSeediGameState:
	return _state([6], [11, 21, 30], RED, 3)


## Red 28 can step or jump onto the bottom triangle (31 / 35).
func _fixture_breakthrough() -> SolahSeediGameState:
	return _state([28], [32, 30], RED, 5)


## Red 8 can jump the last green 13 onto 18 (line VC).
func _fixture_last_capture() -> SolahSeediGameState:
	return _state([8], [13], RED, 7)


## Green 16 is completely frozen: every neighbour and landing occupied.
func _fixture_immobilised() -> SolahSeediGameState:
	return _state(
			[17, 11, 21, 12, 22, 18, 20, 6, 26, 8, 28],
			[16],
			GREEN,
			9)


# --- Sections -----------------------------------------------------------

func _test_topology() -> void:
	_check(SolahSeediRules.LINES.size() == 20, "the chart has 20 polylines")
	_check(_sorted(SolahSeediRules.neighbors(8))
			== [3, 4, 5, 7, 9, 12, 13, 14], "point 8 has its 8 neighbors")
	_check(_sorted(SolahSeediRules.neighbors(31)) == [28, 32, 34],
			"green triangle corner 31 joins 28, 32, 34")
	_check(_sorted(SolahSeediRules.neighbors(0)) == [1, 3],
			"red triangle corner 0 joins 1, 3")
	_check(_sorted(SolahSeediRules.neighbors(16)) == [11, 12, 17, 21, 22],
			"the middle empty point 16 has 5 neighbors")
	_check(SolahSeediRules.are_adjacent(0, 1) and SolahSeediRules.are_adjacent(0, 3),
			"triangle edges 0-1 and 0-3 exist")
	_check(not SolahSeediRules.are_adjacent(0, 8)
			and not SolahSeediRules.are_adjacent(1, 8),
			"triangle corners do not connect across the chart")
	_check(SolahSeediRules.are_adjacent(6, 7),
			"row horizontal 6-7 exists")
	_check(not SolahSeediRules.are_adjacent(6, 8),
			"a row skips its second point")
	_check(SolahSeediRules.are_adjacent(6, 12),
			"diagonal 6-12 exists")
	_check(not SolahSeediRules.are_adjacent(16, 20),
			"a row skips its second point from 16")
	_check(SolahSeediRules.are_adjacent(31, 34),
			"green triangle base 31-34 exists")
	_check(not SolahSeediRules.are_adjacent(31, 21),
			"the triangle does not reach the lattice")
	_check(SolahSeediRules.are_adjacent(1, 4) and SolahSeediRules.are_adjacent(28, 32)
			and SolahSeediRules.are_adjacent(22, 28)
			and SolahSeediRules.are_adjacent(24, 28)
			and SolahSeediRules.are_adjacent(20, 24),
			"centre vertical and diagonals exist")

	# Every polyline segment is a real edge, and no segment repeats.
	var segments := 0
	var seen := {}
	var clean := true
	for line in SolahSeediRules.LINES:
		for i in line.size() - 1:
			var a := int(line[i])
			var b := int(line[i + 1])
			var key := "%d,%d" % [mini(a, b), maxi(a, b)]
			if seen.has(key):
				clean = false
			seen[key] = true
			segments += 1
			if not SolahSeediRules.are_adjacent(a, b):
				clean = false
	_check(clean and segments == 76, "polylines expand to 76 unique segments")
	var degree_sum := 0
	for point in SolahSeediGameState.POINT_COUNT:
		degree_sum += SolahSeediRules.neighbors(point).size()
	_check(degree_sum == 152, "the degree sum is 152 (76 edges × 2)")

	# Jump geometry: a jump is three consecutive points on one line.
	_check(SolahSeediRules.jump_middle(6, 8) == 7, "jump 6→8 lands over 7")
	_check(SolahSeediRules.jump_middle(8, 6) == 7, "jump 8→6 lands over 7")
	_check(SolahSeediRules.jump_middle(0, 8) == 3, "jump 0→8 lands over 3")
	_check(SolahSeediRules.jump_middle(8, 20) == 14, "jump 8→20 lands over 14")
	_check(SolahSeediRules.jump_middle(1, 8) == 4, "jump 1→8 lands over 4")
	_check(SolahSeediRules.jump_middle(6, 16) == 11, "jump 6→16 lands over 11")
	_check(SolahSeediRules.jump_middle(11, 21) == 16, "jump 11→21 lands over 16")
	_check(SolahSeediRules.jump_middle(28, 35) == 32, "jump 28→35 lands over 32")
	_check(SolahSeediRules.jump_middle(31, 33) == 32, "jump 31→33 lands over 32")
	_check(SolahSeediRules.jump_middle(31, 35) == SolahSeediMove.NONE_POINT,
			"31→35 is not a jump pair")
	_check(SolahSeediRules.jump_middle(0, 14) == SolahSeediMove.NONE_POINT,
			"0→14 skips a point and is not a jump pair")
	_check(SolahSeediRules.jump_middle(6, 7) == SolahSeediMove.NONE_POINT,
			"a single step is not a jump")
	_check(SolahSeediRules.jump_middle(6, 10) == SolahSeediMove.NONE_POINT,
			"6→10 is four points along, not a jump")
	_check(SolahSeediRules.jump_middle(0, 5) == SolahSeediMove.NONE_POINT,
			"0→5 is on two different lines")
	var unique := true
	for line in SolahSeediRules.LINES:
		for i in line.size() - 2:
			var a := int(line[i])
			var over := int(line[i + 1])
			var c := int(line[i + 2])
			if SolahSeediRules.jump_middle(a, c) != over \
					or SolahSeediRules.jump_middle(c, a) != over:
				unique = false
	_check(unique, "every line triple resolves through its middle, both ways")


func _test_initial_state() -> void:
	var state := SolahSeediGameState.initial()
	_check(state.board_string() == SolahSeediGameState.INITIAL_BOARD,
			"the board starts as the published string")
	_check(state.side_to_move == RED, "red moves first")
	_check(state.ply == 0 and state.plies_since_capture == 0,
			"fresh game starts at ply 0 with a zero quiet counter")
	_check(state.result == SolahSeediGameState.Result.NONE,
			"fresh game has no result")
	_check(state.count_pieces(CELL_RED) == SolahSeediGameState.PIECES_PER_SIDE
			and state.count_pieces(CELL_GREEN)
			== SolahSeediGameState.PIECES_PER_SIDE,
			"16 red and 16 green pieces start on the board")
	_check(state.points_of(CELL_RED) == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
			11, 12, 13, 14, 15], "red owns points 0-15")
	_check(state.points_of(CELL_GREEN) == [21, 22, 23, 24, 25, 26, 27, 28,
			29, 30, 31, 32, 33, 34, 35, 36], "green owns points 21-36")
	_check(state.is_empty(16) and state.is_empty(20),
			"the middle row starts empty")
	_check(state.counts_consistent(), "initial counts are consistent")
	_check(not state.is_terminal(), "initial position is not terminal")

	var moves := SolahSeediRules.legal_moves(state)
	var notations := _notations(moves)
	notations.sort()
	_check(notations.size() == 9, "the opening offers exactly 9 steps")
	_check(notations == ["11-16", "12-16", "12-17", "12-18", "13-18",
			"14-18", "14-19", "14-20", "15-20"],
			"the opening steps are the published line")
	var all_steps := true
	for move in moves:
		if move.path.size() != 2:
			all_steps = false
	_check(all_steps, "no opening move is a capture")
	_check(SolahSeediRules.legal_moves_from(state, 0).is_empty(),
			"a blocked triangle corner offers nothing")
	var all_ok := true
	for move in moves:
		if not SolahSeediValidator.validate(state, move).ok:
			all_ok = false
	_check(all_ok, "every opening move validates")


func _test_steps() -> void:
	var state := SolahSeediGameState.initial()
	var next := SolahSeediRules.apply(state, SolahSeediMove.step(11, 16))
	_check(next != null, "a legal step applies")
	_check(next.board[11] == CELL_EMPTY and next.board[16] == CELL_RED,
			"the step vacates 11 and occupies 16")
	_check(next.side_to_move == GREEN, "the step passes the turn to green")
	_check(next.ply == 1 and next.plies_since_capture == 1,
			"a quiet step advances the ply and the quiet counter")
	_check(next.result == SolahSeediGameState.Result.NONE,
			"a quiet step decides nothing")
	_check(state.counts_consistent(), "apply never corrupts the input state")

	_check(_issue(state, SolahSeediMove.step(16, 17)) == ISSUE.EMPTY_ORIGIN,
			"stepping from an empty point reports EMPTY_ORIGIN")
	_check(_issue(state, SolahSeediMove.step(11, 6)) == ISSUE.OCCUPIED,
			"stepping onto a friend reports OCCUPIED")
	_check(_issue(state, SolahSeediMove.step(11, 99)) == ISSUE.OUT_OF_RANGE,
			"an off-chart point reports OUT_OF_RANGE")
	_check(_issue(next, SolahSeediMove.step(6, 7)) == ISSUE.NOT_YOUR_PIECE,
			"moving the opponent's piece reports NOT_YOUR_PIECE")
	_check(SolahSeediValidator.validate(state,
			SolahSeediMove.step(11, 16)).ok, "the opening step validates")
	_check(_issue(state, SolahSeediMove.step(6, 10)) == ISSUE.JUMP_GEOMETRY,
			"a non-adjacent pair on no line reports JUMP_GEOMETRY")
	_check(_issue(state, SolahSeediMove.from_path([6, 7, 8]))
			== ISSUE.CHAIN_STEP,
			"walking inside a chain reports CHAIN_STEP")


func _test_captures() -> void:
	var state := _fixture_jump()
	var move := SolahSeediMove.from_path([11, 21])
	_check(SolahSeediValidator.validate(state, move).ok,
			"the jump validates")
	var after := SolahSeediRules.apply(state, move)
	_check(after != null, "the jump applies")
	_check(after.board[11] == CELL_EMPTY and after.board[16] == CELL_EMPTY
			and after.board[21] == CELL_RED,
			"the jump clears origin and victim and occupies the landing")
	_check(after.count_pieces(CELL_GREEN) == 1, "one green piece is gone")
	_check(after.plies_since_capture == 0, "a capture resets the quiet counter")
	_check(after.ply == 2 and after.side_to_move == GREEN,
			"the capture advances the ply and passes the turn")
	_check(after.result == SolahSeediGameState.Result.NONE,
			"one capture decides nothing")
	_check(after.counts_consistent(), "the captured position is consistent")

	var from_origin := SolahSeediRules.legal_moves_from(state, 11)
	var notations := _notations(from_origin)
	notations.sort()
	_check(notations == ["11-12", "11-21*", "11-6"],
			"captures are optional: steps and the jump coexist")
	var has_jump := false
	var has_step := false
	for move2 in from_origin:
		if SolahSeediRules.notation(move2).ends_with("*"):
			has_jump = true
		else:
			has_step = true
	_check(has_jump and has_step, "both captures and steps are offered")

	_check(_issue(state, SolahSeediMove.from_path([11, 16])) == ISSUE.OCCUPIED,
			"landing on a piece reports OCCUPIED")
	_check(_issue(state, SolahSeediMove.from_path([11, 21, 22]))
			== ISSUE.CHAIN_STEP, "a step between hops reports CHAIN_STEP")
	var landing_blocked := _state([11], [16, 21, 30], RED, 1)
	_check(_issue(landing_blocked, SolahSeediMove.from_path([11, 21]))
			== ISSUE.JUMP_LANDING, "a blocked landing reports JUMP_LANDING")
	_check(_issue(SolahSeediGameState.initial(),
			SolahSeediMove.from_path([11, 21])) == ISSUE.JUMP_NOT_ENEMY,
			"jumping a friendly piece reports JUMP_NOT_ENEMY")
	_check(_issue(state, SolahSeediMove.from_path([11, 20]))
			== ISSUE.JUMP_GEOMETRY,
			"an off-line pair reports JUMP_GEOMETRY")
	_check(SolahSeediValidator.error_text(ISSUE.JUMP_LANDING).contains("empty"),
			"the landing message says the point must be empty")

	# The last capture ends the game at once.
	var last := _fixture_last_capture()
	_check(last.count_pieces(CELL_GREEN) == 1, "one green piece remains")
	_check(SolahSeediRules.evaluate(last) == SolahSeediGameState.Result.NONE,
			"the deciding position is still open")
	var win := SolahSeediRules.apply(last, SolahSeediMove.from_path([8, 18]))
	_check(win != null, "the final jump applies")
	_check(win.result == SolahSeediGameState.Result.RED_WIN,
			"capturing the last piece wins for red")
	_check(win.count_pieces(CELL_GREEN) == 0, "no green pieces remain")
	_check(win.counts_consistent(), "the won position is consistent")
	_check(SolahSeediRules.legal_moves(win).is_empty(),
			"a finished game offers no moves")
	_check(_issue(win, SolahSeediMove.step(8, 7)) == ISSUE.GAME_OVER,
			"moving after the game reports GAME_OVER")
	_check(SolahSeediRules.apply(win, SolahSeediMove.step(8, 7)) == null,
			"apply refuses to continue a finished game")
	_check(SolahSeediValidator.error_text(ISSUE.GAME_OVER).contains("game is over"),
			"the game-over message says the game is over")


func _test_chains() -> void:
	var state := _fixture_chain()
	var from_origin := SolahSeediRules.legal_moves_from(state, 6)
	var notations := _notations(from_origin)
	notations.sort()
	_check(notations == ["6-12", "6-16*", "6-16-26*", "6-7"],
			"every chain prefix is offered (the chain may stop early)")
	_check(SolahSeediValidator.validate(state,
			SolahSeediMove.from_path([6, 16])).ok, "one hop validates")
	_check(SolahSeediValidator.validate(state,
			SolahSeediMove.from_path([6, 16, 26])).ok, "two hops validate")
	var after := SolahSeediRules.apply(state,
			SolahSeediMove.from_path([6, 16, 26]))
	_check(after != null, "the chain applies")
	_check(after.board[6] == CELL_EMPTY and after.board[11] == CELL_EMPTY
			and after.board[16] == CELL_EMPTY and after.board[21] == CELL_EMPTY
			and after.board[26] == CELL_RED,
			"both victims and every vacated point are cleared")
	_check(after.count_pieces(CELL_GREEN) == 1, "two greens were captured")
	_check(after.plies_since_capture == 0, "the chain resets the quiet counter")
	_check(after.ply == 4 and after.side_to_move == GREEN,
			"the chain advances one ply and passes the turn")
	_check(after.result == SolahSeediGameState.Result.NONE,
			"two captures decide nothing here")

	# Occupancy is verified hop-by-hop on a scratch board.
	var blocked := _fixture_chain()
	blocked.board[16] = CELL_GREEN
	_check(_issue(blocked, SolahSeediMove.from_path([6, 16, 26]))
			== ISSUE.JUMP_LANDING,
			"a landing filled by the opponent blocks the whole chain")
	_check(_issue(blocked, SolahSeediMove.from_path([6, 16]))
			== ISSUE.JUMP_LANDING,
			"the first hop alone is blocked too")
	_check(_issue(state, SolahSeediMove.from_path([6, 16, 6]))
			== ISSUE.JUMP_NOT_ENEMY,
			"re-entering the vacated origin jumps nobody (the middle is gone)")
	_check(_issue(state, SolahSeediMove.from_path([6, 7, 8])) == ISSUE.CHAIN_STEP,
			"stepping inside a chain is rejected")

	# A winning hop never extends.
	var breakthrough := _fixture_breakthrough()
	var options := SolahSeediRules.legal_moves_from(breakthrough, 28)
	var notations2 := _notations(options)
	_check(notations2.has("28-31"), "the breakthrough step is offered")
	_check(notations2.has("28-35*"), "the breakthrough jump is offered")
	var overlong := 0
	for move in options:
		if move.path.size() > 2 and move.path[1] == 35:
			overlong += 1
	_check(overlong == 0, "no chain extends past the winning hop")
	_check(_issue(breakthrough, SolahSeediMove.from_path([28, 35, 28]))
			== ISSUE.PATH_AFTER_WIN,
			"submitting an over-long path reports PATH_AFTER_WIN")
	_check(SolahSeediValidator.error_text(ISSUE.PATH_AFTER_WIN).contains(
			"earlier hop"), "the over-long message names the winning hop")


func _test_outcomes() -> void:
	# Breakthrough by step and by jump.
	var state := _fixture_breakthrough()
	_check(SolahSeediRules.evaluate(state) == SolahSeediGameState.Result.NONE,
			"the breakthrough position is still open")
	var by_step := SolahSeediRules.apply(state, SolahSeediMove.step(28, 31))
	_check(by_step != null, "the breakthrough step applies")
	_check(by_step.result == SolahSeediGameState.Result.RED_WIN,
			"landing on the enemy triangle wins")
	_check(by_step.counts_consistent(), "the won position is consistent")
	var by_jump := SolahSeediRules.apply(state,
			SolahSeediMove.from_path([28, 35]))
	_check(by_jump != null and by_jump.result == SolahSeediGameState.Result.RED_WIN,
			"jumping onto the enemy triangle also wins")
	# Landing on your OWN triangle is not a win.
	var green_home := _state([8], [34, 30], GREEN, 3)
	var green_step := SolahSeediRules.apply(green_home,
			SolahSeediMove.step(34, 35))
	_check(green_step != null
			and green_step.result == SolahSeediGameState.Result.NONE,
			"green may enter its own triangle without winning")

	# Immobilisation: the side to move with no move loses.
	var immobilised := _fixture_immobilised()
	_check(immobilised.counts_consistent(), "the frozen fixture is consistent")
	_check(SolahSeediRules.legal_moves(immobilised).is_empty(),
			"the frozen green piece has no move")
	_check(SolahSeediRules.evaluate(immobilised)
			== SolahSeediGameState.Result.RED_WIN,
			"a totally immobilised side loses (red wins)")

	# The 60-ply draw, and the capture that prevents it.
	var before := _state([8], [13], RED, 59, 59)
	_check(SolahSeediRules.evaluate(before) == SolahSeediGameState.Result.NONE,
			"59 quiet plies decide nothing")
	var after := SolahSeediRules.apply(before, SolahSeediMove.step(8, 7))
	_check(after != null, "the quiet step applies")
	_check(after.ply == 60 and after.plies_since_capture == 60,
			"the 60th quiet ply reaches the limit")
	_check(after.result == SolahSeediGameState.Result.DRAW,
			"60 quiet plies draw the game")
	_check(SolahSeediRules.evaluate(after) == SolahSeediGameState.Result.DRAW,
			"the drawn position re-evaluates as a draw")
	var busy := SolahSeediRules.apply(_state([8], [13], RED, 59, 59),
			SolahSeediMove.from_path([8, 18]))
	_check(busy != null and busy.result == SolahSeediGameState.Result.RED_WIN,
			"a last-piece capture wins before the draw can fire")
	var continued := SolahSeediRules.apply(_state([11], [16, 30], RED, 59, 59),
			SolahSeediMove.from_path([11, 21]))
	_check(continued != null and continued.plies_since_capture == 0,
			"a capture resets the quiet counter at the brink")
	_check(continued != null
			and continued.result == SolahSeediGameState.Result.NONE,
			"the reset keeps the game alive")

	# Wins are evaluated before the draw and never flip.
	var over := SolahSeediRules.apply(_fixture_last_capture(),
			SolahSeediMove.from_path([8, 18]))
	over.ply = 99
	over.plies_since_capture = 99
	_check(SolahSeediRules.evaluate(over)
			== SolahSeediGameState.Result.RED_WIN,
			"a decided win survives an ancient quiet counter")


func _test_serialization() -> void:
	var initial := SolahSeediGameState.initial()
	_check(initial.serialize() == {
		"version": 1,
		"board": SolahSeediGameState.INITIAL_BOARD,
		"side_to_move": "red",
		"ply": 0,
		"plies_since_capture": 0,
		"result": "none",
	}, "the payload matches the published contract")
	var restored := SolahSeediGameState.deserialize(initial.serialize())
	_check(restored != null, "the payload deserializes")
	_check(restored != null and restored.serialize() == initial.serialize(),
			"serialization round-trips exactly")
	_check(restored != null and _notations(SolahSeediRules.legal_moves(restored))
			== _notations(SolahSeediRules.legal_moves(initial)),
			"the restored position offers the same moves")

	var fixture := _fixture_immobilised()
	var round_trip := SolahSeediGameState.deserialize(fixture.serialize())
	_check(round_trip != null and round_trip.serialize() == fixture.serialize(),
			"a white-box fixture round-trips exactly")
	_check(round_trip != null and _notations(SolahSeediRules.legal_moves(
			round_trip)) == _notations(SolahSeediRules.legal_moves(fixture)),
			"the restored fixture offers the same moves")

	# Malformed payloads are refused.
	var base: Dictionary = SolahSeediGameState.initial().serialize()
	_check(SolahSeediGameState.deserialize(null) == null,
			"null payloads are refused")
	_check(_bad(base, {"board": "RRR"}), "short boards are refused")
	_check(_bad(base, {"side_to_move": "birds"}), "unknown sides are refused")
	_check(_bad(base, {"result": "drawish"}), "unknown results are refused")
	_check(_bad(base, {"version": 99}), "unknown versions are refused")
	_check(_bad(base, {"ply": -1}), "negative plies are refused")
	_check(_bad(base, {"plies_since_capture": -1}),
			"negative quiet counters are refused")
	_check(_bad(base, {"plies_since_capture": 5}),
			"a quiet counter above the ply is refused")
	_check(_bad(base, {"board": "x" + str(base["board"]).substr(1)}),
			"illegal board characters are refused")
	_check(_bad(base, {"board": "R".repeat(17) + ".".repeat(5)
			+ "G".repeat(15)}), "17 reds break piece conservation")
	_check(_bad(base, {"board": ".".repeat(37)}),
			"an empty board cannot be an open game")
	_check(_bad(base, {"board": "G" + ".".repeat(16) + "R".repeat(20)}),
			"20 reds break piece conservation")

	# An open game may never show a piece on the enemy triangle.
	var infiltrated := SolahSeediGameState.initial()
	infiltrated.board[16] = CELL_EMPTY
	infiltrated.board[2] = CELL_GREEN
	infiltrated.board[30] = CELL_RED
	_check(SolahSeediGameState.deserialize(infiltrated.serialize()) == null,
			"a green piece inside the red triangle while open is refused")
	# …but a decided game may hold pieces anywhere sensible.
	var won := _state([28], [32, 30], RED, 9)
	won.result = SolahSeediGameState.Result.RED_WIN
	_check(SolahSeediGameState.deserialize(won.serialize()) != null,
			"a decided game deserializes")
	var no_reds := _state([], [30], RED, 9)
	no_reds.result = SolahSeediGameState.Result.GREEN_WIN
	_check(SolahSeediGameState.deserialize(no_reds.serialize()) != null,
			"a capture-all win without losers deserializes")
	var no_reds_none := _state([], [30], RED, 9)
	_check(SolahSeediGameState.deserialize(no_reds_none.serialize()) == null,
			"an open game with no red pieces is refused")

	# FEN round-trip (client convenience form of the same contract).
	var fen := initial.to_fen()
	_check(fen == "%s r 0 0" % SolahSeediGameState.INITIAL_BOARD,
			"the published FEN is board-side-ply-quiet")
	var fen_state := SolahSeediGameState.from_fen(fen)
	_check(fen_state != null and fen_state.serialize() == initial.serialize(),
			"the FEN round-trips into the same position")
	_check(SolahSeediGameState.from_fen("too short") == null,
			"malformed FENs are refused")


func _test_wire_shape() -> void:
	_check(SolahSeediRules.notation(SolahSeediMove.step(6, 7)) == "6-7",
			"step notation is from-to")
	_check(SolahSeediRules.notation(SolahSeediMove.from_path([6, 16]))
			== "6-16*", "jump notation marks the capture")
	_check(SolahSeediRules.notation(SolahSeediMove.from_path([6, 16, 26]))
			== "6-16-26*", "chain notation joins every landing")
	var move := SolahSeediMove.from_path([6, 16, 26])
	var restored := SolahSeediMove.from_dict(move.to_dict())
	_check(restored != null and restored.equals(move),
			"moves round-trip through dictionaries")
	_check(SolahSeediMove.from_dict({"path": [6]}) == null,
			"a one-point path is refused")
	_check(SolahSeediMove.from_dict({"path": "6-7"}) == null,
			"a string path is refused")
	_check(SolahSeediMove.from_dict({"path": [6, 7.5]}) == null,
			"fractional points are refused")
	_check(SolahSeediMove.from_dict({"path": [0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
			10, 11, 12, 13, 14, 15, 16]}) == null,
			"paths beyond 16 points are refused")
	_check(SolahSeediMove.from_dict(null) == null, "null payloads are refused")
	_check(SolahSeediMove.from_dict({}) == null, "pathless payloads are refused")


func _test_purity_and_determinism() -> void:
	var state := _fixture_chain()
	var snapshot := JSON.stringify(state.serialize())
	var legal := SolahSeediRules.legal_moves(state)
	var applied := SolahSeediRules.apply(state, legal[0])
	_check(applied != null, "a generated legal move applies")
	_check(JSON.stringify(state.serialize()) == snapshot,
			"apply never mutates the input state")
	_check(_notations(SolahSeediRules.legal_moves(state)) == _notations(legal),
			"legal move generation is deterministic")
	var all_ok := true
	for move in legal:
		if not SolahSeediValidator.validate(state, move).ok:
			all_ok = false
	for move in SolahSeediRules.legal_moves(SolahSeediGameState.initial()):
		if not SolahSeediValidator.validate(
				SolahSeediGameState.initial(), move).ok:
			all_ok = false
	_check(all_ok, "generator and validator never disagree")
	_check(SolahSeediRules.apply(state,
			SolahSeediMove.from_path([6, 10])) == null,
			"applying an illegal move returns null")
	_check(SolahSeediGameState.initial().serialize()
			== SolahSeediGameState.initial().serialize(),
			"two fresh games serialize identically")
	var moved := SolahSeediRules.apply(SolahSeediGameState.initial(),
			SolahSeediMove.step(11, 16))
	_check(moved != null and moved.serialize()
			!= SolahSeediGameState.initial().serialize(),
			"a played position serializes differently")


func _test_engine_has_no_ui() -> void:
	var files := [
		"res://src/games/solah_seedi/solah_seedi_move.gd",
		"res://src/games/solah_seedi/solah_seedi_game_state.gd",
		"res://src/games/solah_seedi/solah_seedi_rules.gd",
		"res://src/games/solah_seedi/solah_seedi_validator.gd",
		"res://src/games/solah_seedi/solah_seedi_ai.gd",
	]
	var forbidden := [
		"extends Control", "extends Node", "App.", "user://", "FileAccess",
		"DirAccess", "HTTP", "WebSocket", "Control", "process.env",
	]
	var clean := true
	for path in files:
		var text := FileAccess.get_file_as_string(path)
		if text.is_empty():
			clean = false
			printerr("FAIL: engine file is unreadable: ", path)
			continue
		for token in forbidden:
			if text.contains(token):
				clean = false
				printerr("FAIL: engine file references '%s': %s" % [token, path])
	_check(clean, "rules engine files are independent of the UI and network")


# --- Helpers ------------------------------------------------------------

func _sorted(values: Array[int]) -> Array:
	var copy := values.duplicate()
	copy.sort()
	return copy


func _notations(moves: Array[SolahSeediMove]) -> Array:
	var out := []
	for move in moves:
		out.append(SolahSeediRules.notation(move))
	return out


func _issue(state: SolahSeediGameState, move: SolahSeediMove) -> int:
	return int(SolahSeediValidator.validate(state, move).issue)


func _bad(base: Dictionary, overrides: Dictionary) -> bool:
	var payload := base.duplicate()
	payload.merge(overrides, true)
	return SolahSeediGameState.deserialize(payload) == null


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		printerr("FAIL: ", label)


func _frame() -> void:
	await process_frame


func _finish() -> void:
	print("SOLAH_SEEDI: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)

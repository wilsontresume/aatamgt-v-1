extends SceneTree
## Phase 10 rule-engine test suite for Nine Men's Morris (no UI
## involved).
## Run: godot --headless --path . -s res://tests/phase10/morris_validate.gd
## Exit code 0 = all checks passed.
##
## Covers: topology, opening, placement, mills and captures (both
## exceptions), movement and flying, outcomes (starvation /
## immobilisation / threefold / fifty-ply), serialization contract, wire
## shape, port parity with the TypeScript engine, purity and engine
## isolation. The suite mirrors server/test/unit/nine-mens-morris.spec.ts
## so both ports of docs/nine_mens_morris_rules.md must agree.

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
	_test_placement()
	_test_mills_and_captures()
	_test_movement_and_flying()
	_test_outcomes()
	_test_serialization()
	_test_wire_shape()
	_test_port_parity()
	_test_purity_and_determinism()
	_test_engine_has_no_ui()
	_finish()


# --- Fixtures -----------------------------------------------------------

const RED := NineMensMorrisGameState.Side.RED
const GREEN := NineMensMorrisGameState.Side.GREEN
const CELL_RED := NineMensMorrisGameState.Cell.RED
const CELL_GREEN := NineMensMorrisGameState.Cell.GREEN
const CELL_EMPTY := NineMensMorrisGameState.Cell.EMPTY

const ISSUE := NineMensMorrisValidator.Issue


## Builds a state directly from piece lists (white-box, like the
## Phase 4/9 suites).
func _state(red: Array, green: Array, side: int, ply: int,
		plies_since_capture: int = 0, hands: Array = [9, 9]) -> NineMensMorrisGameState:
	var state := NineMensMorrisGameState.new()
	for point in red:
		state.board[int(point)] = CELL_RED
	for point in green:
		state.board[int(point)] = CELL_GREEN
	state.side_to_move = side
	state.ply = ply
	state.plies_since_capture = plies_since_capture
	state.hands[0] = int(hands[0])
	state.hands[1] = int(hands[1])
	return state


## Reds 0-1 await the landing on 2 that completes the outer mill.
## Greens sit at 8 and 10, both outside mills.
func _fixture_mill_forming() -> NineMensMorrisGameState:
	return _state([0, 1], [8, 10], RED, 4, 2, [7, 7])


## Reds 2-3 await the landing that completes 2-3-4; every green piece
## (1-9-17) is inside a mill, so exception 2 opens all of them.
func _fixture_all_enemy_in_mill() -> NineMensMorrisGameState:
	return _state([2, 3], [1, 9, 17], RED, 6, 0, [7, 6])


## Both sides left placement: red 0-1-2 still mills, and point 7 is the
## quiet step out.
func _fixture_movement() -> NineMensMorrisGameState:
	return _state([0, 1, 2, 4, 6], [9, 10, 11, 13], RED, 18, 3, [0, 0])


## Red is down to three pieces and may fly anywhere.
func _fixture_flying() -> NineMensMorrisGameState:
	return _state([0, 1, 2], [8, 9, 10, 11, 12, 13, 14, 15, 16], RED, 27, 4, [0, 0])


## Green has four pieces, hand empty, and every neighbour is covered by
## red or green itself: immobilisation.
func _fixture_immobilised() -> NineMensMorrisGameState:
	return _state([1, 3, 12, 15, 17, 18, 19], [8, 9, 10, 11], GREEN, 36, 5, [0, 0])


# --- Sections -----------------------------------------------------------

func _test_topology() -> void:
	_check(NineMensMorrisRules.EDGES.size() == 32, "the board has 32 edges")
	_check(NineMensMorrisRules.MILLS.size() == 16, "the board has 16 mills")
	_check(_sorted(NineMensMorrisRules.neighbors(0)) == [1, 7],
			"outer corner 0 joins 1 and 7")
	_check(_sorted(NineMensMorrisRules.neighbors(1)) == [0, 2, 9],
			"outer midpoint 1 joins 0, 2 and the radial 9")
	_check(_sorted(NineMensMorrisRules.neighbors(9)) == [1, 8, 10, 17],
			"middle midpoint 9 joins both rings and both radials")
	_check(_sorted(NineMensMorrisRules.neighbors(23)) == [15, 16, 22],
			"inner point 23 joins 16, 22 and the radial 15")
	_check(_sorted(NineMensMorrisRules.neighbors(19)) == [11, 18, 20],
			"inner midpoint 19 joins 18, 20 and the radial 11")
	_check(NineMensMorrisRules.are_adjacent(0, 1)
			and NineMensMorrisRules.are_adjacent(7, 0),
			"outer square edges exist")
	_check(not NineMensMorrisRules.are_adjacent(0, 2)
			and not NineMensMorrisRules.are_adjacent(1, 3),
			"square corners do not connect across an edge")
	_check(not NineMensMorrisRules.are_adjacent(0, 16)
			and not NineMensMorrisRules.are_adjacent(1, 8),
			"concentric squares join only along the radials")
	_check(NineMensMorrisRules.are_adjacent(9, 17)
			and NineMensMorrisRules.are_adjacent(11, 19),
			"radial arms exist")
	_check(not NineMensMorrisRules.are_adjacent(17, 19),
			"the centre (3,3) is not a point, so inner mids never touch")

	# Every edge is real, and no edge repeats.
	var seen := {}
	var clean := true
	for edge in NineMensMorrisRules.EDGES:
		var a := int((edge as Array)[0])
		var b := int((edge as Array)[1])
		var key := "%d,%d" % [mini(a, b), maxi(a, b)]
		if seen.has(key):
			clean = false
		seen[key] = true
		if not NineMensMorrisRules.are_adjacent(a, b):
			clean = false
	_check(clean and seen.size() == 32, "EDGES expand to 32 unique real edges")
	var degree_sum := 0
	for point in NineMensMorrisGameState.POINT_COUNT:
		degree_sum += NineMensMorrisRules.neighbors(point).size()
	_check(degree_sum == 64, "the degree sum is 64 (32 edges × 2)")

	# Mill table: the 16 published lines.
	var mill_keys := {}
	for mill in NineMensMorrisRules.MILLS:
		var triple := mill as Array
		mill_keys["%d,%d,%d" % [triple[0], triple[1], triple[2]]] = true
	_check(mill_keys.size() == 16, "all 16 mills are distinct")
	for sample in [[0, 1, 2], [2, 3, 4], [8, 9, 10], [16, 17, 18], [1, 9, 17],
			[3, 11, 19], [5, 13, 21], [7, 15, 23]]:
		var text := "%d,%d,%d" % [sample[0], sample[1], sample[2]]
		_check(mill_keys.has(text), "the mill %s exists" % text)
	_check(NineMensMorrisRules.mills_at(1).size() == 2,
			"point 1 sits on exactly two mills (0-1-2, 1-9-17)")
	_check(NineMensMorrisRules.mills_at(8).size() == 2,
			"point 8 sits on exactly two mills (8-9-10, 14-15-8)")
	_check(NineMensMorrisRules.mills_at(16).size() == 2,
			"inner corner 16 sits on exactly two mills (16-17-18, 22-23-16)")
	_check(NineMensMorrisRules.mills_at(13).size() == 2,
			"point 13 sits on exactly two mills (12-13-14, 5-13-21)")


func _test_initial_state() -> void:
	var state := NineMensMorrisGameState.initial()
	_check(state.board_string() == NineMensMorrisGameState.INITIAL_BOARD,
			"the board starts as the published string")
	_check(state.board_string().length() == 24, "the board string has 24 characters")
	_check(state.side_to_move == RED, "red moves first")
	_check(state.hands == [9, 9], "both hands start with nine pieces")
	_check(state.count_pieces(CELL_RED) == 0 and state.count_pieces(CELL_GREEN) == 0,
			"no piece starts on the board")
	_check(state.ply == 0 and state.plies_since_capture == 0,
			"fresh game starts at ply 0 with a zero quiet counter")
	_check(state.result == NineMensMorrisGameState.Result.NONE,
			"fresh game has no result")
	_check(state.history.size() == 1, "history holds the initial position once")
	_check(state.repetition_key() == "........................|red|9|9",
			"the initial repetition key matches the published format")
	_check(state.counts_consistent(), "initial counts are consistent")
	_check(not state.is_terminal(), "initial position is not terminal")

	var notations := NineMensMorrisRules.legal_notations(state)
	notations.sort()
	var expected := []
	for p in 24:
		expected.append("P%d" % p)
	expected.sort()
	_check(_as_array(notations) == expected, "the opening offers exactly 24 placements")
	var all_ok := true
	for move in NineMensMorrisRules.legal_moves(state):
		if not NineMensMorrisValidator.validate(state, move).ok:
			all_ok = false
	_check(all_ok, "every opening placement validates")
	_check(NineMensMorrisRules.phase_of(state, RED)
			== NineMensMorrisRules.PHASE_PLACEMENT,
			"red opens in the placement phase")


func _test_placement() -> void:
	var state := NineMensMorrisGameState.initial()
	var next := NineMensMorrisRules.apply(state, NineMensMorrisMove.place(0))
	_check(next != null, "a legal placement applies")
	_check(next.board[0] == CELL_RED, "the placement occupies point 0")
	_check(next.hands == [8, 9], "the hand loses one piece")
	_check(next.side_to_move == GREEN, "the placement passes the turn to green")
	_check(next.ply == 1 and next.plies_since_capture == 1,
			"a quiet placement advances the ply and the quiet counter")
	_check(next.history.size() == 2, "the repetition history grows by one")
	_check(next.history[1] == "R" + ".".repeat(23) + "|green|8|9",
			"the pushed key is the post-turn position")
	_check(next.result == NineMensMorrisGameState.Result.NONE,
			"a quiet placement decides nothing")
	_check(state.counts_consistent(), "apply never corrupts the input state")

	_check(_issue(next, NineMensMorrisMove.place(0)) == ISSUE.OCCUPIED,
			"placing onto a filled point reports OCCUPIED")
	_check(_issue(state, NineMensMorrisMove.place(24)) == ISSUE.OUT_OF_RANGE,
			"placing off-board reports OUT_OF_RANGE")
	_check(_issue(state, NineMensMorrisMove.place(-1)) == ISSUE.OUT_OF_RANGE,
			"negative points report OUT_OF_RANGE")
	_check(_issue(state, NineMensMorrisMove.step(0, 1)) == ISSUE.MOVE_WITH_HAND,
			"moving while pieces remain in hand reports MOVE_WITH_HAND")
	_check(_issue(state, NineMensMorrisMove.place(0, 5)) == ISSUE.CAPTURE_FORBIDDEN,
			"a capture without a mill reports CAPTURE_FORBIDDEN")
	var depleted := _state([0, 1, 2], [8, 10], RED, 5, 1, [0, 7])
	_check(_issue(depleted, NineMensMorrisMove.place(3)) == ISSUE.HAND_EMPTY,
			"placing with an empty hand reports HAND_EMPTY")
	_check(NineMensMorrisValidator.error_text(ISSUE.MOVE_WITH_HAND).contains("place"),
			"the phase message tells the player to place first")


func _test_mills_and_captures() -> void:
	var state := _fixture_mill_forming()
	_check(NineMensMorrisRules.phase_of(state, RED)
			== NineMensMorrisRules.PHASE_PLACEMENT,
			"red still places while its hand is non-empty")
	var notations := NineMensMorrisRules.legal_notations(state)
	_check(notations.has("P2*8") and notations.has("P2*10"),
			"completing the mill offers a capture variant per legal target")
	_check(not notations.has("P2"),
			"the mill landing is never offered without its capture")
	_check(_issue(state, NineMensMorrisMove.place(2)) == ISSUE.CAPTURE_REQUIRED,
			"a mill formation without capture reports CAPTURE_REQUIRED")
	_check(_issue(state, NineMensMorrisMove.place(2, 5)) == ISSUE.CAPTURE_TARGET,
			"capturing an empty or friendly point reports CAPTURE_TARGET")
	_check(_issue(state, NineMensMorrisMove.place(3, 5)) == ISSUE.CAPTURE_FORBIDDEN,
			"a capture with no new mill reports CAPTURE_FORBIDDEN")
	_check(_issue(state, NineMensMorrisMove.place(5)) == ISSUE.OK,
			"an ordinary placement without capture validates")

	var after := NineMensMorrisRules.apply(state, NineMensMorrisMove.place(2, 8))
	_check(after != null, "the mill placement with its capture applies")
	_check(after.board[2] == CELL_RED and after.board[8] == CELL_EMPTY,
			"the landing occupies 2 and the capture clears 8")
	_check(after.count_pieces(CELL_GREEN) == 1, "one green piece is gone")
	_check(after.plies_since_capture == 0, "the capture resets the quiet counter")
	_check(after.ply == 5 and after.side_to_move == GREEN,
			"the whole turn advances one ply and passes the turn")
	_check(after.result == NineMensMorrisGameState.Result.NONE,
			"one capture decides nothing")

	# Exception 1: a foe-less board ends the turn without a capture.
	var alone := _state([0, 1], [], RED, 4, 2, [7, 9])
	_check(NineMensMorrisRules.legal_notations(alone).has("P2"),
			"with no enemy pieces the mill may close without capture")
	_check(_issue(alone, NineMensMorrisMove.place(2)) == ISSUE.OK,
			"exception 1 accepts the capture-less mill")
	_check(_issue(alone, NineMensMorrisMove.place(2, 8)) == ISSUE.CAPTURE_TARGET,
			"exception 1 refuses a capture that has no target")
	var closed := NineMensMorrisRules.apply(alone, NineMensMorrisMove.place(2))
	_check(closed != null and closed.result == NineMensMorrisGameState.Result.NONE,
			"the capture-less mill turn completes normally")

	# Exception 2: every enemy piece in a mill opens all of them.
	var fortress := _fixture_all_enemy_in_mill()
	_check(_issue(fortress, NineMensMorrisMove.place(4, 1)) == ISSUE.OK,
			"an in-mill enemy may be taken when all of them are in mills")
	_check(_issue(fortress, NineMensMorrisMove.place(4, 9)) == ISSUE.OK,
			"any mill member becomes a legal target under exception 2")
	_check(_issue(fortress, NineMensMorrisMove.place(4)) == ISSUE.CAPTURE_REQUIRED,
			"the capture stays mandatory inside a fortress")
	var broke := NineMensMorrisRules.apply(fortress, NineMensMorrisMove.place(4, 1))
	_check(broke != null and broke.board[1] == CELL_EMPTY,
			"the capture breaks the enemy mill")

	# A mill re-formed by moving away and back is capture-worthy again.
	var shuffled := _state([0, 1, 2], [8, 10, 11, 13], RED, 9, 4, [0, 0])
	var stepped := NineMensMorrisRules.apply(shuffled, NineMensMorrisMove.step(1, 9))
	_check(stepped != null and stepped.result == NineMensMorrisGameState.Result.NONE,
			"leaving the mill is a quiet move")
	var green_turn := NineMensMorrisRules.apply(stepped, NineMensMorrisMove.step(8, 15))
	_check(green_turn != null, "green answers with a quiet step")
	_check(_issue(green_turn, NineMensMorrisMove.step(9, 1)) == ISSUE.CAPTURE_REQUIRED,
			"re-forming the mill demands the capture again")
	var recapture := NineMensMorrisRules.apply(green_turn,
			NineMensMorrisMove.step(9, 1, 10))
	_check(recapture != null and recapture.board[10] == CELL_EMPTY,
			"the re-formed mill captures")
	_check(recapture.plies_since_capture == 0,
			"the recapture resets the quiet counter")
	_check(recapture.result == NineMensMorrisGameState.Result.NONE,
			"green keeps three flying pieces and survives")

	_check(NineMensMorrisRules.notation(NineMensMorrisMove.place(2, 8)) == "P2*8",
			"the mill placement notates with its capture")


func _test_movement_and_flying() -> void:
	var state := _fixture_movement()
	_check(NineMensMorrisRules.phase_of(state, RED)
			== NineMensMorrisRules.PHASE_MOVEMENT,
			"an empty hand with four pieces is movement")
	_check(state.count_pieces(CELL_RED) == 5, "the movement fixture holds five reds")
	var notations := NineMensMorrisRules.legal_notations(state)
	notations.sort()
	_check(_as_array(notations) == ["0-7", "2-3", "4-3", "4-5", "6-5", "6-7"],
			"movement offers every single-edge step onto an empty point")
	_check(not _notations(NineMensMorrisRules.legal_moves(state)).has("0-16"),
			"concentric squares are never adjacent")

	_check(_issue(state, NineMensMorrisMove.step(3, 5)) == ISSUE.EMPTY_ORIGIN,
			"stepping from an empty point reports EMPTY_ORIGIN")
	_check(_issue(state, NineMensMorrisMove.step(9, 8)) == ISSUE.NOT_YOUR_PIECE,
			"moving the opponent's piece reports NOT_YOUR_PIECE")
	_check(_issue(state, NineMensMorrisMove.step(0, 1)) == ISSUE.OCCUPIED,
			"stepping onto a friend reports OCCUPIED")
	_check(_issue(state, NineMensMorrisMove.step(0, 18)) == ISSUE.NOT_ADJACENT,
			"a cross-board step reports NOT_ADJACENT while walking")
	_check(_issue(state, NineMensMorrisMove.step(0, 99)) == ISSUE.OUT_OF_RANGE,
			"an off-board destination reports OUT_OF_RANGE")
	_check(_issue(state, NineMensMorrisMove.place(3)) == ISSUE.HAND_EMPTY,
			"an empty hand refuses further placements")

	var quiet := NineMensMorrisRules.apply(state, NineMensMorrisMove.step(0, 7))
	_check(quiet != null, "a legal step applies")
	_check(quiet.board[0] == CELL_EMPTY and quiet.board[7] == CELL_RED,
			"the step vacates 0 and occupies 7")
	_check(quiet.ply == 19 and quiet.plies_since_capture == 4,
			"the step advances the ply and the quiet counter")
	_check(quiet.side_to_move == GREEN, "the step passes the turn")

	var flying := _fixture_flying()
	_check(NineMensMorrisRules.phase_of(flying, RED) == NineMensMorrisRules.PHASE_FLYING,
			"exactly three pieces means flying")
	_check(NineMensMorrisRules.phase_of(flying, GREEN)
			== NineMensMorrisRules.PHASE_MOVEMENT,
			"the opponent may still be walking with nine pieces")
	var flights := NineMensMorrisRules.legal_notations(flying)
	_check(flights.size() == 36, "every piece may reach every empty point (3 × 12)")
	_check(flights.has("0-18"), "a flying piece may cross the board")
	var landings := NineMensMorrisRules.legal_moves_landing(flying, 23)
	_check(landings.size() == 3, "three pieces can all land on point 23")
	_check(_issue(flying, NineMensMorrisMove.step(0, 18)) == ISSUE.OK,
			"flying accepts the cross-board step")
	_check(_issue(state, NineMensMorrisMove.step(4, 16)) == ISSUE.NOT_ADJACENT,
			"the same leap is refused while walking")


func _test_outcomes() -> void:
	# Starvation: an empty hand with fewer than three pieces loses.
	var starved := _state([0, 1, 4, 6], [8, 10], GREEN, 30, 7, [0, 0])
	_check(NineMensMorrisRules.evaluate(starved)
			== NineMensMorrisGameState.Result.RED_WIN,
			"green starves and red wins")
	var starving_red := _state([0, 1], [8, 10, 11, 13], RED, 30, 5, [0, 0])
	_check(NineMensMorrisRules.evaluate(starving_red)
			== NineMensMorrisGameState.Result.GREEN_WIN,
			"red starves and green wins")
	var hand_protects := _state([0, 1, 4, 6], [8, 10], GREEN, 30, 7, [0, 3])
	_check(NineMensMorrisRules.evaluate(hand_protects)
			== NineMensMorrisGameState.Result.NONE,
			"a reserved hand protects a side from starvation")

	# Immobilisation: no legal move with an empty hand and four pieces.
	var frozen := _fixture_immobilised()
	_check(frozen.side_to_move == GREEN
			and NineMensMorrisRules.evaluate(frozen)
			== NineMensMorrisGameState.Result.RED_WIN,
			"an immobilised green loses to red")
	_check(NineMensMorrisRules.legal_moves(frozen).is_empty(),
			"the immobilised side offers no moves")
	for point in [8, 9, 10, 11]:
		for neighbor in NineMensMorrisRules.neighbors(point):
			_check(frozen.board[neighbor] != CELL_EMPTY,
					"every neighbour of green %d is occupied" % point)

	# Win before draw: starvation still wins past the fifty-ply mark.
	var starving_quiet := _state([0, 1, 4, 6], [8, 10], GREEN, 60, 60, [0, 0])
	_check(NineMensMorrisRules.evaluate(starving_quiet)
			== NineMensMorrisGameState.Result.RED_WIN,
			"starvation outranks the quiet-move draw")

	# Win before threefold: immobilisation outranks an ancient repetition.
	var frozen_again := _fixture_immobilised()
	var frozen_key := frozen_again.repetition_key()
	frozen_again.history.append(frozen_key)
	frozen_again.history.append(frozen_key)
	frozen_again.history.append(frozen_key)
	_check(NineMensMorrisRules.evaluate(frozen_again)
			== NineMensMorrisGameState.Result.RED_WIN,
			"immobilisation outranks threefold repetition")

	# Fifty-ply quiet-move draw.
	var quiet := _state([0, 1, 2, 4, 6], [9, 10, 11, 13], RED, 49, 49, [0, 0])
	_check(NineMensMorrisRules.evaluate(quiet)
			== NineMensMorrisGameState.Result.NONE,
			"quiet counter 49 still plays on")
	var reached := NineMensMorrisRules.apply(quiet, NineMensMorrisMove.step(0, 7))
	_check(reached != null and reached.ply == 50,
			"the quiet counter reaches fifty at ply 50")
	_check(reached.plies_since_capture == 50 and reached.result
			== NineMensMorrisGameState.Result.DRAW,
			"fifty quiet plies end in a draw")

	# Threefold repetition via the real key history: the position one
	# quiet step ahead has already been seen twice.
	var repeat := _state([0, 1, 2, 4, 6], [9, 10, 11, 13], RED, 20, 5, [0, 0])
	var preview := NineMensMorrisRules.apply(repeat, NineMensMorrisMove.step(0, 7))
	_check(preview != null and preview.result
			== NineMensMorrisGameState.Result.NONE,
			"the threefold probe applies cleanly")
	var drawn_key := preview.repetition_key()
	repeat.history.append(drawn_key)
	repeat.history.append(drawn_key)
	_check(repeat.repetition_count(drawn_key) == 2,
			"the upcoming position already appears twice")
	_check(NineMensMorrisRules.evaluate(repeat)
			== NineMensMorrisGameState.Result.NONE,
			"two occurrences still play on")
	var repeated := NineMensMorrisRules.apply(repeat, NineMensMorrisMove.step(0, 7))
	_check(repeated != null and repeated.result
			== NineMensMorrisGameState.Result.DRAW,
			"the completing move lands the draw")
	_check(repeated.history.size() == 3, "the drawn history holds three keys")
	_check(repeated.repetition_count() == 3,
			"the final position appears three times")

	# A decided position never flips back to playing.
	var decided := _state([0, 1, 4, 6], [8, 10], GREEN, 99, 99, [0, 0])
	_check(NineMensMorrisRules.evaluate(decided)
			== NineMensMorrisGameState.Result.RED_WIN,
			"an ancient decided position stays decided")


func _test_serialization() -> void:
	var state := NineMensMorrisGameState.initial()
	var payload := state.serialize()
	_check(payload["version"] == 1, "the payload carries version 1")
	_check(payload["board"] == NineMensMorrisGameState.INITIAL_BOARD,
			"the payload board matches the published string")
	_check(payload["to_move"] == "red", "the payload names the side to move")
	_check(payload["hand_red"] == 9 and payload["hand_green"] == 9,
			"the payload carries both hands")
	_check(payload["ply"] == 0 and payload["plies_since_capture"] == 0,
			"the payload carries both counters")
	_check(payload["result"] == "none", "the payload names an open game")
	_check((payload["history"] as Array).size() == 1,
			"the payload carries the initial history")
	var restored := NineMensMorrisGameState.deserialize(payload)
	_check(restored != null and restored.serialize() == payload,
			"the opening round-trips byte for byte")
	_check(restored != null and restored.board_string() == state.board_string()
			and restored.repetition_key() == state.repetition_key(),
			"the restored opening agrees on board and key")

	# A mid-game round trip keeps the position and the legal moves.
	var mid := state
	for move_data in [{"kind": "place", "point": 0}, {"kind": "place", "point": 8},
			{"kind": "place", "point": 1}, {"kind": "place", "point": 10},
			{"kind": "place", "point": 2, "capture": 8},
			{"kind": "place", "point": 9}, 			{"kind": "place", "point": 4},
			{"kind": "place", "point": 8, "capture": 4}]:
		var parsed := NineMensMorrisMove.from_dict(move_data)
		var applied := NineMensMorrisRules.apply(mid, parsed)
		_check(applied != null, "parity move applies: %s" % str(move_data))
		if applied == null:
			return
		mid = applied
	var mid_copy := NineMensMorrisGameState.deserialize(mid.serialize())
	_check(mid_copy != null and mid_copy.serialize() == mid.serialize(),
			"a mid-game payload round-trips exactly")
	_check(mid_copy != null
			and _notations(NineMensMorrisRules.legal_moves(mid_copy))
			== _notations(NineMensMorrisRules.legal_moves(mid)),
			"the restored position agrees on legal moves")

	# Refusals: malformed shapes never construct a state.
	_check(NineMensMorrisGameState.deserialize(null) == null,
			"a null payload is refused")
	_check(NineMensMorrisGameState.deserialize("x") == null,
			"a string payload is refused")
	_check(NineMensMorrisGameState.deserialize(5) == null,
			"a number payload is refused")
	_check(_bad({"version": 2}) == null, "an unknown version is refused")
	_check(_bad({"board": ".".repeat(23)}) == null,
			"a short board is refused")
	_check(_bad({"board": "X".repeat(24)}) == null,
			"a board with a foreign cell is refused")
	_check(_bad({"hand_red": 10}) == null, "a hand over nine is refused")
	_check(_bad({"hand_red": -1}) == null, "a negative hand is refused")
	_check(_bad({"to_move": "blue"}) == null, "a foreign side is refused")
	_check(_bad({"result": "blue"}) == null, "a foreign result is refused")
	_check(_bad({"ply": -1}) == null, "a negative ply is refused")
	_check(_bad({"plies_since_capture": -1}) == null,
			"a negative quiet counter is refused")
	_check(_bad({"history": []}) == null, "an empty history is refused")
	_check(_bad({"history": ["a", 5]}) == null,
			"a history with a non-string entry is refused")
	var over_packed := state.serialize()
	over_packed["board"] = "R".repeat(9) + ".".repeat(15)
	over_packed["hand_red"] = 9
	_check(NineMensMorrisGameState.deserialize(over_packed) == null,
			"pieces on board plus in hand over nine is refused")
	var lone_win := state.serialize()
	lone_win["result"] = "red_win"
	_check(NineMensMorrisGameState.deserialize(lone_win) == null,
			"a red win with a full green hand is refused")
	lone_win["hand_green"] = 0
	_check(NineMensMorrisGameState.deserialize(lone_win) != null,
			"a red win with a starved green hand is accepted")
	var starving_open := state.serialize()
	starving_open["board"] = "GG" + ".".repeat(22)
	starving_open["hand_green"] = 0
	_check(NineMensMorrisGameState.deserialize(starving_open) == null,
			"an open game with a starved side is refused")
	var unknown := state.serialize()
	unknown["note"] = "extra fields are ignored"
	_check(NineMensMorrisGameState.deserialize(unknown) != null,
			"unknown payload keys are ignored")

	# A starved board beyond the plies limit still deserializes.
	var long_game := state.serialize()
	var big_history := []
	for i in 1800:
		big_history.append("k%d" % i)
	long_game["history"] = big_history
	var truncated := NineMensMorrisGameState.deserialize(long_game)
	_check(truncated != null and truncated.history.size()
			== NineMensMorrisGameState.HISTORY_LOAD_LIMIT,
			"an oversized history truncates to the load limit")
	_check(truncated != null and truncated.history[0] == "k62",
			"truncation keeps the newest entries")
	_check(NineMensMorrisGameState.MAX_HISTORY == 869
			and NineMensMorrisGameState.HISTORY_LOAD_LIMIT == 1738,
			"the history constants match the published contract")


func _test_wire_shape() -> void:
	_check(NineMensMorrisRules.notation(NineMensMorrisMove.place(17)) == "P17",
			"a placement notates as P17")
	_check(NineMensMorrisRules.notation(NineMensMorrisMove.place(17, 22)) == "P17*22",
			"a capturing placement notates with its target")
	_check(NineMensMorrisRules.notation(NineMensMorrisMove.step(17, 18)) == "17-18",
			"a step notates as 17-18")
	_check(NineMensMorrisRules.notation(NineMensMorrisMove.step(17, 18, 22)) == "17-18*22",
			"a capturing step notates with its target")
	_check(NineMensMorrisRules.notation(null) == "", "a null move notates as empty")
	_check(NineMensMorrisMove.place(5).land() == 5, "a placement lands on its point")
	_check(NineMensMorrisMove.step(3, 7).land() == 7, "a step lands on its target")
	_check(not NineMensMorrisMove.place(5).has_capture(),
			"a plain placement carries no capture")
	_check(NineMensMorrisMove.place(5, 2).has_capture(),
			"a capturing placement reports its capture")

	var plain_place := NineMensMorrisMove.place(17)
	_check(plain_place.to_dict() == {"kind": "place", "point": 17},
			"the placement payload omits an absent capture")
	var plain_step := NineMensMorrisMove.step(17, 18)
	_check(plain_step.to_dict() == {"kind": "move", "from": 17, "to": 18},
			"the step payload omits an absent capture")
	var took := NineMensMorrisMove.step(17, 18, 22)
	_check(took.to_dict() == {"kind": "move", "from": 17, "to": 18, "capture": 22},
			"the step payload carries its capture")
	var round_trip := NineMensMorrisMove.from_dict(took.to_dict())
	_check(round_trip != null and round_trip.equals(took),
			"a step round-trips through the wire")
	var round_place := NineMensMorrisMove.from_dict(
			NineMensMorrisMove.place(17, 22).to_dict())
	_check(round_place != null
			and round_place.equals(NineMensMorrisMove.place(17, 22)),
			"a capturing placement round-trips through the wire")

	_check(NineMensMorrisMove.from_dict(null) == null, "a null payload parses to null")
	_check(NineMensMorrisMove.from_dict("x") == null, "a string payload parses to null")
	_check(NineMensMorrisMove.from_dict(5) == null, "a number payload parses to null")
	_check(NineMensMorrisMove.from_dict({}) == null, "an empty payload parses to null")
	_check(NineMensMorrisMove.from_dict({"kind": "walk", "point": 3}) == null,
			"an unknown kind parses to null")
	_check(NineMensMorrisMove.from_dict({"kind": "place"}) == null,
			"a point-less placement parses to null")
	_check(NineMensMorrisMove.from_dict({"kind": "place", "point": 1.5}) == null,
			"a fractional point parses to null")
	_check(NineMensMorrisMove.from_dict({"kind": "place", "point": "x"}) == null,
			"a string point parses to null")
	_check(NineMensMorrisMove.from_dict({"kind": "move", "from": 0}) == null,
			"a destination-less step parses to null")
	_check(NineMensMorrisMove.from_dict({"kind": "move", "from": 0, "to": "x"}) == null,
			"a string destination parses to null")
	_check(NineMensMorrisMove.from_dict(
			{"kind": "place", "point": 0, "capture": 1.5}) == null,
			"a fractional capture parses to null")
	_check(NineMensMorrisMove.from_dict(
			{"kind": "place", "point": 0, "capture": true}) == null,
			"a boolean capture parses to null")
	var whole := NineMensMorrisMove.from_dict({"kind": "place", "point": 3.0})
	_check(whole != null and whole.point == 3,
			"a whole-number float point is accepted")
	var null_capture := NineMensMorrisMove.from_dict(
			{"kind": "place", "point": 0, "capture": null})
	_check(null_capture != null and null_capture.equals(NineMensMorrisMove.place(0)),
			"a null capture means no capture")
	var absent_capture := NineMensMorrisMove.from_dict(
			{"kind": "place", "point": 0, "capture": -1})
	_check(absent_capture != null
			and absent_capture.equals(NineMensMorrisMove.place(0)),
			"capture -1 means no capture")


func _test_port_parity() -> void:
	var line := [
		{"move": {"kind": "place", "point": 0}, "notation": "P0"},
		{"move": {"kind": "place", "point": 8}, "notation": "P8"},
		{"move": {"kind": "place", "point": 1}, "notation": "P1"},
		{"move": {"kind": "place", "point": 10}, "notation": "P10"},
		{"move": {"kind": "place", "point": 2, "capture": 8}, "notation": "P2*8"},
		{"move": {"kind": "place", "point": 9}, "notation": "P9"},
		{"move": {"kind": "place", "point": 4}, "notation": "P4"},
		{"move": {"kind": "place", "point": 8, "capture": 4}, "notation": "P8*4"},
	]
	var state := NineMensMorrisGameState.initial()
	var walked := true
	for entry in line:
		var move := NineMensMorrisMove.from_dict(entry["move"])
		if move == null or NineMensMorrisRules.notation(move) != entry["notation"]:
			walked = false
			break
		var next := NineMensMorrisRules.apply(state, move)
		if next == null:
			walked = false
			break
		state = next
	_check(walked, "the published parity line applies step for step")
	_check(state.board_string() == "RRR.....GGG.............",
			"the parity board matches the TypeScript engine")
	_check(state.ply == 8 and _as_array(state.hands) == [5, 5],
			"the parity line lands on ply 8 with two pieces in hand each")
	_check(state.plies_since_capture == 0,
			"the parity line ends right after the second capture")
	_check(state.side_to_move == RED
			and state.result == NineMensMorrisGameState.Result.NONE,
			"the parity line returns the turn to red with the game open")
	_check(state.history.size() == 9, "the parity line pushes eight keys")
	_check(state.counts_consistent(), "the parity line stays consistent")

	var game := NineMensMorrisGameState.initial()
	var steps := 0
	var finished := true
	while game.result == NineMensMorrisGameState.Result.NONE and steps < 70:
		var moves := NineMensMorrisRules.legal_moves(game)
		if moves.is_empty():
			finished = false
			break
		var next := NineMensMorrisRules.apply(game, moves[0])
		if next == null:
			finished = false
			break
		game = next
		steps += 1
	_check(finished, "the first-legal game runs without a hole")
	_check(game.result == NineMensMorrisGameState.Result.DRAW,
			"the first-legal game draws by threefold repetition")
	_check(game.ply == 48, "the first-legal game takes 48 plies")
	_check(game.history.size() == 49, "the first-legal game pushes 48 keys")
	_check(game.plies_since_capture < 50,
			"the draw came from repetition, not the quiet counter")


func _test_purity_and_determinism() -> void:
	var state := NineMensMorrisGameState.initial()
	var snapshot := state.serialize()
	var probe := NineMensMorrisRules.apply(state, NineMensMorrisMove.place(0))
	_check(probe != null, "the purity probe applies")
	_check(_same_payload(state.serialize(), snapshot),
			"apply never mutates its input state")
	_check(_same_payload(NineMensMorrisGameState.initial().serialize(), snapshot),
			"two openings are identical")
	_check(_notations(NineMensMorrisRules.legal_moves(state))
			== _notations(NineMensMorrisRules.legal_moves(state)),
			"the move generator is deterministic")
	_check(NineMensMorrisRules.apply(state, NineMensMorrisMove.place(0, 1)) == null,
			"an illegal placement applies to null")
	_check(NineMensMorrisRules.apply(state, NineMensMorrisMove.step(0, 1)) == null,
			"an impossible step applies to null")
	_check(_agrees(_fixture_mill_forming()),
			"the generator and the validator agree while placing")
	_check(_agrees(_fixture_movement()),
			"the generator and the validator agree while moving")


func _test_engine_has_no_ui() -> void:
	var files := [
		"res://src/games/nine_mens_morris/nine_mens_morris_move.gd",
		"res://src/games/nine_mens_morris/nine_mens_morris_game_state.gd",
		"res://src/games/nine_mens_morris/nine_mens_morris_validator.gd",
		"res://src/games/nine_mens_morris/nine_mens_morris_rules.gd",
		"res://src/games/nine_mens_morris/nine_mens_morris_ai.gd",
	]
	var forbidden := ["extends Node", "extends Control", "extends Node2D",
			"extends SceneTree", "res://ui/", ".tscn", "get_node("]
	var clean := true
	for path in files:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			clean = false
			continue
		var text := file.get_as_text()
		file.close()
		for token in forbidden:
			if text.contains(token):
				clean = false
	_check(clean, "the rule engine stays free of UI and scene dependencies")


# --- Helpers ------------------------------------------------------------

## The generator side of the validator contract: every legal move
## validates, and no other move does.
func _agrees(state: NineMensMorrisGameState) -> bool:
	var legal := {}
	for move in NineMensMorrisRules.legal_moves(state):
		legal[NineMensMorrisRules.notation(move)] = true
		if not NineMensMorrisValidator.validate(state, move).ok:
			print("FAIL: legal move rejected: %s"
					% NineMensMorrisRules.notation(move))
			return false
	var produced := {}
	for point in NineMensMorrisGameState.POINT_COUNT:
		for capture in range(-1, NineMensMorrisGameState.POINT_COUNT):
			var move := NineMensMorrisMove.place(point, capture)
			if NineMensMorrisValidator.validate(state, move).ok:
				produced[NineMensMorrisRules.notation(move)] = true
	for from_point in NineMensMorrisGameState.POINT_COUNT:
		for to_point in NineMensMorrisGameState.POINT_COUNT:
			for capture in range(-1, NineMensMorrisGameState.POINT_COUNT):
				var move := NineMensMorrisMove.step(from_point, to_point, capture)
				if NineMensMorrisValidator.validate(state, move).ok:
					produced[NineMensMorrisRules.notation(move)] = true
	if produced.size() != legal.size():
		print("FAIL: generator/validator drift: %d legal vs %d validatable"
				% [legal.size(), produced.size()])
		return false
	for key in legal:
		if not produced.has(key):
			print("FAIL: validatable move not generated: %s" % key)
			return false
	return true


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("FAIL: %s" % message)


func _frame() -> void:
	await process_frame


func _finish() -> void:
	if _failures == 0:
		print("NINE_MENS_MORRIS: %d checks, 0 failures" % _checks)
	else:
		print("NINE_MENS_MORRIS: %d checks, %d FAILURES" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _issue(state: NineMensMorrisGameState, move: NineMensMorrisMove) -> int:
	return int(NineMensMorrisValidator.validate(state, move)["issue"])


func _bad(patch: Dictionary) -> NineMensMorrisGameState:
	var payload := NineMensMorrisGameState.initial().serialize()
	for key in patch:
		payload[key] = patch[key]
	return NineMensMorrisGameState.deserialize(payload)


func _same_payload(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for key in a:
		if not b.has(key):
			return false
		var left: Variant = a[key]
		var right: Variant = b[key]
		if left is Array and right is Array:
			if (left as Array).size() != (right as Array).size():
				return false
			for i in (left as Array).size():
				if (left as Array)[i] != (right as Array)[i]:
					return false
		elif left != right:
			return false
	return true


func _sorted(values: Array) -> Array:
	var copy := []
	for value in values:
		copy.append(value)
	copy.sort()
	return copy


func _as_array(values: Array) -> Array:
	var copy := []
	for value in values:
		copy.append(value)
	return copy


func _notations(moves: Array) -> Array:
	var out := []
	for move in moves:
		out.append(NineMensMorrisRules.notation(move))
	return out




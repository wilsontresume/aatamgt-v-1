extends SceneTree
## Phase 4 rule-engine test suite for Aadu Puli Aattam (no UI involved).
## Run: godot --headless --path . -s res://tests/phase4/aadu_puli_validate.gd
## Exit code 0 = all checks passed.
##
## Covers: board topology, valid/invalid moves, captures, blocked tigers,
## goat placement, win conditions, draw, edge cases and serialization.

const SAVE_PATH := "user://aadu_puli_save.json"

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
	_clear_saved_game()
	_test_topology()
	_test_initial_state()
	_test_goat_placement()
	_test_tiger_movement()
	_test_captures()
	_test_blocked_tigers()
	_test_tiger_win()
	_test_goat_stalemate_branch()
	_test_draw()
	_test_game_over()
	_test_serialization()
	_test_purity_and_determinism()
	_test_engine_has_no_ui()
	_finish()


# --- Fixtures -----------------------------------------------------------

## Builds a state directly from piece lists (used for both legal
## fixtures and documented white-box forgeries).
func _state(tigers: Array, goats: Array, hand: int, captured: int,
		side: int, ply: int) -> AaduPuliGameState:
	var state := AaduPuliGameState.new()
	for point in tigers:
		state.board[int(point)] = AaduPuliGameState.Cell.TIGER
	for point in goats:
		state.board[int(point)] = AaduPuliGameState.Cell.GOAT
	state.goats_in_hand = hand
	state.goats_captured = captured
	state.side_to_move = side
	state.ply = ply
	return state


const SIDE_GOATS := AaduPuliGameState.Side.GOATS
const SIDE_TIGERS := AaduPuliGameState.Side.TIGERS

## Tigers on the apex triangle, one goat on 2, hand 14, tigers to move.
func _fixture_jump() -> AaduPuliGameState:
	return _state([0, 3, 4], [2], 14, 0, SIDE_TIGERS, 1)


## All three tigers immobilised (goats win), placement still ongoing.
func _fixture_blocked() -> AaduPuliGameState:
	return _state([19, 22, 0],
			[2, 3, 4, 5, 8, 9, 10, 11, 14, 17, 20, 21],
			3, 0, SIDE_TIGERS, 12)


## Hand empty: 15 goats on the board, empties {2,5,9,15,21}, goats to move.
func _fixture_slide() -> AaduPuliGameState:
	return _state([0, 3, 4],
			[1, 6, 7, 8, 10, 11, 12, 13, 14, 16, 17, 18, 19, 20, 22],
			0, 0, SIDE_GOATS, 20)


## 4 goats already caught, one more catch available for the tigers.
func _fixture_fifth_capture() -> AaduPuliGameState:
	return _state([0, 3, 4], [2], 10, 4, SIDE_TIGERS, 10)


# --- Sections -----------------------------------------------------------

func _test_topology() -> void:
	_check(_sorted(AaduPuliRules.neighbors(0)) == [2, 3, 4, 5],
			"apex 0 connects to 2,3,4,5")
	_check(not AaduPuliRules.are_adjacent(0, 1) and not AaduPuliRules.are_adjacent(0, 6),
			"apex does NOT connect to the row corners 1 and 6")
	_check(AaduPuliRules.are_adjacent(3, 4), "inner apex triangle edge 3-4 exists")
	_check(not AaduPuliRules.are_adjacent(1, 6), "1 and 6 are endpoints, not adjacent")
	_check(AaduPuliRules.are_adjacent(14, 19), "slant edge 14-19 exists")
	_check(not AaduPuliRules.are_adjacent(13, 19) and not AaduPuliRules.are_adjacent(18, 22),
			"base corners do not connect to row corners")
	_check(AaduPuliRules.are_adjacent(1, 7) and AaduPuliRules.are_adjacent(6, 12),
			"side columns exist")
	_check(AaduPuliRules.are_adjacent(19, 20) and AaduPuliRules.are_adjacent(21, 22),
			"base horizontal exists")
	_check(AaduPuliRules.is_jump_line(0, 2, 8), "jump geometry 0 over 2 to 8 is on one line")
	_check(AaduPuliRules.is_jump_line(8, 2, 0), "jump geometry works in reverse (8 over 2 to 0)")
	_check(not AaduPuliRules.is_jump_line(0, 2, 7), "corner turn 0-2-7 is not a jump line")
	_check(not AaduPuliRules.is_jump_line(0, 3, 4), "0-3-4 is not three consecutive line points")


func _test_initial_state() -> void:
	var state := AaduPuliGameState.initial()
	_check(state.tiger_points() == [0, 3, 4], "tigers start on 0, 3, 4")
	_check(state.goats_in_hand == 15 and state.goats_captured == 0,
			"15 goats in hand, none captured")
	_check(state.side_to_move == SIDE_GOATS, "goats move first")
	_check(state.ply == 0 and state.result == AaduPuliGameState.Result.NONE,
			"fresh game has ply 0 and no result")
	_check(state.goats_on_board() == 0 and state.is_empty(7),
			"every non-tiger point starts empty")
	_check(state.counts_consistent(), "initial counts are consistent")
	_check(not state.is_terminal(), "initial position is not terminal")
	var moves := AaduPuliRules.legal_moves(state)
	_check(moves.size() == 20, "20 opening placements are legal (got %d)" % moves.size())
	var all_places := true
	for move in moves:
		if move.kind != AaduPuliMove.Kind.PLACE:
			all_places = false
	_check(all_places, "opening moves are all placements")
	_check(AaduPuliRules.legal_moves_from(state, 0).is_empty(),
			"no origin-based moves exist while placing")


func _test_goat_placement() -> void:
	var state := AaduPuliGameState.initial()
	var verdict := AaduPuliValidator.validate(state, AaduPuliMove.place(7))
	_check(verdict.ok, "placing on empty point 7 is legal")
	var next := AaduPuliRules.apply(state, AaduPuliMove.place(7))
	_check(next != null, "placement applies")
	_check(next.board[7] == AaduPuliGameState.Cell.GOAT, "goat lands on 7")
	_check(next.goats_in_hand == 14, "hand drops to 14")
	_check(next.side_to_move == SIDE_TIGERS and next.ply == 1,
			"turn passes to the tigers (ply 1)")

	_check(AaduPuliValidator.validate(state, AaduPuliMove.place(0)).issue
			== AaduPuliValidator.Issue.OCCUPIED,
			"cannot place on an occupied point")
	_check(AaduPuliValidator.validate(next, AaduPuliMove.place(5)).issue
			== AaduPuliValidator.Issue.WRONG_SIDE,
			"tigers cannot place goats")
	_check(AaduPuliValidator.validate(state, AaduPuliMove.place(99)).issue
			== AaduPuliValidator.Issue.OUT_OF_RANGE,
			"placement outside the board is rejected")

	var slide := _fixture_slide()
	_check(AaduPuliValidator.validate(slide, AaduPuliMove.place(2)).issue
			== AaduPuliValidator.Issue.SLIDE_PHASE_REQUIRED,
			"once the hand is empty, placing is illegal")
	var slide_moves := AaduPuliRules.legal_moves(slide)
	var has_slide := false
	var has_place := false
	for move in slide_moves:
		if move.kind == AaduPuliMove.Kind.STEP:
			has_slide = true
		elif move.kind == AaduPuliMove.Kind.PLACE:
			has_place = true
	_check(has_slide and not has_place,
			"goats only slide after all 15 are placed (%d slides)" % slide_moves.size())

	var mid_placement := _state([0, 3, 4], [1], 13, 0, SIDE_GOATS, 4)
	_check(AaduPuliValidator.validate(mid_placement, AaduPuliMove.step(1, 2)).issue
			== AaduPuliValidator.Issue.PLACEMENT_PHASE_REQUIRED,
			"goats cannot slide while goats remain in hand")

	# Placing the 15th goat flips the phase.
	var almost := _state([0, 3, 4],
			[1, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18],
			1, 0, SIDE_GOATS, 28)
	_check(almost.counts_consistent(), "14 goats placed + 1 in hand is consistent")
	var placed := AaduPuliRules.apply(almost, AaduPuliMove.place(21))
	_check(placed != null and placed.goats_in_hand == 0, "15th goat enters the board")
	var after := AaduPuliRules.apply(placed,
			AaduPuliMove.step(0, 5) if placed.side_to_move == SIDE_TIGERS \
			else AaduPuliMove.place(5))
	_check(after != null, "game continues after placement ends")


func _test_tiger_movement() -> void:
	var state := _fixture_jump()
	_check(AaduPuliValidator.validate(state, AaduPuliMove.step(0, 5)).ok,
			"tiger steps along a line to an empty point")
	_check(AaduPuliValidator.validate(state, AaduPuliMove.step(3, 9)).ok,
			"apex-triangle tiger steps down the slant")
	_check(AaduPuliValidator.validate(state, AaduPuliMove.step(0, 1)).issue
			== AaduPuliValidator.Issue.NOT_ADJACENT,
			"0 -> 1 is not on any line")
	_check(AaduPuliValidator.validate(state, AaduPuliMove.step(0, 3)).issue
			== AaduPuliValidator.Issue.OCCUPIED,
			"cannot step onto another tiger")
	_check(AaduPuliValidator.validate(state, AaduPuliMove.step(1, 5)).issue
			== AaduPuliValidator.Issue.EMPTY_ORIGIN,
			"cannot move from an empty point")
	_check(AaduPuliValidator.validate(state, AaduPuliMove.step(2, 8)).issue
			== AaduPuliValidator.Issue.NOT_YOUR_PIECE,
			"tigers cannot move goats")
	_check(AaduPuliValidator.validate(state, AaduPuliMove.step(0, 99)).issue
			== AaduPuliValidator.Issue.OUT_OF_RANGE,
			"steps outside the board are rejected")
	_check(AaduPuliValidator.validate(_fixture_slide(), AaduPuliMove.step(0, 2)).issue
			== AaduPuliValidator.Issue.NOT_YOUR_PIECE,
			"goats cannot move tigers")

	var stepped := AaduPuliRules.apply(state, AaduPuliMove.step(0, 5))
	_check(stepped.board[0] == AaduPuliGameState.Cell.EMPTY
			and stepped.board[5] == AaduPuliGameState.Cell.TIGER,
			"step leaves the origin empty and occupies the target")
	_check(stepped.side_to_move == SIDE_GOATS, "step passes the turn to the goats")


func _test_captures() -> void:
	var state := _fixture_jump()
	var jump := AaduPuliMove.jump(0, 2, 8)
	_check(AaduPuliValidator.validate(state, jump).ok, "tiger jump 0 over 2 to 8 is legal")

	var after := AaduPuliRules.apply(state, jump)
	_check(after != null, "jump applies")
	_check(after.board[0] == AaduPuliGameState.Cell.EMPTY
			and after.board[2] == AaduPuliGameState.Cell.EMPTY
			and after.board[8] == AaduPuliGameState.Cell.TIGER,
			"jump vacates origin, removes the goat, occupies landing")
	_check(after.goats_captured == 1, "capture counter increments to 1")
	_check(after.goats_in_hand == 14, "captured goat does not return to hand")
	_check(after.counts_consistent(), "counts stay consistent after a capture")
	_check(after.side_to_move == SIDE_GOATS and after.ply == 2,
			"capture ends the tiger's turn")

	_check(AaduPuliValidator.validate(state, AaduPuliMove.jump(0, 3, 9)).issue
			== AaduPuliValidator.Issue.JUMP_NOT_A_GOAT,
			"a tiger cannot jump another tiger")
	var goat_stack := _state([0, 3, 4], [2, 8], 12, 0, SIDE_TIGERS, 1)
	_check(AaduPuliValidator.validate(goat_stack, AaduPuliMove.jump(0, 2, 8)).issue
			== AaduPuliValidator.Issue.JUMP_LANDING,
			"a jump cannot land on a goat (no double-goat leaps)")
	_check(AaduPuliValidator.validate(state, AaduPuliMove.jump(0, 2, 1)).issue
			== AaduPuliValidator.Issue.JUMP_GEOMETRY,
			"a jump cannot turn a corner off the line")
	_check(AaduPuliValidator.validate(_fixture_slide(), AaduPuliMove.jump(0, 2, 8)).issue
			== AaduPuliValidator.Issue.WRONG_SIDE,
			"goats never jump")

	var from_origin := AaduPuliRules.legal_moves_from(state, 0)
	var has_step := false
	var has_jump := false
	for move in from_origin:
		if move.kind == AaduPuliMove.Kind.STEP:
			has_step = true
		elif move.kind == AaduPuliMove.Kind.JUMP:
			has_jump = true
	_check(has_step and has_jump, "capture is optional: step and jump both offered")
	_check(AaduPuliValidator.validate(state, jump).ok,
			"the offered jump validates individually")

	var goat_turn := after
	for move in AaduPuliRules.legal_moves(goat_turn):
		_check(move.kind != AaduPuliMove.Kind.JUMP, "goats get no jump after a capture (chained hops impossible)")
		break


func _test_blocked_tigers() -> void:
	var state := _fixture_blocked()
	_check(state.goats_in_hand == 3, "blocked fixture is still in placement phase")
	_check(state.counts_consistent(), "blocked fixture counts are consistent")
	_check(AaduPuliRules.legal_moves(state).is_empty(),
			"every tiger is blocked: no step and no jump")
	_check(AaduPuliRules.evaluate(state) == AaduPuliGameState.Result.GOATS_WIN,
			"blocked tigers give the goats the win")
	_check(state.goats_captured < AaduPuliGameState.CAPTURES_TO_WIN,
			"blocked fixture is not also a capture win")


func _test_tiger_win() -> void:
	var state := _fixture_fifth_capture()
	_check(state.goats_captured == 4, "one catch away from the tiger win")
	_check(AaduPuliRules.evaluate(state) == AaduPuliGameState.Result.NONE,
			"five captures not reached yet")
	var win := AaduPuliRules.apply(state, AaduPuliMove.jump(0, 2, 8))
	_check(win != null and win.goats_captured == 5, "fifth goat is caught")
	_check(win.result == AaduPuliGameState.Result.TIGERS_WIN,
			"game ends the moment the 5th goat is captured")

	var late := _state([0, 3, 4], [], 15, 5, SIDE_TIGERS, 60)
	_check(AaduPuliRules.evaluate(late) == AaduPuliGameState.Result.TIGERS_WIN,
			"capture win takes precedence over the move-limit draw")


func _test_goat_stalemate_branch() -> void:
	# White-box fixture (spec §5.3): with standard piece counts this
	# position is provably unreachable — no arrangement of the 5–9 empty
	# points has all of its neighbours among only 3 tigers. The branch
	# is implemented anyway, so it is exercised directly.
	var forged := _state([5, 10, 17], [6, 11, 12, 18], 0, 0, SIDE_GOATS, 20)
	_check(AaduPuliRules.legal_moves(forged).is_empty(),
			"no goat has a legal slide in the forged stalemate")
	_check(AaduPuliRules.evaluate(forged) == AaduPuliGameState.Result.TIGERS_WIN,
			"goat-side stalemate is a tiger win (unreachable branch)")


func _test_draw() -> void:
	var before := _state([0, 3, 4], [1, 6], 13, 0, SIDE_GOATS, 59)
	var after := AaduPuliRules.apply(before, AaduPuliMove.place(2))
	_check(after != null and after.ply == 60, "60th ply is played")
	_check(after.result == AaduPuliGameState.Result.DRAW,
			"draw after 30 moves each with no winner")
	var again := AaduPuliRules.evaluate(after)
	_check(again == AaduPuliGameState.Result.DRAW, "draw is stable on re-evaluation")
	var fresh := _state([0, 3, 4], [1, 6], 13, 0, SIDE_TIGERS, 75)
	_check(AaduPuliRules.evaluate(fresh) == AaduPuliGameState.Result.DRAW,
			"ply count alone draws once wins are impossible")


func _test_game_over() -> void:
	var state := _fixture_fifth_capture()
	var over := AaduPuliRules.apply(state, AaduPuliMove.jump(0, 2, 8))
	_check(over != null and over.is_terminal(), "winning move terminates the game")
	_check(AaduPuliValidator.validate(over, AaduPuliMove.place(5)).issue
			== AaduPuliValidator.Issue.GAME_OVER,
			"no moves are accepted after the game ends")
	_check(AaduPuliRules.legal_moves(over).is_empty(),
			"terminal states generate no legal moves")
	_check(AaduPuliRules.apply(over, AaduPuliMove.place(5)) == null,
			"applying to a finished game returns null")


func _test_serialization() -> void:
	var initial := AaduPuliGameState.initial()
	_check(initial.to_fen() == "t..tt.................. g 15 0",
			"initial FEN matches the published position (%s)" % initial.to_fen())
	var from_fen := AaduPuliGameState.from_fen(initial.to_fen())
	_check(from_fen != null and from_fen.to_fen() == initial.to_fen(),
			"FEN round-trip is stable")
	_check(from_fen != null and from_fen.tiger_points() == [0, 3, 4]
			and from_fen.goats_in_hand == 15 and from_fen.goats_captured == 0,
			"FEN restores pieces and derives captured count")

	var fixture := _fixture_blocked()
	var restored := AaduPuliGameState.deserialize(fixture.serialize())
	_check(restored != null, "serialize/deserialize round-trip succeeds")
	_check(restored != null and restored.serialize() == fixture.serialize(),
			"restored state serializes identically")
	if restored != null:
		var before_moves := _notations(AaduPuliRules.legal_moves(fixture))
		var after_moves := _notations(AaduPuliRules.legal_moves(restored))
		_check(before_moves == after_moves,
				"restored state offers the identical legal moves")

	_check(AaduPuliGameState.deserialize(null) == null, "null payload is rejected")
	var bad_length := fixture.serialize()
	bad_length["board"] = "t..tt"
	_check(AaduPuliGameState.deserialize(bad_length) == null, "short board is rejected")
	var bad_side := fixture.serialize()
	bad_side["side_to_move"] = "birds"
	_check(AaduPuliGameState.deserialize(bad_side) == null, "unknown side is rejected")
	var bad_result := fixture.serialize()
	bad_result["result"] = "drawish"
	_check(AaduPuliGameState.deserialize(bad_result) == null, "unknown result is rejected")
	var bad_counts := fixture.serialize()
	bad_counts["goats_in_hand"] = 15  # breaks hand + board + captured == 15
	_check(AaduPuliGameState.deserialize(bad_counts) == null,
			"conservation violations are rejected")
	var bad_tigers := fixture.serialize()
	var tiger_text := str(bad_tigers["board"])
	bad_tigers["board"] = tiger_text.substr(0, 19) + "." + tiger_text.substr(20)
	_check(AaduPuliGameState.deserialize(bad_tigers) == null,
			"positions without exactly 3 tigers are rejected")
	var bad_version := fixture.serialize()
	bad_version["version"] = 99
	_check(AaduPuliGameState.deserialize(bad_version) == null,
			"unknown serialization version is rejected")
	_check(AaduPuliGameState.from_fen("not a fen") == null, "malformed FEN is rejected")

	_check(AaduPuliMove.place(12).notation() == "12", "placement notation is the point")
	_check(AaduPuliMove.step(0, 2).notation() == "0-2", "step notation is from-to")
	_check(AaduPuliMove.jump(0, 2, 8).notation() == "0-8*", "jump notation marks capture")
	var move := AaduPuliMove.jump(0, 2, 8)
	var restored_move := AaduPuliMove.from_dict(move.to_dict())
	_check(restored_move != null and restored_move.equals(move),
			"moves round-trip through dictionaries")


func _test_purity_and_determinism() -> void:
	var state := _fixture_jump()
	var snapshot := state.serialize()
	var legal := AaduPuliRules.legal_moves(state)
	var applied := AaduPuliRules.apply(state, legal[0])
	_check(applied != null, "a generated legal move applies")
	_check(state.serialize() == snapshot, "apply never mutates the input state")
	_check(_notations(AaduPuliRules.legal_moves(state)) == _notations(legal),
			"legal move generation is deterministic")
	_check(AaduPuliRules.apply(state, AaduPuliMove.step(0, 1)) == null,
			"applying an illegal move returns null")

	# Every generated move must pass the validator (the two agree).
	var all_valid := true
	var slide := _fixture_slide()
	for move in AaduPuliRules.legal_moves(slide):
		if not AaduPuliValidator.validate(slide, move).ok:
			all_valid = false
	for move in legal:
		if not AaduPuliValidator.validate(state, move).ok:
			all_valid = false
	_check(all_valid, "generator and validator never disagree")


func _test_engine_has_no_ui() -> void:
	var files := [
		"res://src/games/aadu_puli/aadu_puli_move.gd",
		"res://src/games/aadu_puli/aadu_puli_game_state.gd",
		"res://src/games/aadu_puli/aadu_puli_rules.gd",
		"res://src/games/aadu_puli/aadu_puli_validator.gd",
	]
	var clean := true
	for path in files:
		var text := FileAccess.get_file_as_string(path)
		if text.is_empty() \
				or text.contains("extends Control") \
				or text.contains("extends Node") \
				or text.contains("App.") \
				or text.contains("Control"):
			clean = false
			printerr("FAIL: engine file leaks UI concerns: ", path)
	_check(clean, "rules engine files are independent of the UI")


# --- Helpers ------------------------------------------------------------

func _sorted(values: Array[int]) -> Array:
	var copy := values.duplicate()
	copy.sort()
	return copy


func _notations(moves: Array[AaduPuliMove]) -> Array:
	var out := []
	for move in moves:
		out.append(move.notation())
	return out


func _clear_saved_game() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		var dir := DirAccess.open("user://")
		if dir != null:
			dir.remove("aadu_puli_save.json")


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
	print("AADU_PULI: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)

extends SceneTree
## Phase 9 AI test suite for Solah Seedi (16 Soldiers) (no UI involved).
## Run: godot --headless --path . -s res://tests/phase9/solah_seedi_ai_validate.gd
## Exit code 0 = all checks passed.
##
## Covers: every AI move at every difficulty is validator-approved,
## difficulty changes quality but never legality, the search is
## time-sliced (never blocks the frame), cancel/restart semantics,
## determinism, and the AI source stays free of UI/network access.

const AI_PATH := "res://src/games/solah_seedi/solah_seedi_ai.gd"
const BULK_BUDGET_USEC := 40_000

const EASY := SolahSeediAI.Difficulty.EASY
const MEDIUM := SolahSeediAI.Difficulty.MEDIUM
const HARD := SolahSeediAI.Difficulty.HARD

const SIDE_RED := SolahSeediGameState.Side.RED
const SIDE_GREEN := SolahSeediGameState.Side.GREEN

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
	_test_bulk_legality()
	_test_forced_move()
	_test_tactical_capture()
	_test_search_depth()
	_test_easy_diversity()
	_test_determinism()
	_test_non_blocking()
	await _test_cancel_and_restart()
	_test_terminal_and_moveless()
	_test_ai_has_no_ui_or_network()
	_finish()


# --- Fixtures -----------------------------------------------------------

## Builds a state directly from piece lists (same white-box helper the
## Phase 9 rules suite uses).
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


## Red 11 can jump green 16 onto 21 (line V0).
func _fixture_jump() -> SolahSeediGameState:
	return _state([11], [16, 30], SIDE_RED, 1)


## Red 6 can chain 6→16→26 over greens 11 and 21 (line V0).
func _fixture_chain() -> SolahSeediGameState:
	return _state([6], [11, 21, 30], SIDE_RED, 3)


## Red 28 can break into the green triangle (step 28-31 or jump 28-35*).
func _fixture_breakthrough() -> SolahSeediGameState:
	return _state([28], [32, 30], SIDE_RED, 5)


## Red 8 can jump the last green 13 onto 18: the capture wins outright.
func _fixture_last_capture() -> SolahSeediGameState:
	return _state([8], [13], SIDE_RED, 7)


## Exactly one legal red move: neighbours 14/15/24/25 are green and the
## landings 8/10/28/30 are green too, so the only escape is 20-19.
func _fixture_forced() -> SolahSeediGameState:
	return _state([20], [8, 10, 14, 15, 24, 25, 28, 30], SIDE_RED, 8)


## Green 16 is completely frozen: every neighbour and landing occupied.
func _fixture_immobilised() -> SolahSeediGameState:
	return _state(
			[17, 11, 21, 12, 22, 18, 20, 6, 26, 8, 28],
			[16],
			SIDE_GREEN,
			9)


## Seeded random playouts: diverse, always-well-formed positions from
## either side to move.
func _random_states(count: int) -> Array[SolahSeediGameState]:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261008
	var pool: Array[SolahSeediGameState] = []
	var guard := 0
	while pool.size() < count and guard < 5000:
		guard += 1
		var state := SolahSeediGameState.initial()
		var steps := rng.randi_range(1, 14)
		for i in steps:
			var moves := SolahSeediRules.legal_moves(state)
			if moves.is_empty():
				break
			var next := SolahSeediRules.apply(state,
					moves[rng.randi_range(0, moves.size() - 1)])
			if next == null:
				break
			state = next
			if state.is_terminal():
				break
		if not state.is_terminal() \
				and not SolahSeediRules.legal_moves(state).is_empty():
			pool.append(state)
	return pool


# --- Sections -----------------------------------------------------------

func _test_bulk_legality() -> void:
	var fixtures: Array[SolahSeediGameState] = [
		SolahSeediGameState.initial(),
		_fixture_jump(),
		_fixture_chain(),
		_fixture_breakthrough(),
		_fixture_last_capture(),
	]
	fixtures.append_array(_random_states(10))
	_check(fixtures.size() == 15, "state pool covers 15 positions")
	var index := 0
	for state in fixtures:
		var legal := _notations(SolahSeediRules.legal_moves(state))
		_check(not legal.is_empty(), "pool position %d has legal moves" % index)
		for level in [EASY, MEDIUM, HARD]:
			var move := SolahSeediAI.choose_move(state, level,
					index * 10 + int(level), BULK_BUDGET_USEC)
			var ok: bool = move != null \
					and legal.has(SolahSeediRules.notation(move)) \
					and SolahSeediValidator.validate(state, move).ok \
					and SolahSeediRules.apply(state, move) != null
			_check(ok, "difficulty %d returns a legal move for position %d (%s)"
					% [int(level), index,
					SolahSeediRules.notation(move) if move != null else "null"])
		index += 1


func _test_forced_move() -> void:
	var state := _fixture_forced()
	_check(state.counts_consistent(), "forced fixture counts are consistent")
	_check(_notations(SolahSeediRules.legal_moves(state)) == ["20-19"],
			"fixture leaves exactly one legal move: 20-19")
	for level in [EASY, MEDIUM, HARD]:
		var move := SolahSeediAI.choose_move(state, level, 4, 60_000)
		_check(move != null and SolahSeediRules.notation(move) == "20-19",
				"difficulty %d plays the only legal move" % int(level))


func _test_tactical_capture() -> void:
	# The last capture wins the game outright: Medium and Hard must take
	# it — decision quality changes with difficulty, legality never does.
	var win_state := _fixture_last_capture()
	for level in [MEDIUM, HARD]:
		var move := SolahSeediAI.choose_move(win_state, level, 2, 200_000)
		var next := SolahSeediRules.apply(win_state, move) if move != null else null
		_check(move != null and move.is_capture(),
				"difficulty %d takes the game-winning capture" % int(level))
		_check(next != null
				and next.result == SolahSeediGameState.Result.RED_WIN,
				"difficulty %d capture ends in RED_WIN" % int(level))

	# A free material gain: Hard wins the exchange when one is offered.
	var state := _fixture_jump()
	var hard_move := SolahSeediAI.choose_move(state, HARD, 0, 200_000)
	_check(hard_move != null and hard_move.is_capture(),
			"hard takes the free capture in the 11-21 fixture")


func _test_search_depth() -> void:
	var easy := SolahSeediAI.new()
	easy.difficulty = EASY
	easy.start(_fixture_jump())
	_check(easy.is_finished(), "easy resolves immediately at start")
	_check(easy.get_depth() == 0, "easy never runs the search")

	for level in [MEDIUM, HARD]:
		var ai := SolahSeediAI.new()
		ai.use_thread = false  # inline so the depth reached is measurable
		ai.difficulty = level
		ai.max_compute_usec = 400_000
		ai.start(_fixture_jump())
		var guard := 0
		while not ai.is_finished() and guard < 100:
			ai.step(60_000)
			guard += 1
		_check(ai.is_finished() and ai.get_depth() >= 2,
				"difficulty %d searches at least 2 plies (got %d)"
				% [int(level), ai.get_depth()])


func _test_easy_diversity() -> void:
	var state := SolahSeediGameState.initial()
	var seen := {}
	for seed in 12:
		var move := SolahSeediAI.choose_move(state, EASY, seed, BULK_BUDGET_USEC)
		_check(move != null and SolahSeediValidator.validate(state, move).ok,
				"easy seed %d returns a legal move" % seed)
		if move != null:
			seen[SolahSeediRules.notation(move)] = true
	_check(seen.size() >= 3, "easy varies its replies (%d distinct)" % seen.size())


func _test_determinism() -> void:
	var state := _fixture_chain()
	var first := SolahSeediAI.choose_move(state, MEDIUM, 7, 5_000_000)
	var second := SolahSeediAI.choose_move(state, MEDIUM, 7, 5_000_000)
	_check(first != null and second != null
			and SolahSeediRules.notation(first) == SolahSeediRules.notation(second),
			"same state, difficulty and seed always yield the same move")

	var hard_a := SolahSeediAI.choose_move(state, HARD, 1, 5_000_000)
	var hard_b := SolahSeediAI.choose_move(state, HARD, 2, 5_000_000)
	_check(hard_a != null and hard_b != null
			and SolahSeediRules.notation(hard_a) == SolahSeediRules.notation(hard_b),
			"hard ignores the seed: the search itself is pure")

	var opening := SolahSeediGameState.initial()
	var easy_a := SolahSeediAI.choose_move(opening, EASY, 5, BULK_BUDGET_USEC)
	var easy_b := SolahSeediAI.choose_move(opening, EASY, 5, BULK_BUDGET_USEC)
	_check(easy_a != null and easy_b != null
			and SolahSeediRules.notation(easy_a) == SolahSeediRules.notation(easy_b),
			"easy is reproducible for a fixed seed")
	_check(opening.serialize() == SolahSeediGameState.initial().serialize(),
			"the search never mutates the state it was given")

	# A real (inline) search on a branching position: generous budget so
	# every depth completes, then the same inputs must pick the same move.
	for level in [MEDIUM, HARD]:
		var a := SolahSeediAI.choose_move(_fixture_jump(), level, 4, 5_000_000)
		var b := SolahSeediAI.choose_move(_fixture_jump(), level, 4, 5_000_000)
		_check(a != null and b != null
				and SolahSeediRules.notation(a) == SolahSeediRules.notation(b),
				"inline search is reproducible at difficulty %d" % int(level))


func _test_non_blocking() -> void:
	# The screen starts the search and polls it every frame; start() and
	# every poll must stay far cheaper than one frame, and the worker
	# must finish inside its compute budget the whole time.
	var ai := SolahSeediAI.new()
	ai.difficulty = HARD
	ai.max_compute_usec = 150_000
	var state := _fixture_jump()
	var snapshot := JSON.stringify(state.serialize())
	var started := Time.get_ticks_usec()
	ai.start(state)
	var start_cost := Time.get_ticks_usec() - started
	_check(start_cost < 50_000,
			"start() launches the worker and returns at once (%dµs)" % start_cost)
	var worst_poll := 0
	var finished_at := 0
	while true:
		var before := Time.get_ticks_usec()
		var done := ai.is_finished()
		worst_poll = maxi(worst_poll, Time.get_ticks_usec() - before)
		if done:
			finished_at = Time.get_ticks_usec()
			break
		if Time.get_ticks_usec() - started > 3_000_000:
			break
	_check(worst_poll < 50_000,
			"every poll stays far under one frame (worst %dµs)" % worst_poll)
	_check(ai.is_finished(), "the worker finishes inside its compute budget")
	_check(finished_at - started < 1_000_000,
			"the search respects its 150ms budget (took %dµs)"
			% (finished_at - started))
	var move := ai.get_move()
	_check(move != null and SolahSeediValidator.validate(state, move).ok,
			"the threaded search yields a validator-approved move")
	_check(JSON.stringify(state.serialize()) == snapshot,
			"the worker never mutates the input state")


func _test_cancel_and_restart() -> void:
	var ai := SolahSeediAI.new()
	ai.difficulty = HARD
	ai.max_compute_usec = 500_000
	ai.start(_fixture_chain())
	_check(not ai.is_finished(), "the worker search is still running after start")
	ai.cancel()
	_check(ai.is_finished(), "cancel marks the search finished")
	_check(ai.get_move() == null, "a cancelled search yields no move")

	# Restart on a fresh position (the screen rebuilds the AI per turn).
	ai.max_compute_usec = 150_000
	ai.start(_fixture_last_capture())
	await _wait_finished(ai, 3_000)
	var move := ai.get_move()
	_check(move != null and SolahSeediValidator.validate(
			_fixture_last_capture(), move).ok,
			"restart after cancel yields a legal move")

	var settled := ai.get_move()
	ai.step(1_000_000)
	_check(ai.get_move() == settled, "stepping a finished search changes nothing")

	# Starting twice without cancelling also cancels and joins the first
	# worker before launching the second.
	ai.start(_fixture_chain())
	ai.start(_fixture_chain())
	_check(not ai.is_finished(), "a second start resets the search")
	await _wait_finished(ai, 5_000)
	var restarted := ai.get_move()
	_check(restarted != null and SolahSeediValidator.validate(
			_fixture_chain(), restarted).ok,
			"double start still resolves with a legal move")

	# A single-move position resolves the moment it is started.
	ai.start(_fixture_forced())
	_check(ai.is_finished() and ai.get_move() != null
			and SolahSeediRules.notation(ai.get_move()) == "20-19",
			"restart on a forced position resolves immediately")


func _test_terminal_and_moveless() -> void:
	var over := SolahSeediRules.apply(_fixture_last_capture(),
			SolahSeediMove.from_path([8, 18]))
	_check(over != null and over.is_terminal(), "winning position is terminal")
	for level in [EASY, MEDIUM, HARD]:
		_check(SolahSeediAI.choose_move(over, level, 3, BULK_BUDGET_USEC) == null,
				"difficulty %d returns null on a finished game" % int(level))

	var stuck := _fixture_immobilised()
	_check(SolahSeediRules.legal_moves(stuck).is_empty(),
			"moveless fixture has no legal moves")
	for level in [EASY, MEDIUM, HARD]:
		_check(SolahSeediAI.choose_move(stuck, level, 4, BULK_BUDGET_USEC) == null,
				"difficulty %d returns null when no move exists" % int(level))

	var ai := SolahSeediAI.new()
	ai.start(null)
	_check(ai.is_finished() and ai.get_move() == null,
			"a null state finishes immediately with no move")


func _test_ai_has_no_ui_or_network() -> void:
	var text := FileAccess.get_file_as_string(AI_PATH)
	_check(not text.is_empty(), "AI source is readable")
	var forbidden := [
		"extends Control", "extends Node", "App.", "Control",
		"user://", "FileAccess", "DirAccess", "HTTP", "WebSocket",
		"TCPServer", "PacketPeer", "SceneTree",
	]
	var clean := true
	for token in forbidden:
		if text.contains(token):
			clean = false
			printerr("FAIL: AI source references forbidden token: ", token)
	_check(clean, "AI source has no UI, save-file or network access")
	_check(not text.contains("hidden"),
			"AI source never reads hidden information")


# --- Helpers ------------------------------------------------------------

func _notations(moves: Array[SolahSeediMove]) -> Array:
	var out := []
	for move in moves:
		out.append(SolahSeediRules.notation(move))
	return out


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		printerr("FAIL: ", label)


func _frame() -> void:
	await process_frame


func _wait_finished(ai: SolahSeediAI, timeout_msec: int) -> void:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while not ai.is_finished() and Time.get_ticks_msec() < deadline:
		await _frame()


func _finish() -> void:
	# Never leave a worker running: quit() while a thread searches
	# would tear down script classes under it.
	if SolahSeediAI._active != null:
		SolahSeediAI._active.cancel()
	print("SOLAH_SEEDI_AI: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)

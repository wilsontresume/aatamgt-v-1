extends SceneTree
## Phase 10 AI test suite for Nine Men's Morris (no UI involved).
## Run: godot --headless --path . -s res://tests/phase10/morris_ai_validate.gd
## Exit code 0 = all checks passed.
##
## Covers: every AI move at every difficulty is validator-approved,
## difficulty changes quality but never legality, the search is
## time-sliced (never blocks the frame), cancel/restart semantics,
## determinism, and the AI source stays free of UI/network access.

const AI_PATH := "res://src/games/nine_mens_morris/nine_mens_morris_ai.gd"
const BULK_BUDGET_USEC := 40_000

const EASY := NineMensMorrisAI.Difficulty.EASY
const MEDIUM := NineMensMorrisAI.Difficulty.MEDIUM
const HARD := NineMensMorrisAI.Difficulty.HARD

const SIDE_RED := NineMensMorrisGameState.Side.RED
const SIDE_GREEN := NineMensMorrisGameState.Side.GREEN

const CELL_RED := NineMensMorrisGameState.Cell.RED
const CELL_GREEN := NineMensMorrisGameState.Cell.GREEN
const CELL_EMPTY := NineMensMorrisGameState.Cell.EMPTY

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
## Phase 10 rules suite uses).
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


## Reds 0-1 await the landing on 2: the capture is free material.
func _fixture_mill_forming() -> NineMensMorrisGameState:
	return _state([0, 1], [8, 10], SIDE_RED, 4, 2, [7, 7])


## Both sides left placement: six legal steps, a small branching tree.
func _fixture_movement() -> NineMensMorrisGameState:
	return _state([0, 1, 2, 4, 6], [9, 10, 11, 13], SIDE_RED, 18, 3, [0, 0])


## Red is down to three pieces and may fly anywhere on the board.
func _fixture_flying() -> NineMensMorrisGameState:
	return _state([0, 1, 2], [8, 9, 10, 11, 12, 13, 14, 15, 16], SIDE_RED,
			27, 4, [0, 0])


## Exactly one legal red move: every other piece and neighbour is
## covered, so the only escape is 8-15.
func _fixture_forced() -> NineMensMorrisGameState:
	return _state([8, 9, 10, 11], [1, 3, 12, 17, 19], SIDE_RED, 18, 0, [0, 0])


## Completing the mill and capturing a green piece wins outright: green
## has three pieces, an empty hand and drops to two.
func _fixture_decisive() -> NineMensMorrisGameState:
	return _state([0, 1], [8, 10, 18], SIDE_RED, 10, 3, [7, 0])


## Reds 0-7 complete the mill on 6 and take the lone green piece. No
## green mill can form inside any search horizon, so the capture is
## strictly the best move — the deep search must take it.
func _fixture_free_capture() -> NineMensMorrisGameState:
	return _state([0, 7], [1], SIDE_RED, 4, 2, [7, 7])


## Green has four pieces, hand empty, and every neighbour is occupied.
func _fixture_immobilised() -> NineMensMorrisGameState:
	return _state([1, 3, 12, 15, 17, 18, 19], [8, 9, 10, 11], SIDE_GREEN,
			36, 5, [0, 0])


## Seeded random playouts: diverse, always-well-formed positions from
## either side to move.
func _random_states(count: int) -> Array[NineMensMorrisGameState]:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261008
	var pool: Array[NineMensMorrisGameState] = []
	var guard := 0
	while pool.size() < count and guard < 5000:
		guard += 1
		var state := NineMensMorrisGameState.initial()
		var steps := rng.randi_range(1, 14)
		for i in steps:
			var moves := NineMensMorrisRules.legal_moves(state)
			if moves.is_empty():
				break
			var next := NineMensMorrisRules.apply(state,
					moves[rng.randi_range(0, moves.size() - 1)])
			if next == null:
				break
			state = next
			if state.is_terminal():
				break
		if not state.is_terminal() \
				and not NineMensMorrisRules.legal_moves(state).is_empty():
			pool.append(state)
	return pool


# --- Sections -----------------------------------------------------------

func _test_bulk_legality() -> void:
	var fixtures: Array[NineMensMorrisGameState] = [
		NineMensMorrisGameState.initial(),
		_fixture_mill_forming(),
		_fixture_movement(),
		_fixture_flying(),
		_fixture_forced(),
	]
	fixtures.append_array(_random_states(10))
	_check(fixtures.size() == 15, "state pool covers 15 positions")
	var index := 0
	for state in fixtures:
		var legal := _notations(NineMensMorrisRules.legal_moves(state))
		_check(not legal.is_empty(), "pool position %d has legal moves" % index)
		for level in [EASY, MEDIUM, HARD]:
			var move := NineMensMorrisAI.choose_move(state, level,
					index * 10 + int(level), BULK_BUDGET_USEC)
			var ok: bool = move != null \
					and legal.has(NineMensMorrisRules.notation(move)) \
					and NineMensMorrisValidator.validate(state, move).ok \
					and NineMensMorrisRules.apply(state, move) != null
			_check(ok, "difficulty %d returns a legal move for position %d (%s)"
					% [int(level), index,
					NineMensMorrisRules.notation(move) if move != null else "null"])
		index += 1


func _test_forced_move() -> void:
	var state := _fixture_forced()
	_check(state.counts_consistent(), "forced fixture counts are consistent")
	_check(_notations(NineMensMorrisRules.legal_moves(state)) == ["8-15"],
			"fixture leaves exactly one legal move: 8-15")
	for level in [EASY, MEDIUM, HARD]:
		var move := NineMensMorrisAI.choose_move(state, level, 4, 60_000)
		_check(move != null and NineMensMorrisRules.notation(move) == "8-15",
				"difficulty %d plays the only legal move" % int(level))


func _test_tactical_capture() -> void:
	# The capturing mill placement wins the game outright: Medium and
	# Hard must take it — decision quality changes with difficulty,
	# legality never does.
	var win_state := _fixture_decisive()
	for level in [MEDIUM, HARD]:
		var move := NineMensMorrisAI.choose_move(win_state, level, 2, 400_000)
		var next := NineMensMorrisRules.apply(win_state, move) if move != null else null
		_check(move != null and move.has_capture(),
				"difficulty %d takes the game-winning capture" % int(level))
		_check(next != null
				and next.result == NineMensMorrisGameState.Result.RED_WIN,
				"difficulty %d capture ends in RED_WIN" % int(level))

	# A free material gain with no possible counterplay: the capturing
	# mill placement stays strictly best at every completed depth. Give
	# Hard its full depth-4 time (about 1.5s) so the deep search — not
	# a depth-3 horizon cut — makes the call.
	var free := _fixture_free_capture()
	for level in [MEDIUM, HARD]:
		var free_move := NineMensMorrisAI.choose_move(free, level, 0, 4_000_000)
		_check(free_move != null and free_move.has_capture(),
				"difficulty %d takes the free capture when the enemy cannot answer"
				% int(level))


func _test_search_depth() -> void:
	var easy := NineMensMorrisAI.new()
	easy.difficulty = EASY
	easy.start(_fixture_movement())
	_check(easy.is_finished(), "easy resolves immediately at start")
	_check(easy.get_depth() == 0, "easy never runs the search")

	for level in [MEDIUM, HARD]:
		var ai := NineMensMorrisAI.new()
		ai.use_thread = false  # inline so the depth reached is measurable
		ai.difficulty = level
		ai.max_compute_usec = 400_000
		ai.start(_fixture_movement())
		var guard := 0
		while not ai.is_finished() and guard < 100:
			ai.step(60_000)
			guard += 1
		_check(ai.is_finished() and ai.get_depth() >= 2,
				"difficulty %d searches at least 2 plies (got %d)"
				% [int(level), ai.get_depth()])


func _test_easy_diversity() -> void:
	var state := NineMensMorrisGameState.initial()
	var seen := {}
	for seed in 12:
		var move := NineMensMorrisAI.choose_move(state, EASY, seed, BULK_BUDGET_USEC)
		_check(move != null and NineMensMorrisValidator.validate(state, move).ok,
				"easy seed %d returns a legal move" % seed)
		if move != null:
			seen[NineMensMorrisRules.notation(move)] = true
	_check(seen.size() >= 3, "easy varies its replies (%d distinct)" % seen.size())


func _test_determinism() -> void:
	var state := _fixture_movement()
	var first := NineMensMorrisAI.choose_move(state, MEDIUM, 7, 5_000_000)
	var second := NineMensMorrisAI.choose_move(state, MEDIUM, 7, 5_000_000)
	_check(first != null and second != null
			and NineMensMorrisRules.notation(first)
			== NineMensMorrisRules.notation(second),
			"same state, difficulty and seed always yield the same move")

	var hard_a := NineMensMorrisAI.choose_move(state, HARD, 1, 5_000_000)
	var hard_b := NineMensMorrisAI.choose_move(state, HARD, 2, 5_000_000)
	_check(hard_a != null and hard_b != null
			and NineMensMorrisRules.notation(hard_a)
			== NineMensMorrisRules.notation(hard_b),
			"hard ignores the seed: the search itself is pure")

	var opening := NineMensMorrisGameState.initial()
	var easy_a := NineMensMorrisAI.choose_move(opening, EASY, 5, BULK_BUDGET_USEC)
	var easy_b := NineMensMorrisAI.choose_move(opening, EASY, 5, BULK_BUDGET_USEC)
	_check(easy_a != null and easy_b != null
			and NineMensMorrisRules.notation(easy_a)
			== NineMensMorrisRules.notation(easy_b),
			"easy is reproducible for a fixed seed")
	_check(opening.serialize() == NineMensMorrisGameState.initial().serialize(),
			"the search never mutates the state it was given")

	# A real (inline) search on a branching position: generous budget so
	# every depth completes, then the same inputs must pick the same move.
	for level in [MEDIUM, HARD]:
		var a := NineMensMorrisAI.choose_move(_fixture_movement(), level, 4, 5_000_000)
		var b := NineMensMorrisAI.choose_move(_fixture_movement(), level, 4, 5_000_000)
		_check(a != null and b != null
				and NineMensMorrisRules.notation(a) == NineMensMorrisRules.notation(b),
				"inline search is reproducible at difficulty %d" % int(level))


func _test_non_blocking() -> void:
	# The screen starts the search and polls it every frame; start() and
	# every poll must stay far cheaper than one frame, and the worker
	# must finish inside its compute budget the whole time.
	var ai := NineMensMorrisAI.new()
	ai.difficulty = HARD
	ai.max_compute_usec = 150_000
	var state := _fixture_mill_forming()
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
	_check(move != null and NineMensMorrisValidator.validate(state, move).ok,
			"the threaded search yields a validator-approved move")
	_check(JSON.stringify(state.serialize()) == snapshot,
			"the worker never mutates the input state")


func _test_cancel_and_restart() -> void:
	var ai := NineMensMorrisAI.new()
	ai.difficulty = HARD
	ai.max_compute_usec = 500_000
	ai.start(_fixture_mill_forming())
	_check(not ai.is_finished(), "the worker search is still running after start")
	ai.cancel()
	_check(ai.is_finished(), "cancel marks the search finished")
	_check(ai.get_move() == null, "a cancelled search yields no move")

	# Restart on a fresh position (the screen rebuilds the AI per turn).
	ai.max_compute_usec = 150_000
	ai.start(_fixture_decisive())
	await _wait_finished(ai, 3_000)
	var move := ai.get_move()
	_check(move != null and NineMensMorrisValidator.validate(
			_fixture_decisive(), move).ok,
			"restart after cancel yields a legal move")

	var settled := ai.get_move()
	ai.step(1_000_000)
	_check(ai.get_move() == settled, "stepping a finished search changes nothing")

	# Starting twice without cancelling also cancels and joins the first
	# worker before launching the second.
	ai.start(_fixture_mill_forming())
	ai.start(_fixture_mill_forming())
	_check(not ai.is_finished(), "a second start resets the search")
	await _wait_finished(ai, 5_000)
	var restarted := ai.get_move()
	_check(restarted != null and NineMensMorrisValidator.validate(
			_fixture_mill_forming(), restarted).ok,
			"double start still resolves with a legal move")

	# A single-move position resolves the moment it is started.
	ai.start(_fixture_forced())
	_check(ai.is_finished() and ai.get_move() != null
			and NineMensMorrisRules.notation(ai.get_move()) == "8-15",
			"restart on a forced position resolves immediately")


func _test_terminal_and_moveless() -> void:
	var over := NineMensMorrisRules.apply(_fixture_decisive(),
			NineMensMorrisMove.place(2, 8))
	_check(over != null and over.is_terminal(), "winning position is terminal")
	for level in [EASY, MEDIUM, HARD]:
		_check(NineMensMorrisAI.choose_move(over, level, 3, BULK_BUDGET_USEC) == null,
				"difficulty %d returns null on a finished game" % int(level))

	var stuck := _fixture_immobilised()
	_check(NineMensMorrisRules.legal_moves(stuck).is_empty(),
			"moveless fixture has no legal moves")
	for level in [EASY, MEDIUM, HARD]:
		_check(NineMensMorrisAI.choose_move(stuck, level, 4, BULK_BUDGET_USEC) == null,
				"difficulty %d returns null when no move exists" % int(level))

	var ai := NineMensMorrisAI.new()
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

func _notations(moves: Array[NineMensMorrisMove]) -> Array:
	var out := []
	for move in moves:
		out.append(NineMensMorrisRules.notation(move))
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


func _wait_finished(ai: NineMensMorrisAI, timeout_msec: int) -> void:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while not ai.is_finished() and Time.get_ticks_msec() < deadline:
		await _frame()


func _finish() -> void:
	# Never leave a worker running: quit() while a thread searches
	# would tear down script classes under it.
	if NineMensMorrisAI._active != null:
		NineMensMorrisAI._active.cancel()
	print("NINE_MENS_MORRIS_AI: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)




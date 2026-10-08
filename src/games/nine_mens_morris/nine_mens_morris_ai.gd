class_name NineMensMorrisAI
extends RefCounted
## Difficulty-ranked move search for Nine Men's Morris.
##
## Contract (mirrors SolahSeediAI / AaduPuliAI):
##  - Same rules engine as human players: candidate moves come from
##    NineMensMorrisRules.legal_moves(), so the search can only ever
##    consider moves the validator would accept. Screens still
##    re-validate before submitting (belt and braces).
##  - Perfect information only: the search reads the
##    NineMensMorrisGameState it was handed — the same public position
##    any human sees. No private state, no network, no randomness
##    beyond the seeded choice policy.
##  - Difficulty changes decision quality, never rule validity: Easy
##    picks a random legal move, Medium searches shallowly and may
##    settle for a near-best move, Hard searches to its budget and
##    plays the argmax. Every level returns a legal move or nothing.
##  - Never blocks the game loop: start() snapshots the position and,
##    by default, hands the search to a worker thread while the screen
##    polls is_finished(). cancel() aborts promptly — the worker checks
##    a cancel flag at every search node. Set use_thread = false to
##    drive the search on the calling thread with step(budget_usec);
##    choose_move() and the tests use that mode.

enum Difficulty { EASY, MEDIUM, HARD }

const WIN_SCORE := 1_000_000
const SCORE_BOUND := WIN_SCORE * 4
const MEDIUM_MARGIN := 30

## Overall compute ceiling per difficulty (wall clock microseconds).
const DEFAULT_MAX_COMPUTE_USEC := {
	Difficulty.EASY: 20_000,
	Difficulty.MEDIUM: 400_000,
	Difficulty.HARD: 1_500_000,
}

## Maximum search horizon per difficulty (plies ahead). Placement turns
## branch up to 24 ways, so the horizons stay conservative at equal
## budgets.
const MAX_SEARCH_DEPTH := {
	Difficulty.EASY: 1,
	Difficulty.MEDIUM: 2,
	Difficulty.HARD: 4,
}

## Strong reference to the one AI whose worker thread is (or was)
## running. It keeps that object alive for as long as its worker may
## touch it — GDScript objects must never be freed while a thread still
## runs on them — and the next threaded start() cancels and reaps it.
static var _active = null

var difficulty: int = Difficulty.MEDIUM
## Overrides the difficulty ceiling; tests shrink this to stay fast.
var max_compute_usec: int = -1
## Seed for the Easy/Medium choice policy. The policy itself is pure;
## the wall-clock budget only decides how deep the search gets.
var ai_seed: int = 0
## When true (the default) the search runs on a worker thread so the
## game loop never waits. When false the caller drives it with step().
var use_thread: bool = true

var _rng := RandomNumberGenerator.new()
var _state: NineMensMorrisGameState = null
var _root_moves: Array[NineMensMorrisMove] = []
var _root_scores: Array[int] = []
var _started_usec := 0
var _hard_deadline := 0
var _deadline := 0
var _depth := 0
var _finished := false
var _move: NineMensMorrisMove = null

var _thread: Thread = null
var _mutex := Mutex.new()
var _cancel := false


# --- Lifecycle ----------------------------------------------------------

## Snapshots `state` and prepares a search. Terminal or move-less
## positions finish immediately with a null move. Any previous search
## is cancelled and joined first.
func start(state: NineMensMorrisGameState) -> void:
	_shutdown()
	_rng.seed = ai_seed
	_state = null if state == null else state.duplicate()
	_root_moves = []
	_root_scores = []
	_depth = 0
	_move = null
	_finished = false
	_cancel = false
	if _state == null or _state.is_terminal():
		_finished = true
		return
	# legal_moves also warms the shared topology tables on this thread,
	# so the worker only ever reads them.
	_root_moves = NineMensMorrisRules.legal_moves(_state)
	if _root_moves.is_empty():
		_finished = true
		return
	if _root_moves.size() == 1 or difficulty == Difficulty.EASY:
		_move = _root_moves[_rng.randi_range(0, _root_moves.size() - 1)]
		_finished = true
		return
	_started_usec = Time.get_ticks_usec()
	_hard_deadline = _started_usec + _compute_budget()
	if use_thread:
		var running = NineMensMorrisAI._active
		if running != null and running != self:
			running._shutdown()  # cancel and reap any previous worker
		NineMensMorrisAI._active = self
		_thread = Thread.new()
		_thread.start(_run_search)


## Advances an inline (use_thread = false) search by at most
## `budget_usec` of wall time. With a worker thread this is a no-op —
## the search already runs in the background; only poll is_finished().
func step(budget_usec: int) -> void:
	if _thread != null:
		_reap()
		return
	if _finished:
		return
	_deadline = mini(Time.get_ticks_usec() + budget_usec, _hard_deadline)
	while Time.get_ticks_usec() < _deadline and _depth < _max_depth():
		var scores := _search_root(_depth + 1)
		if scores.is_empty():  # aborted by the deadline; retry next step
			break
		_root_scores = scores
		_depth += 1
	if _depth >= _max_depth() or Time.get_ticks_usec() >= _hard_deadline:
		_commit_move()
		_finished = true


## Aborts the computation and waits for the worker to leave. After
## cancel() the AI must be discarded or restarted; get_move() is null.
func cancel() -> void:
	_mutex.lock()
	_cancel = true
	_mutex.unlock()
	_join()
	_move = null
	_finished = true


func is_finished() -> bool:
	_reap()
	_mutex.lock()
	var done := _finished
	_mutex.unlock()
	return done


## The chosen move once finished; null when cancelled or when the
## position had no legal moves.
func get_move() -> NineMensMorrisMove:
	_reap()
	_mutex.lock()
	var chosen := _move
	_mutex.unlock()
	return chosen


func get_depth() -> int:
	_reap()
	_mutex.lock()
	var reached := _depth
	_mutex.unlock()
	return reached


## Convenience for tests and analysis: runs the full search on the
## calling thread without slicing. Still returns only validator-
## approved moves.
static func choose_move(state: NineMensMorrisGameState, level: int, seed: int = 0,
		budget_usec: int = -1) -> NineMensMorrisMove:
	var ai := NineMensMorrisAI.new()
	ai.use_thread = false
	ai.difficulty = level
	ai.ai_seed = seed
	ai.max_compute_usec = budget_usec
	ai.start(state)
	var guard := 0
	while not ai.is_finished() and guard < 10_000:
		ai.step(50_000_000)
		guard += 1
	return ai.get_move()


# --- Worker plumbing ----------------------------------------------------

## Body of the worker thread: iterative deepening against the total
## compute budget, then the choice policy. Every commit is mutex-guarded
## because the screen polls these fields concurrently.
func _run_search() -> void:
	_mutex.lock()
	_deadline = _hard_deadline
	_mutex.unlock()
	while not _cancel_requested() \
			and Time.get_ticks_usec() < _hard_deadline \
			and _depth < _max_depth():
		var scores := _search_root(_depth + 1)
		if scores.is_empty():  # aborted (deadline or cancel)
			break
		_mutex.lock()
		_root_scores = scores
		_depth += 1
		_mutex.unlock()
	_mutex.lock()
	if not _cancel:
		_commit_move()
	_finished = true
	_mutex.unlock()


func _cancel_requested() -> bool:
	_mutex.lock()
	var flag := _cancel
	_mutex.unlock()
	return flag


## Reaps a worker that has already reported completion (cheap; runs on
## the poll path).
func _reap() -> void:
	if _thread == null:
		return
	_mutex.lock()
	var done := _finished
	_mutex.unlock()
	if done:
		_join()


func _join() -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	if NineMensMorrisAI._active == self:
		NineMensMorrisAI._active = null


## Cancels and joins any running worker (used by start() when a second
## search takes over) so two searches can never overlap.
func _shutdown() -> void:
	_mutex.lock()
	_cancel = true
	_mutex.unlock()
	_join()
	_mutex.lock()
	_cancel = false
	_mutex.unlock()


# --- Search -------------------------------------------------------------

## Scores every root move for the given depth (plies). Returns an empty
## array when the deadline or a cancel aborted the iteration, so
## partial results are never committed.
func _search_root(depth: int) -> Array[int]:
	var scores: Array[int] = []
	for move in _root_moves:
		var child := NineMensMorrisRules.apply(_state, move)
		if child == null:
			# legal_moves only yields validator-approved moves; keep the
			# alignment safe anyway by scoring an immediate loss.
			scores.append(-SCORE_BOUND)
			continue
		var score := -_negamax(child, depth - 1, -SCORE_BOUND, SCORE_BOUND)
		if _aborted():
			return []
		scores.append(score)
	return scores


func _negamax(state: NineMensMorrisGameState, depth: int, alpha: int,
		beta: int) -> int:
	if _aborted():
		return 0
	if state.result != NineMensMorrisGameState.Result.NONE:
		return _terminal_score(state) * _perspective(state)
	if depth <= 0:
		return _evaluate(state) * _perspective(state)
	var moves := _ordered(NineMensMorrisRules.legal_moves(state))
	if moves.is_empty():
		# Engine states are pre-evaluated after every apply, so this is
		# unreachable for well-formed play; treat it as a dead end.
		return _evaluate(state) * _perspective(state)
	for move in moves:
		var child := NineMensMorrisRules.apply(state, move)
		if child == null:
			continue
		var score := -_negamax(child, depth - 1, -beta, -alpha)
		if _aborted():
			return 0
		if score >= beta:
			return beta
		if score > alpha:
			alpha = score
	return alpha


func _aborted() -> bool:
	if _cancel_requested():
		return true
	return Time.get_ticks_usec() >= _deadline


# --- Evaluation (from red's point of view) ------------------------------

func _terminal_score(state: NineMensMorrisGameState) -> int:
	match state.result:
		NineMensMorrisGameState.Result.RED_WIN:
			return WIN_SCORE - state.ply
		NineMensMorrisGameState.Result.GREEN_WIN:
			return -WIN_SCORE + state.ply
	return 0  # draws are worth nothing to either side


## +1 while red is to move, -1 for green (negamax expects a score from
## the side to move's point of view).
func _perspective(state: NineMensMorrisGameState) -> int:
	return 1 if state.side_to_move == NineMensMorrisGameState.Side.RED else -1


func _evaluate(state: NineMensMorrisGameState) -> int:
	# Material dominates: a piece in hand is worth as much as one on the
	# board, so only captures — which shrink the enemy's total forever —
	# move this term. Counting the board alone would make every placement
	# look like a gain and dilute the value of a real capture.
	var score := 100 * ((state.count_pieces(NineMensMorrisGameState.Cell.RED) \
			+ state.hands[0]) \
			- (state.count_pieces(NineMensMorrisGameState.Cell.GREEN) \
			+ state.hands[1]))
	score += _mill_score(state, NineMensMorrisGameState.Cell.RED)
	score -= _mill_score(state, NineMensMorrisGameState.Cell.GREEN)
	for point in state.points_of(NineMensMorrisGameState.Cell.RED):
		score += _mobility(state, point) * 3
	for point in state.points_of(NineMensMorrisGameState.Cell.GREEN):
		score -= _mobility(state, point) * 3
	# A side with exactly three pieces flies: its mobility is board-wide.
	if NineMensMorrisRules.phase_of(state,
			NineMensMorrisGameState.Side.RED) == NineMensMorrisRules.PHASE_FLYING:
		score += 15
	if NineMensMorrisRules.phase_of(state,
			NineMensMorrisGameState.Side.GREEN) == NineMensMorrisRules.PHASE_FLYING:
		score -= 15
	return score


## Mill-shaped material for `cell`: formed mills protect their pieces,
## two-fill mills with one empty are the threats that force captures.
func _mill_score(state: NineMensMorrisGameState, cell: int) -> int:
	var total := 0
	for mill in NineMensMorrisRules.MILLS:
		var triple := mill as Array
		var mine := 0
		var empty := 0
		for i in 3:
			var occupant := state.board[int(triple[i])]
			if occupant == cell:
				mine += 1
			elif occupant == NineMensMorrisGameState.Cell.EMPTY:
				empty += 1
		if mine == 3:
			total += 40
		elif mine == 2 and empty == 1:
			total += 10
		elif mine == 1 and empty == 2:
			total += 2
	return total


## Empty neighbours of the piece on `point` — the cheap mobility proxy
## (a flying piece's board-wide reach is scored separately).
func _mobility(state: NineMensMorrisGameState, point: int) -> int:
	var spaces := 0
	for neighbor in NineMensMorrisRules.neighbors(point):
		if state.is_empty(neighbor):
			spaces += 1
	return spaces


# --- Choice policy ------------------------------------------------------

## Applies the difficulty policy to the completed root scores. Sets the
## chosen move (the caller marks the search finished).
func _commit_move() -> void:
	if _root_moves.is_empty():
		return
	if _root_scores.size() != _root_moves.size():
		# No depth ever completed (budget exhausted mid-first-iteration):
		# fall back to a uniformly random legal move — still fully legal.
		_move = _root_moves[_rng.randi_range(0, _root_moves.size() - 1)]
		return
	if difficulty == Difficulty.HARD:
		_move = _root_moves[_argmax(_root_scores)]
	elif difficulty == Difficulty.MEDIUM:
		var best := _root_scores[_argmax(_root_scores)]
		var candidates: Array[int] = []
		for i in _root_scores.size():
			if _root_scores[i] >= best - MEDIUM_MARGIN:
				candidates.append(i)
		_move = _root_moves[candidates[_rng.randi_range(0, candidates.size() - 1)]]
	else:
		_move = _root_moves[_rng.randi_range(0, _root_moves.size() - 1)]
	_finished = true


func _argmax(scores: Array[int]) -> int:
	var best_index := 0
	for i in scores.size():
		if scores[i] > scores[best_index]:
			best_index = i
	return best_index


func _ordered(moves: Array[NineMensMorrisMove]) -> Array[NineMensMorrisMove]:
	var captures: Array[NineMensMorrisMove] = []
	var quiet: Array[NineMensMorrisMove] = []
	for move in moves:
		if move.has_capture():
			captures.append(move)
		else:
			quiet.append(move)
	captures.append_array(quiet)
	return captures


# --- Budgets ------------------------------------------------------------

func _compute_budget() -> int:
	if max_compute_usec > 0:
		return max_compute_usec
	return int(DEFAULT_MAX_COMPUTE_USEC[difficulty])


func _max_depth() -> int:
	return int(MAX_SEARCH_DEPTH[difficulty])

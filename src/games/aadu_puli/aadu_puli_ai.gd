class_name AaduPuliAI
extends RefCounted
## Difficulty-ranked move search for Aadu Puli Aattam.
##
## Contract (Phase 5):
##  - Same rules engine as human players: candidate moves come from
##    AaduPuliRules.legal_moves(), so the search can only ever consider
##    moves the validator would accept. Screens still re-validate before
##    submitting (belt and braces).
##  - Perfect information only: the search reads the AaduPuliGameState
##    it was handed — the same public position any human sees. No
##    private state, no network, no opponent-side randomness.
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

## Maximum search horizon per difficulty (plies ahead).
const MAX_SEARCH_DEPTH := {
	Difficulty.EASY: 1,
	Difficulty.MEDIUM: 3,
	Difficulty.HARD: 5,
}

## Strong reference to the one AI whose worker thread is (or was) running.
## It keeps that object alive for as long as its worker may touch it —
## GDScript objects must never be freed while a thread still runs on
## them — and the next threaded start() cancels and reaps it.
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
var _state: AaduPuliGameState = null
var _root_moves: Array[AaduPuliMove] = []
var _root_scores: Array[int] = []
var _started_usec := 0
var _hard_deadline := 0
var _deadline := 0
var _depth := 0
var _finished := false
var _move: AaduPuliMove = null

var _thread: Thread = null
var _mutex := Mutex.new()
var _cancel := false


# --- Lifecycle ----------------------------------------------------------

## Snapshots `state` and prepares a search. Terminal or move-less
## positions finish immediately with a null move. Any previous search
## is cancelled and joined first.
func start(state: AaduPuliGameState) -> void:
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
	_root_moves = AaduPuliRules.legal_moves(_state)
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
		var running = AaduPuliAI._active
		if running != null and running != self:
			running._shutdown()  # cancel and reap any previous worker
		AaduPuliAI._active = self
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
func get_move() -> AaduPuliMove:
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
static func choose_move(state: AaduPuliGameState, level: int, seed: int = 0,
		budget_usec: int = -1) -> AaduPuliMove:
	var ai := AaduPuliAI.new()
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
	if AaduPuliAI._active == self:
		AaduPuliAI._active = null


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
		var child := AaduPuliRules.apply(_state, move)
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


func _negamax(state: AaduPuliGameState, depth: int, alpha: int,
		beta: int) -> int:
	if _aborted():
		return 0
	if state.result != AaduPuliGameState.Result.NONE:
		return _terminal_score(state) * _perspective(state)
	if depth <= 0:
		return _evaluate(state) * _perspective(state)
	var moves := _ordered(AaduPuliRules.legal_moves(state))
	if moves.is_empty():
		# Engine states are pre-evaluated after every apply, so this is
		# unreachable for well-formed play; treat it as a dead end.
		return _evaluate(state) * _perspective(state)
	for move in moves:
		var child := AaduPuliRules.apply(state, move)
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


# --- Evaluation (from the tigers' point of view) ------------------------

func _terminal_score(state: AaduPuliGameState) -> int:
	match state.result:
		AaduPuliGameState.Result.TIGERS_WIN:
			return WIN_SCORE - state.ply
		AaduPuliGameState.Result.GOATS_WIN:
			return -WIN_SCORE + state.ply
	return 0


## +1 while the tigers are to move, -1 for the goats (negamax expects a
## score from the side to move's point of view).
func _perspective(state: AaduPuliGameState) -> int:
	return 1 if state.side_to_move == AaduPuliGameState.Side.TIGERS else -1


func _evaluate(state: AaduPuliGameState) -> int:
	var score := 100 * state.goats_captured
	for tiger in state.tiger_points():
		score += _escape_spaces(state, tiger) * 6
		if tiger == 0:
			score += 10  # holding the apex keeps exits open
	for goat in state.goat_points():
		score -= _escape_spaces(state, goat)
	return score


func _escape_spaces(state: AaduPuliGameState, point: int) -> int:
	var spaces := 0
	for neighbor in AaduPuliRules.neighbors(point):
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


func _ordered(moves: Array[AaduPuliMove]) -> Array[AaduPuliMove]:
	var captures: Array[AaduPuliMove] = []
	var quiet: Array[AaduPuliMove] = []
	for move in moves:
		if move.is_capture():
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

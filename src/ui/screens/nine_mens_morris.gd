extends Control
## Nine Men's Morris — offline against the built-in AI or hot-seat
## (pass and play), plus online play against the authoritative NestJS
## server.
##
## Offline: the screen renders the engine's state and submits moves;
## every rule, legality decision and outcome lives in the NineMensMorris*
## engine classes. Input works in three phases (spec §4): during
## placement a tap on an empty point places a piece; during movement or
## flying a tap selects a friendly piece and a second tap on a legal
## landing moves it. A landing that forms a mill opens the capture step:
## the enemy pieces that may be removed are ringed in red and one of
## them completes the move. The AI uses the same rules engine through
## NineMensMorrisAI: it searches on a worker thread, is re-validated
## like a human move, and is cancelled by restart, undo, mode and
## difficulty switches and screen exit. The position survives restarts
## via user://nine_mens_morris_save.json.
##
## Online: the server decides everything — legality, turn order,
## result, rating. The local engine is advisory UX only (it suggests
## where a piece could go); state is applied exclusively from server
## responses, and the offline save file is never touched.

const SAVE_PATH := "user://nine_mens_morris_save.json"
const SETTINGS_SECTION := "nine_mens_morris"

## Indexed by NineMensMorrisAI.Difficulty (easy, medium, hard).
const DIFFICULTY_KEYS := ["easy", "medium", "hard"]
const DIFFICULTY_NAMES := ["Easy", "Medium", "Hard"]

@onready var _board: MorrisBoard = $Margin/Content/Board
@onready var _status_label: Label = $Margin/Content/StatusLabel
@onready var _detail_label: Label = $Margin/Content/DetailLabel
@onready var _undo_button: Button = $Margin/Content/Controls/UndoButton
@onready var _restart_button: Button = $Margin/Content/Controls/RestartButton
@onready var _resign_button: Button = $Margin/Content/Controls/ResignButton
@onready var _rematch_button: Button = $Margin/Content/Controls/RematchButton
@onready var _hint_label: Label = $Margin/Content/Controls/HintLabel
@onready var _vs_ai_button: Button = $Margin/Content/ModeRow/VsAiButton
@onready var _hot_seat_button: Button = $Margin/Content/ModeRow/HotSeatButton
@onready var _online_button: Button = $Margin/Content/ModeRow/OnlineButton
@onready var _ai_badge: Control = $Margin/Content/ModeRow/AiBadge
@onready var _ai_badge_label: Label = \
		$Margin/Content/ModeRow/AiBadge/AiBadgeRow/AiBadgeLabel
@onready var _spinner: Control = \
		$Margin/Content/ModeRow/AiBadge/AiBadgeRow/ThinkingSpinner
@onready var _online_row: Control = $Margin/Content/OnlineRow
@onready var _new_match_button: Button = \
		$Margin/Content/OnlineRow/OnlineActions/NewMatchButton
@onready var _join_button: Button = \
		$Margin/Content/OnlineRow/OnlineActions/JoinButton
@onready var _match_field: LineEdit = \
		$Margin/Content/OnlineRow/OnlineActions/MatchIdField
@onready var _online_label: Label = $Margin/Content/OnlineRow/OnlineStatusLabel
@onready var _difficulty_row: Control = $Margin/Content/DifficultyRow
@onready var _easy_button: Button = $Margin/Content/DifficultyRow/EasyButton
@onready var _medium_button: Button = $Margin/Content/DifficultyRow/MediumButton
@onready var _hard_button: Button = $Margin/Content/DifficultyRow/HardButton

var _state: NineMensMorrisGameState
var _history: Array[String] = []
var _notation_history: Array[String] = []
## Selected friendly piece awaiting a landing tap (-1 when none).
var _selection: int = -1
## Landing chosen while a mill's capture is pending (capture = -1 yet).
var _pending_base: NineMensMorrisMove = null
## Enemy pieces that may be removed to complete the pending move.
var _capture_targets: Array[int] = []
var _last_notation := ""

## The human plays red (first move); the AI plays green in vs-AI mode.
var _ai_mode := true
var _difficulty: int = NineMensMorrisAI.Difficulty.MEDIUM
var _ai: NineMensMorrisAI = null
var _ai_game_seed := 0

## Online mode.
var _online_mode := false
var _submitting := false
var _announced_match_id := ""

## Phase 8: match whose result dialog is on screen — checked for an
## interstitial once the player dismisses it (never mid-game).
var _result_dialog_match_id := ""


func _ready() -> void:
	_load_settings()
	_load_or_new()
	_ai_game_seed = randi()
	_board.point_activated.connect(_on_point_activated)
	_undo_button.pressed.connect(_on_undo_pressed)
	_restart_button.pressed.connect(_on_restart_pressed)
	_vs_ai_button.pressed.connect(func() -> void: _set_ai_mode(true))
	_hot_seat_button.pressed.connect(func() -> void: _set_ai_mode(false))
	_online_button.pressed.connect(_set_online_mode)
	_new_match_button.pressed.connect(_on_new_match_pressed)
	_join_button.pressed.connect(_on_join_pressed)
	_resign_button.pressed.connect(_on_resign_pressed)
	_rematch_button.pressed.connect(_on_rematch_pressed)
	_easy_button.pressed.connect(
			func() -> void: _set_difficulty(NineMensMorrisAI.Difficulty.EASY))
	_medium_button.pressed.connect(
			func() -> void: _set_difficulty(NineMensMorrisAI.Difficulty.MEDIUM))
	_hard_button.pressed.connect(
			func() -> void: _set_difficulty(NineMensMorrisAI.Difficulty.HARD))
	for button in [_vs_ai_button, _hot_seat_button, _easy_button,
			_medium_button, _hard_button]:
		button.toggled.connect(_on_mode_toggled)
	App.online.connection_changed.connect(_on_online_connection)
	App.online.state_applied.connect(_on_online_state)
	App.online.match_changed.connect(_on_online_match_changed)
	App.online.match_completed.connect(_on_online_completed)
	if App.online.consume_auto_online():
		_set_online_mode()
	_refresh()


func _process(_delta: float) -> void:
	if _online_mode:
		_online_label.text = _online_label_text()
	if _ai == null:
		return
	if not _ai.is_finished():
		return
	var move := _ai.get_move()
	_ai = null
	if move == null:
		push_error("NineMensMorris: AI search produced no move")
		_refresh()
		return
	_submit_ai_move(move)


func _exit_tree() -> void:
	# Never leave a worker thread behind when the screen goes away.
	_cancel_ai()
	# Online play does not survive screen exit; re-entering online mode
	# resumes via GET /matches.
	if _online_mode:
		App.online.leave()
		_online_mode = false


# --- Input --------------------------------------------------------------

func _on_point_activated(point: int) -> void:
	if _state == null or _state.is_terminal():
		return
	if _online_mode:
		if _submitting:
			return
		if not App.online.is_active() or App.online.match_status != "ACTIVE":
			return
		if not App.online.is_my_turn():
			return
		_handle_tap(point)
		return
	if _ai_mode and _state.side_to_move == NineMensMorrisGameState.Side.GREEN:
		return  # the AI owns the green turn
	_handle_tap(point)


## One tap on the board: complete a pending capture, place a piece,
## select a friendly piece, follow a legal landing, or deselect.
func _handle_tap(point: int) -> void:
	if not _capture_targets.is_empty():
		if _capture_targets.has(point) and _pending_base != null:
			var chosen := _pending_base
			chosen.capture = point
			_submit_move(chosen)
		return
	if _current_phase() == NineMensMorrisRules.PHASE_PLACEMENT:
		if not _state.is_empty(point):
			_clear_selection()
			_refresh()
			return
		_begin_landing(NineMensMorrisMove.place(point))
		return
	# Movement or flying: select a friendly piece, then a landing.
	if _state.cell(point) == _own_cell():
		if _selection == point:
			_clear_selection()  # tap the same piece again to deselect
		else:
			_selection = point
			_pending_base = null
		_refresh()
		return
	if _selection >= 0 and _landing_allowed(_selection, point):
		_begin_landing(NineMensMorrisMove.step(_selection, point))
		return
	if _selection >= 0:
		_clear_selection()
		_refresh()


## Chooses the landing's final move: submit straight away, or hold it
## as pending while the player picks the mill's capture.
func _begin_landing(base: NineMensMorrisMove) -> void:
	var captures: Array[int] = []
	var plain_ok := false
	for move in NineMensMorrisRules.legal_moves_landing(_state, base.land()):
		if base.kind == NineMensMorrisMove.KIND_MOVE \
				and move.from_point != base.from_point:
			continue
		if move.has_capture():
			if not captures.has(move.capture):
				captures.append(move.capture)
		else:
			plain_ok = true
	if captures.is_empty() and not plain_ok:
		_refresh()  # nothing legal lands there (defensive)
		return
	if captures.is_empty():
		_submit_move(base)
		return
	_pending_base = base
	_capture_targets = captures
	_refresh()


## True when some legal move steps `from` onto `to`.
func _landing_allowed(from: int, to: int) -> bool:
	if not _state.is_empty(to):
		return false
	for move in NineMensMorrisRules.legal_moves_landing(_state, to):
		if move.kind == NineMensMorrisMove.KIND_MOVE \
				and move.from_point == from:
			return true
	return false


func _clear_selection() -> void:
	_selection = -1
	_pending_base = null
	_capture_targets = []


func _on_undo_pressed() -> void:
	if _online_mode or _history.is_empty():
		return
	_cancel_ai()
	_pop_undo()
	if _ai_mode:
		# Rewind the whole exchange so the human controls red again.
		while not _history.is_empty() \
				and _state.side_to_move != NineMensMorrisGameState.Side.RED:
			_pop_undo()
	_clear_selection()
	_save()  # the save file must never resurrect an undone position
	_refresh()


func _on_restart_pressed() -> void:
	if _online_mode:
		return
	_cancel_ai()  # the pending search must not outlive the decision
	var confirmed: bool = await App.dialog.confirm("Restart game?",
			"The current position will be discarded and a fresh game will start.",
			"Restart")
	if not confirmed:
		_refresh()  # resumes the search if it is still the AI's turn
		return
	_state = NineMensMorrisGameState.initial()
	_history.clear()
	_notation_history.clear()
	_last_notation = ""
	_clear_selection()
	_ai_game_seed = randi()
	_save()
	_refresh()


func _on_mode_toggled(_toggled_on: bool) -> void:
	# A pressed toggle can be clicked off; re-sync the control group.
	_refresh()


# --- Mode and difficulty ------------------------------------------------

func _set_ai_mode(enabled: bool) -> void:
	var left_online := false
	if _online_mode:
		_leave_online()
		left_online = true
	if _ai_mode == enabled:
		if left_online:
			_refresh()
		return
	_cancel_ai()
	_ai_mode = enabled
	_clear_selection()
	App.save_local_setting(SETTINGS_SECTION, "opponent",
			"ai" if _ai_mode else "hot_seat")
	_refresh()


func _set_difficulty(level: int) -> void:
	if _difficulty == level:
		_refresh()
		return
	_cancel_ai()
	_difficulty = level
	_clear_selection()
	App.save_local_setting(SETTINGS_SECTION, "difficulty",
			DIFFICULTY_KEYS[level])
	_refresh()


## Starts a search when it is the AI's turn. Idempotent: a refresh
## while the AI is thinking never restarts the search.
func _maybe_start_ai() -> void:
	if not _ai_mode or _ai != null:
		return
	if _online_mode or _state == null or _state.is_terminal():
		return
	if _state.side_to_move != NineMensMorrisGameState.Side.GREEN:
		return
	var ai := NineMensMorrisAI.new()
	ai.difficulty = _difficulty
	ai.ai_seed = _ai_game_seed + _state.ply
	ai.start(_state)
	_ai = ai


func _cancel_ai() -> void:
	if _ai != null:
		_ai.cancel()
		_ai = null


func _is_thinking() -> bool:
	return _ai != null and not _ai.is_finished()


# --- Online mode --------------------------------------------------------

## Toggles the online opponent mode. Entering it does not touch the
## network until the player asks for a match (or resumes one).
func _set_online_mode() -> void:
	if _online_mode:
		_refresh()
		return
	_cancel_ai()
	_online_mode = true
	_ai_mode = false
	_clear_selection()
	_announced_match_id = ""
	# One shared OnlineMatchService, pointed at this game's key.
	App.online.set_game_key(OnlineMatchService.NINE_MENS_MORRIS_KEY)
	_online_bootstrap()
	_refresh()


## Leaving online mode: drop the socket (the server applies its
## disconnect grace) and restore the offline position, which online
## play never wrote.
func _leave_online() -> void:
	App.online.leave()
	_online_mode = false
	_submitting = false
	_clear_selection()
	_announced_match_id = ""
	_load_or_new()


## Connects (when signed in) and resumes a still-open match, if any.
func _online_bootstrap() -> void:
	if not App.auth.is_authenticated():
		_refresh()  # the online label shows the sign-in hint
		return
	var conn: Dictionary = await App.online.connect_service()
	if not _online_mode or not conn.ok:
		_refresh()
		return
	var found: Dictionary = await App.online.find_resumable_match()
	if not _online_mode:
		return
	var resume_id := str(found.get("match_id", ""))
	if not resume_id.is_empty():
		await App.online.subscribe_match(resume_id)
		_match_field.text = App.online.match_id
	_sync_from_online()


## Sign in (guest when needed) and open the realtime socket.
func _ensure_online() -> Dictionary:
	if not App.auth.is_authenticated():
		var login: Dictionary = await App.auth.guest_login()
		if not login.ok:
			return {"ok": false, "error": str(login.get("message",
					"Sign in to play online matches."))}
	if App.online.is_connected_to_server():
		return {"ok": true}
	return await App.online.connect_service()


func _on_new_match_pressed() -> void:
	if _submitting:
		return
	_submitting = true
	App.dialog.show_loading("Creating match…")
	var result := await _ensure_online()
	if result.ok:
		result = await App.online.create_match()
	if result.ok:
		result = await App.online.subscribe_match(App.online.match_id)
	App.dialog.hide_loading()
	_submitting = false
	if not result.ok:
		App.dialog.show_error("Could not start a match",
				str(result.get("error", "Unknown error.")))
		_refresh()
		return
	_announced_match_id = ""
	_match_field.text = App.online.match_id
	_sync_from_online()


func _on_join_pressed() -> void:
	if _submitting:
		return
	var code := _match_field.text.strip_edges()
	if code.is_empty():
		App.dialog.show_error("Match code required",
				"Paste the match code your opponent shared.")
		return
	_submitting = true
	App.dialog.show_loading("Joining match…")
	var result := await _ensure_online()
	if result.ok:
		result = await App.online.join_match(code)
	if result.ok:
		result = await App.online.subscribe_match(code)
	App.dialog.hide_loading()
	_submitting = false
	if not result.ok:
		App.dialog.show_error("Could not join the match",
				str(result.get("error", "Unknown error.")))
		_refresh()
		return
	_announced_match_id = ""
	_sync_from_online()


func _on_resign_pressed() -> void:
	if not App.online.is_active():
		return
	var confirmed: bool = await App.dialog.confirm("Resign match?",
			"You will lose this match. The opponent wins.", "Resign")
	if not confirmed:
		_refresh()
		return
	var ack: Dictionary = await App.online.resign()
	if not ack.ok:
		App.dialog.show_error("Resign failed", str(ack.get("error", "")))
	_maybe_announce_completion()
	_refresh()


func _on_rematch_pressed() -> void:
	if _submitting:
		return
	_submitting = true
	var ack: Dictionary = await App.online.rematch()
	_submitting = false
	if not ack.ok:
		App.dialog.show_error("Rematch failed", str(ack.get("error", "")))
		_refresh()
		return
	_announced_match_id = ""
	_match_field.text = App.online.match_id
	_sync_from_online()


func _submit_online(move: NineMensMorrisMove) -> void:
	if _submitting:
		return
	_submitting = true
	_clear_selection()
	_refresh()
	var ack: Dictionary = await App.online.submit_move(move.to_dict())
	_submitting = false
	if not ack.ok:
		App.dialog.show_error("Move rejected",
				str(ack.get("error", "The server refused the move.")))
		_refresh()
		return
	_sync_from_online()


## Applies the authoritative server state to the board. This is the
## ONLY path that changes the position while online.
func _sync_from_online() -> void:
	var payload: Dictionary = App.online.state_dict
	if not payload.is_empty():
		var restored := NineMensMorrisGameState.deserialize(payload)
		if restored == null:
			push_error("NineMensMorris: server state failed to deserialize")
		else:
			_state = restored
			_last_notation = App.online.last_notation
			_clear_selection()
	_maybe_announce_completion()
	_refresh()


func _on_online_connection(_connected: bool) -> void:
	if _online_mode:
		_refresh()


func _on_online_state() -> void:
	if _online_mode:
		_sync_from_online()


func _on_online_match_changed() -> void:
	if _online_mode:
		_match_field.text = App.online.match_id
		_sync_from_online()


func _on_online_completed(_data: Dictionary) -> void:
	if _online_mode:
		_maybe_announce_completion()
		_refresh()


## One dialog per finished match, always from the server's results.
func _maybe_announce_completion() -> void:
	if not _online_mode:
		return
	if App.online.match_status != "COMPLETED":
		return
	if _announced_match_id == App.online.match_id:
		return
	_announced_match_id = App.online.match_id
	var results: Dictionary = App.online.completion.get("results", {})
	var mine := str(results.get(App.auth.get_player_id(), ""))
	var reason := str(App.online.completion.get("reason", ""))
	match mine:
		"WIN":
			_announce_online_result("You win!", _completion_text(reason, true))
		"LOSS":
			_announce_online_result("You lose", _completion_text(reason, false))
		"DRAW":
			_announce_online_result("Draw",
					"The match ended without a winner.")
		_:
			pass  # not a participant in the result map: no dialog


## Shows the finished-match result dialog and arms the Phase 8
## interstitial check: once the player dismisses this dialog we ask the
## SERVER whether an interstitial is due (never during active play).
func _announce_online_result(title: String, message: String) -> void:
	_result_dialog_match_id = App.online.match_id
	App.dialog.error_dismissed.connect(
			_on_result_dialog_dismissed, CONNECT_ONE_SHOT)
	App.dialog.show_error(title, message)


func _on_result_dialog_dismissed() -> void:
	var match_id := _result_dialog_match_id
	_result_dialog_match_id = ""
	App.ads.check_interstitial(match_id)


func _completion_text(reason: String, won: bool) -> String:
	match reason:
		"RESIGN":
			return "The opponent resigned." if won \
					else "You resigned the match."
		"TIMEOUT":
			return "The opponent ran out of time." if won \
					else "You ran out of time."
		"DISCONNECT":
			return "The opponent left the match." if won \
					else "You left the match and forfeited."
		_:
			return "Decided by the rules of the board."


# --- Moves --------------------------------------------------------------

## Final tap of a move (server-first while online).
func _submit_move(move: NineMensMorrisMove) -> void:
	if _online_mode:
		_submit_online(move)
	else:
		_submit(move)


func _submit(move: NineMensMorrisMove) -> void:
	var verdict := NineMensMorrisValidator.validate(_state, move)
	if not verdict.ok:
		App.dialog.show_error("Illegal move",
				NineMensMorrisValidator.error_text(verdict.issue))
		_clear_selection()
		_refresh()
		return
	_history.append(JSON.stringify(_state.serialize()))
	_notation_history.append(_last_notation)
	var next := NineMensMorrisRules.apply(_state, move)
	if next == null:
		# Validator and rules agreed a moment ago; never swallow this.
		push_error("NineMensMorris: engine rejected a validated move")
		_history.pop_back()
		_notation_history.pop_back()
		return
	_state = next
	_last_notation = NineMensMorrisRules.notation(move)
	_clear_selection()
	_save()
	_refresh()
	if _state.is_terminal():
		_announce_result()


## The AI's move goes through the exact same validation gate as a
## human's; if it were ever illegal we log loudly and re-search.
func _submit_ai_move(move: NineMensMorrisMove) -> void:
	var verdict := NineMensMorrisValidator.validate(_state, move)
	if not verdict.ok:
		push_error("NineMensMorris: AI produced an illegal move — %s"
				% NineMensMorrisValidator.error_text(verdict.issue))
		_refresh()
		return
	_submit(move)


func _pop_undo() -> void:
	var payload: Variant = JSON.parse_string(_history.pop_back())
	var previous := NineMensMorrisGameState.deserialize(payload)
	if previous == null:
		push_error("NineMensMorris: saved undo state is corrupt — discarding")
		_history.clear()
		_notation_history.clear()
		return
	_state = previous
	_last_notation = _notation_history.pop_back() \
			if not _notation_history.is_empty() else ""


func _own_cell() -> int:
	return NineMensMorrisGameState.Cell.RED \
			if _state.side_to_move == NineMensMorrisGameState.Side.RED \
			else NineMensMorrisGameState.Cell.GREEN


func _current_phase() -> String:
	return NineMensMorrisRules.phase_of(_state, _state.side_to_move)


# --- Presentation -------------------------------------------------------

func _refresh() -> void:
	_maybe_start_ai()
	var thinking := _is_thinking()
	_status_label.text = _status_text()
	_detail_label.text = _detail_text()
	_undo_button.disabled = _history.is_empty()
	_sync_mode_controls(thinking)
	_board.configure(_state, _selection, _target_points(), _capture_targets)


func _sync_mode_controls(thinking: bool) -> void:
	_vs_ai_button.set_pressed_no_signal(_ai_mode and not _online_mode)
	_hot_seat_button.set_pressed_no_signal(not _ai_mode and not _online_mode)
	_online_button.set_pressed_no_signal(_online_mode)
	_ai_badge.visible = _ai_mode and not _online_mode
	_difficulty_row.visible = _ai_mode and not _online_mode
	_spinner.visible = _ai_mode and thinking
	if _ai_mode and not _online_mode:
		_ai_badge_label.text = "AI thinking…" if thinking \
				else "AI: %s" % DIFFICULTY_NAMES[_difficulty]
	_easy_button.set_pressed_no_signal(
			_difficulty == NineMensMorrisAI.Difficulty.EASY)
	_medium_button.set_pressed_no_signal(
			_difficulty == NineMensMorrisAI.Difficulty.MEDIUM)
	_hard_button.set_pressed_no_signal(
			_difficulty == NineMensMorrisAI.Difficulty.HARD)
	# Offline-only controls hide online; Resign/Rematch follow the match.
	_undo_button.visible = not _online_mode
	_restart_button.visible = not _online_mode
	_online_row.visible = _online_mode
	_resign_button.visible = _online_mode and App.online.is_active()
	_rematch_button.visible = _online_mode \
			and App.online.match_status == "COMPLETED"
	if _online_mode:
		_hint_label.text = _online_hint_text()
		_online_label.text = _online_label_text()
	elif not _capture_targets.is_empty():
		_hint_label.text = "Mill formed · tap a ringed enemy piece to remove it"
	elif _selection >= 0:
		_hint_label.text = "Piece %d selected · tap a ringed point" % _selection
	elif _current_phase() == NineMensMorrisRules.PHASE_PLACEMENT:
		_hint_label.text = "Place a piece on any open point"
	elif _ai_mode:
		_hint_label.text = "You play red · AI: %s" \
				% DIFFICULTY_NAMES[_difficulty]
	else:
		_hint_label.text = "Hot seat · pass and play"


## Ringed landing points: a pending mill's landing, every open point
## during placement, or the landings of the selected piece.
func _target_points() -> Array[int]:
	var points: Array[int] = []
	if not _capture_targets.is_empty():
		if _pending_base != null:
			points.append(_pending_base.land())
		return points
	if _state == null:
		return points
	if _current_phase() == NineMensMorrisRules.PHASE_PLACEMENT:
		for point in NineMensMorrisGameState.POINT_COUNT:
			if _state.is_empty(point):
				points.append(point)
		return points
	if _selection >= 0:
		for move in NineMensMorrisRules.legal_moves(_state):
			if move.kind == NineMensMorrisMove.KIND_MOVE \
					and move.from_point == _selection \
					and not points.has(move.land()):
				points.append(move.land())
		points.sort()
	return points


func _status_text() -> String:
	if _state == null:
		return ""
	if _online_mode:
		return _online_status_text()
	match _state.result:
		NineMensMorrisGameState.Result.RED_WIN:
			return "Red wins — %s" % _win_reason(
					NineMensMorrisGameState.Result.RED_WIN)
		NineMensMorrisGameState.Result.GREEN_WIN:
			return "Green wins — %s" % _win_reason(
					NineMensMorrisGameState.Result.GREEN_WIN)
		NineMensMorrisGameState.Result.DRAW:
			return "Draw — %s" % _draw_reason()
	if not _capture_targets.is_empty():
		return "%s to capture — remove a ringed enemy piece" % _side_name(
				_state.side_to_move)
	if _ai_mode and _state.side_to_move == NineMensMorrisGameState.Side.GREEN \
			and _is_thinking():
		return "Green is thinking…"
	var who := _side_name(_state.side_to_move)
	match _current_phase():
		NineMensMorrisRules.PHASE_PLACEMENT:
			return "%s to move — place a piece" % who
		NineMensMorrisRules.PHASE_FLYING:
			return "%s to move — fly to any open point" % who
	return "%s to move — step to an adjacent point" % who


## Why `result` was reached (spec §7): starvation below three pieces
## or the opponent having no legal move.
func _win_reason(result: int) -> String:
	var loser := NineMensMorrisGameState.Side.GREEN \
			if result == NineMensMorrisGameState.Result.RED_WIN \
			else NineMensMorrisGameState.Side.RED
	if _state.hand_of(loser) == 0 \
			and _state.count_pieces(_cell_of(loser)) < 3:
		return "the enemy has fewer than three pieces"
	return "the enemy has no legal move"


func _draw_reason() -> String:
	if _state.plies_since_capture >= NineMensMorrisGameState.PLIES_TO_DRAW:
		return "%d plies without a capture" \
				% NineMensMorrisGameState.PLIES_TO_DRAW
	return "the same position occurred three times"


func _side_name(side: int) -> String:
	return "Red" if side == NineMensMorrisGameState.Side.RED else "Green"


func _cell_of(side: int) -> int:
	return NineMensMorrisGameState.Cell.RED \
			if side == NineMensMorrisGameState.Side.RED \
			else NineMensMorrisGameState.Cell.GREEN


func _detail_text() -> String:
	var parts := [
		"Red %d · Green %d" % [
			_state.count_pieces(NineMensMorrisGameState.Cell.RED),
			_state.count_pieces(NineMensMorrisGameState.Cell.GREEN),
		],
		"Hand %d · %d" % [
			_state.hand_of(NineMensMorrisGameState.Side.RED),
			_state.hand_of(NineMensMorrisGameState.Side.GREEN),
		],
		"Move %d" % (floori(_state.ply / 2.0) + 1),
		"Quiet %d/%d" % [_state.plies_since_capture,
				NineMensMorrisGameState.PLIES_TO_DRAW],
	]
	if not _last_notation.is_empty():
		parts.append("Last: %s" % _last_notation)
	if _online_mode and App.online.is_active():
		parts.append("You: %s" % App.online.side)
	return "  ·  ".join(parts)


## Status text for the online mode: connection, lobby and turn state.
## All game outcomes come from the server's completion results.
func _online_status_text() -> String:
	var online := App.online
	if not App.auth.is_authenticated():
		return "Sign in to play online"
	if online.reconnecting:
		return "Reconnecting to the server…"
	if not online.connected:
		return "Connecting to the server…"
	if online.match_id.is_empty():
		return "Create a match or join with a code"
	if online.match_status == "PENDING":
		return "Waiting for an opponent…"
	if online.match_status == "COMPLETED":
		var results: Dictionary = online.completion.get("results", {})
		match str(results.get(App.auth.get_player_id(), "")):
			"WIN":
				return "Match complete — you win"
			"LOSS":
				return "Match complete — you lose"
			"DRAW":
				return "Match complete — draw"
		return "Match complete"
	if not online.opponent_connected():
		return "Opponent disconnected — waiting…"
	if not _capture_targets.is_empty() and online.is_my_turn():
		return "Your move — remove a ringed enemy piece"
	if online.is_my_turn():
		return "Your move — %s" % _phase_action()
	return "Opponent to move…"


func _phase_action() -> String:
	if _state == null:
		return "move"
	match _current_phase():
		NineMensMorrisRules.PHASE_PLACEMENT:
			return "place a piece"
		NineMensMorrisRules.PHASE_FLYING:
			return "fly to an open point"
	return "step to an adjacent point"


## Caption under the create/join controls: match code, turn countdown
## and opponent presence, all from server-provided data.
func _online_label_text() -> String:
	var online := App.online
	if not App.auth.is_authenticated():
		return "Sign in to play online matches"
	if online.reconnecting:
		return "Reconnecting to the server…"
	if not online.connected:
		return "Not connected"
	if online.match_id.is_empty():
		return "Create a match or join with a code"
	if online.match_status == "PENDING":
		return "Match %s · waiting for an opponent" % online.match_id
	if online.match_status == "COMPLETED":
		return "Match %s · finished — start a rematch" % online.match_id
	var text := "Match %s · " % online.match_id
	text += "your move" if online.is_my_turn() else "opponent to move"
	var left := online.turn_seconds_left()
	if left > 0:
		text += " · %ds left" % left
	if not online.opponent_connected():
		text += " · opponent offline"
	if _submitting:
		text += " · sending…"
	return text


func _online_hint_text() -> String:
	if App.online.side.is_empty():
		return "Online · every move is validated by the server"
	return "Online · you play the %s pieces" % App.online.side


func _announce_result() -> void:
	match _state.result:
		NineMensMorrisGameState.Result.RED_WIN:
			App.dialog.show_error("Red win", "Red: %s."
					% _win_reason(NineMensMorrisGameState.Result.RED_WIN))
		NineMensMorrisGameState.Result.GREEN_WIN:
			App.dialog.show_error("Green win", "Green: %s."
					% _win_reason(NineMensMorrisGameState.Result.GREEN_WIN))
		NineMensMorrisGameState.Result.DRAW:
			App.dialog.show_error("Draw", "Draw: %s." % _draw_reason())


# --- Persistence --------------------------------------------------------

func _save() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("NineMensMorris: cannot write %s" % SAVE_PATH)
		return
	file.store_string(JSON.stringify(_state.serialize()))
	file.close()


func _load_or_new() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
		if file != null:
			var restored := NineMensMorrisGameState.deserialize(
					JSON.parse_string(file.get_as_text()))
			file.close()
			if restored != null:
				_state = restored
				return
		var dir := DirAccess.open("user://")
		if dir != null:
			dir.remove("nine_mens_morris_save.json")
	_state = NineMensMorrisGameState.initial()


func _load_settings() -> void:
	_ai_mode = str(App.get_local_setting(
			SETTINGS_SECTION, "opponent", "ai")) != "hot_seat"
	var key := str(App.get_local_setting(
			SETTINGS_SECTION, "difficulty", "medium"))
	var level := DIFFICULTY_KEYS.find(key)
	_difficulty = NineMensMorrisAI.Difficulty.MEDIUM if level < 0 else level

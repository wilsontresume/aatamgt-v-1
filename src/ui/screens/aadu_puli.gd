extends Control
## Aadu Puli Aattam — offline against the built-in AI or hot-seat
## (pass and play), plus online play (Phase 6) against the
## authoritative NestJS server.
##
## Offline: the screen renders the engine's state and submits moves;
## every rule, legality decision and outcome lives in the AaduPuli*
## engine classes. The AI uses the same rules engine through
## AaduPuliAI: it searches on a worker thread (the game loop never
## blocks), is re-validated like a human move, and is cancelled by
## restart, undo, mode/difficulty switches and screen exit.
## The position survives restarts via user://aadu_puli_save.json.
##
## Online: the server decides everything — legality, turn order,
## result, rating. The local engine is advisory UX only (it suggests
## where a piece could go); state is applied exclusively from server
## responses, and the offline save file is never touched.

const SAVE_PATH := "user://aadu_puli_save.json"
const SETTINGS_SECTION := "aadu_puli"

## Indexed by AaduPuliAI.Difficulty (easy, medium, hard).
const DIFFICULTY_KEYS := ["easy", "medium", "hard"]
const DIFFICULTY_NAMES := ["Easy", "Medium", "Hard"]

@onready var _board: AaduPuliBoard = $Margin/Content/Board
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

var _state: AaduPuliGameState
var _history: Array[String] = []
var _notation_history: Array[String] = []
var _selected: int = -1
var _last_notation := ""

## The human plays the goats; the AI plays the tigers in vs-AI mode.
var _ai_mode := true
var _difficulty: int = AaduPuliAI.Difficulty.MEDIUM
var _ai: AaduPuliAI = null
var _ai_game_seed := 0

## Phase 6 online mode.
var _online_mode := false
var _submitting := false
var _announced_match_id := ""


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
			func() -> void: _set_difficulty(AaduPuliAI.Difficulty.EASY))
	_medium_button.pressed.connect(
			func() -> void: _set_difficulty(AaduPuliAI.Difficulty.MEDIUM))
	_hard_button.pressed.connect(
			func() -> void: _set_difficulty(AaduPuliAI.Difficulty.HARD))
	for button in [_vs_ai_button, _hot_seat_button, _easy_button,
			_medium_button, _hard_button]:
		button.toggled.connect(_on_mode_toggled)
	App.online.connection_changed.connect(_on_online_connection)
	App.online.state_applied.connect(_on_online_state)
	App.online.match_changed.connect(_on_online_match_changed)
	App.online.match_completed.connect(_on_online_completed)
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
		push_error("AaduPuli: AI search produced no move")
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
	if _online_mode:
		_on_online_point(point)
		return
	if _state == null or _state.is_terminal():
		return
	if _ai_mode and _state.side_to_move == AaduPuliGameState.Side.TIGERS:
		return  # the AI owns the tiger turn
	var moves := _moves_from_selection()
	if moves.has(point):
		_submit(moves[point])
		return
	if _can_slide_or_step() and _state.cell(point) == _own_cell() \
			and point != _selected:
		_selected = -1 if _selected == point else point
		_refresh()
		return
	if _state.side_to_move == AaduPuliGameState.Side.GOATS \
			and _state.goats_in_hand > 0 and _state.is_empty(point):
		_submit(AaduPuliMove.place(point))
		return
	if _selected != -1:
		_selected = -1
		_refresh()


func _on_undo_pressed() -> void:
	if _online_mode or _history.is_empty():
		return
	_cancel_ai()
	_pop_undo()
	if _ai_mode:
		# Rewind the whole exchange so the human controls the goats again.
		while not _history.is_empty() \
				and _state.side_to_move != AaduPuliGameState.Side.GOATS:
			_pop_undo()
	_selected = -1
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
	_state = AaduPuliGameState.initial()
	_history.clear()
	_notation_history.clear()
	_last_notation = ""
	_selected = -1
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
	_selected = -1
	App.save_local_setting(SETTINGS_SECTION, "opponent",
			"ai" if _ai_mode else "hot_seat")
	_refresh()


func _set_difficulty(level: int) -> void:
	if _difficulty == level:
		_refresh()
		return
	_cancel_ai()
	_difficulty = level
	_selected = -1
	App.save_local_setting(SETTINGS_SECTION, "difficulty",
			DIFFICULTY_KEYS[level])
	_refresh()


## Starts a search when it is the AI's turn. Idempotent: a refresh
## while the AI is thinking never restarts the search.
func _maybe_start_ai() -> void:
	if not _ai_mode or _ai != null:
		return
	if _state == null or _state.is_terminal():
		return
	if _state.side_to_move != AaduPuliGameState.Side.TIGERS:
		return
	var ai := AaduPuliAI.new()
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


# --- Online mode (Phase 6) -----------------------------------------------

## Toggles the online opponent mode. Entering it does not touch the
## network until the player asks for a match (or resumes one).
func _set_online_mode() -> void:
	if _online_mode:
		_refresh()
		return
	_cancel_ai()
	_online_mode = true
	_ai_mode = false
	_selected = -1
	_announced_match_id = ""
	_online_bootstrap()
	_refresh()


## Leaving online mode: drop the socket (the server applies its
## disconnect grace) and restore the offline position, which online
## play never wrote.
func _leave_online() -> void:
	App.online.leave()
	_online_mode = false
	_submitting = false
	_selected = -1
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


## Board tap while online: advisory local UX suggests candidate moves;
## the server has the final word on every submission.
func _on_online_point(point: int) -> void:
	if _submitting or _state == null:
		return
	if not App.online.is_active() or App.online.match_status != "ACTIVE":
		return
	if App.online.is_my_turn():
		var moves := _moves_from_selection()
		if moves.has(point):
			_submit_online(moves[point])
			return
		if _can_slide_or_step() and _state.cell(point) == _own_cell() \
				and point != _selected:
			_selected = -1 if _selected == point else point
			_refresh()
			return
		if _state.side_to_move == AaduPuliGameState.Side.GOATS \
				and _state.goats_in_hand > 0 and _state.is_empty(point):
			_submit_online(AaduPuliMove.place(point))
			return
	if _selected != -1:
		_selected = -1
		_refresh()


func _submit_online(move: AaduPuliMove) -> void:
	if _submitting:
		return
	_submitting = true
	_selected = -1
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
		var restored := AaduPuliGameState.deserialize(payload)
		if restored == null:
			push_error("AaduPuli: server state failed to deserialize")
		else:
			_state = restored
			_last_notation = App.online.last_notation
			_selected = -1
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
			App.dialog.show_error("You win!", _completion_text(reason, true))
		"LOSS":
			App.dialog.show_error("You lose", _completion_text(reason, false))
		"DRAW":
			App.dialog.show_error("Draw",
					"The match ended without a winner.")
		_:
			pass  # not a participant in the result map: no dialog


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

func _submit(move: AaduPuliMove) -> void:
	var verdict := AaduPuliValidator.validate(_state, move)
	if not verdict.ok:
		App.dialog.show_error("Illegal move",
				AaduPuliValidator.error_text(verdict.issue))
		return
	_history.append(JSON.stringify(_state.serialize()))
	_notation_history.append(_last_notation)
	var next := AaduPuliRules.apply(_state, move)
	if next == null:
		# Validator and rules agreed a moment ago; never swallow this.
		push_error("AaduPuli: engine rejected a validated move")
		_history.pop_back()
		_notation_history.pop_back()
		return
	_state = next
	_last_notation = move.notation()
	_selected = -1
	_save()
	_refresh()
	if _state.is_terminal():
		_announce_result()


## The AI's move goes through the exact same validation gate as a
## human's; if it were ever illegal we log loudly and re-search.
func _submit_ai_move(move: AaduPuliMove) -> void:
	var verdict := AaduPuliValidator.validate(_state, move)
	if not verdict.ok:
		push_error("AaduPuli: AI produced an illegal move — %s"
				% AaduPuliValidator.error_text(verdict.issue))
		_refresh()
		return
	_submit(move)


func _pop_undo() -> void:
	var payload: Variant = JSON.parse_string(_history.pop_back())
	var previous := AaduPuliGameState.deserialize(payload)
	if previous == null:
		push_error("AaduPuli: saved undo state is corrupt — discarding")
		_history.clear()
		_notation_history.clear()
		return
	_state = previous
	_last_notation = _notation_history.pop_back() \
			if not _notation_history.is_empty() else ""


func _moves_from_selection() -> Dictionary:
	var moves: Dictionary = {}
	if _selected < 0:
		return moves
	for move in AaduPuliRules.legal_moves_from(_state, _selected):
		moves[move.to_point] = move
	return moves


func _can_slide_or_step() -> bool:
	if _state.side_to_move == AaduPuliGameState.Side.TIGERS:
		return true
	return _state.goats_in_hand == 0


func _own_cell() -> int:
	return AaduPuliGameState.Cell.GOAT \
			if _state.side_to_move == AaduPuliGameState.Side.GOATS \
			else AaduPuliGameState.Cell.TIGER


# --- Presentation -------------------------------------------------------

func _refresh() -> void:
	_maybe_start_ai()
	var thinking := _is_thinking()
	_status_label.text = _status_text()
	_detail_label.text = _detail_text()
	_undo_button.disabled = _history.is_empty()
	_sync_mode_controls(thinking)
	_board.configure(_state, _selected, _target_points(), _is_placing())


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
			_difficulty == AaduPuliAI.Difficulty.EASY)
	_medium_button.set_pressed_no_signal(
			_difficulty == AaduPuliAI.Difficulty.MEDIUM)
	_hard_button.set_pressed_no_signal(
			_difficulty == AaduPuliAI.Difficulty.HARD)
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
	elif _ai_mode:
		_hint_label.text = "You play the goats · AI: %s" \
				% DIFFICULTY_NAMES[_difficulty]
	else:
		_hint_label.text = "Hot seat · pass and play"


func _is_placing() -> bool:
	return _state != null and not _state.is_terminal() \
			and _state.side_to_move == AaduPuliGameState.Side.GOATS \
			and _state.goats_in_hand > 0


func _target_points() -> Array[int]:
	var points: Array[int] = []
	for point in _moves_from_selection().keys():
		points.append(int(point))
	points.sort()
	return points


func _status_text() -> String:
	if _state == null:
		return ""
	if _online_mode:
		return _online_status_text()
	match _state.result:
		AaduPuliGameState.Result.TIGERS_WIN:
			if _state.goats_captured >= AaduPuliGameState.CAPTURES_TO_WIN:
				return "Tigers win — five goats caught"
			return "Tigers win — every tiger is blocked in"
		AaduPuliGameState.Result.GOATS_WIN:
			return "Goats win — the tigers cannot move"
		AaduPuliGameState.Result.DRAW:
			return "Draw — thirty moves each"
	if _ai_mode and _state.side_to_move == AaduPuliGameState.Side.TIGERS \
			and _is_thinking():
		return "Tigers are thinking…"
	if _state.side_to_move == AaduPuliGameState.Side.GOATS:
		return "Goats to move — place a goat" if _state.goats_in_hand > 0 \
				else "Goats to move — slide a goat"
	return "Tigers to move — step or jump"


func _detail_text() -> String:
	var parts := [
		"Captured %d/%d" % [_state.goats_captured, AaduPuliGameState.CAPTURES_TO_WIN],
		"Move %d" % (floori(_state.ply / 2.0) + 1),
	]
	if _state.goats_in_hand > 0:
		parts.append("%d in hand" % _state.goats_in_hand)
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
	if online.is_my_turn():
		if _state.side_to_move == AaduPuliGameState.Side.GOATS:
			return "Your move — place a goat" if _state.goats_in_hand > 0 \
					else "Your move — slide a goat"
		return "Your move — step or jump"
	return "Opponent to move…"


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
	return "Online · you play the %s" \
			% ("goats" if App.online.side == "goats" else "tigers")


func _announce_result() -> void:
	match _state.result:
		AaduPuliGameState.Result.TIGERS_WIN:
			if _state.goats_captured >= AaduPuliGameState.CAPTURES_TO_WIN:
				App.dialog.show_error("Tigers win",
						"Five goats have been caught. The hunt is over.")
			else:
				App.dialog.show_error("Tigers win",
						"The goats blocked every tiger, but had no move left either.")
		AaduPuliGameState.Result.GOATS_WIN:
			App.dialog.show_error("Goats win",
					"Every tiger is sealed in. The herd survives.")
		AaduPuliGameState.Result.DRAW:
			App.dialog.show_error("Draw",
					"Thirty moves each without a winner.")


# --- Persistence --------------------------------------------------------

func _save() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("AaduPuli: cannot write %s" % SAVE_PATH)
		return
	file.store_string(JSON.stringify(_state.serialize()))
	file.close()


func _load_or_new() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
		if file != null:
			var restored := AaduPuliGameState.deserialize(
					JSON.parse_string(file.get_as_text()))
			file.close()
			if restored != null:
				_state = restored
				return
		var dir := DirAccess.open("user://")
		if dir != null:
			dir.remove("aadu_puli_save.json")
	_state = AaduPuliGameState.initial()


func _load_settings() -> void:
	_ai_mode = str(App.get_local_setting(
			SETTINGS_SECTION, "opponent", "ai")) != "hot_seat"
	var key := str(App.get_local_setting(SETTINGS_SECTION, "difficulty", "medium"))
	var level := DIFFICULTY_KEYS.find(key)
	_difficulty = AaduPuliAI.Difficulty.MEDIUM if level < 0 else level

extends Control
## Solah Seedi (16 Soldiers) — offline against the built-in AI or
## hot-seat (pass and play), plus online play against the authoritative
## NestJS server.
##
## Offline: the screen renders the engine's state and submits moves;
## every rule, legality decision and outcome lives in the SolahSeedi*
## engine classes. Input builds a route hop by hop: tapping a soldier
## starts it, each tap adds a legal hop, and a route with no further
## hop is played at once — a route that could continue waits for the
## Play move button (captures are optional, spec §4.3). The AI uses the
## same rules engine through SolahSeediAI: it searches on a worker
## thread, is re-validated like a human move, and is cancelled by
## restart, undo, mode/difficulty switches and screen exit.
## The position survives restarts via user://solah_seedi_save.json.
##
## Online: the server decides everything — legality, turn order,
## result, rating. The local engine is advisory UX only (it suggests
## where a piece could go); state is applied exclusively from server
## responses, and the offline save file is never touched.

const SAVE_PATH := "user://solah_seedi_save.json"
const SETTINGS_SECTION := "solah_seedi"

## Indexed by SolahSeediAI.Difficulty (easy, medium, hard).
const DIFFICULTY_KEYS := ["easy", "medium", "hard"]
const DIFFICULTY_NAMES := ["Easy", "Medium", "Hard"]

@onready var _board: SolahSeediBoard = $Margin/Content/Board
@onready var _status_label: Label = $Margin/Content/StatusLabel
@onready var _detail_label: Label = $Margin/Content/DetailLabel
@onready var _play_button: Button = $Margin/Content/Controls/PlayMoveButton
@onready var _undo_button: Button = $Margin/Content/Controls/UndoButton
@onready var _restart_button: Button = $Margin/Content/Controls/RestartButton
@onready var _resign_button: Button = $Margin/Content/Controls/ResignButton
@onready var _rematch_button: Button = $Margin/Content/Controls/RematchButton
@onready var _hint_label: Label = $Margin/Content/Controls/HintLabel
@onready var _vs_ai_button: Button = $Margin/Content/ModeRow/VsAiButton
@onready var _hot_seat_button: Button = $Margin/Content/ModeRow/HotSeatButton
@onready var _online_button: Button = $Margin/Content/ModeRow/OnlineButton
@onready var _mode_row: Control = $Margin/Content/ModeRow
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
@onready var _you_card: MatchPlayerCard = $Margin/Content/PlayersRow/YouPanel
@onready var _turn_badge: MatchTurnBadge = $Margin/Content/PlayersRow/TurnPanel
@onready var _opp_card: MatchPlayerCard = $Margin/Content/PlayersRow/OppPanel
@onready var _you_hand: MatchHandPanel = $Margin/Content/HandRow/YouHandPanel
@onready var _instr_label: Label = $Margin/Content/HandRow/InstrPanel/InstrLabel
@onready var _opp_hand: MatchHandPanel = $Margin/Content/HandRow/OppHandPanel
@onready var _rules_button: Button = $Margin/Content/Controls/RulesButton

var _state: SolahSeediGameState
var _history: Array[String] = []
var _notation_history: Array[String] = []
## The route built so far: empty, [origin], or origin + every chosen
## landing. The board draws it; the engine only ever sees finished moves.
var _path: Array[int] = []
var _last_notation := ""

## The human plays red (first move); the AI plays green in vs-AI mode.
var _ai_mode := true
var _difficulty: int = SolahSeediAI.Difficulty.MEDIUM
var _ai: SolahSeediAI = null
var _ai_game_seed := 0

## Online mode.
var _online_mode := false
var _submitting := false
var _announced_match_id := ""
## Entry-flow hand-off: matchmaking / accepted challenge already seated us.
var _entry_flow := false
## Phase 12: capture-count baseline for the equipped capture effect.
var _fx_seen_captures := -1

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
	_play_button.pressed.connect(_on_play_pressed)
	_vs_ai_button.pressed.connect(func() -> void: _set_ai_mode(true))
	_hot_seat_button.pressed.connect(func() -> void: _set_ai_mode(false))
	_online_button.pressed.connect(_set_online_mode)
	_new_match_button.pressed.connect(_on_new_match_pressed)
	_join_button.pressed.connect(_on_join_pressed)
	_resign_button.pressed.connect(_on_resign_pressed)
	_rematch_button.pressed.connect(_on_rematch_pressed)
	_easy_button.pressed.connect(
			func() -> void: _set_difficulty(SolahSeediAI.Difficulty.EASY))
	_medium_button.pressed.connect(
			func() -> void: _set_difficulty(SolahSeediAI.Difficulty.MEDIUM))
	_hard_button.pressed.connect(
			func() -> void: _set_difficulty(SolahSeediAI.Difficulty.HARD))
	for button in [_vs_ai_button, _hot_seat_button, _easy_button,
			_medium_button, _hard_button]:
		button.toggled.connect(_on_mode_toggled)
	_you_card.setup(false)
	_opp_card.setup(true)
	_you_hand.setup(false, SolahSeediBoard.RED_DISC)
	_opp_hand.setup(true, SolahSeediBoard.GREEN_DISC)
	_rules_button.pressed.connect(_on_rules_pressed)
	App.online.connection_changed.connect(_on_online_connection)
	App.online.state_applied.connect(_on_online_state)
	App.online.match_changed.connect(_on_online_match_changed)
	App.online.match_completed.connect(_on_online_completed)
	if App.online.consume_auto_online():
		_entry_flow = true
		if _mode_row != null:
			_mode_row.visible = false
		if _online_row != null:
			_online_row.visible = false
		_set_online_mode()
	App.cosmetics.apply_board_skin(_board,
			App.content.board_skin("solah-seedi"))
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
		push_error("SolahSeedi: AI search produced no move")
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
	if _ai_mode and _state.side_to_move == SolahSeediGameState.Side.GREEN:
		return  # the AI owns the green turn
	_handle_tap(point)


## One tap on the chart: extend the route, step back inside it, start a
## new route on a friendly soldier, or clear it.
func _handle_tap(point: int) -> void:
	if _next_points().has(point):
		_path.append(point)
		if _pending_move() != null and _next_points().is_empty():
			_play_pending()  # nothing left to choose: play the route
		else:
			_refresh()
		return
	var existing := _path.find(point)
	if existing >= 0 and existing < _path.size() - 1:
		_path.resize(existing + 1)  # tap an earlier hop to step back
		_refresh()
		return
	if _state.cell(point) == _own_cell():
		if _path == [point]:
			_path = []  # tap the same soldier again to deselect
		else:
			_path = [point]
		_refresh()
		return
	if not _path.is_empty():
		_board.flash_invalid(point)
		_path = []
		_refresh()


func _on_play_pressed() -> void:
	_play_pending()


func _on_undo_pressed() -> void:
	if _online_mode or _history.is_empty():
		return
	_cancel_ai()
	_pop_undo()
	if _ai_mode:
		# Rewind the whole exchange so the human controls red again.
		while not _history.is_empty() \
				and _state.side_to_move != SolahSeediGameState.Side.RED:
			_pop_undo()
	_path = []
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
	_state = SolahSeediGameState.initial()
	_history.clear()
	_notation_history.clear()
	_last_notation = ""
	_path = []
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
	_path = []
	App.save_local_setting(SETTINGS_SECTION, "opponent",
			"ai" if _ai_mode else "hot_seat")
	_refresh()


func _set_difficulty(level: int) -> void:
	if _difficulty == level:
		_refresh()
		return
	_cancel_ai()
	_difficulty = level
	_path = []
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
	if _state.side_to_move != SolahSeediGameState.Side.GREEN:
		return
	var ai := SolahSeediAI.new()
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
	_path = []
	_announced_match_id = ""
	# One shared OnlineMatchService, pointed at this game's key.
	App.online.set_game_key(OnlineMatchService.SOLAH_SEEDI_KEY)
	_online_bootstrap()
	_refresh()


## Leaving online mode: drop the socket (the server applies its
## disconnect grace) and restore the offline position, which online
## play never wrote.
func _leave_online() -> void:
	App.online.leave()
	_online_mode = false
	_submitting = false
	_path = []
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
	# Entry-flow hand-off (matchmaking / accepted challenge) supplies the
	# exact match id; otherwise scan for any resumable match of this game.
	var resume_id := App.online.take_auto_match_id()
	if resume_id.is_empty():
		var found: Dictionary = await App.online.find_resumable_match()
		if not _online_mode:
			return
		resume_id = str(found.get("match_id", ""))
	if not resume_id.is_empty() and _online_mode:
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


func _submit_online(move: SolahSeediMove) -> void:
	if _submitting:
		return
	_submitting = true
	_path = []
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
		var restored := SolahSeediGameState.deserialize(payload)
		if restored == null:
			push_error("SolahSeedi: server state failed to deserialize")
		else:
			_state = restored
			_last_notation = App.online.last_notation
			_path = []
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
			_play_victory_fx()
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


# --- Routes and moves ---------------------------------------------------

## The point that starts the pending route (or -1 when there is none).
func _selection() -> int:
	return _path[0] if not _path.is_empty() else -1


## Points that extend the pending route by one legal hop.
func _next_points() -> Array[int]:
	var points: Array[int] = []
	if _path.is_empty() or _state == null:
		return points
	for move in SolahSeediRules.legal_moves_from(_state, _path[0]):
		if move.path.size() <= _path.size():
			continue
		var matches := true
		for i in _path.size():
			if move.path[i] != _path[i]:
				matches = false
				break
		if matches:
			var next := int(move.path[_path.size()])
			if not points.has(next):
				points.append(next)
	return points


## The finished move the pending route describes, or null when the
## route is empty or incomplete (the validator is the referee).
func _pending_move() -> SolahSeediMove:
	if _path.size() < 2 or _state == null:
		return null
	var move := SolahSeediMove.from_path(_path)
	if not SolahSeediValidator.validate(_state, move).ok:
		return null
	return move


## Plays the finished route (server-first while online).
func _play_pending() -> void:
	var move := _pending_move()
	if move == null:
		_refresh()
		return
	if _online_mode:
		_submit_online(move)
	else:
		_submit(move)


func _submit(move: SolahSeediMove) -> void:
	var verdict := SolahSeediValidator.validate(_state, move)
	if not verdict.ok:
		App.dialog.show_error("Illegal move",
				SolahSeediValidator.error_text(verdict.issue))
		return
	_history.append(JSON.stringify(_state.serialize()))
	_notation_history.append(_last_notation)
	var next := SolahSeediRules.apply(_state, move)
	if next == null:
		# Validator and rules agreed a moment ago; never swallow this.
		push_error("SolahSeedi: engine rejected a validated move")
		_history.pop_back()
		_notation_history.pop_back()
		return
	_state = next
	_last_notation = SolahSeediRules.notation(move)
	_path = []
	_save()
	_refresh()
	if _state.is_terminal():
		_announce_result()


## The AI's move goes through the exact same validation gate as a
## human's; if it were ever illegal we log loudly and re-search.
func _submit_ai_move(move: SolahSeediMove) -> void:
	var verdict := SolahSeediValidator.validate(_state, move)
	if not verdict.ok:
		push_error("SolahSeedi: AI produced an illegal move — %s"
				% SolahSeediValidator.error_text(verdict.issue))
		_refresh()
		return
	_submit(move)


func _pop_undo() -> void:
	var payload: Variant = JSON.parse_string(_history.pop_back())
	var previous := SolahSeediGameState.deserialize(payload)
	if previous == null:
		push_error("SolahSeedi: saved undo state is corrupt — discarding")
		_history.clear()
		_notation_history.clear()
		return
	_state = previous
	_last_notation = _notation_history.pop_back() \
			if not _notation_history.is_empty() else ""


func _own_cell() -> int:
	return SolahSeediGameState.Cell.RED \
			if _state.side_to_move == SolahSeediGameState.Side.RED \
			else SolahSeediGameState.Cell.GREEN


# --- Presentation -------------------------------------------------------

func _refresh() -> void:
	_refresh_capture_fx()
	_maybe_start_ai()
	var thinking := _is_thinking()
	_status_label.text = _status_text()
	_detail_label.text = _detail_text()
	_undo_button.disabled = _history.is_empty()
	_sync_mode_controls(thinking)
	_board.configure(_state, _selection(), _target_points(), _path)
	_refresh_hud()


## Player panels, turn badge and hand trays — visual only.
func _refresh_hud() -> void:
	if _state == null:
		return
	var my_name := App.auth.get_username() if App.auth != null else "You"
	var coins := App.coins.get_balance() if App.coins != null else -1
	var opp_name := ""
	var red_on_board := _state.board.count(SolahSeediGameState.Cell.RED)
	var green_on_board := _state.board.count(SolahSeediGameState.Cell.GREEN)
	if _online_mode:
		var my_is_red := App.online.side != "green"
		opp_name = App.online.opponent_username()
		if opp_name.is_empty():
			opp_name = "Opponent"
		_turn_badge.set_turn("Your Move" if App.online.is_my_turn() else "Their Move",
				App.online.turn_seconds_left() if App.online.is_my_turn() else -1)
		_you_card.set_identity(my_name, "Red" if my_is_red else "Green", true, coins)
		_opp_card.set_identity(opp_name, "Green" if my_is_red else "Red", false)
		var my_count := red_on_board if my_is_red else green_on_board
		var opp_count := green_on_board if my_is_red else red_on_board
		_you_hand.set_counts("You · Red" if my_is_red else "You · Green", -1, my_count, 16)
		_opp_hand.set_counts(opp_name, -1, opp_count, 16)
		_instr_label.text = "Your Move" if App.online.is_my_turn() else "Waiting…"
	elif _ai_mode:
		opp_name = "Guest" + _ai_guest_suffix()
		_turn_badge.set_turn("Your Move" if _state.side_to_move == SolahSeediGameState.Side.RED
				else "Their Move")
		_you_card.set_identity(my_name, "Red", true, coins)
		_opp_card.set_identity(opp_name, "Green", false)
		_you_hand.set_counts("You · Red", -1, red_on_board, 16)
		_opp_hand.set_counts(opp_name, -1, green_on_board, 16)
		_instr_label.text = "Your Move" if _state.side_to_move == SolahSeediGameState.Side.RED else "Their Move"
	else:
		opp_name = "Player 2"
		my_name = "Player 1"
		_turn_badge.set_turn("Player %d's Move" % (1 if _state.side_to_move == SolahSeediGameState.Side.RED else 2))
		_you_card.set_identity(my_name, "Red", true)
		_opp_card.set_identity(opp_name, "Green", false)
		_you_hand.set_counts("Red · P1", -1, red_on_board, 16)
		_opp_hand.set_counts("Green · P2", -1, green_on_board, 16)
		_instr_label.text = "Player %d's Move" % (1 if _state.side_to_move == SolahSeediGameState.Side.RED else 2)


var _ai_guest := ""
func _ai_guest_suffix() -> String:
	if _ai_guest.is_empty():
		var chars := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
		_ai_guest = ""
		for i in 5:
			_ai_guest += chars[randi() % chars.length()]
	return _ai_guest


func _on_rules_pressed() -> void:
	App.dialog.show_error("Solah Seedi",
			"Two armies of sixteen soldiers face each other. A soldier "
			+ "moves one step to an adjacent empty point, or jumps over "
			+ "an enemy soldier to the empty point beyond, capturing it. "
			+ "Build multi-jump routes and play them with the Play button. "
			+ "Capture every enemy soldier to win.")


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
			_difficulty == SolahSeediAI.Difficulty.EASY)
	_medium_button.set_pressed_no_signal(
			_difficulty == SolahSeediAI.Difficulty.MEDIUM)
	_hard_button.set_pressed_no_signal(
			_difficulty == SolahSeediAI.Difficulty.HARD)
	# Offline-only controls hide online; Resign/Rematch follow the match.
	_undo_button.visible = not _online_mode
	_restart_button.visible = not _online_mode
	_online_row.visible = _online_mode and not _entry_flow
	_resign_button.visible = _online_mode and App.online.is_active()
	_rematch_button.visible = _online_mode \
			and App.online.match_status == "COMPLETED"
	# A route that is a legal move but could still continue waits here.
	var pending := _pending_move()
	_play_button.visible = pending != null and not thinking
	if pending != null:
		_play_button.text = "Play %s" % SolahSeediRules.notation(pending)
	if _online_mode:
		_hint_label.text = _online_hint_text()
		_online_label.text = _online_label_text()
	elif not _path.is_empty() and pending != null:
		_hint_label.text = "Route %s · tap a landing or play it" \
				% SolahSeediRules.notation(pending)
	elif not _path.is_empty():
		_hint_label.text = "Route %s · tap the next landing" % _route_text()
	elif _ai_mode:
		_hint_label.text = "You play red · AI: %s" \
				% DIFFICULTY_NAMES[_difficulty]
	else:
		_hint_label.text = "Hot seat · pass and play"


func _target_points() -> Array[int]:
	var points := _next_points()
	points.sort()
	return points


## The pending route as notation (unfinished, so no capture star).
func _route_text() -> String:
	var text := ""
	for i in _path.size():
		if i > 0:
			text += "-"
		text += str(_path[i])
	return text


func _status_text() -> String:
	if _state == null:
		return ""
	if _online_mode:
		return _online_status_text()
	match _state.result:
		SolahSeediGameState.Result.RED_WIN:
			return "Red wins — %s" % _win_reason(SolahSeediGameState.Result.RED_WIN)
		SolahSeediGameState.Result.GREEN_WIN:
			return "Green wins — %s" % _win_reason(SolahSeediGameState.Result.GREEN_WIN)
		SolahSeediGameState.Result.DRAW:
			return "Draw — 60 plies without a capture"
	if _ai_mode and _state.side_to_move == SolahSeediGameState.Side.GREEN \
			and _is_thinking():
		return "Green is thinking…"
	if _state.side_to_move == SolahSeediGameState.Side.RED:
		return "Red to move — step or jump"
	return "Green to move — step or jump"


## Why `result` was reached (spec §5): capture-all, breakthrough or
## the opponent having no legal move.
func _win_reason(result: int) -> String:
	var winner: int = SolahSeediGameState.Cell.RED \
			if result == SolahSeediGameState.Result.RED_WIN \
			else SolahSeediGameState.Cell.GREEN
	var loser: int = SolahSeediGameState.Cell.GREEN \
			if winner == SolahSeediGameState.Cell.RED \
			else SolahSeediGameState.Cell.RED
	if _state.count_pieces(loser) == 0:
		return "every enemy soldier captured"
	var triangle: Array = SolahSeediGameState.GREEN_TRIANGLE \
			if winner == SolahSeediGameState.Cell.RED \
			else SolahSeediGameState.RED_TRIANGLE
	for point in triangle:
		if _state.board[int(point)] == winner:
			return "the enemy triangle is breached"
	return "the enemy has no legal move"


func _detail_text() -> String:
	var parts := [
		"Red %d · Green %d" % [
			_state.count_pieces(SolahSeediGameState.Cell.RED),
			_state.count_pieces(SolahSeediGameState.Cell.GREEN),
		],
		"Move %d" % (floori(_state.ply / 2.0) + 1),
		"Quiet %d/%d" % [_state.plies_since_capture,
				SolahSeediGameState.PLIES_TO_DRAW],
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
	if online.is_my_turn():
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
	return "Online · you play the %s soldiers" % App.online.side


# --- Cosmetic effects (Phase 12) -------------------------------------------

func _refresh_capture_fx() -> void:
	var captures := (SolahSeediGameState.PIECES_PER_SIDE * 2
			- _state.count_pieces(SolahSeediGameState.Cell.RED)
			- _state.count_pieces(SolahSeediGameState.Cell.GREEN))
	if _fx_seen_captures >= 0 and captures > _fx_seen_captures:
		CosmeticFx.capture(_board, CosmeticService.capture_style(
				App.cosmetics.equipped_key("CAPTURE_ANIMATION")))
	_fx_seen_captures = captures


func _play_victory_fx() -> void:
	CosmeticFx.victory(self, CosmeticService.victory_style(
			App.cosmetics.equipped_key("VICTORY_ANIMATION")))


## The local result dialog celebrates only the human side's win;
## online wins celebrate once through _maybe_announce_completion.
func _play_victory_fx_if_won() -> void:
	if _online_mode:
		return
	var won := false
	match _state.result:
		SolahSeediGameState.Result.RED_WIN:
			won = true
		SolahSeediGameState.Result.GREEN_WIN:
			won = not _ai_mode
		_:
			won = false
	if won:
		_play_victory_fx()


func _announce_result() -> void:
	_play_victory_fx_if_won()
	if _ai_mode:
		_track_ai_result()
	match _state.result:
		SolahSeediGameState.Result.RED_WIN:
			App.dialog.show_error("Red win",
					"Red: %s." % _win_reason(SolahSeediGameState.Result.RED_WIN))
		SolahSeediGameState.Result.GREEN_WIN:
			App.dialog.show_error("Green win",
					"Green: %s." % _win_reason(SolahSeediGameState.Result.GREEN_WIN))
		SolahSeediGameState.Result.DRAW:
			App.dialog.show_error("Draw",
					"Sixty plies passed without a capture.")


## AI-mode outcome from the human's side (the human plays red).
func _track_ai_result() -> void:
	var result := "draw"
	match _state.result:
		SolahSeediGameState.Result.RED_WIN:
			result = "win"
		SolahSeediGameState.Result.GREEN_WIN:
			result = "loss"
	App.analytics.track("ai_match_completed", {"result": result},
			"solah-seedi")


# --- Persistence --------------------------------------------------------

func _save() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("SolahSeedi: cannot write %s" % SAVE_PATH)
		return
	file.store_string(JSON.stringify(_state.serialize()))
	file.close()


func _load_or_new() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
		if file != null:
			var restored := SolahSeediGameState.deserialize(
					JSON.parse_string(file.get_as_text()))
			file.close()
			if restored != null:
				_state = restored
				return
		var dir := DirAccess.open("user://")
		if dir != null:
			dir.remove("solah_seedi_save.json")
	_state = SolahSeediGameState.initial()


func _load_settings() -> void:
	_ai_mode = str(App.get_local_setting(
			SETTINGS_SECTION, "opponent", "ai")) != "hot_seat"
	var key := str(App.get_local_setting(
			SETTINGS_SECTION, "difficulty", "medium"))
	var level := DIFFICULTY_KEYS.find(key)
	_difficulty = SolahSeediAI.Difficulty.MEDIUM if level < 0 else level

extends SceneTree
## Phase 9 end-to-end: Solah Seedi online multiplayer on a live backend.
##
## Reuses the ONE OnlineMatchService / ApiClient / AuthService stack
## (Phases 3/6 infrastructure is never duplicated), pointed at the
## solah-seedi game key. Two players: A drives the real Solah Seedi
## screen; B is an independent API + auth + online pair. The server
## stays authoritative — every check verifies what the CLIENT saw.
##
## Coverage: create/join, seats (red/green), a board-tap move, turn
## flips, rejections (wrong turn, malformed, illegal, stale/future
## clientSeq), resign + results, rematch seat swap, hot-seat restore.
## Shared-protocol depths — simultaneous race, reconnect/resume and
## turn timeout — stay in the Phase 6 suite, which exercises the same
## service.
##
## Run through scripts/run_phase9_e2e.sh, which boots the HTTPS server
## with a short turn timeout and exports:
##   AATAMGT_API_URL  e.g. https://127.0.0.1:3443
##   AATAMGT_CA_CERT  path to the server's dev certificate
##
## Exit code 0 = all checks passed.

const SAVE_PATH := "user://solah_seedi_save.json"

var _checks := 0
var _failures := 0
var _started := false
var _app: Node = null
var _main: Node = null
var _screen: Control = null
var _board: Control = null
var _status: Label = null
var _online_label: Label = null
var _b_api: ApiClient = null
var _b_auth: AuthService = null
var _b_online: OnlineMatchService = null
var _completed_events: Array = []
var _match1 := ""
var _match2 := ""
var _a_id := ""
var _b_id := ""
var _save_before := ""


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run()
	return false


func _run() -> void:
	await _frame()

	_app = get_root().get_node_or_null("/root/App")
	_check(_app != null, "autoload App is registered")
	if _app == null:
		_finish()
		return
	_check(_app.online != null, "online service is wired into App")
	var base_url := OS.get_environment("AATAMGT_API_URL").strip_edges()
	_check(not base_url.is_empty(), "AATAMGT_API_URL is provided")
	_check(_app.api_client.is_configured(), "api client configured from environment")
	await _check_server_reachable()
	if _failures > 0:
		# Without a live backend nothing below can pass — bail early.
		_finish()
		return

	await _test_boot_and_login()
	if _failures > 0:
		_finish()
		return

	await _test_toggle_and_join_guard()
	await _test_create_and_join()
	await _test_first_move_via_board()
	await _test_reply_and_rejections()
	await _test_resign_results()
	await _test_rematch_swap()
	await _test_hot_seat_restore()

	_finish()


# --- Sections ----------------------------------------------------------

func _test_boot_and_login() -> void:
	# Player A: the real client session.
	var login: Dictionary = await _app.auth.guest_login()
	_check(login.ok, "player A guest login (%s)" % _msg(login))
	if not login.ok:
		return
	_a_id = _app.auth.get_player_id()
	_check(not _a_id.is_empty(), "player A has a player id")
	_check(_app.online.match_id.is_empty(), "no match before entering online mode")
	_check(not _app.online.is_connected_to_server(), "no socket before bootstrap")

	# Player B: an independent API + auth + online stack. The ApiClient
	# parents HTTPRequest nodes, so it must live inside the tree. B's
	# LOGIN must wait until the splash screen has restored A's session:
	# both AuthServices share user://session.json.
	_b_api = ApiClient.new()
	_b_api.name = "ApiClientB"
	get_root().add_child(_b_api)
	_check(_b_api.configure(_app.api_client.get_base_url(),
			_app.api_client.get_ca_cert_path()), "player B api configured")
	_b_auth = AuthService.new(_b_api)
	_b_online = OnlineMatchService.new(_b_api, _b_auth)
	get_root().add_child(_b_online)
	_app.online.match_completed.connect(func(data: Dictionary) -> void:
		_completed_events.append(data))

	# Boot the real main scene and reach the Solah Seedi screen.
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	_check(main_scene != null, "main.tscn loads")
	if main_scene == null:
		return
	_main = main_scene.instantiate()
	get_root().add_child(_main)
	var reached := await _wait_until(func() -> bool:
			return _app.navigation.current == &"main_menu", 8.0)
	_check(reached, "splash hands off to the main menu")
	_check(_app.auth.is_authenticated() and _app.auth.get_player_id() == _a_id,
			"splash restore keeps A's identity")
	_app.navigation.go(&"solah_seedi")
	await _frame()
	await _frame()
	var container: Control = _main.get_node("ScreenLayer/ScreenContainer")
	for child in container.get_children():
		if child.name == "SolahSeediScreen":
			_screen = child
	_check(_screen != null, "solah_seedi screen instantiates")
	if _screen == null:
		return
	_board = _screen.get_node_or_null("Margin/Content/Board")
	_status = _screen.get_node_or_null("Margin/Content/StatusLabel")
	_online_label = _screen.get_node_or_null(
			"Margin/Content/OnlineRow/OnlineStatusLabel")
	_check(_board != null and _status != null and _online_label != null,
			"screen exposes board, status and online label")

	# Safe to log B in now: the splash restore already ran.
	var b_login: Dictionary = await _b_auth.guest_login()
	_check(b_login.ok, "player B guest login (%s)" % _msg(b_login))
	if not b_login.ok:
		return
	_b_id = _b_auth.get_player_id()
	_check(not _b_id.is_empty(), "player B has a player id")
	_check(_a_id != _b_id, "the two players are distinct users")
	_check(_app.auth.get_player_id() == _a_id,
			"B's login does not displace A's session")

	_save_before = _read(SAVE_PATH)


func _test_toggle_and_join_guard() -> void:
	var online_row: Control = _screen.get_node_or_null("Margin/Content/OnlineRow")
	var online_btn: Button = _screen.get_node_or_null(
			"Margin/Content/ModeRow/OnlineButton")
	var resign_btn: Button = _screen.get_node_or_null(
			"Margin/Content/Controls/ResignButton")
	var rematch_btn: Button = _screen.get_node_or_null(
			"Margin/Content/Controls/RematchButton")
	_check(online_row != null and online_btn != null and resign_btn != null
			and rematch_btn != null, "online controls exist")
	_check(not online_row.visible, "online panel hidden before online mode")
	_check(not resign_btn.visible and not rematch_btn.visible,
			"resign/rematch hidden outside online mode")

	online_btn.pressed.emit()
	await _frame()
	await _frame()
	_check(online_row.visible, "online panel appears in online mode")
	_check(_app.online.game_key == OnlineMatchService.SOLAH_SEEDI_KEY,
			"the shared session service points at the solah-seedi key")
	_check(not resign_btn.visible and not rematch_btn.visible,
			"resign/rematch still hidden without a match")
	var connected := await _wait_until(func() -> bool:
			return _app.online.connected, 8.0)
	_check(connected, "bootstrap connects the realtime socket")

	# Joining with an empty code must not touch the network.
	var join_btn: Button = _screen.get_node_or_null(
			"Margin/Content/OnlineRow/OnlineActions/JoinButton")
	var field: LineEdit = _screen.get_node_or_null(
			"Margin/Content/OnlineRow/OnlineActions/MatchIdField")
	_check(join_btn != null and field != null, "join button and code field exist")
	field.text = ""
	join_btn.pressed.emit()
	await _frame()
	await _frame()
	var error_dialog: Control = _main.get_node_or_null(
			"DialogLayer/DialogRoot/ErrorDialog")
	_check(error_dialog != null and error_dialog.visible,
			"empty match code shows an error dialog")
	if error_dialog != null:
		error_dialog.call("close")


func _test_create_and_join() -> void:
	var new_btn: Button = _screen.get_node_or_null(
			"Margin/Content/OnlineRow/OnlineActions/NewMatchButton")
	var field: LineEdit = _screen.get_node_or_null(
			"Margin/Content/OnlineRow/OnlineActions/MatchIdField")
	_check(new_btn != null, "new match button exists")
	if new_btn == null:
		return

	new_btn.pressed.emit()
	var created := await _wait_until(func() -> bool:
			return not _app.online.match_id.is_empty(), 8.0)
	_check(created, "creating a match yields a server match id")
	if not created:
		return
	_match1 = _app.online.match_id
	_check(_app.online.match_status == "PENDING",
			"creator starts PENDING (got %s)" % _app.online.match_status)
	# Seat and side land asynchronously when the creator's subscribe
	# completes; wait for them rather than sampling one frame after the
	# create response (which only worked when the backend was local).
	var seated := await _wait_until(func() -> bool:
			return _app.online.seat == 0 and _app.online.side == "red", 8.0)
	_check(seated, "creator is seated first as red (seat %d, %s)"
			% [_app.online.seat, _app.online.side])
	var subscribed := await _wait_until(func() -> bool:
			return _app.online.seat == 0, 8.0)
	_check(subscribed, "creator subscribed and holds seat 0")
	_check(field.text == _match1, "match code field shows the server id")
	_check(_online_label.text.contains(_match1),
			"online label shows the match code (got: %s)" % _online_label.text)
	_check(_status.text.contains("Waiting for an opponent"),
			"status asks the creator to wait (got: %s)" % _status.text)

	# Player B joins through REST and subscribes.
	var join: Dictionary = await _b_online.join_match(_match1)
	_check(join.ok, "player B joins the match (%s)" % _msg(join))
	if not join.ok:
		return
	_check(str(join.get("status", "")) == "ACTIVE",
			"the join activates the match (got %s)" % str(join.get("status")))
	var b_conn: Dictionary = await _b_online.connect_service()
	_check(b_conn.ok, "player B connects the realtime socket (%s)" % _msg(b_conn))
	var b_sub: Dictionary = await _b_online.subscribe_match(_match1)
	_check(b_sub.ok, "player B subscribes (%s)" % _msg(b_sub))
	_check(_b_online.seat == 1 and _b_online.side == "green",
			"joiner is seated second as green (seat %d, %s)"
			% [_b_online.seat, _b_online.side])

	var active := await _wait_until(func() -> bool:
			return _app.online.is_active(), 5.0)
	_check(active, "match activates for player A after the join")
	_check(_app.online.match_status == "ACTIVE",
			"A sees status ACTIVE (got %s)" % _app.online.match_status)
	_check(_app.online.seat == 0 and _app.online.side == "red",
			"A keeps seat 0 / red through activation")
	_check(_app.online.is_my_turn(), "red (A) moves first")
	_check(_app.online.turn_seconds_left() > 0, "turn deadline is armed")
	var presence_seen := await _wait_until(func() -> bool:
			return _presence_is(_app.online, _b_id, true), 5.0)
	_check(presence_seen, "A receives B's presence as connected")
	_check(_online_label.text.contains("your move"),
			"online label reports A's turn (got: %s)" % _online_label.text)
	_check(_status.text.contains("Your move"),
			"status reports A's turn (got: %s)" % _status.text)


func _test_first_move_via_board() -> void:
	# A real two-tap route through the board view: the opening step
	# 11-16 completes the route, so it submits immediately.
	_board.emit_signal("point_activated", 11)
	await _frame()
	_check(_board.selection == 11, "first tap selects the red soldier")
	_board.emit_signal("point_activated", 16)
	var accepted := await _wait_until(func() -> bool:
			return _app.online.move_count >= 1, 5.0)
	_check(accepted, "the server accepts A's opening step")
	await _frame()
	await _frame()
	_check(_app.online.state_dict.get("side_to_move", "") == "green",
			"server flips the turn to green")
	_check(_status.text.contains("Opponent to move"),
			"status follows the server turn (got: %s)" % _status.text)
	_check(not _app.online.is_my_turn(), "A no longer owns the turn")
	_check(_board.selection == -1, "the route clears after the server sync")
	var detail: Label = _screen.get_node_or_null("Margin/Content/DetailLabel")
	_check(detail != null and detail.text.contains("You: red"),
			"detail label shows A's side")

	# A tap on the opponent's turn must not send anything.
	var before: int = _app.online.move_count
	_board.emit_signal("point_activated", 16)
	await _frame()
	await _frame()
	await create_timer(0.3).timeout
	_check(_app.online.move_count == before,
			"advisory UI blocks a tap on the opponent's turn")


func _test_reply_and_rejections() -> void:
	# B moves legally: it is green's turn.
	var b_fresh := await _wait_until(func() -> bool:
			return _b_online.state_dict.get("side_to_move", "") == "green", 5.0)
	_check(b_fresh, "B receives A's first move")
	if not b_fresh:
		return
	var b_move := _first_legal(_b_online)
	_check(not b_move.is_empty(), "B computes a legal green move")
	if b_move.is_empty():
		return
	var b_ack: Dictionary = await _b_online.submit_move(b_move)
	_check(b_ack.ok, "server accepts B's green move (%s)" % _msg(b_ack))
	var b_turn := await _wait_until(func() -> bool:
			return _b_online.state_dict.get("side_to_move", "") == "red", 5.0)
	_check(b_turn, "server flips the turn back to red")
	var a_turn := await _wait_until(func() -> bool:
			return _app.online.is_my_turn(), 5.0)
	_check(a_turn, "A receives the turn again")
	await _frame()
	await _frame()
	_check(_status.text.contains("Your move"),
			"screen follows the turn back to A (got: %s)" % _status.text)

	# Server-side wrong turn: B tries while it is A's turn.
	var wrong: Dictionary = await _b_online.submit_move(_first_legal(_b_online))
	_check(not wrong.ok and str(wrong.get("error", "")).contains("Not your turn"),
			"server rejects B's move out of turn (%s)" % _msg(wrong))

	var count_before: int = _app.online.move_count

	# Malformed payload: no path at all.
	var malformed: Dictionary = await _app.online.submit_raw({"kind": 9},
			count_before + 1)
	_check(not malformed.ok and str(malformed.get("error", "")).contains("Malformed"),
			"server rejects a malformed payload (%s)" % _msg(malformed))

	# Illegal move: origin 11 is empty after A's opening step.
	var illegal: Dictionary = await _app.online.submit_raw({"path": [11, 12]},
			count_before + 1)
	_check(not illegal.ok and not str(illegal.get("error", "")).contains(
			"Not your turn") and not str(illegal.get("error", "")).contains(
			"Out of order"),
			"server rejects the illegal step (%s)" % _msg(illegal))

	# Stale and future clientSeq are refused without advancing the game.
	var payload := _first_legal(_app.online)
	_check(not payload.is_empty(), "A computes a legal red move")
	var stale: Dictionary = await _app.online.submit_raw(payload, count_before)
	_check(not stale.ok and str(stale.get("error", "")).contains("Out of order"),
			"server rejects a stale clientSeq (%s)" % _msg(stale))
	var future: Dictionary = await _app.online.submit_raw(payload, count_before + 3)
	_check(not future.ok and str(future.get("error", "")).contains("Out of order"),
			"server rejects a future clientSeq (%s)" % _msg(future))
	_check(_app.online.move_count == count_before,
			"no rejected move advanced the sequence")


func _test_resign_results() -> void:
	var resign_btn: Button = _screen.get_node_or_null(
			"Margin/Content/Controls/ResignButton")
	var rematch_btn: Button = _screen.get_node_or_null(
			"Margin/Content/Controls/RematchButton")
	_check(resign_btn != null and resign_btn.visible,
			"resign button appears during the live match")
	if resign_btn == null:
		return

	resign_btn.pressed.emit()
	await _frame()
	await _frame()
	var confirm_dialog: Control = _main.get_node_or_null(
			"DialogLayer/DialogRoot/ConfirmDialog")
	_check(confirm_dialog != null and confirm_dialog.visible,
			"resign asks for confirmation")
	if confirm_dialog == null:
		return
	confirm_dialog.call("resolve", true)
	var done := await _wait_until(func() -> bool:
			return _app.online.match_status == "COMPLETED", 5.0)
	_check(done, "server completes the match on resign")

	var completed: Dictionary = _app.online.completion
	_check(str(completed.get("reason", "")) == "RESIGN",
			"completion reason is RESIGN (got %s)" % str(completed.get("reason")))
	_check(int(completed.get("winnerSeat", -1)) == 1,
			"winner seat is the opponent's (got %s)" % str(completed.get("winnerSeat")))
	var results: Dictionary = completed.get("results", {})
	_check(str(results.get(_a_id, "")) == "LOSS", "server records A's LOSS")
	_check(str(results.get(_b_id, "")) == "WIN", "server records B's WIN")
	var match1_events := 0
	for event in _completed_events:
		if str((event as Dictionary).get("matchId", "")) == _match1:
			match1_events += 1
	_check(match1_events == 1,
			"match completion announced exactly once (got %d)" % match1_events)
	await _frame()
	await _frame()
	_check(_status.text.contains("Match complete"),
			"status reports the finished match (got: %s)" % _status.text)
	var error_dialog: Control = _main.get_node_or_null(
			"DialogLayer/DialogRoot/ErrorDialog")
	_check(error_dialog != null and error_dialog.visible,
			"server result opens the result dialog")
	if error_dialog != null:
		error_dialog.call("close")
	await _frame()
	_check(rematch_btn != null and rematch_btn.visible,
			"rematch button appears after completion")
	_check(not resign_btn.visible, "resign button disappears after completion")


func _test_rematch_swap() -> void:
	var rematch_btn: Button = _screen.get_node_or_null(
			"Margin/Content/Controls/RematchButton")
	if rematch_btn == null:
		return
	rematch_btn.pressed.emit()
	var switched := await _wait_until(func() -> bool:
			return not _app.online.match_id.is_empty() and _app.online.match_id != _match1, 8.0)
	_check(switched, "rematch creates a fresh server match")
	if not switched:
		return
	_match2 = _app.online.match_id
	_check(_match1 != _match2, "the rematch match id differs")
	var active := await _wait_until(func() -> bool:
			return _app.online.is_active(), 5.0)
	_check(active, "rematch match is ACTIVE")
	_check(_app.online.seat == 1 and _app.online.side == "green",
			"seats swap: A plays green (seat %d, %s)"
			% [_app.online.seat, _app.online.side])
	var b_swapped := await _wait_until(func() -> bool:
			return _b_in_new_seat(), 8.0)
	_check(b_swapped, "B follows the rematch into seat 0 / red (seat %d, %s)"
			% [_b_online.seat, _b_online.side])
	_check(_app.online.completion.is_empty(),
			"the new match starts with no completion")
	_check(not _app.online.is_my_turn(),
			"the swapped seats give B (red) the first move")

	# The old, completed match refuses further play.
	var old_move: Dictionary = await _app.online.submit_raw(
			_first_legal(_app.online), 1, _match1)
	_check(not old_move.ok and str(old_move.get("error", "")).contains("not active"),
			"the old match refuses moves (%s)" % _msg(old_move))
	_check(_app.online.match_id == _match2, "the rejection does not switch matches")


func _test_hot_seat_restore() -> void:
	var hot_seat_btn: Button = _screen.get_node_or_null(
			"Margin/Content/ModeRow/HotSeatButton")
	var online_row: Control = _screen.get_node_or_null("Margin/Content/OnlineRow")
	var undo_btn: Button = _screen.get_node_or_null(
			"Margin/Content/Controls/UndoButton")
	_check(hot_seat_btn != null, "hot seat toggle exists")
	if hot_seat_btn == null:
		return
	hot_seat_btn.pressed.emit()
	await _frame()
	await _frame()
	await _frame()
	_check(not _app.online.is_connected_to_server(),
			"leaving online mode closes the socket")
	_check(_app.online.match_id.is_empty(), "leaving online mode forgets the match")
	_check(online_row != null and not online_row.visible,
			"online panel hides again")
	_check(undo_btn != null and undo_btn.visible, "offline controls return")
	_check(_status.text.begins_with("Red to move"),
			"fresh offline game restored (got: %s)" % _status.text)
	_check(_read(SAVE_PATH) == _save_before,
			"the offline save is untouched after online play")
	if _b_online != null:
		_b_online.leave()
		_b_online.queue_free()
	if _b_api != null:
		_b_api.queue_free()
	await _frame()


# --- Helpers -----------------------------------------------------------

func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		printerr("FAIL: ", label)


func _check_server_reachable() -> void:
	var res: Dictionary = await _app.api_client.request_json(HTTPClient.METHOD_GET,
			"/profiles/me")
	var transport_failure: bool = (res.error_kind == ApiClient.ErrorKind.NETWORK
			or res.error_kind == ApiClient.ErrorKind.SERVER_UNAVAILABLE)
	_check(not transport_failure, "backend reachable over HTTPS (%s)" % _msg(res))
	_check(_app.network.get_status() == NetworkService.Status.CONNECTED,
			"network reports online after the reachability call")


## The first legal Solah Seedi move of the side to move, as the server
## would see it: computed with the shared client rules engine from the
## service's authoritative state payload.
func _first_legal(service: OnlineMatchService) -> Dictionary:
	var state := SolahSeediGameState.deserialize(service.state_dict)
	if state == null:
		return {}
	var moves := SolahSeediRules.legal_moves(state)
	if moves.is_empty():
		return {}
	return moves[0].to_dict()


func _presence_is(service: OnlineMatchService, user_id: String,
		wanted: bool) -> bool:
	return service.presence.has(user_id) \
			and bool(service.presence[user_id]) == wanted


func _b_in_new_seat() -> bool:
	return _b_online.match_id == _match2 and _b_online.seat == 0 \
			and _b_online.side == "red"


func _msg(result: Dictionary) -> String:
	if result.get("ok", false):
		return "ok"
	return str(result.get("error", result.get("message", "failed")))


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text


func _wait_until(predicate: Callable, timeout_sec: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await create_timer(0.1).timeout
	return predicate.call()


func _frame() -> void:
	await process_frame


func _finish() -> void:
	print("PHASE9 E2E: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)

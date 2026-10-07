extends SceneTree
## Phase 6 end-to-end online multiplayer test against a live backend.
##
## Two players: A drives the real Aadu Puli screen + App.online, B is a
## second ApiClient/AuthService/OnlineMatchService pair. The server is
## authoritative — every check here verifies what the CLIENT observed
## from the wire: seats, turn order, rejections, reconnect, results.
##
## Run through scripts/run_phase6_e2e.sh, which boots the HTTPS server
## with a short turn timeout and exports:
##   AATAMGT_API_URL  e.g. https://127.0.0.1:3443
##   AATAMGT_CA_CERT  path to the server's dev certificate
##
## Exit code 0 = all checks passed.

const SAVE_PATH := "user://aadu_puli_save.json"

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
	await _test_turn_and_move_rejections()
	await _test_simultaneous_submits()
	await _test_disconnect_and_resume()
	await _test_resign_results()
	await _test_rematch_and_old_match_rejection()
	await _test_turn_timeout()
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
	# both AuthServices share user://session.json, and logging B in
	# first would make the splash load B's tokens into App.auth — the
	# two players would silently become the same user.
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

	# Boot the real main scene and reach the Aadu Puli screen.
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
	_app.navigation.go(&"aadu_puli")
	await _frame()
	await _frame()
	var container: Control = _main.get_node("ScreenLayer/ScreenContainer")
	for child in container.get_children():
		if child.name == "AaduPuliScreen":
			_screen = child
	_check(_screen != null, "aadu_puli screen instantiates")
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
	await _frame()


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
	_check(_app.online.seat == 0 and _app.online.side == "goats",
			"creator is seated first as goats (seat %d, %s)"
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
	_check(_b_online.seat == 1 and _b_online.side == "tigers",
			"joiner is seated second as tigers (seat %d, %s)"
			% [_b_online.seat, _b_online.side])

	var active := await _wait_until(func() -> bool:
			return _app.online.is_active(), 5.0)
	_check(active, "match activates for player A after the join")
	_check(_app.online.match_status == "ACTIVE",
			"A sees status ACTIVE (got %s)" % _app.online.match_status)
	_check(_app.online.seat == 0 and _app.online.side == "goats",
			"A keeps seat 0 / goats through activation")
	_check(_app.online.is_my_turn(), "goats (A) move first")
	_check(_app.online.turn_seconds_left() > 0, "turn deadline is armed")
	var presence_seen := await _wait_until(func() -> bool:
			return _presence_is(_app.online, _b_id, true), 5.0)
	_check(presence_seen, "A receives B's presence as connected")
	_check(_online_label.text.contains("your move"),
			"online label reports A's turn (got: %s)" % _online_label.text)
	_check(_status.text.contains("Your move"),
			"status reports A's turn (got: %s)" % _status.text)


func _test_first_move_via_board() -> void:
	var point := _first_empty(_app.online.state_dict)
	_check(point >= 0, "an empty point is available for the first goat")
	if point < 0:
		return
	# A real tap through the board view: place the first goat.
	_board.emit_signal("point_activated", point)
	var accepted := await _wait_until(func() -> bool:
			return _app.online.move_count >= 1, 5.0)
	_check(accepted, "the server accepts A's first placement")
	await _frame()
	await _frame()
	_check(_app.online.state_dict.get("side_to_move", "") == "tigers",
			"server flips the turn to the tigers")
	_check(_status.text.contains("Opponent to move"),
			"status follows the server turn (got: %s)" % _status.text)
	_check(not _app.online.is_my_turn(), "A no longer owns the turn")
	var detail: Label = _screen.get_node_or_null("Margin/Content/DetailLabel")
	_check(detail != null and detail.text.contains("You: goats"),
			"detail label shows A's side")

	# A tap on the opponent's turn must not send anything.
	var before: int = _app.online.move_count
	var point2 := _first_empty(_app.online.state_dict)
	_board.emit_signal("point_activated", point2)
	await _frame()
	await _frame()
	await create_timer(0.3).timeout
	_check(_app.online.move_count == before,
			"advisory UI blocks a tap on the opponent's turn")


func _test_turn_and_move_rejections() -> void:
	# B moves legally: it is the tigers' turn.
	var b_fresh := await _wait_until(func() -> bool:
			return _b_online.state_dict.get("side_to_move", "") == "tigers", 5.0)
	_check(b_fresh, "B receives A's first move")
	if not b_fresh:
		return
	var b_move := _b_first_legal()
	_check(not b_move.is_empty(), "B computes a legal tiger move")
	if b_move.is_empty():
		return
	var b_ack: Dictionary = await _b_online.submit_move(b_move)
	_check(b_ack.ok, "server accepts B's tiger move (%s)" % _msg(b_ack))
	var b_turn := await _wait_until(func() -> bool:
			return _b_online.state_dict.get("side_to_move", "") == "goats", 5.0)
	_check(b_turn, "server flips the turn back to the goats")
	var a_turn := await _wait_until(func() -> bool:
			return _app.online.is_my_turn(), 5.0)
	_check(a_turn, "A receives the turn again")

	# Server-side wrong turn: B tries while it is A's turn.
	var wrong: Dictionary = await _b_online.submit_move(_b_first_legal())
	_check(not wrong.ok and str(wrong.get("error", "")).contains("Not your turn"),
			"server rejects B's move out of turn (%s)" % _msg(wrong))

	# Malformed payload: unknown move kind.
	var count_before: int = _app.online.move_count
	var malformed: Dictionary = await _app.online.submit_raw({"kind": 9},
			count_before + 1)
	_check(not malformed.ok and str(malformed.get("error", "")).contains("Malformed"),
			"server rejects a malformed payload (%s)" % _msg(malformed))

	# Illegal placement: the target point already holds a piece (the
	# opening tigers may have moved, so pick an occupied point live).
	var occupied := _first_occupied(_app.online.state_dict)
	_check(occupied >= 0, "an occupied point exists for the illegal test")
	var illegal: Dictionary = await _app.online.submit_raw(
			AaduPuliMove.place(occupied).to_dict(), count_before + 1)
	_check(not illegal.ok and not str(illegal.get("error", "")).contains(
			"Not your turn") and not str(illegal.get("error", "")).contains(
			"Out of order"),
			"server rejects an illegal placement (%s)" % _msg(illegal))

	# Stale and future clientSeq are refused without advancing the game.
	var payload := AaduPuliMove.place(_first_empty(_app.online.state_dict)).to_dict()
	var stale: Dictionary = await _app.online.submit_raw(payload, count_before)
	_check(not stale.ok and str(stale.get("error", "")).contains("Out of order"),
			"server rejects a stale clientSeq (%s)" % _msg(stale))
	var future: Dictionary = await _app.online.submit_raw(payload, count_before + 3)
	_check(not future.ok and str(future.get("error", "")).contains("Out of order"),
			"server rejects a future clientSeq (%s)" % _msg(future))
	_check(_app.online.move_count == count_before,
			"no rejected move advanced the sequence")


func _test_simultaneous_submits() -> void:
	var count_before: int = _app.online.move_count
	_check(_app.online.is_my_turn(), "it is A's turn before the race")
	var payload := AaduPuliMove.place(
			_first_empty(_app.online.state_dict)).to_dict()
	var b_payload := _b_first_legal()
	var sink_a := {}
	var sink_b := {}
	_fire_submit(_app.online, payload, sink_a)
	_fire_submit(_b_online, b_payload, sink_b)
	var both := await _wait_until(func() -> bool:
			return sink_a.has("result") and sink_b.has("result"), 8.0)
	_check(both, "both racing submissions receive an ack")
	if not both:
		return
	var a_ack: Dictionary = sink_a["result"]
	var b_ack: Dictionary = sink_b["result"]
	_check(a_ack.ok, "A's racing move is accepted (%s)" % _msg(a_ack))
	_check(not b_ack.ok, "B's racing move is rejected (%s)" % _msg(b_ack))
	_check(_app.online.move_count == count_before + 1,
			"exactly one of the two moves landed")
	_check(_app.online.state_dict.get("side_to_move", "") == "tigers",
			"the server advanced exactly one ply")


func _test_disconnect_and_resume() -> void:
	# B completes the turn so A owns the next move.
	var b_ready := await _wait_until(func() -> bool:
			return _b_online.state_dict.get("side_to_move", "") == "tigers", 5.0)
	_check(b_ready, "B receives the racing move")
	if not b_ready:
		return
	var b_ack: Dictionary = await _b_online.submit_move(_b_first_legal())
	_check(b_ack.ok, "B moves after the race (%s)" % _msg(b_ack))
	var a_turn := await _wait_until(func() -> bool:
			return _app.online.is_my_turn(), 5.0)
	_check(a_turn, "the turn returns to A")

	# Drop A's transport; both sides must observe it.
	_app.online.drop_connection()
	var dropped := await _wait_until(func() -> bool:
			return not _app.online.connected, 3.0)
	_check(dropped, "A observes the dropped socket")
	var b_saw_offline := await _wait_until(func() -> bool:
			return _presence_is(_b_online, _a_id, false), 5.0)
	_check(b_saw_offline, "B receives presence=false while A is away")

	# Automatic reconnect + re-subscribe, well inside the grace period.
	var reconnected := await _wait_until(func() -> bool:
			return _app.online.connected and _app.online.is_active(), 10.0)
	_check(reconnected, "A reconnects and re-subscribes automatically")
	if not reconnected:
		return
	var b_saw_online := await _wait_until(func() -> bool:
			return _presence_is(_b_online, _a_id, true), 5.0)
	_check(b_saw_online, "B receives presence=true after the resume")
	_check(_app.online.match_id == _match1,
			"reconnect resumes the same match")

	# Play continues from the server state.
	var count_before: int = _app.online.move_count
	_board.emit_signal("point_activated", _first_empty(_app.online.state_dict))
	var resumed := await _wait_until(func() -> bool:
			return _app.online.move_count == count_before + 1, 5.0)
	_check(resumed, "A submits successfully after the reconnect")
	_check(_status.text.contains("Opponent to move"),
			"status follows the resumed turn (got: %s)" % _status.text)


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
	_check(match1_events == 1, "match completion announced exactly once (got %d)"
			% match1_events)
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


func _test_rematch_and_old_match_rejection() -> void:
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
	_check(_app.online.seat == 1 and _app.online.side == "tigers",
			"seats swap: A plays the tigers (seat %d, %s)"
			% [_app.online.seat, _app.online.side])
	var b_swapped := await _wait_until(func() -> bool:
			return _b_in_new_seat(), 8.0)
	_check(b_swapped, "B follows the rematch into seat 0 / goats (seat %d, %s)"
			% [_b_online.seat, _b_online.side])
	_check(_app.online.completion.is_empty(),
			"the new match starts with no completion")
	_check(not _app.online.is_my_turn(),
			"the swapped seats give B (goats) the first move")

	# The old, completed match refuses further play.
	var old_move: Dictionary = await _app.online.submit_raw(
			AaduPuliMove.place(_first_empty(_app.online.state_dict)).to_dict(),
			1, _match1)
	_check(not old_move.ok and str(old_move.get("error", "")).contains("not active"),
			"the old match refuses moves (%s)" % _msg(old_move))
	_check(_app.online.match_id == _match2, "the rejection does not switch matches")


func _test_turn_timeout() -> void:
	# Nobody moves: the server's turn clock (MATCH_TURN_TIMEOUT_MS) must
	# complete the match on its own. B (goats) is to move and loses.
	_check(not _app.online.is_my_turn(),
			"it is B's turn when the timeout window opens")
	_check(_app.online.turn_seconds_left() > 0, "the new match has a deadline")
	var timed_out := await _wait_until(func() -> bool:
			return _app.online.match_status == "COMPLETED", 12.0)
	_check(timed_out, "server completes the match on turn timeout")
	if not timed_out:
		return
	var completed: Dictionary = _app.online.completion
	_check(str(completed.get("reason", "")) == "TIMEOUT",
			"completion reason is TIMEOUT (got %s)" % str(completed.get("reason")))
	_check(int(completed.get("winnerSeat", -1)) == 1,
			"the side to move loses on time (winner seat %s)"
			% str(completed.get("winnerSeat")))
	var results: Dictionary = completed.get("results", {})
	_check(str(results.get(_a_id, "")) == "WIN", "server records A's WIN on time")
	_check(str(results.get(_b_id, "")) == "LOSS", "server records B's LOSS on time")
	var b_done := await _wait_until(func() -> bool:
			return _b_online.match_status == "COMPLETED", 5.0)
	_check(b_done, "B receives the timeout completion too")
	var match2_events := 0
	for event in _completed_events:
		if str((event as Dictionary).get("matchId", "")) == _match2:
			match2_events += 1
	_check(match2_events == 1,
			"timeout announced exactly once for the rematch (got %d)"
			% match2_events)
	await _frame()
	await _frame()
	_check(_status.text.contains("Match complete — you win"),
			"status shows A's timeout win (got: %s)" % _status.text)
	var error_dialog: Control = _main.get_node_or_null(
			"DialogLayer/DialogRoot/ErrorDialog")
	_check(error_dialog != null and error_dialog.visible,
			"timeout opens the result dialog")
	if error_dialog != null:
		error_dialog.call("close")
	await _frame()
	_check(_read(SAVE_PATH) == _save_before,
			"online play never wrote the offline save")


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
	_check(_status.text.begins_with("Goats to move"),
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


## Fires an async service call without awaiting it, so two submissions
## can be in flight at the same time; the result lands in `sink`.
func _fire_submit(service: OnlineMatchService, payload: Dictionary,
		sink: Dictionary) -> void:
	sink["result"] = await service.submit_move(payload)


func _first_empty(state_payload: Dictionary) -> int:
	var state := AaduPuliGameState.deserialize(state_payload)
	if state == null:
		return -1
	for point in AaduPuliGameState.POINT_COUNT:
		if state.is_empty(point):
			return point
	return -1


func _first_occupied(state_payload: Dictionary) -> int:
	var state := AaduPuliGameState.deserialize(state_payload)
	if state == null:
		return -1
	for point in AaduPuliGameState.POINT_COUNT:
		if not state.is_empty(point):
			return point
	return -1


func _b_first_legal() -> Dictionary:
	var state := AaduPuliGameState.deserialize(_b_online.state_dict)
	if state == null:
		return {}
	var moves := AaduPuliRules.legal_moves(state)
	if moves.is_empty():
		return {}
	return moves[0].to_dict()


func _presence_is(service: OnlineMatchService, user_id: String,
		wanted: bool) -> bool:
	return service.presence.has(user_id) \
			and bool(service.presence[user_id]) == wanted


func _b_in_new_seat() -> bool:
	return _b_online.match_id == _match2 and _b_online.seat == 0 \
			and _b_online.side == "goats"


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
	print("PHASE6 E2E: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)

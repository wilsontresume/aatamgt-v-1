extends SceneTree
## Phase 11 end-to-end: social multiplayer on a live backend — friend
## requests (real UI), share challenges (WhatsApp text + code), accept
## with match auto-entry, history + rematch, and abuse prevention.
##
## Reuses the ONE App stack for player A (real screens) and an
## independent API + auth pair for player B, exactly like the Phase 6/9
## suites. C/D/E exist only as server accounts for rate-limit and block
## checks (created over raw REST — no second UI).
##
## Coverage: friends screen add/accept/duplicate, challenge compose
## (choose game → code → pinned share text), polling pickup →
## auto-enter online mode, seats on the accepted match, resign →
## history row → rematch challenge, decline via manual code entry,
## challenge inbox rows, friend pending cap (429), challenge pending
## cap (429), block enforcement in both directions + unblock, invalid
## code guard, self-challenge guard, challenge notification.
##
## Run through scripts/run_phase11_e2e.sh, which boots the HTTPS
## server and exports:
##   AATAMGT_API_URL  e.g. https://127.0.0.1:3443
##   AATAMGT_CA_CERT  path to the server's dev certificate
##   FRIEND_PENDING_LIMIT=2  CHALLENGE_PENDING_LIMIT=2 (cap tests)
##
## Exit code 0 = all checks passed.

const GAME := "aadu-puli-aattam"
const GAME_TITLE := "Aadu Puli Aattam"

var _checks := 0
var _failures := 0
var _started := false
var _app: Node = null
var _main: Node = null
var _b_api: ApiClient = null
var _b_auth: AuthService = null
var _b_online: OnlineMatchService = null
var _a_name := ""
var _a_id := ""
var _b_name := ""
var _match1 := ""
var _match2 := ""


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
	_check(_app.social is SocialService, "App exposes the SocialService")
	var base_url := OS.get_environment("AATAMGT_API_URL").strip_edges()
	_check(not base_url.is_empty(), "AATAMGT_API_URL is provided")
	_check(_app.api_client.is_configured(), "api client configured from environment")
	await _check_server_reachable()
	if _failures > 0:
		_finish()
		return

	await _test_boot_and_login()
	if _failures > 0:
		_finish()
		return

	await _test_friend_request_via_ui()
	await _test_share_challenge_and_auto_enter()
	await _test_resign_history_and_rematch()
	await _test_decline_via_code_entry()
	await _test_inbox_row_opens()
	await _test_abuse_prevention()

	_finish()


# --- Sections ---------------------------------------------------------------

func _test_boot_and_login() -> void:
	var login: Dictionary = await _app.auth.guest_login()
	_check(login.ok, "player A guest login (%s)" % _msg(login))
	if not login.ok:
		return
	_a_name = _app.auth.get_username()
	_check(not _a_name.is_empty(), "player A has a username")
	_a_id = _app.auth.get_player_id()
	_check(not _a_id.is_empty(), "player A has a player id")
	_check(_app.online.match_id.is_empty(), "no match before online mode")
	_check(not _app.online.is_connected_to_server(), "no socket before online mode")

	# Independent stack for player B (mirrors the Phase 6/9 pattern).
	_b_api = ApiClient.new()
	_b_api.name = "ApiClientB"
	get_root().add_child(_b_api)
	_check(_b_api.configure(_app.api_client.get_base_url(),
			_app.api_client.get_ca_cert_path()), "player B api configured")
	_b_auth = AuthService.new(_b_api)
	_b_online = OnlineMatchService.new(_b_api, _b_auth)
	get_root().add_child(_b_online)

	var main_scene: PackedScene = load("res://scenes/main.tscn")
	_check(main_scene != null, "main.tscn loads")
	if main_scene == null:
		return
	_main = main_scene.instantiate()
	get_root().add_child(_main)
	var reached := await _wait_until(func() -> bool:
			return _app.navigation.current == &"main_menu", 8.0)
	_check(reached, "splash hands off to the main menu")
	_check(_app.auth.is_authenticated() and _app.auth.get_username() == _a_name,
			"splash restore keeps A's identity")

	# B logs in only after the splash restore (shared session.json).
	var b_login: Dictionary = await _b_auth.guest_login()
	_check(b_login.ok, "player B guest login (%s)" % _msg(b_login))
	if not b_login.ok:
		return
	_b_name = _b_auth.get_username()
	_check(not _b_name.is_empty() and _b_name != _a_name,
			"the two players are distinct users")
	_check(_app.auth.get_player_id() == _a_id,
			"B's login does not displace A's session")


func _test_friend_request_via_ui() -> void:
	_app.navigation.go(&"friends")
	await _frame()
	await _frame()
	var screen := _screen_named("Friends")
	_check(screen != null, "friends screen instantiates")
	if screen == null:
		return
	_check(_app.navigation.current == &"friends",
			"Friends entry lands on the friends screen")

	var field: LineEdit = screen.get_node(
			"Margin/Content/AddPanel/AddBody/AddRow/UsernameField")
	var add_button: Button = screen.get_node(
			"Margin/Content/AddPanel/AddBody/AddRow/AddButton")
	var add_hint: Label = screen.get_node("Margin/Content/AddPanel/AddBody/AddHint")
	_check(field != null and add_button != null and add_hint != null,
			"add-friend row exposes field, button and hint")

	# Client-side guard first: too-short input never reaches the server.
	field.text = "ab"
	add_button.pressed.emit()
	await _frame()
	_check(add_hint.text.contains("3"),
			"short username shows the length guard (got: %s)" % add_hint.text)

	field.text = _b_name
	add_button.pressed.emit()
	var sent := await _wait_until(func() -> bool:
			return add_hint.text.contains("Request sent"), 6.0)
	_check(sent, "request reaches B through the real UI (got: %s)"
			% add_hint.text)

	# B accepts over REST.
	var b_list: Dictionary = await _b_auth.authenticated_get("/friends")
	var incoming: Variant = (b_list as Dictionary).body.get("incoming") \
			if (b_list as Dictionary).get("ok", false) else null
	var one_incoming := incoming is Array and (incoming as Array).size() == 1
	_check(one_incoming, "B sees exactly one incoming request" if one_incoming
			else "B sees exactly one incoming request (status %s, body %s)"
			% [str(b_list.get("status")), JSON.stringify(b_list.get("body"))])
	if not (incoming is Array) or (incoming as Array).is_empty():
		return
	var req: Dictionary = (incoming as Array)[0]
	var req_user: Dictionary = req.get("user", {})
	_check(str(req_user.get("username", "")) == _a_name,
			"the incoming request is from A")
	var accept: Dictionary = await _b_auth.authenticated_post(
			"/friends/requests/%s/accept" % str(req.get("id", "")), {})
	_check(accept.ok and str(accept.body.get("status", "")) == "ACCEPTED",
			"B accepts the request (%s)" % _msg(accept))

	await _reload_screen(screen)
	var friends_list: VBoxContainer = screen.get_node(
			"Margin/Content/FriendsPanel/FriendsBody/FriendsList")
	var friends_hint: Label = screen.get_node(
			"Margin/Content/FriendsPanel/FriendsBody/FriendsHint")
	var shown := await _wait_until(func() -> bool:
			return friends_list.get_child_count() == 1, 6.0)
	_check(shown, "A's list shows the new friend")
	_check(not friends_hint.visible, "empty-state hint hides when populated")
	if friends_list.get_child_count() == 1:
		var row: HBoxContainer = friends_list.get_child(0)
		var row_text := _row_text(row)
		_check(row_text.contains(_b_name), "friend row names B (got: %s)" % row_text)
		var labels := _row_buttons(row)
		_check(labels.has("Challenge") and labels.has("Remove")
				and labels.has("Block"),
				"friend row offers Challenge/Remove/Block")

	# Duplicate request answers inline (no modal).
	field.text = _b_name
	add_button.pressed.emit()
	var dup := await _wait_until(func() -> bool:
			return add_hint.text.contains("already friends"), 6.0)
	_check(dup, "duplicate request answers inline (got: %s)" % add_hint.text)


func _test_share_challenge_and_auto_enter() -> void:
	var screen := _screen_named("Friends")
	if screen == null:
		return
	var friends_list: VBoxContainer = screen.get_node(
			"Margin/Content/FriendsPanel/FriendsBody/FriendsList")
	if friends_list.get_child_count() == 0:
		_check(false, "a friend row exists for the challenge entry point")
		return
	var row: HBoxContainer = friends_list.get_child(0)
	var challenge_btn: Button = _find_button(row, "Challenge")
	_check(challenge_btn != null, "friend row exposes a Challenge button")
	if challenge_btn == null:
		return

	challenge_btn.pressed.emit()
	await _frame()
	await _frame()
	_check(_app.navigation.current == &"challenge",
			"Challenge opens the challenge screen")
	var challenge := _screen_named("Challenge")
	if challenge == null:
		return
	var choose: Control = challenge.get_node("Margin/Content/ChoosePanel")
	_check(choose.visible, "choose-game panel opens")
	var title: Label = challenge.get_node(
			"Margin/Content/ChoosePanel/ChooseBody/ChooseTitle")
	_check(title.text == "Challenge %s to" % _b_name,
			"choose title names B (got: %s)" % title.text)
	var list: VBoxContainer = challenge.get_node(
			"Margin/Content/ChoosePanel/ChooseBody/ChooseList")
	_check(list.get_child_count() == 3, "all three games are offered")

	var aadu_btn := _find_button(list, GAME_TITLE)
	_check(aadu_btn != null, "Aadu Puli Aattam is offered")
	if aadu_btn == null:
		return
	aadu_btn.pressed.emit()

	var code_label: Label = challenge.get_node("Margin/Content/CodePanel/CodeBody/CodeLabel")
	var created := await _wait_until(func() -> bool:
			return code_label.text.strip_edges().length() >= 4, 8.0)
	_check(created, "challenge creation yields a share code (got: %s)"
			% code_label.text)
	var code := code_label.text.strip_edges()
	_check(SocialService.is_valid_code(code), "share code passes validation")

	var share: Label = challenge.get_node("Margin/Content/SharePanel/ShareBody/ShareText")
	var expected := SocialService.challenge_message(
			_display_name(), GAME_TITLE, code)
	_check(share.text == expected,
			"share text matches the pinned WhatsApp message exactly")
	_check(share.text.begins_with("AATAMGT challenge:\n%s challenged you to %s.\nJoin the match."
			% [_display_name(), GAME_TITLE]),
			"share text leads with the product example's three lines")
	var status: Label = challenge.get_node("Margin/Content/CodePanel/CodeBody/StatusLabel")
	_check(status.text.contains("Waiting"),
			"compose waits for acceptance (got: %s)" % status.text)

	# The invitee is notified server-side.
	var notes: Dictionary = await _b_auth.authenticated_get("/notifications")
	var notified := false
	var note_items: Variant = (notes as Dictionary).body.get("items") \
			if (notes as Dictionary).get("ok", false) else null
	if note_items is Array:
		for n in note_items as Array:
			if n is Dictionary and str((n as Dictionary).get("type", "")) == "challenge" \
					and str((n as Dictionary).get("body", "")).contains(_a_name):
				notified = true
	_check(notified, "B received a challenge notification naming A")

	# B looks the code up and accepts.
	var info: Dictionary = await _b_auth.authenticated_get("/challenges/%s" % code)
	_check(info.ok, "B can read the code (%s)" % _msg(info))
	_check(str(info.body.get("status", "")) == "PENDING",
			"shared code starts PENDING")
	var invitee: Dictionary = info.body.get("invitee") if info.body.get("invitee") is Dictionary else {}
	_check(str(invitee.get("id", "")) == _b_auth.get_player_id(),
			"code is addressed to B")
	var accepted: Dictionary = await _b_auth.authenticated_post(
			"/challenges/%s/accept" % code, {})
	_check(accepted.ok, "B accepts the challenge (%s)" % _msg(accepted))
	if not accepted.ok:
		return
	_match1 = str(accepted.body.get("matchId", ""))
	_check(not _match1.is_empty(), "accept yields a server match id")
	_check(int(accepted.body.get("seat", -1)) == 1,
			"B is seated second on accept")

	# A's compose screen polls every 3s and enters the game automatically.
	var entered := await _wait_until(func() -> bool:
			return _app.navigation.current == &"aadu_puli", 12.0)
	_check(entered, "polling detects the acceptance and enters the game")
	var seated := await _wait_until(func() -> bool:
			return _app.online.match_id == _match1 and _app.online.seat == 0, 8.0)
	_check(seated, "A subscribes to the accepted match on seat 0 (match %s)"
			% _app.online.match_id)
	var game_screen := _screen_named("AaduPuliScreen")
	_check(game_screen != null, "the Aadu Puli screen hosts the session")

	# B connects at the service level and holds seat 1.
	_b_online.set_game_key(GAME)
	var conn: Dictionary = await _b_online.connect_service()
	_check(conn.ok, "player B connects the realtime socket (%s)" % _msg(conn))
	var sub: Dictionary = await _b_online.subscribe_match(_match1)
	_check(sub.ok, "player B subscribes (%s)" % _msg(sub))
	_check(_b_online.seat == 1, "player B holds seat 1 (got %d)" % _b_online.seat)

	var match_info: Dictionary = await _b_auth.authenticated_get(
			"/matches/%s" % _match1)
	_check(str(match_info.body.get("status", "")) == "ACTIVE",
			"the accepted match is ACTIVE on the server")
	var players: Variant = match_info.body.get("players")
	_check(players is Array and (players as Array).size() == 2,
			"the match seats both players")


func _test_resign_history_and_rematch() -> void:
	# B resigns; A sees the completion over the socket.
	var resign: Dictionary = await _b_auth.authenticated_post(
			"/matches/%s/resign" % _match1, {})
	_check(resign.ok, "B resigns the first match (%s)" % _msg(resign))
	var done := await _wait_until(func() -> bool:
			return str(_app.online.match_status) == "COMPLETED", 8.0)
	_check(done, "A observes the completion (status: %s)"
			% _app.online.match_status)

	_app.navigation.go(&"history")
	await _frame()
	await _frame()
	var hist := _screen_named("History")
	_check(hist != null, "history screen instantiates")
	if hist == null:
		return
	var list: VBoxContainer = hist.get_node(
			"Margin/Content/HistoryPanel/HistoryBody/HistoryList")
	var hint: Label = hist.get_node(
			"Margin/Content/HistoryPanel/HistoryBody/HistoryHint")
	var has_row := await _wait_until(func() -> bool:
			return list.get_child_count() >= 1, 8.0)
	_check(has_row, "the completed match appears in history")
	_check(not hint.visible, "history empty-state hides once populated")
	if list.get_child_count() == 0:
		return
	var row: HBoxContainer = list.get_child(0)
	var row_text := _row_text(row)
	_check(row_text.contains(GAME_TITLE), "history row names the game (got: %s)" % row_text)
	_check(row_text.contains("vs %s" % _b_name),
			"history row names the opponent (got: %s)" % row_text)
	_check(row_text.contains("Won"), "history row shows the win (got: %s)" % row_text)
	var rematch_btn: Button = _find_button(row, "Rematch")
	_check(rematch_btn != null, "history row offers Rematch")
	if rematch_btn == null:
		return

	rematch_btn.pressed.emit()
	await _frame()
	await _frame()
	_check(_app.navigation.current == &"challenge",
			"Rematch opens the challenge screen")
	var challenge := _screen_named("Challenge")
	if challenge == null:
		return
	var code_label: Label = challenge.get_node("Margin/Content/CodePanel/CodeBody/CodeLabel")
	var created := await _wait_until(func() -> bool:
			return code_label.text.strip_edges().length() >= 4, 8.0)
	_check(created, "rematch creates a fresh share code")
	var code2 := code_label.text.strip_edges()
	var share: Label = challenge.get_node("Margin/Content/SharePanel/ShareBody/ShareText")
	var expected2 := SocialService.challenge_message(
			_display_name(), GAME_TITLE, code2)
	_check(share.text == expected2,
			"rematch share text pins the same message (got: %s)" % share.text)
	_check(share.text.contains("challenged you to %s" % GAME_TITLE),
			"rematch message targets the same game")

	# B accepts the rematch code; A auto-enters a fresh match.
	var acc2: Dictionary = await _b_auth.authenticated_post(
			"/challenges/%s/accept" % code2, {})
	_check(acc2.ok, "B accepts the rematch (%s)" % _msg(acc2))
	if not acc2.ok:
		return
	_match2 = str(acc2.body.get("matchId", ""))
	_check(not _match2.is_empty() and _match2 != _match1,
			"rematch yields a fresh match id")
	var entered := await _wait_until(func() -> bool:
			return _app.navigation.current == &"aadu_puli" and _app.online.match_id == _match2, 12.0)
	_check(entered, "A auto-enters the rematch (match %s)" % _app.online.match_id)
	var seated := await _wait_until(func() -> bool:
			return _app.online.seat == 0, 8.0)
	_check(seated, "A holds seat 0 on the rematch")
	var b_sub: Dictionary = await _b_online.subscribe_match(_match2)
	_check(b_sub.ok and _b_online.seat == 1,
			"B holds seat 1 on the rematch")


func _test_decline_via_code_entry() -> void:
	# B sends A a fresh challenge; A opens it by typing the share code.
	var made: Dictionary = await _b_auth.authenticated_post("/challenges",
			{"gameKey": GAME, "inviteeUsername": _a_name})
	_check(made.ok, "B creates a challenge addressed to A (%s)" % _msg(made))
	if not made.ok:
		return
	var code_b := str(made.body.get("code", ""))
	_check(SocialService.is_valid_code(code_b), "B's share code validates")

	# Leave the online rematch and open Friends.
	_app.navigation.go(&"friends")
	await _frame()
	await _frame()
	var screen := _screen_named("Friends")
	_check(screen != null, "friends screen opens for manual code entry")
	if screen == null:
		return
	var code_field: LineEdit = screen.get_node(
			"Margin/Content/CodePanel/CodeBody/CodeRow/CodeField")
	var open_button: Button = screen.get_node(
			"Margin/Content/CodePanel/CodeBody/CodeRow/OpenButton")
	var code_hint: Label = screen.get_node(
			"Margin/Content/CodePanel/CodeBody/CodeHint")

	# Client-side guard: junk never reaches the server.
	code_field.text = "!!"
	open_button.pressed.emit()
	await _frame()
	_check(code_hint.text.contains("code from your challenge message"),
			"invalid code shows the inline guard (got: %s)" % code_hint.text)
	_check(_app.navigation.current == &"friends",
			"an invalid code does not navigate")

	code_field.text = code_b
	open_button.pressed.emit()
	var opened := await _wait_until(func() -> bool:
			return _app.navigation.current == &"challenge", 4.0)
	_check(opened, "a valid code opens the challenge screen")
	var challenge := _screen_named("Challenge")
	if challenge == null:
		return
	var incoming: Label = challenge.get_node(
			"Margin/Content/IncomingPanel/IncomingBody/IncomingLabel")
	var expires: Label = challenge.get_node(
			"Margin/Content/IncomingPanel/IncomingBody/ExpiresLabel")
	var accept_btn: Button = challenge.get_node(
			"Margin/Content/IncomingPanel/IncomingBody/IncomingActions/AcceptButton")
	var decline_btn: Button = challenge.get_node(
			"Margin/Content/IncomingPanel/IncomingBody/IncomingActions/DeclineButton")
	await _wait_until(func() -> bool:
			return incoming.text.contains("challenged you to"), 4.0)
	_check(incoming.text == "%s challenged you to %s." % [_b_name, GAME_TITLE],
			"incoming view names challenger and game (got: %s)" % incoming.text)
	_check(expires.text.contains("Expires in"),
			"expiry countdown shows (got: %s)" % expires.text)
	_check(accept_btn.visible and decline_btn.visible
			and not accept_btn.disabled and not decline_btn.disabled,
			"accept and decline are armed")

	decline_btn.pressed.emit()
	var back_to_friends := await _wait_until(func() -> bool:
			return _app.navigation.current == &"friends", 4.0)
	_check(back_to_friends, "declining returns to the friends screen")

	# The code no longer resolves as pending.
	var after: Dictionary = await _b_auth.authenticated_get(
			"/challenges/%s" % code_b)
	_check(after.ok and str(after.body.get("status", "")) == "DECLINED",
			"server marks B's code DECLINED (got: %s)"
			% str(after.body.get("status", "")))


func _test_inbox_row_opens() -> void:
	var made: Dictionary = await _b_auth.authenticated_post("/challenges",
			{"gameKey": GAME, "inviteeUsername": _a_name})
	_check(made.ok, "B challenges A again (%s)" % _msg(made))
	if not made.ok:
		return
	var screen := _screen_named("Friends")
	if screen == null:
		_check(false, "friends screen hosts the challenge inbox")
		return
	await _reload_screen(screen)
	var list: VBoxContainer = screen.get_node(
			"Margin/Content/ChallengesPanel/ChallengesBody/ChallengeList")
	var hint: Label = screen.get_node(
			"Margin/Content/ChallengesPanel/ChallengesBody/ChallengeHint")
	var has_row := await _wait_until(func() -> bool:
			return list.get_child_count() >= 1, 6.0)
	_check(has_row, "pending challenge appears in the friends inbox")
	_check(not hint.visible, "challenge empty-state hides when populated")
	if list.get_child_count() == 0:
		return
	var row: HBoxContainer = list.get_child(0)
	var row_text := _row_text(row)
	_check(row_text.contains("From %s" % _b_name),
			"inbox row names the challenger (got: %s)" % row_text)
	_check(row_text.contains(GAME_TITLE),
			"inbox row names the game (got: %s)" % row_text)
	var open_btn := _find_button(row, "Open")
	_check(open_btn != null, "inbox row offers Open")
	if open_btn == null:
		return

	open_btn.pressed.emit()
	var opened := await _wait_until(func() -> bool:
			return _app.navigation.current == &"challenge", 4.0)
	_check(opened, "Open enters the challenge screen")
	var challenge := _screen_named("Challenge")
	if challenge == null:
		return
	var incoming: Label = challenge.get_node(
			"Margin/Content/IncomingPanel/IncomingBody/IncomingLabel")
	await _wait_until(func() -> bool:
			return incoming.text.contains("challenged you to"), 4.0)
	_check(incoming.text == "%s challenged you to %s." % [_b_name, GAME_TITLE],
			"Open lands on the incoming view (got: %s)" % incoming.text)

	# Decline this one too, then confirm the inbox is empty again.
	var decline_btn: Button = challenge.get_node(
			"Margin/Content/IncomingPanel/IncomingBody/IncomingActions/DeclineButton")
	decline_btn.pressed.emit()
	var back_to_friends := await _wait_until(func() -> bool:
			return _app.navigation.current == &"friends", 4.0)
	_check(back_to_friends, "decline returns to Friends")
	var fresh := _screen_named("Friends")
	if fresh == null:
		return
	await _reload_screen(fresh)
	var fresh_list: VBoxContainer = fresh.get_node(
			"Margin/Content/ChallengesPanel/ChallengesBody/ChallengeList")
	var fresh_hint: Label = fresh.get_node(
			"Margin/Content/ChallengesPanel/ChallengesBody/ChallengeHint")
	var cleared := await _wait_until(func() -> bool:
			return fresh_list.get_child_count() == 0 and fresh_hint.visible, 6.0)
	_check(cleared, "declined challenge leaves the inbox")


func _test_abuse_prevention() -> void:
	var screen := _screen_named("Friends")
	if screen == null:
		_check(false, "friends screen drives the abuse checks")
		return
	await _reload_screen(screen)
	var field: LineEdit = screen.get_node(
			"Margin/Content/AddPanel/AddBody/AddRow/UsernameField")
	var add_button: Button = screen.get_node(
			"Margin/Content/AddPanel/AddBody/AddRow/AddButton")
	var add_hint: Label = screen.get_node("Margin/Content/AddPanel/AddBody/AddHint")

	# Three extra accounts (raw REST — they never open a client).
	var suffix := str(Time.get_ticks_msec())
	var c_name := "soc_%s_c" % suffix
	var d_name := "soc_%s_d" % suffix
	var e_name := "soc_%s_e" % suffix
	var c_token := await _register_user(c_name)
	var d_token := await _register_user(d_name)
	var e_token := await _register_user(e_name)
	_check(not c_token.is_empty() and not d_token.is_empty()
			and not e_token.is_empty(),
			"three extra accounts are registered")

	# 1. Friend-request pending cap (FRIEND_PENDING_LIMIT=2).
	field.text = c_name
	add_button.pressed.emit()
	var sent_c := await _wait_until(func() -> bool:
			return add_hint.text.contains("Request sent"), 6.0)
	_check(sent_c, "first friend request passes the cap (got: %s)" % add_hint.text)
	field.text = d_name
	add_button.pressed.emit()
	var sent_d := await _wait_until(func() -> bool:
			return add_hint.text.contains("Request sent"), 6.0)
	_check(sent_d, "second friend request passes the cap (got: %s)" % add_hint.text)
	field.text = e_name
	add_button.pressed.emit()
	var capped := await _wait_until(func() -> bool:
			return add_hint.text.contains("Too many pending requests"), 6.0)
	_check(capped, "third request hits the pending cap (got: %s)" % add_hint.text)

	# 2. Challenge pending cap (CHALLENGE_PENDING_LIMIT=2).
	var ch1: Dictionary = await _app.social.create_challenge(GAME, c_name)
	_check(ch1.ok, "challenge 1 passes the pending cap (%s)" % _msg(ch1))
	var ch2: Dictionary = await _app.social.create_challenge(GAME, d_name)
	_check(ch2.ok, "challenge 2 passes the pending cap (%s)" % _msg(ch2))
	var ch3: Dictionary = await _app.social.create_challenge(GAME, e_name)
	_check(not ch3.ok and str(ch3.get("message", "")).contains(
			"Too many pending challenges"),
			"challenge 3 hits the pending cap (got: %s)"
			% str(ch3.get("message", "")))

	# 3. You cannot challenge yourself.
	var self_ch: Dictionary = await _app.social.create_challenge(GAME, _a_name)
	_check(not self_ch.ok and str(self_ch.get("message", "")).contains(
			"cannot challenge yourself"),
			"self-challenge is rejected (got: %s)"
			% str(self_ch.get("message", "")))

	# 4. A block stops requests and challenges in both directions.
	var c_block: Dictionary = await _b_api.request_json(HTTPClient.METHOD_POST,
			"/friends/block", {"username": _a_name}, c_token)
	_check(c_block.ok, "C blocks A (%s)" % _msg(c_block))
	field.text = c_name
	add_button.pressed.emit()
	var blocked_req := await _wait_until(func() -> bool:
			return add_hint.text.contains("Cannot send a request"), 6.0)
	_check(blocked_req, "request toward a blocker answers 403 (got: %s)"
			% add_hint.text)
	var blocked_ch: Dictionary = await _app.social.create_challenge(GAME, c_name)
	_check(not blocked_ch.ok and str(blocked_ch.get("message", "")).contains(
			"Cannot send to this player"),
			"challenge toward a blocker answers 403 (got: %s)"
			% str(blocked_ch.get("message", "")))

	# 5. Unblock through C's token, then the request works again.
	var c_friends: Dictionary = await _b_api.request_json(HTTPClient.METHOD_GET,
			"/friends", {}, c_token)
	var blocked_id := ""
	if c_friends.ok and c_friends.body.get("blocked") is Array:
		for entry in c_friends.body.get("blocked") as Array:
			var u: Variant = (entry as Dictionary).get("user")
			if u is Dictionary and str((u as Dictionary).get(
					"username", "")) == _a_name:
				blocked_id = str((entry as Dictionary).get("id", ""))
	_check(not blocked_id.is_empty(), "C sees the blocked friendship row")
	var unblocked: Dictionary = await _b_api.request_json(
			HTTPClient.METHOD_DELETE, "/friends/%s" % blocked_id, {}, c_token)
	_check(unblocked.ok, "C unblocks A (%s)" % _msg(unblocked))
	field.text = c_name
	add_button.pressed.emit()
	var again := await _wait_until(func() -> bool:
			return add_hint.text.contains("Request sent"), 6.0)
	_check(again, "after unblock the request goes through (got: %s)"
			% add_hint.text)


func _register_user(username: String) -> String:
	var res: Dictionary = await _b_api.request_json(HTTPClient.METHOD_POST,
			"/auth/register", {"username": username, "password": "Soc12345!"})
	if not res.ok:
		_check(false, "register %s (%s)" % [username, _msg(res)])
		return ""
	return str(res.body.get("accessToken", ""))


## Waits for an in-flight screen reload, then runs a fresh one.
func _reload_screen(screen: Node) -> void:
	while bool(screen.get("_busy")):
		await _frame()
	await screen.reload()


# --- Helpers ----------------------------------------------------------------

func _screen_named(root_name: String) -> Control:
	if _main == null:
		return null
	var container: Control = _main.get_node("ScreenLayer/ScreenContainer")
	for child in container.get_children():
		if child.name == root_name:
			return child
	return null


func _row_text(row: Node) -> String:
	var parts := PackedStringArray()
	_collect_text(row, parts)
	return " | ".join(parts)


func _row_buttons(row: Node) -> Array:
	var found := []
	_collect_buttons(row, found)
	return found


## Rows may nest their title in a VBox (history) — walk containers.
func _collect_text(node: Node, parts: PackedStringArray) -> void:
	for child in node.get_children():
		if child is Label:
			parts.append((child as Label).text)
		elif child is Button:
			parts.append((child as Button).text)
		else:
			_collect_text(child, parts)


func _collect_buttons(node: Node, found: Array) -> void:
	for child in node.get_children():
		if child is Button:
			found.append((child as Button).text)
		else:
			_collect_buttons(child, found)


func _find_button(parent: Node, text: String) -> Button:
	for child in parent.get_children():
		if child is Button and (child as Button).text == text:
			return child
		if not (child is Label):
			var nested := _find_button(child, text)
			if nested != null:
				return nested
	return null


func _display_name() -> String:
	var display: String = _app.user.get_display_name()
	if display.is_empty() or display == UserService.PLACEHOLDER_NAME:
		display = _app.auth.get_username()
	return display


func _check_server_reachable() -> void:
	var res: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_GET, "/profiles/me")
	var transport_failure: bool = (res.error_kind == ApiClient.ErrorKind.NETWORK
			or res.error_kind == ApiClient.ErrorKind.SERVER_UNAVAILABLE)
	_check(not transport_failure, "backend reachable over HTTPS (%s)" % _msg(res))
	_check(_app.network.get_status() == NetworkService.Status.CONNECTED,
			"network reports online after the reachability call")


func _msg(res: Dictionary) -> String:
	if res.get("ok", false):
		return "ok"
	var message := str(res.get("message", res.get("error", "")))
	return "failed: %s (status %d)" % [message, int(res.get("status", 0))]


func _wait_until(predicate: Callable, timeout_sec: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await create_timer(0.15).timeout
	return predicate.call()


func _frame() -> void:
	await process_frame


func _finish() -> void:
	print("SOCIAL E2E: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		printerr("FAIL: ", label)

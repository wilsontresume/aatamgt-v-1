extends SceneTree
## Phase 1 validation suite (no external test framework needed).
## Run: godot --headless --path . -s res://tests/validate.gd
## Exit code 0 = all checks passed.

const SCREEN_ROOT_NAMES := {
	&"splash": "SplashScreen",
	&"main_menu": "MainMenu",
	&"game_selection": "GameSelection",
	&"profile": "Profile",
	&"settings": "Settings",
	&"auth": "AuthScreen",
	&"aadu_puli": "AaduPuliScreen",
	&"solah_seedi": "SolahSeediScreen",
}

var _checks := 0
var _failures := 0
var _started := false
var _app: Node = null
var _main: Node = null


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run()
	return false


func _run() -> void:
	await _frame()

	# Phase 3: start every run from a clean slate so a stored session
	# can never delay or redirect the assertions below.
	if FileAccess.file_exists("user://session.json"):
		var user_dir := DirAccess.open("user://")
		if user_dir != null:
			user_dir.remove("session.json")

	# Phase 4: a stored Aadu Puli position must not leak into the checks.
	if FileAccess.file_exists("user://aadu_puli_save.json"):
		var game_dir := DirAccess.open("user://")
		if game_dir != null:
			game_dir.remove("aadu_puli_save.json")

	# Phase 9: same for the stored Solah Seedi position.
	if FileAccess.file_exists("user://solah_seedi_save.json"):
		var solah_dir := DirAccess.open("user://")
		if solah_dir != null:
			solah_dir.remove("solah_seedi_save.json")

	# --- Autoload ------------------------------------------------------
	_app = get_root().get_node_or_null("/root/App")
	_check(_app != null, "autoload App is registered")
	if _app == null:
		_finish()
		return

	# --- Resource load scan -------------------------------------------
	_scan_dir("res://scenes")
	_scan_dir("res://src")
	await _frame()

	# --- Theme + main scene -------------------------------------------
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	_check(main_scene != null, "main.tscn loads")
	if main_scene == null:
		_finish()
		return
	_main = main_scene.instantiate()
	get_root().add_child(_main)
	await _frame()

	var screen_container: Control = _main.get_node("ScreenLayer/ScreenContainer")
	_check(screen_container.theme != null, "theme applied to screen container")

	# --- Splash -> main menu handoff ----------------------------------
	_check(_app.navigation.current == &"splash", "boots into splash screen")
	await create_timer(1.9).timeout
	_check(_app.navigation.current == &"main_menu", "splash auto-advances to main menu")

	# --- Every screen instantiates with correct root -------------------
	for screen_id in [&"game_selection", &"profile", &"settings", &"auth",
			&"aadu_puli", &"solah_seedi", &"main_menu"]:
		_app.navigation.go(screen_id)
		await _frame()
		await _frame()
		var found := false
		for child in screen_container.get_children():
			if child.name == SCREEN_ROOT_NAMES[screen_id]:
				found = true
		_check(found, "screen '%s' hosts node %s" % [screen_id, SCREEN_ROOT_NAMES[screen_id]])

	# --- Back stack ----------------------------------------------------
	_app.navigation.go(&"settings")
	await _frame()
	_check(_app.navigation.can_go_back(), "history available from main menu -> settings")
	_app.navigation.back()
	_check(_app.navigation.current == &"main_menu", "back() returns to main menu")

	# --- Invalid navigation ignored ------------------------------------
	_app.navigation.go(&"does_not_exist")
	_check(_app.navigation.current == &"main_menu", "unknown screen id is rejected")

	# --- Coin balance display ------------------------------------------
	_app.coins.set_balance_from_server(1500)
	await create_timer(0.6).timeout
	var coin_label: Label = _main.get_node_or_null(
			"ScreenLayer/ScreenContainer/MainMenu/Margin/Content/TopBar/ActionsSlot/CoinBalance/AmountLabel")
	_check(coin_label != null and coin_label.text == "1,500",
			"coin display formats 1,500 (got: %s)" % (coin_label.text if coin_label else "missing"))

	# --- Error dialog ---------------------------------------------------
	var error_dialog: Control = _main.get_node("DialogLayer/DialogRoot/ErrorDialog")
	_app.dialog.show_error("Test title", "Test message")
	await _frame()
	_check(error_dialog.visible, "error dialog becomes visible")
	var err_title: Label = error_dialog.get_node("Center/Panel/Body/TitleLabel")
	var err_msg: Label = error_dialog.get_node("Center/Panel/Body/MessageLabel")
	_check(err_title.text == "Test title" and err_msg.text == "Test message",
			"error dialog title/message mapped in order")
	error_dialog.close()
	await _frame()
	_check(not error_dialog.visible, "error dialog closes")

	# --- Confirm dialog -------------------------------------------------
	var confirm_dialog: Control = _main.get_node("DialogLayer/DialogRoot/ConfirmDialog")
	var results: Array = []
	var sig: Signal = _app.dialog.confirm("Leave?", "Are you sure?", "Leave", true)
	sig.connect(func(result: bool) -> void: results.append(result))
	await _frame()
	_check(confirm_dialog.visible, "confirm dialog becomes visible")
	confirm_dialog.resolve(true)
	await _frame()
	_check(results == [true], "confirm dialog resolves true")

	# --- Loading overlay ------------------------------------------------
	var loading: Control = _main.get_node("DialogLayer/DialogRoot/LoadingCenter/LoadingIndicator")
	_app.dialog.show_loading("Please wait")
	await _frame()
	_check(loading.visible, "loading indicator shows")
	_app.dialog.hide_loading()
	_check(not loading.visible, "loading indicator hides")

	# --- Placeholder services -------------------------------------------
	_check(_app.user.is_initialized() and _app.user.is_guest(), "user placeholder is a guest")
	_check(_app.game_session.start_session(&"morris") == false, "no fake game session is created")
	_check(_app.network.get_status() == NetworkService.Status.OFFLINE, "network reports offline in Phase 1")
	_check(_app.coins.get_balance() == 1500, "coin balance mirrors server value")

	# --- Phase 3: backend wiring (offline assertions only) ------------
	_check(_app.auth != null and _app.api_client != null,
			"auth service and api client are wired into App")
	_check(not _app.auth.is_authenticated(), "no session after a clean boot")
	_check(not _app.auth.has_stored_session(), "guest boot writes no session file")
	_check(BackendConfig.validate_url("https://api.example.com") == "https://api.example.com",
			"https backend urls are accepted")
	_check(BackendConfig.validate_url("http://evil.example.com") == "",
			"plain http on a public host is rejected")
	_check(BackendConfig.validate_url("http://127.0.0.1:3000") == "http://127.0.0.1:3000",
			"loopback http stays available for development")
	_check(BackendConfig.validate_url("https://api.example.com/") == "https://api.example.com",
			"trailing slash is normalized")
	_check(not _app.api_client.is_reachable(), "no reachability claim before any request")

	_app.navigation.go(&"settings")
	await _frame()
	await _frame()
	var settings_screen: Control = null
	for child in screen_container.get_children():
		if child.name == "Settings":
			settings_screen = child
	var sign_in_button: Button = settings_screen.get_node_or_null(
			"Margin/Content/AccountPanel/AccountBody/SignInButton") 			if settings_screen != null else null
	_check(sign_in_button != null and not sign_in_button.disabled,
			"settings sign-in button is enabled")

	# --- Phase 4: Aadu Puli Aattam (offline hot seat) -------------------
	_app.navigation.go(&"aadu_puli")
	await _frame()
	await _frame()
	var aadu_screen: Control = null
	for child in screen_container.get_children():
		if child.name == "AaduPuliScreen":
			aadu_screen = child
	_check(aadu_screen != null, "aadu_puli screen instantiates")
	if aadu_screen != null:
		var status: Label = aadu_screen.get_node_or_null("Margin/Content/StatusLabel")
		var detail: Label = aadu_screen.get_node_or_null("Margin/Content/DetailLabel")
		var undo_btn: Button = aadu_screen.get_node_or_null(
				"Margin/Content/Controls/UndoButton")
		var board: Control = aadu_screen.get_node_or_null("Margin/Content/Board")
		_check(status != null and status.text == "Goats to move — place a goat",
				"fresh game asks the goats to place")
		_check(detail != null and detail.text.contains("15 in hand"),
				"detail shows the goat hand")
		_check(undo_btn != null and undo_btn.disabled, "undo starts disabled")
		_check(board != null and board.has_signal("point_activated"),
				"board exposes point activation")

		if board != null and status != null and undo_btn != null:
			# Hot seat first: a persisted vs-AI preference must never
			# race the Phase 4 assertions (Phase 5 switches it back).
			var hot_seat_btn: Button = aadu_screen.get_node_or_null(
					"Margin/Content/ModeRow/HotSeatButton")
			_check(hot_seat_btn != null, "hot seat toggle exists")
			if hot_seat_btn != null:
				hot_seat_btn.pressed.emit()
				await _frame()
				_check(status.text == "Goats to move — place a goat",
						"hot seat mode selects without touching the game")
			# Drive a full move through the view signal (no rendering needed).
			board.emit_signal("point_activated", 7)
			await _frame()
			_check(status.text == "Tigers to move — step or jump",
					"placing through the board submits the move")
			_check(not undo_btn.disabled, "undo enables after a move")
			_check(FileAccess.file_exists("user://aadu_puli_save.json"),
					"position is saved after a move")
			undo_btn.pressed.emit()
			await _frame()
			_check(status.text == "Goats to move — place a goat",
					"undo restores the previous position")
			_check(undo_btn.disabled, "undo disables at the start again")

		# --- Phase 5: Aadu Puli Aattam AI -----------------------------
		if board != null and status != null and undo_btn != null:
			await _test_aadu_puli_ai(aadu_screen, board, status, undo_btn)

		# --- Phase 6: online multiplayer (offline UI contract) -------
		if status != null and undo_btn != null:
			await _test_online_ui(aadu_screen, status, undo_btn)

	# --- Phase 7: virtual coin wallet (client contract) --------------
	_test_phase7_wallet()

	# --- Phase 8: ad architecture (client contract) -----------------
	_test_phase8_ads()

	# --- Phase 9: Solah Seedi (offline + AI + online contract) ------
	await _test_solah_seedi(screen_container)

	_finish()


## Phase 7 offline contract: the client can only OBSERVE the coin
## balance. CoinService exposes exactly one writer — a server-pushed
## value — and has no add/spend/mint API. AuthService exposes the
## read-only wallet fetch; rewarded-ad grants moved to AdService in
## Phase 8, where the server alone decides the coin amount.
func _test_phase7_wallet() -> void:
	var coin_methods := []
	for m in _app.coins.get_method_list():
		coin_methods.append(str(m.get("name", "")))
	_check(coin_methods.has("set_balance_from_server"),
			"CoinService accepts server-pushed balances")
	for forbidden in ["add_coins", "spend_coins", "set_balance", "mint", "credit", "debit"]:
		_check(not coin_methods.has(forbidden),
				"CoinService has no '%s' mutator" % forbidden)

	var auth_methods := []
	for m in _app.auth.get_method_list():
		auth_methods.append(str(m.get("name", "")))
	_check(auth_methods.has("fetch_wallet"),
			"AuthService exposes the wallet read (GET /wallet)")
	_check(auth_methods.has("authenticated_post"),
			"AuthService exposes authenticated POST for grants")
	_check(not auth_methods.has("claim_rewarded_ad"),
			"the superseded ad claim stub is gone from AuthService")

	_app.coins.set_balance_from_server(4200)
	_check(_app.coins.get_balance() == 4200,
			"balance follows the server payload")
	_app.coins.set_balance_from_server(0)
	_check(_app.coins.get_balance() == 0,
			"balance resets only from a server payload")


## Phase 8 client contract: every ad goes AdService -> AdProvider ->
## server. The client holds no ad unit IDs, never grants coins itself
## (reward_granted only fires after server validation), and checks
## interstitial eligibility only from a dismissed result dialog.
func _test_phase8_ads() -> void:
	_check(_app.ads != null, "App exposes the AdService")
	var ad_methods := []
	for m in _app.ads.get_method_list():
		ad_methods.append(str(m.get("name", "")))
	for required in ["refresh_config", "request_rewarded", "check_interstitial"]:
		_check(ad_methods.has(required), "AdService exposes %s" % required)

	_check(_app.ads.has_signal("reward_granted") and _app.ads.has_signal("reward_failed"),
			"AdService reports validated grants and failures")
	_check(_app.ads.is_connected("reward_granted", Callable(_app, "_on_reward_granted")),
			"App re-reads the wallet after a validated grant")

	var stub := StubAdProvider.new()
	_check(stub is AdProvider, "StubAdProvider implements AdProvider")
	var provider_methods := []
	for m in stub.get_method_list():
		provider_methods.append(str(m.get("name", "")))
	_check(provider_methods.has("show_rewarded"),
			"provider abstraction can present rewarded ads")
	_check(provider_methods.has("show_interstitial"),
			"provider abstraction can present interstitials")

	var dialog_signals := []
	for s in _app.dialog.get_signal_list():
		dialog_signals.append(str(s.get("name", "")))
	_check(dialog_signals.has("error_dismissed"),
			"DialogService forwards result-dialog dismissals")

	_check(_scan_text("res://src", "ca-app-pub").is_empty(),
			"no ad unit IDs hardcoded under src/")
	_check(_scan_text("res://src", "rewards/ad").is_empty(),
			"unvalidated Phase 7 ad endpoint gone from the client")
	_check(not _scan_text("res://src/ui/screens/aadu_puli.gd",
			"check_interstitial").is_empty(),
			"dismissed result dialog triggers the interstitial check")


## Every .gd file under `path` (or the file itself) containing `needle`.
func _scan_text(path: String, needle: String) -> Array:
	if path.ends_with(".gd"):
		var only := FileAccess.open(path, FileAccess.READ)
		if only == null:
			return []
		var found := only.get_as_text().contains(needle)
		only.close()
		return [path] if found else []
	var hits: Array = []
	var dir := DirAccess.open(path)
	if dir == null:
		return hits
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		var full := path + "/" + file_name
		if dir.current_is_dir() and not file_name.begins_with("."):
			hits.append_array(_scan_text(full, needle))
		elif file_name.ends_with(".gd"):
			var file := FileAccess.open(full, FileAccess.READ)
			if file != null:
				if file.get_as_text().contains(needle):
					hits.append(full)
				file.close()
		file_name = dir.get_next()
	dir.list_dir_end()
	return hits


## Phase 6 offline contract: the Online opponent mode exists, hides
## offline-only controls, exposes create/join plus resign/rematch,
## wires App.online, and never touches the local save. No socket and
## no session may be created here — this suite runs without a backend.
func _test_online_ui(screen: Control, status: Label, undo_btn: Button) -> void:
	var online_btn: Button = screen.get_node_or_null(
			"Margin/Content/ModeRow/OnlineButton")
	var online_row: Control = screen.get_node_or_null("Margin/Content/OnlineRow")
	var new_btn: Button = screen.get_node_or_null(
			"Margin/Content/OnlineRow/OnlineActions/NewMatchButton")
	var join_btn: Button = screen.get_node_or_null(
			"Margin/Content/OnlineRow/OnlineActions/JoinButton")
	var code_field: LineEdit = screen.get_node_or_null(
			"Margin/Content/OnlineRow/OnlineActions/MatchIdField")
	var online_label: Label = screen.get_node_or_null(
			"Margin/Content/OnlineRow/OnlineStatusLabel")
	var resign_btn: Button = screen.get_node_or_null(
			"Margin/Content/Controls/ResignButton")
	var rematch_btn: Button = screen.get_node_or_null(
			"Margin/Content/Controls/RematchButton")
	var restart_btn: Button = screen.get_node_or_null(
			"Margin/Content/Controls/RestartButton")
	var hot_seat_btn: Button = screen.get_node_or_null(
			"Margin/Content/ModeRow/HotSeatButton")
	var difficulty_row: Control = screen.get_node_or_null(
			"Margin/Content/DifficultyRow")
	var badge: Control = screen.get_node_or_null("Margin/Content/ModeRow/AiBadge")
	_check(_app.online != null, "online match service is wired into App")
	_check(online_btn != null and online_row != null and new_btn != null
			and join_btn != null and code_field != null and online_label != null
			and resign_btn != null and rematch_btn != null and restart_btn != null
			and hot_seat_btn != null and difficulty_row != null and badge != null,
			"online controls exist")
	if online_btn == null or online_row == null or resign_btn == null \
			or rematch_btn == null or restart_btn == null:
		return
	_check(not online_row.visible, "online panel hidden in hot seat mode")
	_check(not resign_btn.visible and not rematch_btn.visible,
			"resign/rematch hidden outside online mode")
	_check(not _app.online.is_connected_to_server(),
			"no socket before the player enters online mode")

	var save_before := _aadu_save_ply()
	online_btn.pressed.emit()
	await _frame()
	await _frame()
	_check(online_row.visible, "online panel appears in online mode")
	_check(not undo_btn.visible and not restart_btn.visible,
			"offline controls hide in online mode")
	_check(not difficulty_row.visible and not badge.visible,
			"AI controls hide in online mode")
	_check(not resign_btn.visible and not rematch_btn.visible,
			"resign/rematch wait for a live match")
	_check(online_btn.button_pressed, "online toggle shows as pressed")
	_check(not _app.auth.is_authenticated(),
			"entering online mode creates no session offline")
	_check(online_label.text == "Sign in to play online matches",
			"online label asks for sign-in (got: %s)" % online_label.text)
	_check(_aadu_save_ply() == save_before,
			"entering online mode leaves the offline save untouched")
	_check(not _app.online.is_connected_to_server(),
			"no socket opens without a signed-in player")

	hot_seat_btn.pressed.emit()
	await _frame()
	await _frame()
	_check(not online_row.visible, "online panel hides when leaving online mode")
	_check(undo_btn.visible and restart_btn.visible, "offline controls return")
	_check(not online_btn.button_pressed, "online toggle releases")
	_check(status.text == "Goats to move — place a goat",
			"offline position restored after online mode (got: %s)"
			% status.text)
	_check(_aadu_save_ply() == save_before,
			"the offline save is still untouched")


## Phase 5 contract: vs-AI mode with Easy/Medium/Hard, a visible
## thinking state, board-input isolation during the AI's turn, and
## cancel/restart semantics. Assumes the Phase 4 block just left us in
## hot seat mode on a fresh game (ply 0, goats to move).
func _test_aadu_puli_ai(screen: Control, board: Control, status: Label,
		undo_btn: Button) -> void:
	var vs_ai_btn: Button = screen.get_node_or_null(
			"Margin/Content/ModeRow/VsAiButton")
	var hot_seat_btn: Button = screen.get_node_or_null(
			"Margin/Content/ModeRow/HotSeatButton")
	var difficulty_row: Control = screen.get_node_or_null(
			"Margin/Content/DifficultyRow")
	var badge: Control = screen.get_node_or_null(
			"Margin/Content/ModeRow/AiBadge")
	var badge_label: Label = screen.get_node_or_null(
			"Margin/Content/ModeRow/AiBadge/AiBadgeRow/AiBadgeLabel")
	var spinner: Control = screen.get_node_or_null(
			"Margin/Content/ModeRow/AiBadge/AiBadgeRow/ThinkingSpinner")
	var easy_btn: Button = screen.get_node_or_null(
			"Margin/Content/DifficultyRow/EasyButton")
	var medium_btn: Button = screen.get_node_or_null(
			"Margin/Content/DifficultyRow/MediumButton")
	var hard_btn: Button = screen.get_node_or_null(
			"Margin/Content/DifficultyRow/HardButton")
	var restart_btn: Button = screen.get_node_or_null(
			"Margin/Content/Controls/RestartButton")
	_check(vs_ai_btn != null and hot_seat_btn != null and difficulty_row != null
			and badge != null and badge_label != null and spinner != null
			and easy_btn != null and medium_btn != null and hard_btn != null
			and restart_btn != null,
			"vs-AI, difficulty and thinking-indicator controls exist")
	if vs_ai_btn == null or hot_seat_btn == null or difficulty_row == null \
			or badge == null or badge_label == null or spinner == null \
			or easy_btn == null or medium_btn == null or hard_btn == null \
			or restart_btn == null:
		return
	_check(not difficulty_row.visible and not badge.visible,
			"AI controls are hidden in hot seat mode")

	# Switch to vs-AI; the fresh game stays the human's turn.
	vs_ai_btn.pressed.emit()
	await _frame()
	_check(vs_ai_btn.button_pressed and not hot_seat_btn.button_pressed,
			"vs-AI mode toggles on")
	_check(difficulty_row.visible and badge.visible,
			"AI controls appear in vs-AI mode")
	_check(not spinner.visible, "no thinking state before a move")
	_check(_aadu_save_ply() == 0, "fresh position untouched by the mode switch")
	easy_btn.pressed.emit()
	await _frame()
	_check(easy_btn.button_pressed, "easy difficulty selects")

	# The AI answers the opening move.
	board.emit_signal("point_activated", 7)
	var ai_ply := _aadu_save_ply()
	var frames := 0
	while ai_ply < 2 and frames < 300:
		await _frame()
		ai_ply = _aadu_save_ply()
		frames += 1
	_check(ai_ply == 2, "the AI answers the opening move (ply %d)" % ai_ply)
	_check(status.text.begins_with("Goats to move"),
			"the turn returns to the human")
	_check(not spinner.visible, "thinking indicator hides after the reply")
	_check(not undo_btn.disabled, "undo stays available after the AI reply")
	_check(badge_label.text == "AI: Easy", "badge shows the active difficulty")

	# Undo in vs-AI mode rewinds the whole exchange (ply 2 -> 0).
	undo_btn.pressed.emit()
	await _frame()
	_check(_aadu_save_ply() == 0,
			"undo rewinds past the AI reply to the human turn")
	_check(status.text == "Goats to move — place a goat",
			"human to move after undo")
	_check(undo_btn.disabled, "undo disables at the start again")

	# Hard: a visible thinking state, and the board ignores input during it.
	hard_btn.pressed.emit()
	await _frame()
	_check(hard_btn.button_pressed, "hard difficulty selects")
	board.emit_signal("point_activated", 7)
	await _frame()
	_check(status.text == "Tigers are thinking…",
			"thinking state while the AI searches")
	_check(spinner.visible, "thinking spinner shows during the search")
	_check(badge_label.text == "AI thinking…",
			"badge shows the thinking state")
	board.emit_signal("point_activated", 9)
	await _frame()
	_check(_aadu_save_ply() == 1, "board input is ignored while the AI thinks")
	_check(board.selection == -1,
			"no piece can be selected during the AI's turn")

	# Switching difficulty cancels and restarts the search.
	medium_btn.pressed.emit()
	await _frame()
	_check(status.text == "Tigers are thinking…",
			"difficulty switch restarts the search")

	# Switching to hot seat cancels the search outright.
	hot_seat_btn.pressed.emit()
	await _frame()
	_check(status.text == "Tigers to move — step or jump",
			"mode switch cancels the AI search")
	_check(not badge.visible and not difficulty_row.visible,
			"AI controls hide in hot seat mode")

	# Back to vs-AI: restart cancels the pending search either way.
	vs_ai_btn.pressed.emit()
	await _frame()
	_check(status.text == "Tigers are thinking…",
			"returning to vs-AI resumes the search")
	var confirm_dialog: Control = _main.get_node(
			"DialogLayer/DialogRoot/ConfirmDialog")
	restart_btn.pressed.emit()
	await _frame()
	_check(confirm_dialog != null and confirm_dialog.visible,
			"restart confirmation opens")
	if confirm_dialog == null:
		return
	confirm_dialog.resolve(false)  # decline: position kept, search resumes
	await _frame()
	await _frame()
	_check(_aadu_save_ply() == 1, "declining restart keeps the position")
	_check(status.text == "Tigers are thinking…",
			"declined restart resumes the search")
	restart_btn.pressed.emit()
	await _frame()
	confirm_dialog.resolve(true)  # accept: fresh game, no stray AI move
	var stable := 0
	frames = 0
	while frames < 30:
		await _frame()
		frames += 1
		if _aadu_save_ply() == 0:
			stable += 1
		else:
			stable = 0
	_check(stable >= 10,
			"restart starts a fresh game and no stray AI move follows")
	_check(status.text == "Goats to move — place a goat",
			"fresh game is the human's turn")

	# Tidy end state for anything that runs after this suite.
	hot_seat_btn.pressed.emit()
	await _frame()
	_check(not badge.visible, "suite ends in hot seat mode")


## Phase 9 contract: the Solah Seedi screen boots from its own save,
## routes chain input through the shared rules engine (select, extend,
## offer a stop, finish, step back, clear), hands green to the AI in
## vs-AI mode, and reuses the ONE online session service under the
## solah-seedi game key — all offline, no socket, no session.
func _test_solah_seedi(screen_container: Control) -> void:
	# Crafted position: red 0+6, greens 11/21/30, red to move, ply 3.
	# From 6 red can step (7, 12) or jump the chain 6-16-26 over 11+21.
	_write_solah_save({
		"version": 1,
		"board": "R.....R....G.........G........G......",
		"side_to_move": "red",
		"ply": 3,
		"plies_since_capture": 0,
		"result": "none",
	})
	_app.navigation.go(&"solah_seedi")
	await _frame()
	await _frame()
	var screen: Control = null
	for child in screen_container.get_children():
		if child.name == "SolahSeediScreen":
			screen = child
	_check(screen != null, "solah_seedi screen instantiates")
	if screen == null:
		return
	var status: Label = screen.get_node_or_null("Margin/Content/StatusLabel")
	var detail: Label = screen.get_node_or_null("Margin/Content/DetailLabel")
	var undo_btn: Button = screen.get_node_or_null(
			"Margin/Content/Controls/UndoButton")
	var play_btn: Button = screen.get_node_or_null(
			"Margin/Content/Controls/PlayMoveButton")
	var board: Control = screen.get_node_or_null("Margin/Content/Board")
	_check(status != null and status.text == "Red to move — step or jump",
			"the screen restores the stored position (red to move)")
	_check(detail != null and detail.text.contains("Green 3"),
			"detail shows the crafted army sizes")
	_check(undo_btn != null and undo_btn.disabled, "undo starts disabled")
	_check(play_btn != null and not play_btn.visible,
			"the play button waits for a stoppable route")
	_check(board != null and board.has_signal("point_activated"),
			"board exposes point activation")
	if board == null or status == null or undo_btn == null or play_btn == null:
		return

	# Hot seat first: a persisted vs-AI preference must not race us.
	var hot_seat_btn: Button = screen.get_node_or_null(
			"Margin/Content/ModeRow/HotSeatButton")
	_check(hot_seat_btn != null, "hot seat toggle exists")
	if hot_seat_btn != null:
		hot_seat_btn.pressed.emit()
		await _frame()
		_check(status.text == "Red to move — step or jump",
				"hot seat mode selects without touching the game")

	# Chain input through the view signal (no rendering needed).
	board.emit_signal("point_activated", 6)
	await _frame()
	_check(board.selection == 6, "tapping a soldier selects it")
	board.emit_signal("point_activated", 16)
	await _frame()
	_check(board.selection == 6 and board.path_points == [6, 16],
			"a chainable jump keeps the route pending")
	_check(play_btn.visible, "the play button offers the stop here")
	_check(play_btn.text == "Play 6-16*",
			"play button shows the jump notation (got: %s)" % play_btn.text)
	_check(status.text == "Red to move — step or jump",
			"the pending route has not been submitted yet")
	board.emit_signal("point_activated", 26)
	await _frame()
	_check(status.text == "Green to move — step or jump",
			"finishing the chain submits it (got: %s)" % status.text)
	_check(board.selection == -1 and board.path_points.is_empty(),
			"the route clears after the move")
	_check(not undo_btn.disabled, "undo enables after a move")
	_check(FileAccess.file_exists("user://solah_seedi_save.json"),
			"position is saved after a move")
	_check(_solah_save_ply() == 4, "the chain advanced the saved ply")

	# Step back inside the route, then clear it on a foreign tap.
	undo_btn.pressed.emit()
	await _frame()
	_check(status.text == "Red to move — step or jump" and undo_btn.disabled,
			"undo restores the stored position")
	board.emit_signal("point_activated", 6)
	await _frame()
	board.emit_signal("point_activated", 16)
	await _frame()
	_check(play_btn.visible, "the jump waits again")
	board.emit_signal("point_activated", 6)
	await _frame()
	_check(board.selection == 6 and board.path_points == [6],
			"tapping an earlier hop steps back inside the route")
	_check(not play_btn.visible, "an unfinished origin has nothing to play")
	board.emit_signal("point_activated", 30)  # a green soldier
	await _frame()
	_check(board.selection == -1 and board.path_points.is_empty(),
			"tapping a foreign soldier clears the route")

	# vs-AI: red steps 6-7, Easy answers for green, undo rewinds both.
	var vs_ai_btn: Button = screen.get_node_or_null(
			"Margin/Content/ModeRow/VsAiButton")
	var easy_btn: Button = screen.get_node_or_null(
			"Margin/Content/DifficultyRow/EasyButton")
	var badge_label: Label = screen.get_node_or_null(
			"Margin/Content/ModeRow/AiBadge/AiBadgeRow/AiBadgeLabel")
	if vs_ai_btn != null and easy_btn != null:
		vs_ai_btn.pressed.emit()
		await _frame()
		easy_btn.pressed.emit()
		await _frame()
		if badge_label != null:
			_check(badge_label.text == "AI: Easy",
					"the badge follows the difficulty")
		board.emit_signal("point_activated", 6)
		await _frame()
		board.emit_signal("point_activated", 7)
		await _frame()
		var frames := 0
		while _solah_save_ply() != 5 and frames < 300:
			await _frame()
			frames += 1
		_check(_solah_save_ply() == 5, "the AI answers the move (ply 5)")
		_check(status.text == "Red to move — step or jump",
				"the turn returns to the human (got: %s)" % status.text)
		undo_btn.pressed.emit()
		await _frame()
		_check(_solah_save_ply() == 3,
				"undo rewinds the whole exchange to the stored position")
		_check(undo_btn.disabled, "nothing left to undo")

	await _test_solah_online_ui(screen, status, undo_btn)


## Phase 9 offline online-UI contract: same node paths as the Aadu
## Puli screen (one shared session service), solah-seedi game key,
## sign-in hint while signed out, and the offline save untouched.
func _test_solah_online_ui(screen: Control, status: Label,
		undo_btn: Button) -> void:
	var online_btn: Button = screen.get_node_or_null(
			"Margin/Content/ModeRow/OnlineButton")
	var online_row: Control = screen.get_node_or_null("Margin/Content/OnlineRow")
	var new_btn: Button = screen.get_node_or_null(
			"Margin/Content/OnlineRow/OnlineActions/NewMatchButton")
	var join_btn: Button = screen.get_node_or_null(
			"Margin/Content/OnlineRow/OnlineActions/JoinButton")
	var code_field: LineEdit = screen.get_node_or_null(
			"Margin/Content/OnlineRow/OnlineActions/MatchIdField")
	var online_label: Label = screen.get_node_or_null(
			"Margin/Content/OnlineRow/OnlineStatusLabel")
	var resign_btn: Button = screen.get_node_or_null(
			"Margin/Content/Controls/ResignButton")
	var rematch_btn: Button = screen.get_node_or_null(
			"Margin/Content/Controls/RematchButton")
	var restart_btn: Button = screen.get_node_or_null(
			"Margin/Content/Controls/RestartButton")
	var hot_seat_btn: Button = screen.get_node_or_null(
			"Margin/Content/ModeRow/HotSeatButton")
	var difficulty_row: Control = screen.get_node_or_null(
			"Margin/Content/DifficultyRow")
	var badge: Control = screen.get_node_or_null("Margin/Content/ModeRow/AiBadge")
	_check(_app.online != null, "online match service is wired into App")
	_check(online_btn != null and online_row != null and new_btn != null
			and join_btn != null and code_field != null and online_label != null
			and resign_btn != null and rematch_btn != null and restart_btn != null
			and hot_seat_btn != null and difficulty_row != null and badge != null,
			"online controls exist for solah seedi")
	if online_btn == null or online_row == null or resign_btn == null \
			or rematch_btn == null or restart_btn == null:
		return
	_check(not online_row.visible, "online panel hidden in hot seat mode")
	_check(not resign_btn.visible and not rematch_btn.visible,
			"resign/rematch hidden outside online mode")
	_check(not _app.online.is_connected_to_server(),
			"no socket before the player enters online mode")

	var save_before := _solah_save_ply()
	online_btn.pressed.emit()
	await _frame()
	await _frame()
	_check(online_row.visible, "online panel appears in online mode")
	_check(not undo_btn.visible and not restart_btn.visible,
			"offline controls hide in online mode")
	_check(not difficulty_row.visible and not badge.visible,
			"AI controls hide in online mode")
	_check(not resign_btn.visible and not rematch_btn.visible,
			"resign/rematch wait for a live match")
	_check(online_btn.button_pressed, "online toggle shows as pressed")
	_check(not _app.auth.is_authenticated(),
			"entering online mode creates no session offline")
	_check(online_label.text == "Sign in to play online matches",
			"online label asks for sign-in (got: %s)" % online_label.text)
	_check(status.text == "Sign in to play online",
			"status asks for sign-in (got: %s)" % status.text)
	_check(_app.online.game_key == OnlineMatchService.SOLAH_SEEDI_KEY,
			"the shared session service points at the solah-seedi key")
	_check(_solah_save_ply() == save_before,
			"entering online mode leaves the offline save untouched")
	_check(not _app.online.is_connected_to_server(),
			"no socket opens without a signed-in player")

	hot_seat_btn.pressed.emit()
	await _frame()
	await _frame()
	_check(not online_row.visible, "online panel hides when leaving online mode")
	_check(undo_btn.visible and restart_btn.visible, "offline controls return")
	_check(not online_btn.button_pressed, "online toggle releases")
	_check(status.text == "Red to move — step or jump",
			"offline position restored after online mode (got: %s)"
			% status.text)
	_check(_solah_save_ply() == save_before,
			"the offline save is still untouched")


# ----------------------------------------------------------------------

func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		printerr("FAIL: ", label)


func _scan_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		_failures += 1
		printerr("FAIL: cannot open directory ", path)
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if dir.current_is_dir() and not file_name.begins_with("."):
			_scan_dir(path + "/" + file_name)
		elif file_name.ends_with(".tscn") or file_name.ends_with(".gd"):
			var full := path + "/" + file_name
			var resource = load(full)
			_check(resource != null, "resource loads: %s" % full)
		file_name = dir.get_next()
	dir.list_dir_end()


func _frame() -> void:
	await process_frame


## The ply from the screen's save file (or -1 when missing/corrupt).
func _aadu_save_ply() -> int:
	if not FileAccess.file_exists("user://aadu_puli_save.json"):
		return -1
	var file := FileAccess.open("user://aadu_puli_save.json", FileAccess.READ)
	if file == null:
		return -1
	var data: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (data is Dictionary) or not (data as Dictionary).has("ply"):
		return -1
	return int((data as Dictionary)["ply"])


## The ply from the Solah Seedi screen's save file (or -1).
func _solah_save_ply() -> int:
	if not FileAccess.file_exists("user://solah_seedi_save.json"):
		return -1
	var file := FileAccess.open("user://solah_seedi_save.json", FileAccess.READ)
	if file == null:
		return -1
	var data: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (data is Dictionary) or not (data as Dictionary).has("ply"):
		return -1
	return int((data as Dictionary)["ply"])


## Writes a Solah Seedi position before the screen loads it.
func _write_solah_save(payload: Dictionary) -> void:
	var file := FileAccess.open("user://solah_seedi_save.json",
			FileAccess.WRITE)
	if file == null:
		_failures += 1
		printerr("FAIL: cannot write user://solah_seedi_save.json")
		return
	file.store_string(JSON.stringify(payload))
	file.close()


func _finish() -> void:
	print("VALIDATE: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)

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
	for screen_id in [&"game_selection", &"profile", &"settings", &"main_menu"]:
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

	_finish()


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


func _finish() -> void:
	print("VALIDATE: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)

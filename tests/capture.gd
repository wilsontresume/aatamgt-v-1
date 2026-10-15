extends SceneTree
## Visual capture pass — walks every screen and dialog, saving PNGs to
## tests/artifacts/ for review. Run windowed (no --headless):
##   godot --path . -s res://tests/capture.gd

const OUT_DIR := "res://tests/artifacts"
const LOG_PATH := "/tmp/aatamgt_capture.log"

var _started := false


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run()
	return false


func _log(message: String) -> void:
	var file := FileAccess.open(LOG_PATH, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	else:
		file.seek_end()
	file.store_line("%s  %s" % [Time.get_time_string_from_system(), message])
	file.close()
	print(message)


func _run() -> void:
	_log("step: start")
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	# Phase 4: capture the Aadu Puli board from a guaranteed fresh game.
	if FileAccess.file_exists("user://aadu_puli_save.json"):
		var user_dir := DirAccess.open("user://")
		if user_dir != null:
			user_dir.remove("aadu_puli_save.json")

	var app := get_root().get_node_or_null("/root/App")
	if app == null:
		_log("FAIL: autoload App missing")
		quit(1)
		return
	app.coins.set_balance_from_server(1500)
	_log("step: main scene instantiate")

	var main = load("res://scenes/main.tscn").instantiate()
	get_root().add_child(main)
	_log("step: main added")

	await create_timer(2.0).timeout
	_log("step: reached main menu")
	await _snap("01_main_menu")

	app.navigation.go(&"game_selection")
	await create_timer(0.5).timeout
	await _snap("02_game_selection")

	app.navigation.go(&"profile")
	await create_timer(0.5).timeout
	await _snap("03_profile")

	app.navigation.go(&"settings")
	await create_timer(0.5).timeout
	await _snap("04_settings")

	app.dialog.show_error("Connection failed",
			"We could not reach the AATAMGT servers. Check your internet connection and try again.")
	await create_timer(0.5).timeout
	await _snap("05_error_dialog")
	main.get_node("DialogLayer/DialogRoot/ErrorDialog").close()
	_log("step: error dialog done")

	var sig: Signal = app.dialog.confirm("Leave the match?",
			"Your opponent will be notified and the match will count as a loss.", "Leave", true)
	var resolved := [false]
	sig.connect(func(result: bool) -> void: resolved[0] = true)
	await create_timer(0.5).timeout
	await _snap("06_confirm_dialog")
	main.get_node("DialogLayer/DialogRoot/ConfirmDialog").resolve(true)
	await create_timer(0.2).timeout
	_log("step: confirm dialog done (resolved=%s)" % str(resolved[0]))

	app.dialog.show_loading("Loading your profile")
	await create_timer(0.5).timeout
	await _snap("07_loading")
	app.dialog.hide_loading()

	app.navigation.go(&"auth")
	await create_timer(0.5).timeout
	await _snap("08_auth_sign_in")

	var auth_screen: Control = null
	for child in main.get_node("ScreenLayer/ScreenContainer").get_children():
		if child.name == "AuthScreen":
			auth_screen = child
	if auth_screen != null:
		auth_screen.get_node(
			"SafeMargin/Scroll/CenterH/Stage/Panel/Body/SwitchButton").pressed.emit()
		await create_timer(0.4).timeout
		await _snap("09_auth_register")
		var auth_err: Label = auth_screen.get_node(
				"SafeMargin/Scroll/CenterH/Stage/Panel/Body/ErrorLabel")
		auth_err.text = "That username is already taken."
		auth_err.visible = true
		await _snap("10_auth_error")
	else:
		_log("FAIL: auth screen not found for capture")

	app.navigation.go(&"aadu_puli")
	await create_timer(0.6).timeout

	var aadu_screen: Control = null
	for child in main.get_node("ScreenLayer/ScreenContainer").get_children():
		if child.name == "AaduPuliScreen":
			aadu_screen = child
	if aadu_screen == null:
		_log("FAIL: aadu puli screen not found for capture")
		_log("step: complete")
		quit(1)
		return

	var status_before: Label = aadu_screen.get_node("Margin/Content/StatusLabel")
	# A persisted vs-AI preference must not race the Phase 4 snaps.
	aadu_screen.get_node("Margin/Content/ModeRow/HotSeatButton").pressed.emit()
	await create_timer(0.3).timeout
	_log("status before snap11: %s" % status_before.text)
	await _snap("11_aadu_puli")

	var board: Control = aadu_screen.get_node("Margin/Content/Board")
	board.emit_signal("point_activated", 7)  # goats place on 7
	await create_timer(0.4).timeout
	board.emit_signal("point_activated", 0)  # select the apex tiger
	await create_timer(0.4).timeout
	_log("status before snap12: %s" % status_before.text)
	await _snap("12_aadu_puli_selection")

	# Phase 5: vs-AI on Hard — thinking state, then the AI's reply.
	aadu_screen.get_node("Margin/Content/DifficultyRow/HardButton").pressed.emit()
	await create_timer(0.2).timeout
	aadu_screen.get_node("Margin/Content/ModeRow/VsAiButton").pressed.emit()
	var thinking := false
	for i in range(240):  # hard budget is 1.5s; grab the search while it runs
		await create_timer(0.05).timeout
		if status_before.text.begins_with("Tigers are thinking"):
			thinking = true
			break
	_log("thinking observed=%s after status: %s" % [str(thinking), status_before.text])
	await _snap("13_aadu_puli_ai_thinking")

	var replied := false
	for i in range(240):  # the reply must land within ~12s
		await create_timer(0.05).timeout
		if status_before.text.begins_with("Goats to move"):
			replied = true
			break
	_log("ai reply observed=%s after status: %s" % [str(replied), status_before.text])
	await _snap("14_aadu_puli_ai_reply")

	if not thinking or not replied:
		_log("FAIL: phase 5 capture state missing (thinking=%s replied=%s)"
				% [str(thinking), str(replied)])
		_log("step: complete")
		quit(1)
		return

	# Phase 6: the Online opponent mode's controls (no backend needed —
	# the panel and its sign-in/waiting states are pure UI).
	aadu_screen.get_node("Margin/Content/ModeRow/OnlineButton").pressed.emit()
	await create_timer(0.5).timeout
	var online_row: Control = aadu_screen.get_node_or_null("Margin/Content/OnlineRow")
	if online_row == null or not online_row.visible:
		_log("FAIL: online row did not open for snap15")
		_log("step: complete")
		quit(1)
		return
	_log("status before snap15: %s"
			% (aadu_screen.get_node("Margin/Content/StatusLabel") as Label).text)
	await _snap("15_aadu_puli_online")

	_log("step: complete")
	quit(0)


func _snap(file_name: String) -> void:
	await create_timer(0.25).timeout
	var image := get_root().get_texture().get_image()
	if image == null:
		_log("FAIL: no texture image for %s" % file_name)
		return
	var path := "%s/%s.png" % [OUT_DIR, file_name]
	var err := image.save_png(path)
	_log("snap %s (err=%d)" % [path, err])

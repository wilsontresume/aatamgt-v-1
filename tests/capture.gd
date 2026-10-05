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

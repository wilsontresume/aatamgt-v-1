extends SceneTree
## Board art preview — renders the three redesigned boards with sample
## positions and saves PNGs to tests/artifacts/ for visual review.
## Run windowed (no --headless):
##   godot --path . -s res://tests/board_preview.gd

const OUT_DIR := "res://tests/artifacts"

var _started := false


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run()
	return false


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var window := get_root()
	window.size = Vector2i(700, 1080)

	# --- Hero close-up: Aadu Puli at full detail -------------------------
	var ap := AaduPuliBoard.new()
	ap.position = Vector2(20, 20)
	ap.size = Vector2(660, 1040)
	ap.set_anchors_preset(Control.PRESET_TOP_LEFT)
	var ap_state := AaduPuliGameState.from_fen("tg.tt.g......g......... g 12 0")
	ap.configure(ap_state, 0, [2], false)
	window.add_child(ap)
	ap.queue_redraw()
	await create_timer(0.4).timeout
	await _snap("art_aadu_puli_closeup")
	ap.queue_free()

	# --- All three boards side by side -----------------------------------
	window.size = Vector2i(1720, 940)
	await create_timer(0.2).timeout

	var ss := SolahSeediBoard.new()
	ss.position = Vector2(20, 20)
	ss.size = Vector2(540, 900)
	var ss_state := SolahSeediGameState.from_fen(
			"RRRRRRRRRRRRRRRR.....GGGGGGGGGGGGGGGG r 0 0")
	ss.configure(ss_state, 11, [16], [11, 16])
	window.add_child(ss)

	var nm := MorrisBoard.new()
	nm.position = Vector2(580, 20)
	nm.size = Vector2(560, 900)
	var nm_state := NineMensMorrisGameState.initial()
	nm_state = NineMensMorrisRules.apply(nm_state, NineMensMorrisMove.place(0))
	nm_state = NineMensMorrisRules.apply(nm_state, NineMensMorrisMove.place(8))
	nm_state = NineMensMorrisRules.apply(nm_state, NineMensMorrisMove.place(4))
	nm_state = NineMensMorrisRules.apply(nm_state, NineMensMorrisMove.place(12))
	nm_state = NineMensMorrisRules.apply(nm_state, NineMensMorrisMove.place(1))
	nm_state = NineMensMorrisRules.apply(nm_state, NineMensMorrisMove.place(9))
	nm.configure(nm_state, 1, [2, 7], [])
	window.add_child(nm)

	var ap2 := AaduPuliBoard.new()
	ap2.position = Vector2(1160, 20)
	ap2.size = Vector2(540, 900)
	ap2.configure(ap_state, 0, [2], false)
	window.add_child(ap2)

	ss.queue_redraw()
	nm.queue_redraw()
	ap2.queue_redraw()
	await create_timer(0.4).timeout
	await _snap("art_boards_all")
	print("board preview complete")
	quit(0)


func _snap(file_name: String) -> void:
	await create_timer(0.2).timeout
	var image := get_root().get_texture().get_image()
	if image == null:
		print("FAIL: no texture image for %s" % file_name)
		return
	var path := "%s/%s.png" % [OUT_DIR, file_name]
	var err := image.save_png(path)
	print("snap %s (err=%d)" % [path, err])

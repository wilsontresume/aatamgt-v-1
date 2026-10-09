extends SceneTree
## Phase 12 cosmetic inventory suite (offline): scene structure,
## navigation wiring, server-owned state labels, the offline
## no-mutation contract, avatar/board presentation wiring and the
## victory/capture FX hooks. No server involved — REST flows are
## covered by tests/phase12/cosmetics_e2e.gd and the integration
## specs under server/test.
##
## Run: godot --headless --path . -s res://tests/phase12/cosmetic_validate.gd
## Exit code 0 = all checks passed.

const INVENTORY_SCENE := "res://scenes/screens/inventory.tscn"
const MAIN_MENU_SCENE := "res://scenes/screens/main_menu.tscn"
const PROFILE_SCENE := "res://scenes/components/player_profile.tscn"
const AADU_SCENE := "res://scenes/screens/aadu_puli.tscn"

const INVENTORY_NODES := [
	"Margin/Content/TopBar",
	"Margin/Content/HintLabel",
	"Margin/Content/Scroll/Sections",
]

const GAME_SCREEN_FILES := [
	"res://src/ui/screens/aadu_puli.gd",
	"res://src/ui/screens/solah_seedi.gd",
	"res://src/ui/screens/nine_mens_morris.gd",
]

var _checks := 0
var _failures := 0
var _started := false
var _app: Node = null


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

	# Fresh local state: signed out, no stored game positions.
	for file_name in ["session.json", "aadu_puli_save.json",
			"solah_seedi_save.json", "nine_mens_morris_save.json"]:
		if FileAccess.file_exists("user://%s" % file_name):
			var user_dir := DirAccess.open("user://")
			if user_dir != null:
				user_dir.remove(file_name)

	_test_service_wiring()
	_test_states_and_palettes()
	await _test_offline_no_mutation()
	_test_cache_helpers()
	await _test_inventory_scene()
	await _test_main_menu_entry()
	await _test_avatar_cosmetics()
	_test_board_skins()
	_test_screen_source_hooks()
	await _test_game_screen_fx_hooks()
	_finish()


# --- Wiring -----------------------------------------------------------------

func _test_service_wiring() -> void:
	_check(_app.cosmetics is CosmeticService, "App.cosmetics is wired")
	var signals := []
	for s in _app.cosmetics.get_signal_list():
		signals.append(str(s.get("name", "")))
	_check(signals.has("inventory_changed"), "CosmeticService signals inventory_changed")
	_check(CosmeticService.CATEGORY_ORDER.size() == 5,
			"five cosmetic categories are ordered")
	for category in CosmeticService.CATEGORY_ORDER:
		_check(CosmeticService.CATEGORY_TITLES.has(category),
				"category has a display title: %s" % category)


# --- States and palettes -----------------------------------------------------

func _test_states_and_palettes() -> void:
	_check(CosmeticService.state_of({"owned": true, "equipped": true})
			== "equipped", "equipped state label")
	_check(CosmeticService.state_of({"owned": true, "equipped": false})
			== "owned", "owned state label")
	_check(CosmeticService.state_of({"owned": false, "equipped": false})
			== "locked", "locked state label")
	_check(CosmeticService.tier_label({"tier": "FREE", "price": 0}) == "Free",
			"free tier label")
	_check(CosmeticService.tier_label({"tier": "PREMIUM", "price": 350})
			== "350 coins", "premium tier label")
	_check(not CosmeticService.is_premium({"tier": "FREE"}),
			"free is not premium")
	_check(CosmeticService.is_premium({"tier": "PREMIUM"}),
			"premium tier detected")
	_check(CosmeticService.board_palette("board_classic").is_empty(),
			"classic board palette is empty")
	_check(not CosmeticService.board_palette("board_woodland").is_empty(),
			"woodland board palette exists")
	_check(CosmeticService.pfp_style("pfp_default").is_empty(),
			"default pfp style is empty")
	_check(not CosmeticService.pfp_style("pfp_nebula").is_empty(),
			"nebula pfp style exists")
	_check(CosmeticService.frame_style("frame_none").is_empty(),
			"no-frame style is empty")
	_check(not CosmeticService.frame_style("frame_gold").is_empty(),
			"gold frame style exists")
	_check(CosmeticService.victory_style("victory_none").is_empty(),
			"none victory style is empty")
	_check(CosmeticService.capture_style("capture_none").is_empty(),
			"none capture style is empty")


# --- Offline contract: failures never mutate the cache ------------------------

func _seed_fixture() -> Array:
	var fixture := [
		{"key": "board_classic", "category": "BOARD_SKIN", "tier": "FREE",
				"price": 0, "owned": true, "equipped": true},
		{"key": "board_midnight", "category": "BOARD_SKIN",
				"tier": "PREMIUM", "price": 250, "owned": false,
				"equipped": false},
		{"key": "pfp_default", "category": "PROFILE_PICTURE", "tier": "FREE",
				"price": 0, "owned": true, "equipped": true},
	]
	_app.cosmetics.items = fixture
	_app.cosmetics.loaded = true
	_app.cosmetics.dev_grants_enabled = true
	return fixture


func _test_offline_no_mutation() -> void:
	var fixture := _seed_fixture()
	for action in ["claim", "purchase", "equip", "dev_grant"]:
		var res: Dictionary = {}
		match action:
			"claim":
				res = await _app.cosmetics.claim("board_woodland")
			"purchase":
				res = await _app.cosmetics.purchase("board_midnight")
			"equip":
				res = await _app.cosmetics.equip("board_classic")
			"dev_grant":
				res = await _app.cosmetics.dev_grant("victory_fireworks")
		_check(not res.ok, "%s fails without a session" % action)
		_check(_app.cosmetics.items == fixture,
				"%s leaves the cached inventory untouched" % action)
		_check(_app.cosmetics.loaded,
				"%s keeps the loaded flag" % action)
	var refresh: Dictionary = await _app.cosmetics.refresh()
	_check(not refresh.ok, "refresh fails without a session")
	_check(_app.cosmetics.items == fixture,
			"refresh failure leaves the cache untouched")
	_app.cosmetics.clear()
	_check(_app.cosmetics.items.is_empty(), "clear() empties the cache")
	_check(not _app.cosmetics.loaded, "clear() resets the loaded flag")


# --- Cache helpers ------------------------------------------------------------

func _test_cache_helpers() -> void:
	_seed_fixture()
	_check(_app.cosmetics.equipped_key("BOARD_SKIN") == "board_classic",
			"equipped_key finds the equipped board")
	_check(_app.cosmetics.equipped_key("PROFILE_FRAME") == "",
			"equipped_key returns empty for unknown categories")
	var boards: Array = _app.cosmetics.items_in_category("BOARD_SKIN")
	_check(boards.size() == 2, "items_in_category filters by category")
	_check(_app.cosmetics.items_in_category("CAPTURE_ANIMATION").is_empty(),
			"items_in_category hides other categories")
	_app.cosmetics.clear()


# --- Inventory scene ----------------------------------------------------------

func _test_inventory_scene() -> void:
	var scene: PackedScene = load(INVENTORY_SCENE)
	_check(scene != null, "inventory scene loads")
	if scene == null:
		return
	var screen: Control = scene.instantiate()
	_check(screen.name == "Inventory", "inventory root node named Inventory")
	get_root().add_child(screen)
	await _frame()
	await _frame()
	for node_path in INVENTORY_NODES:
		var node: Node = screen.get_node_or_null(node_path)
		_check(node != null, "inventory has %s" % node_path)
	var sections: VBoxContainer = screen.get_node("Margin/Content/Scroll/Sections")
	_check(sections.get_child_count() == 0,
			"no sections render without a signed-in session")
	var hint: Label = screen.get_node("Margin/Content/HintLabel")
	_check(not hint.text.is_empty(), "hint explains the empty inventory")
	screen.queue_free()
	await _frame()


# --- Main menu entry ----------------------------------------------------------

func _test_main_menu_entry() -> void:
	var scene: PackedScene = load(MAIN_MENU_SCENE)
	var menu: Control = scene.instantiate()
	get_root().add_child(menu)
	await _frame()
	var button: Button = menu.get_node_or_null("Margin/Content/InventoryButton")
	_check(button != null, "main menu has an Inventory button")
	if button != null:
		_check(button.text == "Inventory", "Inventory button is labelled")
		button.pressed.emit()
		_check(_app.navigation.current == &"inventory",
				"Inventory button navigates to the inventory screen")
	menu.queue_free()
	await _frame()
	_app.navigation.current = &""


# --- Avatar cosmetics ---------------------------------------------------------

func _test_avatar_cosmetics() -> void:
	_app.cosmetics.items = [
		{"key": "pfp_sunset", "category": "PROFILE_PICTURE",
				"owned": true, "equipped": true},
		{"key": "frame_gold", "category": "PROFILE_FRAME",
				"owned": true, "equipped": true},
	]
	var scene: PackedScene = load(PROFILE_SCENE)
	var profile: Control = scene.instantiate()
	get_root().add_child(profile)
	await _frame()
	var avatar: Variant = profile.get_node("Avatar")
	_check(avatar._style == CosmeticService.pfp_style("pfp_sunset"),
			"avatar picks up the equipped profile picture")
	_check(avatar._frame == CosmeticService.frame_style("frame_gold"),
			"avatar picks up the equipped frame")
	_app.cosmetics.clear()
	await _frame()
	_check(avatar._style.is_empty() and avatar._frame.is_empty(),
			"clearing the inventory resets the avatar to classic")
	profile.queue_free()
	await _frame()


# --- Board skins --------------------------------------------------------------

func _test_board_skins() -> void:
	var boards: Array = [AaduPuliBoard.new(), MorrisBoard.new(), SolahSeediBoard.new()]
	var names := ["AaduPuliBoard", "MorrisBoard", "SolahSeediBoard"]
	for i in boards.size():
		var board: Variant = boards[i]
		_check(board.has_method("set_skin"), "%s exposes set_skin" % names[i])
		_check(board.skin.is_empty(), "%s starts on the classic palette" % names[i])
		board.set_skin(CosmeticService.board_palette("board_woodland"))
		_check(board.skin.get("bg", Color(0, 0, 0)) == Color("1d2a1e"),
				"%s stores the woodland palette" % names[i])
		board.set_skin({})
		_check(board.skin.is_empty(),
				"%s restores the classic palette on empty input" % names[i])
		board.free()


# --- Game screen source hooks --------------------------------------------------

func _test_screen_source_hooks() -> void:
	for path in GAME_SCREEN_FILES:
		var source := FileAccess.get_file_as_string(path)
		_check(not source.is_empty(), "screen source readable: %s" % path)
		_check(source.contains("App.cosmetics.apply_board_skin(_board)"),
				"screen applies the board skin: %s" % path)
		_check(source.contains("CosmeticFx.capture("),
				"screen fires capture FX: %s" % path)
		_check(source.contains("CosmeticFx.victory("),
				"screen fires victory FX: %s" % path)
		_check(source.contains("CosmeticService.capture_style("),
				"screen reads the equipped capture style: %s" % path)
		_check(source.contains("CosmeticService.victory_style("),
				"screen reads the equipped victory style: %s" % path)


# --- Game screen FX hooks (live instance) ---------------------------------------

func _test_game_screen_fx_hooks() -> void:
	var scene: PackedScene = load(AADU_SCENE)
	var screen: Variant = scene.instantiate()
	get_root().add_child(screen)
	await _frame()
	var board: Variant = screen.get_node("Margin/Content/Board")
	_check(board.skin.is_empty(), "offline aadu board stays classic")
	_check(screen.has_method("_refresh_capture_fx"),
			"aadu screen exposes the capture FX hook")
	_check(screen.has_method("_play_victory_fx"),
			"aadu screen exposes the victory FX hook")
	_check(screen.has_method("_play_victory_fx_if_won"),
			"aadu screen exposes the guarded victory helper")

	# Capture FX: equip capture_flash, then advance the capture count.
	_app.cosmetics.items = [
		{"key": "capture_flash", "category": "CAPTURE_ANIMATION",
				"owned": true, "equipped": true},
		{"key": "victory_confetti", "category": "VICTORY_ANIMATION",
				"owned": true, "equipped": true},
	]
	screen._fx_seen_captures = 0
	var board_children: int = board.get_child_count()
	screen._state.goats_captured = 1
	screen._refresh_capture_fx()
	_check(board.get_child_count() == board_children + 1,
			"capture effect spawns on the board")
	_check(screen._fx_seen_captures == 1, "capture baseline advances")
	screen._refresh_capture_fx()
	_check(board.get_child_count() == board_children + 1,
			"capture effect does not repeat without a new capture")
	await create_timer(0.8).timeout
	_check(board.get_child_count() == board_children,
			"capture burst cleans itself up")

	# Victory FX: equipped style overlays the screen; empty style is a no-op.
	var screen_children: int = screen.get_child_count()
	screen._play_victory_fx()
	_check(screen.get_child_count() == screen_children + 1,
			"victory effect overlays the screen")
	_app.cosmetics.clear()
	screen._play_victory_fx()
	_check(screen.get_child_count() == screen_children + 1,
			"no victory effect without an equipped style")

	# Guarded helper: not terminal → no FX; online → celebrated elsewhere.
	screen._state.result = AaduPuliGameState.Result.NONE
	screen._play_victory_fx_if_won()
	_check(screen.get_child_count() == screen_children + 1,
			"no victory FX while the game is undecided")
	screen._state.result = AaduPuliGameState.Result.GOATS_WIN
	_app.cosmetics.items = [
		{"key": "victory_confetti", "category": "VICTORY_ANIMATION",
				"owned": true, "equipped": true},
	]
	screen._play_victory_fx_if_won()
	_check(screen.get_child_count() == screen_children + 2,
			"local human win plays the victory effect")
	screen._online_mode = true
	screen._play_victory_fx_if_won()
	_check(screen.get_child_count() == screen_children + 2,
			"online wins celebrate via the completion dialog instead")
	_app.cosmetics.clear()
	screen.queue_free()
	await _frame()


# --- Helpers --------------------------------------------------------------------

func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		printerr("FAIL: ", label)


func _frame() -> void:
	await process_frame


func _finish() -> void:
	print("PHASE12 COSMETIC VALIDATE: %d checks, %d failures"
			% [_checks, _failures])
	quit(1 if _failures > 0 else 0)

extends SceneTree
## Phase 15 offline suite: admin dashboard contract.
## Covers navigation wiring, the role-gated AdminService REST surface,
## the six-tab screen structure, main-menu entry gating, and the
## non-staff / signed-out fail-soft paths (no network, no local
## mutation, no fake rows).
## REST flows: tests/phase15/admin_e2e.gd
## Run: scripts/run_phase15_tests.sh

const MAIN_MENU_SCENE := "res://scenes/screens/main_menu.tscn"
const ADMIN_SCENE := "res://scenes/screens/admin.tscn"

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

	# Hermetic offline run: drop any stored session so the signed-out
	# paths are deterministic, and never hit a configured backend.
	if FileAccess.file_exists("user://session.json"):
		var user_dir := DirAccess.open("user://")
		if user_dir != null:
			user_dir.remove("session.json")

	_app = get_root().get_node_or_null("/root/App")
	if _app == null:
		print("FAIL: autoload App is missing")
		quit(1)
		return

	_test_wiring()
	_test_service_contract()
	_test_auth_gating()
	await _test_screen_offline()
	_finish()


# --- Wiring -----------------------------------------------------------------

func _test_wiring() -> void:
	_check(_app.navigation.has_screen(&"admin"),
			"navigation knows the admin screen")
	_check(_app.admin != null, "App instantiates the AdminService")
	var path: String = _app.navigation.SCREEN_PATHS.get(&"admin", "")
	_check(path == "res://scenes/screens/admin.tscn",
			"admin screen maps to admin.tscn")

	var menu: PackedScene = load(MAIN_MENU_SCENE)
	var menu_inst: Control = menu.instantiate()
	var admin_button: Node = menu_inst.get_node_or_null(
			"Margin/Content/AdminButton")
	_check(admin_button != null, "main menu has an Admin button")
	_check(admin_button is Button and admin_button.text == "Admin",
			"Admin button is labelled")
	_check(admin_button != null and not admin_button.visible,
			"Admin button ships hidden until a staff session")
	menu_inst.free()

	var scene: PackedScene = load(ADMIN_SCENE)
	_check(scene != null, "admin.tscn loads")
	var screen: Control = scene.instantiate()
	_check(screen.name == "Admin", "admin screen root node is named Admin")
	var required := [
		"Margin/Content/TopBar",
		"Margin/Content/HintLabel",
		"Margin/Content/AdminTabs",
		"Margin/Content/SearchRow",
		"Margin/Content/SearchRow/SearchEdit",
		"Margin/Content/SearchRow/SearchButton",
		"Margin/Content/FilterRow",
		"Margin/Content/Scroll/Column",
		"Margin/Content/Scroll/Column/ListRows",
		"Margin/Content/Scroll/Column/DetailRows",
	]
	for node_path in required:
		_check(screen.get_node_or_null(node_path) != null,
				"admin screen hosts %s" % node_path)
	var top_bar: Control = screen.get_node("Margin/Content/TopBar")
	_check(top_bar.get("show_back") == true, "admin screen offers a back button")
	_check(top_bar.get("show_coins") == false,
			"admin screen does not duplicate the coin display")
	screen.free()


# --- Service contract -------------------------------------------------------

func _test_service_contract() -> void:
	var methods := []
	for m in _app.admin.get_method_list():
		methods.append(str(m.get("name", "")))
	for required in ["stats", "players", "player", "player_wallet",
			"player_matches", "set_status", "matches", "finalize_match",
			"economy_summary", "transactions", "ad_shows", "purchases",
			"cosmetics", "update_cosmetic", "config_entries", "save_config",
			"audit_log"]:
		_check(methods.has(required), "AdminService exposes %s" % required)
	for forbidden in ["credit", "debit", "set_balance", "add_coins",
			"spend_coins", "grant", "mint", "set_rating", "apply_result",
			"complete_purchase", "ban_user", "mutate_config", "set_config",
			"apply_status", "finalize_locally"]:
		_check(not methods.has(forbidden),
				"no local platform-state writer '%s'" % forbidden)

	var script: Script = load("res://src/core/services/admin_service.gd")
	_check(script != null, "admin_service.gd loads")
	var screen_script: Script = load("res://src/ui/screens/admin.gd")
	_check(screen_script != null, "admin.gd loads")
	var statics := []
	for s in screen_script.get_script_constant_map():
		statics.append(str(s))
	for required in ["TABS", "GAME_FILTERS", "ECONOMY_FILTERS", "CONTENT_FILTERS"]:
		_check(statics.has(required), "admin screen defines %s" % required)


# --- Auth gating ------------------------------------------------------------

func _test_auth_gating() -> void:
	_check(AuthService.USER_FIELDS.has("role"),
			"role persists with the public user")
	_check(AuthService.USER_FIELDS.has("id") and AuthService.USER_FIELDS.has("username"),
			"core identity fields still persist")
	_check(_app.auth.has_method("role"), "AuthService exposes role()")
	_check(_app.auth.has_method("is_staff"), "AuthService exposes is_staff()")
	_check(_app.auth.role() == "USER", "signed-out role falls back to USER")
	_check(not _app.auth.is_staff(), "signed-out session is not staff")
	_check(not _app.auth.is_guest() or not _app.auth.is_staff(),
			"guests can never be staff")


# --- Screen offline ---------------------------------------------------------

func _test_screen_offline() -> void:
	var scene: PackedScene = load(ADMIN_SCENE)
	var screen: Control = scene.instantiate()
	get_root().add_child(screen)
	await _frame()
	await _frame()

	var hint: Label = screen.get_node("Margin/Content/HintLabel")
	_check(hint.visible, "non-staff session surfaces a hint")
	_check(hint.text.contains("Staff"),
			"hint demands staff access")

	var tabs: HBoxContainer = screen.get_node("Margin/Content/AdminTabs")
	_check(tabs.get_child_count() == 6, "six tab buttons render")
	_check(not tabs.visible, "tabs hide for non-staff sessions")
	var tab_names := []
	for child in tabs.get_children():
		tab_names.append(str(child.name))
	_check(tab_names == ["PlayersTab", "GamesTab", "EconomyTab",
			"ContentTab", "ConfigTab", "AuditTab"],
			"tab order players -> audit")

	var search_row: HBoxContainer = screen.get_node("Margin/Content/SearchRow")
	_check(not search_row.visible, "search hides for non-staff sessions")
	var filter_row: HBoxContainer = screen.get_node("Margin/Content/FilterRow")
	_check(not filter_row.visible, "filters hide for non-staff sessions")

	var list_rows: VBoxContainer = screen.get_node(
			"Margin/Content/Scroll/Column/ListRows")
	var detail_rows: VBoxContainer = screen.get_node(
			"Margin/Content/Scroll/Column/DetailRows")
	_check(list_rows.get_child_count() == 0,
			"no fake list rows render without staff rights")
	_check(detail_rows.get_child_count() == 0,
			"no fake detail rows render without staff rights")
	_check(String(screen.get("_tab")) == "players",
			"players tab is the default tab")

	# Pressing tabs / search as a non-staff user must stay local: the
	# screen re-shows the staff hint and renders nothing fake.
	var config_tab: Button = tabs.get_node("ConfigTab")
	config_tab.pressed.emit()
	await _frame()
	await _frame()
	_check(String(screen.get("_tab")) == "config", "config tab selects")
	_check(hint.visible and hint.text.contains("Staff"),
			"config tab keeps the staff hint")
	_check(list_rows.get_child_count() == 0,
			"config tab renders no rows without staff rights")

	var search_edit: LineEdit = screen.get_node(
			"Margin/Content/SearchRow/SearchEdit")
	search_edit.text = "wilson"
	var search_button: Button = screen.get_node(
			"Margin/Content/SearchRow/SearchButton")
	search_button.pressed.emit()
	await _frame()
	await _frame()
	_check(String(screen.get("_tab")) == "players",
			"search returns to the players tab")
	_check(hint.visible and hint.text.contains("Staff"),
			"search keeps the staff hint")
	_check(list_rows.get_child_count() == 0,
			"search renders no rows without staff rights")

	get_root().remove_child(screen)
	screen.free()


# --- Helpers ----------------------------------------------------------------

func _frame() -> void:
	await process_frame


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % label)


func _finish() -> void:
	print("VALIDATE: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)

extends SceneTree
## Phase 14 offline suite: competitive ranking contract.
## Covers navigation wiring, the server-owned rating service, the
## Bronze -> Master band table, and offline (fail-soft) rendering of
## the leaderboard and profile rank sections.
## REST flows: tests/phase14/rankings_e2e.gd
## Run: scripts/run_phase14_tests.sh

const MAIN_MENU_SCENE := "res://scenes/screens/main_menu.tscn"
const PROFILE_SCENE := "res://scenes/screens/profile.tscn"
const LEADERBOARD_SCENE := "res://scenes/screens/leaderboard.tscn"

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
	_test_rank_bands()
	_test_service_contract()
	await _test_leaderboard_offline()
	await _test_profile_offline()
	_finish()


# --- Wiring -----------------------------------------------------------------

func _test_wiring() -> void:
	_check(_app.navigation.has_screen(&"leaderboard"),
			"navigation knows the leaderboard screen")
	_check(_app.rankings != null, "App instantiates the RankingService")

	var menu: PackedScene = load(MAIN_MENU_SCENE)
	var menu_inst: Control = menu.instantiate()
	var rankings_button: Node = menu_inst.get_node_or_null(
			"Margin/Content/RankingsButton")
	_check(rankings_button != null, "main menu has a Rankings button")
	_check(rankings_button is Button and rankings_button.text == "Rankings",
			"Rankings button is labelled")
	menu_inst.free()

	var profile: PackedScene = load(PROFILE_SCENE)
	var profile_inst: Control = profile.instantiate()
	_check(profile_inst.get_node_or_null("Margin/Content/RankTitle") != null,
			"profile has the Competitive heading")
	_check(profile_inst.get_node_or_null("Margin/Content/RankRows") != null,
			"profile has the rank rows container")
	profile_inst.free()

	var board: PackedScene = load(LEADERBOARD_SCENE)
	var board_inst: Control = board.instantiate()
	_check(board_inst.get_node_or_null("Margin/Content/TopBar") != null,
			"leaderboard has a TopBar")
	_check(board_inst.get_node_or_null("Margin/Content/SeasonLabel") != null,
			"leaderboard has a season label")
	_check(board_inst.get_node_or_null("Margin/Content/GameTabs") != null,
			"leaderboard has game tabs")
	_check(board_inst.get_node_or_null(
			"Margin/Content/Scroll/Column/StandingPanel/StandingBody/StandingTitle") != null,
			"leaderboard has the my-standing card")
	_check(board_inst.get_node_or_null(
			"Margin/Content/Scroll/Column/BoardPanel/BoardBody/BoardRows") != null,
			"leaderboard has the standings board")
	_check(board_inst.get_node_or_null(
			"Margin/Content/Scroll/Column/ResultsPanel/ResultsBody/ResultRows") != null,
			"leaderboard has the recent results list")
	board_inst.free()


# --- Rank bands -------------------------------------------------------------

func _test_rank_bands() -> void:
	_check(RankingService.RATED_GAME_KEYS.size() == 3, "three rated games")
	_check(RankingService.RATED_GAME_KEYS.has("aadu-puli-aattam"),
			"aadu-puli-aattam is rated")
	_check(RankingService.RATED_GAME_KEYS.has("solah-seedi"),
			"solah-seedi is rated")
	_check(RankingService.RATED_GAME_KEYS.has("nine-mens-morris"),
			"nine-mens-morris is rated")
	_check(RankingService.GAME_TITLES.get("solah-seedi", "") == "16 Soldiers",
			"Solah Seedi displays as 16 Soldiers")

	_check(RankingService.RANK_TIERS.size() == 6, "six rank tiers")
	var keys := []
	var previous := -1
	for tier in RankingService.RANK_TIERS:
		keys.append(str(tier["key"]))
		var minimum := int(tier["min"])
		_check(minimum > previous,
				"tier '%s' threshold strictly increases" % str(tier["key"]))
		_check(str(tier["name"]) == str(tier["name"]).capitalize(),
				"tier '%s' has a display name" % str(tier["key"]))
		previous = minimum
	_check(keys == ["bronze", "silver", "gold", "platinum", "diamond", "master"],
			"rank order bronze -> master")

	var boundaries := {
		0: "Bronze", 999: "Bronze", 1099: "Bronze", 1100: "Silver",
		1299: "Silver", 1300: "Gold", 1499: "Gold", 1500: "Platinum",
		1699: "Platinum", 1700: "Diamond", 1899: "Diamond",
		1900: "Master", 3000: "Master",
	}
	for rating in boundaries:
		var expected: String = boundaries[rating]
		_check(RankingService.rank_title(int(rating)) == expected,
				"rating %d maps to %s" % [int(rating), expected])
		var info: Dictionary = RankingService.rank_of(int(rating))
		_check(str(info.get("name", "")) == expected,
				"rank_of(%d) carries the name" % int(rating))
		_check(str(info.get("key", "")) == expected.to_lower(),
				"rank_of(%d) carries the tier key" % int(rating))


# --- Service contract -------------------------------------------------------

func _test_service_contract() -> void:
	var methods := []
	for m in _app.rankings.get_method_list():
		methods.append(str(m.get("name", "")))
	for required in ["summary", "leaderboard", "history", "rank_of", "rank_title"]:
		_check(methods.has(required), "RankingService exposes %s" % required)
	for forbidden in ["set_rating", "apply_result", "record_win", "adjust",
			"submit_result", "set_rank", "add_rating"]:
		_check(not methods.has(forbidden),
				"no local rating writer '%s'" % forbidden)

	var script: Script = load("res://src/core/services/ranking_service.gd")
	var statics := []
	for s in script.get_script_constant_map():
		statics.append(str(s))
	for required in ["RATED_GAME_KEYS", "GAME_TITLES", "RANK_TIERS"]:
		_check(statics.has(required), "RankingService defines %s" % required)


# --- Leaderboard offline ----------------------------------------------------

func _test_leaderboard_offline() -> void:
	var board: PackedScene = load(LEADERBOARD_SCENE)
	var screen: Control = board.instantiate()
	get_root().add_child(screen)
	await _frame()
	await _frame()

	var tabs: Node = screen.get_node("Margin/Content/GameTabs")
	_check(tabs.get_child_count() == 3, "three game tabs render")

	var season: Label = screen.get_node("Margin/Content/SeasonLabel")
	_check(season.text.begins_with("Season:"), "season label carries a prefix")
	_check(season.text.contains("\u2014"),
			"offline season label falls back to an em dash")

	var standing_title: Label = screen.get_node(
			"Margin/Content/Scroll/Column/StandingPanel/StandingBody/StandingTitle")
	_check(standing_title.text.contains("standing"),
			"standing card is titled")

	var standing_rows: HBoxContainer = screen.get_node(
			"Margin/Content/Scroll/Column/StandingPanel/StandingBody/StandingRow")
	_check(standing_rows.get_child_count() >= 1, "signed-out standing renders")
	_check(_row_text(standing_rows).contains("Sign in"),
			"signed-out standing prompts sign in")

	var result_rows: VBoxContainer = screen.get_node(
			"Margin/Content/Scroll/Column/ResultsPanel/ResultsBody/ResultRows")
	_check(result_rows.get_child_count() >= 1, "offline results render a note")
	_check(_row_text(result_rows).contains("Sign in"),
			"signed-out results prompt sign in")

	var hint: Label = screen.get_node("Margin/Content/HintLabel")
	_check(hint.visible, "offline standings failure surfaces in the hint")

	var board_rows: VBoxContainer = screen.get_node(
			"Margin/Content/Scroll/Column/BoardPanel/BoardBody/BoardRows")
	_check(board_rows.get_child_count() >= 1,
			"offline board renders a placeholder row")
	_check(_row_text(board_rows).contains("Standings unavailable")
			or _row_text(board_rows).contains("offline"),
			"offline board explains itself")

	# Tab selection swaps the active game key without a scene change.
	var tabs_array: Array = tabs.get_children()
	_check(tabs_array.size() == 3, "tab buttons enumerated")
	var aadu: Button = tabs.get_node_or_null("AaduPuliTab")
	var soldiers: Button = tabs.get_node_or_null("SoldiersTab")
	var morris: Button = tabs.get_node_or_null("MorrisTab")
	_check(aadu != null and soldiers != null and morris != null,
			"three named tab buttons exist")
	soldiers.pressed.emit()
	await _frame()
	await _frame()
	_check(String(screen.get("_game_key")) == "solah-seedi",
			"soldiers tab selects solah-seedi")
	_check(soldiers.button_pressed, "soldiers tab shows pressed state")
	_check(not aadu.button_pressed, "aadu tab releases pressed state")
	morris.pressed.emit()
	await _frame()
	await _frame()
	_check(String(screen.get("_game_key")) == "nine-mens-morris",
			"morris tab selects nine-mens-morris")
	aadu.pressed.emit()
	await _frame()
	await _frame()
	_check(String(screen.get("_game_key")) == "aadu-puli-aattam",
			"aadu tab reselects the default game")

	get_root().remove_child(screen)
	screen.free()


# --- Profile offline --------------------------------------------------------

func _test_profile_offline() -> void:
	var profile: PackedScene = load(PROFILE_SCENE)
	var screen: Control = profile.instantiate()
	get_root().add_child(screen)
	await _frame()
	await _frame()

	var rank_rows: VBoxContainer = screen.get_node("Margin/Content/RankRows")
	_check(rank_rows.get_child_count() >= 1, "signed-out profile rank rows render")
	_check(_row_text(rank_rows).contains("Sign in"),
			"signed-out profile prompts sign in")

	get_root().remove_child(screen)
	screen.free()


# --- Helpers ----------------------------------------------------------------

func _row_text(container: Node) -> String:
	var out := ""
	for child in container.get_children():
		if child is Label:
			out += "%s " % child.text
		else:
			out += _row_text(child)
	return out


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

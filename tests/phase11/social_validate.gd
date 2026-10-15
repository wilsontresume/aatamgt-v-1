extends SceneTree
## Phase 11 social suite (offline): screen structure, share text,
## navigation wiring and abuse-prevention guards. No server involved —
## REST paths are exercised by tests/phase11/social_e2e.gd.
##
## Run: godot --headless --path . -s res://tests/phase11/social_validate.gd
## Exit code 0 = all checks passed.

const FRIENDS_SCENE := "res://scenes/screens/friends.tscn"
const CHALLENGE_SCENE := "res://scenes/screens/challenge.tscn"
const HISTORY_SCENE := "res://scenes/screens/history.tscn"

const FRIENDS_NODES := [
	"Margin/Content/TopBar",
	"Margin/Content/AddPanel/AddBody/AddRow/UsernameField",
	"Margin/Content/AddPanel/AddBody/AddRow/AddButton",
	"Margin/Content/AddPanel/AddBody/AddHint",
	"Margin/Content/IncomingPanel/IncomingBody/IncomingList",
	"Margin/Content/IncomingPanel/IncomingBody/IncomingHint",
	"Margin/Content/FriendsPanel/FriendsBody/FriendsList",
	"Margin/Content/FriendsPanel/FriendsBody/FriendsHint",
	"Margin/Content/ChallengesPanel/ChallengesBody/ChallengeList",
	"Margin/Content/ChallengesPanel/ChallengesBody/ChallengeHint",
	"Margin/Content/BlockedPanel/BlockedBody/BlockedList",
	"Margin/Content/BlockedPanel/BlockedBody/BlockedHint",
	"Margin/Content/CodePanel/CodeBody/CodeRow/CodeField",
	"Margin/Content/CodePanel/CodeBody/CodeRow/OpenButton",
	"Margin/Content/CodePanel/CodeBody/CodeHint",
]
const CHALLENGE_NODES := [
	"Margin/Content/TopBar",
	"Margin/Content/ChoosePanel/ChooseBody/ChooseTitle",
	"Margin/Content/ChoosePanel/ChooseBody/ChooseList",
	"Margin/Content/ChoosePanel/ChooseBody/ChooseHint",
	"Margin/Content/IncomingPanel/IncomingBody/IncomingLabel",
	"Margin/Content/IncomingPanel/IncomingBody/ExpiresLabel",
	"Margin/Content/IncomingPanel/IncomingBody/IncomingActions/AcceptButton",
	"Margin/Content/IncomingPanel/IncomingBody/IncomingActions/DeclineButton",
	"Margin/Content/CodePanel/CodeBody/CodeLabel",
	"Margin/Content/CodePanel/CodeBody/StatusLabel",
	"Margin/Content/SharePanel/ShareBody/ShareText",
	"Margin/Content/SharePanel/ShareBody/ShareRow/WhatsappButton",
	"Margin/Content/SharePanel/ShareBody/ShareRow/CopyButton",
	"Margin/Content/ExtraRow/CancelButton",
]
const HISTORY_NODES := [
	"Margin/Content/TopBar",
	"Margin/Content/HistoryPanel/HistoryBody/HistoryList",
	"Margin/Content/HistoryPanel/HistoryBody/HistoryHint",
	"Margin/Content/ReloadRow/ReloadButton",
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

	# Fresh auth state: signed out, so screens never hit the network here.
	if FileAccess.file_exists("user://session.json"):
		var user_dir := DirAccess.open("user://")
		if user_dir != null:
			user_dir.remove("session.json")

	_test_service_wiring()
	_test_share_text()
	_test_code_validation()
	_test_navigation_paths()
	await _test_scene_structure(FRIENDS_SCENE, "Friends", FRIENDS_NODES)
	await _test_scene_structure(CHALLENGE_SCENE, "Challenge", CHALLENGE_NODES)
	await _test_scene_structure(HISTORY_SCENE, "History", HISTORY_NODES)
	await _test_no_chat()
	await _test_main_menu_entry_points()
	await _test_choose_game_view()
	_finish()


# --- Service wiring --------------------------------------------------------

func _test_service_wiring() -> void:
	_check(_app.social is SocialService, "App.social is wired")
	_check(_app.social.get_script() != null, "App.social has a script")


# --- Share text (the WhatsApp message) -------------------------------------

func _test_share_text() -> void:
	var msg := SocialService.challenge_message(
			"Wilson", "Aadu Puli Aattam", "K7M2QX9B")
	var expected := "AATAMGT challenge:\n" \
			+ "Wilson challenged you to Aadu Puli Aattam.\n" \
			+ "Join the match.\n" \
			+ "\nCode: K7M2QX9B"
	_check(msg == expected, "share text matches the product example exactly")
	_check(msg.begins_with("AATAMGT challenge:\nWilson challenged you to "
			+ "Aadu Puli Aattam.\nJoin the match."),
			"share text leads with the example's three lines")
	_check(msg.contains("\n\nCode: K7M2QX9B"),
			"share text appends the entry code")

	var linked := SocialService.challenge_message(
			"Wilson", "Solah Seedi", "AB12CD34", "https://e.example/play")
	_check(linked.ends_with("\nhttps://e.example/play?challenge=AB12CD34"),
			"optional link line carries the challenge code")
	var linked_query := SocialService.challenge_message(
			"Wilson", "Solah Seedi", "AB12CD34", "https://e.example/play?a=1")
	_check(linked_query.ends_with("\nhttps://e.example/play?a=1&challenge=AB12CD34"),
			"link line uses & when the base already has a query")

	var url := SocialService.whatsapp_url(msg)
	_check(url.begins_with("https://wa.me/?text="),
			"whatsapp share targets wa.me")
	_check(not url.contains(" "), "whatsapp url is fully percent-encoded")
	_check(url.contains("AATAMGT%20challenge%3A%0A"),
			"whatsapp url encodes the message head")


# --- Code validation (client-side guard) ------------------------------------

func _test_code_validation() -> void:
	_check(SocialService.is_valid_code("K7M2QX9B"), "valid 8-char code accepted")
	_check(SocialService.is_valid_code("  k7m2qx9b  "),
			"lowercase/space input normalised")
	_check(SocialService.is_valid_code("ABCD"), "shortest valid code accepted")
	_check(not SocialService.is_valid_code(""), "empty code rejected")
	_check(not SocialService.is_valid_code("AB"), "too-short code rejected")
	_check(not SocialService.is_valid_code("AB!D"), "punctuation rejected")
	_check(not SocialService.is_valid_code("AB12-XY"), "hyphen rejected")
	_check(not SocialService.is_valid_code("THISISOVER16CHARS"),
			"over-long code rejected")


# --- Navigation -------------------------------------------------------------

func _test_navigation_paths() -> void:
	for screen_id in [&"friends", &"challenge", &"history"]:
		_check(_app.navigation.has_screen(screen_id),
				"navigation knows screen '%s'" % screen_id)
		var path: String = NavigationService.SCREEN_PATHS[screen_id]
		_check(ResourceLoader.exists(path), "scene exists: %s" % path)
	_check(SocialService.screen_for("aadu-puli-aattam") == &"aadu_puli",
			"game key maps to Aadu Puli screen")
	_check(SocialService.screen_for("solah-seedi") == &"solah_seedi",
			"game key maps to Solah Seedi screen")
	_check(SocialService.screen_for("nine-mens-morris") == &"nine_mens_morris",
			"game key maps to Morris screen")
	_check(SocialService.screen_for("unknown-game") == &"",
			"unknown game key maps to no screen")
	_check(SocialService.game_title("aadu-puli-aattam") == "Aadu Puli Aattam",
			"game title lookup")
	_check(SocialService.game_title("mystery") == "mystery",
			"unknown game title falls back to the key")


# --- Scene structure --------------------------------------------------------

func _test_scene_structure(path: String, root_name: String,
		node_paths: Array) -> void:
	var scene: PackedScene = load(path)
	_check(scene != null, "scene loads: %s" % path)
	if scene == null:
		return
	var screen: Control = scene.instantiate()
	_check(screen.name == root_name, "%s root node named %s" % [path, root_name])
	get_root().add_child(screen)
	await _frame()
	for node_path in node_paths:
		var node: Node = screen.get_node_or_null(node_path)
		_check(node != null, "%s has %s" % [root_name, node_path])
	screen.queue_free()
	await _frame()


func _test_no_chat() -> void:
	# Phase 11 ships no text chat — scan the social screens for any
	# chat-named node so one can never sneak in unnoticed.
	for path in [FRIENDS_SCENE, CHALLENGE_SCENE, HISTORY_SCENE]:
		var screen: Node = (load(path) as PackedScene).instantiate()
		get_root().add_child(screen)
		await _frame()
		_check(not _find_named(screen, "chat"),
				"no chat UI in %s" % path)
		_check(not _find_named(screen, "messageinput"),
				"no message input in %s" % path)
		screen.queue_free()
		await _frame()


func _find_named(node: Node, needle: String) -> bool:
	for child in node.get_children():
		if String(child.name).to_lower().contains(needle):
			return true
		if _find_named(child, needle):
			return true
	return false


# --- Main menu entry points -------------------------------------------------

func _test_main_menu_entry_points() -> void:
	var scene: PackedScene = load("res://scenes/screens/main_menu.tscn")
	var menu: Control = scene.instantiate()
	get_root().add_child(menu)
	await _frame()
	var friends_button: Button = menu.get_node_or_null(
			"Margin/Content/FeaturesRow/FriendsButton")
	var history_button: Button = menu.get_node_or_null(
			"Margin/Content/FeaturesRow/HistoryButton")
	_check(friends_button != null, "main menu has a Friends button")
	_check(history_button != null, "main menu has a History button")
	if friends_button != null and history_button != null:
		_app.social.pending = {}
		friends_button.pressed.emit()
		_check(_app.navigation.current == &"friends",
				"Friends button navigates to friends screen")
		history_button.pressed.emit()
		_check(_app.navigation.current == &"history",
				"History button navigates to history screen")
	menu.queue_free()
	await _frame()
	_app.navigation.current = &""


# --- Challenge screen: choose-game view (pending hand-off) -------------------

func _test_choose_game_view() -> void:
	_app.social.set_pending({"mode": "choose_game", "invitee": "wilson"})
	var screen: Control = (load(CHALLENGE_SCENE) as PackedScene).instantiate()
	get_root().add_child(screen)
	await _frame()
	var choose: Control = screen.get_node("Margin/Content/ChoosePanel")
	var incoming: Control = screen.get_node("Margin/Content/IncomingPanel")
	var code_panel: Control = screen.get_node("Margin/Content/CodePanel")
	_check(choose.visible, "choose-game panel opens for pending challenge")
	_check(not incoming.visible, "incoming panel stays hidden")
	_check(not code_panel.visible, "code panel stays hidden until created")
	var title: Label = screen.get_node(
			"Margin/Content/ChoosePanel/ChooseBody/ChooseTitle")
	_check(title.text == "Challenge wilson to",
			"choose title names the invitee (got: %s)" % title.text)
	var list: VBoxContainer = screen.get_node(
			"Margin/Content/ChoosePanel/ChooseBody/ChooseList")
	_check(list.get_child_count() == 3, "all three games are offered")
	var titles: Array = []
	for child in list.get_children():
		if child is Button:
			titles.append((child as Button).text)
	_check(titles.has("Aadu Puli Aattam") and titles.has("Solah Seedi")
			and titles.has("Nine Men's Morris"),
			"game buttons show the human titles")
	_check(_app.social.pending.is_empty(),
			"pending hand-off was consumed exactly once")

	# Empty hand-off: the screen must not crash, it shows a hint instead.
	screen.queue_free()
	await _frame()
	var fallback: Control = (load(CHALLENGE_SCENE) as PackedScene).instantiate()
	get_root().add_child(fallback)
	await _frame()
	var hint: Label = fallback.get_node(
			"Margin/Content/ChoosePanel/ChooseBody/ChooseHint")
	_check(hint.visible and hint.text.contains("Friends"),
			"no pending challenge shows a guidance hint")
	fallback.queue_free()
	await _frame()


# --- Harness ----------------------------------------------------------------

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
	print("SOCIAL VALIDATE: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)

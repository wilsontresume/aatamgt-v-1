extends SceneTree
## Phase 12 end-to-end: the cosmetic inventory on a live backend —
## registration (1000-coin welcome), inventory defaults, claim a free
## cosmetic, buy a premium one (coin ledger moves), dev-only grant,
## equip switching within a category, and the equipped styles reaching
## the board and profile avatar.
##
## Run through scripts/run_phase12_e2e.sh, which boots the HTTPS
## server and exports:
##   AATAMGT_API_URL  e.g. https://127.0.0.1:3443
##   AATAMGT_CA_CERT  path to the server's dev certificate
##
## Exit code 0 = all checks passed.

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
	_app = get_root().get_node_or_null("/root/App")
	_check(_app != null, "autoload App is registered")
	if _app == null:
		_finish()
		return
	_check(_app.cosmetics is CosmeticService, "App exposes the CosmeticService")
	var base_url := OS.get_environment("AATAMGT_API_URL").strip_edges()
	_check(not base_url.is_empty(), "AATAMGT_API_URL is provided")
	_check(_app.api_client.is_configured(), "api client configured from environment")
	await _check_server_reachable()
	if _failures > 0:
		_finish()
		return

	await _test_register_and_open_inventory()
	if _failures > 0:
		_finish()
		return
	await _test_default_inventory_state()
	await _test_claim_free_cosmetics()
	await _test_purchase_premium_cosmetic()
	await _test_dev_grant()
	await _test_equip_switching()
	await _test_persistence_after_reload()
	await _test_equipped_styles_reach_the_app()

	_finish()


# --- Sections ------------------------------------------------------------------

func _test_register_and_open_inventory() -> void:
	var username := "cos%d%d" % [Time.get_ticks_msec(), randi() % 10000]
	var reg: Dictionary = await _app.auth.register(username, "Cos12345!")
	_check(reg.ok, "player registers for the welcome bonus (%s)" % _msg(reg))
	if not reg.ok:
		return
	var got_coins := await _wait_until(
			func() -> bool: return _app.coins.get_balance() == 1000, 8.0)
	_check(got_coins, "registration bonus lands (1000 coins)")

	var main_scene: PackedScene = load("res://scenes/main.tscn")
	_check(main_scene != null, "main.tscn loads")
	if main_scene == null:
		return
	_main = main_scene.instantiate()
	get_root().add_child(_main)
	var reached := await _wait_until(
			func() -> bool: return _app.navigation.current == &"main_menu", 8.0)
	_check(reached, "splash hands off to the main menu")

	var menu := _screen_named("MainMenu")
	_check(menu != null, "main menu is on screen")
	if menu == null:
		return
	var button: Button = menu.get_node_or_null("Margin/Content/InventoryButton")
	_check(button != null, "main menu has an Inventory button")
	if button == null:
		return
	button.pressed.emit()
	_check(_app.navigation.current == &"inventory",
			"Inventory button navigates to the inventory")
	var screen := _screen_named("Inventory")
	var sections_ready := await _wait_until(
			func() -> bool: return _section_count(_screen_named("Inventory")) == 5,
			10.0)
	_check(screen != null, "inventory screen is on screen")
	_check(sections_ready, "five category sections render")
	_check(_app.cosmetics.dev_grants_enabled,
			"server exposes dev grants outside production")


func _test_default_inventory_state() -> void:
	var screen := _screen_named("Inventory")
	if screen == null:
		return
	_check(_count_buttons(screen, "Equipped") == 5,
			"one equipped default per category")
	_check(_count_buttons(screen, "Claim") == 5,
			"every free non-default starts claimable")
	_check(_count_buttons(screen, "Buy") == 5,
			"every premium item starts purchasable")
	_check(_count_buttons(screen, "Grant") == 10,
			"dev grants appear on the ten unowned rows")
	_check(_count_labels(screen, "Equipped") == 5,
			"five equipped state chips")
	_check(_count_labels(screen, "Locked") == 10,
			"ten locked state chips")
	_check(_count_labels(screen, "Owned") == 0,
			"no owned-but-unequipped items initially")


func _test_claim_free_cosmetics() -> void:
	var screen := _screen_named("Inventory")
	if screen == null:
		return
	var row := _find_row(screen, "Woodland Board")
	_check(row != null, "woodland board row exists")
	if row == null:
		return
	var claim: Button = _find_button(row, "Claim")
	_check(claim != null, "woodland board shows Claim")
	if claim == null:
		return
	claim.pressed.emit()
	var claimed := await _wait_until(
			func() -> bool: return _count_buttons(_screen_named("Inventory"), "Equip") >= 1,
			10.0)
	_check(claimed, "claiming the free board succeeds")
	screen = _screen_named("Inventory")
	_check(_count_labels(screen, "Owned") == 1, "claimed item shows as owned")
	_check(_count_labels(screen, "Locked") == 9, "one fewer locked item")
	_check(_count_buttons(screen, "Claim") == 4, "one fewer claim button")

	# Second free claim: the profile picture used by the avatar test.
	row = _find_row(screen, "Sunset Avatar")
	_check(row != null, "sunset avatar row exists")
	if row == null:
		return
	claim = _find_button(row, "Claim")
	if claim == null:
		_check(false, "sunset avatar shows Claim")
		return
	claim.pressed.emit()
	var claimed2 := await _wait_until(
			func() -> bool: return _count_labels(_screen_named("Inventory"), "Owned") >= 2,
			10.0)
	_check(claimed2, "claiming the free profile picture succeeds")


func _test_purchase_premium_cosmetic() -> void:
	var screen := _screen_named("Inventory")
	if screen == null:
		return
	var before: int = _app.coins.get_balance()
	_check(before == 1000, "balance is 1000 before the purchase")
	var row := _find_row(screen, "Midnight Board")
	_check(row != null, "midnight board row exists")
	if row == null:
		return
	var buy: Button = _find_button(row, "Buy")
	_check(buy != null, "midnight board shows Buy")
	if buy == null:
		return
	buy.pressed.emit()
	var bought := await _wait_until(
			func() -> bool: return _app.coins.get_balance() == before - 250, 10.0)
	_check(bought, "purchase debits 250 coins through the ledger")
	screen = _screen_named("Inventory")
	_check(_count_labels(screen, "Owned") == 3, "purchased item shows as owned")
	_check(_count_buttons(screen, "Buy") == 4, "one fewer buy button")
	_check(_count_buttons(screen, "Grant") == 7, "grant disappears after purchase")


func _test_dev_grant() -> void:
	var screen := _screen_named("Inventory")
	if screen == null:
		return
	var before: int = _app.coins.get_balance()
	var row := _find_row(screen, "Fireworks")
	_check(row != null, "fireworks row exists")
	if row == null:
		return
	var grant: Button = _find_button(row, "Grant")
	_check(grant != null, "fireworks shows the dev Grant button")
	if grant == null:
		return
	grant.pressed.emit()
	var granted := await _wait_until(
			func() -> bool: return _count_labels(_screen_named("Inventory"), "Owned") >= 4,
			10.0)
	_check(granted, "dev grant owns the item without a purchase")
	screen = _screen_named("Inventory")
	_check(_app.coins.get_balance() == before,
			"dev grant never moves coins")
	_check(_count_buttons(screen, "Grant") == 6, "grant button disappears once owned")
	_check(_count_buttons(screen, "Equip") == 4,
			"four items are ready to equip (claimed/granted, not equipped)")


func _test_equip_switching() -> void:
	var screen := _screen_named("Inventory")
	if screen == null:
		return
	var row := _find_row(screen, "Woodland Board")
	if row == null:
		_check(false, "woodland row available for equip")
		return
	var equip: Button = _find_button(row, "Equip")
	_check(equip != null, "owned woodland board shows Equip")
	if equip == null:
		return
	equip.pressed.emit()
	var equipped := await _wait_until(_woodland_is_equipped, 10.0)
	_check(equipped, "woodland board becomes equipped")
	screen = _screen_named("Inventory")
	var classic_text := _row_text(_find_row(screen, "Classic Board"))
	_check(classic_text.contains("Owned") and not classic_text.contains("Equipped"),
			"classic board drops back to owned")
	var section := _section(screen, "Board skins")
	_check(section != null, "board skins section found")
	if section != null:
		_check(_count_labels(section, "Equipped") == 1,
				"exactly one equipped board in the section")
		_check(_count_labels(section, "Locked") == 0,
				"no locked boards remain in the section")


func _test_persistence_after_reload() -> void:
	var screen := _screen_named("Inventory")
	if screen == null:
		return
	await _reload_screen(screen)
	screen = _screen_named("Inventory")
	_check(_count_labels(screen, "Equipped") == 5,
			"equipped state survives a refresh (server-owned)")
	_check(_count_labels(screen, "Owned") == 4,
			"owned state survives a refresh (server-owned)")
	_check(_count_labels(screen, "Locked") == 6,
			"locked state survives a refresh (server-owned)")
	_check(_app.coins.get_balance() == 750, "balance still 750 after reload")


func _test_equipped_styles_reach_the_app() -> void:
	# Equip the claimed profile picture so the avatar check observes it.
	var inventory := _screen_named("Inventory")
	if inventory != null:
		var row := _find_row(inventory, "Sunset Avatar")
		var equip: Button = _find_button(row, "Equip") if row != null else null
		if equip != null:
			equip.pressed.emit()
		var pfp_equipped := await _wait_until(_sunset_is_equipped, 10.0)
		_check(pfp_equipped, "claimed profile picture can be equipped")

	_app.navigation.go(&"aadu_puli")
	var game_ready := await _wait_until(
			func() -> bool: return _screen_named("AaduPuliScreen") != null, 6.0)
	_check(game_ready, "aadu puli screen opens")
	var game := _screen_named("AaduPuliScreen")
	if game != null:
		var board: Variant = game.get_node("Margin/Content/Board")
		_check(board.skin.get("bg", Color(0, 0, 0)) == Color("1d2a1e"),
				"equipped woodland palette reaches the game board")

	_app.navigation.go(&"profile")
	var profile_ready := await _wait_until(
			func() -> bool: return _screen_named("Profile") != null, 6.0)
	_check(profile_ready, "profile screen opens")
	var profile := _screen_named("Profile")
	if profile != null:
		var avatar: Variant = profile.get_node(
				"Margin/Content/ProfileCenter/ProfileDisplay/Avatar")
		_check(avatar._style == CosmeticService.pfp_style("pfp_sunset"),
				"equipped profile picture reaches the profile avatar")
		_check(avatar._frame.is_empty(),
				"no frame equipped — avatar stays unframed")


# --- Helpers --------------------------------------------------------------------

func _check_server_reachable() -> void:
	var res: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_GET, "/profiles/me")
	var transport_failure: bool = (res.error_kind == ApiClient.ErrorKind.NETWORK
			or res.error_kind == ApiClient.ErrorKind.SERVER_UNAVAILABLE)
	_check(not transport_failure, "backend reachable over HTTPS (%s)" % _msg(res))
	_check(_app.network.get_status() == NetworkService.Status.CONNECTED,
			"network reports online after the reachability call")


func _screen_named(root_name: String) -> Control:
	if _main == null:
		return null
	var container: Control = _main.get_node("ScreenLayer/ScreenContainer")
	for child in container.get_children():
		if child.name == root_name:
			return child
	return null


func _section_count(screen: Control) -> int:
	if screen == null:
		return -1
	var sections: Node = screen.get_node_or_null("Margin/Content/Scroll/Sections")
	if sections == null:
		return -1
	return sections.get_child_count()


func _section(screen: Control, title: String) -> Control:
	if screen == null:
		return null
	var sections: Node = screen.get_node_or_null("Margin/Content/Scroll/Sections")
	if sections == null:
		return null
	for panel in sections.get_children():
		var body: Node = panel.get_child(0)
		if body.get_child_count() > 0 and body.get_child(0) is Label \
				and (body.get_child(0) as Label).text == title:
			return panel
	return null


## Finds the item row (HBox) whose labels include the exact item name.
func _find_row(root: Node, label_text: String) -> Node:
	for child in root.get_children():
		if child is HBoxContainer:
			var parts := PackedStringArray()
			_collect_labels(child, parts)
			if parts.has(label_text):
				return child
		var nested := _find_row(child, label_text)
		if nested != null:
			return nested
	return null


func _row_text(row: Node) -> String:
	if row == null:
		return ""
	var parts := PackedStringArray()
	_collect_all(row, parts)
	return " | ".join(parts)


func _count_buttons(screen: Node, text: String) -> int:
	var found := []
	_collect_buttons(screen, found)
	var count := 0
	for entry in found:
		if str(entry) == text:
			count += 1
	return count


func _count_labels(screen: Node, text: String) -> int:
	if screen == null:
		return -1
	var parts := PackedStringArray()
	_collect_labels(screen, parts)
	var count := 0
	for entry in parts:
		if str(entry) == text:
			count += 1
	return count


func _collect_labels(node: Node, parts: PackedStringArray) -> void:
	for child in node.get_children():
		if child is Label:
			parts.append((child as Label).text)
		else:
			_collect_labels(child, parts)


func _collect_all(node: Node, parts: PackedStringArray) -> void:
	for child in node.get_children():
		if child is Label:
			parts.append((child as Label).text)
		elif child is Button:
			parts.append((child as Button).text)
		else:
			_collect_all(child, parts)


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


func _woodland_is_equipped() -> bool:
	var fresh := _screen_named("Inventory")
	if fresh == null:
		return false
	return _row_text(_find_row(fresh, "Woodland Board")).contains("Equipped")


func _sunset_is_equipped() -> bool:
	var fresh := _screen_named("Inventory")
	if fresh == null:
		return false
	return _row_text(_find_row(fresh, "Sunset Avatar")).contains("Equipped")


## Waits for an in-flight screen reload, then runs a fresh one.
func _reload_screen(screen: Node) -> void:
	while bool(screen.get("_busy")):
		await _frame()
	await screen.reload()


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


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		printerr("FAIL: ", label)


func _finish() -> void:
	print("COSMETICS E2E: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)

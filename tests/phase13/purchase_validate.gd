extends SceneTree
## Phase 13 offline suite: in-app purchase contract.
## Covers navigation wiring, the seven platform product IDs, the
## billing-provider abstraction, the no-local-grant/no-price rules,
## and offline (fail-soft) rendering of the shop screen.
## REST flows: tests/phase13/purchases_e2e.gd
## Run: scripts/run_phase13_tests.sh

const MAIN_MENU_SCENE := "res://scenes/screens/main_menu.tscn"
const SHOP_SCENE := "res://scenes/screens/shop.tscn"
const SHOP_SERVICE_PATH := "res://src/core/services/shop_service.gd"
const SHOP_SCREEN_PATH := "res://src/ui/screens/shop.gd"

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
	_test_product_contract()
	_test_price_rule()
	_test_billing_contract()
	await _test_service_offline()
	await _test_shop_screen_offline()
	_finish()


# --- Wiring -----------------------------------------------------------------

func _test_wiring() -> void:
	_check(_app.navigation.has_screen(&"shop"),
			"navigation knows the shop screen")
	_check(_app.shop != null, "App instantiates the ShopService")

	var menu: PackedScene = load(MAIN_MENU_SCENE)
	var menu_inst: Control = menu.instantiate()
	var shop_button: Node = menu_inst.get_node_or_null(
			"Margin/Content/FeaturesRow/ShopButton")
	_check(shop_button != null, "main menu has a Shop button")
	_check(shop_button is Button and shop_button.caption == "Shop",
			"Shop button is labelled")
	menu_inst.free()

	var shop: PackedScene = load(SHOP_SCENE)
	var shop_inst: Control = shop.instantiate()
	_check(shop_inst.get_node_or_null("Margin/Content/TopBar") != null,
			"shop has a TopBar")
	_check(shop_inst.get_node_or_null("Margin/Content/Scroll/Column/CoinRows") != null,
			"shop has the coin rows container")
	_check(shop_inst.get_node_or_null("Margin/Content/Scroll/Column/PassPanel/PassBody/PassTitle") != null,
			"shop has the Royal Pass panel title")
	_check(shop_inst.get_node_or_null("Margin/Content/Scroll/Column/PassPanel/PassBody/PassPrice") != null,
			"shop has the pass price slot")
	_check(shop_inst.get_node_or_null("Margin/Content/Scroll/Column/PassPanel/PassBody/PassStatus") != null,
			"shop has the pass status slot")
	_check(shop_inst.get_node_or_null("Margin/Content/Scroll/Column/PassPanel/PassBody/PassButtons/BuyPassButton") != null,
			"shop has the Royal Pass buy button")
	_check(shop_inst.get_node_or_null("Margin/Content/Scroll/Column/PassPanel/PassBody/PassButtons/RestoreButton") != null,
			"shop has the restore purchases button")
	shop_inst.free()


# --- Products ---------------------------------------------------------------

func _test_product_contract() -> void:
	var keys: Array = ShopService.PRODUCT_KEYS
	_check(keys.size() == 7, "seven platform product IDs")
	_check(keys == [
		"com.aatamgt.coins_100",
		"com.aatamgt.coins_1000",
		"com.aatamgt.coins_5500",
		"com.aatamgt.coins_12000",
		"com.aatamgt.coins_65000",
		"com.aatamgt.coins_150000",
		"com.aatamgt.royal_pass",
	], "six ascending coin packs plus the Royal Pass")
	_check(ShopService.ROYAL_PASS_KEY == "com.aatamgt.royal_pass",
			"Royal Pass platform ID")
	for key in keys:
		_check(str(key).begins_with("com.aatamgt."),
				"product ID '%s' under the app package" % str(key))

	var methods := []
	for m in _app.shop.get_method_list():
		methods.append(str(m.get("name", "")))
	for required in ["refresh", "products", "price_text", "buy", "restore",
			"entitlement", "history"]:
		_check(methods.has(required), "ShopService exposes %s" % required)
	for forbidden in ["grant", "credit", "debit", "set_balance", "add_coins",
			"spend_coins", "complete_purchase", "confirm_purchase",
			"set_entitlement", "activate_pass", "mint"]:
		_check(not methods.has(forbidden),
				"no local purchase/grant writer '%s'" % forbidden)

	# Before any successful refresh there is no catalog and no price.
	_check(_app.shop.products().is_empty(), "no fake products before refresh")
	_check(_app.shop.price_text("com.aatamgt.coins_100") == "",
			"no price text before refresh")
	_check(not _app.shop.is_loaded(), "catalog reports not loaded")


func _test_price_rule() -> void:
	var dollar_price := RegEx.new()
	dollar_price.compile("\\$[0-9]")
	for path in [SHOP_SERVICE_PATH, SHOP_SCREEN_PATH]:
		var text := FileAccess.get_file_as_string(path)
		_check(not text.contains("Rs "), "%s has no 'Rs ' price" % path)
		_check(not text.contains("\u20b9"), "%s has no rupee price" % path)
		_check(dollar_price.search(text) == null,
				"%s has no dollar price" % path)
		_check(not text.contains("\u20ac"), "%s has no euro price" % path)
		_check(not text.contains("INR "), "%s has no INR price" % path)


# --- Billing providers ------------------------------------------------------

func _test_billing_contract() -> void:
	var base: BillingProvider = BillingProvider.new()
	var base_methods := []
	for m in base.get_method_list():
		base_methods.append(str(m.get("name", "")))
	for verb in ["is_available", "query_products", "purchase", "query_owned"]:
		_check(base_methods.has(verb),
				"BillingProvider contract has %s" % verb)

	var play: BillingProvider = GooglePlayBilling.new()
	_check(play is BillingProvider, "Play provider honors the contract")
	_check(not play.is_available(),
			"Play provider is unavailable without the platform plugin")
	_check(play.query_products(ShopService.PRODUCT_KEYS).is_empty(),
			"Play provider returns no products offline")
	_check(play.query_owned().is_empty(),
			"Play provider owns nothing offline")
	var play_purchase: Dictionary = await play.purchase(
			ShopService.PRODUCT_KEYS[0])
	_check(not play_purchase.ok,
			"Play purchase fails offline without a local grant")
	_check(str(play_purchase.get("error", "")).contains("unavailable"),
			"Play purchase error is honest about availability")

	var dev: BillingProvider = DevStoreBilling.new(
			_app.api_client, _app.auth)
	_check(dev is BillingProvider, "dev store honors the contract")
	var dev_purchase: Dictionary = await dev.purchase(
			ShopService.PRODUCT_KEYS[0])
	_check(not dev_purchase.ok,
			"signed-out dev store purchase fails without a grant")
	_check(str(dev_purchase.get("error", "")).contains("Sign in"),
			"signed-out dev store purchase asks for sign-in")
	_check(dev.query_owned().is_empty(),
			"signed-out dev store owns nothing")


# --- ShopService (signed out, offline) --------------------------------------

func _test_service_offline() -> void:
	var refresh: Dictionary = await _app.shop.refresh()
	_check(not refresh.ok, "refresh fails offline")
	_check(_app.shop.products().is_empty(),
			"failed refresh renders no fake catalog")
	_check(not _app.shop.is_loaded(), "catalog stays unloaded offline")

	var buy: Dictionary = await _app.shop.buy(ShopService.PRODUCT_KEYS[0])
	_check(not buy.ok, "signed-out buy fails offline")
	_check(str(buy.get("error", "")).contains("Sign in"),
			"signed-out buy asks for sign-in")
	_check(buy.get("stage", "") == "store",
			"signed-out buy stops before any store call")

	var restore: Dictionary = await _app.shop.restore()
	_check(not restore.ok, "signed-out restore fails offline")
	_check(str(restore.get("error", "")).contains("Sign in"),
			"signed-out restore asks for sign-in")

	var ent: Dictionary = await _app.shop.entitlement()
	_check(not ent.ok, "signed-out entitlement fails offline")
	_check(int(ent.get("error_kind", -1)) == ApiClient.ErrorKind.EXPIRED_SESSION,
			"signed-out entitlement fails with expired session")

	var hist: Dictionary = await _app.shop.history()
	_check(not hist.ok, "signed-out purchase history fails offline")
	_check(not _app.shop.dev_store_enabled(),
			"dev store flag stays off until the server says otherwise")


# --- Shop screen (signed out, offline) --------------------------------------

func _test_shop_screen_offline() -> void:
	var scene: PackedScene = load(SHOP_SCENE)
	var screen: Control = scene.instantiate()
	_app.add_child(screen)
	for i in 8:
		await _frame()

	var hint := screen.get_node("Margin/Content/HintLabel") as Label
	var rows := screen.get_node(
			"Margin/Content/Scroll/Column/CoinRows") as VBoxContainer
	var status := screen.get_node(
			"Margin/Content/Scroll/Column/PassPanel/PassBody/PassStatus") as Label
	var pass_price := screen.get_node(
			"Margin/Content/Scroll/Column/PassPanel/PassBody/PassPrice") as Label
	var buy_pass := screen.get_node(
			"Margin/Content/Scroll/Column/PassPanel/PassBody/PassButtons/BuyPassButton") as Button
	var restore := screen.get_node(
			"Margin/Content/Scroll/Column/PassPanel/PassBody/PassButtons/RestoreButton") as Button

	_check(hint.text.contains("offline"),
			"offline shop reports the offline hint")
	_check(rows.get_child_count() == 0,
			"offline shop renders no fake product rows")
	_check(status.text.contains("Sign in"),
			"signed-out pass status asks for sign-in")
	_check(pass_price.text == "\u2014",
			"unknown pass price renders honestly, not a literal")
	_check(buy_pass.disabled, "buy disabled offline")
	_check(restore.disabled, "restore disabled offline")

	# Pressing buy while signed out surfaces the sign-in error — and
	# the local balance is untouched (no writer exists to touch it).
	buy_pass.pressed.emit()
	for i in 4:
		await _frame()
	_check(hint.text.contains("Sign in"),
			"buy attempt reports the sign-in requirement")

	restore.pressed.emit()
	for i in 4:
		await _frame()
	_check(hint.text.contains("Sign in"),
			"restore attempt reports the sign-in requirement")

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

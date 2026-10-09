extends SceneTree
## Phase 13 end-to-end: in-app purchases on a live backend with the
## dev store simulator — the catalog arrives from the server with
## store prices, a coin pack is bought through the shop screen
## (grant only after server verification), duplicate and garbage
## tokens are refused without a second grant, the Royal Pass
## activates for 30 days, restore is idempotent, and a store refund
## notification claws the coins back and rolls the pass off.
##
## Run through scripts/run_phase13_e2e.sh, which boots the HTTPS
## server (IAP_DEV_STORE=true) and exports:
##   AATAMGT_API_URL  e.g. https://127.0.0.1:3443
##   AATAMGT_CA_CERT  path to the server's dev certificate
##
## Exit code 0 = all checks passed.

const PASS_KEY := "com.aatamgt.royal_pass"
const COINS_100 := "com.aatamgt.coins_100"
const COINS_1000 := "com.aatamgt.coins_1000"

var _checks := 0
var _failures := 0
var _started := false
var _app: Node = null
var _main: Node = null
var _username := ""
var _dup_token := ""


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
	_check(_app.shop is ShopService, "App exposes the ShopService")
	var base_url := OS.get_environment("AATAMGT_API_URL").strip_edges()
	_check(not base_url.is_empty(), "AATAMGT_API_URL is provided")
	_check(_app.api_client.is_configured(),
			"api client configured from environment")
	await _check_server_reachable()
	if _failures > 0:
		_finish()
		return

	await _test_register_player()
	if _failures > 0:
		_finish()
		return
	await _test_catalog_server_owned()
	await _test_open_shop_from_menu()
	if _failures > 0:
		_finish()
		return
	await _test_buy_coin_pack_through_store()
	await _test_duplicate_and_bad_tokens()
	await _test_royal_pass_and_restore()
	await _test_refund_and_revoke()
	_finish()


# --- Sections ----------------------------------------------------------------

func _test_register_player() -> void:
	_username = "shop%d%d" % [Time.get_ticks_msec(), randi() % 10000]
	var reg: Dictionary = await _app.auth.register(_username, "Shop12345!")
	_check(reg.ok, "player registers (%s)" % _msg(reg))
	if not reg.ok:
		return
	var got_coins := await _wait_until(
			func() -> bool: return _app.coins.get_balance() == 1000, 8.0)
	_check(got_coins, "player receives the 1000-coin welcome")


## The catalog is server-owned: seven platform IDs in the contract
## order, store prices (dev simulator fixture), no local price.
func _test_catalog_server_owned() -> void:
	var res: Dictionary = await _app.shop.refresh()
	_check(res.ok, "catalog refresh succeeds (%s)" % _msg(res))
	if not res.ok:
		return
	_check(_app.shop.dev_store_enabled(),
			"server reports the dev store active")
	_check(_app.shop.is_loaded(), "catalog reports loaded")
	var products: Array = _app.shop.products()
	_check(products.size() == 7, "seven catalog products (got %d)"
			% products.size())
	var keys := []
	var coin_amounts := []
	var saw_pass := false
	for product in products:
		keys.append(str(product.get("productKey", "")))
		var price: String = _app.shop.price_text(
				str(product.get("productKey", "")))
		_check(not price.is_empty(),
				"%s carries a store price" % str(product.get("productKey")))
		_check(price.contains("0") or price.contains("1")
				or price.contains("2") or price.contains("3")
				or price.contains("4") or price.contains("5")
				or price.contains("6") or price.contains("7")
				or price.contains("8") or price.contains("9"),
				"%s price reads as a real number (%s)"
				% [str(product.get("productKey")), price])
		if str(product.get("kind", "")) == "COINS":
			coin_amounts.append(int(product.get("coins", 0)))
			var expected_title := "%d Coins" % int(product.get("coins", 0))
			_check(str(product.get("title", "")) == expected_title,
					"coin pack titled %s" % expected_title)
		else:
			saw_pass = true
			_check(str(product.get("productKey", "")) == PASS_KEY,
					"the non-coin product is the Royal Pass")
			_check(int(product.get("passDays", 0)) == 30,
					"Royal Pass grants 30 days")
	_check(keys == ShopService.PRODUCT_KEYS,
			"catalog order matches the seven platform IDs")
	_check(coin_amounts == [100, 1000, 5500, 12000, 65000, 150000],
			"six coin packs in ascending order")
	_check(saw_pass, "catalog includes the Royal Pass")


## The real player path: main menu -> Shop, six coin rows with buy
## buttons, live pass price and an honest inactive status.
func _test_open_shop_from_menu() -> void:
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
	var button: Button = menu.get_node_or_null("Margin/Content/ShopButton")
	_check(button != null, "main menu has a Shop button")
	if button == null:
		return
	button.pressed.emit()
	_check(_app.navigation.current == &"shop",
			"Shop button navigates to the shop")

	var rows_ready := await _wait_until(
			func() -> bool: return _coin_row_count() == 6, 10.0)
	_check(rows_ready, "shop renders six coin rows (got %d)"
			% _coin_row_count())
	var screen := _screen_named("Shop")
	_check(screen != null, "shop screen is on screen")
	if screen == null:
		return
	var pass_price := screen.get_node(
			"Margin/Content/Scroll/Column/PassPanel/PassBody/PassPrice") as Label
	_check(not pass_price.text.is_empty() and pass_price.text != "\u2014",
			"pass price slot shows the store price (got: %s)" % pass_price.text)
	var status_ready := await _wait_until(
			func() -> bool: return _pass_status_text() != "", 8.0)
	_check(status_ready, "pass status line resolves")
	_check(_pass_status_text().contains("Not active"),
			"fresh account shows the pass inactive (got: %s)"
			% _pass_status_text())
	for i in _coin_row_count():
		var row := _coin_row(i)
		_check(row != null and _buy_button_in_row(row) != null,
				"coin row %d has a Buy button" % i)


## Buying through the screen only credits coins once the backend has
## verified the store token: 1000 -> 2000, history shows GRANTED.
func _test_buy_coin_pack_through_store() -> void:
	var screen := _screen_named("Shop")
	if screen == null:
		return
	var balance_before := await _server_balance()
	_check(balance_before == 1000, "server wallet starts at 1000 (got %d)"
			% balance_before)
	var row := _coin_row(1)
	if row == null or _buy_button_in_row(row) == null:
		_check(false, "coins_1000 row is present")
		return
	_buy_button_in_row(row).pressed.emit()
	var credited := await _wait_until(
			func() -> bool: return _app.coins.get_balance() == 2000, 10.0)
	_check(credited, "client balance lands on 2000 after verification (got %d)"
			% _app.coins.get_balance())
	var hint := screen.get_node("Margin/Content/HintLabel") as Label
	_check(hint.text.contains("verified") or hint.text.contains("updated"),
			"hint reports the server-verified purchase (got: %s)" % hint.text)
	var server_balance := await _server_balance()
	_check(server_balance == 2000,
			"server wallet matches at 2000 (got %d)" % server_balance)

	var history: Dictionary = await _app.shop.history()
	_check(history.ok, "purchase history reads (%s)" % _msg(history))
	if not history.ok:
		return
	var items: Array = history.body.get("items", [])
	var found := false
	for item in items:
		if not (item is Dictionary):
			continue
		if str(item.get("productKey", "")) == COINS_1000 \
				and str(item.get("state", "")) == "GRANTED":
			found = true
	_check(found, "history records the coins_1000 pack as GRANTED")


## A duplicate submit of the same token must not pay twice, and a
## garbage token is refused outright — the client balance never
## moves on either (the raw grant happens out of band).
func _test_duplicate_and_bad_tokens() -> void:
	var issue: Dictionary = await _dev_issue(COINS_100)
	_check(issue.ok, "dev store issues a coins_100 token (%s)" % _msg(issue))
	if not issue.ok:
		return
	var token := str(issue.body.get("purchaseToken", ""))
	_check(not token.is_empty(), "dev store returns a purchase token")
	if token.is_empty():
		return
	_dup_token = token

	var first: Dictionary = await _raw_submit(COINS_100, token)
	_check(first.ok, "first token submit succeeds (%s)" % _msg(first))
	if first.ok:
		_check(str(first.body.get("status", "")) == "granted",
				"first submit grants")
	var after_grant := await _server_balance()
	_check(after_grant == 2100, "server wallet 2100 after the grant (got %d)"
			% after_grant)
	_check(_app.coins.get_balance() == 2000,
			"client balance untouched by the out-of-band grant (got %d)"
			% _app.coins.get_balance())

	var second: Dictionary = await _raw_submit(COINS_100, token)
	_check(second.ok, "duplicate submit accepted as idempotent (%s)"
			% _msg(second))
	if second.ok:
		_check(str(second.body.get("status", "")) == "already_processed",
				"duplicate reports already_processed")
	var after_dup := await _server_balance()
	_check(after_dup == 2100, "duplicate grants nothing (got %d)" % after_dup)

	var bad: Dictionary = await _raw_submit(COINS_100,
			"garbage_token_not_from_any_store")
	_check(not bad.ok, "garbage token refused (%s)" % _msg(bad))
	_check(int(bad.get("status", 0)) == 422,
			"garbage token is a 422")
	var after_bad := await _server_balance()
	_check(after_bad == 2100, "garbage token grants nothing (got %d)" % after_bad)
	_check(_app.coins.get_balance() == 2000,
			"client balance still at its verified value (got %d)"
			% _app.coins.get_balance())


## The Royal Pass buy through the screen activates a ~30-day
## entitlement without touching coins; restore afterwards is a
## no-op that keeps everything as-is.
func _test_royal_pass_and_restore() -> void:
	var screen := _screen_named("Shop")
	if screen == null:
		return
	var balance_before := await _server_balance()
	var buy_pass := screen.get_node(
			"Margin/Content/Scroll/Column/PassPanel/PassBody/PassButtons/BuyPassButton") as Button
	buy_pass.pressed.emit()
	var active := await _wait_until(
			func() -> bool: return _pass_status_text().contains("Active until"),
			10.0)
	_check(active, "pass status line shows the active window (got: %s)"
			% _pass_status_text())

	var entitlement: Dictionary = await _app.shop.entitlement()
	_check(entitlement.ok, "entitlement endpoint reads (%s)" % _msg(entitlement))
	if entitlement.ok:
		var body: Dictionary = entitlement.body
		_check(bool(body.get("active", false)), "server reports the pass active")
		_check(str(body.get("key", "")) == PASS_KEY,
				"entitlement key is the Royal Pass")
		var now := int(Time.get_unix_time_from_system())
		var unix_value: Variant = body.get("expiresAtUnix", 0)
		var unix := 0 if unix_value == null else int(unix_value)
		var days := float(unix - now) / 86400.0
		_check(days > 28.5 and days < 31.0,
				"pass expires ~30 days out (got %.1f days)" % days)

	var balance_after := await _server_balance()
	_check(balance_after == balance_before,
			"the pass costs no coins (got %d)" % balance_after)
	_check(_app.coins.get_balance() == balance_after,
			"client wallet matches the server after the pass buy (got %d vs %d)"
			% [_app.coins.get_balance(), balance_after])

	var hint := screen.get_node("Margin/Content/HintLabel") as Label
	var restore := screen.get_node(
			"Margin/Content/Scroll/Column/PassPanel/PassBody/PassButtons/RestoreButton") as Button
	restore.pressed.emit()
	var hint_wants_restore := func() -> bool:
		return hint.text.contains("up to date") or hint.text.contains("restored")
	var hint_ready := await _wait_until(hint_wants_restore, 10.0)
	_check(hint_ready, "restore reports the idempotent result (got: %s)"
			% hint.text)
	var after_restore: Dictionary = await _app.shop.entitlement()
	if after_restore.ok:
		_check(bool(after_restore.body.get("active", false)),
				"restore keeps the pass active")
	else:
		_check(false, "restore keeps the entitlement readable (%s)"
				% _msg(after_restore))


## Store notifications: a refund claws the coins back (idempotent on
## the wire), and a REVOKED subscription rolls the Royal Pass off —
## all server-side, with the client only re-reading afterwards.
func _test_refund_and_revoke() -> void:
	var balance_before := await _server_balance()
	_check(balance_before == 2100, "pre-refund wallet at 2100 (got %d)"
			% balance_before)

	var flip: Dictionary = await _set_state(_dup_token, "CANCELED")
	_check(flip.ok, "dev store flips the token to CANCELED (%s)" % _msg(flip))
	var refund_push: Dictionary = await _rtdn({
		"oneTimeProductNotification": {
			"notificationType": 11,
			"purchaseToken": _dup_token,
			"productId": COINS_100,
		},
	})
	_check(refund_push.ok, "refund notification accepted (%s)" % _msg(refund_push))
	var clawed := await _wait_for_balance(balance_before - 100, 10.0)
	_check(clawed, "server wallet clawed back to %d (got %d)"
			% [balance_before - 100, await _server_balance()])

	var again: Dictionary = await _rtdn({
		"oneTimeProductNotification": {
			"notificationType": 11,
			"purchaseToken": _dup_token,
			"productId": COINS_100,
		},
	})
	_check(again.ok, "duplicate refund notification accepted (%s)" % _msg(again))
	await _frame()
	await _frame()
	var stable := await _server_balance()
	_check(stable == balance_before - 100,
			"double refund changes nothing (got %d)" % stable)

	var history: Dictionary = await _app.shop.history()
	if history.ok:
		var refunded := false
		for item in history.body.get("items", []):
			if not (item is Dictionary):
				continue
			if str(item.get("productKey", "")) == COINS_100 \
					and str(item.get("state", "")) == "REFUNDED":
				refunded = true
		_check(refunded, "history records the coins_100 pack as REFUNDED")
	else:
		_check(false, "purchase history reads after the refund (%s)" % _msg(history))

	# Royal Pass revoked: the status line and entitlement both drop.
	var pass_token := await _owned_pass_token()
	_check(not pass_token.is_empty(), "dev store lists the pass token")
	if pass_token.is_empty():
		return
	var flip_pass: Dictionary = await _set_state(pass_token, "CANCELED")
	_check(flip_pass.ok, "dev store flips the pass token to CANCELED (%s)"
			% _msg(flip_pass))
	var revoke_push: Dictionary = await _rtdn({
		"subscriptionNotification": {
			"notificationType": 12,
			"purchaseToken": pass_token,
			"subscriptionId": PASS_KEY,
		},
	})
	_check(revoke_push.ok, "revocation notification accepted (%s)" % _msg(revoke_push))
	# The screen re-reads the entitlement through the normal restore
	# path — the server already rolled the pass off.
	var shop_screen := _screen_named("Shop")
	if shop_screen != null:
		var restore_button := shop_screen.get_node(
				"Margin/Content/Scroll/Column/PassPanel/PassBody/PassButtons/RestoreButton") as Button
		restore_button.pressed.emit()
	var dropped := await _wait_until(
			func() -> bool: return not _pass_status_text().contains("Active until"),
			10.0)
	_check(dropped, "pass status line drops the active window (got: %s)"
			% _pass_status_text())
	var after_revoke: Dictionary = await _app.shop.entitlement()
	if after_revoke.ok:
		_check(not bool(after_revoke.body.get("active", false)),
				"server reports the pass inactive after revocation")
	var coins_stable := await _server_balance()
	_check(coins_stable == balance_before - 100,
			"revoking the pass moves no coins (got %d)" % coins_stable)

	# The client re-syncs its wallet cache from the server.
	_app.refresh_wallet()
	var resynced := await _wait_until(
			func() -> bool: return _app.coins.get_balance() == balance_before - 100,
			8.0)
	_check(resynced, "client wallet re-syncs to %d (got %d)"
			% [balance_before - 100, _app.coins.get_balance()])


# --- Helpers ----------------------------------------------------------------

func _token() -> String:
	return str(_app.auth.get_access_token())


func _dev_issue(product_id: String) -> Dictionary:
	return await _app.api_client.request_json(HTTPClient.METHOD_POST,
			"/shop/dev/issue", {"productId": product_id}, _token())


func _raw_submit(product_id: String, token: String) -> Dictionary:
	return await _app.api_client.request_json(HTTPClient.METHOD_POST,
			"/purchases", {"productId": product_id, "purchaseToken": token},
			_token())


func _set_state(token: String, state: String) -> Dictionary:
	return await _app.api_client.request_json(HTTPClient.METHOD_POST,
			"/shop/dev/store/%s/state" % token, {"state": state}, _token())


func _rtdn(payload: Dictionary) -> Dictionary:
	var data := Marshalls.raw_to_base64(JSON.stringify(payload).to_utf8_buffer())
	return await _app.api_client.request_json(HTTPClient.METHOD_POST,
			"/hooks/rtdn", {"message": {"data": data}})


func _owned_pass_token() -> String:
	var res: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_GET, "/shop/dev/owned", {}, _token())
	if not res.ok:
		return ""
	for item in res.body.get("items", []):
		if item is Dictionary and str(item.get("productId", "")) == PASS_KEY:
			return str(item.get("purchaseToken", ""))
	return ""


func _server_balance() -> int:
	var res: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_GET, "/wallet", {}, _token())
	if not res.ok:
		return -1
	return int(res.body.get("balance", -1))


func _wait_for_balance(want: int, timeout_sec: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if (await _server_balance()) == want:
			return true
		await create_timer(0.15).timeout
	return (await _server_balance()) == want


func _screen_named(root_name: String) -> Control:
	if _main == null:
		return null
	var container: Control = _main.get_node("ScreenLayer/ScreenContainer")
	for child in container.get_children():
		if child.name == root_name:
			return child
	return null


func _coin_row_count() -> int:
	var screen := _screen_named("Shop")
	if screen == null:
		return -1
	var rows := screen.get_node_or_null(
			"Margin/Content/Scroll/Column/CoinRows")
	if rows == null:
		return -1
	return rows.get_child_count()


func _coin_row(index: int) -> HBoxContainer:
	var screen := _screen_named("Shop")
	if screen == null:
		return null
	var rows := screen.get_node("Margin/Content/Scroll/Column/CoinRows")
	if index < 0 or index >= rows.get_child_count():
		return null
	return rows.get_child(index) as HBoxContainer


func _buy_button_in_row(row: HBoxContainer) -> Button:
	if row == null:
		return null
	for child in row.get_children():
		if child is Button:
			return child
	return null


func _pass_status_text() -> String:
	var screen := _screen_named("Shop")
	if screen == null:
		return ""
	var status := screen.get_node_or_null(
			"Margin/Content/Scroll/Column/PassPanel/PassBody/PassStatus")
	if status == null:
		return ""
	return (status as Label).text


func _check_server_reachable() -> void:
	var res: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_GET, "/profiles/me")
	var transport_failure: bool = (res.error_kind == ApiClient.ErrorKind.NETWORK
			or res.error_kind == ApiClient.ErrorKind.SERVER_UNAVAILABLE)
	_check(not transport_failure, "backend reachable over HTTPS (%s)" % _msg(res))
	_check(_app.network.get_status() == NetworkService.Status.CONNECTED,
			"network reports online after the reachability call")


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
	print("PURCHASES E2E: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


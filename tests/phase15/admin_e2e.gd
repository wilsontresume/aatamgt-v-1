extends SceneTree
## Phase 15 end-to-end: the admin dashboard on a live backend — staff
## sign-in, the gated main-menu entry, player search/detail with
## suspend-ban-unban (login blocked while suspended), game status
## filters with an operator finalisation, economy views fed by a real
## dev-store purchase, cosmetic price/disable toggles reflected in the
## public catalog, runtime config overrides (registration bonus, Royal
## Pass days) observed end-to-end, and the audit trail listing every
## action.
##
## Run through scripts/run_phase15_e2e.sh, which boots the HTTPS
## server (IAP_DEV_STORE), ensures the e2e admin account, and exports:
##   AATAMGT_API_URL           e.g. https://127.0.0.1:3443
##   AATAMGT_CA_CERT           path to the server's dev certificate
##   AATAMGT_E2E_ADMIN_USER    admin username
##   AATAMGT_E2E_ADMIN_PASS    admin password
##
## Exit code 0 = all checks passed.

const VICTIM_PASSWORD := "Victim12345!"
const ADMIN_PASSWORD_FALLBACK := "AdminPass123!"

var _checks := 0
var _failures := 0
var _started := false
var _app: Node = null
var _main: Node = null
var _admin_user := ""
var _admin_pass := ""
var _victim_name := ""
var _victim_id := ""
var _victim_token := ""
var _match_id := ""
var _original_bonus := ""
var _original_days := ""


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
	_check(_app.admin is AdminService, "App exposes the AdminService")
	_admin_user = OS.get_environment("AATAMGT_E2E_ADMIN_USER").strip_edges()
	_admin_pass = OS.get_environment("AATAMGT_E2E_ADMIN_PASS").strip_edges()
	if _admin_pass.is_empty():
		_admin_pass = ADMIN_PASSWORD_FALLBACK
	_check(not _admin_user.is_empty(), "admin credentials are provided")
	var base_url := OS.get_environment("AATAMGT_API_URL").strip_edges()
	_check(not base_url.is_empty(), "AATAMGT_API_URL is provided")
	_check(_app.api_client.is_configured(), "api client configured from environment")
	await _check_server_reachable()
	if _failures > 0:
		_finish()
		return

	await _test_session_setup()
	if _failures > 0:
		_finish()
		return
	await _test_open_dashboard()
	if _failures > 0:
		_finish()
		return
	await _section("players", _test_players_flow)
	await _section("games", _test_games_flow)
	await _section("economy", _test_economy_flow)
	await _section("content", _test_content_flow)
	await _section("config", _test_config_flow)
	await _section("audit", _test_audit_flow)
	await _section("gating", _test_staff_gating)
	_finish()


func _section(name: String, fn: Callable) -> void:
	var t0 := Time.get_ticks_msec()
	print("### section ", name, " (t=", t0, ")")
	await fn.call()
	print("### section ", name, " done in ", Time.get_ticks_msec() - t0, "ms")


# --- Sections ------------------------------------------------------------------

## Registers the victim raw (no session) and signs the admin in through
## the real AuthService so the dashboard runs under a staff session.
func _test_session_setup() -> void:
	_victim_name = "p15v%d" % [Time.get_ticks_msec() % 1000000]
	var reg: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_POST, "/auth/register",
			{"username": _victim_name, "password": VICTIM_PASSWORD})
	_check(reg.ok, "victim registers (%s)" % _msg(reg))
	if not reg.ok:
		return
	_victim_token = str(reg.body.get("accessToken", ""))
	_victim_id = str(_dict(reg.body.get("user")).get("id", ""))
	_check(not _victim_token.is_empty(), "victim receives an access token")
	_check(not _victim_id.is_empty(), "victim has a user id")

	var login_res: Dictionary = await _app.auth.login(_admin_user, _admin_pass)
	_check(login_res.ok, "admin signs in (%s)" % _msg(login_res))
	if not login_res.ok:
		return
	_check(_app.auth.is_staff(), "session carries a staff role")
	_check(_app.auth.role() == "ADMIN", "session role is ADMIN")


## Boots the real main scene, finds the staff-gated Admin entry and
## walks into the dashboard through the button a staff member presses.
func _test_open_dashboard() -> void:
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
	var button: Button = menu.get_node_or_null("Margin/Content/FeaturesRow/AdminButton")
	_check(button != null, "main menu has an Admin button")
	if button == null:
		return
	_check(button.visible, "Admin button is visible for staff")
	await _press(button)
	_check(_app.navigation.current == &"admin",
			"Admin button navigates to the dashboard")

	var screen: Control = await _wait_screen()
	_check(screen != null, "admin screen is on screen")
	if screen == null:
		return
	var listed := await _wait_until(
			func() -> bool: return _row_count("PlayerRow") > 0 and _list_text().contains(_victim_name),
			10.0)
	_check(listed, "players tab lists the victim (rows=%d)" % _row_count("PlayerRow"))


## Player search -> detail -> suspend (login blocked) -> unban ->
## ban (login blocked) -> unban, all through the screen's own buttons.
func _test_players_flow() -> void:
	var screen := _screen_named("Admin")
	if screen == null:
		return
	var search: LineEdit = screen.get_node(
			"Margin/Content/SearchRow/SearchEdit")
	search.text = _victim_name
	var search_button: Button = screen.get_node(
			"Margin/Content/SearchRow/SearchButton")
	await _press(search_button)
	var narrowed := await _wait_until(
			func() -> bool: return _row_count("PlayerRow") == 1 and _list_text().contains(_victim_name),
			10.0)
	_check(narrowed, "search narrows to the victim (rows=%d)" % _row_count("PlayerRow"))

	var open := screen.find_child("OpenButton", true, false) as Button
	_check(open != null, "player row offers an Open button")
	if open == null:
		return
	await _press(open)
	var detailed := await _wait_until(
			func() -> bool: return _detail_text().contains(_victim_name) and _detail_text().contains("Coins:"),
			10.0)
	_check(detailed, "player detail renders (got: %s)" % _detail_text())
	_check(_detail_text().contains("ACTIVE"), "player starts ACTIVE")

	var suspend := screen.find_child("SuspendButton", true, false) as Button
	_check(suspend != null, "detail offers a Suspend button")
	if suspend == null:
		return
	await _press(suspend)
	var suspended := await _wait_until(
			func() -> bool: return _hint_text().contains("Status set to SUSPENDED"), 10.0)
	_check(suspended, "suspend confirms (hint: %s)" % _hint_text())
	_check(_detail_text().contains("SUSPENDED"), "detail shows SUSPENDED")

	var blocked := await _raw_login(_victim_name, VICTIM_PASSWORD)
	_check(not blocked.ok, "suspended player cannot sign in")
	var blocked_status := int(blocked.get("status", 0))
	_check(blocked_status >= 401 and blocked_status < 500,
			"suspended sign-in is refused (status %d)" % blocked_status)

	var unban := screen.find_child("UnbanButton", true, false) as Button
	_check(unban != null, "detail offers an Unban button")
	if unban == null:
		return
	await _press(unban)
	var reactivated := await _wait_until(
			func() -> bool: return _hint_text().contains("Status set to ACTIVE"), 10.0)
	_check(reactivated, "unban confirms (hint: %s)" % _hint_text())
	_check(_detail_text().contains("ACTIVE"), "detail shows ACTIVE again")
	var allowed := await _raw_login(_victim_name, VICTIM_PASSWORD)
	_check(allowed.ok, "unbanned player signs in (%s)" % _msg(allowed))

	var ban := screen.find_child("BanButton", true, false) as Button
	_check(ban != null, "detail offers a Ban button")
	if ban == null:
		return
	await _press(ban)
	var banned := await _wait_until(
			func() -> bool: return _hint_text().contains("Status set to BANNED"), 10.0)
	_check(banned, "ban confirms (hint: %s)" % _hint_text())
	var banned_login := await _raw_login(_victim_name, VICTIM_PASSWORD)
	_check(not banned_login.ok, "banned player cannot sign in")
	unban = screen.find_child("UnbanButton", true, false) as Button
	if unban != null:
		await _press(unban)
		var restored := await _wait_until(
				func() -> bool: return _hint_text().contains("Status set to ACTIVE"), 10.0)
		_check(restored, "ban is lifted again (hint: %s)" % _hint_text())
	var final_login := await _raw_login(_victim_name, VICTIM_PASSWORD)
	_check(final_login.ok, "player signs in after the ban is lifted")

	var close := screen.find_child("CloseDetailButton", true, false) as Button
	if close != null:
		await _press(close)
		await _frame()
		_check(_detail_text().is_empty(), "detail closes")


## Creates a live match (victim + admin), filters the games tab by
## status, then finalises it as an operator and finds it under
## COMPLETED.
func _test_games_flow() -> void:
	var screen := _screen_named("Admin")
	if screen == null:
		return
	var create: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_POST, "/matches",
			{"gameKey": "aadu-puli-aattam"}, _victim_token)
	_check(create.ok, "victim creates a match (%s)" % _msg(create))
	if not create.ok:
		return
	_match_id = str(create.body.get("id", ""))
	var join: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_POST, "/matches/%s/join" % _match_id, {},
			_app.auth.get_access_token())
	_check(join.ok, "admin joins the match (%s)" % _msg(join))

	var games_tab: Button = screen.get_node(
			"Margin/Content/AdminTabs/GamesTab")
	await _press(games_tab)
	var on_games := await _wait_until(
			func() -> bool: return String(screen.get("_tab")) == "games", 5.0)
	_check(on_games, "games tab selects")
	var active_seen := await _wait_until(
			func() -> bool: return _row_count("MatchRow") > 0 and _list_text().contains(_victim_name),
			10.0)
	_check(active_seen, "games list shows the active match (got: %s)" % _list_text())

	var active_filter: Button = screen.get_node_or_null(
			"Margin/Content/FilterRow/Filter_1")
	_check(active_filter != null, "games tab offers the Active filter")
	if active_filter != null:
		await _press(active_filter)
		var only_active := await _wait_until(
				func() -> bool: return _row_count("MatchRow") > 0 and _list_text().contains(_victim_name),
				10.0)
		_check(only_active, "active filter keeps the match visible")

	var finalize: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_PATCH, "/admin/matches/%s/finalize" % _match_id,
			{
				"status": "COMPLETED",
				"reason": "phase 15 e2e",
				"players": [
					{"userId": _victim_id, "result": "WIN", "score": 1},
					{"userId": _app.auth.get_player_id(), "result": "LOSS", "score": 0},
				],
			}, _app.auth.get_access_token())
	_check(finalize.ok, "operator finalises the match (%s)" % _msg(finalize))

	var completed_filter: Button = screen.get_node_or_null(
			"Margin/Content/FilterRow/Filter_2")
	_check(completed_filter != null, "games tab offers the Completed filter")
	if completed_filter != null:
		await _press(completed_filter)
		var completed_seen := await _wait_until(
				func() -> bool: return _row_count("MatchRow") > 0 and _list_text().contains("COMPLETED") and _list_text().contains(_victim_name),
				10.0)
		_check(completed_seen, "completed filter shows the finalised match")


## A real dev-store purchase lands in the economy views: the summary
## line, the PURCHASE ledger row, the purchases list and the ad-shows
## list.
func _test_economy_flow() -> void:
	var issue: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_POST, "/shop/dev/issue",
			{"productId": "com.aatamgt.coins_100"}, _victim_token)
	_check(issue.ok, "dev store issues a coin token (%s)" % _msg(issue))
	if not issue.ok:
		return
	var submit: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_POST, "/purchases",
			{
				"productId": "com.aatamgt.coins_100",
				"purchaseToken": str(issue.body.get("purchaseToken", "")),
			}, _victim_token)
	_check(submit.ok, "purchase settles (%s)" % _msg(submit))
	_check(str(submit.body.get("status", "")) == "granted",
			"purchase is granted by the server")

	var shown: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_POST, "/ads/interstitial/shown",
			{"matchId": _match_id}, _victim_token)
	_check(shown.ok, "interstitial show records (%s)" % _msg(shown))

	var screen := _screen_named("Admin")
	if screen == null:
		return
	var economy_tab: Button = screen.get_node(
			"Margin/Content/AdminTabs/EconomyTab")
	await _press(economy_tab)
	var on_economy := await _wait_until(
			func() -> bool: return String(screen.get("_tab")) == "economy", 5.0)
	_check(on_economy, "economy tab selects")
	var summary_seen := await _wait_until(
			func() -> bool: return _list_text().contains("Issued"), 10.0)
	_check(summary_seen, "summary line renders (got: %s)" % _list_text())
	_check(_list_text().contains("Spent"), "summary reports coins spent")
	_check(_list_text().contains("Transactions"), "summary reports transactions")
	_check(_list_text().contains("Purchases"), "summary reports purchases")
	var purchase_row := await _wait_until(
			func() -> bool: return _list_text().contains("PURCHASE") and _list_text().contains(_victim_name),
			10.0)
	_check(purchase_row, "ledger shows the victim's purchase")

	var purchases_filter: Button = screen.get_node_or_null(
			"Margin/Content/FilterRow/Filter_2")
	if purchases_filter != null:
		await _press(purchases_filter)
		var listed := await _wait_until(
				func() -> bool: return _list_text().contains("com.aatamgt.coins_100"), 10.0)
		_check(listed, "purchases view lists the coin pack")
	var ads_filter: Button = screen.get_node_or_null(
			"Margin/Content/FilterRow/Filter_1")
	if ads_filter != null:
		await _press(ads_filter)
		var ad_row := await _wait_until(
				func() -> bool: return _list_text().contains("INTERSTITIAL") and _list_text().contains(_victim_name),
				10.0)
		_check(ad_row, "ad shows view lists the presentation")


## Cosmetic price edit + enable/disable reflected in the admin list and
## the public catalog, then restored.
func _test_content_flow() -> void:
	var screen := _screen_named("Admin")
	if screen == null:
		return
	var content_tab: Button = screen.get_node(
			"Margin/Content/AdminTabs/ContentTab")
	await _press(content_tab)
	var on_content := await _wait_until(
			func() -> bool: return String(screen.get("_tab")) == "content" and _row_count("CosmeticRow") > 0,
			10.0)
	_check(on_content, "content tab lists cosmetics (got: %s)" % _list_text())

	var open := screen.find_child("OpenButton", true, false) as Button
	_check(open != null, "cosmetic row offers an Open button")
	if open == null:
		return
	await _press(open)
	var detailed := await _wait_until(
			func() -> bool: return screen.find_child("PriceEdit", true, false) != null, 10.0)
	_check(detailed, "cosmetic editor opens (got: %s)" % _detail_text())

	var price_edit := screen.find_child("PriceEdit", true, false) as LineEdit
	if price_edit == null:
		return
	var cosmetic_name := _detail_text()
	var original_price := price_edit.text
	price_edit.text = "123"
	var save := screen.find_child("SavePriceButton", true, false) as Button
	_check(save != null, "editor offers a Save price button")
	if save == null:
		return
	await _press(save)
	var price_saved := await _wait_until(
			func() -> bool: return _hint_text().contains("Price saved"), 10.0)
	_check(price_saved, "price save confirms (hint: %s)" % _hint_text())
	_check(_list_text().contains("123 coins"), "list shows the new price")

	var public_res: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_GET, "/cosmetics", {}, _victim_token)
	var shown_price := -1
	if public_res.ok:
		shown_price = _public_price(public_res, cosmetic_name)
	_check(shown_price == 123,
			"public catalog shows the new price (got %d)" % shown_price)

	var toggle := screen.find_child("ToggleButton", true, false) as Button
	_check(toggle != null, "editor offers an enable/disable toggle")
	if toggle == null:
		return
	await _press(toggle)
	var disabled := await _wait_until(
			func() -> bool: return _hint_text().contains("Cosmetic disabled"), 10.0)
	_check(disabled, "disable confirms (hint: %s)" % _hint_text())
	_check(_list_text().contains("Hidden"), "list marks the cosmetic Hidden")
	public_res = await _app.api_client.request_json(
			HTTPClient.METHOD_GET, "/cosmetics", {}, _victim_token)
	if public_res.ok:
		_check(_public_price(public_res, cosmetic_name) == -1,
				"disabled cosmetic leaves the public catalog")

	toggle = screen.find_child("ToggleButton", true, false) as Button
	if toggle != null:
		await _press(toggle)
		var enabled := await _wait_until(
				func() -> bool: return _hint_text().contains("Cosmetic enabled"), 10.0)
		_check(enabled, "enable confirms (hint: %s)" % _hint_text())
		_check(_list_text().contains("Live"), "list marks the cosmetic Live")

	price_edit = screen.find_child("PriceEdit", true, false) as LineEdit
	if price_edit != null:
		price_edit.text = original_price
		save = screen.find_child("SavePriceButton", true, false) as Button
		if save != null:
			await _press(save)
			var restored := await _wait_until(
					func() -> bool: return _list_text().contains("%s coins" % original_price) and _hint_text().contains("Price saved"),
					10.0)
			_check(restored, "original price restored (list: %s)" % _list_text())


## Config overrides observed end-to-end: the registration bonus pays a
## fresh account the configured amount, the Royal Pass duration shows
## in the public catalog — then everything is restored.
func _test_config_flow() -> void:
	var screen := _screen_named("Admin")
	if screen == null:
		return
	var config_tab: Button = screen.get_node(
			"Margin/Content/AdminTabs/ConfigTab")
	await _press(config_tab)
	var on_config := await _wait_until(
			func() -> bool: return String(screen.get("_tab")) == "config" and _row_count("ConfigRow") > 0 and _list_text().contains("Registration bonus"),
			10.0)
	_check(on_config, "config tab lists the keys (got: %s)" % _list_text())

	var bonus_edit := screen.find_child(
			"Value_coins_registration_bonus", true, false) as LineEdit
	var days_edit := screen.find_child(
			"Value_shop_royal_pass_days", true, false) as LineEdit
	_check(bonus_edit != null, "registration bonus editor exists")
	_check(days_edit != null, "royal pass days editor exists")
	if bonus_edit == null or days_edit == null:
		return
	_original_bonus = bonus_edit.text
	_original_days = days_edit.text
	bonus_edit.text = "555"
	days_edit.text = "45"
	var save := screen.find_child("SaveConfigButton", true, false) as Button
	_check(save != null, "config tab offers a save button")
	if save == null:
		return
	await _press(save)
	var saved := await _wait_until(
			func() -> bool: return _hint_text().contains("Configuration saved"), 10.0)
	_check(saved, "config save confirms (hint: %s)" % _hint_text())

	var bonus_name := "p15b%d" % [Time.get_ticks_msec() % 1000000]
	var bonus_reg: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_POST, "/auth/register",
			{"username": bonus_name, "password": VICTIM_PASSWORD})
	_check(bonus_reg.ok, "fresh account registers (%s)" % _msg(bonus_reg))
	if bonus_reg.ok:
		var bonus_token := str(bonus_reg.body.get("accessToken", ""))
		var wallet: Dictionary = await _app.api_client.request_json(
				HTTPClient.METHOD_GET, "/wallet", {}, bonus_token)
		_check(wallet.ok and int(wallet.body.get("balance", -1)) == 555,
				"registration bonus pays the configured 555 (got %d)"
				% int(wallet.body.get("balance", -1)))

	var products: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_GET, "/shop/products", {}, _victim_token)
	var pass_info := _pass_from(products) if products.ok else {}
	_check(int(pass_info.get("passDays", 0)) == 45,
			"catalog shows the configured 45-day pass (got %d)"
			% int(pass_info.get("passDays", -1)))
	_check(str(pass_info.get("title", "")).contains("(45 days)"),
			"pass title carries the configured duration")

	# Restore the original values through the same editors.
	bonus_edit = screen.find_child(
			"Value_coins_registration_bonus", true, false) as LineEdit
	days_edit = screen.find_child(
			"Value_shop_royal_pass_days", true, false) as LineEdit
	if bonus_edit != null and days_edit != null:
		bonus_edit.text = _original_bonus
		days_edit.text = _original_days
		save = screen.find_child("SaveConfigButton", true, false) as Button
		if save != null:
			await _press(save)
			var restored := await _wait_until(
					func() -> bool: return _hint_text().contains("Configuration saved"), 10.0)
			_check(restored, "restore save confirms (hint: %s)" % _hint_text())

	var products_after: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_GET, "/shop/products", {}, _victim_token)
	var restored_days := int(_pass_from(products_after).get("passDays", -1)) if products_after.ok else -1
	_check(restored_days == int(_original_days),
			"pass duration restored (catalog shows %d, want %s)"
			% [restored_days, _original_days])
	var restore_name := "p15r%d" % [Time.get_ticks_msec() % 1000000]
	var restore_reg: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_POST, "/auth/register",
			{"username": restore_name, "password": VICTIM_PASSWORD})
	if restore_reg.ok:
		var restore_token := str(restore_reg.body.get("accessToken", ""))
		var wallet: Dictionary = await _app.api_client.request_json(
				HTTPClient.METHOD_GET, "/wallet", {}, restore_token)
		_check(int(wallet.body.get("balance", -1)) == int(_original_bonus),
				"registration bonus restored to %s (got %d)"
				% [_original_bonus, int(wallet.body.get("balance", -1))])
	else:
		_check(false, "post-restore account registers (%s)" % _msg(restore_reg))


## The audit tab names every action the dashboard performed.
func _test_audit_flow() -> void:
	var screen := _screen_named("Admin")
	if screen == null:
		return
	var audit_tab: Button = screen.get_node(
			"Margin/Content/AdminTabs/AuditTab")
	await _press(audit_tab)
	var on_audit := await _wait_until(
			func() -> bool: return String(screen.get("_tab")) == "audit" and _row_count("AuditRow") > 0 and _list_text().contains("user.status"),
			10.0)
	_check(on_audit, "audit tab lists actions (got: %s)" % _list_text())
	_check(_list_text().contains("config.set"), "audit carries config.set")
	_check(_list_text().contains("cosmetic.update"),
			"audit carries cosmetic.update")
	_check(_list_text().contains("match.finalize"),
			"audit carries match.finalize")
	var rows: VBoxContainer = screen.get_node_or_null(
			"Margin/Content/Scroll/Column/ListRows")
	if rows != null:
		_check(rows.get_child_count() >= 3, "audit renders multiple rows")


## Signs out of the staff session: the entry disappears, the server
## refuses every admin read, and no local state leaks.
func _test_staff_gating() -> void:
	var out: Dictionary = await _app.auth.logout()
	_check(out.ok, "admin session logs out")
	var user_login: Dictionary = await _app.auth.login(_victim_name, VICTIM_PASSWORD)
	_check(user_login.ok, "victim signs in (%s)" % _msg(user_login))
	_check(not _app.auth.is_staff(), "regular session is not staff")
	_check(_app.auth.role() == "USER", "regular session role is USER")

	_app.navigation.go(&"main_menu")
	var menu: Control = await _wait_named("MainMenu")
	_check(menu != null, "main menu returns")
	if menu != null:
		var button: Button = menu.get_node_or_null(
				"Margin/Content/FeaturesRow/AdminButton")
		_check(button != null, "Admin button still exists")
		_check(button != null and not button.visible,
				"Admin button hides for regular players")

	var stats: Dictionary = await _app.admin.stats()
	_check(not stats.ok, "admin stats refused for a regular player")
	_check(int(stats.get("status", 0)) == 403,
			"server answers 403 (got %d)" % int(stats.get("status", 0)))


# --- Helpers --------------------------------------------------------------------

func _check_server_reachable() -> void:
	var res: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_GET, "/profiles/me")
	var transport_failure: bool = (res.error_kind == ApiClient.ErrorKind.NETWORK
			or res.error_kind == ApiClient.ErrorKind.SERVER_UNAVAILABLE)
	_check(not transport_failure, "backend reachable over HTTPS (%s)" % _msg(res))
	_check(_app.network.get_status() == NetworkService.Status.CONNECTED,
			"network reports online after the reachability call")


func _raw_login(identifier: String, password: String) -> Dictionary:
	return await _app.api_client.request_json(HTTPClient.METHOD_POST,
			"/auth/login", {"identifier": identifier, "password": password})


func _screen_named(root_name: String) -> Control:
	if _main == null:
		return null
	var container: Control = _main.get_node("ScreenLayer/ScreenContainer")
	for child in container.get_children():
		if child.name == root_name:
			return child
	return null


func _wait_screen() -> Control:
	await _wait_until(
			func() -> bool: return _screen_named("Admin") != null, 8.0)
	return _screen_named("Admin")


func _wait_named(root_name: String) -> Control:
	await _wait_until(
			func() -> bool: return _screen_named(root_name) != null, 8.0)
	return _screen_named(root_name)


func _row_count(row_name: String) -> int:
	var screen := _screen_named("Admin")
	if screen == null:
		return 0
	var rows: Node = screen.get_node_or_null(
			"Margin/Content/Scroll/Column/ListRows")
	if rows == null:
		return 0
	var count := 0
	for child in rows.get_children():
		if child.name == row_name:
			count += 1
	return count


func _list_text() -> String:
	var screen := _screen_named("Admin")
	if screen == null:
		return ""
	var rows: Node = screen.get_node_or_null(
			"Margin/Content/Scroll/Column/ListRows")
	if rows == null:
		return ""
	return _labels_text(rows)


func _detail_text() -> String:
	var screen := _screen_named("Admin")
	if screen == null:
		return ""
	var rows: Node = screen.get_node_or_null(
			"Margin/Content/Scroll/Column/DetailRows")
	if rows == null:
		return ""
	return _labels_text(rows)


func _hint_text() -> String:
	var screen := _screen_named("Admin")
	if screen == null:
		return ""
	var hint: Node = screen.get_node_or_null("Margin/Content/HintLabel")
	if hint == null or not (hint as Label).visible:
		return ""
	return (hint as Label).text


func _public_price(products: Dictionary, cosmetic_name: String) -> int:
	if not products.ok:
		return -1
	var items: Array = products.body.get("items", [])
	for row in items:
		if row is Dictionary:
			var item := row as Dictionary
			if str(item.get("name", "")) == cosmetic_name:
				return int(item.get("price", -1))
	return -1


func _pass_from(products: Dictionary) -> Dictionary:
	if not products.ok:
		return {}
	var items: Array = products.body.get("items", [])
	for row in items:
		if row is Dictionary:
			var item := row as Dictionary
			if str(item.get("productKey", "")) == "com.aatamgt.royal_pass":
				return item
	return {}


func _dict(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


func _labels_text(node: Node) -> String:
	var parts := PackedStringArray()
	_collect_labels(node, parts)
	return " | ".join(parts)


func _collect_labels(node: Node, parts: PackedStringArray) -> void:
	for child in node.get_children():
		if child is Label:
			parts.append((child as Label).text)
		else:
			_collect_labels(child, parts)


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


func _press(button: Button) -> void:
	var screen := _screen_named("Admin")
	var button_name := ""
	if is_instance_valid(button):
		button_name = str(button.name)
	if screen == null:
		if is_instance_valid(button):
			button.pressed.emit()
		return
	var idle := await _wait_until(
			func() -> bool: return not bool(screen.get("_busy")), 8.0)
	if not idle:
		printerr("      press: screen still busy for ", button_name)
	var fresh := screen.find_child(button_name, true, false) as Button
	if fresh == null:
		printerr("      press: button ", button_name, " not found")
		return
	fresh.pressed.emit()


func _frame() -> void:
	await process_frame


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		printerr("FAIL: ", label)
		printerr("      diag: ", _diag_text())


func _diag_text() -> String:
	var screen := _screen_named("Admin")
	if screen == null:
		return "no admin screen (main=%s) hint=%s" % [str(_main != null), _hint_text().left(120)]
	var detail: Node = screen.get_node_or_null(
			"Margin/Content/Scroll/Column/DetailRows")
	var detail_names := "-"
	if detail != null:
		var names := PackedStringArray()
		for c in detail.get_children():
			names.append(str(c.name))
		detail_names = ",".join(names)
	return "tab=%s busy=%s rows=%d detail=[%s] hint=%s | list=%s" % [
			str(screen.get("_tab")), str(screen.get("_busy")),
			_row_count_any(screen), detail_names,
			_hint_text().left(150), _list_text().left(160)]


func _row_count_any(screen: Control) -> int:
	var rows: Node = screen.get_node_or_null(
			"Margin/Content/Scroll/Column/ListRows")
	if rows == null:
		return 0
	return rows.get_child_count()


func _finish() -> void:
	print("ADMIN E2E: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)

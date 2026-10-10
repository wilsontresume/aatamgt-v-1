extends Control
## Phase 15: staff dashboard — players, games, economy, content,
## configuration and the audit trail. Every number comes from the
## server; every mutation goes through AdminService to the role-guarded
## AdminController, which validates, persists and audits. This screen
## holds no local copy of platform state: if a request fails it shows
## the error and keeps whatever was already rendered.

const TABS := {
	"players": "PlayersTab",
	"games": "GamesTab",
	"economy": "EconomyTab",
	"content": "ContentTab",
	"config": "ConfigTab",
	"audit": "AuditTab",
}

const GAME_FILTERS := [["All", ""], ["Active", "ACTIVE"],
	["Completed", "COMPLETED"], ["Abandoned", "ABANDONED"]]
const ECONOMY_FILTERS := [["Transactions", "transactions"], ["Ad shows", "ads"],
	["Purchases", "purchases"]]
const CONTENT_FILTERS := [["All", ""], ["Boards", "BOARD_SKIN"],
	["Pictures", "PROFILE_PICTURE"], ["Frames", "PROFILE_FRAME"],
	["Victory", "VICTORY_ANIMATION"], ["Capture", "CAPTURE_ANIMATION"]]

@onready var _tabs_row: HBoxContainer = $Margin/Content/AdminTabs
@onready var _search_row: HBoxContainer = $Margin/Content/SearchRow
@onready var _search_edit: LineEdit = $Margin/Content/SearchRow/SearchEdit
@onready var _search_button: Button = $Margin/Content/SearchRow/SearchButton
@onready var _filter_row: HBoxContainer = $Margin/Content/FilterRow
@onready var _list_rows: VBoxContainer = $Margin/Content/Scroll/Column/ListRows
@onready var _detail_rows: VBoxContainer = $Margin/Content/Scroll/Column/DetailRows
@onready var _hint: Label = $Margin/Content/HintLabel

var _tab: String = "players"
var _busy := false
var _query := ""
var _filter := ""
var _summary: Dictionary = {}
var _config_items: Array = []


func _ready() -> void:
	for child in _tabs_row.get_children():
		if child is Button:
			child.pressed.connect(_on_tab_pressed.bind(child))
	_search_button.pressed.connect(_on_search)
	_search_edit.text_submitted.connect(_on_search_submitted)
	if not App.auth.is_staff():
		_set_hint("Staff access required.")
		_tabs_row.visible = false
		_search_row.visible = false
		_filter_row.visible = false
		return
	_select_tab_visual()
	await _load()


func _on_search_submitted(_text: String) -> void:
	await _on_search()


func _on_search() -> void:
	_query = _search_edit.text.strip_edges()
	_tab = "players"
	_filter = ""
	_select_tab_visual()
	await _load()


func _on_tab_pressed(button: Button) -> void:
	for key in TABS:
		if str(TABS[key]) == button.name:
			_tab = key
			break
	_filter = ""
	_clear(_detail_rows)
	_select_tab_visual()
	await _load()


func _on_filter_pressed(value: String) -> void:
	_filter = value
	_clear(_detail_rows)
	await _load()


func _select_tab_visual() -> void:
	for child in _tabs_row.get_children():
		if child is Button:
			(child as Button).set_pressed_no_signal(child.name == TABS.get(_tab, ""))
	_search_row.visible = _tab == "players"
	_filter_row.visible = _filter_row.get_child_count() > 0


# --- Loading -----------------------------------------------------------------

func _load() -> void:
	if _busy:
		return
	if not App.auth.is_staff():
		_set_hint("Staff access required.")
		return
	_busy = true
	_hint.visible = false
	_render_filters()
	var res: Dictionary = {}
	match _tab:
		"players":
			res = await App.admin.players(_query, 1, 20)
		"games":
			res = await App.admin.matches(_filter, 1, 20)
		"economy":
			res = await _load_economy()
		"content":
			res = await App.admin.cosmetics(_filter, 1, 50)
		"config":
			res = await App.admin.config_entries()
		"audit":
			res = await App.admin.audit_log(1, 20)
	_busy = false
	if not bool(res.get("ok", false)):
		_set_hint(_error_text(res))
		return
	_render(res)


func _load_economy() -> Dictionary:
	var summary_res: Dictionary = await App.admin.economy_summary()
	if not bool(summary_res.get("ok", false)):
		return summary_res
	_summary = summary_res.body if summary_res.body is Dictionary else {}
	match _filter:
		"ads":
			return await App.admin.ad_shows(1, 20)
		"purchases":
			return await App.admin.purchases(1, 20)
		_:
			return await App.admin.transactions("", "", 1, 20)


func _render_filters() -> void:
	var pairs: Array = []
	match _tab:
		"games":
			pairs = GAME_FILTERS
		"economy":
			pairs = ECONOMY_FILTERS
		"content":
			pairs = CONTENT_FILTERS
	_clear(_filter_row)
	var idx := 0
	for pair in pairs:
		var value := str(pair[1])
		var button := _make_button(str(pair[0]), "Filter_%d" % idx)
		button.toggle_mode = true
		button.set_pressed_no_signal(value == _filter)
		button.pressed.connect(_on_filter_pressed.bind(value))
		_filter_row.add_child(button)
		idx += 1
	_filter_row.visible = pairs.size() > 0


func _render(res: Dictionary) -> void:
	_clear(_list_rows)
	var body: Dictionary = res.body if res.body is Dictionary else {}
	match _tab:
		"players":
			_render_players(body)
		"games":
			_render_games(body)
		"economy":
			_render_economy(body)
		"content":
			_render_content(body)
		"config":
			_render_config(body)
		"audit":
			_render_audit(body)


# --- Players tab -------------------------------------------------------------

func _render_players(body: Dictionary) -> void:
	var items := _items(body)
	if items.is_empty():
		_list_rows.add_child(_label("No players match that search.", true))
		return
	for item in items:
		if item is Dictionary:
			_list_rows.add_child(_make_player_row(item as Dictionary))


func _make_player_row(item: Dictionary) -> HBoxContainer:
	var row := _hbox()
	row.name = "PlayerRow"
	row.add_child(_label(str(item.get("username", "?")), false))
	row.add_child(_chip(str(item.get("role", "USER"))))
	row.add_child(_status_chip(str(item.get("status", ""))))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var open := _make_button("Open", "OpenButton")
	open.pressed.connect(_open_player.bind(str(item.get("id", ""))))
	row.add_child(open)
	return row


func _open_player(player_id: String) -> void:
	if _busy:
		return
	_busy = true
	_hint.visible = false
	var detail_res: Dictionary = await App.admin.player(player_id)
	var wallet_res: Dictionary = {}
	var matches_res: Dictionary = {}
	if bool(detail_res.get("ok", false)):
		wallet_res = await App.admin.player_wallet(player_id, 1, 5)
		matches_res = await App.admin.player_matches(player_id, 1, 5)
	_busy = false
	if not bool(detail_res.get("ok", false)):
		_set_hint(_error_text(detail_res))
		return
	var body: Dictionary = detail_res.body if detail_res.body is Dictionary else {}
	_render_player_detail(body, wallet_res, matches_res)


func _render_player_detail(player: Dictionary, wallet_res: Dictionary,
		matches_res: Dictionary) -> void:
	_clear(_detail_rows)
	var player_id := str(player.get("id", ""))

	var head := _hbox()
	head.name = "PlayerDetail"
	head.add_child(_label(str(player.get("username", "?")), false))
	head.add_child(_status_chip(str(player.get("status", ""))))
	head.add_child(_chip(str(player.get("role", "USER"))))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	var close := _make_button("Close", "CloseDetailButton")
	close.pressed.connect(_close_detail)
	head.add_child(close)
	_detail_rows.add_child(head)

	var profile: Dictionary = _dict(player.get("profile"))
	_detail_rows.add_child(_label(
			"Rating %d · %d games · %dW %dL %dD" % [
			int(profile.get("rating", 0)), int(profile.get("gamesPlayed", 0)),
			int(profile.get("wins", 0)), int(profile.get("losses", 0)),
			int(profile.get("draws", 0))], true))

	var balance := 0
	var wallets_value: Variant = player.get("wallets", [])
	if wallets_value is Array and (wallets_value as Array).size() > 0:
		var first: Variant = (wallets_value as Array)[0]
		balance = int(_dict(first).get("balance", 0))
	var ledger_total := 0
	if bool(wallet_res.get("ok", false)):
		var wallet_body: Dictionary = _dict(wallet_res.body)
		balance = int(wallet_body.get("balance", balance))
		ledger_total = int(wallet_body.get("total", 0))
	_detail_rows.add_child(_label("Coins: %d · %d ledger entries" % [balance, ledger_total],
			false))

	if bool(wallet_res.get("ok", false)):
		_detail_rows.add_child(_label("Recent wallet", true))
		for tx in _items(_dict(wallet_res.body)):
			if tx is Dictionary:
				_detail_rows.add_child(_make_wallet_row(tx as Dictionary))

	if bool(matches_res.get("ok", false)):
		_detail_rows.add_child(_label("Recent matches", true))
		for match_row in _items(_dict(matches_res.body)):
			if match_row is Dictionary:
				_detail_rows.add_child(_make_match_row(match_row as Dictionary))

	var actions := _hbox()
	actions.name = "PlayerActions"
	var suspend := _make_button("Suspend", "SuspendButton")
	suspend.pressed.connect(_change_status.bind(player_id, "SUSPENDED"))
	actions.add_child(suspend)
	var ban := _make_button("Ban", "BanButton")
	ban.pressed.connect(_change_status.bind(player_id, "BANNED"))
	actions.add_child(ban)
	var unban := _make_button("Unban", "UnbanButton")
	unban.pressed.connect(_change_status.bind(player_id, "ACTIVE"))
	actions.add_child(unban)
	_detail_rows.add_child(actions)


func _make_wallet_row(tx: Dictionary) -> HBoxContainer:
	var row := _hbox()
	row.name = "WalletRow"
	var amount := int(tx.get("amount", 0))
	var amount_label := _label("%+d" % amount, false)
	amount_label.modulate = AppTheme.C_SUCCESS if amount >= 0 else AppTheme.C_DANGER
	row.add_child(amount_label)
	row.add_child(_chip(str(tx.get("type", ""))))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	row.add_child(_label(str(tx.get("memo", "")), true))
	return row


func _close_detail() -> void:
	_clear(_detail_rows)


func _change_status(player_id: String, status: String) -> void:
	if _busy:
		return
	_busy = true
	_hint.visible = false
	var res: Dictionary = await App.admin.set_status(player_id, status,
			"dashboard action")
	_busy = false
	if not bool(res.get("ok", false)):
		_set_hint(_error_text(res))
		return
	await _load()
	await _open_player(player_id)
	_set_hint("Status set to %s." % status)


# --- Games tab ---------------------------------------------------------------

func _render_games(body: Dictionary) -> void:
	var items := _items(body)
	if items.is_empty():
		_list_rows.add_child(_label("No matches in this state.", true))
		return
	for item in items:
		if item is Dictionary:
			_list_rows.add_child(_make_match_row(item as Dictionary))


func _make_match_row(item: Dictionary) -> HBoxContainer:
	var row := _hbox()
	row.name = "MatchRow"
	var game: Dictionary = _dict(item.get("game"))
	row.add_child(_label(str(game.get("name", game.get("key", "?"))), false))
	row.add_child(_status_chip(str(item.get("status", ""))))
	var names: Array = []
	var players_value: Variant = item.get("players", [])
	if players_value is Array:
		for entry in players_value as Array:
			if entry is Dictionary:
				var user: Dictionary = _dict(_dict(entry).get("user"))
				names.append(str(user.get("username", "?")))
	if not names.is_empty():
		row.add_child(_label(", ".join(names), true))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	row.add_child(_label(str(item.get("createdAt", "")), true))
	return row


# --- Economy tab -------------------------------------------------------------

func _render_economy(body: Dictionary) -> void:
	_list_rows.add_child(_label(_summary_text(), false))
	var items := _items(body)
	if items.is_empty():
		_list_rows.add_child(_label("Nothing recorded yet.", true))
		return
	for item in items:
		if item is Dictionary:
			_list_rows.add_child(_make_economy_row(item as Dictionary))


func _summary_text() -> String:
	if _summary.is_empty():
		return "Summary unavailable."
	var ads: Dictionary = _dict(_summary.get("rewardedAds"))
	var purchases: Dictionary = _dict(_summary.get("purchases"))
	return ("Issued %d · Spent %d · Transactions %d · Ad grants %d (%d coins) "
			+ "· Purchases %d") % [
			int(_summary.get("coinsIssued", 0)),
			int(_summary.get("coinsSpent", 0)),
			int(_summary.get("transactions", 0)),
			int(ads.get("grants", 0)),
			int(ads.get("coinsGranted", 0)),
			int(purchases.get("count", 0)),
	]


func _make_economy_row(item: Dictionary) -> HBoxContainer:
	var row := _hbox()
	row.name = "EconomyRow"
	match _filter:
		"ads":
			row.add_child(_label(str(item.get("username", "?")), false))
			row.add_child(_chip(str(item.get("kind", ""))))
			var ad_spacer := Control.new()
			ad_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(ad_spacer)
			row.add_child(_label(str(item.get("shownAt", "")), true))
		"purchases":
			row.add_child(_label(str(item.get("username", "?")), false))
			row.add_child(_label(str(item.get("productKey", "")), true))
			row.add_child(_chip(str(item.get("state", ""))))
			row.add_child(_label("%d coins" % int(item.get("coinAmount", 0)), false))
		_:
			var amount := int(item.get("amount", 0))
			var amount_label := _label("%+d" % amount, false)
			amount_label.modulate = AppTheme.C_SUCCESS if amount >= 0 \
					else AppTheme.C_DANGER
			row.add_child(amount_label)
			row.add_child(_label(str(item.get("username", "?")), false))
			row.add_child(_chip(str(item.get("type", ""))))
			var spacer := Control.new()
			spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(spacer)
			row.add_child(_label(str(item.get("memo", "")), true))
	return row


# --- Content tab -------------------------------------------------------------

func _render_content(body: Dictionary) -> void:
	var items := _items(body)
	if items.is_empty():
		_list_rows.add_child(_label("No cosmetics found.", true))
		return
	for item in items:
		if item is Dictionary:
			_list_rows.add_child(_make_cosmetic_row(item as Dictionary))


func _make_cosmetic_row(item: Dictionary) -> HBoxContainer:
	var row := _hbox()
	row.name = "CosmeticRow"
	row.add_child(_label(str(item.get("name", item.get("key", "?"))), false))
	row.add_child(_label(str(item.get("category", "")), true))
	row.add_child(_chip(str(item.get("tier", ""))))
	row.add_child(_label("%d coins" % int(item.get("price", 0)), false))
	var active := bool(item.get("active", true))
	var live := _chip("Live" if active else "Hidden")
	live.modulate = AppTheme.C_SUCCESS if active else AppTheme.C_TEXT_DISABLED
	row.add_child(live)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var open := _make_button("Open", "OpenButton")
	open.pressed.connect(_open_cosmetic.bind(item))
	row.add_child(open)
	return row


func _open_cosmetic(item: Dictionary) -> void:
	_clear(_detail_rows)
	var detail := _hbox()
	detail.name = "CosmeticDetail"
	detail.add_child(_label(str(item.get("name", item.get("key", "?"))), false))
	var price_edit := LineEdit.new()
	price_edit.name = "PriceEdit"
	price_edit.text = str(int(item.get("price", 0)))
	price_edit.custom_minimum_size = Vector2(90, 0)
	detail.add_child(price_edit)
	var save := _make_button("Save price", "SavePriceButton")
	save.pressed.connect(_save_price.bind(str(item.get("id", ""))))
	detail.add_child(save)
	var active := bool(item.get("active", true))
	var toggle := _make_button("Disable" if active else "Enable", "ToggleButton")
	toggle.pressed.connect(_toggle_cosmetic.bind(str(item.get("id", "")), not active))
	detail.add_child(toggle)
	var close := _make_button("Close", "CloseDetailButton")
	close.pressed.connect(_close_detail)
	detail.add_child(close)
	_detail_rows.add_child(detail)


func _save_price(cosmetic_id: String) -> void:
	var edit: Node = find_child("PriceEdit", true, false)
	if _busy or not (edit is LineEdit):
		return
	_busy = true
	_hint.visible = false
	var res: Dictionary = await App.admin.update_cosmetic(cosmetic_id,
			{"price": int((edit as LineEdit).text.strip_edges())})
	_busy = false
	if not bool(res.get("ok", false)):
		_set_hint(_error_text(res))
		return
	await _load()
	if res.body is Dictionary:
		_open_cosmetic(res.body as Dictionary)
	_set_hint("Price saved.")


func _toggle_cosmetic(cosmetic_id: String, active: bool) -> void:
	if _busy:
		return
	_busy = true
	_hint.visible = false
	var res: Dictionary = await App.admin.update_cosmetic(cosmetic_id,
			{"active": active})
	_busy = false
	if not bool(res.get("ok", false)):
		_set_hint(_error_text(res))
		return
	await _load()
	if res.body is Dictionary:
		_open_cosmetic(res.body as Dictionary)
	_set_hint("Cosmetic %s." % ("enabled" if active else "disabled"))


# --- Config tab --------------------------------------------------------------

func _render_config(body: Dictionary) -> void:
	_config_items = _items(body)
	if _config_items.is_empty():
		_list_rows.add_child(_label("No configuration keys available.", true))
		return
	for entry in _config_items:
		if not (entry is Dictionary):
			continue
		var item := entry as Dictionary
		var key := str(item.get("key", ""))
		var row := _hbox()
		row.name = "ConfigRow"
		var label := _label(str(item.get("label", key)), false)
		label.custom_minimum_size = Vector2(300, 0)
		row.add_child(label)
		var node_name := "Value_" + key.replace(".", "_")
		if str(item.get("kind", "")) == "bool":
			var check := CheckBox.new()
			check.name = node_name
			check.button_pressed = bool(item.get("value", false))
			row.add_child(check)
		else:
			var edit := LineEdit.new()
			edit.name = node_name
			edit.text = str(int(item.get("value", 0)))
			edit.custom_minimum_size = Vector2(110, 0)
			row.add_child(edit)
		if bool(item.get("overridden", false)):
			row.add_child(_chip("overridden"))
		_list_rows.add_child(row)
	var save := _make_button("Save configuration", "SaveConfigButton")
	save.pressed.connect(_on_save_config)
	_detail_rows.add_child(save)


func _on_save_config() -> void:
	if _busy:
		return
	var entries: Array = []
	for entry in _config_items:
		if not (entry is Dictionary):
			continue
		var item := entry as Dictionary
		var key := str(item.get("key", ""))
		var node_name := "Value_" + key.replace(".", "_")
		if str(item.get("kind", "")) == "bool":
			var check := find_child(node_name, true, false)
			if check is CheckBox:
				entries.append({"key": key, "value": (check as CheckBox).button_pressed})
		else:
			var edit := find_child(node_name, true, false)
			if edit is LineEdit:
				entries.append({"key": key,
						"value": int((edit as LineEdit).text.strip_edges())})
	_busy = true
	_hint.visible = false
	var res: Dictionary = await App.admin.save_config(entries)
	_busy = false
	if not bool(res.get("ok", false)):
		_set_hint(_error_text(res))
		return
	await _load()
	_set_hint("Configuration saved.")


# --- Audit tab ---------------------------------------------------------------

func _render_audit(body: Dictionary) -> void:
	var items := _items(body)
	if items.is_empty():
		_list_rows.add_child(_label("No admin actions recorded yet.", true))
		return
	for item in items:
		if item is Dictionary:
			_list_rows.add_child(_make_audit_row(item as Dictionary))


func _make_audit_row(item: Dictionary) -> HBoxContainer:
	var row := _hbox()
	row.name = "AuditRow"
	row.add_child(_chip(str(item.get("action", ""))))
	row.add_child(_label(str(item.get("actor", "?")), false))
	var target := str(item.get("targetId", ""))
	if target.is_empty():
		target = str(item.get("targetType", ""))
	row.add_child(_label(target, true))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	row.add_child(_label(str(item.get("createdAt", "")), true))
	return row


# --- Small helpers ------------------------------------------------------------

func _items(body: Dictionary) -> Array:
	var value: Variant = body.get("items", [])
	return value if value is Array else []


func _dict(value: Variant) -> Dictionary:
	if value is Dictionary:
		return value as Dictionary
	return {}


func _clear(container: Container) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _hbox() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	return row


func _label(text: String, caption: bool) -> Label:
	var label := Label.new()
	label.text = text
	if caption:
		label.theme_type_variation = "Caption"
	return label


func _chip(text: String) -> Label:
	var chip := Label.new()
	chip.text = text
	chip.modulate = AppTheme.C_ACCENT
	return chip


func _status_chip(status: String) -> Label:
	var chip := _chip(status)
	if status == "BANNED" or status == "SUSPENDED":
		chip.modulate = AppTheme.C_DANGER
	elif status == "ACTIVE":
		chip.modulate = AppTheme.C_SUCCESS
	return chip


func _make_button(text: String, node_name: String) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.custom_minimum_size = Vector2(0, 32)
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return button


func _set_hint(text: String) -> void:
	_hint.text = text
	_hint.visible = true


func _error_text(res: Dictionary) -> String:
	var kind := int(res.get("error_kind", ApiClient.ErrorKind.NONE))
	if kind == ApiClient.ErrorKind.NETWORK \
			or kind == ApiClient.ErrorKind.SERVER_UNAVAILABLE:
		return "You appear to be offline \u2014 admin data needs a connection."
	var message := str(res.get("message", ""))
	return message if not message.is_empty() else "Request failed."


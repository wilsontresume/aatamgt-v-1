extends Control
## Phase 13: shop — coin packs and the Royal Pass.
##
## Prices are whatever the store reports (Play Billing in
## production, the dev store simulator in development); the screen
## never invents one. Buy only succeeds once the backend has
## verified the store token and settled the grant — the hint line
## reports exactly what the server said.

@onready var _hint: Label = $Margin/Content/HintLabel
@onready var _coin_rows: VBoxContainer = \
		$Margin/Content/Scroll/Column/CoinRows
@onready var _pass_price: Label = \
		$Margin/Content/Scroll/Column/PassPanel/PassBody/PassPrice
@onready var _pass_status: Label = \
		$Margin/Content/Scroll/Column/PassPanel/PassBody/PassStatus
@onready var _buy_pass: Button = \
		$Margin/Content/Scroll/Column/PassPanel/PassBody/PassButtons/BuyPassButton
@onready var _restore: Button = \
		$Margin/Content/Scroll/Column/PassPanel/PassBody/PassButtons/RestoreButton

var _busy := false


func _ready() -> void:
	_buy_pass.pressed.connect(func() -> void: _buy(ShopService.ROYAL_PASS_KEY))
	_restore.pressed.connect(_on_restore)
	_reload()


func _reload() -> void:
	if _busy:
		return
	_busy = true
	_hint.text = "Loading the store\u2026"
	var res: Dictionary = await App.shop.refresh()
	_busy = false
	if not res.ok:
		_hint.text = _error_text(res)
		await _reload_pass_status()
		return
	_hint.text = ""
	_render_catalog()
	await _reload_pass_status()


# --- Catalog -----------------------------------------------------------------

func _render_catalog() -> void:
	for child in _coin_rows.get_children():
		_coin_rows.remove_child(child)
		child.queue_free()
	for product in App.shop.products():
		if product is Dictionary and str(product.get("kind", "")) == "COINS":
			_coin_rows.add_child(_make_coin_row(product))
	var pass_price := App.shop.price_text(ShopService.ROYAL_PASS_KEY)
	_pass_price.text = pass_price if not pass_price.is_empty() else "\u2014"


func _make_coin_row(product: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 2)
	var title := Label.new()
	title.text = str(product.get("title", product.get("productKey", "")))
	info.add_child(title)
	var subtitle := Label.new()
	subtitle.theme_type_variation = "Caption"
	subtitle.text = "%d coins" % int(product.get("coins", 0))
	info.add_child(subtitle)
	row.add_child(info)

	var price := Label.new()
	var price_text := str(product.get("price_text", ""))
	price.text = price_text if not price_text.is_empty() else "\u2014"
	price.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(price)

	var buy := Button.new()
	buy.text = "Buy"
	buy.custom_minimum_size = Vector2(0, 32)
	buy.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	buy.pressed.connect(_buy.bind(str(product.get("productKey", ""))))
	row.add_child(buy)
	return row


# --- Actions -----------------------------------------------------------------

func _buy(product_key: String) -> void:
	if _busy:
		return
	_busy = true
	_hint.text = "Verifying purchase with the store\u2026"
	var res: Dictionary = await App.shop.buy(product_key)
	_busy = false
	if not res.ok:
		_hint.text = str(res.get("error", "The purchase could not be completed."))
		return
	match str(res.get("status", "")):
		"pending":
			_hint.text = "The store marked this purchase as pending \u2014 " \
					+ "it settles automatically once the store clears it."
		"already_processed":
			_hint.text = "You already own this purchase \u2014 nothing was charged twice."
		_:
			_hint.text = "Purchase verified \u2014 your balance is updated."
	await _reload_pass_status()


func _on_restore() -> void:
	if _busy:
		return
	_busy = true
	_hint.text = "Checking your store purchases\u2026"
	var res: Dictionary = await App.shop.restore()
	_busy = false
	if not res.ok:
		_hint.text = str(res.get("error", "Restore failed."))
		return
	var restored := int(res.get("restored", 0))
	_hint.text = ("%d purchase(s) restored from the store." % restored) \
			if restored > 0 else "Nothing new to restore \u2014 you are up to date."
	var royal_pass: Dictionary = res.get("royalPass", {})
	if royal_pass is Dictionary and not royal_pass.is_empty():
		_pass_status.text = _pass_text(royal_pass)
	await _reload_pass_status()


func _reload_pass_status() -> void:
	if not App.auth.is_authenticated():
		_pass_status.text = "Sign in to buy or check your Royal Pass."
		_buy_pass.disabled = true
		_restore.disabled = true
		return
	_buy_pass.disabled = false
	_restore.disabled = false
	var res: Dictionary = await App.shop.entitlement()
	if not res.ok:
		_pass_status.text = "Pass status unavailable right now."
		return
	_pass_status.text = _pass_text(res.body)


# --- Helpers -------------------------------------------------------------------

static func _pass_text(status: Dictionary) -> String:
	var unix_value: Variant = status.get("expiresAtUnix", 0)
	var unix := 0 if unix_value == null else int(unix_value)
	if bool(status.get("active", false)):
		return "Active until %s (UTC)" % _format_unix(unix)
	if unix > 0:
		return "Expired since %s (UTC)" % _format_unix(unix)
	return "Not active."


static func _format_unix(unix: int) -> String:
	if unix <= 0:
		return "\u2014"
	return Time.get_datetime_string_from_unix_time(unix, true)


func _error_text(res: Dictionary) -> String:
	var kind := int(res.get("error_kind", ApiClient.ErrorKind.NONE))
	if kind == ApiClient.ErrorKind.NETWORK \
			or kind == ApiClient.ErrorKind.SERVER_UNAVAILABLE:
		return "You appear to be offline \u2014 the store needs a connection."
	var message := str(res.get("message", ""))
	return message if not message.is_empty() else "Could not load the store."

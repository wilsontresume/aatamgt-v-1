extends Control
## Cosmetic inventory (Phase 12): renders the server-owned catalog —
## owned / equipped / locked, free / premium — and forwards the allowed
## actions (claim, buy, equip, dev-grant) to the server. The client
## performs no inventory math: every state shown here came from
## GET /cosmetics.

@onready var _hint: Label = $Margin/Content/HintLabel
@onready var _sections: VBoxContainer = $Margin/Content/Scroll/Sections

var _busy := false


func _ready() -> void:
	App.cosmetics.inventory_changed.connect(_on_inventory_changed)
	reload()


func _on_inventory_changed() -> void:
	_render()


# --- Loading -----------------------------------------------------------------

func reload() -> void:
	if _busy:
		return
	if not App.auth.is_authenticated():
		_render_signed_out()
		return
	_busy = true
	var res: Dictionary = await App.cosmetics.refresh()
	_busy = false
	if not res.ok:
		_show_load_error(res)
	_render()


func _render_signed_out() -> void:
	_clear_sections()
	_hint.visible = true
	_hint.text = "Sign in to view and equip your cosmetics."


func _show_load_error(res: Dictionary) -> void:
	var kind := int(res.get("error_kind", ApiClient.ErrorKind.NONE))
	if kind == ApiClient.ErrorKind.NETWORK \
			or kind == ApiClient.ErrorKind.SERVER_UNAVAILABLE:
		_hint.visible = true
		_hint.text = "Inventory unavailable \u2014 you appear to be offline."
		return
	App.dialog.show_error("Could not load inventory",
			str(res.get("message", "")))


# --- Rendering ---------------------------------------------------------------

func _render() -> void:
	_clear_sections()
	if App.cosmetics.items.is_empty():
		_hint.visible = true
		if not App.auth.is_authenticated():
			_hint.text = "Sign in to view and equip your cosmetics."
		elif _hint.text.is_empty():
			_hint.text = "Inventory unavailable \u2014 try again later."
		return
	for category in CosmeticService.CATEGORY_ORDER:
		_sections.add_child(_make_section(category))
	_hint.visible = true
	_hint.text = "Equipped cosmetics apply across menus and games."


func _clear_sections() -> void:
	for child in _sections.get_children():
		_sections.remove_child(child)
		child.queue_free()


func _make_section(category: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.theme_type_variation = "Card"
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	panel.add_child(body)
	var heading := Label.new()
	heading.theme_type_variation = "Heading"
	heading.text = str(CosmeticService.CATEGORY_TITLES.get(category, category))
	body.add_child(heading)
	for item in App.cosmetics.items_in_category(category):
		body.add_child(_make_item_row(item))
	return panel


func _make_item_row(item: Dictionary) -> HBoxContainer:
	var state := CosmeticService.state_of(item)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 2)
	var title := Label.new()
	title.text = str(item.get("name", ""))
	info.add_child(title)
	var subtitle := Label.new()
	subtitle.theme_type_variation = "Caption"
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var description := str(item.get("description", ""))
	var tier := CosmeticService.tier_label(item)
	subtitle.text = ("%s \u00b7 %s" % [description, tier]) \
			if not description.is_empty() else tier
	info.add_child(subtitle)
	row.add_child(info)

	var chip := Label.new()
	chip.text = _state_label(state)
	chip.theme_type_variation = "Caption"
	chip.modulate = _state_color(state)
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(chip)

	if App.cosmetics.dev_grants_enabled and state == "locked":
		row.add_child(_make_action("Grant",
				func() -> void: _act(item, "grant")))
	match state:
		"locked":
			var text := "Buy" if CosmeticService.is_premium(item) else "Claim"
			row.add_child(_make_action(text,
					func() -> void: _act(item, "buy" if CosmeticService.is_premium(item) else "claim")))
		"owned":
			row.add_child(_make_action("Equip", func() -> void: _act(item, "equip")))
		_:
			row.add_child(_make_action("Equipped", func() -> void: null, true))
	return row


func _state_label(state: String) -> String:
	match state:
		"equipped":
			return "Equipped"
		"owned":
			return "Owned"
		_:
			return "Locked"


func _state_color(state: String) -> Color:
	match state:
		"equipped":
			return AppTheme.C_ACCENT
		"owned":
			return AppTheme.C_SUCCESS
		_:
			return AppTheme.C_TEXT_DISABLED


func _make_action(text: String, pressed: Callable,
		disabled: bool = false) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, 32)
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.disabled = disabled
	button.pressed.connect(pressed)
	return button


# --- Actions -----------------------------------------------------------------

func _act(item: Dictionary, action: String) -> void:
	if _busy:
		return
	_busy = true
	var key := str(item.get("key", ""))
	var res: Dictionary = {}
	match action:
		"claim":
			res = await App.cosmetics.claim(key)
		"buy":
			res = await App.cosmetics.purchase(key)
		"equip":
			res = await App.cosmetics.equip(key)
		"grant":
			res = await App.cosmetics.dev_grant(key)
		_:
			pass
	_busy = false
	if not res.ok:
		_hint.visible = true
		_hint.text = _error_text(res)
		return
	_render()  # the refresh already re-pulled; rebuild from the new cache


func _error_text(res: Dictionary) -> String:
	var kind := int(res.get("error_kind", ApiClient.ErrorKind.NONE))
	if kind == ApiClient.ErrorKind.NETWORK \
			or kind == ApiClient.ErrorKind.SERVER_UNAVAILABLE:
		return "You appear to be offline \u2014 nothing was changed."
	var message := str(res.get("message", ""))
	return message if not message.is_empty() else "Something went wrong."

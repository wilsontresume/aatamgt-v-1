extends Control
## Phase 11: completed matches with results and a rematch shortcut.
## Rematch creates a fresh share challenge for the same game — the
## opponent accepts it through the normal challenge flow.

@onready var _list: VBoxContainer = \
		$Margin/Content/HistoryPanel/HistoryBody/HistoryList
@onready var _hint: Label = $Margin/Content/HistoryPanel/HistoryBody/HistoryHint
@onready var _reload_button: Button = \
		$Margin/Content/ReloadRow/ReloadButton

var _busy := false


func _ready() -> void:
	_reload_button.pressed.connect(func() -> void: reload())
	reload()


func reload() -> void:
	if _busy:
		return
	if not App.auth.is_authenticated():
		_clear()
		_hint.text = "Sign in to see your match history."
		_hint.visible = true
		return
	_busy = true
	var res: Dictionary = await App.social.match_history()
	_busy = false
	_clear()
	if not res.ok:
		_hint.visible = true
		_hint.text = "No completed matches yet."
		var kind := int(res.get("error_kind", ApiClient.ErrorKind.NONE))
		if kind != ApiClient.ErrorKind.NETWORK \
				and kind != ApiClient.ErrorKind.SERVER_UNAVAILABLE:
			App.dialog.show_error("Could not load history",
					str(res.get("message", "")))
		return
	var items: Variant = (res.body as Dictionary).get("items")
	var arr: Array = items if items is Array else []
	_hint.visible = arr.is_empty()
	_hint.text = "No completed matches yet \u2014 play a game first."
	for item in arr:
		if item is Dictionary:
			_list.add_child(_row(item))


func _clear() -> void:
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()


func _row(item: Dictionary) -> HBoxContainer:
	var me := App.auth.get_username()
	var opponent := "?"
	var my_result := ""
	var players: Variant = item.get("players")
	if players is Array:
		for p in players as Array:
			if not (p is Dictionary):
				continue
			var username := str((p as Dictionary).get("username", ""))
			if username == me:
				my_result = str((p as Dictionary).get("result", ""))
			elif opponent == "?":
				opponent = username

	var row := HBoxContainer.new()
	row.add_child(_labels(item, opponent))
	row.add_child(_result_label(my_result))

	var rematch := Button.new()
	rematch.text = "Rematch"
	rematch.custom_minimum_size = Vector2(110, 32)
	rematch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var game_key := str(item.get("gameKey", ""))
	rematch.pressed.connect(func() -> void: _rematch(game_key, opponent))
	row.add_child(rematch)
	return row


func _labels(item: Dictionary, opponent: String) -> VBoxContainer:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(_label(SocialService.game_title(str(item.get("gameKey", ""))),
			"Body"))
	column.add_child(_label("vs %s \u00b7 %s" % [opponent,
			_date_of(str(item.get("completedAt", str(item.get("createdAt", "")))))],
			"Caption"))
	return column


func _label(text: String, variation: String) -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = variation
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _result_label(result: String) -> Label:
	var label := Label.new()
	label.theme_type_variation = "Body"
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	label.custom_minimum_size = Vector2(72, 0)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	match result:
		"WIN":
			label.text = "Won"
			label.add_theme_color_override("font_color", AppTheme.C_SUCCESS)
		"LOSS":
			label.text = "Lost"
			label.add_theme_color_override("font_color", AppTheme.C_DANGER)
		"DRAW":
			label.text = "Draw"
		"ABANDONED":
			label.text = "Left"
			label.add_theme_color_override("font_color",
					AppTheme.C_TEXT_SECONDARY)
		_:
			label.text = "\u2014"
			label.add_theme_color_override("font_color",
					AppTheme.C_TEXT_SECONDARY)
	return label


func _date_of(iso: String) -> String:
	if iso.is_empty():
		return ""
	var unix := OnlineMatchService._iso_to_unix(iso)
	if unix <= 0.0:
		return ""
	var d := Time.get_datetime_dict_from_unix_time(int(unix))
	return "%04d-%02d-%02d %02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute]


## Rematch = a new challenge for the same game, addressed to the same
## opponent. The share text goes through the challenge screen.
func _rematch(game_key: String, opponent: String) -> void:
	if opponent == "?" or game_key.is_empty():
		return
	App.social.set_pending({
		"mode": "rematch",
		"game_key": game_key,
		"invitee": opponent,
	})
	App.navigation.go(&"challenge")

extends Control
## Multiplayer-first game entry (Workflow Change 2). PLAY on the main
## menu lands here: pick a coin tier, then Play with Friend or Play
## Online. Tiers are loaded from the backend — no hard-coded catalog.
## Hot-seat / local VsAI remain available inside each game screen when
## the player opens it without an entry-flow hand-off.

const GAME_TITLES := {
	"aadu-puli-aattam": "Aadu Puli Aattam",
	"solah-seedi": "Solah Seedi",
	"nine-mens-morris": "Nine Men's Morris",
}

@onready var _title_label: Label = $Margin/Content/TitleBanner/TitleVBox/TitleLabel
@onready var _coins_label: Label = \
		$Margin/Content/CoinsPanel/CoinsHBox/CoinsVBox/CoinsLabel
@onready var _tiers_row: HBoxContainer = $Margin/Content/TiersRow
@onready var _tier_detail: Label = $Margin/Content/TierDetail
@onready var _retry_button: Button = $Margin/Content/RetryButton
@onready var _actions_row: Control = $Margin/Content/ActionsRow
@onready var _play_with_label: Label = $Margin/Content/PlayWithLabel
@onready var _friend_button: Button = $Margin/Content/ActionsRow/FriendButton
@onready var _online_button: Button = $Margin/Content/ActionsRow/OnlineButton
@onready var _status_label: Label = $Margin/Content/StatusLabel
@onready var _queue_panel: Control = $Margin/Content/QueuePanel
@onready var _queue_label: Label = \
		$Margin/Content/QueuePanel/QueueVBox/QueueLabel
@onready var _cancel_button: Button = \
		$Margin/Content/QueuePanel/QueueVBox/CancelButton
@onready var _back_button: Control = $Margin/Content/TopBar

var _game_key := OnlineMatchService.AADU_PULI_KEY
var _screen_id: StringName = &"aadu_puli"
var _selected_tier := ""  # No tier selected until the player chooses one
var _tiers: Dictionary = {}  # id -> {id, label, costCoins, rewardMultiplierBp, rewardCoins}
var _tier_buttons: Dictionary = {}  # id -> Button (built dynamically)
var _queueing := false
var _poll_timer: Timer
var _pending_params: Dictionary = {}


func apply_params(params: Dictionary) -> void:
	_pending_params = params
	# main.gd may call this before or after _ready; apply immediately when
	# the node is already live so the title/tier reflect the selection.
	if is_node_ready() and not _pending_params.is_empty():
		_apply_params(_pending_params)
		_pending_params = {}
		_title_label.text = GAME_TITLES.get(_game_key, _game_key)


func _ready() -> void:
	if not _pending_params.is_empty():
		_apply_params(_pending_params)
		_pending_params = {}
	else:
		# No hand-off params (back stack, deep link): use the carousel.
		_apply_params({"game_id": String(App.selected_game)})
	_title_label.text = GAME_TITLES.get(_game_key, _game_key)
	_queue_panel.visible = false
	# Hide Play actions until a tier is selected (workflow requirement).
	_set_actions_visible(false)
	_retry_button.visible = false
	_retry_button.pressed.connect(_load_tiers)
	_friend_button.pressed.connect(_on_friend_pressed)
	_online_button.pressed.connect(_on_online_pressed)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	_poll_timer = Timer.new()
	_poll_timer.wait_time = MatchmakingService.POLL_INTERVAL
	_poll_timer.one_shot = false
	_poll_timer.timeout.connect(_on_poll_timeout)
	add_child(_poll_timer)
	_refresh_coins()
	_load_tiers()
	# Boot-straight-into-online (challenge accepted / rematch) still works.
	if App.online.consume_auto_online():
		_enter_game_online()


func _exit_tree() -> void:
	if _poll_timer != null and not _poll_timer.is_stopped():
		_poll_timer.stop()
		# Leaving mid-queue: never leave a ghost WAITING ticket.
		if _queueing:
			var _ignored: Dictionary = await App.matchmaking.cancel_queue()


func _set_actions_visible(vis: bool) -> void:
	_actions_row.visible = vis
	_play_with_label.visible = vis


func _apply_params(params: Dictionary) -> void:
	var gid := str(params.get("game_id", "aadu_puli"))
	_screen_id = StringName(gid)
	_game_key = MatchmakingService.game_key_for(_screen_id)
	App.online.set_game_key(_game_key)


func _clear_tier_buttons() -> void:
	for id in _tier_buttons:
		var btn: Button = _tier_buttons[id]
		if is_instance_valid(btn):
			btn.queue_free()
	_tier_buttons.clear()


func _build_tier_button(tier: Dictionary) -> Button:
	var btn := Button.new()
	btn.toggle_mode = true
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size = Vector2(0, 240)
	btn.theme_type_variation = _tier_variation(str(tier.get("label",
			str(tier.get("id", "?")))))
	var label := str(tier.get("label", tier.get("id", "?")))
	var cost := int(tier.get("costCoins", 0))
	var reward := int(tier.get("rewardCoins", 0))
	# Rich card content: name, coin art placeholder, cost/reward rows.
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 6)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	btn.add_child(vb)
	var name_label := Label.new()
	name_label.text = label
	name_label.theme_type_variation = "TierName"
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Phase E: published tier display color/description from the manifest.
	var display := {}
	if App != null and App.content != null:
		display = App.content.tier_display(str(tier.get("id", "")))
	var tier_color: Variant = display.get("color", null)
	if tier_color is Color:
		name_label.add_theme_color_override("font_color", tier_color)
	vb.add_child(name_label)
	var art := _TierArt.new()
	art.tier_label = label
	art.art_asset_id = str(display.get("art_id", ""))
	art.custom_minimum_size = Vector2(0, 64)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(art)
	var description := str(display.get("description", ""))
	if not description.is_empty():
		var desc := Label.new()
		desc.text = description
		desc.theme_type_variation = "Caption"
		desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(desc)
	if cost == 0:
		_add_tier_row(vb, "Free play", "")
	else:
		_add_tier_row(vb, "Entry Cost", "%d" % cost)
		_add_tier_row(vb, "Win Reward", "%d" % reward, true)
	# Selected checkmark overlay.
	var check := _TierCheck.new()
	check.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	check.position = Vector2(-30, 6)
	check.mouse_filter = Control.MOUSE_FILTER_IGNORE
	check.visible = false
	btn.add_child(check)
	btn.set_meta("check", check)
	btn.pressed.connect(_on_tier_pressed.bind(str(tier.get("id", ""))))
	return btn


func _add_tier_row(parent: Control, caption: String, value: String,
		is_reward: bool = false) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(row)
	var cap := Label.new()
	cap.text = caption
	cap.theme_type_variation = "Caption"
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(cap)
	if not value.is_empty():
		var coin := _MiniCoin.new()
		coin.custom_minimum_size = Vector2(18, 18)
		coin.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(coin)
		var val := Label.new()
		val.text = value
		val.theme_type_variation = "TierReward" if is_reward else "TierCost"
		val.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(val)


func _tier_variation(label: String) -> String:
	var low := label.to_lower()
	if low.contains("bronze"):
		return "TierBronzeBtn"
	if low.contains("silver"):
		return "TierSilverBtn"
	if low.contains("gold"):
		return "TierGoldBtn"
	return "TierGenericBtn"


func _on_tier_pressed(tier_id: String) -> void:
	_selected_tier = tier_id
	for id in _tier_buttons:
		var btn: Button = _tier_buttons[id]
		btn.button_pressed = (id == tier_id)
		var check: Control = btn.get_meta("check", null)
		if check != null:
			check.visible = (id == tier_id)
	_refresh_tier_detail()
	# Reveal Play actions only after a valid tier is selected.
	_set_actions_visible(true)


# --- Small procedural decorations for tier cards -------------------------

class _MiniCoin extends Control:
	func _draw() -> void:
		var r := size.x * 0.5
		var c := Vector2(size.x * 0.5, size.y * 0.5)
		draw_circle(c, r, AppTheme.C_ACCENT)
		draw_arc(c, r - 1.5, 0.0, TAU, 24, AppTheme.C_ACCENT_PRESSED, 1.5, true)
		draw_circle(c, r * 0.55, AppTheme.C_ACCENT_PRESSED)


class _TierArt extends Control:
	var tier_label := "Bronze"
	var art_asset_id := ""

	func _ready() -> void:
		if art_asset_id.is_empty() and App != null and App.content != null:
			var display := App.content.tier_display_by_name(tier_label)
			art_asset_id = str(display.get("art_id", ""))
		if App != null and App.content != null \
				and not App.content.asset_ready.is_connected(_on_asset_ready):
			App.content.asset_ready.connect(_on_asset_ready)
		# Trigger a background download when the manifest references art.
		if App != null and App.content != null and not art_asset_id.is_empty():
			var _tex := App.content.texture_for(art_asset_id)

	func _on_asset_ready(_asset_id: String) -> void:
		if is_inside_tree():
			queue_redraw()

	func _draw() -> void:
		var art_tex: Texture2D = null
		if App != null and App.content != null and not art_asset_id.is_empty():
			art_tex = App.content.texture_for(art_asset_id)
		if art_tex != null:
			draw_texture_rect(art_tex, Rect2(Vector2.ZERO, size), true)
			return
		var w := size.x
		var h := size.y
		var cx := w * 0.5
		var cy := h * 0.55
		var low := tier_label.to_lower()
		if low.contains("gold"):
			# Treasure chest silhouette.
			var chest := Rect2(cx - 30, cy - 12, 60, 34)
			draw_rect(chest, Color("8d4a1a"))
			draw_rect(Rect2(chest.position, Vector2(60, 16)), Color("a85c22"))
			draw_rect(Rect2(cx - 32, cy - 16, 64, 8), AppTheme.C_GOLD_BRIGHT)
			draw_circle(Vector2(cx, cy + 4), 6, AppTheme.C_GOLD_BRIGHT)
			for i in 5:
				draw_circle(Vector2(cx - 22 + i * 11, cy - 20), 5,
						AppTheme.C_GOLD_BRIGHT)
		elif low.contains("silver"):
			for i in 3:
				draw_circle(Vector2(cx - 16 + i * 16, cy - 4), 11, Color("cfd8dc"))
				draw_circle(Vector2(cx - 16 + i * 16, cy - 4), 7, Color("b0bec5"))
			for i in 3:
				draw_circle(Vector2(cx - 8 + i * 16, cy + 10), 11, Color("eceff1"))
				draw_circle(Vector2(cx - 8 + i * 16, cy + 10), 7, Color("cfd8dc"))
		else:
			for i in 3:
				draw_circle(Vector2(cx - 16 + i * 16, cy - 4), 11, AppTheme.C_ACCENT)
				draw_circle(Vector2(cx - 16 + i * 16, cy - 4), 7, AppTheme.C_ACCENT_PRESSED)
			for i in 3:
				draw_circle(Vector2(cx - 8 + i * 16, cy + 10), 11, AppTheme.C_GOLD_BRIGHT)
				draw_circle(Vector2(cx - 8 + i * 16, cy + 10), 7, AppTheme.C_ACCENT)


class _TierCheck extends Control:
	func _draw() -> void:
		var r := 14.0
		var c := Vector2(r, r)
		draw_circle(c, r, AppTheme.C_SUCCESS)
		draw_arc(c, r - 1.5, 0.0, TAU, 24, Color.WHITE, 1.5, true)
		draw_polyline(PackedVector2Array([
			Vector2(c.x - 6, c.y), Vector2(c.x - 2, c.y + 4), Vector2(c.x + 6, c.y - 4),
		]), Color.WHITE, 2.5, true)


func _refresh_tier_detail() -> void:
	if _selected_tier.is_empty():
		_tier_detail.text = "Select a stake tier to continue"
		return
	var t: Dictionary = _tiers.get(_selected_tier, {})
	if t.is_empty():
		_tier_detail.text = "Tier details unavailable"
		return
	var cost := int(t.get("costCoins", 0))
	var reward := int(t.get("rewardCoins", 0))
	var detail := ""
	if cost == 0:
		detail = "Free play · winner keeps bragging rights"
	else:
		detail = "Entry %d coins · winner takes %d coins" % [cost, reward]
	# Phase E: append the published description when the manifest has one.
	if App != null and App.content != null:
		var display := App.content.tier_display(_selected_tier)
		var description := str(display.get("description", ""))
		if not description.is_empty():
			detail += "\n" + description
	_tier_detail.text = detail


func _load_tiers() -> void:
	if not App.auth.is_authenticated():
		_tier_detail.text = "Sign in to play online"
		_set_actions_visible(false)
		return
	_retry_button.visible = false
	_tier_detail.text = "Loading tiers…"
	var res: Dictionary = await App.matchmaking.list_tiers()
	if not res.ok:
		var msg := str(res.get("message", "Could not load tiers"))
		# Spec: do NOT fabricate tiers on failure — show error + retry.
		_tier_detail.text = msg
		_retry_button.visible = true
		_set_actions_visible(false)
		_clear_tier_buttons()
		_tiers.clear()
		_selected_tier = ""
		return
	var items: Array = res.body.get("items", [])
	if items.is_empty():
		_tier_detail.text = "No tiers available yet"
		_retry_button.visible = true
		_set_actions_visible(false)
		return
	_tiers.clear()
	_selected_tier = ""
	_clear_tier_buttons()
	for item in items:
		var id := str(item.get("id", ""))
		if id.is_empty():
			continue
		_tiers[id] = item
		var btn := _build_tier_button(item)
		_tiers_row.add_child(btn)
		_tier_buttons[id] = btn
	_set_actions_visible(false)
	_refresh_tier_detail()


func _refresh_coins() -> void:
	_coins_label.text = "%d coins" % App.coins.get_balance()


func _on_friend_pressed() -> void:
	if not App.auth.is_authenticated():
		App.navigation.go(&"auth")
		return
	if _selected_tier.is_empty():
		return
	App.analytics.track("entry_play_friend", {"tier": _selected_tier}, _game_key)
	App.matchmaking.set_pending({
		"game_key": _game_key,
		"tier_id": _selected_tier,
	})
	App.navigation.go(&"friend_challenge")


func _on_online_pressed() -> void:
	if not App.auth.is_authenticated():
		App.navigation.go(&"auth")
		return
	if _selected_tier.is_empty() or _queueing:
		return
	_queueing = true
	_online_button.disabled = true
	_friend_button.disabled = true
	_queue_panel.visible = true
	_queue_label.text = "Searching for an opponent…"
	_status_label.text = "Queued · %s" % _selected_tier
	App.analytics.track("entry_play_online", {"tier": _selected_tier}, _game_key)

	var res: Dictionary = await App.matchmaking.queue(_game_key, _selected_tier)
	if not res.ok:
		_end_queue()
		_status_label.text = str(res.get("message", "Could not start matchmaking"))
		return
	_handle_queue_result(res)


func _handle_queue_result(res: Dictionary) -> void:
	var body: Dictionary = res.get("body", {}) as Dictionary
	var status := str(body.get("status", ""))
	if status == "matched":
		_on_matched(body)
	elif status == "queued":
		_queue_label.text = "Searching… (AI opponent after a short wait)"
		_poll_timer.start()
	else:
		_end_queue()
		_status_label.text = "Unexpected matchmaking response"


func _on_poll_timeout() -> void:
	if not _queueing:
		return
	var res: Dictionary = await App.matchmaking.status()
	if not res.ok:
		return
	var body: Dictionary = res.get("body", {}) as Dictionary
	var status := str(body.get("status", "idle"))
	if status == "matched":
		_poll_timer.stop()
		_on_matched(body)
	elif status == "idle":
		_poll_timer.stop()
		_end_queue()
		_status_label.text = "Queue ended — try again"


func _on_matched(body: Dictionary) -> void:
	_queueing = false
	_poll_timer.stop()
	_queue_panel.visible = false
	_online_button.disabled = false
	_friend_button.disabled = false
	var vs_ai := bool(body.get("vsAi", false))
	var match_id := str(body.get("matchId", ""))
	if vs_ai:
		_status_label.text = "Matched vs AI · joining…"
	else:
		_status_label.text = "Opponent found · joining…"
	App.analytics.track("entry_matched", {"vsAi": vs_ai, "tier": _selected_tier}, _game_key)
	# Hand the game screen an auto-online session (seat + state from server).
	App.online.request_auto_online(match_id)
	App.navigation.go(_screen_id)


func _on_cancel_pressed() -> void:
	_poll_timer.stop()
	var _ignored: Dictionary = await App.matchmaking.cancel_queue()
	_end_queue()
	_status_label.text = "Search cancelled"


func _end_queue() -> void:
	_queueing = false
	_queue_panel.visible = false
	_online_button.disabled = false
	_friend_button.disabled = false
	_refresh_coins()


func _enter_game_online() -> void:
	App.navigation.go(_screen_id)

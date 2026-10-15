extends Control
## Colorful arcade lobby (main-menu redesign). Preserves every existing
## navigation target, the real wallet display (via TopBar/CoinBalance),
## auth session wiring and staff-gated Admin entry. The PLAY button
## opens the multiplayer-first game entry (tiers + Play with Friend /
## Play Online). Decorative nodes never intercept input.

const GameCardScript := preload("res://src/ui/menu/game_card.gd")

@onready var _top_bar: Control = $Margin/Content/TopBar
@onready var _profile_pill: Control = $Margin/Content/Header/ProfilePill
@onready var _logo_rect: TextureRect = $Margin/Content/Header/LogoRect
@onready var _solah_card: Control = $Margin/Content/Carousel/SolahCard
@onready var _aadu_card: Control = $Margin/Content/Carousel/AaduCard
@onready var _morris_card: Control = $Margin/Content/Carousel/MorrisCard
@onready var _dot0: Control = $Margin/Content/Dots/Dot0
@onready var _dot1: Control = $Margin/Content/Dots/Dot1
@onready var _dot2: Control = $Margin/Content/Dots/Dot2
@onready var _play_button: Button = $Margin/Content/PlayWrap/PlayButton
@onready var _daily_banner: Button = $Margin/Content/RewardsRow/DailyBanner
@onready var _royal_banner: Button = $Margin/Content/RewardsRow/RoyalBanner
@onready var _profile_button: Button = $Margin/Content/FeaturesRow/ProfileButton
@onready var _shop_button: Button = $Margin/Content/FeaturesRow/ShopButton
@onready var _settings_button: Button = $Margin/Content/FeaturesRow/SettingsButton
@onready var _friends_button: Button = $Margin/Content/FeaturesRow/FriendsButton
@onready var _inventory_button: Button = $Margin/Content/FeaturesRow/InventoryButton
@onready var _history_button: Button = $Margin/Content/FeaturesRow/HistoryButton
@onready var _rankings_button: Button = $Margin/Content/FeaturesRow/RankingsButton
@onready var _admin_button: Button = $Margin/Content/FeaturesRow/AdminButton
@onready var _home_nav: Button = $Margin/Content/BottomNav/NavRow/HomeNav
@onready var _friends_nav: Button = $Margin/Content/BottomNav/NavRow/FriendsNav
@onready var _leaderboard_nav: Button = $Margin/Content/BottomNav/NavRow/LeaderboardNav
@onready var _profile_nav: Button = $Margin/Content/BottomNav/NavRow/ProfileNav
@onready var _store_nav: Button = $Margin/Content/BottomNav/NavRow/StoreNav
@onready var _version_label: Label = $VersionLabel

var _cards: Dictionary = {}  # StringName -> game_card.gd
var _dots: Array[Control] = []
var _daily_claimable := false
var _play_tween: Tween = null
var _sparkles: CPUParticles2D = null
var _fade_tween: Tween = null


func _ready() -> void:
	_version_label.text = "v%s" % App.APP_VERSION
	_ensure_logo()
	_cards = {
		&"solah_seedi": _solah_card,
		&"aadu_puli": _aadu_card,
		&"nine_mens_morris": _morris_card,
	}
	_dots = [_dot0, _dot1, _dot2]
	_style_pill()
	_style_dots()
	_wire_cards()
	_wire_buttons()
	_wire_nav()
	_wire_banners()
	_select_game(App.selected_game)
	_refresh_staff_visibility()
	_refresh_daily_status()
	_spawn_sparkles()
	_start_play_pulse()
	_start_fade_in()
	resized.connect(_on_resized)
	_on_resized()
	App.auth.session_changed.connect(_on_session_changed)
	App.selected_game_changed.connect(_on_selected_game_changed)


func _exit_tree() -> void:
	if App.auth.session_changed.is_connected(_on_session_changed):
		App.auth.session_changed.disconnect(_on_session_changed)
	if App.selected_game_changed.is_connected(_on_selected_game_changed):
		App.selected_game_changed.disconnect(_on_selected_game_changed)


# --- Wiring -------------------------------------------------------------

func _wire_cards() -> void:
	for id in _cards:
		var card: Control = _cards[id]
		card.chosen.connect(_on_card_chosen)


func _on_card_chosen(game_id: StringName) -> void:
	App.select_game(game_id)


func _on_selected_game_changed(game_id: StringName) -> void:
	_select_game(game_id)


func _wire_buttons() -> void:
	_play_button.pressed.connect(_on_play)
	_profile_pill.gui_input.connect(_on_profile_pill_input)
	_profile_button.pressed.connect(func() -> void:
		_log("Profile"); App.navigation.go(&"profile"))
	_shop_button.pressed.connect(func() -> void:
		_log("Shop"); App.navigation.go(&"shop"))
	_settings_button.pressed.connect(func() -> void:
		_log("Settings"); App.navigation.go(&"settings"))
	_friends_button.pressed.connect(func() -> void:
		_log("Friends"); App.navigation.go(&"friends"))
	_inventory_button.pressed.connect(func() -> void:
		_log("Inventory"); App.navigation.go(&"inventory"))
	_history_button.pressed.connect(func() -> void:
		_log("History"); App.navigation.go(&"history"))
	_rankings_button.pressed.connect(func() -> void:
		_log("Rankings"); App.navigation.go(&"leaderboard"))
	_admin_button.pressed.connect(func() -> void:
		_log("Admin"); App.navigation.go(&"admin"))


func _wire_nav() -> void:
	_home_nav.pressed.connect(func() -> void:
		_log("Nav Home"); App.navigation.go(&"main_menu"))
	_friends_nav.pressed.connect(func() -> void:
		_log("Nav Friends"); App.navigation.go(&"friends"))
	_leaderboard_nav.pressed.connect(func() -> void:
		_log("Nav Leaderboard"); App.navigation.go(&"leaderboard"))
	_profile_nav.pressed.connect(func() -> void:
		_log("Nav Profile"); App.navigation.go(&"profile"))
	_store_nav.pressed.connect(func() -> void:
		_log("Nav Store"); App.navigation.go(&"shop"))


func _wire_banners() -> void:
	_daily_banner.banner_pressed.connect(_on_daily_pressed)
	_royal_banner.banner_pressed.connect(func() -> void:
		_log("Royal Pass"); App.navigation.go(&"shop"))


func _on_profile_pill_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_log("Profile pill")
		App.navigation.go(&"profile")


# --- Game selection + PLAY ---------------------------------------------

func _select_game(game_id: StringName) -> void:
	var ids: Array = [&"solah_seedi", &"aadu_puli", &"nine_mens_morris"]
	for i in range(ids.size()):
		var id: StringName = ids[i]
		var card = _cards.get(id)
		if card == null:
			continue
		if id == game_id:
			card.pick()
		else:
			card.choose()
		if i < _dots.size():
			_style_dot(_dots[i], id == game_id)


func _on_play() -> void:
	_log("PLAY -> %s" % App.selected_game)
	App.analytics.track("play_pressed", {}, String(App.selected_game))
	# Multiplayer-first entry: tier cards + Play with Friend / Play Online.
	App.navigation.go(&"game_entry", {"game_id": String(App.selected_game)})


# --- Daily rewards (real backend, never simulated) ----------------------

func _refresh_daily_status() -> void:
	if not App.auth.is_authenticated():
		_daily_claimable = false
		_daily_banner.set_subtitle("Sign in to claim daily rewards")
		return
	var res: Dictionary = await App.rewards.daily_status()
	if not res.ok:
		_daily_claimable = false
		_daily_banner.set_subtitle("Offline — try again later")
		return
	var body: Dictionary = res.body
	if bool(body.get("todayClaimed", false)):
		_daily_claimable = false
		_daily_banner.set_subtitle("Claimed! Come back tomorrow")
	else:
		_daily_claimable = true
		_daily_banner.set_subtitle("+%d coins · Day %d" % [
				int(body.get("nextRewardCoins", 0)), int(body.get("nextStreakDay", 1))])


func _on_daily_pressed() -> void:
	_log("Daily Rewards")
	if not App.auth.is_authenticated():
		App.navigation.go(&"auth")
		return
	if not _daily_claimable:
		return
	_daily_banner.disabled = true
	_daily_banner.set_subtitle("Claiming…")
	var res: Dictionary = await App.rewards.claim_daily()
	if res.ok:
		# Server granted the coins — re-read the authoritative balance.
		App.refresh_wallet()
		_daily_claimable = false
		_daily_banner.set_subtitle("Claimed! Come back tomorrow")
	else:
		_daily_claimable = false
		_daily_banner.set_subtitle(str(res.get("error", "Could not claim — try later")))
	_daily_banner.disabled = false


func _on_session_changed(_user: Dictionary = {}) -> void:
	_refresh_daily_status()
	_refresh_staff_visibility()


# --- Presentation -------------------------------------------------------

## The logo ships in res://UI/logo.png; assign it defensively so a
## missing ext-resource reference can never leave a blank header.
func _ensure_logo() -> void:
	if _logo_rect == null:
		return
	if _logo_rect.texture == null:
		var tex: Texture2D = load("res://UI/logo.png")
		if tex != null:
			_logo_rect.texture = tex


func _style_pill() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.2, 0.26, 0.8)
	sb.set_corner_radius_all(99)
	sb.set_border_width_all(2)
	sb.border_color = Color(AppTheme.C_GOLD_BRIGHT.r, AppTheme.C_GOLD_BRIGHT.g,
			AppTheme.C_GOLD_BRIGHT.b, 0.55)
	sb.content_margin_left = 10
	sb.content_margin_right = 14
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	_profile_pill.add_theme_stylebox_override("panel", sb)


func _style_dots() -> void:
	for i in range(_dots.size()):
		_style_dot(_dots[i], false)


func _style_dot(dot: Control, active: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = AppTheme.C_GOLD_BRIGHT if active else Color(1, 1, 1, 0.28)
	sb.set_corner_radius_all(99)
	if active:
		sb.set_border_width_all(1)
		sb.border_color = Color(1, 1, 1, 0.6)
	dot.add_theme_stylebox_override("panel", sb)


func _spawn_sparkles() -> void:
	_sparkles = CPUParticles2D.new()
	_sparkles.name = "PlaySparkles"
	_sparkles.amount = 16
	_sparkles.lifetime = 1.5
	_sparkles.preprocess = 1.5
	_sparkles.emitting = true
	_sparkles.gravity = Vector2(0, -22)
	_sparkles.initial_velocity_min = 14.0
	_sparkles.initial_velocity_max = 40.0
	_sparkles.scale_amount_min = 1.5
	_sparkles.scale_amount_max = 3.4
	_sparkles.color = Color(AppTheme.C_GOLD_BRIGHT.r, AppTheme.C_GOLD_BRIGHT.g,
			AppTheme.C_GOLD_BRIGHT.b, 0.85)
	_sparkles.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	_sparkles.emission_rect_extents = Vector2(130, 6)
	add_child(_sparkles)
	_position_sparkles()


func _position_sparkles() -> void:
	if _sparkles == null or not is_instance_valid(_play_button):
		return
	var rect := _play_button.get_global_rect()
	_sparkles.global_position = Vector2(rect.get_center().x, rect.position.y + 4.0)
	var half_w := maxf(40.0, rect.size.x * 0.5 - 10.0)
	_sparkles.emission_rect_extents = Vector2(half_w, 5.0)


func _start_play_pulse() -> void:
	if _play_tween != null and _play_tween.is_valid():
		_play_tween.kill()
	_play_button.pivot_offset = _play_button.size / 2.0
	_play_tween = create_tween().set_loops()
	_play_tween.tween_property(_play_button, "scale", Vector2(1.045, 1.045), 0.55) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_play_tween.tween_property(_play_button, "scale", Vector2.ONE, 0.55) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_play_tween.tween_interval(0.35)


func _start_fade_in() -> void:
	modulate.a = 0.0
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = create_tween()
	_fade_tween.tween_property(self, "modulate:a", 1.0, 0.28)


func _on_resized() -> void:
	_position_sparkles()
	if _play_button != null:
		_play_button.pivot_offset = _play_button.size / 2.0
	for id in _cards:
		var card = _cards.get(id)
		if card != null and is_instance_valid(card):
			card.pivot_offset = card.size / 2.0


# --- Staff + misc -------------------------------------------------------

func _refresh_staff_visibility(_user: Dictionary = {}) -> void:
	_admin_button.visible = App.auth.is_staff()


func _log(label: String) -> void:
	if OS.is_debug_build():
		print("UI: main menu '%s' pressed" % label)

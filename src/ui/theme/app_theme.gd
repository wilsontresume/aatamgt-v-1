class_name AppTheme
extends RefCounted
## Single source of truth for AATAMGT's visual language.
## Colorful casual-arcade palette: sky blue, turquoise, leafy green,
## sunrise orange and rich gold over dark-teal contrast panels.
## Built in code (no .tres) so palette values stay greppable and testable.

# --- Core surfaces (dark teal contrast, never plain black) ---------------
const C_BG := Color("0e3a4a")           # deep teal base under illustrated bg
const C_SURFACE := Color("0d3040")      # dark teal panel
const C_CARD := Color("10485c")         # teal card
const C_CARD_HOVER := Color("17607a")   # lighter teal on hover
const C_BORDER := Color("c9982f")       # muted gold ornamental border
const C_ACCENT := Color("ffb300")       # rich gold primary action
const C_ACCENT_HOVER := Color("ffc93c") # bright gold
const C_ACCENT_PRESSED := Color("e09600")
const C_ON_ACCENT := Color("2a1a04")    # dark brown on gold
const C_TEXT := Color("fff8e7")         # cream
const C_TEXT_SECONDARY := Color("b8dce8")
const C_TEXT_DISABLED := Color("6d95a3")
const C_DANGER := Color("e5484d")
const C_DANGER_PRESSED := Color("c62f34")
const C_SUCCESS := Color("4caf50")

# --- Bright palette (shared accents) -------------------------------------
const C_SKY_BLUE := Color("29b6f6")
const C_TURQUOISE := Color("26c6da")
const C_LEAF_GREEN := Color("66bb6a")
const C_SUNRISE := Color("ff8a65")
const C_ORANGE := Color("ffa726")
const C_YELLOW := Color("ffd54f")
const C_PURPLE := Color("ab47bc")

# --- Arcade lobby palette (kept for existing menu components) ------------
const C_ARCADE_RED := Color("e8503a")
const C_ARCADE_BLUE := Color("2f80ed")
const C_ARCADE_GREEN := Color("27ae60")
const C_ARCADE_YELLOW := Color("f2c94c")
const C_ARCADE_PURPLE := Color("9b51e0")
const C_ARCADE_ORANGE := Color("f2994a")
const C_ARCADE_TEAL := Color("17a2a2")
const C_GOLD_BRIGHT := Color("ffd76a")
const C_GOLD_DEEP := Color("e8a020")
const C_PLAY_SHADOW := Color("8a5a10")

# --- Tier identity colors ------------------------------------------------
const C_BRONZE := Color("cd7f32")
const C_BRONZE_DEEP := Color("8b5a2b")
const C_SILVER := Color("b0bec5")
const C_SILVER_DEEP := Color("5c7a99")
const C_GOLD_TIER := Color("ffd76a")
const C_GOLD_TIER_DEEP := Color("7b1fa2")   # purple card, per reference

# --- Wood / ornament -----------------------------------------------------
const C_WOOD := Color("6b3f1d")
const C_WOOD_LIGHT := Color("a0672f")
const C_PANEL_DARK_TEAL := Color("0a2e3a")

# --- Game-board surface (sandstone temple slab) ---------------------------
const C_BOARD_SAND := Color("c89f70")
const C_BOARD_SAND_DARK := Color("a67c48")
const C_BOARD_LINE := Color("4a2e12")
const C_MOVE_GLOW := Color("6ee76e")
const C_PLAYER_BLUE := Color("1565c0")
const C_PLAYER_BLUE_DEEP := Color("0d47a1")
const C_PLAYER_RED := Color("b71c1c")
const C_PLAYER_RED_DEEP := Color("7f0000")
const C_TURN_RING := Color("4caf50")

# --- Geometry ------------------------------------------------------------
const R_CARD := 18.0
const R_DIALOG := 20.0
const R_BUTTON := 14.0
const R_PILL := 99.0


static func build() -> Theme:
	var t := Theme.new()
	t.default_font_size = 17

	# Shared palette, readable from any control:
	# get_theme_color("accent", "App")
	t.set_color("bg", "App", C_BG)
	t.set_color("surface", "App", C_SURFACE)
	t.set_color("card", "App", C_CARD)
	t.set_color("border", "App", C_BORDER)
	t.set_color("accent", "App", C_ACCENT)
	t.set_color("text", "App", C_TEXT)
	t.set_color("text_secondary", "App", C_TEXT_SECONDARY)
	t.set_color("danger", "App", C_DANGER)
	t.set_color("success", "App", C_SUCCESS)
	t.set_color("sky_blue", "App", C_SKY_BLUE)
	t.set_color("turquoise", "App", C_TURQUOISE)
	t.set_color("leaf_green", "App", C_LEAF_GREEN)
	t.set_color("sunrise", "App", C_SUNRISE)
	t.set_color("orange", "App", C_ORANGE)
	t.set_color("yellow", "App", C_YELLOW)
	t.set_color("purple", "App", C_PURPLE)
	t.set_color("bronze", "App", C_BRONZE)
	t.set_color("silver", "App", C_SILVER)
	t.set_color("gold_tier", "App", C_GOLD_TIER)
	t.set_color("wood", "App", C_WOOD)
	t.set_color("arcade_red", "App", C_ARCADE_RED)
	t.set_color("arcade_blue", "App", C_ARCADE_BLUE)
	t.set_color("arcade_green", "App", C_ARCADE_GREEN)
	t.set_color("arcade_yellow", "App", C_ARCADE_YELLOW)
	t.set_color("arcade_purple", "App", C_ARCADE_PURPLE)
	t.set_color("arcade_orange", "App", C_ARCADE_ORANGE)
	t.set_color("arcade_teal", "App", C_ARCADE_TEAL)
	t.set_color("gold_bright", "App", C_GOLD_BRIGHT)
	t.set_color("gold_deep", "App", C_GOLD_DEEP)

	# --- Container spacing
	t.set_constant("separation", "VBoxContainer", 14)
	t.set_constant("separation", "HBoxContainer", 12)

	# --- Labels ---------------------------------------------------------
	t.set_color("font_color", "Label", C_TEXT)
	# Cream labels pick up a soft dark shadow so they stay readable over
	# bright illustrated backgrounds.
	t.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0.45))
	t.set_constant("shadow_offset_x", "Label", 0)
	t.set_constant("shadow_offset_y", "Label", 2)

	_add_label_variation(t, "TitleLarge", 34, C_GOLD_BRIGHT)
	_add_label_variation(t, "ScreenTitle", 22, C_GOLD_BRIGHT)
	_add_label_variation(t, "Heading", 19, C_TEXT)
	_add_label_variation(t, "Body", 17, C_TEXT)
	_add_label_variation(t, "Caption", 14, C_TEXT_SECONDARY)
	_add_label_variation(t, "ValueBig", 26, C_GOLD_BRIGHT)

	# --- Buttons --------------------------------------------------------
	# Base Button reads as the teal secondary style with gold hairline.
	_style_button(t, "Button", Color(C_CARD.r, C_CARD.g, C_CARD.b, 0.92),
			C_CARD_HOVER, _pressed(C_CARD), C_TEXT, Color(C_BORDER.r,
			C_BORDER.g, C_BORDER.b, 0.65))
	_style_button(t, "PrimaryButton", C_ACCENT, C_ACCENT_HOVER, C_ACCENT_PRESSED,
			C_ON_ACCENT, Color.TRANSPARENT)
	_style_button(t, "SecondaryButton", Color(C_SURFACE.r, C_SURFACE.g,
			C_SURFACE.b, 0.92), C_CARD, _pressed(C_SURFACE), C_TEXT,
			Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.55))
	_style_button(t, "GhostButton", Color(0, 0, 0, 0.28), Color(1, 1, 1, 0.14),
			Color(1, 1, 1, 0.2), C_TEXT, Color(1, 1, 1, 0.35))
	_style_button(t, "DangerButton", C_DANGER, _pressed(C_DANGER), C_DANGER_PRESSED,
			Color.WHITE, Color.TRANSPARENT)

	# --- Cards / panels -------------------------------------------------
	# Teal translucent card with ornamental gold border — the workhorse
	# panel across every screen.
	t.set_type_variation("Card", "PanelContainer")
	t.set_stylebox("panel", "Card", _box(Color(C_CARD.r, C_CARD.g, C_CARD.b, 0.88),
			Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.75), R_CARD, 20, 18, 1.5))

	# --- Text inputs ----------------------------------------------------
	t.set_stylebox("normal", "LineEdit", _box(Color(C_SURFACE.r, C_SURFACE.g,
			C_SURFACE.b, 0.95), Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.6),
			R_BUTTON, 24, 15))
	t.set_stylebox("focus", "LineEdit", _box(Color(C_SURFACE.r, C_SURFACE.g,
			C_SURFACE.b, 0.95), C_ACCENT, R_BUTTON, 24, 15))
	t.set_stylebox("read_only", "LineEdit", _box(Color(C_CARD.r, C_CARD.g,
			C_CARD.b, 0.9), Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.4),
			R_BUTTON, 24, 15))
	t.set_color("font_color", "LineEdit", C_TEXT)
	t.set_color("font_placeholder_color", "LineEdit", C_TEXT_SECONDARY)
	t.set_color("font_uneditable_color", "LineEdit", C_TEXT_SECONDARY)
	t.set_font_size("font_size", "LineEdit", 17)

	t.set_type_variation("Dialog", "PanelContainer")
	var dialog_box := _box(Color(C_PANEL_DARK_TEAL.r, C_PANEL_DARK_TEAL.g,
			C_PANEL_DARK_TEAL.b, 0.97), C_GOLD_BRIGHT, R_DIALOG, 28, 24, 2.0)
	dialog_box.shadow_color = Color(0, 0, 0, 0.4)
	dialog_box.shadow_size = 16
	dialog_box.shadow_offset = Vector2(0, 6)
	t.set_stylebox("panel", "Dialog", dialog_box)

	t.set_type_variation("Badge", "PanelContainer")
	var badge := _box(Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.2),
			Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.5), R_PILL, 12, 5)
	t.set_stylebox("panel", "Badge", badge)

	# --- Ornament panel (dark teal + gold frame, for section headers) ----
	t.set_type_variation("OrnamentPanel", "PanelContainer")
	var orn := _box(Color(C_PANEL_DARK_TEAL.r, C_PANEL_DARK_TEAL.g,
			C_PANEL_DARK_TEAL.b, 0.9), Color(C_GOLD_BRIGHT.r, C_GOLD_BRIGHT.g,
			C_GOLD_BRIGHT.b, 0.85), 14.0, 18.0, 12.0, 2.0)
	t.set_stylebox("panel", "OrnamentPanel", orn)

	# --- Wood banner plaque (game titles, section banners) ---------------
	t.set_type_variation("WoodBanner", "PanelContainer")
	var wood := _box(Color("5c3418"), Color(C_GOLD_BRIGHT.r, C_GOLD_BRIGHT.g,
			C_GOLD_BRIGHT.b, 0.9), 16.0, 22.0, 12.0, 2.5)
	wood.shadow_color = Color(0, 0, 0, 0.45)
	wood.shadow_size = 8
	wood.shadow_offset = Vector2(0, 4)
	t.set_stylebox("panel", "WoodBanner", wood)

	# --- Tier cards (Bronze / Silver / Gold) -----------------------------
	_add_tier_card(t, "TierBronze", Color("7a4520"), Color("a86832"), C_BRONZE)
	_add_tier_card(t, "TierSilver", Color("3d5568"), Color("5c7a99"), C_SILVER)
	_add_tier_card(t, "TierGold", Color("5a1f7a"), Color("7b2d9e"), C_GOLD_TIER)
	# Button variants for dynamic tier cards (game_entry builds Buttons).
	_add_tier_button(t, "TierBronzeBtn", Color("7a4520"), Color("a86832"),
			Color("c9854a"), Color("8b5a2b"))
	_add_tier_button(t, "TierSilverBtn", Color("3d5568"), Color("5c7a99"),
			Color("90a4ae"), Color("546e7a"))
	_add_tier_button(t, "TierGoldBtn", Color("5a1f7a"), Color("7b2d9e"),
			C_GOLD_TIER, Color("6a1b9a"))
	# Generic fallback (unknown tier ids from the backend).
	_add_tier_button(t, "TierGenericBtn", Color("0d4c5c"), Color("136078"),
			C_TURQUOISE, Color("0a3d4a"))

	# --- Play action cards (green friend / blue online) ------------------
	t.set_type_variation("ActionGreen", "PanelContainer")
	var green := _box(Color("1b5e20"), Color(C_LEAF_GREEN.r, C_LEAF_GREEN.g,
			C_LEAF_GREEN.b, 0.95), 18.0, 20.0, 18.0, 2.5)
	green.shadow_color = Color(0, 0, 0, 0.4)
	green.shadow_size = 10
	green.shadow_offset = Vector2(0, 5)
	t.set_stylebox("panel", "ActionGreen", green)

	t.set_type_variation("ActionBlue", "PanelContainer")
	var blue := _box(Color("0d47a1"), Color(C_SKY_BLUE.r, C_SKY_BLUE.g,
			C_SKY_BLUE.b, 0.95), 18.0, 20.0, 18.0, 2.5)
	blue.shadow_color = Color(0, 0, 0, 0.4)
	blue.shadow_size = 10
	blue.shadow_offset = Vector2(0, 5)
	t.set_stylebox("panel", "ActionBlue", blue)

	# Button variants for the two Play action cards.
	_add_action_button(t, "ActionGreenBtn", Color("1b5e20"), Color("2e7d32"),
			Color("145218"), Color(C_LEAF_GREEN.r, C_LEAF_GREEN.g, C_LEAF_GREEN.b, 0.95))
	_add_action_button(t, "ActionBlueBtn", Color("0d47a1"), Color("1565c0"),
			Color("0a3a82"), Color(C_SKY_BLUE.r, C_SKY_BLUE.g, C_SKY_BLUE.b, 0.95))

	# --- Arcade lobby (main menu redesign) ------------------------------
	# Big gold PLAY button: bright gold with deep-gold outline and a soft
	# drop shadow for pop over the illustrated temple scene.
	t.set_type_variation("PlayButton", "Button")
	var play_normal := _box(C_GOLD_BRIGHT, C_GOLD_DEEP, 22, 36, 18, 2.0)
	play_normal.shadow_color = Color(C_PLAY_SHADOW.r, C_PLAY_SHADOW.g,
			C_PLAY_SHADOW.b, 0.55)
	play_normal.shadow_size = 8
	play_normal.shadow_offset = Vector2(0, 5)
	var play_hover := _box(Color(1.0, 0.9, 0.55), C_GOLD_DEEP, 22, 36, 18, 2.0)
	play_hover.shadow_color = play_normal.shadow_color
	play_hover.shadow_size = 10
	play_hover.shadow_offset = Vector2(0, 6)
	var play_pressed := _box(C_GOLD_DEEP, Color("b8801a"), 22, 36, 18, 2.0)
	play_pressed.shadow_size = 3
	play_pressed.shadow_offset = Vector2(0, 2)
	t.set_stylebox("normal", "PlayButton", play_normal)
	t.set_stylebox("hover", "PlayButton", play_hover)
	t.set_stylebox("pressed", "PlayButton", play_pressed)
	t.set_stylebox("disabled", "PlayButton", _box(Color(0.55, 0.5, 0.4),
			Color(0.4, 0.36, 0.28), 22, 36, 18))
	t.set_stylebox("focus", "PlayButton", StyleBoxEmpty.new())
	t.set_color("font_color", "PlayButton", C_ON_ACCENT)
	t.set_color("font_hover_color", "PlayButton", C_ON_ACCENT)
	t.set_color("font_pressed_color", "PlayButton", Color("5a3d08"))
	t.set_color("font_disabled_color", "PlayButton", Color(0.35, 0.32, 0.26))
	t.set_font_size("font_size", "PlayButton", 30)

	# Translucent deep-teal glass panel used behind menu banners and the
	# bottom nav bar.
	t.set_type_variation("MenuPanel", "PanelContainer")
	t.set_stylebox("panel", "MenuPanel", _box(Color(0.03, 0.18, 0.24, 0.82),
			Color(1, 0.85, 0.4, 0.35), R_CARD, 14, 10, 1.0))

	# Bottom-nav text caption.
	_add_label_variation(t, "NavLabel", 11, C_TEXT_SECONDARY)
	_add_label_variation(t, "NavLabelActive", 11, C_GOLD_BRIGHT)

	# --- Login screen (login redesign) ---------------------------------
	# Deep-teal temple panel with a gold ornate border, matching the
	# arcade menu's gold accents over a colourful daytime temple scene.
	t.set_type_variation("LoginPanel", "PanelContainer")
	var login_panel := _box(Color("0d3039"), C_GOLD_BRIGHT, 26.0, 22.0, 18.0, 2.0)
	login_panel.shadow_color = Color(1.0, 0.78, 0.3, 0.35)
	login_panel.shadow_size = 18
	login_panel.shadow_offset = Vector2(0, 6)
	t.set_stylebox("panel", "LoginPanel", login_panel)

	t.set_type_variation("AuthField", "PanelContainer")
	t.set_stylebox("panel", "AuthField",
			_box(Color("0a2630"), Color(1.0, 0.84, 0.42, 0.4), 14.0, 14.0, 12.0, 1.0))

	# Social sign-in pills: Google (white) + Facebook (blue); icons are
	# procedural child Controls, so content margins leave room for them.
	t.set_type_variation("GoogleButton", "Button")
	var google_normal := _box(Color.WHITE, Color(0, 0, 0, 0.10), 28.0, 56.0, 14.0)
	google_normal.content_margin_right = 46.0
	var google_hover := _box(Color(0.96, 0.96, 0.96), Color(0, 0, 0, 0.14), 28.0, 56.0, 14.0)
	google_hover.content_margin_right = 46.0
	var google_pressed := _box(Color(0.9, 0.9, 0.9), Color(0, 0, 0, 0.18), 28.0, 56.0, 14.0)
	google_pressed.content_margin_right = 46.0
	var google_disabled := _box(Color(0.93, 0.93, 0.93), Color(0, 0, 0, 0.08), 28.0, 56.0, 14.0)
	google_disabled.content_margin_right = 46.0
	t.set_stylebox("normal", "GoogleButton", google_normal)
	t.set_stylebox("hover", "GoogleButton", google_hover)
	t.set_stylebox("pressed", "GoogleButton", google_pressed)
	t.set_stylebox("disabled", "GoogleButton", google_disabled)
	t.set_stylebox("focus", "GoogleButton", StyleBoxEmpty.new())
	t.set_color("font_color", "GoogleButton", Color("1f1f1f"))
	t.set_color("font_hover_color", "GoogleButton", Color("1f1f1f"))
	t.set_color("font_pressed_color", "GoogleButton", Color("1f1f1f"))
	t.set_color("font_disabled_color", "GoogleButton", Color(0.5, 0.5, 0.5))
	t.set_font_size("font_size", "GoogleButton", 17)

	t.set_type_variation("FacebookButton", "Button")
	var fb_normal := _box(Color("1877f2"), Color(1, 1, 1, 0.18), 28.0, 56.0, 14.0)
	fb_normal.content_margin_right = 46.0
	var fb_hover := _box(Color("1f8cff"), Color(1, 1, 1, 0.22), 28.0, 56.0, 14.0)
	fb_hover.content_margin_right = 46.0
	var fb_pressed := _box(Color("1565d8"), Color(1, 1, 1, 0.25), 28.0, 56.0, 14.0)
	fb_pressed.content_margin_right = 46.0
	var fb_disabled := _box(Color(0.35, 0.5, 0.72), Color(1, 1, 1, 0.12), 28.0, 56.0, 14.0)
	fb_disabled.content_margin_right = 46.0
	t.set_stylebox("normal", "FacebookButton", fb_normal)
	t.set_stylebox("hover", "FacebookButton", fb_hover)
	t.set_stylebox("pressed", "FacebookButton", fb_pressed)
	t.set_stylebox("disabled", "FacebookButton", fb_disabled)
	t.set_stylebox("focus", "FacebookButton", StyleBoxEmpty.new())
	t.set_color("font_color", "FacebookButton", Color.WHITE)
	t.set_color("font_hover_color", "FacebookButton", Color.WHITE)
	t.set_color("font_pressed_color", "FacebookButton", Color.WHITE)
	t.set_color("font_disabled_color", "FacebookButton", Color(0.85, 0.85, 0.85))
	t.set_font_size("font_size", "FacebookButton", 17)

	# Gold Sign In / Create Account CTA.
	t.set_type_variation("GoldSignIn", "Button")
	var gold_normal := _box(Color("ffc42e"), Color("b8770a"), 16.0, 24.0, 15.0, 2.0)
	gold_normal.shadow_color = Color(0.48, 0.3, 0.0, 0.55)
	gold_normal.shadow_size = 8
	gold_normal.shadow_offset = Vector2(0, 5)
	var gold_hover := _box(Color("ffd257"), Color("b8770a"), 16.0, 24.0, 15.0, 2.0)
	gold_hover.shadow_color = gold_normal.shadow_color
	gold_hover.shadow_size = 10
	gold_hover.shadow_offset = Vector2(0, 6)
	var gold_pressed := _box(Color("e8a71c"), Color("9a6510"), 16.0, 24.0, 15.0, 2.0)
	gold_pressed.shadow_size = 3
	gold_pressed.shadow_offset = Vector2(0, 2)
	t.set_stylebox("normal", "GoldSignIn", gold_normal)
	t.set_stylebox("hover", "GoldSignIn", gold_hover)
	t.set_stylebox("pressed", "GoldSignIn", gold_pressed)
	t.set_stylebox("disabled", "GoldSignIn",
			_box(Color(0.55, 0.5, 0.35), Color(0.4, 0.36, 0.25), 16.0, 24.0, 15.0, 2.0))
	t.set_stylebox("focus", "GoldSignIn", StyleBoxEmpty.new())
	t.set_color("font_color", "GoldSignIn", Color("3a2504"))
	t.set_color("font_hover_color", "GoldSignIn", Color("3a2504"))
	t.set_color("font_pressed_color", "GoldSignIn", Color("5a3d08"))
	t.set_color("font_disabled_color", "GoldSignIn", Color(0.35, 0.32, 0.26))
	t.set_font_size("font_size", "GoldSignIn", 20)

	# Gold-outlined guest pill.
	t.set_type_variation("GuestOutline", "Button")
	var guest_normal := _box(Color(1, 1, 1, 0.05), C_GOLD_BRIGHT, 28.0, 56.0, 14.0, 2.0)
	guest_normal.content_margin_right = 46.0
	var guest_hover := _box(Color(1, 0.85, 0.4, 0.12), C_GOLD_BRIGHT, 28.0, 56.0, 14.0, 2.0)
	guest_hover.content_margin_right = 46.0
	var guest_pressed := _box(Color(1, 0.85, 0.4, 0.2), C_GOLD_DEEP, 28.0, 56.0, 14.0, 2.0)
	guest_pressed.content_margin_right = 46.0
	t.set_stylebox("normal", "GuestOutline", guest_normal)
	t.set_stylebox("hover", "GuestOutline", guest_hover)
	t.set_stylebox("pressed", "GuestOutline", guest_pressed)
	t.set_stylebox("disabled", "GuestOutline",
			_box(Color(1, 1, 1, 0.03), Color(1, 1, 1, 0.15), 28.0, 56.0, 14.0, 2.0))
	t.set_stylebox("focus", "GuestOutline", StyleBoxEmpty.new())
	t.set_color("font_color", "GuestOutline", Color.WHITE)
	t.set_color("font_hover_color", "GuestOutline", Color.WHITE)
	t.set_color("font_pressed_color", "GuestOutline", Color.WHITE)
	t.set_color("font_disabled_color", "GuestOutline", Color(0.55, 0.55, 0.55))
	t.set_font_size("font_size", "GuestOutline", 17)

	# Gold text link (switch between sign-in / register).
	t.set_type_variation("LinkGold", "Button")
	t.set_stylebox("normal", "LinkGold", StyleBoxEmpty.new())
	t.set_stylebox("hover", "LinkGold", _box(Color(1, 1, 1, 0.06), Color.TRANSPARENT, 8.0, 8.0, 8.0))
	t.set_stylebox("pressed", "LinkGold", _box(Color(1, 1, 1, 0.1), Color.TRANSPARENT, 8.0, 8.0, 8.0))
	t.set_stylebox("disabled", "LinkGold", StyleBoxEmpty.new())
	t.set_stylebox("focus", "LinkGold", StyleBoxEmpty.new())
	t.set_color("font_color", "LinkGold", C_GOLD_BRIGHT)
	t.set_color("font_hover_color", "LinkGold", Color(1.0, 0.92, 0.7))
	t.set_color("font_pressed_color", "LinkGold", C_GOLD_DEEP)
	t.set_color("font_disabled_color", "LinkGold", Color(0.55, 0.5, 0.4))
	t.set_font_size("font_size", "LinkGold", 16)

	# Wood-styled Back pill (matches reference top-left Back button).
	t.set_type_variation("WoodBack", "Button")
	var back_normal := _box(Color("5c3418"), Color(C_GOLD_BRIGHT.r,
			C_GOLD_BRIGHT.g, C_GOLD_BRIGHT.b, 0.85), 26.0, 22.0, 12.0, 1.5)
	back_normal.shadow_color = Color(0, 0, 0, 0.4)
	back_normal.shadow_size = 6
	back_normal.shadow_offset = Vector2(0, 3)
	var back_hover := _box(Color("7a4520"), C_GOLD_BRIGHT, 26.0, 22.0, 12.0, 1.5)
	var back_pressed := _box(Color("4a2810"), Color(C_GOLD_DEEP.r,
			C_GOLD_DEEP.g, C_GOLD_DEEP.b, 0.8), 26.0, 22.0, 12.0, 1.5)
	t.set_stylebox("normal", "WoodBack", back_normal)
	t.set_stylebox("hover", "WoodBack", back_hover)
	t.set_stylebox("pressed", "WoodBack", back_pressed)
	t.set_stylebox("disabled", "WoodBack", _box(Color("3d220e"),
			Color(1, 1, 1, 0.1), 26.0, 22.0, 12.0, 1.0))
	t.set_stylebox("focus", "WoodBack", StyleBoxEmpty.new())
	t.set_color("font_color", "WoodBack", C_GOLD_BRIGHT)
	t.set_color("font_hover_color", "WoodBack", Color.WHITE)
	t.set_color("font_pressed_color", "WoodBack", C_GOLD_DEEP)
	t.set_color("font_disabled_color", "WoodBack", Color(0.5, 0.42, 0.3))
	t.set_font_size("font_size", "WoodBack", 17)

	_add_label_variation(t, "WelcomeLabel", 17, Color("e8f2f6"))
	_add_label_variation(t, "BrandLabel", 38, C_GOLD_BRIGHT)
	_add_label_variation(t, "AuthTagline", 14, Color(0.82, 0.9, 0.95))
	_add_label_variation(t, "AuthDivider", 13, Color(1, 1, 1, 0.6))
	_add_label_variation(t, "TierName", 20, Color.WHITE)
	_add_label_variation(t, "TierCost", 18, Color.WHITE)
	_add_label_variation(t, "TierReward", 18, C_GOLD_BRIGHT)
	_add_label_variation(t, "SectionTitle", 18, C_GOLD_BRIGHT)

	# --- Match HUD panels (board redesign) --------------------------------
	t.set_type_variation("PlayerBlue", "PanelContainer")
	var pblue := _box(Color(C_PLAYER_BLUE.r, C_PLAYER_BLUE.g, C_PLAYER_BLUE.b, 0.92),
			C_SKY_BLUE, 16.0, 10.0, 10.0, 2.0)
	pblue.shadow_color = Color(0, 0, 0, 0.4)
	pblue.shadow_size = 6
	pblue.shadow_offset = Vector2(0, 3)
	t.set_stylebox("panel", "PlayerBlue", pblue)

	t.set_type_variation("PlayerRed", "PanelContainer")
	var pred := _box(Color(C_PLAYER_RED.r, C_PLAYER_RED.g, C_PLAYER_RED.b, 0.92),
			C_SUNRISE, 16.0, 10.0, 10.0, 2.0)
	pred.shadow_color = Color(0, 0, 0, 0.4)
	pred.shadow_size = 6
	pred.shadow_offset = Vector2(0, 3)
	t.set_stylebox("panel", "PlayerRed", pred)

	t.set_type_variation("TurnPanel", "PanelContainer")
	var turn := _box(Color(0.05, 0.22, 0.26, 0.88), C_TURN_RING, 16.0, 10.0, 10.0, 2.0)
	turn.shadow_color = Color(C_TURN_RING.r, C_TURN_RING.g, C_TURN_RING.b, 0.35)
	turn.shadow_size = 10
	t.set_stylebox("panel", "TurnPanel", turn)

	t.set_type_variation("HandPanel", "PanelContainer")
	t.set_stylebox("panel", "HandPanel",
			_box(Color(0.04, 0.20, 0.24, 0.85), Color(1, 0.85, 0.4, 0.35), 14.0, 10.0, 8.0, 1.0))

	t.set_type_variation("InstrPanel", "PanelContainer")
	var instr := _box(Color(C_TURN_RING.r, C_TURN_RING.g, C_TURN_RING.b, 0.30),
			C_TURN_RING, 99.0, 14.0, 8.0, 1.5)
	instr.shadow_color = Color(C_TURN_RING.r, C_TURN_RING.g, C_TURN_RING.b, 0.45)
	instr.shadow_size = 8
	t.set_stylebox("panel", "InstrPanel", instr)

	# Status/detail strips: Label styleboxes give the ornamental ribbon.
	t.set_type_variation("StatusStrip", "Label")
	var strip := _box(Color(0.05, 0.18, 0.14, 0.85), C_GOLD_BRIGHT, 99.0, 18.0, 10.0, 1.5)
	strip.shadow_color = Color(0, 0, 0, 0.35)
	strip.shadow_size = 4
	t.set_stylebox("normal", "StatusStrip", strip)
	t.set_color("font_color", "StatusStrip", C_GOLD_BRIGHT)
	t.set_font_size("font_size", "StatusStrip", 18)
	t.set_constant("shadow_offset_x", "StatusStrip", 0)
	t.set_constant("shadow_offset_y", "StatusStrip", 0)

	t.set_type_variation("DetailStrip", "Label")
	var dstrip := _box(Color(1, 1, 1, 0.06), Color(1, 0.85, 0.4, 0.3), 99.0, 16.0, 8.0, 1.0)
	t.set_stylebox("normal", "DetailStrip", dstrip)
	t.set_color("font_color", "DetailStrip", C_TEXT_SECONDARY)
	t.set_font_size("font_size", "DetailStrip", 14)
	t.set_constant("shadow_offset_x", "DetailStrip", 0)
	t.set_constant("shadow_offset_y", "DetailStrip", 0)

	_add_label_variation(t, "BoardSubtitle", 14, Color(0.9, 0.82, 0.62))
	_add_label_variation(t, "PieceDotLabel", 12, Color(1, 1, 1, 0.9))
	_add_label_variation(t, "SideName", 15, Color.WHITE)
	_add_label_variation(t, "YouTag", 12, C_TURN_RING)

	return t


static func _pressed(bg: Color) -> Color:
	return bg.darkened(0.18)


static func _add_label_variation(t: Theme, name: String, size: int, color: Color) -> void:
	t.set_type_variation(name, "Label")
	t.set_font_size("font_size", name, size)
	t.set_color("font_color", name, color)


static func _add_tier_card(t: Theme, name: String, bg: Color, bg_hover: Color,
		border: Color) -> void:
	t.set_type_variation(name, "PanelContainer")
	var normal := _box(Color(bg.r, bg.g, bg.b, 0.94), border, 20.0, 14.0, 16.0, 2.0)
	normal.shadow_color = Color(0, 0, 0, 0.45)
	normal.shadow_size = 8
	normal.shadow_offset = Vector2(0, 4)
	var hover := _box(Color(bg_hover.r, bg_hover.g, bg_hover.b, 0.96), border,
			20.0, 14.0, 16.0, 2.0)
	hover.shadow_color = normal.shadow_color
	hover.shadow_size = 10
	t.set_stylebox("panel", name, normal)
	t.set_stylebox("panel_hover", name, hover)


static func _add_tier_button(t: Theme, name: String, bg: Color, bg_hover: Color,
		border: Color, bg_pressed: Color) -> void:
	t.set_type_variation(name, "Button")
	var normal := _box(Color(bg.r, bg.g, bg.b, 0.96), border, 20.0, 12.0, 14.0, 2.0)
	normal.shadow_color = Color(0, 0, 0, 0.45)
	normal.shadow_size = 8
	normal.shadow_offset = Vector2(0, 4)
	var hover := _box(Color(bg_hover.r, bg_hover.g, bg_hover.b, 0.98), border,
			20.0, 12.0, 14.0, 2.0)
	hover.shadow_color = Color(border.r, border.g, border.b, 0.6)
	hover.shadow_size = 14
	hover.shadow_offset = Vector2(0, 4)
	var pressed := _box(Color(bg_pressed.r, bg_pressed.g, bg_pressed.b, 0.98),
			border, 20.0, 12.0, 14.0, 2.0)
	pressed.shadow_size = 3
	t.set_stylebox("normal", name, normal)
	t.set_stylebox("hover", name, hover)
	t.set_stylebox("pressed", name, pressed)
	# Selected (toggled) state: bright gold ring glow.
	var selected := _box(Color(bg_hover.r, bg_hover.g, bg_hover.b, 1.0),
			C_GOLD_BRIGHT, 20.0, 12.0, 14.0, 3.0)
	selected.shadow_color = Color(C_GOLD_BRIGHT.r, C_GOLD_BRIGHT.g,
			C_GOLD_BRIGHT.b, 0.7)
	selected.shadow_size = 18
	selected.shadow_offset = Vector2(0, 2)
	t.set_stylebox("pressed", name, selected)
	t.set_stylebox("disabled", name, _box(Color(bg.r, bg.g, bg.b, 0.5),
			Color(border.r, border.g, border.b, 0.35), 20.0, 12.0, 14.0, 1.0))
	t.set_stylebox("focus", name, StyleBoxEmpty.new())
	t.set_color("font_color", name, Color.WHITE)
	t.set_color("font_hover_color", name, Color.WHITE)
	t.set_color("font_pressed_color", name, Color.WHITE)
	t.set_color("font_disabled_color", name, Color(1, 1, 1, 0.5))
	t.set_font_size("font_size", name, 17)


static func _add_action_button(t: Theme, name: String, bg: Color, bg_hover: Color,
		bg_pressed: Color, border: Color) -> void:
	t.set_type_variation(name, "Button")
	var normal := _box(Color(bg.r, bg.g, bg.b, 0.96), border, 18.0, 18.0, 16.0, 2.5)
	normal.shadow_color = Color(0, 0, 0, 0.4)
	normal.shadow_size = 10
	normal.shadow_offset = Vector2(0, 5)
	var hover := _box(Color(bg_hover.r, bg_hover.g, bg_hover.b, 0.98), border,
			18.0, 18.0, 16.0, 2.5)
	hover.shadow_size = 12
	hover.shadow_offset = Vector2(0, 6)
	var pressed := _box(Color(bg_pressed.r, bg_pressed.g, bg_pressed.b, 0.98),
			border, 18.0, 18.0, 16.0, 2.5)
	pressed.shadow_size = 3
	pressed.shadow_offset = Vector2(0, 2)
	t.set_stylebox("normal", name, normal)
	t.set_stylebox("hover", name, hover)
	t.set_stylebox("pressed", name, pressed)
	t.set_stylebox("disabled", name, _box(Color(bg.r, bg.g, bg.b, 0.45),
			Color(border.r, border.g, border.b, 0.3), 18.0, 18.0, 16.0, 1.5))
	t.set_stylebox("focus", name, StyleBoxEmpty.new())
	t.set_color("font_color", name, Color.WHITE)
	t.set_color("font_hover_color", name, Color.WHITE)
	t.set_color("font_pressed_color", name, Color.WHITE)
	t.set_color("font_disabled_color", name, Color(1, 1, 1, 0.5))
	t.set_font_size("font_size", name, 19)


static func _style_button(t: Theme, type: String, normal: Color, hover: Color,
		pressed: Color, font: Color, border: Color) -> void:
	if type != "Button":
		t.set_type_variation(type, "Button")
	t.set_stylebox("normal", type, _box(normal, border, R_BUTTON, 24, 15))
	t.set_stylebox("hover", type, _box(hover, border, R_BUTTON, 24, 15))
	t.set_stylebox("pressed", type, _box(pressed, border, R_BUTTON, 24, 15))
	t.set_stylebox("disabled", type, _box(Color(1, 1, 1, 0.05),
			Color(1, 1, 1, 0.08), R_BUTTON, 24, 15))
	t.set_stylebox("focus", type, StyleBoxEmpty.new())
	t.set_color("font_color", type, font)
	t.set_color("font_hover_color", type, font)
	t.set_color("font_pressed_color", type, font)
	t.set_color("font_disabled_color", type, C_TEXT_DISABLED)
	t.set_font_size("font_size", type, 18)


static func _box(bg: Color, border: Color, radius: float, mx: float, my: float, border_width: float = 1.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	if border.a > 0.0:
		sb.set_border_width_all(int(border_width))
		sb.border_color = border
	sb.set_corner_radius_all(int(radius))
	sb.content_margin_left = mx
	sb.content_margin_right = mx
	sb.content_margin_top = my
	sb.content_margin_bottom = my
	return sb

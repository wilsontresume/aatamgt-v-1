class_name AppTheme
extends RefCounted
## Single source of truth for AATAMGT's visual language.
## Dark, gold-accented palette built for portrait mobile screens.
## Built in code (no .tres) so palette values stay greppable and testable.

# --- Palette -------------------------------------------------------------
const C_BG := Color("0d1117")
const C_SURFACE := Color("151b23")
const C_CARD := Color("1b232e")
const C_CARD_HOVER := Color("222c3a")
const C_BORDER := Color("2a3441")
const C_ACCENT := Color("e8b54a")       # royal gold
const C_ACCENT_HOVER := Color("f2c665")
const C_ACCENT_PRESSED := Color("c9982f")
const C_ON_ACCENT := Color("14181f")
const C_TEXT := Color("f2f5f8")
const C_TEXT_SECONDARY := Color("9aa6b5")
const C_TEXT_DISABLED := Color("5d6673")
const C_DANGER := Color("e5484d")
const C_DANGER_PRESSED := Color("c62f34")
const C_SUCCESS := Color("46a758")

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

	# --- Container spacing
	t.set_constant("separation", "VBoxContainer", 14)
	t.set_constant("separation", "HBoxContainer", 12)

	# --- Labels ---------------------------------------------------------
	t.set_color("font_color", "Label", C_TEXT)

	_add_label_variation(t, "TitleLarge", 34, C_ACCENT)
	_add_label_variation(t, "ScreenTitle", 22, C_TEXT)
	_add_label_variation(t, "Heading", 19, C_TEXT)
	_add_label_variation(t, "Body", 17, C_TEXT)
	_add_label_variation(t, "Caption", 14, C_TEXT_SECONDARY)
	_add_label_variation(t, "ValueBig", 26, C_ACCENT)

	# --- Buttons --------------------------------------------------------
	# Base Button reads as the secondary style.
	_style_button(t, "Button", C_CARD, C_CARD_HOVER, _pressed(C_CARD), C_TEXT, C_BORDER)
	_style_button(t, "PrimaryButton", C_ACCENT, C_ACCENT_HOVER, C_ACCENT_PRESSED,
			C_ON_ACCENT, Color.TRANSPARENT)
	_style_button(t, "SecondaryButton", C_SURFACE, C_CARD, _pressed(C_SURFACE),
			C_TEXT, C_BORDER)
	_style_button(t, "GhostButton", Color.TRANSPARENT, Color(1, 1, 1, 0.06),
			Color(1, 1, 1, 0.11), C_TEXT, Color.TRANSPARENT)
	_style_button(t, "DangerButton", C_DANGER, _pressed(C_DANGER), C_DANGER_PRESSED,
			Color.WHITE, Color.TRANSPARENT)

	# --- Cards / panels -------------------------------------------------
	t.set_type_variation("Card", "PanelContainer")
	t.set_stylebox("panel", "Card", _box(C_CARD, C_BORDER, R_CARD, 20, 18))

	# --- Text inputs ----------------------------------------------------
	t.set_stylebox("normal", "LineEdit", _box(C_SURFACE, C_BORDER, R_BUTTON, 24, 15))
	t.set_stylebox("focus", "LineEdit", _box(C_SURFACE, C_ACCENT, R_BUTTON, 24, 15))
	t.set_stylebox("read_only", "LineEdit", _box(C_CARD, C_BORDER, R_BUTTON, 24, 15))
	t.set_color("font_color", "LineEdit", C_TEXT)
	t.set_color("font_placeholder_color", "LineEdit", C_TEXT_SECONDARY)
	t.set_color("font_uneditable_color", "LineEdit", C_TEXT_SECONDARY)
	t.set_font_size("font_size", "LineEdit", 17)

	t.set_type_variation("Dialog", "PanelContainer")
	t.set_stylebox("panel", "Dialog", _box(C_SURFACE, C_BORDER, R_DIALOG, 28, 24))

	t.set_type_variation("Badge", "PanelContainer")
	var badge := _box(Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.16),
			Color.TRANSPARENT, R_PILL, 12, 5)
	t.set_stylebox("panel", "Badge", badge)

	return t


static func _pressed(bg: Color) -> Color:
	return bg.darkened(0.18)


static func _add_label_variation(t: Theme, name: String, size: int, color: Color) -> void:
	t.set_type_variation(name, "Label")
	t.set_font_size("font_size", name, size)
	t.set_color("font_color", name, color)


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


static func _box(bg: Color, border: Color, radius: float, mx: float, my: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	if border.a > 0.0:
		sb.set_border_width_all(1)
		sb.border_color = border
	sb.set_corner_radius_all(int(radius))
	sb.content_margin_left = mx
	sb.content_margin_right = mx
	sb.content_margin_top = my
	sb.content_margin_bottom = my
	return sb

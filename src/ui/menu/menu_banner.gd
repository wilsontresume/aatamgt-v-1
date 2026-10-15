extends Button
## Lobby banner button (Daily Rewards / Royal Pass). Bold colored panel,
## procedural icon, title + subtitle, chevron. The parent screen owns
## all backend behaviour — this is presentation + tap only.

const IconScript := preload("res://src/ui/menu/menu_icon.gd")

signal banner_pressed

@export var banner_title: String = "Daily Rewards"
@export var banner_subtitle: String = "Claim your daily reward!"
@export var banner_color: Color = Color("2f80ed")
@export var banner_icon: StringName = &"daily"

@onready var _icon: Control = $Row/Icon
@onready var _chevron: Control = $Row/Chevron
@onready var _title_label: Label = $Row/Text/TitleLabel
@onready var _subtitle_label: Label = $Row/Text/SubtitleLabel

var _tween: Tween = null


func _ready() -> void:
	_icon.set_script(IconScript)
	_icon.icon = banner_icon
	_icon.icon_color = Color.WHITE
	_chevron.set_script(IconScript)
	_chevron.icon = &"chevron"
	_chevron.icon_color = Color(1, 1, 1, 0.85)
	_title_label.text = banner_title
	_subtitle_label.text = banner_subtitle
	_apply_style()
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button_down.connect(_on_down)
	button_up.connect(_on_up)
	pressed.connect(_forward)


func set_subtitle(text: String) -> void:
	banner_subtitle = text
	if is_node_ready():
		_subtitle_label.text = text


func set_enabled_state(enabled: bool, subtitle: String) -> void:
	set_subtitle(subtitle)
	if is_node_ready():
		disabled = not enabled


func _forward() -> void:
	banner_pressed.emit()


func _apply_style() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = banner_color
	sb.set_corner_radius_all(16)
	sb.set_border_width_all(2)
	sb.border_color = Color(1, 1, 1, 0.3)
	sb.content_margin_left = 12
	sb.content_margin_right = 10
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 5
	sb.shadow_offset = Vector2(0, 3)
	var sb_hover := sb.duplicate()
	sb_hover.bg_color = banner_color.lightened(0.1)
	var sb_pressed := sb.duplicate()
	sb_pressed.bg_color = banner_color.darkened(0.2)
	sb_pressed.shadow_size = 1
	add_theme_stylebox_override("normal", sb)
	add_theme_stylebox_override("hover", sb_hover)
	add_theme_stylebox_override("pressed", sb_pressed)
	add_theme_stylebox_override("disabled", sb)
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	add_theme_color_override("font_color", Color.WHITE)
	add_theme_color_override("font_hover_color", Color.WHITE)
	add_theme_color_override("font_pressed_color", Color.WHITE)
	add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.45))


func _on_down() -> void:
	_kill()
	_tween = create_tween()
	_tween.tween_property(self, "scale", Vector2(0.97, 0.97), 0.06)


func _on_up() -> void:
	_kill()
	_tween = create_tween()
	_tween.tween_property(self, "scale", Vector2.ONE, 0.1) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _kill() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null

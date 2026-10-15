extends Button
## Colorful arcade icon tile for the lobby: rounded colored panel,
## procedural icon, caption underneath, and a subtle press-scale so
## taps feel physical on touchscreens.

const IconScript := preload("res://src/ui/menu/menu_icon.gd")

@export var icon_name: StringName = &"home"
@export var tile_color: Color = Color("2f80ed")
@export var caption: String = "":
	set(value):
		caption = value
		if is_node_ready():
			_caption_label.text = caption
@export var icon_size: int = 26
@export var show_caption: bool = true:
	set(value):
		show_caption = value
		if is_node_ready():
			_caption_label.visible = show_caption

var _base_scale := Vector2.ONE
var _tween: Tween = null

@onready var _icon: Control = $Icon
@onready var _caption_label: Label = $CaptionLabel


func _ready() -> void:
	_icon.set_script(IconScript)
	_icon.icon = icon_name
	_icon.icon_color = Color.WHITE
	_icon.custom_minimum_size = Vector2(icon_size, icon_size)
	_caption_label.text = caption
	_caption_label.visible = show_caption
	_apply_style()
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button_down.connect(_on_down)
	button_up.connect(_on_up)
	pressed.connect(_on_pressed_reset)


func _apply_style() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = tile_color
	sb.set_corner_radius_all(14)
	sb.set_border_width_all(2)
	sb.border_color = Color(1, 1, 1, 0.28)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 8
	sb.content_margin_bottom = 4
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 4
	sb.shadow_offset = Vector2(0, 3)
	var sb_hover := sb.duplicate()
	sb_hover.bg_color = tile_color.lightened(0.12)
	var sb_pressed := sb.duplicate()
	sb_pressed.bg_color = tile_color.darkened(0.22)
	sb_pressed.shadow_size = 1
	sb_pressed.shadow_offset = Vector2(0, 1)
	add_theme_stylebox_override("normal", sb)
	add_theme_stylebox_override("hover", sb_hover)
	add_theme_stylebox_override("pressed", sb_pressed)
	add_theme_stylebox_override("disabled", sb)
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	add_theme_color_override("font_color", Color.WHITE)
	add_theme_color_override("font_hover_color", Color.WHITE)
	add_theme_color_override("font_pressed_color", Color.WHITE)
	add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.4))


func _on_down() -> void:
	_kill_tween()
	_tween = create_tween()
	_tween.tween_property(self, "scale", Vector2(0.92, 0.92), 0.06)


func _on_up() -> void:
	_animate_scale(Vector2.ONE, 0.1)


func _on_pressed_reset() -> void:
	if scale.x > 0.99:
		_animate_scale(Vector2.ONE, 0.1)


func _animate_scale(target: Vector2, duration: float) -> void:
	_kill_tween()
	_tween = create_tween()
	_tween.tween_property(self, "scale", target, duration) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null

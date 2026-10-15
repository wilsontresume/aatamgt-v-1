extends Button
## Login-screen pill (Google / Facebook / Guest / link switch): a
## procedural leading badge and trailing chevron are drawn as anchored
## child icon Controls; the Button itself supplies the label and the
## full-row tap target. Icons never intercept input themselves.

const IconScript := preload("res://src/ui/menu/menu_icon.gd")

@export var badge: StringName = &"none"
@export var badge_color: Color = Color.WHITE
@export var chevron_color: Color = Color.WHITE
@export var show_chevron: bool = true


func _ready() -> void:
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if badge != &"none":
		add_child(_make_icon(badge, badge_color, 28.0, true))
	if show_chevron:
		add_child(_make_icon(&"chevron", chevron_color, 18.0, false))


func _make_icon(icon_name: StringName, color: Color, px: float,
		on_left: bool) -> Control:
	var ic := Control.new()
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ic.set_script(IconScript)
	ic.set("icon", icon_name)
	ic.set("icon_color", color)
	if on_left:
		ic.anchor_left = 0.0
		ic.anchor_right = 0.0
		ic.anchor_top = 0.5
		ic.anchor_bottom = 0.5
		ic.offset_left = 16.0
		ic.offset_right = 16.0 + px
	else:
		ic.anchor_left = 1.0
		ic.anchor_right = 1.0
		ic.anchor_top = 0.5
		ic.anchor_bottom = 0.5
		ic.offset_left = -14.0 - px
		ic.offset_right = -14.0
	ic.offset_top = -px * 0.5
	ic.offset_bottom = px * 0.5
	return ic

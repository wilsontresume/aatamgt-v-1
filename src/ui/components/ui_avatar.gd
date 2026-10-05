extends Control
## Circular avatar with the player's initial (placeholder for real
## profile pictures in a later phase).

var _initial := "?"
var _avatar_size := 56


func set_initial(initial: String) -> void:
	_initial = initial if initial.length() > 0 else "?"
	queue_redraw()


func set_avatar_size(value: int) -> void:
	_avatar_size = maxi(24, value)
	custom_minimum_size = Vector2(_avatar_size, _avatar_size)
	size = custom_minimum_size
	queue_redraw()


func _ready() -> void:
	if custom_minimum_size.x > 0:
		_avatar_size = int(custom_minimum_size.x)
	resized.connect(queue_redraw)
	queue_redraw()


func _draw() -> void:
	var center := size / 2.0
	var radius := minf(size.x, size.y) / 2.0 - 2.0
	var accent := AppTheme.C_ACCENT
	draw_circle(center, radius, accent.darkened(0.35))
	draw_arc(center, radius, 0.0, TAU, 48, accent, 2.0, true)
	var font := get_theme_default_font()
	var font_size := int(radius * 0.95)
	var text_color := AppTheme.C_TEXT
	var ascent := font.get_ascent(font_size)
	var half := font.get_string_size(_initial, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
	draw_string(font, Vector2(center.x - half.x / 2.0, center.y + ascent / 2.0 - 1.0),
			_initial, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_color)

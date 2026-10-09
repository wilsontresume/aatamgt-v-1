extends Control
## Circular avatar with the player's initial (placeholder for real
## profile pictures in a later phase). Phase 12: accepts the equipped
## PROFILE_PICTURE fill/accent and PROFILE_FRAME ring from the server
## inventory — empty dictionaries keep the classic look.

var _initial := "?"
var _avatar_size := 56
var _style := {}
var _frame := {}


func set_initial(initial: String) -> void:
	_initial = initial if initial.length() > 0 else "?"
	queue_redraw()


func set_avatar_size(value: int) -> void:
	_avatar_size = maxi(24, value)
	custom_minimum_size = Vector2(_avatar_size, _avatar_size)
	size = custom_minimum_size
	queue_redraw()


## Equipped profile-picture palette ({fill, accent} or {} for classic).
func set_style(style: Dictionary) -> void:
	_style = style if style != null else {}
	queue_redraw()


## Equipped profile-frame ring ({color, width} or {} for none).
func set_frame(frame: Dictionary) -> void:
	_frame = frame if frame != null else {}
	queue_redraw()


func _ready() -> void:
	if custom_minimum_size.x > 0:
		_avatar_size = int(custom_minimum_size.x)
	resized.connect(queue_redraw)
	queue_redraw()


func _draw() -> void:
	var center := size / 2.0
	var frame_width := float(_frame.get("width", 0.0)) if not _frame.is_empty() else 0.0
	var radius := minf(size.x, size.y) / 2.0 - 2.0
	if frame_width > 0.0:
		# Leave room outside the disc for the ring.
		radius = minf(size.x, size.y) / 2.0 - 1.0 - (frame_width + 1.0)
	if radius <= 2.0:
		radius = 2.0

	var accent: Color = _style.get("accent", AppTheme.C_ACCENT)
	var fill: Color = _style.get("fill", accent.darkened(0.35))
	draw_circle(center, radius, fill)
	draw_arc(center, radius, 0.0, TAU, 48, accent, 2.0, true)

	if frame_width > 0.0:
		var frame_color: Color = _frame.get("color", AppTheme.C_BORDER)
		draw_arc(center, radius + frame_width * 0.5 + 1.0, 0.0, TAU, 64,
				frame_color, frame_width, true)

	var font := get_theme_default_font()
	var font_size := int(radius * 0.95)
	var text_color := AppTheme.C_TEXT
	var ascent := font.get_ascent(font_size)
	var half := font.get_string_size(_initial, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
	draw_string(font, Vector2(center.x - half.x / 2.0, center.y + ascent / 2.0 - 1.0),
			_initial, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_color)

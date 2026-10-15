class_name MatchHandPanel
extends PanelContainer
## In-hand / on-board piece tray for the in-match HUD. One panel per
## side: caption (side name), count line ("In hand: 9 · On board: 3"),
## and a row of up to N dots showing remaining pieces.

var _caption: Label = null
var _count_label: Label = null
var _dots_box: HBoxContainer = null
var _is_opponent := false
var _dot_color := Color("e5484d")


func _ready() -> void:
	theme_type_variation = "HandPanel"
	add_theme_constant_override("separation", 4)
	if _caption == null:
		_build()


## is_opponent: true tints the dots toward the opponent side colour.
func setup(is_opponent: bool, dot_color: Color) -> void:
	_is_opponent = is_opponent
	_dot_color = dot_color
	if _caption == null:
		_build()
	_queue_dot_redraw()


func set_counts(side_name: String, in_hand: int, on_board: int, total: int) -> void:
	if _caption == null:
		_build()
	_caption.text = side_name
	if in_hand >= 0:
		_count_label.text = "In hand: %d · On board: %d" % [in_hand, on_board]
		_apply_counts_for_dots(in_hand, on_board)
	else:
		_count_label.text = "On board: %d / %d" % [on_board, total]
		_apply_counts_for_dots(0, on_board)
	_queue_dot_redraw()


var _dot_total := 0
var _dot_in_hand := 0
var _dot_on_board := 0


func _queue_dot_redraw() -> void:
	# Dots reflect remaining army: in-hand (solid) + on-board (hollow).
	if _dots_box == null:
		return
	for child in _dots_box.get_children():
		child.queue_free()
	var remaining := maxi(_dot_in_hand + _dot_on_board, 0)
	var shown := mini(remaining, 16)
	for i in shown:
		var dot := Panel.new()
		dot.custom_minimum_size = Vector2(9, 9)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var style := StyleBoxFlat.new()
		var filled := i < _dot_in_hand
		if filled:
			style.bg_color = _dot_color
			style.border_color = Color(1, 1, 1, 0.4)
		else:
			style.bg_color = Color(_dot_color.r, _dot_color.g, _dot_color.b, 0.25)
			style.border_color = _dot_color
		style.set_corner_radius_all(5)
		style.set_border_width_all(1 if not filled else 0)
		dot.add_theme_stylebox_override("panel", style)
		_dots_box.add_child(dot)


func _apply_counts_for_dots(in_hand: int, on_board: int) -> void:
	_dot_in_hand = in_hand
	_dot_on_board = on_board


func _build() -> void:
	# PanelContainer gives every child the same rect; stack in a box.
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 2)
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(stack)

	_caption = Label.new()
	_caption.theme_type_variation = "PieceDotLabel"
	_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption.text = "—"
	stack.add_child(_caption)

	_count_label = Label.new()
	_count_label.theme_type_variation = "PieceDotLabel"
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_count_label.text = ""
	stack.add_child(_count_label)

	_dots_box = HBoxContainer.new()
	_dots_box.add_theme_constant_override("separation", 3)
	_dots_box.alignment = BoxContainer.ALIGNMENT_CENTER
	stack.add_child(_dots_box)

class_name MatchTurnBadge
extends PanelContainer
## Centre turn indicator for the in-match HUD: whose move it is, plus
## the online turn timer when a clock is running.

var _turn_label: Label = null
var _timer_label: Label = null


func _ready() -> void:
	theme_type_variation = "TurnPanel"
	add_theme_constant_override("separation", 2)
	if _turn_label == null:
		_build()


func set_turn(text: String, seconds_left: int = -1) -> void:
	if _turn_label == null:
		_build()
	_turn_label.text = text
	if seconds_left >= 0:
		var mins := seconds_left / 60
		var secs := seconds_left % 60
		_timer_label.text = "%d:%02d" % [mins, secs]
		_timer_label.visible = true
	else:
		_timer_label.visible = false


## Brief gold flash when the turn flips.
func flash() -> void:
	var tw := create_tween()
	tw.tween_property(self, "modulate", Color(1.3, 1.3, 1.05), 0.15)
	tw.tween_property(self, "modulate", Color.WHITE, 0.4)


func _build() -> void:
	# PanelContainer gives every child the same rect; stack in a box.
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 0)
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(stack)

	_turn_label = Label.new()
	_turn_label.theme_type_variation = "SideName"
	_turn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_turn_label.text = "—"
	stack.add_child(_turn_label)

	_timer_label = Label.new()
	_timer_label.theme_type_variation = "Caption"
	_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_timer_label.visible = false
	stack.add_child(_timer_label)

extends Control
## Modal error dialog (styled via the "Dialog" theme variation).
## Presented through App.dialog.show_error().

signal dismissed

@onready var _title_label: Label = $Center/Panel/Body/TitleLabel
@onready var _message_label: Label = $Center/Panel/Body/MessageLabel
@onready var _ok_button: Button = $Center/Panel/Body/OkButton


func _ready() -> void:
	visible = false
	_ok_button.pressed.connect(close)


func _notification(what: int) -> void:
	# Android settles the viewport size asynchronously; re-sort the
	# Center container after any resize so the panel centers correctly.
	if what == NOTIFICATION_RESIZED and is_node_ready():
		call_deferred("_resort")


func _resort() -> void:
	if is_node_ready() and has_node("Center"):
		# Android can leave this root at 0x0 (anchors never re-resolved
		# after the surface-sized viewport arrives). Re-resolve the
		# full-rect preset against the (now real) parent size.
		var parent_ctrl := get_parent() as Control
		if parent_ctrl != null and parent_ctrl.size.x > 1.0 \
				and (size.x < 1.0 or size.y < 1.0):
			set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var center := $Center as Control
		if center != null and size.x > 1.0:
			# Pin Center to this dialog's rect directly (the full-rect
			# preset on the container keeps a stale oversized height
			# on Android).
			center.anchor_right = 0.0
			center.anchor_bottom = 0.0
			center.offset_right = size.x
			center.offset_bottom = size.y
		$Center.queue_sort()


func open(title: String, message: String) -> void:
	_title_label.text = title
	_message_label.text = message
	# A fresh visibility cycle forces the internal Center container to
	# re-sort its panel: on first show the panel otherwise stays at (0,0).
	visible = false
	visible = true
	modulate.a = 0.0
	_resort()
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, 0.15)


func close() -> void:
	visible = false
	dismissed.emit()

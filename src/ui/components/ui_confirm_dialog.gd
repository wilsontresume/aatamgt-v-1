extends Control
## Modal confirmation dialog. Presented through:
##   var ok: bool = await App.dialog.confirm("Title", "Message")

signal confirmed(result: bool)

var _confirm_text := "Confirm"
var _danger := false

@onready var _title_label: Label = $Center/Panel/Body/TitleLabel
@onready var _message_label: Label = $Center/Panel/Body/MessageLabel
@onready var _cancel_button: Button = $Center/Panel/Body/Buttons/CancelButton
@onready var _confirm_button: Button = $Center/Panel/Body/Buttons/ConfirmButton


func _ready() -> void:
	visible = false
	_cancel_button.pressed.connect(func() -> void: resolve(false))
	_confirm_button.pressed.connect(func() -> void: resolve(true))


func _notification(what: int) -> void:
	# Android settles viewport size asynchronously — re-center on resize.
	if what == NOTIFICATION_RESIZED and is_node_ready():
		call_deferred("_resort")


func _resort() -> void:
	if is_node_ready() and has_node("Center"):
		# Same Android guard as ui_error_dialog: re-resolve the root
		# full-rect preset if the surface-sized viewport arrived late,
		# and pin Center to this dialog's rect directly.
		var parent_ctrl := get_parent() as Control
		if parent_ctrl != null and parent_ctrl.size.x > 1.0 \
				and (size.x < 1.0 or size.y < 1.0):
			set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var center := $Center as Control
		if center != null and size.x > 1.0:
			center.anchor_right = 0.0
			center.anchor_bottom = 0.0
			center.offset_right = size.x
			center.offset_bottom = size.y
		$Center.queue_sort()


func configure(confirm_text: String, danger: bool) -> void:
	_confirm_text = confirm_text
	_danger = danger
	if is_node_ready():
		_apply_confirm_style()


func open(title: String, message: String) -> void:
	_title_label.text = title
	_message_label.text = message
	_apply_confirm_style()
	# Fresh visibility cycle so the Center container re-sorts the panel
	# (first show otherwise leaves it at (0,0)).
	visible = false
	visible = true
	modulate.a = 0.0
	_resort()
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, 0.15)


func resolve(result: bool) -> void:
	if not visible:
		return
	visible = false
	confirmed.emit(result)


func _apply_confirm_style() -> void:
	_confirm_button.text = _confirm_text
	_confirm_button.variant = 3 if _danger else 0

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


func configure(confirm_text: String, danger: bool) -> void:
	_confirm_text = confirm_text
	_danger = danger
	if is_node_ready():
		_apply_confirm_style()


func open(title: String, message: String) -> void:
	_title_label.text = title
	_message_label.text = message
	_apply_confirm_style()
	visible = true
	modulate.a = 0.0
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

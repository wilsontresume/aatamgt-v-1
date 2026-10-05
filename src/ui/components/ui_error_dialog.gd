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


func open(title: String, message: String) -> void:
	_title_label.text = title
	_message_label.text = message
	visible = true
	modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, 0.15)


func close() -> void:
	visible = false
	dismissed.emit()

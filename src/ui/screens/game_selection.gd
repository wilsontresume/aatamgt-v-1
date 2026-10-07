extends Control
## Game selection. Aadu Puli Aattam is playable offline (Phase 4);
## the remaining cards are placeholders for later phases and inert.


@onready var _aadu_puli_card: Control = $Margin/Content/AaduPuliCard


func _ready() -> void:
	_aadu_puli_card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_aadu_puli_card.gui_input.connect(_on_aadu_puli_card_input)


func _on_aadu_puli_card_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		App.navigation.go(&"aadu_puli")

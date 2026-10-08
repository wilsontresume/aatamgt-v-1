extends Control
## Game selection. Aadu Puli Aattam, Solah Seedi and Nine Men's Morris
## are playable; the remaining cards are placeholders and inert.


@onready var _aadu_puli_card: Control = $Margin/Content/AaduPuliCard
@onready var _solah_seedi_card: Control = $Margin/Content/SolahSeediCard
@onready var _morris_card: Control = $Margin/Content/MorrisCard


func _ready() -> void:
	_wire(_aadu_puli_card, &"aadu_puli")
	_wire(_solah_seedi_card, &"solah_seedi")
	_wire(_morris_card, &"nine_mens_morris")


func _wire(card: Control, screen_id: StringName) -> void:
	if card == null:
		return
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.gui_input.connect(
			func(event: InputEvent) -> void: _on_card_input(event, screen_id))


func _on_card_input(event: InputEvent, screen_id: StringName) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		App.navigation.go(screen_id)

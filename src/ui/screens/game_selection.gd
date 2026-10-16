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
	# Phase E: reorder cards to match the published manifest displayOrder.
	if App != null and App.content != null:
		_apply_display_order()
		if not App.content.manifest_changed.is_connected(_on_manifest_changed):
			App.content.manifest_changed.connect(_on_manifest_changed)


func _on_manifest_changed() -> void:
	if is_inside_tree():
		_apply_display_order()


## Reorders the three card nodes under the VBox to follow the manifest's
## game displayOrder. Unknown/missing games keep their scene order at the end.
func _apply_display_order() -> void:
	var row := _aadu_puli_card.get_parent()
	if row == null:
		return
	var cards := {
		"aadu-puli-aattam": _aadu_puli_card,
		"solah-seedi": _solah_seedi_card,
		"nine-mens-morris": _morris_card,
	}
	var order := App.content.get_manifest().games_ordered()
	var index := 0
	for entry in order:
		if not (entry is Dictionary):
			continue
		if str((entry as Dictionary).get("status", "ACTIVE")) != "ACTIVE":
			continue
		var key := str((entry as Dictionary).get("key", ""))
		if cards.has(key) and is_instance_valid(cards[key]):
			row.move_child(cards[key], index)
			index += 1


func _wire(card: Control, screen_id: StringName) -> void:
	if card == null:
		return
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.gui_input.connect(
			func(event: InputEvent) -> void: _on_card_input(event, screen_id))


func _on_card_input(event: InputEvent, screen_id: StringName) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		if OS.is_debug_build():
			print("UI: game selected -> %s" % screen_id)
		App.analytics.track("game_selected", {}, String(screen_id))
		App.navigation.go(screen_id)

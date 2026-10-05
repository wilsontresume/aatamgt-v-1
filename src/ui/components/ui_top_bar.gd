extends HBoxContainer
## Standard screen top bar: optional back button, centred-ish title,
## right-hand action slot with a coin balance.

signal back_pressed

@export var title: String = "":
	set(value):
		title = value
		if is_node_ready():
			_title_label.text = title

@export var show_back: bool = false:
	set(value):
		show_back = value
		if is_node_ready():
			_back_button.visible = show_back

@export var show_coins: bool = true:
	set(value):
		show_coins = value
		if is_node_ready():
			_coin_balance.visible = show_coins

@onready var _back_button: Button = $BackButton
@onready var _title_label: Label = $TitleLabel
@onready var _coin_balance: Control = $ActionsSlot/CoinBalance


func _ready() -> void:
	_title_label.text = title
	_back_button.visible = show_back
	_coin_balance.visible = show_coins
	_back_button.pressed.connect(_on_back_pressed)


func _on_back_pressed() -> void:
	back_pressed.emit()
	App.navigation.back()

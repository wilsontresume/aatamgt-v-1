class_name MatchPlayerCard
extends PanelContainer
## Compact player identity card for the in-match HUD: circular
## avatar, display name, side/role caption, and optional coin balance.
## Colours switch between PlayerBlue (you) and PlayerRed (opponent).

const AvatarScene := preload("res://src/ui/components/ui_avatar.gd")

var _avatar: Control = null
var _name_label: Label = null
var _side_label: Label = null
var _coins_label: Label = null
var _you_tag: Label = null
var _is_opponent := false


func _ready() -> void:
	theme_type_variation = "PlayerRed" if _is_opponent else "PlayerBlue"
	add_theme_constant_override("separation", 8)
	_build()


## Configure after adding to the tree (or call before — _ready builds
## lazily on first set if needed).
func setup(is_opponent: bool) -> void:
	_is_opponent = is_opponent
	if is_node_ready():
		theme_type_variation = "PlayerRed" if _is_opponent else "PlayerBlue"


func set_identity(username: String, side_caption: String,
		show_you_tag: bool, coins: int = -1) -> void:
	if _name_label == null:
		_build()
	_name_label.text = username
	_side_label.text = side_caption
	_you_tag.visible = show_you_tag
	_avatar.set_initial(username.substr(0, 1).to_upper() if username.length() > 0 else "?")
	if coins >= 0:
		_coins_label.text = "%d" % coins
		_coins_label.visible = true
	else:
		_coins_label.visible = false


## Cosmetic profile picture / frame from App.auth.
func set_cosmetics(style: Dictionary, frame: Dictionary) -> void:
	if _avatar == null:
		_build()
	_avatar.set_style(style)
	_avatar.set_frame(frame)


## Gold ring flash on turn change.
func pulse_turn() -> void:
	var tw := create_tween()
	tw.tween_property(self, "modulate", Color(1.25, 1.25, 1.0), 0.18)
	tw.tween_property(self, "modulate", Color.WHITE, 0.35)


func _build() -> void:
	if _avatar != null:
		return
	# PanelContainer gives every child the same rect; lay out in a row.
	var row_root := HBoxContainer.new()
	row_root.add_theme_constant_override("separation", 8)
	row_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(row_root)

	_avatar = AvatarScene.new()
	_avatar.set_avatar_size(34)
	_avatar.custom_minimum_size = Vector2(34, 34)
	row_root.add_child(_avatar)

	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 0)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row_root.add_child(info)

	_name_label = Label.new()
	_name_label.theme_type_variation = "SideName"
	_name_label.clip_text = true
	_name_label.text = "…"
	info.add_child(_name_label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	info.add_child(row)

	_side_label = Label.new()
	_side_label.theme_type_variation = "Caption"
	_side_label.text = ""
	row.add_child(_side_label)

	_you_tag = Label.new()
	_you_tag.theme_type_variation = "YouTag"
	_you_tag.text = "YOU"
	_you_tag.visible = false
	row.add_child(_you_tag)

	_coins_label = Label.new()
	_coins_label.theme_type_variation = "PieceDotLabel"
	_coins_label.text = ""
	_coins_label.visible = false
	row.add_child(_coins_label)

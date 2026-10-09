extends HBoxContainer
## Reusable player profile display: avatar + name + guest tag.

@export var show_tag: bool = true
@export var avatar_size: int = 56:
	set(value):
		avatar_size = value
		if is_node_ready():
			_avatar.set_avatar_size(avatar_size)

@onready var _avatar: Control = $Avatar
@onready var _name_label: Label = $Info/NameLabel
@onready var _tag: Label = $Info/TagLabel


func _ready() -> void:
	_avatar.set_avatar_size(avatar_size)
	App.user.profile_changed.connect(_on_profile_changed)
	_on_profile_changed(App.user.get_profile())
	# Phase 12: equipped profile picture + frame come from the server
	# inventory; before the first fetch both styles are empty (classic).
	App.cosmetics.inventory_changed.connect(_apply_cosmetics)
	_apply_cosmetics()


func _apply_cosmetics() -> void:
	_avatar.set_style(CosmeticService.pfp_style(
			App.cosmetics.equipped_key("PROFILE_PICTURE")))
	_avatar.set_frame(CosmeticService.frame_style(
			App.cosmetics.equipped_key("PROFILE_FRAME")))


func _on_profile_changed(profile: Dictionary) -> void:
	var display_name := str(profile.get("display_name", "…"))
	_name_label.text = display_name
	_avatar.set_initial(str(profile.get("avatar_text", display_name.left(1))))
	_tag.text = "Guest" if bool(profile.get("is_guest", false)) else "Player"
	_tag.visible = show_tag

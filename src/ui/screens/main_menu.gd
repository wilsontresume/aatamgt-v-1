extends Control
## Platform hub: play (game selection), profile, settings.

@onready var _play_button: Button = $Margin/Content/PlayButton
@onready var _profile_button: Button = $Margin/Content/ProfileButton
@onready var _settings_button: Button = $Margin/Content/SettingsButton
@onready var _version_label: Label = $Margin/Content/VersionLabel


func _ready() -> void:
	_version_label.text = "v%s · Phase 3" % App.APP_VERSION
	_play_button.pressed.connect(func() -> void: App.navigation.go(&"game_selection"))
	_profile_button.pressed.connect(func() -> void: App.navigation.go(&"profile"))
	_settings_button.pressed.connect(func() -> void: App.navigation.go(&"settings"))

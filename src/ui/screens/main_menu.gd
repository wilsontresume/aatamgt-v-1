extends Control
## Platform hub: play (game selection), profile, settings.

@onready var _play_button: Button = $Margin/Content/PlayButton
@onready var _profile_button: Button = $Margin/Content/ProfileButton
@onready var _settings_button: Button = $Margin/Content/SettingsButton
@onready var _friends_button: Button = $Margin/Content/FriendsButton
@onready var _history_button: Button = $Margin/Content/HistoryButton
@onready var _version_label: Label = $Margin/Content/VersionLabel


func _ready() -> void:
	_version_label.text = "v%s · Phase 3" % App.APP_VERSION
	_play_button.pressed.connect(func() -> void: App.navigation.go(&"game_selection"))
	_profile_button.pressed.connect(func() -> void: App.navigation.go(&"profile"))
	_settings_button.pressed.connect(func() -> void: App.navigation.go(&"settings"))
	_friends_button.pressed.connect(func() -> void: App.navigation.go(&"friends"))
	_history_button.pressed.connect(func() -> void: App.navigation.go(&"history"))

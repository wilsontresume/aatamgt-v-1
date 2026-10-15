extends Control
## Device settings (audio). These are local preferences only — no game
## or economy state lives on the client.

@onready var _volume_slider: HSlider = $Margin/Content/AudioPanel/AudioBody/VolumeRow/VolumeSlider
@onready var _volume_value: Label = $Margin/Content/AudioPanel/AudioBody/VolumeRow/VolumeHeader/VolumeValueLabel
@onready var _version_label: Label = $Margin/Content/AboutPanel/AboutBody/VersionLabel
@onready var _sign_in_button: Button = $Margin/Content/AccountPanel/AccountBody/SignInButton
@onready var _account_hint: Label = $Margin/Content/AccountPanel/AccountBody/AccountHint
@onready var _analytics_toggle: CheckButton = $Margin/Content/PrivacyPanel/PrivacyBody/AnalyticsRow/AnalyticsToggle

const SETTINGS_SECTION := "audio"
const KEY_MASTER_VOLUME := "master_volume"
const DEFAULT_VOLUME := 0.8


func _ready() -> void:
	var saved := float(App.get_local_setting(SETTINGS_SECTION, KEY_MASTER_VOLUME, DEFAULT_VOLUME))
	saved = clampf(saved, 0.0, 1.0)
	_volume_slider.set_value_no_signal(saved)
	_refresh_volume_label(saved)
	_volume_slider.value_changed.connect(_on_volume_changed)

	_version_label.text = "Version %s" % App.APP_VERSION

	_sign_in_button.pressed.connect(_on_sign_in_pressed)
	App.auth.session_changed.connect(_on_account_changed)
	App.auth.signed_out.connect(_on_signed_out)
	_refresh_account()

	_analytics_toggle.set_pressed_no_signal(App.analytics.is_enabled())
	_analytics_toggle.toggled.connect(_on_analytics_toggled)


func _on_sign_in_pressed() -> void:
	if App.auth.is_authenticated():
		var confirmed: bool = await App.dialog.confirm(
				"Sign out?", "You can sign back in at any time.", "Sign out", true)
		if confirmed:
			await App.auth.logout()
			_refresh_account()
	else:
		App.navigation.go(&"auth")


func _on_account_changed(_user: Dictionary) -> void:
	_refresh_account()


func _on_signed_out() -> void:
	_refresh_account()


func _refresh_account() -> void:
	if App.auth.is_authenticated():
		var account_kind := "Guest account" if App.auth.is_guest() else "Registered account"
		_account_hint.text = "Signed in as %s \u00b7 %s" % [App.auth.get_username(), account_kind]
		_sign_in_button.text = "Sign out"
	else:
		_account_hint.text = "Sign in to keep your progress, or keep playing as a guest."
		_sign_in_button.text = "Sign in / Register"


func _on_volume_changed(value: float) -> void:
	_refresh_volume_label(value)
	var bus := AudioServer.get_bus_index("Master")
	if bus >= 0:
		AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(value, 0.0001)))
	App.save_local_setting(SETTINGS_SECTION, KEY_MASTER_VOLUME, value)


func _on_analytics_toggled(pressed: bool) -> void:
	App.analytics.set_enabled(pressed)


func _refresh_volume_label(value: float) -> void:
	_volume_value.text = "%d%%" % roundi(value * 100.0)

extends Control
## Device settings (audio). These are local preferences only — no game
## or economy state lives on the client.

@onready var _volume_slider: HSlider = $Margin/Content/AudioPanel/AudioBody/VolumeRow/VolumeSlider
@onready var _volume_value: Label = $Margin/Content/AudioPanel/AudioBody/VolumeRow/VolumeHeader/VolumeValueLabel
@onready var _version_label: Label = $Margin/Content/AboutPanel/AboutBody/VersionLabel

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


func _on_volume_changed(value: float) -> void:
	_refresh_volume_label(value)
	var bus := AudioServer.get_bus_index("Master")
	if bus >= 0:
		AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(value, 0.0001)))
	App.save_local_setting(SETTINGS_SECTION, KEY_MASTER_VOLUME, value)


func _refresh_volume_label(value: float) -> void:
	_volume_value.text = "%d%%" % roundi(value * 100.0)

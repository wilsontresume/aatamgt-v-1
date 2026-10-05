extends Node
## AATAMGT central application state and service hub (autoload singleton: App).
##
## Owns the placeholder services introduced in Phase 1:
## user, coins, network, game_session, navigation, dialog.
## Later phases replace placeholder internals with backend-backed
## implementations WITHOUT changing call sites.

signal bootstrap_completed

const APP_VERSION := "0.1.0"
const LOCAL_SETTINGS_PATH := "user://settings.cfg"

var user: UserService
var coins: CoinService
var network: NetworkService
var game_session: GameSessionService
var navigation: NavigationService
var dialog: DialogService

var _bootstrapped := false


func _init() -> void:
	navigation = NavigationService.new()
	user = UserService.new()
	coins = CoinService.new()
	network = NetworkService.new()
	game_session = GameSessionService.new()
	dialog = DialogService.new()


## Idempotent local initialization, invoked by the splash screen.
## Phase 1: local placeholders only. Phase 2+: fetch remote config,
## profile and wallet from the authoritative backend.
func bootstrap() -> void:
	if _bootstrapped:
		return
	_bootstrapped = true
	user.initialize_local_placeholder()
	network.set_offline()
	_apply_audio_settings()
	bootstrap_completed.emit()


func is_bootstrapped() -> bool:
	return _bootstrapped


# --- Local (device-only) settings ----------------------------------------
# Not game state — just device preferences (volume, etc). Game/economy
# state never lives on the client.

func get_local_setting(section: String, key: String, default_value: Variant) -> Variant:
	var cfg := ConfigFile.new()
	if cfg.load(LOCAL_SETTINGS_PATH) != OK:
		return default_value
	return cfg.get_value(section, key, default_value)


func save_local_setting(section: String, key: String, value: Variant) -> void:
	var cfg := ConfigFile.new()
	cfg.load(LOCAL_SETTINGS_PATH)  # keep existing values when present
	cfg.set_value(section, key, value)
	if cfg.save(LOCAL_SETTINGS_PATH) != OK:
		push_warning("App: could not save local setting %s/%s" % [section, key])


func _apply_audio_settings() -> void:
	var linear: float = float(get_local_setting("audio", "master_volume", 0.8))
	var bus := AudioServer.get_bus_index("Master")
	if bus >= 0:
		AudioServer.set_bus_volume_db(bus, linear_to_db(clampf(linear, 0.0001, 1.0)))

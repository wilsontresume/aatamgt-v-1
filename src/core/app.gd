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

## Phase 3: backend transport + authenticated session.
var api_client: ApiClient
var auth: AuthService

## Phase 6: authoritative realtime match session.
var online: OnlineMatchService

## Phase 8: rewarded + interstitial ads behind a provider abstraction.
var ads: AdService

## Phase 11: friends, challenges, match history (REST-only social layer).
var social: SocialService

## Phase 12: server-owned cosmetic inventory.
var cosmetics: CosmeticService

## Phase 14: competitive ranking (per-game ratings, seasons, leaderboard).
var rankings: RankingService

## Phase 13: platform in-app purchases (store-verified, server-granted).
var shop: ShopService

## Phase 15: staff dashboard API (role-guarded admin endpoints).
var admin: AdminService

## Phase 16: privacy-conscious product analytics (opt-out, no PII).
var analytics: AnalyticsService

## Menu redesign: daily login rewards (server-owned streaks/claims).
var rewards: RewardsService

## Workflow Change 2: multiplayer-first entry (tiers, queue, AI fallback).
var matchmaking: MatchmakingService

## Phase E: published content manifest (assets, board themes, tier art).
var content: ContentService

## Currently highlighted game on the main-menu carousel. The PLAY
## button opens this game's multiplayer-first entry screen.
signal selected_game_changed(game_id: StringName)
var selected_game: StringName = &"aadu_puli"

const SELECTED_GAME_SETTING := "menu"
const SELECTED_GAME_KEY := "selected_game"
const VALID_GAMES: Array[StringName] = [&"aadu_puli", &"solah_seedi", &"nine_mens_morris"]

var _bootstrapped := false


func _init() -> void:
	navigation = NavigationService.new()
	user = UserService.new()
	coins = CoinService.new()
	network = NetworkService.new()
	game_session = GameSessionService.new()
	dialog = DialogService.new()
	api_client = ApiClient.new()
	auth = AuthService.new(api_client)
	online = OnlineMatchService.new(api_client, auth)
	ads = AdService.new(auth)
	social = SocialService.new(auth)
	cosmetics = CosmeticService.new(auth, coins)
	rankings = RankingService.new(auth, api_client)
	shop = ShopService.new(api_client, auth, coins)
	admin = AdminService.new(auth)
	analytics = AnalyticsService.new(api_client, auth,
			get_local_setting, save_local_setting, APP_VERSION)
	rewards = RewardsService.new(auth)
	matchmaking = MatchmakingService.new(auth)
	content = ContentService.new(api_client)
	var saved_game := str(get_local_setting(SELECTED_GAME_SETTING,
			SELECTED_GAME_KEY, String(selected_game)))
	if VALID_GAMES.has(StringName(saved_game)):
		selected_game = StringName(saved_game)


func _ready() -> void:
	api_client.name = "ApiClient"
	add_child(api_client)
	online.name = "OnlineMatchService"
	add_child(online)
	configure_backend()
	auth.session_changed.connect(_on_session_changed)
	auth.signed_out.connect(_on_signed_out)
	api_client.reachability_changed.connect(_on_reachability)
	ads.reward_granted.connect(_on_reward_granted)
	content.start()


func _notification(what: int) -> void:
	# Session duration + queued events on quit / backgrounding. The
	# flush is async, so a desktop quit is held briefly to let the
	# final batch leave the machine; backgrounding on mobile already
	# keeps the process alive for it.
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		get_tree().auto_accept_quit = false
		analytics.end_session()
		get_tree().create_timer(0.5).timeout.connect(_quit_after_flush)
	elif what == NOTIFICATION_APPLICATION_PAUSED:
		analytics.end_session()


func _quit_after_flush() -> void:
	get_tree().quit()


## (Re)points the API client at the configured backend. Returns false
## when the URL violates the HTTPS policy.
func configure_backend() -> bool:
	return api_client.configure(BackendConfig.resolve_base_url(),
			BackendConfig.ca_cert_path())


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
	analytics.start_session()  # install/first-launch/session metrics
	bootstrap_completed.emit()


func is_bootstrapped() -> bool:
	return _bootstrapped


## Highlights a playable game on the main-menu carousel. Only the three
## implemented titles are accepted; the choice persists locally so the
## next launch opens on the same card.
func select_game(game_id: StringName) -> void:
	if not VALID_GAMES.has(game_id) or game_id == selected_game:
		return
	selected_game = game_id
	save_local_setting(SELECTED_GAME_SETTING, SELECTED_GAME_KEY, String(game_id))
	selected_game_changed.emit(game_id)


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


# --- Backend wiring -----------------------------------------------------

## Phase 7: pull the authoritative balance from the server ledger and
## push it into CoinService. The client never computes or mutates the
## balance itself — this is the only path that feeds it after login.
func refresh_wallet() -> void:
	if not auth.is_authenticated():
		return
	var res: Dictionary = await auth.fetch_wallet()
	if res.ok:
		coins.set_balance_from_server(int(res.body.get("balance", 0)))


func _on_session_changed(session_user: Dictionary) -> void:
	user.apply_session_user(session_user)
	refresh_wallet()  # fire-and-forget: login screens don't block on it
	ads.refresh_config()  # fire-and-forget: server-driven ad config
	cosmetics.refresh()  # fire-and-forget: inventory for the new session
	analytics.on_session_changed(session_user)  # guest-conversion + flush


func _on_signed_out() -> void:
	user.apply_signed_out()
	coins.set_balance_from_server(0)  # never leak the previous account's balance
	ads.clear_config()
	cosmetics.clear()  # never leak the previous account's inventory


## Phase 8: a server-VALIDATED rewarded ad moved coins — re-read the
## authoritative balance instead of trusting the grant payload.
func _on_reward_granted(_tier: String, _coins: int) -> void:
	refresh_wallet()


func _on_reachability(reachable: bool) -> void:
	if reachable:
		network.set_online()
		analytics.flush()  # retry any events queued while offline
	else:
		network.set_offline()

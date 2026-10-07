class_name AdService
extends RefCounted
## Phase 8: rewarded + interstitial orchestration.
##
## The backend mints every ad opportunity (POST /ads/rewarded/session)
## and validates every reward BEFORE coins move (POST /ads/rewarded/
## redeem). This service only asks the provider to present, then relays
## the result — a client-side "ad finished" callback never grants
## anything by itself, and the server response alone reports the tier
## amount and new balance.

signal reward_granted(tier: String, coins: int)
signal reward_failed(reason: String)

const CONFIG_PATH := "/ads/config"
const SESSION_PATH := "/ads/rewarded/session"
const REDEEM_PATH := "/ads/rewarded/redeem"
const ELIGIBILITY_PATH := "/ads/interstitial/eligibility"
const SHOWN_PATH := "/ads/interstitial/shown"

var _auth: AuthService
var _provider: AdProvider
var _config: Dictionary = {}
var _requesting := false


func _init(auth_service: AuthService, provider: AdProvider = null) -> void:
	_auth = auth_service
	_provider = provider if provider != null else StubAdProvider.new()
	_provider.rewarded_completed.connect(_on_rewarded_completed)
	_provider.rewarded_failed.connect(_on_provider_rewarded_failed)
	_provider.interstitial_completed.connect(_on_interstitial_completed)
	_provider.interstitial_failed.connect(_on_interstitial_failed)


## Server-driven ad configuration (provider, unit IDs, frequency rules).
## The client hardcodes none of it — see GET /ads/config.
func config() -> Dictionary:
	return _config


func refresh_config() -> Dictionary:
	var res: Dictionary = await _auth.authenticated_get(CONFIG_PATH)
	if res.ok and res.body is Dictionary:
		_config = res.body
	return res


func clear_config() -> void:
	_config = {}


## Rewarded flow, steps 1-2: ask the SERVER for an ad opportunity, then
## present it through the active provider. Returns false when the
## session could not be minted (nothing was shown, nothing can pay).
func request_rewarded(tier: String = "BONUS") -> bool:
	if _requesting:
		return false
	if not _auth.is_authenticated():
		reward_failed.emit("Not signed in.")
		return false
	_requesting = true
	var res: Dictionary = await _auth.authenticated_post(SESSION_PATH, {"tier": tier})
	if not res.ok:
		_requesting = false
		reward_failed.emit(str(res.get("message", "Could not start the ad.")))
		return false
	_provider.show_rewarded(res.body)
	return true


## Rewarded flow, steps 3-4: the provider finished — redeem the nonce
## server-side. Only a validated response emits reward_granted, with
## the amounts the SERVER computed.
func _on_rewarded_completed(session: Dictionary) -> void:
	var nonce := str(session.get("nonce", ""))
	var res: Dictionary = await _auth.authenticated_post(REDEEM_PATH, {"nonce": nonce})
	_requesting = false
	if res.ok:
		reward_granted.emit(str(res.body.get("tier", "")),
				int(res.body.get("coins", 0)))
	else:
		reward_failed.emit(str(res.get("message", "Reward validation failed.")))


func _on_provider_rewarded_failed(reason: String) -> void:
	_requesting = false
	reward_failed.emit(reason)


## After a (finished) match: ask the server whether an interstitial is
## due under ITS frequency rules; present only when it says yes. The
## server never hears about a match that is still in progress.
func check_interstitial(match_id: String = "") -> void:
	if not _auth.is_authenticated():
		return
	var res: Dictionary = await _auth.authenticated_get(ELIGIBILITY_PATH)
	if not res.ok or not res.body is Dictionary:
		return
	if not bool(res.body.get("eligible", false)):
		return
	_provider.show_interstitial({
		"matchId": match_id,
		"reason": str(res.body.get("reason", "")),
	})


## The provider finished the interstitial — record the show so the
## server-side cooldown ("never after every match") takes effect.
func _on_interstitial_completed(context: Dictionary) -> void:
	await _auth.authenticated_post(SHOWN_PATH, {"matchId": str(context.get("matchId", ""))})


func _on_interstitial_failed(_reason: String) -> void:
	pass  # nothing shown, nothing to record

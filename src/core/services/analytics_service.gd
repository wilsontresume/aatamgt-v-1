class_name AnalyticsService
extends RefCounted
## Privacy-conscious product analytics.
##
## Every event carries a random client-minted installId (stored in
## local settings, never derived from hardware), a per-launch sessionId
## and a coarse OS bucket — never emails, usernames, IPs or device
## fingerprints. Batches go to POST /analytics/events when signed in
## and POST /analytics/anonymous before login. The server ignores
## anything outside an allow-list, and the player can opt out entirely
## (Settings → Share usage data); opting out drops the queue and stops
## collection immediately.

const EVENTS_PATH := "/analytics/events"
const ANONYMOUS_PATH := "/analytics/anonymous"
const SETTINGS_SECTION := "analytics"
const KEY_ENABLED := "enabled"
const KEY_INSTALL_ID := "install_id"
const KEY_INSTALL_REPORTED := "install_reported"
const KEY_LAUNCH_REPORTED := "first_launch_reported"
const FLUSH_AT := 10
const MAX_QUEUE := 40
const DEDUPE_INSTALL := "install"
const DEDUPE_FIRST_LAUNCH := "first_launch"

var _api: ApiClient
var _auth: AuthService
var _get_setting: Callable
var _save_setting: Callable
var _app_version := ""
var _install_id := ""
var _session_id := ""
var _session_started_ms := 0
var _queue: Array[Dictionary] = []
var _flushing := false
var _was_guest := false


## Settings accessors are injected (not reached via the App autoload)
## to keep this service free of a compile-time cycle: App constructs
## AnalyticsService, so the service must never name App at parse time.
func _init(api: ApiClient, auth: AuthService, get_setting: Callable,
		save_setting: Callable, app_version: String) -> void:
	_api = api
	_auth = auth
	_get_setting = get_setting
	_save_setting = save_setting
	_app_version = app_version


## Called once from App.bootstrap(): loads or mints the installId,
## starts the session and reports install/first_launch exactly once.
func start_session() -> void:
	_install_id = str(_get_setting.call(SETTINGS_SECTION, KEY_INSTALL_ID, ""))
	if _install_id.is_empty():
		_install_id = _make_uuid()
		_save_setting.call(SETTINGS_SECTION, KEY_INSTALL_ID, _install_id)
	_session_id = _make_uuid()
	_session_started_ms = Time.get_ticks_msec()
	if not is_enabled():
		return
	if not bool(_get_setting.call(SETTINGS_SECTION, KEY_INSTALL_REPORTED, false)):
		track(DEDUPE_INSTALL, {}, "", DEDUPE_INSTALL)
		_save_setting.call(SETTINGS_SECTION, KEY_INSTALL_REPORTED, true)
	if not bool(_get_setting.call(SETTINGS_SECTION, KEY_LAUNCH_REPORTED, false)):
		track(DEDUPE_FIRST_LAUNCH, {}, "", DEDUPE_FIRST_LAUNCH)
		_save_setting.call(SETTINGS_SECTION, KEY_LAUNCH_REPORTED, true)
	track("session_start")
	flush()


## Called on quit/pause: closes the session with its duration and
## pushes whatever is still queued.
func end_session() -> void:
	if not is_enabled() or _session_started_ms == 0:
		return
	var seconds := int(round((Time.get_ticks_msec() - _session_started_ms) / 1000.0))
	track("session_end", {"durationSeconds": seconds})
	flush()
	_session_started_ms = 0


func is_enabled() -> bool:
	return bool(_get_setting.call(SETTINGS_SECTION, KEY_ENABLED, true))


func set_enabled(enabled: bool) -> void:
	_save_setting.call(SETTINGS_SECTION, KEY_ENABLED, enabled)
	if not enabled:
		_queue.clear()
	elif _session_started_ms == 0:
		# Re-enabling mid-run starts a fresh session rather than backfilling.
		start_session()


## Queues one event. `dedupe_key` lets the server drop replays of
## exactly-once events (install, first launch).
func track(type: String, data: Dictionary = {}, game_key: String = "",
		dedupe_key: String = "") -> void:
	if not is_enabled():
		return
	if _queue.size() >= MAX_QUEUE:
		_queue.pop_front()  # shed oldest under abuse; metrics tolerate loss
	var event := {
		"type": type,
		"sessionId": _session_id,
	}
	if not game_key.is_empty():
		event["gameKey"] = game_key
	if not data.is_empty():
		event["data"] = data
	if not dedupe_key.is_empty():
		event["dedupeKey"] = dedupe_key
	_queue.append(event)
	if _queue.size() >= FLUSH_AT:
		flush()


## Guest session replaced by a registered account on this install.
func note_account_upgraded() -> void:
	_was_guest = false
	track("guest_conversion")


## Marks the previous session kind; called by App on every session change
## so an upgrade can be detected without storing any identity linkage.
func note_session_user(user: Dictionary) -> void:
	_was_guest = bool(user.get("is_guest", false))


## Sends the queue (auth-aware) and clears it on success. Failures keep
## events for a later attempt — analytics must never block the game.
func flush() -> void:
	if _flushing or _queue.is_empty() or not is_enabled():
		return
	if not _api.is_reachable():
		return
	_flushing = true
	var batch := _queue.duplicate()
	var payload := _payload_for(batch)
	var res: Dictionary
	if _auth.is_authenticated():
		res = await _auth.authenticated_post(EVENTS_PATH, payload)
	else:
		res = await _api.request_json(HTTPClient.METHOD_POST, ANONYMOUS_PATH, payload)
	_flushing = false
	if res.ok:
		return  # batch acknowledged; anything re-queued meanwhile stays
	# Transport/server failure: put the batch back for the next flush.
	for index in range(batch.size() - 1, -1, -1):
		_queue.push_front(batch[index])


## Guest → registered upgrade on the same install, detected by App.
func on_session_changed(user: Dictionary) -> void:
	var upgraded := _was_guest and not bool(user.get("is_guest", false))
	note_session_user(user)
	if upgraded:
		note_account_upgraded()
	flush()


func _payload_for(batch: Array[Dictionary]) -> Dictionary:
	return {
		"events": batch,
		"installId": _install_id,
		"platform": _platform_bucket(),
		"version": _app_version,
	}


## Coarse OS family only — enough for release health, useless as a
## fingerprint.
func _platform_bucket() -> String:
	var os_name := OS.get_name().to_lower()
	if os_name.contains("android"):
		return "android"
	if os_name.contains("ios") or os_name.contains("iphone") or os_name.contains("ipad"):
		return "ios"
	if os_name.contains("windows"):
		return "windows"
	if os_name.contains("mac"):
		return "macos"
	if os_name.contains("linux") or os_name.contains("x11"):
		return "linux"
	return "other"


## Random UUIDv4 from the cryptographic RNG — not derived from any
## device identifier.
func _make_uuid() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [
		hex.substr(0, 8),
		hex.substr(8, 4),
		hex.substr(12, 4),
		hex.substr(16, 4),
		hex.substr(20, 12),
	]

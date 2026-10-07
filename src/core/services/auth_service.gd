class_name AuthService
extends RefCounted
## Owns the authenticated session: guest sign-in, registration, login,
## logout, token refresh, and restoring a stored session on next launch.
##
## Persistence contract (Phase 3 security rules):
##  - Only tokens + a small public user summary are written to
##    user://session.json. Passwords are passed as arguments, sent once,
##    and NEVER stored on disk.
##  - All traffic goes through ApiClient, which enforces HTTPS.

signal session_changed(user: Dictionary)
signal signed_out
signal restore_completed(ok: bool)

const SESSION_PATH := "user://session.json"

## Keys persisted per user (explicit allow-list — never dump the raw
## server payload, which may contain more than we want on disk).
const USER_FIELDS := ["id", "username", "is_guest", "display_name"]

var _api: ApiClient
var _session: Dictionary = {}
var _busy := false

## Last failure, for screens that want to read state without matching
## on the returned dictionary.
var last_error: int = ApiClient.ErrorKind.NONE
var last_message := ""


func _init(api: ApiClient) -> void:
	_api = api


# --- State -------------------------------------------------------------

func is_authenticated() -> bool:
	return not str(_session.get("access_token", "")).is_empty() \
			and not str(_session.get("refresh_token", "")).is_empty()


func is_busy() -> bool:
	return _busy


func get_user() -> Dictionary:
	var user: Variant = _session.get("user", {})
	return user.duplicate(true) if user is Dictionary else {}


func get_username() -> String:
	return str(get_user().get("username", ""))


func get_player_id() -> String:
	return str(get_user().get("id", ""))


func is_guest() -> bool:
	return bool(get_user().get("is_guest", false))


func get_access_token() -> String:
	return str(_session.get("access_token", ""))


# --- Persistence -------------------------------------------------------

func has_stored_session() -> bool:
	return FileAccess.file_exists(SESSION_PATH)


func load_stored_session() -> bool:
	if not has_stored_session():
		return false
	var file := FileAccess.open(SESSION_PATH, FileAccess.READ)
	if file == null:
		return false
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary) or (parsed as Dictionary).is_empty():
		clear_session()
		return false
	_session = parsed
	return true


func save_session() -> void:
	var file := FileAccess.open(SESSION_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("AuthService: could not write %s" % SESSION_PATH)
		return
	file.store_string(JSON.stringify(_session, "\t"))
	file.close()


func clear_session(persist: bool = true) -> void:
	_session = {}
	if persist and has_stored_session():
		var dir := DirAccess.open("user://")
		if dir != null:
			dir.remove("session.json")


# --- Flows (each awaits the network) ----------------------------------

## Server-generated throwaway account. No password is chosen or stored
## locally — the backend hashes one and returns only tokens.
func guest_login() -> Dictionary:
	if not _guard():
		return _busy_error()
	_busy = true
	var res: Dictionary = await _api.request_json(HTTPClient.METHOD_POST, "/auth/guest")
	_busy = false
	return await _finish_auth(res)


func login(identifier: String, password: String) -> Dictionary:
	if not _guard():
		return _busy_error()
	_busy = true
	var res: Dictionary = await _api.request_json(HTTPClient.METHOD_POST, "/auth/login", {
		"identifier": identifier,
		"password": password,
	})
	_busy = false
	var result := await _finish_auth(res)
	if not result.ok and result.status == 401:
		result = _fail(ApiClient.ErrorKind.INVALID_CREDENTIALS,
				str(result.get("message", "")), result.status)
	return result


func register(username: String, password: String) -> Dictionary:
	if not _guard():
		return _busy_error()
	_busy = true
	var res: Dictionary = await _api.request_json(HTTPClient.METHOD_POST, "/auth/register", {
		"username": username,
		"password": password,
	})
	_busy = false
	var result := await _finish_auth(res)
	if not result.ok and result.status == 401:
		result = _fail(ApiClient.ErrorKind.INVALID_CREDENTIALS,
				str(result.get("message", "")), result.status)
	return result


## Revokes the refresh token server-side when possible, then always
## clears the local session (signing out must work offline).
func logout() -> Dictionary:
	var refresh := str(_session.get("refresh_token", ""))
	var token := get_access_token()
	if not refresh.is_empty():
		var res: Dictionary = await _api.request_json(HTTPClient.METHOD_POST,
				"/auth/logout", {"refreshToken": refresh}, token)
		last_error = res.error_kind
		last_message = str(res.get("message", ""))
	clear_session()
	signed_out.emit()
	return _ok(200, {})


## Restores a previously stored session on launch: refresh tokens, then
## re-fetch the user. A dead refresh token wipes the session; a merely
## unreachable server keeps it for a later retry.
func restore_session() -> Dictionary:
	if not _guard():
		return _busy_error()
	if not load_stored_session():
		restore_completed.emit(false)
		return _fail(ApiClient.ErrorKind.EXPIRED_SESSION, "No stored session.", 0)

	_busy = true
	if not await _refresh_tokens():
		_busy = false
		if last_error in [ApiClient.ErrorKind.NETWORK, ApiClient.ErrorKind.SERVER_UNAVAILABLE]:
			# Unreachable backend must not sign the player out.
			restore_completed.emit(false)
			return _fail(last_error, last_message, 0)
		_expire()
		return _fail(ApiClient.ErrorKind.EXPIRED_SESSION,
				ApiClient.error_text(ApiClient.ErrorKind.EXPIRED_SESSION), 401)

	var res: Dictionary = await authenticated_get("/users/me")
	_busy = false
	if not res.ok:
		if res.error_kind in [ApiClient.ErrorKind.NETWORK, ApiClient.ErrorKind.SERVER_UNAVAILABLE]:
			# Keep tokens: offline launch must not sign the player out.
			restore_completed.emit(false)
			return res
		_expire()
		return _fail(res.error_kind, str(res.get("message", "")), res.status)

	var user := _public_user(res.body)
	_session["user"] = user
	save_session()
	var merged := await _with_profile(user)
	session_changed.emit(merged)
	restore_completed.emit(true)
	return _ok(res.status, {"user": merged})


## Authenticated GET with automatic one-shot refresh on 401. A 401 that
## survives the refresh wipes the session and reports EXPIRED_SESSION.
func authenticated_get(path: String) -> Dictionary:
	if not is_authenticated():
		return _fail(ApiClient.ErrorKind.EXPIRED_SESSION,
				ApiClient.error_text(ApiClient.ErrorKind.EXPIRED_SESSION), 401)

	var res: Dictionary = await _api.request_json(HTTPClient.METHOD_GET, path, {},
			get_access_token())
	if res.status == 401:
		if await _refresh_tokens():
			res = await _api.request_json(HTTPClient.METHOD_GET, path, {},
					get_access_token())
		elif last_error in [ApiClient.ErrorKind.NETWORK, ApiClient.ErrorKind.SERVER_UNAVAILABLE]:
			return _fail(last_error, last_message, 0)
		if res.status == 401:
			_expire()
			return _fail(ApiClient.ErrorKind.EXPIRED_SESSION,
					ApiClient.error_text(ApiClient.ErrorKind.EXPIRED_SESSION), 401)
	# Surface transport failures unchanged (screens show their own text).
	last_error = res.error_kind
	last_message = str(res.get("message", ""))
	return res


## Authenticated POST with the same one-shot refresh contract as
## authenticated_get. Used for server-side grants (Phase 7 rewards).
func authenticated_post(path: String, payload: Dictionary) -> Dictionary:
	if not is_authenticated():
		return _fail(ApiClient.ErrorKind.EXPIRED_SESSION,
				ApiClient.error_text(ApiClient.ErrorKind.EXPIRED_SESSION), 401)

	var res: Dictionary = await _api.request_json(HTTPClient.METHOD_POST, path,
			payload, get_access_token())
	if res.status == 401:
		if await _refresh_tokens():
			res = await _api.request_json(HTTPClient.METHOD_POST, path, payload,
					get_access_token())
		elif last_error in [ApiClient.ErrorKind.NETWORK, ApiClient.ErrorKind.SERVER_UNAVAILABLE]:
			return _fail(last_error, last_message, 0)
		if res.status == 401:
			_expire()
			return _fail(ApiClient.ErrorKind.EXPIRED_SESSION,
					ApiClient.error_text(ApiClient.ErrorKind.EXPIRED_SESSION), 401)
	last_error = res.error_kind
	last_message = str(res.get("message", ""))
	return res


## Phase 7: reads the authoritative wallet (GET /wallet). The response
## body carries {currency, balance, version} — the caller feeds `balance`
## into CoinService.set_balance_from_server; nothing here mints coins.
func fetch_wallet() -> Dictionary:
	return await authenticated_get("/wallet")


# ----------------------------------------------------------------------

## Stores tokens from a successful auth response and emits
## session_changed with the merged (profile-enriched) user.
func _finish_auth(res: Dictionary) -> Dictionary:
	if not res.ok:
		last_error = res.error_kind
		last_message = str(res.get("message", ""))
		return res

	var body: Dictionary = res.body
	var user := _public_user(body.get("user", {}))
	if user.is_empty():
		return _fail(ApiClient.ErrorKind.UNKNOWN, "Server returned no user.", res.status)

	_session = {
		"access_token": str(body.get("accessToken", "")),
		"refresh_token": str(body.get("refreshToken", "")),
		"expires_in": int(body.get("expiresIn", 0)),
		"user": user,
	}
	save_session()

	var merged := await _with_profile(user)
	last_error = ApiClient.ErrorKind.NONE
	last_message = ""
	session_changed.emit(merged)
	return _ok(res.status, {"user": merged})


## Best-effort profile fetch (display name, level, stats) — auth itself
## still succeeds if this secondary call fails.
func _with_profile(user: Dictionary) -> Dictionary:
	var res: Dictionary = await authenticated_get("/profiles/me")
	if res.ok:
		var body: Dictionary = res.body
		var fallback := str(user.get("display_name", user.get("username", "")))
		user["display_name"] = str(body.get("displayName",
				body.get("display_name", fallback)))
		if body.has("level"):
			user["level"] = int(body["level"])
		if body.has("xp"):
			user["xp"] = int(body["xp"])
		var stats: Variant = body.get("stats", {})
		if stats is Dictionary:
			user["stats"] = {
				"matches": int((stats as Dictionary).get("gamesPlayed", 0)),
				"wins": int((stats as Dictionary).get("wins", 0)),
				"losses": int((stats as Dictionary).get("losses", 0)),
			}
		_session["user"] = user
		save_session()
	return user.duplicate(true)


func _refresh_tokens() -> bool:
	var refresh := str(_session.get("refresh_token", ""))
	if refresh.is_empty():
		return false
	var res: Dictionary = await _api.request_json(HTTPClient.METHOD_POST, "/auth/refresh", {
		"refreshToken": refresh,
	})
	if not res.ok:
		last_error = res.error_kind
		last_message = str(res.get("message", ""))
		return false
	_session["access_token"] = str(res.body.get("accessToken", ""))
	_session["refresh_token"] = str(res.body.get("refreshToken", refresh))
	_session["expires_in"] = int(res.body.get("expiresIn", 0))
	save_session()
	return true


func _expire() -> void:
	clear_session()
	signed_out.emit()


## Allow-listed copy of a server user, normalized from the API's
## camelCase field names to the client's snake_case convention.
func _public_user(raw: Variant) -> Dictionary:
	var out := {}
	if not (raw is Dictionary):
		return out
	var source := raw as Dictionary
	for field in USER_FIELDS:
		if source.has(field):
			out[field] = source[field]
	if source.has("isGuest"):
		out["is_guest"] = bool(source["isGuest"])
	if source.has("displayName"):
		out["display_name"] = str(source["displayName"])
	return out


func _guard() -> bool:
	return not _busy


func _busy_error() -> Dictionary:
	return _fail(ApiClient.ErrorKind.UNKNOWN, "Another account request is already running.", 0)


func _ok(status: int, body: Dictionary) -> Dictionary:
	return {
		"ok": true,
		"status": status,
		"error_kind": ApiClient.ErrorKind.NONE,
		"message": "",
		"body": body,
		"user": body.get("user", {}),
	}


func _fail(kind: int, message: String, status: int) -> Dictionary:
	last_error = kind
	last_message = message
	return {
		"ok": false,
		"status": status,
		"error_kind": kind,
		"message": message,
		"body": {},
		"user": {},
	}

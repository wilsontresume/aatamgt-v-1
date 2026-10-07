extends SceneTree
## Phase 3 end-to-end authentication test against a live backend.
##
## Run through scripts/run_phase3_e2e.sh, which boots the HTTPS server
## and exports:
##   AATAMGT_API_URL  e.g. https://127.0.0.1:3443  (HTTPS enforced)
##   AATAMGT_CA_CERT  path to the server's dev certificate
##
## Exit code 0 = all checks passed.

const SESSION_PATH := "user://session.json"

var _checks := 0
var _failures := 0
var _started := false
var _app: Node = null
var _base_url := ""


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run()
	return false


func _run() -> void:
	await _frame()

	_app = get_root().get_node_or_null("/root/App")
	_check(_app != null, "autoload App is registered")
	if _app == null:
		_finish()
		return

	_base_url = OS.get_environment("AATAMGT_API_URL").strip_edges()
	_check(not _base_url.is_empty(), "AATAMGT_API_URL is provided")
	_check(BackendConfig.validate_url(_base_url) != "", "configured URL passes the HTTPS policy")
	_check(_app.api_client.is_configured(), "api client configured from environment")
	_check(_app.api_client.get_base_url() == BackendConfig.validate_url(_base_url),
			"api client uses the normalized URL")
	await _check_server_reachable()
	if _failures > 0:
		# Without a live backend nothing below can pass — bail early.
		_finish()
		return

	await _test_url_policy()
	await _test_guest_login()
	await _test_registration_and_login()
	await _test_token_refresh_and_expiry()
	await _test_unreachable_server()
	await _test_splash_restore()

	_finish()


# --- Sections ----------------------------------------------------------

## Pure policy checks — no network involved.
func _test_url_policy() -> void:
	_check(not _app.api_client.configure("http://evil.example.com"),
			"ApiClient rejects plain http on a public host")
	_check(not _app.api_client.configure("ftp://api.example.com"),
			"ApiClient rejects non-http schemes")
	_check(_app.api_client.configure("http://127.0.0.1:3443"),
			"ApiClient allows loopback http for development")
	_check(_app.api_client.configure(_base_url), "api client restored to the real backend")
	_check(_app.api_client.configure(_base_url, OS.get_environment("AATAMGT_CA_CERT")),
			"api client keeps the CA certificate")


func _test_guest_login() -> void:
	var result: Dictionary = await _app.auth.guest_login()
	_check(result.ok, "guest login succeeds (%s)" % _msg(result))
	if not result.ok:
		return

	var user: Dictionary = result.user
	_check(str(user.get("username", "")).begins_with("guest_"),
			"server assigns a guest_* username (%s)" % str(user.get("username", "")))
	_check(bool(user.get("is_guest", false)), "user is flagged as a guest")
	_check(not str(user.get("id", "")).is_empty(), "unique player id assigned")
	_check(_app.auth.is_authenticated(), "session marked authenticated")
	_check(_app.auth.is_guest(), "auth service reports guest session")
	_check(_app.user.get_player_id() == str(user.get("id", "")),
			"user service mirrors the backend player id")
	_check(_app.network.get_status() == NetworkService.Status.CONNECTED,
			"network reports online after a successful call")

	_check(FileAccess.file_exists(SESSION_PATH), "session file written")
	var raw := _read_session()
	_check(raw.containsn("access_token") and raw.containsn("refresh_token"),
			"session file stores both tokens")
	_check(not raw.containsn("password"), "no password material in the session file")
	_check(not raw.containsn("passwordHash"), "no password hash in the session file")

	# Duplicate username: registering the guest's username must fail.
	var dup: Dictionary = await _app.auth.register(str(user.get("username", "")),
			"Password123!")
	_check(not dup.ok and dup.error_kind == ApiClient.ErrorKind.DUPLICATE_USERNAME,
			"duplicate username maps to DUPLICATE_USERNAME (got %s)" % _kind(dup))
	_check(_app.auth.is_authenticated(), "failed registration leaves the session intact")


func _test_registration_and_login() -> void:
	var username := "e2e_%d" % (Time.get_ticks_msec() % 100000000)
	var password := "E2ePassw0rd!"

	var registered: Dictionary = await _app.auth.register(username, password)
	_check(registered.ok, "register succeeds (%s)" % _msg(registered))
	if not registered.ok:
		return
	_check(_app.auth.get_username() == username, "session username matches registration")
	_check(not _app.auth.is_guest(), "registered account is not a guest")
	var player_id: String = _app.auth.get_player_id()
	_check(not player_id.is_empty(), "registered account has a player id")

	var me: Dictionary = await _app.auth.authenticated_get("/users/me")
	_check(me.ok and str(me.body.get("id", "")) == player_id,
			"player id matches /users/me (%s)" % _msg(me))
	var profile: Dictionary = await _app.auth.authenticated_get("/profiles/me")
	_check(profile.ok and str(profile.body.get("username", "")) == username,
			"profile endpoint returns the username (%s)" % _msg(profile))

	var signed_out: Dictionary = await _app.auth.logout()
	_check(signed_out.ok and not _app.auth.is_authenticated(), "logout clears the session")
	_check(not FileAccess.file_exists(SESSION_PATH), "logout deletes the session file")
	_check(_app.user.is_guest() and _app.user.get_player_id().is_empty(),
			"user service falls back to the guest placeholder")

	var bad: Dictionary = await _app.auth.login(username, "wrong-password")
	_check(not bad.ok and bad.error_kind == ApiClient.ErrorKind.INVALID_CREDENTIALS,
			"wrong password maps to INVALID_CREDENTIALS (got %s)" % _kind(bad))

	var good: Dictionary = await _app.auth.login(username, password)
	_check(good.ok, "login with correct credentials succeeds (%s)" % _msg(good))
	_check(_app.auth.get_player_id() == player_id, "player id is stable across sessions")
	_check(not _read_session().containsn("password"),
			"login persists no password material")


func _test_token_refresh_and_expiry() -> void:
	# A garbage access token with a valid refresh token must self-heal.
	_write_session_field("access_token", "garbage-access-token")
	_check(_app.auth.load_stored_session(), "session reloads from disk")
	var recovered: Dictionary = await _app.auth.authenticated_get("/users/me")
	_check(recovered.ok, "expired access token is refreshed transparently (%s)" % _msg(recovered))
	_check(not _read_session().containsn("garbage-access-token"),
			"refreshed access token was persisted")

	# A dead refresh token must end the session cleanly (both tokens are
	# invalidated so the 401 path is actually exercised).
	_write_session_field("access_token", "garbage-access-token")
	_write_session_field("refresh_token", "garbage-refresh-token")
	_check(_app.auth.load_stored_session(), "tampered session reloads from disk")
	var expired: Dictionary = await _app.auth.authenticated_get("/users/me")
	_check(not expired.ok and expired.error_kind == ApiClient.ErrorKind.EXPIRED_SESSION,
			"dead refresh token maps to EXPIRED_SESSION (got %s)" % _kind(expired))
	_check(not _app.auth.is_authenticated(), "expired session is cleared in memory")
	_check(not FileAccess.file_exists(SESSION_PATH), "expired session file removed")
	_check(_app.user.is_guest() and _app.user.get_player_id().is_empty(),
			"expiry falls back to the guest placeholder")
	_check(_app.network.get_status() == NetworkService.Status.CONNECTED,
			"server was reachable even though the session expired")


func _test_unreachable_server() -> void:
	# Re-establish a real session, then take the backend away.
	_base_url = OS.get_environment("AATAMGT_API_URL").strip_edges()
	_app.api_client.configure(_base_url, OS.get_environment("AATAMGT_CA_CERT"))

	var username := "e2e_%d" % (Time.get_ticks_msec() % 100000000)
	var password := "E2ePassw0rd!"
	var registered: Dictionary = await _app.auth.register(username, password)
	_check(registered.ok, "register succeeds for the offline checks (%s)" % _msg(registered))
	if not registered.ok:
		return

	_app.api_client.configure("http://127.0.0.1:9", OS.get_environment("AATAMGT_CA_CERT"))
	var offline_restore: Dictionary = await _app.auth.restore_session()
	_check(not offline_restore.ok and offline_restore.error_kind == ApiClient.ErrorKind.SERVER_UNAVAILABLE,
			"unreachable backend maps to SERVER_UNAVAILABLE (got %s)" % _kind(offline_restore))
	_check(_app.auth.is_authenticated(), "unreachable backend keeps the stored session")
	_check(FileAccess.file_exists(SESSION_PATH), "stored session survives an offline launch")
	_check(_app.network.get_status() == NetworkService.Status.OFFLINE,
			"network reports offline after transport failures")

	# DNS failures are classified as NETWORK, not SERVER_UNAVAILABLE.
	_app.api_client.configure("https://does-not-exist.invalid")
	var dns_failure: Dictionary = await _app.auth.guest_login()
	_check(not dns_failure.ok and dns_failure.error_kind == ApiClient.ErrorKind.NETWORK,
			"DNS failure maps to NETWORK (got %s)" % _kind(dns_failure))

	# Back online: the kept session restores successfully.
	_app.api_client.configure(_base_url, OS.get_environment("AATAMGT_CA_CERT"))
	var restored: Dictionary = await _app.auth.restore_session()
	_check(restored.ok, "session restores once the backend is back (%s)" % _msg(restored))
	_check(_app.auth.get_username() == username, "restored session belongs to the same user")
	_check(not _read_session().containsn("password"), "restored session stores no password")


## Boots the real main scene: the splash screen must restore the stored
## session within its deadline and the profile must show the player id.
func _test_splash_restore() -> void:
	var player_id: String = _app.auth.get_player_id()
	_check(FileAccess.file_exists(SESSION_PATH), "session stored before the cold start")

	var main: Node = load("res://scenes/main.tscn").instantiate()
	get_root().add_child(main)
	await create_timer(0.3).timeout
	_check(_app.navigation.current == &"splash", "scene boots into the splash screen")
	await create_timer(5.0).timeout
	_check(_app.navigation.current == &"main_menu",
			"splash restores and hands off to the main menu (got %s)" % _app.navigation.current)
	_check(_app.auth.is_authenticated() and _app.auth.get_player_id() == player_id,
			"restored session keeps the same player id")
	_check(_app.user.get_player_id() == player_id, "profile screen data has the player id")

	_app.navigation.go(&"profile")
	await create_timer(0.5).timeout
	var container: Control = main.get_node("ScreenLayer/ScreenContainer")
	var profile_screen: Control = null
	for child in container.get_children():
		if child.name == "Profile":
			profile_screen = child
	var id_label: Label = profile_screen.get_node_or_null(
			"Margin/Content/AccountPanel/AccountBody/PlayerIdLabel") \
			if profile_screen != null else null
	_check(id_label != null and id_label.text.contains(player_id),
			"profile screen shows the player id")
	var type_label: Label = profile_screen.get_node_or_null(
			"Margin/Content/AccountPanel/AccountBody/AccountTypeLabel") \
			if profile_screen != null else null
	_check(type_label != null and type_label.text.begins_with("Registered"),
			"account card shows registered account (%s)" % (type_label.text if type_label else "missing"))
	main.queue_free()
	await _frame()


# --- Helpers -----------------------------------------------------------

func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		printerr("FAIL: ", label)


func _check_server_reachable() -> void:
	# A bare API call (no session): any HTTP response — including 401 —
	# proves TLS handshake and routing work; only transport kinds do not.
	var res: Dictionary = await _app.api_client.request_json(HTTPClient.METHOD_GET,
			"/profiles/me")
	var transport_failure: bool = (res.error_kind == ApiClient.ErrorKind.NETWORK
			or res.error_kind == ApiClient.ErrorKind.SERVER_UNAVAILABLE)
	_check(not transport_failure, "backend reachable over HTTPS (%s)" % _msg(res))
	_check(_app.network.get_status() == NetworkService.Status.CONNECTED,
			"reachability feeds the network service")


func _msg(result: Dictionary) -> String:
	if result.ok:
		return "ok"
	return "%s (status %d): %s" % [_kind(result), int(result.get("status", 0)),
			str(result.get("message", ""))]


func _kind(result: Dictionary) -> String:
	return ApiClient.ErrorKind.keys()[int(result.get("error_kind", ApiClient.ErrorKind.UNKNOWN))]


func _read_session() -> String:
	var file := FileAccess.open(SESSION_PATH, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text


func _write_session_field(key: String, value: String) -> void:
	var file := FileAccess.open(SESSION_PATH, FileAccess.READ)
	if file == null:
		return
	var data: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (data is Dictionary):
		return
	(data as Dictionary)[key] = value
	file = FileAccess.open(SESSION_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()


func _frame() -> void:
	await process_frame


func _finish() -> void:
	print("E2E: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)

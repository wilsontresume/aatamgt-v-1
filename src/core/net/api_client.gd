class_name ApiClient
extends Node
## Thin HTTPS JSON client for the AATAMGT backend.
##
## Wraps one HTTPRequest per call, translates transport/HTTP failures
## into a stable ErrorKind vocabulary that screens and services share,
## and reports reachability so NetworkService can reflect reality.
##
## Security notes:
##  - Plain HTTP is rejected by BackendConfig before any request leaves
##    the device (loopback development excepted).
##  - The client never persists anything to disk; tokens are owned by
##    AuthService.

signal reachability_changed(reachable: bool)

enum ErrorKind {
	NONE,
	NETWORK,               # DNS / TLS / transport failure
	SERVER_UNAVAILABLE,    # connection refused, timeout, 5xx
	INVALID_CREDENTIALS,   # bad username/password
	DUPLICATE_USERNAME,    # username already taken
	EXPIRED_SESSION,       # 401 with no usable session
	VALIDATION,            # 400 request rejected by the server
	RATE_LIMITED,          # 429
	NOT_FOUND,             # 404
	UNKNOWN,
}

const API_PREFIX := "/api/v1"
const TIMEOUT_SECONDS := 6.0

var _base_url := ""
var _ca_cert_path := ""
var _reachable := false


func configure(base_url: String, ca_cert_path: String = "") -> bool:
	var normalized := BackendConfig.validate_url(base_url)
	if normalized.is_empty():
		push_warning("ApiClient: rejected backend URL '%s' (HTTPS required)" % base_url)
		return false
	_base_url = normalized
	_ca_cert_path = ca_cert_path
	return true


func get_base_url() -> String:
	return _base_url


func get_ca_cert_path() -> String:
	return _ca_cert_path


func is_configured() -> bool:
	return not _base_url.is_empty()


func is_reachable() -> bool:
	return _reachable


## Performs a JSON request against `path` (e.g. "/auth/guest") and
## returns {ok, status, error_kind, message, body}. Awaiting.
func request_json(method: int, path: String, body: Dictionary = {},
		access_token: String = "") -> Dictionary:
	if _base_url.is_empty():
		return _result(false, 0, ErrorKind.SERVER_UNAVAILABLE, {},
				"The backend is not configured. Set %s." % BackendConfig.ENV_BASE_URL)

	var http := HTTPRequest.new()
	http.timeout = TIMEOUT_SECONDS
	_apply_tls(http)
	add_child(http)

	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: application/json",
	])
	if not access_token.is_empty():
		headers.append("Authorization: Bearer %s" % access_token)

	var payload := "" if method == HTTPClient.METHOD_GET else JSON.stringify(body)
	var url := _base_url + API_PREFIX + path
	var start_error := http.request(url, headers, method, payload)
	if start_error != OK:
		http.queue_free()
		_set_reachable(false)
		return _result(false, 0, ErrorKind.NETWORK, {},
				"Could not start the request (error %d)." % start_error)

	var response: Array = await http.request_completed
	http.queue_free()

	var transport_result: int = response[0]
	var status: int = response[1]
	var raw: PackedByteArray = response[3]

	if transport_result != HTTPRequest.RESULT_SUCCESS:
		_set_reachable(false)
		var kind := _map_transport(transport_result)
		return _result(false, 0, kind, {}, _transport_message(kind))

	_set_reachable(true)
	var parsed := _parse_json(raw)
	var message := _message_of(parsed)
	if message.is_empty():
		message = _default_message(status)
	return _result(status >= 200 and status < 300, status, _map_http(status), parsed, message)


## Human-readable fallback for a given error kind (server messages win
## when present).
static func error_text(kind: ErrorKind) -> String:
	match kind:
		ErrorKind.NONE:
			return ""
		ErrorKind.NETWORK:
			return "Network error. Check your connection and try again."
		ErrorKind.SERVER_UNAVAILABLE:
			return "The server is unavailable right now. Please try again later."
		ErrorKind.INVALID_CREDENTIALS:
			return "Incorrect username or password."
		ErrorKind.DUPLICATE_USERNAME:
			return "That username is already taken."
		ErrorKind.EXPIRED_SESSION:
			return "Your session has expired. Please sign in again."
		ErrorKind.VALIDATION:
			return "Please check your details and try again."
		ErrorKind.RATE_LIMITED:
			return "Too many attempts. Please wait a moment and try again."
		ErrorKind.NOT_FOUND:
			return "That could not be found on the server."
		_:
			return "Something went wrong. Please try again."


# ----------------------------------------------------------------------

func _apply_tls(http: HTTPRequest) -> void:
	if _ca_cert_path.is_empty():
		return
	var cert := X509Certificate.new()
	if cert.load(_ca_cert_path) == OK:
		http.set_tls_options(TLSOptions.client(cert))
	else:
		push_warning("ApiClient: could not load CA certificate at %s" % _ca_cert_path)


func _map_transport(result: int) -> ErrorKind:
	match result:
		HTTPRequest.RESULT_CANT_RESOLVE, HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return ErrorKind.NETWORK
		HTTPRequest.RESULT_TIMEOUT, HTTPRequest.RESULT_CANT_CONNECT, \
				HTTPRequest.RESULT_CONNECTION_ERROR:
			return ErrorKind.SERVER_UNAVAILABLE
		_:
			return ErrorKind.NETWORK


func _map_http(status: int) -> ErrorKind:
	match status:
		400:
			return ErrorKind.VALIDATION
		401:
			return ErrorKind.EXPIRED_SESSION
		404:
			return ErrorKind.NOT_FOUND
		409:
			return ErrorKind.DUPLICATE_USERNAME
		429:
			return ErrorKind.RATE_LIMITED
		_:
			if status >= 500:
				return ErrorKind.SERVER_UNAVAILABLE
			return ErrorKind.UNKNOWN if status >= 400 else ErrorKind.NONE


func _transport_message(kind: ErrorKind) -> String:
	return error_text(kind)


func _default_message(status: int) -> String:
	if status >= 500:
		return error_text(ErrorKind.SERVER_UNAVAILABLE)
	if status >= 400:
		return "The server rejected the request (%d)." % status
	return ""


func _parse_json(raw: PackedByteArray) -> Dictionary:
	if raw.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}


## NestJS validation errors arrive as a message array.
func _message_of(body: Dictionary) -> String:
	var message: Variant = body.get("message", "")
	if message is String:
		return message
	if message is Array:
		return " ".join(message.map(func(entry: Variant) -> String: return str(entry)))
	return ""


func _set_reachable(value: bool) -> void:
	if _reachable == value:
		return
	_reachable = value
	reachability_changed.emit(value)


func _result(ok: bool, status: int, kind: ErrorKind, body: Dictionary,
		message: String) -> Dictionary:
	return {
		"ok": ok,
		"status": status,
		"error_kind": kind,
		"message": message,
		"body": body,
	}

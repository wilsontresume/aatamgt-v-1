class_name SocketIoClient
extends Node
## Minimal Engine.IO v4 + Socket.IO v4 client (WebSocket transport only)
## for the AATAMGT realtime gateway.
##
## Protocol (verified against the live NestJS server):
##  - wss://host/socket.io/?EIO=4&transport=websocket
##  - server open `0{...}` -> client namespace connect `40/ws,{"token":<jwt>}`
##  - engine ping `2` -> client pong `3` (Engine.IO v4: server pings)
##  - events `42/ws,["name",payload]`, with ack `42/ws,<id>["name",payload]`
##  - acks `43/ws,<id>[<result>]`
##
## The client never interprets match payloads: everything above the
## transport belongs to OnlineMatchService / the screen.

signal connected                     # namespace CONNECT ack received
signal disconnected(reason: String)
signal event_received(event: String, payload: Variant)


## One in-flight emitWithAck. `resolved` fires exactly once — either
## with the server's ack payload or with a local failure envelope.
class AckWaiter:
	extends RefCounted
	signal resolved(payload: Variant)
	var settled := false

	func finish(payload: Variant) -> void:
		if settled:
			return
		settled = true
		resolved.emit(payload)


const NAMESPACE := "/ws"
const ENGINE_OPEN := 48    # '0'
const ENGINE_CLOSE := 49   # '1'
const ENGINE_PING := 50    # '2'
const ENGINE_PONG := 51    # '3'
const ENGINE_MESSAGE := 52 # '4'

enum State { IDLE, CONNECTING, READY, CLOSED }

var _ws: WebSocketPeer = null
var _state: int = State.IDLE
var _ack_counter := 0
var _pending: Dictionary = {}   # int ack id -> AckWaiter
var _token := ""
var _last_error := ""


func is_ready() -> bool:
	return _state == State.READY and _ws != null \
			and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN


func get_last_error() -> String:
	return _last_error


## Opens the WebSocket transport against a configured backend URL.
## Returns OK once the socket attempt has started; await wait_ready()
## for the authenticated namespace handshake.
func connect_socket(base_url: String, token: String, ca_cert_path: String = "") -> Error:
	_close_quietly()
	_token = token
	_last_error = ""
	_state = State.CONNECTING
	_ws = WebSocketPeer.new()
	var tls: TLSOptions = null
	if not ca_cert_path.is_empty():
		var cert := X509Certificate.new()
		if cert.load(ca_cert_path) == OK:
			tls = TLSOptions.client(cert)
		else:
			push_warning("SocketIoClient: could not load CA certificate at %s"
					% ca_cert_path)
	var err := _ws.connect_to_url(socket_url(base_url), tls)
	if err != OK:
		_ws = null
		_state = State.CLOSED
		_last_error = "Could not open the WebSocket (error %d)." % err
		return err
	return OK


## Polls until the namespace handshake completes. Returns false when
## the transport failed or the timeout elapsed.
func wait_ready(timeout_sec: float = 8.0) -> bool:
	var loop := Engine.get_main_loop() as SceneTree
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if _state == State.READY:
			return true
		if _state == State.CLOSED:
			return false
		if loop != null:
			await loop.create_timer(0.05).timeout
		else:
			return is_ready()
	return _state == State.READY


## Fire-and-forget event (no acknowledgement).
func emit_event(event: String, payload: Dictionary) -> bool:
	return _send("42%s,%s" % [NAMESPACE, JSON.stringify([event, payload])])


## Emits an event and awaits the server's acknowledgement. The result
## is the ack payload as a Dictionary — servers return {ok, ...} either
## way, and local failures use the same shape with a transport error.
func emit_with_ack(event: String, payload: Dictionary,
		timeout_sec: float = 6.0) -> Dictionary:
	if not is_ready():
		return {"ok": false, "error": _last_error if not _last_error.is_empty()
				else "Not connected"}
	_ack_counter += 1
	var ack_id := _ack_counter
	var waiter := AckWaiter.new()
	_pending[ack_id] = waiter
	var packet := "42%s,%d%s" % [NAMESPACE, ack_id, JSON.stringify([event, payload])]
	if not _send(packet):
		_pending.erase(ack_id)
		return {"ok": false, "error": "Could not send the request"}
	var loop := Engine.get_main_loop() as SceneTree
	if loop != null:
		var timer := loop.create_timer(timeout_sec)
		timer.timeout.connect(func() -> void:
			waiter.finish({"ok": false, "error": "The server timed out",
					"timed_out": true}))
	var result: Variant = await waiter.resolved
	_pending.erase(ack_id)
	if result is Dictionary:
		return result
	return {"ok": false, "error": "Unexpected acknowledgement payload"}


## Closes the transport. Pending acks fail immediately; a previously
## READY socket reports the disconnect so services can react (retry or
## surface the loss to the UI).
func close(reason: String = "closed by client") -> void:
	if _ws == null:
		_state = State.CLOSED
		return
	var notify := _state == State.READY
	_ws.close()
	_ws = null
	_teardown(reason, notify)


## Closes without emitting `disconnected` — used when a new transport
## immediately supersedes the old one.
func _close_quietly() -> void:
	if _ws == null:
		if _state == State.READY:
			_state = State.CLOSED
		return
	_ws.close()
	_ws = null
	_teardown("superseded", false)


# ----------------------------------------------------------------------

func _process(_delta: float) -> void:
	if _ws == null:
		return
	var ws := _ws
	ws.poll()
	match ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			while ws.get_available_packet_count() > 0:
				var packet := ws.get_packet()
				_handle_text(packet.get_string_from_utf8())
				if _ws != ws:
					return  # a packet handler closed the transport
		WebSocketPeer.STATE_CLOSING:
			pass  # let the close handshake finish
		WebSocketPeer.STATE_CLOSED:
			var reason := "Connection closed"
			if _state == State.CONNECTING:
				reason = "Could not reach the realtime server"
				_last_error = reason
			_teardown(reason, true)


func _handle_text(text: String) -> void:
	if text.is_empty():
		return
	var kind := text.unicode_at(0)
	var body := text.substr(1)
	match kind:
		ENGINE_OPEN:
			# {"sid":...,"pingInterval":...,"pingTimeout":...}
			_send("40%s,%s" % [NAMESPACE, JSON.stringify({"token": _token})])
		ENGINE_PING:
			_send("3")  # Engine.IO v4: client answers pings
		ENGINE_CLOSE:
			_teardown("Server closed the connection", true)
		ENGINE_MESSAGE:
			_handle_socket_packet(body)
		_:
			pass  # pong/noop/upgrade: nothing to do


func _handle_socket_packet(body: String) -> void:
	if body.is_empty():
		return
	var packet_type := body.unicode_at(0) - 48
	var rest := body.substr(1)
	# Namespace (the gateway lives on /ws).
	var packet_ns := NAMESPACE
	if not rest.is_empty() and rest.unicode_at(0) == 47:  # '/'
		var comma := rest.find(",")
		if comma < 0:
			return
		packet_ns = rest.substr(0, comma)
		rest = rest.substr(comma + 1)
	# Optional acknowledgement id (digits directly before the payload).
	var ack_id := -1
	var digits := 0
	while digits < rest.length() and rest.unicode_at(digits) >= 48 \
			and rest.unicode_at(digits) <= 57:
		digits += 1
	if digits > 0:
		ack_id = int(rest.substr(0, digits))
		rest = rest.substr(digits)
	var data: Variant = null
	if not rest.is_empty():
		data = JSON.parse_string(rest)

	match packet_type:
		0:  # CONNECT acknowledgement
			if packet_ns == NAMESPACE and _state == State.CONNECTING:
				_state = State.READY
				connected.emit()
		1:  # DISCONNECT
			_teardown("Server ended the session", true)
		2:  # EVENT
			if data is Array and (data as Array).size() > 0:
				var items := data as Array
				var event_name := str(items[0])
				var payload: Variant = items[1] if items.size() > 1 else {}
				if event_name == "error":
					_last_error = _error_text(payload)
				event_received.emit(event_name, payload)
		3:  # ACK
			if ack_id >= 0 and _pending.has(ack_id):
				var waiter: AckWaiter = _pending[ack_id]
				_pending.erase(ack_id)
				var result: Variant = {"ok": false,
						"error": "Empty acknowledgement"}
				if data is Array:
					var items := data as Array
					if items.size() == 1:
						result = items[0]
					elif items.size() > 1:
						result = items
				waiter.finish(result)
		4:  # CONNECT_ERROR
			_last_error = _error_text(data)
			_teardown(_last_error, true)
		_:
			pass


func _send(text: String) -> bool:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	return _ws.send_text(text) == OK


func _teardown(reason: String, emit_signal: bool) -> void:
	var was := _state
	_state = State.CLOSED
	_ws = null
	for ack_id in _pending.keys():
		(_pending[ack_id] as AckWaiter).finish({"ok": false,
				"error": reason, "closed": true})
	_pending.clear()
	if was == State.IDLE:
		return
	if emit_signal:
		disconnected.emit(reason)


static func socket_url(base_url: String) -> String:
	var url := BackendConfig.normalize(base_url)
	if url.begins_with("https://"):
		url = "wss://" + url.substr(8)
	elif url.begins_with("http://"):
		url = "ws://" + url.substr(7)
	return url + "/socket.io/?EIO=4&transport=websocket"


static func _error_text(payload: Variant) -> String:
	if payload is Dictionary:
		var d := payload as Dictionary
		if d.has("reason"):
			return str(d["reason"])
		if d.has("message"):
			return str(d["message"])
		return JSON.stringify(d)
	return str(payload)

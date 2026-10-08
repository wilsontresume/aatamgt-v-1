class_name OnlineMatchService
extends Node
## Authoritative online match session (Phase 6), shared by every game
## screen: set_game_key() points the one service at the game being
## played — the session itself (REST lifecycle + WebSocket) is never
## duplicated per game.
##
## Contract: the server decides everything — legality, turn order,
## results, rating, coins. This service only moves bytes: REST for
## match lifecycle (create/join/list), WebSocket for the live session
## (subscribe/move/resign/rematch + broadcasts). Engine state written
## here always comes FROM the server; nothing is computed locally.

signal connection_changed(connected: bool)
signal match_changed                      # subscription or seat switched
signal state_applied                      # authoritative engine state advanced
signal move_received(data: Dictionary)    # an accepted move (mine or theirs)
signal match_completed(data: Dictionary)  # server-decided completion, once
signal presence_updated(data: Dictionary)
signal rematch_available(new_match_id: String)

## Game keys as published by the server catalog.
const AADU_PULI_KEY := "aadu-puli-aattam"
const SOLAH_SEEDI_KEY := "solah-seedi"
const NINE_MENS_MORRIS_KEY := "nine-mens-morris"
const DEFAULT_GAME_KEY := AADU_PULI_KEY
const ACK_TIMEOUT := 6.0

## The game this session is currently pointed at (see set_game_key).
var game_key := DEFAULT_GAME_KEY

var api: ApiClient
var auth: AuthService
var socket: SocketIoClient

# --- Session state (server truth) ---------------------------------------
var match_id := ""
var match_status := ""          # PENDING / ACTIVE / COMPLETED / ...
var seat := -1                  # 0 = goats, 1 = tigers
var side := ""                  # "goats" / "tigers"
var state_version := 0
var move_count := 0             # accepted moves in this match
var state_dict: Dictionary = {} # serialized engine state from the server
var turn_deadline := 0.0        # unix seconds
var completion: Dictionary = {} # {reason, winnerSeat, results}
var presence: Dictionary = {}   # userId -> bool
var last_notation := ""
var connected := false
var reconnecting := false

var _wants_connection := false
var _opening := false
var _announced_match := ""      # match ids whose completion was emitted
## Phase 11: set by the challenge flow; the next game screen consumes
## this in _ready() and enters online mode by itself (the accepted
## match is already waiting on the server).
var auto_enter_online := false


func _init(p_api: ApiClient = null, p_auth: AuthService = null) -> void:
	api = p_api
	auth = p_auth


## Points the session at another game: any live session of the previous
## game is dropped first (the server keeps the match; it can be
## resumed under its own key later). No-op when the key is unchanged.
func set_game_key(key: String) -> void:
	if game_key == key:
		return
	if not match_id.is_empty() or _wants_connection:
		leave()
	game_key = key


## Phase 11: the game screen should boot straight into online mode
## (challenge accepted / rematch pending). One-shot: consumed on read.
func request_auto_online() -> void:
	auto_enter_online = true


func consume_auto_online() -> bool:
	var wanted := auto_enter_online
	auto_enter_online = false
	return wanted


func _enter_tree() -> void:
	_ensure_socket()


# --- Connection ----------------------------------------------------------

func is_connected_to_server() -> bool:
	return socket != null and socket.is_ready()


func is_active() -> bool:
	return match_status == "ACTIVE" and not state_dict.is_empty()


func is_my_turn() -> bool:
	if not is_active():
		return false
	# Engines own their serialization: solah-seedi and aadu-puli use
	# "side_to_move", nine-mens-morris uses "to_move" (spec §9).
	var mover := str(state_dict.get("side_to_move", ""))
	if mover.is_empty():
		mover = str(state_dict.get("to_move", ""))
	return mover == side


func my_user_id() -> String:
	return auth.get_player_id() if auth != null else ""


func opponent_connected() -> bool:
	for user_id in presence:
		if str(user_id) != my_user_id():
			return bool(presence[user_id])
	return true


func turn_seconds_left() -> int:
	if turn_deadline <= 0.0:
		return 0
	return maxi(0, int(ceil(turn_deadline - Time.get_unix_time_from_system())))


## Opens the authenticated WebSocket and waits for the handshake.
func connect_service(timeout_sec: float = 8.0) -> Dictionary:
	_ensure_socket()
	_wants_connection = true
	if socket.is_ready():
		if not connected:
			connected = true
			connection_changed.emit(true)
		return {"ok": true}
	if auth == null or not auth.is_authenticated():
		return {"ok": false, "error": "Sign in to play online."}
	if api == null or not api.is_configured():
		return {"ok": false, "error": "The backend is not configured."}
	_opening = true
	var err := socket.connect_socket(api.get_base_url(), auth.get_access_token(),
			api.get_ca_cert_path())
	if err != OK:
		_opening = false
		return {"ok": false, "error": "Could not reach the realtime server."}
	var ok := await socket.wait_ready(timeout_sec)
	_opening = false
	if not ok:
		_set_disconnected()
		var failure := socket.get_last_error()
		return {"ok": false, "error": failure if not failure.is_empty() \
				else "Could not connect."}
	return {"ok": true}


## Simulates a dropped transport while keeping the session intent, so
## the automatic reconnect (and server disconnect grace) can run.
func drop_connection() -> void:
	if socket != null:
		socket.close("connection lost")


## Full teardown: stops retries, closes the socket, forget the match.
func leave() -> void:
	_wants_connection = false
	reconnecting = false
	if socket != null:
		socket.close("left online mode")
	_clear_match()
	_set_disconnected()


# --- Match lifecycle (REST) ----------------------------------------------

## Server-generated match id; the creator waits in PENDING.
func create_match() -> Dictionary:
	var res: Dictionary = await api.request_json(HTTPClient.METHOD_POST,
			"/matches", {"gameKey": game_key}, auth.get_access_token())
	if not res.ok:
		return _rest_fail(res)
	var body: Dictionary = res.body
	match_id = str(body.get("id", ""))
	match_status = str(body.get("status", "PENDING"))
	state_dict = {}
	completion = {}
	if match_id.is_empty():
		return {"ok": false, "error": "The server returned no match."}
	return {"ok": true, "match_id": match_id, "status": match_status}


func join_match(target_id: String) -> Dictionary:
	var res: Dictionary = await api.request_json(HTTPClient.METHOD_POST,
			"/matches/%s/join" % target_id, {}, auth.get_access_token())
	if not res.ok:
		return _rest_fail(res)
	var body: Dictionary = res.body
	match_id = str(body.get("id", target_id))
	match_status = str(body.get("status", ""))
	completion = {}
	return {"ok": true, "match_id": match_id, "status": match_status,
			"server_state": body.get("serverState", {})}


## Most recent resumable match of mine (PENDING or ACTIVE), for
## reconnection after a relaunch or mode switch.
func find_resumable_match() -> Dictionary:
	var res: Dictionary = await api.request_json(HTTPClient.METHOD_GET,
			"/matches", {}, auth.get_access_token())
	if not res.ok:
		return _rest_fail(res)
	var items: Variant = res.body.get("items", [])
	if items is Array:
		for entry in items as Array:
			if not (entry is Dictionary):
				continue
			var m := entry as Dictionary
			if str(m.get("gameKey", "")) != game_key:
				continue
			var status := str(m.get("status", ""))
			if status == "PENDING" or status == "ACTIVE":
				return {"ok": true, "match_id": str(m.get("id", "")),
						"status": status}
	return {"ok": true, "match_id": "", "status": ""}


# --- Live session (WebSocket) ---------------------------------------------

## Subscribes to a match: seat, side, full state, history and presence.
func subscribe_match(target_id: String) -> Dictionary:
	if not is_connected_to_server():
		return {"ok": false, "error": "Not connected."}
	var ack: Dictionary = await socket.emit_with_ack("match:subscribe",
			{"matchId": target_id}, ACK_TIMEOUT)
	if not ack.ok:
		return ack
	match_id = str(ack.get("matchId", target_id))
	match_status = str(ack.get("status", ""))
	seat = int(ack.get("seat", -1))
	side = str(ack.get("side", ""))
	state_version = int(ack.get("stateVersion", 0))
	var server_state: Variant = ack.get("serverState")
	if server_state is Dictionary:
		_apply_server_state(server_state as Dictionary)
	var moves: Variant = ack.get("moves", [])
	move_count = (moves as Array).size() if moves is Array else 0
	var snap_presence: Variant = ack.get("presence", {})
	presence = (snap_presence as Dictionary).duplicate() if \
			snap_presence is Dictionary else {}
	match_changed.emit()
	state_applied.emit()
	return {"ok": true, "seat": seat, "side": side, "status": match_status,
			"state_version": state_version}


## Submits one move payload. clientSeq guards duplicates/staleness; the
## server rejects anything out of order or illegal with {ok:false,error}.
func submit_move(payload: Dictionary, target_match: String = "",
		seq_override: int = -1) -> Dictionary:
	var mid := target_match if not target_match.is_empty() else match_id
	if mid.is_empty():
		return {"ok": false, "error": "No match is active."}
	if not is_connected_to_server():
		return {"ok": false, "error": "Not connected."}
	var body := {"matchId": mid, "payload": payload}
	if not target_match.is_empty() and seq_override < 0:
		pass  # foreign match: no local sequence knowledge
	elif seq_override >= 0:
		body["clientSeq"] = seq_override
	else:
		body["clientSeq"] = move_count + 1
	var ack: Dictionary = await socket.emit_with_ack("match:move", body,
			ACK_TIMEOUT)
	if not ack.ok:
		return ack
	if mid == match_id:
		_accept_move_ack(ack)
	return ack


func resign() -> Dictionary:
	if match_id.is_empty():
		return {"ok": false, "error": "No match is active."}
	if not is_connected_to_server():
		return {"ok": false, "error": "Not connected."}
	var ack: Dictionary = await socket.emit_with_ack("match:resign",
			{"matchId": match_id}, ACK_TIMEOUT)
	if not ack.ok:
		return ack
	match_status = "COMPLETED"
	_announce_completion_once(ack, match_id)
	return ack


## New server match with swapped seats; the service subscribes to it.
func rematch() -> Dictionary:
	if match_id.is_empty():
		return {"ok": false, "error": "No match is active."}
	if not is_connected_to_server():
		return {"ok": false, "error": "Not connected."}
	var old_id := match_id
	var ack: Dictionary = await socket.emit_with_ack("match:rematch",
			{"matchId": old_id}, ACK_TIMEOUT)
	if not ack.ok:
		return ack
	var new_id := str(ack.get("matchId", ""))
	if new_id.is_empty():
		return {"ok": false, "error": "The server returned no rematch."}
	# The rematch broadcast may already have switched us to the new
	# match — subscribe either way so seat/side/state are fresh.
	match_id = new_id
	completion = {}
	var sub: Dictionary = await subscribe_match(new_id)
	if not sub.ok:
		return sub
	return {"ok": true, "match_id": new_id, "seat": seat, "side": side}


## Test/QA helper: submit without the local sequence guard (stale or
## duplicate clientSeq on purpose).
func submit_raw(payload: Dictionary, client_seq: int,
		target_match: String = "") -> Dictionary:
	var mid := target_match if not target_match.is_empty() else match_id
	if not is_connected_to_server():
		return {"ok": false, "error": "Not connected."}
	return await socket.emit_with_ack("match:move",
			{"matchId": mid, "payload": payload, "clientSeq": client_seq},
			ACK_TIMEOUT)


# --- Broadcasts ----------------------------------------------------------

func _on_event(event: String, payload: Variant) -> void:
	if not (payload is Dictionary):
		return
	var data := payload as Dictionary
	match event:
		"match:moved":
			if str(data.get("matchId", "")) != match_id:
				return
			_accept_move(data)
		"match:status":
			if str(data.get("matchId", "")) != match_id:
				return
			_accept_status(data)
		"match:presence":
			if str(data.get("matchId", "")) != match_id:
				return
			presence[str(data.get("userId", ""))] = bool(data.get("connected", false))
			presence_updated.emit(data)
		"match:rematch":
			# Only meaningful while the OLD match is still ours.
			if str(data.get("matchId", "")) != match_id:
				return
			var new_id := str(data.get("newMatchId", ""))
			if new_id.is_empty():
				return
			match_id = new_id
			completion = {}
			rematch_available.emit(new_id)
			# Fire-and-forget: restore the full snapshot for the new match.
			subscribe_match(new_id)
		_:
			pass


func _accept_move(data: Dictionary) -> void:
	var seq := int(data.get("seq", 0))
	var version := int(data.get("stateVersion", 0))
	if seq <= move_count and version <= state_version:
		return  # already applied (my own ack usually lands first/second)
	if data.has("state") and data["state"] is Dictionary:
		state_dict = data["state"]
	state_version = maxi(state_version, version)
	move_count = maxi(move_count, seq)
	_take_deadline(data)
	if data.has("notation"):
		last_notation = str(data["notation"])
	move_received.emit(data)
	state_applied.emit()


func _accept_move_ack(ack: Dictionary) -> void:
	var move: Variant = ack.get("move")
	var seq := int((move as Dictionary).get("seq", 0)) if move is Dictionary else 0
	var already_applied := seq > 0 and seq <= move_count
	if ack.has("state") and ack["state"] is Dictionary:
		state_dict = ack["state"]
	state_version = maxi(state_version, int(ack.get("stateVersion", 0)))
	move_count = maxi(maxi(move_count, state_version - 1), seq)
	_take_deadline(ack)
	if move is Dictionary and (move as Dictionary).has("notation"):
		last_notation = str((move as Dictionary)["notation"])
	if ack.has("completed"):
		match_status = "COMPLETED"
		_announce_completion_once(ack, match_id)
	if not already_applied:
		state_applied.emit()


func _accept_status(data: Dictionary) -> void:
	var status := str(data.get("status", ""))
	var was_pending := match_status == "PENDING"
	match_status = status
	if data.has("completed") and data["completed"] is Dictionary:
		completion = data["completed"]
	if status == "COMPLETED":
		_announce_completion_once(data, match_id)
	# A PENDING match just became ACTIVE: fetch the fresh snapshot.
	if status == "ACTIVE" and was_pending:
		subscribe_match(match_id)
	match_changed.emit()


func _announce_completion_once(data: Dictionary, for_match: String) -> void:
	if _announced_match == for_match:
		return
	var completed: Variant = data.get("completed", completion)
	if not (completed is Dictionary) or (completed as Dictionary).is_empty():
		return
	_announced_match = for_match
	completion = completed as Dictionary
	match_status = "COMPLETED"
	match_completed.emit({"matchId": for_match, "completed": completion,
			"status": "COMPLETED"})


func _apply_server_state(server_state: Dictionary) -> void:
	if server_state.has("state") and server_state["state"] is Dictionary:
		state_dict = server_state["state"]
		_take_deadline(server_state)
	var completed: Variant = server_state.get("completed")
	if completed is Dictionary:
		completion = completed
		_announced_match = match_id  # a resume must not re-announce an old result


func _take_deadline(source: Dictionary) -> void:
	var deadline := str(source.get("turnDeadlineAt", ""))
	if deadline.is_empty():
		return
	turn_deadline = _iso_to_unix(deadline)


# --- Internals -----------------------------------------------------------

func _on_socket_connected() -> void:
	if not connected:
		connected = true
		connection_changed.emit(true)


func _on_socket_disconnected(_reason: String) -> void:
	var was := connected
	_set_disconnected()
	if not _wants_connection or _opening or reconnecting:
		return
	_auto_reconnect()


func _set_disconnected() -> void:
	if not connected:
		return
	connected = false
	connection_changed.emit(false)


func _auto_reconnect() -> void:
	reconnecting = true
	var restore_match := match_id
	for attempt in 8:
		await _sleep(1.0)
		if not _wants_connection or is_connected_to_server():
			break
		_opening = true
		var r := await connect_service(6.0)
		_opening = false
		if r.ok:
			if not restore_match.is_empty() and match_id == restore_match:
				await subscribe_match(restore_match)
			break
	reconnecting = false
	connection_changed.emit(connected)


func _ensure_socket() -> void:
	if socket != null:
		return
	socket = SocketIoClient.new()
	socket.name = "SocketIoClient"
	add_child(socket)
	socket.connected.connect(_on_socket_connected)
	socket.disconnected.connect(_on_socket_disconnected)
	socket.event_received.connect(_on_event)


func _clear_match() -> void:
	match_id = ""
	match_status = ""
	seat = -1
	side = ""
	state_version = 0
	move_count = 0
	state_dict = {}
	turn_deadline = 0.0
	completion = {}
	presence = {}
	last_notation = ""


func _rest_fail(res: Dictionary) -> Dictionary:
	var message := str(res.get("message", ""))
	if message.is_empty():
		message = ApiClient.error_text(res.error_kind)
	return {"ok": false, "error": message, "status": int(res.get("status", 0))}


static func _iso_to_unix(iso: String) -> float:
	var clean := iso.strip_edges().trim_suffix("Z")
	var dot := clean.find(".")
	if dot >= 0:
		clean = clean.substr(0, dot)
	return Time.get_unix_time_from_datetime_string(clean)


func _sleep(seconds: float) -> void:
	var loop := Engine.get_main_loop() as SceneTree
	if loop != null:
		await loop.create_timer(seconds).timeout

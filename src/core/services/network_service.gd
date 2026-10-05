class_name NetworkService
extends RefCounted
## Placeholder network/connection status service (Phase 1).
## Phase 3 introduces the real WebSocket transport; this service then
## reports live connection state and reconnect attempts.

signal status_changed(status: Status)

enum Status {
	OFFLINE,
	CONNECTING,
	CONNECTED,
	ERROR,
}

var status: Status = Status.OFFLINE


func get_status() -> Status:
	return status


func get_status_label() -> String:
	match status:
		Status.OFFLINE:
			return "Offline"
		Status.CONNECTING:
			return "Connecting…"
		Status.CONNECTED:
			return "Online"
		_:
			return "Connection problem"


func set_offline() -> void:
	_set_status(Status.OFFLINE)


## Phase 1 placeholder: no transport exists yet, so this reports OFFLINE
## instead of pretending to connect.
func connect_to_server() -> void:
	_set_status(Status.OFFLINE)


func disconnect_from_server() -> void:
	_set_status(Status.OFFLINE)


func _set_status(next: Status) -> void:
	if status == next:
		return
	status = next
	status_changed.emit(status)

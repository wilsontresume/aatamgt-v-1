class_name GameSessionService
extends RefCounted
## Placeholder game session service (Phase 1).
## Holds the currently active match context once real gameplay arrives
## (Phase 3+). Phase 1 has no sessions and no gameplay.

signal session_changed(session: Dictionary)

var _session: Dictionary = {}


func has_session() -> bool:
	return not _session.is_empty()


func get_session() -> Dictionary:
	return _session.duplicate()


func get_current_game() -> StringName:
	return StringName(str(_session.get("game_id", "")))


## Phase 1: no gameplay exists. Returns false without side effects —
## never fabricates a session.
func start_session(_game_id: StringName, _mode: StringName = &"") -> bool:
	return false


func end_session() -> void:
	if _session.is_empty():
		return
	_session = {}
	session_changed.emit({})


# Phase 3 TODO: create sessions through the matchmaking service and keep
# the server-authoritative match snapshot here for presentation.

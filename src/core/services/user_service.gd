class_name UserService
extends RefCounted
## Placeholder user/profile service (Phase 1).
## Phase 2+ replaces the internals with backend-synced data
## (guest -> registered account, avatar upload, profile edits).

signal profile_changed(profile: Dictionary)

const PLACEHOLDER_NAME := "Guest Player"

var _profile: Dictionary = {}


## Idempotent local placeholder initialization.
func initialize_local_placeholder() -> void:
	if not _profile.is_empty():
		return
	_profile = {
		"id": "",  # assigned by backend in Phase 2
		"display_name": PLACEHOLDER_NAME,
		"is_guest": true,
		"avatar_text": PLACEHOLDER_NAME.left(1).to_upper(),
		"level": 1,
		"xp": 0,
		# Placeholder stats (display only; backend-computed from Phase 2).
		"stats": {"matches": 0, "wins": 0, "losses": 0},
	}
	profile_changed.emit(get_profile())


func is_initialized() -> bool:
	return not _profile.is_empty()


func get_profile() -> Dictionary:
	return _profile.duplicate(true)


func is_guest() -> bool:
	return bool(_profile.get("is_guest", true))


func get_display_name() -> String:
	return str(_profile.get("display_name", PLACEHOLDER_NAME))


func get_avatar_text() -> String:
	return str(_profile.get("avatar_text", "?"))


func get_level() -> int:
	return int(_profile.get("level", 1))


func get_stats() -> Dictionary:
	var stats = _profile.get("stats", {})
	return stats.duplicate() if stats is Dictionary else {}


# Phase 2 TODO: fetch profile from backend on login, subscribe to profile
# update events, and implement avatar upload + display-name editing.

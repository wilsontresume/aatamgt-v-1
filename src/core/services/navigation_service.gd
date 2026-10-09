class_name NavigationService
extends RefCounted
## Central screen navigation with a back stack.
## Scenes are referenced by path (not preload) to keep the dependency
## graph acyclic: services never point at scene files.

signal navigate_requested(screen_id: StringName, params: Dictionary)
signal screen_changed(screen_id: StringName)

const SCREEN_PATHS := {
	&"splash": "res://scenes/screens/splash_screen.tscn",
	&"main_menu": "res://scenes/screens/main_menu.tscn",
	&"game_selection": "res://scenes/screens/game_selection.tscn",
	&"profile": "res://scenes/screens/profile.tscn",
	&"settings": "res://scenes/screens/settings.tscn",
	&"auth": "res://scenes/screens/auth_screen.tscn",
	&"aadu_puli": "res://scenes/screens/aadu_puli.tscn",
	&"solah_seedi": "res://scenes/screens/solah_seedi.tscn",
	&"nine_mens_morris": "res://scenes/screens/nine_mens_morris.tscn",
	&"friends": "res://scenes/screens/friends.tscn",
	&"challenge": "res://scenes/screens/challenge.tscn",
	&"history": "res://scenes/screens/history.tscn",
	&"inventory": "res://scenes/screens/inventory.tscn",
	&"leaderboard": "res://scenes/screens/leaderboard.tscn",
	&"shop": "res://scenes/screens/shop.tscn",
}

## Reaching this screen resets the back stack (it is the hub).
const ROOT_SCREEN: StringName = &"main_menu"

var current: StringName = &""
var _history: Array[StringName] = []


func has_screen(screen_id: StringName) -> bool:
	return SCREEN_PATHS.has(screen_id)


func go(screen_id: StringName, params: Dictionary = {}) -> void:
	if not SCREEN_PATHS.has(screen_id):
		push_error("NavigationService: unknown screen '%s'" % screen_id)
		return
	if screen_id == current:
		return
	if screen_id == ROOT_SCREEN:
		_history.clear()
	elif current != &"":
		_history.push_back(current)
	current = screen_id
	navigate_requested.emit(screen_id, params)
	screen_changed.emit(screen_id)


## Returns true when a previous screen was restored.
func back() -> bool:
	if _history.is_empty():
		return false
	var previous: StringName = _history.pop_back()
	current = previous
	navigate_requested.emit(previous, {})
	screen_changed.emit(previous)
	return true


func can_go_back() -> bool:
	return not _history.is_empty()

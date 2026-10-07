extends Control
## Splash screen: initializes App, restores a stored session within a
## bounded deadline, then hands off to the main menu.

const MIN_SPLASH_SECONDS := 1.4
const RESTORE_DEADLINE_SECONDS := 3.0


func _ready() -> void:
	var timer := get_tree().create_timer(MIN_SPLASH_SECONDS)
	App.bootstrap()
	await timer.timeout
	if not is_inside_tree():
		return
	if App.auth.has_stored_session():
		await _restore_bounded()
	if not is_inside_tree():
		return
	App.navigation.go(&"main_menu")


## Restores the previous session but never blocks the menu for longer
## than the deadline (slow or unreachable backend must not trap the
## player on the splash screen).
func _restore_bounded() -> void:
	var finished := [false]
	App.auth.restore_completed.connect(
			func(_ok: bool) -> void: finished[0] = true, CONNECT_ONE_SHOT)
	App.auth.restore_session()  # runs in the background until completion
	var elapsed := 0.0
	while not finished[0] and elapsed < RESTORE_DEADLINE_SECONDS:
		await get_tree().create_timer(0.1).timeout
		elapsed += 0.1
		if not is_inside_tree():
			return

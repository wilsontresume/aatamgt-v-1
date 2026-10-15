extends Control
## Splash screen: initializes App, restores a stored session within a
## bounded deadline, then hands off to the login screen or — only when
## a valid session exists — straight to the home menu.

const MIN_SPLASH_SECONDS := 1.4
const RESTORE_DEADLINE_SECONDS := 3.0


func _ready() -> void:
	var timer := get_tree().create_timer(MIN_SPLASH_SECONDS)
	App.bootstrap()
	await timer.timeout
	if not is_inside_tree():
		return
	if App.auth.has_stored_session():
		if OS.is_debug_build():
			print("UI: splash restoring stored session")
		await _restore_bounded()
		if OS.is_debug_build():
			print("UI: splash restore finished (authenticated=%s)" %
					App.auth.is_authenticated())
	if not is_inside_tree():
		return
	# Login-first flow: home only after a real (restored) session. A
	# fresh install or an expired session lands on the welcome screen
	# with no back target (Back exits the app).
	if App.auth.is_authenticated():
		App.navigation.go(&"main_menu")
	else:
		App.navigation.go_no_back(&"auth")


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

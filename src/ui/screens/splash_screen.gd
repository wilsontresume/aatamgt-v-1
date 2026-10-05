extends Control
## Splash screen: initializes App (local Phase 1 bootstrap) and hands
## off to the main menu after a minimum splash time.

const MIN_SPLASH_SECONDS := 1.4


func _ready() -> void:
	var timer := get_tree().create_timer(MIN_SPLASH_SECONDS)
	App.bootstrap()
	await timer.timeout
	if not is_inside_tree():
		return
	App.navigation.go(&"main_menu")

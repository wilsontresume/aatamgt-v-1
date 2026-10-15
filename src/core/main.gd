extends Node
## Root application scene: hosts screens, applies the theme, and wires
## App.navigation to scene instantiation. Dialog layer sits above screens.

const MIN_SPLASH_SECONDS := 1.5

@onready var _screen_container: Control = $ScreenLayer/ScreenContainer
@onready var _background: Control = $ScreenLayer/ScreenContainer/Background
@onready var _dialog_root: Control = $DialogLayer/DialogRoot
@onready var _loading: Control = $DialogLayer/DialogRoot/LoadingCenter/LoadingIndicator
@onready var _error_dialog: Control = $DialogLayer/DialogRoot/ErrorDialog
@onready var _confirm_dialog: Control = $DialogLayer/DialogRoot/ConfirmDialog

var _current_screen: Control = null


func _ready() -> void:
	var theme := AppTheme.build()
	_screen_container.theme = theme
	_dialog_root.theme = theme

	App.dialog.bind(_loading, _error_dialog, _confirm_dialog)
	App.navigation.navigate_requested.connect(_on_navigate_requested)
	# Login-first flow: any session expiry (refresh dead, token revoked)
	# returns the player to the welcome screen — never leaves them on
	# home with a dead session.
	App.auth.signed_out.connect(_on_signed_out)
	App.navigation.go(&"splash")


func _on_signed_out() -> void:
	var current := App.navigation.current
	if current != &"auth" and current != &"splash" and current != &"":
		if OS.is_debug_build():
			print("UI: session ended -> navigate -> auth")
		App.navigation.go_no_back(&"auth")


func _notification(what: int) -> void:
	# Android hardware back: mirror the in-app top-bar back (pop the
	# navigation stack); at the root screen, exit the app like the OS
	# back gesture expects.
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if not App.navigation.back():
			get_tree().quit()


func _on_navigate_requested(screen_id: StringName, params: Dictionary) -> void:
	if OS.is_debug_build():
		print("UI: navigate -> %s" % screen_id)
	var path: String = NavigationService.SCREEN_PATHS.get(screen_id, "")
	if path.is_empty():
		push_error("Main: no scene path for screen '%s'" % screen_id)
		return
	var scene: PackedScene = load(path)
	if scene == null:
		push_error("Main: could not load scene %s" % path)
		return
	var screen := scene.instantiate()
	# Screens that accept navigation params implement apply_params().
	# Called BEFORE add_child so _ready() sees them (game_entry needs
	# game_id before it loads tiers / wires buttons).
	if not params.is_empty() and screen.has_method("apply_params"):
		screen.call("apply_params", params)
	if _current_screen != null and is_instance_valid(_current_screen):
		_screen_container.remove_child(_current_screen)
		_current_screen.queue_free()
	_screen_container.add_child(screen)
	_current_screen = screen
	_fade_in(screen)


## Lightweight entrance fade (150 ms). Decorative only — never blocks
## input or delays navigation.
func _fade_in(screen: Control) -> void:
	screen.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(screen, "modulate:a", 1.0, 0.15)

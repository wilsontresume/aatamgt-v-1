extends Node
## Root application scene: hosts screens, applies the theme, and wires
## App.navigation to scene instantiation. Dialog layer sits above screens.

const MIN_SPLASH_SECONDS := 1.5

@onready var _screen_container: Control = $ScreenLayer/ScreenContainer
@onready var _background: ColorRect = $ScreenLayer/ScreenContainer/Background
@onready var _dialog_root: Control = $DialogLayer/DialogRoot
@onready var _loading: Control = $DialogLayer/DialogRoot/LoadingCenter/LoadingIndicator
@onready var _error_dialog: Control = $DialogLayer/DialogRoot/ErrorDialog
@onready var _confirm_dialog: Control = $DialogLayer/DialogRoot/ConfirmDialog

var _current_screen: Control = null


func _ready() -> void:
	var theme := AppTheme.build()
	_background.color = AppTheme.C_BG
	_screen_container.theme = theme
	_dialog_root.theme = theme

	App.dialog.bind(_loading, _error_dialog, _confirm_dialog)
	App.navigation.navigate_requested.connect(_on_navigate_requested)
	App.navigation.go(&"splash")


func _on_navigate_requested(screen_id: StringName, _params: Dictionary) -> void:
	var path: String = NavigationService.SCREEN_PATHS.get(screen_id, "")
	if path.is_empty():
		push_error("Main: no scene path for screen '%s'" % screen_id)
		return
	var scene: PackedScene = load(path)
	if scene == null:
		push_error("Main: could not load scene %s" % path)
		return
	var screen := scene.instantiate()
	if _current_screen != null and is_instance_valid(_current_screen):
		_screen_container.remove_child(_current_screen)
		_current_screen.queue_free()
	_screen_container.add_child(screen)
	_current_screen = screen

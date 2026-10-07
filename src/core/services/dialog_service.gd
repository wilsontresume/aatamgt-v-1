class_name DialogService
extends RefCounted
## Coordinates modal UI (loading overlay, error dialog, confirmation
## dialog). The dialogs themselves are bound by the main scene; screens
## only talk to this service.

signal confirm_resolved(result: bool)
## Phase 8: the error dialog dismissed (closed). Result dialogs use
## this as the "player acknowledged the outcome" moment — the point
## where an interstitial may be checked (never mid-game).
signal error_dismissed

var _loading: Node = null
var _error_dialog: Node = null
var _confirm_dialog: Node = null


## Called once by the main scene with its dialog instances.
func bind(loading: Node, error_dialog: Node, confirm_dialog: Node) -> void:
	_loading = loading
	_error_dialog = error_dialog
	_confirm_dialog = confirm_dialog
	if _confirm_dialog != null and _confirm_dialog.has_signal("confirmed") \
			and not _confirm_dialog.is_connected("confirmed", _on_confirm_confirmed):
		_confirm_dialog.connect("confirmed", _on_confirm_confirmed)
	if _error_dialog != null and _error_dialog.has_signal("dismissed") \
			and not _error_dialog.is_connected("dismissed", _on_error_dismissed):
		_error_dialog.connect("dismissed", _on_error_dismissed)


func is_bound() -> bool:
	return _error_dialog != null and _confirm_dialog != null


func show_loading(text: String = "Loading") -> void:
	if _loading == null:
		return
	if _loading.has_method("set_text"):
		_loading.call("set_text", text)
	_loading.visible = true


func hide_loading() -> void:
	if _loading != null:
		_loading.visible = false


## Args are title-first, matching confirm().
func show_error(title: String, message: String) -> void:
	if _error_dialog == null:
		push_error("DialogService: error dialog not bound — %s: %s" % [title, message])
		return
	_error_dialog.call("open", title, message)


## Usage: `var ok: bool = await App.dialog.confirm("Delete?", "…")`
func confirm(title: String, message: String, confirm_text: String = "Confirm",
		danger: bool = false) -> Signal:
	if _confirm_dialog == null:
		push_error("DialogService: confirm dialog not bound — %s" % title)
		call_deferred("_deferred_resolve_false")
		return confirm_resolved
	_confirm_dialog.call("configure", confirm_text, danger)
	_confirm_dialog.call("open", title, message)
	return confirm_resolved


func _deferred_resolve_false() -> void:
	confirm_resolved.emit(false)


func _on_confirm_confirmed(result: bool) -> void:
	confirm_resolved.emit(result)


func _on_error_dismissed() -> void:
	error_dismissed.emit()

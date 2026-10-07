extends Control
## Account screen: sign in, create an account, or continue as guest.
## All credential handling stays inside AuthService — this screen never
## touches tokens or writes anything to disk.

enum Mode { SIGN_IN, REGISTER }

const USERNAME_PATTERN := "^[a-zA-Z0-9_]{3,24}$"
const MIN_PASSWORD_LENGTH := 8

@onready var _heading: Label = $Margin/Content/AuthPanel/AuthBody/HeadingLabel
@onready var _subtitle: Label = $Margin/Content/AuthPanel/AuthBody/SubtitleLabel
@onready var _username_field: LineEdit = $Margin/Content/AuthPanel/AuthBody/UsernameField
@onready var _password_field: LineEdit = $Margin/Content/AuthPanel/AuthBody/PasswordField
@onready var _error_label: Label = $Margin/Content/AuthPanel/AuthBody/ErrorLabel
@onready var _submit_button: Button = $Margin/Content/AuthPanel/AuthBody/SubmitButton
@onready var _switch_button: Button = $Margin/Content/AuthPanel/AuthBody/SwitchButton
@onready var _guest_button: Button = $Margin/Content/AuthPanel/AuthBody/GuestButton

var _mode: int = Mode.SIGN_IN
var _busy := false
var _username_regex := RegEx.new()


func _ready() -> void:
	_username_regex.compile(USERNAME_PATTERN)
	_submit_button.pressed.connect(_on_submit)
	_switch_button.pressed.connect(_on_switch_mode)
	_guest_button.pressed.connect(_on_guest)
	_username_field.text_submitted.connect(_on_username_submitted)
	_password_field.text_submitted.connect(_on_password_submitted)
	_set_mode(Mode.SIGN_IN)
	_username_field.grab_focus.call_deferred()


func _on_username_submitted(_text: String) -> void:
	_password_field.grab_focus()


func _on_password_submitted(_text: String) -> void:
	_on_submit()


func _on_switch_mode() -> void:
	_hide_error()
	_set_mode(Mode.REGISTER if _mode == Mode.SIGN_IN else Mode.SIGN_IN)
	_username_field.grab_focus()


func _on_submit() -> void:
	if _busy:
		return
	var username := _username_field.text.strip_edges()
	var password := _password_field.text
	_hide_error()

	if username.is_empty() or password.is_empty():
		_show_inline("Enter your username and password to continue.")
		return
	if _mode == Mode.REGISTER:
		if _username_regex.search(username) == null:
			_show_inline("Usernames are 3-24 letters, numbers or underscores.")
			return
		if password.length() < MIN_PASSWORD_LENGTH:
			_show_inline("Passwords need at least %d characters." % MIN_PASSWORD_LENGTH)
			return

	var result: Dictionary
	_set_busy(true)
	if _mode == Mode.REGISTER:
		result = await App.auth.register(username, password)
	else:
		result = await App.auth.login(username, password)
	_set_busy(false)
	await _handle_result(result)


func _on_guest() -> void:
	if _busy:
		return
	_hide_error()
	_set_busy(true)
	var result: Dictionary = await App.auth.guest_login()
	_set_busy(false)
	await _handle_result(result)


func _handle_result(result: Dictionary) -> void:
	if result.ok:
		_password_field.clear()
		_leave()
		return

	var kind: int = result.error_kind
	var message := str(result.get("message", ""))
	if message.is_empty() or kind == ApiClient.ErrorKind.NETWORK \
			or kind == ApiClient.ErrorKind.SERVER_UNAVAILABLE:
		message = ApiClient.error_text(kind)

	if kind in [ApiClient.ErrorKind.NETWORK, ApiClient.ErrorKind.SERVER_UNAVAILABLE,
			ApiClient.ErrorKind.RATE_LIMITED, ApiClient.ErrorKind.UNKNOWN]:
		App.dialog.show_error(_title_for(kind), message)
	else:
		_show_inline(message)
	_password_field.clear()


func _leave() -> void:
	if App.navigation.can_go_back():
		App.navigation.back()
	else:
		App.navigation.go(App.navigation.ROOT_SCREEN)


func _set_mode(mode: int) -> void:
	_mode = mode
	if _mode == Mode.SIGN_IN:
		_heading.text = "Sign in"
		_subtitle.text = "Sign in to keep your progress across devices."
		_submit_button.text = "Sign in"
		_switch_button.text = "New here? Create an account"
	else:
		_heading.text = "Create account"
		_subtitle.text = "Pick a unique username — it becomes your player identity."
		_submit_button.text = "Create account"
		_switch_button.text = "I already have an account"


func _set_busy(busy: bool) -> void:
	_busy = busy
	_username_field.editable = not busy
	_password_field.editable = not busy
	_submit_button.disabled = busy
	_switch_button.disabled = busy
	_guest_button.disabled = busy


func _show_inline(message: String) -> void:
	_error_label.text = message
	_error_label.visible = true


func _hide_error() -> void:
	_error_label.text = ""
	_error_label.visible = false


func _title_for(kind: int) -> String:
	match kind:
		ApiClient.ErrorKind.INVALID_CREDENTIALS:
			return "Sign in failed"
		ApiClient.ErrorKind.DUPLICATE_USERNAME:
			return "Username taken"
		ApiClient.ErrorKind.NETWORK:
			return "Connection problem"
		ApiClient.ErrorKind.SERVER_UNAVAILABLE:
			return "Server unavailable"
		ApiClient.ErrorKind.RATE_LIMITED:
			return "Too many attempts"
		ApiClient.ErrorKind.EXPIRED_SESSION:
			return "Session expired"
		ApiClient.ErrorKind.VALIDATION:
			return "Check your details"
		_:
			return "Account"

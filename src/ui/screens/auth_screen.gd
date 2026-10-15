extends Control
## Login screen: sign in, create an account, or continue as guest —
## presented over a procedural daytime temple backdrop. All credential
## handling stays inside AuthService — this screen never touches tokens
## or writes anything to disk.

enum Mode { SIGN_IN, REGISTER }

const USERNAME_PATTERN := "^[a-zA-Z0-9_]{3,24}$"
const MIN_PASSWORD_LENGTH := 8
const GUEST_TEXT := "Continue as Guest"
const STAGE_MAX_WIDTH := 520.0

const _LOGO := "SafeMargin/Scroll/CenterH/Stage/Logo"
const _STAGE := "SafeMargin/Scroll/CenterH/Stage"
const _CENTER := "SafeMargin/Scroll/CenterH"

@onready var _back_button: Button = $BackButton
@onready var _scroll: ScrollContainer = $SafeMargin/Scroll
@onready var _center: Control = $SafeMargin/Scroll/CenterH
@onready var _stage: VBoxContainer = $SafeMargin/Scroll/CenterH/Stage
@onready var _logo: TextureRect = $SafeMargin/Scroll/CenterH/Stage/Logo
@onready var _welcome: Label = $SafeMargin/Scroll/CenterH/Stage/Panel/Body/WelcomeLabel
@onready var _tagline: Label = $SafeMargin/Scroll/CenterH/Stage/Panel/Body/TaglineLabel
@onready var _google_button: Button = $SafeMargin/Scroll/CenterH/Stage/Panel/Body/GoogleButton
@onready var _facebook_button: Button = $SafeMargin/Scroll/CenterH/Stage/Panel/Body/FacebookButton
@onready var _username_field: LineEdit = $SafeMargin/Scroll/CenterH/Stage/Panel/Body/UsernameBox/UsernameRow/UsernameField
@onready var _password_field: LineEdit = $SafeMargin/Scroll/CenterH/Stage/Panel/Body/PasswordBox/PasswordRow/PasswordField
@onready var _eye_button: Button = $SafeMargin/Scroll/CenterH/Stage/Panel/Body/PasswordBox/PasswordRow/EyeButton
@onready var _eye_icon: Control = $SafeMargin/Scroll/CenterH/Stage/Panel/Body/PasswordBox/PasswordRow/EyeButton/EyeIcon
@onready var _error_label: Label = $SafeMargin/Scroll/CenterH/Stage/Panel/Body/ErrorLabel
@onready var _submit_button: Button = $SafeMargin/Scroll/CenterH/Stage/Panel/Body/SubmitButton
@onready var _switch_button: Button = $SafeMargin/Scroll/CenterH/Stage/Panel/Body/SwitchButton
@onready var _guest_button: Button = $SafeMargin/Scroll/CenterH/Stage/Panel/Body/GuestButton

var _mode: int = Mode.SIGN_IN
var _busy := false
var _vk_compact := false
var _username_regex := RegEx.new()


func _ready() -> void:
	_username_regex.compile(USERNAME_PATTERN)
	_submit_button.pressed.connect(_on_submit)
	_switch_button.pressed.connect(_on_switch_mode)
	_guest_button.pressed.connect(_on_guest)
	_google_button.pressed.connect(_on_google)
	_facebook_button.pressed.connect(_on_facebook)
	_eye_button.pressed.connect(_on_eye_pressed)
	_username_field.text_submitted.connect(_on_username_submitted)
	_password_field.text_submitted.connect(_on_password_submitted)
	_back_button.pressed.connect(_on_back_pressed)
	# Transparent input surfaces: the AuthField PanelContainer owns the
	# visible box so the field hugging its icon looks like the reference.
	for field: LineEdit in [_username_field, _password_field]:
		field.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
		field.add_theme_stylebox_override("hover", StyleBoxEmpty.new())
		field.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		field.add_theme_stylebox_override("read_only", StyleBoxEmpty.new())
		# Explicit IME control: Godot's virtual_keyboard_show_on_focus never
		# fires on the test device, so show/hide is driven from focus and
		# tap events instead (see _vk_show / _vk_on_focus_exited).
		field.focus_entered.connect(_vk_show.bind(field))
		field.focus_exited.connect(_vk_on_focus_exited)
		field.gui_input.connect(_on_field_gui_input.bind(field))
	# Fresh launch: this screen IS the root — hide Back (hardware back
	# exits the app). When reached from inside the app, keep it.
	_back_button.visible = App.navigation.can_go_back()
	get_viewport().size_changed.connect(_update_stage_size)
	_scroll.resized.connect(_on_scroll_resized)
	_stage.resized.connect(_update_logo_size)
	_update_stage_size()
	_update_logo_size()
	_set_mode(Mode.SIGN_IN)
	if OS.is_debug_build():
		print("VK probe: feature=%s method=%s show_on_focus=%s" % [
			DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD),
			DisplayServer.has_method("virtual_keyboard_show"),
			_username_field.virtual_keyboard_show_on_focus])


func _process(_delta: float) -> void:
	# IME can be dismissed by the system back key without any focus
	# change; poll so the layout snaps back once the keyboard is gone.
	if _vk_compact and DisplayServer.virtual_keyboard_get_height() == 0:
		_vk_compact = false
		_update_stage_size()


## Fit the scroll stage to the viewport (capped width, viewport height)
## so the panel centres on tall screens and scrolls when the keyboard
## shrinks the usable height.
func _update_stage_size() -> void:
	var vp := get_viewport().get_visible_rect().size
	# The IME reports physical pixels while the viewport is in scaled
	# units; convert so the stage matches the area above the keyboard.
	var scale_y := float(DisplayServer.window_get_size().y) / maxf(1.0, vp.y)
	var vk_h := float(DisplayServer.virtual_keyboard_get_height()) / scale_y \
			if _vk_compact else 0.0
	var usable_h := maxf(300.0, vp.y - vk_h)
	var avail_w: float = maxf(260.0, vp.x - 36.0)
	var stage_w: float = minf(avail_w, STAGE_MAX_WIDTH)
	_center.custom_minimum_size = Vector2(avail_w, 0)
	_stage.custom_minimum_size = Vector2(stage_w, maxf(0.0, usable_h - 30.0))
	# The keyboard resize can leave the focused field behind the fold;
	# follow_focus only reacts to focus *moves*, so re-ensure after layout.
	var focus_owner := get_viewport().gui_get_focus_owner()
	if focus_owner is LineEdit and _scroll.is_ancestor_of(focus_owner):
		_ensure_field_visible_later(focus_owner)


## Scroll the focused field into view once the container relayout
## triggered by a viewport resize has settled (immediate calls run on
## stale rects and scroll nowhere).
func _ensure_field_visible_later(field: Control) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(field) and is_instance_valid(_scroll) and field.is_visible_in_tree():
		_scroll.ensure_control_visible(field)


## The scroll view itself resized (keyboard opened/closed): keep the
## focused field above the keyboard.
func _on_scroll_resized() -> void:
	var focus_owner := get_viewport().gui_get_focus_owner()
	if focus_owner is LineEdit and _scroll.is_ancestor_of(focus_owner):
		_scroll.ensure_control_visible(focus_owner)


## Keep the logo proportional to the stage width.
func _update_logo_size() -> void:
	var tex := _logo.texture
	if tex == null:
		return
	var ratio := float(tex.get_height()) / float(maxf(1.0, tex.get_width()))
	var w := clampf(_stage.size.x * 0.75, 180.0, 400.0)
	_logo.custom_minimum_size = Vector2(w, w * ratio)


## Show the Android IME for a text field (password fields get a
## keyboard that hides key hints). Called on focus and on tap so the
## keyboard always returns even if focus never changed.
func _vk_show(field: LineEdit) -> void:
	var vk_type := DisplayServer.KEYBOARD_TYPE_PASSWORD \
			if (field == _password_field and field.secret) \
			else DisplayServer.KEYBOARD_TYPE_DEFAULT
	if OS.is_debug_build():
		print("VK: show type=%d" % vk_type)
	DisplayServer.virtual_keyboard_show(field.text, Rect2(), vk_type)
	if not _vk_compact:
		get_tree().create_timer(0.3).timeout.connect(_vk_read_height, CONNECT_ONE_SHOT)


## The Android window does not resize for the IME on current SDKs, so
## the viewport keeps full height: once the keyboard height is known,
## shrink the stage to the area above it, which top-packs the form and
## keeps the fields and Sign In reachable.
func _vk_read_height() -> void:
	var vk_h := DisplayServer.virtual_keyboard_get_height()
	if OS.is_debug_build():
		print("VK: win=%s vp=%s vk_h=%d" % [
			DisplayServer.window_get_size(),
			get_viewport().get_visible_rect().size, vk_h])
	if vk_h <= 0:
		return
	_vk_compact = true
	_update_stage_size()


## Hide the IME when focus leaves every text field. Deferred by one
## frame so switching username <-> password does not flicker.
func _vk_on_focus_exited() -> void:
	_vk_hide_if_no_text_focus.call_deferred()


func _vk_hide_if_no_text_focus() -> void:
	var focus_owner := get_viewport().gui_get_focus_owner()
	if focus_owner is LineEdit:
		return
	if OS.is_debug_build():
		print("VK: hide (focus owner=%s)" % str(focus_owner))
	DisplayServer.virtual_keyboard_hide()


## Tapping an already-focused field must still bring the keyboard back
## (focus_entered does not re-fire), so show on press as well.
func _on_field_gui_input(event: InputEvent, field: LineEdit) -> void:
	if (event is InputEventMouseButton or event is InputEventScreenTouch) \
			and event.is_pressed():
		_vk_show(field)


func _on_back_pressed() -> void:
	DisplayServer.virtual_keyboard_hide()
	App.navigation.back()


func _on_username_submitted(_text: String) -> void:
	_password_field.grab_focus()


func _on_password_submitted(_text: String) -> void:
	_on_submit()


func _on_eye_pressed() -> void:
	_password_field.secret = not _password_field.secret
	_eye_icon.icon = &"eye_off" if _password_field.secret else &"eye"
	_eye_button.tooltip_text = "Show password" if _password_field.secret else "Hide password"


func _on_switch_mode() -> void:
	if OS.is_debug_build():
		print("UI: auth switch mode (%s)" % ("register" if _mode == Mode.SIGN_IN else "sign_in"))
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
		_submit_button.text = "Creating…"
	else:
		_submit_button.text = "Signing in…"
	if OS.is_debug_build():
		print("UI: auth %s started" % ("register" if _mode == Mode.REGISTER else "login"))
	if _mode == Mode.REGISTER:
		result = await App.auth.register(username, password)
	else:
		result = await App.auth.login(username, password)
	_set_busy(false)
	_set_mode(_mode)
	if OS.is_debug_build():
		print("UI: auth %s -> ok=%s status=%d kind=%d" % [
			"register" if _mode == Mode.REGISTER else "login",
			result.ok, result.status, result.error_kind])
	await _handle_result(result)


func _on_guest() -> void:
	if _busy:
		return
	_hide_error()
	_set_busy(true)
	_guest_button.text = "Connecting…"
	if OS.is_debug_build():
		print("UI: guest login started")
	var result: Dictionary = await App.auth.guest_login()
	_set_busy(false)
	_guest_button.text = GUEST_TEXT
	if OS.is_debug_build():
		print("UI: guest login -> ok=%s status=%d kind=%d" % [
			result.ok, result.status, result.error_kind])
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


## Social sign-in: real provider auth is only possible once OAuth
## credentials and callback URLs are configured for the backend and the
## Android client. Until then the button reports the missing setup
## honestly — it never fakes a session.
func _on_google() -> void:
	if _busy:
		return
	if OS.is_debug_build():
		print("UI: google sign-in pressed (not configured)")
	DisplayServer.virtual_keyboard_hide()
	App.dialog.show_error("Google Sign-In not configured",
			"Add Google OAuth credentials and callback settings to " +
			"enable Google sign-in. No session was created.")


func _on_facebook() -> void:
	if _busy:
		return
	if OS.is_debug_build():
		print("UI: facebook sign-in pressed (not configured)")
	DisplayServer.virtual_keyboard_hide()
	App.dialog.show_error("Facebook Sign-In not configured",
			"Add Facebook app credentials and callback settings to " +
			"enable Facebook sign-in. No session was created.")


## After any successful authentication the player lands on Home. Going
## through ROOT also clears the stack so Back never returns to the
## login screen with a live session.
func _leave() -> void:
	DisplayServer.virtual_keyboard_hide()
	App.navigation.go(App.navigation.ROOT_SCREEN)


func _set_mode(mode: int) -> void:
	_mode = mode
	if _mode == Mode.SIGN_IN:
		_welcome.text = "Welcome to"
		_tagline.text = "Play • Compete • Celebrate Our Games"
		_submit_button.text = "Sign In"
		_switch_button.text = "New here? Create an account"
	else:
		_welcome.text = "Join"
		_tagline.text = "Pick a unique username — it becomes your player identity."
		_submit_button.text = "Create Account"
		_switch_button.text = "I already have an account"


func _set_busy(busy: bool) -> void:
	_busy = busy
	if busy:
		DisplayServer.virtual_keyboard_hide()
	_username_field.editable = not busy
	_password_field.editable = not busy
	_submit_button.disabled = busy
	_switch_button.disabled = busy
	_guest_button.disabled = busy
	_google_button.disabled = busy
	_facebook_button.disabled = busy
	_eye_button.disabled = busy


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

extends Control
## Challenge flow (Phase 11): pick a game, create a share code, hand the
## WhatsApp message to a friend, and accept/decline incoming codes.
## Entered via App.social.set_pending(...) — see _ready().

@onready var _choose_panel: PanelContainer = $Margin/Content/ChoosePanel
@onready var _choose_title: Label = \
		$Margin/Content/ChoosePanel/ChooseBody/ChooseTitle
@onready var _choose_list: VBoxContainer = \
		$Margin/Content/ChoosePanel/ChooseBody/ChooseList
@onready var _choose_hint: Label = \
		$Margin/Content/ChoosePanel/ChooseBody/ChooseHint

@onready var _incoming_panel: PanelContainer = $Margin/Content/IncomingPanel
@onready var _incoming_label: Label = \
		$Margin/Content/IncomingPanel/IncomingBody/IncomingLabel
@onready var _expires_label: Label = \
		$Margin/Content/IncomingPanel/IncomingBody/ExpiresLabel
@onready var _accept_button: Button = \
		$Margin/Content/IncomingPanel/IncomingBody/IncomingActions/AcceptButton
@onready var _decline_button: Button = \
		$Margin/Content/IncomingPanel/IncomingBody/IncomingActions/DeclineButton

@onready var _code_panel: PanelContainer = $Margin/Content/CodePanel
@onready var _code_label: Label = $Margin/Content/CodePanel/CodeBody/CodeLabel
@onready var _status_label: Label = $Margin/Content/CodePanel/CodeBody/StatusLabel

@onready var _share_panel: PanelContainer = $Margin/Content/SharePanel
@onready var _share_text: Label = $Margin/Content/SharePanel/ShareBody/ShareText
@onready var _whatsapp_button: Button = \
		$Margin/Content/SharePanel/ShareBody/ShareRow/WhatsappButton
@onready var _copy_button: Button = \
		$Margin/Content/SharePanel/ShareBody/ShareRow/CopyButton

@onready var _extra_row: HBoxContainer = $Margin/Content/ExtraRow
@onready var _cancel_button: Button = $Margin/Content/ExtraRow/CancelButton

const BUTTON_SCENE := "res://scenes/components/button.tscn"

var _mode := ""
var _code := ""
var _game_key := ""
var _invitee := ""
var _challenge: Dictionary = {}
var _expires_unix := 0.0
var _polling := false
var _deciding := false


func _ready() -> void:
	_accept_button.pressed.connect(_on_accept_pressed)
	_decline_button.pressed.connect(_on_decline_pressed)
	_whatsapp_button.pressed.connect(_on_whatsapp_pressed)
	_copy_button.pressed.connect(_on_copy_pressed)
	_cancel_button.pressed.connect(_on_cancel_pressed)

	var pending := App.social.take_pending()
	_mode = str(pending.get("mode", ""))
	_code = str(pending.get("code", "")).to_upper()
	_game_key = str(pending.get("game_key", ""))
	_invitee = str(pending.get("invitee", ""))
	match _mode:
		"choose_game":
			_show_choose()
		"compose", "rematch":
			_begin_compose()
		"info":
			_load_info()
		_:
			_show_all_hidden()
			_choose_hint.text = "Open a challenge from Friends, or share one."
			_choose_hint.visible = true
			_choose_panel.visible = true


func _exit_tree() -> void:
	_polling = false


func _process(_delta: float) -> void:
	if _incoming_panel.visible and _expires_unix > 0.0 \
			and not _accept_button.disabled:
		_update_expiry()


# --- Views -----------------------------------------------------------------

func _show_all_hidden() -> void:
	_choose_panel.visible = false
	_incoming_panel.visible = false
	_code_panel.visible = false
	_share_panel.visible = false
	_extra_row.visible = false


func _show_choose() -> void:
	_show_all_hidden()
	_choose_panel.visible = true
	_choose_title.text = ("Challenge %s to" % _invitee) \
			if not _invitee.is_empty() else "Challenge a friend to"
	_choose_hint.text = ""
	for child in _choose_list.get_children():
		_choose_list.remove_child(child)
		child.queue_free()
	for game_key in SocialService.GAME_TITLES:
		_choose_list.add_child(_game_button(str(game_key),
				SocialService.game_title(str(game_key))))


func _game_button(game_key: String, title: String) -> Button:
	var button: Button = (load(BUTTON_SCENE) as PackedScene).instantiate()
	button.text = title
	button.pressed.connect(func() -> void: _on_game_chosen(game_key))
	return button


func _begin_compose() -> void:
	if not _challenge.is_empty():
		_apply_compose()
		return
	if _game_key.is_empty():
		_show_choose()
		return
	var res: Dictionary = await App.social.create_challenge(_game_key, _invitee)
	if not res.ok:
		_show_all_hidden()
		_choose_panel.visible = true
		_choose_hint.text = str(res.get("message",
				ApiClient.error_text(int(res.get("error_kind",
				ApiClient.ErrorKind.NONE)))))
		return
	_challenge = res.body
	_code = str(res.body.get("code", _code))
	_apply_compose()


func _on_game_chosen(game_key: String) -> void:
	_game_key = game_key
	await _begin_compose()


func _apply_compose() -> void:
	var body := _challenge
	_mode = "compose"
	_code = str(body.get("code", _code))
	_game_key = str(body.get("gameKey", _game_key))
	var game_name := str(body.get("gameName",
			SocialService.game_title(_game_key)))
	_show_all_hidden()
	_code_panel.visible = true
	_share_panel.visible = true
	_extra_row.visible = true
	_code_label.text = _code
	var status := str(body.get("status", "PENDING"))
	_status_label.text = _status_text(status)
	_share_text.text = SocialService.challenge_message(
			_my_name(), game_name, _code, _link_base())
	if status == "PENDING":
		_start_polling()


func _show_incoming(body: Dictionary) -> void:
	_show_all_hidden()
	_incoming_panel.visible = true
	var challenger := _username_of(body.get("challenger"))
	var game_name := str(body.get("gameName", ""))
	_incoming_label.text = "%s challenged you to %s." % [challenger, game_name]
	var status := str(body.get("status", "PENDING"))
	if status != "PENDING":
		_incoming_label.text += "\n%s" % _status_text(status)
		_accept_button.disabled = true
		_decline_button.disabled = true
		_expires_label.text = ""
		_expires_unix = 0.0
	else:
		_accept_button.disabled = false
		_decline_button.disabled = false
		_expires_unix = OnlineMatchService._iso_to_unix(
				str(body.get("expiresAt", "")))
		_update_expiry()


# --- Code lookup (friends inbox / manual entry) ----------------------------

func _load_info() -> void:
	if _code.is_empty():
		_show_all_hidden()
		_choose_panel.visible = true
		_choose_hint.text = "No challenge selected."
		_choose_hint.visible = true
		return
	var res: Dictionary = await App.social.get_challenge(_code)
	if not res.ok:
		_show_all_hidden()
		_choose_panel.visible = true
		var kind := int(res.get("error_kind", ApiClient.ErrorKind.NONE))
		_choose_hint.text = str(res.get("message", "")) \
				if kind != ApiClient.ErrorKind.NETWORK \
				and kind != ApiClient.ErrorKind.SERVER_UNAVAILABLE \
				else "Could not reach the server. Try again."
		return
	_challenge = res.body
	_assign_from(res.body)


func _assign_from(body: Dictionary) -> void:
	_game_key = str(body.get("gameKey", _game_key))
	var my_id := App.auth.get_player_id()
	var status := str(body.get("status", "PENDING"))
	if str(_id_of(body.get("challenger"))) == my_id:
		# My own code — show the share view (with live status).
		_apply_compose()
		return
	var invitee_id := str(_id_of(body.get("invitee")))
	if invitee_id.is_empty() or invitee_id == my_id or status != "PENDING":
		_show_incoming(body)
		return
	_show_all_hidden()
	_choose_panel.visible = true
	_choose_hint.text = "That challenge is for someone else."


# --- Polling (outgoing code: did they accept?) -----------------------------

func _start_polling() -> void:
	if _polling:
		return
	_polling = true
	while _polling and is_inside_tree():
		await get_tree().create_timer(3.0).timeout
		if not _polling or not is_inside_tree():
			break
		await _check_outgoing()


func _check_outgoing() -> void:
	if _code.is_empty():
		return
	var res: Dictionary = await App.social.get_challenge(_code)
	if not res.ok:
		return
	_challenge = res.body
	var status := str(res.body.get("status", ""))
	_status_label.text = _status_text(status)
	if status == "ACCEPTED":
		_polling = false
		_enter_match(res.body)
	elif status == "DECLINED" or status == "CANCELLED" or status == "EXPIRED":
		_polling = false


# --- Actions ---------------------------------------------------------------

func _on_accept_pressed() -> void:
	if _deciding:
		return
	_deciding = true
	_accept_button.disabled = true
	var res: Dictionary = await App.social.accept_challenge(_code)
	_deciding = false
	if not res.ok:
		_accept_button.disabled = false
		var kind := int(res.get("error_kind", ApiClient.ErrorKind.NONE))
		if kind != ApiClient.ErrorKind.NETWORK \
				and kind != ApiClient.ErrorKind.SERVER_UNAVAILABLE:
			App.dialog.show_error("Could not accept", str(res.get("message", "")))
		return
	_enter_match(res.body)


func _on_decline_pressed() -> void:
	if _deciding:
		return
	_deciding = true
	_decline_button.disabled = true
	var res: Dictionary = await App.social.decline_challenge(_code)
	_deciding = false
	if not res.ok:
		_decline_button.disabled = false
		App.dialog.show_error("Could not decline", str(res.get("message", "")))
		return
	if not App.navigation.back():
		App.navigation.go(&"friends")


func _on_cancel_pressed() -> void:
	var ok: bool = await App.dialog.confirm(
			"Cancel challenge?", "The share code stops working.",
			"Cancel challenge", true)
	if not ok:
		return
	var res: Dictionary = await App.social.cancel_challenge(_code)
	if not res.ok:
		App.dialog.show_error("Could not cancel", str(res.get("message", "")))
		return
	_polling = false
	_status_label.text = _status_text("CANCELLED")


func _on_whatsapp_pressed() -> void:
	App.analytics.track("share", {"channel": "whatsapp"}, _game_key)
	OS.shell_open(SocialService.whatsapp_url(_share_text.text))


func _on_copy_pressed() -> void:
	App.analytics.track("share", {"channel": "copy"}, _game_key)
	DisplayServer.clipboard_set(_share_text.text)
	_status_label.text = "Message copied."


## Accepted (or spotted while polling): hand off to the game screen,
## which boots straight into online mode and resumes the fresh match.
func _enter_match(body: Dictionary) -> void:
	var game_key := str(body.get("gameKey", _game_key))
	var screen := SocialService.screen_for(game_key)
	if screen == &"":
		App.dialog.show_error("Unsupported game", game_key)
		return
	App.online.set_game_key(game_key)
	var match_id := str(body.get("matchId", body.get("match_id", "")))
	App.online.request_auto_online(match_id)
	App.navigation.go(screen)


# --- Helpers ---------------------------------------------------------------

func _update_expiry() -> void:
	var left := int(_expires_unix - Time.get_unix_time_from_system())
	if left <= 0:
		_expires_label.text = "This challenge expired."
		_accept_button.disabled = true
	else:
		_expires_label.text = "Expires in %d:%02d" % [left / 60, left % 60]


func _status_text(status: String) -> String:
	match status:
		"PENDING":
			return "Waiting for a friend to accept\u2026"
		"ACCEPTED":
			return "Accepted \u2014 starting match\u2026"
		"DECLINED":
			return "They declined the challenge."
		"CANCELLED":
			return "Challenge cancelled."
		"EXPIRED":
			return "This code expired \u2014 create a new one."
	return ""


func _my_name() -> String:
	var display := App.user.get_display_name()
	if display.is_empty() or display == App.user.PLACEHOLDER_NAME:
		display = App.auth.get_username()
	return display


func _link_base() -> String:
	return str(App.get_local_setting("challenge", "link_base", ""))


func _username_of(user: Variant) -> String:
	if user is Dictionary:
		return str((user as Dictionary).get("username", "?"))
	return "?"


func _id_of(user: Variant) -> String:
	if user is Dictionary:
		return str((user as Dictionary).get("id", ""))
	return ""

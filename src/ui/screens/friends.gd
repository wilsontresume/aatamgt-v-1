extends Control
## Social hub (Phase 11): find friends, answer requests, open share
## challenges, and manage blocks. REST only — no chat, no push.

@onready var _username_field: LineEdit = \
		$Margin/Content/AddPanel/AddBody/AddRow/UsernameField
@onready var _add_button: Button = \
		$Margin/Content/AddPanel/AddBody/AddRow/AddButton
@onready var _add_hint: Label = $Margin/Content/AddPanel/AddBody/AddHint

@onready var _incoming_list: VBoxContainer = \
		$Margin/Content/IncomingPanel/IncomingBody/IncomingList
@onready var _incoming_hint: Label = \
		$Margin/Content/IncomingPanel/IncomingBody/IncomingHint

@onready var _friends_list: VBoxContainer = \
		$Margin/Content/FriendsPanel/FriendsBody/FriendsList
@onready var _friends_hint: Label = \
		$Margin/Content/FriendsPanel/FriendsBody/FriendsHint

@onready var _challenge_list: VBoxContainer = \
		$Margin/Content/ChallengesPanel/ChallengesBody/ChallengeList
@onready var _challenge_hint: Label = \
		$Margin/Content/ChallengesPanel/ChallengesBody/ChallengeHint

@onready var _blocked_list: VBoxContainer = \
		$Margin/Content/BlockedPanel/BlockedBody/BlockedList
@onready var _blocked_hint: Label = \
		$Margin/Content/BlockedPanel/BlockedBody/BlockedHint

@onready var _code_field: LineEdit = \
		$Margin/Content/CodePanel/CodeBody/CodeRow/CodeField
@onready var _open_code_button: Button = \
		$Margin/Content/CodePanel/CodeBody/CodeRow/OpenButton
@onready var _code_hint: Label = $Margin/Content/CodePanel/CodeBody/CodeHint

var _busy := false


func _ready() -> void:
	_add_button.pressed.connect(_on_add_pressed)
	_username_field.text_submitted.connect(
			func(_text: String) -> void: _on_add_pressed())
	_open_code_button.pressed.connect(_on_open_code_pressed)
	reload()


# --- Loading ---------------------------------------------------------------

func reload() -> void:
	if _busy:
		return
	if not App.auth.is_authenticated():
		_render_signed_out()
		return
	_busy = true
	var res: Dictionary = await App.social.list_friends()
	if not res.ok:
		_busy = false
		_show_load_error(res, "friends")
		return
	var body: Dictionary = res.body
	_render(_incoming_list, _incoming_hint, body.get("incoming"),
			"incoming", "No pending requests.")
	_render(_friends_list, _friends_hint, body.get("friends"),
			"friends", "No friends yet \u2014 add one above.")
	_render(_blocked_list, _blocked_hint, body.get("blocked"),
			"blocked", "No one is blocked.")
	var inbox: Dictionary = await App.social.challenge_inbox()
	if inbox.ok and inbox.body is Dictionary:
		_render_challenges(inbox.body)
	else:
		_clear(_challenge_list)
		_challenge_hint.visible = true
		_challenge_hint.text = "No pending challenges."
	_busy = false


func _render_signed_out() -> void:
	_clear(_incoming_list)
	_clear(_friends_list)
	_clear(_blocked_list)
	_clear(_challenge_list)
	_incoming_hint.text = "Sign in to use friends and challenges."
	_friends_hint.text = ""
	_blocked_hint.text = ""
	_challenge_hint.text = ""
	_incoming_hint.visible = true
	_friends_hint.visible = false
	_blocked_hint.visible = false
	_challenge_hint.visible = false


func _show_load_error(res: Dictionary, what: String) -> void:
	var kind := int(res.get("error_kind", ApiClient.ErrorKind.NONE))
	if kind == ApiClient.ErrorKind.NETWORK \
			or kind == ApiClient.ErrorKind.SERVER_UNAVAILABLE:
		return  # offline: keep the empty state, never a modal on load
	App.dialog.show_error("Could not load %s" % what, str(res.get("message", "")))


# --- Rendering -------------------------------------------------------------

func _clear(list: VBoxContainer) -> void:
	for child in list.get_children():
		list.remove_child(child)
		child.queue_free()


func _render(list: VBoxContainer, hint: Label, items: Variant,
		kind: String, empty_text: String) -> void:
	_clear(list)
	var arr: Array = items if items is Array else []
	hint.text = empty_text
	hint.visible = arr.is_empty()
	for item in arr:
		if not (item is Dictionary):
			continue
		var entry: Dictionary = item
		list.add_child(_make_row(_title_of(entry, kind), _actions_for(kind, entry)))


func _title_of(entry: Dictionary, kind: String) -> String:
	var user: Variant = entry.get("user")
	var username := str((user as Dictionary).get("username", "?")) if user is Dictionary else "?"
	match kind:
		"incoming":
			return "From %s" % username
		"blocked":
			return "%s" % username
		_:
			return username


func _actions_for(kind: String, entry: Dictionary) -> Array:
	var id := str(entry.get("id", ""))
	var user: Variant = entry.get("user")
	var who := str((user as Dictionary).get("username", "")) if user is Dictionary else ""
	match kind:
		"incoming":
			return [
				["Accept", func() -> void: _respond(id, true)],
				["Reject", func() -> void: _respond(id, false)],
			]
		"friends":
			return [
				["Challenge", func() -> void: _start_challenge(who)],
				["Remove", func() -> void: _remove_friend(id, who)],
				["Block", func() -> void: _block(who)],
			]
		"blocked":
			return [["Unblock", func() -> void: _unblock(id)]]
	return []


func _render_challenges(inbox: Dictionary) -> void:
	_clear(_challenge_list)
	var incoming: Array = inbox.get("incoming") if inbox.get("incoming") is Array else []
	var outgoing: Array = inbox.get("outgoing") if inbox.get("outgoing") is Array else []
	_challenge_hint.visible = incoming.is_empty() and outgoing.is_empty()
	_challenge_hint.text = "No pending challenges."
	for ch in incoming:
		if ch is Dictionary:
			_challenge_list.add_child(
					_challenge_row(ch, "From", _challenger_of(ch)))
	for ch in outgoing:
		if ch is Dictionary:
			_challenge_list.add_child(
					_challenge_row(ch, "To", _invitee_of(ch)))


## Row factory takes the entry as a parameter so the [Open] lambda
## captures a per-call binding (not a loop variable).
func _challenge_row(ch: Dictionary, prefix: String, who: String) -> HBoxContainer:
	return _make_row("%s %s \u00b7 %s" % [prefix, who, _game_of(ch)],
			[["Open", func() -> void: _open_challenge(ch)]])


func _challenger_of(ch: Dictionary) -> String:
	var c: Variant = ch.get("challenger")
	return str((c as Dictionary).get("username", "?")) if c is Dictionary else "?"


func _invitee_of(ch: Dictionary) -> String:
	var i: Variant = ch.get("invitee")
	if i is Dictionary:
		return str((i as Dictionary).get("username", "anyone"))
	return "anyone"


func _game_of(ch: Dictionary) -> String:
	return str(ch.get("gameName", ch.get("gameKey", "")))


func _make_row(title: String, actions: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = title
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(label)
	for action in actions:
		if not (action is Array) or (action as Array).size() < 2:
			continue
		var button := Button.new()
		button.text = str(action[0])
		button.custom_minimum_size = Vector2(0, 32)
		button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		button.pressed.connect(action[1] as Callable)
		row.add_child(button)
	return row


# --- Actions ---------------------------------------------------------------

func _on_add_pressed() -> void:
	_add_hint.text = ""
	var username := _username_field.text.strip_edges()
	if username.length() < 3 or username.length() > 24:
		_add_hint.text = "Enter a username (3\u201324 characters)."
		return
	if not App.auth.is_authenticated():
		_add_hint.text = "Sign in to send requests."
		return
	var res: Dictionary = await App.social.send_friend_request(username)
	if not res.ok:
		var message := str(res.get("message", ""))
		if message.is_empty():
			message = ApiClient.error_text(int(res.get("error_kind",
					ApiClient.ErrorKind.NONE)))
		_add_hint.text = message
		return
	_add_hint.text = "Request sent to %s." % username
	_username_field.clear()
	reload()


func _respond(id: String, accept: bool) -> void:
	var res: Dictionary
	if accept:
		res = await App.social.accept_friend_request(id)
	else:
		res = await App.social.decline_friend_request(id)
	if not res.ok:
		App.dialog.show_error("Request failed", str(res.get("message", "")))
		return
	reload()


func _start_challenge(username: String) -> void:
	App.social.set_pending({"mode": "choose_game", "invitee": username})
	App.navigation.go(&"challenge")


func _remove_friend(id: String, who: String) -> void:
	var ok: bool = await App.dialog.confirm(
			"Remove %s?" % who, "You can add each other again later.",
			"Remove", true)
	if not ok:
		return
	var res: Dictionary = await App.social.remove_friend(id)
	if not res.ok:
		App.dialog.show_error("Remove failed", str(res.get("message", "")))
		return
	reload()


func _block(who: String) -> void:
	var ok: bool = await App.dialog.confirm(
			"Block %s?" % who,
			"They can\u2019t add or challenge you while blocked.",
			"Block", true)
	if not ok:
		return
	var res: Dictionary = await App.social.block_user(who)
	if not res.ok:
		App.dialog.show_error("Block failed", str(res.get("message", "")))
		return
	reload()


func _unblock(id: String) -> void:
	var res: Dictionary = await App.social.remove_friend(id)
	if not res.ok:
		App.dialog.show_error("Unblock failed", str(res.get("message", "")))
		return
	reload()


func _open_challenge(ch: Dictionary) -> void:
	App.social.set_pending({"mode": "info", "code": str(ch.get("code", ""))})
	App.navigation.go(&"challenge")


func _on_open_code_pressed() -> void:
	_code_hint.text = ""
	var code := _code_field.text.strip_edges().to_upper()
	if not SocialService.is_valid_code(code):
		_code_hint.text = "Enter the code from your challenge message."
		return
	App.social.set_pending({"mode": "info", "code": code})
	App.navigation.go(&"challenge")

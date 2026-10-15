extends Control
## Friend challenge entry (Workflow Change 2): pick a friend or look up a
## player ID, send a staked challenge, share the code. Server owns the
## challenge lifecycle; this screen only calls SocialService + MatchmakingService.

@onready var _title_label: Label = $Margin/Content/TitleLabel
@onready var _game_label: Label = $Margin/Content/GameLabel
@onready var _tier_label: Label = $Margin/Content/TierLabel
@onready var _friends_option: OptionButton = $Margin/Content/FriendsRow/FriendsOption
@onready var _username_field: LineEdit = $Margin/Content/UsernameRow/UsernameField
@onready var _lookup_button: Button = $Margin/Content/UsernameRow/LookupButton
@onready var _lookup_result: Label = $Margin/Content/LookupResult
@onready var _send_button: Button = $Margin/Content/SendButton
@onready var _status_label: Label = $Margin/Content/StatusLabel
@onready var _code_panel: Control = $Margin/Content/CodePanel
@onready var _code_label: Label = $Margin/Content/CodePanel/CodeVBox/CodeLabel
@onready var _share_button: Button = $Margin/Content/CodePanel/CodeVBox/ShareButton

var _game_key := OnlineMatchService.AADU_PULI_KEY
var _tier_id := ""
var _friends: Array = []
var _resolved_username := ""
var _last_code := ""


func _ready() -> void:
	var pending := App.matchmaking.take_pending()
	if pending.is_empty():
		# Default to the carousel selection when opened from elsewhere.
		_game_key = MatchmakingService.game_key_for(App.selected_game)
		_tier_id = ""
	else:
		_game_key = str(pending.get("game_key", _game_key))
		_tier_id = str(pending.get("tier_id", ""))
	var title := SocialService.game_title(_game_key)
	_title_label.text = "Challenge a Friend"
	_game_label.text = title
	if _tier_id.is_empty():
		_tier_label.text = "Stake tier: none selected"
		_send_button.disabled = true
	else:
		_tier_label.text = "Stake tier: %s" % _tier_id
	_code_panel.visible = false
	_lookup_result.text = ""
	_status_label.text = ""
	_wire()
	_load_friends()


func _wire() -> void:
	_lookup_button.pressed.connect(_on_lookup_pressed)
	_send_button.pressed.connect(_on_send_pressed)
	_share_button.pressed.connect(_on_share_pressed)
	_username_field.text_submitted.connect(func(_t: String) -> void: _on_lookup_pressed())


func _load_friends() -> void:
	_friends_option.clear()
	_friends_option.add_item("Choose a friend…")
	_friends_option.set_item_disabled(0, true)
	if not App.auth.is_authenticated():
		_status_label.text = "Sign in to challenge friends"
		_send_button.disabled = true
		return
	var res: Dictionary = await App.social.list_friends()
	if not res.ok:
		_status_label.text = "Could not load friends"
		return
	_friends = res.body.get("friends", [])
	for row in _friends:
		var uname := str(row.get("user", {}).get("username", ""))
		if uname.is_empty():
			continue
		_friends_option.add_item(uname)


func _on_lookup_pressed() -> void:
	var username := _username_field.text.strip_edges()
	if username.is_empty():
		_lookup_result.text = ""
		_resolved_username = ""
		return
	_lookup_result.text = "Looking up…"
	var res: Dictionary = await App.matchmaking.lookup_player(username)
	if res.ok:
		_resolved_username = str(res.body.get("username", username))
		_lookup_result.text = "Found: %s" % _resolved_username
	else:
		_resolved_username = ""
		_lookup_result.text = "Player not found"


func _on_send_pressed() -> void:
	if not App.auth.is_authenticated():
		App.navigation.go(&"auth")
		return
	if _tier_id.is_empty():
		_status_label.text = "Select a stake tier on the previous screen"
		return
	var invitee := _resolved_username
	if invitee.is_empty() and _friends_option.selected > 0:
		invitee = _friends_option.get_item_text(_friends_option.selected)
	if invitee.is_empty():
		_status_label.text = "Pick a friend or look up a player ID"
		return
	_send_button.disabled = true
	_status_label.text = "Sending challenge…"
	var res: Dictionary = await App.social.create_challenge(_game_key, invitee, _tier_id)
	_send_button.disabled = false
	if not res.ok:
		_status_label.text = str(res.get("error", "Could not send challenge"))
		return
	_last_code = str(res.body.get("code", ""))
	_status_label.text = "Challenge sent to %s" % invitee
	_code_label.text = "Share this code: %s" % _last_code
	_code_panel.visible = true
	App.analytics.track("challenge_sent", {"tier": _tier_id}, _game_key)


func _on_share_pressed() -> void:
	if _last_code.is_empty():
		return
	var me := App.auth.get_username()
	var text := SocialService.challenge_message(
			me, SocialService.game_title(_game_key), _last_code)
	DisplayServer.clipboard_set(text)
	_status_label.text = "Invite text copied to clipboard"

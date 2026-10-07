extends Control
## Player profile with placeholder statistics (backend-computed later).

@onready var _matches_card: PanelContainer = $Margin/Content/StatsRow/MatchesCard
@onready var _wins_card: PanelContainer = $Margin/Content/StatsRow/WinsCard
@onready var _win_rate_card: PanelContainer = $Margin/Content/StatsRow/WinRateCard
@onready var _player_id_label: Label = $Margin/Content/AccountPanel/AccountBody/PlayerIdLabel
@onready var _account_type_label: Label = $Margin/Content/AccountPanel/AccountBody/AccountTypeLabel
@onready var _sign_in_button: Button = $Margin/Content/AccountPanel/AccountBody/SignInButton


func _ready() -> void:
	App.user.profile_changed.connect(_on_profile_changed)
	_on_profile_changed(App.user.get_profile())
	_sign_in_button.pressed.connect(func() -> void: App.navigation.go(&"auth"))
	App.auth.session_changed.connect(_on_account_changed)
	App.auth.signed_out.connect(_on_signed_out)
	_refresh_account()


func _on_account_changed(_user: Dictionary) -> void:
	_refresh_account()


func _on_signed_out() -> void:
	_refresh_account()


func _refresh_account() -> void:
	if App.auth.is_authenticated():
		_player_id_label.text = "Player ID: %s" % App.auth.get_player_id()
		_account_type_label.text = ("Guest account" if App.auth.is_guest()
				else "Registered account")
		_sign_in_button.visible = false
	else:
		_player_id_label.text = "Player ID: \u2014"
		_account_type_label.text = "Not signed in"
		_sign_in_button.visible = true


func _on_profile_changed(profile: Dictionary) -> void:
	var stats: Dictionary = profile.get("stats", {})
	var matches := int(stats.get("matches", 0))
	var wins := int(stats.get("wins", 0))
	_matches_card.value_text = str(matches)
	_wins_card.value_text = str(wins)
	_win_rate_card.value_text = ("%d%%" % roundi(100.0 * wins / matches)) if matches > 0 else "—"

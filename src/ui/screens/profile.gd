extends Control
## Player profile with placeholder statistics (backend-computed later).

@onready var _matches_card: PanelContainer = $Margin/Content/StatsRow/MatchesCard
@onready var _wins_card: PanelContainer = $Margin/Content/StatsRow/WinsCard
@onready var _win_rate_card: PanelContainer = $Margin/Content/StatsRow/WinRateCard
@onready var _player_id_label: Label = $Margin/Content/AccountPanel/AccountBody/PlayerIdLabel
@onready var _account_type_label: Label = $Margin/Content/AccountPanel/AccountBody/AccountTypeLabel
@onready var _sign_in_button: Button = $Margin/Content/AccountPanel/AccountBody/SignInButton
@onready var _rank_rows: VBoxContainer = $Margin/Content/RankRows


func _ready() -> void:
	App.user.profile_changed.connect(_on_profile_changed)
	_on_profile_changed(App.user.get_profile())
	_sign_in_button.pressed.connect(func() -> void: App.navigation.go(&"auth"))
	App.auth.session_changed.connect(_on_account_changed)
	App.auth.signed_out.connect(_on_signed_out)
	_refresh_account()
	_refresh_ranks()


func _on_account_changed(_user: Dictionary) -> void:
	_refresh_account()
	_refresh_ranks()


func _on_signed_out() -> void:
	_refresh_account()
	_refresh_ranks()


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
	_win_rate_card.value_text = ("%d%%" % roundi(100.0 * wins / matches)) if matches > 0 else "\u2014"


## Phase 14: one rank row per rated game — server-owned numbers only.
func _refresh_ranks() -> void:
	for child in _rank_rows.get_children():
		_rank_rows.remove_child(child)
		child.queue_free()
	if not App.auth.is_authenticated():
		_rank_rows.add_child(_rank_caption("Sign in to see your rank."))
		return
	var res: Dictionary = await App.rankings.summary()
	if not res.ok:
		_rank_rows.add_child(_rank_caption("Ratings unavailable."))
		return
	for game in res.body.get("games", []):
		if game is Dictionary:
			_rank_rows.add_child(_rank_row(game))


func _rank_row(game: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var title := Label.new()
	title.text = str(RankingService.GAME_TITLES.get(
			str(game.get("gameKey", "")), str(game.get("gameKey", ""))))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title)
	var rank := Label.new()
	rank.text = str(game.get("rank", {}).get("name", "Bronze"))
	rank.modulate = AppTheme.C_ACCENT
	rank.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(rank)
	var rating := Label.new()
	rating.theme_type_variation = "Caption"
	rating.text = "%d rating \u00b7 %dW-%dL" % [
		int(game.get("rating", 0)),
		int(game.get("wins", 0)),
		int(game.get("losses", 0)),
	]
	rating.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(rating)
	return row


func _rank_caption(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = "Caption"
	return label

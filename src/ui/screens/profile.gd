extends Control
## Player profile with placeholder statistics (backend-computed later).

@onready var _matches_card: PanelContainer = $Margin/Content/StatsRow/MatchesCard
@onready var _wins_card: PanelContainer = $Margin/Content/StatsRow/WinsCard
@onready var _win_rate_card: PanelContainer = $Margin/Content/StatsRow/WinRateCard


func _ready() -> void:
	App.user.profile_changed.connect(_on_profile_changed)
	_on_profile_changed(App.user.get_profile())


func _on_profile_changed(profile: Dictionary) -> void:
	var stats: Dictionary = profile.get("stats", {})
	var matches := int(stats.get("matches", 0))
	var wins := int(stats.get("wins", 0))
	_matches_card.value_text = str(matches)
	_wins_card.value_text = str(wins)
	_win_rate_card.value_text = ("%d%%" % roundi(100.0 * wins / matches)) if matches > 0 else "—"

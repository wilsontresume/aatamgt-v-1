extends Control
## Phase 14: competitive standings — the active season, per-game tabs,
## the player's own rank card, the top-players board and the recent
## rating results. Every number comes from the server; this screen only
## renders what GET /rankings returns.

const TABS := {
	"aadu-puli-aattam": "AaduPuliTab",
	"solah-seedi": "SoldiersTab",
	"nine-mens-morris": "MorrisTab",
}

@onready var _season_label: Label = $Margin/Content/SeasonLabel
@onready var _tabs_row: HBoxContainer = $Margin/Content/GameTabs
@onready var _standing_row: HBoxContainer = \
		$Margin/Content/Scroll/Column/StandingPanel/StandingBody/StandingRow
@onready var _board_rows: VBoxContainer = \
		$Margin/Content/Scroll/Column/BoardPanel/BoardBody/BoardRows
@onready var _result_rows: VBoxContainer = \
		$Margin/Content/Scroll/Column/ResultsPanel/ResultsBody/ResultRows
@onready var _hint: Label = $Margin/Content/HintLabel

var _game_key: String = RankingService.RATED_GAME_KEYS[0]
var _summary: Dictionary = {}
var _busy := false


func _ready() -> void:
	for child in _tabs_row.get_children():
		if child is Button:
			child.pressed.connect(_on_tab_pressed.bind(child))
	await _load()
	_select_tab_visual()


func _on_tab_pressed(button: Button) -> void:
	for key in TABS:
		if str(TABS[key]) == button.name:
			_game_key = key
			break
	_select_tab_visual()
	await _load()


func _select_tab_visual() -> void:
	for child in _tabs_row.get_children():
		if child is Button:
			(child as Button).set_pressed_no_signal(child.name == TABS.get(_game_key, ""))


## Pulls summary + board + history for the selected game and re-renders.
func _load() -> void:
	if _busy:
		return
	_busy = true
	_hint.visible = false

	var summary_res: Dictionary = {}
	var board_res: Dictionary = {}
	var history_res: Dictionary = {}
	if App.auth.is_authenticated():
		summary_res = await App.rankings.summary()
		if summary_res.ok:
			_summary = summary_res.body
	board_res = await App.rankings.leaderboard(_game_key, 10)
	if App.auth.is_authenticated():
		history_res = await App.rankings.history(20, _game_key)
	_busy = false

	var failures: Array = [summary_res, board_res, history_res]
	for res in failures:
		if res is Dictionary and not res.is_empty() and not bool(res.get("ok", true)):
			_hint.visible = true
			_hint.text = _error_text(res)
			break

	_render(board_res, history_res)


# --- Rendering ---------------------------------------------------------------

func _render(board_res: Dictionary, history_res: Dictionary) -> void:
	var season: Dictionary = {}
	if _summary is Dictionary and not _summary.is_empty():
		season = _summary.get("season", {})
	elif board_res.get("ok", false):
		season = board_res.body.get("season", {})
	_season_label.text = "Season: %s" % str(season.get("name", "\u2014"))

	_render_standing()
	_render_board(board_res)
	_render_results(history_res)


func _render_standing() -> void:
	for child in _standing_row.get_children():
		_standing_row.remove_child(child)
		child.queue_free()
	if not App.auth.is_authenticated():
		_standing_row.add_child(_label("Sign in to compete for ranks.", true))
		return
	var game: Dictionary = {}
	for entry in _summary.get("games", []):
		if str(entry.get("gameKey", "")) == _game_key:
			game = entry
	if game.is_empty():
		_standing_row.add_child(_label("No rating yet.", true))
		return
	var rank: Dictionary = game.get("rank", {})
	var title := str(RankingService.GAME_TITLES.get(_game_key, _game_key))
	_standing_row.add_child(_label(title, false))
	_standing_row.add_child(_chip(str(rank.get("name", "Bronze"))))
	_standing_row.add_child(_label("%d rating" % int(game.get("rating", 0)), false))
	_standing_row.add_child(_label(
			"%dW %dL %dD" % [int(game.get("wins", 0)), int(game.get("losses", 0)),
			int(game.get("draws", 0))], true))
	_standing_row.add_child(_label("#%d" % int(game.get("position", 1)), true))


func _render_board(board_res: Dictionary) -> void:
	for child in _board_rows.get_children():
		_board_rows.remove_child(child)
		child.queue_free()
	if not bool(board_res.get("ok", false)):
		_board_rows.add_child(_label("Standings unavailable.", true))
		return
	var items: Variant = board_res.body.get("items")
	var arr: Array = items if items is Array else []
	if arr.is_empty():
		_board_rows.add_child(_label("No ranked players in this game yet.", true))
		return
	for item in arr:
		if not (item is Dictionary):
			continue
		_board_rows.add_child(_make_board_row(item))


func _make_board_row(item: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var position := Label.new()
	position.theme_type_variation = "Caption"
	position.custom_minimum_size = Vector2(36, 0)
	position.text = "#%d" % int(item.get("position", 0))
	row.add_child(position)
	var name_label := Label.new()
	name_label.text = str(item.get("username", "?"))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)
	var rank_label := Label.new()
	rank_label.theme_type_variation = "Caption"
	rank_label.text = str(item.get("rank", {}).get("name", ""))
	row.add_child(rank_label)
	var rating := Label.new()
	rating.text = str(int(item.get("rating", 0)))
	row.add_child(rating)
	return row


func _render_results(history_res: Dictionary) -> void:
	for child in _result_rows.get_children():
		_result_rows.remove_child(child)
		child.queue_free()
	if not App.auth.is_authenticated():
		_result_rows.add_child(_label("Sign in to see your results.", true))
		return
	if not bool(history_res.get("ok", false)):
		_result_rows.add_child(_label("Results unavailable.", true))
		return
	var items: Variant = history_res.body.get("items")
	var arr: Array = items if items is Array else []
	if arr.is_empty():
		_result_rows.add_child(_label("No rated games in this title yet.", true))
		return
	for item in arr:
		if item is Dictionary:
			_result_rows.add_child(_make_result_row(item))


func _make_result_row(item: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var result := Label.new()
	var outcome := str(item.get("result", ""))
	result.text = outcome
	result.custom_minimum_size = Vector2(52, 0)
	result.modulate = AppTheme.C_SUCCESS if outcome == "WIN" \
			else AppTheme.C_DANGER if outcome == "LOSS" else AppTheme.C_TEXT_DISABLED
	row.add_child(result)
	var opponent := Label.new()
	opponent.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var versus := str(item.get("opponent", ""))
	opponent.text = ("vs %s" % versus) if not versus.is_empty() else str(item.get("reason", ""))
	row.add_child(opponent)
	var movement := Label.new()
	var delta := int(item.get("delta", 0))
	movement.text = "%s%d \u2192 %d" % ["+" if delta > 0 else "", delta,
			int(item.get("ratingAfter", 0))]
	row.add_child(movement)
	return row


# --- Small helpers ------------------------------------------------------------

func _label(text: String, caption: bool) -> Label:
	var label := Label.new()
	label.text = text
	if caption:
		label.theme_type_variation = "Caption"
	return label


func _chip(text: String) -> Label:
	var chip := Label.new()
	chip.text = text
	chip.modulate = AppTheme.C_ACCENT
	return chip


func _error_text(res: Dictionary) -> String:
	var kind := int(res.get("error_kind", ApiClient.ErrorKind.NONE))
	if kind == ApiClient.ErrorKind.NETWORK \
			or kind == ApiClient.ErrorKind.SERVER_UNAVAILABLE:
		return "You appear to be offline \u2014 live standings need a connection."
	var message := str(res.get("message", ""))
	return message if not message.is_empty() else "Could not load rankings."

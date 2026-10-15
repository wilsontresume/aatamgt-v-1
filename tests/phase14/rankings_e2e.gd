extends SceneTree
## Phase 14 end-to-end: competitive ranking on a live backend — two
## players complete a rated match (p2 resigns, p1 wins +8), then the
## client reads every surface: leaderboard standing/board/history, tab
## switching across the three rated games, profile rank rows, and a
## duplicate result submission refused by the server.
##
## Run through scripts/run_phase14_e2e.sh, which boots the HTTPS
## server and exports:
##   AATAMGT_API_URL  e.g. https://127.0.0.1:3443
##   AATAMGT_CA_CERT  path to the server's dev certificate
##
## Exit code 0 = all checks passed.

const GAME := "aadu-puli-aattam"

var _checks := 0
var _failures := 0
var _started := false
var _app: Node = null
var _main: Node = null
var _p1_name := ""
var _p2_name := ""
var _p2_token := ""
var _match_id := ""


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run()
	return false


func _run() -> void:
	await _frame()
	_app = get_root().get_node_or_null("/root/App")
	_check(_app != null, "autoload App is registered")
	if _app == null:
		_finish()
		return
	_check(_app.rankings is RankingService, "App exposes the RankingService")
	var base_url := OS.get_environment("AATAMGT_API_URL").strip_edges()
	_check(not base_url.is_empty(), "AATAMGT_API_URL is provided")
	_check(_app.api_client.is_configured(), "api client configured from environment")
	await _check_server_reachable()
	if _failures > 0:
		_finish()
		return

	await _test_complete_a_rated_match()
	if _failures > 0:
		_finish()
		return
	await _test_open_leaderboard_from_menu()
	if _failures > 0:
		_finish()
		return
	await _test_standing_board_and_results()
	await _test_game_tab_switch()
	await _test_duplicate_result_refused()
	await _test_profile_rank_rows()
	await _test_history_endpoint()

	_finish()


# --- Sections ------------------------------------------------------------------

## Registers p1 (session player) and a raw p2, plays out one rated
## match through the REST lifecycle, and checks the server-side
## summary immediately after completion.
func _test_complete_a_rated_match() -> void:
	_p1_name = "rk%d%d" % [Time.get_ticks_msec(), randi() % 10000]
	var reg: Dictionary = await _app.auth.register(_p1_name, "Rank12345!")
	_check(reg.ok, "p1 registers (%s)" % _msg(reg))
	if not reg.ok:
		return
	var got_coins := await _wait_until(
			func() -> bool: return _app.coins.get_balance() == 1000, 8.0)
	_check(got_coins, "p1 receives the 1000-coin welcome")

	_p2_name = "rk%d%d" % [Time.get_ticks_msec() + 1, randi() % 10000]
	var p2_reg: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_POST, "/auth/register",
			{"username": _p2_name, "password": "Rank12345!"})
	_check(p2_reg.ok, "p2 registers without touching the session (%s)" % _msg(p2_reg))
	if not p2_reg.ok:
		return
	_p2_token = str(p2_reg.body.get("accessToken", ""))
	_check(not _p2_token.is_empty(), "p2 receives an access token")

	var p1_token := str(_app.auth.get_access_token())
	_check(not p1_token.is_empty(), "p1 session carries an access token")

	var create: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_POST, "/matches", {"gameKey": GAME}, p1_token)
	_check(create.ok, "p1 creates a rated match (%s)" % _msg(create))
	if not create.ok:
		return
	var match_id := str(create.body.get("id", ""))
	_check(not match_id.is_empty(), "server returns a match id")
	_match_id = match_id

	var join: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_POST, "/matches/%s/join" % match_id, {}, _p2_token)
	_check(join.ok, "p2 joins the match (%s)" % _msg(join))
	if not join.ok:
		return

	var info: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_GET, "/matches/%s" % match_id, {}, p1_token)
	var players: Variant = info.body.get("players") if info.ok else null
	_check(info.ok and str(info.body.get("status", "")) == "ACTIVE",
			"two players flip the match ACTIVE (%s)" % _msg(info))
	_check(players is Array and (players as Array).size() == 2,
			"the match seats both players")

	var resign: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_POST, "/matches/%s/resign" % match_id, {}, _p2_token)
	_check(resign.ok, "p2 resigns — the match completes (%s)" % _msg(resign))
	if not resign.ok:
		return

	var summary: Dictionary = await _app.rankings.summary()
	_check(summary.ok, "p1 reads the ranking summary after completion (%s)" % _msg(summary))
	if not summary.ok:
		return
	var game := _summary_game(summary.body, GAME)
	_check(not game.is_empty(), "summary carries the aadu-puli entry")
	_check(int(game.get("rating", 0)) == 1008,
			"winner is rated 1000 + 8 = 1008 (got %d)" % int(game.get("rating", -1)))
	_check(int(game.get("wins", 0)) == 1, "winner records one win")
	_check(int(game.get("losses", 0)) == 0, "winner records no losses")
	var rank: Dictionary = game.get("rank", {})
	_check(str(rank.get("name", "")) == "Bronze",
			"1008 sits in Bronze (got %s)" % str(rank.get("name", "?")))

	# The loser's mirror image, read through p2's own token.
	var p2_summary: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_GET, "/rankings/summary", {}, _p2_token)
	var p2_game := _summary_game(p2_summary.body, GAME) if p2_summary.ok else {}
	_check(int(p2_game.get("rating", 0)) == 992,
			"loser is rated 1000 - 8 = 992 (got %d)" % int(p2_game.get("rating", -1)))
	_check(int(p2_game.get("losses", 0)) == 1, "loser records one loss")


## Opens the leaderboard through the main menu button — the real
## player path into the screen.
func _test_open_leaderboard_from_menu() -> void:
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	_check(main_scene != null, "main.tscn loads")
	if main_scene == null:
		return
	_main = main_scene.instantiate()
	get_root().add_child(_main)
	var reached := await _wait_until(
			func() -> bool: return _app.navigation.current == &"main_menu", 8.0)
	_check(reached, "splash hands off to the main menu")

	var menu := _screen_named("MainMenu")
	_check(menu != null, "main menu is on screen")
	if menu == null:
		return
	var button: Button = menu.get_node_or_null("Margin/Content/FeaturesRow/RankingsButton")
	_check(button != null, "main menu has a Rankings button")
	if button == null:
		return
	button.pressed.emit()
	_check(_app.navigation.current == &"leaderboard",
			"Rankings button navigates to the leaderboard")

	var loaded := await _wait_until(
			func() -> bool: return _standing_text().contains("1008"), 10.0)
	_check(loaded, "leaderboard loads the signed-in standing (got: %s)"
			% _standing_text())
	var screen := _screen_named("Leaderboard")
	_check(screen != null, "leaderboard screen is on screen")


## The signed-in card, the season header, the board ordering (p1 above
## p2) and the recent-result row — all server numbers.
func _test_standing_board_and_results() -> void:
	var screen := _screen_named("Leaderboard")
	if screen == null:
		return
	var season: Label = screen.get_node("Margin/Content/SeasonLabel")
	_check(season.text.begins_with("Season:"), "season label keeps its prefix")
	_check(not season.text.contains("\u2014"),
			"live season name replaces the offline fallback (got: %s)" % season.text)
	_check(season.text.length() > 9, "season label carries a name")

	var standing := _standing_text()
	_check(standing.contains(_p1_name) or standing.contains("Aadu Puli"),
			"standing names the rated game")
	_check(standing.contains("Bronze"), "standing shows the Bronze chip")
	_check(standing.contains("1008 rating"), "standing shows the 1008 rating")
	_check(standing.contains("1W 0L 0D"), "standing shows the W-L-D record")
	_check(standing.contains("#"), "standing shows a leaderboard position")

	var rows := _child_row_texts("Margin/Content/Scroll/Column/BoardPanel/BoardBody/BoardRows")
	_check(rows.size() >= 2, "the board lists top rated players (got %d rows)" % rows.size())
	# The screen shows only the top-10 page and the dev database
	# accumulates rated users across runs, so both match players are
	# asserted against the full board (limit 100), in order.
	var board: Dictionary = await _app.rankings.leaderboard(GAME, 100)
	_check(board.ok, "full leaderboard reads (%s)" % _msg(board))
	var api_rows := []
	if board.ok:
		for item in board.body.get("items", []):
			if item is Dictionary:
				api_rows.append("%s|%d" % [
					str(item.get("username", "")), int(item.get("rating", 0))])
	var p1_api := _index_containing(api_rows, _p1_name)
	var p2_api := _index_containing(api_rows, _p2_name)
	_check(p1_api >= 0, "full board contains p1's username")
	_check(p2_api >= 0, "full board contains p2's username")
	if p1_api >= 0 and p2_api >= 0:
		_check(p1_api < p2_api,
				"the winner ranks above the loser (p1 #%d, p2 #%d)"
				% [p1_api + 1, p2_api + 1])
		_check(str(api_rows[p1_api]).contains("1008"),
				"p1's board row shows 1008")
		_check(str(api_rows[p2_api]).contains("992"),
				"p2's board row shows 992")

	var results := _joined_row_text(
			"Margin/Content/Scroll/Column/ResultsPanel/ResultsBody/ResultRows")
	_check(results.contains("WIN"), "recent results show the WIN")
	_check(results.contains("vs %s" % _p2_name),
			"recent results name the opponent")
	_check(results.contains("+8 \u2192 1008"),
			"recent results show the delta and new rating")

	var hint: Label = screen.get_node("Margin/Content/HintLabel")
	_check(not hint.visible, "no failure hint with a healthy backend")


## The other rated titles show a fresh player's defaults, not the
## aadu-puli numbers.
func _test_game_tab_switch() -> void:
	var screen := _screen_named("Leaderboard")
	if screen == null:
		return
	var tabs: Node = screen.get_node("Margin/Content/GameTabs")
	var soldiers: Button = tabs.get_node_or_null("SoldiersTab")
	var aadu: Button = tabs.get_node_or_null("AaduPuliTab")
	if soldiers == null or aadu == null:
		_check(false, "game tabs exist for switching")
		return
	soldiers.pressed.emit()
	var switched := await _wait_until(
			func() -> bool: return _standing_text().contains("1000 rating"), 10.0)
	_check(switched, "16 Soldiers tab loads a fresh 1000 rating (got: %s)"
			% _standing_text())
	_check(_standing_text().contains("0W 0L 0D"),
			"16 Soldiers record starts empty")
	aadu.pressed.emit()
	var back := await _wait_until(
			func() -> bool: return _standing_text().contains("1008"), 10.0)
	_check(back, "returning to Aadu Puli restores the 1008 standing")


## The server owns the result: a second resign for the same match is
## refused and the ratings stay put.
func _test_duplicate_result_refused() -> void:
	var again: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_POST, "/matches/%s/resign" % _match_id, {}, _p2_token)
	_check(not again.ok, "duplicate completion is refused (%s)" % _msg(again))
	_check(int(again.get("status", 0)) >= 400 and int(again.get("status", 0)) < 500,
			"refusal is a 4xx (got %d)" % int(again.get("status", 0)))
	var summary: Dictionary = await _app.rankings.summary()
	var game := _summary_game(summary.body, GAME) if summary.ok else {}
	_check(int(game.get("rating", 0)) == 1008,
			"rating unchanged after the duplicate attempt")
	_check(int(game.get("wins", 0)) == 1, "win count unchanged after the duplicate attempt")


## The profile's Competitive section reads the same server summary —
## one row per rated game, in order.
func _test_profile_rank_rows() -> void:
	_app.navigation.go(&"profile")
	var ready := await _wait_until(
			func() -> bool: return _screen_named("Profile") != null, 6.0)
	_check(ready, "profile screen opens")
	var rows_ready := await _wait_until(_profile_row_count.bind(true), 10.0)
	_check(rows_ready, "profile renders one rank row per rated game")
	var profile := _screen_named("Profile")
	if profile == null:
		return
	var rows: VBoxContainer = profile.get_node("Margin/Content/RankRows")
	_check(rows.get_child_count() == 3, "three rated games listed (got %d)"
			% rows.get_child_count())
	if rows.get_child_count() == 0:
		return
	var first := _labels_text(rows.get_child(0))
	_check(first.contains("Aadu Puli"), "first row is Aadu Puli (got: %s)" % first)
	_check(first.contains("Bronze"), "first row shows the Bronze rank")
	_check(first.contains("1008"), "first row shows the 1008 rating")
	_check(first.contains("1W-0L"), "first row shows the 1W-0L record")


## GET /rankings/history carries the completed match with opponent,
## outcome, delta and season — before the screen ever renders it.
func _test_history_endpoint() -> void:
	var res: Dictionary = await _app.rankings.history(20, GAME)
	_check(res.ok, "history endpoint answers (%s)" % _msg(res))
	if not res.ok:
		return
	var items: Variant = res.body.get("items")
	_check(items is Array and (items as Array).size() >= 1,
			"history carries the completed match")
	if not (items is Array) or (items as Array).is_empty():
		return
	var entry: Dictionary = (items as Array)[0]
	_check(str(entry.get("result", "")) == "WIN", "history entry records the WIN")
	_check(int(entry.get("delta", 0)) == 8, "history entry shows +8")
	_check(int(entry.get("ratingAfter", 0)) == 1008, "history entry ends at 1008")
	_check(str(entry.get("opponent", "")) == _p2_name,
			"history entry names p2 as the opponent (got %s)"
			% str(entry.get("opponent", "")))
	_check(not str(entry.get("seasonKey", "")).is_empty(),
			"history entry carries a season")


# --- Helpers --------------------------------------------------------------------

func _check_server_reachable() -> void:
	var res: Dictionary = await _app.api_client.request_json(
			HTTPClient.METHOD_GET, "/profiles/me")
	var transport_failure: bool = (res.error_kind == ApiClient.ErrorKind.NETWORK
			or res.error_kind == ApiClient.ErrorKind.SERVER_UNAVAILABLE)
	_check(not transport_failure, "backend reachable over HTTPS (%s)" % _msg(res))
	_check(_app.network.get_status() == NetworkService.Status.CONNECTED,
			"network reports online after the reachability call")


func _screen_named(root_name: String) -> Control:
	if _main == null:
		return null
	var container: Control = _main.get_node("ScreenLayer/ScreenContainer")
	for child in container.get_children():
		if child.name == root_name:
			return child
	return null


## Live text of the signed-in standing row.
func _standing_text() -> String:
	var screen := _screen_named("Leaderboard")
	if screen == null:
		return ""
	var row: Node = screen.get_node_or_null(
			"Margin/Content/Scroll/Column/StandingPanel/StandingBody/StandingRow")
	if row == null:
		return ""
	return _labels_text(row)


func _child_row_texts(path: String) -> Array:
	var screen := _screen_named("Leaderboard")
	var out := []
	if screen == null:
		return out
	var container: Node = screen.get_node_or_null(path)
	if container == null:
		return out
	for child in container.get_children():
		out.append(_labels_text(child))
	return out


func _joined_row_text(path: String) -> String:
	return " | ".join(PackedStringArray(_child_row_texts(path)))


func _index_containing(rows: Array, needle: String) -> int:
	for i in rows.size():
		if str(rows[i]).contains(needle):
			return i
	return -1


func _labels_text(node: Node) -> String:
	var parts := PackedStringArray()
	_collect_labels(node, parts)
	return " | ".join(parts)


func _collect_labels(node: Node, parts: PackedStringArray) -> void:
	for child in node.get_children():
		if child is Label:
			parts.append((child as Label).text)
		else:
			_collect_labels(child, parts)


func _summary_game(body: Dictionary, game_key: String) -> Dictionary:
	if body == null:
		return {}
	for entry in body.get("games", []):
		if entry is Dictionary and str(entry.get("gameKey", "")) == game_key:
			return entry
	return {}


func _profile_row_count(want_three: bool) -> bool:
	var profile := _screen_named("Profile")
	if profile == null:
		return false
	var rows: Node = profile.get_node_or_null("Margin/Content/RankRows")
	if rows == null:
		return false
	if not want_three:
		return rows.get_child_count() > 0
	return rows.get_child_count() >= 3


func _msg(res: Dictionary) -> String:
	if res.get("ok", false):
		return "ok"
	var message := str(res.get("message", res.get("error", "")))
	return "failed: %s (status %d)" % [message, int(res.get("status", 0))]


func _wait_until(predicate: Callable, timeout_sec: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await create_timer(0.15).timeout
	return predicate.call()


func _frame() -> void:
	await process_frame


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		printerr("FAIL: ", label)


func _finish() -> void:
	print("RANKINGS E2E: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)

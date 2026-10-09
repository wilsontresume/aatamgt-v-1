extends SceneTree
## Phase 12 sample game: a human play session on a live backend.
##
## 1. Registers a player (1000-coin welcome) and acquires cosmetics
##    through the real inventory UI: claim the free Woodland board and
##    Flash capture effect, buy the premium Fireworks victory effect
##    (350 coins through the wallet), and equip all three.
## 2. Opens Aadu Puli Aattam and plays a game against the AI through
##    the board's own point-activation path (the same input a tap
##    takes), verifying the equipped skin is on the board.
## 3. Switches to hot-seat and plays a second game to a decided
##    result — feeding tigers captures — verifying the capture and
##    victory cosmetic effects fire during real play.
##
## Run through scripts/run_phase12_sample.sh (boots HTTPS server).
## Exit code 0 = all checks passed.

const POINT_COUNT := AaduPuliGameState.POINT_COUNT

var _checks := 0
var _failures := 0
var _started := false
var _app: Node = null
var _main: Node = null
var _rejected: Dictionary = {}


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
	var base_url := OS.get_environment("AATAMGT_API_URL").strip_edges()
	_check(not base_url.is_empty(), "AATAMGT_API_URL is provided")
	_check(_app.api_client.is_configured(), "api client configured from environment")
	await _check_server_reachable()
	if _failures > 0:
		_finish()
		return

	# Start from a clean slate: no stored session, no half-played game.
	for file_name in ["session.json", "aadu_puli_save.json"]:
		if FileAccess.file_exists("user://%s" % file_name):
			var user_dir := DirAccess.open("user://")
			if user_dir != null:
				user_dir.remove(file_name)

	await _setup_cosmetics()
	if _failures > 0:
		_finish()
		return
	await _play_against_ai()
	await _play_hotseat_to_result()

	_finish()


# --- Cosmetics setup ---------------------------------------------------------

## Registers, opens the inventory, and acquires/equips three cosmetics
## through the real buttons: Woodland board (free claim), Flash capture
## (free claim), Fireworks victory (premium purchase).
func _setup_cosmetics() -> void:
	var username := "play%d%d" % [Time.get_ticks_msec(), randi() % 10000]
	var reg: Dictionary = await _app.auth.register(username, "Cos12345!")
	_check(reg.ok, "player registers for the welcome bonus (%s)" % _msg(reg))
	if not reg.ok:
		return
	var got_coins := await _wait_until(
			func() -> bool: return _app.coins.get_balance() == 1000, 8.0)
	_check(got_coins, "registration bonus lands (1000 coins)")

	var main_scene: PackedScene = load("res://scenes/main.tscn")
	_check(main_scene != null, "main.tscn loads")
	if main_scene == null:
		return
	_main = main_scene.instantiate()
	get_root().add_child(_main)
	var reached := await _wait_until(
			func() -> bool: return _app.navigation.current == &"main_menu", 8.0)
	_check(reached, "splash hands off to the main menu")

	_app.navigation.go(&"inventory")
	var sections_ready := await _wait_until(
			func() -> bool: return _section_count(_screen_named("Inventory")) == 5,
			10.0)
	_check(sections_ready, "five category sections render")

	await _acquire_item("Woodland Board", "Claim")
	await _acquire_item("Flash", "Claim")
	await _acquire_item("Fireworks", "Buy")
	_check(_app.coins.get_balance() == 650,
			"premium purchase debits 350 coins (1000 -> 650)")


## Claims or buys the named row, then equips it. Verifies the state
## chip progression through the visible row text.
func _acquire_item(item_name: String, action: String) -> void:
	var screen := _screen_named("Inventory")
	if screen == null:
		_check(false, "%s row visible for %s" % [item_name, action])
		return
	var row := _find_row(screen, item_name)
	_check(row != null, "%s row exists" % item_name)
	if row == null:
		return
	var button := _find_button(row, action)
	_check(button != null, "%s offers %s" % [item_name, action])
	if button == null:
		return
	var before_balance: int = _app.coins.get_balance()
	button.pressed.emit()
	var owned := await _wait_until(_acquired_or_equipped.bind(item_name), 10.0)
	_check(owned, "%s becomes owned" % item_name)
	if action == "Buy":
		var charged := await _wait_until(
				func() -> bool: return _app.coins.get_balance() == before_balance - 350,
				8.0)
		_check(charged, "%s purchase moves the wallet" % item_name)
	var equip := _find_button(_find_row(screen, item_name), "Equip")
	_check(equip != null, "%s offers Equip once owned" % item_name)
	if equip == null:
		return
	equip.pressed.emit()
	var equipped := await _wait_until(
			func() -> bool: return _row_contains(item_name, "Equipped"), 10.0)
	_check(equipped, "%s is equipped" % item_name)


func _row_contains(item_name: String, needle: String) -> bool:
	var screen := _screen_named("Inventory")
	if screen == null:
		return false
	return _row_text(_find_row(screen, item_name)).contains(needle)


func _acquired_or_equipped(item_name: String) -> bool:
	return _row_contains(item_name, "Owned") or _row_contains(item_name, "Equipped")


func _ai_turn_over(game: Node) -> bool:
	return game._state.side_to_move == AaduPuliGameState.Side.GOATS \
			or game._state.is_terminal()


func _history_at_least(game: Node, size: int) -> bool:
	return game._history.size() >= size or game._state.is_terminal()


# --- Game 1: against the AI ---------------------------------------------------

func _play_against_ai() -> void:
	_app.navigation.go(&"aadu_puli")
	var ready := await _wait_until(
			func() -> bool: return _screen_named("AaduPuliScreen") != null, 6.0)
	_check(ready, "aadu puli screen opens")
	var game := _screen_named("AaduPuliScreen")
	if game == null:
		return

	var board: Variant = game.get_node("Margin/Content/Board")
	_check(not board.skin.is_empty()
			and board.skin.get("bg", Color(0, 0, 0)) == Color("1d2a1e"),
			"equipped woodland skin is on the board")

	game._set_ai_mode(true)
	game._set_difficulty(AaduPuliAI.Difficulty.EASY)
	await _frame()
	_check(game._ai_mode, "playing against the AI")

	var exchanges := 0
	var my_moves := 0
	while exchanges < 4 and my_moves < 24 and not game._state.is_terminal():
		if game._state.side_to_move != AaduPuliGameState.Side.GOATS:
			# AI mid-turn (its reply usually lands within a frame).
			var settled := await _wait_until(_ai_turn_over.bind(game), 30.0)
			if not settled:
				break
			continue
		var seen: int = game._history.size()
		var move := _goat_move(game._state, false)
		if move == null or not _apply_ui(game, move):
			break
		my_moves += 1
		# Mine records history +1; the AI's answer records another +1.
		var replied := await _wait_until(
				_history_at_least.bind(game, seen + 2), 30.0)
		if not replied:
			break
		exchanges += 1
		await _frame()

	_check(exchanges >= 3,
			"AI answers each of my moves (%d exchanges)" % exchanges)
	_check(game._history.size() >= 6,
			"moves are recorded (%d in history)" % game._history.size())
	_check(not game._state.is_terminal(),
			"still playing after the friendly opening")
	_check(game._status_label.text.length() > 0, "status line reports the turn")
	print("INFO: after %d of my moves — goats in hand %d, side to move %d"
			% [my_moves, game._state.goats_in_hand, game._state.side_to_move])


# --- Game 2: hot seat to a decided result --------------------------------------

func _play_hotseat_to_result() -> void:
	var game := _screen_named("AaduPuliScreen")
	if game == null:
		return
	# Fresh position, no AI: I play both sides.
	game._cancel_ai()
	game._state = AaduPuliGameState.initial()
	game._history.clear()
	game._notation_history.clear()
	game._last_notation = ""
	game._selected = -1
	game._fx_seen_captures = -1
	_rejected = {}
	game._set_ai_mode(false)
	game._save()
	game._refresh()
	await _frame()
	_check(not game._ai_mode, "hot-seat mode: I play both sides")

	var capture_fx_hits := 0
	var plies := 0
	while plies < 80 and not game._state.is_terminal():
		var state: AaduPuliGameState = game._state
		var move: AaduPuliMove = null
		if state.side_to_move == AaduPuliGameState.Side.TIGERS:
			move = _tiger_move(state)
		else:
			move = _goat_move(state, true)
		if move == null:
			break
		var captures_before := state.goats_captured
		if not _apply_ui(game, move):
			_rejected[str(move.notation())] = true
			plies += 1
			await _frame()
			continue
		plies += 1
		await _frame()
		if game._state.goats_captured > captures_before \
				and _z_count(game._board, 40) > 0:
			capture_fx_hits += 1

	_check(game._state.is_terminal(),
			"the game reaches a result (%d plies)" % plies)
	_check(game._state.result == AaduPuliGameState.Result.TIGERS_WIN,
			"tigers win by five captures (result=%d)" % game._state.result)
	_check(game._state.goats_captured == AaduPuliGameState.CAPTURES_TO_WIN,
			"exactly five goats were caught")
	_check(capture_fx_hits >= 3,
			"capture effect fired during play (%d times)" % capture_fx_hits)

	await _frame()
	_check(_z_count(game, 50) > 0,
			"victory effect overlay appears on the win")
	_check(CosmeticService.victory_style(
			_app.cosmetics.equipped_key("VICTORY_ANIMATION")).get("kind", "")
			== "fireworks", "fireworks victory style is the equipped one")
	_check(CosmeticService.capture_style(
			_app.cosmetics.equipped_key("CAPTURE_ANIMATION")).get("kind", "")
			== "flash", "flash capture style is the equipped one")

	var error_dialog: Variant = _app.dialog.get("_error_dialog")
	_check(error_dialog != null and error_dialog.visible,
			"result dialog announces the outcome")
	if error_dialog != null and error_dialog.visible:
		var title := str(error_dialog.get("_title_label").text)
		_check(title.contains("Tigers win"), "dialog title matches (%s)" % title)
		error_dialog.close()
	print("INFO: finished game — %d captures, result %d"
			% [game._state.goats_captured, game._state.result])


# --- Move policies --------------------------------------------------------------

## My goats: when hungry (hot seat) I feed the tigers a capturable
## piece; when friendly (vs AI) I place away from jump lines.
func _goat_move(state: AaduPuliGameState, hungry: bool) -> AaduPuliMove:
	var moves := AaduPuliRules.legal_moves(state)
	if moves.is_empty():
		return null
	if state.goats_in_hand == 0:
		return moves[0]
	var best: AaduPuliMove = null
	var best_score := -9999
	for move in moves:
		if _rejected.has(str(move.notation())):
			continue
		var score := _enabled_captures(state, move.to_point)
		if hungry and score == 0:
			score = -1  # legal but useless — prefer any enabled line
		if (hungry and score > best_score) or (not hungry and score < best_score):
			best = move
			best_score = score
	return best if best != null else moves[0]


## Tigers take a capture whenever one exists, otherwise step toward
## the nearest goat to stay in the hunt.
func _tiger_move(state: AaduPuliGameState) -> AaduPuliMove:
	var moves := AaduPuliRules.legal_moves(state)
	if moves.is_empty():
		return null
	for move in moves:
		if move.is_capture():
			return move
	var best: AaduPuliMove = null
	var best_distance := 9999
	var goats := state.goat_points()
	for move in moves:
		if _rejected.has(str(move.notation())):
			continue
		var distance := _nearest_distance(move.to_point, goats)
		if distance < best_distance:
			best = move
			best_distance = distance
	return best if best != null else moves[0]


## How many tiger jumps a goat placed on `point` would unlock.
func _enabled_captures(state: AaduPuliGameState, point: int) -> int:
	var total := 0
	for tiger in state.tiger_points():
		for landing in range(POINT_COUNT):
			if not state.is_empty(landing):
				continue
			if AaduPuliRules.is_jump_line(tiger, point, landing) \
					or AaduPuliRules.is_jump_line(landing, point, tiger):
				total += 1
	return total


## BFS distance over the board graph from `from_point` to the nearest
## point in `targets` (tigers walk toward prey).
func _nearest_distance(from_point: int, targets: Array) -> int:
	if targets.has(from_point):
		return 0
	var visited := {from_point: true}
	var frontier := [from_point]
	var distance := 0
	while not frontier.is_empty():
		distance += 1
		var next: Array = []
		for point in frontier:
			for neighbor in AaduPuliRules.neighbors(point):
				if visited.has(neighbor):
					continue
				visited[neighbor] = true
				if targets.has(neighbor):
					return distance
				next.append(neighbor)
		frontier = next
	return 9999


## Feeds a move through the screen's own input path (the same
## point-activated signal a tap on the board emits). Returns true when
## the position advanced.
func _apply_ui(game: Node, move: AaduPuliMove) -> bool:
	var before := int(game._state.ply)
	if move.kind == AaduPuliMove.Kind.PLACE:
		game._on_point_activated(move.to_point)
	else:
		game._on_point_activated(move.from_point)
		game._on_point_activated(move.to_point)
	if game._state.ply > before:
		return true
	# A rejected attempt may have left the illegal-move dialog up.
	var error_dialog: Variant = _app.dialog.get("_error_dialog")
	if error_dialog != null and error_dialog.visible:
		error_dialog.close()
	return false


func _z_count(node: Node, z: int) -> int:
	var found := 0
	for child in node.get_children():
		if child is CanvasItem and (child as CanvasItem).z_index == z:
			found += 1
	return found


# --- Infrastructure (shared with cosmetics_e2e) ---------------------------------

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


func _section_count(screen: Control) -> int:
	if screen == null:
		return -1
	var sections: Node = screen.get_node_or_null("Margin/Content/Scroll/Sections")
	if sections == null:
		return -1
	return sections.get_child_count()


func _find_row(root: Node, label_text: String) -> Node:
	if root == null:
		return null
	for child in root.get_children():
		if child is HBoxContainer:
			var parts := PackedStringArray()
			_collect_labels(child, parts)
			if parts.has(label_text):
				return child
		var nested := _find_row(child, label_text)
		if nested != null:
			return nested
	return null


func _row_text(row: Node) -> String:
	if row == null:
		return ""
	var parts := PackedStringArray()
	_collect_all(row, parts)
	return " | ".join(parts)


func _collect_labels(node: Node, parts: PackedStringArray) -> void:
	for child in node.get_children():
		if child is Label:
			parts.append((child as Label).text)
		else:
			_collect_labels(child, parts)


func _collect_all(node: Node, parts: PackedStringArray) -> void:
	for child in node.get_children():
		if child is Label:
			parts.append((child as Label).text)
		elif child is Button:
			parts.append((child as Button).text)
		else:
			_collect_all(child, parts)


func _find_button(parent: Node, text: String) -> Button:
	if parent == null:
		return null
	for child in parent.get_children():
		if child is Button and (child as Button).text == text:
			return child
		if not (child is Label):
			var nested := _find_button(child, text)
			if nested != null:
				return nested
	return null


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
	print("SAMPLE GAME: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)

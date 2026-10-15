class_name SolahSeediBoard
extends Control
## Read-only view of a Solah Seedi (16 Soldiers) position. Draws the
## chart, the pieces and the interactive highlights, and reports taps.
## The board holds no rules: the screen owns the state and hands over
## the pending route plus the legal next points to highlight.

signal point_activated(point: int)

## Normalised chart geometry (docs/salah_seedi_rules.md Appendix A),
## measured on the reference diagram of 643×1200 with square pixel
## cells: x is a fraction of the width, y of the height.
const REFERENCE := Vector2(643.0, 1200.0)
const LAYOUT := {
	0: Vector2(0.072, 0.040), 1: Vector2(0.499, 0.040), 2: Vector2(0.928, 0.040),
	3: Vector2(0.267, 0.145), 4: Vector2(0.499, 0.145), 5: Vector2(0.734, 0.145),
	6: Vector2(0.073, 0.270), 7: Vector2(0.285, 0.270), 8: Vector2(0.499, 0.270),
	9: Vector2(0.714, 0.270), 10: Vector2(0.928, 0.270),
	11: Vector2(0.073, 0.385), 12: Vector2(0.285, 0.385), 13: Vector2(0.499, 0.385),
	14: Vector2(0.714, 0.385), 15: Vector2(0.928, 0.385),
	16: Vector2(0.073, 0.497), 17: Vector2(0.285, 0.497), 18: Vector2(0.499, 0.497),
	19: Vector2(0.714, 0.497), 20: Vector2(0.928, 0.497),
	21: Vector2(0.073, 0.613), 22: Vector2(0.285, 0.613), 23: Vector2(0.499, 0.613),
	24: Vector2(0.714, 0.613), 25: Vector2(0.928, 0.613),
	26: Vector2(0.073, 0.728), 27: Vector2(0.285, 0.728), 28: Vector2(0.499, 0.728),
	29: Vector2(0.714, 0.728), 30: Vector2(0.928, 0.728),
	31: Vector2(0.267, 0.854), 32: Vector2(0.501, 0.854), 33: Vector2(0.734, 0.854),
	34: Vector2(0.073, 0.959), 35: Vector2(0.499, 0.959), 36: Vector2(0.928, 0.959),
}

const R_DOT := 5.0
const R_PIECE := 12.0
const R_TARGET := 12.0
const R_SELECT := 15.0

# --- Piece inks ----------------------------------------------------------
# Lacquered soldier discs: the army hues stay gameplay-legible, each
# carrying a small gold/bone chevron — the mark of a soldier's rank.
const RED_DISC := Color("e5484d")
const RED_CHEVRON := Color("ffd9a0")
const GREEN_DISC := Color("46a758")
const GREEN_CHEVRON := Color("eaf5d8")

var state: SolahSeediGameState = null
var selection: int = -1
var target_points: Array[int] = []
## The route built so far (origin first); drawn as a line through the
## hops the player has already chosen.
var path_points: Array[int] = []
## Phase 12: equipped board-skin palette from App.cosmetics
## ({} = classic surface).
var skin := {}

# --- Animation state (visual only, never blocks input) --------------------
var _pulse_t := 0.0
var _move_anim_t := 0.0
var _move_from := -1
var _move_to := -1
var _move_is_red := false
var _flash_t := 0.0
var _flash_point := -1
var _prev_board: Array[int] = []


func set_skin(palette: Dictionary) -> void:
	skin = palette if palette != null else {}
	queue_redraw()


func configure(p_state: SolahSeediGameState, p_selection: int,
		p_targets: Array[int], p_path: Array[int]) -> void:
	_detect_move(p_state)
	state = p_state
	selection = p_selection
	target_points = p_targets
	path_points = p_path
	queue_redraw()


## Diff the previous board against the new one to find a single piece
## that left one point and arrived at another — the mover to animate.
func _detect_move(p_state: SolahSeediGameState) -> void:
	if p_state == null or _prev_board.size() != SolahSeediGameState.POINT_COUNT:
		_prev_board = p_state.board.duplicate() if p_state != null else []
		return
	var from := -1
	var to := -1
	var moves := 0
	for i in SolahSeediGameState.POINT_COUNT:
		var was: int = _prev_board[i]
		var now: int = p_state.board[i]
		if was != now:
			moves += 1
			if was != 0 and now == 0 and from < 0:
				from = i
			if was == 0 and now != 0 and to < 0:
				to = i
	if moves == 2 and from >= 0 and to >= 0:
		_move_from = from
		_move_to = to
		_move_is_red = p_state.board[to] == SolahSeediGameState.Cell.RED
		_move_anim_t = 1.0
		set_process(true)
	_prev_board = p_state.board.duplicate()


## Red flash ring on an illegal tap. Purely visual.
func flash_invalid(point: int) -> void:
	if point < 0:
		return
	_flash_point = point
	_flash_t = 1.0
	set_process(true)


func _process(delta: float) -> void:
	var animating := false
	_pulse_t = fmod(_pulse_t + delta * 2.2, 1.0)
	if _move_anim_t > 0.0:
		_move_anim_t = maxf(_move_anim_t - delta * 3.2, 0.0)
		animating = true
	if _flash_t > 0.0:
		_flash_t = maxf(_flash_t - delta * 2.5, 0.0)
		animating = true
	if selection >= 0 or not target_points.is_empty() or path_points.size() >= 2:
		animating = true
	if not animating:
		set_process(false)
	queue_redraw()


## Returns the point under `pos`, or -1 when the tap is off the chart.
func point_at(pos: Vector2) -> int:
	var best := -1
	var best_distance := _hit_radius()
	for point in SolahSeediGameState.POINT_COUNT:
		var distance := pos.distance_to(_screen_pos(point))
		if distance <= best_distance:
			best_distance = distance
			best = point
	return best


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var point := point_at(event.position)
		if point >= 0:
			point_activated.emit(point)


func _draw() -> void:
	_draw_panel()
	_draw_lines()
	for point in SolahSeediGameState.POINT_COUNT:
		_draw_point(point)
	_draw_route()
	_draw_targets()
	_draw_move_ghost()
	_draw_selection()
	_draw_flash()


# --- Geometry -----------------------------------------------------------

func _chart() -> Vector2:
	var pad := 30.0
	var area := Vector2(size.x - 2.0 * pad, size.y - 2.0 * pad)
	if area.x <= 0.0 or area.y <= 0.0:
		return Vector2.ONE
	var scale := minf(area.x / REFERENCE.x, area.y / REFERENCE.y)
	return REFERENCE * scale


func _origin(chart: Vector2) -> Vector2:
	# Centre the tall chart; the width usually has slack to spare.
	return Vector2((size.x - chart.x) * 0.5, (size.y - chart.y) * 0.5)


func _screen_pos(point: int) -> Vector2:
	var chart := _chart()
	var unit: Vector2 = LAYOUT[point]
	return _origin(chart) + Vector2(unit.x * chart.x, unit.y * chart.y)


func _hit_radius() -> float:
	return clampf(minf(_chart().x, _chart().y) * 0.045, 14.0, 30.0)


# --- Painting -----------------------------------------------------------

func _draw_panel() -> void:
	BoardArt.panel(self, skin)


func _draw_lines() -> void:
	var line_color: Color = skin.get("line", AppTheme.C_BOARD_LINE)
	for line in SolahSeediRules.LINES:
		var points := PackedVector2Array()
		for point in line:
			points.append(_screen_pos(int(point)))
		BoardArt.groove_polyline(self, points, line_color, 2.0)


func _draw_point(point: int) -> void:
	var at := _screen_pos(point)
	if state == null or state.is_empty(point):
		BoardArt.socket(self, at, R_DOT + 1.0, skin)
		return
	if state.cell(point) == SolahSeediGameState.Cell.RED:
		_draw_soldier(at, RED_DISC, RED_CHEVRON)
	else:
		_draw_soldier(at, GREEN_DISC, GREEN_CHEVRON)


## A soldier's marker: lacquer disc + upward chevron insignia.
func _draw_soldier(at: Vector2, disc_color: Color, ink: Color) -> void:
	BoardArt.disc(self, at, R_PIECE, disc_color)
	var r := R_PIECE * 0.86
	BoardArt.stripe(self, at, r, Vector2(-0.42, 0.10), Vector2(0.0, -0.30),
			ink, 0.16)
	BoardArt.stripe(self, at, r, Vector2(0.0, -0.30), Vector2(0.42, 0.10),
			ink, 0.16)
	BoardArt.stripe(self, at, r, Vector2(-0.26, 0.32), Vector2(0.0, -0.04),
			ink.darkened(0.2), 0.12)
	BoardArt.stripe(self, at, r, Vector2(0.0, -0.04), Vector2(0.26, 0.32),
			ink.darkened(0.2), 0.12)


func _draw_route() -> void:
	if path_points.size() < 2:
		return
	var points := PackedVector2Array()
	for point in path_points:
		points.append(_screen_pos(int(point)))
	draw_polyline(points, AppTheme.C_ACCENT, 4.0, true)
	for i in range(1, path_points.size()):
		draw_circle(_screen_pos(int(path_points[i])), R_DOT + 2.0,
				AppTheme.C_ACCENT)


func _draw_targets() -> void:
	for point in target_points:
		BoardArt.move_glow(self, _screen_pos(point), R_TARGET, _pulse_t)


func _draw_move_ghost() -> void:
	if _move_anim_t <= 0.0 or _move_from < 0 or _move_to < 0 or state == null:
		return
	var t := 1.0 - _move_anim_t
	var eased := t * t * (3.0 - 2.0 * t)
	var from := _screen_pos(_move_from)
	var to := _screen_pos(_move_to)
	var at := from.lerp(to, eased)
	if _move_is_red:
		_draw_soldier(at, RED_DISC, RED_CHEVRON)
	else:
		_draw_soldier(at, GREEN_DISC, GREEN_CHEVRON)


func _draw_flash() -> void:
	if _flash_t <= 0.0 or _flash_point < 0:
		return
	BoardArt.flash_ring(self, _screen_pos(_flash_point), R_SELECT, _flash_t)


func _draw_selection() -> void:
	if selection < 0:
		return
	BoardArt.pulse_ring(self, _screen_pos(selection), R_SELECT, _pulse_t)

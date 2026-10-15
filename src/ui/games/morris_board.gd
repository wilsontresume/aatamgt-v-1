class_name MorrisBoard
extends Control
## Read-only view of a Nine Men's Morris position. Draws the three
## squares, the spokes, the pieces and the interactive highlights, and
## reports taps. The board holds no rules: the screen owns the state
## and hands over the selection, the legal landings and the capture
## choices to highlight. Visual layer only — animations never gate
## input or delay authoritative state application.

signal point_activated(point: int)

## Normalised board geometry: the classic three nested squares with
## the four mid-side spokes, on a 1000×1000 reference. Outer ring 0-7
## clockwise from the top-left, middle ring 8-15, inner ring 16-23,
## centre-mid points of each side complete the spokes (spec §2).
const REFERENCE := Vector2(1000.0, 1000.0)
const LAYOUT := {
	0: Vector2(0.05, 0.05), 1: Vector2(0.50, 0.05), 2: Vector2(0.95, 0.05),
	3: Vector2(0.95, 0.50), 4: Vector2(0.95, 0.95), 5: Vector2(0.50, 0.95),
	6: Vector2(0.05, 0.95), 7: Vector2(0.05, 0.50),
	8: Vector2(0.25, 0.25), 9: Vector2(0.50, 0.25), 10: Vector2(0.75, 0.25),
	11: Vector2(0.75, 0.50), 12: Vector2(0.75, 0.75), 13: Vector2(0.50, 0.75),
	14: Vector2(0.25, 0.75), 15: Vector2(0.25, 0.50),
	16: Vector2(0.40, 0.40), 17: Vector2(0.50, 0.40), 18: Vector2(0.60, 0.40),
	19: Vector2(0.60, 0.50), 20: Vector2(0.60, 0.60), 21: Vector2(0.50, 0.60),
	22: Vector2(0.40, 0.60), 23: Vector2(0.40, 0.50),
}

var state: NineMensMorrisGameState = null
var selection: int = -1
var target_points: Array[int] = []
var capture_points: Array[int] = []
## Phase 12: equipped board-skin palette from App.cosmetics
## ({} = classic surface).
var skin := {}

# --- Piece inks ----------------------------------------------------------
# Turned-wood lacquer discs: army hues stay gameplay-legible, each
# pressed with a concentric ring — the lathe mark of a classic set.
const RED_DISC := Color("e5484d")
const GREEN_DISC := Color("46a758")
const RED_RIM := Color("8c1d21")
const GREEN_RIM := Color("1e5c28")

# --- Animation state (visual only, never blocks input) --------------------
var _pulse_t := 0.0
var _move_anim_t := 0.0
var _move_from := -1
var _move_to := -1
var _move_cell := 0
var _flash_t := 0.0
var _flash_point := -1
var _burst_t := 0.0
var _burst_point := -1
var _prev_board: Array[int] = []


func set_skin(palette: Dictionary) -> void:
	skin = palette if palette != null else {}
	queue_redraw()


func configure(p_state: NineMensMorrisGameState, p_selection: int,
		p_targets: Array[int], p_captures: Array[int]) -> void:
	_detect_move(p_state)
	_detect_mill(p_captures)
	state = p_state
	selection = p_selection
	target_points = p_targets
	capture_points = p_captures
	queue_redraw()


## Diff the previous board against the new one to find a single piece
## that left one point and arrived at another — the mover to animate.
func _detect_move(p_state: NineMensMorrisGameState) -> void:
	if p_state == null or _prev_board.size() != NineMensMorrisGameState.POINT_COUNT:
		_prev_board = p_state.board.duplicate() if p_state != null else []
		return
	var from := -1
	var to := -1
	var moves := 0
	for i in NineMensMorrisGameState.POINT_COUNT:
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
		_move_cell = p_state.board[to]
		_move_anim_t = 1.0
		_start_process()
	_prev_board = p_state.board.duplicate()


## A mill just opened (capture choices appeared) — gold burst.
func _detect_mill(p_captures: Array[int]) -> void:
	if not capture_points.is_empty() and p_captures.is_empty():
		return
	if capture_points.is_empty() and not p_captures.is_empty() \
			and selection >= 0:
		_burst_point = selection
		_burst_t = 1.0
		_start_process()


## Red flash ring on an illegal tap. Purely visual.
func flash_invalid(point: int) -> void:
	if point < 0:
		return
	_flash_point = point
	_flash_t = 1.0
	_start_process()


func _start_process() -> void:
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
	if _burst_t > 0.0:
		_burst_t = maxf(_burst_t - delta * 1.6, 0.0)
		animating = true
	if selection >= 0 or not target_points.is_empty() or not capture_points.is_empty():
		animating = true
	if not animating and _move_anim_t <= 0.0 and _flash_t <= 0.0 and _burst_t <= 0.0:
		set_process(false)
	queue_redraw()


## Returns the point under `pos`, or -1 when the tap is off the board.
func point_at(pos: Vector2) -> int:
	var best := -1
	var best_distance := _hit_radius()
	for point in NineMensMorrisGameState.POINT_COUNT:
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
	_draw_edges()
	for point in NineMensMorrisGameState.POINT_COUNT:
		_draw_point(point)
	_draw_targets()
	_draw_captures()
	_draw_selection()
	_draw_move_ghost()
	_draw_flash()
	_draw_burst()


# --- Geometry -----------------------------------------------------------

func _chart() -> Vector2:
	var pad := 30.0
	var area := Vector2(size.x - 2.0 * pad, size.y - 2.0 * pad)
	if area.x <= 0.0 or area.y <= 0.0:
		return Vector2.ONE
	var unit := minf(area.x / REFERENCE.x, area.y / REFERENCE.y)
	return REFERENCE * unit


func _origin(chart: Vector2) -> Vector2:
	# Centre the square board in the control.
	return Vector2((size.x - chart.x) * 0.5, (size.y - chart.y) * 0.5)


func _screen_pos(point: int) -> Vector2:
	var chart := _chart()
	var unit: Vector2 = LAYOUT[point]
	return _origin(chart) + Vector2(unit.x * chart.x, unit.y * chart.y)


func _hit_radius() -> float:
	return clampf(minf(_chart().x, _chart().y) * 0.06, 16.0, 40.0)


## Piece/ring radii scale with the board so the layout stays crisp.
func _r(factor: float) -> float:
	return clampf(minf(_chart().x, _chart().y) * factor, 4.0, 44.0)


# --- Painting -----------------------------------------------------------

func _draw_panel() -> void:
	BoardArt.panel(self, skin)


func _draw_edges() -> void:
	var line_color: Color = skin.get("line", AppTheme.C_BOARD_LINE)
	for edge in NineMensMorrisRules.EDGES:
		var pair: Array = edge
		var a := _screen_pos(int(pair[0]))
		var b := _screen_pos(int(pair[1]))
		BoardArt.groove(self, a, b, line_color, 2.5)


func _draw_point(point: int) -> void:
	var at := _screen_pos(point)
	if state == null or state.is_empty(point):
		BoardArt.socket(self, at, _r(0.014), skin)
		return
	if state.cell(point) == NineMensMorrisGameState.Cell.RED:
		_draw_disc(at, RED_DISC, RED_RIM)
	else:
		_draw_disc(at, GREEN_DISC, GREEN_RIM)


## A turned counter: bevelled lacquer disc, gold rim, lathe ring and
## pressed star emblem.
func _draw_disc(at: Vector2, disc_color: Color, rim_color: Color) -> void:
	var r := _r(0.032)
	BoardArt.disc(self, at, r, disc_color)
	draw_arc(at, r - 1.0, 0.0, TAU, 32, rim_color.lightened(0.2), 1.5, true)
	draw_arc(at, r * 0.58, 0.0, TAU, 28,
			disc_color.darkened(0.45), maxf(r * 0.10, 1.0), true)
	_draw_star(at, r * 0.34, rim_color.lightened(0.35))
	draw_circle(at, r * 0.12, rim_color.darkened(0.3))


## Six-point star emblem pressed into the counter face.
func _draw_star(at: Vector2, radius: float, ink: Color) -> void:
	var points := PackedVector2Array()
	for i in 12:
		var r := radius if i % 2 == 0 else radius * 0.45
		var angle := -PI * 0.5 + PI * i / 6.0
		points.append(at + Vector2(cos(angle), sin(angle)) * r)
	draw_colored_polygon(points, ink)


func _draw_targets() -> void:
	for point in target_points:
		BoardArt.move_glow(self, _screen_pos(point), _r(0.030), _pulse_t)


func _draw_captures() -> void:
	var breathe := 0.6 + 0.4 * _pulse_t
	for point in capture_points:
		draw_arc(_screen_pos(point), _r(0.044), 0.0, TAU, 44,
				Color(AppTheme.C_DANGER.r, AppTheme.C_DANGER.g,
				AppTheme.C_DANGER.b, breathe), 5.0, true)
		BoardArt.gold_rim(self, _screen_pos(point), _r(0.032), breathe * 0.6)


func _draw_selection() -> void:
	if selection < 0:
		return
	BoardArt.pulse_ring(self, _screen_pos(selection), _r(0.040), _pulse_t)


## Sliding ghost of the piece that just moved (visual only).
func _draw_move_ghost() -> void:
	if _move_anim_t <= 0.0 or _move_from < 0 or _move_to < 0 or state == null:
		return
	var t := 1.0 - _move_anim_t
	var eased := t * t * (3.0 - 2.0 * t)
	var from := _screen_pos(_move_from)
	var to := _screen_pos(_move_to)
	var at := from.lerp(to, eased)
	if _move_cell == NineMensMorrisGameState.Cell.RED:
		_draw_disc(at, RED_DISC, RED_RIM)
	else:
		_draw_disc(at, GREEN_DISC, GREEN_RIM)
	BoardArt.gold_rim(self, at, _r(0.034), 0.8)


func _draw_flash() -> void:
	if _flash_t <= 0.0 or _flash_point < 0:
		return
	BoardArt.flash_ring(self, _screen_pos(_flash_point), _r(0.040), _flash_t)


func _draw_burst() -> void:
	if _burst_t <= 0.0 or _burst_point < 0:
		return
	BoardArt.burst(self, _screen_pos(_burst_point), _r(0.055), 1.0 - _burst_t)

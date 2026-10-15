class_name AaduPuliBoard
extends Control
## Read-only view of an Aadu Puli Aattam position. Draws the chart,
## the pieces and the interactive highlights, and reports taps. The
## board holds no rules: the screen owns the state and hands over the
## legal target points to highlight.

signal point_activated(point: int)

## Normalised chart geometry: apex at (0, 0), four straight slants to
## the base, rows g apart, side columns on x = ±1 (points 1/7/13 and
## 6/12/18 outside the triangle — see docs/aadu_puli_aattam_rules.md §2).
const W := 1.0
const ROW_GAP := 0.62
const LAYOUT := {
	0: Vector2(0.0, 0.0),
	1: Vector2(-1.0, 1), 2: Vector2(-0.25, 1), 3: Vector2(-0.083333, 1),
	4: Vector2(0.083333, 1), 5: Vector2(0.25, 1), 6: Vector2(1.0, 1),
	7: Vector2(-1.0, 2), 8: Vector2(-0.5, 2), 9: Vector2(-0.166667, 2),
	10: Vector2(0.166667, 2), 11: Vector2(0.5, 2), 12: Vector2(1.0, 2),
	13: Vector2(-1.0, 3), 14: Vector2(-0.75, 3), 15: Vector2(-0.25, 3),
	16: Vector2(0.25, 3), 17: Vector2(0.75, 3), 18: Vector2(1.0, 3),
	19: Vector2(-1.0, 4), 20: Vector2(-0.333333, 4),
	21: Vector2(0.333333, 4), 22: Vector2(1.0, 4),
}

const R_DOT := 5.0
const R_TARGET_PAD := 4.0
const R_SELECT_PAD := 6.0

# --- Piece inks (carved medallions) --------------------------------------
# Tiger: gold disc, charcoal-ink front-facing head, gold negative-space
# marks. Goat: bone disc, warm-brown profile head with sweeping horn.
const TIGER_INK := Color("1a1208")
const TIGER_MARK := Color("f5cd78")
const GOAT_DISC := Color("efe4cc")
const GOAT_INK := Color("4a3423")
const GOAT_EYE := Color("f8f2e4")

## Front-facing tiger head: ear peaks, wide cheeks, tapered chin —
## one filled silhouette, unit coords scaled by the piece radius.
var TIGER_HEAD := PackedVector2Array([
	Vector2(-0.34, -0.94), Vector2(-0.12, -0.68), Vector2(0.12, -0.68),
	Vector2(0.34, -0.94), Vector2(0.56, -0.58), Vector2(0.82, -0.30),
	Vector2(0.90, 0.05), Vector2(0.78, 0.42), Vector2(0.50, 0.72),
	Vector2(0.18, 0.88), Vector2(0.0, 0.90), Vector2(-0.18, 0.88),
	Vector2(-0.50, 0.72), Vector2(-0.78, 0.42), Vector2(-0.90, 0.05),
	Vector2(-0.82, -0.30), Vector2(-0.56, -0.58),
])

## Goat head in right-facing profile: snout, beard tuft, throat, poll.
var GOAT_HEAD := PackedVector2Array([
	Vector2(0.62, -0.02), Vector2(0.56, 0.12), Vector2(0.40, 0.22),
	Vector2(0.34, 0.50), Vector2(0.22, 0.28), Vector2(0.02, 0.34),
	Vector2(-0.18, 0.22), Vector2(-0.26, 0.02), Vector2(-0.20, -0.16),
	Vector2(-0.04, -0.26), Vector2(0.18, -0.24), Vector2(0.42, -0.16),
])

## Swept horn crescent, tip curling back over the neck.
var GOAT_HORN := PackedVector2Array([
	Vector2(0.02, -0.26), Vector2(-0.16, -0.48), Vector2(-0.40, -0.58),
	Vector2(-0.62, -0.52), Vector2(-0.72, -0.36), Vector2(-0.60, -0.40),
	Vector2(-0.42, -0.36), Vector2(-0.26, -0.24), Vector2(-0.12, -0.14),
])

## Drooping ear below the horn root.
var GOAT_EAR := PackedVector2Array([
	Vector2(-0.18, -0.06), Vector2(-0.40, 0.06), Vector2(-0.16, 0.08),
])

var state: AaduPuliGameState = null
var selection: int = -1
var target_points: Array[int] = []
var placing: bool = false
## Phase 12: equipped board-skin palette from App.cosmetics
## ({} = classic surface).
var skin := {}

# --- Animation state (visual only, never blocks input) --------------------
var _pulse_t := 0.0
var _move_anim_t := 0.0
var _move_from := -1
var _move_to := -1
var _move_is_tiger := false
var _flash_t := 0.0
var _flash_point := -1
var _prev_board: Array[int] = []


func set_skin(palette: Dictionary) -> void:
	skin = palette if palette != null else {}
	queue_redraw()


func configure(p_state: AaduPuliGameState, p_selection: int,
		p_targets: Array[int], p_placing: bool) -> void:
	_detect_move(p_state)
	state = p_state
	selection = p_selection
	target_points = p_targets
	placing = p_placing
	queue_redraw()


## Diff the previous board against the new one to find a single piece
## that left one point and arrived at another — the mover to animate.
func _detect_move(p_state: AaduPuliGameState) -> void:
	if p_state == null or _prev_board.size() != AaduPuliGameState.POINT_COUNT:
		_prev_board = p_state.board.duplicate() if p_state != null else []
		return
	var from := -1
	var to := -1
	var moves := 0
	for i in AaduPuliGameState.POINT_COUNT:
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
		_move_is_tiger = p_state.board[to] == AaduPuliGameState.Cell.TIGER
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
	if selection >= 0 or not target_points.is_empty() or placing:
		animating = true
	if not animating:
		set_process(false)
	queue_redraw()


## Returns the point under `pos`, or -1 when the tap is off the chart.
func point_at(pos: Vector2) -> int:
	var best := -1
	var best_distance := _hit_radius()
	for point in AaduPuliGameState.POINT_COUNT:
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
	_draw_placement_hints()
	_draw_targets()
	for point in AaduPuliGameState.POINT_COUNT:
		_draw_point(point)
	_draw_move_ghost()
	_draw_selection()
	_draw_flash()


# --- Geometry -----------------------------------------------------------

func _scale() -> float:
	var pad := 30.0
	var area := Vector2(size.x - 2.0 * pad, size.y - 2.0 * pad)
	if area.x <= 0.0 or area.y <= 0.0:
		return 1.0
	return minf(area.x / (2.0 * W), area.y / (4.0 * ROW_GAP))


func _origin() -> Vector2:
	# Centre the chart vertically (width often binds the scale first).
	var chart_height := 4.0 * ROW_GAP * _scale()
	return Vector2(size.x * 0.5, maxf((size.y - chart_height) * 0.5, 24.0))


func _screen_pos(point: int) -> Vector2:
	var unit: Vector2 = LAYOUT[point]
	return _origin() + Vector2(unit.x * _scale(), unit.y * ROW_GAP * _scale())


func _hit_radius() -> float:
	return clampf(_scale() * 0.10, 14.0, 30.0)


## Piece radii scale with the chart so the carved faces stay legible
## on every screen (hero tiger a touch larger than the goat counter).
func _r_tiger() -> float:
	return clampf(_scale() * 0.088, 12.0, 26.0)


func _r_goat() -> float:
	return clampf(_scale() * 0.072, 10.0, 21.0)


# --- Painting -----------------------------------------------------------

func _draw_panel() -> void:
	BoardArt.panel(self, skin)


func _draw_lines() -> void:
	var line_color: Color = skin.get("line", AppTheme.C_BOARD_LINE)
	for line in AaduPuliRules.LINES:
		var points := PackedVector2Array()
		for point in line:
			points.append(_screen_pos(int(point)))
		BoardArt.groove_polyline(self, points, line_color, 2.0)


func _draw_point(point: int) -> void:
	var at := _screen_pos(point)
	if state == null or state.is_empty(point):
		BoardArt.socket(self, at, R_DOT + 1.0, skin)
		return
	match state.cell(point):
		AaduPuliGameState.Cell.TIGER:
			_draw_tiger(at, _r_tiger())
		AaduPuliGameState.Cell.GOAT:
			_draw_goat(at, _r_goat())


## Hero piece: a gold medallion carrying a carved front-facing tiger —
## ear notches, forehead and cheek stripes in negative-space gold, and
## two bright eyes. Reads at any board scale.
func _draw_tiger(at: Vector2, r: float) -> void:
	BoardArt.disc(self, at, r, AppTheme.C_ACCENT)
	BoardArt.shape(self, at, r * 0.92, TIGER_HEAD, TIGER_INK)
	# Ear interiors.
	BoardArt.shape(self, at, r * 0.92, PackedVector2Array([
		Vector2(-0.30, -0.86), Vector2(-0.16, -0.68), Vector2(-0.32, -0.66),
	]), TIGER_MARK)
	BoardArt.shape(self, at, r * 0.92, PackedVector2Array([
		Vector2(0.30, -0.86), Vector2(0.16, -0.68), Vector2(0.32, -0.66),
	]), TIGER_MARK)
	# Forehead stripes.
	BoardArt.stripe(self, at, r * 0.92,
			Vector2(-0.20, -0.56), Vector2(-0.13, -0.30), TIGER_MARK, 0.10)
	BoardArt.stripe(self, at, r * 0.92,
			Vector2(0.0, -0.58), Vector2(0.0, -0.34), TIGER_MARK, 0.10)
	BoardArt.stripe(self, at, r * 0.92,
			Vector2(0.20, -0.56), Vector2(0.13, -0.30), TIGER_MARK, 0.10)
	# Cheek stripes.
	BoardArt.stripe(self, at, r * 0.92,
			Vector2(-0.76, -0.06), Vector2(-0.52, 0.00), TIGER_MARK, 0.09)
	BoardArt.stripe(self, at, r * 0.92,
			Vector2(-0.72, 0.16), Vector2(-0.52, 0.16), TIGER_MARK, 0.09)
	BoardArt.stripe(self, at, r * 0.92,
			Vector2(0.76, -0.06), Vector2(0.52, 0.00), TIGER_MARK, 0.09)
	BoardArt.stripe(self, at, r * 0.92,
			Vector2(0.72, 0.16), Vector2(0.52, 0.16), TIGER_MARK, 0.09)
	# Eyes, nose, muzzle.
	var u := r * 0.92
	draw_circle(at + Vector2(-0.33, -0.08) * u, u * 0.10, TIGER_MARK)
	draw_circle(at + Vector2(0.33, -0.08) * u, u * 0.10, TIGER_MARK)
	BoardArt.shape(self, at, u, PackedVector2Array([
		Vector2(-0.09, 0.24), Vector2(0.09, 0.24), Vector2(0.0, 0.36),
	]), TIGER_MARK)
	BoardArt.stripe(self, at, u,
			Vector2(0.0, 0.36), Vector2(0.0, 0.48), TIGER_MARK, 0.08)


## The humble counterweight: a bone medallion with a brown goat profile —
## swept horn, drooping ear, beard tuft and a single bright eye.
func _draw_goat(at: Vector2, r: float) -> void:
	BoardArt.disc(self, at, r, GOAT_DISC)
	BoardArt.shape(self, at, r * 0.90, GOAT_EAR, GOAT_INK.darkened(0.15))
	BoardArt.shape(self, at, r * 0.90, GOAT_HORN, GOAT_INK)
	BoardArt.shape(self, at, r * 0.90, GOAT_HEAD, GOAT_INK)
	var g := r * 0.90
	draw_circle(at + Vector2(0.24, -0.08) * g, g * 0.09, GOAT_EYE)
	draw_circle(at + Vector2(0.50, 0.02) * g, g * 0.05, GOAT_EYE)


func _draw_placement_hints() -> void:
	if not placing or state == null:
		return
	for point in AaduPuliGameState.POINT_COUNT:
		if state.is_empty(point):
			BoardArt.move_glow(self, _screen_pos(point), R_DOT + 5.0, _pulse_t)


func _draw_targets() -> void:
	var r := _r_tiger() + R_TARGET_PAD
	for point in target_points:
		BoardArt.move_glow(self, _screen_pos(point), r * 0.75, _pulse_t)
		draw_arc(_screen_pos(point), r, 0.0, TAU, 32,
				AppTheme.C_SUCCESS, 3.0, true)


func _draw_move_ghost() -> void:
	if _move_anim_t <= 0.0 or _move_from < 0 or _move_to < 0 or state == null:
		return
	var t := 1.0 - _move_anim_t
	var eased := t * t * (3.0 - 2.0 * t)
	var from := _screen_pos(_move_from)
	var to := _screen_pos(_move_to)
	var at := from.lerp(to, eased)
	if _move_is_tiger:
		_draw_tiger(at, _r_tiger())
	else:
		_draw_goat(at, _r_goat())


func _draw_flash() -> void:
	if _flash_t <= 0.0 or _flash_point < 0:
		return
	BoardArt.flash_ring(self, _screen_pos(_flash_point),
			_r_tiger() + R_SELECT_PAD, _flash_t)


func _draw_selection() -> void:
	if selection < 0:
		return
	var r := _r_tiger() + R_SELECT_PAD
	BoardArt.pulse_ring(self, _screen_pos(selection), r, _pulse_t)

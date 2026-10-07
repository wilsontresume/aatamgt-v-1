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

const R_DOT := 4.0
const R_TIGER := 11.0
const R_GOAT := 8.5
const R_TARGET := 12.0
const R_SELECT := 15.0

var state: AaduPuliGameState = null
var selection: int = -1
var target_points: Array[int] = []
var placing: bool = false


func configure(p_state: AaduPuliGameState, p_selection: int,
		p_targets: Array[int], p_placing: bool) -> void:
	state = p_state
	selection = p_selection
	target_points = p_targets
	placing = p_placing
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
	_draw_selection()


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


# --- Painting -----------------------------------------------------------

func _draw_panel() -> void:
	var panel := StyleBoxFlat.new()
	panel.bg_color = AppTheme.C_SURFACE
	panel.set_corner_radius_all(int(AppTheme.R_CARD))
	panel.set_border_width_all(1)
	panel.border_color = AppTheme.C_BORDER
	draw_style_box(panel, Rect2(Vector2.ZERO, size))


func _draw_lines() -> void:
	for line in AaduPuliRules.LINES:
		var points := PackedVector2Array()
		for point in line:
			points.append(_screen_pos(int(point)))
		draw_polyline(points, AppTheme.C_BORDER, 2.0, true)


func _draw_point(point: int) -> void:
	var at := _screen_pos(point)
	if state == null or state.is_empty(point):
		draw_circle(at, R_DOT, AppTheme.C_TEXT_SECONDARY)
	match state.cell(point) if state != null else -1:
		AaduPuliGameState.Cell.TIGER:
			draw_circle(at, R_TIGER, AppTheme.C_ACCENT)
			draw_circle(at, 4.0, AppTheme.C_ON_ACCENT)
		AaduPuliGameState.Cell.GOAT:
			draw_circle(at, R_GOAT, AppTheme.C_TEXT)
			draw_circle(at, 3.0, AppTheme.C_CARD)


func _draw_placement_hints() -> void:
	if not placing or state == null:
		return
	for point in AaduPuliGameState.POINT_COUNT:
		if state.is_empty(point):
			draw_circle(_screen_pos(point), R_DOT + 3.0,
					AppTheme.C_SUCCESS * Color(1.0, 1.0, 1.0, 0.45))


func _draw_targets() -> void:
	for point in target_points:
		draw_arc(_screen_pos(point), R_TARGET, 0.0, TAU, 32,
				AppTheme.C_SUCCESS, 3.0, true)


func _draw_selection() -> void:
	if selection < 0:
		return
	draw_arc(_screen_pos(selection), R_SELECT, 0.0, TAU, 36,
			AppTheme.C_ACCENT, 3.0, true)

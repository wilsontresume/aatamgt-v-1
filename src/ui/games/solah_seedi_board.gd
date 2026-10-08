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

const R_DOT := 4.0
const R_PIECE := 11.0
const R_TARGET := 12.0
const R_SELECT := 15.0

var state: SolahSeediGameState = null
var selection: int = -1
var target_points: Array[int] = []
## The route built so far (origin first); drawn as a line through the
## hops the player has already chosen.
var path_points: Array[int] = []


func configure(p_state: SolahSeediGameState, p_selection: int,
		p_targets: Array[int], p_path: Array[int]) -> void:
	state = p_state
	selection = p_selection
	target_points = p_targets
	path_points = p_path
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
	_draw_selection()


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
	var panel := StyleBoxFlat.new()
	panel.bg_color = AppTheme.C_SURFACE
	panel.set_corner_radius_all(int(AppTheme.R_CARD))
	panel.set_border_width_all(1)
	panel.border_color = AppTheme.C_BORDER
	draw_style_box(panel, Rect2(Vector2.ZERO, size))


func _draw_lines() -> void:
	for line in SolahSeediRules.LINES:
		var points := PackedVector2Array()
		for point in line:
			points.append(_screen_pos(int(point)))
		draw_polyline(points, AppTheme.C_BORDER, 2.0, true)


func _draw_point(point: int) -> void:
	var at := _screen_pos(point)
	if state == null or state.is_empty(point):
		draw_circle(at, R_DOT, AppTheme.C_TEXT_SECONDARY)
		return
	if state.cell(point) == SolahSeediGameState.Cell.RED:
		draw_circle(at, R_PIECE, AppTheme.C_DANGER)
		draw_circle(at, R_PIECE - 4.0, AppTheme.C_DANGER.darkened(0.35))
	else:
		draw_circle(at, R_PIECE, AppTheme.C_SUCCESS)
		draw_circle(at, R_PIECE - 4.0, AppTheme.C_SUCCESS.darkened(0.35))


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
		draw_arc(_screen_pos(point), R_TARGET, 0.0, TAU, 32,
				AppTheme.C_ACCENT, 3.0, true)


func _draw_selection() -> void:
	if selection < 0:
		return
	draw_arc(_screen_pos(selection), R_SELECT, 0.0, TAU, 36,
			AppTheme.C_TEXT, 3.0, true)

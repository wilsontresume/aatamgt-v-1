class_name MorrisBoard
extends Control
## Read-only view of a Nine Men's Morris position. Draws the three
## squares, the spokes, the pieces and the interactive highlights, and
## reports taps. The board holds no rules: the screen owns the state
## and hands over the selection, the legal landings and the capture
## choices to highlight.

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


func configure(p_state: NineMensMorrisGameState, p_selection: int,
		p_targets: Array[int], p_captures: Array[int]) -> void:
	state = p_state
	selection = p_selection
	target_points = p_targets
	capture_points = p_captures
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
	var panel := StyleBoxFlat.new()
	panel.bg_color = AppTheme.C_SURFACE
	panel.set_corner_radius_all(int(AppTheme.R_CARD))
	panel.set_border_width_all(1)
	panel.border_color = AppTheme.C_BORDER
	draw_style_box(panel, Rect2(Vector2.ZERO, size))


func _draw_edges() -> void:
	for edge in NineMensMorrisRules.EDGES:
		var pair: Array = edge
		var a := _screen_pos(int(pair[0]))
		var b := _screen_pos(int(pair[1]))
		draw_line(a, b, AppTheme.C_BORDER, 3.0, true)


func _draw_point(point: int) -> void:
	var at := _screen_pos(point)
	if state == null or state.is_empty(point):
		draw_circle(at, _r(0.012), AppTheme.C_TEXT_SECONDARY)
		return
	if state.cell(point) == NineMensMorrisGameState.Cell.RED:
		draw_circle(at, _r(0.030), AppTheme.C_DANGER)
		draw_circle(at, _r(0.030) - 6.0, AppTheme.C_DANGER.darkened(0.35))
	else:
		draw_circle(at, _r(0.030), AppTheme.C_SUCCESS)
		draw_circle(at, _r(0.030) - 6.0, AppTheme.C_SUCCESS.darkened(0.35))


func _draw_targets() -> void:
	for point in target_points:
		draw_arc(_screen_pos(point), _r(0.038), 0.0, TAU, 40,
				AppTheme.C_ACCENT, 4.0, true)


func _draw_captures() -> void:
	for point in capture_points:
		draw_arc(_screen_pos(point), _r(0.044), 0.0, TAU, 44,
				AppTheme.C_DANGER, 5.0, true)


func _draw_selection() -> void:
	if selection < 0:
		return
	draw_arc(_screen_pos(selection), _r(0.046), 0.0, TAU, 48,
			AppTheme.C_TEXT, 4.0, true)

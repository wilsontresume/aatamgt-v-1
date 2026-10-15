class_name BoardArt
extends RefCounted
## Shared carved-board painting for all three game boards: sandstone
## temple slab, engraved grooves, drilled sockets, bevelled discs and
## glow overlays. Pure drawing helpers — no rules, no state. Boards
## pass their Control in so the skin palette contract ({"bg": Color,
## "line": Color}) stays in one place. Empty skin = sandstone default.

const GROOVE_SHADOW_ALPHA := 0.55
const SOCKET_SHADOW := Color(0.0, 0.0, 0.0, 0.35)
const DISC_SHADOW := Color(0.0, 0.0, 0.0, 0.30)
const GOLD_TRIM := Color("d4a017")
const GOLD_TRIM_LIGHT := Color("ffd76a")
const SAND_SPECKLE := Color(0.35, 0.22, 0.10, 0.18)


## Sandstone slab with a gold ornamental double border. Deterministic
## speckle noise (hashed from pixel coords) so redraws never flicker.
## Skin palette overrides bg/line when provided (cosmetics contract).
static func panel(board: Control, skin: Dictionary) -> void:
	var bg: Color = skin.get("bg", AppTheme.C_BOARD_SAND)
	var border: Color = skin.get("line", AppTheme.C_BOARD_LINE)
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.set_corner_radius_all(int(AppTheme.R_CARD))
	box.set_border_width_all(1)
	box.border_color = border.darkened(0.25)
	board.draw_style_box(box, Rect2(Vector2.ZERO, board.size))
	# Vertical shading: warm light from the top, shadow at the bottom.
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 0.10))
	gradient.set_color(1, Color(0, 0, 0, 0.14))
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(0, 1)
	board.draw_texture_rect(tex, Rect2(Vector2.ZERO, board.size), false)
	# Deterministic sandstone speckle.
	var w := int(board.size.x)
	var h := int(board.size.y)
	if w > 4 and h > 4:
		var step := 14
		var y := step
		while y < h - 2:
			var x := step
			while x < w - 2:
				var hash_v := (x * 73856093) ^ (y * 19349663)
				var jx := (hash_v & 7) - 3
				var jy := ((hash_v >> 3) & 7) - 3
				var alpha := 0.05 + float((hash_v >> 6) & 7) * 0.015
				board.draw_circle(Vector2(x + jx, y + jy), 1.0,
						Color(SAND_SPECKLE.r, SAND_SPECKLE.g, SAND_SPECKLE.b, alpha))
				x += step
			y += step
	# Gold ornamental double border.
	var inset := 5.0
	var rect := Rect2(inset, inset, board.size.x - inset * 2.0, board.size.y - inset * 2.0)
	var radius := int(AppTheme.R_CARD) - 4
	board.draw_rect(rect, Color(GOLD_TRIM.r, GOLD_TRIM.g, GOLD_TRIM.b, 0.9), false, 2.0)
	var inner := Rect2(inset + 4.0, inset + 4.0,
			rect.size.x - 8.0, rect.size.y - 8.0)
	board.draw_rect(inner, Color(GOLD_TRIM_LIGHT.r, GOLD_TRIM_LIGHT.g,
			GOLD_TRIM_LIGHT.b, 0.35), false, 1.0)
	# Corner flourishes: small gold arcs at each corner.
	var corner_r := 10.0
	var corners := [
		Vector2(rect.position.x + corner_r, rect.position.y + corner_r),
		Vector2(rect.end.x - corner_r, rect.position.y + corner_r),
		Vector2(rect.end.x - corner_r, rect.end.y - corner_r),
		Vector2(rect.position.x + corner_r, rect.end.y - corner_r),
	]
	for corner in corners:
		board.draw_arc(corner, corner_r, 0.0, TAU, 16, Color(GOLD_TRIM_LIGHT.r,
				GOLD_TRIM_LIGHT.g, GOLD_TRIM_LIGHT.b, 0.5), 1.5, true)


## One groove segment: a dark shadow under a solid line, giving the
## chart an incised-in-stone look at any skin colour.
static func groove(board: Control, a: Vector2, b: Vector2,
		color: Color, width: float) -> void:
	var shadow := Color(color.r, color.g, color.b, GROOVE_SHADOW_ALPHA).darkened(0.5)
	board.draw_line(a + Vector2(0.0, 1.0), b + Vector2(0.0, 1.0),
			shadow, width + 1.2, true)
	board.draw_line(a, b, color, width, true)


## Convenience: engraved polyline through the given points.
static func groove_polyline(board: Control, points: PackedVector2Array,
		color: Color, width: float) -> void:
	for i in range(points.size() - 1):
		groove(board, points[i], points[i + 1], color, width)


## Drilled socket for an empty point: dark bore, thin light rim, and a
## faint centre punch.
static func socket(board: Control, at: Vector2, radius: float,
		skin: Dictionary) -> void:
	var line: Color = skin.get("line", AppTheme.C_BOARD_LINE)
	var bore: Color = skin.get("bg", AppTheme.C_BOARD_SAND).darkened(0.45)
	board.draw_circle(at + Vector2(0.0, 1.0), radius * 1.05, SOCKET_SHADOW)
	board.draw_circle(at, radius, bore)
	board.draw_arc(at, radius - 0.6, 0.0, TAU, 20,
			line.lightened(0.3), 1.2, true)
	board.draw_circle(at, maxf(radius * 0.22, 1.0),
			line.lightened(0.15) * Color(1.0, 1.0, 1.0, 0.7))


## Bevelled disc: drop shadow, domed base, dark lower rim, light upper
## rim. The workhorse body for every piece in all three games.
static func disc(board: Control, at: Vector2, radius: float, base: Color) -> void:
	board.draw_circle(at + Vector2(0.0, radius * 0.16), radius * 1.02,
			DISC_SHADOW)
	board.draw_circle(at, radius, base)
	# Lower-right shading arc, upper-left light-catch arc.
	board.draw_arc(at, radius - 0.9, PI * 0.12, PI * 0.88, 22,
			base.darkened(0.40), maxf(radius * 0.16, 1.4), true)
	board.draw_arc(at, radius - 0.9, -PI * 0.88, -PI * 0.12, 22,
			base.lightened(0.35), maxf(radius * 0.12, 1.1), true)


## Tapered crescent / wedge from a polygon of unit coords scaled by r.
static func shape(board: Control, at: Vector2, radius: float,
		unit_points: PackedVector2Array, color: Color) -> void:
	var points := PackedVector2Array()
	for unit in unit_points:
		points.append(at + unit * radius)
	board.draw_colored_polygon(points, color)


## Short inked stripe (piece detail) between two unit coords.
static func stripe(board: Control, at: Vector2, radius: float,
		from: Vector2, to: Vector2, color: Color, width: float) -> void:
	board.draw_line(at + from * radius, at + to * radius, color,
			maxf(radius * width, 1.0), true)


## Gold rim ring around a piece (used for selected / last-moved pieces).
static func gold_rim(board: Control, at: Vector2, radius: float, alpha: float) -> void:
	board.draw_arc(at, radius + 1.5, 0.0, TAU, 40,
			Color(GOLD_TRIM_LIGHT.r, GOLD_TRIM_LIGHT.g, GOLD_TRIM_LIGHT.b, alpha),
			2.5, true)


## Soft green move-glow: a filled translucent dot with a brighter core.
static func move_glow(board: Control, at: Vector2, radius: float, pulse: float) -> void:
	var breathe := 0.65 + 0.35 * pulse
	board.draw_circle(at, radius, Color(0.29, 0.69, 0.31, 0.30 * breathe))
	board.draw_circle(at, radius * 0.55, Color(0.43, 0.91, 0.43, 0.55 * breathe))
	board.draw_arc(at, radius, 0.0, TAU, 24,
			Color(0.55, 0.95, 0.55, 0.65 * breathe), 1.5, true)


## Pulsing gold selection ring around the held piece.
static func pulse_ring(board: Control, at: Vector2, radius: float, pulse: float) -> void:
	var breathe := 0.55 + 0.45 * pulse
	board.draw_arc(at, radius, 0.0, TAU, 48,
			Color(GOLD_TRIM_LIGHT.r, GOLD_TRIM_LIGHT.g, GOLD_TRIM_LIGHT.b, 0.5 * breathe),
			3.0, true)
	board.draw_arc(at, radius + 4.0, 0.0, TAU, 48,
			Color(GOLD_TRIM.r, GOLD_TRIM.g, GOLD_TRIM.b, 0.3 * breathe),
			2.0, true)


## Red flash ring for an illegal tap (self-clearing).
static func flash_ring(board: Control, at: Vector2, radius: float, alpha: float) -> void:
	board.draw_arc(at, radius, 0.0, TAU, 36,
			Color(AppTheme.C_DANGER.r, AppTheme.C_DANGER.g, AppTheme.C_DANGER.b, alpha),
			4.0, true)
	board.draw_line(at + Vector2(-radius * 0.5, -radius * 0.5),
			at + Vector2(radius * 0.5, radius * 0.5),
			Color(AppTheme.C_DANGER.r, AppTheme.C_DANGER.g, AppTheme.C_DANGER.b, alpha),
			3.0, true)
	board.draw_line(at + Vector2(radius * 0.5, -radius * 0.5),
			at + Vector2(-radius * 0.5, radius * 0.5),
			Color(AppTheme.C_DANGER.r, AppTheme.C_DANGER.g, AppTheme.C_DANGER.b, alpha),
			3.0, true)


## Expanding gold burst for a mill / capture highlight.
static func burst(board: Control, at: Vector2, radius: float, progress: float) -> void:
	var r := radius * (0.6 + 0.8 * progress)
	var alpha := 0.85 * (1.0 - progress)
	board.draw_arc(at, r, 0.0, TAU, 40,
			Color(GOLD_TRIM_LIGHT.r, GOLD_TRIM_LIGHT.g, GOLD_TRIM_LIGHT.b, alpha),
			3.0, true)
	board.draw_arc(at, r * 0.7, 0.0, TAU, 32,
			Color(1.0, 1.0, 1.0, alpha * 0.6), 2.0, true)

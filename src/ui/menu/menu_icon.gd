extends Control
## Procedural vector icons for the arcade lobby. One Control draws a
## single icon by name; colors are inherited from the theme ("App"
## palette + arcade accents) or overridden per-instance. Decorative —
## never intercepts input (parents handle taps).

const S_HOME := &"home"
const S_FRIENDS := &"friends"
const S_LEADERBOARD := &"leaderboard"
const S_PROFILE := &"profile"
const S_STORE := &"store"
const S_SHOP := &"shop"
const S_SETTINGS := &"settings"
const S_INVENTORY := &"inventory"
const S_HISTORY := &"history"
const S_RANKINGS := &"rankings"
const S_DAILY := &"daily"
const S_CROWN := &"crown"
const S_CHEVRON := &"chevron"
const S_PLUS := &"plus"
const S_MAIL := &"mail"
const S_TIGER := &"tiger"
const S_GOAT := &"goat"
const S_LOCK := &"lock"
const S_EYE := &"eye"
const S_EYE_OFF := &"eye_off"
const S_GOOGLE := &"google"
const S_FACEBOOK := &"facebook"

@export var icon: StringName = S_HOME:
	set(value):
		icon = value
		queue_redraw()

@export var icon_color: Color = Color.WHITE:
	set(value):
		icon_color = value
		queue_redraw()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)
	queue_redraw()


func _draw() -> void:
	var s := minf(size.x, size.y)
	if s < 4.0:
		return
	var c := size / 2.0
	var u := s / 24.0  # unit: icons designed on a 24x24 grid
	var col := icon_color

	match icon:
		S_HOME:
			# Roof triangle + body.
			var pts := PackedVector2Array([
				c + Vector2(-9, -1) * u, c + Vector2(0, -9) * u,
				c + Vector2(9, -1) * u])
			draw_colored_polygon(pts, col)
			draw_rect(Rect2(c + Vector2(-6, -1) * u, Vector2(12, 9) * u), col)
			draw_rect(Rect2(c + Vector2(-2, 2) * u, Vector2(4, 6) * u),
					Color(0, 0, 0, 0.35))
		S_FRIENDS:
			draw_circle(c + Vector2(-4, -3) * u, 3.6 * u, col)
			draw_circle(c + Vector2(4.5, -3) * u, 3.2 * u, Color(col.r, col.g, col.b, 0.8))
			draw_rect(Rect2(c + Vector2(-7.5, 2) * u, Vector2(7, 7) * u), col)
			draw_rect(Rect2(c + Vector2(1.5, 2.5) * u, Vector2(6.5, 6.5) * u),
					Color(col.r, col.g, col.b, 0.8))
		S_LEADERBOARD, S_RANKINGS:
			# Trophy: cup + stem + base.
			draw_rect(Rect2(c + Vector2(-5, -8) * u, Vector2(10, 8) * u), col)
			draw_circle(c + Vector2(-5.5, -5) * u, 2.2 * u, col)
			draw_circle(c + Vector2(5.5, -5) * u, 2.2 * u, col)
			draw_rect(Rect2(c + Vector2(-1.5, 0) * u, Vector2(3, 5) * u), col)
			draw_rect(Rect2(c + Vector2(-4.5, 5) * u, Vector2(9, 2.5) * u), col)
		S_PROFILE:
			draw_circle(c + Vector2(0, -3.5) * u, 4.2 * u, col)
			draw_circle(c + Vector2(0, 8) * u, 6.5 * u, col)
			# Clip the lower circle to a shoulders shape.
			draw_rect(Rect2(c + Vector2(-7, 6) * u, Vector2(14, 6) * u),
					Color(0, 0, 0, 0))
		S_STORE, S_SHOP:
			# Shop awning + counter.
			draw_rect(Rect2(c + Vector2(-8, -2) * u, Vector2(16, 4) * u), col)
			for i in range(4):
				var stripe := Color(col.r, col.g, col.b, 0.55) if i % 2 == 0 else col
				draw_rect(Rect2(c + Vector2(-8 + i * 4, -6) * u, Vector2(4, 4) * u), stripe)
			draw_rect(Rect2(c + Vector2(-7, 2) * u, Vector2(14, 7) * u), col)
			draw_rect(Rect2(c + Vector2(-3, 4) * u, Vector2(6, 5) * u),
					Color(0, 0, 0, 0.35))
		S_SETTINGS:
			# Gear: ring + teeth.
			draw_arc(c, 5.5 * u, 0.0, TAU, 24, col, 3.2 * u, true)
			for i in range(8):
				var a := TAU * float(i) / 8.0
				var dir := Vector2(cos(a), sin(a))
				draw_rect(Rect2(c + dir * 6.5 * u - Vector2(1.8, 1.8) * u,
						Vector2(3.6, 3.6) * u), col)
			draw_circle(c, 2.2 * u, col)
		S_INVENTORY:
			# Backpack.
			draw_rect(Rect2(c + Vector2(-6, -4) * u, Vector2(12, 12) * u), col)
			draw_arc(c + Vector2(0, -4) * u, 4.0 * u, PI, TAU, 16, col, 2.4 * u, true)
			draw_rect(Rect2(c + Vector2(-3.5, 0) * u, Vector2(7, 5) * u),
					Color(0, 0, 0, 0.3))
		S_HISTORY:
			# Scroll.
			draw_rect(Rect2(c + Vector2(-7, -7) * u, Vector2(14, 14) * u), col)
			draw_circle(c + Vector2(-7, -7) * u, 2.4 * u, col)
			draw_circle(c + Vector2(-7, 7) * u, 2.4 * u, col)
			draw_circle(c + Vector2(7, -7) * u, 2.4 * u, col)
			draw_circle(c + Vector2(7, 7) * u, 2.4 * u, col)
			for i in range(3):
				draw_rect(Rect2(c + Vector2(-4, -3.5 + i * 3.5) * u,
						Vector2(8, 1.6) * u), Color(0, 0, 0, 0.35))
		S_DAILY:
			# Gift chest.
			draw_rect(Rect2(c + Vector2(-7, -2) * u, Vector2(14, 9) * u), col)
			draw_rect(Rect2(c + Vector2(-7, -6) * u, Vector2(14, 5) * u),
					Color(col.r, col.g, col.b, 0.75))
			draw_rect(Rect2(c + Vector2(-1.2, -6) * u, Vector2(2.4, 13) * u),
					Color(1, 0.9, 0.4, 0.95))
			draw_rect(Rect2(c + Vector2(-7, -1) * u, Vector2(14, 2) * u),
					Color(1, 0.9, 0.4, 0.95))
		S_CROWN:
			var crown := PackedVector2Array([
				c + Vector2(-8, 4) * u, c + Vector2(-8, -4) * u,
				c + Vector2(-4, 0) * u, c + Vector2(0, -7) * u,
				c + Vector2(4, 0) * u, c + Vector2(8, -4) * u,
				c + Vector2(8, 4) * u])
			draw_colored_polygon(crown, col)
			draw_rect(Rect2(c + Vector2(-8, 4) * u, Vector2(16, 2.6) * u), col)
			draw_circle(c + Vector2(0, -1) * u, 1.6 * u, Color(1, 1, 0.85, 0.9))
		S_CHEVRON:
			var a := PackedVector2Array([
				c + Vector2(-3, -6) * u, c + Vector2(3, 0) * u,
				c + Vector2(-3, 6) * u])
			draw_colored_polygon(a, col)
		S_PLUS:
			draw_rect(Rect2(c + Vector2(-1.4, -7) * u, Vector2(2.8, 14) * u), col)
			draw_rect(Rect2(c + Vector2(-7, -1.4) * u, Vector2(14, 2.8) * u), col)
		S_MAIL:
			draw_rect(Rect2(c + Vector2(-8, -5) * u, Vector2(16, 11) * u), col)
			var flap := PackedVector2Array([
				c + Vector2(-8, -5) * u, c + Vector2(0, 2) * u,
				c + Vector2(8, -5) * u])
			draw_colored_polygon(flap, Color(0, 0, 0, 0.35))
		S_TIGER:
			# Stylised tiger face: orange head, dark stripes, eyes.
			draw_circle(c, 8.5 * u, Color("f2994a"))
			draw_circle(c + Vector2(-5.5, -7) * u, 3.0 * u, Color("f2994a"))
			draw_circle(c + Vector2(5.5, -7) * u, 3.0 * u, Color("f2994a"))
			draw_circle(c + Vector2(-5.5, -7) * u, 1.6 * u, Color("c96a20"))
			draw_circle(c + Vector2(5.5, -7) * u, 1.6 * u, Color("c96a20"))
			for i in range(3):
				var yy := -5.0 + float(i) * 2.2
				draw_rect(Rect2(c + Vector2(-1.2, yy) * u, Vector2(2.4, 1.2) * u),
						Color("3a2410"))
			draw_circle(c + Vector2(-3, -0.5) * u, 1.5 * u, Color("1c1c1c"))
			draw_circle(c + Vector2(3, -0.5) * u, 1.5 * u, Color("1c1c1c"))
			draw_circle(c + Vector2(0, 3) * u, 1.8 * u, Color("5a3010"))
		S_GOAT:
			draw_circle(c + Vector2(0, 1) * u, 7.5 * u, Color("f0ead8"))
			# Horns.
			draw_arc(c + Vector2(-4, -5) * u, 4.0 * u, PI * 0.9, PI * 1.9, 12,
					Color("8a7a5a"), 2.2 * u, true)
			draw_arc(c + Vector2(4, -5) * u, 4.0 * u, PI * 1.1, PI * 2.1, 12,
					Color("8a7a5a"), 2.2 * u, true)
			draw_circle(c + Vector2(-2.6, -0.5) * u, 1.3 * u, Color("2a2a2a"))
			draw_circle(c + Vector2(2.6, -0.5) * u, 1.3 * u, Color("2a2a2a"))
			# Beard.
			draw_colored_polygon(PackedVector2Array([
				c + Vector2(-1.5, 6) * u, c + Vector2(1.5, 6) * u,
				c + Vector2(0, 10) * u]), Color("e8e0c8"))
		S_LOCK:
			draw_arc(c + Vector2(0, -2.0) * u, 4.8 * u, PI, TAU, 16, col, 2.4 * u, true)
			draw_rect(Rect2(c + Vector2(-6.5, -2.0) * u, Vector2(13, 9.5) * u), col)
			draw_circle(c + Vector2(0, 2.5) * u, 1.8 * u, Color(0, 0, 0, 0.45))
			draw_rect(Rect2(c + Vector2(-0.9, 2.5) * u, Vector2(1.8, 3.2) * u), Color(0, 0, 0, 0.45))
		S_EYE:
			draw_arc(c + Vector2(0, 3.5) * u, 8.0 * u, deg_to_rad(210), deg_to_rad(330), 16, col, 2.2 * u, true)
			draw_arc(c + Vector2(0, -3.5) * u, 8.0 * u, deg_to_rad(30), deg_to_rad(150), 16, col, 2.2 * u, true)
			draw_circle(c, 3.0 * u, col)
			draw_circle(c + Vector2(-1.0, -1.0) * u, 1.1 * u, Color(1, 1, 1, 0.8))
		S_EYE_OFF:
			draw_arc(c + Vector2(0, 3.5) * u, 8.0 * u, deg_to_rad(210), deg_to_rad(330), 16, Color(col.r, col.g, col.b, 0.5), 2.2 * u, true)
			draw_arc(c + Vector2(0, -3.5) * u, 8.0 * u, deg_to_rad(30), deg_to_rad(150), 16, Color(col.r, col.g, col.b, 0.5), 2.2 * u, true)
			draw_circle(c, 3.0 * u, Color(col.r, col.g, col.b, 0.5))
			draw_line(c + Vector2(-8, -8) * u, c + Vector2(8, 8) * u, col, 2.6 * u, true)
		S_GOOGLE:
			var r := 8.0 * u
			var lw := 3.2 * u
			draw_arc(c, r, deg_to_rad(-115), deg_to_rad(-25), 20, Color("ea4335"), lw, true)
			draw_arc(c, r, deg_to_rad(-25), deg_to_rad(65), 20, Color("fbbc05"), lw, true)
			draw_arc(c, r, deg_to_rad(65), deg_to_rad(155), 20, Color("34a853"), lw, true)
			draw_arc(c, r, deg_to_rad(155), deg_to_rad(245), 20, Color("4285f4"), lw, true)
			draw_rect(Rect2(c.x + 0.5 * u, c.y - 1.7 * u, 8.0 * u, 3.4 * u), Color("4285f4"))
		S_FACEBOOK:
			draw_circle(c, 9.0 * u, Color.WHITE)
			var blue := Color("1877f2")
			draw_rect(Rect2(c.x - 1.4 * u, c.y - 8.0 * u, 3.0 * u, 16.0 * u), blue)
			draw_rect(Rect2(c.x - 5.0 * u, c.y - 1.5 * u, 9.0 * u, 2.6 * u), blue)
			draw_arc(c + Vector2(-0.6, -5.8) * u, 2.9 * u, deg_to_rad(180), deg_to_rad(360), 12, blue, 2.6 * u, true)

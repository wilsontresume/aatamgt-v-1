extends Control
## Procedural daytime temple-jungle backdrop for the login screen, drawn
## in code to match the arcade menu's original artwork family: bright blue
## sky, warm sun, sandstone gopurams, side pillars with vines, fire bowls,
## elephant statues and a stone mandala floor. Decorative only — never
## intercepts input.


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)
	queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	if w < 2.0 or h < 2.0:
		return
	var horizon := h * 0.72

	# --- Day sky gradient (blue -> warm haze at horizon) ----------------
	_paint_gradient(Rect2(0, 0, w, horizon * 0.72), Color("2f6db8"), Color("7fb3e0"))
	_paint_gradient(Rect2(0, horizon * 0.6, w, horizon * 0.4),
			Color("7fb3e0"), Color("ffd9a8"))

	# --- Sun + rays behind the centre -----------------------------------
	var sun_c := Vector2(w * 0.5, horizon * 0.42)
	for i in range(12):
		var a := TAU * float(i) / 12.0
		var pts := PackedVector2Array([
			sun_c,
			sun_c + Vector2(cos(a - 0.1), sin(a - 0.1)) * h * 0.22,
			sun_c + Vector2(cos(a + 0.1), sin(a + 0.1)) * h * 0.22])
		draw_colored_polygon(pts, Color(1.0, 0.92, 0.6, 0.10))
	for i in range(6, 0, -1):
		draw_circle(sun_c, 26.0 + i * 22.0, Color(1.0, 0.9, 0.55, 0.05))
	draw_circle(sun_c, 30.0, Color(1.0, 0.95, 0.7, 0.65))
	draw_circle(sun_c, 20.0, Color(1.0, 1.0, 0.9, 0.9))

	# --- Puffy clouds ---------------------------------------------------
	_draw_cloud(Vector2(w * 0.18, horizon * 0.22), 34.0)
	_draw_cloud(Vector2(w * 0.78, horizon * 0.18), 40.0)
	_draw_cloud(Vector2(w * 0.55, horizon * 0.30), 26.0)

	# --- Gopuram towers (day-lit sandstone, not silhouettes) ------------
	_draw_gopuram(Vector2(w * 0.16, horizon), w * 0.17, horizon * 0.62)
	_draw_gopuram(Vector2(w * 0.84, horizon), w * 0.17, horizon * 0.62)

	# --- Mid treeline along horizon -------------------------------------
	_draw_foliage(Vector2(w * 0.30, horizon + 6), 60.0, Color("2d6a3a"), 10)
	_draw_foliage(Vector2(w * 0.70, horizon + 4), 64.0, Color("276036"), 11)
	_draw_foliage(Vector2(w * 0.50, horizon + 10), 46.0, Color("2a6438"), 8)

	# --- Stone floor + mandala ------------------------------------------
	var floor_top := horizon
	_paint_gradient(Rect2(0, floor_top, w, h - floor_top),
			Color("f0d9a8"), Color("c9955a"))
	# Slab joints.
	var slab_y := floor_top + 14.0
	var slab_row := 0
	while slab_y < h:
		var t := (slab_y - floor_top) / maxf(1.0, h - floor_top)
		draw_line(Vector2(0, slab_y), Vector2(w, slab_y),
				Color(0.62, 0.45, 0.26, 0.35), 1.5)
		var joint_x := w * 0.5 + (float(slab_row % 2) - 0.5) * w * 0.22
		draw_line(Vector2(joint_x, slab_y), Vector2(joint_x, slab_y + 18.0 + t * 12.0),
				Color(0.62, 0.45, 0.26, 0.28), 1.2)
		slab_y += 18.0 + t * 12.0
		slab_row += 1
	_draw_mandala(Vector2(w * 0.5, h * 0.93), minf(w * 0.30, h * 0.16))

	# --- Side pillars with vines ----------------------------------------
	_draw_pillar(Vector2(0, 0), w, h, true)
	_draw_pillar(Vector2(w, 0), w, h, false)

	# --- Fire bowls on the pillars --------------------------------------
	_draw_fire_bowl(Vector2(w * 0.09, h * 0.40), 1.0)
	_draw_fire_bowl(Vector2(w * 0.91, h * 0.40), 1.0)

	# --- Elephant statues on the floor corners ---------------------------
	_draw_elephant(Vector2(w * 0.14, h * 0.82), minf(w * 0.13, h * 0.10), false)
	_draw_elephant(Vector2(w * 0.86, h * 0.82), minf(w * 0.13, h * 0.10), true)

	# --- Lotus flowers + floating petals ---------------------------------
	_draw_lotus(Vector2(w * 0.24, h * 0.95), minf(w * 0.05, 26.0))
	_draw_lotus(Vector2(w * 0.76, h * 0.95), minf(w * 0.05, 26.0))
	var petal_colors := [Color("ff6b8a"), Color("ffc94d"), Color("e85aaa")]
	var petal_rng := RandomNumberGenerator.new()
	petal_rng.seed = 20261013
	for i in range(14):
		var px := petal_rng.randf_range(w * 0.08, w * 0.92)
		var py := petal_rng.randf_range(h * 0.10, h * 0.80)
		var pr := petal_rng.randf_range(2.0, 4.0)
		var pc: Color = petal_colors[petal_rng.randi_range(0, 2)]
		draw_circle(Vector2(px, py), pr, Color(pc.r, pc.g, pc.b, 0.5))


## Vertical gradient painted as horizontal bands.
func _paint_gradient(rect: Rect2, top: Color, bottom: Color) -> void:
	const BANDS := 14
	for i in range(BANDS):
		var t := float(i) / float(BANDS - 1)
		var c := top.lerp(bottom, t)
		var band_h := rect.size.y / float(BANDS) + 1.0
		draw_rect(Rect2(rect.position.x, rect.position.y + band_h * i,
				rect.size.x, band_h), c)


## Fluffy cloud from overlapping white circles.
func _draw_cloud(at: Vector2, r: float) -> void:
	var col := Color(1, 1, 1, 0.85)
	draw_circle(at + Vector2(-r * 0.7, r * 0.1), r * 0.6, col)
	draw_circle(at + Vector2(0, -r * 0.2), r * 0.8, col)
	draw_circle(at + Vector2(r * 0.7, r * 0.15), r * 0.55, col)
	draw_rect(Rect2(at.x - r * 1.3, at.y, r * 2.6, r * 0.5), col)


## Day-lit sandstone gopuram: tiers with a light face, shadow edge,
## dome, finial and a red flag — base_y is the tower foot.
func _draw_gopuram(base: Vector2, base_w: float, tower_h: float) -> void:
	var stone := Color("e8c07a")
	var stone_lo := Color("d9a85c")
	var stone_sh := Color("c48a3e")
	var tiers := 5
	var tier_h := tower_h / float(tiers + 1)
	var y := base.y
	for tier in range(tiers):
		var tw := base_w * (1.0 - float(tier) * 0.14)
		var x := base.x - tw * 0.5
		draw_rect(Rect2(x, y - tier_h, tw, tier_h + 1.0), stone)
		draw_rect(Rect2(x + tw * 0.72, y - tier_h, tw * 0.28, tier_h + 1.0), stone_lo)
		# Cornice lip.
		draw_rect(Rect2(x - tw * 0.07, y - tier_h - 4.0,
				tw * 1.14, 5.0), stone_sh)
		# Little niche windows.
		var niches := 3 if tier < 3 else 2
		for n in range(niches):
			var nx := x + tw * (float(n) + 0.5) / float(niches) - tw * 0.06
			draw_rect(Rect2(nx, y - tier_h * 0.72, tw * 0.12, tier_h * 0.42),
					stone_sh)
		y -= tier_h + 4.0
	# Dome + finial + flag.
	draw_circle(Vector2(base.x, y - base_w * 0.10), base_w * 0.20, stone)
	draw_circle(Vector2(base.x + base_w * 0.07, y - base_w * 0.10),
			base_w * 0.13, stone_lo)
	draw_rect(Rect2(base.x - base_w * 0.03, y - base_w * 0.42,
			base_w * 0.06, base_w * 0.24), stone_sh)
	draw_circle(Vector2(base.x, y - base_w * 0.46), base_w * 0.05,
			Color("e8a020"))
	# Flag pole + pennant.
	draw_rect(Rect2(base.x - 1.5, y - base_w * 0.78, 3.0, base_w * 0.32),
			stone_sh)
	var flag := PackedVector2Array([
		Vector2(base.x + 1.5, y - base_w * 0.78),
		Vector2(base.x + base_w * 0.22, y - base_w * 0.70),
		Vector2(base.x + 1.5, y - base_w * 0.62)])
	draw_colored_polygon(flag, Color("d9432f"))


## Overlapping-circle jungle bush.
func _draw_foliage(origin: Vector2, radius: float, color: Color, count: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(origin.x * 31.0 + origin.y * 17.0)
	for i in range(count):
		var ang := rng.randf_range(0.0, TAU)
		var dist := rng.randf_range(0.0, radius * 0.7)
		var r := rng.randf_range(radius * 0.18, radius * 0.42)
		var p := origin + Vector2(cos(ang), sin(ang) * 0.7) * dist
		var shade := rng.randf_range(-0.08, 0.1)
		var c := color.lightened(maxf(0.0, shade)).darkened(maxf(0.0, -shade))
		draw_circle(p, r, Color(c.r, c.g, c.b, 0.92))


## Full-height stone pillar on one screen edge with joint lines, capital
## blocks and trailing vines on the inner side.
func _draw_pillar(at: Vector2, w: float, h: float, on_left: bool) -> void:
	var pw := minf(w * 0.075, 54.0)
	var x := 0.0 if on_left else w - pw
	var stone := Color("d9a05c")
	var stone_lo := Color("c48a3e")
	var stone_sh := Color("b07830")
	draw_rect(Rect2(x, 0, pw, h), stone)
	# Inner shadow edge.
	var sx := x + pw * 0.72 if on_left else x
	draw_rect(Rect2(sx, 0, pw * 0.28, h), stone_lo)
	# Horizontal joints.
	var jy := 40.0
	while jy < h:
		draw_rect(Rect2(x, jy, pw, 3.0), stone_sh)
		jy += 56.0
	# Capital blocks.
	for cy in [h * 0.16, h * 0.55]:
		draw_rect(Rect2(x - 4.0, cy, pw + 8.0, 12.0), stone_sh)
	# Vine: green stem + leaves on the inner edge.
	var vine_x := (x + pw + 3.0) if on_left else (x - 3.0)
	var stem := Color("2d6a3a")
	var leaf := Color("3d8a4a")
	var vy := 20.0
	var phase := 1.0 if on_left else -1.0
	while vy < h:
		draw_line(Vector2(vine_x + sin(vy * 0.04) * 5.0 * phase, vy),
				Vector2(vine_x + sin((vy + 40.0) * 0.04) * 5.0 * phase, vy + 40.0),
				stem, 2.4)
		draw_circle(Vector2(vine_x + sin(vy * 0.04) * 9.0 * phase, vy + 8.0),
				5.5, leaf)
		draw_circle(Vector2(vine_x + sin((vy + 22.0) * 0.04) * 9.0 * phase, vy + 30.0),
				4.5, Color("2d6a3a"))
		vy += 48.0


## Fire bowl bracketed to a pillar: stand, bowl, glow, flame.
func _draw_fire_bowl(at: Vector2, s: float) -> void:
	var stone := Color("8a5c30")
	var stone_hi := Color("a07040")
	draw_rect(Rect2(at.x - 8.0 * s, at.y, 16.0 * s, 34.0 * s), stone)
	draw_rect(Rect2(at.x - 12.0 * s, at.y + 32.0 * s, 24.0 * s, 7.0 * s), stone_hi)
	draw_rect(Rect2(at.x - 14.0 * s, at.y - 7.0 * s, 28.0 * s, 9.0 * s), stone_hi)
	draw_circle(Vector2(at.x, at.y - 14.0 * s), 16.0 * s, Color(1.0, 0.65, 0.15, 0.16))
	draw_circle(Vector2(at.x, at.y - 14.0 * s), 9.0 * s, Color(1.0, 0.72, 0.2, 0.5))
	draw_circle(Vector2(at.x, at.y - 15.0 * s), 5.0 * s, Color(1.0, 0.88, 0.45, 0.95))
	draw_circle(Vector2(at.x, at.y - 16.0 * s), 2.4 * s, Color(1.0, 1.0, 0.85, 1.0))


## Concentric ring + petal mandala inlaid on the floor.
func _draw_mandala(at: Vector2, r: float) -> void:
	var ring := Color(0.72, 0.5, 0.28, 0.55)
	var petal := Color(0.85, 0.35, 0.4, 0.35)
	draw_arc(at, r, 0.0, TAU, 48, ring, 2.5, true)
	draw_arc(at, r * 0.7, 0.0, TAU, 40, ring, 2.0, true)
	draw_arc(at, r * 0.35, 0.0, TAU, 32, ring, 1.6, true)
	for i in range(8):
		var a := TAU * float(i) / 8.0
		var dir := Vector2(cos(a), sin(a))
		var pc := PackedVector2Array([
			at + dir * r * 0.35,
			at + dir.rotated(0.35) * r * 0.66,
			at + dir * r * 0.98,
			at + dir.rotated(-0.35) * r * 0.66])
		draw_colored_polygon(pc, petal)
	draw_circle(at, r * 0.16, Color(0.8, 0.55, 0.25, 0.6))


## Side-facing stone elephant (mirrorable). s = body radius.
func _draw_elephant(at: Vector2, s: float, face_left: bool) -> void:
	var stone := Color("caa473")
	var stone_lo := Color("b08a58")
	var stone_sh := Color("96724a")
	var dir := -1.0 if face_left else 1.0
	# Body.
	draw_circle(at, s, stone)
	draw_circle(at + Vector2(0, s * 0.3), s * 0.7, stone_lo)
	# Head.
	var head := at + Vector2(dir * s * 1.15, -s * 0.1)
	draw_circle(head, s * 0.62, stone)
	# Ear.
	draw_circle(head + Vector2(-dir * s * 0.35, -s * 0.05), s * 0.42, stone_lo)
	# Trunk: arcs down then curling out.
	draw_arc(head + Vector2(dir * s * 0.35, s * 0.45), s * 0.5,
			deg_to_rad(20 if dir > 0 else 160),
			deg_to_rad(110 if dir > 0 else 250), 12, stone, s * 0.22, true)
	draw_circle(head + Vector2(dir * s * 0.55, s * 0.95), s * 0.12, stone_sh)
	# Tusk.
	var tusk := PackedVector2Array([
		head + Vector2(dir * s * 0.55, s * 0.35),
		head + Vector2(dir * s * 0.95, s * 0.55),
		head + Vector2(dir * s * 0.6, s * 0.5)])
	draw_colored_polygon(tusk, Color("f2ead8"))
	# Eye.
	draw_circle(head + Vector2(dir * s * 0.3, -s * 0.15), s * 0.07, stone_sh)
	# Legs.
	for lx in [-0.55, -0.15, 0.25, 0.6]:
		draw_rect(Rect2(at.x + lx * s - s * 0.14, at.y + s * 0.5,
				s * 0.28, s * 0.7), stone_lo)
		draw_rect(Rect2(at.x + lx * s - s * 0.16, at.y + s * 1.1,
				s * 0.32, s * 0.14), stone_sh)
	# Tail.
	draw_line(at + Vector2(-dir * s * 0.95, -s * 0.2),
			at + Vector2(-dir * s * 1.15, s * 0.35), stone_sh, 2.4)


## Pink lotus bloom with layered petals + gold centre.
func _draw_lotus(at: Vector2, r: float) -> void:
	var outer := Color("e85aaa")
	var inner := Color("ff8fc0")
	for i in range(8):
		var a := TAU * float(i) / 8.0
		var dir := Vector2(cos(a), sin(a) * 0.6)
		draw_circle(at + dir * r * 0.55, r * 0.38, outer)
	for i in range(6):
		var a := TAU * float(i) / 6.0 + 0.4
		var dir := Vector2(cos(a), sin(a) * 0.55)
		draw_circle(at + dir * r * 0.28, r * 0.26, inner)
	draw_circle(at, r * 0.16, Color("ffd76a"))

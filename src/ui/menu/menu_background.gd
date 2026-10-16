extends Control
## Procedural main-menu environment: dusk sky, sun glow, layered temple
## (gopuram) silhouettes, jungle foliage and a stone path. All original
## artwork drawn in code — no external image assets, no flattened
## screenshot. Decorative only: never intercepts input.


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)
	# Phase E: published home background art draws over the procedural
	# scene when the content manifest provides one and it has downloaded.
	if App != null and App.content != null:
		if not App.content.asset_ready.is_connected(_on_asset_ready):
			App.content.asset_ready.connect(_on_asset_ready)
		var _tex := App.content.home_texture()
	queue_redraw()


func _on_asset_ready(_asset_id: String) -> void:
	if is_inside_tree():
		queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	if w < 2.0 or h < 2.0:
		return
	var home_tex: Texture2D = null
	if App != null and App.content != null:
		home_tex = App.content.home_texture()
	if home_tex != null:
		draw_texture_rect(home_tex, Rect2(0, 0, w, h), true)
		return
	var horizon := h * 0.52

	# --- Dusk sky gradient (indigo -> violet -> warm sunset) -------------
	_paint_gradient(Rect2(0, 0, w, horizon), Color("1b1040"), Color("6b2d5c"))
	_paint_gradient(Rect2(0, horizon * 0.55, w, horizon * 0.45),
			Color("6b2d5c"), Color("ff7847"))
	_paint_gradient(Rect2(0, horizon * 0.85, w, h - horizon * 0.85),
			Color("ff7847"), Color("ffb35c"))

	# --- Sun glow behind the skyline -------------------------------------
	var sun_c := Vector2(w * 0.5, horizon * 0.92)
	for i in range(6, 0, -1):
		var r := 30.0 + i * 26.0
		draw_circle(sun_c, r, Color(1.0, 0.85, 0.45, 0.045))
	draw_circle(sun_c, 34.0, Color(1.0, 0.9, 0.6, 0.55))
	draw_circle(sun_c, 24.0, Color(1.0, 0.95, 0.75, 0.8))

	# --- Far temple silhouettes (hazy, lightest) -------------------------
	_draw_gopuram_row(w, horizon, 0.55, Color("8a4a6b"), 5, 0.5)

	# --- Mid temples -----------------------------------------------------
	_draw_gopuram_row(w, horizon, 0.78, Color("5c2d4e"), 4, 0.75)

	# --- Near temples (darkest, largest) ---------------------------------
	_draw_gopuram_row(w, horizon, 1.0, Color("341638"), 3, 1.0)

	# --- Ground: warm stone courtyard ------------------------------------
	var ground_top := horizon * 0.985
	_paint_gradient(Rect2(0, ground_top, w, h - ground_top),
			Color("4a2a1e"), Color("2a1810"))
	# Path stones down the middle.
	var path_cx := w * 0.5
	var stone_y := ground_top + 10.0
	var row := 0
	while stone_y < h + 20.0:
		var t := (stone_y - ground_top) / maxf(1.0, h - ground_top)
		var stone_w := lerpf(40.0, 110.0, t)
		var stone_h := lerpf(12.0, 30.0, t)
		var offset := (w * 0.14) * t
		var col := Color("6b4430") if row % 2 == 0 else Color("7a5238")
		draw_rect(Rect2(path_cx - stone_w * 0.5 - offset * 0.15,
				stone_y, stone_w, stone_h), col)
		stone_y += stone_h + lerpf(8.0, 16.0, t)
		row += 1

	# --- Foliage clusters at the edges (jungle framing) ------------------
	_draw_foliage(Vector2(-10, h * 0.18), 90.0, Color("1c4a28"), 14)
	_draw_foliage(Vector2(w + 10, h * 0.15), 100.0, Color("173f22"), 15)
	_draw_foliage(Vector2(-6, h * 0.62), 70.0, Color("1a4324"), 10)
	_draw_foliage(Vector2(w + 6, h * 0.58), 78.0, Color("163a20"), 11)
	_draw_foliage(Vector2(w * 0.12, h + 20), 110.0, Color("123018"), 13)
	_draw_foliage(Vector2(w * 0.88, h + 24), 120.0, Color("123018"), 14)

	# --- Diyas (oil lamps) flanking the path -----------------------------
	_draw_diya(Vector2(path_cx - w * 0.22, ground_top + h * 0.16))
	_draw_diya(Vector2(path_cx + w * 0.22, ground_top + h * 0.16))
	_draw_diya(Vector2(path_cx - w * 0.30, ground_top + h * 0.30), 0.8)
	_draw_diya(Vector2(path_cx + w * 0.30, ground_top + h * 0.30), 0.8)

	# --- Floating petals (static sprinkles) ------------------------------
	var petal_colors := [Color("ff6b8a"), Color("ffc94d"), Color("ff8c42"), Color("e85aaa")]
	var petal_rng := RandomNumberGenerator.new()
	petal_rng.seed = 20261012
	for i in range(18):
		var px := petal_rng.randf_range(0.0, w)
		var py := petal_rng.randf_range(h * 0.08, h * 0.75)
		var pr := petal_rng.randf_range(2.0, 4.5)
		var pc: Color = petal_colors[petal_rng.randi_range(0, petal_colors.size() - 1)]
		draw_circle(Vector2(px, py), pr, Color(pc.r, pc.g, pc.b, 0.55))


## Vertical multi-stop gradient painted as horizontal bands (cheap and
## artifact-free enough for a mobile backdrop).
func _paint_gradient(rect: Rect2, top: Color, bottom: Color) -> void:
	const BANDS := 14
	for i in range(BANDS):
		var t := float(i) / float(BANDS - 1)
		var c := top.lerp(bottom, t)
		var band_h := rect.size.y / float(BANDS) + 1.0
		draw_rect(Rect2(rect.position.x, rect.position.y + band_h * i,
				rect.size.x, band_h), c)


## A row of gopuram (temple tower) silhouettes across the horizon.
func _draw_gopuram_row(w: float, horizon: float, scale: float, color: Color,
		count: int, alpha_scale: float) -> void:
	var slot := w / float(count)
	for i in range(count):
		var cx: float = slot * (float(i) + 0.5) + sin(float(i) * 1.7) * slot * 0.1
		var base_w := slot * 0.42 * scale
		var tiers := 4
		var tier_h := 22.0 * scale
		var y := horizon
		var c := Color(color.r, color.g, color.b, 0.85 * alpha_scale)
		# Tiered tower body.
		for tier in range(tiers):
			var tw := base_w * (1.0 - float(tier) * 0.16)
			draw_rect(Rect2(cx - tw * 0.5, y - tier_h, tw, tier_h + 2.0), c)
			# Small cornice lip.
			draw_rect(Rect2(cx - tw * 0.58, y - tier_h - 4.0 * scale,
					tw * 1.16, 5.0 * scale), c)
			y -= tier_h + 4.0 * scale
		# Dome (shikhara) crown.
		draw_circle(Vector2(cx, y - 6.0 * scale), base_w * 0.22, c)
		# Finial spike.
		draw_rect(Rect2(cx - 2.0 * scale, y - 20.0 * scale,
				4.0 * scale, 16.0 * scale), c)


## Cluster of overlapping circles reading as a jungle bush / canopy.
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


## Stone lamp post with a glowing flame.
func _draw_diya(at: Vector2, s: float = 1.0) -> void:
	var stone := Color("5a4030")
	var stone_hi := Color("6e5040")
	# Pedestal.
	draw_rect(Rect2(at.x - 10.0 * s, at.y, 20.0 * s, 26.0 * s), stone)
	draw_rect(Rect2(at.x - 14.0 * s, at.y + 24.0 * s, 28.0 * s, 8.0 * s), stone_hi)
	# Bowl.
	draw_rect(Rect2(at.x - 12.0 * s, at.y - 8.0 * s, 24.0 * s, 10.0 * s), stone_hi)
	# Flame glow + flame.
	draw_circle(Vector2(at.x, at.y - 16.0 * s), 14.0 * s, Color(1.0, 0.7, 0.2, 0.18))
	draw_circle(Vector2(at.x, at.y - 16.0 * s), 8.0 * s, Color(1.0, 0.75, 0.25, 0.5))
	draw_circle(Vector2(at.x, at.y - 17.0 * s), 4.5 * s, Color(1.0, 0.9, 0.5, 0.95))
	draw_circle(Vector2(at.x, at.y - 18.0 * s), 2.2 * s, Color(1.0, 1.0, 0.9, 1.0))

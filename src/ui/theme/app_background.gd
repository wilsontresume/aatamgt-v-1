class_name AppBackground
extends Control
## Shared colorful full-screen background for every screen.
## Procedural daytime temple-jungle scene: sky-blue sunrise gradient,
## sun, clouds, gopuram silhouettes, treeline, foliage corners and a
## stone courtyard floor. Draws once per resize; mouse-transparent.

var _seed := 7


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	resized.connect(queue_redraw)
	queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	if w < 2.0 or h < 2.0:
		return
	var ground_y := h * 0.78

	# --- Sky: sunrise gradient (deep blue -> warm haze) ------------------
	_paint_gradient(Rect2(0, 0, w, ground_y + 2.0), [
		[0.0, Color("1565c0")],
		[0.35, Color("42a5f5")],
		[0.62, Color("81d4fa")],
		[0.85, Color("ffe082")],
		[1.0, Color("ffb74d")],
	])

	# --- Sun glow --------------------------------------------------------
	var sun_c := Vector2(w * 0.72, ground_y * 0.42)
	draw_circle(sun_c, h * 0.09, Color(1.0, 0.95, 0.7, 0.55))
	draw_circle(sun_c, h * 0.055, Color(1.0, 0.9, 0.5, 0.85))
	draw_circle(sun_c, h * 0.035, Color(1.0, 0.98, 0.85, 1.0))

	# --- Soft clouds -----------------------------------------------------
	_cloud(Vector2(w * 0.18, h * 0.12), w * 0.16)
	_cloud(Vector2(w * 0.55, h * 0.07), w * 0.12)
	_cloud(Vector2(w * 0.85, h * 0.18), w * 0.14)

	# --- Distant gopuram silhouettes (warm sandstone haze) ---------------
	_gopuram(Vector2(w * 0.12, ground_y), w * 0.2, ground_y * 0.42,
			Color(0.85, 0.62, 0.42, 0.55))
	_gopuram(Vector2(w * 0.82, ground_y), w * 0.24, ground_y * 0.52,
			Color(0.82, 0.58, 0.38, 0.6))
	_gopuram(Vector2(w * 0.48, ground_y), w * 0.18, ground_y * 0.34,
			Color(0.88, 0.66, 0.45, 0.45))

	# --- Treeline --------------------------------------------------------
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed
	var x := -20.0
	while x < w + 40.0:
		var tw := rng.randf_range(26.0, 56.0)
		var th := rng.randf_range(40.0, 90.0)
		var shade := rng.randf_range(0.18, 0.32)
		var col := Color(0.1 + shade * 0.2, 0.45 + shade * 0.3, 0.18 + shade * 0.15, 0.85)
		draw_circle(Vector2(x + tw * 0.5, ground_y - th * 0.3), tw * 0.55, col)
		draw_circle(Vector2(x + tw * 0.2, ground_y - th * 0.15), tw * 0.4, col.darkened(0.1))
		x += tw * 0.6

	# --- Stone courtyard -------------------------------------------------
	_paint_gradient(Rect2(0, ground_y, w, h - ground_y), [
		[0.0, Color("8d6e4a")],
		[0.35, Color("a1825a")],
		[1.0, Color("6d5138")],
	])
	# Path stones down the middle.
	var stone_w := w * 0.16
	var sy := ground_y + 10.0
	while sy < h:
		var jitter := rng.randf_range(-stone_w * 0.2, stone_w * 0.2)
		var r := Rect2(w * 0.5 - stone_w * 0.5 + jitter, sy, stone_w, stone_w * 0.45)
		draw_rect(r, Color(0.72, 0.6, 0.44, 0.55))
		draw_rect(Rect2(r.position + Vector2(2, 2), r.size - Vector2(4, 4)),
				Color(0.78, 0.66, 0.5, 0.35))
		sy += stone_w * 0.62

	# --- Foreground foliage corners (leafy green vignette) ---------------
	_foliage(Vector2(0, h), w * 0.34, h * 0.22, true)
	_foliage(Vector2(w, h), w * 0.34, h * 0.22, false)
	_foliage(Vector2(0, 0), w * 0.22, h * 0.12, true)
	_foliage(Vector2(w, 0), w * 0.22, h * 0.12, false)

	# --- Subtle warm vignette at edges ------------------------------------
	draw_circle(Vector2(w * 0.5, h * 0.5), max(w, h) * 0.75, Color(0, 0, 0, 0))


func _paint_gradient(rect: Rect2, stops: Array) -> void:
	# stops: [[offset, Color], ...] top-to-bottom band gradient.
	var bands := 48
	var band_h := rect.size.y / float(bands)
	for i in bands:
		var f := (i + 0.5) / float(bands)
		var c := _sample_stops(stops, f)
		draw_rect(Rect2(rect.position.x, rect.position.y + band_h * i,
				rect.size.x, band_h + 1.0), c)


func _sample_stops(stops: Array, f: float) -> Color:
	if f <= float(stops[0][0]):
		return stops[0][1]
	for i in range(1, stops.size()):
		if f <= float(stops[i][0]):
			var t0 := float(stops[i - 1][0])
			var t1 := float(stops[i][0])
			var k := 0.0 if t1 <= t0 else (f - t0) / (t1 - t0)
			return (stops[i - 1][1] as Color).lerp(stops[i][1] as Color, k)
	return stops[stops.size() - 1][1]


func _cloud(at: Vector2, width: float) -> void:
	var c := Color(1, 1, 1, 0.55)
	draw_circle(at, width * 0.28, c)
	draw_circle(at + Vector2(-width * 0.22, width * 0.06), width * 0.2, c)
	draw_circle(at + Vector2(width * 0.22, width * 0.05), width * 0.22, c)
	draw_circle(at + Vector2(width * 0.05, -width * 0.12), width * 0.18, c)


func _gopuram(base: Vector2, width: float, height: float, col: Color) -> void:
	# Stepped temple tower silhouette.
	var tiers := 5
	var w_step := width
	var y := base.y
	for i in tiers:
		var th := height / float(tiers)
		var tw := w_step * (1.0 - 0.14 * i)
		draw_rect(Rect2(base.x - tw * 0.5, y - th, tw, th + 1.0), col)
		# Cornice
		draw_rect(Rect2(base.x - tw * 0.56, y - th - 6.0, tw * 1.12, 7.0),
				col.darkened(0.12))
		y -= th + 6.0
	# Finial
	draw_circle(Vector2(base.x, y - 8.0), width * 0.05, col.lightened(0.15))
	draw_rect(Rect2(base.x - 2.0, y - 20.0, 4.0, 14.0), col.lightened(0.1))


func _foliage(anchor: Vector2, fw: float, fh: float, left: bool) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed + (1 if left else 2)
	var greens := [Color("2e7d32"), Color("388e3c"), Color("43a047"), Color("558b2f")]
	for i in 14:
		var t := float(i) / 14.0
		var px: float
		var py: float
		if anchor.y > size.y * 0.5:
			# Bottom corners
			px = anchor.x + (fw * (1.0 - t) * (1.0 if left else -1.0)) \
					+ rng.randf_range(-fw * 0.1, fw * 0.1)
			py = anchor.y - fh * rng.randf_range(0.1, 1.0) * t
		else:
			# Top corners
			px = anchor.x + (fw * (1.0 - t) * (1.0 if left else -1.0)) \
					+ rng.randf_range(-fw * 0.1, fw * 0.1)
			py = anchor.y + fh * rng.randf_range(0.0, 0.9) * t
		var r := rng.randf_range(14.0, 40.0)
		var col: Color = greens[i % greens.size()]
		draw_circle(Vector2(px, py), r, Color(col.r, col.g, col.b, 0.75))

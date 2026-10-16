extends PanelContainer
## Selectable lobby game card. Draws original per-game artwork in code
## (no external illustrations exist), shows the title, and highlights
## itself with a bright gold outline + soft glow when selected. Side
## cards scale down slightly; every card stays fully tappable.

signal chosen(game_id: StringName)

@export var game_id: StringName = &"aadu_puli"
@export var title_text: String = "Aadu Puli Aattam"
@export var base_color: Color = Color("c96a20")

var selected: bool = false:
	set(value):
		if selected == value:
			return
		selected = value
		_refresh_style()
		queue_redraw()

var _tween: Tween = null


func _ready() -> void:
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	resized.connect(_on_resized)
	gui_input.connect(_on_gui_input)
	_refresh_style()
	_animate_scale(_target_scale(), 0.22)
	# Phase E: published card art from the content manifest (procedural
	# art stays the fallback; texture draws on top once downloaded).
	if App != null and App.content != null:
		if not App.content.asset_ready.is_connected(_on_asset_ready):
			App.content.asset_ready.connect(_on_asset_ready)
		var _tex := App.content.card_texture(String(game_id))


func _target_scale() -> Vector2:
	return Vector2(1.05, 1.05) if selected else Vector2(0.9, 0.9)


func _on_resized() -> void:
	queue_redraw()


func _on_asset_ready(_asset_id: String) -> void:
	if is_inside_tree():
		queue_redraw()


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		if OS.is_debug_build():
			print("UI: lobby card chosen -> %s" % game_id)
		App.analytics.track("game_selected", {}, String(game_id))
		chosen.emit(game_id)


func choose() -> void:
	## Called by the screen when another card was picked, so this one
	## deselects without re-emitting `chosen`.
	selected = false
	_animate_scale(_target_scale(), 0.18)


func pick() -> void:
	selected = true
	_animate_scale(_target_scale(), 0.18)


func _animate_scale(target: Vector2, duration: float) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	pivot_offset = size / 2.0
	_tween = create_tween()
	_tween.tween_property(self, "scale", target, duration) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _refresh_style() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.22, 0.28, 0.92)
	sb.set_corner_radius_all(18)
	if selected:
		sb.set_border_width_all(4)
		sb.border_color = AppTheme.C_GOLD_BRIGHT
		sb.shadow_color = Color(AppTheme.C_GOLD_BRIGHT.r,
				AppTheme.C_GOLD_BRIGHT.g, AppTheme.C_GOLD_BRIGHT.b, 0.55)
		sb.shadow_size = 16
		sb.shadow_offset = Vector2(0, 0)
	else:
		sb.set_border_width_all(2)
		sb.border_color = Color(1, 1, 1, 0.25)
		sb.shadow_color = Color(0, 0, 0, 0.4)
		sb.shadow_size = 6
		sb.shadow_offset = Vector2(0, 3)
	sb.content_margin_left = 5
	sb.content_margin_right = 5
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	add_theme_stylebox_override("panel", sb)


func _draw() -> void:
	# Art fills the inner rect above the title strip.
	var art := Rect2(Vector2(5, 5), size - Vector2(10, 10))
	if art.size.x < 8.0 or art.size.y < 8.0:
		return
	var title_h := 44.0
	var scene_rect := Rect2(art.position, Vector2(art.size.x, art.size.y - title_h))

	# Published card art (when present) draws over the procedural scene.
	var card_tex: Texture2D = null
	if App != null and App.content != null:
		card_tex = App.content.card_texture(String(game_id))
	if card_tex != null:
		draw_texture_rect(card_tex, scene_rect, true)
	else:
		match game_id:
			&"aadu_puli":
				_draw_aadu_puli(scene_rect)
			&"solah_seedi":
				_draw_solah_seedi(scene_rect)
			&"nine_mens_morris":
				_draw_morris(scene_rect)
			_:
				draw_rect(scene_rect, base_color)

	# Title strip with dark scrim for readability.
	var strip := Rect2(art.position + Vector2(0, art.size.y - title_h),
			Vector2(art.size.x, title_h))
	draw_rect(strip, Color(0, 0, 0, 0.55))
	# Gold underline flourish.
	draw_rect(Rect2(strip.position + Vector2(10, 0), Vector2(strip.size.x - 20, 2)),
			Color(AppTheme.C_GOLD_BRIGHT.r, AppTheme.C_GOLD_BRIGHT.g,
			AppTheme.C_GOLD_BRIGHT.b, 0.7 if selected else 0.35))
	var font := get_theme_default_font()
	var fsize := 15
	var lines := title_text.split("\n")
	var y := strip.position.y + 18.0
	for line in lines:
		var half := font.get_string_size(line, HORIZONTAL_ALIGNMENT_CENTER, -1, fsize)
		draw_string(font, Vector2(strip.position.x + (strip.size.x - half.x) * 0.5, y),
				line, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color("ffe9b0"))
		y += 16.0


# --- Per-game scenes (original procedural illustrations) ----------------

func _draw_aadu_puli(r: Rect2) -> void:
	# Jungle dusk backdrop.
	_gradient_rect(r, Color("1a3a20"), Color("e8a040"))
	# Temple hint in the background.
	var tw := r.size.x * 0.2
	draw_rect(Rect2(r.position.x + r.size.x * 0.72, r.position.y + r.size.y * 0.35,
			tw, r.size.y * 0.35), Color(0.2, 0.12, 0.08, 0.5))
	draw_circle(Vector2(r.position.x + r.size.x * 0.72 + tw * 0.5,
			r.position.y + r.size.y * 0.32), tw * 0.35, Color(0.2, 0.12, 0.08, 0.5))
	# The board: a triangle grid (Aadu Puli's pitch).
	var bc := Vector2(r.get_center().x, r.position.y + r.size.y * 0.62)
	var bw := r.size.x * 0.62
	var bh := r.size.y * 0.42
	var line := Color(0.95, 0.85, 0.6, 0.9)
	# Outer triangle.
	draw_colored_polygon(PackedVector2Array([
		Vector2(bc.x, bc.y - bh * 0.55),
		Vector2(bc.x - bw * 0.5, bc.y + bh * 0.45),
		Vector2(bc.x + bw * 0.5, bc.y + bh * 0.45)]), Color(0.45, 0.28, 0.12, 0.9))
	draw_polyline(PackedVector2Array([
		Vector2(bc.x, bc.y - bh * 0.55),
		Vector2(bc.x - bw * 0.5, bc.y + bh * 0.45),
		Vector2(bc.x + bw * 0.5, bc.y + bh * 0.45),
		Vector2(bc.x, bc.y - bh * 0.55)]), line, 2.0, true)
	# Cross bars.
	draw_line(Vector2(bc.x - bw * 0.25, bc.y + bh * 0.05),
			Vector2(bc.x + bw * 0.25, bc.y + bh * 0.05), line, 1.6)
	draw_line(Vector2(bc.x - bw * 0.375, bc.y + bh * 0.25),
			Vector2(bc.x + bw * 0.375, bc.y + bh * 0.25), line, 1.6)
	draw_line(Vector2(bc.x, bc.y - bh * 0.55), Vector2(bc.x, bc.y + bh * 0.45), line, 1.6)
	# Tiger piece (left) and goat piece (right) on the board.
	draw_circle(Vector2(bc.x - bw * 0.22, bc.y + bh * 0.22), r.size.x * 0.055,
			Color("f2994a"))
	draw_circle(Vector2(bc.x - bw * 0.22, bc.y + bh * 0.22), r.size.x * 0.03,
			Color("3a2410"))
	draw_circle(Vector2(bc.x + bw * 0.22, bc.y + bh * 0.22), r.size.x * 0.05,
			Color("f0ead8"))
	draw_circle(Vector2(bc.x + bw * 0.22, bc.y + bh * 0.22), r.size.x * 0.025,
			Color("8a7a5a"))
	# Large tiger + goat medallions top corners.
	_medallion(Vector2(r.position.x + r.size.x * 0.22, r.position.y + r.size.y * 0.2),
			r.size.x * 0.16, "tiger")
	_medallion(Vector2(r.position.x + r.size.x * 0.78, r.position.y + r.size.y * 0.2),
			r.size.x * 0.16, "goat")


func _draw_solah_seedi(r: Rect2) -> void:
	_gradient_rect(r, Color("5c1020"), Color("e8a040"))
	# Warrior helmet silhouette (center-top).
	var hc := Vector2(r.get_center().x, r.position.y + r.size.y * 0.32)
	var hr := r.size.x * 0.2
	draw_circle(hc, hr, Color("c9a227"))
	draw_circle(hc, hr * 0.72, Color("8a5a20"))
	# Plume.
	draw_circle(hc + Vector2(0, -hr * 1.15), hr * 0.28, Color("e8503a"))
	draw_circle(hc + Vector2(-hr * 0.2, -hr * 0.95), hr * 0.2, Color("e8503a"))
	# Eye slits.
	draw_rect(Rect2(hc + Vector2(-hr * 0.45, -hr * 0.1), Vector2(hr * 0.3, hr * 0.14)),
			Color(0.1, 0.05, 0.02))
	draw_rect(Rect2(hc + Vector2(hr * 0.15, -hr * 0.1), Vector2(hr * 0.3, hr * 0.14)),
			Color(0.1, 0.05, 0.02))
	# The Seedi (ladder) board below: cross-hatch grid with red pawns.
	var board := Rect2(r.position.x + r.size.x * 0.15,
			r.position.y + r.size.y * 0.58,
			r.size.x * 0.7, r.size.y * 0.34)
	draw_rect(board, Color(0.35, 0.2, 0.1, 0.85))
	var gl := Color("f0d090")
	for i in range(4):
		var fx := board.position.x + board.size.x * float(i) / 3.0
		draw_line(Vector2(fx, board.position.y),
				Vector2(fx, board.position.y + board.size.y), gl, 1.4)
	for j in range(3):
		var fy := board.position.y + board.size.y * float(j) / 2.0
		draw_line(Vector2(board.position.x, fy),
				Vector2(board.position.x + board.size.x, fy), gl, 1.4)
	# Red pawn discs on intersections.
	var pr := board.size.x * 0.055
	var spots := [Vector2(0, 0), Vector2(1, 0), Vector2(2, 1), Vector2(3, 0), Vector2(1, 2)]
	for spot in spots:
		var px := board.position.x + board.size.x * float(spot.x) / 3.0
		var py := board.position.y + board.size.y * float(spot.y) / 2.0
		draw_circle(Vector2(px, py), pr, Color("e8503a"))
		draw_circle(Vector2(px, py), pr * 0.55, Color("a02020"))


func _draw_morris(r: Rect2) -> void:
	_gradient_rect(r, Color("0e3a40"), Color("d8b070"))
	# Classic 3-square Morris board, slightly rotated for depth.
	var bc := Vector2(r.get_center().x, r.get_center().y + r.size.y * 0.05)
	var s1 := r.size.x * 0.38
	var s2 := r.size.x * 0.25
	var s3 := r.size.x * 0.12
	var lw := 2.2
	var wood := Color("6b4430")
	draw_rect(Rect2(bc - Vector2(s1, s1 * 0.72), Vector2(s1 * 2, s1 * 1.44)), wood)
	draw_rect(Rect2(bc - Vector2(s2, s2 * 0.72), Vector2(s2 * 2, s2 * 1.44)),
			Color(0, 0, 0, 0))
	var gl := Color("f0d090")
	for s in [s1, s2, s3]:
		var rect := Rect2(bc - Vector2(s, s * 0.72), Vector2(s * 2, s * 1.44))
		draw_rect(rect, gl, false, lw)
	# Connecting lines midpoints.
	draw_line(Vector2(bc.x - s1, bc.y), Vector2(bc.x - s3, bc.y), gl, lw)
	draw_line(Vector2(bc.x + s1, bc.y), Vector2(bc.x + s3, bc.y), gl, lw)
	draw_line(Vector2(bc.x, bc.y - s1 * 0.72), Vector2(bc.x, bc.y - s3 * 0.72), gl, lw)
	draw_line(Vector2(bc.x, bc.y + s1 * 0.72), Vector2(bc.x, bc.y + s3 * 0.72), gl, lw)
	# Black and white pieces on a few points.
	var pr := r.size.x * 0.05
	var pieces := [
		[Vector2(bc.x - s1, bc.y - s1 * 0.72), Color("1c1c1c")],
		[Vector2(bc.x + s1, bc.y - s1 * 0.72), Color("f0ead8")],
		[Vector2(bc.x - s2, bc.y), Color("f0ead8")],
		[Vector2(bc.x + s2, bc.y), Color("1c1c1c")],
		[Vector2(bc.x, bc.y + s3 * 0.72), Color("1c1c1c")],
		[Vector2(bc.x - s3, bc.y + s3 * 0.72), Color("f0ead8")],
	]
	for p in pieces:
		draw_circle(p[0], pr, p[1])
		draw_circle(p[0], pr * 0.6, (p[1] as Color).darkened(0.15))


func _medallion(at: Vector2, radius: float, kind: String) -> void:
	draw_circle(at, radius, Color(0, 0, 0, 0.45))
	draw_circle(at, radius * 0.92, Color(AppTheme.C_GOLD_DEEP.r,
			AppTheme.C_GOLD_DEEP.g, AppTheme.C_GOLD_DEEP.b, 0.9))
	draw_circle(at, radius * 0.8, Color("2a1810"))
	# Mini tiger/goat face inline.
	if kind == "tiger":
		draw_circle(at, radius * 0.55, Color("f2994a"))
		draw_circle(at + Vector2(-radius * 0.3, -radius * 0.35), radius * 0.18, Color("f2994a"))
		draw_circle(at + Vector2(radius * 0.3, -radius * 0.35), radius * 0.18, Color("f2994a"))
		draw_circle(at + Vector2(-radius * 0.18, 0), radius * 0.08, Color("1c1c1c"))
		draw_circle(at + Vector2(radius * 0.18, 0), radius * 0.08, Color("1c1c1c"))
		draw_circle(at + Vector2(0, radius * 0.18), radius * 0.09, Color("5a3010"))
	else:
		draw_circle(at, radius * 0.55, Color("f0ead8"))
		draw_arc(at + Vector2(-radius * 0.22, -radius * 0.3), radius * 0.22,
				PI * 0.9, PI * 1.9, 10, Color("8a7a5a"), radius * 0.1, true)
		draw_arc(at + Vector2(radius * 0.22, -radius * 0.3), radius * 0.22,
				PI * 1.1, PI * 2.1, 10, Color("8a7a5a"), radius * 0.1, true)
		draw_circle(at + Vector2(-radius * 0.14, 0), radius * 0.07, Color("2a2a2a"))
		draw_circle(at + Vector2(radius * 0.14, 0), radius * 0.07, Color("2a2a2a"))


func _gradient_rect(r: Rect2, top: Color, bottom: Color) -> void:
	const BANDS := 12
	for i in range(BANDS):
		var t := float(i) / float(BANDS - 1)
		var band_h := r.size.y / float(BANDS) + 1.0
		draw_rect(Rect2(r.position.x, r.position.y + band_h * i, r.size.x, band_h),
				top.lerp(bottom, t))

class_name CosmeticFx
extends RefCounted
## Pure presentation for equipped cosmetics (Phase 12).
##
## The server decides WHICH effect is equipped (VICTORY_ANIMATION /
## CAPTURE_ANIMATION); this module only animates it locally on top of
## the screen. An empty style — the "none" cosmetics, or offline before
## the first fetch — is always a no-op.


## Expanding capture ring. Progress 0..1 drives radius and alpha.
class _Burst extends Control:
	var progress := 0.0
	var color := Color(1, 1, 1, 1)
	var heavy := false

	func set_progress(value: float) -> void:
		progress = value
		queue_redraw()

	func _draw() -> void:
		var center := size / 2.0
		var max_radius := minf(size.x, size.y) * 0.5
		var radius := lerpf(max_radius * 0.12, max_radius * 0.95, progress)
		var alpha := clampf(1.0 - progress, 0.0, 1.0)
		var line := Color(color.r, color.g, color.b, alpha)
		draw_arc(center, radius, 0.0, TAU, 64, line,
				lerpf(7.0, 1.5, progress), true)
		if heavy:
			var fill := Color(color.r, color.g, color.b, alpha * 0.16)
			draw_circle(center, radius, fill)
			draw_arc(center, radius * 0.72, 0.0, TAU, 48,
					Color(color.r, color.g, color.b, alpha * 0.6),
					lerpf(3.0, 1.0, progress), true)


## Celebration overlay above the whole screen. Fire-and-forget: the
## overlay cleans itself up after a few seconds.
static func victory(parent: Control, style: Dictionary) -> void:
	if parent == null or style.is_empty():
		return
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.z_index = 50
	parent.add_child(overlay)

	var colors: Array = style.get("colors", [Color.WHITE])
	var kind := str(style.get("kind", "confetti"))
	var particles := CPUParticles2D.new()
	particles.position = parent.size / 2.0
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	particles.emission_sphere_radius = 10.0
	particles.scale_amount_min = 3.0
	particles.scale_amount_max = 7.0
	particles.direction = Vector2.UP
	var ramp := Gradient.new()
	for i in colors.size():
		ramp.add_point(float(i) / float(maxi(colors.size() - 1, 1)), colors[i])
	particles.color_ramp = ramp

	if kind == "fireworks":
		particles.amount = 120
		particles.lifetime = 1.6
		particles.spread = 180.0
		particles.initial_velocity_min = 160.0
		particles.initial_velocity_max = 320.0
		particles.gravity = Vector2(0, 90.0)
	else:  # confetti
		particles.amount = 140
		particles.lifetime = 2.2
		particles.spread = 70.0
		particles.initial_velocity_min = 220.0
		particles.initial_velocity_max = 420.0
		particles.gravity = Vector2(0, 420.0)
		particles.angular_velocity_min = -360.0
		particles.angular_velocity_max = 360.0

	overlay.add_child(particles)
	particles.emitting = true
	var tree := overlay.get_tree()
	if tree != null:
		tree.create_timer(3.0).timeout.connect(_free_later.bind(overlay))


## The parent screen can be closed while an overlay is still showing.
static func _free_later(node: Node) -> void:
	if is_instance_valid(node):
		node.queue_free()


## Expanding ring (plus a soft shock disc for the heavy variant) drawn
## over the board at the moment of a capture.
static func capture(board: Control, style: Dictionary) -> void:
	if board == null or style.is_empty():
		return
	var burst := _Burst.new()
	burst.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	burst.mouse_filter = Control.MOUSE_FILTER_IGNORE
	burst.z_index = 40
	burst.color = style.get("color", Color.WHITE)
	burst.heavy = str(style.get("kind", "")) == "shockwave"
	board.add_child(burst)
	var tween := burst.create_tween()
	tween.tween_method(burst.set_progress, 0.0, 1.0, 0.55)
	tween.tween_callback(burst.queue_free)

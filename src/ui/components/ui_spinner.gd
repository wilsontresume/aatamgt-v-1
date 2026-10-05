extends Control
## Rotating arc spinner (procedural, no textures).


var _angle := 0.0


func _process(delta: float) -> void:
	_angle = fposmod(_angle + delta * 300.0, 360.0)
	queue_redraw()


func _draw() -> void:
	var center := size / 2.0
	var radius := maxf(8.0, minf(size.x, size.y) / 2.0 - 5.0)
	var accent := AppTheme.C_ACCENT
	draw_arc(center, radius, 0.0, TAU, 48, accent.darkened(0.72), 4.0, true)
	draw_arc(center, radius, deg_to_rad(_angle), deg_to_rad(_angle + 100.0),
			28, accent, 4.0, true)

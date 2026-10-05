extends Control
## Small gold coin icon, drawn procedurally (no image asset needed).


func _ready() -> void:
	resized.connect(queue_redraw)
	queue_redraw()


func _draw() -> void:
	var center := size / 2.0
	var radius := minf(size.x, size.y) / 2.0 - 1.0
	var accent := AppTheme.C_ACCENT
	draw_circle(center, radius, accent)
	draw_arc(center, radius - 1.5, 0.0, TAU, 40, AppTheme.C_ACCENT_PRESSED, 1.5, true)
	draw_circle(center, radius * 0.55, AppTheme.C_ACCENT_PRESSED)
	draw_circle(Vector2(center.x - radius * 0.25, center.y - radius * 0.25),
			radius * 0.18, AppTheme.C_ACCENT_HOVER)

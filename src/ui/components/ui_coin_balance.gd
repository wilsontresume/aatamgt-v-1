extends HBoxContainer
## Coin balance display; animates to the value owned by App.coins.

@onready var _label: Label = $AmountLabel

var _shown := 0
var _tween: Tween = null


func _ready() -> void:
	_shown = App.coins.get_balance()
	_label.text = _format(_shown)
	App.coins.balance_changed.connect(_on_balance_changed)


func _on_balance_changed(current: int, _previous: int) -> void:
	_animate_to(current)


func _animate_to(target: int) -> void:
	if _tween != null:
		_tween.kill()
	var from := float(_shown)
	if is_equal_approx(from, float(target)):
		_shown = target
		_label.text = _format(_shown)
		return
	_tween = create_tween()
	_tween.tween_method(_set_shown_float, from, float(target), 0.35)


func _set_shown_float(value: float) -> void:
	_shown = roundi(value)
	_label.text = _format(_shown)


func _format(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	var count := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return out if n >= 0 else "-" + out

class_name NineMensMorrisMove
extends RefCounted
## One requested move in Nine Men's Morris: a placement or a single
## edge step (or flight), plus the capture that its newly formed mill
## forces, if any. A pure value object — it carries no rules knowledge
## and never says whether it is legal; NineMensMorrisValidator decides
## that against a given state.
##
## Notation (spec §10): placements `P17`, `P17*22`, movements `17-18`,
## `17-18*22` (`*` marks a capture, the number after it is the removed
## point). Wire/JSON form: { "kind": "place", "point": 17,
## "capture": 22 } or { "kind": "move", "from": 17, "to": 18 }.

## -1 for "no capture" and for unused endpoints of the other kind.
const NONE_POINT := -1
const NONE_CAPTURE := -1

const KIND_PLACE := "place"
const KIND_MOVE := "move"

var kind: String = KIND_PLACE
var point: int = NONE_POINT
var from_point: int = NONE_POINT
var to_point: int = NONE_POINT
var capture: int = NONE_CAPTURE


func _init(p_kind: String = KIND_PLACE, p_point: int = NONE_POINT,
		p_from: int = NONE_POINT, p_to: int = NONE_POINT,
		p_capture: int = NONE_CAPTURE) -> void:
	kind = p_kind
	point = p_point
	from_point = p_from
	to_point = p_to
	capture = p_capture


static func place(p_point: int, p_capture: int = NONE_CAPTURE) -> NineMensMorrisMove:
	return NineMensMorrisMove.new(KIND_PLACE, p_point, NONE_POINT, NONE_POINT, p_capture)


static func step(p_from: int, p_to: int, p_capture: int = NONE_CAPTURE) -> NineMensMorrisMove:
	return NineMensMorrisMove.new(KIND_MOVE, NONE_POINT, p_from, p_to, p_capture)


## Landing point of the placement or movement (before any capture).
func land() -> int:
	return point if kind == KIND_PLACE else to_point


func has_capture() -> bool:
	return capture != NONE_CAPTURE


func to_dict() -> Dictionary:
	var wire: Dictionary = {"kind": kind}
	match kind:
		KIND_PLACE:
			wire["point"] = point
		KIND_MOVE:
			wire["from"] = from_point
			wire["to"] = to_point
	if has_capture():
		wire["capture"] = capture
	return wire


## Strict wire parser: null for anything that is not {kind:"place",
## point:int} / {kind:"move", from:int, to:int} with an optional whole-
## number capture — the client must never guess at a server payload.
## Bounds are the validator's job; this only checks shape, exactly like
## the server's fromWire (spec §10).
static func from_dict(data: Variant) -> NineMensMorrisMove:
	if not (data is Dictionary):
		return null
	var d := data as Dictionary
	var capture_value := NONE_CAPTURE
	if d.has("capture") and d["capture"] != null:
		var raw_capture: Variant = d["capture"]
		if not (raw_capture is int) and not (raw_capture is float):
			return null
		var whole_capture := int(raw_capture)
		if float(whole_capture) != float(raw_capture):
			return null
		capture_value = whole_capture
	var kind_text := str(d.get("kind", ""))
	if kind_text == KIND_PLACE:
		if not d.has("point"):
			return null
		var raw_point: Variant = d["point"]
		if not (raw_point is int) and not (raw_point is float):
			return null
		var whole_point := int(raw_point)
		if float(whole_point) != float(raw_point):
			return null
		return NineMensMorrisMove.place(whole_point, capture_value)
	if kind_text == KIND_MOVE:
		if not d.has("from") or not d.has("to"):
			return null
		var raw_from: Variant = d["from"]
		var raw_to: Variant = d["to"]
		if not (raw_from is int) and not (raw_from is float):
			return null
		if not (raw_to is int) and not (raw_to is float):
			return null
		var whole_from := int(raw_from)
		var whole_to := int(raw_to)
		if float(whole_from) != float(raw_from):
			return null
		if float(whole_to) != float(raw_to):
			return null
		return NineMensMorrisMove.step(whole_from, whole_to, capture_value)
	return null


func equals(other: NineMensMorrisMove) -> bool:
	if other == null:
		return false
	return kind == other.kind and point == other.point \
			and from_point == other.from_point \
			and to_point == other.to_point \
			and capture == other.capture

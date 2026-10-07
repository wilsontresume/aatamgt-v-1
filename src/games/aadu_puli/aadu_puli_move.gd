class_name AaduPuliMove
extends RefCounted
## One requested move in Aadu Puli Aattam. A pure value object: it
## carries no rules knowledge and never says whether it is legal —
## AaduPuliValidator decides that against a given state.
##
## Notation (per the spec): placement `12`, step `0-2`, jump `0-8*`.

enum Kind { PLACE, STEP, JUMP }

## -1 for unused fields (a placement has no origin/capture).
const NONE_POINT := -1

var kind: int = Kind.PLACE
var from_point: int = NONE_POINT
var to_point: int = NONE_POINT
var over_point: int = NONE_POINT  # captured goat, JUMP only


func _init(p_kind: int = Kind.PLACE, p_from: int = NONE_POINT,
		p_to: int = NONE_POINT, p_over: int = NONE_POINT) -> void:
	kind = p_kind
	from_point = p_from
	to_point = p_to
	over_point = p_over


static func place(p_to: int) -> AaduPuliMove:
	return AaduPuliMove.new(Kind.PLACE, NONE_POINT, p_to, NONE_POINT)


static func step(p_from: int, p_to: int) -> AaduPuliMove:
	return AaduPuliMove.new(Kind.STEP, p_from, p_to, NONE_POINT)


static func jump(p_from: int, p_over: int, p_to: int) -> AaduPuliMove:
	return AaduPuliMove.new(Kind.JUMP, p_from, p_to, p_over)


func is_capture() -> bool:
	return kind == Kind.JUMP


func notation() -> String:
	match kind:
		Kind.PLACE:
			return str(to_point)
		Kind.STEP:
			return "%d-%d" % [from_point, to_point]
		_:
			return "%d-%d*" % [from_point, to_point]


func to_dict() -> Dictionary:
	return {
		"kind": kind,
		"from": from_point,
		"to": to_point,
		"over": over_point,
	}


static func from_dict(data: Variant) -> AaduPuliMove:
	if not (data is Dictionary):
		return null
	var d := data as Dictionary
	if not (d.has("kind") and d.has("to")):
		return null
	var move_kind := int(d["kind"])
	if move_kind < 0 or move_kind > Kind.size() - 1:
		return null
	return AaduPuliMove.new(move_kind, int(d.get("from", NONE_POINT)),
			int(d["to"]), int(d.get("over", NONE_POINT)))


func equals(other: AaduPuliMove) -> bool:
	return other != null and kind == other.kind \
			and from_point == other.from_point \
			and to_point == other.to_point \
			and over_point == other.over_point

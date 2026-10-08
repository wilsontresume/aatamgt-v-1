class_name SolahSeediMove
extends RefCounted
## One requested move in Solah Seedi (16 Soldiers): the origin point
## followed by every landing point of the (possibly chained) move. A
## pure value object — it carries no rules knowledge and never says
## whether it is legal; SolahSeediValidator decides that against a
## given state.
##
## Notation (spec §4.4): step `6-7`, jump `6-18*`, chain `6-18-30*`
## (`*` marks a move containing at least one capture).
## Wire/JSON form: { "path": [6, 18, 30] }.

## -1 for an empty path (a move always has at least two points).
const NONE_POINT := -1
const MAX_PATH_POINTS := 16

var path: Array[int] = []


func _init(p_path: Array = []) -> void:
	for point in p_path:
		path.append(int(point))


static func step(p_from: int, p_to: int) -> SolahSeediMove:
	return SolahSeediMove.new([p_from, p_to])


static func from_path(p_path: Array) -> SolahSeediMove:
	return SolahSeediMove.new(p_path)


## Origin of the move, or NONE_POINT for an empty path.
func from_point() -> int:
	return path[0] if not path.is_empty() else NONE_POINT


## Final landing point, or NONE_POINT for an empty path.
func to_point() -> int:
	return path[path.size() - 1] if not path.is_empty() else NONE_POINT


func is_chain() -> bool:
	return path.size() > 2


func is_capture() -> bool:
	# A two-point path is a jump exactly when its ends are not adjacent;
	# anything longer contains at least one hop.
	if path.size() > 2:
		return true
	if path.size() == 2:
		return not SolahSeediRules.are_adjacent(path[0], path[1])
	return false


func to_dict() -> Dictionary:
	return {"path": path.duplicate()}


## Strict wire parser: null for anything that is not {path:[int, int, ...]}
## with 2..MAX_PATH_POINTS whole-number points — the client must never
## guess at a server payload.
static func from_dict(data: Variant) -> SolahSeediMove:
	if not (data is Dictionary):
		return null
	var d := data as Dictionary
	if not d.has("path"):
		return null
	var raw: Variant = d["path"]
	if not (raw is Array):
		return null
	var points := raw as Array
	if points.size() < 2 or points.size() > MAX_PATH_POINTS:
		return null
	var path_points: Array[int] = []
	for entry in points:
		if not (entry is int) and not (entry is float):
			return null
		var value := int(entry)
		if float(value) != float(entry):
			return null
		path_points.append(value)
	return SolahSeediMove.new(path_points)


func equals(other: SolahSeediMove) -> bool:
	if other == null or path.size() != other.path.size():
		return false
	for i in path.size():
		if path[i] != other.path[i]:
			return false
	return true

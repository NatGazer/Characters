extends Node3D
## Harness stub (not game code): full uncut 1.2 x .15 x 1.2 m, 32 kg stock plate so
## contraption_part.setup("armor") gets a finite centre/mesh/collider in the harness.
const STOCK_AREA = 1.0
const SIZE := Vector3(1.2, .15, 1.2)
static func closest_point(_definition: Dictionary, local_point: Vector3) -> Vector3: return local_point.clamp(-SIZE * .5, SIZE * .5)
static func collision_shapes(...args: Array) -> Array:
	var box := BoxShape3D.new()
	box.size = SIZE
	return [box]
static func cut_error(...args: Array) -> String: return "harness: plates are uncut"
static func describe(...args: Array) -> Dictionary: return {"mass": 32.0, "size": SIZE, "area": 1.0, "centre": Vector3.ZERO, "bounds": AABB(-SIZE * .5, SIZE)}
static func mesh(...args: Array) -> Mesh:
	var box := BoxMesh.new()
	box.size = SIZE
	return box
static func normalize(...args: Array) -> Dictionary: return {}
static func offcuts(...args: Array) -> Array: return []
static func same_shape(...args: Array) -> bool: return true

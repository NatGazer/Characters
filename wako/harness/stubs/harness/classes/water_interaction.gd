class_name WaterInteraction extends RefCounted
## Harness stub: RaulsMod's interactive water wake field is absent; report disabled.
static var enabled := false
static var instance: Node
static func sample(_pos: Vector3) -> Vector4: return Vector4.ZERO
static func splash(_pos: Vector3, _strength: float, _radius: float) -> void: pass
static func surface_at_xz(_pos: Vector3) -> Dictionary: return {}
static func macro_height_at(_pos: Vector3, height: float, _probe_id := 0) -> float: return height
static func macro_velocity_at(_pos: Vector3, _probe_id := 0) -> Vector3: return Vector3.ZERO
static func macro_normal_at(_pos: Vector3, normal: Vector3, _probe_id := 0) -> Vector3: return normal

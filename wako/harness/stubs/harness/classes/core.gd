class_name Core extends RefCounted
## Harness stub for RaulsMod's Core damage/world facade.
## damage() follows the receiver convention the Wako scripts document
## (target meta "damageable" names the Node receiver; the explicit impulse is applied
## once to the actual hit body; then receiver.take_damage()).
static var damaged: Array = []
static func damage(target: Object, amount: float, point: Vector3 = Vector3.INF, source: Node = null, kind: StringName = &"hit", impulse: float = 0.0, direction: Vector3 = Vector3.ZERO) -> bool:
	damaged.append([target, amount, point, source, kind, impulse, direction])
	if not is_instance_valid(target): return false
	var receiver: Object = target.get_meta(&"damageable") if target.has_meta(&"damageable") else target
	if not is_instance_valid(receiver) or not receiver.has_method(&"take_damage"): return false
	if impulse > 0.0 and target is RigidBody3D and direction != Vector3.ZERO:
		var body := target as RigidBody3D
		var offset: Vector3 = (point - body.global_position) if point.is_finite() else Vector3.ZERO
		PhysicsServer3D.body_apply_impulse(body.get_rid(), direction.normalized() * impulse, offset)
	receiver.take_damage(amount, point, source, kind)
	return true
static func world_root() -> Node: return null
static func discover(_what: StringName) -> void: pass
static func player() -> Node3D: return Global.Player if Global else null
static func camera() -> Camera3D: return Global.Camera if Global else null

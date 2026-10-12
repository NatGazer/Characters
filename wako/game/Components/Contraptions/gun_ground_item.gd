extends RigidBody3D
## Physical custody for the same Weapon while it is loose or being passed.
## Holding is a bounded assisted fixture; an interrupted pass becomes a native
## falling item at its current pose, with its measured movement retained.
var item: Node3D
var bounds := AABB()
var item_mass := 1.0
var envelope_shape: BoxShape3D

func configure(weapon: Node3D) -> bool:
	if not is_instance_valid(weapon) or not weapon.has_method("serialize_gun"): return false
	item = weapon
	item_mass = weapon.GunPhysics.mass_kg(weapon)
	mass = item_mass
	collision_layer = 1
	collision_mask = 1
	contact_monitor = true
	max_contacts_reported = 8
	set_meta(&"loose_shared_gun", true)
	bounds = weapon.GunPhysics.envelope_local(weapon)
	if not bounds.size.is_finite() or bounds.size.length() <= .001: return false
	# A full model envelope protects the barrel/grip; it does not shrink a
	# rocket launcher to a small pickup cube. Cost is one native convex box.
	var shape := BoxShape3D.new()
	shape.size = bounds.size.max(Vector3(.012,.012,.012))
	envelope_shape = shape
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.position = bounds.get_center()
	add_child(collision)
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = weapon.GunPhysics.center_local(weapon)
	inertia = weapon.GunPhysics.inertia_local(weapon)
	return true

func release_native(velocity: Vector3, spin: Vector3) -> void:
	for carrier: PhysicsBody3D in get_collision_exceptions():
		if is_instance_valid(carrier): remove_collision_exception_with(carrier)
	freeze = false
	linear_velocity = velocity if velocity.is_finite() else Vector3.ZERO
	angular_velocity = spin if spin.is_finite() else Vector3.ZERO
	sleeping = false

static func carrier_motion(carrier: RigidBody3D,weapon: Node3D,pose: Transform3D)->Array[Vector3]:
	if not is_instance_valid(carrier) or not is_instance_valid(weapon): return []
	var native:=PhysicsServer3D.body_get_direct_state(carrier.get_rid())
	if not native: return []
	var center: Vector3=pose*weapon.GunPhysics.center_local(weapon)
	var velocity: Vector3=native.get_velocity_at_local_position(center-native.transform.origin)
	var motion: Array[Vector3] = []
	if velocity.is_finite() and native.angular_velocity.is_finite():
		motion.append(velocity)
		motion.append(native.angular_velocity)
	return motion

func serialize_owned() -> Dictionary:
	if not is_instance_valid(item) or item.get_parent() != self: return {}
	var q := global_basis.orthonormalized().get_rotation_quaternion()
	return {"gun":item.serialize_gun(), "position":[global_position.x,global_position.y,global_position.z],
		"rotation":[q.x,q.y,q.z,q.w], "velocity":[linear_velocity.x,linear_velocity.y,linear_velocity.z],
		"spin":[angular_velocity.x,angular_velocity.y,angular_velocity.z]}

# Validate JSON types before invoking typed math constructors. Null/string
# elements must be refused rather than raising during a saved-state callback.
static func finite_array(value: Variant, count: int) -> bool:
	if not value is Array or value.size() != count: return false
	for component: Variant in value:
		if not (component is int or component is float) or not is_finite(float(component)): return false
	return true

static func saved_pose(row: Dictionary) -> Variant:
	var position: Variant = row.get("position", [])
	var rotation: Variant = row.get("rotation", [])
	if not finite_array(position, 3) or not finite_array(rotation, 4): return null
	var point := Vector3(position[0], position[1], position[2])
	var q := Quaternion(rotation[0], rotation[1], rotation[2], rotation[3])
	if not point.is_finite() or not q.is_finite() or q.length_squared() < .5 or q.length_squared() > 1.5: return null
	return Transform3D(Basis(q.normalized()), point)

static func saved_motion(row: Dictionary, key: String, fallback := Vector3.ZERO) -> Vector3:
	var value: Variant = row.get(key, [])
	if not finite_array(value, 3): return fallback
	var motion := Vector3(value[0], value[1], value[2])
	return motion if motion.is_finite() else fallback

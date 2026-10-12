extends RefCounted
## Shared contact/COM balance controller for the original SempreEmPe and modular
## rolling drives. Outputs finite INTERNAL torque; native friction supplies motion.

static func centre(bodies: Array) -> Vector3:
	var result := Vector3.ZERO
	var mass := 0.0
	for body: RigidBody3D in bodies:
		result += world_centre(body) * body.mass
		mass += body.mass
	return result / maxf(mass, .001)

static func world_centre(body: RigidBody3D) -> Vector3:
	var state := PhysicsServer3D.body_get_direct_state(body.get_rid())
	# The Jolt direct-state COM is a world-oriented offset from the body origin.
	return body.global_position + state.center_of_mass if state else body.to_global(body.center_of_mass)

static func command(upper: RigidBody3D, roller: RigidBody3D, com: Vector3, contact: Vector3,
		normal: Vector3, velocity: Vector3, ground_velocity: Vector3, yaw: float, mass: float,
		maximum_torque: float, maximum_power: float) -> Vector3:
	var height := maxf(.25, (com - contact).dot(normal))
	var offset := (com - contact).slide(normal)
	# Beyond a recoverable stance, let the real machine fall rather than inventing
	# an upright pose or unlimited rescue force. A grabber/repair can stand it up.
	if not recoverable(upper, com, contact, normal):
		return Vector3.ZERO
	var speed_error := (velocity - (roller.linear_velocity - ground_velocity)).slide(normal)
	var wanted_lean := (speed_error * .045).limit_length(height * .12)
	var gain := mass * 9.81 * 4.0
	var damping := mass * height * height * 1.8
	var torque := -normal.cross(offset - wanted_lean) * gain - upper.angular_velocity.slide(normal) * damping
	torque += normal * (yaw - upper.angular_velocity.dot(normal)) * mass * .22
	var relative_speed := (upper.angular_velocity - roller.angular_velocity).length()
	var limit := minf(maximum_torque, maximum_power / maxf(1.0, relative_speed))
	return torque.limit_length(maxf(0, limit))

static func recoverable(upper: RigidBody3D, com: Vector3, contact: Vector3, normal: Vector3) -> bool:
	var height := maxf(.25, (com - contact).dot(normal))
	return upper.global_basis.y.dot(normal) >= .45 and (com - contact).slide(normal).length() <= height * .65

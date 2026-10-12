extends RefCounted
## Wako adapter for the same native rig, pose writer and muscle tone used by Avatar.
## Only supported recovery targets are assisted; native bodies provide every reaction.
const Rig = preload("res://Components/Avatar/ragdoll/ragdoll_rig.gd")
const MassGeometry = preload("res://Components/Contraptions/rolling_balance.gd")
const PoseModifier = preload("res://Components/Avatar/ragdoll/ragdoll_pose.gd")
const NativePose = preload("res://LogicObjects/Wako/wako_native_pose.gd")
const BODY_DEFS := [
	["Bone", .36, 1.0, 9.8, 0, 40.0],
	["Bone.001", .065, 1.0, 3.0, 0, 75.0], ["Bone.003", .058, 1.0, 2.0, 1, 145.0],
	["Bone.005", .04, 1.0, 1.0, 0, 75.0], ["toe.L", .04, 1.0, .1, 0, 70.0],
	["Bone.002", .065, 1.0, 3.0, 0, 75.0], ["Bone.004", .058, 1.0, 2.0, 1, 145.0],
	["Bone.006", .04, 1.0, 1.0, 0, 75.0], ["toe.R", .04, 1.0, .1, 0, 70.0]]
static var CAPS := PackedFloat32Array([0, 40, 45, 18, 2, 40, 45, 18, 2])
static var STIFFNESS := PackedFloat32Array([0,2,5,35,5,2,5,35,5])

var worker: RigidBody3D
var skeleton: Skeleton3D
var model: Node3D
var rig := Rig.new()
var modifier: SkeletonModifier3D
var active := false
var pending := false
var recovering := false
var blocked := ""
var _clock := 0.0
var _supported_time := 0.0
var _upright_time := 0.0
var _cooldown := 0.0
var _saved: Dictionary = {}
var _capsule_angular_locks: Array[bool] = []
var _restore: Dictionary = {}
var _current: Array[Transform3D] = []
var _animated: Array[Transform3D] = []
var _bones: Array[Transform3D] = []
var _relative: Array[Quaternion] = []
var _weights := PackedFloat32Array()
var _impulse := Vector3.ZERO
var _point := Vector3.ZERO
var _rids: Array[RID] = []
var _pose: SkeletonModifier3D
var _recovery_age := 0.0
var assistance_force := Vector3.ZERO
var assistance_torque := Vector3.ZERO
var visual := NativePose.new()

func setup(owner: RigidBody3D, sk: Skeleton3D, skin: Node3D) -> bool:
	worker = owner
	skeleton = sk
	model = skin
	for child: Node in skeleton.get_children():
		if child.has_method(&"_solve"): _pose = child; break
	var holder := Node.new()
	holder.name = "NativeWakoBody"
	worker.add_child(holder)
	var shapes := {"Bone": {"kind": "box", "space": "model", "size": Vector3(.77, .67, .77)}}
	var regions := {"Bone": &"body"}
	var joints := {}
	for chain: Array in [["Bone.001", "Bone.003", "Bone.005", "toe.L"], ["Bone.002", "Bone.004", "Bone.006", "toe.R"]]:
		var region := &"leg_l" if chain[0] == "Bone.001" else &"leg_r"
		for bone: String in chain: regions[bone] = region
		shapes[chain[0]] = {"kind": "capsule", "radius": .065, "child": chain[1]}
		shapes[chain[1]] = {"kind": "capsule", "radius": .058, "child": chain[2]}
		# Rounded native ends follow the original leg skin, rather than leaving
		# the removed broad boot boxes as invisible collision/support surfaces.
		shapes[chain[2]] = {"kind": "sphere", "radius": .09, "offset": Vector3(0, .026, 0)}
		shapes[chain[3]] = {"kind": "sphere", "radius": .026, "offset": Vector3(0, .01, 0)}
		joints[chain[0]] = {"kind": "cone", "axis": Vector3.UP, "swing_deg": 75, "twist_deg": 45, "getup_swing_deg": 150, "getup_twist_deg": 65}
		# The canonical lower bones have a mirrored X rest axis. Their forward
		# knee flexion is positive about bone -X, matching native one-way limits.
		joints[chain[1]] = {"kind": "hinge", "axis": Vector3.LEFT, "swing_deg": 145}
		joints[chain[2]] = {"kind": "cone", "axis": Vector3.RIGHT, "swing_deg": 75, "twist_deg": 25, "getup_swing_deg": 100, "getup_twist_deg": 70}
		joints[chain[3]] = {"kind": "cone", "axis": Vector3.RIGHT, "swing_deg": 70, "twist_deg": 20}
	if not rig.build_skeleton(skeleton, model, BODY_DEFS, holder, {"shapes": shapes, "regions": regions,
		"joints": joints, "collision_layer": 1 << 8, "collision_mask": 1 | 4 | 8 | 16 | 64 | (1 << 8)}): return false
	for body in rig.bodies:
		# Core.damage's receiver convention is a Node, shared by upright and
		# fallen hits so limb impacts interrupt the same persistent helper.
		body.rb.set_meta(&"damageable", worker)
		body.rb.set_meta(&"ragdoll_of", worker)
		body.rb.contact_monitor = true
		body.rb.max_contacts_reported = 6
		body.rb.add_collision_exception_with(worker)
		_rids.append(body.rid)
	_current.resize(rig.bodies.size())
	_animated.resize(rig.bodies.size())
	_bones.resize(rig.bodies.size())
	_relative.resize(rig.bodies.size())
	_weights.resize(rig.bodies.size())
	_weights.fill(1.0)
	modifier = PoseModifier.new()
	modifier.rd = self
	modifier.active = false
	skeleton.add_child(modifier)
	return true

func is_down() -> bool:
	return active or pending

func own_rids() -> Array[RID]:
	return _rids

func knock_down(impulse: Vector3 = Vector3.ZERO, point: Vector3 = Vector3.INF) -> bool:
	if is_down() or _cooldown > 0.0: return false
	if worker.portable_gun and worker.portable_gun.handoff_active():
		worker.portable_gun.interrupt("Native fall interrupted the supported gun grip")
		if worker.portable_gun.handoff_active(): return false
	pending = true
	_capsule_angular_locks = worker.head_leap.take_recovery_angular_locks() if worker.head_leap else [worker.axis_lock_angular_x, worker.axis_lock_angular_y, worker.axis_lock_angular_z]
	_impulse = impulse
	_point = worker.global_position + Vector3.UP * .5 if point == Vector3.INF else point
	modifier.active = true
	worker.stop_navigation()
	if is_instance_valid(worker.coordinator): worker.coordinator.interrupt_worker(worker, "Knocked down; recovering footing")
	worker.action = ""
	worker._animation.speed_scale = 0.0
	return true

func apply_hit(impulse: Vector3, point: Vector3) -> void:
	if not active: return
	var closest = rig.bodies[0]
	var distance := INF
	for body in rig.bodies:
		var next: float = body.rb.global_position.distance_squared_to(point)
		if next < distance: distance = next; closest = body
	closest.rb.apply_impulse(impulse, point - closest.rb.global_position)
	damage_reaction()

func damage_reaction() -> void:
	_clock = 0.0
	recovering = false
	_supported_time = 0.0
	_upright_time = 0.0

func advance(delta: float) -> void:
	_cooldown = maxf(0.0, _cooldown - delta)
	assistance_force = Vector3.ZERO
	assistance_torque = Vector3.ZERO
	if not active: return
	_clock += delta
	for body in rig.bodies:
		_current[body.index] = PhysicsServer3D.body_get_state(body.rid, PhysicsServer3D.BODY_STATE_TRANSFORM)
	var root = rig.bodies[0]
	# The disabled capsule follows the actual native model-space torso frame.
	# A rotating head fall must not retain yesterday's inverted capsule basis
	# when the real native root has regained supported upright footing.
	var basis: Basis=(_current[0].basis*model.transform.basis.orthonormalized().inverse()).orthonormalized()
	worker.global_transform=Transform3D(basis,(_current[0]*root.b2b).origin-Vector3.UP*.224)
	worker.linear_velocity = root.rb.linear_velocity
	# Optional paired stunt observes these same native bodies and contacts.
	if worker.idle_play and worker.idle_play.upside_down and worker.idle_play.upside_down.native_tick(delta): return
	var support := _ground_support()
	_supported_time = _supported_time + delta if not support.is_empty() else 0.0
	if support.is_empty(): _upright_time = 0.0
	if _clock > .65 and not support.is_empty() and (recovering or _supported_time > .25):
		if not recovering:
			_recovery_age = 0.0
		recovering = true
		_recovery_age += delta
		rig.set_getup_ranges(true)
		_recovery_targets(support)
		rig.apply_joint_tone(_current, _relative, delta, 4.0, 3.0, STIFFNESS, CAPS)
		_supported_recovery_motor(support, delta)
		var upright: bool = _current[0].basis.y.dot(Vector3.UP) > .98
		var root_height: float = _current[0].origin.y - support.position.y
		var surface_angular: Vector3 = support.collider.angular_velocity if support.collider is RigidBody3D else Vector3.ZERO
		var safe_velocity: bool = (root.rb.linear_velocity - Vector3(support.velocity)).length() < 1.2 and (root.rb.angular_velocity - surface_angular).length() < 2.0
		_upright_time = _upright_time + delta if upright and root_height > 1.02 and safe_velocity and _capsule_fits(support) else 0.0
		if _upright_time > .4:
			_finish_recovery(support)
			return
	blocked = "Recovery needs firm ground" if support.is_empty() else "Recovering physical footing" if _clock < 8.0 else "Recovery blocked; clear room around Wako"
	worker.status_text = blocked
	worker.needs = blocked

func _ground_support() -> Dictionary:
	var surfaces := {}
	# Position, normal and velocity come from the same actual external contact.
	# Nearby rays cannot invent support, or mix a high deck with a lower floor.
	for body in rig.bodies:
		var state := PhysicsServer3D.body_get_direct_state(body.rid)
		if not state: continue
		for contact in state.get_contact_count():
			var rid := state.get_contact_collider(contact)
			var normal := state.get_contact_local_normal(contact)
			if _rids.has(rid) or normal.y < .65: continue
			if not surfaces.has(rid): surfaces[rid] = {"position": Vector3.ZERO, "normal": Vector3.ZERO, "velocity": Vector3.ZERO, "collider": state.get_contact_collider_object(contact), "rid": rid, "count": 0, "bodies": [], "points": {}}
			var hit: Dictionary = surfaces[rid]
			var position := state.get_contact_collider_position(contact)
			hit.position += position
			if not hit.points.has(body.index): hit.points[body.index] = {"sum": Vector3.ZERO, "count": 0}
			hit.points[body.index].sum += position
			hit.points[body.index].count += 1
			hit.normal += normal
			hit.velocity += state.get_contact_collider_velocity_at_position(contact)
			hit.count += 1
			if not hit.bodies.has(body.index): hit.bodies.append(body.index)
	var best := {}
	for surface: Dictionary in surfaces.values():
		if best.is_empty() or int(surface.count) > int(best.count): best = surface
	if not best.is_empty():
		best.position /= float(best.count)
		best.velocity /= float(best.count)
		best.normal = Vector3(best.normal).normalized()
	return best

func _recovery_targets(support: Dictionary) -> void:
	# Gather soles beneath the real cube, then extend/roll toward an upright
	# stance. These transforms are only muscle targets, never native body poses.
	var root = rig.bodies[0]
	var heading: float = worker._heading
	var push := smoothstep(.5, 2.0, _recovery_age)
	push *= smoothstep(.3, .85, _current[0].basis.y.dot(Vector3.UP))
	var yaw := Basis(Vector3.UP, heading)
	var target_root := Transform3D(yaw, Vector3(_current[0].origin.x, support.position.y + lerpf(.69,1.074,push), _current[0].origin.z))
	var root_bone: Transform3D = target_root * root.b2b
	skeleton.reset_bone_poses()
	skeleton.set_bone_global_pose(root.bone, skeleton.global_transform.affine_inverse() * root_bone)
	for side in 2:
		var names: Array = ["Bone.001", "Bone.003", "Bone.005"] if side == 0 else ["Bone.002", "Bone.004", "Bone.006"]
		var foot = rig.by_name[names[2]]
		var hip_rest: Transform3D = root.b2b * skeleton.get_bone_global_rest(root.bone).affine_inverse() * skeleton.get_bone_global_rest(skeleton.find_bone(names[0]))
		var lateral: Vector3 = (target_root.basis * hip_rest.origin).slide(Vector3.UP)
		var point := Vector3(_current[0].origin.x, support.position.y, _current[0].origin.z) + lateral + lateral.normalized() * .03 + yaw.z * .08
		var query := PhysicsRayQueryParameters3D.create(point + Vector3.UP * 1.5, point - Vector3.UP * .5)
		query.exclude = _rids.duplicate()
		query.exclude.append(worker.get_rid())
		query.collision_mask = 1 | 4
		var hit := worker.get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty() or hit.rid != support.rid or hit.normal.y < .65: continue
		var rest: Transform3D = root.b2b * skeleton.get_bone_global_rest(root.bone).affine_inverse() * skeleton.get_bone_global_rest(foot.bone)
		var basis := skeleton.global_basis.inverse() * yaw * rest.basis
		var ankle: Vector3 = skeleton.global_transform.affine_inverse() * (hit.position + Vector3.UP * .116)
		_pose._solve(skeleton, skeleton.find_bone(names[0]), skeleton.find_bone(names[1]), foot.bone, ankle, 1.0, basis)
	for body in rig.bodies:
		_animated[body.index] = skeleton.global_transform * skeleton.get_bone_global_pose(body.bone) * body.b2b_inv
		if body.parent >= 0:
			_relative[body.index] = _animated[body.parent].basis.get_rotation_quaternion().inverse() * _animated[body.index].basis.get_rotation_quaternion()

func _supported_recovery_motor(support: Dictionary, delta: float) -> void:
	# Spring-foot lift requires an actual sole/toe within its real leg's reach.
	# Before a sole can plant, actual torso contact permits bounded rolling
	# torque, with its opposite reaction on that same native support. Neither
	# nearby rays nor unsupported limbs can supply lift or rolling assistance.
	var soles: Array = []
	for index: int in support.get("bodies", []):
		if index not in [3,4,7,8]: continue
		var side := 0 if index in [3,4] else 1
		var hip = rig.bodies[1 if side == 0 else 5]
		var contact: Dictionary = support.points[index]
		var point: Vector3 = contact.sum / float(contact.count)
		var hip_point: Vector3 = _current[hip.index] * hip.anchor_self
		if hip_point.distance_to(point) <= worker._leg_lengths[side] + .15: soles.append(index)
	if soles.is_empty() and not support.get("bodies", []).has(0): return
	var root = rig.bodies[0]
	var support_body := support.collider as RigidBody3D
	if not soles.is_empty():
		var com: Vector3 = MassGeometry.world_centre(root.rb)
		var ground_velocity: Vector3 = support.velocity
		if support_body: ground_velocity = support_body.linear_velocity + support_body.angular_velocity.cross(com - MassGeometry.world_centre(support_body))
		var relative: Vector3 = root.rb.linear_velocity - ground_velocity
		var height_error: float = support.position.y + 1.074 - _current[0].origin.y
		var lift: float = worker.spring_support_force(rig.total_mass, height_error, relative.y, 1.2, 1.05, 320.0)
		var force := Vector3.UP * lift
		# Native support velocity is followed with bounded traction assistance.
		force += (-relative.slide(Vector3.UP) * rig.total_mass * 3.0).limit_length(50.0)
		force = force.limit_length(320.0)
		assistance_force = force
		root.rb.apply_central_force(force)
		if support_body: support_body.apply_force(-force, com - support_body.global_position)
	var goal := Basis(Vector3.UP, worker._heading).get_rotation_quaternion()
	var error := Rig.rotation_vector(goal * _current[0].basis.get_rotation_quaternion().inverse())
	var support_angular := support_body.angular_velocity if support_body else Vector3.ZERO
	var torque: Vector3 = (error * 100.0 - (root.rb.angular_velocity - support_angular) * 16.0).limit_length(80.0)
	assistance_torque = torque
	root.rb.apply_torque_impulse(torque * delta)
	if support_body: support_body.apply_torque_impulse(-torque * delta)

func _capsule_fits(support: Dictionary) -> bool:
	var shape := worker.get_node("Collision") as CollisionShape3D
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape.shape
	var position := worker.global_position
	query.transform = Transform3D(worker.global_basis, position) * shape.transform
	query.exclude = _rids.duplicate()
	query.exclude.append(worker.get_rid())
	query.collision_mask = int(_saved.get("mask", 5)) | (1 << 8)
	return worker.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()

func remember_pose() -> void:
	if not is_down(): visual.remember(worker,skeleton)

func modify(delta: float) -> void:
	if pending:
		if _restore.is_empty(): _enable()
		else: _enable_restored()
	if not active:
		if visual.is_returning(): visual.continue_return(worker,skeleton,rig.bodies,delta)
		modifier.active=visual.is_returning()
		return
	for body in rig.bodies: _bones[body.index] = _current[body.index] * body.b2b
	visual.write(skeleton,rig.bodies,_bones,_weights)
	worker._update_head()
	worker._update_work_tool(true)

func sync_payload() -> void:
	# Scene teardown cancels jobs after their frozen followers can already have
	# left the tree. Spatial offsets are only meaningful for live physics bodies.
	if not is_instance_valid(worker) or not worker.is_inside_tree() or rig.bodies.is_empty(): return
	# Frozen head cargo/tool followers contribute exactly once to the active
	# native root. Their real offsets shift COM and native rotational inertia.
	var root = rig.bodies[0]
	if not is_instance_valid(root.rb) or not root.rb.is_inside_tree() or not skeleton.is_inside_tree(): return
	var root_world: Transform3D = _current[0] if active or not _restore.is_empty() else _animated[0] if pending else rig.capture_pose(skeleton)[0]
	var inverse := root_world.affine_inverse()
	var loads: Array = []
	if worker.back_tool:
		var load: Dictionary = worker.back_tool.holder_load(root_world*root.b2b)
		if not load.is_empty():
			var rotation: Basis = root_world.basis.inverse()*Basis(load.frame.basis)
			var tensor: Basis = rotation*Basis(load.local_inertia)*rotation.transposed()
			loads.append({"mass":load.mass,"offset":inverse*Vector3(load.world_point),"intrinsic":Vector3(tensor.x.x,tensor.y.y,tensor.z.z)})
	if worker.cargo_mass > 0.0:
		var source: Node3D=worker._cargo_source if is_instance_valid(worker._cargo_source) and worker._cargo_source.is_inside_tree() else null
		if source==null:
			for part: Node in worker.get_tree().get_nodes_in_group(&"contraption_parts"):
				if part.get("carrier") == worker.head_anchor or (worker.pickup and part.get("carrier") == worker.pickup.foot_anchor): source = part; break
		var offset: Vector3 = root.b2b * Vector3(0, worker.HEAD_OFFSET + .2, 0)
		var size := Vector3.ZERO
		if source and source.is_inside_tree():
			# Preserve the actual at-pose cargo basis and measured material COM.
			offset = inverse*MassGeometry.world_centre(source)
			size = source.definition.size
		loads.append({"mass": worker.cargo_mass, "offset": offset, "size": size})
	if is_instance_valid(worker.equipped_tool) and worker.equipped_tool.is_inside_tree() and (not worker.back_tool or worker.back_tool.onboard_mass()>0.0):
		loads.append({"mass": worker.equipped_tool.mass, "offset": inverse * worker.equipped_tool.global_position, "size": worker.equipped_tool.definition.size})
	var mass := 9.8
	var centre := Vector3.ZERO
	for load: Dictionary in loads:
		mass += float(load.mass)
		centre += Vector3(load.offset) * float(load.mass)
	centre /= mass
	var size: Vector3 = root.shape.size
	var inertia := 9.8 / 12.0 * Vector3(size.y*size.y+size.z*size.z,size.x*size.x+size.z*size.z,size.x*size.x+size.y*size.y)
	inertia += 9.8 * Vector3(centre.y*centre.y+centre.z*centre.z,centre.x*centre.x+centre.z*centre.z,centre.x*centre.x+centre.y*centre.y)
	for load: Dictionary in loads:
		var arm: Vector3 = Vector3(load.offset) - centre
		var own: Vector3
		if load.has("intrinsic"):
			own = load.intrinsic
		else:
			var half: Vector3 = load.size
			own = float(load.mass)*Vector3(half.y*half.y+half.z*half.z,half.x*half.x+half.z*half.z,half.x*half.x+half.y*half.y)/12.0
		inertia += float(load.mass)*Vector3(arm.y*arm.y+arm.z*arm.z,arm.x*arm.x+arm.z*arm.z,arm.x*arm.x+arm.y*arm.y)+own
	root.mass = mass
	root.rb.mass = mass
	root.rb.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	root.rb.center_of_mass = centre
	root.rb.inertia = inertia
	root.inertia = (inertia.x + inertia.z) * .5
	rig.total_mass = mass + 12.2

func _take_capsule() -> void:
	if _capsule_angular_locks.is_empty():
		_capsule_angular_locks = [worker.axis_lock_angular_x, worker.axis_lock_angular_y, worker.axis_lock_angular_z]
	_saved = {"layer": worker.collision_layer, "mask": worker.collision_mask, "freeze": worker.freeze, "freeze_mode": worker.freeze_mode, "angular_locks": _capsule_angular_locks.duplicate()}
	worker.collision_layer = 0
	worker.collision_mask = 0
	worker.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	worker.freeze = true
	worker.on_ground = false
	worker.foot_grip_valid = false
	worker.stance_valid = false

func _enable() -> void:
	# Ordinary cancellation seeks an interruption clip. Capture the actual
	# previously visible rig after that seek, rebased by current native motion.
	visual.restore_actual(worker,skeleton)
	rig.capture_pose(skeleton, _animated)
	sync_payload()
	# Read the actual rotating capsule before freezing it. Native limb/root
	# COM motion inherits its own point velocity and spin, including head flight.
	var native:=PhysicsServer3D.body_get_direct_state(worker.get_rid())
	var velocity: Vector3=native.linear_velocity if native else worker.linear_velocity
	var spin: Vector3=native.angular_velocity if native else worker.angular_velocity
	var com: Vector3=native.transform*native.center_of_mass_local if native else worker.global_transform*worker.center_of_mass
	_take_capsule()
	var linear: Array[Vector3] = []
	var angular: Array[Vector3] = []
	for body in rig.bodies:
		var centre: Vector3=_animated[body.index]*body.rb.center_of_mass
		linear.append(velocity+spin.cross(centre-com))
		angular.append(spin)
		rig.set_colliding(body, true)
		body.rb.continuous_cd = true
		_current[body.index] = _animated[body.index]
	rig.enable(_animated, linear, angular)
	if _impulse.length_squared() > 0.0: rig.bodies[0].rb.apply_impulse(_impulse, _point - rig.bodies[0].rb.global_position)
	pending = false
	active = true
	_clock = 0.0
	_supported_time = 0.0
	_upright_time = 0.0

func _finish_recovery(support: Dictionary) -> void:
	visual.begin_return(worker,rig.bodies,_current)
	var velocity := Vector3.ZERO
	for body in rig.bodies: velocity += body.rb.linear_velocity * body.mass / rig.total_mass
	rig.disable()
	active = false
	recovering = false
	modifier.active = true # Retain the last visible native TRS through idle's .25s blend.
	worker.collision_layer = int(_saved.layer)
	worker.collision_mask = int(_saved.mask)
	worker.freeze = bool(_saved.freeze)
	worker.freeze_mode = int(_saved.freeze_mode)
	worker.linear_velocity = velocity
	worker.angular_velocity = rig.bodies[0].rb.angular_velocity
	# Reapply the original capsule policy only after native supported recovery.
	var angular_locks: Array = _saved.get("angular_locks", _capsule_angular_locks)
	worker.axis_lock_angular_x = angular_locks[0]
	worker.axis_lock_angular_y = angular_locks[1]
	worker.axis_lock_angular_z = angular_locks[2]
	_capsule_angular_locks.clear()
	worker._animation.speed_scale = 1.0
	worker._animation.play("wk_idle", .25)
	worker.fear_time = maxf(worker.fear_time, 1.0)
	worker.needs = ""
	worker.status_text = "Regained footing"
	_cooldown = 1.5

func serialize_state() -> Dictionary:
	if pending and _restore.is_empty():
		return {"pending": true, "impulse": [_impulse.x,_impulse.y,_impulse.z], "point": [_point.x,_point.y,_point.z], "angular_locks": _capsule_angular_locks.duplicate()}
	if pending and not _restore.is_empty(): return _restore.duplicate(true)
	if not active: return {}
	var bodies: Array = []
	for body in rig.bodies:
		var t: Transform3D = PhysicsServer3D.body_get_state(body.rid, PhysicsServer3D.BODY_STATE_TRANSFORM)
		bodies.append({"pose": [t.basis.x.x,t.basis.x.y,t.basis.x.z,t.basis.y.x,t.basis.y.y,t.basis.y.z,t.basis.z.x,t.basis.z.y,t.basis.z.z,t.origin.x,t.origin.y,t.origin.z],
			"linear": [body.rb.linear_velocity.x,body.rb.linear_velocity.y,body.rb.linear_velocity.z], "angular": [body.rb.angular_velocity.x,body.rb.angular_velocity.y,body.rb.angular_velocity.z]})
	return {"bodies": bodies, "clock": _clock, "saved": _saved}

static func _finite_array(values: Variant, count: int) -> bool:
	if not values is Array or values.size() != count: return false
	for value: Variant in values:
		if not (value is float or value is int) or not is_finite(float(value)): return false
	return true

static func _valid_angular_locks(values: Variant) -> bool:
	return values is Array and values.size() == 3 and values.all(func(value: Variant) -> bool: return value is bool)

func restore_state(data: Dictionary) -> void:
	if data.has("origin_motion") and not data.origin_motion is bool: return
	if data.get("pending", false):
		if data.has("angular_locks") and not _valid_angular_locks(data.angular_locks): return
		if _finite_array(data.get("impulse"),3) and _finite_array(data.get("point"),3):
			var v: Array = data.impulse
			var p: Array = data.point
			if knock_down(Vector3(v[0],v[1],v[2]),Vector3(p[0],p[1],p[2])) and data.has("angular_locks"):
				_capsule_angular_locks.assign(data.angular_locks)
		return
	var entries: Variant = data.get("bodies", [])
	if not entries is Array or entries.size() != rig.bodies.size(): return
	for entry: Variant in entries:
		if not entry is Dictionary or not _finite_array(entry.get("pose"),12) or not _finite_array(entry.get("linear"),3) or not _finite_array(entry.get("angular"),3): return
		var p: Array = entry.pose
		var basis := Basis(Vector3(p[0],p[1],p[2]),Vector3(p[3],p[4],p[5]),Vector3(p[6],p[7],p[8]))
		if absf(basis.determinant() - 1.0) > .02 or absf(basis.x.length_squared()-1.0) > .02 or absf(basis.y.length_squared()-1.0) > .02 or absf(basis.z.length_squared()-1.0) > .02 or absf(basis.x.dot(basis.y)) > .02 or absf(basis.x.dot(basis.z)) > .02 or absf(basis.y.dot(basis.z)) > .02: return
	var saved: Variant = data.get("saved", {})
	if not saved is Dictionary or not saved.has_all(["layer","mask","freeze","freeze_mode"]): return
	if saved.has("angular_locks") and not _valid_angular_locks(saved.angular_locks): return
	for key: String in ["layer","mask","freeze_mode"]:
		if not (saved[key] is int or saved[key] is float) or not is_finite(float(saved[key])): return
	if int(saved.layer) < 0 or int(saved.layer) > 0x7fffffff or int(saved.mask) < 0 or int(saved.mask) > 0x7fffffff or int(saved.freeze_mode) not in [0,1] or not saved.freeze is bool: return
	if not (data.get("clock") is float or data.get("clock") is int) or not is_finite(float(data.clock)): return
	_restore = data.duplicate(true)
	# Back binding and payload COM run before the first modifier callback.
	# Make the already validated native frames available during that interval.
	for body in rig.bodies:
		var p: Array=entries[body.index].pose
		_current[body.index]=Transform3D(Basis(Vector3(p[0],p[1],p[2]),Vector3(p[3],p[4],p[5]),Vector3(p[6],p[7],p[8])),Vector3(p[9],p[10],p[11]))
	pending = true
	modifier.active = true
	worker._animation.speed_scale = 0.0

func _enable_restored() -> void:
	var linear: Array[Vector3] = []
	var angular: Array[Vector3] = []
	for body in rig.bodies:
		var d: Dictionary = _restore.bodies[body.index]
		var p: Array = d.pose
		_current[body.index] = Transform3D(Basis(Vector3(p[0],p[1],p[2]),Vector3(p[3],p[4],p[5]),Vector3(p[6],p[7],p[8])),Vector3(p[9],p[10],p[11]))
		linear.append(Vector3(d.linear[0],d.linear[1],d.linear[2]))
		angular.append(Vector3(d.angular[0],d.angular[1],d.angular[2]))
		rig.set_colliding(body, true)
	sync_payload()
	_take_capsule()
	_saved = _restore.saved
	# An interrupted head jump records native point motion at each body origin.
	# Fold the currently attached tool/holder once, then convert to its real COM.
	if _restore.get("origin_motion",false):
		for body in rig.bodies: linear[body.index]+=angular[body.index].cross(_current[body.index].basis*body.rb.center_of_mass)
	rig.enable(_current, linear, angular)
	_clock = clampf(float(_restore.clock), 0.0, 600.0)
	_restore.clear()
	pending = false
	active = true

func dispose() -> void:
	for body in rig.bodies:
		if is_instance_valid(body.rb): body.rb.remove_meta(&"damageable")
	rig.free_all()

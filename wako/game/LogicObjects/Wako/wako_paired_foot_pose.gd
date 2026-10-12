extends SkeletonModifier3D
## One optional foot tap after the unchanged terrain modifier. Original finite
## leg geometry supplies every endpoint; the original capsule supplies the hop.
const FOOT_RADIUS := .09
var director: RefCounted
var capture_ready := false
var _bones: Array[Transform3D] = []
var _body := Transform3D.IDENTITY
var _last_soles: Array[Vector3] = [Vector3.ZERO,Vector3.ZERO]
var _last_ankles: Array[Basis] = [Basis.IDENTITY,Basis.IDENTITY]
var _have_last := false
var _launch_crouch := 0.0
var _was_supported := true
var _root_returning := false
var root_reentry: Dictionary = {}
var _shape_owner := -1
var native_contact_baseline: Dictionary = {}
var _foot_query := PhysicsShapeQueryParameters3D.new()
# Immutable preparation root: the previous published root already contains
# the accent, so using it as the authored baseline would accumulate a lean.
var _launch_root := Transform3D.IDENTITY
var _launch_worker := Transform3D.IDENTITY
var _captured_crouch := 0.0
var _flight_soles: Array[Vector3] = [Vector3.ZERO,Vector3.ZERO]
var _flight_ankles: Array[Basis] = [Basis.IDENTITY,Basis.IDENTITY]
var _return_clock := -1.0
var _return_body := Transform3D.IDENTITY
var _return_sole := Vector3.ZERO
var _return_ankle := Basis.IDENTITY
var _contact_clock := -1.0
var _contact_from := Vector3.ZERO
var _greeting_turn := Vector3.ZERO
var _endings: Array = []
var native_geometry_ready := false
var evaluated_end_centres: Array[Vector3] = [Vector3.ZERO,Vector3.ZERO]

# The original supported crouch prepares the launch. Rise into a clear
# waiting pose, then recoil only after the unchanged native foot-tap proof.
# The cube follows the sole by 35 ms and settles through the finite return.
const GREETING_TURNS := [
	[0.0,Vector3.ZERO],
	[.08,Vector3(-.09,.0,.045)],
	[.18,Vector3(-.13,.045,.12)],
	[.50,Vector3(-.13,.045,.12)],
]
const CONTACT_TURNS := [
	[0.0,Vector3.ZERO],
	[.07,Vector3(.11,-.03,-.11)],
	[.13,Vector3(.070,.0,-.065)],
	[.22,Vector3(.025,.005,-.018)],
	[.35,Vector3.ZERO],
]

static func greeting_turn(time: float) -> Vector3:
	return _sample_turn(GREETING_TURNS,time)

static func _sample_turn(keys: Array, time: float, first := Vector3.INF) -> Vector3:
	var clock: float = clampf(time,0.0,float(keys[-1][0]))
	for key: int in range(1,keys.size()):
		var end: Array = keys[key]
		if clock>float(end[0]): continue
		var begin: Array = keys[key-1]
		var from: Vector3 = first if key==1 and first.is_finite() else Vector3(begin[1])
		var t: float = (clock-float(begin[0]))/(float(end[0])-float(begin[0]))
		var spacing: float = t*t*t*(t*(t*6.0-15.0)+10.0)
		if first.is_finite() and key==1:
			spacing = t*t*t*(56.0+t*(-210.0+t*(336.0+t*(-280.0+t*(120.0-21.0*t)))))
		return from.lerp(Vector3(end[1]),spacing)
	return Vector3(keys[-1][1])

func _contact_follow_turn(delta: float) -> Vector3:
	if director._pair.is_empty(): return Vector3.ZERO
	var mirrored: bool = director._pair.a.get_ref()!=director.worker
	if bool(director._pair.get("contact",false)):
		if _contact_clock<0.0:
			_contact_clock = 0.0
			_contact_from = _greeting_turn
			if mirrored: _contact_from.z = -_contact_from.z
		_contact_clock += delta
		var contact_turn: Vector3 = _sample_turn(CONTACT_TURNS,maxf(_contact_clock-.035,0.0),_contact_from)
		if mirrored: contact_turn.z = -contact_turn.z
		return contact_turn
	if director._pair_returning: return Vector3.ZERO
	var launch_turn: Vector3 = greeting_turn(float(director._pair.get("stage_age",.50))-.035)
	if mirrored: launch_turn.z = -launch_turn.z
	return launch_turn

func _ready() -> void:
	var sk := get_skeleton()
	if not director or not sk or not is_instance_valid(director.worker) or not director.worker.ragdoll: return
	# SphereShape3D stores float32; compare the exact original native value,
	# rather than its float64 GDScript authoring literal. No radius tolerance.
	var native_radius: float = PackedFloat32Array([FOOT_RADIUS])[0]
	for side in 2:
		var ending = director.worker.ragdoll.rig.by_name.get(StringName(sk.get_bone_name(director.worker._pose._chains[side][2])))
		if not ending or not ending.shape is SphereShape3D or ending.shape.radius!=native_radius: return
		_endings.append(ending)
	native_geometry_ready = true

func _exit_tree() -> void:
	remove_native_contact()
	native_geometry_ready = false
	if director and is_instance_valid(director.worker):
		director._pair_foot_active = false
		if not director._pair.is_empty(): director.cancel("Paired foot modifier left the original body")

func capture() -> void:
	capture_ready = false
	_have_last = false
	_root_returning = false
	root_reentry.clear()
	_greeting_turn = Vector3.ZERO
	_return_clock = -1.0
	_contact_clock = -1.0
	_contact_from = Vector3.ZERO

func _process_modification_with_delta(delta: float) -> void:
	if not director or not is_instance_valid(director.worker): return
	var worker: RigidBody3D = director.worker
	var pose: SkeletonModifier3D = worker._pose
	var sk := get_skeleton()
	if not sk or not worker.is_available() or (worker.ragdoll and worker.ragdoll.pending):
		director._pair_foot_active = false
		remove_native_contact()
		return
	if not director._pair_foot_active:
		if director.state=="pair_gather" and pose.evaluated_valid:
			_bones.resize(sk.get_bone_count())
			for bone in _bones.size(): _bones[bone] = sk.global_transform*sk.get_bone_global_pose(bone)
			_body = worker.global_transform
			_last_soles = pose.evaluated_soles.duplicate()
			_last_ankles = pose.evaluated_ankles.duplicate()
			_have_last = true
			_launch_crouch = float(director._modifier._crouch)
			_captured_crouch = _launch_crouch
			_launch_root = _bones[0]
			_launch_worker = _body
			_flight_soles = _last_soles.duplicate()
			_flight_ankles = _last_ankles.duplicate()
			_was_supported = worker.on_ground
			capture_ready = true
		return
	if not _have_last or not capture_ready: director.cancel("Paired launch lost its evaluated original legs"); return
	var side: int = director._pair_side
	var chain: Array = pose._chains[side]
	_foot_query.shape = _endings[side].shape
	var inverse := sk.global_transform.affine_inverse()
	# In air the terrain modifier deliberately declines support. Continue its
	# last actual bones through current native-body motion before the same IK.
	if not worker.on_ground:
		var carry := worker.global_transform*_body.affine_inverse()
		for bone in _bones.size(): sk.set_bone_global_pose(bone,inverse*(carry*_bones[bone]))
		# Preserve the original idle modifier's continuous squat release while
		# the captured limbs travel with the native capsule through the hop.
		var root: Transform3D = worker.global_transform*_launch_worker.affine_inverse()*_launch_root
		root.origin += worker._skeleton.global_basis.y*(.046*(_captured_crouch-float(director._modifier._crouch)))
		sk.set_bone_global_pose(0,inverse*root)
	# A capsule support ray can reenter before the airborne cube has reached
	# the ordinary grounded clip's root. Continue that evaluated visual root
	# into the restored clip before solving either foot; the native body,
	# support observations and foot meeting geometry remain unchanged.
	var ordinary_root := sk.get_bone_global_pose(0)
	var root_world := sk.global_transform*ordinary_root
	var authored_turn: Vector3 = _contact_follow_turn(delta)
	_greeting_turn = _greeting_turn.move_toward(authored_turn,delta*4.0)
	root_world.basis = sk.global_basis*Basis.from_euler(_greeting_turn)*ordinary_root.basis
	# Complete seated tools keep their original clear-frame and finite rates.
	var back_stowed: bool = is_instance_valid(worker.equipped_tool) and worker.back_tool and worker.back_tool.phase=="back" and worker.equipped_tool.carrier==worker.back_tool.back_anchor and not worker.tool_foot_occupied()
	var before_root: Quaternion = _bones[0].basis.orthonormalized().get_rotation_quaternion().normalized()
	var after_root: Quaternion = root_world.basis.orthonormalized().get_rotation_quaternion().normalized()
	var root_angle: float = before_root.angle_to(after_root)
	root_world.basis = Basis(before_root.slerp(after_root,minf(1.0,delta*4.0/maxf(root_angle,.0001)))).scaled_local(root_world.basis.get_scale())
	if worker.on_ground and not _was_supported:
		_root_returning = true
		root_reentry = {"frame":Engine.get_physics_frames(),"returning":director._pair_returning,"previous":_bones[0].origin,"wanted":root_world.origin,"gap":_bones[0].origin.distance_to(root_world.origin)}
	var recovering_root: bool = _root_returning
	var landing_goal: Vector3 = root_world.origin
	if _root_returning:
		var target_root := root_world.origin
		root_world.origin = _bones[0].origin.move_toward(target_root,minf(.045,delta*4.5))
		ordinary_root.origin = inverse*root_world.origin
		sk.set_bone_global_pose(0,ordinary_root)
		_root_returning = root_world.origin.distance_to(target_root)>.003
	# Check the actual final bounded frame, including ground reentry, rather
	# than checking one frame then publishing an unproved partial rotation.
	if back_stowed:
		root_world = sk.global_transform*_clear_greeting_root(sk,inverse*root_world,delta)
	if recovering_root: _root_returning = root_world.origin.distance_to(landing_goal)>.003
	ordinary_root = inverse*root_world
	sk.set_bone_global_pose(0,ordinary_root)
	var ordinary_foot := sk.get_bone_global_pose(chain[2])
	var ordinary_sole: Vector3 = sk.global_transform*(ordinary_foot*Vector3(0,pose._ankle_height[side],0))
	var ordinary_basis: Basis = sk.global_basis*ordinary_foot.basis
	var before := _last_ankles[side].get_rotation_quaternion().normalized()
	var wanted: Basis = ordinary_basis if director._pair_returning else Basis(Quaternion(director._pair_start_basis.y.normalized(),director._pair_normal))*director._pair_start_basis
	var desired: Vector3 = ordinary_sole if director._pair_returning else director._pair_point
	if director._pair_returning and not worker.on_ground:
		# The carried prior solve contains the tapping pose. Return toward the
		# immutable launch footprint in current native-body space instead of
		# carrying that raised sole unchanged all the way into ground reentry.
		# This changes only authored spacing; the actual reach, route, rate,
		# rounded-ending clearance and truthful airborne support stay below.
		if _return_clock<0.0:
			_return_clock = 0.0
			_return_body = worker.global_transform
			var carry: Transform3D = worker.global_transform*_body.affine_inverse()
			_return_sole = carry*_last_soles[side]
			_return_ankle = carry.basis*_last_ankles[side]
		_return_clock += delta
		var time: float = clampf(_return_clock/.20,0.0,1.0)
		var spacing: float = time*time*time*(time*(time*6.0-15.0)+10.0)
		var flight: Transform3D = worker.global_transform*_launch_worker.affine_inverse()
		var returning: Transform3D = worker.global_transform*_return_body.affine_inverse()
		desired = (returning*_return_sole).lerp(flight*_flight_soles[side],spacing)
		var release: Quaternion = (returning.basis*_return_ankle).get_rotation_quaternion().normalized()
		var landing: Quaternion = (flight.basis*_flight_ankles[side]).get_rotation_quaternion().normalized()
		wanted = Basis(release.slerp(landing,spacing))
	var after := wanted.get_rotation_quaternion().normalized()
	var difference := before.inverse()*after
	var angle := 2.0*atan2(Vector3(difference.x,difference.y,difference.z).length(),absf(difference.w))
	var world_basis := Basis(before.slerp(after,minf(delta*8.0/maxf(angle,.00001),1.0)).normalized())
	var basis := sk.global_basis.inverse()*world_basis
	if not director._pair_returning:
		# Authored target spacing eases into the meeting. Existing Cartesian,
		# reach and ankle guards still constrain the actual finite ending.
		var flight: float = clampf(float(director._pair.get("stage_age",0.0))/.16,0.0,1.0)
		var spacing: float = flight*flight*flight*(flight*(flight*6.0-15.0)+10.0)
		desired = _flight_soles[side].lerp(director._pair_point,spacing)
	# This solver limits the ACTUAL reachable result, not merely a requested
	# target that could gain another displacement when the native hip moves.
	var previous := _last_soles[side]
	var sole: Vector3 = pose._bounded_head_sole(sk,side,previous,desired,basis,minf(.045,delta*4.5))
	var floor_hit: Dictionary = pose._walk_ground(sole)
	if not _clear(worker,sole,world_basis,floor_hit):
		if not director._pair_returning: director.cancel("Paired foot route became blocked")
		world_basis = Basis(before)
		basis = sk.global_basis.inverse()*world_basis
		sole = pose._bounded_head_sole(sk,side,previous,previous,basis,minf(.045,delta*4.5))
	var terrain_pole: bool = pose._walking_ik
	# The same ordinary model-facing pole remains the intended knee plane in
	# this upright hop; terrain's airborne early exit supplies no new pole.
	pose._walking_ik = true
	pose._solve(sk,chain[0],chain[1],chain[2],inverse*sole-basis*Vector3(0,pose._ankle_height[side],0),1.0,basis)
	pose._walking_ik = terrain_pole
	var actual: Vector3 = sk.global_transform*(sk.get_bone_global_pose(chain[2])*Vector3(0,pose._ankle_height[side],0))
	# Terrain admission is a ray reach test on the capsule. On reentry its
	# opposite foot still has to return from its last actual airborne endpoint,
	# rather than instantly adopting the newly restored grounded idle clip.
	var other := 1-side
	var other_chain: Array = pose._chains[other]
	var other_foot := sk.get_bone_global_pose(other_chain[2])
	var other_goal: Vector3 = sk.global_transform*(other_foot*Vector3(0,pose._ankle_height[other],0))
	var other_after := (sk.global_basis*other_foot.basis).get_rotation_quaternion().normalized()
	var other_before := _last_ankles[other].get_rotation_quaternion().normalized()
	var other_turn := other_before.angle_to(other_after)
	var other_world := Basis(other_before.slerp(other_after,minf(delta*8.0/maxf(other_turn,.00001),1.0)).normalized())
	var other_basis := sk.global_basis.inverse()*other_world
	var other_sole: Vector3 = pose._bounded_head_sole(sk,other,_last_soles[other],other_goal,other_basis,minf(.045,delta*4.5))
	pose._walking_ik = true
	pose._solve(sk,other_chain[0],other_chain[1],other_chain[2],inverse*other_sole-other_basis*Vector3(0,pose._ankle_height[other],0),1.0,other_basis)
	pose._walking_ik = terrain_pole
	var other_actual: Vector3 = sk.global_transform*(sk.get_bone_global_pose(other_chain[2])*Vector3(0,pose._ankle_height[other],0))
	var other_floor: Dictionary = pose._walk_ground(other_actual) if worker.on_ground else {}
	pose.evaluated_grounded[other] = pose.evaluated_grounded[other] and not other_floor.is_empty() and other_actual.distance_to(other_goal)<.025 and absf(Vector3(other_floor.normal).dot(other_actual-Vector3(other_floor.position)))<.025
	# An elevated sole is never funding ground support. Ordinary terrain IK
	# reobserves its own plant on the next evaluation after the actual return.
	pose._target_valid[side] = false
	pose.evaluated_grounded[side] = false
	if not worker.on_ground: pose.evaluated_grounded = [false,false]
	for leg in 2:
		var bones: Array = pose._chains[leg]
		var foot := sk.get_bone_global_pose(bones[2])
		pose.evaluated_hips[leg] = sk.global_transform*sk.get_bone_global_pose(bones[0]).origin
		pose.evaluated_knees[leg] = sk.global_transform*sk.get_bone_global_pose(bones[1]).origin
		pose.evaluated_ankles[leg] = sk.global_basis*foot.basis
		pose.evaluated_soles[leg] = sk.global_transform*(foot*Vector3(0,pose._ankle_height[leg],0))
		evaluated_end_centres[leg] = (sk.global_transform*foot*_endings[leg].b2b_inv).origin
	pose.evaluated_root = sk.global_transform*sk.get_bone_global_pose(0)
	pose.evaluated_worker = worker.global_transform
	pose.evaluated_basis = sk.global_basis
	pose.evaluated_visual_com = pose._posed_center_of_mass(sk)
	pose.evaluated_valid = true
	pose.evaluation_serial += 1
	_last_soles = pose.evaluated_soles.duplicate()
	_last_ankles = pose.evaluated_ankles.duplicate()
	# Carry this newly evaluated rig on the next native tick. Keeping the old
	# launch snapshot would pop the other foot upward when capsule ray support
	# finally leaves reach, even though that foot had kept reaching its floor.
	_bones.resize(sk.get_bone_count())
	for bone in _bones.size(): _bones[bone] = sk.global_transform*sk.get_bone_global_pose(bone)
	_body = worker.global_transform
	_launch_crouch = float(director._modifier._crouch)
	_was_supported = worker.on_ground
	worker._update_head(pose.evaluated_root)
	if worker.ragdoll: worker.ragdoll.remember_pose()
	if not director._pair_returning and not worker.on_ground:
		var peer: RigidBody3D = director._pair_peer()
		# The original native rig keeps imported/rest scale in b2b. Reuse its
		# exact evaluated ending transform and metre-sized sphere resource.
		var centre: Vector3 = evaluated_end_centres[side]
		# Native submission uses the evaluated result, not the earlier request.
		# Losing either participant or encountering a new obstacle cancels both
		# contact shapes immediately; the same finite leg return keeps running.
		if not is_instance_valid(peer) or not peer.idle_play or peer.idle_play._pair.is_empty():
			director.cancel("Paired contact lost its actual neighbour")
		elif not _clear(worker,actual,pose.evaluated_ankles[side],pose._walk_ground(actual),centre):
			director.cancel("Actual paired rounded ending became blocked")
		elif not _add_native_contact(worker,centre):
			director.cancel("Original native inertia cannot be preserved for the foot tap")
		if _shape_owner>=0:
			worker.shape_owner_set_transform(_shape_owner,worker.global_transform.affine_inverse()*Transform3D(Basis.IDENTITY,centre))
	else: remove_native_contact()
	if director._pair_returning and not _root_returning and worker.on_ground and pose.evaluated_grounded[other] and actual.distance_to(ordinary_sole)<.003 and angle<.008 and not floor_hit.is_empty() and absf(Vector3(floor_hit.normal).dot(actual-Vector3(floor_hit.position)))<.025:
		director._pair_foot_active = false
		capture_ready = false
		_have_last = false
		_bones.clear()

func _clear_greeting_root(sk: Skeleton3D, wanted: Transform3D, delta: float) -> Transform3D:
	# The seated tool follows the previous published greeting root. Rebase
	# that actual root through native motion before querying all its keepouts.
	var worker: RigidBody3D = director.worker
	var current_world: Transform3D = worker.global_transform*_body.affine_inverse()*_bones[0]
	var current: Transform3D = sk.global_transform.affine_inverse()*current_world
	wanted.origin = current.origin.move_toward(wanted.origin,.65*delta)
	var before: Quaternion = current.basis.get_rotation_quaternion().normalized()
	var after: Quaternion = wanted.basis.get_rotation_quaternion().normalized()
	wanted.basis = Basis(before.slerp(after,minf(1.0,6.0*delta/maxf(before.angle_to(after),.0001))))
	if worker.back_tool.travel_frame_clear(sk.global_transform*wanted*current_world.affine_inverse()): return wanted
	if not worker.back_tool.travel_frame_clear(Transform3D.IDENTITY): return current
	var clear: Transform3D = current
	var low: float = 0.0
	var high: float = 1.0
	for attempt: int in 8:
		var weight: float = (low+high)*.5
		var test: Transform3D = Transform3D(Basis(before.slerp(wanted.basis.get_rotation_quaternion().normalized(),weight)),current.origin.lerp(wanted.origin,weight))
		if worker.back_tool.travel_frame_clear(sk.global_transform*test*current_world.affine_inverse()):
			clear = test
			low = weight
		else: high = weight
	return clear

func _clear(worker: RigidBody3D, sole: Vector3, basis: Basis, floor_hit: Dictionary, evaluated_centre := Vector3.INF) -> bool:
	var side: int = director._pair_side
	var centre: Vector3 = evaluated_centre if evaluated_centre.is_finite() else sole-basis*Vector3(0,worker._pose._ankle_height[side],0)+basis*_endings[side].b2b_inv.origin
	var radius: float = (_foot_query.shape as SphereShape3D).radius
	_foot_query.exclude = worker.query_exclusions()
	_foot_query.collision_mask = worker.collision_mask
	_foot_query.transform = Transform3D(Basis.IDENTITY,centre)
	var peer: RigidBody3D = director._pair_peer()
	for hit: Dictionary in worker.get_world_3d().direct_space_state.intersect_shape(_foot_query,6):
		# Only the other exact rounded ending is an intentional contact. Its
		# capsule, any third helper and every world obstacle retain collisions.
		if is_instance_valid(peer) and hit.collider==peer and peer.idle_play and is_instance_valid(peer.idle_play._pair_modifier) and peer.idle_play._pair_modifier.owns_shape(int(hit.shape)): continue
		if floor_hit.is_empty() or hit.collider!=floor_hit.collider or hit.rid!=floor_hit.rid or Vector3(floor_hit.normal).dot(centre-Vector3(floor_hit.position))-radius<-.001: return false
	# Existing ragdoll torso geometry is an exact local keepout for this foot.
	if worker.ragdoll and not worker.ragdoll.rig.bodies.is_empty():
		var torso = worker.ragdoll.rig.bodies[0]
		var cube: Transform3D = worker._skeleton.global_transform*worker._skeleton.get_bone_global_pose(torso.bone)*torso.b2b_inv
		var point: Vector3 = cube.affine_inverse()*centre
		var half: Vector3 = torso.shape.size*.5
		if point.distance_to(point.clamp(-half,half))<radius+.005: return false
	return true

func _add_native_contact(worker: RigidBody3D, centre: Vector3) -> bool:
	var native := PhysicsServer3D.body_get_direct_state(worker.get_rid())
	if not native: return false
	# The original helper already owns a custom COM through its real holder
	# and attached-load model. Never replace that continuously updated COM.
	if worker.center_of_mass_mode!=RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM: return false
	if not worker.axis_lock_angular_x or not worker.axis_lock_angular_y or not worker.axis_lock_angular_z: return false
	if not is_finite(worker.mass) or worker.mass<=0.0 or absf(native.inverse_mass-1.0/worker.mass)>.000001: return false
	# Frozen Jolt MotionProperties::SetMassProperties explicitly retains ZERO
	# inverse inertia for these unchanged locked rotational DOFs after every
	# shape update. Never reciprocate zero, estimate a moment or unlock a body.
	if native.inverse_inertia!=Vector3.ZERO: return false
	for axis in 3:
		if native.inverse_inertia_tensor[axis]!=Vector3.ZERO: return false
	if _shape_owner>=0: return true
	native_contact_baseline = {"inverse_inertia":native.inverse_inertia,"tensor":native.inverse_inertia_tensor,"centre":native.center_of_mass_local,"mass":worker.mass,"layer":worker.collision_layer,"mask":worker.collision_mask,"frame":Engine.get_physics_frames()}
	# The ending is a transient native CONTACT shape, with no added stock or
	# load. Jolt scales the rebuilt shape to the SAME finite explicit mass,
	# preserving its original custom COM and zero effective locked inertia.
	# No mass property, collision filter or angular lock is assigned here.
	_shape_owner = worker.create_shape_owner(self)
	worker.shape_owner_set_transform(_shape_owner,worker.global_transform.affine_inverse()*Transform3D(Basis.IDENTITY,centre))
	worker.shape_owner_add_shape(_shape_owner,_foot_query.shape)
	return true

func owns_shape(index: int) -> bool:
	return _shape_owner>=0 and is_instance_valid(director.worker) and director.worker.shape_find_owner(index)==_shape_owner

func remove_native_contact() -> void:
	if _shape_owner<0 or not director or not is_instance_valid(director.worker): return
	var worker: RigidBody3D = director.worker
	worker.remove_shape_owner(_shape_owner)
	_shape_owner = -1

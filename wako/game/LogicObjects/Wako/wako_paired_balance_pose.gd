extends SkeletonModifier3D
## Finite original leg solves and posed weight transfer. This modifier adds
## only each actual rounded ending as a native contact; it supplies no force.
var director: RefCounted
var posing := false
var returning := false
var supported := false
var meeting_ready := false
var native_geometry_ready := false
var support_rid := RID()
var support_gap := INF
var _support_owner: WeakRef
var _peer_owner: WeakRef
var _support_point := Vector3.INF
var _support_basis := Basis.IDENTITY
var _return_point := Vector3.INF
var _return_owner: WeakRef
var _return_rid := RID()
var _return_stage := ""
var _return_lower_point := Vector3.INF
var _return_turn_point := Vector3.INF
var _return_hold_basis := Basis.IDENTITY
var _lift_egress := Vector3.INF
var _lifting_egress := false
var _last_soles: Array[Vector3] = [Vector3.ZERO,Vector3.ZERO]
var _last_ankles: Array[Basis] = [Basis.IDENTITY,Basis.IDENTITY]
var _last_root := Transform3D.IDENTITY
var _weight := 0.0
var _entry_age := 0.0
const PREPARE_SECONDS := .10
var _endings: Array = []
var _shape_owner := -1
var _foot_query := PhysicsShapeQueryParameters3D.new()
var native_contact_baseline: Dictionary = {}
var evaluated_end_centre := Vector3.INF

func _ready() -> void:
	var sk := get_skeleton()
	if not director or not sk or not is_instance_valid(director.worker) or not director.worker.ragdoll: return
	var native_radius: float = PackedFloat32Array([.09])[0]
	for side in 2:
		var ending = director.worker.ragdoll.rig.by_name.get(StringName(sk.get_bone_name(director.worker._pose._chains[side][2])))
		if not ending or not ending.shape is SphereShape3D or ending.shape.radius!=native_radius: return
		_endings.append(ending)
	native_geometry_ready = true

func _exit_tree() -> void:
	remove_native_contact()
	posing = false
	supported = false
	native_geometry_ready = false
	if director and not director.session.is_empty():
		var owner: RefCounted = director.idle
		if owner: owner.cancel("Paired balance modifier left its original helper")
		else: director.cancel("Paired balance modifier lost its idle owner")
	# The tree owns this modifier; it need not retain its director after exit.
	director = null

func capture() -> bool:
	if not native_geometry_ready or not director or not is_instance_valid(director.worker): return false
	var worker: RigidBody3D = director.worker
	var pose: SkeletonModifier3D = worker._pose
	var other: int = 1-director.side
	if not worker.on_ground or not pose.evaluated_valid or not pose.evaluated_grounded[other] or not pose.evaluated_grounded[director.side]: return false
	support_rid = pose.native_support_rid(other)
	if not support_rid.is_valid(): return false
	var return_floor: Dictionary = pose._walk_ground(pose.evaluated_soles[director.side])
	if return_floor.is_empty() or return_floor.rid!=pose.native_support_rid(director.side): return false
	_return_point = return_floor.position
	_return_owner = weakref(return_floor.collider)
	_return_rid = return_floor.rid
	_return_stage = ""
	_lift_egress = director.lift_egress
	_lifting_egress = _lift_egress.is_finite()
	_support_owner = pose._support[other]
	_peer_owner = weakref(director.peer())
	_support_point = pose.evaluated_soles[other]
	_support_basis = pose.evaluated_ankles[other]
	_last_soles = pose.evaluated_soles.duplicate()
	_last_ankles = pose.evaluated_ankles.duplicate()
	_last_root = pose.evaluated_root
	_weight = 0.0
	_entry_age = 0.0
	posing = true
	returning = false
	supported = true
	meeting_ready = false
	return true

func _process_modification_with_delta(delta: float) -> void:
	if not posing or not director or not is_instance_valid(director.worker): return
	var worker: RigidBody3D = director.worker
	var pose: SkeletonModifier3D = worker._pose
	var sk := get_skeleton()
	if not sk or not worker.is_available() or (worker.ragdoll and worker.ragdoll.pending):
		remove_native_contact()
		posing = false
		supported = false
		return
	var side: int = director.side
	var other := 1-side
	_entry_age += delta
	var inverse := sk.global_transform.affine_inverse()
	var ordinary_root := sk.get_bone_global_pose(0)
	var root_world := sk.global_transform*ordinary_root
	pose.evaluated_unbalanced_root = root_world
	pose.evaluated_unbalanced_com = pose._posed_center_of_mass(sk)
	var return_floor: Dictionary = pose._walk_ground(_return_point) if returning else {}
	var original_floor: Object = _return_owner.get_ref() if _return_owner else null
	var return_floor_ready: bool = not return_floor.is_empty() and return_floor.collider==original_floor and return_floor.rid==_return_rid
	if returning and return_floor_ready and _return_stage.is_empty():
		# First lower in the already clear column with its actual ankle. Keep
		# the planted-support shift until this foot is below the original cube,
		# rather than pulling the cube over the toe while it turns/retracts.
		var floor_normal: Vector3 = return_floor.normal
		var height: float = floor_normal.dot(_last_soles[side]-Vector3(return_floor.position))
		_return_lower_point = _last_soles[side]-floor_normal*maxf(height-.42,0.0)
		_return_hold_basis = _last_ankles[side]
		# Once lowered, move the contacting endings apart before their ankle
		# axes return upright. Early interrupted lifts need no extra withdrawal.
		var forward: float = (_last_soles[side]-worker.global_position).dot(director.normal)
		var cube_half: float = worker.ragdoll.rig.bodies[0].shape.size.z*.5
		_return_turn_point = _return_lower_point-director.normal*clampf(forward-cube_half,0.0,.12)
		_return_stage = "lower" if height>.423 else "turn"
	if _return_stage=="lower" and _last_soles[side].distance_to(_return_lower_point)<.003: _return_stage = "turn"
	var lowering_return: bool = returning and _return_stage=="lower"
	var weight_goal: float = _weight if lowering_return else 0.0 if returning else 1.0
	_weight = move_toward(_weight,weight_goal,delta*2.5)
	var support_hit: Dictionary = pose._walk_ground(_support_point)
	var original_support: Object = _support_owner.get_ref() if _support_owner else null
	supported = worker.on_ground and not support_hit.is_empty() and support_hit.collider==original_support and support_hit.rid==support_rid and support_hit.normal.y>.96
	if not supported and not returning: director.idle.cancel("Paired balancing sole lost its original native floor")
	# After the raised ending is safely below the cube, the original weight
	# already decays during turn/land. Let the cube follow that same finite
	# transfer instead of dropping its entire support offset in one goal.
	if supported:
		var toward: Vector3 = (_support_point-pose._posed_center_of_mass(sk)).slide(Vector3(support_hit.normal))
		# The same finite visual balance used by ordinary foot work. Native
		# upright capsule/spring support is unchanged, not mutual head support.
		root_world.origin += toward.limit_length(.13)*_weight
		var local_toward: Vector3 = sk.global_basis.inverse()*toward
		var height := maxf(Vector3(support_hit.normal).dot(pose._posed_center_of_mass(sk)-_support_point),.45)
		var lean: Basis = Basis(Vector3.RIGHT,clampf(atan2(local_toward.z,height),-.08,.08)*_weight) * Basis(Vector3.BACK,clampf(-atan2(local_toward.x,height),-.14,.14)*_weight)
		root_world.basis = sk.global_basis*lean*ordinary_root.basis
	# A small crouch supplies the measured reach needed while both original
	# soles stay planted. Its smooth tail overlaps the raised-foot entry and
	# continues through an early cancellation rather than removing it at once.
	root_world.origin -= Vector3.UP*_gather_drop(_entry_age)
	var root_goal := root_world.origin
	var root_scale := root_world.basis.get_scale()
	root_world.origin = _last_root.origin.move_toward(root_goal,minf(.045,delta*4.5))
	var root_before := _last_root.basis.orthonormalized().get_rotation_quaternion().normalized()
	var root_after := root_world.basis.orthonormalized().get_rotation_quaternion().normalized()
	var root_angle := root_before.angle_to(root_after)
	root_world.basis = Basis(root_before.slerp(root_after,minf(1.0,delta*4.0/maxf(root_angle,.00001))).normalized()).scaled_local(root_scale)
	sk.set_bone_global_pose(0,inverse*root_world)
	var ordinary_soles: Array[Vector3] = []
	var ordinary_ankles: Array[Basis] = []
	for leg in 2:
		var foot := sk.get_bone_global_pose(pose._chains[leg][2])
		ordinary_soles.append(sk.global_transform*(foot*Vector3(0,pose._ankle_height[leg],0)))
		ordinary_ankles.append(sk.global_basis*foot.basis)
	var desired: Vector3 = _lift_egress if _lifting_egress and not returning else director.meeting
	var desired_basis: Basis = Basis(Quaternion(director.start_basis.y.normalized(),director.normal))*director.start_basis
	# The cube first gathers onto the actual opposite planted sole. Both feet
	# retain their captured positions during this brief preparation; the same
	# finite reach and clearance solves remain responsible for every step.
	if not returning and _entry_age<PREPARE_SECONDS:
		desired = _last_soles[side]
		desired_basis = director.start_basis
	if returning:
		# The prior evaluated sole belongs to this raised-foot pose. Incoming
		# terrain IK seeds from that sole, so it is not an independent landing
		# endpoint. Return to the original observed floor through the same
		# finite reach, Cartesian step and ankle rotation bounds instead.
		if return_floor_ready:
			var rest: Basis = pose._walk_rest_feet[side]
			var local_normal: Vector3 = (sk.global_basis.inverse()*Vector3(return_floor.normal)).normalized()
			var landing_basis := Basis(Quaternion(-rest.y.normalized(),local_normal))*rest
			desired = pose._reachable_plant(sk,side,return_floor.position,landing_basis,return_floor.normal)
			desired_basis = sk.global_basis*landing_basis
			if _return_stage=="lower":
				desired = _return_lower_point
				desired_basis = _return_hold_basis
			elif _return_stage=="turn": desired = _return_turn_point
		else:
			desired = _last_soles[side]
			desired_basis = _last_ankles[side]
	var before := _last_ankles[side].get_rotation_quaternion().normalized()
	var after := desired_basis.get_rotation_quaternion().normalized()
	var angle := before.angle_to(after)
	# Keep the original brisk upper rate, then close the last few degrees
	# deliberately instead of arriving at the target at full angular speed.
	var ankle_step := minf(delta*8.0,angle*(1.0-exp(-24.0*delta)))
	var world_basis := Basis(before.slerp(after,minf(1.0,ankle_step/maxf(angle,.00001))).normalized())
	var basis := sk.global_basis.inverse()*world_basis
	_foot_query.shape = _endings[side].shape
	# Fast travel and a short ease-out share the original Cartesian 4.5 m/s
	# ceiling. This also softens each safe lower/turn/land recovery endpoint.
	var sole_step := minf(minf(.045,delta*4.5),_last_soles[side].distance_to(desired)*(1.0-exp(-24.0*delta)))
	var sole: Vector3 = pose._bounded_head_sole(sk,side,_last_soles[side],desired,basis,sole_step)
	var floor_hit: Dictionary = pose._walk_ground(sole)
	if not _clear(worker,sole,world_basis,floor_hit):
		if not returning: director.idle.cancel("Paired balancing foot route became obstructed")
		world_basis = Basis(before)
		basis = sk.global_basis.inverse()*world_basis
		sole = pose._bounded_head_sole(sk,side,_last_soles[side],_last_soles[side],basis,minf(.045,delta*4.5))
	var original_walking: bool = pose._walking_ik
	pose._walking_ik = true
	var chain: Array = pose._chains[side]
	pose._solve(sk,chain[0],chain[1],chain[2],inverse*sole-basis*Vector3(0,pose._ankle_height[side],0),1.0,basis)
	# The other actual finite leg remains on its original observed floor.
	# During release it can converge to ordinary IK without an endpoint snap.
	# Keep the real opposite sole planted while its cube is still transferring
	# weight back. Ordinary IK becomes its target only after that transfer.
	var keep_support: bool = supported and (not returning or lowering_return or _weight>.001)
	var other_goal: Vector3 = _support_point if keep_support else ordinary_soles[other]
	var other_after := (_support_basis if keep_support else ordinary_ankles[other]).get_rotation_quaternion().normalized()
	var other_before := _last_ankles[other].get_rotation_quaternion().normalized()
	var other_angle := other_before.angle_to(other_after)
	var other_world := Basis(other_before.slerp(other_after,minf(1.0,delta*8.0/maxf(other_angle,.00001))).normalized())
	var other_basis := sk.global_basis.inverse()*other_world
	var other_sole: Vector3 = pose._bounded_head_sole(sk,other,_last_soles[other],other_goal,other_basis,minf(.045,delta*4.5))
	var other_chain: Array = pose._chains[other]
	pose._solve(sk,other_chain[0],other_chain[1],other_chain[2],inverse*other_sole-other_basis*Vector3(0,pose._ankle_height[other],0),1.0,other_basis)
	pose._walking_ik = original_walking
	for leg in 2:
		var bones: Array = pose._chains[leg]
		var foot := sk.get_bone_global_pose(bones[2])
		pose.evaluated_hips[leg] = sk.global_transform*sk.get_bone_global_pose(bones[0]).origin
		pose.evaluated_knees[leg] = sk.global_transform*sk.get_bone_global_pose(bones[1]).origin
		pose.evaluated_ankles[leg] = sk.global_basis*foot.basis
		pose.evaluated_soles[leg] = sk.global_transform*(foot*Vector3(0,pose._ankle_height[leg],0))
	var actual: Vector3 = pose.evaluated_soles[side]
	var planted: Vector3 = pose.evaluated_soles[other]
	support_gap = absf(Vector3(support_hit.normal).dot(planted-Vector3(support_hit.position))) if not support_hit.is_empty() else INF
	supported = supported and support_gap<.025 and planted.distance_to(_support_point)<.025
	pose.evaluated_grounded[other] = supported if not returning else worker.on_ground and not support_hit.is_empty() and support_gap<.025 and planted.distance_to(other_goal)<.025
	pose.evaluated_grounded[side] = false
	pose._target_valid[side] = false
	pose.evaluated_balance_support_side = other
	pose.evaluated_balance_support_point = planted
	pose.evaluated_root = sk.global_transform*sk.get_bone_global_pose(0)
	pose.evaluated_worker = worker.global_transform
	pose.evaluated_basis = sk.global_basis
	pose.evaluated_visual_com = pose._posed_center_of_mass(sk)
	pose.evaluated_valid = true
	pose.evaluation_serial += 1
	_last_soles = pose.evaluated_soles.duplicate()
	_last_ankles = pose.evaluated_ankles.duplicate()
	_last_root = pose.evaluated_root
	evaluated_end_centre = (sk.global_transform*sk.get_bone_global_pose(chain[2])*_endings[side].b2b_inv).origin
	worker._update_head(pose.evaluated_root)
	if worker.ragdoll: worker.ragdoll.remember_pose()
	if not returning and _lifting_egress and supported and _weight>.999 and actual.distance_to(_lift_egress)<.003 and angle<.008 and root_world.origin.distance_to(root_goal)<.003 and root_angle<.008: _lifting_egress = false
	meeting_ready = not _lifting_egress and supported and actual.distance_to(director.meeting)<.012 and world_basis.y.dot(director.normal)>.97
	if not returning and director.session.get("stage","")=="press" and meeting_ready:
		if not _clear(worker,actual,pose.evaluated_ankles[side],pose._walk_ground(actual),evaluated_end_centre) or not _add_native_contact(worker,evaluated_end_centre): director.idle.cancel("Actual balancing ending lost its unchanged native clearance or inertia")
		if _shape_owner>=0: worker.shape_owner_set_transform(_shape_owner,worker.global_transform.affine_inverse()*Transform3D(Basis.IDENTITY,evaluated_end_centre))
	else: remove_native_contact()
	if returning and _return_stage=="turn" and return_floor_ready and _weight<.001 and actual.distance_to(_return_turn_point)<.003 and angle<.008 and root_world.origin.distance_to(root_goal)<.003 and root_angle<.008 and pose.evaluated_grounded[other]: _return_stage = "land"
	if returning and _return_stage=="land" and return_floor_ready and _weight<.001 and pose.evaluated_grounded[other] and actual.distance_to(desired)<.003 and angle<.008 and root_world.origin.distance_to(root_goal)<.003 and root_angle<.008 and not floor_hit.is_empty() and floor_hit.collider==_return_owner.get_ref() and floor_hit.rid==_return_rid and absf(Vector3(floor_hit.normal).dot(actual-Vector3(floor_hit.position)))<.025:
		posing = false
		meeting_ready = false

func _prospective_root(sk: Skeleton3D, root: Transform3D, point: Vector3, normal: Vector3, weight: float, original_com := Vector3.INF) -> Transform3D:
	# The actual original support point, cube and current unbalanced COM.
	# This predicts admission only; each evaluated pose still reobserves its
	# native floor and checks the actual whole cube before moving the ending.
	var pose: SkeletonModifier3D = director.worker._pose
	var centre: Vector3 = original_com if original_com.is_finite() else pose._posed_center_of_mass(sk)
	var toward: Vector3 = (point-centre).slide(normal)
	var height := maxf(normal.dot(centre-point),.45)
	var local_toward: Vector3 = sk.global_basis.inverse()*toward
	var lean := Basis(Vector3.RIGHT,clampf(atan2(local_toward.z,height),-.08,.08)*weight)*Basis(Vector3.BACK,clampf(-atan2(local_toward.x,height),-.14,.14)*weight)
	return Transform3D(sk.global_basis*lean*sk.global_basis.inverse()*root.basis,root.origin+toward.limit_length(.13)*weight-Vector3.UP*_gather_drop(weight/2.5))

func _gather_drop(age: float) -> float:
	var phase := clampf(age/.28,0.0,1.0)
	return .012*pow(sin(PI*phase),2.0)

func _cube_gap(centre: Vector3, cube: Transform3D) -> float:
	var torso = director.worker.ragdoll.rig.bodies[0]
	var half: Vector3 = torso.shape.size*.5
	var point: Vector3 = cube.affine_inverse()*centre
	return point.distance_to(point.clamp(-half,half))

func admission(leg: int, meeting: Vector3, facing: Vector3) -> Dictionary:
	if not native_geometry_ready: return {}
	var worker: RigidBody3D = director.worker
	var pose: SkeletonModifier3D = worker._pose
	if not pose.evaluated_valid: return {}
	var sk := get_skeleton()
	var support: Dictionary = pose._walk_ground(pose.evaluated_soles[1-leg])
	if support.is_empty() or support.rid!=pose.native_support_rid(1-leg) or support.normal.y<=.96: return {}
	# Outside this modifier Skeleton3D restores authored bones. Admission
	# must use the same evaluated, body-rebased geometry as evaluated_hip().
	# The original rig torso is Bone (index 0), the captured evaluated root.
	var torso = worker.ragdoll.rig.bodies[0]
	if torso.bone!=0 or sk.get_bone_name(0)!=&"Bone": return {}
	var rebase: Transform3D = worker.global_transform*pose.evaluated_worker.affine_inverse()
	var root: Transform3D = rebase*pose.evaluated_root
	var cube: Transform3D = root*torso.b2b_inv
	var original_com: Vector3 = rebase*pose.evaluated_visual_com
	var shifted := _prospective_root(sk,root,pose.evaluated_soles[1-leg],support.normal,1.0,original_com)
	var change := shifted*root.affine_inverse()
	var predicted_cube := change*cube
	var start: Basis = rebase.basis*pose.evaluated_ankles[leg]
	var final_basis := Basis(Quaternion(start.y.normalized(),facing))*start
	var ankle: Vector3 = meeting-final_basis*Vector3(0,pose._ankle_height[leg],0)
	var hip: Vector3 = worker.evaluated_hip(leg)
	var original_margin: float = worker._leg_lengths[leg]-.012-worker.evaluated_hip(leg).distance_to(ankle)
	var margin: float = minf(original_margin,worker._leg_lengths[leg]-.012-(change*hip).distance_to(ankle))
	if margin<=.035: return {}
	var radius: float = _endings[leg].shape.radius
	var offset: Vector3 = Vector3(0,-pose._ankle_height[leg],0)+_endings[leg].b2b_inv.origin
	var centre: Vector3 = meeting+final_basis*offset
	if _cube_gap(centre,predicted_cube)<radius+.005: return {}
	_foot_query.shape = _endings[leg].shape
	if not _native_clear(worker,centre,pose._walk_ground(meeting)): return {}
	# Test the original direct lift against the bounded root transfer and
	# original sphere, using pure current-geometry samples rather than
	# changing bones or querying an invented collider. A blocked route needs
	# a low egress and actual full cube convergence before it rises.
	var previous: Vector3 = pose.evaluated_soles[leg]
	if not _admitted_segment(leg,previous,previous,start,start,root,cube,pose.evaluated_soles[1-leg],support.normal,0.0,PREPARE_SECONDS): return {}
	var before := start.get_rotation_quaternion().normalized()
	var after := final_basis.get_rotation_quaternion().normalized()
	var angle := before.angle_to(after)
	var seconds := maxf(previous.distance_to(meeting)/4.5,angle/8.0)
	var egress := Vector3.INF
	for sample in 17:
		var elapsed := seconds*float(sample)/16.0
		var sole := previous.move_toward(meeting,elapsed*4.5)
		var basis := Basis(before.slerp(after,minf(1.0,elapsed*8.0/maxf(angle,.00001))).normalized())
		var carried := _prospective_root(sk,root,pose.evaluated_soles[1-leg],support.normal,minf(1.0,(elapsed+PREPARE_SECONDS)*2.5),original_com)*root.affine_inverse()
		if _cube_gap(sole+basis*offset,carried*cube)<radius+.005 or (carried*hip).distance_to(sole-basis*Vector3(0,pose._ankle_height[leg],0))>worker._leg_lengths[leg]-.012:
			var floor_hit: Dictionary = pose._walk_ground(meeting)
			if floor_hit.is_empty(): return {}
			var normal: Vector3 = floor_hit.normal
			var floor_height: float = normal.dot(meeting-Vector3(floor_hit.position))
			egress = meeting-normal*maxf(floor_height-.42,0.0)
			break
	var floor_hit: Dictionary = pose._walk_ground(meeting)
	if floor_hit.is_empty(): return {}
	var low: Vector3 = meeting-Vector3(floor_hit.normal)*maxf(Vector3(floor_hit.normal).dot(meeting-Vector3(floor_hit.position))-.42,0.0)
	var low_seconds := maxf(previous.distance_to(low)/4.5,angle/8.0)
	var low_valid := _admitted_segment(leg,previous,low,start,final_basis,root,cube,pose.evaluated_soles[1-leg],support.normal,PREPARE_SECONDS)
	low_valid = low_valid and _admitted_segment(leg,low,low,final_basis,final_basis,root,cube,pose.evaluated_soles[1-leg],support.normal,low_seconds+PREPARE_SECONDS,.4)
	low_valid = low_valid and _admitted_segment(leg,low,meeting,final_basis,final_basis,root,cube,pose.evaluated_soles[1-leg],support.normal,.4)
	_foot_query.shape = _endings[leg].shape
	low_valid = low_valid and _native_clear(worker,low+final_basis*offset,pose._walk_ground(low))
	if egress.is_finite() and not low_valid: return {}
	return {"leg":leg,"margin":margin,"basis":start,"cube":predicted_cube,"centre":centre,"egress":egress,"low":low,"low_valid":low_valid,"radius":radius}

func _admitted_segment(leg: int, start: Vector3, goal: Vector3, before_basis: Basis, after_basis: Basis, root: Transform3D, cube: Transform3D, support_point: Vector3, support_normal: Vector3, began: float, hold_until := -1.0) -> bool:
	var worker: RigidBody3D = director.worker
	var pose: SkeletonModifier3D = worker._pose
	var sk := get_skeleton()
	var before := before_basis.get_rotation_quaternion().normalized()
	var after := after_basis.get_rotation_quaternion().normalized()
	var angle := before.angle_to(after)
	var seconds := maxf(start.distance_to(goal)/4.5,angle/8.0)
	if hold_until>=0.0: seconds = maxf(0.0,hold_until-began)
	var hip: Vector3 = worker.evaluated_hip(leg)
	var offset: Vector3 = Vector3(0,-pose._ankle_height[leg],0)+_endings[leg].b2b_inv.origin
	var radius: float = _endings[leg].shape.radius
	var rebase: Transform3D = worker.global_transform*pose.evaluated_worker.affine_inverse()
	var original_com: Vector3 = rebase*pose.evaluated_visual_com
	var inverse := root.affine_inverse()
	for sample in 17:
		var elapsed := seconds*float(sample)/16.0
		var sole := start.move_toward(goal,elapsed*4.5)
		var basis := Basis(before.slerp(after,minf(1.0,elapsed*8.0/maxf(angle,.00001))).normalized())
		var carry := _prospective_root(sk,root,support_point,support_normal,minf(1.0,(began+elapsed)*2.5),original_com)*inverse
		var ankle: Vector3 = sole-basis*Vector3(0,pose._ankle_height[leg],0)
		if (carry*hip).distance_to(ankle)>worker._leg_lengths[leg]-.012 or _cube_gap(sole+basis*offset,carry*cube)<radius+.005: return false
	return true

func _native_clear(worker: RigidBody3D, centre: Vector3, floor_hit: Dictionary) -> bool:
	var radius: float = (_foot_query.shape as SphereShape3D).radius
	_foot_query.exclude = worker.query_exclusions()
	_foot_query.collision_mask = worker.collision_mask
	_foot_query.transform = Transform3D(Basis.IDENTITY,centre)
	var neighbour: RigidBody3D = director.peer()
	for hit: Dictionary in worker.get_world_3d().direct_space_state.intersect_shape(_foot_query,6):
		if is_instance_valid(neighbour) and hit.collider==neighbour and neighbour.idle_play and is_instance_valid(neighbour.idle_play.paired_balance.pose) and neighbour.idle_play.paired_balance.pose.owns_shape(int(hit.shape)): continue
		if floor_hit.is_empty() or hit.collider!=floor_hit.collider or hit.rid!=floor_hit.rid or Vector3(floor_hit.normal).dot(centre-Vector3(floor_hit.position))-radius<-.001: return false
	return true

func _clear(worker: RigidBody3D, sole: Vector3, basis: Basis, floor_hit: Dictionary, evaluated_centre := Vector3.INF) -> bool:
	var side: int = director.side
	var centre: Vector3 = evaluated_centre if evaluated_centre.is_finite() else sole-basis*Vector3(0,worker._pose._ankle_height[side],0)+basis*_endings[side].b2b_inv.origin
	var radius: float = (_foot_query.shape as SphereShape3D).radius
	if not _native_clear(worker,centre,floor_hit): return false
	if worker.ragdoll and not worker.ragdoll.rig.bodies.is_empty():
		var torso = worker.ragdoll.rig.bodies[0]
		var cube: Transform3D = worker._skeleton.global_transform*worker._skeleton.get_bone_global_pose(torso.bone)*torso.b2b_inv
		var point: Vector3 = cube.affine_inverse()*centre
		var half: Vector3 = torso.shape.size*.5
		if point.distance_to(point.clamp(-half,half))<radius+.005: return false
	var neighbour: RigidBody3D = _peer_owner.get_ref() if _peer_owner else null
	if is_instance_valid(neighbour):
		# The other skeleton is outside its modifier here, including recovery
		# after the shared session is cancelled. Its evaluated original torso
		# remains authoritative; a missing pose never means a clear body.
		if not neighbour.ragdoll or neighbour.ragdoll.rig.bodies.is_empty() or not neighbour._pose or not neighbour._pose.evaluated_valid: return false
		var torso = neighbour.ragdoll.rig.bodies[0]
		if torso.bone!=0 or neighbour._skeleton.get_bone_name(0)!=&"Bone": return false
		var rebase: Transform3D = neighbour.global_transform*neighbour._pose.evaluated_worker.affine_inverse()
		var cube: Transform3D = rebase*neighbour._pose.evaluated_root*torso.b2b_inv
		var point: Vector3 = cube.affine_inverse()*centre
		var half: Vector3 = torso.shape.size*.5
		if point.distance_to(point.clamp(-half,half))<radius+.005: return false
	return true

func _add_native_contact(worker: RigidBody3D, centre: Vector3) -> bool:
	var native := PhysicsServer3D.body_get_direct_state(worker.get_rid())
	if not native or worker.center_of_mass_mode!=RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM: return false
	if not worker.axis_lock_angular_x or not worker.axis_lock_angular_y or not worker.axis_lock_angular_z: return false
	if not is_finite(worker.mass) or worker.mass<=0.0 or absf(native.inverse_mass-1.0/worker.mass)>.000001: return false
	if native.inverse_inertia!=Vector3.ZERO: return false
	for axis in 3:
		if native.inverse_inertia_tensor[axis]!=Vector3.ZERO: return false
	if _shape_owner>=0: return true
	native_contact_baseline = {"inverse_inertia":native.inverse_inertia,"tensor":native.inverse_inertia_tensor,"centre":native.center_of_mass_local,"mass":worker.mass,"layer":worker.collision_layer,"mask":worker.collision_mask,"frame":Engine.get_physics_frames()}
	_shape_owner = worker.create_shape_owner(self)
	worker.shape_owner_set_transform(_shape_owner,worker.global_transform.affine_inverse()*Transform3D(Basis.IDENTITY,centre))
	worker.shape_owner_add_shape(_shape_owner,_foot_query.shape)
	return true

func owns_shape(index: int) -> bool:
	return _shape_owner>=0 and is_instance_valid(director.worker) and director.worker.shape_find_owner(index)==_shape_owner

func remove_native_contact() -> void:
	if _shape_owner<0 or not director or not is_instance_valid(director.worker): return
	director.worker.remove_shape_owner(_shape_owner)
	_shape_owner = -1

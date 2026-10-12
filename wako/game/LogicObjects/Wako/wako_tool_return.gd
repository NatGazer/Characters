extends RefCounted
## Continue a retained tool from its last actual pose, not a fresh clear axis.
## The existing finite leg and complete-tool guards decide every candidate.
const TURN_SPEED := 6.0
const SOLE_SPEED := 5.4
const WORLD_STEP := .05
const NativeRelease = preload("res://Components/Contraptions/worker_native_tool_release.gd")
static var _native_boxes := {}
static var _sole_probe: SphereShape3D
static var _head_tool_boxes := {}

static func maximum_step(worker: RigidBody3D, delta: float) -> float:
	return minf(.045,SOLE_SPEED*delta)

static func continue_pose(pose: SkeletonModifier3D, sk: Skeleton3D, desired_foot: Transform3D,
		desired_tool: Basis, delta: float) -> Dictionary:
	var worker: RigidBody3D = pose.worker
	var side: int = worker.tool_foot_side()
	var chain: Array = pose._chains[side]
	var toe_index: int = pose._toes[side]
	var inverse := sk.global_transform.affine_inverse()
	var root: Transform3D = sk.global_transform*sk.get_bone_global_pose(0)
	var incoming: Array[Transform3D] = []
	for bone in sk.get_bone_count(): incoming.append(sk.get_bone_global_pose(bone))
	# Native movement carries a lifted toe, while a genuine plant follows its
	# support. Facing the cube must not orbit this actual world sole or mallet.
	var native_rebase: Transform3D = worker.global_transform*pose.evaluated_worker.affine_inverse()
	var previous_sole: Vector3 = pose.evaluated_soles[side]+worker.ground_velocity*delta if pose._tool_return_previous_grounded[side] else native_rebase*pose.evaluated_soles[side]
	var previous_ankle: Basis = sk.global_basis*pose.evaluated_basis.inverse()*pose.evaluated_ankles[side]
	var previous_tool: Basis = sk.global_basis*pose.evaluated_basis.inverse()*worker.tool_grip_transform.basis
	var local_previous_tool: Basis = pose.evaluated_basis.inverse()*worker.tool_grip_transform.basis
	var local_previous_ankle: Basis = pose.evaluated_basis.inverse()*pose.evaluated_ankles[side]
	var previous_knee: Vector3 = pose.evaluated_basis.inverse()*(pose.evaluated_knees[side]-pose.evaluated_hips[side]).normalized()
	var turn_limit := TURN_SPEED*delta
	var ankle := _turn(previous_ankle,sk.global_basis*desired_foot.basis,turn_limit)
	var tool := _turn(previous_tool,desired_tool,turn_limit)
	var sole_offset := Vector3(0,pose._ankle_height[side],0)
	var desired_sole: Vector3 = sk.global_transform*(desired_foot*sole_offset)
	var step := maximum_step(worker,delta)
	var wanted := (desired_sole-previous_sole).limit_length(step)
	var outward := (previous_sole-root.origin).slide(Vector3.UP).normalized()
	if outward.length_squared() < .01: outward = sk.global_basis.x*(1.0 if side==0 else -1.0)
	var world_previous: Vector3 = pose.evaluated_soles[side]+worker.ground_velocity*delta
	var bases: Array[Basis] = [tool,previous_tool]
	for direction: Vector3 in [sk.global_basis.x,sk.global_basis.y,sk.global_basis.z]:
		for amount: float in [-turn_limit,turn_limit]: bases.append(Basis(direction,amount)*previous_tool)
	var offsets: Array[Vector3] = [wanted,(world_previous-previous_sole).limit_length(step),Vector3.ZERO,Vector3.DOWN*step,outward*step,
		(outward+Vector3.DOWN).normalized()*step,Vector3.UP*step,
		(outward+Vector3.UP).normalized()*step,-outward*step]
	var rejected := {"surface":0,"reach":0,"floor":0,"knee":0,"ankle":0,"grip":0,"angle":0,"clearance":0}
	var unobserved_checks := 0
	var query := PhysicsRayQueryParameters3D.new()
	query.collision_mask = 1
	query.exclude = worker.query_exclusions()
	var terrain := worker.get_world_3d().direct_space_state
	for offset: Vector3 in offsets:
		var sole := previous_sole+offset
		query.from = Vector3(sole.x,maxf(sole.y+.5,worker.global_position.y+.12),sole.z)
		# This observes the raised tool's floor; a gap above35mm remains
		# explicitly unplanted and never extends the finite IK chain.
		query.to = sole-Vector3.UP*(worker._leg_lengths[side]+worker.ride_height+.35)
		var surface := terrain.intersect_ray(query)
		if surface.is_empty(): rejected.surface+=1
		elif surface.normal.y<=.6: rejected.surface+=1; continue
		else: sole += surface.normal*maxf(-surface.normal.dot(sole-surface.position),0.0)
		if sole.distance_to(previous_sole) > step+.001: rejected.floor+=1; continue
		pose._solve(sk,chain[0],chain[1],chain[2],inverse*sole-sk.global_basis.inverse()*ankle*sole_offset,1.0,sk.global_basis.inverse()*ankle)
		var foot := sk.get_bone_global_pose(chain[2])
		var solved_sole: Vector3 = sk.global_transform*(foot*sole_offset)
		if solved_sole.distance_to(previous_sole) > step+.001: rejected.reach+=1; continue
		if solved_sole.distance_to(pose.evaluated_soles[side]+worker.ground_velocity*delta) >= WORLD_STEP: rejected.reach+=1; continue
		# Reach clamps can move the ankle into a different column. Observe that
		# actual endpoint before accepting its plane, plant or tool clearance.
		query.from = Vector3(solved_sole.x,maxf(solved_sole.y+.5,worker.global_position.y+.12),solved_sole.z)
		query.to = solved_sole-Vector3.UP*(worker._leg_lengths[side]+worker.ride_height+.35)
		surface = terrain.intersect_ray(query)
		if surface.is_empty():
			if unobserved_checks>=4 or not _native_sole_clear(worker,solved_sole): rejected.surface+=1; continue
		elif surface.normal.y<=.6: rejected.surface+=1; continue
		var gap: float = INF if surface.is_empty() else surface.normal.dot(solved_sole-surface.position)
		if gap < -.001: rejected.floor+=1; continue
		var knee: Vector3 = (sk.get_bone_global_pose(chain[1]).origin-sk.get_bone_global_pose(chain[0]).origin).normalized()
		if knee.angle_to(previous_knee) >= deg_to_rad(12.0): rejected.knee+=1; continue
		if local_previous_ankle.get_rotation_quaternion().angle_to(foot.basis.get_rotation_quaternion()) >= deg_to_rad(18.0): rejected.ankle+=1; continue
		var toe := sk.get_bone_global_pose(toe_index)
		var origin: Vector3 = sk.global_transform*toe.origin
		if origin.distance_to(worker.tool_grip_transform.origin+worker.ground_velocity*delta) >= WORLD_STEP: rejected.grip+=1; continue
		for basis: Basis in bases:
			var local_basis: Basis = sk.global_basis.inverse()*basis
			if local_previous_tool.get_rotation_quaternion().angle_to(local_basis.get_rotation_quaternion()) >= deg_to_rad(18.0): rejected.angle+=1; continue
			if (native_rebase.basis*worker.tool_grip_transform.basis).get_rotation_quaternion().angle_to(basis.get_rotation_quaternion()) >= deg_to_rad(18.0): rejected.angle+=1; continue
			if not head_tool_native_clear(worker,origin,basis,surface,delta): rejected.clearance+=1; continue
			if surface.is_empty():
				unobserved_checks+=1
				if unobserved_checks>4: break
				if not _native_tool_clear(worker,origin,basis): rejected.clearance+=1; continue
			elif not worker.held_tool_basis_clear(origin,basis,surface.position,surface.normal): rejected.clearance+=1; continue
			toe.basis = local_basis
			sk.set_bone_global_pose(toe_index,toe)
			if surface.is_empty():
				var unobserved := _validate_frame(pose,sk,root,delta,false,true)
				if unobserved.is_empty(): rejected.clearance+=1; continue
				return unobserved
			return {"toe":toe,"point":surface.position,"normal":surface.normal,"collider":surface.collider,"sole":solved_sole,"gap":gap}
	# If the hip's new sway crowds every toe candidate, continue the complete
	# last evaluated frame briefly. Validate its actual finite chain, native
	# columns and payload; this is never an unchecked cached endpoint.
	var saved: Array[Transform3D] = pose._tool_return_bones
	if saved.size()==sk.get_bone_count():
		for rebase: Transform3D in [native_rebase,Transform3D(Basis.IDENTITY,worker.ground_velocity*delta)]:
			for bone in sk.get_bone_count(): sk.set_bone_global_pose(bone,inverse*(rebase*saved[bone]))
			var held: Dictionary = _validate_frame(pose,sk,root,delta)
			if not held.is_empty():
				held.held = true
				held.blocked = true
				worker.stop_navigation()
				return held
	# A finite raised column can end outside a platform. A missing ray alone
	# does not prove an obstruction or grant a plant: check the current native
	# geometry, full tool and finite continuity, and invalidate both old plants.
	if rejected.surface>0:
		var frames: Array[Array] = []
		if saved.size()==sk.get_bone_count():
			var rebased: Array[Transform3D] = []
			for bone in sk.get_bone_count(): rebased.append(inverse*(native_rebase*saved[bone]))
			frames.append(rebased)
		frames.append(incoming)
		for frame: Array in frames:
			for bone in sk.get_bone_count(): sk.set_bone_global_pose(bone,frame[bone])
			var unobserved := _validate_frame(pose,sk,root,delta,false,true)
			if unobserved.is_empty(): continue
			unobserved.held=true
			unobserved.blocked=true
			worker.stop_navigation()
			return unobserved
	if saved.size()==sk.get_bone_count():
		# Keep the real tool body where it already is if it cannot follow any
		# bounded finite foot pose. Release is accepted only with a clear native
		# tool and a fully checked current rig, including both observed soles.
		for rebase: Transform3D in [native_rebase,Transform3D(Basis.IDENTITY,worker.ground_velocity*delta)]:
			for bone in sk.get_bone_count(): sk.set_bone_global_pose(bone,inverse*(rebase*saved[bone]))
			var released: Dictionary = _validate_frame(pose,sk,root,delta,true)
			if released.is_empty(): continue
			_native_release(worker)
			released.released = true
			released.blocked = true
			return released
	# No safe finite rendered recovery exists. Hand the last actual bones to
	# the existing native recovery, instead of publishing a rejected new solve.
	# Its original collision bodies, muscle caps and cooldown remain in charge.
	var actual: Array[Transform3D] = pose._tool_return_actual_bones
	if actual.size()==sk.get_bone_count():
		for bone in sk.get_bone_count(): sk.set_bone_global_pose(bone,inverse*(native_rebase*actual[bone]))
	else:
		for bone in sk.get_bone_count(): sk.set_bone_global_pose(bone,incoming[bone])
	var retained_toe := sk.get_bone_global_pose(toe_index)
	if "--tool-return-debug" in OS.get_cmdline_user_args() and (pose.evaluation_serial%20==0 or pose._tool_return_first_block):
		pose._tool_return_first_block = false
		print("CONTRAPTION_TOOL_RETURN_BLOCK serial=",pose.evaluation_serial," body=",worker.global_position," side=",side," oldsole=",world_previous," native_sole=",previous_sole," wanted=",desired_sole," rejected=",rejected," guard=",worker.held_tool_clearance_debug(sk.global_transform*retained_toe.origin,previous_tool,pose._terrain_points[side],pose._sole_normals[side]))
	# Missing columns were independently checked above. Only rejection of
	# actual finite/current geometry may now yield; startup without a previous
	# evaluated frame never reaches this continuation entry.
	if pose.evaluated_valid and worker.ragdoll and not worker.ragdoll.is_down():
		_native_release(worker,true)
		if _yield_geometry(worker):
			# Ordinary lease cancellation seeks the interrupted authored clip.
			# Restore the actual evaluated bones after those synchronous callbacks
			# so native enable captures the frame that was really displayed.
			if actual.size()==sk.get_bone_count():
				for bone in sk.get_bone_count(): sk.set_bone_global_pose(bone,inverse*(native_rebase*actual[bone]))
			worker.ragdoll.modify(delta)
			worker.tool_pose_blocked = "No clear supported retained-tool posture; recovering physically"
			return {"physical":true,"released":true,"blocked":true}
	return {}

static func _yield_geometry(worker: RigidBody3D) -> bool:
	# Ordinary hits retain the adapter's post-get-up cooldown. A proven lack
	# of a complete current finite pose cannot publish an unsafe endpoint
	# during that cooldown; it yields with zero additional impulse instead.
	var cooldown: float = worker.ragdoll._cooldown
	worker.ragdoll._cooldown = 0.0
	var accepted: bool = worker.ragdoll.knock_down()
	if not accepted: worker.ragdoll._cooldown=cooldown
	return accepted

static func _validate_frame(pose: SkeletonModifier3D, sk: Skeleton3D, desired_root: Transform3D, delta: float, release := false, allow_unobserved := false) -> Dictionary:
	var worker: RigidBody3D = pose.worker
	var root: Transform3D = sk.global_transform*sk.get_bone_global_pose(0)
	if root.origin.distance_to(desired_root.origin)>.045:
		if allow_unobserved and "--tool-return-debug" in OS.get_cmdline_user_args(): print("RETURN_FRAME_REJECT desiredroot ",root.origin.distance_to(desired_root.origin))
		return {}
	if root.basis.get_rotation_quaternion().angle_to(desired_root.basis.get_rotation_quaternion())>.12: return {}
	var current_local: Transform3D = worker.global_transform.affine_inverse()*root
	var previous_local: Transform3D = pose.evaluated_worker.affine_inverse()*pose.evaluated_root
	if current_local.origin.distance_to(previous_local.origin)>=.025: return {}
	if (sk.global_basis.inverse()*root.basis).get_rotation_quaternion().angle_to((pose.evaluated_basis.inverse()*pose.evaluated_root.basis).get_rotation_quaternion())>=deg_to_rad(6): return {}
	var query := PhysicsRayQueryParameters3D.new()
	query.collision_mask = 1
	query.exclude = worker.query_exclusions()
	var terrain := worker.get_world_3d().direct_space_state
	var accepted := {}
	var planes: Array[Dictionary] = []
	for side in 2:
		var chain: Array = pose._chains[side]
		var foot := sk.get_bone_global_pose(chain[2])
		var sole: Vector3 = sk.global_transform*(foot*Vector3(0,pose._ankle_height[side],0))
		if sole.distance_to(pose.evaluated_soles[side]+worker.ground_velocity*delta)>=WORLD_STEP:
			if allow_unobserved and "--tool-return-debug" in OS.get_cmdline_user_args(): print("RETURN_FRAME_REJECT sole ",side," ",sole.distance_to(pose.evaluated_soles[side]+worker.ground_velocity*delta))
			return {}
		query.from = Vector3(sole.x,maxf(sole.y+.5,worker.global_position.y+.12),sole.z)
		query.to = sole-Vector3.UP*(worker._leg_lengths[side]+worker.ride_height+.35)
		var surface := terrain.intersect_ray(query)
		if surface.is_empty():
			if not allow_unobserved or not _native_sole_clear(worker,sole): return {}
			planes.append({"point":Vector3.INF,"normal":Vector3.UP,"collider":null,"gap":INF,"unobserved":true})
		else:
			if surface.normal.y<=.6 or surface.normal.dot(sole-surface.position)<-.001: return {}
			planes.append({"point":surface.position,"normal":surface.normal,"collider":surface.collider,"gap":surface.normal.dot(sole-surface.position)})
		var knee: Vector3 = (sk.get_bone_global_pose(chain[1]).origin-sk.get_bone_global_pose(chain[0]).origin).normalized()
		var previous_knee: Vector3 = pose.evaluated_basis.inverse()*(pose.evaluated_knees[side]-pose.evaluated_hips[side]).normalized()
		if knee.angle_to(previous_knee)>=deg_to_rad(12):
			if allow_unobserved and "--tool-return-debug" in OS.get_cmdline_user_args(): print("RETURN_FRAME_REJECT knee ",side," ",rad_to_deg(knee.angle_to(previous_knee)))
			return {}
		if foot.basis.get_rotation_quaternion().angle_to((pose.evaluated_basis.inverse()*pose.evaluated_ankles[side]).get_rotation_quaternion())>=deg_to_rad(18): return {}
		if side!=worker.tool_foot_side(): continue
		var toe := sk.get_bone_global_pose(pose._toes[side])
		var origin: Vector3 = sk.global_transform*toe.origin
		var basis: Basis = sk.global_basis*toe.basis
		if release:
			# Test the actual native body, not the prospective foot attachment.
			var tool: RigidBody3D = worker.equipped_tool
			basis = tool.global_basis
			origin = tool.global_position-basis.y*(.035+float(tool.definition.size.y)*.45)
			query.from = Vector3(origin.x,maxf(origin.y+.5,worker.global_position.y+.12),origin.z)
			query.to = origin-Vector3.UP*(worker._leg_lengths[side]+worker.ride_height+.35)
			surface = terrain.intersect_ray(query)
			if surface.is_empty() or surface.normal.y<=.6: return {}
		else:
			if origin.distance_to(worker.tool_grip_transform.origin+worker.ground_velocity*delta)>=WORLD_STEP: return {}
			if toe.basis.get_rotation_quaternion().angle_to((pose.evaluated_basis.inverse()*worker.tool_grip_transform.basis).get_rotation_quaternion())>=deg_to_rad(18):
				if allow_unobserved and "--tool-return-debug" in OS.get_cmdline_user_args(): print("RETURN_FRAME_REJECT toolturn ",rad_to_deg(toe.basis.get_rotation_quaternion().angle_to((pose.evaluated_basis.inverse()*worker.tool_grip_transform.basis).get_rotation_quaternion())))
				return {}
		if surface.is_empty():
			if not _native_tool_clear(worker,origin,basis): return {}
		elif not worker.held_tool_basis_clear(origin,basis,surface.position,surface.normal): return {}
		if not head_tool_native_clear(worker,origin,basis,surface,delta): return {}
		var plane: Dictionary = planes[side]
		accepted={"toe":toe,"sole":sole,"point":plane.point,"normal":plane.normal,"collider":plane.collider,"gap":plane.gap}
	accepted.planes = planes
	return accepted

static func head_tool_native_clear(worker: RigidBody3D, origin: Vector3, basis: Basis, surface: Dictionary, delta: float) -> bool:
	# The rare head-payload handoff must clear the original solid tool collider,
	# whose empty box corners can be wider than the reused visual mesh slices.
	# Fitting/contact and staged-source policies retain their existing guards.
	if not is_instance_valid(worker._cargo_source) or worker._cargo_source.carrier!=worker.head_anchor: return true
	var tool: RigidBody3D = worker.equipped_tool
	if not is_instance_valid(tool): return false
	var key: int = tool.get_instance_id()
	if not _head_tool_boxes.has(key):
		var shape: CollisionShape3D = tool.get_node_or_null("PhysicalShape")
		if not shape or not shape.shape is BoxShape3D: return false
		_head_tool_boxes[key]={"bounds":AABB(-shape.shape.size*.5,shape.shape.size),"transform":shape.transform}
	var cached: Dictionary = _head_tool_boxes[key]
	var local_shape: Transform3D = cached.transform
	var world: Transform3D = Transform3D(basis,origin+basis.y*(.035+float(tool.definition.size.y)*.45))*local_shape
	var native_root = worker.ragdoll.rig.bodies[0]
	var root_world: Transform3D = worker._skeleton.global_transform*worker._skeleton.get_bone_global_pose(native_root.bone)*native_root.b2b_inv
	if worker._tool_box_intersects(AABB(-native_root.shape.size*.5,native_root.shape.size),root_world.affine_inverse()*world,cached.bounds): return false
	if not surface.is_empty():
		var normal: Vector3 = surface.normal
		var half: Vector3 = cached.bounds.size*.5
		var radius: float = absf(normal.dot(world.basis.x))*half.x+absf(normal.dot(world.basis.y))*half.y+absf(normal.dot(world.basis.z))*half.z
		var velocity := Vector3.ZERO
		if surface.collider is RigidBody3D: velocity=surface.collider.linear_velocity+surface.collider.angular_velocity.cross(Vector3(surface.position)-surface.collider.global_position)
		var closing: float = maxf(0.0,normal.dot(velocity-worker.linear_velocity))*delta
		if normal.dot(world*cached.bounds.get_center()-surface.position)-radius<.005+closing: return false
	return true

static func _native_sole_clear(worker: RigidBody3D, sole: Vector3) -> bool:
	if not _sole_probe:
		_sole_probe=SphereShape3D.new()
		_sole_probe.radius=.001
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape=_sole_probe
	query.transform=Transform3D(Basis.IDENTITY,sole)
	query.collision_mask=0x7fffffff
	var exclusions: Array[RID] = worker.query_exclusions()
	exclusions.append(worker.equipped_tool.get_rid())
	query.exclude=exclusions
	return worker.get_world_3d().direct_space_state.intersect_shape(query,1).is_empty()

static func _native_tool_clear(worker: RigidBody3D, origin: Vector3, basis: Basis) -> bool:
	var frame: Dictionary = worker._tool_clearance_frame()
	frame.basis=basis
	frame.supported=false
	if not worker._tool_posture_clear(origin,basis.y,frame): return false
	var boxes: Array = frame.keepouts
	if boxes.is_empty(): return false
	var key: int = hash(boxes)
	if not _native_boxes.has(key):
		var shapes: Array[BoxShape3D] = []
		for bounds: AABB in boxes:
			var shape := BoxShape3D.new()
			shape.size=bounds.size
			shapes.append(shape)
		_native_boxes[key]=shapes
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask=0x7fffffff
	query.margin=.005
	var exclusions: Array[RID] = worker.query_exclusions()
	exclusions.append(worker.equipped_tool.get_rid())
	query.exclude=exclusions
	var world := Transform3D(basis,origin+basis.y*(.035+float(frame.length)*.45))
	for index in boxes.size():
		query.shape=_native_boxes[key][index]
		query.transform=world*Transform3D(Basis.IDENTITY,boxes[index].get_center())
		var hits := worker.get_world_3d().direct_space_state.intersect_shape(query,1)
		if not hits.is_empty():
			if "--tool-return-debug" in OS.get_cmdline_user_args(): print("RETURN_FRAME_REJECT native_tool box=",index," hit=",hits)
			return false
	return true

static func _native_release(worker: RigidBody3D, release_head := false) -> void:
	if release_head and is_instance_valid(worker.coordinator) and not worker.current_job_id.is_empty():
		var released := NativeRelease.release_for_yield(worker.coordinator.yard,worker,"Retained tool cannot recover here; released for recovery")
		if not released.has("reason"): return
		# This module is not activated by production. Preserve an honest native
		# failure in the isolated experiment if actual current geometry cannot
		# admit a clear handoff; it cannot qualify as a successful guarded yield.
		worker._pose._tool_return_native_failure=str(released.reason)
		print("CONTRAPTION_TOOL_RETURN_NATIVE_REFUSAL ",released)
	var tool: RigidBody3D = worker.equipped_tool
	var direct := PhysicsServer3D.body_get_direct_state(worker.get_rid())
	var velocity: Vector3 = direct.get_velocity_at_local_position(tool.global_position-worker.global_position)
	var angular: Vector3 = direct.angular_velocity
	# The same native body inherits its carrier motion. No assisted set-down,
	# new impulse, replacement stock or ground-position search is involved.
	tool.set_carried(null)
	tool.linear_velocity = velocity
	tool.angular_velocity = angular
	tool.remove_meta(&"equipped_worker")
	worker.set_equipped_tool(null)
	if release_head and is_instance_valid(worker._cargo_source) and worker._cargo_source.carrier==worker.head_anchor:
		var cargo: RigidBody3D = worker._cargo_source
		cargo.set_carried(null)
		cargo.linear_velocity=direct.get_velocity_at_local_position(cargo.global_position-worker.global_position)
		cargo.angular_velocity=angular
		cargo.set_meta(&"in_transit",false)
		worker.set_cargo(0.0)
		if is_instance_valid(worker.coordinator): worker.coordinator.yard.add_loose_part(cargo)
	if is_instance_valid(worker.coordinator): worker.coordinator.yard.add_loose_part(tool)
	worker.stop_navigation()
	worker.interrupt("Retained tool cannot recover here; released for recovery")
	# Existing cancellation will release its lease/unfinished job normally;
	# the tool is already native, so cancellation cannot relocate it.
	if is_instance_valid(worker.coordinator) and worker.coordinator.active_jobs.has(worker.current_job_id):
		worker.coordinator._cancel.call_deferred(worker.coordinator.active_jobs[worker.current_job_id],worker.status_text)

static func _turn(previous: Basis, desired: Basis, maximum: float) -> Basis:
	var from := previous.get_rotation_quaternion()
	var to := desired.get_rotation_quaternion()
	return Basis(from.slerp(to,minf(maximum/maxf(from.angle_to(to),.00001),1.0)))

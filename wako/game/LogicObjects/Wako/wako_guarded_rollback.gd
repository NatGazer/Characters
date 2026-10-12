extends RefCounted
## Unused prototype: a rejected solve may return only to a freshly valid frame.
## It never changes native motion, tool ownership, contact tolerances or reach.

static func capture(sk: Skeleton3D) -> Array[Dictionary]:
	var bones: Array[Dictionary] = []
	for bone in sk.get_bone_count():
		bones.append({"position":sk.get_bone_pose_position(bone),"rotation":sk.get_bone_pose_rotation(bone),"scale":sk.get_bone_pose_scale(bone)})
	return bones

static func restore(sk: Skeleton3D, bones: Array[Dictionary]) -> void:
	# Restore the original absolute-local TRS directly. A world→local matrix
	# round trip needlessly decomposes rotations on every rejected candidate.
	for bone in bones.size():
		sk.set_bone_pose_position(bone,bones[bone].position)
		sk.set_bone_pose_rotation(bone,bones[bone].rotation)
		sk.set_bone_pose_scale(bone,bones[bone].scale)

static func observe(pose: SkeletonModifier3D, sk: Skeleton3D, previous: Dictionary = {}, delta: float = 1.0/120.0) -> Dictionary:
	var worker: RigidBody3D = pose.worker
	if not worker.on_ground or not is_instance_valid(worker.equipped_tool): return {"accepted":false,"reason":"No current grounded tool frame"}
	var world := sk.global_transform
	var root: Transform3D = world*sk.get_bone_global_pose(0)
	var toe: Transform3D = world*sk.get_bone_global_pose(pose._toes[worker.tool_foot_side()])
	var query := PhysicsRayQueryParameters3D.new()
	query.collision_mask = 1
	query.exclude = worker.query_exclusions()
	var space := worker.get_world_3d().direct_space_state
	var soles: Array[Vector3] = []
	var knees: Array[Vector3] = []
	var ankles: Array[Basis] = []
	var world_ankles: Array[Basis] = []
	var columns: Array[Dictionary] = []
	var grounded: Array[bool] = []
	for side in 2:
		var chain: Array = pose._chains[side]
		var hip: Vector3 = world*sk.get_bone_global_pose(chain[0]).origin
		var knee: Vector3 = world*sk.get_bone_global_pose(chain[1]).origin
		var ankle: Transform3D = world*sk.get_bone_global_pose(chain[2])
		var sole: Vector3 = ankle*Vector3(0,pose._ankle_height[side],0)
		if not sole.is_finite() or hip.distance_to(ankle.origin)>worker._leg_lengths[side]+.002:
			return {"accepted":false,"reason":"Finite leg reach"}
		query.from=Vector3(sole.x,maxf(sole.y+.5,worker.global_position.y+.12),sole.z)
		query.to=sole-Vector3.UP*.65
		var column := space.intersect_ray(query)
		var plant_column := not column.is_empty()
		if column.is_empty() and (previous.is_empty() or not previous.grounded[side]):
			# An unplanted working leg may be above its own IK observation range.
			# Observe a lower floor for collision clearance only, just as the
			# existing free-tool path does. This cannot bind or extend a plant.
			query.to=sole-Vector3.UP*(worker.foot_tool_span()+.65)
			column=space.intersect_ray(query)
		if column.is_empty() or column.normal.y<=.6: return {"accepted":false,"reason":"Missing current sole column"}
		var gap: float = column.normal.dot(sole-column.position)
		if gap<-.001: return {"accepted":false,"reason":"Current sole below terrain"}
		if not previous.is_empty() and previous.grounded[side] and (gap>.035 or column.collider!=previous.columns[side].collider):
			return {"accepted":false,"reason":"Previous supporting sole lost its plant","side":side,"gap":gap,"sole":sole,"previous":previous.soles[side],"same_body":column.collider==previous.columns[side].collider}
		if not previous.is_empty():
			if sole.distance_to(previous.soles[side]+worker.ground_velocity*delta)>=.05:
				return {"accepted":false,"reason":"Actual sole continuity","side":side,"sole":sole,"previous":previous.soles[side],"step":sole.distance_to(previous.soles[side]+worker.ground_velocity*delta),"body":worker.global_position,"previous_body":previous.worker.origin,"planted":previous.grounded[side]}
			var direction: Vector3=(knee-hip).normalized()
			if (world.basis.inverse()*direction).angle_to(previous.knees[side])>=deg_to_rad(12):
				return {"accepted":false,"reason":"Actual knee continuity"}
			if (world.basis.inverse()*ankle.basis).get_rotation_quaternion().angle_to(previous.ankles[side].get_rotation_quaternion())>=deg_to_rad(18):
				return {"accepted":false,"reason":"Actual ankle continuity"}
		columns.append(column)
		soles.append(sole)
		knees.append((world.basis.inverse()*(knee-hip)).normalized())
		ankles.append(world.basis.inverse()*ankle.basis)
		world_ankles.append(ankle.basis)
		# Near-plane geometry alone cannot turn an authored swing into a plant.
		grounded.append(pose.evaluated_grounded[side] and plant_column and gap<=.035)
	var tool_side: int=worker.tool_foot_side()
	var plane: Dictionary=columns[tool_side]
	if not worker.held_tool_basis_clear(toe.origin,toe.basis,plane.position,plane.normal):
		return {"accepted":false,"reason":"Current complete tool/cube/floor guard"}
	# The original enabled native tool shape must also clear foreign solid bodies.
	# Own capsule/rig are replaced by the stricter current cube guard above.
	var tool: RigidBody3D=worker.equipped_tool
	var tool_world:=Transform3D(toe.basis,toe.origin+toe.basis.y*(.035+float(tool.definition.size.y)*.45))
	var material:=_staged_material(pose,tool_world,root)
	if not material.accepted: return material
	for collider: CollisionShape3D in tool.find_children("*","CollisionShape3D",true,false):
		if not collider.shape: continue
		var shape:=PhysicsShapeQueryParameters3D.new()
		shape.shape=collider.shape
		shape.transform=tool_world*tool.global_transform.affine_inverse()*collider.global_transform
		shape.collision_mask=0x7fffffff
		shape.exclude=worker.query_exclusions()
		shape.exclude.append(tool.get_rid())
		var contacts:=space.intersect_shape(shape,1)
		if not contacts.is_empty():
			return {"accepted":false,"reason":"Current native tool/foreign solid contact","foreign":str(contacts[0].collider.name),"foreign_world":contacts[0].collider.global_transform,"tool_world":tool_world,"shape_size":collider.shape.size if collider.shape is BoxShape3D else Vector3.ZERO,"shape_local":tool.global_transform.affine_inverse()*collider.global_transform,"sole":soles[tool_side],"floor":plane.position,"floor_body":str(plane.collider.name),"worker":worker.global_position}
	var local_root: Transform3D=worker.global_transform.affine_inverse()*root
	local_root.basis=world.basis.inverse()*root.basis
	if not previous.is_empty():
		if tool.get_instance_id()!=previous.tool_id: return {"accepted":false,"reason":"Actual tool identity changed"}
		if local_root.origin.distance_to(previous.local_root.origin)>=.025 or local_root.basis.get_rotation_quaternion().angle_to(previous.local_root.basis.get_rotation_quaternion())>=deg_to_rad(6):
			return {"accepted":false,"reason":"Actual cube continuity"}
		if toe.origin.distance_to(previous.toe.origin+worker.ground_velocity*delta)>=.05 or (world.basis.inverse()*toe.basis).get_rotation_quaternion().angle_to(previous.local_tool.get_rotation_quaternion())>=deg_to_rad(18):
			return {"accepted":false,"reason":"Actual complete tool continuity"}
	var world_bones: Array[Transform3D]=[]
	for bone in sk.get_bone_count(): world_bones.append(world*sk.get_bone_global_pose(bone))
	return {"accepted":true,"bones":world_bones,"worker":worker.global_transform,"basis":world.basis,
		"local_root":local_root,"toe":toe,"local_tool":world.basis.inverse()*toe.basis,
		"soles":soles,"knees":knees,"ankles":ankles,"world_ankles":world_ankles,"columns":columns,"grounded":grounded,"tool_id":tool.get_instance_id()}

static func rollback(pose: SkeletonModifier3D, sk: Skeleton3D, previous: Dictionary, delta: float = 1.0/120.0, recovering: bool = false) -> Dictionary:
	if previous.is_empty() or not previous.get("accepted",false):
		return {"accepted":false,"reason":"No previously guarded actual frame"}
	var incoming:=capture(sk)
	var requested: Array[Transform3D]=[]
	for bone in sk.get_bone_count(): requested.append(sk.global_transform*sk.get_bone_global_pose(bone))
	var reasons: Array[String]=[]
	for continuing: bool in [true,false] if recovering else [false]:
		restore(sk,incoming)
		var result:=_candidate(pose,sk,previous,delta,requested,continuing)
		if result.accepted: return result
		reasons.append(result.reason)
		restore(sk,incoming)
		if not continuing:
			result.attempts=reasons
			return result
	return {"accepted":false,"reason":"No currently guarded recovery candidate"}

static func _candidate(pose: SkeletonModifier3D, sk: Skeleton3D, previous: Dictionary, delta: float, requested: Array[Transform3D], continuing: bool) -> Dictionary:
	var worker: RigidBody3D=pose.worker
	# The root follows the actual visible heading at the CURRENT native origin.
	# Soles and tool remain world observations; moving the capsule is not a new
	# foot plant. Solve each old endpoint independently below, with finite IK.
	var transport: Basis=sk.global_basis*previous.basis.inverse()
	var rebase:=Transform3D(transport,worker.global_position-transport*previous.worker.origin)
	var inverse:=sk.global_transform.affine_inverse()
	for bone in sk.get_bone_count(): sk.set_bone_global_pose(bone,inverse*(rebase*previous.bones[bone]))
	if continuing:
		var root:=sk.global_transform*sk.get_bone_global_pose(0)
		var desired_local: Vector3=worker.global_transform.affine_inverse()*requested[0].origin
		root.origin=worker.global_transform*(previous.local_root.origin+(desired_local-previous.local_root.origin).limit_length(.012))
		root.basis=_turn_toward(root.basis,requested[0].basis,6.0*delta)
		sk.set_bone_global_pose(0,inverse*root)
	# Native vertical movement does not carry an existing world plant through
	# its support. Project that actual sole onto the SAME current native body,
	# using the unchanged finite leg. Validate the solved endpoint afterwards.
	var query:=PhysicsRayQueryParameters3D.new()
	query.collision_mask=1
	query.exclude=worker.query_exclusions()
	var space:=worker.get_world_3d().direct_space_state
	for side in 2:
		var chain: Array=pose._chains[side]
		var foot:=sk.get_bone_global_pose(chain[2])
		var offset:=Vector3(0,pose._ankle_height[side],0)
		var sole: Vector3=sk.global_transform*(foot*offset)
		var retained: Vector3=previous.soles[side]+worker.ground_velocity*delta
		if continuing: sole=requested[chain[2]]*offset
		sole=retained if previous.grounded[side] else retained+(sole-retained).limit_length(.035)
		query.from=Vector3(sole.x,maxf(sole.y+.5,worker.global_position.y+.12),sole.z)
		query.to=sole-Vector3.UP*.65
		var column:=space.intersect_ray(query)
		if column.is_empty() and not previous.grounded[side]:
			query.to=sole-Vector3.UP*(worker.foot_tool_span()+.65)
			column=space.intersect_ray(query)
		if column.is_empty() or column.normal.y<=.6 or previous.grounded[side] and column.collider!=previous.columns[side].collider:
			return {"accepted":false,"reason":"Previous supporting column changed"}
		var gap: float=column.normal.dot(sole-column.position)
		sole-=column.normal*(gap if previous.grounded[side] else minf(gap,0.0))
		var world_basis: Basis=previous.world_ankles[side]
		if continuing and not previous.grounded[side]: world_basis=_turn_toward(world_basis,requested[chain[2]].basis,6.0*delta)
		var basis: Basis=sk.global_basis.inverse()*world_basis
		pose._solve(sk,chain[0],chain[1],chain[2],inverse*sole-basis*offset,1.0,basis)
	var toe_index: int=pose._toes[worker.tool_foot_side()]
	var toe:=sk.get_bone_global_pose(toe_index)
	var tool_basis: Basis=previous.toe.basis
	if continuing: tool_basis=_turn_toward(tool_basis,requested[toe_index].basis,6.0*delta)
	toe.basis=sk.global_basis.inverse()*tool_basis
	sk.set_bone_global_pose(toe_index,toe)
	var result:=observe(pose,sk,previous,delta)
	if result.accepted: result.continuing=continuing
	return result

static func _turn_toward(from: Basis, toward: Basis, maximum: float) -> Basis:
	var a:=from.orthonormalized().get_rotation_quaternion()
	var b:=toward.orthonormalized().get_rotation_quaternion()
	return Basis(a.slerp(b,minf(maximum/maxf(a.angle_to(b),.00001),1.0)))

static func _staged_material(pose: SkeletonModifier3D, tool_world: Transform3D, cube_world: Transform3D) -> Dictionary:
	var worker: RigidBody3D=pose.worker
	if not is_instance_valid(worker.coordinator) or not worker.coordinator.active_jobs.has(worker.current_job_id): return {"accepted":true}
	var job: Dictionary=worker.coordinator.active_jobs[worker.current_job_id].job
	if not job.kind in ["build","replace"]: return {"accepted":true}
	var source: RigidBody3D=job.part
	if not is_instance_valid(source) or not source.has_meta(&"staged_target") or source.get_meta(&"staged_target")!=job.target or source.carrier!=job.target: return {"accepted":true}
	# A staged original stock body has layer zero, so a world overlap query
	# cannot observe it. Cache its immutable native material in body space,
	# then use the actual CURRENT source transform for every candidate.
	var key: Array=[source.get_instance_id(),source.parameters.hash()]
	var cache: Dictionary=pose.get_meta(&"guarded_staged_material",{})
	var cached: bool=cache.get("key",[])==key
	if cached:
		for material: Dictionary in cache.boxes:
			var collider: CollisionShape3D=material.collider.get_ref()
			if not is_instance_valid(collider) or collider.get_parent()!=source or not collider.shape is BoxShape3D or collider.shape.get_instance_id()!=material.shape_id or collider.shape.size!=material.bounds.size or collider.transform!=material.local:
				cached=false
				break
	if not cached:
		var boxes: Array[Dictionary]=[]
		for collider: CollisionShape3D in source.find_children("*","CollisionShape3D",true,false):
			if not collider.shape: continue
			if not collider.shape is BoxShape3D or collider.get_parent()!=source: return {"accepted":false,"reason":"Unobserved staged source material"}
			boxes.append({"bounds":AABB(-collider.shape.size*.5,collider.shape.size),"local":collider.transform,"collider":weakref(collider),"shape_id":collider.shape.get_instance_id()})
		if boxes.is_empty(): return {"accepted":false,"reason":"Missing staged source material"}
		cache={"key":key,"boxes":boxes}
		pose.set_meta(&"guarded_staged_material",cache)
	var length: float=worker.equipped_tool.definition.size.y
	var keepouts: Array=worker.equipped_tool.get_meta(&"worker_tool_keepouts",[])
	if keepouts.is_empty(): return {"accepted":false,"reason":"Missing complete tool material"}
	for material: Dictionary in cache.boxes:
		var inverse: Transform3D=(source.global_transform*material.local).affine_inverse()
		var bounds: AABB=material.bounds
		var tool_local:=inverse*tool_world
		if bounds.intersects_segment(tool_local*Vector3(0,-length*.5,0),tool_local*Vector3(0,length*.5,0))!=null:
			return {"accepted":false,"reason":"Current tool shaft/staged material contact"}
		for box: AABB in keepouts:
			if worker._tool_box_intersects(bounds,tool_local,box): return {"accepted":false,"reason":"Current complete tool/staged material contact"}
		if worker._tool_box_intersects(bounds,inverse*cube_world,AABB(Vector3(-.38,-.3,-.38),Vector3(.76,.68,.76)).grow(.025)):
			return {"accepted":false,"reason":"Current cube/staged material contact"}
	return {"accepted":true}

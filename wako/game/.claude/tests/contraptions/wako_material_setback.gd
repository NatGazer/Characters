extends RefCounted
## Isolated actual finite-leg trial. No production preload or native mutation.
const ToolMaterial := preload("res://.claude/tests/contraptions/covered_tool_material_observer.gd")
const LocalFrame := preload("res://LogicObjects/Wako/wako_guarded_rollback.gd")

static func apply(pose: SkeletonModifier3D, sk: Skeleton3D, material: RigidBody3D, bounds: AABB, equipment_clear: Callable, parent: RigidBody3D, parent_bounds: AABB) -> Dictionary:
	var worker: RigidBody3D=pose.worker
	var tool: RigidBody3D=worker.equipped_tool
	var side: int=worker.tool_foot_side()
	var chain: Array=pose._chains[side]
	var toe_index: int=pose._toes[side]
	var incoming: Array[Dictionary]=LocalFrame.capture(sk)
	var foot: Transform3D=sk.get_bone_global_pose(chain[2])
	var toe: Transform3D=sk.global_transform*sk.get_bone_global_pose(toe_index)
	var actual: Transform3D=tool_pose(tool,toe)
	var segment_lengths: Array[float]=[]
	for leg in 2:
		var leg_chain: Array=pose._chains[leg]
		for index in 2: segment_lengths.append(sk.get_bone_global_pose(leg_chain[index]).origin.distance_to(sk.get_bone_global_pose(leg_chain[index+1]).origin))
	var request: Dictionary=ToolMaterial.minimum_outward_setback(tool,material,bounds,.05,actual)
	if not request.found: return {"accepted":false,"reason":"Material envelope exceeds original 50 mm candidate","request":request}
	var distance: float=minf(.05,float(request.distance)+.00002) if float(request.distance)>0.0 else 0.0
	if distance>0.0:
		var offset: Vector3=request.outward*distance
		pose._solve(sk,chain[0],chain[1],chain[2],foot.origin+sk.global_basis.inverse()*offset,1.0,foot.basis)
		# Solving the parent changes the actual toe origin. Preserve the exact
		# selected whole-tool basis, then reread the realized finite endpoint.
		var solved_toe: Transform3D=sk.get_bone_global_pose(toe_index)
		solved_toe.basis=sk.global_basis.inverse()*toe.basis
		sk.set_bone_global_pose(toe_index,solved_toe)
	var accepted: Dictionary=observe(pose,sk,material,bounds,equipment_clear,parent,parent_bounds)
	accepted.requested_distance=distance
	accepted.original_tool=actual
	accepted.original_toe=toe
	if accepted.accepted:
		for leg in 2:
			var leg_chain: Array=pose._chains[leg]
			for index in 2:
				var realized_length: float=sk.get_bone_global_pose(leg_chain[index]).origin.distance_to(sk.get_bone_global_pose(leg_chain[index+1]).origin)
				if absf(realized_length-segment_lengths[leg*2+index])>.00001:
					accepted.accepted=false
					accepted.reason="Finite solve changes an original leg segment"
		var realized: Vector3=accepted.tool.origin-actual.origin
		accepted.realized_distance=realized.dot(request.outward)
		accepted.realization_error=realized.distance_to(request.outward*distance)
		if realized.length()>.050001 or accepted.realization_error>.0005 or accepted.tool.basis.x.distance_to(actual.basis.x)>.00001 or accepted.tool.basis.y.distance_to(actual.basis.y)>.00001 or accepted.tool.basis.z.distance_to(actual.basis.z)>.00001:
			accepted.accepted=false
			accepted.reason="Finite solve does not realize the bounded rigid setback"
	if not accepted.accepted:
		LocalFrame.restore(sk,incoming)
		accepted.restored=LocalFrame.capture(sk)==incoming
	return accepted

static func tool_pose(tool: RigidBody3D,toe: Transform3D) -> Transform3D:
	var basis: Basis=toe.basis.orthonormalized()
	return Transform3D(basis,toe.origin+basis.y*(.035+float(tool.definition.size.y)*.45))

static func observe(pose: SkeletonModifier3D,sk: Skeleton3D,material: RigidBody3D,bounds: AABB,equipment_clear: Callable,parent: RigidBody3D,parent_bounds: AABB) -> Dictionary:
	var worker: RigidBody3D=pose.worker
	var tool: RigidBody3D=worker.equipped_tool
	var side: int=worker.tool_foot_side()
	var toe: Transform3D=sk.global_transform*sk.get_bone_global_pose(pose._toes[side])
	var actual: Transform3D=tool_pose(tool,toe)
	var columns: Array[Dictionary]=[]
	var soles: Array[Vector3]=[]
	var knees: Array[Vector3]=[]
	var ankles: Array[Basis]=[]
	var terrain: PhysicsDirectSpaceState3D=worker.get_world_3d().direct_space_state
	for leg in 2:
		var chain: Array=pose._chains[leg]
		var foot: Transform3D=sk.get_bone_global_pose(chain[2])
		var hip: Vector3=sk.global_transform*sk.get_bone_global_pose(chain[0]).origin
		var knee: Vector3=sk.global_transform*sk.get_bone_global_pose(chain[1]).origin
		var ankle: Vector3=sk.global_transform*foot.origin
		var sole: Vector3=sk.global_transform*(foot*Vector3(0,pose._ankle_height[leg],0))
		var leg_length: float=worker._leg_lengths[leg]
		if hip.distance_to(ankle)>leg_length+.002: return {"accepted":false,"reason":"Original finite leg reach"}
		var start:=Vector3(sole.x,maxf(sole.y+.5,worker.global_position.y+.12),sole.z)
		var ray:=PhysicsRayQueryParameters3D.create(start,sole-Vector3.UP*.65,1,worker.query_exclusions())
		var column: Dictionary=terrain.intersect_ray(ray)
		var short_column: bool=not column.is_empty()
		if column.is_empty() and leg==side:
			# A lifted working ankle can be above the short own-sole probe.
			# Observe the lower plane for tool clearance only, never a plant.
			ray.to=sole-Vector3.UP*(worker.foot_tool_span()+.65)
			column=terrain.intersect_ray(ray)
		if column.is_empty() or column.normal.y<.6: return {"accepted":false,"reason":"Actual native sole column unavailable","side":leg,"sole":sole}
		var gap: float=column.normal.dot(sole-column.position)
		if gap<-.001: return {"accepted":false,"reason":"Actual sole below native column","side":leg,"gap":gap}
		if pose.evaluated_grounded[leg] and pose._support[leg].get_ref()!=column.collider: return {"accepted":false,"reason":"Previously planted sole changes native support body","side":leg}
		if leg!=side and worker.feet_work_active() and (not pose.evaluated_grounded[leg] or not worker.stance_valid): return {"accepted":false,"reason":"Original opposite work support not planted"}
		if leg!=side and worker.feet_work_active() and (not short_column or gap>.035): return {"accepted":false,"reason":"Opposite real work plant lost","gap":gap}
		column.short=short_column
		column.sole_gap=gap
		columns.append(column)
		soles.append(sole)
		knees.append((knee-hip).normalized())
		ankles.append(sk.global_basis*foot.basis)
	var tool_column: Dictionary=columns[side]
	if not worker.held_tool_basis_clear(toe.origin,toe.basis,tool_column.position,tool_column.normal): return {"accepted":false,"reason":"Actual complete tool/cube/floor guard","guard":worker.held_tool_clearance_debug(toe.origin,toe.basis,tool_column.position,tool_column.normal)}
	if not ToolMaterial._material_clear(tool,material,bounds,actual): return {"accepted":false,"reason":"Actual selected full-size material envelope"}
	if is_instance_valid(parent) and not ToolMaterial._material_clear(tool,parent,parent_bounds,actual): return {"accepted":false,"reason":"Actual original roof tie material"}
	var equipment: Dictionary=equipment_clear.call(worker,actual)
	if not equipment.is_empty(): return {"accepted":false,"reason":"Actual fixed equipment","hit":equipment}
	return {"accepted":true,"toe":toe,"tool":actual,"columns":columns,"soles":soles,"knees":knees,"ankles":ankles,
		"root":worker.global_transform.affine_inverse()*sk.global_transform*sk.get_bone_global_pose(0),"rig":sk.global_basis,"worker":worker.global_transform}

static func constrain_step(pose: SkeletonModifier3D,sk: Skeleton3D,previous: Dictionary,material: RigidBody3D,bounds: AABB,equipment_clear: Callable,parent: RigidBody3D,parent_bounds: AABB,setback: Dictionary={}) -> Dictionary:
	# Opt-in prototype. A bounded angular request can exceed the existing 50 mm
	# actual endpoint limit with a metre-long tool. Only a causally excessive
	# actual endpoint gets one small same-leg translation; no temporal filtering.
	var observed: Dictionary=observe(pose,sk,material,bounds,equipment_clear,parent,parent_bounds)
	if not observed.accepted or previous.is_empty(): return observed
	var worker: RigidBody3D=pose.worker
	var side: int=worker.tool_foot_side()
	var rebase: Transform3D=worker.global_transform*previous.body.affine_inverse()
	var previous_grip: Vector3=rebase*previous.grip.origin
	var previous_sole: Vector3=rebase*previous.soles[side]
	var grip_delta: Vector3=observed.toe.origin-previous_grip
	var sole_delta: Vector3=observed.soles[side]-previous_sole
	if grip_delta.length()<=.05 and sole_delta.length()<=.05: return observed
	# Keep the actually admitted material-normal coordinate. Shortening the full
	# vector can move a minimum-setback head back into the panel by a fraction of
	# a millimetre; the demonstrated excess is lateral to the actual box face.
	var delta: Vector3=grip_delta if grip_delta.length()>=sole_delta.length() else sole_delta
	var outward: Vector3=-material.global_basis.y.normalized()
	var normal_component: float=delta.dot(outward)
	if absf(normal_component)>=.049: return {"accepted":false,"reason":"Material-normal endpoint change cannot meet the original continuity bound"}
	var tangent: Vector3=delta-outward*normal_component
	var tangent_limit: float=sqrt(.049*.049-normal_component*normal_component)
	var correction: Vector3=tangent.limit_length(tangent_limit)-tangent
	if correction.length()>.05: return {"accepted":false,"reason":"Endpoint correction exceeds original 50 mm candidate","correction":correction}
	var incoming: Array[Dictionary]=LocalFrame.capture(sk)
	var chain: Array=pose._chains[side]
	var foot: Transform3D=sk.get_bone_global_pose(chain[2])
	var toe: Transform3D=sk.get_bone_global_pose(pose._toes[side])
	var lengths: Array[float]=[]
	for leg in 2:
		var leg_chain: Array=pose._chains[leg]
		for index in 2: lengths.append(sk.get_bone_global_pose(leg_chain[index]).origin.distance_to(sk.get_bone_global_pose(leg_chain[index+1]).origin))
	pose._solve(sk,chain[0],chain[1],chain[2],foot.origin+sk.global_basis.inverse()*correction,1.0,foot.basis)
	var solved_toe: Transform3D=sk.get_bone_global_pose(pose._toes[side])
	solved_toe.basis=toe.basis
	sk.set_bone_global_pose(pose._toes[side],solved_toe)
	var constrained: Dictionary=observe(pose,sk,material,bounds,equipment_clear,parent,parent_bounds)
	if constrained.accepted:
		for leg in 2:
			var leg_chain: Array=pose._chains[leg]
			for index in 2:
				if absf(sk.get_bone_global_pose(leg_chain[index]).origin.distance_to(sk.get_bone_global_pose(leg_chain[index+1]).origin)-lengths[leg*2+index])>.00001:
					constrained.accepted=false
					constrained.reason="Endpoint correction changes an original finite leg segment"
		if constrained.toe.origin.distance_to(previous_grip)>.05 or constrained.soles[side].distance_to(previous_sole)>.05:
			constrained.accepted=false
			constrained.reason="Realized finite endpoint still exceeds original 50 mm continuity"
		elif not setback.is_empty() and (constrained.toe.origin.distance_to(setback.original_toe.origin)>.050001 or constrained.tool.origin.distance_to(setback.original_tool.origin)>.050001):
			constrained.accepted=false
			constrained.reason="Combined material and endpoint correction exceeds original 50 mm candidate"
		elif constrained.toe.basis.x.distance_to(observed.toe.basis.x)>.00001 or constrained.toe.basis.y.distance_to(observed.toe.basis.y)>.00001 or constrained.toe.basis.z.distance_to(observed.toe.basis.z)>.00001:
			constrained.accepted=false
			constrained.reason="Endpoint correction changes selected whole-tool basis"
		elif (constrained.toe.origin-observed.toe.origin).distance_to(correction)>.0005:
			constrained.accepted=false
			constrained.reason="Finite endpoint correction is not realized within the original solve tolerance"
		if constrained.accepted:
			constrained.endpoint_corrected=true
			constrained.endpoint_correction=correction
			constrained.endpoint_error=(constrained.toe.origin-observed.toe.origin).distance_to(correction)
	if not constrained.accepted:
		LocalFrame.restore(sk,incoming)
		constrained.restored=LocalFrame.capture(sk)==incoming
	return constrained

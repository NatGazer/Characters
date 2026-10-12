extends RefCounted
## One full-size reusable tool on a container's secured rear clip. The tool is
## still the original finite-mass cargo body, not equipment granted by a job.

static func has_space(tool: Node3D, bay: Node3D, stock: Array) -> bool:
	for other: Node3D in stock:
		if not is_instance_valid(other) or other == tool or other.is_queued_for_deletion() or other.get_parent() != bay: continue
		if other.get_meta(&"stored", false) and other.definition.get("category", "") == "tool": return false
	return true

static func store(tool: Node3D, bay: Node3D) -> void:
	tool.scale = Vector3.ONE
	tool.transform = Transform3D(Basis(Vector3.FORWARD, -PI * .5), Vector3(0, -.035, float(bay.definition.size.z) * .5 + .12))
	tool.set_meta(&"stored_tool_rack", true)

static func pickup_point(tool: Node3D) -> Vector3:
	return tool.global_transform * Vector3(0, -float(tool.definition.size.y) * .45, 0)

static func motion_reason(tool: Node3D) -> String:
	var bay := tool.get_parent() as RigidBody3D
	if not bay: return ""
	return rack_motion_reason(bay, pickup_point(tool))

static func rack_motion_reason(bay: RigidBody3D, point: Vector3) -> String:
	# Fitting captures a supported stock pose for the entire contact clip. Stop
	# the rack itself, including rotation about its native centre of mass.
	var direct := PhysicsServer3D.body_get_direct_state(bay.get_rid())
	var speed := bay.linear_velocity.length()
	if direct: speed = direct.get_velocity_at_local_position(point - bay.global_position).length()
	if speed > .25 or bay.angular_velocity.length() > .1:
		return "Stop the mobile tool rack before fitting a work tool"
	if bay.health <= 0.0 or not bay.installed:
		return "Secure a working container before fetching its clipped tool"
	return ""

static func fetch_stance(worker: RigidBody3D, tool: Node3D, route_admission: Callable=Callable(), preferred: Dictionary={}) -> Dictionary:
	if depot_tool(worker,tool): return _depot_fetch_stance(worker,tool,route_admission,preferred)
	var bay := tool.get_parent() as RigidBody3D
	if not bay or not tool.get_meta(&"stored_tool_rack", false): return {}
	if not motion_reason(tool).is_empty(): return {}
	var grip := pickup_point(tool)
	var exclude: Array[RID] = worker.query_exclusions()
	exclude.append(tool.get_rid())
	if is_instance_valid(worker.coordinator):
		for other: RigidBody3D in worker.coordinator.workers:
			if other != worker: exclude.append(other.get_rid())
	var space := worker.get_world_3d().direct_space_state
	var side: int = worker.tool_foot_side()
	var heading := bay.global_basis.z.slide(Vector3.UP)
	if heading.length_squared() < .0001: return {}
	var facing := Basis.looking_at(-heading.normalized(), Vector3.UP)
	# Fitting's planted counterlean needs some native leg reach in reserve. The
	# whole-tool solver and actual contact still validate the completed pose.
	for gap: float in [.35, .45, .6, .75]:
		for lateral: float in [0.0, -.2, .2]:
			var at: Vector3 = grip + bay.global_basis.z * gap + bay.global_basis.x * lateral - facing * worker._hip_rest_offsets[side]
			var query := PhysicsRayQueryParameters3D.create(at + Vector3.UP * .6, at - Vector3.UP * 2, 1, exclude)
			var hit := space.intersect_ray(query)
			if hit.is_empty() or hit.normal.y < .8: continue
			if hit.collider.get("assembly") != bay.assembly and hit.collider.get("assembly") != null: continue
			at.y = hit.position.y
			var hip: Vector3 = at + Vector3.UP * worker.ride_height + facing * worker._hip_rest_offsets[side]
			if hip.distance_to(grip) > worker._leg_span(side) + .05: continue
			var clearance := PhysicsShapeQueryParameters3D.new()
			clearance.shape = worker.get_node("Collision").shape
			clearance.transform = Transform3D(Basis.IDENTITY, at + Vector3.UP * worker.ride_height) * worker.get_node("Collision").transform
			clearance.collision_mask = 1
			clearance.exclude = exclude
			if not space.intersect_shape(clearance, 1).is_empty(): continue
			return {"point": at, "support": hit.collider}
	return {}

static func depot_tool(worker: RigidBody3D, tool: Node3D) -> bool:
	return is_instance_valid(worker.coordinator) and is_instance_valid(worker.coordinator.yard.storage) \
		and tool.get_parent()==worker.coordinator.yard.storage and tool.get_meta(&"stored",false) \
		and tool.definition.get("category","")=="tool"

static func _depot_fetch_stance(worker: RigidBody3D, tool: Node3D, route_admission: Callable, preferred: Dictionary) -> Dictionary:
	# The original flat tool's grip lies near its handle end, not its centre.
	# Admit the chosen foot from real clear floor beside that grip. An adjacent
	# stock body may not become the opposite supporting sole's fitting platform.
	var grip := pickup_point(tool)
	var heading := -tool.global_basis.y.slide(Vector3.UP)
	if heading.length_squared()<.0001: return {}
	heading=heading.normalized()
	var exclude: Array[RID]=worker.query_exclusions()
	for other: RigidBody3D in worker.coordinator.workers:
		if other!=worker: exclude.append(other.get_rid())
	var space := worker.get_world_3d().direct_space_state
	var side: int=worker.tool_foot_side()
	var collider: CollisionShape3D=worker.get_node("Collision")
	var query := PhysicsRayQueryParameters3D.new()
	query.collision_mask=1
	query.exclude=exclude
	var clearance := PhysicsShapeQueryParameters3D.new()
	clearance.shape=collider.shape
	clearance.collision_mask=1
	clearance.exclude=exclude
	var candidates: Array[Vector3]=[]
	# Keep the admitted endpoint while walking. It still passes exactly the
	# same stopped capsule, grip, opposite sole and fresh native route checks.
	if not preferred.is_empty() and is_instance_valid(preferred.get("support")):
		candidates.append(preferred.point)
	for gap: float in [.35,.45,.6,.75]:
		for angle: float in [0.0,PI*.5,-PI*.5,PI,PI*.25,-PI*.25,PI*.75,-PI*.75]:
			var outward := heading.rotated(Vector3.UP,angle)
			var facing := Basis.looking_at(-outward,Vector3.UP)
			candidates.append(grip+outward*gap-facing*worker._hip_rest_offsets[side])
	for proposed: Vector3 in candidates:
		var at:=proposed
		query.from=at+Vector3.UP*(worker.ride_height+.12)
		query.to=at-Vector3.UP*2.0
		var hit := space.intersect_ray(query)
		if hit.is_empty() or hit.normal.y<.8 or hit.collider.get_meta(&"stored",false) or hit.collider.get("assembly")!=null: continue
		if hit.collider is RigidBody3D and (hit.collider.linear_velocity.length()>.25 or hit.collider.angular_velocity.length()>.1): continue
		at.y=hit.position.y
		# Finish at the actual grip heading that face_point will request.
		var facing:=Basis.looking_at((grip-at).slide(Vector3.UP).normalized(),Vector3.UP)
		var hip: Vector3=at+Vector3.UP*worker.ride_height+facing*worker._hip_rest_offsets[side]
		if hip.distance_to(grip)>worker._leg_span(side)+.05: continue
		var heel: Vector3=at+facing*Vector3(worker._hip_rest_offsets[1-side].x,0,0)
		var planted:=true
		for front: float in [-.16,0.0,.1]:
			var sole: Vector3=heel-facing.z*front
			query.from=sole+Vector3.UP*(worker.ride_height+.12)
			query.to=sole-Vector3.UP*.3
			var sole_hit := space.intersect_ray(query)
			if sole_hit.is_empty() or sole_hit.normal.y<.8 or sole_hit.collider!=hit.collider \
				or absf(hit.normal.dot(sole_hit.position-hit.position))>.025:
				planted=false
				break
		if not planted: continue
		clearance.transform=Transform3D(Basis.IDENTITY,at+Vector3.UP*worker.ride_height)*collider.transform
		if not space.intersect_shape(clearance,1).is_empty(): continue
		# A clear endpoint is useful only if the current native approach can
		# reach it. Reject this candidate rather than wait at a refused path.
		if route_admission.is_valid() and not route_admission.call(at,hit.collider): continue
		return {"point":at,"support":hit.collider}
	return {}

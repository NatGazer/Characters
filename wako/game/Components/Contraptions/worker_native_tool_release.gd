extends RefCounted
## Physical release primitive for isolated complete-pose recovery trials.
## Idle release leaves leases alone. Active yield detaches the actual payloads
## before synchronous ordinary cancellation; it never chooses a set-down pose.
## Production job recovery is intentionally not wired to this module.

static func observe(yard: Node3D, worker: RigidBody3D) -> Dictionary:
	if not is_instance_valid(yard) or not yard.is_inside_tree() or not is_instance_valid(worker) \
		or not worker.is_inside_tree() or worker.is_queued_for_deletion() or not yard.workers.has(worker):
		return {"reason":"The original tool owner is no longer present"}
	var tool: RigidBody3D = worker.equipped_tool
	if not is_instance_valid(tool) or tool.is_queued_for_deletion() or not tool.is_inside_tree() \
		or not yard.loose_parts.has(tool) or tool.definition.get("category","")!="tool" \
		or tool.carrier!=worker.tool_anchor or str(tool.get_meta(&"equipped_worker",""))!=worker.worker_id \
		or tool.get_meta(&"stored",false) or tool.get_meta(&"awaiting_setdown",false):
		return {"reason":"The exact equipped native tool is unavailable"}
	var job_id: String = worker.current_job_id
	if not job_id.is_empty():
		var coordinator: Node = yard.coordinator
		var entry: Dictionary = coordinator.active_jobs.get(job_id,{})
		var reservation: Dictionary = yard._reservations.get(job_id,{})
		if coordinator.is_physics_processing() or entry.is_empty() or not entry.crew.has(worker) \
			or entry.job.get("tool")!=tool or reservation.get("tool_instance",0)!=tool.get_instance_id() \
			or not entry.crew.all(func(member: Node) -> bool: return is_instance_valid(member) and member.work_action_held):
			return {"reason":"Suspend the exact reserved-tool lease before an isolated release trial"}
	var pose: Transform3D = tool.global_transform
	if not pose.is_finite(): return {"reason":"The native tool transform is invalid"}
	var query := PhysicsShapeQueryParameters3D.new()
	# Observe every live solid layer, including helper capsules (4) and
	# activated native rigs (256), before detaching the actual collider.
	query.collision_mask = 0x7fffffff
	query.exclude = [tool.get_rid()]
	query.margin = 0.0
	var shape_count := 0
	for shape: Node in tool.get_children():
		if not shape is CollisionShape3D or shape.disabled or not shape.shape: continue
		shape_count += 1
		query.shape = shape.shape
		query.transform = pose*shape.transform
		var hits := tool.get_world_3d().direct_space_state.intersect_shape(query,1)
		if not hits.is_empty():
			return {"reason":"The actual native tool collider is obstructed at its current pose","collider":hits[0].collider}
	if shape_count==0: return {"reason":"The tool has no original native collision shape"}
	var direct := PhysicsServer3D.body_get_direct_state(worker.get_rid())
	var velocity: Vector3 = direct.get_velocity_at_local_position(pose.origin-worker.global_position) if direct \
		else worker.linear_velocity+worker.angular_velocity.cross(pose.origin-worker.global_position)
	var angular: Vector3 = direct.angular_velocity if direct else worker.angular_velocity
	if not velocity.is_finite() or not angular.is_finite(): return {"reason":"The inherited native motion is invalid"}
	return {"tool":tool,"transform":pose,"velocity":velocity,"angular_velocity":angular,"job":job_id}

static func release(yard: Node3D, worker: RigidBody3D, reason: String) -> Dictionary:
	var observation := observe(yard,worker)
	if observation.has("reason"): return observation
	var tool: RigidBody3D = observation.tool
	worker.set_equipped_tool(null)
	tool.remove_meta(&"equipped_worker")
	tool.set_carried(null)
	yard.add_loose_part(tool)
	# set_carried and reparenting must not replace the last actual attachment
	# endpoint with a ground search, a toe goal or a newly evaluated pose.
	tool.global_transform = observation.transform
	tool.linear_velocity = observation.velocity
	tool.angular_velocity = observation.angular_velocity
	tool.sleeping = false
	worker.stop_navigation()
	worker.needs = reason
	worker.status_text = reason
	observation.released = true
	return observation

static func observe_yield(yard: Node3D, worker: RigidBody3D) -> Dictionary:
	# Unused active-lease trial API. It observes the current native payloads,
	# never a prospective toe endpoint or a reconstructed stock placement.
	if not is_instance_valid(yard) or not yard.is_inside_tree() or not is_instance_valid(worker) \
		or not worker.is_inside_tree() or worker.is_queued_for_deletion() or not yard.workers.has(worker) \
		or not worker.ragdoll or worker.ragdoll.is_down():
		return {"reason":"The original live carrier cannot enter native yield"}
	var coordinator: Node=yard.coordinator
	var id: String=worker.current_job_id
	if not is_instance_valid(coordinator) or id.is_empty(): return {"reason":"Native yield trial requires an actual active lease"}
	var entry: Dictionary=coordinator.active_jobs.get(id,{})
	var reservation: Dictionary=yard._reservations.get(id,{})
	if entry.is_empty() or reservation.is_empty() or entry.job.id!=id or entry.crew.is_empty() or entry.crew[0]!=worker:
		return {"reason":"The exact original carrier lease is unavailable"}
	var crew: Array=entry.crew
	var reserved_workers: Array=reservation.get("workers",[])
	if crew.size()!=reserved_workers.size() or crew.any(func(member: Node)->bool:
		return not is_instance_valid(member) or not member.is_inside_tree() or member.is_queued_for_deletion() \
			or not yard.workers.has(member) or not member.is_available() or member.current_job_id!=id \
			or reserved_workers.count(member.get_instance_id())!=1):
		return {"reason":"The original reserved crew changed"}
	var source: RigidBody3D=entry.job.get("part")
	var tool: RigidBody3D=worker.equipped_tool
	var target: Node3D=entry.job.get("target")
	if not is_instance_valid(source) or not source.is_inside_tree() or source.is_queued_for_deletion() \
		or not is_instance_valid(target) or not target.is_inside_tree() or target.is_queued_for_deletion() \
		or reservation.get("part_instance",0)!=source.get_instance_id() or reservation.get("part_id","")!=source.part_id \
		or not is_instance_valid(tool) or not tool.is_inside_tree() or tool.is_queued_for_deletion() \
		or entry.job.get("tool")!=tool or reservation.get("tool_instance",0)!=tool.get_instance_id() \
		or yard.loose_parts.count(tool)!=1 or tool.carrier!=worker.tool_anchor \
		or str(tool.get_meta(&"equipped_worker",""))!=worker.worker_id or tool.get_meta(&"stored",false) \
		or tool.get_meta(&"awaiting_setdown",false) or tool.definition.get("category","")!="tool":
		return {"reason":"The exact native source/tool reservation changed"}
	var head_held: bool=source.carrier==worker.head_anchor
	if head_held:
		if entry.job.kind not in ["build","replace","salvage"] \
			or entry.phase not in ["carry_exit","carry_outside","carry","boarding_approach","boarding"] \
			or not entry.get("pickup",false) or worker._cargo_source!=source or not worker.carrying \
			or not source.get_meta(&"in_transit",false) or source.get_meta(&"stored",false) \
			or source.get_meta(&"awaiting_setdown",false) or yard.loose_parts.count(source)!=1:
			return {"reason":"The source is not the exact reserved head-held carry"}
		var carried_mass:=0.0
		for member: Node in crew: carried_mass+=member.cargo_mass
		if not is_equal_approx(carried_mass,source.mass): return {"reason":"The cooperative payload mass no longer matches its original source"}
	else:
		if crew.any(func(member: Node)->bool:return member.carrying or member.cargo_mass>0.0):
			return {"reason":"An unrelated head payload would survive the native fall"}
		if entry.phase not in ["inspect","work"]: return {"reason":"Tool-only yield requires actual staged or installed work"}
		var staged_target: Variant=source.get_meta(&"staged_target") if source.has_meta(&"staged_target") else null
		var staged: bool=entry.job.kind in ["build","replace"] and entry.get("staged",false) \
			and staged_target==target and source.carrier==target and source.get_meta(&"in_transit",false) \
			and yard.loose_parts.count(source)==1
		var installed: bool=entry.job.kind in ["join","repair","unbend","dismantle","maintenance"] \
			and source.installed and source.carrier==null and not source.get_meta(&"in_transit",false) \
			and is_instance_valid(source.assembly) and yard.assemblies.has(source.assembly) \
			and source.assembly.parts.get(source.part_id)==source
		if not staged and not installed: return {"reason":"The headless work source has no exact staged/native owner"}
	var direct:=PhysicsServer3D.body_get_direct_state(worker.get_rid())
	if not direct: return {"reason":"Native carrier point motion is unavailable"}
	var payloads: Array[Dictionary]=[]
	for body: RigidBody3D in [tool,source] if head_held else [tool]:
		var captured:=_observe_payload(body,worker,direct)
		if captured.has("reason"): return captured
		payloads.append(captured)
	return {"worker":worker,"entry":entry,"job":id,"crew":crew,"tool":tool,"source":source,
		"source_transform":source.global_transform,"head_released":head_held,"payloads":payloads}

static func _observe_payload(body: RigidBody3D, worker: RigidBody3D, direct: PhysicsDirectBodyState3D) -> Dictionary:
	var pose: Transform3D=body.global_transform
	var velocity: Vector3=direct.get_velocity_at_local_position(pose.origin-worker.global_position)
	var angular: Vector3=direct.angular_velocity
	if not pose.is_finite() or not velocity.is_finite() or not angular.is_finite():
		return {"reason":"The actual native payload pose/motion is invalid"}
	var query:=PhysicsShapeQueryParameters3D.new()
	query.collision_mask=0x7fffffff
	# The payload's own RID is not an obstacle. Only the one capsule which the
	# native fall retires is exempt; partners, other helpers and rigs remain live.
	query.exclude=[body.get_rid(),worker.get_rid()]
	query.margin=0.0
	var shapes:=0
	for collider: CollisionShape3D in body.find_children("*","CollisionShape3D",true,false):
		if collider.disabled or not collider.shape: continue
		shapes+=1
		query.shape=collider.shape
		query.transform=collider.global_transform
		if not query.transform.is_finite(): return {"reason":"An original payload collider has an invalid transform"}
		var hits:=body.get_world_3d().direct_space_state.intersect_shape(query,1)
		if not hits.is_empty(): return {"reason":"The actual native payload collider is obstructed","body":body,"collider":hits[0].collider}
	if shapes==0: return {"reason":"The payload has no enabled original native shape"}
	return {"body":body,"transform":pose,"velocity":velocity,"angular_velocity":angular,"shapes":shapes}

static func release_for_yield(yard: Node3D, worker: RigidBody3D, reason: String) -> Dictionary:
	var observation:=observe_yield(yard,worker)
	if observation.has("reason"): return observation
	# No callback or navigation may run between the snapshot and cancellation.
	# Native physics remains active; the fall itself belongs to the caller.
	for member: Node in observation.crew:
		member.set_work_action_held(true)
		member.stop_navigation()
	for payload: Dictionary in observation.payloads:
		var body: RigidBody3D=payload.body
		body.set_carried(null)
		body.global_transform=payload.transform
		body.linear_velocity=payload.velocity
		body.angular_velocity=payload.angular_velocity
		body.sleeping=false
		yard.add_loose_part(body)
	var tool: RigidBody3D=observation.tool
	tool.remove_meta(&"equipped_worker")
	if observation.head_released: observation.source.set_meta(&"in_transit",false)
	for member: Node in observation.crew: member.set_cargo(0.0)
	worker.set_equipped_tool(null)
	# Head-held stock is already native/in_transit=false, so ordinary cancellation
	# cannot relocate it. Staged stock intentionally follows its existing safe
	# fixture return; this branch makes no head-fall or source-pose claim.
	yard.coordinator.interrupt_worker(worker,reason)
	for member: Node in observation.crew: member.set_work_action_held(false)
	observation.released=true
	return observation

extends RefCounted
## Launch access for original compact depot and loose ground stock. Queries never move a body,
## change custody or start HeadLeap; the coordinator still walks and settles.
const Depot := preload("res://Components/Contraptions/depot_stock_layout.gd")
static var _launch_probe_counts: Dictionary={}

static func depot_head_source(worker: RigidBody3D, source: Node3D) -> bool:
	return is_instance_valid(worker.coordinator) and source.get_parent()==worker.coordinator.yard.storage \
		and source.get_meta(&"stored",false) and source.definition.get("category","")!="tool" \
		and Depot.aisle(source,source.get_parent(),false).is_empty()

static func loose_head_source(worker: RigidBody3D, source: Node3D) -> bool:
	return is_instance_valid(worker.coordinator) and worker.coordinator.yard.loose_parts.has(source) \
		and not source.get_meta(&"stored",false) and not source.get_meta(&"in_transit",false) \
		and not is_instance_valid(source.get("carrier")) and source.get("assembly")==null \
		and source.definition.get("category","")!="tool"

static func head_launch_stance(worker: RigidBody3D, source: RigidBody3D, route_admission: Callable, preferred: Dictionary={}) -> Dictionary:
	var probe_key:=_launch_probe_key(worker,source)
	var probing:=not probe_key.is_empty()
	var facts: Array[Dictionary]=[]
	if not (depot_head_source(worker,source) or loose_head_source(worker,source)) or not worker._pose.evaluated_valid:
		if probing: _launch_probe_emit(worker,source,probe_key,facts,"source access or evaluated pose unavailable")
		return {}
	var bounds: AABB=source.global_transform*Depot.bounds(source)
	if not bounds.position.is_finite() or not bounds.size.is_finite() or bounds.size.length_squared()<.0001:
		if probing: _launch_probe_emit(worker,source,probe_key,facts,"nonfinite or empty original bounds")
		return {}
	var candidates: Array[Vector3]=[]
	if not preferred.is_empty() and is_instance_valid(preferred.get("support")): candidates.append(preferred.point)
	# Twelve fixed near-face proposals replace the old distant entrance. These
	# small gaps stay well inside the unchanged six-metre HeadLeap limit.
	for gap: float in [1.0,1.35,1.7]:
		var centre:=bounds.get_center()
		var faces: Array[Vector3]=[Vector3(bounds.position.x-gap,centre.y,centre.z),Vector3(bounds.end.x+gap,centre.y,centre.z),
			Vector3(centre.x,centre.y,bounds.position.z-gap),Vector3(centre.x,centre.y,bounds.end.z+gap)]
		faces.sort_custom(func(a:Vector3,b:Vector3)->bool:return worker._ground_point.distance_squared_to(a)<worker._ground_point.distance_squared_to(b))
		candidates.append_array(faces)
	var exclude: Array[RID]=worker.query_exclusions()
	for other: RigidBody3D in worker.coordinator.workers:
		if other!=worker: exclude.append(other.get_rid())
	var space:=worker.get_world_3d().direct_space_state
	var ray:=PhysicsRayQueryParameters3D.new()
	ray.collision_mask=1
	ray.exclude=exclude
	var collider: CollisionShape3D=worker.get_node("Collision")
	var clearance:=PhysicsShapeQueryParameters3D.new()
	clearance.collision_mask=1
	clearance.exclude=exclude
	var head:=BoxShape3D.new()
	head.size=Vector3(.80,.70,.80)
	var limb:=SphereShape3D.new()
	limb.radius=.085
	var box:=BoxShape3D.new()
	var observed_root: Transform3D=worker.global_transform*worker._pose.evaluated_worker.affine_inverse()*worker._pose.evaluated_root
	var rebase: Transform3D=worker.global_transform*worker._pose.evaluated_worker.affine_inverse()
	var inverse: Transform3D=worker._model.global_transform.affine_inverse()
	var model_root: Transform3D=inverse*observed_root
	var legs: Array[Vector3]=[]
	for side in 2:
		legs.append(inverse*(rebase*worker._pose.evaluated_hips[side]))
		legs.append(inverse*(rebase*worker._pose.evaluated_knees[side]))
		var ankle: Vector3=worker._pose.evaluated_soles[side]-worker._pose.evaluated_ankles[side]*Vector3(0,worker._pose._ankle_height[side],0)
		legs.append(inverse*(rebase*ankle))
	for proposed: Vector3 in candidates:
		var fact: Dictionary={"proposal":source.encode_vector(proposed)} if probing else {}
		var at:=proposed
		ray.from=at+Vector3.UP*(worker.ride_height+.12)
		ray.to=at-Vector3.UP*2.0
		var hit:=space.intersect_ray(ray)
		# Real ground only: adjacent stored stock is neither a walking deck nor
		# a planted launch sole. Moving native support remains inadmissible.
		if hit.is_empty() or hit.normal.y<.8 or hit.collider.get_meta(&"stored",false) or hit.collider.get("assembly")!=null:
			if probing: _launch_probe_reject(source,facts,fact,"launch floor unavailable, steep, stored or installed",hit)
			continue
		if hit.collider is RigidBody3D and (hit.collider.linear_velocity.length()>.25 or hit.collider.angular_velocity.length()>.1):
			if probing: _launch_probe_reject(source,facts,fact,"moving launch support",hit)
			continue
		at.y=hit.position.y
		if probing:
			fact["point"]=source.encode_vector(at)
			fact["support"]=_launch_probe_hit(source,hit)
			fact["source_distance"]=at.distance_to(source.global_position)
		var heading: Vector3=(source.global_position-at).slide(Vector3.UP)
		if heading.length_squared()<.0001:
			if probing: _launch_probe_reject(source,facts,fact,"degenerate source heading")
			continue
		var facing:=Basis.looking_at(heading.normalized(),Vector3.UP)
		var planted:=true
		for side in 2:
			for front: float in [-.16,0.0,.1]:
				var sole: Vector3=at+facing*Vector3(worker._hip_rest_offsets[side].x,0,-front)
				ray.from=sole+Vector3.UP*(worker.ride_height+.12)
				ray.to=sole-Vector3.UP*.3
				var sole_hit:=space.intersect_ray(ray)
				if sole_hit.is_empty() or sole_hit.normal.y<.8 or sole_hit.collider!=hit.collider \
					or absf(hit.normal.dot(sole_hit.position-hit.position))>.025:
					if probing: _launch_probe_reject(source,facts,fact,"sole floor admission",sole_hit,null,
						{"side":side,"front":front,"sole":source.encode_vector(sole),
						"same_support":not sole_hit.is_empty() and sole_hit.collider==hit.collider,
						"support_plane_error":absf(hit.normal.dot(sole_hit.position-hit.position)) if not sole_hit.is_empty() else null})
					planted=false
					break
			if not planted: break
		if not planted: continue
		clearance.shape=collider.shape
		clearance.transform=Transform3D(Basis.IDENTITY,at+Vector3.UP*worker.ride_height)*collider.transform
		var capsule_hits: Array=space.intersect_shape(clearance,1)
		if not capsule_hits.is_empty():
			if probing: _launch_probe_reject(source,facts,fact,"native upright capsule",capsule_hits[0],clearance)
			continue
		var cube: Transform3D=Transform3D(facing,at)*model_root
		clearance.shape=head
		clearance.transform=cube
		var head_hits: Array=space.intersect_shape(clearance,1)
		if not head_hits.is_empty():
			if probing: _launch_probe_reject(source,facts,fact,"evaluated head box",head_hits[0],clearance,
				{"head_size":source.encode_vector(head.size)})
			continue
		var clear:=true
		clearance.shape=limb
		var model: Transform3D=Transform3D(facing,at)
		for side in 2:
			for link in 2:
				for fraction: float in [.0,.25,.5,.75,1.0]:
					clearance.transform=Transform3D(Basis.IDENTITY,model*(legs[side*3+link].lerp(legs[side*3+link+1],fraction)))
					var limb_hits: Array=space.intersect_shape(clearance,1)
					if not limb_hits.is_empty():
						if probing: _launch_probe_reject(source,facts,fact,"current evaluated leg sphere",limb_hits[0],clearance,
							{"side":side,"link":link,"fraction":fraction,"radius":limb.radius,
							"same_support":limb_hits[0].collider==hit.collider,
							"support_plane_gap":hit.normal.dot(clearance.transform.origin-hit.position)-limb.radius-clearance.margin})
						clear=false
						break
				if not clear: break
			if not clear: break
		if not clear: continue
		var volumes: Array[Dictionary]=[]
		if worker.back_tool:
			var holder: Dictionary=worker.back_tool.holder_load()
			if holder.is_empty():
				if probing: _launch_probe_reject(source,facts,fact,"original back holder unavailable")
				continue
			volumes.append({"transform":observed_root.affine_inverse()*holder.frame,"box":holder.box})
			volumes.append_array(worker.back_tool.local_keepouts())
		if is_instance_valid(worker.equipped_tool) and (not worker.back_tool or worker.back_tool.local_keepouts().is_empty()):
			volumes.append({"transform":observed_root.affine_inverse()*worker.equipped_tool.global_transform,"box":Depot.bounds(worker.equipped_tool)})
		for volume: Dictionary in volumes:
			var full: AABB=volume.box
			box.size=full.size+Vector3.ONE*.015
			clearance.shape=box
			clearance.transform=cube*volume.transform*Transform3D(Basis.IDENTITY,full.get_center())
			var tool_hits: Array=space.intersect_shape(clearance,1)
			if not tool_hits.is_empty():
				if probing: _launch_probe_reject(source,facts,fact,"whole original holder or retained tool",tool_hits[0],clearance,
					{"volume_index":volumes.find(volume),"box_size":source.encode_vector(box.size),
					"volume_local":source.encode_transform(volume.transform)})
				clear=false
				break
		if not clear: continue
		if route_admission.is_valid() and not route_admission.call(at,hit.collider):
			if probing: _launch_probe_reject(source,facts,fact,"existing supported ground route")
			continue
		if probing:
			fact["stage"]="accepted"
			facts.append(fact)
			_launch_probe_emit(worker,source,probe_key,facts,"accepted")
		return {"point":at,"support":hit.collider}
	if probing: _launch_probe_emit(worker,source,probe_key,facts,"no accepted original candidate")
	return {}

static func _launch_probe_key(worker: RigidBody3D,source: RigidBody3D) -> String:
	# Only the genuinely accepted removed original wheel lease, never depot
	# building. Eight rows per source across crew preserve a compact log.
	if "--easy-island-removed-wheel-probe" not in OS.get_cmdline_user_args() \
		or source.get("part_id")!="stock_3" or worker.current_job_id!="salvage:stock_3" \
		or is_instance_valid(source.get("assembly")) or source.get_meta(&"stored",false): return ""
	var key:=str(source.get_rid())
	return key if int(_launch_probe_counts.get(key,0))<8 else ""

static func _launch_probe_hit(source: RigidBody3D,hit: Dictionary) -> Dictionary:
	if hit.is_empty(): return {}
	var collider: Variant=hit.get("collider")
	var result: Dictionary={"rid":str(hit.get("rid")),"shape":hit.get("shape")}
	if is_instance_valid(collider):
		result["body"]=str(collider.get_path()) if collider is Node else str(collider)
		result["stored"]=collider.get_meta(&"stored",false)
		result["assembly"]=str(collider.get("assembly"))
		if collider is RigidBody3D:
			result["linear"]=source.encode_vector(collider.linear_velocity)
			result["angular"]=source.encode_vector(collider.angular_velocity)
	if hit.has("position"): result["position"]=source.encode_vector(hit.position)
	if hit.has("normal"): result["normal"]=source.encode_vector(hit.normal)
	return result

static func _launch_probe_reject(source: RigidBody3D,facts: Array[Dictionary],fact: Dictionary,stage: String,
	hit: Dictionary={},query: PhysicsShapeQueryParameters3D=null,extra: Dictionary={}) -> void:
	fact["stage"]=stage
	fact["hit"]=_launch_probe_hit(source,hit)
	if query!=null:
		fact["query"]=source.encode_transform(query.transform)
		fact["shape_rid"]=str(query.shape.get_rid())
		fact["margin"]=query.margin
	fact.merge(extra)
	facts.append(fact)

static func _launch_probe_emit(worker: RigidBody3D,source: RigidBody3D,key: String,facts: Array[Dictionary],result: String) -> void:
	# Repeated accepted approaches must not consume later refusal samples.
	if result=="accepted":
		if _launch_probe_counts.has("accepted:"+key): return
		_launch_probe_counts["accepted:"+key]=true
	var sample:=int(_launch_probe_counts.get(key,0))+1
	_launch_probe_counts[key]=sample
	var native:=PhysicsServer3D.body_get_direct_state(source.get_rid())
	var feet: Array=[]
	for side in (2 if worker._pose.evaluated_valid else 0):
		feet.append({"hip":source.encode_vector(worker._pose.evaluated_hips[side]),
			"knee":source.encode_vector(worker._pose.evaluated_knees[side]),
			"sole":source.encode_vector(worker._pose.evaluated_soles[side]),
			"ankle_basis":source.encode_transform(Transform3D(worker._pose.evaluated_ankles[side],Vector3.ZERO)),
			"ankle_height":worker._pose._ankle_height[side]})
	print("HEAD_SOURCE_STANCE ",JSON.stringify({"scope":"read-only original query results; admission unchanged",
		"worker":worker.worker_id,"worker_rid":str(worker.get_rid()),"job":worker.current_job_id,"tick":Engine.get_physics_frames(),"sample":sample,
		"source":source.part_id,"source_rid":str(source.get_rid()),"source_pose":source.encode_transform(source.global_transform),
		"source_native":source.encode_transform(native.transform) if native else null,
		"source_native_linear":source.encode_vector(native.linear_velocity) if native else null,
		"source_native_angular":source.encode_vector(native.angular_velocity) if native else null,
		"worker_pose":source.encode_transform(worker.global_transform),"model_pose":source.encode_transform(worker._model.global_transform),
		"evaluated_worker":source.encode_transform(worker._pose.evaluated_worker),"evaluated_root":source.encode_transform(worker._pose.evaluated_root),
		"evaluated_valid":worker._pose.evaluated_valid,"walking_ik":worker._pose._walking_ik,"on_ground":worker.on_ground,
		"feet":feet,"head_box_size":[.80,.70,.80],"later_head_jump_limit":6.0,
		"observed_roof_height":worker.head_leap._head_height,"observed_roof_points":worker.head_leap._roof_samples.size(),
		"back_phase":worker.back_tool.phase if worker.back_tool else "",
		"tool":str(worker.equipped_tool),"result":result,"candidates":facts}))

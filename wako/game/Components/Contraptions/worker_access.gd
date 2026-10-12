extends RefCounted
## Declared access surfaces use the helper's existing finite-force spring-foot movement.
## This validates actual supported ramps, not ladders, arbitrary climbing or navigation meshes.
const Catalogue := preload("res://Components/Contraptions/part_catalog.gd")
const RampAnchor := preload("res://Components/Contraptions/ramp_work_anchor.gd")
const BeamPreparation := preload("res://Components/Contraptions/beam_material_preparation.gd")
static var _hint_tool_shapes: Dictionary={}

static func construction_work_point(job: Dictionary, target: Node3D) -> Variant:
	var preparation: Variant = BeamPreparation.point(job, target)
	if preparation is Vector3: return preparation
	# Only an explicitly tagged rigid primary mount chooses this exact face.
	# Untagged work and all closing joints keep their existing work-point rules.
	if job.get("kind","") not in ["build","replace"] or job.get("target")!=target: return null
	var descriptor: Variant=job.get("descriptor")
	if not descriptor is Dictionary: return null
	var socket: Variant=descriptor.get("construction_work_socket")
	var parent: Variant=descriptor.get("parent")
	if not socket is String or socket.is_empty() or socket!=descriptor.get("socket_b") \
		or not parent is String or parent.is_empty() or descriptor.get("joint")!="rigid" \
		or Catalogue.socket(target.definition,socket).is_empty(): return null
	return target.connector_world(socket).origin

static func _active_construction_point(worker: RigidBody3D, target: Node3D) -> Variant:
	if is_instance_valid(worker.coordinator) and worker.coordinator.active_jobs.has(worker.current_job_id):
		return construction_work_point(worker.coordinator.active_jobs[worker.current_job_id].job,target)
	return null

static func construction_stance_offset(job: Dictionary, target: Node3D) -> Variant:
	# A declared horizontal hint adds candidates; it grants no work reach, height
	# or support and cannot activate on a malformed or unrelated restored lease.
	if not construction_work_point(job,target) is Vector3: return null
	var descriptor: Dictionary=job.descriptor
	var encoded: Variant=descriptor.get("construction_work_stance_offset")
	if descriptor.construction_work_socket!="front" or not encoded is Array or encoded.size()!=3: return null
	for value: Variant in encoded:
		if not (value is int or value is float) or not is_finite(float(value)): return null
	var offset := Vector3(float(encoded[0]),float(encoded[1]),float(encoded[2]))
	if offset.y!=0.0 or offset.length()>.400001: return null
	var world_offset: Vector3=(target.global_basis*offset).slide(Vector3.UP)
	if not world_offset.is_finite() or world_offset.length()>.400001: return null
	return world_offset

static func _active_construction_offset(worker: RigidBody3D, target: Node3D) -> Variant:
	if is_instance_valid(worker.coordinator) and worker.coordinator.active_jobs.has(worker.current_job_id):
		return construction_stance_offset(worker.coordinator.active_jobs[worker.current_job_id].job,target)
	return null

static func route(worker: RigidBody3D, target: Node3D, crew_count := 1) -> Dictionary:
	if not is_instance_valid(target.assembly): return {}
	var machine: Node3D = target.assembly
	var result := {}
	var nearest := INF
	for ramp: RigidBody3D in machine.parts.values():
		if ramp.kind != "access_ramp" or not ramp.installed or ramp.health < 20: continue
		if ramp.linear_velocity.length() > .25 or ramp.angular_velocity.length() > .1:
			result.reason = "Stop the machine before boarding its ramp"
			continue
		if float(ramp.definition.get("walk_width", 0.0)) < .9 * crew_count:
			result.reason = "Ramp too narrow for this load's Wako crew"
			continue
		var points: Array[Vector3] = []
		var authored: Array = ramp.parameters.get("access_points", [])
		if authored.is_empty():
			var half: Vector3 = ramp.definition.size * .5
			points = [ramp.to_global(Vector3(0, half.y + .025, half.z - .08)), ramp.to_global(Vector3(0, half.y + .025, -half.z + .08))]
		else:
			for v: Array in authored: points.append(ramp.to_global(Vector3(v[0], v[1], v[2])))
		if points.size() < 2: continue
		if points[0].y > points[-1].y: points.reverse()
		var exclude: Array[RID] = [worker.get_rid()]
		if is_instance_valid(worker.coordinator):
			for other: RigidBody3D in worker.coordinator.workers:
				if other != worker: exclude.append(other.get_rid())
		var sampled := _sample_path(worker, machine, points, exclude, float(ramp.definition.get("max_slope", 32.0)), crew_count)
		if sampled.is_empty():
			result.reason = "Ramp lacks continuous support or clear headroom; secure a gentle access surface"
			continue
		var extension := _deck_continuation(worker, target, sampled, exclude, crew_count)
		if extension.is_empty():
			var hinted: bool=_active_construction_offset(worker,target) is Vector3
			if not _reachable(worker, target, sampled[-1],.12 if hinted else 0.0):
				result.reason = "Ramp does not reach this connector; extend the work platform"
				continue
			if hinted:
				# An empty continuation must not bypass a declared hint's admission
				# by returning the legacy ramp-only endpoint unchecked.
				var end: Vector3=sampled[-1]
				var ray := PhysicsRayQueryParameters3D.create(end+Vector3.UP*(worker.ride_height+.12),end-Vector3.UP*.3,1,exclude)
				var hit := worker.get_world_3d().direct_space_state.intersect_ray(ray)
				if hit.is_empty() or hit.normal.y<.8 or absf(hit.position.y-end.y)>.16 \
					or hit.collider.get("assembly")!=machine or not _outside_placement(worker,target,end) \
					or not _hinted_retained_tool_clear(worker,target,hit.position,hit.normal):
					result.reason="Ramp end has no clear supported retained-tool stance for this fastener"
					continue
		else:
			sampled.append_array(extension)
		var distance := worker.global_position.distance_squared_to(sampled[0])
		if distance < nearest:
			nearest = distance
			result = {"ramp": ramp, "points": sampled}
	if result.has("points"): result.erase("reason")
	return result

static func _reachable(worker: RigidBody3D, target: Node3D, ground: Vector3, arrival_margin := 0.0) -> bool:
	var construction_point: Variant=_active_construction_point(worker,target)
	var face: Vector3=construction_point if construction_point is Vector3 else target.global_position
	var direction := (face-ground).slide(Vector3.UP)
	var facing := Basis.looking_at(direction.normalized(),Vector3.UP) if direction.length_squared()>.0001 else Basis.IDENTITY
	var hip: Vector3 = ground + Vector3.UP * worker.ride_height + facing * worker._hip_rest_offsets[worker.work_foot_side]
	var closest := target.to_global(Catalogue.closest_point(target.definition, target.to_local(hip)))
	if construction_point is Vector3: closest=construction_point
	if is_instance_valid(worker.coordinator) and worker.coordinator.active_jobs.has(worker.current_job_id):
		var lease: Dictionary = worker.coordinator.active_jobs[worker.current_job_id].job
		if lease.kind=="join" and lease.target==target: closest = target.connector_world(lease.descriptor.socket_b).origin
	if target.kind == "access_ramp": closest = RampAnchor.point(target)
	if _control_access(worker,target):
		# Match the existing supported pedal-stance calculation. Its free toe
		# never borrows the retained mallet's reach or an invented .9 m hip height.
		hip = ground + Vector3.UP * worker.ride_height + target.global_basis * worker._hip_rest_offsets[worker.work_foot_side]
		closest = target.foot_control_world(worker.work_foot_side)
		return closest.distance_to(hip) <= worker._leg_span(worker.work_foot_side) + .07 - arrival_margin
	return closest.distance_to(hip) <= worker._leg_span(worker.work_foot_side) + worker.foot_tool_span() + .07 - arrival_margin

static func _control_access(worker: RigidBody3D,target: Node3D) -> bool:
	if target.kind not in ["gun","station"]: return false
	# Installing or repairing a station uses a retained foot tool on its actual
	# housing. Only control duty needs the opposite free-toe pedal stance.
	if worker.current_job_id.begins_with("operate:"): return true
	if is_instance_valid(worker.coordinator) and worker.coordinator.active_jobs.has(worker.current_job_id):
		return worker.coordinator.active_jobs[worker.current_job_id].job.kind=="operate"
	return worker.action=="operate" or (is_instance_valid(worker.station) and worker.station==target)

static func local_stances(worker: RigidBody3D, target: Node3D, arrival_margin := 0.0, extra_ground_gaps: Array[float] = []) -> Array[Vector3]:
	# Only a stopped work site may use this bounded concave-space fallback. Native
	# routing still has to prove a supported, clear way to every returned position.
	if not target.service_safety_reason().is_empty(): return []
	if work_surface_velocity(worker,target).length() > .25: return []
	var frame: RigidBody3D = target.assembly.root_part()
	if frame and (frame.linear_velocity.length()>.25 or frame.angular_velocity.length()>.1): return []
	var bounds: AABB = target.global_transform * Catalogue.bounds_of(target.definition)
	var centre := bounds.get_center()
	var construction_point: Variant=_active_construction_point(worker,target)
	if construction_point is Vector3: centre=construction_point
	if target.kind == "access_ramp": centre = RampAnchor.point(target)
	var candidates: Array[Vector3] = []
	var join_contact: Variant = null
	if is_instance_valid(worker.coordinator) and worker.coordinator.active_jobs.has(worker.current_job_id):
		var lease: Dictionary = worker.coordinator.active_jobs[worker.current_job_id].job
		if lease.kind=="join" and lease.target==target:
			var contact: Vector3 = target.connector_world(lease.descriptor.socket_b).origin
			join_contact = contact
			for gap: float in [1.3,1.4]:
				candidates.append_array([contact+Vector3(gap,0,0),contact-Vector3(gap,0,0),
					contact+Vector3(0,0,gap),contact-Vector3(0,0,gap)])
	var ground_gaps: Array[float]=[.7,1.0,1.2,1.3]
	for gap: float in extra_ground_gaps:
		if is_finite(gap) and gap>1.3 and gap<=1.7 and not ground_gaps.has(gap): ground_gaps.append(gap)
	for gap: float in ground_gaps:
		candidates.append_array([Vector3(bounds.position.x-gap,centre.y,centre.z),Vector3(bounds.end.x+gap,centre.y,centre.z),
			Vector3(centre.x,centre.y,bounds.position.z-gap),Vector3(centre.x,centre.y,bounds.end.z+gap)])
		if gap>=1.0:
			# A low chassis-side fastener can have a clear ground stance between
			# its tyres. Front/rear fasteners may need the same supported stance
			# offset around a cockpit instead of farther outside the whole rover.
			for side: float in [-1.0,1.0]:
				var along := centre.x+side*(bounds.size.x*.5+.2)
				candidates.append_array([Vector3(along,centre.y,bounds.position.z-gap),Vector3(along,centre.y,bounds.end.z+gap)])
	for gap: float in [.4,.6]:
		candidates.append_array([
			Vector3(bounds.position.x-gap,centre.y,bounds.position.z-gap),Vector3(bounds.end.x+gap,centre.y,bounds.position.z-gap),
			Vector3(bounds.position.x-gap,centre.y,bounds.end.z+gap),Vector3(bounds.end.x+gap,centre.y,bounds.end.z+gap)])
	candidates.sort_custom(func(a:Vector3,b:Vector3)->bool:return worker.global_position.distance_squared_to(a)<worker.global_position.distance_squared_to(b))
	var valid: Array[Vector3] = []
	var exclude: Array[RID] = worker.query_exclusions()
	if is_instance_valid(worker.coordinator):
		for other: RigidBody3D in worker.coordinator.workers:
			if other != worker: exclude.append(other.get_rid())
	for candidate: Vector3 in candidates:
		# The complete retained tool must fit between its contact and the body;
		# maximum leg reach alone can fold its long shaft through the cube.
		if join_contact!=null and (candidate-join_contact).slide(Vector3.UP).length()<worker.foot_tool_span()+.4: continue
		var ray := PhysicsRayQueryParameters3D.create(candidate+Vector3.UP*.42,candidate-Vector3.UP*2.5,1,exclude)
		var hit := worker.get_world_3d().direct_space_state.intersect_ray(ray)
		if hit.is_empty() or hit.normal.y<.8 or absf(hit.position.y-worker._ground_point.y)>.42: continue
		candidate.y = hit.position.y
		if not _reachable(worker,target,candidate,arrival_margin) or not _outside_placement(worker,target,candidate): continue
		if not _outside_future_floors(worker,target.assembly,candidate): continue
		var probe: Array[Vector3] = [candidate-Vector3(0,0,.015),candidate]
		if not _sample_path(worker,target.assembly,probe,exclude,32.0,1,true).is_empty(): valid.append(candidate)
	return valid

static func _outside_future_floors(worker: RigidBody3D,machine: Node3D,ground: Vector3) -> bool:
	# A completed low fastener must not leave its helper inside the floor that
	# the next crew will install. Grounded jigs and the actual floor have finite
	# colliders; creating either through that idle helper would trap its body.
	var centre: Vector3 = ground+Vector3.UP*(worker.ride_height+.2)
	var body := AABB(centre-Vector3(.31,.525,.31),Vector3(.62,1.05,.62))
	for future: Node3D in machine.parts.values():
		if future.installed or future.kind not in ["panel","access_ramp"]: continue
		if body.intersects(future.global_transform*Catalogue.bounds_of(future.definition)): return false
	return true

static func work_surface_velocity(worker: RigidBody3D,target: RigidBody3D) -> Vector3:
	var hip: Vector3 = worker.evaluated_hip(worker.work_foot_side)
	var local := Catalogue.closest_point(target.definition,target.to_local(hip))
	var construction_point: Variant=_active_construction_point(worker,target)
	if construction_point is Vector3: local=target.to_local(construction_point)
	if target.kind == "access_ramp": local = target.to_local(RampAnchor.point(target))
	var direct := PhysicsServer3D.body_get_direct_state(target.get_rid())
	# Godot's local-position API takes a world offset from the body origin and
	# accounts for its native automatic/custom centre of mass, like joint anchors.
	if direct: return direct.get_velocity_at_local_position(target.global_basis*local)
	var centre := target.center_of_mass if target.center_of_mass_mode == RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM else Vector3.ZERO
	return target.linear_velocity+target.angular_velocity.cross(target.global_basis*(local-centre))

static func ground_path(worker: RigidBody3D,machine: Node3D,points: Array[Vector3]) -> Array[Vector3]:
	var exclude: Array[RID] = worker.query_exclusions()
	if is_instance_valid(worker.coordinator):
		for other: RigidBody3D in worker.coordinator.workers:
			if other != worker: exclude.append(other.get_rid())
	return _sample_path(worker,machine,points,exclude,32.0,1,true)

static func ground_path_for_load(worker: RigidBody3D, machine: Node3D, points: Array[Vector3], source: RigidBody3D) -> Array[Vector3]:
	# Planning observes the same finite source on its ordinary head attachment;
	# it never changes cargo, native pose, mass, reservation or collision state.
	if not is_instance_valid(source) or not source.is_inside_tree() or source.is_queued_for_deletion() \
		or not source.global_transform.is_finite() or not source.get_rid().is_valid(): return []
	var exclude: Array[RID] = worker.query_exclusions()
	if is_instance_valid(worker.coordinator):
		for other: RigidBody3D in worker.coordinator.workers:
			if other != worker: exclude.append(other.get_rid())
	# Ordinary head transport disables this source's collider. Exclude it only
	# in this prospective query, leaving its actual stored/grounded body intact.
	exclude.append(source.get_rid())
	return _sample_path(worker,machine,points,exclude,32.0,1,true,source)

static func _deck_continuation(worker: RigidBody3D, target: Node3D, ramp_points: Array[Vector3], exclude: Array[RID], crew_count: int) -> Array[Vector3]:
	# Continue only over this machine's real supported deck. A few bounded paths
	# cover a clear aisle or one corner around cargo; this is not arbitrary pathfinding.
	var start: Vector3 = ramp_points[-1]
	var direction := (start - ramp_points[-2]).slide(Vector3.UP).normalized()
	var inward := start + direction * .6
	var candidates: Array[Vector3] = []
	if _control_access(worker,target) and is_instance_valid(worker.coordinator):
		var stance: Dictionary = worker.coordinator._station_work_position(worker, target)
		if not stance.is_empty(): candidates.append(stance.point)
	else:
		var bounds: AABB = target.global_transform * Catalogue.bounds_of(target.definition)
		var centre := bounds.get_center()
		# Keep every already-proven aisle candidate. An explicit fastener face
		# changes work reach/heading; it must not discard clear axial approaches.
		var centres: Array[Vector3]=[centre]
		var construction_point: Variant=_active_construction_point(worker,target)
		if construction_point is Vector3 and not centres.has(construction_point): centres.append(construction_point)
		for face_centre: Vector3 in centres:
			var proposals: Array[Vector3]=[Vector3(face_centre.x,start.y,face_centre.z)]
			for gap: float in [.45, .7, 1.0]:
				proposals.append_array([Vector3(bounds.position.x-gap,start.y,face_centre.z),Vector3(bounds.end.x+gap,start.y,face_centre.z),
					Vector3(face_centre.x,start.y,bounds.position.z-gap),Vector3(face_centre.x,start.y,bounds.end.z+gap)])
			for proposal: Vector3 in proposals:
				if not candidates.has(proposal): candidates.append(proposal)
	# Try the closest supported approach from the ramp first. Taking the first
	# side face could send a helper past a usable rear tool stance into a pocket
	# that passes maximum reach but folds the full mallet back through its cube.
	candidates.sort_custom(func(a:Vector3,b:Vector3)->bool:return a.distance_squared_to(start)<b.distance_squared_to(start))
	var stance_offset: Variant=_active_construction_offset(worker,target)
	var preferred: Array[Vector3]=[]
	if stance_offset is Vector3:
		# Preserve the original closest-aisle ordering, then test its bounded
		# shifted alternatives before the unchanged original fallback points.
		for candidate: Vector3 in candidates:
			var shifted: Vector3=candidate+stance_offset
			if not preferred.has(shifted): preferred.append(shifted)
		for candidate: Vector3 in candidates:
			if not preferred.has(candidate): preferred.append(candidate)
	else: preferred=candidates
	for candidate: Vector3 in preferred:
		if candidate.distance_to(start) > 5.0: continue
		# A deck can be one ordinary native step above the ramp lip. Derive its
		# height from the real support rather than flattening the whole continuation.
		var ray := PhysicsRayQueryParameters3D.create(Vector3(candidate.x, start.y + .42, candidate.z), Vector3(candidate.x, start.y - .42, candidate.z), 1, exclude)
		var hit := worker.get_world_3d().direct_space_state.intersect_ray(ray)
		if hit.is_empty() or hit.normal.y < .8 or hit.collider.get("assembly") != target.assembly: continue
		candidate.y = hit.position.y
		if stance_offset is Vector3 and not _hinted_retained_tool_clear(worker,target,candidate,hit.normal): continue
		var paths: Array = [[start, candidate], [start, inward, candidate],
			[start, inward, Vector3(candidate.x, inward.y, inward.z), candidate],
			[start, inward, Vector3(inward.x, inward.y, candidate.z), candidate]]
		# A control pod can occupy the direct inward line. Try its four real
		# outside corners; every step still requires the same native deck proof.
		var bounds: AABB = target.global_transform * Catalogue.bounds_of(target.definition)
		paths.append_array([[start,Vector3(candidate.x,start.y,bounds.end.z+.1),candidate],
			[start,Vector3(candidate.x,start.y,bounds.position.z-.1),candidate],
			[start,Vector3(bounds.end.x+.1,start.y,candidate.z),candidate],
			[start,Vector3(bounds.position.x-.1,start.y,candidate.z),candidate]])
		# Another housing can stand between this ramp and the requested cargo.
		# Try both real side aisles around a bounded number of nearby controls;
		# every intervening step still needs the same native support proof.
		var detours := 0
		for obstacle: Node3D in target.assembly.parts.values():
			if obstacle==target or not obstacle.installed or obstacle.kind not in ["station","gun"]: continue
			if obstacle.global_position.distance_to(start)>5.0: continue
			var casing: AABB = obstacle.global_transform*Catalogue.bounds_of(obstacle.definition)
			for outside: float in [casing.position.x-.55,casing.end.x+.55]:
				var rear := Vector3(outside,start.y,casing.end.z+.55)
				var front := Vector3(outside,start.y,casing.position.z-.55)
				paths.append_array([[start,rear,front,candidate],[start,front,rear,candidate]])
			detours += 1
			if detours>=4: break
		for path: Array in paths:
			var points: Array[Vector3] = []
			points.assign(path)
			var sampled := _sample_path(worker, target.assembly, points, exclude, 32.0, crew_count)
			var margin := .12 if stance_offset is Vector3 else 0.0
			if not sampled.is_empty() and _reachable(worker, target, sampled[-1],margin) and _outside_placement(worker, target, sampled[-1]): return sampled
	return []

static func _hinted_retained_tool_clear(worker: RigidBody3D, target: Node3D, ground: Vector3, normal: Vector3) -> bool:
	# Rebase the published actual toe/tool pose only for this read-only query.
	# This proves current retained-tool clearance, not a future work-leg solve.
	# Actual preparation, contact and withdrawal keep their own pose guards.
	var tool: RigidBody3D=worker.equipped_tool
	if worker.back_tool and worker.back_tool.phase == "back":
		var face: Variant = _active_construction_point(worker,target)
		if not face is Vector3: return false
		var direction: Vector3 = (face-ground).slide(Vector3.UP)
		if direction.length_squared()<.0001: return false
		var current := Transform3D(Basis(Vector3.UP,worker._heading),worker.global_position)
		var proposed := Transform3D(Basis.looking_at(direction.normalized(),Vector3.UP),ground+Vector3.UP*worker.ride_height)
		return worker.back_tool.travel_frame_clear(proposed*current.affine_inverse())
	if not is_instance_valid(tool) or tool.carrier!=worker.tool_anchor or not worker.foot_grip_valid \
		or not worker._pose or not worker._pose.evaluated_valid: return false
	var face: Variant=_active_construction_point(worker,target)
	if not face is Vector3: return false
	var direction: Vector3=(face-ground).slide(Vector3.UP)
	if direction.length_squared()<.0001: return false
	var current := Transform3D(Basis(Vector3.UP,worker._heading),worker.global_position)
	var proposed := Transform3D(Basis.looking_at(direction.normalized(),Vector3.UP),ground+Vector3.UP*worker.ride_height)
	var rebase: Transform3D=proposed*current.affine_inverse()
	var world: Transform3D=rebase*tool.global_transform
	if not world.is_finite(): return false
	var frame: Dictionary=worker._tool_clearance_frame()
	var actual_root: Transform3D=worker.global_transform*worker._pose.evaluated_worker.affine_inverse()*worker._pose.evaluated_root
	frame.inverse=(rebase*actual_root).affine_inverse()
	frame.basis=world.basis
	frame.supported=true
	frame.support_point=ground
	frame.support_normal=normal
	var toe: Vector3=world.origin-world.basis.y*(.035+float(frame.length)*.45)
	if not worker._tool_posture_clear(toe,world.basis.y,frame): return false
	var boxes: Array=frame.keepouts
	if boxes.is_empty(): return false
	var key: int=hash(boxes)
	if not _hint_tool_shapes.has(key):
		var shapes: Array[BoxShape3D]=[]
		for box: AABB in boxes:
			var shape := BoxShape3D.new()
			shape.size=box.size
			shapes.append(shape)
		_hint_tool_shapes[key]=shapes
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask=1
	query.margin=.005
	query.exclude=[worker.get_rid(),tool.get_rid()]
	for index in boxes.size():
		var box: AABB=boxes[index]
		query.shape=_hint_tool_shapes[key][index]
		query.transform=world*Transform3D(Basis.IDENTITY,box.get_center())
		if not worker.get_world_3d().direct_space_state.intersect_shape(query,1).is_empty(): return false
	return true

static func _outside_placement(worker: RigidBody3D, target: Node3D, ground: Vector3) -> bool:
	# Planned components have no native collision yet. Do not install a housing
	# through the body merely because its unfinished silhouette can be traversed.
	if target.installed: return true # Its real collider is already checked by the same native sampler.
	var centre: Vector3 = ground + Vector3.UP * (worker.ride_height + .2)
	var body := AABB(centre - Vector3(.31, .525, .31), Vector3(.62, 1.05, .62))
	var component: AABB = target.global_transform * Catalogue.bounds_of(target.definition)
	return not body.intersects(component)

static func _sample_path(worker: RigidBody3D, machine: Node3D, points: Array[Vector3], exclude: Array[RID], max_slope: float, crew_count: int, allow_ground := false, planned_source: RigidBody3D = null) -> Array[Vector3]:
	var sampled: Array[Vector3] = []
	var space := worker.get_world_3d().direct_space_state
	# Depot tool approaches use the same real floor policy as their endpoint.
	# Finite stored parts remain obstacles rather than walking platforms.
	var depot_floor: bool=allow_ground and is_instance_valid(worker.coordinator) and machine==worker.coordinator.yard.storage
	var capsule := CapsuleShape3D.new()
	capsule.radius = .31
	capsule.height = 1.05
	var cargo_shape: BoxShape3D
	var cargo_bounds := AABB()
	var cargo_centre := Vector3.ZERO
	var cargo_height := 0.0
	var cargo_exclude := exclude.duplicate()
	if worker.carrying and is_instance_valid(worker.coordinator) and worker.coordinator.active_jobs.has(worker.current_job_id):
		var source: RigidBody3D = worker.coordinator.active_jobs[worker.current_job_id].job.part
		cargo_bounds = Catalogue.bounds_of(source.definition)
		cargo_shape = BoxShape3D.new()
		cargo_shape.size = cargo_bounds.size + Vector3.ONE * .03
		cargo_centre = cargo_bounds.get_center()
		cargo_height = source.global_position.y - worker._ground_point.y
		cargo_exclude.append(source.get_rid())
	elif is_instance_valid(planned_source):
		cargo_bounds = Catalogue.bounds_of(planned_source.definition)
		cargo_shape = BoxShape3D.new()
		cargo_shape.size = cargo_bounds.size + Vector3.ONE * .03
		cargo_centre = cargo_bounds.get_center()
		cargo_height = worker.head_anchor.global_position.y - worker._ground_point.y + float(planned_source.definition.size.y) * .5 + .03
		cargo_exclude.append(planned_source.get_rid())
	# Reuse query parameters only within this synchronous path check. Every
	# native observation below remains fresh, in its original crew/point order.
	var ray: PhysicsRayQueryParameters3D
	var clearance: PhysicsShapeQueryParameters3D
	for i in points.size() - 1:
		var delta := points[i + 1] - points[i]
		if delta.length_squared() < .000001: continue
		var slope := atan2(absf(delta.y), maxf(delta.slide(Vector3.UP).length(), .001))
		if slope > deg_to_rad(max_slope): return []
		var lateral := delta.cross(Vector3.UP).normalized()
		var steps := maxi(ceili(delta.length() / .18), 1)
		var facing := Basis.IDENTITY
		if cargo_shape:
			var heading := delta.slide(Vector3.UP)
			if heading.length_squared() > .0001: facing = Basis.looking_at(heading.normalized(), Vector3.UP)
		for step in steps + 1:
			var point := points[i].lerp(points[i + 1], float(step) / steps)
			var centre := Vector3.ZERO
			for crew in crew_count:
				var offset := lateral * (float(crew) - float(crew_count - 1) * .5) * .9
				var at := point + offset
				# Start above the same surfaces as the helper's native spring probe.
				# Starting inside a station casing misses its top and incorrectly
				# accepts the floor beneath as an ordinary supported walking stance.
				if not ray: ray = PhysicsRayQueryParameters3D.new()
				ray.from = at + Vector3.UP * (worker.ride_height+.12)
				ray.to = at - Vector3.UP * .3
				ray.collision_mask = 1
				ray.exclude = exclude
				var hit := space.intersect_ray(ray)
				if hit.is_empty() or hit.normal.y < .8 or absf(hit.position.y - point.y) > .16: return []
				if hit.collider.get("assembly") != machine and not (allow_ground and hit.collider.get("assembly") == null): return []
				if depot_floor:
					# A released tool retains its finite contact shape; it is still an
					# obstacle, rather than a low step on the next depot approach.
					var support_definition: Variant=hit.collider.get("definition")
					if hit.collider.get_meta(&"stored",false) or (support_definition is Dictionary and support_definition.get("category","")=="tool"): return []
				var body := hit.collider as RigidBody3D
				if not body and not allow_ground: return []
				if body and (body.linear_velocity.length() > .25 or body.angular_velocity.length() > .1): return []
				if not clearance: clearance = PhysicsShapeQueryParameters3D.new()
				clearance.shape = capsule
				clearance.transform = Transform3D(Basis.IDENTITY, hit.position + Vector3.UP * (worker.ride_height + .2))
				clearance.collision_mask = 1
				clearance.exclude = exclude
				if not space.intersect_shape(clearance, 1).is_empty(): return []
				if cargo_shape:
					clearance.shape = cargo_shape
					clearance.transform = Transform3D(facing, hit.position + Vector3.UP * cargo_height + facing * cargo_centre)
					clearance.exclude = cargo_exclude
					if not space.intersect_shape(clearance, 1).is_empty(): return []
				centre += hit.position
			sampled.append(centre / float(crew_count))
	return sampled

extends RefCounted
## Grounded assisted stock sizing, paid by ordinary supported build-tool work.
## This is a conserved material transaction, not a simulated sawing mechanism.

const Catalogue := preload("res://Components/Contraptions/part_catalog.gd")
const CAPACITY := "beam_durability_capacity"

static func point(job: Dictionary, target: Node3D) -> Variant:
	if job.get("kind", "") != "prepare" or job.get("part") != target or job.get("target") != target: return null
	if not is_instance_valid(target) or target.kind != "beam" or not job.get("parameters") is Dictionary: return null
	var length := float(job.parameters.get("length", 0.0))
	if not is_finite(length) or length < .3 or float(target.definition.size.z)-length < .3-.00001: return null
	# Beam sections retain their front material phase. The plane is measured
	# from the stock's real front end; closest_point selects actual profile material.
	var local := Catalogue.closest_point(target.definition, Vector3(0, float(target.definition.size.y), -float(target.definition.size.z)*.5+length))
	return target.to_global(local)

static func active_point(worker: Node3D, target: Node3D) -> Variant:
	if is_instance_valid(worker.coordinator) and worker.coordinator.active_jobs.has(worker.current_job_id):
		return point(worker.coordinator.active_jobs[worker.current_job_id].job, target)
	return null

static func resume_matches(yard: Node3D, job: Dictionary, saved: Dictionary) -> bool:
	var placement: Node3D = job.get("placement")
	if not (is_instance_valid(placement) and str(saved.get("placement_id", "")) == placement.part_id \
		and int(saved.get("placement_assembly", -1)) == yard.assemblies.find(placement.assembly) \
		and saved.get("parameters") is Dictionary and Catalogue.same_shape("beam", saved.parameters, job.parameters) \
		and saved.get("source_parameters") is Dictionary and Catalogue.same_shape("beam", saved.source_parameters, job.part.parameters)):
		return false
	if not Catalogue.BeamGeometry.validate(saved.source_parameters).is_empty() \
		or not Catalogue.BeamGeometry.validate(saved.parameters).is_empty() \
		or not job.part.beam_durability_error(saved.source_parameters).is_empty() \
		or not grounded_reason(yard, job.part).is_empty(): return false
	var progress: Variant = saved.get("progress")
	if not (progress is int or progress is float) or not is_finite(float(progress)) \
		or float(progress) < 0.0 or float(progress) > 1.0: return false
	for key: String in ["source_mass", "source_health", "source_wear"]:
		var value: Variant = saved.get(key)
		if not (value is int or value is float) or not is_finite(float(value)): return false
	if not saved.get("source_jammed") is bool or saved.source_jammed != job.part.jammed \
		or absf(float(saved.source_mass)-float(job.part.mass)) > .000001 \
		or absf(float(saved.source_health)-float(job.part.health)) > .000001 \
		or absf(float(saved.source_wear)-float(job.part.wear)) > .000001: return false
	var capacity: Variant = saved.get("source_capacity")
	var local: Variant = saved.get("cut_local")
	if not (capacity is int or capacity is float) or not is_finite(float(capacity)) \
		or float(capacity) <= 0.0 or float(capacity) > float(Catalogue.all().beam.health) \
		or absf(float(capacity)-float(saved.source_parameters.get(CAPACITY, Catalogue.all().beam.health))) > .000001 \
		or absf(float(capacity)-float(job.part.definition.health)) > .000001 or not local is Array or local.size() != 3:
		return false
	for coordinate: Variant in local:
		if not (coordinate is int or coordinate is float) or not is_finite(float(coordinate)): return false
	var current: Variant = point(job, job.part)
	var encoded := Vector3(float(local[0]), float(local[1]), float(local[2]))
	return current is Vector3 and job.part.to_local(current).distance_to(encoded) < .000001 \
		and Catalogue.closest_point(job.part.definition, encoded).distance_to(encoded) < .000001

static func jobs(yard: Node3D, placements: Array[Node3D]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	# Field plans still require exact stopped-container ownership. A grounded
	# source outside that custody is not admitted by this workshop fallback.
	if yard.worksite_active(): return result
	for placement: Node3D in placements:
		if placement.kind != "beam" or yard._part_reserved(placement) or yard.available_part("beam", placement.parameters) != null: continue
		var source: RigidBody3D
		for stock: Node3D in yard.loose_parts:
			if not stock is RigidBody3D or yard._part_reserved(stock) or not yard.material_matches(stock, "beam", placement.parameters) \
				or Catalogue.same_shape("beam", stock.parameters, placement.parameters) or not grounded_reason(yard, stock).is_empty(): continue
			if source == null or stock.mass < source.mass: source = stock
		if source == null: continue
		var descriptor: Dictionary = {}
		for planned: Dictionary in yard._plans.get(placement.assembly.get_instance_id(), []):
			if planned.id == placement.part_id: descriptor = planned; break
		if descriptor.is_empty(): continue
		result.append({"id": "prepare:%d:%s" % [placement.assembly.get_instance_id(), placement.part_id],
			"kind": "prepare", "part": source, "target": source, "placement": placement,
			"parameters": placement.parameters.duplicate(true), "descriptor": descriptor,
			"position": source.global_position, "duration": 3.8, "heavy": false,
			"dependencies": [], "priority": 92, "blocked": ""})
	return result

static func reason(yard: Node3D, job: Dictionary) -> String:
	var source: RigidBody3D = job.get("part")
	var placement: Node3D = job.get("placement")
	if not is_instance_valid(source) or not is_instance_valid(placement) or placement.installed \
		or not is_instance_valid(placement.assembly) or placement.assembly.parts.get(placement.part_id) != placement:
		return "The unfinished placement no longer needs this grounded stock"
	if source != job.get("target") or not yard.loose_parts.has(source) or not job.get("parameters") is Dictionary \
		or not Catalogue.same_shape("beam", placement.parameters, job.parameters) \
		or not yard.material_matches(source, "beam", job.parameters) or point(job, source) == null:
		return "Grounded stock or requested section changed; inspect its material again"
	var descriptor: Dictionary = job.get("descriptor", {})
	for dependency: String in descriptor.get("requires", []):
		if not placement.assembly.parts.has(dependency) or not placement.assembly.parts[dependency].installed:
			return "Waiting for supporting component " + dependency
	var parent: String = descriptor.get("parent", "")
	if not parent.is_empty() and (not placement.assembly.parts.has(parent) or not placement.assembly.parts[parent].installed):
		return "Waiting for mounting component " + parent
	if not placement.get_meta(&"construction_support_reason", "").is_empty(): return placement.get_meta(&"construction_support_reason")
	var root: RigidBody3D = placement.assembly.root_part()
	if not is_instance_valid(root) or root.linear_velocity.length() > .25 or root.angular_velocity.length() > .1:
		return "Stop the planned machine before preparing its member"
	if yard.unsafe_at(source.global_position) or yard.unsafe_at(placement.global_position): return "Unsafe stock preparation site"
	return grounded_reason(yard, source)

static func grounded_reason(yard: Node3D, source: RigidBody3D) -> String:
	if not is_instance_valid(source) or source.kind != "beam" or not source.installed or source.planned \
		or is_instance_valid(source.assembly) or is_instance_valid(source.carrier) or source.freeze \
		or source.get_meta(&"stored", false) or source.get_meta(&"rack_scale", false) \
		or source.get_meta(&"in_transit", false) or source.get_meta(&"player_carry", false) \
		or source.get_meta(&"awaiting_setdown", false) or not str(source.get_meta(&"equipped_worker", "")).is_empty() \
		or not source.global_transform.is_finite() or not source.scale.is_equal_approx(Vector3.ONE) \
		or (source.collision_layer & 1) == 0 or (source.collision_mask & 1) == 0:
		return "Set the full-sized real beam on clear native ground before preparation"
	if not source.stock_condition_reason().is_empty(): return source.stock_condition_reason()
	if not source.material_storage_reason().is_empty(): return source.material_storage_reason()
	if source.health <= float(source.definition.health)*.15 or source.jammed: return "Recover working beam material before preparation"
	if not is_finite(source.mass) or source.mass <= 0.0 or not is_finite(source.health) or not is_finite(source.wear): return "Beam material condition must remain finite"
	if not Catalogue.BeamGeometry.validate(source.parameters).is_empty() \
		or absf(source.mass-float(Catalogue.get_def("beam", source.parameters).mass)) > .000001:
		return "The actual beam body must match its finite saved material shape"
	if not source.linear_velocity.is_finite() or not source.angular_velocity.is_finite() \
		or source.linear_velocity.length() > .25 or source.angular_velocity.length() > .1: return "Let grounded stock stop before preparation"
	if source.global_basis.y.normalized().dot(Vector3.UP) < .98: return "Support the actual beam upright on level ground before preparation"
	return support_reason(yard, source, source.global_transform, source.parameters)

static func support_reason(yard: Node3D, source: RigidBody3D, pose: Transform3D, parameters: Dictionary) -> String:
	var definition: Dictionary = Catalogue.get_def("beam", parameters)
	var half: Vector3 = definition.size*.5
	var exclude: Array[RID] = [source.get_rid()]
	for worker: RigidBody3D in yard.workers: exclude.append(worker.get_rid())
	for z: float in [-half.z+.04, 0.0, half.z-.04]:
		var bottom: Vector3 = pose*Vector3(0, -half.y, z)
		var ray := PhysicsRayQueryParameters3D.create(bottom+Vector3.UP*.16, bottom-Vector3.UP*.16, 1, exclude)
		var hit := yard.get_world_3d().direct_space_state.intersect_ray(ray)
		if hit.is_empty() or hit.normal.y < .8 or absf(hit.position.y-bottom.y) > .016 or hit.collider.get("assembly") != null:
			return "The actual beam section needs continuous level native ground support"
		var body := hit.collider as RigidBody3D
		if body and (body.linear_velocity.length() > .25 or body.angular_velocity.length() > .1): return "Stop the beam's actual supporting ground"
	return ""

static func stance(coordinator: Node, job: Dictionary, worker: RigidBody3D, access: GDScript) -> Dictionary:
	var contact: Variant = point(job, job.part)
	if not contact is Vector3: return {}
	var candidates: Array[Vector3] = []
	var source: RigidBody3D = job.part
	for gap: float in [1.1, 1.3, 1.5]:
		for side: float in [-1.0, 1.0]:
			candidates.append(contact+source.global_basis.x*gap*side)
	candidates.sort_custom(func(a: Vector3, b: Vector3) -> bool: return worker.global_position.distance_squared_to(a) < worker.global_position.distance_squared_to(b))
	var exclude: Array[RID] = [worker.get_rid()]
	for other: RigidBody3D in coordinator.workers:
		if other != worker: exclude.append(other.get_rid())
	var capsule := CapsuleShape3D.new()
	capsule.radius = .31; capsule.height = 1.05
	var space := worker.get_world_3d().direct_space_state
	for candidate: Vector3 in candidates:
		var ray := PhysicsRayQueryParameters3D.create(candidate+Vector3.UP*1.5, candidate-Vector3.UP*2.0, 1, exclude)
		var hit := space.intersect_ray(ray)
		if hit.is_empty() or hit.normal.y < .8 or hit.collider.get("assembly") != null or hit.collider == source: continue
		candidate = hit.position
		var direction: Vector3 = (contact-candidate).slide(Vector3.UP)
		if direction.length_squared() < .0001: continue
		var facing := Basis.looking_at(direction.normalized(), Vector3.UP)
		var hip: Vector3 = candidate+Vector3.UP*worker.ride_height+facing*worker._hip_rest_offsets[worker.work_foot_side]
		if hip.distance_to(contact) > worker._leg_span(worker.work_foot_side)+worker.foot_tool_span()+.07-.12: continue
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = capsule; query.collision_mask = 1; query.exclude = exclude
		query.transform = Transform3D(Basis.IDENTITY, candidate+Vector3.UP*(worker.ride_height+.2))
		if not space.intersect_shape(query, 1).is_empty(): continue
		var path: Array = coordinator._plan_route(worker._ground_point, candidate, false, null, candidate.y)
		var route: Array[Vector3] = [worker._ground_point]
		for at: Vector3 in path: route.append(at)
		if route[-1] != candidate: route.append(candidate)
		if access.ground_path(worker, null, route).is_empty(): continue
		return {"point": candidate, "contact": contact}
	return {}

static func tick(coordinator: Node, entry: Dictionary, delta: float, access: GDScript) -> void:
	var worker: RigidBody3D = entry.crew[0]
	var job: Dictionary = entry.job
	var contact: Variant = point(job, job.part)
	if not contact is Vector3:
		coordinator._cancel(entry, "Grounded preparation face changed"); return
	if entry.phase == "approach":
		if not entry.has("preparation_stance"):
			var selected := stance(coordinator, job, worker, access)
			if selected.is_empty():
				entry.retry_delay = 20.0
				coordinator._cancel(entry, "No supported preparation stance; clear ground beside the actual cut plane"); return
			entry.preparation_stance = selected.point
			entry.local_point = selected.point
		var at: Vector3 = entry.preparation_stance
		var arrived: bool = coordinator._navigate(worker, at, .12)
		worker.face_point(contact)
		worker.status_text = "Reaching grounded material preparation point"
		if worker.navigation_blocked():
			coordinator._cancel(entry, "Blocked ground path to material preparation point"); return
		if arrived and worker.on_ground and worker.action.is_empty():
			if not worker.can_reach_work():
				coordinator._cancel(entry, "Preparation point out of finite foot-tool reach"); return
			worker.stop_navigation(); entry.phase = "inspect"; worker.begin_action("inspect")
	elif entry.phase == "work":
		if not worker.tool_pose_blocked.is_empty():
			entry.retry_delay = 20.0; coordinator._cancel(entry, worker.tool_pose_blocked); return
		if not worker.on_ground or not worker.can_reach_work():
			coordinator._cancel(entry, "Lost supported preparation contact; material remains intact"); return
		worker.face_point(contact)
		worker.status_text = "Preparing grounded beam material"
		if float(entry.progress) < 1.0:
			if not worker.foot_contact_ready(): return
			entry.progress = minf(float(entry.progress)+delta/maxf(float(job.duration), .5)/.35, 1.0)
			worker.progress = entry.progress
			if not coordinator.yard.perform_work(job, entry.progress, "tick", entry.crew):
				coordinator._cancel(entry, "Preparation material changed; inspect the real stock again"); return
		elif worker.action.is_empty():
			worker.begin_action("assemble") # Commit only at the next genuine supported work event.

static func contact_ready(yard: Node3D, job: Dictionary, crew: Array) -> bool:
	if crew.size() != 1 or not reason(yard, job).is_empty(): return false
	var worker: RigidBody3D = crew[0]
	var tool: RigidBody3D = worker.equipped_tool
	if worker.work_target != job.part or worker.action != "assemble" or not worker.on_ground \
		or not worker.can_reach_work() or not worker.foot_contact_ready() or not worker.tool_pose_blocked.is_empty() \
		or not yard.tool_compatible(tool, "build") or tool != job.get("tool") or tool.carrier != worker.tool_anchor:
		return false
	# Recheck the actual full mesh's existing cube/floor guards and native world.
	# Only this contacted material body is the intended work target.
	var length: float = tool.definition.size.y
	var toe: Vector3 = tool.global_position-tool.global_basis.y*(.035+length*.45)
	if not worker.held_tool_basis_clear(toe, tool.global_basis, worker._ground_point, worker.ground_normal): return false
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask = 1; query.margin = .005
	query.exclude = [worker.get_rid(), tool.get_rid(), job.part.get_rid()]
	var boxes: Array = tool.get_meta(&"worker_tool_keepouts", [])
	if boxes.is_empty(): return false
	for box: AABB in boxes:
		var shape := BoxShape3D.new(); shape.size = box.size
		query.shape = shape; query.transform = tool.global_transform*Transform3D(Basis.IDENTITY, box.get_center())
		if not yard.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty(): return false
	return true

static func split(yard: Node3D, source: RigidBody3D, parameters: Dictionary, grounded := false, crew: Array = []) -> bool:
	if not yard.material_matches(source, "beam", parameters): return false
	var length := float(parameters.get("length", 2.0))
	var original_length: float = source.definition.size.z
	if original_length-length < .001: return true
	var sections: Array[Dictionary] = Catalogue.BeamGeometry.cut_parameters(source.parameters, length)
	var kept: Dictionary = Catalogue.get_def("beam", sections[0])
	var remaining: Dictionary = Catalogue.get_def("beam", sections[1])
	var original_mass: float = source.mass
	if absf(float(kept.mass)+float(remaining.mass)-original_mass) > maxf(.0001, original_mass*.00001): return false
	var original_capacity: float = source.definition.health
	var original_health: float = source.health
	var fraction: float = float(kept.mass)/(float(kept.mass)+float(remaining.mass))
	var kept_capacity: float = original_capacity*fraction
	var remaining_capacity: float = original_capacity-kept_capacity
	var kept_health: float = original_health*fraction
	var remaining_health: float = original_health-kept_health
	if not source.beam_section_error(sections[0], kept_capacity, kept_health).is_empty() \
		or not source.beam_section_error(sections[1], remaining_capacity, remaining_health).is_empty(): return false
	var pose: Transform3D = source.global_transform
	var direct := PhysicsServer3D.body_get_direct_state(source.get_rid())
	if grounded and direct: pose = direct.transform
	var velocity: Vector3 = direct.linear_velocity if direct else source.linear_velocity
	var angular: Vector3 = direct.angular_velocity if direct else source.angular_velocity
	var centre: Vector3 = direct.center_of_mass_local if direct else Vector3.ZERO
	var kept_offset := Vector3(0, 0, (length-original_length)*.5)
	var remainder_offset := Vector3(0, 0, length*.5)
	var kept_pose := pose*Transform3D(Basis.IDENTITY, kept_offset)
	var remaining_pose := pose*Transform3D(Basis.IDENTITY, remainder_offset)
	var kept_velocity: Vector3 = velocity+angular.cross(pose.basis*(kept_offset+section_centre(sections[0])-centre))
	var remaining_velocity: Vector3 = velocity+angular.cross(pose.basis*(remainder_offset+section_centre(sections[1])-centre))
	var offcut_local: Transform3D = yard.global_transform.affine_inverse()*remaining_pose
	if not kept_pose.is_finite() or not remaining_pose.is_finite() or not offcut_local.is_finite() \
		or not kept_velocity.is_finite() or not remaining_velocity.is_finite() or not angular.is_finite(): return false
	if grounded:
		if not grounded_reason(yard, source).is_empty() \
			or not support_reason(yard, source, kept_pose, sections[0]).is_empty() \
			or not support_reason(yard, source, remaining_pose, sections[1]).is_empty(): return false
		# Both native contact geometries are exact partitions of the already
		# grounded body. No material enters a new volume and no collision-query
		# shrink, larger admission tolerance or searched relocation is required.
	# No gameplay state changes before all material/support/admission checks pass.
	var offcut: RigidBody3D = source.get_script().new()
	var source_blocked: bool = source.is_blocking_signals()
	offcut.set_block_signals(true)
	sections[1][CAPACITY] = remaining_capacity
	offcut.setup("beam", yard.next_id("offcut"), true, sections[1])
	offcut.copy_condition_from(source)
	if not offcut.apply_beam_section(sections[1], remaining_capacity, remaining_health):
		offcut.free(); return false
	# All admission happened against the original source. The known-valid source
	# API cannot introduce a later admission test; suppress its resize emissions
	# until callbacks can observe both conserved bodies and custody entries.
	source.set_block_signals(true)
	if not source.apply_beam_section(sections[0], kept_capacity, kept_health):
		source.set_block_signals(source_blocked); offcut.free(); return false
	# Changing each section's local origin keeps both original material volumes
	# exactly where the cut occurred. The offcut is a real partition, never a
	# centred duplicate moved instantly to storage.
	var carrier: Node3D=source.carrier
	source.global_transform = kept_pose
	if is_instance_valid(carrier): source.set_carried_at_pose(carrier)
	source.linear_velocity = kept_velocity
	source.angular_velocity = angular
	offcut.transform = offcut_local
	offcut.linear_velocity = remaining_velocity
	offcut.angular_velocity = angular
	yard.loose_parts.append(offcut); yard.add_child(offcut)
	if not grounded: yard._release_staged_component(offcut, crew)
	source.set_block_signals(source_blocked); offcut.set_block_signals(false)
	if not source_blocked: source.condition_changed.emit()
	offcut.condition_changed.emit()
	return true

static func section_centre(parameters: Dictionary) -> Vector3:
	# Native convex pieces use uniform material volume. Box/I/tube sections are
	# symmetric; clipped truss webs can have a real off-centre mass distribution.
	var definition: Dictionary = Catalogue.get_def("beam", parameters)
	if definition.get("profile", "box") != "truss": return Vector3.ZERO
	var first_moment := Vector3.ZERO
	for polygon: PackedVector2Array in definition.web_polygons:
		var yz := Vector2.ZERO
		for vertex: Vector2 in polygon: yz += vertex
		yz /= polygon.size()
		var volume: float = Catalogue.BeamGeometry.TRUSS_WEB_WIDTH*Catalogue.BeamGeometry.TRUSS_WEB_HEIGHT*absf(polygon[2].y-polygon[0].y)
		first_moment += Vector3(0, yz.x, yz.y)*volume
	return first_moment/(float(definition.section_area)*float(definition.size.z))

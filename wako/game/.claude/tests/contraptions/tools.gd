extends "res://.claude/tests/contraptions/integration.gd"
## Actual source bodies, timed tool contacts, atomic leases and JSON save/load.
var changes := 0
var planted_contacts := 0
var invalid_contact := false
var shaft_samples := 0
var shaft_intersections := 0
var visual_samples := 0
var visual_intersections := 0
var _tool_vertices: Dictionary = {}
var repair_contacts := 0
var inspection_contacts := 0
var inspection_support_gap := INF
var _work_poses: Dictionary = {}
var inspection_pose_samples := 0
var inspection_knee_step := 0.0
var inspection_ankle_step := 0.0
var inspection_root_step := 0.0
var inspection_root_angle := 0.0
var _work_pose_stats: Dictionary = {}
var watched_work_actions: Array[String] = ["inspect","assemble","tool_change","maintenance"]
var _work_tool_support: Dictionary = {}
var _fitted_tools: Dictionary = {}
var _fitting_contacts := 0
var _fitting_position_step := 0.0
var _fitting_rotation_step := 0.0
var draw_distance := 0.0

# Opt-in diagnostic requires physical_tool_alternate_admission.patch first.
# Counts are native route entry calls, not the total rays/shapes inside them.
class AlternateAdmissionTrace:
	extends "res://Components/Contraptions/work_coordinator.gd"
	var probes: Array[Dictionary] = []
	var route_entries: Array[int] = [0, 0, 0] # gate, path, stance admission
	var _inside_probe: bool = false
	var _first_path: bool = false
	var _first_leg_clear: bool = false
	var _gate: Vector3 = Vector3.INF
	var _point: Vector3 = Vector3.INF

	func _prospective_depot_tool_ready(worker: RigidBody3D, tool: Node3D, capability: String) -> bool:
		var key: int = worker.get_instance_id()
		var until: float = float(_depot_tool_admission_until.get(key, 0.0))
		var cursor: Dictionary = _depot_tool_admission_cursor.get(key, {}).duplicate(true)
		var counts: Array[int] = route_entries.duplicate()
		var fresh: bool = worker.on_ground and until <= _clock
		_inside_probe = true # Count entries even if a throttle guard regresses.
		_gate = Vector3.INF
		_point = Vector3.INF
		_first_path = true
		_first_leg_clear = false
		var result: bool = super._prospective_depot_tool_ready(worker, tool, capability)
		_inside_probe = false
		var delta: Array[int] = []
		for i in counts.size(): delta.append(route_entries[i] - counts[i])
		var row: Dictionary = {"clock": _clock, "frame": Engine.get_physics_frames(), "fresh": fresh,
			"result": result, "tool": tool.part_id, "instance": tool.get_instance_id(), "rid": tool.get_rid(),
			"pose": tool.global_transform, "until_before": until,
			"until_after": float(_depot_tool_admission_until.get(key, 0.0)), "cursor_before": cursor,
			"cursor_after": _depot_tool_admission_cursor.get(key, {}).duplicate(true),
			"route_entries": delta, "ground": worker._ground_point, "gate": _gate, "point": _point,
			"first_leg_clear": _first_leg_clear}
		probes.append(row)
		if fresh:
			print("CONTRAPTION_ALTERNATE_NATIVE clock=%.6f frame=%d tool=%s instance=%d rid=%s pose=%s result=%s until=%.6f route_entries=%s first_leg_clear=%s ground=%s gate=%s point=%s" % [
				row.clock, row.frame, row.tool, row.instance, row.rid, row.pose, row.result, row.until_after,
				row.route_entries, row.first_leg_clear, row.ground, row.gate, row.point])
		return result

	func _storage_approach(part: Node3D, outward: bool) -> Vector3:
		if _inside_probe: route_entries[0] += 1
		var result: Vector3 = super._storage_approach(part, outward)
		if _inside_probe: _gate = result
		return result

	func _supported_work_path(worker: RigidBody3D, machine: Node3D, from: Vector3, to: Vector3, planned: Array, prospective_depot_tool := false) -> Array[Vector3]:
		if _inside_probe: route_entries[1] += 1
		var result: Array[Vector3] = super._supported_work_path(worker, machine, from, to, planned, prospective_depot_tool)
		if _inside_probe and _first_path:
			_first_path = false
			_first_leg_clear = not result.is_empty()
		return result

	func _prospective_depot_tool_stance_reachable(point: Vector3, support: Object, worker: RigidBody3D, gate: Vector3) -> bool:
		if _inside_probe:
			route_entries[2] += 1
			_point = point
		return super._prospective_depot_tool_stance_reachable(point, support, worker, gate)

func _choose_tool_foot(worker: Node, side: int) -> void:
	for number in 100:
		var id := "tool_animation_%d" % number
		if absi(id.hash()) % 2 == side:
			worker.worker_id = id
			return

func _collect_tool_vertices(node: Node, root: Node3D, points: Array[Vector3]) -> void:
	if node is MeshInstance3D and node.mesh:
		var local: Transform3D = root.global_transform.affine_inverse() * node.global_transform
		for surface in node.mesh.get_surface_count():
			var vertices: PackedVector3Array = node.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
			for vertex in vertices: points.append(local * vertex)
	for child: Node in node.get_children(): _collect_tool_vertices(child, root, points)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if not is_instance_valid(yard): return
	for worker: Node in yard.workers:
		_watch_work_pose(worker)
		_watch_tool_fitting(worker)
		if not is_instance_valid(worker.equipped_tool) or not worker.foot_grip_valid: continue
		var tool: Node3D = worker.equipped_tool
		if tool.carrier != worker.tool_anchor: continue
		if not worker._pose.evaluated_valid: continue
		var head: Transform3D = worker.global_transform * worker._pose.evaluated_worker.affine_inverse() * worker._pose.evaluated_root
		var inverse := head.affine_inverse()
		var half: float = tool.definition.size.y * .5
		if worker.action in ["assemble", "repair"] and tool.kind == "assembly_tool" and worker.action_progress > .44 and worker.action_progress < .50:
			var toe: Transform3D = worker.foot_grip_transform
			var tip: Vector3 = toe.origin + toe.basis.y.normalized() * (.035 + worker.foot_tool_span())
			draw_distance = maxf(draw_distance, tip.distance_to(worker.work_point()))
		var bounds := AABB(Vector3(-.38, -.3, -.38), Vector3(.76, .68, .76))
		shaft_samples += 1
		if bounds.intersects_segment(inverse * tool.to_global(Vector3(0, -half, 0)), inverse * tool.to_global(Vector3(0, half, 0))) != null: shaft_intersections += 1
		# The pickaxe cutter is much wider than its shaft. Inspect actual reused
		# mesh vertices throughout the complete motion, not only contact frames.
		if _tick % 4 != 0: continue
		var tool_id := tool.get_instance_id()
		if not _tool_vertices.has(tool_id):
			var points: Array[Vector3] = []
			_collect_tool_vertices(tool.find_child("ExistingToolModel", true, false), tool, points)
			_tool_vertices[tool_id] = points
		var transform := inverse * tool.global_transform
		visual_samples += 1
		for point: Vector3 in _tool_vertices[tool_id]:
			if worker.action == "inspect" and worker.on_ground:
				var support_gap: float = worker.ground_normal.dot(tool.to_global(point)-worker._ground_point)
				if "--inspection-pose-debug" in OS.get_cmdline_user_args() and support_gap < inspection_support_gap and support_gap < .01:
					print("CONTRAPTION_INSPECTION_FLOOR tick=%d phase=%.4f gap=%.6f tool=%s workpoint=%s grip=%s axis=%s blocked=%s" % [_tick,worker.action_progress,support_gap,tool.kind,worker.work_point(),worker.tool_grip_transform.origin,worker.tool_grip_transform.basis.y,worker.tool_pose_blocked])
				inspection_support_gap = minf(inspection_support_gap,support_gap)
			if worker.action in ["assemble","tool_change"] and worker.on_ground:
				var support_gap: float = worker.ground_normal.dot(tool.to_global(point)-worker._ground_point)
				_work_tool_support[worker.action] = minf(float(_work_tool_support.get(worker.action,INF)),support_gap)
			if bounds.grow(-.03).has_point(transform * point):
				visual_intersections += 1
				break

func _watch_tool_fitting(worker: Node) -> void:
	if worker.action != "tool_change" or not is_instance_valid(worker.work_target): return
	var tool: Node3D = worker.work_target
	if tool.definition.get("category","") != "tool": return
	var id := tool.get_instance_id()
	var fitted: bool = tool.carrier == worker.tool_anchor
	var previous: Dictionary = _fitted_tools.get(id,{})
	if fitted and not previous.is_empty() and not previous.fitted:
		_fitting_contacts += 1
		_fitting_position_step = maxf(_fitting_position_step,tool.global_position.distance_to(previous.transform.origin))
		_fitting_rotation_step = maxf(_fitting_rotation_step,rad_to_deg(tool.global_basis.get_rotation_quaternion().angle_to(previous.transform.basis.get_rotation_quaternion())))
	_fitted_tools[id] = {"fitted":fitted,"transform":tool.global_transform}

func _watch_work_pose(worker: Node) -> void:
	var worker_id := worker.get_instance_id()
	if worker.action not in watched_work_actions or not worker._pose.evaluated_valid:
		_work_poses.erase(worker_id)
		return
	var pose: SkeletonModifier3D = worker._pose
	var previous: Dictionary = _work_poses.get(worker_id,{})
	if previous.get("kind","") != worker.action: previous = {}
	if previous.get("serial",-1) == pose.evaluation_serial: return
	var root: Transform3D = pose.evaluated_worker.affine_inverse()*pose.evaluated_root
	root.basis = pose.evaluated_basis.inverse()*pose.evaluated_root.basis
	var stats: Dictionary = _work_pose_stats.get(worker.action,{"samples":0,"knee":0.0,"ankle":0.0,"root":0.0,"angle":0.0,"tool":0.0,"tool_samples":0})
	var tool_id := 0
	var tool_rotation := Quaternion.IDENTITY
	if is_instance_valid(worker.equipped_tool) and worker.equipped_tool.carrier == worker.tool_anchor:
		tool_id = worker.equipped_tool.get_instance_id()
		tool_rotation = (pose.evaluated_basis.inverse()*worker.equipped_tool.global_basis).get_rotation_quaternion()
		stats.tool_samples += 1
		if previous.get("tool_id",0) == tool_id:
			var tool_step := rad_to_deg(tool_rotation.angle_to(previous.tool_rotation))
			stats.tool = maxf(stats.tool,tool_step)
			if tool_step >= 18.0 and "--tool-debug" in OS.get_cmdline_user_args():
				print("CONTRAPTION_WORK_TOOL_TURN action=",worker.action," tick=",_tick," serial=",pose.evaluation_serial," phase=",worker.action_progress," angle=",tool_step," grip=",worker.tool_grip_transform," blocked=",worker.tool_pose_blocked)
	var knees: Array[Vector3] = []
	var ankles: Array[Quaternion] = []
	for side in 2:
		var knee: Vector3 = pose.evaluated_basis.inverse()*(pose.evaluated_knees[side]-pose.evaluated_hips[side]).normalized()
		var ankle: Quaternion = (pose.evaluated_basis.inverse()*pose.evaluated_ankles[side]).get_rotation_quaternion()
		if not previous.is_empty():
			var knee_step := rad_to_deg(knee.angle_to(previous.knees[side]))
			var ankle_step := rad_to_deg(ankle.angle_to(previous.ankles[side]))
			if "--inspection-pose-debug" in OS.get_cmdline_user_args() and (knee_step > 12.0 or ankle_step > 18.0):
				print("CONTRAPTION_INSPECTION_POSE action=%s tick=%d serial=%d phase=%.4f side=%d work_side=%d knee=%.3f ankle=%.3f tool=%s target=%s stance=%s contact=%s blocked=%s workpoint=%s grip=%s axis=%s sole=%s oldsole=%s grounded=%s support=%s" % [worker.action,_tick,pose.evaluation_serial,worker.action_progress,side,worker.work_foot_side,knee_step,ankle_step,worker.equipped_tool.kind if is_instance_valid(worker.equipped_tool) else "none",worker.work_target.part_id if is_instance_valid(worker.work_target) else "none",worker.stance_valid,worker.foot_contact_ready(),worker.tool_pose_blocked,worker.work_point(),worker.foot_grip_transform.origin,worker.foot_grip_transform.basis.y,pose.evaluated_soles[side],previous.soles[side],pose.evaluated_grounded,pose._support[side].get_ref()])
			stats.knee = maxf(stats.knee,knee_step)
			stats.ankle = maxf(stats.ankle,ankle_step)
		knees.append(knee)
		ankles.append(ankle)
	if not previous.is_empty():
		stats.root = maxf(stats.root,root.origin.distance_to(previous.root.origin))
		stats.angle = maxf(stats.angle,rad_to_deg(root.basis.get_rotation_quaternion().angle_to(previous.root.basis.get_rotation_quaternion())))
	_work_poses[worker_id] = {"kind":worker.action,"serial":pose.evaluation_serial,"knees":knees,"ankles":ankles,"root":root,"soles":pose.evaluated_soles.duplicate(),"tool_id":tool_id,"tool_rotation":tool_rotation}
	stats.samples += 1
	_work_pose_stats[worker.action] = stats
	if worker.action == "inspect":
		inspection_pose_samples = stats.samples
		inspection_knee_step = stats.knee
		inspection_ankle_step = stats.ankle
		inspection_root_step = stats.root
		inspection_root_angle = stats.angle

func _run() -> void:
	var floor := StaticBody3D.new()
	floor.position.y = -.5
	add_child(floor)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(160, 1, 160)
	shape.shape = box
	floor.add_child(shape)
	yard = Yard.new()
	add_child(yard)
	yard.work_paused = true
	await _advance(.3)
	_park_fauna()
	if "--tool-alternate-admission" in OS.get_cmdline_user_args():
		await _run_alternate_admission()
		_finish()
		return
	for arg: String in OS.get_cmdline_user_args():
		if arg in ["--tool-foot=left", "--tool-foot=right"]:
			_choose_tool_foot(yard.workers[0], 1 if arg.ends_with("right") else 0)
	for worker: Node in yard.workers:
		worker.paused = worker != yard.workers[0]
		worker.action_contact.connect(func(kind: String) -> void:
			if kind == "tool_change": changes += 1
			if kind == "repair": repair_contacts += 1
			if kind == "inspect": inspection_contacts += 1
			if kind in ["tool_change", "assemble", "maintenance", "repair", "inspect"]:
				planted_contacts += 1
				var toe: Transform3D = worker.foot_grip_transform
				var tip: Vector3 = toe.origin + toe.basis.y.normalized() * (.035 + worker.foot_tool_span())
				invalid_contact = invalid_contact or not worker.on_ground or not worker.stance_valid or tip.distance_to(worker.work_point()) > .18)
	var stock: int = yard.loose_parts.size()
	var mallets: Array = yard.loose_parts.filter(func(p: Node) -> bool: return p.kind == "assembly_tool")
	for tool: Node in mallets: tool.jammed = true
	_check(yard.plan_blueprint({"name": "Tool fixture", "parts": [Plans.piece("frame", "bracket", Vector3.ZERO), Plans.piece("drive", "motor", Vector3(0, .35, 0), "frame")]}), "tool fixture selects a physical stock build")
	yard.work_paused = false
	await _advance(.4)
	_check(yard.coordinator.active_jobs.is_empty() and str(yard.coordinator.blocked).contains("compatible"), "missing compatible healthy tools block work with useful feedback")
	for tool: Node in mallets: tool.jammed = false
	var built := await _wait_until(func() -> bool: return _built_selected(), 80.0)
	_check(built and changes > 0, "helper fetches a real mallet and fits it at the animation contact before building")
	if not built: _dump_workers(); _finish(); return
	var worker: Node = yard.workers.filter(func(w: Node) -> bool: return is_instance_valid(w.equipped_tool))[0]
	_check(worker._skeleton.get_bone_count() == 9 and worker._skeleton.find_bone("toe.L") >= 0 and worker._skeleton.find_bone("toe.R") >= 0, "corrected imported rig contains both named gripping toes and mirrored leg chains")
	_check(planted_contacts > 0 and not invalid_contact, "timed tool events require a planted support foot and evaluated toe/tool contact within 18 cm")
	var tool: Node = worker.equipped_tool
	var id: String = tool.part_id
	_check(tool.carrier == worker.tool_anchor and tool.get_meta(&"equipped_worker", "") == worker.worker_id and worker.mass >= 27, "same finite-mass tool body follows the working-foot fixture and contributes helper weight")
	_check(yard.loose_parts.size() == stock - 2 and mallets.all(func(t: Node) -> bool: return is_instance_valid(t)), "tool fitting consumes no tool resource while installation consumes exactly two components")
	_check(not yard.reserve_job({"id": "duplicate-tool", "kind": "salvage", "part": tool, "target": yard.storage}, [yard.workers[1]]), "equipped tool cannot be double claimed as salvage")
	var motor: Node = yard.selected_assembly.parts.drive
	motor.wear = .04
	motor.parameters.maintenance_due = yard.maintenance_clock - .1
	var health_before: float = motor.health
	var maintained := await _wait_until(func() -> bool: return motor.wear < .01 and float(motor.parameters.maintenance_due) > yard.maintenance_clock, 30.0)
	_check(maintained and motor.health == health_before, "scheduled physical tool inspection lubricates bounded wear without restoring damage health")
	motor.take_damage(20.0, motor.global_position, null, &"hit")
	var repaired := await _wait_until(func() -> bool: return motor.health > 99.0, 30.0)
	_check(repaired and repair_contacts > 0, "a damaged installed component receives real toe-held repair work at the contact event")
	yard.work_paused = true
	var snapshot: Dictionary = JSON.parse_string(JSON.stringify(yard.serialize()))
	yard.restore(snapshot)
	await _advance(.3)
	var restored: Array = yard.workers.filter(func(w: Node) -> bool: return is_instance_valid(w.equipped_tool) and w.equipped_tool.part_id == id)
	_check(restored.size() == 1 and restored[0].equipped_tool.carrier == restored[0].tool_anchor and not restored[0].equipped_tool.get_meta(&"awaiting_setdown", false), "JSON restore retains exactly one owner and the original reusable tool identity")
	yard.work_paused = false
	yard.plan_dismantle()
	var dismantled := await _wait_until(func() -> bool: return yard.selected_assembly.parts.is_empty(), 80.0)
	_check(dismantled and yard.workers.any(func(w: Node) -> bool: return is_instance_valid(w.equipped_tool) and w.equipped_tool.kind == "salvage_tool"), "same worker returns its mallet and fits the compatible physical fastener pickaxe for dismantling")
	_check(yard.loose_parts.size() == stock, "dismantling returns the component while both reusable tool kinds remain conserved")
	_check(shaft_samples > 500 and shaft_intersections == 0, "actual equipped tool shafts stay outside the rigid cube through pickup, travel, work and retraction")
	_check(visual_samples > 125 and visual_intersections == 0, "the actual wide cutter and mallet meshes stay outside the cube throughout complete tool motions")
	_check(draw_distance > .025 and draw_distance < .18, "the toe-held mallet visibly draws back before its existing grounded contact event")
	_check(inspection_contacts >= 2 and not invalid_contact and inspection_support_gap >= .01-.00001, "actual pre-work inspections retain planted timed toe/tool contact and keep the complete tool at least 10 mm above support")
	_check(inspection_pose_samples > 500 and inspection_knee_step < 12.0 and inspection_ankle_step < 18.0 and inspection_root_step < .025 and inspection_root_angle < 6.0,
		"actual inspection preparation, contact and release keep the evaluated cube, knees and ankles continuous")
	for kind: String in ["assemble","tool_change"]:
		var stats: Dictionary = _work_pose_stats.get(kind,{})
		var support_gap: float = _work_tool_support.get(kind,-INF)
		_check(stats.get("samples",0) > 100 and stats.get("knee",INF) < 12.0 and stats.get("ankle",INF) < 18.0
			and stats.get("root",INF) < .025 and stats.get("angle",INF) < 6.0 and support_gap >= .01-.00001,
			"actual %s preparation/contact/release keeps evaluated cube/legs continuous and full retained tool at least 10 mm above support" % kind)
		print("CONTRAPTION_WORK_POSE action=%s samples=%d knee=%.3f ankle=%.3f root=%.6f angle=%.3f tool_gap=%.6f" % [kind,stats.get("samples",0),stats.get("knee",INF),stats.get("ankle",INF),stats.get("root",INF),stats.get("angle",INF),support_gap])
	_check(_fitting_contacts >= 2 and _fitting_position_step < .03 and _fitting_rotation_step < 8.0,
		"real fitting contact retains stock position/orientation before the same foot raises it")
	print("CONTRAPTION_TOOL_FITTING contacts=%d position_step=%.6f rotation_step=%.3f" % [_fitting_contacts,_fitting_position_step,_fitting_rotation_step])
	print("CONTRAPTION_TOOLS inspections=%d inspection_tool_support_gap=%.6f pose_samples=%d knee_step=%.3f ankle_step=%.3f root_step=%.6f root_angle=%.3f" % [inspection_contacts,inspection_support_gap,inspection_pose_samples,inspection_knee_step,inspection_ankle_step,inspection_root_step,inspection_root_angle])
	_finish()

func _alternate_search(job: Dictionary) -> Array:
	# No physics step runs unpaused: this is the ordinary synchronous search.
	var paused_before: bool = yard.work_paused
	yard.work_paused = false
	var crew: Array = yard.coordinator._available_crew(job)
	yard.work_paused = paused_before
	return crew

func _alternate_source_state(tool: RigidBody3D) -> Array:
	var shape: CollisionShape3D = tool.get_node("PhysicalShape")
	return [yard.work_tool_source_stamp(tool).state, tool.mass, tool.inertia,
		tool.center_of_mass, tool.scale, shape.shape.get_instance_id(), shape.transform,
		tool.linear_velocity, tool.angular_velocity]

func _alternate_cooldown(job: Dictionary, worker: RigidBody3D) -> bool:
	var trace: Node = yard.coordinator
	var key: int = worker.get_instance_id()
	var until: float = float(trace._depot_tool_admission_until.get(key, 0.0))
	var cursor: Dictionary = trace._depot_tool_admission_cursor.get(key, {}).duplicate(true)
	var counts: Array[int] = trace.route_entries.duplicate()
	var calls: int = 0
	var unchanged: bool = true
	var start: float = trace._clock
	for attempt in 240:
		if trace._clock >= until: break
		var previous: int = trace.probes.size()
		var crew: Array = _alternate_search(job)
		unchanged = unchanged and crew.is_empty() and trace.probes.size() == previous + 1
		if trace.probes.size() == previous + 1:
			var row: Dictionary = trace.probes[-1]
			unchanged = unchanged and not row.fresh and not row.result and row.route_entries == [0, 0, 0]
		unchanged = unchanged and trace.route_entries == counts \
			and float(trace._depot_tool_admission_until.get(key, 0.0)) == until \
			and trace._depot_tool_admission_cursor.get(key, {}) == cursor
		calls += 1
		await get_tree().physics_frame
	var ok: bool = unchanged and calls > 0 and trace._clock >= until
	_check(ok, "every before-deadline search preserves the native route entries, worker deadline and source cursor")
	print("CONTRAPTION_ALTERNATE_COOLDOWN calls=%d start=%.6f until=%.6f end=%.6f route_entries_delta=%s cursor_unchanged=%s" % [
		calls, start, until, trace._clock, [trace.route_entries[0]-counts[0], trace.route_entries[1]-counts[1], trace.route_entries[2]-counts[2]], unchanged])
	return ok

func _run_alternate_admission() -> void:
	_check(yard.workers.size() == 3 and yard.coordinator.active_jobs.is_empty(), "alternate fixture starts with the original three workers and no lease")
	if yard.workers.size() != 3 or not yard.coordinator.active_jobs.is_empty(): return
	var worker: RigidBody3D = yard.workers[0]
	for other: Node in yard.workers: other.paused = other != worker
	var stock: Array[RigidBody3D] = []
	for id: String in ["stock_25", "stock_26", "stock_27"]:
		var found: RigidBody3D
		for part: RigidBody3D in yard.loose_parts:
			if part.part_id == id: found = part; break
		if not is_instance_valid(found):
			_check(false, "missing original " + id)
			return
		stock.append(found)
	var original_stock: bool = stock.all(func(tool: RigidBody3D) -> bool:
		return tool.kind == "assembly_tool" and tool.get_parent() == yard.storage \
			and tool.get_meta(&"stored", false) and not yard._part_reserved(tool) and yard.tool_compatible(tool, "build"))
	_check(original_stock and not is_instance_valid(worker.equipped_tool), "default mallets remain healthy stored originals and the original worker has no granted tool")
	if not original_stock or is_instance_valid(worker.equipped_tool): return

	# Initial observer setup retains every original script field, including clock.
	var trace: Node = yard.coordinator
	var fields: Dictionary = {}
	for property: Dictionary in trace.get_property_list():
		if (int(property.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0: fields[property.name] = trace.get(property.name)
	trace.set_script(AlternateAdmissionTrace)
	for field: String in fields: trace.set(field, fields[field])
	var grip: Vector3 = stock[1].global_transform * Vector3(0, -float(stock[1].definition.size.y) * .45, 0)
	var blocker: StaticBody3D = StaticBody3D.new()
	blocker.name = "InitialMallet26ClearanceBlocker"
	blocker.collision_layer = 1
	blocker.collision_mask = 1
	blocker.position = Vector3(grip.x, 1.1, grip.z)
	var collision: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(1.6, 1.4, 1.6)
	collision.shape = box
	blocker.add_child(collision)
	add_child(blocker)
	await _advance(.2)
	var baseline: Array = []
	for tool: RigidBody3D in stock: baseline.append(_alternate_source_state(tool))
	var worker_identity: Array = [worker.get_instance_id(), worker.get_rid(), worker.worker_id]
	var inventory: Dictionary = _inventory()
	print("CONTRAPTION_ALTERNATE_SETUP worker=%s blocker=%s size=%s originals=%s" % [worker_identity, blocker.global_position, box.size, baseline])

	# Walk the front aisle normally; the first depot leg stays clear of the box.
	for local: Vector3 in [Vector3(-3, 0, 3), Vector3(-3, 0, 5.5), Vector3(-8, 0, 5.5)]:
		worker.navigate_to(yard.to_global(local))
		var arrived: bool = await _wait_until(func() -> bool: return worker.at_target(.3) and worker.on_ground, 25.0)
		_check(arrived, "original worker navigates to the controlled front-aisle point " + str(local))
		if not arrived: _dump_workers(); return
	worker.stop_navigation()
	var settled: bool = await _wait_until(func() -> bool:
		return worker.on_ground and worker.gait_speed < .08 and worker.linear_velocity.length() < .12 \
			and worker.action.is_empty() and not worker.head_leap.active() and trace._free_worker_return_ready(worker), 5.0)
	_check(settled, "native grounded worker settles without any pose, velocity or clock reset")
	if not settled: _dump_workers(); return
	var planned: bool = yard.plan_blueprint({"name": "Alternate admission", "parts": [Plans.piece("frame", "bracket", Vector3.ZERO)]})
	_check(planned and _inventory() == inventory, "real single-bracket plan uses existing finite stock without a grant")
	if not planned: return
	yard.work_paused = false
	var jobs: Array[Dictionary] = yard.work_jobs()
	yard.work_paused = true
	var job: Dictionary = {}
	for candidate: Dictionary in jobs:
		if candidate.kind == "build" and candidate.target == yard.selected_assembly.parts.frame: job = candidate; break
	_check(not job.is_empty() and str(job.get("blocked", "missing job")).is_empty(), "ordinary unblocked build job is available for one original worker")
	if job.is_empty() or not str(job.get("blocked", "missing job")).is_empty(): return

	# Round one proves genuine frame expiry while source 27 is still unreserved.
	# Round two earns a new proof and consumes it synchronously in reserve_job.
	for round_index in 2:
		_check(yard.tool_for_job(job, worker) == stock[1], "actual nearest original is stock_26 before the fresh search")
		var before: int = trace.probes.size()
		var crew: Array = _alternate_search(job)
		var observed: bool = trace.probes.size() == before + 1
		var denied: Dictionary = trace.probes[-1] if observed else {}
		var blocked26: bool = observed and crew.is_empty() and denied.fresh and not denied.result \
			and denied.instance == stock[1].get_instance_id() and denied.first_leg_clear \
			and denied.route_entries[0] == 1 and denied.route_entries[1] >= 1
		_check(blocked26, "fresh original stock_26 admission is natively refused after its actual clear first leg")
		if not blocked26: return
		var cursor: Dictionary = trace._depot_tool_admission_cursor.get(worker.get_instance_id(), {}).get("build", {})
		_check(yard.tool_for_job(job, worker, cursor) == stock[2], "actual failed-source cursor selects original stock_27 without a probe")
		if not await _alternate_cooldown(job, worker): return
		before = trace.probes.size()
		crew = _alternate_search(job)
		observed = trace.probes.size() == before + 1
		var admitted: Dictionary = trace.probes[-1] if observed else {}
		var clear27: bool = observed and crew.size() == 1 and crew[0] == worker and admitted.fresh and admitted.result \
			and admitted.instance == stock[2].get_instance_id() and admitted.first_leg_clear \
			and admitted.route_entries[0] == 1 and admitted.route_entries[2] > 0
		_check(clear27, "next naturally allowed interval admits original stock_27 through the unchanged native predicates")
		if not clear27: return
		var counts: Array[int] = trace.route_entries.duplicate()
		_check(yard.tool_for_job(job, worker) == stock[2] and trace.route_entries == counts, "same-frame pin returns the actual admitted original without a route entry")
		if round_index == 0:
			var stale: Dictionary = job.duplicate(true)
			var frame_before: int = Engine.get_physics_frames()
			var clock_before: float = trace._clock
			await get_tree().physics_frame
			var unchanged_source: bool = _alternate_source_state(stock[2]) == baseline[2] and not yard._part_reserved(stock[2])
			var expired: bool = Engine.get_physics_frames() > frame_before and unchanged_source \
				and yard.tool_for_job(stale, worker) == null and trace.route_entries == counts
			_check(expired, "genuine copied pin expires on the next native frame before reservation with its original source unchanged")
			print("CONTRAPTION_ALTERNATE_EXPIRY frame_before=%d frame_after=%d clock_before=%.6f clock_after=%.6f source_unchanged=%s reserved=%s" % [
				frame_before, Engine.get_physics_frames(), clock_before, trace._clock, unchanged_source, yard._part_reserved(stock[2])])
			if not expired or not await _alternate_cooldown(job, worker): return
		else:
			var area_reason: String = trace._work_area_reason(job, crew)
			yard.work_paused = false
			var reserved: bool = yard.reserve_job(job, crew) if area_reason.is_empty() else false
			yard.work_paused = true
			var lease: Dictionary = yard._reservations.get(job.id, {})
			var exact: bool = reserved and job.get("tool") == stock[2] and lease.get("tool_instance", 0) == stock[2].get_instance_id() \
				and yard._part_reserved(stock[2]) and not yard._part_reserved(stock[1]) and not job.has("_prospective_tool")
			_check(exact and trace.route_entries == counts, "ordinary work-area selection and same-frame reservation consume exactly proven stock_27 without another admission burst")
			print("CONTRAPTION_ALTERNATE_RESERVE atomic_reservation_only=true full_tool_operation=false exact=%s tool_instance=%s area_reason=%s" % [exact, lease.get("tool_instance", 0), area_reason])
			if reserved: yard.release_job(job)

	var fresh: Array[Dictionary] = []
	for row: Dictionary in trace.probes:
		if row.fresh: fresh.append(row)
	var cadence: bool = fresh.size() == 4
	for i in fresh.size():
		cadence = cadence and is_equal_approx(float(fresh[i].until_after), float(fresh[i].clock) + .6)
		if i > 0: cadence = cadence and float(fresh[i].clock) >= float(fresh[i-1].until_after)
	_check(cadence, "all four fresh native admission bursts retain the exact worker-wide .6-second cadence")
	var preserved: bool = _inventory() == inventory and [worker.get_instance_id(), worker.get_rid(), worker.worker_id] == worker_identity
	for i in stock.size(): preserved = preserved and _alternate_source_state(stock[i]) == baseline[i] and not yard._part_reserved(stock[i])
	_check(preserved, "all three original finite mallets preserve body/RID/shape/pose/condition/custody and remain unreserved after normal lease release")
	print("CONTRAPTION_ALTERNATE_SCOPE native_route_entry_calls=%s fresh_bursts=%d total_native_ray_shape_count=unmeasured worker_clock_not_reset=true" % [trace.route_entries, fresh.size()])

func _finish() -> void:
	print("CONTRAPTION_TOOLS %s ticks=%d" % ["PASS" if failures == 0 else "FAIL (%d)" % failures, _tick])
	Shortcuts.graceful_quit(0 if failures == 0 else 1)

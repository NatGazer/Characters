extends "res://.claude/tests/contraptions/tools.gd"
## The home bodies are held as a native isolation fixture; tool retrieval,
## boarding, fitting, replacement and service use the actual automatic scheduler.
const Assembly := preload("res://Components/Contraptions/contraption_assembly.gd")
const Bay := preload("res://Components/Contraptions/protected_bay.gd")
const ToolAccess := preload("res://Components/Contraptions/worker_tool_access.gd")
var home: Node3D
var worker: RigidBody3D
var fitting_contacts := 0
var invalid_contacts := 0
var boarded := false
var camera: Camera3D
var _captured_fitting := false
var _recovery_poses: Dictionary = {}
var _recovery_samples := 0
var _recovery_knee_step := 0.0
var _recovery_ankle_step := 0.0
var _recovery_tool_angle := 0.0
var _recovery_root_step := 0.0
var _recovery_root_angle := 0.0
var _recovery_floor_samples := 0
var _recovery_tool_floor := INF

func _physics_process(delta: float) -> void:
	var old_hits := shaft_intersections
	super._physics_process(delta)
	if is_instance_valid(yard):
		for helper: Node in yard.workers: _watch_recovery(helper)
	if shaft_intersections > old_hits and "--tool-debug" in OS.get_cmdline_user_args():
		for helper: Node in yard.workers:
			if is_instance_valid(helper.equipped_tool):
				var head: Transform3D = helper.global_transform * helper._pose.evaluated_worker.affine_inverse() * helper._pose.evaluated_root
				print("CONTRAPTION_MOBILE_TOOL_HIT tick=", _tick, " action=", helper.action, " phase=", helper.action_progress, " side=", helper.work_foot_side, " body=", helper.global_position, " head=", head, " grip=", helper.foot_grip_transform, " tool=", helper.equipped_tool.global_transform, " serial=", helper._pose.evaluation_serial, " release=", helper._pose._work_release, " blocked=", helper.tool_pose_blocked)
	if is_instance_valid(worker) and is_instance_valid(home): boarded = boarded or worker.supported_by(home)
	if not _captured_fitting and is_instance_valid(worker) and worker.action == "tool_change" and worker.action_progress > .60 and worker.action_progress < .64 and DisplayServer.get_name() != "headless" and "--tool-capture" in OS.get_cmdline_user_args():
		_captured_fitting = true
		_capture.call_deferred("fitting")

func _watch_recovery(helper: Node) -> void:
	var id := helper.get_instance_id()
	var pose: SkeletonModifier3D = helper._pose
	if not is_instance_valid(helper.equipped_tool) or not pose.evaluated_valid:
		_recovery_poses.erase(id)
		return
	var tool: Node3D = helper.equipped_tool
	if tool.carrier != helper.tool_anchor: return
	var previous: Dictionary = _recovery_poses.get(id, {})
	if previous.get("serial", -1) == pose.evaluation_serial: return
	if previous.get("tool", tool.get_instance_id()) != tool.get_instance_id(): previous = {}
	var knees: Array[Vector3] = []
	var ankles: Array[Quaternion] = []
	var root: Transform3D = pose.evaluated_worker.affine_inverse() * pose.evaluated_root
	root.basis = pose.evaluated_basis.inverse() * pose.evaluated_root.basis
	var rig_basis: Basis = helper.global_basis * pose.evaluated_worker.basis.inverse() * pose.evaluated_basis
	var tool_rotation := (rig_basis.inverse() * tool.global_basis).get_rotation_quaternion()
	var recovery: bool = helper.action.is_empty() or previous.get("empty", false)
	for side in 2:
		var knee: Vector3 = pose.evaluated_basis.inverse() * (pose.evaluated_knees[side] - pose.evaluated_hips[side]).normalized()
		var ankle: Quaternion = (pose.evaluated_basis.inverse() * pose.evaluated_ankles[side]).get_rotation_quaternion()
		if recovery and not previous.is_empty():
			var knee_step := rad_to_deg(knee.angle_to(previous.knees[side]))
			var ankle_step := rad_to_deg(ankle.angle_to(previous.ankles[side]))
			_recovery_knee_step = maxf(_recovery_knee_step, knee_step)
			_recovery_ankle_step = maxf(_recovery_ankle_step, ankle_step)
			if "--tool-debug" in OS.get_cmdline_user_args() and (knee_step > 12.0 or ankle_step > 18.0):
				print("CONTRAPTION_MOBILE_TOOL_RECOVERY tick=", _tick, " action=", helper.action, " phase=", helper.action_progress, " side=", side, " knee=", knee_step, " ankle=", ankle_step, " release=", pose._work_release, " blocked=", helper.tool_pose_blocked, " body=", helper.global_position, " hip=", pose.evaluated_hips[side], " knee_at=", pose.evaluated_knees[side], " sole=", pose.evaluated_soles[side], " old_body=", previous.body, " old_hip=", previous.hips[side], " old_knee=", previous.knee_positions[side], " old_sole=", previous.soles[side], " terrain=", pose._terrain_points[side])
		knees.append(knee)
		ankles.append(ankle)
	if recovery and not previous.is_empty():
		_recovery_samples += 1
		_recovery_root_step = maxf(_recovery_root_step, root.origin.distance_to(previous.root.origin))
		_recovery_root_angle = maxf(_recovery_root_angle, rad_to_deg(root.basis.get_rotation_quaternion().angle_to(previous.root.basis.get_rotation_quaternion())))
		var angle := rad_to_deg(tool_rotation.angle_to(previous.tool_rotation))
		_recovery_tool_angle = maxf(_recovery_tool_angle, angle)
		if angle >= 18.0 and "--tool-debug" in OS.get_cmdline_user_args():
			print("CONTRAPTION_MOBILE_TOOL_TURN tick=", _tick, " action=", helper.action, " phase=", helper.action_progress, " angle=", angle)
	_recovery_poses[id] = {"serial": pose.evaluation_serial, "tool": tool.get_instance_id(), "empty": helper.action.is_empty(), "knees": knees, "ankles": ankles, "root": root, "tool_rotation": tool_rotation, "body": helper.global_position, "hips": pose.evaluated_hips.duplicate(), "knee_positions": pose.evaluated_knees.duplicate(), "soles": pose.evaluated_soles.duplicate()}
	var side: int = helper.tool_foot_side()
	if not helper.action.is_empty() or not pose._terrain_points[side].is_finite(): return
	if not _tool_vertices.has(tool.get_instance_id()): return
	var points: Array[Vector3] = _tool_vertices[tool.get_instance_id()]
	if points.is_empty(): return
	_recovery_floor_samples += 1
	for point: Vector3 in points:
		var gap: float = pose._sole_normals[side].dot(tool.to_global(point) - pose._terrain_points[side])
		_recovery_tool_floor = minf(_recovery_tool_floor, gap)
		if gap < .005 - .00001 and "--tool-debug" in OS.get_cmdline_user_args():
			print("CONTRAPTION_MOBILE_TOOL_FLOOR tick=", _tick, " gap=", gap, " tool=", tool.kind, " support=", pose._terrain_points[side], " grip=", helper.tool_grip_transform.origin)
			break

func _watch_tool_fitting(helper: Node) -> void:
	var previous: Dictionary = _fitted_tools.get(helper.work_target.get_instance_id(), {}) if is_instance_valid(helper.work_target) else {}
	super._watch_tool_fitting(helper)
	if helper.action == "tool_change" and is_instance_valid(helper.work_target) and helper.work_target.carrier == helper.tool_anchor and not previous.is_empty() and not previous.fitted and "--tool-debug" in OS.get_cmdline_user_args():
		print("CONTRAPTION_MOBILE_TOOL_FIT tick=", _tick, " phase=", helper.action_progress, " side=", helper.work_foot_side, " step=", helper.work_target.global_position.distance_to(previous.transform.origin), " hip=", helper.evaluated_hip(helper.work_foot_side), " target=", helper.work_point(), " grip=", helper.foot_grip_transform.origin, " blocked=", helper.tool_pose_blocked)

func _run() -> void:
	var floor := StaticBody3D.new()
	floor.position.y = -.5
	add_child(floor)
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(160, 1, 160)
	collision.shape = box
	floor.add_child(collision)
	var ground_mesh := MeshInstance3D.new()
	var ground := BoxMesh.new()
	ground.size = box.size
	ground_mesh.mesh = ground
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(.31, .35, .37)
	stone.roughness = .92
	ground_mesh.material_override = stone
	floor.add_child(ground_mesh)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(.55, .65, .75)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(.85, .92, 1)
	environment.environment.ambient_light_energy = .85
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -25, 0)
	sun.light_color = Color(1, .94, .84)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	add_child(sun)
	yard = Yard.new()
	add_child(yard)
	yard.work_paused = true
	await _advance(.4)
	_park_fauna()
	for enemy: Node in yard.enemies: enemy.queue_free()
	yard.enemies.clear()
	for original: Node in yard.assemblies: original.queue_free()
	yard.assemblies.clear()
	yard._plans.clear()
	await _advance(.1)
	home = Assembly.new()
	yard.add_child(home)
	home.global_position = Vector3(8, .94, -10)
	yard.assemblies.append(home)
	yard.selected_assembly = home
	var design := Bay.blueprint()
	for descriptor: Dictionary in design.parts:
		var body: RigidBody3D = home.add_part(descriptor.kind, Plans.transform_of(descriptor), true, descriptor.id, descriptor.get("parameters", {}))
		body.freeze = true
		if descriptor.parent != "": home.connect_parts(descriptor.parent, descriptor.id, descriptor.socket_a, descriptor.socket_b, descriptor.joint)
	# Only this healthy station's real maintenance schedule participates; body
	# layout and complete physical construction are covered by protected_bay_build.
	yard._plans[home.get_instance_id()] = design.parts.filter(func(d: Dictionary) -> bool: return d.id == "work")
	worker = yard.workers[0]
	for helper: Node in yard.workers: helper.paused = helper != worker
	for number in 100:
		var id := "mobile_tool_%d" % number
		if absi(id.hash()) % 2 == (1 if "--tool-foot=right" in OS.get_cmdline_user_args() else 0): worker.worker_id = id; break
	worker.global_position = home.parts.entry.to_global(Vector3(0, .1, 1.65)) + Vector3.UP * worker.ride_height
	_watch_fitting()
	camera = Camera3D.new()
	add_child(camera)
	camera.global_position = home.parts.cargo.global_position + Vector3(-3, 1.4, 4)
	camera.look_at(home.parts.cargo.global_position + Vector3(0, -.1, .5))
	camera.current = true
	var mallets: Array = yard.loose_parts.filter(func(p: Node) -> bool: return p.kind == "assembly_tool")
	var original: RigidBody3D = mallets[0]
	var spare: RigidBody3D = mallets[1]
	var original_id: String = original.part_id
	var spare_id: String = spare.part_id
	var inventory := _inventory()
	_check(yard.store_part(original, home.parts.cargo) and original.scale.is_equal_approx(Vector3.ONE) and original.get_meta(&"stored_tool_rack", false), "the same full-sized five-kilogram mallet clips outside the secured mobile container")
	_check(yard.tool_for_job({"kind": "maintenance"}, worker) == original and mallets.all(func(mallet: Node) -> bool: return not mallet.jammed), "automatic tool selection uses the actual nearby clipped mallet while healthy compatible depot stock remains available")
	var source_pose := spare.global_transform
	_check(not yard.store_part(spare, home.parts.cargo) and spare.global_transform.is_equal_approx(source_pose) and spare.get_parent() == yard.storage, "an occupied one-tool clip refuses a second tool without moving or consuming it")
	_check(is_equal_approx(home.parts.cargo.cargo_mass, 5.0) and not ToolAccess.fetch_stance(worker, original).is_empty(), "clip mass belongs to its actual container and retrieval has a supported finite-reach stance")
	_check(home.parts.cargo.center_of_mass.distance_to(original.position * original.mass / home.parts.cargo.mass) < .00001, "the exterior tool contributes its actual clipped position to the finite native container COM")
	await _capture("clipped")
	var station: RigidBody3D = home.parts.work
	station.wear = .04
	station.parameters.maintenance_due = yard.maintenance_clock - .1
	yard.work_paused = false
	var fitting := await _wait_until(func() -> bool: return worker.action == "tool_change" and worker.work_target == original and worker.action_progress > .12 and worker.action_progress < .3, 40.0)
	_check(fitting and fitting_contacts == 0 and original.get_parent() == home.parts.cargo, "pre-contact fitting reserves the exact clipped body without changing its owner")
	if not fitting:
		_dump_workers()
		print("CONTRAPTION_MOBILE_TOOL_BLOCKED ", yard.coordinator.blocked, " retries=", yard.coordinator._retry_reasons)
		_finish()
		return
	var rack_pose: Transform3D = home.parts.cargo.global_transform
	home.parts.cargo.global_position += Vector3(0, 0, .03)
	home.parts.cargo.linear_velocity = Vector3(0, 0, .2)
	await _advance(.1)
	_check(worker.current_job_id == "" and worker.needs.contains("rack shifted") and original.get_meta(&"stored", false), "actual rack creep below boarding speed still interrupts the captured fitting pose before tool ownership changes")
	home.parts.cargo.global_transform = rack_pose
	home.parts.cargo.linear_velocity = Vector3.ZERO
	yard.work_paused = true
	await _advance(.1)
	_check(yard.coordinator.active_jobs.is_empty() and yard._reservations.is_empty() and original.get_meta(&"stored", false), "interrupted fitting releases its atomic lease and leaves the same tool secured in its clip")
	var fitting_save: Dictionary = JSON.parse_string(JSON.stringify(yard.serialize()))
	yard.restore(fitting_save)
	await get_tree().process_frame
	await get_tree().process_frame
	home = yard.selected_assembly
	for body: RigidBody3D in home.parts.values(): body.freeze = true
	_park_fauna()
	worker = yard.workers[0]
	_watch_fitting()
	station = home.parts.work
	original = yard.loose_parts.filter(func(p: Node) -> bool: return p.part_id == original_id)[0]
	spare = yard.loose_parts.filter(func(p: Node) -> bool: return p.part_id == spare_id)[0]
	_check(original.get_parent() == home.parts.cargo and original.scale.is_equal_approx(Vector3.ONE) and not is_instance_valid(worker.equipped_tool) and _inventory() == inventory, "interrupted fitting JSON restores one clipped original and no invented equipped copy")
	yard.work_paused = false
	var serviced := await _wait_until(func() -> bool: return station.wear < .01 and worker.equipped_tool == original and fitting_contacts > 0, 70.0)
	_check(serviced and boarded and invalid_contacts == 0 and worker.equipped_tool == original and original.carrier == worker.tool_anchor, "automatic maintenance boards real support, fits the exact clipped mallet at planted foot contact and services the station")
	if not serviced: _dump_workers(); print("CONTRAPTION mobile blocked ", yard.coordinator.blocked); _finish(); return
	yard.work_paused = true
	await _advance(.15)
	var stock_count: int = yard.loose_parts.size()
	var original_health: float = station.health
	spare.jammed = false
	_check(yard.store_part(spare, home.parts.cargo), "a genuinely freed clip accepts the existing compatible spare")
	station.wear = .04
	station.parameters.maintenance_due = yard.maintenance_clock - .1
	yard.work_paused = false
	var working := await _wait_until(func() -> bool: return worker.action == "maintenance", 35.0)
	_check(working, "the original toe-held tool begins the next due service before failing")
	original.jammed = true
	await _advance(.1)
	_check(worker.current_job_id == "" and worker.needs.contains("tool failed") and is_equal_approx(station.wear, .04), "failure interrupts work immediately with compatible-tool feedback and preserves component wear")
	var replaced := await _wait_until(func() -> bool: return worker.equipped_tool == spare and station.wear < .01, 70.0)
	_check(replaced and original.get_parent() == home.parts.cargo and original.get_meta(&"stored_tool_rack", false) and original.jammed, "automatic replacement fetches the exact healthy spare and returns the failed retained tool to the freed physical clip")
	if not replaced:
		_dump_workers()
		print("CONTRAPTION_MOBILE_TOOL_BLOCKED ", yard.coordinator.blocked, " retries=", yard.coordinator._retry_reasons, " action=", worker.action, " work=", worker.work_point(), " grip=", worker.foot_grip_transform.origin, " tool_pose=", worker.tool_pose_blocked)
		_finish()
		return
	_check(fitting_contacts >= 2 and invalid_contacts == 0 and station.health == original_health and yard.loose_parts.size() == stock_count and _inventory() == inventory, "tool replacement and scheduled wear service preserve all finite bodies and damage health")
	await _capture("serviced")
	yard.work_paused = true
	var snapshot: Dictionary = JSON.parse_string(JSON.stringify(yard.serialize()))
	yard.restore(snapshot)
	await _advance(.4)
	_park_fauna()
	home = yard.selected_assembly
	worker = yard.workers[0]
	var restored_original: Array = yard.loose_parts.filter(func(p: Node) -> bool: return p.part_id == original_id)
	_check(restored_original.size() == 1 and restored_original[0].get_parent() == home.parts.cargo and restored_original[0].scale.is_equal_approx(Vector3.ONE) and worker.equipped_tool.part_id == spare_id and _inventory() == inventory, "JSON restore retains the clipped failed tool, equipped healthy spare and exact original identities")
	var clipped: RigidBody3D = restored_original[0]
	home.parts.cargo.linear_velocity = Vector3(.6, 0, 0)
	_check(ToolAccess.motion_reason(clipped).contains("Stop") and ToolAccess.fetch_stance(worker, clipped).is_empty(), "a moving rack refuses a stale fitting pose even if the helper is already aboard")
	home.parts.cargo.linear_velocity = Vector3.ZERO
	home.parts.cargo.angular_velocity = Vector3(0, .8, 0)
	_check(ToolAccess.motion_reason(clipped).contains("Stop"), "native container rotation also blocks tool fitting independently of chassis velocity")
	_check(shaft_samples > 500 and shaft_intersections == 0 and visual_samples > 125 and visual_intersections == 0, "the complete real retained tools remain outside the Wako cube through mobile fitting, travel and service")
	_check(_fitting_contacts >= 2 and _fitting_position_step < .03 and _fitting_rotation_step < 8.0, "native mobile fitting transfers the same stock pose continuously at the actual toe contact")
	for kind: String in ["inspect","tool_change","maintenance"]:
		var stats: Dictionary = _work_pose_stats.get(kind,{})
		_check(stats.get("samples",0)>125 and stats.get("knee",INF)<12.0 and stats.get("ankle",INF)<18.0 and stats.get("root",INF)<.025 and stats.get("angle",INF)<6.0,
			"actual mobile %s preparation, contact and release keep the evaluated cube, knees and ankles continuous" % kind)
		_check(stats.get("tool_samples",0)>125 and stats.get("tool",INF)<18.0,
			"actual mobile %s retains smooth whole-tool orientation through its work stroke" % kind)
	_check(_recovery_samples > 125 and _recovery_knee_step < 12.0 and _recovery_ankle_step < 18.0 and _recovery_tool_angle < 18.0 and _recovery_root_step < .025 and _recovery_root_angle < 6.0, "actual tool-failure recovery and idle/travel seams retain continuous evaluated knees, ankles, whole-tool rotation and cube motion")
	_check(_recovery_floor_samples > 125 and _recovery_tool_floor >= .005 - .00001, "the complete retained tool stays above its actual observed foot-support plane through idle and travel recovery")
	_finish()

func _watch_fitting() -> void:
	worker.action_contact.connect(func(kind: String) -> void:
		if kind != "tool_change": return
		fitting_contacts += 1
		if not worker.on_ground or not worker.stance_valid or not worker.foot_contact_ready(): invalid_contacts += 1)

func _capture(stage: String) -> void:
	if DisplayServer.get_name() == "headless" or not "--tool-capture" in OS.get_cmdline_user_args(): return
	if stage != "clipped":
		camera.global_position = worker.global_position + Vector3(-2.5, 1.3, 2.2)
		camera.look_at(worker.global_position + Vector3(0, .2, -.25))
	for i in 20: await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("res://.claude/tmp/mobile_tool_" + stage + ".png")

func _finish() -> void:
	for kind: String in ["inspect","tool_change","maintenance"]:
		print("CONTRAPTION_MOBILE_TOOL_WORK kind=",kind," stats=",_work_pose_stats.get(kind,{}))
	print("CONTRAPTION_MOBILE_TOOL_POSE shafts=%d shaft_hits=%d meshes=%d mesh_hits=%d fitting_step=%.6f fitting_angle=%.3f" % [shaft_samples, shaft_intersections, visual_samples, visual_intersections, _fitting_position_step, _fitting_rotation_step])
	print("CONTRAPTION_MOBILE_TOOL_RECOVERY samples=%d knee=%.3f ankle=%.3f tool_angle=%.3f root_step=%.6f root_angle=%.3f floor_samples=%d tool_floor=%.6f" % [_recovery_samples, _recovery_knee_step, _recovery_ankle_step, _recovery_tool_angle, _recovery_root_step, _recovery_root_angle, _recovery_floor_samples, _recovery_tool_floor])
	print("CONTRAPTION_MOBILE_TOOLS %s ticks=%d contacts=%d" % ["PASS" if failures == 0 else "FAIL (%d)" % failures, _tick, fitting_contacts])
	Shortcuts.graceful_quit(0 if failures == 0 else 1)

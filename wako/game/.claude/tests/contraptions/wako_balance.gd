extends Node3D
## Native supported source actions; observe the final body/sole geometry, not a balance flag.
## The weighted COM below describes the visible rig. Upright support remains the existing
## finite capsule/spring controller, rather than an independently simulated limb COM.
const Worker := preload("res://LogicObjects/Wako/Wako.tscn")
const Part := preload("res://Components/Contraptions/contraption_part.gd")
var worker: RigidBody3D
var tool: RigidBody3D
var cargo: RigidBody3D
var target: RigidBody3D
var failures := 0
var stage := "settle"
var samples: Dictionary = {}
var _neutral := Transform3D.IDENTITY
var _neutral_soles: Array[Vector3] = []
var _last_serial := -1
var _previous: Dictionary = {}
var _root_step := 0.0
var _root_angle := 0.0
var _knee_step := 0.0
var _ankle_step := 0.0
var _head_gap := 0.0
var _cargo_gap := 0.0
var _cargo_angle := 0.0
var _tool_gap := 0.0
var _tool_angle := 0.0
var _shaft_intersections := 0
var _mesh_intersections := 0
var _tool_floor := INF
var _contacts: Dictionary = {}
var _tool_vertices: Array[Vector3] = []
var _capture_dir := ""
var _captures: Dictionary = {}
var _camera: Camera3D
var _floor: StaticBody3D
var _watch_motion := false
var _motion := false
var _render_tick := 0
var _motion_counts: Dictionary = {}
var _jitter := false
var _root_marker: Marker3D
var _sole_markers: Array[Marker3D] = []
var _interruptions := false
var _motion_bands: Dictionary = {}

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--balance-captures="): _capture_dir = arg.trim_prefix("--balance-captures=")
		if arg.begins_with("--jitter-out="): _jitter = true
	_motion = "--balance-motion" in OS.get_cmdline_user_args()
	_interruptions = "--balance-interruptions" in OS.get_cmdline_user_args()
	_run.call_deferred()

func _check(ok: bool, message: String) -> void:
	print("CONTRAPTION_WAKO_BALANCE %s %s" % ["ok" if ok else "FAIL", message])
	if not ok: failures += 1

func _advance(seconds: float) -> void:
	for tick in roundi(seconds * Engine.physics_ticks_per_second): await get_tree().physics_frame

func _choose_foot(side: int) -> void:
	for number in 100:
		var id := "balance_role_%d" % number
		if absi(id.hash()) % 2 == side:
			worker.worker_id = id
			return

func _collect_vertices(node: Node, points: Array[Vector3]) -> void:
	if node is MeshInstance3D and node.mesh:
		var transform: Transform3D = tool.global_transform.affine_inverse() * node.global_transform
		for surface in node.mesh.get_surface_count():
			var vertices: PackedVector3Array = node.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
			for vertex in vertices: points.append(transform * vertex)
	for child: Node in node.get_children(): _collect_vertices(child, points)

func _contact(kind: String) -> void:
	_contacts[stage] = int(_contacts.get(stage, 0)) + 1
	if stage.begins_with("interrupt_"): return
	_check(worker.on_ground and worker.foot_contact_ready() and worker.stance_valid,
		"%s %s event retains native support and the original toe/tool contact distance" % [stage, kind])

func _process(_delta: float) -> void:
	_render_tick += 1
	if not _motion or _capture_dir.is_empty() or not _watch_motion or _render_tick % 3 != 0: return
	# Continuous 20 Hz rendered observations retain the real native action timer,
	# including preparation, the contact, release and supported neutral recovery.
	var picture := get_viewport().get_texture().get_image()
	if picture.is_empty(): return
	var number: int = _motion_counts.get(stage,0)
	_motion_counts[stage] = number+1
	if stage.begins_with("interrupt_"):
		var band := 0 if worker.action == "interrupted" and worker.action_progress < .35 else 1 if worker.action == "interrupted" else 2
		var bands: Dictionary = _motion_bands.get(stage,{})
		bands[band] = int(bands.get(band,0))+1
		_motion_bands[stage] = bands
	picture.save_png(_capture_dir.path_join("motion_%s_%03d.png" % [stage,number]))

func _physics_process(_delta: float) -> void:
	if not is_instance_valid(worker) or not is_instance_valid(worker._pose) or not worker._pose.evaluated_valid: return
	var pose: SkeletonModifier3D = worker._pose
	if pose.evaluation_serial == _last_serial: return
	_last_serial = pose.evaluation_serial
	var root: Transform3D = pose.evaluated_worker.affine_inverse() * pose.evaluated_root
	root.basis = pose.evaluated_basis.inverse() * pose.evaluated_root.basis
	var knees: Array[Vector3] = []
	var ankles: Array[Quaternion] = []
	for side in 2:
		knees.append(pose.evaluated_basis.inverse() * (pose.evaluated_knees[side] - pose.evaluated_hips[side]).normalized())
		ankles.append((pose.evaluated_basis.inverse() * pose.evaluated_ankles[side]).get_rotation_quaternion())
	if _watch_motion and not _previous.is_empty():
		_root_step = maxf(_root_step, root.origin.distance_to(_previous.root.origin))
		_root_angle = maxf(_root_angle, rad_to_deg(root.basis.get_rotation_quaternion().angle_to(_previous.root.basis.get_rotation_quaternion())))
		for side in 2:
			_knee_step = maxf(_knee_step, rad_to_deg(knees[side].angle_to(_previous.knees[side])))
			var ankle_step := rad_to_deg(ankles[side].angle_to(_previous.ankles[side]))
			_ankle_step = maxf(_ankle_step,ankle_step)
			if ankle_step > 18.0 and "--balance-debug" in OS.get_cmdline_user_args():
				print("CONTRAPTION_BALANCE_ANKLE stage=",stage," action=",worker.action," phase=",worker.action_progress," side=",side," angle=",ankle_step," entry=",pose._work_entry," release=",pose._work_release)
	_previous = {"root":root,"knees":knees,"ankles":ankles}
	var current_from_evaluated: Transform3D = worker.global_transform * pose.evaluated_worker.affine_inverse()
	if is_instance_valid(_root_marker):
		_root_marker.global_transform = current_from_evaluated * pose.evaluated_root
		for side in 2: _sole_markers[side].global_position = current_from_evaluated * pose.evaluated_soles[side]
	var head: Transform3D = current_from_evaluated * pose.evaluated_root
	head.origin += head.basis * Vector3(0, worker.HEAD_OFFSET, 0)
	_head_gap = maxf(_head_gap, head.origin.distance_to(worker.head_anchor.global_position))
	if _watch_motion and is_instance_valid(cargo) and cargo.carrier == worker.head_anchor:
		var gap := cargo.global_position.distance_to(head * cargo.get("_cargo_anchor"))
		if floori(gap/.03) > floori(_cargo_gap/.03) and "--balance-debug" in OS.get_cmdline_user_args():
			print("CONTRAPTION_WAKO_BALANCE follower stage=%s phase=%.3f gap=%.4f cargo=%s expected=%s anchor=%s" % [stage,worker.action_progress,gap,cargo.global_position,head*cargo.get("_cargo_anchor"),worker.head_anchor.global_position])
		_cargo_gap = maxf(_cargo_gap, gap)
		_cargo_angle = maxf(_cargo_angle,rad_to_deg(cargo.global_basis.get_rotation_quaternion().angle_to(head.basis.get_rotation_quaternion())))
	if is_instance_valid(tool) and tool.carrier == worker.tool_anchor:
		if _watch_motion:
			_tool_gap = maxf(_tool_gap, tool.global_position.distance_to(worker.tool_anchor.global_position))
			_tool_angle = maxf(_tool_angle,rad_to_deg(tool.global_basis.get_rotation_quaternion().angle_to(worker.tool_anchor.global_basis.get_rotation_quaternion())))
		var inverse: Transform3D = (current_from_evaluated * pose.evaluated_root).affine_inverse()
		var half: float = tool.definition.size.y * .5
		var bounds := AABB(Vector3(-.38,-.3,-.38), Vector3(.76,.68,.76))
		if bounds.intersects_segment(inverse * tool.to_global(Vector3(0,-half,0)), inverse * tool.to_global(Vector3(0,half,0))) != null:
			_shaft_intersections += 1
		for point in _tool_vertices:
			_tool_floor = minf(_tool_floor, tool.to_global(point).y)
			if bounds.grow(-.03).has_point(inverse * tool.to_global(point)): _mesh_intersections += 1
	if _neutral_soles.size() != 2 or worker.action.is_empty(): return
	var values: Dictionary = samples.get(stage, {"all":0,"count":0,"shift":0.0,"lean":0.0,"gain":0.0,"max_lean":0.0,"min_gain":INF,"sole_gap":0.0,"sole_drift":0.0,"raised":0.0,"grounded":true,"native":true,"blocked":0})
	values.all += 1
	if not worker.tool_pose_blocked.is_empty(): values.blocked += 1
	if worker.action_progress >= .43 and worker.action_progress <= .76:
		var support_side: int = 1 - worker.work_foot_side
		var sole: Vector3 = pose.evaluated_soles[support_side]
		var neutral_world: Transform3D = pose.evaluated_unbalanced_root
		# The counterfactual body is the same frame's authored root before balance.
		# Keep the actual solved legs and tool when comparing visible COM, so a
		# raised foot cannot masquerade as a transfer of the large cube/head load.
		var cube: Vector3 = pose.evaluated_root * Vector3(0,.04,0)
		var neutral_cube: Vector3 = neutral_world * Vector3(0,.04,0)
		var toward: Vector3 = (sole-neutral_cube).slide(Vector3.UP).normalized()
		var up: Vector3 = pose.evaluated_root.basis.y.normalized()
		var lean := rad_to_deg(atan2(up.dot(toward), up.dot(Vector3.UP)))
		var weighted := cube * 9.8
		var unbalanced := neutral_cube * 9.8
		var total := 22.0
		for side in 2:
			var leg: Vector3 = (pose.evaluated_hips[side]+pose.evaluated_knees[side]) * 1.5 + (pose.evaluated_knees[side]+pose.evaluated_soles[side]) + pose.evaluated_soles[side] * 1.1
			weighted += leg
			unbalanced += leg
		var evaluated_from_current: Transform3D = pose.evaluated_worker * worker.global_transform.affine_inverse()
		if is_instance_valid(tool):
			var tool_point: Vector3 = evaluated_from_current * tool.global_position
			weighted += tool_point * tool.mass
			unbalanced += tool_point * tool.mass
			total += tool.mass
		if is_instance_valid(cargo) and cargo.carrier == worker.head_anchor:
			weighted += (evaluated_from_current * cargo.global_position) * cargo.mass
			var neutral_head := neutral_world
			neutral_head.origin += neutral_head.basis * Vector3(0,worker.HEAD_OFFSET,0)
			unbalanced += (neutral_head * cargo.get("_cargo_anchor")) * cargo.mass
			total += cargo.mass
		var com := weighted / total
		var before := unbalanced / total
		var gain := (before-sole).slide(Vector3.UP).length() - (com-sole).slide(Vector3.UP).length()
		values.count += 1
		values.shift += (cube-neutral_cube).dot(toward)
		values.lean += lean
		values.gain += gain
		values.min_gain = minf(values.min_gain, gain)
		values.max_lean = maxf(values.max_lean, lean)
		values.sole_gap = maxf(values.sole_gap, absf(sole.y))
		var neutral_sole: Vector3 = pose.evaluated_worker * _neutral_soles[support_side]
		values.sole_drift = maxf(values.sole_drift, sole.distance_to(neutral_sole))
		values.raised = maxf(values.raised, pose.evaluated_soles[worker.work_foot_side].y - sole.y)
		values.grounded = values.grounded and pose.evaluated_grounded[support_side]
		values.native = values.native and worker.on_ground and not worker.ragdoll.is_down()
		if values.count % 4 == 0:
			var query := PhysicsRayQueryParameters3D.create(sole+Vector3.UP*.2, sole-Vector3.UP*.25,1)
			query.exclude = worker.query_exclusions()
			var hit := get_world_3d().direct_space_state.intersect_ray(query)
			values.native = values.native and not hit.is_empty() and hit.collider == _floor and absf(hit.position.y-sole.y) < .035
		if not _capture_dir.is_empty() and not _captures.has(stage) and worker.action_progress > .54:
			_captures[stage] = true
			_capture.call_deferred(stage)
	samples[stage] = values

func _capture(label: String) -> void:
	# No pose/timer pause: the saved framebuffer is a real completed work frame.
	await get_tree().process_frame
	await get_tree().process_frame
	var picture := get_viewport().get_texture().get_image()
	if not picture.is_empty():
		DirAccess.make_dir_recursive_absolute(_capture_dir)
		picture.save_png(_capture_dir.path_join(label+".png"))

func _set_neutral() -> void:
	_neutral = worker._pose.evaluated_worker.affine_inverse() * worker._pose.evaluated_root
	_neutral_soles.clear()
	for point: Vector3 in worker._pose.evaluated_soles:
		_neutral_soles.append(worker._pose.evaluated_worker.affine_inverse() * point)

func _action(kind: String, side: int, loaded: bool) -> void:
	stage = "%s_%s_%s" % [kind,"left" if side == 0 else "right","load" if loaded else "bare"]
	_choose_foot(side)
	await _advance(.45)
	# IDs select a fixture role; actual workers retain one ID for their lifetime.
	# Rebind the existing finite payload after this intentional role change.
	worker.set_cargo(worker.cargo_mass)
	_set_neutral()
	_watch_motion = true
	worker.work_target = target
	worker.begin_action(kind)
	await _advance(worker._action_length + .65)
	_watch_motion = false
	var values: Dictionary = samples.get(stage,{})
	var count: float = maxf(float(values.get("count",0)),1)
	var shift: float = values.get("shift",0.0) / count
	var lean: float = values.get("lean",0.0) / count
	var gain: float = values.get("gain",0.0) / count
	_check(count > 20 and values.get("raised",0.0) > .12, "%s observes a genuinely raised work foot through the contact interval" % stage)
	_check(shift > .035 and lean > 1.0 and values.get("max_lean",0.0) < 22.0,
		"%s moves and visibly tilts the evaluated cube toward its actual opposite supporting sole" % stage)
	_check(gain > .02 and values.get("min_gain",-INF) > -.015,
		"%s brings mass-weighted visible COM closer to the planted sole with the same solved leg/tool geometry" % stage)
	_check(values.get("native",false) and values.get("grounded",false) and values.get("sole_gap",INF) < .035 and values.get("sole_drift",INF) < .075,
		"%s retains the original planted sole and native ground without stretching or a new force controller" % stage)
	_check(_contacts.get(stage,0) == 1 and values.get("blocked",1) == 0,
		"%s completes one real authored contact without weakening toe/tool clearance" % stage)
	var recovered: Transform3D = worker._pose.evaluated_worker.affine_inverse()*worker._pose.evaluated_root
	_check(recovered.origin.distance_to(_neutral.origin) < .045,
		"%s returns smoothly to its own settled neutral body position" % stage)
	print("CONTRAPTION_WAKO_BALANCE metrics stage=%s n=%d shift=%.4f lean=%.3f max_lean=%.3f com_gain=%.4f min_gain=%.4f sole_gap=%.4f sole_drift=%.4f raised=%.4f blocked=%d" % [stage,count,shift,lean,values.get("max_lean",0),gain,values.get("min_gain",0),values.get("sole_gap",0),values.get("sole_drift",0),values.get("raised",0),values.get("blocked",0)])

func _interruption(side: int, phase: float) -> void:
	_choose_foot(side)
	await _advance(.5)
	worker.set_cargo(worker.cargo_mass)
	stage = "interrupt_%s_%d" % ["left" if side == 0 else "right",roundi(phase*100)]
	worker.work_target = target
	worker.begin_action("inspect")
	await _advance(worker._action_length*phase)
	var lifted: float = worker._pose.evaluated_soles[side].y
	var contacts_before: int = _contacts.get(stage,0)
	_check(lifted > .12,"%s starts with the actual work foot lifted before cancellation" % stage)
	_watch_motion = true
	# This is the same target invalidation/order as coordinator cancellation.
	worker.work_target = null
	worker.interrupt("Work cancelled; returning foot to support")
	await _advance(worker._action_length+.55)
	_watch_motion = false
	_check(_contacts.get(stage,0) == contacts_before,"%s does not emit an abandoned work event or imaginary interruption contact" % stage)
	_check(worker.on_ground and worker._pose.evaluated_grounded.all(func(grounded: bool) -> bool:return grounded)
		and worker._pose.evaluated_soles[side].y < .035 and worker._pose.evaluated_soles[side].y > -.005,
		"%s returns the released sole onto actual terrain with finite leg support" % stage)
	print("CONTRAPTION_WAKO_BALANCE cancellation stage=%s ground=%s soles=%s planted=%s" % [stage,worker.on_ground,worker._pose.evaluated_soles,worker._pose.evaluated_grounded])

func _run() -> void:
	if not _capture_dir.is_empty(): DirAccess.make_dir_recursive_absolute(_capture_dir)
	_floor = StaticBody3D.new()
	_floor.position.y = -.5
	add_child(_floor)
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(30,1,30)
	collision.shape = box
	_floor.add_child(collision)
	var floor_mesh := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = box.size
	floor_mesh.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(.19,.22,.24)
	material.roughness = .9
	floor_mesh.material_override = material
	_floor.add_child(floor_mesh)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(.30,.37,.47)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(.85,.92,1)
	environment.environment.ambient_light_energy = .65
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45,-35,0)
	sun.light_energy = 2.4
	sun.shadow_enabled = true
	add_child(sun)
	_camera = Camera3D.new()
	_camera.position = Vector3(2.7,1.7,3.4)
	add_child(_camera)
	_camera.look_at(Vector3(0,.9,-.3))
	_camera.current = true
	worker = Worker.instantiate()
	worker.position.y = .85
	worker.worker_id = "balance-initial"
	add_child(worker)
	if not is_instance_valid(worker._pose):
		_check(false,"Wako's actual pose modifier initialises before the native action fixture")
		Shortcuts.graceful_quit(1)
		return
	worker.add_to_group("jitter_root")
	_root_marker = Marker3D.new()
	_root_marker.name = "Cube"
	_root_marker.add_to_group("jitter_focus")
	add_child(_root_marker)
	for label in ["SoleLeft","SoleRight"]:
		var marker := Marker3D.new()
		marker.name = label
		marker.add_to_group("jitter_focus")
		add_child(marker)
		_sole_markers.append(marker)
	worker.action_contact.connect(_contact)
	target = Part.new()
	target.setup("bracket","balance-grounded-work",true)
	target.position = Vector3(0,.15,-.95)
	add_child(target)
	tool = Part.new()
	tool.setup("assembly_tool","balance-same-mallet",true)
	tool.position = Vector3(2,1,0)
	add_child(tool)
	await _advance(1.0)
	tool.set_carried(worker.tool_anchor,Vector3.ZERO)
	tool.global_transform = worker.tool_anchor.global_transform
	worker.set_equipped_tool(tool)
	_collect_vertices(tool,_tool_vertices)
	await _advance(.5)
	for kind in ["inspect","assemble"]:
		for side in 2: await _action(kind,side,false)
	cargo = Part.new()
	cargo.setup("light","balance-same-head-load",true)
	cargo.position = Vector3(2,1,1)
	add_child(cargo)
	cargo.set_carried(worker.head_anchor, Vector3(0,float(cargo.definition.size.y)*.5+.03,0))
	worker.set_cargo(cargo.mass)
	await _advance(.65)
	for side in 2: await _action("inspect",side,true)
	if _interruptions:
		for side in 2:
			for phase: float in [.44,.66]: await _interruption(side,phase)
	_check(cargo.carrier == worker.head_anchor and tool.carrier == worker.tool_anchor and is_equal_approx(worker.mass,22.0+worker.back_tool.holder_mass()+cargo.mass+tool.mass),
		"the same 2 kg head part and finite toe tool remain attached with one copy of their masses")
	_check(_root_step < .025 and _root_angle < 6.0 and _knee_step < 12.0 and _ankle_step < 18.0,
		"both sides and loaded entry/contact/release retain bounded continuous body, knee and ankle motion")
	_check(_head_gap < .01 and _cargo_gap < .01 and _cargo_angle < 1.0 and _tool_gap < .01 and _tool_angle < 1.0,
		"actual head cargo and toe tool retain their evaluated attachment positions throughout balance")
	_check(_shaft_intersections == 0 and _mesh_intersections == 0 and _tool_floor > -.005,
		"the full physical toe tool stays outside the cube and above the native ground throughout actions")
	print("CONTRAPTION_WAKO_BALANCE continuity root_step=%.4f root_angle=%.3f knee_step=%.3f ankle_step=%.3f head_gap=%.4f cargo_gap=%.4f cargo_angle=%.3f tool_gap=%.4f tool_angle=%.3f shaft_hits=%d mesh_hits=%d tool_floor=%.4f" % [_root_step,_root_angle,_knee_step,_ankle_step,_head_gap,_cargo_gap,_cargo_angle,_tool_gap,_tool_angle,_shaft_intersections,_mesh_intersections,_tool_floor])
	if _motion:
		for label: String in samples:
			if label.begins_with("interrupt_"):
				var bands: Dictionary = _motion_bands.get(label,{})
				_check(_motion_counts.get(label,0) >= 24 and bands.get(0,0) >= 2 and bands.get(1,0) >= 2 and bands.get(2,0) >= 2,
					"%s continuously records the shorter supported foot return, recoil and neutral recovery" % label)
			else: _check(_motion_counts.get(label,0) > 30, "%s saves continuous rendered preparation/contact/release/recovery observations" % label)
		print("CONTRAPTION_WAKO_BALANCE rendered_frames=%s" % _motion_counts)
	print("CONTRAPTION_WAKO_BALANCE %s" % ["PASS" if failures == 0 else "FAIL (%d)" % failures])
	if _jitter: return # The existing probe owns shutdown and can observe final recovery.
	Shortcuts.graceful_quit(0 if failures == 0 else 1)

extends "res://.claude/tests/contraptions/wako_balance.gd"
## Real native body collisions exercise the production recoil hooks. Existing
## balance/tool guards sample the evaluated rig; the worker adds no reactions.
const RecoilWorker = preload("res://.claude/tests/contraptions/wako_recoil_worker.gd")
var impactor: RigidBody3D
var contact_events := 0
var hit_cases := 0
var repeated_impacts := 0
var recoil_samples := 0
var maximum_tool_turn := 0.0
var _last_tool := Quaternion.IDENTITY
var _last_tool_valid := false
var minimum_sole := INF
var maximum_sole_step := 0.0
var _last_soles: Array[Vector3] = []
var _last_sole_serial := -1
var _debug_knees: Array[Vector3] = []
var _debug_body := Vector3.ZERO
var _debug_soles: Array[Vector3] = []
var _debug_floor := INF
var _source_clip: Animation
var _source_track := -1
var _case_direction := ""
var _direction_cue := 0.0

func _ready() -> void:
	super._ready()
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--recoil-captures="): _capture_dir = arg.trim_prefix("--recoil-captures=")
	_motion = "--recoil-motion" in OS.get_cmdline_user_args()

func _contact(_kind: String) -> void:
	contact_events += 1

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if not _watch_motion or not is_instance_valid(worker) or not worker._pose.evaluated_valid: return
	var pose: SkeletonModifier3D = worker._pose
	if pose.evaluation_serial != _last_sole_serial:
		if _last_soles.size() == 2:
			for side in 2: maximum_sole_step = maxf(maximum_sole_step,pose.evaluated_soles[side].distance_to(_last_soles[side]))
		_last_soles = pose.evaluated_soles.duplicate()
		_last_sole_serial = pose.evaluation_serial
	if worker.recoil.events>0 and worker.action=="interrupted" and worker.action_progress>.23 and worker.action_progress<.32:
		var up: Vector3 = pose.evaluated_basis.inverse()*pose.evaluated_root.basis.y
		var baseline: Vector3 = _source_clip.rotation_track_interpolate(_source_track,worker._animation.current_animation_position)*Vector3.UP
		_direction_cue = maxf(_direction_cue,(up-baseline).dot(-worker.recoil.DIRECTIONS[_case_direction]))
		if "--recoil-debug" in OS.get_cmdline_user_args() and worker.action_progress>.255 and worker.action_progress<.265:
			var authored: Animation = worker._animation.get_animation(worker._animation.current_animation)
			print("WAKO_RECOIL authored stage=",stage," phase=",worker.action_progress," clip=",worker._animation.current_animation," base=",_source_clip.rotation_track_interpolate(_source_track,worker._animation.current_animation_position)," new=",authored.rotation_track_interpolate(_source_track,worker._animation.current_animation_position)," raw=",worker._skeleton.get_bone_pose_rotation(0)," rest=",worker._skeleton.get_bone_global_rest(0).basis," evaluated=",pose.evaluated_basis.inverse()*pose.evaluated_root.basis," up=",up," baseline=",baseline)
	if "--recoil-debug" in OS.get_cmdline_user_args():
		var knees: Array[Vector3] = []
		for side in 2:
			var knee: Vector3 = pose.evaluated_basis.inverse()*(pose.evaluated_knees[side]-pose.evaluated_hips[side]).normalized()
			knees.append(knee)
			if _debug_knees.size()==2 and rad_to_deg(knee.angle_to(_debug_knees[side]))>12.0:
				print("WAKO_RECOIL seam stage=",stage," phase=",worker.action_progress," action=",worker.action," side=",side," knee=",rad_to_deg(knee.angle_to(_debug_knees[side]))," body=",worker.global_position," oldbody=",_debug_body," sole=",pose.evaluated_soles[side]," oldsole=",_debug_soles[side]," release=",pose._work_release," terrain=",pose._terrain_points)
		_debug_knees = knees
		_debug_body = worker.global_position
		_debug_soles = pose.evaluated_soles.duplicate()
		if _tool_floor < _debug_floor and _tool_floor < .005:
			print("WAKO_RECOIL floor stage=",stage," phase=",worker.action_progress," action=",worker.action," gap=",_tool_floor," body=",worker.global_position," soles=",pose.evaluated_soles," support=",pose._terrain_points," blocked=",worker.tool_pose_blocked)
		_debug_floor = _tool_floor
	var rotation: Quaternion = (pose.evaluated_basis.inverse()*tool.global_basis).get_rotation_quaternion()
	if _last_tool_valid: maximum_tool_turn = maxf(maximum_tool_turn,rad_to_deg(_last_tool.angle_to(rotation)))
	_last_tool = rotation
	_last_tool_valid = true
	for sole: Vector3 in pose.evaluated_soles: minimum_sole = minf(minimum_sole,sole.y)
	recoil_samples += 1

func _floor_setup() -> void:
	_floor = StaticBody3D.new()
	_floor.position.y = -.5
	add_child(_floor)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(100,1,100)
	collision.shape = shape
	_floor.add_child(collision)
	var floor_mesh := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = shape.size
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
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45,-35,0)
	light.light_energy = 2.4
	add_child(light)
	_camera = Camera3D.new()
	_camera.position = Vector3(3,2.2,3.5)
	add_child(_camera)
	_camera.look_at(Vector3(0,1,-.2))
	_camera.current = true
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

func _spawn_impactor(direction: String) -> void:
	var incoming: Vector3 = worker._model.global_basis*worker.recoil.DIRECTIONS[direction]
	impactor = RigidBody3D.new()
	impactor.mass = 300.0
	impactor.gravity_scale = 0.0
	impactor.linear_damp = 0.0
	impactor.collision_layer = 1
	impactor.collision_mask = 4
	impactor.position = worker.global_position+Vector3.UP*.2+incoming*.56
	var collision := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = .25
	collision.shape = shape
	impactor.add_child(collision)
	var visual := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = shape.radius
	mesh.height = shape.radius*2.0
	visual.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(.75,.27,.19)
	visual.material_override = material
	impactor.add_child(visual)
	add_child(impactor)
	impactor.linear_velocity = -incoming*3.25

func _collision(direction: String, side: int, repeated := false) -> void:
	stage = ("repeat_%s_%d" if repeated else "hit_%s_%d")%[direction,side]
	worker = Worker.instantiate()
	worker.set_script(RecoilWorker)
	worker.position.y = .85
	for serial in 30:
		var id := "recoil-%d-%d"%[side,serial]
		if absi(id.hash())%2 == side: worker.worker_id = id; break
	add_child(worker)
	_source_clip = worker._animation.get_animation("wk_interrupted_"+("L" if side==0 else "R"))
	for track in _source_clip.get_track_count():
		if _source_clip.track_get_type(track)==Animation.TYPE_ROTATION_3D and _source_clip.track_get_path(track).get_subname(0)=="Bone": _source_track = track
	_case_direction = direction
	_direction_cue = 0.0
	worker.action_contact.connect(_contact)
	target = Part.new()
	target.setup("bracket",stage+"-work",true)
	target.position = Vector3(0,.15,-.95)
	add_child(target)
	tool = Part.new()
	tool.setup("assembly_tool",stage+"-tool",true)
	add_child(tool)
	cargo = Part.new()
	cargo.setup("light",stage+"-head",true)
	add_child(cargo)
	await _advance(.9)
	tool.set_carried(worker.tool_anchor,Vector3.ZERO)
	tool.global_transform = worker.tool_anchor.global_transform
	worker.set_equipped_tool(tool)
	cargo.set_carried(worker.head_anchor,Vector3(0,float(cargo.definition.size.y)*.5+.03,0))
	worker.set_cargo(cargo.mass)
	_tool_vertices.clear()
	_collect_vertices(tool,_tool_vertices)
	await _advance(.65)
	_set_neutral()
	worker.work_target = target
	worker.begin_action("inspect")
	await _advance(worker._action_length*.44)
	var before: int = contact_events
	_spawn_impactor(direction)
	_previous.clear()
	_debug_knees.clear()
	_last_tool_valid = false
	_last_soles.clear()
	_last_sole_serial = -1
	_watch_motion = true
	for tick in 90:
		await get_tree().physics_frame
		if worker.recoil.events>0 or worker.ragdoll.is_down(): break
	var actual: String = worker.recoil.last_direction
	var impact: float = worker.recoil.last_impulse.length()/worker.mass
	_check(actual == direction and worker.recoil.events == 1 and impact>2.5 and impact<=3.5,
		"%s selects its authored direction from a real native body contact inside the existing stumble band"%stage)
	if worker.recoil.events>0: hit_cases += 1
	# The observed one-shot projectile keeps its native momentum, but ceases to
	# shove after the recorded hit so recovery is not a sustained pinned contact.
	impactor.collision_layer = 0
	impactor.collision_mask = 0
	if repeated:
		await _advance(.70)
		_check(worker.action == "interrupted" and worker._action_time>.65 and worker._action_time<worker._action_length,
			"%s receives its second real hit after cooldown while its first recovery is still active"%stage)
		impactor.queue_free()
		_case_direction = "left"
		_direction_cue = 0.0
		stage = "repeat_left_%d"%side
		_spawn_impactor("left")
		for tick in 90:
			await get_tree().physics_frame
			if worker.recoil.events>1 or worker.ragdoll.is_down(): break
		actual = worker.recoil.last_direction
		impact = worker.recoil.last_impulse.length()/worker.mass
		_check(worker.recoil.events == 2 and actual == "left" and impact>2.5 and impact<=3.5,
			"%s selects its new authored direction from its second native body contact"%stage)
		_check(worker.action == "interrupted" and worker._action_time<.05 and worker.action_progress<.06,
			"%s restarts its actual authored recovery clock without replaying work"%stage)
		if worker.recoil.events == 2: repeated_impacts += 1
		impactor.collision_layer = 0
		impactor.collision_mask = 0
	await _advance(3.1)
	_watch_motion = false
	_check(contact_events == before,"%s emits no abandoned work or recoil contact"%stage)
	_check(_direction_cue>.05,"%s visibly leans the evaluated cube away from its real impact direction"%stage)
	_check(worker.on_ground and not worker.ragdoll.is_down() and worker._pose.evaluated_grounded.all(func(grounded: bool)->bool:return grounded),
		"%s returns the actual working sole to native support without altering the knockdown boundary"%stage)
	_check(tool.carrier == worker.tool_anchor and cargo.carrier == worker.head_anchor and is_equal_approx(worker.mass,22+worker.back_tool.holder_mass()+tool.mass+cargo.mass),
		"%s preserves the same toe-held tool, head cargo and one copy of each finite mass"%stage)
	print("WAKO_RECOIL hit=",stage," direction=",actual," native_impact=",impact," cue=",_direction_cue," velocity=",worker.linear_velocity," soles=",worker._pose.evaluated_soles)
	for node: Node in [worker,tool,cargo,target,impactor]: node.queue_free()
	await get_tree().physics_frame

func _impact_boundary(speed: float, should_knock_down: bool) -> void:
	stage = "boundary_%.1f"%speed
	worker = Worker.instantiate()
	worker.set_script(RecoilWorker)
	worker.worker_id = stage
	worker.position.y = .85
	add_child(worker)
	tool = Part.new()
	tool.setup("assembly_tool",stage+"-tool",true)
	add_child(tool)
	cargo = Part.new()
	cargo.setup("light",stage+"-head",true)
	add_child(cargo)
	await _advance(.8)
	tool.set_carried(worker.tool_anchor,Vector3.ZERO)
	tool.global_transform = worker.tool_anchor.global_transform
	worker.set_equipped_tool(tool)
	cargo.set_carried(worker.head_anchor,Vector3(0,float(cargo.definition.size.y)*.5+.03,0))
	worker.set_cargo(cargo.mass)
	await _advance(.3)
	var incoming: Vector3 = worker._model.global_basis.x
	impactor = RigidBody3D.new()
	impactor.mass = 300.0
	impactor.gravity_scale = 0.0
	impactor.linear_damp = 0.0
	impactor.collision_layer = 1
	impactor.collision_mask = 4
	impactor.position = worker.global_position+Vector3.UP*.2+incoming*.56
	var collision := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = .25
	collision.shape = shape
	impactor.add_child(collision)
	add_child(impactor)
	impactor.linear_velocity = -incoming*speed
	for tick in 90:
		await get_tree().physics_frame
		if worker.maximum_native_impact > .5: break
	var actual: float = worker.maximum_native_impact
	_check(actual > 3.5 if should_knock_down else actual > .5 and actual <= 2.5,
		"%s exercises the original native impact boundary with the finite tool and head load"%stage)
	_check(worker.recoil.events == 0 and worker.ragdoll.is_down() == should_knock_down,
		"%s preserves mild-contact stability and the original stronger-hit native knockdown"%stage)
	print("WAKO_RECOIL boundary speed=",speed," native_impact=",actual," down=",worker.ragdoll.is_down()," recoil_events=",worker.recoil.events)
	for node: Node in [worker,tool,cargo,impactor]: node.queue_free()
	await get_tree().physics_frame

func _run() -> void:
	if not _capture_dir.is_empty(): DirAccess.make_dir_recursive_absolute(_capture_dir)
	_floor_setup()
	for side in 2:
		for direction: String in ["front","back","left","right"]: await _collision(direction,side)
	for side in 2: await _collision("front",side,true)
	_check(hit_cases == 10 and repeated_impacts == 2 and recoil_samples>500,"all four real native impact directions and repeated hits retain either toe-held tool role")
	_check(_root_step<.025 and _root_angle<6 and _knee_step<12 and _ankle_step<18 and maximum_tool_turn<18 and maximum_sole_step<.05,
		"actual grounded recoil and return retain continuous evaluated cube, knees, ankles and whole-tool orientation")
	_check(_shaft_intersections == 0 and _mesh_intersections == 0 and _tool_floor>=.005 and minimum_sole>-.005,
		"whole native tools and evaluated soles remain clear of the cube and actual support")
	_check(_head_gap<.01 and _cargo_gap<.01 and _cargo_angle<1.0 and _tool_gap<.01 and _tool_angle<1.0,
		"the same actual head cargo and toe tool follow their evaluated attachments throughout both hits and recovery")
	await _impact_boundary(2.4,false)
	await _impact_boundary(4.5,true)
	print("WAKO_RECOIL metrics cases=%d samples=%d root=%.4f/%.3f knee=%.3f ankle=%.3f tool=%.3f shaft_hits=%d mesh_hits=%d floor=%.4f sole=%.4f sole_step=%.4f"%[hit_cases,recoil_samples,_root_step,_root_angle,_knee_step,_ankle_step,maximum_tool_turn,_shaft_intersections,_mesh_intersections,_tool_floor,minimum_sole,maximum_sole_step])
	print("WAKO_RECOIL attachments head=%.4f cargo=%.4f/%.3f tool=%.4f/%.3f"%[_head_gap,_cargo_gap,_cargo_angle,_tool_gap,_tool_angle])
	print("WAKO_RECOIL %s"%["PASS" if failures == 0 else "FAIL (%d)"%failures])
	Shortcuts.graceful_quit(0 if failures==0 else 1)

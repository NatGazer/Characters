extends "res://.claude/tests/contraptions/wako_gait.gd"
## Low physical steps: native capsule/spring support, evaluated soles and the same head cargo.
var steps: Array[StaticBody3D] = []
var penetrations := 0
var elevated_samples := 0
var supporting_samples := 0
var crossing_samples := 0
var capture_dir := ""
var render_tick := 0
var root_marker: Marker3D
var sole_markers: Array[Marker3D] = []
var min_step_gap := INF
var anticipated_samples := 0
var maximum_sole_step := 0.0
var _sole_serial := -1
var _previous_soles: Array[Vector3] = []

func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--steps-captures="): capture_dir = arg.trim_prefix("--steps-captures=")
	if not capture_dir.is_empty(): DirAccess.make_dir_recursive_absolute(capture_dir)
	super._ready()

func _process(_delta: float) -> void:
	render_tick += 1
	if capture_dir.is_empty() or render_tick%3 != 0 or not is_instance_valid(worker): return
	var picture := get_viewport().get_texture().get_image()
	if not picture.is_empty(): picture.save_png(capture_dir.path_join("step_%04d.png"%render_tick))

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if not is_instance_valid(worker) or not worker._pose.evaluated_valid: return
	var pose: SkeletonModifier3D = worker._pose
	if pose.evaluation_serial != _sole_serial:
		if _previous_soles.size() == 2:
			for side in 2: maximum_sole_step = maxf(maximum_sole_step,_previous_soles[side].distance_to(pose.evaluated_soles[side]))
		_previous_soles = pose.evaluated_soles.duplicate()
		_sole_serial = pose.evaluation_serial
	var current: Transform3D = worker.global_transform*pose.evaluated_worker.affine_inverse()
	root_marker.global_transform = current*pose.evaluated_root
	for side in 2: sole_markers[side].global_position = current*pose.evaluated_soles[side]
	if worker.global_position.z > -1.5 or worker.global_position.z < -5.5: return
	crossing_samples += 1
	for side in 2:
		var point: Vector3 = pose.evaluated_soles[side]
		if pose._step_lifts[side] > .04: anticipated_samples += 1
		if point.y > .3: elevated_samples += 1
		if pose.evaluated_grounded[side]: supporting_samples += 1
		for step in steps:
			var local := step.to_local(point)
			var shape := step.get_node("Collision").shape as BoxShape3D
			if absf(local.x) > shape.size.x*.5 or absf(local.z) > shape.size.z*.5: continue
			var gap := local.y-shape.size.y*.5
			min_step_gap = minf(min_step_gap,gap)
			if gap < -.002:
				penetrations += 1
				if "--steps-debug" in OS.get_cmdline_user_args():
					print("CONTRAPTION_STEPS penetration stage=%s side=%d sole=%s native=%s plane=%s normal=%s lift=%.4f ahead=%.4f weight=%.4f target=%s"%[stage,side,point,worker.global_position,pose._terrain_points[side],pose._sole_normals[side],pose._step_lifts[side],pose._step_ahead[side],pose._plant_weights[side],pose._targets[side]])

func _box(position: Vector3, size: Vector3, colour: Color) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = position
	add_child(body)
	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	var visual := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	visual.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = .85
	visual.material_override = material
	body.add_child(visual)
	return body

func _run() -> void:
	_box(Vector3(0,-.5,0),Vector3(30,1,30),Color(.19,.22,.24))
	steps.append(_box(Vector3(0,.06,-2.75),Vector3(3,.12,1.5),Color(.35,.40,.45)))
	steps.append(_box(Vector3(0,.12,-4.25),Vector3(3,.24,1.5),Color(.45,.49,.53)))
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
	var camera := Camera3D.new()
	camera.position = Vector3(4,2.5,0)
	add_child(camera)
	camera.look_at(Vector3(0,.9,-3))
	camera.current = true
	root_marker = Marker3D.new()
	root_marker.add_to_group("jitter_focus")
	add_child(root_marker)
	for name in ["SoleLeft","SoleRight"]:
		var marker := Marker3D.new()
		marker.name = name
		marker.add_to_group("jitter_focus")
		add_child(marker)
		sole_markers.append(marker)
	worker = Worker.instantiate()
	worker.worker_id = "native-steps"
	worker.position = Vector3(0,.85,0)
	add_child(worker)
	await _advance(1.0,"idle")
	worker.navigate_to(Vector3(0,.24,-4.4))
	await _advance(3.1,"ascending")
	worker.stop_navigation()
	await _advance(.8,"top")
	_check(worker.on_ground and worker.global_position.z < -3.8 and worker.global_position.y > 1.03,
		"native Wako travels up two real 12 cm steps using unchanged capsule/spring support")
	cargo = Part.new()
	cargo.setup("light","step-head-load",true)
	add_child(cargo)
	cargo.set_carried(worker.head_anchor,Vector3(0,float(cargo.definition.size.y)*.5+.03,0))
	worker.set_cargo(cargo.mass)
	worker.navigate_to(Vector3(0,0,0))
	await _advance(3.5,"loaded_descending")
	worker.stop_navigation()
	await _advance(.7,"bottom")
	_check(worker.on_ground and worker.global_position.z > -.8 and not worker.ragdoll.is_down(),
		"head-loaded Wako steps down onto native terrain without floating or losing its cargo")
	_check(crossing_samples > 200 and supporting_samples > 150 and elevated_samples > 20,
		"actual lifted soles and opposite native plants remain visible throughout both traversals")
	_check(penetrations == 0,"evaluated soles clear actual solid step tops during ascent and descent")
	_check(anticipated_samples > 20,"visible toes anticipate actual low risers before their ground plants change")
	_check(_maximum_knee_step < 12 and _maximum_ankle_step < 18 and _maximum_root_step < .025,
		"step plants and walk/idle handoffs remain continuous with finite leg geometry")
	_check(maximum_sole_step < .05,"actual evaluated world soles avoid the former sharp plantar handoff, including solid tread edges")
	_check(_maximum_head_gap < .01 and _maximum_cargo_gap < .04 and _maximum_cargo_angle < 8,
		"the same head cargo follows the evaluated cube across support changes")
	print("CONTRAPTION_STEPS metrics samples=%d planted=%d elevated=%d penetration=%d min_gap=%.4f knee=%.3f ankle=%.3f root=%.4f sole_step=%.4f"%[crossing_samples,supporting_samples,elevated_samples,penetrations,min_step_gap,_maximum_knee_step,_maximum_ankle_step,_maximum_root_step,maximum_sole_step])
	print("CONTRAPTION_STEPS %s"%["PASS" if failures==0 else "FAIL (%d)"%failures])
	Shortcuts.graceful_quit(0 if failures==0 else 1)

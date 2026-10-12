extends "res://.claude/tests/contraptions/mobile_tools.gd"
## Replay earned workshop stock/jobs. Observe ordinary retained-tool travel;
## construction completion and high-beam work access remain separate checks.
var _travel_observing := false
var _material_before := {}
const ToolReturn = preload("res://LogicObjects/Wako/wako_tool_return.gd")
var _world_previous := {}
var _role_samples := [0,0]
var _role_transitions := [{},{}]
var _travel_sole_step := 0.0
var _travel_gripping_sole_step := 0.0
var _travel_grip_step := 0.0
var _return_capture_dir := ""
var _return_motion := false
var _return_frame := 0
var _return_markers: Array[Marker3D] = []
var _return_jitter := false
var _experiment_path := ""
var _result_path := ""

func _process(_delta: float) -> void:
	if not is_instance_valid(yard) or not _travel_observing or yard.workers.is_empty(): return
	var focus: Node3D = yard.workers[0]
	if not focus._pose.evaluated_valid: return
	var pose: SkeletonModifier3D = focus._pose
	var rebase: Transform3D = focus.global_transform*pose.evaluated_worker.affine_inverse()
	_return_markers[0].global_transform = rebase*pose.evaluated_root
	_return_markers[1].global_position = rebase*pose.evaluated_soles[0]
	_return_markers[2].global_position = rebase*pose.evaluated_soles[1]
	_return_markers[3].global_transform = focus.tool_anchor.global_transform
	if not _return_jitter:
		camera.global_position = focus.global_position+Vector3(3.8,2.1,4.0)
		camera.look_at(focus.global_position+Vector3.UP*.2)
	_return_frame += 1
	if _return_motion and not _return_capture_dir.is_empty() and _return_frame%3==0:
		var frame := get_viewport().get_texture().get_image()
		if not frame.is_empty(): frame.save_png(_return_capture_dir.path_join("travel_%04d.png"%_return_frame))

func _visual_setup(ground: StaticBody3D, box: BoxShape3D) -> void:
	var visual := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = box.size
	visual.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(.19,.22,.24)
	material.roughness = .9
	visual.material_override = material
	ground.add_child(visual)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color(.30,.37,.47)
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color(.85,.92,1)
	world.environment.ambient_light_energy = .65
	add_child(world)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45,-35,0)
	light.light_energy = 2.4
	add_child(light)
	camera = Camera3D.new()
	camera.position = Vector3(-.7,3.0,8.0)
	add_child(camera)
	camera.look_at(Vector3(-4.5,1.0,4.0))
	camera.current = true
	for label: String in ["Cube","SoleLeft","SoleRight","Tool"]:
		var marker := Marker3D.new()
		marker.name = label
		marker.add_to_group("jitter_focus")
		add_child(marker)
		_return_markers.append(marker)

func _watch_recovery(helper: Node) -> void:
	if not _travel_observing: return
	if not helper.action.is_empty():
		_recovery_poses.erase(helper.get_instance_id())
		_world_previous.erase(helper.get_instance_id())
		return
	super._watch_recovery(helper)
	var pose: SkeletonModifier3D = helper._pose
	if not pose.evaluated_valid or not helper.foot_grip_valid or not is_instance_valid(helper.equipped_tool): return
	var id := helper.get_instance_id()
	var previous: Dictionary = _world_previous.get(id,{})
	if previous.get("serial",-1)==pose.evaluation_serial: return
	_role_samples[helper.tool_foot_side()] += 1
	var label: String = helper.worker_id
	_role_transitions[helper.tool_foot_side()][label] = int(_role_transitions[helper.tool_foot_side()].get(label,0))+1
	if previous.get("tool",0)==helper.equipped_tool.get_instance_id():
		for side in 2:
			var step: float = previous.soles[side].distance_to(pose.evaluated_soles[side])
			_travel_sole_step = maxf(_travel_sole_step,step)
			if side==helper.tool_foot_side(): _travel_gripping_sole_step=maxf(_travel_gripping_sole_step,step)
			if step>.05 and "--tool-debug" in OS.get_cmdline_user_args():
				print("CONTRAPTION_TOOL_RETURN_SOLE tick=",_tick," side=",side," toolside=",helper.tool_foot_side()," step=",step," old=",previous.soles[side]," new=",pose.evaluated_soles[side]," oldbody=",previous.body," body=",helper.global_position)
		_travel_grip_step = maxf(_travel_grip_step,previous.grip.distance_to(helper.tool_grip_transform.origin))
	_world_previous[id] = {"serial":pose.evaluation_serial,"tool":helper.equipped_tool.get_instance_id(),"soles":pose.evaluated_soles.duplicate(),"grip":helper.tool_grip_transform.origin,"body":helper.global_position}

func _run() -> void:
	var ground := StaticBody3D.new()
	ground.position.y = -.5
	add_child(ground)
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(160,1,160)
	collision.shape = box
	ground.add_child(collision)
	_visual_setup(ground,box)
	yard = Yard.new()
	add_child(yard)
	yard.work_paused = true
	await _advance(.5)
	_park_fauna()
	var replay := "res://.claude/tmp/covered_workshop_upper_triangle_earned22.json"
	var seconds := 90.0
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--tool-return-experiment="): _experiment_path=argument.get_slice("=",1)
		if argument.begins_with("--tool-return-save="): _result_path=argument.get_slice("=",1)
		if argument.begins_with("--tool-return-earned="): replay=argument.get_slice("=",1)
		if argument.begins_with("--tool-return-seconds="): seconds=float(argument.get_slice("=",1))
		if argument.begins_with("--tool-return-captures="): _return_capture_dir=argument.get_slice("=",1)
		if argument.begins_with("--jitter-out="): _return_jitter=true
	_return_motion = "--tool-return-motion" in OS.get_cmdline_user_args()
	if not _return_capture_dir.is_empty(): DirAccess.make_dir_recursive_absolute(_return_capture_dir)
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(replay))
	_check(saved is Dictionary,"travel replay uses an actual earned covered-workshop save")
	if not saved is Dictionary: _finish(); return
	yard.restore(saved)
	await _advance(.5)
	_park_fauna()
	if not _experiment_path.is_empty():
		var experimental: Script = load(_experiment_path)
		for helper: Node in yard.workers:
			var previous: SkeletonModifier3D = helper._pose
			previous.get_parent().remove_child(previous)
			previous.queue_free()
			helper._pose = experimental.new()
			helper._pose.worker = helper
			helper._skeleton.add_child(helper._pose)
			helper.ragdoll._pose=helper._pose
		await _advance(.1)
	_material_before = _material_mass()
	_check(yard.workers.size()==3 and yard.selected_assembly.parts.values().filter(func(p:Node)->bool:return p.installed).size()>=22,
		"original three helpers and genuinely installed upper structure are restored without a placement shortcut")
	print("CONTRAPTION_TOOL_RETURN_SOURCE pose=",FileAccess.get_sha256("res://LogicObjects/Wako/wako_pose.gd")," helper=",FileAccess.get_sha256("res://LogicObjects/Wako/wako_helper.gd")," experiment=",_experiment_path," experimental_sha=",FileAccess.get_sha256(_experiment_path) if not _experiment_path.is_empty() else "production")
	_travel_observing = true
	yard.work_paused = false
	await _advance(seconds)
	_travel_observing = false
	_check(_same_material(_material_before),"ordinary construction/recovery conserves the earned stock and usable offcuts")
	_check(_recovery_samples>500 and _recovery_knee_step<12.0 and _recovery_ankle_step<18.0 and _recovery_tool_angle<18.0 and _recovery_root_step<.025 and _recovery_root_angle<6.0,
		"actual consecutive travel poses retain the original cube, leg and whole-tool motion limits")
	_check(shaft_samples>1000 and visual_samples>250 and shaft_intersections==0 and visual_intersections==0,
		"complete retained tool shafts and reused meshes remain clear throughout real travel and work")
	_check(_recovery_floor_samples>250 and _recovery_tool_floor>=.005-.00001,
		"actual retained-tool travel vertices stay above their observed native support planes")
	_check(_travel_gripping_sole_step<.05 and _travel_grip_step<.05,
		"final world gripping sole and actual toe remain within the existing50mm motion bound")
	var continuations := 0
	var held_frames := 0
	if not _experiment_path.is_empty():
		for helper: Node in yard.workers:
			continuations += helper._pose._tool_return_recoveries
			held_frames += helper._pose._tool_return_held_frames
		_check(continuations>0,"the earned travel exercises actual final whole-tool clearance continuations")
	_check(_role_samples[0]>125 and _role_samples[1]>125,"both original retained-foot roles have actual consecutive earned travel observations")
	print("CONTRAPTION_TOOL_RETURN_ROLES samples=",_role_samples," identities=",_role_transitions)
	print("CONTRAPTION_TOOL_RETURN_CONTINUATIONS candidates=",continuations," held_frames=",held_frames)
	var installed: Array = []
	for part: Node in yard.selected_assembly.parts.values():
		if part.installed: installed.append(part.part_id)
	print("CONTRAPTION_TOOL_RETURN_STATE installed=",installed," joints=",yard.selected_assembly.connections.size())
	if not _result_path.is_empty():
		var output := FileAccess.open(_result_path,FileAccess.WRITE)
		output.store_string(JSON.stringify(yard.serialize(),"\t"))
		output.close()
	_finish()

func _material_mass() -> Dictionary:
	var result := {}
	for assembly: Node in yard.assemblies:
		for part: Node in assembly.parts.values():
			if part.installed: result[part.kind]=float(result.get(part.kind,0))+float(part.definition.mass)
	for part: Node in yard.loose_parts:
		if is_instance_valid(part) and not part.is_queued_for_deletion(): result[part.kind]=float(result.get(part.kind,0))+float(part.definition.mass)
	return result

func _same_material(expected: Dictionary) -> bool:
	var current := _material_mass()
	if current.size()!=expected.size(): return false
	for kind: String in expected:
		if not current.has(kind) or absf(float(current[kind])-float(expected[kind]))>.001: return false
	return true

func _finish() -> void:
	print("CONTRAPTION_TOOL_RETURN samples=",_recovery_samples," knee=",_recovery_knee_step," ankle=",_recovery_ankle_step," tool=",_recovery_tool_angle," root=",_recovery_root_step," angle=",_recovery_root_angle," sole=",_travel_gripping_sole_step," all_soles=",_travel_sole_step," grip=",_travel_grip_step," shaft_samples=",shaft_samples," shaft_hits=",shaft_intersections," mesh_samples=",visual_samples," mesh_hits=",visual_intersections," floor=",_recovery_tool_floor)
	print("CONTRAPTION_TOOL_RETURN ","PASS" if failures==0 else "FAIL"," ticks=",_tick)
	Shortcuts.graceful_quit(0 if failures==0 else 1)

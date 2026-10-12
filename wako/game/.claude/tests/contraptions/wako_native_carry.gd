## Genuine paid head-carry hit/drop lifecycle and both original native pose seams.
extends "res://.claude/tests/contraptions/mobile_tools.gd"
const FinalObserver = preload("res://.claude/tests/contraptions/wako_native_handoff_observer.gd")
var _chosen: Node
var _actual_previous := {}
var _steps := {}
var _case_role := -1
var _case_source: Node
var _case_tool: Node
var _case_job := ""
var _return_steps := {}
var _return_tail := 0
var _capture_dir := ""
var _capture_frame := 0
var _capture_active := false
var _capture_every := 1
var _handoff_capture := 0
var _previous_image: Image
var _previous_image_frame := 0
var _return_markers: Array[Marker3D] = []
var _native_stats := {}
var _earned_path := "res://.claude/tmp/covered_workshop_upper_triangle_earned22.json"

func _process(_delta: float) -> void:
	if not is_instance_valid(_chosen) or _actual_previous.is_empty(): return
	camera.global_position=_actual_previous.root.origin+Vector3(3.8,2.1,4.0)
	camera.look_at(_actual_previous.root.origin)
	_return_markers[0].global_transform=_actual_previous.root
	_return_markers[1].global_position=_actual_previous.soles[0]
	_return_markers[2].global_position=_actual_previous.soles[1]
	_return_markers[3].global_transform=_chosen.tool_anchor.global_transform
	if _capture_dir.is_empty() or not _capture_active: return
	_capture_frame+=1
	var frame := get_viewport().get_texture().get_image()
	if _handoff_capture>0 and _previous_image and not _previous_image.is_empty():
		_previous_image.save_png(_capture_dir.path_join("role%d_%04d.png"%[_case_role,_previous_image_frame]))
	if not frame.is_empty() and (_capture_frame%_capture_every==0 or _handoff_capture>0):
		frame.save_png(_capture_dir.path_join("role%d_%04d.png"%[_case_role,_capture_frame]))
	_handoff_capture=maxi(0,_handoff_capture-1)
	_previous_image=frame
	_previous_image_frame=_capture_frame

func capture_final(helper: Node) -> void:
	if helper!=_chosen: return
	var sk: Skeleton3D = helper._skeleton
	var root: Transform3D = sk.global_transform*sk.get_bone_global_pose(0)
	var soles: Array[Vector3] = []
	var knees: Array[Vector3] = []
	var ankles: Array[Quaternion] = []
	for side in 2:
		var chain: Array = helper._pose._chains[side]
		var foot: Transform3D = sk.get_bone_global_pose(chain[2])
		soles.append(sk.global_transform*(foot*Vector3(0,helper._pose._ankle_height[side],0)))
		knees.append((sk.global_basis*(sk.get_bone_global_pose(chain[1]).origin-sk.get_bone_global_pose(chain[0]).origin)).normalized())
		ankles.append((sk.global_basis*foot.basis).orthonormalized().get_rotation_quaternion())
	var current := {"native":helper.ragdoll.active,"root":root,"soles":soles,"knees":knees,"ankles":ankles}
	if helper.ragdoll.visual.is_returning(): _return_tail=2
	if not _actual_previous.is_empty() and (current.native!=_actual_previous.native or _return_tail>0):
		var stats := {"root":root.origin.distance_to(_actual_previous.root.origin),"angle":rad_to_deg(root.basis.orthonormalized().get_rotation_quaternion().angle_to(_actual_previous.root.basis.orthonormalized().get_rotation_quaternion())),"sole":0.0,"knee":0.0,"ankle":0.0}
		for side in 2:
			stats.sole=maxf(stats.sole,soles[side].distance_to(_actual_previous.soles[side]))
			stats.knee=maxf(stats.knee,rad_to_deg(knees[side].angle_to(_actual_previous.knees[side])))
			stats.ankle=maxf(stats.ankle,rad_to_deg(ankles[side].angle_to(_actual_previous.ankles[side])))
		if current.native!=_actual_previous.native:
			_handoff_capture=2
			_steps["enter" if current.native else "leave"]=stats
			print("NATIVE_CARRY handoff role=",_case_role," phase=","enter" if current.native else "leave"," stats=",stats)
		else:
			_return_steps.samples+=1
			for key: String in stats: _return_steps[key]=maxf(_return_steps[key],stats[key])
	_actual_previous=current
	if not helper.ragdoll.visual.is_returning(): _return_tail=maxi(0,_return_tail-1)
	if current.native:
		_native_stats.samples+=1
		for body in helper.ragdoll.rig.bodies:
			var expected: Transform3D = PhysicsServer3D.body_get_state(body.rid,PhysicsServer3D.BODY_STATE_TRANSFORM)*body.b2b
			var actual: Transform3D = sk.global_transform*sk.get_bone_global_pose(body.bone)
			_native_stats.position=maxf(_native_stats.position,actual.origin.distance_to(expected.origin))
			_native_stats.angle=maxf(_native_stats.angle,rad_to_deg(actual.basis.orthonormalized().get_rotation_quaternion().angle_to(expected.basis.orthonormalized().get_rotation_quaternion())))

func _run() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--native-carry-earned="): _earned_path=argument.get_slice("=",1)
		if argument.begins_with("--native-carry-capture-every="): _capture_every=maxi(1,int(argument.get_slice("=",1)))
		if argument.begins_with("--native-carry-captures="): _capture_dir=argument.get_slice("=",1)
	if not _capture_dir.is_empty(): DirAccess.make_dir_recursive_absolute(_capture_dir)
	var ground := StaticBody3D.new()
	ground.position.y=-.5
	var box := BoxShape3D.new()
	box.size=Vector3(160,1,160)
	var collision := CollisionShape3D.new()
	collision.shape=box
	ground.add_child(collision)
	add_child(ground)
	_visual_setup(ground,box)
	yard=Yard.new()
	add_child(yard)
	yard.work_paused=true
	await _advance(.5)
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(_earned_path)) if FileAccess.file_exists(_earned_path) else null
	_check(saved is Dictionary,"ordinary carry uses genuinely earned stock, bodies and crew from an existing save")
	if not saved is Dictionary:
		Shortcuts.graceful_quit(1)
		return
	for role in 2:
		_case_role=role
		_previous_image=null
		_handoff_capture=0
		_chosen=null
		_actual_previous.clear()
		_steps.clear()
		_native_stats={"samples":0,"position":0.0,"angle":0.0}
		_return_steps={"samples":0,"root":0.0,"angle":0.0,"sole":0.0,"knee":0.0,"ankle":0.0}
		_return_tail=0
		var expected_id := "314673468603" if role==0 else "316720289077"
		var role_save: Dictionary = saved.duplicate(true)
		role_save.paused=true
		for worker_save: Dictionary in role_save.workers: worker_save.paused=worker_save.id!=expected_id
		yard.restore(role_save)
		await _advance(.5)
		_park_fauna()
		for helper: Node in yard.workers:
			helper.paused=helper.worker_id!=expected_id
			if helper.paused: continue
			_chosen=helper
			print("NATIVE_CARRY loaded worker=",helper.worker_id," helper=",helper.get_script().source_code.sha256_text()," pose=",helper._pose.get_script().source_code.sha256_text()," native=",helper.ragdoll.visual.get_script().source_code.sha256_text()," ragdoll=",helper.ragdoll.get_script().source_code.sha256_text())
			var observer := FinalObserver.new()
			observer.worker=helper
			observer.fixture=self
			helper._skeleton.add_child(observer)
		var material_before := _material_mass()
		yard.work_paused=false
		_case_source=null
		for tick in 12000:
			await get_tree().physics_frame
			var entry: Dictionary = yard.coordinator.active_jobs.get(_chosen.current_job_id,{})
			if tick%1200==0: print("NATIVE_CARRY search role=",role," tick=",tick," job=",_chosen.current_job_id," phase=",entry.get("phase","")," status=",_chosen.status_text," needs=",_chosen.needs," body=",_chosen.global_position)
			if entry.is_empty() or entry.crew.size()!=1 or entry.phase not in ["carry","carry_exit","carry_outside","boarding"]: continue
			var source: Node = entry.job.get("part")
			if not is_instance_valid(source) or source!=_chosen._cargo_source or source.carrier!=_chosen.head_anchor or not source.get_meta(&"in_transit",false) or source.mass<5.0 or not is_instance_valid(_chosen.equipped_tool): continue
			_case_source=source
			_case_tool=_chosen.equipped_tool
			_case_job=_chosen.current_job_id
			break
		_check(is_instance_valid(_case_source),"original foot-role crew physically reaches a genuine paid head-carry lease")
		if not is_instance_valid(_case_source): break
		_check(_chosen.tool_foot_side()==role,"saved original worker retains the actual requested tool-foot role")
		var part_id: String = _case_source.part_id
		var tool_id: String = _case_tool.part_id
		var mass: float = _case_source.mass
		var health: float = _case_source.health
		var wear: float = _case_source.wear
		var parameters: Dictionary = _case_source.parameters.duplicate(true)
		print("NATIVE_CARRY before role=",role," worker=",_chosen.worker_id," job=",_case_job," source=",part_id," mass=",mass," tool=",tool_id," action=",_chosen.action)
		_capture_active=true
		if not _capture_dir.is_empty():
			for frame in 12: await get_tree().process_frame
		_check(_chosen.current_job_id==_case_job and _chosen._cargo_source==_case_source and _case_source.carrier==_chosen.head_anchor and _case_source.get_meta(&"in_transit",false) and _chosen.equipped_tool==_case_tool,"actual hit begins with the same paid head source, toe tool and original work lease")
		_chosen.apply_hit(_chosen._model.global_basis.x*(-_chosen.mass*3.55))
		yard.work_paused=true
		_check(_chosen.ragdoll.is_down(),"original loaded strong hit enters native fall using unchanged impulse and cancellation policy")
		_check(_chosen.current_job_id.is_empty() and not yard.coordinator.active_jobs.has(_case_job) and not yard._reservations.has(_case_job) and _chosen.equipped_tool==null and _chosen.cargo_mass==0.0,"original cancellation clears stock lease, tool attachment and duplicate native load")
		_check(_case_source.part_id==part_id and _case_tool.part_id==tool_id and absf(_case_source.mass-mass)<.001 and absf(_case_source.health-health)<.001 and absf(_case_source.wear-wear)<.001 and _case_source.parameters==parameters,"original assisted cancellation preserves exact paid stock identity, condition and parameters")
		for tick in 6000:
			await get_tree().physics_frame
			if not _chosen.ragdoll.is_down() and _steps.has("leave"): break
		for tick in 60: await get_tree().physics_frame
		_check(not _chosen.ragdoll.is_down() and _chosen.ragdoll._cooldown>0.0,"actual native get-up retains original capsule and cooldown restoration")
		for label: String in ["enter","leave"]:
			var stats: Dictionary = _steps.get(label,{})
			_check(not stats.is_empty() and stats.root<.025 and stats.angle<6.0 and stats.sole<.05 and stats.knee<12.0 and stats.ankle<18.0,"genuine loaded %s rig handoff retains original motion bounds"%label)
		_check(_case_source.part_id==part_id and _case_tool.part_id==tool_id and absf(_case_source.mass-mass)<.001 and _case_source.parameters==parameters and _same_material(material_before),"actual native fall conserves the same paid source/tool bodies and finite material")
		_check(_return_steps.samples>20 and _return_steps.root<.025 and _return_steps.angle<6.0 and _return_steps.sole<.05 and _return_steps.knee<12.0 and _return_steps.ankle<18.0,"every genuine loaded native-to-authored return frame retains original continuity bounds")
		_check(_native_stats.samples>125 and _native_stats.position<.0001 and _native_stats.angle<.1,"visible loaded bones remain aligned to actual native bodies throughout the fall")
		var state: Dictionary = yard.serialize()
		_check(state.parts.filter(func(p:Dictionary)->bool:return p.id==part_id).size()==1 and state.parts.filter(func(p:Dictionary)->bool:return p.id==tool_id).size()==1,"ordinary drop JSON retains one original paid source and one original tool")
		print("NATIVE_CARRY return role=",role," stats=",_return_steps," native_samples=",_native_stats.samples," native_error=",_native_stats.position," native_angle=",_native_stats.angle)
		print("NATIVE_CARRY after role=",role," down=",_chosen.ragdoll.is_down()," source=",_case_source.part_id," mass=",_case_source.mass," health=",_case_source.health," wear=",_case_source.wear," tool=",_case_tool.part_id," handoffs=",_steps)
		_capture_active=false
		yard.work_paused=true
		yard.coordinator.cancel_all()
	print("CONTRAPTION_NATIVE_CARRY ","PASS" if failures==0 else "FAIL", " failures=",failures)
	Shortcuts.graceful_quit(0 if failures==0 else 1)


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

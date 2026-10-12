extends "res://.claude/tests/contraptions/wako_recoil.gd"
## Actual live hostile bodies and scheduler parking requests drive the cue.
const Yard = preload("res://Components/Contraptions/contraption_yard.gd")
const Fauna = preload("res://Components/Contraptions/machine_fauna.gd")
var yard: Node3D
var hostile: Node3D
var _visible_cue := 0.0
var _peak_speed := 0.0
var _travel := 0.0
var _start := Vector3.ZERO
var _watch_impacts := 0
var _watch_serial := -1
var _support_samples := 0
var _supported_watch := true

func _ready() -> void:
	super._ready()
	_motion = "--threat-motion" in OS.get_cmdline_user_args()
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--threat-captures="): _capture_dir = arg.trim_prefix("--threat-captures=")

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if not _watch_motion or not is_instance_valid(worker) or not worker._pose.evaluated_valid: return
	_peak_speed = maxf(_peak_speed,worker.gait_speed)
	_travel = maxf(_travel,(worker.global_position-_start).slide(Vector3.UP).length())
	var cue: SkeletonModifier3D = worker.threat_watch
	if cue.weight<=.2 or not is_instance_valid(cue.threat): return
	var pose: SkeletonModifier3D = worker._pose
	if pose.evaluation_serial!=_watch_serial:
		_watch_serial = pose.evaluation_serial
		_support_samples += 1
		var planted: int = 1-worker.tool_foot_side()
		_supported_watch = _supported_watch and worker.on_ground and pose.evaluated_grounded[planted] and absf(pose.evaluated_soles[planted].y)<.035 and pose._support[planted].get_ref()==_floor
	var clip: Animation = worker._animation.get_animation(worker._animation.current_animation)
	var index := -1
	for track in clip.get_track_count():
		if clip.track_get_type(track)==Animation.TYPE_ROTATION_3D and clip.track_get_path(track).get_subname(0)=="Bone": index = track; break
	if index<0: return
	var base: Vector3 = clip.rotation_track_interpolate(index,worker._animation.current_animation_position)*Vector3.UP
	var up: Vector3 = worker._pose.evaluated_basis.inverse()*worker._pose.evaluated_root.basis.y
	var away: Vector3 = (worker._pose.evaluated_basis.inverse()*cue.direction).slide(Vector3.UP).normalized()
	_visible_cue = maxf(_visible_cue,(up-base).dot(away))

func _fixture_yard() -> void:
	yard = Yard.new()
	yard.position = Vector3(12.5,0,-7)
	add_child(yard)
	yard.work_paused = true
	await _advance(.4)
	# Keep the real safety/scheduler implementations, isolating one helper and
	# one hostile rather than letting unrelated construction/fire supply cues.
	for collection: Array in [yard.workers,yard.enemies,yard.assemblies,yard.loose_parts]:
		for node: Node in collection.duplicate(): node.queue_free()
		collection.clear()
	yard.coordinator.workers.clear()
	yard._plans.clear()
	await _advance(.1)

func _escape(direction_name: String, side: int) -> void:
	stage = "cover_%s_%d"%[direction_name,side]
	worker = Worker.instantiate()
	worker.position.y = .85
	for number in 100:
		var id := "threat_%d_%d"%[side,number]
		if absi(id.hash())%2==side: worker.worker_id = id; break
	worker.configure(yard.coordinator)
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
	_tool_vertices.clear()
	_collect_vertices(tool,_tool_vertices)
	await _advance(.4)
	_start = worker.global_position
	_peak_speed = 0.0
	_travel = 0.0
	_visible_cue = 0.0
	_watch_serial = -1
	_support_samples = 0
	_supported_watch = true
	var incoming: Vector3 = worker._model.global_basis*worker.recoil.DIRECTIONS[direction_name]
	hostile = Fauna.new()
	yard.add_child(hostile)
	hostile.configure(yard,"dune_runner",worker.global_position+incoming*6.0-Vector3.UP*worker.ride_height)
	# The actual finite machine and live threat identity remain. Deferred AI
	# startup has finished before its independent motion/weapons are isolated.
	await _advance(.3)
	hostile.set_physics_process(false)
	hostile.assembly.active = false
	if is_instance_valid(hostile.mind_host): hostile.mind_host.shutdown()
	for body: RigidBody3D in hostile.assembly.parts.values(): body.freeze = true
	yard.enemies.append(hostile)
	var before := contact_events
	_previous.clear()
	_debug_knees.clear()
	_last_soles.clear()
	_last_sole_serial = -1
	_last_tool_valid = false
	_watch_motion = true
	yard.work_paused = false
	yard.coordinator.refresh_jobs()
	_check(yard.unsafe_at(worker.global_position) and worker.has_target and worker.status_text=="Taking cover" and worker.fear_time==0.0,
		"%s uses real enemy safety and the existing sheltered walking request without adding hit fear"%stage)
	await _advance(3.8)
	_check(worker.threat_watch.observations>60 and _support_samples>60 and _supported_watch and _visible_cue>.015 and _travel>.5 and _peak_speed>.8 and _peak_speed<2.11,
		"%s walks to actual cover at the original finite speed, then visibly watches away from the real threat"%stage)
	# Keep this actual hostile/cover/payload state alive for the probe. Its
	# graceful shutdown can outlast recording; later hit assertions must not
	# mistake that deliberately cancelled action clock for a recovery failure.
	if _jitter: return
	if direction_name=="front":
		_source_clip = worker._animation.get_animation("wk_interrupted_"+("L" if side==0 else "R"))
		for track in _source_clip.get_track_count():
			if _source_clip.track_get_type(track)==Animation.TYPE_ROTATION_3D and _source_clip.track_get_path(track).get_subname(0)=="Bone": _source_track = track; break
		_case_direction = "front"
		_spawn_impactor("front")
		for tick in 90:
			await get_tree().physics_frame
			if worker.recoil.events>0: break
		var impact: float = worker.recoil.last_impulse.length()/worker.mass
		_check(worker.recoil.events==1 and impact>2.5 and impact<=3.5 and not worker.ragdoll.is_down(),
			"%s actual hit hands the authored shelter watch to the original grounded recoil"%stage)
		impactor.collision_layer = 0
		impactor.collision_mask = 0
		await _advance(.6)
		_check(worker.action=="interrupted" and contact_events==before and worker.threat_watch.weight==0.0,
			"%s watches safely yield to actual hit recovery without an abandoned work contact"%stage)
		await _advance(.6)
		_check(worker.action.is_empty() and contact_events==before,"%s completes actual hit recovery before watching again"%stage)
		impactor.queue_free()
		_watch_impacts += 1
	yard.enemies.erase(hostile)
	hostile.queue_free()
	await _advance(1.0)
	_watch_motion = false
	_check(worker.threat_watch.weight==0.0 and not is_instance_valid(worker.threat_watch.threat) and contact_events==before,
		"%s blends out after the actual threat leaves without a work contact"%stage)
	_check(tool.carrier==worker.tool_anchor and cargo.carrier==worker.head_anchor and is_equal_approx(worker.mass,22+tool.mass+cargo.mass),
		"%s keeps the same idle toe tool and head load under the existing payload policy"%stage)
	print("WAKO_THREAT case=",stage," cue=",_visible_cue," speed=",_peak_speed," travel=",_travel," observations=",worker.threat_watch.observations," remaining=",worker.threat_watch.weight)
	yard.work_paused = true
	# Finish native follower ownership before deleting this isolated crew. The
	# coordinator's real removal callback otherwise defers abandoning this tool.
	worker.set_equipped_tool(null)
	tool.set_carried(null)
	cargo.set_carried(null)
	worker.set_cargo(0.0)
	for node: Node in [worker,tool,cargo]: node.queue_free()
	await _advance(.1)

func _run() -> void:
	if not _capture_dir.is_empty(): DirAccess.make_dir_recursive_absolute(_capture_dir)
	_floor_setup()
	await _fixture_yard()
	for side in 2:
		for direction_name: String in ["front","back","left","right"]:
			await _escape(direction_name,side)
			if _jitter: return # The probe owns shutdown of the continuing real watch.
	_check(_watch_impacts==2 and recoil_samples>1000 and _root_step<.025 and _root_angle<6 and _knee_step<12 and _ankle_step<18 and maximum_tool_turn<18 and maximum_sole_step<.05,
		"actual threat/shelter transitions retain continuous evaluated cube, soles, knees, ankles and whole-tool orientation")
	_check(_shaft_intersections==0 and _mesh_intersections==0 and _tool_floor>=.005 and minimum_sole>-.005,
		"the same full-sized tool and evaluated soles remain clear of the cube and actual native floor")
	_check(_head_gap<.01 and _cargo_gap<.01 and _cargo_angle<1 and _tool_gap<.01 and _tool_angle<1,
		"the same head load and toe tool follow their evaluated attachments throughout escape")
	print("WAKO_THREAT metrics samples=%d root=%.4f/%.3f knee=%.3f ankle=%.3f tool=%.3f sole=%.4f shaft=%d mesh=%d floor=%.4f sole_floor=%.4f"%[recoil_samples,_root_step,_root_angle,_knee_step,_ankle_step,maximum_tool_turn,maximum_sole_step,_shaft_intersections,_mesh_intersections,_tool_floor,minimum_sole])
	print("WAKO_THREAT %s"%["PASS" if failures==0 else "FAIL (%d)"%failures])
	Shortcuts.graceful_quit(0 if failures==0 else 1)

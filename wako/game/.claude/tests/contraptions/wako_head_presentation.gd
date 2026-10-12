extends "res://.claude/tests/contraptions/wako_cooperative_carry.gd"
## Observe the real eyes/caption through an earned cooperative stage event.
## The assisted HeadCargo fixture and the same finite source remain untouched.
var _presentation := {}
var _previous := {}
var _stage_seen := false
var _stage_source := ""
var _stage_mass := 0.0
var _proof_finished := false

func _ready() -> void:
	super._ready()
	_carry_duration=24.0

func _run() -> void:
	if "--head-presentation-yard" not in OS.get_cmdline_user_args():
		super._run()
		return
	var world := World.instantiate()
	add_child(world)
	await _advance(.2)
	yard=world.get_node("ContraptionYard")
	yard.work_paused=true
	var saved: Variant=JSON.parse_string(FileAccess.get_file_as_string("res://.claude/tmp/wako_cooperative_yard_earned_carry.json"))
	_check(saved is Dictionary,"presentation proof restores the genuine original right-foot carry save")
	if not saved is Dictionary:
		Shortcuts.graceful_quit(1)
		return
	saved.paused=true
	yard.restore(saved)
	await _advance(.5)
	_park_fauna()
	_expected_roles=[0,1]
	_expected_tool_roles=[1]
	yard.work_paused=false
	_observing=true

func _process(delta: float) -> void:
	super._process(delta)
	if not is_instance_valid(_view): return
	# A closer observational view makes the existing real work caption readable.
	_view.global_position=_shot_center+Vector3(4,3,4)
	_view.look_at(_shot_center,Vector3.UP)

func _start_motion(entry: Dictionary) -> void:
	super._start_motion(entry)
	for helper: Node in entry.crew: helper._label.add_to_group(&"field_headload_motion")

func _observe_jobs() -> void:
	# Salvage targets in the genuine Yard replay are storage nodes, not parts.
	if "--head-presentation-yard" not in OS.get_cmdline_user_args(): super._observe_jobs()

func capture_final(helper: Node) -> void:
	if _proof_finished or not _carry_crew.has(helper) or not helper._pose.evaluated_valid: return
	var id: String=helper.worker_id
	var pose: SkeletonModifier3D=helper._pose
	var before: Dictionary=_previous.get(id,{})
	if before.get("serial",-1)==pose.evaluation_serial: return
	var sk: Skeleton3D=helper._skeleton
	var own_head: Vector3=sk.global_transform*(sk.get_bone_global_pose(0)*Vector3(0,helper.HEAD_OFFSET,0))
	if not _presentation.has(id):
		_presentation[id]={"samples":0,"face_error":0.0,"caption_step":0.0,"clearance":INF,"gaze_step":0.0,"logical_jump":0.0,"release_source_step":0.0,"preparing":0,"inspecting":0,"owner":helper.task_label_owner}
	var stats: Dictionary=_presentation[id]
	stats.samples+=1
	stats.face_error=maxf(stats.face_error,own_head.distance_to(helper._visual_head_point))
	if not before.is_empty():
		stats.caption_step=maxf(stats.caption_step,absf(helper._label.position.y-float(before.caption)))
		stats.gaze_step=maxf(stats.gaze_step,helper._eye_gaze.distance_to(before.gaze))
		if before.carrying and not helper.carrying:
			stats.logical_jump=helper.head_anchor.global_position.distance_to(before.head)
			stats.release_source_step=_carry_source.global_position.distance_to(before.source)
	if helper.carrying and helper._caption_source_id==_carry_source.get_instance_id():
		var actual: AABB=_carry_source.global_transform*helper._caption_source_bounds
		stats.clearance=minf(stats.clearance,helper._label.global_position.y-actual.end.y)
	var entry: Dictionary=yard.coordinator.active_jobs.get(_carry_job,{})
	if not entry.is_empty() and entry.get("staged",false):
		_stage_seen=true
		_stage_source=_carry_source.part_id
		_stage_mass=_carry_source.mass
		if helper._label.text.contains("Preparing inspection") and not helper.carrying and entry.phase=="staging": stats.preparing+=1
		if entry.phase=="inspect" and helper.action=="inspect": stats.inspecting+=1
	_previous[id]={"serial":pose.evaluation_serial,"caption":helper._label.position.y,"gaze":helper._eye_gaze,"head":helper.head_anchor.global_position,"source":_carry_source.global_position,"carrying":helper.carrying}
	if _presentation.size()==2 and _presentation.values().all(func(s:Dictionary)->bool:return s.inspecting>30): _finish_carry.call_deferred()

func _finish_carry() -> void:
	if _proof_finished: return
	_proof_finished=true
	_ended=true
	_check(_stage_seen and _stage_source=="stock_35" and absf(_stage_mass-48.0)<.001,"real stage retains the same finite original 48kg source")
	_check(is_instance_valid(_carry_source.carrier) and _carry_source.carrier==_carry_source.get_meta(&"staged_target",null),"the original assisted stage owns its source without a new head follower")
	for id: String in _presentation:
		var stats: Dictionary=_presentation[id]
		print("HEAD_PRESENTATION worker=",id," stats=",stats)
		_check(stats.samples>125 and stats.face_error<.0001,"actual final own-face origin is used for eyes of "+id)
		_check(stats.caption_step<.05 and stats.clearance>.30,"real payload caption stays clear and returns continuously for "+id)
		_check(stats.gaze_step<.004,"existing eye-gaze transition remains continuous for "+id)
		if stats.owner: _check(stats.preparing>0,"successful stage announces preparation before inspection")
	_check(_presentation.size()==2 and _presentation.values().any(func(s:Dictionary)->bool:return s.logical_jump>1.0 and s.release_source_step<.05),"the raw unused fixture reset remains recorded while staged stock stays continuous")
	_check(_inventory()==_carry_before,"presentation preserves all actual stock and tool material")
	print("CONTRAPTION_HEAD_PRESENTATION ","PASS" if failures==0 else "FAIL"," failures=",failures)
	if is_instance_valid(_carry_motion_probe):
		while _carry_motion_probe._phase!="done": await get_tree().process_frame
	Shortcuts.graceful_quit(0 if failures==0 else 1)

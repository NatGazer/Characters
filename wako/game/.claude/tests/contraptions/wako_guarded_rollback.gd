extends "res://.claude/tests/contraptions/wako_tool_return.gd"
## Ordinary earned roof work; only the isolated pose solver is substituted.
const Prototype := preload("res://.claude/tmp/wako_guarded_rollback_pose.gd")
const Guarded := preload("res://LogicObjects/Wako/wako_guarded_rollback.gd")
const FinalObserve := preload("res://.claude/tests/contraptions/wako_native_handoff_observer.gd")
var _guarded_done := false
var _held_jobs := {}
var _guarded_contacts := 0
var _guarded_samples := 0
var _guarded_cancelled := 0
var _guarded_recovered := 0
var _negative := false
var _negative_blocker: StaticBody3D
var _negative_worker: Node
var _negative_added_tick := -1
var _guarded_body_contacts := 0
var _guarded_prior := {}
var _guarded_seam_samples := 0
var _guarded_blocked_work := false
var _guarded_seam_tail := {}

func _ready() -> void:
	_negative="--guarded-negative" in OS.get_cmdline_user_args()
	super._ready()

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if _guarded_done or not is_instance_valid(yard): return
	for helper: Node in yard.workers:
		if helper._pose.get_script()!=Prototype: continue
		if _negative and helper==_negative_worker and _tick>_negative_added_tick+1:
			_negative_test(helper)
			return
		if helper._pose._guarded_refusals>0:
			_check(false,"live current geometry has no admitted rollback; unresolved path is not published as success")
			_guarded_finish.call_deferred()
			return
		if _held_jobs.has(helper.worker_id):
			var held: Dictionary=_held_jobs[helper.worker_id]
			if not held.cancelled and not yard.coordinator.active_jobs.has(held.job):
				held.cancelled=true
				_guarded_cancelled+=1
				_check(not yard._reservations.has(held.job),"ordinary cancellation releases the same original reservation")
			if held.cancelled and not held.recovered and helper.action.is_empty() and helper._pose.evaluated_valid and not helper._pose._guarded_returning and not helper._pose._guarded_held:
				held.recovered=true
				_guarded_recovered+=1
				_check(helper.equipped_tool==held.tool,"ordinary supported recovery retains the exact original toe tool")

func capture_final(helper: Node) -> void:
	if _guarded_done or helper._pose.get_script()!=Prototype or not helper._pose.evaluated_valid: return
	var pose: SkeletonModifier3D=helper._pose
	var sk: Skeleton3D=helper._skeleton
	if pose._guarded_held:
		_guarded_samples+=1
		var actual: Dictionary=Guarded.observe(pose,sk)
		if not actual.accepted: _check(false,"published retained frame passes fresh complete guards: "+actual.reason)
		if helper.foot_grip_valid or helper.foot_contact_ready(): _check(false,"blocked retained frame cannot emit work contact")
		if not _held_jobs.has(helper.worker_id) and not helper.current_job_id.is_empty():
			var entry: Dictionary=yard.coordinator.active_jobs.get(helper.current_job_id,{})
			if not entry.is_empty():
				_held_jobs[helper.worker_id]={"job":helper.current_job_id,"source":entry.job.part,"source_id":entry.job.part.part_id,
					"tool":helper.equipped_tool,"cancelled":false,"recovered":false}
				print("GUARDED_ROLLBACK_ACTUAL_LEASE worker=",helper.worker_id," role=",helper.tool_foot_side()," job=",helper.current_job_id," phase=",entry.phase," source=",entry.job.part.part_id," tool=",helper.equipped_tool.part_id," exhausted=",pose._guarded_exhaustions)
	var previous: Dictionary=_guarded_prior.get(helper.worker_id,{})
	var fresh: Dictionary=Guarded.observe(pose,sk)
	if pose._guarded_held or pose._guarded_returning: _guarded_seam_tail[helper.worker_id]=2
	var tail: int=_guarded_seam_tail.get(helper.worker_id,0)
	if fresh.accepted:
		if not previous.is_empty() and (tail>0 or _held_jobs.has(helper.worker_id) and not _held_jobs[helper.worker_id].recovered):
			var seam: Dictionary=Guarded.observe(pose,sk,previous)
			_guarded_seam_samples+=1
			if not seam.accepted: _check(false,"actual guarded/cancel/recovery seam: "+seam.reason)
		_guarded_prior[helper.worker_id]=fresh
	if not pose._guarded_held and not pose._guarded_returning and tail>0: _guarded_seam_tail[helper.worker_id]=tail-1
	if not _negative: return
	if not is_instance_valid(_negative_blocker) and not pose._guarded_frame.is_empty():
		_negative_worker=helper
		_negative_blocker=StaticBody3D.new()
		_negative_blocker.name="DeliberateForeignToolObstruction"
		_negative_blocker.collision_layer=1
		add_child(_negative_blocker)
		_negative_blocker.global_position=helper.equipped_tool.global_position
		var shape:=CollisionShape3D.new()
		var box:=BoxShape3D.new()
		box.size=Vector3(.08,.08,.08)
		shape.shape=box
		_negative_blocker.add_child(shape)
		_negative_added_tick=_tick
		return

func _negative_test(helper: Node) -> void:
	var pose: SkeletonModifier3D=helper._pose
	var sk: Skeleton3D=helper._skeleton
	var before:=Guarded.capture(sk)
	var body: Transform3D=helper.global_transform
	var velocity: Vector3=helper.linear_velocity
	var tool: RigidBody3D=helper.equipped_tool
	var tool_pose: Transform3D=tool.global_transform
	var source_id: String=helper.current_job_id
	var result:=Guarded.rollback(pose,sk,pose._guarded_frame)
	print("GUARDED_ROLLBACK_NEGATIVE result=",result," tool=",tool.part_id," worker=",helper.worker_id," role=",helper.tool_foot_side())
	_check(not result.accepted and result.reason=="Current native tool/foreign solid contact","actual foreign solid invalidates the previously guarded tool frame")
	_check(Guarded.capture(sk)==before and helper.global_transform==body and helper.linear_velocity==velocity and tool.global_transform==tool_pose and helper.equipped_tool==tool and helper.current_job_id==source_id,
		"refused rollback changes no bones, native pose/velocity, actual tool identity or lease")
	_guarded_body_contacts+=1
	_guarded_finish.call_deferred()

func _run() -> void:
	if "--guarded-parse-only" in OS.get_cmdline_user_args():
		_check(true,"unused rollback module and isolated earned fixture parse")
		_guarded_finish()
		return
	var ground:=StaticBody3D.new()
	ground.position.y=-.5
	add_child(ground)
	var collision:=CollisionShape3D.new()
	var box:=BoxShape3D.new()
	box.size=Vector3(160,1,160)
	collision.shape=box
	ground.add_child(collision)
	_visual_setup(ground,box)
	yard=Yard.new()
	add_child(yard)
	yard.work_paused=true
	await _advance(.5)
	_park_fauna()
	var path:="res://.claude/tmp/covered_central_roof_paid_partial32.json"
	var seconds:=35.0
	_guarded_blocked_work="--guarded-blocked-work" in OS.get_cmdline_user_args()
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--guarded-earned="): path=argument.get_slice("=",1)
		if argument.begins_with("--guarded-seconds="): seconds=clampf(float(argument.get_slice("=",1)),5,60)
	var saved: Variant=JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(saved is Dictionary,"guarded replay restores genuinely earned original stock and crew")
	if not saved is Dictionary: _guarded_finish(); return
	yard.restore(saved)
	await _advance(.5)
	_park_fauna()
	for helper: Node in yard.workers:
		var old: SkeletonModifier3D=helper._pose
		var index:=old.get_index()
		old.active=false
		var prototype:=Prototype.new()
		prototype.worker=helper
		helper._skeleton.add_child(prototype)
		helper._skeleton.move_child(prototype,index)
		# Continue the actual original mid-job histories; replacing a solver
		# must not create an unrelated authored entry/release seam.
		for property: Dictionary in old.get_property_list():
			if (int(property.usage)&PROPERTY_USAGE_SCRIPT_VARIABLE)==0: continue
			var value: Variant=old.get(property.name)
			if value is Array or value is Dictionary: value=value.duplicate(true)
			prototype.set(property.name,value)
		var incoming:=Guarded.capture(helper._skeleton)
		helper.ragdoll.visual.restore_actual(helper,helper._skeleton)
		var initial:=Guarded.observe(prototype,helper._skeleton)
		if initial.accepted: prototype._guarded_frame=initial
		Guarded.restore(helper._skeleton,incoming)
		helper._pose=prototype
		helper.ragdoll._pose=prototype
		old.queue_free()
		var observer:=FinalObserve.new()
		observer.worker=helper
		observer.fixture=self
		helper._skeleton.add_child(observer)
		helper.action_contact.connect(func(_kind:String)->void:
			if helper._pose._guarded_held: _guarded_contacts+=1)
	_material_before=_material_mass()
	print("GUARDED_ROLLBACK_SOURCE production=",FileAccess.get_sha256("res://LogicObjects/Wako/wako_pose.gd")," prototype=",yard.workers[0]._pose.get_script().source_code.sha256_text()," module=",FileAccess.get_sha256("res://LogicObjects/Wako/wako_guarded_rollback.gd")," earned=",path," crew=",yard.workers.map(func(w:Node)->Array:return [w.worker_id,w.tool_foot_side()]))
	yard.work_paused=false
	_travel_observing=true
	await _advance(seconds)
	_guarded_finish()

func _guarded_finish() -> void:
	if _guarded_done: return
	_guarded_done=true
	var exhaustions:=0
	var holds:=0
	var refusals:=0
	if is_instance_valid(yard):
		for helper: Node in yard.workers:
			if helper._pose.get_script()==Prototype:
				exhaustions+=helper._pose._guarded_exhaustions
				holds+=helper._pose._guarded_holds
				refusals+=helper._pose._guarded_refusals
		_check(_same_material(_material_before),"ordinary job/rollback preserves all original material and usable offcuts")
		if _negative: _check(_guarded_body_contacts==1,"the current-invalid negative was actually observed")
		else:
			if _guarded_blocked_work:
				_check(holds>0 and _guarded_samples>0 and _guarded_seam_samples>125,"actual blocked work prep/cancel recovery publishes guarded continuous frames")
			else: _check(exhaustions>0 and holds>0 and _guarded_samples>0,"ordinary controller/geometry actually exhausts all retained candidates and publishes guarded rollback")
			_check(_guarded_cancelled>0 and _guarded_recovered>0,"real original job cancels and returns through supported recovery")
		_check(_guarded_contacts==0,"no blocked rollback frame emits a work contact event")
	print("CONTRAPTION_GUARDED_ROLLBACK ","PASS" if failures==0 else "FAIL"," scope=","current_invalid" if _negative else "blocked_work" if _guarded_blocked_work else "all_rejected"," exhausted=",exhaustions," held=",holds," refused=",refusals," published_samples=",_guarded_samples," seams=",_guarded_seam_samples," contacts=",_guarded_contacts," cancelled=",_guarded_cancelled," recovered=",_guarded_recovered," ticks=",_tick)
	Shortcuts.graceful_quit(0 if failures==0 else 1)

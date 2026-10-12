extends "res://.claude/tests/contraptions/wako_material_setback_stroke.gd"
## Ordinary earned lease/cancellation. No diagnostic worker or stock placement.
const Frame := preload("res://LogicObjects/Wako/wako_guarded_rollback.gd")
var _live_done := false
var _live_prior := {}
var _live_safe := {}
var _live_case := {}
var _live_material := {}
var _live_attempts: Array[Dictionary] = []
var _live_attempt_jobs := {}
var _live_seconds := 35.0
var _live_contacts := 0
var _live_samples := 0
var _live_guard_failures := 0
var _live_motion := {"sole":0.0,"grip":0.0,"knee":0.0,"ankle":0.0,"tool":0.0,"root":0.0,"root_angle":0.0}
var _live_routes := {}
var _live_sections := {}
var _live_guard_reasons := {}
var _stop_after_recovery := false
var _right_availability := false
var _paused_crew: Array[Dictionary] = []
var _trace_pickup := false
var _pickup_trace_samples := 0

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if _live_done or not is_instance_valid(yard) or yard._restoring: return
	for entry: Dictionary in yard.coordinator.active_jobs.values():
		if entry.job.get("target")!=yard.selected_assembly.parts.roof: continue
		for worker: RigidBody3D in entry.crew:
			var key: String=worker.worker_id+":"+str(entry.phase)
			if _live_routes.has(key): continue
			_live_routes[key]=true
			print("MATERIAL_LEASE_NATIVE_ROUTE tick=",_tick," worker=",worker.worker_id," role=",worker.tool_foot_side()," phase=",entry.phase," native=",worker.global_transform," support=",worker._ground_body," ground_point=",worker._ground_point," ground_normal=",worker.ground_normal," ground=",worker.on_ground," navigation=",worker.has_target," destination=",worker.target_position," source=",entry.job.part.part_id," source_carrier=",entry.job.part.carrier," access=",_actual_access(entry,worker))

func _actual_access(entry: Dictionary,worker: RigidBody3D) -> Dictionary:
	var route: Dictionary=entry.get("access",{}).get(worker.worker_id,{})
	if route.is_empty(): return {}
	var points: Array=route.get("points",[])
	var step: int=int(route.get("step",-1))
	return {"ramp":route.get("ramp"),"step":step,"count":points.size(),"first":points[0] if not points.is_empty() else Vector3.INF,"last":points[-1] if not points.is_empty() else Vector3.INF,"current":points[step] if step>=0 and step<points.size() else Vector3.INF,"ground":worker._ground_point,"actual_body":worker.global_position,"final_horizontal_error":(worker.global_position-points[-1]).slide(Vector3.UP).length() if not points.is_empty() else INF}

func _run() -> void:
	_stop_after_recovery="--material-lease-stop-after-recovery" in OS.get_cmdline_user_args()
	_right_availability="--material-lease-right-availability" in OS.get_cmdline_user_args()
	_trace_pickup="--material-lease-pickup-trace" in OS.get_cmdline_user_args()
	if "--material-lease-parse-only" in OS.get_cmdline_user_args():
		_check(true,"ordinary material lease/cancel prototype parses without production hooks")
		_live_finish()
		return
	var ground := StaticBody3D.new()
	ground.position.y=-.5
	add_child(ground)
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size=Vector3(160,1,160)
	collision.shape=box
	ground.add_child(collision)
	yard=Yard.new()
	add_child(yard)
	yard.work_paused=true
	_observing=true
	await _advance(.5)
	_park_fauna()
	var path := "res://.claude/tmp/covered_central_roof_paid_partial32.json"
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--material-lease-earned="): path=argument.get_slice("=",1)
		if argument.begins_with("--material-lease-seconds="): _live_seconds=clampf(argument.get_slice("=",1).to_float(),5.0,70.0)
	var saved: Variant=JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(saved is Dictionary,"ordinary material observation uses the genuine earned partial")
	if not saved is Dictionary: _live_finish(); return
	yard.restore(saved)
	yard.work_paused=true
	await _advance(.5)
	_park_fauna()
	var machine: Node3D=yard.selected_assembly
	_check(machine.parts.values().filter(func(part:Node)->bool:return part.installed).size()==32 and machine.connections.size()==40 and not machine.parts.roof.installed,"actual original 32 bodies/40 links and unfinished roof are restored")
	_live_material=_material_mass()
	for helper: RigidBody3D in yard.workers:
		if _right_availability and helper.tool_foot_side()==0:
			_paused_crew.append({"worker":helper,"paused":helper.paused})
			helper.paused=true
		var old: SkeletonModifier3D=helper._pose
		var index: int=old.get_index()
		old.active=false
		var trial:=SetbackPose.new()
		trial.worker=helper
		helper._skeleton.add_child(trial)
		helper._skeleton.move_child(trial,index)
		for property: Dictionary in old.get_property_list():
			if (int(property.usage)&PROPERTY_USAGE_SCRIPT_VARIABLE)==0: continue
			var value: Variant=old.get(property.name)
			if value is Array or value is Dictionary: value=value.duplicate(true)
			trial.set(property.name,value)
		trial.material_fixture=self
		helper._pose=trial
		helper.ragdoll._pose=trial
		old.queue_free()
		var observer:=LastObserver.new()
		observer.worker=helper
		observer.fixture=self
		helper._skeleton.add_child(observer)
		helper.action_contact.connect(func(kind:String)->void:
			if not _live_case.is_empty() and helper==_live_case.worker and _live_case.blocked and kind in ["inspect","assemble"]: _live_contacts+=1)
	print("MATERIAL_LEASE_SOURCE production=",FileAccess.get_sha256("res://LogicObjects/Wako/wako_pose.gd")," helper=",FileAccess.get_sha256("res://LogicObjects/Wako/wako_helper.gd")," coordinator=",FileAccess.get_sha256("res://Components/Contraptions/work_coordinator.gd")," trial=",FileAccess.get_sha256("res://.claude/tmp/wako_material_setback_pose.gd")," module=",FileAccess.get_sha256("res://.claude/tests/contraptions/wako_material_setback.gd")," earned=",path," original_crew=",yard.workers.map(func(w:Node)->Array:return [w.worker_id,w.tool_foot_side(),w.global_transform,w.equipped_tool.part_id]))
	if _right_availability: print("MATERIAL_LEASE_AVAILABILITY player_crew_pause=",_paused_crew.map(func(record:Dictionary)->Array:return [record.worker.worker_id,record.worker.tool_foot_side(),record.paused,record.worker.paused])," body_source_roles_and_admission_unchanged=true")
	yard.work_paused=false
	await _advance(_live_seconds)
	_live_finish()

func _lease(worker: RigidBody3D) -> Dictionary:
	if not is_instance_valid(yard) or yard._restoring or not yard.coordinator.active_jobs.has(worker.current_job_id): return {}
	var entry: Dictionary=yard.coordinator.active_jobs[worker.current_job_id]
	var job: Dictionary=entry.job
	if job.kind not in ["build","replace"] or job.target!=yard.selected_assembly.parts.roof or entry.phase not in ["inspect","work"]: return {}
	var source: Node3D=job.get("part")
	if not is_instance_valid(source) or not is_instance_valid(worker.equipped_tool) or source.carrier!=job.target or source.get_meta(&"staged_target",null)!=job.target or not source.get_meta(&"in_transit",false): return {}
	var reservation: Dictionary=yard._reservations.get(worker.current_job_id,{})
	if reservation.get("part_instance",0)!=source.get_instance_id() or not reservation.get("workers",[]).has(worker.get_instance_id()) or reservation.get("tool_instance",0)!=worker.equipped_tool.get_instance_id() or job.get("tool")!=worker.equipped_tool: return {}
	return {"entry":entry,"job":job,"source":source,"tool":worker.equipped_tool,"reservation":reservation}

func material_withdrawal(pose: SkeletonModifier3D,contact: Vector3,axis: Vector3,distance: float) -> Vector3:
	var lease: Dictionary=_lease(pose.worker)
	if lease.is_empty(): return contact-axis*distance
	return contact-lease.source.global_basis.y.normalized()*distance

func apply_material_setback(pose: SkeletonModifier3D,sk: Skeleton3D) -> bool:
	var worker: RigidBody3D=pose.worker
	var lease: Dictionary=_lease(worker)
	if lease.is_empty():
		var returning: bool=not _live_case.is_empty() and _live_case.worker==worker and _live_case.blocked and not yard.coordinator.active_jobs.has(_live_case.job_id) and worker.equipped_tool==_live_case.tool and worker.action in ["interrupted",""] and (not _live_case.recovered or _tick<=_live_case.recovery_tick+2)
		return _guard_cancel_return(pose,sk) if returning else true
	var source: RigidBody3D=lease.source
	var native: Dictionary=_actual_material_bounds(source)
	if not native.accepted: _check(false,native.reason); return false
	var parent: RigidBody3D=yard.selected_assembly.parts.roof_tie
	if _live_case.is_empty():
		_live_case={"worker":worker,"source":source,"source_id":source.part_id,"source_instance":source.get_instance_id(),"source_rid":source.get_rid(),"parameters":source.parameters.duplicate(true),"health":source.health,"wear":source.wear,"tool":worker.equipped_tool,"tool_id":worker.equipped_tool.part_id,"job_id":worker.current_job_id,"started":_tick,"blocked":false,"cancelled":false,"recovered":false,"held":0,"contacts_at_block":0}
		print("MATERIAL_LEASE_ACTUAL worker=",worker.worker_id," role=",worker.tool_foot_side()," tool=",worker.equipped_tool.part_id," source=",source.part_id," rid=",source.get_rid()," phase=",lease.entry.phase," action=",worker.action," body=",worker.global_transform," source_pose=",source.global_transform," reservation=",lease.reservation," native_ground=",worker._ground_point," ground_normal=",worker.ground_normal," access=",_actual_access(lease.entry,worker))
	var attempt: Dictionary={"worker":worker.worker_id,"job":worker.current_job_id,"source":source.part_id}
	if _live_attempt_jobs.get(worker.worker_id,"")!=worker.current_job_id:
		_live_attempt_jobs[worker.worker_id]=worker.current_job_id
		_live_attempts.append(attempt)
		print("MATERIAL_LEASE_SCHEDULER actual_attempt=",attempt," tick=",_tick)
	var previous: Dictionary=_live_prior.get(worker.worker_id,{})
	var result: Dictionary=Setback.apply(pose,sk,source,native.bounds,_crossbar_equipment_hit,parent,Catalogue.bounds_of(parent.definition))
	var bounded: bool=worker.action=="inspect" and worker.action_progress>=.4 and worker.action_progress<=.65 and pose._work_entry.is_empty() and pose._work_release.is_empty() and previous.get("action","")=="inspect"
	if bounded and result.accepted:
		var old_axis: Vector3=previous.work_axis
		if old_axis.length_squared()>.5 and worker._work_axis.length_squared()>.5 and old_axis.angle_to(worker._work_axis)<=6.0/float(Engine.physics_ticks_per_second)+.001:
			result=Setback.constrain_step(pose,sk,previous,source,native.bounds,_crossbar_equipment_hit,parent,Catalogue.bounds_of(parent.definition),result)
	if result.accepted and not previous.is_empty():
		var changes: Dictionary=_changes(_packet(worker,result),previous)
		if not _bounded(changes): result={"accepted":false,"reason":"Final material frame exceeds original motion bounds","changes":changes}
	var latched: bool=not _live_case.is_empty() and _live_case.worker==worker and _live_case.job_id==worker.current_job_id and _live_case.blocked and not _live_case.cancelled
	var reason: String=_live_case.blocked_reason if latched else worker.tool_pose_blocked if not worker.tool_pose_blocked.is_empty() else "Isolated material lease refused: "+str(result.get("reason",""))
	if latched or not result.accepted or not worker.tool_pose_blocked.is_empty():
		# Ordinary coordinator sees this reason on its next actual tick. Publish
		# only one freshly guarded actual prior frame; no desired fallback/yield.
		worker.tool_pose_blocked=reason
		if _live_case.worker==worker and not _live_case.blocked:
			_live_case.blocked=true
			_live_case.blocked_reason=reason
			_live_case.blocked_tick=_tick
			print("MATERIAL_LEASE_BLOCK worker=",worker.worker_id," action=",worker.action," progress=",worker.action_progress," reason=",reason," result=",result)
		var held: Dictionary=_guard_prior(pose,sk,_live_safe.get(worker.worker_id,previous),source,native.bounds,parent)
		if not held.accepted:
			_check(false,"real blocked lease has no freshly admitted prior frame: "+held.reason)
			_live_finish.call_deferred()
			return false
		result=held
		worker.tool_pose_blocked=reason
		if _live_case.worker==worker: _live_case.held+=1
		_rebind(pose,result)
		return false
	_rebind(pose,result)
	return true

func _guard_prior(pose: SkeletonModifier3D,sk: Skeleton3D,previous: Dictionary,source: RigidBody3D,bounds: AABB,parent: RigidBody3D,returning := false) -> Dictionary:
	if previous.is_empty(): return {"accepted":false,"reason":"No actual prior complete frame"}
	var incoming: Array[Dictionary]=Frame.capture(sk)
	var claims: Dictionary={"grounded":pose.evaluated_grounded.duplicate(),"valid":pose._target_valid.duplicate()}
	var rebase: Transform3D=pose.worker.global_transform*previous.body.affine_inverse()
	for bone in sk.get_bone_count(): sk.set_bone_global_pose(bone,sk.global_transform.affine_inverse()*rebase*previous.bones[bone])
	if returning: _invalidate_return_plants(pose,sk)
	var observed: Dictionary=Setback.observe(pose,sk,source,bounds,_crossbar_equipment_hit,parent,Catalogue.bounds_of(parent.definition))
	if observed.accepted:
		var current: Dictionary=_packet(pose.worker,observed)
		var changes: Dictionary=_changes(current,previous)
		if not _bounded(changes): observed={"accepted":false,"reason":"Prior complete frame no longer meets original motion bounds","changes":changes}
	if not observed.accepted:
		Frame.restore(sk,incoming)
		pose.evaluated_grounded=claims.grounded
		pose._target_valid=claims.valid
	return observed

func _invalidate_return_plants(pose: SkeletonModifier3D,sk: Skeleton3D) -> void:
	# Ordinary native return can move a sole from the ramp onto an adjacent cap.
	# It is no longer the old plant, even if both surfaces meet continuously.
	# This changes only that stale visual claim; actual work support stays strict.
	if pose.worker.feet_work_active(): return
	for side in 2:
		var sole: Vector3=sk.global_transform*(sk.get_bone_global_pose(pose._chains[side][2])*Vector3(0,pose._ankle_height[side],0))
		var start:=Vector3(sole.x,maxf(sole.y+.5,pose.worker.global_position.y+.12),sole.z)
		var query:=PhysicsRayQueryParameters3D.create(start,sole-Vector3.UP*.65,1,pose.worker.query_exclusions())
		var column: Dictionary=pose.worker.get_world_3d().direct_space_state.intersect_ray(query)
		if not column.is_empty() and column.normal.y>.6 and pose._support[side].get_ref()!=column.collider:
			pose.evaluated_grounded[side]=false
			pose._target_valid[side]=false

func _guard_cancel_return(pose: SkeletonModifier3D,sk: Skeleton3D) -> bool:
	var source: RigidBody3D=_live_case.source
	var native: Dictionary=_actual_material_bounds(source)
	if not native.accepted: _check(false,native.reason); return false
	var parent: RigidBody3D=yard.selected_assembly.parts.roof_tie
	var previous: Dictionary=_live_prior.get(pose.worker.worker_id,{})
	var claims: Dictionary={"grounded":pose.evaluated_grounded.duplicate(),"valid":pose._target_valid.duplicate()}
	_invalidate_return_plants(pose,sk)
	var observed: Dictionary=Setback.observe(pose,sk,source,native.bounds,_crossbar_equipment_hit,parent,Catalogue.bounds_of(parent.definition))
	if observed.accepted and not previous.is_empty() and not _bounded(_changes(_packet(pose.worker,observed),previous)):
		observed={"accepted":false,"reason":"Actual cancel-return frame exceeds original motion bounds"}
	if not observed.accepted:
		pose.evaluated_grounded=claims.grounded
		pose._target_valid=claims.valid
		observed=_guard_prior(pose,sk,_live_safe.get(pose.worker.worker_id,previous),source,native.bounds,parent,true)
		if observed.accepted:
			_live_case.return_held=int(_live_case.get("return_held",0))+1
			print("MATERIAL_LEASE_RETURN_HELD tick=",_tick," action=",pose.worker.action," phase=",pose.worker.action_progress," original_clock_continues=true")
	if not observed.accepted:
		_check(false,"actual cancel-return has no fresh guarded complete candidate: "+observed.reason)
		_live_finish.call_deferred()
		return false
	_rebind(pose,observed)
	return true

func _rebind(pose: SkeletonModifier3D,observed: Dictionary) -> void:
	for side in 2:
		var column: Dictionary=observed.columns[side]
		pose._terrain_points[side]=column.position
		pose._sole_normals[side]=column.normal
		if column.sole_gap>.035 or not column.short:
			pose.evaluated_grounded[side]=false
			pose._target_valid[side]=false

func capture_final(worker: RigidBody3D) -> void:
	if _live_done or not worker._pose.evaluated_valid or not is_instance_valid(worker.equipped_tool): return
	var pose: SkeletonModifier3D=worker._pose
	var current: Dictionary=_actual_frame(worker)
	if _trace_pickup:
		current.native_targets=pose._targets.duplicate()
		current.native_target_valid=pose._target_valid.duplicate()
		current.native_plants=pose._plant_weights.duplicate()
		current.native_support=pose._support.map(func(reference:WeakRef)->int:return reference.get_ref().get_instance_id() if is_instance_valid(reference.get_ref()) else 0)
	current.bones=[]
	for bone in worker._skeleton.get_bone_count(): current.bones.append(worker._skeleton.global_transform*worker._skeleton.get_bone_global_pose(bone))
	var previous: Dictionary=_live_prior.get(worker.worker_id,{})
	if not _live_case.is_empty() and _live_case.worker==worker:
		if _live_case.get("serial",-1)==pose.evaluation_serial: return
		_live_case.serial=pose.evaluation_serial
		_live_samples+=1
		if _live_case.blocked and not yard.coordinator.active_jobs.has(_live_case.job_id) and not _live_case.cancelled:
			_live_case.cancelled=true
			_live_attempt_jobs.erase(worker.worker_id)
			_live_case.cancel_tick=_tick
			var cancelled_source: RigidBody3D=_live_case.source
			_check(not yard._reservations.has(_live_case.job_id) and worker.current_job_id!=_live_case.job_id,"ordinary active coordinator cancels and releases the exact blocked lease")
			_check(is_instance_valid(cancelled_source) and cancelled_source.get_instance_id()==_live_case.source_instance and cancelled_source.get_rid()==_live_case.source_rid and cancelled_source.part_id==_live_case.source_id and cancelled_source.carrier==null and not cancelled_source.get_meta(&"in_transit",false) and not cancelled_source.has_meta(&"staged_target") and yard.loose_parts.has(cancelled_source),"ordinary assisted cancellation safely returns the same original staged source/native RID")
			print("MATERIAL_LEASE_CANCEL worker=",worker.worker_id," delay_ticks=",_tick-_live_case.blocked_tick," actual_action=",worker.action," actual_source=",cancelled_source.global_transform," tool=",worker.equipped_tool.part_id)
		var section: String="post_recovery_travel" if _live_case.recovered else "cancel_return" if _live_case.cancelled else "active_lease"
		if not _live_sections.has(section): _live_sections[section]={"samples":0,"guard_failures":0,"motion":{"sole":0.0,"grip":0.0,"knee":0.0,"ankle":0.0,"tool":0.0,"root":0.0,"root_angle":0.0}}
		var section_stats: Dictionary=_live_sections[section]
		section_stats.samples+=1
		if _trace_pickup and _live_case.recovered and worker.action=="pickup" and _pickup_trace_samples<12:
			_pickup_trace_samples+=1
			var job: Dictionary=yard.coordinator.active_jobs.get(worker.current_job_id,{}).get("job",{})
			print("MATERIAL_LEASE_PICKUP_TRACE tick=",_tick," action_phase=",worker.action_progress," job=",worker.current_job_id," source=",job.get("part")," work_role=",worker.work_foot_side," retained_role=",worker.tool_foot_side()," feet_work=",worker.feet_work_active()," pickup_state=",worker.pickup.state," body=",worker.global_position," native_velocity=",worker.linear_velocity," handoff=",pose._gait_handoff_active," targets=",current.native_targets," prior_targets=",previous.get("native_targets",[])," target_valid=",current.native_target_valid," plants=",current.native_plants," supports=",current.native_support," prior_supports=",previous.get("native_support",[])," ground=",pose.evaluated_grounded," columns=",pose._terrain_points," soles=",current.soles," prior_soles=",previous.get("soles",[]))
		var source: RigidBody3D=_live_case.source
		var native: Dictionary=_actual_material_bounds(source)
		var parent: RigidBody3D=yard.selected_assembly.parts.roof_tie
		var guarded: Dictionary=Setback.observe(pose,worker._skeleton,source,native.bounds,_crossbar_equipment_hit,parent,Catalogue.bounds_of(parent.definition))
		if not guarded.accepted:
			_live_guard_failures+=1
			section_stats.guard_failures+=1
			var key: String=section+":"+str(guarded.reason)
			_live_guard_reasons[key]=int(_live_guard_reasons.get(key,0))+1
			if _live_guard_reasons[key]==1: print("MATERIAL_LEASE_FINAL_GUARD tick=",_tick," action=",worker.action," phase=",worker.action_progress," cancelled=",_live_case.cancelled," section=",section," result=",guarded)
		else: _live_safe[worker.worker_id]=current
		if not previous.is_empty():
			var changes: Dictionary=_changes(current,previous)
			for key: String in _live_motion:
				if not _bounded(changes) and changes[key]>_live_motion[key]: print("MATERIAL_LEASE_ACTUAL_SEAM tick=",_tick," section=",section," key=",key," change=",changes[key]," previous=",previous," current=",current)
				_live_motion[key]=maxf(_live_motion[key],changes[key])
				section_stats.motion[key]=maxf(section_stats.motion[key],changes[key])
		if _live_case.blocked and yard.coordinator.active_jobs.has(_live_case.job_id) and worker.current_job_id==_live_case.job_id and (worker.foot_grip_valid or worker.foot_contact_ready()): _check(false,"blocked guarded live lease suppresses toe contact until normal cancellation")
		if _live_case.cancelled and not _live_case.recovered and worker.action.is_empty() and pose._work_release.is_empty() and _tick>_live_case.cancel_tick+60:
			_live_case.recovered=true
			_live_case.recovery_tick=_tick
			_check(worker.equipped_tool==_live_case.tool and worker.equipped_tool.part_id==_live_case.tool_id and source.parameters==_live_case.parameters and source.health==_live_case.health and source.wear==_live_case.wear,"real supported recovery retains the original toe tool, source geometry and condition")
			print("MATERIAL_LEASE_RECOVER worker=",worker.worker_id," ticks_after_cancel=",_tick-_live_case.cancel_tick," body=",worker.global_transform)
	_live_prior[worker.worker_id]=current
	if _stop_after_recovery and not _live_case.is_empty() and _live_case.worker==worker and _live_case.recovered and _tick>=_live_case.recovery_tick+2:
		# This optional lifecycle proof includes the final return endpoint and
		# two actual following authored frames. The default long replay still
		# records subsequent navigation/pickup and its original raw failures.
		_live_finish.call_deferred()

func _packet(worker: RigidBody3D,observed: Dictionary) -> Dictionary:
	return {"body":worker.global_transform,"rig":worker._skeleton.global_basis,"root":observed.root,"soles":observed.soles,"knees":observed.knees,"ankles":observed.ankles,"grip":observed.toe,"tool":observed.tool}

func _changes(current: Dictionary,previous: Dictionary) -> Dictionary:
	var rebase: Transform3D=current.body*previous.body.affine_inverse()
	var values := {"sole":0.0,"grip":current.grip.origin.distance_to(rebase*previous.grip.origin),"knee":0.0,"ankle":0.0,"tool":rad_to_deg((current.rig.inverse()*current.tool.basis).get_rotation_quaternion().angle_to((previous.rig.inverse()*previous.tool.basis).get_rotation_quaternion())),"root":current.root.origin.distance_to(previous.root.origin),"root_angle":rad_to_deg(current.root.basis.get_rotation_quaternion().angle_to(previous.root.basis.get_rotation_quaternion()))}
	for side in 2:
		values.sole=maxf(values.sole,current.soles[side].distance_to(rebase*previous.soles[side]))
		values.knee=maxf(values.knee,rad_to_deg((current.rig.inverse()*current.knees[side]).angle_to(previous.rig.inverse()*previous.knees[side])))
		values.ankle=maxf(values.ankle,rad_to_deg((current.rig.inverse()*current.ankles[side]).get_rotation_quaternion().angle_to((previous.rig.inverse()*previous.ankles[side]).get_rotation_quaternion())))
	return values

func _bounded(changes: Dictionary) -> bool:
	return changes.sole<.05 and changes.grip<.05 and changes.knee<12.0 and changes.ankle<18.0 and changes.tool<18.0 and changes.root<.025 and changes.root_angle<6.0

func _live_finish() -> void:
	if _live_done: return
	_live_done=true
	if is_instance_valid(yard):
		for record: Dictionary in _paused_crew:
			if is_instance_valid(record.worker): record.worker.paused=record.paused
		if _right_availability: print("MATERIAL_LEASE_AVAILABILITY restored=",_paused_crew.map(func(record:Dictionary)->Array:return [record.worker.worker_id,record.worker.paused]))
		_check(_same_material(_live_material),"ordinary staged cancellation/recovery preserves original finite material")
		_check(not _live_case.is_empty(),"normal navigation and source staging reach a real reserved work lease before prototype activation")
		if not _live_case.is_empty():
			if _right_availability: _check(_live_case.worker.tool_foot_side()==1,"ordinary availability choice admits the original right-foot worker without changing its role")
			_check(_live_case.blocked and _live_case.held>0 and _live_case.cancelled and _live_case.recovered,"real blocked staged work publishes a guarded prior frame, cancels normally and completes supported recovery")
			_check(_live_samples>125 and _live_guard_failures==0 and _bounded(_live_motion) and _live_contacts==0,"actual staged/cancel/recovery stays within original complete-tool/contact and motion limits")
		var output:=FileAccess.open("res://.claude/tmp/wako_material_lease_cancel_actual.json",FileAccess.WRITE)
		output.store_string(JSON.stringify(yard.serialize(),"\t"))
		output.close()
		print("MATERIAL_LEASE_RESULT scope=","real_lease_cancel_complete_return_plus_two_frames" if _stop_after_recovery else "full_bounded_replay"," case=",_live_case," attempts=",_live_attempts," routes=",_live_routes," retries=",yard.coordinator._retry_reasons," samples=",_live_samples," guard_failures=",_live_guard_failures," guard_reasons=",_live_guard_reasons," contacts_after_block=",_live_contacts," motion=",_live_motion," sections=",_live_sections," ticks=",_tick)
	print("CONTRAPTION_MATERIAL_LEASE ","PASS" if failures==0 else "FAIL")
	Shortcuts.graceful_quit(0 if failures==0 else 1)

func _finish() -> void:
	_live_finish()

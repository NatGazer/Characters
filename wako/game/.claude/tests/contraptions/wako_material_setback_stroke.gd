extends "res://.claude/tests/contraptions/covered_workshop_build.gd"
## Native diagnostic on genuine earned roof geometry; no paid stock consumption.
const SetbackPose := preload("res://.claude/tmp/wako_material_setback_pose.gd")
const Setback := preload("res://.claude/tests/contraptions/wako_material_setback.gd")
const LastObserver := preload("res://.claude/tests/contraptions/wako_native_handoff_observer.gd")
var _setback_stats := {}
var _setback_prior := {}
var _setback_started := {}
var _setback_finishing := false
var _normal_stroke := false
var _bounded_endpoint := false

func _run() -> void:
	_normal_stroke="--setback-normal-stroke" in OS.get_cmdline_user_args()
	_bounded_endpoint="--setback-bounded-endpoint" in OS.get_cmdline_user_args()
	if "--setback-parse-only" in OS.get_cmdline_user_args():
		_check(true,"isolated finite-leg material-setback module, derived pose and original earned fixture parse")
		_finish()
		return
	await super._run()

func _query_roof_stance(edge_descriptors: Array[Dictionary]=[],scaffold: Dictionary={}) -> void:
	_check(not scaffold.is_empty(),"actual finite-leg setback scope uses the original native 2.1 m scaffold diagnostic")
	for helper: RigidBody3D in yard.workers:
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
			if _setback_stats.has(helper.worker_id):
				var stats: Dictionary=_setback_stats[helper.worker_id]
				stats.events[kind]=int(stats.events.get(kind,0))+1)
	print("MATERIAL_SETBACK_SOURCE production=",FileAccess.get_sha256("res://LogicObjects/Wako/wako_pose.gd")," trial=",FileAccess.get_sha256("res://.claude/tmp/wako_material_setback_pose.gd")," module=",FileAccess.get_sha256("res://.claude/tests/contraptions/wako_material_setback.gd")," original_crew=",yard.workers.map(func(w:Node)->Array:return [w.worker_id,w.tool_foot_side(),w.equipped_tool.part_id]))
	await super._query_roof_stance(edge_descriptors,scaffold)

func material_withdrawal(pose: SkeletonModifier3D,contact: Vector3,axis: Vector3,distance: float) -> Vector3:
	var worker: RigidBody3D=pose.worker
	if _normal_stroke and is_instance_valid(yard.selected_assembly) and yard.selected_assembly.parts.has("roof") and worker.work_target==yard.selected_assembly.parts.roof:
		# Only direction changes. The selected actual underside, original stroke
		# amplitudes/time/contact callback, finite leg and every guard stay exact.
		return contact-yard.selected_assembly.parts.roof.global_basis.y.normalized()*distance
	return contact-axis*distance

func apply_material_setback(pose: SkeletonModifier3D,sk: Skeleton3D) -> bool:
	var worker: RigidBody3D=pose.worker
	if not is_instance_valid(yard.selected_assembly) or not yard.selected_assembly.parts.has("roof"): return true
	var roof: RigidBody3D=yard.selected_assembly.parts.roof
	if worker.work_target!=roof or not is_instance_valid(worker.equipped_tool): return true
	# Keep the unchanged right role as an explicit no-axis control. Neither its
	# ID/tool nor its published native diagnostic posture is rewritten.
	if worker.tool_foot_side()!=0 and not _normal_stroke: return true
	if not _setback_started.has(worker.worker_id):
		if worker.action!="inspect": return true
		_setback_started[worker.worker_id]=true
		_setback_stats[worker.worker_id]={"worker":worker.worker_id,"role":worker.tool_foot_side(),"tool":worker.equipped_tool.part_id,"tool_instance":worker.equipped_tool.get_instance_id(),"attachment_hits":0,"samples":0,"shifted":0,"refused":0,"max_setback":0.0,"max_error":0.0,
			"sole":0.0,"grip":0.0,"knee":0.0,"ankle":0.0,"tool_turn":0.0,"cube":0.0,"cube_turn":0.0,"events":{},"phases":{},"material_hits":0,"native_hits":0,"guard_hits":0,"floor":INF,"tip_event":{},"head_gap":INF,"endpoint_corrected":0,"endpoint_correction":0.0}
	var native: Dictionary=_actual_material_bounds(roof)
	if not native.accepted:
		_check(false,native.reason)
		return false
	var parent: RigidBody3D=yard.selected_assembly.parts.roof_tie
	var native_before:=worker.global_transform
	var velocity_before:=worker.linear_velocity
	var material_before:=roof.global_transform
	var material_velocity:=roof.linear_velocity
	var lease_before: String=worker.current_job_id
	var tool_before: RigidBody3D=worker.equipped_tool
	var tool_id: String=tool_before.part_id
	var result: Dictionary=Setback.apply(pose,sk,roof,native.bounds,_crossbar_equipment_hit,parent,Catalogue.bounds_of(parent.definition))
	var previous: Dictionary=_setback_prior.get(worker.worker_id,{})
	var bounded_contact: bool=worker.action=="inspect" and worker.action_progress>=.4 and worker.action_progress<=.65 and pose._work_entry.is_empty() and pose._work_release.is_empty() and previous.get("action","")=="inspect"
	if bounded_contact:
		var previous_axis: Vector3=previous.work_axis
		bounded_contact=previous_axis.length_squared()>.5 and worker._work_axis.length_squared()>.5 and previous_axis.angle_to(worker._work_axis)<=6.0/float(Engine.physics_ticks_per_second)+.001
	if result.accepted and _bounded_endpoint and bounded_contact:
		var constrained: Dictionary=Setback.constrain_step(pose,sk,previous,roof,native.bounds,_crossbar_equipment_hit,parent,Catalogue.bounds_of(parent.definition),result)
		for key: String in ["requested_distance","realization_error","original_tool","original_toe"]:
			constrained[key]=result.get(key)
		result=constrained
	if worker.global_transform!=native_before or worker.linear_velocity!=velocity_before or roof.global_transform!=material_before or roof.linear_velocity!=material_velocity or worker.current_job_id!=lease_before or worker.equipped_tool!=tool_before or tool_before.part_id!=tool_id:
		_check(false,"finite leg trial mutates no native worker/source motion, original tool or lease")
	var stats: Dictionary=_setback_stats[worker.worker_id]
	if not result.accepted:
		stats.refused+=1
		stats["reasons"]=stats.get("reasons",{})
		stats.reasons[result.reason]=int(stats.reasons.get(result.reason,0))+1
		if stats.get("last_reason","")!=result.reason: print("MATERIAL_SETBACK_REFUSED worker=",worker.worker_id," role=",worker.tool_foot_side()," tool=",worker.equipped_tool.part_id," action=",worker.action," phase=",worker.action_progress," result=",result)
		stats.last_reason=result.reason
		worker.tool_pose_blocked="Isolated material-setback refused: "+result.reason
		return false
	if worker.tool_pose_blocked.begins_with("Isolated material-setback refused: "): worker.tool_pose_blocked=""
	stats.max_setback=maxf(stats.max_setback,float(result.requested_distance))
	stats.max_error=maxf(stats.max_error,float(result.get("realization_error",0.0)))
	if result.requested_distance>0.0: stats.shifted+=1
	if result.get("endpoint_corrected",false):
		stats.endpoint_corrected+=1
		stats.endpoint_correction=maxf(stats.endpoint_correction,result.endpoint_correction.length())
	var side: int=worker.tool_foot_side()
	var column: Dictionary=result.columns[side]
	pose._terrain_points[side]=column.position
	pose._sole_normals[side]=column.normal
	if column.sole_gap>.035:
		pose.evaluated_grounded[side]=false
		pose._target_valid[side]=false
	return true

func _observe_roof_stroke_return(worker: RigidBody3D,roof: RigidBody3D) -> void:
	# Observe the entire original .34-second work release and its next actual
	# authored frame at the SAME supported native stance, before fixture cleanup.
	for frame in 90:
		_trace_roof_tool_clearance()
		_trace_roof_parent_tool_clearance(worker,roof,true)
		await get_tree().physics_frame
	if _setback_stats.has(worker.worker_id):
		_check(worker.action.is_empty() and worker._pose._work_release.is_empty(),"original "+worker.worker_id+" finishes the actual work release before the native observation ends")

func _actual_material_bounds(material: RigidBody3D) -> Dictionary:
	var shapes: Array=material.find_children("*","CollisionShape3D",true,false).filter(func(node:Node)->bool:return node.get_parent()==material and node.shape!=null)
	if shapes.size()!=1 or not shapes[0].shape is BoxShape3D: return {"accepted":false,"reason":"Isolated material-setback supports only the actual original single native box"}
	var relative: Transform3D=material.global_transform.affine_inverse()*shapes[0].global_transform
	if relative.basis.x.distance_to(Vector3.RIGHT)>.00001 or relative.basis.y.distance_to(Vector3.UP)>.00001 or relative.basis.z.distance_to(Vector3.BACK)>.00001: return {"accepted":false,"reason":"Original material native box local rotation unsupported"}
	return {"accepted":true,"bounds":relative*AABB(-shapes[0].shape.size*.5,shapes[0].shape.size)}

func capture_final(worker: RigidBody3D) -> void:
	if worker.work_target!=yard.selected_assembly.parts.roof or not worker._pose.evaluated_valid: return
	if not _setback_started.has(worker.worker_id):
		# Preserve the actual last native-entry/idle frame. The first inspection
		# sample is compared with that frame, not treated as a fresh sequence.
		_setback_prior[worker.worker_id]=_actual_frame(worker)
		return
	var stats: Dictionary=_setback_stats[worker.worker_id]
	var pose: SkeletonModifier3D=worker._pose
	if stats.get("serial",-1)==pose.evaluation_serial: return
	stats.serial=pose.evaluation_serial
	stats.samples+=1
	stats.phases[worker.action if not worker.action.is_empty() else "return"]=int(stats.phases.get(worker.action if not worker.action.is_empty() else "return",0))+1
	var roof: RigidBody3D=yard.selected_assembly.parts.roof
	var tip: Vector3=worker.foot_grip_transform.origin+worker.foot_grip_transform.basis.y*(.035+worker.foot_tool_span())
	var material: Dictionary=ToolMaterial.observe(worker.equipped_tool,roof,_actual_material_bounds(roof).bounds,tip)
	if material.interior_triangles>0: stats.material_hits+=1
	if material.native_tool_overlap: stats.native_hits+=1
	stats.head_gap=minf(stats.head_gap,float(material.head_bottom_face_gap_mm))
	var guard: Dictionary=_published_roof_tool_guard(worker)
	if guard.shaft or guard.meshes>0: stats.guard_hits+=1
	stats.floor=minf(stats.floor,float(guard.floor))
	if worker.action in ["inspect","assemble"] and absf(worker.action_progress-.56)<.01:
		var event: Dictionary=stats.tip_event.get(worker.action,{"min":INF,"max":0.0,"ready":false})
		var gap: float=tip.distance_to(worker.work_point())
		event.min=minf(event.min,gap)
		event.max=maxf(event.max,gap)
		event.ready=event.ready or worker.foot_contact_ready()
		stats.tip_event[worker.action]=event
	var current: Dictionary=_actual_frame(worker)
	var admitted: Transform3D=Setback.tool_pose(worker.equipped_tool,worker.tool_grip_transform)
	var exact_attachment: bool=worker.equipped_tool.carrier==worker.tool_anchor and worker.equipped_tool.get_instance_id()==stats.tool_instance and worker.equipped_tool.part_id==stats.tool and worker.tool_foot_side()==stats.role
	exact_attachment=exact_attachment and admitted.origin.distance_to(worker.equipped_tool.global_position)<.00001 and admitted.basis.x.distance_to(worker.equipped_tool.global_basis.x)<.00001 and admitted.basis.y.distance_to(worker.equipped_tool.global_basis.y)<.00001 and admitted.basis.z.distance_to(worker.equipped_tool.global_basis.z)<.00001
	if not exact_attachment: stats.attachment_hits+=1
	var previous: Dictionary=_setback_prior.get(worker.worker_id,{})
	if not previous.is_empty():
		var rebase: Transform3D=current.body*previous.body.affine_inverse()
		for side in 2:
			stats.sole=maxf(stats.sole,current.soles[side].distance_to(rebase*previous.soles[side]))
			stats.knee=maxf(stats.knee,rad_to_deg((current.rig.inverse()*current.knees[side]).angle_to(previous.rig.inverse()*previous.knees[side])))
			stats.ankle=maxf(stats.ankle,rad_to_deg((current.rig.inverse()*current.ankles[side]).get_rotation_quaternion().angle_to((previous.rig.inverse()*previous.ankles[side]).get_rotation_quaternion())))
		var grip_step: float=current.grip.origin.distance_to(rebase*previous.grip.origin)
		if grip_step>.049 and grip_step>stats.grip:
			print("MATERIAL_SETBACK_ACTUAL_POSITION worker=",worker.worker_id," serial=",pose.evaluation_serial," step=",grip_step," previous=",previous," current=",current," guard=",guard," reason=",worker.tool_pose_blocked)
		stats.grip=maxf(stats.grip,grip_step)
		var turn: float=rad_to_deg((current.rig.inverse()*current.tool.basis).get_rotation_quaternion().angle_to((previous.rig.inverse()*previous.tool.basis).get_rotation_quaternion()))
		if turn>18.0 and turn>stats.tool_turn:
			print("MATERIAL_SETBACK_ACTUAL_TURN worker=",worker.worker_id," serial=",pose.evaluation_serial," previous=",previous," current=",current," guard=",guard," reason=",worker.tool_pose_blocked," material_depth=",material.interior_depth_mm)
		stats.tool_turn=maxf(stats.tool_turn,turn)
		stats.cube=maxf(stats.cube,current.root.origin.distance_to(previous.root.origin))
		stats.cube_turn=maxf(stats.cube_turn,rad_to_deg(current.root.basis.get_rotation_quaternion().angle_to(previous.root.basis.get_rotation_quaternion())))
	_setback_prior[worker.worker_id]=current

func _actual_frame(worker: RigidBody3D) -> Dictionary:
	var pose: SkeletonModifier3D=worker._pose
	var current: Dictionary={"body":worker.global_transform,"rig":worker._skeleton.global_basis,"soles":pose.evaluated_soles.duplicate(),"knees":[],"ankles":pose.evaluated_ankles.duplicate(),"grip":worker.tool_grip_transform,"tool":worker.equipped_tool.global_transform,"root":worker.global_transform.affine_inverse()*pose.evaluated_root,"action":worker.action,"phase":worker.action_progress,"entry":pose._work_entry.duplicate(true),"release":pose._work_release.duplicate(true),"work_axis":worker._work_axis}
	for side in 2: current.knees.append((pose.evaluated_knees[side]-pose.evaluated_hips[side]).normalized())
	return current

func _finish() -> void:
	if not _setback_finishing:
		_setback_finishing=true
		for id: String in _setback_stats:
			var stats: Dictionary=_setback_stats[id]
			print("MATERIAL_SETBACK_ACTUAL worker=",id," result=",stats)
			_check(stats.samples>125 and stats.shifted>0 and stats.refused==0,"original "+id+" realizes finite material setbacks without rejected publication")
			_check(stats.material_hits==0 and stats.native_hits==0 and stats.guard_hits==0 and stats.attachment_hits==0 and stats.floor>=.005,"original "+id+" keeps actual imported head, native tool box, cube and floor clear")
			_check(stats.phases.has("inspect") and stats.phases.has("assemble") and stats.phases.has("return") and stats.events.has("inspect") and stats.events.has("assemble"),"original "+id+" spans actual preparation, contact, synchronous assembly and return")
			_check(stats.tip_event.has("inspect") and stats.tip_event.has("assemble") and stats.tip_event.values().all(func(event:Dictionary)->bool:return event.ready and event.max<.18),"original "+id+" retains unchanged real foot contact with honest tool-tip distance")
			_check(stats.sole<.05 and stats.grip<.05 and stats.knee<12.0 and stats.ankle<18.0 and stats.tool_turn<18.0 and stats.cube<.025 and stats.cube_turn<6.0,"original "+id+" remains continuously bounded through the complete actual finite-IK stroke")
		if not _setback_stats.is_empty(): _check(_setback_stats.size()==(3 if _normal_stroke else 2),"original helper cohort/foot roles are observed without changing IDs or equipment")
	super._finish()

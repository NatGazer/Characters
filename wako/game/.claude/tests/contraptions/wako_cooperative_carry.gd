extends "res://.claude/tests/contraptions/field_worksite_render.gd"
## Observe original paid cooperative cargo and complete retained tools.
## The optional isolated pose replacement leaves native stock, crew, navigation
## and forces intact; the default observes ordinary production behavior.
const Observe = preload("res://.claude/tests/contraptions/wako_native_handoff_observer.gd")
var _carry_crew: Array[Node] = []
var _carry_source: RigidBody3D
var _carry_job := ""
var _carry_time := 0.0
var _carry_duration := 12.0
var _ended := false
var _carry_before := {}
var _poses := {}
var _stats := {}
var _vertices := {}
var _carry_query := PhysicsRayQueryParameters3D.new()
var _alternate_crew := false
var _candidate_script: Script
var _candidate_workers := {}
var _floor_reports := {}
var _candidate_ids: Array[String] = ["431996541197","434244688275","435754637805"]
var _expected_roles: Array[int] = [0,0]
var _expected_tool_roles: Array[int] = [0,0]
var _earned_carry_path := ""
var _carry_search_deadline := 12000
var _carry_motion_probe: Node

func _ready() -> void:
	_alternate_crew="--coop-alternate-crew" in OS.get_cmdline_user_args()
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--coop-candidate="): _candidate_script=load(argument.get_slice("=",1))
		if argument.begins_with("--coop-seconds="): _carry_duration=clampf(float(argument.get_slice("=",1)),12.0,24.0)
	if "--coop-parse-only" in OS.get_cmdline_user_args(): return
	super._ready()

func _physics_process(delta: float) -> void:
	if is_instance_valid(yard):
		for helper: Node in yard.workers:
			# Only an original crew member is paused, through the ordinary helper
			# availability flag. IDs, native bodies, stock and forces stay intact.
			if _alternate_crew and helper.worker_id=="431996541197": helper.paused=true
			if _candidate_script and not _candidate_workers.has(helper.get_instance_id()) and helper.worker_id in _candidate_ids:
				var sk: Skeleton3D = helper._skeleton
				var original: SkeletonModifier3D = helper._pose
				var index: int = original.get_index()
				var candidate: SkeletonModifier3D = _candidate_script.new()
				candidate.worker=helper
				original.active=false
				sk.add_child(candidate)
				sk.move_child(candidate,index)
				helper._pose=candidate
				if helper.ragdoll: helper.ragdoll._pose=candidate
				original.queue_free()
				_candidate_workers[helper.get_instance_id()]=true
	super._physics_process(delta)
	if _ended or not is_instance_valid(yard) or yard._restoring: return
	if _carry_crew.is_empty():
		for entry: Dictionary in yard.coordinator.active_jobs.values():
			if entry.job.kind!="build" or entry.crew.size()!=2 or entry.phase!="carry_exit": continue
			var source: Node = entry.job.part
			if source.part_id!="stock_35" or source.kind!="track" or absf(source.mass-48.0)>.001: continue
			if not is_instance_valid(source.carrier) or not entry.crew.all(func(w:Node)->bool:return w.carrying): continue
			_carry_source=source
			_carry_job=entry.job.id
			_carry_before=_inventory()
			for helper: Node in entry.crew:
				_carry_crew.append(helper)
				print("COOP_CARRY loaded worker=",helper.worker_id," helper=",helper.get_script().source_code.sha256_text()," pose=",helper._pose.get_script().source_code.sha256_text()," native=",helper.ragdoll.visual.get_script().source_code.sha256_text()," ragdoll=",helper.ragdoll.get_script().source_code.sha256_text()," candidate=",_candidate_script!=null)
				var observer := Observe.new()
				observer.worker=helper
				observer.fixture=self
				helper._skeleton.add_child(observer)
				_stats[helper.worker_id]={"samples":0,"root":0.0,"root_angle":0.0,"sole":0.0,"grip":0.0,"knee":0.0,"ankle":0.0,"tool":0.0,"world_tool":0.0,"shaft_samples":0,"shaft_hits":0,"mesh_samples":0,"mesh_hits":0,"floor":INF,"sole_floor":INF,"role":helper.tool_foot_side(),"retained":is_instance_valid(helper.equipped_tool)}
			print("COOP_CARRY original source=",source.part_id," mass=",source.mass," crew=",_carry_crew.map(func(w:Node)->Array:return [w.worker_id,w.tool_foot_side(),w.equipped_tool.part_id if is_instance_valid(w.equipped_tool) else "bare"])," job=",_carry_job)
			if not _earned_carry_path.is_empty():
				var file := FileAccess.open(_earned_carry_path,FileAccess.WRITE)
				if file: file.store_string(JSON.stringify(yard.serialize()))
			break
	else:
		_carry_time+=delta
		if _carry_time>=_carry_duration: _finish_carry.call_deferred()
	if _tick>=_carry_search_deadline and _carry_crew.is_empty():
		_check(false,"genuine saved stock35 reaches ordinary original two-worker carrying")
		_finish_carry.call_deferred()

func _mesh_vertices(node: Node, root: Node3D, points: Array[Vector3]) -> void:
	if node is MeshInstance3D and node.mesh:
		var relative: Transform3D = root.global_transform.affine_inverse()*node.global_transform
		for surface in node.mesh.get_surface_count():
			var data: PackedVector3Array = node.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
			for point in data: points.append(relative*point)
	for child in node.get_children(): _mesh_vertices(child,root,points)

func _start_motion(entry: Dictionary) -> void:
	super._start_motion(entry)
	_carry_motion_probe=get_node_or_null("JitterProbe")
	if is_instance_valid(_carry_motion_probe):
		_carry_motion_probe.stay=true
		for argument: String in OS.get_cmdline_user_args():
			if argument.begins_with("--coop-render-seconds="):
				_carry_motion_probe.record_s=clampf(float(argument.get_slice("=",1)),12.0,24.0)

func capture_final(helper: Node) -> void:
	if _ended or not _carry_crew.has(helper) or not helper._pose.evaluated_valid: return
	var pose: SkeletonModifier3D = helper._pose
	var id: String = helper.worker_id
	var before: Dictionary = _poses.get(id,{})
	if before.get("serial",-1)==pose.evaluation_serial: return
	var tool: Node3D = helper.equipped_tool
	var has_tool := is_instance_valid(tool)
	var sk: Skeleton3D = helper._skeleton
	var root: Transform3D = sk.global_transform*sk.get_bone_global_pose(0)
	var local_root: Transform3D = pose.evaluated_worker.affine_inverse()*root
	local_root.basis=pose.evaluated_basis.inverse()*root.basis
	var knees: Array[Vector3] = []
	var ankles: Array[Quaternion] = []
	for side in 2:
		knees.append((pose.evaluated_basis.inverse()*(pose.evaluated_knees[side]-pose.evaluated_hips[side])).normalized())
		ankles.append((pose.evaluated_basis.inverse()*pose.evaluated_ankles[side]).get_rotation_quaternion())
	var tool_basis: Basis = tool.global_basis if has_tool else Basis.IDENTITY
	var local_tool: Quaternion = (pose.evaluated_basis.inverse()*tool_basis).get_rotation_quaternion() if has_tool else Quaternion.IDENTITY
	var actual: Transform3D = helper.tool_grip_transform
	var stats: Dictionary = _stats[id]
	if not before.is_empty():
		stats.samples+=1
		stats.root=maxf(stats.root,local_root.origin.distance_to(before.root.origin))
		stats.root_angle=maxf(stats.root_angle,rad_to_deg(local_root.basis.get_rotation_quaternion().angle_to(before.root.basis.get_rotation_quaternion())))
		var local_turn: float = rad_to_deg(local_tool.angle_to(before.local_tool)) if has_tool and before.has_tool else 0.0
		var world_turn: float = rad_to_deg(tool_basis.get_rotation_quaternion().angle_to(before.tool_basis.get_rotation_quaternion())) if has_tool and before.has_tool else 0.0
		var grip_step: float = actual.origin.distance_to(before.grip.origin) if has_tool and before.has_tool else 0.0
		var sole_step := 0.0
		stats.grip=maxf(stats.grip,grip_step)
		stats.tool=maxf(stats.tool,local_turn)
		stats.world_tool=maxf(stats.world_tool,world_turn)
		for side in 2:
			stats.knee=maxf(stats.knee,rad_to_deg(knees[side].angle_to(before.knees[side])))
			stats.ankle=maxf(stats.ankle,rad_to_deg(ankles[side].angle_to(before.ankles[side])))
			stats.sole=maxf(stats.sole,pose.evaluated_soles[side].distance_to(before.soles[side]))
			sole_step=maxf(sole_step,pose.evaluated_soles[side].distance_to(before.soles[side]))
		if local_turn>18.0 or world_turn>18.0 or grip_step>.05 or sole_step>.05:
			var side: int = helper.tool_foot_side()
			var surface: Vector3 = pose._terrain_points[side]
			print("COOP_CARRY burst t=",_carry_time," worker=",id," role=",side," serial=",pose.evaluation_serial," action=",helper.action," phase=",helper.action_progress," local_turn=",local_turn," world_turn=",world_turn," grip_step=",grip_step," sole_step=",sole_step," heading=",helper._heading," idle_heading=",helper._idle_heading," gait_speed=",helper.gait_speed," clip=",helper._animation.current_animation," clip_phase=",helper.gait_phase," target=",helper.target_position," has_target=",helper.has_target," avoidance=",helper._avoidance," body=",helper.global_position," root=",root," grip=",actual," old_grip=",before.grip," soles=",pose.evaluated_soles," old_soles=",before.soles," plants=",pose._target_valid," targets=",pose._targets," weights=",pose._plant_weights," held_lift=",pose._held_lift," guard=",helper.held_tool_clearance_debug(actual.origin,actual.basis,surface,pose._sole_normals[side]) if has_tool else {}," previous_guard=",helper.held_tool_clearance_debug(actual.origin,before.grip.basis,surface,pose._sole_normals[side]) if has_tool else {})
	_poses[id]={"serial":pose.evaluation_serial,"root":local_root,"knees":knees,"ankles":ankles,"local_tool":local_tool,"tool_basis":tool_basis,"has_tool":has_tool,"grip":actual,"soles":pose.evaluated_soles.duplicate()}
	_carry_query.exclude=helper.query_exclusions()
	_carry_query.collision_mask=1
	for side in 2:
		var sole: Vector3 = pose.evaluated_soles[side]
		_carry_query.from=Vector3(sole.x,maxf(sole.y+.5,helper.global_position.y+.12),sole.z)
		_carry_query.to=sole-Vector3.UP*.5
		var surface := get_world_3d().direct_space_state.intersect_ray(_carry_query)
		if not surface.is_empty():
			var gap: float = surface.normal.dot(sole-surface.position)
			stats.sole_floor=minf(stats.sole_floor,gap)
			if gap<-.0011 and int(_floor_reports.get(id,0))<12:
				_floor_reports[id]=int(_floor_reports.get(id,0))+1
				print("COOP_CARRY sole_floor t=",_carry_time," worker=",id," role=",helper.tool_foot_side()," side=",side," action=",helper.action," phase=",helper.action_progress," gap=",gap," sole=",sole," surface=",surface.position," body=",surface.collider.name," pose_plane=",pose._terrain_points[side]," plant=",pose._target_valid[side]," target=",pose._targets[side])
	if not has_tool: return
	var bounds := AABB(Vector3(-.38,-.3,-.38),Vector3(.76,.68,.76))
	var inverse: Transform3D = root.affine_inverse()
	var half: float = tool.definition.size.y*.5
	stats.shaft_samples+=1
	if bounds.intersects_segment(inverse*tool.to_global(Vector3(0,-half,0)),inverse*tool.to_global(Vector3(0,half,0)))!=null: stats.shaft_hits+=1
	if pose.evaluation_serial%4!=0: return
	var tool_id: int = tool.get_instance_id()
	if not _vertices.has(tool_id):
		var points: Array[Vector3] = []
		_mesh_vertices(tool.find_child("ExistingToolModel",true,false),tool,points)
		_vertices[tool_id]=points
	stats.mesh_samples+=1
	var hit := false
	var side: int = helper.tool_foot_side()
	for point: Vector3 in _vertices[tool_id]:
		var world: Vector3 = tool.to_global(point)
		hit=hit or bounds.grow(-.03).has_point(inverse*world)
		if pose._terrain_points[side].is_finite(): stats.floor=minf(stats.floor,pose._sole_normals[side].dot(world-pose._terrain_points[side]))
	if hit: stats.mesh_hits+=1

func _finish_carry() -> void:
	if _ended: return
	_ended=true
	# Preserve the strict observer window, then let the real
	# renderer finish its separately configured settle and recording.
	# The fixture owns the final exit so a strict failure cannot become exit0.
	if is_instance_valid(_carry_motion_probe):
		while _carry_motion_probe._phase!="done": await get_tree().process_frame
	var roles: Array = _carry_crew.map(func(w:Node)->int:return w.tool_foot_side())
	roles.sort()
	_check(_carry_crew.size()==2 and roles==_expected_roles,"cooperative crew keeps its actual original foot roles in the earned cohort")
	var retained_roles: Array = _stats.values().filter(func(s:Dictionary)->bool:return s.retained).map(func(s:Dictionary)->int:return s.role)
	retained_roles.sort()
	_check(retained_roles==_expected_tool_roles,"every requested original tool-foot role retains its real equipped tool")
	for id: String in _stats:
		var stats: Dictionary = _stats[id]
		print("COOP_CARRY final worker=",id," stats=",stats)
		_check(stats.samples>125 and stats.root<.025 and stats.root_angle<6.0 and stats.knee<12.0 and stats.ankle<18.0 and stats.tool<18.0 and stats.world_tool<18.0 and stats.grip<.05 and stats.sole<.05,"actual cooperative carrying retains original cube/leg/whole-tool continuity for "+id)
		_check(stats.sole_floor>=-.0011,"both actual soles preserve native support clearance for "+id)
		if stats.retained:
			_check(stats.shaft_samples>125 and stats.mesh_samples>125 and stats.shaft_hits==0 and stats.mesh_hits==0 and stats.floor>=.005-.00001,"actual complete retained tool/cube/floor guards remain intact for "+id)
	_check(_inventory()==_carry_before,"same original finite cooperative stock and tool material is conserved")
	print("CONTRAPTION_COOP_CARRY ","PASS" if failures==0 else "FAIL"," failures=",failures)
	Shortcuts.graceful_quit(0 if failures==0 else 1)

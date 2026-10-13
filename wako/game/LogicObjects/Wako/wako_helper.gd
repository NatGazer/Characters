extends RigidBody3D
## Uses the corrected Wako skin/rig, authored foot-work clips, and player spring-foot forces.
## Upright rotation assist matches the player. Hits, cargo weight, falls and moving support remain physical.

signal action_contact(action: String)
signal action_finished(action: String)
const Dash = preload("res://LogicObjects/Vehicles/UI/dash_style.gd")
const LoadGeometry = preload("res://Components/Contraptions/rolling_balance.gd")
const BackTool = preload("res://LogicObjects/Wako/wako_back_tool.gd")
const PortableGun := preload("res://LogicObjects/Wako/wako_portable_gun.gd")
const Pose = preload("res://LogicObjects/Wako/wako_pose.gd")
const HeadPickup = preload("res://LogicObjects/Wako/wako_head_pickup.gd")
const HeadLeap = preload("res://LogicObjects/Wako/wako_head_leap.gd")
const Ragdoll = preload("res://LogicObjects/Wako/wako_ragdoll.gd")
const Recoil = preload("res://LogicObjects/Wako/wako_recoil.gd")
const ThreatWatch = preload("res://LogicObjects/Wako/wako_threat.gd")
const Personality := preload("res://LogicObjects/Wako/wako_personality.gd")
const IdlePlay := preload("res://LogicObjects/Wako/wako_idle_play.gd")
const Pickup = preload("res://LogicObjects/Wako/wako_pickup.gd")
const Catalogue = preload("res://Components/Contraptions/part_catalog.gd")
const RampAnchor := preload("res://Components/Contraptions/ramp_work_anchor.gd")
const BeamPreparation := preload("res://Components/Contraptions/beam_material_preparation.gd")
const SKIN = preload("res://LogicObjects/Wako/snow_skin.gdshader")
const EYE_SKIN = preload("res://LogicObjects/Wako/snow_eye.gdshader")
const FOOTSTEP = preload("res://Components/PlayerPlugins/footsteps/audio/footstep_grass_000.ogg")
const WORK_SOUND = preload("res://Components/PlayerPlugins/footsteps/audio/impactMetal_light_000.ogg")
const WORK_IMPACTS := [WORK_SOUND, preload("res://Components/PlayerPlugins/footsteps/audio/impactMetal_light_001.ogg"), preload("res://Components/PlayerPlugins/footsteps/audio/impactMetal_light_002.ogg")]
const HEAD_OFFSET := .338 # Original mesh top 1.412m minus imported root-bone pivot 1.074m.
const TOOL_AXIS_TIE_EPS := .00001
const WORK_RUN_SPEED := 3.4
const WORK_HEAD_CARRY_SPEED := 2.2
static var _shared_work_library: AnimationLibrary
static var _shared_skin_material: ShaderMaterial
@export var worker_id := ""
@export var helper_name := "Wako"
@export var walk_speed := 2.1
@export var carry_capacity := 60.0
@export var ride_height := 0.85
var coordinator: Node
# The Yard remains the sole crew owner and saver; companion intentions add no bodies.
var companion_mode := "work"
var companion_hold := Vector3.ZERO
var companion_speed := 2.1
var status_text := "Watching for useful work"
var progress := 0.0
var current_job_id := ""
var head_anchor: Node3D
var tool_anchor: Node3D
var equipped_gun: Node3D
var gun_anchor: Node3D
var portable_gun: Node3D
var equipped_tool: Node3D
var work_foot_side := 0
var tool_pickup_point := Vector3.ZERO
var tool_pickup_basis := Basis.IDENTITY
var tool_pickup_return := Vector3.ZERO
var tool_pickup_contact_phase := .56
var tool_change_picked_up := false
var stance_point := Vector3.ZERO
var stance_valid := false
var foot_grip_transform := Transform3D.IDENTITY
var tool_grip_transform := Transform3D.IDENTITY
var foot_grip_valid := false
var tool_pose_blocked := ""
var on_ground := false
var ground_velocity := Vector3.ZERO
var ground_normal := Vector3.UP
var gait_phase := 0.0
var gait_speed := 0.0
var turn_rate := 0.0
var _grounded_heading_handoff := false
var target_position := Vector3.ZERO
var has_target := false
var navigation_final_stop := true
var carrying := false
var cargo_mass := 0.0
var _cargo_source: Node3D
var carry_partner: Node
var brace_leader: Node3D
var brace_load: Node3D
var access_support: RigidBody3D
var station: Node3D
var station_support: RigidBody3D
var station_support_local := Vector3.ZERO
var station_reacquire_time := 0.0
var saved_station_id := ""
var saved_station_assembly := -1
var saved_station_support_id := ""
var task_label_owner := true
var cargo_target: Node3D
var cargo_staging := false
var _cargo_stage_start := Transform3D.IDENTITY
var _cargo_stage_body_start := Transform3D.IDENTITY
var _cargo_stage_body_finish := Transform3D.IDENTITY
var _cargo_stage_com := Vector3.ZERO
var _cargo_stage_lift_height := 0.0
var _cargo_stage_times := Vector3.ZERO
var _cargo_stage_tail_pose := Transform3D.IDENTITY
var _cargo_stage_tail_time := 0.0
var _cargo_stage_tail_radius := 0.0
var _cargo_visual_bounds := AABB()
var _cargo_turn_source_id := 0
var _cargo_turn_bounds := AABB()
var work_target: Node3D
var paused := false
var needs := ""
var action := ""
var action_progress := 0.0
var fear_time := 0.0
var _damage_impulse_watch := false
var _damage_velocity_before := Vector3.ZERO
var safe_position := Vector3.ZERO
var _action_time := 0.0
var work_action_held := false
var _held_action_speed := 1.0
var _action_length := 1.0
var _contact_sent := false
var _model: Node3D
var _skeleton: Skeleton3D
var _pose: SkeletonModifier3D
var _animation: AnimationPlayer
var _label: Label3D
var _audio: AudioStreamPlayer3D
var _work_audio: AudioStreamPlayer3D
var _work_impact_rng := RandomNumberGenerator.new()
var _last_work_impact := -1
var _tool: Node3D
var _sparks: GPUParticles3D
var _spark_time := 0.0
var _ground_body: RigidBody3D
var _ground_point := Vector3.ZERO
var _query: PhysicsRayQueryParameters3D
var _step_index := 0
var _pending_step_side := -1
var _last_velocity := Vector3.ZERO
var _reaction := 0.0
var _heading := 0.0
var _idle_heading := 0.0
var _visual_pitch := 0.0
var _probe_clock := 0.0
var _avoidance := Vector3.ZERO
var _blocked_time := 0.0
var _work_departure_active := false
var _work_departure_age := 0.0
var _label_time := 0.0
var _visual_head_point := Vector3.INF
var _caption_source_id := 0
var _caption_source_bounds := AABB()
var _leg_lengths: Array[float] = []
var _hip_rest_offsets: Array[Vector3] = []
var _skin_mesh: MeshInstance3D
var ragdoll: RefCounted
var recoil: RefCounted
var threat_watch: SkeletonModifier3D
var personality: RefCounted
var idle_play: RefCounted
var pickup: RefCounted
var back_tool: RefCounted
var head_leap: RefCounted
# Uploaded pupil gaze (atlas UV), mirrored from the face engine each tick.
var _eye_gaze := Vector2.ZERO
var _eye_smile_source: WeakRef
const Eyes := preload("res://LogicObjects/Wako/wako_eyes.gd")
## Face engine (blinks, saccades, event faces, uniform uploads).
var eyes: RefCounted
## Coordinator gaze hint for the current lease phase (stock, tool, target or
## the next reserved target). Read by the eyes only; never a reach target.
var attention_point := Vector3.INF
## The same hint as a node when it moves (a part in flight, a fetched tool):
## the eyes pursue it instead of re-aiming at a stale point.
var attention_node: Node3D
var _work_axis := Vector3.ZERO
var _work_axis_target := 0
var _work_axis_tool := 0

func _notification(what: int) -> void:
	# Recruitment reparents this same helper; only actual deletion owns rig cleanup.
	if what == NOTIFICATION_PREDELETE and ragdoll: ragdoll.dispose()

func _ready() -> void:
	add_to_group(&"wako_helpers")
	if worker_id.is_empty(): worker_id = str(get_instance_id())
	work_foot_side = absi(worker_id.hash()) % 2
	mass = 22.0
	axis_lock_angular_x = true
	axis_lock_angular_y = true
	axis_lock_angular_z = true
	can_sleep = false
	_model = $Wako
	_model.position.y = -ride_height
	_skeleton = _model.find_child("Skeleton3D", true, false) as Skeleton3D
	for names: Array in [["Bone.001", "Bone.003", "Bone.005"], ["Bone.002", "Bone.004", "Bone.006"]]:
		var hip := _skeleton.get_bone_global_rest(_skeleton.find_bone(names[0])).origin
		var knee := _skeleton.get_bone_global_rest(_skeleton.find_bone(names[1])).origin
		var ankle := _skeleton.get_bone_global_rest(_skeleton.find_bone(names[2])).origin
		_leg_lengths.append(hip.distance_to(knee) + knee.distance_to(ankle))
		_hip_rest_offsets.append(hip - _skeleton.get_bone_global_rest(0).origin)
	_animation = _model.get_node("AnimationPlayer")
	_animation.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS
	_animation.callback_mode_method = AnimationMixer.ANIMATION_CALLBACK_MODE_METHOD_IMMEDIATE
	_pose = Pose.new()
	_pose.worker = self
	_skeleton.add_child(_pose)
	_skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_PHYSICS
	ragdoll = Ragdoll.new()
	ragdoll.setup(self, _skeleton, _model)
	_apply_skin()
	_seed_expression()
	_author_actions()
	recoil = Recoil.new()
	recoil.setup(self)
	threat_watch = ThreatWatch.new()
	threat_watch.setup(self)
	_animation.play("wk_idle")
	head_anchor = Node3D.new()
	head_anchor.name = "HeadCargo"
	add_child(head_anchor)
	tool_anchor = Node3D.new()
	tool_anchor.name = "FootToolGrip"
	add_child(tool_anchor)
	portable_gun = PortableGun.new()
	portable_gun.setup(self)
	pickup = Pickup.new()
	pickup.setup(self)
	back_tool = BackTool.new()
	back_tool.setup(self)
	head_leap = HeadLeap.new()
	head_leap.setup(self)
	set_cargo(cargo_mass)
	_label = Label3D.new()
	_label.font = Dash.font("semi")
	_label.font_size = 48
	_label.pixel_size = .0026
	_label.outline_size = 6
	_label.outline_modulate = Color(.025, .04, .055, 1)
	_label.no_depth_test = false
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.alpha_cut = Label3D.ALPHA_CUT_OPAQUE_PREPASS
	_label.visibility_range_end = 10.0
	_label.visibility_range_end_margin = 1.0
	_label.position = Vector3(0, 1.45, 0)
	add_child(_label)
	_audio = AudioStreamPlayer3D.new()
	_audio.max_distance = 20.0
	_audio.unit_size = 2.0
	_audio.volume_db = -13.0
	add_child(_audio)
	# One retained impact channel keeps genuine tool contact audible even
	# while an arriving footstep finishes on the locomotion channel.
	_work_impact_rng.seed = absi(str(worker_id).hash())+67193
	_work_audio = AudioStreamPlayer3D.new()
	_work_audio.name = "WakoToolContact"
	_work_audio.bus = &"SFX"
	_work_audio.max_distance = 20.0
	_work_audio.unit_size = 2.0
	_work_audio.volume_db = -15.0
	add_child(_work_audio)
	personality = Personality.new()
	personality.setup(self)
	bind_eye_smile_source(personality)
	idle_play = IdlePlay.new()
	idle_play.setup(self)
	_create_tool()
	_query = PhysicsRayQueryParameters3D.new()
	_query.exclude = query_exclusions()
	_query.collision_mask = 1
	safe_position = global_position
	target_position = safe_position
	if coordinator: coordinator.register_worker(self)

func configure(service: Node) -> void:
	coordinator = service
	if is_node_ready(): coordinator.register_worker(self)

func navigate_to(point: Vector3, final_stop := true) -> void:
	if portable_gun and portable_gun.handoff_active():
		portable_gun.interrupt("Navigation interrupted the supported gun grip")
		if portable_gun.handoff_active(): return
	target_position = point
	navigation_final_stop = final_stop
	has_target = true

func stop_navigation() -> void:
	has_target = false
	_blocked_time = 0.0

func at_target(distance := 0.75) -> bool:
	var relative := target_position - global_position
	return Vector2(relative.x, relative.z).length() < distance and absf(relative.y + ride_height) < 1.15

func navigation_blocked() -> bool:
	return _blocked_time > 8.0

func energetic_work_transit() -> bool:
	# Both feet must be free for the authored run. Narrow native decks and
	# shared heavy head loads keep their original controlled walking speed.
	if companion_mode != "work" or paused or not action.is_empty() or fear_time > 0.0 \
		or tool_foot_occupied() or is_instance_valid(carry_partner) or is_instance_valid(brace_leader) or is_instance_valid(_ground_body) \
		or not is_instance_valid(coordinator) or not coordinator.active_jobs.has(current_job_id): return false
	var entry: Dictionary = coordinator.active_jobs[current_job_id]
	if entry.get("phase", "") in ["boarding_approach", "boarding", "egress"]: return false
	return entry.job.kind in ["salvage", "build", "replace", "join", "repair", "unbend", "dismantle", "maintenance", "prepare"]

func face_point(point: Vector3) -> void:
	if back_tool and back_tool.busy(): return
	var d := point - global_position
	if Vector2(d.x, d.z).length_squared() > 0.0001: _idle_heading = atan2(-d.x, -d.z)

func set_work_action_held(held: bool) -> void:
	if work_action_held == held: return
	work_action_held = held
	if held:
		_held_action_speed = _animation.speed_scale
		_animation.speed_scale = 0.0
		stop_navigation()
	else:
		_animation.speed_scale = _held_action_speed

func begin_action(kind: String) -> void:
	if idle_play: idle_play.cancel("Useful foot action")
	if portable_gun and portable_gun.handoff_active() and not (kind == "operate" and work_target == portable_gun):
		portable_gun.interrupt("Useful foot work interrupted the gun grip")
		if portable_gun.handoff_active(): return
	if work_action_held: return
	if head_leap and head_leap.active(): return
	if back_tool and not back_tool.before_action(kind): return
	var side := tool_foot_side()
	if kind == "operate": side = control_foot_side()
	elif kind == "interrupted": side = work_foot_side
	elif kind == "brace" and is_instance_valid(brace_load): side = 0 if _model.to_local(brace_load.global_position).x < 0.0 else 1
	elif kind == "pickup" and pickup and pickup.state in ["reaching", "held"] and tool_foot_occupied(): side = 1 - tool_foot_side()
	if action == kind and work_foot_side == side: return
	action = kind
	_work_axis = Vector3.ZERO
	_action_time = 0.0
	tool_change_picked_up = false
	tool_pickup_contact_phase = .56
	if kind == "tool_change" and is_instance_valid(work_target):
		tool_pickup_basis = work_target.global_basis.orthonormalized()
		tool_pickup_return = Vector3.ZERO
		if work_target.get_meta(&"stored_tool_rack",false) and work_target.get_parent() is Node3D:
			# A clipped horizontal tool lifts toward the rack's clear exterior,
			# rather than drawing its complete shaft through the raised cube.
			tool_pickup_return = -(work_target.get_parent() as Node3D).global_basis.z.slide(Vector3.UP).normalized()*.18
		# Match the same .45-length offset used by the carried tool centre.
		tool_pickup_point = work_target.global_transform * Vector3(0, -float(work_target.definition.size.y) * .45, 0)
	if kind == "place" and cargo_staging and is_instance_valid(coordinator) and coordinator.active_jobs.has(current_job_id):
		var source: Node3D = coordinator.active_jobs[current_job_id].job.part
		_cargo_visual_bounds = _whole_cargo_bounds(source)
	_contact_sent = false
	tool_pose_blocked = ""
	action_progress = 0.0
	stop_navigation()
	work_foot_side = side
	if back_tool: back_tool.action_entered(kind)
	var clip := "work/" + kind + ("_L" if work_foot_side == 0 else "_R")
	_grounded_heading_handoff = HeadPickup.eligible(self,kind)
	if _grounded_heading_handoff:
		clip = HeadPickup.LIBRARY+"/pickup_"+("L" if work_foot_side==0 else "R")
	_action_length = _animation.get_animation(clip).length
	if kind=="place" and cargo_staging and is_instance_valid(_cargo_source) and is_instance_valid(cargo_target):
		_cargo_stage_start=head_anchor.global_transform
		_action_length=maxf(_action_length,_cargo_stage_duration(_cargo_source,cargo_target.global_transform))
	_animation.speed_scale = 1.0
	_animation.play(clip, 0.18)
	if kind=="place" and cargo_staging: _animation.speed_scale=_animation.get_animation(clip).length/_action_length
	# Our physics action timer can finish one tick before AnimationPlayer. Replaying
	# the same work clip must restart, rather than resume its final frame and lose
	# every subsequent toe-contact event.
	_animation.seek(0.0, false)
	_tool.visible = tool_foot_occupied() and kind in ["assemble", "repair", "unbend", "maintenance", "place"]

func _whole_cargo_bounds(source: Node3D) -> AABB:
	var bounds: AABB=Catalogue.bounds_of(source.definition)
	for shape: CollisionShape3D in source.find_children("*","CollisionShape3D",true,false):
		if shape.shape and not shape.disabled:
			bounds=bounds.merge(source.global_transform.affine_inverse()*shape.global_transform*shape.shape.get_debug_mesh().get_aabb())
	for mesh: MeshInstance3D in source.visual.find_children("*","MeshInstance3D",true,false):
		if mesh.mesh: bounds=bounds.merge(source.global_transform.affine_inverse()*mesh.global_transform*mesh.mesh.get_aabb())
	for batch: MultiMeshInstance3D in source.visual.find_children("*","MultiMeshInstance3D",true,false):
		if not batch.multimesh or not batch.multimesh.mesh: continue
		var local: Transform3D=source.global_transform.affine_inverse()*batch.global_transform
		for index in batch.multimesh.instance_count:
			bounds=bounds.merge(local*batch.multimesh.get_instance_transform(index)*batch.multimesh.mesh.get_aabb())
	return bounds

func _loaded_head_turn_limit() -> float:
	# A whole finite Head load cannot use the empty cube's six-radian turn.
	# Keep the original walking force/speed; bound the actual rotational
	# corner velocity by the existing 2.5 m/s material movement limit.
	if not carrying or not head_leap or head_leap.state!="done" or not head_leap.contacted or head_leap.crew.is_empty(): return 6.0
	var source: Node3D=_cargo_source
	var leader: Node=head_leap.crew[0]
	if not is_instance_valid(source) or not source.is_inside_tree() or not is_instance_valid(leader) or not leader.is_inside_tree() \
		or source.carrier!=leader.head_anchor or not source.freeze: return 6.0
	if _cargo_turn_source_id!=source.get_instance_id():
		_cargo_turn_source_id=source.get_instance_id()
		_cargo_turn_bounds=_whole_cargo_bounds(source)
	var axis: Vector3=global_basis.y.normalized()
	var lever := 0.0
	for corner in 8:
		var point: Vector3=source.global_transform*_cargo_turn_bounds.get_endpoint(corner)
		lever=maxf(lever,(point-_model.global_position).slide(axis).length())
	return minf(6.0,2.5/maxf(lever,.01))

func _cargo_stage_duration(source: Node3D, destination: Transform3D) -> float:
	# Move the original BODY around its actual material COM. Rotating the
	# old off-centre head contact made the chassis orbit unnecessarily.
	var native := PhysicsServer3D.body_get_direct_state(source.get_rid())
	if not native: return INF
	_cargo_stage_com=native.center_of_mass_local
	_cargo_stage_body_start=source.global_transform
	_cargo_stage_body_finish=destination
	var start_com: Vector3 = _cargo_stage_body_start*_cargo_stage_com
	var finish_com: Vector3 = destination*_cargo_stage_com
	var rotation: Quaternion = _cargo_stage_body_start.basis.get_rotation_quaternion().inverse()*destination.basis.get_rotation_quaternion()
	if rotation.w<0.0: rotation=Quaternion(-rotation.x,-rotation.y,-rotation.z,-rotation.w)
	var angle: float = rotation.get_angle()
	var axis: Vector3 = rotation.get_axis() if angle>.000001 else Vector3.UP
	var world_axis: Vector3 = _cargo_stage_body_start.basis*axis
	var lever := 0.0
	var lowest := INF
	_cargo_stage_tail_radius=0.0
	for x: float in [_cargo_visual_bounds.position.x,_cargo_visual_bounds.end.x]:
		for y: float in [_cargo_visual_bounds.position.y,_cargo_visual_bounds.end.y]:
			for z: float in [_cargo_visual_bounds.position.z,_cargo_visual_bounds.end.z]:
				var corner: Vector3 = Vector3(x,y,z)-_cargo_stage_com
				_cargo_stage_tail_radius=maxf(_cargo_stage_tail_radius,corner.length())
				lever=maxf(lever,corner.slide(axis).length())
				lowest=minf(lowest,_cargo_rotated_min_y(_cargo_stage_body_start.basis*corner,world_axis,angle))
	var head_plane: float = _cargo_stage_start.origin.y
	var members: Array = head_leap.crew if head_leap and head_leap.contacted else [self]
	for member: Node in members:
		if not is_instance_valid(member) or not member._pose.evaluated_valid: continue
		var head: Transform3D = member.global_transform*member._pose.evaluated_worker.affine_inverse()*member._pose.evaluated_root
		head.origin+=head.basis*Vector3(0,HEAD_OFFSET,0)
		head_plane=maxf(head_plane,member._head_upper_y(head))
	_cargo_stage_lift_height=maxf(maxf(start_com.y,finish_com.y),head_plane+.01-lowest)
	# Each segment has one smoothstep whose peak derivative is 1.5. Bound
	# every full corner, plus the original 2.232143 rad/s angular maximum.
	var lifting: float = 1.5*(_cargo_stage_lift_height-start_com.y)/2.5
	var crossing: float = 1.5*((finish_com-start_com).slide(Vector3.UP).length()+angle*lever)/2.5
	crossing=maxf(crossing,1.5*angle/((1.5/.28)/2.4))
	var lowering: float = 1.5*(_cargo_stage_lift_height-finish_com.y)/2.5
	_cargo_stage_times=Vector3(lifting,crossing,lowering)
	var active: float = lifting+crossing+lowering
	# Complete material motion by .90; the original .56 event waits for real
	# pose/sole admission, and there is still a finite settled release tail.
	var duration: float = maxf(2.5,active/.90)
	if active>.000001: _cargo_stage_times*=duration*.90/active
	_cargo_stage_tail_pose=destination
	_cargo_stage_tail_time=_cargo_stage_times.x+_cargo_stage_times.y+_cargo_stage_times.z
	return duration

func _cargo_rotated_min_y(point: Vector3, axis: Vector3, angle: float) -> float:
	var along: float = axis.y*axis.dot(point)
	var cosine: float = point.y-along
	var sine: float = axis.cross(point).y
	var minimum: float = minf(point.y,cosine*cos(angle)+sine*sin(angle)+along)
	var trough: float = atan2(sine,cosine)+PI
	for cycle in [-1,0,1]:
		var at: float = trough+float(cycle)*TAU
		if at>=0.0 and at<=angle: minimum=minf(minimum,cosine*cos(at)+sine*sin(at)+along)
	return minimum

func _cargo_stage_body_pose() -> Transform3D:
	var start_com: Vector3 = _cargo_stage_body_start*_cargo_stage_com
	var finish_com: Vector3 = _cargo_stage_body_finish*_cargo_stage_com
	var elapsed: float = minf(_action_time,_cargo_stage_times.x+_cargo_stage_times.y+_cargo_stage_times.z)
	var lifting: float = smoothstep(0.0,maxf(_cargo_stage_times.x,.000001),elapsed)
	var crossing: float = smoothstep(0.0,maxf(_cargo_stage_times.y,.000001),maxf(0.0,elapsed-_cargo_stage_times.x))
	var lowering: float = smoothstep(0.0,maxf(_cargo_stage_times.z,.000001),maxf(0.0,elapsed-_cargo_stage_times.x-_cargo_stage_times.y))
	var body: Transform3D = _cargo_stage_body_start.interpolate_with(_cargo_stage_body_finish,crossing)
	var centre: Vector3 = start_com.lerp(finish_com,crossing)
	centre.y=lerpf(lerpf(start_com.y,_cargo_stage_lift_height,lifting),finish_com.y,lowering)
	body.origin=centre-body.basis*_cargo_stage_com
	if _action_time<=_cargo_stage_times.x+_cargo_stage_times.y+_cargo_stage_times.z or not is_instance_valid(cargo_target): return body
	# Keep the captured lift/cross/lower path. Only its existing settled tail
	# follows the real moving placement; repeated pose publications spend no
	# extra motion budget because the unchanged action clock advances once.
	var delta: float=maxf(0.0,_action_time-_cargo_stage_tail_time)
	if delta>0.0:
		var destination: Transform3D=cargo_target.global_transform
		var current_com: Vector3=_cargo_stage_tail_pose*_cargo_stage_com
		var destination_com: Vector3=destination*_cargo_stage_com
		var angle: float=_cargo_stage_tail_pose.basis.get_rotation_quaternion().angle_to(destination.basis.get_rotation_quaternion())
		# COM travel plus the furthest original corner's angular arc bounds
		# every full material point, using the same 2.5 m/s and angular limits.
		var travel: float=current_com.distance_to(destination_com)+angle*_cargo_stage_tail_radius
		var weight: float=minf(1.0,2.5*delta/maxf(travel,.000001))
		weight=minf(weight,((1.5/.28)/2.4)*delta/maxf(angle,.000001))
		_cargo_stage_tail_pose=_cargo_stage_tail_pose.interpolate_with(destination,weight)
		_cargo_stage_tail_pose.origin=current_com.lerp(destination_com,weight)-_cargo_stage_tail_pose.basis*_cargo_stage_com
		_cargo_stage_tail_time=_action_time
	return _cargo_stage_tail_pose

func interrupt(reason: String) -> void:
	set_work_action_held(false)
	status_text = reason
	needs = reason
	_reaction = maxf(_reaction, 0.5)
	if is_available(): begin_action("interrupted")

func is_available() -> bool:
	return not ragdoll or not ragdoll.is_down()

func query_exclusions() -> Array[RID]:
	var exclusions: Array[RID] = [get_rid()]
	if ragdoll: exclusions.append_array(ragdoll.own_rids())
	if portable_gun: exclusions.append_array(portable_gun.support_query_rids())
	return exclusions

func attached_payload_centre() -> Dictionary:
	# The original capsule is 22 kg. Frozen original followers and permanent
	# holder hardware contribute once; a released native tool contributes zero.
	if not is_inside_tree(): return {}
	# A tree-exiting worker can outlive its detached spatial children. There
	# is no complete world load snapshot then; scalar custody stays unchanged.
	var capsule := get_node_or_null("Collision") as Node3D
	if not is_instance_valid(capsule) or not capsule.is_inside_tree(): return {}
	var total := 22.0
	var weighted: Vector3 = capsule.global_position*total
	if back_tool:
		var load: Dictionary = back_tool.holder_load()
		if load.is_empty(): return {}
		weighted += Vector3(load.world_point)*float(load.mass)
		total += float(load.mass)
	if cargo_mass > 0.0:
		var point: Vector3
		if is_instance_valid(_cargo_source) and _cargo_source.is_inside_tree():
			point = LoadGeometry.world_centre(_cargo_source)
		else:
			if not is_instance_valid(head_anchor) or not head_anchor.is_inside_tree(): return {}
			point = head_anchor.global_position
		weighted += point*cargo_mass
		total += cargo_mass
	var tool_mass: float = back_tool.onboard_mass() if back_tool else (float(equipped_tool.mass) if is_instance_valid(equipped_tool) else 0.0)
	if tool_mass > 0.0:
		if not is_instance_valid(equipped_tool) or not equipped_tool.is_inside_tree(): return {}
		weighted += LoadGeometry.world_centre(equipped_tool)*float(equipped_tool.mass)
		total += float(equipped_tool.mass)
	var centre := weighted/total
	return {"mass":total,"point":centre,"local_centre":global_transform.affine_inverse()*centre}

func _sync_attached_payload() -> void:
	if not is_inside_tree() or not is_available(): return
	var load: Dictionary = attached_payload_centre()
	if load.is_empty(): return
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = load.local_centre
	if portable_gun and is_instance_valid(equipped_gun): portable_gun._sync_physical_payload(equipped_gun.global_transform)

func set_cargo(load_mass: float) -> void:
	carrying = load_mass > 0.0
	cargo_mass = maxf(load_mass, 0.0)
	_cargo_source = null
	if carrying and is_inside_tree():
		# Bind the same assisted source once when its load changes. Catch assigns
		# mass just before changing the native flying part back to a head follower.
		if pickup and is_instance_valid(pickup.part): _cargo_source = pickup.part
		# Every reserved crew share refers to the same actual head-held body.
		# Its material COM is shared; the finite scalar mass share is not changed.
		if head_leap and is_instance_valid(head_leap.part) and not head_leap.crew.is_empty():
			var leader: Node=head_leap.crew[0]
			if head_leap.crew.has(self) and is_instance_valid(leader) and head_leap.part.carrier==leader.head_anchor:
				_cargo_source=head_leap.part
		for part: Node in get_tree().get_nodes_in_group(&"contraption_parts"):
			if part.get("carrier") == head_anchor or (pickup and part.get("carrier") == pickup.foot_anchor):
				_cargo_source = part
				break
	mass = 22.0 + (back_tool.holder_mass() if back_tool else 0.0) + cargo_mass + (back_tool.onboard_mass() if back_tool else (float(equipped_tool.mass) if is_instance_valid(equipped_tool) else 0.0)) + (portable_gun.payload_mass() if portable_gun else 0.0)
	_sync_attached_payload()
	if ragdoll and is_inside_tree(): ragdoll.sync_payload()

func set_equipped_tool(tool: Node3D) -> void:
	if back_tool: back_tool.on_equipped_changed(equipped_tool,tool)
	equipped_tool = tool
	set_cargo(cargo_mass)

func apply_hit(impulse: Vector3) -> void:
	if ragdoll and ragdoll.active:
		ragdoll.apply_hit(impulse, global_position + Vector3.UP * .5)
		return
	if ragdoll and impulse.length() / maxf(mass, 1.0) >= 3.5 and ragdoll.knock_down(impulse):
		fear_time = 3.0
		return
	apply_central_impulse(impulse)
	_reaction = clampf(impulse.length() / maxf(mass * 3.0, 1.0), 0.15, 1.0)
	fear_time = 3.0
	if recoil: recoil.react(impulse)

func hurt(amount: float, from := Vector3.INF, _kind := &"hit") -> void:
	var direction := Vector3.UP
	if from != Vector3.INF: direction = (global_position - from).normalized() + Vector3.UP * 0.25
	apply_hit(direction * minf(amount, 50.0) * 0.7)

func take_damage(amount: float, _point: Vector3 = Vector3.INF, _source: Node = null, _kind: StringName = &"hit") -> void:
	if amount <= 0.0: return
	# Core.damage already applies its explicit impulse to the actual hit body.
	# React to the damage here without adding hurt()'s separate scripted push.
	fear_time = maxf(fear_time, 3.0)
	_reaction = maxf(_reaction, clampf(amount / 50.0, .15, 1.0))
	if is_instance_valid(coordinator): coordinator.interrupt_worker(self, "Hit; seeking shelter")
	if ragdoll and ragdoll.is_down(): ragdoll.damage_reaction()
	else:
		_damage_velocity_before = _last_velocity
		_damage_impulse_watch = true
		if recoil: recoil.watch_damage(_damage_velocity_before,_point)

func _physics_process(delta: float) -> void:
	if not _query: return
	fear_time = maxf(fear_time - delta, 0.0)
	_reaction = maxf(_reaction - delta * 1.4, 0.0)
	_spark_time = maxf(_spark_time - delta, 0.0)
	if _sparks: _sparks.emitting = _spark_time > 0.0
	if ragdoll: ragdoll.advance(delta)
	var head_flight: bool = head_leap and head_leap.active()
	if head_flight:
		if back_tool: back_tool.advance(delta)
		head_leap.advance(delta)
		_update_head()
	elif is_available():
		_update_ground(delta)
		if back_tool: back_tool.advance(delta)
		# A hard landing may request the native handoff during this very probe.
		if is_available():
			_move_with_forces(delta)
			_update_animation(delta)
			_update_head()
	if not is_available() and back_tool and not head_flight: back_tool.advance(delta)
	if pickup: pickup.advance(delta)
	if portable_gun: portable_gun.advance(delta)
	if head_leap and not head_leap.active(): head_leap._watch_release()
	if personality: personality.advance(delta)
	if idle_play: idle_play.advance(delta)
	_update_expression(delta)
	_update_caption_height(delta)
	_label_time += delta
	if _label_time > 0.18:
		_label_time = 0.0
		_label.visible = task_label_owner and (companion_mode != "work" or not current_job_id.is_empty() or is_instance_valid(station) or fear_time > 0.0 or not needs.is_empty())
		var camera := get_viewport().get_camera_3d()
		if camera:
			_label.visible = _label.visible and _caption_is_readable(camera, _label)
			if _label.visible and is_instance_valid(coordinator):
				var screen := camera.unproject_position(_label.global_position)
				for other: Node3D in coordinator.workers:
					if other == self or not is_instance_valid(other) or not other.task_label_owner: continue
					if other.worker_id >= worker_id or (other.companion_mode == "work" and other.current_job_id.is_empty() and not is_instance_valid(other.station)): continue
					if not _caption_is_readable(camera, other._label): continue
					if camera.unproject_position(other._label.global_position).distance_to(screen) < 110:
						_label.visible = false
						break
		var short_status := status_text
		var normal_tool_yield: bool = needs == "Giving the tool crew room to fit and stow" and fear_time <= 0.0
		if not is_available(): short_status = "Regaining footing"
		elif normal_tool_yield: short_status = "Clearing tool passage"
		elif not needs.is_empty(): short_status = (status_text if companion_mode != "work" else "Work blocked") if fear_time <= 0.0 else "Taking cover"
		elif _preparing_inspection(): short_status = "Preparing inspection"
		if short_status.length() > 28: short_status = short_status.left(27) + "…"
		var caption_name := helper_name
		if helper_name == "Captive Wako" and worker_id.begins_with("captive_") \
			and is_instance_valid(coordinator) and is_instance_valid(coordinator.yard) \
			and get_parent() == coordinator.yard and coordinator.yard.workers.has(self) \
			and not is_in_group(&"captive_wakos"):
			caption_name = "Rescued Wako"
		_label.text = caption_name + " · " + short_status
		if progress > 0.0 and progress < 1.0: _label.text += "  %d%%" % int(progress * 100.0)
		_label.modulate = Color(1.0, 0.72, 0.44) if not needs.is_empty() and not normal_tool_yield else Color(0.87, 0.98, 1.0)
	_last_velocity = linear_velocity

func _caption_is_readable(camera: Camera3D, caption: Label3D) -> bool:
	var bottom_position := caption.global_position
	if camera.global_position.distance_to(bottom_position) >= 9.0 or camera.is_position_behind(bottom_position): return false
	var top_position := bottom_position + camera.global_basis.y * caption.font_size * caption.pixel_size
	# Both endpoints must be beyond the near plane before perspective division.
	if camera.is_position_behind(top_position): return false
	var bottom := camera.unproject_position(bottom_position)
	var top := camera.unproject_position(top_position)
	return top.distance_to(bottom) >= 12.0

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	_observe_native_impacts(state)
	if recoil: recoil.observe_contacts(state)
	_sync_native_followers()
	if portable_gun: portable_gun.sync_native()

func _observe_native_impacts(state: PhysicsDirectBodyState3D) -> void:
	if not is_available(): return
	if _damage_impulse_watch:
		_damage_impulse_watch = false
		if (state.linear_velocity - _damage_velocity_before).length() >= 3.5 and ragdoll:
			# Preserve the velocity Core put into the capsule. The native handoff
			# must not apply that impulse a second time to the root body.
			ragdoll.knock_down()
			return
	# Contacts and blasts do not need an AI command to interrupt work: a hard body impact is enough.
	for i in state.get_contact_count():
		var impact := state.get_contact_impulse(i).length() / maxf(mass, 1.0)
		if impact > 2.5:
			_reaction = maxf(_reaction, clampf(impact / 8.0, .25, 1.0))
			fear_time = maxf(fear_time, 2.0)
			if impact > 3.5 and ragdoll: ragdoll.knock_down()

func _update_ground(delta: float) -> void:
	if idle_play and idle_play.water_support_active():
		# An immersed helper floats through the shared water force model;
		# underwater terrain is not a planted spring-foot support claim.
		on_ground = false
		_ground_body = null
		ground_velocity = Vector3.ZERO
		return
	var probe_origin := global_position
	if feet_work_active() and stance_valid:
		probe_origin.x = stance_point.x
		probe_origin.z = stance_point.z
	_query.from = probe_origin + Vector3.UP * 0.12
	_query.to = probe_origin - Vector3.UP * (ride_height + 0.42)
	var hit := get_world_3d().direct_space_state.intersect_ray(_query)
	var was_grounded := on_ground
	on_ground = not hit.is_empty() and hit.normal.y > 0.64
	_ground_body = null
	ground_velocity = Vector3.ZERO
	if not on_ground: return
	ground_normal = ground_normal.lerp(hit.normal, 1.0 - exp(-8.0 * delta)).normalized()
	_ground_point = hit.position
	_ground_body = hit.collider as RigidBody3D
	if _ground_body:
		ground_velocity = _ground_body.linear_velocity + _ground_body.angular_velocity.cross(_ground_point - _ground_body.global_position)
	var distance: float = global_position.y - hit.position.y
	var relative_y := (linear_velocity - ground_velocity).y
	var leg_force := spring_support_force(mass, ride_height - distance, relative_y)
	apply_central_force(Vector3.UP * leg_force)
	if _ground_body: _ground_body.apply_force(Vector3.DOWN * leg_force, _ground_point - _ground_body.global_position)
	if not was_grounded and _last_velocity.y < -2.0:
		_reaction = clampf(-_last_velocity.y / 9.0, 0.15, 1.0)
		_play_sound(FOOTSTEP, 0.7)
		if _last_velocity.y < -6.5 and ragdoll: ragdoll.knock_down()

static func spring_support_force(load_mass: float, height_error: float, relative_speed: float,
		hz := 2.6, damping := .96, maximum := 22.0 * 9.8 * 5.0) -> float:
	var frequency := TAU * hz
	return clampf(load_mass * (9.8 + frequency * frequency * height_error - 2.0 * frequency * damping * relative_speed), 0.0, maximum)

func _move_with_forces(delta: float, keep_evaluated_parent: bool = false) -> void:
	var offset := target_position - global_position
	offset.y = 0.0
	var desired := Vector3.ZERO
	var relative := linear_velocity - ground_velocity
	var horizontal := Vector3(relative.x, 0, relative.z)
	var work_transit: bool = energetic_work_transit()
	var station_job := false
	if is_instance_valid(coordinator) and coordinator.active_jobs.has(current_job_id):
		station_job = coordinator.active_jobs[current_job_id].job.kind == "operate"
	var station_correction: bool = (action == "operate" or station_job) and is_instance_valid(work_target) and work_target.kind in ["gun", "station"] and supported_by(work_target.assembly)
	if has_target and not paused and (action.is_empty() or station_correction) and not (back_tool and back_tool.blocks_navigation()):
		var travel_speed: float = clampf(companion_speed, walk_speed, 3.6) if companion_mode == "follow" else walk_speed
		if work_transit: travel_speed = maxf(travel_speed, WORK_RUN_SPEED)
		var speed := 3.6 if fear_time > 0.0 else travel_speed * clampf(1.0 - cargo_mass / 140.0, 0.45, 1.0)
		# The original eased .40 m head-carry swing must still fit its 5.4 m/s
		# sole budget; free-foot running does not borrow a faster loaded leg.
		if work_transit and carrying: speed = minf(speed, WORK_HEAD_CARRY_SPEED)
		if idle_play: speed = idle_play.speed_limit(speed)
		work_transit = work_transit and speed > .01
		# A supported pedal approach needs the same precision as existing duty.
		# The coarse travel gain settles against native static friction outside
		# the 5 cm stance tolerance; a bounded near-station servo crosses it.
		var arrival_gain := 6.0 if station_correction and offset.length() < .5 else 2.0
		var approach_speed: float = minf(speed, offset.length() * arrival_gain)
		if work_transit:
			# The existing supported gather precedes the real force-driven launch.
			# A continuing route does not repeat the anticipation at every waypoint.
			if not _work_departure_active: _work_departure_age = .13 if horizontal.length() > .3 else 0.0
			_work_departure_active = true
			_work_departure_age = minf(_work_departure_age + delta, .13)
			# Keep the original final .45 m precision approach. Outside it, enter
			# briskly, then brake within the unchanged native traction envelope.
			arrival_gain = lerpf(2.0, 4.0, smoothstep(.45, 1.25, offset.length()))
			var braking_accel: float = minf(maxf(horizontal.length(), .8) * 6.0 * (1.0 - _reaction * .7), 9.8 * (1.25 if on_ground else .055)) * ground_normal.y
			approach_speed = minf(speed, minf(offset.length() * arrival_gain, sqrt(2.0 * braking_accel * offset.length()))) if navigation_final_stop else speed
			if horizontal.length_squared() > .16:
				var alignment: float = horizontal.normalized().dot(offset.normalized())
				approach_speed *= lerpf(.38, 1.0, smoothstep(.1, .85, alignment))
			approach_speed *= lerpf(.55, 1.0, smoothstep(.64, .98, ground_normal.y))
			approach_speed *= smoothstep(.015, .13, _work_departure_age)
		else:
			_work_departure_active = false
			_work_departure_age = 0.0
		desired = offset.normalized() * approach_speed
		_probe_clock += delta
		if _probe_clock > 0.16:
			_probe_clock = 0.0
			_avoidance = _probe_obstacles(desired.normalized())
		desired = (desired + _avoidance * (approach_speed if work_transit else speed)).limit_length(approach_speed if work_transit else speed)
		if is_instance_valid(coordinator):
			for other: Node3D in coordinator.workers:
				if other == self or not is_instance_valid(other): continue
				var apart := (global_position - other.global_position).slide(Vector3.UP)
				var spacing := apart.length()
				if spacing > .01 and spacing < .85:
					desired += apart / spacing * (.85 - spacing) * 2.0
			desired = desired.limit_length(approach_speed if work_transit else speed)
		if offset.length() > 1.1 and (linear_velocity - ground_velocity).length() < 0.18: _blocked_time += delta
		else: _blocked_time = maxf(_blocked_time - delta * 2.0, 0.0)
		if desired.length_squared() > 0.04 and not station_correction: _idle_heading = atan2(-desired.x, -desired.z)
	else:
		_work_departure_active = false
		_work_departure_age = 0.0
	if feet_work_active() and stance_valid and on_ground:
		# Authored counterlean already shifts the body over the planted leg. Correct
		# only beyond the capsule's supported footprint, rather than shifting twice
		# and dragging the operator away from the pedal on each work cycle.
		var balance := (stance_point - global_position).slide(Vector3.UP)
		if balance.length() > .22:
			desired += balance.normalized() * minf(balance.length() - .22, .25) * 1.5
	var force := (desired - horizontal) * mass * 6.0 * (1.0 - _reaction * 0.7)
	force = force.slide(ground_normal).limit_length(mass * 9.8 * (1.25 if on_ground else 0.055))
	if idle_play and (idle_play.water_support_active() or idle_play.water_ballistic_flight()): force = Vector3.ZERO
	apply_central_force(force)
	if on_ground and _ground_body: _ground_body.apply_force(-force, _ground_point - _ground_body.global_position)
	gait_speed = horizontal.length()
	# Head launches from its completed supported pose. Native movement above
	# is unchanged; every other caller retains its original visual steering.
	if keep_evaluated_parent: return
	var previous_heading := _heading
	var ordinary_terrain_turn: bool = on_ground and _pose and _pose.evaluated_valid and _pose._walking_ik \
		and not carrying and not (head_leap and head_leap.active()) and not (back_tool and back_tool.busy())
	if action.is_empty() and (ordinary_terrain_turn or _grounded_heading_handoff or tool_foot_occupied() or (carrying and head_leap and head_leap.contacted and head_leap.part==_cargo_source)):
		# Planted terrain IK and the departing cube share the evaluated rotation budget.
		# Integrate the existing filtered turn velocity before moving the rig,
		# rather than publishing a large heading step then filtering its report.
		var turn_limit: float=_loaded_head_turn_limit()
		if ordinary_terrain_turn: turn_limit=minf(turn_limit,_pose.stopped_turn_limit())
		var wanted_turn := clampf(wrapf(_idle_heading-_heading,-PI,PI)*6.0,-turn_limit,turn_limit)
		turn_rate = lerpf(turn_rate,wanted_turn,1.0-exp(-10.0*delta))
		turn_rate=clampf(turn_rate,-turn_limit,turn_limit)
		_heading += turn_rate*delta
	else:
		_heading = lerp_angle(_heading, _idle_heading, 1.0 - exp(-6.0 * delta))
		turn_rate = lerpf(turn_rate, wrapf(_heading - previous_heading, -PI, PI) / maxf(delta, .001), 1.0 - exp(-10.0 * delta))
	_model.rotation.y = _heading
	var run_lean := -.1 if gait_speed > 2.5 else 0.0
	_visual_pitch = lerpf(_visual_pitch, clampf(-relative.y * 0.035, -0.2, 0.18) + _reaction * 0.15 + run_lean, 1.0 - exp(-8.0 * delta))
	_model.rotation.x = _visual_pitch

func _probe_obstacles(direction: Vector3) -> Vector3:
	if direction.length_squared() < 0.01: return Vector3.ZERO
	var from := global_position + Vector3.UP * 0.18
	# Do not avoid a machine beyond the exterior work position we are trying to reach.
	var probe_distance := minf(1.25, (target_position - global_position).slide(Vector3.UP).length()) if has_target else 1.25
	var query := PhysicsRayQueryParameters3D.create(from, from + direction * maxf(probe_distance, .01))
	var exclusions := query_exclusions()
	if is_instance_valid(access_support): exclusions.append(access_support.get_rid())
	query.exclude = exclusions
	query.collision_mask = collision_mask
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty(): return Vector3.ZERO
	var tangent: Vector3 = hit.normal.slide(Vector3.UP).normalized()
	var side := direction.cross(Vector3.UP)
	if worker_id.hash() % 2 == 0: side = -side
	return tangent * 0.8 + side * 0.75

func _update_animation(delta: float) -> void:
	if work_action_held: return
	if not action.is_empty():
		_pending_step_side = -1
		_action_time += delta
		action_progress = clampf(_action_time / _action_length, 0.0, 1.0)
		if _action_time >= _action_length:
			var finished := action
			action = ""
			_tool.visible = false
			action_finished.emit(finished)
		return
	var clip := "wk_idle"
	var playback := 1.0
	if gait_speed > 0.15 and on_ground:
		clip = "work/carry" if carrying else "work/run" if gait_speed > 2.5 else "wk_walkcycle"
		# Each authored half-cycle moves the planted sole back by this distance.
		# Match that stance velocity to native travel instead of speeding every
		# clip by the walking cadence, which made running and hauling feet hurry.
		var stance_distance := .40 if carrying else .50 if clip == "work/run" else .46
		var nominal_speed := stance_distance * 2.0 / _animation.get_animation(clip).length
		if tool_foot_occupied():
			var stance_fraction := lerpf(.5,.24,smoothstep(2.1,3.2,gait_speed))
			nominal_speed = stance_distance / (stance_fraction * _animation.get_animation(clip).length)
		playback = clampf(gait_speed / nominal_speed, 0.12, 3.0)
	elif not on_ground or fear_time > 0.0: clip = "work/danger_L"
	if _animation.current_animation != clip:
		var locomotion_clips := ["wk_walkcycle", "work/carry", "work/run"]
		var previous_phase := 0.0
		var preserve_phase := _animation.current_animation in locomotion_clips and clip in locomotion_clips
		if preserve_phase:
			previous_phase = _animation.current_animation_position / _animation.current_animation_length
		_animation.play(clip, 0.24, 1.0)
		if preserve_phase: _animation.seek(previous_phase * _animation.get_animation(clip).length, false)
	_animation.speed_scale = playback
	# The imported cycle plants the left sole near 90%, right near 40%; IK and sounds share that actual clip.
	gait_phase = fposmod(_animation.current_animation_position / maxf(_animation.current_animation_length, .01) + .1, 1.0)
	var index := int(gait_phase * 2.0)
	if index != _step_index and on_ground and gait_speed > 0.25:
		_step_index = index
		_pending_step_side = index
	if gait_speed <= .25 or clip not in ["wk_walkcycle", "work/carry", "work/run"]: _pending_step_side = -1
	if _pending_step_side >= 0 and on_ground and _pose.evaluated_valid and _pose.evaluated_grounded[_pending_step_side]:
		var sole: Vector3 = _pose.evaluated_soles[_pending_step_side]
		var plane: Vector3 = _pose._terrain_points[_pending_step_side]
		# A cadence boundary may precede a real low-step landing. Delay its
		# sound until this evaluated sole reaches its own observed support.
		if plane.is_finite() and absf(_pose._sole_normals[_pending_step_side].dot(sole-plane)) < .035:
			_play_sound(FOOTSTEP, 1.15 if gait_speed > 2.5 else 1.0)
			_pending_step_side = -1

func _sync_native_followers() -> void:
	if back_tool: back_tool.sync_native()
	# The native callback has synchronized the real capsule before it runs.
	# Its child anchors already follow that move; publish it to the existing
	# frozen followers instead of leaving them one tick behind after a hit.
	if is_instance_valid(head_anchor) and is_instance_valid(_cargo_source) and _cargo_source.get("carrier") == head_anchor and _cargo_source.get("freeze") == true:
		_cargo_source.global_transform = _cargo_source.carried_world_transform()
	if is_instance_valid(tool_anchor) and is_instance_valid(equipped_tool) and equipped_tool.get("carrier") == tool_anchor and equipped_tool.get("freeze") == true:
		equipped_tool.global_transform = tool_anchor.global_transform
	_sync_head_crew_payload()

func _sync_head_crew_payload() -> void:
	_sync_attached_payload()
	# Both reserved shares use one common submitted source pose. The leader's
	# later native/skeleton publication must not leave its partner one pose behind.
	if not head_leap or not head_leap.contacted or not is_instance_valid(head_leap.part): return
	var source: Node3D = head_leap.part
	if head_leap.crew.is_empty() or not source.is_inside_tree(): return
	var leader: Node = head_leap.crew[0]
	if not is_instance_valid(leader) or not leader.is_inside_tree() or source.carrier!=leader.head_anchor: return
	for member: Node in head_leap.crew:
		if member!=self and is_instance_valid(member) and member._cargo_source==source and member.cargo_mass>0.0:
			member._sync_attached_payload()

func _update_head(evaluated_pose: Variant = null) -> void:
	if not _skeleton: return
	var xf: Transform3D = evaluated_pose if evaluated_pose is Transform3D else _skeleton.global_transform * _skeleton.get_bone_global_pose(0)
	if not evaluated_pose is Transform3D and is_available() and _pose and _pose.evaluated_valid:
		# Physics callbacks can run between modifier evaluations, when Skeleton3D
		# has restored authored bones. Rebase the last evaluated cube to this tick.
		xf = global_transform * _pose.evaluated_worker.affine_inverse() * _pose.evaluated_root
	if back_tool:
		back_tool._sync_root(xf)
		if not back_tool.foot_occupied(): back_tool._publish_back()
	xf.origin += xf.basis * Vector3(0, HEAD_OFFSET, 0)
	# This is the creature's real face origin. The assisted cargo fixture can
	# travel between both heads and down to a staged component; eyes and the
	# unloaded caption must not follow that separate carrying frame.
	_visual_head_point = xf.origin
	_update_work_tool()
	if carrying and head_leap and head_leap.contacted and head_leap.part==_cargo_source:
		xf = head_leap.contact_frame()
	elif carrying and is_instance_valid(carry_partner) and carry_partner._skeleton:
		var other: Transform3D = carry_partner._skeleton.global_transform * carry_partner._skeleton.get_bone_global_pose(0)
		if carry_partner._pose.evaluated_valid:
			other = carry_partner.global_transform * carry_partner._pose.evaluated_worker.affine_inverse() * carry_partner._pose.evaluated_root
		other.origin += other.basis * Vector3(0, HEAD_OFFSET, 0)
		# A shared level fixture must clear the upper corners of both pitched
		# cubes, rather than intersecting the higher partner's forehead.
		var head_height := maxf(_head_upper_y(xf),_head_upper_y(other)) + .005 - .03
		head_height = maxf(head_height,maxf(xf.origin.y,other.origin.y))
		xf.origin = (xf.origin + other.origin) * .5
		xf.origin.y = head_height
		var span := (other.origin - xf.origin).slide(Vector3.UP)
		if span.length_squared() > .01:
			var right := span.normalized()
			xf.basis = Basis(right, Vector3.UP, right.cross(Vector3.UP)).orthonormalized()
	if cargo_staging and is_instance_valid(cargo_target) and action == "place":
		# Large/cooperative placement retains the existing assisted construction
		# fixture until a physical crane/cradle can support this whole handover.
		# This assisted transfer is not a native toe/cargo placement mechanism.
		var source: Node3D = coordinator.active_jobs[current_job_id].job.part if is_instance_valid(coordinator) and coordinator.active_jobs.has(current_job_id) else null
		if is_instance_valid(source): xf=_cargo_stage_body_pose()*source.carried_local_transform().affine_inverse()
	head_anchor.global_transform = xf
	if is_instance_valid(_cargo_source) and _cargo_source.get("carrier") == head_anchor and _cargo_source.get("freeze") == true:
		# Publish the existing frozen follower after the final cube/head pose,
		# like the toe/tool paths. A released native body is never moved here.
		_cargo_source.global_transform = _cargo_source.carried_world_transform()
	_sync_head_crew_payload()

func _head_upper_y(head: Transform3D) -> float:
	var height := -INF
	for x: float in [-.38,.38]:
		for z: float in [-.38,.38]:
			height = maxf(height,(head*Vector3(x,0,z)).y)
	return height

func _update_caption_height(delta: float) -> void:
	var height := maxf(1.45, _visual_head_point.y - global_position.y + .35) if _visual_head_point.is_finite() else 1.45
	if carrying and is_instance_valid(coordinator) and coordinator.active_jobs.has(current_job_id):
		var source: Node3D = coordinator.active_jobs[current_job_id].job.get("part")
		if is_instance_valid(source):
			if _caption_source_id != source.get_instance_id():
				_caption_source_id = source.get_instance_id()
				_caption_source_bounds = Catalogue.bounds_of(source.definition)
				for mesh: MeshInstance3D in source.visual.find_children("*","MeshInstance3D",true,false):
					if mesh.mesh: _caption_source_bounds = _caption_source_bounds.merge(source.global_transform.affine_inverse()*mesh.global_transform*mesh.mesh.get_aabb())
				for batch: MultiMeshInstance3D in source.visual.find_children("*","MultiMeshInstance3D",true,false):
					if not batch.multimesh or not batch.multimesh.mesh: continue
					var local: Transform3D = source.global_transform.affine_inverse()*batch.global_transform
					for i in batch.multimesh.instance_count:
						_caption_source_bounds = _caption_source_bounds.merge(local*batch.multimesh.get_instance_transform(i)*batch.multimesh.mesh.get_aabb())
			var bounds: AABB = source.global_transform*_caption_source_bounds
			height = maxf(height,bounds.end.y-global_position.y+.35)
	else:
		_caption_source_id = 0
	# Stay above the real payload immediately when it rises. Lower the visible
	# caption continuously after handover; only its text keeps the .18s cadence.
	var next := lerpf(_label.position.y,height,1.0-exp(-8.0*delta))
	_label.position.y = maxf(height,next)

func _preparing_inspection() -> bool:
	if action != "place" or carrying or not is_instance_valid(coordinator) or not coordinator.active_jobs.has(current_job_id): return false
	var entry: Dictionary = coordinator.active_jobs[current_job_id]
	if entry.get("phase","") != "staging" or not entry.get("staged",false) or entry.job.kind not in ["build","replace"]: return false
	var source: Node3D = entry.job.get("part")
	var target: Node3D = entry.job.get("target")
	return is_instance_valid(source) and is_instance_valid(target) and source.carrier == target and source.get_meta(&"staged_target",null) == target

func feet_work_active() -> bool:
	return action in ["assemble", "repair", "unbend", "maintenance", "operate", "tool_change", "inspect"] or (pickup and pickup.manipulating())

func tool_foot_side() -> int:
	return absi(worker_id.hash()) % 2

func tool_foot_occupied() -> bool:
	return back_tool.ordinary_foot_occupied() if back_tool else is_instance_valid(equipped_tool)

func control_foot_side() -> int:
	# Keep a retained tool curled in its original toe grip. The free opposite
	# foot presses controls; approach and playback must use this same role.
	return 1 - tool_foot_side() if tool_foot_occupied() else tool_foot_side()

func work_point() -> Vector3:
	if pickup and pickup.manipulating(): return pickup.target()
	if not is_instance_valid(work_target): return global_position
	if work_target.get("kind") in ["gun", "station"] and (action == "operate" or current_job_id.begins_with("operate:") or (is_instance_valid(station) and station == work_target)):
		return work_target.foot_control_world(work_foot_side)
	if action == "tool_change":
		# Clear a finite rack's exterior before raising the full mallet head.
		var extraction := smoothstep(tool_pickup_contact_phase,minf(tool_pickup_contact_phase+.14,.96),action_progress) if tool_change_picked_up else 0.0
		return tool_pickup_point+Vector3.UP*.35*tool_pickup_lift_weight()+tool_pickup_return*extraction
	if work_target.get("definition") == null: return work_target.global_position
	var preparation: Variant = BeamPreparation.active_point(self, work_target)
	if preparation is Vector3: return preparation
	if is_instance_valid(coordinator) and coordinator.active_jobs.has(current_job_id):
		var lease: Dictionary = coordinator.active_jobs[current_job_id].job
		if lease.kind=="join" and lease.target==work_target:
			return work_target.connector_world(lease.descriptor.socket_b).origin
		if lease.kind in ["build","replace"] and lease.target==work_target:
			var descriptor: Variant = lease.get("descriptor",{})
			var work_socket: Variant = descriptor.get("construction_work_socket") if descriptor is Dictionary else null
			var parent_id: Variant = descriptor.get("parent") if descriptor is Dictionary else null
			if work_socket is String and not work_socket.is_empty() and work_socket==descriptor.get("socket_b") \
					and descriptor.get("joint")=="rigid" and parent_id is String and not parent_id.is_empty() \
					and not Catalogue.socket(work_target.definition,work_socket).is_empty():
				# An explicit construction face stays on its real primary fastener.
				# A closest underside can move behind adjacent installed structure.
				return work_target.connector_world(work_socket).origin
	if work_target.get("kind") == "access_ramp": return RampAnchor.point(work_target)
	var origin := evaluated_hip(work_foot_side)
	var local := work_target.to_local(origin)
	return work_target.to_global(Catalogue.closest_point(work_target.definition, local))

func foot_tool_span() -> float:
	if pickup and pickup.manipulating(): return 0.0
	if action in ["operate", "tool_change"] or current_job_id.begins_with("operate:") or (is_instance_valid(station) and station == work_target): return 0.0
	return float(equipped_tool.definition.size.y) * .95 if is_instance_valid(equipped_tool) else 0.0

func tool_pickup_release_weight() -> float:
	return smoothstep(tool_pickup_contact_phase,minf(tool_pickup_contact_phase+.2,.96),action_progress) if tool_change_picked_up else 0.0

func tool_pickup_lift_weight() -> float:
	var start := tool_pickup_contact_phase+(.08 if tool_pickup_return.length_squared() > .001 else 0.0)
	return smoothstep(start,minf(start+.2,.96),action_progress) if tool_change_picked_up else 0.0

func _leg_span(side: int) -> float:
	return _leg_lengths[side]

func stable_tool_work() -> bool:
	return action in ["inspect", "assemble", "repair", "unbend", "tool_change", "maintenance"]

func rest_hip_offset() -> Vector3:
	return _skeleton.global_basis * _hip_rest_offsets[work_foot_side]

func evaluated_hip(side: int) -> Vector3:
	# Skeleton3D restores authored poses outside its modifier. Reach checks must
	# use the same evaluated hip as the visible, compressed working creature.
	if _pose and _pose.evaluated_valid:
		return global_transform * _pose.evaluated_worker.affine_inverse() * _pose.evaluated_hips[side]
	var upper := _skeleton.find_bone("Bone.001" if side == 0 else "Bone.002")
	return _skeleton.global_transform * _skeleton.get_bone_global_pose(upper).origin

func clear_tool_axis(contact: Vector3, hip: Vector3) -> Dictionary:
	var span := foot_tool_span()
	if span <= .001: return {"axis": (contact - hip).normalized()}
	var frame := _tool_clearance_frame()
	var target_id := work_target.get_instance_id() if is_instance_valid(work_target) else 0
	var tool_id := equipped_tool.get_instance_id() if is_instance_valid(equipped_tool) else 0
	var previous_axis := Vector3.ZERO
	if stable_tool_work() and _work_axis.length_squared() > .01 and target_id == _work_axis_target and tool_id == _work_axis_tool:
		previous_axis = _work_axis
		# A still reachable, clear tool posture should not switch merely because
		# another discrete candidate becomes slightly cheaper during preparation.
		# Revalidate against the current hip, cube, whole tool and support plane.
		if _tool_axis_reachable(_work_axis,contact,hip,span,frame):
			return {"axis":_work_axis}
	var horizontal := (contact - hip).slide(Vector3.UP).normalized()
	if horizontal.length_squared() < .01: horizontal = -_model.global_basis.z
	var preferred := clampf((contact.y - (hip.y - .4)) / span, -.35, .98)
	var best := {}
	var best_score := INF
	var valid_axes: Array[Vector3] = []
	for vertical: float in [preferred, clampf(preferred - .2, -.35, .98), clampf(preferred + .2, -.35, .98), 0.0, .6, .85, .98, -.35]:
		for yaw: float in [0.0, .5, -.5, 1.0, -1.0]:
			var axis := horizontal.rotated(Vector3.UP, yaw) * sqrt(1.0 - vertical * vertical) + Vector3.UP * vertical
			var grip := contact - axis * span
			if not _tool_axis_reachable(axis,contact,hip,span,frame): continue
			if previous_axis.length_squared() > .01: valid_axes.append(axis)
			var score := absf(vertical - preferred) + absf(yaw) * .2 + grip.distance_to(hip) * .25
			# Mirrored yaw candidates have equal geometric cost. Roundoff must
			# not swap the gripping leg between them on consecutive work ticks.
			if score < best_score - TOOL_AXIS_TIE_EPS:
				best_score = score
				best = {"axis": axis}
	if stable_tool_work() and not best.is_empty():
		if previous_axis.length_squared() > .01:
			# Moving geometry can invalidate yesterday's tool direction. Walk
			# toward a clear candidate by a bounded angular step only if that
			# entire CURRENT intermediate posture is valid as well. A blocked
			# route returns no posture rather than retaining an invalid axis.
			var transition := Vector3.ZERO
			var transition_cost := INF
			var maximum_turn := 6.0/float(Engine.physics_ticks_per_second)
			for axis: Vector3 in valid_axes:
				var angle := previous_axis.angle_to(axis)
				var stepped := previous_axis.slerp(axis,minf(maximum_turn/maxf(angle,.00001),1.0)).normalized()
				if not _tool_axis_reachable(stepped,contact,hip,span,frame): continue
				var cost: float = previous_axis.angle_to(stepped)+axis.angle_to(best.axis)*.025
				if cost < transition_cost-TOOL_AXIS_TIE_EPS:
					transition = stepped
					transition_cost = cost
			if transition.length_squared() < .01: return {}
			best.axis = transition
		_work_axis = best.axis
		_work_axis_target = target_id
		_work_axis_tool = tool_id
	return best

func _tool_axis_reachable(axis: Vector3, contact: Vector3, hip: Vector3, span: float, frame: Dictionary) -> bool:
	var grip := contact-axis*span
	return grip.y >= _ground_point.y+.08 and grip.distance_to(hip) <= _leg_span(work_foot_side)+.09 and _tool_posture_clear(grip-axis*.035,axis,frame)

func clear_held_tool_axis(toe_origin: Vector3, preferred: Vector3,
		support_point := Vector3.INF, support_normal := Vector3.UP) -> Vector3:
	# Blending a clear destination with an authored foot curl can still sweep the
	# shaft through the cube. Keep the actual gripping toe's whole shaft clear,
	# including pickup, travel and retraction; contact gating remains unchanged.
	if not is_instance_valid(equipped_tool): return preferred
	var frame := _tool_clearance_frame()
	if support_point.is_finite():
		frame.support_point = support_point
		frame.support_normal = support_normal
	if _tool_posture_clear(toe_origin, preferred, frame): return preferred
	var horizontal := preferred.slide(Vector3.UP).normalized()
	if horizontal.length_squared() < .01: horizontal = -_model.global_basis.z
	var best := preferred
	var score := INF
	for vertical: float in [clampf(preferred.y, -.98, .98), .45, .25, 0.0, -.25, .75, -.6]:
		for yaw: float in [0.0, .3, -.3, .6, -.6, 1.0, -1.0, PI]:
			var axis := horizontal.rotated(Vector3.UP, yaw) * sqrt(1.0 - vertical * vertical) + Vector3.UP * vertical
			if not _tool_posture_clear(toe_origin, axis, frame): continue
			var deviation := 1.0 - axis.dot(preferred)
			if deviation < score - TOOL_AXIS_TIE_EPS:
				score = deviation
				best = axis
	# A raised edge can leave too little toe/terrain clearance for ANY axis.
	# Let the finite leg solve provide room instead of accepting an unsafe curl.
	if score<INF and action.is_empty() and _pose and _pose._walking_ik:
		# The discrete search supplies a genuinely clear endpoint. Refine its
		# path toward neutral through the SAME complete-tool SAT and terrain
		# tests, so a moving sole does not jump between fixed tilt buckets.
		var clear := best
		var lower := 0.0
		var upper := 1.0
		for iteration in 10:
			var weight := (lower+upper)*.5
			var trial := best.slerp(preferred,weight).normalized()
			if _tool_posture_clear(toe_origin,trial,frame):
				clear=trial
				lower=weight
			else: upper=weight
		return clear
	return best if score < INF else Vector3.ZERO

func _tool_clearance_frame() -> Dictionary:
	# Candidate axes are tested synchronously against the same evaluated rig.
	# Keep these observations local to the call, never across pose changes.
	var inverse := (_skeleton.global_transform * _skeleton.get_bone_global_pose(0)).affine_inverse()
	var toe_index := _skeleton.find_bone("toe.L" if tool_foot_side() == 0 else "toe.R")
	var toe_basis := _skeleton.global_basis * _skeleton.get_bone_global_pose(toe_index).basis
	return {"inverse": inverse, "toe_basis": toe_basis,
		"bounds": AABB(Vector3(-.38, -.3, -.38), Vector3(.76, .68, .76)).grow(.025),
		"length": float(equipped_tool.definition.size.y),
		"supported": on_ground, "support_point": _ground_point, "support_normal": ground_normal,
		"keepouts": equipped_tool.get_meta(&"worker_tool_keepouts", [])}

func _tool_posture_clear(toe_origin: Vector3, axis: Vector3, frame: Dictionary = {}) -> bool:
	if not is_instance_valid(equipped_tool): return true
	if frame.is_empty(): frame = _tool_clearance_frame()
	var inverse: Transform3D = frame.inverse
	var toe_basis: Basis = frame.toe_basis
	var basis: Basis = frame.basis if frame.has("basis") else tool_axis_basis(toe_basis,axis)
	var length: float = frame.length
	var world := Transform3D(basis, toe_origin + axis * (.035 + length * .45))
	var transform := inverse * world
	var bounds: AABB = frame.bounds
	# Keep the complete physical handle inside the same guard as its visual
	# slices, including the short bare ends beyond the authored mesh.
	if bounds.intersects_segment(transform*Vector3(0,-length*.5,0),transform*Vector3(0,length*.5,0)) != null: return false
	for box: AABB in frame.keepouts:
		if _tool_box_intersects(bounds,transform,box): return false
		if frame.supported:
			# The same cached visual slices must stay above the observed support
			# plane during approach and release, not only clear the face at contact.
			var normal: Vector3 = frame.support_normal
			var half := box.size * .5
			var radius := absf(normal.dot(basis.x)) * half.x + absf(normal.dot(basis.y)) * half.y + absf(normal.dot(basis.z)) * half.z
			if normal.dot(world * box.get_center() - frame.support_point) - radius < .005: return false
	return true

static func _tool_box_intersects(bounds: AABB, transform: Transform3D, box: AABB) -> bool:
	if not bounds.intersects(transform*box): return false
	# A transformed AABB includes empty corners beside a tilted tool. Retain
	# the same padded cube and keepout box, testing their actual oriented
	# volumes on both face normals and all edge cross products.
	var delta := transform*box.get_center()-bounds.get_center()
	var cube_half := bounds.size*.5
	var tool_half := box.size*.5
	var x := transform.basis.x*tool_half.x
	var y := transform.basis.y*tool_half.y
	var z := transform.basis.z*tool_half.z
	var axes: Array[Vector3] = [Vector3.RIGHT,Vector3.UP,Vector3.BACK,
		y.cross(z),z.cross(x),x.cross(y)]
	for edge: Vector3 in [x,y,z]:
		axes.append(edge.cross(Vector3.RIGHT))
		axes.append(edge.cross(Vector3.UP))
		axes.append(edge.cross(Vector3.BACK))
	for axis: Vector3 in axes:
		if axis.length_squared() < 1e-12: continue
		var cube_radius := absf(axis.x)*cube_half.x+absf(axis.y)*cube_half.y+absf(axis.z)*cube_half.z
		var tool_radius := absf(axis.dot(x))+absf(axis.dot(y))+absf(axis.dot(z))
		if absf(axis.dot(delta)) > cube_radius+tool_radius: return false
	return true

func held_tool_basis_clear(toe_origin: Vector3, basis: Basis,
		support_point: Vector3, support_normal: Vector3) -> bool:
	# Recovery must validate the complete intermediate orientation, including
	# axial roll; a clear handle direction alone cannot protect the mallet head.
	var frame := _tool_clearance_frame()
	frame.basis = basis
	if support_point.is_finite():
		frame.support_point = support_point
		frame.support_normal = support_normal
	return _tool_posture_clear(toe_origin,basis.y,frame)

func held_tool_return_direction(toe_origin: Vector3, basis: Basis, support_normal: Vector3) -> Vector3:
	# A crossbar can enter a different cube face than the gripping toe. Choose
	# the return direction from the actual intersecting oriented mesh slices;
	# the existing finite leg trials still decide whether any endpoint is clear.
	var frame := _tool_clearance_frame()
	var inverse: Transform3D = frame.inverse
	var cube: Transform3D = inverse.affine_inverse()
	var local := inverse*Transform3D(basis,toe_origin+basis.y*(.035+float(frame.length)*.45))
	var intersections: Array[AABB] = []
	for box: AABB in frame.keepouts:
		if _tool_box_intersects(frame.bounds,local,box): intersections.append(local*box)
	if intersections.is_empty(): return Vector3.ZERO
	var bounds: AABB = frame.bounds
	var best := Vector3.ZERO
	var shortest := INF
	for axis: int in 3:
		for sign_value: float in [-1.0,1.0]:
			var local_axis := Vector3.ZERO
			local_axis[axis] = sign_value
			var direction: Vector3 = (cube.basis*local_axis).slide(support_normal).normalized()
			var progress: float = (inverse.basis*direction).dot(local_axis)
			if progress <= .00001: continue
			var distance := 0.0
			for box: AABB in intersections:
				var separation: float = bounds.end[axis]-box.position[axis] if sign_value>0.0 else box.end[axis]-bounds.position[axis]
				distance = maxf(distance,separation/progress)
			if distance < shortest:
				shortest = distance
				best = direction
	return best

func held_tool_clearance_debug(toe_origin: Vector3, basis: Basis, support_point: Vector3, support_normal: Vector3) -> Dictionary:
	var frame := _tool_clearance_frame()
	var axis := basis.y
	var world := Transform3D(basis,toe_origin+axis*(.035+frame.length*.45))
	var local: Transform3D = frame.inverse*world
	var floor_gap := INF
	var meshes := 0
	for box: AABB in frame.keepouts:
		if _tool_box_intersects(frame.bounds,local,box): meshes += 1
		var half := box.size*.5
		var radius := absf(support_normal.dot(basis.x))*half.x+absf(support_normal.dot(basis.y))*half.y+absf(support_normal.dot(basis.z))*half.z
		floor_gap = minf(floor_gap,support_normal.dot(world*box.get_center()-(support_point if support_point.is_finite() else frame.support_point))-radius)
	return {"shaft":frame.bounds.intersects_segment(local*Vector3(0,-frame.length*.5,0),local*Vector3(0,frame.length*.5,0)) != null,"meshes":meshes,"floor":floor_gap,"local_grip":frame.inverse*toe_origin}

func tool_axis_basis(toe_basis: Basis, axis: Vector3) -> Basis:
	# A direction alone leaves axial rotation undefined. A minimum-angle turn
	# becomes singular when the animated toe crosses the opposite direction.
	# Work keeps the tool's right edge in the creature's facing frame;
	# clearance and the actual toe use this SAME complete orientation.
	var right: Vector3
	if stable_tool_work():
		var reference: Basis = tool_pickup_basis if action == "tool_change" else _model.global_basis
		right = reference.x.slide(axis)
		if right.length_squared() < .01: right = reference.z.slide(axis)
		right = right.normalized()
	else:
		if not feet_work_active():
			# Recovery has a real neutral roll to return to. Keeping yesterday's
			# axial roll forever can require an indefinitely raised gripping leg.
			right = _model.global_basis.x.slide(axis)
			if right.length_squared() < .01: right = _model.global_basis.z.slide(axis)
			right = right.normalized()
		else:
			var turn := Quaternion(toe_basis.y.normalized(),axis)
			right = turn*toe_basis.x.normalized()
	return Basis(right, axis, right.cross(axis)).orthonormalized()

func _update_work_tool(evaluated_pose := false) -> void:
	if evaluated_pose:
		var bone := _skeleton.find_bone("toe.L" if work_foot_side == 0 else "toe.R")
		if bone < 0: return
		foot_grip_transform = _skeleton.global_transform * _skeleton.get_bone_global_pose(bone)
		var tool_bone := _skeleton.find_bone("toe.L" if tool_foot_side() == 0 else "toe.R")
		tool_grip_transform = _skeleton.global_transform * _skeleton.get_bone_global_pose(tool_bone)
		foot_grip_valid = true
	if not foot_grip_valid: return
	if back_tool and back_tool.pose_owned():
		if evaluated_pose and back_tool.foot_occupied(): back_tool._publish_foot(tool_grip_transform)
		return
	if evaluated_pose and pickup: pickup.evaluate(foot_grip_transform)
	var toe := tool_grip_transform
	if not evaluated_pose and _pose and _pose.evaluated_valid:
		# Native motion can advance between modifier evaluations. Follow the
		# same rebased evaluated rig as the cube/head, rather than leaving the
		# retained tool behind for one physics tick during cancelled work.
		toe = global_transform * _pose.evaluated_worker.affine_inverse() * toe
	var grip := toe.origin + toe.basis.y * .035
	var axis := toe.basis.y.normalized()
	var right := toe.basis.x.normalized()
	var basis := Basis(right, axis, right.cross(axis)).orthonormalized()
	var span := float(equipped_tool.definition.size.y) if tool_foot_occupied() else 0.0
	tool_anchor.global_transform = Transform3D(basis, grip + axis * span * .45)
	if is_instance_valid(equipped_tool) and equipped_tool.carrier == tool_anchor:
		equipped_tool.global_transform = tool_anchor.global_transform
	_tool.global_transform = Transform3D(Basis.IDENTITY, grip + axis * span * .95)
	_sparks.position = Vector3.ZERO

func portable_gun_control_ready(item: Node3D) -> bool:
	return portable_gun != null and portable_gun.control_ready(item)

func foot_contact_ready() -> bool:
	if not on_ground or not is_instance_valid(work_target): return false
	if action == "tool_change" and tool_change_picked_up: return true
	# Skeleton modifiers restore the authored pose after evaluation. Keep the actual
	# evaluated grip, so timed callbacks test the rendered contact rather than that rest pose.
	if not foot_grip_valid: return false
	var toe := foot_grip_transform
	var tip := toe.origin + toe.basis.y.normalized() * (.035 + foot_tool_span())
	return tip.distance_to(work_point()) < .18

func can_reach_work() -> bool:
	if not is_instance_valid(work_target): return false
	var hip := evaluated_hip(work_foot_side)
	return hip.distance_to(work_point()) <= _leg_span(work_foot_side) + foot_tool_span() + .07

func can_reach_target(target: Node3D) -> bool:
	if not is_instance_valid(target): return false
	if target == work_target and (not current_job_id.is_empty() or is_instance_valid(station)): return can_reach_work()
	# Scheduling estimates a nearby access position. Completion uses the actual ankle/toe contact above.
	var origin := _skeleton.global_transform * _skeleton.get_bone_global_pose(0).origin
	var local := target.to_local(origin)
	return origin.distance_to(target.to_global(Catalogue.closest_point(target.definition, local))) <= _leg_span(work_foot_side) + 1.05

func supported_by(machine: Node) -> bool:
	return is_instance_valid(machine) and on_ground and is_instance_valid(_ground_body) and _ground_body.get("assembly") == machine

func bind_station_support() -> void:
	station_support = _ground_body if is_instance_valid(station) and supported_by(station.assembly) else null
	if station_support:
		# Preserve the capsule's standing location, not the offset supporting sole:
		# walking the capsule onto that sole would apply the authored weight shift twice.
		var standing := global_position - ground_normal * (global_position - _ground_point).dot(ground_normal)
		station_support_local = station_support.to_local(standing)

func _apply_skin() -> void:
	_skin_mesh = _model.find_child("wakoMesh", true, false) as MeshInstance3D
	if not _shared_skin_material:
		var original := _skin_mesh.get_active_material(0) as StandardMaterial3D
		_shared_skin_material = ShaderMaterial.new()
		_shared_skin_material.shader = SKIN
		_shared_skin_material.set_shader_parameter("albedo_texture", original.albedo_texture)
		var eye_material := ShaderMaterial.new()
		eye_material.shader = EYE_SKIN
		eye_material.set_shader_parameter("albedo_texture", original.albedo_texture)
		# A coplanar material pass inherits the same instance expression, native
		# geometry, skeleton and motion depth; ALPHA marks only eye fragments.
		_shared_skin_material.next_pass = eye_material
	_skin_mesh.set_surface_override_material(0, _shared_skin_material)

func _seed_expression() -> void:
	# One face engine per helper (seeded from worker_id); per-instance
	# uniforms on the shared skin.
	eyes = Eyes.new()
	eyes.setup(self)

func bind_eye_smile_source(source: RefCounted) -> void:
	# Personality owns observation/timing. Eyes only consume its bounded intent;
	# a weak reference does not retain an unloaded worker/director pair.
	# Smile contract: smile_weight (float), look_position (finite Vector3).
	# The production personality also publishes alert_weight/alert_position
	# from its already revalidated live cached enemy core, its attention
	# result and the voice clock used for mouth sync.
	_eye_smile_source = weakref(source) if source else null

func _update_expression(delta: float) -> void:
	# Runs every physics tick: blinks and saccades are evaluated at 120 Hz;
	# the face brain runs at 6/4/2 Hz by camera distance and visibility (12-20
	# Hz while a near face acts, talks, strikes or is alarmed), and only changed
	# instance uniforms are uploaded. The engine mirrors its gaze into _eye_gaze.
	if eyes and _skin_mesh: eyes.advance(delta)

## Short event face from a real trigger (surprise, joy, pride, worry,
## annoyed, relief, curious, notice, squeeze, flinch, satisfied).
func face_pulse(kind: StringName, amount := 1.0) -> void:
	if eyes: eyes.pulse(kind, amount)

func face_blink(slow := false) -> void:
	if eyes: eyes.blink_now(1.0, slow)

## Rest/sit API for the face: relaxed lids, sleepy after a long rest.
func set_face_rest(relaxed: float, sleepy := 0.0) -> void:
	if eyes: eyes.set_rest(relaxed, sleepy)

func _author_actions() -> void:
	if _shared_work_library:
		_animation.add_animation_library("work", _shared_work_library)
		HeadPickup.install(self)
		return
	var library := AnimationLibrary.new()
	for kind: String in ["pickup", "place", "inspect", "assemble", "repair", "maintenance", "unbend", "tool_change", "brace", "push", "pull", "operate", "step", "danger", "interrupted"]:
		for side: String in ["L", "R"]:
			var source := "wk_" + kind + ("" if kind == "danger" else "_" + side)
			var clip := _animation.get_animation(source).duplicate(true) as Animation
			clip.loop_mode = Animation.LOOP_LINEAR if kind == "danger" else Animation.LOOP_NONE
			if kind not in ["danger", "interrupted"]:
				var method := clip.add_track(Animation.TYPE_METHOD)
				clip.track_set_path(method, NodePath(".."))
				clip.track_insert_key(method, clip.length * .56, {"method": "_work_contact", "args": [kind]})
			library.add_animation(kind + "_" + side, clip)
	library.add_animation("carry", _animation.get_animation("wk_carry").duplicate(true))
	library.add_animation("run", _animation.get_animation("wk_run").duplicate(true))
	_shared_work_library = library
	_animation.add_animation_library("work", library)
	HeadPickup.install(self)

func _work_contact(kind: String) -> void:
	if kind=="pickup" and head_leap and head_leap.active(): return
	if work_action_held: return
	if action != kind or _contact_sent or not on_ground: return
	if kind == "pickup" and pickup.manipulating() and not pickup.contact_ready(): return
	if kind in ["assemble", "repair", "unbend", "maintenance", "tool_change", "operate", "inspect"] and not foot_contact_ready(): return
	if kind == "tool_change" and is_instance_valid(work_target):
		# Preserve stock pose at the existing fitting event. The empty anchor
		# must not drop its centre onto a bare grip before full length is known.
		tool_anchor.global_transform = work_target.global_transform
		tool_pickup_contact_phase = action_progress
	_contact_sent = true
	if kind in ["assemble", "repair", "unbend", "maintenance", "tool_change", "operate"]:
		_play_work_impact(kind)
		if is_instance_valid(equipped_tool) and kind in ["assemble", "repair"]:
			_spark_time = .28
			equipped_tool.wear = minf(equipped_tool.wear + .002, 1.0)
	action_contact.emit(kind)

func _play_work_impact(kind: String) -> void:
	# Called only from the unchanged supported toe/tool contact admission.
	# Audio variation never consumes locomotion or personality randomness.
	if Shortcuts.quitting or not is_instance_valid(_work_audio) or _work_audio.playing: return
	var choice := _work_impact_rng.randi_range(0,WORK_IMPACTS.size()-2 if _last_work_impact>=0 else WORK_IMPACTS.size()-1)
	if _last_work_impact>=0 and choice>=_last_work_impact: choice += 1
	_last_work_impact = choice
	_work_audio.stream = WORK_IMPACTS[choice]
	_work_audio.pitch_scale = (.9 if kind=="unbend" else 1.2)*_work_impact_rng.randf_range(.94,1.06)
	_work_audio.global_position = work_point()
	_work_audio.play()

func _play_sound(stream: AudioStream, pitch: float) -> void:
	if _audio and not _audio.playing:
		_audio.stream = stream
		_audio.pitch_scale = pitch
		_audio.play()

func _create_tool() -> void:
	_tool = Node3D.new()
	_tool.name = "FootContactEffects"
	add_child(_tool)
	_sparks = GPUParticles3D.new()
	_sparks.name = "WorkContactSparks"
	_sparks.amount = 14
	_sparks.lifetime = .24
	_sparks.emitting = false
	_sparks.position = Vector3(0, -.1, .4)
	var particles := ParticleProcessMaterial.new()
	particles.direction = Vector3(0, .5, 1)
	particles.spread = 65.0
	particles.initial_velocity_min = .7
	particles.initial_velocity_max = 1.6
	particles.gravity = Vector3(0, -3.2, 0)
	_sparks.process_material = particles
	var spark_mesh := SphereMesh.new()
	spark_mesh.radius = .008
	spark_mesh.height = .016
	spark_mesh.radial_segments = 4
	spark_mesh.rings = 2
	var spark_material := StandardMaterial3D.new()
	spark_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark_material.albedo_color = Color(1, .76, .33)
	spark_material.emission_enabled = true
	spark_material.emission = Color(1, .58, .17)
	spark_material.emission_energy_multiplier = 1.5
	spark_mesh.material = spark_material
	_sparks.draw_pass_1 = spark_mesh
	_tool.add_child(_sparks)
	_tool.visible = false

func serialize_state() -> Dictionary:
	var physical: Dictionary=ragdoll.serialize_state() if ragdoll else {}
	if physical.is_empty() and head_leap: physical=head_leap.saved_physical_body()
	var station_assembly := -1
	if is_instance_valid(station) and is_instance_valid(coordinator): station_assembly = coordinator.yard.assemblies.find(station.assembly)
	return {"id": worker_id, "name": helper_name, "position": [global_position.x, global_position.y, global_position.z],
		"velocity": [linear_velocity.x, linear_velocity.y, linear_velocity.z], "job": current_job_id,
		"heading": _heading, "idle_heading": _idle_heading,
		"progress": progress, "paused": paused, "status": status_text,
		"companion_mode": companion_mode, "companion_hold": [companion_hold.x, companion_hold.y, companion_hold.z],
		"station": station.part_id if is_instance_valid(station) else "",
		"station_assembly": station_assembly,
		"station_support": station_support.part_id if is_instance_valid(station_support) else "",
		"station_support_local": [station_support_local.x, station_support_local.y, station_support_local.z],
		"safe_position": [safe_position.x, safe_position.y, safe_position.z],
		"physical_body": physical,
		"portable_gun": portable_gun.serialize_owned() if portable_gun else {},
		"back_tool": back_tool.serialize_state() if back_tool else {}}

func restore_state(data: Dictionary) -> void:
	worker_id = str(data.get("id", worker_id))
	_seed_expression()
	work_foot_side = absi(worker_id.hash()) % 2
	_heading = float(data.get("heading", 0.0))
	_idle_heading = float(data.get("idle_heading", _heading))
	_model.rotation.y = _heading
	helper_name = str(data.get("name", helper_name))
	var p: Array = data.get("position", [])
	if p.size() == 3: global_position = Vector3(p[0], p[1], p[2])
	var v: Array = data.get("velocity", [])
	if v.size() == 3: linear_velocity = Vector3(v[0], v[1], v[2])
	var s: Array = data.get("safe_position", [])
	if s.size() == 3: safe_position = Vector3(s[0], s[1], s[2])
	companion_mode = str(data.get("companion_mode", "work"))
	if companion_mode not in ["work", "follow", "stay"]: companion_mode = "work"
	companion_speed = walk_speed
	companion_hold = global_position-Vector3.UP*ride_height
	var hold: Variant = data.get("companion_hold", [])
	if hold is Array and hold.size() == 3 and hold.all(func(number: Variant) -> bool: return (number is int or number is float) and is_finite(float(number))):
		companion_hold = Vector3(float(hold[0]), float(hold[1]), float(hold[2]))
	paused = bool(data.get("paused", false))
	current_job_id = str(data.get("job", ""))
	progress = float(data.get("progress", 0.0))
	saved_station_id = str(data.get("station", ""))
	saved_station_assembly = int(data.get("station_assembly", -1))
	saved_station_support_id = str(data.get("station_support", ""))
	var foot: Array = data.get("station_support_local", [])
	if foot.size() == 3: station_support_local = Vector3(foot[0], foot[1], foot[2])
	station_reacquire_time = .5
	status_text = "Checking saved assignment"
	if back_tool: back_tool.restore_state(data.get("back_tool",{}))
	if ragdoll: ragdoll.restore_state(data.get("physical_body", {}))
	if portable_gun: portable_gun.restore_owned(data.get("portable_gun", {}))

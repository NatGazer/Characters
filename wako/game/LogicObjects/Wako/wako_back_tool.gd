extends RefCounted
## Finite same-body foot toss and assisted contact-only back clamp.
## The equipped item stays owned by this Wako in every phase. Only an attached
## item contributes to capsule mass; native flight retains the original body.
const PBR := preload("res://Components/Contraptions/ancient_pbr.gd")
const Part := preload("res://Components/Contraptions/contraption_part.gd")
const AncientVisual := preload("res://Components/Contraptions/ancient_machine_visual.gd")
const HolderGeometry := preload("res://LogicObjects/Wako/wako_back_holder_geometry.gd")
const HolderVisual := preload("res://LogicObjects/Wako/wako_back_holder_visual.gd")
const SENSOR_LAYER := 1 << 20
const TOE_SPEED := 1.5
const TOE_TURN := 4.5
const MAX_KICK_SPEED := 6.5
const FLIGHT_SECONDS := .56
const FOOT_WORK := ["inspect", "assemble", "repair", "unbend", "maintenance", "tool_change"]
var worker: RigidBody3D
var phase := "foot"
var reason := ""
var pending_action := ""
var _pending_job := ""
var tosses := 0
var catches := 0
var retrievals := 0
var native_samples := 0
var validation_usec := 0

# Opt-in diagnostic scalars only. Each inclusive subtree is reported separately;
# nested timings must never be added together. Disabled during ordinary play.
var source_budget_enabled := "--easy-island-source-budget" in OS.get_cmdline_user_args()
var source_budget: Dictionary = {}
var return_preflight_reuse_enabled: bool = not ("--back-tool-return-preflight-no-reuse" in OS.get_cmdline_user_args())
var _empty_toe_native_query_calls: int = 0
var _empty_retrieval_sample_checks: int = 0
var _whole_tool_native_query_calls: int = 0
var _whole_tool_path_sample_checks: int = 0
var _return_native_sample_reuses: int = 0
var return_preflight_timings_enabled: bool = source_budget_enabled and ("--back-tool-return-preflight-times" in OS.get_cmdline_user_args())
var _whole_tool_reach_usec: int = 0
var _whole_tool_posture_usec: int = 0
var _whole_tool_native_usec: int = 0
var _whole_tool_reach_calls: int = 0
var _whole_tool_posture_calls: int = 0
var _whole_tool_sample_math_usec: int = 0
var _whole_tool_frame_clear_usec: int = 0
var _whole_tool_refusal_usec: int = 0
var last_path_failure: Dictionary = {}
var last_native_obstacle: Dictionary = {}
var launch_impulse := Vector3.ZERO
var launch_before_momentum := Vector3.ZERO
var launch_after_momentum := Vector3.ZERO
var catch_before_momentum := Vector3.ZERO
var catch_after_momentum := Vector3.ZERO
var catch_pose_error := 0.0
var retrieval_pose_error := 0.0
var retrieval_contact_observation_enabled: bool = "--back-tool-current3-retrieval" in OS.get_cmdline_user_args() or "--back-tool-current3-retrieval-negative" in OS.get_cmdline_user_args()
var last_retrieval_contact: Dictionary = {}
var fitting_return_corrections:=0
var fitting_return_retains:=0
var last_fitting_return: Dictionary={}
var _supported_return_pending: Dictionary={}
const SUPPORTED_RETURN_STATUS := "Retaining the current supported original tool while its return clears"
const RETRIEVAL_REFUSAL := "Can't reach the tool on its back. Clear nearby parts or give the Wako room to stand."
var max_toe_step := 0.0
var max_toe_turn := 0.0
var last_contact_points := PackedVector3Array()
var back_anchor: Node3D
var holder: AnimatableBody3D
var _holder_geometry := HolderGeometry.new()
var _holder_geometry_ready := false
var _holder_half_width := -1.0
var _seat_colliders: Array[CollisionShape3D] = []
var _seat_models: Array[MeshInstance3D] = []
var _drop_arms: Array[MeshInstance3D] = []
var _age := 0.0
var _wait := 0.0
var _retry := 0.0
var _waypoints: Array[Transform3D] = []
var _stow_local_waypoints: Array[Transform3D] = []
var _retrieval_local_waypoints: Array[Transform3D] = []
var _path_index := 0
var _return_segment_index := -1
var _return_segment_phase := ""
var _return_segment_start := Transform3D.IDENTITY
var _return_segment_age := 0.0
var _return_segment_seconds := 0.0
var _toe := Transform3D.IDENTITY
var _toe_in_ankle := Transform3D.IDENTITY
var _previous_toe := Transform3D.IDENTITY
var _home_toe_body := Transform3D.IDENTITY
var _home_toe_in_ankle := Transform3D.IDENTITY
var _toe_velocity := Vector3.ZERO
var _toe_angular := Vector3.ZERO
var _ordinary_motion: Dictionary={}
var _ordinary_motion_age:=INF
var _ordinary_drop_pending:=false
var last_drop_motion: Dictionary={}
var _previous_worker := Transform3D.IDENTITY
var _tool_com_local := Vector3.ZERO
var _knee_plane_world:=Vector3.FORWARD
var _root := Transform3D.IDENTITY
var _body_frame := Transform3D.IDENTITY
var _rest_root_basis := Basis.IDENTITY
var _back_local := Transform3D.IDENTITY
var _tool_id := 0
var _tool_rid := RID()
var _foot_side := 0
var _side_sign := -1.0
var _saved_linear_damp := 0.0
var _saved_linear_mode := 0
var _saved_angular_damp := 0.0
var _saved_angular_mode := 0
var _damping_saved := false
var _restore: Dictionary = {}
var _want_stow := false
var _stow_wait:=0.0
var _query := PhysicsShapeQueryParameters3D.new()
var _contact_query := PhysicsShapeQueryParameters3D.new()
var _empty_foot_shape := SphereShape3D.new()
var _native_colliders: Array[CollisionShape3D] = []
var _native_local: Array[Transform3D] = []
var _cached_tool_id := 0
var _preflight_frame: Dictionary = {}
var _empty_return_active:=false
var _empty_return_tail:=0.0
var _tool_free_recovery:=false
var _empty_return_source_id:=0
var _empty_return_source_rid:=RID()
var _cancel_pole_active:=false
var _cancel_axes: Array[Vector3]=[Vector3.DOWN,Vector3.DOWN]
var _cancel_poles: Array[Vector3]=[Vector3.FORWARD,Vector3.FORWARD]
var _cancel_pose_delta:=0.0
var _empty_sole:=Vector3.ZERO
var _empty_ankle:=Basis.IDENTITY
var empty_sole_step:=0.0
var empty_ankle_turn:=0.0
var _work_pole_active:=false
var _work_poles: Array[Vector3]=[Vector3.FORWARD,Vector3.FORWARD]
var _work_pole_seed: Dictionary={}
var _work_pole_age:=0.0
var _work_pole_mode:="work"
var _fitting_epoch: Dictionary={}
static var _bronze: StandardMaterial3D
static var _stone: StandardMaterial3D
static var _rubber: StandardMaterial3D
static var _holder_meshes: Dictionary = {}

func setup(owner: RigidBody3D) -> void:
	worker = owner
	_rest_root_basis = worker._skeleton.get_bone_global_rest(0).basis.orthonormalized()
	back_anchor = Node3D.new()
	back_anchor.name = "SeatedBackToolBinding"
	worker.add_child(back_anchor)
	holder = AnimatableBody3D.new()
	holder.name = "AncientBackToolCradle"
	holder.collision_layer = SENSOR_LAYER
	holder.collision_mask = 0
	holder.sync_to_physics = false
	worker.add_child(holder)
	holder.add_to_group(&"wako_back_cradles")
	_build_holder()
	_query.collision_mask = 0x7fffffff & ~SENSOR_LAYER
	_query.margin = 0.0
	_contact_query.collision_mask = SENSOR_LAYER
	_contact_query.margin = 0.0
	_contact_query.exclude = worker.query_exclusions()
	_empty_foot_shape.radius = .07
	holder.visible = false
	# Initialize the real default seat geometry before assigning its finite load.
	_sync_root()
	_holder_geometry_ready = _holder_geometry.setup(holder)

func foot_occupied() -> bool:
	return is_instance_valid(worker.equipped_tool) and worker.equipped_tool.carrier == worker.tool_anchor

func pose_owned() -> bool:
	return phase in ["prepare", "retrieve", "return"]

func ordinary_foot_occupied() -> bool:
	return foot_occupied() and not pose_owned()

func request_stow() -> bool:
	# Optional head-flight caller: readiness requires real completed custody,
	# never a nominal anchor or a fabricated catch. The caller owns its queue.
	if not is_instance_valid(worker.equipped_tool): return true
	if phase == "back" and worker.equipped_tool.carrier == back_anchor: return true
	if phase == "foot" and _retry <= 0.0: _request_toss()
	return false

func holder_mass() -> float:
	# Permanent hardware remains present while hidden or without a tool.
	return HolderGeometry.MASS

func holder_load(evaluated_root: Variant = null) -> Dictionary:
	if not _holder_geometry_ready: return {}
	var load: Dictionary = _holder_geometry.holder_load()
	if not load.is_empty() and evaluated_root is Transform3D:
		var root: Transform3D = evaluated_root
		var frame := Transform3D((root.basis*_rest_root_basis.inverse()).orthonormalized(),root.origin)
		load.frame = frame
		load.world_point = frame*Vector3(load.local_com)
	return load

func onboard_mass() -> float:
	var tool: RigidBody3D = worker.equipped_tool
	return float(tool.mass) if is_instance_valid(tool) and tool.carrier in [worker.tool_anchor, back_anchor] else 0.0

func busy() -> bool:
	return _empty_return_active or (_tool_free_recovery and _cancel_pole_active) or phase in ["prepare", "flight", "retrieve", "return"]

func blocks_navigation() -> bool:
	if worker.fear_time>0.0 or not (busy() or (_want_stow and foot_occupied())): return false
	# A released mallet can support the native spring above the actual two
	# foot columns. Let the existing finite parking walk leave that support;
	# the empty sole still has to finish its original bounded return.
	return not (loose_tool_support_recovery() and worker.has_target \
		and worker.coordinator.empty_tool_parking_departure_ready(worker))

func loose_tool_support_recovery() -> bool:
	if not _tool_free_recovery or not _empty_return_active or not _cancel_pole_active \
		or phase!="foot" or _work_pole_active or not _restore.is_empty() or not pending_action.is_empty(): return false
	if not worker.action.is_empty() or not worker.current_job_id.is_empty() or worker.paused \
		or not worker.on_ground or not worker.is_available() or worker.fear_time>0.0: return false
	if is_instance_valid(worker.equipped_tool) or is_instance_valid(worker.equipped_gun) \
		or is_instance_valid(worker.station) or is_instance_valid(worker.work_target) \
		or worker.carrying or worker.cargo_mass>0.0 or is_instance_valid(worker._cargo_source): return false
	if worker.head_leap and worker.head_leap.active(): return false
	if worker.pickup and worker.pickup.state not in ["","caught","failed"]: return false
	if worker.portable_gun and worker.portable_gun.handoff_active(): return false
	if not worker._pose or not worker._pose.evaluated_valid or not worker._pose._work_release.is_empty(): return false
	var coordinator: Node=worker.coordinator
	if not is_instance_valid(coordinator) or not is_instance_valid(coordinator.yard): return false
	var support: RigidBody3D=worker._ground_body
	if not is_instance_valid(support) or support.get_instance_id()!=_empty_return_source_id \
		or support.get_rid()!=_empty_return_source_rid or support.get("assembly")!=null \
		or support.get("carrier")!=null or support.freeze or support.get_meta(&"stored",false) \
		or support.get_meta(&"in_transit",false) or support.get_meta(&"player_carry",false): return false
	return support.get("kind") in ["assembly_tool","salvage_tool"] \
		and coordinator.yard.loose_parts.has(support) and not coordinator.yard._part_reserved(support)

func before_action(kind: String) -> bool:
	if kind!="tool_change": _fitting_epoch.clear()
	if kind in ["interrupted", "danger"]:
		_work_pole_active=false
		pending_action = ""
		_pending_job = ""
		if busy(): drop("Interrupted during back-tool transfer")
		return true
	if busy():
		pending_action = kind
		_pending_job = worker.current_job_id
		return false
	if not is_instance_valid(worker.equipped_tool): return true
	if phase == "back" and kind in FOOT_WORK:
		pending_action = kind
		_pending_job = worker.current_job_id
		worker.stop_navigation()
		# The current completed modifier owns retrieval capture below.
		return false
	return true

func action_entered(kind: String) -> void:
	if kind not in FOOT_WORK:
		_work_pole_active=false
		return
	if phase!="foot" or not worker.on_ground or not worker.is_available() or not worker._pose.evaluated_valid: return
	var tool: RigidBody3D=worker.equipped_tool
	if not is_instance_valid(tool) and kind!="tool_change": return
	# Consecutive foot actions must enter from the same actually published
	# foot/tool, rather than reuse the previous action's manipulation epoch.
	worker._pose._work_origin.clear()
	worker._pose._work_entry.clear()
	worker._pose._manipulation_snapshot.clear()
	_capture_evaluated_work_poles(kind,"work")

func fitting_acquired(tool: RigidBody3D) -> void:
	# Called only after the production acquisition/contact has succeeded.
	if worker.action!="tool_change" or not worker.tool_change_picked_up or tool!=worker.equipped_tool \
		or tool!=worker.work_target or tool.carrier!=worker.tool_anchor: return
	_fitting_epoch={"instance":tool.get_instance_id(),"rid":tool.get_rid(),"job":worker.current_job_id,
		"side":worker.tool_foot_side(),"acquired_serial":worker._pose.evaluation_serial}

func tag_fitting_snapshot(snapshot: Dictionary) -> void:
	if _fitting_epoch.is_empty() or worker.action!="tool_change" or not foot_occupied(): return
	var tool: RigidBody3D=worker.equipped_tool
	if tool.get_instance_id()!=int(_fitting_epoch.instance) or tool.get_rid()!=_fitting_epoch.rid \
		or worker.current_job_id!=str(_fitting_epoch.job) or worker.work_foot_side!=int(_fitting_epoch.side): return
	snapshot.fitting_epoch=_fitting_epoch.duplicate()
	snapshot.fitting_serial=worker._pose.evaluation_serial

func claim_fitting_release(pose: SkeletonModifier3D,_sk: Skeleton3D,snapshot: Dictionary) -> bool:
	# Transfer this exact completed fitting release directly into a validated
	# finite stow route, before ordinary idle would tilt wide stock into its
	# rack. The actual current original body is revalidated; none is restored.
	if _fitting_epoch.is_empty() or phase!="foot" or not worker.action.is_empty() or not foot_occupied(): return false
	var tag: Dictionary=snapshot.get("fitting_epoch",{})
	var tool: RigidBody3D=worker.equipped_tool
	if tag!=_fitting_epoch or tool.get_instance_id()!=int(_fitting_epoch.instance) or tool.get_rid()!=_fitting_epoch.rid \
		or worker.current_job_id!=str(_fitting_epoch.job) or worker.tool_foot_side()!=int(_fitting_epoch.side) \
		or pose.evaluation_serial-int(snapshot.get("fitting_serial",-100))>2: return false
	var future: Vector3=worker.target_position if worker.has_target else Vector3.INF
	if not future.is_finite() and is_instance_valid(worker.coordinator):
		var entry: Dictionary=worker.coordinator.active_jobs.get(worker.current_job_id,{})
		var target: Variant=entry.get("job",{}).get("target")
		if is_instance_valid(target) and target is Node3D: future=target.global_position
	if not future.is_finite() or (future-worker.global_position).slide(Vector3.UP).length()<=1.1: return false
	_sync_root()
	_cache_tool(tool)
	var current:=_toe_for(tool.global_transform)
	if not _frame_clear(current,_root,true): return false
	_request_toss()
	if phase!="prepare": return false
	_capture_evaluated_work_poles("","fitting")
	_fitting_epoch.clear()
	print("CONTRAPTION_BACK_TOOL FITTING_RELEASE_CLAIM tool=",tool.part_id," serial=",pose.evaluation_serial," native=",str(tool.get_rid()))
	return true

func advance(delta: float) -> void:
	_retry = maxf(_retry-delta, 0.0)
	_empty_return_tail=maxf(_empty_return_tail-delta,0.0)
	_ordinary_motion_age+=delta
	if not is_instance_valid(worker) or not worker.is_inside_tree(): return
	var tool: RigidBody3D = worker.equipped_tool
	if _work_pole_active:
		_sync_root()
		_advance_work_poles(delta)
	if not is_instance_valid(tool):
		# A real fitting begins without an equipped item. Its captured entry
		# planes still enter the existing no_tool_fitting validation above.
		if not (_work_pole_active and int(_work_pole_seed.get("instance",-1))==0 and str(_work_pole_seed.get("action",""))=="tool_change"):
			_work_pole_active=false
		phase = "foot"
		_want_stow = false
		holder.visible = false
		if _tool_free_recovery:
			# This owns only the already-empty graphical leg. Native support,
			# falling and the released original body remain authoritative.
			if not worker.on_ground or not worker.is_available():
				_empty_return_active=false
				_empty_return_tail=0.0
				_tool_free_recovery=false
				_cancel_pole_active=false
			elif not _empty_return_active and _empty_return_tail<=0.0 and not _cancel_pole_active:
				_tool_free_recovery=false
				var next:=pending_action if _pending_job==worker.current_job_id else ""
				pending_action=""
				_pending_job=""
				if not next.is_empty(): worker.begin_action.call_deferred(next)
		else:
			pending_action = ""
		return
	_sync_root()
	holder.visible = true
	if not pending_action.is_empty() and _pending_job != worker.current_job_id:
		pending_action = ""
		_pending_job = ""
	if not _restore.is_empty():
		_restore_binding(tool)
		return
	if _tool_id != 0 and (tool.get_instance_id() != _tool_id or tool.get_rid() != _tool_rid):
		reason = "The original tool owner changed"
		phase = "foot"
		pending_action = ""
		return
	if is_instance_valid(tool.carrier) and tool.carrier not in [worker.tool_anchor, back_anchor]:
		# A foreign carrier has already acquired this exact body. Clear only our
		# stale claim; never detach or relocate another actor's actual source.
		_restore_damping(tool)
		if str(tool.get_meta(&"equipped_worker", "")) == worker.worker_id: tool.remove_meta(&"equipped_worker")
		worker.set_equipped_tool(null)
		reason = "The original tool acquired another carrier"
		return
	if not worker.is_available():
		drop("Dropped the same tool while falling")
		return
	if busy():
		_age += delta
		if not worker.on_ground or worker.fear_time > 0.0:
			drop("Lost safe support during back-tool transfer")
			return
		if _age > 10.0:
			drop("Back-tool transfer timed out; recovering original loose tool")
			return
	if phase == "foot":
		if tool.carrier != worker.tool_anchor: return
		_want_stow = worker.has_target and worker.action.is_empty() and (worker.target_position-worker.global_position).slide(Vector3.UP).length() > 1.1
		_stow_wait=_stow_wait+delta if _want_stow else 0.0
		if _stow_wait>6.0:
			drop("No clear bounded back transfer; releasing the original tool")
			return
		if _want_stow and _retry <= 0.0:
			_request_toss()
	elif phase == "flight":
		native_samples += 1
		_observe_catch(delta)
	elif phase == "back":
		_publish_back()

func evaluated(pose: SkeletonModifier3D, sk: Skeleton3D, delta: float) -> void:
	_guard_fitting_return(pose,sk,delta)
	if _empty_return_active or _empty_return_tail>0.0: _recover_empty_leg(pose,sk,delta)
	if not is_instance_valid(worker.equipped_tool):
		if _cancel_pole_active: _capture_cancelled_planes(pose,sk)
		return
	if phase == "back":
		_sync_root(sk.global_transform*sk.get_bone_global_pose(0))
		_publish_back()
		# Ordinary IK has now completed this same evaluated torso and leg.
		# Capture and admit from that rig, then take its first finite step here;
		# the worker tick must not claim an older published walking endpoint.
		if not pending_action.is_empty(): _request_retrieval(sk)
		if phase == "back": return
	if phase not in ["prepare", "retrieve", "return"]: return
	if phase == "prepare" and _path_index >= _waypoints.size(): return
	var side := _foot_side
	var chain: Array = pose._chains[side]
	var toe_index: int = pose._toes[side]
	var root := sk.global_transform*sk.get_bone_global_pose(0)
	_root = root
	_sync_root(root)
	if phase == "prepare" and _stow_local_waypoints.size() == _waypoints.size():
		# This passage belongs to the moving body. Retarget desired frames only;
		# the actual world toe still advances through the same finite guards.
		for i in range(_path_index, _waypoints.size()):
			_waypoints[i] = _body_frame * _stow_local_waypoints[i]
	if phase == "retrieve" and _retrieval_local_waypoints.size() == _waypoints.size():
		# The seated source and hip follow this completed torso together. Keep
		# their admitted rear passage in that frame as ordinary idle settles;
		# the ground lift remains WORLD and the actual toe still takes only a
		# bounded, currently reachable and native-clear step toward each target.
		for i in range(maxi(_path_index,1),_waypoints.size()-1):
			_waypoints[i] = _body_frame * _retrieval_local_waypoints[i]
	if phase == "retrieve": _publish_back()
	var target := _waypoints[_path_index]
	if phase == "retrieve" and _path_index == _waypoints.size()-1:
		var tool: RigidBody3D = worker.equipped_tool
		target = Transform3D(tool.global_basis, tool.global_transform*Vector3(0,-.035-float(tool.definition.size.y)*.45,0))
	var before := _toe
	var wanted := _toe
	var restoring_binding:=phase=="return" and _path_index==_waypoints.size()-1 and _turn(_toe_in_ankle.basis.get_rotation_quaternion(),_home_toe_in_ankle.basis.get_rotation_quaternion())>.0005
	var old_binding:=_toe_in_ankle
	var motion_target := target
	var return_age_after := _return_segment_age
	# The original first empty-foot lift must immediately clear its planted
	# native sphere. Its subsequent already-clear reach can use authored spacing.
	var eased_segment:=not (phase=="retrieve" and _path_index==0)
	if eased_segment and not restoring_binding:
		if _return_segment_phase!=phase or _return_segment_index!=_path_index:
			_return_segment_phase=phase
			_return_segment_index=_path_index
			_return_segment_start=_toe
			_return_segment_age=0.0
			_return_segment_seconds=maxf(_toe.origin.distance_to(target.origin)/TOE_SPEED,
				_turn(_toe.basis.get_rotation_quaternion(),target.basis.get_rotation_quaternion())/TOE_TURN)
		return_age_after=_return_segment_age+delta
		var ramps:=_transfer_segment_ramps()
		var fraction:=_return_segment_fraction(return_age_after,_return_segment_seconds,ramps.x,ramps.y)
		motion_target=Transform3D(Basis(_return_segment_start.basis.get_rotation_quaternion().slerp(target.basis.get_rotation_quaternion(),fraction)),
			_return_segment_start.origin.lerp(target.origin,fraction))
	if restoring_binding:
		var from:=_toe_in_ankle.basis.get_rotation_quaternion().normalized()
		var to:=_home_toe_in_ankle.basis.get_rotation_quaternion().normalized()
		_toe_in_ankle.basis=Basis(from.slerp(to,minf(TOE_TURN*delta/maxf(_turn(from,to),.000001),1.0)))
		# The real authored toe pivot has not changed; only its captured curl
		# differs between an empty walking foot and the former held-tool foot.
		_toe_in_ankle.origin=_home_toe_in_ankle.origin
	else:
		wanted.origin = _toe.origin.move_toward(motion_target.origin,TOE_SPEED*delta)
	var qa := _toe.basis.get_rotation_quaternion().normalized()
	var qb := motion_target.basis.get_rotation_quaternion().normalized()
	var angle := _turn(qa,qb)
	wanted.basis = Basis(qa.slerp(qb,minf(TOE_TURN*delta/maxf(angle,.000001),1.0)))
	var held := foot_occupied()
	var hip: Vector3 = sk.global_transform*sk.get_bone_global_pose(chain[0]).origin
	var reachable:=_toe_reachable(wanted,hip,side)
	var clear:=_frame_clear(wanted,root,true) if held else _empty_toe_clear(wanted,root)
	var refused_step := not reachable or not clear
	if refused_step:
		_toe_in_ankle=old_binding
		if _wait==0.0:
			var ankle: Vector3=wanted.origin-(wanted.basis*_toe_in_ankle.basis.inverse())*_toe_in_ankle.origin
			last_path_failure={"phase":phase,"waypoint":_path_index,"held":held,"reachable":reachable,"clear":clear,"toe":Part.encode_transform(wanted),"target":Part.encode_transform(target),"ankle":Part.encode_vector(ankle),"hip":Part.encode_vector(hip),"span":worker._leg_span(side),"root":Part.encode_transform(root)}
			if not clear: last_path_failure.native_obstacle=last_native_obstacle.duplicate(true)
			print("CONTRAPTION_BACK_TOOL evaluated_path_refused ",JSON.stringify(last_path_failure))
		_wait += delta
		if _wait > .75:
			drop("Tool path lost clearance; original tool released safely")
			return
		# A refused next step still owns its preceding actual WORLD toe. The
		# shared modifier publishes its completed rig below, so returning an
		# ordinary idle leg here would move the same held tool before release.
		# Retain only a currently reachable, fully clear original pose; otherwise
		# release from the actual attachment before any ordinary publication.
		var current_clear := _frame_clear(_toe,root,true) if held else _empty_toe_clear(_toe,root)
		if not _toe_reachable(_toe,hip,side) or not current_clear:
			drop("The current tool-transfer pose no longer fits; original tool released at its actual pose")
			return
		wanted = _toe
		restoring_binding = false
	else:
		_wait = 0.0
	var local_inv := sk.global_transform.affine_inverse()
	var foot := sk.get_bone_global_pose(chain[2])
	var toe := sk.get_bone_global_pose(toe_index)
	var relative: Basis = _toe_in_ankle.basis
	var offset: Vector3 = _toe_in_ankle.origin
	var foot_basis: Basis = sk.global_basis.inverse()*wanted.basis*relative.inverse()
	var ankle: Vector3 = local_inv*wanted.origin-foot_basis*offset
	# Preserve the actual incoming knee plane, then turn it finitely toward
	# the eye-facing model front. Imported Bone forward is reversed.
	var forward: Vector3=-worker._model.global_basis.z
	var pole_angle:=_knee_plane_world.angle_to(forward)
	_knee_plane_world=_knee_plane_world.slerp(forward,minf(TOE_TURN*delta/maxf(pole_angle,.000001),1.0)).normalized()
	var old_pole: Vector3=pose._travel_poles[side]
	var old_pole_handoff: bool=pose._travel_pole_handoff
	pose._travel_poles[side]=_knee_plane_world
	pose._travel_pole_handoff=true
	pose._solve(sk,chain[0],chain[1],chain[2],ankle,1.0,foot_basis)
	pose._travel_poles[side]=old_pole
	pose._travel_pole_handoff=old_pole_handoff
	toe = sk.get_bone_global_pose(toe_index)
	toe.basis = sk.global_basis.inverse()*wanted.basis
	sk.set_bone_global_pose(toe_index,toe)
	var actual: Transform3D = sk.global_transform*sk.get_bone_global_pose(toe_index)
	if actual.origin.distance_to(wanted.origin) > .002:
		# No force or leg-length increase can make an unreachable ankle valid.
		drop("The back tool is outside finite foot reach")
		return
	_toe = actual
	# Measure the actual tool COM in the capsule frame. A WORLD toe delta
	# already includes native translation and omits the rotating tool offset;
	# adding it to native carrier velocity would count body travel twice.
	var current_worker: Transform3D = worker.global_transform
	var previous_local := _previous_worker.affine_inverse()*_tool_frame(before)
	var current_local := current_worker.affine_inverse()*_tool_frame(_toe)
	_toe_velocity = current_worker.basis*((current_local*_tool_com_local)-(previous_local*_tool_com_local))/maxf(delta,.000001)
	_toe_angular = current_worker.basis*_angular(previous_local.basis,current_local.basis,delta)
	_previous_worker = current_worker
	_previous_toe = before
	max_toe_step = maxf(max_toe_step,before.origin.distance_to(actual.origin))
	max_toe_turn = maxf(max_toe_turn,_turn(before.basis.get_rotation_quaternion(),actual.basis.get_rotation_quaternion())/maxf(delta,.000001))
	pose.evaluated_grounded[side] = false
	pose._target_valid[side] = false
	pose._walk_swing_phase[side] = -1.0
	if held: _publish_foot(actual)
	if refused_step: return
	if eased_segment and not restoring_binding: _return_segment_age=return_age_after
	if restoring_binding: return
	if eased_segment:
		var ramps:=_transfer_segment_ramps()
		var ramp_in:=minf(ramps.x,_return_segment_seconds)
		var ramp_out:=minf(ramps.y,_return_segment_seconds)
		if _return_segment_age<_return_segment_seconds+.5*(ramp_in+ramp_out): return
	var arrived := actual.origin.distance_to(target.origin) < .001 and _turn(actual.basis.get_rotation_quaternion(),target.basis.get_rotation_quaternion()) < .001
	if not arrived: return
	if phase == "retrieve" and _path_index == _waypoints.size()-1:
		_attach_to_foot(actual)
		return
	_path_index += 1
	if _path_index < _waypoints.size(): return
	if phase == "prepare":
		# Release happens only after this actual evaluated toe frame is published.
		_launch.call_deferred()
	else:
		phase = "foot"
		_want_stow = false
		_age = 0.0
		_tool_id = 0
		_reset_foot_handoff(pose)
		var next := pending_action
		pending_action = ""
		if not next.is_empty():
			_capture_work_poles(pose,sk,next)
			worker.begin_action.call_deferred(next)

func _guard_fitting_return(pose: SkeletonModifier3D,sk: Skeleton3D,delta: float) -> void:
	# Guard the proposed ORIGINAL acquired stock before the modifier publishes
	# it. A completion-time claim cannot recover an already unsafe publication.
	if _fitting_epoch.is_empty() or phase!="foot" or worker.action!="tool_change" \
		or not worker.tool_change_picked_up or worker.action_progress<.78: return
	var tool: RigidBody3D=worker.equipped_tool
	if not is_instance_valid(tool) or tool.carrier!=worker.tool_anchor or tool!=worker.work_target \
		or tool.get_instance_id()!=int(_fitting_epoch.instance) or tool.get_rid()!=_fitting_epoch.rid \
		or worker.current_job_id!=str(_fitting_epoch.job) or worker.tool_foot_side()!=int(_fitting_epoch.side): return
	var side: int=int(_fitting_epoch.side)
	var opposite: int=1-side
	var support_rid: RID=pose.native_support_rid(opposite)
	if not pose.evaluated_valid or not worker.on_ground or not worker.is_available() \
		or not pose._target_valid[opposite] or not pose.evaluated_grounded[opposite] or not support_rid.is_valid():
		drop("The matching original fitting stock lost genuine opposite-foot support")
		return
	var support_sole: Vector3=sk.global_transform*(sk.get_bone_global_pose(pose._chains[opposite][2])*Vector3(0,pose._ankle_height[opposite],0))
	if support_sole.distance_to(pose._targets[opposite])>=.10:
		drop("The matching original fitting stock has no settled opposite sole")
		return
	var root: Transform3D=sk.global_transform*sk.get_bone_global_pose(0)
	_sync_root(root)
	_cache_tool(tool)
	var actual:=_toe_for(tool.global_transform)
	var proposed: Transform3D=sk.global_transform*sk.get_bone_global_pose(pose._toes[side])
	# The actually held body is the starting point, never an older clear frame.
	if not _frame_clear(actual,root,true):
		drop("The original fitting stock lost native clearance before return")
		return
	var proposed_clear:=_frame_clear(proposed,root,true)
	var rejected: Dictionary=last_native_obstacle.duplicate(true)
	var gap:=_native_support_gap(_tool_frame(proposed),worker._ground_point,worker.ground_normal)
	if proposed_clear and gap>=.006: return
	var support_only:=true
	if not proposed_clear:
		if rejected.is_empty(): support_only=false
		for hit: Dictionary in rejected.get("hits",[]):
			if str(hit.rid)!=str(support_rid): support_only=false
	var corrected:=proposed
	var lift:=maxf(.006-gap,0.0)
	if support_only and lift<=.045: corrected.origin+=worker.ground_normal*lift
	else: corrected=actual
	# A currently clear previous body may be retained while the real leg takes
	# a bounded step. No fitting clock/contact or Part transform is rewritten.
	var turn:=_turn(actual.basis.get_rotation_quaternion(),corrected.basis.get_rotation_quaternion())
	corrected.basis=Basis(actual.basis.get_rotation_quaternion().slerp(corrected.basis.get_rotation_quaternion(),minf(TOE_TURN*delta/maxf(turn,.000001),1.0)))
	corrected.origin=actual.origin.move_toward(corrected.origin,TOE_SPEED*delta)
	var rebase: Transform3D=worker.global_transform*pose.evaluated_worker.affine_inverse()
	var prior_basis: Basis=rebase.basis*pose.evaluated_ankles[side]
	var prior_ankle: Vector3=rebase*(pose.evaluated_soles[side]-pose.evaluated_ankles[side]*Vector3(0,pose._ankle_height[side],0))
	var binding: Transform3D=Transform3D(prior_basis,prior_ankle).affine_inverse()*actual
	var chain: Array=pose._chains[side]
	var hip: Vector3=sk.global_transform*sk.get_bone_global_pose(chain[0]).origin
	if not _fitting_segment_clear(actual,corrected,binding,hip,side,root): corrected=actual
	if not _fitting_segment_clear(actual,corrected,binding,hip,side,root):
		drop("The original fitting stock has no finite supported return")
		return
	var ankle_basis: Basis=corrected.basis*binding.basis.inverse()
	var ankle: Vector3=corrected.origin-ankle_basis*binding.origin
	var old_axis: Vector3=(prior_ankle-rebase*pose.evaluated_hips[side]).normalized()
	var plane: Vector3=(rebase.basis*(pose.evaluated_knees[side]-pose.evaluated_hips[side])).slide(old_axis)
	if plane.length_squared()<.00001:
		drop("The original fitting stock lost its evaluated finite knee plane")
		return
	plane=_transport_cancel_plane(plane.normalized(),old_axis,(ankle-hip).normalized())
	var saved_pole: Vector3=pose._travel_poles[side]
	var saved_handoff: bool=pose._travel_pole_handoff
	var saved_work: bool=_work_pole_active
	pose._travel_poles[side]=plane
	pose._travel_pole_handoff=true
	_work_pole_active=false
	var incoming_bones: Array[int]=[chain[0],chain[1],chain[2],pose._toes[side]]
	var incoming_poses: Array[Transform3D]=[]
	for bone: int in incoming_bones: incoming_poses.append(sk.get_bone_global_pose(bone))
	pose._solve(sk,chain[0],chain[1],chain[2],sk.global_transform.affine_inverse()*ankle,1.0,sk.global_basis.inverse()*ankle_basis)
	pose._travel_poles[side]=saved_pole
	pose._travel_pole_handoff=saved_handoff
	_work_pole_active=saved_work
	var toe:=sk.get_bone_global_pose(pose._toes[side])
	toe.basis=sk.global_basis.inverse()*corrected.basis
	sk.set_bone_global_pose(pose._toes[side],toe)
	var evaluated: Transform3D=sk.global_transform*sk.get_bone_global_pose(pose._toes[side])
	if evaluated.origin.distance_to(corrected.origin)>.002 or not _frame_clear(evaluated,root,true):
		for index in incoming_bones.size(): sk.set_bone_global_pose(incoming_bones[index],incoming_poses[index])
		drop("The original fitting stock's evaluated return lost clearance")
		return
	pose.evaluated_grounded[side]=false
	pose._target_valid[side]=false
	pose._walk_swing_phase[side]=-1.0
	for bone: int in [chain[0],chain[1]]: pose._gait_rotations[bone]=sk.get_bone_pose_rotation(bone)
	if evaluated.origin.distance_to(actual.origin)<.000001 and _turn(evaluated.basis.get_rotation_quaternion(),actual.basis.get_rotation_quaternion())<.000001:
		fitting_return_retains+=1
	else: fitting_return_corrections+=1
	last_fitting_return={"serial":pose.evaluation_serial,"instance":tool.get_instance_id(),"rid":str(tool.get_rid()),"job":worker.current_job_id,
		"side":side,"actual":Part.encode_transform(actual),"proposed":Part.encode_transform(proposed),"evaluated":Part.encode_transform(evaluated),
		"gap":gap,"lift":lift,"support_only":support_only,"support_rid":str(support_rid),"rejected":rejected}

func _native_support_gap(frame: Transform3D,point: Vector3,normal: Vector3) -> float:
	var gap:=INF
	for index in _native_colliders.size():
		var bounds: AABB=_native_colliders[index].shape.get_debug_mesh().get_aabb()
		var native_frame: Transform3D=frame*_native_local[index]
		for corner in 8: gap=minf(gap,normal.dot(native_frame*bounds.get_endpoint(corner)-point))
	return gap

func _fitting_segment_clear(from: Transform3D,to: Transform3D,binding: Transform3D,hip: Vector3,side: int,root: Transform3D) -> bool:
	var old_binding:=_toe_in_ankle
	_toe_in_ankle=binding
	var count:=maxi(1,ceili(maxf(from.origin.distance_to(to.origin)/.025,_turn(from.basis.get_rotation_quaternion(),to.basis.get_rotation_quaternion())/.05)))
	var clear:=true
	for index in count+1:
		var fraction: float=float(index)/count
		var sample:=Transform3D(Basis(from.basis.get_rotation_quaternion().slerp(to.basis.get_rotation_quaternion(),fraction)),from.origin.lerp(to.origin,fraction))
		var reachable:=_toe_reachable(sample,hip,side)
		var frame_clear:=_frame_clear(sample,root,true) if reachable else false
		if not reachable or not frame_clear:
			if from.origin.is_equal_approx(to.origin) and from.basis.is_equal_approx(to.basis):
				var lease: Dictionary=worker.coordinator.active_jobs.get(worker.current_job_id,{}) if worker.coordinator else {}
				var source: Variant=lease.get("job",{}).get("part")
				print("CONTRAPTION_BACK_TOOL current_return_refused ",JSON.stringify({"tool":worker.equipped_tool.part_id,"tool_rid":str(worker.equipped_tool.get_rid()),"source":source.part_id if is_instance_valid(source) else "none","source_rid":str(source.get_rid()) if is_instance_valid(source) else "none","job":worker.current_job_id,"action":worker.action,"progress":worker.action_progress,"serial":worker._pose.evaluation_serial,"toe":Part.encode_transform(sample),"hip":Part.encode_vector(hip),"root":Part.encode_transform(root),"reachable":reachable,"clear":frame_clear,"native_obstacle":last_native_obstacle.duplicate(true) if reachable else {}}))
			clear=false
			break
	_toe_in_ankle=old_binding
	return clear

func retain_original_foot(pose: SkeletonModifier3D,sk: Skeleton3D,side: int) -> Variant:
	# A failed complete-basis trial cannot publish its unbounded desired roll.
	# Keep the CURRENT original body only when its current full shapes, finite
	# leg reach and opposite native-supported sole still admit that exact pose.
	var tool: RigidBody3D=worker.equipped_tool
	if not is_instance_valid(tool) or tool.carrier!=worker.tool_anchor or not pose.evaluated_valid: return null
	var opposite: int=1-side
	var support: Object=pose._support[opposite].get_ref()
	var support_rid: RID=pose.native_support_rid(opposite)
	if not worker.on_ground or not worker.is_available() or not pose.evaluated_grounded[opposite] \
		or not pose._target_valid[opposite] or not support_rid.is_valid():
		drop("No genuinely supported finite whole-tool return")
		return null
	var support_sole: Vector3=sk.global_transform*(sk.get_bone_global_pose(pose._chains[opposite][2])*Vector3(0,pose._ankle_height[opposite],0))
	if support_sole.distance_to(pose._targets[opposite])>=.10:
		drop("No settled opposite sole for the original whole-tool return")
		return null
	var root: Transform3D=sk.global_transform*sk.get_bone_global_pose(0)
	_sync_root(root)
	_cache_tool(tool)
	var actual:=_toe_for(tool.global_transform)
	var rebase: Transform3D=worker.global_transform*pose.evaluated_worker.affine_inverse()
	var prior_basis: Basis=rebase.basis*pose.evaluated_ankles[side]
	var prior_ankle: Vector3=rebase*(pose.evaluated_soles[side]-pose.evaluated_ankles[side]*Vector3(0,pose._ankle_height[side],0))
	var binding: Transform3D=Transform3D(prior_basis,prior_ankle).affine_inverse()*actual
	var chain: Array=pose._chains[side]
	var hip: Vector3=sk.global_transform*sk.get_bone_global_pose(chain[0]).origin
	if not _fitting_segment_clear(actual,actual,binding,hip,side,root):
		drop("No currently clear finite whole-tool return")
		return null
	var ankle_basis: Basis=actual.basis*binding.basis.inverse()
	var ankle: Vector3=actual.origin-ankle_basis*binding.origin
	var old_axis: Vector3=(prior_ankle-rebase*pose.evaluated_hips[side]).normalized()
	var plane: Vector3=(rebase.basis*(pose.evaluated_knees[side]-pose.evaluated_hips[side])).slide(old_axis)
	if plane.length_squared()<.00001:
		drop("No actual finite whole-tool knee plane")
		return null
	plane=_transport_cancel_plane(plane.normalized(),old_axis,(ankle-hip).normalized())
	var saved_pole: Vector3=pose._travel_poles[side]
	var saved_handoff: bool=pose._travel_pole_handoff
	var saved_work: bool=_work_pole_active
	pose._travel_poles[side]=plane
	pose._travel_pole_handoff=true
	_work_pole_active=false
	var incoming_bones: Array[int]=[chain[0],chain[1],chain[2],pose._toes[side]]
	var incoming_poses: Array[Transform3D]=[]
	for bone: int in incoming_bones: incoming_poses.append(sk.get_bone_global_pose(bone))
	pose._solve(sk,chain[0],chain[1],chain[2],sk.global_transform.affine_inverse()*ankle,1.0,sk.global_basis.inverse()*ankle_basis)
	pose._travel_poles[side]=saved_pole
	pose._travel_pole_handoff=saved_handoff
	_work_pole_active=saved_work
	var toe:=sk.get_bone_global_pose(pose._toes[side])
	toe.basis=sk.global_basis.inverse()*actual.basis
	sk.set_bone_global_pose(pose._toes[side],toe)
	var evaluated: Transform3D=sk.global_transform*sk.get_bone_global_pose(pose._toes[side])
	if evaluated.origin.distance_to(actual.origin)>.002 or not _frame_clear(evaluated,root,true):
		for index in incoming_bones.size(): sk.set_bone_global_pose(incoming_bones[index],incoming_poses[index])
		drop("The actual whole-tool return lost finite clearance")
		return null
	for bone: int in [chain[0],chain[1]]: pose._gait_rotations[bone]=sk.get_bone_pose_rotation(bone)
	pose.evaluated_grounded[side]=false
	pose._target_valid[side]=false
	_supported_return_pending={"serial":pose.evaluation_serial+1,"job":worker.current_job_id,"instance":tool.get_instance_id(),"rid":tool.get_rid(),"opposite":opposite,"support":weakref(support),"support_rid":support_rid}
	worker.tool_pose_blocked=SUPPORTED_RETURN_STATUS
	return evaluated

func _recover_empty_leg(pose: SkeletonModifier3D, sk: Skeleton3D, delta: float) -> void:
	# The actual released leg retains its preceding WORLD sole and ankle.
	# Ordinary free-foot IK may choose a different rest basis: let the real
	# finite chain reach that pose without jumping its ankle-offset endpoint.
	var side:=_foot_side
	var chain: Array=pose._chains[side]
	var foot: Transform3D=sk.global_transform*sk.get_bone_global_pose(chain[2])
	var ordinary_planted: bool=pose.evaluated_grounded[side] and pose._target_valid[side]
	var offset:=Vector3(0,pose._ankle_height[side],0)
	var wanted_sole: Vector3=foot*offset
	var qa:=_empty_ankle.get_rotation_quaternion().normalized()
	var qb:=foot.basis.get_rotation_quaternion().normalized()
	var angle:=_turn(qa,qb)
	var sole_step:=minf(.045,delta*5.4)
	var hip: Vector3=sk.global_transform*sk.get_bone_global_pose(chain[0]).origin
	var span: float=worker._leg_span(side)-.012
	var fraction:=minf(6.0*delta/maxf(angle,.000001),1.0)
	var basis:=_empty_ankle
	var sole:=_empty_sole
	# Turn at the actual current sole first. Lowering a near-extended leg
	# together with that turn can exceed reach and repeatedly veto the same
	# sideways ankle. A reachable rotation may instead spend a little of the
	# existing sole budget; the remaining budget owns translation afterwards.
	for attempt in 9:
		var candidate:=Basis(qa.slerp(qb,fraction))
		var current_ankle:=_empty_sole-candidate*offset
		if hip.distance_to(current_ankle)>span:
			current_ankle=hip+(current_ankle-hip).normalized()*span
		var current_sole:=current_ankle+candidate*offset
		if current_sole.distance_to(_empty_sole)<=sole_step:
			basis=candidate
			sole=current_sole
			break
		fraction*=.5
	var translation_step:=maxf(sole_step-sole.distance_to(_empty_sole),0.0)
	sole=sole.move_toward(wanted_sole,translation_step)
	var ankle:=sole-basis*offset
	if hip.distance_to(ankle)>span:
		ankle=hip+(ankle-hip).normalized()*span
		sole=ankle+basis*offset
	var old_pole: Vector3=pose._travel_poles[side]
	var old_handoff: bool=pose._travel_pole_handoff
	pose._travel_poles[side]=_knee_plane_world
	pose._travel_pole_handoff=true
	pose._solve(sk,chain[0],chain[1],chain[2],sk.global_transform.affine_inverse()*ankle,1.0,sk.global_basis.inverse()*basis)
	pose._travel_poles[side]=old_pole
	pose._travel_pole_handoff=old_handoff
	for bone: int in [chain[0],chain[1]]: pose._gait_rotations[bone]=sk.get_bone_pose_rotation(bone)
	var actual: Transform3D=sk.global_transform*sk.get_bone_global_pose(chain[2])
	var actual_sole: Vector3=actual*offset
	if _empty_sole.distance_to(actual_sole)>.04501:
		print("CONTRAPTION_BACK_TOOL EMPTY_RETURN_STEP before=",_empty_sole," after=",actual_sole," wanted=",wanted_sole," hip=",hip," worker=",worker.global_position," span=",span," basis=",basis," oldbasis=",_empty_ankle," phase=",phase)
	empty_sole_step=maxf(empty_sole_step,_empty_sole.distance_to(actual_sole))
	empty_ankle_turn=maxf(empty_ankle_turn,_turn(_empty_ankle.get_rotation_quaternion(),actual.basis.get_rotation_quaternion())/maxf(delta,.000001))
	_empty_sole=actual_sole
	_empty_ankle=actual.basis
	if _empty_return_active:
		pose._target_valid[side]=false
		pose._walk_swing_phase[side]=-1.0
		pose.evaluated_grounded[side]=false
	elif actual_sole.distance_to(wanted_sole)>.01:
		pose.evaluated_grounded[side]=false
	if _empty_return_active and actual_sole.distance_to(wanted_sole)<.002 and _turn(actual.basis.get_rotation_quaternion(),qb)<.002 \
		and ordinary_planted and (not _tool_free_recovery or (worker.action.is_empty() and pose._walking_ik)):
		print("CONTRAPTION_BACK_TOOL EMPTY_RETURN_DONE sole=",actual_sole," ground=",worker._ground_point," normal=",worker.ground_normal," desired=",wanted_sole)
		_empty_return_active=false
		_empty_return_tail=.8
		pose._gait_handoff_velocity[side]=Vector3.ZERO

func _request_toss() -> void:
	if not _safe_entry() or not foot_occupied(): return
	_sync_root()
	var started := Time.get_ticks_usec()
	var tool: RigidBody3D = worker.equipped_tool
	_tool_id = tool.get_instance_id()
	_tool_rid = tool.get_rid()
	_cache_tool(tool)
	_foot_side = worker.tool_foot_side()
	_side_sign = -1.0 if (_body_frame.affine_inverse()*worker.evaluated_hip(_foot_side)).x < 0.0 else 1.0
	# The native follower may have advanced after the last modifier sample.
	# Start from the exact original fitted Part frame, whose identity grip
	# binding publishes this same toe, rather than yesterday's WORLD cache.
	_toe = _toe_for(tool.global_transform)
	_home_toe_body = _body_frame.affine_inverse()*_toe
	_previous_toe = _toe
	_previous_worker = worker.global_transform
	_capture_toe_binding()
	_home_toe_in_ankle=_toe_in_ankle
	if not _frame_clear(_toe,_root,true) and _only_observed_support_contact():
		# The ordinary controller uses exact visual slices while an attached
		# stock BoxShape can still touch its support with an empty corner. Use
		# its existing bounded 45 mm leg lift; do not waive native clearance.
		worker._pose._held_lift_time=.35
		_retry=.04
		_tool_id=0
		reason="Raising the original tool clear of its observed support"
		return
	var side := _side_sign
	var outward := _axis_basis(_body_frame.basis*Vector3(side,0,0),_body_frame.basis.y)
	var inward := _axis_basis(_body_frame.basis*Vector3(-side,0,0),_body_frame.basis.y)
	var back_axis:=_axis_basis(_body_frame.basis.z,_body_frame.basis.y)
	var rear := _reachable_rear(side,[outward,back_axis,inward])
	if not rear.is_finite():
		reason="The original ankle cannot reach behind the body"
		_retry=3.0
		return
	var root_points: Array[Vector3] = [Vector3(side*.57,-.52,-.38),rear,Vector3(side*.57,-.18,.58)]
	_waypoints.clear()
	_waypoints.append(Transform3D(_toe.basis,_body_frame*root_points[0]))
	_waypoints.append(Transform3D(outward,_body_frame*root_points[0]))
	_waypoints.append(Transform3D(outward,_body_frame*root_points[1]))
	_waypoints.append(Transform3D(back_axis,_body_frame*root_points[1]))
	_waypoints.append(Transform3D(inward,_body_frame*root_points[1]))
	_waypoints.append(Transform3D(inward,_body_frame*root_points[2]))
	_preflight_frame = worker._tool_clearance_frame()
	_preflight_frame.inverse = _root.affine_inverse()
	var clear_path := _path_clear(_toe,_waypoints)
	if not clear_path:
		# An outward horizontal shaft can sweep an installed part or a depot
		# wall. Try the same finite side passage with the original stock upright;
		# turn it rearward before its axial roll, keeping the cutter outside us.
		var upright_route := _upright_stow_route(side,inward,back_axis)
		if not upright_route.is_empty() and _path_clear(_toe,upright_route):
			_waypoints = upright_route
			clear_path = true
	if not clear_path:
		# An installed tyre can obstruct the first low diagonal withdrawal.
		# Raise the original toe toward the existing launch height before its
		# first shaft turn; the complete diagonal remains preflighted unchanged.
		var raised_route := _upright_stow_route(side,inward,back_axis,true)
		if not raised_route.is_empty() and _path_clear(_toe,raised_route):
			_waypoints = raised_route
			clear_path = true
	if not clear_path:
		# The full pickaxe cutter can crowd the cube while the usual front
		# corner turns upright beside stored stock. Move its first turn outside
		# that actual width; the original rear, reach and whole-tool checks
		# still decide whether this longer finite passage is available.
		var width := maxf(.57,.405+float(tool.definition.size.x)*.5+.015)
		var wide_route := _upright_stow_route(side,inward,back_axis,true,width)
		if width>.57 and not wide_route.is_empty() and _path_clear(_toe,wide_route):
			_waypoints = wide_route
			clear_path = true
	if not clear_path:
		# A chassis edge can meet the upright head at the usual rear turn.
		# Turn closer to the body first, then move the inward-pointing shaft
		# to the unchanged launch. The same full-tool/body/reach guards decide.
		var turn_depth := maxf(.48,.405+float(tool.definition.size.z)*.5+.01)
		if turn_depth < .58:
			var near_route := _upright_stow_route(side,inward,back_axis,false,.57,turn_depth)
			if not near_route.is_empty() and _path_clear(_toe,near_route):
				_waypoints = near_route
				clear_path = true
	_preflight_frame = {}
	if not clear_path:
		reason = "No clear finite foot path to the back cradle"
		_retry = 3.0
		_tool_id = 0
		_waypoints.clear()
		validation_usec = Time.get_ticks_usec()-started
		return
	validation_usec = Time.get_ticks_usec()-started
	_stow_local_waypoints.clear()
	var stow_inverse := _body_frame.affine_inverse()
	for waypoint: Transform3D in _waypoints:
		_stow_local_waypoints.append(stow_inverse * waypoint)
	_path_index = 0
	_age = 0.0
	phase = "prepare"
	_return_segment_index=-1
	_stow_wait=0.0
	worker._idle_heading = worker._heading
	worker.status_text = "Tossing tool into back cradle"
	worker.tool_pose_blocked = ""

func _upright_stow_route(side: float,inward: Basis,back_axis: Basis,raised := false,front_width := .57,rear_depth := .58) -> Array[Transform3D]:
	# Tilt the actual shaft upright without changing its axial roll at the
	# front corner. Coupling that tilt to a new cardinal roll makes the
	# shortest quaternion arc swing the complete mallet head into our cube.
	# The existing distinct rear turns own the later roll, with full checks.
	var tilt := Quaternion(_toe.basis.y.normalized(),_body_frame.basis.y.normalized())
	var upright := (Basis(tilt)*_toe.basis).orthonormalized()
	var back_flip := _axis_basis(_body_frame.basis.z,-_body_frame.basis.y)
	var rear := _reachable_rear(side,[upright,back_flip,back_axis,inward],-.18 if raised else -.52,Vector3.INF,rear_depth)
	if not rear.is_finite(): return []
	var front: Vector3 = _body_frame*Vector3(side*front_width,-.18 if raised else -.52,-.38)
	var behind: Vector3 = _body_frame*rear
	# Separate every translation and turn: evaluated() caps their actual
	# speeds independently, so its route must match the preflight segments.
	var points: Array[Transform3D] = [Transform3D(_toe.basis,front),Transform3D(upright,front)]
	points.append_array([Transform3D(upright,behind),Transform3D(back_flip,behind),
		Transform3D(back_axis,behind),Transform3D(inward,behind),
		Transform3D(inward,_body_frame*Vector3(side*.57,-.18,.58))])
	return points

func _request_retrieval(sk: Skeleton3D) -> void:
	if phase != "back" or _empty_return_active or not _safe_entry(true): return
	_sync_root(sk.global_transform*sk.get_bone_global_pose(0))
	var pose: SkeletonModifier3D = worker._pose
	_foot_side = worker.tool_foot_side()
	var hip: Vector3 = sk.global_transform*sk.get_bone_global_pose(pose._chains[_foot_side][0]).origin
	_side_sign = -1.0 if (_body_frame.affine_inverse()*hip).x < 0.0 else 1.0
	_toe = sk.global_transform*sk.get_bone_global_pose(pose._toes[_foot_side])
	_previous_toe = _toe
	_previous_worker = worker.global_transform
	_capture_toe_binding(sk)
	var tool: RigidBody3D = worker.equipped_tool
	var target := Transform3D(tool.global_basis,tool.global_transform*Vector3(0,-.035-float(tool.definition.size.y)*.45,0))
	# The empty foot travels behind its own side; it never crosses the torso.
	var side := _side_sign
	var rear:=_reachable_rear(side,[_toe.basis,target.basis],-.52,hip)
	if not rear.is_finite(): return
	var lift:=_toe
	lift.origin+=worker.ground_normal*maxf(.10-worker.ground_normal.dot(_toe.origin-worker._ground_point),.03)
	_waypoints = [lift,Transform3D(_toe.basis,_body_frame*Vector3(side*.57,-.52,-.38)),Transform3D(target.basis,_body_frame*rear),target]
	# Prefer the original passage. Loose native stock can block its forward
	# corner; withdraw beside the current empty toe before moving rearward.
	# The common ground lift and every actual step retain their live guards.
	var preflight_started: int=Time.get_ticks_usec() if source_budget_enabled else 0
	var native_before: int=_empty_toe_native_query_calls
	var samples_before: int=_empty_retrieval_sample_checks
	var admitted: bool = _empty_retrieval_path_clear(lift,_waypoints,hip)
	if not admitted:
		var start_local: Vector3=_body_frame.affine_inverse()*_toe.origin
		var beside: Vector3=_body_frame*Vector3(side*.57,-.52,start_local.z)
		var alternate: Array[Transform3D]=[lift,Transform3D(_toe.basis,beside),
			Transform3D(_toe.basis,_body_frame*rear),Transform3D(target.basis,_body_frame*rear),target]
		admitted = _empty_retrieval_path_clear(lift,alternate,hip)
		if admitted: _waypoints=alternate
	if source_budget_enabled:
		_record_source_budget("empty_retrieval_candidate_preflight_inclusive",preflight_started)
		var row: Dictionary=source_budget["empty_retrieval_candidate_preflight_inclusive"]
		row.last_native_queries=_empty_toe_native_query_calls-native_before
		row.last_sample_checks=_empty_retrieval_sample_checks-samples_before
		row.total_native_queries=int(row.get("total_native_queries",0))+int(row.last_native_queries)
		row.total_sample_checks=int(row.get("total_sample_checks",0))+int(row.last_sample_checks)
		row.max_native_queries=maxi(int(row.get("max_native_queries",0)),int(row.last_native_queries))
		row.max_sample_checks=maxi(int(row.get("max_sample_checks",0)),int(row.last_sample_checks))
	if not admitted:
		# Keep the exact source on its back binding. The existing coordinator
		# can wait/retry supported access; no refused toe route owns the rig.
		reason = RETRIEVAL_REFUSAL
		worker.tool_pose_blocked = reason
		worker.needs = reason
		return
	if worker.tool_pose_blocked == RETRIEVAL_REFUSAL: worker.tool_pose_blocked = ""
	if worker.needs == RETRIEVAL_REFUSAL: worker.needs = ""
	reason = ""
	_retrieval_local_waypoints.clear()
	var retrieval_inverse := _body_frame.affine_inverse()
	for waypoint: Transform3D in _waypoints:
		_retrieval_local_waypoints.append(retrieval_inverse*waypoint)
	_path_index = 0
	_age = 0.0
	_wait = 0.0
	phase = "retrieve"
	_return_segment_index=-1
	worker._idle_heading = worker._heading
	worker.status_text = "Retrieving the same back tool"

func _empty_retrieval_path_clear(from: Transform3D, points: Array[Transform3D], current_hip := Vector3.INF) -> bool:
	# Empty-foot admission uses the same sphere/torso/native exclusions and
	# actual toe-to-ankle binding and current hip as evaluation, not a held-tool proxy.
	var hip: Vector3=current_hip if current_hip.is_finite() else worker.evaluated_hip(_foot_side)
	for endpoint: Transform3D in points:
		var distance: float=from.origin.distance_to(endpoint.origin)
		var angle: float=_turn(from.basis.get_rotation_quaternion(),endpoint.basis.get_rotation_quaternion())
		var count: int=maxi(1,ceili(maxf(distance/.025,angle/.05)))
		for index: int in count+1:
			var fraction: float=float(index)/count
			var sample: Transform3D=Transform3D(Basis(from.basis.get_rotation_quaternion().slerp(endpoint.basis.get_rotation_quaternion(),fraction)),from.origin.lerp(endpoint.origin,fraction))
			if source_budget_enabled: _empty_retrieval_sample_checks+=1
			if not _toe_reachable(sample,hip,_foot_side) or not _empty_toe_clear(sample,_root): return false
		from=endpoint
	return true

func _attach_to_foot(toe: Transform3D) -> void:
	if not source_budget_enabled:
		_attach_to_foot_observed(toe)
		return
	var started_usec: int=Time.get_ticks_usec()
	var native_before: int=_whole_tool_native_query_calls
	var samples_before: int=_whole_tool_path_sample_checks
	var reuses_before: int=_return_native_sample_reuses
	var stages_before: Array[int]=[]
	if return_preflight_timings_enabled:
		stages_before=[_whole_tool_reach_usec,_whole_tool_posture_usec,_whole_tool_native_usec,_whole_tool_reach_calls,_whole_tool_posture_calls,_whole_tool_sample_math_usec,_whole_tool_frame_clear_usec,_whole_tool_refusal_usec]
	_attach_to_foot_observed(toe)
	_record_whole_tool_query_budget("same_tool_contact_return_preflight_inclusive",started_usec,native_before,samples_before,reuses_before,stages_before)

func _attach_to_foot_observed(toe: Transform3D) -> void:
	var tool: RigidBody3D = worker.equipped_tool
	var exact: Transform3D = tool.global_transform
	var candidate := _tool_frame(toe)
	if candidate.origin.distance_to(exact.origin) > .001 or _turn(candidate.basis.get_rotation_quaternion(),exact.basis.get_rotation_quaternion()) > .001: return
	# Both fixtures are already identical at real evaluated handle contact.
	worker.tool_anchor.global_transform = exact
	tool.set_carried(worker.tool_anchor,Vector3.ZERO)
	retrieval_pose_error = exact.origin.distance_to(tool.global_position)
	retrievals += 1
	phase = "return"
	_return_segment_index=-1
	if retrieval_contact_observation_enabled:
		last_retrieval_contact={"scope":"actual same-native foot contact before held-return preflight",
			"tool_instance":tool.get_instance_id(),"tool_rid":str(tool.get_rid()),"equipped_same":worker.equipped_tool==tool,
			"at_tool_anchor":tool.carrier==worker.tool_anchor,"carrier":str(tool.carrier.get_path()) if tool.carrier is Node else str(tool.carrier),
			"phase":phase,"contacts":retrievals,"retrieval_pose_error":retrieval_pose_error,
			"actual":Part.encode_transform(tool.global_transform),"contact_candidate":Part.encode_transform(candidate),
			"mass":tool.mass,"freeze":tool.freeze,"pending_action":pending_action}
		print("CONTRAPTION_BACK_TOOL RETRIEVAL_CONTACT ",JSON.stringify(last_retrieval_contact))
	var side := _side_sign
	var outward := _axis_basis(_body_frame.basis*Vector3(side,0,0),_body_frame.basis.y)
	var back_axis:=_axis_basis(_body_frame.basis.z,_body_frame.basis.y)
	var rear:=_reachable_rear(side,[toe.basis,back_axis,outward])
	if not rear.is_finite():
		drop("The recovered original tool has no finite return path")
		return
	var home := _body_frame*_home_toe_body
	home=_supported_return_home(home)
	if not home.origin.is_finite():
		drop("The original tool has no clear supported return pose")
		return
	# Only this synchronous read-only route search shares exact native samples.
	# Actual contact/custody is already established; no body or rig is moved
	# until this local context is discarded, before drop or load publication.
	var same_request: Dictionary={}
	if return_preflight_reuse_enabled:
		var exclusions: Array[RID]=worker.query_exclusions()
		exclusions.append(tool.get_rid())
		exclusions.append(holder.get_rid())
		var request_frame: Dictionary=worker._tool_clearance_frame()
		request_frame.inverse=_root.affine_inverse()
		# These observations are immutable within this synchronous route search;
		# each exact toe still receives its own basis, reach and native query.
		same_request={"frame":request_frame,"native_samples":{},
			"tool_id":tool.get_instance_id(),"root":_root,"inverse":request_frame.inverse,"exclusions":exclusions,
			"grip_offset":.035+float(tool.definition.size.y)*.45,
			"space":worker.get_world_3d().direct_space_state}
	_waypoints = [Transform3D(toe.basis,_body_frame*rear),Transform3D(back_axis,_body_frame*rear),Transform3D(outward,_body_frame*rear),Transform3D(outward,_body_frame*Vector3(side*.57,-.52,-.38)),Transform3D(home.basis,_body_frame*Vector3(side*.57,-.52,-.38)),home]
	if not _return_path_clear(toe,_waypoints,same_request):
		# A newly installed body can occupy yesterday's neutral-tool endpoint.
		# Retain the verified exterior staging pose instead; the already queued
		# useful action captures that actual pose for its bounded work entry.
		var exterior:=_supported_return_home(Transform3D(outward,_body_frame*Vector3(side*.57,-.52,-.38)))
		var exterior_clear := false
		if exterior.origin.is_finite():
			_waypoints[4]=exterior
			_waypoints[5]=exterior
			exterior_clear = _return_path_clear(toe,_waypoints,same_request)
		if not exterior_clear and not _upright_return_route(toe,home,back_axis,same_request) and not _raised_upright_return_route(toe,back_axis,same_request):
			_publish_return_path_refusal(same_request)
			same_request.clear()
			drop("The original tool has no finite clear work-entry path")
			return
	same_request.clear()
	_path_index = 0
	_wait = 0.0
	_age = 0.0
	worker.set_cargo(worker.cargo_mass)

func _upright_return_route(toe: Transform3D,home: Transform3D,back_axis: Basis,same_request: Dictionary={}) -> bool:
	var upright := _axis_basis(_body_frame.basis.y,_body_frame.basis.z)
	var back_flip := _axis_basis(_body_frame.basis.z,-_body_frame.basis.y)
	var rear := _reachable_rear(_side_sign,[toe.basis,back_axis,back_flip,upright])
	if not rear.is_finite(): return false
	var front: Vector3 = _body_frame*Vector3(_side_sign*.57,-.52,-.38)
	var behind: Vector3 = _body_frame*rear
	var points: Array[Transform3D] = [Transform3D(toe.basis,behind),
		Transform3D(back_axis,behind),Transform3D(back_flip,behind),
		Transform3D(upright,behind),Transform3D(upright,front),
		Transform3D(home.basis,front),home]
	if not _return_path_clear(toe,points,same_request):
		# If new work occupies the former home, the actual queued foot action
		# can enter from this clear upright front pose through its normal blend.
		var exterior := _supported_return_home(Transform3D(upright,front))
		if not exterior.origin.is_finite(): return false
		points[-2] = exterior
		points[-1] = exterior
		if not _return_path_clear(toe,points,same_request): return false
	_waypoints = points
	return true

func _raised_upright_return_route(toe: Transform3D,back_axis: Basis,same_request: Dictionary={}) -> bool:
	# The low side passage can meet real loose stock after handle contact.
	# Raise the upright original on its clear rear side before moving forward;
	# keep this one exterior work-entry candidate behind all existing routes.
	var upright: Basis=_axis_basis(_body_frame.basis.y,_body_frame.basis.z)
	var back_flip: Basis=_axis_basis(_body_frame.basis.z,-_body_frame.basis.y)
	var rear: Vector3=_reachable_rear(_side_sign,[toe.basis,back_axis,back_flip,upright])
	if not rear.is_finite(): return false
	var behind: Vector3=_body_frame*rear
	var raised: Vector3=_body_frame*Vector3(_side_sign*.57,-.18,rear.z)
	var front: Vector3=_body_frame*Vector3(_side_sign*.57,-.18,-.38)
	var exterior: Transform3D=_supported_return_home(Transform3D(upright,front))
	if not exterior.origin.is_finite(): return false
	# Distinct translation/turn stages follow evaluated()'s independent caps.
	# The duplicate endpoint retains its normal finite final curl recovery.
	var points: Array[Transform3D]=[Transform3D(toe.basis,behind),
		Transform3D(back_axis,behind),Transform3D(back_flip,behind),
		Transform3D(upright,behind),Transform3D(upright,raised),exterior,exterior]
	if not _return_path_clear(toe,points,same_request): return false
	_waypoints=points
	return true

func _return_path_clear(from: Transform3D, points: Array[Transform3D],same_request: Dictionary={}) -> bool:
	# The last lowering happens only after the real foot joint has recovered
	# its original held-tool binding. Preflight that same two-stage operation.
	var leading: Array[Transform3D]=[]
	for index in points.size()-1: leading.append(points[index])
	if not _path_clear(from,leading,same_request): return false
	var saved:=_toe_in_ankle
	var start:=saved.basis.get_rotation_quaternion().normalized()
	var end:=_home_toe_in_ankle.basis.get_rotation_quaternion().normalized()
	var count:=maxi(1,ceili(_turn(start,end)/.04))
	var hip: Vector3=worker.evaluated_hip(_foot_side)
	var clear:=true
	for index in count+1:
		_toe_in_ankle.basis=Basis(start.slerp(end,float(index)/count))
		if not _toe_reachable(points[-2],hip,_foot_side):
			clear=false
			break
	if clear:
		_toe_in_ankle=_home_toe_in_ankle
		var final: Array[Transform3D]=[points[-1]]
		clear=_path_clear(points[-2],final,same_request)
	_toe_in_ankle=saved
	return clear

func _transfer_segment_ramps() -> Vector2:
	# Give the first lift a readable gather and the final contact/home a
	# deliberate settle. Clearance corners are short transitions, not poses
	# that each deserve the old held-return's full 100 ms settling emphasis.
	if _path_index==_waypoints.size()-1:
		if phase=="return": return Vector2(.035,.10)
		if phase=="retrieve": return Vector2(.025,.075)
		return Vector2(.025,.020)
	if _path_index==0: return Vector2(.055,.025)
	return Vector2(.020,.025)

static func _return_segment_fraction(elapsed: float,seconds_at_limit: float,ramp_in_seconds := .10,ramp_out_seconds := .10) -> float:
	# Integrate capped cosine speed ramps along the exact preflighted
	# line/slerp. Translation/turn ceilings and every live guard stay intact;
	# refused actual steps do not advance the accepted segment clock.
	if seconds_at_limit<=.000001: return 1.0
	var ramp_in:=minf(ramp_in_seconds,seconds_at_limit)
	var ramp_out:=minf(ramp_out_seconds,seconds_at_limit)
	var duration:=seconds_at_limit+.5*(ramp_in+ramp_out)
	var age:=clampf(elapsed,0.0,duration)
	if age<ramp_in:
		return (.5*age-ramp_in*sin(PI*age/ramp_in)/(2.0*PI))/seconds_at_limit
	if age<=duration-ramp_out: return (age-.5*ramp_in)/seconds_at_limit
	var tail:=duration-age
	return 1.0-(.5*tail-ramp_out*sin(PI*tail/ramp_out)/(2.0*PI))/seconds_at_limit

func _supported_return_home(home: Transform3D) -> Transform3D:
	# Body sway and a new support can lower yesterday's body-relative toe.
	# Lift only the proposed target, bounded by the existing 45 mm held-tool
	# lift, using every original native shape corner on the real new support.
	var surface: Dictionary=worker._pose._walk_ground(home.origin)
	if surface.is_empty(): return Transform3D(Basis.IDENTITY,Vector3.INF)
	var frame:=_tool_frame(home)
	var gap:=INF
	for index in _native_colliders.size():
		var bounds: AABB=_native_colliders[index].shape.get_debug_mesh().get_aabb()
		var native_frame: Transform3D=frame*_native_local[index]
		for corner in 8:
			gap=minf(gap,Vector3(surface.normal).dot(native_frame*bounds.get_endpoint(corner)-Vector3(surface.position)))
	var lift:=maxf(.006-gap,0.0)
	if lift>.045: return Transform3D(Basis.IDENTITY,Vector3.INF)
	home.origin+=Vector3(surface.normal)*lift
	return home

func _launch() -> void:
	if phase != "prepare" or _path_index < _waypoints.size() or not foot_occupied(): return
	if not worker.on_ground or not worker.is_available() or worker.fear_time > 0.0:
		drop("Lost footing at tool release")
		return
	var tool: RigidBody3D = worker.equipped_tool
	var exact: Transform3D = tool.global_transform
	var destination: Vector3 = _body_frame*Vector3(0,-.18,.58)
	var gravity := float(ProjectSettings.get_setting("physics/3d/default_gravity",9.8))*tool.gravity_scale
	var direct := PhysicsServer3D.body_get_direct_state(worker.get_rid())
	var worker_velocity: Vector3 = direct.linear_velocity if direct else worker.linear_velocity
	var destination_velocity: Vector3 = worker.ground_velocity
	var wanted: Vector3 = (destination+destination_velocity*FLIGHT_SECONDS-exact.origin)/FLIGHT_SECONDS+Vector3.UP*(gravity*FLIGHT_SECONDS*.5)
	launch_impulse = tool.mass*(wanted-worker_velocity)
	if launch_impulse.length() > tool.mass*MAX_KICK_SPEED or not _arc_clear(exact,wanted,gravity,FLIGHT_SECONDS):
		reason = "No clear bounded toss arc behind the Wako"
		phase = "foot"
		_retry = 3.0
		_tool_id = 0
		_reset_foot_handoff(worker._pose)
		return
	var com: Vector3 = exact*_tool_com_local
	var inherited: Vector3 = _point_velocity(worker,com)+_toe_velocity
	var inherited_angular: Vector3 = (direct.angular_velocity if direct else worker.angular_velocity)+_toe_angular
	launch_before_momentum = worker.mass*worker_velocity
	tool.set_carried(null)
	# This is the observed attachment motion at release, not prescribed flight.
	tool.linear_velocity = inherited
	tool.angular_velocity = inherited_angular
	_save_damping(tool)
	tool.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	tool.linear_damp = 0.0
	tool.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	tool.angular_damp = 0.0
	tool.sleeping = false
	worker.set_cargo(worker.cargo_mass)
	tool.apply_central_impulse(tool.mass*(wanted-inherited))
	worker.apply_impulse(-launch_impulse,exact.origin-worker.global_position)
	launch_after_momentum = worker.mass*_velocity(worker)+tool.mass*_velocity(tool)
	phase = "flight"
	_empty_return_active=true
	_empty_sole=worker._pose.evaluated_soles[_foot_side]
	_empty_ankle=worker._pose.evaluated_ankles[_foot_side]
	_age = 0.0
	tosses += 1
	worker.status_text = "Tool airborne toward back cradle"

func _observe_catch(delta: float) -> void:
	var tool: RigidBody3D = worker.equipped_tool
	var velocity: Vector3 = _velocity(tool)
	var relative: Vector3 = velocity-worker.ground_velocity
	if _age < .2 or relative.y >= -.05: return
	last_contact_points.clear()
	var exclusions: Array[RID] = worker.query_exclusions()
	for cradle: Node in worker.get_tree().get_nodes_in_group(&"wako_back_cradles"):
		if cradle != holder and cradle is CollisionObject3D: exclusions.append(cradle.get_rid())
	_contact_query.exclude = exclusions
	_cache_tool(tool)
	for collider: CollisionShape3D in _native_colliders:
		_contact_query.shape = collider.shape
		_contact_query.transform = collider.global_transform
		var points := worker.get_world_3d().direct_space_state.collide_shape(_contact_query,8)
		last_contact_points.append_array(points)
	if not last_contact_points.is_empty():
		var exact: Transform3D = tool.global_transform
		var expected: Transform3D = Transform3D(exact.basis,_body_frame*Vector3(0,-.18,.58))
		var gap: Vector3 = _root.basis.inverse()*(exact.origin-expected.origin)
		# The enabled original native tool shapes must touch the actual tray.
		# Contact may penetrate by at most one real native falling step. Catch
		# preserves that observed pose; it never snaps to this reference frame.
		var step_bound := absf(relative.y)*delta+.5*9.8*delta*delta+.000002
		if absf(gap.x) > .10 or absf(gap.z) > .035 or absf(gap.y) > step_bound+.008 \
			or _velocity(tool).length() > 7.0 or not _frame_clear(_toe_for(exact),_root,false):
			drop("Tool contacted the cradle outside its safe seated pose")
			return
		var worker_velocity := _velocity(worker)
		catch_before_momentum = worker.mass*worker_velocity+tool.mass*velocity
		back_anchor.global_transform = exact
		_back_local = _root.affine_inverse()*exact
		tool.set_carried(back_anchor,Vector3.ZERO)
		_restore_damping(tool)
		worker.set_cargo(worker.cargo_mass)
		worker.apply_impulse(tool.mass*(velocity-worker_velocity),exact.origin-worker.global_position)
		catch_after_momentum = worker.mass*_velocity(worker)
		catch_pose_error = exact.origin.distance_to(tool.global_position)
		phase = "back"
		_want_stow = false
		catches += 1
		_age = 0.0
		_retry = 0.0
		_reset_foot_handoff(worker._pose)
		worker.status_text = "Walking with both feet free"
	elif _age > FLIGHT_SECONDS+.25:
		drop("Back catch missed; recovering the original loose tool")

func drop(explanation: String) -> void:
	var tool: RigidBody3D = worker.equipped_tool
	if not is_instance_valid(tool): return
	# The production coordinator defers original-tool abandonment when a
	# worker leaves the tree. During whole-scene teardown either native body
	# may already have left; no world pose/point velocity exists to query here.
	if not worker.is_inside_tree() or not tool.is_inside_tree(): return
	var carried := is_instance_valid(tool.carrier)
	var ordinary_foot: bool=phase=="foot" and tool.carrier==worker.tool_anchor
	var ordinary_binding: bool=ordinary_foot and not _ordinary_motion.is_empty() \
		and int(_ordinary_motion.instance)==tool.get_instance_id() and _ordinary_motion.rid==tool.get_rid() \
		and _ordinary_motion_age<=maxf(float(_ordinary_motion.delta)*2.0,2.0/120.0)
	var original_motion: bool=ordinary_binding and bool(_ordinary_motion.get("pair_valid",false))
	_ordinary_drop_pending=ordinary_binding
	var exact: Transform3D = tool.global_transform
	print("CONTRAPTION_BACK_TOOL drop ",JSON.stringify({"reason":explanation,"tool":tool.part_id,"tool_rid":str(tool.get_rid()),"job":worker.current_job_id,"action":worker.action,"progress":worker.action_progress,"actual":Part.encode_transform(exact),"native_obstacle":last_native_obstacle.duplicate(true)}))
	var velocity := _velocity(tool)
	var spin: Vector3 = tool.angular_velocity
	var carrier_body: RigidBody3D = worker
	if worker.ragdoll and worker.ragdoll.active: carrier_body = worker.ragdoll.rig.bodies[0].rb
	var carrier_velocity := _velocity(carrier_body)
	if carried:
		var direct := PhysicsServer3D.body_get_direct_state(carrier_body.get_rid())
		_cache_tool(tool)
		velocity = _point_velocity(carrier_body,exact*_tool_com_local)
		spin = direct.angular_velocity if direct else carrier_body.angular_velocity
		if foot_occupied() and pose_owned():
			velocity += _toe_velocity
			spin += _toe_angular
		elif original_motion:
			# Only the preceding actual same-Part publications supply a foot
			# stroke. Old transfer velocities never describe ordinary repair.
			velocity+=worker.global_basis*Vector3(_ordinary_motion.linear)
			spin+=worker.global_basis*Vector3(_ordinary_motion.angular)
	last_drop_motion={"instance":tool.get_instance_id(),"rid":str(tool.get_rid()),"phase":phase,
		"ordinary_foot":ordinary_foot,"measured_ordinary":original_motion,"pose":Part.encode_transform(exact),
		"linear":Part.encode_vector(velocity),"angular":Part.encode_vector(spin),
		"preceding_publication":int(_ordinary_motion.get("serial",-1)) if original_motion else -1}
	tool.set_carried(null)
	if carried:
		tool.linear_velocity = velocity
		tool.angular_velocity = spin
	_restore_damping(tool)
	tool.sleeping = false
	tool.remove_meta(&"equipped_worker")
	worker.set_equipped_tool(null)
	if carried: carrier_body.apply_central_impulse(-tool.mass*(velocity-carrier_velocity))
	if is_instance_valid(worker.coordinator) and is_instance_valid(worker.coordinator.yard): worker.coordinator.yard.add_loose_part(tool)
	phase = "foot"
	_want_stow = false
	pending_action = ""
	_tool_id = 0
	_retry = 3.0
	reason = explanation
	worker.status_text = explanation
	worker.tool_pose_blocked = ""
	_reset_foot_handoff(worker._pose)

func _safe_entry(stowed := false) -> bool:
	if not worker.on_ground or not worker.is_available() or worker.fear_time > 0.0 or worker.paused: return false
	if is_instance_valid(worker.get("equipped_gun")): return false
	var gun_driver: Variant = worker.get("portable_gun")
	if gun_driver and gun_driver.has_method("handoff_active") and gun_driver.call("handoff_active"): return false
	if worker.current_job_id.begins_with("operate:") and is_instance_valid(worker.station) and worker.station.get("kind") == "gun": return false
	if not worker._pose or not worker._pose.evaluated_valid or not worker.foot_grip_valid: return false
	if worker.carrying or is_instance_valid(worker._cargo_source): return false
	if worker.get("head_leap") and worker.head_leap.active(): return false
	if worker.pickup and not worker.pickup.state.is_empty() and worker.pickup.state not in ["caught","failed"]: return false
	if not worker._pose._work_release.is_empty() or worker._pose._travel_tool_handoff or worker._pose._travel_pole_handoff: return false
	if not stowed and not worker.action.is_empty(): return false
	if worker._pose.evaluated_grounded.count(true) < 1: return false
	if (worker.linear_velocity-worker.ground_velocity).length() > .3: return false
	if absf(worker.turn_rate)>.15: return false
	if stowed:
		# Match the existing real tool-fitting capture contract. A WORLD
		# retrieval route must not start while the native carrier still coasts.
		if worker._pose.evaluated_grounded.count(true)!=2 or worker.gait_speed>=.08: return false
		if (worker.linear_velocity-worker.ground_velocity).length()>=.08: return false
		if worker._animation.current_animation!="wk_idle" or worker._animation.current_animation_position<.24: return false
	return true

func _path_clear(from: Transform3D, points: Array[Transform3D],same_request: Dictionary={}) -> bool:
	if not source_budget_enabled: return _path_clear_observed(from,points,same_request)
	var started_usec := Time.get_ticks_usec()
	var native_before: int=_whole_tool_native_query_calls
	var samples_before: int=_whole_tool_path_sample_checks
	var reuses_before: int=_return_native_sample_reuses
	var stages_before: Array[int]=[]
	if return_preflight_timings_enabled:
		stages_before=[_whole_tool_reach_usec,_whole_tool_posture_usec,_whole_tool_native_usec,_whole_tool_reach_calls,_whole_tool_posture_calls,_whole_tool_sample_math_usec,_whole_tool_frame_clear_usec,_whole_tool_refusal_usec]
	var result: bool = _path_clear_observed(from,points,same_request)
	_record_whole_tool_query_budget("whole_tool_path_preflight_inclusive",started_usec,native_before,samples_before,reuses_before,stages_before)
	return result

func _path_clear_observed(from: Transform3D, points: Array[Transform3D],same_request: Dictionary={}) -> bool:
	var side: int = worker.tool_foot_side()
	var hip: Vector3 = worker.evaluated_hip(side)
	last_path_failure.clear()
	if not same_request.is_empty(): same_request.erase("path_refusal")
	var waypoint := 0
	for endpoint: Transform3D in points:
		var distance := from.origin.distance_to(endpoint.origin)
		var from_rotation: Quaternion=from.basis.get_rotation_quaternion()
		var endpoint_rotation: Quaternion=endpoint.basis.get_rotation_quaternion()
		var angle := _turn(from_rotation,endpoint_rotation)
		var count := maxi(1,ceili(maxf(distance/.025,angle/.05)))
		for index in count+1:
			var math_started_usec: int=Time.get_ticks_usec() if return_preflight_timings_enabled else 0
			var fraction := float(index)/count
			var sample := Transform3D(Basis(from_rotation.slerp(endpoint_rotation,fraction)),from.origin.lerp(endpoint.origin,fraction))
			if return_preflight_timings_enabled: _whole_tool_sample_math_usec+=Time.get_ticks_usec()-math_started_usec
			if source_budget_enabled: _whole_tool_path_sample_checks+=1
			var reachable := _toe_reachable(sample,hip,side)
			var frame_started_usec: int=Time.get_ticks_usec() if return_preflight_timings_enabled and reachable else 0
			var clear := _frame_clear(sample,_root,true,same_request) if reachable else false
			if return_preflight_timings_enabled and reachable: _whole_tool_frame_clear_usec+=Time.get_ticks_usec()-frame_started_usec
			if not reachable or not clear:
				var refusal_started_usec: int=Time.get_ticks_usec() if return_preflight_timings_enabled else 0
				var ankle: Vector3=sample.origin-(sample.basis*_toe_in_ankle.basis.inverse())*_toe_in_ankle.origin
				if not same_request.is_empty():
					# Intermediate rejected routes are not a failed retrieval. Preserve
					# exact raw observations until the synchronous request really fails;
					# a later route clears this just as it clears last_path_failure.
					same_request.path_refusal={"waypoint":waypoint,"sample":index,"count":count,"reachable":reachable,"clear":clear,
						"toe":sample,"ankle":ankle,"binding":_toe_in_ankle,"hip":hip,"span":worker._leg_span(side),"root":_root,
						"support_point":worker._ground_point,"support_normal":worker.ground_normal,
						"native_obstacle":last_native_obstacle.duplicate(true)}
				else:
					last_path_failure = {"waypoint":waypoint,"sample":index,"count":count,"reachable":reachable,"clear":clear,"toe":Part.encode_transform(sample),"ankle":Part.encode_vector(ankle),"binding":Part.encode_transform(_toe_in_ankle),"hip":Part.encode_vector(hip),"span":worker._leg_span(side),"root":Part.encode_transform(_root),"posture":worker.held_tool_clearance_debug(sample.origin,sample.basis,worker._ground_point,worker.ground_normal)}
					last_path_failure.native_obstacle=last_native_obstacle.duplicate(true)
					print("CONTRAPTION_BACK_TOOL path_refused ",JSON.stringify(last_path_failure))
				if return_preflight_timings_enabled: _whole_tool_refusal_usec+=Time.get_ticks_usec()-refusal_started_usec
				return false
		from = endpoint
		waypoint += 1
	return true

func _publish_return_path_refusal(same_request: Dictionary) -> void:
	if not same_request.has("path_refusal"): return
	var refusal_started_usec: int=Time.get_ticks_usec() if return_preflight_timings_enabled else 0
	var failure: Dictionary=same_request.path_refusal
	var sample: Transform3D=failure.toe
	# No rig, support or native body changes during this one route search.
	# The final reason keeps the same exact failure pose and fresh posture debug.
	last_path_failure={"waypoint":failure.waypoint,"sample":failure.sample,"count":failure.count,
		"reachable":failure.reachable,"clear":failure.clear,"toe":Part.encode_transform(sample),
		"ankle":Part.encode_vector(failure.ankle),"binding":Part.encode_transform(failure.binding),
		"hip":Part.encode_vector(failure.hip),"span":failure.span,"root":Part.encode_transform(failure.root),
		"posture":worker.held_tool_clearance_debug(sample.origin,sample.basis,failure.support_point,failure.support_normal)}
	last_path_failure.native_obstacle=failure.native_obstacle.duplicate(true)
	print("CONTRAPTION_BACK_TOOL path_refused ",JSON.stringify(last_path_failure))
	if return_preflight_timings_enabled: _whole_tool_refusal_usec+=Time.get_ticks_usec()-refusal_started_usec

func _frame_clear(toe: Transform3D, root: Transform3D, native_obstacles: bool,same_request: Dictionary={}) -> bool:
	last_native_obstacle={}
	var tool: RigidBody3D = worker.equipped_tool
	if not is_instance_valid(tool): return false
	if not same_request.is_empty() and tool.get_instance_id()!=int(same_request.tool_id): same_request.clear()
	var request_support_current: bool=not same_request.is_empty() and _preflight_frame.is_empty()
	var frame: Dictionary = _preflight_frame if not _preflight_frame.is_empty() else (same_request.frame if not same_request.is_empty() else worker._tool_clearance_frame())
	frame.inverse = same_request.inverse if not same_request.is_empty() and same_request.root==root else root.affine_inverse()
	if not request_support_current:
		frame.supported = worker.on_ground
		frame.support_point = worker._ground_point
		frame.support_normal = worker.ground_normal
	frame.basis = toe.basis
	frame.toe_basis = toe.basis
	var world: Transform3D=Transform3D(toe.basis,toe.origin+toe.basis.y*float(same_request.grip_offset)) if native_obstacles and not same_request.is_empty() else Transform3D.IDENTITY
	# Existing entries all passed posture before their original native query.
	# Reuse that predicate only for this exact toe/root in the same read-only
	# search; ankle-binding reach and refusal diagnostics still run live.
	if native_obstacles and not same_request.is_empty() and same_request.native_samples.has(world):
		var cached_sample: Dictionary=same_request.native_samples[world]
		if cached_sample.toe==toe and cached_sample.root==root:
			_query.exclude=same_request.exclusions
			return _reuse_return_native_sample(world,cached_sample)
	var posture_started_usec: int=Time.get_ticks_usec() if return_preflight_timings_enabled else 0
	var posture_clear: bool=worker._tool_posture_clear(toe.origin,toe.basis.y,frame)
	if return_preflight_timings_enabled:
		_whole_tool_posture_usec+=Time.get_ticks_usec()-posture_started_usec
		_whole_tool_posture_calls+=1
	if not posture_clear: return false
	if not native_obstacles: return true
	if same_request.is_empty(): world=_tool_frame(toe)
	var exclusions: Array[RID]=same_request.exclusions if not same_request.is_empty() else worker.query_exclusions()
	if same_request.is_empty():
		exclusions.append(tool.get_rid())
		exclusions.append(holder.get_rid())
	_query.exclude=exclusions
	_cache_tool(tool)
	# A rounded tool-world origin can coincide for different exact toes or
	# roots. Those still execute posture above; the identical native query
	# transform alone can retain its original same-request native result.
	if not same_request.is_empty() and same_request.native_samples.has(world):
		return _reuse_return_native_sample(world,same_request.native_samples[world])
	var obstacles: Array[Dictionary]=[]
	for index in _native_colliders.size():
		var collider: CollisionShape3D = _native_colliders[index]
		_query.shape = collider.shape
		_query.transform = world*_native_local[index]
		_query.motion = Vector3.ZERO
		if source_budget_enabled: _whole_tool_native_query_calls+=1
		var native_started_usec: int=Time.get_ticks_usec() if return_preflight_timings_enabled else 0
		var space: PhysicsDirectSpaceState3D=same_request.space if not same_request.is_empty() else worker.get_world_3d().direct_space_state
		var hits: Array=space.intersect_shape(_query,8)
		if return_preflight_timings_enabled: _whole_tool_native_usec+=Time.get_ticks_usec()-native_started_usec
		if hits.is_empty(): continue
		var bounds: AABB=collider.shape.get_debug_mesh().get_aabb()
		var gap:=INF
		for corner in 8:
			gap=minf(gap,worker.ground_normal.dot(_query.transform*bounds.get_endpoint(corner)-worker._ground_point))
		for hit: Dictionary in hits:
			obstacles.append({"body":str(hit.collider.get_path()),"rid":str(hit.rid),"shape":index,
				"shape_rid":str(collider.shape.get_rid()),"native_bounds_support_gap":gap})
	if not obstacles.is_empty():
		last_native_obstacle=obstacles[0].duplicate()
		last_native_obstacle.tool=Part.encode_transform(world)
		last_native_obstacle.hits=obstacles
		last_native_obstacle.support_point=Part.encode_vector(worker._ground_point)
		last_native_obstacle.support_normal=Part.encode_vector(worker.ground_normal)
	if not same_request.is_empty():
		same_request.native_samples[world]={"toe":toe,"root":root,"obstacle":last_native_obstacle.duplicate(true)}
	return obstacles.is_empty()

func _reuse_return_native_sample(world: Transform3D,cached_sample: Dictionary) -> bool:
	last_native_obstacle=cached_sample.obstacle.duplicate(true)
	# Posture-refused and native-disabled calls never enter this cache. Native
	# setup has already replayed exclusions; a real shape loop also wrote its
	# final shape/transform/motion, while an empty one left those untouched.
	if not _native_colliders.is_empty():
		_query.shape=_native_colliders[-1].shape
		_query.transform=world*_native_local[-1]
		_query.motion=Vector3.ZERO
	if source_budget_enabled: _return_native_sample_reuses+=1
	return last_native_obstacle.is_empty()

func _only_observed_support_contact() -> bool:
	var support: Dictionary=worker.get_world_3d().direct_space_state.intersect_ray(worker._query)
	if support.is_empty(): return false
	var touching:=false
	for index in _native_colliders.size():
		_query.shape=_native_colliders[index].shape
		_query.transform=worker.equipped_tool.global_transform*_native_local[index]
		_query.motion=Vector3.ZERO
		var hits: Array=worker.get_world_3d().direct_space_state.intersect_shape(_query,8)
		for hit: Dictionary in hits:
			if hit.rid!=support.rid: return false
			touching=true
	return touching

func _arc_clear(origin: Transform3D, velocity: Vector3, gravity: float, seconds: float) -> bool:
	var tool: RigidBody3D = worker.equipped_tool
	var count := maxi(1,ceili(seconds*120.0))
	var terrain := worker.get_world_3d().direct_space_state
	_cache_tool(tool)
	var exclusions: Array[RID]=worker.query_exclusions()
	exclusions.append(tool.get_rid())
	exclusions.append(holder.get_rid())
	_query.exclude=exclusions
	var previous := origin
	for index in count+1:
		var time := seconds*float(index)/count
		var sample := Transform3D(origin.basis,origin.origin+velocity*time-Vector3.UP*(gravity*time*time*.5))
		if not _frame_clear(_toe_for(sample),_root,false): return false
		for shape_index in _native_colliders.size():
			var collider: CollisionShape3D = _native_colliders[shape_index]
			_query.shape = collider.shape
			_query.transform = previous*_native_local[shape_index]
			_query.motion = sample.origin-previous.origin
			var motion := terrain.cast_motion(_query)
			if motion.size() != 2 or motion[0] < 1.0: return false
		previous = sample
	return true

func _toe_reachable(toe: Transform3D, hip: Vector3, side: int) -> bool:
	var started_usec: int=Time.get_ticks_usec() if return_preflight_timings_enabled else 0
	var foot_basis: Basis = toe.basis*_toe_in_ankle.basis.inverse()
	var ankle: Vector3 = toe.origin-foot_basis*_toe_in_ankle.origin
	var reachable: bool=ankle.distance_to(hip) <= worker._leg_span(side)-.012
	if return_preflight_timings_enabled:
		_whole_tool_reach_usec+=Time.get_ticks_usec()-started_usec
		_whole_tool_reach_calls+=1
	return reachable

func _reachable_rear(side: float,bases: Array[Basis],lowest_height := -.52,current_hip := Vector3.INF,rear_depth := .58) -> Vector3:
	# Solve the rear height from the actual oriented toe-to-ankle offset and
	# finite imported leg. Keep an extra 15 mm for the real idle rig sway.
	var point:=Vector3(side*.57,lowest_height,rear_depth)
	var hip: Vector3=_body_frame.affine_inverse()*(current_hip if current_hip.is_finite() else worker.evaluated_hip(_foot_side))
	var reach: float=worker._leg_span(_foot_side)-.012-.015
	for segment in maxi(1,bases.size()-1):
		var from:=bases[segment].get_rotation_quaternion().normalized()
		var to:=bases[mini(segment+1,bases.size()-1)].get_rotation_quaternion().normalized()
		var count:=maxi(1,ceili(_turn(from,to)/.04))
		for step in count+1:
			var basis:=Basis(from.slerp(to,float(step)/count))
			var offset: Vector3=_body_frame.basis.inverse()*(basis*_toe_in_ankle.basis.inverse()*_toe_in_ankle.origin)
			var horizontal:=Vector2(point.x-offset.x-hip.x,point.z-offset.z-hip.z).length_squared()
			if horizontal>=reach*reach: return Vector3.INF
			var vertical:=sqrt(reach*reach-horizontal)
			point.y=maxf(point.y,hip.y+offset.y-vertical)
	return point if point.y<=-.18 else Vector3.INF

func _capture_toe_binding(sk: Skeleton3D = null) -> void:
	var pose: SkeletonModifier3D = worker._pose
	var rebase: Transform3D = worker.global_transform*pose.evaluated_worker.affine_inverse()
	var basis: Basis = rebase.basis*pose.evaluated_ankles[_foot_side]
	var origin: Vector3 = rebase*pose.evaluated_soles[_foot_side]-basis*Vector3(0,pose._ankle_height[_foot_side],0)
	var hip: Vector3=rebase*pose.evaluated_hips[_foot_side]
	var knee: Vector3=rebase*pose.evaluated_knees[_foot_side]
	if sk:
		var chain: Array = pose._chains[_foot_side]
		var ankle: Transform3D = sk.global_transform*sk.get_bone_global_pose(chain[2])
		basis = ankle.basis
		origin = ankle.origin
		hip = sk.global_transform*sk.get_bone_global_pose(chain[0]).origin
		knee = sk.global_transform*sk.get_bone_global_pose(chain[1]).origin
	_toe_in_ankle = Transform3D(basis,origin).affine_inverse()*_toe
	_knee_plane_world=(knee-hip).slide((origin-hip).normalized()).normalized()
	if _knee_plane_world.length_squared()<.01: _knee_plane_world=-worker._model.global_basis.z

func _empty_toe_clear(toe: Transform3D,root: Transform3D) -> bool:
	last_native_obstacle={}
	if AABB(Vector3(-.405,-.325,-.405),Vector3(.81,.73,.81)).grow(.07).has_point(root.affine_inverse()*toe.origin): return false
	var exclusions: Array[RID]=worker.query_exclusions()
	exclusions.append(worker.equipped_tool.get_rid())
	exclusions.append(holder.get_rid())
	_query.exclude=exclusions
	_query.shape = _empty_foot_shape
	_query.transform = Transform3D(Basis.IDENTITY,toe.origin)
	_query.motion = Vector3.ZERO
	if source_budget_enabled: _empty_toe_native_query_calls+=1
	var hits: Array=worker.get_world_3d().direct_space_state.intersect_shape(_query,1)
	if not hits.is_empty():
		var hit: Dictionary=hits[0]
		var collider: Object=hit.get("collider")
		last_native_obstacle={"body":str(collider.get_path()) if collider is Node else str(collider),"rid":str(hit.rid),"shape":hit.shape,
			"empty_foot":Part.encode_transform(_query.transform),"radius":_empty_foot_shape.radius}
	return hits.is_empty()

func _tool_frame(toe: Transform3D) -> Transform3D:
	return Transform3D(toe.basis,toe.origin+toe.basis.y*(.035+float(worker.equipped_tool.definition.size.y)*.45))

func _toe_for(tool: Transform3D) -> Transform3D:
	return Transform3D(tool.basis,tool.origin-tool.basis.y*(.035+float(worker.equipped_tool.definition.size.y)*.45))

func _publish_foot(toe: Transform3D) -> void:
	worker.tool_grip_transform = toe
	worker.tool_anchor.global_transform = _tool_frame(toe)
	if foot_occupied(): worker.equipped_tool.global_transform = worker.tool_anchor.global_transform

func foot_published(delta: float) -> void:
	# Observe only the actual completed follower publication. Two same native
	# bodies/COM frames supply the relative foot stroke for a later safe release;
	# this writes no body pose, forces or animation state.
	var tool: RigidBody3D=worker.equipped_tool
	if phase!="foot" or not is_instance_valid(tool) or tool.carrier!=worker.tool_anchor or delta<=0.0:
		_ordinary_motion.clear()
		_ordinary_motion_age=INF
		return
	_cache_tool(tool)
	var local: Transform3D=worker.global_transform.affine_inverse()*tool.global_transform
	var linear:=Vector3.ZERO
	var angular:=Vector3.ZERO
	var pair_valid:=false
	var preceding:=_ordinary_motion
	if not preceding.is_empty() and int(preceding.instance)==tool.get_instance_id() and preceding.rid==tool.get_rid() \
		and _ordinary_motion_age>0.0 and _ordinary_motion_age<=maxf(delta*2.0,2.0/120.0):
		var previous_local: Transform3D=preceding.local
		# Physics advance counts the exact elapsed simulation time, including
		# any skipped publication. A first/same-tick sample has no derivative.
		linear=(local*_tool_com_local-previous_local*_tool_com_local)/_ordinary_motion_age
		angular=_angular(previous_local.basis,local.basis,_ordinary_motion_age)
		pair_valid=true
	_ordinary_motion={"instance":tool.get_instance_id(),"rid":tool.get_rid(),"serial":worker._pose.evaluation_serial,
		"local":local,"linear":linear,"angular":angular,"delta":delta,"pair_valid":pair_valid,
		"elapsed":_ordinary_motion_age if pair_valid else 0.0}
	_ordinary_motion_age=0.0

func _publish_back() -> void:
	if not is_instance_valid(worker.equipped_tool) or worker.equipped_tool.carrier != back_anchor: return
	back_anchor.global_transform = _root*_back_local
	worker.equipped_tool.global_transform = back_anchor.global_transform

func sync_native() -> void:
	if not worker.is_available(): return
	_sync_root()
	if phase == "back" or phase == "retrieve": _publish_back()

func _sync_root(evaluated := Transform3D.IDENTITY) -> void:
	if evaluated != Transform3D.IDENTITY:
		_root = evaluated
	elif worker.ragdoll and (worker.ragdoll.active or (worker.ragdoll.pending and not worker.ragdoll._restore.is_empty())) and not worker.ragdoll._current.is_empty():
		_root = worker.ragdoll._current[0]*worker.ragdoll.rig.bodies[0].b2b
	elif worker._pose and worker._pose.evaluated_valid:
		_root = worker.global_transform*worker._pose.evaluated_worker.affine_inverse()*worker._pose.evaluated_root
	else:
		_root = worker._skeleton.global_transform*worker._skeleton.get_bone_global_pose(0)
	# Bone's imported horizontal axes are reversed relative to the eye face.
	# Remove its authored rest rotation before defining back/right coordinates;
	# retain the actual evaluated body pitch, roll and airborne inversion.
	_body_frame = Transform3D((_root.basis*_rest_root_basis.inverse()).orthonormalized(),_root.origin)
	holder.global_transform = _body_frame
	var half_width := float(worker.equipped_tool.definition.size.x)*.5 if is_instance_valid(worker.equipped_tool) else .12
	if half_width != _holder_half_width:
		_holder_half_width = half_width
		for collider: CollisionShape3D in _seat_colliders: collider.position.y = -.18-half_width-.018
		for seat: MeshInstance3D in _seat_models: seat.position.y = -.18-half_width-.005
		for arm: MeshInstance3D in _drop_arms:
			arm.scale.y = half_width-.02
			arm.position.y = (-.22-.20-half_width)*.5
		if _holder_geometry_ready: _holder_geometry_ready = _holder_geometry.rebuild()

func _reset_foot_handoff(pose: SkeletonModifier3D) -> void:
	if not pose: return
	pose._work_release.clear()
	pose._manipulation_snapshot.clear()
	pose._work_origin.clear()
	pose._held_lift = 0.0
	pose._held_shift = Vector3.ZERO
	pose._held_lift_time = 0.0
	pose._walk_swing_phase = [-1.0,-1.0]
	pose._walking_ik = false
	pose._gait_handoff_active = true
	pose._gait_handoff_tail = .24
	pose._travel_tool_handoff = false

func _capture_work_poles(pose: SkeletonModifier3D,sk: Skeleton3D,kind: String) -> void:
	if kind not in FOOT_WORK or not foot_occupied(): return
	var tool: RigidBody3D=worker.equipped_tool
	for side in 2:
		var chain: Array=pose._chains[side]
		var hip: Vector3=sk.global_transform*sk.get_bone_global_pose(chain[0]).origin
		var knee: Vector3=sk.global_transform*sk.get_bone_global_pose(chain[1]).origin
		var ankle: Vector3=sk.global_transform*sk.get_bone_global_pose(chain[2]).origin
		var plane: Vector3=(knee-hip).slide((ankle-hip).normalized())
		_work_poles[side]=plane.normalized() if plane.length_squared()>.00001 else -worker._model.global_basis.z
	_work_pole_seed={"job":worker.current_job_id,"action":kind,"instance":tool.get_instance_id(),"rid":tool.get_rid(),"side":_foot_side,"worker":worker.global_transform,"toe":_toe,"tool":tool.global_transform}
	_work_pole_age=0.0
	_work_pole_mode="work"
	_work_pole_active=true
	print("CONTRAPTION_BACK_TOOL WORK_ENTRY_CAPTURE action=",kind," job=",worker.current_job_id," poles=",_work_poles," tool=",tool.part_id)

func _capture_evaluated_work_poles(kind: String,mode: String) -> void:
	var pose: SkeletonModifier3D=worker._pose
	var tool: RigidBody3D=worker.equipped_tool
	var rebase: Transform3D=worker.global_transform*pose.evaluated_worker.affine_inverse()
	for side in 2:
		var hip: Vector3=rebase*pose.evaluated_hips[side]
		var ankle: Vector3=rebase*(pose.evaluated_soles[side]-pose.evaluated_ankles[side]*Vector3(0,pose._ankle_height[side],0))
		var plane: Vector3=(rebase*pose.evaluated_knees[side]-hip).slide((ankle-hip).normalized())
		_work_poles[side]=plane.normalized() if plane.length_squared()>.00001 else -worker._model.global_basis.z
	_work_pole_seed={"job":worker.current_job_id,"action":kind,"instance":tool.get_instance_id() if is_instance_valid(tool) else 0,
		"rid":tool.get_rid() if is_instance_valid(tool) else RID(),"side":worker.work_foot_side,"serial":pose.evaluation_serial}
	_work_pole_age=0.0
	_work_pole_mode=mode
	_work_pole_active=true

func _advance_work_poles(delta: float) -> void:
	if not _work_pole_active: return
	var tool: RigidBody3D=worker.equipped_tool
	var no_tool_fitting: bool=not is_instance_valid(tool) and int(_work_pole_seed.instance)==0 and str(_work_pole_seed.action)=="tool_change"
	var same_tool: bool=is_instance_valid(tool) and tool.get_instance_id()==int(_work_pole_seed.instance) and tool.get_rid()==_work_pole_seed.rid
	if not (same_tool or no_tool_fitting) \
		or worker.current_job_id!=str(_work_pole_seed.job) or not worker.is_available() or not worker.on_ground or worker.fear_time>0.0:
		_work_pole_active=false
		return
	_work_pole_age+=delta
	if worker.action.is_empty() and _work_pole_mode=="work":
		if _work_pole_age>.25: _work_pole_active=false
		return
	if worker.action!=str(_work_pole_seed.action) or worker.work_foot_side!=int(_work_pole_seed.side) \
		or (_work_pole_mode=="fitting" and phase not in ["prepare","flight","back"]):
		_work_pole_active=false
		return
	# Every solve in this tick shares one bounded WORLD bend-plane step.
	# Rotate around the finite leg axis: a nearly opposite raw 3D pole can
	# otherwise cross that axis and flip its projected knee plane at once.
	var wanted: Vector3=(-worker._model.global_basis.z if _work_pole_mode=="fitting" or worker.action in ["inspect","assemble","repair"] else _root.basis*Vector3.FORWARD).normalized()
	var matched:=true
	for side in 2:
		var pose: SkeletonModifier3D=worker._pose
		var ankle: Vector3=pose.evaluated_soles[side]-pose.evaluated_ankles[side]*Vector3(0,pose._ankle_height[side],0)
		var axis: Vector3=(ankle-pose.evaluated_hips[side]).normalized()
		if axis.length_squared()<.5:
			matched=false
			continue
		var previous: Vector3=_work_poles[side].slide(axis)
		var desired: Vector3=wanted.slide(axis)
		if previous.length_squared()<.00001:
			previous=(pose.evaluated_knees[side]-pose.evaluated_hips[side]).slide(axis)
		if previous.length_squared()<.00001:
			matched=false
			continue
		previous=previous.normalized()
		if desired.length_squared()<.00001:
			_work_poles[side]=previous
			matched=false
			continue
		desired=desired.normalized()
		var sine: float=axis.dot(previous.cross(desired))
		var cosine: float=clampf(previous.dot(desired),-1.0,1.0)
		var angle: float=atan2(sine,cosine)
		if absf(sine)<.000001 and cosine<0.0:
			var outward: Vector3=worker._model.global_basis.x*(-1.0 if side==0 else 1.0)
			angle=PI if axis.cross(previous).dot(outward)>=0.0 else -PI
		var step: float=clampf(angle,-delta*6.0,delta*6.0)
		_work_poles[side]=previous.rotated(axis,step).normalized() if absf(angle)>.00001 else desired
		if _work_pole_mode=="fitting" and side==_foot_side: _knee_plane_world=_work_poles[side]
		matched=matched and absf(angle-step)<.00001
	if matched: _work_pole_active=false

func ordinary_work_pole(side: int) -> Variant:
	var owned: bool=phase=="foot" or (_work_pole_mode=="fitting" and phase in ["prepare","flight","back"])
	return _work_poles[side] if _work_pole_active and owned and worker.action==str(_work_pole_seed.action) else null

func begin_evaluation(delta: float) -> void:
	# Each refinement in this modifier evaluation reads the same preceding
	# actually published axes/planes and the same finite angular budget.
	_cancel_pose_delta=maxf(delta,0.0)
	if _cancel_pole_active and (is_instance_valid(worker.equipped_tool) or not worker.on_ground or not worker.is_available()):
		_cancel_pole_active=false

func cancelled_plane_owned() -> bool:
	return _cancel_pole_active

func cancelled_return_pole(side: int,hip: Vector3,target: Vector3) -> Variant:
	if not _cancel_pole_active: return null
	var axis: Vector3=(target-hip).normalized()
	if axis.length_squared()<.5: return _cancel_poles[side]
	var previous:=_transport_cancel_plane(_cancel_poles[side],_cancel_axes[side],axis)
	var desired: Vector3=(-worker._model.global_basis.z).slide(axis)
	if desired.length_squared()<.00001: return previous
	desired=desired.normalized()
	var sine: float=axis.dot(previous.cross(desired))
	var cosine: float=clampf(previous.dot(desired),-1.0,1.0)
	var angle: float=atan2(sine,cosine)
	if absf(sine)<.000001 and cosine<0.0:
		var outward: Vector3=worker._model.global_basis.x*(-1.0 if side==0 else 1.0)
		angle=PI if axis.cross(previous).dot(outward)>=0.0 else -PI
	return previous.rotated(axis,clampf(angle,-_cancel_pose_delta*6.0,_cancel_pose_delta*6.0)).normalized()

func _transport_cancel_plane(plane: Vector3,old_axis: Vector3,axis: Vector3) -> Vector3:
	var cosine: float=clampf(old_axis.dot(axis),-1.0,1.0)
	var transported: Vector3
	if cosine<-.99999:
		# The retained perpendicular plane gives an opposed-axis rotation a
		# deterministic side without inventing a cardinal knee direction.
		transported=plane.rotated(plane.normalized(),PI)
	else:
		transported=Quaternion(old_axis,axis)*plane
	return transported.slide(axis).normalized()

func _capture_cancelled_planes(pose: SkeletonModifier3D,sk: Skeleton3D) -> void:
	var matched:=true
	for side in 2:
		var chain: Array=pose._chains[side]
		var hip: Vector3=sk.global_transform*sk.get_bone_global_pose(chain[0]).origin
		var knee: Vector3=sk.global_transform*sk.get_bone_global_pose(chain[1]).origin
		var ankle: Vector3=sk.global_transform*sk.get_bone_global_pose(chain[2]).origin
		var axis: Vector3=(ankle-hip).normalized()
		if axis.length_squared()<.5:
			matched=false
			continue
		var plane: Vector3=(knee-hip).slide(axis)
		_cancel_poles[side]=plane.normalized() if plane.length_squared()>.00001 else _transport_cancel_plane(_cancel_poles[side],_cancel_axes[side],axis)
		_cancel_axes[side]=axis
		# Cancellation owns the finite analytic bend, so its ordinary joint
		# filter was bypassed. Keep that filter's cache at the actual final pose
		# before acquisition or ordinary supported work takes ownership again.
		for bone: int in [chain[0],chain[1]]: pose._gait_rotations[bone]=sk.get_bone_pose_rotation(bone)
		var desired: Vector3=(-worker._model.global_basis.z).slide(axis)
		matched=matched and desired.length_squared()>.00001 and _cancel_poles[side].angle_to(desired.normalized())<.001
	# Ordinary forward IK takes over only after real finite empty-foot
	# recovery, its existing tail, and both actually converged knee planes.
	if matched and not _empty_return_active and _empty_return_tail<=0.0 and worker.action.is_empty() and pose._walking_ik:
		_cancel_pole_active=false

func _save_damping(tool: RigidBody3D) -> void:
	_saved_linear_damp = tool.linear_damp
	_saved_linear_mode = tool.linear_damp_mode
	_saved_angular_damp = tool.angular_damp
	_saved_angular_mode = tool.angular_damp_mode
	_damping_saved = true

func _restore_damping(tool: RigidBody3D) -> void:
	if not _damping_saved: return
	tool.linear_damp = _saved_linear_damp
	tool.linear_damp_mode = _saved_linear_mode
	tool.angular_damp = _saved_angular_damp
	tool.angular_damp_mode = _saved_angular_mode
	_damping_saved = false

func serialize_state() -> Dictionary:
	var tool: RigidBody3D = worker.equipped_tool
	if not is_instance_valid(tool): return {}
	return {"version":2,"tool":tool.part_id,"phase":phase,"local":Part.encode_transform(_back_local),"home":Part.encode_transform(_home_toe_body),"home_binding":Part.encode_transform(_home_toe_in_ankle),"pending":pending_action,"pending_job":_pending_job,"motion":saved_item_motion(),
		"linear_damp":_saved_linear_damp,"linear_mode":_saved_linear_mode,"angular_damp":_saved_angular_damp,"angular_mode":_saved_angular_mode,"damping_saved":_damping_saved}

func restore_state(data: Dictionary) -> void:
	_restore = data.duplicate(true)

func bind_restored_item(tool: RigidBody3D) -> bool:
	if _restore.is_empty(): return false
	if str(_restore.get("tool","")) != tool.part_id: return false
	if str(_restore.get("phase","foot")) == "foot":
		_restore.clear()
		return false
	worker.set_equipped_tool(tool)
	_restore_binding(tool)
	return true

func _restore_binding(tool: RigidBody3D) -> void:
	if str(_restore.get("tool","")) != tool.part_id:
		_restore.clear()
		return
	var saved_phase := str(_restore.get("phase","foot"))
	_home_toe_body = Part.decode_transform(_restore.get("home",Part.encode_transform(_home_toe_body)))
	_home_toe_in_ankle=Part.decode_transform(_restore.get("home_binding",Part.encode_transform(_home_toe_in_ankle)))
	if saved_phase == "back":
		# Yard restoration has rebuilt this item at its saved world pose. Bind
		# that same untouched body against the newly restored actual rig frame.
		# The ordinary worker save does not restore its AnimationPlayer time;
		# reusing yesterday's evaluated root would jump the source on tick one.
		_sync_root()
		_back_local = _root.affine_inverse()*tool.global_transform
		back_anchor.global_transform = tool.global_transform
		tool.set_carried(back_anchor,Vector3.ZERO)
		phase = "back"
		_pending_job = str(_restore.get("pending_job",""))
		pending_action = str(_restore.get("pending","")) if _pending_job == worker.current_job_id else ""
		_tool_id = tool.get_instance_id()
		_tool_rid = tool.get_rid()
		worker.set_cargo(worker.cargo_mass)
	else:
		# Flight and half-finished retrieval resume as the original loose native
		# body at saved pose/motion. A save never fabricates a successful catch.
		if saved_phase in ["flight","prepare","retrieve","return"]:
			var motion: Dictionary = _restore.get("motion",{})
			tool.set_carried(null)
			tool.linear_velocity = Part.decode_vector(motion.get("velocity",Part.encode_vector(tool.linear_velocity)))
			tool.angular_velocity = Part.decode_vector(motion.get("angular_velocity",Part.encode_vector(tool.angular_velocity)))
			_saved_linear_damp = float(_restore.get("linear_damp",tool.linear_damp))
			_saved_linear_mode = int(_restore.get("linear_mode",tool.linear_damp_mode))
			_saved_angular_damp = float(_restore.get("angular_damp",tool.angular_damp))
			_saved_angular_mode = int(_restore.get("angular_mode",tool.angular_damp_mode))
			_damping_saved = bool(_restore.get("damping_saved",false))
			drop("Interrupted back-tool transfer restored as the same loose tool")
	_restore.clear()

func saved_item_motion() -> Dictionary:
	var tool: RigidBody3D = worker.equipped_tool
	if not is_instance_valid(tool): return {}
	var velocity := _velocity(tool)
	var spin: Vector3 = tool.angular_velocity
	if is_instance_valid(tool.carrier):
		var direct := PhysicsServer3D.body_get_direct_state(worker.get_rid())
		_cache_tool(tool)
		velocity = _point_velocity(worker,tool.global_transform*_tool_com_local)
		spin = direct.angular_velocity if direct else worker.angular_velocity
		if foot_occupied() and busy():
			velocity += _toe_velocity
			spin += _toe_angular
	return {"velocity":Part.encode_vector(velocity),"angular_velocity":Part.encode_vector(spin)}

func restored_binding_pending() -> bool:
	return not _restore.is_empty()

func on_equipped_changed(previous: Node3D, next: Node3D) -> void:
	if previous == next: return
	var fitting_handoff: bool=previous==null and next is RigidBody3D and is_instance_valid(next) \
		and next==worker.work_target and next.get("carrier")==worker.tool_anchor \
		and worker.action=="tool_change" and _tool_free_recovery and _cancel_pole_active \
		and worker.on_ground and worker.is_available() and worker.fear_time<=0.0 \
		and worker._pose and worker._pose.evaluated_valid
	if fitting_handoff:
		# The old released body's empty return ends at actual new-stock contact.
		# Its published knee planes enter fitting finitely instead of reverting
		# to an opposed authored branch when equipment ownership changes.
		_capture_evaluated_work_poles("tool_change","work")
		_work_pole_seed.instance=next.get_instance_id()
		_work_pole_seed.rid=(next as RigidBody3D).get_rid()
	var retain_empty:=_seed_cancelled_empty_return(previous,next)
	_ordinary_motion.clear()
	_ordinary_motion_age=INF
	_ordinary_drop_pending=false
	_fitting_epoch.clear()
	if is_instance_valid(previous) and previous is RigidBody3D: _restore_damping(previous)
	phase = "foot"
	_want_stow = false
	_stow_wait=0.0
	_tool_id = 0
	_waypoints.clear()
	pending_action = ""
	_age = 0.0
	if not retain_empty:
		_empty_return_active=false
		_empty_return_tail=0.0
		_tool_free_recovery=false
		_cancel_pole_active=false
	_work_pole_active=fitting_handoff

func _seed_cancelled_empty_return(previous: Node3D,next: Node3D) -> bool:
	if next!=null or not is_instance_valid(previous) or not previous is RigidBody3D: return false
	var source:=previous as RigidBody3D
	var ordinary: bool=_ordinary_drop_pending and not _ordinary_motion.is_empty() \
		and source.get_instance_id()==int(_ordinary_motion.instance) and source.get_rid()==_ordinary_motion.rid
	if not ordinary and (source.get_instance_id()!=_cached_tool_id or source.get_rid()!=_tool_rid): return false
	if not (ordinary or pose_owned() or _empty_return_active or _empty_return_tail>0.0): return false
	var pose: SkeletonModifier3D=worker._pose
	if not worker.on_ground or not worker.is_available() or not pose or not pose.evaluated_valid: return false
	if ordinary: _foot_side=worker.tool_foot_side()
	var rebase: Transform3D=worker.global_transform*pose.evaluated_worker.affine_inverse() if ordinary else Transform3D.IDENTITY
	# Capture the existing evaluated leg before equipment is cleared. The
	# same dropped Part keeps its native motion; this captures no new body.
	_empty_sole=rebase*pose.evaluated_soles[_foot_side]
	_empty_ankle=rebase.basis*pose.evaluated_ankles[_foot_side]
	var hip: Vector3=rebase*pose.evaluated_hips[_foot_side]
	var ankle: Vector3=_empty_sole-_empty_ankle*Vector3(0,pose._ankle_height[_foot_side],0)
	var plane: Vector3=(rebase*pose.evaluated_knees[_foot_side]-hip).slide((ankle-hip).normalized())
	if plane.length_squared()>.00001: _knee_plane_world=plane.normalized()
	for side in 2:
		var source_hip: Vector3=rebase*pose.evaluated_hips[side]
		var source_ankle: Vector3=rebase*(pose.evaluated_soles[side]-pose.evaluated_ankles[side]*Vector3(0,pose._ankle_height[side],0))
		var axis: Vector3=(source_ankle-source_hip).normalized()
		var source_plane: Vector3=(rebase*pose.evaluated_knees[side]-source_hip).slide(axis)
		if axis.length_squared()<.5 or source_plane.length_squared()<.00001: return false
		_cancel_axes[side]=axis
		_cancel_poles[side]=source_plane.normalized()
	_cancel_pole_active=true
	_empty_return_active=true
	_empty_return_tail=0.0
	_tool_free_recovery=true
	_empty_return_source_id=source.get_instance_id()
	_empty_return_source_rid=source.get_rid()
	return true

func recovering() -> bool:
	return busy() or _empty_return_tail>0.0 or _work_pole_active or _cancel_pole_active

func attached_tools() -> Array[RigidBody3D]:
	var output: Array[RigidBody3D] = []
	var tool: RigidBody3D = worker.equipped_tool
	if is_instance_valid(tool) and tool.carrier == back_anchor: output.append(tool)
	return output

func travel_frame_clear(rebase: Transform3D) -> bool:
	if phase != "back": return false
	var tool: RigidBody3D = worker.equipped_tool
	var transform: Transform3D = rebase*tool.global_transform
	var exclusions: Array[RID]=worker.query_exclusions()
	exclusions.append(tool.get_rid())
	exclusions.append(holder.get_rid())
	_query.exclude=exclusions
	_query.motion = Vector3.ZERO
	_cache_tool(tool)
	for index in _native_colliders.size():
		var collider: CollisionShape3D = _native_colliders[index]
		_query.shape = collider.shape
		_query.transform = transform*_native_local[index]
		if not worker.get_world_3d().direct_space_state.intersect_shape(_query,1).is_empty(): return false
	return true

func local_keepouts() -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	var tool: RigidBody3D = worker.equipped_tool
	if not is_instance_valid(tool) or tool.carrier != back_anchor: return output
	for box: AABB in tool.get_meta(&"worker_tool_keepouts",[]): output.append({"transform":_back_local,"box":box,"body":tool})
	return output

static func _colliders(body: RigidBody3D) -> Array[CollisionShape3D]:
	var output: Array[CollisionShape3D] = []
	for node: Node in body.find_children("*","CollisionShape3D",true,false):
		if node is CollisionShape3D and not node.disabled and node.shape: output.append(node)
	return output

func _cache_tool(tool: RigidBody3D) -> void:
	if _cached_tool_id == tool.get_instance_id(): return
	_cached_tool_id = tool.get_instance_id()
	_native_colliders = _colliders(tool)
	var direct := PhysicsServer3D.body_get_direct_state(tool.get_rid())
	_tool_com_local = direct.center_of_mass_local if direct else tool.center_of_mass
	_native_local.clear()
	var inverse := tool.global_transform.affine_inverse()
	for collider: CollisionShape3D in _native_colliders: _native_local.append(inverse*collider.global_transform)

static func _velocity(body: RigidBody3D) -> Vector3:
	var direct := PhysicsServer3D.body_get_direct_state(body.get_rid())
	return direct.linear_velocity if direct else body.linear_velocity

static func _point_velocity(body: RigidBody3D, point: Vector3) -> Vector3:
	var direct := PhysicsServer3D.body_get_direct_state(body.get_rid())
	return direct.get_velocity_at_local_position(point-body.global_position) if direct else body.linear_velocity+body.angular_velocity.cross(point-body.global_position)

static func _turn(a: Quaternion,b: Quaternion) -> float:
	var relative := a.normalized().inverse()*b.normalized()
	return 2.0*atan2(Vector3(relative.x,relative.y,relative.z).length(),absf(relative.w))

static func _angular(a: Basis,b: Basis,delta: float) -> Vector3:
	var relative := b.get_rotation_quaternion().normalized()*a.get_rotation_quaternion().normalized().inverse()
	if relative.w < 0.0: relative = -relative
	var axis := Vector3(relative.x,relative.y,relative.z)
	return axis.normalized()*(2.0*atan2(axis.length(),relative.w)/maxf(delta,.000001)) if axis.length_squared() > 1e-16 else Vector3.ZERO

static func _axis_basis(axis: Vector3,right: Vector3) -> Basis:
	axis = axis.normalized()
	right = right.slide(axis).normalized()
	return Basis(right,axis,right.cross(axis)).orthonormalized()

func _build_holder() -> void:
	if not _bronze:
		_bronze = StandardMaterial3D.new()
		_bronze.albedo_color = Color("ead4a7")
		PBR.bronze(_bronze)
		_bronze.roughness = .60
		_bronze.metallic = .78
		_bronze.normal_scale = .18
		_stone = StandardMaterial3D.new()
		_stone.albedo_color = Color(.59,.57,.48)
		PBR.stone(_stone)
		HolderVisual.finish_seat(_stone)
		_rubber = StandardMaterial3D.new()
		_rubber.albedo_color = Color("424844")
		PBR.dark(_rubber,true)
	# This permanent 2 kg accessory adds to the original 22 kg character.
	# It is never loose catalogue stock or ammunition/material.
	var body_fitted:=HolderVisual.fit_to_body(worker._skin_mesh,worker._skeleton)
	_box("RootSeat",HolderVisual.SEAT_SIZE,HolderVisual.SEAT_ORIGIN if body_fitted else Vector3(0,-.13,.40),_stone)
	for side: float in [-1.0,1.0]:
		# The original socket's outward face and all native catching geometry
		# stay at their original positions. A solid upper plate tongue and an
		# angled lower-front relief join the cradle while clearing hip swing.
		_box("BronzeSocket",HolderVisual.SOCKET_SIZE if body_fitted else Vector3(.065,.19,.10),Vector3(side*.23,-.13,.36 if body_fitted else .45),_bronze)
		_box("CradleArm",Vector3(.065,.045,.16),Vector3(side*.23,-.22,.54),_bronze)
		_drop_arms.append(_box("DropArm",Vector3(.065,1.0,.065),Vector3(side*.23,-.27,.54),_bronze))
		_seat_models.append(_box("RubberSeat",Vector3(.13,.02,.13),Vector3(side*.23,-.305,.58),_rubber))
		var tray := CollisionShape3D.new()
		tray.name = "SeatedContact"
		var shape := BoxShape3D.new()
		shape.size = Vector3(.13,.025,.16)
		tray.shape = shape
		tray.position = Vector3(side*.23,-.318,.58)
		holder.add_child(tray)
		_seat_colliders.append(tray)
		var screw := MeshInstance3D.new()
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = .018
		cylinder.bottom_radius = .018
		cylinder.height = .01
		cylinder.radial_segments = 6
		screw.mesh = cylinder
		screw.material_override = _bronze
		screw.rotation.x = PI*.5
		screw.position = Vector3(side*.23,-.10,.505)
		holder.add_child(screw)

func _box(title: String,size: Vector3,position: Vector3,material: StandardMaterial3D) -> MeshInstance3D:
	var key := str(size)
	if not _holder_meshes.has(key):
		if title == "RootSeat": _holder_meshes[key] = HolderVisual.seat_mesh()
		elif title == "BronzeSocket" and size == HolderVisual.SOCKET_SIZE: _holder_meshes[key] = HolderVisual.socket_mesh()
		else: _holder_meshes[key] = AncientVisual.beveled_box(size)
	var instance := MeshInstance3D.new()
	instance.name = title
	instance.mesh = _holder_meshes[key]
	instance.material_override = material
	instance.position = position
	holder.add_child(instance)
	return instance

func supported_foot_return_pending() -> bool:
	# Only the latest successful exact-body retention is temporary. A real
	# shape/reach/support failure still follows the ordinary blocker/drop path.
	if _supported_return_pending.is_empty() or not is_instance_valid(worker) or not worker.is_inside_tree(): return false
	if worker.tool_pose_blocked!=SUPPORTED_RETURN_STATUS or not worker.on_ground or not worker.is_available(): return false
	var pose: SkeletonModifier3D=worker._pose
	var tool: RigidBody3D=worker.equipped_tool
	if not pose.evaluated_valid or pose.evaluation_serial!=int(_supported_return_pending.serial) or worker.current_job_id!=str(_supported_return_pending.job): return false
	if not is_instance_valid(tool) or not tool.is_inside_tree() or tool.carrier!=worker.tool_anchor or tool.get_instance_id()!=int(_supported_return_pending.instance) or tool.get_rid()!=_supported_return_pending.rid: return false
	var side: int=int(_supported_return_pending.opposite)
	var support: Object=_supported_return_pending.support.get_ref()
	return phase=="foot" and pose.evaluated_grounded[side] and pose._target_valid[side] and is_instance_valid(support) and pose._support[side].get_ref()==support \
		and pose.native_support_rid(side)==_supported_return_pending.support_rid


func _record_whole_tool_query_budget(label: String,started_usec: int,native_before: int,samples_before: int,reuses_before: int,stages_before: Array[int]=[]) -> void:
	_record_source_budget(label,started_usec)
	var row: Dictionary=source_budget[label]
	var counts: Dictionary={"native_queries":_whole_tool_native_query_calls-native_before,
		"sample_checks":_whole_tool_path_sample_checks-samples_before,
		"exact_sample_reuses":_return_native_sample_reuses-reuses_before}
	# Nested scope rows must not be added. frame_clear_usec also contains its
	# posture/native sub-timings; timer overhead remains in parent durations.
	if stages_before.size()>=5:
		counts.reach_usec=_whole_tool_reach_usec-stages_before[0]
		counts.posture_usec=_whole_tool_posture_usec-stages_before[1]
		counts.native_usec=_whole_tool_native_usec-stages_before[2]
		counts.reach_calls=_whole_tool_reach_calls-stages_before[3]
		counts.posture_calls=_whole_tool_posture_calls-stages_before[4]
	if stages_before.size()==8:
		counts.sample_math_usec=_whole_tool_sample_math_usec-stages_before[5]
		counts.frame_clear_usec=_whole_tool_frame_clear_usec-stages_before[6]
		counts.refusal_usec=_whole_tool_refusal_usec-stages_before[7]
	for field: String in counts:
		var value: int=int(counts[field])
		row["last_"+field]=value
		row["total_"+field]=int(row.get("total_"+field,0))+value
		row["max_"+field]=maxi(int(row.get("max_"+field,0)),value)

func _record_source_budget(label: String, started_usec: int) -> void:
	var elapsed_usec := Time.get_ticks_usec()-started_usec
	var row: Dictionary = source_budget.get(label,{"calls":0,"total_usec":0,"max_usec":0,"last_usec":0,"last_tick":0,"last_frame":0,"max_tick":0,"max_frame":0})
	row.calls += 1
	row.total_usec += elapsed_usec
	if elapsed_usec > int(row.max_usec):
		row.max_usec = elapsed_usec
		row.max_tick = Engine.get_physics_frames()
		row.max_frame = Engine.get_process_frames()
	row.last_usec = elapsed_usec
	row.last_tick = Engine.get_physics_frames()
	row.last_frame = Engine.get_process_frames()
	source_budget[label] = row

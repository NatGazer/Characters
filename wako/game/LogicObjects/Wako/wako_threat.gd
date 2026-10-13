extends SkeletonModifier3D
## A brisk armless notice/warning phrase over the same perceived live core.
## Original threat perception, finite recovery and native flee own all gameplay.
const PHRASE_SECONDS := .64
const LEAN_RATE := 2.8
const YAW_RATE := 3.2
const DROP_RATE := .75
# Time, away lean, supported gather, look turn. Eyes lead the cube; a second
# quick head dip accents the existing audible warning, then the body settles.
# Timing/spacing, anticipation and overlap: .claude/RESEARCH.md section 10.
const POSES := [
	[.00, 0.0, 0.0, 0.0],
	[.055, -.040, .032, .15],
	[.125, .145, .012, 1.0],
	[.195, .130, .010, 1.0],
	[.265, -.055, .034, .62],
	[.335, .092, .012, .70],
	[.420, .055, .006, .35],
	[.640, 0.0, 0.0, 0.0],
]
var worker: RigidBody3D
var threat: Node3D
var weight := 0.0
var direction := Vector3.ZERO
var notice_focus := 0.0
# Startle beat that precedes the focus: eyes widen first, then narrow.
var notice_widen := 0.0
var observations := 0
var phrases := 0
var _noticed_id := 0
var _notice_serial := 0
var _notice_age := 10.0
var _presented_serial := 0
var _phrase_age := PHRASE_SECONDS
var _lean := Vector3.ZERO
var _drop := 0.0
var _yaw := 0.0
var _turn_side := 1.0
var _escape_amount := 0.0
var _escape_age := 0.0
var _look_back_period := 1.6

func setup(owner: RigidBody3D) -> void:
	worker = owner
	_turn_side = 1.0 if absi(str(worker.worker_id).hash())%2==0 else -1.0
	_look_back_period = 1.35+.1*float(absi(str(worker.worker_id).hash())%6)
	# Existing support/tool IK consumes this authored pose afterward.
	worker._skeleton.add_child(self)
	worker._skeleton.move_child(self,worker._pose.get_index())

static func phrase_pose(seconds: float) -> Vector3:
	var clock := clampf(seconds,0.0,PHRASE_SECONDS)
	for index in range(1,POSES.size()):
		var next: Array = POSES[index]
		if clock>float(next[0]): continue
		var previous: Array = POSES[index-1]
		var t := clampf((clock-float(previous[0]))/(float(next[0])-float(previous[0])),0.0,1.0)
		# Short intervals carry brisk action; finite quintic spacing makes every
		# held pose and the final interruption destination enter without a snap.
		var spacing := t*t*t*(t*(t*6.0-15.0)+10.0)
		return Vector3(float(previous[1]),float(previous[2]),float(previous[3])).lerp(Vector3(float(next[1]),float(next[2]),float(next[3])),spacing)
	return Vector3.ZERO

func _can_present() -> bool:
	if not worker.on_ground or not worker.is_available() or worker.paused or worker.work_action_held: return false
	if not worker.current_job_id.is_empty() or not worker.action.is_empty() or is_instance_valid(worker.station) or is_instance_valid(worker.work_target): return false
	if worker.carrying or is_instance_valid(worker.carry_partner) or is_instance_valid(worker.brace_load) or is_instance_valid(worker.brace_leader): return false
	if worker.head_leap and worker.head_leap.active(): return false
	if worker.pickup and not worker.pickup.state.is_empty(): return false
	if worker.back_tool and (worker.back_tool.pose_owned() or worker.back_tool.recovering()): return false
	if worker.portable_gun and worker.portable_gun.handoff_active(): return false
	var play: RefCounted = worker.idle_play
	if play and (play.physical_recovery_pending() or not play._pair.is_empty() or play.state not in ["","run"]): return false
	if play and is_instance_valid(play._modifier) and play._modifier.applied_weight>.001: return false
	return true

func _taking_cover() -> bool:
	return worker.has_target and worker.target_position.is_finite() and (worker.target_position-worker.global_position).slide(Vector3.UP).length()<.25 and worker.gait_speed<.2

func _process_modification_with_delta(delta: float) -> void:
	if not is_instance_valid(worker): return
	if not worker.on_ground or not worker.is_available():
		weight = 0.0
		direction = Vector3.ZERO
		threat = null
		notice_focus = 0.0
		notice_widen = 0.0
		_lean = Vector3.ZERO
		_drop = 0.0
		_yaw = 0.0
		_escape_amount = 0.0
		_escape_age = 0.0
		return
	# Exactly the existing perceived/heard core is revalidated by its owner.
	# This leaf scans no enemies/geometry and publishes no navigation request.
	var observed: Node3D = worker.personality._actual_threat() if worker.personality else null
	var observed_id := observed.get_instance_id() if is_instance_valid(observed) else 0
	var step := clampf(delta,0.0,.05)
	if observed_id!=_noticed_id:
		_noticed_id = observed_id
		_notice_age = 0.0
		if observed_id!=0: _notice_serial += 1
	_notice_age += step
	# Notice reads as surprise first (eyes widen within ~2 frames, pupils
	# pinpoint), then a focused worried look while the warning plays, then
	# open watching eyes. The ordinary expression clock remains the owner.
	var widen := smoothstep(0.0,.03,_notice_age)*(1.0-smoothstep(.16,.40,_notice_age)) if observed_id!=0 else 0.0
	var focus := smoothstep(.14,.26,_notice_age)*(1.0-smoothstep(.55,.95,_notice_age)) if observed_id!=0 else 0.0
	var was_wide := notice_widen>=.5
	notice_widen = move_toward(notice_widen,widen,step*30.0)
	# The face composes the widen as it peaks (never a quiet-interval late).
	if notice_widen>=.5 and not was_wide:
		var face: RefCounted = worker.get("eyes")
		if face: face.wake()
	notice_focus = move_toward(notice_focus,focus,step*14.0)
	threat = observed
	var admitted := _can_present()
	if admitted and observed_id!=0 and _presented_serial!=_notice_serial and _notice_age<1.5:
		_presented_serial = _notice_serial
		_phrase_age = 0.0
		phrases += 1
	_phrase_age = minf(_phrase_age+step,PHRASE_SECONDS)
	var active_phrase := admitted and observed_id!=0 and _phrase_age<PHRASE_SECONDS
	var shelter := admitted and observed_id!=0 and _taking_cover()
	# A warning should carry into the actual escape, rather than return to
	# casual upright travel mid-flight. Read native motion relative to the
	# real support; no target, force, speed or terrain plant is changed.
	var relative_velocity: Vector3 = (worker.linear_velocity-worker.ground_velocity).slide(worker.ground_normal)
	var away_speed := relative_velocity.dot(direction)
	var escaping: bool = admitted and observed_id!=0 and worker.fear_time>0.0
	var escape_request := smoothstep(.35,2.6,away_speed) if escaping else 0.0
	_escape_amount = move_toward(_escape_amount,escape_request,step*4.5)
	if escape_request>.001: _escape_age += step
	else: _escape_age = 0.0
	var presenting := active_phrase or shelter or _escape_amount>.001
	weight = move_toward(weight,1.0 if presenting else 0.0,step*(14.0 if presenting else 9.0))
	if observed_id!=0:
		var away := (worker.global_position-observed.global_position).slide(Vector3.UP).normalized()
		direction = direction.lerp(away,1.0-exp(-18.0*step))
		if admitted: observations += 1
	# Ordinary useful play pays no complete-tool native queries for an absent
	# danger pose. Acquisition/eye attention still consume the cached core.
	if weight<=0.0 and _lean.length_squared()<1e-12 and _drop<.000001 and absf(_yaw)<.000001:
		_lean = Vector3.ZERO
		_drop = 0.0
		_yaw = 0.0
		if observed_id==0: direction = Vector3.ZERO
		return
	var local: Vector3 = (worker._model.global_basis.inverse()*direction).slide(Vector3.UP)
	var pose := phrase_pose(_phrase_age) if active_phrase else Vector3(.032,.012,0.0) if shelter else Vector3.ZERO
	# The cube follows the paid departure, then briefly watches back, and
	# keeps peeking back on a personal period while the escape lasts. Each
	# glance settles before the running lean; all still pass the existing
	# published-sole reach and complete carried-tool gates below.
	var back_age := _escape_age if _escape_age<_look_back_period else fmod(_escape_age-_look_back_period,_look_back_period)+.06
	var watch_back := smoothstep(.06,.15,back_age)*(1.0-smoothstep(.34,.64,back_age))
	var escape_pose := Vector3(.105,.018,.72*watch_back)*(_escape_amount if escaping else 0.0)
	var escape_blend := smoothstep(.335,PHRASE_SECONDS,_phrase_age) if active_phrase else 1.0
	pose = pose.lerp(escape_pose,escape_blend) if _escape_amount>.001 else pose
	var axis := Vector3.UP.cross(local)
	var desired_lean := axis*pose.x*weight
	var desired_drop := pose.y*weight
	# The head IS the cube. Aim a small readable turn toward the actual enemy;
	# front/back notices receive a tiny individual side accent, never new arms.
	var glance := clampf(atan2(local.x,local.z),-.23,.23) if local.length_squared()>.0001 else 0.0
	if absf(local.x)<.12: glance = .17*_turn_side
	var desired_yaw := glance*pose.z*weight
	# The existing hip span/stride needs room before a side-facing recoil.
	# This gather overlaps the turn and stays below the original danger dip;
	# the same finite drop rate and complete tool gate still own its delivery.
	desired_drop = maxf(desired_drop,desired_lean.length()*.4+absf(desired_yaw)*.1)
	var sk := get_skeleton()
	var root := sk.get_bone_global_pose(0)
	var foot_reach := _finite_reach_frame(sk,step)
	for factor: float in [1.0,.5,.25,0.0]:
		var next_lean := _lean.move_toward(desired_lean*factor,step*LEAN_RATE)
		var next_drop := move_toward(_drop,desired_drop*factor,step*DROP_RATE)
		var next_yaw := move_toward(_yaw,desired_yaw*factor,step*YAW_RATE)
		var proposed := _root_with_cue(root,next_lean,next_drop,next_yaw)
		sk.set_bone_global_pose(0,proposed)
		if _payload_clear(sk,proposed,foot_reach):
			_lean = next_lean
			_drop = next_drop
			_yaw = next_yaw
			break
	# Clearance chooses a destination, never a discontinuous scale of the
	# applied pose. Final original IK retains sole, tool and knee authority.
	sk.set_bone_global_pose(0,_root_with_cue(root,_lean,_drop,_yaw))

func _root_with_cue(root: Transform3D, lean: Vector3, drop: float, yaw: float) -> Transform3D:
	var proposed := root
	var angle := lean.length()
	if angle>.000001: proposed.basis = Basis(lean/angle,angle)*root.basis
	proposed.basis = Basis(Vector3.UP,yaw)*proposed.basis
	proposed.origin.y -= drop
	return proposed

func _finite_reach_frame(sk: Skeleton3D, delta: float) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var support: SkeletonModifier3D = worker._pose
	if not support or not support.evaluated_valid: return result
	# The same WORLD sole clock as ordinary terrain gait, before roles change.
	# Native body travel never drags a planted sole along with the cube.
	# This samples no new contact, changes no plant and spends no extra reach.
	for side in 2:
		var ankle: Vector3 = support.evaluated_soles[side]+worker.ground_velocity*delta-support.evaluated_ankles[side]*Vector3(0,support._ankle_height[side],0)
		var bone: int = support._chains[side][0]
		var hip: Vector3 = sk.global_transform*sk.get_bone_global_pose(bone).origin
		# Native hip travel can already retire yesterday's endpoint. Do not
		# make that original return harder; existing terrain gait owns it.
		result.append({"bone":bone,"ankle":ankle,"limit":maxf(worker._leg_lengths[side]-.012,hip.distance_to(ankle))})
	return result

func _payload_clear(sk: Skeleton3D, root: Transform3D, foot_reach: Array[Dictionary]) -> bool:
	for support: Dictionary in foot_reach:
		var hip: Vector3 = sk.global_transform*sk.get_bone_global_pose(int(support.bone)).origin
		if hip.distance_to(support.ankle)>float(support.limit)+.0005: return false
	if worker.tool_foot_occupied() and worker.foot_grip_valid:
		var held: Transform3D = worker.tool_anchor.global_transform
		var toe := held.origin-held.basis.y*(.035+float(worker.equipped_tool.definition.size.y)*.45)
		var side: int = worker.tool_foot_side()
		if not worker.held_tool_basis_clear(toe,held.basis,worker._pose._terrain_points[side],worker._pose._sole_normals[side]): return false
	if worker.back_tool and worker.back_tool.phase=="back" and is_instance_valid(worker.equipped_tool) and worker.equipped_tool.carrier==worker.back_tool.back_anchor and worker._pose.evaluated_valid:
		var previous: Transform3D = worker.global_transform*worker._pose.evaluated_worker.affine_inverse()*worker._pose.evaluated_root
		if not worker.back_tool.travel_frame_clear(sk.global_transform*root*previous.affine_inverse()): return false
	return true

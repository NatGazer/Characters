extends SkeletonModifier3D
## Named leg chains: stance foot support and ankle/toe manipulation after authored animation.
const LegGeometry = preload("res://Components/Contraptions/shared_leg_geometry.gd")
const MassGeometry = preload("res://Components/Contraptions/rolling_balance.gd")
const Gait = preload("res://LogicObjects/Wako/wako_gait.gd")
# Knee pole splay: knees point at the face and slightly outward.
const POLE_SPLAY := .12
const GAIT_RELEASE_BLEND := .16  # s: another owner's legs blend in from the gait's last joints
const POLE_TURN_RATE := 12.0
# Existing negative phase resets also cancel a missed landing; no saved state.
const WALK_PENDING_LANDING := -2.0

var worker: RigidBody3D
var _chains: Array = []
var _toes: Array[int] = []
var _ankle_height := [.116, .116]
var _lowest_sole := [-1.085, -1.085]
var _targets: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _target_valid := [false, false]
var _support: Array[WeakRef] = []
# Transient exact native bodies: Terrain3D ray owners are not PhysicsBody3D.
var _support_rids: Array[RID] = [RID(), RID()]
var _support_query := PhysicsRayQueryParameters3D.new()
var _support_local: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _sole_normals: Array[Vector3] = [Vector3.UP, Vector3.UP]
var _terrain_points: Array[Vector3] = [Vector3.INF, Vector3.INF]
var _previous_terrain_points: Array[Vector3] = [Vector3.INF, Vector3.INF]
var _terrain_transition_time := [0.0,0.0]
var _plant_weights := [1.0, 1.0]
var _gait_handoff_velocity: Array[Vector3] = [Vector3.ZERO,Vector3.ZERO]
var _gait_handoff_active := false
var _gait_handoff_tail := 0.0
var _interrupted_handoff_side := -1
var _interrupted_previous_target := Vector3.INF
# Evaluated modifier results are kept for motion diagnostics. Skeleton3D may
# restore authored poses after evaluation, so outside queries are not final IK.
var evaluated_soles: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var evaluated_hips: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var evaluated_knees: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var evaluated_ankles: Array[Basis] = [Basis.IDENTITY, Basis.IDENTITY]
var evaluated_grounded := [false, false]
var _preceding_grounded := [false, false]
var evaluated_valid := false
var evaluated_basis := Basis.IDENTITY
var evaluation_serial := 0
var _gait_rotations: Dictionary = {}
var _gait_release_rotations: Dictionary = {}
var _gait_release_age := INF
var _brake_handoff_age := -1.0  # s: an action begun mid-run waits for the gait's braking steps
var _head_gait_continuation := false
var _head_gait_rotations: Dictionary = {}
var _head_gait_settle_time := 0.0
var _sway_offset := 0.0
var _sway_roll := 0.0
var _sway_shift := Vector3.ZERO
var _sway_pitch := 0.0
var _motion_velocity := Vector3.ZERO
var _motion_velocity_valid := false
var _motion_intent := false
var _motion_start_age := 0.0
var evaluated_root := Transform3D.IDENTITY
var evaluated_worker := Transform3D.IDENTITY
var evaluated_unbalanced_root := Transform3D.IDENTITY
var evaluated_unbalanced_com := Vector3.ZERO
var evaluated_visual_com := Vector3.ZERO
var evaluated_balance_support_side := -1
var evaluated_balance_support_point := Vector3.ZERO
var _release_foot: Dictionary = {}
var _work_rotations: Dictionary = {}
var _terrain_query := PhysicsRayQueryParameters3D.new()
var _manipulation_snapshot: Dictionary = {}
var _work_release: Dictionary = {}
var _work_entry: Dictionary = {}
var _work_origin: Dictionary = {}
var _work_return_armed := false
var _work_return_active := false
# Match exactly the six authored inspection/assembly/repair clips. This
# remaps only their visual IK intent; the real action/event clock remains
# unchanged, including the shared .56 contact, support and release owners.
const WORK_TIMING := {
	"assemble": [[0.0,0.0,1.0],[0.025,0.025,1.3870967741935483],[0.12,0.24,1.3870967741935485],[0.22,0.34,0.6000000000000001],[0.36,0.4,0.31578947368421034],[0.48,0.43,0.433333333333333],[0.56,0.56,1.6851851851851858],[0.6,0.63,1.5135135135135145],[0.69,0.75,0.8510638297872342],[0.77,0.8,0.8189655172413791],[0.93,0.99,0.25503355704698016],[1.0,1.0,0.14285714285714307]],
	"inspect": [[0.0,0.0,1.0],[0.03,0.03,1.3548387096774193],[0.13,0.24,1.68],[0.23,0.38,0.875],[0.34,0.45,0.5833333333333335],[0.47,0.52,0.48695652173913057],[0.56,0.56,0.6153846153846153],[0.64,0.64,1.0769230769230769],[0.76,0.78,1.2],[0.93,0.99,0.2560975609756101],[1.0,1.0,0.14285714285714307]],
	"repair": [[0.0,0.0,1.0],[0.025,0.025,1.3636363636363635],[0.13,0.25,1.1111111111111114],[0.25,0.34,0.6923076923076923],[0.39,0.43,0.5624999999999999],[0.49,0.48,0.6956521739130435],[0.56,0.56,1.194029850746269],[0.6,0.61,1.2244897959183678],[0.7,0.73,1.028571428571428],[0.8,0.82,1.0337837837837838],[0.94,0.99,0.2931034482758621],[1.0,1.0,0.16666666666666666]],
}
const WORK_RELEASE_SECONDS := .34
var _step_lifts := [0.0,0.0]
var _step_ahead := [0.0,0.0]
var _step_probe_age := [0.0,0.0]
var _step_side := -1
var _held_lift := 0.0
var _held_lift_time := 0.0
var _held_shift := Vector3.ZERO
var _walk_rest_feet: Array[Basis] = []
var _walk_swing_phase := [-1.0,-1.0]
var _walking_ik := false
# Ordinary locomotion planner (clock, swings, plants, settle steps, acting).
var gait: RefCounted
var _gait_sides := [false, false]
# Deterministic leg twist: rest frame (segment, rest face) per leg bone.
var _rest_bone_basis: Dictionary = {}
var _rest_frame_inv: Dictionary = {}
# Default knee pole per leg (WORLD), advanced once per physics frame.
var _pole_out: Array[Vector3] = [Vector3.INF, Vector3.INF]
var _pole_base: Array[Vector3] = [Vector3.INF, Vector3.INF]
var _pole_frame := [-10, -10]
var _sway_roll_state := 0.0
# One ordinary idle turn step owns a real lifted sole; all work/stunt owners
# retain their original targets. Native support remains the spring/capsule.
var _pivot_side := -1
var _pivot_age := 0.0
var _pivot_duration := .20
var _pivot_start := Vector3.ZERO
var _pivot_start_support: WeakRef
var _pivot_start_local := Vector3.ZERO
var _pivot_support: WeakRef
var _pivot_local := Vector3.ZERO
var _pivot_rid := RID()
var _pivot_return_side := -1
var _pivot_work_side := -1
var _stopped_turn_pose_ready := false
var _travel_pole_handoff := false
var _travel_tool_handoff := false
var _travel_tool_settle_time := 0.0
var _travel_poles: Array[Vector3] = [Vector3.FORWARD,Vector3.FORWARD]
var _head_work_continuation := false
var _head_work_settle := 0.0
var _head_work_feet_match := false
var _head_work_source: WeakRef
var _head_work_target: WeakRef
var _head_work_job := ""
var _head_work_toes: Array[Transform3D] = [Transform3D.IDENTITY,Transform3D.IDENTITY]
var _head_ground_continuation := false
var _head_landing_continuation := false
var _head_joint_rotations: Dictionary = {}
var _head_pose_delta := 0.0
var _head_return_settle := 0.0
var _head_root_matches := false
var _head_soles_match := false
var _head_joints_match := false
var _head_authored_upper: Array[Basis] = [Basis.IDENTITY,Basis.IDENTITY]
var _head_authored_lower: Array[Basis] = [Basis.IDENTITY,Basis.IDENTITY]
var _head_authored_upper_axes: Array[Vector3] = [Vector3.DOWN,Vector3.DOWN]
var _head_authored_lower_axes: Array[Vector3] = [Vector3.DOWN,Vector3.DOWN]

func _ready() -> void:
	_support = [weakref(null), weakref(null)]
	var sk := get_skeleton()
	for names: Array in [["Bone.001", "Bone.003", "Bone.005", "toe.L"], ["Bone.002", "Bone.004", "Bone.006", "toe.R"]]:
		_chains.append([sk.find_bone(names[0]), sk.find_bone(names[1]), sk.find_bone(names[2])])
		_toes.append(sk.find_bone(names[3]))
		_walk_rest_feet.append(sk.get_bone_global_rest(_chains[-1][2]).basis)
		for index in 2:
			var bone: int = _chains[-1][index]
			var child: int = _chains[-1][index+1]
			var rest := sk.get_bone_global_rest(bone)
			_rest_bone_basis[bone] = rest.basis
			_rest_frame_inv[bone] = _leg_frame(sk.get_bone_global_rest(child).origin-rest.origin,Vector3.FORWARD).transposed()
	gait = Gait.new()
	gait.setup(self,sk)

func _process_modification_with_delta(delta: float) -> void:
	if not is_instance_valid(worker):
		return
	_head_pose_delta = maxf(delta,0.0)
	if worker.back_tool: worker.back_tool.begin_evaluation(delta)
	if worker.ragdoll and worker.ragdoll.pending:
		# Let native capture retain the actual last evaluated bones after the
		# cancellation clip seek, rather than evaluating a new work/idle frame.
		evaluated_valid=false
		return
	if worker.ragdoll and worker.ragdoll.active:
		_head_work_continuation = false
		_head_work_settle = 0.0
		_head_ground_continuation = false
		_head_landing_continuation = false
		_head_return_settle = 0.0
		_head_joint_rotations.clear()
		_head_gait_continuation = false
		worker._grounded_heading_handoff = false
		_head_gait_rotations.clear()
		evaluated_valid = false
		_target_valid = [false, false]
		_support_rids = [RID(), RID()]
		_walk_swing_phase = [-1.0,-1.0]
		_walking_ik = false
		_pivot_side = -1
		_pivot_return_side = -1
		_pivot_work_side = -1
		_travel_pole_handoff = false
		_travel_tool_handoff = false
		_travel_tool_settle_time = 0.0
		_gait_rotations.clear()
		_release_foot.clear()
		_manipulation_snapshot.clear()
		_work_release.clear()
		_work_entry.clear()
		_work_origin.clear()
		_work_return_armed = false
		_work_return_active = false
		_held_lift = 0.0
		_held_lift_time = 0.0
		_held_shift = Vector3.ZERO
		_step_lifts = [0.0,0.0]
		_step_ahead = [0.0,0.0]
		_gait_handoff_active = false
		_interrupted_handoff_side = -1
		_interrupted_previous_target = Vector3.INF
		_sway_offset = 0.0
		_sway_roll = 0.0
		_sway_roll_state = 0.0
		_sway_shift = Vector3.ZERO
		_sway_pitch = 0.0
		_motion_velocity_valid = false
		_motion_intent = false
		_motion_start_age = 0.0
		evaluated_balance_support_side = -1
		gait.reset()
		return
	var sk := get_skeleton()
	if sk and worker.head_leap and worker.head_leap.evaluate_airborne(self,sk):
		gait.reset()
		_pivot_side = -1
		_pivot_return_side = -1
		_pivot_work_side = -1
		_head_work_continuation = false
		_head_work_settle = 0.0
		_head_ground_continuation = false
		_head_landing_continuation = false
		_head_return_settle = 0.0
		# The next supported solve starts with these actual WORLD rotations,
		# including the native body turn, rather than the restored idle clip.
		for chain: Array in _chains:
			for bone: int in [chain[0],chain[1]]:
				_head_joint_rotations[bone] = (sk.global_basis*sk.get_bone_global_pose(bone).basis).get_rotation_quaternion().normalized()
		return
	if not sk or not worker.on_ground:
		# Ordinary locomotion that runs off an edge keeps its own flying legs
		# (tuck, then reach for the ground) instead of an authored clip pose.
		var fly: bool = sk != null and _air_allowed() and gait.air(delta)
		_head_work_continuation = false
		_head_work_settle = 0.0
		_head_ground_continuation = false
		_head_landing_continuation = false
		_head_return_settle = 0.0
		_head_joint_rotations.clear()
		_head_gait_continuation = false
		worker._grounded_heading_handoff = false
		_head_gait_rotations.clear()
		evaluated_valid = false
		_target_valid = [false, false]
		_support_rids = [RID(), RID()]
		_walk_swing_phase = [-1.0,-1.0]
		_walking_ik = false
		_pivot_side = -1
		_pivot_return_side = -1
		_pivot_work_side = -1
		_travel_pole_handoff = false
		_travel_tool_handoff = false
		_travel_tool_settle_time = 0.0
		worker.foot_grip_valid = false
		worker.stance_valid = false
		_gait_rotations.clear()
		_manipulation_snapshot.clear()
		_work_release.clear()
		_work_entry.clear()
		_work_origin.clear()
		_work_return_armed = false
		_work_return_active = false
		_held_lift = 0.0
		_held_lift_time = 0.0
		_held_shift = Vector3.ZERO
		_step_lifts = [0.0,0.0]
		_step_ahead = [0.0,0.0]
		_gait_handoff_active = false
		_interrupted_handoff_side = -1
		_interrupted_previous_target = Vector3.INF
		_sway_offset = 0.0
		_sway_roll = 0.0
		_sway_roll_state = 0.0
		_sway_shift = Vector3.ZERO
		_sway_pitch = 0.0
		_motion_velocity_valid = false
		_motion_intent = false
		_motion_start_age = 0.0
		evaluated_balance_support_side = -1
		if fly: _air_legs(sk)
		else: gait.reset()
		if sk and worker.ragdoll: worker.ragdoll.remember_pose()
		return
	# Only this same native-contact Head lease acquires the work handoff.
	# It owns joint/plane continuity, leaving the real toe contact and all
	# existing work/retrieval sole targets in their original controllers.
	var head_entry: Dictionary = worker.coordinator.active_jobs.get(worker.current_job_id,{}) if is_instance_valid(worker.coordinator) else {}
	var head_job: Dictionary = head_entry.get("job",{})
	if worker.head_leap and worker.head_leap.contacted and is_instance_valid(worker.head_leap.part) and worker.head_leap.crew.has(worker) and head_entry.get("staged",false) and head_job.get("head_first_pickup",false) and head_job.get("part")==worker.head_leap.part and is_instance_valid(head_job.get("target")):
		_head_work_source = weakref(worker.head_leap.part)
		_head_work_target = weakref(head_job.target)
		_head_work_job = str(head_job.id)
		_head_work_continuation = true
		_head_work_settle = 0.0
	# A later launch preflight can replace HeadLeap's temporary part/contact
	# fields while this original staged material still awaits the same job.
	# Remember only the custody earned by actual contact, never a planned copy.
	var staged_source: RigidBody3D = _head_work_source.get_ref() if _head_work_source else null
	var staged_target: RigidBody3D = _head_work_target.get_ref() if _head_work_target else null
	var staged_head_live: bool = is_instance_valid(staged_source) and is_instance_valid(staged_target) and staged_source.is_inside_tree() and staged_target.is_inside_tree() \
		and not staged_source.is_queued_for_deletion() and not staged_target.is_queued_for_deletion() and not is_instance_valid(staged_source.assembly) \
		and staged_source.freeze and staged_source.carrier==staged_target and staged_source.get_meta(&"staged_target",null)==staged_target and staged_source.get_meta(&"in_transit",false)
	var same_staged_head: bool = staged_head_live and (head_entry.is_empty() or (str(head_job.get("id",""))==_head_work_job and head_job.get("part")==staged_source and head_job.get("target")==staged_target))
	if same_staged_head:
		_head_work_continuation = true
		_head_work_settle = 0.0
	var head_prepare: bool = worker.head_leap and worker.head_leap.state=="prepare"
	var head_landing: bool = worker.head_leap and worker.head_leap.state=="landing"
	# The same head-held stock enters supported placement/bracing after its
	# landing has already converged to walking. That new clip must retain the
	# last WORLD legs instead of switching back to the imported root pole.
	var supported_head_handover: bool = worker.action in ["place","brace"] and worker.carrying and is_instance_valid(worker._cargo_source) and worker.head_leap and worker.head_leap.contacted and worker.head_leap.part==worker._cargo_source
	# Stage contact clears cargo before its place/brace clip ends. A queued
	# back retrieval can then leave action empty while that old clip remains.
	# Keep the owned WORLD return until actual foot work or gait takes over;
	# interruption releases the same finite grounded legs through this path.
	var ordinary_head_return: bool = worker.action in ["","interrupted","place","brace"]
	if head_prepare:
		_head_ground_continuation = true
		_head_landing_continuation = false
		_head_return_settle = 0.0
		_head_gait_continuation = false
	elif head_landing:
		_head_ground_continuation = true
		_head_landing_continuation = true
		_head_gait_continuation = false
	elif supported_head_handover:
		_head_ground_continuation = true
		_head_landing_continuation = true
		_head_return_settle = 0.0
		_head_gait_continuation = false
	elif _head_landing_continuation and ordinary_head_return:
		_head_ground_continuation = true
	else:
		_head_ground_continuation = false
		_head_landing_continuation = false
		_head_return_settle = 0.0
	var local_inv := sk.global_transform.affine_inverse()
	# Both immediate sole tests share the current scene and exclusions.
	var terrain := worker.get_world_3d().direct_space_state
	_terrain_query.exclude = worker.query_exclusions()
	_terrain_query.collision_mask = 1
	# Validate the matching fitting release against the actual preceding
	# published support before this evaluation clears its output fields.
	var fitting_release_claimed: bool = worker.back_tool and worker.back_tool.claim_fitting_release(self,sk,_manipulation_snapshot)
	_preceding_grounded = evaluated_grounded
	evaluated_grounded = [false, false]
	_previous_terrain_points[0] = _terrain_points[0]
	_previous_terrain_points[1] = _terrain_points[1]
	_terrain_points[0] = Vector3.INF
	_terrain_points[1] = Vector3.INF
	var speed: float = worker.gait_speed
	var manipulation: bool = worker.feet_work_active() and is_instance_valid(worker.work_target)
	_update_work_pole_return(manipulation)
	# Grounded head pickup retains the existing finite
	# walking-to-idle sole handoff through the actual nonsmall pickup clock.
	var supported_head_pickup: bool = worker.action=="pickup" and worker._animation.current_animation.begins_with("head_pickup/") and worker.pickup and worker.pickup.state.is_empty() and not manipulation and worker.on_ground and is_instance_valid(worker.work_target)
	if supported_head_pickup:
		_head_gait_continuation = true
		_head_gait_settle_time = 0.0
	elif not worker.action.is_empty():
		_head_gait_continuation = false
		_head_gait_settle_time = 0.0
		_head_gait_rotations.clear()
	var head_gait_matches: bool = not worker.tool_foot_occupied()
	if manipulation and _manipulation_snapshot.is_empty() and evaluated_valid:
		var side: int = worker.work_foot_side
		var current_from_previous: Transform3D = worker.global_transform*evaluated_worker.affine_inverse()
		_work_entry = {"side":side,"age":0.0,"sole":local_inv*(current_from_previous*evaluated_soles[side]),
			"basis":sk.global_basis.inverse()*current_from_previous.basis*evaluated_ankles[side]}
	elif not manipulation: _work_entry.clear()
	var tossing: bool = worker.pickup and worker.pickup.state == "flight"
	if tossing:
		# The native toss already owns its captured sole follow-through below.
		_manipulation_snapshot.clear()
		_work_release.clear()
	elif not manipulation and not _manipulation_snapshot.is_empty():
		if not fitting_release_claimed:
			_work_release = _manipulation_snapshot.duplicate()
			_work_release.age = 0.0
		_manipulation_snapshot.clear()
	elif manipulation: _work_release.clear()
	if _head_ground_continuation:
		# Head owns both actual WORLD soles below, including its paused launch
		# preparation. An older root-relative work release cannot move them.
		_work_release.clear()
		_manipulation_snapshot.clear()
	var stable_work: bool = worker.stable_tool_work()
	if not stable_work: _work_origin.clear()
	elif _work_origin.is_empty():
		var side: int = worker.work_foot_side
		var root := sk.get_bone_global_pose(0)
		var foot := sk.get_bone_global_pose(_chains[side][2])
		var toe := sk.get_bone_global_pose(_toes[side])
		var toe_offset := foot.basis.inverse()*(toe.origin-foot.origin)
		var toe_relative := foot.basis.inverse()*toe.basis
		if evaluated_valid:
			var current_from_previous: Transform3D = worker.global_transform*evaluated_worker.affine_inverse()
			foot.basis = sk.global_basis.inverse()*current_from_previous.basis*evaluated_ankles[side]
			foot.origin = local_inv*(current_from_previous*evaluated_soles[side])-foot.basis*Vector3(0,_ankle_height[side],0)
			if worker.foot_grip_valid:
				var actual_toe: Transform3D=current_from_previous*worker.tool_grip_transform
				var actual_foot:=Transform3D(sk.global_basis*foot.basis,sk.global_transform*foot.origin)
				toe_offset=actual_foot.affine_inverse()*actual_toe.origin
				toe_relative=actual_foot.basis.inverse()*actual_toe.basis
		_work_origin = {"ankle":root.affine_inverse()*foot.origin,"basis":root.basis.inverse()*foot.basis,"toe_offset":toe_offset,"toe_relative":toe_relative}
	var free_tool: bool = worker.tool_foot_occupied() and not worker.feet_work_active()
	_held_lift_time = maxf(_held_lift_time-delta,0.0) if free_tool else 0.0
	_held_lift = move_toward(_held_lift,.045 if _held_lift_time > 0.0 else 0.0,delta*1.8)
	if not free_tool: _held_shift = Vector3.ZERO
	elif _held_lift_time <= 0.0: _held_shift = _held_shift.move_toward(Vector3.ZERO,delta*.18)
	if not stable_work: _work_rotations.clear()
	var tool_support_point := Vector3.INF
	var tool_support_normal := Vector3.UP
	worker.stance_valid = false
	# A peer's native half-turn retains this lower actor's real plants. The
	# existing terrain solver still owns reach, finite lowering and sliding;
	# recoil speed alone must not release a sole into the ordinary run swing.
	var native_peer_stance: bool = worker.idle_play and worker.idle_play.get("upside_down") and worker.idle_play.upside_down.owns_lower_stance()
	var walking: bool = not native_peer_stance and worker.action.is_empty() and worker._animation.current_animation in ["wk_walkcycle", "work/carry", "work/run"]
	# Ordinary terrain travel and its idle landing own Cartesian sole targets.
	# Head and foot actions retain their separate captured-pose handoffs.
	var was_walking_ik := _walking_ik
	_walking_ik = worker.action.is_empty() and (head_prepare or (not _head_gait_continuation and _work_release.is_empty() and worker._animation.current_animation in ["wk_idle","wk_walkcycle","work/carry","work/run"]))
	# An action begun while the body still slides from a run (native braking
	# takes ~.5 m from 3.4 m/s) would drag its planted clip feet along the
	# ground: the gait keeps the legs for its braking steps (at most .6 s;
	# never for foot work, head, back-tool or tool owners, whose own entry
	# solves start from the published legs) and then hands over through the
	# usual release blend.
	var braking: bool = was_walking_ik and not _walking_ik and gait.active and worker.on_ground and not worker.action.is_empty() \
		and not manipulation and not worker.feet_work_active() and not worker.tool_foot_occupied() and not head_prepare \
		and not _head_ground_continuation and not _head_work_continuation and not _head_gait_continuation and _work_release.is_empty() \
		and not (worker.head_leap and worker.head_leap.active()) and not (worker.back_tool and (worker.back_tool.busy() or worker.back_tool.pose_owned()))
	if braking:
		var slide: float = (worker.linear_velocity-worker.ground_velocity).slide(worker.ground_normal).length()
		braking = slide > .8 if _brake_handoff_age < 0.0 else _brake_handoff_age < .6 and (slide > .1 or gait.state[0] != Gait.PLANTED or gait.state[1] != Gait.PLANTED)
	if braking:
		_brake_handoff_age = maxf(_brake_handoff_age,0.0)+delta
		_walking_ik = true
	else: _brake_handoff_age = -1.0
	if was_walking_ik and not _walking_ik and evaluated_valid:
		# The gait can hand its legs over mid-stride (an action begins on
		# arrival or interrupts): remember its last joints for a short blend.
		_gait_release_rotations.clear()
		for side in 2:
			_gait_release_rotations[side] = [evaluated_soles[side], evaluated_ankles[side].get_rotation_quaternion()]
		_gait_release_age = 0.0
	_update_travel_pole_handoff(delta)
	_gait_sides = [false, false]
	if _walking_ik:
		# Head preparation/landing and a peer's native half-turn keep their
		# plants; the planner then only finishes swings already in the air.
		var hold_feet: bool = head_prepare or _head_ground_continuation or native_peer_stance
		gait.plan(sk,delta,_settle_allowed(),hold_feet,_head_work_continuation)
	# Another owner took the legs: the locomotion acting fades out instead of
	# vanishing in one tick (and a resume continues from what is left).
	else: gait.release(delta)
	if walking or worker.action in ["place","brace"] or supported_head_pickup:
		if not _gait_handoff_active: _gait_handoff_velocity = [Vector3.ZERO,Vector3.ZERO]
		_gait_handoff_active = true
		_gait_handoff_tail = .24
	elif worker.action in ["","place","brace"] and _gait_handoff_tail > 0.0:
		_gait_handoff_tail = maxf(_gait_handoff_tail-delta,0.0)
	else:
		_gait_handoff_active = false
		_gait_handoff_tail = 0.0
	if not walking: _step_side = -1
	elif _step_side >= 0 and _step_ahead[_step_side] <= .025 and _step_lifts[_step_side] <= .025: _step_side = -1
	if walking and _step_side < 0:
		if _step_ahead[0] > .025 and _step_ahead[1] > .025: _step_side = 0 if _plant_weights[0] < _plant_weights[1] else 1
		elif _step_ahead[0] > .025: _step_side = 0
		elif _step_ahead[1] > .025: _step_side = 1
	var phase: float = fposmod(worker._animation.current_animation_position / maxf(worker._animation.current_animation_length, .01) + .1, 1.0)
	# The visible body and soles share one stance phase. Native support is still
	# the capsule/spring-foot controller; this is a small pose adjustment before
	# terrain IK, not another ground-force or locomotion controller.
	for side in 2:
		var foot_phase := fposmod(phase + side * .5, 1.0)
		var plant := 1.0 if not walking or speed < .18 else 1.0 - smoothstep(.43, .55, foot_phase)
		if walking and _step_side >= 0: plant = .15 if side == _step_side else 1.0
		_plant_weights[side] = move_toward(float(_plant_weights[side]), plant, delta * 12.0)
	_update_stopped_turn(sk,delta)
	_weight_transfer(sk, walking, speed, delta)
	_load_brace(sk)
	if _head_ground_continuation and evaluated_valid:
		_continue_head_root(sk,delta)
	elif _head_work_continuation and evaluated_valid:
		# A renewed ordinary approach can turn its visual hip faster than its
		# near-extended legs. Use the existing finite root handoff there only;
		# actual work and Back-owned finite waypoints keep their own root frame.
		if _walking_ik and _head_work_endpoint_owned(0) and _head_work_endpoint_owned(1):
			_continue_head_root(sk,delta)
		else:
			_capture_head_authored_joints(sk)
		_head_joints_match = true
		_head_work_feet_match = true
	for side in 2:
		var chain: Array = _chains[side]
		var upper: int = chain[0]
		var lower: int = chain[1]
		var foot: int = chain[2]
		var foot_xf := sk.get_bone_global_pose(foot)
		if _walking_ik:
			_terrain_walk_leg(sk,side,local_inv,walking,speed,phase,delta)
			continue
		_walk_swing_phase[side] = -1.0
		if manipulation and side == worker.work_foot_side and _toes[side] >= 0:
			_target_valid[side] = false
			var toe_xf := sk.get_bone_global_pose(_toes[side])
			var work_phase: float = _work_source_phase()
			var contact: Vector3 = worker.work_point()
			var hip_world := sk.global_transform * sk.get_bone_global_pose(upper).origin
			var axis := (contact - hip_world).normalized()
			if worker.pickup.manipulating(): axis = Vector3.DOWN
			if worker.action == "inspect":
				# A small toe-held probe scans the actual work face; it settles at
				# the same timed contact used to finish inspection, without striking.
				contact += worker._model.global_basis.x * (.025 * sin(work_phase * TAU) * (1.0 - smoothstep(.43,.56,work_phase)))
			if worker.foot_tool_span() > .001:
				# The supporting sole stays planted while the other foot draws its tool
				# back and returns at the existing .56 contact event. Solve the complete
				# withdrawn posture through the same clearance/reach path as the strike.
				contact -= axis * _tool_setback()
				var posture: Dictionary = worker.clear_tool_axis(contact, hip_world)
				if posture.is_empty():
					if worker.action_progress > .43 and worker.action_progress < .77: worker.tool_pose_blocked = "No clear foot/tool posture; provide a work platform or clear access"
					if evaluated_valid:
						# An unreachable next posture must not restore the authored
						# leg for one frame. Retain the last actual finite foot while
						# the job stops or finds a genuinely supported work stance.
						var last_basis: Basis = sk.global_basis.inverse()*evaluated_ankles[side]
						var last_sole: Vector3 = evaluated_soles[side]+worker.ground_velocity*delta
						_solve(sk,upper,lower,foot,local_inv*last_sole-last_basis*Vector3(0,_ankle_height[side],0),1.0,last_basis)
						var last_toe := sk.get_bone_global_pose(_toes[side])
						last_toe.basis = sk.global_basis.inverse()*worker.tool_grip_transform.basis
						sk.set_bone_global_pose(_toes[side],last_toe)
					continue
				axis = posture.axis
				worker.tool_pose_blocked = ""
			if worker.action == "tool_change":
				# Fit the physical stock axis first, then raise it gradually with
				# the same toe instead of flipping as .56 equips the rigid body.
				var stock_axis: Vector3 = worker.tool_pickup_basis.y.normalized()
				var stow_axis: Vector3 = (-worker._model.global_basis.z*.75+Vector3.UP*.65).normalized()
				axis = stock_axis.slerp(stow_axis,worker.tool_pickup_release_weight()).normalized()
			var grip_world: Vector3 = contact - axis * worker.foot_tool_span()
			var rotation := Quaternion(toe_xf.basis.y.normalized(), (sk.global_basis.inverse() * axis).normalized())
			var desired_basis := Basis(rotation) * foot_xf.basis
			var desired_toe := toe_xf.basis
			if stable_work:
				desired_toe = sk.global_basis.inverse() * worker.tool_axis_basis(sk.global_basis * toe_xf.basis, axis)
				# Final toe orientation is set independently below. Do not rotate
				# the entire ankle to cancel the authored toe's changing axial curl.
				var toe_relative: Basis = _work_origin.toe_relative
				desired_basis = desired_toe * toe_relative.inverse()
			var grip_offset := foot_xf.basis.inverse() * (toe_xf.origin + toe_xf.basis.y * .035 - foot_xf.origin)
			var desired_ankle: Vector3 = local_inv * grip_world - desired_basis * grip_offset
			if stable_work:
				grip_offset = Vector3(_work_origin.toe_offset)+desired_basis.inverse()*(sk.global_basis.inverse()*axis)*.035
				desired_ankle = local_inv*grip_world-desired_basis*grip_offset
			var envelope := smoothstep(.10, .43, work_phase) * (1.0 - smoothstep(.78, 1.0, work_phase))
			var from_ankle := foot_xf.origin
			var from_basis := foot_xf.basis
			if stable_work and not _work_origin.is_empty():
				# The tool foot prepares from its actual entry pose. A curling
				# authored ankle is not a moving interpolation origin: its roll can
				# reverse a clear contact solution while the body stands still.
				var root := sk.get_bone_global_pose(0)
				from_ankle = root*Vector3(_work_origin.ankle)
				from_basis = root.basis*Basis(_work_origin.basis)
			var authored_rotation := from_basis.get_rotation_quaternion()
			var desired_rotation := desired_basis.get_rotation_quaternion()
			if stable_work:
				# Keep quaternion hemispheres continuous through a turn past 180
				# degrees. Shortest-arc interpolation would reverse the complete
				# ankle twist at that boundary even though both poses are smooth.
				var previous: Dictionary = _work_rotations.get(side,{})
				var authored_reference: Quaternion = previous.get("authored",authored_rotation)
				var desired_reference: Quaternion = previous.get("desired",authored_rotation)
				if authored_rotation.dot(authored_reference) < 0.0: authored_rotation = -authored_rotation
				if desired_rotation.dot(desired_reference) < 0.0: desired_rotation = -desired_rotation
				_work_rotations[side] = {"authored":authored_rotation,"desired":desired_rotation}
			var blended_basis := Basis(authored_rotation.slerpni(desired_rotation,envelope) if stable_work else authored_rotation.slerp(desired_rotation,envelope))
			var blended_ankle := from_ankle.lerp(desired_ankle,envelope)
			if stable_work:
				# Work entry can inherit a low walking toe during clip blending.
				# Raise the actual leg, retaining its length and the opposite plant,
				# to the SAME minimum grip height required by tool-axis reach tests.
				var blended_grip: Vector3 = sk.global_transform * (blended_ankle+blended_basis*grip_offset)
				var gap: float = worker.ground_normal.dot(blended_grip-worker._ground_point)
				if gap < .08: blended_ankle += sk.global_basis.inverse()*worker.ground_normal*(.08-gap)
			_solve(sk, upper, lower, foot, blended_ankle, .98, blended_basis)
			if stable_work:
				var solved_toe := sk.get_bone_global_pose(_toes[side])
				var entry_toe: Basis = from_basis*Basis(_work_origin.toe_relative)
				if work_phase > .78 and worker.tool_foot_occupied():
					# The bare toe's pre-fitting pose is not the equipped tool's
					# return pose. Turn toward carry while the work leg is still
					# raised, before lowering the complete mallet beside the cube.
					var stow_axis: Vector3 = (-worker._model.global_basis.z*.75+Vector3.UP*.65).normalized()
					var right: Vector3 = worker._model.global_basis.x.slide(stow_axis).normalized()
					entry_toe = sk.global_basis.inverse()*Basis(right,stow_axis,right.cross(stow_axis))
				solved_toe.basis = Basis(entry_toe.get_rotation_quaternion().slerp(desired_toe.get_rotation_quaternion(),envelope))
				sk.set_bone_global_pose(_toes[side],solved_toe)
			continue
		var ankle_to_sole := Vector3(0, _ankle_height[side], 0)
		var sole_local := foot_xf * ankle_to_sole
		var sole := sk.global_transform * sole_local
		if worker.station_reacquire_time > 0.0 and side != worker.work_foot_side and is_instance_valid(worker.station_support):
			var saved_sole: Vector3 = worker.station_support.to_global(worker.station_support_local)
			if saved_sole.distance_to(sole) < .45:
				# Rebind the saved, physically supported foot rather than planting a neutral
				# clip just outside the edge while the deck has moved during loading.
				sole = saved_sole
				_targets[side] = saved_sole
				_support[side] = weakref(worker.station_support)
				_support_rids[side] = worker.station_support.get_rid()
				_support_local[side] = worker.station_support_local
				_target_valid[side] = true
		_terrain_query.from = Vector3(sole.x,maxf(sole.y+.5,worker.global_position.y+.12),sole.z)
		_terrain_query.to = sole - Vector3.UP * 0.65
		var hit := terrain.intersect_ray(_terrain_query)
		if hit.is_empty() or hit.normal.y < 0.6:
			_target_valid[side] = false
			continue
		_sole_normals[side] = hit.normal
		_terrain_points[side] = hit.position
		_terrain_transition_time[side] = maxf(float(_terrain_transition_time[side])-delta,0.0)
		if _previous_terrain_points[side].is_finite() and absf(hit.normal.dot(hit.position-_previous_terrain_points[side])) > .025:
			_terrain_transition_time[side] = .35
		if side == worker.tool_foot_side():
			# A swing can already be outside a raised deck while the capsule is
			# still above it. Use this foot's observed surface for tool clearance.
			tool_support_point = hit.position
			tool_support_normal = hit.normal
		var stance: bool = _plant_weights[side] > .72
		var clearance := maxf(sole_local.y - float(_lowest_sole[side]), 0.0) if walking else 0.0
		if walking:
			_step_probe_age[side] += delta
			if _step_probe_age[side] >= .05:
				_step_probe_age[side] = 0.0
				var travel: Vector3 = (worker.linear_velocity-worker.ground_velocity).slide(Vector3.UP)
				_step_ahead[side] = 0.0
				if travel.length_squared() > .04:
						# A single far probe can skip a small cap between the sole and
						# its destination. Observe that finite corridor before crossing.
						for distance: float in [.16,.36,clampf(speed*.38,.7,.9)]:
							var ahead: Vector3 = hit.position+travel.normalized()*distance
							_terrain_query.from = Vector3(ahead.x,maxf(ahead.y+.55,worker.global_position.y+.12),ahead.z)
							_terrain_query.to = ahead-Vector3.UP*.35
							var upcoming := terrain.intersect_ray(_terrain_query)
							if not upcoming.is_empty() and upcoming.normal.y > .6:
								var rise: float = hit.normal.dot(upcoming.position-hit.position)
								if rise > .025 and (rise <= .42 or upcoming.normal.y < .995):
									_step_ahead[side] = maxf(float(_step_ahead[side]),minf(rise,.42)+.035)
			# Only an observed low rise asks for an early toe lift. Native spring
			# support, both real limb lengths and the existing gait remain in charge.
			_step_lifts[side] = move_toward(float(_step_lifts[side]),float(_step_ahead[side]),delta*1.6)
			clearance += _step_lifts[side]
		else:
			_step_lifts[side] = 0.0
			_step_ahead[side] = 0.0
		var desired: Vector3 = hit.position + hit.normal * clearance * (1.0 - _plant_weights[side])
		var support: Object = _support[side].get_ref()
		if stance and _target_valid[side] and support is Node3D:
			var planted: Vector3 = support.to_global(_support_local[side])
			# A overstretched planted foot releases rather than stretching the body.
			# Keep the new ground hit as the released target; reusing the old target
			# here would bind an out-of-reach point to the new moving support forever.
			if planted.distance_to(sole) > 0.45 or support != hit.collider or _support_rids[side] != hit.rid:
				_target_valid[side] = false
			else:
				desired = planted
		if not _target_valid[side] or not stance:
			_targets[side] = desired
			_support[side] = weakref(hit.collider)
			_support_rids[side] = hit.rid
			if hit.collider is Node3D:
				_support_local[side] = hit.collider.to_local(desired)
			_target_valid[side] = stance
		else:
			_targets[side] = _targets[side].lerp(desired, 1.0 - exp(-14.0 * delta))
		# Pin the sole, not the ankle: the original long feet roll through their toe during the stride.
		var normal: Vector3 = (sk.global_basis.inverse() * hit.normal).normalized()
		var tilt := Quaternion(-foot_xf.basis.y.normalized(), normal)
		var basis := Basis(Quaternion.IDENTITY.slerp(tilt, _plant_weights[side])) * foot_xf.basis
		if not walking and not manipulation and stance:
			# A cancelled raised foot can project beyond its finite leg's standing
			# footprint. Replant nearer the hip on the SAME observed support, rather
			# than pinning an unreachable target and leaving the sole in the air.
			var reachable := _reachable_plant(sk, side, _targets[side], basis, hit.normal)
			if reachable.distance_to(_targets[side]) > .002:
				_terrain_query.from = reachable + Vector3.UP * .2
				_terrain_query.to = reachable - Vector3.UP * .25
				var replant := terrain.intersect_ray(_terrain_query)
				if not replant.is_empty() and replant.collider == hit.collider and replant.normal.y > .6:
					_targets[side] = replant.position
					_support_local[side] = replant.collider.to_local(replant.position)
					_support_rids[side] = replant.rid
		var held_lift: float = _held_lift if free_tool and side == worker.tool_foot_side() else 0.0
		var held_shift: Vector3 = _held_shift if free_tool and side == worker.tool_foot_side() else Vector3.ZERO
		var target: Vector3 = local_inv * (_targets[side]+hit.normal*held_lift+held_shift) - basis * ankle_to_sole
		# Full-weight solves: a partial blend between the imported (old +Z
		# knee) clip and the face-bent solution would park the knee halfway
		# round and let a planted sole drift with the clip.
		_solve(sk, upper, lower, foot, target, 1.0, basis)
		evaluated_grounded[side] = stance and held_lift < .01
		if manipulation and side != worker.work_foot_side and stance:
			worker.stance_point = _targets[side]
			worker.stance_valid = true
		if worker.tool_foot_occupied() and side == worker.tool_foot_side() and _toes[side] >= 0:
			# Curl the gripping toes upwards during travel; the planted heel keeps its support.
			var toe_pose := sk.get_bone_global_pose(_toes[side])
			var axis: Vector3 = (-worker._model.global_basis.z * .75 + Vector3.UP * .65).normalized()
			var q := Quaternion(toe_pose.basis.y.normalized(), (sk.global_basis.inverse() * axis).normalized())
			toe_pose.basis = Basis(q) * toe_pose.basis
			sk.set_bone_global_pose(_toes[side], toe_pose)
	# A pedal also has one planted support leg. Smooth replanting that leg when
	# its actual moving-deck anchor releases, just as during toe/tool work.
	var work_support: bool = manipulation and (stable_work or worker.action == "operate")
	if worker.action in ["","interrupted","place","brace"] or work_support or supported_head_pickup:
		# Plant release and walking-to-idle blending can change the analytic solution
		# abruptly. Blend leg rotations through that change, retaining bone lengths
		# and each sole's solved orientation instead of flipping its skin for a frame.
		var blend := 1.0 - exp(-28.0 * delta)
		for side in 2:
			if _walking_ik: continue
			var chain: Array = _chains[side]
			if _work_release.get("side",-1) == side: continue
			if work_support and side == worker.work_foot_side:
				for bone: int in [chain[0],chain[1]]: _gait_rotations.erase(bone)
				continue
			var foot_basis := sk.get_bone_global_pose(chain[2]).basis
			if evaluated_valid:
				var previous_basis: Basis = sk.global_basis.inverse()*worker.global_basis*evaluated_worker.basis.inverse()*evaluated_ankles[side]
				var angle := previous_basis.get_rotation_quaternion().angle_to(foot_basis.get_rotation_quaternion())
				foot_basis = Basis(previous_basis.get_rotation_quaternion().slerp(foot_basis.get_rotation_quaternion(),minf(delta*6.0/maxf(angle,.00001),1.0)))
			for bone: int in [chain[0], chain[1]]:
				# The departure pole already follows the actual knee plane at a
				# finite speed. Filtering its two joints independently can bend
				# them backward again and pull the solved sole behind the body.
				if _head_ground_continuation or _head_work_continuation or _travel_pole_handoff or (worker.back_tool and worker.back_tool.cancelled_plane_owned()): continue
				if _head_gait_continuation:
					# The prior evaluated rotation belongs to the WORLD rig frame.
					# A resumed visual heading must enter this same leg solve rather
					# than rotate an unchanged local knee pose by the full heading.
					var global_pose := sk.get_bone_global_pose(bone)
					var target_world := (sk.global_basis*global_pose.basis).get_rotation_quaternion().normalized()
					var previous_world: Quaternion = _head_gait_rotations.get(bone,target_world)
					var relative_world := previous_world.inverse()*target_world
					var world_turn := 2.0*atan2(Vector3(relative_world.x,relative_world.y,relative_world.z).length(),absf(relative_world.w))
					var rotation_world := previous_world.slerp(target_world,minf(blend,delta*6.0/maxf(world_turn,.00001))).normalized()
					global_pose.basis = sk.global_basis.inverse()*Basis(rotation_world)
					sk.set_bone_global_pose(bone,global_pose)
					continue
				var target := sk.get_bone_pose_rotation(bone)
				var previous: Quaternion = _gait_rotations.get(bone, target)
				var turn := previous.angle_to(target)
				var rotation := previous.slerp(target,minf(blend,delta*6.0/maxf(turn,.00001)))
				_gait_rotations[bone] = rotation
				sk.set_bone_pose_rotation(bone, rotation)
			var foot_pose := sk.get_bone_global_pose(chain[2])
			foot_pose.basis = foot_basis
			sk.set_bone_global_pose(chain[2], foot_pose)
			if work_support and _target_valid[side]:
				# Releasing a previous walking plant must not snap the supporting
				# knee at work entry. Blend the same leg rotations, but project any
				# below-plane sole at its CURRENT lateral position, not at the new
				# target that caused the discontinuity. Reach stays clamped by IK.
				var ankle_to_sole := Vector3(0,_ankle_height[side],0)
				var final_sole: Vector3 = sk.global_transform*(foot_pose*ankle_to_sole)
				var gap: float = worker.ground_normal.dot(final_sole-_targets[side])
				if gap < 0.0:
					var projected: Vector3 = final_sole-worker.ground_normal*gap
					var target: Vector3 = local_inv*projected-foot_pose.basis*ankle_to_sole
					_solve(sk,chain[0],chain[1],chain[2],target,1.0,foot_pose.basis)
					for bone: int in [chain[0],chain[1]]: _gait_rotations[bone] = sk.get_bone_pose_rotation(bone)
		if not work_support and not _walking_ik:
			for side in 2:
				if not _terrain_points[side].is_finite() and not _head_gait_continuation: continue
				_project_sole_above_terrain(sk,side,local_inv,delta)
				if _gait_handoff_active and evaluated_valid: _blend_gait_handoff(sk,side,local_inv,speed,delta)
	else: _gait_rotations.clear()
	if not _walking_ik and _gait_release_age < GAIT_RELEASE_BLEND:
		_blend_gait_release(sk,manipulation,delta)
	_blend_work_release(sk,delta)
	if free_tool and not _head_gait_continuation and not _work_release.is_empty():
		# The captured fitting sole follows a moving rig after the earlier
		# terrain solve. Observe that final sole's own column before turning
		# its whole retained tool; a lifted release is not a valid plant.
		_project_sole_above_terrain(sk,int(_work_release.side),local_inv,delta,true)
	_blend_work_entry(sk,delta)
	if manipulation and (not _work_entry.is_empty() or stable_work and worker.action_progress < .43):
		# Entry and early preparation may turn the ankle before its lift. Observe
		# that final sole's own native column after the captured entry blend.
		_project_sole_above_terrain(sk,worker.work_foot_side,local_inv,delta)
	_blend_pickup_release(sk)
	if _head_ground_continuation and evaluated_valid:
		_continue_head_soles(sk,local_inv,delta)
	if _terrain_points[worker.tool_foot_side()].is_finite():
		tool_support_point = _terrain_points[worker.tool_foot_side()]
		tool_support_normal = _sole_normals[worker.tool_foot_side()]
	if worker.tool_foot_occupied() and _toes[worker.tool_foot_side()] >= 0:
		var world_tool_return: bool = _head_work_continuation or _head_gait_continuation or _travel_tool_handoff or _walking_ik
		var toe_index: int = _toes[worker.tool_foot_side()]
		var toe_pose := sk.get_bone_global_pose(toe_index)
		if free_tool and not tool_support_point.is_finite():
			# A free toe can pass beside a raised deck while the spring foot is
			# still above it. Observe the lower surface for tool clearance only;
			# this longer ray never binds a plant or extends the terrain IK reach.
			var toe_world: Vector3 = sk.global_transform*toe_pose.origin
			_terrain_query.from = toe_world+Vector3.UP*.5
			_terrain_query.to = toe_world-Vector3.UP*(worker.foot_tool_span()+.65)
			var beneath := terrain.intersect_ray(_terrain_query)
			if not beneath.is_empty() and beneath.normal.y > .6:
				tool_support_point = beneath.position
				tool_support_normal = beneath.normal
		var axis: Vector3 = (-worker._model.global_basis.z*.75+Vector3.UP*.65).normalized() if free_tool else (sk.global_basis*toe_pose.basis.y).normalized()
		var stable_release: bool = stable_work and worker.action_progress > .78
		var clear_axis: Vector3 = axis if stable_release and worker.held_tool_basis_clear(sk.global_transform*toe_pose.origin,sk.global_basis*toe_pose.basis,tool_support_point,tool_support_normal) else worker.clear_held_tool_axis(sk.global_transform*toe_pose.origin,axis,tool_support_point,tool_support_normal)
		if clear_axis.length_squared() < .01 and tool_support_point.is_finite() and free_tool:
			# A newly observed raised tread can crowd the retained tool against
			# BOTH the cube and terrain. Raise its actual gripping leg a few
			# centimetres with the same finite chain, retaining the other plant.
			var side: int = worker.tool_foot_side()
			var chain: Array = _chains[side]
			var foot := sk.get_bone_global_pose(chain[2])
			_held_lift_time = .35
			for lift: float in [.015,.03]:
				_solve(sk,chain[0],chain[1],chain[2],foot.origin+sk.global_basis.inverse()*tool_support_normal*lift,1.0,foot.basis)
				toe_pose = sk.get_bone_global_pose(toe_index)
				clear_axis = worker.clear_held_tool_axis(sk.global_transform*toe_pose.origin,axis,tool_support_point,tool_support_normal)
				if clear_axis.length_squared() > .01: break
			_held_lift = maxf(_held_lift,.015)
			for bone: int in [chain[0],chain[1]]: _gait_rotations[bone] = sk.get_bone_pose_rotation(bone)
			evaluated_grounded[side] = false
		if clear_axis.length_squared() < .01:
			worker.tool_pose_blocked = "No clear supported retained-tool posture"
			clear_axis = axis
		elif worker.tool_pose_blocked == "No clear supported retained-tool posture": worker.tool_pose_blocked = ""
		var rotation := Quaternion(toe_pose.basis.y.normalized(), (sk.global_basis.inverse() * clear_axis).normalized())
		if (stable_work and not stable_release) or free_tool:
			toe_pose.basis = sk.global_basis.inverse() * worker.tool_axis_basis(sk.global_basis * toe_pose.basis, clear_axis)
		else:
			toe_pose.basis = Basis(rotation) * toe_pose.basis
		if (free_tool or stable_work) and evaluated_valid and worker.foot_grip_valid:
			# The authored recoil can reverse axial toe roll while the shaft
			# stays clear. Retain the whole evaluated tool orientation and turn
			# toward recovery through bounded, currently clear intermediate poses.
			var previous: Basis = worker.global_basis*evaluated_worker.basis.inverse()*worker.tool_grip_transform.basis
			if free_tool and not world_tool_return: previous = sk.global_basis*evaluated_basis.inverse()*worker.tool_grip_transform.basis
			var desired: Basis = sk.global_basis*toe_pose.basis
			var stepped: Basis
			if world_tool_return:
				# Ordinary Cartesian gait also keeps its actual WORLD orientation.
				# Rebasing the previous tool by a newly turned rig adds that yaw on
				# top of its bounded turn. Head return keeps this exact same path.
				var before := previous.get_rotation_quaternion().normalized()
				var after := desired.get_rotation_quaternion().normalized()
				var relative := before.inverse()*after
				var angle := 2.0*atan2(Vector3(relative.x,relative.y,relative.z).length(),absf(relative.w))
				# Inward round-trip reserve; measured final WORLD cap stays 6.0.
				var weight := minf(maxf(delta*6.0-.00001,0.0)/maxf(angle,.00001),1.0)
				stepped = Basis(before.slerp(after,weight).normalized())
				if _walking_ik:
					# Ordinary travel must meet the original rig-local budget too.
					# Choose the farthest point on this same WORLD path which lies
					# inside that budget, then use the unchanged full-tool guards.
					var local_previous: Quaternion = (sk.global_basis*evaluated_basis.inverse()*worker.tool_grip_transform.basis).get_rotation_quaternion().normalized()
					var limit := maxf(delta*6.0-.00001,0.0)
					var local_relative := local_previous.inverse()*stepped.get_rotation_quaternion()
					var local_angle := 2.0*atan2(Vector3(local_relative.x,local_relative.y,local_relative.z).length(),absf(local_relative.w))
					if local_angle>limit:
						var lower := 0.0
						var upper := weight
						for iteration in 12:
							var trial := before.slerp(after,(lower+upper)*.5).normalized()
							var relative_local := local_previous.inverse()*trial
							var turn_local := 2.0*atan2(Vector3(relative_local.x,relative_local.y,relative_local.z).length(),absf(relative_local.w))
							if turn_local<=limit: lower=(lower+upper)*.5
							else: upper=(lower+upper)*.5
						stepped = Basis(before.slerp(after,lower).normalized())
			else:
				var angle := previous.get_rotation_quaternion().angle_to(desired.get_rotation_quaternion())
				var weight := minf(delta*6.0/maxf(angle,.00001),1.0)
				stepped = Basis(previous.get_rotation_quaternion().slerp(desired.get_rotation_quaternion(),weight))
			var origin: Vector3 = sk.global_transform*toe_pose.origin
			if worker.held_tool_basis_clear(origin,stepped,tool_support_point,tool_support_normal):
				toe_pose.basis = sk.global_basis.inverse()*stepped
			elif worker.held_tool_basis_clear(origin,previous,tool_support_point,tool_support_normal):
				toe_pose.basis = sk.global_basis.inverse()*previous
			elif free_tool and tool_support_point.is_finite():
				# Retaining axial roll can need slightly more terrain clearance
				# than the final orientation. Keep that room through the return.
				var side: int = worker.tool_foot_side()
				var chain: Array = _chains[side]
				var foot := sk.get_bone_global_pose(chain[2])
				var kept_orientation := false
				var trial_bones: Array[int] = [chain[0],chain[1],chain[2],toe_index]
				var trial_input: Array[Transform3D] = []
				if world_tool_return:
					for bone: int in trial_bones: trial_input.append(sk.get_bone_global_pose(bone))
				_held_lift_time = .35
				for lift: float in [.015,.03]:
					if world_tool_return:
						for index in trial_bones.size(): sk.set_bone_global_pose(trial_bones[index],trial_input[index])
					_solve(sk,chain[0],chain[1],chain[2],foot.origin+sk.global_basis.inverse()*tool_support_normal*lift,1.0,foot.basis)
					toe_pose = sk.get_bone_global_pose(toe_index)
					toe_pose.basis = sk.global_basis.inverse()*desired
					origin = sk.global_transform*toe_pose.origin
					if worker.held_tool_basis_clear(origin,stepped,tool_support_point,tool_support_normal):
						toe_pose.basis = sk.global_basis.inverse()*stepped
						kept_orientation = true
						break
					elif worker.held_tool_basis_clear(origin,previous,tool_support_point,tool_support_normal):
						toe_pose.basis = sk.global_basis.inverse()*previous
						kept_orientation = true
						break
				if not kept_orientation:
					# The native body can move toward the previous tool while its
					# sole is returning. Give that same leg a small outward clearance
					# return before changing the complete mallet orientation.
					var cube: Vector3 = sk.global_transform*sk.get_bone_global_pose(0).origin
					var outward: Vector3 = (origin-cube).slide(tool_support_normal).normalized()
					for offset: Vector3 in [-tool_support_normal*.015,-tool_support_normal*.015+outward*.015,outward*.015,outward*.03,tool_support_normal*.03+outward*.015,tool_support_normal*.03+outward*.03]:
						if world_tool_return:
							for index in trial_bones.size(): sk.set_bone_global_pose(trial_bones[index],trial_input[index])
						_solve(sk,chain[0],chain[1],chain[2],foot.origin+sk.global_basis.inverse()*offset,1.0,foot.basis)
						toe_pose = sk.get_bone_global_pose(toe_index)
						origin = sk.global_transform*toe_pose.origin
						var candidate_sole: Vector3 = sk.global_transform*(sk.get_bone_global_pose(chain[2])*Vector3(0,_ankle_height[side],0))
						if tool_support_normal.dot(candidate_sole-tool_support_point) < -.001: continue
						if worker.held_tool_basis_clear(origin,stepped,tool_support_point,tool_support_normal) or worker.held_tool_basis_clear(origin,previous,tool_support_point,tool_support_normal):
							toe_pose.basis = sk.global_basis.inverse()*(stepped if worker.held_tool_basis_clear(origin,stepped,tool_support_point,tool_support_normal) else previous)
							_held_shift = (_held_shift+offset.slide(tool_support_normal)).limit_length(.06)
							kept_orientation = true
							break
				if not kept_orientation:
					# A tight edge can block the proposed foot motion as well as its
					# tool turn. Retain the last actual sole on observed terrain while
					# the next gait target finds room, rather than flipping the mallet.
					var retained_sole: Vector3 = evaluated_soles[side]+worker.ground_velocity*delta
					if world_tool_return and free_tool and not evaluated_grounded[side]:
						# An unplanted swing belongs to the advancing native body.
						# Retain its actual finite endpoint in that body frame while
						# the same WORLD rotation catches up with the resumed cube.
						retained_sole = worker.global_transform*(evaluated_worker.affine_inverse()*evaluated_soles[side])
					if worker.action == "interrupted" and _work_release.get("side",-1) == side and not evaluated_grounded[side]:
						# A native hit moves the capsule under its lifted working toe.
						# Carry that actual unplanted pose with the body; a world-fixed
						# fallback would hold it behind, then jump across at release.
						retained_sole = worker.global_transform*(evaluated_worker.affine_inverse()*evaluated_soles[side])
					_terrain_query.from = retained_sole+Vector3.UP*.5
					_terrain_query.to = retained_sole-Vector3.UP*.5
					var support := terrain.intersect_ray(_terrain_query)
					if not support.is_empty() and support.normal.y > .6:
						retained_sole += support.normal*maxf(-support.normal.dot(retained_sole-support.position),0.0)
						var retained_basis: Basis = sk.global_basis.inverse()*evaluated_ankles[side]
						if world_tool_return:
							# Clearance trials must start from the last evaluated WORLD
							# limb, not from a rejected lift's accumulated joint state.
							# Current hip attachment and all original bone lengths stay
							# owned by the current rig and the same finite two-link solve.
							for bone: int in [chain[0],chain[1]]:
								var input_pose := sk.get_bone_global_pose(bone)
								var previous_input: Quaternion = _head_gait_rotations.get(bone,(sk.global_basis*input_pose.basis).get_rotation_quaternion())
								input_pose.basis = sk.global_basis.inverse()*Basis(previous_input)
								sk.set_bone_global_pose(bone,input_pose)
							var input_foot := sk.get_bone_global_pose(chain[2])
							input_foot.basis = retained_basis
							sk.set_bone_global_pose(chain[2],input_foot)
						var cube: Vector3 = sk.global_transform*sk.get_bone_global_pose(0).origin
						var away: Vector3 = (retained_sole-cube).slide(support.normal).normalized()
						if world_tool_return:
							var retained_origin: Vector3 = worker.tool_grip_transform.origin+retained_sole-evaluated_soles[side]
							var tool_return: Vector3 = worker.held_tool_return_direction(retained_origin,stepped,support.normal)
							if tool_return.length_squared()>.01: away = tool_return
						var retained_bones: Array[int] = [chain[0],chain[1],chain[2],toe_index]
						var retained_input: Array[Transform3D] = []
						for bone: int in retained_bones: retained_input.append(sk.get_bone_global_pose(bone))
						# A high swing may crowd the full crossbar before its shaft.
						# Start at the last actual sole, rather than the new desired
						# ankle that already lost that orientation's clearance.
						for offset: Vector3 in [Vector3.ZERO,-support.normal*.015,-support.normal*.03,away*.015,away*.03,away*.045,-support.normal*.015+away*.03]:
							# Each rejected solve is discarded before trying another
							# finite endpoint; it must not become the next input pose.
							for index in retained_bones.size(): sk.set_bone_global_pose(retained_bones[index],retained_input[index])
							var candidate_sole: Vector3 = retained_sole+offset
							_terrain_query.from = Vector3(candidate_sole.x,maxf(candidate_sole.y+.5,worker.global_position.y+.12),candidate_sole.z)
							_terrain_query.to = candidate_sole-Vector3.UP*.5
							var column := terrain.intersect_ray(_terrain_query)
							if column.is_empty() or column.normal.y < .6: continue
							if column.normal.dot(candidate_sole-column.position) < -.001: continue
							_solve(sk,chain[0],chain[1],chain[2],local_inv*candidate_sole-retained_basis*Vector3(0,_ankle_height[side],0),1.0,retained_basis)
							toe_pose = sk.get_bone_global_pose(toe_index)
							origin = sk.global_transform*toe_pose.origin
							var actual_sole: Vector3 = sk.global_transform*(sk.get_bone_global_pose(chain[2])*Vector3(0,_ankle_height[side],0))
							_terrain_query.from = Vector3(actual_sole.x,maxf(actual_sole.y+.5,worker.global_position.y+.12),actual_sole.z)
							_terrain_query.to = actual_sole-Vector3.UP*.5
							column = terrain.intersect_ray(_terrain_query)
							if column.is_empty() or column.normal.y < .6: continue
							if actual_sole.distance_to(retained_sole) > .05 or column.normal.dot(actual_sole-column.position) < -.001: continue
							# The same finite WORLD turn also belongs to this recovered
							# leg endpoint. Testing it only at the rejected gait endpoint
							# discarded a valid continuous path as the cube turned.
							var retained_rotation: Basis = previous
							if world_tool_return and worker.held_tool_basis_clear(origin,stepped,column.position,column.normal):
								retained_rotation = stepped
							elif not worker.held_tool_basis_clear(origin,previous,column.position,column.normal):
								continue
							toe_pose.basis = sk.global_basis.inverse()*retained_rotation
							_terrain_points[side] = column.position
							_sole_normals[side] = column.normal
							_targets[side] = column.position
							_support[side] = weakref(column.collider)
							_support_rids[side] = column.rid
							_support_local[side] = column.collider.to_local(column.position)
							_target_valid[side] = column.normal.dot(actual_sole-column.position) <= .035
							_held_shift = (_held_shift+offset.slide(column.normal)).limit_length(.06)
							kept_orientation = true
							break
						if not kept_orientation:
							for index in retained_bones.size(): sk.set_bone_global_pose(retained_bones[index],retained_input[index])
							toe_pose = sk.get_bone_global_pose(toe_index)
					if not kept_orientation:
						var retained: Variant=worker.back_tool.retain_original_foot(self,sk,side)
						toe_pose=sk.get_bone_global_pose(toe_index) if retained is Transform3D else toe_pose
						if not retained is Transform3D: toe_pose.basis=sk.global_basis.inverse()*previous
				_held_lift = maxf(_held_lift,.015)
				for bone: int in [chain[0],chain[1]]: _gait_rotations[bone] = sk.get_bone_pose_rotation(bone)
				evaluated_grounded[side] = false
			else:
				var retained: Variant=worker.back_tool.retain_original_foot(self,sk,worker.tool_foot_side())
				toe_pose=sk.get_bone_global_pose(toe_index) if retained is Transform3D else toe_pose
				if not retained is Transform3D: toe_pose.basis=sk.global_basis.inverse()*previous
			if world_tool_return:
				var final_head_rotation := (sk.global_basis*toe_pose.basis).get_rotation_quaternion().normalized()
				var desired_head_rotation := desired.get_rotation_quaternion().normalized()
				var head_difference := final_head_rotation.inverse()*desired_head_rotation
				head_gait_matches = 2.0*atan2(Vector3(head_difference.x,head_difference.y,head_difference.z).length(),absf(head_difference.w)) < .00005
		if "--tool-debug" in OS.get_cmdline_user_args() and worker.foot_grip_valid and worker.tool_foot_occupied():
			var final_basis: Basis = sk.global_basis*toe_pose.basis
			var previous_basis: Basis = worker.global_basis*evaluated_worker.basis.inverse()*worker.tool_grip_transform.basis
			var turn := rad_to_deg(previous_basis.get_rotation_quaternion().angle_to(final_basis.get_rotation_quaternion()))
			if turn > 18.0:
				print("CONTRAPTION_HELD_TURN action=",worker.action," phase=",worker.action_progress," free=",free_tool," evaluated=",evaluated_valid," angle=",turn," serial=",evaluation_serial," lift=",_held_lift," hold=",_held_lift_time," support=",tool_support_point," sole=",evaluated_soles[worker.tool_foot_side()]," origin=",sk.global_transform*toe_pose.origin," previous=",previous_basis," final=",final_basis," blocked=",worker.tool_pose_blocked," previous_guard=",worker.held_tool_clearance_debug(sk.global_transform*toe_pose.origin,previous_basis,tool_support_point,tool_support_normal))
		sk.set_bone_global_pose(toe_index, toe_pose)
	_continue_head_back_leg(sk)
	if worker.back_tool: worker.back_tool.evaluated(self,sk,delta)
	if worker.portable_gun: worker.portable_gun.evaluate(sk,delta)
	_continue_cancelled_pivot(sk,delta,manipulation)
	for side in 2:
		_head_work_toes[side] = sk.global_transform*sk.get_bone_global_pose(_toes[side])
		for bone: int in [_chains[side][0],_chains[side][1]]:
			_head_gait_rotations[bone] = (sk.global_basis*sk.get_bone_global_pose(bone).basis).get_rotation_quaternion().normalized()
			_head_joint_rotations[bone] = _head_gait_rotations[bone]
		evaluated_hips[side] = sk.global_transform * sk.get_bone_global_pose(_chains[side][0]).origin
		evaluated_knees[side] = sk.global_transform * sk.get_bone_global_pose(_chains[side][1]).origin
		evaluated_ankles[side] = sk.global_basis * sk.get_bone_global_pose(_chains[side][2]).basis
		evaluated_soles[side] = sk.global_transform * (sk.get_bone_global_pose(_chains[side][2]) * Vector3(0, _ankle_height[side], 0))
		# Gait plants publish support only for a sole actually on its plant.
		evaluated_grounded[side] = evaluated_grounded[side] and evaluated_soles[side].distance_to(_targets[side]) < (.02 if _gait_sides[side] else .10)
		if work_support and side != worker.work_foot_side and not evaluated_grounded[side]:
			# No work completion may claim the old plant while this sole is still
			# moving toward its newly observed supported location.
			worker.stance_valid = false
	evaluated_valid = true
	evaluated_root = sk.global_transform * sk.get_bone_global_pose(0)
	evaluated_worker = worker.global_transform
	evaluated_basis = sk.global_basis
	evaluation_serial += 1
	_finish_work_pole_return()
	var normal_head_gait: bool = worker.action.is_empty() and worker._animation.current_animation in ["wk_idle","wk_walkcycle","work/carry","work/run"] and (not worker.back_tool or not worker.back_tool.pose_owned())
	# Reaching today's place pose is not a handoff to its remaining authored
	# tail. Release grounded ownership only after ordinary gait has converged.
	if _head_landing_continuation and not head_landing and normal_head_gait:
		var planes_match := true
		for side in 2:
			var ankle: Vector3 = evaluated_soles[side]-evaluated_ankles[side]*Vector3(0,_ankle_height[side],0)
			var axis: Vector3 = (ankle-evaluated_hips[side]).normalized()
			var plane: Vector3 = (evaluated_knees[side]-evaluated_hips[side]).slide(axis)
			var wanted: Vector3 = (-worker._model.global_basis.z).slide(axis)
			planes_match = planes_match and plane.length_squared()>.00001 and wanted.length_squared()>.00001 and plane.normalized().angle_to(wanted.normalized())<.001
		_head_return_settle = _head_return_settle+delta if _head_root_matches and _head_soles_match and _head_joints_match and planes_match else 0.0
		if _head_return_settle>=.24:
			_head_ground_continuation = false
			_head_landing_continuation = false
			_head_return_settle = 0.0
	if _head_work_continuation:
		var planes_match := true
		for side in 2:
			var ankle: Vector3 = evaluated_soles[side]-evaluated_ankles[side]*Vector3(0,_ankle_height[side],0)
			var axis: Vector3 = (ankle-evaluated_hips[side]).normalized()
			var plane: Vector3 = (evaluated_knees[side]-evaluated_hips[side]).slide(axis)
			var wanted: Vector3 = (-worker._model.global_basis.z).slide(axis)
			planes_match = planes_match and plane.length_squared()>.00001 and wanted.length_squared()>.00001 and plane.normalized().angle_to(wanted.normalized())<.001
		_head_work_settle = _head_work_settle+delta if normal_head_gait and not same_staged_head and _head_joints_match and _head_work_feet_match and planes_match else 0.0
		if _head_work_settle>=.24:
			_head_work_continuation = false
			_head_work_settle = 0.0
			_head_work_source = null
			_head_work_target = null
			_head_work_job = ""
	worker._update_work_tool(true)
	if worker.back_tool: worker.back_tool.foot_published(delta)
	if _travel_tool_handoff and worker.action.is_empty():
		# A finished foot fitting can turn the visual cube faster than its tool.
		# Keep the same captured WORLD return until the actual tool and heading
		# settle, then restore ordinary terrain travel without a final roll jump.
		_travel_tool_settle_time = _travel_tool_settle_time+delta if head_gait_matches and absf(worker.turn_rate)<.15 else 0.0
		if _travel_tool_settle_time>=.24: _travel_tool_handoff = false
	if _head_gait_continuation and walking and worker.action.is_empty():
		# The two coordinate conventions meet at the actual ordinary gait target.
		# End only after its tool has converged and the cube has settled through
		# the existing .24-second locomotion blend, then release the scoped state.
		_head_gait_settle_time = _head_gait_settle_time+delta if head_gait_matches and absf(worker.turn_rate)<.15 else 0.0
		if _head_gait_settle_time >= .24:
			_head_gait_continuation = false
			worker._grounded_heading_handoff = false
	if stable_work and worker.action_progress > .545 and worker.action_progress < .565 and "--tool-debug" in OS.get_cmdline_user_args():
		print("CONTRAPTION_CONTACT_POSE action=",worker.action," side=",worker.work_foot_side," gap=",(worker.foot_grip_transform.origin+worker.foot_grip_transform.basis.y*(.035+worker.foot_tool_span())).distance_to(worker.work_point())," toe_parent=",sk.get_bone_parent(_toes[worker.work_foot_side])," ankle=",_chains[worker.work_foot_side][2]," origin=",_work_origin," grip=",worker.foot_grip_transform.origin," target=",worker.work_point())
	# Head cargo stays on the evaluated cube, including its supported sway.
	# Physics callbacks alone can see restored authored poses between modifiers.
	worker._update_head(evaluated_root)
	if worker.head_leap: worker.head_leap.capture_evaluated(sk)
	evaluated_visual_com = _posed_center_of_mass(sk)
	if worker.ragdoll: worker.ragdoll.remember_pose()
	if manipulation:
		var side: int = worker.work_foot_side
		var root := sk.get_bone_global_pose(0)
		var foot := sk.get_bone_global_pose(_chains[side][2])
		_manipulation_snapshot.side = side
		_manipulation_snapshot.sole = root.affine_inverse()*(foot*Vector3(0,_ankle_height[side],0))
		_manipulation_snapshot.basis = root.basis.inverse()*foot.basis
		var support_side: int = 1-side
		var support_foot := sk.get_bone_global_pose(_chains[support_side][2])
		_manipulation_snapshot.support_sole = root.affine_inverse()*(support_foot*Vector3(0,_ankle_height[support_side],0))
		_manipulation_snapshot.support_basis = root.basis.inverse()*support_foot.basis
		if worker.back_tool: worker.back_tool.tag_fitting_snapshot(_manipulation_snapshot)
	# Optional hello admission observes this completed native publication,
	# after real idle-step planning, both sole solves and tool/head ownership.
	if worker.personality: worker.personality.pose_published()

func _continue_head_root(sk: Skeleton3D, delta: float) -> void:
	var root := sk.get_bone_global_pose(0)
	if worker.head_leap: root = worker.head_leap.grounded_stunt_root(self,sk,root)
	var desired: Transform3D = sk.global_transform*root
	var previous: Transform3D = worker.global_transform*evaluated_worker.affine_inverse()*evaluated_root
	var before := previous.basis.get_rotation_quaternion().normalized()
	var after := desired.basis.get_rotation_quaternion().normalized()
	var relative := before.inverse()*after
	var angle := 2.0*atan2(Vector3(relative.x,relative.y,relative.z).length(),absf(relative.w))
	var position: Vector3 = previous.origin.move_toward(desired.origin,delta*.9)
	var rotation := before.slerp(after,minf(delta*6.0/maxf(angle,.00001),1.0)).normalized()
	_head_root_matches = position.distance_to(desired.origin)<.002 and angle<=delta*6.0+.001
	sk.set_bone_global_pose(0,sk.global_transform.affine_inverse()*Transform3D(Basis(rotation),position))
	_capture_head_authored_joints(sk)

func _capture_head_authored_joints(sk: Skeleton3D) -> void:
	# Keep this evaluation's ordinary authored frames before any IK refinement.
	# Their finite axial twist is also part of the eventual gait handoff.
	for side in 2:
		var chain: Array = _chains[side]
		var upper: Transform3D = sk.global_transform*sk.get_bone_global_pose(chain[0])
		var lower: Transform3D = sk.global_transform*sk.get_bone_global_pose(chain[1])
		var ankle: Transform3D = sk.global_transform*sk.get_bone_global_pose(chain[2])
		_head_authored_upper[side] = upper.basis
		_head_authored_lower[side] = lower.basis
		_head_authored_upper_axes[side] = (lower.origin-upper.origin).normalized()
		_head_authored_lower_axes[side] = (ankle.origin-lower.origin).normalized()

func _continue_head_soles(sk: Skeleton3D, local_inv: Transform3D, delta: float) -> void:
	_head_soles_match = true
	_head_joints_match = true
	for side in 2:
		var chain: Array = _chains[side]
		var foot := sk.get_bone_global_pose(chain[2])
		var offset := Vector3(0,_ankle_height[side],0)
		var requested: Vector3 = sk.global_transform*(foot*offset)
		var previous: Vector3 = evaluated_soles[side]+worker.ground_velocity*delta
		var sole: Vector3 = previous.move_toward(requested,minf(.045,delta*5.4))
		var before := evaluated_ankles[side].get_rotation_quaternion().normalized()
		var after := (sk.global_basis*foot.basis).get_rotation_quaternion().normalized()
		var relative := before.inverse()*after
		var angle := 2.0*atan2(Vector3(relative.x,relative.y,relative.z).length(),absf(relative.w))
		var world_basis := Basis(before.slerp(after,minf(delta*6.0/maxf(angle,.00001),1.0)).normalized())
		var basis: Basis = sk.global_basis.inverse()*world_basis
		var hit := _walk_ground(sole)
		if not hit.is_empty():
			# A native surface entering the return column cannot replace the last
			# actual lower sole at once. Keep that clear column before raising.
			if hit.normal.dot(sole-hit.position)<-.001 and hit.normal.dot(hit.position-previous)>.025:
				var lower := _walk_ground(previous)
				if not lower.is_empty() and hit.normal.dot(hit.position-lower.position)>.025:
					sole.x = previous.x
					sole.z = previous.z
					hit = lower
			sole += hit.normal*maxf(-hit.normal.dot(sole-hit.position),0.0)
			# The current native hip may still be above a descending landing.
			# Preserve the real lateral column until this finite leg can reach it.
			var hip: Vector3 = sk.global_transform*sk.get_bone_global_pose(chain[0]).origin
			var ankle: Vector3 = sole-world_basis*offset
			var horizontal: Vector3 = (ankle-hip).slide(hit.normal)
			var reach: float = worker._leg_lengths[side]-.012
			if horizontal.length_squared()<reach*reach:
				var lowest := -sqrt(reach*reach-horizontal.length_squared())
				sole += hit.normal*maxf(lowest-hit.normal.dot(ankle-hip),0.0)
			_terrain_points[side] = hit.position
			_sole_normals[side] = hit.normal
		sole = _bounded_head_sole(sk,side,evaluated_soles[side],sole,basis,minf(.045,delta*5.4))
		_solve(sk,chain[0],chain[1],chain[2],local_inv*sole-basis*offset,1.0,basis)
		var actual: Vector3 = sk.global_transform*(sk.get_bone_global_pose(chain[2])*offset)
		_head_soles_match = _head_soles_match and actual.distance_to(requested)<.002 and angle<=delta*6.0+.001
		# Only the final finite leg on its actually observed support is a plant.
		# No captured elevated foot may fund the native supported handoff.
		_target_valid[side] = not hit.is_empty() and actual.distance_to(hit.position)<.003
		evaluated_grounded[side] = _target_valid[side]
		_targets[side] = actual
		if _target_valid[side]:
			_support[side] = weakref(hit.collider)
			_support_rids[side] = hit.rid
			if hit.collider is Node3D: _support_local[side] = hit.collider.to_local(actual)
		for bone: int in [chain[0],chain[1]]: _gait_rotations[bone] = sk.get_bone_pose_rotation(bone)

func _head_return_pole(side: int, hip: Vector3, target: Vector3, requested_pole: Vector3 = Vector3.INF) -> Vector3:
	var old_ankle: Vector3 = evaluated_soles[side]-evaluated_ankles[side]*Vector3(0,_ankle_height[side],0)
	var old_axis: Vector3 = (old_ankle-evaluated_hips[side]).normalized()
	var axis: Vector3 = (target-hip).normalized()
	var previous: Vector3 = (evaluated_knees[side]-evaluated_hips[side]).slide(old_axis).normalized()
	# Every refinement transports the SAME preceding evaluated plane, then
	# spends the SAME per-evaluation budget around its current finite leg axis.
	# Turning a raw 3D pole before projecting can instead cross the axis and
	# flip the actual knee plane by half a turn.
	var transported: Vector3 = previous if old_axis.dot(axis)<-.99999 else Quaternion(old_axis,axis)*previous
	transported = transported.slide(axis).normalized()
	var wanted: Vector3 = (requested_pole if requested_pole.is_finite() else -worker._model.global_basis.z).slide(axis)
	if wanted.length_squared()<.00001: return transported
	wanted = wanted.normalized()
	var sine: float = axis.dot(transported.cross(wanted))
	var cosine: float = clampf(transported.dot(wanted),-1.0,1.0)
	var angle: float = atan2(sine,cosine)
	if absf(sine)<.000001 and cosine<0.0:
		var outward: Vector3 = worker._model.global_basis.x*(-1.0 if side==0 else 1.0)
		angle = PI if axis.cross(transported).dot(outward)>=0.0 else -PI
	return transported.rotated(axis,clampf(angle,-_head_pose_delta*6.0,_head_pose_delta*6.0)).normalized()

func _recover_head_joint_twist(sk: Skeleton3D, bone: int, axis: Vector3, wanted: Basis) -> void:
	var pose := sk.get_bone_global_pose(bone)
	var current: Basis = sk.global_basis*pose.basis
	var before := current.get_rotation_quaternion().normalized()
	var after := wanted.get_rotation_quaternion().normalized()
	var relative := after*before.inverse()
	if relative.w<0.0: relative = -relative
	var twist := 2.0*atan2(Vector3(relative.x,relative.y,relative.z).dot(axis),relative.w)
	var previous: Quaternion = _head_joint_rotations.get(bone,before)
	var from_previous := previous.inverse()*before
	var turn := 2.0*atan2(Vector3(from_previous.x,from_previous.y,from_previous.z).length(),absf(from_previous.w))
	# Spend only the remaining WORLD joint budget after its analytic swing.
	# Axial recovery leaves both solved endpoints and the knee plane unchanged.
	var limit := maxf(_head_pose_delta*6.0-turn,0.0)
	var recovered := Basis(Quaternion(axis,clampf(twist,-limit,limit)))*current
	pose.basis = sk.global_basis.inverse()*recovered
	sk.set_bone_global_pose(bone,pose)
	var remaining := recovered.get_rotation_quaternion().normalized().inverse()*after
	var remaining_angle := 2.0*atan2(Vector3(remaining.x,remaining.y,remaining.z).length(),absf(remaining.w))
	_head_joints_match = _head_joints_match and remaining_angle<.001

func _bounded_head_sole(sk: Skeleton3D, side: int, previous: Vector3, desired: Vector3, basis: Basis, step: float) -> Vector3:
	var chain: Array = _chains[side]
	var hip := sk.get_bone_global_pose(chain[0]).origin
	var knee := sk.get_bone_global_pose(chain[1]).origin
	var ankle := sk.get_bone_global_pose(chain[2]).origin
	var upper: float = hip.distance_to(knee)
	var lower: float = knee.distance_to(ankle)
	var inverse := sk.global_transform.affine_inverse()
	var offset := basis*Vector3(0,_ankle_height[side],0)
	# Limit the result of the same finite geometry, not merely its requested
	# target: native hip travel can otherwise add a reach correction afterward.
	var wanted: Vector3 = LegGeometry.two_link(hip,inverse*desired-offset,upper,lower,Vector3.FORWARD,.015,.012,Vector3.FORWARD).foot
	wanted = sk.global_transform*(wanted+offset)
	if wanted.distance_to(previous)<=step: return wanted
	var start: Vector3 = LegGeometry.two_link(hip,inverse*previous-offset,upper,lower,Vector3.FORWARD,.015,.012,Vector3.FORWARD).foot
	start = sk.global_transform*(start+offset)
	if start.distance_to(previous)>=step: return start
	# Both endpoints lie in this leg's reach ball. Their continuous segment
	# remains reachable; choose its last point inside the actual sole budget.
	var direction: Vector3 = wanted-start
	var relative: Vector3 = start-previous
	var squared: float = direction.length_squared()
	if squared<.00000001: return start
	var projection: float = relative.dot(direction)
	var discriminant: float = maxf(projection*projection-squared*(relative.length_squared()-step*step),0.0)
	var progress: float = clampf((-projection+sqrt(discriminant))/squared,0.0,1.0)
	return start.lerp(wanted,progress)

func _head_work_joint_turn(sk: Skeleton3D, side: int, hip: Vector3, ankle: Vector3, upper: float, lower: float, requested_pole: Vector3) -> float:
	var pole: Vector3 = sk.global_basis.inverse()*_head_return_pole(side,sk.global_transform*hip,sk.global_transform*ankle,requested_pole)
	var solution := LegGeometry.two_link(hip,ankle,upper,lower,pole,.015,.012,Vector3.FORWARD)
	var previous_ankle: Vector3 = evaluated_soles[side]-evaluated_ankles[side]*Vector3(0,_ankle_height[side],0)
	var old_upper: Vector3 = (evaluated_knees[side]-evaluated_hips[side]).normalized()
	var old_lower: Vector3 = (previous_ankle-evaluated_knees[side]).normalized()
	var new_upper: Vector3 = (sk.global_basis*(solution.knee-hip)).normalized()
	var new_lower: Vector3 = (sk.global_basis*(solution.foot-solution.knee)).normalized()
	var qa := Quaternion(old_upper,new_upper)
	var qb := Quaternion(qa*old_lower,new_lower)*qa
	return maxf(2.0*atan2(Vector3(qa.x,qa.y,qa.z).length(),absf(qa.w)),2.0*atan2(Vector3(qb.x,qb.y,qb.z).length(),absf(qb.w)))

func _bounded_head_work_target(sk: Skeleton3D, side: int, hip: Vector3, target: Vector3, upper: float, lower: float, basis: Basis, requested_pole: Vector3) -> Vector3:
	# Near full extension a short Cartesian return can still fold its knee
	# quickly. Predict the SAME finite analytic solve and keep the farthest
	# point on that endpoint path within the existing WORLD joint budget.
	var budget: float = _head_pose_delta*6.0
	if _head_work_joint_turn(sk,side,hip,target,upper,lower,requested_pole)<=budget: return target
	var offset := basis*Vector3(0,_ankle_height[side],0)
	var previous := _bounded_head_sole(sk,side,evaluated_soles[side],evaluated_soles[side],basis,minf(.045,_head_pose_delta*5.4))
	var start: Vector3 = sk.global_transform.affine_inverse()*previous-offset
	# Native hip motion remains authoritative; never extend a leg to restore
	# an unreachable old endpoint. Its closest actual finite pose still wins.
	if _head_work_joint_turn(sk,side,hip,start,upper,lower,requested_pole)>=budget: return start
	var low := 0.0
	var high := 1.0
	for iteration in 12:
		var middle: float = (low+high)*.5
		var candidate: Vector3 = start.lerp(target,middle)
		if _head_work_joint_turn(sk,side,hip,candidate,upper,lower,requested_pole)<=budget: low=middle
		else: high=middle
	return start.lerp(target,low)

func _update_work_pole_return(manipulation: bool) -> void:
	# Only these six actual work clips arm the handoff. An interrupted clip
	# may exhaust its sole-release dictionary before the first idle tick.
	if manipulation and WORK_TIMING.has(worker.action):
		_work_return_armed = true
		_work_return_active = false
	elif worker.action in ["","interrupted","place","brace"]:
		if _work_return_armed:
			_work_return_active = true
			_work_return_armed = false
	else:
		_work_return_armed = false
		_work_return_active = false

func _finish_work_pole_return() -> void:
	if not _work_return_active or not worker.action.is_empty() or not _work_release.is_empty(): return
	for side in 2:
		var ankle: Vector3 = evaluated_soles[side]-evaluated_ankles[side]*Vector3(0,_ankle_height[side],0)
		var axis: Vector3 = (ankle-evaluated_hips[side]).normalized()
		var plane: Vector3 = (evaluated_knees[side]-evaluated_hips[side]).slide(axis)
		var wanted: Vector3 = (-worker._model.global_basis.z).slide(axis)
		if plane.length_squared()<.00001 or wanted.length_squared()<.00001 or plane.normalized().angle_to(wanted.normalized())>=.001: return
	_work_return_active = false
	# Both actual knees now agree with ordinary gait. Retire the older raw
	# direction handoff too, so its unprojected pole cannot reclaim the solve.
	_travel_pole_handoff = false

func _update_travel_pole_handoff(delta: float) -> void:
	var releasing: bool = not _work_release.is_empty() or _head_gait_continuation
	var travelling: bool = worker.action.is_empty() and (releasing or worker._animation.current_animation in ["wk_idle","wk_walkcycle","work/carry","work/run"])
	if not travelling or not evaluated_valid:
		_travel_pole_handoff = false
		_travel_tool_handoff = false
		_travel_tool_settle_time = 0.0
		return
	if releasing and worker.tool_foot_occupied(): _travel_tool_handoff = true
	if not _travel_pole_handoff and not releasing: return
	var starting := not _travel_pole_handoff
	_travel_pole_handoff = true
	var matched := true
	for side in 2:
		# Recover the preceding actual bend, including its real ankle offset.
		# Work/acrobatic poses stay authored; only their action-empty departure
		# turns the finite knee plane toward the eye face. Soles are unchanged.
		var ankle: Vector3 = evaluated_soles[side]-evaluated_ankles[side]*Vector3(0,_ankle_height[side],0)
		var axis := (ankle-evaluated_hips[side]).normalized()
		var previous: Vector3 = evaluated_knees[side]-evaluated_hips[side] if starting else _travel_poles[side]
		previous = previous.slide(axis).normalized() if starting else previous.normalized()
		# Blend a WORLD direction, then let each final solve project it onto
		# its current hip-to-ankle axis. Reprojecting the stored direction onto
		# yesterday's moving axis would add an unbounded turn before the cap.
		var wanted: Vector3 = (-worker._model.global_basis.z).normalized()
		if previous.length_squared()<.01: previous = wanted
		if wanted.length_squared()<.01: wanted = previous
		var angle := acos(clampf(previous.dot(wanted),-1.0,1.0))
		var turn_axis := previous.cross(wanted)
		if turn_axis.length_squared()<.000001:
			# Opposite poles need a stable side: each knee recovers outward,
			# avoiding an arbitrary quaternion half-turn through the other leg.
			turn_axis = axis
			var outward: Vector3 = worker._model.global_basis.x*(-1.0 if side==0 else 1.0)
			if turn_axis.cross(previous).dot(outward)<0.0: turn_axis = -turn_axis
		var step := minf(angle,delta*6.0)
		_travel_poles[side] = previous.rotated(turn_axis.normalized(),step).normalized() if angle>.00001 else wanted
		matched = matched and angle-step<.00001
	# Keep the corrected pole while a legacy release still owns the targets;
	# ordinary Cartesian gait then uses the same model-facing forward pole.
	if matched and not releasing: _travel_pole_handoff = false

func native_support_rid(side: int) -> RID:
	# Invalid plants cannot reuse their old RID. Native identities are observed
	# again after loading/recovery and are never persisted in worker JSON.
	if not _target_valid[side] or not is_instance_valid(worker) or not worker.is_inside_tree(): return RID()
	var support: Object = _support[side].get_ref()
	var rid: RID = _support_rids[side]
	if not rid.is_valid() or not is_instance_valid(support) or not support is Node3D \
		or not support.is_inside_tree() or support.is_queued_for_deletion(): return RID()
	if support is PhysicsBody3D:
		# Retain the original moving-node identity, transform and velocity path.
		if support.get_rid() != rid: return RID()
	elif not support is Terrain3D:
		return RID()
	# A Terrain3D owner may outlive a replaced native chunk. Prove the SAME
	# current native body before asking the server about a possibly stale RID.
	var point: Vector3 = _targets[side]
	_support_query.from = Vector3(point.x, maxf(point.y+.5, worker.global_position.y+.12), point.z)
	_support_query.to = point-Vector3.UP*.65
	_support_query.collision_mask = 1
	_support_query.exclude = worker.query_exclusions()
	var hit := worker.get_world_3d().direct_space_state.intersect_ray(_support_query)
	if hit.is_empty() or hit.normal.y < .6 or hit.collider != support or hit.rid != rid: return RID()
	if PhysicsServer3D.body_get_space(rid) != worker.get_world_3d().space: return RID()
	if support is Terrain3D and PhysicsServer3D.body_get_mode(rid) != PhysicsServer3D.BODY_MODE_STATIC: return RID()
	return rid

func _walk_ground(point: Vector3) -> Dictionary:
	_terrain_query.from = Vector3(point.x,maxf(point.y+.55,worker.global_position.y+.25),point.z)
	_terrain_query.to = Vector3(point.x,minf(point.y-.8,worker.global_position.y-worker.ride_height-.45),point.z)
	var hit := worker.get_world_3d().direct_space_state.intersect_ray(_terrain_query)
	return hit if not hit.is_empty() and hit.normal.y>.6 else {}


func _stopped_turn_allowed() -> bool:
	return worker.on_ground and _walking_ik and evaluated_valid and worker.action.is_empty() \
		and not worker.has_target and worker.gait_speed<.18 and not worker.carrying \
		and not worker.tool_foot_occupied() and not is_instance_valid(worker.equipped_gun) \
		and not _head_ground_continuation and not _head_work_continuation and not _head_gait_continuation \
		and not _head_landing_continuation and _work_release.is_empty() and _work_entry.is_empty() \
		and not _travel_pole_handoff and not _travel_tool_handoff \
		and not (worker.head_leap and worker.head_leap.active()) \
		and not (worker.back_tool and (worker.back_tool.busy() or worker.back_tool.pose_owned() or worker.back_tool.recovering())) \
		and not (worker.idle_play and (not worker.idle_play.state.is_empty() or worker.idle_play.physical_recovery_pending()))

func _settle_allowed() -> bool:
	# Ordinary free stance: settle/turn steps may lift a sole. Every captured
	# work/head/back/gun/idle-play owner keeps its own plants, and so does a
	# frightened stop (the danger clip takes the legs as the body settles: a
	# settle step it interrupted was left skating along with the cube).
	return worker.on_ground and evaluated_valid and worker.action.is_empty() and worker.fear_time <= 0.0 \
		and not is_instance_valid(worker.equipped_gun) \
		and not _head_ground_continuation and not _head_work_continuation and not _head_gait_continuation \
		and not _head_landing_continuation and _work_release.is_empty() and _work_entry.is_empty() \
		and not _travel_tool_handoff \
		and not (worker.head_leap and worker.head_leap.active()) \
		and not (worker.back_tool and (worker.back_tool.busy() or worker.back_tool.pose_owned() or worker.back_tool.recovering())) \
		and not (worker.portable_gun and worker.portable_gun.handoff_active()) \
		and not (worker.idle_play and (worker.idle_play.state not in ["","run"] or worker.idle_play.physical_recovery_pending()))

func stopped_turn_limit() -> float:
	# Helper heading cap while standing. Settle steps follow the heading, so
	# the cube turns briskly and only slows as a planted leg nears its reach.
	if not gait or not gait.active or not _settle_allowed(): return 6.0
	# The hips never twist far past a planted foot (braided shins): the turn
	# waits for the next step, which lands turned into the new heading.
	if gait.moving: return gait.turn_limit(6.0)
	var limit: float = gait.turn_limit(3.4)
	for side in 2:
		if gait.state[side] != Gait.PLANTED or not evaluated_grounded[side]: continue
		var ankle: Vector3 = evaluated_soles[side]-evaluated_ankles[side]*Vector3(0,_ankle_height[side],0)
		var spare: float = worker._leg_lengths[side]-.012-evaluated_hips[side].distance_to(ankle)
		limit = minf(limit,.6+3.6*smoothstep(.0,.035,spare))
	return limit

func _update_stopped_turn(sk: Skeleton3D, delta: float) -> void:
	_stopped_turn_pose_ready = false
	if not _stopped_turn_allowed():
		_cancel_stopped_turn(false)
		var own_release: bool = _pivot_return_side>=0 and worker.action in ["","interrupted"] \
			and (_work_release.get("side",-1)==1-_pivot_return_side or _work_return_active)
		if _stopped_turn_captured_owner(own_release) or (not own_release and (not worker.feet_work_active() or not is_instance_valid(worker.work_target))):
			_pivot_return_side=-1
			_pivot_work_side=-1
		elif own_release:
			_pivot_work_side=-1
		elif _pivot_return_side==worker.work_foot_side:
			_pivot_return_side=-1
		return
	# Quiet only when the gait's own stance scan proves both soles need no
	# settle step (it replaced the old single idle pivot, incl. turning).
	_stopped_turn_pose_ready = gait.active and gait.quiet and _preceding_grounded[0] and _preceding_grounded[1]

func _cancel_stopped_turn(support_lost: bool) -> void:
	if _pivot_side>=0:
		# A lifted cancelled sole is not a new plant. Its published WORLD
		# pose feeds either normal travel/work entry or the support return.
		_pivot_return_side=_pivot_side
		_pivot_work_side=worker.work_foot_side if worker.feet_work_active() and is_instance_valid(worker.work_target) else -1
		var column := _walk_ground(evaluated_soles[_pivot_side])
		if not column.is_empty() and column.collider is Node3D:
			_pivot_start_support=weakref(column.collider)
			_pivot_start_local=column.collider.to_local(column.position)
			_pivot_rid=column.rid
		_gait_handoff_velocity[_pivot_side]=Vector3.ZERO
		_target_valid[_pivot_side]=false
		if support_lost: _support_rids[_pivot_side]=RID()
	_pivot_side=-1
	_pivot_age=0.0

func _stopped_turn_captured_owner(own_work_return := false) -> bool:
	return _head_ground_continuation or _head_work_continuation or _head_gait_continuation or _head_landing_continuation \
		or (_travel_pole_handoff and not own_work_return) or _travel_tool_handoff \
		or (worker.head_leap and worker.head_leap.active()) \
		or (worker.back_tool and (worker.back_tool.busy() or worker.back_tool.pose_owned() or worker.back_tool.recovering())) \
		or (worker.portable_gun and worker.portable_gun.handoff_active()) \
		or (worker.idle_play and (not worker.idle_play.state.is_empty() or worker.idle_play.physical_recovery_pending()))

func _continue_cancelled_pivot(sk: Skeleton3D, delta: float, manipulation: bool) -> void:
	if _pivot_return_side<0 or not evaluated_valid: return
	var side: int = _pivot_return_side
	# Ordinary Cartesian travel already starts at the published sole. The
	# useful work foot has its existing WORLD _work_entry; Back/Head/Gun
	# keep their own captured poses and original clearance owners.
	# Keep this actual support anchor through the original work-release tail.
	# The first ordinary gait evaluation then owns its same native plant.
	# This original work departure owns the knee plane, not a new sole pose.
	# Every captured Head/Back/Gun/idle/full-tool endpoint still drops the marker.
	var own_return: bool = worker.action in ["","interrupted"] \
		and (_work_release.get("side",-1)==1-side or _work_return_active)
	var captured_owner: bool = _stopped_turn_captured_owner(own_return)
	var own_release: bool = own_return and not _walking_ik
	if not manipulation and worker.action in ["","interrupted"] and not captured_owner:
		# The other foot's original root-relative release can touch the floor
		# before reaching its native plant. Keep that real return unplanted;
		# neither this marker nor ordinary gait may claim a sliding contact.
		var work_side: int = 1-side
		var work_owner: Object = _support[work_side].get_ref()
		var work_foot := sk.get_bone_global_pose(_chains[work_side][2])
		var work_sole: Vector3 = sk.global_transform*(work_foot*Vector3(0,_ankle_height[work_side],0))
		var work_hit := _walk_ground(work_sole)
		var work_planted: bool = _target_valid[work_side] and work_owner is Node3D \
			and work_owner.is_inside_tree() and not work_owner.is_queued_for_deletion() \
			and not work_hit.is_empty() and work_hit.collider==work_owner and work_hit.rid==_support_rids[work_side] \
			and absf(work_hit.normal.dot(work_sole-work_hit.position))<.0005 \
			and work_sole.distance_to(work_owner.to_global(_support_local[work_side]))<.001
		evaluated_grounded[work_side]=evaluated_grounded[work_side] and work_planted
		if _walking_ik:
			# Its existing Cartesian gait owns the final return; retire this
			# actual work return only once the same original anchor is reached.
			if work_planted: _pivot_return_side=-1
			_pivot_work_side=-1
			return
	if (not manipulation and not own_release) or side==worker.work_foot_side or captured_owner:
		_pivot_return_side=-1
		if not manipulation or captured_owner: _pivot_work_side=-1
		return
	var chain: Array = _chains[side]
	var foot := sk.get_bone_global_pose(chain[2])
	var offset := Vector3(0,_ankle_height[side],0)
	var from: Quaternion = evaluated_ankles[side].get_rotation_quaternion().normalized()
	var to: Quaternion = (sk.global_basis*foot.basis).get_rotation_quaternion().normalized()
	foot.basis=sk.global_basis.inverse()*Basis(from.slerp(to,minf(1.0,delta*6.0/maxf(from.angle_to(to),.00001))))
	sk.set_bone_global_pose(chain[2],foot)
	var previous: Vector3 = evaluated_soles[side]+worker.ground_velocity*delta
	var original_column := _walk_ground(previous)
	if original_column.is_empty():
		# No real column can own support. Retain the same finite airborne leg
		# until the original body support/recovery finds terrain or takes over.
		_solve(sk,chain[0],chain[1],chain[2],sk.global_transform.affine_inverse()*previous-foot.basis*offset,1.0,foot.basis)
		evaluated_grounded[side]=false
		_target_valid[side]=false
		worker.stance_valid=false
		return
	var owner: Object = _pivot_start_support.get_ref() if _pivot_start_support else null
	if not owner is Node3D or not owner.is_inside_tree() or owner.is_queued_for_deletion() \
		or original_column.collider!=owner or original_column.rid!=_pivot_rid:
		_solve(sk,chain[0],chain[1],chain[2],sk.global_transform.affine_inverse()*previous-foot.basis*offset,1.0,foot.basis)
		evaluated_grounded[side]=false
		_target_valid[side]=false
		worker.stance_valid=false
		return
	# The released foot lowers onto the real column beneath its captured sole,
	# rather than chasing a new authored standing location and relabelling it
	# as planted each tick. Only the original finite-reach recovery may replant.
	var landing: Vector3 = owner.to_global(_pivot_start_local)
	var reachable := _reachable_plant(sk,side,landing,foot.basis,original_column.normal)
	if reachable.distance_to(landing)>.002:
		var replant := _walk_ground(reachable)
		if not replant.is_empty() and replant.collider==owner and replant.rid==_pivot_rid:
			landing=replant.position
	# A desired endpoint must not rewrite the ankle before the analytic solve
	# measures its original knee-to-ankle segment.
	_blend_gait_handoff(sk,side,sk.global_transform.affine_inverse(),worker.gait_speed,delta,landing)
	foot=sk.get_bone_global_pose(chain[2])
	var sole: Vector3 = sk.global_transform*(foot*offset)
	var hit := _walk_ground(sole)
	var released: bool = _preceding_grounded[side] and sole.distance_to(previous)>.001
	var planted: bool = not released and not hit.is_empty() and hit.collider==owner and hit.rid==_pivot_rid \
		and absf(hit.normal.dot(sole-hit.position))<.0005 and sole.distance_to(landing)<.001
	evaluated_grounded[side]=planted
	_target_valid[side]=planted
	if manipulation and side!=worker.work_foot_side:
		worker.stance_valid=planted
		if planted: worker.stance_point=hit.position
	if not planted: return
	_targets[side]=hit.position
	_support[side]=weakref(hit.collider)
	_support_rids[side]=hit.rid
	_support_local[side]=hit.collider.to_local(hit.position) if hit.collider is Node3D else Vector3.ZERO
	_pivot_start_local=owner.to_local(hit.position)

func _air_allowed() -> bool:
	# Only a plain locomotion flight: actions, a foot-held tool, head/back
	# owners, idle play and water keep their own airborne presentation.
	return worker.action.is_empty() and not worker.tool_foot_occupied() \
		and not (worker.head_leap and worker.head_leap.active()) \
		and not (worker.back_tool and (worker.back_tool.busy() or worker.back_tool.pose_owned())) \
		and not (worker.idle_play and (worker.idle_play.state not in ["","run"] or worker.idle_play.water_support_active() or worker.idle_play.physical_recovery_pending()))

func _air_legs(sk: Skeleton3D) -> void:
	# Solve the flying legs the gait planned (Gait.air): same face-bent
	# two-link solve and fading acting root as on the ground.
	if gait.acting(): sk.set_bone_global_pose(0,gait.acting_root(sk,sk.get_bone_global_pose(0)))
	var local_inv := sk.global_transform.affine_inverse()
	for side in 2:
		var chain: Array = _chains[side]
		var basis: Basis = sk.global_basis.inverse()*gait.out_basis[side]
		_solve(sk,chain[0],chain[1],chain[2],local_inv*gait.out_sole[side]-basis*Vector3(0,_ankle_height[side],0),1.0,basis)
		if _toes[side] >= 0:
			var rest := sk.get_bone_rest(_toes[side]).basis.get_rotation_quaternion()
			var wanted := (Quaternion(gait._toe_axis[side],gait.out_toe[side])*rest).normalized()
			sk.set_bone_pose_rotation(_toes[side],sk.get_bone_pose_rotation(_toes[side]).slerp(wanted,maxf(gait.locomotion_weight,.5)))

func _blend_gait_release(sk: Skeleton3D, manipulation: bool, delta: float) -> void:
	# Owners without their own joint handoff (step, push, pull, ...) read
	# authored clip feet: entered mid-stride that is a one-tick knee snap. Ease
	# their soles in from the gait's last published soles over
	# GAIT_RELEASE_BLEND and re-solve the same face-bent leg (a Cartesian
	# blend, so a sole both owners plant at the same spot never dips). Owners
	# that already filter from _gait_rotations, and a manipulated work foot,
	# keep their own continuity.
	_gait_release_age += delta
	var filtered: bool = worker.action in ["","interrupted","place","brace"]
	var w := smoothstep(0.0, GAIT_RELEASE_BLEND, _gait_release_age)
	var local_inv := sk.global_transform.affine_inverse()
	for side in 2:
		if filtered or (manipulation and side == worker.work_foot_side) or not _gait_release_rotations.has(side): continue
		var chain: Array = _chains[side]
		var released: Array = _gait_release_rotations[side]
		var foot_pose := sk.get_bone_global_pose(chain[2])
		var offset := Vector3(0,_ankle_height[side],0)
		var owner_sole: Vector3 = sk.global_transform*(foot_pose*offset)
		var sole: Vector3 = (released[0] as Vector3).lerp(owner_sole,w)
		var basis: Basis = sk.global_basis.inverse()*Basis((released[1] as Quaternion).slerp((sk.global_basis*foot_pose.basis).get_rotation_quaternion(),w))
		_solve(sk,chain[0],chain[1],chain[2],local_inv*sole-basis*offset,1.0,basis)
	if _gait_release_age >= GAIT_RELEASE_BLEND: _gait_release_rotations.clear()

func _terrain_walk_leg(sk: Skeleton3D, side: int, local_inv: Transform3D, _walking: bool, _speed: float, _phase: float, delta: float) -> void:
	# Ordinary locomotion: the gait planner owns the sole, its yaw/roll and the
	# plant/support bookkeeping; this solves the finite leg and publishes it.
	var chain: Array = _chains[side]
	var hip: Vector3 = sk.global_transform*sk.get_bone_global_pose(chain[0]).origin
	var sole: Vector3 = gait.out_sole[side]
	var hit: Dictionary = gait.out_hit[side]
	var planted: bool = gait.out_planted[side]
	var world_basis: Basis = gait.out_basis[side]
	var basis := sk.global_basis.inverse()*world_basis
	var ankle_offset: Vector3 = world_basis*Vector3(0,_ankle_height[side],0)
	if planted and gait.stance_age[side] < .001:
		var contact_offset: Vector3 = sole-ankle_offset-hip
		# A contact the shown knee is still far from (the swing's knee rate limit
		# held it back while the body dropped) keeps reaching instead of popping.
		var knee_gap: float = absf(gait.knee_flex(side,contact_offset.length())-gait.knee_prev[side]) if is_finite(gait.knee_prev[side]) else 0.0
		if (contact_offset.length()>worker._leg_lengths[side]-.014 or knee_gap>deg_to_rad(10.0)) and gait.defer_contact(side,contact_offset,knee_gap):
			planted = false
			hit = {}
	if not planted:
		gait.validate_landing(side,hip)
		# An airborne sole keeps its own column and rises until the leg can
		# reach it (down-steps, descents); clamping along the leg would drag
		# it back toward the hip. Planted soles stay exact or are re-planned.
		# A swing keeps a little knee flex (no whip through full extension),
		# eased in from the stance's own reach so the lift-off knee folds
		# continuously instead of jumping to the swing margin and holding.
		var t_swing: float = gait.t[side]
		var reach: float = worker._leg_lengths[side]-.012-.018*smoothstep(0.0,.3,t_swing)*(1.0-smoothstep(.7,1.0,t_swing))
		var hip_to_ankle: Vector3 = sole-ankle_offset-hip
		var horizontal := hip_to_ankle.slide(Vector3.UP)
		if horizontal.length_squared()<reach*reach:
			sole.y += maxf(-sqrt(reach*reach-horizontal.length_squared())-hip_to_ankle.y,0.0)
		if t_swing>.5 and gait.landing[side].y<gait._swing_start(side).y-.05:
			# Stepping down: late in the swing the leg reaches forward and down
			# for the lower tread (knee <= ~75 deg) instead of holding the heel
			# folded up high and stabbing down, wherever the ground under the
			# reaching sole is clear (past the edge).
			var cap: float = lerpf(PI,deg_to_rad(75.0),smoothstep(.5,.75,t_swing))
			var reach_to: Vector3 = sole-ankle_offset-hip
			var reach_span: float = reach_to.length()
			if reach_span>.001 and gait.knee_flex(side,reach_span)>cap:
				var stretched: Vector3 = hip+reach_to/reach_span*gait.knee_span(side,cap)+ankle_offset
				# The whole foot must be past the edge: its sole point and both
				# ends (toe and heel) clear the ground under them.
				if gait.foot_clear(stretched,gait.foot_along(side,world_basis),.015): sole = stretched
		# An airborne foot straightens its knee at most ~9 deg a tick (the
		# planned arc can ask for more as the leg nears extension: a whip). A
		# contact the limited knee has not reached yet keeps reaching (deferred
		# below), so the plant is still exact. Extension is always limited (it
		# only keeps the sole nearer the hip); the fold only over clear ground.
		var previous_flex: float = gait.knee_prev[side]
		if is_finite(previous_flex):
			var to: Vector3 = sole-ankle_offset-hip
			var span: float = to.length()
			var flex: float = gait.knee_flex(side,span)
			var limit: float = deg_to_rad(9.0)
			if span>.001 and flex<previous_flex-limit:
				sole = hip+to/span*gait.knee_span(side,previous_flex-limit)+ankle_offset
			elif span>.001 and flex>previous_flex+limit and gait.t[side]<.75:
				# The lift-off fold is eased the same way, but only where the eased
				# foot still clears the ground under it (never pressed into a rise).
				# A planned climb onto a riser folds deliberately faster (16 deg).
				var fold_limit: float = limit
				if not gait._planar[side] and gait.landing[side].y>gait._swing_start(side).y+.08: fold_limit = deg_to_rad(16.0)
				var eased: Vector3 = hip+to/span*gait.knee_span(side,previous_flex+fold_limit)+ankle_offset
				var along: Vector3 = gait.foot_along(side,world_basis)
				if gait.foot_clear(eased,along): sole = eased
				else:
					# A riser met late (a wall climbed at a run) needs a faster fold:
					# only as much faster as keeps the sole clear of it, not the whole
					# re-planned arc in one tick.
					var lo: float = previous_flex+fold_limit
					var hi: float = flex
					for i in 4:
						var mid: float = (lo+hi)*.5
						if gait.foot_clear(hip+to/span*gait.knee_span(side,mid)+ankle_offset,along): hi = mid
						else: lo = mid
					sole = hip+to/span*gait.knee_span(side,hi)+ankle_offset
		if evaluated_valid and gait.speed<=2.4:
			# Walking feet keep the gait's calm speed ceiling here too, so the
			# easing above never adds a catch-up jump on top of a fast swing.
			var shown: Vector3 = evaluated_soles[side]+worker.ground_velocity*delta
			# A foot-held tool's sole is shown with its clearance lift/shift on
			# top: limit from the sole the gait asked for, or that bounded lift
			# would ratchet the swing up a little more every tick.
			if worker.tool_foot_occupied() and side==worker.tool_foot_side() and gait.shown_sole[side].is_finite():
				shown = gait.shown_sole[side]+worker.ground_velocity*delta
			sole = shown+(sole-shown).limit_length(maxf(5.8*delta,.001))
	elif gait.stance_age[side] < .001:
		# A contact made this tick is planted only where this hip can really
		# put the sole: slide it toward the hip on its own support if the
		# predicted footfall ended up beyond reach (steep descents).
		var reach: float = worker._leg_lengths[side]-.010
		var offset: Vector3 = sole-ankle_offset-hip
		if offset.length()>reach and absf(offset.y)<reach:
			var horizontal := offset.slide(Vector3.UP).limit_length(sqrt(reach*reach-offset.y*offset.y))
			# At most a few centimetres: a longer slide is a visible teleport
			# (the leg is then shown a little short of the plant instead).
			var flat_offset := offset.slide(Vector3.UP)
			horizontal = flat_offset+(horizontal-flat_offset).limit_length(.035)
			var closer: Dictionary = gait._ground(Vector3(hip.x+horizontal.x,sole.y,hip.z+horizontal.z)+ankle_offset)
			if not closer.is_empty() and closer.collider is Node3D:
				hit = closer
				sole = closer.position
				gait.replant(side,closer,sole)
	if evaluated_valid and _head_ground_continuation:
		# Head landing/preparation keeps its finite sole budget.
		sole = _bounded_head_sole(sk,side,evaluated_soles[side],sole,basis,minf(.045,delta*5.4))
	if not hit.is_empty():
		_terrain_points[side] = hit.position
		_sole_normals[side] = hit.normal
	_walk_swing_phase[side] = -1.0 if planted else gait.t[side]
	_plant_weights[side] = 1.0 if planted else 0.0
	# Legacy riser-anticipation fields now report the planner's look-ahead
	# obstacle lift for this swing (0 while planted).
	_step_lifts[side] = 0.0 if planted else gait._clear_lift[side]
	_step_ahead[side] = _step_lifts[side]
	_target_valid[side] = planted and not hit.is_empty() and hit.collider is Node3D
	# A planted sole publishes its contact point, not the heel-peeled sole
	# shown during push-off (the toe pad stays where it planted); the sole is
	# then "grounded" only while it is really within 2 cm of that plant.
	var plant: Vector3 = sole-gait._roll_off[side] if planted else sole
	if _target_valid[side]:
		_support[side] = weakref(hit.collider)
		_support_rids[side] = hit.rid
		_support_local[side] = hit.collider.to_local(plant)
	_targets[side] = plant
	var tool_foot: bool = worker.tool_foot_occupied() and side==worker.tool_foot_side()
	var held_lift: float = _held_lift if tool_foot else 0.0
	var held_shift: Vector3 = _held_shift if tool_foot else Vector3.ZERO
	var normal: Vector3 = hit.normal if not hit.is_empty() else Vector3.UP
	var requested: Vector3 = sole+normal*held_lift+held_shift
	if tool_foot and evaluated_valid:
		# The retained tool's own owners may have held this foot elsewhere
		# (a whole-tool return); resuming from there keeps the tool foot's
		# finite toe budget instead of snapping the knee in one tick.
		var shown_prev: Vector3 = evaluated_soles[side]+worker.ground_velocity*delta
		requested = shown_prev+(requested-shown_prev).limit_length(maxf(5.4*delta,.001))
	_solve(sk,chain[0],chain[1],chain[2],local_inv*requested-basis*Vector3(0,_ankle_height[side],0),1.0,basis)
	_gait_rotations[chain[0]] = sk.get_bone_pose_rotation(chain[0])
	_gait_rotations[chain[1]] = sk.get_bone_pose_rotation(chain[1])
	# The knee the gait's own sole asks for: a foot-held tool's bounded
	# clearance lift/shift on top is not part of the swing/contact pose the
	# rate limits and the contact deferral compare against.
	gait.knee_prev[side] = gait.knee_flex(side,(sole-ankle_offset-hip).length())
	evaluated_grounded[side] = planted and _target_valid[side] and held_lift<.01
	gait.requested[side] = requested
	gait.shown_sole[side] = sole
	_gait_sides[side] = true
	if _toes[side] < 0: return
	if tool_foot:
		var toe := sk.get_bone_global_pose(_toes[side])
		var axis: Vector3 = (-worker._model.global_basis.z*.75+Vector3.UP*.65).normalized()
		toe.basis = Basis(Quaternion(toe.basis.y.normalized(),(sk.global_basis.inverse()*axis).normalized()))*toe.basis
		sk.set_bone_global_pose(_toes[side],toe)
	elif gait.locomotion_weight > .001:
		# Toe push-off curl and mid-swing extension, independent of the clips.
		var rest := sk.get_bone_rest(_toes[side]).basis.get_rotation_quaternion()
		var wanted := (Quaternion(gait._toe_axis[side],gait.out_toe[side])*rest).normalized()
		sk.set_bone_pose_rotation(_toes[side],sk.get_bone_pose_rotation(_toes[side]).slerp(wanted,gait.locomotion_weight))

func _blend_gait_handoff(sk: Skeleton3D, side: int, local_inv: Transform3D, speed: float, delta: float, desired_sole := Vector3.INF) -> void:
	var chain: Array = _chains[side]
	var foot := sk.get_bone_global_pose(chain[2])
	var offset := Vector3(0,_ankle_height[side],0)
	var desired: Vector3 = desired_sole if desired_sole.is_finite() else sk.global_transform*(foot*offset)
	# Angular blending alone cannot smooth a plant that replaces its world
	# endpoint. Follow the actual evaluated sole through that handoff after
	# terrain projection, then solve the same finite leg on its own native column.
	var previous: Vector3 = evaluated_soles[side]+worker.ground_velocity*delta
	var wanted := ((desired-previous)/maxf(delta,.0001)).limit_length(maxf(speed*2.2+.4,1.2))
	_gait_handoff_velocity[side] = _gait_handoff_velocity[side].move_toward(wanted,delta*18.0)
	var next: Vector3 = previous+_gait_handoff_velocity[side]*delta
	_terrain_query.from = Vector3(next.x,maxf(next.y+.5,worker.global_position.y+.12),next.z)
	_terrain_query.to = next-Vector3.UP*.65
	var terrain := worker.get_world_3d().direct_space_state
	var surface := terrain.intersect_ray(_terrain_query)
	if surface.is_empty() or surface.normal.y < .6:
		if _head_gait_continuation:
			# A released swing is still the same evaluated finite leg. Losing
			# its support column does not restore a different authored endpoint.
			_solve(sk,chain[0],chain[1],chain[2],local_inv*next-foot.basis*offset,1.0,foot.basis)
			evaluated_grounded[side] = false
		return
	if surface.normal.dot(next-surface.position) < -.001 and surface.normal.dot(surface.position-previous) > .025:
		# A bounded swing cannot pass through a riser while it is still low.
		# Raise over the real lower column before releasing toward the upper top.
		var lower: Vector3 = _previous_terrain_points[side]
		var column: Vector3 = previous
		if lower.is_finite() and surface.normal.dot(surface.position-lower) > .025 and (lower-previous).slide(surface.normal).length() <= .06:
			column = lower
		next.x = column.x
		next.z = column.z
		_terrain_query.from = Vector3(next.x,maxf(next.y+.5,worker.global_position.y+.12),next.z)
		_terrain_query.to = next-Vector3.UP*.65
		surface = terrain.intersect_ray(_terrain_query)
		if surface.is_empty() or surface.normal.y < .6: return
	next += surface.normal*maxf(-surface.normal.dot(next-surface.position),0.0)
	# Keep this clear column instead of letting a reach clamp move the toe
	# through the riser. The same finite leg can lift as the native hip rises.
	var hip: Vector3 = sk.global_transform*sk.get_bone_global_pose(chain[0]).origin
	var ankle: Vector3 = next-sk.global_basis*foot.basis*offset
	var horizontal: Vector3 = (ankle-hip).slide(surface.normal)
	var reach: float = worker._leg_lengths[side]-.02
	if horizontal.length_squared() < reach*reach:
		var minimum := -sqrt(reach*reach-horizontal.length_squared())
		next += surface.normal*maxf(minimum-surface.normal.dot(ankle-hip),0.0)
	_solve(sk,chain[0],chain[1],chain[2],local_inv*next-foot.basis*offset,1.0,foot.basis)
	for bone: int in [chain[0],chain[1]]: _gait_rotations[bone] = sk.get_bone_pose_rotation(bone)
	_terrain_points[side] = surface.position
	_sole_normals[side] = surface.normal
	if surface.normal.dot(next-surface.position) > .035: evaluated_grounded[side] = false

func _project_sole_above_terrain(sk: Skeleton3D, side: int, local_inv: Transform3D, delta: float, bounded_return := false) -> void:
	var chain: Array = _chains[side]
	var foot := sk.get_bone_global_pose(chain[2])
	var offset := Vector3(0,_ankle_height[side],0)
	var sole: Vector3 = sk.global_transform*(foot*offset)
	var normal: Vector3 = _sole_normals[side]
	var observed: Vector3 = _terrain_points[side]
	# A held plant and its authored/smoothed leg can have different horizontal
	# positions at a riser. Check the rendered sole's actual column before
	# projecting it; the older ray may still describe the lower tread.
	_terrain_query.from = Vector3(sole.x,maxf(sole.y+.5,worker.global_position.y+.12),sole.z)
	_terrain_query.to = sole-Vector3.UP*.4
	var surface := worker.get_world_3d().direct_space_state.intersect_ray(_terrain_query)
	if not surface.is_empty() and surface.normal.y > .6:
		if bounded_return and surface.normal.dot(sole-surface.position)>=-.001:
			# A captured fitting sole can already clear the new top while its
			# earlier target still describes the lower tread. Publish this real
			# column without imposing an unnecessary sideways edge recovery.
			_terrain_points[side] = surface.position
			_sole_normals[side] = surface.normal
			return
		# A manipulation entry can reach this final-column probe before its
		# earlier work-foot solve observed terrain. INF denotes that missing
		# plane; only this current real ray or a finite older tread can own it.
		var lower: Vector3 = observed if observed.is_finite() else surface.position
		if _previous_terrain_points[side].is_finite() and normal.dot(lower-_previous_terrain_points[side]) > .025: lower = _previous_terrain_points[side]
		if normal.dot(surface.position-lower) > .025 or evaluated_valid and normal.dot(surface.position-evaluated_soles[side]) > .025:
			if evaluated_valid:
				# Keep the last real lower-tread sole when a smoothed stride
				# first crosses a high edge. Its own column must still observe
				# that lower surface; the finite leg releases naturally as the
				# body advances, rather than folding onto the new top at once.
				var previous_sole: Vector3 = evaluated_soles[side]+worker.ground_velocity*delta
				_terrain_query.from = Vector3(previous_sole.x,maxf(previous_sole.y+.5,worker.global_position.y+.12),previous_sole.z)
				_terrain_query.to = previous_sole-Vector3.UP*.4
				var previous_surface := worker.get_world_3d().direct_space_state.intersect_ray(_terrain_query)
				if not previous_surface.is_empty() and previous_surface.normal.y > .6 and normal.dot(surface.position-previous_surface.position) > .025 and previous_sole.distance_to(sole) < .45:
					previous_sole += previous_surface.normal*maxf(-previous_surface.normal.dot(previous_sole-previous_surface.position),0.0)
					_solve(sk,chain[0],chain[1],chain[2],local_inv*previous_sole-foot.basis*offset,1.0,foot.basis)
					_terrain_points[side] = previous_surface.position
					_sole_normals[side] = previous_surface.normal
					_target_valid[side] = false
					evaluated_grounded[side] = false
					for bone: int in [chain[0],chain[1]]: _gait_rotations[bone] = sk.get_bone_pose_rotation(bone)
					return
			# A turning or newly moving edge can enter the smoothed sole's
			# column while its real target remains just outside on a lower tread.
			# First return a few centimetres toward that observed clear column,
			# rather than folding the knee onto an unexpected high edge at once.
			var outward: Vector3 = (lower-sole).slide(normal)
			if outward.length_squared() > .000001:
				# Only the captured fitting return uses its original finite sole
				# speed here. Other callers, including Head, keep their exact path.
				var lateral_step := minf(.045,delta*5.4) if bounded_return else .06
				var beside: Vector3 = sole+outward.normalized()*lateral_step
				_solve(sk,chain[0],chain[1],chain[2],local_inv*beside-foot.basis*offset,1.0,foot.basis)
				foot = sk.get_bone_global_pose(chain[2])
				sole = sk.global_transform*(foot*offset)
				_terrain_query.from = Vector3(sole.x,maxf(sole.y+.5,worker.global_position.y+.12),sole.z)
				_terrain_query.to = sole-Vector3.UP*.4
				var clear := worker.get_world_3d().direct_space_state.intersect_ray(_terrain_query)
				if not clear.is_empty() and clear.normal.y > .6: surface = clear
				else:
					evaluated_grounded[side] = false
					_target_valid[side] = false
					_terrain_points[side] = Vector3.INF
					return
				for bone: int in [chain[0],chain[1]]: _gait_rotations[bone] = sk.get_bone_pose_rotation(bone)
		_terrain_points[side] = surface.position
		normal = surface.normal
		_sole_normals[side] = normal
	if not _terrain_points[side].is_finite():
		# No current or earlier actual sole column supplied a plane. Keep this
		# foot unplanted; projecting the missing-plane INF sentinel would create
		# a nonfinite IK target even though the original native rig is finite.
		evaluated_grounded[side] = false
		_target_valid[side] = false
		return
	var gap := normal.dot(sole-_terrain_points[side])
	if gap < -.001:
		# Reproject the actual smoothed sole, retaining its lateral position,
		# finite limb lengths and orientation on this foot's observed surface.
		var target := local_inv*(sole-normal*gap)-foot.basis*offset
		_solve(sk,chain[0],chain[1],chain[2],target,1.0,foot.basis)
		for bone: int in [chain[0],chain[1]]: _gait_rotations[bone] = sk.get_bone_pose_rotation(bone)

func _reachable_plant(sk: Skeleton3D, side: int, point: Vector3, basis: Basis, normal: Vector3) -> Vector3:
	var hip: Vector3 = sk.global_transform*sk.get_bone_global_pose(_chains[side][0]).origin
	var length: float = worker._leg_lengths[side]-.02
	var ankle_offset: Vector3 = sk.global_basis*basis*Vector3(0,_ankle_height[side],0)
	var desired := point-ankle_offset
	var vertical := normal.dot(desired-hip)
	if absf(vertical) >= length: return point
	var horizontal := (desired-hip).slide(normal)
	var reach := sqrt(maxf(length*length-vertical*vertical,0.0))
	return hip+normal*vertical+horizontal.limit_length(reach)+ankle_offset

func _blend_work_release(sk: Skeleton3D, delta: float) -> void:
	if worker.action == "interrupted" and not _work_release.is_empty():
		var side: int = int(_work_release.side)
		# A lateral native hit can release the old world plant before this
		# raised leg has returned. Keep the actual sole moving continuously
		# toward its replacement instead of instantly claiming that new plant.
		if _interrupted_previous_target.is_finite() and (_targets[side]-_interrupted_previous_target).slide(_sole_normals[side]).length() > .05:
			_interrupted_handoff_side = side
			_gait_handoff_velocity[side] = Vector3.ZERO
		_interrupted_previous_target = _targets[side]
	elif worker.action != "interrupted":
		_interrupted_previous_target = Vector3.INF
	if _work_release.is_empty():
		_blend_interrupted_handoff(sk,delta)
		return
	var side: int = _work_release.side
	var chain: Array = _chains[side]
	var foot := sk.get_bone_global_pose(chain[2])
	var root := sk.get_bone_global_pose(0)
	var weight := smoothstep(0.0,WORK_RELEASE_SECONDS,float(_work_release.age))
	var offset := Vector3(0,_ankle_height[side],0)
	var from_basis: Basis = root.basis*_work_release.basis
	var from_rotation := from_basis.get_rotation_quaternion()
	var desired_rotation := foot.basis.get_rotation_quaternion()
	# The grounded recoil endpoint can pass 180 degrees from the saved ankle.
	# Preserve its quaternion hemisphere so the return does not reverse mid-blend.
	var previous_desired: Quaternion = _work_release.get("desired_rotation",from_rotation)
	var previous_from: Quaternion = _work_release.get("from_rotation",from_rotation)
	if desired_rotation.dot(previous_desired) < 0.0: desired_rotation = -desired_rotation
	if from_rotation.dot(previous_from) < 0.0: from_rotation = -from_rotation
	var endpoint_angle := previous_desired.angle_to(desired_rotation)
	desired_rotation = previous_desired.slerpni(desired_rotation,minf(delta*6.0/maxf(endpoint_angle,.00001),1.0))
	_work_release.desired_rotation = desired_rotation
	_work_release.from_rotation = from_rotation
	var basis := Basis(from_rotation.slerpni(desired_rotation,weight))
	var sole: Vector3 = (root*_work_release.sole).lerp(foot*offset,weight)
	if _target_valid[side]:
		var normal: Vector3 = (sk.global_basis.inverse()*_sole_normals[side]).normalized()
		var plane: Vector3 = sk.global_transform.affine_inverse()*_targets[side]
		sole += normal*maxf(-normal.dot(sole-plane),0.0)
	_solve(sk,chain[0],chain[1],chain[2],sole-basis*offset,1.0,basis)
	for bone: int in [chain[0],chain[1]]: _gait_rotations[bone] = sk.get_bone_pose_rotation(bone)
	if _work_release.has("support_sole"):
		var support_side: int = 1-side
		var support_chain: Array = _chains[support_side]
		var support_foot := sk.get_bone_global_pose(support_chain[2])
		var support_offset := Vector3(0,_ankle_height[support_side],0)
		var support_basis := Basis((root.basis*Basis(_work_release.support_basis)).get_rotation_quaternion().slerp(support_foot.basis.get_rotation_quaternion(),weight))
		var support_sole: Vector3 = (root*Vector3(_work_release.support_sole)).lerp(support_foot*support_offset,weight)
		if _terrain_points[support_side].is_finite():
			var normal: Vector3 = (sk.global_basis.inverse()*_sole_normals[support_side]).normalized()
			var plane: Vector3 = sk.global_transform.affine_inverse()*_terrain_points[support_side]
			support_sole += normal*maxf(-normal.dot(support_sole-plane),0.0)
		_solve(sk,support_chain[0],support_chain[1],support_chain[2],support_sole-support_basis*support_offset,1.0,support_basis)
		for bone: int in [support_chain[0],support_chain[1]]: _gait_rotations[bone] = sk.get_bone_pose_rotation(bone)
	# The leg returns over observed terrain; a lifted sole is not a plant.
	if weight < .98: evaluated_grounded[side] = false
	_work_release.age += delta
	if _work_release.age > WORK_RELEASE_SECONDS: _work_release.clear()
	_blend_interrupted_handoff(sk,delta)

func _blend_interrupted_handoff(sk: Skeleton3D, delta: float) -> void:
	if _interrupted_handoff_side < 0 or not evaluated_valid: return
	if worker.feet_work_active() or not worker.on_ground or _gait_handoff_active:
		_interrupted_handoff_side = -1
		return
	var side: int = _interrupted_handoff_side
	if not _terrain_points[side].is_finite(): return
	var before: Vector3 = sk.global_transform*(sk.get_bone_global_pose(_chains[side][2])*Vector3(0,_ankle_height[side],0))
	var speed: float = maxf(worker.gait_speed,(worker.linear_velocity-worker.ground_velocity).length())
	# The final world-sole continuation observes its own current column,
	# retains native support motion and solves the original finite leg.
	_blend_gait_handoff(sk,side,sk.global_transform.affine_inverse(),speed,delta)
	var after: Vector3 = sk.global_transform*(sk.get_bone_global_pose(_chains[side][2])*Vector3(0,_ankle_height[side],0))
	if _work_release.is_empty() and before.distance_to(after) < .002:
		_interrupted_handoff_side = -1
		_gait_handoff_velocity[side] = Vector3.ZERO

func _blend_work_entry(sk: Skeleton3D, delta: float) -> void:
	if _work_entry.is_empty(): return
	var side: int = _work_entry.side
	var chain: Array = _chains[side]
	var foot := sk.get_bone_global_pose(chain[2])
	var offset := Vector3(0,_ankle_height[side],0)
	var weight := smoothstep(0.0,.18,float(_work_entry.age))
	var basis := Basis(Basis(_work_entry.basis).get_rotation_quaternion().slerp(foot.basis.get_rotation_quaternion(),weight))
	var sole: Vector3 = Vector3(_work_entry.sole).lerp(foot*offset,weight)
	_solve(sk,chain[0],chain[1],chain[2],sole-basis*offset,1.0,basis)
	_work_entry.age += delta
	if _work_entry.age > .18: _work_entry.clear()

func _blend_pickup_release(sk: Skeleton3D) -> void:
	# Capture the evaluated gripping sole, then return it to the actual terrain
	# endpoint after native release. Interpolating both local knee rotations made
	# the sole sweep a curved path through the ground. The finite IK solution
	# preserves the real limb lengths while following this supported return.
	if not worker.pickup: return
	var chain: Array = _chains[worker.work_foot_side]
	var foot: Transform3D = sk.get_bone_global_pose(chain[2])
	var root: Transform3D = sk.get_bone_global_pose(0)
	var ankle_to_sole := Vector3(0,_ankle_height[worker.work_foot_side],0)
	if worker.pickup.state == "held":
		_release_foot = {"side":worker.work_foot_side,"sole":root.affine_inverse()*(foot*ankle_to_sole),"basis":root.basis.inverse()*foot.basis}
	elif worker.pickup.state == "flight" and worker.pickup.release_progress() < 1.0 and _release_foot.get("side",-1) == worker.work_foot_side:
		var weight: float = worker.pickup.release_progress()
		var released_basis: Basis = root.basis*_release_foot.basis
		var basis := Basis(released_basis.get_rotation_quaternion().slerp(foot.basis.get_rotation_quaternion(),weight))
		var released_sole: Vector3 = root*_release_foot.sole
		var sole: Vector3 = released_sole.lerp(foot*ankle_to_sole,weight)
		if _target_valid[worker.work_foot_side]:
			# Body balance can pitch the captured local sole below its freshly
			# observed terrain plane. Return above that same support with finite IK.
			var normal: Vector3 = (sk.global_basis.inverse()*_sole_normals[worker.work_foot_side]).normalized()
			var plane: Vector3 = sk.global_transform.affine_inverse()*_targets[worker.work_foot_side]
			sole += normal * maxf(-normal.dot(sole-plane),0.0)
		_solve(sk,chain[0],chain[1],chain[2],sole-basis*ankle_to_sole,1.0,basis)
	else: _release_foot.clear()

func _work_source_phase() -> float:
	var phase: float = worker.action_progress
	if not WORK_TIMING.has(worker.action): return phase
	var points: Array = WORK_TIMING[worker.action]
	for index in points.size()-1:
		var a: Array = points[index]
		var b: Array = points[index+1]
		if phase < float(a[0]) or phase > float(b[0]): continue
		var width: float = float(b[0])-float(a[0])
		var u: float = (phase-float(a[0]))/width
		var u2: float = u*u
		var u3: float = u2*u
		var mapped: float = (2.0*u3-3.0*u2+1.0)*float(a[1])+(u3-2.0*u2+u)*width*float(a[2])+(-2.0*u3+3.0*u2)*float(b[1])+(u3-u2)*width*float(b[2])
		return clampf(mapped,float(a[1]),float(b[1]))
	return phase

func _tool_setback() -> float:
	if worker.action not in ["assemble", "repair", "unbend", "maintenance"] or not worker.tool_foot_occupied(): return 0.0
	var phase: float = _work_source_phase()
	var draw := smoothstep(.22, .40, phase) * (1.0 - smoothstep(.42, .56, phase))
	var release := smoothstep(.60, .72, phase) * (1.0 - smoothstep(.78, .96, phase))
	if worker.action == "assemble":
		# Reach the real work face on the original entry path, then give both
		# building and dismantling a brief draw and brisk final contact stroke.
		# The same .56 event, amplitudes, support and recovery remain owners;
		# the tool's eased return overlaps the existing slower body settle.
		var action_phase: float = worker.action_progress
		draw = smoothstep(.38, .47, action_phase) * (1.0 - smoothstep(.51, .56, action_phase))
		release = smoothstep(.575, .65, action_phase) * (1.0 - smoothstep(.72, .91, action_phase))
	if worker.equipped_tool.kind == "salvage_tool":
		# A short toe-held pull loosens the fastener; it never swings across the face.
		return .025 * draw + .055 * release
	var strength := .5 if worker.action in ["maintenance", "unbend"] else 1.0
	return (.075 * draw + .04 * release) * strength

func _load_brace(sk: Skeleton3D) -> void:
	if worker.action != "brace" or not is_instance_valid(worker.brace_leader) or not is_instance_valid(worker.brace_load): return
	var root := sk.get_bone_global_pose(0)
	var toward: Vector3 = worker._model.global_basis.inverse() * (worker.brace_load.global_position - sk.global_transform * root.origin)
	var envelope := smoothstep(.07,.34,worker.action_progress) * (1.0-smoothstep(.66,.98,worker.action_progress))
	var load: float = clampf(worker.cargo_mass/worker.carry_capacity,0.0,1.0)
	# The partner responds to the real shared load/leader instead of doing the
	# leader's tool kick. Terrain IK keeps BOTH loaded heels on their supports.
	root.origin.x += clampf(toward.x,-1.0,1.0)*.022*load*envelope
	root.origin.y -= .025*load*envelope
	sk.set_bone_global_pose(0,root)

func _weight_transfer(sk: Skeleton3D, walking: bool, speed: float, delta: float) -> void:
	var shift := Vector3.ZERO
	var roll := 0.0
	var pitch := 0.0
	var root := sk.get_bone_global_pose(0)
	# The gait owns locomotion acting (crouch, bob, lean, shift, bank, eye
	# lead): it replaces the clip's root while travelling and the old walking
	# sway below. Work/greeting/balance layers still apply on top of it.
	var gait_acting: bool = _walking_ik and gait.active
	# While another owner takes over (or hands back), the same procedural
	# root keeps fading by its own weight, so neither switch pops the cube.
	var gait_shown: bool = gait.acting()
	if gait_shown:
		root = gait.acting_root(sk,root)
		sk.set_bone_global_pose(0,root)
	evaluated_unbalanced_root = sk.global_transform * root
	evaluated_unbalanced_com = _posed_center_of_mass(sk)
	evaluated_balance_support_side = -1
	if walking and not gait_acting:
		var support := Vector2(float(_plant_weights[0]) if _target_valid[0] else 0.0, float(_plant_weights[1]) if _target_valid[1] else 0.0)
		var bias := (support.y - support.x) / maxf(support.x + support.y, .01)
		var strength := smoothstep(.18, .8, speed)
		var running := smoothstep(2.1, 3.2, speed)
		# A head load calls for smaller lateral excursions and turns. Coordinated
		# carriers remain quieter still so the shared head fixture does not rock.
		var load := clampf(worker.cargo_mass / worker.carry_capacity, 0.0, 1.0)
		var steadiness := lerpf(1.0, .4, load) * (.65 if is_instance_valid(worker.carry_partner) else 1.0)
		shift.x = bias * lerpf(.035, .045, running) * strength * steadiness
		# Lean the upper cube toward the stance leg as it receives the weight.
		# A positive Z rotation tilts its top left, hence the opposite bias sign.
		roll = clampf((-bias * lerpf(.024, .034, running) + clampf(worker.turn_rate, -2.5, 2.5) * .023) * strength * steadiness,-.095,.095)
	# Read the real native acceleration, not an imagined locomotion force.
	# This upper-body acting layer never edits velocity, terrain targets,
	# planted soles, pole directions, work clocks or support/reach limits.
	var relative_velocity: Vector3 = (worker.linear_velocity-worker.ground_velocity).slide(worker.ground_normal)
	var acceleration := (relative_velocity-_motion_velocity)/maxf(delta,.0001) if _motion_velocity_valid else Vector3.ZERO
	_motion_velocity = relative_velocity
	_motion_velocity_valid = true
	var back_stowed: bool = is_instance_valid(worker.equipped_tool) and worker.back_tool and worker.back_tool.phase=="back" and worker.equipped_tool.carrier==worker.back_tool.back_anchor and not worker.tool_foot_occupied()
	var ordinary_expression: bool = worker.action.is_empty() and not worker.carrying and (not is_instance_valid(worker.equipped_tool) or back_stowed) and not is_instance_valid(worker.equipped_gun) \
		and not _head_ground_continuation and not _head_work_continuation and not _head_gait_continuation and not _head_landing_continuation \
		and _work_release.is_empty() and _work_entry.is_empty() and not _travel_tool_handoff and not _travel_pole_handoff \
		and not (worker.head_leap and worker.head_leap.active()) and not (worker.back_tool and (worker.back_tool.pose_owned() or worker.back_tool.recovering()))
	var free_expression: bool = ordinary_expression and not (worker.idle_play and (worker.idle_play.state not in ["","run"] or worker.idle_play.physical_recovery_pending() or worker.idle_play.crouch_weight>.001 or (is_instance_valid(worker.idle_play._modifier) and worker.idle_play._modifier.applied_weight>.001)))
	# The authored solo phrase and its short interruption fade use this same
	# full-tool proof. The planted water notice shares that admission;
	# actual diving and swimming keep their original separate native motion.
	var solo_expression: bool = ordinary_expression and worker.idle_play and is_instance_valid(worker.idle_play._modifier) and (worker.idle_play._modifier.get(&"_solo_dance_tail")==true or worker.idle_play._modifier.get(&"_water_notice_tail")==true) and not worker.idle_play.physical_recovery_pending()
	var requested: bool = free_expression and worker.has_target and worker.target_position.is_finite() and (worker.target_position-worker.global_position).slide(worker.ground_normal).length_squared()>.09
	# This evaluation has already cleared its published sole flags. Admit
	# from the captured preceding plants, then prove this frame's finite
	# root/leg/full-tool geometry below; ordinary obligations remain live.
	var greeting_expression: bool = free_expression and worker.personality and worker.personality.greeting_weight>.001 \
		and worker.personality._can_smile() and evaluated_valid and _preceding_grounded[0] and _preceding_grounded[1] \
		and not is_instance_valid(worker.equipped_gun) and not worker.tool_foot_occupied() \
		and not (worker.threat_watch and worker.threat_watch.weight>.001)
	if requested and not _motion_intent: _motion_start_age = 0.0
	elif requested: _motion_start_age += delta
	_motion_intent = requested
	if free_expression and not gait_acting and not (worker.threat_watch and worker.threat_watch.weight>.001):
		var forward: Vector3 = (-sk.global_basis.z).slide(worker.ground_normal).normalized()
		var drive := clampf(acceleration.dot(forward),-8.0,8.0)
		var anticipation := smoothstep(0.0,.04,_motion_start_age)*(1.0-smoothstep(.07,.13,_motion_start_age)) if requested else 0.0
		# A quick supported gather gives the following movement a clear accent.
		# Counter-lean then follows acceleration and overshoots during braking;
		# the original finite filter below supplies the final ease-out settle.
		var posed_up := (sk.global_basis*root.basis.y).normalized()
		var authored_lean := atan2(posed_up.dot(forward),posed_up.dot(worker.ground_normal))
		var wanted_lean := clampf(drive*.012*(1.0-anticipation)+relative_velocity.dot(forward)*.020-.055*anticipation,-.115,.115)
		# Aim the evaluated cube, including its existing authored backward
		# pitch, rather than hiding a small new lean inside that old pose.
		pitch = clampf(authored_lean-wanted_lean,-.20,.20)
		shift.z = clampf(drive*.003,-.024,.024)*(1.0-anticipation)
		shift.y = -.045*anticipation
		if walking:
			var stance_phase := fposmod(worker.gait_phase*2.0,1.0)
			var receive := smoothstep(.02,.14,stance_phase)*(1.0-smoothstep(.20,.48,stance_phase))
			shift.y -= .026*receive*smoothstep(.18,.8,speed)
			# Lean into a real turn without changing the original roll envelope.
			roll = clampf(roll+clampf(worker.turn_rate,-2.5,2.5)*.015,-.095,.095)
	if _pivot_side>=0:
		var contact_weight: float = smoothstep(0.0,.025,_pivot_age)*(1.0-smoothstep(.025+_pivot_duration,.075+_pivot_duration,_pivot_age))
		var toward: Vector3 = (evaluated_soles[1-_pivot_side]-evaluated_unbalanced_com).slide(worker.ground_normal)
		var local_toward: Vector3 = sk.global_basis.inverse()*toward
		shift.x+=clampf(local_toward.x,-.055,.055)*contact_weight
		shift.y-=.026*contact_weight
		roll+=clampf(-local_toward.x*.16,-.045,.045)*contact_weight
	if greeting_expression:
		# The real observed-player director supplies one supported hello.
		# Existing final IK owns both soles; the same support/full-tool proof
		# used for quiet solo acting admits this small upper-cube gesture.
		shift += worker.personality.greeting_pose(0)
		var greeting_turn: Vector3 = worker.personality.greeting_pose(1)
		pitch += greeting_turn.x
		roll += greeting_turn.z
	var releasing: bool = worker.pickup and worker.pickup.state == "flight" and worker.pickup.release_progress() < 1.0
	if worker.feet_work_active() or releasing:
		var side: int = 1-worker.work_foot_side
		var support: Object = _support[side].get_ref()
		if _target_valid[side] and support is Node3D:
			# Reuse the real sole plant observed by terrain IK, including a moving
			# support's current transform. This never invents a support or force.
			var point: Vector3 = support.to_global(_support_local[side])
			var sole: Vector3 = sk.global_transform * (sk.get_bone_global_pose(_chains[side][2]) * Vector3(0,_ankle_height[side],0))
			if point.distance_to(sole) < .45:
				var envelope := smoothstep(.06,.35,worker.action_progress) * (1.0-smoothstep(.78,1.0,worker.action_progress))
				if releasing: envelope *= 1.0-worker.pickup.release_progress()
				var toward: Vector3 = (point-evaluated_unbalanced_com).slide(worker.ground_normal)
				var local_toward: Vector3 = sk.global_basis.inverse()*toward
				local_toward.y = 0.0
				# Tosses retain the native departure corridor. Control presses also
				# keep the free hip within the finite pedal reach on a narrow deck.
				var constrained: bool = (worker.pickup and (worker.pickup.manipulating() or releasing)) or worker.action == "operate"
				shift = local_toward.limit_length(.055 if constrained else .17)*envelope
				var height := maxf(worker.ground_normal.dot(evaluated_unbalanced_com-point),.45)
				var load := clampf(worker.cargo_mass/worker.carry_capacity,0.0,1.0)
				var steadiness := lerpf(1.0,.65,load)
				var roll_limit := .065 if constrained else .14
				var pitch_limit := .045 if constrained else .08
				roll = clampf(-atan2(local_toward.x,height),-roll_limit,roll_limit)*envelope*steadiness
				pitch = clampf(atan2(local_toward.z,height),-pitch_limit,pitch_limit)*envelope*steadiness
				evaluated_balance_support_side = side
				evaluated_balance_support_point = point
	var blend := 1.0 - exp(-(18.0 if free_expression else 10.0) * delta)
	_sway_shift = _sway_shift.move_toward(_sway_shift.lerp(shift,blend),.65*delta)
	_sway_roll_state = lerpf(_sway_roll_state, roll, blend)
	_sway_pitch = lerpf(_sway_pitch, pitch, blend)
	# Published totals include the gait's own lateral shift and roll.
	var gait_weight: float = gait.locomotion_weight if gait_shown else 0.0
	_sway_offset = _sway_shift.x + gait.body_shift*gait_weight
	_sway_roll = _sway_roll_state + gait.body_roll*gait_weight
	# Bounded translation and tilt precede the same finite leg solves. Their
	# soles/tools remain on real targets; head fixtures follow this evaluated
	# cube. Upright support still belongs to the existing native capsule, so
	# this posed mass estimate is visual balance, not a new COM force solver.
	root.origin += _sway_shift
	root.basis = Basis(Vector3.RIGHT,_sway_pitch) * Basis(Vector3.BACK,_sway_roll_state) * root.basis
	if solo_expression or greeting_expression:
		root = _supported_solo_root(sk,root,delta,back_stowed)
	elif back_stowed and free_expression:
		root = _clear_back_motion_root(sk,root,delta)
	if gait_acting:
		gait.update_drop(sk,root,delta)
		root = gait.constrain_root(sk,root,delta)
	sk.set_bone_global_pose(0, root)

func _supported_solo_root(sk: Skeleton3D, wanted: Transform3D, delta: float, back_stowed: bool) -> Transform3D:
	# Last-stride plants need not lie below rest hips. Admit the cube against
	# BOTH actual supported ankle targets, leaving the original .012 reserve.
	# Only the visual root gathers; the original terrain IK owns every sole.
	if not evaluated_valid: return sk.get_bone_global_pose(0)
	var native_rebase := worker.global_transform*evaluated_worker.affine_inverse()
	var current_world: Transform3D = native_rebase*evaluated_root
	var local_inv := sk.global_transform.affine_inverse()
	var current := local_inv*current_world
	var authored := sk.get_bone_global_pose(0)
	var hips: Array[Vector3] = []
	var ankles: Array[Vector3] = []
	var up: Vector3 = (sk.global_basis.inverse()*worker.ground_normal).normalized()
	var gather := 0.0
	for side in 2:
		var support: Object = _support[side].get_ref()
		if not _target_valid[side] or not support is Node3D: return current
		var point: Vector3 = support.to_global(_support_local[side])
		var rest: Basis = _walk_rest_feet[side]
		var normal := (sk.global_basis.inverse()*_sole_normals[side]).normalized()
		var basis := Basis(Quaternion(-rest.y.normalized(),normal))*rest
		var ankle: Vector3 = local_inv*point-basis*Vector3(0,_ankle_height[side],0)
		var hip: Vector3 = authored.affine_inverse()*sk.get_bone_global_pose(_chains[side][0]).origin
		ankles.append(ankle)
		hips.append(hip)
		var separation: Vector3 = wanted*hip-ankle
		var reach: float = worker._leg_lengths[side]-.012
		var horizontal := separation.slide(up).length_squared()
		if horizontal<reach*reach:
			gather = maxf(gather,separation.dot(up)-sqrt(reach*reach-horizontal))
	# A bounded deeper gather retains the authored brisk sway and lean where
	# the real stance permits them. Extreme stances approach a proved pose
	# instead of lengthening a leg, moving a plant or adding a support force.
	wanted.origin -= up*clampf(gather,0.0,.11)
	wanted.origin = current.origin.move_toward(wanted.origin,(.65 if back_stowed else 3.0)*delta)
	var from := current.basis.get_rotation_quaternion().normalized()
	var to := wanted.basis.get_rotation_quaternion().normalized()
	wanted.basis = Basis(from.slerp(to,minf(1.0,(6.0 if back_stowed else 10.0)*delta/maxf(from.angle_to(to),.0001))))
	if _solo_root_supported(wanted,hips,ankles) and (not back_stowed or worker.back_tool.travel_frame_clear(sk.global_transform*wanted*current_world.affine_inverse())): return wanted
	var admitted := current
	var low := 0.0
	var high := 1.0
	for attempt in 10:
		var weight := (low+high)*.5
		var test := Transform3D(Basis(from.slerp(wanted.basis.get_rotation_quaternion().normalized(),weight)),current.origin.lerp(wanted.origin,weight))
		if _solo_root_supported(test,hips,ankles) and (not back_stowed or worker.back_tool.travel_frame_clear(sk.global_transform*test*current_world.affine_inverse())):
			admitted = test
			low = weight
		else: high = weight
	return admitted

func _solo_root_supported(root: Transform3D, hips: Array[Vector3], ankles: Array[Vector3]) -> bool:
	for side in 2:
		var reach: float = worker._leg_lengths[side]-.012
		if (root*hips[side]).distance_squared_to(ankles[side])>reach*reach: return false
	return true

func _clear_back_motion_root(sk: Skeleton3D, wanted: Transform3D, delta: float) -> Transform3D:
	# The actual last evaluated root is also the seated tool's current frame.
	# Rebase through the same native worker movement; never invent a tool pose.
	var current_world: Transform3D = worker.global_transform*evaluated_worker.affine_inverse()*evaluated_root if evaluated_valid else sk.global_transform*sk.get_bone_global_pose(0)
	var current: Transform3D = sk.global_transform.affine_inverse()*current_world
	wanted.origin = current.origin.move_toward(wanted.origin,.65*delta)
	var from := current.basis.get_rotation_quaternion().normalized()
	var to := wanted.basis.get_rotation_quaternion().normalized()
	var angle := from.angle_to(to)
	wanted.basis = Basis(from.slerp(to,minf(1.0,6.0*delta/maxf(angle,.0001))))
	var rebase := sk.global_transform*wanted*current_world.affine_inverse()
	if worker.back_tool.travel_frame_clear(rebase): return wanted
	# Keep the real current complete tool if even its original native frame
	# is blocked. Otherwise approach only the last exactly proved clear frame.
	if not worker.back_tool.travel_frame_clear(Transform3D.IDENTITY): return current
	var clear := current
	var low := 0.0
	var high := 1.0
	for attempt in 8:
		var weight := (low+high)*.5
		var test := Transform3D(Basis(from.slerp(wanted.basis.get_rotation_quaternion().normalized(),weight)),current.origin.lerp(wanted.origin,weight))
		if worker.back_tool.travel_frame_clear(sk.global_transform*test*current_world.affine_inverse()):
			clear = test
			low = weight
		else: high = weight
	return clear

func _posed_center_of_mass(sk: Skeleton3D) -> Vector3:
	if not worker.ragdoll or worker.ragdoll.rig.bodies.is_empty():
		return sk.global_transform * sk.get_bone_global_pose(0).origin
	var weighted := Vector3.ZERO
	var total := 0.0
	for body in worker.ragdoll.rig.bodies:
		var frame: Transform3D = sk.global_transform*sk.get_bone_global_pose(body.bone)*body.b2b_inv
		# Use the finite base body masses, then add live followers once. Native
		# payload COM is captured for ragdoll forces and can predate a moving toe.
		var body_mass: float = 9.8 if body.index == 0 else body.mass
		weighted += frame.origin*body_mass
		total += body_mass
	if worker.back_tool:
		var load: Dictionary = worker.back_tool.holder_load(sk.global_transform*sk.get_bone_global_pose(0))
		if not load.is_empty():
			weighted += Vector3(load.world_point)*float(load.mass)
			total += float(load.mass)
	var cargo: Node3D = worker._cargo_source
	if worker.cargo_mass > 0.0 and is_instance_valid(cargo):
		var point: Vector3 = MassGeometry.world_centre(cargo)
		if cargo.get("carrier") == worker.head_anchor and not is_instance_valid(worker.carry_partner):
			var head: Transform3D = sk.global_transform*sk.get_bone_global_pose(0)
			head.origin += head.basis*Vector3(0,worker.HEAD_OFFSET,0)
			var local_com: Vector3 = cargo.global_basis.inverse()*(point-cargo.global_position)
			point = head*cargo.carried_local_transform()*local_com
		weighted += point*worker.cargo_mass
		total += worker.cargo_mass
	if is_instance_valid(worker.equipped_tool) and (not worker.back_tool or worker.back_tool.onboard_mass()>0.0):
		weighted += MassGeometry.world_centre(worker.equipped_tool)*worker.equipped_tool.mass
		total += worker.equipped_tool.mass
	if worker.portable_gun and worker.portable_gun.payload_mass()>0.0:
		weighted += worker.portable_gun.payload_centre()*worker.portable_gun.payload_mass()
		total += worker.portable_gun.payload_mass()
	return weighted/maxf(total,.001)

func _continue_head_back_leg(sk: Skeleton3D) -> void:
	if not _head_work_continuation or _head_ground_continuation or not evaluated_valid: return
	var back: RefCounted = worker.back_tool
	if not back or not back.pose_owned() or back._empty_return_active or back._empty_return_tail>0.0: return
	# Back's real finite path may refuse clearance/reach and return without a
	# solve. Keep the previously published WORLD leg as its incoming pose so
	# that refusal cannot publish an ordinary foot or resume from a false plant.
	# Its successful waypoint and captured toe binding remain authoritative.
	var side: int = back._foot_side
	var chain: Array = _chains[side]
	var basis: Basis = sk.global_basis.inverse()*evaluated_ankles[side]
	var ankle: Vector3 = sk.global_transform.affine_inverse()*evaluated_soles[side]-basis*Vector3(0,_ankle_height[side],0)
	_solve(sk,chain[0],chain[1],chain[2],ankle,1.0,basis)
	var toe := sk.get_bone_global_pose(_toes[side])
	toe.basis = sk.global_basis.inverse()*_head_work_toes[side].basis
	sk.set_bone_global_pose(_toes[side],toe)
	evaluated_grounded[side] = false
	_target_valid[side] = false
	_walk_swing_phase[side] = -1.0
	_head_work_feet_match = false

func _head_work_endpoint_owned(side: int) -> bool:
	if not _head_work_continuation or _head_ground_continuation or not evaluated_valid: return false
	var back: RefCounted = worker.back_tool
	if not back: return true
	# These controllers already supply a finite, clearance-checked WORLD
	# endpoint. Altering it in the shared solver feeds a false ordinary target
	# into their return or makes their real waypoint appear out of reach.
	if side==back._foot_side and (back.pose_owned() or back._empty_return_active or back._empty_return_tail>0.0): return false
	var fitting: Dictionary = back._fitting_epoch
	var tool: RigidBody3D = worker.equipped_tool
	if not fitting.is_empty() and back.phase=="foot" and worker.action=="tool_change" and worker.tool_change_picked_up and worker.action_progress>=.78 \
		and side==int(fitting.side) and is_instance_valid(tool) and tool.carrier==worker.tool_anchor and tool==worker.work_target \
		and tool.get_instance_id()==int(fitting.instance) and tool.get_rid()==fitting.rid and worker.current_job_id==str(fitting.job): return false
	return true

func _solve(sk: Skeleton3D, a: int, b: int, c: int, target: Vector3, weight: float, foot_basis: Basis) -> void:
	var head_work_endpoint: bool = _head_work_endpoint_owned(0 if a==_chains[0][0] else 1)
	if head_work_endpoint:
		var side: int = 0 if a==_chains[0][0] else 1
		var offset := Vector3(0,_ankle_height[side],0)
		var desired_sole: Vector3 = sk.global_transform*(target+foot_basis*offset)
		var before := evaluated_ankles[side].get_rotation_quaternion().normalized()
		var after := (sk.global_basis*foot_basis).get_rotation_quaternion().normalized()
		var relative := before.inverse()*after
		var angle := 2.0*atan2(Vector3(relative.x,relative.y,relative.z).length(),absf(relative.w))
		foot_basis = sk.global_basis.inverse()*Basis(before.slerp(after,minf(_head_pose_delta*6.0/maxf(angle,.00001),1.0)).normalized())
		# Preserve the requested sole while its ankle turns, then rate-limit the
		# actually reachable result using the unchanged two-link geometry.
		# Every refinement starts from the same preceding published WORLD sole.
		var sole := _bounded_head_sole(sk,side,evaluated_soles[side],desired_sole,foot_basis,minf(.045,_head_pose_delta*5.4))
		target = sk.global_transform.affine_inverse()*sole-foot_basis*offset
		_head_work_feet_match = _head_work_feet_match and sole.distance_to(desired_sole)<.002 and angle<=_head_pose_delta*6.0+.001
		# The scoped endpoint already blends in Cartesian space. An additional
		# joint-weight blend could move its final sole outside that finite path.
		weight = 1.0
	if (_head_ground_continuation or _head_work_continuation) and evaluated_valid:
		# Use the preceding actual rotations as the finite IK starting frame.
		# A fresh authored joint twist is not part of the native landing motion.
		for bone: int in [a,b]:
			if not _head_joint_rotations.has(bone): continue
			var previous_pose := sk.get_bone_global_pose(bone)
			var previous_rotation: Quaternion = _head_joint_rotations[bone]
			previous_pose.basis = sk.global_basis.inverse()*Basis(previous_rotation)
			sk.set_bone_global_pose(bone,previous_pose)
	var axf := sk.get_bone_global_pose(a)
	var bxf := sk.get_bone_global_pose(b)
	var cxf := sk.get_bone_global_pose(c)
	var hip := axf.origin
	var l1 := hip.distance_to(bxf.origin)
	var l2 := bxf.origin.distance_to(cxf.origin)
	var to := target - hip
	if to.length_squared() < 0.00001 or l1 < 0.01 or l2 < 0.01:
		return
	# Every state bends its knees toward the eye face (model -Z, which is the
	# root's BACK since the imported Bone is turned 180 degrees), splayed a
	# little outward. External owners below still replace it.
	var pole := _default_pole(sk,0 if a==_chains[0][0] else 1)
	if _travel_pole_handoff:
		pole = sk.global_basis.inverse()*_travel_poles[0 if a==_chains[0][0] else 1]
	if WORK_TIMING.has(worker.action):
		# These six authored work clips face the same direction as the eyes.
		# Transport the preceding actual knee plane through the existing finite
		# budget; every refinement starts from that same published WORLD pose.
		var side: int=0 if a==_chains[0][0] else 1
		var forward: Vector3=-worker._model.global_basis.z
		pole=sk.global_basis.inverse()*(_head_return_pole(side,sk.global_transform*hip,sk.global_transform*target,forward) if evaluated_valid else forward)
	if worker.back_tool:
		var side: int=0 if a==_chains[0][0] else 1
		var external_pole: Variant=worker.back_tool.ordinary_work_pole(side)
		if external_pole is Vector3: pole=sk.global_basis.inverse()*Vector3(external_pole)
		var cancelled_pole: Variant=worker.back_tool.cancelled_return_pole(side,sk.global_transform*hip,sk.global_transform*target)
		if cancelled_pole is Vector3: pole=sk.global_basis.inverse()*Vector3(cancelled_pole)
	var pivot_side: int = 0 if a==_chains[0][0] else 1
	if _pivot_work_side>=0 and evaluated_valid:
		# This actual turn's work entry transports both captured knee planes.
		# Its raised foot converges to the authored work bend at the original
		# six-radian budget; the planted support keeps the eye-facing bend.
		var requested: Vector3 = sk.global_basis*pole if pivot_side==_pivot_work_side else -worker._model.global_basis.z
		pole=sk.global_basis.inverse()*_head_return_pole(pivot_side,sk.global_transform*hip,sk.global_transform*target,requested)
	if _work_return_active and evaluated_valid and not (worker.back_tool and worker.back_tool.cancelled_plane_owned()):
		var side: int = 0 if a==_chains[0][0] else 1
		# Reuse the pure evaluated-plane transport and existing 6 rad/s cap.
		# Each refinement starts from the SAME preceding published knee, so
		# neither the raised foot nor its planted partner spends extra turns.
		# Soles, ankle frames, native support, reach and event clocks stay owned
		# by their original controllers; only the departing bend plane changes.
		pole = sk.global_basis.inverse()*_head_return_pole(side,sk.global_transform*hip,sk.global_transform*target,-worker._model.global_basis.z)
	if (_head_ground_continuation or _head_work_continuation) and evaluated_valid:
		var side: int = 0 if a==_chains[0][0] else 1
		var requested: Vector3 = Vector3.INF if _head_ground_continuation else sk.global_basis*pole
		if head_work_endpoint:
			var requested_target := target
			target = _bounded_head_work_target(sk,side,hip,target,l1,l2,foot_basis,requested)
			_head_work_feet_match = _head_work_feet_match and target.distance_to(requested_target)<.002
		pole = sk.global_basis.inverse()*_head_return_pole(side,sk.global_transform*hip,sk.global_transform*target,requested)
	var solution := LegGeometry.two_link(hip, target, l1, l2, pole, .015, .012, Vector3.FORWARD)
	var knee: Vector3 = solution.knee
	var endpoint: Vector3 = solution.foot
	# The knee hinge is the bend-plane normal for BOTH segments: a fixed
	# mapping of each bone's rest frame (segment, rest face) onto (segment,
	# knee bend direction) gives a deterministic twist, no skin wrap.
	var leg_axis: Vector3 = endpoint-hip
	var bend: Vector3 = (knee-hip).slide(leg_axis.normalized()) if leg_axis.length_squared()>1e-8 else pole
	if bend.length_squared()<1e-8: bend = pole.slide(leg_axis.normalized()) if leg_axis.length_squared()>1e-8 else pole
	var continuation: bool = (_head_ground_continuation or _head_work_continuation) and evaluated_valid
	if not continuation and _rest_frame_inv.has(a) and _rest_frame_inv.has(b):
		# Partial weights slerp from the current (authored) frame toward the
		# same deterministic target, so twist never comes from the clip alone.
		var upper_target := _deterministic_basis(a,knee-hip,bend)
		axf.basis = upper_target if weight>=.999 else Basis(axf.basis.get_rotation_quaternion().slerp(upper_target.get_rotation_quaternion(),weight))
		sk.set_bone_global_pose(a, axf)
		bxf = sk.get_bone_global_pose(b)
		var lower_target := _deterministic_basis(b,endpoint-knee,bend)
		bxf.basis = lower_target if weight>=.999 else Basis(bxf.basis.get_rotation_quaternion().slerp(lower_target.get_rotation_quaternion(),weight))
		sk.set_bone_global_pose(b, bxf)
	else:
		var qa := Quaternion((bxf.origin - hip).normalized(), (knee - hip).normalized())
		axf.basis = Basis(Quaternion.IDENTITY.slerp(qa, weight)) * axf.basis
		sk.set_bone_global_pose(a, axf)
		# Re-read after the upper joint, retaining both bone lengths.
		bxf = sk.get_bone_global_pose(b)
		cxf = sk.get_bone_global_pose(c)
		var qb := Quaternion((cxf.origin - bxf.origin).normalized(), (endpoint - bxf.origin).normalized())
		bxf.basis = Basis(Quaternion.IDENTITY.slerp(qb, weight)) * bxf.basis
		sk.set_bone_global_pose(b, bxf)
	if continuation and _rest_frame_inv.has(a) and _rest_frame_inv.has(b):
		var upper_axis: Vector3 = (sk.global_basis*(knee-hip)).normalized()
		var lower_axis: Vector3 = (sk.global_basis*(endpoint-knee)).normalized()
		# Head continuations keep their finite joint budget but now recover
		# toward the same deterministic twist the ordinary solve publishes.
		var wanted_upper: Basis = sk.global_basis*_deterministic_basis(a,knee-hip,bend)
		var wanted_lower: Basis = sk.global_basis*_deterministic_basis(b,endpoint-knee,bend)
		# Rotating the upper segment around its solved axis does not move the
		# knee. Preserve the lower WORLD frame while that upper twist recovers.
		var lower_pose := sk.get_bone_global_pose(b)
		_recover_head_joint_twist(sk,a,upper_axis,wanted_upper)
		sk.set_bone_global_pose(b,lower_pose)
		_recover_head_joint_twist(sk,b,lower_axis,wanted_lower)
	var foot_pose := sk.get_bone_global_pose(c)
	# Preserve the clip's foot orientation plus support tilt; solving the knee must not twist the ankle twice.
	foot_pose.basis = foot_basis
	sk.set_bone_global_pose(c, foot_pose)


static func _leg_frame(segment: Vector3, forward: Vector3) -> Basis:
	# Orthonormal right-handed frame: Y along the segment, Z toward the bend.
	var y := segment.normalized()
	var z := forward.slide(y)
	if z.length_squared()<1e-8: z = (Vector3.FORWARD if absf(y.z)<.9 else Vector3.UP).slide(y)
	z = z.normalized()
	return Basis(y.cross(z),y,z)

func _deterministic_basis(bone: int, segment: Vector3, bend: Vector3) -> Basis:
	# Rest frame (rest segment, rest face -Z) -> solved frame (segment, bend).
	var rotation: Basis = _leg_frame(segment,bend)*Basis(_rest_frame_inv[bone])
	return (rotation*Basis(_rest_bone_basis[bone])).orthonormalized()

func _default_pole(sk: Skeleton3D, side: int) -> Vector3:
	# Face pole, continuous across owner changes: start from the published knee
	# plane whenever another owner solved the last frame, then turn toward the
	# face (outward first if it was bent the other way) at a finite rate.
	var root := sk.get_bone_global_pose(0)
	var face: Vector3 = (sk.global_basis*(root.basis*Vector3.BACK)).normalized()
	var outward: Vector3 = (sk.global_basis*(root.basis*(Vector3.RIGHT if side==0 else Vector3.LEFT))).normalized()
	# Running knees splay a little wider (two clear pistons from the front).
	var splay: float = POLE_SPLAY+(.13*gait.run_weight*gait.locomotion_weight if gait and gait.active else 0.0)
	var wanted := (face+outward*splay).normalized()
	var frame := Engine.get_physics_frames()
	if int(_pole_frame[side])!=frame:
		var base: Vector3 = _pole_out[side]
		if int(_pole_frame[side])!=frame-1 or not base.is_finite():
			base = wanted
			if evaluated_valid:
				var ankle: Vector3 = evaluated_soles[side]-evaluated_ankles[side]*Vector3(0,_ankle_height[side],0)
				var axis: Vector3 = ankle-evaluated_hips[side]
				var offset: Vector3 = (evaluated_knees[side]-evaluated_hips[side]).slide(axis.normalized()) if axis.length_squared()>1e-6 else Vector3.ZERO
				if offset.length()>.01: base = offset.normalized()
		_pole_base[side] = base
		_pole_frame[side] = frame
	var from: Vector3 = _pole_base[side]
	var goal := outward if from.dot(wanted)<-.3 else wanted
	var angle := from.angle_to(goal)
	var step := minf(angle,POLE_TURN_RATE*maxf(_head_pose_delta,1.0/120.0))
	var result := from
	if angle>.00001:
		var turn_axis := from.cross(goal)
		result = from.rotated(turn_axis.normalized(),step).normalized() if turn_axis.length_squared()>1e-10 else goal
	_pole_out[side] = result
	return sk.global_basis.inverse()*result

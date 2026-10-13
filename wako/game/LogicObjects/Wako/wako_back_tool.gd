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
const FLIGHT_SECONDS := .56 # Legacy hop route only; the stunt plans its own flight time.
const FOOT_WORK := ["inspect", "assemble", "repair", "unbend", "maintenance", "tool_change"]
# Upward tool stunt: gather -> kick -> ballistic quarter twirl -> contact catch.
# Every bound below caps the same finite toe/tool/body; none waives a guard.
const GATHER_TOE_SPEED := 2.2
const STUNT_TURN := 6.0
# A brisk foot twirl on the way out of the seat (~1.3 rev/s peak).
const RETRIEVE_TURN := 10.5
# Tray hardware (rubber + shelf + bronze socket) below each tray top, the
# skin cube's bottom edge, and the clearance kept above it.
const TRAY_HARDWARE_BELOW_TOP := .087
const CUBE_BOTTOM_Y := -.2625
const HARDWARE_ABOVE_BOTTOM := .04
# First-use cost guesses (ops) of one planner unit, refined as units run.
const PLAN_UNIT_DEFAULT := {"pose":4,"solve":12,"arc_posture":90,"arc_native":40,"kick":30,"advance":20}
const RETRIEVE_TOE_SPEED := 3.4
const KICK_STROKE := .26 # Straight COM stroke of the kick (the thigh drives it).
const KICK_RAMP := .03 # Speed ramp-in only: the tool leaves at full stroke speed.
const KICK_TOE_SPEED := 4.4 # Stroke speed cap (the tool's own release speed is ~4.0-4.4).
const KICK_TOE_LIMIT := 5.3 # Toe speed incl. its roll, under Pose's .045 m/tick sole budget.
const KICK_TOE_STEP := .045
const KICK_SPIN_MAX := 8.0 # Ankle flick roll rate cap; the toe's own speed is bounded per tick.
const STUNT_SPIN_CORRECTION_MAX := 2.0 # Release torque impulse bound (stunt only, plan/s12).
const SPIN_CORRECTION_PREFERRED := 1.6 # Main tiers: nearly all of the spin is the foot's own flick.
const HOLD_SECONDS := .10 # Slow-in hold at the cocked pose (alive: toe settles, head dips).
const HOLD_DIP := .015
const HOLD_TILT := .07 # ~4 degrees
const FOLLOW_THROUGH := .17 # Empty toe carries on past release, ramping out (a real kick).
# Tool COM apex above the ground (world): ~.45-.5 m over the roof; the low
# variant still fits a 2.2 m ceiling before the legacy hop is used.
const APEX_MAIN := [1.94,2.0,2.06]
const APEX_LOW := [1.55,1.45]
const PLAN_OPS_PER_TICK := 140
const ADVANCE_MAX := .30
const ADVANCE_MIN := .10
const ADVANCE_LIMIT := .40 # Planned advance plus closed-loop correction.
const ADVANCE_SECONDS := .50
const ADVANCE_ACCEL := 6.0
const ADVANCE_GAIN := 12.0
const CATCH_TURN_TOLERANCE := 0.13962634 # 8 degrees
const SPIN_CORRECTION_MAX := 2.0
const SETTLE_SECONDS := .39 # Catch absorb: dip, 1-frame hold, recovery with overshoot.
const CATCH_CROUCH := -.02 # Pose's steady "under it" crouch the catch is aimed at (the absorb dips below it).
const PROUD_SECONDS := .46 # Its own 2 cm bounce plus an over-the-shoulder glance.
# Backpack geometry (body frame: +X right, +Y up, +Z back). The fitted plate's
# outer face is measured from the actual skin (HolderVisual); the seated tool
# keeps 10 mm of air in front of its grown visual slices.
const PLATE_BACK := .2552
const SEAT_Z := .317
const SEAT_AIR := .010
const BACK_KEEP_Z := .26
const SEAT_TOP_MAX := .32 # Seated keepout top stays under the roof (.3376).
const PAD_PRELOAD := .001 # Resting tool overlaps each tray sensor by 1 mm.
const PAD_DEPTH_BUDGET := .018 # First-tray penetration accepted at the two-tray contact (inside the 20 mm rubber).
const LEGACY_SEAT := Vector3(0, -.18, .58)
const LEGACY_SEAT_V2 := Vector3(0, -.18, .317)
# Root-local whole-tool keepout used by back transfers. Root-local x/z are the
# body frame negated (180-degree rest), so the BACK face is root-local -Z. The
# front/sides keep the helper's general cube; only the measured rear moves in.
# Back transfers use the measured body instead of the general cube's doubled
# depth: the skin cube (x +-.4243, y -.2625...+.3376, z +-.199, straps to
# .207) plus margins, and the fitted plate region behind it (to PLATE_BACK).
# Root-local x/z are the body frame negated: the back is root-local -Z.
const FRONT_KEEP_Z := .229
const CUBE_BACK_Z := .219
const BACK_BOUNDS := AABB(Vector3(-.444, -.30, -CUBE_BACK_Z), Vector3(.888, .668, CUBE_BACK_Z + FRONT_KEEP_Z))
const PLATE_BOUNDS := AABB(Vector3(-.27, -.255, -BACK_KEEP_Z), Vector3(.54, .25, BACK_KEEP_Z))
# In the last .06 s before tray contact the grown (+5 mm) slices may use 3 mm
# of their growth past the plate face: the visual tool stays >= 2 mm off the
# plate (a spinning wide head's edge sweeps a few mm deeper than its axis),
# and the settle re-seats it.
const CATCH_PLATE_GRACE := .003
const CATCH_BOUNDS := AABB(Vector3(-.444, -.30, -.209), Vector3(.888, .668, .209 + FRONT_KEEP_Z))
const CATCH_PLATE_BOUNDS := AABB(Vector3(-.27, -.255, -(PLATE_BACK - CATCH_PLATE_GRACE)), Vector3(.54, .25, PLATE_BACK - CATCH_PLATE_GRACE))
var stage := "" # Stunt sub-state: gather, kick, flight, settle, reach, draw, home ("" = legacy route).
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
# Diagnostic per-tick query counters (posture SATs, native space queries);
# the harness reads and zeroes them each tick. Never used for decisions.
var ops_posture := 0
var ops_native := 0

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
var _seat_colliders: Array[CollisionShape3D] = []
var _seat_models: Array[MeshInstance3D] = []
var _drop_arms: Array[MeshInstance3D] = []
var _gussets: Array[MeshInstance3D] = []
var _straps: Array[MeshInstance3D] = []
var _plate_back := PLATE_BACK
var _seat_layouts: Dictionary = {}
var _seat_local := Transform3D(Basis.IDENTITY,Vector3(0,-.044,SEAT_Z))
var _seat_normal := Vector3.UP
var _pad_features: Array[Vector3] = []
var _pad_tops: Array[Vector3] = []
var _holder_layout_key: Array = []
var _visual_points := PackedVector3Array()
var _feature_shape := BoxShape3D.new()
# Harness-only seat exploration: --back-tool-seat=<tilt deg>,<far shift>,<max y>.
var seat_override := PackedFloat32Array()
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
var _age_frame := 0
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
var _stunt: Dictionary = {} # Planned gather/kick/flight; empty for the legacy hop route.
var _kick_time := 0.0
var _toe_motion_tick := -1
var _return_local_waypoints: Array[Transform3D] = []
var _return_segment_binding := Transform3D.IDENTITY
var _reach_binding: Array[Transform3D] = []
var _legacy_pending := false
var _step_plan: Dictionary = {}
var _return_search: Dictionary = {}
var _launch_refused: Array[String] = []
var _launch_refused_at := Vector3.ZERO
var _legacy_search: Dictionary = {}
var _retrieval_cand := 0
var _plan_unit_cost: Dictionary = {}
var _interrupt_after_catch := false
var _deferred_recoil := ""
var _recoil_seen := 0
var _deferred_kind := "interrupted"
var _home_extension_done := false
var _deferred_reaction := 0.0
var _retrieval_retry := 0.0
var _catch_trim := 0.0
var catch_trim_gain := .12
var _empty_return_age := 0.0
const EMPTY_RETURN_LIMIT := 2.5
var _advance: Dictionary = {} # Supported forward capsule advance while the tool flies.
var _flight_seconds := FLIGHT_SECONDS
var _stage_age := 0.0
var _settle_time := 0.0
var _back_keepout := false
var _seat_z := SEAT_Z
var _planted_ticks := 0
var _route_fast := false
var _draw_points := 0
var _stunt_metrics: Dictionary = {}
var migrated_seat := false
var _release_guard: Dictionary = {} # Loose body ignoring its own Wako until it cannot reach it.
var _flight_prev_local := Transform3D.IDENTITY
var _flight_prev_valid := false
var _flight_prev_body := Transform3D.IDENTITY
var _cradle_clack := -1.0 # Age of the cradle lips' catch "clack" (< 0: idle).
var _pad_base: Array[Transform3D] = [Transform3D.IDENTITY,Transform3D.IDENTITY]
# Worn-pack display state (see _update_holder_display).
const HOLDER_LAYOUT_SECONDS := .30
const REST_PAD := Vector3(.14,-.065,.317) # Level, mirrored empty trays on the plate at a diagonal seat's mean tray height.
var _display_seat := false
var _display_key: Array = []
var _display_from: Array[Transform3D] = []
var _display_to: Array[Transform3D] = []
var _display_t := 1.0
var _seat_rebound := false
const SEAT_SETTLE_SECONDS := .12
# Visible rubber give at the catch: 8 mm down, a 2 mm rebound, a last 0.8 mm
# dip, with one rocking rattle about the tray axis decaying over ~.15 s.
const SEAT_GIVE := .008
const SEAT_RATTLE := .035
const SEAT_REBOUND_SECONDS := .20
const CLACK_SECONDS := .10
var _plan_search: Dictionary = {}
var _arc_fail_time := -1.0
var _floor_margin := 0.0
var _lift_off: Dictionary = {}
const LIFT_OFF_RADIUS := .10
const AIM_BEHIND := .015
const CROUCH_MARGIN := .055 # Deepest acting crouch below the planning pose (gather/hold).
var _seat_settling := false
var _catch_keepout := false
var _seat_flip := 1.0
var _seat_settle_age := 0.0
var _seat_settle_from := Transform3D.IDENTITY
var _seat_settle_to := Transform3D.IDENTITY
# Diagnostic switch (harness A/B only): plan the stunt without the body advance.
var stunt_advance_disabled: bool = "--back-tool-no-advance" in OS.get_cmdline_user_args()
var _acting: Dictionary = {} # Direct-mode body acting state handed to Pose (shift, roll, pitch, yaw).
const ACT_SHIFT_RATE := 1.4 # m/s
const ACT_TURN_RATE := 4.0 # rad/s
var _catch_dip := .03
var _catch_trim_at_catch := 0.0
var _support_step: Dictionary = {} # Support foot's catch-up step during the flight.
var _support_step_done := false
var _draw_started := 0.0
var _draw_lift_t0 := -1.0
var _retrieval_time := 0.0
static var _bronze: StandardMaterial3D
static var _stone: StandardMaterial3D
static var _rubber: StandardMaterial3D
static var _holder_meshes: Dictionary = {}

func setup(owner: RigidBody3D) -> void:
	worker = owner
	for raw: String in OS.get_cmdline_user_args():
		if raw.begins_with("--back-tool-trim="): catch_trim_gain = float(raw.trim_prefix("--back-tool-trim="))
		if raw.begins_with("--back-tool-seat="):
			for item: String in raw.trim_prefix("--back-tool-seat=").split(","): seat_override.append(float(item))
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
	# The permanent 2 kg holder is always counted, so it is always shown.
	holder.visible = true
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
	if not (busy() or (_want_stow and foot_occupied())): return false
	# A fright normally frees navigation at once; the bounded (< 1 s) owned
	# transfers - a retrace home, the flight to the catch, the way home - finish
	# first so the flee never drags a leg that still holds or awaits the tool.
	if worker.fear_time>0.0 and not (phase in ["prepare","flight","return"] and worker.on_ground): return false
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
	# Interruption outcomes by phase (no custody gap, no loose tool in the body):
	#   prepare (gather/hold/kick): the toe still holds it -> ordinary foot carry;
	#   flight: the passive cradle still catches it, the reaction follows the catch;
	#   return (draw/home, preflighted ~.5 s): finished, the reaction follows;
	#   retrieve (before handle contact): the tool stays seated.
	# A startle (interrupt, danger, a hit's fear) while the Wako still stands
	# never sheds a tool in transfer: the airborne tool is still caught by the
	# passive cradle, a tool on its way home finishes it, a stunt not yet
	# released retraces home on the foot - then the reaction plays.
	var grounded: bool = worker.on_ground and worker.is_available()
	var recoil: RefCounted = worker.get("recoil")
	if kind == "interrupted" and phase == "flight" and recoil and int(recoil.events) != _recoil_seen:
		# A hit strong enough for the native recoil shoves the cradle away from
		# the airborne tool: the stunt ends now and its one recoil plays at
		# once; the same tool lands on its own, solid against the body (never
		# through it), and is recovered like any loose original.
		_recoil_seen = int(recoil.events)
		_work_pole_active=false
		pending_action = ""
		_pending_job = ""
		drop("Hit in flight; the airborne tool lands on its own")
		return true
	if kind in ["interrupted", "danger"] and grounded and (phase == "flight" or (phase == "return" and _return_search.is_empty() and not _waypoints.is_empty())):
		_work_pole_active=false
		_defer_reaction(kind,"Interrupted; catching the airborne tool first" if phase == "flight" else "Interrupted; finishing the tool's way home first")
		return false
	if kind in ["interrupted", "danger"] and phase == "return" and not _return_search.is_empty() and _reseat_from_contact():
		# Still at handle contact (the draw route was being preflighted): the
		# tool goes back to the cradle and the empty foot returns home.
		_work_pole_active=false
		pending_action = ""
		_pending_job = ""
		return true
	if kind in ["interrupted", "danger"] and phase == "prepare" and grounded and foot_occupied():
		_work_pole_active=false
		if _cancel_to_foot("Interrupted before release; the tool goes back to the foot"):
			_defer_reaction(kind,"Interrupted before release; the tool goes back to the foot")
			return false
		pending_action = ""
		_pending_job = ""
		return true
	if kind in ["interrupted", "danger"]:
		_work_pole_active=false
		pending_action = ""
		_pending_job = ""
		# A still-seated tool (retrieval before toe contact, or the leg settling
		# after a catch) stays in the cradle; only a tool in transfer is released.
		if phase == "retrieve": _abort_retrieval("Interrupted retrieval; the same tool stays seated")
		elif _transfer_owns_tool(): drop("Interrupted during back-tool transfer")
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
	_retrieval_retry = maxf(_retrieval_retry-delta, 0.0)
	_empty_return_tail=maxf(_empty_return_tail-delta,0.0)
	_ordinary_motion_age+=delta
	if not is_instance_valid(worker) or not worker.is_inside_tree(): return
	# Recoil events already answered (a new one during a held reaction is
	# recognised by _defer_reaction).
	if not _interrupt_after_catch and worker.recoil: _recoil_seen = int(worker.recoil.events)
	_update_release_guard(delta)
	_update_holder_display(delta)
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
		holder.visible = true
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
	var pose: SkeletonModifier3D = worker._pose
	_planted_ticks = _planted_ticks+1 if pose and pose.evaluated_valid and pose.evaluated_grounded.count(true) == 2 else 0
	_stage_age += delta
	if phase in ["retrieve","return"]: _retrieval_time += delta
	if _seat_settling:
		_seat_settle_age += delta
		if phase != "back": _seat_settling = false
	_update_clack(delta)
	if not _lift_off.is_empty() and ((phase not in ["foot","prepare"] and stage != "retrace") or stage in ["hold","kick","release"]): _lift_off.clear()
	if stage in ["settle","proud"]:
		_settle_time -= delta
		if phase != "back": _set_stage("")
		elif _settle_time <= 0.0:
			if stage == "settle" and not worker.has_target:
				_set_stage("proud")
				_settle_time = PROUD_SECONDS
			else: _set_stage("")
	if busy():
		_age += delta
		_age_frame = Engine.get_physics_frames()
		if not worker.on_ground or worker.fear_time > 0.0:
			# Seated custody survives the settling leg; a retrieval that has not
			# touched the handle returns to the cradle instead of shedding it.
			# A fright (hit, danger) while the Wako still stands sheds nothing:
			# the airborne tool is still caught (the advance keeps driving the
			# cradle under it), a tool on its way home finishes, a stunt not yet
			# released retraces home on the foot. Only lost footing releases.
			var standing: bool = worker.on_ground and worker.is_available()
			if phase == "retrieve": _abort_retrieval("Lost safe support before retrieval contact")
			elif standing and phase in ["flight","return"]: pass
			elif standing and phase == "prepare":
				if not _cancel_to_foot("Startled before release; the tool goes back to the foot"): drop("Startled before release with no clear way home")
			elif _transfer_owns_tool(): drop("Lost safe support during back-tool transfer")
			if phase not in ["back","flight","return"]: return
		if _age > 10.0 and phase != "back":
			if phase == "retrieve": _abort_retrieval("Back-tool retrieval timed out; the tool stays seated")
			else: drop("Back-tool transfer timed out; recovering original loose tool")
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
		_update_catch_trim()
		_observe_catch(delta)
	elif phase == "back":
		_publish_back()

func evaluated(pose: SkeletonModifier3D, sk: Skeleton3D, delta: float) -> void:
	_guard_fitting_return(pose,sk,delta)
	if _empty_return_active or _empty_return_tail>0.0: _recover_empty_leg(pose,sk,delta)
	if not _support_step.is_empty(): _drive_support_step(pose,sk,delta)
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
	var timed: bool = phase == "prepare" and stage in ["hold","kick"]
	if phase == "prepare" and not timed and _path_index >= _waypoints.size(): return
	var root := sk.global_transform*sk.get_bone_global_pose(0)
	_root = root
	_sync_root(root)
	if timed:
		_evaluate_kick(pose,sk,delta,root)
		return
	if phase == "return" and not _return_search.is_empty():
		# Hold the actual grip while the budgeted return search finishes.
		_continue_return_search()
		if phase != "return": return
		if not _return_search.is_empty() or _waypoints.is_empty():
			_drive_toe(pose,sk,delta,_toe,_toe_in_ankle,_toe)
			return
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
	if phase == "return" and _return_local_waypoints.size() == _waypoints.size():
		# The fast draw follows the body as well (no world-anchored lag).
		for i in range(_path_index,_waypoints.size()):
			_waypoints[i] = _body_frame*_return_local_waypoints[i]
	if phase == "retrieve": _publish_back()
	var target := _waypoints[_path_index]
	if phase == "retrieve" and _path_index == _waypoints.size()-1:
		var tool: RigidBody3D = worker.equipped_tool
		target = Transform3D(tool.global_basis, tool.global_transform*Vector3(0,-.035-float(tool.definition.size.y)*.45,0))
	# The toe uncurls from grip to walking binding DURING the last home
	# segment (below); only a residual after arrival is restored in place.
	var home_last:=phase=="return" and _path_index==_waypoints.size()-1
	var restoring_binding:=home_last and _turn(_toe_in_ankle.basis.get_rotation_quaternion(),_home_toe_in_ankle.basis.get_rotation_quaternion())>.0005 \
		and _toe.origin.distance_to(target.origin)<.001 and _turn(_toe.basis.get_rotation_quaternion(),target.basis.get_rotation_quaternion())<.001
	var reach_binding: bool = phase=="retrieve" and not _reach_binding.is_empty()
	var old_binding:=_toe_in_ankle
	var motion_target := target
	var return_age_after := _return_segment_age
	# The original first empty-foot lift must immediately clear its planted
	# native sphere. Its subsequent already-clear reach can use authored spacing.
	var eased_segment:=not (phase=="retrieve" and _path_index==0)
	var toe_speed := _segment_toe_speed()
	var toe_turn := _segment_toe_turn()
	if eased_segment and not restoring_binding:
		if _return_segment_phase!=phase or _return_segment_index!=_path_index:
			_return_segment_phase=phase
			_return_segment_index=_path_index
			_return_segment_start=_toe
			_return_segment_binding=_toe_in_ankle
			_return_segment_age=0.0
			_return_segment_seconds=maxf(_toe.origin.distance_to(target.origin)/toe_speed,
				_turn(_toe.basis.get_rotation_quaternion(),target.basis.get_rotation_quaternion())/toe_turn)
		return_age_after=_return_segment_age+delta
		var ramps:=_transfer_segment_ramps()
		var fraction:=_return_segment_fraction(return_age_after,_return_segment_seconds,ramps.x,ramps.y)
		motion_target=Transform3D(Basis(_return_segment_start.basis.get_rotation_quaternion().slerp(target.basis.get_rotation_quaternion(),fraction)),
			_return_segment_start.origin.lerp(target.origin,fraction))
		if home_last:
			var from_b := _return_segment_binding.basis.get_rotation_quaternion().normalized()
			_toe_in_ankle = Transform3D(Basis(from_b.slerp(_home_toe_in_ankle.basis.get_rotation_quaternion().normalized(),fraction)),
				_return_segment_binding.origin.lerp(_home_toe_in_ankle.origin,fraction))
		if reach_binding:
			# The empty toe curls toward its reach binding along the same eased
			# segment (a finite joint change at the same rate budget).
			var goal: Transform3D = _reach_binding[mini(_path_index,_reach_binding.size()-1)]
			var from_q := _return_segment_binding.basis.get_rotation_quaternion().normalized()
			_toe_in_ankle = Transform3D(Basis(from_q.slerp(goal.basis.get_rotation_quaternion().normalized(),fraction)),_return_segment_binding.origin.lerp(goal.origin,fraction))
	var before := _toe
	var wanted := _toe
	if restoring_binding:
		var from:=_toe_in_ankle.basis.get_rotation_quaternion().normalized()
		var to:=_home_toe_in_ankle.basis.get_rotation_quaternion().normalized()
		_toe_in_ankle.basis=Basis(from.slerp(to,minf(toe_turn*delta/maxf(_turn(from,to),.000001),1.0)))
		# The real authored toe pivot has not changed; only its captured curl
		# differs between an empty walking foot and the former held-tool foot.
		_toe_in_ankle.origin=_home_toe_in_ankle.origin
	else:
		wanted.origin = _toe.origin.move_toward(motion_target.origin,toe_speed*delta)
	var qa := _toe.basis.get_rotation_quaternion().normalized()
	var qb := motion_target.basis.get_rotation_quaternion().normalized()
	var angle := _turn(qa,qb)
	wanted.basis = Basis(qa.slerp(qb,minf(toe_turn*delta/maxf(angle,.000001),1.0)))
	var stepped := _drive_toe(pose,sk,delta,wanted,old_binding,target)
	if plan_debug and phase == "return": print("CONTRAPTION_BACK_TOOL return_step idx=",_path_index,"/",_waypoints.size()," stage=",stage," dist=",snappedf(_toe.origin.distance_to(target.origin),.0001)," turn=",snappedf(_turn(_toe.basis.get_rotation_quaternion(),target.basis.get_rotation_quaternion()),.001)," binding=",restoring_binding," seg_age=",snappedf(_return_segment_age,.001),"/",snappedf(_return_segment_seconds,.001)," stepped=",stepped)
	if stepped < 0: return
	if stepped == 0: return
	if eased_segment and not restoring_binding: _return_segment_age=return_age_after
	if restoring_binding: return
	if eased_segment:
		var ramps:=_transfer_segment_ramps()
		var ramp_in:=minf(ramps.x,_return_segment_seconds)
		var ramp_out:=minf(ramps.y,_return_segment_seconds)
		if _return_segment_age<_return_segment_seconds+.5*(ramp_in+ramp_out): return
	var actual := _toe
	var arrived := actual.origin.distance_to(target.origin) < .001 and _turn(actual.basis.get_rotation_quaternion(),target.basis.get_rotation_quaternion()) < .001
	if not arrived: return
	if phase == "retrieve" and _path_index == _waypoints.size()-1:
		_attach_to_foot(actual)
		return
	_path_index += 1
	if phase == "return" and _route_fast and _path_index >= _draw_points: _set_stage("home")
	if _path_index < _waypoints.size(): return
	if phase == "prepare":
		if not _stunt.is_empty():
			# Slow-in has reached the cocked pose: hold, then kick.
			_set_stage("hold")
			_kick_time = 0.0
			return
		# Release happens only after this actual evaluated toe frame is published.
		_launch.call_deferred()
	else:
		_finish_return(pose,sk)

func _finish_return(pose: SkeletonModifier3D,sk: Skeleton3D) -> void:
	if pending_action.is_empty() and not _home_extension_done:
		# The queued foot action was cancelled on the way (an interrupt): end
		# in the ordinary carry pose the stow started from, not in the
		# work-ready grip, so ordinary foot custody resumes without a jump.
		_home_extension_done = true
		var home := _supported_return_home(_body_frame*_home_toe_body)
		if home.origin.is_finite() and (_toe.origin.distance_to(home.origin) > .01 or _turn(_toe.basis.get_rotation_quaternion(),home.basis.get_rotation_quaternion()) > .05):
			# Direct, then over a raised midpoint (a long pickaxe head swings
			# clear of the support leg and the floor above the straight line).
			var up: Vector3 = worker.ground_normal
			for lift: float in [0.0,.06,.12,.18]:
				var points: Array[Transform3D] = [home]
				if lift > 0.0:
					var mid := _interp(_toe,home,.5)
					mid.origin += up*lift
					points = [mid,home]
				if _path_clear(_toe,points):
					_accept_return_route(points,0)
					_set_stage("home")
					_route_fast = false
					return
			if plan_debug: print("CONTRAPTION_BACK_TOOL home_extension_refused ",last_path_failure)
	phase = "foot"
	_set_stage("")
	_route_fast = false
	_want_stow = false
	_age = 0.0
	_tool_id = 0
	_return_local_waypoints.clear()
	_reset_foot_handoff(pose)
	var next := pending_action
	pending_action = ""
	if not next.is_empty():
		_capture_work_poles(pose,sk,next)
		worker.begin_action.call_deferred(next)
	_begin_deferred_interrupt()

func _evaluate_kick(pose: SkeletonModifier3D,sk: Skeleton3D,delta: float,_root_now: Transform3D) -> void:
	# Hold (slow-in finished) then the timed kick stroke. Each tick still takes
	# only a reachable, whole-tool/native-clear, Pose-budgeted actual step.
	var wanted: Transform3D
	if stage == "hold":
		_kick_time += delta
		wanted = _hold_pose(_stunt,_kick_time)
		if _kick_time >= HOLD_SECONDS:
			_set_stage("kick")
			_kick_time = 0.0
	else:
		_kick_time += delta
		wanted = _kick_pose(_stunt,_kick_time)
	if wanted.origin.distance_to(_toe.origin) > KICK_TOE_STEP+.001:
		wanted.origin = _toe.origin.move_toward(wanted.origin,KICK_TOE_STEP)
	var stepped := _drive_toe(pose,sk,delta,wanted,_toe_in_ankle,wanted)
	if plan_debug:
		var inv := _body_frame.affine_inverse()
		print("CONTRAPTION_BACK_TOOL kick_step stage=",stage," t=",snappedf(_kick_time,.0001)," stepped=",stepped," wanted=",inv*wanted.origin," actual=",inv*_toe.origin," wy=",_body_frame.basis.inverse()*wanted.basis.y," ay=",_body_frame.basis.inverse()*_toe.basis.y," v=",_toe_velocity.length()," w=",_toe_angular.length())
	if stepped <= 0: return
	if stage == "kick" and _kick_time+delta > float(_stunt.kick_seconds)+.0001:
		# Release on the stroke's last full tick: this published pose and its
		# measured full-speed motion/roll are what the tool inherits.
		_path_index = _waypoints.size()
		_set_stage("release")
		_launch.call_deferred()

func _drive_toe(pose: SkeletonModifier3D,sk: Skeleton3D,delta: float,wanted: Transform3D,old_binding: Transform3D,target: Transform3D) -> int:
	# Shared owned-toe step: reach + whole-tool (held) or sphere (empty)
	# check, IK with the transported knee plane, actual-vs-wanted check,
	# measured motion, publication. Returns 1 stepped, 0 refused (held), -1
	# released/aborted.
	var side := _foot_side
	var chain: Array = pose._chains[side]
	var toe_index: int = pose._toes[side]
	var root := _root
	var before := _toe
	var held := foot_occupied()
	var hip: Vector3 = sk.global_transform*sk.get_bone_global_pose(chain[0]).origin
	var reachable:=_toe_reachable(wanted,hip,side)
	var clear:=_frame_clear(wanted,root,true) if held else _empty_toe_clear(wanted,root)
	var refused_step := not reachable or not clear
	if refused_step:
		_toe_in_ankle=old_binding
		if _wait==0.0:
			var ankle: Vector3=wanted.origin-(wanted.basis*_toe_in_ankle.basis.inverse())*_toe_in_ankle.origin
			last_path_failure={"phase":phase,"stage":stage,"waypoint":_path_index,"held":held,"reachable":reachable,"clear":clear,"toe":Part.encode_transform(wanted),"target":Part.encode_transform(target),"ankle":Part.encode_vector(ankle),"hip":Part.encode_vector(hip),"span":worker._leg_span(side),"root":Part.encode_transform(root)}
			if not clear: last_path_failure.native_obstacle=last_native_obstacle.duplicate(true)
			if plan_debug: print("CONTRAPTION_BACK_TOOL evaluated_path_refused ",JSON.stringify(last_path_failure))
		_wait += delta
		# The timed kick may not stall: a refused stroke releases nothing and
		# returns the tool from its actual pose like any other refusal.
		var patience := .10 if stage in ["kick","hold"] else .75
		if _wait > patience:
			if phase == "retrieve": _abort_retrieval("Retrieval path lost clearance; the same tool stays seated",pose,sk)
			elif phase == "prepare" and _cancel_to_foot("Stunt path lost clearance; the tool goes back to the foot"):
				# Hold this tick's actual pose (below); the retrace starts next tick.
				_wait = 0.0
			else:
				drop("Tool path lost clearance; original tool released safely")
				return -1
		# A refused next step still owns its preceding actual WORLD toe. The
		# shared modifier publishes its completed rig below, so returning an
		# ordinary idle leg here would move the same held tool before release.
		# Retain only a currently reachable, fully clear original pose; otherwise
		# release from the actual attachment before any ordinary publication.
		var current_clear := _frame_clear(_toe,root,true) if held else _empty_toe_clear(_toe,root)
		if not _toe_reachable(_toe,hip,side) or not current_clear:
			if phase == "retrieve": _abort_retrieval("The empty retrieval pose no longer fits; the same tool stays seated",pose,sk)
			else: drop("The current tool-transfer pose no longer fits; original tool released at its actual pose")
			return -1
		wanted = _toe
	else:
		_wait = 0.0
	var local_inv := sk.global_transform.affine_inverse()
	var relative: Basis = _toe_in_ankle.basis
	var offset: Vector3 = _toe_in_ankle.origin
	var foot_basis: Basis = sk.global_basis.inverse()*wanted.basis*relative.inverse()
	var ankle: Vector3 = local_inv*wanted.origin-foot_basis*offset
	# Preserve the actual incoming knee plane, then turn it finitely toward
	# the eye-facing model front. Imported Bone forward is reversed.
	var forward: Vector3=(-worker._model.global_basis.z).normalized()
	var pole_angle:=_knee_plane_world.angle_to(forward)
	_knee_plane_world=_knee_plane_world.normalized().slerp(forward,minf(TOE_TURN*delta/maxf(pole_angle,.000001),1.0)).normalized()
	var old_pole: Vector3=pose._travel_poles[side]
	var old_pole_handoff: bool=pose._travel_pole_handoff
	pose._travel_poles[side]=_knee_plane_world
	pose._travel_pole_handoff=true
	pose._solve(sk,chain[0],chain[1],chain[2],ankle,1.0,foot_basis)
	pose._travel_poles[side]=old_pole
	pose._travel_pole_handoff=old_pole_handoff
	var toe := sk.get_bone_global_pose(toe_index)
	toe.basis = sk.global_basis.inverse()*wanted.basis
	sk.set_bone_global_pose(toe_index,toe)
	var actual: Transform3D = sk.global_transform*sk.get_bone_global_pose(toe_index)
	if actual.origin.distance_to(wanted.origin) > .002:
		# No force or leg-length increase can make an unreachable ankle valid.
		if phase == "retrieve": _abort_retrieval("The handle is outside finite foot reach; the same tool stays seated",pose,sk)
		else: drop("The back tool is outside finite foot reach")
		return -1
	_toe = actual
	# Measure the actual tool COM in the capsule frame. A WORLD toe delta
	# already includes native translation and omits the rotating tool offset;
	# adding it to native carrier velocity would count body travel twice.
	var current_worker: Transform3D = worker.global_transform
	var previous_local := _previous_worker.affine_inverse()*_tool_frame(before)
	var current_local := current_worker.affine_inverse()*_tool_frame(_toe)
	_toe_velocity = current_worker.basis*((current_local*_tool_com_local)-(previous_local*_tool_com_local))/maxf(delta,.000001)
	_toe_angular = current_worker.basis*_angular(previous_local.basis,current_local.basis,delta)
	_toe_motion_tick = Engine.get_physics_frames()
	_previous_worker = current_worker
	_previous_toe = before
	max_toe_step = maxf(max_toe_step,before.origin.distance_to(actual.origin))
	max_toe_turn = maxf(max_toe_turn,_turn(before.basis.get_rotation_quaternion(),actual.basis.get_rotation_quaternion())/maxf(delta,.000001))
	pose.evaluated_grounded[side] = false
	pose._target_valid[side] = false
	pose._walk_swing_phase[side] = -1.0
	if held: _publish_foot(actual)
	return 0 if refused_step else 1

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
				print("CONTRAPTION_BACK_TOOL current_return_refused ",JSON.stringify({"tool":worker.equipped_tool.part_id,"tool_rid":str(worker.equipped_tool.get_rid()),"source":source.part_id if is_instance_valid(source) else "none","source_rid":str(source.get_rid()) if is_instance_valid(source) else "none","job":worker.current_job_id,"action":worker.action,"progress":worker.action_progress,"serial":worker._pose.evaluation_serial,"toe":Part.encode_transform(sample),"hip":Part.encode_vector(hip),"root":Part.encode_transform(root),"reachable":reachable,"clear":frame_clear,"native_obstacle":last_native_obstacle.duplicate(true) if reachable else {},"posture":_posture_debug_at(_tool_frame(sample),root),"support_gap":_native_support_gap(_tool_frame(sample),worker._ground_point,worker.ground_normal)}))
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
	var evaluated_clear: bool = evaluated.origin.distance_to(actual.origin)<=.002 and _frame_clear(evaluated,root,true)
	if not evaluated_clear:
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
	_empty_return_age += delta
	var stepping: bool = _empty_return_active and not _step_plan.is_empty()
	if stepping:
		# Kick follow-through, then a step THROUGH: the empty foot lands ahead
		# under the advancing body before the tool comes down.
		wanted_sole = _step_sole(_empty_return_age)
	var qa:=_empty_ankle.get_rotation_quaternion().normalized()
	var qb:=foot.basis.get_rotation_quaternion().normalized()
	if stepping and _empty_return_age < float(_step_plan.t_land)*.5:
		# Follow-through keeps the flicked ankle, then turns toward the landing.
		qb = qa
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
		if plan_debug: print("CONTRAPTION_BACK_TOOL EMPTY_RETURN_STEP before=",_empty_sole," after=",actual_sole," wanted=",wanted_sole," hip=",hip," worker=",worker.global_position," span=",span," basis=",basis," oldbasis=",_empty_ankle," phase=",phase)
	empty_sole_step=maxf(empty_sole_step,_empty_sole.distance_to(actual_sole))
	empty_ankle_turn=maxf(empty_ankle_turn,_turn(_empty_ankle.get_rotation_quaternion(),actual.basis.get_rotation_quaternion())/maxf(delta,.000001))
	_empty_sole=actual_sole
	_empty_ankle=actual.basis
	if stepping and _empty_return_age >= float(_step_plan.t_land) and actual_sole.distance_to(wanted_sole)<.002 \
		and _turn(actual.basis.get_rotation_quaternion(),qb)<.002 and _plant_step(pose,side,actual_sole):
		# Touch-down: the same actual sole becomes Pose's support-local plant.
		print("CONTRAPTION_BACK_TOOL STEP_THROUGH_LANDED sole=",actual_sole," t=",snappedf(_empty_return_age,.001))
		_step_plan.clear()
		_empty_return_active=false
		_empty_return_tail=.24
		pose._gait_handoff_velocity[side]=Vector3.ZERO
		return
	if _empty_return_active:
		pose._target_valid[side]=false
		pose._walk_swing_phase[side]=-1.0
		pose.evaluated_grounded[side]=false
	elif actual_sole.distance_to(wanted_sole)>.01:
		pose.evaluated_grounded[side]=false
	if _empty_return_active and not stepping and _empty_return_age > EMPTY_RETURN_LIMIT:
		# Finite recovery: an empty leg that cannot converge (e.g. the ordinary
		# target keeps moving out of its reach) hands the leg back to ordinary
		# IK through Pose's own bounded gait handoff instead of owning it forever.
		print("CONTRAPTION_BACK_TOOL EMPTY_RETURN_TIMEOUT sole=",actual_sole," desired=",wanted_sole," age=",snappedf(_empty_return_age,.01))
		_empty_return_active=false
		_empty_return_tail=0.0
		_reset_foot_handoff(pose)
		return
	if _empty_return_active and actual_sole.distance_to(wanted_sole)<.002 and _turn(actual.basis.get_rotation_quaternion(),qb)<.002 \
		and ordinary_planted and (not _tool_free_recovery or (worker.action.is_empty() and pose._walking_ik)):
		print("CONTRAPTION_BACK_TOOL EMPTY_RETURN_DONE sole=",actual_sole," ground=",worker._ground_point," normal=",worker.ground_normal," desired=",wanted_sole)
		_empty_return_active=false
		# Match Pose's other recovery tails; the planted leg already converged.
		_empty_return_tail=.24
		pose._gait_handoff_velocity[side]=Vector3.ZERO

func _plan_step_through(flight: float) -> Dictionary:
	# After release: the toe carries on along the kick, ramping out over
	# FOLLOW_THROUGH, then the empty foot steps THROUGH and lands at its own
	# stance under the body's planned end position (d ahead) early in the
	# flight, taking the weight so the support foot can step up as well.
	var pose: SkeletonModifier3D = worker._pose
	if not pose or not pose.evaluated_valid or _advance.is_empty(): return {}
	var side := _foot_side
	var support := 1-side
	var rebase: Transform3D = worker.global_transform*pose.evaluated_worker.affine_inverse()
	var support_local: Vector3 = _body_frame.affine_inverse()*(rebase*pose.evaluated_soles[support])
	var stance_local := Vector3(-support_local.x,support_local.y,support_local.z)
	var forward: Vector3 = _advance.dir
	var landing: Vector3 = _body_frame*stance_local+forward*float(_advance.d)
	var hit: Dictionary = pose._walk_ground(landing)
	if hit.is_empty() or not hit.collider is Node3D: return {}
	var speed := _toe_velocity.length()
	var direction := _toe_velocity/speed if speed > .1 else Vector3.UP
	var follow := minf(FOLLOW_THROUGH,speed*.05)
	return {"start":_empty_sole,"direction":direction,"follow":follow,"t_follow":2.0*follow/maxf(speed,.5),
		"landing":Vector3(hit.position),"t_land":_step_times(flight).x,"lift":.05}

func _plan_support_step(flight: float) -> Dictionary:
	# The support foot's own short step up to its stance under the advanced
	# body, after the kick foot has taken the weight: both feet are square and
	# planted well before the catch (no split lunge through the absorb).
	var pose: SkeletonModifier3D = worker._pose
	if not pose or not pose.evaluated_valid or _advance.is_empty() or float(_advance.d) < .03: return {}
	var support := 1-_foot_side
	var rebase: Transform3D = worker.global_transform*pose.evaluated_worker.affine_inverse()
	var sole: Vector3 = rebase*pose.evaluated_soles[support]
	var hit: Dictionary = pose._walk_ground(sole+Vector3(_advance.dir)*float(_advance.d))
	if hit.is_empty() or not hit.collider is Node3D: return {}
	var t0 := _step_times(flight).y
	return {"start":sole,"landing":Vector3(hit.position),"t0":t0,"t1":minf(t0+.22,flight-.14),"lift":.045}

func _drive_support_step(pose: SkeletonModifier3D,sk: Skeleton3D,delta: float) -> void:
	# Owned support-foot step (same finite chain solve as the empty leg). It
	# lifts only after the kick foot has planted, moves the actual sole along
	# a short arc and plants it on the real ground it was planned on.
	if _support_step.is_empty(): return
	var side := 1-_foot_side
	var chain: Array = pose._chains[side]
	var st := _support_step
	st.clock = float(st.get("clock",0.0))+delta
	var offset := Vector3(0,pose._ankle_height[side],0)
	if not bool(st.get("started",false)):
		var kick_planted: bool = _step_plan.is_empty() and not _empty_return_active
		if float(st.clock) < float(st.t0) or not kick_planted:
			if float(st.clock) > float(st.t1)+.10 or phase not in ["flight","back"] or not worker.on_ground:
				_support_step.clear()
			return
		var foot: Transform3D = sk.global_transform*sk.get_bone_global_pose(chain[2])
		var hip: Vector3 = sk.global_transform*sk.get_bone_global_pose(chain[0]).origin
		var knee: Vector3 = sk.global_transform*sk.get_bone_global_pose(chain[1]).origin
		st.started = true
		st.s0 = float(st.clock)
		st.start = foot*offset
		st.basis = foot.basis
		var plane: Vector3 = (knee-hip).slide((foot.origin-hip).normalized())
		st.plane = plane.normalized() if plane.length_squared() > .00001 else (-worker._model.global_basis.z)
	var duration := maxf(float(st.t1)-float(st.t0),.12)
	var u := clampf((float(st.clock)-float(st.s0))/duration,0.0,1.0)
	var eased := u*u*(3.0-2.0*u)
	var landing: Vector3 = st.landing
	var sole: Vector3 = Vector3(st.start).lerp(landing,eased)+worker.ground_normal*float(st.lift)*sin(PI*u)
	var basis: Basis = st.basis
	var ankle := sole-basis*offset
	var hip_now: Vector3 = sk.global_transform*sk.get_bone_global_pose(chain[0]).origin
	var span: float = worker._leg_span(side)-.012
	if hip_now.distance_to(ankle) > span: ankle = hip_now+(ankle-hip_now).normalized()*span
	var old_pole: Vector3 = pose._travel_poles[side]
	var old_handoff: bool = pose._travel_pole_handoff
	pose._travel_poles[side] = st.plane
	pose._travel_pole_handoff = true
	pose._solve(sk,chain[0],chain[1],chain[2],sk.global_transform.affine_inverse()*ankle,1.0,sk.global_basis.inverse()*basis)
	pose._travel_poles[side] = old_pole
	pose._travel_pole_handoff = old_handoff
	for bone: int in [chain[0],chain[1]]: pose._gait_rotations[bone] = sk.get_bone_pose_rotation(bone)
	var actual: Vector3 = (sk.global_transform*sk.get_bone_global_pose(chain[2]))*offset
	st.max_step = maxf(float(st.get("max_step",0.0)),actual.distance_to(Vector3(st.get("last",actual))))
	st.last = actual
	pose._walk_swing_phase[side] = -1.0
	if u >= 1.0 and actual.distance_to(landing) < .01 and _plant_step(pose,side,actual):
		print("CONTRAPTION_BACK_TOOL SUPPORT_STEP_LANDED sole=",actual," t=",snappedf(float(st.clock),.001)," max_step=",snappedf(float(st.max_step),.0001))
		_stunt_metrics.support_step_landed = float(st.clock)
		_support_step.clear()
		_support_step_done = true
		pose._gait_handoff_velocity[side] = Vector3.ZERO
		return
	pose.evaluated_grounded[side] = false
	pose._target_valid[side] = false
	if u >= 1.0 and float(st.clock)-float(st.s0) > duration+.15:
		# Could not plant exactly: hand the leg back to Pose's own bounded handoff.
		_support_step.clear()
		_reset_foot_handoff(pose)

func _step_sole(age: float) -> Vector3:
	var plan := _step_plan
	var start: Vector3 = plan.start
	var t_follow: float = plan.t_follow
	var apex: Vector3 = start+Vector3(plan.direction)*float(plan.follow)
	if age <= t_follow:
		var u := clampf(age/maxf(t_follow,.001),0.0,1.0)
		return start+Vector3(plan.direction)*float(plan.follow)*(1.0-(1.0-u)*(1.0-u))
	var landing: Vector3 = plan.landing
	var u := clampf((age-t_follow)/maxf(float(plan.t_land)-t_follow,.05),0.0,1.0)
	var eased := u*u*(3.0-2.0*u)
	return apex.lerp(landing,eased)+Vector3.UP*float(plan.lift)*sin(PI*u)*(1.0-u)

func _plant_step(pose: SkeletonModifier3D,side: int,sole: Vector3) -> bool:
	var hit: Dictionary = pose._walk_ground(sole)
	if hit.is_empty() or not hit.collider is Node3D or Vector3(hit.position).distance_to(sole) > .01: return false
	pose._support[side] = weakref(hit.collider)
	pose._support_rids[side] = hit.rid
	pose._support_local[side] = (hit.collider as Node3D).to_local(hit.position)
	pose._targets[side] = hit.position
	pose._target_valid[side] = true
	pose._walk_swing_phase[side] = -1.0
	pose.evaluated_grounded[side] = true
	return true

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
	if plan_debug: print("CONTRAPTION_BACK_TOOL toss_request t=",Engine.get_physics_frames()," legacy_pending=",_legacy_pending," keepouts=",tool.get_meta(&"worker_tool_keepouts",[]))
	_lift_off.clear()
	if not _frame_clear(_toe,_root,true) and _only_observed_support_contact():
		# The ordinary carry can rest a wide stock box's empty corner on the
		# ground it stands on. The gather then lifts it straight off that same
		# support: within LIFT_OFF_RADIUS of the start, contact with exactly
		# that support body is admitted only while it never gets deeper than
		# it already is. Every other body, and every later pose, keeps the full
		# native clearance (no separate .35 s ordinary lift first).
		var support: Dictionary = worker.get_world_3d().direct_space_state.intersect_ray(worker._query)
		_lift_off = {"rid":support.rid,"origin":_toe.origin,"gap":_native_support_gap(_tool_frame(_toe),worker._ground_point,worker.ground_normal)}
		# The way home later ends with the same corner just clear of the ground.
		var home_lift: float = clampf(.006-float(_lift_off.gap),0.0,.06)
		_home_toe_body = _body_frame.affine_inverse()*Transform3D(_toe.basis,_toe.origin+worker.ground_normal*home_lift)
		if not _frame_clear(_toe,_root,true) or float(_lift_off.gap) < -.045:
			_lift_off.clear()
			if plan_debug: print("CONTRAPTION_BACK_TOOL toss_lift native=",JSON.stringify(last_native_obstacle)," posture=",JSON.stringify(_posture_debug(_tool_frame(_toe)))," lift=",worker._pose._held_lift)
			worker._pose._held_lift_time=.35
			_retry=.04
			_tool_id=0
			reason="Raising the original tool clear of its observed support"
			return
	_stunt.clear()
	_advance.clear()
	reason = ""
	# Keep the tool's current roll: lay it in with whichever native face is
	# nearer the trays (the legacy hop always uses the original upward face).
	_seat_flip = 1.0 if _toe.basis.x.dot(_body_frame.basis.x*_side_sign) >= 0.0 else -1.0
	if not _seat_face_ok(tool,_side_sign,_seat_flip) and _seat_face_ok(tool,_side_sign,-_seat_flip): _seat_flip = -_seat_flip
	_commit_seat(tool)
	_back_keepout = true
	_preflight_frame = worker._tool_clearance_frame()
	_preflight_frame.inverse = _root.affine_inverse()
	# Two stunts in a row refused at their own release re-check (a slope or
	# support the plan's margin did not cover): no third wind-up; the plain
	# bounded stow route takes over for this request.
	if not _launch_refused.is_empty() and worker.global_position.distance_to(_launch_refused_at) > .5: _launch_refused.clear()
	var stunt := {} if (_legacy_pending or _launch_refused.size() >= 2) else _plan_stunt()
	if stunt.has("pending") or stunt.has("exhausted"):
		# Continue the bounded search on the next tick (still on the toe); an
		# exhausted search hands the legacy route its own fresh tick.
		_legacy_pending = stunt.has("exhausted")
		if _legacy_pending: _stunt_metrics = {"planned":false,"search_ops":stunt.get("search_ops",0)}
		_back_keepout = false
		_preflight_frame = {}
		_tool_id = 0
		validation_usec = Time.get_ticks_usec()-started
		reason = "Planning the tool stunt"
		return
	var search_ops: int = int(_stunt_metrics.get("search_ops",0)) if _legacy_pending else 0
	_legacy_pending = false
	var clear_path := not stunt.is_empty()
	if clear_path:
		_stunt = stunt
		_waypoints = stunt.waypoints
	else:
		_seat_flip = 1.0 if _seat_face_ok(tool,_side_sign,1.0) else -1.0
		_commit_seat(tool)
		var legacy := _legacy_route_step(tool)
		if legacy == 0:
			# Continue the budgeted legacy preflight next tick (still on the toe).
			_legacy_pending = true
			_back_keepout = false
			_preflight_frame = {}
			_tool_id = 0
			validation_usec = Time.get_ticks_usec()-started
			reason = "Planning the tool stow"
			return
		clear_path = legacy > 0
	_back_keepout = false
	_preflight_frame = {}
	validation_usec = Time.get_ticks_usec()-started
	if not clear_path:
		if reason.is_empty(): reason = "No clear finite foot path to the back cradle"
		# Route refusals retry briskly; the 6 s stow budget still bounds them.
		_retry = maxf(_retry,1.0)
		_tool_id = 0
		_waypoints.clear()
		_stunt.clear()
		return
	_stow_local_waypoints.clear()
	var stow_inverse := _body_frame.affine_inverse()
	for waypoint: Transform3D in _waypoints:
		_stow_local_waypoints.append(stow_inverse * waypoint)
	_path_index = 0
	_age = 0.0
	phase = "prepare"
	_set_stage("gather" if not _stunt.is_empty() else "")
	_kick_time = 0.0
	_stunt_metrics = {"planned": not _stunt.is_empty(), "plan_usec": validation_usec, "legacy_search_ops": search_ops}
	if not _stunt.is_empty():
		for key: String in ["apex","advance","flight_seconds","release_speed","launch_point","candidate","front","flip","search_ops","search_ticks","d_reach","kick_speed","kick_spin","kick_seconds","turns","spin_option","T_adv","rise","lean","gather_route"]: _stunt_metrics[key] = _stunt.get(key)
	_return_segment_index=-1
	_stow_wait=0.0
	reason = ""
	worker._idle_heading = worker._heading
	worker.status_text = "Tossing tool into back cradle"
	worker.tool_pose_blocked = ""

func _legacy_route_candidates(tool: RigidBody3D) -> Array:
	# Original side-and-rear passage and short hop, kept as the final fallback
	# when no upward stunt arc is clear (low ceiling, crowded worksite). The
	# variants below are preflighted in budgeted chunks by _legacy_route_step.
	var side := _side_sign
	var outward := _axis_basis(_body_frame.basis*Vector3(side,0,0),_body_frame.basis.y)
	# The short hop now lands in the diagonal seat: the toe carries the tool
	# in its seated orientation, 26 cm behind its seat (the old rack depth).
	var inward := seat_basis()
	var back_axis:=_axis_basis(_body_frame.basis.z,_body_frame.basis.y)
	var rear := _reachable_rear(side,[outward,back_axis,inward])
	if not rear.is_finite():
		reason="The original ankle cannot reach behind the body"
		return []
	var root_points: Array[Vector3] = [Vector3(side*.57,-.52,-.38),rear,_body_frame.affine_inverse()*_legacy_hop_toe().origin]
	var routes: Array = [[Transform3D(_toe.basis,_body_frame*root_points[0]),Transform3D(outward,_body_frame*root_points[0]),
		Transform3D(outward,_body_frame*root_points[1]),Transform3D(back_axis,_body_frame*root_points[1]),
		Transform3D(inward,_body_frame*root_points[1]),Transform3D(inward,_body_frame*root_points[2])]]
	# An outward horizontal shaft can sweep an installed part or a depot
	# wall: the same finite side passage with the original stock upright.
	routes.append(_upright_stow_route(side,inward,back_axis))
	# An installed tyre can obstruct the first low diagonal withdrawal: raise
	# the toe toward the launch height before its first shaft turn.
	routes.append(_upright_stow_route(side,inward,back_axis,true))
	# The full pickaxe cutter: move its first turn outside that actual width.
	var width := maxf(.57,.405+float(tool.definition.size.x)*.5+.015)
	if width > .57: routes.append(_upright_stow_route(side,inward,back_axis,true,width))
	# A chassis edge can meet the upright head at the usual rear turn: turn
	# closer to the body first.
	var turn_depth := maxf(.48,.405+float(tool.definition.size.z)*.5+.01)
	if turn_depth < .58: routes.append(_upright_stow_route(side,inward,back_axis,false,.57,turn_depth))
	return routes.filter(func(route: Array) -> bool: return not route.is_empty())

func _legacy_route_step(tool: RigidBody3D) -> int:
	# Resumable legacy search: 1 found (_waypoints set), 0 continue next
	# tick, -1 refused. Each tick checks only budget-sized sample chunks.
	if _legacy_search.is_empty():
		var routes := _legacy_route_candidates(tool)
		if routes.is_empty(): return -1
		_legacy_search = {"routes":routes,"index":0}
	_preflight_frame = worker._tool_clearance_frame()
	_preflight_frame.inverse = _root.affine_inverse()
	var hip: Vector3 = worker.evaluated_hip(_foot_side)
	var budget_start := _plan_ops()
	var routes: Array = _legacy_search.routes
	while not _legacy_search.has("route") and int(_legacy_search.index) < routes.size():
		var room: int = (PLAN_OPS_PER_TICK-(_plan_ops()-budget_start))/3
		if room < 4: return 0
		var route: Array = routes[int(_legacy_search.index)]
		var result := _chunk_route_clear(_legacy_search,_toe,route,room,hip,_foot_side)
		if result == 0: return 0
		_legacy_search.index = int(_legacy_search.index)+1
		if result > 0:
			# The route is clear; the hop arc from its launch pose must be too
			# (checked in slices below before any motion is committed).
			_legacy_search.route = route
			_legacy_search.arc_k = 0
			break
	if not _legacy_search.has("route"):
		_legacy_search.clear()
		return -1
	var exact := _tool_frame(_legacy_hop_toe())
	var gravity := _gravity(tool)
	var wanted: Vector3 = (_body_frame*seat_point()-exact.origin)/FLIGHT_SECONDS+Vector3.UP*(gravity*FLIGHT_SECONDS*.5)
	var total := maxi(1,ceili(FLIGHT_SECONDS*60.0))
	while int(_legacy_search.arc_k) <= total:
		var room: int = (PLAN_OPS_PER_TICK-(_plan_ops()-budget_start))/(2+_native_colliders.size())
		if room < 3: return 0
		var k: int = _legacy_search.arc_k
		var last := mini(k+room-1,total)
		var clear := _arc_clear(exact,wanted,gravity,FLIGHT_SECONDS,k,last)
		if not clear:
			reason = "No clear hop arc to the back cradle"
			_legacy_search.clear()
			return -1
		_legacy_search.arc_k = last+1
	_waypoints.clear()
	for item: Transform3D in _legacy_search.route: _waypoints.append(item)
	_legacy_search.clear()
	return 1

## ---- Upward stunt planner ---------------------------------------------------
## gather (to a cocked pose in FRONT of the face) -> hold (slow-in) -> kick
## (timed toe trajectory: the tool COM runs a straight stroke at full speed
## while the toe rolls the tool about the seat axis) -> release (the tool
## inherits that measured motion; a small bounded impulse completes it) ->
## ballistic twirl over the head into the seat while the capsule steps
## forward under it. Every candidate passes the existing reach, whole-tool
## posture (against the MOVING body) and native checks; the first clear one
## wins, else the legacy route. The search is resumable under a per-tick
## query budget so no tick carries the whole search.
var plan_debug: bool = "--back-tool-plan-debug" in OS.get_cmdline_user_args()

func _plan_note(index: int,why: String,apex := -1.0,d := -1.0) -> void:
	if plan_debug: print("CONTRAPTION_BACK_TOOL plan_refused candidate=",index," why=",why," apex=",apex," advance=",d," native=",JSON.stringify(last_native_obstacle))

func _plan_ops() -> int:
	return ops_posture+ops_native

func _plan_stunt() -> Dictionary:
	var tool: RigidBody3D = worker.equipped_tool
	var forward: Vector3 = (-worker._model.global_basis.z).slide(worker.ground_normal)
	if forward.length_squared() < .01 or not worker.on_ground:
		_plan_search.clear()
		return {}
	forward = forward.normalized()
	var preferred := _seat_flip
	var key := [tool.get_instance_id(),_foot_side,preferred]
	if _plan_search.is_empty() or _plan_search.key != key or Engine.get_physics_frames()-int(_plan_search.tick) > 2:
		var d_reach := _advance_reach(forward) if not stunt_advance_disabled else 0.0
		var advances: Array[float] = []
		# With the support foot's own catch-up step during the flight, the
		# capsule may advance past the planted support's reach (checked per
		# plan against the support's lift-off time). The longer advance also
		# brings the cradle under the tool so it falls nearly straight down
		# onto the seat, clear of the plate.
		if not stunt_advance_disabled and d_reach >= ADVANCE_MIN and _step_advance_ok(forward,ADVANCE_MAX): advances.append(ADVANCE_MAX)
		if d_reach >= ADVANCE_MIN: advances.append(minf(.20,d_reach))
		if d_reach >= .12 and minf(.20,d_reach) > .125: advances.append(.12)
		advances.append(0.0)
		_plan_search = {"key":key,"cand":0,"apex":0,"spin":0,"adv":0,"stage":"pose","advances":advances,
			"d_reach":d_reach,"gather":{},"route":0,"steps":0,"ticks":0,"ops":0,"skip_apex":-1}
	_plan_search.tick = Engine.get_physics_frames()
	_plan_search.ticks = int(_plan_search.ticks)+1
	var budget_start := _plan_ops()
	var flips: Array[float] = [preferred]
	if _seat_face_ok(tool,_side_sign,-preferred): flips.append(-preferred)
	var candidates := _stunt_candidates(tool)
	# Search slots best tier first across BOTH seat faces (an asymmetric head
	# may only clear the body with one face out), then the next tier.
	var slots: Array = []
	for tier in 5:
		for flip_value: float in flips:
			for index in candidates.size():
				if int(candidates[index].tier) == tier: slots.append([flip_value,index])
	var advances: Array = _plan_search.advances
	var hip: Vector3 = worker.evaluated_hip(_foot_side)
	while int(_plan_search.cand) < slots.size():
		if _plan_search.has("unit_stage"):
			# The unit that just ran: remember its kind's worst cost.
			var unit_ops: int = _plan_ops()-budget_start-int(_plan_search.unit_mark)
			_plan_unit_cost[_plan_search.unit_stage] = maxi(int(_plan_unit_cost.get(_plan_search.unit_stage,0)),unit_ops)
			if plan_debug and unit_ops > 60: print("CONTRAPTION_BACK_TOOL plan_unit ",_plan_search.unit_stage," ops=",unit_ops," at=",int(_plan_search.unit_mark))
			_plan_search.erase("unit_stage")
		if _plan_ops()-budget_start >= PLAN_OPS_PER_TICK:
			_plan_search.ops = int(_plan_search.ops)+_plan_ops()-budget_start
			_seat_flip = preferred
			_commit_seat(tool)
			return {"pending":true}
		var flip: float = slots[int(_plan_search.cand)][0]
		var ci: int = slots[int(_plan_search.cand)][1]
		# Learn each unit kind's cost (ops) and yield BEFORE a unit that would
		# overrun this tick's budget, so one tick stays near PLAN_OPS_PER_TICK.
		var spent_now: int = _plan_ops()-budget_start
		var unit_kind := str(_plan_search.stage)
		var unit_guess: int = 12 if unit_kind == "gather" else maxi(int(_plan_unit_cost.get(unit_kind,0)),int(PLAN_UNIT_DEFAULT.get(unit_kind,8)))
		if spent_now > 0 and spent_now+unit_guess > PLAN_OPS_PER_TICK:
			_plan_search.erase("unit_stage")
			_plan_search.ops = int(_plan_search.ops)+spent_now
			_seat_flip = preferred
			_commit_seat(tool)
			return {"pending":true}
		_plan_search.unit_stage = unit_kind
		_plan_search.unit_mark = spent_now
		_seat_flip = flip
		_commit_seat(tool)
		var cand: Dictionary = candidates[ci]
		var gather_key := "%d:%d" % [int(flip),ci]
		match str(_plan_search.stage):
			"pose":
				# Cheap: the release toe itself is reachable and clear.
				var release_probe := Transform3D(_cock_basis(float(cand.lean),float(cand.get("blade",0.0))),_body_frame*Vector3(cand.point))
				if not _toe_reachable(release_probe,hip,_foot_side) or not _frame_clear(release_probe,_root,false):
					_plan_note(ci,"release_pose")
					_plan_next_candidate()
					continue
				_plan_search.stage = "solve"
			"solve":
				var ai: int = _plan_search.apex
				var si: int = _plan_search.spin
				var di: int = _plan_search.adv
				var apexes: Array = cand.apexes
				var spins: Array = cand.spins
				if ai >= apexes.size():
					_plan_next_candidate()
					continue
				if si < spins.size() and int(spins[si]) in _plan_search.get("skip_spins",[]):
					# This spin sense already met the body right after release; no
					# apex or advance changes that (the release frame is the same).
					_plan_search.spin = si+1
					_plan_search.adv = 0
					continue
				if si >= spins.size() or ai == int(_plan_search.skip_apex):
					_plan_search.apex = ai+1
					_plan_search.spin = 0
					_plan_search.adv = 0
					continue
				if di >= advances.size():
					_plan_search.spin = si+1
					_plan_search.adv = 0
					continue
				_plan_search.adv = di+1
				var apex: float = float(apexes[ai])
				if _launch_refused.has(_plan_key(flip,ci,apex,int(spins[si]))):
					# Its actual release already failed the launch-time arc re-check.
					_plan_search.spin = si+1
					_plan_search.adv = 0
					continue
				var plan := _solve_kick(Vector3(cand.point),apex,float(advances[di]),int(spins[si]),forward,float(cand.lean),float(cand.get("blade",0.0)))
				if plan.is_empty():
					_plan_note(ci,"solve",apex,float(advances[di]))
					continue
				if int(spins[si]) == 1 and float(plan.get("spin_correction",0.0)) > SPIN_CORRECTION_PREFERRED:
					_plan_note(ci,"spin_impulse",apex,float(advances[di]))
					continue
				var lift_off: float = _step_times(float(plan.T)).y
				if float(plan.advance) > float(_plan_search.d_reach)+.005 and float(plan.advance)*_minjerk(lift_off/float(plan.T_adv)) > float(_plan_search.d_reach)+.005:
					# The planted support could not follow until its own step lifts it.
					_plan_note(ci,"support_reach",apex,float(advances[di]))
					continue
				var cock: Transform3D = plan.cock
				_floor_margin = CROUCH_MARGIN
				var cock_clear := _frame_clear(cock,_root,false)
				_floor_margin = 0.0
				if not _toe_reachable(cock,hip,_foot_side) or not _toe_reachable(plan.release,hip,_foot_side) or not cock_clear:
					_plan_note(ci,"cock",apex,float(advances[di]))
					continue
				_plan_search.plan = plan
				_plan_search.stage = "arc_posture"
			"arc_posture","arc_native","kick","advance":
				# One check per budget unit; any refusal returns to the solve loop.
				var plan: Dictionary = _plan_search.plan
				var apex: float = plan.apex
				var check := str(_plan_search.stage)
				var passed := true
				match check:
					"arc_posture": passed = _stunt_arc_clear(_tool_frame(plan.release),plan.v,plan.omega,float(plan.T),forward,float(plan.advance),float(plan.T_adv),false)
					"arc_native": passed = _stunt_arc_clear(_tool_frame(plan.release),plan.v,plan.omega,float(plan.T),forward,float(plan.advance),float(plan.T_adv),true)
					"kick":
						_floor_margin = CROUCH_MARGIN
						passed = _kick_path_clear(plan,hip)
						_floor_margin = 0.0
					"advance": passed = float(plan.advance) <= 0.0 or _advance_clear(forward,float(plan.advance))
				if not passed:
					_plan_note(ci,check,apex,float(plan.advance))
					# A world obstacle (low ceiling): other spins/advances rarely help.
					if check == "arc_native": _plan_search.skip_apex = int(_plan_search.apex)
					if check == "arc_posture" and _arc_fail_time >= 0.0 and _arc_fail_time < .12:
						var skip: Array = _plan_search.get("skip_spins",[])
						skip.append(int(plan.spin_option))
						_plan_search.skip_spins = skip
					_plan_search.stage = "solve"
					_plan_search.erase("plan")
					continue
				var order := ["arc_posture","arc_native","kick","advance","gather"]
				_plan_search.stage = order[order.find(check)+1]
				_plan_search.route = 0
			"gather":
				# Resumable: gather routes are preflighted in sample chunks that
				# fit the remaining budget (one route may span several ticks).
				var plan: Dictionary = _plan_search.plan
				var cached: Variant = _plan_search.gather.get(gather_key)
				# First pass: short gathers only (a brisk raise into the cock); the
				# outboard detours join only if no candidate has a short one.
				var routes := _gather_routes(plan.cock,bool(_plan_search.get("long_gather",false)))
				if cached == null:
					var ri: int = _plan_search.route
					if ri >= routes.size():
						_plan_search.gather[gather_key] = []
						_plan_note(ci,"gather")
						_plan_next_candidate()
						continue
					var room: int = maxi((PLAN_OPS_PER_TICK-(_plan_ops()-budget_start))/3,4)
					var result := _chunk_route_clear(_plan_search,_toe,routes[ri],room,hip,_foot_side)
					if result == 0: continue
					_plan_search.route = ri+1
					if result > 0: _plan_search.gather[gather_key] = ri
					continue
				if cached is Array:
					_plan_next_candidate()
					continue
				var gather: Array[Transform3D] = routes[int(cached)]
				plan.waypoints = gather
				plan.gather_route = int(cached)
				plan.candidate = ci
				plan.front = bool(cand.front)
				plan.launch_point = Vector3(cand.point)
				plan.d_reach = _plan_search.d_reach
				plan.flip = flip
				plan.search_ops = int(_plan_search.ops)+_plan_ops()-budget_start
				plan.search_ticks = int(_plan_search.ticks)
				if plan_debug:
					var rel: Transform3D = _body_frame.affine_inverse()*_tool_frame(plan.release)
					print("CONTRAPTION_BACK_TOOL plan_accepted candidate=",ci," apex=",plan.apex," release_body=",rel.origin," y=",rel.basis.y," root_y=",_root.origin.y," rootlocal=",_root.affine_inverse()*_tool_frame(plan.release).origin," clear=",_frame_clear(plan.release,_root,false)," dbg=",JSON.stringify(_posture_debug_at(_tool_frame(plan.release),_root)))
				_plan_search.clear()
				return plan
	_seat_flip = preferred
	_commit_seat(tool)
	if not bool(_plan_search.get("long_gather",false)):
		# Second pass with the outboard gather detours (next tick).
		_plan_search.long_gather = true
		_plan_search.cand = 0
		_plan_search.gather = {}
		_plan_next_candidate()
		_plan_search.cand = 0
		_plan_search.ops = int(_plan_search.ops)+_plan_ops()-budget_start
		return {"pending":true}
	var spent := int(_plan_search.ops)+_plan_ops()-budget_start
	_plan_search.clear()
	return {"exhausted":true,"search_ops":spent}

static func _plan_key(flip: float,candidate: int,apex: float,spin_option: int) -> String:
	return "%d:%d:%.2f:%d" % [int(flip),candidate,apex,spin_option]

func _chunk_route_clear(state: Dictionary,start: Transform3D,route: Array,room: int,hip: Vector3,side: int) -> int:
	# One budgeted slice of a whole-tool route preflight (the same samples as
	# _path_clear: per segment, line/slerp at 25 mm / .05 rad). Returns 1 when
	# the whole route is clear, -1 when refused, 0 to resume next call.
	var seg: int = int(state.get("c_seg",0))
	var k: int = int(state.get("c_k",0))
	while true:
		var seg_start: Transform3D = start if seg == 0 else route[seg-1]
		var endpoint: Transform3D = route[seg]
		var from_q := seg_start.basis.get_rotation_quaternion()
		var end_q := endpoint.basis.get_rotation_quaternion()
		var count := maxi(1,ceili(maxf(seg_start.origin.distance_to(endpoint.origin)/.025,_turn(from_q,end_q)/.05)))
		var take := mini(count+1-k,room)
		for index in range(k,k+take):
			var fraction := float(index)/count
			var sample := Transform3D(Basis(from_q.slerp(end_q,fraction)),seg_start.origin.lerp(endpoint.origin,fraction))
			if not _toe_reachable(sample,hip,side) or not _frame_clear(sample,_root,true):
				if plan_debug:
					var rel: Transform3D = _body_frame.affine_inverse()*sample
					print("CONTRAPTION_BACK_TOOL route_refused seg=",seg,"/",route.size()," k=",index,"/",count," reach=",_toe_reachable(sample,hip,side)," toe_body=",rel.origin," y=",rel.basis.y," native=",JSON.stringify(last_native_obstacle).left(160)," posture=",JSON.stringify(_posture_debug(_tool_frame(sample))).left(300))
				state.erase("c_seg")
				state.erase("c_k")
				return -1
		room -= take
		k += take
		if k >= count+1:
			seg += 1
			k = 0
			if seg >= route.size():
				state.erase("c_seg")
				state.erase("c_k")
				return 1
		if room <= 0:
			state.c_seg = seg
			state.c_k = k
			return 0
	return 0

func _plan_next_candidate() -> void:
	_plan_search.cand = int(_plan_search.cand)+1
	_plan_search.apex = 0
	_plan_search.spin = 0
	_plan_search.adv = 0
	_plan_search.skip_apex = -1
	_plan_search.erase("skip_spins")
	_plan_search.stage = "pose"
	_plan_search.erase("plan")

func _stunt_candidates(tool: RigidBody3D) -> Array[Dictionary]:
	# Release toe points (body frame) with the tool's outward lean at the
	# cocked pose, most appealing first. A strictly frontal launch cannot land
	# on the back seat (the last ~.15 s of descent must already be behind the
	# back), so the kick sits beside the hip, a little in front, in view of
	# the face; the outward lean keeps the upright tool off the cube's side.
	# Tier 0: the near-hip kick (low abduction) whose ankle flick rolls the
	# tool inward over the top: a ~1 1/4 cartwheel about the seat axis, the
	# foot's own roll carrying nearly all of it (release impulse <= 1.6 rad/s).
	# A spinning 1.05 m tool passes vertical over the roof near its apex, so
	# its COM must clear the roof by more than half its length (~1.95-2.05 m
	# world for this rig). Tier 1: the same kicks rolling outward (~2/3 turn)
	# or the short twirl - a wide pickaxe head would sweep its inner spike
	# into the cube side on an inward roll. Tier 2: a low ~1.5 m lob with the
	# short twirl (ceilings). Tiers 3-4: wider and side fallbacks for crowded
	# sites, before the legacy hop.
	var s := _side_sign
	var wide := _keepout_half_width(tool) > .2
	var output: Array[Dictionary] = []
	var specs := []
	var points: Array[Vector3] = [Vector3(.33,-.48,.05),Vector3(.30,-.52,.10),Vector3(.36,-.45,0.0),Vector3(.32,-.50,-.04),Vector3(.36,-.56,.05),Vector3(.40,-.54,.02)]
	if not wide:
		for point: Vector3 in points:
			for lean: float in [66.0,72.0,60.0]:
				specs.append([point,lean,APEX_MAIN,[1],0])
	if wide:
		# A wide head held across the frontal plane beside the hip sweeps its
		# spike or handle-end slices into the cube's side as it travels inward:
		# it is kicked with the blade fore-and-aft (sagittal) instead, and the
		# ankle flick rolls it about the flight's own axis into the seat.
		for point: Vector3 in points:
			for lean: float in [66.0,72.0,78.0]:
				specs.append([point,lean,[2.12,2.18,2.24],[1],0])
	for point: Vector3 in points:
		for lean: float in [60.0,70.0]:
			specs.append([point,lean,APEX_MAIN+[2.12,2.18],[0,2],1])
	for point: Vector3 in points:
		for lean: float in [60.0,70.0]:
			specs.append([point,lean,APEX_LOW,[2],2])
	specs.append_array([
		[Vector3(.42,-.42,-.03),40.0,APEX_MAIN+APEX_LOW,[0,2],3],
		[Vector3(.55,-.45,-.05),30.0,APEX_MAIN+APEX_LOW,[0,2],3]])
	for spec: Array in specs:
		var point: Vector3 = spec[0]
		output.append({"point":Vector3(s*point.x,point.y,point.z),"lean":deg_to_rad(spec[1]),"apexes":spec[2],"spins":spec[3],"front":true,"tier":spec[4],"blade":float(spec[5]) if spec.size() > 5 else 0.0})
	var half_x := _keepout_half_width(tool)
	var lateral := maxf(.52,.405+half_x+.015+(.09 if half_x > .2 else 0.0))
	for point: Vector3 in [Vector3(lateral,-.30,.18),Vector3(lateral,-.26,.24),Vector3(lateral,-.20,.12)]:
		output.append({"point":Vector3(s*point.x,point.y,point.z),"lean":0.0,"apexes":APEX_LOW,"spins":[2],"front":false,"tier":4})
	return output

func _cock_basis(lean: float,blade: float) -> Basis:
	# Upright launch basis leaning outward (toward the tool foot's side) in
	# the frontal plane, i.e. turned about the shared seat axis; a wide head
	# may first be turned fore-and-aft about its own shaft (blade).
	var basis := (Basis(_body_frame.basis.z.normalized(),-_side_sign*lean)*_launch_basis_in(_body_frame.basis)).orthonormalized()
	if blade != 0.0: basis = (Basis(basis.y.normalized(),blade)*basis).orthonormalized()
	return basis

func _kick_basis(plan: Dictionary,angle: float) -> Basis:
	return (Basis(Vector3(plan.axis),angle)*Basis(plan.cock_basis)).orthonormalized()

static func _ramp_distance(speed: float,ramp: float,time: float) -> float:
	# Speed ramps linearly from 0 over `ramp` seconds, then holds.
	if time <= ramp: return speed*time*time/(2.0*ramp)
	return speed*(time-ramp*.5)

func _solve_kick(release_point: Vector3,apex: float,d: float,spin_option: int,forward: Vector3,lean := 0.0,blade := 0.0) -> Dictionary:
	# Release toe fixed; solve the ballistic arc (apex = tool COM height above
	# the ground), its spin and the straight kick stroke that delivers them
	# (fixed-point passes). The foot's roll (an ankle flick) supplies as much
	# of the spin as the toe's own per-tick speed budget allows; the bounded
	# release impulse only tops it up.
	var tool: RigidBody3D = worker.equipped_tool
	var grip := Vector3(0,.035+float(tool.definition.size.y)*.45,0)+_tool_com_local
	# Upright launch basis leaning outward (toward the tool foot's side) in
	# the frontal plane, i.e. turned about the shared seat axis.
	var cock_basis := _cock_basis(lean,blade)
	var axis: Vector3 = cock_basis.z.normalized()
	var release_toe: Vector3 = _body_frame*release_point
	var direct := PhysicsServer3D.body_get_direct_state(worker.get_rid())
	var worker_velocity: Vector3 = direct.linear_velocity if direct else worker.linear_velocity
	var up: Vector3 = worker.ground_normal if worker.ground_normal.length_squared() > .5 else Vector3.UP
	var ground: float = up.dot(worker._ground_point)
	var theta := 0.0
	var direction := Vector3.UP
	var speed := KICK_TOE_SPEED
	var kick_spin := 0.0
	var solved := {}
	var rise := 0.0
	for pass_index in 3:
		var release_basis := (Basis(axis,theta)*cock_basis).orthonormalized()
		var release := Transform3D(release_basis,release_toe)
		var com_height: float = up.dot(_tool_frame(release)*_tool_com_local)-ground
		rise = apex-com_height
		if rise < .25: return {}
		solved = _ballistic(_tool_frame(release),rise,d,forward,spin_option)
		if solved.is_empty(): return {}
		var omega: Vector3 = solved.omega
		# The short twirl turns about its own relative axis (a blade-turned
		# launch differs from the seat by more than a turn about its Z): the
		# ankle flick rolls the tool about that same flight axis.
		if spin_option == 2 and omega.length() > .1: axis = omega.normalized()
		var rate := omega.dot(axis)
		var relative_v: Vector3 = Vector3(solved.v)-worker_velocity
		speed = minf(KICK_TOE_SPEED,relative_v.length()*.97)
		direction = relative_v.normalized()
		# Largest flick roll (same sense as the flight spin) whose toe still
		# moves within the held-tool sole budget at the release instant: the
		# toe runs v_com - w x r (r = toe -> tool COM).
		var lever: Vector3 = release_basis*grip
		var best := -1.0
		for step in 41:
			var w := minf(absf(rate),KICK_SPIN_MAX)*(1.0-float(step)/40.0)
			var toe_v: Vector3 = direction*speed-(axis*(signf(rate)*w)).cross(lever)
			if toe_v.length() <= KICK_TOE_LIMIT:
				best = w
				break
		if best < 0.0: return {}
		kick_spin = signf(rate)*best
		solved.spin_correction = absf(rate-kick_spin)
		if float(solved.spin_correction) > STUNT_SPIN_CORRECTION_MAX:
			if plan_debug: print("CONTRAPTION_BACK_TOOL kick_solve_refused rate=",rate," kick_spin=",kick_spin," option=",spin_option," T=",solved.T)
			return {}
		# Whole physics ticks: the stroke's last published tick IS the planned
		# release frame (no one-tick-short release off the checked pose).
		var hz := float(Engine.physics_ticks_per_second)
		var seconds := ceilf((KICK_STROKE/speed+KICK_RAMP*.5)*hz-.001)/hz
		speed = KICK_STROKE/(seconds-KICK_RAMP*.5)
		theta = _ramp_distance(kick_spin,KICK_RAMP,seconds)
		solved.release = release
		solved.kick_seconds = seconds
	var release_basis: Basis = (solved.release as Transform3D).basis
	var com_release: Vector3 = release_toe+release_basis*grip
	var com_cock: Vector3 = com_release-direction*KICK_STROKE
	var cock := Transform3D(cock_basis,com_cock-cock_basis*grip)
	solved.cock = cock
	solved.cock_basis = cock_basis
	var velocity: Vector3 = solved.v
	var apex_time := maxf(velocity.y,0.0)/_gravity(tool)
	var apex_point: Vector3 = com_release+Vector3(velocity.x,0.0,velocity.z)*apex_time+Vector3.UP*rise
	solved.axis = axis
	solved.com_cock = com_cock
	solved.direction = direction
	solved.kick_speed = speed
	solved.kick_spin = kick_spin
	solved.grip = grip
	solved.release_speed = (Vector3(solved.v)-worker_velocity).length()
	solved.apex = apex
	solved.rise = rise
	solved.advance = d
	solved.dir = forward
	solved.flight_seconds = solved.T
	solved.spin_option = spin_option
	solved.lean = lean
	# The supported advance ends ~.1 s before contact: the body is under the
	# tool and square on both feet when it lands.
	solved.T_adv = clampf(float(solved.T)-.18,.30,.80)
	# Body-local copies: the kick is replayed relative to the moving body.
	var inverse := _body_frame.affine_inverse()
	solved.apex_local = inverse*apex_point
	solved.local = {"com_cock":inverse*com_cock,"direction":_body_frame.basis.inverse()*direction,
		"axis":_body_frame.basis.inverse()*axis,"cock_basis":_body_frame.basis.inverse()*cock_basis}
	return solved

func _hold_pose(plan: Dictionary,time: float) -> Transform3D:
	# The cocked pose, alive: the toe settles a little and the head dips (the
	# leg loads before the snap), back to the cocked pose as the kick starts.
	var base := _kick_pose(plan,0.0)
	var weight := sin(PI*clampf(time/HOLD_SECONDS,0.0,1.0))
	if weight <= 0.0: return base
	var up: Vector3 = _body_frame.basis.y.normalized()
	var axis: Vector3 = (_body_frame.basis*Vector3(plan.local.axis)).normalized()
	var head: Vector3 = base.basis.y.normalized()
	var sense := -1.0 if up.dot(axis.cross(head)) > 0.0 else 1.0
	return Transform3D((Basis(axis,sense*HOLD_TILT*weight)*base.basis).orthonormalized(),base.origin-up*HOLD_DIP*weight)

func _kick_pose(plan: Dictionary,time: float) -> Transform3D:
	# Toe frame at `time` into the kick, in WORLD through the current body.
	var local: Dictionary = plan.local
	var b := _body_frame.basis
	var com: Vector3 = _body_frame*Vector3(local.com_cock)+(b*Vector3(local.direction)).normalized()*_ramp_distance(float(plan.kick_speed),KICK_RAMP,time)
	var basis := (Basis((b*Vector3(local.axis)).normalized(),_ramp_distance(float(plan.kick_spin),KICK_RAMP,time))*(b*Basis(local.cock_basis))).orthonormalized()
	return Transform3D(basis,com-basis*Vector3(plan.grip))

func _kick_path_clear(plan: Dictionary,hip: Vector3) -> bool:
	# The timed stroke itself, sampled per tick: reach, whole-tool posture,
	# native clearance and the per-tick toe step budget.
	var seconds: float = plan.kick_seconds
	var count := maxi(2,ceili(seconds*120.0))
	var settled := _hold_pose(plan,HOLD_SECONDS*.5)
	if not _toe_reachable(settled,hip,_foot_side) or not _frame_clear(settled,_root,true): return false
	var previous := _kick_pose(plan,0.0)
	for index in count+1:
		var sample := _kick_pose(plan,seconds*float(index)/count)
		if sample.origin.distance_to(previous.origin) > KICK_TOE_STEP+.0005: return false
		if not _toe_reachable(sample,hip,_foot_side) or not _frame_clear(sample,_root,index%2 == 0 or index == count): return false
		previous = sample
	return true

func _gather_routes(cock: Transform3D,long := true) -> Array:
	# From the actual current toe (any authored toe direction, e.g. a tool
	# trailing behind on the floor) to the cocked pose. The tool turns
	# upright OUTBOARD of the body, never through it; a wide cutter first
	# turns its blade fore-and-aft. Each route is preflighted by the caller.
	var current := _body_frame.affine_inverse()*_toe
	var cock_local := _body_frame.affine_inverse()*cock
	var s := _side_sign
	var tool: RigidBody3D = worker.equipped_tool
	var wide := _keepout_half_width(tool) > .2
	var out_x := maxf(absf(current.origin.x)+.12,.58 if not wide else .62)
	var lift_y := maxf(current.origin.y+.14,-.90)
	var aside := Vector3(s*out_x,lift_y,current.origin.z)
	var aside_up := Vector3(s*out_x,maxf(lift_y,cock_local.origin.y-.10),minf(current.origin.z,cock_local.origin.z*.5))
	var upright := cock.basis
	# Blade fore-and-aft: the cock basis turned a quarter about its shaft.
	var sagittal := (Basis(cock.basis.y.normalized(),PI*.5)*cock.basis).orthonormalized()
	var lifted := _toe
	lifted.origin += _body_frame.basis.y*.14
	var routes: Array = []
	routes.append([cock])
	routes.append([lifted,cock])
	# Short arcs first: the shaft is raised (its far end up, off the floor)
	# while the toe lifts, then it turns straight into the cocked pose.
	var shaft: Vector3 = _toe.basis.y.normalized()
	var raise_axis: Vector3 = shaft.cross(_body_frame.basis.y.normalized())
	if raise_axis.length_squared() > .01:
		raise_axis = raise_axis.normalized()
		for pair: Vector2 in [Vector2(.12,deg_to_rad(35.0)),Vector2(.18,deg_to_rad(55.0))]:
			var raised := Transform3D((Basis(raise_axis,pair.y)*_toe.basis).orthonormalized(),_toe.origin+_body_frame.basis.y*pair.x)
			routes.append([raised,cock])
	if not long: return _route_arrays(routes)
	routes.append([Transform3D(_toe.basis,_body_frame*aside),Transform3D(upright,_body_frame*aside_up),cock])
	if wide: routes.append([Transform3D(_toe.basis,_body_frame*aside),Transform3D(sagittal,_body_frame*aside_up),Transform3D(sagittal,_body_frame*Vector3(cock_local.origin.x,cock_local.origin.y,cock_local.origin.z-.12)),cock])
	routes.append([lifted,Transform3D(_toe.basis,_body_frame*aside),Transform3D(upright,_body_frame*aside_up),cock])
	return _route_arrays(routes)

static func _route_arrays(routes: Array) -> Array:
	var output: Array = []
	for route: Array in routes:
		var points: Array[Transform3D] = []
		for item: Transform3D in route: points.append(item)
		output.append(points)
	return output

func _ballistic(release_tool: Transform3D,apex: float,d: float,forward: Vector3,spin_option := 0) -> Dictionary:
	# Free flight of the actual body: COM parabola plus constant world spin
	# about the seat axis into the seated basis. The seat is the cradle at
	# landing time: current body + planned advance + support (platform) motion.
	var tool: RigidBody3D = worker.equipped_tool
	var gravity := _gravity(tool)
	var com_local := _tool_com_local
	var p0: Vector3 = release_tool*com_local
	var vy := sqrt(2.0*gravity*apex)
	# Aim at the cradle as it will be at the catch: the body without this
	# stunt's own transient lean/shift (the acting has eased out by then).
	var settled := _settled_body_frame()
	var seat_basis_world := _seat_basis_in(settled.basis)
	var ground_velocity: Vector3 = worker.ground_velocity
	var seconds := .85
	var seat_com := Vector3.ZERO
	for pass_index in 3:
		# Aimed a little behind the seat line (AIM_BEHIND): the last part of
		# the fall stays clear of the plate; the rubber settle slides it home.
		seat_com = settled*(seat_point()+Vector3(0,0,AIM_BEHIND))+forward*d+ground_velocity*seconds+seat_basis_world*com_local+settled.basis.y*CATCH_CROUCH
		var fall := apex-(seat_com.y-p0.y)
		if fall < .05: return {}
		seconds = vy/gravity+sqrt(2.0*fall/gravity)
	var velocity: Vector3 = (seat_com-p0).slide(Vector3.UP)/seconds+Vector3.UP*vy
	var relative: Quaternion = (seat_basis_world*release_tool.basis.inverse()).get_rotation_quaternion().normalized()
	if relative.w < 0.0: relative = -relative
	var axis: Vector3 = (seat_basis_world.z).normalized()
	var angle := relative.get_angle()
	var signed := angle*signf(relative.get_axis().dot(axis)) if angle > .000001 else 0.0
	# Spin options (whole turns added about the same seat axis): 0 = the
	# other way round (>= 3/4 turn), 1 = the short way plus a full turn,
	# 2 = the short way (a slow quarter-ish twirl; last resort).
	var total := signed
	if spin_option == 0: total = signed-TAU*(1.0 if signed >= 0.0 else -1.0)
	elif spin_option == 1: total = signed+TAU*(1.0 if signed >= 0.0 else -1.0)
	var omega := axis*total/seconds
	if spin_option == 2 and angle > .000001: omega = relative.get_axis().normalized()*angle/seconds
	return {"T":seconds,"v":velocity,"omega":omega,"seat_com":seat_com,"p0":p0,"turns":absf(total)/TAU}

static func _minjerk(tau: float) -> float:
	tau = clampf(tau,0.0,1.0)
	return tau*tau*tau*(10.0+tau*(-15.0+6.0*tau))

func _stunt_arc_clear(origin: Transform3D,velocity: Vector3,omega: Vector3,seconds: float,forward: Vector3,d: float,advance_seconds: float,native: bool) -> bool:
	# Whole-tool posture against the body as it will be (planned advance and
	# support motion), plus a continuous native sweep of the actual shapes.
	_arc_fail_time = -1.0
	var tool: RigidBody3D = worker.equipped_tool
	var gravity := _gravity(tool)
	var com_local := _tool_com_local
	var p0: Vector3 = origin*com_local
	var ground_velocity: Vector3 = worker.ground_velocity
	var count := maxi(2,ceili(seconds*(30.0 if native else 60.0)))
	var space := worker.get_world_3d().direct_space_state
	if native:
		var exclusions: Array[RID]=worker.query_exclusions()
		exclusions.append(tool.get_rid())
		exclusions.append(holder.get_rid())
		_query.exclude=exclusions
	var previous := origin
	var spin := omega.length()
	var axis := omega/spin if spin > .000001 else Vector3.UP
	var reach := Vector3(tool.definition.size).length()*.5+.75
	# The body as it will be: this stunt's transient lean/crouch eased out
	# (the same settled frame the ballistic aims at), advancing under the tool.
	var settled := _settled_body_frame()
	var root_base := Transform3D((settled.basis*_rest_root_basis).orthonormalized(),settled.origin)
	for index in count+1:
		var time := seconds*float(index)/count
		var rotation := (Basis(axis,spin*time)*origin.basis).orthonormalized() if spin > .000001 else origin.basis
		var com := p0+velocity*time-Vector3.UP*(gravity*time*time*.5)
		var sample := Transform3D(rotation,com-rotation*com_local)
		if not native:
			# From the actual body at release to the settled one as Pose's acting eases out.
			var ease := smoothstep(0.0,.35,time)
			var base := Transform3D(Basis(_root.basis.get_rotation_quaternion().slerp(root_base.basis.get_rotation_quaternion(),ease)),_root.origin.lerp(root_base.origin,ease))
			var root_now := Transform3D(base.basis,base.origin+forward*(d*_minjerk(time/advance_seconds))+ground_velocity*time)
			# Far from the body no posture slice can touch it.
			if com.distance_to(root_now.origin) > reach: continue
			# Landing on the trays: the contact keepout (plate face) applies.
			_catch_keepout = time > seconds-.06
			var posture_clear := _frame_clear(_toe_for(sample),root_now,false)
			_catch_keepout = false
			if not posture_clear:
				_arc_fail_time = time
				if plan_debug:
					var body_now := Transform3D(_body_frame.basis,root_now.origin)
					var local := body_now.affine_inverse()*sample
					print("CONTRAPTION_BACK_TOOL arc_posture_refused t=",snappedf(time,.001),"/",snappedf(seconds,.001)," root_now=",root_now.origin," settled=",settled.origin," root=",_root.origin," d=",d," tool_body=",local.origin," x=",local.basis.x," y=",local.basis.y," posture=",JSON.stringify(_posture_debug_at(sample,root_now)))
				return false
		else:
			for shape_index in _native_colliders.size():
				_query.shape = _native_colliders[shape_index].shape
				_query.transform = previous*_native_local[shape_index]
				_query.motion = sample.origin-previous.origin
				ops_native += 1
				var motion := space.cast_motion(_query)
				if motion.size() != 2 or motion[0] < 1.0:
					last_native_obstacle = {"arc_time":time,"tool":Part.encode_transform(sample)}
					if plan_debug: print("CONTRAPTION_BACK_TOOL arc_native_refused t=",snappedf(time,.001)," tool_body=",_body_frame.affine_inverse()*sample.origin," info=",space.get_rest_info(_query))
					_query.motion = Vector3.ZERO
					return false
				# The cast translates the PREVIOUS orientation only, and Jolt's
				# shape cast ignores bodies it already overlaps: the spin between
				# samples can carry the head into a ceiling unseen. Overlap-test
				# the sample's own pose too.
				_query.motion = Vector3.ZERO
				_query.transform = sample*_native_local[shape_index]
				ops_native += 1
				if not space.intersect_shape(_query,1).is_empty():
					last_native_obstacle = {"arc_time":time,"tool":Part.encode_transform(sample),"overlap":true}
					if plan_debug: print("CONTRAPTION_BACK_TOOL arc_native_overlap t=",snappedf(time,.001)," tool_body=",_body_frame.affine_inverse()*sample.origin," hit=",space.intersect_shape(_query,1))
					return false
		previous = sample
	_query.motion = Vector3.ZERO
	return true

func _advance_reach(forward: Vector3) -> float:
	# The support sole stays planted while the capsule advances: the supporting
	# hip may move only as far as the finite leg (with the stunt crouch) reaches.
	var pose: SkeletonModifier3D = worker._pose
	if not pose or not pose.evaluated_valid: return 0.0
	var support := 1-_foot_side
	if not pose.evaluated_grounded[support]: return 0.0
	var rebase: Transform3D = worker.global_transform*pose.evaluated_worker.affine_inverse()
	var hip: Vector3 = rebase*pose.evaluated_hips[support]
	var ankle: Vector3 = rebase*(pose.evaluated_soles[support]-pose.evaluated_ankles[support]*Vector3(0,pose._ankle_height[support],0))
	var reach: float = worker._leg_lengths[support]-.012-.015
	var relative: Vector3 = hip-worker.ground_normal*.035-ankle
	var along := relative.dot(forward)
	var disc := along*along-relative.length_squared()+reach*reach
	if disc < 0.0: return 0.0
	return clampf(-along+sqrt(disc),0.0,ADVANCE_MAX)

func _step_advance_ok(forward: Vector3,d: float) -> bool:
	# The support foot can take its own catch-up step during the flight: real
	# walkable ground under both feet's squared landing points ahead.
	var pose: SkeletonModifier3D = worker._pose
	if not pose or not pose.evaluated_valid: return false
	var rebase: Transform3D = worker.global_transform*pose.evaluated_worker.affine_inverse()
	for side in 2:
		var sole: Vector3 = rebase*pose.evaluated_soles[side]
		var hit: Dictionary = pose._walk_ground(sole+forward*d)
		if hit.is_empty() or not hit.collider is Node3D: return false
		if absf(worker.ground_normal.dot(Vector3(hit.position)-sole)) > .06: return false
	return true

static func _step_times(flight: float) -> Vector2:
	# Kick foot touch-down (step-through) and the support foot's lift-off.
	var land := clampf(flight*.42,.30,.45)
	return Vector2(land,land+.03)

func _advance_clear(forward: Vector3,d: float) -> bool:
	# The capsule's own native shape must sweep the planned advance clear.
	var body: CollisionShape3D
	for child: Node in worker.get_children():
		if child is CollisionShape3D and not child.disabled and child.shape: body = child; break
	if not body: return false
	var exclusions: Array[RID]=worker.query_exclusions()
	exclusions.append(worker.equipped_tool.get_rid())
	exclusions.append(holder.get_rid())
	_query.exclude=exclusions
	_query.shape=body.shape
	_query.transform=body.global_transform.translated(worker.ground_normal*.02)
	_query.motion=forward*(d+.04)
	ops_native += 1
	var motion := worker.get_world_3d().direct_space_state.cast_motion(_query)
	_query.motion=Vector3.ZERO
	return motion.size()==2 and motion[0]>=1.0

static func _gravity(tool: RigidBody3D) -> float:
	return float(ProjectSettings.get_setting("physics/3d/default_gravity",9.8))*tool.gravity_scale

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
		_legacy_hop_toe()])
	return points

func _legacy_hop_toe() -> Transform3D:
	# Short-hop launch: the tool in its seated orientation at the old rack
	# depth behind its diagonal seat; the hop solve lands it on the trays.
	return _toe_for(Transform3D(seat_basis(),_body_frame*(seat_point()+Vector3(0,0,LEGACY_SEAT.z-SEAT_Z))))

func _request_retrieval(sk: Skeleton3D) -> void:
	if phase != "back" or _empty_return_active or _seat_settling or _retrieval_retry > 0.0 or not _safe_entry(true): return
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
	var lift:=_toe
	lift.origin+=worker.ground_normal*maxf(.10-worker.ground_normal.dot(_toe.origin-worker._ground_point),.03)
	var preflight_started: int=Time.get_ticks_usec() if source_budget_enabled else 0
	var native_before: int=_empty_toe_native_query_calls
	var samples_before: int=_empty_retrieval_sample_checks
	# Reverse of the toss: the empty toe rises beside its hip, turns into the
	# handle's frame a little down the shaft from the low handle end of the
	# diagonal seat, then slides up the shaft into the grip (actual contact).
	var start_local: Vector3=_body_frame.affine_inverse()*_toe.origin
	var shaft: Vector3 = target.basis.y.normalized()
	var pre := Transform3D(target.basis,target.origin-shaft*.09)
	var pre_local: Vector3 = _body_frame.affine_inverse()*pre.origin
	# Beside the hip and under the body's grown keepout (y < -.37), so the
	# empty foot rounds the cube's lower rear corner instead of grazing it.
	var beside_point := Vector3(side*maxf(absf(start_local.x)+.05,absf(pre_local.x)),minf(pre_local.y-.10,-.40),(start_local.z+pre_local.z)*.5)
	var behind_point := Vector3(beside_point.x,beside_point.y,maxf(beside_point.z,pre_local.z))
	# Candidates in order (fast passages first; a handle end close in behind
	# the plate passes under the rear corner all the way back, then rises);
	# the original rear passages last. Budgeted: ~70 ops per tick, resuming.
	var admitted := false
	var ops_start := _plan_ops()
	var index := _retrieval_cand
	var total := 6
	while index < total:
		if index > _retrieval_cand and _plan_ops()-ops_start > 70: break
		var route: Array[Transform3D] = []
		match index:
			# Direct: off the floor, straight up under the low handle end.
			0: route = [lift,pre,target]
			1: route = [lift,Transform3D(_toe.basis,_body_frame*beside_point),pre,target]
			2: route = [lift,Transform3D(target.basis,_body_frame*beside_point),pre,target]
			3: if behind_point.z > beside_point.z: route = [lift,Transform3D(target.basis,_body_frame*behind_point),pre,target]
			4, 5:
				# Original rear passage. Loose native stock can block its forward
				# corner; withdraw beside the current empty toe before moving rearward.
				var rear:=_reachable_rear(side,[_toe.basis,target.basis],-.52,hip)
				if rear.is_finite():
					if index == 4: route = [lift,Transform3D(_toe.basis,_body_frame*Vector3(side*.57,-.52,-.38)),Transform3D(target.basis,_body_frame*rear),target]
					else: route = [lift,Transform3D(_toe.basis,_body_frame*Vector3(side*.57,-.52,start_local.z)),
						Transform3D(_toe.basis,_body_frame*rear),Transform3D(target.basis,_body_frame*rear),target]
		index += 1
		if route.is_empty(): continue
		if _empty_retrieval_path_clear(lift,route,hip):
			admitted = true
			_waypoints = route
			_route_fast = index <= 4
			break
	if not admitted and index < total:
		# Resume the remaining candidates next tick (the seated tool stays put).
		_retrieval_cand = index
		return
	_retrieval_cand = 0
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
		# A refused route is re-tried briskly, not re-searched every tick.
		_retrieval_retry = .25
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
	_set_stage("reach")
	_retrieval_time = 0.0
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
			if not _toe_reachable(sample,hip,_foot_side) or not _empty_toe_clear(sample,_root):
				if plan_debug: print("CONTRAPTION_BACK_TOOL retrieval_refused point=",points.find(endpoint)," sample=",index,"/",count," reachable=",_toe_reachable(sample,hip,_foot_side)," toe_body=",_body_frame.affine_inverse()*sample.origin," hip_body=",_body_frame.affine_inverse()*hip," native=",JSON.stringify(last_native_obstacle))
				return false
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
	# The tool is held at the grip from here on. The return route is chosen
	# over the next ticks under the same query budget as the toss planner
	# (the toe keeps holding the actual contact pose meanwhile).
	var home := _body_frame*_home_toe_body
	var stored := home
	home=_supported_return_home(stored)
	# Walking stows record the carry pose mid-gait; after the stop the same
	# body-relative toe can sit lower. Lift it further rather than shed it.
	if not home.origin.is_finite(): home=_supported_return_home(stored,.10)
	if not home.origin.is_finite():
		drop("The original tool has no clear supported return pose")
		return
	var ends: Array[Transform3D] = []
	if not pending_action.is_empty():
		# A queued foot action enters best from a work-ready grip: the same home
		# toe point with the shaft raised forward toward the work.
		var saved_binding := _toe_in_ankle
		_toe_in_ankle = _home_toe_in_ankle
		var hip: Vector3 = worker.evaluated_hip(_foot_side)
		for pitch: float in [.70,.35]:
			for offset: Vector3 in [Vector3.ZERO,_body_frame.basis.y*.06-_body_frame.basis.z*.06]:
				var ready := _supported_return_home(Transform3D(_work_ready_basis(1.0,pitch),home.origin+offset))
				# Cheap reach prefilter with the final (home) toe curl.
				if ready.origin.is_finite() and _toe_reachable(ready,hip,_foot_side): ends.append(ready)
		_toe_in_ankle = saved_binding
	ends.append(home)
	var routes: Array = []
	for end: Transform3D in ends: routes.append_array(_draw_routes(toe,end))
	_return_search = {"routes":routes,"index":0,"home":home,"ticks":0}
	_home_extension_done = false
	_waypoints = []
	_return_local_waypoints.clear()
	_route_fast = true
	_draw_points = 0
	_set_stage("draw")
	_draw_started = _retrieval_time
	_draw_lift_t0 = -1.0
	_path_index = 0
	_wait = 0.0
	_age = 0.0
	worker.set_cargo(worker.cargo_mass)
	_continue_return_search()

func _continue_return_search() -> void:
	# Resumable return-route search: one preflighted route per budget unit.
	if _return_search.is_empty(): return
	var tool: RigidBody3D = worker.equipped_tool
	var budget_start := _plan_ops()
	_return_search.ticks = int(_return_search.ticks)+1
	var routes: Array = _return_search.routes
	var exclusions: Array[RID]=worker.query_exclusions()
	exclusions.append(tool.get_rid())
	exclusions.append(holder.get_rid())
	var request_frame: Dictionary=worker._tool_clearance_frame()
	request_frame.inverse=_root.affine_inverse()
	var same_request: Dictionary={"frame":request_frame,"native_samples":{},
		"tool_id":tool.get_instance_id(),"root":_root,"inverse":request_frame.inverse,"exclusions":exclusions,
		"grip_offset":.035+float(tool.definition.size.y)*.45,
		"space":worker.get_world_3d().direct_space_state} if return_preflight_reuse_enabled else {}
	# Resumable in sample chunks: each tick checks only as many samples of the
	# current route segment as the op budget affords (~3 ops per sample), then
	# resumes there. Samples are the runtime's own line/slerp points; along the
	# last segment the toe binding uncurls with the same fraction, exactly as
	# the eased return drives it.
	var foot_side: int = worker.tool_foot_side()
	var hip: Vector3 = worker.evaluated_hip(foot_side)
	while int(_return_search.index) < routes.size():
		var spent: int = _plan_ops()-budget_start
		var room: int = (PLAN_OPS_PER_TICK-spent)/3
		if spent > 0 and room < 4: return
		var route: Array = routes[int(_return_search.index)]
		var seg: int = int(_return_search.get("seg",0))
		var seg_start: Transform3D = _return_search.get("start",_toe) if seg == 0 else route[seg-1]
		if seg == 0 and not _return_search.has("start"): _return_search.start = _toe
		var endpoint: Transform3D = route[seg]
		var last: bool = seg == route.size()-1
		var from_q: Quaternion = seg_start.basis.get_rotation_quaternion()
		var end_q: Quaternion = endpoint.basis.get_rotation_quaternion()
		var count := maxi(1,ceili(maxf(seg_start.origin.distance_to(endpoint.origin)/.025,_turn(from_q,end_q)/.05)))
		var k: int = int(_return_search.get("k",0))
		var take := mini(count+1-k,maxi(room,4))
		var saved := _toe_in_ankle
		var grip_q := saved.basis.get_rotation_quaternion().normalized()
		var home_q := _home_toe_in_ankle.basis.get_rotation_quaternion().normalized()
		var ok := true
		same_request.erase("path_refusal")
		for index in range(k,k+take):
			var fraction := float(index)/count
			var sample := Transform3D(Basis(from_q.slerp(end_q,fraction)),seg_start.origin.lerp(endpoint.origin,fraction))
			if last: _toe_in_ankle = Transform3D(Basis(grip_q.slerp(home_q,fraction)),saved.origin.lerp(_home_toe_in_ankle.origin,fraction))
			var reachable := _toe_reachable(sample,hip,foot_side)
			var clear := reachable and _frame_clear(sample,_root,true,same_request)
			if not clear:
				ok = false
				var ankle: Vector3 = sample.origin-(sample.basis*_toe_in_ankle.basis.inverse())*_toe_in_ankle.origin
				same_request.path_refusal = {"waypoint":seg,"sample":index,"count":count,"reachable":reachable,"clear":clear,"toe":sample,
					"ankle":ankle,"binding":_toe_in_ankle,"hip":hip,"span":worker._leg_span(foot_side),"root":_root,
					"support_point":worker._ground_point,"support_normal":worker.ground_normal,"native_obstacle":last_native_obstacle.duplicate(true)}
				break
		_toe_in_ankle = saved
		var finished_segment := k+take >= count+1
		_return_search.k = k+take
		if ok and not finished_segment: continue
		if ok and not last:
			_return_search.seg = seg+1
			_return_search.k = 0
			continue
		for key: String in ["seg","k","start"]: _return_search.erase(key)
		_return_search.index = int(_return_search.index)+1
		if ok:
			var points: Array[Transform3D] = []
			for item: Transform3D in route: points.append(item)
			_stunt_metrics.return_route = int(_return_search.index)-1
			var fallback_route: bool = _return_search.has("fallback") and int(_return_search.index)-1 >= int(_return_search.fallback)
			if fallback_route:
				_set_stage("home")
				_route_fast = false
			_accept_return_route(points,0 if fallback_route else int(route.size()))
			_stunt_metrics.return_search_ticks = _return_search.ticks
			_return_search.clear()
			return
		if plan_debug and same_request.has("path_refusal"): print("CONTRAPTION_BACK_TOOL draw_refused route=",int(_return_search.index)-1," seg=",seg," ",_draw_refusal_note(same_request))
	if not _return_search.has("fallback"):
		# Every draw route refused: the original (slower) rear routes join the
		# same budgeted search instead of running synchronously in one tick.
		var fallback := _return_fallback_routes(_return_search.home)
		if fallback.is_empty():
			_return_search.clear()
			drop("The recovered original tool has no finite return path")
			return
		_return_search.fallback = routes.size()
		routes.append_array(fallback)
		return
	_return_search.clear()
	_publish_return_path_refusal(same_request)
	drop("The original tool has no finite clear work-entry path")

func _return_fallback_routes(home: Transform3D) -> Array:
	# The original rear passages (main, exterior work entry, upright and
	# raised upright), as point lists for the budgeted search.
	var side := _side_sign
	var toe := _toe
	var outward := _axis_basis(_body_frame.basis*Vector3(side,0,0),_body_frame.basis.y)
	var back_axis:=_axis_basis(_body_frame.basis.z,_body_frame.basis.y)
	var routes: Array = []
	var rear:=_reachable_rear(side,[toe.basis,back_axis,outward])
	if not rear.is_finite(): return routes
	var mid: Vector3 = _body_frame*Vector3(side*.57,-.52,-.38)
	var main: Array = [Transform3D(toe.basis,_body_frame*rear),Transform3D(back_axis,_body_frame*rear),Transform3D(outward,_body_frame*rear),Transform3D(outward,mid),Transform3D(home.basis,mid),home]
	routes.append(main)
	# A newly installed body can occupy yesterday's neutral-tool endpoint:
	# retain the verified exterior staging pose instead.
	var exterior:=_supported_return_home(Transform3D(outward,mid))
	if exterior.origin.is_finite():
		var alt := main.duplicate()
		alt[4] = exterior
		alt[5] = exterior
		routes.append(alt)
	var upright := _axis_basis(_body_frame.basis.y,_body_frame.basis.z)
	var back_flip := _axis_basis(_body_frame.basis.z,-_body_frame.basis.y)
	var upright_rear := _reachable_rear(side,[toe.basis,back_axis,back_flip,upright])
	if upright_rear.is_finite():
		var behind: Vector3 = _body_frame*upright_rear
		var front: Vector3 = _body_frame*Vector3(side*.57,-.52,-.38)
		var points: Array = [Transform3D(toe.basis,behind),Transform3D(back_axis,behind),Transform3D(back_flip,behind),
			Transform3D(upright,behind),Transform3D(upright,front),Transform3D(home.basis,front),home]
		routes.append(points)
		var upright_exterior := _supported_return_home(Transform3D(upright,front))
		if upright_exterior.origin.is_finite():
			var alt_up := points.duplicate()
			alt_up[-2] = upright_exterior
			alt_up[-1] = upright_exterior
			routes.append(alt_up)
		# The low side passage can meet loose stock: raise the upright tool on
		# its clear rear side before moving forward.
		var raised: Vector3 = _body_frame*Vector3(side*.57,-.18,upright_rear.z)
		var raised_front := _supported_return_home(Transform3D(upright,_body_frame*Vector3(side*.57,-.18,-.38)))
		if raised_front.origin.is_finite():
			routes.append([Transform3D(toe.basis,behind),Transform3D(back_axis,behind),Transform3D(back_flip,behind),
				Transform3D(upright,behind),Transform3D(upright,raised),raised_front,raised_front])
	return routes

func _accept_return_route(points: Array[Transform3D],draw_points: int) -> void:
	_waypoints = points
	_return_local_waypoints.clear()
	var inverse := _body_frame.affine_inverse()
	for point: Transform3D in points: _return_local_waypoints.append(inverse*point)
	_draw_points = mini(2,draw_points)
	_path_index = 0
	_return_segment_index = -1
	_wait = 0.0

func _draw_refusal_note(same_request: Dictionary) -> String:
	var failure: Dictionary = same_request.path_refusal
	var toe: Transform3D = failure.toe
	return JSON.stringify({"waypoint":failure.waypoint,"sample":failure.sample,"count":failure.count,"reachable":failure.reachable,"clear":failure.clear,
		"toe_body":_body_frame.affine_inverse()*toe.origin,"posture":_posture_debug_at(_tool_frame(toe),_root),"native":failure.native_obstacle})

func _work_ready_basis(roll := 1.0,pitch := .70) -> Basis:
	# Shaft raised forward toward the work (pitch in radians above level).
	var forward: Vector3 = -_body_frame.basis.z
	return _axis_basis((_body_frame.basis.y*sin(pitch)+forward*cos(pitch)).normalized(),_body_frame.basis.x*(roll if roll != 0.0 else 1.0))

func _draw_routes(toe: Transform3D,end: Transform3D) -> Array:
	# Reverse of the stunt: lift the shaft off both trays (along their normal)
	# and draw it out along its own axis, then either swing straight into the
	# end pose, or twirl it upright beside the hip first (and, when the work
	# roll differs, turn it half about its shaft out there). Wide variant last.
	var s := _side_sign
	var tool: RigidBody3D = worker.equipped_tool
	var normal: Vector3 = (_body_frame.basis*_seat_normal).normalized()
	var lift := Transform3D(toe.basis,toe.origin+normal*.06-toe.basis.y.normalized()*.03)
	var upright: Basis = _launch_basis_in(_body_frame.basis)
	var half_width := _keepout_half_width(tool)
	var lateral := maxf(.52,maxf(.405+half_width+.03,BACK_BOUNDS.end.x+half_width+.012))
	var lift_local: Vector3 = _body_frame.affine_inverse()*lift.origin
	var end_local: Vector3 = _body_frame.affine_inverse()*end.origin
	# Staging stands the tool outboard far enough that a cross head (up to
	# 12 cm half-length at the toe's height + .76) passes clear of the cube side.
	var staging := Vector3(s*maxf(lateral+.035,.585),end_local.y+.14,end_local.z)
	var routes: Array = []
	routes.append([lift,Transform3D(end.basis,_body_frame*staging),end])
	# The reverse twirl stays in the tray plane (behind the plate) until the
	# tool stands upright outboard of the hip, then comes forward.
	# The compact variant turns while it travels (each segment's time is the
	# larger of its move and its turn, so overlapping them saves ~.4 s); the
	# stepped variants stop to turn in place out there.
	var reversed := end.basis.x.dot(upright.x) < 0.0
	var quarter := Basis(_body_frame.basis.y,s*PI*.5)
	# A wide head (pickaxe blade) would need an unreachable lateral beside the
	# hip (and edge-on it sweeps the cube's rear corner): it takes the wide route.
	for compact: bool in ([] if lateral > .62 else [true,false]):
		for depth: float in [lift_local.z+.02,lift_local.z+.09]:
			if compact and depth > lift_local.z+.05: continue
			var low := Vector3(s*lateral,-.42,depth)
			var twirl: Array = [lift]
			if reversed and compact: twirl.append(Transform3D((quarter*upright).orthonormalized(),_body_frame*low))
			else:
				twirl.append(Transform3D(upright,_body_frame*low))
				if reversed:
					twirl.append(Transform3D((quarter*upright).orthonormalized(),_body_frame*low))
					twirl.append(Transform3D((quarter*quarter*upright).orthonormalized(),_body_frame*low))
			twirl.append_array([Transform3D(end.basis,_body_frame*staging),end])
			routes.append(twirl)
	# Wide: lay it outward beside and behind the hip, swing it down and in at
	# foot height, then turn it into the end pose under the body.
	var outward: Vector3 = _body_frame.basis.x*s
	var level: Vector3 = end.basis.y.slide(_body_frame.basis.y)
	var swing := end.basis
	if level.length_squared() > .01: swing = (Basis(Quaternion(level.normalized(),outward))*end.basis).orthonormalized()
	var behind := Vector3(s*lateral,-.42,lift_local.z)
	var wide_point := Vector3(s*lateral,maxf(end_local.y+.18,-.75),(lift_local.z+end_local.z)*.5)
	var low_point := Vector3(s*maxf(absf(end_local.x)+.04,.36),end_local.y+.05,end_local.z)
	routes.append([lift,Transform3D(upright,lift.origin),Transform3D(upright,_body_frame*behind),Transform3D(swing,_body_frame*wide_point),
		Transform3D(swing,_body_frame*low_point),Transform3D(end.basis,_body_frame*low_point),end])
	return routes

func _binding_restore_reachable(at: Transform3D) -> bool:
	# The held toe uncurls to its walking binding before/while lowering home:
	# every intermediate binding must keep this toe pose within reach.
	var saved:=_toe_in_ankle
	var start:=saved.basis.get_rotation_quaternion().normalized()
	var end:=_home_toe_in_ankle.basis.get_rotation_quaternion().normalized()
	var count:=maxi(1,ceili(_turn(start,end)/.04))
	var hip: Vector3=worker.evaluated_hip(_foot_side)
	var clear:=true
	for index in count+1:
		_toe_in_ankle.basis=Basis(start.slerp(end,float(index)/count))
		if not _toe_reachable(at,hip,_foot_side):
			clear=false
			break
	_toe_in_ankle=saved
	return clear

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
	if phase=="prepare" and not _stunt.is_empty():
		# Gather: a brisk start, quick corners and a slow-in to the cocked pose
		# (the timed kick that follows has its own ramp-in and no ramp-out).
		var last: bool = _path_index==_waypoints.size()-1
		return Vector2(.05 if _path_index==0 else .02,.09 if last else .02)
	if _route_fast:
		if _path_index==_waypoints.size()-1: return Vector2(.03,.07) if phase=="retrieve" else Vector2(.035,.09)
		return Vector2(.035,.035)
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

func _segment_toe_speed() -> float:
	if phase=="prepare" and not _stunt.is_empty(): return GATHER_TOE_SPEED
	if _route_fast and phase in ["retrieve","return"]: return RETRIEVE_TOE_SPEED
	return TOE_SPEED

func _segment_toe_turn() -> float:
	if phase=="prepare" and not _stunt.is_empty(): return STUNT_TURN
	if _route_fast and phase in ["retrieve","return"]: return RETRIEVE_TURN
	return TOE_TURN

func _set_stage(next: String) -> void:
	if stage != next: _stage_age = 0.0
	stage = next

func _transfer_owns_tool() -> bool:
	# Phases in which the tool is genuinely between custodies (on the moving
	# toe or airborne). A seated tool, including during retrieval before toe
	# contact, is never released by an interruption.
	return phase in ["prepare","flight","return"]

func _abort_retrieval(explanation: String,pose: SkeletonModifier3D = null,sk: Skeleton3D = null) -> void:
	# The empty toe never touched the handle: the same tool is still seated on
	# back_anchor. Return to that custody and recover the empty leg from its
	# actual current pose (WORLD sole/ankle), exactly like after a launch.
	if phase != "retrieve": return
	var tool: RigidBody3D = worker.equipped_tool
	if not is_instance_valid(tool) or tool.carrier != back_anchor:
		drop(explanation)
		return
	print("CONTRAPTION_BACK_TOOL retrieval_aborted ",JSON.stringify({"reason":explanation,"tool":tool.part_id,"rid":str(tool.get_rid()),"waypoint":_path_index}))
	phase = "back"
	_set_stage("")
	_route_fast = false
	_waypoints.clear()
	_retrieval_local_waypoints.clear()
	_wait = 0.0
	_age = 0.0
	reason = explanation
	worker.status_text = explanation
	if pose == null: pose = worker._pose
	if pose and worker.on_ground and worker.is_available():
		var chain: Array = pose._chains[_foot_side]
		if sk:
			var ankle: Transform3D = sk.global_transform*sk.get_bone_global_pose(chain[2])
			_empty_ankle = ankle.basis
			_empty_sole = ankle*Vector3(0,pose._ankle_height[_foot_side],0)
		elif pose.evaluated_valid:
			var rebase: Transform3D = worker.global_transform*pose.evaluated_worker.affine_inverse()
			_empty_sole = rebase*pose.evaluated_soles[_foot_side]
			_empty_ankle = rebase.basis*pose.evaluated_ankles[_foot_side]
		_empty_return_active = true
		_empty_return_tail = 0.0
		_empty_return_age = 0.0
		_step_plan.clear()
	_reset_foot_handoff(pose)

## ---- Worn seat --------------------------------------------------------------
## Body frame: +X right, +Y up, +Z back; s = tool foot side, f = resting face.
## The tool lies diagonally across the fitted plate ("antenna"): its handle
## end low on the tool foot's side near the hip, its head raised toward the
## far side, its measured keepout below the roof (head-first pickups keep
## their contact face) and SEAT_AIR in front of the plate. Two rubber trays
## carry the visual shaft at stations on both sides of the native COM; the
## tray tops are measured from the tool's own visual surface.
func seat_point() -> Vector3:
	# Body-frame seat of the tool origin (native box centre).
	return _seat_local.origin

func seat_basis() -> Basis:
	# Seated tool axes in WORLD: Y along the shaft toward the head (up across
	# the back toward the far side), Z = s*f * back, X = Y x Z... completed.
	return _seat_basis_in(_body_frame.basis)

func _seat_basis_in(b: Basis) -> Basis:
	return (b*_seat_local.basis).orthonormalized()

func _launch_basis_in(b: Basis) -> Basis:
	# Upright launch pose: shaft up. The seat differs only by a turn about the
	# shared Z axis (s*f*back), so a pure twirl about Z lays it in.
	return Basis(b.x*(_side_sign*_seat_flip),b.y,b.z*(_side_sign*_seat_flip)).orthonormalized()

static func _seat_basis_local(tilt: float,s: float,f: float) -> Basis:
	var c := cos(tilt)
	var n := sin(tilt)
	return Basis(Vector3(s*n,c,0.0)*f,Vector3(-s*c,n,0.0),Vector3(0.0,0.0,s*f))

func _seat_spec(tool: RigidBody3D) -> Dictionary:
	# tilt: head end raised toward the far side; shift: origin toward the far
	# side; y_max: highest origin; pads: shaft stations of the two trays.
	# The low (handle-side) tray sits close enough to the centre that all
	# tray hardware stays >= 4 cm above the cube's bottom edge; both trays
	# still bracket the tool's centre of mass.
	if seat_override.size() == 3:
		return {"tilt":deg_to_rad(seat_override[0]),"shift":seat_override[1],"y_max":seat_override[2],"pads":[-.14,.20]}
	if is_instance_valid(tool) and _keepout_half_width(tool) > .2:
		# Wide cutter: a shallower tilt and a larger far shift keep its blade
		# outboard of the far leg and its keepout under the roof.
		return {"tilt":deg_to_rad(15.0),"shift":.16,"y_max":-.10,"pads":[-.125,.12]}
	# Compact head (mallet): its handle end sits low just outboard of the hip
	# (an easy toe target: little abduction), the head peeks out past the far
	# shoulder; both trays stay inside the hip lane and bracket the COM.
	return {"tilt":deg_to_rad(30.0),"shift":.12,"y_max":-.044,"pads":[-.14,.14]}

func _seat_layout_for(tool: RigidBody3D,s: float,f: float) -> Dictionary:
	# Pure geometry for one tool/side/face (cached): seat frame (body), tray
	# tops (body), tray normal (body) and the tool-local contact features.
	var key := "%d:%d:%d" % [tool.get_instance_id() if is_instance_valid(tool) else 0,int(s),int(f)]
	if _seat_layouts.has(key): return _seat_layouts[key]
	var spec := _seat_spec(tool)
	var tilt: float = spec.tilt
	var basis := _seat_basis_local(tilt,s,f)
	var top := -INF
	var boxes: Array = tool.get_meta(&"worker_tool_keepouts",[]) if is_instance_valid(tool) else []
	for box: AABB in boxes:
		for corner in 8: top = maxf(top,(basis*box.get_endpoint(corner)).y)
	if top == -INF: top = .36
	var origin := Vector3(-s*float(spec.shift),minf(float(spec.y_max),SEAT_TOP_MAX-top),_seat_depth(tool))
	var frame := Transform3D(basis,origin)
	var normal := Vector3(s*sin(tilt),cos(tilt),0.0)
	var features: Array[Vector3] = []
	var tops: Array[Vector3] = []
	for station: float in spec.pads:
		var low := _shaft_low(tool,station,f)
		var feature := Vector3(-f*low,station,0.0)
		features.append(feature)
		tops.append(frame*feature)
	var layout := {"frame":frame,"normal":normal,"features":features,"tops":tops,"tilt":tilt,"s":s,"f":f}
	_seat_layouts[key] = layout
	return layout

func _seat_face_ok(tool: RigidBody3D,s: float,f: float) -> bool:
	# A resting face whose underside drops a tray (e.g. onto a pickaxe's
	# hanging spike) would hang the tray hardware below the cube: not offered.
	var layout := _seat_layout_for(tool,s,f)
	var lowest := INF
	for top: Vector3 in layout.tops: lowest = minf(lowest,top.y)
	return lowest-TRAY_HARDWARE_BELOW_TOP >= CUBE_BOTTOM_Y+HARDWARE_ABOVE_BOTTOM-.0005

func _shaft_low(tool: RigidBody3D,station: float,f: float) -> float:
	# Distance of the tool's lowest VISUAL surface below its axis (along the
	# resting "down" = -f*X) near one shaft station. Mesh vertices first;
	# the grown keepout band is the fallback (minus its 5 mm growth).
	var low := -INF
	if is_instance_valid(tool):
		_cache_tool(tool)
		for point: Vector3 in _visual_points:
			if absf(point.y-station) <= .06: low = maxf(low,-f*point.x)
		if low == -INF:
			for box: AABB in tool.get_meta(&"worker_tool_keepouts",[]):
				if station >= box.position.y and station <= box.end.y:
					low = maxf(low,maxf(-f*box.position.x,-f*box.end.x)-.005)
	return low if low > -INF else .023

func _commit_seat(tool: RigidBody3D) -> void:
	# The seat this transfer uses; the holder hardware follows it.
	var layout := _seat_layout_for(tool,_side_sign,_seat_flip)
	_seat_local = layout.frame
	_seat_normal = layout.normal
	_pad_features = layout.features
	_pad_tops = layout.tops
	_seat_z = _seat_local.origin.z
	var key := [_side_sign,_seat_flip,tool.get_instance_id() if is_instance_valid(tool) else 0]
	# The hardware follows through _update_holder_display (never per candidate).
	if key != _holder_layout_key: _holder_layout_key = key

func _pad_gap(tool_body: Transform3D,index: int) -> float:
	# Signed height of tray `index`'s contact feature above its rubber top
	# (body frame); <= 0 is contact, the sensor overlaps below PAD_PRELOAD.
	return _seat_normal.dot(tool_body*_pad_features[index]-_pad_tops[index])

func tray_contacts(at: Variant = null) -> Array:
	# Actual native query of each contact feature against this cradle's own
	# two tray sensors (shape index = tray), at the tool's pose or a proposed
	# pose of the same body. Read-only; used by the catch.
	var output := [false,false]
	var tool: RigidBody3D = worker.equipped_tool
	if not is_instance_valid(tool) or _pad_features.size() != 2: return output
	var frame: Transform3D = at if at is Transform3D else tool.global_transform
	var exclusions: Array[RID] = worker.query_exclusions()
	for cradle: Node in worker.get_tree().get_nodes_in_group(&"wako_back_cradles"):
		if cradle != holder and cradle is CollisionObject3D: exclusions.append(cradle.get_rid())
	_contact_query.exclude = exclusions
	_contact_query.shape = _feature_shape
	var up := frame.basis*Vector3(_seat_flip,0,0)
	for index in 2:
		_contact_query.transform = Transform3D(frame.basis,frame*_pad_features[index]+up.normalized()*.002)
		ops_native += 1
		for hit: Dictionary in worker.get_world_3d().direct_space_state.intersect_shape(_contact_query,4):
			if hit.collider == holder and int(hit.shape) == index: output[index] = true
	return output

func _settled_body_frame() -> Transform3D:
	# Current evaluated body frame minus Pose's transient sway (applied to the
	# root as origin += shift, basis = pitch * roll * authored, skeleton space).
	var pose: SkeletonModifier3D = worker._pose
	if not pose or not pose.evaluated_valid: return _body_frame
	var skb: Basis = worker._skeleton.global_basis.orthonormalized()
	var yaw: float = float(_acting.get("yaw",0.0)) if not _acting.is_empty() else 0.0
	var undo: Basis = skb*Basis(Vector3.BACK,-float(pose._sway_roll))*Basis(Vector3.RIGHT,-float(pose._sway_pitch))*Basis(Vector3.UP,-yaw)*skb.inverse()
	return Transform3D((undo*_body_frame.basis).orthonormalized(),_body_frame.origin-skb*Vector3(pose._sway_shift))

static func _keepout_half_width(tool: RigidBody3D) -> float:
	var half := float(tool.definition.size.x)*.5
	for box: AABB in tool.get_meta(&"worker_tool_keepouts",[]): half = maxf(half,maxf(absf(box.position.x),absf(box.end.x)))
	return half

static func _keepout_half_depth(tool: RigidBody3D) -> float:
	var half := .047+.005
	for box: AABB in tool.get_meta(&"worker_tool_keepouts",[]): half = maxf(half,maxf(absf(box.position.z),absf(box.end.z)))
	return half

static func _seat_depth(tool: RigidBody3D) -> float:
	# Grown visual slices keep SEAT_AIR (10 mm) in front of the plate face.
	if not is_instance_valid(tool): return SEAT_Z
	return clampf(PLATE_BACK+SEAT_AIR+_keepout_half_depth(tool),PLATE_BACK+.05,.40)

## ---- Presentation / integration hooks (read-only for Pose and helper) -------
func stunt_owns_gait() -> bool:
	# Keep the idle clip (no walk cycle lifting the support foot) while the
	# stunt gathers, kicks, flies and settles.
	if stage in ["gather","hold","kick","release","flight"]: return true
	return stage in ["settle","proud"] and not worker.has_target

func stunt_force(horizontal: Vector3) -> Variant:
	# Helper _move_with_forces hook: the native capsule advances under the
	# airborne tool through forces only (no transform writes). Min-jerk
	# feed-forward plus closed-loop alignment of the actual cradle under the
	# OBSERVED falling body. Returns null when inactive.
	if phase != "flight" or _advance.is_empty() or not worker.on_ground or not worker.is_available(): return null
	var tool: RigidBody3D = worker.equipped_tool
	if not is_instance_valid(tool) or is_instance_valid(tool.carrier): return null
	var d: float = _advance.d
	var seconds: float = _advance.seconds
	var dir: Vector3 = _advance.dir
	var time := _age
	var tau := clampf(time/seconds,0.0,1.0)
	var feed_velocity := dir*(d/seconds*30.0*tau*tau*(1.0-tau)*(1.0-tau))
	var feed_accel := dir*(d/(seconds*seconds)*60.0*tau*(1.0-tau)*(1.0-2.0*tau)) if tau < 1.0 and d > 0.0 else Vector3.ZERO
	var correction := Vector3.ZERO
	var gravity := _gravity(tool)
	var com: Vector3 = tool.global_transform*_tool_com_local
	var velocity: Vector3 = _velocity(tool)-worker.ground_velocity
	var seat_com: Vector3 = _body_frame*seat_point()+seat_basis()*_tool_com_local
	var drop_height := com.y-seat_com.y
	var disc := velocity.y*velocity.y+2.0*gravity*drop_height
	if disc > 0.0:
		var arrive := (velocity.y+sqrt(disc))/gravity
		if arrive > .04:
			var future := d*(_minjerk((time+arrive)/seconds)-_minjerk(tau))
			var error: Vector3 = (com+velocity*arrive-(seat_com+dir*future)).slide(Vector3.UP)
			var along := error.dot(dir)
			var done: float = (worker.global_position-Vector3(_advance.origin)).dot(dir)
			along = clampf(along,-.05,maxf(ADVANCE_LIMIT-done-(d-d*_minjerk(tau)),0.0))
			# Sideways the cradle may recover a shove (a hit) under the tool too.
			var side_error := (error-dir*error.dot(dir)).limit_length(.12)
			correction = (dir*along+side_error)/maxf(arrive,.10)
	var desired := feed_velocity+correction
	var force: Vector3 = ((feed_accel+(desired-horizontal)*ADVANCE_GAIN).slide(worker.ground_normal)).limit_length(ADVANCE_ACCEL)*worker.mass
	_advance.peak_force = maxf(float(_advance.peak_force),force.length())
	_advance.last = {"feed":feed_velocity,"correction":correction,"force":force,"horizontal":horizontal}
	return force

func stunt_pose(pose: SkeletonModifier3D,sk: Skeleton3D,unbalanced_com: Vector3) -> Dictionary:
	# Pose _weight_transfer hook: upper-cube acting only (support shift, roll,
	# crouch/rise, pitch, yaw). Soles, reach and the native body are untouched.
	# The stunt times its own beats (a 2-frame snap, a 2-frame catch dip), so
	# it hands Pose the already-filtered values ("direct"): a short own filter
	# with rate limits, seeded from Pose's current sway so nothing jumps; when
	# the stunt lets go, Pose's ordinary filter continues from the same values.
	var want := _acting_target(pose,sk,unbalanced_com)
	if want.is_empty() and not _acting.is_empty() and pose and not pose.evaluated_valid \
		and stage in ["gather","hold","kick","release","flight","settle","proud","reach","draw","home"]:
		# Pose not evaluated yet (the first tick after a load): hold the saved
		# acting instead of dropping the cube to neutral under the airborne tool.
		return {"direct":true,"shift":_acting.shift,"roll":_acting.roll,"pitch":_acting.pitch,"yaw":_acting.yaw,"side":-1,"point":Vector3.ZERO}
	if want.is_empty():
		if _acting.is_empty(): return {}
		if absf(float(_acting.yaw)) < .002:
			_acting.clear()
			return {}
		# Let a residual yaw ease out before the ordinary filter owns the cube.
		want = {"shift":pose._sway_shift,"roll":pose._sway_roll,"pitch":pose._sway_pitch,"yaw":0.0,"tau":.05,"side":-1,"point":Vector3.ZERO}
	var dt: float = clampf(float(pose._head_pose_delta),1.0/480.0,1.0/30.0)
	if _acting.is_empty():
		_acting = {"shift":pose._sway_shift,"roll":pose._sway_roll,"pitch":pose._sway_pitch,"yaw":0.0}
	var k := 1.0-exp(-dt/maxf(float(want.get("tau",.05)),.002))
	var shift: Vector3 = _acting.shift
	shift = shift.move_toward(shift.lerp(Vector3(want.shift),k),ACT_SHIFT_RATE*dt)
	var turns := {}
	for key: String in ["roll","pitch","yaw"]:
		var now: float = _acting[key]
		turns[key] = move_toward(now,lerpf(now,float(want.get(key,0.0)),k),ACT_TURN_RATE*dt)
	_acting = {"shift":shift,"roll":turns.roll,"pitch":turns.pitch,"yaw":turns.yaw}
	return {"direct":true,"shift":shift,"roll":turns.roll,"pitch":turns.pitch,"yaw":turns.yaw,"side":int(want.get("side",-1)),"point":Vector3(want.get("point",Vector3.ZERO))}

func _retrieval_clock() -> float:
	return _retrieval_time

func _acting_target(pose: SkeletonModifier3D,sk: Skeleton3D,unbalanced_com: Vector3) -> Dictionary:
	# Body beats (skeleton-local: +X right, +Y up, +Z back; pitch > 0 tips the
	# top back = face up; roll toward a sole = onto that foot; yaw > 0 turns
	# the face toward -X). Support-foot weight first, the kick snaps up onto
	# the support toe, the face follows the tool, the catch dips with the
	# tool's momentum, then a separate proud bounce and an over-the-shoulder
	# glance. Retrieval shifts onto the support foot and turns toward the tool.
	var acting_stages := ["gather","hold","kick","release","flight","settle","proud","reach","draw","home"]
	if not stage in acting_stages or not pose or not pose.evaluated_valid: return {}
	if stage in ["settle","proud"] and worker.has_target: return {}
	if stage in ["reach","draw","home"] and (not worker.on_ground or phase not in ["retrieve","return"]): return {}
	var a := _stage_age
	var support := 1-_foot_side
	var soles: Array[Vector3] = []
	for side in 2:
		soles.append(sk.global_transform*(sk.get_bone_global_pose(pose._chains[side][2])*Vector3(0,pose._ankle_height[side],0)))
	var weight_side := support
	var envelope := 1.0
	var crouch := 0.0
	var pitch := 0.0
	var yaw := 0.0
	var tau := .05
	var lateral := .055
	var roll_size := .07
	match stage:
		"gather":
			# Decide: weight onto the support foot (roll ~4 deg), knee loads,
			# the top pitches toward the tool beside the foot.
			envelope = smoothstep(0.0,.15,a)
			crouch = -.035*smoothstep(.02,.22,a)
			pitch = -.055*smoothstep(.04,.26,a)
			tau = .06
		"hold":
			# Cocked and loaded: deepest crouch, still leaning toward the tool.
			crouch = -.05
			pitch = -.065
			tau = .05
		"kick","release":
			# Snap: rise onto the support toe and throw the face up.
			crouch = .035
			pitch = .07
			tau = .022
		"flight":
			var t := _age
			var landed: bool = _step_plan.is_empty() and not _empty_return_active
			var stepping: bool = bool(_support_step.get("started",false))
			if stepping:
				weight_side = _foot_side
				envelope = 1.0
			elif landed and _support_step_done:
				envelope = 0.0
			else:
				# Weight stays on the support sole until the kick foot lands ahead.
				var land: float = float(_step_plan.get("t_land",.42)) if not _step_plan.is_empty() else .42
				envelope = 1.0-smoothstep(land*.6,land,t)
				if landed: envelope = 0.0
			var under := CATCH_CROUCH+_catch_trim
			crouch = lerpf(.035,under,smoothstep(.04,.30,t))
			# Face up at the climbing tool, level for the cradle by the catch,
			# then a small forward-up brace.
			pitch = .09*smoothstep(0.0,.14,t)*(1.0-smoothstep(_flight_seconds*.50,_flight_seconds-.18,t))
			tau = .06
		"settle":
			# Absorb: bottom in 2 frames, hold 1, recover with a small overshoot.
			envelope = 0.0
			var base := CATCH_CROUCH+_catch_trim_at_catch
			var dip := _catch_dip
			if a < .06: crouch = base-dip*(1.0-pow(1.0-a/.06,2.0))
			elif a < .093: crouch = base-dip
			elif a < .25: crouch = lerpf(base-dip,.007,smoothstep(.093,.25,a))
			else: crouch = lerpf(.007,0.0,smoothstep(.25,SETTLE_SECONDS,a))
			# The load lands behind the COM: the top rocks back, then settles.
			pitch = .045*smoothstep(0.0,.035,a)*(1.0-smoothstep(.07,.26,a))
			tau = .012
		"proud":
			# Its own 2 cm two-foot bounce, then a glance over the shoulder at
			# the seated head.
			envelope = 0.0
			crouch = .02*sin(PI*clampf(a/.24,0.0,1.0))
			yaw = _side_sign*.17*(smoothstep(.06,.16,a)-smoothstep(.34,PROUD_SECONDS,a))
			tau = .03
		"reach","draw","home":
			# Retrieval: weight onto the support foot (roll 4-5 deg, knee +6
			# deg), the body turns toward the tool corner while the foot reaches,
			# then counter-pitches as the mass swings forward and turns back.
			var reach_t := _retrieval_clock()
			envelope = smoothstep(0.0,.12,reach_t)
			lateral = .058
			roll_size = .08
			crouch = -.022*smoothstep(0.0,.14,reach_t)
			if stage == "reach":
				# Glance: the cube turns toward the tool corner as the empty foot
				# rises, and is square again by handle contact (the held tool may
				# not have the body turning under it in the seat's 1 cm of air).
				var unwind := 0.0
				if _path_index >= maxi(_waypoints.size()-2,1) and _return_segment_phase == "retrieve":
					var legs := float(_waypoints.size()-_path_index)
					var segment := clampf(_return_segment_age/maxf(_return_segment_seconds,.05),0.0,1.0)
					unwind = clampf((1.0-(legs-1.0)*.5)*.5+segment*.5,0.0,1.0) if legs <= 2.0 else 0.0
				yaw = _side_sign*-.30*smoothstep(.03,.20,reach_t)*(1.0-unwind)
				pitch = .02*smoothstep(.05,.25,reach_t)
			elif stage == "draw":
				# The cube holds still while the toe lifts the tool off the trays,
				# then starts to counter-pitch as the mass swings forward.
				if _path_index >= 1 and _draw_lift_t0 < 0.0: _draw_lift_t0 = _stage_age
				var b: float = maxf(_stage_age-_draw_lift_t0,0.0) if _draw_lift_t0 >= 0.0 else 0.0
				pitch = lerpf(.02,-.085,smoothstep(0.0,.25,b))
				# Any glance left over holds still until the tool is out beside the hip.
				yaw = float(_acting.get("yaw",0.0))
			else:
				var fade := 1.0-smoothstep(maxf(_return_segment_seconds-.18,0.0),_return_segment_seconds+.08,_return_segment_age) if _path_index >= _waypoints.size()-1 else 1.0
				pitch = -.085*fade
				yaw = 0.0
				envelope *= fade
				crouch *= fade
			tau = .07
	var toward: Vector3 = (soles[weight_side]-unbalanced_com).slide(worker.ground_normal)
	var local: Vector3 = sk.global_basis.inverse()*toward
	var shift := Vector3(clampf(local.x,-lateral,lateral)*envelope,crouch,0.0)
	var height := maxf(worker.ground_normal.dot(unbalanced_com-soles[weight_side]),.45)
	var roll := clampf(-atan2(local.x,height),-roll_size,roll_size)*envelope
	return {"shift":shift,"roll":roll,"pitch":pitch,"yaw":yaw,"tau":tau,"side":weight_side if envelope > .5 else -1,"point":soles[weight_side]}

## Face hooks for the expression code (_update_expression is not edited here).
## Wiring, inside _update_expression before the gaze is applied:
##   var stunt_look: Variant = back_tool.gaze_target() if back_tool else null
##   if stunt_look is Vector3: looking = stunt_look; gaze_response = maxf(gaze_response,18.0)
##   (and add "stunt_look is Vector3" to the condition that aims the eyes)
##   effort = minf(effort, 1.0-.30*back_tool.face_effort())  # brace squint
##   if back_tool.blink_hold(): _next_blink = maxf(_next_blink,.25)
##   if back_tool.face_cue() == &"pride": smile_request = maxf(smile_request,.6)
## The eyes sit on the front face, so they never aim at the seat behind the
## head: the last beat braces forward-up with a squint, the proud beat glances
## toward the seated side.
func gaze_target() -> Variant:
	# Leads the action: the tool while gathering, the planned apex as the kick
	# winds up, the tool in flight, a forward-up brace for the last beat and
	# the dip, a glance toward the seated side, the handle while reaching.
	var tool: RigidBody3D = worker.equipped_tool
	if not is_instance_valid(tool) or not tool.is_inside_tree() or not worker.is_inside_tree(): return null
	_cache_tool(tool)
	var com: Vector3 = tool.global_transform*_tool_com_local
	match stage:
		"gather": return com
		"hold","kick","release":
			if not _stunt.is_empty() and _stunt.has("apex_local"): return _body_frame*Vector3(_stunt.apex_local)
			return com
		"flight":
			if _bracing(): return _body_frame*Vector3(0,.55,-1.6)
			return com+_velocity(tool)*.06
		"settle": return _body_frame*Vector3(0,.35,-1.6)
		"proud": return _body_frame*Vector3(_side_sign*1.3,.30,-.35)
		"reach": return tool.global_transform*Vector3(0,-.035-float(tool.definition.size.y)*.45,0)
		"draw": return com
	return null

func _bracing() -> bool:
	# The last beat before the predicted contact (the tool is falling past the
	# eye line toward the seat behind the head).
	if stage != "flight" or not is_instance_valid(worker.equipped_tool): return false
	return _velocity(worker.equipped_tool).y < 0.0 and _age > _flight_seconds-.16

func face_effort() -> float:
	# Brace squint: the last beat and the catch dip, eased out by the proud beat.
	if _bracing(): return 1.0
	if stage == "settle": return clampf(1.0-_stage_age/.20,0.0,1.0)
	return 0.0

func blink_hold() -> bool:
	# Never blink through the snap or while the tool is airborne.
	return stage in ["kick","release","flight"]

func face_cue() -> StringName:
	# A short proud accent after the real contact catch (happy lids).
	return &"pride" if stage in ["settle","proud"] else &""

func stunt_metrics() -> Dictionary:
	return _stunt_metrics

func _supported_return_home(home: Transform3D,max_lift := .045) -> Transform3D:
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
	if lift>max_lift: return Transform3D(Basis.IDENTITY,Vector3.INF)
	home.origin+=Vector3(surface.normal)*lift
	return home

func _launch() -> void:
	if phase != "prepare" or _path_index < _waypoints.size() or not foot_occupied(): return
	if not worker.on_ground or not worker.is_available():
		drop("Lost footing at tool release")
		return
	if worker.fear_time > 0.0:
		# Startled at the release tick: nothing is thrown; the toe retraces home.
		if not _cancel_to_foot("Startled at release; the tool goes back to the foot"): drop("Startled at release with no clear way home")
		return
	var tool: RigidBody3D = worker.equipped_tool
	var exact: Transform3D = tool.global_transform
	var gravity := _gravity(tool)
	var direct := PhysicsServer3D.body_get_direct_state(worker.get_rid())
	var worker_velocity: Vector3 = direct.linear_velocity if direct else worker.linear_velocity
	var com: Vector3 = exact*_tool_com_local
	var inherited: Vector3 = _point_velocity(worker,com)+_toe_velocity
	var inherited_angular: Vector3 = (direct.angular_velocity if direct else worker.angular_velocity)+_toe_angular
	var wanted := Vector3.ZERO
	var wanted_angular := inherited_angular
	var seconds := FLIGHT_SECONDS
	var arc_clear := false
	if not _stunt.is_empty():
		# Re-solve from the ACTUAL released frame and measured kick motion. The
		# same apex/advance plan lands this body in the cradle as it will be.
		var forward: Vector3 = _stunt.dir
		var d: float = float(_stunt.advance)
		var up: Vector3 = worker.ground_normal if worker.ground_normal.length_squared() > .5 else Vector3.UP
		var rise: float = float(_stunt.apex)-(up.dot(exact*_tool_com_local)-up.dot(worker._ground_point))
		var solved := _ballistic(exact,maxf(rise,.25),d,forward,int(_stunt.spin_option))
		if not solved.is_empty():
			wanted = solved.v
			wanted_angular = solved.omega
			seconds = float(solved.T)
			_stunt.seat_com_planned = solved.seat_com
			var correction := (wanted_angular-inherited_angular).length()
			_stunt_metrics.spin_correction = correction
			_stunt_metrics.turns = solved.turns
			_back_keepout = true
			arc_clear = correction <= STUNT_SPIN_CORRECTION_MAX \
				and _stunt_arc_clear(exact,wanted,wanted_angular,seconds,forward,d,float(_stunt.T_adv),false) \
				and _stunt_arc_clear(exact,wanted,wanted_angular,seconds,forward,d,float(_stunt.T_adv),true)
			_back_keepout = false
	else:
		var destination: Vector3 = _body_frame*seat_point()
		wanted = (destination+worker.ground_velocity*FLIGHT_SECONDS-exact.origin)/FLIGHT_SECONDS+Vector3.UP*(gravity*FLIGHT_SECONDS*.5)
		arc_clear = _arc_clear(exact,wanted,gravity,FLIGHT_SECONDS)
	launch_impulse = tool.mass*(wanted-worker_velocity)
	if plan_debug and not _stunt.is_empty():
		var rel2: Transform3D = _body_frame.affine_inverse()*exact
		_back_keepout = true
		print("CONTRAPTION_BACK_TOOL launch_pose release_body=",rel2.origin," y=",rel2.basis.y," root_y=",_root.origin.y," sway=",worker._pose._sway_shift," pitch=",worker._pose._sway_pitch," rootlocal=",_root.affine_inverse()*exact.origin," clear=",_frame_clear(_toe_for(exact),_root,false)," dbg=",JSON.stringify(_posture_debug_at(exact,_root)))
		_back_keepout = false
	if plan_debug: print("CONTRAPTION_BACK_TOOL launch_check native=",JSON.stringify(last_native_obstacle)," arc=",arc_clear," impulse_speed=",launch_impulse.length()/tool.mass," inherited=",inherited," wanted=",wanted," w_in=",inherited_angular," w_want=",wanted_angular," spin_corr=",_stunt_metrics.get("spin_correction",-1.0))
	if not arc_clear or launch_impulse.length() > tool.mass*MAX_KICK_SPEED:
		reason = "No clear bounded toss arc behind the Wako"
		# The next plan skips this candidate/apex/spin rather than repeating it.
		_launch_refused_at = worker.global_position
		if not _stunt.is_empty(): _launch_refused.append(_plan_key(float(_stunt.get("flip",1.0)),int(_stunt.get("candidate",-1)),float(_stunt.get("apex",0.0)),int(_stunt.get("spin_option",-1))))
		# Nothing is thrown: the toe retraces its passage home on the foot
		# (the old snap back to the ordinary carry could not keep the pose).
		var why := reason
		if not _cancel_to_foot(why): drop("No clear bounded toss arc and no clear way home")
		reason = why
		return
	launch_before_momentum = worker.mass*worker_velocity
	_launch_refused.clear()
	tool.set_carried(null)
	# The worn seat lies inside the capsule's support radius (the capsule is a
	# locomotion proxy, not the cube). Its own airborne tool may not shove the
	# capsule; the whole-tool keepout still protects the real body.
	_guard_release(tool)
	_flight_prev_valid = false
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
	if wanted_angular != inherited_angular:
		# Bounded flick spin about the principal axes: impulse = I_world * dω.
		var principal: Vector3 = tool.inertia
		if principal.x > 0.0 and principal.y > 0.0 and principal.z > 0.0:
			var basis: Basis = exact.basis.orthonormalized()
			var local_delta: Vector3 = basis.inverse()*(wanted_angular-inherited_angular)
			tool.apply_torque_impulse(basis*(local_delta*principal))
		else:
			tool.angular_velocity = wanted_angular
	worker.apply_impulse(-launch_impulse,exact.origin-worker.global_position)
	launch_after_momentum = worker.mass*_velocity(worker)+tool.mass*_velocity(tool)
	phase = "flight"
	_flight_seconds = seconds
	# Every flight (stunt or legacy hop) aligns the cradle under the observed
	# body through capsule forces; only the stunt adds the planned advance.
	var drive_dir: Vector3 = (-worker._model.global_basis.z).slide(worker.ground_normal).normalized()
	_advance = {"d":0.0,"seconds":ADVANCE_SECONDS,"dir":drive_dir,"origin":worker.global_position,"peak_force":0.0}
	if not _stunt.is_empty():
		_set_stage("flight")
		_advance.d = float(_stunt.advance)
		_advance.seconds = float(_stunt.T_adv)
		_advance.dir = _stunt.dir
		_stunt_metrics.release_speed = (wanted-worker_velocity).length()
		_stunt_metrics.release_toe_speed = _toe_velocity.length()
		_stunt_metrics.release_toe_ratio = _toe_velocity.length()/maxf((wanted-worker_velocity).length(),.001)
		_stunt_metrics.release_impulse_speed = (wanted-inherited).length()
		_stunt_metrics.planned_flight = seconds
		_stunt_metrics.launch_omega = wanted_angular.length()
		_stunt_metrics.kick_omega = inherited_angular.length()
	_empty_return_active=true
	_empty_sole=worker._pose.evaluated_soles[_foot_side]
	_empty_ankle=worker._pose.evaluated_ankles[_foot_side]
	_empty_return_age = 0.0
	_catch_trim = 0.0
	_step_plan = _plan_step_through(seconds) if not _stunt.is_empty() else {}
	_support_step = _plan_support_step(seconds) if not _step_plan.is_empty() else {}
	_support_step_done = false
	_age = 0.0
	tosses += 1
	worker.status_text = "Tool airborne toward back cradle"

func _update_catch_trim() -> void:
	# The spinning tool reaches the seat orientation at its own time; trim the
	# cradle height (Pose's crouch, <= 3.5 cm) so the contact happens then.
	if _stunt.is_empty() and stage != "flight":
		_catch_trim = 0.0
		return
	var tool: RigidBody3D = worker.equipped_tool
	var com: Vector3 = tool.global_transform*_tool_com_local
	var velocity: Vector3 = _velocity(tool)-worker.ground_velocity
	var seat_world := seat_basis()
	var seat_com: Vector3 = _body_frame*seat_point()+seat_world*_tool_com_local
	var gravity := _gravity(tool)
	var disc := velocity.y*velocity.y+2.0*gravity*(com.y-seat_com.y)
	if disc <= 0.0: return
	var contact := (velocity.y+sqrt(disc))/gravity
	if contact > .30 or contact < .05: return
	var axis: Vector3 = seat_world.z.normalized()
	var rate: float = tool.angular_velocity.dot(axis)
	if absf(rate) < .5: return
	var relative: Quaternion = (seat_world*tool.global_basis.inverse()).get_rotation_quaternion().normalized()
	var signed := 2.0*atan2(Vector3(relative.x,relative.y,relative.z).dot(axis),relative.w)
	signed = wrapf(signed,-PI,PI)
	var match_time := signed/rate
	while match_time < 0.0: match_time += TAU/absf(rate)
	if match_time > contact+.2: match_time -= TAU/absf(rate)
	var fall_speed := absf(velocity.y-gravity*contact)
	var delta_y := -fall_speed*(match_time-contact)
	# Small gain: Pose's own filter realises the crouch with a lag.
	_catch_trim = clampf(_catch_trim+delta_y*catch_trim_gain,-.015,.015)
	if plan_debug: print("CONTRAPTION_BACK_TOOL trim t=",snappedf(_age,.001)," contact=",snappedf(contact,.0001)," match=",snappedf(match_time,.0001)," signed=",snappedf(signed,.001)," rate=",snappedf(rate,.01)," trim=",snappedf(_catch_trim,.0001)," gaps=",[snappedf(_pad_gap(_body_frame.affine_inverse()*tool.global_transform,0),.001),snappedf(_pad_gap(_body_frame.affine_inverse()*tool.global_transform,1),.001)])
	_stunt_metrics.catch_trim = _catch_trim

func _observe_catch(delta: float) -> void:
	var tool: RigidBody3D = worker.equipped_tool
	if worker._pose and not worker._pose.evaluated_valid:
		# No evaluated cube yet (the first tick after a load): the cradle's
		# frame is not real, so neither predict nor record it.
		_flight_prev_valid = false
		return
	var velocity: Vector3 = _velocity(tool)
	var relative: Vector3 = velocity-worker.ground_velocity
	# The free body's pose relative to the moving cradle, this tick and last.
	var local_now: Transform3D = _body_frame.affine_inverse()*tool.global_transform
	var local_prev: Transform3D = _flight_prev_local if _flight_prev_valid else local_now
	var body_prev: Transform3D = _flight_prev_body if _flight_prev_valid else _body_frame
	_flight_prev_local = local_now
	_flight_prev_body = _body_frame
	_flight_prev_valid = true
	if _age < .2 or relative.y >= -.05:
		if _age > _flight_seconds+.25: drop("Back catch missed; recovering the original loose tool")
		return
	var gaps: Array[float] = [_pad_gap(local_now,0),_pad_gap(local_now,1)]
	var contact_local := local_now
	var tau := 0.0
	var predicted := false
	var trays := tray_contacts()
	if plan_debug: print("CONTRAPTION_BACK_TOOL catch_probe t=",snappedf(_age,.001)," trays=",trays," gaps=",[snappedf(gaps[0],.0001),snappedf(gaps[1],.0001)]," body=",_body_frame.origin," cap=",worker.global_position," root=",_root.origin," tool_w=",tool.global_position," tool_body=",local_now.origin," seat=",_seat_local.origin," turn=",snappedf(rad_to_deg(_turn(local_now.basis.get_rotation_quaternion(),_seat_local.basis.get_rotation_quaternion())),.01))
	if not (trays[0] and trays[1]):
		# Not (both) touching yet. Predict this tick's own free motion relative
		# to the cradle (the body's ballistic step and spin, the body frame's
		# last step); if BOTH trays are reached inside it, the contact happens
		# this tick: the body moves forward along its free path to the first
		# two-tray contact pose and the actual tray sensors are queried THERE.
		# No penetrated pose is ever published, so the catch never steps back.
		var gravity := Vector3.DOWN*_gravity(tool)
		var omega: Vector3 = tool.angular_velocity
		var com: Vector3 = tool.global_transform*_tool_com_local
		var next_velocity := velocity+gravity*delta
		var next_basis: Basis = tool.global_basis
		if omega.length() > .000001: next_basis = (Basis(omega.normalized(),omega.length()*delta)*next_basis).orthonormalized()
		var next_tool := Transform3D(next_basis,com+next_velocity*delta-next_basis*_tool_com_local)
		var body_next: Transform3D = _body_frame*(body_prev.affine_inverse()*_body_frame)
		var local_next: Transform3D = body_next.affine_inverse()*next_tool
		var gaps_next: Array[float] = [_pad_gap(local_next,0),_pad_gap(local_next,1)]
		# Crossing time of each tray along the step (in ticks; 0 = already in
		# contact, > 1 = later).
		var cross: Array[float] = [INF,INF]
		for index in 2:
			if gaps[index] <= 0.0 or trays[index]: cross[index] = 0.0
			elif gaps_next[index] < gaps[index]: cross[index] = gaps[index]/(gaps[index]-gaps_next[index])
		tau = maxf(cross[0],cross[1])
		# The tray that touched first must still be inside its rubber when the
		# other arrives (one continuous touch-down of a slightly tipped body).
		var later := 0 if cross[0] >= cross[1] else 1
		var first_depth: float = gaps[1-later]+(gaps_next[1-later]-gaps[1-later])*tau if tau < 100.0 else gaps_next[1-later]
		var confirmed := false
		if tau <= 1.25 and first_depth >= -PAD_DEPTH_BUDGET:
			# The linear crossing estimate ignores the spin's curvature: confirm
			# on the real sensors, a little further along the same free path if
			# needed, until both trays genuinely report contact.
			for attempt in 5:
				var at := minf(tau+.06*attempt,1.25)
				contact_local = _interp(local_now,local_next,at)
				var probe := tray_contacts(_body_frame*contact_local)
				if probe[0] and probe[1]:
					tau = at
					trays = probe
					confirmed = true
					break
		if not confirmed:
			if trays[0] or trays[1]:
				var touching := 0 if trays[0] else 1
				_stunt_metrics.first_tray = touching
				if gaps[touching] < -PAD_DEPTH_BUDGET or first_depth < -PAD_DEPTH_BUDGET-.01:
					# Past its rubber before the other side can arrive: no seat.
					_stunt_metrics.catch_refusal = {"one_tray":touching,"gaps":gaps,"first_depth":first_depth}
					drop("Tool landed on one side of the cradle only")
			elif _age > _flight_seconds+.25: drop("Back catch missed; recovering the original loose tool")
			return
		predicted = true
	else:
		# Already overlapping both (a resumed save, a body bump): attach where
		# the later tray first touched along the last free step, but never
		# step back more than 1 cm; the rubber settle absorbs the rest.
		for index in 2:
			var before := _pad_gap(local_prev,index)
			if before > 0.0 and gaps[index] < before: tau = maxf(tau,clampf(before/(before-gaps[index]),0.0,1.0))
		var span := local_prev.origin.distance_to(local_now.origin)
		if span > .0001: tau = maxf(tau,1.0-.01/span)
		contact_local = _interp(local_prev,local_now,tau)
	var depth := minf(_pad_gap(contact_local,0),_pad_gap(contact_local,1))
	var exact: Transform3D = _body_frame*contact_local
	var offset: Vector3 = _seat_local.basis.inverse()*(contact_local.origin-_seat_local.origin)
	var turn := _turn(exact.basis.get_rotation_quaternion(),seat_basis().get_rotation_quaternion())
	_catch_keepout = true
	var seated_clear := _frame_clear(_toe_for(exact),_root,false)
	_catch_keepout = false
	if absf(offset.y) > .10 or absf(offset.z) > .035 or depth < -PAD_DEPTH_BUDGET \
		or velocity.length() > 7.0 or turn > CATCH_TURN_TOLERANCE or not seated_clear:
		_stunt_metrics.catch_refusal = {"offset":offset,"turn":turn,"speed":velocity.length(),"depth":depth,"posture":_posture_debug(exact),"clear":_catch_clear_detail(exact)}
		drop("Tool contacted the cradle outside its safe seated pose")
		return
	_stunt_metrics.catch_predicted = predicted
	# Felt weight: the cube's absorb dip scales with the caught momentum.
	_catch_dip = clampf(.6*float(tool.mass)*absf(relative.y)/maxf(float(worker.mass),1.0)*.08,.025,.045)
	_catch_trim_at_catch = _catch_trim
	_cradle_clack = 0.0
	var worker_velocity := _velocity(worker)
	catch_before_momentum = worker.mass*worker_velocity+tool.mass*velocity
	tool.global_transform = exact
	back_anchor.global_transform = exact
	_back_local = _root.affine_inverse()*exact
	tool.set_carried(back_anchor,Vector3.ZERO)
	_clear_release_contacts(true)
	# Native box contact report at the contact pose (the native box contains
	# the visual underside, so it overlaps both trays as well).
	last_contact_points.clear()
	var exclusions: Array[RID] = worker.query_exclusions()
	for cradle: Node in worker.get_tree().get_nodes_in_group(&"wako_back_cradles"):
		if cradle != holder and cradle is CollisionObject3D: exclusions.append(cradle.get_rid())
	_contact_query.exclude = exclusions
	_cache_tool(tool)
	for index in _native_colliders.size():
		_contact_query.shape = _native_colliders[index].shape
		_contact_query.transform = exact*_native_local[index]
		ops_native += 1
		last_contact_points.append_array(worker.get_world_3d().direct_space_state.collide_shape(_contact_query,8))
	# Settle level on both trays, sliding only along them.
	_seat_settle_from = contact_local
	_seat_settle_to = Transform3D(_seat_local.basis,_seat_local.origin+_seat_local.basis.y*clampf(offset.y,-.05,.05))
	_seat_settle_age = 0.0
	_seat_settling = true
	_seat_rebound = true
	_restore_damping(tool)
	worker.set_cargo(worker.cargo_mass)
	worker.apply_impulse(tool.mass*(velocity-worker_velocity),exact.origin-worker.global_position)
	catch_after_momentum = worker.mass*_velocity(worker)
	catch_pose_error = exact.origin.distance_to(tool.global_position)
	var after := tray_contacts()
	_stunt_metrics.catch_trays = [trays[0],trays[1]]
	_stunt_metrics.catch_trays_at_contact_pose = [after[0],after[1]]
	_stunt_metrics.catch_tau = tau
	_stunt_metrics.catch_first_tray_depth = -depth
	# Step of the caught body relative to the cradle on the contact tick (along
	# its own free path) and any component reversing its incoming motion.
	_stunt_metrics.catch_step = local_now.origin.distance_to(contact_local.origin)
	var incoming: Vector3 = local_now.origin-local_prev.origin
	_stunt_metrics.catch_reversal = maxf(-(contact_local.origin-local_now.origin).dot(incoming.normalized()),0.0) if incoming.length() > .00001 else 0.0
	_stunt_metrics.catch_contacts = last_contact_points.size()/2
	_stunt_metrics.catch_turn_deg = rad_to_deg(turn)
	_stunt_metrics.catch_offset = offset
	_stunt_metrics.catch_speed = velocity.length()
	_stunt_metrics.flight_seconds_actual = _age
	if _stunt.has("seat_com_planned"):
		var seat_now: Vector3 = _body_frame*seat_point()+seat_basis()*_tool_com_local
		_stunt_metrics.seat_error_at_catch = seat_now-Vector3(_stunt.seat_com_planned)
		var settled := _settled_body_frame()
		_stunt_metrics.sway_at_catch = _body_frame.origin-settled.origin
	if not _advance.is_empty():
		_stunt_metrics.advance_actual = (worker.global_position-Vector3(_advance.origin)).dot(Vector3(_advance.dir))
		_stunt_metrics.peak_drive_force = _advance.peak_force
		_stunt_metrics.planned_advance = _advance.d
	_advance.clear()
	phase = "back"
	_want_stow = false
	catches += 1
	_age = 0.0
	_retry = 0.0
	_flight_prev_valid = false
	if not _stunt.is_empty():
		_set_stage("settle")
		_settle_time = SETTLE_SECONDS
	else: _set_stage("")
	_stunt.clear()
	_retrieval_cand = 0
	worker.status_text = "Walking with both feet free"
	_begin_deferred_interrupt()

func _reseat_from_contact() -> bool:
	# The held tool has not left its seated pose yet: hand it back to the
	# cradle exactly where it is (no motion, no custody gap).
	var tool: RigidBody3D = worker.equipped_tool
	if not is_instance_valid(tool) or tool.carrier != worker.tool_anchor: return false
	# Compare with the pose it actually rested in (the settle keeps a caught
	# body's own along-shaft offset on the rubber), not the nominal seat.
	var seated: Transform3D = _root*_back_local
	var exact: Transform3D = tool.global_transform
	if exact.origin.distance_to(seated.origin) > .01 or _turn(exact.basis.get_rotation_quaternion(),seated.basis.get_rotation_quaternion()) > .035: return false
	back_anchor.global_transform = exact
	_back_local = _root.affine_inverse()*exact
	tool.set_carried(back_anchor,Vector3.ZERO)
	_return_search.clear()
	_waypoints.clear()
	_route_fast = false
	phase = "retrieve"
	_abort_retrieval("Interrupted at handle contact; the same tool stays seated")
	return true

func _cancel_to_foot(explanation: String) -> bool:
	# Nothing is released and nothing jumps: the toe retraces its own
	# preflighted gather passage (reversed) from the ACTUAL toe back to the
	# ordinary carry pose it started from, as an owned "home" return under the
	# same per-tick reach / whole-tool / native guards and TOE_SPEED/TOE_TURN
	# caps. Ordinary foot custody resumes only at that pose.
	print("CONTRAPTION_BACK_TOOL stunt_cancelled ",JSON.stringify({"reason":explanation,"stage":stage}))
	reason = explanation
	var route: Array[Transform3D] = []
	if phase == "prepare" and foot_occupied() and _stow_local_waypoints.size() == _waypoints.size():
		var reached: int = mini(_path_index,_stow_local_waypoints.size())
		for index in range(reached-1,-1,-1): route.append(_body_frame*_stow_local_waypoints[index])
		var home := _body_frame*_home_toe_body
		var lifted := _supported_return_home(home)
		route.append(lifted if lifted.origin.is_finite() else home)
	_stunt.clear()
	_advance.clear()
	_step_plan.clear()
	_support_step.clear()
	_route_fast = false
	_want_stow = false
	_retry = 1.0
	if route.is_empty():
		phase = "foot"
		_set_stage("")
		_waypoints.clear()
		_tool_id = 0
		_reset_foot_handoff(worker._pose)
		return false
	phase = "return"
	# Its own stage: the body's retrieval acting (glance yaw, counter-pitch)
	# does not apply; the cube eases back to its ordinary sway.
	_set_stage("retrace")
	_return_search.clear()
	_home_extension_done = true
	_accept_return_route(route,0)
	_age = 0.0
	_retrace_metrics_start()
	return true

func _retrace_metrics_start() -> void:
	_stunt_metrics.retrace = {"from_toe":_body_frame.affine_inverse()*_toe.origin,"waypoints":_waypoints.size()}

func _begin_deferred_interrupt() -> void:
	if not _interrupt_after_catch: return
	_interrupt_after_catch = false
	worker._reaction = maxf(float(worker._reaction),_deferred_reaction)
	_deferred_reaction = 0.0
	# With the tool back on the foot the startle stays a body/face reaction:
	# the interrupted clip folds the work foot under the cube and would make
	# the ordinary held-tool guard shed the same tool it just kept.
	if worker.is_available() and not foot_occupied():
		if _deferred_recoil.is_empty(): worker.begin_action.call_deferred(_deferred_kind)
		else: _play_deferred_recoil.call_deferred(_deferred_recoil)
	_deferred_kind = "interrupted"
	_deferred_recoil = ""

func _play_deferred_recoil(direction: String) -> void:
	# A native hit's recoil arrived during the stunt: its interrupt was held
	# for the catch (only an 8 ms sliver of its clip ran before the stunt's
	# idle took the cube back). Play that same directional recoil once now,
	# exactly as the recoil owner starts it, instead of a second generic
	# 'interrupted' reaction.
	if not worker.is_available() or foot_occupied(): return
	worker.begin_action("interrupted")
	if worker.action != "interrupted": return
	var clip: String = "recoil/"+direction+"_"+("L" if worker.work_foot_side == 0 else "R")
	if not worker._animation.has_animation(clip): return
	worker._action_time = 0.0
	worker.action_progress = 0.0
	worker._action_length = worker._animation.get_animation(clip).length
	worker._animation.play(clip,.18)
	worker._animation.seek(0.0,false)
	_stunt_metrics.deferred_recoil = clip

func _defer_reaction(kind: String,why: String) -> void:
	# The startle (its clip, visual pitch and weaker drive) waits for custody.
	pending_action = ""
	_pending_job = ""
	_interrupt_after_catch = true
	_deferred_kind = kind if kind in ["interrupted","danger"] else "interrupted"
	# A native recoil (wako_recoil.react) counts its event before interrupting:
	# remember its direction so the held reaction is that one recoil.
	var recoil: RefCounted = worker.get("recoil")
	if recoil and int(recoil.events) != _recoil_seen:
		_deferred_recoil = str(recoil.last_direction)
		_recoil_seen = int(recoil.events)
	_deferred_reaction = maxf(_deferred_reaction,float(worker._reaction))
	worker._reaction = 0.0
	reason = why

## Refusal diagnostics only: which part of the seated-pose test failed.
func _catch_clear_detail(exact: Transform3D) -> Dictionary:
	var toe := _toe_for(exact)
	var frame: Dictionary = worker._tool_clearance_frame()
	frame.inverse = _root.affine_inverse()
	frame.basis = toe.basis
	frame.toe_basis = toe.basis
	frame.bounds = CATCH_BOUNDS
	frame.supported = false
	var cube: bool = worker._tool_posture_clear(toe.origin,toe.basis.y,frame)
	frame.supported = worker.on_ground
	frame.support_point = worker._ground_point+worker.ground_normal*_floor_margin
	var floor: bool = worker._tool_posture_clear(toe.origin,toe.basis.y,frame)
	frame.bounds = CATCH_PLATE_BOUNDS
	frame.supported = false
	var plate: bool = worker._tool_posture_clear(toe.origin,toe.basis.y,frame)
	return {"cube":cube,"floor":floor,"plate":plate,"on_ground":worker.on_ground,"floor_margin":_floor_margin,"plate_local":_root.affine_inverse()*(toe.origin+toe.basis.y*.5075)}

func _posture_debug(exact: Transform3D) -> Dictionary:
	return _posture_debug_at(exact,_root)

func _posture_debug_at(exact: Transform3D,root: Transform3D) -> Dictionary:
	var frame: Dictionary = worker._tool_clearance_frame()
	frame.bounds = BACK_BOUNDS if (_back_keepout or phase != "foot") else frame.bounds
	var local: Transform3D = root.affine_inverse()*exact
	var hits: Array = []
	var floor_gap := INF
	for box: AABB in frame.keepouts:
		if worker._tool_box_intersects(frame.bounds,local,box): hits.append(local*box)
		floor_gap = minf(floor_gap,worker.ground_normal.dot(exact*box.get_center()-worker._ground_point))
	var length: float = frame.length
	return {"shaft":frame.bounds.intersects_segment(local*Vector3(0,-length*.5,0),local*Vector3(0,length*.5,0)) != null,"slices":hits,"local":local.origin,"floor_centre_gap":floor_gap}

## ---- Released-body contact guard ---------------------------------------------
## The worn seat lies inside the capsule's radius (the capsule is a locomotion
## proxy, not the cube) and inside the ragdoll root box. A body released or
## restored loose there (launch, any drop, a loose load) ignores exactly these
## own bodies until it cannot reach them any more; it never shoves its Wako.
## One place owns this for every loose release near the seat.
func _guard_release(tool: RigidBody3D) -> void:
	if not is_instance_valid(tool) or not tool.is_inside_tree(): return
	var guarded: RigidBody3D = _release_guard.get("tool",weakref(null)).get_ref() if not _release_guard.is_empty() else null
	var bodies: Array[PhysicsBody3D] = [worker]
	if worker.ragdoll and worker.ragdoll.get("rig") and worker.ragdoll.active:
		for entry in worker.ragdoll.rig.bodies:
			if is_instance_valid(entry.rb): bodies.append(entry.rb)
	if guarded != tool: _clear_release_contacts(true)
	var refs: Array = _release_guard.get("bodies",[]) if guarded == tool else []
	for body: PhysicsBody3D in bodies:
		if not body in tool.get_collision_exceptions(): tool.add_collision_exception_with(body)
		var known := false
		for ref: WeakRef in refs:
			if ref.get_ref() == body: known = true
		if not known: refs.append(weakref(body))
	_release_guard = {"tool":weakref(tool),"bodies":refs,"age":float(_release_guard.get("age",0.0)) if guarded == tool else 0.0}

func _update_release_guard(delta: float) -> void:
	if _release_guard.is_empty(): return
	var tool: RigidBody3D = _release_guard.tool.get_ref()
	if not is_instance_valid(tool) or not tool.is_inside_tree() or not worker.is_inside_tree():
		_release_guard.clear()
		return
	# Any new custody (our catch, a re-equip, another carrier) ends the guard.
	if is_instance_valid(tool.carrier):
		_clear_release_contacts(true)
		return
	_release_guard.age = float(_release_guard.age)+delta
	_cache_tool(tool)
	var com: Vector3 = tool.global_transform*_tool_com_local
	var reach: float = Vector3(tool.definition.size).length()*.5+.06
	var remaining: Array = []
	for ref: WeakRef in _release_guard.bodies:
		var body: PhysicsBody3D = ref.get_ref()
		if not is_instance_valid(body) or not body.is_inside_tree():
			if is_instance_valid(body): tool.remove_collision_exception_with(body)
			continue
		if _release_may_touch(tool,body,com,reach): remaining.append(ref)
		else: tool.remove_collision_exception_with(body)
	_release_guard.bodies = remaining
	if remaining.is_empty(): _release_guard.clear()

func _release_may_touch(tool: RigidBody3D,body: PhysicsBody3D,com: Vector3,reach: float) -> bool:
	# Still overlapping, or its free (ballistic) course over the next second
	# still passes through reach of this body: keep ignoring it.
	var bounds := AABB()
	var found := false
	for child: Node in body.get_children():
		if child is CollisionShape3D and not child.disabled and child.shape:
			var box: AABB = child.global_transform*child.shape.get_debug_mesh().get_aabb()
			bounds = bounds.merge(box) if found else box
			found = true
	if not found: return false
	var zone := bounds.grow(reach)
	var velocity: Vector3 = _velocity(tool)
	var moving: bool = (velocity-worker.ground_velocity).length() > .15
	var near := zone.has_point(com)
	if moving and not near:
		var gravity := Vector3.DOWN*_gravity(tool)
		for step in 20:
			var time := .05*(step+1)
			if zone.has_point(com+velocity*time+gravity*(.5*time*time)): near = true; break
	if not near: return false
	var solid: bool = bool(_release_guard.get("solid",false))
	_query.exclude = []
	_query.collision_mask = 0x7fffffff
	_query.motion = Vector3.ZERO
	var touching := false
	for index in _native_colliders.size():
		_query.shape = _native_colliders[index].shape
		_query.transform = tool.global_transform*_native_local[index]
		ops_native += 1
		for hit: Dictionary in worker.get_world_3d().direct_space_state.intersect_shape(_query,16):
			if hit.rid == body.get_rid(): touching = true
	_query.collision_mask = 0x7fffffff & ~SENSOR_LAYER
	# A resting body that no longer overlaps is an ordinary loose obstacle
	# again (the Wako may bump it like any other part); a moving one keeps it.
	# A tool shed from the air (a missed or abandoned catch) is solid against
	# the body as soon as it is not already inside it: it lands on the Wako,
	# never through it.
	if solid: return touching
	return touching or moving

func _clear_release_contacts(_force: bool) -> void:
	if _release_guard.is_empty(): return
	var tool: RigidBody3D = _release_guard.tool.get_ref()
	if is_instance_valid(tool):
		for ref: WeakRef in _release_guard.bodies:
			var body: PhysicsBody3D = ref.get_ref()
			if is_instance_valid(body): tool.remove_collision_exception_with(body)
	_release_guard.clear()

func release_guard_active() -> bool:
	return not _release_guard.is_empty()

func drop(explanation: String) -> void:
	var tool: RigidBody3D = worker.equipped_tool
	if not is_instance_valid(tool): return
	# The production coordinator defers original-tool abandonment when a
	# worker leaves the tree. During whole-scene teardown either native body
	# may already have left; no world pose/point velocity exists to query here.
	if not worker.is_inside_tree() or not tool.is_inside_tree(): return
	var carried := is_instance_valid(tool.carrier)
	var from_air: bool = phase == "flight"
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
	# Released at the seat (or inside a knocked-down ragdoll): never shove us.
	_guard_release(tool)
	if from_air and not _release_guard.is_empty(): _release_guard.solid = true
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
	_set_stage("")
	_stunt.clear()
	_advance.clear()
	_support_step.clear()
	_return_search.clear()
	_begin_deferred_interrupt()
	_seat_settling = false
	_route_fast = false
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
		# Physical settle instead of a fixed idle-clip wait: both actual soles
		# evaluated planted on consecutive ticks (the speed gates are above).
		if _planted_ticks < 2: return false
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
				elif _back_keepout and not plan_debug:
					# Planner/route searches refuse many candidates by design: keep a
					# light record, no posture debug pass and no print.
					last_path_failure = {"waypoint":waypoint,"sample":index,"count":count,"reachable":reachable,"clear":clear,"toe":Part.encode_transform(sample)}
				else:
					last_path_failure = {"waypoint":waypoint,"sample":index,"count":count,"reachable":reachable,"clear":clear,"toe":Part.encode_transform(sample),"ankle":Part.encode_vector(ankle),"binding":Part.encode_transform(_toe_in_ankle),"hip":Part.encode_vector(hip),"span":worker._leg_span(side),"root":Part.encode_transform(_root),"posture":worker.held_tool_clearance_debug(sample.origin,sample.basis,worker._ground_point,worker.ground_normal)}
					if plan_debug: last_path_failure.back_posture = _posture_debug_at(_tool_frame(sample),_root)
					last_path_failure.native_obstacle=last_native_obstacle.duplicate(true)
					if plan_debug: print("CONTRAPTION_BACK_TOOL path_refused ",JSON.stringify(last_path_failure))
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
	if plan_debug: print("CONTRAPTION_BACK_TOOL path_refused ",JSON.stringify(last_path_failure))
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
		# Planning the crouched gather/hold: the body will sit up to
		# CROUCH_MARGIN lower than when it is planned, so the same body-relative
		# tool must keep that much more air above its support.
		frame.support_point = worker._ground_point+worker.ground_normal*_floor_margin
		frame.support_normal = worker.ground_normal
	frame.basis = toe.basis
	frame.toe_basis = toe.basis
	# Back transfers use the measured rear face (fitted plate) instead of the
	# general cube's doubled depth; ordinary foot work keeps the general cube.
	var plate_bounds := AABB()
	if _catch_keepout:
		frame.bounds = CATCH_BOUNDS
		plate_bounds = CATCH_PLATE_BOUNDS
	elif _back_keepout or phase != "foot":
		frame.bounds = BACK_BOUNDS
		plate_bounds = PLATE_BOUNDS
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
	var lifting_off := _lifting_off(toe)
	ops_posture += 1
	var posture_clear: bool=worker._tool_posture_clear(toe.origin,toe.basis.y,frame)
	var near_plate: bool = plate_bounds.size != Vector3.ZERO and plate_bounds.grow(.62).has_point(frame.inverse*(toe.origin+toe.basis.y*.5075))
	if posture_clear and near_plate:
		# Same whole-tool test against the fitted plate region behind the cube.
		ops_posture += 1
		var cube: AABB = frame.bounds
		frame.bounds = plate_bounds
		var plate_frame := frame.duplicate()
		plate_frame.supported = false
		posture_clear = worker._tool_posture_clear(toe.origin,toe.basis.y,plate_frame)
		frame.bounds = cube
	if return_preflight_timings_enabled:
		_whole_tool_posture_usec+=Time.get_ticks_usec()-posture_started_usec
		_whole_tool_posture_calls+=1
	if not posture_clear and lifting_off:
		# Lifting off its own support: the body and plate keepouts still apply.
		var floorless := frame.duplicate()
		floorless.supported = false
		ops_posture += 1
		posture_clear = worker._tool_posture_clear(toe.origin,toe.basis.y,floorless)
	if not posture_clear: return false
	if not native_obstacles: return true
	if same_request.is_empty(): world=_tool_frame(toe)
	var exclusions: Array[RID]=same_request.exclusions if not same_request.is_empty() else worker.query_exclusions()
	if lifting_off: exclusions.append(_lift_off.rid)
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
		ops_native += 1
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

func _lifting_off(toe: Transform3D) -> bool:
	# See _request_toss: the gather's first lift straight off its own support.
	if _lift_off.is_empty() or not (phase in ["foot","prepare"] or stage == "retrace") or toe.origin.distance_to(Vector3(_lift_off.origin)) > LIFT_OFF_RADIUS: return false
	return _native_support_gap(_tool_frame(toe),worker._ground_point,worker.ground_normal) >= float(_lift_off.gap)-.001

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

func _arc_clear(origin: Transform3D, velocity: Vector3, gravity: float, seconds: float, first := 0, last := -1) -> bool:
	# Short legacy hop: 60 Hz samples (native casts sweep between them). The
	# planner checks it in [first,last] slices; the launch re-check whole.
	var tool: RigidBody3D = worker.equipped_tool
	var count := maxi(1,ceili(seconds*60.0))
	var terrain := worker.get_world_3d().direct_space_state
	_cache_tool(tool)
	var exclusions: Array[RID]=worker.query_exclusions()
	exclusions.append(tool.get_rid())
	exclusions.append(holder.get_rid())
	_query.exclude=exclusions
	var start := clampi(first,0,count)
	var stop := count if last < 0 else clampi(last,start,count)
	var before := seconds*float(maxi(start-1,0))/count
	var previous := Transform3D(origin.basis,origin.origin+velocity*before-Vector3.UP*(gravity*before*before*.5))
	for index in range(start,stop+1):
		var time := seconds*float(index)/count
		var sample := Transform3D(origin.basis,origin.origin+velocity*time-Vector3.UP*(gravity*time*time*.5))
		if not _frame_clear(_toe_for(sample),_root,false): return false
		for shape_index in _native_colliders.size():
			var collider: CollisionShape3D = _native_colliders[shape_index]
			_query.shape = collider.shape
			_query.transform = previous*_native_local[shape_index]
			_query.motion = sample.origin-previous.origin
			ops_native += 1
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
	var local: Vector3 = root.affine_inverse()*toe.origin
	if phase in ["back","retrieve"]:
		# The worn seat sits close behind the body: test the measured body and
		# plate (as the held-tool transfers do), grown by the empty toe sphere.
		# Sphere-vs-box distance (the grown box would also refuse its empty
		# corners, e.g. the low handle end just off the plate's edge).
		if _box_distance(BACK_BOUNDS,local) < _empty_foot_shape.radius or _box_distance(PLATE_BOUNDS,local) < _empty_foot_shape.radius: return false
	elif AABB(Vector3(-.405,-.325,-.405),Vector3(.81,.73,.81)).grow(.07).has_point(local): return false
	var exclusions: Array[RID]=worker.query_exclusions()
	exclusions.append(worker.equipped_tool.get_rid())
	exclusions.append(holder.get_rid())
	_query.exclude=exclusions
	_query.shape = _empty_foot_shape
	_query.transform = Transform3D(Basis.IDENTITY,toe.origin)
	_query.motion = Vector3.ZERO
	if source_budget_enabled: _empty_toe_native_query_calls+=1
	ops_native += 1
	var hits: Array=worker.get_world_3d().direct_space_state.intersect_shape(_query,1)
	if not hits.is_empty():
		var hit: Dictionary=hits[0]
		var collider: Object=hit.get("collider")
		last_native_obstacle={"body":str(collider.get_path()) if collider is Node else str(collider),"rid":str(hit.rid),"shape":hit.shape,
			"empty_foot":Part.encode_transform(_query.transform),"radius":_empty_foot_shape.radius}
	return hits.is_empty()

static func _box_distance(box: AABB,point: Vector3) -> float:
	return point.distance_to(point.clamp(box.position,box.end))

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
	if _seat_settling:
		# The caught body settles level on BOTH rubber trays: it moves only
		# within their contact (the first-touched tray releases its rubber
		# compression) plus a small damped rebound/rattle into the rubber.
		var t := _seat_settle_age
		var weight := smoothstep(0.0,SEAT_SETTLE_SECONDS,t)
		var body_local := _interp(_seat_settle_from,_seat_settle_to,weight)
		if _seat_rebound:
			var dip := _seat_give(t)
			# One rattle: the shaft rocks about its own axis on the rubber (the
			# head swings visibly; the contact features stay on both trays).
			var rattle := SEAT_RATTLE*exp(-t/.05)*sin(TAU*t/.09)
			var centre: Vector3 = body_local.origin
			var axis: Vector3 = body_local.basis.y.normalized()
			var shake := Transform3D(Basis(axis,rattle),Vector3.ZERO)
			body_local = Transform3D(Basis.IDENTITY,centre-_seat_normal*dip)*shake*Transform3D(Basis.IDENTITY,-centre)*body_local
		# Resting on both trays throughout: never above either rubber top.
		if _pad_features.size() == 2:
			var lift := maxf(_pad_gap(body_local,0),_pad_gap(body_local,1))
			if lift > 0.0: body_local.origin -= _seat_normal*lift
		if t >= maxf(SEAT_SETTLE_SECONDS,SEAT_REBOUND_SECONDS if _seat_rebound else 0.0):
			body_local = _seat_settle_to
			_seat_settling = false
		_back_local = _root.affine_inverse()*(_body_frame*body_local)
	back_anchor.global_transform = _root*_back_local
	worker.equipped_tool.global_transform = back_anchor.global_transform

static func _seat_give(t: float) -> float:
	# Rubber compression under the caught body (m, positive = into the tray).
	# The rubber springs back to its rest preload (never past it: the body
	# stays on both trays), then one small second dip.
	if t < .07: return SEAT_GIVE*sin(PI*t/.07)
	if t < .09: return 0.0
	if t < .15: return .12*SEAT_GIVE*sin(PI*(t-.09)/.06)
	return 0.0

func _update_clack(delta: float) -> void:
	# Visual tray response (mesh transforms only; sensors and the 2 kg load
	# integral are untouched): the rubber cradle squashes with the caught
	# body's give, and its lips flick ~10% closed over the shaft right at the
	# catch and spring back - a visible "clack".
	if _seat_models.size() != 2 or _pad_base.size() != 2: return
	var squeeze := 0.0
	if _cradle_clack >= 0.0:
		_cradle_clack += delta
		squeeze = .10*sin(PI*clampf(_cradle_clack/CLACK_SECONDS,0.0,1.0))
		if _cradle_clack >= CLACK_SECONDS: _cradle_clack = -1.0
	var give := maxf(_seat_give(_seat_settle_age),0.0) if _seat_settling and _seat_rebound and phase == "back" else 0.0
	var thickness: float = HolderVisual.PAD_SIZE.y
	for index in 2:
		var base: Transform3D = _pad_base[index]
		var scale_y := clampf((thickness-give)/thickness,.4,1.0)
		var origin: Vector3 = base.origin-base.basis.y.normalized()*(thickness-thickness*scale_y)*.5
		_seat_models[index].transform = Transform3D(base.basis*Basis.from_scale(Vector3(1.0,scale_y,1.0-squeeze)),origin)

static func _interp(a: Transform3D,b: Transform3D,weight: float) -> Transform3D:
	var qa := a.basis.get_rotation_quaternion().normalized()
	var qb := b.basis.get_rotation_quaternion().normalized()
	return Transform3D(Basis(qa.slerp(qb,weight)),a.origin.lerp(b.origin,weight))

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
	# Between transfers the worn trays wait for the equipped tool on its foot's
	# side (a transfer commits its own side/face before it starts).
	var tool: RigidBody3D = worker.equipped_tool
	if is_instance_valid(tool) and phase == "foot" and not busy():
		var s := -1.0 if worker.tool_foot_side() == 0 else 1.0
		if s != _side_sign or _holder_layout_key.size() < 3 or int(_holder_layout_key[2]) != tool.get_instance_id():
			_side_sign = s
			_commit_seat(tool)

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
	# v4: diagonal worn seat (side/face stored); "retrieve" is still seated custody.
	return {"version":4,"side":_side_sign,"flip":_seat_flip,"seat":Part.encode_transform(_seat_local),"stage":stage,"tool":tool.part_id,"phase":phase,"local":Part.encode_transform(_back_local),"home":Part.encode_transform(_home_toe_body),"home_binding":Part.encode_transform(_home_toe_in_ankle),"pending":pending_action,"pending_job":_pending_job,"motion":saved_item_motion(),
		"linear_damp":_saved_linear_damp,"linear_mode":_saved_linear_mode,"angular_damp":_saved_angular_damp,"angular_mode":_saved_angular_mode,"damping_saved":_damping_saved,
		# An airborne tool resumes its flight and catch exactly (advance clock,
		# catch trim, cube acting, step plans); plain JSON-safe numbers only.
		"flight":_flight_record() if phase == "flight" else {}}

func restore_state(data: Dictionary) -> void:
	_restore = data.duplicate(true)

func bind_restored_item(tool: RigidBody3D) -> bool:
	if _restore.is_empty(): return false
	if str(_restore.get("tool","")) != tool.part_id: return false
	if str(_restore.get("phase","foot")) in ["foot","prepare","return"]:
		# A save taken while the toe holds it (gather/hold/kick, or on its way
		# home after retrieval) restores the same tool in the ordinary foot
		# carry: the yard re-equips it on the foot.
		_restore.clear()
		return false
	worker.set_equipped_tool(tool)
	_restore_binding(tool)
	# A restored seated or airborne tool finds its trays already in place.
	_show_layout(is_instance_valid(worker.equipped_tool) and phase in ["flight","back","retrieve"])
	return true

func _restore_binding(tool: RigidBody3D) -> void:
	if str(_restore.get("tool","")) != tool.part_id:
		_restore.clear()
		return
	var saved_phase := str(_restore.get("phase","foot"))
	_home_toe_body = Part.decode_transform(_restore.get("home",Part.encode_transform(_home_toe_body)))
	_home_toe_in_ankle=Part.decode_transform(_restore.get("home_binding",Part.encode_transform(_home_toe_in_ankle)))
	if saved_phase == "back" or (saved_phase == "retrieve" and _restore_was_seated()):
		# Yard restoration has rebuilt this item at its saved world pose. Bind
		# that same untouched body against the newly restored actual rig frame.
		# The ordinary worker save does not restore its AnimationPlayer time;
		# reusing yesterday's evaluated root would jump the source on tick one.
		# A save taken during retrieval (before toe contact) is still seated.
		_sync_root()
		migrated_seat = false
		var local: Transform3D = _body_frame.affine_inverse()*tool.global_transform
		var version := int(_restore.get("version",2))
		_cache_tool(tool)
		if version >= 4:
			_side_sign = float(_restore.get("side",_side_sign))
			_seat_flip = float(_restore.get("flip",_seat_flip))
		else:
			# Older horizontal seats: handle side and resting face from the body.
			_side_sign = -signf(local.basis.y.x) if absf(local.basis.y.x) > .5 else _side_sign
			_seat_flip = 1.0 if local.basis.x.y >= 0.0 else -1.0
		_commit_seat(tool)
		var legacy: Vector3 = LEGACY_SEAT if version < 3 else LEGACY_SEAT_V2
		if version < 4 and absf(local.origin.x-legacy.x) <= .10 and absf(local.origin.y-legacy.y) <= .10 \
			and absf(local.origin.z-legacy.z) <= .06 and local.basis.y.dot(Vector3(-_side_sign,0,0)) > .97:
			# Documented v2/v3 migration (at load, before any frame is shown): the
			# same seated body moves from the old horizontal seat (rack z .58 or
			# the v3 worn seat) onto the current diagonal trays, unchanged custody.
			local = _seat_local
			tool.global_transform = _body_frame*local
			migrated_seat = true
		_back_local = _root.affine_inverse()*tool.global_transform
		# The restored rig starts from its raw pose; ease the same body back onto
		# the trays relative to the body (bounded, like the catch settle).
		var rest := Transform3D(_seat_local.basis,_seat_local.origin+_seat_local.basis.y*clampf(_seat_local.basis.y.dot(local.origin-_seat_local.origin),-.05,.05))
		if rest.origin.distance_to(local.origin) < .12 and _turn(rest.basis.get_rotation_quaternion(),local.basis.get_rotation_quaternion()) < .25:
			_seat_settle_from = local
			_seat_settle_to = rest
			_seat_settle_age = 0.0
			_seat_settling = true
			_seat_rebound = false
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
			# (A retrieval save is restored seated above; this branch keeps the
			# loose release for a genuinely unseated body.)
			var motion: Dictionary = _restore.get("motion",{})
			tool.set_carried(null)
			tool.linear_velocity = Part.decode_vector(motion.get("velocity",Part.encode_vector(tool.linear_velocity)))
			tool.angular_velocity = Part.decode_vector(motion.get("angular_velocity",Part.encode_vector(tool.angular_velocity)))
			_saved_linear_damp = float(_restore.get("linear_damp",tool.linear_damp))
			_saved_linear_mode = int(_restore.get("linear_mode",tool.linear_damp_mode))
			_saved_angular_damp = float(_restore.get("angular_damp",tool.angular_damp))
			_saved_angular_mode = int(_restore.get("angular_mode",tool.angular_damp_mode))
			_damping_saved = bool(_restore.get("damping_saved",false))
			var flight: Dictionary = _restore.get("flight",{})
			if saved_phase == "flight" and not flight.is_empty() and _resume_flight(tool,flight): pass
			else: drop("Interrupted back-tool transfer restored as the same loose tool")
	_restore.clear()

func _flight_record() -> Dictionary:
	var vec := func(v: Variant) -> Variant: return Part.encode_vector(v) if v is Vector3 else v
	# The flight clock pairs with the tool pose this tick's physics step started
	# from; a save after that step (or in a later tick) holds the stepped body,
	# so the saved clock advances with it and the restore stays on schedule.
	var ticks := maxi(int(Engine.get_physics_frames()-_age_frame),0)+(0 if Engine.is_in_physics_frame() else 1)
	var record := {"age":_age+float(ticks)/float(Engine.physics_ticks_per_second),"seconds":_flight_seconds,"trim":_catch_trim,"stage":stage,"stunt":not _stunt.is_empty(),
		"empty_age":_empty_return_age,"empty_active":_empty_return_active,"support_done":_support_step_done}
	record.advance = {"d":float(_advance.get("d",0.0)),"seconds":float(_advance.get("seconds",ADVANCE_SECONDS)),
		"dir":vec.call(_advance.get("dir",Vector3.FORWARD)),"origin":vec.call(_advance.get("origin",worker.global_position)),"peak_force":float(_advance.get("peak_force",0.0))}
	if _stunt.has("seat_com_planned"): record.seat_com = vec.call(_stunt.seat_com_planned)
	if _stunt.has("dir"): record.dir = vec.call(_stunt.dir)
	if not _acting.is_empty(): record.acting = {"shift":vec.call(_acting.shift),"roll":float(_acting.roll),"pitch":float(_acting.pitch),"yaw":float(_acting.yaw)}
	if not _step_plan.is_empty():
		record.step = {"start":vec.call(_step_plan.start),"direction":vec.call(_step_plan.direction),"follow":float(_step_plan.follow),
			"t_follow":float(_step_plan.t_follow),"landing":vec.call(_step_plan.landing),"t_land":float(_step_plan.t_land),"lift":float(_step_plan.lift)}
	if not _support_step.is_empty():
		record.support = {"start":vec.call(_support_step.start),"landing":vec.call(_support_step.landing),"t0":float(_support_step.t0),"t1":float(_support_step.t1),"lift":float(_support_step.lift)}
	return record

func _resume_flight(tool: RigidBody3D,flight: Dictionary) -> bool:
	# The same loose body keeps its saved motion; the cradle keeps aligning
	# under it (advance clock, catch trim, cube acting, the feet's planned
	# steps) and the guard keeps it off the capsule. Nothing is fabricated:
	# the catch still needs real two-tray contact.
	var advance: Variant = flight.get("advance")
	if not advance is Dictionary: return false
	_sync_root()
	_cache_tool(tool)
	_side_sign = float(_restore.get("side",_side_sign))
	_seat_flip = float(_restore.get("flip",_seat_flip))
	_commit_seat(tool)
	_foot_side = worker.tool_foot_side()
	var adv: Dictionary = advance
	_advance = {"d":float(adv.get("d",0.0)),"seconds":float(adv.get("seconds",ADVANCE_SECONDS)),
		"dir":Part.decode_vector(adv.get("dir",Part.encode_vector(Vector3.FORWARD))),
		"origin":Part.decode_vector(adv.get("origin",Part.encode_vector(worker.global_position))),"peak_force":float(adv.get("peak_force",0.0))}
	_stunt.clear()
	if bool(flight.get("stunt",false)):
		# Only the fields the flight reads; the full plan is not needed any more.
		_stunt = {"dir":Part.decode_vector(flight.get("dir",Part.encode_vector(_advance.dir))),"advance":_advance.d,"T_adv":_advance.seconds}
		if flight.has("seat_com"): _stunt.seat_com_planned = Part.decode_vector(flight.seat_com)
	_age = float(flight.get("age",0.0))
	_flight_seconds = float(flight.get("seconds",FLIGHT_SECONDS))
	_catch_trim = float(flight.get("trim",0.0))
	_empty_return_age = float(flight.get("empty_age",0.0))
	_support_step_done = bool(flight.get("support_done",false))
	_acting.clear()
	var acting: Variant = flight.get("acting")
	if acting is Dictionary:
		_acting = {"shift":Part.decode_vector(acting.shift),"roll":float(acting.roll),"pitch":float(acting.pitch),"yaw":float(acting.yaw)}
		# The restored cube starts where the saved one was (the cradle height
		# the catch was aimed at), not at Pose's neutral sway.
		var pose: SkeletonModifier3D = worker._pose
		if pose:
			pose._sway_shift = _acting.shift
			pose._sway_offset = _acting.shift.x
			pose._sway_roll = _acting.roll
			pose._sway_pitch = _acting.pitch
	_step_plan.clear()
	var step: Variant = flight.get("step")
	if step is Dictionary:
		_step_plan = {"start":Part.decode_vector(step.start),"direction":Part.decode_vector(step.direction),"follow":float(step.follow),
			"t_follow":float(step.t_follow),"landing":Part.decode_vector(step.landing),"t_land":float(step.t_land),"lift":float(step.lift)}
	_support_step.clear()
	var support: Variant = flight.get("support")
	if support is Dictionary:
		_support_step = {"start":Part.decode_vector(support.start),"landing":Part.decode_vector(support.landing),"t0":float(support.t0),"t1":float(support.t1),"lift":float(support.lift)}
	phase = "flight"
	_set_stage(str(flight.get("stage","")))
	_tool_id = tool.get_instance_id()
	_tool_rid = tool.get_rid()
	_flight_prev_valid = false
	_guard_release(tool)
	# Free flight as at the launch (no damping; the saved originals return at
	# the catch or release).
	tool.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	tool.linear_damp = 0.0
	tool.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	tool.angular_damp = 0.0
	tool.sleeping = false
	print("CONTRAPTION_BACK_TOOL flight_resumed ",JSON.stringify({"tool":tool.part_id,"rid":str(tool.get_rid()),"age":_age,"stunt":not _stunt.is_empty()}))
	return true

func _restore_was_seated() -> bool:
	# v2 and v3 saves of "retrieve" both keep the tool on back_anchor until the
	# exact toe contact; the restored body still lies at its seated pose.
	var local: Transform3D = Part.decode_transform(_restore.get("local",Part.encode_transform(Transform3D.IDENTITY)))
	return local != Transform3D.IDENTITY

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
	_set_stage("")
	_stunt.clear()
	_advance.clear()
	_support_step.clear()
	_return_search.clear()
	_seat_settling = false
	_route_fast = false
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
	_empty_return_age=0.0
	_step_plan.clear()
	_tool_free_recovery=true
	_empty_return_source_id=source.get_instance_id()
	_empty_return_source_rid=source.get_rid()
	return true

func recovering() -> bool:
	# The catch beat (absorb, proud bounce) reads on its own: Pose's stopped
	# catch-up step waits for it.
	return busy() or _empty_return_tail>0.0 or _work_pole_active or _cancel_pole_active or stage in ["settle","proud"]

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
	# Tool-local visual surface samples (rubber tray tops are measured on them).
	_visual_points = PackedVector3Array()
	for node: Node in tool.find_children("*","MeshInstance3D",true,false):
		var mesh_node := node as MeshInstance3D
		if not mesh_node.mesh or not mesh_node.is_visible_in_tree(): continue
		var local: Transform3D = inverse*mesh_node.global_transform
		for surface in mesh_node.mesh.get_surface_count():
			for vertex: Vector3 in mesh_node.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]: _visual_points.append(local*vertex)

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
	# Worn backpack (11 material meshes, 2 tray sensors): the plate is fitted
	# 1 mm off the skin (or, if a future remesh defeats the exact fit, a box
	# seated BODY_GAP off the measured back face); two bronze straps run from
	# the plate up the back toward the roof edge; each rubber tray sits on a
	# bronze shelf and gusset bolted to the plate or strap, entirely inside
	# the body silhouette and above the cube's bottom edge.
	var body_fitted:=HolderVisual.fit_to_body(worker._skin_mesh,worker._skeleton)
	_plate_back = PLATE_BACK if body_fitted else HolderVisual.measured_back(worker._skin_mesh,worker._skeleton)+HolderVisual.BODY_GAP+HolderVisual.SEAT_SIZE.z
	var plate_origin: Vector3 = HolderVisual.SEAT_ORIGIN if body_fitted else Vector3(0,-.13,_plate_back-HolderVisual.SEAT_SIZE.z*.5)
	_box("RootSeat",HolderVisual.SEAT_SIZE,plate_origin,_stone)
	for side: float in [-1.0,1.0]:
		# Each strap follows the skin's own section (1 mm off it) up the back
		# and over the roof bevel, ending on the roof under its rivet; a rig
		# that cannot be sectioned keeps the flat strap on the measured back.
		var fitted: ArrayMesh = HolderVisual.strap_mesh(worker._skin_mesh,worker._skeleton,side) if body_fitted else null
		var strap: MeshInstance3D
		if fitted:
			strap = MeshInstance3D.new()
			strap.name = "CradleArm"
			strap.mesh = fitted
			strap.material_override = _bronze
			holder.add_child(strap)
		else:
			strap = _box("CradleArm",HolderVisual.STRAP_SIZE,Vector3(side*HolderVisual.STRAP_X,HolderVisual.STRAP_Y,HolderVisual.measured_back(worker._skin_mesh,worker._skeleton)+HolderVisual.BODY_GAP+HolderVisual.STRAP_SIZE.z*.5),_bronze)
		_straps.append(strap)
		var rivet := MeshInstance3D.new()
		rivet.name = "screw"
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = .016
		cylinder.bottom_radius = .016
		cylinder.height = .01
		cylinder.radial_segments = 6
		rivet.mesh = cylinder
		rivet.material_override = _bronze
		if fitted: rivet.transform = HolderVisual.strap_end(side)
		else:
			rivet.rotation.x = PI*.5
			rivet.position = Vector3(side*HolderVisual.STRAP_X,-.06,_plate_back+.0035)
		holder.add_child(rivet)
	for index in 2:
		_gussets.append(_box("BronzeSocket",HolderVisual.SOCKET_SIZE,Vector3.ZERO,_bronze))
		_drop_arms.append(_box("DropArm",HolderVisual.SHELF_SIZE,Vector3.ZERO,_bronze))
		_seat_models.append(_box("RubberSeat",HolderVisual.PAD_SIZE,Vector3.ZERO,_rubber))
		var tray := CollisionShape3D.new()
		tray.name = "SeatedContact"
		var shape := BoxShape3D.new()
		shape.size = HolderVisual.TRAY_SENSOR_SIZE
		tray.shape = shape
		holder.add_child(tray)
		_seat_colliders.append(tray)
	_feature_shape.size = Vector3(.004,.03,.03)
	_commit_seat(null)
	_show_layout(false)

func _layout_holder() -> void:
	# Instant: show the current display target (tests, restores, the build).
	_show_layout(_display_seat)

## Worn-pack display. The trays rest level and mirrored (x-symmetric hardware,
## so the empty pack adds no sideways load to the balance) whenever no tool is
## seated or on its way to the seat; a transfer that commits to a seat swings
## them into that seat's diagonal layout over HOLDER_LAYOUT_SECONDS (well
## before any catch), and they swing back once the tool has left the back.
## The planner's candidate seats never move the hardware.
func _show_layout(seat: bool) -> void:
	if _seat_models.size() != 2: return
	_display_seat = seat
	_display_key = [seat]+(_holder_layout_key if seat else [])
	_display_to = _layout_targets(seat)
	_display_t = 1.0
	_apply_layout(_display_to)

func _update_holder_display(delta: float) -> void:
	if _seat_models.size() != 2: return
	var tool: RigidBody3D = worker.equipped_tool
	var want: bool = is_instance_valid(tool) and (phase in ["flight","back","retrieve"] or (phase == "prepare" and stage != "retrace"))
	var key: Array = [want]+(_holder_layout_key if want else [])
	if key != _display_key:
		_display_key = key
		_display_seat = want
		_display_from = _current_layout()
		_display_to = _layout_targets(want)
		_display_t = 0.0
	if _display_t >= 1.0: return
	_display_t = minf(_display_t+delta/HOLDER_LAYOUT_SECONDS,1.0)
	var weight := smoothstep(0.0,1.0,_display_t)
	var blended: Array[Transform3D] = []
	for index in _display_to.size(): blended.append(_display_from[index].interpolate_with(_display_to[index],weight))
	_apply_layout(blended)

func _layout_parts() -> Array[Node3D]:
	return [_seat_models[0],_seat_colliders[0],_drop_arms[0],_gussets[0],_seat_models[1],_seat_colliders[1],_drop_arms[1],_gussets[1]]

func _current_layout() -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var parts := _layout_parts()
	for index in parts.size():
		# The rubber's own clack squash is not part of the layout.
		out.append(_pad_base[0 if index < 4 else 1] if index%4 == 0 and _pad_base.size() == 2 else parts[index].transform)
	return out

func _apply_layout(transforms: Array[Transform3D]) -> void:
	var parts := _layout_parts()
	for index in parts.size(): parts[index].transform = transforms[index]
	if _pad_base.size() == 2:
		_pad_base[0] = transforms[0]
		_pad_base[1] = transforms[4]
	if _holder_geometry_ready: _holder_geometry_ready = _holder_geometry.rebuild()

func _layout_targets(seat: bool) -> Array[Transform3D]:
	# Each tray: rubber top on the tool's measured visual underside (seat) or
	# level and mirrored (rest), sensor top PAD_PRELOAD above it (a resting
	# tool genuinely overlaps both sensors), a bronze shelf under the rubber
	# reaching the plate (or the strap/skin above it) and a gusset beneath.
	var n: Vector3 = _seat_normal if seat else Vector3.UP
	var along: Vector3 = _seat_local.basis.y.normalized() if seat else Vector3.RIGHT
	var tops: Array = _pad_tops if seat else [Vector3(-REST_PAD.x,REST_PAD.y,REST_PAD.z),REST_PAD]
	var depth_axis := along.cross(n).normalized()
	var pad_basis := Basis(along,n,depth_axis)
	var out: Array[Transform3D] = []
	for index in 2:
		var top: Vector3 = tops[index]
		var on_plate: bool = absf(top.x) <= HolderVisual.SEAT_SIZE.x*.5+.005 and top.y <= HolderVisual.SEAT_ORIGIN.y+HolderVisual.SEAT_SIZE.y*.5+.005
		var mount_z: float = _plate_back if on_plate else HolderVisual.MEASURED_BACK+HolderVisual.BODY_GAP+HolderVisual.STRAP_SIZE.z
		var back_z: float = top.z+HolderVisual.PAD_SIZE.z*.5
		var shelf_centre: Vector3 = top-n*(HolderVisual.PAD_SIZE.y+HolderVisual.SHELF_SIZE.y*.5)
		shelf_centre.z = (mount_z+back_z)*.5
		var gusset_basis := Basis(n.cross(Vector3.BACK).normalized(),n,Vector3.BACK)
		var gusset_centre: Vector3 = shelf_centre-n*(HolderVisual.SHELF_SIZE.y*.5+HolderVisual.SOCKET_SIZE.y*.5)
		gusset_centre.z = mount_z+HolderVisual.SOCKET_SIZE.z*.5
		out.append(Transform3D(pad_basis,top-n*HolderVisual.PAD_SIZE.y*.5))
		out.append(Transform3D(pad_basis,top+n*(PAD_PRELOAD-HolderVisual.TRAY_SENSOR_SIZE.y*.5)))
		out.append(Transform3D(pad_basis*Basis.from_scale(Vector3(1,1,maxf(back_z-mount_z,.02)/HolderVisual.SHELF_SIZE.z)),shelf_centre))
		out.append(Transform3D(gusset_basis,gusset_centre))
	return out

func _box(title: String,size: Vector3,position: Vector3,material: StandardMaterial3D) -> MeshInstance3D:
	var key := str(size)
	if not _holder_meshes.has(key):
		if title == "RootSeat": _holder_meshes[key] = HolderVisual.seat_mesh()
		elif title == "BronzeSocket" and size == HolderVisual.SOCKET_SIZE: _holder_meshes[key] = HolderVisual.socket_mesh()
		elif title == "RubberSeat" and size == HolderVisual.PAD_SIZE: _holder_meshes[key] = HolderVisual.cradle_mesh()
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

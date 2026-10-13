extends RefCounted
## Real native-body head approach and return. The upright capsule assist is
## suspended during the leap; pose, feet, tool and cargo follow that same body.
## The finite in-air force/torque correction is assisted animation physics.
## It never assigns a body transform, velocity or stock scale.
const HolderClearance := preload("res://LogicObjects/Wako/wako_head_holder_clearance.gd")
const LegGeometry := preload("res://Components/Contraptions/shared_leg_geometry.gd")
const Catalogue := preload("res://Components/Contraptions/part_catalog.gd")
const StockBounds := preload("res://Components/Contraptions/depot_stock_layout.gd")
const LoadGeometry := preload("res://Components/Contraptions/rolling_balance.gd")
const GRAVITY := 9.8
const CONTACT_GAP := .0001
const CONTACT_ERROR := .00075
const MAXIMUM_SPEED := 8.5
const MAXIMUM_ACCELERATION := GRAVITY * 2.0
const MAXIMUM_ANGULAR_ACCELERATION := 24.0
const CONTACT_QUERY_BIT := 1 << 30
# Admission keeps 10% of the 2 g force cap and 15% of the 24 rad/s² angular cap
# for measured tracking error; feed-forward plus PD can never exceed either cap.
const FORCE_BUDGET := .9
const ANGULAR_BUDGET := .85
# --- Supported departure (round 3) -------------------------------------------
# The native body itself crouches, lunges toward the stock and drives off the
# planted balls of its feet: ground reactions (push only, inside a friction
# cone, paired with the support) carry the planned motion; any excess beyond
# the cone is the ordinary finite assist. The release state IS the flight's
# launch: no launch impulse. "beta" is the ball-to-hip line from vertical at
# release, set from the launch elevation so the leg pushes along the flight.
const PREP := {"crouch":.36,"drive":.14,"bottom_speed":.4,"bottom_accel":8.0,"bottom_pitch":deg_to_rad(14.0),"bottom_spin":1.2,
	"release_pitch":deg_to_rad(25.0),"release_spin":2.2,"drive_length":.18,"beta_lead":deg_to_rad(8.0),"beta_min":deg_to_rad(10.0),"beta_max":deg_to_rad(28.0)}
# A crew counts in together: a nod (the follower answers a few frames later),
# a crouch (a planted 21 cm crouch cannot drop faster than ~0.4 s without
# leaving its support), a shared 0.1 s hold at the bottom, then the drive.
const CREW_PREP := {"crouch":.60,"drive":.15,"bottom_speed":.35,"bottom_accel":8.0,"bottom_pitch":deg_to_rad(12.0),"bottom_spin":1.0,
	"release_pitch":deg_to_rad(22.0),"release_spin":2.2,"drive_length":.18,"beta_lead":deg_to_rad(8.0),"beta_min":deg_to_rad(10.0),"beta_max":deg_to_rad(26.0),
	"nod":.06,"hold":.10}
const CREW_CROUCH_LAG := .04
const NOD_ANGLE := deg_to_rad(7.0)
const NOD_SECONDS := .16
# A short lunge for cramped launch places (screens close ahead).
const SHORT_PREP := {"crouch":.32,"drive":.13,"bottom_speed":.3,"bottom_accel":8.0,"bottom_pitch":deg_to_rad(10.0),"bottom_spin":1.0,
	"release_pitch":deg_to_rad(18.0),"release_spin":2.4,"drive_length":.15,"beta_lead":deg_to_rad(12.0),"beta_min":deg_to_rad(4.0),"beta_max":deg_to_rad(12.0)}
# A launch place right behind a screen: no lunge, an upright drive.
const STAND_PREP := {"crouch":.30,"drive":.13,"bottom_speed":.25,"bottom_accel":8.0,"bottom_pitch":deg_to_rad(5.0),"bottom_spin":.8,
	"release_pitch":deg_to_rad(10.0),"release_spin":2.4,"drive_length":.15,"beta_lead":deg_to_rad(40.0),"beta_min":0.0,"beta_max":deg_to_rad(4.0)}
const FRICTION := 1.1
const SUPPORT_MAXIMUM := 6.0*GRAVITY
const SUPPORT_LEVER := .12
const RELEASE_KNEE := deg_to_rad(12.0)
const HEEL_PEEL := deg_to_rad(30.0)
# --- Outbound flight ---------------------------------------------------------
# Free fall from the release, then ONE late flare (the legs open) that ends a
# short free fall above the roof, then a REAL head impact on the stock (its
# collision exception is lifted for the touch). Candidates are [apex above
# the release COM (m), head impact speed (m/s)], tried in order; the long tier
# keeps the shape with higher apexes (screens), the original quintic timings
# stay as the last-resort legacy tier.
# Round 4: the head arrives at 1.8-1.9 m/s (Jolt still stops a cube cleanly
# below ~2 m/s), which keeps the assisted arrival brake short.
const SOLO_OUTBOUND := [[.45,1.85],[.42,1.85],[.48,1.85],[.39,1.85],[.51,1.8],[.36,1.85],[.33,1.85],[.30,1.85]]
const CREW_OUTBOUND := [[.60,1.8],[.55,1.8],[.65,1.75],[.50,1.8],[.70,1.75],[.45,1.8]]
const LONG_OUTBOUND := [[.6,1.7],[.75,1.7],[.95,1.65],[1.2,1.6],[1.45,1.55]]
const LEGACY_OUTBOUND := [[1.6,.70],[2.0,.70],[2.0,1.0],[2.4,1.0],[2.4,1.35],[2.8,1.35],[3.0,1.35],[3.4,1.35]]
const FLARE_PLATEAU := 16.4
const FLARE_RAMP := .04
const IMPACT_FALL := .045
const ARRIVAL_DRIFT := .12
const HORIZONTAL_RAMP := .04
# Horizontal braking ends this long before the roof touch: a level, vertical
# final head descent.
const HORIZONTAL_LEAD := .06
# Spin: release spin, a faster tucked coast, one brake while the legs open,
# then a slower final turn into the head impact.
const SPIN_RAMP := .03
const SPIN_BRAKE := 20.0
const TUCK_SPIN_START := .08
const TUCK_SPIN_SECONDS := .16
# Spin carried into the impact: a small solo stock takes the roof at a brisk
# turn (the real contact stops it); a wide stock or crew turns slower so the
# trailing roof edge cannot reach the stock before the roof is level.
const IMPACT_SPIN := 2.6
const WIDE_IMPACT_SPIN := 2.0
const OPEN_LEAD := .16
const MAXIMUM_SPIN := 6.0
const MINIMUM_SPIN := 2.2
# --- Head impact, squash and contact hold ------------------------------------
# Lift the stock's collision exception this long before the planned touch.
const IMPACT_ARM := 2.5/120.0
const IMPACT_WINDOW := 3.0/120.0
# The cube squashes about its crown on the head impact (root travel; the cube
# itself shortens twice this), holds it through the dwell, then releases into a
# stretch at the peak of the head push (a headspring's kip).
const IMPACT_SQUASH := .028
const PUSH_STRETCH := .018
# Heavy loads: a held strain beat on the head before the loaded kick (the cube
# visibly compresses, the knees tremble), released by the push.
const STRAIN_SQUASH := .028
const STRAIN_SECONDS := .27
# Contact hold gains (same 2 g / 24 rad/s² caps): a stopped head settles its
# sub-millimetre error within a few ticks of the impact.
const HOLD_GAINS := [6400.0,160.0,6400.0,160.0]
# The hold floats the roof this far above the stock (inside the unchanged
# half-millimetre gate) so friction at a tilted edge cannot pin a residual.
const HOLD_GAP := .0002
const FLIGHT_GAINS := [36.0,12.0,60.0,12.0]
const CONTACT_PRESS := 2.0/120.0
# --- Return ------------------------------------------------------------------
# The legs snap RETURN_LEAD before the head push; the supported push spreads
# the return impulse over the leg kick (paired with the stock's support; a
# stylised spread of the push-off impulse, reported in flight_stats). The
# flight is then BALLISTIC (round 4): candidates [apex above the touchdown COM,
# vertical lift]; the flight time follows from that apex under g - lift (>=
# 0.9 g brisk, >= 0.8 g on the high fallback arcs), horizontal travel bleeds at
# most the drift brake, and the landing is planned short of the launch place
# by the distance the touchdown drift rolls out over the planted feet.
const SOLO_RETURN := [[.30,.6],[.27,.6],[.33,.6],[.24,.6],[.36,.8],[.21,.6]]
const HEAVY_RETURN := [[.30,.8],[.27,.8],[.33,.8],[.25,.8],[.36,1.0],[.22,.8]]
const LONG_RETURN := [[.45,1.2],[.6,1.5],[.75,1.8],[.9,2.0]]
const LEGACY_RETURN := [[1.6,.70],[2.0,.90],[2.4,1.1],[2.55,1.1],[2.7,1.35],[2.85,1.35]]
const LEGACY_TOUCHDOWN := -1.15
const RETURN_LEAD := 2.0/120.0
const RETURN_PUSH := .10
const HEAVY_PUSH := .12
const PUSH_RAMP := .025
const DRIFT_DECEL := 1.5
# A loaded solo return never arcs above the empty outbound's height class.
const SOLO_APEX_ABOVE_HOME := .40
# Planted-feet roll-out of the touchdown drift (friction-limited, ~0.45 g).
const LAND_BRAKE := 4.5
const LAND_SHORT := .20
const RETURN_SPIN := 4.5
const CREW_RETURN_SPIN := 3.5
const LANDING_SPIN := .8
# Planned leg beats in the cube frame: [hip flexion toward the face, knee
# flexion, knee adduction toward the midline (negative splays outward), foot
# point] in radians.
const LEG_TRAIL := [deg_to_rad(2.0),deg_to_rad(8.0),0.0,deg_to_rad(45.0)]
# Pike tuck (round 4): the knees fold under the seat with NO thigh splay, so
# the feet stay hip-width apart from every camera. Only when the own padded
# cube, holder or tool refuses it does the fit add a small splay (<= 18 deg),
# and that splay follows the knee fold (the knees lead in and out).
const LEG_TUCK := [deg_to_rad(44.0),deg_to_rad(132.0),0.0,deg_to_rad(46.0)]
const LEG_SPLAYS := [0.0,deg_to_rad(10.0),deg_to_rad(15.0),deg_to_rad(18.0)]
# A crew partner stands 0.98 m away: the same pike.
const LEG_PIKE := [deg_to_rad(44.0),deg_to_rad(132.0),0.0,deg_to_rad(46.0)]
# Moving hold: the tuck keeps deepening through the apex (knee, hip, toes),
# then releases into the opening; never a frozen shape while the body
# travels. Its deepest shape (hip 50, knee 139) keeps the shins 85 mm under
# the padded cube: a deeper pike only fits by splaying the thighs.
const TUCK_HOLD := [deg_to_rad(6.0),deg_to_rad(7.0),0.0,deg_to_rad(6.0)]
const SPLAY_KNEE_FROM := deg_to_rad(30.0)
const SPLAY_KNEE_TO := deg_to_rad(110.0)
# The back holder hangs below the seat: the fit blends the shin fold down from
# the full tuck toward this mild one until every link is clear.
const LEG_TUCK_LOW := [deg_to_rad(40.0),deg_to_rad(70.0),deg_to_rad(8.0),deg_to_rad(45.0)]
const LEG_TADA := [deg_to_rad(6.0),deg_to_rad(20.0),0.0,deg_to_rad(52.0)]
const LEG_RELOAD := [deg_to_rad(30.0),deg_to_rad(96.0),deg_to_rad(6.0),deg_to_rad(40.0)]
const LEG_STRAIN := [deg_to_rad(36.0),deg_to_rad(110.0),deg_to_rad(6.0),deg_to_rad(36.0)]
# The kick swings the straight legs 25 deg past the vertical toward home, toes
# pointed, while the head pushes (the kip of a headspring).
const LEG_KICK := [deg_to_rad(25.0),deg_to_rad(4.0),0.0,deg_to_rad(60.0)]
const LEG_LAND := [deg_to_rad(16.0),deg_to_rad(32.0),0.0,0.0]
# The legs keep their momentum through the head impact: they whip past the
# vertical (toward the travel side), then recoil into the reload.
const LEG_WHIP := deg_to_rad(18.0)
const WHIP_SECONDS := .05
const RECOIL_SECONDS := .07
const TUCK_IN_SECONDS := .10
# The legs open with the arrival brake: from the first assisted tick (a little
# before), spread over OPEN_SECONDS, reaching up into the plant before impact.
const OPEN_SECONDS := .28
const OPEN_ANTICIPATION := .05
const PLANT_HOLD := .03
const MAXIMUM_PIN_POINT := deg_to_rad(62.0)
const TRAIL_SECONDS := .05
const TOE_CURL := deg_to_rad(22.0)
const FOOT_FLATTEN_SECONDS := .12
# Crew members are two creatures: the follower's leg curves run ~4 frames
# behind (catching up before each impact/touchdown) and its tuck is 8 deg
# apart; the shared load, flight timing and plan stay exact.
const TWIN_DELAY := .06
const TWIN_ANGLE := deg_to_rad(8.0)
# Touchdown absorb (P0-6): one monotonic deceleration of the visual root from
# the measured impact speed to the bottom, a short hold, a slower recovery.
# The rise out of the absorb is one ease-in-out curve (root <= ~0.5 m/s); the
# leap hands back LANDING_TAIL before it ends and the curve completes after the
# hand-off, so the carry stance is reached with continuous root velocity.
const ABSORB := {"hold":.03,"recover":.45,"depth":.16}
const CREW_ABSORB := {"hold":.08,"recover":.65,"depth":.18}
const LANDING_TAIL := .2
# The rise is stretched so the visual root never climbs faster than this
# (the native body keeps rising under its spring meanwhile).
const RISE_SPEED := .47
const ABSORB_ROCK := deg_to_rad(3.0)
const DRIFT_ROCK := deg_to_rad(2.5)
const BRISK_ROOT_SPEED := 3.0
# A knocked stock: unassisted flight while retrying a bare recovery this long.
const BARE_WAIT_SECONDS := .2
# An interrupted ballistic fall: translational correction stays this small (the
# COM keeps its own arc); the assist only turns the body feet-down.
const FALL_ASSIST := 3.0

var worker: RigidBody3D
var part: RigidBody3D
var crew: Array = []
var state := ""
var reason := ""
var elapsed := 0.0
var contact_local := Vector3.ZERO
var contact_normal := Vector3.UP
var _crew_axis := Vector3.RIGHT
var contact_error := INF
var contact_surface_gap := INF
var contact_surface_penetration := .0
var contacted := false
var source_before_contact := Transform3D.IDENTITY
var source_after_contact := Transform3D.IDENTITY
var _source_start := Transform3D.IDENTITY
var _home := Transform3D.IDENTITY
var _root_local := Transform3D.IDENTITY
var _tool_local := Transform3D.IDENTITY
var _tool_bounds := AABB()
var _holder_bounds := AABB()
# The holder without its roof straps/rivets: the stock is meant to land on the roof.
var _holder_source_bounds := AABB()
var _flight_start := Transform3D.IDENTITY
var _destination := Transform3D.IDENTITY
var _launch_velocity := Vector3.ZERO
var _flight_seconds := 1.3
var _bones: Array[Transform3D] = []
var _snapshot_ready := false
var _saved_damping := .0
var _saved_damping_mode := RigidBody3D.DAMP_MODE_COMBINE
var _saved_angular_damping := .0
var _saved_angular_damping_mode := RigidBody3D.DAMP_MODE_COMBINE
var _settled := 0.0
var _stock_bounds := AABB()
var _gun_head_geometry: Dictionary = {}
var _cargo_refusal_rows := 0
static var _contact_face_probe_rows: Dictionary={}
var _cargo_refusal_state_rows: Dictionary = {}
var _cargo_local := Transform3D.IDENTITY
var _release_watch: RigidBody3D
# A bare push-off rides its stock through the exception until the head is
# this far clear (no second, real contact push on top of the paired reaction).
var _release_margin := 0.0
# A mid-air cancel keeps the planned load until the touchdown.
var _release_on_touchdown := false
var _abort_requested := false
var _return_started := false
var _native_settings_saved := false
var _saved_angular_locks: Array[bool] = []
var _needs_angular_restore := false
var _planning_return := false
var _saved_source_layer := 0
var _saved_collision_shape: Shape3D
var _saved_collision_transform := Transform3D.IDENTITY
var _needs_collision_restore := false
var arc_failure := ""
var _launch_frame := -1
# The physics frame in which this member's advance last applied its forces.
var _advanced_frame := -1
var _head_height := .338
var _roof_samples: Array[Vector3]=[]
var _head_touch_local:=Vector3(0,.338,0)
var _rotation_axis := Vector3.RIGHT
var _rotation_angle := .0
var evaluated_leg_bases: Array[Basis]=[]
var _stunt_forward := Vector3.FORWARD
var _impact_age := -1.0
var _stunt_grounded: Array[bool] = [false,false]
var _restart_leg_points: Array[Vector3] = []
var _restart_ankles: Array[Basis] = []
var _stunt_capacity := 1.0
var _stunt_clearance_rows := 0
var _holder_clearance := HolderClearance.new()
var _holder_inverse := Transform3D.IDENTITY
var _holder_root_ref := Transform3D.IDENTITY
var _holder_capture_usec := 0
# Centre-of-mass plan: one piecewise-polynomial track per world axis and one for
# the half-turn angle about _rotation_axis. A track segment is
# [t0, t1, c0..c5] in (t - t0); evaluation clamps to the track's ends.
# The body origin is derived: COM(t) - R(t)*_com_local.
var _com_local := Vector3.ZERO
var _track_x: Array = []
var _track_y: Array = []
var _track_z: Array = []
var _track_spin: Array = []
# Choreography beats of the admitted plan (seconds into the flight).
var _beat_brake := 0.5
var _beat_open := 0.5
# First assisted arrival tick of the outbound (the legs start opening here).
var _beat_assist := 0.5
var _beat_spin_end := 1.0
var _bare_retry := 0.0
var _bare_waiting := false
var _bare_wait_start := 0.0
var _bare_wait_age := 0.0
# An interrupted dive whose remainder is no longer clear of the world.
var _dive_blocked := false
var _outbound_axis := Vector3.RIGHT
var _touchdown_velocity := Vector3.ZERO
var _launch_spin := Vector3.ZERO
var _plan_tier := ""
var _plan_candidate: Array = []
var _impact_speed := 0.0
var _absorb_depth := .0
var _contact_age := -1.0
# Cube (root bone) frames relative to the body: the standing rest root, the
# last Pose-owned gather root, and the launch root the flight carries. The
# return blends the cube back to its rest root while the body rewinds.
var _rest_root_local := Transform3D.IDENTITY
var _hold_root_local := Transform3D.IDENTITY
var _hip_root: Array[Vector3] = []
var _leg_upper: Array[float] = [.41,.41]
var _leg_lower: Array[float] = [.399,.399]
var _ankle_rest_root: Array[Basis] = []
var _shin_rest_root: Array[Vector3] = []
# Push-off: toe joints stay pinned on the ground through the extension and the
# first outbound ticks while the leg can still reach them.
var _pin_points: Array[Vector3] = []
var _pin_toe_basis: Array[Basis] = []
var _pin_ankle_offset: Array[Vector3] = []
var _pin_active := false
var _pin_release_time := -1.0
var _pin_release_pose: Array = []
var _launch_leg_pose: Array = []
var _pin_foot_basis: Array[Basis] = []
var _toe_ankle: Array[Vector3] = []
var _rest_toe: Array[Vector3] = []
var _rest_ankle: Array[Vector3] = []
var _impact_root := Vector3.ZERO
var _impact_drift := Vector3.ZERO
var _impact_bottom_gather := 0.0
var _finish_frame := -1
var _finish_age := -1.0
var _rise_seconds := -1.0
var flight_stats: Dictionary = {}
# Supported departure plan: COM tracks (world) and pitch about _outbound_axis,
# t = 0 at begin_group; the release state is the flight's launch state.
var _prep_x: Array = []
var _prep_y: Array = []
var _prep_z: Array = []
var _prep_spin: Array = []
var _prep_seconds := 0.0
var _prep_crouch := 0.0
var _prep_profile: Dictionary = {}
var _prep_stats: Dictionary = {}
# Plan-time window whose feed-forward is a ground/stock reaction (paired with
# that support) instead of assist: the departure and the head push-off.
var _support_from := -1.0
var _support_to := -1.0
var _support_body: Object = null
var _support_point := Vector3.ZERO
var _support_normal := Vector3.UP
# Real head impact and the visual squash/strain of the cube about its crown.
var _impact_armed := false
var _impact_clock := -1.0
var _impact_velocity := 0.0
var _arrival_velocity := Vector3.ZERO
var _squash_depth := .0
var _squash_at_attach := .0
var _squash := .0
var _splay := .0
var _twin := 0.0
var _return_lead := RETURN_LEAD
# The head push lasts at least RETURN_PUSH; a faster (fallback) return pushes
# longer so the stock's support can carry it inside its friction cone.
var _push_seconds := RETURN_PUSH
# Return flight: the planned horizontal drift brake and vertical lift.
var _return_drift_brake := 0.0
var _return_lift := 0.0
# Outbound: seconds from the first assisted brake/flare tick to the last.
var _assist_span := 0.0
var _rechecked := false
var _restart_angles: Array = []
# The legs' whip/overshoot angles at the attach (the return starts there).
var _return_start_angles: Array = []
# An interrupted leap that reached the stock pushes off it bare (no cargo).
var _bare_push := false
var _elevation_guess := deg_to_rad(55.0)
static var _args: PackedStringArray = []
static var profile_stats := false

func setup(owner: RigidBody3D) -> void:
	worker = owner
	if _args.is_empty():
		_args = OS.get_cmdline_user_args()
		# Per-tick controller statistics are a profiling aid only.
		profile_stats = profile_stats or _args.has("--head-stunt-profile") or _args.has("--head-leap-stats")

func active() -> bool:
	return state in ["prepare", "outbound", "contact", "return", "landing"]

func airborne_pose() -> bool:
	return state in ["outbound", "contact", "return"]

## Eye target for the face system: the real contact point while gathering and
## diving onto it; once the head has landed (a few frames before the kick) the
## landing spot under the launch place, through the return and touchdown.
func gaze_target() -> Variant:
	var landed := state=="contact" and (_impact_clock>=WHIP_SECONDS*.5 or (not _impact_armed and _contact_age>=.03))
	if state in ["prepare","outbound","contact"] and not landed and is_instance_valid(part):
		return part.global_transform*contact_local
	if landed or state in ["return","landing"]:
		return _home.origin-_home.basis.y.normalized()*worker.ride_height
	return null

## Expression cue for the face system (read-only; the face owner wires it):
## &"focus" through the gather, &"impact" for 0.15 s after the head lands,
## &"strain" while a heavy load is held on the head before the kick, &"phew"
## through a heavy/crew landing's held crouch, else &"".
func face_cue() -> StringName:
	match state:
		"prepare": return &"focus"
		"contact": return &"impact" if _impact_clock>=0.0 and _impact_clock<.15 else &""
		"return":
			if _return_lead>RETURN_LEAD+.001 and elapsed<_return_lead: return &"strain"
			return &"impact" if _impact_clock>=0.0 and _impact_clock<.15 else &""
		"landing":
			if _absorb_profile()==CREW_ABSORB and _impact_age>=0.0 and _impact_age<_absorb_bottom_time()+float(CREW_ABSORB.hold)+.25: return &"phew"
	return &""

## True while the eyes must stay open (no blink may START): the drive and the
## dive into the head impact, and the head push-off.
func blink_hold() -> bool:
	if state=="prepare": return elapsed>=_prep_crouch-.05
	if state=="outbound": return true
	if state=="return": return elapsed<_return_lead+_push_seconds+.05
	return false

## Pose root position budget: brisk only for the gather and the touchdown absorb;
## every other head-owned blend keeps the original .9 m/s.
func root_speed_limit() -> float:
	if state=="prepare": return BRISK_ROOT_SPEED
	var absorb: Dictionary = _absorb_profile()
	if state=="landing" and _impact_age>=0.0 and _impact_age<_absorb_bottom_time()+float(absorb.hold)+.1: return BRISK_ROOT_SPEED
	return .9

static func begin_group(source: RigidBody3D, members: Array) -> String:
	if not is_instance_valid(source) or members.is_empty(): return "Reserved physical stock unavailable"
	# Compact .28/.12 depot displays cannot be expanded at head contact without
	# stretching a rigid body. Keep its actual pose and reject that old storage
	# representation until the depot has a full-size physical storage place.
	if not source.global_basis.get_scale().is_equal_approx(Vector3.ONE):
		return "Head pickup needs full-size physical stock; compact depot display remains in its original place"
	if is_instance_valid(source.carrier): return "Physical stock is already held"
	if source.linear_velocity.length() > .3 or source.angular_velocity.length() > .3:
		return "Wait for the original stock to settle before head pickup"
	var bounds: AABB = StockBounds.bounds(source)
	if bounds.size.length_squared() < .0001: return "Physical stock has no complete contact geometry"
	# Contacts are placed along the stock's OWN horizontal axes (round 4): the
	# same layout turned to any heading gets the same contacts.
	var axis := 0 if bounds.size.x >= bounds.size.z else 2
	if members.size() > 1 and absf(bounds.size.x-bounds.size.z) < .02:
		# A square face has no long axis: share contacts along the crew's own
		# side-by-side spacing instead of a float tie (which crossed paths).
		var spread: Vector3 = (members[members.size()-1].global_position-members[0].global_position).slide(Vector3.UP)
		axis = 0 if absf(spread.dot(source.global_basis.x.normalized())) >= absf(spread.dot(source.global_basis.z.normalized())) else 2
	if members.size() > 1 and bounds.size[axis] < 1.18:
		return "This heavy stock needs a wider supported head contact face"
	for member: Node in members:
		# A failed landing can leave the temporary flight torso in use while
		# the original capsule is obstructed. Preserve that original shape:
		# another jump must not capture the temporary torso as its new default.
		if not member.head_leap.active():
			member.head_leap._restore_collision_when_safe()
			if member.head_leap._needs_collision_restore:
				return "Clear the original Wako body before another head-first jump"
		var back: Variant=member.back_tool if "back_tool" in member else null
		if back and (back.busy() or back.recovering()): return "Wait for the original foot/back tool transfer to settle before head pickup"
		if back and is_instance_valid(member.equipped_tool):
			if member.tool_foot_occupied(): return "Physically stow the original foot tool before the head-first jump"
			if not back.attached_tools().has(member.equipped_tool): return "Original tool has not reached genuine back custody"
			var keepouts: Array=back.local_keepouts()
			if keepouts.is_empty() or keepouts.any(func(item:Dictionary)->bool:return item.get("body")!=member.equipped_tool or not item.get("transform") is Transform3D or not item.get("box") is AABB):
				return "Secured original back tool has no complete measured body keepouts"
		if not member.head_leap._capture_mesh_roof(): return "The original Wako skin has no evaluated rigid head roof"
		if member.head_leap.active() or not member.on_ground or not member._pose.evaluated_valid:
			return "Wako need supported footing before their head-first jump"
		if not member._pose.evaluated_grounded.any(func(value: bool) -> bool: return value):
			return "Wako need a genuine planted launch sole"
		if member.linear_velocity.length() > .6: return "Wako are settling their launch footing"
	for index in members.size():
		var controller: RefCounted = members[index].head_leap
		controller._prepare(source, members, bounds, axis, index)
	members[0].head_leap._saved_source_layer=source.collision_layer
	# A query-only layer exposes the SAME frozen native stock shapes to a precise
	# head ray. No helper or world body has this bit in its physical collision mask.
	source.collision_layer |= CONTACT_QUERY_BIT
	var alternative_planned := false
	for member: Node in members:
		var controller: RefCounted = member.head_leap
		var face_reason: String = controller._observe_contact_face()
		# A solo approach can hit a curved rim or an open gap. Reuse the
		# existing bounded native-face/full-arc alternatives before giving up.
		if not face_reason.is_empty() and members.size()==1:
			face_reason=controller._plan_outbound_alternatives(face_reason)
			alternative_planned=face_reason.is_empty()
		if not face_reason.is_empty():
			for other: Node in members: other.head_leap.clear_before_launch()
			return face_reason
	var blocker: String = "" if alternative_planned else members[0].head_leap._plan_outbound()
	if not blocker.is_empty():
		for other: Node in members: other.head_leap.clear_before_launch()
		return blocker
	for member: Node in members:
		member.stop_navigation()
		# The supported departure owns the native body from here: the flight
		# torso replaces the capsule at the standing cube, the angular locks are
		# released and the planted feet carry the crouch, lunge and drive.
		member.action = ""
		member.action_progress = 0.0
		member._grounded_heading_handoff = false
		member._animation.pause()
		member._tool.visible = false
		source.add_collision_exception_with(member)
		member.head_leap._save_native_settings()
		member.head_leap._support_body = member._ground_body
		member.head_leap._support_point = member._ground_point
		member.head_leap._support_normal = member.ground_normal
	return ""

func _capture_mesh_roof() -> bool:
	if not _roof_samples.is_empty(): return true
	var mesh: MeshInstance3D=worker._skin_mesh
	var sk: Skeleton3D=worker._skeleton
	if not mesh or not mesh.skin or not sk: return false
	var root:=sk.find_bone("Bone")
	var triangles: Array[Vector3]=[]
	var roof_vertices: Array[Vector3]=[]
	_head_height=-INF
	for surface in mesh.mesh.get_surface_count():
		var arrays:=mesh.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array=arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array=arrays[Mesh.ARRAY_WEIGHTS]
		var indices: PackedInt32Array=arrays[Mesh.ARRAY_INDEX]
		if indices.is_empty():
			for index in vertices.size(): indices.append(index)
		var stride:=bones.size()/vertices.size()
		var points: Array[Vector3]=[]
		for index in vertices.size():
			var point:=Vector3.ZERO
			var root_weight:=.0
			for influence in stride:
				var weight:=weights[index*stride+influence]
				if weight<=.000001: continue
				var bind:=bones[index*stride+influence]
				var bone:=mesh.skin.get_bind_bone(bind)
				if bone<0: bone=sk.find_bone(mesh.skin.get_bind_name(bind))
				if bone!=root: continue
				point+=mesh.skin.get_bind_pose(bind)*vertices[index]*weight
				root_weight+=weight
			points.append(point if root_weight>.9999 else Vector3.INF)
			if root_weight>.9999:
				_head_height=maxf(_head_height,point.y)
				roof_vertices.append(point)
		for triangle in indices.size()/3:
			var a:=points[indices[triangle*3]]
			var b:=points[indices[triangle*3+1]]
			var c:=points[indices[triangle*3+2]]
			if not a.is_finite() or not b.is_finite() or not c.is_finite(): continue
			if absf((b-a).cross(c-a).normalized().y)>.95: triangles.append((a+b+c)/3.0)
	if not is_finite(_head_height) or absf(_head_height-worker.HEAD_OFFSET)>.01:
		print("HEAD_ROOF_BAD_HEIGHT ",_head_height," samples=",triangles.size())
		return false
	var roofs:=roof_vertices.filter(func(point: Vector3)->bool:return point.y>=_head_height-.015)
	if roofs.is_empty():
		print("HEAD_ROOF_NO_TRIANGLES height=",_head_height," candidates=",triangles)
		return false
	_head_touch_local=roof_vertices[0]
	for point: Vector3 in roof_vertices:
		if point.y>_head_touch_local.y+.000001 or (absf(point.y-_head_touch_local.y)<.000001 and Vector2(point.x,point.z).length_squared()<Vector2(_head_touch_local.x,_head_touch_local.z).length_squared()): _head_touch_local=point
	_roof_samples.append(_head_touch_local)
	# The faceted original roof is curved: its triangle centroids are below
	# its crown. Contact samples are actual weighted vertices on those indexed
	# triangles, including the genuine crown that first touches the material.
	for desired: Vector2 in [Vector2.ZERO,Vector2(-.25,-.25),Vector2(-.25,.25),Vector2(.25,-.25),Vector2(.25,.25)]:
		var best: Vector3=roofs[0]
		for point: Vector3 in roofs:
			if Vector2(point.x,point.z).distance_squared_to(desired)<Vector2(best.x,best.z).distance_squared_to(desired): best=point
		if not _roof_samples.has(best): _roof_samples.append(best)
	print("HEAD_ROOF_ORIGINAL height=",_head_height," touch=",_head_touch_local," vertices=",_roof_samples)
	return not _roof_samples.is_empty()

func _prepare(source: RigidBody3D, members: Array, bounds: AABB, axis: int, index: int) -> void:
	part = source
	crew = members.duplicate()
	state = "prepare"
	_impact_age = -1.0
	for side in 2: _stunt_grounded[side] = worker._pose.evaluated_grounded[side]
	reason = ""
	elapsed = 0.0
	contacted = false
	_abort_requested = false
	_return_started = false
	_native_settings_saved = false
	_planning_return = false
	_settled = 0.0
	_snapshot_ready = false
	_bones.clear()
	_restart_leg_points.clear()
	_restart_angles.clear()
	_restart_ankles.clear()
	_stunt_clearance_rows = 0
	_impact_speed = 0.0
	_absorb_depth = 0.0
	_finish_frame = -1
	_finish_age = -1.0
	_contact_age = -1.0
	_bare_retry = 0.0
	_bare_waiting = false
	_bare_wait_age = 0.0
	_dive_blocked = false
	_release_on_touchdown = false
	_plan_tier = ""
	_impact_armed = false
	_impact_clock = -1.0
	_impact_velocity = 0.0
	_squash_depth = 0.0
	_squash_at_attach = 0.0
	_squash = 0.0
	_support_from = -1.0
	_support_to = -1.0
	_return_lead = RETURN_LEAD
	_push_seconds = RETURN_PUSH
	_rechecked = false
	_return_start_angles.clear()
	_bare_push = false
	_preplan = {}
	_preplanned = {}
	_twin = float(members.find(worker)) if members.size()>1 else 0.0
	flight_stats = {"source":source.part_id if "part_id" in source else str(source.name),"crew":members.size()}
	_stock_bounds = bounds
	_capture_gun_head_constituents()
	_source_start = source.global_transform
	_home = worker.global_transform
	_stunt_forward = (worker.global_basis.inverse()*(-worker._model.global_basis.z)).normalized()
	_pin_points.clear()
	_pin_active = false
	_pin_release_time = -1.0
	_pin_release_pose.clear()
	_launch_leg_pose.clear()
	_capture_rest_geometry()
	_hold_root_local = _rest_root_local
	_root_local = _rest_root_local
	# The retained original tool can be on a toe or a genuinely caught back
	# holder. Clearance captures its actual body pose, never an assumed anchor.
	_tool_local = worker.global_transform.affine_inverse() * (worker.equipped_tool.global_transform if is_instance_valid(worker.equipped_tool) else worker.tool_anchor.global_transform)
	_tool_bounds=StockBounds.bounds(worker.equipped_tool) if is_instance_valid(worker.equipped_tool) else AABB()
	_capture_holder_bounds()
	contact_normal=Vector3.UP
	var stock_axis: Vector3 = source.global_basis.x if axis==0 else source.global_basis.z
	_crew_axis=stock_axis.slide(Vector3.UP).normalized() if stock_axis.slide(Vector3.UP).length_squared()>.0001 else (Vector3.RIGHT if axis==0 else Vector3.BACK)
	var approach := Vector3.ZERO
	for member: Node in members: approach+=member.global_position
	approach/=members.size()
	var local_approach: Vector3 = source.global_transform.affine_inverse()*approach
	var point := bounds.get_center()
	point.y=bounds.end.y
	for lateral in [0,2]:
		var margin: float=minf(.38,bounds.size[lateral]*.45)
		if members.size()>1 and lateral==axis: margin=maxf(margin,.49+.03)
		point[lateral]=clampf(local_approach[lateral],bounds.position[lateral]+margin,bounds.end[lateral]-margin)
	if members.size()>1:
		# Member order along the crew's own spacing (leader first), whichever
		# way the stock's axis points.
		var spread: Vector3 = members[members.size()-1].global_position-members[0].global_position
		var sign := 1.0 if spread.dot(stock_axis)>=0.0 else -1.0
		point[axis]+=sign*(float(index)-float(members.size()-1)*.5)*.98
	contact_local=point

func _observe_contact_face() -> String:
	var point: Vector3 = part.global_transform*contact_local
	var depth: float=(part.global_transform*_stock_bounds).size.y+.4
	var query := PhysicsRayQueryParameters3D.create(point+contact_normal*.2,point-contact_normal*depth,CONTACT_QUERY_BIT)
	var hit := worker.get_world_3d().direct_space_state.intersect_ray(query)
	var args:=_args
	var original_wheel_probe: bool="--easy-island-removed-wheel-probe" in args and part.part_id=="stock_3" and worker.current_job_id=="salvage:stock_3"
	var original_gun_probe: bool="--easy-island-gun-controls" in args and part.part_id=="stock_16" and part.kind=="gun" and worker.current_job_id.begins_with("build:")
	if (original_wheel_probe or original_gun_probe) and (hit.is_empty() or hit.collider!=part or hit.normal.dot(Vector3.UP)<.8):
		_observe_original_contact_refusal(point,query,hit)
	if hit.is_empty() or hit.collider!=part: return "The actual stock has no native head contact face at this support point"
	if hit.normal.dot(Vector3.UP)<.8: return "The original stock has no sufficiently level head contact face"
	contact_local=part.global_transform.affine_inverse()*hit.position
	contact_normal=hit.normal
	return ""

func _observe_original_contact_refusal(point: Vector3,query: PhysicsRayQueryParameters3D,hit: Dictionary) -> void:
	# Capture the native ray which actually failed; no extra ray or admission.
	var key:=str(part.get_rid())
	var sample:=int(_contact_face_probe_rows.get(key,0))
	if sample>=8: return
	_contact_face_probe_rows[key]=sample+1
	var collider: Variant=hit.get("collider")
	var native:=PhysicsServer3D.body_get_direct_state(part.get_rid())
	var world_bounds: AABB=part.global_transform*_stock_bounds
	print("HEAD_CONTACT_FACE_REFUSAL ",JSON.stringify({"scope":"read-only actual failed native head-face ray",
		"worker":worker.worker_id,"job":worker.current_job_id,"tick":Engine.get_physics_frames(),"sample":sample+1,
		"source":part.part_id,"source_rid":str(part.get_rid()),"source_pose":part.encode_transform(part.global_transform),
		"source_native":part.encode_transform(native.transform) if native else null,
		"worker_pose":part.encode_transform(worker.global_transform),"saved_launch":part.encode_transform(_home),
		"source_world_bounds":[part.encode_vector(world_bounds.position),part.encode_vector(world_bounds.size)],
		"contact_local":part.encode_vector(contact_local),"proposal":part.encode_vector(point),
		"ray_from":part.encode_vector(query.from),"ray_to":part.encode_vector(query.to),"collision_mask":query.collision_mask,
		"hit_body":str(collider.get_path()) if is_instance_valid(collider) and collider is Node else str(collider),
		"hit_rid":str(hit.get("rid")),"hit_shape":hit.get("shape"),"same_source":collider==part,
		"hit_point":part.encode_vector(hit.position) if hit.has("position") else null,
		"hit_normal":part.encode_vector(hit.normal) if hit.has("normal") else null,
		"normal_up":hit.normal.dot(Vector3.UP) if hit.has("normal") else null,
		"unchanged_minimum_normal_up":.8,"roof_height":_head_height,"roof_samples":_roof_samples.size()}))

func _contact_destination(gap := CONTACT_GAP) -> Transform3D:
	var y := -contact_normal
	var home_cube := _home.basis*_rest_root_local.basis
	# A cooperative flip uses the same WORLD axis along both contact points.
	# Different visual launch yaws must not rotate the two roofs along different
	# axes and sweep the common stock through the partner's native head.
	# Head-first: the half-turn axis is lateral to the travel toward the stock
	# (UP x d), shared as one world axis by a crew. A pi turn about +/-axis is
	# the same pose; the signed branch is chosen explicitly by the planner.
	var flip_axis := _flip_axis().slide(contact_normal).normalized()
	if flip_axis.length_squared()<.5: flip_axis=home_cube.x.slide(contact_normal).normalized()
	var flipped := Basis(flip_axis,PI)*home_cube
	var x := flipped.x.slide(y).normalized()
	if x.length_squared() < .5: x = Vector3.RIGHT.slide(y).normalized()
	var cube := Basis(x,y,x.cross(y)).orthonormalized()
	var body := cube * _root_local.basis.orthonormalized().inverse()
	var point: Vector3 = part.global_transform * contact_local + contact_normal * gap
	return Transform3D(body, point - cube*_head_touch_local - body*_root_local.origin)

func _travel_direction() -> Vector3:
	# Horizontal launch-to-contact direction; a crew shares the mean direction.
	var total := Vector3.ZERO
	for member: Node in crew:
		if not is_instance_valid(member): continue
		var leap: RefCounted=member.head_leap
		if not is_instance_valid(leap.part): continue
		var direction: Vector3=(leap.part.global_transform*leap.contact_local-leap._home.origin).slide(Vector3.UP)
		if direction.length_squared()<.0025: direction=(leap._home.basis*leap._stunt_forward).slide(Vector3.UP)
		if direction.length_squared()>.000001: total+=direction.normalized()
	if total.length_squared()<.000001: total=(_home.basis*_stunt_forward).slide(Vector3.UP)
	return total.normalized() if total.length_squared()>.000001 else Vector3.FORWARD

func _flip_axis() -> Vector3:
	# A positive turn about UP x d tips the head toward d: a head-first front
	# flip. A crew keeps its common world axis, signed to agree with that turn.
	var lateral := Vector3.UP.cross(_travel_direction()).normalized()
	if crew.size()>1: return _crew_axis if _crew_axis.dot(lateral)>=0.0 else -_crew_axis
	return lateral

func _native_com_local() -> Vector3:
	var native:=PhysicsServer3D.body_get_direct_state(worker.get_rid())
	return native.center_of_mass_local if native else worker.center_of_mass

func _loaded_com_local(source: RigidBody3D, share: float, frame: Variant = null) -> Vector3:
	# Predict the native COM after the same source's share joins this body
	# (the helper's attached-payload rule), so the return is planned before
	# custody changes. _follow still tracks the actual COM it then measures.
	var com := _native_com_local()
	if share<=0.0 or not is_instance_valid(source): return com
	var body: Transform3D = frame if frame is Transform3D else worker.global_transform
	var cargo: Vector3=body.affine_inverse()*LoadGeometry.world_centre(source)
	return (com*worker.mass+cargo*share)/(worker.mass+share)

func _plan_outbound() -> String:
	var blocker := _plan_outbound_at_contact()
	if blocker.is_empty() or crew.size()!=1: return blocker
	return _plan_outbound_alternatives(blocker)

func _plan_outbound_alternatives(blocker: String) -> String:
	# Keep a clear original approach. A solo roof beside taller finite stock
	# can need another real contact within the same supported face margins.
	var first: Vector3=part.global_transform*contact_local
	var normal := contact_normal
	var world_bounds: AABB=part.global_transform*_stock_bounds
	var centre := world_bounds.get_center()
	centre.y=world_bounds.end.y
	for candidate: Vector3 in [centre,centre*2.0-first]:
		if candidate.is_equal_approx(first): continue
		candidate.y=world_bounds.end.y
		for lateral in [0,2]:
			var margin: float=minf(.38,world_bounds.size[lateral]*.45)
			candidate[lateral]=clampf(candidate[lateral],world_bounds.position[lateral]+margin,world_bounds.end[lateral]-margin)
		contact_local=part.global_transform.affine_inverse()*candidate
		contact_normal=normal
		if not _observe_contact_face().is_empty(): continue
		blocker=_plan_outbound_at_contact()
		if blocker.is_empty(): return ""
	# The small open horn's central tapered bell is not a supporting plane
	# for the complete head: its level driver stands above that facet. After
	# preserving the ordinary candidates, ray the real top driver connector.
	# Native face observation and the unchanged whole-source arc guard still
	# decide admission; the source retains its actual pose, shape and mass.
	if part.kind==Catalogue.SignalHorn.KIND:
		var top: Dictionary=Catalogue.socket(part.definition,"top")
		if not top.is_empty():
			var previous_contact:=contact_local
			var previous_normal:=contact_normal
			var driver: Vector3=part.global_transform*top.pos
			driver.y=world_bounds.end.y
			contact_local=part.global_transform.affine_inverse()*driver
			contact_normal=Vector3.UP
			if _observe_contact_face().is_empty(): blocker=_plan_outbound_at_contact()
			else:
				contact_local=previous_contact
				contact_normal=previous_normal
	return blocker

func _plan_outbound_at_contact() -> String:
	for member: Node in crew:
		var controller: RefCounted=member.head_leap
		controller._outbound_axis=controller._flip_axis()
		# The flight carries the cube at its standing root: the gather, lean and
		# push-off are real native motion of the same body, not root offsets.
		controller._root_local=controller._rest_root_local
		controller._fit_stunt_tuck()
		controller._com_local=controller._departure_com_local()
		controller._destination=controller._contact_destination()
		if controller._home.origin.distance_to(controller._destination.origin)>6.0: return "Actual stock is beyond a bounded head-first jump; clear a closer launch place"
	# Brisk flare arcs first, higher apexes next (screens between launch and
	# stock), the original quintic timings last; a cramped launch place uses
	# the short lunge.
	var tiers: Array=[[SOLO_OUTBOUND if crew.size()==1 else CREW_OUTBOUND,"brisk"],[LONG_OUTBOUND,"long"],[LEGACY_OUTBOUND,"legacy"]]
	var profiles: Array=[_prep_profile_for(false),SHORT_PREP,STAND_PREP]
	var leader: RefCounted=crew[0].head_leap
	for tier: Array in tiers:
		# The brisk candidates share their path: once two are blocked by the
		# world, the rest of that tier is skipped for the higher tiers.
		var blocked := 0
		for candidate: Array in tier[0]:
			if blocked>=2: break
			for profile: Dictionary in profiles:
				var shaped := true
				var seconds := -1.0
				for member: Node in crew:
					var controller: RefCounted=member.head_leap
					# A crew shares one duration: followers fit the leader's flight time.
					if not controller._plan_departure(candidate,str(tier[1]),profile,seconds):
						shaped=false
						arc_failure=controller.arc_failure
						if _args.has("--head-leap-debug"): print("HEAD_LEAP_CANDIDATE_REFUSED ",tier[1]," ",candidate," ",arc_failure)
						break
					if seconds<0.0:
						seconds=controller._flight_seconds
						# The leader's own cheap checks first: no follower fit is paid
						# for an arc whose lunge or head path is already blocked.
						if crew.size()>1 and not (controller._prep_clear() and controller._head_path_clear()):
							shaped=false
							arc_failure=controller.arc_failure
							break
				if shaped:
					if crew.all(func(member: Node) -> bool: return member.head_leap._prep_clear() and member.head_leap._arc_quick()) \
						and crew.all(func(member: Node) -> bool: return member.head_leap._arc_clear(false,0.0,false,true)):
						for member: Node in crew: member.head_leap._record_plan("outbound")
						return ""
					for member: Node in crew:
						if not member.head_leap.arc_failure.is_empty(): arc_failure=member.head_leap.arc_failure
					if _args.has("--head-leap-debug"): print("HEAD_LEAP_ARC_REFUSED ",tier[1]," ",candidate," ",profile.release_pitch," ",arc_failure)
				# A shorter or upright departure only helps a lunge or an early
				# (near-launch) obstruction; later failures do not depend on it.
				if not (arc_failure.begins_with("push-off") or leader._failure_time()<.3): break
			if tier[1]=="brisk" and _world_blocked(arc_failure): blocked += 1
		if _args.has("--head-leap-debug"): print("HEAD_LEAP_TIER_REFUSED ",tier[1]," ",arc_failure)
	return "No clear whole-body/head-first arc; "+arc_failure

static func _world_blocked(failure: String) -> bool:
	return failure.contains("obstruction") or failure.contains("intersects")

func _failure_time() -> float:
	# The flight time a refusal names ("... at 0.123s"), else infinity.
	var at := arc_failure.rfind(" at ")
	if at<0: return INF
	var text := arc_failure.substr(at+4).get_slice("s",0)
	return float(text) if text.is_valid_float() else INF

func _stock_moved() -> bool:
	# The admitted arc was checked against the stock at its launch pose. Any
	# displacement past the original .08 m/.08 rad gate, or a stock that is
	# being knocked right now, invalidates that check.
	if not is_instance_valid(part): return true
	if is_instance_valid(part.carrier): return false
	return part.global_position.distance_to(_source_start.origin) > .08 \
		or part.global_basis.orthonormalized().get_rotation_quaternion().angle_to(_source_start.basis.orthonormalized().get_rotation_quaternion()) > .08 \
		or _velocity(part).length() > .5

func _small_stock_timing() -> bool:
	return crew.size()==1 and is_instance_valid(part) and part.mass<=35.0 and maxf(_stock_bounds.size.x,maxf(_stock_bounds.size.y,_stock_bounds.size.z))<=1.2

static func _quintic(p0: float, v0: float, a0: float, p1: float, v1: float, a1: float, seconds: float) -> PackedFloat64Array:
	# Position/velocity/acceleration at both ends, time-power coefficients.
	var t := maxf(seconds,.0001)
	var h := p1-(p0+v0*t+.5*a0*t*t)
	var dv := v1-(v0+a0*t)
	var da := a1-a0
	return PackedFloat64Array([p0,v0,.5*a0,(10.0*h-4.0*dv*t+.5*da*t*t)/(t*t*t),(-15.0*h+7.0*dv*t-da*t*t)/(t*t*t*t),(6.0*h-3.0*dv*t+.5*da*t*t)/(t*t*t*t*t)])

static func _quintic_at(c: PackedFloat64Array, time: float, order: int) -> float:
	if c.size()!=6: return 0.0
	if order==0: return c[0]+time*(c[1]+time*(c[2]+time*(c[3]+time*(c[4]+time*c[5]))))
	if order==1: return c[1]+time*(2.0*c[2]+time*(3.0*c[3]+time*(4.0*c[4]+time*5.0*c[5])))
	return 2.0*c[2]+time*(6.0*c[3]+time*(12.0*c[4]+time*20.0*c[5]))

static func _assist_minimising_velocity(p0: float, a0: float, p1: float, v1: float, a1: float, seconds: float) -> float:
	# The quintic acceleration is linear in its start velocity: a(t)=A(t)+B(t)v0.
	# Least squares on the horizontal assist gives the most ballistic push-off.
	var base := _quintic(p0,0.0,a0,p1,v1,a1,seconds)
	var unit := _quintic(0.0,1.0,0.0,0.0,0.0,0.0,seconds)
	var numerator := .0
	var denominator := .0
	for step in 41:
		var time := seconds*float(step)/40.0
		var b := _quintic_at(unit,time,2)
		numerator += _quintic_at(base,time,2)*b
		denominator += b*b
	return -numerator/denominator if denominator>.000001 else 0.0

# --- Plan tracks: [t0, t1, c0..c5] polynomial segments in (t - t0). ---------
static func _segment(t0: float, t1: float, coefficients: PackedFloat64Array) -> PackedFloat64Array:
	var segment := PackedFloat64Array([t0,t1,0.0,0.0,0.0,0.0,0.0,0.0])
	for index in mini(coefficients.size(),6): segment[2+index]=coefficients[index]
	return segment

static func _track_at(track: Array, time: float, order: int) -> float:
	if track.is_empty(): return 0.0
	var segment: PackedFloat64Array = track[track.size()-1]
	for candidate: PackedFloat64Array in track:
		if time<candidate[1]:
			segment=candidate
			break
	var x := clampf(time-segment[0],0.0,segment[1]-segment[0])
	if order==0: return segment[2]+x*(segment[3]+x*(segment[4]+x*(segment[5]+x*(segment[6]+x*segment[7]))))
	if order==1: return segment[3]+x*(2.0*segment[4]+x*(3.0*segment[5]+x*(4.0*segment[6]+x*5.0*segment[7])))
	return 2.0*segment[4]+x*(6.0*segment[5]+x*(12.0*segment[6]+x*20.0*segment[7]))

static func _track_end(track: Array) -> float:
	return track[track.size()-1][1] if not track.is_empty() else 0.0

static func _jerk_track(t0: float, p: float, v: float, a: float, steps: Array) -> Array:
	# Piecewise constant jerk: each step [duration, end acceleration] ramps the
	# acceleration linearly. Position/velocity/acceleration stay continuous.
	var track: Array = []
	for step: Array in steps:
		var duration := float(step[0])
		if duration<=.000001: continue
		var jerk := (float(step[1])-a)/duration
		track.append(_segment(t0,t0+duration,PackedFloat64Array([p,v,a*.5,jerk/6.0])))
		p += v*duration+a*duration*duration*.5+jerk*duration*duration*duration/6.0
		v += a*duration+jerk*duration*duration*.5
		a = float(step[1])
		t0 += duration
	return track

static func _scaled_track(track: Array, offset: float, scale: float) -> Array:
	var result: Array = []
	for segment: PackedFloat64Array in track:
		var scaled := segment.duplicate()
		for index in range(2,8): scaled[index]*=scale
		scaled[2]+=offset
		result.append(scaled)
	return result

static func _shift_track(track: Array, offset: float) -> Array:
	var result: Array = []
	for segment: PackedFloat64Array in track:
		var shifted := segment.duplicate()
		shifted[0]+=offset
		shifted[1]+=offset
		result.append(shifted)
	return result

# --- Supported departure -------------------------------------------------------
func _prep_profile_for(short := false) -> Dictionary:
	if short: return SHORT_PREP
	return CREW_PREP if crew.size()>1 else PREP

func _departure_com_local() -> Vector3:
	# The native COM after the flight torso replaces the capsule at the rest
	# root (the helper weights its 22 kg at the Collision node).
	var com := _native_com_local()
	if _needs_collision_restore: return com
	var collision: CollisionShape3D=worker.get_node("Collision")
	return com+(_rest_root_local.origin-collision.position)*(22.0/maxf(worker.mass,1.0))

static func _heel_axis(arm: Vector3) -> Vector3:
	var axis := arm.cross(Vector3.UP)
	if axis.length_squared()<.000001: return Vector3.ZERO
	axis = axis.normalized()
	if axis.cross(arm).y<0.0: axis = -axis
	return axis

func _release_reach(side: int, basis: Basis, direction: Vector3) -> float:
	# Largest ball-to-hip distance along `direction` the leg reaches with the
	# release knee, the heel peeled about the planted ball of the foot.
	var ball: Vector3 = _home*_rest_toe[side]
	var arm: Vector3 = _home.basis*(_rest_ankle[side]-_rest_toe[side])
	var axis := _heel_axis(arm)
	var hip_mid: Vector3 = _rest_root_local*((_hip_root[0]+_hip_root[1])*.5)
	var offset: Vector3 = basis*(_rest_root_local*_hip_root[side]-hip_mid)
	var mid_ball: Vector3 = _home*((_rest_toe[0]+_rest_toe[1])*.5)
	var upper := _leg_upper[side]
	var lower := _leg_lower[side]
	var wanted := sqrt(upper*upper+lower*lower+2.0*upper*lower*cos(RELEASE_KNEE))
	var low := .3
	var high := 1.3
	for iteration in 16:
		var middle := (low+high)*.5
		var hip := mid_ball+direction*middle+offset
		var near := INF
		for step in 9:
			var lift := MAXIMUM_PIN_POINT*float(step)/8.0
			near = minf(near,hip.distance_to(ball+(arm.rotated(axis,lift) if axis!=Vector3.ZERO else arm)))
		if near<=wanted: low=middle
		else: high=middle
	return low

func _release_pose(profile: Dictionary, elevation: float) -> Transform3D:
	# The push-off leaves with the ball-to-hip line close to the launch vector
	# (beta from vertical) and the cube pitched toward the stock.
	var beta := clampf(PI*.5-elevation-float(profile.beta_lead),float(profile.beta_min),float(profile.beta_max))
	var d := _travel_direction()
	var basis := (Basis(_outbound_axis,float(profile.release_pitch))*_home.basis).orthonormalized()
	var direction := (Vector3.UP*cos(beta)+d*sin(beta)).normalized()
	var reach := minf(_release_reach(0,basis,direction),_release_reach(1,basis,direction))
	var mid_ball: Vector3 = _home*((_rest_toe[0]+_rest_toe[1])*.5)
	var hip_mid: Vector3 = _rest_root_local*((_hip_root[0]+_hip_root[1])*.5)
	_prep_stats.beta_deg = rad_to_deg(beta)
	_prep_stats.reach = reach
	return Transform3D(basis,mid_ball+direction*reach-basis*hip_mid)

func _plan_departure(candidate: Array, tier: String, profile: Dictionary, seconds: float) -> bool:
	arc_failure = ""
	_prep_profile = profile
	_prep_stats = {}
	if _hip_root.size()!=2 or _rest_toe.size()!=2:
		arc_failure="no captured leg geometry for a supported push-off"
		return false
	# The release pose leans along the launch it produces: start from the last
	# planned elevation and refine once only when it moved.
	var elevation := _elevation_guess
	for attempt in 2:
		_flight_start = _release_pose(profile,elevation)
		_configure_rotation(_outbound_axis)
		var planned: bool
		if tier=="legacy": planned=_plan_flight(float(candidate[0]),float(candidate[1]),false,"legacy")
		else: planned=_plan_outbound_flight(float(candidate[0]),float(candidate[1]),tier,seconds,float(profile.release_spin))
		if not planned: return false
		var launched := atan2(_launch_velocity.y,Vector2(_launch_velocity.x,_launch_velocity.z).length())
		var settled := absf(launched-elevation)<deg_to_rad(1.0)
		elevation = launched
		_elevation_guess = launched
		if settled: break
	return _plan_prepare(profile)

func _plan_prepare(profile: Dictionary) -> bool:
	# Crouch-and-lunge then drive: two quintic segments per axis from standing
	# rest to the release state (position, velocity, free-fall acceleration).
	var tick := 1.0/120.0
	var crouch := snappedf(float(profile.crouch),tick)
	var drive := snappedf(float(profile.drive),tick)
	var start: Vector3 = _home*_com_local
	var release: Vector3 = _flight_start*_com_local
	var velocity := _launch_velocity
	if velocity.length()<.5:
		arc_failure="push-off too slow for a supported drive"
		return false
	# A faster push-off needs a longer planted drive (about 2.5 g on average).
	var length := clampf(velocity.length_squared()/(2.0*25.0),float(profile.drive_length)*.8,.34)
	drive = snappedf(clampf(2.2*length/velocity.length(),float(profile.drive),.22),tick)
	var bottom := release-velocity.normalized()*length
	# The crouch ends already driving along the launch vector (the lowest
	# point passes just before), so the last ticks push along the flight.
	var drive_direction := velocity.normalized()
	var bottom_velocity := drive_direction*float(profile.bottom_speed)
	var bottom_acceleration := drive_direction*float(profile.bottom_accel)
	# A crew first stands still through its nod (the follower a few frames
	# longer), descends, and holds the bottom together before the drive.
	var still := snappedf(float(profile.get("nod",0.0))+(CREW_CROUCH_LAG*_twin if crew.size()>1 else 0.0),tick)
	var hold := snappedf(float(profile.get("hold",0.0)),tick)
	var descent := crouch-still-hold
	if descent<.15:
		arc_failure="push-off crouch too short"
		return false
	var hold_speed := .12
	var pre_bottom := bottom-drive_direction*(hold*(hold_speed+float(profile.bottom_speed))*.5)
	var tracks: Array = [[],[],[]]
	for axis in 3:
		var end_acceleration := -GRAVITY if axis==1 else 0.0
		if still>0.0: tracks[axis].append(_segment(0.0,still,PackedFloat64Array([start[axis]])))
		if hold>0.0:
			tracks[axis].append(_segment(still,still+descent,_quintic(start[axis],0.0,0.0,pre_bottom[axis],drive_direction[axis]*hold_speed,0.0,descent)))
			tracks[axis].append(_segment(still+descent,crouch,_quintic(pre_bottom[axis],drive_direction[axis]*hold_speed,0.0,bottom[axis],bottom_velocity[axis],bottom_acceleration[axis],hold)))
		else:
			tracks[axis].append(_segment(still,crouch,_quintic(start[axis],0.0,0.0,bottom[axis],bottom_velocity[axis],bottom_acceleration[axis],descent)))
		tracks[axis].append(_segment(crouch,crouch+drive,_quintic(bottom[axis],bottom_velocity[axis],bottom_acceleration[axis],release[axis],velocity[axis],end_acceleration,drive)))
	_prep_x=tracks[0]
	_prep_y=tracks[1]
	_prep_z=tracks[2]
	var pitch := float(profile.release_pitch)
	var spin := _launch_spin.dot(_outbound_axis)
	_prep_spin=[]
	if still>0.0: _prep_spin.append(_segment(0.0,still,PackedFloat64Array([0.0])))
	_prep_spin.append(_segment(still,crouch,_quintic(0.0,0.0,0.0,float(profile.bottom_pitch),float(profile.bottom_spin),0.0,crouch-still)))
	_prep_spin.append(_segment(crouch,crouch+drive,_quintic(float(profile.bottom_pitch),float(profile.bottom_spin),0.0,pitch,spin,_spin_angle(0.0,2),drive)))
	_prep_seconds=crouch+drive
	_prep_crouch=crouch
	# Plausibility of the planted push: per-tick speed change, the friction-cone
	# ground reaction and the assist for any excess, the pinned legs' reach.
	var worst_support := .0
	var worst_assist := .0
	var worst_step := .0
	var direction_error := .0
	var previous := Vector3.ZERO
	var steps := roundi(_prep_seconds/tick)
	for step in range(steps+1):
		var time := tick*step
		var check_reach := step%2==0 or step==steps
		var feed := _prep_com(time,2)+Vector3.UP*GRAVITY
		var reaction := _support_reaction(feed,Vector3.UP)
		worst_support = maxf(worst_support,reaction.length())
		worst_assist = maxf(worst_assist,(feed-reaction).length())
		var speed := _prep_com(time,1)
		if step>0: worst_step = maxf(worst_step,speed.distance_to(previous))
		previous = speed
		if time>_prep_seconds-.07 and speed.length()>.3: direction_error = maxf(direction_error,rad_to_deg(speed.angle_to(velocity)))
		if not check_reach: continue
		var body := _prep_body(time)
		for side in 2:
			if not _leg_reaches(side,body,time):
				arc_failure="planted leg cannot follow the push-off at %.3fs" % time
				return false
	_prep_stats.merge({"seconds":_prep_seconds,"crouch":crouch,"peak_support_g":worst_support/GRAVITY,"peak_assist":worst_assist,
		"peak_step":worst_step,"direction_error_deg":direction_error,"release_speed":velocity.length(),"release_pitch_deg":rad_to_deg(pitch),
		"release_spin":spin,"bottom_drop":start.y-bottom.y},true)
	if worst_assist>MAXIMUM_ACCELERATION*FORCE_BUDGET:
		arc_failure="push-off needs %.1fm/s² assist beyond the planted reaction" % worst_assist
		return false
	if worst_step>.6:
		arc_failure="push-off changes speed %.2fm/s in one tick" % worst_step
		return false
	return true

func _leg_reaches(side: int, body: Transform3D, time: float) -> bool:
	# The planted ball of the foot stays within the leg's reach (knee 3-150
	# degrees) for some heel lift up to the push's peel.
	var hip: Vector3 = body*(_rest_root_local*_hip_root[side])
	var ball: Vector3 = _home*_rest_toe[side]
	var arm: Vector3 = _home.basis*(_rest_ankle[side]-_rest_toe[side])
	var axis := _heel_axis(arm)
	var upper := _leg_upper[side]
	var lower := _leg_lower[side]
	var longest := sqrt(upper*upper+lower*lower+2.0*upper*lower*cos(deg_to_rad(3.0)))
	var shortest := sqrt(upper*upper+lower*lower+2.0*upper*lower*cos(deg_to_rad(150.0)))
	var floor_lift := _heel_floor(time)
	for step in 9:
		var lift := lerpf(floor_lift,MAXIMUM_PIN_POINT,float(step)/8.0)
		var distance := hip.distance_to(ball+(arm.rotated(axis,lift) if axis!=Vector3.ZERO else arm))
		if distance<=longest and distance>=shortest: return true
	return false

func _heel_floor(time: float) -> float:
	return HEEL_PEEL*smoothstep(_prep_crouch,_prep_seconds,time)

func _prep_com(time: float, order: int) -> Vector3:
	return Vector3(_track_at(_prep_x,time,order),_track_at(_prep_y,time,order),_track_at(_prep_z,time,order))

func _prep_body(time: float) -> Transform3D:
	var basis := (Basis(_outbound_axis,_track_at(_prep_spin,time,0))*_home.basis).orthonormalized()
	return Transform3D(basis,_prep_com(time,0)-basis*_com_local)

func _prep_clear() -> bool:
	# The lunging cube and drive stay clear of the world and the stock.
	var query := PhysicsShapeQueryParameters3D.new()
	var torso := BoxShape3D.new()
	torso.size = Vector3(.76,_head_height*2.0,.76)
	query.shape = torso
	query.collision_mask = 1|CONTACT_QUERY_BIT
	var exclusions: Array[RID]=worker.query_exclusions()
	for member: Node in crew: exclusions.append(member.get_rid())
	query.exclude = exclusions
	var space := worker.get_world_3d().direct_space_state
	var steps := ceili(_prep_seconds*30.0)
	for step in range(1,steps+1):
		var time := _prep_seconds*float(step)/steps
		query.transform = _prep_body(time)*_rest_root_local
		if not space.intersect_shape(query,1).is_empty():
			arc_failure="push-off lunge obstruction at %.3fs" % time
			return false
	return true

static func _support_reaction(feed: Vector3, normal: Vector3) -> Vector3:
	# What planted feet (or a supported head) can push: no pull, inside the
	# friction cone, bounded; the rest of the feed-forward stays assist.
	var pressing := maxf(feed.dot(normal),0.0)
	var tangential := (feed-normal*feed.dot(normal)).limit_length(pressing*FRICTION)
	return (normal*pressing+tangential).limit_length(SUPPORT_MAXIMUM)

# --- Outbound flight: free fall, one flare, free fall into the head impact ------
static func _flare_hold(speed: float, entry: float, plateau: float) -> float:
	# Hold of the assist trapezoid (0 -> plateau -> 0) that turns free-fall
	# speed `speed` into the downward entry speed `entry`.
	return (-entry-speed+2.0*GRAVITY*FLARE_RAMP-plateau*FLARE_RAMP)/(plateau-GRAVITY)

static func _flare_drop(speed: float, hold: float, plateau: float) -> float:
	var duration := 2.0*FLARE_RAMP+hold
	return speed*duration-.5*GRAVITY*duration*duration+.5*plateau*(hold+FLARE_RAMP)*(hold+2.0*FLARE_RAMP)

static func _flare_vertical(y0: float, y1: float, launch_speed: float, impact: float, plateau := FLARE_PLATEAU) -> Dictionary:
	# The last free fall into the roof, short enough to keep a real flare.
	var fall := minf(IMPACT_FALL,.45*impact*impact/(2.0*GRAVITY))
	var entry_squared := impact*impact-2.0*GRAVITY*fall
	if entry_squared<0.0 or launch_speed<=0.0: return {}
	var entry := sqrt(entry_squared)
	var finish := y1+fall
	var end_height := func(start: float) -> float:
		var speed := launch_speed-GRAVITY*start
		var hold := _flare_hold(speed,entry,plateau)
		if hold<0.0: return INF
		return y0+launch_speed*start-.5*GRAVITY*start*start+_flare_drop(speed,hold,plateau)
	# Earliest start: the flare is only its ramps.
	var low := maxf((launch_speed-(-entry+2.0*GRAVITY*FLARE_RAMP-plateau*FLARE_RAMP))/GRAVITY,0.0)
	if end_height.call(low)<finish: return {}
	var high := low+3.0
	for iteration in 28:
		var middle := (low+high)*.5
		if end_height.call(middle)>finish: low=middle
		else: high=middle
	var start := (low+high)*.5
	var speed := launch_speed-GRAVITY*start
	var hold := maxf(_flare_hold(speed,entry,plateau),0.0)
	var last := (impact-entry)/GRAVITY
	var track: Array=[_segment(0.0,start,PackedFloat64Array([y0,launch_speed,-.5*GRAVITY]))]
	track.append_array(_jerk_track(start,y0+launch_speed*start-.5*GRAVITY*start*start,speed,-GRAVITY,[[FLARE_RAMP,plateau-GRAVITY],[hold,plateau-GRAVITY],[FLARE_RAMP,-GRAVITY],[last,-GRAVITY]]))
	return {"track":track,"seconds":_track_end(track),"flare":start,"flare_end":start+2.0*FLARE_RAMP+hold,"speed":launch_speed,"entry":entry}

static func _flare_seconds(y0: float, y1: float, launch_speed: float, impact: float, plateau := FLARE_PLATEAU) -> float:
	var plan := _flare_vertical(y0,y1,launch_speed,impact,plateau)
	return float(plan.seconds) if not plan.is_empty() else -1.0

static func _flare_for_seconds(y0: float, y1: float, seconds: float, impact: float, plateau := FLARE_PLATEAU) -> Dictionary:
	# A crew follower fits the leader's duration with its own push-off speed
	# (the flight time grows monotonically with the launch speed).
	# Regula falsi (Illinois) on the monotonic duration: ~8 evaluations.
	var low := .3
	var high := MAXIMUM_SPEED
	var f_low := _flare_seconds(y0,y1,low,impact,plateau)-seconds
	var f_high := _flare_seconds(y0,y1,high,impact,plateau)-seconds
	if f_low+seconds<0.0:
		# The slowest launches cannot reach the roof with this flare: bisect
		# up to the first feasible speed.
		for iteration in 20:
			var middle := (low+high)*.5
			var time := _flare_seconds(y0,y1,middle,impact,plateau)
			if time<0.0: low=middle
			else: high=middle
		low=high
		high=MAXIMUM_SPEED
		f_low=_flare_seconds(y0,y1,low,impact,plateau)-seconds
	if f_low>0.0 or f_high<0.0: return {}
	var side := 0
	var speed := low
	for iteration in 30:
		speed = (low*f_high-high*f_low)/(f_high-f_low)
		var value := _flare_seconds(y0,y1,speed,impact,plateau)-seconds
		if absf(value)<.0002: break
		if value<0.0:
			low=speed
			f_low=value
			if side==-1: f_high*=.5
			side=-1
		else:
			high=speed
			f_high=value
			if side==1: f_low*=.5
			side=1
	var plan := _flare_vertical(y0,y1,speed,impact,plateau)
	return plan if not plan.is_empty() and absf(float(plan.seconds)-seconds)<.0006 else {}

func _plan_outbound_flight(apex: float, impact: float, tier: String, seconds := -1.0, release_spin := 2.5) -> bool:
	# P0-2 (round 3): the COM rises and falls freely; ONE late flare (legs
	# opening) slows the descent to a short free fall into a real head impact.
	arc_failure = ""
	_plan_tier = tier
	_plan_candidate = [apex,impact]
	_support_from = -1.0
	_support_to = -1.0
	var start: Vector3 = _flight_start*_com_local
	var end: Vector3 = _destination*_com_local
	# The flare and the horizontal brake share the force budget: a hard flare
	# forces a long, early horizontal brake, a gentler one a longer flare.
	# Keep the plateau whose assisted span (brake and flare together) is the
	# shortest: the most free-fall flight for this candidate.
	var best: Dictionary = {}
	var best_span := INF
	var failure := ""
	for plateau: float in [FLARE_PLATEAU,14.6,12.8,11.0]:
		if not _plan_outbound_flare(apex,impact,seconds,plateau,start,end):
			failure = arc_failure
			continue
		var span := _assist_span
		if span<best_span-.004:
			best_span = span
			best = {"_flight_seconds":_flight_seconds,"_track_x":_track_x,"_track_y":_track_y,"_track_z":_track_z,"_launch_velocity":_launch_velocity,
				"_touchdown_velocity":_touchdown_velocity,"_beat_brake":_beat_brake,"_assist_span":_assist_span,"_beat_assist":_beat_assist}
	if best.is_empty():
		arc_failure = failure
		return false
	_restore_plan(best)
	arc_failure = ""
	return _plan_outbound_spin(_flight_seconds,release_spin,tier)

func _plan_outbound_flare(apex: float, impact: float, seconds: float, plateau: float, start: Vector3, end: Vector3) -> bool:
	# A gentler flare starts earlier and leaves more of the force budget for
	# the horizontal brake (far or high stock).
	var vertical: Dictionary = _flare_for_seconds(start.y,end.y,seconds,impact,plateau) if seconds>0.0 else _flare_vertical(start.y,end.y,sqrt(2.0*GRAVITY*apex),impact,plateau)
	if vertical.is_empty():
		arc_failure="no free-fall arc with one flare reaches the roof (apex %.2f)" % apex
		return false
	var total: float = vertical.seconds
	_flight_seconds = total
	_track_y = vertical.track
	# Horizontal: the push-off speed coasts, then one trapezoid brake (as late
	# as the shared force budget allows next to the flare) leaves a small drift
	# toward the contact and a level final drop.
	var across := Vector3(end.x-start.x,0.0,end.z-start.z)
	var distance := across.length()
	var direction := across/distance if distance>.000001 else Vector3.ZERO
	var drift := minf(ARRIVAL_DRIFT,distance/maxf(total,.1))
	var finish := total-HORIZONTAL_LEAD
	var budget := MAXIMUM_ACCELERATION*FORCE_BUDGET*.97
	var horizontal: Array = []
	var speed := distance/maxf(total,.1)
	var found := false
	for lead: float in [0.0,.05,.1,.15,.2,.26,.32,.4,.5,.6,.75,.9,1.1]:
		var begin := maxf(float(vertical.flare)-lead,.08)
		var window := finish-begin
		if window<=2.0*HORIZONTAL_RAMP+.02: continue
		speed = (distance-drift*(HORIZONTAL_LEAD+window*.5))/(begin+window*.5)
		if speed<=drift+.02:
			# Short travel: one constant drift, no horizontal brake at all.
			speed = distance/total
			horizontal = [_segment(0.0,total,PackedFloat64Array([0.0,speed]))]
		else:
			var deceleration := (speed-drift)/(window-HORIZONTAL_RAMP)
			horizontal = _jerk_track(0.0,0.0,speed,0.0,[[begin,0.0],[HORIZONTAL_RAMP,-deceleration],[window-2.0*HORIZONTAL_RAMP,-deceleration],[HORIZONTAL_RAMP,0.0],[HORIZONTAL_LEAD,0.0]])
		var worst := 0.0
		var joints: Array[float] = []
		for segment: PackedFloat64Array in horizontal+_track_y: joints.append_array([segment[0],segment[1]])
		for time: float in joints: worst=maxf(worst,Vector2(_track_at(horizontal,time,2),_track_at(_track_y,time,2)+GRAVITY).length())
		if worst<=budget:
			found=true
			break
	if not found:
		arc_failure="horizontal brake exceeds the force budget at apex %.2f" % apex
		return false
	_track_x = _scaled_track(horizontal,start.x,direction.x)
	_track_z = _scaled_track(horizontal,start.z,direction.z)
	_launch_velocity = direction*speed+Vector3.UP*float(vertical.speed)
	if _launch_velocity.length()>MAXIMUM_SPEED:
		arc_failure="push-off %.2fm/s exceeds %.1fm/s" % [_launch_velocity.length(),MAXIMUM_SPEED]
		return false
	_touchdown_velocity = direction*_track_at(horizontal,total,1)+Vector3.DOWN*impact
	_beat_brake = vertical.flare
	var brake_begin: float = total if horizontal.size()==1 else horizontal[0][1]
	var brake_end: float = total if horizontal.size()==1 else finish
	_assist_span = maxf(float(vertical.flare_end),brake_end)-minf(float(vertical.flare),brake_begin)
	_beat_assist = minf(float(vertical.flare),brake_begin)
	return true

func _impact_spin() -> float:
	return IMPACT_SPIN if _small_stock_timing() and _plan_tier=="brisk" else WIDE_IMPACT_SPIN

func _spin_track(total: float, release: float, peak: float, open: float) -> Array:
	# Release coast, tuck spin-up, tucked coast, one brake while the legs open,
	# a slower final turn into the impact. Accelerations are trapezoids.
	var up := (peak-release)/(TUCK_SPIN_SECONDS-SPIN_RAMP)
	var brake := maxf(peak-_impact_spin(),0.0)
	var window := maxf(brake/SPIN_BRAKE+SPIN_RAMP,2.0*SPIN_RAMP+.001)
	var deceleration := brake/(window-SPIN_RAMP)
	var coast := open-TUCK_SPIN_START-TUCK_SPIN_SECONDS
	var final := total-open-window
	if coast<0.0 or final<0.0: return []
	return _jerk_track(0.0,0.0,release,0.0,[[TUCK_SPIN_START,0.0],[SPIN_RAMP,up],[TUCK_SPIN_SECONDS-2.0*SPIN_RAMP,up],[SPIN_RAMP,0.0],
		[coast,0.0],[SPIN_RAMP,-deceleration],[window-2.0*SPIN_RAMP,-deceleration],[SPIN_RAMP,0.0],[final,0.0]])

func _plan_outbound_spin(total: float, release: float, tier := "brisk") -> bool:
	# P0-3 (round 3): the push-off's spin, faster in the tuck, slower once the
	# legs open; the half-turn completes exactly at the head impact.
	# Round 4: the spin brakes as the legs open with the arrival brake, the
	# opened shape then turns slower into the impact. A short flight (tall
	# stock) that cannot finish its half-turn that way brakes the spin later.
	var leg_open := clampf(_beat_assist-OPEN_ANTICIPATION,TRAIL_SECONDS+.05+TUCK_IN_SECONDS,total-PLANT_HOLD-.12)
	var failure := ""
	for policy in 2:
		var lead := leg_open if policy==0 else total-OPEN_LEAD
		if policy==1 and lead<=leg_open+.01: break
		if _plan_outbound_spin_at(total,release,tier,lead): return true
		failure = arc_failure
	arc_failure = failure
	return false

func _plan_outbound_spin_at(total: float, release: float, tier: String, lead: float) -> bool:
	var opening := func(peak: float) -> float: return clampf(lead,TUCK_SPIN_START+TUCK_SPIN_SECONDS,total-(maxf(peak-_impact_spin(),0.0)/SPIN_BRAKE+SPIN_RAMP)-.02)
	var fastest := _spin_track(total,release,MAXIMUM_SPIN,opening.call(MAXIMUM_SPIN))
	if fastest.is_empty() or _track_at(fastest,total,0)<_rotation_angle:
		arc_failure="half-turn needs more than %.1frad/s in %.2fs" % [MAXIMUM_SPIN,total]
		return false
	var low := minf(_impact_spin(),release)
	var slowest := _spin_track(total,release,low,opening.call(low))
	if not slowest.is_empty() and _track_at(slowest,total,0)>_rotation_angle:
		arc_failure="%.2fs flight overturns the half-turn even untucked" % total
		return false
	var high := MAXIMUM_SPIN
	var track := fastest
	for iteration in 18:
		var middle := (low+high)*.5
		var trial := _spin_track(total,release,middle,opening.call(middle))
		if trial.is_empty() or _track_at(trial,total,0)<_rotation_angle: low=middle
		else:
			high=middle
			track=trial
	var peak := high
	if peak<(MINIMUM_SPIN if tier=="brisk" else 1.5):
		arc_failure="tucked spin %.2frad/s below %.1f" % [peak,MINIMUM_SPIN]
		return false
	var up := absf(peak-release)/(TUCK_SPIN_SECONDS-SPIN_RAMP)
	if up>MAXIMUM_ANGULAR_ACCELERATION*ANGULAR_BUDGET:
		arc_failure="tuck spin-up %.1frad/s² over the angular budget" % up
		return false
	_track_spin = track
	_launch_spin = _rotation_axis*release
	_beat_open = opening.call(peak)
	_beat_spin_end = total
	return true

# --- Return: supported head push, then a near-ballistic flight -----------------
func _landing_destination(short: float) -> Transform3D:
	# The touchdown is planned short of the launch place by the distance its
	# drift rolls out; the landing hold then brings the body home.
	var back := (_home.origin-_flight_start.origin).slide(Vector3.UP)
	var direction := back.normalized() if back.length_squared()>.0001 else Vector3.ZERO
	return Transform3D(_home.basis,_home.origin-direction*short)

func _kick_seconds() -> float:
	return RETURN_LEAD+_push_seconds-.012

func _fit_push(velocity: Vector3) -> float:
	# Shortest push (>= RETURN_PUSH) whose peak feed the support can carry with
	# at most 80% of the force budget left as assist.
	for push: float in [RETURN_PUSH,.12,.13,.14,.16,.18,.20,.22]:
		var feed := velocity/(push-PUSH_RAMP)+contact_normal*GRAVITY
		if (feed-_support_reaction(feed,contact_normal)).length()<=MAXIMUM_ACCELERATION*FORCE_BUDGET*.8: return push
	return .22

func _push_tracks(start: Vector3, velocity: Vector3) -> Array:
	# Hold through the leg snap, then a trapezoid push to `velocity` paired with
	# the stock's support (gravity stays supported until the head leaves).
	var lead := _return_lead
	var peak := velocity/(_push_seconds-PUSH_RAMP)
	var tracks: Array = []
	for axis in 3:
		var track: Array=[_segment(0.0,lead,PackedFloat64Array([start[axis]]))]
		track.append_array(_jerk_track(lead,start[axis],0.0,0.0,[[PUSH_RAMP,peak[axis]],[_push_seconds-2.0*PUSH_RAMP,peak[axis]],[PUSH_RAMP,0.0]]))
		tracks.append(track)
	return tracks

func _return_heavy() -> bool:
	# A shared or large load (not an empty bare push) takes the heavy timing.
	return not _bare_push and (crew.size()>1 or not _small_stock_timing())

func _plan_return_flight(apex: float, lift: float, tier: String) -> bool:
	# Round 4: the head push-off is a supported reaction spread over the leg
	# kick; the flight is then ballistic under g - lift with a bounded drift
	# brake, landing short of home by its rolled-out drift.
	arc_failure = ""
	_plan_tier = tier
	_plan_candidate = [apex,lift]
	var heavy := _return_heavy()
	_return_lead = RETURN_LEAD+(STRAIN_SECONDS if heavy else 0.0)
	_push_seconds = HEAVY_PUSH if heavy else RETURN_PUSH
	var start: Vector3 = _flight_start*_com_local
	var short := .06
	var velocity := Vector3.ZERO
	var gravity := GRAVITY-lift
	var seconds := .7
	var drift := 0.0
	var brake := DRIFT_DECEL
	var direction := Vector3.ZERO
	var end := Vector3.ZERO
	for iteration in 5:
		_destination = _landing_destination(short)
		end = _destination*_com_local
		var guess := velocity.normalized() if velocity.length()>.1 else ((end-start).slide(Vector3.UP).normalized()*cos(deg_to_rad(60.0))+Vector3.UP*sin(deg_to_rad(60.0)))
		var push_end := start+guess*(velocity.length()*_push_seconds*.5)
		var rise := end.y+apex-push_end.y
		if rise<=.05:
			arc_failure="return apex below the push-off"
			return false
		var vertical := sqrt(2.0*gravity*rise)
		seconds = (vertical+sqrt(2.0*gravity*apex))/gravity
		var across := (end-push_end).slide(Vector3.UP)
		var distance := across.length()
		direction = across/distance if distance>.000001 else Vector3.ZERO
		brake = DRIFT_DECEL
		var horizontal := distance/seconds+.5*brake*seconds
		drift = horizontal-brake*seconds
		if drift<.1:
			# Short travel: bleed less, keep a small drift.
			drift = minf(.1,distance/seconds)
			horizontal = 2.0*distance/seconds-drift
			brake = (horizontal-drift)/seconds
		velocity = direction*horizontal+Vector3.UP*vertical
		short = clampf(drift*drift/(2.0*LAND_BRAKE),0.0,LAND_SHORT)
		_push_seconds = maxf(_fit_push(velocity),HEAVY_PUSH if heavy else RETURN_PUSH)
	if tier=="brisk" and not heavy and not _bare_push:
		# The loaded solo arc stays in the empty outbound's height class.
		var home_com: Vector3 = _home*_native_com_local()
		if end.y+apex-home_com.y>SOLO_APEX_ABOVE_HOME+.001:
			arc_failure="loaded return apex %.2fm above the home COM (cap %.2f)" % [end.y+apex-home_com.y,SOLO_APEX_ABOVE_HOME]
			return false
	if velocity.length()>MAXIMUM_SPEED:
		arc_failure="return push-off %.2fm/s exceeds %.1fm/s" % [velocity.length(),MAXIMUM_SPEED]
		return false
	var per_tick := velocity.length()/(_push_seconds-PUSH_RAMP)/120.0
	if per_tick>.6:
		arc_failure="return push changes speed %.2fm/s in one tick" % per_tick
		return false
	var tracks := _push_tracks(start,velocity)
	var takeoff := _return_lead+_push_seconds
	var push_end := Vector3(_track_at(tracks[0],takeoff,0),_track_at(tracks[1],takeoff,0),_track_at(tracks[2],takeoff,0))
	var decel_vector := -direction*brake+Vector3.UP*(-gravity)
	_return_drift_brake = brake
	_return_lift = lift
	for axis in 3:
		tracks[axis].append(_segment(takeoff,takeoff+seconds,PackedFloat64Array([push_end[axis],velocity[axis],.5*decel_vector[axis]])))
	_track_x = tracks[0]
	_track_y = tracks[1]
	_track_z = tracks[2]
	_flight_seconds = takeoff+seconds
	_support_from = 0.0
	_support_to = takeoff
	_launch_velocity = velocity
	_touchdown_velocity = direction*drift+Vector3.DOWN*sqrt(2.0*gravity*apex)
	if _args.has("--head-leap-debug"): print("HEAD_LEAP_RETURN_PLAN T=%.2f apex=%.2f v0=%s lift=%.2f drift=%.2f brake=%.2f short=%.3f push=%.3f" % [seconds,apex,velocity,lift,drift,brake,short,_push_seconds])
	# Rewind about the outbound axis: the push and kick start the turn, the
	# flight carries it round to a gentle landing spin.
	var crew_timing := heavy
	# The push-off spin scales with the rewind it must cover in the flight.
	var omega0 := clampf((1.15 if crew_timing else 1.3)*_rotation_angle/seconds,2.5,CREW_RETURN_SPIN+1.0 if crew_timing else MAXIMUM_SPIN)
	var omega1 := minf(LANDING_SPIN,.4*_rotation_angle/seconds)
	var ramp_angle := .5*omega0*_push_seconds
	var spin := _quintic(ramp_angle,omega0,0.0,_rotation_angle,omega1,0.0,seconds)
	var spin_peak := omega0/(_push_seconds-PUSH_RAMP)
	_track_spin = [_segment(0.0,_return_lead,PackedFloat64Array([0.0]))]
	_track_spin.append_array(_jerk_track(_return_lead,0.0,0.0,0.0,[[PUSH_RAMP,spin_peak],[_push_seconds-2.0*PUSH_RAMP,spin_peak],[PUSH_RAMP,0.0]]))
	_track_spin.append(_segment(takeoff,takeoff+seconds,spin))
	_launch_spin = _rotation_axis*omega0
	var peak_alpha := .0
	for step in 49:
		var time := seconds*float(step)/48.0
		peak_alpha = maxf(peak_alpha,absf(_quintic_at(spin,time,2)))
		if _quintic_at(spin,time,1)<-.25:
			arc_failure="rewind would reverse at %.3fs" % time
			return false
	if peak_alpha>MAXIMUM_ANGULAR_ACCELERATION*ANGULAR_BUDGET:
		arc_failure="angular budget %.1frad/s² on the %.2fs rewind" % [peak_alpha,seconds]
		return false
	_beat_brake = takeoff
	_beat_open = takeoff+seconds*.55
	_beat_spin_end = _flight_seconds
	return true

func _prepend_return_push(velocity: Vector3) -> void:
	# Legacy return: the original quintic flight is entered through the same
	# supported head push (its tracks start at the push-off's end).
	var start: Vector3 = _flight_start*_com_local
	var tracks := _push_tracks(start,velocity)
	var takeoff := _return_lead+_push_seconds
	_track_x = tracks[0]+_shift_track(_track_x,takeoff)
	_track_y = tracks[1]+_shift_track(_track_y,takeoff)
	_track_z = tracks[2]+_shift_track(_track_z,takeoff)
	var omega0 := _spin_angle(0.0,1)
	var spin_peak := omega0/(_push_seconds-PUSH_RAMP)
	var spin_prefix: Array=[_segment(0.0,_return_lead,PackedFloat64Array([0.0]))]
	spin_prefix.append_array(_jerk_track(_return_lead,0.0,0.0,0.0,[[PUSH_RAMP,spin_peak],[_push_seconds-2.0*PUSH_RAMP,spin_peak],[PUSH_RAMP,0.0]]))
	var offset := .5*omega0*_push_seconds
	var shifted := _shift_track(_track_spin,takeoff)
	for segment: PackedFloat64Array in shifted: segment[2]+=offset
	_track_spin = spin_prefix+shifted
	_flight_seconds += takeoff
	_support_from = 0.0
	_support_to = takeoff
	_beat_brake += takeoff
	_beat_open += takeoff
	_beat_spin_end += takeoff

func _plan_flight(seconds: float, apex: float, returning: bool, tier: String, start_velocity: Variant = null, bare_recovery := true, start_com: Variant = null) -> bool:
	# Original quintic plan: the legacy fallback tier and every interrupted
	# (bare) recovery. A fixed start velocity receives no new impulse.
	arc_failure = ""
	_flight_seconds = seconds
	_plan_tier = tier
	_plan_candidate = [seconds,apex]
	var fixed := start_velocity is Vector3
	var bare := fixed and bare_recovery
	_support_from = -1.0
	_support_to = -1.0
	var horizontal_seconds := seconds*(.9 if not returning else 1.0)
	var start: Vector3 = start_com if start_com is Vector3 else _flight_start*_com_local
	var end: Vector3 = _destination*_com_local
	# An interrupted recovery beside the stock first lifts its head clear
	# (net upward start) while it already turns back toward upright.
	var beside_stock := bare and is_instance_valid(part) and (part.global_transform*_stock_bounds).grow(.3).has_point(_head_point())
	var start_acceleration := (5.0 if beside_stock else 0.0) if bare else -GRAVITY
	_touchdown_velocity = Vector3.UP*(LEGACY_TOUCHDOWN if returning else 0.0)
	var end_acceleration := -GRAVITY if returning else 0.0
	var velocity := Vector3.ZERO
	if fixed:
		velocity = start_velocity
	else:
		velocity.x = _assist_minimising_velocity(start.x,0.0,end.x,0.0,0.0,horizontal_seconds)
		velocity.z = _assist_minimising_velocity(start.z,0.0,end.z,0.0,0.0,horizontal_seconds)
		# Vertical push-off reaches the requested apex above the higher end.
		var ceiling := maxf(start.y,end.y)+apex
		var low := 0.0
		var high := MAXIMUM_SPEED
		for iteration in 24:
			var middle := (low+high)*.5
			var trial := _quintic(start.y,middle,start_acceleration,end.y,_touchdown_velocity.y,end_acceleration,seconds)
			var top := -INF
			for step in 33: top = maxf(top,_quintic_at(trial,seconds*float(step)/32.0,0))
			if top<ceiling: low=middle
			else: high=middle
		velocity.y = (low+high)*.5
		if velocity.length()>MAXIMUM_SPEED:
			arc_failure="push-off %.2fm/s exceeds %.1fm/s" % [velocity.length(),MAXIMUM_SPEED]
			return false
	_track_x = [_segment(0.0,horizontal_seconds,_quintic(start.x,velocity.x,0.0,end.x,0.0,0.0,horizontal_seconds))]
	_track_z = [_segment(0.0,horizontal_seconds,_quintic(start.z,velocity.z,0.0,end.z,0.0,0.0,horizontal_seconds))]
	_track_y = [_segment(0.0,seconds,_quintic(start.y,velocity.y,start_acceleration,end.y,_touchdown_velocity.y,end_acceleration,seconds))]
	_launch_velocity = velocity
	var spin_seconds := seconds*(.86 if not returning else (.9 if bare else 1.0))
	var angle := _rotation_angle
	var omega0 := .0
	var omega1 := .0
	var crew_timing := not _small_stock_timing()
	_track_spin = []
	var delay := .0
	var peak_alpha := .0
	if bare:
		omega0 = clampf(worker.angular_velocity.dot(_rotation_axis),-MAXIMUM_SPIN,MAXIMUM_SPIN)
		if beside_stock and omega0*angle<0.0:
			# The existing spin dives the head toward the stock while the
			# recovery turns back: brake it over a short lift first.
			delay = clampf(absf(omega0)/18.0,.06,.22)
			_track_spin.append(_segment(0.0,delay,PackedFloat64Array([0.0,omega0,-.5*omega0/delay])))
			peak_alpha = absf(omega0/delay)
			spin_seconds = seconds*.9-delay
			omega0 = 0.0
	elif returning:
		omega0 = minf(CREW_RETURN_SPIN if crew_timing else RETURN_SPIN,1.5*angle/spin_seconds)
		omega1 = minf(LANDING_SPIN,.4*angle/spin_seconds)
	else:
		omega0 = minf(4.0 if crew_timing else 5.5,1.6*angle/spin_seconds)
	var spin := _quintic(_track_at(_track_spin,delay,0) if delay>0.0 else 0.0,omega0,0.0,_rotation_angle,omega1,0.0,spin_seconds)
	_track_spin.append(_segment(delay,delay+spin_seconds,spin))
	_launch_spin = _rotation_axis*(omega0 if delay<=0.0 else _track_at(_track_spin,0.0,1))
	for step in 49:
		var time := spin_seconds*float(step)/48.0
		peak_alpha = maxf(peak_alpha,absf(_quintic_at(spin,time,2)))
		if _quintic_at(spin,time,1)<-.25 and not bare:
			arc_failure="half-turn would reverse at %.3fs" % time
			return false
	# An interrupted recovery may use more of the unchanged 24 rad/s² cap: its
	# landing settle tolerates tracking error that a precise head contact cannot.
	if peak_alpha>MAXIMUM_ANGULAR_ACCELERATION*(.95 if bare else ANGULAR_BUDGET):
		arc_failure="angular budget %.1frad/s² at %.2fs half-turn" % [peak_alpha,spin_seconds]
		return false
	_beat_brake = seconds*.62
	_beat_open = spin_seconds*.6+delay
	_beat_assist = _beat_open
	_beat_spin_end = spin_seconds+delay
	return true

func _record_plan(label: String) -> void:
	# Admission facts for the probe/report: the exact admitted plan.
	var worst := .0
	var low := 0
	var samples := ceili(_flight_seconds*120.0)
	var apex := -INF
	var free_fall := 0.0
	for step in range(samples+1):
		var time := _flight_seconds*float(step)/samples
		var need := (_planned_com(time,2)+Vector3.UP*GRAVITY).length()
		# A supported push is a ground/stock reaction, not assist.
		if _supported_at(time): need = (_planned_com(time,2)+Vector3.UP*GRAVITY-_support_reaction(_planned_com(time,2)+Vector3.UP*GRAVITY,Vector3.UP)).length()
		worst = maxf(worst,need)
		if need<.3*GRAVITY: low+=1
		if need<.15*GRAVITY: free_fall+=_flight_seconds/samples
		apex = maxf(apex,_planned_com(time,0).y)
	var peak_alpha := .0
	var peak_spin := .0
	for step in range(samples+1):
		var time := _flight_seconds*float(step)/samples
		peak_alpha=maxf(peak_alpha,absf(_spin_angle(time,2)))
		peak_spin=maxf(peak_spin,absf(_spin_angle(time,1)))
	flight_stats[label]={"tier":_plan_tier,"candidate":_plan_candidate,"seconds":_flight_seconds,"brake_start":_beat_brake,"spin_brake_start":_beat_open,"spin_end":_beat_spin_end,
		"push_off":_launch_velocity.length(),"push_off_velocity":[_launch_velocity.x,_launch_velocity.y,_launch_velocity.z],
		"launch_spin":_launch_spin.length(),"peak_spin":peak_spin,"turn_deg":rad_to_deg(_rotation_angle),"axis":[_rotation_axis.x,_rotation_axis.y,_rotation_axis.z],
		"apex_above_start_com":apex-(_flight_start*_com_local).y,"apex_above_end_com":apex-(_destination*_com_local).y,
		"worst_assist":worst,"admission":MAXIMUM_ACCELERATION*FORCE_BUDGET,"admission_margin":MAXIMUM_ACCELERATION*FORCE_BUDGET-worst,
		"low_assist_fraction":float(low)/float(samples+1),"free_fall_seconds":free_fall,"peak_alpha":peak_alpha,"alpha_admission":MAXIMUM_ANGULAR_ACCELERATION*ANGULAR_BUDGET,
		"touchdown_velocity":[_touchdown_velocity.x,_touchdown_velocity.y,_touchdown_velocity.z],"com_local":[_com_local.x,_com_local.y,_com_local.z],
		"tuck_capacity":_stunt_capacity,"splay_deg":rad_to_deg(_splay),"head_first":(_flight_start.basis.y.cross(_destination.origin-_flight_start.origin)).dot(_rotation_axis)>0.0 if label=="outbound" else null,
		"flare_start":_beat_brake if label=="outbound" else null,"support_window":[_support_from,_support_to],"departure":_prep_stats.duplicate() if label=="outbound" else null}

func capture_evaluated(sk: Skeleton3D) -> void:
	_capture_leg_bases(sk)
	_refresh_shared_anchor()
	if state in ["prepare","landing"]:
		for side in 2: _stunt_grounded[side] = worker._pose.evaluated_grounded[side]
	if state != "prepare": return
	_bones.clear()
	for bone in sk.get_bone_count(): _bones.append(sk.get_bone_pose(bone))
	# The last Pose-owned gather root: the push-off extension starts here.
	_hold_root_local = worker._pose.evaluated_worker.affine_inverse()*worker._pose.evaluated_root
	# The retained original tool can be on a toe or a genuinely caught back
	# holder. Clearance captures its actual body pose, never an assumed anchor.
	_tool_local = worker.global_transform.affine_inverse() * (worker.equipped_tool.global_transform if is_instance_valid(worker.equipped_tool) else worker.tool_anchor.global_transform)
	_stunt_forward = (worker.global_basis.inverse()*(-worker._model.global_basis.z)).normalized()
	_capture_holder_bounds()
	_snapshot_ready = true

func advance(delta: float) -> void:
	_watch_release()
	if not active(): return
	# One leader-owned release puts every cooperative body on the same tick.
	# A later helper callback in that tick must not advance only one arc.
	if state in ["outbound","return"] and _launch_frame==Engine.get_physics_frames(): return
	_advanced_frame = Engine.get_physics_frames()
	if not worker.is_available():
		abort("Head pickup interrupted by a native fall")
		_finish(false)
		return
	if not is_instance_valid(part) or not part.is_inside_tree():
		abort("Reserved physical stock removed during the head approach")
	elapsed += delta
	if _impact_clock>=0.0: _impact_clock += delta
	if state == "prepare":
		worker._update_ground(delta)
		_cancel_spring()
		_support_body = worker._ground_body
		_support_point = worker._ground_point
		_support_normal = worker.ground_normal if worker.on_ground else Vector3.UP
		if elapsed<_prep_crouch and (_abort_requested or not worker.on_ground):
			# Cancelled while still crouching: the same supported body stands
			# back up through the ordinary landing hold (no jump, no reset).
			if not _abort_requested: abort("Launch sole lost its native support")
			_stand_down()
			return
		# The planted feet carry the planned crouch, lunge and drive; once the
		# drive has begun the push completes and an abort recovers in the air.
		_follow_prep(minf(elapsed,_prep_seconds))
		if crew[0]==worker and not _rechecked and elapsed>=_prep_crouch-.05:
			# Last chance before the drive commits: the admitted arc is checked
			# again against the CURRENT world (its planned frames are cached, so
			# only the shape queries run); a blocked arc stands back up.
			_rechecked = true
			var started := Time.get_ticks_usec()
			# Same leg path as the admission: the launch legs are only known at
			# the release (the current crouch is not the extended push-off).
			var captured: Array = []
			for member: Node in crew:
				captured.append(member.head_leap._launch_leg_pose)
				member.head_leap._launch_leg_pose = []
			var clear: bool = not _stock_moved() and crew.all(func(member: Node) -> bool: return member.head_leap._prep_clear() and member.head_leap._arc_quick()) \
				and crew.all(func(member: Node) -> bool: return member.head_leap._arc_clear(false,0.0,false,true))
			for index in crew.size(): crew[index].head_leap._launch_leg_pose = captured[index]
			flight_stats.gather_recheck_ms = (Time.get_ticks_usec()-started)/1000.0
			if not clear:
				var blocker := arc_failure
				for member: Node in crew:
					if not member.head_leap.arc_failure.is_empty(): blocker = member.head_leap.arc_failure
				abort("The head-first arc became obstructed during the gather; standing back up: "+(blocker if not blocker.is_empty() else "the stock moved"))
				return
		if elapsed < _prep_seconds or crew[0]!=worker: return
		if not crew.all(func(member: Node) -> bool: return member.head_leap.state=="prepare" and member.head_leap.elapsed>=member.head_leap._prep_seconds-.0001): return
		for member: Node in crew:
			var controller: RefCounted=member.head_leap
			controller._release()
		return
	worker.on_ground = false
	worker.stance_valid = false
	worker.gait_speed = 0.0
	worker.turn_rate = 0.0
	if _abort_requested and state in ["outbound","contact"] and not _return_started:
		# Interrupted (round 4): never a mid-air reversal. While the stock is
		# where the arc was admitted and the rest of the dive is clear of the
		# CURRENT world, the dive continues to a real head landing on the stock
		# and the body pushes off it bare (a real head push, ballistic flight).
		# A knocked stock or a blocked dive continues ballistically instead:
		# attitude-only assist turns the body feet-down to land past/beside the
		# stock, or the fall (ragdoll) takes over.
		if crew[0]==worker:
			var moved := _stock_moved()
			if moved: _release_moved_stock()
			if state=="outbound" and not moved and not _dive_blocked and elapsed>=_bare_retry:
				_bare_retry = elapsed+.1
				if not crew.all(func(member: Node) -> bool: return member.head_leap._arc_clear(false,member.head_leap.elapsed)):
					_dive_blocked = true
			if state=="outbound" and (moved or _dive_blocked) and (elapsed>=_bare_retry or not _bare_waiting):
				if _begin_fall_recovery(): return
				_bare_retry = elapsed+1.0/60.0
			elif state=="contact":
				# The head has landed on the stock: once the impact has stopped it
				# (the legs' whip), push off bare like the loaded return.
				var landed := _contact_age>=.4 or (_impact_clock>=WHIP_SECONDS+CONTACT_PRESS and _velocity(worker).length()<.3 and worker.angular_velocity.length()<.8) \
					or (not _impact_armed and _contact_age>=.06 and _velocity(worker).length()<.3)
				if landed and _begin_bare_group_return(moved): return
		if _bare_waiting:
			# Unassisted free flight while a knocked stock clears the way: no
			# force or torque at all until a clear recovery exists (or the fall).
			return
	if state == "outbound":
		if not _abort_requested and _stock_moved():
			abort("The actual stock moved; head contact was not made")
			return
		_follow_plan(minf(elapsed,_flight_seconds))
		if crew[0]==worker and not _abort_requested and elapsed>=_flight_seconds-PREPLAN_LEAD and elapsed<_flight_seconds-.02:
			_preplan_step()
		# The fastest approach into the roof just before the touch (the native
		# contact may already have stopped the head on this last outbound tick).
		var falling := _velocity(worker)
		if elapsed<_flight_seconds-.1 or -falling.dot(contact_normal)>-_arrival_velocity.dot(contact_normal): _arrival_velocity = falling
		elif _impact_armed and _impact_clock<0.0 and -falling.dot(contact_normal)<.4*-_arrival_velocity.dot(contact_normal): _register_impact(-_arrival_velocity.dot(contact_normal))
		worker.action_progress = clampf(elapsed/_flight_seconds*.5,0.0,.5)
		# Even an interrupted dive lands on the stock for real while the stock
		# is still where the arc was admitted (the recovery starts from there).
		if not _impact_armed and _plan_tier in ["brisk","long"] and elapsed>=_flight_seconds-IMPACT_ARM and not _stock_moved():
			# The head lands on the stock for real: lift this body's exception
			# so the native contact stops it (custody still needs every gate).
			_impact_armed = true
			if _args.has("--head-leap-debug"): print("HEAD_LEAP_ARMED el=",elapsed," T=",_flight_seconds)
			if is_instance_valid(part): part.remove_collision_exception_with(worker)
		if elapsed >= _flight_seconds:
			state = "contact"
			elapsed = 0.0
			_contact_age = 0.0
	elif state == "contact":
		_contact_age = elapsed
		var destination := _contact_destination()
		if _impact_clock<0.0:
			var approach := -_velocity(worker).dot(contact_normal)
			var arrival := -_arrival_velocity.dot(contact_normal)
			if not _impact_armed or approach<.4*arrival or _contact_age>=IMPACT_WINDOW: _register_impact(arrival if _impact_armed else 0.0)
		if _impact_clock<0.0:
			# Falling into the stock: no braking assist; the real head contact
			# stops the body (Jolt resolves it), the hold takes over after.
			_follow(destination,_velocity(worker),Vector3.DOWN*GRAVITY,worker.angular_velocity,Vector3.ZERO,[FLIGHT_GAINS[0],0.0,FLIGHT_GAINS[2],0.0])
		else:
			_follow(_contact_destination(HOLD_GAP),Vector3.ZERO,Vector3.ZERO,Vector3.ZERO,Vector3.ZERO,HOLD_GAINS)
		contact_error = _head_point().distance_to(part.global_transform*contact_local+contact_normal*CONTACT_GAP)
		if elapsed > 1.6 and not contact_ready(): abort("Head approach missed the current physical stock face")
	elif state == "return":
		var time := minf(elapsed,_flight_seconds)
		_follow_plan(time,_support_from>=0.0 and time>=_support_from and time<_support_to)
		worker.action_progress = .5+.4*clampf(elapsed/_flight_seconds,0.0,1.0)
		if elapsed >= _flight_seconds:
			state = "landing"
			elapsed = 0.0
			flight_stats.touchdown_plan_velocity = _touchdown_velocity.y
			flight_stats.touchdown_actual_velocity = _velocity(worker).y
			flight_stats.touchdown_drift = _velocity(worker).slide(Vector3.UP).length()
			_seed_landing_release()
			worker.action=""
			worker._animation.play("wk_idle",.2)
	elif state == "landing":
		worker._update_ground(delta)
		if _release_on_touchdown and (worker.on_ground or elapsed>.3) and crew[0]==worker:
			_release_on_touchdown = false
			abort(reason)
		if _impact_age < .0 and worker.on_ground:
			_impact_age = .0
			_rise_seconds = -1.0
			# The touchdown is a real impact: its measured speed scales the absorb.
			_impact_speed = maxf(0.0,-(_velocity(worker)-worker.ground_velocity).y)
			_absorb_depth = clampf(.035+.045*_impact_speed+(.03 if _absorb_profile()==CREW_ABSORB else 0.0),.08,float(_absorb_profile().depth))
			# The absorb continues the visual root from where (and how fast) it
			# actually arrives: the last published root, rebased to this tick.
			_impact_root = _actual_root().origin
			_impact_bottom_gather = 0.0
			_impact_drift = (_velocity(worker)-worker.ground_velocity).slide(Vector3.UP)
			_settle_flight_torso()
			flight_stats.absorb_bottom_seconds = _absorb_bottom_time()
			flight_stats.impact_speed = _impact_speed
			flight_stats.absorb_depth = _absorb_depth
			if _impact_speed>1.0: worker._play_sound(worker.FOOTSTEP,.62+.04*minf(_impact_speed,3.0))
		elif _impact_age >= .0: _impact_age += delta
		_follow(_home,Vector3.ZERO)
		var upright := worker.global_basis.orthonormalized().get_rotation_quaternion().angle_to(_home.basis.orthonormalized().get_rotation_quaternion())<.035
		# An interrupted leap has no landing place to reach: settled upright on
		# whatever supports it (e.g. its own dropped cargo) is its recovery.
		var placed: bool = worker.global_position.distance_to(_home.origin)<.2 and worker._pose.evaluated_grounded.any(func(value: bool) -> bool: return value)
		if _abort_requested: placed = true
		var settled: bool = worker.on_ground and upright and worker._pose.evaluated_valid and placed and _velocity(worker).length()<.5 and worker.angular_velocity.length()<.35
		_settled = _settled+delta if settled else 0.0
		# Hand back once the absorb has bottomed out and is visibly recovering.
		var absorb: Dictionary = _absorb_profile()
		var absorbed := _absorb_bottom_time()+float(absorb.hold)+_rise_duration()-LANDING_TAIL
		if _settled >= .18 and (_impact_age < .0 or _impact_age >= absorbed): _finish(not _abort_requested)
		elif elapsed > 3.0:
			abort("Return landing needs clear supported ground")
			# The source is loose at its actual last carried pose. Native movement
			# and ordinary recovery continue; no original launch pose is restored.
			_finish(false)

func _cancel_spring() -> void:
	# The helper's ride-height spring (applied by _update_ground) is replaced by
	# the planned planted reaction during the supported departure.
	if not worker.on_ground: return
	var distance: float = worker.global_position.y-worker._ground_point.y
	var relative: float = (worker.linear_velocity-worker.ground_velocity).y
	var spring: float = worker.spring_support_force(worker.mass,worker.ride_height-distance,relative)
	worker.apply_central_force(Vector3.DOWN*spring)
	if is_instance_valid(worker._ground_body): worker._ground_body.apply_force(Vector3.UP*spring,worker._ground_point-worker._ground_body.global_position)

func _follow_prep(time: float) -> void:
	var lag := maxf(time-.5/float(Engine.physics_ticks_per_second),0.0)
	_follow(_prep_body(time),_prep_com(lag,1),_prep_com(time,2),_outbound_axis*_track_at(_prep_spin,lag,1),_outbound_axis*_track_at(_prep_spin,time,2),FLIGHT_GAINS,true)

func _release() -> void:
	# The drive's last planted tick IS the launch: the body already carries the
	# planned push-off velocity and spin (no impulse is added).
	elapsed = maxf(elapsed-_prep_seconds,0.0)
	_mark_launch_frame()
	var velocity := _velocity(worker)
	flight_stats.launch_outbound = {"speed":velocity.length(),"planned":_launch_velocity.length(),"error":velocity.distance_to(_launch_velocity),
		"spin":worker.angular_velocity.dot(_rotation_axis),"planned_spin":_launch_spin.length(),"pitch_deg":rad_to_deg(acos(clampf(worker.global_basis.y.normalized().dot(Vector3.UP),-1.0,1.0)))}
	worker.action = "pickup"
	worker.on_ground = false
	worker.stance_valid = false
	state = "outbound"

func _stand_down() -> void:
	# No touchdown absorb: the supported body simply rises out of its crouch.
	state = "landing"
	elapsed = 0.0
	_impact_age = 10.0
	_absorb_depth = 0.0
	_impact_bottom_gather = 0.0
	_settled = 0.0

func _register_impact(speed: float) -> void:
	_impact_clock = 0.0
	_impact_velocity = maxf(speed,0.0)
	_squash_depth = clampf(.018+.006*_impact_velocity,0.0,IMPACT_SQUASH) if speed>.3 else 0.0
	if _args.has("--head-leap-debug"): print("HEAD_LEAP_IMPACT speed=",speed," armed=",_impact_armed," arrival=",_arrival_velocity," now=",_velocity(worker)," age=",_contact_age)
	flight_stats.head_impact = {"speed":_impact_velocity,"squash":_squash_depth,"contact_age":_contact_age,"velocity_after":_velocity(worker).length(),"spin_after":worker.angular_velocity.length()}
	if _impact_velocity>.6: worker._play_sound(worker.FOOTSTEP,.5+.05*minf(_impact_velocity,2.0))

func contact_ready() -> bool:
	if state != "contact" or _abort_requested or not is_instance_valid(part): return false
	# A real head impact first (stopped by the native contact), then the legs'
	# whip-through; a legacy docked arrival keeps its short press beat.
	if _impact_armed and (_impact_clock<CONTACT_PRESS or _impact_clock<WHIP_SECONDS): return false
	if not _impact_armed and _contact_age<.06: return false
	var root := _actual_root()
	var head := root*_head_touch_local
	var point: Vector3 = part.global_transform*contact_local + contact_normal*CONTACT_GAP
	var tolerance := _contact_tolerance()
	contact_error = head.distance_to(point)
	if contact_error>maxf(CONTACT_ERROR,tolerance) or root.basis.y.normalized().dot(-contact_normal)<1.0-pow(tolerance/.43,2.0)*.5 or _velocity(worker).length()>.2 or worker.angular_velocity.length()>.15: return false
	# Test the evaluated actual upper head plane against this source's original
	# native surface, including its real roof footprint. An AABB proximity is
	# never an attachment event. Small stock can touch only part of that plane.
	contact_surface_gap=INF
	contact_surface_penetration=0.0
	for point_on_skin: Vector3 in _roof_samples:
		var surface := root*point_on_skin
		var query := PhysicsRayQueryParameters3D.create(surface+contact_normal*.025,surface-contact_normal*.025,CONTACT_QUERY_BIT)
		var hit := worker.get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty() or hit.collider!=part: continue
		var gap: float=hit.normal.dot(surface-hit.position)
		contact_surface_gap=minf(contact_surface_gap,gap)
		contact_surface_penetration=maxf(contact_surface_penetration,-gap)
	return contact_surface_gap<=tolerance and contact_surface_gap>=-tolerance and contact_surface_penetration<=tolerance and not _stock_support().is_empty()

func _contact_tolerance() -> float:
	# Four float32 coordinate units cover the native/mesh transform arithmetic
	# at Island distances; nearby focused play still needs a half-mm touch.
	var point: Vector3=part.global_position.abs()
	var magnitude := maxf(1.0,maxf(point.x,maxf(point.y,point.z)))
	var unit := pow(2.0,floor(log(magnitude)/log(2.0))-23.0)
	return maxf(.0005,unit*4.0)

func contact_frame() -> Transform3D:
	var root := _rigid_root()
	root.origin += root.basis*_head_touch_local
	if crew.size()>1:
		var roots: Array[Transform3D]=[]
		for member: Node in crew: roots.append(member.head_leap._rigid_root())
		root=_shared_head_frame(roots)
	return root

func _refresh_shared_anchor() -> void:
	# A crew's shared fixture sits on every member's evaluated crown. A partner
	# evaluated after the leader republishes the leader's anchor (and the frozen
	# shared load) from this tick's crown instead of the previous one.
	if crew.size()<2 or not contacted or crew[0]==worker or not is_instance_valid(crew[0]): return
	var leader: RefCounted = crew[0].head_leap
	if leader.contacted and leader.part==part and is_instance_valid(part) and part.carrier==crew[0].head_anchor: crew[0]._update_head()

func _rigid_root() -> Transform3D:
	# The evaluated cube without its visual squash: the squash pivots on the
	# crown, so the rigid frame keeps the exact crown point and orientation.
	var root := _actual_root()
	var crown := root*_head_touch_local
	var basis := root.basis.orthonormalized()
	return Transform3D(basis,crown-basis*_head_touch_local)

func _shared_head_frame(roots: Array[Transform3D]) -> Transform3D:
	var head:=roots[0]
	var centre:=Vector3.ZERO
	for index in roots.size(): centre+=roots[index]*crew[index].head_leap._head_touch_local
	centre/=roots.size()
	# A rigid shared load rests on BOTH crowns: the leader's frame tilts about
	# its nearest axis until the crown-to-crown line lies in its plane (two
	# heads absorbing a landing a few mm apart tilt the plate, never float it).
	var last := roots.size()-1
	var span: Vector3 = roots[last]*crew[last].head_leap._head_touch_local-roots[0]*crew[0].head_leap._head_touch_local
	var up := head.basis.y.normalized()
	if last>0 and span.length_squared()>.01:
		var line := span.normalized()
		var level := up-line*line.dot(up)
		if level.length_squared()>.25: head.basis = (Basis(Quaternion(up,level.normalized()))*head.basis.orthonormalized()).orthonormalized()
	var normal:=head.basis.y.normalized()
	var extension:=.0
	# The common finite fixture follows the highest actual roof skin of either
	# head, not the average height which could sweep stock through the higher
	# partner. This maximum of continuous skin positions is itself continuous;
	# contact captures its current frame without changing the source pose.
	for index in roots.size():
		for sample: Vector3 in crew[index].head_leap._roof_samples: extension=maxf(extension,normal.dot(roots[index]*sample-centre))
	head.origin=centre+normal*extension
	return head

static func attach_group(source: RigidBody3D, members: Array) -> bool:
	if members.is_empty() or not members.all(func(member: Node) -> bool: return member.head_leap.part==source and member.head_leap.contact_ready()): return false
	var leader: Node = members[0]
	var before := source.global_transform
	var source_velocity := _velocity(source)
	var local: Transform3D = leader.head_leap.contact_frame().affine_inverse()*before
	var share: float = source.mass/members.size()
	# Plan every cooperative trajectory before changing any source custody.
	# Their shared fixture follows the evaluated midpoint and leader orientation;
	# each worker's real contact face stays beneath the same original body.
	for member: Node in members:
		var controller: RefCounted = member.head_leap
		controller._cargo_local = local
		controller._planning_return = true
		controller._flight_start = member.global_transform
		controller._destination = controller._home
		controller._com_local = controller._loaded_com_local(source,share)
		controller._capture_return_start()
	var heavy: bool = leader.head_leap._return_heavy()
	var planned := false
	var failures: Array[String]=[]
	# Round 4: the return was normally planned (and its whole arc cleared, in
	# chunks) during the last ticks of the dive, from the planned contact pose.
	# Adopt it when the actual contact matches that pose; the cheap first pass
	# re-checks it against the current world on this contact tick.
	if members.all(func(member: Node) -> bool: return member.head_leap._preplan_matches(source)):
		for member: Node in members:
			var controller: RefCounted = member.head_leap
			controller._restore_plan(controller._preplanned.plan)
			controller._planning_return = true
		planned = members.all(func(member: Node) -> bool: return member.head_leap._arc_quick())
		for member: Node in members:
			member.head_leap.flight_stats.return_preplanned = planned
			# The visual squash continues from the actual impact clock.
			member.head_leap._squash_at_attach = member.head_leap._contact_squash(member.head_leap._impact_clock) if member.head_leap._impact_clock>=0.0 else 0.0
		if not planned:
			for member: Node in members:
				var controller: RefCounted = member.head_leap
				controller._cargo_local = local
				controller._flight_start = member.global_transform
				controller._destination = controller._home
				controller._com_local = controller._loaded_com_local(source,share)
				controller._capture_return_start()
	# Rewind about the outbound axis first: the head pushes off the stock and
	# the feet lead back toward the launch place. The opposite continuous
	# branch (load-upward-first) and the original long timings stay fallbacks.
	# All cooperative bodies select the same world axis branch.
	for tier: Array in [[HEAVY_RETURN if heavy else SOLO_RETURN,"brisk"],[LONG_RETURN,"long"],[LEGACY_RETURN,"legacy"]]:
		if planned: break
		for direction: float in [-1.0,1.0]:
			var blocked := 0
			for candidate: Array in tier[0]:
				# Two brisk candidates blocked by the world early in the push or
				# flight: their siblings share that path, try the next branch.
				if blocked>=2: break
				var shaped := true
				for member: Node in members:
					var controller: RefCounted = member.head_leap
					if not controller._plan_return(candidate,str(tier[1]),direction):
						shaped=false
						failures.append(member.worker_id+": "+controller.arc_failure)
						if _args.has("--head-leap-debug"): print("HEAD_LEAP_RETURN_REFUSED ",tier[1]," ",candidate," ",direction," ",failures.back())
						break
				if not shaped: continue
				if members.all(func(member: Node) -> bool: return member.head_leap._arc_quick()) and members.all(func(member: Node) -> bool: return member.head_leap._arc_clear(true,0.0,false,true)):
					planned=true
					break
				for member: Node in members:
					if not member.head_leap.arc_failure.is_empty():
						failures.append(member.worker_id+": "+member.head_leap.arc_failure)
						if tier[1]=="brisk" and _world_blocked(member.head_leap.arc_failure) and member.head_leap._failure_time()<.45: blocked += 1
				if _args.has("--head-leap-debug"): print("HEAD_LEAP_RETURN_REFUSED ",tier[1]," ",candidate," ",direction," ",failures.back() if not failures.is_empty() else "")
			if planned: break
		if planned: break
	if not planned: print("HEAD_RETURN_PREFLIGHT_REASONS ",failures.slice(0,8))

	for member: Node in members: member.head_leap._planning_return=false
	if not planned:
		for member: Node in members: member.head_leap.abort("No clear original-stock return arc; source remains at its actual head-contact pose: "+member.head_leap.arc_failure)
		return false
	var support: Dictionary = leader.head_leap._stock_support()
	# Transfer the SAME finite body's incoming momentum once. Source custody
	# changes at geometric head contact without relocating its pose or basis.
	leader.head_anchor.global_transform = leader.head_leap.contact_frame()
	for member: Node in members:
		# The carried body rides the heads through the head exception again.
		source.add_collision_exception_with(member)
	source.set_carried_at_pose(leader.head_anchor)
	for member: Node in members:
		var old_velocity := _velocity(member)
		member.set_cargo(source.mass/members.size())
		member.apply_central_impulse((source_velocity-old_velocity)*(source.mass/members.size()))
		member.head_leap.contacted = true
		member.head_leap._cargo_local = local
		member.head_leap.source_before_contact = before
		member.head_leap.source_after_contact = source.global_transform
		member.head_leap.flight_stats.contact_dwell = member.head_leap._contact_age
		member.head_leap._preplanned = {}
		member.head_leap._record_plan("return")
	for member: Node in members:
		var controller: RefCounted = member.head_leap
		controller._return_started=true
		# The head push-off is a reaction on the stock's own support, spread
		# over the leg kick (no instantaneous launch impulse).
		controller._support_body=support.get("collider") as Object
		controller._support_point=support.get("position",member.global_position)
		controller._support_normal=controller.contact_normal
		if controller._support_body is RigidBody3D: controller._support_body.sleeping=false
		controller.state="return"
		controller.elapsed=0.0
		# No free tick on the attach: a member that has not advanced yet this
		# tick follows its return plan this same tick.
		controller._mark_launch_frame()
	return true

# --- Return pre-plan (round 4): no planning hitch on the contact tick ---------
# During the last PREPLAN_LEAD of a brisk/long dive the leader plans the whole
# crew's loaded return from the PLANNED contact pose and clears its arc in
# chunks over several ticks (the outbound plan is restored after each step).
const PREPLAN_LEAD := .22
const PREPLAN_CHUNKS := 5
const PREPLAN_ATTACH_AGE := .07
var _preplan: Dictionary = {}
var _preplanned: Dictionary = {}

func _preplan_candidates() -> Array:
	var heavy := _return_heavy()
	var rows: Array = []
	for tier: Array in [[HEAVY_RETURN if heavy else SOLO_RETURN,"brisk"],[LONG_RETURN,"long"],[LEGACY_RETURN,"legacy"]]:
		for direction: float in [-1.0,1.0]:
			for candidate: Array in tier[0]: rows.append([candidate,str(tier[1]),direction])
	return rows

func _preplan_step() -> void:
	# Leader only: one bounded step per tick.
	if _preplan.get("finished",false) or not is_instance_valid(part): return
	var started := Time.get_ticks_usec()
	if _preplan.is_empty(): _preplan = {"index":0,"chunk":-1,"plans":[],"finished":false,"part":part.global_transform}
	var outbound: Array = []
	for member: Node in crew:
		outbound.append(member.head_leap._plan_snapshot())
		member.head_leap._preplan_saved_pose = member.head_leap._launch_leg_pose
	var rows := _preplan_candidates()
	if int(_preplan.chunk)<0:
		# Find the next candidate whose plan math and cheap pass succeed (a
		# few per tick at most).
		var tries := 0
		while int(_preplan.index)<rows.size() and tries<4:
			var row: Array = rows[int(_preplan.index)]
			tries += 1
			if _preplan_setup() and crew.all(func(member: Node) -> bool: return member.head_leap._plan_return(row[0],row[1],row[2])) \
				and crew.all(func(member: Node) -> bool: return member.head_leap._arc_quick()):
				var plans: Array = []
				for member: Node in crew: plans.append(member.head_leap._plan_snapshot())
				_preplan.plans = plans
				_preplan.chunk = 0
				break
			_preplan.index = int(_preplan.index)+1
		if int(_preplan.index)>=rows.size(): _preplan.finished = true
	else:
		# Clear one time window of the whole complete pass for every member.
		var plans: Array = _preplan.plans
		for index in crew.size():
			var controller: RefCounted = crew[index].head_leap
			controller._restore_plan(plans[index])
			controller._planning_return = true
		var span := float(crew[0].head_leap._flight_seconds)/PREPLAN_CHUNKS
		var low := span*int(_preplan.chunk)
		var high := span*(int(_preplan.chunk)+1)+.0001
		var clear := crew.all(func(member: Node) -> bool: return member.head_leap._arc_clear(true,low,false,true,high))
		if not clear:
			_preplan.index = int(_preplan.index)+1
			_preplan.chunk = -1
		else:
			_preplan.chunk = int(_preplan.chunk)+1
			if int(_preplan.chunk)>=PREPLAN_CHUNKS:
				_preplan.finished = true
				for index in crew.size(): crew[index].head_leap._preplanned = {"plan":plans[index],"part":_preplan.part}
	for index in crew.size():
		var controller: RefCounted = crew[index].head_leap
		controller._planning_return = false
		controller._restore_plan(outbound[index])
		controller._launch_leg_pose = controller._preplan_saved_pose
	flight_stats.preplan_ms = float(flight_stats.get("preplan_ms",0.0))+(Time.get_ticks_usec()-started)/1000.0
	flight_stats.preplan_peak_tick_ms = maxf(float(flight_stats.get("preplan_peak_tick_ms",0.0)),(Time.get_ticks_usec()-started)/1000.0)

var _preplan_saved_pose: Array = []

func _preplan_setup() -> bool:
	# Every member at its PLANNED contact pose, the same stock at its current
	# pose, the loaded COM and the leg/whip state of a typical attach.
	var share: float = part.mass/crew.size()
	var roots: Array[Transform3D] = []
	var poses: Array[Transform3D] = []
	for member: Node in crew:
		var controller: RefCounted = member.head_leap
		var pose: Transform3D = controller._contact_destination(HOLD_GAP)
		poses.append(pose)
		roots.append(pose*controller._root_local)
	var frame: Transform3D
	if crew.size()>1: frame = _shared_head_frame(roots)
	else: frame = Transform3D(roots[0].basis.orthonormalized(),roots[0]*_head_touch_local)
	var local: Transform3D = frame.affine_inverse()*part.global_transform
	for index in crew.size():
		var controller: RefCounted = crew[index].head_leap
		controller._cargo_local = local
		controller._planning_return = true
		controller._bare_push = false
		controller._flight_start = poses[index]
		controller._destination = controller._home
		controller._com_local = controller._loaded_com_local(part,share,poses[index])
		controller._return_start_angles = controller._contact_angles(maxf(PREPLAN_ATTACH_AGE-TWIN_DELAY*.5*controller._twin,0.0))
	return true

func _preplan_matches(source: RigidBody3D) -> bool:
	# The actual contact is the planned one (sub-mm/sub-degree), on the same
	# unmoved stock.
	if _preplanned.is_empty() or not is_instance_valid(source): return false
	var plan: Dictionary = _preplanned.plan
	var start: Transform3D = plan._flight_start
	var stock: Transform3D = _preplanned.part
	if worker.global_transform.origin.distance_to(start.origin)>.004: return false
	if worker.global_basis.orthonormalized().get_rotation_quaternion().angle_to(start.basis.orthonormalized().get_rotation_quaternion())>.02: return false
	return source.global_transform.origin.distance_to(stock.origin)<.001 and source.global_basis.orthonormalized().get_rotation_quaternion().angle_to(stock.basis.orthonormalized().get_rotation_quaternion())<.002

func _plan_return(candidate: Array, tier: String, direction: float) -> bool:
	_configure_rotation(_outbound_axis*direction)
	if tier!="legacy": return _plan_return_flight(float(candidate[0]),float(candidate[1]),tier)
	# Legacy quintic timing, entered through the same supported head push.
	var heavy := _return_heavy()
	_return_lead = RETURN_LEAD+(STRAIN_SECONDS if heavy else 0.0)
	_destination = _home
	_push_seconds = RETURN_PUSH
	if not _plan_flight(float(candidate[0]),float(candidate[1]),true,"legacy"): return false
	var velocity := _launch_velocity
	_push_seconds = _fit_push(velocity)
	var omega0 := _spin_angle(0.0,1)
	var start: Vector3 = _flight_start*_com_local
	var takeoff := _push_tracks(start,velocity)
	var push_end := Vector3(_track_at(takeoff[0],_return_lead+_push_seconds,0),_track_at(takeoff[1],_return_lead+_push_seconds,0),_track_at(takeoff[2],_return_lead+_push_seconds,0))
	var angle := _rotation_angle
	_rotation_angle = angle-.5*omega0*_push_seconds
	var planned := _plan_flight(float(candidate[0]),float(candidate[1]),true,"legacy",velocity,false,push_end)
	_rotation_angle = angle
	if not planned: return false
	_prepend_return_push(velocity)
	return true

const PLAN_FIELDS := ["_flight_start","_destination","_launch_velocity","_flight_seconds","_com_local","_track_x","_track_y","_track_z","_track_spin",
	"_beat_brake","_beat_open","_beat_assist","_beat_spin_end","_rotation_axis","_rotation_angle","_touchdown_velocity","_launch_spin","_plan_tier","_plan_candidate",
	"_support_from","_support_to","_return_lead","_push_seconds","_return_drift_brake","_return_lift","_cargo_local","_return_start_angles","_bare_push",
	"_com_local"]

func _plan_snapshot() -> Dictionary:
	var snapshot := {}
	for field: String in PLAN_FIELDS: snapshot[field] = get(field)
	return snapshot

func _restore_plan(snapshot: Dictionary) -> void:
	for field: String in snapshot: set(field,snapshot[field])

func _capture_restart_legs() -> void:
	# Restart from the last ACTUAL final published limbs. The same finite
	# interpolation feeds both preflight and posing, before any recovery force.
	var published: SkeletonModifier3D = worker._pose
	var inverse: Transform3D = published.evaluated_worker.affine_inverse()
	_restart_leg_points.clear()
	_restart_ankles.clear()
	for side in 2:
		_restart_leg_points.append(inverse*published.evaluated_hips[side])
		_restart_leg_points.append(inverse*published.evaluated_knees[side])
		_restart_leg_points.append(inverse*(published.evaluated_soles[side]-published.evaluated_ankles[side]*Vector3(0,published._ankle_height[side],0)))
		_restart_ankles.append(published.evaluated_worker.basis.inverse()*published.evaluated_ankles[side])
	# The same limbs as joint angles: the recovery's tuck path starts here.
	var cube_inverse: Transform3D = published.evaluated_root.affine_inverse()
	_restart_angles = _angles_of(0,[cube_inverse*published.evaluated_knees[0],
		cube_inverse*(published.evaluated_soles[0]-published.evaluated_ankles[0]*Vector3(0,published._ankle_height[0],0)),Basis.IDENTITY,float(LEG_TUCK[3])])

func _clear_restart_legs() -> void:
	_restart_leg_points.clear()
	_restart_angles.clear()
	_restart_ankles.clear()

func _mark_launch_frame() -> void:
	# A member whose advance already ran this tick must not follow twice; one
	# that has not run yet follows its new plan this same tick (no free tick).
	_launch_frame = Engine.get_physics_frames() if _advanced_frame==Engine.get_physics_frames() else -1

func _release_moved_stock() -> void:
	# A knocked stock is loose: real contact physics owns any touch from now
	# on. Lift the head exception at once when the bodies are apart; when they
	# already overlap, let them separate first (no violent depenetration).
	if not is_instance_valid(part): return
	for member: Node in crew:
		if not is_instance_valid(member): continue
		var leap: RefCounted = member.head_leap
		if leap._release_watch==part or not part.get_collision_exceptions().has(member): continue
		var bounds: AABB = part.global_transform*_stock_bounds
		var cube: AABB = leap._actual_root()*AABB(Vector3(-.38,-_head_height,-.38),Vector3(.76,_head_height*2.0,.76))
		if bounds.grow(.005).intersects(cube): leap._release_watch = part
		else: part.remove_collision_exception_with(member)

func _begin_bare_group_return(moved := false) -> bool:
	# The interrupted head has landed on the stock (round 4): every member
	# pushes off it bare with the loaded return's supported head push and
	# ballistic flight (the stock's own support carries the reaction). The
	# original slow recovery from rest is the fallback, then the fall.
	var snapshots: Array[Dictionary]=[]
	for member: Node in crew:
		var controller: RefCounted=member.head_leap
		snapshots.append(controller._plan_snapshot())
		controller._planning_return=true
		controller._bare_push=true
		controller._clear_restart_legs()
		controller._flight_start=member.global_transform
		controller._destination=controller._home
		controller._com_local=controller._native_com_local()
		controller._capture_return_start()
	var planned := false
	var failures: Array[String]=[]
	if not moved:
		for tier: Array in [[SOLO_RETURN,"brisk"],[LONG_RETURN,"long"],[LEGACY_RETURN,"legacy"]]:
			for direction: float in [-1.0,1.0]:
				for candidate: Array in tier[0]:
					var shaped := true
					for member: Node in crew:
						if not member.head_leap._plan_return(candidate,str(tier[1]),direction):
							shaped=false
							failures.append("%s %s %s" % [tier[1],str(candidate),member.head_leap.arc_failure])
							break
					if not shaped: continue
					if crew.all(func(member: Node) -> bool: return member.head_leap._arc_quick()) and crew.all(func(member: Node) -> bool: return member.head_leap._arc_clear(false,0.0,false,true)):
						planned=true
						break
					for member: Node in crew:
						if not member.head_leap.arc_failure.is_empty(): failures.append("%s %s %s" % [tier[1],str(candidate),member.head_leap.arc_failure])
				if planned: break
			if planned: break
	if planned:
		# The head pushes off the stock it landed on, exactly like the loaded
		# return: the stock transmits the paired reaction to whatever it rests
		# on (the head rides it through the exception, lifted once apart).
		var support: Dictionary = _stock_support()
		for member: Node in crew:
			var controller: RefCounted=member.head_leap
			controller._planning_return=false
			controller._bare_waiting=false
			controller._return_started=true
			controller._support_body=support.get("collider",part) as Object
			controller._support_point=support.get("position",controller._head_point())
			controller._support_normal=controller.contact_normal
			if controller._support_body is RigidBody3D: controller._support_body.sleeping=false
			if is_instance_valid(part) and member.is_inside_tree():
				part.add_collision_exception_with(member)
				controller._release_watch=part
				controller._release_margin=.03
			controller._record_plan("bare_return")
			controller.state="return"
			controller.elapsed=0.0
			controller._mark_launch_frame()
		return true
	if _args.has("--head-leap-debug"): print("HEAD_BARE_PUSH_REASONS ",failures.slice(0,8))
	for index in crew.size():
		crew[index].head_leap._restore_plan(snapshots[index])
		crew[index].head_leap._bare_push=false
	return _begin_slow_bare_return()

func _begin_slow_bare_return() -> bool:
	# Fallback from rest on the stock (no mid-air reversal): the original
	# quintic recovery; no impulse, the assisted body only brakes and turns
	# back to the supported home pose. Without one, the fall takes over.
	for member: Node in crew:
		var controller: RefCounted=member.head_leap
		controller._planning_return=true
		controller._capture_restart_legs()
		controller._flight_start=member.global_transform
		controller._destination=controller._home
		controller._com_local=controller._native_com_local()
	var planned := false
	var failures: Array[String]=[]
	for branch: float in [1.0,-1.0]:
		for seconds: float in [.9,1.1,1.25,1.4,1.6,1.8,2.4,3.0]:
			var shaped := true
			for member: Node in crew:
				var controller: RefCounted=member.head_leap
				controller._configure_rotation(_crew_axis if crew.size()>1 else Vector3.ZERO,branch)
				if crew.size()>1 and branch<0.0: controller._configure_rotation(-_crew_axis)
				if not controller._plan_flight(seconds,0.0,true,"bare",_velocity(member)):
					shaped=false
					failures.append("%.2fs/%d %s" % [seconds,int(branch),controller.arc_failure])
			if shaped and crew.all(func(member: Node) -> bool:return member.head_leap._arc_quick()) and crew.all(func(member: Node) -> bool:return member.head_leap._arc_clear(false,0.0,false,true)):
				planned=true
				break
			for member: Node in crew:
				if shaped and not member.head_leap.arc_failure.is_empty(): failures.append("%.2fs/%d %s" % [seconds,int(branch),member.head_leap.arc_failure])
		if planned: break
	if not planned: print("HEAD_BARE_RETURN_REASONS ",failures.slice(0,10))
	_end_recovery_planning(planned,"bare_return")
	return true

func _end_recovery_planning(planned: bool, label: String) -> void:
	for member: Node in crew:
		var controller: RefCounted=member.head_leap
		controller._planning_return=false
		controller._bare_waiting=false
		controller._return_started=true
		if planned:
			controller._record_plan(label)
			controller.state="return"
			controller.elapsed=0.0
			controller._mark_launch_frame()
		else:
			controller._finish(false)
			if member.ragdoll and not member.ragdoll.is_down(): member.ragdoll.knock_down()

func _begin_fall_recovery() -> bool:
	# An interrupted dive with no stock to land on (knocked away, or the rest
	# of the dive blocked): the COM continues its ballistic arc (no reversal,
	# at most FALL_ASSIST of translational correction); the assist only turns
	# the body feet-down while the legs tuck and open to land past or beside
	# the stock. Without a clear landing, fly on unassisted for a moment while
	# a knocked stock clears the way, then the fall (ragdoll) takes over.
	# Returns false only while waiting (the admitted outbound plan is kept).
	var snapshots: Array[Dictionary]=[]
	for member: Node in crew:
		var controller: RefCounted=member.head_leap
		snapshots.append(controller._plan_snapshot())
		controller._planning_return=true
		controller._capture_restart_legs()
	var planned := false
	var failures: Array[String]=[]
	for branch: float in [1.0,-1.0]:
		var shaped := true
		for member: Node in crew:
			if not member.head_leap._plan_fall_recovery(branch):
				shaped=false
				failures.append("%d %s" % [int(branch),member.head_leap.arc_failure])
				break
		if shaped and crew.all(func(member: Node) -> bool:return member.head_leap._arc_quick()) and crew.all(func(member: Node) -> bool:return member.head_leap._arc_clear(false,0.0,false,true)):
			planned=true
			break
		for member: Node in crew:
			if shaped and not member.head_leap.arc_failure.is_empty(): failures.append("%d %s" % [int(branch),member.head_leap.arc_failure])
	if planned:
		for member: Node in crew:
			var controller: RefCounted=member.head_leap
			# The landing place is where the ballistic arc meets the ground.
			controller._home = controller._destination
		_end_recovery_planning(true,"fall_recovery")
		return true
	if _bare_wait_age<BARE_WAIT_SECONDS:
		for index in crew.size():
			var controller: RefCounted=crew[index].head_leap
			controller._planning_return=false
			controller._clear_restart_legs()
			controller._restore_plan(snapshots[index])
			if not controller._bare_waiting: controller._bare_wait_start=controller.elapsed
			controller._bare_waiting=true
			controller._bare_wait_age=controller.elapsed-controller._bare_wait_start
		return false
	print("HEAD_FALL_RECOVERY_REASONS ",failures.slice(0,6))
	_end_recovery_planning(false,"fall_recovery")
	return true

func _plan_fall_recovery(branch: float) -> bool:
	# Ballistic continuation: the COM keeps its actual velocity under gravity
	# until it reaches the standing COM height above the ground it falls onto;
	# the body turns from its current attitude to upright (either branch).
	arc_failure = ""
	_plan_tier = "fall"
	_plan_candidate = [branch]
	_support_from = -1.0
	_support_to = -1.0
	_bare_push = false
	_flight_start = worker.global_transform
	_com_local = _native_com_local()
	var start: Vector3 = _flight_start*_com_local
	var velocity := _velocity(worker)
	# Standing COM height above the sole plane (slightly bent at touchdown).
	var stand: float = (_home*_com_local).y-(_home.origin.y-worker.ride_height)-.03
	var space := worker.get_world_3d().direct_space_state
	var exclusions: Array[RID] = worker.query_exclusions()
	for member: Node in crew: exclusions.append(member.get_rid())
	var seconds := .5
	var ground: float = _home.origin.y-worker.ride_height
	for iteration in 4:
		var at := start+velocity*seconds+Vector3.DOWN*(.5*GRAVITY*seconds*seconds)
		var query := PhysicsRayQueryParameters3D.create(Vector3(at.x,maxf(start.y,at.y)+.3,at.z),Vector3(at.x,at.y-2.0,at.z),1)
		query.exclude = exclusions
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			arc_failure = "no ground under the ballistic landing"
			return false
		if hit.collider==part:
			arc_failure = "the ballistic fall lands on the stock"
			return false
		if hit.normal.y<.8:
			arc_failure = "the ballistic fall lands on a slope"
			return false
		ground = hit.position.y
		var discriminant: float = velocity.y*velocity.y+2.0*GRAVITY*(start.y-(ground+stand))
		if discriminant<0.0:
			arc_failure = "the ballistic arc stays below the standing height"
			return false
		seconds = (velocity.y+sqrt(discriminant))/GRAVITY
	if seconds<.3:
		arc_failure = "%.2fs of fall is too short to land feet-down" % maxf(seconds,0.0)
		return false
	var land := start+velocity*seconds+Vector3.DOWN*(.5*GRAVITY*seconds*seconds)
	var basis := _home.basis.orthonormalized()
	_destination = Transform3D(basis,land-basis*_com_local)
	_configure_rotation(Vector3.ZERO,branch)
	_flight_seconds = seconds
	_track_x = [_segment(0.0,seconds,PackedFloat64Array([start.x,velocity.x]))]
	_track_y = [_segment(0.0,seconds,PackedFloat64Array([start.y,velocity.y,-.5*GRAVITY]))]
	_track_z = [_segment(0.0,seconds,PackedFloat64Array([start.z,velocity.z]))]
	_launch_velocity = velocity
	_touchdown_velocity = velocity+Vector3.DOWN*GRAVITY*seconds
	# Attitude: from the actual spin about this axis to upright, finishing a
	# little before the touchdown; the off-axis spin is damped by the same cap.
	var spin_seconds := seconds*.85
	var omega0 := clampf(worker.angular_velocity.dot(_rotation_axis),-MAXIMUM_SPIN,MAXIMUM_SPIN)
	var off_axis: float = (worker.angular_velocity-_rotation_axis*worker.angular_velocity.dot(_rotation_axis)).length()
	var spin := _quintic(0.0,omega0,0.0,_rotation_angle,0.0,0.0,spin_seconds)
	_track_spin = [_segment(0.0,spin_seconds,spin)]
	_launch_spin = _rotation_axis*omega0
	var peak_alpha := .0
	for step in 33: peak_alpha = maxf(peak_alpha,absf(_quintic_at(spin,spin_seconds*float(step)/32.0,2)))
	peak_alpha += off_axis/maxf(spin_seconds*.5,.05)
	if peak_alpha>MAXIMUM_ANGULAR_ACCELERATION*.95:
		arc_failure = "turning feet-down needs %.1frad/s² in %.2fs" % [peak_alpha,spin_seconds]
		return false
	_beat_brake = seconds
	_beat_open = spin_seconds*.6
	_beat_assist = _beat_open
	_beat_spin_end = spin_seconds
	return true

func _configure_rotation(preferred_axis := Vector3.ZERO, branch := 1.0) -> void:
	var rotation := (_destination.basis.orthonormalized().get_rotation_quaternion()*_flight_start.basis.orthonormalized().get_rotation_quaternion().inverse()).normalized()
	if rotation.w<0.0: rotation=-rotation
	var vector := Vector3(rotation.x,rotation.y,rotation.z)
	_rotation_axis=vector.normalized() if vector.length_squared()>.000001 else (preferred_axis.normalized() if preferred_axis.length_squared()>.5 else Vector3.RIGHT)
	_rotation_angle=2.0*atan2(vector.length(),maxf(rotation.w,.000001))
	var alternative := _rotation_axis.dot(preferred_axis)<0.0 if preferred_axis.length_squared()>.5 else branch<0.0
	if alternative and _rotation_angle>.01:
		_rotation_axis=-_rotation_axis
		_rotation_angle=TAU-_rotation_angle

func _spin_angle(time: float, order: int) -> float:
	return _track_at(_track_spin,time,order)

func _planned_com(time: float, order: int) -> Vector3:
	# Clamped evaluation holds each channel's end state (rest, or touchdown motion).
	if _track_y.is_empty(): return _destination*_com_local if order==0 else Vector3.ZERO
	return Vector3(_track_at(_track_x,time,order),_track_at(_track_y,time,order),_track_at(_track_z,time,order))

func _planned_body(time: float) -> Transform3D:
	# Rotation about the planned centre of mass: the cube spins, it does not orbit.
	var basis := Basis(_rotation_axis,_spin_angle(time,0))*_flight_start.basis.orthonormalized()
	return Transform3D(basis,_planned_com(time,0)-basis*_com_local)

# Planned frames of one admission pass, shared by the partner and cargo checks
# (a crew evaluates each member's sample once, not once per partner). The
# cache belongs to one exact plan: any planning state change discards it.
var _samples: Dictionary = {}
var _samples_key: Array = []

func _refresh_samples() -> void:
	var key: Array = [_flight_seconds,_rotation_angle,_rotation_axis,_launch_velocity,_launch_spin,_com_local,_flight_start,_destination,_root_local,
		_plan_tier,_plan_candidate,_return_lead,_push_seconds,_stunt_capacity,_splay,_planning_return,_return_started,_restart_leg_points.size(),_restart_angles,
		_beat_brake,_beat_open,_beat_assist,_beat_spin_end,_support_from,_track_x.size(),_track_y.size(),_track_spin.size(),_twin,_cargo_local,_launch_leg_pose,_return_start_angles,_bare_push]
	if key!=_samples_key:
		_samples.clear()
		_samples_key = key

func _sample(time: float) -> Array:
	# [body, cube-frame leg points (body-local), cube] at a plan time.
	var cached: Variant = _samples.get(time)
	if cached!=null: return cached
	var body := _planned_body(time)
	var result: Array = [body,_planned_leg_points(time),body*_root_at(time)]
	_samples[time] = result
	return result

func _root_at(time: float) -> Transform3D:
	# The cube frame relative to the body at plan time: the launch root through
	# the outbound and contact; the return blends it back to the rest root.
	if not _return_phase(): return _root_local
	var blend := smoothstep(.05,.8,clampf(time/maxf(_flight_seconds,.001),0.0,1.0))
	return _blend_root(_root_local,_rest_root_local,blend)

static func _blend_root(from: Transform3D, to: Transform3D, weight: float) -> Transform3D:
	var rotation := from.basis.orthonormalized().get_rotation_quaternion().slerp(to.basis.orthonormalized().get_rotation_quaternion(),weight)
	return Transform3D(Basis(rotation),from.origin.lerp(to.origin,weight))

func _planned_group_head(time: float) -> Transform3D:
	var leader: RefCounted = crew[0].head_leap
	var head: Transform3D = leader._sample(time)[2]
	var roots: Array[Transform3D]=[]
	for member: Node in crew: roots.append(member.head_leap._sample(time)[2])
	if crew.size()>1: return _shared_head_frame(roots)
	head.origin+=head.basis*leader._head_touch_local
	return head

func _planned_angular_velocity(time: float) -> Vector3:
	return _rotation_axis*_spin_angle(time,1)

func _planned_angular_acceleration(time: float) -> Vector3:
	return _rotation_axis*_spin_angle(time,2)

func _follow_plan(time: float, supported := false) -> void:
	# Jolt integrates semi-implicitly (velocity, then position). A body that
	# is on the plan at t carries the plan's mid-step velocity p'(t - dt/2);
	# with the p''(t) feed-forward the discrete flight then stays on the
	# continuous plan instead of drifting a*dt*t/2 behind it.
	var lag := maxf(time-.5/float(Engine.physics_ticks_per_second),0.0)
	_follow(_planned_body(time),_planned_com(lag,1),_planned_com(time,2),_planned_angular_velocity(lag),_planned_angular_acceleration(time),FLIGHT_GAINS,supported)

func _flight_inertia_world() -> Basis:
	# Jolt's inertia of the swapped flight torso: a uniform box of the current
	# mass about its own centre (measured in Jolt: .087 m / .097 m / .086 m kg·m²).
	# Used for the launch impulse, before the native shape swap is applied.
	var size := Vector3(.76,_head_height*2.0,.76)
	var moments := Vector3(size.y*size.y+size.z*size.z,size.x*size.x+size.z*size.z,size.x*size.x+size.y*size.y)*worker.mass/12.0
	var frame := (worker.global_basis*_root_local.basis).orthonormalized()
	var inertia := frame*Basis.from_scale(moments)*frame.transposed()
	# Jolt's mass properties are about the body's custom COM: parallel axis.
	var offset: Vector3 = worker.global_basis*(_root_local.origin-_native_com_local())
	var shift := worker.mass*offset.length_squared()
	return Basis(inertia.x+Vector3(shift,0,0)-offset*offset.x*worker.mass,inertia.y+Vector3(0,shift,0)-offset*offset.y*worker.mass,inertia.z+Vector3(0,0,shift)-offset*offset.z*worker.mass)

func _inertia_world() -> Basis:
	var direct := PhysicsServer3D.body_get_direct_state(worker.get_rid())
	if direct:
		var inverse: Basis = direct.inverse_inertia_tensor
		if absf(inverse.determinant())>1e-9: return inverse.inverse()
	return _flight_inertia_world()

func _follow(goal: Transform3D, com_velocity: Vector3, com_acceleration := Vector3.ZERO, angular_velocity := Vector3.ZERO, angular_acceleration := Vector3.ZERO, gains: Array = FLIGHT_GAINS, supported := false) -> void:
	var direct := PhysicsServer3D.body_get_direct_state(worker.get_rid())
	var com: Vector3=direct.center_of_mass_local if direct else _com_local
	# Track the ACTUAL native COM point of the planned body (cargo/torso swaps
	# move it slightly from the planned COM), with its exact rigid motion.
	var offset := goal.basis*(com-_com_local)
	var position_error := goal*com-worker.global_transform*com
	var wanted_velocity := com_velocity+angular_velocity.cross(offset)
	var wanted_acceleration := com_acceleration+angular_acceleration.cross(offset)+angular_velocity.cross(angular_velocity.cross(offset))
	# Supported landing uses the existing opposite leg/ground spring reaction.
	# In-air gravity assistance must not double that real support force.
	var gravity_assist := .0 if state=="landing" and worker.on_ground else GRAVITY
	var feed := wanted_acceleration+Vector3.UP*gravity_assist
	# A planted push (feet on the ground, or the head on the stock) carries the
	# planned feed-forward as a real support reaction paired with that support;
	# only what the friction cone cannot push, and the tracking correction,
	# remain the finite assist.
	var reaction := _support_reaction(feed,_support_normal) if supported else Vector3.ZERO
	var command := feed-reaction+position_error*float(gains[0])+(wanted_velocity-_velocity(worker))*float(gains[1])
	var cap := FALL_ASSIST if state=="return" and _plan_tier=="fall" else MAXIMUM_ACCELERATION
	var acceleration := command.limit_length(cap)
	worker.apply_central_force((acceleration+reaction)*worker.mass)
	if supported: _apply_support(-reaction*worker.mass,Vector3.ZERO)
	var error := (goal.basis.orthonormalized().get_rotation_quaternion()*worker.global_basis.orthonormalized().get_rotation_quaternion().inverse()).normalized()
	if error.w<0.0: error=-error
	var axis := Vector3(error.x,error.y,error.z)
	var angle := 2.0*atan2(axis.length(),maxf(error.w,.000001))
	# No dead zone: a 0.1 degree residual (|axis| ~ 1e-3) must still be corrected.
	var rotation_error := axis.normalized()*angle if axis.length_squared()>1e-16 else Vector3.ZERO
	var inertia := _inertia_world()
	# A planted push also turns the body through the support's moment (the
	# reaction's line of action off the COM), bounded by a foot-length lever.
	var support_torque := (inertia*angular_acceleration).limit_length(reaction.length()*worker.mass*SUPPORT_LEVER) if supported else Vector3.ZERO
	var angular_feed := angular_acceleration-(inertia.inverse()*support_torque if supported else Vector3.ZERO)
	# Angular-acceleration feed-forward removes the PD lag; the command is
	# capped at 24 rad/s² of the body's ACTUAL Jolt inertia (not an estimate).
	var alpha := (rotation_error*float(gains[2])+(angular_velocity-worker.angular_velocity)*float(gains[3])+angular_feed).limit_length(MAXIMUM_ANGULAR_ACCELERATION)
	worker.apply_torque(inertia*alpha+support_torque)
	if supported: _apply_support(Vector3.ZERO,-support_torque)
	# Per-tick controller statistics only when profiling (lab / --head-leap-stats).
	if profile_stats and state in ["prepare","outbound","contact","return"]:
		var key := "prepare_" if state=="prepare" else ""
		flight_stats[key+"peak_force"] = maxf(float(flight_stats.get(key+"peak_force",0.0)),acceleration.length()*worker.mass)
		flight_stats[key+"peak_force_ratio"] = maxf(float(flight_stats.get(key+"peak_force_ratio",0.0)),acceleration.length()/MAXIMUM_ACCELERATION)
		flight_stats[key+"force_cap"] = MAXIMUM_ACCELERATION*worker.mass
		flight_stats[key+"peak_alpha"] = maxf(float(flight_stats.get(key+"peak_alpha",0.0)),alpha.length())
		flight_stats[key+"peak_torque"] = maxf(float(flight_stats.get(key+"peak_torque",0.0)),(inertia*alpha).length())
		flight_stats.alpha_cap = MAXIMUM_ANGULAR_ACCELERATION
		if supported:
			flight_stats[key+"peak_support_g"] = maxf(float(flight_stats.get(key+"peak_support_g",0.0)),reaction.length()/GRAVITY)
			flight_stats[key+"peak_support_torque"] = maxf(float(flight_stats.get(key+"peak_support_torque",0.0)),support_torque.length())
			if state=="return" and is_instance_valid(part):
				# Stylised spread push (documented): the head push's paired
				# support reaction is spread over the kick while the rigid cube
				# already lifts its stock (or itself) off that support. Report
				# the delta-v it supplies while still resting and once lifted.
				var lift := INF
				if contacted and is_instance_valid(part.carrier): lift = (part.global_transform*_stock_bounds).position.y-_support_point.y
				else: lift = _support_normal.dot(_head_point()-(part.global_transform*contact_local))
				var dv := reaction.length()/float(Engine.physics_ticks_per_second)
				var slot := "support_dv_resting" if lift<=.001 else "support_dv_lifted"
				flight_stats[slot] = float(flight_stats.get(slot,0.0))+dv
		if command.length()>MAXIMUM_ACCELERATION+.001: flight_stats[key+"force_saturated_ticks"] = int(flight_stats.get(key+"force_saturated_ticks",0))+1
		flight_stats.inertia_per_mass = (inertia.x.x+inertia.y.y+inertia.z.z)/(3.0*worker.mass)

func _apply_support(force: Vector3, torque: Vector3) -> void:
	# The opposite reaction on a movable support (ground body, or the body the
	# stock rests on), woken first so a sleeping support still receives it.
	var support := _support_body as RigidBody3D
	if not is_instance_valid(support): return
	support.sleeping = false
	if force.length_squared()>0.0: support.apply_force(force,_support_point-support.global_position)
	if torque.length_squared()>0.0: support.apply_torque(torque)

func _arc_quick(from_time := 0.0) -> bool:
	# The cheap first pass alone (force budget, padded head box): a crew runs
	# it for every member before any member's complete pass.
	return _arc_clear(false,from_time,true)

func _arc_clear(with_cargo: bool, from_time := 0.0, quick_only := false, quick_done := false, to_time := INF) -> bool:
	arc_failure=""
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask = 1
	var exclusions: Array[RID]=worker.query_exclusions()
	for member: Node in crew: exclusions.append(member.get_rid())
	if is_instance_valid(part): exclusions.append(part.get_rid())
	query.exclude = exclusions
	var shape := BoxShape3D.new()
	shape.size = Vector3(.80,.70,.80)
	query.shape = shape
	var space := worker.get_world_3d().direct_space_state
	var source_query := PhysicsShapeQueryParameters3D.new()
	source_query.collision_mask=CONTACT_QUERY_BIT
	# The target remains an obstacle throughout the approach. Its exact native
	# material is queried separately from the inflated world-clearance proxies.
	# Only the true roof-plane endpoint may approach within the contact gap.
	source_query.exclude=worker.query_exclusions()
	var steps := ceili(_flight_seconds*30.0)
	# The world and actual native COM cannot advance inside this synchronous
	# admission. Reuse precisely the same computed finite frames/accelerations
	# in its second pass; all original samples and native queries still run.
	# The planned COM is the native COM this body has in that flight (the return
	# predicts the shared cargo); its admission is the unchanged |a + g| <= .9 2g.
	# Cheap first pass, sample by sample so a refusal stops at once: the force
	# budget of the planned COM and the padded head box alone against the
	# world. Most refusals (screens, shelves, overhangs) end here before the
	# limb, tool, holder, cargo and crew queries of the complete pass below.
	for member: Node in crew: member.head_leap._refresh_samples()
	var head_query := PhysicsShapeQueryParameters3D.new()
	head_query.collision_mask = 1
	head_query.exclude = exclusions
	head_query.shape = shape
	for step in range(steps+1):
		if quick_done: break
		var time := _flight_seconds*float(step)/steps
		if time<from_time-.000001: continue
		var feed := _planned_com(time,2)+Vector3.UP*GRAVITY
		# A supported push needs assist only beyond what its support can push
		# (no pull, friction cone, bounded); the same .9 x 2g budget applies.
		var acceleration := (feed-_support_reaction(feed,contact_normal)).length() if _supported_at(time) else feed.length()
		if acceleration>MAXIMUM_ACCELERATION*FORCE_BUDGET:
			arc_failure="force budget at %.3fs: %.3fm/s²%s" % [time,acceleration," beyond the supported push" if _supported_at(time) else ""]
			return false
		if step==0: continue
		head_query.transform = _sample(time)[2]
		var head_hits := space.intersect_shape(head_query,1)
		if not head_hits.is_empty():
			var blocker: Variant = head_hits[0].get("collider")
			arc_failure="head obstruction at %.3fs centre %s by %s" % [time,head_query.transform.origin,blocker.name if blocker is Node else str(blocker)]
			return false
	if quick_only: return true
	# One exact geometry validation per synchronous arc; samples reuse
	# its original source-local boxes without walking the scene again.
	var gun_head_boxes: Array[Dictionary] = []
	if with_cargo and _gun_head_geometry_current(): gun_head_boxes = _gun_head_geometry.boxes
	var limb_shape := SphereShape3D.new()
	limb_shape.radius=.085
	var torso := BoxShape3D.new()
	torso.size=Vector3(.76,_head_height*2.0,.76)
	var tool_shape := BoxShape3D.new()
	if is_instance_valid(worker.equipped_tool): tool_shape.size = _tool_bounds.size+Vector3.ONE*.025
	var holder_shape := BoxShape3D.new()
	if _holder_bounds.size.length_squared()>.000001: holder_shape.size=_holder_bounds.size+Vector3.ONE*.015
	var holder_source_shape := BoxShape3D.new()
	if _holder_source_bounds.has_volume(): holder_source_shape.size=_holder_source_bounds.size+Vector3.ONE*.015
	var cargo_shape := BoxShape3D.new()
	cargo_shape.size = _stock_bounds.size+Vector3.ONE*.03
	var cargo_start: Vector3 = (_planned_group_head(0.0)*_cargo_local).origin if with_cargo else Vector3.ZERO
	for step in range(1,steps+1):
		var time := _flight_seconds*float(step)/steps
		if time<from_time-.000001: continue
		if time>to_time: break
		# The same frames the first pass admitted (force budget, head box).
		var sample: Array = _sample(time)
		var body: Transform3D=sample[0]
		var legs: Array[Vector3]=sample[1]
		var root := _root_at(time)
		if not _crew_clear(time,with_cargo,gun_head_boxes,body,legs): return false
		query.shape=limb_shape
		for side in 2:
			for link in 2:
				var a: Vector3=body*legs[side*3+link]
				var b: Vector3=body*legs[side*3+link+1]
				for fraction: float in [.0,.25,.5,.75,1.0]:
					query.transform=Transform3D(Basis.IDENTITY,a.lerp(b,fraction))
					if not space.intersect_shape(query,1).is_empty(): arc_failure="leg %d/%d obstruction at %.3fs centre %s" % [side,link,time,query.transform.origin]; return false
		# Check the complete toe-held tool and finite flight torso.
		query.shape=torso
		query.transform=body*root
		if not space.intersect_shape(query,1).is_empty(): arc_failure="torso obstruction at %.3fs" % time; return false
		if _return_phase() and _needs_collision_restore and not root.is_equal_approx(_root_local):
			# The physical flight torso keeps its launch pose while the visual
			# cube blends back: clear that actual collision box too.
			query.transform=body*_root_local
			if not space.intersect_shape(query,1).is_empty(): arc_failure="flight torso obstruction at %.3fs" % time; return false
			query.transform=body*root
		# A bare push-off starts with the head ON the stock: its own touch is
		# the support until the push has lifted the head clear.
		var check_source := not with_cargo and not (_bare_push and _return_phase() and time<=_support_to+.04)
		if check_source:
			source_query.shape=torso
			source_query.transform=query.transform
			if not space.intersect_shape(source_query,1).is_empty(): arc_failure="original stock intersects head/body before contact at %.3fs" % time; return false
			source_query.shape=limb_shape
			for side in 2:
				for link in 2:
					var a: Vector3=body*legs[side*3+link]
					var b: Vector3=body*legs[side*3+link+1]
					for fraction: float in [.0,.25,.5,.75,1.0]:
						source_query.transform=Transform3D(Basis.IDENTITY,a.lerp(b,fraction))
						if not space.intersect_shape(source_query,1).is_empty(): arc_failure="original stock intersects leg before contact at %.3fs" % time; return false
		if is_instance_valid(worker.equipped_tool):
			query.shape = tool_shape
			query.transform = body*_tool_local*Transform3D(Basis.IDENTITY,_tool_bounds.get_center())
			if not space.intersect_shape(query,1).is_empty(): arc_failure="tool obstruction at %.3fs" % time; return false
			if check_source:
				source_query.shape=tool_shape
				source_query.transform=query.transform
				if not space.intersect_shape(source_query,1).is_empty(): arc_failure="original stock intersects retained tool before contact at %.3fs" % time; return false
		if _holder_bounds.size.length_squared()>.000001:
			query.shape=holder_shape
			query.transform=body*_holder_frame(time)*Transform3D(Basis.IDENTITY,_holder_bounds.get_center())
			if not space.intersect_shape(query,1).is_empty(): arc_failure="original back holder obstruction at %.3fs" % time; return false
			if check_source and _holder_source_bounds.has_volume():
				source_query.shape=holder_source_shape
				source_query.transform=body*_holder_frame(time)*Transform3D(Basis.IDENTITY,_holder_source_bounds.get_center())
				if not space.intersect_shape(source_query,1).is_empty(): arc_failure="original stock intersects permanent back holder before head contact at %.3fs" % time; return false
		if with_cargo:
			var head := _planned_group_head(_flight_seconds*float(step)/steps)
			query.shape = cargo_shape
			query.transform = head*_cargo_local*Transform3D(Basis.IDENTITY,_stock_bounds.get_center())
			# While the supported head push is still lifting the stock off its own
			# support, its padded box necessarily touches that support.
			var lifting := _support_from>=0.0 and time<=_support_to+.02 and (head*_cargo_local).origin.distance_to(cargo_start)<.04
			var stock_hits: Array=[] if lifting else space.intersect_shape(query,1)
			if not stock_hits.is_empty():
				if "--easy-island-removed-wheel-probe" in _args:
					_observe_cargo_refusal(time,head*_cargo_local,query,stock_hits,space)
				# A wheel's empty rectangular corners are not physical cargo. Keep
				# the fast padded-box admission; only a rejection needs the exact
				# enabled original geometry, with the same 15 mm face clearance.
				if not _original_wheel_cargo_clear(head*_cargo_local,query,space):
					arc_failure="stock obstruction at %.3fs" % time
					return false
		query.shape = shape
	return true

func _head_path_clear(from_time := 0.0) -> bool:
	_refresh_samples()
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask = 1
	var exclusions: Array[RID]=worker.query_exclusions()
	for member: Node in crew: exclusions.append(member.get_rid())
	if is_instance_valid(part): exclusions.append(part.get_rid())
	query.exclude = exclusions
	var shape := BoxShape3D.new()
	shape.size = Vector3(.80,.70,.80)
	query.shape = shape
	var space := worker.get_world_3d().direct_space_state
	var steps := ceili(_flight_seconds*30.0)
	for step in range(1,steps+1):
		var time := _flight_seconds*float(step)/steps
		if time<from_time-.000001: continue
		query.transform = _sample(time)[2]
		if not space.intersect_shape(query,1).is_empty():
			arc_failure="head obstruction at %.3fs centre %s" % [time,query.transform.origin]
			return false
	return true

func _supported_at(time: float) -> bool:
	return _support_from>=0.0 and time>=_support_from-.0001 and time<=_support_to+.0001

static func _boxes_overlap(a: Transform3D, a_size: Vector3, b: Transform3D, b_size: Vector3) -> bool:
	var axes: Array[Vector3]=[a.basis.x,a.basis.y,a.basis.z,b.basis.x,b.basis.y,b.basis.z]
	for aa in 3:
		for bb in 3: axes.append(a.basis[aa].cross(b.basis[bb]))
	var apart := b.origin-a.origin
	for axis: Vector3 in axes:
		if axis.length_squared()<.000001: continue
		axis=axis.normalized()
		var radius_a := .0
		var radius_b := .0
		for index in 3:
			radius_a+=absf(axis.dot(a.basis[index]))*a_size[index]*.5
			radius_b+=absf(axis.dot(b.basis[index]))*b_size[index]*.5
		if absf(axis.dot(apart))>=radius_a+radius_b-.0005: return false
	return true

static func _segment_box(a: Vector3,b: Vector3,box: Transform3D,size: Vector3,radius: float) -> bool:
	# Conservative finite capsule versus full oriented box, covering the whole
	# link rather than leaving holes between joint/sample spheres.
	var inverse:=box.affine_inverse()
	var start: Vector3=inverse*a
	var direction: Vector3=inverse*b-start
	var half:=size*.5+Vector3.ONE*radius
	var low:=.0
	var high:=1.0
	for axis in 3:
		if absf(direction[axis])<.000001:
			if absf(start[axis])>half[axis]: return false
		else:
			var near:=(-half[axis]-start[axis])/direction[axis]
			var far:=(half[axis]-start[axis])/direction[axis]
			low=maxf(low,minf(near,far))
			high=minf(high,maxf(near,far))
			if low>high: return false
	return true

static func _segment_distance(a: Vector3,b: Vector3,c: Vector3,d: Vector3) -> float:
	var ab:=b-a
	var cd:=d-c
	var ac:=a-c
	var aa:=ab.length_squared()
	var cc:=cd.length_squared()
	var coupling:=ab.dot(cd)
	var e:=cd.dot(ac)
	var f:=ab.dot(ac)
	var denominator:=aa*cc-coupling*coupling
	var s:=clampf((coupling*e-cc*f)/denominator,0.0,1.0) if denominator>.000001 else .0
	var t:=clampf((coupling*s+e)/cc,0.0,1.0) if cc>.000001 else .0
	if aa>.000001: s=clampf((coupling*t-f)/aa,0.0,1.0)
	return (a+ab*s).distance_to(c+cd*t)

func _finite_wheel_shape(shape: Shape3D) -> bool:
	if shape is CylinderShape3D:
		return is_finite(shape.radius) and is_finite(shape.height) and shape.radius>0.0 and shape.height>0.0
	if shape is BoxShape3D:
		return shape.size.is_finite() and shape.size.x>0.0 and shape.size.y>0.0 and shape.size.z>0.0
	if shape is ConvexPolygonShape3D:
		if shape.points.size()<4: return false
		var bounds:=AABB(shape.points[0],Vector3.ZERO)
		for point: Vector3 in shape.points:
			if not point.is_finite(): return false
			bounds=bounds.expand(point)
		return bounds.size.x>0.0 and bounds.size.y>0.0 and bounds.size.z>0.0
	return false

func _original_wheel_cargo_clear(cargo_pose: Transform3D,box_query: PhysicsShapeQueryParameters3D,space: PhysicsDirectSpaceState3D) -> bool:
	if not is_instance_valid(part) or part.kind!="wheel" or not cargo_pose.is_finite(): return false
	var native_query:=PhysicsShapeQueryParameters3D.new()
	native_query.collision_mask=box_query.collision_mask
	native_query.exclude=box_query.exclude
	native_query.margin=.015
	var enabled:=0
	var source_rid: RID=part.get_rid()
	for index: int in PhysicsServer3D.body_get_shape_count(source_rid):
		var owner: int=part.shape_find_owner(index)
		if part.is_shape_owner_disabled(owner): continue
		var shape_rid: RID=PhysicsServer3D.body_get_shape(source_rid,index)
		if not shape_rid.is_valid(): return false
		var resource: Shape3D
		for owner_index: int in part.shape_owner_get_shape_count(owner):
			var candidate: Shape3D=part.shape_owner_get_shape(owner,owner_index)
			if candidate!=null and candidate.get_rid()==shape_rid:
				resource=candidate
				break
		if resource==null or not _finite_wheel_shape(resource): return false
		var local: Transform3D=PhysicsServer3D.body_get_shape_transform(source_rid,index)
		if not local.is_finite() or local.basis.determinant()<=0.0: return false
		native_query.shape_rid=shape_rid
		native_query.transform=cargo_pose*local
		if not native_query.transform.is_finite(): return false
		if not space.intersect_shape(native_query,1).is_empty(): return false
		enabled+=1
	return enabled>0

func _arc_hit_facts(hits: Array) -> Array[Dictionary]:
	var result: Array[Dictionary]=[]
	for hit: Dictionary in hits:
		var collider: Variant=hit.get("collider")
		result.append({"body":str(collider.get_path()) if is_instance_valid(collider) and collider is Node else str(collider),
			"rid":str(hit.get("rid")),"shape":hit.get("shape"),"part_id":str(collider.get("part_id")) if is_instance_valid(collider) else "",
			"stored":collider.get_meta(&"stored",false) if is_instance_valid(collider) else null})
	return result

func _observe_cargo_refusal(time: float,cargo_pose: Transform3D,query: PhysicsShapeQueryParameters3D,hits: Array,space: PhysicsDirectSpaceState3D) -> void:
	# Read-only causal comparison at the EXACT rejected original cargo pose.
	# Every production guard/admission result above remains unchanged.
	if not is_instance_valid(part) or not part.is_inside_tree() or _cargo_refusal_rows>=256: return
	var source_rid: RID=part.get_rid()
	var assembly_id: int=part.assembly.get_instance_id() if is_instance_valid(part.assembly) else 0
	var state_key: String=str([source_rid,bool(part.installed),assembly_id,bool(part.get_meta(&"stored",false))])
	var state_rows: int=int(_cargo_refusal_state_rows.get(state_key,0))
	if state_rows>=8: return
	_cargo_refusal_state_rows[state_key]=state_rows+1
	_cargo_refusal_rows+=1
	var native_samples: Array[Dictionary]=[]
	var native_query:=PhysicsShapeQueryParameters3D.new()
	native_query.collision_mask=query.collision_mask
	native_query.exclude=query.exclude
	# Same 15 mm face clearance as the production box's 30 mm total padding.
	# Use all ENABLED original native shapes without modifying any resource.
	native_query.margin=.015
	for shape_index: int in PhysicsServer3D.body_get_shape_count(source_rid):
		if part.is_shape_owner_disabled(part.shape_find_owner(shape_index)): continue
		var shape_rid: RID=PhysicsServer3D.body_get_shape(source_rid,shape_index)
		var local: Transform3D=PhysicsServer3D.body_get_shape_transform(source_rid,shape_index)
		native_query.shape_rid=shape_rid
		native_query.transform=cargo_pose*local
		var native_hits: Array=space.intersect_shape(native_query,1)
		native_samples.append({"index":shape_index,"shape_rid":str(shape_rid),"shape_type":PhysicsServer3D.shape_get_type(shape_rid),
			"local":part.encode_transform(local),"planned":part.encode_transform(native_query.transform),"margin":native_query.margin,
			"hits":_arc_hit_facts(native_hits)})
	var native:=PhysicsServer3D.body_get_direct_state(source_rid)
	print("HEAD_CARGO_REFUSAL ",JSON.stringify({"scope":"read-only same-pose comparison at the rejected padded cargo box",
		"worker":worker.worker_id,"job":worker.current_job_id,"source":part.part_id,"kind":part.kind,"source_instance":part.get_instance_id(),
		"source_installed":part.installed,"source_assembly_id":assembly_id,"source_stored":part.get_meta(&"stored",false),"source_state_sample":state_rows+1,
		"source_rid":str(source_rid),"source_mass":part.mass,"source_actual":part.encode_transform(part.global_transform),
		"source_native":part.encode_transform(native.transform) if native else null,"source_native_linear":part.encode_vector(native.linear_velocity) if native else null,
		"source_native_angular":part.encode_vector(native.angular_velocity) if native else null,"source_carrier":str(part.carrier),
		"worker_pose":part.encode_transform(worker.global_transform),"worker_ground":part.encode_vector(worker._ground_point),"worker_on_ground":worker.on_ground,
		"time":time,"flight_seconds":_flight_seconds,"rotation_axis":part.encode_vector(_rotation_axis),"rotation_angle":_rotation_angle,
		"cargo_pose":part.encode_transform(cargo_pose),"box_transform":part.encode_transform(query.transform),"box_size":part.encode_vector(_stock_bounds.size+Vector3.ONE*.03),
		"production_hits":_arc_hit_facts(hits),"native_shape_count":PhysicsServer3D.body_get_shape_count(source_rid),"enabled_native_samples":native_samples,
		"native_same_pose_all_clear":not native_samples.is_empty() and native_samples.all(func(row:Dictionary)->bool:return row.hits.is_empty())}))


static func _gun_constituent_box_valid(pose: Transform3D, size: Vector3, native: bool) -> bool:
	var determinant := pose.basis.determinant()
	if not pose.is_finite() or not is_finite(determinant) or determinant <= 0.0 or not size.is_finite(): return false
	if native:
		return size.x > 0.0 and size.y > 0.0 and size.z > 0.0 and pose.basis.is_equal_approx(pose.basis.orthonormalized())
	return size.x >= 0.0 and size.y >= 0.0 and size.z >= 0.0 \
		and absf(pose.basis.x.normalized().dot(pose.basis.y.normalized())) < .00001 \
		and absf(pose.basis.x.normalized().dot(pose.basis.z.normalized())) < .00001 \
		and absf(pose.basis.y.normalized().dot(pose.basis.z.normalized())) < .00001

func _capture_gun_head_constituents() -> void:
	_gun_head_geometry.clear()
	if crew.size() != 1 or part.kind != "gun" or not is_instance_valid(part.visual): return
	var source_rid: RID = part.get_rid()
	if not source_rid.is_valid(): return
	var native_shapes: Array[Dictionary] = []
	var boxes: Array[Dictionary] = []
	var enabled := 0
	for index: int in PhysicsServer3D.body_get_shape_count(source_rid):
		var owner: int = part.shape_find_owner(index)
		var disabled: bool = part.is_shape_owner_disabled(owner)
		var shape_rid: RID = PhysicsServer3D.body_get_shape(source_rid,index)
		var local: Transform3D = PhysicsServer3D.body_get_shape_transform(source_rid,index)
		var resource: Shape3D
		for owner_index: int in part.shape_owner_get_shape_count(owner):
			var candidate: Shape3D = part.shape_owner_get_shape(owner,owner_index)
			if candidate != null and candidate.get_rid() == shape_rid:
				resource = candidate
				break
		var box_shape := resource as BoxShape3D
		if not disabled:
			if not shape_rid.is_valid() or box_shape == null or not _gun_constituent_box_valid(local,box_shape.size,true) \
				or PhysicsServer3D.shape_get_type(shape_rid) != PhysicsServer3D.SHAPE_BOX \
				or PhysicsServer3D.shape_get_data(shape_rid) != box_shape.size*.5: return
			boxes.append({"pose":local,"size":box_shape.size})
			enabled += 1
		native_shapes.append({"owner":owner,"disabled":disabled,"rid":shape_rid,"local":local,
			"resource":resource,"size":box_shape.size if box_shape else Vector3.ZERO})
	if enabled == 0: return
	var nodes: Array[Dictionary] = []
	var meshes: Array[Dictionary] = []
	var pending: Array[Node] = [part.visual]
	var visual_count := 0
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		# Unknown MultiMesh envelopes keep the original refusal.
		if node is MultiMeshInstance3D: return
		nodes.append({"node":node,"parent":node.get_parent(),"children":node.get_child_count(true)})
		pending.append_array(node.get_children(true))
		if node is MeshInstance3D:
			var local: Transform3D = StockBounds._local_pose(part,node)
			var box: AABB = node.mesh.get_aabb() if node.mesh != null else AABB()
			meshes.append({"node":node,"resource":node.mesh,"local":local,"box":box})
			if node.mesh == null: continue
			var pose := local*Transform3D(Basis.IDENTITY,box.get_center())
			if not box.position.is_finite() or not _gun_constituent_box_valid(pose,box.size,false): return
			boxes.append({"pose":pose,"size":box.size})
			visual_count += 1
	if visual_count == 0: return
	_gun_head_geometry = {"source":part,"rid":source_rid,"visual":part.visual,
		"native":native_shapes,"nodes":nodes,"meshes":meshes,"boxes":boxes}

func _gun_head_geometry_current() -> bool:
	if _gun_head_geometry.is_empty() or not is_instance_valid(part) or crew.size() != 1 or part.kind != "gun": return false
	if part != _gun_head_geometry.source or part.get_rid() != _gun_head_geometry.rid \
		or not is_instance_valid(part.visual) or part.visual != _gun_head_geometry.visual \
		or not part.global_basis.get_scale().is_equal_approx(Vector3.ONE): return false
	var source_rid: RID = part.get_rid()
	if PhysicsServer3D.body_get_shape_count(source_rid) != _gun_head_geometry.native.size(): return false
	for index: int in _gun_head_geometry.native.size():
		var saved: Dictionary = _gun_head_geometry.native[index]
		if part.shape_find_owner(index) != saved.owner or part.is_shape_owner_disabled(saved.owner) != saved.disabled \
			or PhysicsServer3D.body_get_shape(source_rid,index) != saved.rid \
			or PhysicsServer3D.body_get_shape_transform(source_rid,index) != saved.local: return false
		if not saved.disabled:
			var resource: Variant = saved.resource
			if not is_instance_valid(resource) or not resource is BoxShape3D \
				or resource.get_rid() != saved.rid or resource.size != saved.size \
				or PhysicsServer3D.shape_get_type(saved.rid) != PhysicsServer3D.SHAPE_BOX \
				or PhysicsServer3D.shape_get_data(saved.rid) != saved.size*.5: return false
	for saved: Dictionary in _gun_head_geometry.nodes:
		var node: Variant = saved.node
		if not is_instance_valid(node) or not node.is_inside_tree() or node.get_parent() != saved.parent \
			or node.get_child_count(true) != saved.children: return false
	for saved: Dictionary in _gun_head_geometry.meshes:
		var node: Variant = saved.node
		if not is_instance_valid(node) or node.mesh != saved.resource \
			or StockBounds._local_pose(part,node) != saved.local: return false
		if node.mesh != null and node.mesh.get_aabb() != saved.box: return false
	return true

func _gun_head_constituents_clear(time: float, head: Transform3D, head_size: Vector3, boxes: Array[Dictionary]) -> bool:
	if boxes.is_empty() or not is_instance_valid(part) or crew.size() != 1 or part.kind != "gun": return false
	var source_pose := _planned_group_head(time)*_cargo_local
	if not source_pose.is_finite() or not is_finite(source_pose.basis.determinant()) or source_pose.basis.determinant() <= 0.0 \
		or not head.is_finite() or not is_finite(head.basis.determinant()) or head.basis.determinant() <= 0.0 \
		or not head_size.is_finite() or head_size.x <= 0.0 or head_size.y <= 0.0 or head_size.z <= 0.0: return false
	for box: Dictionary in boxes:
		if _boxes_overlap(source_pose*box.pose,box.size,head,head_size): return false
	return true

func _observe_original_gun_head_overlap(time: float,cargo: Transform3D,head: Transform3D,head_size: Vector3) -> void:
	# Observe the EXACT rejected union-box SAT. No extra space query or admission.
	if "--easy-island-gun-controls" not in _args or not is_instance_valid(part) \
		or part.part_id!="stock_16" or part.kind!="gun" or not worker.current_job_id.begins_with("build:"): return
	var source_rid: RID=part.get_rid()
	var key:=str(source_rid)+":head_overlap"
	var sample:=int(_contact_face_probe_rows.get(key,0))
	if sample>=8: return
	_contact_face_probe_rows[key]=sample+1
	var planned_head:=_planned_group_head(time)
	var source_pose:=planned_head*_cargo_local
	var live_head:=contact_frame()
	var source_native:=PhysicsServer3D.body_get_direct_state(source_rid)
	var worker_native:=PhysicsServer3D.body_get_direct_state(worker.get_rid())
	var native_shapes: Array[Dictionary]=[]
	var all_native_clear:=true
	for index: int in PhysicsServer3D.body_get_shape_count(source_rid):
		var owner: int=part.shape_find_owner(index)
		if part.is_shape_owner_disabled(owner): continue
		var shape_rid: RID=PhysicsServer3D.body_get_shape(source_rid,index)
		var resource: Shape3D
		for owner_index: int in part.shape_owner_get_shape_count(owner):
			var candidate: Shape3D=part.shape_owner_get_shape(owner,owner_index)
			if candidate!=null and candidate.get_rid()==shape_rid:
				resource=candidate
				break
		var box_shape:=resource as BoxShape3D
		var local: Transform3D=PhysicsServer3D.body_get_shape_transform(source_rid,index)
		var supported: bool=shape_rid.is_valid() and box_shape!=null and box_shape.size.is_finite() \
			and box_shape.size.x>0.0 and box_shape.size.y>0.0 and box_shape.size.z>0.0 \
			and local.is_finite() and local.basis.determinant()>0.0 and local.basis.is_equal_approx(local.basis.orthonormalized())
		var intersects: Variant=_boxes_overlap(source_pose*local,box_shape.size,head,head_size) if supported else null
		all_native_clear=all_native_clear and supported and intersects==false
		native_shapes.append({"index":index,"rid":str(shape_rid),"resource":resource.get_class() if resource else "missing", \
			"supported":supported,"size":part.encode_vector(box_shape.size) if box_shape!=null else null, \
			"pose":part.encode_transform(source_pose*local),"head_overlap":intersects})
	var visual_count:=0
	var all_visual_clear:=true
	var visual_hits: Array[Dictionary]=[]
	for node: MeshInstance3D in part.visual.find_children("*","MeshInstance3D",true,false):
		if node.mesh==null: continue
		var box: AABB=node.mesh.get_aabb()
		var pose:=source_pose*StockBounds._local_pose(part,node)*Transform3D(Basis.IDENTITY,box.get_center())
		var supported: bool=box.position.is_finite() and box.size.is_finite() and box.size.x>=0.0 and box.size.y>=0.0 and box.size.z>=0.0 \
			and pose.is_finite() and pose.basis.determinant()>0.0 \
			and absf(pose.basis.x.normalized().dot(pose.basis.y.normalized()))<.00001 \
			and absf(pose.basis.x.normalized().dot(pose.basis.z.normalized()))<.00001 \
			and absf(pose.basis.y.normalized().dot(pose.basis.z.normalized()))<.00001
		var intersects: Variant=_boxes_overlap(pose,box.size,head,head_size) if supported else null
		visual_count+=1
		all_visual_clear=all_visual_clear and supported and intersects==false
		if not supported or intersects==true:
			visual_hits.append({"node":str(node.get_path()),"supported":supported,"pose":part.encode_transform(pose),"size":part.encode_vector(box.size),"head_overlap":intersects})
	# The original bounds also include MultiMeshes. Do not claim clear coverage
	# if this particular source contains any; that case remains unsupported.
	var multi_meshes: Array=part.visual.find_children("*","MultiMeshInstance3D",true,false)
	print("HEAD_ORIGINAL_GUN_OVERLAP ",JSON.stringify({"source":part.part_id,"source_rid":str(source_rid),"worker":worker.worker_id, \
		"job":worker.current_job_id,"tick":Engine.get_physics_frames(),"sample":sample+1,"time":time, \
		"source_current_pose":part.encode_transform(part.global_transform),"planned_source_pose":part.encode_transform(source_pose), \
		"source_native_pose":part.encode_transform(source_native.transform) if source_native else null, \
		"worker_native_pose":part.encode_transform(worker_native.transform) if worker_native else null, \
		"live_contact_root_pose":part.encode_transform(_actual_root()),"live_contact_head_pose":part.encode_transform(live_head), \
		"planned_head_pose":part.encode_transform(planned_head),"captured_cargo_local":part.encode_transform(_cargo_local), \
		"saved_launch_pose":part.encode_transform(_home),"stock_bounds_position":part.encode_vector(_stock_bounds.position), \
		"union_pose":part.encode_transform(cargo),"union_size":part.encode_vector(_stock_bounds.size), \
		"head_pose":part.encode_transform(head),"head_size":part.encode_vector(head_size), \
		"contact_local":part.encode_vector(contact_local),"contact_normal":part.encode_vector(contact_normal), \
		"skin_gap":contact_surface_gap,"skin_penetration":contact_surface_penetration,"unchanged_tolerance":_contact_tolerance(), \
		"enabled_native_shapes":native_shapes,"all_native_boxes_clear":not native_shapes.is_empty() and all_native_clear, \
		"visual_mesh_count":visual_count,"visual_box_hits":visual_hits,"multi_mesh_count":multi_meshes.size(), \
		"all_visual_boxes_clear":visual_count>0 and all_visual_clear and multi_meshes.is_empty()}))




func _crew_clear(time: float, with_cargo: bool, gun_head_boxes: Array[Dictionary] = [], own_body:=Transform3D.IDENTITY, own_legs: Array[Vector3]=[]) -> bool:
	# The caller already computed this exact sample. Standalone diagnostics
	# retain their original private-call behavior; no admitted pose is skipped.
	if own_legs.is_empty():
		_refresh_samples()
		own_legs=_sample(time)[1]
		own_body=_sample(time)[0]
	var own_cube := own_body*_root_at(time)
	var cube_size := Vector3(.76,_head_height*2.0,.76)
	var cargo := _planned_group_head(time)*_cargo_local*Transform3D(Basis.IDENTITY,_stock_bounds.get_center()) if with_cargo else Transform3D.IDENTITY
	var holder:=own_body*_holder_frame(time)*Transform3D(Basis.IDENTITY,_holder_bounds.get_center())
	var holder_low:=own_body*_holder_frame(time)*Transform3D(Basis.IDENTITY,_holder_source_bounds.get_center())
	if with_cargo and _holder_source_bounds.has_volume() and _boxes_overlap(cargo,_stock_bounds.size,holder_low,_holder_source_bounds.size): arc_failure="shared stock crosses permanent back holder at %.3fs" % time; return false
	var has_tool:=is_instance_valid(worker.equipped_tool)
	var tool:=own_body*_tool_local*Transform3D(Basis.IDENTITY,_tool_bounds.get_center()) if has_tool else Transform3D.IDENTITY
	if with_cargo and has_tool and _boxes_overlap(cargo,_stock_bounds.size,tool,_tool_bounds.size): arc_failure="shared stock crosses retained tool at %.3fs" % time; return false
	# The tucked finite links must also clear the helper's own complete back
	# hardware/tool. A tuck is never just a visual pose outside preflight.
	for side in 2:
		for link in 2:
			var a: Vector3 = own_body*own_legs[side*3+link]
			var b: Vector3 = own_body*own_legs[side*3+link+1]
			if _own_holder_intersects(own_legs[side*3+link],own_legs[side*3+link+1],_holder_frame(time)): arc_failure="tucked leg crosses original back holder at %.3fs" % time; return false
			if has_tool and _segment_box(a,b,tool,_tool_bounds.size,.085): arc_failure="tucked leg crosses original retained tool at %.3fs" % time; return false
			if link==1 and _segment_box(a,b,own_cube,cube_size,.085): arc_failure="tucked lower leg crosses own head at %.3fs" % time; _observe_stunt_clearance(time,side,own_legs); return false
	if with_cargo:
		if _boxes_overlap(cargo,_stock_bounds.size,own_cube,cube_size):
			_observe_original_gun_head_overlap(time,cargo,own_cube,cube_size)
			# A gun's combined bounds can enclose empty space. Only the
			# complete unchanged native AND visible constituents may recover
			# that rejection, against this same real head and SAT tolerance.
			if not _gun_head_constituents_clear(time,own_cube,cube_size,gun_head_boxes):
				arc_failure="stock crosses carrying head at %.3fs" % time
				return false
		for side in 2:
			for link in 2:
				if _segment_box(own_body*own_legs[side*3+link],own_body*own_legs[side*3+link+1],cargo,_stock_bounds.size,.085): arc_failure="stock crosses carrying leg at %.3fs" % time; return false
	# Each pair is checked once, both ways, by its lower-index member (the
	# partner's own pass would repeat the same mirrored tests).
	var own_index := crew.find(worker)
	for member: Node in crew:
		if member==worker or crew.find(member)<own_index: continue
		var other: RefCounted=member.head_leap
		var other_sample: Array = other._sample(time)
		var other_body: Transform3D=other_sample[0]
		var other_legs: Array[Vector3]=other_sample[1]
		var other_cube: Transform3D=other_sample[2]
		if _boxes_overlap(own_cube,cube_size,other_cube,cube_size): arc_failure="cooperative heads/body cross at %.3fs" % time; return false
		if with_cargo and _boxes_overlap(cargo,_stock_bounds.size,other_cube,cube_size): arc_failure="shared stock crosses partner head at %.3fs" % time; return false
		var other_holder: Transform3D=other_body*other._holder_frame(time)*Transform3D(Basis.IDENTITY,other._holder_bounds.get_center())
		if _boxes_overlap(holder,_holder_bounds.size,other_cube,cube_size) or _boxes_overlap(own_cube,cube_size,other_holder,other._holder_bounds.size): arc_failure="permanent back holder crosses partner head at %.3fs" % time; return false
		if _boxes_overlap(holder,_holder_bounds.size,other_holder,other._holder_bounds.size): arc_failure="cooperative back holders cross at %.3fs" % time; return false
		var other_low: Transform3D=other_body*other._holder_frame(time)*Transform3D(Basis.IDENTITY,other._holder_source_bounds.get_center())
		if with_cargo and other._holder_source_bounds.has_volume() and _boxes_overlap(cargo,_stock_bounds.size,other_low,other._holder_source_bounds.size): arc_failure="shared stock crosses partner back holder at %.3fs" % time; return false
		var other_has_tool:=is_instance_valid(member.equipped_tool)
		var other_tool: Transform3D=other_body*other._tool_local*Transform3D(Basis.IDENTITY,other._tool_bounds.get_center()) if other_has_tool else Transform3D.IDENTITY
		if with_cargo and other_has_tool and _boxes_overlap(cargo,_stock_bounds.size,other_tool,other._tool_bounds.size): arc_failure="shared stock crosses partner tool at %.3fs" % time; return false
		if other_has_tool and _boxes_overlap(other_tool,other._tool_bounds.size,own_cube,cube_size): arc_failure="partner retained tool crosses head at %.3fs" % time; return false
		for side in 2:
			for link in 2:
				var c: Vector3=own_body*own_legs[side*3+link]
				var d: Vector3=own_body*own_legs[side*3+link+1]
				if _segment_box(c,d,other_holder,other._holder_bounds.size,.085): arc_failure="leg crosses partner back holder at %.3fs" % time; return false
				if _segment_box(c,d,other_cube,cube_size,.085): arc_failure="leg crosses partner head at %.3fs" % time; return false
				if other_has_tool and _segment_box(c,d,other_tool,other._tool_bounds.size,.085): arc_failure="leg crosses partner tool at %.3fs" % time; return false
		if has_tool:
			if _boxes_overlap(tool,_tool_bounds.size,other_cube,cube_size): arc_failure="retained tool crosses partner head at %.3fs" % time; return false
			if other_has_tool:
				if _boxes_overlap(tool,_tool_bounds.size,other_tool,other._tool_bounds.size): arc_failure="cooperative retained tools cross at %.3fs" % time; return false
		for side in 2:
			for link in 2:
				var a: Vector3=other_body*other_legs[side*3+link]
				var b: Vector3=other_body*other_legs[side*3+link+1]
				if _segment_box(a,b,holder,_holder_bounds.size,.085): arc_failure="partner leg crosses permanent back holder at %.3fs" % time; return false
				if _segment_box(a,b,own_cube,cube_size,.085): arc_failure="partner leg crosses head at %.3fs" % time; return false
				if with_cargo and _segment_box(a,b,cargo,_stock_bounds.size,.085): arc_failure="stock crosses partner leg at %.3fs" % time; return false
				if has_tool and _segment_box(a,b,tool,_tool_bounds.size,.085): arc_failure="tool crosses partner leg at %.3fs" % time; return false
				for own_side in 2:
					for own_link in 2:
						var c: Vector3=own_body*own_legs[own_side*3+own_link]
						var d: Vector3=own_body*own_legs[own_side*3+own_link+1]
						if _segment_distance(a,b,c,d)<.17: arc_failure="cooperative legs cross at %.3fs" % time; return false
	return true

func _absorb_profile() -> Dictionary:
	# Heavy shared loads absorb deeper and recover more slowly.
	return CREW_ABSORB if crew.size()>1 or not _small_stock_timing() else ABSORB

func _rise_duration() -> float:
	return _rise_seconds if _rise_seconds>0.0 else float(_absorb_profile().recover)

func _absorb_bottom_time() -> float:
	# One constant deceleration from the measured impact speed to the bottom.
	return clampf(2.0*_absorb_depth/maxf(_impact_speed,.1),.09,.16)

func _absorb_drop(age: float) -> float:
	var bottom := _absorb_bottom_time()
	if age>=bottom: return _absorb_depth
	var speed := 2.0*_absorb_depth/bottom
	return speed*age-speed*age*age/(2.0*bottom)

func grounded_stunt_root(pose: SkeletonModifier3D, sk: Skeleton3D, authored: Transform3D) -> Transform3D:
	# The gather is the native body's own crouch (the cube rides it); only the
	# touchdown absorb shapes the Pose-owned root, after actual landing support.
	var gather := .0
	var lean := .0
	var axis := -_outbound_axis
	var age := _impact_age
	if state in ["done","failed"] and _finish_frame>=0 and _finish_age>=0.0 and _finish_age<9.0:
		# The rise curve continues through the hand-off to the ordinary carry.
		age = _finish_age+float(Engine.get_physics_frames()-_finish_frame)/float(Engine.physics_ticks_per_second)
		var absorb_tail: Dictionary = _absorb_profile()
		if age>_absorb_bottom_time()+float(absorb_tail.hold)+_rise_duration(): _finish_frame = -1
	if (state=="landing" and _impact_age>=.0) or (state in ["done","failed"] and _finish_frame>=0):
		# Velocity-continuous absorb: the visual root keeps the measured impact
		# speed and decelerates once, monotonically, to the bottom (whatever the
		# native spring does underneath), holds, then recovers more slowly.
		var absorb: Dictionary = _absorb_profile()
		var hold_end := _absorb_bottom_time()+float(absorb.hold)
		var normal: Vector3 = worker.ground_normal
		var envelope := _absorb_drop(age)/maxf(_absorb_depth,.001)
		var authored_height: float = normal.dot(sk.global_transform*authored.origin)
		if age<=hold_end:
			gather = maxf(authored_height-(normal.dot(_impact_root)-_absorb_drop(age)),0.0)
		else:
			# Rise from the absorb's WORLD bottom to the moving authored stance:
			# zero velocity at both ends, whatever the native spring does.
			var span := maxf(authored_height-(normal.dot(_impact_root)-_absorb_depth),0.0)
			if _rise_seconds<0.0:
				# Sized for the whole climb back to the standing cube height
				# (the native body is still rising under its spring).
				var stand_span: float = normal.dot(_home*_rest_root_local.origin)-(normal.dot(_impact_root)-_absorb_depth)
				_rise_seconds = clampf(1.5*maxf(span,stand_span)/RISE_SPEED,float(absorb.recover),.9)
			envelope = 1.0-smoothstep(hold_end,hold_end+_rise_duration(),age)
			gather = span*envelope
		# The touchdown drift rocks the cube back (toward home) over its heels.
		var drift := _impact_drift.length()
		lean = (ABSORB_ROCK+DRIFT_ROCK*clampf(drift,0.0,1.2))*envelope
		if drift>.05: axis = Vector3.UP.cross(_impact_drift/drift)
	else: return authored
	if (gather<.00001 and lean<.0001) or not worker.on_ground or not pose.evaluated_valid: return authored
	var wanted := authored
	wanted.origin -= sk.global_basis.inverse()*worker.ground_normal*gather
	var local_axis: Vector3 = sk.global_basis.inverse()*axis.slide(worker.ground_normal)
	if lean>.0001 and local_axis.length_squared()>.000001:
		# Pitch about the hip line so the cube tips toward the stock over its feet.
		var pivot := Vector3.ZERO
		for side in 2: pivot += sk.get_bone_global_pose(pose._chains[side][0]).origin*.5
		pivot = wanted.origin+(pivot-authored.origin)
		var turn := Basis(local_axis.normalized(),lean)
		wanted.basis = turn*wanted.basis
		wanted.origin = pivot+turn*(wanted.origin-pivot)
	var native_rebase: Transform3D = worker.global_transform*pose.evaluated_worker.affine_inverse()
	# Reuse the unchanged true plant/reach reserve and complete stored-tool
	# admission. The caller still applies its finite position/6 rad/s caps.
	for side in 2:
		var hip: Vector3 = authored.affine_inverse()*sk.get_bone_global_pose(pose._chains[side][0]).origin
		var ankle: Vector3 = sk.global_transform.affine_inverse()*(native_rebase*(pose.evaluated_soles[side]-pose.evaluated_ankles[side]*Vector3(0,pose._ankle_height[side],0)))
		if (wanted*hip).distance_to(ankle)>worker._leg_lengths[side]-.012: return authored
	if worker.back_tool and is_instance_valid(worker.equipped_tool) and not worker.back_tool.travel_frame_clear(sk.global_transform*wanted*(native_rebase*pose.evaluated_root).affine_inverse()): return authored
	return wanted

func _return_phase() -> bool:
	return _planning_return or _return_started

# --- Leg geometry in the cube (root bone) frame -----------------------------
func _capture_rest_geometry() -> void:
	var pose: SkeletonModifier3D = worker._pose
	var sk: Skeleton3D = worker._skeleton
	_rest_root_local = pose.evaluated_worker.affine_inverse()*pose.evaluated_root
	_rest_root_local.basis = _rest_root_local.basis.orthonormalized()
	var root_inverse: Transform3D = pose.evaluated_root.affine_inverse()
	var root_basis: Basis = pose.evaluated_root.basis.orthonormalized().inverse()
	_hip_root.clear()
	_ankle_rest_root.clear()
	_shin_rest_root.clear()
	_toe_ankle.clear()
	_rest_toe.clear()
	_rest_ankle.clear()
	for side in 2:
		var hip: Vector3 = pose.evaluated_hips[side]
		var knee: Vector3 = pose.evaluated_knees[side]
		var ankle: Vector3 = pose.evaluated_soles[side]-pose.evaluated_ankles[side]*Vector3(0,pose._ankle_height[side],0)
		_hip_root.append(root_inverse*hip)
		_leg_upper[side] = hip.distance_to(knee)
		_leg_lower[side] = knee.distance_to(ankle)
		_ankle_rest_root.append((root_basis*pose.evaluated_ankles[side].orthonormalized()).orthonormalized())
		_shin_rest_root.append((root_basis*(ankle-knee)).normalized())
		# The toe joint in its ankle frame, as the rig authors it (either way).
		var toe: int = pose._toes[side] if side<pose._toes.size() else -1
		var offset := Vector3.ZERO
		if toe>=0 and sk and sk.get_bone_parent(toe)==int(pose._chains[side][2]): offset = sk.get_bone_rest(toe).origin
		_toe_ankle.append(offset)
		# Standing ankle and ball of the foot (toe joint), body-local.
		var body: Transform3D = pose.evaluated_worker.affine_inverse()
		_rest_ankle.append(body*ankle)
		_rest_toe.append(body*(ankle+pose.evaluated_ankles[side]*offset))

func _face_root() -> Vector3:
	var face: Vector3 = _rest_root_local.basis.inverse()*_stunt_forward
	face.y = 0.0
	return face.normalized() if face.length_squared()>.000001 else Vector3.BACK

func _leg_from_angles(side: int, angles: Array) -> Array:
	# [hip flexion toward the face, knee flexion, adduction, foot point] ->
	# [knee, ankle, foot basis, point] in the cube frame. Knees bend toward the
	# face; the shin folds back; the foot rides with the shin, then points.
	var hip: Vector3 = _hip_root[side]
	var forward := _face_root()
	var down := Vector3.DOWN
	var outward := down.cross(forward).normalized()
	if outward.dot(hip)<0.0: outward = -outward
	var flex := float(angles[0])
	var adduct := float(angles[2])
	var thigh := (down*cos(flex)+forward*sin(flex))
	thigh = (thigh*cos(adduct)-outward*sin(adduct)).normalized()
	var knee := hip+thigh*_leg_upper[side]
	var hinge := thigh.cross(forward)
	if hinge.length_squared()<.000001: hinge = -outward
	hinge = hinge.normalized()
	var shin := thigh.rotated(hinge,-float(angles[1]))
	var ankle := knee+shin*_leg_lower[side]
	var foot := Basis(Quaternion(_shin_rest_root[side],shin))*_ankle_rest_root[side]
	var point := float(angles[3])
	if point>.0001 and _toe_ankle[side].length_squared()>.000001:
		var toe := (foot*_toe_ankle[side]).normalized()
		var axis := toe.cross(shin)
		if axis.length_squared()>.000001: foot = Basis(axis.normalized(),minf(point,toe.angle_to(shin)))*foot
	return [knee,ankle,foot.orthonormalized(),point]

static func _angles_lerp(from: Array, to: Array, weight: float) -> Array:
	var result: Array = []
	for index in 4: result.append(lerpf(float(from[index]),float(to[index]),weight))
	return result

func _tuck_angles(hold := 0.0) -> Array:
	var angles := _angles_lerp(LEG_TUCK_LOW,LEG_PIKE if crew.size()>1 else LEG_TUCK,_stunt_capacity)
	# The moving hold deepens the fitted tuck (hold 0..1).
	for index in 4: angles[index] = float(angles[index])+float(TUCK_HOLD[index])*hold*_stunt_capacity
	angles[2] = float(angles[2])-_splay
	# A crew partner tucks a few degrees shallower (fitted with it).
	angles[0] = float(angles[0])-TWIN_ANGLE*_twin
	return angles

const LEG_WHIP_POSE := [deg_to_rad(-12.0),deg_to_rad(70.0),0.0,deg_to_rad(50.0)]
# The whip-over overshoots past the pike and settles back (a moving hold on
# the head, never identical frames before the kick).
const WHIP_OVERSHOOT := [deg_to_rad(-5.0),deg_to_rad(6.0),0.0,0.0]

func _splay_follow(knee: float, splay_add: float, other_add: float, other_knee: float) -> float:
	# Thigh abduction tied to the knee fold: closed (other_add) while the knee
	# is open, the fitted splay only once the knee has folded past 110 deg.
	var low := smoothstep(SPLAY_KNEE_FROM,SPLAY_KNEE_TO,other_knee)
	var span := 1.0-low
	var weight := clampf((smoothstep(SPLAY_KNEE_FROM,SPLAY_KNEE_TO,knee)-low)/span,0.0,1.0) if span>.0001 else 1.0
	return lerpf(other_add,splay_add,weight)

func _into_tuck(from: Array, weight: float, hold := 0.0) -> Array:
	# The knees lead: they fold first, the hips follow; any fitted splay opens
	# only with the knee fold (never straight legs held apart).
	var tuck := _tuck_angles(hold)
	var result := _angles_lerp(from,tuck,smoothstep(.1,1.0,weight))
	result[1] = lerpf(float(from[1]),float(tuck[1]),smoothstep(0.0,.75,weight))
	result[2] = _splay_follow(float(result[1]),float(tuck[2]),float(from[2]),float(from[1]))
	return result

func _out_of_tuck(to: Array, weight: float, hold := 1.0) -> Array:
	# Opening: the knees unfold first, the hips follow; a fitted splay closes
	# as the knee unfolds below 110 deg.
	var tuck := _tuck_angles(hold)
	var result := _angles_lerp(tuck,to,smoothstep(.15,1.0,weight))
	result[1] = lerpf(float(tuck[1]),float(to[1]),smoothstep(0.0,.8,weight))
	result[2] = _splay_follow(float(result[1]),float(tuck[2]),float(to[2]),float(to[1]))
	return result

func _open_window() -> Vector2:
	# Outbound leg opening [start, end]: it begins with the first assisted
	# arrival tick (a little before) and spreads over OPEN_SECONDS, ending a
	# short plant hold before the impact.
	var tucked := TRAIL_SECONDS+.01+TUCK_IN_SECONDS
	var end := maxf(_flight_seconds-PLANT_HOLD,tucked+.08)
	var start := clampf(_beat_assist-OPEN_ANTICIPATION,tucked+.04,end-.12)
	return Vector2(start,minf(start+OPEN_SECONDS,end))

func _outbound_angles(time: float) -> Array:
	# Trail off the toes, knees-first pike tuck, a moving hold that deepens
	# through the apex, then ONE open with the arrival brake into the legs-up
	# plant before the impact.
	var launch: Array = _launch_leg_pose if _launch_leg_pose.size()==4 else LEG_TRAIL
	var angles := _angles_lerp(launch,LEG_TRAIL,smoothstep(.0,TRAIL_SECONDS,time))
	var tuck_start := TRAIL_SECONDS+.01
	var tucked := tuck_start+TUCK_IN_SECONDS
	var window := _open_window()
	var hold := smoothstep(tucked,window.x,time)
	if time<window.x: return _into_tuck(angles,smoothstep(tuck_start,tucked,time),hold)
	return _out_of_tuck(LEG_TADA,smoothstep(window.x,window.y,time))

func _bare_angles(time: float) -> Array:
	# An interrupted fall recovery folds from wherever the legs were (knees
	# first) into the tuck, then opens to land.
	var start: Array = _restart_angles if _restart_angles.size()==4 else _tuck_angles()
	var land_start := maxf(.2,_flight_seconds*.6)
	var tucked := minf(.12,land_start*.6)
	var angles := _into_tuck(start,smoothstep(0.0,tucked,time),smoothstep(tucked,land_start,time)) if time<land_start else _out_of_tuck(LEG_LAND,smoothstep(land_start,maxf(_flight_seconds*.92,land_start+.1),time))
	angles[3] = float(angles[3])*smoothstep(.0,FOOT_FLATTEN_SECONDS,_flight_seconds-time)
	return angles

func _return_angles(time: float) -> Array:
	# From the impact whip (heavy loads first strain), the legs kick over past
	# the vertical toward home (toes pointed) while the supported head push
	# accelerates the body; knees-first tuck with a moving hold; open to land.
	if _plan_tier in ["bare","fall"]: return _bare_angles(time)
	var kick_start := maxf(_return_lead-RETURN_LEAD,0.0)
	var start: Array = _return_start_angles if _return_start_angles.size()==4 else LEG_WHIP_POSE
	var angles: Array = start
	if kick_start>0.0:
		angles = _angles_lerp(start,LEG_STRAIN,smoothstep(0.0,minf(kick_start*.6,.14),time))
		# The strain trembles a little under the load (a moving hold).
		var tremble := sin(TAU*7.0*maxf(time-.06,0.0))*smoothstep(.06,.14,time)*(1.0-smoothstep(kick_start*.85,kick_start,time))
		angles[1] = float(angles[1])+deg_to_rad(2.5)*tremble
	angles = _angles_lerp(angles,LEG_KICK,smoothstep(kick_start,kick_start+_kick_seconds(),time))
	var tuck_start := kick_start+_kick_seconds()+.01
	var tucked := tuck_start+TUCK_IN_SECONDS+.04
	var land_start := maxf(tucked+.06,_flight_seconds*.62)
	if time<land_start: angles = _into_tuck(angles,smoothstep(tuck_start,tucked,time),smoothstep(tucked,land_start,time))
	else: angles = _out_of_tuck(LEG_LAND,smoothstep(land_start,maxf(_flight_seconds*.92,land_start+.1),time))
	# Pointed in the air, flat soles for the last FOOT_FLATTEN_SECONDS.
	angles[3] = float(angles[3])*smoothstep(.0,FOOT_FLATTEN_SECONDS,_flight_seconds-time)
	return angles

func _capture_return_start() -> void:
	# The return's legs start from the whip/overshoot pose they are showing now.
	var age := _impact_clock if _impact_clock>=0.0 else _contact_age
	_return_start_angles = _contact_angles(maxf(age-TWIN_DELAY*.5*_twin,0.0))
	_squash_at_attach = _contact_squash(_impact_clock) if _impact_clock>=0.0 else 0.0

func _contact_angles(age: float) -> Array:
	# Impact: the legs whip past the vertical, overshoot a few degrees and
	# settle back toward the pike (the return's anticipation).
	var angles := _angles_lerp(LEG_TADA,LEG_WHIP_POSE,smoothstep(0.0,WHIP_SECONDS,age))
	var bump := smoothstep(WHIP_SECONDS*.5,WHIP_SECONDS+.02,age)-.6*smoothstep(WHIP_SECONDS+.02,WHIP_SECONDS+.12,age)
	for index in 4: angles[index] = float(angles[index])+float(WHIP_OVERSHOOT[index])*bump
	return angles

func _twin_time(time: float) -> float:
	# The follower's cosmetic legs lag ~4 frames and catch up before the end
	# of each flight phase (impact, touchdown): the shift is monotonic in time.
	if _twin<=0.0: return time
	var lag := TWIN_DELAY*_twin*clampf((_flight_seconds-time-.04)/.12,0.0,1.0)
	return maxf(time-lag,0.0)

func _leg_angles_at(time: float, posing: bool) -> Array:
	# A crew partner's cosmetic curve runs a few frames behind, a few degrees
	# apart: two creatures, one shared plan (preflight samples the same curve).
	var in_contact := posing and state=="contact" and not _planning_return
	if not in_contact: time = _twin_time(time)
	var angles: Array
	if in_contact:
		var age := _impact_clock if _impact_clock>=0.0 else _contact_age
		angles = _contact_angles(maxf(age-TWIN_DELAY*.5*_twin,0.0))
	elif _return_phase(): angles = _return_angles(time)
	else: angles = _outbound_angles(time)
	return angles

func _leg_pose_at(time: float, posing := false) -> Array:
	var angles := _leg_angles_at(time,posing)
	var result: Array = []
	for side in 2: result.append(_leg_from_angles(side,angles))
	if _restart_leg_points.size()==6:
		# A bare recovery starts from the ACTUAL published limbs. Its joint-angle
		# path already starts at those limbs: only the small conversion residual
		# blends out, quickly, so no straight point-space chord sweeps a shin
		# through the cube.
		var restart := .08 if _restart_angles.size()==4 else .25*_flight_seconds
		var blend := smoothstep(.0,restart,time)
		var start := _root_at(0.0).affine_inverse()
		for side in 2:
			var leg: Array = result[side]
			leg[0] = (start*_restart_leg_points[side*3+1]).lerp(leg[0],blend)
			leg[1] = (start*_restart_leg_points[side*3+2]).lerp(leg[1],blend)
			if _restart_ankles.size()==2:
				var from: Quaternion = (start.basis*_restart_ankles[side]).orthonormalized().get_rotation_quaternion()
				leg[2] = Basis(from.slerp((leg[2] as Basis).get_rotation_quaternion(),blend))
	return result

func _planned_leg_points(time: float) -> Array[Vector3]:
	var result: Array[Vector3] = []
	if _hip_root.size()!=2: return result
	var root := _root_at(time)
	var legs := _leg_pose_at(time)
	for side in 2:
		result.append(root*_hip_root[side])
		result.append(root*(legs[side][0] as Vector3))
		result.append(root*(legs[side][1] as Vector3))
	return result

func _stunt_self_clear(points: Array[Vector3]) -> bool:
	var head_size := Vector3(.76,_head_height*2.0,.76)
	var has_tool := is_instance_valid(worker.equipped_tool)
	var tool := _tool_local*Transform3D(Basis.IDENTITY,_tool_bounds.get_center())
	for side in 2:
		for link in 2:
			var a: Vector3 = points[side*3+link]
			var b: Vector3 = points[side*3+link+1]
			if _own_holder_intersects(a,b,_root_local*_holder_root_ref.affine_inverse()): return false
			if has_tool and _segment_box(a,b,tool,_tool_bounds.size,.085): return false
			if link==1 and _segment_box(a,b,_root_local,head_size,.085): return false
	return true

func _tuck_points(capacity: float) -> Array[Vector3]:
	var saved := _stunt_capacity
	_stunt_capacity = capacity
	var points: Array[Vector3] = []
	for side in 2:
		var leg := _leg_from_angles(side,_tuck_angles(1.0))
		points.append(_root_local*_hip_root[side])
		points.append(_root_local*(leg[0] as Vector3))
		points.append(_root_local*(leg[1] as Vector3))
	_stunt_capacity = saved
	return points

func _fit_stunt_tuck() -> void:
	# Fit the tuck BEFORE the original full arc/force admission: the smallest
	# thigh splay whose full frog tuck keeps the 85 mm links outside the own
	# padded cube, holder and tool; otherwise the best partial tuck (blended
	# toward the open pose). Final preflight still checks every body, stock,
	# partner, holder/tool and link with the original finite envelopes.
	_stunt_capacity = 1.0
	_splay = 0.0
	if _hip_root.size()!=2: return
	var best_capacity := -1.0
	var best_splay := 0.0
	for splay: float in (LEG_SPLAYS if crew.size()<=1 else [0.0]):
		_splay = splay
		if not _stunt_self_clear(_tuck_points(0.0)): continue
		if _stunt_self_clear(_tuck_points(1.0)):
			_stunt_capacity = 1.0
			return
		var low := .0
		var high := 1.0
		for iteration in 8:
			var middle := (low+high)*.5
			if _stunt_self_clear(_tuck_points(middle)): low=middle
			else: high=middle
		if low>best_capacity:
			best_capacity = low
			best_splay = splay
	_splay = best_splay
	_stunt_capacity = maxf(best_capacity,0.0)*.95

func _observe_stunt_clearance(time: float, side: int, points: Array[Vector3]) -> void:
	if _stunt_clearance_rows>=2: return
	_stunt_clearance_rows += 1
	print("HEAD_STUNT_SELF_REFUSAL worker=",worker.worker_id," source=",part.part_id," state=",state," time=",time," side=",side," capacity=",_stunt_capacity," hips=",_hip_root," proposed_links=",points," actual_root=",_root_local," forward=",_stunt_forward)

# --- Supported departure legs: pinned balls of the feet -----------------------
func _prep_owned() -> bool:
	return state=="prepare" and _snapshot_ready and not _bones.is_empty() and _hip_root.size()==2

func _capture_pins(sk: Skeleton3D, pose: SkeletonModifier3D) -> void:
	# Pin the balls of the feet (toe joints) where the last supported pose put
	# them; the heels lift about them, the toes stay flat on the ground.
	_pin_points.clear()
	_pin_toe_basis.clear()
	_pin_ankle_offset.clear()
	_pin_foot_basis.clear()
	for side in 2:
		var chain: Array = pose._chains[side]
		var toe: int = pose._toes[side] if side<pose._toes.size() else -1
		var foot := sk.global_transform*sk.get_bone_global_pose(chain[2])
		var pivot: Vector3 = sk.global_transform*sk.get_bone_global_pose(toe).origin if toe>=0 else foot*Vector3(0,pose._ankle_height[side],0)
		_pin_points.append(pivot)
		_pin_toe_basis.append((sk.global_basis*sk.get_bone_global_pose(toe).basis).orthonormalized() if toe>=0 else foot.basis.orthonormalized())
		_pin_ankle_offset.append(foot.origin-pivot)
		_pin_foot_basis.append(foot.basis.orthonormalized())
	_pin_active = true

func _pinned_leg(side: int, root_world: Transform3D, knee_flexion: float, minimum_lift := 0.0) -> Dictionary:
	# Smallest heel lift about the pinned toe joint that lets this hip keep the
	# requested knee flexion; refused once even the full point cannot reach.
	var hip: Vector3 = root_world*_hip_root[side]
	var pivot: Vector3 = _pin_points[side]
	var arm: Vector3 = _pin_ankle_offset[side]
	var axis := arm.cross(Vector3.UP)
	if axis.length_squared()<.000001: return {}
	axis = axis.normalized()
	if axis.cross(arm).y<0.0: axis = -axis
	var upper := _leg_upper[side]
	var lower := _leg_lower[side]
	var wanted := minf(sqrt(upper*upper+lower*lower+2.0*upper*lower*cos(knee_flexion)),upper+lower-.003)
	# The heel rises at least minimum_lift (toes-last push). The ankle height
	# about the ball of the foot peaks part-way through the point, so sample
	# the lift instead of assuming a monotonic reach.
	var floor_lift := minf(minimum_lift,MAXIMUM_PIN_POINT)
	var lift := -1.0
	var nearest := INF
	var nearest_lift := floor_lift
	for step in 33:
		var trial := lerpf(floor_lift,MAXIMUM_PIN_POINT,float(step)/32.0)
		var distance := hip.distance_to(pivot+arm.rotated(axis,trial))
		if distance<nearest:
			nearest = distance
			nearest_lift = trial
		if distance<=wanted:
			lift = trial
			break
	if lift<0.0:
		# Even straightened: refuse once the planted ball is out of reach.
		if nearest>upper+lower-.003: return {}
		lift = nearest_lift
	var ankle := pivot+arm.rotated(axis,lift)
	var face: Vector3 = worker.global_basis*_stunt_forward
	var solution := LegGeometry.two_link(hip,ankle,upper,lower,face,.015,.003,face)
	return {"knee":solution.knee,"ankle":ankle,"foot":Basis(axis,lift)*_pin_foot_basis[side],"lift":lift}

func _pinned_legs(root_world: Transform3D, knee_flexion: float, minimum_lift := 0.0) -> Array:
	var legs: Array = []
	var inverse := root_world.affine_inverse()
	for side in 2:
		var leg := _pinned_leg(side,root_world,knee_flexion,minimum_lift)
		if leg.is_empty(): return []
		legs.append([inverse*(leg.knee as Vector3),inverse*(leg.ankle as Vector3),(root_world.basis.inverse()*(leg.foot as Basis)).orthonormalized(),float(leg.lift)])
	return legs

func _angles_of(side: int, leg: Array) -> Array:
	# Joint angles of a cube-frame leg (for blending the launch into the keys).
	var hip: Vector3 = _hip_root[side]
	var thigh: Vector3 = ((leg[0] as Vector3)-hip).normalized()
	var shin: Vector3 = ((leg[1] as Vector3)-(leg[0] as Vector3)).normalized()
	var forward := _face_root()
	var outward := Vector3.DOWN.cross(forward).normalized()
	if outward.dot(hip)<0.0: outward = -outward
	# Inverse of _leg_from_angles: adduction from the thigh's outward lean.
	var adduct := -asin(clampf(thigh.dot(outward),-1.0,1.0))
	var plane := (thigh+outward*sin(adduct)).normalized()
	return [atan2(plane.dot(forward),-plane.y),thigh.angle_to(shin),adduct,float(leg[3])]

func _apply_stunt_legs(pose: SkeletonModifier3D, sk: Skeleton3D, legs: Array, flat_toes := false) -> void:
	# Aim the snapshot bones at the cube-frame knees/ankles; feet take the
	# planned basis; pointed toes curl, pinned toes stay flat on the ground.
	var to_skeleton := sk.global_transform.affine_inverse()*(sk.global_transform*sk.get_bone_global_pose(0))
	for side in 2:
		var chain: Array = pose._chains[side]
		var leg: Array = legs[side]
		var upper := sk.get_bone_global_pose(chain[0])
		var lower := sk.get_bone_global_pose(chain[1])
		var knee: Vector3 = to_skeleton*(leg[0] as Vector3)
		var ankle: Vector3 = to_skeleton*(leg[1] as Vector3)
		upper.basis = Basis(Quaternion((lower.origin-upper.origin).normalized(),(knee-upper.origin).normalized()))*upper.basis
		sk.set_bone_global_pose(chain[0],upper)
		lower = sk.get_bone_global_pose(chain[1])
		var foot := sk.get_bone_global_pose(chain[2])
		lower.basis = Basis(Quaternion((foot.origin-lower.origin).normalized(),(ankle-lower.origin).normalized()))*lower.basis
		sk.set_bone_global_pose(chain[1],lower)
		foot = sk.get_bone_global_pose(chain[2])
		foot.basis = to_skeleton.basis*(leg[2] as Basis)
		sk.set_bone_global_pose(chain[2],foot)
		var toe: int = pose._toes[side] if side<pose._toes.size() else -1
		if toe<0: continue
		var toe_pose := sk.get_bone_global_pose(toe)
		if flat_toes and side<_pin_toe_basis.size():
			toe_pose.basis = sk.global_basis.inverse()*_pin_toe_basis[side]
			sk.set_bone_global_pose(toe,toe_pose)
			continue
		var curl := clampf(float(leg[3])/float(LEG_TUCK[3]),0.0,1.0)
		if curl<.001: continue
		var shin: Vector3 = (foot.origin-lower.origin).normalized()
		var toe_direction: Vector3 = toe_pose.origin-foot.origin
		var flex_axis := toe_direction.cross(shin)
		if flex_axis.length_squared()<.000001: continue
		toe_pose.basis = Basis(flex_axis.normalized(),TOE_CURL*curl)*toe_pose.basis
		sk.set_bone_global_pose(toe,toe_pose)

func evaluate_airborne(pose: SkeletonModifier3D, sk: Skeleton3D) -> bool:
	var preparing := _prep_owned()
	if not (preparing or airborne_pose() or (state=="landing" and not worker.on_ground)) or _bones.is_empty() or _hip_root.size()!=2: return false
	for bone in _bones.size(): sk.set_bone_pose(bone,_bones[bone])
	if preparing and _pin_points.is_empty(): _capture_pins(sk,pose)
	var time := _flight_seconds
	if state in ["outbound","return"]: time = minf(elapsed,_flight_seconds)
	# The cube rides the native body at its standing root: the crouch, lunge
	# and drive are the body's own motion, not a root offset.
	var root_local: Transform3D = _rest_root_local if preparing else _root_at(time)
	var root_world := worker.global_transform*root_local
	if preparing and crew.size()>1:
		# The crew's count-in nod: the cube tips toward the stock and back
		# about its hip line (the planted legs are untouched).
		var age := elapsed-CREW_CROUCH_LAG*_twin
		if age>0.0 and age<NOD_SECONDS:
			var hips: Vector3 = root_world*((_hip_root[0]+_hip_root[1])*.5)
			var axis_world: Vector3 = (worker.global_basis*_outbound_axis).normalized()
			var turn := Basis(axis_world,NOD_ANGLE*sin(PI*age/NOD_SECONDS))
			root_world = Transform3D(turn*root_world.basis,hips+turn*(root_world.origin-hips))
	sk.set_bone_global_pose(0,sk.global_transform.affine_inverse()*root_world)
	var legs: Array = []
	var pinned := false
	if preparing or (state=="outbound" and _pin_active):
		# Planted: the knee follows the hip's real distance to the pinned ball
		# of the foot; the heel peels through the drive; after the release the
		# toes stay down until even full extension cannot reach them.
		var lift := _heel_floor(elapsed) if preparing else HEEL_PEEL
		legs = _pinned_legs(root_world,deg_to_rad(8.0) if preparing else deg_to_rad(3.0),lift)
		pinned = not legs.is_empty()
		if pinned:
			_pin_release_pose = legs
			if preparing: _launch_leg_pose = _angles_of(0,legs[0])
		elif state=="outbound":
			_pin_active = false
			_pin_release_time = elapsed
		elif _pin_release_pose.size()==2:
			legs = _pin_release_pose
	if legs.is_empty():
		legs = _leg_pose_at(time,true)
		if state=="outbound" and _pin_release_time>=0.0 and _pin_release_pose.size()==2 and elapsed<_pin_release_time+TRAIL_SECONDS:
			# Feet trail off the ground into the planned tuck.
			var blend := smoothstep(_pin_release_time,_pin_release_time+TRAIL_SECONDS,elapsed)
			for side in 2:
				var from: Array = _pin_release_pose[side]
				var to: Array = legs[side]
				legs[side] = [(from[0] as Vector3).lerp(to[0],blend),(from[1] as Vector3).lerp(to[1],blend),
					Basis((from[2] as Basis).get_rotation_quaternion().slerp((to[2] as Basis).get_rotation_quaternion(),blend)),lerpf(float(from[3]),float(to[3]),blend)]
	_apply_stunt_legs(pose,sk,legs,pinned)
	_squash = _squash_now()
	if absf(_squash)>.0002: _apply_squash(sk,root_world,_squash)
	pose.evaluated_grounded = [pinned,pinned]
	pose._target_valid = [false,false]
	pose._gait_rotations.clear()
	pose._head_gait_continuation = false
	pose._travel_pole_handoff=false
	pose._travel_tool_handoff=false
	pose._travel_tool_settle_time=0.0
	for side in 2:
		var chain: Array = pose._chains[side]
		pose.evaluated_hips[side] = sk.global_transform*sk.get_bone_global_pose(chain[0]).origin
		pose.evaluated_knees[side] = sk.global_transform*sk.get_bone_global_pose(chain[1]).origin
		pose.evaluated_ankles[side] = sk.global_basis*sk.get_bone_global_pose(chain[2]).basis
		pose.evaluated_soles[side] = sk.global_transform*(sk.get_bone_global_pose(chain[2])*Vector3(0,pose._ankle_height[side],0))
	pose.evaluated_root = sk.global_transform*sk.get_bone_global_pose(0)
	pose.evaluated_worker = worker.global_transform
	pose.evaluated_basis = sk.global_basis
	pose.evaluated_valid = true
	pose.evaluation_serial += 1
	_capture_leg_bases(sk)
	worker._update_work_tool(true)
	worker._update_head(pose.evaluated_root)
	_refresh_shared_anchor()
	if worker.ragdoll: worker.ragdoll.remember_pose()
	return true

# --- Visual squash of the cube about its crown -------------------------------
func _squash_now() -> float:
	# Head impact: a fast compression (a little overshoot) held through the
	# dwell; the return releases it (heavy loads first strain deeper, with a
	# tremble) into a stretch at the peak of the head push, then settles.
	if state=="contact" and _impact_clock>=0.0: return _contact_squash(_impact_clock)
	if state=="return" and _plan_tier in ["brisk","long","legacy"]: return _return_squash(elapsed)
	return 0.0

func _contact_squash(age: float) -> float:
	if _squash_depth<=0.0: return 0.0
	return _squash_depth*smoothstep(0.0,.03,age)*(1.0-.15*smoothstep(.03,.09,age))

func _return_squash(time: float) -> float:
	var kick_start := maxf(_return_lead-RETURN_LEAD,0.0)
	var value := _squash_at_attach
	if kick_start>0.0:
		value = lerpf(value,STRAIN_SQUASH,smoothstep(0.0,minf(kick_start*.6,.14),time))
		value += .002*sin(TAU*7.0*maxf(time-.06,0.0))*smoothstep(.06,.14,time)*(1.0-smoothstep(kick_start*.85,kick_start,time))
	var peak := _return_lead+_push_seconds*.55
	value = lerpf(value,-PUSH_STRETCH,smoothstep(maxf(kick_start,_return_lead-.03),peak,time))
	return lerpf(value,0.0,smoothstep(_return_lead+_push_seconds,_return_lead+_push_seconds+.14,time))

func _apply_squash(sk: Skeleton3D, root_world: Transform3D, amount: float) -> void:
	# Scale the cube along its up axis about the crown (the roof contact never
	# moves) with a volume-keeping bulge; the legs keep their own rigid bones,
	# riding the squashed hips. Purely visual: contact, cargo and clearance
	# frames use the rigid cube (_rigid_root).
	var height := maxf(_head_touch_local.y,.1)
	var squash := clampf(1.0-amount/height,.85,1.1)
	var bulge := 1.0/sqrt(squash)
	var scale := Basis.from_scale(Vector3(bulge,squash,bulge))
	var squashed := root_world*Transform3D(scale,_head_touch_local-scale*_head_touch_local)
	var to_skeleton := sk.global_transform.affine_inverse()
	var uppers: Array[Transform3D] = []
	var pose: SkeletonModifier3D = worker._pose
	for side in 2: uppers.append(sk.get_bone_global_pose(pose._chains[side][0]))
	sk.set_bone_global_pose(0,to_skeleton*squashed)
	var root_inverse := (to_skeleton*root_world).affine_inverse()
	for side in 2:
		var upper: Transform3D = uppers[side]
		upper.origin = (to_skeleton*squashed)*(root_inverse*upper.origin)
		sk.set_bone_global_pose(pose._chains[side][0],upper)

func _seed_landing_release() -> void:
	var pose: SkeletonModifier3D=worker._pose
	if not pose.evaluated_valid: return
	# The returned real cube and its head-held material share the already
	# qualified grounded departure turn budget before normal routing resumes.
	worker._grounded_heading_handoff=true
	var rebase: Transform3D=worker.global_transform*pose.evaluated_worker.affine_inverse()
	var root: Transform3D=rebase*pose.evaluated_root
	var inverse := root.affine_inverse()
	var side: int=worker.tool_foot_side()
	var other: int=1-side
	pose._manipulation_snapshot.clear()
	pose._work_release={"side":side,"age":0.0,
		"sole":inverse*(rebase*pose.evaluated_soles[side]),"basis":root.basis.inverse()*rebase.basis*pose.evaluated_ankles[side],
		"support_sole":inverse*(rebase*pose.evaluated_soles[other]),"support_basis":root.basis.inverse()*rebase.basis*pose.evaluated_ankles[other]}
	pose._head_gait_continuation=false
	pose._head_gait_rotations.clear()
	pose._target_valid=[false,false]
	pose._walk_swing_phase=[-1.0,-1.0]
	pose._gait_handoff_active=false
	pose._gait_handoff_tail=0.0

func _stock_support() -> Dictionary:
	if not is_instance_valid(part): return {}
	var bounds: AABB = part.global_transform*_stock_bounds
	var point := Vector3(bounds.get_center().x,bounds.position.y,bounds.get_center().z)
	var query := PhysicsRayQueryParameters3D.create(point+Vector3.UP*.025,point-Vector3.UP*.05,1)
	var exclusions: Array[RID]=[part.get_rid()]
	for member: Node in crew: exclusions.append(member.get_rid())
	query.exclude = exclusions
	var hit := worker.get_world_3d().direct_space_state.intersect_ray(query)
	return hit if not hit.is_empty() and hit.normal.y>.65 else {}

func _actual_root() -> Transform3D:
	if worker._pose.evaluated_valid:
		return worker.global_transform*worker._pose.evaluated_worker.affine_inverse()*worker._pose.evaluated_root
	return worker.global_transform*_root_local

func _head_point() -> Vector3:
	return _actual_root()*_head_touch_local

func abort(message: String) -> void:
	# Finished work retains its contact history, but no longer owns installed
	# or loose stock, nor a former partner's newly started head leap.
	if not active():
		if not is_instance_valid(part) or not is_instance_valid(part.carrier): return
		var held_by_crew := crew.any(func(member: Node) -> bool: return is_instance_valid(member) and member.head_leap.part==part and member.head_leap.crew==crew and part.carrier==member.head_anchor)
		var staged: bool=contacted and part.has_meta(&"staged_target") and part.get_meta(&"staged_target")==part.carrier
		if not held_by_crew and not staged: return
	if reason.is_empty(): reason=message
	_abort_requested = true
	for member: Node in crew:
		if not is_instance_valid(member) or member.head_leap.part!=part or member.head_leap.crew!=crew: continue
		if member.head_leap.reason.is_empty(): member.head_leap.reason=message
		member.head_leap._abort_requested=true
	# A valid stock object may already have left the world when its carrier's
	# tree_exiting callback cancels the job. No physical release exists then.
	if crew.is_empty() or not is_instance_valid(part) or not part.is_inside_tree(): return
	if crew[0]!=worker:
		if is_instance_valid(crew[0]) and crew[0].head_leap.part==part and crew[0].head_leap.crew==crew:
			crew[0].head_leap.abort(message)
		return
	if state=="return" and contacted and part.carrier==worker.head_anchor \
		and crew.all(func(member: Node) -> bool: return is_instance_valid(member) and member.is_inside_tree() and member.is_available() and member.head_leap.state=="return"):
		# Cancelled in mid-air with the load on the head(s): the admitted
		# flight was planned with that load, so it is carried to the touchdown
		# and released there (a load let go mid-flight is flung off the
		# rotating head and comes down on the creature).
		_release_on_touchdown = true
		return
	_release_on_touchdown = false
	# Preserve precise source visibility through a bare recovery preflight.
	# The physical masks still ignore this query-only layer.
	if not is_instance_valid(part.carrier): part.collision_layer=_saved_source_layer|CONTACT_QUERY_BIT
	if part.carrier==worker.head_anchor or (contacted and part.has_meta(&"staged_target") and is_instance_valid(part.carrier)):
		# Prefer the source's measured native COM/angular motion directly. It
		# includes animated head motion and remains valid when crew are leaving.
		var stock_state := PhysicsServer3D.body_get_direct_state(part.get_rid())
		var velocity: Vector3=stock_state.linear_velocity if stock_state else part.linear_velocity
		var spin: Vector3=stock_state.angular_velocity if stock_state else part.angular_velocity
		if not stock_state and crew.all(func(member: Node) -> bool: return is_instance_valid(member) and member.is_inside_tree() and member.head_leap.part==part and member.head_leap.crew==crew):
			# Keep the ordinary point-motion fallback while the whole crew still
			# has a world frame; detached bodies retain their own cached motion.
			velocity=Vector3.ZERO
			for member: Node in crew:
				var direct := PhysicsServer3D.body_get_direct_state(member.get_rid())
				var com: Vector3=member.global_transform*direct.center_of_mass_local if direct else member.global_position
				velocity += _velocity(member)+member.angular_velocity.cross(member.head_leap._head_point()-com)
			velocity /= crew.size()
			velocity+=worker.angular_velocity.cross(part.global_position-contact_frame().origin)
			spin=worker.angular_velocity
		var target: Variant=part.get_meta(&"staged_target") if part.has_meta(&"staged_target") else null
		if is_instance_valid(target): target.visual.show()
		part.remove_meta(&"staged_target")
		part.set_carried(null)
		part.linear_velocity = velocity
		part.angular_velocity = spin
		part.set_meta(&"in_transit",false)
		for member: Node in crew:
			if not is_instance_valid(member) or member.head_leap.part!=part or member.head_leap.crew!=crew: continue
			if member.is_inside_tree():
				part.add_collision_exception_with(member)
				member.head_leap._release_watch = part
			else:
				part.remove_collision_exception_with(member)
			# A supported release can occur long after the landing converged.
			# This actual carried/staged body's cancellation must hand its current
			# WORLD legs to the interrupted clip before clearing the cargo share.
			# Airborne impacts retain their existing native fall/return ownership.
			var pose: SkeletonModifier3D = member._pose
			if member.is_inside_tree() and member.on_ground and is_instance_valid(pose) and pose.is_inside_tree() and pose.evaluated_valid:
				pose._head_landing_continuation = true
				pose._head_return_settle = 0.0
			member.set_cargo(0.0)
			member.head_leap._abort_requested = true

func _watch_release() -> void:
	# The flight torso stays in use for the whole owned leap (the supported
	# departure included); restoring the capsule waits for the end.
	if not active(): _restore_collision_when_safe()
	if not is_instance_valid(_release_watch): return
	if not _release_watch.is_inside_tree():
		_release_watch.remove_collision_exception_with(worker)
		_release_watch=null
		return
	var local_bounds: AABB = StockBounds.bounds(_release_watch)
	var collision: CollisionShape3D=worker.get_node("Collision")
	var apart := false
	if collision.shape is BoxShape3D:
		# The flight torso is the cube itself: lift the exception as soon as
		# the two boxes no longer overlap, so a released load resting on the
		# roof is held by real contact instead of sinking into the body.
		var stock_box := _release_watch.global_transform*Transform3D(Basis.IDENTITY,local_bounds.get_center())
		apart = not _boxes_overlap(stock_box.orthonormalized(),local_bounds.size+Vector3.ONE*2.0*_release_margin,collision.global_transform.orthonormalized(),collision.shape.size)
	else:
		var bounds: AABB = _release_watch.global_transform*local_bounds
		var cube: AABB = _actual_root()*AABB(Vector3(-.4,-.35,-.4),Vector3(.8,.7,.8))
		var native: AABB=collision.global_transform*collision.shape.get_debug_mesh().get_aabb()
		apart = not bounds.grow(.06).intersects(cube.merge(native))
	if apart:
		_release_watch.remove_collision_exception_with(worker)
		_release_watch = null
		_release_margin = 0.0

func clear_before_launch() -> void:
	if state=="prepare":
		if is_instance_valid(part): part.remove_collision_exception_with(worker)
		if not crew.is_empty() and crew[0]==worker and is_instance_valid(part): part.collision_layer=_saved_source_layer
		state=""
		part=null

func _save_native_settings() -> void:
	_native_settings_saved=true
	if not _needs_angular_restore:
		_saved_angular_locks = [worker.axis_lock_angular_x, worker.axis_lock_angular_y, worker.axis_lock_angular_z]
	_needs_angular_restore = true
	_swap_flight_torso()
	_saved_damping = worker.linear_damp
	_saved_damping_mode = worker.linear_damp_mode
	_saved_angular_damping = worker.angular_damp
	_saved_angular_damping_mode = worker.angular_damp_mode
	worker.linear_damp_mode=RigidBody3D.DAMP_MODE_REPLACE
	worker.linear_damp=0.0
	worker.angular_damp_mode=RigidBody3D.DAMP_MODE_REPLACE
	worker.angular_damp=0.0
	worker.axis_lock_angular_x=false
	worker.axis_lock_angular_y=false
	worker.axis_lock_angular_z=false

func _swap_flight_torso() -> void:
	# The old capsule extends 148 mm past this asset's real roof. During the
	# rotating head flight use its captured finite cube instead, so a genuine
	# thin-part touch does not require pushing that invisible capsule into floor.
	# Both legs retain their native reactive observers and finite skin geometry.
	# The swap moves the helper's custom COM (it follows the Collision node):
	# do it on the supported push-off, so the launch plans the COM it flies on
	# instead of a spinning body whose COM jumps on its first airborne tick.
	if _needs_collision_restore: return
	var collision: CollisionShape3D=worker.get_node("Collision")
	_saved_collision_shape=collision.shape
	_saved_collision_transform=collision.transform
	var torso:=BoxShape3D.new()
	torso.size=Vector3(.76,_head_height*2.0,.76)
	collision.shape=torso
	collision.transform=_root_local
	_needs_collision_restore=true

func _settle_flight_torso() -> void:
	if not _needs_collision_restore: return
	var collision: CollisionShape3D=worker.get_node("Collision")
	if collision.shape is BoxShape3D: collision.transform=_rest_root_local

func _finish(success: bool) -> void:
	if _release_on_touchdown and crew.size()>0 and crew[0]==worker:
		_release_on_touchdown = false
		abort(reason)
	# The absorb's rise keeps its own curve through the hand-off.
	_finish_age = _impact_age if state=="landing" and _impact_age>=0.0 and _impact_age<9.0 else -1.0
	_finish_frame = Engine.get_physics_frames() if _finish_age>=0.0 else -1
	if _native_settings_saved:
		worker.linear_damp=_saved_damping
		worker.linear_damp_mode=_saved_damping_mode
		worker.angular_damp=_saved_angular_damping
		worker.angular_damp_mode=_saved_angular_damping_mode
	_restore_collision_when_safe()
	# Lock only after supported native angular settling. A failed recovery is
	# left for the existing reactive/ragdoll controller instead of snapping it.
	if _needs_angular_restore and (success or (worker.on_ground and worker.global_basis.y.dot(Vector3.UP)>.98 and worker.angular_velocity.length()<.35)):
		worker.axis_lock_angular_x = _saved_angular_locks[0]
		worker.axis_lock_angular_y = _saved_angular_locks[1]
		worker.axis_lock_angular_z = _saved_angular_locks[2]
		_needs_angular_restore = false
	state="done" if success else "failed"
	worker.action=""
	worker.action_progress=1.0
	worker._animation.play("wk_idle",.2)
	if is_instance_valid(part) and not is_instance_valid(_release_watch): part.remove_collision_exception_with(worker)
	if not crew.is_empty() and crew[0]==worker and is_instance_valid(part) and not is_instance_valid(part.carrier): part.collision_layer=_saved_source_layer
	if not success and worker.global_basis.y.dot(Vector3.UP)<.8 and worker.ragdoll and not worker.ragdoll.is_down(): worker.ragdoll.knock_down()

func take_recovery_angular_locks() -> Array[bool]:
	# The accepted native fall owns this pre-flight policy until supported recovery.
	var locks: Array[bool] = [worker.axis_lock_angular_x, worker.axis_lock_angular_y, worker.axis_lock_angular_z]
	if _needs_angular_restore:
		locks.assign(_saved_angular_locks)
		_needs_angular_restore = false
	return locks

func _restore_collision_when_safe() -> void:
	if not _needs_collision_restore: return
	var suspended: bool=worker.ragdoll and worker.ragdoll.is_down()
	var supported: bool=worker.on_ground and worker.global_basis.y.dot(Vector3.UP)>.98 and _velocity(worker).length()<.5 and worker.angular_velocity.length()<.35
	if supported and not suspended:
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape=_saved_collision_shape
		query.transform=worker.global_transform*_saved_collision_transform
		query.collision_mask=1
		query.exclude=worker.query_exclusions()
		if not worker.get_world_3d().direct_space_state.intersect_shape(query,1).is_empty(): return
	if supported or suspended:
		var collision: CollisionShape3D=worker.get_node("Collision")
		collision.shape=_saved_collision_shape
		collision.transform=_saved_collision_transform
		_needs_collision_restore=false

static func _velocity(body: RigidBody3D) -> Vector3:
	var direct := PhysicsServer3D.body_get_direct_state(body.get_rid())
	return direct.linear_velocity if direct else body.linear_velocity

func saved_physical_body() -> Dictionary:
	# A supported departure or an upright supported landing (on its feet)
	# saves as the ordinary body.
	if not _native_settings_saved or not active() or state=="prepare" or not worker.ragdoll: return {}
	if state=="landing" and worker.on_ground and worker.global_basis.y.normalized().dot(Vector3.UP)>.95: return {}
	var visual: RefCounted=worker.ragdoll.visual
	if visual._remembered.size()!=worker._skeleton.get_bone_count(): return {}
	# Saving interrupts the assisted jump into existing native fall/recovery.
	# Each frame is the last actually evaluated rig carried by current native
	# motion; no authored upright pose or previous launch place is substituted.
	var native:=PhysicsServer3D.body_get_direct_state(worker.get_rid())
	var frame: Transform3D=native.transform if native else worker.global_transform
	var spin: Vector3=native.angular_velocity if native else worker.angular_velocity
	var velocity: Vector3=native.linear_velocity if native else worker.linear_velocity
	var com: Vector3=frame*native.center_of_mass_local if native else frame*worker.center_of_mass
	var rebase: Transform3D=frame*visual._remembered_worker.affine_inverse()
	var bodies: Array=[]
	for body in worker.ragdoll.rig.bodies:
		var pose: Transform3D=rebase*visual._remembered[body.bone]*body.b2b_inv
		pose.basis=pose.basis.orthonormalized()
		var point_motion:=velocity+spin.cross(pose.origin-com)
		bodies.append({"pose":[pose.basis.x.x,pose.basis.x.y,pose.basis.x.z,pose.basis.y.x,pose.basis.y.y,pose.basis.y.z,pose.basis.z.x,pose.basis.z.y,pose.basis.z.z,pose.origin.x,pose.origin.y,pose.origin.z],"linear":[point_motion.x,point_motion.y,point_motion.z],"angular":[spin.x,spin.y,spin.z]})
	return {"bodies":bodies,"clock":0.0,"origin_motion":true,"saved":{"layer":worker.collision_layer,"mask":worker.collision_mask,"freeze":worker.freeze,"freeze_mode":worker.freeze_mode,"angular_locks":_saved_angular_locks.duplicate()}}

func _capture_leg_bases(sk: Skeleton3D) -> void:
	evaluated_leg_bases.clear()
	for side in 2:
		var chain: Array=worker._pose._chains[side]
		for bone: int in [chain[1],chain[2]]: evaluated_leg_bases.append(sk.global_basis*sk.get_bone_global_pose(bone).basis)

func _capture_holder_bounds() -> void:
	_holder_bounds=AABB()
	_holder_source_bounds=AABB()
	if not worker.back_tool: return
	var found:=false
	var inverse:=worker.global_transform.affine_inverse()
	for node: Node in worker.back_tool.holder.get_children():
		if not node is MeshInstance3D or not node.mesh: continue
		var bounds: AABB=inverse*node.global_transform*node.get_aabb()
		_holder_bounds=_holder_bounds.merge(bounds) if found else bounds
		found=true
		if node in worker.back_tool._straps or node.mesh is CylinderMesh: continue
		_holder_source_bounds=_holder_source_bounds.merge(bounds) if _holder_source_bounds.has_volume() else bounds
	# Preserve the ORIGINAL world/cargo/partner union. Only own-limb
	# admission resolves its empty cavities against every real constituent.
	var started_usec := Time.get_ticks_usec()
	var holder_frame: Transform3D=inverse*worker.back_tool.holder.global_transform
	_holder_inverse=holder_frame.affine_inverse()
	# The holder rides on the cube (the back tool syncs it to the root bone):
	# remember which cube frame these body-local bounds were captured under.
	_holder_root_ref = worker._pose.evaluated_worker.affine_inverse()*worker._pose.evaluated_root if worker._pose.evaluated_valid else _rest_root_local
	_holder_clearance.capture(worker.back_tool.holder)
	# Holder space must be rigid so the original 85mm radius is unchanged.
	if not holder_frame.basis.is_equal_approx(holder_frame.basis.orthonormalized()): _holder_clearance.valid=false
	_holder_capture_usec=maxi(_holder_capture_usec,Time.get_ticks_usec()-started_usec)


func _holder_frame(time: float) -> Transform3D:
	# Body-local placement of the captured holder when the cube is at its
	# planned root: the holder follows the cube's lean, rise and blend.
	return _root_at(time)*_holder_root_ref.affine_inverse()

func _own_holder_intersects(a: Vector3,b: Vector3,frame := Transform3D.IDENTITY) -> bool:
	var to_holder := _holder_inverse*frame.affine_inverse()
	return _holder_clearance.intersects(to_holder*a,to_holder*b)

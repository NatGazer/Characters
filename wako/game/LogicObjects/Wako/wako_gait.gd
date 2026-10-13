extends RefCounted
## Ordinary-locomotion gait planner for Wako, owned by wako_pose.gd.
## The clock is distance-locked: phase advances by ground-relative travel, so
## a planted sole never treadmills and cadence, stride and duty adapt to speed
## (double-support walk -> light run with a flight phase). Each foot is a small
## state machine: PLANTED soles keep position AND yaw in their support's local
## frame and roll heel-up about the toe joint late in stance; SWING feet glide
## (sin^2-ramped, constant-speed middle) to a landing predicted from the
## helper's own force law, over a look-ahead clearance arc; SETTLE steps are
## short time-driven steps that tidy the stance after a stop, recover a
## released plant, and turn in place.
## Pure planning: no physics writes. wako_pose.gd solves and publishes legs,
## then hands back the requested soles so overrides by other owners are seen.
## The body-acting layer (bob, nod, sway, waddle roll, hip twist, lean, squash)
## is phase-locked to the same clock and fades out continuously whenever
## another owner takes the legs (release()).
const PLANTED := 0
const SWING := 1
const SETTLE := 2
const HIP_X := .237
const T_SWING_MAX := .34        # slowest locomotion swing; slower walks keep longer double support
const T_FIRST_SWING := .24      # the launch step is brisk even while the body is still slow
const T_STOP := .2              # an airborne foot at a stop lands within this
const T_RECOVER := .2
const SETTLE_DISTANCE := .07
const SETTLE_YAW := .28         # 16 degrees: turning in place steps before the planted legs twist
const SANITY_SPEED := 16.0      # m/s; only a NaN/teleport guard, swings may legitimately peak ~11 m/s
const MAX_STANCE := .52         # stance distance must fit the run-crouch reach
const STOP_HORIZON := .45
const COMMIT_T := .8            # swing progress after which the footfall is fixed
const CORRIDOR: Array[float] = [.15, .45, .75]   # look-ahead ground samples along the swing
const TOOL_STANCE_LEAD := .08   # a foot-held mallet's stance stays in front of the hip
const HIP_ABOVE_BODY := .035    # rest hip above the capsule origin: -.85 + 1.0739 - .029 - .16
const REACH_DROP := .06         # extra crouch the visual root may still add to reach lower ground
const FOOT_GAP := .20           # sole centres across the heading; the shins are ~.15 thick
const LAUNCH_HOLD := .065       # weight goes onto the support foot before the first lift
const PEEL_RATE := 10.0         # rad/s: a stop drops a peeled heel quickly, never in one tick
const DROP_SPEED := .6          # m/s: the reach crouch eases in at crests and edges (no hiccup)

var pose: SkeletonModifier3D
var worker: RigidBody3D
var active := false

# --- clock ---
var phase := 0.0
var phase_rate := 0.0
var speed := 0.0
var velocity := Vector3.ZERO
var accel := Vector3.ZERO
var _last_velocity := Vector3.INF
var half_stride := .16
var duty := .62
var run_weight := 0.0
var moving := false
var moving_age := 0.0
var carry := false
var flee := false
var up := Vector3.UP
var quiet := false
var settle_allowed := false
var hold := false
var plan_usec := 0              # cost of the last plan() (diagnostics)
var debug_log := false          # harness: print launch/lift decisions
var _launch_hold := 0.0
var airborne := false           # locomotion left the ground: the legs fly (air())
var _air_fresh := false
var _air_vy := 0.0
var _air_rel: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _drop: Array[bool] = [false, false]            # landing from air(): falls with the cube to the ground
var _drop_planted: Array[bool] = [false, false]
var _air_query := PhysicsRayQueryParameters3D.new()

# --- feet ---
var state: Array[int] = [PLANTED, PLANTED]
var armed: Array[bool] = [true, true]
var t: Array[float] = [0.0, 0.0]
var p0: Array[float] = [0.0, 0.0]
var min_rate: Array[float] = [0.0, 0.0]
var lift: Array[float] = [.07, .07]
var support: Array = [null, null]               # WeakRef of the plant/start support
var support_rid: Array[RID] = [RID(), RID()]
var local_point: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var local_forward: Array[Vector3] = [Vector3.FORWARD, Vector3.FORWARD]
var start_world: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var start_normal: Array[Vector3] = [Vector3.UP, Vector3.UP]
var start_yaw: Array[float] = [0.0, 0.0]
var landing: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var landing_normal: Array[Vector3] = [Vector3.UP, Vector3.UP]
var landing_hit: Array = [{}, {}]
var landing_yaw: Array[float] = [0.0, 0.0]
var _sampled_for: Array[Vector3] = [Vector3.INF, Vector3.INF]
var _clear_lift: Array[float] = [0.0, 0.0]
var foot_yaw: Array[float] = [0.0, 0.0]
var _t_prev: Array[float] = [-1.0, -1.0]
var _frozen: Array[bool] = [false, false]
var _planar: Array[bool] = [true, true]
var _contact_delay: Array[int] = [0, 0]
var _contact_kind: Array[int] = [SWING, SWING]
var _frozen_support: Array = [null, null]
var _frozen_local: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _pass: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]        # swing bulge around the stance foot
var stance_age: Array[float] = [0.0, 0.0]
var landing_count: Array[int] = [0, 0]          # helper plays a footstep per new landing
var landing_strength: Array[float] = [0.0, 0.0]
var requested: Array[Vector3] = [Vector3.INF, Vector3.INF]
var debug_planned: Array[Vector3] = [Vector3.INF, Vector3.INF]

# --- foot roll (rest-derived, so a re-authored toe direction just works) ---
var _rest_foot: Array[Basis] = []
var _toe_axis: Array[Vector3] = []              # toe curl axis, ankle-local
var _toe_dir: Array[Vector3] = []               # horizontal ankle->toe joint, skeleton rest
var _ball_off: Array[Vector3] = []              # toe joint relative to the sole point, skeleton rest
var _peel: Array[float] = [0.0, 0.0]            # planted heel-up angle about the toe joint
var _peel0: Array[float] = [0.0, 0.0]           # heel-up angle at lift-off (swing continues it)
var _roll_off: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]   # rolled sole - planted point
# Handoff from another owner's last published foot: fades out, never pops.
var _hand_off: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _hand_rot: Array[Quaternion] = [Quaternion.IDENTITY, Quaternion.IDENTITY]

# --- per-tick outputs (world space) ---
var out_sole: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var out_basis: Array[Basis] = [Basis.IDENTITY, Basis.IDENTITY]
var out_planted: Array[bool] = [true, true]
var out_hit: Array = [{}, {}]
var out_toe: Array[float] = [0.0, 0.0]

# --- body acting (skeleton-space offsets for the root bone) ---
var locomotion_weight := 0.0
var _lw_v := 0.0
var body_y := 0.0               # sprung crouch (speed dip, launch gather, reversal crouch)
var _by_v := 0.0
var body_bob := 0.0             # phase-locked stance bob (never sprung: no lag)
var body_lean := 0.0
var _lean_v := 0.0
var body_nod := 0.0
var body_roll := 0.0            # total: sprung bank/launch + phase-locked waddle
var _roll_s := 0.0
var _roll_v := 0.0
var _roll_osc := 0.0
var body_shift := 0.0           # total: sprung launch shift + phase-locked sway
var _shift_s := 0.0
var _shift_v := 0.0
var _shift_osc := 0.0
var body_yaw := 0.0             # total: sprung eye lead + phase-locked hip twist
var _yaw_s := 0.0
var _yaw_v := 0.0
var body_twist := 0.0
var body_drop := 0.0
var _drop_v := 0.0
var settle_dip := 0.0
var squash := 0.0
var _squash_t := 1.0
var _squash_amp := 0.0
var _squash_len := .13
var _act_phase := 0.0
var _launch_t := -1.0
var _launch_side := 0
var _brake_time := 0.0
var _recent_speed := 0.0

var _query := PhysicsRayQueryParameters3D.new()
var _query_key := -1
var _query_age := 0
var _plant_hit: Array = [{}, {}]                # cached plant observation (static supports)
var _plant_hit_age: Array[int] = [0, 0]
var _space: PhysicsDirectSpaceState3D
# Prediction results (members, so the per-tick planner allocates nothing).
var _pred_x := Vector3.ZERO
var _pred_v := Vector3.ZERO
var _lt_point := Vector3.ZERO
var _lt_heading := 0.0
var _lt_hip := Vector3.ZERO

func setup(owner_pose: SkeletonModifier3D, sk: Skeleton3D) -> void:
	pose = owner_pose
	worker = owner_pose.worker
	_rest_foot.clear()
	_toe_axis.clear()
	_toe_dir.clear()
	_ball_off.clear()
	for side in 2:
		var ankle: int = pose._chains[side][2]
		var rest_ankle := sk.get_bone_global_rest(ankle)
		_rest_foot.append(rest_ankle.basis)
		# Toe curl axis in the ankle's local frame: rotates the rest toe
		# direction toward the sole. Derived, so a re-authored toe works too.
		var toe: int = pose._toes[side]
		var toe_dir := Vector3.BACK
		var ball := Vector3(0.0, .06, .06)
		if toe >= 0:
			var rest_toe := sk.get_bone_rest(toe)
			toe_dir = (rest_toe.basis.y).normalized()
			var sole := rest_ankle.origin + rest_ankle.basis.orthonormalized() * Vector3(0, float(pose._ankle_height[side]), 0)
			ball = sk.get_bone_global_rest(toe).origin - sole
		var axis := toe_dir.cross(Vector3.UP).normalized()  # ankle local +Y points to the sole
		_toe_axis.append(axis if axis.length_squared() > .5 else Vector3.RIGHT)
		var flat := Vector3(ball.x, 0.0, ball.z)
		_toe_dir.append(flat.normalized() if flat.length() > .01 else Vector3.BACK)
		_ball_off.append(ball)

# ------------------------------------------------------------------ helpers
static func min_jerk(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * x * (10.0 + x * (-15.0 + 6.0 * x))

static func glide(x: float) -> float:
	# Swing progress: smooth sin^2 velocity ramps over the first/last fifth
	# and a constant-speed middle. Zero velocity AND acceleration at lift-off
	# and contact like min-jerk, but a peak of only 1.25x the mean speed, so
	# the foot travels decisively without whipping.
	const A := .2
	const V := 1.0 / (1.0 - A)
	x = clampf(x, 0.0, 1.0)
	if x < A: return V * (x * .5 - A / TAU * sin(PI * x / A))
	if x > 1.0 - A: return 1.0 - glide(1.0 - x)
	return V * (A * .5 + x - A)

static func _glide_inverse(s: float) -> float:
	var lo := 0.0
	var hi := 1.0
	for i in 14:
		var mid := (lo + hi) * .5
		if glide(mid) < s: lo = mid
		else: hi = mid
	return (lo + hi) * .5

static func bump(x: float, early := .8) -> float:
	# Early peak (~42%, ~34% running): brisk toe-off and heel tuck, then a
	# long, gradual reach down to contact (no knee whip just before landing).
	x = clampf(x, 0.0, 1.0)
	return pow(sin(PI * pow(x, early)), 1.5)

func _bump(tt: float) -> float:
	return bump(tt, lerpf(.8, .65, run_weight))

static func spring(x: float, v: float, target: float, omega: float, dt: float) -> Vector2:
	# Implicit critically damped spring: unconditionally stable at any tick.
	var f := 1.0 + 2.0 * dt * omega
	var oo := omega * omega
	var hoo := dt * oo
	var hhoo := dt * hoo
	var inv := 1.0 / (f + hhoo)
	return Vector2((f * x + dt * v + hhoo * target) * inv, (v + hoo * (target - x)) * inv)

static func facing(heading: float) -> Vector3:
	return Vector3(-sin(heading), 0.0, -cos(heading))

static func yaw_of(direction: Vector3) -> float:
	return atan2(-direction.x, -direction.z)

func _lateral(side: int, heading: float, width: float) -> Vector3:
	return Basis(Vector3.UP, heading) * Vector3(-width if side == 0 else width, 0.0, 0.0)

func _local_phase(side: int) -> float:
	return fposmod(phase + .5 * side, 1.0)

func _stride(v: float) -> float:
	# Quick, short steps read small and cute: ~5.8 steps/s at a 3.4 m/s run.
	var l := clampf(.16 + .125 * v, .16, .62)
	# Shorter steps on steep ground keep both soles inside the leg's reach
	# (the native body height is measured at its centre, not at the feet).
	l *= lerpf(1.0, .72, smoothstep(.985, .89, up.y))
	if carry: l *= .8
	elif _tool_mode(): l *= .75
	elif flee: l *= 1.1
	return l

func _duty(v: float) -> float:
	var d := lerpf(.62, .50, smoothstep(.6, 1.8, v))
	d = lerpf(d, .36, smoothstep(1.8, 3.2, v))
	if _tool_mode(): return maxf(d, .56)
	return maxf(d, .52) if carry else d

func _is_tool_foot(side: int) -> bool:
	return worker.tool_foot_occupied() and side == worker.tool_foot_side()

func _tool_mode() -> bool:
	# A foot-held full tool: shorter, double-supported steps keep the whole
	# tool's clearance and the finite toe speed (<= 5.4 m/s) without lagging.
	return worker.tool_foot_occupied()

func _swing_span(v: float, d: float) -> float:
	# Phase span of a swing: (1-d), shortened by the T_SWING_MAX time floor.
	if v < .01: return 0.0
	return minf(1.0 - d, T_SWING_MAX * v / (2.0 * _stride(v)))

func stance_distance(v: float) -> float:
	var d := _duty(v)
	return minf(2.0 * _stride(v) * (1.0 - _swing_span(v, d)), MAX_STANCE)

func _predict(tau: float, desired: Vector3) -> void:
	# Same force law as wako_helper._move_with_forces (P gain 6, traction cap).
	var v := velocity
	var x := Vector3.ZERO
	var steps := 5
	var h := tau / steps
	var gain := 6.0 * (1.0 - float(worker._reaction) * .7)
	var cap := 9.8 * 1.25
	var target := desired.slide(up)
	for i in steps:
		var a := ((target - v) * gain).limit_length(cap)
		v += a * h
		x += v * h
	_pred_x = x
	_pred_v = v

func _heading_at(tau: float) -> float:
	var error := wrapf(worker._idle_heading - worker._heading, -PI, PI)
	return worker._heading + clampf(worker.turn_rate * tau, -absf(error), absf(error))

func _lead_heading() -> float:
	return worker._heading + clampf(wrapf(worker._idle_heading - worker._heading, -PI, PI), -.55, .55)

func _track(v: float) -> float:
	# Feet converge toward the midline as speed rises (narrower than the
	# hips), which is what makes the side-to-side sway and waddle earned.
	var w := HIP_X * lerpf(lerpf(1.0, .75, smoothstep(.2, 1.0, v)), .55, smoothstep(1.7, 2.9, v))
	if carry: w = maxf(w, HIP_X * .85) * 1.08
	elif _tool_mode(): w = maxf(w, HIP_X * .9)
	return w

func _foot_frame(yaw: float, normal: Vector3) -> Basis:
	# Skeleton-rest -> world rotation of a foot at `yaw` on a support `normal`.
	var b := Basis(Vector3.UP, yaw)
	var n := normal.normalized()
	if n.dot(Vector3.UP) < .9999: b = Basis(Quaternion(Vector3.UP, n)) * b
	return b

func _roll_axis(side: int, frame: Basis, normal: Vector3) -> Vector3:
	# Positive rotation about this axis lifts the heel (the toes stay down).
	var axis := normal.cross(frame * _toe_dir[side])
	return axis.normalized() if axis.length_squared() > 1e-6 else frame * Vector3.RIGHT

func _foot_basis(side: int, yaw: float, heel_up: float, normal: Vector3) -> Basis:
	var frame := _foot_frame(yaw, normal)
	var b := frame * _rest_foot[side]
	if absf(heel_up) > .0001: b = Basis(_roll_axis(side, frame, normal), heel_up) * b
	return b.orthonormalized()

func _support_alive(side: int) -> Node3D:
	var ref: WeakRef = support[side]
	var node: Object = ref.get_ref() if ref else null
	if node is Node3D and (node as Node3D).is_inside_tree() and not (node as Node3D).is_queued_for_deletion(): return node
	return null

func _plant(side: int, hit: Dictionary, point: Vector3, yaw: float) -> void:
	state[side] = PLANTED
	_plant_hit[side] = {}
	t[side] = 0.0
	stance_age[side] = 0.0
	foot_yaw[side] = yaw
	_peel[side] = 0.0
	_drop[side] = false
	_roll_off[side] = Vector3.ZERO
	if hit.is_empty() or not hit.collider is Node3D:
		support[side] = null
		support_rid[side] = RID()
		local_point[side] = point
		local_forward[side] = facing(yaw)
		return
	var body: Node3D = hit.collider
	support[side] = weakref(body)
	support_rid[side] = hit.rid
	local_point[side] = body.to_local(point)
	local_forward[side] = body.global_basis.inverse() * facing(yaw)

func validate_landing(side: int, hip: Vector3) -> void:
	# Called by the pose with this tick's real hip: a footfall the leg will
	# not reach at contact is pulled toward the hip now and committed, so the
	# foot lands exactly where it plants (no slide at contact).
	# Corrections must stay absorbable by the fading re-target offset: none
	# in the last part of the swing, and only small ones once it is late.
	if state[side] == PLANTED or t[side] < .45 or t[side] > .97: return
	var rate: float = maxf(min_rate[side], phase_rate / maxf(1.0 - p0[side], .05) if state[side] == SWING and moving else min_rate[side])
	var t_rem := (1.0 - t[side]) / maxf(rate, .001)
	var hip_contact := hip + velocity.slide(Vector3.UP) * t_rem - Vector3.UP * clampf(.2 - body_drop, 0.0, .02)
	var ankle: Vector3 = landing[side] + Vector3.UP * float(pose._ankle_height[side])
	# Land on a slightly flexed knee: a fully straight reach whips the knee.
	var reach: float = float(worker._leg_lengths[side]) - .035
	var offset := ankle - hip_contact
	if offset.length() <= reach or absf(offset.y) >= reach: return
	var horizontal := offset.slide(Vector3.UP).limit_length(sqrt(reach * reach - offset.y * offset.y))
	var wanted := Vector3(hip_contact.x + horizontal.x, landing[side].y, hip_contact.z + horizontal.z)
	var step := (.008 if t[side] > .88 else .015) if t[side] > .7 else .06
	wanted = landing[side] + (wanted - landing[side]).slide(Vector3.UP).limit_length(step)
	var hit: Dictionary = _ground(wanted)
	if hit.is_empty() or not hit.collider is Node3D: return
	_frozen[side] = true
	_frozen_support[side] = weakref(hit.collider)
	_frozen_local[side] = (hit.collider as Node3D).to_local(hit.position)
	landing[side] = hit.position

func defer_contact(side: int) -> bool:
	# The pose found this tick's footfall below the real hip's reach (steep
	# descent): keep reaching for it a little longer instead of planting a
	# stretched leg that would have to slide back toward the hip.
	if state[side] != PLANTED or _contact_delay[side] >= 14: return false
	var delay := _contact_delay[side] + 1
	var body := _support_alive(side)
	state[side] = _contact_kind[side]
	t[side] = .999
	_t_prev[side] = .999
	_frozen[side] = true
	_frozen_support[side] = weakref(body) if body else null
	_frozen_local[side] = local_point[side]
	_contact_delay[side] = delay
	landing_count[side] -= 1
	out_planted[side] = false
	# A drop landing keeps falling with the cube instead of a timed curve.
	_drop[side] = _drop_planted[side]
	return true

func replant(side: int, hit: Dictionary, point: Vector3) -> void:
	# Pose moved a fresh contact to where the leg can actually reach it.
	_plant(side, hit, point, foot_yaw[side])
	out_sole[side] = point
	out_hit[side] = hit

func _planted_point(side: int) -> Vector3:
	var body := _support_alive(side)
	return body.to_global(local_point[side]) if body else local_point[side]

func _planted_yaw(side: int) -> float:
	var body := _support_alive(side)
	if not body: return foot_yaw[side]
	return yaw_of((body.global_basis * local_forward[side]).slide(Vector3.UP))

func _foot_now(side: int) -> Vector3:
	return _planted_point(side) if state[side] == PLANTED else out_sole[side]

func _lift_off(side: int, kind: int, rate_floor: float, base_lift: float) -> void:
	# A planted foot leaves from its rolled (heel-up) sole, so the swing
	# continues the published foot exactly instead of snapping it flat.
	var from := out_sole[side] if state[side] != PLANTED else _planted_point(side) + _roll_off[side]
	start_world[side] = from
	var body := _support_alive(side) if state[side] == PLANTED else null
	if body:
		local_point[side] = body.to_local(from)
	else:
		support[side] = null
	start_yaw[side] = _planted_yaw(side) if state[side] == PLANTED else foot_yaw[side]
	start_normal[side] = pose._sole_normals[side] if pose._sole_normals[side].is_finite() else Vector3.UP
	if debug_log: print("GAIT lift side=%d kind=%d from_state=%d phase=%.3f local=%.3f duty=%.2f armed=%s moving=%s" % [side, kind, state[side], phase, _local_phase(side), duty, armed[side], moving])
	_peel0[side] = _peel[side] if state[side] == PLANTED else 0.0
	_peel[side] = 0.0
	_roll_off[side] = Vector3.ZERO
	state[side] = kind
	t[side] = 0.0
	p0[side] = _local_phase(side)
	min_rate[side] = rate_floor
	lift[side] = base_lift
	_sampled_for[side] = Vector3.INF
	_clear_lift[side] = 0.0
	_t_prev[side] = -1.0
	_frozen[side] = false
	_contact_delay[side] = 0
	_pass[side] = Vector3.ZERO
	_drop[side] = false
	_drop_planted[side] = false
	armed[side] = false

func _swing_start(side: int) -> Vector3:
	# The lift-off point travels with its support (moving decks).
	var body := _support_alive(side)
	return body.to_global(local_point[side]) if body else start_world[side]

func _ground(point: Vector3) -> Dictionary:
	# Same column probe as wako_pose._walk_ground, but it also ignores the
	# creature's own carried bodies (a foot-held mallet is a layer-1 body that
	# would otherwise look like a raised floor under its own swing).
	_query.from = Vector3(point.x, maxf(point.y + .55, worker.global_position.y + .25), point.z)
	_query.to = Vector3(point.x, minf(point.y - .8, worker.global_position.y - worker.ride_height - .45), point.z)
	var hit := _space.intersect_ray(_query)
	return hit if not hit.is_empty() and hit.normal.y > .6 else {}

func _refresh_query() -> void:
	# Exclusions only change with carried bodies/ragdoll state: rebuild on a
	# key change (or every half second), not every tick.
	var key := 0
	for body: Variant in [worker.equipped_tool, worker._cargo_source]:
		if is_instance_valid(body): key = key * 31 + (body as Object).get_instance_id() + (7 if body.get("carrier") != null else 0)
	_query_age += 1
	if key != _query_key or _query_age > 60 or _space == null:
		_query_key = key
		_query_age = 0
		var exclusions: Array[RID] = worker.query_exclusions()
		for body: Variant in [worker.equipped_tool, worker._cargo_source]:
			if body is CollisionObject3D and is_instance_valid(body) and (body as Node).get("carrier") != null \
				and body.get("carrier") in [worker.tool_anchor, worker.head_anchor, worker.back_tool.back_anchor if worker.back_tool else null]:
				exclusions.append((body as CollisionObject3D).get_rid())
		_query.exclude = exclusions
		_query.collision_mask = 1
		_space = worker.get_world_3d().direct_space_state

# ------------------------------------------------------------------ resync
func _init_from_published(side: int, sk: Skeleton3D) -> void:
	var valid: bool = pose.evaluated_valid
	var sole: Vector3
	var published: Basis
	if _air_fresh:
		# Landing: the feet continue from the flying pose air() just showed
		# (the skeleton has meanwhile been reset to an authored clip).
		sole = out_sole[side]
		published = out_basis[side]
		valid = true
	elif valid:
		sole = pose.evaluated_soles[side]
		published = pose.evaluated_ankles[side]
	else:
		var foot := sk.get_bone_global_pose(pose._chains[side][2])
		sole = sk.global_transform * (foot * Vector3(0, pose._ankle_height[side], 0))
		published = sk.global_basis * foot.basis
	var yaw: float = worker._heading
	var forward: Vector3 = (published.orthonormalized() * _rest_foot[side].inverse() * Vector3.FORWARD).slide(Vector3.UP)
	if forward.length_squared() > .01: yaw = yaw_of(forward)
	var hit: Dictionary = _ground(sole)
	out_sole[side] = sole
	requested[side] = Vector3.INF
	foot_yaw[side] = yaw
	_peel[side] = 0.0
	var normal: Vector3 = hit.normal if not hit.is_empty() else Vector3.UP
	# The releasing owner's foot orientation fades into the planned one.
	_hand_rot[side] = (published.get_rotation_quaternion() * _foot_basis(side, yaw, 0.0, normal).get_rotation_quaternion().inverse()).normalized()
	_hand_off[side] = Vector3.ZERO
	# A sole resting on its support is planted right there, whatever flags the
	# releasing owner published: re-lifting it (both feet at once after every
	# work action) read as an unsupported double hop.
	var gap: float = hit.normal.dot(sole - hit.position) if not hit.is_empty() else INF
	if absf(gap) < .02 or hit.is_empty():
		_plant(side, hit, hit.position if not hit.is_empty() else sole, yaw)
		if not hit.is_empty(): _hand_off[side] = sole - hit.position
		armed[side] = true
	else:
		# Genuinely airborne (an action's raised foot, a landing): it comes
		# down from exactly where it is, with a small arc.
		state[side] = PLANTED  # so _lift_off reads the published point below
		support[side] = null
		local_point[side] = sole
		_roll_off[side] = Vector3.ZERO
		_lift_off(side, SETTLE, 1.0 / T_RECOVER, clampf(.035 - .25 * maxf(gap, 0.0), .012, .035))
		start_world[side] = sole
		support[side] = null
		# Touchdown of the capsule's long support ray after air(): the reaching
		# feet keep falling with the cube and reach on down until they touch.
		_drop[side] = _air_fresh

func reset() -> void:
	# Hard reset (ragdoll, head leap, a fall the gait did not start): those
	# owners never show the acting root, so the next start fades it in.
	airborne = false
	_air_fresh = false
	release(0.0, true)

func release(delta: float, hard := false) -> void:
	# Another owner took the legs: the acting root fades out continuously
	# (locomotion weight, crouch, lean, bank, eye lead, reach drop) instead of
	# vanishing in one tick, and a resume starts from whatever is left.
	active = false
	moving = false
	moving_age = 0.0
	_launch_hold = 0.0
	_launch_t = -1.0
	_last_velocity = Vector3.INF
	if hard:
		locomotion_weight = 0.0
		_lw_v = 0.0
		body_y = 0.0
		_by_v = 0.0
		body_bob = 0.0
		body_lean = 0.0
		_lean_v = 0.0
		body_nod = 0.0
		_roll_s = 0.0
		_roll_v = 0.0
		_roll_osc = 0.0
		_shift_s = 0.0
		_shift_v = 0.0
		_shift_osc = 0.0
		_yaw_s = 0.0
		_yaw_v = 0.0
		body_twist = 0.0
		body_drop = 0.0
		_drop_v = 0.0
		settle_dip = 0.0
		squash = 0.0
		_squash_amp = 0.0
		_brake_time = 0.0
		_publish_totals()
		return
	if delta <= 0.0: return
	var w := spring(locomotion_weight, _lw_v, 0.0, 11.0, delta)
	locomotion_weight = clampf(w.x, 0.0, 1.0)
	_lw_v = w.y
	var y := spring(body_y, _by_v, 0.0, 14.0, delta)
	body_y = y.x
	_by_v = y.y
	var l := spring(body_lean, _lean_v, 0.0, 11.0, delta)
	body_lean = l.x
	_lean_v = l.y
	var s := spring(_shift_s, _shift_v, 0.0, 14.0, delta)
	_shift_s = s.x
	_shift_v = s.y
	var r := spring(_roll_s, _roll_v, 0.0, 14.0, delta)
	_roll_s = r.x
	_roll_v = r.y
	var yw := spring(_yaw_s, _yaw_v, 0.0, 12.0, delta)
	_yaw_s = yw.x
	_yaw_v = yw.y
	# Phase-locked layers freeze and are scaled out by the fading weight.
	settle_dip = move_toward(settle_dip, 0.0, .4 * delta)
	_update_squash(delta)
	var d := spring(body_drop, _drop_v, 0.0, 9.0, delta)
	_drop_v = clampf(d.y, -DROP_SPEED, DROP_SPEED)
	body_drop = maxf(body_drop + _drop_v * delta, 0.0)
	_publish_totals()

func acting() -> bool:
	# Whether acting_root still has anything to show (also while releasing).
	return active or locomotion_weight > .001 or body_drop > .0005 or absf(settle_dip) > .0005 or absf(squash) > .0005

# ------------------------------------------------------------------ main
func plan(sk: Skeleton3D, delta: float, can_settle: bool, hold_feet: bool, lenient := false) -> void:
	if delta <= 0.0: return
	var started := Time.get_ticks_usec()
	up = worker.ground_normal if worker.ground_normal.is_finite() else Vector3.UP
	hold = hold_feet
	settle_allowed = can_settle and not hold_feet
	_refresh_query()
	if not active or not pose.evaluated_valid:
		for side in 2: _init_from_published(side, sk)
		_last_velocity = Vector3.INF
		phase_rate = 0.0
		if _air_fresh:
			# Touchdown after a drop: the cube squashes with the impact.
			_start_squash(clampf(-_air_vy * .011, .014, .045), .2)
	else:
		for side in 2:
			# Another owner (tool clearance, head/back endpoints, IK reach) moved
			# the published sole away from the request: continue from it.
			var tolerance := .02 if state[side] == PLANTED else .035
			# The retained-tool clearance block adds its own bounded lift/shift
			# (<= ~.1 m) to the tool foot after this plan: that is not a new owner.
			if worker.tool_foot_occupied() and side == worker.tool_foot_side(): tolerance = .2
			if lenient: tolerance = .12
			if requested[side].is_finite() and pose.evaluated_soles[side].distance_to(requested[side]) > tolerance:
				_init_from_published(side, sk)
	var landed := _air_fresh
	_air_fresh = false
	airborne = false
	active = true
	_update_clock(delta)
	if landed and moving and _drop[0] and _drop[1]: _land_running()
	for side in 2: debug_planned[side] = Vector3.INF
	_events(delta)
	for side in 2: _foot_output(side, delta)
	_update_body(delta)
	plan_usec = Time.get_ticks_usec() - started

func _update_clock(delta: float) -> void:
	velocity = (worker.linear_velocity - worker.ground_velocity).slide(up)
	speed = velocity.length()
	if _last_velocity.is_finite():
		var raw := (velocity - _last_velocity) / delta
		accel = accel.lerp(raw.limit_length(30.0), 1.0 - exp(-18.0 * delta))
	else: accel = Vector3.ZERO
	_last_velocity = velocity
	carry = worker.carrying
	flee = worker.fear_time > 0.0
	var desired: Vector3 = worker.locomotion_desired
	var intent: bool = desired.length() > .12 and not hold
	var was_moving := moving
	moving = not hold and (intent or speed > (.2 if moving else .35))
	moving_age = moving_age + delta if moving else 0.0
	if moving and not was_moving: moving_age = 0.0
	half_stride = _stride(speed)
	duty = _duty(speed)
	if 2.0 * half_stride * duty > MAX_STANCE: half_stride = MAX_STANCE * .5 / duty
	run_weight = 0.0 if carry else smoothstep(1.7, 2.9, speed)
	var any_swing := state[0] == SWING or state[1] == SWING
	phase_rate = speed / (2.0 * half_stride) if (moving or any_swing) else 0.0
	phase = fposmod(phase + phase_rate * delta, 1.0)
	_recent_speed = maxf(speed, _recent_speed - delta * 2.5)
	if moving and not was_moving: _start_step()

func _start_step() -> void:
	# Launch: the foot farther behind the requested motion steps first.
	if debug_log: print("GAIT start_step states=%s drop=%s speed=%.2f phase=%.2f" % [state, _drop, speed, phase])
	if state[0] == SWING or state[1] == SWING: return
	var desired: Vector3 = worker.locomotion_desired
	var direction := desired.slide(up)
	if direction.length_squared() < .01: direction = velocity
	if direction.length_squared() < .01: direction = facing(worker._heading)
	direction = direction.normalized()
	var body: Vector3 = worker.global_position
	var behind0 := -(_foot_now(0) - body).dot(direction)
	var behind1 := -(_foot_now(1) - body).dot(direction)
	var lead := 0 if behind0 > behind1 else 1
	if absf(behind0 - behind1) < .03:
		# Tie: the outside foot of the coming turn opens the step.
		var error := wrapf(yaw_of(direction) - worker._heading, -PI, PI)
		lead = 1 if error > 0.0 else 0
	var d := duty
	if _drop[0] or _drop[1]:
		# Still landing from a drop: the cadence resumes from those contacts.
		return
	if state[0] == SETTLE or state[1] == SETTLE:
		# A recovering foot (after a landing or an action) is already in the
		# air: it becomes the launch swing instead of landing and re-lifting.
		if state[lead] != SETTLE: lead = 1 - lead
		phase = fposmod(d + t[lead] * (1.0 - d) - .5 * lead, 1.0)
		state[lead] = SWING
		p0[lead] = d
		armed[1 - lead] = _local_phase(1 - lead) < d
		return
	phase = fposmod(d - .5 * lead, 1.0)
	armed[lead] = true
	armed[1 - lead] = _local_phase(1 - lead) < duty
	if speed < .5:
		# Anticipation: shift onto the support foot and gather for ~65 ms.
		_launch_hold = LAUNCH_HOLD
		_launch_t = 0.0
		_launch_side = lead

func _events(delta: float) -> void:
	var stopping := not moving
	if _drop_planted[0] and _drop_planted[1] and state[0] == PLANTED and state[1] == PLANTED and stance_age[0] > 0.0 and stance_age[1] > 0.0:
		# Both feet held after a drop: re-phase like a launch, so the run
		# resumes with one foot (never a two-footed hop out of the landing).
		_drop_planted[0] = false
		_drop_planted[1] = false
		if moving and not hold: _start_step()
	_launch_hold = maxf(_launch_hold - delta, 0.0)
	for side in 2:
		var p := _local_phase(side)
		var d := duty
		match state[side]:
			PLANTED:
				stance_age[side] += delta
				if p < d: armed[side] = true
				if not moving or hold: continue
				var other_planted := state[1 - side] == PLANTED
				# Walking keeps a supporting foot: wait for the partner's contact
				# (flight is for running; a foot-held tool never flies, since its
				# whole-tool clearance needs a genuinely supported opposite sole).
				var tool_foot: bool = _is_tool_foot(side)
				var may_fly: bool = duty < .49 and not worker.tool_foot_occupied()
				if not other_planted and not may_fly and not _overreached(side): continue
				if not other_planted and tool_foot: continue
				if (armed[side] and p >= d and _launch_hold <= 0.0) or (p > .8 * d and other_planted == false and _pushed_off(side, delta)):
					var first := moving_age < .12
					_lift_off(side, SWING, 1.0 / (T_FIRST_SWING if first else T_SWING_MAX), _base_lift(side))
				elif _overreached(side):
					# Never drag a plant past reach: release it now and re-phase so
					# the alternation continues from this very step.
					if other_planted:
						phase = fposmod(d - .5 * side, 1.0)
					_lift_off(side, SWING, 1.0 / T_RECOVER, _base_lift(side))
			SWING, SETTLE:
				if _drop[side]: continue
				var rate := min_rate[side]
				if state[side] == SWING and not stopping:
					rate = maxf(rate, phase_rate / maxf(1.0 - p0[side], .05))
				if stopping and state[side] == SWING:
					rate = maxf(rate, (1.0 - t[side]) / T_STOP)
					min_rate[side] = rate
				t[side] = minf(t[side] + rate * delta, 1.0)
	# Stand-still settling (also stepping turns), one foot at a time. It may
	# begin while the body is still braking, aimed at where it will come to
	# rest, so a stop reads as one step-together instead of a late shuffle.
	quiet = false
	if not moving and settle_allowed and state[0] == PLANTED and state[1] == PLANTED and speed < 1.0:
		var worst := -1
		var worst_score := 0.0
		var lead := _lead_heading()
		_predict(STOP_HORIZON, Vector3.ZERO)
		var rest: Vector3 = worker.global_position + _pred_x
		for side in 2:
			var neutral := rest + _lateral(side, lead, HIP_X)
			var offset := (_planted_point(side) - neutral).slide(Vector3.UP).length()
			var yaw_error := absf(wrapf(_planted_yaw(side) - lead, -PI, PI))
			var score := maxf(offset / SETTLE_DISTANCE, yaw_error / SETTLE_YAW)
			if score > 1.0 and score > worst_score and stance_age[side] > .05:
				worst = side
				worst_score = score
		if worst >= 0:
			var neutral := rest + _lateral(worst, lead, HIP_X)
			var distance := (_planted_point(worst) - neutral).slide(Vector3.UP).length()
			var duration := clampf(.12 + .2 * distance, .13, .2)
			_lift_off(worst, SETTLE, 1.0 / duration, clampf(.03 + .12 * distance, .035, .065))
		else: quiet = speed < .25

func _dip(v: float) -> float:
	# Light walking crouch (legs extend so the bob shows); a run sits lower.
	return -.012 * smoothstep(.1, 1.0, v) - .008 * smoothstep(1.2, 3.2, v)

func _roll_weight() -> float:
	return smoothstep(.3, 1.2, speed)

func _base_lift(side: int) -> float:
	if _is_tool_foot(side): return .075
	# A visible knee drive: ~10 cm clearance walking, a high heel tuck running.
	var l := lerpf(.095, .20, smoothstep(1.2, 3.2, speed))
	return l * .6 if carry else l

func _peel_max() -> float:
	# Heel-up roll about the toe joint at lift-off: subtle walking, a real
	# push-off running.
	return lerpf(.22, .32, run_weight) * (.6 if carry else 1.0)

func _pushed_off(side: int, delta: float) -> bool:
	# Running push-off: the stance leg leaves as it reaches its extension
	# (knee ~25 deg), one or two ticks before the clock's toe-off, instead of
	# snapping straight on its last stance tick.
	if not pose.evaluated_valid or _is_tool_foot(side): return false
	var rebase: Transform3D = worker.global_transform * pose.evaluated_worker.affine_inverse()
	var hip: Vector3 = rebase * pose.evaluated_hips[side] + velocity * delta * 1.5
	var ankle: Vector3 = out_sole[side] - out_basis[side] * Vector3(0, float(pose._ankle_height[side]), 0)
	return hip.distance_to(ankle) > float(worker._leg_lengths[side]) - .02

func _overreached(side: int) -> bool:
	if not pose.evaluated_valid: return false
	var rebase: Transform3D = worker.global_transform * pose.evaluated_worker.affine_inverse()
	var hip: Vector3 = rebase * pose.evaluated_hips[side]
	var sole := _planted_point(side)
	var ankle: Vector3 = sole + Vector3.UP * float(pose._ankle_height[side])
	var reach: float = float(worker._leg_lengths[side]) - .012
	if hip.distance_to(ankle) > reach - .004: return true
	var direction := velocity.normalized() if speed > .2 else facing(worker._heading)
	# A foot-held mallet points forward-up: behind the hip it swings under the
	# cube, so that foot keeps its stance in front and leaves early.
	if _is_tool_foot(side): return -(sole - hip).dot(direction) > .04
	return -(sole - hip).dot(direction) > stance_distance(speed) * .5 + .12

func _landing_target(side: int, t_rem: float) -> void:
	# Sets _lt_point (world, unprojected), _lt_heading and _lt_hip.
	if moving and not hold:
		var desired: Vector3 = worker.locomotion_desired
		_predict(t_rem, desired)
		var v_land: Vector3 = _pred_v
		var heading := _heading_at(t_rem)
		var vl := v_land.length()
		var point: Vector3 = worker.global_position + _pred_x + worker.ground_velocity * t_rem + _lateral(side, heading, _track(vl))
		var direction := v_land / vl if vl > .2 else facing(heading)
		_lt_hip = point + Vector3.UP * (HIP_ABOVE_BODY + _dip(vl) - body_drop - REACH_DROP)
		# Running feet land a little under the body (not a straight-legged
		# overstride) and leave further behind it.
		var lead := lerpf(.5, .44, smoothstep(1.7, 2.9, vl))
		point += direction * (stance_distance(vl) * lead + (TOOL_STANCE_LEAD if _is_tool_foot(side) else 0.0))
		# Never cross or brush the other leg: keep the soles FOOT_GAP apart
		# across the heading (the inside foot of a turn steps out). Checked
		# across both the predicted and the current heading, since a quick
		# zigzag can turn the cube back before the foot lands.
		var other := 1 - side
		var anchor: Vector3 = _planted_point(other) if state[other] == PLANTED else landing[other]
		var outward := -1.0 if side == 0 else 1.0
		for frame_heading: float in [heading, worker._heading]:
			var right := Basis(Vector3.UP, frame_heading) * Vector3.RIGHT
			var gap := (point - anchor).slide(Vector3.UP).dot(right) * outward
			if gap < FOOT_GAP: point += right * outward * (FOOT_GAP - gap)
		_lt_point = point
		_lt_heading = heading
		return
	# Stopping or settling: land where the hip will come to rest, facing the
	# requested heading (with a bounded lead so turning in place can continue).
	_predict(STOP_HORIZON, Vector3.ZERO)
	var heading := _lead_heading()
	_lt_point = worker.global_position + _pred_x + worker.ground_velocity * t_rem + _lateral(side, heading, HIP_X)
	_lt_heading = heading
	_lt_hip = _lt_point + Vector3.UP * (HIP_ABOVE_BODY - body_drop - REACH_DROP)

func _sample_corridor(side: int, from: Vector3, to: Vector3) -> void:
	# Look-ahead: ground at 1/3 and 2/3 of the horizontal corridor (cached
	# per landing). A slope keeps its straight line; an edge chooses the
	# early-rise / late-descent profile; the apex then clears every sample
	# by 6 cm above the path the foot will actually take.
	_sampled_for[side] = to
	var heights: Array[float] = [0.0, 0.0, 0.0]
	var planar := true
	for i in CORRIDOR.size():
		var k: float = CORRIDOR[i]
		var hit: Dictionary = _ground(from.lerp(to, k) + Vector3.UP * .3)
		var h: float = hit.position.y if not hit.is_empty() else lerpf(from.y, to.y, k)
		heights[i] = h
		planar = planar and absf(h - lerpf(from.y, to.y, k)) < .025
	_planar[side] = planar
	var rise := to.y - from.y
	var need := 0.0
	for i in CORRIDOR.size():
		var t_k := _glide_inverse(CORRIDOR[i])
		var path := from.y + rise * _vertical(side, rise, t_k)
		# Only ground that actually protrudes above the planned path asks for
		# a higher apex (flat ground keeps the ordinary lift).
		var protrusion := heights[i] - path
		if protrusion > .01: need = maxf(need, (protrusion + .05) / maxf(_bump(t_k), .25))
	_clear_lift[side] = clampf(need, 0.0, .45)

func _vertical(side: int, rise: float, tt: float) -> float:
	if _planar[side]: return glide(tt)
	if rise > .03: return min_jerk(tt / .65)            # step up: rise early
	if rise < -.03: return min_jerk((tt - .22) / .78)   # step down: descend after the edge
	return glide(tt)

func _curve(side: int, from: Vector3, land: Vector3, tt: float) -> Vector3:
	var s := glide(tt)
	var rise := land.y - from.y
	var point := Vector3(lerpf(from.x, land.x, s), from.y + rise * _vertical(side, rise, tt), lerpf(from.z, land.z, s))
	point.y += maxf(lift[side], _clear_lift[side]) * _bump(tt)
	point += _pass[side] * sin(PI * s)
	return point

func _swing_point(side: int, from: Vector3, land: Vector3, tt: float, previous: Vector3, delta: float) -> Vector3:
	var point := _curve(side, from, land, tt)
	if _t_prev[side] >= 0.0 and tt < 1.0 and delta > 0.0:
		# Re-targeting (new prediction, stop, step height) must not jump the
		# foot: carry last tick's offset from the re-targeted curve and let it
		# fade with the remaining progress, so contact is still exact.
		var before := _curve(side, from, land, _t_prev[side])
		var fade := (1.0 - glide(tt)) / maxf(1.0 - glide(_t_prev[side]), .0001)
		point += (previous - before) * clampf(fade, 0.0, 1.0)
	return point

func _update_pass(side: int, from: Vector3, land: Vector3) -> void:
	# A swing whose straight path would brush the planted foot (turns,
	# narrow tracks) bulges around it; the endpoints are already apart.
	_pass[side] = Vector3.ZERO
	var other := 1 - side
	if state[other] != PLANTED: return
	var p := _planted_point(other)
	var a := Vector2(from.x, from.z)
	var ab := Vector2(land.x, land.z) - a
	var length2 := ab.length_squared()
	if length2 < 1e-4: return
	var c := Vector2(p.x, p.z)
	var s := clampf((c - a).dot(ab) / length2, .15, .85)
	var away := a + ab * s - c
	var d := away.length()
	if d >= FOOT_GAP: return
	# Around the planted foot on this leg's own side (left foot passes left).
	var side_dir := Vector2(-ab.y, ab.x).normalized() * (-1.0 if side == 0 else 1.0)
	var n := away / d if d > 1e-4 else side_dir
	if n.dot(side_dir) < 0.0:
		# Starting on the wrong side of it (a crossed stance): go round the
		# correct side rather than straight through the other shin.
		n = side_dir
		d = 0.0
	_pass[side] = Vector3(n.x, 0.0, n.y) * (FOOT_GAP - d)

func _foot_output(side: int, delta: float) -> void:
	if state[side] == PLANTED:
		_planted_output(side, delta)
	elif _drop[side]:
		_drop_output(side, delta)
	else:
		_swing_output(side, delta)
	_apply_handoff(side, delta)

func _land_running() -> void:
	# A running landing is one footfall, not two: the forward foot comes
	# down (drop), the trailing foot turns straight into the next swing.
	var direction := velocity.normalized() if speed > .2 else facing(worker._heading)
	var body: Vector3 = worker.global_position
	var lead := 0 if -(out_sole[0] - body).dot(direction) > -(out_sole[1] - body).dot(direction) else 1
	_drop[lead] = false
	_drop_planted[lead] = false
	start_world[lead] = out_sole[lead]
	support[lead] = null
	state[lead] = SWING
	t[lead] = 0.0
	_t_prev[lead] = -1.0
	p0[lead] = duty
	min_rate[lead] = 1.0 / T_SWING_MAX
	lift[lead] = _base_lift(lead) * .6
	_sampled_for[lead] = Vector3.INF
	phase = fposmod(duty - .5 * lead, 1.0)
	# The forward foot steps down to a real running footfall (a brisk timed
	# step onto the predicted landing), not a stretched drop behind the cube.
	var fwd := 1 - lead
	_drop[fwd] = false
	_drop_planted[fwd] = false
	start_world[fwd] = out_sole[fwd]
	t[fwd] = 0.0
	_t_prev[fwd] = -1.0
	min_rate[fwd] = 1.0 / .14
	lift[fwd] = .02
	_sampled_for[fwd] = Vector3.INF
	if debug_log: print("GAIT land_running lead=%d" % lead)

func _drop_output(side: int, delta: float) -> void:
	# Feet arriving from air(): carried by the cube's own fall plus a reach of
	# 2.4 m/s further down (the pose clamps them to the leg), drifting toward
	# their footfall, and planted the moment they meet the ground. The cube
	# then keeps settling onto bending knees (absorb), never a fold-and-snap.
	# From the sole the leg really reached (the pose clamps it to the leg), so
	# contact means the reachable sole met the ground.
	var reached: Vector3 = pose.evaluated_soles[side] if pose.evaluated_valid else out_sole[side]
	var p: Vector3 = reached + worker.linear_velocity * delta
	_landing_target(side, .1)
	p = p.move_toward(Vector3(_lt_point.x, p.y, _lt_point.z), 1.6 * delta)
	p.y -= 2.4 * delta
	var hit := _ground(p)
	var yaw := lerp_angle(foot_yaw[side], _lt_heading, minf(1.0, 8.0 * delta))
	foot_yaw[side] = yaw
	landing_yaw[side] = yaw
	t[side] += delta
	# Touching means the sole the leg really reached is on the ground: until
	# then the stretched leg keeps reaching while the cube comes down onto
	# it (a long fall gives up waiting after .3 s).
	var below := _ground(reached)
	if not below.is_empty() and (reached.y <= below.position.y + .006 or t[side] > .3):
		hit = below
		var touch: Vector3 = hit.position
		_contact_kind[side] = SETTLE
		_plant(side, hit, touch, yaw)
		_hand_off[side] = Vector3.UP * clampf(reached.y - touch.y, 0.0, .03)
		landing_count[side] += 1
		landing_strength[side] = clampf(-_air_vy / 4.0, .3, 1.0)
		if moving and not hold and state[1 - side] == SWING:
			# The running landing's stance starts here; the cadence follows it.
			phase = fposmod(-.5 * side, 1.0)
			_drop_planted[side] = false
		out_sole[side] = touch
		out_basis[side] = _foot_basis(side, yaw, 0.0, hit.normal)
		out_planted[side] = true
		out_hit[side] = hit
		out_toe[side] = 0.0
		armed[side] = _local_phase(side) < duty
		if state[1 - side] != SWING: _drop_planted[side] = true
		if debug_log: print("GAIT drop contact side=%d moving=%s other_drop=%s" % [side, moving, _drop[1 - side]])
		return
	out_sole[side] = p
	out_basis[side] = _foot_basis(side, yaw, 0.0, hit.normal if not hit.is_empty() else Vector3.UP)
	out_planted[side] = false
	out_hit[side] = hit
	out_toe[side] = move_toward(out_toe[side], 0.0, 4.0 * delta)

func _apply_handoff(side: int, delta: float) -> void:
	if _hand_off[side].length_squared() > 1e-8 or not _hand_rot[side].is_equal_approx(Quaternion.IDENTITY):
		# Fade out the releasing owner's last foot pose (<= 2 cm, any tilt).
		out_sole[side] += _hand_off[side]
		out_basis[side] = (Basis(_hand_rot[side]) * out_basis[side]).orthonormalized()
		var k := exp(-18.0 * delta)
		_hand_off[side] *= k
		_hand_rot[side] = Quaternion.IDENTITY.slerp(_hand_rot[side], k).normalized()
		if _hand_off[side].length() < .0002: _hand_off[side] = Vector3.ZERO
		if _hand_rot[side].get_angle() < .002: _hand_rot[side] = Quaternion.IDENTITY

func _planted_output(side: int, delta: float) -> void:
	var point := _planted_point(side)
	var body := _support_alive(side)
	# A plant on a static body re-observes its column every 6th tick (it
	# cannot move); moving supports and fresh plants are probed every tick.
	var hit: Dictionary = _plant_hit[side]
	_plant_hit_age[side] += 1
	if hit.is_empty() or not body is StaticBody3D or _plant_hit_age[side] >= 6 or stance_age[side] < .05:
		hit = _ground(point)
		_plant_hit[side] = hit
		_plant_hit_age[side] = 0
	var same: bool = not hit.is_empty() and (support[side] == null or (body != null and hit.collider == body and hit.rid == support_rid[side]))
	if not same or absf(hit.normal.dot(point - hit.position)) > .03:
		# The plant's support vanished/changed under the sole: recover.
		out_sole[side] = point
		_lift_off(side, SETTLE, 1.0 / T_RECOVER, .04)
		start_world[side] = point
		support[side] = null
		_swing_output(side, 0.0)
		return
	if support[side] == null and not hit.is_empty() and hit.collider is Node3D:
		_plant(side, hit, point, foot_yaw[side])
	var native_peer: bool = worker.idle_play and worker.idle_play.get("upside_down") and worker.idle_play.upside_down.owns_lower_stance()
	if native_peer and body and hit.normal.y > .97 and pose.evaluated_valid:
		# A braced peer recoil may slide this same floor plant within reach.
		var reachable: Vector3 = pose._reachable_plant(pose.get_skeleton(), side, point, Basis.IDENTITY, hit.normal)
		var previous: Vector3 = pose.evaluated_soles[side] + worker.ground_velocity * delta
		var next: Vector3 = previous.move_toward(reachable, minf(.075, delta * 5.4))
		var next_hit: Dictionary = _ground(next)
		if not next_hit.is_empty() and next_hit.collider == body and next_hit.rid == support_rid[side]:
			point = next_hit.position
			hit = next_hit
			_plant_hit[side] = {}
			local_point[side] = body.to_local(point)
	point += hit.normal * maxf(-hit.normal.dot(point - hit.position), 0.0)
	var yaw := _planted_yaw(side)
	foot_yaw[side] = yaw
	# Heel-to-toe roll: late in a moving stance the heel peels up about the
	# toe joint (the toe pad stays flat and fixed on the ground), which is the
	# push-off. A stop lets the heel back down quickly, never in one tick.
	var u := clampf(_local_phase(side) / maxf(duty, .05), 0.0, 1.0) if moving and not hold else 0.0
	var wanted := _peel_max() * smoothstep(.5, 1.0, u) * _roll_weight() if not _is_tool_foot(side) else 0.0
	_peel[side] = move_toward(_peel[side], wanted, PEEL_RATE * maxf(delta, 1.0 / 120.0))
	var frame := _foot_frame(yaw, hit.normal)
	var basis := (frame * _rest_foot[side]).orthonormalized()
	var sole := point
	if _peel[side] > .0001:
		var roll := Basis(_roll_axis(side, frame, hit.normal), _peel[side])
		var joint := point + frame * _ball_off[side]
		sole = joint + roll * (point - joint)
		basis = (roll * basis).orthonormalized()
	_roll_off[side] = sole - point
	out_sole[side] = sole
	out_basis[side] = basis
	out_planted[side] = true
	out_hit[side] = hit
	# Planted toes counter-rotate exactly by the roll: flat on the ground.
	out_toe[side] = -_peel[side]

func _swing_output(side: int, delta: float) -> void:
	# Airborne: locomotion swing or settle/recovery step.
	var rate: float = maxf(min_rate[side], .001)
	if state[side] == SWING and moving: rate = maxf(rate, phase_rate / maxf(1.0 - p0[side], .05))
	# Contact registers on a whole tick: predict to that tick, not to the
	# fractional remainder (else the landing jumps by up to v*dt at contact).
	var t_rem := (1.0 - t[side]) / rate
	if delta > 0.0: t_rem = ceilf(t_rem / delta - .001) * delta
	var hit: Dictionary
	var land: Vector3
	var frozen_body: Node3D = null
	if _frozen[side]:
		var ref: WeakRef = _frozen_support[side]
		var node: Object = ref.get_ref() if ref else null
		if node is Node3D and (node as Node3D).is_inside_tree(): frozen_body = node
	if _frozen[side] and (frozen_body or _frozen_support[side] == null):
		# Committed footfall: the last part of the swing descends onto a fixed
		# point (carried by its support) instead of chasing new predictions.
		land = frozen_body.to_global(_frozen_local[side]) if frozen_body else _frozen_local[side]
		hit = _ground(land)
		if hit.is_empty() or (frozen_body and hit.collider != frozen_body) or absf(hit.position.y - land.y) > .03:
			# Something new entered the committed column (a dropped part, a
			# moved deck): keep the committed point, plant only on what is
			# really there at contact.
			if not hit.is_empty() and absf(hit.position.y - land.y) > .03: hit = {}
		else: land = hit.position
	else:
		_landing_target(side, t_rem)
		hit = _ground(_lt_point)
		if not hit.is_empty():
			# Reachable footfall: on steep descents pull the landing toward the
			# predicted hip (with the crouch the body may still add) so the sole
			# is planted inside the leg's reach instead of hovering.
			var ankle: Vector3 = hit.position + Vector3.UP * float(pose._ankle_height[side])
			var reach: float = float(worker._leg_lengths[side]) - .03
			var offset := ankle - _lt_hip
			if offset.length() > reach and absf(offset.y) < reach:
				var horizontal := offset.slide(Vector3.UP).limit_length(sqrt(reach * reach - offset.y * offset.y))
				var closer: Dictionary = _ground(Vector3(_lt_hip.x + horizontal.x, hit.position.y, _lt_hip.z + horizontal.z))
				if not closer.is_empty(): hit = closer
		land = hit.position if not hit.is_empty() else Vector3(_lt_point.x, landing[side].y, _lt_point.z)
		landing_yaw[side] = _lt_heading
		if t[side] >= COMMIT_T and not hit.is_empty():
			_frozen[side] = true
			_frozen_support[side] = weakref(hit.collider) if hit.collider is Node3D else null
			_frozen_local[side] = (hit.collider as Node3D).to_local(land) if hit.collider is Node3D else land
	landing[side] = land
	landing_hit[side] = hit
	landing_normal[side] = hit.normal if not hit.is_empty() else Vector3.UP
	var from := _swing_start(side)
	if not _sampled_for[side].is_finite() or _sampled_for[side].distance_to(land) > .08: _sample_corridor(side, from, land)
	_update_pass(side, from, land)
	# A foot-held tool's clearance block may hold or nudge that sole after
	# this plan; continue from where the sole really is, not where it was asked.
	var actual: Vector3 = out_sole[side]
	if _is_tool_foot(side) and pose.evaluated_valid:
		var held: Vector3 = pose.evaluated_soles[side] - pose._held_shift
		actual = Vector3(held.x, out_sole[side].y, held.z)
	var previous: Vector3 = actual + worker.ground_velocity * delta
	var point := _swing_point(side, from, land, t[side], previous, delta)
	if delta > 0.0 and out_sole[side].is_finite() and _t_prev[side] >= 0.0:
		# Walking/jogging feet keep a calm 5.9 m/s ceiling (a foot-held tool
		# 5.4 m/s); running is only sanity-capped. Rather than letting the foot
		# trail its plan, the swing clock itself slows: the sole stays exactly
		# on its curve and simply lands a moment later.
		var cap := (SANITY_SPEED if speed > 2.4 else 5.9) * delta
		if _is_tool_foot(side):
			cap = minf(cap, maxf(5.4, speed * 2.4) * delta)
		if previous.distance_to(point) > cap and _is_tool_foot(side):
			# The retained tool keeps its original finite toe budget as a plain
			# per-tick limit (its clearance block re-solves around that sole).
			point = previous.move_toward(point, cap)
		elif previous.distance_to(point) > cap:
			var lo: float = _t_prev[side]
			var hi: float = t[side]
			for i in 8:
				var mid := (lo + hi) * .5
				if previous.distance_to(_swing_point(side, from, land, mid, previous, delta)) > cap: hi = mid
				else: lo = mid
			t[side] = lo
			point = _swing_point(side, from, land, lo, previous, delta)
			if previous.distance_to(point) > cap: point = previous.move_toward(point, cap)
	var s := glide(t[side])
	debug_planned[side] = _curve(side, from, land, t[side])
	_t_prev[side] = t[side]
	# Never let a planned sole sink into terrain met on the way (probed only
	# near the ground or over a corridor that rises above the straight line).
	var low: bool = point.y - maxf(from.y, land.y) < .05 or _clear_lift[side] > 0.0 or not _planar[side] or _is_tool_foot(side)
	var under: Dictionary = _ground(point) if low else {}
	var floor_clear := .012 * clampf(minf(t[side] / .12, (1.0 - t[side]) / .12), 0.0, 1.0)
	if not under.is_empty() and floor_clear > 0.0:
		var gap: float = under.normal.dot(point - under.position)
		if gap < floor_clear: point += under.normal * (floor_clear - gap)
	if delta > 0.0 and _t_prev[side] >= 0.0 and speed <= 2.4:
		var ceiling := 5.9 * delta
		if previous.distance_to(point) > ceiling: point = previous.move_toward(point, ceiling)
	var yaw := lerp_angle(start_yaw[side], landing_yaw[side], s)
	foot_yaw[side] = yaw
	var normal := start_normal[side].slerp(landing_normal[side], s).normalized() if start_normal[side].dot(landing_normal[side]) < .9999 else landing_normal[side]
	var tt := t[side]
	var kind_scale := (1.0 if state[side] == SWING else .4) * _roll_weight()
	if _is_tool_foot(side): kind_scale = 0.0
	# Heel-up angle: the lift-off roll continues into a toe-off plantar flex,
	# then the foot dorsiflexes to reach for the contact, flat at contact.
	var toe_off := .14 * sin(PI * clampf(tt / .4, 0.0, 1.0)) * (1.0 - smoothstep(.25, .5, tt))
	var reach_ahead := -.24 * smoothstep(.35, .78, tt) * (1.0 - smoothstep(.86, 1.0, tt))
	var heel_up := _peel0[side] * (1.0 - smoothstep(0.0, .45, tt)) + (toe_off + reach_ahead) * kind_scale
	out_sole[side] = point
	out_basis[side] = _foot_basis(side, yaw, heel_up, normal)
	out_planted[side] = false
	out_hit[side] = under if not under.is_empty() else hit
	# Toes: flat-on-ground extension at lift-off flicks into a curl, relaxes,
	# then lifts a little before contact.
	var flick := .32 * sin(PI * clampf(tt / .4, 0.0, 1.0))
	var pre := -.15 * smoothstep(.55, .8, tt) * (1.0 - smoothstep(.88, 1.0, tt))
	out_toe[side] = -_peel0[side] * (1.0 - smoothstep(0.0, .15, tt)) + (flick + pre) * kind_scale
	if tt >= 1.0:
		# Contact: plant exactly where the sole is, on its observed support
		# (normally the landing itself; a capped foot never slides to it).
		var contact: Vector3 = hit.position if not hit.is_empty() else point
		if point.distance_to(contact) > .004:
			var below: Dictionary = _ground(point)
			if not below.is_empty():
				hit = below
				contact = below.position
		var was_swing := state[side] == SWING
		if debug_log:
			var other_pt := _foot_now(1 - side)
			var rgt := Basis(Vector3.UP, worker._heading) * Vector3.RIGHT
			print("GAIT contact side=%d at=%s other=%s(state %d) sep=%.3f heading=%.2f land_yaw=%.2f frozen=%s" % [side, str(contact), str(other_pt), state[1 - side], (contact - other_pt).slide(Vector3.UP).dot(rgt) * (-1.0 if side == 0 else 1.0), worker._heading, landing_yaw[side], _frozen[side]])
		_contact_kind[side] = state[side]
		# The swing start (support-local) must survive a deferred contact.
		var start_keep := _swing_start(side)
		_plant(side, hit, contact, landing_yaw[side])
		start_world[side] = start_keep
		landing_count[side] += 1
		landing_strength[side] = clampf(speed / 3.4, .15, 1.0) if was_swing else .12
		out_sole[side] = contact
		out_basis[side] = _foot_basis(side, landing_yaw[side], 0.0, landing_normal[side])
		out_planted[side] = not hit.is_empty()
		out_hit[side] = hit
		out_toe[side] = 0.0
		debug_planned[side] = Vector3.INF
		if _contact_delay[side] == 0:
			# Weight arriving: the last step of a stop and each settle hop
			# squash the cube a little (secondary motion, not physics).
			if was_swing and not moving: _start_squash(lerpf(.012, .026, smoothstep(.6, 2.5, _recent_speed)), .14)
			elif not was_swing and not moving: _start_squash(.014, .12)
			elif was_swing and _reversing() > .5: _start_squash(.018, .12)
		if moving and not hold:
			# A recovery/settle landing re-enters the cadence at its own contact.
			var p := _local_phase(side)
			if not was_swing or (p > .2 and p < .8):
				if state[1 - side] == PLANTED: phase = fposmod(-.5 * side, 1.0)
			armed[side] = _local_phase(side) < duty

# ------------------------------------------------------------------ air
func air(delta: float) -> bool:
	# Locomotion ran off an edge: instead of snapping to an authored clip the
	# legs keep their own pose in the air, tuck under the cube, then reach for
	# the coming ground (soft knees, flat feet) so the landing continues from
	# exactly what was shown. Only continues a gait that owned the legs.
	if not active and not airborne: return false
	if delta <= 0.0: return airborne
	if not airborne:
		airborne = true
		for side in 2:
			_air_rel[side] = out_sole[side] - worker.global_position
			_hand_off[side] = Vector3.ZERO
			_hand_rot[side] = out_basis[side].get_rotation_quaternion()
	release(delta)
	_refresh_query()
	_air_fresh = true
	var heading: float = worker._heading
	var forward := facing(heading)
	var v: Vector3 = worker.linear_velocity
	_air_vy = v.y
	# Time until the capsule meets the ground ahead/below decides tuck vs reach.
	var probe: Vector3 = worker.global_position + v.slide(Vector3.UP) * .12
	_air_query.from = probe + Vector3.UP * .2
	_air_query.to = probe - Vector3.UP * 4.0
	_air_query.exclude = _query.exclude
	_air_query.collision_mask = 1
	var hit := _space.intersect_ray(_air_query)
	var height: float = worker.global_position.y - hit.position.y if not hit.is_empty() else 4.0
	# The gait takes the legs back when the capsule's support ray (ride
	# height + .42) finds ground, so the legs must be reaching by then.
	var impact := maxf(height - float(worker.ride_height) - .38, 0.0) / maxf(-v.y, .6)
	var reach := 1.0 - smoothstep(.05, .22, impact)
	var travel := clampf(v.slide(Vector3.UP).dot(forward) * .045, -.05, .14)
	for side in 2:
		var lateral := _lateral(side, heading, HIP_X * .92)
		var tuck := Vector3(0.0, -float(worker.ride_height) + .26, 0.0) + forward * .05
		var land := Vector3(0.0, -float(worker.ride_height) + .03, 0.0) + forward * travel
		var target := lateral + tuck.lerp(land, reach)
		if not hit.is_empty():
			# Never reach through the ground the cube is about to land on.
			target.y = maxf(target.y, hit.position.y + .01 - worker.global_position.y)
		_air_rel[side] = _air_rel[side].move_toward(target, 3.2 * delta)
		out_sole[side] = worker.global_position + _air_rel[side]
		# Toes hang a little while tucked; the sole flattens to land.
		var planned := _foot_basis(side, heading, lerpf(.25, 0.0, reach), Vector3.UP)
		if out_basis[side].is_finite():
			# The first air ticks turn from the last shown foot (a slerp from the
			# remembered world rotation), never a one-tick snap.
			var from: Quaternion = _hand_rot[side]
			var to := planned.get_rotation_quaternion()
			var angle := from.angle_to(to)
			var next := from.slerp(to, minf(1.0, 9.0 * delta / maxf(angle, .0001))) if angle > .0001 else to
			_hand_rot[side] = next
			out_basis[side] = Basis(next)
		else: out_basis[side] = planned
		out_planted[side] = false
		out_hit[side] = {}
		out_toe[side] = lerpf(.18, -.06, reach)
		requested[side] = out_sole[side]
	return true

# ------------------------------------------------------------------ body
func _start_squash(amount: float, length: float) -> void:
	if _squash_t < _squash_len and _squash_amp > amount: return
	_squash_amp = amount
	_squash_len = length
	_squash_t = 0.0

func _update_squash(delta: float) -> void:
	# Impact profile: compresses fast (~30% of the length), recovers slower.
	_squash_t += delta
	var s := clampf(_squash_t / maxf(_squash_len, .01), 0.0, 1.0)
	squash = -_squash_amp * sin(PI * pow(s, .6)) if s < 1.0 else 0.0

func _reversing() -> float:
	# 0..1: requested travel points back against the current motion.
	var desired: Vector3 = worker.locomotion_desired.slide(up)
	if speed < .6 or desired.length() < .3: return 0.0
	return smoothstep(-.2, -.8, (velocity / speed).dot(desired.normalized()))

func _publish_totals() -> void:
	body_shift = _shift_s + _shift_osc
	body_roll = clampf(_roll_s + _roll_osc, -.12, .12)
	body_yaw = _yaw_s + body_twist

func _update_body(delta: float) -> void:
	var swinging := state[0] == SWING or state[1] == SWING
	var target_weight := 1.0 if (moving or swinging or speed > .3) else 0.0
	var w := spring(locomotion_weight, _lw_v, target_weight, 9.0, delta)
	locomotion_weight = clampf(w.x, 0.0, 1.0)
	_lw_v = w.y
	# Acting clock: the gait phase, with re-phase jumps (launch, early
	# release, recovery contact) absorbed over ~70 ms instead of popping.
	_act_phase = fposmod(_act_phase + phase_rate * delta, 1.0)
	_act_phase = fposmod(_act_phase + wrapf(phase - _act_phase, -.5, .5) * minf(1.0, 14.0 * delta), 1.0)
	var v := speed
	var load := clampf(float(worker.cargo_mass) / maxf(float(worker.carry_capacity), 1.0), 0.0, 1.0)
	var steady := lerpf(1.0, .4, load) * (.65 if is_instance_valid(worker.carry_partner) else 1.0)
	var tool := _tool_mode()
	# A foot-held mallet points forward-up from the toe: an upright, taller,
	# quieter cube keeps the whole tool clear of the body while it travels.
	var calm := (.4 if carry else 1.0) * steady * (.35 if tool else 1.0)
	var gait_on := smoothstep(.15, .9, v)
	# Launch anticipation: weight onto the support foot, a small gather and
	# a lean into the start, then it hands over to the phase-locked sway.
	var launch := 0.0
	if _launch_t >= 0.0:
		_launch_t += delta
		launch = smoothstep(0.0, LAUNCH_HOLD, _launch_t) * (1.0 - smoothstep(.16, .34, _launch_t))
		if _launch_t > .34: _launch_t = -1.0
	var support_sign := -1.0 if _launch_side == 1 else 1.0   # toward the support (non-lead) foot
	var reverse := _reversing()
	# Sprung crouch: speed dip, launch gather, a pivot crouch when reversing.
	var y_target := _dip(v) * (.35 if tool else steady) - .018 * launch - .025 * reverse * calm
	var y := spring(body_y, _by_v, y_target, 30.0, delta)
	body_y = y.x
	_by_v = y.y
	# Phase-locked stance bob and nod, added AFTER the springs (a spring at
	# step frequency lags ~90 degrees): walk lowest at double support, run
	# lowest at mid-stance and highest at mid-flight; nose down when low.
	var low := duty - .5 * (1.0 - run_weight)
	var x := fposmod(2.0 * _act_phase - low, 1.0)
	# A run rises a touch faster than it falls (peak ~4 ms before
	# mid-flight): the stance knee re-extends into the push-off while the
	# landing leg still arrives bent. A steeper rise would snap the knee
	# straight in the last stance ticks.
	var peak := lerpf(.5, .475, run_weight)
	var wave := cos(PI * x / peak) if x < peak else -cos(PI * (x - peak) / (1.0 - peak))
	body_bob = -lerpf(.023 * gait_on, .034, run_weight) * calm * wave
	body_nod = lerpf(.026 * gait_on, .035, run_weight) * calm * wave
	_update_squash(delta)
	# Forward lean from speed and paid acceleration: one owner, continuous,
	# underdamped. Braking leans back; when the skid ends the cube pitches
	# past upright, nose-down, and settles (follow-through).
	var forward := facing(worker._heading)
	var a_fwd := clampf(accel.dot(forward), -14.0, 14.0)
	var lean_target := clampf(.045 * velocity.dot(forward) + .016 * a_fwd, -.16, .26) * (.5 if carry else (.15 if tool else 1.0)) * steady
	if flee: lean_target *= 1.25
	lean_target += .07 * launch * calm
	if a_fwd < -4.0 and v > .8: _brake_time = .6
	else: _brake_time = maxf(_brake_time - delta, 0.0)
	if _brake_time > 0.0 and v < .35 and a_fwd > -2.5:
		_lean_v += .95 * (.5 if carry else (.2 if tool else 1.0)) * steady
		_brake_time = 0.0
	var zeta := .45
	var omega := 11.5
	_lean_v += (omega * omega * (lean_target - body_lean) - 2.0 * zeta * omega * _lean_v) * delta
	body_lean += _lean_v * delta
	# Sway over the stance foot, waddle roll toward it and a hip twist that
	# leads with the swinging leg: all phase-locked (never sprung), largest
	# walking, smaller and quicker running, quiet when loaded.
	var sway := gait_on * steady * (.45 if carry else 1.0) * (.4 if tool else 1.0)
	var sway_wave := cos(TAU * (_act_phase - duty * .5))
	_shift_osc = -lerpf(.037, .02, run_weight) * sway * sway_wave
	_roll_osc = lerpf(.06, .035, run_weight) * sway * sway_wave
	body_twist = lerpf(.06, .045, run_weight) * sway * sway_wave
	var s := spring(_shift_s, _shift_v, .03 * support_sign * launch, 26.0, delta)
	_shift_s = s.x
	_shift_v = s.y
	# Bank into turns and roll onto the launch support foot.
	var bank := .5 * atan(v * clampf(worker.turn_rate, -6.0, 6.0) / 9.8)
	var roll_target := clampf(bank, -.095, .095) * steady - .05 * support_sign * launch
	var r := spring(_roll_s, _roll_v, roll_target, 16.0, delta)
	_roll_s = r.x
	_roll_v = r.y
	# The cube's eyes lead a turn toward the requested heading (<= 8 deg).
	var yaw_target := clampf(wrapf(worker._idle_heading - worker._heading, -PI, PI) * .35, -.14, .14) * (.5 if carry else 1.0)
	var yw := spring(_yaw_s, _yaw_v, yaw_target, 12.0, delta)
	_yaw_s = yw.x
	_yaw_v = yw.y
	_publish_totals()
	# Settle steps hop: a quick gather at push-off, a small rise in the air.
	var hop := 0.0
	for side in 2:
		if state[side] == SETTLE:
			var tt := t[side]
			hop = minf(hop, -.022 * sin(PI * clampf(tt / .35, 0.0, 1.0)) + .012 * sin(PI * clampf((tt - .3) / .7, 0.0, 1.0)))
	settle_dip = move_toward(settle_dip, hop, .9 * delta)

func acting_root(sk: Skeleton3D, authored: Transform3D) -> Transform3D:
	# Procedural locomotion root, blended in by locomotion_weight. Authored
	# locomotion clips only contribute while the creature is standing still
	# (so this layer is independent of the clips' own leg/root conventions).
	var rest := sk.get_bone_rest(0)
	var w := locomotion_weight
	var procedural := Transform3D(rest.basis, Vector3(0.0, -.029, 0.0))
	var root := authored.interpolate_with(procedural, w) if w > .0005 else authored
	# Skeleton-space offsets: -Z is the face, -X the character's left hip;
	# +X rotation tilts the top backward, +Z rotation tilts it left.
	root.origin += Vector3(body_shift * w, (body_y + body_bob) * w + settle_dip + squash - body_drop, 0.0)
	var tilt := Basis(Vector3.UP, body_yaw * w) * Basis(Vector3.RIGHT, -(body_lean + body_nod) * w) * Basis(Vector3.BACK, body_roll * w)
	root.basis = (tilt * root.basis).orthonormalized()
	return root

func update_drop(sk: Skeleton3D, root: Transform3D, delta: float) -> void:
	# Lower the visual hip just enough for planted/landing soles to stay in
	# reach (down-steps, slopes) so feet never hover above lower ground.
	var need := 0.0
	var rest_inv := sk.get_bone_rest(0).affine_inverse()
	for side in 2:
		# Landings are judged from .35 on, so the crouch eases in ahead of the
		# contact rather than being yanked in on its last ticks.
		if state[side] != PLANTED and t[side] < .35: continue
		# A stance about to lift off is released by the planner, not chased.
		if state[side] == PLANTED and moving and _local_phase(side) > .7 * duty: continue
		var target: Vector3 = out_sole[side] - _roll_off[side] if state[side] == PLANTED else landing[side]
		var ankle: Vector3 = target + Vector3.UP * float(pose._ankle_height[side])
		var hip_rest: Vector3 = sk.get_bone_global_rest(pose._chains[side][0]).origin
		var hip: Vector3 = sk.global_transform * (root * (rest_inv * hip_rest))
		hip.y += body_drop
		if state[side] != PLANTED:
			# Judge a landing from where the hip will be at contact, not from
			# here: the run's footfall is ~.4 m ahead now but only ~.2 m then.
			var rate: float = maxf(min_rate[side], .001)
			if state[side] == SWING and moving: rate = maxf(rate, phase_rate / maxf(1.0 - p0[side], .05))
			hip += velocity.slide(Vector3.UP) * ((1.0 - t[side]) / rate)
		var reach: float = float(worker._leg_lengths[side]) - .022
		var horizontal := (hip - ankle).slide(Vector3.UP).length()
		if horizontal >= reach: continue
		var vertical := hip.y - ankle.y
		need = maxf(need, vertical - sqrt(reach * reach - horizontal * horizontal))
	need = clampf(need, 0.0, .2)
	var d := spring(body_drop, _drop_v, need, 24.0 if need > body_drop else 9.0, delta)
	# Speed-capped: a crest or an edge eases the crouch in (no root hiccup).
	_drop_v = clampf(d.y, -DROP_SPEED, DROP_SPEED)
	body_drop = maxf(body_drop + _drop_v * delta, 0.0) if absf(d.y) > DROP_SPEED else maxf(d.x, 0.0)

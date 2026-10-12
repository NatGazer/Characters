extends RefCounted
## Ordinary-locomotion gait planner for Wako, owned by wako_pose.gd.
## The clock is distance-locked: phase advances by ground-relative travel, so
## a planted sole never treadmills and cadence, stride and duty adapt to speed
## (double-support walk -> light run with a flight phase). Each foot is a small
## state machine: PLANTED soles keep position AND yaw in their support's local
## frame; SWING feet glide (sin^2-ramped, constant-speed middle) to a landing
## predicted from the helper's own force law, over a look-ahead clearance arc;
## SETTLE steps are short time-driven steps that tidy the stance after a stop,
## recover a released plant, and turn in place.
## Pure planning: no physics writes. wako_pose.gd solves and publishes legs,
## then hands back the requested soles so overrides by other owners are seen.
const PLANTED := 0
const SWING := 1
const SETTLE := 2
const HIP_X := .237
const T_SWING_MAX := .34        # slowest locomotion swing; slower walks keep longer double support
const T_FIRST_SWING := .24      # the launch step is brisk even while the body is still slow
const T_STOP := .2              # an airborne foot at a stop lands within this
const T_RECOVER := .2
const SETTLE_DISTANCE := .07
const SETTLE_YAW := .44         # 25 degrees
const SANITY_SPEED := 16.0      # m/s; only a NaN/teleport guard, swings may legitimately peak ~11 m/s
const MAX_STANCE := .52         # stance distance must fit the run-crouch reach
const STOP_HORIZON := .45
const COMMIT_T := .8            # swing progress after which the footfall is fixed
const CORRIDOR: Array[float] = [.15, .45, .75]   # look-ahead ground samples along the swing
const TOOL_STANCE_LEAD := .08   # a foot-held mallet's stance stays in front of the hip
const HIP_ABOVE_BODY := .035    # rest hip above the capsule origin: -.85 + 1.0739 - .029 - .16
const REACH_DROP := .06         # extra crouch the visual root may still add to reach lower ground

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
var stance_age: Array[float] = [0.0, 0.0]
var landing_count: Array[int] = [0, 0]          # helper plays a footstep per new landing
var landing_strength: Array[float] = [0.0, 0.0]
var requested: Array[Vector3] = [Vector3.INF, Vector3.INF]
var debug_planned: Array[Vector3] = [Vector3.INF, Vector3.INF]

# --- per-tick outputs (world space) ---
var out_sole: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var out_basis: Array[Basis] = [Basis.IDENTITY, Basis.IDENTITY]
var out_planted: Array[bool] = [true, true]
var out_hit: Array = [{}, {}]
var out_toe: Array[float] = [0.0, 0.0]

# --- body acting (skeleton-space offsets for the root bone) ---
var locomotion_weight := 0.0
var _lw_v := 0.0
var body_y := 0.0
var _by_v := 0.0
var body_lean := 0.0
var _lean_v := 0.0
var body_roll := 0.0
var _roll_v := 0.0
var body_shift := 0.0
var _shift_v := 0.0
var body_yaw := 0.0
var _yaw_v := 0.0
var body_drop := 0.0
var _drop_v := 0.0
var settle_dip := 0.0
var body_nod := 0.0
var _rest_foot: Array[Basis] = []
var _query := PhysicsRayQueryParameters3D.new()
var _query_key := -1
var _query_age := 0
var _plant_hit: Array = [{}, {}]                # cached plant observation (static supports)
var _plant_hit_age: Array[int] = [0, 0]
var _space: PhysicsDirectSpaceState3D
var _toe_axis: Array[Vector3] = []

func setup(owner_pose: SkeletonModifier3D, sk: Skeleton3D) -> void:
	pose = owner_pose
	worker = owner_pose.worker
	_rest_foot.clear()
	_toe_axis.clear()
	for side in 2:
		var ankle: int = pose._chains[side][2]
		_rest_foot.append(sk.get_bone_global_rest(ankle).basis)
		# Toe curl axis in the ankle's local frame: rotates the rest toe
		# direction toward the sole. Derived, so a re-authored toe works too.
		var toe: int = pose._toes[side]
		var toe_dir := Vector3.BACK
		if toe >= 0:
			var rest_toe := sk.get_bone_rest(toe)
			toe_dir = (rest_toe.basis.y).normalized()
		var axis := toe_dir.cross(Vector3.UP).normalized()  # ankle local +Y points to the sole
		_toe_axis.append(axis if axis.length_squared() > .5 else Vector3.RIGHT)

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

static func bump(x: float) -> float:
	# Early peak (~42%): brisk toe-off, longer reach down to contact.
	x = clampf(x, 0.0, 1.0)
	return pow(sin(PI * pow(x, .8)), 1.5)

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
	var l := clampf(.16 + .155 * v, .16, .72)
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

func stance_distance(v: float, side: int) -> float:
	var d := _duty(v)
	return minf(2.0 * _stride(v) * (1.0 - _swing_span(v, d)), MAX_STANCE)

func _predict(tau: float, desired: Vector3) -> Array:
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
	return [x, v]

func _heading_at(tau: float) -> float:
	var error := wrapf(worker._idle_heading - worker._heading, -PI, PI)
	return worker._heading + clampf(worker.turn_rate * tau, -absf(error), absf(error))

func _lead_heading() -> float:
	return worker._heading + clampf(wrapf(worker._idle_heading - worker._heading, -PI, PI), -.55, .55)

func _track(side: int) -> float:
	var w := HIP_X * lerpf(1.0, .84, run_weight)
	return w * 1.08 if carry else w

func _foot_basis(side: int, yaw: float, pitch: float, normal: Vector3) -> Basis:
	var b := Basis(Vector3.UP, yaw) * _rest_foot[side]
	if absf(pitch) > .0001: b = Basis(Basis(Vector3.UP, yaw) * Vector3.RIGHT, pitch) * b
	var n := normal.normalized()
	if n.dot(Vector3.UP) < .9999: b = Basis(Quaternion(Vector3.UP, n)) * b
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

func validate_landing(side: int, hip: Vector3, delta: float) -> void:
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

func _lift_off(side: int, kind: int, rate_floor: float, base_lift: float) -> void:
	var from := out_sole[side] if state[side] != PLANTED else _planted_point(side)
	start_world[side] = from
	var body := _support_alive(side) if state[side] == PLANTED else null
	if body:
		local_point[side] = body.to_local(from)
	else:
		support[side] = null
	start_yaw[side] = _planted_yaw(side) if state[side] == PLANTED else foot_yaw[side]
	start_normal[side] = pose._sole_normals[side] if pose._sole_normals[side].is_finite() else Vector3.UP
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
	var yaw: float = worker._heading
	if valid:
		sole = pose.evaluated_soles[side]
		var forward: Vector3 = (pose.evaluated_ankles[side] * _rest_foot[side].inverse() * Vector3.FORWARD).slide(Vector3.UP)
		if forward.length_squared() > .01: yaw = yaw_of(forward)
	else:
		var foot := sk.get_bone_global_pose(pose._chains[side][2])
		sole = sk.global_transform * (foot * Vector3(0, pose._ankle_height[side], 0))
	var hit: Dictionary = _ground(sole)
	out_sole[side] = sole
	requested[side] = Vector3.INF
	foot_yaw[side] = yaw
	var grounded: bool = not hit.is_empty() and absf(hit.normal.dot(sole - hit.position)) < .02
	if valid: grounded = grounded and pose.evaluated_grounded[side] and pose._target_valid[side]
	if grounded or not valid:
		_plant(side, hit, hit.position if not hit.is_empty() else sole, yaw)
		armed[side] = true
	else:
		state[side] = PLANTED  # so _lift_off reads the published point below
		support[side] = null
		local_point[side] = sole
		_lift_off(side, SETTLE, 1.0 / T_RECOVER, .04)
		start_world[side] = sole
		support[side] = null

func reset() -> void:
	active = false

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
	active = true
	_update_clock(delta)
	for side in 2: debug_planned[side] = Vector3.INF
	_events(sk, delta)
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
	if moving and not was_moving: _start_step()

func _start_step() -> void:
	# Launch: the foot farther behind the requested motion steps at once.
	if state[0] != PLANTED or state[1] != PLANTED: return
	var desired: Vector3 = worker.locomotion_desired
	var direction := desired.slide(up)
	if direction.length_squared() < .01: direction = velocity
	if direction.length_squared() < .01: direction = facing(worker._heading)
	direction = direction.normalized()
	var body: Vector3 = worker.global_position
	var behind0 := -(_planted_point(0) - body).dot(direction)
	var behind1 := -(_planted_point(1) - body).dot(direction)
	var lead := 0 if behind0 > behind1 else 1
	if absf(behind0 - behind1) < .03:
		# Tie: the outside foot of the coming turn opens the step.
		var error := wrapf(yaw_of(direction) - worker._heading, -PI, PI)
		lead = 1 if error > 0.0 else 0
	var d := duty
	phase = fposmod(d - .5 * lead, 1.0)
	armed[lead] = true
	armed[1 - lead] = _local_phase(1 - lead) < duty

func _events(sk: Skeleton3D, delta: float) -> void:
	var stopping := not moving
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
				var tool_foot: bool = worker.tool_foot_occupied() and side == worker.tool_foot_side()
				var may_fly: bool = duty < .49 and not tool_foot and not worker.tool_foot_occupied()
				if not other_planted and not may_fly and not _overreached(side, sk): continue
				if not other_planted and tool_foot: continue
				if armed[side] and p >= d:
					var first := moving_age < .05
					_lift_off(side, SWING, 1.0 / (T_FIRST_SWING if first else T_SWING_MAX), _base_lift(side))
				elif _overreached(side, sk):
					# Never drag a plant past reach: release it now and re-phase so
					# the alternation continues from this very step.
					if other_planted:
						phase = fposmod(d - .5 * side, 1.0)
					_lift_off(side, SWING, 1.0 / T_RECOVER, _base_lift(side))
			SWING, SETTLE:
				var rate := min_rate[side]
				if state[side] == SWING and not stopping:
					rate = maxf(rate, phase_rate / maxf(1.0 - p0[side], .05))
				if stopping and state[side] == SWING:
					rate = maxf(rate, (1.0 - t[side]) / T_STOP)
					min_rate[side] = rate
				t[side] = minf(t[side] + rate * delta, 1.0)
	# Stand-still settling (also stepping turns). One foot at a time.
	quiet = false
	if not moving and settle_allowed and state[0] == PLANTED and state[1] == PLANTED and speed < .25:
		var worst := -1
		var worst_score := 0.0
		var lead := _lead_heading()
		for side in 2:
			var neutral := worker.global_position + _lateral(side, lead, HIP_X)
			var offset := (_planted_point(side) - neutral).slide(Vector3.UP).length()
			var yaw_error := absf(wrapf(_planted_yaw(side) - lead, -PI, PI))
			var score := maxf(offset / SETTLE_DISTANCE, yaw_error / SETTLE_YAW)
			if score > 1.0 and score > worst_score and stance_age[side] > .05:
				worst = side
				worst_score = score
		if worst >= 0:
			var neutral := worker.global_position + _lateral(worst, lead, HIP_X)
			var distance := (_planted_point(worst) - neutral).slide(Vector3.UP).length()
			var duration := clampf(.17 + .3 * distance, .18, .28)
			_lift_off(worst, SETTLE, 1.0 / duration, clampf(.025 + .12 * distance, .03, .06))
		else: quiet = true

func _dip(v: float) -> float:
	return -.022 * smoothstep(.1, 1.0, v) - .02 * smoothstep(1.2, 3.2, v)

func _roll_weight() -> float:
	return smoothstep(.3, 1.2, speed)

func _base_lift(side: int) -> float:
	if worker.tool_foot_occupied() and side == worker.tool_foot_side(): return .075
	var l := lerpf(.07, .16, smoothstep(1.2, 3.2, speed))
	return l * .6 if carry else l

func _overreached(side: int, sk: Skeleton3D) -> bool:
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
	return -(sole - hip).dot(direction) > stance_distance(speed, side) * .5 + .12

func _landing_target(side: int, t_rem: float) -> Array:
	# Returns [point(world, unprojected), heading at landing].
	if moving and not hold:
		var desired: Vector3 = worker.locomotion_desired
		var predicted := _predict(t_rem, desired)
		var v_land: Vector3 = predicted[1]
		var heading := _heading_at(t_rem)
		var point: Vector3 = worker.global_position + predicted[0] + worker.ground_velocity * t_rem + _lateral(side, heading, _track(side))
		var vl := v_land.length()
		var direction := v_land / vl if vl > .2 else facing(heading)
		var hip := point + Vector3.UP * (HIP_ABOVE_BODY + _dip(vl) - body_drop - REACH_DROP)
		point += direction * (stance_distance(vl, side) * .5 + (TOOL_STANCE_LEAD if _is_tool_foot(side) else 0.0))
		return [point, heading, hip]
	# Stopping or settling: land where the hip will come to rest, facing the
	# requested heading (with a bounded lead so turning in place can continue).
	var rest := _predict(STOP_HORIZON, Vector3.ZERO)
	var heading := _lead_heading()
	var point: Vector3 = worker.global_position + rest[0] + worker.ground_velocity * t_rem + _lateral(side, heading, HIP_X)
	return [point, heading, point + Vector3.UP * (HIP_ABOVE_BODY - body_drop - REACH_DROP)]

func _sample_corridor(side: int, from: Vector3, to: Vector3) -> void:
	# Look-ahead: ground at 1/3 and 2/3 of the horizontal corridor (cached
	# per landing). A slope keeps its straight line; an edge chooses the
	# early-rise / late-descent profile; the apex then clears every sample
	# by 6 cm above the path the foot will actually take.
	_sampled_for[side] = to
	var heights: Array[float] = []
	var planar := true
	for k: float in CORRIDOR:
		var hit: Dictionary = _ground(from.lerp(to, k) + Vector3.UP * .3)
		var h: float = hit.position.y if not hit.is_empty() else lerpf(from.y, to.y, k)
		heights.append(h)
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
		if protrusion > .01: need = maxf(need, (protrusion + .05) / maxf(bump(t_k), .25))
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
	point.y += maxf(lift[side], _clear_lift[side]) * bump(tt)
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

func _foot_output(side: int, delta: float) -> void:
	if state[side] == PLANTED:
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
			_foot_output(side, 0.0)
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
		# Subtle heel-to-toe roll: the heel peels late in a moving stance.
		var u := clampf(_local_phase(side) / maxf(duty, .05), 0.0, 1.0) if moving else 0.0
		var peel := -.10 * smoothstep(.62, 1.0, u) * _roll_weight()
		out_sole[side] = point
		out_basis[side] = _foot_basis(side, yaw, peel, hit.normal)
		out_planted[side] = true
		out_hit[side] = hit
		out_toe[side] = .35 * smoothstep(.55, 1.0, u) * _roll_weight()
		return
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
		var target := _landing_target(side, t_rem)
		hit = _ground(target[0])
		if not hit.is_empty():
			# Reachable footfall: on steep descents pull the landing toward the
			# predicted hip (with the crouch the body may still add) so the sole
			# is planted inside the leg's reach instead of hovering.
			var hip: Vector3 = target[2]
			var ankle: Vector3 = hit.position + Vector3.UP * float(pose._ankle_height[side])
			var reach: float = float(worker._leg_lengths[side]) - .03
			var offset := ankle - hip
			if offset.length() > reach and absf(offset.y) < reach:
				var horizontal := offset.slide(Vector3.UP).limit_length(sqrt(reach * reach - offset.y * offset.y))
				var closer: Dictionary = _ground(Vector3(hip.x + horizontal.x, hit.position.y, hip.z + horizontal.z))
				if not closer.is_empty(): hit = closer
		land = hit.position if not hit.is_empty() else Vector3(target[0].x, landing[side].y, target[0].z)
		landing_yaw[side] = target[1]
		if t[side] >= COMMIT_T and not hit.is_empty():
			_frozen[side] = true
			_frozen_support[side] = weakref(hit.collider) if hit.collider is Node3D else null
			_frozen_local[side] = (hit.collider as Node3D).to_local(land) if hit.collider is Node3D else land
	landing[side] = land
	landing_hit[side] = hit
	landing_normal[side] = hit.normal if not hit.is_empty() else Vector3.UP
	var from := _swing_start(side)
	if not _sampled_for[side].is_finite() or _sampled_for[side].distance_to(land) > .08: _sample_corridor(side, from, land)
	# A foot-held tool's clearance block may hold or nudge that sole after
	# this plan; continue from where the sole really is, not where it was asked.
	var actual: Vector3 = out_sole[side]
	if worker.tool_foot_occupied() and side == worker.tool_foot_side() and pose.evaluated_valid:
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
	if worker.tool_foot_occupied() and side == worker.tool_foot_side(): kind_scale = 0.0
	# Toe-off plantar flexion (continuing the stance heel peel) -> dorsiflexed
	# reach before contact -> flat at contact.
	var plantar := -(.10 + .14 * sin(PI * clampf(tt / .4, 0.0, 1.0))) * (1.0 - smoothstep(.25, .5, tt))
	var dorsi := .24 * smoothstep(.35, .78, tt) * (1.0 - smoothstep(.86, 1.0, tt))
	var pitch := (plantar + dorsi) * kind_scale
	out_sole[side] = point
	out_basis[side] = _foot_basis(side, yaw, pitch, normal)
	out_planted[side] = false
	out_hit[side] = under if not under.is_empty() else hit
	out_toe[side] = (.35 * (1.0 - smoothstep(0.0, .3, tt)) - .25 * smoothstep(.25, .55, tt) * (1.0 - smoothstep(.7, .95, tt))) * kind_scale
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
		if moving and not hold:
			# A recovery/settle landing re-enters the cadence at its own contact.
			var p := _local_phase(side)
			if not was_swing or (p > .2 and p < .8):
				if state[1 - side] == PLANTED: phase = fposmod(-.5 * side, 1.0)
			armed[side] = _local_phase(side) < duty

# ------------------------------------------------------------------ body
func _update_body(delta: float) -> void:
	var swinging := state[0] == SWING or state[1] == SWING
	var target_weight := 1.0 if (moving or swinging or speed > .3) else 0.0
	var w := spring(locomotion_weight, _lw_v, target_weight, 9.0, delta)
	locomotion_weight = clampf(w.x, 0.0, 1.0)
	_lw_v = w.y
	var v := speed
	var load := clampf(float(worker.cargo_mass) / maxf(float(worker.carry_capacity), 1.0), 0.0, 1.0)
	var steady := lerpf(1.0, .4, load) * (.65 if is_instance_valid(worker.carry_partner) else 1.0)
	# Height: crouch with speed so knees visibly bend, plus the stance bob.
	var dip := _dip(v)
	var step_phase := fposmod(2.0 * phase, 1.0)
	var low := duty - .5 * (1.0 - run_weight)
	var amplitude := lerpf(.012 * smoothstep(.2, 1.0, v), .042, run_weight) * (.4 if carry else 1.0)
	var bob := -amplitude * cos(TAU * (step_phase - low))
	# The cube nods into each running footfall (absorb) and lifts its face in
	# flight: secondary motion that sells weight, kept small and phase-locked.
	body_nod = .035 * run_weight * cos(TAU * (step_phase - low)) * (.4 if carry else 1.0)
	# Launch: a quick gather on the first step reads as anticipation.
	var gather := -.03 * sin(PI * clampf(moving_age / .16, 0.0, 1.0)) if moving and moving_age < .16 else 0.0
	var y_target := (dip + bob) * steady + gather
	# A foot-held mallet points forward-up from the toe: an upright, taller
	# cube keeps the whole tool clear of the body while it travels.
	var tool := _tool_mode()
	if tool: y_target *= .35
	var y := spring(body_y, _by_v, y_target, 34.0, delta)
	body_y = y.x
	_by_v = y.y
	# Forward lean from speed and paid acceleration: one owner, continuous,
	# underdamped so a stop pitches slightly forward, then settles.
	var forward := facing(worker._heading)
	var a_fwd := clampf(accel.dot(forward), -14.0, 14.0)
	var lean_target := clampf(.045 * velocity.dot(forward) + .016 * a_fwd, -.16, .26) * (.5 if carry else (.15 if tool else 1.0)) * steady
	if flee: lean_target *= 1.25
	var zeta := .55
	var omega := 13.0
	_lean_v += (omega * omega * (lean_target - body_lean) - 2.0 * zeta * omega * _lean_v) * delta
	body_lean += _lean_v * delta
	# Weight shift over the stance foot (walk) and bank into turns.
	var stance_mid := duty * .5
	var shift_target := -.021 * lerpf(1.0, .45, run_weight) * smoothstep(.15, .8, v) * cos(TAU * (phase - stance_mid)) * (.45 if carry else 1.0) * steady
	var s := spring(body_shift, _shift_v, shift_target, 26.0, delta)
	body_shift = s.x
	_shift_v = s.y
	var bank := .5 * atan(v * clampf(worker.turn_rate, -6.0, 6.0) / 9.8)
	var roll_target := clampf(bank - body_shift * .9, -.095, .095) * steady
	var r := spring(body_roll, _roll_v, roll_target, 16.0, delta)
	body_roll = clampf(r.x, -.095, .095)
	_roll_v = r.y
	# The cube's eyes lead a turn toward the requested heading (<= 8 deg).
	var yaw_target := clampf(wrapf(worker._idle_heading - worker._heading, -PI, PI) * .35, -.14, .14) * (.5 if carry else 1.0)
	var yw := spring(body_yaw, _yaw_v, yaw_target, 12.0, delta)
	body_yaw = yw.x
	_yaw_v = yw.y
	settle_dip = 0.0
	for side in 2:
		if state[side] == SETTLE: settle_dip = minf(settle_dip, -.014 * sin(PI * t[side]))

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
	var drop := body_drop
	root.origin += Vector3(body_shift * w, (body_y * w) + settle_dip - drop, 0.0)
	var tilt := Basis(Vector3.UP, body_yaw * w) * Basis(Vector3.RIGHT, -(body_lean + body_nod) * w) * Basis(Vector3.BACK, body_roll * w)
	root.basis = (tilt * root.basis).orthonormalized()
	return root

func update_drop(sk: Skeleton3D, root: Transform3D, delta: float) -> void:
	# Lower the visual hip just enough for planted/landing soles to stay in
	# reach (down-steps, slopes) so feet never hover above lower ground.
	var need := 0.0
	var rest_inv := sk.get_bone_rest(0).affine_inverse()
	for side in 2:
		if state[side] != PLANTED and t[side] < .55: continue
		# A stance about to lift off is released by the planner, not chased.
		if state[side] == PLANTED and moving and _local_phase(side) > .7 * duty: continue
		var target: Vector3 = out_sole[side] if state[side] == PLANTED else landing[side]
		var ankle: Vector3 = target + Vector3.UP * float(pose._ankle_height[side])
		var hip_rest: Vector3 = sk.get_bone_global_rest(pose._chains[side][0]).origin
		var hip: Vector3 = sk.global_transform * (root * (rest_inv * hip_rest))
		hip.y += body_drop
		if state[side] != PLANTED:
			# Judge a landing from where the hip will be at contact, not from
			# here: the run's footfall is ~.4 m ahead now but only ~.27 m then,
			# so a current-hip test held the whole run ~6 cm too low.
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
	body_drop = maxf(d.x, 0.0)
	_drop_v = d.y

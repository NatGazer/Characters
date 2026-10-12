extends Node
## Quantitative gait acceptance probe. Reads only the published pose caches
## (evaluated_*, _support/_support_local, gait debug when present) once per
## pose evaluation and accumulates per-label statistics. Scenario scripts set
## `label`; print_report() writes one METRIC block per label.
var wako: RigidBody3D
var label := ""
var _serial := -1
var _stats: Dictionary = {}
var _order: Array[String] = []
var _grounded := [false, false]
var _anchor: Array = [null, null]          # [support WeakRef/null, local point]
var _stance_max := [0.0, 0.0]
var _stance_ticks := [0, 0]
var _swing_ticks := [0, 0]
var _swing_rel: Array = [[], []]            # sole-hip offsets along travel during the swing
var _knee_angle := [INF, INF]
var _knee_dir: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _t0 := 0
var _timer: SkeletonModifier3D
var _first_lift_pending := -1.0
var clock := 0.0
var debug := "debug=1" in OS.get_cmdline_user_args()
# Contact skating independent of the published plant flag: any sole within
# CONTACT_H of its observed terrain counts as touching; its support-relative
# drift during that contact is the skate.
const CONTACT_H := .008
var _contact := [false, false]
var _last_sole: Array[Vector3] = [Vector3.INF, Vector3.INF]
var _contact_anchor: Array = [null, null]
var _contact_max := [0.0, 0.0]

class EvalTimer extends SkeletonModifier3D:
	var probe: Node
	func _process_modification_with_delta(_delta: float) -> void:
		probe._t0 = Time.get_ticks_usec()

func attach(target: RigidBody3D) -> void:
	wako = target
	_timer = EvalTimer.new()
	_timer.probe = self
	var pose: Node = wako._pose
	wako._skeleton.add_child(_timer)
	wako._skeleton.move_child(_timer, pose.get_index())
	pose.modification_processed.connect(_on_pose_done)

func _on_pose_done() -> void:
	if _t0 <= 0: return
	var dt := Time.get_ticks_usec() - _t0
	_t0 = 0
	var s := _bucket()
	s.perf_sum += dt
	s.perf_n += 1
	s.perf_max = maxi(s.perf_max, dt)
	# Sample inside the evaluation: supports (moving decks) are at the very
	# transform the pose used, so support-relative slip is exact.
	_sample(1.0 / Engine.physics_ticks_per_second)

func mark_motion_start() -> void:
	# The scenario issued a travel command from standstill this tick.
	_first_lift_pending = clock

func _bucket() -> Dictionary:
	var key := label if not label.is_empty() else "-"
	if not _stats.has(key):
		_order.append(key)
		_stats[key] = {"ticks": 0, "speed": 0.0, "perf_sum": 0, "perf_n": 0, "perf_max": 0,
			"stances": [], "slip_max": 0.0, "landings": 0, "ground_ticks": [0, 0], "flight": 0, "moving": 0,
			"knee_pos": 0, "knee_n": 0, "knee_step": 0.0, "knee_dir_step": 0.0, "knee_step_stance": 0.0,
			"reach_viol": 0, "land_rel": [], "mid_rel": [], "plan_lag": 0.0, "start_latency": [],
			"neutral": [], "skates": [], "skate_max": 0.0, "sole_step": 0.0, "swing_time": [], "stance_time": [], "min_clear": INF}
	return _stats[key]

func _support_point(side: int) -> Array:
	var pose: Node = wako._pose
	var ref: WeakRef = pose._support[side]
	var support: Object = ref.get_ref() if ref else null
	if support is Node3D and pose._target_valid[side]:
		return [weakref(support), (support as Node3D).to_local(pose.evaluated_soles[side])]
	return [null, pose.evaluated_soles[side]]

func _support_point_any(side: int) -> Array:
	# Support owner from the latest terrain observation, plant flag or not.
	var pose: Node = wako._pose
	var ref: WeakRef = pose._support[side]
	var support: Object = ref.get_ref() if ref else null
	if support is Node3D: return [weakref(support), (support as Node3D).to_local(pose.evaluated_soles[side])]
	return [null, pose.evaluated_soles[side]]

func _physics_process(delta: float) -> void:
	clock += delta

func _sample(delta: float) -> void:
	if not is_instance_valid(wako): return
	var pose: Node = wako._pose
	if not pose.evaluated_valid or pose.evaluation_serial == _serial: return
	_serial = pose.evaluation_serial
	var s := _bucket()
	s.ticks += 1
	var rel: Vector3 = (wako.linear_velocity - wako.ground_velocity).slide(wako.ground_normal)
	var speed := rel.length()
	s.speed += speed
	var face: Vector3 = -pose.evaluated_basis.z
	var travel: Vector3 = rel.normalized() if speed > .2 else face.slide(wako.ground_normal).normalized()
	var both_air := true
	for side in 2:
		var g: bool = pose.evaluated_grounded[side]
		var sole: Vector3 = pose.evaluated_soles[side]
		var hip: Vector3 = pose.evaluated_hips[side]
		var knee: Vector3 = pose.evaluated_knees[side]
		var ankle: Vector3 = sole - pose.evaluated_ankles[side] * Vector3(0, pose._ankle_height[side], 0)
		if g: both_air = false
		if _last_sole[side].is_finite(): s.sole_step = maxf(s.sole_step, sole.distance_to(_last_sole[side]))
		_last_sole[side] = sole
		var tp0: Vector3 = pose._terrain_points[side]
		var touching: bool = tp0.is_finite() and pose._sole_normals[side].dot(sole - tp0) < CONTACT_H
		if touching and not _contact[side]:
			_contact_anchor[side] = _support_point_any(side)
			_contact_max[side] = 0.0
		elif touching:
			var ca: Array = _contact_anchor[side]
			var cexp: Vector3 = ca[1]
			if ca[0] != null:
				var csup: Object = (ca[0] as WeakRef).get_ref()
				if csup is Node3D: cexp = (csup as Node3D).to_global(ca[1])
			var drift: float = (sole - cexp).slide(pose._sole_normals[side]).length()
			if debug and drift > .008 and drift > _contact_max[side] + .002:
				var gait: Variant = pose.get("gait")
				var hip_d: float = pose.evaluated_hips[side].distance_to(sole - pose.evaluated_ankles[side] * Vector3(0, pose._ankle_height[side], 0))
				print("SKATE c=%.3f %s side=%d drift=%.3f h=%.4f grounded=%s state=%s t=%.2f req_err=%.3f hip_ankle=%.3f v=%.2f" % [clock, label, side, drift, pose._sole_normals[side].dot(sole - tp0), g, str(gait.state[side]) if gait else "-", float(gait.t[side]) if gait else -1.0, sole.distance_to(gait.requested[side]) if gait and gait.requested[side].is_finite() else -1.0, hip_d, rel.length()])
			_contact_max[side] = maxf(_contact_max[side], drift)
		elif _contact[side]:
			s.skates.append(_contact_max[side])
			s.skate_max = maxf(s.skate_max, _contact_max[side])
		_contact[side] = touching
		if debug and side == 0 and clock > 19.0 and clock < 19.3:
			var gd: Variant = pose.get("gait")
			print("TRACE t=%.3f st=%d gt=%.2f g=%s touch=%s sole=(%.3f,%.3f,%.3f) h=%.4f hip_rel=%.3f land=(%.3f,%.3f)" % [clock, gd.state[side], gd.t[side], g, touching, sole.x, sole.y, sole.z, pose._sole_normals[side].dot(sole - tp0) if tp0.is_finite() else -1.0, (sole - hip).dot(travel), gd.landing[side].x, gd.landing[side].z])
		if g: s.ground_ticks[side] += 1
		# Knee bend side relative to the face.
		var axis := (ankle - hip).normalized()
		var off := (knee - hip).slide(axis)
		if off.length() > .004:
			s.knee_n += 1
			if off.dot(face) > 0.0: s.knee_pos += 1
		var a := rad_to_deg((hip - knee).angle_to(ankle - knee))
		var kd: Vector3 = pose.evaluated_basis.inverse() * (knee - hip).normalized()
		if _knee_angle[side] != INF:
			var step := absf(a - float(_knee_angle[side]))
			if debug and step > 9.0:
				var gk: Variant = pose.get("gait")
				print("KNEE %s side=%d step=%.1f angle=%.1f g=%s state=%s t=%.2f hip_ankle=%.3f sole=%s req=%s drop=%.3f" % [label, side, step, a, g, str(gk.state[side]) if gk else "-", float(gk.t[side]) if gk else -1.0, hip.distance_to(ankle), str(sole), str(gk.requested[side]) if gk else "", float(gk.body_drop) if gk else 0.0])
			s.knee_step = maxf(s.knee_step, step)
			if g: s.knee_step_stance = maxf(s.knee_step_stance, step)
			s.knee_dir_step = maxf(s.knee_dir_step, rad_to_deg(kd.angle_to(_knee_dir[side])))
		_knee_angle[side] = a
		_knee_dir[side] = kd
		if g and hip.distance_to(ankle) > float(wako._leg_lengths[side]) - .012 + .003: s.reach_viol += 1
		# Planned-curve lag (new planner publishes its intended sole).
		var gait: Variant = pose.get("gait")
		var planned: Vector3 = Vector3.INF
		if gait != null and not g: planned = gait.debug_planned[side]
		elif gait == null and not g and float(pose._walk_swing_phase[side]) >= 0.0:
			# Original planner: same formula as _terrain_walk_leg (ignoring its cap).
			var ph: float = fposmod(wako._animation.current_animation_position / maxf(wako._animation.current_animation_length, .01) + .1 + side * .5, 1.0)
			var sp: float = pose._walk_swing_phase[side]
			var t := clampf((ph - sp) / maxf(1.0 - sp, .01), 0.0, 1.0)
			t = t + .16 * sin(PI * t)
			planned = pose._walk_swing_start[side].lerp(pose._walk_swing_landing[side], pose._walk_swing_progress(t))
		if not g:
			if planned.is_finite():
				var behind := -(sole - planned).slide(wako.ground_normal).dot(travel)
				s.plan_lag = maxf(s.plan_lag, behind)
		if g and not _grounded[side]:
			# Landing: sole relative to hip along travel.
			if speed > .3:
				s.landings += 1
				s.land_rel.append((sole - hip).slide(wako.ground_normal).dot(travel))
				var arr: Array = _swing_rel[side]
				if arr.size() > 2: s.mid_rel.append(arr[arr.size() / 2])
				s.swing_time.append(_swing_ticks[side] * delta)
			_anchor[side] = _support_point(side)
			_stance_max[side] = 0.0
			_stance_ticks[side] = 0
		elif g:
			_stance_ticks[side] += 1
			var anchor: Array = _anchor[side]
			var expected: Vector3 = anchor[1]
			if anchor[0] != null:
				var sup: Object = (anchor[0] as WeakRef).get_ref()
				if sup is Node3D: expected = (sup as Node3D).to_global(anchor[1])
			var sl: float = (sole - expected).slide(wako.ground_normal).length()
			if debug and sl > .004 and sl > _stance_max[side] + .001:
				var gs: Variant = pose.get("gait")
				print("SLIP %s side=%d slip=%.4f state=%s t=%.2f planted_pt=%s sole=%s hip_ankle=%.3f" % [label, side, sl, str(gs.state[side]) if gs else "-", float(gs.t[side]) if gs else -1.0, str(gs._planted_point(side)) if gs else "", str(sole), hip.distance_to(ankle)])
			_stance_max[side] = maxf(_stance_max[side], sl)
		elif _grounded[side]:
			# Lift-off ends a stance.
			s.stances.append(_stance_max[side])
			s.slip_max = maxf(s.slip_max, _stance_max[side])
			if speed > .3: s.stance_time.append(_stance_ticks[side] * delta)
			_swing_rel[side] = []
			_swing_ticks[side] = 0
			if _first_lift_pending >= 0.0:
				s.start_latency.append(clock - _first_lift_pending)
				_first_lift_pending = -1.0
		if not g:
			_swing_ticks[side] += 1
			(_swing_rel[side] as Array).append((sole - hip).slide(wako.ground_normal).dot(travel))
			var tp: Vector3 = pose._terrain_points[side]
			if tp.is_finite(): s.min_clear = minf(s.min_clear, pose._sole_normals[side].dot(sole - tp))
		_grounded[side] = g
	if speed > .5:
		s.moving += 1
		if both_air: s.flight += 1

func neutral_snapshot() -> Array:
	# Distances of each sole from its hip's ground projection (stance neatness).
	var pose: Node = wako._pose
	var out := []
	for side in 2:
		var d: Vector3 = (pose.evaluated_soles[side] - pose.evaluated_hips[side]).slide(wako.ground_normal)
		out.append(d.length())
	_bucket().neutral.append(out)
	return out

static func _mean(a: Array) -> float:
	if a.is_empty(): return NAN
	var t := 0.0
	for v in a: t += float(v)
	return t / a.size()

static func _minv(a: Array) -> float:
	var m := INF
	for v in a: m = minf(m, float(v))
	return m if m != INF else NAN

static func _maxv(a: Array) -> float:
	var m := -INF
	for v in a: m = maxf(m, float(v))
	return m if m != -INF else NAN

func print_report() -> void:
	for key in _order:
		var s: Dictionary = _stats[key]
		var n := maxi(int(s.ticks), 1)
		var dur := float(s.ticks) / Engine.physics_ticks_per_second
		var line := "METRIC %-16s t=%.2fs v=%.2f" % [key, dur, float(s.speed) / n]
		line += " slip_max=%.1fmm slip_mean=%.1fmm stances=%d" % [float(s.slip_max) * 1000.0, _mean(s.stances) * 1000.0, (s.stances as Array).size()]
		line += " skate_max=%.1fmm skate_mean=%.1fmm" % [float(s.skate_max) * 1000.0, _mean(s.skates) * 1000.0]
		line += " knee_fwd=%.1f%% knee_step=%.1fdeg knee_step_stance=%.1fdeg knee_dir_step=%.1fdeg reach_viol=%d" % [100.0 * s.knee_pos / maxf(s.knee_n, 1), s.knee_step, s.knee_step_stance, s.knee_dir_step, s.reach_viol]
		if int(s.landings) > 0:
			line += " steps_per_s=%.2f duty=%.2f/%.2f flight=%.1f%% swing_t=%.3f stance_t=%.3f land_rel=%.3f(min %.3f) mid_rel=%.3f plan_lag=%.3f" % [s.landings / dur, s.ground_ticks[0] / float(n), s.ground_ticks[1] / float(n), 100.0 * s.flight / maxf(s.moving, 1), _mean(s.swing_time), _mean(s.stance_time), _mean(s.land_rel), _minv(s.land_rel), _mean(s.mid_rel), s.plan_lag]
		if not (s.start_latency as Array).is_empty(): line += " start_latency=%.3fs" % _maxv(s.start_latency)
		if not (s.neutral as Array).is_empty():
			var last: Array = s.neutral[-1]
			line += " neutral_dev=%.3f/%.3f" % [last[0], last[1]]
		line += " sole_step=%.3f" % s.sole_step
		if float(s.min_clear) < INF: line += " min_swing_clear=%.3f" % s.min_clear
		if int(s.perf_n) > 0: line += " perf_us=%.0f/%d" % [float(s.perf_sum) / s.perf_n, s.perf_max]
		print(line)

extends Node
## Contract probe (from the round-3 critic): NaN/inf, bone orthonormality and
## det, published-contract coherence, grounded soles really on their support,
## knee side in gait ticks (shown bones), footstep count vs contacts, eval
## time distribution (spikes), swing lag behind the hip. gait_lab probe=1.
var wako: RigidBody3D
var metrics_ref: Node
var label := ""
var _sk: Skeleton3D
var _pose: Node
var _serial := -1
var _rest_len: Array = []
var _s: Dictionary = {}
var _order: Array[String] = []
var _t0 := 0
var _ray := PhysicsRayQueryParameters3D.new()
var _prev_g := [false, false]
var _prev_lc := [-1, -1]
var _gait_g_prev := [false, false]
var _leg_bones: Array[int] = []
var _ball_h := [.06, .06]

class EvalTimer extends SkeletonModifier3D:
	var probe: Node
	func _process_modification_with_delta(_delta: float) -> void:
		probe._t0 = Time.get_ticks_usec()

func attach(target: RigidBody3D) -> void:
	wako = target
	_sk = wako._skeleton
	_pose = wako._pose
	for b in _sk.get_bone_count():
		var r := _sk.get_bone_global_rest(b).basis
		_rest_len.append(Vector3(r.x.length(), r.y.length(), r.z.length()))
	for side in 2:
		for b: int in _pose._chains[side]: _leg_bones.append(b)
		if int(_pose._toes[side]) >= 0:
			_leg_bones.append(int(_pose._toes[side]))
			var ankle: Transform3D = _sk.get_bone_global_rest(_pose._chains[side][2])
			_ball_h[side] = _sk.get_bone_global_rest(int(_pose._toes[side])).origin.y - (ankle.origin.y - float(_pose._ankle_height[side]))
	_leg_bones.append(0)
	var timer := EvalTimer.new()
	timer.probe = self
	_sk.add_child(timer)
	_sk.move_child(timer, _pose.get_index())
	_pose.modification_processed.connect(_on_done)
	_ray.collision_mask = 1

func _b() -> Dictionary:
	if metrics_ref: label = metrics_ref.label
	var k := label if label != "" else "-"
	if not _s.has(k):
		_order.append(k)
		_s[k] = {"ticks": 0, "nan": 0, "pub_nan": 0, "gait_nan": 0, "ortho": 0.0, "lendev": 0.0, "det_min": INF,
			"wsp_bad": 0, "g_far_target": 0, "g_off_ground": 0, "g_off_max": 0.0, "support_bad": 0, "tgt_mismatch": 0.0,
			"knee_back": 0, "knee_n": 0, "us": [], "plan": [], "over1500": 0, "over3000": 0, "steps_sound": 0, "steps_contact": 0,
			"stl_bad": 0, "root_det_min": INF, "leg_ortho": 0.0, "swing_behind": 0.0}
	return _s[k]

static func _ortho_err(b: Basis) -> float:
	var x := b.x.normalized(); var y := b.y.normalized(); var z := b.z.normalized()
	return maxf(absf(x.dot(y)), maxf(absf(y.dot(z)), absf(z.dot(x))))

func _on_done() -> void:
	var s := _b()
	if _t0 > 0:
		var us := Time.get_ticks_usec() - _t0
		(s.us as Array).append(us)
		if us > 1500: s.over1500 += 1
		if us > 3000: s.over3000 += 1
		_t0 = 0
	var g: Variant = _pose.get("gait")
	if g != null and g.active: (s.plan as Array).append(int(g.plan_usec))
	s.ticks += 1
	for b in _sk.get_bone_count():
		var xf := _sk.get_bone_global_pose(b)
		if not (xf.origin.is_finite() and xf.basis.x.is_finite() and xf.basis.y.is_finite() and xf.basis.z.is_finite()):
			s.nan += 1
			continue
		var oe := _ortho_err(xf.basis)
		s.ortho = maxf(s.ortho, oe)
		if b in _leg_bones: s.leg_ortho = maxf(s.leg_ortho, oe)
		var rl: Vector3 = _rest_len[b]
		s.lendev = maxf(s.lendev, maxf(absf(xf.basis.x.length() - rl.x), maxf(absf(xf.basis.y.length() - rl.y), absf(xf.basis.z.length() - rl.z))))
		s.det_min = minf(s.det_min, xf.basis.determinant() / maxf(rl.x * rl.y * rl.z, 1e-6))
	if g != null:
		for side in 2:
			if not ((g.out_sole[side] as Vector3).is_finite() and (g.out_basis[side] as Basis).x.is_finite() and is_finite(float(g.t[side]))): s.gait_nan += 1
		for v: float in [g.phase, g.phase_rate, g.body_lean, g.body_bob, g.body_drop, g.body_y, g.body_roll, g.body_yaw, g.body_shift, g.locomotion_weight, g.squash, g.absorb]:
			if not is_finite(v): s.gait_nan += 1
		# Footstep events (helper plays one per landing_count change).
		for side in 2:
			var lc: int = g.landing_count[side]
			if _prev_lc[side] >= 0 and lc > _prev_lc[side]: s.steps_sound += lc - _prev_lc[side]
			_prev_lc[side] = lc
	var stl: float = _pose.stopped_turn_limit()
	if not is_finite(stl) or stl <= 0.0: s.stl_bad += 1
	if not _pose.evaluated_valid or _pose.evaluation_serial == _serial: return
	_serial = _pose.evaluation_serial
	var root: Transform3D = _pose.evaluated_root
	if not (root.origin.is_finite() and root.basis.x.is_finite()): s.pub_nan += 1
	else: s.root_det_min = minf(s.root_det_min, root.basis.orthonormalized().determinant())
	var gait_tick: bool = g != null and g.active and _pose._walking_ik and not g.airborne
	var face: Vector3 = -(_pose.evaluated_basis as Basis).z
	var rel: Vector3 = (wako.linear_velocity - wako.ground_velocity).slide(Vector3.UP)
	for side in 2:
		var sole: Vector3 = _pose.evaluated_soles[side]
		var hip: Vector3 = _pose.evaluated_hips[side]
		var knee: Vector3 = _pose.evaluated_knees[side]
		var ab: Basis = _pose.evaluated_ankles[side]
		if not (sole.is_finite() and hip.is_finite() and knee.is_finite() and ab.x.is_finite() and (_pose._targets[side] as Vector3).is_finite()):
			s.pub_nan += 1
			continue
		var grounded: bool = _pose.evaluated_grounded[side]
		var wsp: float = _pose._walk_swing_phase[side]
		var gait_side: bool = gait_tick and bool(_pose._gait_sides[side])
		if gait_side:
			if grounded and wsp != -1.0: s.wsp_bad += 1
			if int(g.state[side]) != 0 and wsp < 0.0: s.wsp_bad += 1
			if int(g.state[side]) == 0 and wsp != -1.0: s.wsp_bad += 1
			if grounded and sole.distance_to(_pose._targets[side]) > .021: s.g_far_target += 1
			# Knee side from the SHOWN bones.
			var c: Array = _pose._chains[side]
			var bh := _sk.global_transform * _sk.get_bone_global_pose(int(c[0])).origin
			var bk := _sk.global_transform * _sk.get_bone_global_pose(int(c[1])).origin
			var ba := _sk.global_transform * _sk.get_bone_global_pose(int(c[2])).origin
			var off := (bk - bh).slide((ba - bh).normalized())
			if off.length() > .004:
				s.knee_n += 1
				if off.dot(face) <= 0.0: s.knee_back += 1
			if not grounded and int(g.state[side]) == 1 and float(g.t[side]) >= .6 and rel.length() > .6 and g.moving:
				var want: Vector3 = wako.get("locomotion_desired")
				if want.slide(Vector3.UP).length() < .1 or want.slide(Vector3.UP).normalized().dot(rel.normalized()) > .7:
					s.swing_behind = maxf(s.swing_behind, -(sole - hip).slide(Vector3.UP).dot(rel.normalized()))
			if grounded and not _gait_g_prev[side]: s.steps_contact += 1
			_gait_g_prev[side] = grounded
		else:
			_gait_g_prev[side] = grounded
		if grounded:
			_ray.exclude = wako.query_exclusions()
			_ray.from = sole + Vector3.UP * .3
			_ray.to = sole - Vector3.UP * .3
			var hit := wako.get_world_3d().direct_space_state.intersect_ray(_ray)
			if not hit.is_empty():
				# The toe pad stays down while the heel peels: judge the lower of sole/ball.
				var h: float = absf((hit.normal as Vector3).dot(sole - hit.position))
				var toe: int = _pose._toes[side]
				if toe >= 0 and h > .012:
					var ball: Vector3 = _sk.global_transform * _sk.get_bone_global_pose(toe).origin
					_ray.from = ball + Vector3.UP * .3
					_ray.to = ball - Vector3.UP * .3
					var bh2 := wako.get_world_3d().direct_space_state.intersect_ray(_ray)
					if not bh2.is_empty(): h = minf(h, absf((bh2.normal as Vector3).dot(ball - bh2.position) - float(_ball_h[side])))
				s.g_off_max = maxf(s.g_off_max, h)
				if h > .02: s.g_off_ground += 1
			else: s.g_off_ground += 1
			if _pose._target_valid[side]:
				var ref: WeakRef = _pose._support[side]
				var sup: Object = ref.get_ref() if ref else null
				if sup is Node3D and (_pose._support_rids[side] as RID).is_valid():
					s.tgt_mismatch = maxf(s.tgt_mismatch, (sup as Node3D).to_global(_pose._support_local[side]).distance_to(_pose._targets[side]))
				else: s.support_bad += 1
			else: s.support_bad += 1

static func _pct(a: Array, q: float) -> int:
	if a.is_empty(): return 0
	var c := a.duplicate(); c.sort()
	return int(c[mini(int(c.size() * q), c.size() - 1)])

func report() -> void:
	for k in _order:
		var s: Dictionary = _s[k]
		print("PROBE %-18s ticks=%d nan=%d pub_nan=%d gait_nan=%d ortho=%.6f leg_ortho=%.6f lendev=%.6f det_min=%.4f root_det=%.4f wsp_bad=%d g_far_target=%d g_off_ground=%d g_off_max=%.1fmm support_bad=%d tgt_mismatch=%.4f knee_back=%d/%d swing_behind=%.3f steps sound/contact=%d/%d stl_bad=%d us_p50/p99/max=%d/%d/%d over1.5ms=%d over3ms=%d plan_p50/p99/max=%d/%d/%d" % [k, s.ticks, s.nan, s.pub_nan, s.gait_nan, s.ortho, s.leg_ortho, s.lendev, s.det_min, s.root_det_min, s.wsp_bad, s.g_far_target, s.g_off_ground, s.g_off_max * 1000.0, s.support_bad, s.tgt_mismatch, s.knee_back, s.knee_n, s.swing_behind, s.steps_sound, s.steps_contact, s.stl_bad, _pct(s.us, .5), _pct(s.us, .99), _pct(s.us, 1.0), s.over1500, s.over3000, _pct(s.plan, .5), _pct(s.plan, .99), _pct(s.plan, 1.0)])

extends Node
## Quantitative gait acceptance probe. Reads only the published pose caches
## (evaluated_*, _support/_support_local, final bone poses, gait debug when
## present) once per pose evaluation and accumulates per-label statistics.
## Scenario scripts set `label`; print_report() writes one METRIC block per
## label (contacts/knees/cadence) plus one ACTING block (body acting, push-off,
## leg clearance, skinned toe penetration, owner handoffs).
## Horizontal quantities are measured with slide(UP), never along a slope
## normal, and a contact is judged by a vertical ray under the sole.
var wako: RigidBody3D
var label := ""
var _serial := -1
var _stats: Dictionary = {}
var _order: Array[String] = []
var _grounded := [false, false]
var _anchor: Array = [null, null]          # [support WeakRef/null, local sole, local ball]
var _stance_max := [0.0, 0.0]
var _stance_ticks := [0, 0]
var _swing_ticks := [0, 0]
var _swing_rel: Array = [[], []]            # horizontal sole-hip offsets along travel during the swing
var _swing_apex := [0.0, 0.0]
var _knee_angle := [INF, INF]
var _knee_dir: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _stance_flex: Array = [[], []]
var _last_state := [0, 0]
var _anchor_label := ""
var _bone_knee := [INF, INF]
var _bone_root := Transform3D()
var _bone_root_ok := false
var _t0 := 0
var _timer: SkeletonModifier3D
var _first_lift_pending := -1.0
var clock := 0.0
var debug := "debug=1" in OS.get_cmdline_user_args()
var dump_label := ""
# Contact skating independent of the published plant flag: a sole (heel/
# ankle projection) or its toe joint (the ball, which carries a peeled heel)
# within CONTACT_H of the ground under it counts as touching; the drift of
# whichever of the two stays put is the skate.
const CONTACT_H := .008
var _contact := [false, false]
var _last_sole: Array[Vector3] = [Vector3.INF, Vector3.INF]
var _contact_anchor: Array = [null, null]
var _contact_max := [0.0, 0.0]
var _ray := PhysicsRayQueryParameters3D.new()
var _ray_age := 999
var _ball_rest_h := [.06, .06]
# Acting history (time, root height) for the bob phase.
var _hist: Array = []
var _stance_start := [-1.0, -1.0]
var _flight_start := -1.0
var _prev_root := Transform3D()
var _prev_root_ok := false
var _prev_active := false
# Skinned foot/toe underside vertices: [side] -> Array of [[bone, weight, bone-local point], ...]
var _sole_verts: Array = [[], []]
var _mesh: MeshInstance3D
var _sk: Skeleton3D
# Regression checks (critic round 2): pronks, taps, slow flight, stuck
# contacts, 4-tick (one 30 fps frame) knee change, shin tilt, toe/heel in
# geometry. _n counts published evaluations (the per-label arrays insert a
# NAN break when a label is re-entered, so second differences never span gaps).
var _n := 0
var _lift_n := [-99, -99]
var _land_n := [-99, -99]
var _ground_run := [0, 0]
var _air_run := 0
var _air_counted := false
var _stuck := [0, 0]
var _k_hist: Array = [[], []]               # last 5 [angle, grounded, stance_tick]
var _swing_flex := [0.0, 0.0]

class EvalTimer extends SkeletonModifier3D:
	var probe: Node
	func _process_modification_with_delta(_delta: float) -> void:
		probe._t0 = Time.get_ticks_usec()

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("dump="): dump_label = a.get_slice("=", 1)

func attach(target: RigidBody3D) -> void:
	wako = target
	_timer = EvalTimer.new()
	_timer.probe = self
	var pose: Node = wako._pose
	_sk = wako._skeleton
	_sk.add_child(_timer)
	_sk.move_child(_timer, pose.get_index())
	pose.modification_processed.connect(_on_pose_done)
	for side in 2:
		var toe: int = pose._toes[side]
		if toe >= 0:
			var ankle: Transform3D = _sk.get_bone_global_rest(pose._chains[side][2])
			_ball_rest_h[side] = _sk.get_bone_global_rest(toe).origin.y - (ankle.origin.y - float(pose._ankle_height[side]))
	_collect_sole_verts()
	var g: Variant = pose.get("gait")
	if debug and g != null and "debug_log" in g:
		g.debug_log = true
		print("GAITRIG ball_off=%s toe_dir=%s ankle_h=%s legs=%s roll_hip=%s" % [str(g._ball_off), str(g._toe_dir), str(pose._ankle_height), str(wako._leg_lengths), str(g.get("_roll_hip"))])

func _collect_sole_verts() -> void:
	# The underside of each foot+toe in the rest pose (lowest 3 cm of the
	# vertices skinned mostly to that ankle/toe), for a skinned penetration test.
	_mesh = wako.get("_skin_mesh")
	if not is_instance_valid(_mesh) or _mesh.skin == null or _mesh.mesh == null: return
	var pose: Node = wako._pose
	var skin: Skin = _mesh.skin
	var bind_bone: Array[int] = []
	for i in skin.get_bind_count():
		var b := skin.get_bind_bone(i)
		if b < 0: b = _sk.find_bone(skin.get_bind_name(i))
		bind_bone.append(b)
	for side in 2:
		var foot_bones := [int(pose._chains[side][2]), int(pose._toes[side])]
		var picked: Array = []
		var lowest := INF
		for s in _mesh.mesh.get_surface_count():
			var arr := _mesh.mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var bones = arr[Mesh.ARRAY_BONES]
			var weights = arr[Mesh.ARRAY_WEIGHTS]
			if bones == null or weights == null or verts.is_empty(): continue
			var per := int(bones.size() / verts.size())
			for vi in verts.size():
				var on_foot := 0.0
				var influences: Array = []
				for k in per:
					var w: float = weights[vi * per + k]
					if w <= .0001: continue
					var bi: int = int(bones[vi * per + k])
					var bone: int = bind_bone[bi] if bi < bind_bone.size() else -1
					if bone < 0: continue
					if bone in foot_bones: on_foot += w
					influences.append([bone, w, skin.get_bind_pose(bi) * verts[vi]])
				if on_foot < .5: continue
				var rest_pos := Vector3.ZERO
				for inf: Array in influences: rest_pos += _sk.get_bone_global_rest(int(inf[0])) * (inf[2] as Vector3) * float(inf[1])
				lowest = minf(lowest, rest_pos.y)
				picked.append([rest_pos.y, influences])
		var keep: Array = []
		var ext := AABB()
		var ankle_rest := _sk.get_bone_global_rest(int(pose._chains[side][2]))
		var sole_rest := ankle_rest.origin - Vector3(0, float(pose._ankle_height[side]), 0)
		for p: Array in picked:
			if float(p[0]) < lowest + .03:
				keep.append(p[1])
				var rp := Vector3.ZERO
				for inf: Array in p[1]: rp += _sk.get_bone_global_rest(int(inf[0])) * (inf[2] as Vector3) * float(inf[1])
				ext = AABB(rp - sole_rest, Vector3.ZERO) if ext.size == Vector3.ZERO and ext.position == Vector3.ZERO else ext.expand(rp - sole_rest)
		if debug: print("FOOTPRINT side=%d rel_sole min=%s max=%s lowest_rel=%.3f" % [side, str(ext.position), str(ext.end), lowest - sole_rest.y])
		# Bounded cost: at most 90 underside vertices per foot.
		var stride := maxi(1, ceili(keep.size() / 90.0))
		for i in range(0, keep.size(), stride): (_sole_verts[side] as Array).append(keep[i])
	print("METRICS sole_verts L=%d R=%d mesh_on_skeleton=%s" % [(_sole_verts[0] as Array).size(), (_sole_verts[1] as Array).size(), _mesh.global_transform.is_equal_approx(_sk.global_transform)])

func _on_pose_done() -> void:
	if _t0 <= 0: return
	var dt := Time.get_ticks_usec() - _t0
	_t0 = 0
	var s := _bucket()
	s.perf_sum += dt
	s.perf_n += 1
	s.perf_max = maxi(s.perf_max, dt)
	if (s.perf_samples as Array).size() < 4000: (s.perf_samples as Array).append(dt)
	var gait_obj: Variant = wako._pose.get("gait")
	if gait_obj != null and gait_obj.active:
		s.plan_sum += int(gait_obj.plan_usec)
		s.plan_n += 1
		s.plan_max = maxi(s.plan_max, int(gait_obj.plan_usec))
		if (s.plan_samples as Array).size() < 4000: (s.plan_samples as Array).append(int(gait_obj.plan_usec))
	_bones_every_tick(s)
	# Sample inside the evaluation: supports (moving decks) are at the very
	# transform the pose used, so support-relative slip is exact.
	_sample(1.0 / Engine.physics_ticks_per_second)

func _bones_every_tick(s: Dictionary) -> void:
	# Final bones of EVERY evaluation, published or not (airborne, ragdoll
	# capture, other owners): what is actually shown. Catches take-off and
	# landing snaps that the published caches skip.
	var pose: Node = wako._pose
	for side in 2:
		var chain: Array = pose._chains[side]
		var hip := _sk.get_bone_global_pose(int(chain[0])).origin
		var knee := _sk.get_bone_global_pose(int(chain[1])).origin
		var ankle := _sk.get_bone_global_pose(int(chain[2])).origin
		var a := rad_to_deg((hip - knee).angle_to(ankle - knee))
		if _bone_knee[side] != INF:
			s.knee_step_shown = maxf(s.knee_step_shown, absf(a - float(_bone_knee[side])))
			var window := clock > float(OS.get_environment("TRACE_T0")) and clock < float(OS.get_environment("TRACE_T1")) if OS.get_environment("TRACE_T0") != "" else false
			if debug and (absf(a - float(_bone_knee[side])) > 9.0 or window):
				var g: Variant = pose.get("gait")
				print("SHOWN c=%.3f %s side=%d step=%.1f angle=%.1f on_ground=%s valid=%s walking_ik=%s air=%s active=%s state=%s anim=%s" % [clock, label, side, absf(a - float(_bone_knee[side])), a, wako.on_ground, pose.evaluated_valid, pose._walking_ik, g.airborne if g and "airborne" in g else "-", g.active if g else "-", str(g.state[side]) if g else "-", wako._animation.current_animation])
		_bone_knee[side] = a
	var root := _sk.get_bone_global_pose(0)
	if _bone_root_ok:
		s.root_step_shown = maxf(s.root_step_shown, root.origin.distance_to(_bone_root.origin))
		s.root_turn_shown = maxf(s.root_turn_shown, rad_to_deg(root.basis.get_rotation_quaternion().angle_to(_bone_root.basis.get_rotation_quaternion())))
	_bone_root = root
	_bone_root_ok = true

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
			"reach_viol": 0, "land_rel": [], "mid_rel": [], "plan_lag": 0.0, "late_behind": 0.0, "start_latency": [],
			"neutral": [], "skates": [], "skate_max": 0.0, "sole_step": 0.0, "tool_blocked": 0, "plan_sum": 0, "plan_n": 0, "plan_max": 0, "perf_samples": [], "plan_samples": [], "swing_time": [], "stance_time": [], "min_clear": INF,
			"rh": [], "ry": [], "pitch": [], "roll": [], "twist": [], "bob_low": [], "bob_high": [], "flex_off": [], "flex_mid": [],
			"leg_gap": INF, "ankle_gap": INF, "track": [], "apex": [], "toe_pen": -INF, "toe_pen_g": -INF,
			"root_step": 0.0, "root_turn": 0.0, "handoffs": 0, "knee_step_shown": 0.0, "root_step_shown": 0.0, "root_turn_shown": 0.0,
			"last_n": -2, "pronk": 0, "taps": 0, "air_slow": 0, "both_up_duty": 0, "both_up_ev": 0, "stuck_max": 0, "knee4_g": 0.0, "knee4_land": 0.0,
			"flex_g": [], "flex_td": [], "flex_swing": [], "shin_back": [], "behind5": 0, "ahead5": 0, "rel_n": 0, "ball_pen": 0.0, "heel_pen": 0.0}
	return _stats[key]

func _support_point(side: int, any := false) -> Array:
	# Support-local sole and ball (toe joint) for drift measurements.
	var pose: Node = wako._pose
	var ref: WeakRef = pose._support[side]
	var support: Object = ref.get_ref() if ref else null
	var sole: Vector3 = pose.evaluated_soles[side]
	var ball := _ball(side)
	if support is Node3D and (any or pose._target_valid[side]):
		return [weakref(support), (support as Node3D).to_local(sole), (support as Node3D).to_local(ball)]
	return [null, sole, ball]

func _contact_point(side: int) -> Array:
	# Anchor a physical contact in the frame of the body actually under the
	# sole (pose._support can still name a deck the foot just stepped off).
	var sole: Vector3 = wako._pose.evaluated_soles[side]
	var ball := _ball(side)
	var hit := _ground_hit(sole)
	if not hit.is_empty() and hit.collider is Node3D and not hit.collider is StaticBody3D:
		var body: Node3D = hit.collider
		return [weakref(body), body.to_local(sole), body.to_local(ball)]
	return [null, sole, ball]

func _drift(anchor: Array, side: int) -> float:
	var sole: Vector3 = wako._pose.evaluated_soles[side]
	var ball := _ball(side)
	var es: Vector3 = anchor[1]
	var eb: Vector3 = anchor[2]
	if anchor[0] != null:
		var sup: Object = (anchor[0] as WeakRef).get_ref()
		if sup is Node3D:
			es = (sup as Node3D).to_global(anchor[1])
			eb = (sup as Node3D).to_global(anchor[2])
	return minf((sole - es).slide(Vector3.UP).length(), (ball - eb).slide(Vector3.UP).length())

func _ball(side: int) -> Vector3:
	var toe: int = wako._pose._toes[side]
	if toe < 0: return wako._pose.evaluated_soles[side]
	return _sk.global_transform * _sk.get_bone_global_pose(toe).origin

func _ground_hit(point: Vector3) -> Dictionary:
	_ray_age += 1
	if _ray_age > 60:
		_ray_age = 0
		# The creature's own carried bodies (a foot-held mallet, head cargo)
		# are not ground: a sole resting on its own tool is not a contact.
		var ex: Array[RID] = wako.query_exclusions()
		for body: Variant in [wako.equipped_tool, wako._cargo_source]:
			if body is CollisionObject3D and is_instance_valid(body): ex.append((body as CollisionObject3D).get_rid())
		_ray.exclude = ex
		_ray.collision_mask = 1
	_ray.from = point + Vector3.UP * .5
	_ray.to = point - Vector3.UP * .6
	return wako.get_world_3d().direct_space_state.intersect_ray(_ray)

func _ground_y(point: Vector3) -> float:
	var hit := _ground_hit(point)
	return hit.position.y if not hit.is_empty() else -INF

func _physics_process(delta: float) -> void:
	clock += delta

static func _seg_dist(p1: Vector3, q1: Vector3, p2: Vector3, q2: Vector3) -> float:
	# Closest distance between two segments (Ericson, RTCD 5.1.9).
	var d1 := q1 - p1
	var d2 := q2 - p2
	var r := p1 - p2
	var a := d1.dot(d1)
	var e := d2.dot(d2)
	var f := d2.dot(r)
	var s := 0.0
	var t := 0.0
	if a <= 1e-9 and e <= 1e-9: return r.length()
	if a <= 1e-9: t = clampf(f / e, 0.0, 1.0)
	else:
		var c := d1.dot(r)
		if e <= 1e-9: s = clampf(-c / a, 0.0, 1.0)
		else:
			var b := d1.dot(d2)
			var denom := a * e - b * b
			s = clampf((b * f - c * e) / denom, 0.0, 1.0) if denom > 1e-9 else 0.0
			t = (b * s + f) / e
			if t < 0.0:
				t = 0.0
				s = clampf(-c / a, 0.0, 1.0)
			elif t > 1.0:
				t = 1.0
				s = clampf((b - c) / a, 0.0, 1.0)
	return ((p1 + d1 * s) - (p2 + d2 * t)).length()

func _sample(delta: float) -> void:
	if not is_instance_valid(wako): return
	var pose: Node = wako._pose
	if not pose.evaluated_valid or pose.evaluation_serial == _serial: return
	_serial = pose.evaluation_serial
	_n += 1
	var s := _bucket()
	s.ticks += 1
	if int(s.last_n) >= 0 and int(s.last_n) != _n - 1:
		# Re-entered label: break the series (no fake second differences).
		for key: String in ["rh", "ry", "pitch", "roll", "twist"]: (s[key] as Array).append(NAN)
	s.last_n = _n
	var gait: Variant = pose.get("gait")
	if label != _anchor_label:
		# Drift is judged per phase: a new label re-anchors the soles that
		# are already down (another owner may have moved them before).
		_anchor_label = label
		for side in 2:
			if _grounded[side]:
				_anchor[side] = _support_point(side)
				_stance_max[side] = 0.0
			if _contact[side]:
				_contact_anchor[side] = _contact_point(side)
				_contact_max[side] = 0.0
	if not dump_label.is_empty() and (dump_label == "*" or label.begins_with(dump_label)): _dump(pose, gait)
	if not str(wako.tool_pose_blocked).is_empty(): s.tool_blocked += 1
	var rel: Vector3 = (wako.linear_velocity - wako.ground_velocity).slide(wako.ground_normal)
	var speed := rel.length()
	s.speed += speed
	var face: Vector3 = -pose.evaluated_basis.z
	var flat_rel := rel.slide(Vector3.UP)
	var travel: Vector3 = flat_rel.normalized() if flat_rel.length() > .2 else face.slide(Vector3.UP).normalized()
	var heading_fwd := Vector3(-sin(float(wako._heading)), 0.0, -cos(float(wako._heading)))
	var right := heading_fwd.cross(Vector3.UP)
	# Root pops relative to the body (owner handoffs show up here).
	var root_rel: Transform3D = pose.evaluated_worker.affine_inverse() * pose.evaluated_root
	if _prev_root_ok:
		var rstep := root_rel.origin.distance_to(_prev_root.origin)
		var rturn := rad_to_deg(root_rel.basis.get_rotation_quaternion().angle_to(_prev_root.basis.get_rotation_quaternion()))
		s.root_step = maxf(s.root_step, rstep)
		s.root_turn = maxf(s.root_turn, rturn)
		if debug and (rstep > .02 or rturn > 4.0):
			print("ROOTPOP c=%.3f %s step=%.4f turn=%.2f active=%s w=%.3f" % [clock, label, rstep, rturn, gait.active if gait else false, float(gait.locomotion_weight) if gait else 0.0])
	_prev_root = root_rel
	_prev_root_ok = true
	var active_now: bool = gait != null and gait.active
	if active_now != _prev_active: s.handoffs += 1
	_prev_active = active_now
	# Body acting: height above the ground under the body, pitch/roll vs the
	# heading frame, hip twist vs the heading.
	var root_up: Vector3 = pose.evaluated_root.basis.y.normalized()
	var root_face: Vector3 = (pose.evaluated_root.basis * Vector3.BACK).slide(Vector3.UP).normalized()
	var rh: float = pose.evaluated_root.origin.y - float(wako._ground_point.y)
	(s.rh as Array).append(rh)
	(s.ry as Array).append(pose.evaluated_root.origin.y)
	if debug and (s.ry as Array).size() > 2:
		var ry: Array = s.ry
		var acc := (float(ry[-1]) - 2.0 * float(ry[-2]) + float(ry[-3])) * 14400.0
		if absf(acc) > 60.0:
			print("VACC c=%.3f %s acc=%.0f y=%.4f drop=%.3f body_y=%.3f bob=%.3f settle=%.3f squash=%.3f wy=%.4f states=%s" % [clock, label, acc, ry[-1], float(gait.body_drop) if gait else 0.0, float(gait.body_y) if gait else 0.0, float(gait.body_bob) if gait and "body_bob" in gait else 0.0, float(gait.settle_dip) if gait else 0.0, float(gait.squash) if gait and "squash" in gait else 0.0, wako.global_position.y, str(gait.state) if gait else "-"])
	(s.pitch as Array).append(rad_to_deg(asin(clampf(root_up.dot(heading_fwd), -1.0, 1.0))))
	(s.roll as Array).append(rad_to_deg(asin(clampf(root_up.dot(right), -1.0, 1.0))))
	(s.twist as Array).append(rad_to_deg(heading_fwd.signed_angle_to(root_face, Vector3.UP)))
	_hist.append([clock, rh])
	if _hist.size() > 200: _hist.pop_front()
	var both_air := true
	var knees: Array[Vector3] = []
	var ankles: Array[Vector3] = []
	for side in 2:
		var g: bool = pose.evaluated_grounded[side]
		var sole: Vector3 = pose.evaluated_soles[side]
		var hip: Vector3 = pose.evaluated_hips[side]
		var knee: Vector3 = pose.evaluated_knees[side]
		var ankle: Vector3 = sole - pose.evaluated_ankles[side] * Vector3(0, pose._ankle_height[side], 0)
		knees.append(knee)
		ankles.append(ankle)
		if g: both_air = false
		if _last_sole[side].is_finite():
			s.sole_step = maxf(s.sole_step, sole.distance_to(_last_sole[side]))
		_last_sole[side] = sole
		# Contact by a vertical ray under the sole (and the ball for a peel).
		var ground := _ground_y(sole)
		var ball := _ball(side)
		var gap_sole := sole.y - ground
		var gap_ball := ball.y - _ground_y(ball) - float(_ball_rest_h[side])
		var touching: bool = (gap_sole < CONTACT_H and gap_sole > -.03) or (gap_ball < CONTACT_H and gap_ball > -.03)
		if gap_ball < .1:
			if debug and -gap_ball > .008 and -gap_ball > float(s.ball_pen) + .002: print("BALLPEN c=%.3f %s side=%d pen=%.4f sole_gap=%.4f g=%s state=%s t=%.2f ball=%s sole=%s" % [clock, label, side, -gap_ball, gap_sole, g, str(gait.state[side]) if gait else "-", float(gait.t[side]) if gait else -1.0, str(ball), str(sole)])
			s.ball_pen = maxf(s.ball_pen, -gap_ball)
		if gap_sole < .1: s.heel_pen = maxf(s.heel_pen, -gap_sole)
		if touching and not _contact[side]:
			_contact_anchor[side] = _contact_point(side)
			_contact_max[side] = 0.0
		elif touching:
			var drift := _drift(_contact_anchor[side], side)
			if debug and OS.get_environment("TRACE_BALL") == label and side == 0:
				var an: Array = _contact_anchor[side]
				print("BALL c=%.3f gap=%.4f/%.4f sole_drift=%.4f ball_drift=%.4f D=%.3f leg=%.3f peel_state=%s" % [clock, gap_sole, gap_ball, (sole - (an[1] as Vector3)).slide(Vector3.UP).length(), (ball - (an[2] as Vector3)).slide(Vector3.UP).length(), hip.distance_to(ankle), float(wako._leg_lengths[side]), str(gait.state[side]) if gait else "-"])
			if debug and drift > .004 and drift > _contact_max[side] + .001:
				print("SKATE c=%.3f %s side=%d drift=%.3f gap=%.4f/%.4f grounded=%s state=%s t=%.2f v=%.2f" % [clock, label, side, drift, gap_sole, gap_ball, g, str(gait.state[side]) if gait else "-", float(gait.t[side]) if gait else -1.0, rel.length()])
			_contact_max[side] = maxf(_contact_max[side], drift)
		elif _contact[side]:
			s.skates.append(_contact_max[side])
			s.skate_max = maxf(s.skate_max, _contact_max[side])
		_contact[side] = touching
		if g: s.ground_ticks[side] += 1
		# Knee bend side relative to the face, angle and flexion.
		var axis := (ankle - hip).normalized()
		var off := (knee - hip).slide(axis)
		if off.length() > .004:
			s.knee_n += 1
			if off.dot(face) > 0.0: s.knee_pos += 1
		var a := rad_to_deg((hip - knee).angle_to(ankle - knee))
		var flex := 180.0 - a
		var kd: Vector3 = pose.evaluated_basis.inverse() * (knee - hip).normalized()
		if _knee_angle[side] != INF:
			var step := absf(a - float(_knee_angle[side]))
			if debug and step > 9.0:
				print("KNEE c=%.3f %s side=%d step=%.1f angle=%.1f g=%s state=%s t=%.2f hip_ankle=%.3f drop=%.3f" % [clock, label, side, step, a, g, str(gait.state[side]) if gait else "-", float(gait.t[side]) if gait else -1.0, hip.distance_to(ankle), float(gait.body_drop) if gait else 0.0])
			s.knee_step = maxf(s.knee_step, step)
			if g: s.knee_step_stance = maxf(s.knee_step_stance, step)
			s.knee_dir_step = maxf(s.knee_dir_step, rad_to_deg(kd.angle_to(_knee_dir[side])))
		if debug and gait != null and int(gait.state[side]) != int(_last_state[side]):
			print("EVT c=%.3f %s side=%d %d->%d t=%.2f angle=%.1f g=%s hip_ankle=%.3f" % [clock, label, side, _last_state[side], gait.state[side], float(gait.t[side]), a, g, hip.distance_to(ankle)])
		if gait != null: _last_state[side] = int(gait.state[side])
		_knee_angle[side] = a
		_knee_dir[side] = kd
		_regressions(s, side, g, a, flex, hip, knee, ankle, sole, travel, speed, gait)
		if g and hip.distance_to(ankle) > float(wako._leg_lengths[side]) - .012 + .003: s.reach_viol += 1
		# Planned-curve offset (the planner's own re-target carry; informative).
		if gait != null and not g and gait.debug_planned[side].is_finite():
			var behind_plan: float = -(sole - gait.debug_planned[side]).slide(Vector3.UP).dot(travel)
			s.plan_lag = maxf(s.plan_lag, behind_plan)
		var ahead := (sole - hip).slide(Vector3.UP).dot(travel)
		if g and not _grounded[side]:
			# Landing: horizontal sole ahead of the hip along travel.
			if speed > .3:
				s.landings += 1
				s.land_rel.append(ahead)
				var arr: Array = _swing_rel[side]
				if arr.size() > 2: s.mid_rel.append(arr[arr.size() / 2])
				s.swing_time.append(_swing_ticks[side] * delta)
				s.apex.append(_swing_apex[side])
				(s.track as Array).append(absf((sole - pose.evaluated_soles[1 - side]).slide(Vector3.UP).dot(right)))
			_anchor[side] = _support_point(side)
			_stance_max[side] = 0.0
			_stance_ticks[side] = 0
			_stance_flex[side] = []
			_stance_start[side] = clock
		elif g:
			_stance_ticks[side] += 1
			var sl := _drift(_anchor[side], side)
			if debug and sl > .004 and sl > _stance_max[side] + .001:
				print("SLIP %s side=%d slip=%.4f state=%s t=%.2f hip_ankle=%.3f" % [label, side, sl, str(gait.state[side]) if gait else "-", float(gait.t[side]) if gait else -1.0, hip.distance_to(ankle)])
			_stance_max[side] = maxf(_stance_max[side], sl)
		elif _grounded[side]:
			# Lift-off ends a stance: slip, push-off flexion, bob phase.
			s.stances.append(_stance_max[side])
			s.slip_max = maxf(s.slip_max, _stance_max[side])
			if speed > .3:
				s.stance_time.append(_stance_ticks[side] * delta)
				var flexes: Array = _stance_flex[side]
				if flexes.size() > 4:
					s.flex_off.append(flexes[-1])
					s.flex_mid.append(flexes[flexes.size() / 2])
				if _stance_start[side] >= 0.0 and speed > 2.6: _bob_low(s, _stance_start[side], clock - delta)
			_swing_rel[side] = []
			_swing_ticks[side] = 0
			_swing_apex[side] = 0.0
			if _first_lift_pending >= 0.0:
				s.start_latency.append(clock - _first_lift_pending)
				_first_lift_pending = -1.0
		if g: (_stance_flex[side] as Array).append(flex)
		if not g:
			_swing_ticks[side] += 1
			(_swing_rel[side] as Array).append(ahead)
			_swing_apex[side] = maxf(_swing_apex[side], ankle.y - ground)
			var wsp: float = pose._walk_swing_phase[side]
			# Judged while the request agrees with the motion: mid-reversal the
			# planner deliberately lands toward where the body is GOING.
			var wanted: Vector3 = wako.locomotion_desired.slide(Vector3.UP)
			var steady := wanted.length() < .1 or wanted.normalized().dot(travel) > .7
			if wsp >= .6 and speed > .6 and gait != null and gait.moving and gait.state[side] == 1 and steady:
				if debug and -ahead > .1 and -ahead > float(s.late_behind) + .01: print("LATE c=%.3f %s side=%d behind=%.3f t=%.2f g=%s" % [clock, label, side, -ahead, wsp, g])
				s.late_behind = maxf(s.late_behind, -ahead)
			if ground > -INF: s.min_clear = minf(s.min_clear, gap_sole)
		_grounded[side] = g
	# Both feet up: slow flight (>= 30 ms below 1 m/s) and any double swing
	# while the gait itself wants double support (duty >= .5).
	if both_air and not wako._pose.evaluated_grounded[0] and gait != null and gait.active:
		_air_run += 1
		if speed < 1.0 and _air_run >= 4 and not _air_counted:
			s.air_slow += 1
			_air_counted = true
		if gait.moving and float(gait.duty) >= .5 and speed > .2:
			s.both_up_duty += 1
			if _air_run == 1: s.both_up_ev += 1
			if debug and _air_run == 1: print("BOTHUP c=%.3f %s duty=%.2f v=%.2f states=%s t=%s" % [clock, label, gait.duty, speed, str(gait.state), str(gait.t)])
	else:
		_air_run = 0
		_air_counted = false
	var gap := _seg_dist(knees[0], ankles[0], knees[1], ankles[1])
	if debug and gap < .18:
		print("LEGGAP c=%.3f %s gap=%.3f states=%s t=%s soles=%s/%s heading=%.2f" % [clock, label, gap, str(gait.state) if gait else "-", str(gait.t) if gait else "-", str(pose.evaluated_soles[0]), str(pose.evaluated_soles[1]), float(wako._heading)])
	s.leg_gap = minf(s.leg_gap, gap)
	s.ankle_gap = minf(s.ankle_gap, (ankles[0] - ankles[1]).slide(Vector3.UP).length())
	if speed > .5:
		s.moving += 1
		if both_air: s.flight += 1
	# Flight intervals at a run: the body should peak mid-flight.
	if both_air and speed > 2.6:
		if _flight_start < 0.0: _flight_start = clock
	elif _flight_start >= 0.0:
		if clock - _flight_start > .02: _bob_high(s, _flight_start, clock - delta)
		_flight_start = -1.0
	if int(s.ticks) % 3 == 0: _toe_penetration(s, pose)

func _regressions(s: Dictionary, side: int, g: bool, a: float, flex: float, hip: Vector3, knee: Vector3, ankle: Vector3, sole: Vector3, travel: Vector3, speed: float, gait: Variant) -> void:
	var was: bool = _grounded[side]
	# Lifts/landings of both feet within 2 ticks below 2.5 m/s: a pronk.
	if was and not g:
		_lift_n[side] = _n
		if _n - int(_lift_n[1 - side]) <= 2 and speed < 2.5 and speed > .2:
			s.pronk += 1
			if debug: print("PRONK lift c=%.3f %s v=%.2f" % [clock, label, speed])
		if _ground_run[side] <= 2 and speed > .2:
			s.taps += 1
			if debug: print("TAP c=%.3f %s side=%d ticks=%d v=%.2f" % [clock, label, side, _ground_run[side], speed])
	if g and not was:
		_land_n[side] = _n
		if _n - int(_land_n[1 - side]) <= 2 and speed < 2.5 and speed > .2:
			s.pronk += 1
			if debug: print("PRONK land c=%.3f %s v=%.2f" % [clock, label, speed])
	_ground_run[side] = _ground_run[side] + 1 if g else 0
	# A contact the planner keeps deferring at the end of its swing.
	if gait != null and int(gait.state[side]) != 0 and float(gait.t[side]) >= .99 and not g: _stuck[side] += 1
	else: _stuck[side] = 0
	s.stuck_max = maxi(int(s.stuck_max), int(_stuck[side]))
	# Knee change over one 30 fps frame on a foot grounded throughout; the
	# first 8 stance ticks are the landing absorption.
	var hist: Array = _k_hist[side]
	hist.append([a, g, _ground_run[side]])
	if hist.size() > 5: hist.pop_front()
	if hist.size() == 5 and g and bool(hist[0][1]) and bool(hist[1][1]) and bool(hist[2][1]) and bool(hist[3][1]):
		var change := absf(a - float(hist[0][0]))
		s.knee4_g = maxf(s.knee4_g, change)
		if int(_ground_run[side]) <= 9: s.knee4_land = maxf(s.knee4_land, change)
		if debug and change > 25.0: print("KNEE4 c=%.3f %s side=%d change=%.1f stance_tick=%d" % [clock, label, side, change, _ground_run[side]])
	if speed > .3:
		if g:
			(s.flex_g as Array).append(flex)
			if not was: (s.flex_td as Array).append(flex)
		else: _swing_flex[side] = maxf(_swing_flex[side], flex)
		if g and not was and _swing_flex[side] > 0.0:
			(s.flex_swing as Array).append(_swing_flex[side])
			_swing_flex[side] = 0.0
		# Shin tilt along travel: + means the ankle trails the knee (backward).
		var shin := ankle - knee
		(s.shin_back as Array).append(rad_to_deg(atan2(-shin.dot(travel), -shin.y)))
		var ahead := (sole - hip).slide(Vector3.UP).dot(travel)
		s.rel_n += 1
		if ahead < -.05: s.behind5 += 1
		elif ahead > .05: s.ahead5 += 1

static func _pct(a: Array, q: float) -> float:
	var c: Array = []
	for v in a:
		if not is_nan(float(v)): c.append(float(v))
	if c.is_empty(): return NAN
	c.sort()
	return float(c[clampi(int(c.size() * q), 0, c.size() - 1)])

func _bob_low(s: Dictionary, t0: float, t1: float) -> void:
	var best := INF
	var at := 0.0
	for h: Array in _hist:
		if float(h[0]) >= t0 - .0001 and float(h[0]) <= t1 + .0001 and float(h[1]) < best:
			best = float(h[1])
			at = float(h[0])
	if best < INF: (s.bob_low as Array).append((at - (t0 + t1) * .5) * 1000.0)

func _bob_high(s: Dictionary, t0: float, t1: float) -> void:
	# Search the flight +-25 ms so a peak just outside it still counts.
	var best := -INF
	var at := 0.0
	for h: Array in _hist:
		if float(h[0]) >= t0 - .025 and float(h[0]) <= t1 + .025 and float(h[1]) > best:
			best = float(h[1])
			at = float(h[0])
	if best > -INF: (s.bob_high as Array).append((at - (t0 + t1) * .5) * 1000.0)

func _toe_penetration(s: Dictionary, pose: Node) -> void:
	if not is_instance_valid(_mesh): return
	var xf := _mesh.global_transform
	for side in 2:
		var verts: Array = _sole_verts[side]
		if verts.is_empty(): continue
		# Against the support plane under the sole (slopes included); each
		# vertex's depth below that plane, measured along its normal.
		var hit := _ground_hit(pose.evaluated_soles[side])
		if hit.is_empty(): continue
		var n: Vector3 = hit.normal
		var pen := -INF
		for v: Array in verts:
			var p := Vector3.ZERO
			for inf: Array in v: p += _sk.get_bone_global_pose(int(inf[0])) * (inf[2] as Vector3) * float(inf[1])
			pen = maxf(pen, -n.dot(xf * p - hit.position))
		s.toe_pen = maxf(s.toe_pen, pen)
		if debug and pen > .002 and pose.evaluated_grounded[side]:
			var toe_rot: Quaternion = _sk.get_bone_pose_rotation(int(pose._toes[side]))
			var rest_rot: Quaternion = _sk.get_bone_rest(int(pose._toes[side])).basis.get_rotation_quaternion()
			var foot_up: Vector3 = -(_sk.global_basis * _sk.get_bone_global_pose(int(pose._chains[side][2])).basis.y).normalized()
			print("TOEPEN c=%.3f %s side=%d pen=%.4f toe_vs_rest=%.1fdeg foot_tilt=%.1fdeg action=%s anim=%s" % [clock, label, side, pen, rad_to_deg(toe_rot.angle_to(rest_rot)), rad_to_deg(foot_up.angle_to(n)), wako.action, wako._animation.current_animation])
		if pose.evaluated_grounded[side]: s.toe_pen_g = maxf(s.toe_pen_g, pen)

func _dump(pose: Node, gs: Variant) -> void:
	# Pose dump for the strobe/series plotters (harness/scripts/gait_strobe.py).
	var root: Transform3D = pose.evaluated_root
	var line := "POSE %.4f %s %s" % [clock, _v(root.origin), _v(root.basis.y)]
	for side in 2:
		var ankle: Vector3 = pose.evaluated_soles[side] - pose.evaluated_ankles[side] * Vector3(0, pose._ankle_height[side], 0)
		line += " %d %s %s %s %s" % [1 if pose.evaluated_grounded[side] else 0, _v(pose.evaluated_hips[side]), _v(pose.evaluated_knees[side]), _v(ankle), _v(pose.evaluated_soles[side])]
	if gs:
		line += " drop=%.3f y=%.3f lean=%.3f" % [gs.body_drop, float(gs.body_y) + float(gs.get("body_bob") if gs.get("body_bob") != null else 0.0), gs.body_lean]
		line += " gt=%.3f,%.3f gs=%d,%d roll=%.3f ph=%.3f" % [gs.t[0], gs.t[1], gs.state[0], gs.state[1], gs.body_roll, gs.get("_act_phase") if gs.get("_act_phase") != null else -1.0]
	print(line + " " + label.replace(" ", "_"))
	var line2 := "POSE2 %.4f %s %s %s %s" % [clock, _v(root.origin), _v(root.basis.x), _v(root.basis.y), _v(root.basis.z)]
	for side in 2:
		var ti: int = pose._toes[side]
		var txf: Transform3D = _sk.global_transform * _sk.get_bone_global_pose(ti) if ti >= 0 else Transform3D()
		var axf: Transform3D = _sk.global_transform * _sk.get_bone_global_pose(pose._chains[side][2])
		line2 += " %d %s %s %s" % [1 if pose.evaluated_grounded[side] else 0, _v(txf.origin), _v(txf.origin + txf.basis.y.normalized() * .08), _v(axf.origin)]
	line2 += " v=%.3f" % (wako.linear_velocity - wako.ground_velocity).slide(wako.ground_normal).length()
	print(line2 + " " + label.replace(" ", "_"))

func neutral_snapshot() -> Array:
	# Horizontal distances of each sole from its hip's vertical projection.
	var pose: Node = wako._pose
	var out := []
	for side in 2:
		var d: Vector3 = (pose.evaluated_soles[side] - pose.evaluated_hips[side]).slide(Vector3.UP)
		out.append(d.length())
	_bucket().neutral.append(out)
	return out

static func _v(p: Vector3) -> String:
	return "%.4f,%.4f,%.4f" % [p.x, p.y, p.z]

static func _median(a: Array) -> int:
	if a.is_empty(): return 0
	var c := a.duplicate()
	c.sort()
	return int(c[c.size() / 2])

static func _mean(a: Array) -> float:
	if a.is_empty(): return NAN
	var t := 0.0
	for v in a: t += float(v)
	return t / a.size()

static func _mean_abs(a: Array) -> float:
	if a.is_empty(): return NAN
	var t := 0.0
	for v in a: t += absf(float(v))
	return t / a.size()

static func _minv(a: Array) -> float:
	var m := INF
	for v in a:
		if not is_nan(float(v)): m = minf(m, float(v))
	return m if m != INF else NAN

static func _maxv(a: Array) -> float:
	var m := -INF
	for v in a:
		if not is_nan(float(v)): m = maxf(m, float(v))
	return m if m != -INF else NAN

static func _vacc(a: Array) -> float:
	# Largest vertical root acceleration (second difference at 120 Hz).
	var m := 0.0
	for i in range(2, a.size()):
		var v := absf(float(a[i]) - 2.0 * float(a[i - 1]) + float(a[i - 2])) * 14400.0
		if not is_nan(v): m = maxf(m, v)
	return m

static func _p2p(a: Array) -> float:
	# Robust peak-to-peak (5th..95th percentile) of a steady phase.
	var c: Array = []
	for v in a:
		if not is_nan(float(v)): c.append(float(v))
	if c.size() < 8: return NAN
	c.sort()
	return float(c[int(c.size() * .95)]) - float(c[int(c.size() * .05)])

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
			line += " steps_per_s=%.2f duty=%.2f/%.2f flight=%.1f%% swing_t=%.3f stance_t=%.3f land_rel=%.3f(min %.3f) mid_rel=%.3f late_behind=%.3f plan_lag=%.3f" % [s.landings / dur, s.ground_ticks[0] / float(n), s.ground_ticks[1] / float(n), 100.0 * s.flight / maxf(s.moving, 1), _mean(s.swing_time), _mean(s.stance_time), _mean(s.land_rel), _minv(s.land_rel), _mean(s.mid_rel), s.late_behind, s.plan_lag]
		if not (s.start_latency as Array).is_empty(): line += " start_latency=%.3fs" % _maxv(s.start_latency)
		if not (s.neutral as Array).is_empty():
			var last: Array = s.neutral[-1]
			line += " neutral_dev=%.3f/%.3f" % [last[0], last[1]]
		line += " sole_step=%.3f" % s.sole_step
		if int(s.tool_blocked) > 0: line += " tool_blocked=%d" % s.tool_blocked
		if float(s.min_clear) < INF: line += " min_swing_clear=%.3f" % s.min_clear
		# Timings: median (robust to preemption on a shared CPU) / mean / max.
		line += " stuck_max=%d pronk=%d taps=%d air_slow=%d both_up_duty=%d/%dev knee4_g=%.1fdeg knee4_land=%.1fdeg ball_pen=%.1fmm heel_pen=%.1fmm" % [s.stuck_max, s.pronk, s.taps, s.air_slow, s.both_up_duty, s.both_up_ev, s.knee4_g, s.knee4_land, float(s.ball_pen) * 1000.0, float(s.heel_pen) * 1000.0]
		if not (s.flex_g as Array).is_empty():
			line += " flex_g_p5/p50/p95=%.0f/%.0f/%.0f flex_td=%.0f flex_swing=%.0f shin_back_p10/p50=%.0f/%.0f behind5/ahead5=%.0f/%.0f%%" % [_pct(s.flex_g, .05), _pct(s.flex_g, .5), _pct(s.flex_g, .95), _mean(s.flex_td), _mean(s.flex_swing), _pct(s.shin_back, .1), _pct(s.shin_back, .5), 100.0 * s.behind5 / maxf(s.rel_n, 1), 100.0 * s.ahead5 / maxf(s.rel_n, 1)]
		if int(s.perf_n) > 0: line += " perf_us=%d/%.0f/%d" % [_median(s.perf_samples), float(s.perf_sum) / s.perf_n, s.perf_max]
		if int(s.plan_n) > 0: line += " plan_us=%d/%.0f/%d" % [_median(s.plan_samples), float(s.plan_sum) / s.plan_n, s.plan_max]
		print(line)
		var act := "ACTING %-16s bob_p2p=%.1fcm pitch_p2p=%.1fdeg roll_p2p=%.1fdeg twist_p2p=%.1fdeg pitch_range=%.1f..%.1fdeg root_vacc_max=%.0fm/s2" % [key, _p2p(s.rh) * 100.0, _p2p(s.pitch), _p2p(s.roll), _p2p(s.twist), _minv(s.pitch), _maxv(s.pitch), _vacc(s.ry)]
		if key.begins_with("stop") and (s.pitch as Array).size() > 8:
			# Braking lean-back, then how far the cube pitches past upright.
			var pa: Array = s.pitch
			var lo := pa.find(_minv(pa))
			act += " brake_lean=%.1fdeg follow_through=%+.1fdeg" % [_minv(pa), _maxv(pa.slice(lo))]
		if not (s.bob_low as Array).is_empty(): act += " bob_low_vs_midstance=%+.0fms(|%.0f|)" % [_mean(s.bob_low), _mean_abs(s.bob_low)]
		if not (s.bob_high as Array).is_empty(): act += " bob_high_vs_midflight=%+.0fms(|%.0f|)" % [_mean(s.bob_high), _mean_abs(s.bob_high)]
		if not (s.flex_off as Array).is_empty(): act += " knee_flex_mid/toeoff=%.0f/%.0fdeg" % [_mean(s.flex_mid), _mean(s.flex_off)]
		if not (s.apex as Array).is_empty(): act += " swing_apex_ankle=%.3f" % _mean(s.apex)
		if not (s.track as Array).is_empty(): act += " track=%.3f(min %.3f)" % [_mean(s.track), _minv(s.track)]
		act += " leg_gap_min=%.3f ankle_gap_min=%.3f" % [s.leg_gap, s.ankle_gap]
		if float(s.toe_pen) > -INF: act += " toe_pen=%.1fmm(planted %.1fmm)" % [float(s.toe_pen) * 1000.0, float(s.toe_pen_g) * 1000.0]
		act += " root_step=%.4f root_turn=%.2fdeg handoffs=%d shown_knee_step=%.1fdeg shown_root_step=%.4f shown_root_turn=%.2fdeg" % [s.root_step, s.root_turn, s.handoffs, s.knee_step_shown, s.root_step_shown, s.root_turn_shown]
		print(act)
		# Pass/fail summary against the acceptance gates (informative for
		# phases owned by foot actions, falls or ragdoll).
		var fails: Array[String] = []
		if float(s.late_behind) > .10: fails.append("late_behind=%.3f" % s.late_behind)
		if int(s.stuck_max) > 3: fails.append("stuck=%d" % s.stuck_max)
		if int(s.pronk) > 0: fails.append("pronk=%d" % s.pronk)
		if int(s.taps) > 0: fails.append("taps=%d" % s.taps)
		if int(s.both_up_duty) > 0: fails.append("both_up_duty=%d" % s.both_up_duty)
		if int(s.air_slow) > 0: fails.append("air_slow=%d" % s.air_slow)
		if float(s.skate_max) > .006: fails.append("skate=%.1fmm" % (float(s.skate_max) * 1000.0))
		if float(s.slip_max) > .005: fails.append("slip=%.1fmm" % (float(s.slip_max) * 1000.0))
		if int(s.knee_n) > 0 and int(s.knee_pos) < int(s.knee_n): fails.append("knee_fwd")
		if int(s.reach_viol) > 0: fails.append("reach_viol=%d" % s.reach_viol)
		if float(s.ball_pen) > .008: fails.append("ball_pen=%.1fmm" % (float(s.ball_pen) * 1000.0))
		if float(s.knee4_land) > 25.0: fails.append("knee4_land=%.0f" % s.knee4_land)
		if float(s.knee_step_stance) > 8.0: fails.append("knee_step_stance=%.1f" % s.knee_step_stance)
		print("GATE %-16s %s" % [key, "ok" if fails.is_empty() else "FAIL " + " ".join(fails)])

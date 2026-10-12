extends RefCounted
## Get-up pose matching (POLISH2-GETUP): which get-up clip, from which frame, turned which way (and mirrored or not)
## fits the body lying on the ground best.
##
## The candidates are every get-up clip (get_up_back, get_up_front) and its left/right mirror (built once from the
## clip's own keys, see build_mirror()), sampled every STEP s over the first SPAN of the clip (lying, rolling over,
## sitting up, on all fours). A candidate is compared with the ragdoll by
##   - every joint's local rotation (child bone relative to its parent body's bone: yaw and position don't matter),
##     weighted (torso and the big limb joints more than the hands, feet and head),
##   - the torso's tilt (hips and upper chest, after the best turn about UP: what the body can't change by itself
##     while it lies there), and
##   - the hips' height above the ground,
## and the best one gives the clip, the start time and the root yaw (from the torso's heading). The database is built
## a few samples per physics tick during the fall (never more than BUILD_BUDGET_US per tick), and the matching pass
## runs a few candidates per tick while the body settles, so no frame pays for all of it.

const Clip := preload("res://Components/Avatar/ragdoll/ragdoll_clip.gd")
const Rig := preload("res://Components/Avatar/ragdoll/ragdoll_rig.gd")
const UP := Vector3.UP
const CLIPS : Array[StringName] = [&"get_up_back", &"get_up_front"]
const MIRROR_SUFFIX := "_mirror"
## Share of each clip that is sampled (from its start) and the spacing of the samples (clip seconds)
const SPAN := 0.55
const STEP := 0.05
## Joint weights (by bone name without Left / Right); torso tilt and hips height weights (per rad / per 0.1 m)
const W := {&"Spine": 1.5, &"Chest": 1.5, &"UpperChest": 1.5, &"Neck": 0.5, &"Head": 0.5, &"UpperArm": 1.3,
	&"LowerArm": 1.0, &"Hand": 0.35, &"UpperLeg": 1.6, &"LowerLeg": 1.3, &"Foot": 0.45}
const W_TILT := 6.0
## Per rad a candidate's joints lie outside the ragdoll's joint ranges (the pre-pose can't reach it)
const W_LIMIT := 5.0
const W_HEIGHT := 1.5
## Per rad of difference in how steeply the spine rises (a body lying flat is matched to a frame lying flat: the
## pre-pose rolls it over, it doesn't sit it up at the same time)
const W_ELEV := 5.0
const BUILD_BUDGET_US := 450
const MATCH_PER_TICK := 24


class Entry:
	var clip : StringName
	var t := 0.0
	var mirror := false
	## per body: the bone's rotation relative to its parent body's bone (root: identity)
	var rel : Array[Quaternion] = []
	## hips / upper chest bone rotations in the avatar's frame at yaw 0
	var qh := Quaternion.IDENTITY
	var qc := Quaternion.IDENTITY
	## hips height above the ground (m)
	var h := 0.0
	## how steeply the spine rises (rad)
	var el := 0.0
	## upper chest height above the ground (m)
	var hc := 0.0
	## how deep its limbs reach into flat ground (m, summed)
	var ground := 0.0
	## how far its joints lie outside the ragdoll's ranges (rad, summed)
	var excess := 0.0


## The ragdoll's pose, measured once per matching pass
class Feat:
	var rel : Array[Quaternion] = []
	var qh := Quaternion.IDENTITY
	var qc := Quaternion.IDENTITY
	var h := 0.0
	var el := 0.0
	var hc := 0.0


var rd : Object # the AvatarRagdoll
var entries : Array[Entry] = []
var ready := false
var build_us := 0 # total time spent building (us)
var _w := PackedFloat32Array()
var _wsum := 0.0
var _todo : Array = [] # [clip name, t] or [clip name, "mirror"]
var _mirror_jobs := {} # clip -> incremental mirror build state
var _b_hips := 0
var _b_uc := 0
# matching pass
var _feat : Feat
var _next := 0
var _costs := PackedFloat32Array()
var _yaws := PackedFloat32Array()
var pass_us := 0 # time spent in the current pass (us)
var pass_max_tick_us := 0


func setup(ragdoll : Object) -> void:
	rd = ragdoll
	var rig : Object = rd.rig
	_w.resize(rig.bodies.size())
	_wsum = 0.0
	for b in rig.bodies:
		var key := StringName(String(b.name).trim_prefix("Left").trim_prefix("Right"))
		var w : float = W.get(key, 1.0) if b.parent >= 0 else 0.0
		_w[b.index] = w
		_wsum += w
	_b_hips = (rig.by_name[&"Hips"]).index
	_b_uc = (rig.by_name[&"UpperChest"]).index
	var lib : AnimationLibrary = rd.av.profile.library
	for cn in CLIPS:
		if not lib.has_animation(cn):
			continue
		_queue_samples(cn)
		_todo.append([cn, "mirror"])


func _queue_samples(cn : StringName) -> void:
	var a : Animation = rd.av.profile.library.get_animation(cn)
	var n := int(floor(a.length * SPAN / STEP))
	for k in n + 1:
		_todo.append([cn, k * STEP])


## Builds a little more of the database (call every physics tick while the body is down). True when it is complete.
func build_step(budget_us := BUILD_BUDGET_US) -> bool:
	if ready:
		return true
	var t0 := Time.get_ticks_usec()
	while not _todo.is_empty() and Time.get_ticks_usec() - t0 < budget_us:
		var job : Array = _todo[0]
		if job[1] is String:
			# The mirrored clip: built a few tracks at a time, then its samples are queued
			if _mirror_step(job[0], t0, budget_us):
				_todo.pop_front()
				var mn := StringName(String(job[0]) + MIRROR_SUFFIX)
				if rd.av.profile.library.has_animation(mn):
					_queue_samples(mn)
			continue
		_todo.pop_front()
		entries.append(_sample_entry(job[0], job[1]))
	build_us += Time.get_ticks_usec() - t0
	ready = _todo.is_empty()
	if ready:
		_costs.resize(entries.size())
		_yaws.resize(entries.size())
	return ready


## Everything at once (a knock-down that ends before the database is complete).
func build_all() -> void:
	while not build_step(1 << 30):
		pass


func _sample_entry(cn : StringName, t : float) -> Entry:
	var clip : Clip = rd._get_clip(cn)
	var T : Transform3D = rd._skel_for(clip)
	var smp := clip.sample(t)
	var e := Entry.new()
	e.clip = cn
	e.t = t
	e.mirror = String(cn).ends_with(MIRROR_SUFFIX)
	var rig : Object = rd.rig
	e.rel.resize(rig.bodies.size())
	var q := PackedVector4Array()
	var gq : Array[Quaternion] = []
	gq.resize(rig.bodies.size())
	for b in rig.bodies:
		gq[b.index] = (smp[b.bone][1] as Transform3D).basis.orthonormalized().get_rotation_quaternion()
	for b in rig.bodies:
		e.rel[b.index] = Quaternion.IDENTITY if b.parent < 0 else (gq[b.parent].inverse() * gq[b.index]).normalized()
	var TR := T.basis.orthonormalized().get_rotation_quaternion()
	e.qh = (TR * gq[_b_hips]).normalized()
	e.qc = (TR * gq[_b_uc]).normalized()
	e.h = (T * (smp[rig.bodies[_b_hips].bone][1] as Transform3D).origin).y
	e.hc = (T * (smp[rig.bodies[_b_uc].bone][1] as Transform3D).origin).y
	e.el = _elevation(T * (smp[rig.bodies[_b_hips].bone][1] as Transform3D).origin, T * (smp[rig.bodies[_b_uc].bone][1] as Transform3D).origin)
	var xf : Array[Transform3D] = []
	for b in rig.bodies:
		xf.append((smp[b.bone][1] as Transform3D) * b.b2b_inv)
	e.excess = excess(xf)
	# Limbs the frame puts into flat ground (the torso is lifted as a whole, see AvatarRagdoll._gather_targets): the
	# pre-pose can't reach them there
	var lift := 0.0
	for b in rig.bodies:
		if b.region == &"torso" or b.region == &"hips":
			lift = maxf(lift, -lowest(b, T * xf[b.index]))
	for b in rig.bodies:
		if b.region != &"torso" and b.region != &"hips":
			# (the feet's capsules are rough: a flat sole is thinner than they are)
			var k := 0.5 if String(b.name).ends_with("Foot") else 1.0
			e.ground += k * maxf(-(lowest(b, T * xf[b.index]) + lift), 0.0)
	return e


## The lowest point of a body's shape at `x` (y, m).
static func lowest(b : Object, x : Transform3D) -> float:
	var cap := b.shape as CapsuleShape3D
	if cap:
		var hh := cap.height * 0.5 - cap.radius
		return minf((x * Vector3(0, hh, 0)).y, (x * Vector3(0, -hh, 0)).y) - cap.radius
	var bx := b.shape as BoxShape3D
	var lo := INF
	if bx:
		var h := bx.size * 0.5
		for i in 8:
			lo = minf(lo, (x * Vector3(h.x * (1 if i & 1 else -1), h.y * (1 if i & 2 else -1), h.z * (1 if i & 4 else -1))).y)
	return lo if lo < INF else x.origin.y


## How far a pose (body transforms, any common frame) lies outside the ragdoll's joint ranges (rad, summed over the
## joints): cones by swing and twist, hinges by the bend and by any turn off the hinge (the elbow's forearm turn and
## carrying angle have some play, the knee none).
func excess(xf : Array[Transform3D]) -> float:
	var ex := 0.0
	for b in rd.rig.bodies:
		if b.parent < 0:
			continue
		var fa : Transform3D = xf[b.parent] * b.jframe_parent
		var fb : Transform3D = xf[b.index] * b.jframe_self
		var rel := fa.basis.orthonormalized().inverse() * fb.basis.orthonormalized()
		var q := rel.get_rotation_quaternion()
		var tw := absf(_twist_angle(q))
		if b.hinge:
			var bend := rad_to_deg(atan2(rel.x.y, rel.x.x)) # + = the way it bends
			var off := rad_to_deg(asin(clampf(absf(rel.x.z), 0.0, 1.0)))
			var arm := String(b.name).contains("Arm")
			var lim := rad_to_deg(b.limit)
			ex += deg_to_rad(maxf(bend - lim, 0.0) + maxf(-bend - 3.0, 0.0))
			ex += deg_to_rad(maxf(off - (Rig.ELBOW_OFF_AXIS if arm else 3.0), 0.0))
			ex += deg_to_rad(maxf(rad_to_deg(tw) - (Rig.FOREARM_TWIST if arm else 3.0), 0.0))
		else:
			var swing := acos(clampf(rel.x.x, -1.0, 1.0))
			ex += maxf(swing - b.limit_getup, 0.0) + maxf(tw - b.twist_getup, 0.0)
	return ex


static func _twist_angle(q : Quaternion) -> float:
	var tw := Quaternion(q.x, 0.0, 0.0, q.w)
	if tw.length_squared() < 1e-10:
		return 0.0
	tw = tw.normalized()
	return wrapf(2.0 * atan2(tw.x, tw.w), -PI, PI)


## The ragdoll's pose now (bone frames: body * b2b).
func measure() -> Feat:
	var f := Feat.new()
	var rig : Object = rd.rig
	var n : int = rig.bodies.size()
	var gq : Array[Quaternion] = []
	gq.resize(n)
	for b in rig.bodies:
		gq[b.index] = ((rd._cur[b.index] as Transform3D) * b.b2b).basis.orthonormalized().get_rotation_quaternion()
	f.rel.resize(n)
	for b in rig.bodies:
		f.rel[b.index] = Quaternion.IDENTITY if b.parent < 0 else (gq[b.parent].inverse() * gq[b.index]).normalized()
	f.qh = gq[_b_hips]
	f.qc = gq[_b_uc]
	var hp : Vector3 = ((rd._cur[_b_hips] as Transform3D) * rig.bodies[_b_hips].b2b).origin
	var gy : float = rd._ground_y(hp, hp.y - 1.0)
	f.h = hp.y - gy
	var cp : Vector3 = ((rd._cur[_b_uc] as Transform3D) * rig.bodies[_b_uc].b2b).origin
	f.el = _elevation(hp, cp)
	f.hc = cp.y - rd._ground_y(cp, cp.y - 1.0)
	return f


## Cost of one candidate against the pose (weighted mean angle, rad) and the yaw that lines its torso up.
func cost(f : Feat, e : Entry) -> Vector2:
	var s := 0.0
	for i in _w.size():
		var wi := _w[i]
		if wi > 0.0:
			s += wi * 2.0 * acos(minf(absf(f.rel[i].dot(e.rel[i])), 1.0))
	var q1 := f.qh * e.qh.inverse()
	var q2 := f.qc * e.qc.inverse()
	if q1.dot(q2) < 0.0:
		q2 = -q2
	var qa := q1 + q2
	var yaw := 2.0 * atan2(qa.y, qa.w) if absf(qa.y) + absf(qa.w) > 1e-6 else 0.0
	var Y := Quaternion(UP, yaw)
	var tilt := 0.5 * (2.0 * acos(minf(absf(f.qh.dot(Y * e.qh)), 1.0)) + 2.0 * acos(minf(absf(f.qc.dot(Y * e.qc)), 1.0)))
	# (hips and upper chest: a body lying on the ground isn't matched to a push-up it would have to lift itself into)
	var dh := (absf(f.h - e.h) + absf(f.hc - e.hc)) / 0.1 + e.ground / 0.05
	var de := absf(f.el - e.el)
	return Vector2((s + W_TILT * tilt + W_HEIGHT * dh + W_ELEV * de + W_LIMIT * e.excess) / (_wsum + W_TILT + W_HEIGHT + W_ELEV), yaw)


## How steeply the spine rises from the hips to the upper chest (rad, 0 = lying flat).
static func _elevation(hips : Vector3, chest : Vector3) -> float:
	var d := chest - hips
	return atan2(d.y, Vector2(d.x, d.z).length())


## The torso's tilt difference (deg: hips, upper chest) after the turn `yaw`.
func tilt(f : Feat, e : Entry, yaw : float) -> Vector2:
	var Y := Quaternion(UP, yaw)
	return Vector2(rad_to_deg(f.qh.angle_to(Y * e.qh)), rad_to_deg(f.qc.angle_to(Y * e.qc)))


## Unweighted mean and max angle (deg) of the joints' local rotations, pose vs candidate (the harness' pose error).
func joint_error(f : Feat, e : Entry) -> Vector2:
	var tot := 0.0
	var mx := 0.0
	var n := 0
	for b in rd.rig.bodies:
		if b.parent < 0:
			continue
		var a := rad_to_deg(2.0 * acos(minf(absf(f.rel[b.index].dot(e.rel[b.index])), 1.0)))
		tot += a
		mx = maxf(mx, a)
		n += 1
	return Vector2(tot / maxf(n, 1), mx)


# --- the matching pass (a few candidates per tick) ---------------------------------------------------------------------

func begin_pass() -> void:
	_feat = measure()
	_next = 0
	pass_us = 0
	pass_max_tick_us = 0


func pass_active() -> bool:
	return _feat != null


func pass_done() -> bool:
	return _feat != null and _next >= entries.size()


func cancel_pass() -> void:
	_feat = null


func pass_step(n := MATCH_PER_TICK) -> void:
	if _feat == null:
		return
	var t0 := Time.get_ticks_usec()
	var end := mini(_next + n, entries.size())
	for i in range(_next, end):
		var c := cost(_feat, entries[i])
		_costs[i] = c.x
		_yaws[i] = c.y
	_next = end
	var us := Time.get_ticks_usec() - t0
	pass_us += us
	pass_max_tick_us = maxi(pass_max_tick_us, us)


## Finishes the pass: the pose is measured again and the best few candidates of the pass (and the neighbouring clip
## times of the best one) are scored against it. Returns {entry, cost, yaw, feat}.
func finish() -> Dictionary:
	if _feat == null:
		begin_pass()
	var t0 := Time.get_ticks_usec()
	pass_step(entries.size())
	var t1 := Time.get_ticks_usec()
	var order := range(entries.size())
	order.sort_custom(func(a : int, b : int) -> bool: return _costs[a] < _costs[b])
	var f := measure()
	var best := -1
	var best_c := INF
	var best_yaw := 0.0
	for k in mini(8, order.size()):
		var c := cost(f, entries[order[k]])
		if c.x < best_c:
			best_c = c.x
			best = order[k]
			best_yaw = c.y
	var out := {}
	if best < 0:
		_feat = null
		return out
	var be := entries[best]
	# Between the samples: half a step either side
	for dt in [-STEP * 0.5, STEP * 0.5]:
		var t : float = be.t + dt
		if t < 0.0:
			continue
		var e := _sample_entry(be.clip, t)
		var c := cost(f, e)
		if c.x < best_c:
			best_c = c.x
			be = e
			best_yaw = c.y
	pass_us += Time.get_ticks_usec() - t1
	pass_max_tick_us = maxi(pass_max_tick_us, int(Time.get_ticks_usec() - t0))
	out = {entry = be, cost = best_c, yaw = best_yaw, feat = f}
	_feat = null
	return out


## The best candidate restricted to one clip at t (the old choice: frame 0), for comparisons.
func score(f : Feat, cn : StringName, t : float) -> Dictionary:
	var e := _sample_entry(cn, t)
	var c := cost(f, e)
	return {entry = e, cost = c.x, yaw = c.y}


# --- mirrored clips ------------------------------------------------------------------------------------------------------

## Mirrors a humanoid clip left <-> right (the skeleton's sagittal plane), key by key. For a bone m whose mirror is b,
## with M the reflection and K_x = (M R_x M)^-1 R_mirror(x) (R = global rest rotations, so the mirrored rest is the
## rest): local'_m = K_parent(b)^-1 (M local_b M) K_b and position'_m = K_parent(b)^-1 M position_b. Returns true when
## done (it works through BUILD_BUDGET_US per call).
func _mirror_step(cn : StringName, t0 : int, budget_us : int) -> bool:
	var lib : AnimationLibrary = rd.av.profile.library
	var mn := StringName(String(cn) + MIRROR_SUFFIX)
	if lib.has_animation(mn):
		_mirror_meta(cn, mn)
		return true
	var sk : Skeleton3D = rd.av.skeleton
	var job : Dictionary = _mirror_jobs.get(cn, {})
	if job.is_empty():
		var src := lib.get_animation(cn)
		var dst := Animation.new()
		dst.length = src.length
		dst.step = src.step
		dst.loop_mode = src.loop_mode
		var l := sk.get_bone_global_rest(sk.find_bone("LeftUpperLeg")).origin
		var r := sk.get_bone_global_rest(sk.find_bone("RightUpperLeg")).origin
		var nrm := (l - r).normalized()
		var M := Basis(Vector3.RIGHT - 2.0 * nrm.x * nrm, Vector3.UP - 2.0 * nrm.y * nrm, Vector3.BACK - 2.0 * nrm.z * nrm)
		job = {src = src, dst = dst, M = M, track = 0, K = {}}
		_mirror_jobs[cn] = job
	var src2 : Animation = job["src"]
	var dst2 : Animation = job["dst"]
	var M2 : Basis = job["M"]
	var K : Dictionary = job["K"]
	var prefix := "%" + String(rd.av.profile.skeleton_name) + ":"
	while int(job["track"]) < src2.get_track_count():
		if Time.get_ticks_usec() - t0 >= budget_us:
			return false
		var ti := int(job["track"])
		job["track"] = ti + 1
		var path := String(src2.track_get_path(ti))
		var typ := src2.track_get_type(ti)
		var bn := path.trim_prefix(prefix)
		var b := sk.find_bone(bn)
		var mname := _mirror_name(bn)
		var m := sk.find_bone(mname)
		var nt := dst2.add_track(typ)
		dst2.track_set_interpolation_type(nt, src2.track_get_interpolation_type(ti))
		dst2.track_set_imported(nt, src2.track_is_imported(ti))
		if not path.begins_with(prefix) or b < 0 or m < 0:
			dst2.track_set_path(nt, src2.track_get_path(ti))
			for k in src2.track_get_key_count(ti):
				dst2.track_insert_key(nt, src2.track_get_key_time(ti, k), src2.track_get_key_value(ti, k))
			continue
		dst2.track_set_path(nt, NodePath(prefix + mname))
		var pb := sk.get_bone_parent(b)
		var Kp := _k(sk, M2, K, pb)
		var Kb := _k(sk, M2, K, b)
		var Kpi := Kp.inverse()
		for k in src2.track_get_key_count(ti):
			var kt := src2.track_get_key_time(ti, k)
			match typ:
				Animation.TYPE_ROTATION_3D:
					var L := Basis(src2.track_get_key_value(ti, k) as Quaternion)
					dst2.rotation_track_insert_key(nt, kt, (Kpi * (M2 * L * M2) * Kb).orthonormalized().get_rotation_quaternion())
				Animation.TYPE_POSITION_3D:
					dst2.position_track_insert_key(nt, kt, Kpi * (M2 * (src2.track_get_key_value(ti, k) as Vector3)))
				_:
					dst2.track_insert_key(nt, kt, src2.track_get_key_value(ti, k))
	lib.add_animation(mn, dst2)
	_mirror_jobs.erase(cn)
	_mirror_meta(cn, mn)
	return true


## K_x (see _mirror_step); identity for no bone.
static func _k(sk : Skeleton3D, M : Basis, cache : Dictionary, x : int) -> Basis:
	if x < 0:
		return Basis()
	if cache.has(x):
		return cache[x]
	var mx := sk.find_bone(_mirror_name(sk.get_bone_name(x)))
	if mx < 0:
		mx = x
	var Rx := sk.get_bone_global_rest(x).basis.orthonormalized()
	var Rm := sk.get_bone_global_rest(mx).basis.orthonormalized()
	var k := ((M * Rx * M).inverse() * Rm).orthonormalized()
	cache[x] = k
	return k


static func _mirror_name(n : String) -> String:
	if n.begins_with("Left"):
		return "Right" + n.substr(4)
	if n.begins_with("Right"):
		return "Left" + n.substr(5)
	return n


## The mirrored clip's metadata (ground, length; the travel and turn mirrored) next to the original's.
func _mirror_meta(cn : StringName, mn : StringName) -> void:
	var meta : Dictionary = rd.av.profile.clip_meta()
	if meta.has(String(mn)) or not meta.has(String(cn)):
		return
	var m : Dictionary = (meta[String(cn)] as Dictionary).duplicate(true)
	if m.has("root_turn_deg"):
		m["root_turn_deg"] = -float(m["root_turn_deg"])
	if m.has("root_travel") and (m["root_travel"] as Array).size() == 3:
		m["root_travel"][0] = -float(m["root_travel"][0])
	meta[String(mn)] = m

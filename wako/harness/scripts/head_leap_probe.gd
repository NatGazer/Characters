extends Node
## Head-leap metrics probe. Samples the real worker bodies once per physics tick
## (after the helpers have run) and reports the flip as numbers: rotation,
## tuck, durations, apex, measured assist force/torque against the native
## caps, attach displacement, contact gap, landing impact and absorb, timing.
## Works against both the original and the rebuilt head_leap controller.
const GRAVITY := 9.8
const FORCE_CAP := 2.0 * GRAVITY
const ANGULAR_CAP := 24.0
const Motion := preload("res://harness/scripts/head_leap_motion.gd")

var crew: Array = []
var part: RigidBody3D
var t := 0.0
var events: Dictionary = {}
var _state: Array[String] = []
var _prev_v: Array[Vector3] = []
var _prev_w: Array[Vector3] = []
var _prev_state: Array[String] = []
var _impulse_tick: Array[bool] = []
var _home_com: Array[Vector3] = []
var _home_root_y: Array[float] = []
var _home_origin_y: Array[float] = []
var _launch_com: Array[Vector3] = []
var _contact_basis: Array[Basis] = []
var _start_basis: Array[Basis] = []
var m: Array[Dictionary] = []
var part_before_tick := Transform3D.IDENTITY
var attach: Dictionary = {}
var _last_part := Transform3D.IDENTITY
var _last_knee: Array = []
var _last_ankle: Array = []
var continuity := {"knee_step_deg":0.0,"ankle_step_deg":0.0,"boundary":{}}
# Per-tick trace rows (all members) for the derived motion metrics and plots.
var rows: Array = []
var trace_path := ""
var _start_cube: Array[Basis] = []

func watch(members: Array, source: RigidBody3D) -> void:
	crew = members
	part = source
	for index in crew.size():
		_state.append("")
		_prev_v.append(Vector3.ZERO)
		_prev_w.append(Vector3.ZERO)
		_prev_state.append("")
		_impulse_tick.append(false)
		_home_com.append(Vector3.ZERO)
		_home_root_y.append(0.0)
		_home_origin_y.append(0.0)
		_launch_com.append(Vector3.ZERO)
		_contact_basis.append(Basis.IDENTITY)
		_start_basis.append(Basis.IDENTITY)
		_start_cube.append(Basis.IDENTITY)
		m.append({"rotation_out_deg":0.0,"rotation_return_deg":0.0,"net_out_deg":0.0,"net_return_deg":0.0,
			"max_knee_flexion_deg":0.0,"max_knee_flexion_out_deg":0.0,"max_knee_flexion_return_deg":0.0,
			"apex_out_m":-INF,"apex_return_m":-INF,"peak_assist_ms2":0.0,"peak_assist_N":0.0,"assist_cap_N":0.0,
			"peak_alpha":0.0,"peak_omega":0.0,"launch_speed":0.0,"launch_omega":0.0,"return_launch_speed":0.0,
			"touchdown_vy":0.0,"body_dip_m":0.0,"root_dip_m":0.0,"upside_down_err_deg":-1.0,
			"low_assist_frac_return":0.0,"_return_ticks":0,"_low_ticks":0,"max_tilt_deg":0.0})

func mark(name: String) -> void:
	if not events.has(name): events[name] = snappedf(t, .0001)

func record_attach(info: Dictionary) -> void:
	attach = info

var _toss_state := ""
var _toss_local := Transform3D.IDENTITY
var toss: Dictionary = {}

func _observe_toss() -> void:
	# Custody snap at the head catch: pose of the same body one tick after
	# custody versus its catch-time pose carried rigidly by the head anchor.
	if crew.is_empty() or not is_instance_valid(crew[0]) or not is_instance_valid(part): return
	var w: RigidBody3D = crew[0]
	var state: String = w.pickup.state
	if state == "caught" and _toss_state == "flight":
		_toss_local = w.head_anchor.global_transform.affine_inverse()*part.global_transform
		toss.catch_t = t
		toss.catch_gap_offset = (w.head_anchor.global_transform.affine_inverse()*part.global_position)
	elif state == "caught" and _toss_state == "caught" and not toss.has("catch_snap_mm"):
		var rigid: Transform3D = w.head_anchor.global_transform*_toss_local
		toss.catch_snap_mm = rigid.origin.distance_to(part.global_position)*1000.0
		toss.catch_snap_deg = rad_to_deg(rigid.basis.get_rotation_quaternion().angle_to(part.global_basis.orthonormalized().get_rotation_quaternion()))
	if state == "flight":
		var head: Vector3 = w.pickup._head_point()
		toss.apex_above_head = maxf(float(toss.get("apex_above_head",-INF)), part.global_position.y-head.y)
		toss.flight_s = w.pickup._flight_clock
	_toss_state = state

func _physics_process(delta: float) -> void:
	t += delta
	_observe_toss()
	if is_instance_valid(part): _last_part = part.global_transform
	# Rigid custody after the helpers publish: the same source sits at its
	# attach-time pose in the evaluated head contact frame (no slip/snap).
	if not crew.is_empty() and is_instance_valid(crew[0]) and is_instance_valid(part) and part.carrier == crew[0].head_anchor and crew[0].head_leap.contacted and crew[0].head_leap.active():
		var local: Transform3D = crew[0].head_leap.contact_frame().affine_inverse()*part.global_transform
		attach["max_cargo_drift_mm"] = maxf(float(attach.get("max_cargo_drift_mm",0.0)), local.origin.distance_to(part.carried_local_transform().origin)*1000.0)
	for index in crew.size():
		if not is_instance_valid(crew[index]): continue
		var w: RigidBody3D = crew[index]
		var leap: RefCounted = w.head_leap
		var state: String = leap.state
		var direct := PhysicsServer3D.body_get_direct_state(w.get_rid())
		var v: Vector3 = direct.linear_velocity if direct else w.linear_velocity
		var omega: Vector3 = direct.angular_velocity if direct else w.angular_velocity
		var com: Vector3 = w.global_transform*(direct.center_of_mass_local if direct else Vector3.ZERO)
		var row: Dictionary = m[index]
		var changed := state != _prev_state[index]
		if changed:
			var key := "%d:%s" % [index, state]
			if index == 0: mark(state)
			events[key] = snappedf(t, .0001)
			if state == "prepare":
				_home_com[index] = com
				_start_basis[index] = w.global_basis
				_start_cube[index] = w._pose.evaluated_root.basis.orthonormalized()
				var root: Transform3D = w._pose.evaluated_root
				_home_root_y[index] = root.origin.y
				_home_origin_y[index] = w.global_position.y
			if state == "outbound":
				_launch_com[index] = com
			if state == "contact": _contact_basis[index] = w.global_basis
			if state == "return":
				_contact_basis[index] = w.global_basis
				row.net_out_deg = rad_to_deg(_start_basis[index].get_rotation_quaternion().angle_to(w.global_basis.get_rotation_quaternion()))
				row.upside_down_err_deg = rad_to_deg(acos(clampf(w.global_basis.y.normalized().dot(Vector3.DOWN), -1.0, 1.0)))
			if state == "landing":
				row.touchdown_vy = v.y
				row.net_return_deg = rad_to_deg(_contact_basis[index].get_rotation_quaternion().angle_to(w.global_basis.get_rotation_quaternion()))
		# Native launch/attach impulses are one-tick events, not sustained assist.
		var skip := changed or _prev_state[index] != state or _impulse_tick[index]
		_impulse_tick[index] = changed and state in ["outbound","return"]
		var airborne := state in ["outbound","contact","return"]
		if airborne and not skip:
			var acceleration := (v-_prev_v[index])/delta
			var assist := (acceleration+Vector3.UP*GRAVITY).length()
			row.peak_assist_ms2 = maxf(row.peak_assist_ms2, assist)
			row.peak_assist_N = maxf(row.peak_assist_N, assist*w.mass)
			row.assist_cap_N = FORCE_CAP*w.mass
			row.peak_alpha = maxf(row.peak_alpha, ((omega-_prev_w[index])/delta).length())
			if state == "return":
				row._return_ticks += 1
				if assist < .3*GRAVITY: row._low_ticks += 1
		if airborne and direct and not row.has("inertia"):
			# Jolt's actual world inertia of the flight body (swapped torso box +
			# custom COM) against the controller's original I = .12 m estimate.
			var inverse: Basis = direct.inverse_inertia_tensor
			if absf(inverse.determinant()) > 1e-12:
				var inertia := inverse.inverse()
				var local := w.global_basis.inverse()*inertia*w.global_basis
				row.inertia = {"mass":w.mass,"Ixx":local.x.x,"Iyy":local.y.y,"Izz":local.z.z,
					"per_mass":[local.x.x/w.mass,local.y.y/w.mass,local.z.z/w.mass],"estimate":.12*w.mass,
					"com_local":direct.center_of_mass_local,"state":state}
		if state == "return" and direct and not row.has("inertia_loaded"):
			var inverse_loaded: Basis = direct.inverse_inertia_tensor
			if absf(inverse_loaded.determinant()) > 1e-12:
				var loaded := w.global_basis.inverse()*inverse_loaded.inverse()*w.global_basis
				row.inertia_loaded = {"mass":w.mass,"diag":[loaded.x.x,loaded.y.y,loaded.z.z],"estimate":.12*w.mass,"com_local":direct.center_of_mass_local}
		if changed and state == "outbound":
			row.launch_speed = v.length()
			row.launch_omega = omega.length()
		if changed and state == "return": row.return_launch_speed = v.length()
		if airborne: row.peak_omega = maxf(row.peak_omega, omega.length())
		if state in ["outbound","contact"]:
			row.rotation_out_deg += rad_to_deg(omega.length()*delta)
			row.apex_out_m = maxf(row.apex_out_m, com.y-_launch_com[index].y)
		if state == "return":
			row.rotation_return_deg += rad_to_deg(omega.length()*delta)
			row.apex_return_m = maxf(row.apex_return_m, com.y-_home_com[index].y)
		if state in ["landing","done"] and events.has("%d:landing" % index) and t-float(events["%d:landing" % index]) < 1.2:
			row.body_dip_m = maxf(row.body_dip_m, _home_origin_y[index]-w.global_position.y)
			var root: Transform3D = w.global_transform*w._pose.evaluated_worker.affine_inverse()*w._pose.evaluated_root
			row.root_dip_m = maxf(row.root_dip_m, _home_root_y[index]-root.origin.y)
		if state in ["landing","done"]:
			row.max_tilt_deg = maxf(row.max_tilt_deg, rad_to_deg(acos(clampf(w.global_basis.y.normalized().dot(Vector3.UP),-1.0,1.0))))
		if state in ["prepare","outbound","contact","return","landing"] and w._pose.evaluated_valid:
			# Per-tick WORLD knee-plane/ankle steps (gait thresholds 12 / 18 deg),
			# including the prepare->outbound, contact->return, air->ground handoffs.
			while _last_knee.size() < (index+1)*2:
				_last_knee.append(null)
				_last_ankle.append(null)
			for side in 2:
				var thigh: Vector3 = (w._pose.evaluated_knees[side]-w._pose.evaluated_hips[side]).normalized()
				var foot: Quaternion = w._pose.evaluated_ankles[side].orthonormalized().get_rotation_quaternion()
				var slot := index*2+side
				if _last_knee[slot] != null:
					var knee_step := rad_to_deg(thigh.angle_to(_last_knee[slot]))
					var ankle_step := rad_to_deg(foot.angle_to(_last_ankle[slot]))
					if knee_step > continuity.knee_step_deg: continuity.knee_step_at = "%s %.3f" % [state, leap.elapsed]
					if ankle_step > continuity.ankle_step_deg: continuity.ankle_step_at = "%s %.3f" % [state, leap.elapsed]
					continuity.knee_step_deg = maxf(continuity.knee_step_deg, knee_step)
					continuity.ankle_step_deg = maxf(continuity.ankle_step_deg, ankle_step)
					if changed:
						var key := _prev_state[index]+">"+state
						var row_b: Dictionary = continuity.boundary.get(key, {"knee":0.0,"ankle":0.0})
						row_b.knee = maxf(row_b.knee, knee_step)
						row_b.ankle = maxf(row_b.ankle, ankle_step)
						continuity.boundary[key] = row_b
				_last_knee[slot] = thigh
				_last_ankle[slot] = foot
		if airborne and w._pose.evaluated_valid:
			for side in 2:
				var hip: Vector3 = w._pose.evaluated_hips[side]
				var knee: Vector3 = w._pose.evaluated_knees[side]
				var ankle: Vector3 = w._pose.evaluated_soles[side]-w._pose.evaluated_ankles[side]*Vector3(0,w._pose._ankle_height[side],0)
				var flex := rad_to_deg((knee-hip).angle_to(ankle-knee))
				row.max_knee_flexion_deg = maxf(row.max_knee_flexion_deg, flex)
				if state == "return": row.max_knee_flexion_return_deg = maxf(row.max_knee_flexion_return_deg, flex)
				else: row.max_knee_flexion_out_deg = maxf(row.max_knee_flexion_out_deg, flex)
		if state in ["prepare","outbound","contact","return","landing"] or (state in ["done","failed"] and t-float(events.get("%d:%s" % [index,state],t)) < .6):
			rows.append(_row(index, w, leap, state, v, omega, com, delta))
		_prev_v[index] = v
		_prev_w[index] = omega
		_prev_state[index] = state

func _row(index: int, w: RigidBody3D, leap: RefCounted, state: String, v: Vector3, omega: Vector3, com: Vector3, delta: float) -> Dictionary:
	var pose = w._pose
	var cube: Transform3D = w.global_transform*pose.evaluated_worker.affine_inverse()*pose.evaluated_root if pose.evaluated_valid else w.global_transform
	var up := cube.basis.y.normalized()
	var axis: Vector3 = leap._outbound_axis.normalized()
	# Signed visual cube rotation about the flip axis since the start of prepare.
	var relative: Basis = cube.basis.orthonormalized()*_start_cube[index].inverse()
	var q := relative.get_rotation_quaternion()
	var turn := 2.0*atan2(Vector3(q.x,q.y,q.z).dot(axis),q.w)
	var face: Vector3 = (cube.basis*leap._face_root()).normalized() if leap._hip_root.size()==2 else -w._model.global_basis.z
	var down := -up
	var knees := []
	var hips := []
	var points := []
	var reach := 0.0
	var lowest := INF
	for side in 2:
		var hip: Vector3 = pose.evaluated_hips[side]
		var knee: Vector3 = pose.evaluated_knees[side]
		var ankle: Vector3 = pose.evaluated_soles[side]-pose.evaluated_ankles[side]*Vector3(0,pose._ankle_height[side],0)
		var thigh := (knee-hip).normalized()
		var shin := (ankle-knee).normalized()
		knees.append(rad_to_deg(thigh.angle_to(shin)))
		hips.append(rad_to_deg(atan2(thigh.dot(face),thigh.dot(down))))
		var sole_down: Vector3 = (pose.evaluated_ankles[side]*Vector3.UP).normalized()
		# Foot pitch against the ground (0 = flat sole, >0 = heel lifted/pointed).
		points.append(rad_to_deg(sole_down.angle_to(Vector3.DOWN)))
		reach = maxf(reach,maxf((knee-com).length(),(pose.evaluated_soles[side]-com).length()))
		lowest = minf(lowest,pose.evaluated_soles[side].y)
		# The evaluated toe joint (skeleton reads between modifiers are stale).
		if side < leap._toe_ankle.size(): lowest = minf(lowest,(ankle+pose.evaluated_ankles[side]*leap._toe_ankle[side]).y)
	var gap := INF
	if is_instance_valid(part) and not leap.contacted:
		gap = (cube*leap._head_touch_local-(part.global_transform*leap.contact_local)).dot(leap.contact_normal)
	var gaze: Variant = leap.gaze_target()
	return {"i":index,"t":snappedf(t,.0001),"st":state,"el":snappedf(leap.elapsed,.0001),
		"com":[com.x,com.y,com.z],"v":[v.x,v.y,v.z],"w":omega.length(),"wa":omega.dot(axis),
		"pitch":rad_to_deg(acos(clampf(up.dot(Vector3.UP),-1.0,1.0))),"turn":rad_to_deg(turn),
		"body_pitch":rad_to_deg(acos(clampf(w.global_basis.y.normalized().dot(Vector3.UP),-1.0,1.0))),
		"knee":knees,"hip":hips,"point":points,"reach":reach,"root":[cube.origin.x,cube.origin.y,cube.origin.z],
		"low":lowest,"gap":gap if is_finite(gap) else null,"ground":w.on_ground,
		"part":[part.global_position.x,part.global_position.y,part.global_position.z] if is_instance_valid(part) else null,
		"gaze":[gaze.x,gaze.y,gaze.z] if gaze is Vector3 else null}

func report(extra: Dictionary = {}) -> Dictionary:
	var out := {"events":events,"attach":attach,"toss_probe":toss,"continuity":continuity}
	var member_rows: Array = []
	for index in m.size():
		var row: Dictionary = m[index].duplicate()
		var ticks: int = row._return_ticks
		row.low_assist_frac_return = float(row._low_ticks)/float(ticks) if ticks > 0 else 0.0
		row.erase("_return_ticks")
		row.erase("_low_ticks")
		for key: String in row.keys():
			if row[key] is float: row[key] = snappedf(row[key], .001) if is_finite(row[key]) else null
		var e := func(name: String) -> float: return float(events.get("%d:%s" % [index, name], -1.0))
		var begin: float = e.call("prepare")
		var launch: float = e.call("outbound")
		var contact: float = e.call("contact")
		var ret: float = e.call("return")
		var land: float = e.call("landing")
		var finish: float = maxf(e.call("done"), e.call("failed"))
		row.gather_s = snappedf(launch-begin, .001) if launch > 0 and begin >= 0 else null
		row.outbound_s = snappedf(contact-launch, .001) if contact > 0 and launch > 0 else null
		row.contact_dwell_s = snappedf(ret-contact, .001) if ret > 0 and contact > 0 else null
		row.return_s = snappedf(land-ret, .001) if land > 0 and ret > 0 else null
		row.landing_settle_s = snappedf(finish-land, .001) if finish > 0 and land > 0 else null
		row.total_pickup_s = snappedf(finish-begin, .001) if finish > 0 and begin >= 0 else null
		row.outcome = crew[index].head_leap.state if is_instance_valid(crew[index]) else "freed"
		row.reason = crew[index].head_leap.reason if is_instance_valid(crew[index]) else ""
		var leap: RefCounted = crew[index].head_leap if is_instance_valid(crew[index]) else null
		if leap and "flight_stats" in leap: row.controller = leap.flight_stats
		member_rows.append(row)
	out.members = member_rows
	# Heavy/shared loads touch down slower: the free-fall tail is 0.15 s.
	var heavy: bool = crew.size() > 1 or (is_instance_valid(crew[0]) and not crew[0].head_leap._small_stock_timing())
	out.motion = Motion.summarize(self.rows, crew.size(), .15 if heavy else .18)
	if not trace_path.is_empty():
		var file := FileAccess.open(trace_path, FileAccess.WRITE)
		if file:
			for row: Dictionary in self.rows: file.store_line(JSON.stringify(row))
	out.merge(extra, true)
	return out

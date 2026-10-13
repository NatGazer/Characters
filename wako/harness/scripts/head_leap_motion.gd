extends RefCounted
## Derived motion metrics of a head-first flip from the probe's per-tick rows:
## how the centre of mass falls, how long the cube hangs inverted or slow,
## spin coast/brake, tuck shape, push-off, contact beats, return descent and the
## landing absorb. Harness-only; reads rows, never the controllers.
const G := 9.8

static func summarize(rows: Array, members: int, tail := .18) -> Array:
	var result: Array = []
	for index in members:
		var mine: Array = rows.filter(func(row: Dictionary) -> bool: return int(row.i) == index)
		result.append(_member(mine, tail))
	return result

static func _vec(value: Variant) -> Vector3:
	return Vector3(value[0], value[1], value[2]) if value is Array and value.size() == 3 else Vector3.ZERO

static func _member(rows: Array, tail: float) -> Dictionary:
	var out := {}
	if rows.size() < 3: return out
	var by_state := func(name: String) -> Array: return rows.filter(func(row: Dictionary) -> bool: return row.st == name)
	var prepare: Array = by_state.call("prepare")
	var outbound: Array = by_state.call("outbound")
	var contact: Array = by_state.call("contact")
	var back: Array = by_state.call("return")
	var landing: Array = by_state.call("landing")
	if prepare.is_empty() or outbound.is_empty(): return out
	var dt := 1.0/120.0
	var home_com := _vec(prepare[0].com)
	var rest_root_y: float = _vec(prepare[0].root).y
	var ground: float = prepare[0].low
	# ---- push-off ----------------------------------------------------------
	var launch: Dictionary = outbound[0]
	var lowest_root := INF
	var lowest_at := 0.0
	for row: Dictionary in prepare:
		if _vec(row.root).y < lowest_root:
			lowest_root = _vec(row.root).y
			lowest_at = row.t
	var crouch_depth := rest_root_y - lowest_root
	var deep_from := INF
	for row: Dictionary in prepare:
		if rest_root_y - _vec(row.root).y >= crouch_depth*.9:
			deep_from = minf(deep_from, float(row.t))
	# Pose fields lag physics by one tick in these rows: outbound[1] carries
	# the launch-tick evaluation (the push-off fully extended).
	var last_prepare: Dictionary = outbound[1] if outbound.size() > 1 else outbound[0]
	var pre_rate := 0.0
	if prepare.size() >= 2:
		var before: Dictionary = prepare[prepare.size()-2]
		pre_rate = deg_to_rad(float(last_prepare.turn) - float(before.turn))/(float(last_prepare.t) - float(before.t))
	# Balls of the feet stay planted (toe joints within 3 mm of where the
	# push-off started) for this many ticks after the launch tick.
	var pinned := 0
	var max_extension := {"knee": 180.0, "heel": 0.0, "root": -INF}
	var planted: Array = prepare[prepare.size()-1].get("toes", [])
	for index in range(2, outbound.size()):
		var row: Dictionary = outbound[index]
		var toes: Array = row.get("toes", [])
		var still := toes.size() == 2 and planted.size() == 2
		for side in 2:
			if still and _vec(toes[side]).distance_to(_vec(planted[side])) > .003: still = false
		if still:
			pinned += 1
			max_extension.knee = minf(max_extension.knee, maxf(float(row.knee[0]), float(row.knee[1])))
			max_extension.heel = maxf(max_extension.heel, minf(float(row.point[0]), float(row.point[1])))
			max_extension.root = maxf(max_extension.root, _vec(row.root).y - rest_root_y)
		else: break
	out.push = {"gather_s": float(launch.t) - float(prepare[0].t), "crouch_depth_m": crouch_depth,
		"deep_hold_s": float(launch.t) - deep_from if is_finite(deep_from) else null,
		"root_above_rest_at_launch_m": _vec(last_prepare.root).y - rest_root_y,
		"knee_at_launch_deg": maxf(float(last_prepare.knee[0]), float(last_prepare.knee[1])),
		"heel_lift_at_launch_deg": minf(float(last_prepare.point[0]), float(last_prepare.point[1])),
		"lean_at_launch_deg": float(last_prepare.turn), "preroll_rate_at_launch": pre_rate,
		"toes_pinned_ticks_after_launch": pinned, "pinned_min_knee_deg": max_extension.knee, "pinned_max_heel_lift_deg": max_extension.heel,
		"pinned_max_root_above_rest_m": max_extension.root, "launch_spin": float(launch.w)}
	# ---- outbound descent ------------------------------------------------
	var apex_t := float(outbound[0].t)
	var apex_y := -INF
	var peak_fall := 0.0
	var peak_fall_t := apex_t
	for row: Dictionary in outbound:
		var com := _vec(row.com)
		if com.y > apex_y:
			apex_y = com.y
			apex_t = row.t
	for row: Dictionary in outbound:
		var fall := -_vec(row.v).y
		if float(row.t) >= apex_t and fall > peak_fall:
			peak_fall = fall
			peak_fall_t = row.t
	var contact_com: Vector3 = _vec(contact[0].com) if not contact.is_empty() else _vec(outbound[outbound.size()-1].com)
	var before_return: Array = outbound + contact
	var inverted := 0.0
	var slow := 0.0
	var first_inverted := INF
	for row: Dictionary in before_return:
		if float(row.pitch) > 170.0:
			inverted += dt
			first_inverted = minf(first_inverted, float(row.t))
		if float(row.t) > apex_t and _vec(row.v).length() < .5: slow += dt
	var contact_t: float = contact[0].t if not contact.is_empty() else float(outbound[outbound.size()-1].t)
	var final_pitch: float = contact[0].pitch if not contact.is_empty() else 180.0
	var turned_at := INF
	for row: Dictionary in outbound:
		if float(row.pitch) >= final_pitch - 2.0:
			turned_at = row.t
			break
	# spin coast and brake window (body angular rate about the flip axis)
	var coast := INF
	var coast_peak := 0.0
	for row: Dictionary in outbound:
		var rate := absf(float(row.wa))
		coast_peak = maxf(coast_peak, rate)
	var brake_start := INF
	var brake_end := INF
	var pitch_at_brake := 0.0
	var coast_sum := 0.0
	var coast_count := 0
	for row: Dictionary in outbound:
		var rate := absf(float(row.wa))
		if not is_finite(brake_start) and float(row.t) > float(outbound[0].t) + .05 and rate < coast_peak*.97:
			brake_start = row.t
			pitch_at_brake = row.pitch
		if not is_finite(brake_start) and float(row.t) > float(outbound[0].t) + .05:
			coast_sum += rate
			coast_count += 1
		if is_finite(brake_start) and not is_finite(brake_end) and rate < .05*coast_peak: brake_end = row.t
	if coast_count > 0: coast = coast_sum/coast_count
	# tuck
	var tuck_knee := 0.0
	var tuck_hip := 0.0
	var tuck_reach := INF
	for row: Dictionary in outbound:
		var knee := maxf(float(row.knee[0]), float(row.knee[1]))
		if knee > tuck_knee:
			tuck_knee = knee
			tuck_hip = maxf(float(row.hip[0]), float(row.hip[1]))
			tuck_reach = row.reach
	var knee_out_end: float = maxf(float(outbound[outbound.size()-1].knee[0]), float(outbound[outbound.size()-1].knee[1]))
	var whip := 0.0
	if is_finite(brake_start):
		var min_after_open := INF
		for row: Dictionary in outbound:
			if float(row.t) > brake_start + .08:
				var knee := maxf(float(row.knee[0]), float(row.knee[1]))
				min_after_open = minf(min_after_open, knee)
				whip = maxf(whip, knee - min_after_open)
	out.outbound = {"seconds": contact_t - float(outbound[0].t), "apex_above_launch_com_m": apex_y - _vec(outbound[0].com).y,
		"peak_fall_speed": peak_fall, "fall_g": (peak_fall/maxf(peak_fall_t - apex_t, .001))/G if peak_fall_t > apex_t else null,
		"fall_from_apex_s": peak_fall_t - apex_t, "inverted_over_170_before_return_s": inverted, "slow_under_05_before_return_s": slow,
		"half_turn_done_before_contact_s": contact_t - turned_at if is_finite(turned_at) else null,
		"pitch_at_contact_deg": final_pitch, "spin_coast_rad_s": coast if is_finite(coast) else coast_peak,
		"spin_brake_window_s": brake_end - brake_start if is_finite(brake_end) and is_finite(brake_start) else null,
		"spin_brake_starts_at_pitch_deg": pitch_at_brake,
		"tuck_knee_deg": tuck_knee, "tuck_hip_deg": tuck_hip, "tuck_reach_m": tuck_reach,
		"knee_at_contact_deg": knee_out_end, "brake_whip_knee_deg": whip}
	# ---- contact beat -----------------------------------------------------
	if not contact.is_empty():
		var reload := 0.0
		for row: Dictionary in contact: reload = maxf(reload, maxf(float(row.knee[0]), float(row.knee[1])))
		out.contact = {"dwell_s": contact.size()*dt, "knee_at_touch_deg": maxf(float(contact[0].knee[0]), float(contact[0].knee[1])),
			"knee_reloaded_deg": reload}
	# ---- return --------------------------------------------------------------
	if not back.is_empty():
		var kick := INF
		for row: Dictionary in back:
			if float(row.el) < .12: kick = minf(kick, maxf(float(row.knee[0]), float(row.knee[1])))
		var top := -INF
		var top_t := 0.0
		for row: Dictionary in back:
			if _vec(row.com).y > top:
				top = _vec(row.com).y
				top_t = row.t
		var touch: Dictionary = landing[0] if not landing.is_empty() else back[back.size()-1]
		var touch_t: float = touch.t
		var tail_assist := 0.0
		var tail_horizontal := 0.0
		var previous: Dictionary = {}
		for row: Dictionary in back:
			if not previous.is_empty():
				var a := (_vec(row.v) - _vec(previous.v))/(float(row.t) - float(previous.t))
				if touch_t - float(row.t) <= tail + .0001: tail_assist = maxf(tail_assist, (a + Vector3.UP*G).length())
				if touch_t - float(row.t) <= .30 + .0001: tail_horizontal = maxf(tail_horizontal, Vector2(a.x, a.z).length())
			previous = row
		var touch_v := _vec(back[back.size()-1].v)
		# The loaded COM (cargo share included) above its own touchdown COM;
		# apex_above_home_com_m compares it with the bare standing COM.
		out["return"] = {"seconds": touch_t - float(back[0].t), "kick_knee_deg": kick, "apex_above_home_com_m": top - home_com.y,
			"apex_above_touchdown_com_m": top - _vec(touch.com).y,
			"descent_g": (absf(touch_v.y)/maxf(touch_t - top_t, .001))/G, "descent_s": touch_t - top_t,
			"tail_window_s": tail, "tail_peak_assist": tail_assist, "last_03_s_peak_horizontal_accel": tail_horizontal,
			"touchdown_vertical": touch_v.y, "touchdown_horizontal": Vector2(touch_v.x, touch_v.z).length()}
	# ---- landing absorb ---------------------------------------------------
	var impact: Array = landing.filter(func(row: Dictionary) -> bool: return row.ground)
	if impact.size() > 3:
		var t0: float = impact[0].t
		var y0: float = _vec(impact[0].root).y
		var low_y := y0
		var rise := 0.0
		var max_dv := 0.0
		var knee_drop := 0.0
		var max_knee := -INF
		var bottom_t := t0
		var previous_speed := INF
		var previous_y := y0
		var previous_t := t0
		for row: Dictionary in impact:
			var y := _vec(row.root).y
			var age := float(row.t) - t0
			if age <= .10 + .0001:
				rise = maxf(rise, y - low_y)
				var knee := maxf(float(row.knee[0]), float(row.knee[1]))
				if knee > max_knee: max_knee = knee
				knee_drop = maxf(knee_drop, max_knee - knee)
			if age <= .12 + .0001 and float(row.t) > previous_t:
				var speed := (y - previous_y)/(float(row.t) - previous_t)
				if is_finite(previous_speed): max_dv = maxf(max_dv, absf(speed - previous_speed))
				previous_speed = speed
			if y < low_y:
				low_y = y
				bottom_t = row.t
			previous_y = y
			previous_t = row.t
		out.landing = {"absorb_root_drop_m": rest_root_y - low_y, "drop_from_impact_m": y0 - low_y, "bottom_after_impact_s": bottom_t - t0,
			"root_rise_first_010_s_m": rise, "max_root_speed_change_per_tick_first_012_s": max_dv,
			"knee_unbend_first_010_s_deg": knee_drop, "knee_at_impact_deg": maxf(float(impact[0].knee[0]), float(impact[0].knee[1]))}
	out.gates = _gates(rows, prepare, outbound, contact, back, landing)
	return out

static func _accel(a: Dictionary, b: Dictionary) -> Vector3:
	return (_vec(b.v) - _vec(a.v))/maxf(float(b.t) - float(a.t), .0001)

static func _gates(rows: Array, prepare: Array, outbound: Array, contact: Array, back: Array, landing: Array) -> Dictionary:
	# The critic's numeric gates for a convincing flip, per member.
	var g := {}
	# Push-off: the visual root's motion over the last 0.07 s of the planted
	# drive against the flight's launch velocity; the ball-to-hip line.
	if prepare.size() > 9 and outbound.size() > 2:
		var launch := _vec(outbound[1].v)
		var worst_dir := 0.0
		var worst_root_step := 0.0
		var previous_speed := Vector3.INF
		var tail: Array = prepare.slice(prepare.size() - 9) + outbound.slice(0, 3)
		for index in range(1, tail.size()):
			var a: Dictionary = tail[index - 1]
			var b: Dictionary = tail[index]
			var root_v := (_vec(b.root) - _vec(a.root))/maxf(float(b.t) - float(a.t), .0001)
			if index < 9 and root_v.length() > .3: worst_dir = maxf(worst_dir, rad_to_deg(root_v.angle_to(launch)))
			if previous_speed.is_finite(): worst_root_step = maxf(worst_root_step, root_v.distance_to(previous_speed))
			previous_speed = root_v
		var release: Dictionary = outbound[0]
		var toes: Array = prepare[prepare.size() - 1].get("toes", [])
		var line_deg = null
		if toes.size() == 2 and release.has("hipmid"):
			var ball := (_vec(toes[0]) + _vec(toes[1]))*.5
			line_deg = rad_to_deg((_vec(release.hipmid) - ball).angle_to(launch))
		g.push = {"root_direction_vs_launch_deg_last_007s": worst_dir, "root_speed_step_max": worst_root_step,
			"body_pitch_at_release_deg": release.body_pitch, "toe_hip_line_vs_launch_deg": line_deg,
			"launch_speed": launch.length(), "launch_elevation_deg": rad_to_deg(atan2(launch.y, Vector2(launch.x, launch.z).length()))}
	# Outbound arrival: assisted vs free fall, the impact and the stop.
	if outbound.size() > 4:
		var last_assisted_gap = null
		var assisted := 0.0
		var peak_assist := 0.0
		for index in range(1, outbound.size()):
			var a := _accel(outbound[index - 1], outbound[index])
			var assist := (a + Vector3.UP*G).length()
			if float(outbound[index].el) > .05:
				peak_assist = maxf(peak_assist, assist)
				if assist > 1.5:
					assisted += float(outbound[index].t) - float(outbound[index - 1].t)
					last_assisted_gap = outbound[index].gap
		var approach := 0.0
		for row: Dictionary in outbound.slice(maxi(outbound.size() - 4, 0)) + contact.slice(0, 2):
			approach = maxf(approach, -_vec(row.v).y)
		var stop_ticks := 0
		var stop_dv := 0.0
		var chain: Array = outbound.slice(maxi(outbound.size() - 3, 0)) + contact
		for index in range(1, chain.size()):
			var dv := _vec(chain[index].v).distance_to(_vec(chain[index - 1].v))
			stop_dv = maxf(stop_dv, dv)
			if -_vec(chain[index].v).y > .1 and -_vec(chain[index - 1].v).y > .1: stop_ticks += 1
		var squash := 0.0
		for row: Dictionary in contact + back.slice(0, mini(back.size(), 30)): squash = maxf(squash, float(row.get("squash", 0.0)))
		g.arrival = {"seconds_with_assist_over_15": assisted, "gap_after_last_assist_m": last_assisted_gap, "flight_peak_assist": peak_assist,
			"impact_speed": approach, "impact_max_speed_change_per_tick": stop_dv, "squash_peak_m": squash}
	# The inverted and slow windows from the impact through the return push.
	var inverted := 0.0
	var slow := 0.0
	var window: Array = outbound.slice(outbound.size()/2) + contact + back.slice(0, mini(back.size(), 40))
	for index in range(1, window.size()):
		var dt := float(window[index].t) - float(window[index - 1].t)
		if float(window[index].pitch) > 170.0: inverted += dt
		if _vec(window[index].v).length() < .3: slow += dt
	g.window = {"inverted_over_170_s": inverted, "speed_under_03_s": slow}
	# Return push-off and flight.
	if back.size() > 20:
		var takeoff_speed := 0.0
		for row: Dictionary in back.slice(0, 60): takeoff_speed = maxf(takeoff_speed, _vec(row.v).length())
		var worst_dv := 0.0
		var knee_at_speed = null
		var push_ticks := 0
		for index in range(1, mini(back.size(), 60)):
			var dv := _vec(back[index].v).distance_to(_vec(back[index - 1].v))
			worst_dv = maxf(worst_dv, dv)
			# Ticks of the push itself: the speed grows (a ballistic rise slows).
			if _vec(back[index].v).length() - _vec(back[index - 1].v).length() > .05: push_ticks += 1
			if knee_at_speed == null and _vec(back[index].v).length() >= .95*takeoff_speed: knee_at_speed = maxf(float(back[index].knee[0]), float(back[index].knee[1]))
		var top_index := 0
		for index in back.size():
			if _vec(back[index].v).length() >= .95*takeoff_speed:
				top_index = index
				break
		var h_assist := 0.0
		var v_assist := 0.0
		for index in range(top_index + 3, back.size()):
			var a := _accel(back[index - 1], back[index])
			h_assist = maxf(h_assist, Vector2(a.x, a.z).length())
			v_assist = maxf(v_assist, absf(a.y + G))
		var launch := _vec(back[mini(top_index + 1, back.size() - 1)].v)
		g.return_launch = {"speed": launch.length(), "elevation_deg": rad_to_deg(atan2(launch.y, Vector2(launch.x, launch.z).length())),
			"max_speed_change_per_tick": worst_dv, "push_ticks": push_ticks, "knee_at_takeoff_speed_deg": knee_at_speed,
			"flight_peak_horizontal_accel": h_assist, "flight_peak_vertical_assist": v_assist}
	return g

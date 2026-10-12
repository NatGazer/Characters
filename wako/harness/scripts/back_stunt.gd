extends "res://harness/scripts/stage.gd"
## Focused back-tool stunt scene and metrics probe.
## Wako holds a real catalogue tool (same Part body as play) on its toe,
## stows it on its back, then retrieves it for a foot action. Works against
## both the legacy hop and the new upward stunt; new diagnostics are read
## only when the BackTool exposes them.
## User args (after `--`):
##   --tool=assembly_tool|salvage_tool   --side=0|1   --walk
##   --interrupt=gather|kick|rising|apex|falling|settle|reach|draw|home
##   --ceiling=<y>        static slab above the Wako (blocked arc)
##   --save=flight|prepare|back|retrieve    save + rebuild + restore at that moment
##   --cam=side|three|front   --quit (exit when the scenario completes)
const Part := preload("res://Components/Contraptions/contraption_part.gd")
const HolderVisual := preload("res://LogicObjects/Wako/wako_back_holder_visual.gd")

var wako: RigidBody3D
var tool: RigidBody3D
var target: RigidBody3D
var args := {}
var tool_kind := "assembly_tool"
var side := 0
var state := "settle"
var t_state := 0.0
var events: Array = []
var m := {}
var _id := 0
var _rid := RID()
var _prev_phase := ""
var _prev_stage := ""
var _prev_tool_pos := Vector3.INF
var _prev_tool_vel := Vector3.ZERO
var _prev_worker_vel := Vector3.ZERO
var _prev_worker_pos := Vector3.ZERO
var _t := {}
var _launch_pos := Vector3.ZERO
var _launch_tool := Vector3.ZERO
var _ground_y := 0.0
var _support_sole0 := Vector3.INF
var _interrupt_done := false
var _interrupt_t := -1.0
var _interrupt_tool_pos := Vector3.INF
var _save_done := false
var _done := false
var _impulse_ticks := {}
var _tick := 0
var _identity_ok := true
var _mass_ok := true
var _max_jump := 0.0
var _flight_samples := 0

func _arg(key: String, fallback: String) -> String:
	return str(args.get(key, fallback))

func setup() -> void:
	for raw: String in OS.get_cmdline_user_args():
		var item := raw.trim_prefix("--")
		var eq := item.find("=")
		if eq < 0: args[item] = "1"
		else: args[item.substr(0, eq)] = item.substr(eq + 1)
	tool_kind = _arg("tool", "assembly_tool")
	side = int(_arg("side", "0"))
	var id := ""
	for number in 200:
		id = "back_stunt_%d" % number
		if absi(id.hash()) % 2 == side: break
	wako = spawn_wako(Vector3(0, 1.0, 0), id)
	cam_follow = wako
	match _arg("cam", "three"):
		"side": cam_offset = Vector3(2.75, .9, -.2)
		"front": cam_offset = Vector3(.9, .75, -2.4)
		"back": cam_offset = Vector3(.6, .9, 2.45)
		_: cam_offset = Vector3(2.0, 1.0, 2.05)
	cam_lift = float(_arg("cam_lift", ".35"))
	cam_smooth = 2.5
	if args.has("ceiling"):
		var y := float(_arg("ceiling", "1.9"))
		add_box(Vector3(0, y + .05, 0), Vector3(3.0, .1, 3.0), Color(.55, .42, .32))
	target = Part.new()
	target.setup("bracket", "back_stunt_target", true)
	target.position = Vector3(0, .15, -1.0)
	add_child(target)
	m = {"tool": tool_kind, "side": side, "worker": id, "interrupt": _arg("interrupt", ""), "save": _arg("save", ""),
		"ceiling": float(_arg("ceiling", "0")) if args.has("ceiling") else 0.0}

func build_world() -> void:
	# Optional tilted ground (--slope=deg, rotation about X: facing up/down hill).
	var slope := 0.0
	for raw: String in OS.get_cmdline_user_args():
		if raw.begins_with("--slope="): slope = float(raw.trim_prefix("--slope="))
	add_box(Vector3(0, -0.5, 0), Vector3(60, 1, 60), Color(0.46, 0.5, 0.42), Vector3(slope, 0, 0))

func _equip() -> void:
	tool = Part.new()
	tool.setup(tool_kind, "back_stunt_" + tool_kind, true)
	tool.position = wako.global_position + Vector3(1.5, 0, 0)
	add_child(tool)
	tool.set_carried(wako.tool_anchor, Vector3.ZERO)
	tool.global_transform = wako.tool_anchor.global_transform
	tool.set_meta(&"equipped_worker", wako.worker_id)
	wako.set_equipped_tool(tool)
	_id = tool.get_instance_id()
	_rid = tool.get_rid()
	m.tool_mass = tool.mass
	m.instance = _id
	m.rid = str(_rid)

func _bt() -> RefCounted:
	return wako.back_tool if is_instance_valid(wako) else null

func _stage_name() -> String:
	var bt := _bt()
	if not bt: return ""
	if "stage" in bt: return str(bt.stage)
	return ""

func _event(label: String, extra := {}) -> void:
	var e := {"t": snappedf(clock, .0001), "event": label}
	e.merge(extra)
	events.append(e)
	print("BACK_STUNT_EVENT ", JSON.stringify(e))

func _seat_basis(bt: RefCounted) -> Basis:
	var b: Basis = bt._body_frame.basis
	var s: float = bt._side_sign
	if bt.has_method("seat_basis"): return bt.seat_basis()
	return Basis(b.y, -s * b.x, s * b.z).orthonormalized()

static func _turn(a: Basis, b: Basis) -> float:
	return a.get_rotation_quaternion().angle_to(b.get_rotation_quaternion())

func scenario(delta: float) -> void:
	_tick += 1
	t_state += delta
	if _done: return
	var bt := _bt()
	_observe(delta, bt)
	match state:
		"settle":
			caption("settle")
			if clock > 1.0:
				_equip()
				_go("hold")
		"hold":
			caption("%s on the %s toe" % [tool_kind, "left" if side == 0 else "right"])
			if t_state > 1.2:
				_t.request = clock
				bt._sync_root()
				var toe_body: Transform3D = bt._body_frame.affine_inverse() * bt._toe_for(tool.global_transform)
				var hip_body: Vector3 = bt._body_frame.affine_inverse() * wako.evaluated_hip(wako.tool_foot_side())
				_event("stow_request", {"toe_body": toe_body.origin, "toe_y": toe_body.basis.y, "toe_x": toe_body.basis.x, "hip_body": hip_body,
					"root_height": bt._root.origin.y - _ground_y})
				_go("stow")
		"stow":
			if not is_instance_valid(tool): return
			caption("stow: %s %s" % [bt.phase, _stage_name()])
			if bt.phase == "foot" and tool.carrier == wako.tool_anchor:
				if args.has("walk"): wako.navigate_to(wako.global_position + Vector3(0, 0, -4.0))
				else: bt.request_stow()
			if bt.phase == "back" and tool.carrier == bt.back_anchor and _t.has("catch") and clock - float(_t.catch) > .8 and not m.has("seated"):
				m.seated = _holder_metrics(bt)
			if bt.phase == "back" and tool.carrier == bt.back_anchor and _t.has("catch") and clock - float(_t.catch) > 1.2:
				if args.has("walk"):
					_go("walk_after")
				else:
					_go("retrieve")
			if t_state > 12.0: _finish("stow_timeout")
			if not wako.equipped_tool and _t.has("dropped") and clock - float(_t.dropped) > 2.0: _finish("dropped")
		"walk_after":
			caption("walking with the tool on its back")
			if t_state > 2.5:
				wako.stop_navigation()
				_go("retrieve")
		"retrieve":
			caption("retrieve: %s %s" % [bt.phase, _stage_name()])
			if t_state < .05: return
			if not _t.has("retrieve_request"):
				# A real foot action is queued; BackTool retrieves first.
				if bt.phase == "back":
					_t.retrieve_request = clock
					_event("retrieve_request")
					wako.work_target = target
					wako.begin_action("inspect")
			if wako.action == "inspect" and not _t.has("action_begin"):
				_t.action_begin = clock
				_event("action_begin")
			if _t.has("action_begin") and wako.action.is_empty():
				_finish("complete")
			if t_state > 14.0: _finish("retrieve_timeout")
			if not wako.equipped_tool and _t.has("dropped") and clock - float(_t.dropped) > 2.0: _finish("dropped")
	_interrupts(bt)
	_saves(bt)

func _go(next: String) -> void:
	state = next
	t_state = 0.0

func _interrupts(bt: RefCounted) -> void:
	var label := _arg("interrupt", "")
	if label.is_empty() or _interrupt_done or not is_instance_valid(tool) or not bt: return
	var stage := _stage_name()
	var phase: String = bt.phase
	var hit := false
	var vy: float = tool.linear_velocity.y if not tool.freeze else 0.0
	match label:
		"gather": hit = phase == "prepare" and (stage == "gather" or (stage.is_empty() and bt._path_index <= 1 and t_state > .25))
		"kick": hit = phase == "prepare" and (stage == "kick" or (stage.is_empty() and bt._path_index >= bt._waypoints.size() - 1))
		"rising": hit = phase == "flight" and vy > 1.0
		"apex": hit = phase == "flight" and absf(vy) < .35 and bt._age > .05
		"falling": hit = phase == "flight" and vy < -1.5
		"settle": hit = phase == "back" and _t.has("catch") and clock - float(_t.catch) < .2 and clock - float(_t.catch) > .03
		"reach": hit = phase == "retrieve" and bt._path_index >= 1
		"draw": hit = phase == "return" and bt._path_index <= 1
		"home": hit = phase == "return" and bt._path_index >= bt._waypoints.size() - 1
	if not hit: return
	_interrupt_done = true
	_interrupt_t = clock
	_interrupt_tool_pos = tool.global_position
	m.interrupt_phase = phase
	m.interrupt_stage = stage
	_event("interrupt", {"phase": phase, "stage": stage, "tool": tool.global_position})
	wako.interrupt("Harness interruption")

func _saves(bt: RefCounted) -> void:
	var label := _arg("save", "")
	if label.is_empty() or _save_done or not is_instance_valid(tool) or not bt: return
	var hit := false
	match label:
		"flight": hit = bt.phase == "flight" and bt._age > .15
		"prepare": hit = bt.phase == "prepare" and t_state > .2
		"back", "back_v2": hit = bt.phase == "back" and _t.has("catch") and clock - float(_t.catch) > .5
		"retrieve": hit = bt.phase == "retrieve" and bt._path_index >= 1
	if not hit: return
	_save_done = true
	var phase: String = bt.phase
	var saved_worker: Dictionary = JSON.parse_string(JSON.stringify(wako.serialize_state()))
	var saved_tool: Dictionary = JSON.parse_string(JSON.stringify(tool.serialize()))
	var tool_pos := tool.global_position
	var tool_vel := tool.linear_velocity
	var saved_motion: Dictionary = saved_worker.get("back_tool", {}).get("motion", {})
	if label == "back_v2":
		# Forge an old (v2) save: same seated body at the old rack depth z .58.
		var local: Transform3D = bt._body_frame.affine_inverse() * tool.global_transform
		local.origin.z = .58
		saved_tool.transform = Part.encode_transform(bt._body_frame * local)
		saved_worker.back_tool.version = 2
		saved_worker.back_tool.erase("seat")
		tool_pos = (bt._body_frame * local).origin
	_event("save", {"phase": phase, "version": saved_worker.get("back_tool", {}).get("version", 0), "tool": tool_pos})
	# Rebuild both bodies the way the yard does after a load.
	var old_worker := wako
	var old_tool := tool
	var restore_pos: Array = saved_worker.position
	old_worker.queue_free()
	old_tool.queue_free()
	remove_child(old_worker)
	remove_child(old_tool)
	tool = Part.new()
	tool.setup(str(saved_tool.kind), str(saved_tool.id), true)
	add_child(tool)
	tool.restore_condition(saved_tool)
	tool.global_transform = Part.decode_transform(saved_tool.transform)
	tool.set_meta(&"equipped_worker", str(saved_worker.id))
	tool.freeze = true
	tool.collision_layer = 0
	tool.collision_mask = 0
	wako = spawn_wako(Vector3(restore_pos[0], restore_pos[1], restore_pos[2]), str(saved_worker.id))
	wako.restore_state(saved_worker)
	cam_follow = wako
	var bound: bool = wako.back_tool.bind_restored_item(tool)
	if not bound:
		tool.set_carried(wako.tool_anchor, Vector3.ZERO)
		tool.global_transform = wako.tool_anchor.global_transform
		wako.set_equipped_tool(tool)
	var restored_phase: String = wako.back_tool.phase
	var carrier := "none"
	if is_instance_valid(tool.carrier): carrier = "back" if tool.carrier == wako.back_tool.back_anchor else ("foot" if tool.carrier == wako.tool_anchor else str(tool.carrier.name))
	m.save = {"saved_phase": phase, "restored_phase": restored_phase, "carrier": carrier, "bound": bound,
		"equipped": wako.equipped_tool == tool, "frozen": tool.freeze, "layer": tool.collision_layer,
		"pose_error": tool.global_position.distance_to(tool_pos), "velocity_saved": tool_vel,
		"velocity_restored": tool.linear_velocity, "saved_motion": saved_motion,
		"catch_fabricated": carrier == "back" and phase not in ["back", "retrieve"], "kind_same": tool.kind == tool_kind,
		"migrated": wako.back_tool.get("migrated_seat") if "migrated_seat" in wako.back_tool else null,
		"seat_after": wako.back_tool._body_frame.affine_inverse() * tool.global_position,
		"mass_same": is_equal_approx(tool.mass, float(m.tool_mass)), "health": tool.health}
	_event("restored", m.save)
	_id = tool.get_instance_id()
	_rid = tool.get_rid()
	_save_t = clock
	_prev_tool_pos = Vector3.INF

var _save_t := -1.0

func _observe(delta: float, bt: RefCounted) -> void:
	if not is_instance_valid(wako) or not bt: return
	var phase: String = bt.phase
	var stage := _stage_name()
	var wpos := wako.global_position
	var wvel := wako.linear_velocity
	if wako.on_ground: _ground_y = wako._ground_point.y
	if phase != _prev_phase:
		_event("phase", {"from": _prev_phase, "to": phase, "stage": stage})
		_on_phase(_prev_phase, phase, bt)
		_prev_phase = phase
	if stage != _prev_stage:
		_event("stage", {"from": _prev_stage, "to": stage})
		_prev_stage = stage
	if is_instance_valid(tool):
		if tool.get_instance_id() != _id or tool.get_rid() != _rid: _identity_ok = false
		var owned: bool = wako.equipped_tool == tool
		if is_instance_valid(wako.equipped_tool) and not owned: _identity_ok = false
		if not is_equal_approx(tool.mass, float(m.get("tool_mass", tool.mass))): _mass_ok = false
		var expected_mass: float = 22.0 + bt.holder_mass() + (tool.mass if is_instance_valid(tool.carrier) and owned else 0.0) + wako.cargo_mass
		if owned and absf(wako.mass - expected_mass) > .001: _mass_ok = false
		var tp := tool.global_position
		if _prev_tool_pos.is_finite():
			var step := tp.distance_to(_prev_tool_pos)
			if phase == "flight" or _prev_phase_tick == "flight":
				_flight_samples += 1
			if not _impulse_ticks.has(_tick): _max_jump = maxf(_max_jump, step)
		if args.has("trace_interrupt") and _interrupt_t >= 0.0 and clock - _interrupt_t < .1:
			print("INT t=%.4f pos=%s step=%.4f frozen=%s vel=%s" % [clock, tp, tp.distance_to(_prev_tool_pos) if _prev_tool_pos.is_finite() else -1.0, tool.freeze, tool.linear_velocity])
		# Interrupt continuity: the released body must not jump.
		if _interrupt_t >= 0.0 and clock - _interrupt_t < .3 and _prev_tool_pos.is_finite():
			var predicted := _prev_tool_pos + _prev_tool_vel * delta
			m.interrupt_max_tool_step = maxf(float(m.get("interrupt_max_tool_step", 0.0)), tp.distance_to(predicted))
		if phase == "flight":
			var com: Vector3 = tool.global_transform * tool.center_of_mass
			m.apex_world = maxf(float(m.get("apex_world", -INF)), com.y)
			m.apex_above_launch = maxf(float(m.get("apex_above_launch", -INF)), com.y - _launch_tool.y)
			m.apex_above_ground = maxf(float(m.get("apex_above_ground", -INF)), com.y - _ground_y)
			var roof: float = bt._root.origin.y + .3376
			m.apex_above_roof = maxf(float(m.get("apex_above_roof", -INF)), com.y - roof)
			if com.y > roof: m.frames_above_roof = int(m.get("frames_above_roof", 0)) + 1
		_prev_tool_vel = tool.linear_velocity if not tool.freeze else (tp - _prev_tool_pos) / delta if _prev_tool_pos.is_finite() else Vector3.ZERO
		_prev_tool_pos = tp
	# Body: advance and drive force (horizontal capsule acceleration).
	if phase in ["prepare", "flight"] or (phase == "back" and _t.has("catch") and clock - float(_t.catch) < .35 and not wako.has_target):
		var acc := ((wvel - _prev_worker_vel) / delta).slide(Vector3.UP)
		if not _impulse_ticks.has(_tick) and not _impulse_ticks.has(_tick - 1):
			m.peak_horizontal_force = maxf(float(m.get("peak_horizontal_force", 0.0)), acc.length() * wako.mass)
		m.peak_horizontal_speed = maxf(float(m.get("peak_horizontal_speed", 0.0)), (wvel - wako.ground_velocity).slide(Vector3.UP).length())
		var p: SkeletonModifier3D = wako._pose
		if p and p.evaluated_valid:
			var support: int = 1 - wako.tool_foot_side()
			var sole: Vector3 = wako.global_transform * p.evaluated_worker.affine_inverse() * p.evaluated_soles[support]
			if not _support_sole0.is_finite() and p.evaluated_grounded[support]: _support_sole0 = sole
			elif _support_sole0.is_finite() and p.evaluated_grounded[support]:
				m.support_sole_slip = maxf(float(m.get("support_sole_slip", 0.0)), sole.distance_to(_support_sole0))
	if args.has("trace") and is_instance_valid(tool) and phase in ["flight","prepare"] or (args.has("trace") and _t.has("catch") and clock - float(_t.catch) < .3):
		var local: Vector3 = bt._body_frame.affine_inverse() * tool.global_position
		var seat: Vector3 = bt.seat_point() if bt.has_method("seat_point") else Vector3(0, -.18, .58)
		var rel: Vector3 = local - seat
		print("TRACE t=%.3f ph=%s st=%s tool_body=(%.3f,%.3f,%.3f) gap=(%.3f,%.3f,%.3f) wv=(%.2f,%.2f,%.2f) wpos=(%.3f,%.3f) tv=(%.2f,%.2f,%.2f) turn=%.1f" % [clock, phase, stage,
			local.x, local.y, local.z, rel.x, rel.y, rel.z, wvel.x, wvel.y, wvel.z, wpos.x, wpos.z, tool.linear_velocity.x, tool.linear_velocity.y, tool.linear_velocity.z,
			rad_to_deg(_turn(tool.global_basis, _seat_basis(bt)))], " adv=", bt._advance.get("last", {}) if "_advance" in bt else {})
	if args.has("trace_action") and is_instance_valid(tool) and _t.has("action_begin") and clock - float(_t.action_begin) < .5:
		var tb: Transform3D = bt._body_frame.affine_inverse() * tool.global_transform
		print("ACTION t=%.3f prog=%.3f tool_x=(%.2f,%.2f,%.2f) tool_y=(%.2f,%.2f,%.2f) pos=(%.3f,%.3f,%.3f) carrier=%s" % [clock, wako.action_progress, tb.basis.x.x, tb.basis.x.y, tb.basis.x.z, tb.basis.y.x, tb.basis.y.y, tb.basis.y.z, tb.origin.x, tb.origin.y, tb.origin.z, tool.carrier.name if is_instance_valid(tool.carrier) else "none"])
	_prev_worker_vel = wvel
	_prev_worker_pos = wpos
	_prev_phase_tick = phase
	if bt.has_method("stunt_metrics"):
		var sm: Dictionary = bt.stunt_metrics()
		if not sm.is_empty(): m.stunt = sm
	m.max_toe_step = bt.max_toe_step
	m.max_toe_turn = bt.max_toe_turn
	m.validation_usec_max = maxi(int(m.get("validation_usec_max", 0)), int(bt.validation_usec))
	if not is_instance_valid(wako.equipped_tool):
		m.holder_visible_without_tool = bt.holder.visible

var _prev_phase_tick := ""

func _on_phase(from: String, to: String, bt: RefCounted) -> void:
	if to == "prepare" and not _t.has("prepare"): _t.prepare = clock
	if to == "flight" and not _t.has("launch"):
		_t.launch = clock
		_launch_pos = wako.global_position
		_launch_tool = tool.global_transform * tool.center_of_mass
		m.launch_speed = tool.linear_velocity.length()
		m.launch_velocity = tool.linear_velocity
		m.launch_spin = tool.angular_velocity
		m.launch_impulse = bt.launch_impulse.length()
		m.launch_tool_height = _launch_tool.y - _ground_y
		_impulse_ticks[_tick] = true
		_impulse_ticks[_tick + 1] = true
	if from == "flight" and to == "back":
		_t.catch = clock
		_impulse_ticks[_tick] = true
		_impulse_ticks[_tick + 1] = true
		m.flight_time = clock - float(_t.launch)
		m.stow_time = clock - float(_t.request)
		m.stow_time_from_prepare = clock - float(_t.get("prepare", _t.request))
		m.advance = (wako.global_position - _launch_pos).slide(Vector3.UP).length()
		m.advance_forward = (wako.global_position - _launch_pos).dot((-wako._model.global_basis.z).slide(Vector3.UP).normalized())
		m.contacts = bt.last_contact_points.size() / 2
		m.catch_pose_error = bt.catch_pose_error
		var exact: Transform3D = tool.global_transform
		m.catch_orientation_error_deg = rad_to_deg(_turn(exact.basis, _seat_basis(bt)))
		var seat: Vector3 = bt._body_frame * (bt.seat_point() if bt.has_method("seat_point") else Vector3(0, -.18, .58))
		m.catch_seat_gap = bt._root.basis.inverse() * (exact.origin - seat)
		# Tool step across the contact tick vs. its free ballistic prediction.
		if _prev_tool_pos.is_finite():
			m.catch_step_world = exact.origin.distance_to(_prev_tool_pos)
	if from == "back" and to == "retrieve": _t.retrieve = clock
	if from == "retrieve" and to == "return":
		_t.contact = clock
		m.retrieve_reach_time = clock - float(_t.get("retrieve_request", _t.retrieve))
	if from == "retrieve" and to == "back":
		_event("retrieve_aborted_to_back")
	if from == "return" and to == "foot":
		_t.home = clock
		m.retrieval_time = clock - float(_t.get("retrieve_request", clock))
	if to == "foot" and from in ["prepare", "flight", "retrieve", "return", "back"] and not is_instance_valid(wako.equipped_tool):
		_t.dropped = clock
		m.dropped_from = from
		m.drop_reason = bt.reason

func _finish(why: String) -> void:
	if _done: return
	_done = true
	var bt := _bt()
	m.result = why
	m.identity_same = _identity_ok
	m.mass_conserved = _mass_ok
	m.final_phase = bt.phase if bt else ""
	m.final_carrier = "none"
	if is_instance_valid(tool) and is_instance_valid(tool.carrier):
		m.final_carrier = "back" if tool.carrier == bt.back_anchor else ("foot" if tool.carrier == wako.tool_anchor else str(tool.carrier.name))
	m.final_equipped = is_instance_valid(wako) and wako.equipped_tool == tool and is_instance_valid(tool)
	if _t.has("dropped") and is_instance_valid(tool): m.dropped_tool_rest = tool.global_position
	m.tosses = bt.tosses
	m.catches = bt.catches
	m.retrievals = bt.retrievals
	m.timeline = _t
	m.holder = _holder_metrics(bt)
	if _interrupt_t >= 0.0:
		m.interrupt_outcome = {"phase_after": bt.phase, "carrier": m.final_carrier, "equipped": m.final_equipped,
			"same_instance": is_instance_valid(tool) and tool.get_instance_id() == _id, "dropped": _t.has("dropped"),
			"max_tool_step_after": m.get("interrupt_max_tool_step", 0.0)}
	print("BACK_STUNT_METRICS ", JSON.stringify(m))
	if args.has("quit"):
		await get_tree().create_timer(.2).timeout
		get_tree().quit()

var cam_lift := 0.0

func _process(delta: float) -> void:
	super(delta)
	# Frame the whole throw (apex ~2.1 m) as well as the feet.
	if cam_lift != 0.0: camera.look_at(cam_target + Vector3(0, cam_lift, 0), Vector3.UP)
	if not _done and args.has("quit") and clock > 40.0: _finish("wall_timeout")

## ---- Holder geometry (plate vs skin, seated tool vs plate) --------------------
func _holder_metrics(bt: RefCounted) -> Dictionary:
	var out := {}
	var meshes := 0
	var sensors := 0
	var seat: MeshInstance3D
	for child: Node in bt.holder.get_children():
		if child is MeshInstance3D: meshes += 1
		if child is CollisionShape3D: sensors += 1
		if child.name == "RootSeat": seat = child
	out.meshes = meshes
	out.sensors = sensors
	out.mass = bt.holder_mass()
	out.body_fitted = HolderVisual._body_fitted
	out.visible = bt.holder.visible
	var skin_z := _skin_back_grid()
	if seat and not skin_z.is_empty():
		var inner := _plate_inner_grid(seat)
		var gaps: Array[float] = []
		for key: Vector2 in skin_z:
			if inner.has(key): gaps.append(float(inner[key]) - float(skin_z[key]))
		if not gaps.is_empty():
			gaps.sort()
			out.plate_gap_min = gaps[0]
			out.plate_gap_max = gaps[-1]
			out.plate_samples = gaps.size()
		var outer_max := -INF
		var arrays := seat.mesh.surface_get_arrays(0)
		for v: Vector3 in arrays[Mesh.ARRAY_VERTEX]: outer_max = maxf(outer_max, (seat.transform * v).z)
		out.plate_outer_z = outer_max
		if is_instance_valid(tool) and tool.carrier == bt.back_anchor:
			var inv: Transform3D = bt.holder.global_transform.affine_inverse() * tool.global_transform
			var front := INF
			for box: AABB in tool.get_meta(&"worker_tool_keepouts", []):
				for c in 8: front = minf(front, (inv * box.get_endpoint(c)).z)
			out.tool_front_z = front
			out.tool_plate_gap = front - outer_max
			var native_front := INF
			for shape: Node in tool.find_children("*", "CollisionShape3D", true, false):
				var cs := shape as CollisionShape3D
				if cs.disabled or not cs.shape is BoxShape3D: continue
				var half: Vector3 = (cs.shape as BoxShape3D).size * .5
				var local: Transform3D = bt.holder.global_transform.affine_inverse() * cs.global_transform
				for c in 8: native_front = minf(native_front, (local * (AABB(-half, half * 2.0).get_endpoint(c))).z)
			out.tool_native_front_z = native_front
			out.seat_local = bt.holder.global_transform.affine_inverse() * tool.global_position
	return out

func _skin_back_grid() -> Dictionary:
	var mi: MeshInstance3D = wako._skin_mesh
	var sk: Skeleton3D = wako._skeleton
	if not mi or not mi.skin: return {}
	var skin: Skin = mi.skin
	var root_bind := -1
	for bind in skin.get_bind_count():
		if skin.get_bind_bone(bind) == 0 or skin.get_bind_name(bind) == sk.get_bone_name(0): root_bind = bind; break
	if root_bind < 0: return {}
	var xf := Transform3D(sk.get_bone_global_rest(0).basis, Vector3.ZERO) * skin.get_bind_pose(root_bind)
	var tris: Array = []
	for surface in mi.mesh.get_surface_count():
		var a := mi.mesh.surface_get_arrays(surface)
		if a[Mesh.ARRAY_BONES] == null: continue
		var pts: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
		for o in range(0, idx.size(), 3):
			var p0: Vector3 = xf * pts[idx[o]]
			var p1: Vector3 = xf * pts[idx[o + 1]]
			var p2: Vector3 = xf * pts[idx[o + 2]]
			if minf(p0.z, minf(p1.z, p2.z)) < .05: continue
			tris.append([p0, p1, p2])
	return _grid_max_z(tris)

func _plate_inner_grid(seat: MeshInstance3D) -> Dictionary:
	var a := seat.mesh.surface_get_arrays(0)
	var pts: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var tris: Array = []
	var count := idx.size() if not idx.is_empty() else pts.size()
	for o in range(0, count, 3):
		var p := []
		for c in 3: p.append(seat.transform * pts[idx[o + c] if not idx.is_empty() else o + c])
		tris.append(p)
	return _grid_min_z(tris)

func _grid_points() -> Array[Vector2]:
	var out: Array[Vector2] = []
	for i in 11:
		for j in 6:
			out.append(Vector2(-.24 + .048 * i, -.225 + .039 * j))
	return out

static func _bary_z(p: Vector2, t: Array) -> float:
	var a: Vector3 = t[0]; var b: Vector3 = t[1]; var c: Vector3 = t[2]
	var v0 := Vector2(b.x - a.x, b.y - a.y); var v1 := Vector2(c.x - a.x, c.y - a.y); var v2 := p - Vector2(a.x, a.y)
	var d := v0.x * v1.y - v1.x * v0.y
	if absf(d) < 1e-12: return NAN
	var u := (v2.x * v1.y - v1.x * v2.y) / d
	var v := (v0.x * v2.y - v2.x * v0.y) / d
	if u < -1e-6 or v < -1e-6 or u + v > 1.0 + 1e-6: return NAN
	return a.z + u * (b.z - a.z) + v * (c.z - a.z)

func _grid_max_z(tris: Array) -> Dictionary:
	var out := {}
	for p: Vector2 in _grid_points():
		var best := -INF
		for t: Array in tris:
			var z := _bary_z(p, t)
			if not is_nan(z): best = maxf(best, z)
		if best > -INF: out[p] = best
	return out

func _grid_min_z(tris: Array) -> Dictionary:
	var out := {}
	for p: Vector2 in _grid_points():
		var best := INF
		for t: Array in tris:
			var z := _bary_z(p, t)
			if not is_nan(z): best = minf(best, z)
		if best < INF: out[p] = best
	return out

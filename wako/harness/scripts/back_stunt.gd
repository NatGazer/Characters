extends "res://harness/scripts/stage.gd"
## Focused back-tool stunt scene and metrics probe.
## Wako holds a real catalogue tool (same Part body as play) on its toe,
## stows it on its back, then retrieves it for a foot action. Works against
## both the legacy hop and the new upward stunt; new diagnostics are read
## only when the BackTool exposes them. Round-1 review checks (catch tray
## split, drop/restore overlap and worker dv, leg-vs-seated-tool clearance,
## per-tick query cost, knock-down, late interrupt/save) are folded in here.
## User args (after `--`):
##   --tool=assembly_tool|salvage_tool   --side=0|1
##   --walk [--walk_dist=6 --walk_speed=2.1]   walk/run with the tool seated
##   --depart             stow triggered by a far navigation target (production path)
##   --interrupt=gather|hold(=windup)|kick|rising|apex|falling|late|settle|reach|contact|draw|home  [--late_h=.12]
##   --hit_kick_rel=k [--hit_speed=3 --hit_dir=1]   recoil-strength hit k ticks after the kick starts
##   --knock=back|retrieve|draw            ragdoll knock-down at that moment
##   --ceiling=<y>        static slab above the Wako (blocked arc)
##   --save=flight|flight_late|prepare|back|back_v2|retrieve    save + rebuild + restore
##   --slope=<deg>
##   --cam=side|three|front|front3|back|side_wide|three_wide|front3_wide|back_wide
##        --camoff=x,y,z  --cam_lift=.35 (.55 wide) --fixed --fov=50
##   --noshadow  --win=a-b;c-d (render windows)  --vis=a-b (per-tick VIS trace)
##   --ticks_out=<path> (per-tick cost rows)  --quit (exit when the scenario completes)
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
var chk := {}
var _id := 0
var _rid := RID()
var _prev_phase := ""
var _prev_stage := ""
var _prev_tool_pos := Vector3.INF
var _prev_tool_vel := Vector3.ZERO
var _prev_worker_vel := Vector3.ZERO
var _prev_worker_pos := Vector3.ZERO
var _prev_body := Transform3D.IDENTITY
var _prev_tool_xf := Transform3D.IDENTITY
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
var _prev_phase_tick := ""
var _save_t := -1.0
var cam_lift := 0.0

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
		"front3": cam_offset = Vector3(-1.9, .6, -2.2)
		"back": cam_offset = Vector3(.3, .9, 2.5)
		# Wide presets keep the ground and the whole 2.6 m flight in frame.
		"side_wide": cam_offset = Vector3(3.5, 1.15, -.2)
		"three_wide": cam_offset = Vector3(2.55, 1.2, 2.6)
		"front3_wide": cam_offset = Vector3(-2.35, 1.0, -2.75)
		"back_wide": cam_offset = Vector3(.45, 1.15, 3.4)
		_: cam_offset = Vector3(2.0, 1.0, 2.05)
	if args.has("camoff"):
		var c: PackedStringArray = _arg("camoff", "").split(",")
		cam_offset = Vector3(float(c[0]), float(c[1]), float(c[2]))
	cam_lift = float(_arg("cam_lift", ".55" if _arg("cam", "").ends_with("_wide") else ".35"))
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
	if args.has("plan_debug") and wako.back_tool: wako.back_tool.plan_debug = true
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
	_late_hooks(bt)
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
				# --depart: the production trigger (a far navigation target) starts
				# the stow; otherwise the head-launch style request_stow() does.
				if args.has("depart"):
					if not wako.has_target: wako.navigate_to(wako.global_position - wako._model.global_basis.z * float(_arg("walk_dist", "6")))
				else: bt.request_stow()
			if bt.phase == "back" and tool.carrier == bt.back_anchor and _t.has("catch") and clock - float(_t.catch) > .8 and not m.has("seated"):
				m.seated = _holder_metrics(bt)
			if bt.phase == "back" and tool.carrier == bt.back_anchor and _t.has("catch") and clock - float(_t.catch) > 1.2:
				if args.has("depart"):
					_go("walk_after")
				elif args.has("walk"):
					wako.walk_speed = float(_arg("walk_speed", str(wako.walk_speed)))
					wako.navigate_to(wako.global_position - wako._model.global_basis.z * float(_arg("walk_dist", "6")))
					_go("walk_after")
				else:
					_go("retrieve")
			if t_state > 12.0: _finish("stow_timeout")
			if not wako.equipped_tool and _t.has("dropped") and clock - float(_t.dropped) > 2.0 and (not bt.busy() or clock - float(_t.dropped) > 6.0): _finish("dropped")
		"walk_after":
			caption("walking with the tool on its back")
			if not wako.has_target or t_state > 8.0:
				wako.stop_navigation()
				if t_state > 1.0 and wako.linear_velocity.length() < .2: _go("retrieve")
		"retrieve":
			caption("retrieve: %s %s" % [bt.phase, _stage_name()])
			if t_state < .05: return
			if not _t.has("retrieve_request"):
				# A real foot action is queued; BackTool retrieves first.
				if bt.phase == "back" and not wako.has_target:
					_t.retrieve_request = clock
					_event("retrieve_request")
					wako.work_target = target
					wako.begin_action("inspect")
			if _t.has("retrieve_aborted") and not _t.has("retrieve_rerequest") and clock - float(_t.retrieve_aborted) > 1.0 \
					and bt.phase == "back" and not bt.busy():
				# An interrupted retrieval leaves the tool seated; the next
				# ordinary foot action retrieves it normally (no soft-lock).
				_t.retrieve_rerequest = clock
				_t.retrieve_request = clock
				_event("retrieve_rerequest")
				wako.work_target = target
				wako.begin_action("inspect")
			if wako.action == "inspect" and not _t.has("action_begin"):
				_t.action_begin = clock
				_event("action_begin")
			if _t.has("action_begin") and wako.action.is_empty():
				_finish("complete")
			if t_state > 14.0: _finish("retrieve_timeout")
			if not wako.equipped_tool and _t.has("dropped") and clock - float(_t.dropped) > 2.0 and (not bt.busy() or clock - float(_t.dropped) > 6.0): _finish("dropped")
	_interrupts(bt)
	_saves(bt)
	bt = _bt()
	if bt and _save_t >= 0.0 and clock - _save_t > .4 and not m.has("seated_after_restore") and bt.phase == "back" and is_instance_valid(tool) and tool.carrier == bt.back_anchor:
		m.seated_after_restore = _holder_metrics(bt)
	if bt and is_instance_valid(wako):
		_cost(bt)
		_watch(delta, bt)

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
		"hold", "windup": hit = phase == "prepare" and stage in ["hold", "windup"]
		"kick": hit = phase == "prepare" and (stage == "kick" or (stage.is_empty() and bt._path_index >= bt._waypoints.size() - 1))
		"rising": hit = phase == "flight" and vy > 1.0
		"apex": hit = phase == "flight" and absf(vy) < .35 and bt._age > .05
		"falling": hit = phase == "flight" and vy < -1.5
		"settle": hit = phase == "back" and _t.has("catch") and clock - float(_t.catch) < .2 and clock - float(_t.catch) > .03
		"reach": hit = phase == "retrieve" and bt._path_index >= 1
		"contact": hit = phase == "return" and bt._waypoints.is_empty()
		"draw": hit = phase == "return" and stage == "draw" and not bt._waypoints.is_empty() and bt._path_index >= 1
		"home": hit = phase == "return" and stage == "home" and not bt._waypoints.is_empty() and bt._path_index >= bt._waypoints.size() - 1
	if not hit: return
	_do_interrupt(bt, phase, stage)

func _do_interrupt(bt: RefCounted, phase: String, stage: String) -> void:
	_interrupt_done = true
	_interrupt_t = clock
	_interrupt_tool_pos = tool.global_position
	m.interrupt_phase = phase
	m.interrupt_stage = stage
	chk.interrupt_overlap_before = _tool_overlap_report()
	_event("interrupt", {"phase": phase, "stage": stage, "tool": tool.global_position})
	wako.interrupt("Harness interruption")

func _late_hooks(bt: RefCounted) -> void:
	if not bt or not is_instance_valid(tool): return
	# Knock-down while seated / during retrieval.
	var knock := _arg("knock", "")
	if not knock.is_empty() and not chk.has("knock"):
		var go := false
		if knock == "back": go = bt.phase == "back" and _t.has("catch") and clock - float(_t.catch) > .6 and tool.carrier == bt.back_anchor
		if knock == "retrieve": go = bt.phase == "retrieve" and bt._path_index >= 1
		if knock == "draw": go = bt.phase == "return" and bt._path_index <= 1
		if go:
			_interrupt_tool_pos = tool.global_position
			_interrupt_t = clock
			_event("knock", {"phase": bt.phase, "stage": _stage_name()})
			chk.knock = {"ok": wako.ragdoll.knock_down(Vector3.ZERO), "phase": bt.phase}
	# Late-flight interrupt (tool falling into the seat region).
	if _arg("interrupt", "") == "late" and not _interrupt_done and bt.phase == "flight":
		var com: Vector3 = tool.global_transform * tool.center_of_mass
		var seat: Vector3 = bt._body_frame * bt.seat_point()
		if tool.linear_velocity.y < -1.0 and com.y - seat.y < float(_arg("late_h", ".12")):
			_do_interrupt(bt, bt.phase, _stage_name())
	# Fright / hit while the tool flies (--fear=rising|apex|falling|late|age).
	var fear := _arg("fear", "")
	if not fear.is_empty() and not chk.has("fear") and bt.phase == "flight":
		var vy: float = tool.linear_velocity.y
		var com_f: Vector3 = tool.global_transform * tool.center_of_mass
		var seat_f: Vector3 = bt._body_frame * bt.seat_point()
		var go_f := false
		match fear:
			"rising": go_f = vy > 1.0
			"apex": go_f = absf(vy) < .35 and bt._age > .05
			"falling": go_f = vy < -1.5
			"late": go_f = vy < -1.0 and com_f.y - seat_f.y < .15
			"age": go_f = bt._age > float(_arg("fear_age", ".15"))
		if go_f:
			chk.fear = {"t": clock, "stage": _stage_name(), "age": bt._age, "tool_above_seat": com_f.y - seat_f.y, "hit": args.has("hit")}
			_event("fear", chk.fear)
			_interrupt_t = clock
			_interrupt_tool_pos = tool.global_position
			if args.has("hit"): wako.apply_hit(-wako._model.global_basis.x * wako.mass * float(_arg("hit_speed", "1.0")))
			else: wako.fear_time = 3.0
			_loose_watch = 0
	_track_loose(bt)
	# Late-flight save (tool inside/near the capsule envelope).
	if _arg("save", "") == "flight_late" and not _save_done and bt.phase == "flight":
		var com2: Vector3 = tool.global_transform * tool.center_of_mass
		var seat2: Vector3 = bt._body_frame * bt.seat_point()
		if tool.linear_velocity.y < -1.0 and com2.y - seat2.y < float(_arg("late_h", ".12")):
			chk.late_save_overlap_before = _tool_overlap_report()
			_do_save(bt)

func _saves(bt: RefCounted) -> void:
	var label := _arg("save", "")
	if label.is_empty() or label == "flight_late" or _save_done or not is_instance_valid(tool) or not bt: return
	var hit := false
	match label:
		"flight": hit = bt.phase == "flight" and bt._age > .15
		"prepare": hit = bt.phase == "prepare" and t_state > .2
		"back", "back_v2": hit = bt.phase == "back" and _t.has("catch") and clock - float(_t.catch) > .5
		"retrieve": hit = bt.phase == "retrieve" and bt._path_index >= 1
		"return": hit = bt.phase == "return" and not bt._waypoints.is_empty() and bt._path_index >= 1
	if hit: _do_save(bt)

## After any loose release, follow the same body for 2 s: the deepest pass of
## its visual vertices into the rigid cube, and where it comes to rest.
var _loose_watch := -1
var _vis_pts := PackedVector3Array()
func _tool_vis_points() -> PackedVector3Array:
	if not _vis_pts.is_empty(): return _vis_pts
	var inv := tool.global_transform.affine_inverse()
	for node: Node in tool.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if not mi.mesh or not mi.is_visible_in_tree(): continue
		var local: Transform3D = inv * mi.global_transform
		for surface in mi.mesh.get_surface_count():
			for vertex: Vector3 in mi.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]: _vis_pts.append(local * vertex)
	return _vis_pts

func _cube_penetration(bt: RefCounted) -> float:
	var cube := AABB(Vector3(-.424, -.2625, -.1992), Vector3(.848, .6001, .3984))
	var inv: Transform3D = bt._body_frame.affine_inverse() * tool.global_transform
	var depth := 0.0
	for point: Vector3 in _tool_vis_points():
		var q: Vector3 = inv * point
		if cube.has_point(q):
			depth = maxf(depth, minf(minf(minf(q.x - cube.position.x, cube.end.x - q.x), minf(q.y - cube.position.y, cube.end.y - q.y)), minf(q.z - cube.position.z, cube.end.z - q.z)))
	return depth

func _track_loose(bt: RefCounted) -> void:
	var loose: bool = not is_instance_valid(tool.carrier)
	if loose and _loose_watch < 0 and _t.has("dropped"): _loose_watch = 0
	if _loose_watch < 0 or _loose_watch > 240: return
	_loose_watch += 1
	if not loose: return
	var pen := _cube_penetration(bt)
	chk.loose_cube_pen_max = maxf(float(chk.get("loose_cube_pen_max", 0.0)), pen)
	if pen > .005: chk.loose_cube_pen_ticks = int(chk.get("loose_cube_pen_ticks", 0)) + 1
	if _loose_watch == 240:
		chk.loose_final_body_local = bt._body_frame.affine_inverse() * tool.global_position
		chk.loose_final_exception = wako in tool.get_collision_exceptions()

func _do_save(bt: RefCounted) -> void:
	var label := _arg("save", "")
	_save_done = true
	var phase: String = bt.phase
	var saved_worker: Dictionary = JSON.parse_string(JSON.stringify(wako.serialize_state()))
	var saved_tool: Dictionary = JSON.parse_string(JSON.stringify(tool.serialize()))
	var tool_pos := tool.global_position
	var tool_vel: Vector3 = (tool.global_position - _prev_tool_pos) * 120.0 if _prev_tool_pos.is_finite() else tool.linear_velocity
	if tool.carrier == null: tool_vel = tool.linear_velocity
	var saved_motion: Dictionary = saved_worker.get("back_tool", {}).get("motion", {})
	if label == "back_v2":
		# Forge a faithful old (v2) save: the old horizontal rack seat at
		# (0,-.18,.58) - tool X up, Y = -s*x (handle on the foot side), Z = s*z -
		# version 2 with no side/face/seat record. Restore must migrate it.
		var s: float = bt._side_sign
		var local := Transform3D(Basis(Vector3(0, 1, 0), Vector3(-s, 0, 0), Vector3(0, 0, s)), Vector3(0, -.18, .58))
		var world: Transform3D = bt._body_frame * local
		saved_tool.transform = Part.encode_transform(world)
		saved_worker.back_tool.version = 2
		for key: String in ["seat", "side", "flip"]: saved_worker.back_tool.erase(key)
		saved_worker.back_tool.local = Part.encode_transform(bt._root.affine_inverse() * world)
		tool_pos = world.origin
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
		"pose_error": tool.global_position.distance_to(tool_pos), "velocity_observed": tool_vel,
		"velocity_restored": tool.linear_velocity, "saved_motion": saved_motion,
		"catch_fabricated": carrier == "back" and phase not in ["back", "retrieve"], "kind_same": tool.kind == tool_kind,
		"migrated": wako.back_tool.get("migrated_seat") if "migrated_seat" in wako.back_tool else null,
		"seat_after": wako.back_tool._body_frame.affine_inverse() * tool.global_position,
		"mass_same": is_equal_approx(tool.mass, float(m.tool_mass)), "health": tool.health,
		"exception_with_worker": wako in tool.get_collision_exceptions()}
	_event("restored", m.save)
	_id = tool.get_instance_id()
	_rid = tool.get_rid()
	_save_t = clock
	_prev_tool_pos = Vector3.INF
	_restore_watch = 0

## ---- per-tick observation ------------------------------------------------------
func _leg_points(leg: int) -> Array:
	# The completed modifier's published leg (Pose's evaluated caches, rebased
	# to the current native body); raw bone reads outside the modifier would
	# show the un-solved animation pose.
	var pz: SkeletonModifier3D = wako._pose
	if pz and pz.evaluated_valid:
		var rebase: Transform3D = wako.global_transform * pz.evaluated_worker.affine_inverse()
		var sole: Vector3 = rebase * pz.evaluated_soles[leg]
		var ankle_basis: Basis = rebase.basis * pz.evaluated_ankles[leg]
		var ankle: Vector3 = sole - ankle_basis * Vector3(0, pz._ankle_height[leg], 0)
		return [rebase * pz.evaluated_hips[leg], rebase * pz.evaluated_knees[leg], ankle, sole]
	var sk: Skeleton3D = wako._skeleton
	var chain: Array = pz._chains[leg]
	var hip: Vector3 = sk.global_transform * sk.get_bone_global_pose(chain[0]).origin
	var knee: Vector3 = sk.global_transform * sk.get_bone_global_pose(chain[1]).origin
	var ankle_xf: Transform3D = sk.global_transform * sk.get_bone_global_pose(chain[2])
	var sole2: Vector3 = ankle_xf * Vector3(0, pz._ankle_height[leg], 0)
	return [hip, knee, ankle_xf.origin, sole2]

func _leg_angles(bt: RefCounted, leg: int) -> Dictionary:
	# Body-frame angles (+X right, +Y up, +Z back). Flexion > 0 = forward,
	# extension < 0; abduction > 0 = away from the body midline.
	var pts := _leg_points(leg)
	var inv: Basis = bt._body_frame.basis.inverse()
	var hip_local: Vector3 = bt._body_frame.affine_inverse() * pts[0]
	var outward := signf(hip_local.x) if absf(hip_local.x) > .01 else 1.0
	var out := {}
	for pair: Array in [["line", pts[3]], ["thigh", pts[1]]]:
		var v: Vector3 = inv * (Vector3(pair[1]) - Vector3(pts[0]))
		out[pair[0] + "_from_vertical"] = rad_to_deg(acos(clampf(-v.y / maxf(v.length(), 1e-6), -1.0, 1.0)))
		out[pair[0] + "_flexion"] = rad_to_deg(atan2(-v.z, -v.y))
		out[pair[0] + "_abduction"] = rad_to_deg(atan2(outward * v.x, -v.y))
	var sole_local: Vector3 = bt._body_frame.affine_inverse() * pts[3]
	out.sole_rel_hip = sole_local - hip_local
	return out

func _observe(delta: float, bt: RefCounted) -> void:
	if not is_instance_valid(wako) or not bt: return
	var phase: String = bt.phase
	var stage := _stage_name()
	var wpos := wako.global_position
	var wvel := wako.linear_velocity
	if _interrupt_t >= 0.0 and wako._animation:
		# Reaction clips after the startle/hit: [clip, start, seconds held].
		var clips: Array = m.get("reaction_clips", [])
		var now := str(wako._animation.current_animation)
		if clips.is_empty() or str(clips[-1][0]) != now:
			if clips.size() < 16: clips.append([now, snappedf(clock, .001), 0.0])
		else: clips[-1][2] = snappedf(clock - float(clips[-1][1]), .001)
		m.reaction_clips = clips
	if wako.on_ground: _ground_y = wako._ground_point.y
	if phase != _prev_phase:
		_event("phase", {"from": _prev_phase, "to": phase, "stage": stage})
		_on_phase(_prev_phase, phase, bt)
		_prev_phase = phase
	if stage != _prev_stage:
		_event("stage", {"from": _prev_stage, "to": stage})
		_on_stage(_prev_stage, stage, bt)
		_prev_stage = stage
	if is_instance_valid(tool):
		if tool.get_instance_id() != _id or tool.get_rid() != _rid: _identity_ok = false
		var owned: bool = wako.equipped_tool == tool
		if is_instance_valid(wako.equipped_tool) and not owned: _identity_ok = false
		if not is_equal_approx(tool.mass, float(m.get("tool_mass", tool.mass))): _mass_ok = false
		var expected_mass: float = 22.0 + bt.holder_mass() + (tool.mass if is_instance_valid(tool.carrier) and owned else 0.0) + wako.cargo_mass
		if owned and absf(wako.mass - expected_mass) > .001: _mass_ok = false
		var tp := tool.global_position
		var com: Vector3 = tool.global_transform * tool.center_of_mass
		if _prev_tool_pos.is_finite():
			var step := tp.distance_to(_prev_tool_pos)
			if phase == "flight" or _prev_phase_tick == "flight": _flight_samples += 1
			if not _impulse_ticks.has(_tick): _max_jump = maxf(_max_jump, step)
			# Kick / gather toe (tool COM) speed while the tool is on the foot.
			if phase == "prepare" and tool.carrier == wako.tool_anchor:
				var speed := step / delta
				var key := "kick_peak_speed" if stage in ["kick"] else ("hold_peak_speed" if stage == "hold" else "gather_peak_speed")
				m[key] = maxf(float(m.get(key, 0.0)), speed)
				if stage == "hold": m.hold_time = float(m.get("hold_time", 0.0)) + delta
			if phase == "flight":
				m.flight_turn_deg = float(m.get("flight_turn_deg", 0.0)) + rad_to_deg(_turn(_prev_tool_xf.basis, tool.global_basis))
		if args.has("trace_interrupt") and _interrupt_t >= 0.0 and clock - _interrupt_t < float(_arg("trace_window", ".1")):
			print("INT t=%.4f pos=%s step=%.4f frozen=%s vel=%s" % [clock, tp, tp.distance_to(_prev_tool_pos) if _prev_tool_pos.is_finite() else -1.0, tool.freeze, tool.linear_velocity])
		# Interrupt continuity: the released body must not jump.
		if _interrupt_t >= 0.0 and clock - _interrupt_t < .3 and _prev_tool_pos.is_finite():
			var predicted := _prev_tool_pos + _prev_tool_vel * delta
			m.interrupt_max_tool_step = maxf(float(m.get("interrupt_max_tool_step", 0.0)), tp.distance_to(predicted))
		if phase == "flight":
			m.apex_world = maxf(float(m.get("apex_world", -INF)), com.y)
			m.apex_above_launch = maxf(float(m.get("apex_above_launch", -INF)), com.y - _launch_tool.y)
			m.apex_above_ground = maxf(float(m.get("apex_above_ground", -INF)), com.y - _ground_y)
			var roof: float = bt._root.origin.y + .3376
			m.apex_above_roof = maxf(float(m.get("apex_above_roof", -INF)), com.y - roof)
			if com.y > roof: m.frames_above_roof = int(m.get("frames_above_roof", 0)) + 1
		_prev_tool_vel = tool.linear_velocity if not tool.freeze else (tp - _prev_tool_pos) / delta if _prev_tool_pos.is_finite() else Vector3.ZERO
		_prev_tool_pos = tp
		_prev_tool_xf = tool.global_transform
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
			elif _support_sole0.is_finite() and p.evaluated_grounded[support] and not _t.has("catch"):
				m.support_sole_slip = maxf(float(m.get("support_sole_slip", 0.0)), sole.distance_to(_support_sole0))
	_feet_after_launch(bt)
	_retrieval_watch(delta, bt)
	_r3_probe(delta, bt)
	if args.has("trace") and is_instance_valid(tool) and phase in ["flight","prepare"] or (args.has("trace") and _t.has("catch") and clock - float(_t.catch) < .3):
		var local: Vector3 = bt._body_frame.affine_inverse() * tool.global_position
		var seat: Vector3 = bt.seat_point() if bt.has_method("seat_point") else Vector3(0, -.18, .58)
		var rel: Vector3 = local - seat
		print("TRACE t=%.3f ph=%s st=%s tool_body=(%.3f,%.3f,%.3f) gap=(%.3f,%.3f,%.3f) wv=(%.2f,%.2f,%.2f) wpos=(%.3f,%.3f) tv=(%.2f,%.2f,%.2f) turn=%.1f" % [clock, phase, stage,
			local.x, local.y, local.z, rel.x, rel.y, rel.z, wvel.x, wvel.y, wvel.z, wpos.x, wpos.z, tool.linear_velocity.x, tool.linear_velocity.y, tool.linear_velocity.z,
			rad_to_deg(_turn(tool.global_basis, _seat_basis(bt)))], " adv=", bt._advance.get("last", {}) if "_advance" in bt else {})
	if args.has("vis") and is_instance_valid(tool):
		var vr := _arg("vis", "2.0-5.0").split("-")
		if clock >= float(vr[0]) and clock <= float(vr[1]): _vis(bt, phase, stage)
	_prev_worker_vel = wvel
	_prev_worker_pos = wpos
	_prev_phase_tick = phase
	_prev_body = bt._body_frame
	if bt.has_method("stunt_metrics"):
		var sm: Dictionary = bt.stunt_metrics()
		if not sm.is_empty(): m.stunt = sm
	if not stage.is_empty():
		# What the eyes actually do per beat (moves only when the expression
		# code is wired to the BackTool face hooks, e.g. the gaze preview build).
		var eyes: Dictionary = m.get("eyes", {})
		var beat: Dictionary = eyes.get(stage, {"gaze_max": [0.0, 0.0], "openness_min": 1.0})
		# Base helper face, or the face branch's eye engine (wako_eyes.gd).
		var engine: Variant = wako.get("eyes")
		var face_engine: bool = engine is Object and "gaze" in engine and "_blink_value" in engine
		var eg: Vector2 = engine.gaze if face_engine else wako._eye_gaze
		if eg.length() > Vector2(beat.gaze_max[0], beat.gaze_max[1]).length(): beat.gaze_max = [snappedf(eg.x, .0001), snappedf(eg.y, .0001)]
		beat.openness_min = minf(float(beat.openness_min), float(engine._blink_value) if face_engine else float(wako._eye_shader_openness))
		if not face_engine: beat.smile_max = maxf(float(beat.get("smile_max", 0.0)), float(wako._eye_smile))
		if face_engine and "_track" in engine and bt.has_method("gaze_target"):
			# How far the eyes' tracked point is from the stunt's gaze target.
			var want: Variant = bt.gaze_target()
			var track: Vector3 = engine._track
			var head: Vector3 = wako._visual_head_point if wako._visual_head_point.is_finite() else wako.global_position
			if want is Vector3 and track.is_finite():
				var err := rad_to_deg((track - head).angle_to(Vector3(want) - head))
				beat.track_err_max = maxf(float(beat.get("track_err_max", 0.0)), err)
				beat.track_err_sum = float(beat.get("track_err_sum", 0.0)) + err
				beat.track_n = int(beat.get("track_n", 0)) + 1
		eyes[stage] = beat
		m.eyes = eyes
	if bt.has_method("gaze_target") and stage in ["gather", "hold", "kick", "flight", "settle", "reach", "draw"]:
		var g: Variant = bt.gaze_target()
		var key := "gaze_" + stage
		if not m.has(key): m[key] = g is Vector3
		elif not (g is Vector3): m[key] = false
	m.max_toe_step = bt.max_toe_step
	m.max_toe_turn = bt.max_toe_turn
	m.validation_usec_max = maxi(int(m.get("validation_usec_max", 0)), int(bt.validation_usec))
	if not is_instance_valid(wako.equipped_tool):
		m.holder_visible_without_tool = bt.holder.visible

func _vis(bt: RefCounted, phase: String, stage: String) -> void:
	var sk: Skeleton3D = wako._skeleton
	var rootw: Transform3D = sk.global_transform * sk.get_bone_global_pose(0)
	var pz: SkeletonModifier3D = wako._pose
	if pz and pz.evaluated_valid: rootw = wako.global_transform * pz.evaluated_worker.affine_inverse() * pz.evaluated_root
	var soles := [Vector3.ZERO, Vector3.ZERO]
	if pz and pz.evaluated_valid:
		for k in 2: soles[k] = wako.global_transform * pz.evaluated_worker.affine_inverse() * pz.evaluated_soles[k]
	var bf: Transform3D = bt._body_frame
	var com: Vector3 = tool.global_transform * tool.center_of_mass
	var fs: int = wako.tool_foot_side()
	var gz: Variant = bt.gaze_target() if bt.has_method("gaze_target") else null
	var wpos := wako.global_position
	print("VIS t=%.4f ph=%s st=%s cap=(%.3f,%.3f,%.3f) root=(%.3f,%.3f,%.3f) fwd=(%.3f,%.3f,%.3f) kick=(%.3f,%.3f,%.3f) sup=(%.3f,%.3f,%.3f) gk=%s gs=%s tool=(%.3f,%.3f,%.3f) tup=(%.3f,%.3f,%.3f) gaze=%s" % [clock, phase, stage,
		wpos.x, wpos.y, wpos.z, rootw.origin.x, rootw.origin.y, rootw.origin.z, -bf.basis.z.x, -bf.basis.z.y, -bf.basis.z.z,
		soles[fs].x, soles[fs].y, soles[fs].z, soles[1-fs].x, soles[1-fs].y, soles[1-fs].z, str(pz.evaluated_grounded[fs]) if pz else "?", str(pz.evaluated_grounded[1-fs]) if pz else "?",
		com.x, com.y, com.z, tool.global_basis.y.x, tool.global_basis.y.y, tool.global_basis.y.z, str(gz)])

## Kick-foot touchdown and support-foot catch-up step around the catch.
var _kick_land_seen := false
var _support_plant := Vector3.INF
var _support_step_seen := false
var _kick_airborne := false
func _feet_after_launch(bt: RefCounted) -> void:
	var pz: SkeletonModifier3D = wako._pose
	if not pz or not pz.evaluated_valid or not _t.has("launch"): return
	var fs: int = int(bt._foot_side)
	var to_world: Transform3D = wako.global_transform * pz.evaluated_worker.affine_inverse()
	var kick_sole: Vector3 = to_world * pz.evaluated_soles[fs]
	var sup_sole: Vector3 = to_world * pz.evaluated_soles[1 - fs]
	var forward: Vector3 = (-wako._model.global_basis.z).slide(Vector3.UP).normalized()
	if not _kick_land_seen and clock - float(_t.launch) < 2.0:
		if not pz.evaluated_grounded[fs]: _kick_airborne = true
		elif _kick_airborne:
			_kick_land_seen = true
			m.kick_foot_land_after_launch = clock - float(_t.launch)
			m.kick_foot_land_ahead_of_capsule = (kick_sole - wako.global_position).dot(forward)
			m.kick_foot_land_ahead_of_launch_plant = (kick_sole - _launch_pos).dot(forward)
	if _t.has("catch") and not _support_step_seen:
		if not _support_plant.is_finite(): _support_plant = sup_sole
		elif sup_sole.distance_to(_support_plant) > .02:
			_support_step_seen = true
			m.support_step_after_catch = clock - float(_t.catch)
		if clock - float(_t.catch) < .02:
			m.support_behind_capsule_at_catch = (sup_sole - wako.global_position).dot(forward)
			m.kick_foot_ahead_of_capsule_at_catch = (kick_sole - wako.global_position).dot(forward)
	# Follow-through: kick sole travel past its release point along the kick.
	if _t.has("launch") and clock - float(_t.launch) < .25 and m.has("release_sole"):
		var dir: Vector3 = m.get("kick_dir", Vector3.UP)
		m.follow_through = maxf(float(m.get("follow_through", 0.0)), (kick_sole - Vector3(m.release_sole)).dot(dir))

## Retrieval: leg angles during the reach and the longest near-still interval.
var _retr_last_toe := Vector3.INF
var _still := 0.0
func _retrieval_watch(delta: float, bt: RefCounted) -> void:
	if args.has("trace_from") and clock > float(_arg("trace_from", "0")) and clock < float(_arg("trace_from", "0")) + 1.5 and is_instance_valid(tool):
		_dense_tool()
		var low := INF
		for i in range(0, _dense_pts.size(), 4): low = minf(low, (tool.global_transform * _dense_pts[i]).y)
		print("TRACE t=%.3f phase=%s stage=%s root_y=%.3f tool_low=%.3f action=%s g=%s" % [clock, bt.phase, bt.stage, bt._root.origin.y - _ground_y, low - _ground_y, str(wako.action), str(wako._pose.evaluated_grounded)])
	if args.has("trace_wait") and bt.phase == "back" and clock > float(_arg("trace_wait", "4.0")):
		print("WAIT t=%.3f stage=%s g=%s sole0=%.3f sole1=%.3f vel=%s gait=%.3f" % [clock, str(bt.stage), str(wako._pose.evaluated_grounded), Vector3(_leg_points(0)[3]).y - _ground_y, Vector3(_leg_points(1)[3]).y - _ground_y, str(wako.linear_velocity), wako.gait_speed])
	if not _t.has("retrieve_request") or _t.has("action_begin_seen"): return
	if bt.phase == "back":
		# Why the retrieval has not started yet (ticks per blocking gate).
		var why := []
		if not wako.on_ground: why.append("air")
		if not wako.is_available(): why.append("unavailable")
		if wako._pose.evaluated_grounded.count(true) != 2:
			why.append("grounded")
			for leg in 2:
				if not wako._pose.evaluated_grounded[leg]:
					why.append("ungrounded_%d%s" % [leg, "_tool" if leg == int(bt._foot_side) else ""])
					var sole_h: float = Vector3(_leg_points(leg)[3]).y - _ground_y
					m["ungrounded_sole_max_%d" % leg] = maxf(float(m.get("ungrounded_sole_max_%d" % leg, 0.0)), sole_h)
		if wako.gait_speed >= .08: why.append("gait")
		if (wako.linear_velocity - wako.ground_velocity).length() >= .08: why.append("speed")
		if absf(wako.turn_rate) > .15: why.append("turn")
		if int(bt._planted_ticks) < 2: why.append("planted")
		if bt._seat_settling: why.append("seat_settling")
		if float(bt._retrieval_retry) > 0.0: why.append("retry")
		if not wako._pose._work_release.is_empty() or wako._pose._travel_tool_handoff or wako._pose._travel_pole_handoff: why.append("pose_handoff")
		if wako.idle_play and str(wako.idle_play.state) != "": why.append("idle_play:" + str(wako.idle_play.state))
		if not wako.action.is_empty(): why.append("action")
		var wait: Dictionary = m.get("retrieve_wait", {})
		for k: String in why: wait[k] = int(wait.get(k, 0)) + 1
		wait.ticks = int(wait.get("ticks", 0)) + 1
		m.retrieve_wait = wait
	if bt.phase in ["retrieve", "return"] or (bt.phase == "foot" and not _t.has("action_begin")):
		var pts := _leg_points(int(bt._foot_side))
		var toe: Vector3 = pts[3]
		if _retr_last_toe.is_finite():
			var speed := toe.distance_to(_retr_last_toe) / delta
			if speed < .4: _still += delta
			else: _still = 0.0
			m.retrieval_longest_still = maxf(float(m.get("retrieval_longest_still", 0.0)), _still)
		_retr_last_toe = toe
		if bt.phase == "retrieve":
			var a := _leg_angles(bt, int(bt._foot_side))
			for key: String in ["line_abduction", "thigh_abduction", "line_from_vertical"]:
				m["reach_max_" + key] = maxf(float(m.get("reach_max_" + key, -INF)), float(a[key]))
			m["reach_min_thigh_flexion"] = minf(float(m.get("reach_min_thigh_flexion", INF)), float(a.thigh_flexion))
			var sole_h: float = Vector3(pts[3]).y - _ground_y
			m.reach_max_sole_height = maxf(float(m.get("reach_max_sole_height", 0.0)), sole_h)
		if bt.phase == "return" and is_instance_valid(tool):
			if not bt._return_local_waypoints.is_empty() and not m.has("return_route_pts"):
				var pts2 := []
				for w: Transform3D in bt._return_local_waypoints: pts2.append([w.origin, w.basis.y.normalized(), w.basis.x.normalized()])
				m.return_route_pts = pts2
				m.return_seg_t = []
			if m.has("return_seg_t") and (m.return_seg_t as Array).size() <= int(bt._path_index):
				(m.return_seg_t as Array).append([int(bt._path_index), snappedf(clock, .001), str(bt.stage)])
			var a2 := _leg_angles(bt, int(bt._foot_side))
			m.return_max_thigh_abduction = maxf(float(m.get("return_max_thigh_abduction", -INF)), float(a2.thigh_abduction))
			_dense_tool()
			var low := INF
			var xf := tool.global_transform
			for i in range(0, _dense_pts.size(), 3): low = minf(low, (xf * _dense_pts[i]).y)
			m.return_min_tool_floor = minf(float(m.get("return_min_tool_floor", INF)), low - _ground_y)
	if _t.has("action_begin"): _t.action_begin_seen = true

func _on_stage(from: String, to: String, bt: RefCounted) -> void:
	if to == "kick" and is_instance_valid(tool):
		m.cock_leg = _leg_angles(bt, int(bt._foot_side))
		_kick_sole_prev = bt._body_frame.affine_inverse() * Vector3(_leg_points(int(bt._foot_side))[3])
		_kick_sole0 = _kick_sole_prev
		_kick_sole_path = 0.0
		_kick_tick0 = _tick
	if to == "kick": _t.kick_start = clock
	if to == "reach" and not m.has("reach_route"):
		var inv: Transform3D = bt._body_frame.affine_inverse()
		var route := []
		for w: Transform3D in bt._waypoints: route.append(inv * w.origin)
		m.reach_route = route
		m.reach_hip = inv * Vector3(_leg_points(int(bt._foot_side))[0])

func _on_phase(from: String, to: String, bt: RefCounted) -> void:
	if to == "prepare" and not _t.has("prepare"): _t.prepare = clock
	if to == "flight" and not _t.has("launch"):
		_t.launch = clock
		_launch_pos = wako.global_position
		_launch_tool = tool.global_transform * tool.center_of_mass
		m.launch_speed = tool.linear_velocity.length()
		m.launch_velocity = tool.linear_velocity
		m.launch_spin = tool.angular_velocity
		m.launch_spin_rate = tool.angular_velocity.length()
		m.launch_impulse = bt.launch_impulse.length()
		m.launch_tool_height = _launch_tool.y - _ground_y
		m.release_leg = _leg_angles(bt, int(bt._foot_side))
		m.release_sole = _leg_points(int(bt._foot_side))[3]
		# Kick drive: the thigh's own flexion change and the kick sole's travel
		# (body frame, cock -> release), so a pure ankle flick reads as such.
		if m.has("cock_leg") and _kick_sole0.is_finite():
			var sole_now: Vector3 = bt._body_frame.affine_inverse() * Vector3(m.release_sole)
			_kick_sole_path += sole_now.distance_to(_kick_sole_prev)
			m.kick_thigh_flex_change = float(m.release_leg.thigh_flexion) - float(m.cock_leg.thigh_flexion)
			m.kick_sole_travel = _kick_sole_path
			m.kick_sole_disp = sole_now - _kick_sole0
			m.kick_ticks = _tick - _kick_tick0
		m.kick_dir = tool.linear_velocity.normalized()
		var toe_v: Vector3 = bt._toe_velocity if "_toe_velocity" in bt else Vector3.ZERO
		m.release_toe_speed = toe_v.length()
		m.release_toe_ratio = toe_v.length() / maxf(tool.linear_velocity.length(), .001)
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
		if _prev_tool_pos.is_finite():
			# World step of the tool over the contact tick (includes the body's own
			# travel) and the body-local step (tool relative to the cradle frame).
			m.catch_step_world = exact.origin.distance_to(_prev_tool_pos)
			var local_prev: Vector3 = _prev_body.affine_inverse() * _prev_tool_pos
			var local_now: Vector3 = bt._body_frame.affine_inverse() * exact.origin
			m.catch_step_body_local = local_now.distance_to(local_prev)
			# Deviation of the caught pose from the free ballistic path between the
			# last free tick and the next (a catch never teleports the body).
			var v0: Vector3 = _prev_tool_vel
			var best := INF
			for i in 21:
				var tau := float(i) / 20.0 * 1.25 / 120.0
				var p: Vector3 = _prev_tool_pos + v0 * tau + Vector3.DOWN * 4.9 * tau * tau
				best = minf(best, p.distance_to(exact.origin))
			m.catch_offset_from_ballistic_path = best
	if from == "back" and to == "retrieve": _t.retrieve = clock
	if from == "retrieve" and to == "return":
		_t.contact = clock
		m.retrieve_reach_time = clock - float(_t.get("retrieve_request", _t.retrieve))
	if from in ["retrieve", "return"] and to == "back":
		_event("retrieve_aborted_to_back")
		_t.retrieve_aborted = clock
	if from == "return" and to == "foot":
		_t.home = clock
		m.retrieval_time = clock - float(_t.get("retrieve_request", clock))
	if to == "foot" and from in ["prepare", "flight", "retrieve", "return", "back"] and not is_instance_valid(wako.equipped_tool):
		_t.dropped = clock
		m.dropped_from = from
		m.drop_reason = bt.reason

## ---- review checks (catch split, drop/restore, legs, cost) ---------------------
var _hist: Array = []
var _catches_seen := 0
var _post_catch := -1
var _catch_rec := {}
var _equipped_prev := false
var _drop_watch := -1
var _drop_rec := {}
var _restore_watch := -1
var _restore_rec := {}
var _last_us := 0
var _ticks: Array = []
var _tool_prev_v := Vector3.ZERO
var _tool_prev_p := Vector3.INF
var _wv_prev := Vector3.ZERO

func _cost(bt: RefCounted) -> void:
	var now := Time.get_ticks_usec()
	var frame_us := now - _last_us if _last_us > 0 else 0
	_last_us = now
	var posture: int = int(bt.get("ops_posture")) if bt.get("ops_posture") != null else 0
	var native: int = int(bt.get("ops_native")) if bt.get("ops_native") != null else 0
	if bt.get("ops_posture") != null:
		bt.ops_posture = 0
		bt.ops_native = 0
	var ph: String = bt.phase
	var st := _stage_name()
	if state in ["stow", "retrieve", "walk_after"] or ph != "foot":
		_ticks.append([_tick, ph, st, frame_us, posture, native])
	var key := ph + ":" + st
	if not chk.has("cost"): chk.cost = {}
	var row: Dictionary = chk.cost.get(key, {"ticks": 0, "ops_max": 0, "ops_sum": 0})
	row.ticks += 1
	row.ops_max = maxi(row.ops_max, posture + native)
	row.ops_sum += posture + native
	chk.cost[key] = row
	chk.total_ops = int(chk.get("total_ops", 0)) + posture + native
	if posture + native > int(chk.get("worst_tick_ops", 0)):
		chk.worst_tick_ops = posture + native
		chk.worst_tick = {"tick": _tick, "phase": ph, "stage": st, "posture": posture, "native": native}
	if posture + native > 160: chk.ticks_over_160 = int(chk.get("ticks_over_160", 0)) + 1

func _overlaps(shape_owner: CollisionShape3D, mask: int, rid: RID) -> bool:
	if not shape_owner or shape_owner.disabled: return false
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape_owner.shape
	q.transform = shape_owner.global_transform
	q.collision_mask = mask
	q.margin = 0.0
	for hit: Dictionary in get_world_3d().direct_space_state.intersect_shape(q, 32):
		if hit.rid == rid: return true
	return false

func _tool_overlap_report() -> Dictionary:
	var out := {}
	if not is_instance_valid(tool) or not is_instance_valid(wako): return out
	var capsule: CollisionShape3D
	for child: Node in wako.get_children():
		if child is CollisionShape3D and not child.disabled: capsule = child; break
	out.capsule_overlap = _overlaps(capsule, 0x7fffffff, tool.get_rid()) if wako.collision_layer != 0 else false
	out.exception_with_worker = wako in tool.get_collision_exceptions()
	var rag_overlap := false
	if wako.ragdoll and wako.ragdoll.active:
		for body in wako.ragdoll.rig.bodies:
			for child in body.rb.get_children():
				if child is CollisionShape3D and _overlaps(child, 0x7fffffff, tool.get_rid()): rag_overlap = true
	out.ragdoll_active = wako.ragdoll.active if wako.ragdoll else false
	out.ragdoll_overlap = rag_overlap
	return out

func _watch(delta: float, bt: RefCounted) -> void:
	var g := Vector3.DOWN * 9.8
	if is_instance_valid(tool):
		var p := tool.global_position
		var v := tool.linear_velocity
		var local: Transform3D = bt._root.affine_inverse() * tool.global_transform
		# The first tick after a load has no evaluated cube yet (its body frame
		# is the unposed skeleton): not a pose the tool was ever published in.
		if wako._pose and not wako._pose.evaluated_valid: return
		_hist.append({"tick": _tick, "pos": p, "vel": v, "carried": is_instance_valid(tool.carrier), "phase": str(bt.phase), "local": local, "body": bt._body_frame.affine_inverse() * tool.global_transform})
		if _hist.size() > 6: _hist.pop_front()
		if int(bt.catches) > _catches_seen:
			_catches_seen = int(bt.catches)
			_post_catch = 0
			var left := 0
			var right := 0
			for point: Vector3 in bt.last_contact_points:
				var lx: float = (bt._body_frame.affine_inverse() * point).x
				if lx < 0.0: left += 1
				else: right += 1
			_catch_rec = {"contact_points_left": left, "contact_points_right": right}
			if _hist.size() >= 3:
				# Body-local steps around the contact tick: the catch must not pop
				# back against the incoming motion or leave the free path.
				var a0: Vector3 = (_hist[-3].body as Transform3D).origin
				var b0: Vector3 = (_hist[-2].body as Transform3D).origin
				var c0: Vector3 = (_hist[-1].body as Transform3D).origin
				var s1 := b0 - a0
				var s2 := c0 - b0
				_catch_rec.pre_step_body_local = s1.length()
				_catch_rec.catch_step_body_local = s2.length()
				_catch_rec.catch_reversal = maxf(-s2.dot(s1.normalized()), 0.0) if s1.length() > 1e-6 else 0.0
				_catch_rec.catch_pop = float(m.get("catch_offset_from_ballistic_path", 0.0))
			var sm: Dictionary = bt.stunt_metrics() if bt.has_method("stunt_metrics") else {}
			for k: String in ["catch_trays", "catch_first_tray_depth", "catch_tau"]:
				if sm.has(k): _catch_rec[k] = sm[k]
			_catch_rec.max_world_step_after = 0.0
			_catch_rec.max_local_step_after = 0.0
			_catch_rec.launch_momentum = [bt.launch_before_momentum, bt.launch_after_momentum]
			_catch_rec.catch_momentum = [bt.catch_before_momentum, bt.catch_after_momentum]
			_catch_rec.contact_both_ticks = 0
			_catch_rec.contact_missing_ticks = 0
		elif _post_catch >= 0 and _post_catch < 45:
			_post_catch += 1
			if _hist.size() >= 2:
				var a: Dictionary = _hist[-2]
				var b: Dictionary = _hist[-1]
				_catch_rec.max_world_step_after = maxf(float(_catch_rec.max_world_step_after), (b.pos as Vector3).distance_to(a.pos))
				_catch_rec.max_local_step_after = maxf(float(_catch_rec.max_local_step_after), (b.local as Transform3D).origin.distance_to((a.local as Transform3D).origin))
			# Settle stays in contact with BOTH trays (the BackTool's own query).
			if bt.has_method("tray_contacts") and tool.carrier == bt.back_anchor:
				var trays: Array = bt.tray_contacts()
				if trays.size() == 2 and trays[0] and trays[1]: _catch_rec.contact_both_ticks += 1
				else:
					_catch_rec.contact_missing_ticks += 1
					var miss: Array = _catch_rec.get("missing_at", [])
					miss.append([_post_catch, trays])
					_catch_rec.missing_at = miss
			if _post_catch == 45: chk.catch = _catch_rec
		# Drop detection (equipped -> loose).
		var equipped: bool = is_instance_valid(wako.equipped_tool) and wako.equipped_tool == tool
		if _equipped_prev and not equipped and _drop_watch < 0:
			_drop_watch = 0
			_drop_rec = _tool_overlap_report()
			_drop_rec.phase_before = _prev_phase_tick
			_drop_rec.max_dv_anomaly = 0.0
			_drop_rec.start_speed = v.length()
			_drop_rec.worker_dv_max = 0.0
			_drop_rec.worker_dv_vertical_max = 0.0
			_drop_rec.tick = _tick
		elif _drop_watch >= 0 and _drop_watch < 120:
			_drop_watch += 1
			if _tool_prev_p.is_finite():
				var dv := (v - _tool_prev_v - g * delta).length()
				if p.y - _ground_y > .35: _drop_rec.max_dv_anomaly = maxf(float(_drop_rec.max_dv_anomaly), dv)
			var wv: Vector3 = wako.linear_velocity
			_drop_rec.worker_dv_max = maxf(float(_drop_rec.worker_dv_max), (wv - _wv_prev).slide(Vector3.UP).length())
			_drop_rec.worker_dv_vertical_max = maxf(float(_drop_rec.worker_dv_vertical_max), absf(wv.y - _wv_prev.y))
			if _drop_watch == 2: _drop_rec.overlap_after_2 = _tool_overlap_report()
			if _drop_watch == 120:
				_drop_rec.final_pos = p
				_drop_rec.final_speed = v.length()
				_drop_rec.exception_after_1s = wako in tool.get_collision_exceptions()
				_drop_rec.overlap_after_1s = _tool_overlap_report()
				chk.drop = _drop_rec
		_equipped_prev = equipped
		if _restore_watch >= 0 and _restore_watch < 120:
			if _restore_watch == 0:
				_restore_rec = _tool_overlap_report()
				_restore_rec.max_dv_anomaly = 0.0
				_restore_rec.worker_dv_max = 0.0
				_restore_rec.worker_dv_vertical_max = 0.0
			elif _tool_prev_p.is_finite():
				var dv2 := (v - _tool_prev_v - g * delta).length()
				if p.y - _ground_y > .35: _restore_rec.max_dv_anomaly = maxf(float(_restore_rec.max_dv_anomaly), dv2)
				_restore_rec.worker_dv_max = maxf(float(_restore_rec.worker_dv_max), (wako.linear_velocity - _wv_prev).slide(Vector3.UP).length())
				_restore_rec.worker_dv_vertical_max = maxf(float(_restore_rec.worker_dv_vertical_max), absf(wako.linear_velocity.y - _wv_prev.y))
			_restore_watch += 1
			if _restore_watch == 120: chk.restore = _restore_rec
		_tool_prev_v = v
		_tool_prev_p = p
	# Leg vs seated tool/holder clearance.
	if bt.phase == "back" and is_instance_valid(tool) and tool.carrier == bt.back_anchor:
		var c := _leg_clearance(bt)
		var bucket := "walk" if state == "walk_after" else "stand"
		if c < float(chk.get("leg_tool_clearance_min_" + bucket, INF)):
			chk["leg_tool_clearance_min_" + bucket] = c
			chk["leg_tool_clearance_at_" + bucket] = {"state": state, "tick": _tick, "speed": wako.linear_velocity.length()}
		if state == "walk_after": chk.walk_peak_speed = maxf(float(chk.get("walk_peak_speed", 0.0)), (wako.linear_velocity - wako.ground_velocity).slide(Vector3.UP).length())
	_wv_prev = wako.linear_velocity

var _pen := 0.0
func _segment_obb_distance(a: Vector3, b: Vector3, xf: Transform3D, box: AABB) -> float:
	var best := INF
	var inv := xf.affine_inverse()
	for i in 25:
		var q0: Vector3 = inv * a.lerp(b, float(i) / 24.0)
		var q := q0.clamp(box.position, box.end)
		var d := q0.distance_to(q)
		if d <= 0.0:
			var depth := minf(minf(minf(q0.x - box.position.x, box.end.x - q0.x), minf(q0.y - box.position.y, box.end.y - q0.y)), minf(q0.z - box.position.z, box.end.z - q0.z))
			_pen = maxf(_pen, depth)
		best = minf(best, d)
	return best

func _leg_clearance(bt: RefCounted) -> float:
	# Leg centre lines (hip-knee, knee-ankle) vs the seated tool's measured
	# keepout slices and the holder hardware. Leg radius is about 6 cm.
	var best := INF
	var boxes: Array = tool.get_meta(&"worker_tool_keepouts", [])
	var detail: Dictionary = chk.get("leg_detail", {})
	for side_index in 2:
		var pts := _leg_points(side_index)
		var segs := {"thigh": [pts[0], pts[1]], "shin": [pts[1], pts[2]]}
		for seg_name: String in segs:
			var a: Vector3 = segs[seg_name][0]
			var b: Vector3 = segs[seg_name][1]
			var tb := INF
			_pen = 0.0
			for box: AABB in boxes: tb = minf(tb, _segment_obb_distance(a, b, tool.global_transform, box))
			if tb < .06: chk.leg_tool_ticks_within_r = int(chk.get("leg_tool_ticks_within_r", 0)) + 1
			if tb <= 0.0:
				chk.leg_tool_ticks_inside = int(chk.get("leg_tool_ticks_inside", 0)) + 1
				chk.leg_tool_max_centerline_depth = maxf(float(chk.get("leg_tool_max_centerline_depth", 0.0)), _pen)
			var key := "tool_%s_%d" % [seg_name, side_index]
			if tb < float(detail.get(key, {}).get("d", INF)):
				detail[key] = {"d": tb, "state": state, "speed": snappedf(wako.linear_velocity.length(), .01), "tick": _tick}
			best = minf(best, tb)
			for child: Node in bt.holder.get_children():
				if child is MeshInstance3D and child.name != "RootSeat":
					var mi := child as MeshInstance3D
					var hb := _segment_obb_distance(a, b, mi.global_transform, mi.get_aabb())
					var hkey := "holder_%s_%s_%d" % [str(child.name), seg_name, side_index]
					if hb < float(detail.get(hkey, {}).get("d", INF)):
						detail[hkey] = {"d": hb, "state": state, "speed": snappedf(wako.linear_velocity.length(), .01), "tick": _tick}
					if hb < float(chk.get("leg_holder_clearance_min", INF)): chk.leg_holder_clearance_min = hb
	chk.leg_detail = detail
	return best

func _finish(why: String) -> void:
	if _done: return
	_done = true
	var bt := _bt()
	if not chk.has("catch") and not _catch_rec.is_empty(): chk.catch = _catch_rec
	if not chk.has("drop") and not _drop_rec.is_empty(): chk.drop = _drop_rec
	if not chk.has("restore") and not _restore_rec.is_empty(): chk.restore = _restore_rec
	m.chk = chk
	m.result = why
	m.identity_same = _identity_ok
	m.mass_conserved = _mass_ok
	m.final_phase = bt.phase if bt else ""
	m.final_carrier = "none"
	if is_instance_valid(tool) and is_instance_valid(tool.carrier):
		m.final_carrier = "back" if tool.carrier == bt.back_anchor else ("foot" if tool.carrier == wako.tool_anchor else str(tool.carrier.name))
	m.final_equipped = is_instance_valid(wako) and wako.equipped_tool == tool and is_instance_valid(tool)
	m.final_busy = bt.busy() if bt else false
	m.final_blocks_navigation = bt.blocks_navigation() if bt else false
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
	var path := _arg("ticks_out", "")
	if not path.is_empty():
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(_ticks))
			f.close()
	print("BACK_STUNT_METRICS ", JSON.stringify(m))
	if args.has("assert"): _assertions()
	if args.has("quit"):
		await get_tree().create_timer(.2).timeout
		get_tree().quit()

## ---- packaged regression assertions (--assert) ------------------------------
## One PASS/FAIL line per scenario for harness/run_back_checks.sh: custody and
## identity, both-tray catch and in-contact settle, retrieval, worker dv and
## overlap/exception after any loose release, leg clearance while walking,
## no soft-lock (never busy at the end), honest save restores, tick cost.
func _assertions() -> void:
	var fails := 0
	var count := 0
	var checks: Array = []
	var knock := args.has("knock")
	var plain := not args.has("interrupt") and not args.has("save") and not args.has("ceiling") and not knock and not args.has("fear") and not args.has("hit_kick_rel")
	checks.append(["same native tool and mass throughout", bool(m.get("identity_same", false)) and bool(m.get("mass_conserved", false))])
	checks.append(["never left busy (no soft-lock)", not bool(m.get("final_busy", true))])
	var holder: Dictionary = m.get("holder", {})
	if holder.has("strap_gap_max"):
		checks.append(["both straps sit on the skin (gap <= 1.5 cm, no penetration)", int(holder.get("strap_count", 0)) == 2 and float(holder.strap_gap_max) <= .015 and float(holder.strap_gap_min) >= -.0005])
	var drop: Dictionary = chk.get("drop", {})
	if not drop.is_empty():
		var after: Dictionary = drop.get("overlap_after_1s", {})
		checks.append(["loose release: no capsule/ragdoll overlap or exception 1 s later", not bool(after.get("capsule_overlap", false)) and not bool(after.get("ragdoll_overlap", false)) and not bool(drop.get("exception_after_1s", false))])
		# A hit/knock already shoves the Wako; a tool shed from the air after it
		# may land on it (solid, never through it).
		if not knock and not args.has("hit") and not args.has("hit_kick_rel"): checks.append(["loose release: worker horizontal dv < .1 m/s", float(drop.get("worker_dv_max", 0.0)) < .1])
	if plain or (args.has("interrupt") and str(_arg("interrupt", "")) in ["rising", "apex", "falling", "late", "settle", "reach", "contact"]):
		var catch: Dictionary = chk.get("catch", {})
		checks.append(["caught on BOTH trays and settled in contact", catch.get("catch_trays", []) == [true, true] and int(catch.get("contact_missing_ticks", 1)) == 0])
		checks.append(["complete stow and retrieval onto the foot", str(m.get("result", "")) == "complete" and str(m.get("final_carrier", "")) == "foot"])
		checks.append(["catch orientation error < 8 deg", float(m.get("catch_orientation_error_deg", 99.0)) < 8.0])
		checks.append(["no part of the tool passes through the tray hardware in flight (<= .5 mm)", float(chk.get("hw_pen_flight_max", 0.0)) <= .0005])
	var catch_rec: Dictionary = chk.get("catch", {})
	if catch_rec.has("catch_reversal"):
		# Contact is detected on the tick it happens; the body stops on its own
		# free path (no penetrated pose is published, no step back).
		checks.append(["catch pose on the free path (pop <= 1 cm) with no step back (<= 2 mm)", float(catch_rec.get("catch_pop", 1.0)) <= .01 and float(catch_rec.get("catch_reversal", 1.0)) <= .002])
	if plain and m.has("kick_thigh_flex_change"):
		# The leg drives the kick (not an ankle flick), and the wind-up is a
		# moving counter-swing (no held frame) that drops the tool first.
		checks.append(["hip-driven kick: thigh flexion +15 deg or more, sole travel >= .20 m", float(m.get("kick_thigh_flex_change", 0.0)) >= 15.0 and float(m.get("kick_sole_travel", 0.0)) >= .20])
		checks.append(["anticipation keeps moving (still <= .07 s) and dips the tool >= 5 cm", float(m.get("prepare_longest_still", 1.0)) <= .07 and float(m.get("windup_dip", 0.0)) >= .05])
	if plain and not args.has("walk") and not args.has("depart"):
		checks.append(["retrieval under 2 s from a standstill", float(m.get("retrieval_time", 99.0)) < 2.0])
		checks.append(["per-tick query cost <= 170 ops", int(chk.get("worst_tick_ops", 9999)) <= 170])
		checks.append(["retrieval: thigh abduction <= 35 deg, tool >= 5 cm off the floor on the way home",
			float(m.get("reach_max_thigh_abduction", 99.0)) <= 35.0 and float(m.get("return_max_thigh_abduction", 99.0)) <= 35.0 and float(m.get("return_min_tool_floor", 0.0)) >= .05])
		var seated: Dictionary = m.get("seated", {})
		checks.append(["seated silhouette: <= 20 cm past the cube's sides, <= 8 cm below it",
			float(seated.get("silhouette_side_overhang", 1.0)) <= .20 and float(seated.get("silhouette_bottom_hang", 1.0)) <= .08])
	if args.has("walk") or args.has("depart"):
		checks.append(["legs keep >= 5 cm from the seated tool and holder while walking", float(chk.get("leg_tool_clearance_min_walk", 0.0)) >= .05 and float(chk.get("leg_holder_clearance_min", 0.0)) >= .05])
	if args.has("interrupt") and str(_arg("interrupt", "")) in ["gather", "hold", "kick", "draw", "home"]:
		checks.append(["interrupt keeps the tool on the foot without a jump (<= 5 cm/tick off its path)", str(m.get("final_carrier", "")) == "foot" and not _t.has("dropped") and float(m.get("interrupt_max_tool_step", 1.0)) <= .05])
	if args.has("hit_kick_rel"):
		# A recoil-strength hit around the release: the tool stays on the foot,
		# is caught, or lands loose - never through the body.
		checks.append(["hit around release: the tool never passes through the body (<= 5 mm)", int(chk.get("cube_pen_ticks", 0)) == 0])
	if args.has("fear"):
		if args.has("hit"):
			# A shove can carry the cradle out from under the tool: then the same
			# body lands loose beside it, never through it or lodged in the capsule.
			checks.append(["hit in flight: caught on both trays, or lands loose clear of the body", (catch_rec.get("catch_trays", []) == [true, true] and not _t.has("dropped")) or (_t.has("dropped") and float(chk.get("loose_cube_pen_max", 1.0)) <= .005)])
			if float(_arg("hit_speed", "1.0")) > 2.5:
				# A recoil-strength hit: exactly one held reaction clip (no sliver
				# now and a second generic reaction after the catch).
				var reactions := 0
				for clip: Array in m.get("reaction_clips", []):
					if (str(clip[0]).begins_with("recoil/") or str(clip[0]).ends_with("interrupted_L") or str(clip[0]).ends_with("interrupted_R")) and float(clip[2]) > .1: reactions += 1
				checks.append(["recoil hit in flight: one reaction, not two", reactions == 1])
		else:
			checks.append(["fright in flight: still caught on both trays, never through the body", catch_rec.get("catch_trays", []) == [true, true] and not _t.has("dropped") and float(chk.get("loose_cube_pen_max", 0.0)) <= .005])
	if m.get("save") is Dictionary:
		checks.append(["save restore never fabricates a catch", not bool((m.save as Dictionary).get("catch_fabricated", true))])
		if str(_arg("save", "")) == "back_v2":
			var seated: Dictionary = m.get("seated_after_restore", {})
			checks.append(["old v2 save migrates onto the worn seat (tool <= 1.5 cm off the plate)", bool((m.save as Dictionary).get("migrated", false)) and float(seated.get("tool_plate_gap", 1.0)) <= .015])
		if str(_arg("save", "")) == "return":
			checks.append(["save on the way home restores the same tool on the foot", str((m.save as Dictionary).get("carrier", "")) == "foot" and str(m.get("final_carrier", "")) == "foot"])
	for item: Array in checks:
		count += 1
		if not bool(item[1]): fails += 1
		print("BACK_STUNT_CHECK %s %s" % ["ok" if bool(item[1]) else "FAIL", item[0]])
	print("BACK_STUNT %s %d checks" % ["PASS" if fails == 0 else "FAIL (%d)" % fails, count])

var _fixed_set := false
var _fixed_cam := Vector3.ZERO
var _fixed_tgt := Vector3.ZERO

func _process(delta: float) -> void:
	super(delta)
	if args.has("fixed") and frame > 40:
		if not _fixed_set:
			_fixed_set = true
			_fixed_cam = camera.global_position
			_fixed_tgt = cam_target
		camera.global_position = _fixed_cam
		camera.look_at(_fixed_tgt + Vector3(0, cam_lift, 0), Vector3.UP)
	elif cam_lift != 0.0: camera.look_at(cam_target + Vector3(0, cam_lift, 0), Vector3.UP)
	if args.has("fov"): camera.fov = float(_arg("fov", "50"))
	if args.has("noshadow") and frame == 3:
		for n: Node in get_children():
			if n is DirectionalLight3D: (n as DirectionalLight3D).shadow_enabled = false
	if args.has("win"):
		var on := false
		for w: String in _arg("win", "").split(";"):
			var ab := w.split("-")
			if clock >= float(ab[0]) and clock <= float(ab[1]): on = true
		get_viewport().disable_3d = not on
	if not _done and args.has("quit") and clock > 40.0: _finish("wall_timeout")

## ---- Round-3 probes ----------------------------------------------------------
## Tool visual (dense 1 cm samples) vs every piece of tray hardware - rubber
## base and its two lips, bronze shelf, gusset - and the plate, from launch
## through the settle and during retrieval; cube penetration in every phase;
## the kick's leg drive; stillness/stalls through the gather and wind-up; an
## optional recoil-strength hit k ticks after the kick starts (--hit_kick_rel).
var _kick_sole0 := Vector3.INF
var _kick_sole_prev := Vector3.INF
var _kick_sole_path := 0.0
var _kick_tick0 := 0
var _dense_pts := PackedVector3Array()
var _dense_bands := {}
var _prep_prev_com := Vector3.INF
var _prep_still := 0.0
var _gather_moving := false
var _hit_kick_done := false

func _dense_tool() -> void:
	if not _dense_pts.is_empty(): return
	var inv := tool.global_transform.affine_inverse()
	for node: Node in tool.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if not mi.mesh or not mi.is_visible_in_tree(): continue
		var xf: Transform3D = inv * mi.global_transform
		for s in mi.mesh.get_surface_count():
			var arr: Array = mi.mesh.surface_get_arrays(s)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if idx.is_empty():
				for i in v.size(): idx.append(i)
			for t in range(0, idx.size() - 2, 3):
				var a: Vector3 = xf * v[idx[t]]
				var b: Vector3 = xf * v[idx[t + 1]]
				var c: Vector3 = xf * v[idx[t + 2]]
				for e: Array in [[a, b], [b, c], [c, a]]:
					var n := maxi(1, ceili((e[0] as Vector3).distance_to(e[1]) / .01))
					for k in n: _dense_pts.append((e[0] as Vector3).lerp(e[1], float(k) / n))
				_dense_pts.append((a + b + c) / 3.0)
	# Packed arrays are values in a Dictionary: build plain arrays first.
	var bands := {}
	for i in _dense_pts.size():
		var band := floori(_dense_pts[i].y / .01)
		if not bands.has(band): bands[band] = []
		(bands[band] as Array).append(i)
	for band: int in bands: _dense_bands[band] = PackedInt32Array(bands[band])

func _hardware_boxes(bt: RefCounted) -> Array:
	# [label, world transform (orthonormal), local AABB (metres)] per solid piece.
	var out: Array = []
	var groups := {"rubber": bt._seat_models, "shelf": bt._drop_arms, "gusset": bt._gussets}
	for kind: String in groups:
		var nodes: Array = groups[kind]
		for i in nodes.size():
			var mi: MeshInstance3D = nodes[i]
			if not is_instance_valid(mi) or not mi.visible: continue
			var g: Transform3D = mi.global_transform
			var sc: Vector3 = g.basis.get_scale()
			var xf := Transform3D(g.basis.orthonormalized(), g.origin)
			if kind == "rubber":
				var p: Vector3 = HolderVisual.PAD_SIZE * sc
				var lh: float = HolderVisual.LIP_HEIGHT * sc.y
				var lw: float = HolderVisual.LIP_WIDTH * sc.z
				out.append(["%s%d" % [kind, i], xf, AABB(-p * .5, p)])
				out.append(["lip%d" % i, xf, AABB(Vector3(-p.x * .5, p.y * .5, p.z * .5 - lw), Vector3(p.x, lh, lw))])
				out.append(["lip%d" % i, xf, AABB(Vector3(-p.x * .5, p.y * .5, -p.z * .5), Vector3(p.x, lh, lw))])
			else:
				var box: AABB = mi.mesh.get_aabb()
				out.append(["%s%d" % [kind, i], xf, AABB(box.position * sc, box.size * sc)])
	for child: Node in bt.holder.get_children():
		if child is MeshInstance3D and child.name == "RootSeat":
			var seat_mi := child as MeshInstance3D
			out.append(["plate", seat_mi.global_transform, seat_mi.mesh.get_aabb()])
	return out

func _hardware_pen(bt: RefCounted) -> Dictionary:
	# Deepest tool-visual sample inside each hardware piece (metres).
	_dense_tool()
	var out := {}
	var txf := tool.global_transform
	var com := txf * tool.center_of_mass
	for item: Array in _hardware_boxes(bt):
		var xf: Transform3D = item[1]
		var box: AABB = item[2]
		if xf.origin.distance_to(com) > .62 + box.size.length() * .5: continue
		var to_local: Transform3D = xf.affine_inverse() * txf
		var to_tool: Transform3D = txf.affine_inverse() * xf
		var lo := INF
		var hi := -INF
		for c in 8:
			var q: Vector3 = to_tool * box.get_endpoint(c)
			lo = minf(lo, q.y)
			hi = maxf(hi, q.y)
		var depth := 0.0
		for band in range(floori(lo / .01), floori(hi / .01) + 1):
			if not _dense_bands.has(band): continue
			for i: int in _dense_bands[band]:
				var q: Vector3 = to_local * _dense_pts[i]
				if box.has_point(q):
					depth = maxf(depth, minf(minf(minf(q.x - box.position.x, box.end.x - q.x), minf(q.y - box.position.y, box.end.y - q.y)), minf(q.z - box.position.z, box.end.z - q.z)))
		if depth > 0.0:
			var label: String = item[0]
			out[label] = maxf(float(out.get(label, 0.0)), depth)
	return out

func _r3_probe(delta: float, bt: RefCounted) -> void:
	if not is_instance_valid(tool) or not is_instance_valid(wako): return
	if wako._pose and not wako._pose.evaluated_valid: return
	var phase: String = bt.phase
	var stage := _stage_name()
	# Recoil-strength hit swept around the release tick.
	if args.has("hit_kick_rel") and not _hit_kick_done and m.has("cock_leg") and _tick - _kick_tick0 >= int(_arg("hit_kick_rel", "0")):
		_hit_kick_done = true
		chk.hit_kick = {"tick": _tick, "rel": _tick - _kick_tick0, "phase": phase, "stage": stage}
		_interrupt_t = clock
		_loose_watch = 0
		wako.apply_hit(-wako._model.global_basis.x * wako.mass * float(_arg("hit_speed", "3.0")) * float(_arg("hit_dir", "1")))
	# Cube penetration of the tool visual in every phase (custody or loose).
	var pen := _cube_penetration(bt)
	if pen > 0.0:
		var key := phase + ":" + stage + (":loose" if not is_instance_valid(tool.carrier) else "")
		var by: Dictionary = chk.get("cube_pen_by_phase", {})
		by[key] = maxf(float(by.get(key, 0.0)), pen)
		chk.cube_pen_by_phase = by
		if pen > .005: chk.cube_pen_ticks = int(chk.get("cube_pen_ticks", 0)) + 1
	# Tool vs tray hardware from launch through the settle, and while the
	# empty foot reaches and draws the tool out.
	var window := phase in ["flight", "retrieve", "return"] or (phase == "back" and _t.has("catch") and clock - float(_t.catch) < .6)
	if window and _t.has("launch"):
		var hw := _hardware_pen(bt)
		if not hw.is_empty():
			var bucket := phase + ("" if is_instance_valid(tool.carrier) else ":loose")
			var rec: Dictionary = chk.get("hw_pen", {})
			var row: Dictionary = rec.get(bucket, {})
			for label: String in hw:
				var depth: float = hw[label]
				if depth > float(row.get(label, [0.0])[0]): row[label] = [snappedf(depth, .0001), snappedf(clock, .001)]
			rec[bucket] = row
			chk.hw_pen = rec
			if phase == "flight" and is_instance_valid(tool) and not is_instance_valid(tool.carrier) and wako.equipped_tool == tool:
				var worst := 0.0
				for label: String in hw: worst = maxf(worst, float(hw[label]))
				chk.hw_pen_flight_max = maxf(float(chk.get("hw_pen_flight_max", 0.0)), worst)
	# Gather/wind-up: the tool never stops dead between start and release.
	if phase == "prepare" and tool.carrier == wako.tool_anchor and stage in ["gather", "hold", "windup", "kick"]:
		var com_local: Vector3 = bt._body_frame.affine_inverse() * (tool.global_transform * tool.center_of_mass)
		if _prep_prev_com.is_finite():
			var speed := com_local.distance_to(_prep_prev_com) / delta
			# Reads as a held pose: under ~1 cm per 60 fps frame.
			if speed < .6 and (bt._stage_age > .10 or stage != "gather"):
				_prep_still += delta
			else: _prep_still = 0.0
			m.prepare_longest_still = maxf(float(m.get("prepare_longest_still", 0.0)), _prep_still)
			if stage == "gather":
				if speed > .5: _gather_moving = true
				elif speed < .2 and _gather_moving:
					_gather_moving = false
					m.gather_stalls = int(m.get("gather_stalls", 0)) + 1
			# Counter-motion: the COM drops during the wind-up before the kick.
			if stage in ["hold", "windup"]: m.windup_dip = maxf(float(m.get("windup_dip", 0.0)), float(m.get("_windup_top", com_local.y)) - com_local.y)
			if stage == "gather": m._windup_top = com_local.y
		_prep_prev_com = com_local
	# Kick sole path (body frame) from the cocked pose to the release.
	if phase == "prepare" and stage == "kick" and _kick_sole_prev.is_finite():
		var sole: Vector3 = bt._body_frame.affine_inverse() * Vector3(_leg_points(int(bt._foot_side))[3])
		_kick_sole_path += sole.distance_to(_kick_sole_prev)
		_kick_sole_prev = sole

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
	# Lowest holder hardware point (body frame) vs the cube's bottom edge.
	var lowest := INF
	var widest := 0.0
	for child: Node in bt.holder.get_children():
		if child is MeshInstance3D and child.name != "RootSeat":
			var mi := child as MeshInstance3D
			for c in 8:
				var q: Vector3 = mi.transform * mi.get_aabb().get_endpoint(c)
				lowest = minf(lowest, q.y)
				widest = maxf(widest, absf(q.x))
	out.hardware_lowest_y = lowest
	out.hardware_above_cube_bottom = lowest - (-.2625)
	out.hardware_max_abs_x = widest
	var straps := _strap_gaps(bt)
	for key: String in straps: out[key] = straps[key]
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
			var top := -INF
			var bottom := INF
			for box: AABB in tool.get_meta(&"worker_tool_keepouts", []):
				for c in 8:
					var q: Vector3 = inv * box.get_endpoint(c)
					front = minf(front, q.z)
					top = maxf(top, q.y)
					bottom = minf(bottom, q.y)
			# Visual silhouette vs the cube's back outline (x +-.405, y -.2625..roof .3376).
			_dense_tool()
			var lo := Vector3.INF
			var hi := -Vector3.INF
			var low_at := Vector3.ZERO
			for i in range(0, _dense_pts.size(), 2):
				var q2: Vector3 = inv * _dense_pts[i]
				if q2.y < lo.y: low_at = q2
				lo = lo.min(q2)
				hi = hi.max(q2)
			out.silhouette_lowest_point = low_at
			out.silhouette_x = [lo.x, hi.x]
			out.silhouette_y = [lo.y, hi.y]
			out.silhouette_side_overhang = maxf(0.0, maxf(hi.x - .405, -.405 - lo.x))
			out.silhouette_bottom_hang = maxf(0.0, -.2625 - lo.y)
			out.silhouette_top_over_roof = hi.y - .3376
			out.tool_front_z = front
			out.tool_plate_gap = front - outer_max
			out.tool_top_y = top
			out.tool_top_above_roof = top - .3376
			out.tool_bottom_y = bottom
			var native_front := INF
			for shape: Node in tool.find_children("*", "CollisionShape3D", true, false):
				var cs := shape as CollisionShape3D
				if cs.disabled or not cs.shape is BoxShape3D: continue
				var half: Vector3 = (cs.shape as BoxShape3D).size * .5
				var local: Transform3D = bt.holder.global_transform.affine_inverse() * cs.global_transform
				for c in 8: native_front = minf(native_front, (local * (AABB(-half, half * 2.0).get_endpoint(c))).z)
			out.tool_native_front_z = native_front
			out.seat_local = bt.holder.global_transform.affine_inverse() * tool.global_position
			var grip: Vector3 = inv * Vector3(0, -.035 - float(tool.definition.size.y) * .45, 0)
			out.grip_local = grip
	return out

## Straps vs the real skin (independent of how they were built): every unique
## strap vertex's signed distance to the nearest root-rigid back/roof skin
## triangle. min < 0 = penetration; max - thickness bounds the inner face's
## gap anywhere along the strap (a floating strap shows up here).
func _strap_gaps(bt: RefCounted) -> Dictionary:
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
			if maxf(p0.z, maxf(p1.z, p2.z)) < .05: continue
			var box := AABB(p0, Vector3.ZERO).expand(p1).expand(p2).grow(.05)
			tris.append([p0, p1, p2, -(p1 - p0).cross(p2 - p0).normalized(), box])
	var out := {"strap_count": 0}
	var lowest := INF
	var highest := -INF
	var top := -INF
	for strap: MeshInstance3D in bt._straps:
		out.strap_count = int(out.strap_count) + 1
		var seen := {}
		var arrays := strap.mesh.surface_get_arrays(0)
		for v: Vector3 in arrays[Mesh.ARRAY_VERTEX]:
			var p: Vector3 = strap.transform * v
			var key := p.snapped(Vector3.ONE * .0001)
			if seen.has(key): continue
			seen[key] = true
			top = maxf(top, p.y)
			var best := INF
			var signed := 0.0
			for t: Array in tris:
				if not (t[4] as AABB).has_point(p): continue
				var q := _closest_on_triangle(p, t[0], t[1], t[2])
				var d := p.distance_to(q)
				if d < best:
					best = d
					signed = d if (p - q).dot(t[3]) >= -1e-5 else -d
			lowest = minf(lowest, signed)
			highest = maxf(highest, best)
	if int(out.strap_count) > 0:
		out.strap_gap_min = lowest
		out.strap_gap_max = highest - HolderVisual.STRAP_SIZE.z
		out.strap_top_y = top
	return out

static func _closest_on_triangle(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	# Ericson, Real-Time Collision Detection 5.1.5.
	var ab := b - a; var ac := c - a; var ap := p - a
	var d1 := ab.dot(ap); var d2 := ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0: return a
	var bp := p - b
	var d3 := ab.dot(bp); var d4 := ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3: return b
	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0: return a + ab * (d1 / (d1 - d3))
	var cp := p - c
	var d5 := ab.dot(cp); var d6 := ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6: return c
	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0: return a + ac * (d2 / (d2 - d6))
	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0: return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	var denom := 1.0 / (va + vb + vc)
	return a + ab * (vb * denom) + ac * (vc * denom)

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

extends "res://harness/scripts/stage.gd"
## Head-first pickup lab. Drives the real head_leap (begin_group / contact_ready
## / attach_group) and wako_pickup controllers directly with real contraption
## parts, standing in for the coordinator/yard calls, and prints metrics.
## User args: --case=solo|large|crew|obstacle|interrupt|hit|save|toss
##            --view=side|34|front  --out=<json path>  --slowmo=<time scale>
const Part := preload("res://Components/Contraptions/contraption_part.gd")
const HeadLeap := preload("res://LogicObjects/Wako/wako_head_leap.gd")
const Probe := preload("res://harness/scripts/head_leap_probe.gd")
const Catalogue := preload("res://Components/Contraptions/part_catalog.gd")

var case_name := "solo"
var view := "side"
var out_path := ""
var crew: Array = []
var part: RigidBody3D
var probe: Node
var stage_name := "settle"
var stage_clock := 0.0
var attempts := 0
var refusals: Array[String] = []
var outcome: Dictionary = {}
var _attached := false
var _finished_at := -1.0
var _saved: Dictionary = {}
var _restored: RigidBody3D
var _restored_all: Array = []
var _toss: Dictionary = {}
var _part_prev := Transform3D.IDENTITY
var _reported := false
var interrupt_at := .42
var interrupt_state := "outbound"
var heading := 0.0
var save_state := "return"
var save_at := .3
var crew_gap := 1.0
var gap := 1.35
var trace_path := ""
var push_kind := "toward"
var push_at := .5
var crate: RigidBody3D

func setup() -> void:
	# The lab reads the controller's per-tick force/torque statistics.
	var controller_script: Script = HeadLeap
	controller_script.set("profile_stats", true)
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--case="): case_name = arg.trim_prefix("--case=")
		if arg.begins_with("--view="): view = arg.trim_prefix("--view=")
		if arg.begins_with("--out="): out_path = arg.trim_prefix("--out=")
		if arg.begins_with("--slowmo="): Engine.time_scale = float(arg.trim_prefix("--slowmo="))
		if arg.begins_with("--interrupt-at="): interrupt_at = float(arg.trim_prefix("--interrupt-at="))
		if arg.begins_with("--interrupt-state="): interrupt_state = arg.trim_prefix("--interrupt-state=")
		if arg.begins_with("--heading="): heading = deg_to_rad(float(arg.trim_prefix("--heading=")))
		if arg.begins_with("--save-state="): save_state = arg.trim_prefix("--save-state=")
		if arg.begins_with("--save-at="): save_at = float(arg.trim_prefix("--save-at="))
		if arg.begins_with("--crew-gap="): crew_gap = float(arg.trim_prefix("--crew-gap="))
		if arg.begins_with("--gap="): gap = float(arg.trim_prefix("--gap="))
		if arg.begins_with("--trace="): trace_path = arg.trim_prefix("--trace=")
		if arg.begins_with("--push="): push_kind = arg.trim_prefix("--push=")
		if arg.begins_with("--push-at="): push_at = float(arg.trim_prefix("--push-at="))
	var focus := Vector3(0, .75, -.8)
	match case_name:
		"solo", "interrupt", "hit", "save", "push":
			part = _part("bracket", Vector3(0, .15, -(gap+.15)))
			crew = [spawn_wako(Vector3(0, 1.0, 0), "leap_solo")]
		"large":
			# 48 kg flux generator: outside the small-stock limits (> 35 kg).
			part = _part("generator", Vector3(0, .325, -(gap+.475)))
			crew = [spawn_wako(Vector3(0, 1.0, 0), "leap_large")]
			focus = Vector3(0, .8, -1.0)
		"crew", "crew_save", "crew_interrupt", "crew_obstacle":
			# 32 kg cut armour plate (1.2 m face): one shared two-Wako job.
			part = _part("armor", Vector3(0, .075, -(crew_gap+.6)))
			crew = [spawn_wako(Vector3(-.49, 1.0, 0), "leap_crew_a"), spawn_wako(Vector3(.49, 1.0, 0), "leap_crew_b")]
			focus = Vector3(0, .8, -.85)
			if case_name == "crew_obstacle":
				# A 1.05 m screen across both launch places (crew fallback tiers).
				add_box(Vector3(0, .525, -.8), Vector3(2.6, 1.05, .08), Color(.55, .42, .32))
		"stack":
			# The stock rests on a loose 25 kg crate: the push-off reactions act
			# on a movable, possibly sleeping support.
			crate = RigidBody3D.new()
			crate.mass = 25.0
			var crate_shape := CollisionShape3D.new()
			var crate_box := BoxShape3D.new()
			crate_box.size = Vector3(.7, .3, .7)
			crate_shape.shape = crate_box
			crate.add_child(crate_shape)
			var crate_mesh := MeshInstance3D.new()
			var crate_visual := BoxMesh.new()
			crate_visual.size = crate_box.size
			crate_mesh.mesh = crate_visual
			crate.add_child(crate_mesh)
			crate.position = Vector3(0, .15, -(gap+.15))
			add_child(crate)
			part = _part("bracket", Vector3(0, .45, -(gap+.15)))
			crew = [spawn_wako(Vector3(0, 1.0, 0), "leap_stack")]
		"obstacle":
			# A 1.05 m screen between launch place and stock rejects the brisk
			# short arcs; clearance must fall back to the long original plans.
			part = _part("bracket", Vector3(0, .15, -1.75))
			add_box(Vector3(0, .525, -.86), Vector3(1.4, 1.05, .08), Color(.55, .42, .32))
			crew = [spawn_wako(Vector3(0, 1.0, 0), "leap_obstacle")]
			focus = Vector3(0, .9, -.9)
		"toss":
			part = _part("light", Vector3(0, .11, -.42))
			# The harness eye-lamp visual is a smaller stub than the real 0.22 m
			# collision box: render the collision box itself (render-only).
			for node: Node in part.find_children("*", "MeshInstance3D", true, false): node.visible = false
			_ensure_visual(part)
			crew = [spawn_wako(Vector3(0, 1.0, 0), "leap_toss")]
			focus = Vector3(0, .9, -.2)
	if heading != 0.0:
		# Same layout turned about the launch place (direction-invariance check).
		for node: Node3D in crew + [part]:
			node.global_position = node.global_position.rotated(Vector3.UP, heading)
			if node == part: node.rotate_y(heading)
		focus = focus.rotated(Vector3.UP, heading)
	cam_target = focus
	var distance := 3.6 if case_name != "crew" else 4.0
	cam_target.y += .15
	match view:
		"side": cam_offset = Vector3(distance+.2, .55, 0)
		"34": cam_offset = Vector3(distance*.68, 1.15, distance*.68)
		"front": cam_offset = Vector3(.4, .6, -distance)
	probe = Probe.new()
	probe.trace_path = trace_path
	add_child(probe)
	probe.watch(crew, part)

func _part(kind: String, at: Vector3, rot := Vector3.ZERO) -> RigidBody3D:
	var p: RigidBody3D = Part.new()
	p.setup(kind, "leap_" + kind, true)
	p.position = at
	p.rotation_degrees = rot
	add_child(p)
	_ensure_visual(p)
	return p

func _ensure_visual(p: RigidBody3D) -> void:
	# Some part visuals are auto-stubs in this harness. Render-only stand-in:
	# a box of the real catalogue bounds (no physics, not game code).
	var visible_mesh := false
	for node: Node in p.find_children("*", "MeshInstance3D", true, false):
		if node.mesh and node.is_visible_in_tree(): visible_mesh = true
	if visible_mesh: return
	var bounds: AABB = Catalogue.bounds_of(p.definition)
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = bounds.size
	mesh.mesh = box
	mesh.position = bounds.get_center()
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(.86, .52, .22)
	material.roughness = .6
	mesh.material_override = material
	p.add_child(mesh)

func _settled(w: RigidBody3D) -> bool:
	return w.on_ground and w._pose.evaluated_valid and w._pose.evaluated_grounded.all(func(v: bool) -> bool: return v) \
		and w.linear_velocity.length() < .12 and w.angular_velocity.length() < .15 and w.action.is_empty() \
		and w._animation.current_animation == "wk_idle" and w._animation.current_animation_position >= .24

func scenario(delta: float) -> void:
	stage_clock += delta
	if case_name == "toss":
		_toss_scenario(delta)
		return
	var leader: RigidBody3D = null
	if not crew.is_empty() and is_instance_valid(crew[0]): leader = crew[0]
	match stage_name:
		"settle":
			# Each member faces its own contact column (crew contacts sit at +-.49).
			for w: RigidBody3D in crew: w.face_point(Vector3(w.global_position.x, part.global_position.y, part.global_position.z) if crew.size() > 1 else part.global_position)
			caption("%s · settling" % case_name)
			if clock < 1.6 or not crew.all(_settled) or part.linear_velocity.length() > .05: return
			var started := Time.get_ticks_usec()
			var blocker: String = HeadLeap.begin_group(part, crew)
			outcome.begin_group_ms = (Time.get_ticks_usec()-started)/1000.0
			attempts += 1
			if not blocker.is_empty():
				refusals.append(blocker)
				print("LEAP_REFUSED ", blocker)
				if attempts >= 4: _finish("refused")
				stage_clock = -.5
				return
			stage_name = "leap"
			stage_clock = 0.0
		"leap":
			if not is_instance_valid(leader): return
			var leap: RefCounted = leader.head_leap
			caption("%s · %s %.2fs" % [case_name, leap.state, leap.elapsed])
			# Coordinator stand-ins: cancel / external hit / save during flight.
			_watch_safety()
			if case_name == "push" and leap.state == "outbound" and leap.elapsed >= push_at and not outcome.has("pushed"):
				# The stock is knocked mid-dive: toward the incoming head, or sideways.
				var impulse := Vector3(0, 2.2, 1.6) if push_kind == "toward" else Vector3(2.0, .5, 0)
				impulse = impulse.rotated(Vector3.UP, heading)*2.0*part.mass
				outcome.pushed = {"kind":push_kind,"elapsed":leap.elapsed,"impulse":[impulse.x,impulse.y,impulse.z]}
				part.apply_central_impulse(impulse)
			if case_name in ["interrupt","crew_interrupt"] and leap.state == interrupt_state and leap.elapsed >= interrupt_at and not outcome.has("interrupted"):
				outcome.interrupted = {"at_state":leap.state,"elapsed":leap.elapsed,"carrier_before":str(part.carrier)}
				leap.abort("Harness: coordinator cancelled the job mid-flight")
			if case_name == "hit" and leap.state == "return" and leap.elapsed >= .22 and not outcome.has("hit"):
				outcome.hit = {"at_state":"return","elapsed":leap.elapsed,"carried":part.carrier==leader.head_anchor}
				leader.apply_hit(Vector3(150, 60, 0))
			if case_name in ["save","crew_save"] and leap.state == save_state and leap.elapsed >= save_at and _saved.is_empty():
				_save_and_restore(leader)
				return
			if leap.state in ["outbound","return"] and "--trace-flight" in OS.get_cmdline_user_args():
				var direct := PhysicsServer3D.body_get_direct_state(leader.get_rid())
				var com: Vector3 = leader.global_transform*direct.center_of_mass_local
				var at: float = minf(leap.elapsed+1.0/120.0,leap._flight_seconds)
				var want: Vector3 = leap._planned_body(at)*direct.center_of_mass_local
				var goal: Basis = leap._planned_body(at).basis
				print("FLIGHT_TRACE %s t=%.3f com_err=%s mm=%.1f rot_err=%.2fdeg v=%s vplan=%s w=%.2f wplan=%.2f" % [leap.state,leap.elapsed,(com-want)*1000.0,(com-want).length()*1000.0,
					rad_to_deg(goal.get_rotation_quaternion().angle_to(leader.global_basis.get_rotation_quaternion())),direct.linear_velocity,leap._planned_com(at-.5/120.0,1),direct.angular_velocity.length(),leap._planned_angular_velocity(at-.5/120.0).length()])
			if leap.state == "contact" and "--trace-contact" in OS.get_cmdline_user_args():
				var root: Transform3D = leap._actual_root()
				var point: Vector3 = part.global_transform*leap.contact_local+leap.contact_normal*leap.CONTACT_GAP
				for w in crew:
					var L: RefCounted = w.head_leap
					var r: Transform3D = L._actual_root()
					var goal: Basis = L._contact_destination(L.HOLD_GAP).basis
					print("CONTACT_TRACE %s t=%.3f err=%.2fmm tilt=%.3fdeg goal_err=%.3fdeg v=%.3f w=%.3f ready=%s gap=%.3fmm head=%s" % [w.worker_id,L.elapsed,(r*L._head_touch_local).distance_to(part.global_transform*L.contact_local+L.contact_normal*L.CONTACT_GAP)*1000.0,
						rad_to_deg(acos(clampf(r.basis.y.normalized().dot(-L.contact_normal),-1.0,1.0))),rad_to_deg(goal.get_rotation_quaternion().angle_to(w.global_basis.get_rotation_quaternion())),w.linear_velocity.length(),w.angular_velocity.length(),L.contact_ready(),L.contact_surface_gap*1000.0,r*L._head_touch_local])
			if not _attached and leap.state == "contact" and crew.all(func(w) -> bool: return is_instance_valid(w) and w.head_leap.contact_ready()):
				var info := {"contact_error_mm":leap.contact_error*1000.0,"surface_gap_mm":leap.contact_surface_gap*1000.0,
					"penetration_mm":leap.contact_surface_penetration*1000.0,
					"tilt_deg":rad_to_deg(acos(clampf(leap._actual_root().basis.y.normalized().dot(-leap.contact_normal),-1.0,1.0))),
					"v":leader.linear_velocity.length(),"omega":leader.angular_velocity.length(),"t":probe.t}
				var before := part.global_transform
				var attach_started := Time.get_ticks_usec()
				var attached: bool = HeadLeap.attach_group(part, crew)
				outcome.attach_group_ms = (Time.get_ticks_usec()-attach_started)/1000.0
				if attached:
					_attached = true
					var after := part.global_transform
					info.part_displacement_mm = before.origin.distance_to(after.origin)*1000.0
					info.part_rotation_deg = rad_to_deg(before.basis.get_rotation_quaternion().angle_to(after.basis.get_rotation_quaternion()))
					info.same_item = part.carrier == leader.head_anchor
					info.mass_shares = crew.map(func(w: RigidBody3D) -> float: return w.cargo_mass)
					info.carrier = str(part.carrier.get_path()) if is_instance_valid(part.carrier) else ""
					probe.record_attach(info)
					_part_prev = part.global_transform
				else:
					info.refused = leap.reason
					probe.record_attach(info)
			if crew.all(func(w) -> bool: return not is_instance_valid(w) or w.head_leap.state in ["done","failed",""]):
				if _finished_at < 0.0: _finished_at = clock
				if clock-_finished_at > 1.2: _finish(leap.state)
		"restored":
			caption("save · restored native body %.2fs" % stage_clock)
			var upright := 0
			for restored: RigidBody3D in _restored_all:
				if not is_instance_valid(restored): continue
				var down: bool = restored.ragdoll and restored.ragdoll.is_down()
				outcome.restored_down_ticks = int(outcome.get("restored_down_ticks",0)) + (1 if down else 0)
				if not down and restored.is_available() and restored.on_ground: upright += 1
			for index in _restored_all.size():
				var restored: RigidBody3D = _restored_all[index]
				var key := "restored_upright_s_%d" % index
				if is_instance_valid(restored) and not (restored.ragdoll and restored.ragdoll.is_down()) and restored.on_ground and not outcome.has(key):
					outcome[key] = stage_clock
			if upright == _restored_all.size() and not outcome.has("restored_upright_s"):
				outcome.restored_upright_s = stage_clock
			if stage_clock > 12.0 or (outcome.has("restored_upright_s") and stage_clock > outcome.restored_upright_s + .5): _finish("restored")

func _watch_crate() -> void:
	if not is_instance_valid(crate): return
	var speed := crate.linear_velocity.length()
	if speed > float(outcome.get("crate_peak_speed", 0.0)): outcome.crate_peak_speed = speed
	outcome.crate_displacement_m = crate.global_position.distance_to(Vector3(0, .15, -(gap+.15)))
	if not crew.is_empty() and is_instance_valid(crew[0]) and crew[0].head_leap.state == "contact" and not outcome.has("crate_sleeping_at_contact"):
		outcome.crate_sleeping_at_contact = crate.sleeping

func _watch_crew_load() -> void:
	# While a shared load is carried: each member's actual roof skin against the
	# load's facing side (signed: + gap, - penetration), per leap state.
	if crew.size() < 2 or not is_instance_valid(part) or not is_instance_valid(part.carrier): return
	var bounds: AABB = Catalogue.bounds_of(part.definition)
	var inverse: Transform3D = part.global_transform.affine_inverse()
	var rows: Dictionary = outcome.get("crew_roof_gap_mm", {})
	for index in crew.size():
		var w: RigidBody3D = crew[index]
		if not is_instance_valid(w) or not w.head_leap.contacted: continue
		var root: Transform3D = w.head_leap._actual_root()
		var worst := INF
		for sample: Vector3 in w.head_leap._roof_samples:
			var local: Vector3 = inverse*(root*sample)
			worst = minf(worst, local.y - bounds.end.y if local.y > bounds.get_center().y else bounds.position.y - local.y)
		var key := "%d:%s" % [index, w.head_leap.state]
		var row: Dictionary = rows.get(key, {"min": INF, "max": -INF})
		row.min = minf(row.min, worst*1000.0)
		row.max = maxf(row.max, worst*1000.0)
		rows[key] = row
	outcome.crew_roof_gap_mm = rows

func _watch_safety() -> void:
	_watch_crate()
	_watch_crew_load()
	# Ragdolls, and how deep any flight torso ever overlaps the stock while the
	# stock is not carried (an honest dive must never pass through it).
	for w: RigidBody3D in crew:
		if not is_instance_valid(w): continue
		if w.ragdoll and w.ragdoll.is_down():
			var downs: Array = outcome.get("ragdolled", [])
			if not downs.has(w.worker_id):
				downs.append(w.worker_id)
				outcome.ragdolled = downs
				outcome["ragdoll_at_%s" % w.worker_id] = {"state":w.head_leap.state,"elapsed":w.head_leap.elapsed,"t":probe.t}
		# Only before custody: a released cargo keeps the original release
		# exception with its former carrier until they separate (by design).
		if is_instance_valid(part) and not is_instance_valid(part.carrier) and w.head_leap.active() and not w.head_leap.contacted:
			var collision: CollisionShape3D = w.get_node("Collision")
			if collision.shape is BoxShape3D:
				var bounds: AABB = Catalogue.bounds_of(part.definition)
				var depth := _box_overlap(collision.global_transform, collision.shape.size, part.global_transform*Transform3D(Basis.IDENTITY, bounds.get_center()), bounds.size)
				outcome.max_torso_stock_overlap_m = maxf(float(outcome.get("max_torso_stock_overlap_m", 0.0)), depth)

static func _box_overlap(a: Transform3D, a_size: Vector3, b: Transform3D, b_size: Vector3) -> float:
	# SAT penetration depth of two oriented boxes (0 when separated).
	var axes: Array[Vector3] = [a.basis.x, a.basis.y, a.basis.z, b.basis.x, b.basis.y, b.basis.z]
	for i in 3:
		for j in 3: axes.append(a.basis[i].cross(b.basis[j]))
	var depth := INF
	var apart := b.origin - a.origin
	for axis: Vector3 in axes:
		if axis.length_squared() < .000001: continue
		axis = axis.normalized()
		var ra := 0.0
		var rb := 0.0
		for k in 3:
			ra += absf(axis.dot(a.basis[k].normalized()))*a_size[k]*.5
			rb += absf(axis.dot(b.basis[k].normalized()))*b_size[k]*.5
		var overlap := ra + rb - absf(axis.dot(apart))
		if overlap <= 0.0: return 0.0
		depth = minf(depth, overlap)
	return depth

func _save_and_restore(leader: RigidBody3D) -> void:
	# The save replaces the live world: every crew member leaves, the same
	# source keeps its actual pose, and fresh Wakos load the saved states.
	var leap: RefCounted = leader.head_leap
	var saved: Array = []
	for w: RigidBody3D in crew:
		if not is_instance_valid(w): continue
		var data: Dictionary = JSON.parse_string(JSON.stringify(w.serialize_state()))
		saved.append({"data":data,"position":w.global_position,"id":w.worker_id})
	var physical: Dictionary = saved[0].data.get("physical_body", {})
	_saved = {"at_state":leap.state,"elapsed":leap.elapsed,"members":saved.size(),"bodies":(physical.get("bodies",[]) as Array).size(),
		"origin_motion":physical.get("origin_motion",false),"saved_locks":physical.get("saved",{}).get("angular_locks",[]),
		"source_carried":part.carrier==leader.head_anchor,"source_in_transit":part.get_meta(&"in_transit",false),
		"saved_velocity":saved[0].data.get("velocity"),"worker_up_y":leader.global_basis.y.y,
		"physical_bodies_per_member":saved.map(func(row: Dictionary) -> int: return (row.data.get("physical_body",{}).get("bodies",[]) as Array).size())}
	var pose := part.global_transform
	for w: RigidBody3D in crew:
		if is_instance_valid(w): w.queue_free()
	part.set_carried(null)
	part.global_transform = pose
	part.linear_velocity = Vector3.ZERO
	_restored_all.clear()
	for row: Dictionary in saved:
		var restored: RigidBody3D = WAKO.instantiate()
		restored.worker_id = str(row.id) + "_restored"
		restored.position = row.position
		add_child(restored)
		restored.restore_state(row.data)
		_restored_all.append(restored)
	_restored = _restored_all[0]
	_saved.restored_down = _restored_all.map(func(w: RigidBody3D) -> bool: return w.ragdoll.is_down() if w.ragdoll else false)
	_saved.source_pose_kept_mm = pose.origin.distance_to(part.global_position)*1000.0
	outcome.save = _saved
	stage_name = "restored"
	stage_clock = 0.0

func _toss_scenario(delta: float) -> void:
	var w: RigidBody3D = crew[0]
	var pickup: RefCounted = w.pickup
	match stage_name:
		"settle":
			w.face_point(part.global_position)
			caption("toss · settling")
			if clock < 1.6 or not _settled(w): return
			# Yard present_pickup: freeze the same light body in place, reserve it.
			part.set_meta(&"in_transit", true)
			part.freeze = true
			part.collision_layer = 0
			part.collision_mask = 0
			w.work_target = part
			pickup.begin(part)
			w.action_contact.connect(func(kind: String) -> void:
				if kind == "pickup" and pickup.state == "reaching":
					_toss.grip = pickup.grip())
			w.begin_action("pickup")
			probe.mark("toss_begin")
			stage_name = "toss"
			stage_clock = 0.0
		"toss":
			caption("toss · %s" % pickup.state)
			# Visual cube height: ready crouch under the flight, dip on the catch.
			var cube_y: float = (w.global_transform*w._pose.evaluated_worker.affine_inverse()*w._pose.evaluated_root).origin.y
			if not _toss.has("stand_root_y"): _toss.stand_root_y = cube_y
			if pickup.state == "flight": _toss.ready_drop_m = maxf(float(_toss.get("ready_drop_m", 0.0)), float(_toss.stand_root_y) - cube_y)
			if pickup.state == "flight": _toss._before_catch_y = cube_y
			if pickup.state == "caught" and _toss.has("_before_catch_y") and probe.t-float(_toss.get("caught_t", probe.t)) < .5:
				var dip: float = float(_toss._before_catch_y) - cube_y
				if dip > float(_toss.get("catch_dip_m", 0.0)):
					_toss.catch_dip_m = dip
					_toss.catch_dip_bottom_s = probe.t-float(_toss.get("caught_t", probe.t))
			if pickup.state == "flight":
				probe.mark("toss_launch")
				var head: Vector3 = pickup._head_point()
				_toss.apex_above_head = maxf(float(_toss.get("apex_above_head",-INF)), part.global_position.y-head.y)
				_toss.flight_s = pickup._flight_clock
				_toss.launch_impulse = pickup.launch_impulse.length()
				_part_prev = part.global_transform
			if pickup.state == "caught" and not _toss.has("caught_t"):
				probe.mark("toss_caught")
				_toss.caught_t = probe.t
				var now := part.global_transform
				_toss.catch_jump_mm = _part_prev.origin.distance_to(now.origin)*1000.0
				_toss.catch_rotation_deg = rad_to_deg(_part_prev.basis.get_rotation_quaternion().angle_to(now.basis.get_rotation_quaternion()))
				_toss.catch_momentum_error = pickup.catch_before_momentum.distance_to(pickup.catch_after_momentum)
				_toss.launch_momentum_error = pickup.launch_before_momentum.distance_to(pickup.launch_after_momentum)
			if pickup.state == "caught":
				# Real collision bottom against the actual roof plane (head frame).
				var footprint: AABB = pickup._footprint(pickup._head_frame().affine_inverse()*part.global_transform)
				_toss.catch_gap_mm = pickup.catch_gap*1000.0
				_toss.roof_gap_mm = footprint.position.y*1000.0
				_toss.max_roof_gap_mm = maxf(float(_toss.get("max_roof_gap_mm",-INF)), footprint.position.y*1000.0) if probe.t-float(_toss.caught_t) > .2 else _toss.get("max_roof_gap_mm",-INF)
				_toss.seat_centre_mm = Vector2(footprint.get_center().x, footprint.get_center().z).length()*1000.0
				_toss.settle_offset_mm = pickup.catch_offset.length()*1000.0
				_toss.settle_yaw_deg = pickup.catch_yaw
				# Per-tick step relative to the carrying head (the settle residual).
				var local: Transform3D = w.head_anchor.global_transform.affine_inverse()*part.global_transform
				if _toss.has("_local_prev"):
					_toss.max_settle_step_mm = maxf(float(_toss.get("max_settle_step_mm",0.0)), (_toss._local_prev as Vector3).distance_to(local.origin)*1000.0)
				_toss._local_prev = local.origin
				_part_prev = part.global_transform
				if probe.t-float(_toss.caught_t) > 1.0:
					_toss.erase("_local_prev")
					_toss.erase("_before_catch_y")
					_finish("caught")
			elif pickup.state == "failed" or stage_clock > 8.0:
				_toss.reason = pickup.reason
				_finish(pickup.state)

func _finish(result: String) -> void:
	if _reported: return
	_reported = true
	var extra := {"case":case_name,"result":result,"refusals":refusals,"outcome":outcome,"toss":_toss,
		"part_carrier":str(part.carrier.name) if is_instance_valid(part) and is_instance_valid(part.carrier) else "",
		"part_kind":part.kind if is_instance_valid(part) else "","part_mass":part.mass if is_instance_valid(part) else 0.0}
	var report: Dictionary = probe.report(extra)
	var text := JSON.stringify(report)
	print("LEAP_METRICS ", text)
	if not out_path.is_empty():
		var file := FileAccess.open(out_path, FileAccess.WRITE)
		if file: file.store_string(JSON.stringify(report, "  "))
	if DisplayServer.get_name() == "headless": Shortcuts.graceful_quit(0)

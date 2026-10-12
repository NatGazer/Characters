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

func setup() -> void:
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
	var focus := Vector3(0, .75, -.8)
	match case_name:
		"solo", "interrupt", "hit", "save":
			part = _part("bracket", Vector3(0, .15, -(gap+.15)))
			crew = [spawn_wako(Vector3(0, 1.0, 0), "leap_solo")]
		"large":
			# 48 kg flux generator: outside the small-stock limits (> 35 kg).
			part = _part("generator", Vector3(0, .325, -(gap+.475)))
			crew = [spawn_wako(Vector3(0, 1.0, 0), "leap_large")]
			focus = Vector3(0, .8, -1.0)
		"crew":
			# 32 kg cut armour plate (1.2 m face): one shared two-Wako job.
			part = _part("armor", Vector3(0, .075, -(crew_gap+.6)))
			crew = [spawn_wako(Vector3(-.49, 1.0, 0), "leap_crew_a"), spawn_wako(Vector3(.49, 1.0, 0), "leap_crew_b")]
			focus = Vector3(0, .8, -.85)
		"obstacle":
			# A 1.05 m screen between launch place and stock rejects the brisk
			# short arcs; clearance must fall back to the long original plans.
			part = _part("bracket", Vector3(0, .15, -1.75))
			add_box(Vector3(0, .525, -.86), Vector3(1.4, 1.05, .08), Color(.55, .42, .32))
			crew = [spawn_wako(Vector3(0, 1.0, 0), "leap_obstacle")]
			focus = Vector3(0, .9, -.9)
		"toss":
			part = _part("light", Vector3(0, .08, -.42))
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
			var blocker: String = HeadLeap.begin_group(part, crew)
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
			if case_name == "interrupt" and leap.state == interrupt_state and leap.elapsed >= interrupt_at and not outcome.has("interrupted"):
				outcome.interrupted = {"at_state":leap.state,"elapsed":leap.elapsed,"carrier_before":str(part.carrier)}
				leap.abort("Harness: coordinator cancelled the job mid-flight")
			if case_name == "hit" and leap.state == "return" and leap.elapsed >= .22 and not outcome.has("hit"):
				outcome.hit = {"at_state":"return","elapsed":leap.elapsed,"carried":part.carrier==leader.head_anchor}
				leader.apply_hit(Vector3(150, 60, 0))
			if case_name == "save" and leap.state == save_state and leap.elapsed >= save_at and _saved.is_empty():
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
				print("CONTACT_TRACE t=%.3f err=%.2fmm tilt=%.3fdeg v=%.3f w=%.3f ready=%s head=%s point=%s" % [leap.elapsed,(root*leap._head_touch_local).distance_to(point)*1000.0,
					rad_to_deg(acos(clampf(root.basis.y.normalized().dot(-leap.contact_normal),-1.0,1.0))),leader.linear_velocity.length(),leader.angular_velocity.length(),leap.contact_ready(),root*leap._head_touch_local,point])
			if not _attached and leap.state == "contact" and crew.all(func(w) -> bool: return is_instance_valid(w) and w.head_leap.contact_ready()):
				var info := {"contact_error_mm":leap.contact_error*1000.0,"surface_gap_mm":leap.contact_surface_gap*1000.0,
					"penetration_mm":leap.contact_surface_penetration*1000.0,
					"tilt_deg":rad_to_deg(acos(clampf(leap._actual_root().basis.y.normalized().dot(-leap.contact_normal),-1.0,1.0))),
					"v":leader.linear_velocity.length(),"omega":leader.angular_velocity.length(),"t":probe.t}
				var before := part.global_transform
				if HeadLeap.attach_group(part, crew):
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
			if is_instance_valid(_restored):
				var down: bool = _restored.ragdoll and _restored.ragdoll.is_down()
				outcome.restored_down_ticks = int(outcome.get("restored_down_ticks",0)) + (1 if down else 0)
				if not down and _restored.is_available() and _restored.on_ground and not outcome.has("restored_upright_s"):
					outcome.restored_upright_s = stage_clock
			if stage_clock > 4.0: _finish("restored")

func _save_and_restore(leader: RigidBody3D) -> void:
	var leap: RefCounted = leader.head_leap
	var data: Dictionary = JSON.parse_string(JSON.stringify(leader.serialize_state()))
	var physical: Dictionary = data.get("physical_body", {})
	_saved = {"at_state":leap.state,"elapsed":leap.elapsed,"bodies":(physical.get("bodies",[]) as Array).size(),
		"origin_motion":physical.get("origin_motion",false),"saved_locks":physical.get("saved",{}).get("angular_locks",[]),
		"source_carried":part.carrier==leader.head_anchor,"source_in_transit":part.get_meta(&"in_transit",false),
		"saved_velocity":data.get("velocity"),"worker_up_y":leader.global_basis.y.y}
	# The save replaces the live world: the original worker leaves, the same
	# source keeps its actual pose, and a fresh Wako loads the saved state.
	var pose := part.global_transform
	leader.queue_free()
	part.set_carried(null)
	part.global_transform = pose
	part.linear_velocity = Vector3.ZERO
	_restored = WAKO.instantiate()
	_restored.worker_id = "leap_restored"
	_restored.position = leader.global_position
	add_child(_restored)
	_restored.restore_state(data)
	_saved.restored_down = _restored.ragdoll.is_down() if _restored.ragdoll else false
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
				var seat: Vector3 = w.head_anchor.global_transform*Vector3(0, float(part.definition.size.y)*.5+.03, 0)
				_toss.max_step_mm = maxf(float(_toss.get("max_step_mm",0.0)), _part_prev.origin.distance_to(part.global_position)*1000.0)
				_toss.seat_error_mm = part.global_position.distance_to(seat)*1000.0
				_part_prev = part.global_transform
				if probe.t-float(_toss.caught_t) > 1.0: _finish("caught")
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

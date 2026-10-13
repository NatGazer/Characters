extends "res://harness/scripts/stage.gd"
## Gait acceptance lab. One scene, several scenarios chosen by user arg
## `scenario=<flat|terrain|platform|carry|showcase>` (default flat). Every
## scenario drives the real Wako only through its public navigation API and
## prints METRIC lines from harness/scripts/gait_metrics.gd at the end.
##   godot --headless --fixed-fps 120 --path <hw> res://harness/scenes/gait_lab.tscn -- scenario=terrain
## Optional: cam=side|q34|front|far|fq34|q34c|sidec|rear, quit=0 (keep running),
## tint=1 (orange ball on the LEFT ankle, blue on the right, for readability).
## Adversarial scenarios (after the first critic pass): interrupt, arrive_act,
## inspect, stopgo, drop_start, slope_stop, step_run, zigzag, reverse_run,
## uturn_run, platform_fast, creep, carry_run.
const Metrics := preload("res://harness/scripts/gait_metrics.gd")
const Part := preload("res://Components/Contraptions/contraption_part.gd")
var wako: RigidBody3D
var metrics: Node
var args := {}
var deck: RigidBody3D
var cargo: RigidBody3D
var _deck_target := Vector3.INF

func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if "=" in a: args[a.get_slice("=", 0)] = a.get_slice("=", 1)

func build_world() -> void:
	add_box(Vector3(0, -0.5, 0), Vector3(120, 1, 120), Color(0.46, 0.5, 0.42))
	# Faint 1 m floor lines make foot skating readable on video.
	for i in range(-12, 13):
		add_box(Vector3(i, .0005, 0), Vector3(.012, .001, 26), Color(0.38, 0.42, 0.35), Vector3.ZERO, 0)
		add_box(Vector3(0, .0005, i), Vector3(26, .001, .012), Color(0.38, 0.42, 0.35), Vector3.ZERO, 0)

func add_ramp(p0: Vector3, p1: Vector3, width: float, color: Color) -> void:
	# Box whose TOP surface runs exactly from p0 to p1.
	var b := Basis.looking_at(p1 - p0, Vector3.UP)
	var t := .5
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.transform = Transform3D(b, (p0 + p1) * .5 - b.y * t * .5)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(width, t, p0.distance_to(p1))
	shape.shape = box
	body.add_child(shape)
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	mesh.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = .85
	mesh.material_override = m
	body.add_child(mesh)
	add_child(body)

func setup() -> void:
	var scenario: String = args.get("scenario", "flat")
	var cam: String = args.get("cam", "side")
	cam_offset = {"side": Vector3(2.7, .75, .35), "q34": Vector3(1.9, 1.05, 1.9), "front": Vector3(.6, .9, -2.6), "far": Vector3(4.2, 1.8, 2.2),
		"fq34": Vector3(1.55, .7, -1.75), "q34c": Vector3(1.6, .75, 1.6), "sidec": Vector3(2.3, .55, .2), "rear": Vector3(-.5, .85, 2.4)}.get(cam, Vector3(2.7, .75, .35))
	cam_smooth = 5.0
	var start := Vector3(0, 1.0, 22)
	match scenario:
		"terrain": _build_terrain()
		"platform", "platform_fast":
			start = Vector3(0, 1.45, 0)
			_build_platform()
		"slope_stop":
			_build_slopes()
			start = Vector3(0, 1.0, 4)
		"step_run":
			_build_steps()
			start = Vector3(0, 1.2, 21)
		"drop_start":
			start = Vector3(0, 2.6, 22)
			add_box(Vector3(0, .3, 10), Vector3(3, .6, 8), Color(0.62, 0.6, 0.55))
		"interrupt":
			start = Vector3(0, 1.6, 22)
			add_box(Vector3(0, .3, 19), Vector3(3, .6, 8), Color(0.62, 0.6, 0.55))
	wako = spawn_wako(start, "gait_lab")
	cam_follow = wako
	metrics = Metrics.new()
	add_child(metrics)
	if args.get("tint", "0") == "1": _tint_feet.call_deferred()
	_run.call_deferred(scenario)

func _tint_feet() -> void:
	# Small coloured markers on the ankles: left orange, right blue.
	var sk: Skeleton3D = wako._skeleton
	var pose: Node = wako._pose
	for side in 2:
		# On the knee, standing proud of the shin so it reads in every view.
		var attach := BoneAttachment3D.new()
		attach.bone_idx = int(pose._chains[side][1])
		sk.add_child(attach)
		var ball := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = .05
		sphere.height = .1
		ball.mesh = sphere
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(1.0, .45, .05) if side == 0 else Color(.1, .45, 1.0)
		m.emission_enabled = true
		m.emission = m.albedo_color * .4
		ball.material_override = m
		attach.add_child(ball)

func _build_slopes() -> void:
	var stone := Color(0.62, 0.6, 0.55)
	# 15 deg ramp z 0 -> -6, plateau, 25 deg ramp z -8 -> -12, plateau.
	var r15 := 6.0 * tan(deg_to_rad(15.0))
	add_ramp(Vector3(0, 0, 0), Vector3(0, r15, -6), 3.0, stone)
	add_box(Vector3(0, r15 * .5, -7), Vector3(3, r15, 2), stone)
	var r25 := 4.0 * tan(deg_to_rad(25.0))
	add_ramp(Vector3(0, r15, -8), Vector3(0, r15 + r25, -12), 3.0, stone.darkened(.15))
	add_box(Vector3(0, (r15 + r25) * .5, -13.5), Vector3(3, r15 + r25, 3), stone)

func _build_steps() -> void:
	var stone := Color(0.62, 0.6, 0.55)
	# Plateau A 16 cm (z 24 -> 6), floor (6 -> 0), plateau B 16 cm (0 -> -10).
	add_box(Vector3(0, .08, 15), Vector3(3, .16, 18), stone)
	add_box(Vector3(0, .08, -5), Vector3(3, .16, 10), stone)

func _build_terrain() -> void:
	var stone := Color(0.62, 0.6, 0.55)
	var z := 18.0
	# Up 8 cm x3, plateau, up 16 cm x2, plateau, down 16 cm x2, down 8 cm x3.
	var h := 0.0
	for rise: float in [.08, .08, .08]:
		h += rise
		add_box(Vector3(0, h * .5, z - .225), Vector3(3, h, .45), stone)
		z -= .45
	add_box(Vector3(0, h * .5, z - .6), Vector3(3, h, 1.2), stone); z -= 1.2
	for rise: float in [.16, .16]:
		h += rise
		add_box(Vector3(0, h * .5, z - .25), Vector3(3, h, .5), stone)
		z -= .5
	add_box(Vector3(0, h * .5, z - .6), Vector3(3, h, 1.2), stone); z -= 1.2
	for drop: float in [.16, .16, .08, .08]:
		h -= drop
		if h > .001: add_box(Vector3(0, h * .5, z - .25), Vector3(3, h, .5), stone)
		z -= .5
	# z is now ~10.5. Slope 15 deg up over 2.6 m, plateau, 25 deg down.
	z -= 1.0
	var rise15 := 2.6 * tan(deg_to_rad(15.0))
	add_ramp(Vector3(0, 0, z), Vector3(0, rise15, z - 2.6), 3.0, stone.darkened(.1))
	add_box(Vector3(0, rise15 * .5, z - 2.6 - .6), Vector3(3, rise15, 1.2), stone.darkened(.1))
	var run25 := rise15 / tan(deg_to_rad(25.0))
	add_ramp(Vector3(0, rise15, z - 3.8), Vector3(0, 0, z - 3.8 - run25), 3.0, stone.darkened(.2))
	z -= 3.8 + run25 + 1.0
	# Uneven blocks 2-7 cm.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for ix in range(-3, 4):
		for iz in 12:
			var bh := rng.randf_range(.02, .07)
			add_box(Vector3(ix * .42 + rng.randf_range(-.05, .05), bh * .5, z - iz * .42), Vector3(.36, bh, .36), stone.lightened(rng.randf_range(0, .2)))

func _build_platform() -> void:
	deck = RigidBody3D.new()
	deck.mass = 20000
	deck.gravity_scale = 0
	deck.linear_damp = 0
	deck.angular_damp = 0
	deck.axis_lock_linear_y = true
	deck.axis_lock_angular_x = true
	deck.axis_lock_angular_z = true
	deck.collision_layer = 1
	deck.position = Vector3(0, .35, 0)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(7, .3, 7)
	shape.shape = box
	deck.add_child(shape)
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	mesh.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(.55, .42, .3)
	mesh.material_override = m
	deck.add_child(mesh)
	for i in range(-3, 4):
		var line := MeshInstance3D.new()
		var lm := BoxMesh.new()
		lm.size = Vector3(.015, .002, 7)
		line.mesh = lm
		line.position = Vector3(i, .151, 0)
		var lmat := StandardMaterial3D.new()
		lmat.albedo_color = Color(.35, .25, .18)
		line.material_override = lmat
		deck.add_child(line)
	add_child(deck)

func _ticks(seconds: float) -> void:
	for i in roundi(seconds * Engine.physics_ticks_per_second):
		if _deck_target.is_finite() and is_instance_valid(deck):
			wako.navigate_to(deck.to_global(_deck_target) - Vector3(0, 0, 0))
		await get_tree().physics_frame

func _phase(text: String, seconds: float) -> void:
	metrics.label = text
	caption(text)
	await _ticks(seconds)

func _go(dir: Vector3, speed: float, start_label: String, steady_label: String, steady: float) -> void:
	wako.walk_speed = speed
	wako.navigate_to(wako.global_position + dir.normalized() * 80.0 - Vector3(0, wako.ride_height, 0))
	metrics.mark_motion_start()
	await _phase(start_label, .8)
	await _phase(steady_label, steady)

func _goto(dir: Vector3, speed: float) -> void:
	wako.walk_speed = speed
	wako.navigate_to(wako.global_position + dir.normalized() * 80.0 - Vector3(0, wako.ride_height, 0))

func _until(text: String, done: Callable, limit: int) -> void:
	metrics.label = text
	caption(text)
	var guard := 0
	while not done.call() and guard < limit:
		await _ticks(1.0 / 120.0)
		guard += 1

func _stop(label: String) -> void:
	wako.stop_navigation()
	await _phase(label, 1.6)
	metrics.neutral_snapshot()

func _run(scenario: String) -> void:
	metrics.attach(wako)
	await _phase("idle", .5 if scenario.ends_with("clip") else 1.2)
	match scenario:
		"flat":
			await _go(Vector3.FORWARD, 1.0, "start_1.0", "walk_1.0", 2.4)
			await _stop("stop_1.0")
			await _go(Vector3.FORWARD, 2.1, "start_2.1", "jog_2.1", 2.4)
			await _stop("stop_2.1")
			await _go(Vector3.FORWARD, 3.4, "start_3.4", "run_3.4", 2.6)
			await _stop("stop_3.4")
			wako.walk_speed = 2.1
			wako.navigate_to(wako.global_position + Vector3(40, -wako.ride_height, 0))
			await _phase("turn90_2.1", 2.0)
			wako.navigate_to(wako.global_position + Vector3(-40, -wako.ride_height, 0))
			await _phase("reverse_2.1", 2.2)
			await _stop("stop_rev")
			wako.face_point(wako.global_position + Vector3(4, 0, 0))
			await _phase("turn_in_place", 2.0)
			metrics.neutral_snapshot()
		"terrain":
			wako.walk_speed = float(args.get("speed", "2.1"))
			wako.navigate_to(Vector3(0, 0, -16))
			metrics.mark_motion_start()
			await _phase("stairs", 4.3 * 2.1 / wako.walk_speed)
			await _phase("slopes", 3.4 * 2.1 / wako.walk_speed)
			await _phase("blocks", 3.0 * 2.1 / wako.walk_speed)
			await _stop("stop_terrain")
		"platform":
			deck.linear_velocity = Vector3(.45, 0, 0)
			deck.angular_velocity = Vector3(0, .35, 0)
			await _phase("deck_idle", 1.5)
			wako.walk_speed = 1.6
			for p: Vector3 in [Vector3(0, 0, -2.2), Vector3(2.0, 0, -1.0), Vector3(1.5, 0, 1.8), Vector3(-1.5, 0, 1.5)]:
				_deck_target = p
				await _phase("deck_walk", 1.6)
			_deck_target = Vector3.INF
			await _stop("deck_stop")
			await _phase("deck_stand", 2.5)
		"carry":
			cargo = Part.new()
			cargo.setup("battery", "gait-head-load", true)
			add_child(cargo)
			cargo.set_carried(wako.head_anchor, Vector3(0, float(cargo.definition.size.y) * .5 + .03, 0))
			wako.set_cargo(cargo.mass)
			await _phase("carry_idle", .8)
			await _go(Vector3.FORWARD, 2.1 / (1.0 - cargo.mass / 140.0), "carry_start", "carry_2.1", 2.6)
			await _stop("carry_stop")
			wako.navigate_to(wako.global_position + Vector3(30, -wako.ride_height, 0))
			await _phase("carry_turn", 2.0)
			await _stop("carry_stop2")
		"runclip":
			await _go(Vector3.FORWARD, 3.4, "run 3.4 m/s", "run 3.4 m/s ", 1.6)
			await _stop("stop")
		"walkclip":
			await _go(Vector3.FORWARD, 1.0, "walk 1.0 m/s", "walk 1.0 m/s ", 1.4)
			await _go(Vector3.FORWARD, 2.1, "jog 2.1 m/s", "jog 2.1 m/s ", 1.0)
			await _stop("stop")
		"turnclip":
			wako.walk_speed = 2.1
			wako.navigate_to(wako.global_position + Vector3(0, -wako.ride_height, -40))
			await _phase("jog", 1.2)
			wako.navigate_to(wako.global_position + Vector3(40, -wako.ride_height, 0))
			await _phase("turn 90", 1.4)
			wako.navigate_to(wako.global_position + Vector3(-40, -wako.ride_height, 0))
			await _phase("reverse", 1.6)
			await _stop("stop")
			wako.face_point(wako.global_position + Vector3(0, 0, 4))
			await _phase("turn in place", 1.6)
		"tool":
			# A retained full mallet on the tool foot: finite toe budget and
			# whole-tool clearance still own that foot during travel.
			var tool: RigidBody3D = Part.new()
			tool.setup("assembly_tool", "gait-lab-mallet", true)
			tool.position = wako.global_position + Vector3(2, 0, 0)
			add_child(tool)
			await _ticks(.2)
			tool.set_carried(wako.tool_anchor, Vector3.ZERO)
			tool.global_transform = wako.tool_anchor.global_transform
			wako.set_equipped_tool(tool)
			await _phase("tool_idle", .8)
			# Trips longer than 1.1 m make the back tool stow the mallet first;
			# short repositioning hops keep it on the foot (the case to test).
			wako.walk_speed = 2.1
			for hop: Vector3 in [Vector3(0, 0, -1.0), Vector3(0, 0, -1.0), Vector3(.9, 0, -.4), Vector3(.9, 0, .3), Vector3(-1.0, 0, 0)]:
				wako.navigate_to(wako.global_position + hop - Vector3(0, wako.ride_height, 0))
				await _phase("tool_hop", .9)
				print("TOOL_STATE c=%.2f phase=%s held=%s reason=%s blocked=%s" % [metrics.clock, wako.back_tool.phase, is_instance_valid(wako.equipped_tool) and wako.equipped_tool.get("carrier") == wako.tool_anchor, wako.back_tool.reason, wako.tool_pose_blocked])
			await _stop("tool_stop")
		"actions":
			# Non-gait foot actions use the legacy authored-follow solve: their
			# knees must also bend toward the face and hand back to the gait.
			for kind: String in ["place", "brace", "step", "push", "interrupted"]:
				wako.begin_action(kind)
				metrics.label = "act_" + kind
				caption(kind)
				var guard := 0
				while not wako.action.is_empty() and guard < 600:
					await _ticks(1.0 / 120.0)
					guard += 1
				await _phase("after_" + kind, .5)
			wako.fear_time = 1.2
			await _phase("danger", 1.2)
			await _go(Vector3.FORWARD, 2.1, "act_start", "act_walk", 1.2)
			await _stop("act_stop")
		"interrupt":
			# Run off a real 0.6 m ledge, land, keep running; then begin foot
			# actions mid-walk (each stops navigation itself) and resume.
			_goto(Vector3.FORWARD, 3.4)
			await _until("ledge_run", func() -> bool: return wako.global_position.z <= 15.5, 900)
			await _until("ledge_fall_land", func() -> bool: return wako.global_position.z <= 12.0, 900)
			await _phase("after_fall", .8)
			wako.stop_navigation()
			await _phase("stop1", 1.2)
			for kind: String in ["step", "interrupted", "brace"]:
				_goto(Vector3.FORWARD, 2.1)
				await _phase("walk_" + kind, 1.2)
				wako.begin_action(kind)
				await _until("act_" + kind, func() -> bool: return wako.action.is_empty(), 600)
				await _phase("resume_" + kind, .8)
			wako.stop_navigation()
			await _phase("stop", 1.2)
		"arrive_act":
			# Coordinator-like: travel, arrive, wait for the settle gates
			# (gait_speed<.08, |turn|<.15, wk_idle >= .24 s, both soles), act.
			for kind: String in ["inspect", "step", "brace"]:
				wako.walk_speed = 2.1
				wako.navigate_to(wako.global_position + Vector3(0, -wako.ride_height, -3.0))
				await _until("travel_" + kind, func() -> bool: return wako.at_target(.2), 900)
				wako.stop_navigation()
				metrics.label = "settle_" + kind
				var guard := 0
				var last := {"speed": 0, "turn": 0, "idle": 0, "feet": 0}
				while guard < 960:
					var p: Node = wako._pose
					var ok := {"speed": wako.gait_speed < .08, "turn": absf(wako.turn_rate) < .15, "idle": wako._animation.current_animation == "wk_idle" and wako._animation.current_animation_position >= .24, "feet": p.evaluated_valid and p.evaluated_grounded[0] and p.evaluated_grounded[1]}
					for key: String in ok:
						if not ok[key]: last[key] = guard + 1
					if ok.speed and ok.turn and ok.idle and ok.feet: break
					await _ticks(1.0 / 120.0)
					guard += 1
				var g: Variant = wako._pose.get("gait")
				# Which gate held the work back longest (ticks until it last turned true).
				print("GATE %s settle_ticks=%d w=%.3f speed@%d turn@%d idle@%d feet@%d" % [kind, guard, float(g.locomotion_weight) if g else 0.0, last.speed, last.turn, last.idle, last.feet])
				var target := Node3D.new()
				add_child(target)
				target.global_position = wako.global_position + (-wako._model.global_basis.z) * .45 + Vector3(.1, -wako.ride_height + .05, 0)
				wako.work_target = target
				wako.begin_action(kind)
				await _until("act_" + kind, func() -> bool: return wako.action.is_empty(), 900)
				wako.work_target = null
				await _phase("resume_" + kind, 1.0)
		"inspect":
			var target := Node3D.new()
			add_child(target)
			target.global_position = wako.global_position + (-wako._model.global_basis.z) * .45 + Vector3(.12, -wako.ride_height + .05, 0)
			wako.work_target = target
			wako.begin_action("inspect")
			await _until("inspect", func() -> bool: return wako.action.is_empty(), 900)
			wako.work_target = null
			await _phase("after_inspect", .8)
			_goto(Vector3.FORWARD, 2.1)
			await _phase("walk_after", 1.5)
			var t2 := Node3D.new()
			add_child(t2)
			t2.global_position = wako.global_position + (-wako._model.global_basis.z) * .5 + Vector3(0, -wako.ride_height + .05, 0)
			wako.work_target = t2
			wako.begin_action("inspect")
			await _until("inspect_from_walk", func() -> bool: return wako.action.is_empty(), 900)
			wako.work_target = null
			await _phase("after_inspect2", .8)
			_goto(Vector3.FORWARD, 2.1)
			await _phase("walk_after2", 1.2)
			await _stop("stop")
		"stopgo":
			for i in 6:
				_goto(Vector3.FORWARD, 3.4)
				await _phase("go", .45)
				wako.stop_navigation()
				await _phase("brake", .18)
			await _stop("stop")
		"drop_start":
			await _until("falling", func() -> bool: return wako.on_ground, 600)
			_goto(Vector3.FORWARD, 3.4)
			metrics.mark_motion_start()
			await _phase("start_after_land", 1.4)
			await _until("ledge_air", func() -> bool: return wako.global_position.z <= 5.0, 1200)
			await _phase("after_ledge", 1.2)
			await _stop("stop")
		"slope_stop":
			_goto(Vector3.FORWARD, 1.0)
			await _until("climb15", func() -> bool: return wako.global_position.z <= -2.8, 1200)
			await _stop("stop_on_15")
			wako.face_point(wako.global_position + Vector3(4, 0, 0))
			await _phase("turn_on_15", 2.0)
			metrics.neutral_snapshot()
			_goto(Vector3.FORWARD, 2.1)
			await _until("climb25", func() -> bool: return wako.global_position.z <= -10.0, 1500)
			await _stop("stop_on_25")
			_goto(Vector3.BACK, 2.1)
			await _phase("down25_15", 4.0)
			await _stop("stop_end")
		"step_run":
			_goto(Vector3.FORWARD, 3.4)
			await _until("run_top", func() -> bool: return wako.global_position.z <= 7.2, 1500)
			await _until("down16_run", func() -> bool: return wako.global_position.z <= 4.0, 600)
			await _until("floor_run", func() -> bool: return wako.global_position.z <= 1.2, 600)
			await _until("up16_run", func() -> bool: return wako.global_position.z <= -2.0, 600)
			await _phase("run_top2", .6)
			await _stop("stop")
		"zigzag":
			wako.walk_speed = 3.4
			for i in 10:
				var a := deg_to_rad(60.0 if i % 2 == 0 else -60.0)
				wako.navigate_to(wako.global_position + Vector3(sin(a), 0, -cos(a)) * 30.0 - Vector3(0, wako.ride_height, 0))
				await _phase("zigzag", .35)
			await _stop("stop")
		"reverse_run", "uturn_run":
			_goto(Vector3.FORWARD, 3.4)
			metrics.mark_motion_start()
			await _phase("run", 2.2)
			if scenario == "reverse_run": _goto(Vector3.BACK, 3.4)
			else: wako.navigate_to(wako.global_position + Vector3(1.5, -wako.ride_height, 30))
			await _phase("reverse_at_run", 2.4)
			await _stop("stop")
		"platform_fast":
			deck.linear_velocity = Vector3(.8, 0, 0)
			deck.angular_velocity = Vector3(0, .9, 0)
			await _phase("deck_idle", 2.0)
			wako.walk_speed = 2.1
			for p: Vector3 in [Vector3(0, 0, -2.2), Vector3(2.0, 0, -1.0), Vector3(1.5, 0, 1.8), Vector3(-1.5, 0, 1.5)]:
				_deck_target = p
				await _phase("deck_walk", 1.4)
			_deck_target = Vector3.INF
			await _stop("deck_stop")
			await _phase("deck_stand", 2.5)
		"creep":
			for sp: float in [.22, .15, .1]:
				_goto(Vector3.FORWARD, sp)
				await _phase("creep_%.2f" % sp, 3.5)
			await _stop("stop")
		"carry_run":
			cargo = Part.new()
			cargo.setup("battery", "gait-head-load", true)
			add_child(cargo)
			cargo.set_carried(wako.head_anchor, Vector3(0, float(cargo.definition.size.y) * .5 + .03, 0))
			wako.set_cargo(cargo.mass)
			await _phase("carry_idle", .8)
			_goto(Vector3.FORWARD, 3.4)
			await _phase("carry_run", 2.4)
			_goto(Vector3.BACK, 3.4)
			await _phase("carry_reverse", 2.4)
			await _stop("carry_stop")
			print("CARGO carrier_ok=%s cargo_y_rel=%.3f" % [cargo.get("carrier") == wako.head_anchor, cargo.global_position.y - wako.global_position.y])
		"knockdown":
			# Ragdoll from a run (hard gait reset), recovery, then travel again.
			_goto(Vector3.FORWARD, 3.4)
			await _phase("run", 1.6)
			var knocked: bool = wako.ragdoll.knock_down(Vector3(0, 60, -120), Vector3.INF) if wako.ragdoll else false
			print("KNOCK down=%s" % knocked)
			await _until("ragdoll", func() -> bool: return not (wako.ragdoll.active or wako.ragdoll.pending), 1200)
			await _phase("recovered", 1.0)
			_goto(Vector3.FORWARD, 2.1)
			metrics.mark_motion_start()
			await _phase("walk_after", 1.6)
			await _stop("stop")
		"showcase":
			await _go(Vector3.FORWARD, 1.0, "walk 1.0 m/s", "walk 1.0 m/s ", 1.6)
			await _go(Vector3.FORWARD, 2.1, "jog 2.1 m/s", "jog 2.1 m/s ", 1.2)
			await _go(Vector3.FORWARD, 3.4, "run 3.4 m/s", "run 3.4 m/s ", 1.4)
			await _stop("stop")
			wako.walk_speed = 2.1
			wako.navigate_to(wako.global_position + Vector3(40, -wako.ride_height, 0))
			await _phase("turn 90", 1.6)
			wako.navigate_to(wako.global_position + Vector3(-40, -wako.ride_height, 0))
			await _phase("reverse", 1.8)
			await _stop("stop ")
			wako.face_point(wako.global_position + Vector3(0, 0, 4))
			await _phase("turn in place", 1.6)
	metrics.print_report()
	if args.get("quit", "1") == "1": get_tree().quit()

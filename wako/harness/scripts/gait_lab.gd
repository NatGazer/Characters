extends "res://harness/scripts/stage.gd"
## Gait acceptance lab. One scene, several scenarios chosen by user arg
## `scenario=<flat|terrain|platform|carry|showcase>` (default flat). Every
## scenario drives the real Wako only through its public navigation API and
## prints METRIC lines from harness/scripts/gait_metrics.gd at the end.
##   godot --headless --fixed-fps 120 --path <hw> res://harness/scenes/gait_lab.tscn -- scenario=terrain
## Optional: cam=side|q34|front, quit=0 (keep running), clip=<label prefix to stop after>.
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
	cam_offset = {"side": Vector3(2.7, .75, .35), "q34": Vector3(1.9, 1.05, 1.9), "front": Vector3(.6, .9, -2.6), "far": Vector3(4.2, 1.8, 2.2)}.get(cam, Vector3(2.7, .75, .35))
	cam_smooth = 5.0
	var start := Vector3(0, 1.0, 22)
	if scenario == "terrain": _build_terrain()
	if scenario == "platform":
		start = Vector3(0, 1.45, 0)
		_build_platform()
	wako = spawn_wako(start, "gait_lab")
	cam_follow = wako
	metrics = Metrics.new()
	add_child(metrics)
	_run.call_deferred(scenario)

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

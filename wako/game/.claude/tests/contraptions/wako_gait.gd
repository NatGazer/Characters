extends Node3D
## Native travel commands and same-node head cargo; evaluated pose continuity.
const Worker := preload("res://LogicObjects/Wako/Wako.tscn")
const Part := preload("res://Components/Contraptions/contraption_part.gd")
var worker: RigidBody3D
var cargo: RigidBody3D
var failures := 0
var stage := "settle"
var stage_clock := 0.0
var samples: Dictionary = {}
var _last_serial := -1
var _last_knees: Array[Vector3] = []
var _last_ankles: Array[Quaternion] = []
var _maximum_knee_step := 0.0
var _maximum_ankle_step := 0.0
var _maximum_head_gap := 0.0
var _maximum_head_angle := 0.0
var _maximum_cargo_gap := 0.0
var _maximum_cargo_angle := 0.0
var _cargo_samples := 0
var _last_root := Transform3D.IDENTITY
var _has_root := false
var _maximum_root_step := 0.0
var _maximum_root_angle := 0.0

func _ready() -> void:
	_run.call_deferred()

func _check(ok: bool, message: String) -> void:
	print("CONTRAPTION_GAIT %s %s" % ["ok" if ok else "FAIL", message])
	if not ok: failures += 1

func _advance(seconds: float, label: String) -> void:
	stage = label
	stage_clock = 0.0
	for i in roundi(seconds * Engine.physics_ticks_per_second):
		await get_tree().physics_frame

func _physics_process(delta: float) -> void:
	stage_clock += delta
	if not is_instance_valid(worker) or not worker._pose.evaluated_valid: return
	var pose: SkeletonModifier3D = worker._pose
	if pose.evaluation_serial == _last_serial: return
	_last_serial = pose.evaluation_serial
	var values: Dictionary = samples.get(stage, {"count": 0, "sway_sq": 0.0, "sway": Vector2.ZERO, "roll": 0.0, "speed": 0.0, "turn": 0.0, "run": false, "height_count": 0, "height_sum": 0.0, "height_sq": 0.0})
	values.count += 1
	values.sway_sq += pose._sway_offset * pose._sway_offset
	values.sway.x = minf(values.sway.x, pose._sway_offset)
	values.sway.y = maxf(values.sway.y, pose._sway_offset)
	values.roll = maxf(values.roll, absf(pose._sway_roll))
	values.speed = maxf(values.speed, worker.gait_speed)
	values.turn = maxf(values.turn, absf(worker.turn_rate))
	values.run = values.run or worker._animation.current_animation == "work/run"
	var root: Transform3D = pose.evaluated_worker.affine_inverse() * pose.evaluated_root
	# Heading changes are deliberate native navigation, not a clip discontinuity.
	# Compare the cube's pose in its evaluated model frame for seam/roll continuity.
	root.basis = pose.evaluated_basis.inverse() * pose.evaluated_root.basis
	if _has_root:
		_maximum_root_step = maxf(_maximum_root_step, root.origin.distance_to(_last_root.origin))
		_maximum_root_angle = maxf(_maximum_root_angle, rad_to_deg(root.basis.get_rotation_quaternion().angle_to(_last_root.basis.get_rotation_quaternion())))
	_last_root = root
	_has_root = true
	if stage_clock > .65:
		values.height_count += 1
		values.height_sum += root.origin.y
		values.height_sq += root.origin.y * root.origin.y
	samples[stage] = values
	var knees: Array[Vector3] = []
	var ankles: Array[Quaternion] = []
	for side in 2:
		var knee: Vector3 = pose.evaluated_basis.inverse() * (pose.evaluated_knees[side] - pose.evaluated_hips[side]).normalized()
		var ankle: Quaternion = (pose.evaluated_basis.inverse() * pose.evaluated_ankles[side]).get_rotation_quaternion()
		if _last_knees.size() == 2:
			_maximum_knee_step = maxf(_maximum_knee_step, rad_to_deg(knee.angle_to(_last_knees[side])))
			_maximum_ankle_step = maxf(_maximum_ankle_step, rad_to_deg(ankle.angle_to(_last_ankles[side])))
		knees.append(knee)
		ankles.append(ankle)
	_last_knees = knees
	_last_ankles = ankles
	# The parent rigid body may advance before the next modifier evaluation.
	# Compare in its current frame rather than treating travel as anchor drift.
	var head: Transform3D = worker.global_transform * pose.evaluated_worker.affine_inverse() * pose.evaluated_root
	head.origin += head.basis * Vector3(0, worker.HEAD_OFFSET, 0)
	_maximum_head_gap = maxf(_maximum_head_gap, head.origin.distance_to(worker.head_anchor.global_position))
	_maximum_head_angle = maxf(_maximum_head_angle, rad_to_deg(head.basis.get_rotation_quaternion().angle_to(worker.head_anchor.global_basis.get_rotation_quaternion())))
	if is_instance_valid(cargo) and cargo.carrier == worker.head_anchor and stage_clock > .25:
		var expected := head
		expected.origin += expected.basis * cargo.get("_cargo_anchor")
		_maximum_cargo_gap = maxf(_maximum_cargo_gap, cargo.global_position.distance_to(expected.origin))
		_maximum_cargo_angle = maxf(_maximum_cargo_angle, rad_to_deg(cargo.global_basis.get_rotation_quaternion().angle_to(expected.basis.get_rotation_quaternion())))
		_cargo_samples += 1

func _run() -> void:
	var floor := StaticBody3D.new()
	floor.position.y = -.5
	add_child(floor)
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(100, 1, 100)
	collision.shape = box
	floor.add_child(collision)
	worker = Worker.instantiate()
	worker.position.y = .85
	worker.worker_id = "gait-review"
	add_child(worker)
	await _advance(1.0, "idle")
	worker.walk_speed = 2.1
	worker.navigate_to(worker.global_position + Vector3(0, -worker.ride_height, -30))
	await _advance(2.5, "walk")
	worker.navigate_to(worker.global_position + Vector3(-20, -worker.ride_height, -3))
	await _advance(1.5, "turn")
	worker.walk_speed = 3.4
	worker.navigate_to(worker.global_position + Vector3(25, -worker.ride_height, -12))
	await _advance(2.5, "run")
	worker.stop_navigation()
	await _advance(.8, "idle_after_run")
	cargo = Part.new()
	cargo.setup("armor", "gait-head-load", true)
	add_child(cargo)
	cargo.set_carried(worker.head_anchor, Vector3(0, float(cargo.definition.size.y) * .5 + .03, 0))
	worker.set_cargo(cargo.mass)
	# Equal steady walking speed isolates load-aware posing from slower hauling.
	worker.walk_speed = 2.1 / (1.0 - cargo.mass / 140.0)
	worker.navigate_to(worker.global_position + Vector3(0, -worker.ride_height, -25))
	await _advance(2.5, "head_carry")
	worker.navigate_to(worker.global_position + Vector3(-20, -worker.ride_height, 3))
	await _advance(1.5, "head_turn")
	worker.stop_navigation()
	await _advance(.8, "head_idle")
	_check(cargo.carrier == worker.head_anchor and is_equal_approx(worker.mass, 22.0 + worker.back_tool.holder_mass() + cargo.mass), "the same finite-mass 32 kg part remains on the head fixture with one copy of payload mass")
	cargo.set_carried(null)
	cargo.global_position = worker.global_position + Vector3(2, -.7, 0)
	worker.set_cargo(0)
	worker.apply_hit(Vector3(18, 2, 0))
	await _advance(1.2, "danger")
	_check(worker.on_ground and not worker.ragdoll.is_down(), "native travel and modest danger reaction retain actual grounded support")
	var walk: Dictionary = samples.get("walk", {})
	var load: Dictionary = samples.get("head_carry", {})
	_check(not walk.is_empty() and walk.count > 100 and walk.sway.x < -.01 and walk.sway.y > .01, "walk shifts the cube toward both support feet through real evaluated poses")
	var walk_rms := sqrt(float(walk.get("sway_sq", 0)) / maxf(float(walk.get("count", 0)), 1))
	var load_rms := sqrt(float(load.get("sway_sq", 0)) / maxf(float(load.get("count", 0)), 1))
	_check(not load.is_empty() and load.count > 100 and load_rms < walk_rms * .85 and load.speed > 1.8, "head-loaded travel reduces sway at equivalent native walking speed")
	_check(samples.get("run", {}).get("run", false) and samples.get("run", {}).get("speed", 0) > 2.6, "actual higher-speed locomotion blends into the authored running clip")
	_check(samples.get("turn", {}).get("turn", 0) > .5 and samples.get("turn", {}).get("roll", 1) < .10, "turn bank follows actual heading changes within a small finite pose range")
	_check(_maximum_knee_step < 12 and _maximum_ankle_step < 18, "loaded turning and walk/run/idle/danger transitions retain continuous knees and ankles")
	_check(_maximum_head_gap < .01 and _maximum_head_angle < 1.0, "evaluated head cargo anchor stays on the moving cube through sway and counterroll")
	_check(_cargo_samples > 200 and _maximum_cargo_gap < .04 and _maximum_cargo_angle < 8.0, "the actual carried part remains within 4 cm and 8 degrees of evaluated head contact throughout loaded travel")
	var walk_height := _height_deviation(walk)
	var loaded_height := _height_deviation(load)
	_check(walk_height > .005 and loaded_height < walk_height * .7, "loaded short steps keep the actual cube vertically quieter at the same travel speed")
	_check(_maximum_root_step < .025 and _maximum_root_angle < 6.0, "actual cube motion remains continuous across loop seams and walk/run/carry/idle transitions")
	print("CONTRAPTION_GAIT walk_rms=%.4f load_rms=%.4f knee_step=%.3f ankle_step=%.3f head_gap=%.4f head_angle=%.3f cargo_gap=%.4f cargo_angle=%.3f" % [walk_rms, load_rms, _maximum_knee_step, _maximum_ankle_step, _maximum_head_gap, _maximum_head_angle, _maximum_cargo_gap, _maximum_cargo_angle])
	print("CONTRAPTION_GAIT %s" % ["PASS" if failures == 0 else "FAIL (%d)" % failures])
	print("CONTRAPTION_GAIT body_walk_sd=%.4f body_load_sd=%.4f root_step=%.4f root_angle=%.3f" % [walk_height,loaded_height,_maximum_root_step,_maximum_root_angle])
	Shortcuts.graceful_quit(0 if failures == 0 else 1)

func _height_deviation(values: Dictionary) -> float:
	var count := maxf(float(values.get("height_count", 0)), 1.0)
	var average := float(values.get("height_sum", 0.0)) / count
	return sqrt(maxf(float(values.get("height_sq", 0.0)) / count - average * average, 0.0))

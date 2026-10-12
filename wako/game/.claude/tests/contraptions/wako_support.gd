extends Node3D
## Physical support velocity/reaction, impulse interruption and falling on the original Wako model.
const Worker := preload("res://LogicObjects/Wako/Wako.tscn")
var failures := 0
var _track_gait := false
var _last_evaluation := -1
var _last_knees: Array[Vector3] = []
var _last_ankles: Array[Quaternion] = []
var _maximum_knee_step := 0.0
var _maximum_ankle_step := 0.0
var _gait_samples := 0
var _gait_worker: RigidBody3D
var _sway_range := Vector2.ZERO
var _maximum_roll := 0.0


func _ready() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	print("CONTRAPTION_SUPPORT %s %s" % ["ok" if ok else "FAIL", message])
	if not ok: failures += 1


func _advance(ticks: int) -> void:
	for i in ticks:
		await get_tree().physics_frame


func _physics_process(_delta: float) -> void:
	if not _track_gait or not is_instance_valid(_gait_worker): return
	for pose: Node in _gait_worker._skeleton.get_children():
		if not pose is SkeletonModifier3D or not pose.get("evaluated_valid"): continue
		if pose.evaluation_serial == _last_evaluation: continue
		_last_evaluation = pose.evaluation_serial
		_sway_range.x = minf(_sway_range.x, float(pose._sway_offset))
		_sway_range.y = maxf(_sway_range.y, float(pose._sway_offset))
		_maximum_roll = maxf(_maximum_roll, absf(pose._sway_roll))
		var knees: Array[Vector3] = []
		var ankles: Array[Quaternion] = []
		for side in 2:
			var direction: Vector3 = pose.evaluated_basis.inverse() * (pose.evaluated_knees[side] - pose.evaluated_hips[side]).normalized()
			knees.append(direction)
			var ankle: Quaternion = (pose.evaluated_basis.inverse() * pose.evaluated_ankles[side]).get_rotation_quaternion()
			ankles.append(ankle)
			if _last_knees.size() == 2:
				var step := rad_to_deg(direction.angle_to(_last_knees[side]))
				_maximum_knee_step = maxf(_maximum_knee_step,step)
				if step > 12.0 and "--support-debug" in OS.get_cmdline_user_args():
					print("CONTRAPTION_SUPPORT seam side=%d step=%.3f speed=%.3f clip=%s point=%s target=%s sole=%s hip=%s reaction=%.3f"%[side,step,_gait_worker.gait_speed,_gait_worker._animation.current_animation,_gait_worker.global_position,pose._targets[side],pose.evaluated_soles[side],pose.evaluated_hips[side],_gait_worker._reaction])
					print("CONTRAPTION_SUPPORT step ahead=%s lifts=%s side=%d weights=%s ground=%s surfaces=%s"%[pose._step_ahead,pose._step_lifts,pose._step_side,pose._plant_weights,_gait_worker._ground_point,pose._terrain_points])
			if _last_ankles.size() == 2: _maximum_ankle_step = maxf(_maximum_ankle_step, rad_to_deg(ankle.angle_to(_last_ankles[side])))
		_last_knees = knees
		_last_ankles = ankles
		_gait_samples += 1


func _run() -> void:
	var ground := StaticBody3D.new()
	add_child(ground)
	ground.position.y = -0.5
	_add_box(ground, Vector3(100, 1, 100))
	# A free horizontal deck isolates moving-support response. Gravity is disabled on
	# this test fixture only; the Wako has normal gravity and applies reactions to it.
	var deck := RigidBody3D.new()
	deck.mass = 1500
	deck.gravity_scale = 0
	deck.linear_damp = 0
	deck.angular_damp = 0
	deck.axis_lock_angular_x = true
	deck.axis_lock_angular_y = true
	deck.axis_lock_angular_z = true
	add_child(deck)
	deck.position = Vector3(0, 3, 0)
	_add_box(deck, Vector3(10, .4, 10))
	deck.linear_velocity = Vector3(.6, 0, 0)
	var wako: RigidBody3D = Worker.instantiate()
	add_child(wako)
	wako.global_position = Vector3(0, 4.05, 0)
	var start := wako.global_position
	await _advance(360)
	_check(wako.on_ground and wako.ground_velocity.x > .2, "helper samples the real moving deck velocity")
	_check(wako.global_position.x - start.x > .6, "idle Wako travels with its moving support using physical forces")
	_check(deck.linear_velocity.y < -.01, "Wako leg support applies a weight reaction to the deck")
	var speed_before := wako.linear_velocity
	wako.apply_central_impulse(Vector3(35, 42, 0))
	await _advance(3)
	_check((wako.linear_velocity - speed_before).length() > 1.0 and wako.linear_velocity.is_finite(), "a hit changes the actual helper body velocity")
	# Let it leave the support naturally, then verify it lands safely rather than remaining suspended.
	wako.apply_central_impulse(Vector3(220, 0, 0))
	await _advance(960)
	_check(wako.global_position.is_finite() and wako.global_position.y > .2 and wako.global_position.y < 1.6,
		"a displaced helper falls under gravity and regains ground support")
	# Grounded turns and idle handoffs exercise the actual named-bone modifier,
	# including plant release. Query its evaluated cache, not restored clip poses.
	_gait_worker = wako
	_track_gait = true
	wako.navigate_to(wako.global_position + Vector3(-5, -wako.ride_height, 0))
	await _advance(360)
	wako.stop_navigation()
	await _advance(180)
	wako.walk_speed = 3.2
	wako.navigate_to(wako.global_position + Vector3(0, -wako.ride_height, -6))
	await _advance(360)
	wako.stop_navigation()
	await _advance(180)
	_check(_gait_samples > 500 and _maximum_knee_step < 12.0 and _maximum_ankle_step < 18.0, "walking, turning, running and idle transitions keep evaluated knees and ankles continuous without leg flips")
	_check(_sway_range.x < -.01 and _sway_range.y > .01 and _maximum_roll < .10, "actual supported gait shifts across both planted legs with bounded counterroll and turn banking")
	print("CONTRAPTION_SUPPORT gait_samples=%d maximum_knee_step=%.3f maximum_ankle_step=%.3f degrees" % [_gait_samples, _maximum_knee_step, _maximum_ankle_step])
	print("CONTRAPTION_SUPPORT %s" % ["PASS" if failures == 0 else "FAIL (%d)" % failures])
	Shortcuts.graceful_quit(0 if failures == 0 else 1)


func _add_box(body: PhysicsBody3D, size: Vector3) -> void:
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)

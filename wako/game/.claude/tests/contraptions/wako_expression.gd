extends Node3D
## Real standalone helpers: shared skin resource, independent native expression
## clocks and mesh instance parameters. Visual lid orientation is render-tested.
const Worker := preload("res://LogicObjects/Wako/Wako.tscn")
const Fauna := preload("res://Components/Contraptions/machine_fauna.gd")
const HolderGeometry := preload("res://LogicObjects/Wako/wako_back_holder_geometry.gd")
var workers: Array[RigidBody3D] = []
var failures := 0
var checks := 0

func _ready() -> void:
	_run.call_deferred()

func _check(ok: bool, message: String) -> void:
	checks += 1
	print("CONTRAPTION_WAKO_EXPRESSION %s %s" % ["ok" if ok else "FAIL", message])
	if not ok: failures += 1

func _advance(ticks: int) -> void:
	for tick in ticks: await get_tree().physics_frame

func _run() -> void:
	var floor := StaticBody3D.new()
	floor.position.y = -.5
	add_child(floor)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(30,1,30)
	collision.shape = shape
	floor.add_child(collision)
	for i in 2:
		var worker: RigidBody3D = Worker.instantiate()
		worker.worker_id = "expression_%d" % i
		worker.position = Vector3((i * 2.0 - 1.0) * .6,.85,0)
		worker.paused = true
		add_child(worker)
		workers.append(worker)
	await _advance(120)
	_check(workers.all(func(w: Node) -> bool: return w.on_ground and w.global_position.is_finite()),
		"two standalone helpers settle on actual ground without a task coordinator")
	_check(workers[0]._skin_mesh.get_active_material(0) == workers[1]._skin_mesh.get_active_material(0),
		"helper skins share the same shader material resource")
	var guard := Fauna.new()
	guard.configure(null,"cliff_guard",Vector3(6,0,0))
	add_child(guard)
	await _advance(8) # Allow the shared 30 Hz expression clock its first write.
	guard.assembly.active = false
	guard.mind_host.shutdown()
	for part: RigidBody3D in guard.assembly.parts.values(): part.freeze = true
	var captive: RigidBody3D = guard._captive_worker
	var bay: RigidBody3D
	for part: RigidBody3D in guard.assembly.parts.values():
		if part.kind == "container": bay = part
	# The authored 22 kg body keeps its permanent finite back holder in captivity.
	var expected_captive_mass := 22.0 + HolderGeometry.MASS
	var closed := [false,false]
	var asynchronous_blink := false
	var finite_values := true
	var captive_blinked := false
	for tick in 960:
		await get_tree().physics_frame
		var openness: Array[float] = []
		for i in 2:
			var eye: float = workers[i]._skin_mesh.get_instance_shader_parameter(&"eye_openness")
			var gaze: Vector2 = workers[i]._skin_mesh.get_instance_shader_parameter(&"gaze_uv_offset")
			finite_values = finite_values and is_finite(eye) and eye >= 0 and eye <= 1 and gaze.is_finite()
			closed[i] = closed[i] or eye < .06
			openness.append(eye)
		asynchronous_blink = asynchronous_blink or (minf(openness[0],openness[1]) < .06 and maxf(openness[0],openness[1]) > .95)
		var captive_eye: float = captive._skin_mesh.get_instance_shader_parameter(&"eye_openness")
		captive_blinked = captive_blinked or (captive_eye < .06 and maxf(openness[0],openness[1]) > .95)
	_check(finite_values and closed.all(func(value: bool) -> bool: return value),
		"actual expression updates keep finite values and both helpers complete natural blinks")
	_check(asynchronous_blink,
		"one helper can blink while the other remains open despite their shared material")
	_check(captive_blinked and captive._skin_mesh.get_active_material(0) == workers[0]._skin_mesh.get_active_material(0)
		and not captive.is_physics_processing() and captive.freeze and not captive.is_in_group(&"wako_helpers")
		and is_equal_approx(captive.mass,expected_captive_mass)
		and is_equal_approx(bay.mass,float(bay.definition.mass)+expected_captive_mass) and bay.stored_resources.is_empty(),
		"same secured captive and its finite back holder blink independently without locomotion, helper jobs or an inventory duplicate")
	_finish()

func _finish() -> void:
	print("CONTRAPTION_WAKO_EXPRESSION %s %d checks" % ["PASS" if failures == 0 else "FAIL (%d)" % failures,checks])
	Shortcuts.graceful_quit(0 if failures == 0 else 1)

extends "res://harness/scripts/stage.gd"
## Micro-benchmark of the face engine pieces against the personality tick
## (same machine load), for the per-Wako cost report.
const Props := preload("res://harness/scripts/face_props.gd")
var wako: RigidBody3D
var done := false

func setup() -> void:
	wako = spawn_wako(Vector3(0, .86, 0), "face_bench")
	cam_target = Vector3(0, 1.1, -.2)
	cam_offset = Vector3(.35, .12, -1.45)
	Props.make_player(self, Vector3(-1.2, .5, -2.6))

func _bench(label: String, fn: Callable, n := 3000) -> float:
	var t0 := Time.get_ticks_usec()
	for i in n: fn.call()
	var per := float(Time.get_ticks_usec() - t0) / n
	print("BENCH %-22s %7.2f usec" % [label, per])
	return per

func scenario(_delta: float) -> void:
	if done or clock < 1.5: return
	done = true
	var e: RefCounted = wako.eyes
	var dt := 1.0 / 120.0
	_bench("empty call", func() -> void: pass)
	_bench("eyes.advance", func() -> void: e.advance(dt))
	_bench("eyes._brain", func() -> void: e._brain(1.0 / 30.0))
	_bench("eyes._update_lod", func() -> void: e._update_lod())
	_bench("eyes._poll_events", func() -> void: e._poll_events(1.0 / 30.0))
	_bench("eyes._choose_gaze", func() -> void: e._choose_gaze(1.0 / 30.0))
	_bench("eyes._compose", func() -> void: e._compose())
	_bench("eyes._advance_blink", func() -> void: e._advance_blink(dt))
	_bench("eyes._advance_gaze", func() -> void: e._gaze_static = 0; e._advance_gaze(dt))
	_bench("eyes._uv_toward", func() -> void: e._uv_toward(Vector3(1, 1, -3)))
	_bench("eyes._eye_frame", func() -> void: e._eye_frame())
	_bench("eyes._settle", func() -> void: e._settle(dt))
	_bench("eyes._upload(same)", func() -> void: e._upload())
	_bench("set_instance_param", func() -> void: wako._skin_mesh.set_instance_shader_parameter(&"eye_smile", randf()))
	_bench("personality.advance", func() -> void: wako.personality.advance(dt), 1000)
	_bench("attention.scan", func() -> void: wako.personality.attention.scan(Global.Player, wako.personality._can_see), 1000)
	get_tree().quit()

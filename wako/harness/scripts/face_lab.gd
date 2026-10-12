extends "res://harness/scripts/stage.gd"
## Face test: one Wako in close-up cycling REAL triggers through the shipped
## code paths (attention, work strokes with admitted contacts, the greeting
## smile, a hit, a live hostile notice -> alarm -> relief, a completion).
## --part=a: idle life + work strokes; b: greeting + hit; c: threat + relief + win.
const Props := preload("res://harness/scripts/face_props.gd")
var wako: RigidBody3D
var player: Node3D
var hostile: Node3D
var fastener: Node3D
var part := "a"
var _strokes := 0
var _flags := {}
var _log_next := 0.0

func setup() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--part="): part = arg.trim_prefix("--part=")
	wako = spawn_wako(Vector3(0, .86, 0), "face_lab_" + part)
	Props.bind_atlas(wako)
	cam_target = Vector3(0, 1.1, -.2)
	cam_offset = Vector3(.32, .1, -1.55)
	player = Props.make_player(self, Vector3(-2.0, .5, -2.8))
	fastener = Node3D.new()
	fastener.name = "Fastener"
	add_child(fastener)
	var mesh := MeshInstance3D.new()
	var bolt := CylinderMesh.new()
	bolt.top_radius = .03
	bolt.bottom_radius = .03
	bolt.height = .06
	mesh.mesh = bolt
	fastener.add_child(mesh)
	fastener.position = Vector3(.15, .05, -.55)

func _once(key: String) -> bool:
	if _flags.has(key): return false
	_flags[key] = true
	return true

func scenario(_delta: float) -> void:
	match part:
		"a": _part_a()
		"b": _part_b()
		"c": _part_c()
	if clock >= _log_next:
		_log_next += .1
		var e: RefCounted = wako.eyes
		var v: Array = e._value
		print("LAB t=%.2f open=%.2f gaze=(%.4f,%.4f) uc=%.2f lr=%.2f tilt=%.2f dil=%.2f pop=%.2f smile=%.2f mouth=(%.2f,%.2f,%.2f) alarm=%.2f act=%s p=%.2f voice=%s/%.2f att=%s" % [clock,
			e._blink_value, e.gaze.x, e.gaze.y, v[0], v[1], v[2], v[4], v[5], v[6], v[7], v[8], v[9], v[11],
			wako.action, wako.action_progress, wako.personality.voice_kind, wako.personality.voice_clock, wako.personality.attention.kind])

func _part_a() -> void:
	# Idle life: the player strolls past; attention, saccades, blinks.
	player.position.x = -2.0 + 3.0 * smoothstep(.2, 2.6, clock)
	if clock < 2.4:
		caption("idle: attention, saccades, micro-saccades, blinks")
		return
	# Real work strokes on a fastener at the toe (effort -> contact -> glint).
	caption("work strokes: draw squint, strike, admitted contact")
	if _once("work"):
		wako.work_target = fastener
		wako.face_point(fastener.global_position)
	if wako.action.is_empty() and _strokes < 3:
		_strokes += 1
		wako.begin_action("assemble")
	# Keep the fastener where this real toe lands so the helper's own
	# admission test can pass at the .56 contact.
	if wako.action == "assemble" and wako.action_progress > .40 and wako.action_progress < .55 and wako.foot_grip_valid:
		var toe: Transform3D = wako.foot_grip_transform
		fastener.global_position = toe.origin + toe.basis.y.normalized() * (.035 + wako.foot_tool_span())

func _part_b() -> void:
	player.position = Vector3(-.35, .5, -2.4)
	if clock < 2.2:
		caption("greeting: eye contact, smile, hello")
		if clock > .4 and _once("smile"):
			wako.personality._next_smile = 0.0
		return
	caption("hit: surprise, oops, recoil")
	if _once("hit"):
		wako.apply_hit(Vector3(.9, 0, .4) * wako.mass * 1.6)

func _part_c() -> void:
	player.position = Vector3(1.6, .5, -3.4)
	if clock < 1.0:
		caption("watching")
		return
	if clock < 3.2:
		caption("live hostile: widen -> focus -> worried alarm")
		if _once("hostile"): hostile = Props.make_hostile(self, Vector3(-4.5, 0, -5.0))
		return
	if clock < 4.6:
		caption("threat gone: relief + sigh")
		if _once("kill"): Props.kill_hostile(hostile)
		return
	caption("job completed: joy + yay")
	if _once("done"): wako.personality.work_completed("build", "lab")

extends "res://harness/scripts/stage.gd"
## Face cost probe (after the critic's perf8): 8 idle Wako with real idle play,
## a strolling player, then a live hostile (alert, no fear) that is later
## disabled. Prints per-Wako usec/tick of the face engine (eyes.advance, its
## own profiler) and of personality.advance (attention scans included).
## --far: camera 35 m away (face LOD 2).
const Props := preload("res://harness/scripts/face_props.gd")
const COUNT := 8
var crowd: Array[RigidBody3D] = []
var player: Node3D
var hostile: Node3D
var service: Node
var _start := {}
var _measuring := false
var driver: Node

func setup() -> void:
	service = Props.make_coordinator(self, false)
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	for i in COUNT:
		var w: RigidBody3D = Props.timed_wako(WAKO)
		w.worker_id = "perf_%02d" % i
		w.position = Vector3((i % 4 - 1.5) * 1.4, .86, floorf(i / 4.0) * 1.7)
		w.configure(service)
		add_child(w)
		w._heading = rng.randf_range(-.4, .4)
		w._idle_heading = w._heading
		crowd.append(w)
	player = Props.make_player(self, Vector3(-3.5, .5, -2.6))
	driver = Props.drive_faces(self, crowd)
	cam_target = Vector3(0, .95, .8)
	cam_offset = Vector3(0, 6.0, -35.0) if "--far" in OS.get_cmdline_user_args() else Vector3(.4, .8, -5.5)

func scenario(_delta: float) -> void:
	player.position.x = -3.5 + 7.0 * (.5 - .5 * cos(clock * .7))
	if clock > 7.0 and not is_instance_valid(hostile) and clock < 7.1:
		hostile = Props.make_hostile(self, Vector3(1.0, 0, -13.0))
	if clock > 11.0 and is_instance_valid(hostile) and hostile.alive:
		Props.kill_hostile(hostile)
	if clock > 2.0 and not _measuring and _start.is_empty():
		_measuring = true
		for w in crowd: _start[w] = [int(driver.usec.get(w, 0)), int(driver.ticks.get(w, 0)), w.personality.profile_total_usec, w.personality.profile_ticks, w.eyes.uploads]
	if clock > 15.0 and _measuring:
		_measuring = false
		var face := 0.0
		var pers := 0.0
		var uploads := 0
		for w in crowd:
			var a: Array = _start[w]
			face += float(int(driver.usec[w]) - a[0]) / maxf(int(driver.ticks[w]) - a[1], 1)
			pers += float(w.personality.profile_total_usec - a[2]) / maxf(w.personality.profile_ticks - a[3], 1)
			uploads += w.eyes.uploads - a[4]
		print("FACE_PERF face_usec_per_wako_tick=%.2f personality_usec_per_wako_tick=%.2f uploads_per_wako_s=%.1f" % [face / COUNT, pers / COUNT, float(uploads) / COUNT / 13.0])
		get_tree().quit()

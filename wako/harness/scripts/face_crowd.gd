extends "res://harness/scripts/stage.gd"
## Crowd gaze desync: 12 idle Wako, a strolling player and a few REAL events
## (a hit, a job completion, a drop landing). Prints synchrony statistics:
## how many share one gaze target, how many watch the player at once, how
## often saccades/blinks coincide, plus per-Wako face cost.
## --headless-stats: run without the camera close-up requirements.
const Props := preload("res://harness/scripts/face_props.gd")
const COUNT := 12
var crowd: Array[RigidBody3D] = []
var player: Node3D
var _flags := {}
var _samples := 0
var _same_sum := 0.0
var _same_max := 0.0
var _player_sum := 0.0
var _player_max := 0
var _windows := 0
var _sync_saccade_windows := 0
var _sync_blink_samples := 0
var _last_saccades: Array[int] = []
var _window_starts: Array[int] = []
var _window_clock := 0.0
var _rng := RandomNumberGenerator.new()
var _gaze_prev := {}
var _gaze_step_max := 0.0
var _smile_seen := {}
var _smile_window_max := 0
var _greet_seen := {}
var _greet_window_max := 0
var _alarm_without_threat := 0.0
var _gaze_spread_sum := 0.0

var service: Node
var driver: Node

func setup() -> void:
	_rng.seed = 4242
	# Real idle play (dance, hops, high-fives, routes) needs a scheduler/yard.
	service = Props.make_coordinator(self, false)
	for i in COUNT:
		var col := i % 4
		var row := floori(i / 4.0)
		var pos := Vector3((col - 1.5) * 1.3 + _rng.randf_range(-.15, .15), .86, row * 1.6 + _rng.randf_range(-.2, .2))
		var w: RigidBody3D = WAKO.instantiate()
		w.worker_id = "crowd_%02d" % i
		w.position = pos
		w.configure(service)
		add_child(w)
		w._heading = _rng.randf_range(-.45, .45)
		w._idle_heading = w._heading
		Props.bind_atlas(w)
		crowd.append(w)
		_last_saccades.append(0)
		_window_starts.append(0)
	player = Props.make_player(self, Vector3(-3.5, .5, -2.6))
	driver = Props.drive_faces(self, crowd)
	cam_target = Vector3(0, .95, 1.4)
	cam_offset = Vector3(.4, .55, -5.0)
	# --far: camera 35 m away (face LOD 2) to measure the crowd cost at distance.
	if "--far" in OS.get_cmdline_user_args(): cam_offset = Vector3(0, 6.0, -35.0)

func _once(key: String) -> bool:
	if _flags.has(key): return false
	_flags[key] = true
	return true

func scenario(delta: float) -> void:
	player.position.x = -3.5 + 7.0 * (.5 - .5 * cos(clock * .9))
	caption("crowd t=%.1f: player strolls; hit #5 @1.8s, #2 finishes a job @3.0s, #10 dropped @4.2s" % clock)
	if clock > 1.8 and _once("hit"): crowd[5].apply_hit(Vector3(-.6, 0, .5) * crowd[5].mass * 1.5)
	if clock > 3.0 and _once("done"): crowd[2].personality.work_completed("build", "crowd")
	if clock > 4.2 and _once("drop"):
		crowd[10].global_position += Vector3.UP * 1.1
		crowd[10].linear_velocity = Vector3.ZERO
	_sample(delta)

func _sample(delta: float) -> void:
	if clock < .5: return
	_samples += 1
	var keys := {}
	var watching_player := 0
	var blinking := 0
	for i in COUNT:
		var e: RefCounted = crowd[i].eyes
		if _gaze_prev.has(i): _gaze_step_max = maxf(_gaze_step_max, e.gaze.distance_to(_gaze_prev[i]))
		_gaze_prev[i] = e.gaze
		var key: int = e._want_key
		keys[key] = int(keys.get(key, 0)) + 1
		if crowd[i].personality.attention.kind == &"player" and e._want_node and e._want_node.get_ref() == player: watching_player += 1
		if e._blink_value < .5: blinking += 1
	# Smiles: how many different Wako showed an eye-smile within the last 1 s
	# (the crowd budget keeps this well under 40%).
	var smiling_window := 0
	var greeting_window := 0
	var gaze_sum := Vector2.ZERO
	var gazes: Array[Vector2] = []
	for i in COUNT:
		var e: RefCounted = crowd[i].eyes
		if float(e._value[e.SMILE]) > .5: _smile_seen[i] = clock
		if clock - float(_smile_seen.get(i, -10.0)) < 1.0: smiling_window += 1
		if float(crowd[i].personality.smile_weight) > .5: _greet_seen[i] = clock
		if clock - float(_greet_seen.get(i, -10.0)) < 1.0: greeting_window += 1
		var mesh: MeshInstance3D = crowd[i]._skin_mesh
		var alarm: Variant = mesh.get_instance_shader_parameter(&"face_alarm")
		if alarm != null and float(alarm) > .1 and crowd[i].personality._actual_threat() == null: _alarm_without_threat += delta
		gazes.append(e.gaze)
		gaze_sum += e.gaze
	_smile_window_max = maxi(_smile_window_max, smiling_window)
	_greet_window_max = maxi(_greet_window_max, greeting_window)
	var mean_gaze := gaze_sum / COUNT
	var spread := 0.0
	for g in gazes: spread += g.distance_to(mean_gaze)
	_gaze_spread_sum += spread / COUNT
	var same := 0
	for k in keys: same = maxi(same, int(keys[k]))
	_same_sum += float(same) / COUNT
	_same_max = maxf(_same_max, float(same) / COUNT)
	_player_sum += watching_player
	_player_max = maxi(_player_max, watching_player)
	if blinking * 2 > COUNT: _sync_blink_samples += 1
	_window_clock += delta
	if _window_clock >= .1:
		_window_clock = 0.0
		_windows += 1
		var starters := 0
		for i in COUNT:
			var s: int = crowd[i].eyes.events.saccade
			if s != _last_saccades[i]: starters += 1
			_last_saccades[i] = s
		if starters * 2 > COUNT: _sync_saccade_windows += 1

func _exit_tree() -> void:
	if _samples == 0: return
	var eyes_usec := 0.0
	var pers_usec := 0.0
	var scans := 0
	var scan_usec := 0
	var uploads := 0
	var saccades := 0
	var blinks := 0
	for w in crowd:
		eyes_usec += driver.per_tick(w)
		pers_usec += float(w.personality.profile_total_usec) / maxf(w.personality.profile_ticks, 1)
		scans += w.personality.attention.profile_scans
		scan_usec += w.personality.attention.profile_usec
		uploads += w.eyes.uploads
		saccades += w.eyes.events.saccade
		blinks += w.eyes.events.blink
	print("CROWD samples=%d mean_share_same_target=%.2f max_share=%.2f mean_player_watchers=%.2f/%d max_player_watchers=%d sync_saccade_windows=%d/%d sync_blink_ticks=%d max_gaze_step=%.4f" % [
		_samples, _same_sum / _samples, _same_max, _player_sum / _samples, COUNT, _player_max, _sync_saccade_windows, _windows, _sync_blink_samples, _gaze_step_max])
	print("CROWD smiles: greeting smiles max %d/%d within any 1 s window (%.0f%%); any eye-smile (play contacts, voices, wins included) max %d/%d (%.0f%%); face_alarm>.1 without a live threat for %.2f Wako-seconds; mean gaze spread %.4f UV (range +-%.3f)" % [
		_greet_window_max, COUNT, 100.0 * _greet_window_max / COUNT, _smile_window_max, COUNT, 100.0 * _smile_window_max / COUNT, _alarm_without_threat, _gaze_spread_sum / _samples, .03])
	print("CROWD per-Wako avg usec/tick eyes=%.1f personality=%.1f attention_scan=%.1f usec/scan; saccades=%d blinks=%d uploads=%d over %.1fs" % [
		eyes_usec / COUNT, pers_usec / COUNT, float(scan_usec) / maxf(scans, 1), saccades, blinks, uploads, clock])

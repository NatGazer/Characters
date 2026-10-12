extends "res://harness/scripts/stage.gd"
## Headless checks for the face/attention fixes with the real yard scheduler:
## 1. foot-held gun gaze looks at the real aim target, not the gun node;
## 2. a live hostile notice widens the eyes before the focus/squint beat;
## 3. a Wako without line of sight that HEARS a warning keeps the live threat
##    in attention for seconds (not a single .29 s scan);
## 4. completion/contact events reach the shared attention board.
const Props := preload("res://harness/scripts/face_props.gd")
var service: Node
var wakos: Array[RigidBody3D] = []
var hostile: Node3D
var _phase := "setup"
var _results := {}
var _gun_point := Vector3(-3.0, 1.2, -4.0)
var _gun_ok := 0
var _gun_samples := 0
var _widen_peak := -1.0
var _focus_peak := -1.0
var _widen_max := 0.0
var _focus_max := 0.0
var _uc_min := 1.0
var _hidden_alert_time := 0.0
var _hidden_heard := false
var _hostile_time := -1.0
var _failures := 0
var _paused: Array[RigidBody3D] = []
var _closed := [false, false]
var _async_blink := false
var _finite := true
var _shared_material := false

func setup() -> void:
	service = Props.make_coordinator(self, true)
	add_box(Vector3(-2.0, .9, -1.4), Vector3(1.6, 1.8, .3), Color(.4, .35, .3))
	for i in 3:
		var w: RigidBody3D = WAKO.instantiate()
		w.worker_id = "check_%d" % i
		w.position = [Vector3(0, .86, 0), Vector3(2.0, .86, 0), Vector3(-2.0, .86, 0)][i]
		w.configure(service)
		add_child(w)
		wakos.append(w)
	# Two paused standalone helpers (like the package's expression test).
	for i in 2:
		var p: RigidBody3D = WAKO.instantiate()
		p.worker_id = "expression_%d" % i
		p.position = Vector3((i * 2.0 - 1.0) * .6 + 8.0, .86, 0)
		p.paused = true
		add_child(p)
		_paused.append(p)
	cam_target = Vector3(0, 1, 0)

func _check(ok: bool, label: String) -> void:
	print("FACE_CHECK %s %s" % ["ok" if ok else "FAIL", label])
	if not ok: _failures += 1

func _sample_blinks() -> void:
	var open: Array[float] = []
	for i in 2:
		var eye: Variant = _paused[i]._skin_mesh.get_instance_shader_parameter(&"eye_openness")
		var value := float(eye) if eye != null else 1.0
		_finite = _finite and is_finite(value) and value >= 0.0 and value <= 1.0
		_closed[i] = _closed[i] or value < .06
		open.append(value)
	_async_blink = _async_blink or (minf(open[0], open[1]) < .06 and maxf(open[0], open[1]) > .95)

func scenario(delta: float) -> void:
	if clock > 1.0 and clock < 9.0: _sample_blinks()
	if clock < .5: return
	var gun_wako := wakos[1]
	if clock < 2.0:
		gun_wako.work_target = gun_wako.portable_gun
		gun_wako.portable_gun.desired_target = _gun_point
		if clock > 1.0:
			_gun_samples += 1
			if gun_wako.eyes._want_point.distance_to(_gun_point) < .01 and gun_wako.eyes.gaze.y > .004: _gun_ok += 1
		return
	if not is_instance_valid(hostile):
		gun_wako.work_target = null
		gun_wako.portable_gun.desired_target = Vector3.INF
		_check(_gun_ok > _gun_samples * .9, "gun hold gaze follows the real aim target (%d/%d samples), not the gun node" % [_gun_ok, _gun_samples])
		hostile = Props.make_hostile(self, Vector3(1.0, 0, -13.0))
		_hostile_time = clock
	var age := clock - _hostile_time
	var watcher := wakos[0]
	var widen: float = watcher.threat_watch.notice_widen
	var focus: float = watcher.threat_watch.notice_focus
	if widen > _widen_max: _widen_max = widen; _widen_peak = age
	if focus > _focus_max: _focus_max = focus; _focus_peak = age
	if age < 1.0: _uc_min = minf(_uc_min, watcher.eyes._value[0])
	var hidden := wakos[2]
	if hidden.personality.heard_age < 10.0: _hidden_heard = true
	if hidden.personality._actual_threat() != null: _hidden_alert_time += delta
	if age > 6.6 and _phase != "done":
		_phase = "done"
		_check(_widen_peak >= 0.0 and _focus_peak > _widen_peak and _widen_max > .8, "notice widens first (widen peak %.2fs, focus peak %.2fs)" % [_widen_peak, _focus_peak])
		_check(_uc_min < 0.0, "upper lids retract above the disc during the notice (min %.2f)" % _uc_min)
		var hidden_sees: bool = hidden.personality._can_see(hostile._core.global_position, hostile._core)
		_check(not hidden_sees, "occluded Wako has no line of sight to the hostile")
		_check(_hidden_heard and _hidden_alert_time > 2.5, "occluded Wako heard the warning and kept the threat %.2fs (needs > 2.5 s)" % _hidden_alert_time)
		var posts := 0
		for entry: Dictionary in wakos[0].personality.attention._ring: if entry.kind == &"warning": posts += 1
		_check(posts > 0, "warning posted to the shared attention board (%d)" % posts)
		_check(_finite and _closed[0] and _closed[1], "paused helpers complete natural blinks with finite uploaded openness")
		_check(_async_blink, "one helper blinks while the other stays open (shared material, per-instance uniforms)")
		_check(_paused[0]._skin_mesh.get_active_material(0) == _paused[1]._skin_mesh.get_active_material(0), "helper skins share one material")
		print("FACE_CHECK %s %d failures" % ["PASS" if _failures == 0 else "FAIL", _failures])
		get_tree().quit(0 if _failures == 0 else 1)

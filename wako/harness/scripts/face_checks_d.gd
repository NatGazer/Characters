extends "res://harness/scripts/stage.gd"
## Headless regression checks for the face round-4 fixes:
## 1. onsets: the slow channels (smile, lids, tilt) ease in (critically
##    damped), never snap in one upload, at the near and the far stride;
## 2. a full-range glance darts (~.14 s) inside the .004 UV/tick bound, and a
##    small saccade keeps its short minimum-jerk flight;
## 3. the uploaded squeeze never shows the seam->crease band;
## 4. a silent greeting only parts the lips;
## 5. mouth sync on an idle, on-screen face: every voice kind (hup, grunt,
##    yay, hmm, hello) opens the jaw with its syllables, from the first one;
## 6. see -> take -> shout: a noticed hostile widens the uploaded eyes within
##    a few frames, and the warning call starts after that widen peaked;
## 7. a Wako that only HEARS the warning keeps the threat in attention and
##    alert, but gets no fear/retreat until it sees the enemy itself.
const Props := preload("res://harness/scripts/face_props.gd")
const Voice := preload("res://LogicObjects/Wako/wako_personality_voice.gd")
const KINDS := ["hup", "grunt", "yay", "hmm", "hello"]
var service: Node
var seer: RigidBody3D
var hearer: RigidBody3D
var hostile: Node3D
var _failures := 0
var _flags := {}
var _voice := {}
var _voice_at := {}
var _notice_at := -1.0
var _pop_at := -1.0
var _pop_samples := []
var _shout_at := -1.0
var _hostile_at := -1.0
var _heard_at := -1.0
var _late_fear := 0.0
var _late_alert := 0.0

func setup() -> void:
	service = Props.make_coordinator(self, true)
	seer = WAKO.instantiate()
	seer.worker_id = "checkd_seer"
	seer.position = Vector3(0, .86, 0)
	seer.configure(service)
	add_child(seer)
	hearer = WAKO.instantiate()
	hearer.worker_id = "checkd_hearer"
	hearer.position = Vector3(5.0, .86, 1.0)
	hearer.configure(service)
	add_child(hearer)
	# A block hides the hostile (at 0,0,-8) from the hearer only.
	add_box(Vector3(3.0, 1.1, -3.0), Vector3(2.5, 2.2, 2.5), Color(.4, .35, .3))
	cam_target = Vector3(0, 1.05, 0)
	cam_offset = Vector3(0, .3, -2.4)

func _check(ok: bool, label: String) -> void:
	print("FACE_CHECK_D %s %s" % ["ok" if ok else "FAIL", label])
	if not ok: _failures += 1

func _once(key: String) -> bool:
	if _flags.has(key): return false
	_flags[key] = true
	return true

func _unit_checks() -> void:
	var e: RefCounted = seer.eyes
	var saved_value: Array = e._value.duplicate()
	var saved_target: Array = e._target.duplicate()
	var saved_vel: Array = e._vel.duplicate()
	# 1. Spring onsets.
	var results := []
	for stride in [1.0 / 60.0, 1.0 / 15.0]:
		e._value[e.SMILE] = 0.0
		e._target[e.SMILE] = .63
		e._vel[e.SMILE] = 0.0
		e._settle(stride)
		var first: float = e._value[e.SMILE]
		var steps := 1
		while e._value[e.SMILE] < .8 * .63 and steps < 60:
			e._settle(stride)
			steps += 1
		var overshoot := 0.0
		for i in 30:
			e._settle(stride)
			overshoot = maxf(overshoot, float(e._value[e.SMILE]) - .63)
		results.append([first, steps * stride, overshoot])
	_check(results[0][0] < .12 and results[0][1] > .1 and results[0][1] < .2 and results[0][2] < .002,
		"a smile onset eases in at 60 Hz (first upload %.2f of .63, 80%% at %.0f ms, overshoot %.3f)" % [results[0][0], 1000.0 * results[0][1], results[0][2]])
	_check(results[1][0] < .63 * .5 and results[1][2] < .002,
		"and at the far 15 Hz stride (first upload %.2f of .63, overshoot %.3f)" % [results[1][0], results[1][2]])
	# A widening upper lid still opens like a reflex.
	e._value[e.UC] = .06
	e._target[e.UC] = -.3
	e._vel[e.UC] = 0.0
	e._settle(1.0 / 60.0)
	e._settle(1.0 / 60.0)
	_check(e._value[e.UC] < -.15, "a surprise widen still opens fast (upper lid %.2f after 2 uploads, target -.30)" % e._value[e.UC])
	e._value = saved_value
	e._target = saved_target.duplicate()
	e._vel = saved_vel
	# 2. Saccade flights.
	var saved_gaze: Vector2 = e.gaze
	for case in [[Vector2(-.02, .02), Vector2(.02, -.02), .16, "full-range glance"], [Vector2(.004, .002), Vector2(.008, -.002), .05, "small saccade"]]:
		e.gaze = case[0]
		e._start_saccade(case[1])
		var ticks := 0
		var step_max := 0.0
		while e._sacc_t >= 0.0 and ticks < 120:
			var before: Vector2 = e.gaze
			e._fly(1.0 / 120.0, case[1])
			step_max = maxf(step_max, e.gaze.distance_to(before))
			ticks += 1
		var landed: float = e.gaze.distance_to(case[1])
		_check(ticks / 120.0 <= case[2] and step_max < .004 and landed < .0005,
			"a %s (%.3f UV) flies in %.0f ms (<= %.0f), max step %.4f UV/tick (< .004)" % [case[3], Vector2(case[0]).distance_to(case[1]), 1000.0 * ticks / 120.0, 1000.0 * case[2], step_max])
	e.gaze = saved_gaze
	e._blink_pending = false
	# 3. Uploaded squeeze sweep.
	var mesh: MeshInstance3D = seer._skin_mesh
	var shown := []
	var banded := 0
	for v in [0.0, .2, .4, .47, .55, .63, .7, .85, .95, .8, .66, .58, .5, .45, .3, .1, 0.0, .5, .5, .5]:
		e._value[e.SQUEEZE] = v
		e._upload_channels(mesh)
		var iris: Vector4 = mesh.get_instance_shader_parameter(&"eye_iris")
		shown.append("%.2f" % iris.w)
		if iris.w > .445 and iris.w < .675: banded += 1
	_check(banded == 0, "the uploaded squeeze skips the seam->crease band (%d in band): %s" % [banded, " ".join(shown)])
	e._value = saved_value
	e._channels_dirty = true
	e._dirty = true
	# 4. A silent greeting.
	var p: RefCounted = seer.personality
	var saved := [p.smile_weight, p.greeting_weight, p.greeting_age]
	p.smile_weight = 1.0
	p.greeting_weight = 1.0
	p.greeting_age = .25
	e._compose()
	_check(p.voice_clock < 0.0 and e._target[e.MOPEN] <= .08, "a silent greeting only parts the lips (mouth open %.2f <= .08)" % e._target[e.MOPEN])
	p.smile_weight = saved[0]
	p.greeting_weight = saved[1]
	p.greeting_age = saved[2]
	e._target = saved_target
	e._compose()

func _voice_case(kind: String, at: float) -> void:
	var p: RefCounted = seer.personality
	if clock > at and _once("say_" + kind):
		p._chatter_remaining = 0.0
		p._work_call_history.clear()
		if p.say(kind, -22.0, 1.0, true): _voice_at[kind] = clock
		else: print("FACE_CHECK_D note: say(%s) declined" % kind)
	if not _voice_at.has(kind) or p.voice_clock < 0.0 or p.voice_kind != kind: return
	var mouth: Vector4 = seer._skin_mesh.get_instance_shader_parameter(&"mouth_shape")
	var want: float = Voice.mouth_open(p.voice_notes, p.voice_clock) * seer.eyes._voice_shape(kind).x
	var s: Array = _voice.get(kind, [0, 0, 0.0, 0.0, []])
	s[0] += 1
	# Uploads lag one stride (~17 ms) behind the clip; a tick is "late" when
	# the jaw shows less than half of the syllable it should be on.
	if want > .2 and mouth.x < .5 * want: s[1] += 1
	s[2] = maxf(s[2], mouth.x)
	s[3] = maxf(s[3], want)
	s[4].append(Vector3(clock - float(_voice_at[kind]), want, mouth.x))
	_voice[kind] = s

func scenario(_delta: float) -> void:
	if clock > 1.0 and _once("unit"): _unit_checks()
	for i in KINDS.size(): _voice_case(KINDS[i], 1.6 + 1.2 * i)
	if clock > 7.8 and _once("voice_check"):
		for kind in KINDS:
			if not _voice.has(kind):
				_check(false, "voice %s played" % kind)
				continue
			var s: Array = _voice[kind]
			# Latency: the first syllable's jaw reaching half the clip's peak.
			var t_want := -1.0
			var t_jaw := -1.0
			for sample: Vector3 in s[4]:
				if t_want < 0.0 and sample.y >= .5 * s[3]: t_want = sample.x
				if t_jaw < 0.0 and sample.z >= .5 * s[3]: t_jaw = sample.x
			_check(s[2] >= .6 * s[3] and s[1] <= maxi(2, s[0] / 5) and t_jaw >= 0.0 and t_jaw - t_want <= .035,
				"%s: jaw max %.2f of %.2f, %d/%d late ticks, reaches half open %.0f ms after its syllable" % [kind, s[2], s[3], s[1], s[0], 1000.0 * (t_jaw - t_want)])
	if clock > 8.0 and _once("hostile"):
		hostile = Props.make_hostile(self, Vector3(0, 0, -8.0))
		_hostile_at = clock
	if _hostile_at < 0.0: return
	var watch: SkeletonModifier3D = seer.threat_watch
	var iris: Vector4 = seer._skin_mesh.get_instance_shader_parameter(&"eye_iris")
	if _notice_at < 0.0 and float(watch.notice_widen) > 0.0: _notice_at = clock
	if _notice_at >= 0.0 and clock - _notice_at < .6:
		if _pop_at < 0.0 and iris.z >= .3: _pop_at = clock
		_pop_samples.append(Vector2(clock, iris.z))
	var p: RefCounted = seer.personality
	if _shout_at < 0.0 and p.voice_kind == "warning" and p.voice_clock >= 0.0: _shout_at = clock
	var h: RefCounted = hearer.personality
	if _heard_at < 0.0 and h.heard_age < 10.0: _heard_at = clock
	if _heard_at >= 0.0 and clock > _heard_at + 1.0 and clock < _heard_at + 3.0:
		_late_fear = maxf(_late_fear, hearer.fear_time)
		if is_instance_valid(h.live_threat) and h.alert_weight > .5: _late_alert += _delta
	if clock > _hostile_at + 4.5 and _once("final"):
		# The widen "peaks" when the uploaded pop first reaches 90% of its max.
		var pop_max := 0.0
		for sample: Vector2 in _pop_samples: pop_max = maxf(pop_max, sample.y)
		var pop_peak_at := -1.0
		for sample: Vector2 in _pop_samples:
			if sample.y >= .9 * pop_max:
				pop_peak_at = sample.x
				break
		_check(_notice_at >= 0.0 and _pop_at >= 0.0 and _pop_at - _notice_at <= .07,
			"the notice widen reaches the shader %.0f ms after it starts (<= 70)" % (1000.0 * (_pop_at - _notice_at)))
		_check(_shout_at >= 0.0 and _shout_at >= pop_peak_at - .02 and _shout_at - _notice_at >= .1 and _shout_at - _notice_at <= .35,
			"see -> take -> shout: widen at 90%% of its peak (%.2f) at +%.0f ms, warning call at +%.0f ms" % [pop_max, 1000.0 * (pop_peak_at - _notice_at), 1000.0 * (_shout_at - _notice_at)])
		var hidden_sees: bool = h._can_see(hostile._core.global_position, hostile._core)
		_check(not hidden_sees and _heard_at >= 0.0, "the hearer has no line of sight and heard the call")
		_check(_late_alert > 1.5 and _late_fear <= 0.0,
			"heard-only threat: alert/attention kept %.2f s, no fear after the first scan window (max fear %.2f)" % [_late_alert, _late_fear])
		print("FACE_CHECK_D %s %d failures" % ["PASS" if _failures == 0 else "FAIL", _failures])
		get_tree().quit(0 if _failures == 0 else 1)

extends "res://harness/scripts/stage.gd"
## Headless regression checks for the face round-3 fixes:
## 1. squeeze never dwells in the seam->crease band: stroke squeezes and
##    squeeze pulses peak outside it, and the channel crosses it in one upload;
## 2. a directed stumble (recoil event, no fear jump) wakes the face on the
##    same tick, with one startle blink and no flutter afterwards;
## 3. a board event whose actor was freed is never attended (a live one is);
## 4. a real notice: no blink during the widen/focus beat;
## 5. watching a hostile behind it, the cube turns only into a 3/4 stance
##    (the eyes cover the last ~45 deg) instead of turning its back to the yard.
const Props := preload("res://harness/scripts/face_props.gd")
const Attention := preload("res://LogicObjects/Wako/wako_attention.gd")
var service: Node
var wakos: Array[RigidBody3D] = []
var hostile: Node3D
var _failures := 0
var _flags := {}
var _hit_tick := -1
var _hit_seen_tick := -1
var _hit_blinks_before := 0
var _dead_seen := 0
var _live_seen := 0
var _live_node: Node3D
var _notice_start := {}
var _notice_blinks := 0
var _notice_windows := 0
var _blink_prev := {}
var _gap_after := 10.0
var _notice_end := {}

func setup() -> void:
	service = Props.make_coordinator(self, true)
	for i in 4:
		var w: RigidBody3D = WAKO.instantiate()
		w.worker_id = "checkc_%d" % i
		w.position = Vector3((i - 1.5) * 1.4, .86, 0)
		w.configure(service)
		add_child(w)
		wakos.append(w)
	cam_target = Vector3(0, 1, 0)

func _check(ok: bool, label: String) -> void:
	print("FACE_CHECK_C %s %s" % ["ok" if ok else "FAIL", label])
	if not ok: _failures += 1

func _once(key: String) -> bool:
	if _flags.has(key): return false
	_flags[key] = true
	return true

func scenario(_delta: float) -> void:
	# 1. Squeeze band.
	if clock > 1.0 and _once("squeeze"):
		var e: RefCounted = wakos[3].eyes
		var in_band := 0
		for i in 400:
			e._roll_stroke()
			if e._stroke_squeeze > .34 and e._stroke_squeeze < .76: in_band += 1
		_check(in_band == 0, "stroke squeezes avoid the seam->crease band (%d/400 in .34-.76)" % in_band)
		var saved: float = e._expressive
		var bad := 0
		for k in 13:
			e._expressive = .85 + .025 * k
			for a in 15:
				var amount := .3 + .05 * a
				var peak: float = .9 * e._squeeze_amount(amount) * e._expressive
				if peak > .4 and peak < .74: bad += 1
		e._expressive = saved
		_check(bad == 0, "squeeze pulse peaks avoid the band (%d/195 in .4-.74)" % bad)
		var value: Array = e._value.duplicate()
		var target: Array = e._target.duplicate()
		var steps := 0
		e._value[e.SQUEEZE] = 0.0
		e._target[e.SQUEEZE] = .9
		for i in 30:
			e._settle(1.0 / 60.0)
			var v: float = e._value[e.SQUEEZE]
			if v > .46 and v < .66: steps += 1
		e._value = value
		e._target = target
		e._dirty = true
		_check(steps <= 1, "the squeeze channel crosses .46-.66 in %d upload(s) at 60 Hz" % steps)
	# 2. A directed stumble without a fear jump.
	if clock > 1.5 and _once("recoil"):
		var w := wakos[1]
		_hit_blinks_before = int(w.eyes.events.blink)
		var reacted: bool = w.recoil.react(Vector3(-3.0 * w.mass, 0, 0), w.global_position + Vector3(1.0, .3, 0))
		_hit_tick = Engine.get_physics_frames() if reacted else -2
	if _hit_tick >= 0 and _hit_seen_tick < 0 and int(wakos[1].eyes.events.hit) > 0:
		_hit_seen_tick = Engine.get_physics_frames()
	if clock > 2.4 and _once("recoil_check"):
		if _hit_tick == -2:
			print("FACE_CHECK_C skip stumble checks: recoil.react declined (not grounded)")
		else:
			var latency := _hit_seen_tick - _hit_tick
			_check(_hit_seen_tick >= 0 and latency <= 2, "a directed stumble reaches the face in %d tick(s)" % latency)
			var blinks := int(wakos[1].eyes.events.blink) - _hit_blinks_before
			_check(blinks <= 1, "one startle blink, no flutter after a bump (%d blinks in 0.9 s)" % blinks)
	# 3. Freed vs live event actors.
	if clock > 3.0 and _once("dead_post"):
		for w in wakos: w.personality.attention._hold = -10.0
		var dead := Node3D.new()
		add_child(dead)
		dead.global_position = wakos[0].global_position + Vector3(0, .4, -2.0)
		Attention.post(wakos[0], &"probe_dead", dead.global_position, 1.0, 4.0, dead)
		dead.free()
	if clock > 3.0 and clock < 4.6:
		for w in wakos:
			if w.personality.attention.kind == &"probe_dead": _dead_seen += 1
	if clock > 4.7 and _once("live_post"):
		for w in wakos: w.personality.attention._hold = -10.0
		_live_node = Node3D.new()
		add_child(_live_node)
		_live_node.global_position = wakos[0].global_position + Vector3(.5, .4, -2.0)
		Attention.post(wakos[0], &"probe_live", _live_node.global_position, 1.0, 4.0, _live_node)
	if clock > 4.7 and clock < 6.3:
		for w in wakos:
			if w.personality.attention.kind == &"probe_live": _live_seen += 1
	if clock > 6.3 and _once("probe_check"):
		_check(_dead_seen == 0, "an event whose actor was freed is never attended (%d samples)" % _dead_seen)
		_check(_live_seen > 0, "the same event with a live actor is attended (%d samples)" % _live_seen)
	# 4/5. A hostile appears behind the row, beyond the flee radius.
	if clock > 6.5 and _once("hostile"):
		hostile = Props.make_hostile(self, Vector3(0, 0, 13.0))
	if clock > 6.5 and clock < 12.0:
		for w in wakos:
			var watch: SkeletonModifier3D = w.threat_watch
			var beat: bool = is_instance_valid(watch) and (float(watch.notice_widen) > .15 or float(watch.notice_focus) > .05)
			var blinks := int(w.eyes.events.blink)
			var started: bool = blinks > int(_blink_prev.get(w, blinks))
			_blink_prev[w] = blinks
			if beat:
				if not _notice_start.has(w):
					_notice_start[w] = clock
					_notice_windows += 1
				if started: _notice_blinks += 1
				_notice_end[w] = clock
			elif started and _notice_end.has(w) and clock - float(_notice_end[w]) < 1.0:
				_gap_after = minf(_gap_after, clock - float(_notice_end[w]))
	if clock > 12.0 and _once("final"):
		_check(_notice_windows > 0 and _notice_blinks == 0, "no blink during the notice widen/focus beat (%d blinks over %d notices)" % [_notice_blinks, _notice_windows])
		_check(_gap_after >= .2, "the first blink after the beat waits a personal beat (min gap %.2fs)" % _gap_after)
		var three_quarter := 0
		var offsets := []
		for w in wakos:
			var to: Vector3 = (hostile._core.global_position - w.global_position).slide(Vector3.UP)
			var off := absf(wrapf(atan2(-to.x, -to.z) - w._heading, -PI, PI))
			offsets.append("%.0f" % rad_to_deg(off))
			if off > .45 and off < 1.15: three_quarter += 1
		_check(three_quarter >= 3, "watching a hostile behind, the cube turns into a 3/4 stance (offsets %s deg)" % str(offsets))
		print("FACE_CHECK_C %s %d failures" % ["PASS" if _failures == 0 else "FAIL", _failures])
		get_tree().quit(0 if _failures == 0 else 1)

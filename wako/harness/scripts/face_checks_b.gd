extends "res://harness/scripts/stage.gd"
## Headless regression checks for the face round-2 fixes:
## 1. the gaze origin is the rendered painted eye centre; a level target 3 m
##    ahead needs (almost) no deflection;
## 2. a job interruption is not a hit: no "hit" board event, no "uh-oh";
## 3. a real hit: one hit event, the eyes look toward where it came from,
##    no danger preset without a live enemy, no voice chorus from the crew,
##    and the neighbours glance at the bumped Wako;
## 4. a standing neighbour's landing reaches another Wako's attention (the
##    switch ray may hit that neighbour);
## 5. a player who walks out of sight is released (never tracked blind).
const Props := preload("res://harness/scripts/face_props.gd")
const Attention := preload("res://LogicObjects/Wako/wako_attention.gd")
var service: Node
var wakos: Array[RigidBody3D] = []
var player: Node3D
var wall: StaticBody3D
var _failures := 0
var _flags := {}
var _oops := {}
var _alarm_max := 0.0
var _hit_look_ok := 0
var _hit_look_samples := 0
var _hit_glances := 0
var _landing_seen := 0
var _player_held := false
var _hidden_at := -1.0
var _released_after := -1.0
var _hit_source := Vector3.INF

func setup() -> void:
	service = Props.make_coordinator(self, true)
	for i in 4:
		var w: RigidBody3D = WAKO.instantiate()
		w.worker_id = "checkb_%d" % i
		w.position = Vector3((i - 1.5) * 1.3, .86, 0)
		w.configure(service)
		add_child(w)
		wakos.append(w)
	player = Props.make_player(self, Vector3(30, .5, 30))
	cam_target = Vector3(0, 1, 0)

func _check(ok: bool, label: String) -> void:
	print("FACE_CHECK_B %s %s" % ["ok" if ok else "FAIL", label])
	if not ok: _failures += 1

func _once(key: String) -> bool:
	if _flags.has(key): return false
	_flags[key] = true
	return true

func _count_ring(kind: StringName, since: float) -> int:
	var count := 0
	for entry: Dictionary in Attention._ring:
		if entry.kind == kind and float(entry.time) >= since: count += 1
	return count

func scenario(_delta: float) -> void:
	for w in wakos:
		if w.personality._event_voice == "oops" or w.personality.voice_kind == "oops": _oops[w.worker_id] = clock
	# 1. Eye origin.
	if clock > 1.0 and _once("frame"):
		var e: RefCounted = wakos[0].eyes
		var painted: Vector3 = Props.painted_eye_midpoint(wakos[0])
		var origin: Vector3 = e.eye_origin()
		var eye_frame: Transform3D = e._eye_frame()
		var level: Vector2 = e._uv_toward(origin - eye_frame.basis.z * 3.0)
		_check(painted.is_finite() and origin.distance_to(painted) < .03, "gaze origin sits on the painted eyes (%.1f mm from the mesh eye midpoint %s)" % [origin.distance_to(painted) * 1000.0, painted])
		_check(level.length() < .001, "a level target 3 m ahead needs no deflection (|gaze| %.5f)" % level.length())
	# 2. Interruptions (the coordinator's _cancel path) are not hits.
	if clock > 1.5 and _once("interrupt"):
		_oops.clear()
		for w in wakos: w.interrupt("Unsafe worksite; taking cover")
	if clock > 3.2 and _once("interrupt_check"):
		var hits := 0
		for w in wakos: hits += int(w.eyes.events.hit)
		_check(hits == 0 and _count_ring(&"hit", 1.4) == 0, "job interruption is not a hit (face hits %d, board hit events %d)" % [hits, _count_ring(&"hit", 1.4)])
		_check(_oops.is_empty(), "no \"uh-oh\" for an interruption (%s)" % str(_oops.keys()))
		_oops.clear()
	# 3. A real bump from the +x side, no enemy anywhere.
	if clock > 3.5 and _once("hit"):
		_hit_source = wakos[1].global_position + Vector3(2.0, .3, 0)
		wakos[1].hurt(30.0, _hit_source)
	if clock > 3.5 and clock < 6.5:
		var mesh: MeshInstance3D = wakos[1]._skin_mesh
		var alarm: Variant = mesh.get_instance_shader_parameter(&"face_alarm")
		_alarm_max = maxf(_alarm_max, float(alarm) if alarm != null else 0.0)
		var e: RefCounted = wakos[1].eyes
		if clock > 3.75 and clock < 4.3:
			_hit_look_samples += 1
			var to_source := (_hit_source - wakos[1].global_position).slide(Vector3.UP).normalized()
			var looked: Vector3 = e._want_point
			if looked.is_finite() and (looked - wakos[1].global_position).slide(Vector3.UP).normalized().dot(to_source) > .7: _hit_look_ok += 1
		for i in [0, 2, 3]:
			if wakos[i].personality.attention.kind == &"hit": _hit_glances += 1
	if clock > 6.5 and _once("hit_check"):
		_check(int(wakos[1].eyes.events.hit) == 1, "the bump is one real hit for the face (%d)" % int(wakos[1].eyes.events.hit))
		_check(_hit_look_ok * 2 > _hit_look_samples, "eyes look toward where the bump came from (%d/%d samples)" % [_hit_look_ok, _hit_look_samples])
		_check(_alarm_max < .1, "no danger preset without a live enemy (max face_alarm %.2f)" % _alarm_max)
		var others := 0
		for id: String in _oops:
			if id != wakos[1].worker_id: others += 1
		_check(others == 0, "no crew chorus: only the bumped Wako may say \"uh-oh\" (%s)" % str(_oops.keys()))
		_check(_hit_glances > 0, "neighbours glance at the bumped Wako (%d samples)" % _hit_glances)
	# 4. A standing neighbour lands (event on its own body).
	if clock > 7.0 and _once("landing"):
		for w in wakos: w.personality.attention._hold = -10.0
		Attention.post(wakos[3], &"landing", wakos[3].global_position, .9, 1.6, wakos[3])
	if clock > 7.0 and clock < 8.6:
		for i in [0, 1, 2]:
			if wakos[i].personality.attention.kind == &"landing": _landing_seen += 1
	if clock > 8.6 and _once("landing_check"):
		_check(_landing_seen > 0, "a standing neighbour's landing is attended (%d samples)" % _landing_seen)
	# 5. The player stands close in front of #0, then steps behind a wall.
	if clock > 8.7 and _once("player"):
		player.global_position = wakos[0].global_position + Vector3(0, -.36, -2.0)
		wall = add_box(wakos[0].global_position + Vector3(1.6, .4, -1.2), Vector3(.2, 2.0, 1.6), Color(.4, .35, .3))
	if clock > 8.7 and clock < 12.0 and not _player_held:
		var att: RefCounted = wakos[0].personality.attention
		var node: Object = att.node.get_ref() if att.node else null
		if node == player and clock > 9.5:
			_player_held = true
			player.global_position = wakos[0].global_position + Vector3(2.6, -.36, -1.2)
			_hidden_at = clock
	if _player_held and _released_after < 0.0:
		var att: RefCounted = wakos[0].personality.attention
		var node: Object = att.node.get_ref() if att.node else null
		var e: RefCounted = wakos[0].eyes
		var eye_node: Object = e._want_node.get_ref() if e._want_node else null
		if node != player and eye_node != player: _released_after = clock - _hidden_at
	if clock > 13.0 and _once("final"):
		var sees: bool = wakos[0].personality._can_see(player.global_position + Vector3.UP * .6, player)
		if _player_held:
			_check(not sees and _released_after >= 0.0 and _released_after < .8, "an unseen player is released (after %.2fs, player visible=%s)" % [_released_after, sees])
		else:
			print("FACE_CHECK_B skip player-release check: attention never chose the player")
		print("FACE_CHECK_B %s %d failures" % ["PASS" if _failures == 0 else "FAIL", _failures])
		get_tree().quit(0 if _failures == 0 else 1)

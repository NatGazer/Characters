class_name SwimAudio extends Node3D
## Sounds of a swimmer (used by Components/Water/player_swim.gd, reusable for any swimmer):
##  * strokes: a stroke cycle whose rate follows the swim speed (faster when sprinting); each arm entry picks one of the
##    stroke grains (shuffle bag, never the same twice in a row) with pitch / level jitter, alternating left / right
##    hand, plus drips from the arm recovery and, when sprinting, extra splash
##  * treading water: occasional soft sculling gurgles
##  * water lapping around the head: a FlowingWaterSound (HEAD_LAP) whose laps / wash follow how fast the water moves
##    against the head (wave height change relative to the eyes, plus the swimmer's own speed through the water)
##  * under water: exhaled bubble bursts made of many bubble grains
## Call update() every physics tick while the swimmer is in or near water, stop() when leaving it.

@export var stroke_volume_db := -17.0
@export var lap_volume_db := -3.5
@export var bubbles_volume_db := -12.0
@export var bus: StringName = &"Master"

var _rng := RandomNumberGenerator.new()
var _hands: Array[WaterAudioBank.Emitter] = []
var _head: WaterAudioBank.Emitter
var _lap: FlowingWaterSound
var _bags := {}
var _phase := 0.0
var _period := 1.0
var _side := 0
var _was_stroking := false
var _pending: Array[Array] = [] # [time, cat, db, pitch, emitter]
var _clock := 0.0
var _prev_rel := INF
var _motion := 0.0
var _scull_t := 1.5
var _bubble_t := 2.0
var _swimming := false
var _idle := 0.0
## Main-thread cost of the last update(), microseconds.
var last_cost_usec := 0

func _ready() -> void:
	_rng.randomize()
	for i in 2:
		_hands.append(WaterAudioBank.Emitter.new(self, 8, 1.5, 30.0, bus, "Hand%d" % i))
	_head = WaterAudioBank.Emitter.new(self, 16, 1.5, 30.0, bus, "Head")
	for c: StringName in [&"stroke", &"splash", &"plop", &"bubble", &"gurgle", &"lap"]:
		_bags[c] = WaterAudioBank.Bag.new(WaterAudioBank.grains(c).size())
	_lap = FlowingWaterSound.new()
	_lap.name = "HeadLap"
	_lap.kind = FlowingWaterSound.Kind.HEAD_LAP
	_lap.unit_size = 1.2
	_lap.max_distance = 30.0
	_lap.spread = 0.9
	_lap.grain_emitters = 2
	_lap.volume_db = lap_volume_db
	_lap.bus = bus
	_lap.gain = 0.0
	add_child(_lap, false, Node.INTERNAL_MODE_BACK)

## swimming: in the water and swimming; stroking: the swimmer is pushing (movement input); speed: speed through the
## water (m/s); surface: water surface point above/below the head; head: eye position; forward: horizontal facing.
func update(delta: float, swimming: bool, stroking: bool, speed: float, sprint: bool, head_under: bool,
		surface: Vector3, head: Vector3, forward: Vector3) -> void:
	var t0 := Time.get_ticks_usec()
	_clock += delta
	_swimming = swimming
	var fwd := Vector3(forward.x, 0.0, forward.z)
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var right := fwd.cross(Vector3.UP)
	# Water moving against the head: how fast the surface moves relative to the eyes, plus the swimmer's own wash.
	var rel := surface.y - head.y
	if _prev_rel != INF and delta > 0.0:
		var rate := absf(rel - _prev_rel) / delta
		_motion = lerpf(_motion, minf(rate, 3.0) + 0.1 * speed, 1.0 - exp(-delta * 2.5))
	_prev_rel = rel
	var at_surface := swimming and not head_under and rel > -0.9
	_lap.gain = 1.0 if at_surface else 0.0
	_lap.update_listener_point(Vector3(head.x, surface.y, head.z), speed, clampf(_motion / 0.6, 0.0, 1.0))
	# Strokes at the surface.
	var stroke_now := at_surface and stroking
	if stroke_now:
		var sp := clampf((speed - 0.3) / 3.0, 0.0, 1.0)
		if not _was_stroking:
			_phase = 0.85
			_period = 1.0
		_phase += delta / _period
		if _phase >= 1.0:
			_phase -= 1.0
			_period = lerpf(1.05, 0.62, sp) * (0.82 if sprint else 1.0) * _rng.randf_range(0.88, 1.12)
			_stroke(sp, sprint, surface, head, fwd, right)
	_was_stroking = stroke_now
	# Treading water: soft sculling now and then.
	if at_surface and not stroking:
		_scull_t -= delta
		if _scull_t <= 0.0:
			_scull_t = _rng.randf_range(1.2, 2.8)
			_side = 1 - _side
			_hands[_side].player.global_position = Vector3(head.x, surface.y - 0.25, head.z) + right * (0.4 if _side else -0.4)
			_play(_hands[_side], &"gurgle" if _rng.randf() < 0.6 else &"lap", stroke_volume_db - 13.0 + _rng.randf_range(-3, 3),
				_rng.randf_range(0.95, 1.3))
	# Exhaled bubbles under water.
	if swimming and head_under:
		_bubble_t -= delta
		if _bubble_t <= 0.0:
			_bubble_t = _rng.randf_range(3.5, 6.5)
			var n := _rng.randi_range(6, 16)
			var dur := _rng.randf_range(0.4, 1.1)
			for i in n:
				_pending.append([_clock + dur * pow(_rng.randf(), 1.5), &"bubble",
					bubbles_volume_db + _rng.randf_range(-8.0, 0.0), _rng.randf_range(0.55, 1.05), _head])
		_head.player.global_position = head + Vector3.UP * 0.25
	else:
		_bubble_t = minf(_bubble_t, 1.5)
	for k in range(_pending.size() - 1, -1, -1):
		var e: Array = _pending[k]
		if _clock >= e[0]:
			_pending.remove_at(k)
			_play(e[4], e[1], e[2], e[3])
	last_cost_usec = Time.get_ticks_usec() - t0

func _stroke(sp: float, sprint: bool, surface: Vector3, head: Vector3, fwd: Vector3, right: Vector3) -> void:
	_side = 1 - _side
	var em := _hands[_side]
	var hand := Vector3(head.x, surface.y, head.z) + fwd * 0.5 + right * (0.35 if _side else -0.35)
	WaterInteraction.splash(hand,lerpf(0.15,0.4,sp)*(1.3 if sprint else 1.0),0.25)
	em.player.global_position = hand
	var db := stroke_volume_db + lerpf(-3.0, 2.0, sp) + _rng.randf_range(-2.5, 2.0)
	_play(em, &"stroke", db, _rng.randf_range(0.9, 1.12) + (0.05 if sprint else 0.0))
	if sprint and _rng.randf() < 0.45 or _rng.randf() < 0.12:
		_play(em, &"splash", db - _rng.randf_range(6.0, 11.0), _rng.randf_range(0.9, 1.25))
	for i in _rng.randi_range(0, 2):
		_pending.append([_clock + _rng.randf_range(0.35, 0.75), &"plop", db - _rng.randf_range(10.0, 16.0),
			_rng.randf_range(0.9, 1.3), em])

func _play(em: WaterAudioBank.Emitter, cat: StringName, db: float, pitch: float) -> void:
	var list := WaterAudioBank.grains(cat)
	if list.is_empty():
		return
	em.play(list[(_bags[cat] as WaterAudioBank.Bag).pick(_rng)], db, pitch)

## Out of the water: fade the lapping; the players stop once their last grains have rung out.
func stop() -> void:
	_lap.gain = 0.0
	_pending.clear()
	_was_stroking = false
	_prev_rel = INF
	_swimming = false

func _process(delta: float) -> void:
	_idle = 0.0 if _swimming else _idle + delta
	if _idle > 2.0 and (_head.player.playing or _hands[0].player.playing or _hands[1].player.playing):
		for em in _hands:
			em.stop()
		_head.stop()

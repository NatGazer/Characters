class_name FlowingWaterSound extends Node3D
## Non-repeating, layered sound of one water feature (river, rapids, waterfall, lake shore, surf, open sea, water lapping
## around a swimmer's head). Nothing is a loop you can recognise:
##  * a broadband bed made of three seamless noise textures (low rumble, mid wash, high fizz). Each layer is always two
##    voices cross-faded (equal power) from random offsets, with random durations, a random base pitch and a slow pitch
##    drift, and the layer gains wander on their own, so the bed's spectral shape keeps moving and never repeats.
##  * a granular layer: bubbles, plops, gurgles, trickles, splashes, spatter and laps (hundreds of distinct grains made
##    by .claude/scripts/gen_water_audio.py), scheduled as Poisson processes on a few emitters scattered around the
##    focus point, picked from shuffle bags with pitch / level jitter. Density, level, pitch and brightness follow
##    flow speed, turbulence, size, wind and distance.
##  * surf: breaking waves are events (a crash swell on the mid bed, a fizzing backwash on the high bed, a burst of
##    splash / spatter / trickle grains), spaced by the wave period with random sets. The open sea breathes with the swell.
##
## Use (a water body):
##   var s := FlowingWaterSound.new()
##   s.kind = FlowingWaterSound.Kind.RIVER
##   add_child(s)
##   # every frame or every few frames:
##   s.update_listener_point(nearest_water_point, flow_speed_mps, turbulence_0_1, downstream_dir)
## `active = false` fades it out and stops its players (do that when the camera is far away).
## CPU: the main thread only updates ~10 voice volumes per frame and schedules grains; the mixer plays PCM voices
## (4 AudioStreamPlayer3D per source, ~6-14 voices sounding at once).

enum Kind { RIVER, RAPIDS, WATERFALL, LAKE, SURF, SEA, HEAD_LAP }

const CATS: Array[StringName] = [&"bubble", &"plop", &"gurgle", &"trickle", &"splash", &"spatter", &"lap"]
## Level of each bed layer at gain 1 (dB), so recipes can use comparable 0..1 gains.
const BED_DB: Array[float] = [-3.0, -6.0, -12.0]

@export var kind := Kind.RIVER
## Mean flow speed at the focus point (m/s).
@export var flow_speed := 1.0
## 0 = smooth water, 1 = white water (steep rapids).
@export_range(0.0, 1.0) var turbulence := 0.0
## River width (m), waterfall drop height (m), surf / sea significant wave height (m).
@export var size := 1.0
## Waterfall width (m).
@export var width := 4.0
## Wind speed (m/s): lake laps and sea whitecaps.
@export var wind := 4.0
## Surf / swell period (s).
@export var wave_period := 7.0
## Extra linear gain (smoothed), e.g. muffling under water.
@export var gain := 1.0
@export var volume_db := 0.0
@export var unit_size := 6.0
@export var max_distance := 80.0
## Grain emitters scatter this far (m) around the focus point.
@export var spread := 6.0
@export_range(1, 6) var grain_emitters := 3
@export var bus: StringName = &"Master"
@export var active := true
## 0 = random.
@export var random_seed := 0

## World point the sound is centred on (the nearest water point). INF = this node's own position.
var focus := Vector3.INF
## Horizontal downstream direction (grain emitters spread along it).
var flow_dir := Vector3.ZERO
## Main-thread cost of the last _process, microseconds (for the harness).
var last_cost_usec := 0

var _rng := RandomNumberGenerator.new()
var _bed_em: WaterAudioBank.Emitter
var _grain_em: Array[WaterAudioBank.Emitter] = []
var _em_off: Array[Vector3] = []
var _em_t := PackedFloat32Array()
var _layers: Array[Layer] = []
var _events: Array[Voice] = [] # surf wave voices (not tied to a layer)
var _pending: Array[Array] = [] # [time, category index, db, pitch, emitter index]
var _next := PackedFloat32Array() # per category: remaining unit-rate exponential time to the next grain
var _bags: Array[WaterAudioBank.Bag] = []
var _rates := PackedFloat32Array() # per category: rate, dB low, dB high, pitch low, pitch high
var _master := 0.0
var _clock := 0.0
var _recipe_t := 0.0
var _sleeping := true
var _halted := false
var _surf_t := 2.0
var _set_left := 0
var _swell := 0.0
var _swell_period := 7.0
var _dist := 0.0
var _built := false
var _tick := 1.0
var _last_grain := -10.0
var _kind_db := 0.0
const TICK := 1.0 / 20.0

class Voice extends RefCounted:
	var id := -1
	var layer := 0
	var t := 0.0
	var a := 1.0
	var h := 1.0
	var r := 1.0
	var peak := 1.0
	var base := 1.0
	var drift := 0.0
	var drift_to := 0.0
	var drift_t := 0.0
	var next := false
	var pitch := -1.0
	var db := -200.0

	## Equal-power envelope: sin rise, hold, cos fall.
	func env() -> float:
		var x := t
		if x <= 0.0:
			return 0.0
		if x < a:
			return sin(PI * 0.5 * x / a)
		x -= a
		if x < h:
			return 1.0
		return cos(PI * 0.5 * clampf((x - h) / r, 0.0, 1.0))

	func finished() -> bool:
		return t >= a + h + r + 0.1

class Layer extends RefCounted:
	var gain := 0.0
	var target := 0.0
	var pitch := 1.0
	var wander := 1.0
	var wander_to := 1.0
	var wander_t := 0.0
	var voices: Array[Voice] = []

func _ready() -> void:
	if random_seed != 0:
		_rng.seed = random_seed
	else:
		_rng.randomize()
	_build()

func _build() -> void:
	if _built:
		return
	_built = true
	_bed_em = WaterAudioBank.Emitter.new(self, 8, unit_size, max_distance, bus, "Bed")
	for i in grain_emitters:
		_grain_em.append(WaterAudioBank.Emitter.new(self, 12, unit_size * 0.7, max_distance, bus, "Grains%d" % i))
		_em_off.append(Vector3.ZERO)
		_em_t.append(0.0)
	for l in 3:
		_layers.append(Layer.new())
	_rates.resize(CATS.size() * 5)
	_next.resize(CATS.size())
	for i in CATS.size():
		_next[i] = -log(maxf(_rng.randf(), 1e-6))
		_bags.append(WaterAudioBank.Bag.new(WaterAudioBank.grains(CATS[i]).size()))
	_swell_period = wave_period
	_tick = _rng.randf() * TICK # spread the sources' ticks over frames

## Call per frame (or every few frames) with the nearest water point; negative values keep the current parameters.
func update_listener_point(point: Vector3, speed := -1.0, turb := -1.0, dir := Vector3.ZERO) -> void:
	focus = point
	if speed >= 0.0:
		flow_speed = speed
	if turb >= 0.0:
		turbulence = clampf(turb, 0.0, 1.0)
	if dir != Vector3.ZERO:
		flow_dir = Vector3(dir.x, 0.0, dir.z).normalized()

func _focus() -> Vector3:
	return global_position if focus == Vector3.INF else focus

# --- recipes ------------------------------------------------------------------------------------------------

## Sets the layer targets / pitches and the grain rates from the parameters.
func _recipe() -> void:
	var L := _layers
	_rates.fill(0.0)
	_kind_db = 0.0
	match kind:
		Kind.RIVER, Kind.RAPIDS:
			var n := clampf(flow_speed / 3.0, 0.0, 1.5)
			var t := turbulence if kind == Kind.RIVER else maxf(turbulence, 0.75)
			var w := clampf(size / 8.0, 0.4, 1.6)
			_layer(0, (0.12 + 0.3 * t) * w, 0.95 + 0.1 * n)
			_layer(1, (0.35 + 0.3 * n + 0.45 * t) * w, 0.95 + 0.15 * n + 0.1 * t)
			_layer(2, (0.07 + 0.12 * n + 0.75 * t * t) * w, 0.95 + 0.1 * t)
			_kind_db = 3.4 - 4.3 * t
			var calm := 1.0 - 0.6 * t
			_rate(&"bubble", (5.0 + 9.0 * n) * calm, -18, -9, 0.75, 1.35)
			_rate(&"gurgle", (1.4 + 3.0 * n) * calm, -16, -8, 0.8, 1.25)
			_rate(&"plop", (0.5 + 0.8 * n) * calm, -20, -12, 0.85, 1.25)
			_rate(&"trickle", (0.35 + 0.6 * n) * calm, -18, -10, 0.85, 1.2)
			_rate(&"splash", 2.0 * t + 22.0 * t * t, -17, -9, 0.8, 1.2)
			_rate(&"spatter", 2.5 * t, -18, -10, 0.85, 1.2)
		Kind.WATERFALL:
			var h := maxf(size, 1.0)
			var p := clampf(1.18 - h * 0.012, 0.72, 1.12)
			var big := clampf(sqrt(h * maxf(width, 1.0)) / 12.0, 0.4, 1.6)
			_kind_db = -5.1
			_layer(0, 1.0 * big, p)
			_layer(1, 0.8 * big, p * 0.95)
			_layer(2, 0.4 * big, clampf(p * 1.05, 0.8, 1.1))
			_rate(&"splash", clampf(10.0 + h * 0.9, 10.0, 40.0), -12, -3, p * 0.8, p * 1.15)
			_rate(&"spatter", 2.0 + h * 0.08, -14, -6, 0.85, 1.15)
			_rate(&"gurgle", 3.0, -14, -6, p * 0.8, p * 1.1)
			_rate(&"bubble", 5.0, -18, -9, 0.8, 1.2)
		Kind.LAKE:
			var w := clampf(wind, 0.0, 15.0)
			_kind_db = -3.1
			_layer(0, 0.05 + 0.015 * w, 0.85)
			_layer(1, 0.03 + 0.02 * w, 0.85)
			_layer(2, 0.0, 1.0)
			_rate(&"lap", 0.35 + 0.16 * w, -9, -2, 0.85, 1.15)
			_rate(&"bubble", 0.25 + 0.05 * w, -22, -14, 0.9, 1.3)
			_rate(&"plop", 0.15, -22, -15, 0.9, 1.2)
			_rate(&"gurgle", 0.2 + 0.04 * w, -18, -10, 0.9, 1.2)
		Kind.SURF:
			var hs := clampf(size, 0.1, 4.0)
			_layer(0, 0.18 + 0.08 * hs, 0.8)
			_layer(1, 0.1 + 0.04 * hs, 0.85)
			_layer(2, 0.02, 0.9)
			_rate(&"lap", 0.4, -12, -4, 0.8, 1.1)
			_rate(&"trickle", 0.3, -18, -10, 0.85, 1.15)
		Kind.SEA:
			var hs := clampf(size, 0.0, 6.0)
			var caps := clampf((wind - 6.0) / 10.0, 0.0, 1.0)
			var sw := 0.7 + 0.3 * sin(_swell)
			_layer(0, (0.18 + 0.06 * hs) * sw, 0.75)
			_layer(1, (0.22 + 0.06 * hs + 0.2 * caps) * sw, 0.8 + 0.1 * caps)
			_layer(2, 0.01 + 0.15 * caps * sw, 0.9)
			_rate(&"lap", (0.35 + 0.35 * hs) * (0.6 + 0.8 * maxf(sin(_swell), 0.0)), -12, -3, 0.75, 1.1)
			_rate(&"gurgle", 0.3 + 0.2 * hs, -18, -10, 0.8, 1.1)
			_rate(&"bubble", 0.4, -24, -15, 0.85, 1.2)
			_rate(&"spatter", 1.5 * caps, -18, -9, 0.85, 1.15)
			_rate(&"splash", 1.2 * caps, -18, -9, 0.7, 1.0)
		Kind.HEAD_LAP:
			# turbulence = how much the water moves against the head (0..1)
			var m := clampf(turbulence, 0.0, 1.0)
			_layer(0, 0.05 + 0.25 * m, 0.8)
			_layer(1, 0.03 + 0.22 * m, 0.7 + 0.15 * m)
			_layer(2, 0.03 * m, 1.0)
			_rate(&"lap", 0.25 + 2.6 * m, -14, -3, 0.85 + 0.1 * m, 1.25)
			_rate(&"gurgle", 0.2 + 1.2 * m, -18, -9, 0.9, 1.3)
			_rate(&"bubble", 0.3 + 1.2 * m, -24, -14, 0.9, 1.4)
			_rate(&"plop", 0.1 + 0.6 * m, -24, -15, 0.9, 1.3)
	for i in 3:
		L[i].target *= L[i].wander

func _layer(i: int, g: float, pitch: float) -> void:
	_layers[i].target = maxf(g, 0.0)
	_layers[i].pitch = pitch

## Grain rate (events per second) and level / pitch ranges of a category.
func _rate(cat: StringName, r: float, db_lo: float, db_hi: float, p_lo: float, p_hi: float) -> void:
	var i := CATS.find(cat) * 5
	_rates[i] = maxf(r, 0.0)
	_rates[i + 1] = db_lo
	_rates[i + 2] = db_hi
	_rates[i + 3] = p_lo
	_rates[i + 4] = p_hi

# --- runtime ------------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not _built or _halted:
		return
	var t0 := Time.get_ticks_usec()
	_clock += delta
	var f := _focus()
	var cam := get_viewport().get_camera_3d()
	_dist = cam.global_position.distance_to(f) if cam else 0.0
	var want := active and gain > 0.0005 and _dist < max_distance + 15.0
	var target := gain if want else 0.0
	_master = move_toward(_master, target, delta * maxf(2.0 * absf(target - _master), 0.5))
	if not want and _master <= 0.0005 and _clock - _last_grain > 1.6:
		if not _sleeping:
			_sleep()
		last_cost_usec = Time.get_ticks_usec() - t0
		return
	if _sleeping:
		_sleeping = false
		_place_emitters(f, 1.0)
	if _bed_em.halted:
		_halted = true
		_events.clear()
		return
	# Envelopes, positions and recipes at 20 Hz (the mixer ramps volumes smoothly in between); grains every frame.
	_tick += delta
	if _tick >= TICK:
		var dt := minf(_tick, 0.25)
		_tick = 0.0
		_swell += dt * TAU / maxf(_swell_period, 1.0)
		if _swell > TAU:
			_swell -= TAU
			_swell_period = wave_period * _rng.randf_range(0.75, 1.3)
		_recipe_t -= dt
		if _recipe_t <= 0.0:
			_recipe_t = 0.1
			_wander(0.1)
			_recipe()
		_place_emitters(f, dt)
		_update_layers(dt)
		if kind == Kind.SURF:
			_update_surf(dt)
		_update_events(dt)
	_schedule_grains(delta)
	last_cost_usec = Time.get_ticks_usec() - t0

## Slow random gain wander of each layer (spectral shape keeps moving).
func _wander(dt: float) -> void:
	for l in _layers:
		l.wander_t -= dt
		if l.wander_t <= 0.0:
			l.wander_t = _rng.randf_range(1.0, 4.0)
			l.wander_to = _rng.randf_range(0.72, 1.28)
		l.wander = lerpf(l.wander, l.wander_to, 1.0 - exp(-dt * 0.8))

func _place_emitters(f: Vector3, delta: float) -> void:
	_bed_em.player.global_position = f if delta >= 1.0 else _bed_em.player.global_position.lerp(f, 1.0 - exp(-delta * 4.0))
	for i in _grain_em.size():
		_em_t[i] -= delta
		if _em_t[i] <= 0.0:
			_em_t[i] = _rng.randf_range(1.2, 3.5)
			var a := _rng.randf() * TAU
			var r := sqrt(_rng.randf()) * spread
			var o := Vector3(cos(a) * r, 0.0, sin(a) * r)
			if flow_dir != Vector3.ZERO:
				var side := Vector3(-flow_dir.z, 0.0, flow_dir.x)
				o = flow_dir * (o.x * 1.6) + side * (o.z * 0.6)
			_em_off[i] = o
		var p := f + _em_off[i]
		var em := _grain_em[i]
		em.player.global_position = p if delta >= 1.0 else em.player.global_position.lerp(p, 1.0 - exp(-delta * 3.0))

func _new_bed_voice(layer: int, attack: float) -> Voice:
	var s := WaterAudioBank.bed(layer)
	var v := Voice.new()
	v.layer = layer
	v.base = _rng.randf_range(0.96, 1.04)
	v.id = _bed_em.play(s, -80.0, _layers[layer].pitch * v.base, _rng.randf() * s.get_length())
	v.a = attack
	v.h = _rng.randf_range(2.0, 6.0)
	v.r = _rng.randf_range(1.2, 2.6)
	return v

func _set_db(v: Voice, db: float) -> void:
	if absf(db - v.db) > 0.05:
		v.db = db
		_bed_em.set_volume(v.id, db)

func _update_layers(delta: float) -> void:
	var off := volume_db + _kind_db
	for li in 3:
		var l := _layers[li]
		l.gain = move_toward(l.gain, l.target, delta * maxf(absf(l.target - l.gain) * 1.5, 0.05))
		var voices := l.voices
		if voices.is_empty() and l.gain > 0.002:
			voices.append(_new_bed_voice(li, 0.8))
		for k in range(voices.size() - 1, -1, -1):
			var v := voices[k]
			v.t += delta
			if v.id == AudioStreamPlaybackPolyphonic.INVALID_ID:
				voices.remove_at(k)
				continue
			if not v.next and v.t >= v.a + v.h:
				v.next = true
				if l.gain > 0.002:
					voices.append(_new_bed_voice(li, v.r))
			if v.finished():
				_bed_em.stop_voice(v.id)
				voices.remove_at(k)
				continue
			_set_db(v, linear_to_db(maxf(v.env() * l.gain * _master, 0.00001)) + BED_DB[li] + off)
			v.drift_t -= delta
			if v.drift_t <= 0.0:
				v.drift_t = _rng.randf_range(1.5, 4.0)
				v.drift_to = _rng.randf_range(-1.0, 1.0)
			v.drift = lerpf(v.drift, v.drift_to, 1.0 - exp(-delta * 0.7))
			var p: float = l.pitch * v.base * (1.0 + 0.025 * v.drift)
			if absf(p - v.pitch) > 0.001:
				v.pitch = p
				_bed_em.set_pitch(v.id, p)

func _update_surf(delta: float) -> void:
	_surf_t -= delta
	if _surf_t > 0.0:
		return
	var hs := clampf(size, 0.1, 4.0)
	# Sets: every so often 2-4 bigger waves come close together.
	var strength := _rng.randf_range(0.55, 1.0)
	if _set_left > 0:
		_set_left -= 1
		strength = _rng.randf_range(0.9, 1.25)
	elif _rng.randf() < 0.15:
		_set_left = _rng.randi_range(2, 3)
	_surf_t = wave_period * _rng.randf_range(0.6, 1.4) * (0.8 if _set_left > 0 else 1.0)
	var s := strength * clampf(0.45 + hs * 0.35, 0.3, 1.5)
	var crash_db := linear_to_db(s)
	var a := _rng.randf_range(0.35, 0.9)
	_events.append(_event_voice(1, _rng.randf_range(0.85, 1.05), 0.0, a, _rng.randf_range(0.2, 0.7),
		_rng.randf_range(1.6, 3.2), s * 0.9))
	_events.append(_event_voice(2, _rng.randf_range(0.85, 1.0), -a * 0.6, 0.5, _rng.randf_range(0.3, 0.8),
		_rng.randf_range(2.5, 4.5), s * 0.55))
	for i in _rng.randi_range(3, 8):
		_pending.append([_clock + a * 0.6 + _rng.randf_range(0.0, 0.9), CATS.find(&"splash"), crash_db + _rng.randf_range(-13.0, -4.0),
			_rng.randf_range(0.7, 1.0), _rng.randi_range(0, _grain_em.size() - 1)])
	for i in _rng.randi_range(1, 3):
		_pending.append([_clock + a + _rng.randf_range(0.5, 2.5), CATS.find(&"spatter"), crash_db + _rng.randf_range(-16.0, -8.0),
			_rng.randf_range(0.8, 1.1), _rng.randi_range(0, _grain_em.size() - 1)])
	for i in _rng.randi_range(2, 5):
		_pending.append([_clock + a + _rng.randf_range(1.0, 4.0), CATS.find(&"trickle"), crash_db + _rng.randf_range(-16.0, -8.0),
			_rng.randf_range(0.8, 1.15), _rng.randi_range(0, _grain_em.size() - 1)])

func _event_voice(layer: int, pitch: float, t0: float, a: float, h: float, r: float, peak: float) -> Voice:
	var s := WaterAudioBank.bed(layer)
	var v := Voice.new()
	v.layer = layer
	v.id = _bed_em.play(s, -80.0, pitch, _rng.randf() * s.get_length())
	v.t = t0
	v.a = a
	v.h = h
	v.r = r
	v.peak = peak
	return v

func _update_events(delta: float) -> void:
	var off := volume_db + _kind_db
	for k in range(_events.size() - 1, -1, -1):
		var v := _events[k]
		v.t += delta
		if v.id == AudioStreamPlaybackPolyphonic.INVALID_ID:
			_events.remove_at(k)
			continue
		if v.finished():
			_bed_em.stop_voice(v.id)
			_events.remove_at(k)
			continue
		_set_db(v, linear_to_db(maxf(v.env() * v.peak * _master, 0.00001)) + BED_DB[v.layer] + off)
	for k in range(_pending.size() - 1, -1, -1):
		var e: Array = _pending[k]
		if _clock >= e[0]:
			_pending.remove_at(k)
			_grain(e[1], e[2], e[3], e[4])

func _schedule_grains(delta: float) -> void:
	# Far away the grains drown in the bed: thin them out (fewer voices) beyond ~40 % of max_distance.
	var near := clampf(1.3 - _dist / (max_distance * 0.6), 0.1, 1.0)
	for ci in _next.size():
		var j := ci * 5
		var rate := _rates[j] * near
		if rate <= 0.0:
			continue
		var nx := _next[ci] - rate * delta
		var fired := 0
		while nx <= 0.0 and fired < 4:
			fired += 1
			_grain(ci, _rng.randf_range(_rates[j + 1], _rates[j + 2]), _rng.randf_range(_rates[j + 3], _rates[j + 4]), -1)
			nx += -log(maxf(_rng.randf(), 1e-6))
		_next[ci] = maxf(nx, 0.0) if fired >= 4 else nx

func _grain(ci: int, db: float, pitch: float, em_i: int) -> void:
	if _master < 0.001 or _grain_em.is_empty():
		return
	var list := WaterAudioBank.grains(CATS[ci])
	if list.is_empty():
		return
	var s: AudioStreamWAV = list[_bags[ci].pick(_rng)]
	var em := _grain_em[em_i if em_i >= 0 else _rng.randi_range(0, _grain_em.size() - 1)]
	_last_grain = _clock
	em.play(s, db + volume_db + _kind_db + linear_to_db(_master), pitch)

func _sleep() -> void:
	_sleeping = true
	for l in _layers:
		l.voices.clear()
		l.gain = 0.0
	_events.clear()
	_pending.clear()
	_bed_em.stop()
	for em in _grain_em:
		em.stop()

## Number of voices this source currently holds (bed + surf events), for diagnostics.
func bed_voice_count() -> int:
	var n := _events.size()
	for l in _layers:
		n += l.voices.size()
	return n

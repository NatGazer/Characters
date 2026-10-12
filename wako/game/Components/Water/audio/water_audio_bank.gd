class_name WaterAudioBank extends RefCounted
## Shared pieces of the non-repeating water audio (FlowingWaterSound, SwimAudio):
##  * the grain banks (bubbles, plops, splashes, spatter, gurgles, trickles, laps, swim strokes), sliced once from the
##    bank wavs made by .claude/scripts/gen_water_audio.py (table in water_audio_slices.gd) and cached for everyone
##  * the three seamless bed textures (low rumble, mid wash, high fizz), only ever played from random offsets
##  * Bag: picks grains in shuffled order, never the same one twice in a row
##  * Emitter: one AudioStreamPlayer3D + AudioStreamPolyphonic that many grains / bed voices share. It never
##    (re)starts after Shortcuts.graceful_quit() or after something else stopped it (a scene change), so no playback
##    leaks at exit.

const SLICES := preload("res://Components/Water/audio/water_audio_slices.gd")
const BED_LOW := preload("res://Components/Water/audio/bed_low.wav")
const BED_MID := preload("res://Components/Water/audio/bed_mid.wav")
const BED_HIGH := preload("res://Components/Water/audio/bed_high.wav")

enum Bed { LOW, MID, HIGH }

static var _grains := {}

static func bed(which: int) -> AudioStreamWAV:
	match which:
		Bed.LOW: return BED_LOW
		Bed.MID: return BED_MID
	return BED_HIGH

## All grains of a category (&"bubble", &"plop", &"splash", &"spatter", &"gurgle", &"trickle", &"lap", &"stroke").
static func grains(cat: StringName) -> Array[AudioStreamWAV]:
	if _grains.has(cat):
		return _grains[cat]
	var out: Array[AudioStreamWAV] = []
	_grains[cat] = out
	var e: Array = SLICES.BANKS.get(cat, [])
	if e.is_empty():
		push_error("WaterAudioBank: unknown grain category %s" % cat)
		return out
	var src := load(e[0]) as AudioStreamWAV
	if src == null or src.format != AudioStreamWAV.FORMAT_16_BITS or src.stereo:
		push_error("WaterAudioBank: %s must be imported as uncompressed mono 16-bit (compress/mode=0)" % e[0])
		return out
	var data := src.data
	var sl: Array = e[1]
	for i in range(0, sl.size() - 1, 2):
		var w := AudioStreamWAV.new()
		w.format = AudioStreamWAV.FORMAT_16_BITS
		w.mix_rate = src.mix_rate
		w.stereo = false
		w.data = data.slice(sl[i] * 2, (sl[i] + sl[i + 1]) * 2)
		out.append(w)
	return out

## Shortcuts.graceful_quit() has stopped all audio: starting a player now would leak its playback at exit.
static func quitting(n: Node) -> bool:
	if n == null or not n.is_inside_tree():
		return true
	var sc := n.get_node_or_null(^"/root/Shortcuts")
	return sc != null and bool(sc.get(&"quitting"))

## Shuffle bag over n items: every item once per round, and never the same item twice in a row across rounds.
class Bag extends RefCounted:
	var _order := PackedInt32Array()
	var _i := 0
	var _last := -1
	var _n := 0

	func _init(n: int) -> void:
		_n = n

	func pick(rng: RandomNumberGenerator) -> int:
		if _n <= 1:
			return 0
		if _i >= _order.size():
			_order.resize(_n)
			for k in _n:
				_order[k] = k
			for k in range(_n - 1, 0, -1):
				var j := rng.randi_range(0, k)
				var t := _order[k]
				_order[k] = _order[j]
				_order[j] = t
			if _order[0] == _last:
				var j := rng.randi_range(1, _n - 1)
				_order[0] = _order[j]
				_order[j] = _last
			_i = 0
		_last = _order[_i]
		_i += 1
		return _last

## One 3D emitter playing many polyphonic voices.
class Emitter extends RefCounted:
	var player: AudioStreamPlayer3D
	var pb: AudioStreamPlaybackPolyphonic
	var halted := false
	var _started := false

	func _init(parent: Node, polyphony: int, unit_size: float, max_distance: float, bus: StringName, name: String) -> void:
		player = preload("res://Components/WorldAcoustics/world_acoustics.gd").create_player()
		player.name = name
		var s := AudioStreamPolyphonic.new()
		s.polyphony = polyphony
		player.stream = s
		player.unit_size = unit_size
		player.max_distance = max_distance
		player.max_db = 3.0
		player.attenuation_filter_cutoff_hz = 6000.0
		player.bus = bus
		player.top_level = true
		parent.add_child(player, false, Node.INTERNAL_MODE_BACK)

	## Starts the player if needed. False when it may not play (quitting, halted, not in the tree).
	func ensure() -> bool:
		if halted or player == null:
			return false
		if player.playing:
			return pb != null
		if _started:
			# Polyphonic players never end on their own: someone stopped every player (graceful quit, scene change).
			halted = true
			pb = null
			return false
		if WaterAudioBank.quitting(player):
			return false
		player.play()
		pb = player.get_stream_playback() as AudioStreamPlaybackPolyphonic
		_started = pb != null
		return _started

	func play(stream: AudioStream, volume_db: float, pitch: float, from := 0.0) -> int:
		if not ensure():
			return AudioStreamPlaybackPolyphonic.INVALID_ID
		return pb.play_stream(stream, from, volume_db, pitch)

	func set_volume(id: int, volume_db: float) -> void:
		if pb != null and player.playing:
			pb.set_stream_volume(id, volume_db)

	func set_pitch(id: int, pitch: float) -> void:
		if pb != null and player.playing:
			pb.set_stream_pitch_scale(id, pitch)

	func stop_voice(id: int) -> void:
		if pb != null and player.playing:
			pb.stop_stream(id)

	func is_voice_playing(id: int) -> bool:
		return pb != null and player.playing and pb.is_stream_playing(id)

	## Stops the player on purpose (so a later ensure() may start it again).
	func stop() -> void:
		if player != null and player.playing:
			player.stop()
		_started = false
		pb = null

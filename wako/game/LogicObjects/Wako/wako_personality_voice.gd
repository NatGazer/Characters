extends RefCounted
## Exact shared short PCM bank. Runtime preparation never synthesizes samples.
## Event-driven; work impacts keep their own channel.
const RATE := 22050
const BAKED_BANK := preload("res://LogicObjects/Wako/wako_voice_bank.res")
# Syllables [start, duration, f0 start, f0 end] of every baked clip, in bank
# order. The offline synthesizer and the runtime mouth sync share this table.
const NOTES := {
	"effort": [[[.0,.14,260.0,190.0],[.16,.12,360.0,490.0]],[[.0,.10,380.0,255.0],[.13,.17,210.0,330.0]],[[.0,.18,235.0,175.0],[.21,.09,530.0,390.0]]],
	# Curious hums, small fitting chuckles and quiet repair mutters are tied
	# to real foot contacts, never to a timer or an assumed completed job.
	"inspect": [[[.0,.20,185.0,270.0],[.23,.09,340.0,280.0]],[[.0,.13,230.0,175.0],[.17,.16,190.0,310.0]],[[.0,.23,210.0,295.0]]],
	"assemble": [[[.0,.08,290.0,225.0],[.12,.14,470.0,380.0]],[[.0,.11,350.0,260.0],[.15,.08,430.0,560.0],[.26,.07,320.0,240.0]],[[.0,.13,240.0,350.0],[.17,.11,390.0,290.0]]],
	"repair": [[[.0,.11,190.0,210.0],[.14,.08,260.0,205.0],[.25,.09,320.0,245.0]],[[.0,.16,235.0,185.0],[.21,.12,280.0,340.0]],[[.0,.09,270.0,220.0],[.12,.19,180.0,245.0]]],
	"play": [[[.0,.09,420.0,550.0],[.13,.10,540.0,410.0],[.27,.11,460.0,640.0]],[[.0,.11,380.0,570.0],[.17,.15,640.0,440.0]]],
	"jump": [[[.0,.25,330.0,680.0]],[[.0,.07,440.0,330.0],[.09,.21,370.0,710.0]]],
	"warning": [[[.0,.12,690.0,520.0],[.19,.17,760.0,440.0]]],
}
const SEEDS := {"effort":[1,2,3],"inspect":[9,10,11],"assemble":[12,13,14],"repair":[15,16,17],"play":[4,5],"jump":[6,7],"warning":[8]}
# Event kinds without their own PCM reuse a baked clip, re-pitched and/or
# trimmed (time variation): [bank kind, clip index (-1 = any), pitch factor,
# start offset s, length s (0 = to the end), optional pitch bend [at stream
# time s, factor]]. pick() stays one random draw.
const VARIANTS := {
	"hup": ["jump",0,1.24,0.0,.12],
	"hop": ["jump",1,1.30,0.0,.085],
	"wee": ["jump",-1,1.12,0.0,0.0],
	"grunt": ["effort",-1,.90,0.0,.17],
	"nngh": ["effort",2,.80,0.0,.21],
	# "uh-oh": the two falling warning syllables, an octave down, the second
	# bent lower still (a recognisable falling two-note contour).
	"oops": ["warning",0,.62,0.0,0.0,[.17,.8]],
	"yay": ["play",0,1.16,0.0,0.0],
	"hmm": ["inspect",2,.88,0.0,0.0],
	"huh": ["inspect",1,1.10,.17,.16],
	"giggle": ["assemble",1,1.34,0.0,0.0],
	# A slow falling exhale: the long warning fall, far below its pitch.
	"sigh": ["warning",0,.46,.19,.17],
}
static var _bank: Dictionary = {}
static var _notes_by_stream: Dictionary = {}
static var generated_streams := 0
static var generated_bytes := 0
static var generation_usec := 0

static func prepare() -> void:
	if not _bank.is_empty(): return
	var began := Time.get_ticks_usec()
	_bank = BAKED_BANK.get_meta(&"clips")
	for kind: String in _bank:
		var clips: Array = _bank[kind]
		generated_streams += clips.size()
		var notes: Array = NOTES.get(kind,[])
		for index in clips.size():
			var stream: AudioStreamWAV = clips[index]
			generated_bytes += stream.data.size()
			# A clip whose baked length disagrees with the table gets a plain
			# whole-clip envelope rather than a mistimed mouth.
			var clip_notes: Array = notes[index] if index<notes.size() else []
			var expected := 0.0
			for note: Array in clip_notes: expected = maxf(expected,float(note[0])+float(note[1]))
			var actual := stream.data.size()/2.0/float(stream.mix_rate)
			_notes_by_stream[stream.get_instance_id()] = clip_notes if absf(actual-expected-.015)<.004 else [[0.0,actual,300.0,300.0]]
	generation_usec = Time.get_ticks_usec()-began

static func pick(kind: String, rng: RandomNumberGenerator, previous: AudioStream = null) -> AudioStream:
	prepare()
	var clips: Array = _bank.get(kind,_bank.play)
	var last := clips.find(previous)
	# One random draw, with no retries or consecutive identical syllables.
	var index := rng.randi_range(0,clips.size()-2 if last>=0 and clips.size()>1 else clips.size()-1)
	if last>=0 and clips.size()>1 and index>=last: index += 1
	return clips[index]

## Resolve a voice kind (baked or event variant) to {stream, pitch, from,
## length, notes}. Uses one random draw like pick().
static func variant(kind: String, rng: RandomNumberGenerator, previous: AudioStream = null) -> Dictionary:
	prepare()
	var spec: Array = VARIANTS.get(kind,[])
	var stream: AudioStream
	var pitch := 1.0
	var from := 0.0
	var length := 0.0
	var bend: Array = []
	if spec.is_empty():
		stream = pick(kind,rng,previous)
	else:
		var clips: Array = _bank.get(str(spec[0]),_bank.play)
		var index := int(spec[1])
		stream = pick(str(spec[0]),rng,previous) if index<0 or index>=clips.size() else clips[index]
		pitch = float(spec[2])
		from = float(spec[3])
		length = float(spec[4])
		if spec.size()>5: bend = spec[5]
	return {"stream":stream,"pitch":pitch,"from":from,"length":length,"bend":bend,"notes":_notes_by_stream.get(stream.get_instance_id(),[])}

## True between the first syllable's onset and the last one's end (the jaw
## stays slightly open across the gaps of one clip).
static func within(notes: Array, t: float) -> bool:
	if notes.is_empty(): return false
	var last: Array = notes.back()
	return t>=float(notes[0][0]) and t<float(last[0])+float(last[1])

## Jaw opening (0..1) of a clip at stream time t: per-syllable envelope, a
## little wider on the higher, excited part of each glide.
static func mouth_open(notes: Array, t: float) -> float:
	var open := 0.0
	for note: Array in notes:
		var age := t-float(note[0])
		var duration := float(note[1])
		if age<0.0 or age>=duration: continue
		var envelope := smoothstep(0.0,.03,age)*(1.0-smoothstep(duration-.045,duration,age))
		var frequency := lerpf(float(note[2]),float(note[3]),smoothstep(0.0,1.0,age/duration))
		open = maxf(open,envelope*clampf(.3+frequency/850.0,.45,1.0))
	return open

static func regenerate_offline() -> Dictionary:
	# Offline bank regeneration only. Never called by work or idle playback.
	_bank = {}
	_notes_by_stream = {}
	generated_streams = 0
	generated_bytes = 0
	var began := Time.get_ticks_usec()
	for kind: String in NOTES:
		var clips: Array = []
		var notes: Array = NOTES[kind]
		for index in notes.size(): clips.append(_syllables(notes[index],int(SEEDS[kind][index])))
		_bank[kind] = clips
	generation_usec = Time.get_ticks_usec()-began
	return _bank

static func _syllables(notes: Array, seed: int) -> AudioStreamWAV:
	var length := 0.0
	for note: Array in notes: length = maxf(length,float(note[0])+float(note[1]))
	var samples := ceili((length+.015)*RATE)
	var pcm := PackedByteArray()
	pcm.resize(samples*2)
	var noise := RandomNumberGenerator.new()
	noise.seed = seed+8327
	var phase := 0.0
	for sample in samples:
		var time := float(sample)/RATE
		var value := 0.0
		for note: Array in notes:
			var age := time-float(note[0])
			var duration := float(note[1])
			if age<0.0 or age>=duration: continue
			var fraction := age/duration
			var frequency := lerpf(float(note[2]),float(note[3]),smoothstep(0.0,1.0,fraction))*(1.0+.018*sin(age*TAU*22.0))
			phase += TAU*frequency/RATE
			var envelope := smoothstep(0.0,.017,age)*(1.0-smoothstep(duration-.035,duration,age))
			# Harmonic vocal buzz and a little breath, rather than pure alert beeps.
			value += envelope*(sin(phase)*.45+sin(phase*2.0+.3)*.17+sin(phase*3.0)*.08+noise.randf_range(-.018,.018))
		pcm.encode_s16(sample*2,int(clampf(value,-.95,.95)*32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.stereo = false
	stream.data = pcm
	generated_streams += 1
	generated_bytes += pcm.size()
	return stream

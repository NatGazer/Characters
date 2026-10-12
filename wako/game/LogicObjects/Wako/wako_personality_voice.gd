extends RefCounted
## Exact shared short PCM bank. Runtime preparation never synthesizes samples.
## Event-driven; work impacts keep their own channel.
const RATE := 22050
const BAKED_BANK := preload("res://LogicObjects/Wako/wako_voice_bank.res")
static var _bank: Dictionary = {}
static var generated_streams := 0
static var generated_bytes := 0
static var generation_usec := 0

static func prepare() -> void:
	if not _bank.is_empty(): return
	var began := Time.get_ticks_usec()
	_bank = BAKED_BANK.get_meta(&"clips")
	for clips: Array in _bank.values():
		generated_streams += clips.size()
		for stream: AudioStreamWAV in clips: generated_bytes += stream.data.size()
	generation_usec = Time.get_ticks_usec()-began

static func pick(kind: String, rng: RandomNumberGenerator, previous: AudioStream = null) -> AudioStream:
	prepare()
	var clips: Array = _bank.get(kind,_bank.play)
	var last := clips.find(previous)
	# One random draw, with no retries or consecutive identical syllables.
	var index := rng.randi_range(0,clips.size()-2 if last>=0 and clips.size()>1 else clips.size()-1)
	if last>=0 and clips.size()>1 and index>=last: index += 1
	return clips[index]

static func regenerate_offline() -> Dictionary:
	# Offline bank regeneration only. Never called by work or idle playback.
	_bank = {}
	generated_streams = 0
	generated_bytes = 0
	var began := Time.get_ticks_usec()
	_bank.effort = [_syllables([[.0,.14,260.0,190.0],[.16,.12,360.0,490.0]],1),_syllables([[.0,.10,380.0,255.0],[.13,.17,210.0,330.0]],2),_syllables([[.0,.18,235.0,175.0],[.21,.09,530.0,390.0]],3)]
	# Curious hums, small fitting chuckles and quiet repair mutters are tied
	# to real foot contacts, never to a timer or an assumed completed job.
	_bank.inspect = [_syllables([[.0,.20,185.0,270.0],[.23,.09,340.0,280.0]],9),_syllables([[.0,.13,230.0,175.0],[.17,.16,190.0,310.0]],10),_syllables([[.0,.23,210.0,295.0]],11)]
	_bank.assemble = [_syllables([[.0,.08,290.0,225.0],[.12,.14,470.0,380.0]],12),_syllables([[.0,.11,350.0,260.0],[.15,.08,430.0,560.0],[.26,.07,320.0,240.0]],13),_syllables([[.0,.13,240.0,350.0],[.17,.11,390.0,290.0]],14)]
	_bank.repair = [_syllables([[.0,.11,190.0,210.0],[.14,.08,260.0,205.0],[.25,.09,320.0,245.0]],15),_syllables([[.0,.16,235.0,185.0],[.21,.12,280.0,340.0]],16),_syllables([[.0,.09,270.0,220.0],[.12,.19,180.0,245.0]],17)]
	_bank.play = [_syllables([[.0,.09,420.0,550.0],[.13,.10,540.0,410.0],[.27,.11,460.0,640.0]],4),_syllables([[.0,.11,380.0,570.0],[.17,.15,640.0,440.0]],5)]
	_bank.jump = [_syllables([[.0,.25,330.0,680.0]],6),_syllables([[.0,.07,440.0,330.0],[.09,.21,370.0,710.0]],7)]
	_bank.warning = [_syllables([[.0,.12,690.0,520.0],[.19,.17,760.0,440.0]],8)]
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

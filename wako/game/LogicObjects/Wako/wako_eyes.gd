extends RefCounted
## Living face for one Wako (one RefCounted per helper; no node, no material).
##
## * Blinks run at physics rate (close ~50 ms, hold ~30 ms, open ~100 ms) on a
##   log-normal personal clock with doubles/partials, plus motivated blinks on
##   big gaze shifts, landings, hits and completions.
## * Gaze is a world point held in the evaluated cube frame every gaze update
##   (VOR), measured from the real painted eye centre (skin bind pose): the eyes
##   stay on target while the body walks, turns, dances or greets. Target
##   changes are minimum-jerk saccades; fixations carry micro-saccades and
##   small refixations (faces, the player, a watched hostile).
## * Expression channels (lids, tilt, wink, squeeze, pupil, pop, smile, mouth)
##   come from real state (work strokes, load, live danger, play, voices) plus
##   short event pulses, and are uploaded as the shared skin's instance
##   uniforms only when they change. A camera distance/visibility LOD keeps
##   crowds cheap.
const Attention := preload("res://LogicObjects/Wako/wako_attention.gd")
const Voice := preload("res://LogicObjects/Wako/wako_personality_voice.gd")
# Gaze range in atlas UV (the shader's GAZE_MAX): half moves the whole disc,
# half the pupil inside it. tanh knee in radians.
const G_MAX := .03
const G_KNEE := .62
# Per-update gaze step bound (UV); the package head test bounds a tick to .004.
const STEP_LIMIT := .0031
# Work-contact look cap (85% of the range) and the proud-beat lift (UV up).
const WORK_LOOK_MAX := .85*G_MAX
const PROUD_LIFT := .009
# Saccade flight: peak speed (UV/s, .0037 per 120 Hz tick), ease time (s) and
# the per-tick flight bound (under the package's .004).
const FLY_SPEED := .0037*120.0
const FLY_RAMP := 2.0/120.0
const FLY_STEP := .0039
# Midpoint of the two painted eye centres in mesh/bind space (atlas UV
# (.409,.715)/(.409,.914) on the front face), skinned 100% to the cube bone.
const EYE_REST_POINT := Vector3(0.0, 1.175, -.197)
const EYE_SIDE := .213
const STROKE_KINDS := ["assemble","repair","inspect","tool_change","operate"]
# Notice age (s) before which no blink may start: the widen/focus beat plus
# a short refractory on its tail.
const NOTICE_QUIET := 1.25
const STRAIN_KINDS := ["unbend","maintenance","push","pull","brace"]
# Brain rates: quiet faces think at 6/4/2 Hz (near/mid/far or off-screen);
# a near face that is alarmed, airborne or acting at 12 Hz, and one that
# talks, strikes, startles or plays a short pulse at 20 Hz (the expression
# channels themselves settle smoothly at the upload rate). Hits, landings,
# voices and pulses wake the brain on the very next tick.
const LOD_INTERVALS := [1.0/6.0, 1.0/4.0, 1.0/2.0]
const BUSY_INTERVAL := 1.0/12.0
const FAST_INTERVAL := 1.0/20.0
# Gaze/settle/upload stride in physics ticks (60/30/15 Hz at 120 Hz).
const STRIDES := [2, 4, 8]
# Critically damped spring rates (rad/s) of the slow expression channels:
# smile, lower lid and tilt reach ~80% in 150 ms, a lowering upper lid in 110 ms.
const SPRING_SLOW := 20.0
const SPRING_LID := 28.0
enum {UC, LR, TILT, WINK, DIL, POP, SMILE, MOPEN, MCURVE, MWIDTH, MSKEW, SQUEEZE, ALARM, STARTLE, CHANNELS}
const PULSE_CHANNELS := 12
# Squeeze values where the shader's closed seam opens into the "> <" crease.
const SQUEEZE_BAND := Vector2(.44,.68)
# Event pulses: [attack, hold, release, uc, lr, tilt, wink, dil, pop, smile, open, curve, width, skew, squeeze].
const PULSES := {
	&"surprise": [.045,.16,.45, -.32,-.05,0.0,0.0,-.45,1.0,0.0,.65,-.5,-.8,0.0,0.0],
	&"flinch": [.02,.04,.10, -.12,0.0,0.0,0.0,-.2,.35,0.0,.0,0.0,0.0,0.0,0.0],
	&"satisfied": [.08,.35,.45, 0.0,.12,0.0,0.0,.15,0.0,.42,.05,.45,.1,0.0,0.0],
	&"joy": [.10,.9,.6, 0.0,0.0,0.0,0.0,.45,0.0,.95,.38,.9,.3,0.0,0.0],
	&"pride": [.10,.5,.5, .1,.05,0.0,0.0,.2,0.0,.55,.05,.55,.1,0.0,0.0],
	&"curious": [.12,.55,.45, -.06,0.0,.2,.22,.3,.1,0.0,.05,-.35,-.1,.7,0.0],
	&"worry": [.20,1.0,.7, .08,.05,-.8,0.0,.25,0.0,0.0,0.0,-.75,-.1,0.0,0.0],
	&"annoyed": [.15,.7,.7, .22,.18,.5,0.0,0.0,0.0,0.0,0.0,-.35,.25,.35,0.0],
	&"relief": [.25,.6,.9, .25,.1,0.0,0.0,.1,0.0,.45,.1,.35,0.0,0.0,0.0],
	&"notice": [.05,.22,.3, -.1,0.0,0.0,0.0,.3,.25,0.0,0.0,0.0,0.0,0.0,0.0],
	&"squeeze": [.03,.07,.22, .15,.3,.1,0.0,0.0,0.0,0.0,.05,-.4,.45,0.0,.9],
}
var worker: RigidBody3D
var gaze := Vector2.ZERO
var uploads := 0
var events := {"blink":0,"saccade":0,"pulse":0,"hit":0}
var _rng := RandomNumberGenerator.new()
var _time := 0.0
var _tick := 0
var _brain_wait := 0.0
var _brain_time := 0.0
var _brain_interval := 1.0/15.0
var _busy := false
var _fast := false
var _choose_wait := 0.0
var _choose_elapsed := 0.0
var _gaze_time := 0.0
var _gaze_next := 0
var _gaze_stride := 2
var _aim_next := 0
var _reactive_until := 0.0
var _settle_time := 0.0
var _out_next := 0
var _lod := 0
var _lod_next := 0.0
var _eye_local := EYE_REST_POINT
var _rest_inverse := Basis.IDENTITY
var _frame := Transform3D.IDENTITY
var _frame_tick := -1
# Personal traits.
var _blink_mean := 3.4
var _lid_rest := .06
var _pupil_rest := 0.0
var _skew_rest := 0.0
var _expressive := 1.0
var _side := 1.0
var _pupil_drift := 0.0
var _pupil_drift_at := 0.0
# Blink.
var _blink_t := -1.0
var _blink_close := .05
var _blink_hold := .03
var _blink_open := .1
var _blink_depth := 1.0
var _blink_value := 1.0
var _blink_at := 2.0
var _blink_started := -10.0
var _double_pending := false
# A motivated blink (gaze-evoked, landing, completion) fires after a personal
# 40-150 ms latency, so a shared stimulus never blinks a crowd in sync; a
# startle blink opens a quiet window (no gaze-evoked/double/motivated blink
# flutter over the surprise or the notice beat).
var _blink_pending := false
var _blink_pending_depth := 1.0
var _blink_startle := false
var _blink_quiet_until := 0.0
# Gaze.
var _want_point := Vector3.INF
var _want_node: WeakRef
var _want_offset := Vector3.ZERO
var _want_face := false
var _want_hops := 0
var _body_moving := true
var _body_turning := true
var _dancing := false
var _want_key := 0
var _track := Vector3.INF
# Saccade onset latency for shared stimuli (board events, a heard warning).
var _sacc_hold_until := 0.0
var _desired := Vector2.ZERO
var _vergence := 0.0
var _sacc_t := -1.0
var _sacc_dur := .05
var _sacc_from := Vector2.ZERO
var _sacc_amp := 0.0
var _sacc_cruise := false
# The next saccade is a wide alert glance away (pairs with a blink).
var _glance_blink := false
var _micro := Vector2.ZERO
var _micro_wait := .6
var _gaze_static := 0
var _swirl := 0.0
var _look_back_wait := 1.2
var _look_back_left := 0.0
var _cargo_glance_wait := 4.0
var _cargo_glance_left := 0.0
var _alert_glance_wait := 1.0
var _alert_glance_left := 0.0
var _alert_glance_point := Vector3.INF
var _hit_look_left := 0.0
var _hit_point := Vector3.INF
var _hit_v0 := Vector3.ZERO
var _hit_directed := false
var _feature := Vector3.ZERO
var _feature_wait := .5
# The current fixation is the work contact (its deflection is capped), and
# the proud beat after an admitted contact (eyes lift; sometimes a glance up
# at the watching player).
var _work_look := false
var _proud_from := 0.0
var _proud_until := 0.0
var _proud_look_from := 0.0
var _proud_look_until := 0.0
# Channels: target (brain) and current (settled toward the target).
var _target: Array[float] = []
var _value: Array[float] = []
var _vel: Array[float] = []
var _settling := true
var _dirty := true
var _channels_dirty := true
var _pulses: Array[Array] = []
# A clip is playing: the jaw targets follow its syllables at the upload rate
# over the composed mouth (_mouth_pre; _mouth_invert damps its curve upside down).
var _voice_live := false
var _mouth_pre := Vector3.ZERO
var _mouth_invert := 0.0
# Change-only uploads.
var _sent_open := -1.0
var _sent_gaze := Vector2(INF, INF)
var _sent_smile := -1.0
var _sent_alarm := -1.0
var _sent_startle := -1.0
var _sent_lids := Vector4(INF, 0, 0, 0)
var _sent_iris := Vector4(INF, 0, 0, 0)
var _sent_mouth := Vector4(INF, 0, 0, 0)
var _sent_reactive := -1.0
var _squeeze_prev := 0.0
# Event polling memory.
var _was_grounded := true
var _fear_seen := 0.0
var _ground_seen := true
var _air_time := 0.0
var _last_fear := 0.0
var _last_recoil := 0
var _last_leap := ""
var _last_back := ""
var _last_play := ""
var _last_action := ""
var _last_job := ""
var _last_contact := false
var _last_progress := 0.0
var _stroke_squeeze := .8
var _alarm_age := 0.0
var _down := false
var _rest_relaxed := 0.0
var _rest_sleepy := 0.0
var _rest_age := 0.0
var _attention_serial := -1
var _threat_seen := 0
var _up_y := 1.0
var _fast_turn := false
var _partner_ref: WeakRef

func setup(owner: RigidBody3D) -> void:
	worker = owner
	_rng.seed = absi(str(worker.worker_id).hash())+7439
	_blink_mean = _rng.randf_range(2.7,4.3)
	_lid_rest = _rng.randf_range(.03,.09)
	_pupil_rest = _rng.randf_range(-.05,.15)
	_skew_rest = _rng.randf_range(-.12,.12)
	_expressive = _rng.randf_range(.85,1.15)
	_side = 1.0 if _rng.randf()<.5 else -1.0
	_pupil_drift_at = _rng.randf_range(1.0,4.0)
	_blink_at = _rng.randf_range(.5,3.2)
	_brain_wait = _rng.randf()*_brain_interval
	_gaze_next = _rng.randi_range(1,4)
	_out_next = _rng.randi_range(1,4)
	_target.resize(CHANNELS)
	_value.resize(CHANNELS)
	_vel.resize(CHANNELS)
	_target[UC] = _lid_rest
	_value[UC] = _lid_rest
	_resolve_eye_point()
	if worker.has_signal(&"action_contact"): worker.action_contact.connect(_on_contact)

func _resolve_eye_point() -> void:
	var skeleton: Skeleton3D = worker._skeleton
	if not skeleton or skeleton.get_bone_count()==0: return
	var rest := skeleton.get_bone_global_rest(0)
	_rest_inverse = rest.basis.orthonormalized().inverse()
	# The painted eyes are skinned to the cube bone: its bind pose maps the
	# mesh-space eye centre into that bone's frame (the bone rests at the
	# skeleton origin, ~.1 m above the body, not at the model's ground origin).
	_eye_local = rest.affine_inverse()*EYE_REST_POINT
	var mesh: MeshInstance3D = worker._skin_mesh
	var skin: Skin = mesh.skin if mesh else null
	if not skin: return
	for bind in skin.get_bind_count():
		var bone := skin.get_bind_bone(bind)
		if bone<0: bone = skeleton.find_bone(skin.get_bind_name(bind))
		if bone==0:
			_eye_local = skin.get_bind_pose(bind)*EYE_REST_POINT
			return

## Short event face (real trigger owned by the caller).
func pulse(kind: StringName, amount := 1.0, delay := 0.0) -> void:
	var preset: Array = PULSES.get(kind,[])
	if preset.is_empty() or amount<=0.0: return
	if _pulses.size()>=6: _pulses.pop_front()
	_pulses.append([preset,_time+delay,amount*_expressive])
	events.pulse += 1
	wake()

## Compose on the next tick (a pulse, a voice onset): a 2-frame surprise or
## the first syllable is never late.
func wake() -> void:
	_brain_wait = minf(_brain_wait,0.0)

## Rest mood for a seated/resting body (future sit state): relaxed 0..1, sleepy 0..1.
func set_rest(relaxed: float, sleepy := 0.0) -> void:
	_rest_relaxed = clampf(relaxed,0.0,1.0)
	_rest_sleepy = clampf(sleepy,0.0,1.0)

func blink_now(depth := 1.0, slow := false) -> void:
	if _blink_t>=0.0: return
	_start_blink(depth,slow)

## True while the eyes hold a fixation on this node (not mid-saccade, within
## ~10 degrees): personality only smiles at someone it is really looking at.
func watching(node: Node3D) -> bool:
	if not is_instance_valid(node) or not _want_node or _want_node.get_ref()!=node or _sacc_t>=0.0: return false
	return gaze.distance_to(_desired)<.0045

func _on_contact(kind: String) -> void:
	# The helper admitted this real toe/tool contact: brief flinch, then a
	# satisfied glint; a hammer blow sometimes earns a squeeze blink. The
	# satisfied eyes lift off the work for a proud beat (the pupils never
	# press into the cheek), now and then up to the watching player.
	if kind in ["assemble","repair","unbend","maintenance"]:
		pulse(&"flinch",1.0)
		pulse(&"satisfied",.8,.07)
		if _rng.randf()<.4: _motivated_blink(1.0)
		_proud_from = _time+_rng.randf_range(.1,.16)
		_proud_until = _proud_from+_rng.randf_range(.35,.5)
		var personality: RefCounted = worker.personality
		var seen: Node3D = personality._seen_player.get_ref() if personality and personality._seen_player else null
		if is_instance_valid(seen) and _rng.randf()<.15 and seen.global_position.distance_squared_to(worker.global_position)<36.0:
			_proud_look_from = _proud_from
			_proud_look_until = _proud_until+.1
	elif kind in ["inspect","tool_change"]:
		pulse(&"satisfied",.55,.04)

## One physics tick (the helper's _update_expression). Kept lean: most ticks
## only advance clocks; harness profiling wraps this call from outside.
func advance(delta: float) -> void:
	_time += delta
	_tick += 1
	_brain_wait -= delta
	# Two cheap per-tick edges wake the brain at once: a hit (fear jumps)
	# and a landing/take-off.
	var fear: float = worker.fear_time
	var grounded: bool = worker.on_ground
	var recoil: RefCounted = worker.recoil
	if fear>_fear_seen+.3 or grounded!=_ground_seen or (recoil and int(recoil.events)!=_last_recoil):
		_brain_wait = minf(_brain_wait,0.0)
		_ground_seen = grounded
	_fear_seen = fear
	if _brain_wait<=0.0:
		# Timers advance by the real time since the last compose (an early
		# wake never over-counts them), and the next compose waits at most
		# the interval this compose chose: a wake from outside (a voice onset,
		# a pulse, a notice) on a quiet face is followed by the fast cadence
		# at once, never by the old quiet interval.
		var elapsed := minf(_time-_brain_time,.6)
		_brain_time = _time
		var carry := _brain_wait
		_brain(elapsed)
		_brain_wait = clampf(carry+_brain_interval,0.0,_brain_interval)
	if _blink_t>=0.0 or _time>=_blink_at: _advance_blink(delta)
	# Gaze, settling and uploads run on strides with a personal phase (60 Hz
	# near; the renderer never sees more); saccades and the dizzy swirl step
	# every tick (every LOD: the package bounds a tick's gaze step to .004 UV).
	# A slow or still body refreshes its VOR at a half/quarter rate.
	if _sacc_t>=0.0 or _down or _tick>=_gaze_next:
		_advance_gaze(_time-_gaze_time)
		_gaze_time = _time
	if _tick>=_out_next:
		_out_next = _tick+STRIDES[_lod]
		if _voice_live: _voice_mouth()
		if _settling: _settle(_time-_settle_time)
		_settle_time = _time
		if _dirty or (_sent_reactive>0.0 and _time>=_reactive_until): _upload()

# ---------------------------------------------------------------- blinks

func _start_blink(depth: float, slow: bool) -> void:
	_blink_t = 0.0
	_blink_depth = clampf(depth,0.0,1.0)
	var sleepy := _rest_sleepy
	_blink_close = (.085 if slow else .05)*_rng.randf_range(.9,1.12)*(1.0+.6*sleepy)
	_blink_hold = (.09 if slow else .028)*_rng.randf_range(.8,1.3)*(1.0+1.5*sleepy)
	_blink_open = (.16 if slow else .1)*_rng.randf_range(.9,1.15)*(1.0+.8*sleepy)
	_blink_started = _time
	events.blink += 1

func _advance_blink(delta: float) -> void:
	if _blink_t>=0.0:
		_blink_t += delta
		var closure := 0.0
		if _blink_t<_blink_close: closure = smoothstep(0.0,1.0,_blink_t/_blink_close)
		elif _blink_t<_blink_close+_blink_hold: closure = 1.0
		elif _blink_t<_blink_close+_blink_hold+_blink_open: closure = 1.0-smoothstep(0.0,1.0,(_blink_t-_blink_close-_blink_hold)/_blink_open)
		else:
			_blink_t = -1.0
			if _double_pending:
				_double_pending = false
				_blink_at = _time+_rng.randf_range(.05,.12)
		_blink_value = 1.0-_blink_depth*closure
		_dirty = true
		return
	if _time<_blink_at: return
	# Watching a live danger blinks a little more often (stress), resting less.
	var personality: RefCounted = worker.personality
	var alert := float(personality.alert_weight) if personality else 0.0
	var mean := _blink_mean*(1.0-.25*alert)*(1.0+.8*_rest_sleepy)
	var hold := _blink_wait_until()
	if _blink_startle: hold = _time
	if hold>_time:
		# A blink never lands in a strike contact, the notice widen/focus beat
		# or a startle's quiet window. A motivated blink that missed its moment
		# is dropped; the spontaneous clock resumes a personal beat after the
		# hold (blinks never pile up at its end).
		_blink_pending = false
		_double_pending = false
		_blink_at = hold+_rng.randf_range(.25,.8)
		return
	_blink_at = _time+clampf(exp(log(mean)-.1+.45*_rng.randfn()),.6,9.0)
	if _blink_pending:
		_blink_pending = false
		_blink_startle = false
		_double_pending = false
		_start_blink(_blink_pending_depth,false)
		return
	var roll := _rng.randf()
	_double_pending = roll<.12+.05*alert
	_start_blink(_rng.randf_range(.55,.75) if roll>.87 else 1.0,_rest_sleepy>.5)

## Game time until which no blink may start (now or earlier: none).
func _blink_wait_until() -> float:
	var hold := _blink_quiet_until
	# Never blink into a strike contact or the widen/focus beat of a notice.
	if worker.action in STROKE_KINDS and worker.action_progress>.44 and worker.action_progress<.62: hold = maxf(hold,_time+.03)
	var watch: SkeletonModifier3D = worker.threat_watch
	if is_instance_valid(watch):
		if float(watch.notice_widen)>.15 or float(watch.notice_focus)>.05: hold = maxf(hold,_time+.05)
		elif float(watch._notice_age)<NOTICE_QUIET and is_instance_valid(watch.threat):
			# The beat's focus releases by ~.95 s: no gaze- or turn-evoked
			# blink lands right on its tail either (a personal beat first).
			hold = maxf(hold,_time+NOTICE_QUIET-float(watch._notice_age))
	return hold

func _motivated_blink(chance: float, depth := 1.0, latency := .04, spread := .11) -> void:
	if _blink_t>=0.0 or _blink_pending or _time-_blink_started<.3 or _blink_wait_until()>_time or _rng.randf()>chance: return
	_blink_pending = true
	_blink_pending_depth = depth
	_blink_at = _time+latency+_rng.randf()*spread

## Startle blink (a real hit): fast, then a quiet window over the surprise
## and the look toward the source.
func _startle_blink() -> void:
	if _blink_t<0.0 and _blink_wait_until()<=_time:
		_blink_pending = true
		_blink_startle = true
		_blink_pending_depth = 1.0
		_blink_at = _time+_rng.randf_range(.02,.05)
	_double_pending = false
	_blink_quiet_until = _time+.8

# ---------------------------------------------------------------- gaze

func _eye_frame() -> Transform3D:
	# One evaluated cube frame per tick, shared by every gaze query.
	if _frame_tick==_tick: return _frame
	_frame_tick = _tick
	var pose: SkeletonModifier3D = worker._pose
	var root: Transform3D
	if pose and pose.evaluated_valid and not _down:
		root = worker.global_transform*pose.evaluated_worker.affine_inverse()*pose.evaluated_root
	else:
		root = worker._skeleton.global_transform*worker._skeleton.get_bone_global_pose(0)
	_frame = Transform3D(root.basis*_rest_inverse,root*_eye_local)
	_up_y = _frame.basis.y.y
	return _frame

## Eye frame origin in world space (between the painted eye centres).
func eye_origin() -> Vector3:
	return _eye_frame().origin

func _uv_toward(point: Vector3) -> Vector2:
	var frame := _eye_frame()
	var local: Vector3 = (point-frame.origin)*frame.basis
	var distance := local.length()
	if distance<.001: return _desired
	var yaw := atan2(local.x,-local.z)
	var pitch := atan2(local.y,Vector2(local.x,local.z).length())
	# Near targets converge both pupils (half the geometric vergence).
	_vergence = clampf(atan2(EYE_SIDE,maxf(distance,.15))*.5*G_MAX/G_KNEE*clampf(-local.z/distance*2.0,0.0,1.0),0.0,.007) if distance<3.0 else 0.0
	return Vector2(G_MAX*tanh(pitch/G_KNEE),-G_MAX*tanh(yaw/G_KNEE)).limit_length(G_MAX)

func _advance_gaze(delta: float) -> void:
	if _down:
		# Dizzy swirl while the native ragdoll owns the body.
		_swirl += delta*7.0
		gaze = gaze.move_toward(Vector2(cos(_swirl),sin(_swirl*1.3))*.014,STEP_LIMIT)
		worker._eye_gaze = gaze
		_dirty = true
		return
	if _sacc_t>=0.0 and _tick<_aim_next:
		# Mid-flight ticks reuse the last aim (re-aimed every third tick).
		_fly(delta,_desired)
		return
	_aim_next = _tick+3
	var moving: bool = _sacc_t>=0.0
	if _want_node:
		var live: Node3D = _want_node.get_ref()
		if is_instance_valid(live) and live.is_inside_tree():
			var at: Vector3 = live.global_position
			if _want_face:
				var face: Vector3 = live._visual_head_point
				if face.is_finite(): at = face
			# Refixations: a watched actor gets small saccades between its
			# face, body and feet (mostly the face), a watched hostile quick
			# darts over its body, like real looking.
			_feature_wait -= delta
			var hop := false
			if _feature_wait<=0.0 and _lod==0 and _sacc_t<0.0 and _want_hops>0:
				var roll := _rng.randf()
				var feature := Vector3.ZERO
				if _want_hops==2:
					_feature_wait = _rng.randf_range(.3,.75)
					feature = Vector3.ZERO if roll<.4 else Vector3(_rng.randf_range(-.35,.35),_rng.randf_range(-.3,.35),_rng.randf_range(-.2,.2))
				else:
					_feature_wait = _rng.randf_range(.3,.9)
					feature = Vector3.ZERO if roll<.55 else Vector3(_rng.randf_range(-.12,.12),-.35,0.0) if roll<.85 else Vector3(_rng.randf_range(-.15,.15),-.75,0.0)
					if _want_face: feature *= .5
				hop = feature.distance_squared_to(_feature)>.01
				_feature = feature
			at += _want_offset+_feature
			if hop:
				_track = at
				_start_saccade(_uv_toward(at))
				moving = true
			elif not _track.is_finite() or at.distance_squared_to(_track)>.000001:
				# Smooth pursuit of a moving target in world space.
				_track = at if not _track.is_finite() else _track.lerp(at,1.0-exp(-14.0*delta))
				moving = true
	else:
		if _want_point!=_track: moving = true
		_track = _want_point
	if moving or _body_moving: _gaze_static = 0
	else: _gaze_static += 1
	var desired := _uv_toward(_track) if _track.is_finite() else Vector2(-.002,0.0)
	if _work_look:
		# Looking down at the work never pins the pupils at the rim, and the
		# satisfied beat lifts them off the cheek arch.
		desired = desired.limit_length(WORK_LOOK_MAX)
		if _time>=_proud_from and _time<_proud_until: desired.x += PROUD_LIFT
	# Still reacting to a shared stimulus: hold the old fixation briefly.
	if _time<_sacc_hold_until and _sacc_t<0.0: desired = _desired
	if _sacc_t>=0.0:
		_fly(delta,desired)
	elif desired.distance_to(_desired)>.0035 or gaze.distance_to(desired)>.0045:
		# A jump that pursuit/VOR cannot follow (teleported target, wrap
		# behind the body) becomes a catch-up saccade, never a pop.
		_start_saccade(desired)
	else:
		# Micro-saccades: tiny discrete jumps around the target every .35-1.1 s,
		# so a still fixation is truly still (nothing to upload) between them.
		_micro_wait -= delta
		if _micro_wait<=0.0 and _lod==0:
			_micro_wait = _rng.randf_range(.35,1.1)
			_micro = (_micro*.4+Vector2(_rng.randf_range(-1.0,1.0),_rng.randf_range(-1.0,1.0)).normalized()*_rng.randf_range(.0004,.0009)).limit_length(.0012)
		# Fixation (VOR + pursuit + micro-saccades), bounded per update so a
		# fast body turn never pops the pupil.
		gaze = gaze.move_toward((desired+_micro).limit_length(G_MAX+.001),STEP_LIMIT*1.15)
	_desired = desired
	worker._eye_gaze = gaze
	if gaze.distance_squared_to(_sent_gaze)>.000000015: _dirty = true
	# VOR refresh (the body's turn rate is read right here, every update):
	# 60 Hz near for real turns and flight, 30 Hz while dancing or slowly
	# turning, 20 Hz while otherwise moving, 10 Hz for a still fixation.
	var stride: int = STRIDES[_lod]
	var turn: float = absf(worker.turn_rate)
	_gaze_stride = stride if turn>.9 or not _ground_seen else stride*2 if turn>.3 or _dancing else stride*3 if _gaze_static<=2 or _body_moving else stride*6
	_gaze_next = _tick+_gaze_stride
	if _time<_sacc_hold_until: _gaze_next = mini(_gaze_next,_tick+ceili((_sacc_hold_until-_time)*120.0)+1)

func _fly(delta: float, desired: Vector2) -> void:
	# A saccade launched in this very call (a refixation hop) starts its
	# flight next tick; owed stride time never fast-forwards it.
	if _sacc_t==0.0 and _gaze_time==_time and delta>1.5/120.0: delta = 1.0/120.0
	_sacc_t += delta
	var s := clampf(_sacc_t/_sacc_dur,0.0,1.0)
	var progress := s*s*s*(10.0+s*(-15.0+6.0*s))
	if _sacc_cruise:
		# A long glance darts: a 2-tick ease in, a cruise at the per-tick
		# continuity bound, a 2-tick ease out (not a slow min-jerk slide).
		var t := minf(_sacc_t,_sacc_dur)
		var left := _sacc_dur-t
		var travelled := FLY_SPEED*t*t/(2.0*FLY_RAMP) if t<FLY_RAMP else _sacc_amp-FLY_SPEED*left*left/(2.0*FLY_RAMP) if left<FLY_RAMP else FLY_SPEED*(t-.5*FLY_RAMP)
		progress = clampf(travelled/_sacc_amp,0.0,1.0)
	# A target that moves during the flight (a turning body) can never push
	# one tick beyond the continuity bound.
	gaze = gaze.move_toward(_sacc_from.lerp(desired,progress),FLY_STEP*maxf(delta*120.0,1.0))
	if s>=1.0: _sacc_t = -1.0
	worker._eye_gaze = gaze
	if gaze.distance_squared_to(_sent_gaze)>.000000015: _dirty = true

func _start_saccade(to_uv: Vector2) -> void:
	var amplitude := to_uv.distance_to(gaze)
	if amplitude<.0006: return
	var degrees := amplitude/(G_MAX/G_KNEE)*57.3
	# Small saccades follow a minimum-jerk path; one whose min-jerk peak
	# would exceed the per-tick bound flies a speed-limited trapezoid
	# (.055 UV, a full-range glance, in ~.14 s).
	_sacc_dur = clampf(.021+.0022*degrees,.03,.11)
	_sacc_amp = amplitude
	_sacc_cruise = 1.875*amplitude/_sacc_dur>FLY_SPEED and amplitude>FLY_SPEED*FLY_RAMP
	if _sacc_cruise: _sacc_dur = amplitude/FLY_SPEED+FLY_RAMP
	_sacc_from = gaze
	_sacc_t = 0.0
	# Time owed to a skipped stride must not fast-forward the new saccade.
	_gaze_time = _time
	_micro = Vector2.ZERO
	_gaze_static = 0
	events.saccade += 1
	# Big gaze shifts often carry a blink (gaze-evoked blink, starting with
	# the saccade), less often while watching a danger (no flutter over
	# every look); a wide alert glance away always hides its transit in one.
	var glance := _glance_blink
	_glance_blink = false
	if degrees>22.0:
		var personality: RefCounted = worker.personality
		var chance := 1.0 if glance and degrees>40.0 else .5-.3*(float(personality.alert_weight) if personality else 0.0)
		_motivated_blink(chance,1.0,.0,.025)

## hops: 0 none, 1 face/body/feet refixations, 2 quick darts over a hostile.
func _look_at(point: Vector3, key: int, follow: Node3D = null, offset := Vector3.ZERO, hops := -1) -> void:
	if key==_want_key:
		if not follow: _want_point = point
		return
	_want_key = key
	_want_point = point
	_want_node = weakref(follow) if follow else null
	_want_offset = offset
	_want_face = false
	_feature = Vector3.ZERO
	if follow:
		var face: Variant = follow.get("_visual_head_point")
		_want_face = face is Vector3
		_track = (face if face is Vector3 and face.is_finite() else follow.global_position)+offset
	else:
		_track = point
	_want_hops = hops if hops>=0 else 1 if follow and (_want_face or follow==Global.Player) else 0
	if _track.is_finite() and not _down:
		if _time<_sacc_hold_until: _gaze_next = mini(_gaze_next,_tick+ceili((_sacc_hold_until-_time)*120.0)+1)
		else: _start_saccade(_uv_toward(_track))
	_gaze_static = 0

## A shared stimulus (a board event, a heard warning) is looked at after a
## personal 40-150 ms reaction time, so a crowd never jumps in one frame.
func _react_later() -> void:
	_sacc_hold_until = _time+_rng.randf_range(.04,.15)

# ---------------------------------------------------------------- brain

func _brain(elapsed: float) -> void:
	# Staggered sub-steps: events and expression every brain tick, gaze
	# choice every other, LOD every fourth (all on a personal phase).
	# The camera LOD refreshes on game time (4 Hz), never on the brain's own
	# (possibly slow, far) cadence, so a face recovers its rate at once.
	if _time>=_lod_next:
		_lod_next = _time+.25
		_update_lod()
	_poll_events(elapsed)
	_choose_wait -= elapsed
	if _choose_wait<=0.0 or _want_key==0:
		_choose_gaze(_choose_elapsed+elapsed)
		_choose_elapsed = 0.0
		# Gaze decisions: 10 Hz while something real happens, ~3 Hz when quiet
		# (the attention board itself refreshes at ~4 Hz).
		_choose_wait = .1 if _busy or _hit_look_left>0.0 or not worker.current_job_id.is_empty() else .3
	else:
		_choose_elapsed += elapsed
	_compose()
	_brain_interval = LOD_INTERVALS[_lod] if _lod>0 or not _busy else FAST_INTERVAL if _fast else BUSY_INTERVAL
	# Glance/look-back timers keep their length on a far, on-screen face.
	var personality: RefCounted = worker.personality
	if personality and is_instance_valid(personality.live_threat): _brain_interval = minf(_brain_interval,.25)

func _update_lod() -> void:
	var camera: Camera3D = worker.get_viewport().get_camera_3d() if worker.is_inside_tree() else null
	var lod := 0
	if camera:
		var head: Vector3 = worker.global_position+Vector3.UP*.3
		var distance := camera.global_position.distance_to(head)
		lod = 0 if distance<9.0 else 1 if distance<22.0 else 2
		if lod<2 and not camera.is_position_in_frustum(head): lod = 2
	if lod<_lod: _brain_wait = minf(_brain_wait,LOD_INTERVALS[lod])
	_lod = lod

func _poll_events(elapsed: float) -> void:
	# The VOR refresh rate follows real body motion (sampled at brain rate).
	var play_node: RefCounted = worker.idle_play
	var turn: float = absf(worker.turn_rate)
	var dancing: bool = play_node and (play_node.dance_weight>.001 or play_node.crouch_weight>.001)
	# A frozen captive (driven externally, no physics) is never airborne.
	var grounded: bool = worker.on_ground or worker.freeze
	_dancing = dancing
	_body_turning = turn>.6 or dancing or not grounded
	_body_moving = _body_turning or turn>.02 or worker.linear_velocity.length_squared()>.0025 or not worker.action.is_empty() or _sacc_t>=0.0
	# Real hits only: apply_hit/take_damage/native impacts raise fear_time to
	# 2-3 s and the recoil leaf counts directed stumbles. A job interruption
	# (reaction .5, "interrupted") is not a hit and posts nothing.
	var fear: float = worker.fear_time
	var recoil: RefCounted = worker.recoil
	var recoil_events: int = int(recoil.events) if recoil else 0
	var hit := (fear>_last_fear+.3 and fear>=1.9) or recoil_events!=_last_recoil
	if hit and not worker.paused: _on_hit(recoil_events!=_last_recoil)
	_last_fear = fear
	_last_recoil = recoil_events
	var down: bool = not worker.is_available()
	if down!=_down:
		if down:
			pulse(&"surprise",1.0)
			Attention.post(worker,&"fall",worker.global_position,.75,2.0,worker)
		else:
			_start_blink(1.0,true)
			pulse(&"relief",.5,.2)
			pulse(&"annoyed",.6,.9)
		_down = down
		_want_key = 0
	# Landings after real flight.
	if not grounded: _air_time += elapsed
	elif not _was_grounded:
		if _air_time>.22:
			pulse(&"squeeze",_squeeze_amount(clampf(_air_time*1.3,.35,.9)))
			_motivated_blink(.75)
			Attention.post(worker,&"landing",worker.global_position,.45,1.2,worker)
			if _air_time>.5 and worker.cargo_mass>0.0: pulse(&"pride",.7,.25)
		_air_time = 0.0
	_was_grounded = grounded
	# A big, fast body turn carries a blink (eyes reset during the turn).
	var fast_turn: bool = turn>2.5
	if fast_turn and not _fast_turn: _motivated_blink(.55)
	_fast_turn = fast_turn
	# Head-first flips.
	var leap_node: RefCounted = worker.head_leap
	var leap: String = leap_node.state if leap_node else ""
	if leap!=_last_leap:
		if leap=="prepare":
			pulse(&"notice",1.0)
			Attention.post(worker,&"flip",worker.global_position,.65,2.6,worker)
		elif leap=="contact": pulse(&"squeeze",_squeeze_amount(1.0))
		_last_leap = leap
	# Back-tool toss and its caught return.
	var back_node: RefCounted = worker.back_tool
	var back: String = back_node.phase if back_node else ""
	if back!=_last_back:
		if back=="flight":
			Attention.post(worker,&"toss",worker.global_position+Vector3.UP,.6,1.5,worker.equipped_tool if is_instance_valid(worker.equipped_tool) else worker)
		elif _last_back=="flight" and back=="back":
			pulse(&"pride",.8)
			_motivated_blink(.6)
			Attention.post(worker,&"catch",worker.global_position+Vector3.UP*.5,.55,1.2,worker)
		_last_back = back
	# Idle play beats other Wako may enjoy watching.
	if play_node:
		var state: String = play_node.state
		if state!=_last_play:
			if state=="dance": Attention.post(worker,&"dance",worker.global_position,.45,maxf(float(play_node.state_duration),1.5),worker)
			elif state=="gather" and not play_node._water_active: Attention.post(worker,&"hop",worker.global_position,.4,1.4,worker)
			elif state=="water_excited": pulse(&"joy",.8)
			elif state=="water_swim":
				Attention.post(worker,&"splash",worker.global_position,.75,2.0,worker)
				pulse(&"surprise",.6)
			_last_play = state
		var contact: bool = not play_node._pair.is_empty() and bool(play_node._pair.get("contact",false))
		if contact and not _last_contact: Attention.post(worker,&"highfive",worker.global_position+Vector3.UP*.3,.6,1.4,worker)
		_last_contact = contact
	# Useful work: a fresh reservation is noticed before the body departs;
	# an interruption worries; completion is handled by the personality.
	var job: String = worker.current_job_id
	if job!=_last_job:
		if not job.is_empty(): pulse(&"notice",1.0)
		_last_job = job
		_want_key = 0
	var action: String = worker.action
	var progress: float = worker.action_progress
	if action!=_last_action:
		if action=="interrupted" and not hit: pulse(&"worry",.5)
		_last_action = action
		_roll_stroke()
	elif progress<_last_progress-.3: _roll_stroke()
	_last_progress = progress
	var personality: RefCounted = worker.personality
	if not personality: return
	# A newly noticed live threat is looked at on this very brain tick.
	var threat: Node3D = personality.live_threat
	var threat_id := threat.get_instance_id() if is_instance_valid(threat) else 0
	if threat_id!=_threat_seen:
		_threat_seen = threat_id
		_choose_wait = 0.0
	# Relief once a real danger alert releases.
	if float(personality.alert_weight)>.5: _alarm_age += elapsed
	elif _alarm_age>0.0:
		if _alarm_age>1.0 and not _down: pulse(&"relief",.8)
		_alarm_age = 0.0
	# Attention switching to another actor's fresh event: a curious glance.
	var attention: RefCounted = personality.attention
	if attention and attention.serial!=_attention_serial:
		_attention_serial = attention.serial
		var kind: StringName = attention.kind
		if attention.novel and kind in [&"flip",&"splash",&"toss",&"fall",&"hit",&"hop",&"landing"]: pulse(&"curious",.8)
		elif kind in [&"job_done",&"highfive",&"catch"]: pulse(&"satisfied",.6)
	if _rest_amount()>0.0: _rest_age += elapsed
	else: _rest_age = 0.0

func _roll_stroke() -> void:
	# Each hammer stroke squeezes a little differently: mostly a pinched
	# "> <", sometimes only a tight squint; never the in-between closing
	# band where the seam is still opening into the crease.
	_stroke_squeeze = _rng.randf_range(.76,1.0) if _rng.randf()<.7 else _rng.randf_range(.18,.34)

## Pulse amount whose peak squeeze (preset .9 x expressiveness) is a clear
## squint (<= .4) or a clear "> <" crease (>= .74), never the band between.
func _squeeze_amount(amount: float) -> float:
	var peak := .9*amount*_expressive
	if peak<=.4 or peak>=.74: return amount
	return (.38 if peak<.57 else .76)/(.9*_expressive)

func _on_hit(directed: bool) -> void:
	# Surprise first, then the eyes find where it came from, then a little
	# annoyance while recovering. No danger preset without a live enemy.
	events.hit += 1
	pulse(&"surprise",.9)
	_startle_blink()
	# The impulse lands in this physics step: remember the velocity before it
	# and read the push on the next gaze choices (a directed stumble already
	# carries its contact point).
	_hit_v0 = worker.linear_velocity
	_hit_directed = directed
	_hit_point = Vector3.INF
	_hit_look_left = _rng.randf_range(.9,1.3)
	pulse(&"annoyed",.85,_rng.randf_range(.75,1.0))
	_want_key = 0
	_choose_wait = 0.0
	Attention.post(worker,&"hit",worker.global_position+Vector3.UP*.4,.7,1.4,worker)

func _hit_source(directed: bool) -> Vector3:
	var head: Vector3 = worker.global_position+Vector3.UP*.35
	var recoil: RefCounted = worker.recoil
	if directed and recoil:
		var point: Vector3 = recoil.last_point
		if point.is_finite() and point.distance_squared_to(worker.global_position)>.04: return point+Vector3.UP*.2
		var impulse: Vector3 = Vector3(recoil.last_impulse).slide(Vector3.UP)
		if impulse.length_squared()>.0001: return head-impulse.normalized()*2.2
	# The impulse moved the body: its push points away from the source.
	var push: Vector3 = (worker.linear_velocity-_hit_v0).slide(Vector3.UP)
	if push.length_squared()>.04: return head-push.normalized()*2.2
	return Vector3.INF

func _rest_amount() -> float:
	var play: RefCounted = worker.idle_play
	if play and play.state.begins_with("sit"): return 1.0
	return _rest_relaxed

func _work_focus() -> bool:
	return worker.action in STROKE_KINDS and is_instance_valid(worker.work_target) and worker.on_ground and worker.fear_time<=0.0 and not _down

func _choose_gaze(elapsed: float) -> void:
	_work_look = false
	if _down:
		_want_key = -1
		return
	var personality: RefCounted = worker.personality
	var action: String = worker.action
	var job: String = worker.current_job_id
	# 1. A real live hostile (seen, or heard from a peer). A working Wako
	# glances during the notice beat; fear keeps watching while escaping.
	var core: Node3D = personality.live_threat if personality else null
	if is_instance_valid(core):
		var working: bool = not job.is_empty() or not action in ["","danger","interrupted"] or is_instance_valid(worker.station)
		var watch: SkeletonModifier3D = worker.threat_watch
		if is_instance_valid(core) and (not working or worker.fear_time>0.0 or is_instance_valid(watch) and float(watch._notice_age)<.9):
			var caller: Node3D = personality.heard_caller.get_ref() if personality.heard_caller else null
			if is_instance_valid(caller) and float(personality.heard_age)<.32 and caller!=worker:
				if _want_key!=caller.get_instance_id(): _react_later()
				_look_at(Vector3.INF,caller.get_instance_id(),caller)
				return
			if worker.fear_time>0.0 and worker.gait_speed>1.0 and worker.has_target:
				# Escaping: watch the path, peek back at the enemy on a rhythm.
				_look_back_wait -= elapsed
				if _look_back_left>0.0: _look_back_left -= elapsed
				elif _look_back_wait<=0.0:
					_look_back_wait = _rng.randf_range(1.0,1.8)
					_look_back_left = _rng.randf_range(.38,.55)
				if _look_back_left<=0.0:
					_look_at(worker.target_position+Vector3.UP*.9,7)
					return
			elif _alert_glance(elapsed,core):
				return
			_look_at(Vector3.INF,core.get_instance_id(),core,Vector3.ZERO,2)
			return
	# 2. A real hit: look where it came from before anything else.
	if _hit_look_left>0.0:
		_hit_look_left -= elapsed
		if not _hit_point.is_finite(): _hit_point = _hit_source(_hit_directed)
		if _hit_point.is_finite():
			_look_at(_hit_point,_point_key(_hit_point,43))
			return
	# 3. Foot-held gun: the real aim target, never the gun node itself.
	var gun: Node3D = worker.portable_gun
	if gun and (is_instance_valid(worker.equipped_gun) or worker.work_target==gun):
		var aim: Vector3 = gun.desired_target
		if aim.is_finite(): _look_at(aim,_point_key(aim,11))
		else: _look_at(worker.global_position-worker._model.global_basis.z*4.0+Vector3.UP*.5,12)
		return
	# 4. Thrown tool in the air; part during a flip.
	var back: RefCounted = worker.back_tool
	if back and back.phase=="flight" and is_instance_valid(worker.equipped_tool):
		_look_at(Vector3.INF,worker.equipped_tool.get_instance_id(),worker.equipped_tool)
		return
	var leap: RefCounted = worker.head_leap
	if leap and leap.active() and is_instance_valid(leap.part) and not leap.contacted:
		_look_at(Vector3.INF,leap.part.get_instance_id(),leap.part)
		return
	# 5. Useful work: the real contact point, then the coordinator's phase
	# hint (stock, tool, destination or the next lease), then travel.
	if _work_focus():
		if _time>=_proud_look_from and _time<_proud_look_until:
			var personality_seen: Node3D = personality._seen_player.get_ref() if personality and personality._seen_player else null
			if is_instance_valid(personality_seen):
				_look_at(Vector3.INF,personality_seen.get_instance_id(),personality_seen,Vector3.UP*.6,0)
				return
		_work_look = true
		_look_at(worker.work_point(),worker.work_target.get_instance_id()+13)
		return
	if action in STRAIN_KINDS and is_instance_valid(worker.work_target):
		_look_at(Vector3.INF,worker.work_target.get_instance_id(),worker.work_target)
		return
	if not job.is_empty():
		if worker.carrying and worker.cargo_mass>0.0:
			# Load awareness: an occasional eyes-up check on the head cargo.
			_cargo_glance_wait -= elapsed
			if _cargo_glance_left>0.0:
				_cargo_glance_left -= elapsed
				_look_at(worker.head_anchor.global_position+Vector3.UP*.25,17)
				return
			if _cargo_glance_wait<=0.0:
				_cargo_glance_wait = _rng.randf_range(3.0,6.0)
				_cargo_glance_left = _rng.randf_range(.3,.45)
		# The hint node (a part in flight, a tool) is pursued, not re-aimed.
		var hint_node: Node3D = worker.attention_node
		if is_instance_valid(hint_node) and hint_node.is_inside_tree():
			_look_at(Vector3.INF,hint_node.get_instance_id(),hint_node)
			return
		var hint: Vector3 = worker.attention_point
		if hint.is_finite():
			_look_at(hint,_point_key(hint,19))
			return
		if is_instance_valid(worker.work_target):
			_look_at(Vector3.INF,worker.work_target.get_instance_id(),worker.work_target)
			return
		if worker.has_target:
			_look_at(worker.target_position+Vector3.UP*.4,_point_key(worker.target_position,23))
			return
	# 6. Play: water, partner, the greeted player.
	var play: RefCounted = worker.idle_play
	if play and play._water_active and play._water_point.is_finite() and (play.state.begins_with("water") or play.state=="gather"):
		_look_at(play._water_point,29)
		return
	var partner := _find_partner(play)
	_partner_ref = weakref(partner) if partner else null
	if partner:
		_look_at(Vector3.INF,partner.get_instance_id(),partner)
		return
	var source: Object = worker._eye_smile_source.get_ref() if worker._eye_smile_source else null
	var source_weight: Variant = source.get("smile_weight") if source else null
	if (source_weight is float or source_weight is int) and float(source_weight)>.05:
		var smile_point: Variant = source.get("look_position")
		if smile_point is Vector3 and smile_point.is_finite():
			if source==personality and is_instance_valid(Global.Player): _look_at(Vector3.INF,Global.Player.get_instance_id(),Global.Player,Vector3.UP*.6)
			else: _look_at(smile_point,_point_key(smile_point,37))
			return
	# 7. Free attention (attention board / player / personal scan points);
	# a Wako walking somewhere mostly watches where it is going.
	var attention: RefCounted = personality.attention if personality else null
	if worker.has_target and worker.gait_speed>.35 and (not attention or float(attention.strength)<.45) \
		and (worker.target_position-worker.global_position).slide(Vector3.UP).length_squared()>.64:
		_look_at(worker.target_position+Vector3.UP*.5,_point_key(worker.target_position,31))
		return
	if attention and attention.point.is_finite():
		var follow: Node3D = attention.node.get_ref() if attention.node else null
		var shared: bool = attention.kind!=&"player" and attention.kind!=&"scan"
		if is_instance_valid(follow) and follow!=worker:
			if shared and _want_key!=follow.get_instance_id(): _react_later()
			_look_at(Vector3.INF,follow.get_instance_id(),follow,Vector3.UP*.6 if follow==Global.Player else Vector3.ZERO)
		else:
			if shared and _want_key!=1000003+int(attention.serial): _react_later()
			_look_at(attention.point,1000003+int(attention.serial))
		return
	_look_at(Vector3.INF,1)

func _alert_glance(elapsed: float, core: Node3D) -> bool:
	# Watching a live hostile is not one frozen stare: short glances to a
	# peer, the player or the way out, then back to the enemy.
	_alert_glance_wait -= elapsed
	if _alert_glance_left>0.0:
		_alert_glance_left -= elapsed
		if _alert_glance_point.is_finite():
			_look_at(_alert_glance_point,_point_key(_alert_glance_point,41))
			return true
		return false
	if _alert_glance_wait>0.0: return false
	_alert_glance_wait = _rng.randf_range(.9,1.7)
	_alert_glance_point = Vector3.INF
	var roll := _rng.randf()
	var personality: RefCounted = worker.personality
	if roll<.4:
		var peer := _nearest_peer()
		if peer: _alert_glance_point = peer._visual_head_point
	elif roll<.65:
		var seen: Node3D = personality._seen_player.get_ref() if personality._seen_player else null
		if is_instance_valid(seen): _alert_glance_point = seen.global_position+Vector3.UP*.6
	if not _alert_glance_point.is_finite():
		var cover: Vector3 = personality._cover_point
		var away: Vector3 = (worker.global_position-core.global_position).slide(Vector3.UP)
		_alert_glance_point = cover+Vector3.UP*.2 if cover.is_finite() else worker.global_position+away.normalized()*3.0 if away.length_squared()>.01 else Vector3.INF
	if not _alert_glance_point.is_finite(): return false
	_alert_glance_left = _rng.randf_range(.22,.42)
	_glance_blink = true
	_look_at(_alert_glance_point,_point_key(_alert_glance_point,41))
	if _time>=_sacc_hold_until: _glance_blink = false
	return true

func _nearest_peer() -> Node3D:
	var service: Node = worker.coordinator
	if not is_instance_valid(service): return null
	var best: Node3D
	var best_distance := 64.0
	for peer: Variant in service.workers:
		if not is_instance_valid(peer) or peer==worker or not peer.is_inside_tree(): continue
		var distance: float = worker.global_position.distance_squared_to(peer.global_position)
		if distance<best_distance and Vector3(peer._visual_head_point).is_finite():
			best = peer
			best_distance = distance
	return best

func _point_key(point: Vector3, salt: int) -> int:
	# Same coarse location (.4 m cells) = same fixation; a new cell = saccade.
	return hash(Vector3i(roundi(point.x*2.5),roundi(point.y*2.5),roundi(point.z*2.5)))+salt

func _find_partner(play: RefCounted) -> Node3D:
	if not play or worker.fear_time>0.0: return null
	var peer: Node3D
	if not play._pair.is_empty():
		if str(play._pair.get("stage",""))!="route": peer = play._pair_peer()
	elif play.paired_balance and play.paired_balance.active(): peer = play.paired_balance.peer()
	elif play.upside_down and play.upside_down.active():
		var session: Dictionary = play.upside_down.session
		for key: String in ["a","b","base","top"]:
			var ref: Variant = session.get(key)
			if ref is WeakRef and ref.get_ref() and ref.get_ref()!=worker: peer = ref.get_ref()
	return peer if is_instance_valid(peer) and peer.is_inside_tree() else null

func _compose() -> void:
	var personality: RefCounted = worker.personality
	var attention_strength := float(personality.attention.strength) if personality and personality.attention else 0.0
	var uc := _lid_rest-.08*smoothstep(.4,.8,attention_strength)
	var lr := 0.0
	var tilt := 0.0
	var wink := 0.0
	# Pupil unrest: a small new resting size every few seconds (it settles,
	# then the face is quiet again; no per-frame wobble to upload).
	if _time>=_pupil_drift_at:
		_pupil_drift_at = _time+_rng.randf_range(2.0,5.0)
		_pupil_drift = _rng.randf_range(-.06,.06)
	var dil := _pupil_rest+_pupil_drift
	var pop := 0.0
	var smile := 0.0
	var mopen := 0.0
	var mcurve := 0.0
	var mwidth := 0.0
	var mskew := _skew_rest
	var squeeze := 0.0
	var alarm := 0.0
	var startle := 0.0
	_voice_live = false
	if _down:
		var wobble := sin(_time*5.0)
		uc = .5; lr = .3; tilt = -.5; mopen = .35; mwidth = -.5; mskew = .6*wobble; mcurve = -.4
	else:
		var action: String = worker.action
		var progress: float = worker.action_progress
		var gait: float = worker.gait_speed
		var threat_core: Node3D = personality.live_threat if personality else null
		if not is_instance_valid(threat_core): threat_core = null
		if gait>2.2 and worker.fear_time<=0.0: uc -= .05
		# Effort: draw (determined lens squint) -> strike near the .56 contact
		# (a pinched squeeze, gritted mouth) -> the admitted contact pulses.
		if not action.is_empty():
			if _work_focus():
				if action=="assemble" or action=="repair":
					var draw := smoothstep(.10,.30,progress)*(1.0-smoothstep(.48,.55,progress))
					var strike := smoothstep(.49,.55,progress)*(1.0-smoothstep(.60,.72,progress))
					uc += .38*draw+.15*strike
					lr += .36*draw+.3*strike
					tilt += .35*draw+.15*strike
					# The squeeze itself snaps shut and open around the contact
					# (~70-80 ms each way), so the seam->crease band is crossed
					# in one or two uploads.
					squeeze += _stroke_squeeze*smoothstep(.50,.535,progress)*(1.0-smoothstep(.62,.66,progress))
					mcurve -= .35*draw+.5*strike
					mwidth += .3*draw+.55*strike
					mopen += .1*strike
				elif action=="inspect":
					uc -= .08; dil += .3; tilt += .12; mskew += .35*_side; mcurve -= .2
				else:
					uc += .15; tilt += .3; mcurve -= .15
			elif action in STRAIN_KINDS:
				var strain := smoothstep(.12,.3,progress)*(1.0-smoothstep(.82,.97,progress))
				uc += .3*strain; lr += .3*strain; tilt += .6*strain; squeeze += .22*strain; mcurve -= .45*strain; mwidth += .5*strain
			elif action=="place":
				uc += .08; mcurve += .1
			elif action=="interrupted":
				tilt -= .3; mcurve -= .3
		elif not worker.needs.is_empty():
			tilt -= .3; mcurve -= .3
		# Load: a heavy head cargo shows in the lids and a tight mouth.
		var cargo_load := clampf(worker.cargo_mass/30.0,0.0,1.0)
		if cargo_load>0.0:
			uc += .12*cargo_load; lr += .1*cargo_load; tilt += .15*cargo_load; mwidth += .15*cargo_load; mcurve -= .15*cargo_load
		var play: RefCounted = worker.idle_play
		# Airborne play/stunts: eyes wide, little "wee" mouth.
		if _air_time>.12:
			pop += .4; uc -= .15; mopen += .3; mwidth -= .35
			if play and play.state in ["flight","landing","water_flight","water_exit_flight"]: smile += .25
		# Danger preset (worried lids, frown) only for a real live enemy:
		# fleeing it, or watching it while idle. Sustained worry dilates
		# ("puppy eyes"); a bump with no enemy is surprise + annoyance only.
		if threat_core:
			if worker.fear_time>0.0 and worker.on_ground and not worker.paused: alarm = 1.0
			elif worker.current_job_id.is_empty() and action in ["","danger","interrupted"]: alarm = float(personality.alert_weight)
		else:
			var shaken := clampf(worker.fear_time/3.0,0.0,1.0)
			tilt -= .2*shaken; mcurve -= .2*shaken
		dil += .3*alarm
		# Real notice: widen first (pop, a brief pupil constriction, gasp),
		# then a focused worried look while the warning plays.
		var watch: SkeletonModifier3D = worker.threat_watch
		if is_instance_valid(watch):
			var widen := float(watch.notice_widen)
			var focus := float(watch.notice_focus)
			if widen>0.0 or focus>0.0:
				uc += -.34*widen+.12*focus
				lr += .14*focus
				pop += .9*widen
				dil -= .55*widen
				tilt -= .35*focus
				mopen += .55*widen
				mwidth -= .7*widen
				startle = maxf(widen,.6*focus)
		# Social joy: the greeting smile, water, a partner's real contact.
		var social := 0.0
		var source: Object = worker._eye_smile_source.get_ref() if worker._eye_smile_source else null
		var source_weight: Variant = source.get("smile_weight") if source else null
		if source_weight is float or source_weight is int: social = clampf(float(source_weight),0.0,1.0)*(1.0-alarm)
		if play and alarm<.01:
			if play._water_active:
				var state: String = play.state
				if state=="water_attention": social = maxf(social,.35)
				elif state in ["water_excited","water_run","water_settle","water_swim","water_swim_return"]:
					social = maxf(social,.9); mopen += .35; dil += .45
			if not play._pair.is_empty() and bool(play._pair.get("contact",false)):
				social = maxf(social,.75*(1.0-smoothstep(.45,.9,float(play._pair.get("contact_age",0.0)))))
			# A partner nearby warms the eyes; the real contact makes them beam.
			elif _partner_ref and _partner_ref.get_ref(): social = maxf(social,.2)
		smile += social
		mcurve += .6*social
		# The hello parts the lips on its accent, then eases shut into the
		# smile; only a real "hello" clip opens the mouth wide (its syllables
		# drive the jaw below; a silent open mouth reads as posed).
		if personality: mopen += .06*social*float(personality.greeting_weight)*(1.0-smoothstep(.3,.55,float(personality.greeting_age)))
		dil += .3*social
		# Resting (sit API or a future idle "sit*" state): relaxed lids,
		# sleepy after a while unless something interesting is watched.
		var rest := _rest_amount()
		if rest>0.0:
			var sleepy := maxf(_rest_sleepy,smoothstep(15.0,25.0,_rest_age)*.6)*(1.0-attention_strength)
			uc = lerpf(uc,maxf(uc,.2+.35*sleepy),rest)
			lr += .1*rest; tilt -= .15*sleepy; mcurve += .15*rest; dil += .2*sleepy
		# Gun aim: a determined one-eye aiming squint.
		var gun: Node3D = worker.portable_gun
		if gun and is_instance_valid(worker.equipped_gun) and gun.desired_target.is_finite():
			wink += .45*_side; uc += .2; tilt += .35; mcurve -= .2; mskew += .4*_side
		# Voice: the jaw follows the real clip's syllables (_voice_mouth, at
		# the upload rate); happy calls also smile.
		if personality and float(personality.voice_clock)>=0.0 and not personality.voice_notes.is_empty():
			_voice_live = true
			var kind: String = personality.voice_kind
			if kind=="play" or kind=="yay" or kind=="giggle" or kind=="hello": smile = maxf(smile,.35)
	# Upside down (flips, upside-down play) a smile would read as a frown:
	# show happy arcs and a small round "o" instead.
	_mouth_invert = 0.0
	if _up_y<-.3:
		var inverted := smoothstep(-.3,-.7,_up_y)
		_mouth_invert = inverted
		mcurve = lerpf(mcurve,0.0,inverted)
		mopen = maxf(mopen,.3*inverted)
		mwidth = lerpf(mwidth,-.6,inverted)
		smile = maxf(smile,.55*inverted)
	var t := _target
	t[UC] = uc; t[LR] = lr; t[TILT] = tilt; t[WINK] = wink; t[DIL] = dil; t[POP] = pop; t[SMILE] = smile
	t[MOPEN] = mopen; t[MCURVE] = mcurve; t[MWIDTH] = mwidth; t[MSKEW] = mskew; t[SQUEEZE] = squeeze; t[ALARM] = alarm; t[STARTLE] = startle
	# Compose at 20 Hz only while timing is visible (syllables, a strike, the
	# startle beat, a pulse's attack); held/releasing pulses settle at 12 Hz.
	var attacking := _apply_pulses() if not _pulses.is_empty() else false
	var talking: bool = personality and float(personality.voice_clock)>=0.0
	_mouth_pre = Vector3(t[MOPEN],t[MCURVE],t[MWIDTH])
	if _voice_live: _voice_mouth()
	_fast = attacking or talking or startle>0.0 or squeeze>0.0 or (worker.action in STROKE_KINDS and _work_focus())
	_busy = _fast or not _pulses.is_empty() or _down or alarm>0.0 or not worker.action.is_empty() or _air_time>0.0
	t[UC] = clampf(t[UC],-.4,1.0)
	t[LR] = clampf(t[LR],0.0,1.0)
	t[TILT] = clampf(t[TILT],-1.0,1.0)
	t[WINK] = clampf(t[WINK],-1.0,1.0)
	t[DIL] = clampf(t[DIL],-1.0,1.0)
	t[POP] = clampf(t[POP],0.0,1.0)
	t[SMILE] = clampf(t[SMILE],0.0,1.0)
	t[MOPEN] = clampf(t[MOPEN],0.0,1.0)
	t[MCURVE] = clampf(t[MCURVE],-1.0,1.0)
	t[MWIDTH] = clampf(t[MWIDTH],-1.0,1.0)
	t[MSKEW] = clampf(t[MSKEW],-1.0,1.0)
	t[SQUEEZE] = clampf(t[SQUEEZE],0.0,1.0)
	if not _settling:
		for channel in CHANNELS:
			if absf(_value[channel]-t[channel])>.002:
				_settling = true
				break

## The jaw on the playing clip's syllables, over the composed mouth: run by
## every compose and, while a clip plays, at every upload stride (60 Hz near),
## so a syllable is never sampled late by the brain's own cadence.
func _voice_mouth() -> void:
	var t := _target
	var open_now := _mouth_pre.x
	var curve := _mouth_pre.y
	var width := _mouth_pre.z
	var personality: RefCounted = worker.personality
	if personality and float(personality.voice_clock)>=0.0 and not personality.voice_notes.is_empty():
		var notes: Array = personality.voice_notes
		var clock := float(personality.voice_clock)
		var open := Voice.mouth_open(notes,clock)
		# The jaw stays a little open between the syllables of one clip.
		if Voice.within(notes,clock): open = maxf(open,.16)
		var shape := _voice_shape(personality.voice_kind)
		var shaped := minf(open*3.0,1.0)
		open_now = maxf(open_now,open*shape.x)
		curve += shape.y*shaped*(1.0-_mouth_invert)
		width += shape.z*shaped
	else: _voice_live = false
	open_now = clampf(open_now,0.0,1.0)
	curve = clampf(curve,-1.0,1.0)
	width = clampf(width,-1.0,1.0)
	if absf(t[MOPEN]-open_now)>.001 or absf(t[MCURVE]-curve)>.001 or absf(t[MWIDTH]-width)>.001: _settling = true
	t[MOPEN] = open_now
	t[MCURVE] = curve
	t[MWIDTH] = width

func _voice_shape(kind: String) -> Vector3:
	# (open gain, curve, width) per call: warning shouts, play beams,
	# effort grits, hums stay small and lopsided.
	match kind:
		"warning": return Vector3(1.0,-.6,-.4)
		"play","yay","giggle","wee": return Vector3(.85,.6,.2)
		"hello": return Vector3(.7,.45,.1)
		"effort","grunt","nngh": return Vector3(.5,-.4,.5)
		"inspect","hmm","huh": return Vector3(.38,-.1,-.3)
		"jump","hup","hop": return Vector3(.8,0.0,-.5)
		"oops": return Vector3(.8,-.35,-.6)
		"sigh": return Vector3(.4,.1,-.1)
	return Vector3(.65,.1,0.0)

func _apply_pulses() -> bool:
	# Adds the live pulse envelopes; true while one is starting (its attack,
	# or due within the next busy brain tick).
	var t := _target
	var attacking := false
	var index := 0
	while index<_pulses.size():
		var entry: Array = _pulses[index]
		var preset: Array = entry[0]
		var age: float = _time-float(entry[1])
		var attack := float(preset[0])
		var hold := float(preset[1])
		var release := float(preset[2])
		if age>attack+hold+release:
			_pulses.remove_at(index)
			continue
		index += 1
		if age<attack+.03: attacking = attacking or age>-BUSY_INTERVAL
		if age<0.0: continue
		var weight := float(entry[2])*(smoothstep(0.0,attack,age) if age<attack else 1.0 if age<attack+hold else 1.0-smoothstep(attack+hold,attack+hold+release,age))
		for channel in PULSE_CHANNELS: t[channel] += float(preset[3+channel])*weight
	return attacking

func _settle(delta: float) -> void:
	# The slow expression channels (smile, lower lid, tilt, upper lid) are
	# critically damped springs (exact step for any stride), so an onset eases
	# in over ~150 ms instead of snapping, and never overshoots; a widening
	# upper lid (surprise, notice) still opens like a reflex. The fast
	# channels (pop, pupil, squeeze, startle, jaw...) are exponential
	# approaches: a 2-frame surprise, never a pop. Alarm rises fast and
	# releases slowly; the jaw opens fast and eases shut.
	var settled := true
	var fast := 1.0-exp(-30.0*delta)
	var decay_slow := exp(-SPRING_SLOW*delta)
	var decay_lid := exp(-SPRING_LID*delta)
	for channel in CHANNELS:
		var target := _target[channel]
		var value := _value[channel]
		if channel<=TILT or channel==SMILE:
			var vel := _vel[channel]
			if value==target and vel==0.0: continue
			if channel==UC and target<value-.04:
				vel = 0.0
				value = lerpf(value,target,1.0-exp(-40.0*delta))
			else:
				var omega := SPRING_LID if channel==UC else SPRING_SLOW
				var offset := value-target
				var c := vel+omega*offset
				var decay := decay_lid if channel==UC else decay_slow
				value = target+(offset+c*delta)*decay
				vel = (vel-omega*c*delta)*decay
			if absf(value-target)<.0015 and absf(vel)<.03:
				value = target
				vel = 0.0
			else: settled = false
			_vel[channel] = vel
			_value[channel] = value
			continue
		if value==target: continue
		var rate := fast
		if channel==ALARM: rate = 1.0-exp(-(18.0 if target>value else 5.0)*delta)
		elif channel==SQUEEZE: rate = 1.0-exp(-60.0*delta)
		elif channel==MOPEN: rate = 1.0-exp(-(32.0 if target>value else 15.0)*(1.5 if _voice_live else 1.0)*delta)
		value = lerpf(value,target,rate)
		if absf(value-target)<.0015: value = target
		else: settled = false
		_value[channel] = value
	_settling = not settled
	_dirty = true
	_channels_dirty = true

func _upload() -> void:
	_dirty = false
	var mesh: MeshInstance3D = worker._skin_mesh
	if not mesh: return
	var changed := false
	var open := _blink_value
	if open!=_sent_open and (absf(open-_sent_open)>.003 or open<=0.0 or open>=1.0):
		_sent_open = open
		mesh.set_instance_shader_parameter(&"eye_openness",open)
		changed = true
	if gaze.distance_squared_to(_sent_gaze)>.000000015:
		_sent_gaze = gaze
		mesh.set_instance_shader_parameter(&"gaze_uv_offset",gaze)
		changed = true
	if _channels_dirty or absf(_vergence-_sent_iris.y)>.0003:
		_channels_dirty = false
		changed = _upload_channels(mesh) or changed
	# Material-only changes have no motion vectors: mark the eye pass
	# reactive for TAA while the face changes (held .2 s, so intermittent
	# changes never flap the flag).
	if changed:
		uploads += 1
		_reactive_until = _time+.2
	var reactive := 1.0 if changed or _time<_reactive_until else 0.0
	if reactive!=_sent_reactive:
		_sent_reactive = reactive
		mesh.set_instance_shader_parameter(&"eye_reactivity",reactive)

func _upload_channels(mesh: MeshInstance3D) -> bool:
	var changed := false
	var v := _value
	if absf(v[SMILE]-_sent_smile)>.003 or (v[SMILE]==0.0 and _sent_smile!=0.0):
		_sent_smile = v[SMILE]
		mesh.set_instance_shader_parameter(&"eye_smile",_sent_smile)
		changed = true
	if absf(v[ALARM]-_sent_alarm)>.003 or (v[ALARM]==0.0 and _sent_alarm!=0.0):
		_sent_alarm = v[ALARM]
		mesh.set_instance_shader_parameter(&"face_alarm",_sent_alarm)
		changed = true
	if absf(v[STARTLE]-_sent_startle)>.003 or (v[STARTLE]==0.0 and _sent_startle!=0.0):
		_sent_startle = v[STARTLE]
		mesh.set_instance_shader_parameter(&"face_startle",_sent_startle)
		changed = true
	var lids := Vector4(v[UC],v[LR],v[TILT],v[WINK])
	if _vec4_moved(lids,_sent_lids):
		_sent_lids = lids
		mesh.set_instance_shader_parameter(&"eye_lids",lids)
		changed = true
	# The shader's seam->crease scissor band (.44-.68) is never displayed:
	# a squeeze crossing it shows the side it is moving toward, so a strike
	# reads seam -> "> <" (and back) from one upload to the next.
	var squeeze := v[SQUEEZE]
	if squeeze>SQUEEZE_BAND.x and squeeze<SQUEEZE_BAND.y:
		if squeeze>_squeeze_prev+.001: squeeze = SQUEEZE_BAND.y
		elif squeeze<_squeeze_prev-.001: squeeze = SQUEEZE_BAND.x
		elif _sent_iris.w<=SQUEEZE_BAND.x or _sent_iris.w>=SQUEEZE_BAND.y: squeeze = _sent_iris.w
		else: squeeze = SQUEEZE_BAND.y if squeeze>.56 else SQUEEZE_BAND.x
	_squeeze_prev = v[SQUEEZE]
	var iris := Vector4(v[DIL],_vergence,v[POP],squeeze)
	if _vec4_moved(iris,_sent_iris) or absf(iris.y-_sent_iris.y)>.0003:
		_sent_iris = iris
		mesh.set_instance_shader_parameter(&"eye_iris",iris)
		changed = true
	var mouth := Vector4(v[MOPEN],v[MCURVE],v[MWIDTH],v[MSKEW])
	if _vec4_moved(mouth,_sent_mouth):
		_sent_mouth = mouth
		mesh.set_instance_shader_parameter(&"mouth_shape",mouth)
		changed = true
	return changed

static func _vec4_moved(a: Vector4, b: Vector4) -> bool:
	return absf(a.x-b.x)>.003 or absf(a.y-b.y)>.003 or absf(a.z-b.z)>.003 or absf(a.w-b.w)>.003 \
		or (a!=b and (a==Vector4.ZERO or b==Vector4.ZERO))

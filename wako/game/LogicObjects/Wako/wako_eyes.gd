extends RefCounted
## Living face for one Wako (one RefCounted per helper; no node, no material).
##
## * Blinks run at physics rate (close ~50 ms, hold ~30 ms, open ~100 ms) on a
##   log-normal personal clock with doubles/partials, plus motivated blinks on
##   big gaze shifts, landings, hits and completions.
## * Gaze is a world point held in the evaluated cube frame every tick (VOR):
##   the eyes stay on target while the body walks, turns, dances or greets.
##   Target changes are minimum-jerk saccades; fixations carry micro-saccades.
## * Expression channels (lids, tilt, wink, pupil, pop, smile, mouth) come from
##   real state (work strokes, load, danger, play, voices) plus short event
##   pulses, and are uploaded as the shared skin's instance uniforms only when
##   they change. A camera distance/visibility LOD keeps crowds cheap.
const Attention := preload("res://LogicObjects/Wako/wako_attention.gd")
const Voice := preload("res://LogicObjects/Wako/wako_personality_voice.gd")
const G_MAX := .02
const G_KNEE := .62
const STEP_LIMIT := .0031
const EYE_REST_POINT := Vector3(0.0, 1.175, -.197)
const EYE_SIDE := .213
const STROKE_KINDS := ["assemble","repair","inspect","tool_change","operate"]
const STRAIN_KINDS := ["unbend","maintenance","push","pull","brace"]
# Brain rates: quiet faces think at 10/8/4 Hz (near/mid/far or off-screen),
# a near face that acts, talks, startles or is alarmed at 20 Hz (the
# expression channels themselves settle smoothly at the upload rate).
const LOD_INTERVALS := [1.0/10.0, 1.0/8.0, 1.0/4.0]
const BUSY_INTERVAL := 1.0/20.0
# Gaze/settle/upload stride in physics ticks (60/30/15 Hz at 120 Hz).
const STRIDES := [2, 4, 8]
enum {UC, LR, TILT, WINK, DIL, POP, SMILE, MOPEN, MCURVE, MWIDTH, MSKEW, ALARM, STARTLE, CHANNELS}
# Event pulses: [attack, hold, release, uc, lr, tilt, wink, dil, pop, smile, open, curve, width, skew].
const PULSES := {
	&"surprise": [.045,.16,.45, -.32,-.05,0.0,0.0,-.8,1.0,0.0,.65,-.5,-.8,0.0],
	&"flinch": [.02,.04,.10, -.12,0.0,0.0,0.0,-.35,.35,0.0,.0,0.0,0.0,0.0],
	&"satisfied": [.08,.35,.45, 0.0,.12,0.0,0.0,.15,0.0,.42,.05,.45,.1,0.0],
	&"joy": [.10,.9,.6, 0.0,0.0,0.0,0.0,.45,0.0,.95,.38,.9,.3,0.0],
	&"pride": [.10,.5,.5, .1,.05,0.0,0.0,.2,0.0,.55,.05,.55,.1,0.0],
	&"curious": [.12,.55,.45, -.06,0.0,.2,.22,.3,.1,0.0,.05,-.35,-.1,.7],
	&"worry": [.20,1.0,.7, .08,.05,-.8,0.0,0.0,0.0,0.0,0.0,-.75,-.1,0.0],
	&"relief": [.25,.6,.9, .25,.1,0.0,0.0,.1,0.0,.45,.1,.35,0.0,0.0],
	&"notice": [.05,.22,.3, -.1,0.0,0.0,0.0,.3,.25,0.0,0.0,0.0,0.0,0.0],
	&"squeeze": [.03,.07,.22, .7,.45,.2,0.0,0.0,0.0,0.0,.05,-.4,.45,0.0],
}
## Harness/profiling switch: per-tick usec accounting (off in the game).
static var profiling := false
var worker: RigidBody3D
var gaze := Vector2.ZERO
var profile_ticks := 0
var profile_total_usec := 0
var profile_peak_usec := 0
var uploads := 0
var events := {"blink":0,"saccade":0,"pulse":0}
var _rng := RandomNumberGenerator.new()
var _time := 0.0
var _tick := 0
var _brain_wait := 0.0
var _brain_count := 0
var _brain_interval := 1.0/15.0
var _busy := false
var _choose_wait := 0.0
var _choose_elapsed := 0.0
var _gaze_debt := 0.0
var _lod := 0
var _eye_local := EYE_REST_POINT
var _rest_inverse := Basis.IDENTITY
# Personal traits.
var _blink_mean := 3.4
var _lid_rest := .12
var _pupil_rest := 0.0
var _skew_rest := 0.0
var _expressive := 1.0
var _side := 1.0
var _hippus_phase := 0.0
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
# Gaze.
var _want_point := Vector3.INF
var _want_node: WeakRef
var _want_offset := Vector3.ZERO
var _want_face := false
var _body_moving := true
var _body_turning := true
var _want_key := 0
var _track := Vector3.INF
var _desired := Vector2.ZERO
var _vergence := 0.0
var _sacc_t := -1.0
var _sacc_dur := .05
var _sacc_from := Vector2.ZERO
var _micro := Vector2.ZERO
var _micro_goal := Vector2.ZERO
var _micro_wait := .6
var _gaze_static := 0
var _swirl := 0.0
var _look_back_wait := 1.2
var _look_back_left := 0.0
var _cargo_glance_wait := 4.0
var _cargo_glance_left := 0.0
var _feature := Vector3.ZERO
var _feature_wait := .5
# Channels: target (brain) and current (settled toward the target).
var _target: Array[float] = []
var _value: Array[float] = []
var _settling := true
var _settle_debt := 0.0
var _dirty := true
var _channels_dirty := true
var _pulses: Array[Array] = []
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
# Event polling memory.
var _was_grounded := true
var _air_time := 0.0
var _last_reaction := 0.0
var _last_leap := ""
var _last_back := ""
var _last_play := ""
var _last_action := ""
var _last_job := ""
var _last_contact := false
var _alarm_age := 0.0
var _down := false
var _rest_relaxed := 0.0
var _rest_sleepy := 0.0
var _rest_age := 0.0
var _attention_serial := -1
var _up_y := 1.0
var _fast_turn := false
var _partner_ref: WeakRef

func setup(owner: RigidBody3D) -> void:
	worker = owner
	_rng.seed = absi(str(worker.worker_id).hash())+7439
	_blink_mean = _rng.randf_range(2.7,4.3)
	_lid_rest = _rng.randf_range(.08,.16)
	_pupil_rest = _rng.randf_range(-.05,.15)
	_skew_rest = _rng.randf_range(-.12,.12)
	_expressive = _rng.randf_range(.85,1.15)
	_side = 1.0 if _rng.randf()<.5 else -1.0
	_hippus_phase = _rng.randf()*TAU
	_blink_at = _rng.randf_range(.5,3.2)
	_brain_wait = _rng.randf()*_brain_interval
	_brain_count = _rng.randi_range(0,5)
	_target.resize(CHANNELS)
	_value.resize(CHANNELS)
	_target[UC] = _lid_rest
	_value[UC] = _lid_rest
	var skeleton: Skeleton3D = worker._skeleton
	if skeleton and skeleton.get_bone_count()>0:
		var rest := skeleton.get_bone_global_rest(0)
		_rest_inverse = rest.basis.orthonormalized().inverse()
		_eye_local = rest.affine_inverse()*EYE_REST_POINT
	if worker.has_signal(&"action_contact"): worker.action_contact.connect(_on_contact)

## Short event face (real trigger owned by the caller).
func pulse(kind: StringName, amount := 1.0, delay := 0.0) -> void:
	var preset: Array = PULSES.get(kind,[])
	if preset.is_empty() or amount<=0.0: return
	if _pulses.size()>=6: _pulses.pop_front()
	_pulses.append([preset,_time+delay,amount*_expressive])
	events.pulse += 1
	# Compose on the next tick so a 2-frame surprise is never late.
	_brain_wait = minf(_brain_wait,0.0)

## Rest mood for a seated/resting body (future sit state): relaxed 0..1, sleepy 0..1.
func set_rest(relaxed: float, sleepy := 0.0) -> void:
	_rest_relaxed = clampf(relaxed,0.0,1.0)
	_rest_sleepy = clampf(sleepy,0.0,1.0)

func blink_now(depth := 1.0, slow := false) -> void:
	if _blink_t>=0.0: return
	_start_blink(depth,slow)

func _on_contact(kind: String) -> void:
	# The helper admitted this real toe/tool contact: brief flinch, then a
	# satisfied glint; a hammer blow sometimes earns a squeeze blink.
	if kind in ["assemble","repair","unbend","maintenance"]:
		pulse(&"flinch",1.0)
		pulse(&"satisfied",.8,.07)
		if _rng.randf()<.4: _motivated_blink(1.0)
	elif kind in ["inspect","tool_change"]:
		pulse(&"satisfied",.55,.04)

func advance(delta: float) -> void:
	var began := Time.get_ticks_usec() if profiling else 0
	profile_ticks += 1
	_time += delta
	_tick += 1
	_brain_wait -= delta
	if _brain_wait<=0.0:
		var elapsed := _brain_interval-_brain_wait
		_brain_wait = maxf(_brain_wait+_brain_interval,0.0)
		_brain(elapsed)
	if _blink_t>=0.0 or _time>=_blink_at: _advance_blink(delta)
	# Gaze, settling and uploads run on a stride (60 Hz near, the renderer
	# never sees more); saccades and the dizzy swirl step every tick. A still
	# body watching a still target refreshes its VOR at half that rate.
	var stride: int = STRIDES[_lod]
	var saccading := _sacc_t>=0.0 or _down
	_gaze_debt += delta
	_settle_debt += delta
	var gaze_stride := stride if _body_turning else stride*2 if _gaze_static<=2 else stride*4
	if saccading or _tick%gaze_stride==0:
		_advance_gaze(_gaze_debt)
		_gaze_debt = 0.0
	if _tick%stride!=0:
		if profiling: profile_total_usec += Time.get_ticks_usec()-began
		return
	if _settling: _settle(_settle_debt)
	_settle_debt = 0.0
	if _dirty: _upload()
	if profiling:
		var spent := Time.get_ticks_usec()-began
		profile_total_usec += spent
		profile_peak_usec = maxi(profile_peak_usec,spent)

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
	if _blink_suppressed():
		_blink_at = _time+.08
		return
	var mean := _blink_mean*(1.3 if worker.fear_time>0.0 else 1.0)*(1.0+.8*_rest_sleepy)
	_blink_at = _time+clampf(exp(log(mean)-.1+.45*_rng.randfn()),.8,9.0)
	var roll := _rng.randf()
	_double_pending = roll<.12
	_start_blink(_rng.randf_range(.55,.75) if roll>.87 else 1.0,_rest_sleepy>.5)

func _blink_suppressed() -> bool:
	# Never blink into a strike contact or the startle beat of a real notice.
	if worker.action in STROKE_KINDS and worker.action_progress>.44 and worker.action_progress<.62: return true
	var watch: SkeletonModifier3D = worker.threat_watch
	return is_instance_valid(watch) and float(watch.notice_widen)>.15

func _motivated_blink(chance: float, depth := 1.0) -> void:
	if _blink_t>=0.0 or _time-_blink_started<.3 or _rng.randf()>chance or _blink_suppressed(): return
	_start_blink(depth,false)

# ---------------------------------------------------------------- gaze

func _eye_frame() -> Transform3D:
	var pose: SkeletonModifier3D = worker._pose
	var root: Transform3D
	if pose and pose.evaluated_valid and not _down:
		root = worker.global_transform*pose.evaluated_worker.affine_inverse()*pose.evaluated_root
	else:
		root = worker._skeleton.global_transform*worker._skeleton.get_bone_global_pose(0)
	return Transform3D(root.basis*_rest_inverse,root*_eye_local)

func _uv_toward(point: Vector3) -> Vector2:
	var frame := _eye_frame()
	_up_y = frame.basis.y.y
	var local: Vector3 = (point-frame.origin)*frame.basis
	var distance := local.length()
	if distance<.001: return _desired
	var yaw := atan2(local.x,-local.z)
	var pitch := atan2(local.y,Vector2(local.x,local.z).length())
	# Near targets converge both pupils (half the geometric vergence).
	_vergence = clampf(atan2(EYE_SIDE,maxf(distance,.15))*.5*G_MAX/G_KNEE*clampf(-local.z/distance*2.0,0.0,1.0),0.0,.007) if distance<3.0 else 0.0
	return Vector2(G_MAX*tanh(pitch/G_KNEE),-G_MAX*tanh(yaw/G_KNEE)).limit_length(.02)

func _advance_gaze(delta: float) -> void:
	if _down:
		# Dizzy swirl while the native ragdoll owns the body.
		_swirl += delta*7.0
		gaze = gaze.move_toward(Vector2(cos(_swirl),sin(_swirl*1.3))*.011,STEP_LIMIT)
		_dirty = true
		return
	var moving: bool = _sacc_t>=0.0
	if _want_node:
		var live: Node3D = _want_node.get_ref()
		if is_instance_valid(live) and live.is_inside_tree():
			var at: Vector3 = live.global_position
			if _want_face:
				var face: Vector3 = live._visual_head_point
				if face.is_finite(): at = face
			# Refixations: a watched actor gets small saccades between its
			# face, body and feet (mostly the face), like real looking.
			_feature_wait -= delta
			var hop := false
			if _feature_wait<=0.0 and _lod==0 and _sacc_t<0.0 and (_want_face or live==Global.Player):
				_feature_wait = _rng.randf_range(.3,.9)
				var roll := _rng.randf()
				var feature := Vector3.ZERO if roll<.55 else Vector3(_rng.randf_range(-.12,.12),-.35,0.0) if roll<.85 else Vector3(_rng.randf_range(-.15,.15),-.75,0.0)
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
	var desired := _uv_toward(_track) if _track.is_finite() else Vector2(-.003,0.0)
	if _sacc_t>=0.0:
		# A saccade launched in this very call (a refixation hop) starts its
		# flight next tick; owed stride time never fast-forwards it.
		if _sacc_t==0.0 and _gaze_debt==0.0 and delta>1.5/120.0: delta = 1.0/120.0
		_sacc_t += delta
		var s := clampf(_sacc_t/_sacc_dur,0.0,1.0)
		# Minimum-jerk path; a target that moves during the flight (a turning
		# body) can never push one tick beyond the continuity bound.
		gaze = gaze.move_toward(_sacc_from.lerp(desired,s*s*s*(10.0+s*(-15.0+6.0*s))),STEP_LIMIT*1.15*maxf(delta*120.0,1.0))
		if s>=1.0: _sacc_t = -1.0
	elif desired.distance_to(_desired)>.0035 or gaze.distance_to(desired)>.0045:
		# A jump that pursuit/VOR cannot follow (teleported target, wrap
		# behind the body) becomes a catch-up saccade, never a pop.
		_start_saccade(desired)
	else:
		_micro_wait -= delta
		if _micro_wait<=0.0 and _lod==0:
			_micro_wait = _rng.randf_range(.35,1.1)
			_micro_goal = Vector2(_rng.randf_range(-1.0,1.0),_rng.randf_range(-1.0,1.0)).normalized()*_rng.randf_range(.0003,.0008)
		_micro = _micro.move_toward(_micro_goal,delta*.03)
		_micro_goal = _micro_goal.move_toward(Vector2.ZERO,delta*.0015)
		# Fixation (VOR + pursuit + micro-saccades), bounded per update so a
		# fast body turn never pops the pupil.
		gaze = gaze.move_toward((desired+_micro).limit_length(.021),STEP_LIMIT*1.15)
	_desired = desired
	if gaze.distance_squared_to(_sent_gaze)>.000000015: _dirty = true

func _start_saccade(to_uv: Vector2) -> void:
	var amplitude := to_uv.distance_to(gaze)
	if amplitude<.0006: return
	var degrees := amplitude/(G_MAX/G_KNEE)*57.3
	_sacc_dur = maxf(clampf(.021+.0022*degrees,.03,.11),1.875*amplitude/(STEP_LIMIT*120.0))
	_sacc_from = gaze
	_sacc_t = 0.0
	# Time owed to a skipped stride must not fast-forward the new saccade.
	_gaze_debt = 0.0
	_micro = Vector2.ZERO
	_micro_goal = Vector2.ZERO
	_gaze_static = 0
	events.saccade += 1
	# Big gaze shifts often carry a blink (gaze-evoked blink).
	if degrees>22.0: _motivated_blink(.5)

func _look_at(point: Vector3, key: int, follow: Node3D = null, offset := Vector3.ZERO) -> void:
	if key==_want_key:
		if not follow: _want_point = point
		return
	_want_key = key
	_want_point = point
	_want_node = weakref(follow) if follow else null
	_want_offset = offset
	_want_face = false
	if follow:
		var face: Variant = follow.get("_visual_head_point")
		_want_face = face is Vector3
		_track = (face if face is Vector3 and face.is_finite() else follow.global_position)+offset
	else:
		_track = point
	if _track.is_finite() and not _down: _start_saccade(_uv_toward(_track))
	_gaze_static = 0

# ---------------------------------------------------------------- brain

func _brain(elapsed: float) -> void:
	# Staggered sub-steps: events and expression every brain tick, gaze
	# choice every other, LOD every fourth (all on a personal phase).
	_brain_count += 1
	if _brain_count%4==0: _update_lod()
	_poll_events(elapsed)
	_choose_wait -= elapsed
	if _choose_wait<=0.0 or _lod>0 or _want_key==0:
		_choose_gaze(_choose_elapsed+elapsed)
		_choose_elapsed = 0.0
		_choose_wait = .1
	else:
		_choose_elapsed += elapsed
	_compose()
	_brain_interval = BUSY_INTERVAL if _busy and _lod==0 else LOD_INTERVALS[_lod]

func _update_lod() -> void:
	var camera: Camera3D = worker.get_viewport().get_camera_3d() if worker.is_inside_tree() else null
	var lod := 0
	if camera:
		var head: Vector3 = worker.global_position+Vector3.UP*.3
		var distance := camera.global_position.distance_to(head)
		lod = 0 if distance<9.0 else 1 if distance<22.0 else 2
		if lod<2 and not camera.is_position_in_frustum(head): lod = 2
	_lod = lod

func _poll_events(elapsed: float) -> void:
	# The VOR refresh rate follows real body motion (sampled at brain rate).
	var play_node: RefCounted = worker.idle_play
	var turn: float = absf(worker.turn_rate)
	var dancing: bool = play_node and (play_node.dance_weight>.001 or play_node.crouch_weight>.001)
	_body_turning = turn>.6 or dancing or not worker.on_ground
	_body_moving = _body_turning or turn>.02 or worker.linear_velocity.length_squared()>.0025 or not worker.action.is_empty() or _sacc_t>=0.0
	# Hits, stumbles and native impacts raise the helper's reaction clock.
	var reaction: float = worker._reaction
	if reaction>_last_reaction+.08:
		pulse(&"surprise",clampf(reaction*1.4,.5,1.0))
		_motivated_blink(.7,1.0)
		Attention.post(worker,&"hit",worker.global_position+Vector3.UP*.4,.7,1.4)
	_last_reaction = reaction
	var down: bool = not worker.is_available()
	if down!=_down:
		if down:
			pulse(&"surprise",1.0)
			Attention.post(worker,&"fall",worker.global_position,.75,2.0,worker)
		else:
			_start_blink(1.0,true)
			pulse(&"relief",.5,.2)
		_down = down
		_want_key = 0
	# Landings after real flight.
	var grounded: bool = worker.on_ground
	if not grounded: _air_time += elapsed
	elif not _was_grounded:
		if _air_time>.22:
			pulse(&"squeeze",clampf(_air_time*1.3,.35,.9))
			_motivated_blink(.75)
			Attention.post(worker,&"landing",worker.global_position,.45,1.2)
			if _air_time>.5 and worker.cargo_mass>0.0: pulse(&"pride",.7,.25)
		_air_time = 0.0
	_was_grounded = grounded
	# A big, fast body turn carries a blink (eyes reset during the turn).
	var fast_turn: bool = absf(worker.turn_rate)>2.5
	if fast_turn and not _fast_turn: _motivated_blink(.55)
	_fast_turn = fast_turn
	# Head-first flips.
	var leap_node: RefCounted = worker.head_leap
	var leap: String = leap_node.state if leap_node else ""
	if leap!=_last_leap:
		if leap=="prepare":
			pulse(&"notice",1.0)
			Attention.post(worker,&"flip",worker.global_position,.65,2.6,worker)
		elif leap=="contact": pulse(&"squeeze",.5)
		_last_leap = leap
	# Back-tool toss and its caught return.
	var back_node: RefCounted = worker.back_tool
	var back: String = back_node.phase if back_node else ""
	if back!=_last_back:
		if back=="flight":
			Attention.post(worker,&"toss",worker.global_position+Vector3.UP,.6,1.5,worker.equipped_tool if is_instance_valid(worker.equipped_tool) else null)
		elif _last_back=="flight" and back=="back":
			pulse(&"pride",.8)
			_motivated_blink(.6)
			Attention.post(worker,&"catch",worker.global_position+Vector3.UP*.5,.55,1.2)
		_last_back = back
	# Idle play beats other Wako may enjoy watching.
	var play: RefCounted = worker.idle_play
	if play:
		var state: String = play.state
		if state!=_last_play:
			if state=="dance": Attention.post(worker,&"dance",worker.global_position,.45,maxf(float(play.state_duration),1.5),worker)
			elif state=="gather" and not play._water_active: Attention.post(worker,&"hop",worker.global_position,.4,1.4,worker)
			elif state=="water_excited": pulse(&"joy",.8)
			elif state=="water_swim":
				Attention.post(worker,&"splash",worker.global_position,.75,2.0,worker)
				pulse(&"surprise",.6)
			_last_play = state
		var contact: bool = not play._pair.is_empty() and bool(play._pair.get("contact",false))
		if contact and not _last_contact: Attention.post(worker,&"highfive",worker.global_position+Vector3.UP*.3,.6,1.4)
		_last_contact = contact
	# Useful work: a fresh reservation is noticed before the body departs;
	# an interruption worries; completion is handled by the personality.
	var job: String = worker.current_job_id
	if job!=_last_job:
		if not job.is_empty(): pulse(&"notice",1.0)
		_last_job = job
		_want_key = 0
	var action: String = worker.action
	if action!=_last_action:
		if action=="interrupted": pulse(&"worry",.7)
		_last_action = action
	var personality: RefCounted = worker.personality
	if not personality: return
	# Relief once a real danger alert releases.
	if float(personality.alert_weight)>.5 or worker.fear_time>0.0: _alarm_age += elapsed
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

func _rest_amount() -> float:
	var play: RefCounted = worker.idle_play
	if play and play.state.begins_with("sit"): return 1.0
	return _rest_relaxed

func _work_focus() -> bool:
	return worker.action in STROKE_KINDS and is_instance_valid(worker.work_target) and worker.on_ground and worker.fear_time<=0.0 and not _down

func _choose_gaze(elapsed: float) -> void:
	if _down:
		_want_key = -1
		return
	var personality: RefCounted = worker.personality
	var action: String = worker.action
	var job: String = worker.current_job_id
	var alert := float(personality.alert_weight) if personality else 0.0
	# 1. A real live hostile (seen, or heard from a peer). A working Wako
	# glances during the notice beat; fear keeps watching while escaping.
	if alert>.05:
		var core: Node3D = personality._actual_threat()
		var working: bool = not job.is_empty() or not action in ["","danger"] or is_instance_valid(worker.station)
		var watch: SkeletonModifier3D = worker.threat_watch
		if is_instance_valid(core) and (not working or worker.fear_time>0.0 or is_instance_valid(watch) and float(watch._notice_age)<.9):
			var caller: Node3D = personality.heard_caller.get_ref() if personality.heard_caller else null
			if is_instance_valid(caller) and float(personality.heard_age)<.32 and caller!=worker:
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
			_look_at(Vector3.INF,core.get_instance_id(),core)
			return
	# 2. Foot-held gun: the real aim target, never the gun node itself.
	var gun: Node3D = worker.portable_gun
	if gun and (is_instance_valid(worker.equipped_gun) or worker.work_target==gun):
		var aim: Vector3 = gun.desired_target
		if aim.is_finite(): _look_at(aim,_point_key(aim,11))
		else: _look_at(worker.global_position-worker._model.global_basis.z*4.0+Vector3.UP*.5,12)
		return
	# 3. Thrown tool in the air; part during a flip.
	var back: RefCounted = worker.back_tool
	if back and back.phase=="flight" and is_instance_valid(worker.equipped_tool):
		_look_at(Vector3.INF,worker.equipped_tool.get_instance_id(),worker.equipped_tool)
		return
	var leap: RefCounted = worker.head_leap
	if leap and leap.active() and is_instance_valid(leap.part) and not leap.contacted:
		_look_at(Vector3.INF,leap.part.get_instance_id(),leap.part)
		return
	# 4. Useful work: the real contact point, then the coordinator's phase
	# hint (stock, tool, destination or the next lease), then travel.
	if _work_focus():
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
	# 5. Play: water, partner, the greeted player.
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
	# 6. Free attention (attention board / player / personal scan points);
	# a Wako walking somewhere mostly watches where it is going.
	var attention: RefCounted = personality.attention if personality else null
	if worker.has_target and worker.gait_speed>.35 and (not attention or float(attention.strength)<.45) \
		and (worker.target_position-worker.global_position).slide(Vector3.UP).length_squared()>.64:
		_look_at(worker.target_position+Vector3.UP*.5,_point_key(worker.target_position,31))
		return
	if attention and attention.point.is_finite():
		var follow: Node3D = attention.node.get_ref() if attention.node else null
		if is_instance_valid(follow) and follow!=worker:
			_look_at(Vector3.INF,follow.get_instance_id(),follow,Vector3.UP*.6 if follow==Global.Player else Vector3.ZERO)
		else:
			_look_at(attention.point,1000003+int(attention.serial))
		return
	_look_at(Vector3.INF,1)

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
	var uc := _lid_rest-.05*smoothstep(.4,.8,attention_strength)
	var lr := 0.0
	var tilt := 0.0
	var wink := 0.0
	var dil := _pupil_rest+.05*sin(_time*TAU*.23+_hippus_phase)
	var pop := 0.0
	var smile := 0.0
	var mopen := 0.0
	var mcurve := 0.0
	var mwidth := 0.0
	var mskew := _skew_rest
	var alarm := 0.0
	var startle := 0.0
	if _down:
		var wobble := sin(_time*5.0)
		uc = .5; lr = .3; tilt = -.5; mopen = .35; mwidth = -.5; mskew = .6*wobble; mcurve = -.4
	else:
		var action: String = worker.action
		var progress: float = worker.action_progress
		var gait: float = worker.gait_speed
		if gait>2.2 and worker.fear_time<=0.0: uc -= .05
		# Effort: draw (determined squint) -> strike near the .56 contact
		# (squeeze, gritted mouth) -> the admitted contact pulses take over.
		if not action.is_empty():
			if _work_focus():
				if action=="assemble" or action=="repair":
					var draw := smoothstep(.10,.30,progress)*(1.0-smoothstep(.48,.55,progress))
					var strike := smoothstep(.49,.55,progress)*(1.0-smoothstep(.60,.72,progress))
					uc += .38*draw+.6*strike
					lr += .36*draw+.48*strike
					tilt += .35*draw+.22*strike
					mcurve -= .35*draw+.5*strike
					mwidth += .3*draw+.55*strike
					mopen += .1*strike
				elif action=="inspect":
					uc -= .05; dil += .3; tilt += .12; mskew += .35*_side; mcurve -= .2
				else:
					uc += .15; tilt += .3; mcurve -= .15
			elif action in STRAIN_KINDS:
				var strain := smoothstep(.12,.3,progress)*(1.0-smoothstep(.82,.97,progress))
				uc += .38*strain; lr += .26*strain; tilt += .6*strain; mcurve -= .45*strain; mwidth += .5*strain
			elif action=="place":
				uc += .08; mcurve += .1
			elif action=="interrupted":
				tilt -= .4; mcurve -= .4
		elif not worker.needs.is_empty():
			tilt -= .3; mcurve -= .3
		# Load: a heavy head cargo shows in the lids and a tight mouth.
		var load := clampf(worker.cargo_mass/30.0,0.0,1.0)
		if load>0.0:
			uc += .12*load; lr += .06*load; tilt += .15*load; mwidth += .15*load; mcurve -= .15*load
		var play: RefCounted = worker.idle_play
		# Airborne play/stunts: eyes wide, little "wee" mouth.
		if _air_time>.12:
			pop += .4; uc -= .15; mopen += .3; mwidth -= .35
			if play and play.state in ["flight","landing","water_flight","water_exit_flight"]: smile += .3
		# Danger: alarm preset (worried lids, frown) and constricted pupils.
		if worker.fear_time>0.0 and worker.on_ground and not worker.paused: alarm = 1.0
		elif personality and (worker.current_job_id.is_empty() and action in ["","danger"]): alarm = float(personality.alert_weight)
		dil -= .35*alarm
		# Real notice: widen first (pop, pinpoint pupils, gasp), then a
		# focused worried look while the warning plays.
		var watch: SkeletonModifier3D = worker.threat_watch
		if is_instance_valid(watch):
			var widen := float(watch.notice_widen)
			var focus := float(watch.notice_focus)
			if widen>0.0 or focus>0.0:
				uc += -.34*widen+.2*focus
				lr += .14*focus
				pop += .9*widen
				dil += -.75*widen-.35*focus
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
			elif _partner_ref and _partner_ref.get_ref(): social = maxf(social,.35)
		smile += social
		mcurve += .6*social
		if personality: mopen += .22*social*float(personality.greeting_weight)
		dil += .3*social
		# Resting (sit API or a future idle "sit*" state): relaxed lids,
		# sleepy after a while unless something interesting is watched.
		var rest := _rest_amount()
		if rest>0.0:
			var sleepy := maxf(_rest_sleepy,smoothstep(15.0,25.0,_rest_age)*.6)*(1.0-attention_strength)
			uc = lerpf(uc,maxf(uc,.2+.3*sleepy),rest)
			lr += .1*rest; tilt -= .15*sleepy; mcurve += .15*rest; dil += .2*sleepy
		# Gun aim: a determined one-eye aiming squint.
		var gun: Node3D = worker.portable_gun
		if gun and is_instance_valid(worker.equipped_gun) and gun.desired_target.is_finite():
			wink += .45*_side; uc += .2; tilt += .35; mcurve -= .2; mskew += .4*_side
		# Voice: the jaw follows the real clip's syllables.
		if personality and float(personality.voice_clock)>=0.0:
			var notes: Array = personality.voice_notes
			if not notes.is_empty():
				var open := Voice.mouth_open(notes,float(personality.voice_clock))
				var kind: String = personality.voice_kind
				var shape := _voice_shape(kind)
				var shaped := minf(open*3.0,1.0)
				mopen = maxf(mopen,open*shape.x)
				mcurve += shape.y*shaped
				mwidth += shape.z*shaped
				if kind=="play" or kind=="yay" or kind=="giggle": smile = maxf(smile,.35)
	# Upside down (flips, upside-down play) a smile would read as a frown:
	# show happy arcs and a small round "o" instead.
	if _up_y<-.3:
		var inverted := smoothstep(-.3,-.7,_up_y)
		mcurve = lerpf(mcurve,0.0,inverted)
		mopen = maxf(mopen,.3*inverted)
		mwidth = lerpf(mwidth,-.6,inverted)
		smile = maxf(smile,.55*inverted)
	var t := _target
	t[UC] = uc; t[LR] = lr; t[TILT] = tilt; t[WINK] = wink; t[DIL] = dil; t[POP] = pop; t[SMILE] = smile
	t[MOPEN] = mopen; t[MCURVE] = mcurve; t[MWIDTH] = mwidth; t[MSKEW] = mskew; t[ALARM] = alarm; t[STARTLE] = startle
	_busy = _down or alarm>0.0 or startle>0.0 or mopen>0.0 or not worker.action.is_empty() or not _pulses.is_empty() or _air_time>0.0
	if not _pulses.is_empty(): _apply_pulses()
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
	if not _settling:
		for channel in CHANNELS:
			if absf(_value[channel]-t[channel])>.002:
				_settling = true
				break

func _voice_shape(kind: String) -> Vector3:
	# (open gain, curve, width) per call: warning shouts, play beams,
	# effort grits, hums stay small and lopsided.
	match kind:
		"warning": return Vector3(1.0,-.6,-.4)
		"play","yay","giggle","wee": return Vector3(.85,.6,.2)
		"effort","grunt","nngh": return Vector3(.5,-.4,.5)
		"inspect","hmm","huh": return Vector3(.38,-.1,-.3)
		"jump","hup","hop": return Vector3(.8,0.0,-.5)
		"oops": return Vector3(.8,-.35,-.6)
		"sigh": return Vector3(.4,.1,-.1)
	return Vector3(.65,.1,0.0)

func _apply_pulses() -> void:
	var t := _target
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
		if age<0.0: continue
		var weight := float(entry[2])*(smoothstep(0.0,attack,age) if age<attack else 1.0 if age<attack+hold else 1.0-smoothstep(attack+hold,attack+hold+release,age))
		for channel in 11: t[channel] += float(preset[3+channel])*weight

func _settle(delta: float) -> void:
	# Exponential approach per channel: fast enough for a 2-frame surprise,
	# never a pop. Alarm rises fast and releases slowly.
	var settled := true
	var fast := 1.0-exp(-30.0*delta)
	for channel in CHANNELS:
		var target := _target[channel]
		var value := _value[channel]
		if value==target: continue
		var rate := fast
		if channel==ALARM: rate = 1.0-exp(-(18.0 if target>value else 5.0)*delta)
		elif channel==MOPEN: rate = 1.0-exp(-40.0*delta)
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
	# reactive for TAA while (and only while) the face changes.
	var reactive := 1.0 if changed else 0.0
	if reactive!=_sent_reactive:
		_sent_reactive = reactive
		mesh.set_instance_shader_parameter(&"eye_reactivity",reactive)
	if changed:
		uploads += 1
		_dirty = true

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
	var iris := Vector4(v[DIL],_vergence,v[POP],0.0)
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

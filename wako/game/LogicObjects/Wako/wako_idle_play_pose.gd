extends SkeletonModifier3D
## An authored squat, proud snap, cheeky bow and double nod.
## The original final terrain-foot IK still owns both soles.
## It is presentation only: the original spring-foot capsule supplies support.
static var _shared_curve: Animation
static var _shared_dance_curve: Animation
static var _shared_carrying_dance_curve: Animation
var _dance_clock := 0.0
var _solo_dance_tail := false
var _carrying_solo_tail := false
var director: RefCounted
var applied_weight := 0.0
var _clock := 0.0
var _dance := 0.0
var _crouch := 0.0
var _dive := 0.0
var _swim := 0.0
var _water_notice := 0.0
var _water_notice_clock := 0.0
var _water_notice_tail := false

# Squat / proud snap / opposite bow / double nod, with distinct silhouettes.
# Brief anticipation, quick
# accents, distinct holds, overshoot and a longer ease-out settle precede
# the original terrain-foot solve. No scale, native force or foot target is
# changed. Timing/spacing and overlap references:
# https://www.animationmentor.com/blog/slow-in-and-slow-out-the-12-basic-principles-of-animation/
# https://www.animationmentor.com/blog/anticipation-the-12-basic-principles-of-animation/
# https://www.animationmentor.com/blog/follow-through-and-overlapping-action-the-12-basic-principles-of-animation/
const DANCE_SECONDS := 1.80
# Whole wide cutters need a higher, shallower forward bow. Keep the same
# brisk accents, yaw and full sideways snap instead of relying on the
# original clearance admission to clip a bare pose into a timid shuffle.
const CARRYING_DANCE_SHIFT_SCALE := Vector3(1,.80,.90)
const CARRYING_DANCE_TURN_SCALE := Vector3(.62,1,1)
const DANCE_POSES := [
	[0.00, Vector3.ZERO, Vector3.ZERO],
	[.12, Vector3(-.025,-.040,.020), Vector3(.085,-.050,.045)],
	[.24, Vector3(-.050,-.115,.035), Vector3(.225,-.180,.160)],
	[.34, Vector3(.055,-.105,-.005), Vector3(-.210,.350,-.420)],
	[.42, Vector3(.070,-.105,-.018), Vector3(-.200,.380,-.440)],
	[.53, Vector3(.060,-.105,-.013), Vector3(-.160,.350,-.400)],
	[.61, Vector3(0,-.065,.018), Vector3(.060,.020,-.025)],
	[.73, Vector3(-.070,-.120,.055), Vector3(.340,-.330,.360)],
	[.80, Vector3(-.077,-.120,.060), Vector3(.370,-.360,.400)],
	[.91, Vector3(-.060,-.110,.045), Vector3(.270,-.280,.300)],
	[1.00, Vector3(0,-.105,.027), Vector3(.320,.055,.035)],
	[1.09, Vector3(0,-.070,-.020), Vector3(-.220,.100,-.035)],
	[1.18, Vector3(0,-.120,.038), Vector3(.400,-.030,.020)],
	[1.28, Vector3(.012,-.050,-.014), Vector3(-.200,.040,-.025)],
	[1.40, Vector3(.014,-.035,.005), Vector3(.045,-.015,.015)],
	[1.64, Vector3.ZERO, Vector3.ZERO],
	[1.80, Vector3.ZERO, Vector3.ZERO],
]

static func dance_pose(time: float, track: int, carrying := false) -> Vector3:
	var clock := clampf(time,0.0,DANCE_SECONDS)
	for key in range(1,DANCE_POSES.size()):
		var end: Array = DANCE_POSES[key]
		if clock>float(end[0]): continue
		var begin: Array = DANCE_POSES[key-1]
		var t := (clock-float(begin[0]))/maxf(float(end[0])-float(begin[0]),.0001)
		# The authored intervals carry the rhythm. Fast accents front-load
		# their travel then ease out for longer; preparation and recovery
		# use the quieter quintic. Both keep zero velocity/acceleration at
		# a hold, so the style does not depend on a one-frame pose jump.
		var spacing := t*t*t*(t*(t*6.0-15.0)+10.0)
		if key in [3,7,11,13]:
			spacing = t*t*t*(56.0+t*(-210.0+t*(336.0+t*(-280.0+t*(120.0-21.0*t)))))
		var result := Vector3(begin[track+1]).lerp(Vector3(end[track+1]),spacing)
		if carrying: result *= CARRYING_DANCE_SHIFT_SCALE if track==0 else CARRYING_DANCE_TURN_SCALE
		return result
	return Vector3.ZERO

func _prepare_dance_curve() -> void:
	if _shared_dance_curve: return
	for carrying: bool in [false,true]:
		var curve := Animation.new()
		curve.length = DANCE_SECONDS
		curve.loop_mode = Animation.LOOP_LINEAR
		for name: String in ["shift","turn"]:
			var track := curve.add_track(Animation.TYPE_VALUE)
			curve.track_set_path(track,NodePath(name))
			curve.track_set_interpolation_type(track,Animation.INTERPOLATION_LINEAR)
		# Both variants keep identical native-rate timing and turn overlap.
		for tick in range(roundi(DANCE_SECONDS*120.0)+1):
			var time := tick/120.0
			curve.track_insert_key(0,time,dance_pose(time,0,carrying))
			curve.track_insert_key(1,time,dance_pose(maxf(time-.035,0.0),1,carrying))
		if carrying: _shared_carrying_dance_curve = curve
		else: _shared_dance_curve = curve

# One admitted-water notice: a small counter-gather, brisk proud snap,
# one overshoot and a slower settle. The cube turns 25 ms after the gather;
# final terrain IK and the existing supported/full-tool admission own contact.
const WATER_NOTICE_SECONDS := .52
const WATER_NOTICE_POSES := [
	[0.00, Vector3.ZERO, Vector3.ZERO],
	[.07, Vector3(-.016,-.035,.014), Vector3(.080,-.045,.050)],
	[.13, Vector3(-.020,-.085,.024), Vector3(.150,-.110,.140)],
	[.23, Vector3(.018,-.065,-.012), Vector3(-.200,.180,-.220)],
	[.29, Vector3(.012,-.070,-.006), Vector3(-.150,.145,-.165)],
	[.35, Vector3(-.008,-.040,.009), Vector3(.080,-.055,.065)],
	[.43, Vector3(.002,-.016,.002), Vector3(-.020,.025,-.018)],
	[.52, Vector3.ZERO, Vector3.ZERO],
]

static func water_notice_pose(time: float, track: int) -> Vector3:
	var clock := clampf(time,0.0,WATER_NOTICE_SECONDS)
	for key in range(1,WATER_NOTICE_POSES.size()):
		var end: Array = WATER_NOTICE_POSES[key]
		if clock>float(end[0]): continue
		var begin: Array = WATER_NOTICE_POSES[key-1]
		var t := (clock-float(begin[0]))/maxf(float(end[0])-float(begin[0]),.0001)
		var spacing := t*t*t*(t*(t*6.0-15.0)+10.0)
		if key==3:
			spacing = t*t*t*(56.0+t*(-210.0+t*(336.0+t*(-280.0+t*(120.0-21.0*t)))))
		return Vector3(begin[track+1]).lerp(Vector3(end[track+1]),spacing)
	return Vector3.ZERO

func _ready() -> void:
	_prepare_dance_curve()
	if _shared_curve: return
	_shared_curve = Animation.new()
	_shared_curve.length = 1.44
	_shared_curve.loop_mode = Animation.LOOP_LINEAR
	var shift := _shared_curve.add_track(Animation.TYPE_VALUE)
	_shared_curve.track_set_path(shift,NodePath("shift"))
	_shared_curve.track_set_interpolation_type(shift,Animation.INTERPOLATION_CUBIC)
	var turn := _shared_curve.add_track(Animation.TYPE_VALUE)
	_shared_curve.track_set_path(turn,NodePath("turn"))
	_shared_curve.track_set_interpolation_type(turn,Animation.INTERPOLATION_CUBIC)
	for key: Array in [[0.0,Vector3.ZERO,Vector3.ZERO],
		[.18,Vector3(.024,-.012,0),Vector3(.022,.035,-.065)],
		[.36,Vector3(0,-.004,0),Vector3(0,.05,0)],
		[.54,Vector3(-.024,-.012,0),Vector3(-.022,.035,.065)],
		[.72,Vector3.ZERO,Vector3.ZERO],
		[.9,Vector3(.024,-.012,0),Vector3(-.022,-.035,-.065)],
		[1.08,Vector3(0,-.004,0),Vector3(0,-.05,0)],
		[1.26,Vector3(-.024,-.012,0),Vector3(.022,-.035,.065)],
		[1.44,Vector3.ZERO,Vector3.ZERO]]:
		_shared_curve.track_insert_key(shift,float(key[0]),key[1])
		_shared_curve.track_insert_key(turn,float(key[0]),key[2])

func _process_modification_with_delta(delta: float) -> void:
	if not director or not is_instance_valid(director.worker) or not _shared_curve: return
	var worker: RigidBody3D = director.worker
	if not worker.is_available() or (worker.ragdoll and worker.ragdoll.pending):
		_dance = 0.0
		_solo_dance_tail = false
		_carrying_solo_tail = false
		_crouch = 0.0
		_dive = 0.0
		_swim = 0.0
		_water_notice = 0.0
		_water_notice_tail = false
		applied_weight = 0.0
		return
	_clock = fposmod(_clock+delta*float(director.playfulness),_shared_curve.length)
	var noticing: bool = director.state=="water_excited" and director._water_active and not director._water_interrupted
	# Notice starts only after the original finite turn regained both plants.
	# On interruption its presentation fades while original useful work owns
	# the same body, tool custody and final foot solves.
	if noticing:
		_water_notice_clock = minf(float(director.state_age),WATER_NOTICE_SECONDS)
		_water_notice_tail = true
	elif _water_notice_tail:
		_water_notice_clock = minf(_water_notice_clock+delta,WATER_NOTICE_SECONDS)
	_water_notice = move_toward(_water_notice,1.0 if noticing and worker.on_ground else 0.0,delta*12.0)
	if _water_notice<=.001 and not noticing: _water_notice_tail = false
	_dance = move_toward(_dance,float(director.dance_weight) if worker.on_ground and not noticing else 0.0,delta*4.5)
	_crouch = move_toward(_crouch,float(director.crouch_weight),delta*4.5)
	_dive = move_toward(_dive,float(director.water_dive_weight),delta*3.5)
	_swim = move_toward(_swim,float(director.water_swim_weight),delta*3.5)
	if director.state!="dance" and _dance<=.001: _solo_dance_tail = false
	applied_weight = maxf(_water_notice,maxf(_dance,maxf(_dive,_swim)))
	if _dance<=.001 and _crouch<=.001 and _dive<=.001 and _swim<=.001 and _water_notice<=.001: return
	var sk := get_skeleton()
	var root := sk.get_bone_global_pose(0)
	# Begin a new spontaneous dance at its own anticipation pose, even
	# after a long idle interval. Water keeps its existing free-running clock.
	if director.state=="dance":
		# Choose from actual seated custody once. Retain that variant through
		# the ordinary interruption fade, even if work begins retrieving it.
		if not _solo_dance_tail:
			_carrying_solo_tail = is_instance_valid(worker.equipped_tool) and worker.back_tool and worker.back_tool.phase=="back" and worker.equipped_tool.carrier==worker.back_tool.back_anchor and not worker.tool_foot_occupied()
		_dance_clock = fposmod(float(director.state_age)*float(director.playfulness),DANCE_SECONDS)
		_solo_dance_tail = true
	elif _solo_dance_tail:
		_dance_clock = fposmod(_dance_clock+delta*float(director.playfulness),DANCE_SECONDS)
		if _dance<=.001: _solo_dance_tail = false
	var curve: Animation = _shared_dance_curve if _solo_dance_tail else _shared_curve
	if _solo_dance_tail and _carrying_solo_tail: curve = _shared_carrying_dance_curve
	var clock := _dance_clock if _solo_dance_tail else _clock
	var shift: Vector3 = curve.value_track_interpolate(0,clock)
	var turn: Vector3 = curve.value_track_interpolate(1,clock)
	root.origin += shift*_dance-Vector3.UP*(.046*_crouch)
	root.basis = Basis.from_euler(turn*_dance)*root.basis
	if _water_notice_tail:
		root.origin += water_notice_pose(_water_notice_clock,0)*_water_notice
		root.basis = Basis.from_euler(water_notice_pose(maxf(_water_notice_clock-.025,0.0),1)*_water_notice)*root.basis
	# Feet and the original head/cube pitch into the real native water entry.
	# This authored blend supplies no force or water/support observation.
	root.basis = Basis(Vector3.RIGHT,-1.02*_dive+.055*sin(_clock*TAU)*_swim)*root.basis
	sk.set_bone_global_pose(0,root)
	for side in 2:
		var chain: Array = worker._pose._chains[side]
		var hip: int = chain[0]
		var knee: int = chain[1]
		var phase := _clock*TAU*1.35+PI*side
		var stroke := sin(phase)*.24*_swim
		var tuck := .32*_dive+.22*(.5+.5*cos(phase))*_swim
		var hip_rotation := sk.get_bone_pose_rotation(hip)
		var knee_rotation := sk.get_bone_pose_rotation(knee)
		sk.set_bone_pose_rotation(hip,hip_rotation*Quaternion(Vector3.RIGHT,stroke))
		sk.set_bone_pose_rotation(knee,knee_rotation*Quaternion(Vector3.LEFT,tuck))
	if not worker.on_ground and (_dive>.001 or _swim>.001):
		worker._update_head(sk.global_transform*sk.get_bone_global_pose(0))

extends RefCounted
const GunControl := preload("res://Components/Contraptions/gun_control_point.gd")
## Small spontaneous expressions on the ordinary helper. The real scheduler
## keeps all leases, cargo, supported interruption and finite walking forces.
const Voice := preload("res://LogicObjects/Wako/wako_personality_voice.gd")
const Attention := preload("res://LogicObjects/Wako/wako_attention.gd")
const NOTICE_RADIUS := 15.0
const DANGER_RADIUS := 11.0
static var _warning_until: Dictionary = {}
# Only recent audible calls are retained, not a registry scanned per tick.
static var _work_call_history: Array[Dictionary] = []
# Smiles currently shown in each scene tree (instance id -> game time until
# the smile and its release end): a crowd never beams all at once.
static var _smiling: Dictionary = {}
var worker: RigidBody3D
var smile_weight := 0.0
var greeting_weight := 0.0
var greeting_age := 1.0
var look_position := Vector3.INF
var alert_weight := 0.0
var alert_position := Vector3.INF
var personality_pitch := 1.0
var events := {"smile":0,"warning":0,"work_contact":0,"work_voice":0,"work_voice_cancel":0,"work_complete_voice":0,"water_voice":0,"water_voice_cancel":0,"cover":0,"event_voice":0,"heard_warning":0,"attention_turn":0}
var profile_ticks := 0
var profile_total_usec := 0
var profile_peak_usec := 0
var _rng := RandomNumberGenerator.new()
# Audio choices cannot consume the observation, smile or idle motion clocks.
var _voice_rng := RandomNumberGenerator.new()
var _last_voice_streams: Dictionary = {}
var _voice_kind := ""
var _work_voice_action := ""
var _work_voice_completed := false
var _water_voice_phase := ""
var _work_voice_job := ""
var _work_voice_target_id := 0
var _work_voice_volume := -19.0
var _work_voice_fade := -1.0
var _clock := 0.0
var _scan_remaining := 0.0
var _next_smile := 0.0
var _smile_remaining := 0.0
var _greeting_active := false
var _greeting_pending := false
var _work_voice_remaining := 0.0
var _cover_retry := 0.0
var _cover_point := Vector3.INF
var _cover_until := 0.0
var _cover_source: WeakRef
var _retreat_core: WeakRef
var _retreat_candidates: Array[Vector3] = []
var _route_goal := Vector3.INF
var _route_from := Vector3.INF
var _route_last := Vector3.INF
var _route_steps := 0
var _route_step := 0
var _threat: WeakRef
var _seen_player: WeakRef
var _voice: AudioStreamPlayer3D
var _ray := PhysicsRayQueryParameters3D.new()
var _clearance := PhysicsShapeQueryParameters3D.new()
# Attention chooser, heard-danger memory and the voice clock the eyes read
# for mouth sync (stream time of the playing clip, -1 when silent).
var attention: RefCounted
var heard_caller: WeakRef
## The revalidated live hostile core this tick (or null), for the face.
var live_threat: Node3D
var heard_age := 10.0
var voice_notes: Array = []
var voice_clock := -1.0
var voice_kind := ""
var _heard_threat: WeakRef
var _heard_until := 0.0
var _voice_rate := 1.0
var _voice_cut := 0.0
var _event_voice := ""
var _event_voice_action := ""
var _chatter_remaining := 0.0
var _queued_voice := ""
var _queued_volume := 0.0
var _queued_wait := 0.0
var _queued_until := 0.0
var _voice_bend_at := -1.0
var _voice_bend := 1.0
var _voice_base_pitch := 1.0
var _hits_seen := 0
var _threat_turn_wait := 0.0
var _poll_action := ""
var _poll_progress := 0.0
var _poll_play := ""
var _poll_leap := ""
var _poll_down := false
var _poll_lands := 0
var _alert_time := 0.0
var _attention_turn := 0.0
var _attention_turn_wait := 0.0
var _attention_seen := -1
var _poll_clock := 0.0

func setup(owner: RigidBody3D) -> void:
	worker = owner
	_rng.seed = absi(str(worker.worker_id).hash())+59821
	_voice_rng.seed = absi(str(worker.worker_id).hash())+90173
	personality_pitch = _rng.randf_range(.87,1.16)
	_next_smile = _rng.randf_range(1.8,5.5)
	_work_voice_remaining = _rng.randf_range(.8,2.0)
	_scan_remaining = _rng.randf_range(0.0,.25)
	_chatter_remaining = _voice_rng.randf_range(1.5,4.0)
	attention = Attention.new()
	attention.setup(worker)
	var capsule := CapsuleShape3D.new()
	capsule.radius = .31
	capsule.height = 1.06
	_clearance.shape = capsule
	_clearance.collision_mask = worker.collision_mask
	_voice = AudioStreamPlayer3D.new()
	_voice.name = "WakoVoice"
	_voice.bus = &"Voice"
	_voice.max_distance = 22.0
	_voice.unit_size = 2.0
	_voice.volume_db = -16.0
	worker.add_child(_voice)
	Voice.prepare()
	worker.action_contact.connect(_on_work_contact)

func advance(delta: float) -> void:
	var began := Time.get_ticks_usec()
	_clock += delta
	_scan_remaining -= delta
	_next_smile = maxf(0.0,_next_smile-delta)
	_smile_remaining = maxf(0.0,_smile_remaining-delta)
	greeting_age = minf(1.0,greeting_age+delta)
	_work_voice_remaining = maxf(0.0,_work_voice_remaining-delta)
	if voice_clock>=0.0 or not _queued_voice.is_empty(): _advance_voice_clock(delta)
	_advance_work_voice(delta)
	# Event voices poll real state at 10 Hz (crossings are edge-detected);
	# the slow clocks (hearing, chatter cooldown) tick with them.
	_poll_clock += delta
	if _poll_clock>=.1:
		heard_age += _poll_clock
		_chatter_remaining = maxf(0.0,_chatter_remaining-_poll_clock)
		_poll_voice_events(_poll_clock)
		_poll_clock = 0.0
	_cover_retry = maxf(0.0,_cover_retry-delta)
	if _scan_remaining<=0.0:
		_scan_remaining = _rng.randf_range(.21,.29)
		_observe_world()
	var core := _actual_threat()
	if core!=live_threat:
		# A newly noticed (or lost) enemy wakes the face on the next tick, so
		# the startle widen is never sampled late.
		live_threat = core
		var face: RefCounted = worker.get("eyes")
		if face: face.wake()
	# Eyes reuse this live cached observation; no new visibility query or
	# remembered point survives actual enemy loss, defeat or departure.
	alert_position = core.global_position if core else Vector3.INF
	alert_weight = move_toward(alert_weight,1.0 if core else 0.0,delta*4.0)
	if core and worker.global_position.distance_squared_to(core.global_position)<DANGER_RADIUS*DANGER_RADIUS:
		# Existing job/station cancellation owns physical payload recovery. Gun
		# duty remains protected on its actual reachable supported control point.
		if not _protected_gun() and is_instance_valid(worker.coordinator):
			worker.fear_time = maxf(worker.fear_time,.7)
			if _cover_retry<=0.0:
				_cover_retry = .8
				_choose_retreat(core)
	_advance_retreat()
	var free_expression := _can_smile()
	if not free_expression or core:
		_smile_remaining = 0.0
	var player: Node3D = _seen_player.get_ref() if _seen_player else null
	if free_expression and not core and is_instance_valid(player):
		if _next_smile<=0.0 and _smile_remaining<=0.0 and _smile_allowed(player):
			_smile_remaining = _rng.randf_range(1.3,2.8)
			_next_smile = _rng.randf_range(6.0,15.0)
			_smiling[worker.get_instance_id()] = Attention.now()+_smile_remaining+1.0
			greeting_age = 0.0
			_greeting_active = false
			_greeting_pending = true
			events.smile += 1
	else:
		_smile_remaining = 0.0
	var wanted := 1.0 if _smile_remaining>0.0 else 0.0
	smile_weight = move_toward(smile_weight,wanted,delta*(3.0 if wanted>0.0 else 2.0))
	# A natural smile can start while the last arriving/turning sole is still
	# recovering. Let the existing face turn finish before the one supported
	# body hello; the eyes keep their original smile and independent blink.
	# This pending acknowledgement owns no plant, support force or IK target.
	_greeting_pending = _greeting_pending and wanted>0.0 and free_expression and not core and is_instance_valid(player)
	# One acknowledgement belongs to a real natural smile, not a new idle
	# loop. The observed eyes lead its body by 120 ms. A lost obligation or
	# plant cancels the request; the existing pose filter releases it smoothly.
	_greeting_active = _greeting_active and wanted>0.0 and _can_greet() and not core and is_instance_valid(player)
	greeting_weight = move_toward(greeting_weight,1.0 if _greeting_active and greeting_age<1.0 else 0.0,delta*12.0)
	# Quiet eye contact uses the already observed visible player, including
	# the gaps between smiles. Only a real smile asks the body to turn.
	look_position = player.global_position+Vector3.UP*.6 if free_expression and not core and is_instance_valid(player) else Vector3.INF
	if wanted>0.0 and look_position.is_finite(): worker.face_point(look_position)
	if _poll_clock==0.0:
		_follow_attention(.1,free_expression and not core)
		_threat_turn(.1,core)
	var elapsed := Time.get_ticks_usec()-began
	profile_ticks += 1
	profile_total_usec += elapsed
	profile_peak_usec = maxi(profile_peak_usec,elapsed)

func pose_published() -> void:
	if not _greeting_pending and not _greeting_active: return
	# The existing native idle-foot planner and actual current sole solve
	# publish before this admission. A finished pivot alone is not quiet:
	# its opposite old stride still needs the original .055 m placement scan.
	var pose: SkeletonModifier3D = worker._pose
	var quiet_placement: bool = pose and pose.evaluated_valid and pose._stopped_turn_pose_ready \
		and pose._pivot_side<0 and pose._pivot_return_side<0
	_greeting_active = _greeting_active and quiet_placement and _can_greet()
	if not _greeting_pending or not quiet_placement or not _can_greet() or not _greeting_start_ready(): return
	_greeting_pending = false
	_greeting_active = true
	# Begin the unchanged zero-age neutral-to-gather interval, including
	# its original 120 ms eye lead; never jump into a later body pose.
	greeting_age = 0.0

func _greeting_start_ready() -> bool:
	var player: Node3D = _seen_player.get_ref() if _seen_player else null
	if not is_instance_valid(player): return false
	# The original walk-to-idle landing still owns the arriving legs.
	# Prior published plants do not admit a hello during that last stride.
	if worker._animation.current_animation!="wk_idle": return false
	# Admit the hello only after its real arriving/player-facing turn.
	# Once started, the original ongoing support/work/danger gates own
	# continuation; a small native turn ease-out is not a new start.
	var toward: Vector3 = (player.global_position-worker.global_position).slide(Vector3.UP)
	if toward.length_squared()<.0001 or absf(worker.turn_rate)>.12: return false
	var facing := atan2(-toward.x,-toward.z)
	return absf(wrapf(facing-worker._heading,-PI,PI))<=.04

func _can_greet() -> bool:
	if not _can_smile() or is_instance_valid(worker.equipped_gun) or worker.tool_foot_occupied(): return false
	var pose: SkeletonModifier3D = worker._pose
	return pose and pose.evaluated_valid and pose.evaluated_grounded[0] and pose.evaluated_grounded[1]

# A friendly quiet hello: counter-dip, proud tilt, single nod, small
# overshoot and a longer settle. Happiness is specific to the encounter;
# the eyes carry its emotion, rather than adding an unrelated big dance.
# Kevin Koch: https://www.animationmentor.com/blog/the-6-basic-emotions-animating-happiness-with-kevin-koch/
const GREETING_POSES := [
	[0.00, Vector3.ZERO, Vector3.ZERO],
	[.12, Vector3.ZERO, Vector3.ZERO],
	[.21, Vector3(-.009,-.028,.010), Vector3(.045,0,.025)],
	[.32, Vector3(.012,-.012,-.003), Vector3(.080,0,-.120)],
	[.43, Vector3(.010,-.013,-.002), Vector3(.065,0,-.105)],
	[.53, Vector3(0,-.020,.012), Vector3(-.120,0,-.055)],
	[.65, Vector3(.003,-.008,-.004), Vector3(.035,0,-.020)],
	[.92, Vector3.ZERO, Vector3.ZERO],
	[1.00, Vector3.ZERO, Vector3.ZERO],
]

func greeting_pose(track: int) -> Vector3:
	var clock := maxf(greeting_age-(.025 if track==1 else 0.0),0.0)
	for key in range(1,GREETING_POSES.size()):
		var end: Array = GREETING_POSES[key]
		if clock>float(end[0]): continue
		var begin: Array = GREETING_POSES[key-1]
		var t := (clock-float(begin[0]))/maxf(float(end[0])-float(begin[0]),.0001)
		var spacing := t*t*t*(t*(t*6.0-15.0)+10.0)
		if key in [3,5]:
			# Front-loaded accents ease out with zero endpoint velocity and
			# acceleration, followed by a deliberately longer final settle.
			spacing = t*t*t*(56.0+t*(-210.0+t*(336.0+t*(-280.0+t*(120.0-21.0*t)))))
		return Vector3(begin[track+1]).lerp(Vector3(end[track+1]),spacing)*greeting_weight
	return Vector3.ZERO

func _can_smile() -> bool:
	if not worker.is_available() or worker.paused or not worker.on_ground or worker.fear_time>0.0: return false
	if not worker.action.is_empty() or not worker.current_job_id.is_empty() or worker.work_action_held: return false
	if worker.carrying or is_instance_valid(worker.station) or is_instance_valid(worker.access_support): return false
	if is_instance_valid(worker.carry_partner) or is_instance_valid(worker.brace_load) or is_instance_valid(worker.brace_leader): return false
	if worker.head_leap and worker.head_leap.active(): return false
	if worker.back_tool and worker.back_tool.busy(): return false
	# The existing water/pair controller owns its attention and facing while
	# playing or recovering. These are cached claims, not new route queries.
	var play: RefCounted = worker.idle_play
	if play and (not play.state.is_empty() or not play._pair.is_empty() or play.physical_recovery_pending()): return false
	if worker.pickup and not worker.pickup.state.is_empty(): return false
	if worker.portable_gun and worker.portable_gun.handoff_active(): return false
	if worker.gait_speed>.25 or (worker.linear_velocity-worker.ground_velocity).length()>.35: return false
	if worker.has_target and (worker.target_position-worker.global_position).slide(Vector3.UP).length()>.3: return false
	return worker.needs.is_empty()

func _protected_gun() -> bool:
	if worker.portable_gun and worker.portable_gun.defence_stance_ready(): return true
	var station: Node3D = worker.station
	if is_instance_valid(station) and station.kind=="gun" and station.installed and station.health>0.0:
		return worker.supported_by(station.assembly) and worker.can_reach_work()
	var service: Node = worker.coordinator
	if not is_instance_valid(service) or not service.active_jobs.has(worker.current_job_id): return false
	var job: Dictionary = service.active_jobs[worker.current_job_id].job
	return job.kind=="operate" and is_instance_valid(job.target) and job.target.kind=="gun" \
		and worker.supported_by(job.target.assembly) and worker.can_reach_target(job.target)

func _observe_world() -> void:
	var nearest: Node3D
	var distance := NOTICE_RADIUS*NOTICE_RADIUS
	for enemy: Node in worker.get_tree().get_nodes_in_group(&"contraption_threats"):
		var core := _live_enemy_core(enemy)
		if not core: continue
		var squared := worker.global_position.distance_squared_to(core.global_position)
		if squared>=distance or not _can_see(core.global_position,core): continue
		nearest = core
		distance = squared
	_threat = weakref(nearest) if nearest else null
	if nearest: _warn(nearest)
	elif _heard_threat:
		# A peer's real warning keeps its live core in mind for a few seconds
		# without own sight; _actual_threat() still revalidates every tick.
		var heard: Node3D = _heard_threat.get_ref()
		if _clock<_heard_until and is_instance_valid(heard) and not heard.is_queued_for_deletion() \
			and _live_enemy_core(heard.get_meta(&"machine_fauna",null))==heard: _threat = _heard_threat
		else: _heard_threat = null
	_seen_player = null
	var player: Node3D = Global.Player if is_instance_valid(Global.Player) else null
	if player and player.global_position.distance_squared_to(worker.global_position)<81.0 \
		and _can_see(player.global_position+Vector3.UP*.6,player):
		_seen_player = weakref(player)
	# Points of interest reuse this same perception cadence (no extra scan).
	# Working Wako and Wako facing a real live threat look at their job or
	# threat and free the slot; a bumped Wako (fear, no enemy) keeps looking.
	if attention:
		if worker.current_job_id.is_empty() and not _actual_threat() and not is_instance_valid(worker.station):
			attention.scan(_seen_player.get_ref() if _seen_player else null,_can_see)
		else: attention.release()

func _live_enemy_core(enemy: Node) -> Node3D:
	return GunControl.live_hostile_core(enemy)

func _actual_threat() -> Node3D:
	var core: Node3D = _threat.get_ref() if _threat else null
	if not is_instance_valid(core) or core.is_queued_for_deletion(): return null
	if _live_enemy_core(core.get_meta(&"machine_fauna",null))!=core: return null
	return core if worker.global_position.distance_squared_to(core.global_position)<NOTICE_RADIUS*NOTICE_RADIUS else null

func _can_see(point: Vector3, target: Node3D) -> bool:
	_ray.exclude = worker.query_exclusions()
	_ray.collision_mask = worker.collision_mask
	_ray.from = worker._visual_head_point if worker._visual_head_point.is_finite() else worker.global_position+Vector3.UP*.3
	_ray.to = point
	var hit := worker.get_world_3d().direct_space_state.intersect_ray(_ray)
	if hit.is_empty(): return true
	var collider: Node = hit.collider
	if collider==target or target.is_ancestor_of(collider): return true
	var assembly: Variant = target.get("assembly")
	return is_instance_valid(assembly) and collider.get("assembly")==assembly

func _warn(core: Node3D) -> void:
	# Game time (physics frames), so movie-maker and slowed frames never
	# re-trigger a call early.
	var now := Attention.now()
	var key := core.get_instance_id()
	if now<float(_warning_until.get(key,0.0)): return
	# One sparse audible call per enemy reaches the nearby crew. Expiry and
	# a real live core prevent permanent or stale danger.
	_warning_until[key] = now+_rng.randf_range(5.0,8.0)
	for stale: int in _warning_until.keys():
		if float(_warning_until[stale])<now-10.0: _warning_until.erase(stale)
	if _play_voice("warning",-9.0):
		events.warning += 1
		# A close enemy sometimes earns an urgent second call.
		if worker.global_position.distance_squared_to(core.global_position)<DANGER_RADIUS*DANGER_RADIUS and _voice_rng.randf()<.35:
			_queued_voice = "warning"
			_queued_volume = -10.0
			_queued_wait = .07
			_queued_until = _clock+.5
	Attention.post(worker,&"warning",worker.global_position+Vector3.UP*.5,.9,1.5,worker)
	var service: Node = worker.coordinator
	if not is_instance_valid(service) or not is_instance_valid(service.yard): return
	service.yard.last_message = worker.helper_name+" warns: enemy nearby!"
	for peer: RigidBody3D in service.workers:
		if not is_instance_valid(peer) or peer.global_position.distance_squared_to(worker.global_position)>144.0: continue
		var director: RefCounted = peer.get("personality")
		if director: director.hear_warning(core,worker)

func hear_warning(core: Node3D, caller: Node3D = null) -> void:
	if not is_instance_valid(core) or _live_enemy_core(core.get_meta(&"machine_fauna",null))!=core: return
	if worker.global_position.distance_squared_to(core.global_position)>NOTICE_RADIUS*NOTICE_RADIUS: return
	_threat = weakref(core)
	alert_weight = 1.0
	_smile_remaining = 0.0
	if caller==worker: return
	# Hearing is not a one-scan glance: keep the live core in mind for a few
	# seconds (refreshed by later calls) and glance at the caller first.
	_heard_threat = weakref(core)
	_heard_until = _clock+3.5+.25*float(absi(str(worker.worker_id).hash())%5)
	if is_instance_valid(caller):
		heard_caller = weakref(caller)
		heard_age = 0.0
	events.heard_warning += 1

func safe_retreat_position(ordinary: Vector3) -> Vector3:
	var core: Node3D = _cover_source.get_ref() if _cover_source else null
	# A remembered real live threat may still occupy ordinary parking after
	# the helper escapes its sight radius. Do not walk straight back into it
	# on a timer; actual defeat, departure or a changed danger envelope releases it.
	if not _cover_point.is_finite() or not is_instance_valid(core) \
		or _live_enemy_core(core.get_meta(&"machine_fauna",null))!=core: return ordinary
	if ordinary.distance_squared_to(core.global_position)>=DANGER_RADIUS*DANGER_RADIUS: return ordinary
	if _cover_point.distance_squared_to(core.global_position)<DANGER_RADIUS*DANGER_RADIUS: return ordinary
	if is_instance_valid(worker.coordinator) and worker.coordinator.yard.unsafe_at(_cover_point): return ordinary
	return _cover_point

func _choose_retreat(core: Node3D) -> void:
	if _route_goal.is_finite() or not _retreat_candidates.is_empty(): return
	if not worker.on_ground or not worker.is_available() or is_instance_valid(worker._ground_body) or worker.ground_normal.y<.9: return
	var service: Node = worker.coordinator
	if not is_instance_valid(service) or not is_instance_valid(service.yard): return
	var ordinary: Vector3 = service._parking_position(worker)
	if ordinary.distance_squared_to(core.global_position)>=DANGER_RADIUS*DANGER_RADIUS and not service.yard.unsafe_at(ordinary): return
	if _cover_point.is_finite() and _clock<_cover_until and not service.yard.unsafe_at(_cover_point) \
		and _cover_point.distance_squared_to(core.global_position)>=DANGER_RADIUS*DANGER_RADIUS: return
	var away: Vector3 = (worker._ground_point-core.global_position).slide(Vector3.UP).normalized()
	if away.length_squared()<.5: return
	_retreat_core = weakref(core)
	for distance: float in [4.0,6.0,8.0]:
		for turn: float in [0.0,.48,-.48,.9,-.9]:
			var candidate: Vector3 = worker._ground_point+away.rotated(Vector3.UP,turn)*distance
			if candidate.distance_squared_to(core.global_position)>=DANGER_RADIUS*DANGER_RADIUS \
				and not service.yard.unsafe_at(candidate): _retreat_candidates.append(candidate)

func _advance_retreat() -> void:
	if not _route_goal.is_finite() and _retreat_candidates.is_empty(): return
	var core: Node3D = _retreat_core.get_ref() if _retreat_core else null
	if not is_instance_valid(core) or _live_enemy_core(core.get_meta(&"machine_fauna",null))!=core \
		or not worker.on_ground or not worker.is_available() or is_instance_valid(worker._ground_body) or _protected_gun():
		_retreat_candidates.clear()
		_route_goal = Vector3.INF
		return
	if _route_goal.is_finite() and (worker._ground_point-_route_from).length()>.35:
		# Do not publish a route sampled from a departed native starting point.
		_retreat_candidates.clear()
		_route_goal = Vector3.INF
		return
	_ray.exclude = worker.query_exclusions()
	_ray.collision_mask = 1
	_clearance.exclude = worker.query_exclusions()
	# At most three floor/headroom samples per 120 Hz tick, including failed
	# candidates. Idle personality never runs a whole route search in one tick.
	for sample in 3:
		if not _route_goal.is_finite():
			if _retreat_candidates.is_empty(): return
			_route_goal = _retreat_candidates.pop_front()
			_route_from = worker._ground_point
			_route_last = _route_from
			_route_steps = maxi(1,ceili((_route_goal-_route_from).slide(Vector3.UP).length()/.35))
			_route_step = 0
		_route_step += 1
		var point := _route_from.lerp(_route_goal,float(_route_step)/_route_steps)
		_ray.from = Vector3(point.x,_route_last.y+.55,point.z)
		_ray.to = Vector3(point.x,_route_last.y-.55,point.z)
		var hit := worker.get_world_3d().direct_space_state.intersect_ray(_ray)
		if hit.is_empty() or hit.normal.y<.9 or hit.collider is RigidBody3D:
			_route_goal = Vector3.INF
			continue
		point = hit.position
		if absf(point.y-_route_last.y)>.12 or point.distance_squared_to(core.global_position)+.01<_route_last.distance_squared_to(core.global_position):
			_route_goal = Vector3.INF
			continue
		_clearance.transform = Transform3D(Basis.IDENTITY,point+Vector3.UP*worker.ride_height)
		if not worker.get_world_3d().direct_space_state.intersect_shape(_clearance,1).is_empty():
			_route_goal = Vector3.INF
			continue
		_route_last = point
		if _route_step<_route_steps: continue
		if point.distance_squared_to(core.global_position)>=DANGER_RADIUS*DANGER_RADIUS \
			and not worker.coordinator.yard.unsafe_at(point):
			_cover_point = point+Vector3.UP*worker.ride_height
			_cover_source = weakref(core)
			_cover_until = _clock+8.0
			events.cover += 1
			_retreat_candidates.clear()
		_route_goal = Vector3.INF
		return

func _on_work_contact(kind: String) -> void:
	if kind not in ["assemble","repair","maintenance","unbend","inspect","tool_change","operate"]: return
	# The helper already admitted the actual supported toe/tool contact. A
	# stale signal or held/paused work must not create a pretend work sound.
	if worker.action!=kind or not worker._contact_sent: return
	events.work_contact += 1
	Attention.post(worker,&"work_contact",worker.work_point(),.45,1.1,null,worker.work_target)
	if worker.fear_time>0.0 or alert_weight>.001 or worker.paused or worker.work_action_held or not worker.on_ground \
		or not worker.is_available() or not is_instance_valid(worker.work_target) or _work_voice_remaining>0.0: return
	# Brisk work has sparse short vocal accents, not a voice on every blow.
	# Nearby helpers take turns; a rejected call never postpones useful work.
	if not _work_call_room(): return
	_work_voice_remaining = _voice_rng.randf_range(4.0,7.0) if kind=="operate" else _voice_rng.randf_range(2.0,4.0)
	if _voice_rng.randf()> (.35 if kind=="operate" else .76): return
	var call_kind := "inspect" if kind in ["inspect","tool_change"] else "repair" if kind in ["repair","maintenance","operate"] else "effort" if kind=="unbend" else "assemble"
	var volume := -21.0 if call_kind=="inspect" else -20.0 if call_kind=="repair" else -19.0
	if kind=="operate": volume = -23.0
	if not _play_voice(call_kind,volume): return
	_remember_work_call()
	_work_voice_action = kind
	_work_voice_job = worker.current_job_id
	_work_voice_target_id = worker.work_target.get_instance_id()
	_work_voice_volume = volume
	events.work_voice += 1

func _work_call_room() -> bool:
	var now := Attention.now()
	var tree_id := worker.get_tree().get_instance_id()
	for index in range(_work_call_history.size()-1,-1,-1):
		var call: Dictionary = _work_call_history[index]
		var owner: Object = call.owner.get_ref()
		if now>=float(call.until) or not is_instance_valid(owner) or call.tree!=tree_id:
			_work_call_history.remove_at(index)
	for call: Dictionary in _work_call_history:
		if worker.global_position.distance_squared_to(call.position)<64.0: return false
	return true

func _remember_work_call() -> void:
	_work_call_history.append({"until":Attention.now()+_voice_rng.randf_range(.9,1.3),
		"position":worker.global_position,"tree":worker.get_tree().get_instance_id(),"owner":weakref(worker)})

func work_completed(kind: String, job_id: String) -> void:
	# The scheduler invokes this once, after real perform_work success and
	# resource release. Animation ending and failed/cancelled work never do.
	if kind not in ["build","replace","join","prepare","dismantle","salvage","repair","maintenance","unbend"]: return
	if is_instance_valid(worker) and worker.is_inside_tree() and worker.fear_time<=0.0 and alert_weight<=.001:
		# The crew and nearby Wako can share the real win.
		Attention.post(worker,&"job_done",worker.global_position+Vector3.UP*.5,.8,2.0,worker)
		if worker.has_method(&"face_pulse"):
			worker.face_pulse(&"joy",1.0)
			worker.face_blink(true)
	if Shortcuts.quitting or not is_instance_valid(_voice) or not _completed_voice_supported(): return
	# Let a just-earned real contact syllable finish naturally into the win;
	# do not layer or truncate it with a second celebratory voice.
	if _voice.playing and _work_voice_job==job_id and not _work_voice_action.is_empty() and _work_voice_fade<0.0:
		_work_voice_completed = true
		_work_voice_job = ""
		_work_voice_target_id = 0
		return
	if _voice.playing or _work_voice_remaining>1.2 or not _work_call_room() or _voice_rng.randf()>.72: return
	if not _play_voice("yay",-19.5): return
	_remember_work_call()
	_work_voice_completed = true
	_work_voice_action = worker.action
	_work_voice_volume = -19.5
	_work_voice_remaining = _voice_rng.randf_range(2.0,4.0)
	events.work_complete_voice += 1

func _completed_voice_supported() -> bool:
	if not worker.current_job_id.is_empty() or worker.paused or worker.work_action_held \
		or not worker.on_ground or worker.fear_time>0.0 or alert_weight>.001 or not worker.is_available(): return false
	var service: Node = worker.coordinator
	return not is_instance_valid(service) or not is_instance_valid(service.yard) or not service.yard.work_paused

func _advance_work_voice(delta: float) -> void:
	if _work_voice_action.is_empty() and _water_voice_phase.is_empty() and not _work_voice_completed and _event_voice.is_empty(): return
	if not is_instance_valid(_voice) or not _voice.playing:
		_work_voice_action = ""
		_water_voice_phase = ""
		_work_voice_completed = false
		_event_voice = ""
		_work_voice_fade = -1.0
		return
	# Deleted/restored work references stay Variant until validity is known.
	var target: Variant = worker.get("work_target")
	var target_id := 0
	if is_instance_valid(target) and target is Node3D and not target.is_queued_for_deletion():
		target_id = target.get_instance_id()
	var continuing: bool = worker.action==_work_voice_action and worker.current_job_id==_work_voice_job \
		and target_id!=0 and target_id==_work_voice_target_id \
		and not worker.paused and not worker.work_action_held and worker.on_ground and worker.fear_time<=0.0 and alert_weight<=.001 and worker.is_available()
	if _work_voice_completed:
		# A brief earned tail may settle with its finishing action. New useful
		# work, pause, target obligation, danger or a fall still interrupts it.
		continuing = _completed_voice_supported() and worker.action in ["",_work_voice_action]
	if not _water_voice_phase.is_empty(): continuing = _water_voice_supported()
	if not _event_voice.is_empty(): continuing = _event_voice_supported()
	if continuing and _work_voice_fade<0.0: return
	if _work_voice_fade<0.0:
		_work_voice_fade = 0.0
		if not _event_voice.is_empty(): pass
		elif not _water_voice_phase.is_empty(): events.water_voice_cancel += 1
		else: events.work_voice_cancel += 1
	# Bounded amplitude fade on the existing channel, no tween/player per
	# contact. It also follows real target loss, native falls and job changes.
	_work_voice_fade += delta
	var gain := 1.0-smoothstep(0.0,.065,_work_voice_fade)
	_voice.volume_db = _work_voice_volume+linear_to_db(maxf(gain,.0001))
	if _work_voice_fade>=.065:
		_voice.stop()
		_work_voice_action = ""
		_water_voice_phase = ""
		_work_voice_completed = false
		_event_voice = ""
		_work_voice_fade = -1.0

func _water_voice_supported() -> bool:
	if not is_instance_valid(worker) or worker.is_queued_for_deletion() or not worker.is_available() \
		or worker.paused or worker.fear_time>0.0 or alert_weight>.001: return false
	if not worker.current_job_id.is_empty() or not worker.action.is_empty() or worker.work_action_held: return false
	var play: Variant = worker.get("idle_play")
	# Reuse the water controller's real cancellation/lease observations; no
	# extra route, support or water query belongs to the audio channel.
	return is_instance_valid(play) and bool(play.get("_water_active")) \
		and not bool(play.get("_water_interrupted")) and not bool(play.get("_reserved_for_work"))

func water_voice_cue(phase: String) -> bool:
	if phase not in ["notice","dive","surface"] or not _water_voice_supported() \
		or _work_voice_remaining>0.0 or not is_instance_valid(_voice) or _voice.playing: return false
	# These one-shot boundaries never spend the idle/motion random stream.
	if _voice_rng.randf()>.6: return false
	var kind := "inspect" if phase=="notice" else "jump" if phase=="dive" else "play"
	var volume := -22.0 if phase=="notice" else -23.0 if phase=="dive" else -21.0
	if not _play_voice(kind,volume): return false
	_work_voice_remaining = _voice_rng.randf_range(2.8,5.2)
	_water_voice_phase = phase
	_work_voice_volume = volume
	events.water_voice += 1
	return true

func _play_voice(kind: String, volume: float) -> bool:
	if Shortcuts.quitting or not is_instance_valid(_voice): return false
	if _voice.playing:
		if kind!="warning": return false
		_voice.stop()
	_work_voice_action = ""
	_water_voice_phase = ""
	_work_voice_completed = false
	_event_voice = ""
	_work_voice_fade = -1.0
	var previous: AudioStream = _last_voice_streams.get(kind)
	# Same baked bank: idle play calls sometimes giggle; event kinds resolve
	# to re-pitched/trimmed clips (Voice.VARIANTS).
	var spoken := "giggle" if kind=="play" and _voice_rng.randf()<.3 else kind
	var voice := Voice.variant(spoken,_voice_rng,previous)
	_voice.stream = voice.stream
	_last_voice_streams[kind] = _voice.stream
	_voice_kind = kind
	_voice.pitch_scale = personality_pitch*_voice_rng.randf_range(.96,1.04)*float(voice.pitch)*(1.06 if kind in ["assemble","effort"] else 1.0)
	_voice_base_pitch = _voice.pitch_scale
	var bend: Array = voice.bend
	_voice_bend_at = float(bend[0]) if bend.size()==2 else -1.0
	_voice_bend = float(bend[1]) if bend.size()==2 else 1.0
	_voice.volume_db = volume
	_work_voice_volume = volume
	_voice.play(float(voice.from))
	voice_notes = voice.notes
	voice_kind = spoken
	voice_clock = float(voice.from)
	_voice_rate = _voice.pitch_scale
	_voice_cut = float(voice.from)+float(voice.length) if float(voice.length)>0.0 else 0.0
	# Listeners glance at the talker (warnings post their own event); the
	# face composes the first syllable on the next tick.
	if kind!="warning": Attention.post(worker,&"voice",worker.global_position+Vector3.UP*.4,.3,.8,worker)
	var face: RefCounted = worker.get("eyes")
	if face: face.wake()
	return true

## Sparse event voice on a real trigger: personal chatter cooldown (urgent
## calls skip only this), crew turn-taking, silence in danger unless this
## Wako itself was hit (own_hit), one random draw.
func say(kind: String, volume: float, chance := 1.0, urgent := false, own_hit := false) -> bool:
	if Shortcuts.quitting or not is_instance_valid(_voice) or _voice.playing or worker.paused: return false
	if not urgent and _chatter_remaining>0.0: return false
	if not own_hit and (worker.fear_time>0.0 or alert_weight>.001): return false
	if not _work_call_room(): return false
	if _voice_rng.randf()>chance: return false
	if not _play_voice(kind,volume): return false
	_remember_work_call()
	_event_voice = kind
	_event_voice_action = worker.action
	_chatter_remaining = _voice_rng.randf_range(2.5,6.0)
	events.event_voice += 1
	return true

func _event_voice_supported() -> bool:
	# A trimmed clip ends with the same 65 ms fade as an interruption.
	if _voice_cut>0.0 and voice_clock>=_voice_cut: return false
	if _event_voice=="oops": return true
	if not worker.is_available() or worker.paused or worker.fear_time>0.0 or alert_weight>.001: return false
	if _event_voice in ["grunt","nngh"]: return worker.action==_event_voice_action and not worker.work_action_held and worker.on_ground
	return true

func _advance_voice_clock(delta: float) -> void:
	# Every clip starts through _play_voice (which starts this clock); a
	# silent face with nothing queued never calls this.
	if voice_clock>=0.0 and is_instance_valid(_voice) and _voice.playing:
		voice_clock += delta*_voice_rate
		if _voice_bend_at>=0.0 and voice_clock>=_voice_bend_at:
			# A short glide into the bent pitch (a falling second syllable).
			_voice.pitch_scale = move_toward(_voice.pitch_scale,_voice_base_pitch*_voice_bend,delta*6.0)
			_voice_rate = _voice.pitch_scale
		# A clip can never outlive its own PCM (guards a silent/dummy audio
		# server from holding the channel and the mouth open forever).
		if _voice.stream and voice_clock>_voice.stream.get_length()+.15: _voice.stop()
		return
	if voice_clock>=0.0:
		voice_clock = -1.0
		voice_notes = []
	if _queued_voice.is_empty(): return
	# The urgent repeat only belongs right after its own call.
	if _clock>_queued_until:
		_queued_voice = ""
		return
	_queued_wait -= delta
	if _queued_wait>0.0: return
	var kind := _queued_voice
	_queued_voice = ""
	if _actual_threat(): _play_voice(kind,_queued_volume)

func _poll_voice_events(delta: float) -> void:
	var action: String = worker.action
	var progress: float = worker.action_progress
	if action!=_poll_action:
		_poll_action = action
		_poll_progress = 0.0
	# Effort on real strokes: a sparse grunt on the draw before contact, a
	# strained "nngh" in sustained force. Shares the work-voice cooldown.
	if _work_voice_remaining<=0.0 and worker.on_ground and not worker.work_action_held and is_instance_valid(worker.work_target):
		if action in ["assemble","repair"] and _poll_progress<.40 and progress>=.40:
			if say("grunt",-21.0,.24): _work_voice_remaining = _voice_rng.randf_range(2.0,4.0)
		elif action in ["unbend","push","pull","brace","maintenance"] and _poll_progress<.28 and progress>=.28:
			if say("nngh",-21.0,.3): _work_voice_remaining = _voice_rng.randf_range(2.5,4.5)
	_poll_progress = progress
	# Anticipation "hup" on real jump gathers, a small "hop" on landings.
	var play: RefCounted = worker.idle_play
	var state: String = str(play.state) if play else ""
	if state!=_poll_play:
		if state=="gather" and not play._water_active: say("hup",-22.0,.55)
		_poll_play = state
	var lands: int = int(play.events.land) if play else 0
	if lands!=_poll_lands:
		if lands>_poll_lands: say("hop",-24.0,.3)
		_poll_lands = lands
	var leap: String = str(worker.head_leap.state) if worker.head_leap else ""
	if leap!=_poll_leap:
		if leap=="prepare": say("hup",-22.0,.5)
		_poll_leap = leap
	# Real hits (counted by the face from apply_hit/take_damage/native
	# impacts, never a job interruption) and falls: an "uh-oh". It still
	# takes turns with nearby calls.
	var face: RefCounted = worker.get("eyes")
	var hits: int = int(face.events.hit) if face else 0
	var down: bool = not worker.is_available()
	if hits!=_hits_seen or (down and not _poll_down): say("oops",-18.0 if down else -20.0,.75,true,true)
	_hits_seen = hits
	_poll_down = down
	# A curious "huh?"/"hmm" now and then when attention jumps to a fresh,
	# unusual event of another Wako (a flip, splash, fall, toss).
	if attention and attention.serial!=_attention_seen:
		_attention_seen = attention.serial
		if attention.novel and attention.kind in [&"flip",&"splash",&"fall",&"toss",&"hop"]:
			say("huh" if _voice_rng.randf()<.5 else "hmm",-24.0,.18)
	# Relief once a real alert releases.
	if alert_weight>.9: _alert_time += delta
	elif alert_weight<=.001:
		if _alert_time>1.0: say("sigh",-22.0,.6)
		_alert_time = 0.0

func _smile_allowed(player: Node3D) -> bool:
	# Smile at someone this Wako is really looking at, and only while few of
	# the crew already beam (each tree keeps its own count).
	var face: RefCounted = worker.get("eyes")
	if face and not face.watching(player): return false
	if attention and attention.kind!=&"player" and attention.point.is_finite(): return false
	var now := Attention.now()
	var active := 0
	for id: int in _smiling.keys():
		if float(_smiling[id])<now or not is_instance_id_valid(id): _smiling.erase(id)
		elif (instance_from_id(id) as Node).get_tree()==worker.get_tree(): active += 1
	var service: Node = worker.coordinator
	var crew: int = service.workers.size() if is_instance_valid(service) else 1
	return active<maxi(1,int(.2*crew))

func _threat_turn(delta: float, core: Node3D) -> void:
	# Watching a live enemy while standing (beyond the flee radius, or from
	# cover): the eyes lead and the cube follows toward it, but only into a
	# 3/4 stance. Within ~60 deg the eyes alone watch it; beyond that the
	# cube turns just enough to leave ~45 deg to the eyes, so the worried
	# face stays readable from most of the yard (never a full back turn).
	_threat_turn_wait = maxf(0.0,_threat_turn_wait-delta)
	if not core or _threat_turn_wait>0.0 or not worker.is_available() or not worker.on_ground or worker.paused: return
	if not worker.current_job_id.is_empty() or worker.action not in ["","danger"] or is_instance_valid(worker.station) or worker.carrying: return
	if worker.gait_speed>.25 or (worker.has_target and (worker.target_position-worker.global_position).slide(Vector3.UP).length()>.3): return
	if worker.back_tool and worker.back_tool.busy(): return
	var watch: SkeletonModifier3D = worker.threat_watch
	if is_instance_valid(watch) and float(watch._notice_age)<.4: return
	var to: Vector3 = (core.global_position-worker.global_position).slide(Vector3.UP)
	if to.length_squared()<.04: return
	var off := wrapf(atan2(-to.x,-to.z)-worker._heading,-PI,PI)
	if absf(off)<1.05: return
	_threat_turn_wait = .9
	var facing: float = worker._heading+off-signf(off)*.8
	worker.face_point(worker.global_position+Vector3(-sin(facing),0.0,-cos(facing))*3.0)

func _follow_attention(delta: float, idle: bool) -> void:
	# A quiet planted Wako turns its body toward a strong point of interest
	# that stays well off its face (eyes lead; the body follows later).
	_attention_turn_wait = maxf(0.0,_attention_turn_wait-delta)
	if not idle or smile_weight>.01 or not attention or float(attention.strength)<.5 or attention.kind==&"scan" or not attention.point.is_finite():
		_attention_turn = 0.0
		return
	var to: Vector3 = (attention.point-worker.global_position).slide(Vector3.UP)
	if to.length_squared()<.04: return
	if absf(wrapf(atan2(-to.x,-to.z)-worker._heading,-PI,PI))<.7:
		_attention_turn = 0.0
		return
	_attention_turn += delta
	if _attention_turn>.8 and _attention_turn_wait<=0.0:
		_attention_turn_wait = 3.0
		_attention_turn = 0.0
		events.attention_turn += 1
		worker.face_point(attention.point)

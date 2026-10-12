extends RefCounted
## Optional idle intentions on the original native helper: supported shimmy,
## a short real run, and a bounded ground-launched hop. Work owns the scheduler.
signal play_cancelled(reason: String, played_state: String, serial: int)

const IdlePose := preload("res://LogicObjects/Wako/wako_idle_play_pose.gd")
const PairPose := preload("res://LogicObjects/Wako/wako_paired_foot_pose.gd")
const PairedBalance := preload("res://LogicObjects/Wako/wako_paired_balance.gd")
const UpsideDown := preload("res://LogicObjects/Wako/wako_upside_down_play.gd")
const PLAY_RADIUS := 3.6
const JUMP_SPEED := 3.35
const WATER_NOTICE_RADIUS := 5.0
const WATER_PLAY_RADIUS := 5.4
const WATER_DIVE_RANGE := 3.1
const WATER_DIVE_SPEED := 3.5
const WaterBuoyancy := preload("res://Components/Water/buoyancy.gd")
const WATER_DEPTH_MIN := 1.1
const WATER_DEPTH_MAX := 1.8
var worker: RigidBody3D
var state := ""
var state_age := 0.0
var state_duration := 0.0
var dance_weight := 0.0
var crouch_weight := 0.0
var playfulness := 1.0
var events := {"dance":0,"run":0,"launch":0,"airborne":0,"land":0,"cancel":0,"water_notice":0,"water_approach":0,"water_hop":0,"water_land":0,"water_return":0,"water_enter":0,"water_dive":0,"water_swim":0,"water_exit":0}
var last_cancel := ""
var _pair: Dictionary = {}
var _pair_side := -1
var _pair_foot_active := false
var _pair_returning := false
var _pair_point := Vector3.INF
var _pair_normal := Vector3.FORWARD
var _pair_start_basis := Basis.IDENTITY
var _pair_route_from := Vector3.INF
var _pair_route_last := Vector3.INF
var _pair_route_steps := 0
var _pair_route_step := 0
var _pair_modifier: SkeletonModifier3D
var paired_balance: RefCounted
var upside_down: RefCounted
var last_launch_impulse := Vector3.ZERO
# Optional real immersion uses the existing water force component. The
# ordinary spring-foot controller resumes only for the checked shore exit.
var water_phase := ""
var _water_owner: WeakRef
var _water_point := Vector3.INF
var _water_floor := Vector3.INF
var _water_home := Vector3.INF
var _water_hop_goal := Vector3.INF
var _water_candidates: Array[Vector3] = []
var _water_dry_route: Array[Vector3] = []
var _water_active := false
var _water_check_remaining := 0.0
var _water_retry := 0.0
var water_dive_weight := 0.0
var water_swim_weight := 0.0
var water_immersion := 0.0
var last_water_force := Vector3.ZERO
var last_water_exit_impulse := Vector3.ZERO
var _water_buoy: Node
var _water_clearance := PhysicsShapeQueryParameters3D.new()
var _water_support_frame := -1
var _water_support_cached := false
var _water_recovering := false
var _water_return_requested := false
var _water_interrupted := false
var _water_entered := false
var _water_head_under := false
# Audio-only latch: one actual emergence boundary per native water launch.
var _water_voice_surface_seen := false
var _water_swim_seen := false
var _water_motion_age := 0.0
var _water_exit_attempts := 0
var _water_exit_check := 0.0
var _water_launch_shore := Vector3.INF
var _water_exit_target := Vector3.INF
var _water_flight_time := 0.0
var profile_ticks := 0
var profile_total_usec := 0
var profile_peak_usec := 0
var _rng := RandomNumberGenerator.new()
var _next_play := 0.0
var _run_goal := Vector3.INF
var _run_speed := 0.0
var _airborne_seen := false
var _landing_age := 0.0
var _jump_recovering := false
var _had_obligations := false
var _reservation_frame := -1
var _reserved_for_work := false
var _modifier: SkeletonModifier3D
var _ray := PhysicsRayQueryParameters3D.new()
var _clearance := PhysicsShapeQueryParameters3D.new()
var _route_candidates: Array[Vector3] = []
var _route_from := Vector3.INF
var _route_goal := Vector3.INF
var _route_last := Vector3.INF
var _route_steps := 0
var _route_step := 0

func setup(owner: RigidBody3D) -> void:
	worker = owner
	_rng.seed = absi(str(worker.worker_id).hash())+219483
	playfulness = _rng.randf_range(.8,1.25)
	_next_play = _rng.randf_range(5.0,15.0)/playfulness
	var capsule := CapsuleShape3D.new()
	capsule.radius = .31
	capsule.height = 1.06
	_clearance.shape = capsule
	_clearance.collision_mask = worker.collision_mask
	_modifier = IdlePose.new()
	_modifier.director = self
	worker._skeleton.add_child(_modifier)
	worker._skeleton.move_child(_modifier,worker._pose.get_index())
	_pair_modifier = PairPose.new()
	_pair_modifier.director = self
	worker._skeleton.add_child(_pair_modifier)
	worker._skeleton.move_child(_pair_modifier,worker._pose.get_index()+1)
	paired_balance = PairedBalance.new()
	paired_balance.setup(self)
	upside_down = UpsideDown.new()
	upside_down.setup(self)
	for key: String in ["pair_invite","pair_launch","pair_contact","pair_complete","pair_miss","pair_cancel"]: events[key] = 0

func advance(delta: float) -> void:
	var began := Time.get_ticks_usec()
	if paired_balance: paired_balance.elapse(delta)
	if upside_down: upside_down.elapse(delta)
	_next_play = maxf(0.0,_next_play-delta)
	_water_retry = maxf(0.0,_water_retry-delta)
	_water_check_remaining = maxf(0.0,_water_check_remaining-delta)
	# A launch cannot be undone by a new intention. Keep observing the actual
	# original body until support/feet settle; no pose or velocity reset.
	if upside_down and upside_down.active():
		upside_down.advance(delta)
	elif paired_balance and paired_balance.active():
		paired_balance.advance(delta)
	elif not _pair.is_empty():
		_advance_pair(delta)
	elif _water_recovering:
		_advance_water_motion(delta)
	elif _jump_recovering:
		_advance_jump(delta)
	elif not _free_of_obligations() and not (state.is_empty() and _free_of_obligations(true)):
		_had_obligations = true
		cancel("Useful work, danger or physical recovery")
	elif not state.is_empty():
		_had_obligations = false
		_advance_solo(delta)
	else:
		if _had_obligations:
			_had_obligations = false
			_next_play = maxf(_next_play,_rng.randf_range(3.0,7.0))
		dance_weight = move_toward(dance_weight,0.0,delta*4.0)
		crouch_weight = move_toward(crouch_weight,0.0,delta*4.0)
		var companion_invited: bool = upside_down and upside_down.offer()
		if not companion_invited: companion_invited = paired_balance and paired_balance.offer()
		if not companion_invited and _next_play<=0.0 and available_for_play(true): _choose_solo()
	var elapsed := Time.get_ticks_usec()-began
	profile_ticks += 1
	profile_total_usec += elapsed
	profile_peak_usec = maxi(profile_peak_usec,elapsed)

func _free_of_obligations(water_only := false) -> bool:
	if not is_instance_valid(worker) or worker.is_queued_for_deletion() or not worker.is_available() or worker.paused: return false
	if not worker.current_job_id.is_empty() or not worker.action.is_empty() or worker.work_action_held: return false
	if worker.carrying or worker.cargo_mass>0.0 or is_instance_valid(worker.carry_partner) or is_instance_valid(worker.brace_load) or is_instance_valid(worker.brace_leader): return false
	if is_instance_valid(worker.station) or is_instance_valid(worker.access_support) or worker.fear_time>0.0 or worker._reaction>.1: return false
	if worker.head_leap and worker.head_leap.active(): return false
	if worker.pickup and not worker.pickup.state.is_empty(): return false
	if worker.back_tool and worker.back_tool.busy(): return false
	# A retained tool may play only after its real native toss/catch seats it
	# on the back. Never sacrifice toe-tool clearance for an idle expression.
	if worker.tool_foot_occupied() or is_instance_valid(worker.equipped_gun): return false
	if worker.portable_gun and (worker.portable_gun.handoff_active() or worker.portable_gun.idle_stance_claim()): return false
	if not worker.needs.is_empty(): return false
	var pose: SkeletonModifier3D = worker._pose
	if not pose or not pose._work_release.is_empty() or pose._head_gait_continuation or pose._travel_tool_handoff or pose._travel_pole_handoff or pose._interrupted_handoff_side>=0: return false
	if pose._head_ground_continuation or pose._head_landing_continuation or pose._head_work_continuation: return false
	if pose._held_lift_time>0.0 or pose._held_lift>.001 or pose._held_shift.length_squared()>.00001: return false
	var personality: RefCounted = worker.personality
	if personality and personality.alert_weight>.001: return false
	if not is_instance_valid(worker.coordinator): return false
	var yard: Node3D = worker.coordinator.yard
	if not is_instance_valid(yard): return false
	# Field parking and an arrived rendezvous are actual exploration locations.
	# Only water intentions may use their quiet opening; ordinary solo
	# play retains its existing depot admission and useful jobs keep priority.
	var water_intention := water_only or _water_recovering or _water_active or state in ["water_search","water_route"]
	if yard.work_paused:
		# A public water visit is an explicit player choice after the ordinary
		# pause has physically recovered real jobs. Other idle play stays paused.
		if not water_intention or not yard.crew_travel_active() or not yard.crew_travel_worker(worker) \
				or yard.crew_travel_context().get("purpose")!="water": return false
	if yard.worksite_active():
		if not water_intention or not yard.worksite_worker(worker) or yard.worksite_context().has("reason"): return false
	if yard.crew_travel_active() and yard.crew_travel_worker(worker):
		var travel: Dictionary = yard.crew_travel_context()
		if not water_intention or travel.get("phase")!="arrived" or travel.get("arrived",0)!=travel.get("total",-1) or not str(travel.get("reason","")).is_empty(): return false
	if yard.unsafe_at(worker.global_position): return false
	# A bare restored/material lease still reserves this actual helper.
	var frame := Engine.get_physics_frames()
	if frame!=_reservation_frame:
		_reservation_frame = frame
		_reserved_for_work = false
		for key: Variant in yard._reservations:
			var reservation: Dictionary = yard._reservations[key]
			if reservation.get("workers",[]).has(worker.get_instance_id()):
				_reserved_for_work = true
				break
	return not _reserved_for_work

func available_for_play(water_only := false) -> bool:
	if not _free_of_obligations(water_only) or not state.is_empty() or _water_recovering or _jump_recovering or _pair_foot_active or not _pair.is_empty() or (paired_balance and paired_balance.active()) or (upside_down and upside_down.active()): return false
	# The already begun player hello owns its original one-second phrase and
	# finite fade before another optional idle activity asks for attention.
	# Existing useful-work, danger and native recovery admission stays live.
	var personality: RefCounted = worker.personality
	if personality and (personality.greeting_weight>.001 or (personality._greeting_active and personality.greeting_age<1.0)): return false
	if not worker.on_ground or is_instance_valid(worker._ground_body) or worker.ground_normal.y<.96: return false
	if not worker._pose.evaluated_valid or not worker._pose.evaluated_grounded[0] or not worker._pose.evaluated_grounded[1]: return false
	if worker.gait_speed>.12 or (worker.linear_velocity-worker.ground_velocity).length()>.18: return false
	if worker.has_target and (worker.target_position-worker.global_position).slide(Vector3.UP).length()>.22: return false
	return absf(worker.global_position.y-worker._ground_point.y-worker.ride_height)<.07

func idle_navigation_claim() -> bool:
	# The scheduler asks only after all real leases, danger, blocked jobs,
	# selected crew travel and portable-gun stance have had priority.
	return _water_recovering or _jump_recovering or _pair_foot_active or (paired_balance and paired_balance.active()) or (upside_down and upside_down.active()) or (not state.is_empty() and _free_of_obligations())

func water_navigation_claim() -> bool:
	# Native immersion/exit must finish even if new work or an invalid field
	# destination ends enjoyment. A dry intention still yields immediately.
	return _water_recovering or ((_water_active or state in ["water_search","water_route"]) and _free_of_obligations())

func speed_limit(ordinary: float) -> float:
	return _run_speed if state in ["run","water_run","water_return"] and _free_of_obligations() else ordinary

func physical_recovery_pending() -> bool:
	return _water_recovering or _jump_recovering or _pair_foot_active or (paired_balance and paired_balance.physical_recovery_pending()) or (upside_down and upside_down.physical_recovery_pending())

func cancel(reason: String) -> void:
	var playing := not state.is_empty() and not (_water_recovering and _water_interrupted)
	if upside_down and upside_down.active(): upside_down.cancel(reason)
	if paired_balance and paired_balance.active(): paired_balance.cancel(reason)
	if not _pair.is_empty(): _release_pair(reason)
	if playing:
		events.cancel += 1
		last_cancel = reason
		play_cancelled.emit(reason,state,int(events.cancel))
	if _water_recovering:
		# An already launched native body must finish physical recovery before
		# the scheduler lends it to work. Cancel enjoyment, never the motion.
		_water_interrupted = true
		_water_return_requested = true
		dance_weight = 0.0
		crouch_weight = 0.0
		_next_play = maxf(_next_play,7.0)
		return
	# Stop only this controller's unchanged idle target. A newer public/work
	# navigation target belongs to its original owner and is never erased.
	if state in ["run","water_run","water_return"] and worker.has_target and worker.target_position.distance_squared_to(_run_goal)<.0001: worker.stop_navigation()
	_route_candidates.clear()
	_route_goal = Vector3.INF
	_water_candidates.clear()
	_water_dry_route.clear()
	_water_active = false
	water_phase = "recover" if _jump_recovering else ""
	dance_weight = 0.0
	if not _jump_recovering:
		state = ""
		state_age = 0.0
		crouch_weight = 0.0
	if playing: _next_play = maxf(_next_play,_rng.randf_range(3.0,7.0))

func _choose_solo() -> void:
	_next_play = _rng.randf_range(9.0,23.0)/playfulness
	state_age = 0.0
	if _water_retry<=0.0 and _rng.randf()<.65:
		_water_retry = _rng.randf_range(18.0,35.0)
		_start_water_search()
		return
	if not _free_of_obligations(): return # Quiet field openings are water-only.
	var choice := _rng.randf()
	if choice<.24 and _try_pair(): return
	if choice<.47:
		state = "dance"
		state_duration = _rng.randf_range(2.2,4.2)
		# Finish one or two complete authored phrases under the original
		# 4.2 s cap, rather than fading halfway through a nod.
		var phrases := maxi(1,floori(state_duration*playfulness/IdlePose.DANCE_SECONDS))
		state_duration = phrases*IdlePose.DANCE_SECONDS/playfulness
		worker.stop_navigation()
		events.dance += 1
		_voice("play",-19.0)
	elif choice<.78:
		state = "route"
		_route_candidates.clear()
		_route_from = worker._ground_point
		_route_last = _route_from
		_route_goal = Vector3.INF
		for attempt in 5:
			var angle := _rng.randf_range(-PI,PI)
			var goal: Vector3 = _route_from+Vector3(sin(angle),0,cos(angle))*_rng.randf_range(2.75,3.3)
			if (goal-worker.safe_position).slide(Vector3.UP).length()<=PLAY_RADIUS: _route_candidates.append(goal)
		worker.stop_navigation()
	elif _jump_space_clear():
		state = "gather"
		state_duration = _rng.randf_range(.26,.36)
		worker.stop_navigation()

func _advance_solo(delta: float) -> void:
	state_age += delta
	if _water_active and _water_check_remaining<=0.0:
		_water_check_remaining = .25
		if not _water_dry_support(worker._ground_point): cancel("Shore support is no longer dry"); return
		if state!="water_return" and not _water_present(): cancel("Noticed water is no longer present"); return
	if state=="water_search":
		if not available_jump_support() or (_water_home-worker._ground_point).length()>.15: cancel("Water notice support changed"); return
		_advance_water_search()
	elif state=="water_route":
		if not worker.on_ground or is_instance_valid(worker._ground_body) or (_route_from-worker._ground_point).length()>.15: cancel("Shore starting support changed"); return
		_advance_route()
		if state_age>1.5: cancel("No clear dry shoreline route")
	elif state=="water_attention":
		# Looking at the admitted water uses the existing finite planted turn.
		# Let that genuine step finish before asking both soles to dance; the
		# expression and native launch retain their original contact guards.
		if not worker.on_ground or is_instance_valid(worker._ground_body) or (_water_home-worker._ground_point).length()>.15 or (worker.linear_velocity-worker.ground_velocity).length()>.3: cancel("Shore looking support changed"); return
		worker.face_point(_water_point)
		dance_weight = 0.0
		var facing: bool = absf(wrapf(worker._idle_heading-worker._heading,-PI,PI))<.08 and absf(worker.turn_rate)<.15
		var planted: bool = worker._pose.evaluated_valid and worker._pose.evaluated_grounded[0] and worker._pose.evaluated_grounded[1]
		_landing_age = _landing_age+delta if facing and planted else 0.0
		if _landing_age>.14:
			state = "water_excited"
			water_phase = "excited"
			state_age = 0.0
		elif state_age>1.5: cancel("Shore look did not regain both supported soles")
	elif state in ["water_excited","water_enjoy"]:
		if not worker.on_ground or is_instance_valid(worker._ground_body) or not worker._pose.evaluated_valid or not worker._pose.evaluated_grounded[0] or not worker._pose.evaluated_grounded[1] or (worker.linear_velocity-worker.ground_velocity).length()>.3: cancel("Shore expression support changed"); return
		worker.face_point(_water_point)
		dance_weight = .4*minf(smoothstep(0.0,.25,state_age),1.0-smoothstep(state_duration-.3,state_duration,state_age))
		if state_age>=state_duration:
			dance_weight = 0.0
			state = "water_run" if state=="water_excited" else "water_return"
			water_phase = "approach" if state=="water_run" else "return"
			if state=="water_return":
				_run_goal = _water_home
				_run_speed = worker.walk_speed
			else: events.water_approach += 1
			state_age = 0.0
			state_duration = 4.0
			worker.navigate_to(_run_goal)
	elif state=="water_settle":
		worker.face_point(_water_point)
		if available_jump_support() and state_age>.2 and _jump_space_clear():
			state = "gather"
			water_phase = "gather"
			state_age = 0.0
			state_duration = _rng.randf_range(.26,.36)
		elif state_age>2.0: cancel("Shore hop did not regain supported feet")
	elif state=="dance":
		if not worker.on_ground or worker.gait_speed>.2 or not worker._pose.evaluated_grounded[0] or not worker._pose.evaluated_grounded[1]: cancel("Dance support changed"); return
		# Keep the double nod readable, then release during its authored settle.
		# At the fastest original personality rate this remains slower than
		# the existing 4.5/s pose filter, so no new squat leaks into the tail.
		var settle_seconds := .425/playfulness
		dance_weight = minf(smoothstep(0.0,.42,state_age),1.0-smoothstep(state_duration-settle_seconds,state_duration,state_age))
		if state_age>=state_duration: state = ""
	elif state=="route":
		if not worker.on_ground or is_instance_valid(worker._ground_body) or (_route_from-worker._ground_point).length()>.15: cancel("Run starting support changed"); return
		_advance_route()
		if state_age>1.5: cancel("No clear supported idle run")
	elif state in ["run","water_run","water_return"]:
		if not worker.on_ground or is_instance_valid(worker._ground_body) or worker.navigation_blocked() or not worker.has_target or worker.target_position.distance_squared_to(_run_goal)>.0001: cancel("Idle run interrupted"); return
		if state!="run" and state_age>=state_duration and not worker.at_target(.22): cancel("Idle shore arrival timed out"); return
		if worker.at_target(.22) or (state=="run" and state_age>=state_duration):
			worker.stop_navigation()
			if state=="water_run":
				state = "water_settle"
				water_phase = "settle"
				state_age = 0.0
			else:
				if state=="water_return": events.water_return += 1
				state = ""
				_water_active = false
				water_phase = ""
				_voice("play",-20.0)
	elif state=="gather":
		if not available_jump_support() or not _jump_space_clear(): cancel("Jump support changed"); return
		crouch_weight = smoothstep(0.0,state_duration,state_age)
		if state_age<state_duration: return
		var relative: Vector3 = worker.linear_velocity-worker.ground_velocity
		var impulse: Vector3 = Vector3.UP*worker.mass*clampf(JUMP_SPEED-relative.y,0.0,JUMP_SPEED)
		if _water_active:
			var offset: Vector3 = (_water_hop_goal-worker._ground_point).slide(Vector3.UP)
			var wanted: Vector3 = offset/maxf(_water_flight_time,.1)
			impulse += (wanted-relative.slide(Vector3.UP)).limit_length(WATER_DIVE_SPEED)*worker.mass
			_water_launch_shore = worker._ground_point
			_water_recovering = true
			_water_return_requested = false
			_water_interrupted = false
			_water_entered = false
			_water_head_under = false
			_water_voice_surface_seen = false
			_water_swim_seen = false
			_water_motion_age = 0.0
			_water_exit_attempts = 0
			_water_exit_check = 0.0
			_start_water_buoyancy()
			water_phase = "launch"
			events.water_hop += 1
		if impulse.length_squared()<1.0: cancel("Jump launch declined"); return
		worker.apply_central_impulse(impulse)
		last_launch_impulse = impulse
		events.launch += 1
		_jump_recovering = true
		_airborne_seen = false
		_landing_age = 0.0
		state = "water_flight" if _water_recovering else "flight"
		state_age = 0.0
		if not _water_recovering: _voice("jump",-17.0)

func available_jump_support() -> bool:
	return worker.on_ground and worker.is_available() and not is_instance_valid(worker._ground_body) and worker.ground_normal.y>.97 \
		and worker._pose.evaluated_valid and worker._pose.evaluated_grounded[0] and worker._pose.evaluated_grounded[1] \
		and (worker.linear_velocity-worker.ground_velocity).length()<.2

func _advance_jump(delta: float) -> void:
	state_age += delta
	if _water_active and not _free_of_obligations(): cancel("Shore hop interrupted; native landing continues")
	dance_weight = 0.0
	crouch_weight = move_toward(crouch_weight,0.0,delta*4.5)
	if not worker.is_available():
		# The existing native ragdoll now owns the same body/legs and recovery.
		_jump_recovering = false
		cancel("Native fall recovery took ownership")
		return
	if not worker.on_ground and not _airborne_seen:
		_airborne_seen = true
		events.airborne += 1
	var settled: bool = worker.on_ground and worker._pose.evaluated_valid \
		and worker._pose.evaluated_grounded[0] and worker._pose.evaluated_grounded[1] \
		and absf(worker.global_position.y-worker._ground_point.y-worker.ride_height)<.075 \
		and (worker.linear_velocity-worker.ground_velocity).length()<.25
	# The spring-foot controller's actual published sole support and native
	# body settling end the jump. A timer alone never declares a landing.
	if settled and state_age>.45:
		if state!="landing":
			state = "landing"
			_landing_age = 0.0
		_landing_age += delta
	else:
		_landing_age = 0.0
	if _landing_age>.14:
		if _airborne_seen: events.land += 1
		_jump_recovering = false
		state = ""
		state_age = 0.0
		crouch_weight = 0.0
		if _water_active and _airborne_seen and _free_of_obligations() and _water_dry_support(worker._ground_point):
			events.water_land += 1
			state = "water_enjoy"
			water_phase = "enjoy"
			state_duration = _rng.randf_range(.9,1.5)
		else:
			_water_active = false
			water_phase = ""
		_next_play = maxf(_next_play,_rng.randf_range(5.0,12.0))

func _jump_space_clear() -> bool:
	if not available_jump_support(): return false
	if _water_active: return _water_hop_clear()
	_clearance.exclude = worker.query_exclusions()
	for height: float in [.2,.45,.7]:
		_clearance.transform = Transform3D(Basis.IDENTITY,worker.global_position+Vector3.UP*(.2+height))
		if not worker.get_world_3d().direct_space_state.intersect_shape(_clearance,1).is_empty(): return false
	return true

func _advance_route() -> void:
	_ray.exclude = worker.query_exclusions()
	_ray.collision_mask = 1
	_clearance.exclude = worker.query_exclusions()
	# At most three floor/headroom samples each native tick; no unbounded idle
	# route search or whole-yard scan on a single frame.
	for sample in 3:
		if not _route_goal.is_finite():
			if _route_candidates.is_empty(): cancel("No clear supported idle run"); return
			_route_goal = _route_candidates.pop_front()
			_route_last = _route_from
			_route_steps = maxi(1,ceili((_route_goal-_route_from).slide(Vector3.UP).length()/.3))
			_route_step = 0
		_route_step += 1
		var point := _route_from.lerp(_route_goal,float(_route_step)/_route_steps)
		_ray.from = Vector3(point.x,_route_last.y+.55,point.z)
		_ray.to = Vector3(point.x,_route_last.y-.55,point.z)
		var hit := worker.get_world_3d().direct_space_state.intersect_ray(_ray)
		if hit.is_empty() or hit.collider is RigidBody3D:
			_route_goal = Vector3.INF
			continue
		point = hit.position
		if hit.normal.y<(.64 if _water_active else .96):
			if _water_active and point.y<_route_last.y:
				_finish_water_route()
				return
			_route_goal = Vector3.INF
			continue
		if _water_active:
			if worker.coordinator.yard.unsafe_at(point): _route_goal = Vector3.INF; continue
			var height := Water.height_at(point,worker.get_instance_id()*4096+68)
			if is_finite(height) and height>point.y+.015:
				_finish_water_route()
				return
			# A real bank can descend before the water owner's polygon starts.
			# Stop the walking route on its last complete dry support footprint;
			# the noticed immersed floor remains the actual swept dive target.
			if hit.normal.y<.96 or absf(point.y-_route_last.y)>.075:
				_finish_water_route()
				return
		if absf(point.y-_route_last.y)>.075 or worker.coordinator.yard.unsafe_at(point):
			_route_goal = Vector3.INF
			continue
		_clearance.transform = Transform3D(Basis.IDENTITY,point+Vector3.UP*(worker.ride_height+.2))
		if not worker.get_world_3d().direct_space_state.intersect_shape(_clearance,1).is_empty():
			_route_goal = Vector3.INF
			continue
		if _water_active: _water_dry_route.append(point)
		_route_last = point
		if _route_step<_route_steps: continue
		if _water_active: cancel("No wet terrain at the noticed surface"); return
		_run_goal = point
		_run_speed = _rng.randf_range(3.05,3.4)
		state = "run"
		state_age = 0.0
		state_duration = 3.5
		_route_candidates.clear()
		_route_goal = Vector3.INF
		events.run += 1
		worker.navigate_to(_run_goal)
		return

func _finish_water_route() -> bool:
	if _water_dry_route.size()<4: cancel("Shore is too close for a supported approach"); return false
	_run_goal = _water_dry_route[-2]
	_water_hop_goal = _water_floor
	if (_water_hop_goal-_run_goal).slide(Vector3.UP).length()>WATER_DIVE_RANGE: cancel("Deep water is beyond a finite local dive"); return false
	if (_run_goal-_water_home).slide(Vector3.UP).length()<.8: cancel("Shore has no room for a real approach"); return false
	_run_speed = _rng.randf_range(3.05,3.4)
	state = "water_attention"
	water_phase = "look"
	state_age = 0.0
	_landing_age = 0.0
	state_duration = _rng.randf_range(.52,.62)
	_route_candidates.clear()
	_route_goal = Vector3.INF
	events.water_notice += 1
	_water_voice("notice")
	return true

func _start_water_search() -> void:
	state = "water_search"
	water_phase = "search"
	_water_active = false
	_water_home = worker._ground_point
	_water_candidates.clear()
	# A public shore visit directs the original crew's ordinary attention.
	# Treat its actual admitted water as one local search proposal only; every
	# native/live-water admission remains in _advance_water_search below.
	var hinted:Vector3=worker.coordinator.yard._crew_travel.water_notice_point(worker)
	if hinted.is_finite():
		var offset:Vector3=(hinted-_water_home).slide(Vector3.UP)
		if offset.length()<=WATER_PLAY_RADIUS:
			var candidate:Vector3=_water_home+offset.limit_length(WATER_NOTICE_RADIUS)
			if (candidate-worker.safe_position).slide(Vector3.UP).length()<=WATER_PLAY_RADIUS: _water_candidates.append(candidate)
	# A finite local look on the existing idle cadence, not an Island/body scan.
	var start := _rng.randf_range(-PI,PI)
	for sample in 8:
		var angle := start+float(sample)*TAU/8.0
		var candidate := _water_home+Vector3(sin(angle),0,cos(angle))*WATER_NOTICE_RADIUS
		if (candidate-worker.safe_position).slide(Vector3.UP).length()<=WATER_PLAY_RADIUS: _water_candidates.append(candidate)
	worker.stop_navigation()

func _advance_water_search() -> void:
	if _water_candidates.is_empty():
		state = ""
		water_phase = ""
		_next_play = minf(_next_play,_rng.randf_range(2.0,4.0))
		return
	var point: Vector3 = _water_candidates.pop_front()
	_ray.exclude = worker.query_exclusions()
	_ray.collision_mask = 1
	_ray.from = point+Vector3.UP*.55
	_ray.to = point-Vector3.UP*2.0
	var hit := worker.get_world_3d().direct_space_state.intersect_ray(_ray)
	if hit.is_empty() or hit.normal.y<.64 or hit.collider is RigidBody3D: return
	point = hit.position
	var owner: Object = Water.body_at(point)
	var height := Water.height_at(point,worker.get_instance_id()*4096+67)
	# Ocean owns queries under dry land too. Water must really lie ABOVE this
	# native terrain, within a bounded shallow plunge, rather than below it.
	if not _live_water_owner(owner) or not is_finite(height) or height-point.y<WATER_DEPTH_MIN or height-point.y>WATER_DEPTH_MAX: return
	# A shallow target must support the actual four displacement probes and
	# leave the original capsule clear at its measured calm equilibrium. A
	# polygon-tip query with half its probes outside water cannot float this
	# unchanged finite body, even though its centre names a live lake owner.
	var floating := Vector3(point.x,height-.506,point.z)
	for probe: Vector3 in [Vector3(-.15,.2,-.15),Vector3(.15,.2,-.15),Vector3(-.15,.2,.15),Vector3(.15,.2,.15)]:
		if Water.body_at(floating+worker.global_basis*probe)!=owner: return
	var collision: CollisionShape3D = worker.get_node("Collision")
	_water_clearance.shape = collision.shape
	_water_clearance.exclude = worker.query_exclusions()
	_water_clearance.collision_mask = worker.collision_mask
	_water_clearance.transform = Transform3D(worker.global_basis,floating)*collision.transform
	if not worker.get_world_3d().direct_space_state.intersect_shape(_water_clearance,1).is_empty(): return
	var surface := Vector3(point.x,height+.04,point.z)
	_ray.collision_mask = worker.collision_mask
	_ray.from = worker._visual_head_point if worker._visual_head_point.is_finite() else worker.global_position+Vector3.UP*.3
	_ray.to = surface
	if not worker.get_world_3d().direct_space_state.intersect_ray(_ray).is_empty(): return
	_water_owner = weakref(owner)
	_water_point = surface
	_water_floor = point
	_water_active = true
	_water_check_remaining = .25
	_water_candidates.clear()
	_water_dry_route.clear()
	_water_dry_route.append(_water_home)
	_route_candidates.clear()
	_route_candidates.append(point)
	_route_from = _water_home
	_route_goal = Vector3.INF
	state = "water_route"
	water_phase = "qualify"
	state_age = 0.0

func _water_present() -> bool:
	var owner: Object = _water_owner.get_ref() if _water_owner else null
	if not _live_water_owner(owner) or Water.body_at(_water_floor)!=owner: return false
	var height := Water.height_at(_water_floor,worker.get_instance_id()*4096+67)
	if not is_finite(height) or height-_water_floor.y<WATER_DEPTH_MIN or height-_water_floor.y>WATER_DEPTH_MAX: return false
	_water_point.y = height+.04
	return true

func _water_hop_clear() -> bool:
	if not _water_present() or not _water_dry_support(worker._ground_point): return false
	if worker._ground_point.y-_water_point.y>.3: return false
	var offset: Vector3 = (_water_hop_goal-worker._ground_point).slide(Vector3.UP)
	if offset.length()<.2 or offset.length()>WATER_DIVE_RANGE: return false
	var flow := Water.velocity_at(_water_floor,worker.get_instance_id()*4096+70)
	if not flow.is_finite() or flow.length()>.6: return false
	var collision: CollisionShape3D = worker.get_node("Collision")
	var body_bounds: AABB = collision.transform*collision.shape.get_debug_mesh().get_aabb()
	var gravity := maxf(worker.get_gravity().length(),9.8)
	# Reach the admitted water point when the original capsule first enters it.
	# A later centre-below-water aim can reacquire a shallow bank's foot ray.
	var drop := worker.global_position.y-_water_point.y+body_bounds.position.y
	if drop<=0.0: return false
	_water_flight_time = (JUMP_SPEED+sqrt(JUMP_SPEED*JUMP_SPEED+2.0*gravity*drop))/gravity
	var wanted: Vector3 = offset/_water_flight_time
	if wanted.length()>WATER_DIVE_SPEED: return false
	_water_clearance.exclude = worker.query_exclusions()
	_water_clearance.collision_mask = worker.collision_mask
	# Query the original capsule at actual ballistic samples. The native body
	# then supplies every movement/impact; this does not install a trajectory.
	_water_clearance.shape = collision.shape
	for sample in 5:
		var t := _water_flight_time*float(sample+1)/5.0
		var center: Vector3 = worker.global_position+wanted*t+Vector3.UP*(JUMP_SPEED*t-.5*gravity*t*t)
		_water_clearance.transform = Transform3D(worker.global_basis,center)*collision.transform
		if not worker.get_world_3d().direct_space_state.intersect_shape(_water_clearance,1).is_empty(): return false
	return true

func _water_dry_support(point: Vector3) -> bool:
	var height := Water.height_at(point,worker.get_instance_id()*4096+69)
	return not is_finite(height) or height<=point.y+.015

func _live_water_owner(owner: Object) -> bool:
	var body := owner as Node
	return is_instance_valid(body) and body.is_inside_tree() and not body.is_queued_for_deletion()

func _start_water_buoyancy() -> void:
	if not is_instance_valid(_water_buoy):
		_water_buoy = WaterBuoyancy.new()
		_water_buoy.name = "IdleWaterBuoyancy"
		# Four slices of the original capsule's finite volume. The real body
		# mass (including its seated tool) is displaced once, never replaced.
		var probes: Array[Vector3] = [Vector3(-.15,.2,-.15),Vector3(.15,.2,-.15),Vector3(-.15,.2,.15),Vector3(.15,.2,.15)]
		_water_buoy.probes = probes
		_water_buoy.volume = worker.mass/1025.0*1.25
		_water_buoy.drag = 1.8
		_water_buoy.vertical_drag = 8.0
		_water_buoy.wake_coupling = 0.0
		_water_buoy.entered_water.connect(_on_water_entry)
		worker.add_child(_water_buoy)
	var actual_volume: float = worker.mass/1025.0*1.25
	if _water_buoy.volume!=actual_volume:
		_water_buoy.volume = actual_volume
		_water_buoy._setup()
	_water_buoy.set_physics_process(true)

func _stop_water_buoyancy() -> void:
	# This force component belongs only to the current finite water motion.
	# Retire it so shared WaterInteraction cannot replay its latched wet
	# probes with a dry body's later velocity. Original bodies stay intact.
	if is_instance_valid(_water_buoy):
		_water_buoy.set_physics_process(false)
		_water_buoy.queue_free()
	_water_buoy = null

func _on_water_entry(_speed: float) -> void:
	if not _water_recovering or _water_entered: return
	_water_entered = true
	events.water_enter += 1
	# Buoyancy emits only after its real Water queries immerse a probe slice.
	# No expression phase or timeout can manufacture this transition.
	state = "water_swim_return" if _water_return_requested else "water_swim"
	water_phase = "return" if _water_return_requested else "dive"
	state_age = 0.0
	state_duration = _rng.randf_range(2.4,3.4)

func water_support_active() -> bool:
	var frame := Engine.get_physics_frames()
	if frame==_water_support_frame: return _water_support_cached
	_water_support_frame = frame
	_water_support_cached = _water_support_now()
	return _water_support_cached

func _water_support_now() -> bool:
	if not _water_recovering or state=="water_native_recover": return false
	var owner: Object = _water_owner.get_ref() if _water_owner else null
	if not _live_water_owner(owner) or Water.body_at(worker.global_position)!=owner: return false
	var h := Water.height_at(worker.global_position,worker.get_instance_id()*4096+71)
	# The original Collision capsule has centre +.2 and half-height .51.
	# Its actual lower cap must meet water before land forces are suppressed.
	return is_finite(h) and h>worker.global_position.y-.31

func water_ballistic_flight() -> bool:
	if not _water_recovering or state not in ["water_flight","water_exit_flight"]: return false
	# Preserve the already checked finite impulse through its short ballistic
	# window. Ordinary dry movement still brakes normally, including a missed
	# dive after this window. No extra impulse or propulsion is supplied here.
	if state_age>_water_flight_time+.04: return false
	if state=="water_exit_flight" and worker.on_ground and _water_dry_support(worker._ground_point) \
			and (worker._ground_point-_water_launch_shore).slide(Vector3.UP).length()<.6: return false
	return true

func _water_motion_settled() -> bool:
	return worker.on_ground and worker._pose.evaluated_valid \
		and worker._pose.evaluated_grounded[0] and worker._pose.evaluated_grounded[1] \
		and absf(worker.global_position.y-worker._ground_point.y-worker.ride_height)<.075 \
		and (worker.linear_velocity-worker.ground_velocity).length()<.25

func _advance_water_motion(delta: float) -> void:
	state_age += delta
	_water_motion_age += delta
	_water_exit_check = maxf(0.0,_water_exit_check-delta)
	crouch_weight = move_toward(crouch_weight,0.0,delta*4.5)
	dance_weight = 0.0
	last_water_force = Vector3.ZERO
	if not worker.is_available():
		# A real impact may hand the same body to the existing native ragdoll.
		_finish_water_motion(false,"Native fall recovery took water ownership")
		return
	# The scheduler retains physical recovery before lending this same body
	# to a job. Its real pending queue must still end water enjoyment now.
	var useful_work_waiting: bool = _water_entered and not worker.coordinator.yard.work_paused and not worker.coordinator._jobs.is_empty()
	if not _water_interrupted and (useful_work_waiting or not _free_of_obligations()):
		cancel("Water play interrupted; returning to the real shore")
	if not worker.on_ground and not _airborne_seen:
		_airborne_seen = true
		events.airborne += 1
	var owner: Object = _water_owner.get_ref() if _water_owner else null
	var changed_owner := _water_entered and state not in ["water_exit_flight","water_native_recover"] and Water.body_at(worker.global_position)!=owner
	if (not _live_water_owner(owner) or changed_owner) and state!="water_native_recover":
		cancel("Water disappeared; native supported recovery continues")
		state = "water_native_recover"
		water_phase = "recover"
		state_age = 0.0
		_stop_water_buoyancy()
	_observe_water_voice_surface()
	if state in ["water_exit_flight","water_native_recover"]:
		water_dive_weight = move_toward(water_dive_weight,0.0,delta*3.5)
		water_swim_weight = move_toward(water_swim_weight,0.0,delta*3.5)
		if _water_motion_settled(): _landing_age += delta
		else: _landing_age = 0.0
		if _landing_age>.14:
			var dry := _water_dry_support(worker._ground_point)
			for sole: Vector3 in worker._pose.evaluated_soles:
				dry = dry and _water_dry_support(sole)
			_finish_water_motion(dry,"Native shallow-bed support regained" if not dry else "")
			return
		# A newly blocked real exit can fall back into the same water. Restore
		# flotation rather than calling the failed flight a supported landing.
		if state=="water_exit_flight" and state_age>.9 and _water_exit_attempts<2:
			var h := Water.height_at(worker.global_position,worker.get_instance_id()*4096+71)
			if is_finite(h) and h>worker.global_position.y-.31 and not worker.on_ground:
				_start_water_buoyancy()
				state = "water_swim_return"
				water_phase = "return"
				state_age = 0.0
				_water_exit_check = .5
		return
	if not _water_entered:
		water_dive_weight = move_toward(water_dive_weight,.95 if _airborne_seen and worker.linear_velocity.y<.5 else .2,delta*3.5)
		water_swim_weight = 0.0
		# A declined/obstructed launch still completes the original supported
		# landing. No teleport, water phase assignment or forced wet state.
		if state_age>1.5 and _water_motion_settled():
			_finish_water_motion(false,"Dive did not reach real water")
		return
	water_immersion = float(_water_buoy.submerged) if is_instance_valid(_water_buoy) else 0.0
	var sample := Water.sample_at(worker.global_position,worker.get_instance_id()*4096+72)
	var height: float = sample.height
	var flow: Vector3 = sample.velocity
	if not is_finite(height) or not flow.is_finite():
		cancel("Water surface changed; native supported recovery continues")
		state = "water_native_recover"
		water_phase = "recover"
		_stop_water_buoyancy()
		return
	var head: Vector3 = worker._visual_head_point
	if head.is_finite() and not _water_head_under:
		var head_height := Water.height_at(head,worker.get_instance_id()*4096+73)
		if is_finite(head_height) and head_height>head.y+.04:
			_water_head_under = true
			events.water_dive += 1
			_water_voice("dive")
	# Entry momentum dips the real body/head; no extra downward impulse.
	water_dive_weight = move_toward(water_dive_weight,.85*(1.0-smoothstep(.25,.8,state_age)) if state=="water_swim" else 0.0,delta*3.5)
	water_swim_weight = move_toward(water_swim_weight,clampf(water_immersion,0.0,1.0)*(1.0-water_dive_weight),delta*3.5)
	if state=="water_swim" and (state_age>=state_duration or _water_return_requested):
		state = "water_swim_return"
		water_phase = "return"
		state_age = 0.0
		_water_return_requested = true
	var return_swim := state=="water_swim_return"
	var tangent := (_water_floor-_water_launch_shore).slide(Vector3.UP).normalized().cross(Vector3.UP)
	var goal := _water_launch_shore if return_swim else _water_floor+tangent*(sin(state_age*TAU*.55)*.22)
	var offset := (goal-worker.global_position).slide(Vector3.UP)
	var desired := offset.normalized()*minf(offset.length()*2.0,1.25 if return_swim else .65)
	var relative := (worker.linear_velocity-flow).slide(Vector3.UP)
	# Stroke force exists only in actually immersed water, independently of
	# optional animation and expression. Shared Buoyancy handles lift/drag.
	last_water_force = ((desired-relative)*worker.mass*3.0).limit_length(worker.mass*3.5)*clampf(water_immersion,0.0,1.0)
	worker.apply_central_force(last_water_force)
	worker.face_point(goal)
	if water_immersion>.25 and last_water_force.length()>.5 and not _water_swim_seen:
		_water_swim_seen = true
		events.water_swim += 1
	if return_swim and _water_exit_check<=0.0:
		_water_exit_check = .2
		_try_water_shore_exit()
	# Assistance is finite even if a new obstacle removes the checked bank.
	# Re-enable the original spring-foot controller over the admitted shallow
	# native bed; it must really settle before releasing the helper to work.
	if _water_motion_age>14.0 and state!="water_exit_flight":
		cancel("Shore exit blocked; settling on the real shallow bed")
		state = "water_native_recover"
		water_phase = "recover"
		state_age = 0.0
		_stop_water_buoyancy()

func _try_water_shore_exit() -> bool:
	if _water_exit_attempts>=2 or not _water_launch_shore.is_finite(): return false
	var offset := (_water_launch_shore-worker.global_position).slide(Vector3.UP)
	if offset.length()<.1 or offset.length()>WATER_DIVE_RANGE: return false
	_ray.exclude = worker.query_exclusions()
	_ray.collision_mask = 1
	_ray.from = _water_launch_shore+Vector3.UP*.15
	_ray.to = _water_launch_shore-Vector3.UP*.15
	var hit := worker.get_world_3d().direct_space_state.intersect_ray(_ray)
	if hit.is_empty() or hit.normal.y<.97 or hit.collider is RigidBody3D: return false
	if not _water_dry_support(hit.position) or worker.coordinator.yard.unsafe_at(hit.position): return false
	var target: Vector3 = hit.position+Vector3.UP*(worker.ride_height+.06)
	var lift := target.y-worker.global_position.y
	if lift<.1 or lift>1.85: return false
	var gravity := maxf(worker.get_gravity().length(),9.8)
	# Same finite ballistic shore-hop principle as player_swim.gd. The
	# original idle jump cap stays 3.35; a bank exit pays this measured lift.
	var takeoff := sqrt(2.0*gravity*(lift+.15))
	var duration := (takeoff+sqrt(maxf(takeoff*takeoff-2.0*gravity*lift,0.0)))/gravity
	var wanted := offset/duration
	if wanted.length()>WATER_DIVE_SPEED: return false
	# The capsule sweep must describe the native velocity this finite impulse
	# can actually produce. An early work cancellation can still be descending
	# or travelling outwards too fast; let real buoyancy/strokes settle it first.
	var velocity: Vector3 = worker.linear_velocity
	if takeoff-velocity.y<0.0 or takeoff-velocity.y>6.3 \
			or (wanted-velocity.slide(Vector3.UP)).length()>WATER_DIVE_SPEED: return false
	var collision: CollisionShape3D = worker.get_node("Collision")
	_water_clearance.shape = collision.shape
	_water_clearance.collision_mask = worker.collision_mask
	_water_clearance.exclude = worker.query_exclusions()
	for index in 5:
		var t := duration*float(index+1)/5.0
		var center := worker.global_position+wanted*t+Vector3.UP*(takeoff*t-.5*gravity*t*t)
		_water_clearance.transform = Transform3D(worker.global_basis,center)*collision.transform
		if not worker.get_world_3d().direct_space_state.intersect_shape(_water_clearance,1).is_empty(): return false
	last_water_exit_impulse = (Vector3.UP*clampf(takeoff-velocity.y,0.0,6.3)+(wanted-velocity.slide(Vector3.UP)).limit_length(WATER_DIVE_SPEED))*worker.mass
	worker.apply_central_impulse(last_water_exit_impulse)
	_stop_water_buoyancy()
	_water_exit_target = target
	_water_flight_time = duration
	_water_exit_attempts += 1
	events.water_exit += 1
	state = "water_exit_flight"
	water_phase = "exit"
	state_age = 0.0
	_landing_age = 0.0
	return true

func _finish_water_motion(returned: bool, reason: String) -> void:
	# Native support on a dry polygon edge is recovery, but is not a completed
	# trip to the original checked shore. Preserve that distinction in events.
	returned = returned and (worker.global_position-_water_launch_shore).slide(Vector3.UP).length()<.4
	_stop_water_buoyancy()
	if returned:
		events.water_return += 1
		if _airborne_seen: events.land += 1; events.water_land += 1
	elif not reason.is_empty():
		last_cancel = reason
	_water_recovering = false
	_jump_recovering = false
	_water_active = false
	_water_return_requested = false
	_water_interrupted = false
	water_phase = ""
	state = ""
	state_age = 0.0
	water_dive_weight = 0.0
	water_swim_weight = 0.0
	water_immersion = 0.0
	last_water_force = Vector3.ZERO
	crouch_weight = 0.0
	_landing_age = 0.0
	_next_play = maxf(_next_play,_rng.randf_range(5.0,12.0))

func _water_voice(phase: String) -> void:
	if worker.personality: worker.personality.water_voice_cue(phase)

func _observe_water_voice_surface() -> void:
	# The actual evaluated head must first have crossed below this live owner.
	# Crossing back above its local surface triggers at most one quiet cue.
	if not _water_entered or not _water_head_under or _water_voice_surface_seen or _water_interrupted: return
	var head: Vector3 = worker._visual_head_point
	if not head.is_finite(): return
	var height := Water.height_at(head,worker.get_instance_id()*4096+73)
	if is_finite(height) and head.y>height+.025:
		_water_voice_surface_seen = true
		_water_voice("surface")

func _voice(kind: String, volume: float) -> void:
	# Share the existing sparse personality voice channel and PCM bank.
	if worker.personality: worker.personality._play_voice(kind,volume)

func _pair_peer() -> RigidBody3D:
	if _pair.is_empty(): return null
	var first: RigidBody3D = _pair.a.get_ref()
	var second: RigidBody3D = _pair.b.get_ref()
	return second if first==worker else first

func _try_pair() -> bool:
	if not available_for_play(): return false
	if not is_instance_valid(_pair_modifier) or not _pair_modifier.native_geometry_ready: return false
	if not worker.axis_lock_angular_x or not worker.axis_lock_angular_y or not worker.axis_lock_angular_z: return false
	var peer: RigidBody3D
	var nearest := 3.1*3.1
	var examined := 0
	for candidate: RigidBody3D in worker.coordinator.workers:
		examined += 1
		if examined>16: break
		if candidate==worker or not is_instance_valid(candidate) or not candidate.idle_play or not candidate.idle_play.available_for_play(): continue
		if not is_instance_valid(candidate.idle_play._pair_modifier) or not candidate.idle_play._pair_modifier.native_geometry_ready: continue
		if not candidate.axis_lock_angular_x or not candidate.axis_lock_angular_y or not candidate.axis_lock_angular_z: continue
		var squared: float = (candidate.global_position-worker.global_position).slide(Vector3.UP).length_squared()
		if squared<1.1*1.1 or squared>=nearest or absf(candidate._ground_point.y-worker._ground_point.y)>.06: continue
		peer = candidate
		nearest = squared
	if not peer or not _jump_space_clear() or not peer.idle_play._jump_space_clear(): return false
	var direction: Vector3 = (peer.global_position-worker.global_position).slide(Vector3.UP).normalized()
	var centre: Vector3 = (peer._ground_point+worker._ground_point)*.5
	var goals: Array[Vector3] = [centre-direction*.61,centre+direction*.61]
	var actors: Array[RigidBody3D] = [worker,peer]
	for index in 2:
		if (goals[index]-actors[index].safe_position).slide(Vector3.UP).length()>PLAY_RADIUS: return false
	_pair = {"a":weakref(worker),"b":weakref(peer),"age":0.0,"stage_age":0.0,"stage":"route","frame":-1,"contact":false,"contact_age":0.0,"goals":goals,"launch_serials":[-1,-1],"route_ready":[false,false],"settled":0.0}
	peer.idle_play._pair = _pair
	for index in 2:
		var actor: RigidBody3D = actors[index]
		var director: RefCounted = actor.idle_play
		director.state = "pair_invite"
		director.state_age = 0.0
		director.events.pair_invite += 1
		director._pair_route_from = actor._ground_point
		director._pair_route_last = actor._ground_point
		director._pair_route_steps = maxi(1,ceili((goals[index]-actor._ground_point).length()/.3))
		director._pair_route_step = 0
		actor.stop_navigation()
	return true

func _advance_pair_route(index: int) -> void:
	var goal: Vector3 = _pair.goals[index]
	_ray.exclude = worker.query_exclusions()
	_ray.collision_mask = 1
	_clearance.exclude = worker.query_exclusions()
	for sample in 3:
		_pair_route_step += 1
		var point := _pair_route_from.lerp(goal,float(_pair_route_step)/_pair_route_steps)
		_ray.from = Vector3(point.x,_pair_route_last.y+.55,point.z)
		_ray.to = Vector3(point.x,_pair_route_last.y-.55,point.z)
		var hit := worker.get_world_3d().direct_space_state.intersect_ray(_ray)
		if hit.is_empty() or hit.collider is RigidBody3D or hit.normal.y<.96 or absf(hit.position.y-_pair_route_last.y)>.075 or worker.coordinator.yard.unsafe_at(hit.position): cancel("Paired approach has no clear supported route"); return
		point = hit.position
		_clearance.transform = Transform3D(Basis.IDENTITY,point+Vector3.UP*(worker.ride_height+.2))
		if not worker.get_world_3d().direct_space_state.intersect_shape(_clearance,1).is_empty(): cancel("Paired approach has no native body clearance"); return
		_pair_route_last = point
		if _pair_route_step>=_pair_route_steps:
			_pair.goals[index] = point
			_pair.route_ready[index] = true
			return

func _prepare_pair(peer: RigidBody3D) -> bool:
	var point: Vector3 = (worker._ground_point+peer._ground_point)*.5
	var hip_height: float = (worker.evaluated_hip(0).y+worker.evaluated_hip(1).y+peer.evaluated_hip(0).y+peer.evaluated_hip(1).y)*.25
	point.y += clampf(hip_height-point.y+.28,.78,1.05)
	var direction: Vector3 = (peer.global_position-worker.global_position).slide(Vector3.UP).normalized()
	for actor: RigidBody3D in [worker,peer]:
		var director: RefCounted = actor.idle_play
		var normal: Vector3 = direction if actor==worker else -direction
		var chosen := -1
		var margin := .035
		for side in 2:
			var ankle: Vector3 = point-normal*float(actor._pose._ankle_height[side])
			var remaining: float = actor._leg_lengths[side]-.012-actor.evaluated_hip(side).distance_to(ankle)
			if remaining>margin: chosen = side; margin = remaining
		if chosen<0: return false
		director._pair_side = chosen
		director._pair_point = point
		director._pair_normal = normal
		var rebase: Transform3D = actor.global_transform*actor._pose.evaluated_worker.affine_inverse()
		director._pair_start_basis = rebase.basis*actor._pose.evaluated_ankles[chosen]
	return true

func _advance_pair(delta: float) -> void:
	if _jump_recovering: _advance_jump(delta)
	if not _free_of_obligations(): cancel("Useful work or danger interrupts paired play"); return
	var peer := _pair_peer()
	if not is_instance_valid(peer) or not peer.idle_play or peer.idle_play._pair.is_empty() or not peer.idle_play._free_of_obligations(): cancel("Paired helper became unavailable"); return
	if not is_instance_valid(_pair_modifier) or not is_instance_valid(peer.idle_play._pair_modifier): cancel("Paired foot geometry owner became unavailable"); return
	if _pair.stage!="route": worker.face_point(peer.global_position)
	var index := 0 if _pair.a.get_ref()==worker else 1
	if _pair.stage=="route" and not _pair.route_ready[index]:
		if not available_jump_support() or (worker._ground_point-_pair_route_from).length()>.15: cancel("Paired route starting support changed"); return
		_advance_pair_route(index)
		if _pair.is_empty(): return
	var frame := Engine.get_physics_frames()
	if int(_pair.frame)==frame: return
	_pair.frame = frame
	_pair.age += delta
	_pair.stage_age += delta
	var actors: Array[RigidBody3D] = [_pair.a.get_ref(),_pair.b.get_ref()]
	if float(_pair.age)>12.0: cancel("Paired play waits for actual supported landing"); return
	if _pair.stage=="route":
		if _pair.route_ready.all(func(ready:bool)->bool:return ready):
			_pair.stage = "approach"
			_pair.stage_age = 0.0
			for actor_index in 2: actors[actor_index].navigate_to(_pair.goals[actor_index])
		elif float(_pair.stage_age)>1.5: cancel("Paired route did not find supported footing")
	elif _pair.stage=="approach":
		var arrived := true
		for actor_index in 2:
			var actor: RigidBody3D = actors[actor_index]
			if not actor.on_ground or is_instance_valid(actor._ground_body) or actor.navigation_blocked() or not actor.has_target or actor.target_position.distance_squared_to(_pair.goals[actor_index])>.0001: cancel("Paired approach interrupted"); return
			arrived = arrived and actor.at_target(.13) and (actor.linear_velocity-actor.ground_velocity).length()<.2
		_pair.settled = float(_pair.settled)+delta if arrived else 0.0
		if float(_pair.settled)>.14:
			_pair.stage = "invite"
			_pair.stage_age = 0.0
			for actor: RigidBody3D in actors: actor.stop_navigation()
		elif float(_pair.stage_age)>4.0: cancel("Paired approach did not settle")
	elif _pair.stage in ["invite","gather"]:
		# Ordinary supported turning owns both planted feet; only a settled
		# evaluated preparation permits the one native impulse on each body.
		for actor_index in 2: actors[actor_index].face_point(actors[1-actor_index].global_position)
		if not available_jump_support() or not peer.idle_play.available_jump_support():
			if float(_pair.stage_age)>2.5: cancel("Paired greeting lost original sole support")
			return
		var direction: Vector3 = (peer.global_position-worker.global_position).slide(Vector3.UP).normalized()
		var aligned: bool = (-worker._model.global_basis.z).dot(direction)>.97 and (-peer._model.global_basis.z).dot(-direction)>.97
		var facing: bool = aligned and absf(worker.turn_rate)<.25 and absf(peer.turn_rate)<.25
		if _pair.stage=="invite":
			if facing:
				if not _prepare_pair(peer): cancel("Original paired feet cannot reach the meeting"); return
				_pair.stage = "gather"
				_pair.stage_age = 0.0
				for actor: RigidBody3D in actors:
					actor.idle_play.state = "pair_gather"
					actor.idle_play._pair_modifier.capture()
			elif float(_pair.stage_age)>2.5: cancel("Paired greeting did not face its neighbour")
		else:
			for actor: RigidBody3D in actors: actor.idle_play.crouch_weight = smoothstep(0.0,.22,float(_pair.stage_age))
			if float(_pair.stage_age)<.32 or not actors.all(func(actor:RigidBody3D)->bool:return actor.idle_play._pair_modifier.capture_ready): return
			if not aligned or not _jump_space_clear() or not peer.idle_play._jump_space_clear() or not _prepare_pair(peer): cancel("Paired launch clearance changed"); return
			# Keep the gathered pose while the original supported turn settles.
			# Only its native rate may delay the hop; all other clearance stays live.
			if not facing:
				if float(_pair.stage_age)>=.50: cancel("Paired launch clearance changed")
				return
			for actor_index in 2:
				var actor: RigidBody3D = actors[actor_index]
				var director: RefCounted = actor.idle_play
				var relative: Vector3 = actor.linear_velocity-actor.ground_velocity
				# A small inward component supplies real native closing motion at
				# the sole tap. Both components share the original hop delta-v cap;
				# no scripted contact impulse or body/velocity reset is needed.
				var launch: Vector3 = Vector3.UP*clampf(JUMP_SPEED-relative.y,0.0,JUMP_SPEED)+director._pair_normal*.12-relative.slide(Vector3.UP)
				var impulse := launch.limit_length(JUMP_SPEED)*actor.mass
				actor.apply_central_impulse(impulse)
				director.last_launch_impulse = impulse
				director.events.launch += 1
				director.events.pair_launch += 1
				director._jump_recovering = true
				director._airborne_seen = false
				director._landing_age = 0.0
				director._pair_foot_active = true
				director._pair_returning = false
				director.state = "flight"
				director.state_age = 0.0
				_pair.launch_serials[actor_index] = actor._pose.evaluation_serial
			_pair.stage = "flight"
			_pair.stage_age = 0.0
	else:
		if _pair.stage=="flight" and not _pair.contact: _observe_pair_contact(actors,frame)
		if _pair.contact: _pair.contact_age += delta
		if float(_pair.contact_age)>.10 or float(_pair.stage_age)>.62:
			_pair.stage = "return"
			for actor: RigidBody3D in actors:
				actor.idle_play._pair_returning = true
				actor.idle_play._pair_modifier.remove_native_contact()
		if actors.all(func(actor:RigidBody3D)->bool:return not actor.idle_play.physical_recovery_pending()):
			for actor: RigidBody3D in actors:
				if _pair.contact: actor.idle_play.events.pair_complete += 1
				else: actor.idle_play.events.pair_miss += 1
			if _pair.contact: actors[1].idle_play._voice("play",-22.0)
			_release_pair("")

func _observe_pair_contact(actors: Array[RigidBody3D], frame: int) -> void:
	var first: RefCounted = actors[0].idle_play
	var second: RefCounted = actors[1].idle_play
	if not is_instance_valid(first._pair_modifier) or not is_instance_valid(second._pair_modifier): return
	if not first._airborne_seen or not second._airborne_seen or actors[0].on_ground or actors[1].on_ground: return
	var soles: Array[Vector3] = []
	var normals: Array[Vector3] = []
	var centres: Array[Vector3] = []
	var serials: Array[int] = []
	for index in 2:
		var actor: RigidBody3D = actors[index]
		var director: RefCounted = actor.idle_play
		var pose: SkeletonModifier3D = actor._pose
		if not pose.evaluated_valid or pose.evaluation_serial<=int(_pair.launch_serials[index]): return
		var rebase: Transform3D = actor.global_transform*pose.evaluated_worker.affine_inverse()
		soles.append(rebase*pose.evaluated_soles[director._pair_side])
		normals.append((rebase.basis*pose.evaluated_ankles[director._pair_side].y).normalized())
		centres.append(rebase*director._pair_modifier.evaluated_end_centres[director._pair_side])
		serials.append(pose.evaluation_serial)
	if soles[0].distance_to(soles[1])>=.025 or normals[0].dot(first._pair_normal)<.94 or normals[1].dot(second._pair_normal)<.94 or normals[0].dot(normals[1])>-.94: return
	# A requested meeting or geometric near miss is insufficient: the actual
	# native manifold must name BOTH original rounded ending shape owners.
	var native := PhysicsServer3D.body_get_direct_state(actors[0].get_rid())
	if not native: return
	for contact in native.get_contact_count():
		if native.get_contact_collider_object(contact)!=actors[1] or not first._pair_modifier.owns_shape(native.get_contact_local_shape(contact)) or not second._pair_modifier.owns_shape(native.get_contact_collider_shape(contact)): continue
		var impulse: Vector3 = native.get_contact_impulse(contact)
		var normal: Vector3 = native.get_contact_local_normal(contact)
		var local_point: Vector3 = native.get_contact_local_position(contact)
		var remote_point: Vector3 = native.get_contact_collider_position(contact)
		var closing: float = (native.get_contact_collider_velocity_at_position(contact)-native.get_contact_local_velocity_at_position(contact)).dot(normal)
		# Frozen Jolt reports world points and a native collision-response
		# estimate. Require actual native closing motion at both evaluated sole
		# surfaces; a moved authored target or tangential near miss cannot pass.
		if impulse.length()<=.000001 or closing<=.000001 or absf(normal.dot(normals[0]))<.9 or local_point.distance_to(soles[0])>=.025 or remote_point.distance_to(soles[1])>=.025: continue
		_pair.contact = true
		_pair.proof = {"frame":frame,"serials":serials,"soles":soles,"normals":normals,"ending_centres":centres,"ending_radius":first._pair_modifier._endings[first._pair_side].shape.radius,"gap":soles[0].distance_to(soles[1]),"airborne_seen":[first._airborne_seen,second._airborne_seen],"native_impulse":impulse,"native_point":remote_point,"native_local_point":local_point,"native_closing":closing,"native_normal":normal,"local_shape":native.get_contact_local_shape(contact),"remote_shape":native.get_contact_collider_shape(contact)}
		for actor: RigidBody3D in actors: actor.idle_play.events.pair_contact += 1
		actors[0].idle_play._voice("play",-21.0)
		return

func _release_pair(reason: String) -> void:
	if _pair.is_empty(): return
	var actors: Array = [_pair.a.get_ref(),_pair.b.get_ref()]
	var goals: Array = _pair.goals
	for index in 2:
		var actor: RigidBody3D = actors[index]
		if not is_instance_valid(actor) or not actor.idle_play: continue
		var director: RefCounted = actor.idle_play
		director._pair = {}
		director._pair_returning = true
		if is_instance_valid(director._pair_modifier): director._pair_modifier.remove_native_contact()
		director._next_play = maxf(director._next_play,director._rng.randf_range(8.0,18.0))
		if actor.has_target and actor.target_position.distance_squared_to(goals[index])<.0001: actor.stop_navigation()
		if not reason.is_empty():
			director.events.pair_cancel += 1
			if actor!=worker: director.cancel(reason)
		elif not director._jump_recovering: director.state = ""

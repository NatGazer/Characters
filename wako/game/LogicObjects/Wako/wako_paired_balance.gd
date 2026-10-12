extends RefCounted
## A short mutual toe press, with one terrain-planted leg on each original
## helper. Existing native upright/spring assistance remains responsible for
## vertical support; toe contacts transmit a genuine bounded horizontal load.
const BalancePose := preload("res://LogicObjects/Wako/wako_paired_balance_pose.gd")
var _idle_owner: WeakRef
# The helper owns its idle controller, which owns this director. Keep the
# back-reference weak so removing the real helper releases both controllers.
var idle: RefCounted:
	get: return _idle_owner.get_ref() if _idle_owner else null
var worker: RigidBody3D
var pose: SkeletonModifier3D
var session: Dictionary = {}
var side := -1
var meeting := Vector3.INF
var normal := Vector3.FORWARD
var start_basis := Basis.IDENTITY
var original_goal := Vector3.INF
var press_goal := Vector3.INF
var lift_egress := Vector3.INF
var _route_last := Vector3.INF
var _route_start := Vector3.INF
var _route_count := 0
var _route_step := 0
var _ray := PhysicsRayQueryParameters3D.new()
var _clearance := PhysicsShapeQueryParameters3D.new()
var _invitation_remaining := 0.0
var _invitation_rng := RandomNumberGenerator.new()

func setup(owner: RefCounted) -> void:
	_idle_owner = weakref(owner)
	worker = owner.worker
	# A separate sparse social cadence does not consume the original dance,
	# water, hop or high-five random choices. Offers still require an idle opening.
	_invitation_rng.seed = absi(str(worker.worker_id).hash())+734981
	_invitation_remaining = _invitation_rng.randf_range(6.0,14.0)
	pose = BalancePose.new()
	pose.director = self
	worker._skeleton.add_child(pose)
	worker._skeleton.move_child(pose,idle._pair_modifier.get_index()+1)
	var capsule := CapsuleShape3D.new()
	capsule.radius = .31
	capsule.height = 1.06
	_clearance.shape = capsule
	for key: String in ["balance_invite","balance_contact","balance_complete","balance_cancel"]: idle.events[key] = 0

func active() -> bool:
	return not session.is_empty() or (is_instance_valid(pose) and pose.posing)

func physical_recovery_pending() -> bool:
	return is_instance_valid(pose) and pose.posing

func elapse(delta: float) -> void:
	# This is a social cooldown, not an idle-duration requirement. Ordinary
	# solo activity and useful work do not freeze it; nothing is queued while
	# they own the helper. The idle caller and original admission choose play.
	_invitation_remaining = maxf(0.0,_invitation_remaining-delta)

func offer() -> bool:
	if _invitation_remaining>0.0: return false
	_invitation_remaining = _invitation_rng.randf_range(4.0,7.0)
	return try_pair()

func peer() -> RigidBody3D:
	if session.is_empty(): return null
	return session.b.get_ref() if session.a.get_ref()==worker else session.a.get_ref()

func _geometry_available(actor: RigidBody3D) -> bool:
	return actor.axis_lock_angular_x and actor.axis_lock_angular_y and actor.axis_lock_angular_z \
		and actor.center_of_mass_mode==RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM \
		and is_instance_valid(actor.idle_play.paired_balance.pose) and actor.idle_play.paired_balance.pose.native_geometry_ready

func try_pair() -> bool:
	if not idle.available_for_play() or not _geometry_available(worker): return false
	var neighbour: RigidBody3D
	var nearest := 3.1*3.1
	var examined := 0
	for candidate: RigidBody3D in worker.coordinator.workers:
		examined += 1
		if examined>16: break
		if not is_instance_valid(candidate) or candidate==worker or not candidate.idle_play or not candidate.idle_play.paired_balance: continue
		if not candidate.idle_play.available_for_play() or not _geometry_available(candidate): continue
		var squared: float = (candidate.global_position-worker.global_position).slide(Vector3.UP).length_squared()
		if squared<1.1*1.1 or squared>=nearest or absf(candidate._ground_point.y-worker._ground_point.y)>.06: continue
		neighbour = candidate
		nearest = squared
	if not neighbour: return false
	var toward: Vector3 = (neighbour.global_position-worker.global_position).slide(Vector3.UP).normalized()
	var centre: Vector3 = (neighbour._ground_point+worker._ground_point)*.5
	var goals: Array[Vector3] = [centre-toward*.56,centre+toward*.56]
	var actors: Array[RigidBody3D] = [worker,neighbour]
	for index in 2:
		if (goals[index]-actors[index].safe_position).slide(Vector3.UP).length()>idle.PLAY_RADIUS: return false
	session = {"a":weakref(worker),"b":weakref(neighbour),"stage":"route","age":0.0,"stage_age":0.0,"frame":-1,"goals":goals,"route_ready":[false,false],"settled":0.0,"contact_ticks":0,"contact_run":0,"maximum_contact_run":0,"response_peak":0.0,"proofs":[]}
	neighbour.idle_play.paired_balance.session = session
	for index in 2:
		var actor: RigidBody3D = actors[index]
		var director: RefCounted = actor.idle_play.paired_balance
		director.original_goal = goals[index]
		director._route_start = actor._ground_point
		director._route_last = actor._ground_point
		director._route_count = maxi(1,ceili((goals[index]-actor._ground_point).length()/.3))
		director._route_step = 0
		director._invitation_remaining = director._invitation_rng.randf_range(20.0,35.0)
		actor.idle_play.state = "balance_invite"
		actor.idle_play.state_age = 0.0
		actor.idle_play.events.balance_invite += 1
		actor.stop_navigation()
	return true

func _advance_route(index: int) -> void:
	_ray.exclude = worker.query_exclusions()
	_ray.collision_mask = 1
	_clearance.exclude = worker.query_exclusions()
	_clearance.collision_mask = worker.collision_mask
	for sample in 3:
		_route_step += 1
		var point := _route_start.lerp(original_goal,float(_route_step)/_route_count)
		_ray.from = Vector3(point.x,_route_last.y+.55,point.z)
		_ray.to = Vector3(point.x,_route_last.y-.55,point.z)
		var hit := worker.get_world_3d().direct_space_state.intersect_ray(_ray)
		if hit.is_empty() or hit.collider is RigidBody3D or hit.normal.y<.96 or absf(hit.position.y-_route_last.y)>.075 or worker.coordinator.yard.unsafe_at(hit.position): idle.cancel("Paired balance has no supported approach"); return
		point = hit.position
		_clearance.transform = Transform3D(Basis.IDENTITY,point+Vector3.UP*(worker.ride_height+.2))
		if not worker.get_world_3d().direct_space_state.intersect_shape(_clearance,1).is_empty(): idle.cancel("Paired balance approach is obstructed"); return
		_route_last = point
		if _route_step>=_route_count:
			original_goal = point
			session.goals[index] = point
			session.route_ready[index] = true
			return

func _prepare(actors: Array[RigidBody3D]) -> bool:
	var midpoint: Vector3 = (actors[0]._ground_point+actors[1]._ground_point)*.5
	var hip_height: float = (actors[0].evaluated_hip(0).y+actors[0].evaluated_hip(1).y+actors[1].evaluated_hip(0).y+actors[1].evaluated_hip(1).y)*.25
	midpoint.y += clampf(hip_height-midpoint.y-.02,.45,.7)
	var toward: Vector3 = (actors[1].global_position-actors[0].global_position).slide(Vector3.UP).normalized()
	var options: Array = [[],[]]
	for index in 2:
		var actor: RigidBody3D = actors[index]
		var director: RefCounted = actor.idle_play.paired_balance
		var facing: Vector3 = toward if index==0 else -toward
		for leg in 2:
			if not actor._pose.native_support_rid(1-leg).is_valid(): continue
			var admitted: Dictionary = director.pose.admission(leg,midpoint,facing)
			if not admitted.is_empty(): options[index].append(admitted)
		if options[index].is_empty(): return false
	var chosen: Array = []
	var best := .035
	for first: Dictionary in options[0]:
		for second: Dictionary in options[1]:
			# Both original cubes must leave both actual rounded endings clear,
			# including the peer's predicted support transfer. Only toe-to-toe
			# contact is intentional; a toe inside either body is inadmissible.
			if actors[1].idle_play.paired_balance.pose._cube_gap(first.centre,second.cube)<float(first.radius)+.005 or actors[0].idle_play.paired_balance.pose._cube_gap(second.centre,first.cube)<float(second.radius)+.005: continue
			var needs_low: bool = Vector3(first.egress).is_finite() or Vector3(second.egress).is_finite()
			if needs_low and (not bool(first.low_valid) or not bool(second.low_valid)): continue
			var remaining := minf(float(first.margin),float(second.margin))
			if remaining>best: best = remaining; chosen = [first,second]
	if chosen.is_empty(): return false
	for index in 2:
		var director: RefCounted = actors[index].idle_play.paired_balance
		director.side = int(chosen[index].leg)
		director.meeting = midpoint
		director.normal = toward if index==0 else -toward
		director.start_basis = chosen[index].basis
		director.lift_egress = chosen[index].low if Vector3(chosen[0].egress).is_finite() or Vector3(chosen[1].egress).is_finite() else Vector3.INF
		director.press_goal = actors[index]._ground_point+director.normal*.025
	return true

func advance(delta: float) -> void:
	if session.is_empty():
		if not physical_recovery_pending() and idle.state.begins_with("balance_"): idle.state = ""
		return
	if not idle._free_of_obligations(): idle.cancel("Useful work or danger interrupts paired balance"); return
	var neighbour := peer()
	if not is_instance_valid(neighbour) or not neighbour.idle_play or not neighbour.idle_play.paired_balance or not neighbour.idle_play._free_of_obligations(): idle.cancel("Paired balancing helper became unavailable"); return
	if not worker.on_ground or is_instance_valid(worker._ground_body) or worker.ground_normal.y<.96: idle.cancel("Paired balance lost its native terrain support"); return
	var index := 0 if session.a.get_ref()==worker else 1
	if session.stage=="route" and not session.route_ready[index]:
		if not idle.available_jump_support() or (worker._ground_point-_route_start).length()>.15: idle.cancel("Paired balance approach support changed"); return
		_advance_route(index)
		if session.is_empty(): return
	if session.stage!="route": worker.face_point(neighbour.global_position)
	var frame := Engine.get_physics_frames()
	if int(session.frame)==frame: return
	session.frame = frame
	session.age += delta
	session.stage_age += delta
	var actors: Array[RigidBody3D] = [session.a.get_ref(),session.b.get_ref()]
	if float(session.age)>12.0: idle.cancel("Paired balance did not recover its planted soles"); return
	if session.stage=="route":
		if session.route_ready.all(func(ready:bool)->bool:return ready):
			session.stage = "approach"
			session.stage_age = 0.0
			for actor_index in 2: actors[actor_index].navigate_to(session.goals[actor_index])
		elif float(session.stage_age)>1.5: idle.cancel("Paired balance found no safe approach")
	elif session.stage=="approach":
		var arrived := true
		for actor_index in 2:
			var actor: RigidBody3D = actors[actor_index]
			if not actor.on_ground or is_instance_valid(actor._ground_body) or actor.navigation_blocked() or not actor.has_target or actor.target_position.distance_squared_to(session.goals[actor_index])>.0001: idle.cancel("Paired balance approach was interrupted"); return
			arrived = arrived and actor.at_target(.13) and (actor.linear_velocity-actor.ground_velocity).length()<.2
		session.settled = float(session.settled)+delta if arrived else 0.0
		if float(session.settled)>.14:
			session.stage = "face"
			session.stage_age = 0.0
			for actor: RigidBody3D in actors: actor.stop_navigation()
		elif float(session.stage_age)>4.0: idle.cancel("Paired balance approach did not settle")
	elif session.stage=="face":
		var facing := true
		for actor_index in 2:
			var actor: RigidBody3D = actors[actor_index]
			actor.face_point(actors[1-actor_index].global_position)
			var toward: Vector3 = (actors[1-actor_index].global_position-actor.global_position).slide(Vector3.UP).normalized()
			facing = facing and actor.idle_play.available_jump_support() and (-actor._model.global_basis.z).dot(toward)>.97 and absf(actor.turn_rate)<.25
		if facing:
			if not _prepare(actors): idle.cancel("Original planted legs cannot reach a mutual balance"); return
			for actor: RigidBody3D in actors:
				if not actor.idle_play.paired_balance.pose.capture(): idle.cancel("Paired balance lost original grounded feet"); return
			session.stage = "lift"
			session.stage_age = 0.0
			for actor: RigidBody3D in actors: actor.idle_play.state = "balance_lift"
		elif float(session.stage_age)>2.5: idle.cancel("Paired balance did not face its neighbour")
	elif session.stage=="lift":
		if actors.all(func(actor:RigidBody3D)->bool:return actor.idle_play.paired_balance.pose.meeting_ready):
			session.stage = "press"
			session.stage_age = 0.0
			for actor: RigidBody3D in actors:
				actor.idle_play.state = "balance_press"
				# The unchanged bounded native navigation servo supplies the mutual
				# horizontal press. No balance-specific body force or impulse.
				actor.navigate_to(actor.idle_play.paired_balance.press_goal)
		elif float(session.stage_age)>1.5: idle.cancel("Paired balance feet did not meet")
	elif session.stage=="press":
		for actor: RigidBody3D in actors:
			var director: RefCounted = actor.idle_play.paired_balance
			if not director.pose.supported or not actor.has_target or actor.target_position.distance_squared_to(director.press_goal)>.0001: idle.cancel("Paired toe press lost its supported intention"); return
		_observe_contact(actors,frame)
		if float(session.stage_age)>.85:
			if int(session.maximum_contact_run)<30 or float(session.response_peak)<=.000001: idle.cancel("Paired balance never carried an actual native toe contact"); return
			session.stage = "return"
			for actor: RigidBody3D in actors:
				actor.stop_navigation()
				actor.idle_play.state = "balance_return"
				actor.idle_play.paired_balance.pose.returning = true
				actor.idle_play.paired_balance.pose.remove_native_contact()
	else:
		if actors.all(func(actor:RigidBody3D)->bool:return not actor.idle_play.paired_balance.physical_recovery_pending()):
			for actor: RigidBody3D in actors: actor.idle_play.events.balance_complete += 1
			_release(actors,"")

func _observe_contact(actors: Array[RigidBody3D], frame: int) -> void:
	var first: RefCounted = actors[0].idle_play.paired_balance
	var second: RefCounted = actors[1].idle_play.paired_balance
	var state := PhysicsServer3D.body_get_direct_state(actors[0].get_rid())
	var found := false
	if state and first.pose.supported and second.pose.supported:
		for contact in state.get_contact_count():
			if state.get_contact_collider_object(contact)!=actors[1] or not first.pose.owns_shape(state.get_contact_local_shape(contact)) or not second.pose.owns_shape(state.get_contact_collider_shape(contact)): continue
			var native_normal := state.get_contact_local_normal(contact)
			var response := state.get_contact_impulse(contact)
			var local_point := state.get_contact_local_position(contact)
			var remote_point := state.get_contact_collider_position(contact)
			var soles: Array[Vector3] = [actors[0]._pose.evaluated_soles[first.side],actors[1]._pose.evaluated_soles[second.side]]
			if absf(native_normal.dot(first.normal))<.9 or local_point.distance_to(soles[0])>.025 or remote_point.distance_to(soles[1])>.025: continue
			found = true
			session.contact_ticks += 1
			session.response_peak = maxf(float(session.response_peak),response.length())
			if int(session.contact_ticks)==1:
				for actor: RigidBody3D in actors: actor.idle_play.events.balance_contact += 1
				actors[0].idle_play._voice("play",-21.0)
			elif int(session.contact_ticks)==31:
				actors[1].idle_play._voice("play",-22.0)
			if session.proofs.size()<192:
				session.proofs.append({"frame":frame,"local_shape":state.get_contact_local_shape(contact),"remote_shape":state.get_contact_collider_shape(contact),"normal":native_normal,"reported_response":response,"closing":(state.get_contact_collider_velocity_at_position(contact)-state.get_contact_local_velocity_at_position(contact)).dot(native_normal),"soles":soles,"points":[local_point,remote_point],"ground_support":[first.pose.support_rid,second.pose.support_rid],"support_soles":[actors[0]._pose.evaluated_soles[1-first.side],actors[1]._pose.evaluated_soles[1-second.side]],"support_gaps":[first.pose.support_gap,second.pose.support_gap]})
			break
	session.contact_run = int(session.contact_run)+1 if found else 0
	session.maximum_contact_run = maxi(int(session.maximum_contact_run),int(session.contact_run))

func cancel(reason: String) -> void:
	if session.is_empty():
		if is_instance_valid(pose): pose.returning = true; pose.remove_native_contact()
		return
	var actors: Array = [session.a.get_ref(),session.b.get_ref()]
	_release(actors,reason)

func _release(actors: Array, reason: String) -> void:
	for actor: RigidBody3D in actors:
		if not is_instance_valid(actor) or not actor.idle_play: continue
		var director: RefCounted = actor.idle_play.paired_balance
		director.session = {}
		if is_instance_valid(director.pose): director.pose.returning = true; director.pose.remove_native_contact()
		if actor.has_target and (actor.target_position.distance_squared_to(director.original_goal)<.0001 or actor.target_position.distance_squared_to(director.press_goal)<.0001): actor.stop_navigation()
		actor.idle_play._next_play = maxf(actor.idle_play._next_play,actor.idle_play._rng.randf_range(8.0,18.0))
		if not reason.is_empty(): actor.idle_play.events.balance_cancel += 1
		if not director.physical_recovery_pending(): actor.idle_play.state = ""
	for actor: RigidBody3D in actors:
		if actor!=worker and is_instance_valid(actor) and actor.idle_play and not reason.is_empty(): actor.idle_play.cancel(reason)

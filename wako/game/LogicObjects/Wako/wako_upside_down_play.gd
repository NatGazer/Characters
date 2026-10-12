extends RefCounted
## A ground-launched native half-turn onto a neighbour's real cube roof.
## The existing nine-body ragdoll replaces the upper capsule. Only reported
## head contact admits balancing; finite assistance reacts on that same body.
const Rig := preload("res://Components/Avatar/ragdoll/ragdoll_rig.gd")
const LAUNCH_SPEED := 5.6
const BALANCE_TORQUE := 80.0
const BALANCE_TRACTION := 50.0
var _idle_owner: WeakRef
var idle: RefCounted:
	get: return _idle_owner.get_ref() if _idle_owner else null
var worker: RigidBody3D
var session: Dictionary = {}
var _roof_owner := -1
var _lower_owners: Array[int] = []
var _original_capsule: Shape3D
var _original_capsule_transform := Transform3D.IDENTITY
var _original_capsule_disabled := false
var _roof_body: WeakRef
var _roof_baseline: Dictionary = {}
var _initial: Array[Transform3D] = []
var _relative: Array[Quaternion] = []
var _remaining := 18.0
var _rng := RandomNumberGenerator.new()
var last_result: Dictionary = {}

func setup(owner: RefCounted) -> void:
	_idle_owner = weakref(owner)
	worker = owner.worker
	# Publish collider geometry after the existing final terrain-foot solve,
	# from that same genuinely evaluated native-pose snapshot.
	worker._pose.modification_processed.connect(_sync_evaluated_lower)
	_rng.seed = absi(str(worker.worker_id).hash())+386127
	_remaining = _rng.randf_range(18.0,32.0)
	for key: String in ["upside_invite","upside_launch","upside_contact","upside_complete","upside_cancel"]: idle.events[key] = 0

func elapse(delta: float) -> void:
	_remaining = maxf(0.0,_remaining-delta)

func active() -> bool:
	return not session.is_empty()

func physical_recovery_pending() -> bool:
	return active() and session.get("launched",false)

func owns_lower_stance() -> bool:
	# Pose ownership only. Real native floor/head contacts remain separately
	# measured; this never publishes a support flag or applies an extra force.
	return active() and session.get("launched",false) and session.base.get_ref()==worker and _lower_owners.size()==9 and not worker.ragdoll.is_down()

func offer() -> bool:
	if _remaining>0.0: return false
	_remaining = _rng.randf_range(6.0,10.0)
	return try_pair()

func _bare(actor: RigidBody3D) -> bool:
	return is_instance_valid(actor) and actor.companion_mode=="work" and actor.idle_play and actor.idle_play.available_for_play() \
		and actor.ragdoll and actor.ragdoll.rig.bodies.size()==9 \
		and actor.ragdoll._cooldown<=0.0 \
		and not is_instance_valid(actor.equipped_tool) and not is_instance_valid(actor.equipped_gun) \
		and actor.axis_lock_angular_x and actor.axis_lock_angular_y and actor.axis_lock_angular_z \
		and actor.center_of_mass_mode==RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM

func try_pair() -> bool:
	if not _bare(worker): return false
	var neighbour: RigidBody3D
	var nearest := 3.0*3.0
	for candidate: RigidBody3D in worker.coordinator.workers.slice(0,16):
		if candidate==worker or not _bare(candidate) or not candidate.idle_play.upside_down: continue
		var d := (candidate.global_position-worker.global_position).slide(Vector3.UP).length_squared()
		if d<1.0 or d>=nearest or absf(candidate._ground_point.y-worker._ground_point.y)>.035: continue
		nearest=d; neighbour=candidate
	if not neighbour: return false
	var towards := (neighbour.global_position-worker.global_position).slide(Vector3.UP).normalized()
	# The proposer supports; its neighbour jumps. Both use ordinary navigation.
	var goal: Vector3 = worker._ground_point+towards*1.42
	if (goal-neighbour.safe_position).slide(Vector3.UP).length()>idle.PLAY_RADIUS: return false
	if not _route_clear(neighbour,goal): return false
	session={"base":weakref(worker),"top":weakref(neighbour),"stage":"approach","age":0.0,"stage_age":0.0,"frame":-1,"goal":goal,"home":neighbour._ground_point,"launched":false,"interrupted":false,"reason":"","settled":0.0,"contact_ticks":0,"contact_run":0,"maximum_contact_run":0,"response_peak":0.0,"inverted_ticks":0,"launch_pending":false,"return_pending":false,"proofs":[],"lower_floor_faults":0,"native_mass_drift":0.0,"lower_moment_drift":0.0}
	neighbour.idle_play.upside_down.session=session
	for actor: RigidBody3D in [worker,neighbour]:
		actor.stop_navigation()
		actor.idle_play.state="upside_invite"
		actor.idle_play.events.upside_invite+=1
		actor.idle_play.upside_down._remaining=actor.idle_play.upside_down._rng.randf_range(35.0,55.0)
		actor.idle_play.upside_down._relative.clear()
	neighbour.navigate_to(goal)
	return true

func _route_clear(actor: RigidBody3D, goal: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.new()
	query.exclude=actor.query_exclusions(); query.collision_mask=1
	var previous: Vector3=actor._ground_point
	for index in range(1,maxi(2,ceili(previous.distance_to(goal)/.25))+1):
		var p: Vector3=actor._ground_point.lerp(goal,float(index)/maxi(2,ceili(actor._ground_point.distance_to(goal)/.25)))
		query.from=p+Vector3.UP*.3; query.to=p-Vector3.UP*.3
		var hit:=actor.get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty() or hit.collider is RigidBody3D or hit.normal.y<.97 or absf(hit.position.y-previous.y)>.06 or actor.coordinator.yard.unsafe_at(hit.position): return false
		previous=hit.position
	return true

func _obligations(actor: RigidBody3D, upper_native := false) -> bool:
	if not is_instance_valid(actor) or actor.is_queued_for_deletion() or actor.paused: return true
	if not upper_native and (not actor.is_available() or not actor.idle_play._free_of_obligations()): return true
	if actor.companion_mode!="work" or not actor.current_job_id.is_empty() or not actor.action.is_empty() or actor.work_action_held: return true
	if actor.fear_time>0.0 or actor._reaction>.1 or actor.carrying or actor.cargo_mass>0.0: return true
	if is_instance_valid(actor.station) or is_instance_valid(actor.access_support) or is_instance_valid(actor.brace_load) or is_instance_valid(actor.equipped_tool) or is_instance_valid(actor.equipped_gun): return true
	if not is_instance_valid(actor.coordinator) or not is_instance_valid(actor.coordinator.yard): return true
	var yard: Node3D=actor.coordinator.yard
	if yard.work_paused or yard.worksite_active() or yard.crew_travel_active() or yard.unsafe_at(actor.global_position): return true
	for lease: Dictionary in yard._reservations.values():
		if lease.get("workers",[]).has(actor.get_instance_id()): return true
	return false

func advance(delta: float) -> void:
	if session.is_empty(): return
	var base: RigidBody3D=session.base.get_ref()
	var top: RigidBody3D=session.top.get_ref()
	if not is_instance_valid(base) or not is_instance_valid(top): cancel("Playmate left"); _release(false); return
	if worker==base: _update_roof()
	var frame:=Engine.get_physics_frames()
	if int(session.frame)==frame: return
	session.frame=frame; session.age+=delta; session.stage_age+=delta
	var launched: bool=session.launched
	if launched and not top.ragdoll.is_down() and float(session.stage_age)>.2:
		_release(not session.interrupted and int(session.maximum_contact_run)>=30)
		return
	# Like original water play, end enjoyment for real pending useful work
	# while retaining native ownership until an actual supported return.
	var useful_work_waiting: bool=launched and not base.coordinator.yard.work_paused and not base.coordinator._jobs.is_empty()
	if useful_work_waiting or _obligations(base) or _obligations(top,launched and top.ragdoll.is_down()): cancel("Useful work or danger needs the helpers")
	if session.is_empty(): return
	if launched:
		# A real work, danger or companion intention ends enjoyment at once.
		# Retain only the lower native brace until the upper same-mass rig
		# returns; original forces and real contact still react without a reset.
		base.stop_navigation()
	if not launched:
		base.face_point(top.global_position); top.face_point(base.global_position)
		if not base.idle_play.available_jump_support() or not top.on_ground or top.navigation_blocked(): cancel("Original ground support changed"); return
		if session.stage=="approach":
			var toward: Vector3=(base.global_position-top.global_position).slide(Vector3.UP).normalized()
			var arrived: bool=top.at_target(.08) and (top.linear_velocity-top.ground_velocity).length()<.16 and absf(top.turn_rate)<.2 and (-top._model.global_basis.z).dot(toward)>.98
			session.settled=float(session.settled)+delta if arrived else 0.0
			if float(session.settled)>.16:
				top.stop_navigation()
				if not base.idle_play.upside_down._add_roof(): cancel("Original finite head roof unavailable"); return
				session.stage="gather"; session.stage_age=0.0
				for actor: RigidBody3D in [base,top]: actor.idle_play.state="upside_gather"
			elif float(session.age)>5.0: cancel("Supported approach did not settle")
		elif session.stage=="gather":
			top.idle_play.crouch_weight=smoothstep(0.0,.16,float(session.stage_age))
			if float(session.stage_age)>.22:
				if not top.idle_play.available_jump_support() or not _admit_launch(base,top): cancel("Real body sweep cannot reach the head safely"); return
				session.launched=true; session.launch_pending=true; session.stage="launch"; session.stage_age=0.0
				top.idle_play.crouch_weight=0.0
				for actor: RigidBody3D in [base,top]: actor.idle_play.state="upside_native"
				# Existing ragdoll capture replaces the capsule at its evaluated pose.
				top._animation.speed_scale=0.0
				top.ragdoll._impulse=Vector3.ZERO
				top.ragdoll.pending=true; top.ragdoll.modifier.active=true
	elif not top.ragdoll.is_down():
		if float(session.stage_age)>.2: _release(not session.interrupted and int(session.maximum_contact_run)>=30)
	elif float(session.age)>18.0:
		cancel("Native stunt needed ordinary physical recovery")

func _add_roof() -> bool:
	if _roof_owner>=0: return true
	var native:=PhysicsServer3D.body_get_direct_state(worker.get_rid())
	var visual: RefCounted=worker.ragdoll.visual
	var collision:=worker.get_node("Collision") as CollisionShape3D
	if not native or native.inverse_inertia!=Vector3.ZERO or not worker._pose.evaluated_valid or collision.disabled: return false
	if visual._remembered.size()!=worker._skeleton.get_bone_count(): return false
	for axis in 3:
		if native.inverse_inertia_tensor[axis]!=Vector3.ZERO: return false
	var body=worker.ragdoll.rig.bodies[0]
	if not body.shape is BoxShape3D: return false
	if worker.ragdoll.rig.bodies.any(func(part)->bool:return part.rb.process_mode!=Node.PROCESS_MODE_DISABLED or PhysicsServer3D.body_get_space(part.rid).is_valid()): return false
	_original_capsule=collision.shape
	_original_capsule_transform=collision.transform
	_original_capsule_disabled=collision.disabled
	_roof_baseline={"mass":worker.mass,"centre":native.center_of_mass_local,"inverse_inertia":native.inverse_inertia,"tensor":native.inverse_inertia_tensor,"inertia_property":worker.inertia,"layer":worker.collision_layer,"mask":worker.collision_mask,"capsule_rid":collision.shape.get_rid(),"capsule_transform":collision.transform,"capsule_disabled":collision.disabled}
	# Original HeadLeap also replaces the coarse capsule with its real cube
	# for head contact. This grounded stunt additionally retains all eight
	# original native leg/foot shapes, so no missing leg geometry grants passage.
	# These shapes belong to the SAME original aggregate body, mass and custom
	# COM. The nine separate lower ragdoll bodies stay disabled, with no load
	# duplication. Its original locked-axis/spring support remains the assist.
	for original in worker.ragdoll.rig.bodies:
		var owner:=worker.create_shape_owner(worker)
		worker.shape_owner_add_shape(owner,original.shape)
		_lower_owners.append(owner)
	_roof_owner=_lower_owners[0]
	_roof_body=weakref(worker)
	_update_roof()
	collision.disabled=true
	return true

func _sync_evaluated_lower() -> void:
	if _roof_owner>=0 and is_instance_valid(worker) and worker.is_inside_tree() and not worker.ragdoll.is_down(): _update_roof()

func _update_roof() -> void:
	if _roof_owner<0 or not worker._pose.evaluated_valid: return
	var visual: RefCounted=worker.ragdoll.visual
	if visual._remembered.size()!=worker._skeleton.get_bone_count(): return
	var rebase: Transform3D=worker.global_transform*visual._remembered_worker.affine_inverse()
	for original in worker.ragdoll.rig.bodies:
		var native_part: Transform3D=rebase*visual._remembered[original.bone]*original.b2b_inv
		native_part.basis=native_part.basis.orthonormalized()
		worker.shape_owner_set_transform(_lower_owners[original.index],worker.global_transform.affine_inverse()*native_part)
	var native:=PhysicsServer3D.body_get_direct_state(worker.get_rid())
	if native and not session.is_empty():
		session.native_mass_drift=maxf(float(session.native_mass_drift),maxf(absf(worker.mass-float(_roof_baseline.mass)),absf(1.0/native.inverse_mass-float(_roof_baseline.mass))))
		session.lower_during={"mass":1.0/native.inverse_mass,"centre":native.center_of_mass_local,"inverse_inertia":native.inverse_inertia,"tensor":native.inverse_inertia_tensor,"capsule_disabled":worker.get_node("Collision").disabled,"compound_shapes":_lower_owners.size(),"separate_lower_bodies_disabled":worker.ragdoll.rig.bodies.all(func(part)->bool:return part.rb.process_mode==Node.PROCESS_MODE_DISABLED and not PhysicsServer3D.body_get_space(part.rid).is_valid())}
		# Permanent holder motion may legitimately change the existing custom
		# payload COM. The compound contact follows that same accounted centre.
		var drift:=native.center_of_mass_local.distance_to(worker.center_of_mass)
		session.lower_payload_com_motion=maxf(float(session.get("lower_payload_com_motion",0.0)),worker.center_of_mass.distance_to(Vector3(_roof_baseline.centre)))
		drift=maxf(drift,native.inverse_inertia.distance_to(Vector3(_roof_baseline.inverse_inertia)))
		for axis in 3: drift=maxf(drift,native.inverse_inertia_tensor[axis].distance_to(Basis(_roof_baseline.tensor)[axis]))
		session.lower_moment_drift=maxf(float(session.lower_moment_drift),drift)

func _restore_lower_collision() -> bool:
	if _lower_owners.is_empty(): return true
	var collision:=worker.get_node("Collision") as CollisionShape3D
	if collision.shape!=_original_capsule or collision.transform!=_original_capsule_transform: return false
	if not worker.ragdoll.is_down():
		var query:=PhysicsShapeQueryParameters3D.new()
		query.shape=_original_capsule
		query.transform=worker.global_transform*_original_capsule_transform
		query.exclude=worker.query_exclusions()
		query.collision_mask=int(_roof_baseline.mask)|(1<<8)
		var hits:=worker.get_world_3d().direct_space_state.intersect_shape(query,1)
		if not hits.is_empty():
			session.restore_blocker=str(hits[0].collider.get_path())
			return false
	# No body transform or velocity is changed. Restore the original saved
	# primitive only after its actual volume is clear (or its body is frozen
	# under the existing native ragdoll). Remove every owned compound shape.
	collision.disabled=_original_capsule_disabled
	for owner in _lower_owners: worker.remove_shape_owner(owner)
	_lower_owners.clear(); _roof_owner=-1; _original_capsule=null
	var native:=PhysicsServer3D.body_get_direct_state(worker.get_rid())
	if native:
		session.lower_after={"mass":1.0/native.inverse_mass,"centre":native.center_of_mass_local,"inverse_inertia":native.inverse_inertia,"tensor":native.inverse_inertia_tensor,"capsule_disabled":collision.disabled,"capsule_rid":collision.shape.get_rid(),"capsule_transform":collision.transform}
	return true

func _admit_launch(base: RigidBody3D, top: RigidBody3D) -> bool:
	var root=top.ragdoll.rig.bodies[0]
	var visual: RefCounted=top.ragdoll.visual
	if visual._remembered.size()!=top._skeleton.get_bone_count(): return false
	var rebase: Transform3D=top.global_transform*visual._remembered_worker.affine_inverse()
	_initial.resize(top.ragdoll.rig.bodies.size())
	for body in top.ragdoll.rig.bodies:
		var original: Transform3D=rebase*visual._remembered[body.bone]*body.b2b_inv
		original.basis=original.basis.orthonormalized()
		_initial[body.index]=original
	var base_director: RefCounted=base.idle_play.upside_down
	var roof: Transform3D=base.global_transform*base.shape_owner_get_transform(base_director._roof_owner)
	var roof_point: Vector3=roof.origin+roof.basis.y*float(base.ragdoll.rig.bodies[0].shape.size.y)*.5
	var start:=Vector3.ZERO
	var holder: Dictionary=top.back_tool.holder_load(_initial[0]*root.b2b)
	if holder.is_empty(): return false
	var torso_mass: float=9.8+float(holder.mass)
	var torso_com: Vector3=(_initial[0].origin*9.8+Vector3(holder.world_point)*float(holder.mass))/torso_mass
	var total: float=torso_mass+12.2
	for body in top.ragdoll.rig.bodies:
		var body_com: Vector3=torso_com if body.index==0 else _initial[body.index]*body.rb.center_of_mass
		start+=body_com*(torso_mass if body.index==0 else body.mass)/total
	# A backward half-turn lifts the feet away from the supporting neighbour.
	# A forward turn swung the toes into its real capsule before clearing it.
	var axis: Vector3=-_initial[0].basis.x.normalized()
	var goal_rotation:=Basis(axis,PI)
	var target_com: Vector3=roof_point+Vector3.UP*float(root.shape.size.y)*.5-goal_rotation*(_initial[0].origin-start)
	var height:=target_com.y-start.y
	var gravity:=maxf(top.get_gravity().length(),9.8)
	# The full body needs time to clear the real supporting cube before
	# its head descends. Retain the original 5.6 m/s bound; a minimum 5.5
	# here buys physical clearance, never a pose/path exemption.
	var takeoff:=maxf(5.5,sqrt(2.0*gravity*(height+.14)))
	if takeoff>LAUNCH_SPEED: return false
	var linear_damping: float=.05+float(ProjectSettings.get_setting("physics/3d/default_linear_damp",.1))
	var angular_damping: float=.8+float(ProjectSettings.get_setting("physics/3d/default_angular_damp",.1))
	var flight_ticks:=0
	var last_height:=0.0
	var position:=Vector3.ZERO
	var velocity:=Vector3.UP*takeoff
	var horizontal_time:=0.0
	var damping_factor:=maxf(1.0-linear_damping/120.0,0.0)
	var horizontal_speed:=1.0
	for tick in 96:
		velocity=velocity*damping_factor-Vector3.UP*gravity/120.0
		position+=velocity/120.0
		horizontal_speed*=damping_factor; horizontal_time+=horizontal_speed/120.0
		if tick>24 and velocity.y<0.0 and position.y<=height and last_height>height: flight_ticks=tick; break
		last_height=position.y
	if flight_ticks<60 or flight_ticks>96: return false
	var duration: float=flight_ticks/120.0
	var horizontal: Vector3=(target_com-start).slide(Vector3.UP)/horizontal_time
	if horizontal.length()>2.3: return false
	var omega:=PI*angular_damping/(1.0-exp(-angular_damping*duration))
	if omega>7.6: return false
	session.flight_plan={"initial":_initial.duplicate(),"roof":roof,"start_com":start,"launch_ground":top._ground_point,"target_com":target_com,"mass":total,"takeoff":takeoff,"duration":duration,"velocity":horizontal+Vector3.UP*takeoff,"spin":axis*omega}
	var query:=PhysicsShapeQueryParameters3D.new()
	query.exclude=top.query_exclusions(); query.collision_mask=1|4|8|16|64|(1<<8)
	# Original native shape sweep: all nine retained body shapes, finite motion.
	# Intended peer touch is only the torso roof at the final inverted approach.
	for sample in range(1,25):
		var ticks:=roundi(flight_ticks*float(sample)/24.0)
		var t:=ticks/120.0
		var turn:=omega*(1.0-exp(-angular_damping*t))/angular_damping
		var rotation:=Basis(axis,turn)
		var center:=start
		var flight_velocity:=horizontal+Vector3.UP*takeoff
		for tick in ticks:
			flight_velocity=flight_velocity*damping_factor-Vector3.UP*gravity/120.0
			center+=flight_velocity/120.0
		for body in top.ragdoll.rig.bodies:
			var original: Transform3D=_initial[body.index]
			query.shape=body.shape
			query.transform=Transform3D(rotation*original.basis,center+rotation*(original.origin-start))
			for hit: Dictionary in top.get_world_3d().direct_space_state.intersect_shape(query,4):
				var intended: bool=hit.collider==base and body.index==0 and sample>=22 and query.transform.basis.y.dot(Vector3.UP)<-.9 and query.transform.origin.y>=roof_point.y+float(root.shape.size.y)*.5-.012
				if not intended:
					session.launch_blocker={"sample":sample,"body":body.name,"collider":str(hit.collider.get_path()),"point":query.transform.origin,"is_base":hit.collider==base,"shape":hit.shape}
					return false
	session.launch_floor_rids=[top._pose.native_support_rid(0),top._pose.native_support_rid(1)]
	session.launch_velocity=horizontal+Vector3.UP*takeoff
	session.launch_omega=axis*omega
	session.goal_basis=Basis(axis,PI)*_initial[0].basis
	session.duration=duration
	session.planned_com=start; session.target_com=target_com
	session.planned_mass=total
	session.takeoff=takeoff
	return true

func native_tick(delta: float) -> bool:
	if session.is_empty() or session.top.get_ref()!=worker or not session.launched or not worker.ragdoll.active: return false
	var rd: RefCounted=worker.ragdoll
	var base: RigidBody3D=session.base.get_ref()
	if not is_instance_valid(base) or not base.is_available(): cancel("Supporting Wako lost footing"); return false
	if session.launch_pending:
		if _relative.size()!=rd.rig.bodies.size():
			_relative.resize(rd.rig.bodies.size())
			for body in rd.rig.bodies:
				if body.parent>=0: _relative[body.index]=rd._current[body.parent].basis.get_rotation_quaternion().inverse()*rd._current[body.index].basis.get_rotation_quaternion()
		var planted:=_launch_foot_contact()
		if planted.is_empty():
			if float(session.stage_age)>.05:
				cancel("Native launch foot did not contact its original floor")
				return false
			rd.rig.apply_joint_tone(rd._current,_relative,delta,4.0,3.0,rd.STIFFNESS,rd.CAPS)
			return true
		session.launch_support=planted
		if not _impulse_group(Vector3(session.launch_velocity),Vector3(session.launch_omega),null,Vector3(planted.point)):
			cancel("Finite launch motor cannot supply this momentum")
			return false
		session.launch_pending=false; session.stage="flight"; session.stage_age=0.0
		worker.idle_play.events.upside_launch+=1
	var support:=_head_contact(base)
	var inverted: bool=rd._current[0].basis.y.dot(Vector3.UP)<-.92
	var has_contact: bool=not support.is_empty() and inverted
	if has_contact:
		session.contact_ticks+=1; session.contact_run+=1
		session.maximum_contact_run=maxi(int(session.maximum_contact_run),int(session.contact_run))
		session.response_peak=maxf(float(session.response_peak),float(support.response))
		if int(session.contact_ticks)==1:
			worker.idle_play.events.upside_contact+=1; base.idle_play.events.upside_contact+=1
			worker.idle_play._voice("play",-21.0)
		if session.stage=="flight": session.stage="balance"; session.stage_age=0.0
		if session.proofs.size()<96: session.proofs.append({"frame":Engine.get_physics_frames(),"normal":support.normal,"point":support.position,"response":support.response,"roof_shape":support.shape,"root_up":rd._current[0].basis.y,"ground_soles":base._pose.evaluated_soles.duplicate(),"ground_rids":[base._pose.native_support_rid(0),base._pose.native_support_rid(1)],"actual_floor":_base_floor_contacts(base),"geometry_error":_lower_geometry_error(base)})
	else: session.contact_run=0
	if inverted: session.inverted_ticks+=1
	if not _base_supported(base):
		session.lower_floor_faults+=1; cancel("Supporting feet lost their real floor")
	if session.stage=="balance" and has_contact:
		var root=rd.rig.bodies[0]
		var error:=Rig.rotation_vector(Basis(session.goal_basis).get_rotation_quaternion()*rd._current[0].basis.get_rotation_quaternion().inverse())
		var torque: Vector3=(error*100.0-(root.rb.angular_velocity-base.angular_velocity)*16.0).limit_length(BALANCE_TORQUE)
		root.rb.apply_torque_impulse(torque*delta); base.apply_torque_impulse(-torque*delta)
		var relative_velocity: Vector3=root.rb.linear_velocity-(base.linear_velocity+base.angular_velocity.cross(Vector3(support.position)-base.global_position))
		var traction: Vector3=(-relative_velocity.slide(Vector3.UP)*root.mass*3.0).limit_length(BALANCE_TRACTION)
		root.rb.apply_force(traction,Vector3(support.position)-root.rb.global_position)
		base.apply_force(-traction,Vector3(support.position)-base.global_position)
		# Thirty uninterrupted actual contacts already make the quick stunt
		# readable. Push back while that support still exists, before drift can
		# carry the inverted cube off its finite roof.
		if int(session.contact_run)>=30 or session.interrupted:
			var plan:=_return_velocity()
			if plan.is_empty():
				cancel("Original supported return ground changed")
				return false
			session.return_plan=plan
			var velocity: Vector3=plan.velocity
			var turn: Vector3=-rd._current[0].basis.x.normalized()*4.8
			if not _impulse_group(velocity,turn,base,Vector3(support.position),true):
				cancel("Finite supported return motor cannot supply this momentum")
				return false
			session.stage="return"; session.stage_age=0.0
	elif session.stage=="balance" and not has_contact:
		cancel("Actual head support ended; ordinary native get-up owns recovery")
		session.stage="recover"; session.stage_age=0.0
		return false
	elif session.stage=="flight" and float(session.stage_age)>1.0:
		cancel("Native head landing did not settle")
		session.stage="recover"; session.stage_age=0.0
		return false
	if session.stage=="return" or (session.interrupted and session.stage!="flight"): return false
	rd.rig.apply_joint_tone(rd._current,_relative,delta,4.0,3.0,rd.STIFFNESS,rd.CAPS)
	return true

func _return_velocity() -> Dictionary:
	# Recheck the original home surface. Its captured upright whole-body COM
	# offset comes from the evaluated launch geometry, including the holder.
	# Returning DOWN from the peer's head needs far less lift than UP*3.
	var query:=PhysicsRayQueryParameters3D.new()
	query.exclude=worker.query_exclusions(); query.collision_mask=1
	query.from=Vector3(session.home)+Vector3.UP*.3
	query.to=Vector3(session.home)-Vector3.UP*.3
	var hit:=worker.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or hit.collider is RigidBody3D or hit.normal.y<.97 or absf(hit.position.y-Vector3(session.home).y)>.035 or worker.coordinator.yard.unsafe_at(hit.position): return {}
	var centre:=Vector3.ZERO
	var total_mass:=0.0
	var gravity:=Vector3.ZERO
	var linear_damping: float=-1.0
	for body in worker.ragdoll.rig.bodies:
		var native:=PhysicsServer3D.body_get_direct_state(body.rid)
		if not native or native.inverse_mass<=0.0: return {}
		var mass: float=1.0/native.inverse_mass
		centre+=(native.transform*native.center_of_mass_local)*mass
		gravity+=native.total_gravity*mass
		total_mass+=mass
		if linear_damping<0.0: linear_damping=native.total_linear_damp
		elif absf(native.total_linear_damp-linear_damping)>.000001: return {}
	if absf(total_mass-worker.ragdoll.rig.total_mass)>.0001: return {}
	centre/=total_mass; gravity/=total_mass
	var target: Vector3=Vector3(hit.position)+Vector3(session.flight_plan.start_com)-Vector3(session.flight_plan.launch_ground)
	var ticks:=roundi(.65*Engine.physics_ticks_per_second)
	var step: float=1.0/Engine.physics_ticks_per_second
	var damping:=maxf(1.0-linear_damping*step,0.0)
	var unit_velocity:=1.0
	var unit_travel:=0.0
	var gravity_velocity:=Vector3.ZERO
	var gravity_travel:=Vector3.ZERO
	for tick in ticks:
		unit_velocity*=damping; unit_travel+=unit_velocity*step
		gravity_velocity=gravity_velocity*damping+gravity*step
		gravity_travel+=gravity_velocity*step
	if unit_travel<=0.0: return {}
	var velocity: Vector3=(target-centre-gravity_travel)/unit_travel
	if not velocity.is_finite() or velocity.length()>6.3: return {}
	return {"centre":centre,"target":target,"ground":hit.position,"ground_rid":hit.rid,"ground_normal":hit.normal,"duration":ticks*step,"ticks":ticks,"step":step,"gravity":gravity,"linear_damping":linear_damping,"unit_travel":unit_travel,"gravity_travel":gravity_travel,"velocity":velocity}

func _launch_foot_contact() -> Dictionary:
	var rear: Dictionary={}
	var projection:=INF
	var forward: Vector3=Vector3(session.launch_velocity).slide(Vector3.UP).normalized()
	for body_index in [3,4,7,8]:
		var body=worker.ragdoll.rig.bodies[body_index]
		var native:=PhysicsServer3D.body_get_direct_state(body.rid)
		if not native: continue
		for contact in native.get_contact_count():
			var rid:=native.get_contact_collider(contact)
			var normal:=native.get_contact_local_normal(contact)
			if not session.launch_floor_rids.has(rid) or normal.y<.8: continue
			var point:=native.get_contact_collider_position(contact)
			var toward:=forward.dot(point-worker.global_position)
			if toward<projection:
				projection=toward
				rear={"rid":rid,"body":body_index,"point":point,"normal":normal,"response":native.get_contact_impulse(contact).length()}
	return rear

func _base_supported(base: RigidBody3D) -> bool:
	return base.on_ground and base.ground_normal.y>.96 and not is_instance_valid(base._ground_body) and base._pose.evaluated_valid and base._pose.evaluated_grounded[0] and base._pose.evaluated_grounded[1] and base._pose.native_support_rid(0).is_valid() and base._pose.native_support_rid(1).is_valid() and not _base_floor_contacts(base).is_empty()

func _lower_geometry_error(base: RigidBody3D) -> Dictionary:
	var director: RefCounted=base.idle_play.upside_down
	var visual: RefCounted=base.ragdoll.visual
	if director._lower_owners.size()!=9 or visual._remembered.size()!=base._skeleton.get_bone_count(): return {"metres":INF,"radians":INF}
	var native: Transform3D=PhysicsServer3D.body_get_state(base.get_rid(),PhysicsServer3D.BODY_STATE_TRANSFORM)
	var rebase: Transform3D=base.global_transform*visual._remembered_worker.affine_inverse()
	var distance:=0.0
	var angle:=0.0
	for original in base.ragdoll.rig.bodies:
		var expected: Transform3D=rebase*visual._remembered[original.bone]*original.b2b_inv
		expected.basis=expected.basis.orthonormalized()
		var shape_index:=base.shape_owner_get_shape_index(director._lower_owners[original.index],0)
		var actual: Transform3D=native*PhysicsServer3D.body_get_shape_transform(base.get_rid(),shape_index)
		distance=maxf(distance,actual.origin.distance_to(expected.origin))
		# acos(dot) quantises identical float bases to an apparent milliradian.
		# atan2 of the relative quaternion's imaginary norm resolves real small
		# differences without relaxing the same physical angular tolerance.
		var difference: Quaternion=actual.basis.get_rotation_quaternion().inverse()*expected.basis.get_rotation_quaternion()
		angle=maxf(angle,2.0*atan2(Vector3(difference.x,difference.y,difference.z).length(),absf(difference.w)))
	return {"metres":distance,"radians":angle,"evaluation":base._pose.evaluation_serial}

func _base_floor_contacts(base: RigidBody3D) -> Dictionary:
	var director: RefCounted=base.idle_play.upside_down
	if director._lower_owners.size()!=9: return {}
	var native:=PhysicsServer3D.body_get_direct_state(base.get_rid())
	if not native or base.freeze: return {}
	var feet: Array=[[],[]]
	for contact in native.get_contact_count():
		var normal:=native.get_contact_local_normal(contact)
		if normal.y<.8: continue
		var shape_index:=native.get_contact_local_shape(contact)
		var owner:=base.shape_find_owner(shape_index)
		var body_index: int=director._lower_owners.find(owner)
		if body_index not in [3,4,7,8]: continue
		var side:=0 if body_index in [3,4] else 1
		var rid:=native.get_contact_collider(contact)
		if rid!=base._pose.native_support_rid(side): continue
		feet[side].append({"rid":rid,"shape":shape_index,"body":body_index,"normal":normal,"point":native.get_contact_collider_position(contact),"response":native.get_contact_impulse(contact).length()})
	if feet[0].is_empty() or feet[1].is_empty(): return {}
	return {"feet":feet}

func _head_contact(base: RigidBody3D) -> Dictionary:
	var director: RefCounted=base.idle_play.upside_down
	if director._roof_owner<0 or not _base_supported(base): return {}
	var root=worker.ragdoll.rig.bodies[0]
	var native:=PhysicsServer3D.body_get_direct_state(root.rid)
	if not native: return {}
	var shape_index:=base.shape_owner_get_shape_index(director._roof_owner,0)
	var roof: Transform3D=base.global_transform*base.shape_owner_get_transform(director._roof_owner)
	var half: Vector3=base.ragdoll.rig.bodies[0].shape.size*.5
	# Jolt reports face-manifold corners, including the actual roof edges.
	# Keep the original 30 mm support margin on the same finite upper COM;
	# a reported native point still has to lie on this roof's upward face.
	var centre:=Vector3.ZERO
	var mass:=0.0
	for body in worker.ragdoll.rig.bodies:
		var state:=PhysicsServer3D.body_get_direct_state(body.rid)
		if not state or state.inverse_mass<=0.0: return {}
		var body_mass:=1.0/state.inverse_mass
		centre+=(state.transform*state.center_of_mass_local)*body_mass
		mass+=body_mass
	if absf(mass-worker.ragdoll.rig.total_mass)>.0001: return {}
	var contained: Vector3=roof.affine_inverse()*(centre/mass)
	if not contained.is_finite() or absf(contained.x)>half.x-.03 or absf(contained.z)>half.z-.03: return {}
	for contact in native.get_contact_count():
		if native.get_contact_collider_object(contact)!=base or native.get_contact_collider_shape(contact)!=shape_index: continue
		var normal:=native.get_contact_local_normal(contact)
		var point:=native.get_contact_collider_position(contact)
		var local: Vector3=roof.affine_inverse()*point
		if normal.y<.8 or absf(local.y-half.y)>.025 or absf(local.x)>half.x+.00001 or absf(local.z)>half.z+.00001: continue
		return {"position":point,"normal":normal,"response":native.get_contact_impulse(contact).length(),"shape":shape_index}
	return {}

func _impulse_group(velocity: Vector3, spin: Vector3, support: RigidBody3D, point: Vector3, limited_return := false) -> bool:
	var rd: RefCounted=worker.ragdoll
	if limited_return and (int(session.get("return_pulse_count",0))>0 or not is_instance_valid(support) or _head_contact(support).is_empty()): return false
	var com:=Vector3.ZERO
	var total_mass:=0.0
	var states: Array[PhysicsDirectBodyState3D]=[]
	var centres: Array[Vector3]=[]
	var masses: Array[float]=[]
	for body in rd.rig.bodies:
		var native:=PhysicsServer3D.body_get_direct_state(body.rid)
		if not native or native.inverse_mass<=0.0 or absf(native.inverse_inertia_tensor.determinant())<.00000001: return false
		var mass: float=1.0/native.inverse_mass
		var centre: Vector3=native.transform*native.center_of_mass_local
		states.append(native); masses.append(mass); centres.append(centre)
		com+=centre*mass; total_mass+=mass
	if absf(total_mass-rd.rig.total_mass)>.0001: return false
	com/=total_mass
	var reaction:=Vector3.ZERO
	var reaction_torque:=Vector3.ZERO
	var impulses: Array[Vector3]=[]
	var angular_impulses: Array[Vector3]=[]
	for body in rd.rig.bodies:
		var native: PhysicsDirectBodyState3D=states[body.index]
		var centre: Vector3=centres[body.index]
		var impulse: Vector3=(velocity+spin.cross(centre-com)-native.linear_velocity)*masses[body.index]
		var angular: Vector3=native.inverse_inertia_tensor.inverse()*(spin-native.angular_velocity)
		impulses.append(impulse); angular_impulses.append(angular)
		reaction+=impulse; reaction_torque+=angular+(centre-point).cross(impulse)
	var fraction:=1.0
	if limited_return:
		# Saturate this ONE actually supported pulse, preserving every body's
		# real mass, inertia, velocity and lever about the native head contact.
		# A partial pulse changes momentum physically; it never assigns a pose
		# or velocity, and no further pulse or external motor follows in air.
		fraction=minf(fraction,total_mass*6.3/maxf(reaction.length(),.000001))
		fraction=minf(fraction,48.0/maxf(reaction_torque.length(),.000001))
		if fraction<1.0: fraction*=.999999
		session.return_pulse={"frame":Engine.get_physics_frames(),"contact_run":session.contact_run,"point":point,"mass":total_mass,"centre":com,"requested_linear":reaction,"requested_angular":reaction_torque,"fraction":fraction,"states":[]}
		for body in rd.rig.bodies:
			var native: PhysicsDirectBodyState3D=states[body.index]
			session.return_pulse.states.append({"body":body.index,"mass":masses[body.index],"centre":centres[body.index],"inverse_inertia_tensor":native.inverse_inertia_tensor,"velocity":native.linear_velocity,"angular_velocity":native.angular_velocity})
		for index in impulses.size():
			impulses[index]*=fraction; angular_impulses[index]*=fraction
		reaction*=fraction; reaction_torque*=fraction
		session.return_pulse.applied_linear=reaction
		session.return_pulse.applied_angular=reaction_torque
	# The launch remains all-or-decline; a supported return admits only its
	# affordable impulse. Both preserve the same original finite motor caps.
	if not reaction.is_finite() or not reaction_torque.is_finite() or reaction.length()>rd.rig.total_mass*6.3 or reaction_torque.length()>48.0:
		session.rejected_impulse={"point":point,"linear":reaction,"angular":reaction_torque,"mass":rd.rig.total_mass}
		return false
	for body in rd.rig.bodies:
		body.rb.apply_central_impulse(impulses[body.index])
		body.rb.apply_torque_impulse(angular_impulses[body.index])
	if limited_return: session.return_pulse_count=1
	if is_instance_valid(support):
		support.apply_impulse(-reaction,point-support.global_position)
		support.apply_torque_impulse(-reaction_torque)
	# Static terrain takes the original launch's opposite reaction. No velocity
	# assignment or mid-air external steering is used by this optional stunt.
	session.last_impulse=reaction; session.last_angular_impulse=reaction_torque
	return true

func cancel(reason: String) -> void:
	if session.is_empty(): return
	if not session.interrupted:
		session.interrupted=true; session.reason=reason
		for actor: RigidBody3D in [session.base.get_ref(),session.top.get_ref()]:
			if is_instance_valid(actor): actor.idle_play.events.upside_cancel+=1
	if not session.launched: _release(false)

func _release(completed: bool) -> void:
	if session.is_empty(): return
	var actors: Array=[session.base.get_ref(),session.top.get_ref()]
	if is_instance_valid(actors[0]) and not actors[0].idle_play.upside_down._restore_lower_collision(): return
	var result: Dictionary=session.duplicate()
	result.erase("base"); result.erase("top")
	for actor: RigidBody3D in actors:
		if not is_instance_valid(actor) or not actor.idle_play: continue
		var director: RefCounted=actor.idle_play.upside_down
		if actor==actors[0]: result.lower_before=director._roof_baseline
		director.last_result=result; director.session={}
		actor.idle_play.crouch_weight=0.0
		if actor.idle_play.state.begins_with("upside_"): actor.idle_play.state=""
		if completed: actor.idle_play.events.upside_complete+=1
		actor.idle_play._next_play=maxf(actor.idle_play._next_play,8.0)

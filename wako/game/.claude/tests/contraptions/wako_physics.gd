extends Node3D
## Real native body handoff, JSON replay, loaded COM and moving-support recovery.
const Worker = preload("res://LogicObjects/Wako/Wako.tscn")
const Yard = preload("res://Components/Contraptions/contraption_yard.gd")
const Part = preload("res://Components/Contraptions/contraption_part.gd")
var failures := 0
var checks := 0
var minimum_up := 1.0
var maximum_force := 0.0
var maximum_torque := 0.0

func _ready() -> void: _run.call_deferred()

func _advance(seconds: float) -> void:
	for tick in ceili(seconds * 120): await get_tree().physics_frame

func _check(ok: bool, message: String) -> void:
	checks += 1
	print("CONTRAPTION_WAKO_PHYSICS %s %s" % ["ok" if ok else "FAIL", message])
	if not ok: failures += 1

func _box(body: PhysicsBody3D, size: Vector3) -> void:
	var collider := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	collider.shape = box
	body.add_child(collider)

func _worker(position: Vector3) -> RigidBody3D:
	var worker: RigidBody3D = Worker.instantiate()
	add_child(worker)
	worker.global_position = position
	return worker

func _recover(worker: RigidBody3D, seconds := 12.0) -> bool:
	for tick in ceili(seconds * 120):
		minimum_up = minf(minimum_up, worker.ragdoll.rig.bodies[0].rb.global_basis.y.dot(Vector3.UP))
		maximum_force = maxf(maximum_force, worker.ragdoll.assistance_force.length())
		maximum_torque = maxf(maximum_torque, worker.ragdoll.assistance_torque.length())
		if worker.is_available() and worker.on_ground: return true
		await get_tree().physics_frame
	return worker.is_available() and worker.on_ground

func _run() -> void:
	var floor := StaticBody3D.new()
	floor.position.y = -.5
	add_child(floor)
	_box(floor, Vector3(160,1,160))
	var worker := _worker(Vector3(0,.85,0))
	await _advance(1)
	var base_mass: float = 22.0 + worker.back_tool.holder_mass()
	_check(worker.on_ground and worker.ragdoll.rig.bodies.size() == 9 and is_equal_approx(worker.mass,base_mass) and is_equal_approx(worker.ragdoll.rig.total_mass,base_mass), "canonical nine-bone creature includes its authored22kg body and permanent back-holder mass exactly once")
	worker.axis_lock_angular_x = true
	worker.axis_lock_angular_y = false
	worker.axis_lock_angular_z = true
	worker.apply_hit(Vector3(95,12,0))
	await _advance(.15)
	_check(worker.ragdoll.active and worker.freeze and worker.collision_layer == 0 and not worker.is_available(), "hard hit transfers collision/support to native bodies and excludes worker from scheduling")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(worker.serialize_state()))
	_check(saved.physical_body.saved.get("angular_locks",[]) == [true,false,true], "real native impact records the exact mixed capsule angular policy in JSON")
	var expected: Array = saved.physical_body.bodies[0].pose
	var expected_velocity: Array = saved.physical_body.bodies[0].linear
	worker.queue_free()
	await _advance(.02)
	worker = _worker(Vector3(0,.85,0))
	worker.restore_state(saved)
	for tick in 12:
		if worker.ragdoll.active: break
		await get_tree().physics_frame
	var restored: Transform3D = worker.ragdoll._current[0]
	_check(worker.ragdoll.active and worker.freeze and worker.ragdoll.rig.bodies.all(func(b) -> bool: return not b.rb.freeze and b.rb.collision_layer == 256), "actual JSON replay enables every recreated native collider with capsule disabled")
	_check(restored.origin.distance_to(Vector3(expected[9],expected[10],expected[11])) < .001 and worker.ragdoll.rig.bodies[0].rb.linear_velocity.distance_to(Vector3(expected_velocity[0],expected_velocity[1],expected_velocity[2])) < .5 and saved.physical_body.bodies.size() == 9, "replay restores real midfall pose/velocity and does not erase its caller snapshot")
	var recovered := await _recover(worker)
	_check(minimum_up < .5 and recovered and worker.collision_layer == 4 and not worker.freeze, "native cube/legs tumble then contact-supported assistance returns a fitted steady capsule")
	_check(recovered and [worker.axis_lock_angular_x,worker.axis_lock_angular_y,worker.axis_lock_angular_z] == [true,false,true], "supported recovery after actual midfall JSON replay restores the original mixed angular policy")
	_check(maximum_force <= 320.001 and maximum_torque <= 80.001, "supported assistance obeys finite320N and80Nm limits")
	await _advance(.1)
	_check(worker.needs.is_empty(), "settled recovery clears its blocked caption instead of overwriting the successful handoff")
	var state := PhysicsServer3D.body_get_direct_state(worker.get_rid())
	var before := state.linear_velocity
	var damage_received := Core.damage(worker,12,worker.global_position,null,&"gun",10.0,Vector3.RIGHT)
	var after := state.linear_velocity
	_check(damage_received and worker.fear_time >= 2.9 and absf((after-before).x - 10.0/worker.mass) < .01, "public damage reaches the upright helper and applies its explicit impulse once to its actual finite mass")
	await _advance(1.6) # Recovery's short contact cooldown must expire normally.
	Core.damage(worker,18,worker.global_position,null,&"gun",110.0,Vector3.RIGHT)
	await _advance(.1)
	_check(worker.ragdoll.active and not worker.is_available(), "public hard weapon impulse triggers real native fall from the existing capsule velocity")
	if not worker.ragdoll.active:
		Shortcuts.graceful_quit(1)
		return
	var root = worker.ragdoll.rig.bodies[0]
	worker.ragdoll._clock = 1.0
	worker.ragdoll.recovering = true
	state = PhysicsServer3D.body_get_direct_state(root.rid)
	before = state.linear_velocity
	damage_received = Core.damage(root.rb,12,root.rb.global_position,null,&"gun",10.0,Vector3.RIGHT)
	after = state.linear_velocity
	_check(damage_received and root.rb.get_meta(&"damageable") == worker and worker.ragdoll._clock == 0.0 and not worker.ragdoll.recovering and absf((after-before).x - 10.0/root.mass) < .01, "public native-body damage resolves its worker Node, resets recovery and adds no duplicate scripted push")
	worker.queue_free()
	await _advance(.02)
	worker = _worker(Vector3(10,.85,0))
	worker.apply_hit(Vector3(95,12,0))
	var pending: Dictionary = JSON.parse_string(JSON.stringify(worker.serialize_state()))
	_check(pending.physical_body.get("pending",false), "save before modifier activation preserves pending physical hit")
	worker.queue_free()
	await _advance(.02)
	worker = _worker(Vector3(10,.85,0))
	worker.restore_state(pending)
	await _advance(.1)
	_check(worker.ragdoll.active and not worker.is_available(), "pending hit replay activates real native bodies once")
	var malformed: Dictionary = saved.duplicate(true)
	malformed.physical_body.bodies[0].pose = []
	var invalid := _worker(Vector3(15,.85,0))
	invalid.restore_state(malformed)
	_check(invalid.is_available(), "malformed native arrays are rejected without activating corrupt physics")
	invalid.queue_free()
	worker.queue_free()
	await _advance(.02)
	worker = _worker(Vector3(10,4.5,10))
	for tick in 360:
		if worker.ragdoll.active: break
		await get_tree().physics_frame
	_check(worker.ragdoll.active and worker.freeze and not worker.is_available(), "actual gravity fall triggers native limb support at hard landing without a same-tick upright move")
	_check(await _recover(worker), "hard landing recovers through native contacts and bounded assistance")
	worker.queue_free()
	await _advance(.02)
	await _fallen_collision()
	await _loaded_replay()
	await _moving_deck()
	await _blocked_heavy_job()
	print("CONTRAPTION_WAKO_PHYSICS %s checks=%d maxforce=%.3f maxtorque=%.3f" % ["PASS" if failures == 0 else "FAIL (%d)" % failures,checks,maximum_force,maximum_torque])
	Shortcuts.graceful_quit(0 if failures == 0 else 1)

func _fallen_collision() -> void:
	var first := _worker(Vector3(-15,.85,-20))
	var second := _worker(Vector3(-11,.85,-20))
	await _advance(1)
	first.apply_hit(Vector3(95,12,0))
	second.apply_hit(Vector3(-95,12,0))
	var contact_found := false
	for tick in 360:
		if first.ragdoll.active:
			for body in first.ragdoll.rig.bodies:
				var state := PhysicsServer3D.body_get_direct_state(body.rid)
				for contact in state.get_contact_count():
					var other := state.get_contact_collider_object(contact)
					if is_instance_valid(other) and other.has_meta(&"ragdoll_of") and other.get_meta(&"ragdoll_of") == second: contact_found = true
		if contact_found: break
		await get_tree().physics_frame
	_check(contact_found, "two independently fallen helpers physically collide through native layer9 bodies")
	first.queue_free()
	second.queue_free()
	await _advance(.02)

func _loaded_replay() -> void:
	var worker := _worker(Vector3(20,.85,0))
	await _advance(1)
	var base_mass: float = worker.ragdoll.rig.total_mass
	var base_com: Vector3 = worker.ragdoll.rig.bodies[0].rb.center_of_mass
	var base_inertia: Vector3 = worker.ragdoll.rig.bodies[0].rb.inertia
	var cargo := Part.new()
	cargo.setup("bracket","retained_head_load")
	# Author this retained-load fixture at its head seat before entering physics;
	# this is not a pickup or an in-flight pose adjustment.
	cargo.transform = worker.head_anchor.global_transform * Transform3D(Basis.IDENTITY,Vector3(0,.18,0))
	add_child(cargo)
	cargo.set_carried(worker.head_anchor,Vector3(0,.18,0))
	worker.set_cargo(cargo.mass)
	worker.apply_hit(Vector3(125,14,0))
	await _advance(.15)
	var root = worker.ragdoll.rig.bodies[0]
	_check(worker.ragdoll.active and is_equal_approx(worker.ragdoll.rig.total_mass,base_mass+cargo.mass) and root.rb.center_of_mass.y > maxf(.1,base_com.y) and root.rb.inertia.x > maxf(.9,base_inertia.x), "retained5kg head load adds exactly its mass above the permanent holder baseline and raises actual COM/inertia")
	_payload_diagnostic("retained_head_load",worker,cargo,{"base_mass":base_mass,"base_com":base_com,"base_inertia":base_inertia,"mass_ok":is_equal_approx(worker.ragdoll.rig.total_mass,base_mass+cargo.mass),"com_ok":root.rb.center_of_mass.y>maxf(.1,base_com.y),"inertia_ok":root.rb.inertia.x>maxf(.9,base_inertia.x)})
	var saved: Dictionary = JSON.parse_string(JSON.stringify(worker.serialize_state()))
	cargo.set_carried(null)
	worker.queue_free()
	await _advance(.02)
	worker = _worker(Vector3(20,.85,0))
	cargo.set_carried(worker.head_anchor,Vector3(0,.18,0))
	worker.set_cargo(cargo.mass)
	worker.restore_state(saved)
	await _advance(.05)
	_check(worker.ragdoll.active and is_equal_approx(worker.ragdoll.rig.total_mass,base_mass+cargo.mass) and worker.ragdoll.rig.bodies[0].rb.center_of_mass.y > maxf(.1,base_com.y) and worker.ragdoll.rig.bodies[0].rb.inertia.x > maxf(.9,base_inertia.x) and cargo.carrier == worker.head_anchor, "loaded JSON replay retains the same cargo once above the holder baseline with raised native COM/inertia")
	_payload_diagnostic("replayed_head_load",worker,cargo,{"base_mass":base_mass,"base_com":base_com,"base_inertia":base_inertia})
	worker.set_cargo(0)
	cargo.set_carried(null)
	cargo.queue_free()
	_check(is_equal_approx(worker.ragdoll.rig.total_mass,base_mass) and worker.ragdoll.rig.bodies[0].rb.center_of_mass.distance_to(base_com) < .001 and worker.ragdoll.rig.bodies[0].rb.inertia.distance_to(base_inertia) < .001, "removing native head load restores the original permanent-holder mass, COM and inertia without another capsule body")
	_check(await _recover(worker), "replayed physical fall can still recover after its head load is released")
	worker.queue_free()
	await _advance(.02)

func _moving_deck() -> void:
	var deck := RigidBody3D.new()
	deck.mass = 15000
	deck.gravity_scale = 0 # Isolated freely moving test support, not game assistance.
	deck.linear_damp = 0
	deck.angular_damp = 0
	add_child(deck)
	deck.position = Vector3(35,3,0)
	_box(deck,Vector3(18,.4,18))
	deck.linear_velocity = Vector3(1.6,0,0)
	var worker := _worker(Vector3(35,4.05,0))
	await _advance(1)
	worker.apply_hit(Vector3(95,12,0))
	var saw_deck := false
	for tick in 240:
		var support: Dictionary = worker.ragdoll._ground_support() if worker.ragdoll.active else {}
		if support.get("rid") == deck.get_rid() and worker.ragdoll.assistance_force.length() > 0: saw_deck = true; break
		await get_tree().physics_frame
	_check(saw_deck and deck.linear_velocity.y < -.01, "native get-up uses actual moving-deck contacts and applies weight reaction to it")
	worker.ragdoll.rig.bodies[0].rb.apply_central_impulse(Vector3(0,120,0))
	await _advance(.3)
	_check(worker.ragdoll.active and worker.ragdoll._ground_support().is_empty() and worker.ragdoll.assistance_force.is_zero_approx() and worker.ragdoll.assistance_torque.is_zero_approx(), "losing real support immediately disables all lift/attitude assistance during native flight")
	_check(await _recover(worker,18) and worker._ground_body == deck and worker.ground_velocity.x > 1.2, "airborne native body lands and regains fitted standing support on the same moving deck")
	worker.queue_free()
	deck.queue_free()
	await _advance(.02)

func _blocked_heavy_job() -> void:
	var yard := Yard.new()
	yard.position = Vector3(0,0,40)
	add_child(yard)
	yard.work_paused = true
	yard.coordinator.set_physics_process(false)
	for enemy: Node3D in yard.enemies:
		enemy.set_physics_process(false)
		enemy.assembly.active = false
		if is_instance_valid(enemy.mind_host): enemy.mind_host.shutdown()
		for part: RigidBody3D in enemy.assembly.parts.values(): part.freeze = true
	await _advance(1)
	await _recruitment_lifetime(yard)
	var first: RigidBody3D = yard.workers[0]
	var second: RigidBody3D = yard.workers[1]
	var first_base_mass: float = first.mass
	var second_base_mass: float = second.mass
	var first_native_base_mass: float = first.ragdoll.rig.total_mass
	first.global_position = Vector3(45,.85,45)
	second.global_position = Vector3(46.4,.85,45)
	await _advance(.1)
	var cargo: Node3D = yard.available_part("chassis")
	var job := {"id":"native_heavy","kind":"salvage","part":cargo,"target":yard.storage,"heavy":true}
	var crew: Array = [first,second]
	yard.work_paused = false
	var reserved := yard.reserve_job(job,crew)
	var picked := reserved and yard.perform_work(job,0.0,"pickup",crew)
	for worker: Node in crew: worker.set_cargo(cargo.mass/2); worker.current_job_id = job.id
	yard.coordinator.active_jobs[job.id] = {"job":job,"crew":crew,"phase":"carry","elapsed":0.0,"progress":0.0}
	var tool: Node3D = yard.available_part("assembly_tool")
	yard._equip_worker_tool(tool,first)
	var obstacle := StaticBody3D.new()
	add_child(obstacle)
	obstacle.position = Vector3(45,4,45)
	_box(obstacle,Vector3(25,12,25)) # Blocks every bounded safe set-down site.
	await _advance(.02)
	var cargo_identity: int = cargo.get_instance_id()
	var cargo_rid: RID = cargo.get_rid()
	var cargo_mass: float = cargo.mass
	var cargo_pose: Transform3D = cargo.global_transform
	Core.damage(first,18,first.global_position,null,&"gun",350.0,Vector3.RIGHT)
	_payload_diagnostic("heavy_hit_immediate",first,cargo,{"first_base_mass":first_base_mass,"second_base_mass":second_base_mass,"second_mass":second.mass,"first_native_base_mass":first_native_base_mass,"source_tool":tool.part_id,"source_tool_mass":tool.mass,"source_tool_carrier":str(tool.carrier),"source_tool_worker":tool.get_meta(&"equipped_worker","")})
	_check(picked and not yard.coordinator.active_jobs.has(job.id) and not yard._reservations.has(job.id) and first.current_job_id.is_empty() and second.current_job_id.is_empty(), "hard hit atomically interrupts coordinated110kg head carry and releases both workers' leases")
	_check(cargo.get_instance_id() == cargo_identity and cargo.get_rid() == cargo_rid and is_equal_approx(cargo.mass,cargo_mass) and cargo.global_transform.is_equal_approx(cargo_pose) and cargo.carrier == null and not cargo.freeze and cargo.collision_layer == 1 and not cargo.get_meta(&"awaiting_setdown",false) and not cargo.get_meta(&"in_transit",false) and cargo.linear_velocity.is_finite() and cargo.angular_velocity.is_finite() and yard.loose_parts.count(cargo) == 1 and not yard._part_reserved(cargo) and is_equal_approx(first.mass,first_base_mass) and is_equal_approx(second.mass,second_base_mass), "interrupted heavy load releases the original native body at its exact current pose with finite motion, single custody and both workers' original mass")
	_check(first.equipped_tool == null and tool.carrier == null and str(tool.get_meta(&"equipped_worker","")) == "" and yard.loose_parts.count(tool) == 1, "interruption releases the actual foot tool once before native support takes over")
	await _advance(.05)
	_check(first.ragdoll.active and is_equal_approx(first.ragdoll.rig.total_mass,first_native_base_mass), "native body handoff occurs after heavy cargo/tool cleanup with only the original permanent-holder baseline")
	_payload_diagnostic("heavy_handoff",first,cargo,{"first_base_mass":first_base_mass,"first_native_base_mass":first_native_base_mass})
	var saved: Dictionary = JSON.parse_string(JSON.stringify(yard.serialize()))
	var id: String = cargo.part_id
	var worker_id: String = first.worker_id
	yard.work_paused = true
	yard.restore(saved)
	yard.coordinator.set_physics_process(false)
	await _advance(.1)
	cargo = yard.loose_parts.filter(func(p: Node)->bool: return p.part_id == id)[0]
	first = yard.workers.filter(func(w:Node)->bool: return w.worker_id == worker_id)[0]
	_check(cargo.part_id == id and is_equal_approx(cargo.mass,cargo_mass) and cargo.carrier == null and not cargo.freeze and cargo.collision_layer == 1 and not cargo.get_meta(&"awaiting_setdown",false) and not cargo.get_meta(&"in_transit",false) and cargo.linear_velocity.is_finite() and cargo.angular_velocity.is_finite() and yard.loose_parts.count(cargo) == 1 and not yard._part_reserved(cargo) and first.ragdoll.active and is_equal_approx(first.ragdoll.rig.total_mass,first_native_base_mass), "actual yard JSON restores the same heavy resource once in native motion and its worker's original permanent-holder mass")
	_payload_diagnostic("heavy_json_replay",first,cargo,{"first_base_mass":first_base_mass,"first_native_base_mass":first_native_base_mass,"cargo_instances":yard.loose_parts.count(cargo),"saved_worker":saved.workers.filter(func(w:Dictionary)->bool:return str(w.get("id",""))==worker_id)})
	obstacle.queue_free()
	await _advance(1)
	_check(is_equal_approx(cargo.mass,cargo_mass) and cargo.carrier == null and not cargo.freeze and cargo.collision_layer == 1 and not cargo.get_meta(&"awaiting_setdown",false) and cargo.linear_velocity.is_finite() and cargo.angular_velocity.is_finite() and yard.loose_parts.count(cargo) == 1 and not yard._part_reserved(cargo), "after obstruction removal the same released resource continues native motion with single unreserved custody")
	yard.queue_free()
	await _advance(.05)

func _recruitment_lifetime(yard: Node3D) -> void:
	var worker := _worker(Vector3(-45,.85,40))
	await _advance(1)
	var rig = worker.ragdoll.rig
	var original_rig_mass: float = rig.total_mass
	var capsule_id: int = worker.get_instance_id()
	var capsule_rid: RID = worker.get_rid()
	var holder_id: int = rig.root.get_instance_id()
	var body_ids: Array[int] = []
	var body_rids: Array[RID] = []
	var body_masses: Array[float] = []
	for body in rig.bodies:
		body_ids.append(body.rb.get_instance_id())
		body_rids.append(body.rid)
		body_masses.append(body.rb.mass)
	var adopted: Node = yard.adopt_worker(worker,worker.global_position)
	await _advance(.02)
	var same: bool = adopted == worker and worker.get_instance_id() == capsule_id and worker.get_rid() == capsule_rid and worker.get_parent() == yard and yard.workers.count(worker) == 1 and rig.bodies.size() == 9 and not rig.enabled and is_equal_approx(rig.total_mass,original_rig_mass)
	if rig.bodies.size() == 9:
		for index in 9:
			var body = rig.bodies[index]
			same = same and body.rb.get_instance_id() == body_ids[index] and body.rid == body_rids[index] and is_equal_approx(body.rb.mass,body_masses[index]) and body.rb.process_mode == Node.PROCESS_MODE_DISABLED
	_check(same, "actual yard recruitment reparents one idle capsule while preserving all nine original native body identities, RIDs and masses")
	if same:
		worker.apply_hit(Vector3(95,12,0))
		await _advance(.15)
		_check(worker.ragdoll.active and rig.bodies.size() == 9 and rig.bodies[0].rid == body_rids[0], "recruited helper transfers a real impact to its original native rig")
		_check(await _recover(worker), "recruited helper recovers through real support and the existing bounded assistance")
	yard.workers.erase(worker)
	worker.queue_free()
	await _advance(.05)
	var removed: bool = not is_instance_id_valid(capsule_id) and not is_instance_id_valid(holder_id) and rig.bodies.is_empty()
	for body_id: int in body_ids: removed = removed and not is_instance_id_valid(body_id)
	_check(removed, "actual helper deletion disposes every recruited native body and its holder without an orphan rig")

func _payload_diagnostic(label: String, worker: RigidBody3D, cargo: Node3D, baseline: Dictionary) -> void:
	var root = worker.ragdoll.rig.bodies[0]
	var tool: Node3D = worker.equipped_tool if is_instance_valid(worker.equipped_tool) else null
	print("CONTRAPTION_WAKO_PAYLOAD ",label," ",{"worker_mass":worker.mass,"worker_freeze":worker.freeze,"cargo_share":worker.cargo_mass,"holder_mass":worker.back_tool.holder_mass(),"holder_load":worker.back_tool.holder_load(),"onboard_tool_mass":worker.back_tool.onboard_mass(),"tool":str(tool),"tool_mass":tool.mass if tool else 0.0,"tool_carrier":str(tool.carrier) if tool else "none","tool_freeze":tool.freeze if tool else false,"tool_phase":worker.back_tool.phase,"native_mass":worker.ragdoll.rig.total_mass,"root_mass":root.rb.mass,"root_com":root.rb.center_of_mass,"root_inertia":root.rb.inertia,"ragdoll_active":worker.ragdoll.active,"ragdoll_pending":worker.ragdoll.pending,"cargo_mass":cargo.mass,"cargo_carrier":str(cargo.carrier),"cargo_on_head":cargo.carrier==worker.head_anchor,"cargo_freeze":cargo.freeze,"cargo_layer":cargo.collision_layer,"awaiting_setdown":cargo.get_meta(&"awaiting_setdown",false),"in_transit":cargo.get_meta(&"in_transit",false),"cargo_meta":cargo.get_meta_list()}," baseline=",baseline)

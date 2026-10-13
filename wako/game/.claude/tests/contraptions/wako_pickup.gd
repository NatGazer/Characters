extends "res://.claude/tests/contraptions/integration.gd"
## Real depot access, evaluated toe grip, native same-body flight/head catch,
## resource leases, complete body keepout, cancellation and JSON interruption.
const Part = preload("res://Components/Contraptions/contraption_part.gd")
var state_samples := {}
var source_ids: Array[String] = []
var saw_separate_foot := false
var bad_contact := false
var bad_weight := false
var cube_intersections := 0
var flight_samples := 0
var maximum_launch_impulse := 0.0
var maximum_momentum_error := 0.0
var maximum_held_error := 0.0
var _last_flight: Dictionary = {}
var maximum_gravity_error := 0.0
var inspection_contacts := 0
var externally_struck_flights: Dictionary = {}
var _last_release_sole: Dictionary = {}
var maximum_release_step := 0.0
var maximum_release_knee_step := 0.0
var maximum_release_ankle_step := 0.0
var minimum_release_support_gap := INF
var _release_query := PhysicsRayQueryParameters3D.new()
var release_samples := 0

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if not is_instance_valid(yard): return
	for worker: Node in yard.workers:
		if not worker.pickup or not is_instance_valid(worker.pickup.part): continue
		var pickup: RefCounted = worker.pickup
		var source: RigidBody3D = pickup.part
		var key: String = source.part_id + ":" + pickup.state
		state_samples[key] = int(state_samples.get(key,0)) + 1
		if pickup.state in ["held","flight","caught"]:
			if not source_ids.has(source.part_id): source_ids.append(source.part_id)
			if is_instance_valid(worker.equipped_tool): saw_separate_foot = saw_separate_foot or worker.work_foot_side != worker.tool_foot_side()
			var held_mass: float = source.mass if pickup.state in ["held","caught"] else 0.0
			var tool_mass: float = worker.equipped_tool.mass if is_instance_valid(worker.equipped_tool) else 0.0
			bad_weight = bad_weight or absf(worker.mass-22.0-worker.back_tool.holder_mass()-held_mass-tool_mass)>.01
		if not worker._pose.evaluated_valid: continue
		var sole: Vector3 = worker._pose.evaluated_soles[worker.work_foot_side]
		var knee: Vector3 = (worker._pose.evaluated_knees[worker.work_foot_side]-worker._pose.evaluated_hips[worker.work_foot_side]).normalized()
		var ankle: Quaternion = worker._pose.evaluated_ankles[worker.work_foot_side].get_rotation_quaternion()
		if pickup.state == "flight" and pickup.release_progress() < 1.0:
			release_samples += 1
			_release_query.from = sole+Vector3.UP*.05
			_release_query.to = sole-Vector3.UP*.3
			_release_query.collision_mask = 1
			var release_exclusions: Array[RID] = worker.query_exclusions()
			release_exclusions.append(source.get_rid())
			if is_instance_valid(worker.equipped_tool): release_exclusions.append(worker.equipped_tool.get_rid())
			_release_query.exclude = release_exclusions
			var release_support: Dictionary = worker.get_world_3d().direct_space_state.intersect_ray(_release_query)
			if not release_support.is_empty():
				var support_gap: float = release_support.normal.dot(sole-release_support.position)
				if "--pickup-sole-debug" in OS.get_cmdline_user_args() and support_gap < minimum_release_support_gap and support_gap < -.001:
					print("CONTRAPTION_RELEASE_SUPPORT phase=%.6f clock=%.6f blend=%.6f sole=%s support=%s body=%s" % [worker.action_progress,pickup._flight_clock,pickup.release_progress(),sole,release_support.position,release_support.collider])
				minimum_release_support_gap = minf(minimum_release_support_gap,support_gap)
			if _last_release_sole.get("source",0)==source.get_instance_id() and _last_release_sole.get("tick",0)==_tick-1:
				maximum_release_step = maxf(maximum_release_step,sole.distance_to(_last_release_sole.sole))
				maximum_release_knee_step = maxf(maximum_release_knee_step,rad_to_deg(knee.angle_to(_last_release_sole.knee)))
				maximum_release_ankle_step = maxf(maximum_release_ankle_step,rad_to_deg(ankle.angle_to(_last_release_sole.ankle)))
		_last_release_sole = {"source":source.get_instance_id(),"tick":_tick,"sole":sole,"knee":knee,"ankle":ankle}
		var root: Transform3D = worker.global_transform * worker._pose.evaluated_worker.affine_inverse() * worker._pose.evaluated_root
		var cube := AABB(Vector3(-.38,-.3,-.38),Vector3(.76,.68,.76))
		var envelope: AABB = root.affine_inverse() * source.global_transform * Catalogue.bounds_of(source.definition)
		if pickup.state in ["held","flight"] and cube.intersects(envelope): cube_intersections += 1
		if pickup.state == "held":
			var toe: Transform3D = worker.foot_grip_transform
			maximum_held_error = maxf(maximum_held_error,(toe.origin+toe.basis.y*.035).distance_to(pickup.foot_anchor.global_position))
		if pickup.state == "flight":
			flight_samples += 1
			maximum_launch_impulse = maxf(maximum_launch_impulse,pickup.launch_impulse.length())
			maximum_momentum_error = maxf(maximum_momentum_error,pickup.launch_before_momentum.distance_to(pickup.launch_after_momentum))
			if not externally_struck_flights.has(source.get_instance_id()) and _last_flight.get("id",0) == source.get_instance_id() and int(_last_flight.get("tick",0)) == _tick-1:
				var acceleration: Vector3 = (source.linear_velocity-Vector3(_last_flight.velocity))/delta
				maximum_gravity_error = maxf(maximum_gravity_error,acceleration.distance_to(Vector3.DOWN*9.8))
			_last_flight = {"id":source.get_instance_id(),"tick":_tick,"velocity":source.linear_velocity}
		if pickup.state == "caught":
			maximum_momentum_error = maxf(maximum_momentum_error,pickup.catch_before_momentum.distance_to(pickup.catch_after_momentum))

func _observe_contacts(worker: Node) -> void:
	worker.action_contact.connect(func(kind: String) -> void:
		if kind == "pickup" and worker.pickup.manipulating():
			bad_contact = bad_contact or not worker.on_ground or not worker.stance_valid or not worker.pickup.contact_ready()
		if kind == "inspect":
			inspection_contacts += 1
			bad_contact = bad_contact or not worker.on_ground or not worker.stance_valid or not worker.foot_contact_ready())

func _run() -> void:
	var floor := StaticBody3D.new()
	floor.position.y = -.5
	add_child(floor)
	var collider := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(160,1,160)
	collider.shape = box
	floor.add_child(collider)
	yard = Yard.new()
	add_child(yard)
	yard.work_paused = true
	await _advance(.3)
	_park_fauna()
	for arg: String in OS.get_cmdline_user_args():
		if arg not in ["--pickup-foot=left", "--pickup-foot=right"]: continue
		var side := 1 if arg.ends_with("right") else 0
		for number in 100:
			var id := "pickup_animation_%d" % number
			if absi(id.hash()) % 2 == side:
				yard.workers[0].worker_id = id
				break
	print("CONTRAPTION_PICKUP worker_id=",yard.workers[0].worker_id," tool_foot=",yard.workers[0].tool_foot_side())
	for worker: Node in yard.workers:
		worker.paused = worker != yard.workers[0]
		_observe_contacts(worker)
	var stock: int = yard.loose_parts.size()
	var bracket: Node = yard.available_part("bracket")
	var lamp: Node = yard.available_part("light")
	var bracket_id: String = bracket.part_id
	var lamp_id: String = lamp.part_id
	_check(yard.plan_blueprint({"name":"Foot pickup fixture","parts":[Plans.piece("frame","bracket",Vector3.ZERO),Plans.piece("lamp","light",Vector3(.3,.2,0),"frame")]}),"selects a genuine two-part plan using existing bracket/lamp stock")
	yard.work_paused = false
	var built := await _wait_until(_built_selected,90.0)
	_check(built,"actual helpers enter the existing depot and build bracket plus lamp from real stock")
	if not built: _dump_workers(); _finish(); return
	_check(source_ids.has(bracket_id) and source_ids.has(lamp_id) and yard.loose_parts.size()==stock-2,"both exact stock identities travel through foot/native/head phases and each installs once")
	_check(state_samples.has(bracket_id+":held") and state_samples.has(bracket_id+":flight") and state_samples.has(bracket_id+":caught") and flight_samples>60,"the same light rigid body leaves the real toe and travels under native gravity before a head-zone catch")
	_check(saw_separate_foot and not bad_contact and not bad_weight,"opposite foot keeps the tool, supporting sole gates toe contact and held/airborne mass is counted once")
	_check(cube_intersections==0 and maximum_held_error<.005,"actual complete component bounds stay outside the currently evaluated cube throughout lift/flight")
	_check(maximum_launch_impulse<=40.01 and maximum_momentum_error<.05 and maximum_gravity_error<.2,"bounded native launch/catch preserve actual linear momentum and flight has gravity without a scripted path")
	_check(inspection_contacts>=2,"a distinct toe-held inspection probe reaches actual parts before construction advances")
	_check(release_samples>30 and maximum_release_step<.06,"evaluated kicking leg follows through and returns gradually without a one-tick ground-pose snap")
	_check(maximum_release_knee_step<12.0 and maximum_release_ankle_step<18.0,"evaluated released knee and ankle keep continuous orientation throughout the real sole return")
	_check(minimum_release_support_gap >= -.001 and minimum_release_support_gap < .03,"the released sole returns above actual native support instead of sweeping through it")
	# Interrupt a real loose light load before its kick. No synthetic contacts.
	var source := Part.new()
	source.setup("bracket","interrupt_light",true)
	yard.add_child(source)
	source.global_position = Vector3(-3,.16,5)
	yard.add_loose_part(source)
	var held := await _wait_until(func()->bool:return yard.workers[0].pickup.state=="held" and yard.workers[0].pickup.part==source,45.0)
	_check(held,"loose salvage reaches genuine gripping-foot contact")
	if held:
		yard.coordinator.interrupt_worker(yard.workers[0],"Pickup interruption fixture")
		_check(is_instance_valid(source) and source.carrier==null and not source.get_meta(&"in_transit",false) and not yard._part_reserved(source),"interrupted toe cargo releases its original body and reservation safely")
	# Save during actual flight, restore through the existing safe-setdown path.
	yard.work_paused = false
	var airborne := await _wait_until(func()->bool:return yard.workers[0].pickup.state=="flight",60.0)
	_check(airborne,"recovered exact loose resource can retry through an actual native toss")
	if airborne:
		var id: String = yard.workers[0].pickup.part.part_id
		var data: Dictionary = JSON.parse_string(JSON.stringify(yard.serialize()))
		yard.restore(data)
		await _advance(.3)
		_park_fauna()
		var restored: Array = yard.loose_parts.filter(func(p:Node)->bool:return p.part_id==id)
		_check(restored.size()==1 and restored[0].carrier==null and restored[0].linear_damp>.1,"JSON mid-flight interruption restores exactly one physical source with normal damping and safe release")
		var stored := await _wait_until(func()->bool:return restored[0].get_meta(&"stored",false),60.0)
		_check(stored,"restored interrupted load is automatically recovered and stowed without manufacturing a replacement")
	# A real external sideways hit can spoil a catch. Recovery must restore the
	# temporary damping and self-collision exclusion even after state == failed.
	var missed := Part.new()
	missed.setup("light", "missed_catch_light", true)
	yard.add_child(missed)
	missed.global_position = Vector3(-3,.12,5)
	yard.add_loose_part(missed)
	var kicked := await _wait_until(func()->bool:return yard.workers[0].pickup.state=="flight" and yard.workers[0].pickup.part==missed,45.0)
	_check(kicked,"a separately reserved light reaches an actual kick before an external hit spoils its catch")
	if kicked:
		var worker: RigidBody3D = yard.workers[0]
		externally_struck_flights[missed.get_instance_id()] = true
		missed.apply_central_impulse(Vector3(8,0,0))
		var released := await _wait_until(func()->bool:return is_instance_valid(missed) and not missed.get_meta(&"in_transit",false) and not yard._part_reserved(missed),5.0)
		_check(released and missed.carrier==null and missed.linear_damp>.1 and missed.linear_damp_mode==RigidBody3D.DAMP_MODE_COMBINE and not missed.get_collision_exceptions().has(worker),"a genuinely missed catch releases the same body, normal damping, self-collision and resource lease")
	_check(cube_intersections==0 and maximum_momentum_error<.05,"interrupted and JSON-resumed tosses also preserve whole-body keepout and native momentum")
	print("CONTRAPTION_PICKUP flight_samples=",flight_samples," cube_hits=",cube_intersections," impulse=",maximum_launch_impulse," momentum_error=",maximum_momentum_error," gravity_error=",maximum_gravity_error," grip_error=",maximum_held_error," release_step=",maximum_release_step," knee_step=",maximum_release_knee_step," ankle_step=",maximum_release_ankle_step," sole_gap=",minimum_release_support_gap)
	_finish()

func _finish() -> void:
	print("CONTRAPTION_PICKUP %s ticks=%d" % ["PASS" if failures==0 else "FAIL (%d)"%failures,_tick])
	Shortcuts.graceful_quit(0 if failures==0 else 1)

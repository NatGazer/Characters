extends "res://.claude/tests/contraptions/tools.gd"
## Real stock construction followed by distinct foot repair and joint straightening.
var worker: Node
var work_samples := {"repair": {}, "unbend": {}}
var unbend_contacts := 0
var current_stage := "construction"
var current_motor: RigidBody3D
var current_connection: Node3D
var minimum_support_gap := INF

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if not is_instance_valid(worker) or not worker._pose.evaluated_valid: return
	if not work_samples.has(worker.action): return
	if _tick % 4 == 0 and worker.on_ground and is_instance_valid(worker.equipped_tool):
		var tool: Node3D = worker.equipped_tool
		if _tool_vertices.has(tool.get_instance_id()):
			for vertex: Vector3 in _tool_vertices[tool.get_instance_id()]:
				minimum_support_gap = minf(minimum_support_gap, worker.ground_normal.dot(tool.to_global(vertex) - worker._ground_point))
	var band := clampi(int(worker.action_progress*5.0),0,4)
	if work_samples[worker.action].has(band): return
	var root: Transform3D = worker.global_transform*worker._pose.evaluated_worker.affine_inverse()*worker._pose.evaluated_root
	work_samples[worker.action][band] = {"position": worker._model.global_basis.inverse()*(root.origin-worker.global_position),
		"basis": worker._model.global_basis.inverse()*root.basis}

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
	worker = yard.workers[0]
	var side := 0
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--repair-foot=right": side = 1
	_choose_tool_foot(worker, side)
	for w: Node in yard.workers: w.paused = w != worker
	worker.action_contact.connect(_contact)
	var stock: int = yard.loose_parts.size()
	_check(yard.plan_blueprint({"name":"Mechanical repair work","parts":[Plans.piece("frame","bracket",Vector3.ZERO),Plans.piece("drive","motor",Vector3(0,.35,0),"frame")]}),"selects a real two-component repair fixture from stored stock")
	yard.work_paused = false
	var built := await _wait_until(_built_selected,80.0)
	_check(built and yard.loose_parts.size()==stock-2,"automatic helpers complete actual reserved construction before the animation check")
	if not built: _dump_workers(); _finish(); return
	current_motor = yard.selected_assembly.parts.drive
	current_connection = yard.selected_assembly.connections[0]
	var tool_id: String = worker.equipped_tool.part_id
	current_stage = "repair"
	current_motor.take_damage(30.0,current_motor.global_position,null,&"test")
	_check(current_motor.health<99,"native component damage creates a genuine repair need")
	var repaired := await _wait_until(func()->bool:return current_motor.health>99,45.0)
	_check(repaired and repair_contacts>0,"precision repair contacts restore the damaged component through automatic foot work")
	if not repaired: _dump_workers()
	current_stage = "unbend"
	current_connection.deformation = Vector3(.12,.07,0)
	var unbent := await _wait_until(func()->bool:return current_connection.deformation.length()<.018,45.0)
	_check(unbent and unbend_contacts>0,"sustained counterload contacts straighten the actual yielded connection")
	if not unbent: _dump_workers()
	_check(not invalid_contact and planted_contacts>=repair_contacts+unbend_contacts,"every maintenance event has real sole support and evaluated toe/tool contact")
	_check(worker.equipped_tool.part_id==tool_id and worker.equipped_tool.carrier==worker.tool_anchor and yard.loose_parts.size()==stock-2,"the same reusable toe-held tool and installed resources remain conserved")
	_check(shaft_samples>200 and shaft_intersections==0 and visual_samples>50 and visual_intersections==0,"complete actual mallet mesh and shaft clear the rigid cube throughout both work motions")
	_check(is_finite(minimum_support_gap) and minimum_support_gap >= -.001,"the whole toe-held mallet stays above its observed support throughout preparation, contact and release")
	var displacement := 0.0
	var rotation := 0.0
	for band: int in work_samples.repair:
		if not work_samples.unbend.has(band): continue
		var first: Dictionary = work_samples.repair[band]
		var second: Dictionary = work_samples.unbend[band]
		displacement = maxf(displacement,first.position.distance_to(second.position))
		rotation = maxf(rotation,first.basis.get_rotation_quaternion().angle_to(second.basis.get_rotation_quaternion()))
	_check(work_samples.repair.size()>=4 and work_samples.unbend.size()>=4 and (displacement>.025 or rotation>.08),"actual rendered-body poses distinguish precision repair from loaded straightening")
	print("WAKO_REPAIR samples=",work_samples," contact=",repair_contacts,"/",unbend_contacts," root_delta=",displacement," rotation=",rotation," support_gap=",minimum_support_gap)
	_finish()

func _contact(kind: String) -> void:
	if kind not in ["assemble","repair","unbend"]: return
	planted_contacts += 1
	if kind == "repair": repair_contacts += 1
	if kind == "unbend": unbend_contacts += 1
	var toe: Transform3D = worker.foot_grip_transform
	var tip: Vector3 = toe.origin+toe.basis.y.normalized()*(.035+worker.foot_tool_span())
	invalid_contact = invalid_contact or not worker.on_ground or not worker.stance_valid or tip.distance_to(worker.work_point())>.18

func _finish() -> void:
	print("WAKO_REPAIR %s ticks=%d" % ["PASS" if failures==0 else "FAIL (%d)" % failures,_tick])
	Shortcuts.graceful_quit(0 if failures==0 else 1)

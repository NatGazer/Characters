extends Node3D
## Real workshop/worker/physics integration; does not complete construction by setting installed flags.
## Run: godot --headless --path . --fixed-fps 60 res://.claude/tests/contraptions/integration.tscn

const Yard := preload("res://Components/Contraptions/contraption_yard.gd")
const Plans := preload("res://Components/Contraptions/blueprints.gd")
const Catalogue := preload("res://Components/Contraptions/part_catalog.gd")

var yard: Node3D
var failures := 0
var saw_cargo := false
var saw_heavy_crew := false
var saw_repair := false
var _observing := false
var _tick := 0


func _ready() -> void:
	_run.call_deferred()


func _check(ok: bool, explanation: String) -> void:
	print("CONTRAPTION %s %s" % ["ok" if ok else "FAIL", explanation])
	if not ok:
		failures += 1


func _physics_process(_delta: float) -> void:
	_tick += 1
	if not _observing or not is_instance_valid(yard):
		return
	for part: Variant in yard.loose_parts:
		if is_instance_valid(part) and is_instance_valid(part.get("carrier")):
			saw_cargo = true
	for reservation: Dictionary in yard.get("_reservations").values():
		if reservation.get("workers", []).size() >= 2:
			saw_heavy_crew = true
	for worker: Variant in yard.workers:
		if is_instance_valid(worker) and worker.get("action") == "repair":
			saw_repair = true


func _wait_until(condition: Callable, seconds: float) -> bool:
	for i in int(seconds * 120.0):
		if condition.call():
			return true
		await get_tree().physics_frame
	return bool(condition.call())


func _advance(seconds: float) -> void:
	for i in int(seconds * 120.0):
		await get_tree().physics_frame

func _park_fauna() -> void:
	# Isolate construction work from autonomous hostile pursuit. Keep the live
	# physical cores for the later native damage/salvage/rescue assertions.
	for enemy: Node3D in yard.enemies:
		enemy.set_physics_process(false)
		enemy.assembly.active = false
		if is_instance_valid(enemy.mind_host): enemy.mind_host.shutdown()
		for part: RigidBody3D in enemy.assembly.parts.values():
			part.freeze = true


func _inventory() -> Dictionary:
	var counts := {}
	for assembly: Variant in yard.assemblies:
		if not is_instance_valid(assembly):
			continue
		for part: Variant in assembly.parts.values():
			if is_instance_valid(part) and part.installed:
				counts[part.kind] = int(counts.get(part.kind, 0)) + 1
	for part: Variant in yard.loose_parts:
		if is_instance_valid(part) and not part.is_queued_for_deletion():
			counts[part.kind] = int(counts.get(part.kind, 0)) + 1
	return counts


func _built_selected() -> bool:
	if not is_instance_valid(yard.selected_assembly):
		return false
	for part: Variant in yard.selected_assembly.parts.values():
		if not part.installed:
			return false
	return not yard.selected_assembly.parts.is_empty()


func _dump_workers() -> void:
	for worker: Variant in yard.workers:
		if is_instance_valid(worker):
			print("CONTRAPTION worker ", worker.get("status_text"), " needs=", worker.get("needs"),
				" pos=", worker.global_position, " target=", worker.get("target_position"), " ground=", worker.get("on_ground"),
				" action=", worker.get("action"), " job=", worker.get("current_job_id"))
	print("CONTRAPTION reservations ", yard.get("_reservations"))
	for entry: Dictionary in yard.coordinator.active_jobs.values():
		print("CONTRAPTION active phase=", entry.phase, " kind=", entry.job.kind, " part=", entry.job.part.part_id,
			" target=", entry.job.target.global_position, " elapsed=", entry.elapsed)


func _run() -> void:
	var ground := StaticBody3D.new()
	ground.position = Vector3(0, -0.5, 0)
	add_child(ground)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(160, 1, 160)
	shape.shape = box
	ground.add_child(shape)
	yard = Yard.new()
	yard.name = "Workshop"
	add_child(yard)
	_observing = true
	await _advance(1.0)
	_check(yard.workers.size() == 3 and yard.enemies.size() == 3, "live workshop has helpers and three enemy body plans")
	_park_fauna()
	_check(Plans.validate(Plans.rover(), Catalogue.all()).is_empty(), "rover blueprint graph validates")
	var donor: Node3D = yard.assemblies[0]
	var recovered: RigidBody3D = donor.parts["cell"]
	var donor_inventory := _inventory()
	var salvage_condition: float = recovered.health
	var strikes: Array[StringName] = []
	for i in 3:
		var hit_point := recovered.global_position
		strikes.append(recovered.pickaxe_hit(hit_point, Vector3.UP, Vector3.FORWARD))
		Core.damage(recovered, 18.0, hit_point, null, &"pickaxe", 40.0, Vector3.FORWARD)
		await _advance(.4)
	_check(strikes == [&"metal", &"metal", &"break"] and recovered.assembly == null,
		"three native pickaxe strikes loosen the donor fasteners and detach its component")
	_check(is_equal_approx(recovered.health, salvage_condition), "salvage strikes preserve the recovered component condition")
	var stored := await _wait_until(func() -> bool: return recovered.get_meta(&"stored", false), 90.0)
	_check(stored and _inventory() == donor_inventory, "Wako collect detached donor salvage and store it without duplication")
	if not stored:
		_dump_workers()
		_finish()
		return
	var inventory_before := _inventory()
	var resources_before: int = yard.loose_parts.size()
	_check(yard.plan_blueprint(Plans.rover()), "rover plan accepted using physical stock")
	var a: Node3D = yard.selected_assembly
	_check(not _built_selected() and a.parts.size() == 7, "selecting a blueprint creates seven unfinished placements")
	_check(_inventory() == inventory_before and yard.loose_parts.size() == resources_before, "plans grant or consume no components")
	var built := await _wait_until(_built_selected, 150.0)
	_check(built, "Wako fetch and assemble the powered wheeled platform")
	if not built:
		_dump_workers()
		_finish()
		return
	_check(saw_cargo, "real cargo was carried on a Wako head")
	_check(saw_heavy_crew, "heavy chassis reserved two helpers")
	_check(_inventory() == inventory_before and yard.loose_parts.size() == resources_before - 7,
		"one real resource consumed per installed placement")
	_check(a.connections.size() == 6, "installed body has its six physical connections")
	var energy_before: Variant = a.get("energy")
	yard.activate_selected()
	await _advance(3.0)
	var body: RigidBody3D = a.root_part()
	_check(is_instance_valid(body) and body.mass > 0 and is_finite(body.mass), "platform has finite physical mass")
	var drive_start := body.global_position
	a.set_control(0.4, 0.0, true)
	await _advance(5.0)
	_check(body.global_position.distance_to(drive_start) > 0.25, "unattended latched controls move the physical body")
	if energy_before is float:
		_check(float(a.get("energy")) < float(energy_before), "motor work consumes stored energy")
	a.set_control(0, 0, true)
	a.active = false
	await _advance(1.0)
	# Keep the workshop near the original work site after testing drive. This is a test relocation,
	# not a construction shortcut; all installed parts and joints preserve their relative positions.
	var relocation := Vector3(0, 1.1, -3) - body.global_position
	for part: Variant in a.parts.values():
		part.global_position += relocation
		part.linear_velocity = Vector3.ZERO
		part.angular_velocity = Vector3.ZERO
	_check(yard.plan_blueprint(Plans.upgrade(), true), "storage and articulated upgrade is planned")
	await _wait_until(func() -> bool: return saw_cargo and not yard.get("_reservations").is_empty(), 12.0)
	yard.work_paused = true
	var saved_inventory := _inventory()
	var snapshot: Dictionary = JSON.parse_string(JSON.stringify(yard.serialize()))
	yard.restore(snapshot)
	await _advance(1.0)
	_park_fauna()
	_check(_inventory() == saved_inventory, "save/load preserves installed parts and interrupted cargo without duplication")
	_check(yard.work_paused and yard.workers.size() == 3, "pause preference and helper crew survive saving")
	yard.work_paused = false
	var upgraded := await _wait_until(_built_selected, 150.0)
	_check(upgraded and yard.selected_assembly.parts.size() == 11, "workers recover interrupted jobs and finish the articulated storage upgrade")
	if not upgraded:
		_dump_workers()
		_finish()
		return
	a = yard.selected_assembly
	var wheel: RigidBody3D = a.parts["fl"]
	wheel.take_damage(55.0, wheel.global_position, null, &"test")
	_check(float(wheel.health) < float(wheel.definition.health), "damage changes actual component condition")
	var repaired := await _wait_until(func() -> bool: return wheel.health >= wheel.definition.health - 0.5, 90.0)
	_check(repaired and saw_repair, "Wako visibly inspect and repair a damaged wheel")
	var connection: Node3D = a.connections[0]
	connection.deformation = Vector3(0.12, 0.07, 0)
	var unbent := await _wait_until(func() -> bool: return connection.deformation.length() < .025, 90.0)
	_check(unbent, "Wako straighten a yielded connection")
	var enemy: Node3D = yard.enemies[1]
	var core: RigidBody3D
	for part: Variant in enemy.assembly.parts.values():
		if part.kind == "remote_core":
			core = part
	_check(core != null and not core.detach(), "live hostile remote prevents salvage")
	var crew_before: int = yard.workers.size()
	Core.damage(core, 1000.0, core.global_position, null, &"test")
	await _advance(0.1)
	_check(not enemy.alive and not enemy.is_in_group(&"contraption_threats"), "destroying the malicious core disables the enemy and removes its fear zone")
	_check(yard.workers.size() == crew_before + 1, "defeated guard frees a Wako into the helper crew")
	var safe_blueprint := true
	for descriptor: Dictionary in enemy.blueprint.parts:
		if descriptor.kind == "remote_core":
			safe_blueprint = false
	_check(safe_blueprint and Plans.validate(enemy.blueprint, Catalogue.all()).is_empty(), "discovered body blueprint is valid and excludes the malicious core")
	var no_remote_salvage := true
	for part: Variant in yard.loose_parts:
		if is_instance_valid(part) and part.kind == "remote_core":
			no_remote_salvage = false
	_check(no_remote_salvage, "remote core can never enter recovered inventory")
	# A second terminal hit must not repeat salvage, blueprint, or crew release.
	var inventory_after := _inventory()
	enemy.damage_core(1000.0)
	_check(_inventory() == inventory_after and yard.workers.size() == crew_before + 1, "death is idempotent and cannot duplicate resources or helper recruits")
	_finish()


func _finish() -> void:
	print("CONTRAPTION_INTEGRATION %s ticks=%d" % ["PASS" if failures == 0 else "FAIL (%d)" % failures, _tick])
	Shortcuts.graceful_quit(0 if failures == 0 else 1)

extends Node3D
## Actual paired pedal station and its exclusive live control lease. Saved worker
## strings are labels only; they cannot authorize a shot. The same gun can leave
## this socket, carrying its state into another physical role.
var mount: WeakRef
var gun: WeakRef
var controller: WeakRef
var commanded_target := Vector3.INF
var commanded_trigger := false

func configure(body: RigidBody3D) -> void:
	mount = weakref(body)

func link(item: Node3D) -> bool:
	if gun and is_instance_valid(gun.get_ref()) and gun.get_ref() != item: return false
	gun = weakref(item)
	return true

func unlink(item: Node3D) -> bool:
	if not gun or gun.get_ref() != item: return false
	gun = null
	controller = null
	commanded_target = Vector3.INF
	commanded_trigger = false
	return true

func claim(candidate: Node) -> bool:
	var occupied: Node = controller.get_ref() if controller else null
	if is_instance_valid(occupied) and occupied != candidate and _controller_valid(occupied): return false
	if not _controller_valid(candidate): return false
	controller = weakref(candidate)
	return true

func release(candidate: Node) -> void:
	if controller and controller.get_ref() == candidate: controller = null

func live_controller() -> Node:
	var candidate: Node = controller.get_ref() if controller else null
	return candidate if is_instance_valid(candidate) and _controller_valid(candidate) else null

func admits(item: Node, candidate: Node, support: RigidBody3D) -> bool:
	return is_instance_valid(support) and mount and mount.get_ref() == support and gun and gun.get_ref() == item and is_inside_tree() and support.is_ancestor_of(self) and live_controller() == candidate

func command(candidate: Node, target: Vector3, trigger: bool) -> bool:
	if live_controller() != candidate or not target.is_finite(): return false
	commanded_target = target
	commanded_trigger = trigger
	return true

func shot_admitted(item: Node, require_trigger := true) -> bool:
	if not gun or gun.get_ref() != item or (require_trigger and not commanded_trigger) or not commanded_target.is_finite(): return false
	var tip: Node3D = item.local_muzzle()
	if not is_instance_valid(tip) or not item.is_ancestor_of(tip): return false
	var support: Node = mount.get_ref() if mount else null
	if not is_instance_valid(support) or not support.gun_envelope_clear(item, item.global_transform): return false
	return (-tip.global_basis.z.normalized()).dot((commanded_target - tip.global_position).normalized()) >= .997

func _controller_valid(candidate: Node) -> bool:
	var body: RigidBody3D = mount.get_ref() as RigidBody3D if mount else null
	if not is_instance_valid(candidate) or not candidate.is_inside_tree() or not is_instance_valid(body) or not body.is_inside_tree(): return false
	var machine: Node = body.get("assembly")
	if not is_instance_valid(machine) or not bool(body.get("installed")) or bool(body.get("planned")) or body.get("carrier") != null or float(body.get("health")) <= 0.0 or bool(body.get("jammed")): return false
	if not machine.parts.has(str(body.get("part_id"))) or machine.parts[str(body.get("part_id"))] != body or not machine.has_power(body): return false
	if candidate.is_in_group(&"wako_helpers"):
		return candidate.get("station") == body and candidate.get("work_target") == body and not candidate.paused and candidate.fear_time <= 0.0 and candidate.supported_by(machine) and candidate.can_reach_work() and candidate.foot_contact_ready()
	if candidate == Core.player():
		# Player control is a lease at this real gun pedal, separate from motion helms.
		return bool(candidate.get("active")) and bool(candidate.get("on_ground")) and candidate.global_position.distance_to(global_position) <= 1.7
	return candidate == machine.get("mind_host") and candidate.has_method("allows_weapon_control") and candidate.allows_weapon_control(body)

## Autonomous gun roles share the helper's existing live hostile-brain policy.
static func live_hostile_core(enemy: Node) -> Node3D:
	if not is_instance_valid(enemy) or enemy.is_queued_for_deletion() or not bool(enemy.get("alive")): return null
	var core: Node3D = enemy.get("_core")
	var assembly: Node3D = enemy.get("assembly")
	var mind: Node = enemy.get("mind_host")
	if not is_instance_valid(core) or not core.is_inside_tree() or not is_instance_valid(assembly) or not assembly.active: return null
	if not core.installed or core.health<=0.0 or not is_instance_valid(mind) or not mind.hostile: return null
	if not is_instance_valid(mind.brain) or not mind.brain.enabled: return null
	return core

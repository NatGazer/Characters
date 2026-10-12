extends RefCounted
## Runtime links, deliberately absent from saved gun state. A binding names actual
## nodes: the carried item, its physical carrier, muzzle and linked control point.
var role := ""
var weapon: WeakRef
var carrier: WeakRef
var actor: WeakRef
var muzzle: WeakRef
var control: WeakRef
var excludes: Array[RID] = []

func configure(item: Node3D, body: RigidBody3D, shooter: Node, muzzle_node: Node3D, point: Node3D, context: String, excluded: Array[RID]) -> void:
	weapon = weakref(item)
	carrier = weakref(body)
	actor = weakref(shooter)
	muzzle = weakref(muzzle_node)
	control = weakref(point) if point else null
	role = context
	excludes.clear()
	if context == "wako": excludes.append_array(excluded)
	if shooter.has_method("query_exclusions"):
		for owned: RID in shooter.query_exclusions():
			if not excludes.has(owned): excludes.append(owned)
	if not excludes.has(body.get_rid()): excludes.append(body.get_rid())
	if shooter is CollisionObject3D and not excludes.has(shooter.get_rid()): excludes.append(shooter.get_rid())

func body() -> RigidBody3D:
	return carrier.get_ref() as RigidBody3D if carrier else null

func shooter() -> Node:
	return actor.get_ref() as Node if actor else null

func bore() -> Node3D:
	var item: Node = weapon.get_ref() if weapon else null
	if is_instance_valid(item):
		var actual: Node3D = item.local_muzzle()
		if is_instance_valid(actual) and item.is_ancestor_of(actual): return actual
	return null

func valid() -> bool:
	var item: Node = weapon.get_ref() if weapon else null
	var support := body()
	var shot_actor := shooter()
	var tip := bore()
	if not is_instance_valid(item) or not item.is_inside_tree() or not is_instance_valid(support) or not support.is_inside_tree() or not is_instance_valid(shot_actor) or not is_instance_valid(tip) or not tip.is_inside_tree(): return false
	if role == "mount":
		var point: Node = control.get_ref() if control else null
		return is_instance_valid(point) and point.has_method("admits") and point.admits(item, shot_actor, support)
	if role == "wako":
		# A live evaluated free-toe fixture is required; head cargo is never a gun grip.
		return shot_actor.is_in_group(&"wako_helpers") and shot_actor.get("equipped_gun") == item and shot_actor.get("gun_anchor") == item.get_parent() and shot_actor.has_method("portable_gun_control_ready") and shot_actor.portable_gun_control_ready(item)
	return false

func shot_valid(require_trigger := true) -> bool:
	if not valid(): return false
	if role == "mount":
		var point: Node = control.get_ref() if control else null
		return is_instance_valid(point) and point.shot_admitted(weapon.get_ref(), require_trigger)
	return true

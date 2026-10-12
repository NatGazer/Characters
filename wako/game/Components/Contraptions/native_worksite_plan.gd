extends RefCounted
## Read-only projector/depot selection. The existing Yard remains the sole
## resource owner; a mobile anchor never creates a replacement Yard or crew.
const Worksite := preload("res://Components/Contraptions/native_worksite.gd")
const Site := preload("res://Components/Contraptions/construction_site.gd")
const RANGE := 65.0

static func from_container(yard:Node3D,container:Variant) -> Dictionary:
	var result := Worksite.assess(yard,container)
	# Preserve the canonical owner for archive/stock inspection even when this
	# exact body's admission fails. The reason still forbids projection; no
	# guessed nearby replacement can provide permission or resources.
	result.yard = yard
	result.anchor = container
	result.legacy = false
	if result.has("reason"): return result
	var locator := Worksite.encode_anchor(yard,container)
	if locator.is_empty(): return {"reason":"The stopped container has no canonical workshop identity."}
	result.locator = locator
	return result

static func nearest(yards:Array,from:Vector3) -> Dictionary:
	if not from.is_finite(): return {"reason":"The projector has no finite world position."}
	var owner:Node3D
	var distance := RANGE
	# Preserve the ordinary current-yard selection, including its rejected
	# placements. A remote container does not silently replace a nearby yard.
	for yard:Variant in yards:
		if not is_instance_valid(yard) or not yard is Node3D or not yard.is_inside_tree() or yard.is_queued_for_deletion(): continue
		var separation:float = from.distance_to(yard.global_position)
		if separation < distance:
			distance = separation
			owner = yard
	if is_instance_valid(owner):
		return {"yard":owner,"transform":owner.global_transform,"floor":owner.global_position.y,"legacy":true}
	var nearest_container:RigidBody3D
	distance = RANGE
	for yard:Variant in yards:
		if not is_instance_valid(yard) or not yard is Node3D or not yard.is_inside_tree() or yard.is_queued_for_deletion(): continue
		for assembly:Variant in yard.assemblies:
			if not is_instance_valid(assembly): continue
			for part:Variant in assembly.parts.values():
				if not is_instance_valid(part) or not part is RigidBody3D or part.kind != "container" or not part.is_inside_tree() or part.is_queued_for_deletion(): continue
				var separation:float = from.distance_to(part.global_position)
				if separation < distance:
					distance = separation
					nearest_container = part
					owner = yard
	if not is_instance_valid(nearest_container): return {"reason":"Find a workshop or its stopped crewed container within 65 m."}
	# Assess this exact nearest body. Invalid stock/crew must not resolve to a
	# guessed replacement container with different ownership.
	return from_container(owner,nearest_container)

static func validate(selection:Dictionary,blueprint:Dictionary,world_root:Vector3) -> Dictionary:
	if selection.has("reason"): return {"reason":selection.reason}
	var yard:Node3D = selection.get("yard")
	if not is_instance_valid(yard) or not yard.is_inside_tree() or not world_root.is_finite():
		return {"reason":"The selected workshop or proposed world site is unavailable."}
	if selection.get("legacy",false):
		if world_root.distance_to(yard.global_position) > RANGE: return {"reason":"Aim within 65 m of the workshop."}
		return Site.validate_at(yard,blueprint,yard.to_local(world_root))
	var anchor:RigidBody3D = Worksite.resolve_anchor(yard,selection.get("locator"))
	if not is_instance_valid(anchor) or anchor != selection.get("anchor"):
		return {"reason":"The exact selected container has departed or disconnected."}
	var current := from_container(yard,anchor)
	if current.has("reason"): return {"reason":current.reason}
	if world_root.distance_to(anchor.global_position) > RANGE: return {"reason":"Aim within 65 m of the stopped container."}
	# Fresh native eligibility supplies today's ground, not an old foundation Y.
	var result := Site.validate_at(yard,blueprint,yard.to_local(world_root),current.transform)
	if not result.has("reason"):
		result.yard = yard
		result.locator = current.locator
		result.anchor = anchor
	return result

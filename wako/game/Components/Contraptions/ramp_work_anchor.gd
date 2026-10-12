extends RefCounted
## Ramp fasteners are serviced at the high mounting end's real upper face.
## Shared by work approach, finite reach estimates and actual timed foot contact.
const Catalogue := preload("res://Components/Contraptions/part_catalog.gd")

static func point(ramp: Node3D) -> Vector3:
	var half: Vector3 = ramp.definition.size * .5
	var local := Vector3(0,0,-half.z)
	var high := -INF
	for id: String in ["entry","exit"]:
		var socket: Dictionary = Catalogue.socket(ramp.definition,id)
		if socket.is_empty(): continue
		var at: Vector3 = socket.pos
		var height: float = ramp.to_global(at).y
		if height > high:
			high = height
			local = at
	local.z = clampf(local.z,-half.z+.08,half.z-.08)
	local.x = clampf(local.x,-half.x,half.x)
	local.y = half.y if ramp.global_basis.y.y >= 0 else -half.y
	return ramp.to_global(local)

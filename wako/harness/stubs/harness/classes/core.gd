class_name Core extends RefCounted
## Harness stub for RaulsMod's Core damage/world facade.
static var damaged: Array = []
static func damage(...args: Array) -> bool:
	damaged.append(args)
	return true
static func world_root() -> Node: return null
static func discover(_what: StringName) -> void: pass
static func player() -> Node3D: return Global.Player if Global else null

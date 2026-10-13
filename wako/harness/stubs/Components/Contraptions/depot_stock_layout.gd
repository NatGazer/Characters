extends Node3D
## Harness stub for the missing RaulsMod StockBounds module (used by the head-leap
## lab and the stock checks; never game code).
## bounds() returns the part's real catalogue AABB so solo-large and crew
## admission (face width, cargo boxes, return heights) see true geometry.
const Catalogue := preload("res://Components/Contraptions/part_catalog.gd")
const TOOL_ROW_Z = 0.0
static func _local_pose(...args: Array) -> Transform3D: return Transform3D.IDENTITY
static func aisle(...args: Array) -> Variant: return null
static func bounds(...args: Array) -> AABB:
	if not args.is_empty() and args[0] is Node and args[0].get("definition") is Dictionary:
		return Catalogue.bounds_of(args[0].definition)
	return AABB(Vector3(-0.15, -0.15, -0.15), Vector3(0.3, 0.3, 0.3))
static func place(...args: Array) -> Variant: return null
static func plan(...args: Array) -> Variant: return null
static func prepare(...args: Array) -> Variant: return null
static func restore_display(...args: Array) -> Variant: return null
static func rows(...args: Array) -> Variant: return null
static func serialized(...args: Array) -> Variant: return null

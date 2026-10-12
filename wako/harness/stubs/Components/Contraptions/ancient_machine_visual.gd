extends Node3D
## Hand-tuned from the auto-generated harness stub for missing RaulsMod module Components/Contraptions/ancient_machine_visual.gd (aliases: AncientVisual).
## Not game code: permissive placeholders so the real Wako scripts can load.
const BRONZE = Color(0.63, 0.51, 0.33)
static func beveled_box(size: Vector3, ..._rest: Array) -> ArrayMesh: return _box(size)
static func build_chassis(...args: Array) -> Variant: return null
static func build_cockpit(...args: Array) -> Variant: return null
static func build_gun_station(...args: Array) -> Variant: return null
static func build_leg(...args: Array) -> Variant: return null
static func build_mind(...args: Array) -> Variant: return null
static func build_power(...args: Array) -> Variant: return null
static func build_remote_core(...args: Array) -> Variant: return null
static func build_switch(...args: Array) -> Variant: return null
static func build_utility_station(...args: Array) -> Variant: return null
static func carved_box(size: Vector3, ..._rest: Array) -> ArrayMesh: return _box(size)
static func container_side_seats_mesh(...args: Array) -> Mesh: return BoxMesh.new()
static func dress(...args: Array) -> Variant: return null
static func gun_side_foot_pieces(...args: Array) -> Array: return []
static func shell_color(...args: Array) -> Color: return Color(0.8, 0.8, 0.8)
static func stone_family(...args: Array) -> bool: return false
static func utility_station_pieces(...args: Array) -> Array: return []
static func wall_mesh(...args: Array) -> Mesh: return BoxMesh.new()
static func wheel_hub_mesh(...args: Array) -> Mesh: return BoxMesh.new()
static func wheel_inlay_mesh(...args: Array) -> Mesh: return BoxMesh.new()
static func wheel_stone_hub_mesh(...args: Array) -> Mesh: return BoxMesh.new()
static func wheel_tire_mesh(...args: Array) -> Mesh: return BoxMesh.new()
static func wheel_tread_mesh(...args: Array) -> Mesh: return BoxMesh.new()
static func _box(size: Vector3) -> ArrayMesh:
	# Plain box with the requested extents; the real module adds bevels/engraving.
	var box := BoxMesh.new()
	box.size = size
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, box.get_mesh_arrays())
	return mesh

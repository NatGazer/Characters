extends RefCounted
## Reuses salvage props only; never creates a player HandTool/input manager for a helper.
const MALLET: Mesh = preload("res://Sites/_ConstrKit/props/meshes/sledgehammer_01_0.res")
const AncientMallet := preload("res://Components/Contraptions/ancient_mallet_visual.gd")
const PICKAXE: PackedScene = preload("res://Sites/Tutorial/models/pickaxe.glb")
static var _keepout_cache: Dictionary = {}

static func add_model(parent: Node3D, model: String, size: Vector3) -> void:
	var root := Node3D.new()
	root.name = "ExistingToolModel"
	parent.add_child(root)
	var mallet_mesh: MeshInstance3D
	if model == "sledgehammer":
		var mesh := MeshInstance3D.new()
		mesh.mesh = MALLET
		mallet_mesh = mesh
		root.add_child(mesh)
		var bounds := MALLET.get_aabb()
		var scale_factor := size.y / maxf(bounds.size.y, .001)
		mesh.scale = Vector3.ONE * scale_factor
		mesh.position = -bounds.get_center() * scale_factor
	else:
		var imported := PICKAXE.instantiate() as Node3D
		root.add_child(imported)
		# The reused pickaxe is authored with its cutter across Z. The catalogue
		# tool frame uses X across the cutter, Y along the handle, Z thickness.
		imported.rotation.y = PI * .5
		var bounds := AABB()
		var meshes: Array[MeshInstance3D] = []
		_collect_meshes(imported, meshes)
		for mesh: MeshInstance3D in meshes:
			var box := (root.global_transform.affine_inverse() * mesh.global_transform) * mesh.get_aabb()
			bounds = box if bounds.size == Vector3.ZERO else bounds.merge(box)
		var scale_factor := size.y / maxf(bounds.size.y, .001)
		imported.scale = Vector3.ONE * scale_factor
		imported.position = -bounds.get_center() * scale_factor
	var key := model + str(size)
	if not _keepout_cache.has(key):
		var meshes: Array[MeshInstance3D] = []
		_collect_meshes(root, meshes)
		var points := PackedVector3Array()
		for mesh: MeshInstance3D in meshes:
			var transform := parent.global_transform.affine_inverse() * mesh.global_transform
			for surface in mesh.mesh.get_surface_count():
				for vertex: Vector3 in mesh.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]: points.append(transform * vertex)
		var boxes: Array[AABB] = []
		# Short overlapping slices retain the cutter's actual width/thickness
		# without treating the thin handle as a full-width bounding box.
		var step := size.y / 8.0
		for band in 8:
			var low := -size.y * .5 + step * band
			var box := AABB(Vector3(-.02, low, -.02), Vector3(.04, step, .04))
			for point: Vector3 in points:
				if point.y >= low - step and point.y <= low + step * 2:
					box = box.expand(Vector3(point.x, clampf(point.y, low, low + step), point.z))
			boxes.append(box.grow(.005))
		_keepout_cache[key] = boxes
	parent.get_parent().set_meta(&"worker_tool_keepouts", _keepout_cache[key])
	if is_instance_valid(mallet_mesh):
		# Clearance remains the exact original imported mesh, before its visual
		# replacement. The carved model is wholly inside those same eight boxes.
		root.remove_child(mallet_mesh)
		mallet_mesh.free()
		AncientMallet.add_model(root, MALLET, size)

static func _collect_meshes(node: Node, output: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D: output.append(node)
	for child: Node in node.get_children(): _collect_meshes(child, output)

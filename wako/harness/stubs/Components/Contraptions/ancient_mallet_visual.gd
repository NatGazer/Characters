extends Node3D
## Harness stub (not game code): re-add the original imported mallet mesh at the
## same normalised scale the real carved model occupies, so whole-tool vertex guards
## in the contraption tests sample real geometry instead of an empty model.
static func add_model(root: Node3D, mesh: Mesh, size: Vector3, ..._rest: Array) -> void:
	var instance := MeshInstance3D.new()
	instance.name = "HarnessMallet"
	instance.mesh = mesh
	var bounds := mesh.get_aabb()
	var scale_factor := size.y / maxf(bounds.size.y, .001)
	instance.scale = Vector3.ONE * scale_factor
	instance.position = -bounds.get_center() * scale_factor
	root.add_child(instance)

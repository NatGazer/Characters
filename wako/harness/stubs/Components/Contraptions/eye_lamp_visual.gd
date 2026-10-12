extends Node3D
## Harness stub (not game code): the lamp part's visual is a plain lens sphere.
func build(part: Node3D, _brass: Variant = null, _dark: Variant = null, lamp_material: Variant = null) -> void:
	var lens := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = .08
	sphere.height = .16
	lens.mesh = sphere
	if lamp_material is Material: lens.material_override = lamp_material
	add_child(lens)
func set_power(...args: Array) -> void: pass
func set_lit(...args: Array) -> void: pass
func _refresh_light() -> void: pass
func inspect_status() -> String: return ""

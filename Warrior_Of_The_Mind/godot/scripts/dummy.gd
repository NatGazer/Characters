extends StaticBody3D
## Training dummy: wobbles and flashes gold when struck by the sword or a mind bolt.

var mesh: MeshInstance3D
var mat: StandardMaterial3D
var wobble := Vector3.ZERO
var wv := Vector3.ZERO

func _ready() -> void:
	var cs := CollisionShape3D.new(); var cap := CapsuleShape3D.new(); cap.radius = 0.3; cap.height = 1.8
	cs.shape = cap; cs.position = Vector3(0, 0.9, 0); add_child(cs)
	mesh = MeshInstance3D.new(); var cm := CapsuleMesh.new(); cm.radius = 0.3; cm.height = 1.8; mesh.mesh = cm
	mesh.position = Vector3(0, 0.9, 0)
	mat = StandardMaterial3D.new(); mat.albedo_color = Color(0.35, 0.28, 0.2); mat.roughness = 0.9
	mat.emission_enabled = true; mat.emission = Color(1, 0.6, 0.2); mat.emission_energy_multiplier = 0.0
	mesh.material_override = mat
	add_child(mesh)

func hit(dir: Vector3) -> void:
	wv += Vector3(dir.z, 0, -dir.x) * 4.0
	mat.emission_energy_multiplier = 6.0

func _physics_process(delta: float) -> void:
	# damped spring wobble
	wv += (-wobble * 60.0 - wv * 6.0) * delta
	wobble += wv * delta
	mesh.rotation = Vector3(wobble.x, 0, wobble.z) * 0.6
	mat.emission_energy_multiplier = move_toward(mat.emission_energy_multiplier, 0.0, 12.0 * delta)
	for b in get_tree().get_nodes_in_group("bolts"):
		if b.global_position.distance_to(global_position + Vector3.UP) < 0.8:
			hit((global_position - b.global_position).normalized()); b.queue_free()

extends Node3D
## Shared harness stage: lit ground, optional obstacle course, camera rig and
## a deterministic scenario clock. Scenario scripts extend this.
const WAKO := preload("res://LogicObjects/Wako/Wako.tscn")
var camera: Camera3D
var clock := 0.0
var frame := 0
var cam_target := Vector3.ZERO
var cam_offset := Vector3(3.2, 1.6, 3.2)
var cam_follow: Node3D
var cam_smooth := 4.0
var _caption: Label

func _ready() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.32, 0.47, 0.68)
	mat.sky_horizon_color = Color(0.72, 0.78, 0.84)
	mat.ground_horizon_color = Color(0.55, 0.52, 0.47)
	mat.ground_bottom_color = Color(0.25, 0.23, 0.2)
	sky.sky_material = mat
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.9
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	e.ssao_enabled = true
	e.glow_enabled = true
	e.glow_intensity = 0.25
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, 35, 0)
	sun.light_energy = 2.4
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 30.0
	add_child(sun)
	camera = Camera3D.new()
	camera.fov = 50.0
	camera.current = true
	add_child(camera)
	Global.Camera = camera
	var ui := CanvasLayer.new()
	add_child(ui)
	_caption = Label.new()
	_caption.position = Vector2(18, 12)
	_caption.add_theme_font_size_override("font_size", 20)
	_caption.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_caption.add_theme_constant_override("outline_size", 6)
	ui.add_child(_caption)
	build_world()
	setup()

func caption(text: String) -> void:
	if _caption: _caption.text = text

func build_world() -> void:
	add_box(Vector3(0, -0.5, 0), Vector3(60, 1, 60), Color(0.46, 0.5, 0.42))

func setup() -> void:
	pass

func add_box(pos: Vector3, size: Vector3, color: Color, rot := Vector3.ZERO, layer := 1) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = layer
	body.collision_mask = 0
	body.position = pos
	body.rotation_degrees = rot
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mesh.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.85
	mesh.material_override = m
	body.add_child(mesh)
	add_child(body)
	return body

func spawn_wako(pos: Vector3, id := "harness_wako", yaw := 0.0) -> RigidBody3D:
	var w: RigidBody3D = WAKO.instantiate()
	w.worker_id = id
	w.position = pos
	add_child(w)
	if yaw != 0.0:
		w._heading = yaw
		w._idle_heading = yaw
	return w

func _physics_process(delta: float) -> void:
	clock += delta
	scenario(delta)

func scenario(_delta: float) -> void:
	pass

func _process(delta: float) -> void:
	frame += 1
	if is_instance_valid(cam_follow):
		# Lead by velocity/smoothing so a steady run stays centred (no lag).
		var lead := Vector3.ZERO
		if cam_follow is RigidBody3D: lead = (cam_follow as RigidBody3D).linear_velocity.slide(Vector3.UP) / cam_smooth
		cam_target = cam_target.lerp(cam_follow.global_position + Vector3(0, 0.1, 0) + lead, 1.0 - exp(-cam_smooth * delta)) if frame > 2 else cam_follow.global_position
	camera.global_position = cam_target + cam_offset
	camera.look_at(cam_target, Vector3.UP)

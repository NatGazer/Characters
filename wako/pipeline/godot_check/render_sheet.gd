extends Node3D
# Usage (same scratch project, plus snow_skin.gdshader/.gdshaderinc in LogicObjects/Wako/):
#   python wako_deform_sheet.py -- Wako.blend OUT prefix --no-render --export-godot job.json
#   VK_ICD_FILENAMES=... xvfb-run godot --path <proj> --resolution 426x360 render_sheet.tscn -- job.json PANEL_DIR
#   python3 wako_deform_sheet.py godot-compose job.json PANEL_DIR OUT_DIR prefix "LABEL"
# Real-engine deformation check: imports the rebuilt Wako.blend, applies the game's snow
# skin shader exactly like wako_helper._apply_skin(), poses the Skeleton3D with the
# armature-space bone matrices exported by wako_deform_sheet.py (converted Blender->Godot:
# (x, y, z) -> (x, z, -y)) and captures each pose/view to PNG.
const SKIN := preload("res://LogicObjects/Wako/snow_skin.gdshader")
var job: Dictionary
var out_dir: String
var sk: Skeleton3D
var cam: Camera3D
var steps := []
var step := 0
var wait := 0
var C := Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	job = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	out_dir = args[1]
	DirAccess.make_dir_recursive_absolute(out_dir)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.45, 0.58, 0.78)
	sm.sky_horizon_color = Color(0.72, 0.76, 0.82)
	sm.ground_bottom_color = Color(0.25, 0.25, 0.27)
	sm.ground_horizon_color = Color(0.6, 0.62, 0.66)
	sky.sky_material = sm
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 12.0
	add_child(sun)
	sun.look_at_from_position(Vector3.ZERO, C * Vector3(0.8, -1.0, -1.3), Vector3.UP)
	# weak shadowless fill from below so close-ups of the hip junction underside read
	var under := DirectionalLight3D.new()
	under.light_energy = 0.35
	add_child(under)
	under.look_at_from_position(Vector3.ZERO, C * Vector3(0.2, 0.3, 1.0), Vector3.FORWARD)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(8, 8)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.32, 0.34, 0.37)
	gm.roughness = 0.95
	ground.material_override = gm
	ground.position.y = -0.0076
	add_child(ground)
	var model: Node3D = load("res://LogicObjects/Wako/Wako.blend").instantiate()
	add_child(model)
	sk = model.find_children("*", "Skeleton3D", true, false)[0]
	var ap: AnimationPlayer = model.find_children("*", "AnimationPlayer", true, false)[0]
	ap.stop()
	var mesh: MeshInstance3D = model.find_child("wakoMesh", true, false)
	var original := mesh.get_active_material(0) as StandardMaterial3D
	var mat := ShaderMaterial.new()
	mat.shader = SKIN
	var tex: Texture2D = original.albedo_texture
	if tex == null:
		# The ORIGINAL .blend stores an absolute Windows texture path that does not exist
		# here; use the same atlas so the before/after comparison matches the user's game.
		tex = load("res://LogicObjects/Wako/textures/Player.png")
		print("albedo texture missing in import; using res:// atlas fallback")
	mat.set_shader_parameter("albedo_texture", tex)
	mesh.set_surface_override_material(0, mat)
	cam = Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.far = 30.0
	add_child(cam)
	cam.current = true
	for pose in job["poses"]:
		for view in pose["views"]:
			steps.append([pose, view])

func _set_pose(pose: Dictionary) -> void:
	sk.reset_bone_poses()
	for i in sk.get_bone_count():
		var m: Array = pose["bones"][sk.get_bone_name(i)]
		# m: 4x4 row-major Blender armature-space pose matrix
		var bx := Vector3(m[0][0], m[1][0], m[2][0])
		var by := Vector3(m[0][1], m[1][1], m[2][1])
		var bz := Vector3(m[0][2], m[1][2], m[2][2])
		var t := Vector3(m[0][3], m[1][3], m[2][3])
		var g := Transform3D(Basis(C * bx, C * by, C * bz), C * t)
		sk.set_bone_global_pose(i, g)

func _process(_dt: float) -> void:
	if step >= steps.size():
		get_tree().quit()
		return
	var pose: Dictionary = steps[step][0]
	var view: Dictionary = steps[step][1]
	if wait == 0:
		_set_pose(pose)
		var loc: Array = view["location"]
		var fwd: Array = view["forward"]
		var p := C * Vector3(loc[0], loc[1], loc[2])
		var f := C * Vector3(fwd[0], fwd[1], fwd[2])
		cam.size = view["ortho_scale"]
		cam.look_at_from_position(p, p + f, Vector3.UP)
	wait += 1
	if wait >= 4:
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s/%s" % [out_dir, view["file"]])
		wait = 0
		step += 1

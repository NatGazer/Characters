class_name WaterSplash extends Node3D
## One-shot splash: a spray of droplets, a burst of white mist and a splash sound. Frees itself.
##   WaterSplash.spawn(any_node_in_tree, world_pos, strength)   # strength ~0.3 (pebble) .. 3 (car)

const SMALL := preload("res://Components/Ocean/audio/splash_small.wav")
const BIG := preload("res://Components/Ocean/audio/splash_big.wav")

static var _drop_mat: StandardMaterial3D
static var _mist_mat: StandardMaterial3D
static var _drop_mesh: QuadMesh
static var _mist_mesh: QuadMesh

static func spawn(context: Node, pos: Vector3, strength: float = 1.0) -> WaterSplash:
	if context == null or not context.is_inside_tree() or not pos.is_finite() or not is_finite(strength):
		return null
	WaterInteraction.splash(pos, strength, maxf(0.15, strength * 0.4))
	var s := WaterSplash.new()
	s.strength = strength
	s.top_level = true
	s.position = pos
	context.get_tree().current_scene.add_child(s) if context.get_tree().current_scene else context.get_tree().root.add_child(s)
	return s

var strength := 1.0

static func _materials() -> void:
	if _drop_mat:
		return
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 64
	tex.height = 64
	_drop_mat = StandardMaterial3D.new()
	_drop_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_drop_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_drop_mat.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT_WRAP
	_drop_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	_drop_mat.billboard_keep_scale = true
	_drop_mat.vertex_color_use_as_albedo = true
	_drop_mat.albedo_texture = tex
	_drop_mat.albedo_color = Color(0.85, 0.9, 0.95, 0.9)
	_drop_mat.roughness = 0.3
	_mist_mat = _drop_mat.duplicate()
	_mist_mat.albedo_color = Color(0.8, 0.85, 0.9, 0.22)
	_mist_mat.roughness = 1.0
	_mist_mat.proximity_fade_enabled = true
	_mist_mat.proximity_fade_distance = 0.6
	_drop_mesh = QuadMesh.new()
	_drop_mesh.size = Vector2(0.09, 0.09)
	_mist_mesh = QuadMesh.new()
	_mist_mesh.size = Vector2(1.0, 1.0)

func _ready() -> void:
	_materials()
	var k := clampf(strength, 0.2, 4.0)
	var drops := GPUParticles3D.new()
	drops.one_shot = true
	drops.explosiveness = 0.92
	drops.amount = int(40 + 110 * k)
	drops.lifetime = 1.4
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3.UP
	pm.emission_ring_radius = 0.25 * sqrt(k)
	pm.emission_ring_inner_radius = 0.05
	pm.emission_ring_height = 0.05
	pm.direction = Vector3.UP
	pm.spread = 28.0
	pm.initial_velocity_min = 2.0 * sqrt(k)
	pm.initial_velocity_max = 6.5 * sqrt(k)
	pm.gravity = Vector3(0, -9.8, 0)
	pm.damping_min = 0.2
	pm.damping_max = 0.8
	pm.scale_min = 0.6
	pm.scale_max = 1.6 * sqrt(k)
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 0.95))
	ramp.set_color(1, Color(1, 1, 1, 0.0))
	var rt := GradientTexture1D.new()
	rt.gradient = ramp
	pm.color_ramp = rt
	drops.process_material = pm
	drops.draw_pass_1 = _drop_mesh
	drops.material_override = _drop_mat
	add_child(drops)
	drops.emitting = true

	var mist := GPUParticles3D.new()
	mist.one_shot = true
	mist.explosiveness = 0.8
	mist.amount = int(8 + 14 * k)
	mist.lifetime = 1.8
	var mm := ParticleProcessMaterial.new()
	mm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mm.emission_sphere_radius = 0.3 * sqrt(k)
	mm.direction = Vector3.UP
	mm.spread = 60.0
	mm.initial_velocity_min = 0.8
	mm.initial_velocity_max = 2.5 * sqrt(k)
	mm.gravity = Vector3(0, -1.5, 0)
	mm.damping_min = 1.5
	mm.damping_max = 3.0
	mm.scale_min = 0.8 * sqrt(k)
	mm.scale_max = 2.2 * sqrt(k)
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.4))
	sc.add_point(Vector2(1, 1.0))
	var sct := CurveTexture.new()
	sct.curve = sc
	mm.scale_curve = sct
	var mr := Gradient.new()
	mr.set_color(0, Color(1, 1, 1, 0.7))
	mr.set_color(1, Color(1, 1, 1, 0.0))
	var mrt := GradientTexture1D.new()
	mrt.gradient = mr
	mm.color_ramp = mrt
	mist.process_material = mm
	mist.draw_pass_1 = _mist_mesh
	mist.material_override = _mist_mat
	add_child(mist)
	mist.emitting = true

	var snd := preload("res://Components/WorldAcoustics/world_acoustics.gd").create_player()
	snd.stream = BIG if k > 1.2 else SMALL
	snd.volume_db = linear_to_db(clampf(0.35 + k * 0.35, 0.2, 1.4))
	snd.pitch_scale = randf_range(0.9, 1.1) / clampf(sqrt(k) * 0.8 + 0.2, 0.7, 1.4)
	snd.unit_size = 6.0 + k * 4.0
	add_child(snd)
	snd.play()
	get_tree().create_timer(2.2).timeout.connect(queue_free)

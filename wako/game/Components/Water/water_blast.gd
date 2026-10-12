class_name WaterBlast extends Node3D
## An explosion at or under a water surface (lake, river, sea): a white water column thrown straight up, a crown
## of heavy drops, a low ring of spray racing out over the surface and a deep splash, instead of a dry fireball
## over the water. Blast.explode() calls `WaterBlast.spawn_for()` for every blast; it does nothing on dry land.
## Visual and sound only (the waves come from WATER2 / the splash's ripples). Frees itself.

const BIG := preload("res://Components/Ocean/audio/splash_big.wav")
const LIFE := 6.5

## Blasts further above the surface than this (m) are dry.
const ABOVE := 1.2
const DEFAULT_BOOMS: Array[AudioStream] = [
	preload("res://Components/Explosion/audio/barrel_explosion_1.wav"),
	preload("res://Components/Explosion/audio/barrel_explosion_2.wav"),
	preload("res://Components/Explosion/audio/barrel_explosion_3.wav"),
]

var k := 1.0          # size (1 = a grenade at the surface)
var depth := 0.0      # how far under the surface the charge went off (m)
var blast_sounds: Array[AudioStream] = []
static var _column_mat: StandardMaterial3D


## Pure classification, shared with weapon-specific effects. A buried charge is dry even if a lake owns its XZ.
static func depth_at(pos: Vector3) -> float:
	var info := _surface_info(pos)
	return float(info.depth) if not info.is_empty() else -INF


## Spawns the water blast when `pos` is in water or just above it. Returns the charge depth below the surface
## (m, negative = above it) or -INF when the blast is not on water.
static func spawn_for(pos: Vector3, radius: float, impulse: float, visual: Variant = null) -> float:
	if not pos.is_finite() or not is_finite(radius) or not is_finite(impulse) or radius <= 0.0:
		return -INF
	var info := _surface_info(pos)
	if info.is_empty():
		return -INF
	var level: float = info.level
	var d: float = info.depth
	if d < -ABOVE:
		return d
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return d
	var root: Node = Core.world_root() if Core.world_root() else tree.current_scene
	if root == null:
		return d
	var b := WaterBlast.new()
	b.name = "WaterBlast"
	# A grenade (r 12, 1600 N*s) is 1; a rocket a little more, a nuke caps at 3.2
	b.k = clampf(sqrt(maxf(impulse, 1.0)) / 40.0 * 0.5 + radius / 24.0, 0.5, 3.2)
	b.depth = maxf(d, 0.0)
	if visual != null:
		var sounds: Array = visual.get("sounds", DEFAULT_BOOMS) if visual is Dictionary else DEFAULT_BOOMS
		b.blast_sounds.assign(sounds)
	b.top_level = true
	b.position = Vector3(pos.x, level, pos.z)
	root.add_child(b)
	WaterSplash.spawn(root, Vector3(pos.x, level, pos.z), clampf(b.k * 2.0, 1.0, 4.0))
	return d


static func _surface_info(pos: Vector3) -> Dictionary:
	if not pos.is_finite():
		return {}
	var s := WaterInteraction.surface_at_xz(pos)
	if s.is_empty():
		return {}
	var level := Water.height_at(Vector3(pos.x, (s.position as Vector3).y, pos.z))
	if not is_finite(level):
		level = (s.position as Vector3).y
	var tree := Engine.get_main_loop() as SceneTree
	# A surface over the same XZ does not make a buried charge underwater.
	# Keep ground blasts and their fireball when the charge is below the bed.
	var bed := -INF
	var body: Object = s.surface
	if body is Ocean:
		bed = (body as Ocean).seabed_at(pos)
	elif body is WaterBody:
		var info: Dictionary = (body as WaterBody).interaction_info_at(Vector2(pos.x, pos.z))
		if not info.is_empty():
			bed = float(info.height) - float(info.depth)
	var terrain := tree.current_scene.get_node_or_null(^"Terrain3D") if tree and tree.current_scene else null
	if terrain != null:
		var ground_height: float = terrain.data.get_height(pos)
		if is_finite(ground_height):
			bed = maxf(bed, ground_height)
	if is_finite(bed) and (pos.y < bed - 0.05 or bed >= level):
		return {}
	return {level = level, depth = level - pos.y}


func _ready() -> void:
	WaterSplash._materials()
	if _column_mat == null:
		_column_mat = WaterSplash._mist_mat.duplicate()
		_column_mat.albedo_color = Color(0.95, 0.97, 1.0, 0.85)
	# Deep charges throw a lower, fatter dome; a surface shot throws a tall column
	var f := maxf(exp(-depth / maxf(5.0, 8.0 * k)), 0.3)
	var sk := sqrt(k)
	WeaponSettings.ensure()
	var q := WeaponSettings.explosion_quality()
	var n: float = [0.5, 0.75, 1.0, 1.25][clampi(q, 0, 3)]

	# Column: big soft white puffs shot straight up, slowing and collapsing back
	var col := _particles(int(70 * k * n), 3.6, 0.95, _column_mat, WaterSplash._mist_mesh)
	var pm := col.process_material as ParticleProcessMaterial
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.6 * sk * (1.0 + (1.0 - f))
	pm.direction = Vector3.UP
	pm.spread = lerpf(22.0, 7.0, f)
	pm.initial_velocity_min = 6.0 * sk * lerpf(0.6, 1.0, f)
	pm.initial_velocity_max = 17.0 * sk * lerpf(0.5, 1.0, f)
	pm.gravity = Vector3(0, -9.8, 0)
	pm.damping_min = 0.3
	pm.damping_max = 1.2
	pm.scale_min = 1.6 * k
	pm.scale_max = 3.6 * k
	pm.scale_curve = _curve([Vector2(0, 0.35), Vector2(0.25, 0.9), Vector2(1, 1.6)])
	pm.color_ramp = _ramp(Color(0.96, 0.97, 1.0, 0.85), Color(0.9, 0.92, 0.95, 0.0), 0.55)

	# Crown: heavy drops thrown up and out, falling back as rain around the column
	var crown := _particles(int(380 * k * n), 2.8, 0.97, WaterSplash._drop_mat, _big_drop())
	pm = crown.process_material as ParticleProcessMaterial
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3.UP
	pm.emission_ring_radius = 0.8 * sk
	pm.emission_ring_inner_radius = 0.2
	pm.emission_ring_height = 0.2
	pm.direction = Vector3.UP
	pm.spread = 34.0
	pm.initial_velocity_min = 5.0 * sk * f + 2.0
	pm.initial_velocity_max = 16.0 * sk * f + 3.0
	pm.gravity = Vector3(0, -9.8, 0)
	pm.damping_min = 0.1
	pm.damping_max = 0.5
	pm.scale_min = 0.7
	pm.scale_max = 2.2
	pm.color_ramp = _ramp(Color(1, 1, 1, 0.95), Color(1, 1, 1, 0.0), 0.8)

	# Base surge: a low ring of spray racing out over the water
	var surge := _particles(int(36 * k * n), 4.5, 1.0, WaterSplash._mist_mat, WaterSplash._mist_mesh)
	pm = surge.process_material as ParticleProcessMaterial
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3.UP
	pm.emission_ring_radius = 1.2 * sk
	pm.emission_ring_inner_radius = 0.8 * sk
	pm.emission_ring_height = 0.1
	pm.direction = Vector3(1, 0.12, 0)
	pm.spread = 180.0
	pm.flatness = 0.9
	pm.initial_velocity_min = 5.0 * sk
	pm.initial_velocity_max = 11.0 * sk
	pm.gravity = Vector3(0, -0.6, 0)
	pm.damping_min = 1.6
	pm.damping_max = 2.6
	pm.scale_min = 2.0 * k
	pm.scale_max = 4.5 * k
	pm.scale_curve = _curve([Vector2(0, 0.4), Vector2(1, 1.8)])
	pm.color_ramp = _ramp(Color(0.95, 0.96, 0.98, 0.55), Color(0.9, 0.92, 0.95, 0.0), 0.35)
	# The surge's emission points must turn with the radial direction: each puff flies out from its ring point
	pm.set_param_min(ParticleProcessMaterial.PARAM_RADIAL_ACCEL, 4.0 * sk)
	pm.set_param_max(ParticleProcessMaterial.PARAM_RADIAL_ACCEL, 8.0 * sk)

	# Keep the weapon's own bang when replacing its dry explosion. Deep charges are lower and muffled.
	if not blast_sounds.is_empty():
		var boom := preload("res://Components/WorldAcoustics/world_acoustics.gd").create_player()
		boom.stream = blast_sounds.pick_random()
		boom.unit_size = 22.0 * sk
		boom.pitch_scale = clampf(1.0 - depth * 0.035, 0.65, 1.0)
		boom.volume_db = -minf(depth * 1.5, 12.0)
		add_child(boom)
		boom.play()

	# A dull underwater thump under the explosion's own bang, then the water crashing back
	var snd := preload("res://Components/WorldAcoustics/world_acoustics.gd").create_player()
	snd.stream = BIG
	snd.volume_db = linear_to_db(clampf(0.7 + 0.3 * k, 0.7, 1.4))
	snd.pitch_scale = clampf(0.85 / sk, 0.55, 0.95)
	snd.unit_size = 14.0 + 8.0 * k
	add_child(snd)
	snd.play()
	var late := preload("res://Components/WorldAcoustics/world_acoustics.gd").create_player()
	late.stream = BIG
	late.volume_db = linear_to_db(clampf(0.4 + 0.25 * k, 0.4, 1.1))
	late.pitch_scale = clampf(1.0 / sk, 0.6, 1.05)
	late.unit_size = 10.0 + 6.0 * k
	add_child(late)
	get_tree().create_timer(clampf(1.2 * sk, 0.8, 2.4)).timeout.connect(func() -> void:
		if is_instance_valid(late) and late.is_inside_tree():
			late.play())
	get_tree().create_timer(LIFE).timeout.connect(queue_free)


func _particles(amount: int, life: float, explosive: float, mat: Material, mesh: Mesh) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = explosive
	p.amount = maxi(amount, 4)
	p.lifetime = life
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-40, -4, -40), Vector3(80, 70, 80))
	p.process_material = ParticleProcessMaterial.new()
	p.draw_pass_1 = mesh
	p.material_override = mat
	add_child(p)
	p.emitting = true
	return p


static var _big_drop_mesh: QuadMesh


static func _big_drop() -> QuadMesh:
	if _big_drop_mesh == null:
		_big_drop_mesh = QuadMesh.new()
		_big_drop_mesh.size = Vector2(0.16, 0.16)
	return _big_drop_mesh


static func _curve(points: Array) -> CurveTexture:
	var c := Curve.new()
	c.max_value = 3.0
	for pt in points:
		c.add_point(pt)
	var t := CurveTexture.new()
	t.curve = c
	return t


static func _ramp(a: Color, b: Color, hold: float) -> GradientTexture1D:
	var g := Gradient.new()
	g.set_color(0, a)
	g.set_color(1, b)
	g.add_point(hold, a)
	var t := GradientTexture1D.new()
	t.gradient = g
	return t

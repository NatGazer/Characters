class_name EnvBuilder
extends RefCounted
## Builds the dramatic showcase environment in code (so it is easy to tweak and needs no assets):
## dusk sky, AgX tone mapping, bloom tuned for the glowing gold, SSAO / SSIL, volumetric fog,
## a stone arena and three-point lighting (warm key, cool rim, golden kicker).

static func is_software_renderer() -> bool:
	var a := RenderingServer.get_video_adapter_name().to_lower()
	return "llvmpipe" in a or "lavapipe" in a or "swiftshader" in a or "software" in a

static func build(parent: Node3D, quality_high := true) -> Dictionary:
	var hq := quality_high and not is_software_renderer()
	var we := WorldEnvironment.new()
	var env := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.10, 0.12, 0.19)
	sm.sky_horizon_color = Color(0.55, 0.47, 0.43)
	sm.ground_bottom_color = Color(0.02, 0.02, 0.025)
	sm.ground_horizon_color = Color(0.35, 0.26, 0.22)
	sm.sun_angle_max = 20.0
	sky.sky_material = sm
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.5
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.45
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_strength = 1.0
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 1.1
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	env.set_glow_level(1, 1.0); env.set_glow_level(2, 0.8); env.set_glow_level(3, 0.6); env.set_glow_level(5, 0.3)
	env.ssao_enabled = hq
	env.ssao_radius = 0.6; env.ssao_intensity = 1.6
	env.ssil_enabled = hq
	env.sdfgi_enabled = false
	env.fog_enabled = true
	env.fog_light_color = Color(0.32, 0.26, 0.24)
	env.fog_sky_affect = 0.25
	env.fog_density = 0.006
	env.volumetric_fog_enabled = hq
	env.volumetric_fog_density = 0.018
	env.volumetric_fog_albedo = Color(0.9, 0.8, 0.7)
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.06
	env.adjustment_saturation = 1.05
	we.environment = env
	parent.add_child(we)

	# key: warm, high, from the front-left, soft shadows
	var key := DirectionalLight3D.new()
	key.name = "Key"
	key.light_color = Color(1.0, 0.86, 0.72)
	key.light_energy = 4.2
	key.shadow_enabled = true
	key.shadow_blur = 1.5
	key.directional_shadow_max_distance = 25.0
	key.light_volumetric_fog_energy = 1.2
	key.rotation_degrees = Vector3(-38, -35, 0)
	key.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY   # no sun disc in the sky
	parent.add_child(key)
	# rim: cool, from behind-right
	var rim := SpotLight3D.new()
	rim.name = "Rim"
	rim.light_color = Color(0.55, 0.70, 1.0)
	rim.light_energy = 16.0
	rim.spot_range = 14.0; rim.spot_angle = 30.0
	rim.position = Vector3(3.2, 3.6, -4.2)
	parent.add_child(rim)
	rim.look_at_from_position(rim.position, Vector3(0, 1.3, 0))
	rim.shadow_enabled = hq
	# soft cool fill from the camera side (no shadows) so faces never go black
	var fill := DirectionalLight3D.new()
	fill.name = "Fill"
	fill.light_color = Color(0.75, 0.82, 1.0)
	fill.light_energy = 1.6
	fill.rotation_degrees = Vector3(-12, 160, 0)
	parent.add_child(fill)
	# golden kicker from the left-behind
	var kick := SpotLight3D.new()
	kick.name = "Kicker"
	kick.light_color = Color(1.0, 0.62, 0.30)
	kick.light_energy = 9.0
	kick.spot_range = 12.0; kick.spot_angle = 34.0
	kick.position = Vector3(-3.8, 2.4, -2.6)
	parent.add_child(kick)
	kick.look_at_from_position(kick.position, Vector3(0, 1.2, 0))
	# floor: dark stone arena with an engraved ring
	var floor := MeshInstance3D.new()
	floor.name = "Arena"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 7.0; cyl.bottom_radius = 7.2; cyl.height = 0.2; cyl.radial_segments = 96
	floor.mesh = cyl
	floor.position = Vector3(0, -0.1, 0)
	floor.material_override = stone_material()
	parent.add_child(floor)
	var col := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new(); box.size = Vector3(60, 0.2, 60)
	cs.shape = box; col.add_child(cs); col.position = Vector3(0, -0.1, 0)
	parent.add_child(col)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(200, 200)
	ground.mesh = pm; ground.position = Vector3(0, -0.21, 0)
	var gm := StandardMaterial3D.new(); gm.albedo_color = Color(0.05, 0.045, 0.04); gm.roughness = 0.95
	ground.material_override = gm
	parent.add_child(ground)
	return {"env": env, "key": key, "rim": rim, "kicker": kick, "hq": hq}

static func stone_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_CELLULAR
	n.frequency = 0.02
	n.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
	var t := NoiseTexture2D.new(); t.noise = n; t.width = 1024; t.height = 1024; t.seamless = true
	var cr := Gradient.new()
	cr.set_color(0, Color(0.05, 0.045, 0.045)); cr.set_color(1, Color(0.22, 0.20, 0.19))
	t.color_ramp = cr
	m.albedo_texture = t
	var tn := NoiseTexture2D.new(); tn.noise = n; tn.width = 1024; tn.height = 1024; tn.seamless = true
	tn.as_normal_map = true; tn.bump_strength = 6.0
	m.normal_enabled = true; m.normal_texture = tn
	m.roughness = 0.82
	m.uv1_scale = Vector3(6, 6, 6)
	m.uv1_triplanar = true
	return m

class_name WarriorVFX
extends RefCounted
## Procedural effects for the Warrior of the Mind (no texture assets needed):
## psychic bolt (projectile), blast shockwave, sword summon sparks, hit flash.

const GOLD := Color(1.0, 0.66, 0.24)

static func _glow_material(c: Color, energy := 6.0, alpha := 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(c.r, c.g, c.b, alpha)
	m.emission_enabled = true; m.emission = c; m.emission_energy_multiplier = energy
	if alpha < 1.0: m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

static func _particles(amount: int, lifetime: float, c: Color, size: float, spread: float, vel: Vector2, gravity := Vector3.ZERO) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount; p.lifetime = lifetime
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 0, 1); pm.spread = spread
	pm.initial_velocity_min = vel.x; pm.initial_velocity_max = vel.y
	pm.gravity = gravity
	pm.scale_min = 0.5; pm.scale_max = 1.2
	var cr := Gradient.new(); cr.set_color(0, Color(c.r, c.g, c.b, 1)); cr.set_color(1, Color(c.r, c.g * 0.6, c.b * 0.3, 0))
	var gt := GradientTexture1D.new(); gt.gradient = cr
	pm.color_ramp = gt
	var sc := Curve.new(); sc.add_point(Vector2(0, 1)); sc.add_point(Vector2(1, 0))
	var st := CurveTexture.new(); st.curve = sc
	pm.scale_curve = st
	p.process_material = pm
	var q := QuadMesh.new(); q.size = Vector2(size, size)
	var qm := _glow_material(Color(1, 1, 1), 4.0, 0.999)
	qm.vertex_color_use_as_albedo = true
	var g := Gradient.new(); g.set_color(0, Color(1, 1, 1, 1)); g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.25, Color(1, 1, 1, 0.8))
	var gt2 := GradientTexture2D.new(); gt2.gradient = g; gt2.fill = GradientTexture2D.FILL_RADIAL
	gt2.fill_from = Vector2(0.5, 0.5); gt2.fill_to = Vector2(1.0, 0.5); gt2.width = 64; gt2.height = 64
	qm.albedo_texture = gt2
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	q.material = qm
	p.draw_pass_1 = q
	return p

## A glowing golden bolt flying from `from` along `dir`; frees itself after `range_m`.
static func spawn_bolt(parent: Node, from: Vector3, dir: Vector3, speed := 26.0, range_m := 40.0) -> Node3D:
	var b := Node3D.new()
	b.name = "MindBolt"
	b.add_to_group("bolts")
	parent.add_child(b)
	b.global_position = from
	var core := MeshInstance3D.new()
	var sm := SphereMesh.new(); sm.radius = 0.07; sm.height = 0.14
	core.mesh = sm; core.material_override = _glow_material(GOLD, 14.0)
	b.add_child(core)
	var halo := MeshInstance3D.new()
	var hm := SphereMesh.new(); hm.radius = 0.2; hm.height = 0.4
	halo.mesh = hm; halo.material_override = _glow_material(GOLD, 3.0, 0.25)
	b.add_child(halo)
	var l := OmniLight3D.new(); l.light_color = GOLD; l.light_energy = 3.5; l.omni_range = 3.5
	b.add_child(l)
	var trail := _particles(160, 0.45, GOLD, 0.09, 12.0, Vector2(0.2, 1.0))
	trail.local_coords = false
	b.add_child(trail)
	var d := dir.normalized()
	var tw := b.create_tween()
	tw.tween_property(b, "global_position", from + d * range_m, range_m / speed)
	tw.tween_callback(b.queue_free)
	# muzzle flash
	flash(parent, from, 1.2, 0.12)
	return b

static func flash(parent: Node, at: Vector3, energy := 2.0, time := 0.15, c := GOLD) -> void:
	var l := OmniLight3D.new(); l.light_color = c; l.light_energy = energy; l.omni_range = 4.0
	parent.add_child(l); l.global_position = at
	var tw := l.create_tween()
	tw.tween_property(l, "light_energy", 0.0, time)
	tw.tween_callback(l.queue_free)

## Expanding shock ring + dust for the two-handed blast.
static func spawn_blast(parent: Node, at: Vector3, forward: Vector3) -> void:
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new(); tm.inner_radius = 0.30; tm.outer_radius = 0.36; tm.rings = 48
	ring.mesh = tm
	var m := _glow_material(GOLD, 8.0, 0.9)
	ring.material_override = m
	parent.add_child(ring)
	ring.global_position = at
	ring.look_at(at + forward, Vector3.UP)
	ring.rotate_object_local(Vector3.RIGHT, PI / 2)
	var tw := ring.create_tween().set_parallel(true)
	tw.tween_property(ring, "scale", Vector3.ONE * 5.0, 0.8).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(ring, "global_position", at + forward.normalized() * 2.5, 0.8).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(m, "albedo_color:a", 0.0, 0.8).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(ring.queue_free)
	flash(parent, at, 4.0, 0.3)
	var sparks := _particles(260, 0.8, GOLD, 0.06, 40.0, Vector2(3.0, 9.0), Vector3(0, -4, 0))
	sparks.one_shot = true; sparks.explosiveness = 0.95
	parent.add_child(sparks)
	sparks.global_position = at
	sparks.look_at(at + forward, Vector3.UP)
	sparks.rotate_object_local(Vector3.UP, PI)
	sparks.emitting = true
	sparks.get_tree().create_timer(1.5).timeout.connect(sparks.queue_free)

## Golden sparks converging into the hand when the sword is summoned.
static func spawn_summon(parent: Node3D) -> void:
	var p := _particles(220, 0.6, GOLD, 0.05, 180.0, Vector2(-2.5, -1.2))
	p.one_shot = true; p.explosiveness = 0.6
	var pm := p.process_material as ParticleProcessMaterial
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.9
	parent.add_child(p)
	p.emitting = true
	p.get_tree().create_timer(1.2).timeout.connect(p.queue_free)
	var l := OmniLight3D.new(); l.light_color = GOLD; l.light_energy = 0.0; l.omni_range = 3.0
	parent.add_child(l)
	var tw := l.create_tween()
	tw.tween_property(l, "light_energy", 5.0, 0.25)
	tw.tween_property(l, "light_energy", 0.0, 0.5)
	tw.tween_callback(l.queue_free)

## Short golden trail following a node (sword tip) for `time` seconds.
static func slash_trail(parent: Node3D, time := 0.35) -> void:
	var p := _particles(90, 0.22, GOLD, 0.07, 5.0, Vector2(0.0, 0.2))
	p.local_coords = false
	parent.add_child(p)
	p.emitting = true
	p.get_tree().create_timer(time).timeout.connect(func(): p.emitting = false)
	p.get_tree().create_timer(time + 0.4).timeout.connect(p.queue_free)

@tool
class_name Waterfall extends Node3D
## A waterfall: a falling sheet from a lip to a plunge pool that tears into ragged jets as it falls (an aerated white
## core, thin glassy edges), droplets peeling off the lip and the edges, a churning splash zone (radial foam and
## turbulence rings spreading out and drifting downstream), spray thrown up at the impact and lit mist billowing out
## and drifting with the wind, and a looping 3D roar.
## Cascade mode (`path` set): the water tumbles down a rocky chute along the given centre line instead of falling
## freely (used for the steep stretches of the island's rivers).
##
## USAGE
##   var f := Waterfall.new()
##   f.top = Vector3(0, 0, 0)          # water surface at the lip (node space)
##   f.bottom = Vector3(0, -16, 5)     # plunge pool surface (node space); the sheet follows a parabola between them
##   f.width = 10.0                    # width at the lip (the sheet spreads by `spread` towards the bottom)
##   add_child(f)                      # builds on _ready; call rebuild() after changing exports
##
##   f.path = PackedVector3Array([...]) # node space, lip -> foot: a cascade down that line (top/bottom = its ends)
##
##   Waterfall.from_dict({"top": [x, y, z], "bottom": [x, y, z], "width": 14.0})   # world_layout.json `waterfalls[]`
##   (the node goes to `top`; drop / river / id keys are accepted and ignored except id -> node name)
##   Waterfall.from_gap(gap)  # a cascade for a WaterBody.gap_spans() entry
##
## QUERIES (for audio / gameplay)
##   impact_position() -> Vector3   world point where the water hits the pool (the loudest spot)
##   impact_strength() -> float     0..1 from the drop, the width and the flow (a 70 m, 14 m wide fall is ~1)
##   lip_position() -> Vector3      world point of the lip (centre)
##   drop_height() -> float         m; is_cascade() -> bool
##
## The waterfall does not answer water queries: the river above ends at the lip (its steep stretch is a gap) and the
## pool below is a WaterBody lake or river. Set `pool_radius` > 0 to have the waterfall add a pool WaterBody itself
## (round, or `pool_polygon`).
## Performance: ~40 x 14 sheet quads (cascades up to 160 rows), <= ~420 particles (mist, spray, droplets), everything
## hidden beyond `visibility_range` / `particles_range`.

const SHEET_SHADER := preload("res://Components/Water/shaders/waterfall.gdshader")
const CHURN_SHADER := preload("res://Components/Water/shaders/waterfall_churn.gdshader")
const DROP_SHADER := preload("res://Components/Water/shaders/water_droplets.gdshader")
const NOISE_TEX := preload("res://Components/Water/textures/falls_noise.png")
const JETS_TEX := preload("res://Components/Water/textures/falls_jets.png")
const PUFF_TEX := preload("res://Components/Water/textures/mist_puff.png")
const MIST_SHADER := preload("res://Components/Water/shaders/water_mist.gdshader")
const FOAM_TEX := preload("res://Components/Ocean/textures/foam.png")
const RIVER_FOAM_TEX := preload("res://Components/Water/textures/river_foam.png")
const MIST_LIFT := 0.9

@export_tool_button("Rebuild", "Reload") var rebuild_action := rebuild
## Water surface at the lip (node space).
@export var top := Vector3.ZERO
## Plunge pool surface (node space).
@export var bottom := Vector3(0, -12, 4)
@export var width := 6.0
## Horizontal run-up of the sheet before the lip (merges with the river surface).
@export var lip_length := 2.5
## Water speed over the lip (m/s): sets how fast the texture moves at the top.
@export var lip_speed := 2.5
## Width multiplier at the bottom.
@export var spread := 1.25
## How much the sheet bows out in the middle (fraction of the width).
@export var bulge := 0.08
@export var rows := 40
@export var columns := 14
@export var water_color := Color(0.06, 0.13, 0.12)
@export var foam_color := Color(0.8, 0.83, 0.84)
## How ragged the lower sheet gets (0 = a smooth curtain).
@export_range(0.0, 2.0) var breakup := 1.0
## Cascade: the centre line (node space, lip -> foot, on the water surface). Empty = a free fall from top to bottom.
@export var path := PackedVector3Array()

@export_group("Pool")
## Radius of the white water disc on the pool (0 = automatic from width and drop).
@export var churn_radius := 0.0
@export var churn := true
## > 0: also create a WaterBody lake of this radius at `bottom`.
@export var pool_radius := 0.0
## Optional pool shoreline (x, z relative to `bottom`); empty = a circle of pool_radius.
@export var pool_polygon := PackedVector2Array()

@export_group("Mist")
## Multiplies the particle counts (0 = no particles).
@export_range(0.0, 2.0) var mist := 1.0
@export var spray := true
## Droplets peeling off the lip and the edges of the sheet, and splash drops at the impact.
@export var droplets := true

@export_group("Audio")
@export var sound := true
@export var volume_db := 0.0
@export var max_distance := 320.0

@export_group("Rendering")
@export var visibility_range := 900.0
@export var particles_range := 320.0

var sheet: MeshInstance3D
var churn_mesh: MeshInstance3D
var mist_particles: GPUParticles3D
var spray_particles: GPUParticles3D
var veil_particles: GPUParticles3D
var drop_particles: Array[GPUParticles3D] = []
var roar: FlowingWaterSound
var pool: WaterBody
var sheet_material: ShaderMaterial
var churn_material: ShaderMaterial
var drop_material: ShaderMaterial
var mist_materials: Array[ShaderMaterial] = []

var _dir := Vector3(0, 0, 1)
var _side := Vector3(1, 0, 0)
var _drop := 1.0
var _wind_t := 0.0

func _ready() -> void:
	if not Engine.is_editor_hint():
		add_to_group(&"waterfall_interaction")
	rebuild()

## Rebuilds the sheet, churn disc, particles, pool and sound from the exports.
func rebuild() -> void:
	for c in get_children(true):
		if c.has_meta(&"waterfall_part"):
			c.queue_free()
	sheet = null
	churn_mesh = null
	mist_particles = null
	spray_particles = null
	veil_particles = null
	drop_particles.clear()
	mist_materials.clear()
	drop_material = null
	roar = null
	pool = null
	if is_cascade():
		top = path[0]
		bottom = path[path.size() - 1]
	var d := Vector3(bottom.x - top.x, 0.0, bottom.z - top.z)
	_dir = d.normalized() if d.length() > 0.05 else Vector3(0, 0, 1)
	_side = _dir.cross(Vector3.UP).normalized()
	_drop = maxf(top.y - bottom.y, 0.5)
	_build_sheet(d.length())
	if churn:
		_build_churn()
	if mist > 0.0 and not Engine.is_editor_hint():
		_build_particles()
	if pool_radius > 0.0:
		pool = WaterBody.new()
		pool.name = "Pool"
		pool.kind = WaterBody.Kind.LAKE
		pool.radius = pool_radius
		pool.polygon = pool_polygon
		pool.max_depth = maxf(3.0, _drop * 0.25)
		_part(pool)
		pool.position = Vector3(bottom.x, 0.0, bottom.z)
		pool.level = (global_transform * bottom).y if is_inside_tree() else bottom.y
	if sound and not Engine.is_editor_hint():
		roar = FlowingWaterSound.new()
		roar.name = "Roar"
		# A cascade tumbling down a chute sounds like very rough rapids; a free fall roars.
		roar.kind = FlowingWaterSound.Kind.RAPIDS if is_cascade() else FlowingWaterSound.Kind.WATERFALL
		roar.size = _drop if not is_cascade() else width
		roar.width = width
		roar.flow_speed = maxf(lip_speed, 3.0)
		roar.turbulence = 1.0
		roar.spread = maxf(width * 0.5, 2.0)
		roar.unit_size = clampf(sqrt(_drop * width) * 0.9, 4.0, 30.0)
		roar.max_distance = max_distance
		roar.volume_db = volume_db
		_part(roar)
		roar.position = bottom + Vector3(0, 1.5, 0) - _dir * 1.0

func _part(n: Node) -> void:
	n.set_meta(&"waterfall_part", true)
	add_child(n, false, Node.INTERNAL_MODE_BACK)

# --- queries ---------------------------------------------------------------------------------------------

func is_cascade() -> bool:
	return path.size() >= 2

func drop_height() -> float:
	return _drop

## World point where the falling water hits the pool (or the foot of a cascade).
func impact_position() -> Vector3:
	return global_transform * (bottom + Vector3(0, 0.3, 0))

## World point of the lip (centre).
func lip_position() -> Vector3:
	return global_transform * top

## 0..1: how powerful the fall is (drop x width x lip speed; a 70 m, 14 m wide fall is ~1; cascades count half).
func impact_strength() -> float:
	var e := sqrt(_drop * width * maxf(lip_speed, 0.5)) / 45.0
	return clampf(e * (0.5 if is_cascade() else 1.0), 0.05, 1.0)

# --- sheet -----------------------------------------------------------------------------------------------

## Centre line of the fall. Free fall: lip run-up, then a parabola from the lip to just below the pool surface.
## Cascade: the run-up, then the path, with the time of flight integrated along it (gravity along the slope minus
## friction). Returns [points, tof, fall_fraction].
func _centre_line(dh: float) -> Array:
	var pts := PackedVector3Array()
	var tof := PackedFloat32Array()
	var ff := PackedFloat32Array()
	var g := 9.81
	var lip_n := 6
	var d0 := _dir
	if is_cascade():
		var h0 := Vector3(path[1].x - path[0].x, 0.0, path[1].z - path[0].z)
		if h0.length() > 0.05:
			d0 = h0.normalized()
	for i in lip_n:
		var u := float(i) / lip_n
		var back := lip_length * (1.0 - u)
		pts.append(top - d0 * back)
		tof.append(-back / maxf(lip_speed, 0.1))
		ff.append(0.0)
	if is_cascade():
		var v := maxf(lip_speed, 0.5)
		var tf := 0.0
		for i in range(0, path.size() - 1):
			var a := path[i]
			var b := path[i + 1]
			var seg := a.distance_to(b)
			var sub := maxi(int(ceil(seg / 0.5)), 1)
			for j in sub:
				var p0 := a.lerp(b, float(j) / sub)
				var p1 := a.lerp(b, float(j + 1) / sub)
				var l := p0.distance_to(p1)
				if i > 0 or j > 0:
					pts.append(p0)
					tof.append(tf)
					ff.append(clampf((top.y - p0.y) / _drop, 0.0, 1.0))
				# Tumbling water: most of the fall's energy goes into turbulence (friction), so it speeds up slowly.
				var v1 := sqrt(maxf(v * v + 2.0 * g * (p0.y - p1.y) * 0.35, 0.25))
				v1 = minf(v1, 9.0)
				tf += l / maxf((v + v1) * 0.5, 0.3)
				v = v1
		pts.append(path[path.size() - 1] + Vector3.DOWN * 0.5)
		tof.append(tf + 0.1)
		ff.append(1.0)
		return [pts, tof, ff]
	var extra := 0.9 # plunge below the pool surface
	var f_end := sqrt((_drop + extra) / _drop)
	var n := 160
	for i in n + 1:
		var f := f_end * float(i) / n
		var fall := _drop * f * f
		# Leave the lip horizontally at lip_speed, then follow the parabola to the bottom point.
		var p := top + _dir * dh * f + Vector3.DOWN * fall
		pts.append(p)
		tof.append(sqrt(2.0 * fall / g))
		ff.append(clampf(fall / _drop, 0.0, 1.0))
	return [pts, tof, ff]

func _build_sheet(dh: float) -> void:
	var cl := _centre_line(dh)
	var pts: PackedVector3Array = cl[0]
	var tofs: PackedFloat32Array = cl[1]
	var ffs: PackedFloat32Array = cl[2]
	# Arc length of the fine line, then rows spaced by arc length (denser near the lip where the curve bends).
	var arc := PackedFloat32Array([0.0])
	for i in range(1, pts.size()):
		arc.append(arc[i - 1] + pts[i].distance_to(pts[i - 1]))
	var total := arc[arc.size() - 1]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var nr := maxi(rows, 8)
	if is_cascade():
		nr = clampi(int(total / 1.1), 16, 180)
	var nc := maxi(columns, 4)
	# Two layers. Free fall: the front curtain and, a little behind it, a narrower inner one (the fall has body seen
	# from the side). Cascade: the water on the rock and a narrower tumbling white layer riding on top.
	var thick := clampf(0.2 + _drop * 0.02 + width * 0.02, 0.2, 1.5)
	for layer in 2:
		_sheet_layer(st, layer, thick, pts, tofs, ffs, arc, total, nr, nc)
	for layer in 2:
		var base := layer * (nr + 1) * (nc + 1)
		for r in nr:
			for c in nc:
				var a := base + r * (nc + 1) + c
				var b := a + nc + 1
				# Front faces (clockwise) look out of the cliff, along the normals.
				st.add_index(a)
				st.add_index(b)
				st.add_index(a + 1)
				st.add_index(a + 1)
				st.add_index(b)
				st.add_index(b + 1)
	_finish_sheet(st)

func _sheet_layer(st: SurfaceTool, layer: int, thick: float, pts: PackedVector3Array, tofs: PackedFloat32Array,
		ffs: PackedFloat32Array, arc: PackedFloat32Array, total: float, nr: int, nc: int) -> void:
	var j := 0
	var casc := is_cascade()
	for r in nr + 1:
		var s := total * (float(r) / nr if casc else pow(float(r) / nr, 1.35))
		while j < arc.size() - 2 and arc[j + 1] < s:
			j += 1
		var t := clampf((s - arc[j]) / maxf(arc[j + 1] - arc[j], 1e-5), 0.0, 1.0)
		var p := pts[j].lerp(pts[j + 1], t)
		var tf := lerpf(tofs[j], tofs[j + 1], t)
		var fr := lerpf(ffs[j], ffs[j + 1], t)
		# Smoothed tangent (the cascade path has kinks).
		var ja := maxi(j - 2, 0)
		var jb := mini(j + 3, pts.size() - 1)
		var tan := (pts[jb] - pts[ja]).normalized()
		var nrm := _side.cross(tan).normalized()
		var w: float
		if casc:
			w = width * (1.0 if layer == 0 else 0.72)
			p += nrm * (0.1 + 0.3 * float(layer)) * smoothstep(0.0, 0.05, fr)
		else:
			w = width * lerpf(1.0, spread, pow(fr, 0.7)) * (1.0 if layer == 0 else 0.86)
			p -= nrm * thick * float(layer) * smoothstep(0.0, 0.15, fr)
		var bow := 0.0 if casc else bulge * w * smoothstep(0.0, 0.25, fr)
		for c in nc + 1:
			var x := float(c) / nc - 0.5
			var v := p + _side * x * w + nrm * bow * (0.25 - x * x) * 4.0
			if casc:
				# Water piles up in the middle of the chute and thins at the sides.
				v += nrm * (0.25 - x * x) * 0.6
			else:
				# The edges curl back towards the cliff a little.
				v -= nrm * smoothstep(0.35, 0.5, absf(x)) * 0.15 * w * fr
			st.set_uv(Vector2(x + 0.5, tf))
			st.set_uv2(Vector2(fr, s))
			st.set_color(Color(float(layer), 1.0 if casc else 0.0, 0.0, 1.0))
			st.set_normal(nrm)
			st.set_tangent(Plane(_side, 1.0))
			st.add_vertex(v)

func _finish_sheet(st: SurfaceTool) -> void:
	sheet_material = ShaderMaterial.new()
	sheet_material.shader = SHEET_SHADER
	sheet_material.set_shader_parameter(&"noise_tex", NOISE_TEX)
	sheet_material.set_shader_parameter(&"jets_tex", JETS_TEX)
	sheet_material.set_shader_parameter(&"water_color", water_color)
	sheet_material.set_shader_parameter(&"foam_color", foam_color)
	sheet_material.set_shader_parameter(&"width_m", width)
	sheet_material.set_shader_parameter(&"breakup", breakup)
	sheet_material.set_shader_parameter(&"flow_rate", 1.0)
	sheet_material.set_shader_parameter(&"drop_m", _drop)
	sheet = MeshInstance3D.new()
	sheet.name = "Sheet"
	sheet.mesh = st.commit()
	sheet.material_override = sheet_material
	sheet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sheet.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	sheet.extra_cull_margin = 2.0
	_range(sheet, visibility_range)
	_part(sheet)

func _range(g: GeometryInstance3D, r: float) -> void:
	if r > 0.0:
		g.visibility_range_end = r
		g.visibility_range_end_margin = r * 0.1
		g.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF

# --- churn (the splash zone on the pool) -----------------------------------------------------------------

func _churn_r() -> float:
	if churn_radius > 0.0:
		return churn_radius
	if is_cascade():
		return clampf(width * 0.8 + _drop * 0.05, 2.5, 12.0)
	return clampf(width * 0.9 + _drop * 0.15, 3.0, 32.0)

func _build_churn() -> void:
	var R := _churn_r()
	var segs := 64
	var rings := 14
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# An oval: stretched downstream (the outflow carries the foam away) and across (the sheet is wide).
	var centre := bottom + Vector3(0, 0.04, 0) + _dir * 0.3
	var across_r := maxf(R, width * (1.0 if is_cascade() else spread) * 0.6)
	for r in rings + 1:
		var rr := pow(float(r) / rings, 1.3)
		for s in segs + 1:
			var a := TAU * s / segs
			var c := cos(a)
			var sn := sin(a)
			var along := c * R * (1.6 if c > 0.0 else 0.7)
			var across := sn * across_r
			st.set_uv(Vector2(float(s) / segs, rr))
			# UV2: metres from the impact (along the outflow, across).
			st.set_uv2(Vector2(along * rr, across * rr))
			st.set_normal(Vector3.UP)
			st.add_vertex(centre + (_dir * along + _side * across) * rr)
	for r in rings:
		for s in segs:
			var a := r * (segs + 1) + s
			var b := a + segs + 1
			st.add_index(a)
			st.add_index(b)
			st.add_index(a + 1)
			st.add_index(a + 1)
			st.add_index(b)
			st.add_index(b + 1)
	churn_material = ShaderMaterial.new()
	churn_material.shader = CHURN_SHADER
	churn_material.render_priority = 1 # after the pool's water surface
	churn_material.set_shader_parameter(&"foam_tex", RIVER_FOAM_TEX)
	churn_material.set_shader_parameter(&"noise_tex", NOISE_TEX)
	churn_material.set_shader_parameter(&"foam_color", foam_color)
	churn_material.set_shader_parameter(&"radius_m", R)
	churn_material.set_shader_parameter(&"impact_half_width", width * (0.5 if is_cascade() else spread * 0.45))
	churn_material.set_shader_parameter(&"intensity", clampf(0.8 + _drop * 0.012, 0.7, 1.3) * (0.8 if is_cascade() else 1.0))
	churn_material.set_shader_parameter(&"outflow_speed", clampf(lip_speed * 0.5, 0.6, 2.5))
	var gb := global_basis if is_inside_tree() else basis
	var dw := gb * _dir
	var sw := gb * _side
	churn_material.set_shader_parameter(&"dir_w", Vector2(dw.x, dw.z).normalized())
	churn_material.set_shader_parameter(&"side_w", Vector2(sw.x, sw.z).normalized())
	churn_mesh = MeshInstance3D.new()
	churn_mesh.name = "Churn"
	churn_mesh.mesh = st.commit()
	churn_mesh.material_override = churn_material
	churn_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	churn_mesh.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_range(churn_mesh, visibility_range * 0.6)
	_part(churn_mesh)

# --- particles -------------------------------------------------------------------------------------------

func _puff_material(alpha_scale: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = MIST_SHADER
	m.set_shader_parameter(&"puff_tex", PUFF_TEX)
	m.set_shader_parameter(&"albedo", Color(0.86, 0.88, 0.9, alpha_scale))
	# Fade out towards the pool surface: bottom (node space) -> world height.
	m.set_shader_parameter(&"floor_y", (global_transform * bottom).y if is_inside_tree() else bottom.y)
	mist_materials.append(m)
	return m

func _ramp(stops: Array) -> GradientTexture1D:
	var g := Gradient.new()
	var offs := PackedFloat32Array()
	var cols := PackedColorArray()
	for s: Array in stops:
		offs.append(s[0])
		cols.append(Color(1, 1, 1, s[1]))
	g.offsets = offs
	g.colors = cols
	var t := GradientTexture1D.new()
	t.gradient = g
	return t

func _curve_tex(a: float, b: float, c: float) -> CurveTexture:
	var cv := Curve.new()
	cv.max_value = maxf(maxf(a, b), c)
	cv.add_point(Vector2(0.0, a))
	cv.add_point(Vector2(0.4, b))
	cv.add_point(Vector2(1.0, c))
	var t := CurveTexture.new()
	t.curve = cv
	return t

func _particles(nm: String, amount: int, lifetime: float, aabb: AABB, pm: ParticleProcessMaterial, mesh: Mesh,
		range_m: float, parent: Node3D) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = nm
	p.amount = maxi(amount, 1)
	p.lifetime = lifetime
	p.preprocess = lifetime
	p.randomness = 0.5
	p.fixed_fps = 30
	p.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	p.visibility_aabb = aabb
	p.process_material = pm
	p.draw_pass_1 = mesh
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_range(p, range_m)
	parent.add_child(p)
	return p

func _drop_mesh(w: float, l: float) -> QuadMesh:
	if drop_material == null:
		drop_material = ShaderMaterial.new()
		drop_material.shader = DROP_SHADER
	var q := QuadMesh.new()
	q.size = Vector2(w, l)
	q.material = drop_material
	return q

func _build_particles() -> void:
	var casc := is_cascade()
	var w := width * (1.0 if casc else spread)
	var size := sqrt(_drop * width)
	var base := Node3D.new()
	base.name = "Mist"
	_part(base)
	base.position = bottom + _dir * 0.5
	base.basis = Basis(-_side, Vector3.UP, _dir) # local x across, z downstream (right-handed)
	var big := AABB(Vector3(-w - 25, -3, -25), Vector3(w * 2 + 50, _drop + 30, 60))
	# Big soft mist puffs rolling out of the plunge.
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(w * 0.45, 0.4, 0.8)
	pm.direction = Vector3(0, 0.9, 1.0)
	pm.spread = 50.0
	pm.initial_velocity_min = 1.5 + size * 0.1
	pm.initial_velocity_max = 3.0 + size * 0.2
	# Mist billows up (warm, buoyant spray air) and away, rolling in a slow turbulence; damping stays below the lift.
	pm.gravity = Vector3(0, MIST_LIFT, 0)
	pm.damping_min = 0.2
	pm.damping_max = 0.45
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 1.5
	pm.turbulence_noise_scale = 6.0
	pm.turbulence_noise_speed_random = 0.3
	pm.turbulence_influence_min = 0.04
	pm.turbulence_influence_max = 0.1
	var s0 := clampf(size * 0.6, 2.5, 11.0) * (0.6 if casc else 1.0)
	pm.scale_min = s0 * 0.7
	pm.scale_max = s0 * 1.3
	pm.scale_curve = _curve_tex(0.35, 0.9, 1.6)
	pm.color_ramp = _ramp([[0.0, 0.0], [0.12, 0.8], [0.45, 0.45], [1.0, 0.0]])
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.angular_velocity_min = -12.0
	pm.angular_velocity_max = 12.0
	pm.anim_offset_max = 1.0
	var q := QuadMesh.new()
	q.material = _puff_material(0.7 if casc else 0.85)
	mist_particles = _particles("MistPuffs", int(clampi(int(size * 3.5 * mist), 12, 64) * (0.6 if casc else 1.0)), 6.0,
		big, pm, q, particles_range, base)
	if spray:
		# Spray thrown up and out of the plunge, falling back quickly.
		var ps := ParticleProcessMaterial.new()
		ps.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		ps.emission_box_extents = Vector3(w * 0.42, 0.2, 0.5)
		ps.direction = Vector3(0, 1.0, 0.55)
		ps.spread = 35.0
		ps.initial_velocity_min = 2.0 + size * 0.25
		ps.initial_velocity_max = 4.0 + size * 0.45
		ps.gravity = Vector3(0, -7.0, 0)
		ps.damping_min = 0.3
		ps.damping_max = 0.8
		var s1 := clampf(size * 0.12, 0.5, 2.2)
		ps.scale_min = s1 * 0.6
		ps.scale_max = s1 * 1.4
		ps.scale_curve = _curve_tex(0.5, 1.0, 1.8)
		ps.color_ramp = _ramp([[0.0, 0.0], [0.1, 0.8], [0.6, 0.45], [1.0, 0.0]])
		ps.angle_min = -180.0
		ps.angle_max = 180.0
		ps.anim_offset_max = 1.0
		var q2 := QuadMesh.new()
		q2.material = _puff_material(0.8)
		spray_particles = _particles("Spray", clampi(int(size * 5.0 * mist), 16, 64), 1.8, big, ps, q2,
			particles_range * 0.7, base)
	if droplets:
		_build_droplets(base, w, size, big)
	if _drop > 6.0 and not casc:
		# A veil of fine spray peeling off the lower sheet and drifting out.
		var pv := ParticleProcessMaterial.new()
		pv.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		pv.emission_box_extents = Vector3(w * 0.4, _drop * 0.22, 0.4)
		pv.direction = Vector3(0, -0.3, 1.0)
		pv.spread = 25.0
		pv.initial_velocity_min = 0.6
		pv.initial_velocity_max = 1.8
		pv.gravity = Vector3(0, -0.6, 0)
		pv.damping_min = 0.2
		pv.damping_max = 0.5
		var s2 := clampf(size * 0.3, 1.5, 5.0)
		pv.scale_min = s2 * 0.7
		pv.scale_max = s2 * 1.3
		pv.scale_curve = _curve_tex(0.4, 1.0, 1.7)
		pv.color_ramp = _ramp([[0.0, 0.0], [0.2, 0.4], [0.7, 0.2], [1.0, 0.0]])
		pv.angle_min = -180.0
		pv.angle_max = 180.0
		pv.anim_offset_max = 1.0
		var q3 := QuadMesh.new()
		q3.material = _puff_material(0.7)
		var f := sqrt(0.62)
		var d2 := Vector3(bottom.x - top.x, 0.0, bottom.z - top.z).length()
		var veil_base := Node3D.new()
		veil_base.name = "VeilBase"
		_part(veil_base)
		veil_base.position = top + _dir * (d2 * f + 0.6) + Vector3.DOWN * _drop * 0.62
		veil_base.basis = base.basis
		veil_particles = _particles("Veil", clampi(int(size * 1.5 * mist), 8, 28), 4.0,
			AABB(Vector3(-w - 20, -_drop - 5, -20), Vector3(w * 2 + 40, _drop + 20, 45)), pv, q3, particles_range * 0.8, veil_base)

## Droplets: streaks aligned with their velocity (water_droplets.gdshader). Splash drops thrown up at the impact,
## drops peeling off the lip and the edges of a free fall (they fall beside the sheet and separate from it).
func _build_droplets(base: Node3D, w: float, size: float, big: AABB) -> void:
	var casc := is_cascade()
	var pd := ParticleProcessMaterial.new()
	pd.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pd.emission_box_extents = Vector3(w * 0.45, 0.3, 0.8)
	pd.direction = Vector3(0, 1.0, 0.35)
	pd.spread = 40.0
	pd.initial_velocity_min = 2.5 + size * 0.2
	pd.initial_velocity_max = 5.0 + size * 0.45
	pd.gravity = Vector3(0, -9.8, 0)
	pd.particle_flag_align_y = true
	pd.scale_min = 0.6
	pd.scale_max = 1.4
	pd.color_ramp = _ramp([[0.0, 0.0], [0.05, 1.0], [0.8, 0.8], [1.0, 0.0]])
	drop_particles.append(_particles("SplashDrops", int(clampi(int(size * 12.0 * mist), 40, 180) * (0.6 if casc else 1.0)),
		1.4, big, pd, _drop_mesh(0.06, 0.45), particles_range * 0.5, base))
	if casc:
		return
	# Lip and edge drops: emitted along the lip, moving over it at lip speed, then falling freely.
	var lip := Node3D.new()
	lip.name = "LipDrops"
	_part(lip)
	lip.position = top + _dir * 0.2
	lip.basis = base.basis
	var fall_t := clampf(sqrt(2.0 * _drop / 9.81), 0.6, 4.0)
	var pl := ParticleProcessMaterial.new()
	pl.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pl.emission_box_extents = Vector3(width * 0.52, 0.05, 0.2)
	pl.direction = Vector3(0, 0.15, 1.0)
	pl.spread = 12.0
	pl.initial_velocity_min = lip_speed * 0.8
	pl.initial_velocity_max = lip_speed * 1.4 + 0.5
	pl.gravity = Vector3(0, -9.8, 0)
	pl.damping_min = 0.0
	pl.damping_max = 0.3
	pl.particle_flag_align_y = true
	pl.scale_min = 0.7
	pl.scale_max = 1.6
	pl.color_ramp = _ramp([[0.0, 0.0], [0.04, 0.9], [0.85, 0.7], [1.0, 0.0]])
	var la := AABB(Vector3(-w - 10, -_drop - 5, -5), Vector3(w * 2 + 20, _drop + 10, _drop * 0.6 + 20))
	drop_particles.append(_particles("LipDrops", clampi(int(width * _drop * 0.35 * mist), 40, 160), fall_t, la, pl,
		_drop_mesh(0.05, 0.55), particles_range * 0.6, lip))

## Farther than this from the camera, the shader clocks and lights are refreshed every 6th frame only.
const FAR_UPDATE_DIST := 400.0
var _far_skip := 0

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var cam := get_viewport().get_camera_3d()
	if cam and cam.global_position.distance_to(global_transform * ((top + bottom) * 0.5)) > FAR_UPDATE_DIST + top.distance_to(bottom) * 0.5:
		_far_skip -= 1
		if _far_skip > 0:
			return
		_far_skip = 6
		delta *= 6.0
	var env := WaterBody.env_state(get_tree())
	var t: float = env.time
	var sky: Vector3 = env.sky_horizon * 0.65 + env.sky_zenith * 0.35
	if sheet_material:
		sheet_material.set_shader_parameter(&"falls_time", t)
		sheet_material.set_shader_parameter(&"sky_color", sky)
	if churn_material:
		churn_material.set_shader_parameter(&"falls_time", t)
	# Mist and drops light themselves from the sky (soft, never black in the shade of the gorge) plus the sun.
	var sun: Vector3 = env.sun_dir
	var lit: Vector3 = env.light
	# Droplet clouds scatter every colour alike: mostly the sky's brightness, only a hint of its blue.
	var lum := sky.dot(Vector3(0.3, 0.55, 0.15))
	var soft := sky.lerp(Vector3(lum, lum, lum), 0.65)
	for m in mist_materials:
		m.set_shader_parameter(&"ambient_light", soft)
	if drop_material:
		drop_material.set_shader_parameter(&"light_color", soft * 1.1 + lit * 0.2)
		drop_material.set_shader_parameter(&"sun_dir", sun)
	_wind_t -= delta
	if _wind_t <= 0.0 and mist_particles:
		_wind_t = 0.5
		# Wind pushes the mist (in the particles' local frame: x across, z downstream).
		var wv: Vector2 = env.wind_vec
		var wl := Vector3(wv.x, 0.0, wv.y) * 0.08
		var b := mist_particles.global_basis.inverse()
		var g := b * wl
		(mist_particles.process_material as ParticleProcessMaterial).gravity = Vector3(g.x, MIST_LIFT, g.z)
		if spray_particles:
			(spray_particles.process_material as ParticleProcessMaterial).gravity = Vector3(g.x * 0.5, -7.0, g.z * 0.5)

## Waterfall from a `waterfalls[]` entry of world_layout.json: {top: [x, y, z], bottom: [x, y, z], width}.
static func from_dict(d: Dictionary) -> Waterfall:
	var f := Waterfall.new()
	f.name = String(d.get("id", "Waterfall"))
	var t: Array = d.get("top", [0, 0, 0])
	var b: Array = d.get("bottom", [0, -10, 0])
	var tv := Vector3(float(t[0]), float(t[1]), float(t[2]))
	var bv := Vector3(float(b[0]), float(b[1]), float(b[2]))
	f.position = tv
	f.top = Vector3.ZERO
	f.bottom = bv - tv
	f.width = float(d.get("width", 8.0))
	return f

## A cascade for a WaterBody.gap_spans() entry (world positions): the water tumbles down the gap's centre line.
static func from_gap(g: Dictionary) -> Waterfall:
	var f := Waterfall.new()
	var top_w: Vector3 = g.top
	f.position = top_w
	var p := PackedVector3Array()
	# A river's height control points span a cliff; interpolating their heights
	# can put a cascade tens of metres inside its upper rock shelf. Drape the
	# densely sampled centre line over the actual shelf before it falls.
	var source: PackedVector3Array = g.path
	for i in source.size() - 1:
		var a := source[i]
		var b := source[i + 1]
		var steps := maxi(int(ceil(Vector2(b.x - a.x, b.z - a.z).length() / 0.5)), 1)
		for j in steps:
			var q := a.lerp(b, float(j) / steps)
			var ground := WorldLayout.height_at(q.x, q.z)
			q.y = maxf(q.y, ground + 0.3)
			p.append(q - top_w)
	var last := source[source.size() - 1]
	var pool_height := last.y
	last.y = maxf(pool_height, WorldLayout.height_at(last.x, last.z) + 0.3)
	p.append(last - top_w)
	# The authored gap may end while still inside the shelf. Continue to the
	# actual cliff edge/plunge rather than leaving a flat strip above the rock.
	var downstream := last - source[0]
	downstream.y = 0.0
	downstream = downstream.normalized()
	for step in 100:
		if last.y <= pool_height + 0.35:
			break
		last += downstream * 0.5
		last.y = maxf(pool_height, WorldLayout.height_at(last.x, last.z) + 0.3)
		p.append(last - top_w)
	f.path = p
	f.width = maxf(float(g.width) * 0.85, 1.5)
	f.lip_speed = clampf(float(g.get("speed", 2.0)), 1.0, 5.0)
	f.lip_length = clampf(f.width * 0.3, 1.0, 3.0)
	f.spread = 1.0
	f.columns = clampi(int(f.width / 1.2), 6, 14)
	f.breakup = 0.6
	f.max_distance = 180.0
	f.volume_db = -4.0
	f.visibility_range = 700.0
	f.particles_range = 220.0
	return f

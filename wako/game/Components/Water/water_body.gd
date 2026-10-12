@tool
class_name WaterBody extends Node3D
## A lake (flat level inside a polygon) or a river (a ribbon along a Curve3D with a current). Builds its own surface
## mesh and material, registers with `Water` so height/normal/velocity queries (and Buoyancy) work, and plays a
## lapping / babbling ambience at the water nearest to the camera.
##
## USAGE
##   var lake := WaterBody.new(); lake.kind = WaterBody.Kind.LAKE
##   lake.level = 38.0                                   # world y of the surface
##   lake.polygon = PackedVector2Array([...])            # shoreline, x/z relative to the node (or leave empty + radius)
##   add_child(lake)                                     # builds on _ready (call rebuild() after changing exports)
##
##   var river := WaterBody.new(); river.kind = WaterBody.Kind.RIVER
##   river.curve = my_curve3d                            # centre line in node space, source -> mouth, y = water surface
##   river.width = 9.0; river.flow_speed = 1.6           # (+ width_curve / flow_curve / per-point arrays)
##   add_child(river)
##
##   WaterBody.lake_from_dict(d) / WaterBody.river_from_dict(d)  -> WaterBody (not yet in the tree)
##   Dicts follow World/world_layout.schema.md (`lakes[]`, `rivers[]`):
##     lake:  {id, center: [x, level, z], level, max_depth, radius, outline: [[x, z], ...] (world)}
##     river: {id, points: [[x, y, z], ...] (world, y = water surface), width: [..], depth: [..], flow: [..] (m/s),
##             into: "lake_x" | "sea" | river id}   (+ optional fade_in / fade_out in metres, source_foam 0..1,
##             sea_level: a river "into": "sea" is trimmed where its surface reaches the sea)
##
## QUERIES (what Water.* calls; cheap: a coarse grid + a one-entry cache, ~2-5 us per call)
##   contains(pos) -> bool       inside the footprint, below level + 2 m and above the bed (- 3 m)
##   height_at(pos) -> float     lake: level. river: surface height at the nearest centre-line point, plus the drawn
##                               standing waves / boulder pillows (interpolated like the mesh: within ~1-2 cm)
##   normal_at(pos) -> Vector3   river: tilted along its slope
##   velocity_at(pos) -> Vector3 river: the drawn surface current (fast core pushed to the outer bank in bends, slow
##                               banks, back-flow in eddies below bends, spreading where it widens) * depth fall-off;
##                               lake: a slight wind drift at the surface
##   river_progress(pos) -> Vector2 (arc length along the river, signed lateral offset), river_length(), river_point(s)
## AUDIO / GAMEPLAY QUERIES (rivers; lakes return 0 / {})
##   turbulence_at(pos) -> float      0 calm .. 1 white water at the nearest centre-line point (also on the bank)
##   rapids_near(pos, radius = 40) -> {position, strength, turbulence, flow_speed, distance}: the roughest water in range
##   flow_speed_at(pos) -> float      surface current (m/s) at the nearest centre-line point
##   gap_spans() -> Array[Dictionary] the steep stretches a Waterfall (cascade) must bridge (see Waterfall.from_gap)
##
## LOOK (per body, also what an underwater effect needs): `level`, `absorption` (Beer-Lambert per metre, fresh water:
## greenish-brown), `scatter_color` (lit in-scattered colour, updated every frame from the sun and sky), `scatter_tint`,
## `turbidity` (silt). Rivers are analysed per metre (_analyse_river): bends, eddies, white water on steep stretches,
## hydraulic jumps at the base of steps, glassy tongues before drops, riffles, foam carried downstream, standing waves
## and submerged boulders; the shader advects detail, boils and foam along the per-vertex current (dual-phase flow map).
## River segments steeper than `max_slope` are left out (a Waterfall bridges them). The node may be moved and rotated
## around Y; it must not be scaled.

enum Kind { LAKE, RIVER }

const SHADER := preload("res://Components/Water/shaders/water_body.gdshader")
const RIPPLE_TEX := preload("res://Components/Water/textures/lake_ripples.png")
const FLOW_TEX := preload("res://Components/Water/textures/river_flow.png")
const FOAM_TEX := preload("res://Components/Ocean/textures/foam.png")
const RAIN_TEX := preload("res://Components/Ocean/textures/ripples.png")
const CAUSTICS_TEX := preload("res://Components/Ocean/textures/caustics_atlas.png")
const RIVER_FOAM_TEX := preload("res://Components/Water/textures/river_foam.png")
const RIVER_BOILS_TEX := preload("res://Components/Water/textures/river_boils.png")

@export var kind := Kind.LAKE
@export_tool_button("Rebuild", "Reload") var rebuild_action := rebuild

@export_group("Lake")
## World height of the lake surface.
@export var level := 0.0
## Shoreline (x, z relative to the node). Empty = a circle of `radius`.
@export var polygon := PackedVector2Array()
@export var radius := 20.0
## Deepest point below the level (queries end 2 m below it).
@export var max_depth := 10.0

@export_group("River")
## Centre line in node space, source -> mouth; point y = water surface height.
@export var curve: Curve3D
## Water surface width (m).
@export var width := 8.0
## Width multiplier along the river (x = 0 source .. 1 mouth).
@export var width_curve: Curve
## Surface current (m/s) on flat stretches.
@export var flow_speed := 1.5
## Flow multiplier along the river (x = 0 source .. 1 mouth).
@export var flow_curve: Curve
## Current grows with the slope: speed *= 1 + slope_speedup * (drop per metre).
@export var slope_speedup := 3.0
@export var max_flow_speed := 9.0
## Channel depth below the surface (queries, current fall-off).
@export var depth := 1.5
## Optional per-curve-point values (same count as the curve's points; override width / flow_speed / depth).
@export var point_widths := PackedFloat32Array()
@export var point_flows := PackedFloat32Array()
@export var point_depths := PackedFloat32Array()
## Metres over which the surface fades in at the source / out at the mouth (where it merges into a lake or the sea).
@export var fade_in := 0.0
@export var fade_out := 0.0
## Stretches steeper than this (drop per metre) are left out: waterfalls.
@export var max_slope := 0.9
## Gaps that drop less than this are drawn as steep river rather than left for a waterfall.
@export var min_gap_drop := 3.0
## The river ends at a waterfall lip: the last metres run smooth and glassy (the tongue).
@export var end_lip := false
## Foam already on the water at the source (0..1), e.g. 1 for a river that starts in a waterfall's plunge pool.
@export_range(0.0, 1.0) var source_foam := 0.0
## Submerged boulders (pillows + V-shaped foam wakes) per metre, relative (0 = none).
@export_range(0.0, 3.0) var boulders := 1.0
## Standing-wave amplitude multiplier (rapids, the base of steps).
@export_range(0.0, 2.0) var waves := 1.0

@export_group("Mesh")
## Target vertex spacing (m). Big lakes coarsen it to stay under ~30k quads.
@export var mesh_spacing := 2.0
## Extra surface beyond the shoreline / river banks so it tucks under the terrain.
@export var bank_margin := 1.5
## Hide the surface beyond this distance (0 = never).
@export var visibility_range := 0.0

@export_group("Look")
## Beer-Lambert absorption per metre (r, g, b). Fresh water: blue goes first (humic) -> green-brown depths.
@export var absorption := Vector3(0.45, 0.13, 0.3)
## In-scattering colour of deep water per unit of daylight.
@export var scatter_tint := Color(0.016, 0.045, 0.032)
@export var water_albedo := Color(0.0, 0.02, 0.016)
@export var foam_color := Color(0.84, 0.87, 0.85)
@export_range(0.0, 1.0) var roughness := 0.04
@export var ripple_strength := 1.0
@export var foam_amount := 1.0
@export var shore_foam := 1.0
var interaction_revision := 0
@export var caustics := 0.8
## Suspended silt (extra extinction and olive in-scattering per metre). < 0 = automatic (rivers 0.3, lakes 0.04).
@export var turbidity := -1.0

@export_group("Audio")
@export var sound := true
@export var sound_volume_db := 0.0
@export var sound_max_distance := 70.0

## Lit in-scattered radiance of deep water this frame (HDR, what the shader uses).
var scatter_color := Vector3(0.01, 0.03, 0.02)
var material: ShaderMaterial

## Optional WATER2 rendered layer, disabled by default and detached on live toggle.
func set_extra_layer(disp: Texture2D, normal: Texture2D, rect: Rect2) -> void:
	if material == null:
		return
	material.set_shader_parameter(&"extra_enabled", true)
	material.set_shader_parameter(&"extra_disp", disp)
	material.set_shader_parameter(&"extra_normal", normal)
	material.set_shader_parameter(&"extra_rect", Vector4(rect.position.x, rect.position.y, 1.0/rect.size.x, 1.0/rect.size.y))

func clear_extra_layer() -> void:
	if material:
		material.set_shader_parameter(&"extra_enabled", false)
		material.set_shader_parameter(&"extra_disp", null)
		material.set_shader_parameter(&"extra_normal", null)
# Cached visual options. They never alter meshing, hydraulics or Water queries.
var _water_settings: Node
var _screen_reflections := true
var _draw_caustics := true
var _caustics_clear := 1.0
var _surface_caustics := -1.0
var mesh_instances: Array[MeshInstance3D] = []

var _built := false
var _xf := Transform3D.IDENTITY
var _inv := Transform3D.IDENTITY
var _bmin := Vector2.ZERO # footprint bounds (node space xz)
var _bmax := Vector2.ZERO
# Coarse grid over the footprint. Lake: per-cell state (0 out, 1 in, 2 boundary). River: CSR lists of segments.
var _g_origin := Vector2.ZERO
var _g_cell := 4.0
var _g_w := 0
var _g_h := 0
var _g_state := PackedByteArray()
var _g_start := PackedInt32Array()
var _g_items := PackedInt32Array()
var _poly := PackedVector2Array()
# River samples (node space).
var _rp := PackedVector3Array()
var _ra := PackedVector2Array()   # horizontal downstream direction
var _rhw := PackedFloat32Array()  # half width
var _rspd := PackedFloat32Array()
var _rdep := PackedFloat32Array()
var _rslope := PackedFloat32Array()
var _rsteep := PackedFloat32Array() # 0..1 white-water look, slope smoothed over ~20 m
var _rs := PackedFloat32Array()   # arc length
var _rok := PackedByteArray()     # segment k -> k+1 is water (not a waterfall gap)
var _rinv2 := PackedFloat32Array() # 1 / squared horizontal segment length
# River hydraulics per sample (see _analyse_river).
var _rkap := PackedFloat32Array()   # signed curvature (1/m), + = bending towards + lateral
var _rwhite := PackedFloat32Array() # white water 0..1
var _rtrail := PackedFloat32Array() # foam carried downstream 0..1
var _rjump := PackedFloat32Array()  # hydraulic jump 0..1
var _rlip := PackedFloat32Array()   # glassy tongue before a drop 0..1
var _ramp := PackedFloat32Array()   # standing-wave amplitude (m)
var _rphase := PackedFloat32Array() # standing-wave phase (rad, integrated along the river)
var _rkw := PackedFloat32Array()    # standing-wave number (rad/m)
var _reddy := PackedFloat32Array()  # eddy strength, sign = inner bank side
var _rdhw := PackedFloat32Array()   # d(half width)/ds
var _boulders: Array[Vector4] = []  # (s, lateral, radius, strength), sorted by s
var _mesh_cols := 8
# Query polyline: the samples decimated to ~4 m segments (kept at waterfall gaps), indexed by a pruned grid.
var _Qp := PackedVector3Array()
var _Qa := PackedVector2Array()
var _Qhw := PackedFloat32Array()
var _Qspd := PackedFloat32Array()
var _Qdep := PackedFloat32Array()
var _Qsl := PackedFloat32Array()
var _Qs := PackedFloat32Array()
var _Qok := PackedByteArray()
var _Qinv2 := PackedFloat32Array()
# One-entry query cache (Water.* asks contains() and then height/velocity for the same point).
var _q_pos := Vector3(INF, INF, INF)
var _q_in := false
var _q_h := -INF
var _q_n := Vector3.UP
var _q_v := Vector3.ZERO
var _q_s := 0.0
var _q_lat := 0.0
var _registered := false
var _sound: FlowingWaterSound
var _sound_t := 0.0
var _rebuild_queued := false
## Surface meshes are computed on a worker thread (the query structures are built right away, so queries, gap_spans()
## and flow_speed_at() work as soon as the body is in the tree); the meshes appear a frame or two later. This keeps
## ~0.5 s of lake/river meshing out of the frame the island enters the tree. Off in the editor.
var threaded_mesh := true
var _mesh_task := -1
var _mesh_gen := 0

# --- lifecycle -------------------------------------------------------------------------------------------

func _enter_tree() -> void:
	_bind_water_settings()
	if not Engine.is_editor_hint():
		Water.register_body(self)
		_registered = true
	set_notify_transform(true)

func _exit_tree() -> void:
	if is_instance_valid(_water_settings):
		_water_settings.changed.disconnect(_on_water_setting_changed)
		_water_settings.registered.disconnect(_on_water_setting_registered)
	_water_settings = null
	if _registered:
		Water.unregister_body(self)
		_registered = false
	_finish_mesh_task()

func _ready() -> void:
	rebuild()
	if not Engine.is_editor_hint() and sound:
		_sound = FlowingWaterSound.new()
		_sound.name = "Ambience"
		_sound.kind = FlowingWaterSound.Kind.RIVER if kind == Kind.RIVER else FlowingWaterSound.Kind.LAKE
		_sound.unit_size = 7.0 if kind == Kind.RIVER else 5.0
		_sound.max_distance = sound_max_distance
		_sound.volume_db = sound_volume_db
		_sound.active = false
		add_child(_sound)

# The ocean owns registration of these shared graphics knobs. Listen for late
# registration as well as edits so scene entry order does not change quality.
func _bind_water_settings() -> void:
	if Engine.is_editor_hint():
		return
	_water_settings = get_node_or_null(^"/root/Settings")
	if _water_settings == null:
		return
	_water_settings.changed.connect(_on_water_setting_changed)
	_water_settings.registered.connect(_on_water_setting_registered)
	_on_water_setting_registered(&"graphics/water_reflections")
	_on_water_setting_registered(&"graphics/water_caustics")

func _on_water_setting_registered(key: StringName) -> void:
	if key == &"graphics/water_reflections" or key == &"graphics/water_caustics":
		if _water_settings.has(key):
			_on_water_setting_changed(key, _water_settings.get_value(key))

func _on_water_setting_changed(key: StringName, value: Variant) -> void:
	match key:
		&"graphics/water_reflections": _screen_reflections = String(value) == "Screen-space"
		&"graphics/water_caustics": _draw_caustics = bool(value)
		_: return
	_apply_surface_quality()

func _apply_surface_quality() -> void:
	if material:
		material.set_shader_parameter(&"ssr_strength", 1.0 if _screen_reflections else 0.0)
		_update_caustics_quality()

func _update_caustics_quality() -> void:
	var strength := caustics * _caustics_clear if _draw_caustics else 0.0
	if not is_equal_approx(strength, _surface_caustics):
		_surface_caustics = strength
		material.set_shader_parameter(&"caustics_strength", strength)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_finish_mesh_task()
	if what == NOTIFICATION_TRANSFORM_CHANGED and is_inside_tree():
		_xf = global_transform
		_inv = _xf.affine_inverse()
		_q_pos = Vector3(INF, INF, INF)
		_publish_bounds()
		if kind == Kind.LAKE and _built and not _rebuild_queued:
			# The lake level is a world height: the mesh depends on the node's y.
			_rebuild_queued = true
			rebuild.call_deferred()

## Rebuilds the mesh, the material and the query structures from the exports.
func rebuild() -> void:
	interaction_revision+=1
	_rebuild_queued = false
	if not is_inside_tree():
		return
	_xf = global_transform
	_inv = _xf.affine_inverse()
	_q_pos = Vector3(INF, INF, INF)
	for mi in mesh_instances:
		if is_instance_valid(mi):
			mi.queue_free()
	mesh_instances.clear()
	_make_material()
	if kind == Kind.LAKE:
		_build_lake()
	else:
		_build_river()
	_built = true
	_publish_bounds()

## World box of everything contains() can accept (see _query), for Water.body_at's quick rejection; also used to
## throttle the per-frame shader updates of bodies far from the camera.
var world_box := AABB()

func _publish_bounds() -> void:
	var lo := 0.0
	var hi := 0.0
	if kind == Kind.LAKE:
		lo = level - max_depth - 2.5 - _xf.origin.y
		hi = level + 2.5 - _xf.origin.y
	elif not _Qp.is_empty():
		lo = INF
		hi = -INF
		var dmax := 0.0
		for k in _Qp.size():
			lo = minf(lo, _Qp[k].y)
			hi = maxf(hi, _Qp[k].y)
			dmax = maxf(dmax, _Qdep[k])
		# Queries accept 2 m above the surface (plus standing waves) and down to depth + 3 m.
		lo -= dmax + 4.0
		hi += 4.0
	else:
		world_box = AABB()
		if _registered:
			Water.set_body_bounds(self, world_box)
		return
	var local := AABB(Vector3(_bmin.x - 1.0, lo, _bmin.y - 1.0), Vector3(_bmax.x - _bmin.x + 2.0, hi - lo, _bmax.y - _bmin.y + 2.0))
	world_box = _xf * local
	if _registered:
		Water.set_body_bounds(self, world_box)

func _make_material() -> void:
	if material == null:
		material = ShaderMaterial.new()
		material.shader = SHADER
		_surface_caustics = -1.0
	var m := material
	m.set_shader_parameter(&"ripple_normals", RIPPLE_TEX)
	m.set_shader_parameter(&"flow_normals", FLOW_TEX)
	m.set_shader_parameter(&"foam_tex", FOAM_TEX)
	m.set_shader_parameter(&"rain_tex", RAIN_TEX)
	m.set_shader_parameter(&"caustics_atlas", CAUSTICS_TEX)
	m.set_shader_parameter(&"is_river", kind == Kind.RIVER)
	m.set_shader_parameter(&"absorption", absorption)
	m.set_shader_parameter(&"scatter_color", scatter_color)
	m.set_shader_parameter(&"water_albedo", _v3(water_albedo))
	m.set_shader_parameter(&"foam_color", _v3(foam_color))
	m.set_shader_parameter(&"roughness", roughness)
	m.set_shader_parameter(&"normal_strength", ripple_strength)
	m.set_shader_parameter(&"foam_amount", foam_amount)
	m.set_shader_parameter(&"shore_foam", shore_foam)
	m.set_shader_parameter(&"caustics_scale", 0.3)
	m.set_shader_parameter(&"river_foam", RIVER_FOAM_TEX)
	m.set_shader_parameter(&"river_boils", RIVER_BOILS_TEX)
	var river := kind == Kind.RIVER
	m.set_shader_parameter(&"turbidity", turbidity if turbidity >= 0.0 else (0.3 if river else 0.04))
	m.set_shader_parameter(&"edge_softness", 0.28 if river else 0.1)
	_apply_surface_quality()

static func _v3(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)

## Runs `job` (returns [[name, arrays, format flags], ...]; pure maths on this body's finished query data) on a worker
## thread, then adds the meshes on the main thread. A newer rebuild supersedes a pending one.
func _queue_meshes(job: Callable) -> void:
	_finish_mesh_task()
	_mesh_gen += 1
	var gen := _mesh_gen
	if not threaded_mesh or Engine.is_editor_hint():
		_add_meshes(gen, job.call())
		return
	_mesh_task = WorkerThreadPool.add_task(func() -> void:
		var out: Array = job.call()
		_add_meshes.call_deferred(gen, out), false, "WaterBody meshes")

## Waits for a running mesh task (pure maths, no resource loading, so blocking on it can't deadlock).
func _finish_mesh_task() -> void:
	if _mesh_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_mesh_task)
		_mesh_task = -1

func _add_meshes(gen: int, parts: Array) -> void:
	if gen != _mesh_gen:
		return
	_finish_mesh_task()
	for part: Array in parts:
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, part[1], [], {}, part[2])
		_add_mesh(mesh, part[0])

func _add_mesh(mesh: Mesh, nm: String) -> void:
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = mesh
	mi.material_override = material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	if visibility_range > 0.0:
		mi.visibility_range_end = visibility_range
		mi.visibility_range_end_margin = visibility_range * 0.1
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(mi, false, Node.INTERNAL_MODE_BACK)
	mesh_instances.append(mi)

# --- per frame -------------------------------------------------------------------------------------------

## Bodies farther than this from the camera refresh their shader uniforms (light, wind, clocks) only every
## FAR_UPDATE_EVERY frames: the ripples are sub-pixel there.
const FAR_UPDATE_DIST := 350.0
const FAR_UPDATE_EVERY := 6
var _far_skip := 0

func _process(delta: float) -> void:
	if Engine.is_editor_hint() or material == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam != null and world_box.size != Vector3.ZERO:
		var cp := cam.global_position
		var d := world_box.get_center().distance_to(cp) - world_box.size.length() * 0.5
		if d > FAR_UPDATE_DIST:
			_far_skip -= 1
			if _far_skip > 0:
				if _sound:
					_update_sound(delta, env_state(get_tree()))
				return
			_far_skip = FAR_UPDATE_EVERY
	var env := env_state(get_tree())
	var light: Vector3 = env.light
	scatter_color = Vector3(scatter_tint.r * light.x, scatter_tint.g * light.y, scatter_tint.b * light.z)
	var m := material
	m.set_shader_parameter(&"scatter_color", scatter_color)
	m.set_shader_parameter(&"wind_dir", env.wind_dir)
	m.set_shader_parameter(&"wind_speed", env.wind_speed)
	m.set_shader_parameter(&"rain", env.rain)
	m.set_shader_parameter(&"water_time", env.time)
	m.set_shader_parameter(&"caustics_time", env.time)
	m.set_shader_parameter(&"sky_zenith", env.sky_zenith)
	m.set_shader_parameter(&"sky_horizon", env.sky_horizon)
	m.set_shader_parameter(&"sun_refracted", env.sun_refracted)
	_caustics_clear = float(env.clear)
	_update_caustics_quality()
	m.set_shader_parameter(&"cam_inside", cam != null and contains(cam.global_position))
	_update_sound(delta, env)

func _update_sound(delta: float, env: Dictionary) -> void:
	if _sound == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	_sound_t -= delta
	if _sound_t > 0.0:
		return
	_sound_t = 0.2
	var cp := cam.global_position
	var q := _inv * cp
	var far := sound_max_distance + 5.0
	if q.x < _bmin.x - far or q.x > _bmax.x + far or q.z < _bmin.y - far or q.z > _bmax.y + far:
		_sound.active = false
		return
	if kind == Kind.RIVER:
		var k := _nearest_sample(q)
		if k < 0:
			_sound.active = false
			return
		var p := _rp[k]
		var a := _ra[k]
		var side := Vector3(-a.y, 0.0, a.x)
		var lat := clampf((q - p).dot(side), -_rhw[k], _rhw[k])
		var point := _xf * (p + side * lat)
		var spd := _rspd[k]
		var turb := clampf(_rwhite[k] + _boulder_at(_rs[k], lat).x * 0.5, 0.0, 1.0)
		var hw := _rhw[k]
		# Rough water close by dominates what you hear: follow it (the loudest spot, not the nearest).
		var rp := rapids_near(cp, 35.0)
		if not rp.is_empty() and float(rp.turbulence) * (1.0 - float(rp.distance) / 35.0) > turb * 0.9:
			point = rp.position
			turb = float(rp.turbulence)
			spd = float(rp.flow_speed)
		_sound.size = hw * 2.0
		_sound.update_listener_point(point, spd, turb, _xf.basis * Vector3(a.x, 0.0, a.y))
	else:
		var q2 := Vector2(q.x, q.z)
		var best := INF
		var bp := Vector2.ZERO
		var n := _poly.size()
		for i in n:
			var c := Geometry2D.get_closest_point_to_segment(q2, _poly[i], _poly[(i + 1) % n])
			var d := c.distance_squared_to(q2)
			if d < best:
				best = d
				bp = c
		_sound.update_listener_point(_xf * Vector3(bp.x, level - _xf.origin.y, bp.y))
		_sound.wind = float(env.wind_speed)
	_sound.active = true

# --- shared environment (weather, sky light) -------------------------------------------------------------

static var _env := {}
static var _env_frame := -1
static var _env_usec := 0
static var _clock := 0.0
static var _sun_id := 0

## Wind, rain, sky light and a clock shared by all water bodies and waterfalls (computed once per frame).
## Keys: time, wind_speed, wind_dir (Vector2 x/z the wind blows towards), wind_vec, rain, storm, light (Vector3 daylight
## for scatter colours), sky_zenith, sky_horizon, sun_dir, sun_refracted, clear (0..1 direct sun).
static func env_state(tree: SceneTree) -> Dictionary:
	var f := Engine.get_process_frames()
	if f == _env_frame and not _env.is_empty():
		return _env
	_env_frame = f
	var now := Time.get_ticks_usec()
	if _env_usec > 0:
		_clock = fmod(_clock + minf((now - _env_usec) * 1e-6, 0.25), 3600.0)
	_env_usec = now
	var weather: Node = tree.get_first_node_in_group(&"weather") if tree else null
	var wind := 3.0
	var wind_deg := 240.0
	var rain := 0.0
	var storm := 0.0
	if weather and "params" in weather:
		var p: Dictionary = weather.params
		wind = p.get("wind_speed", wind)
		wind_deg = p.get("wind_direction", wind_deg)
		rain = p.get("rain", 0.0)
		storm = p.get("storminess", 0.0)
	var sun: DirectionalLight3D = null
	if weather and "sun" in weather and is_instance_valid(weather.sun):
		sun = weather.sun
	elif tree:
		sun = instance_from_id(_sun_id) as DirectionalLight3D if _sun_id != 0 else null
		if sun == null and f % 60 == 1:
			for l in tree.root.find_children("*", "DirectionalLight3D", true, false):
				sun = l
				_sun_id = l.get_instance_id()
				break
	var sun_dir := Vector3(0.3, 0.8, 0.2).normalized()
	var sun_energy := 1.0
	var sun_col := Color.WHITE
	if sun:
		sun_dir = sun.global_basis.z.normalized()
		sun_energy = sun.light_energy if sun.visible else 0.0
		sun_col = sun.light_color
	var sky := Vector3(0.35, 0.45, 0.6)
	if weather and weather.has_method("zenith_radiance"):
		sky = weather.zenith_radiance(weather.sun_dir, weather.params.sun_intensity)
		sky += weather.zenith_radiance(weather.moon_dir, weather.params.sun_intensity * 0.02) + Vector3(0.002, 0.003, 0.005)
		sky *= 1.0 - weather.overcast() * 0.45
	var sun_irr := Vector3(sun_col.r, sun_col.g, sun_col.b) * sun_energy * maxf(sun_dir.y, 0.0)
	var horizon := sky * 2.2 + Vector3(0.02, 0.02, 0.025)
	if weather and "env" in weather and weather.env:
		var fc: Color = weather.env.fog_light_color
		horizon = Vector3(fc.r, fc.g, fc.b) * 1.1
	var a := deg_to_rad(wind_deg)
	var wd := Vector2(sin(a), cos(a))
	_env = {
		"time": _clock, "wind_speed": wind, "wind_dir": wd, "wind_vec": wd * wind, "rain": rain, "storm": storm,
		"light": sun_irr * 0.55 + sky * 1.4, "sky_zenith": sky * 1.3, "sky_horizon": horizon, "sun_dir": sun_dir,
		"sun_refracted": _refract(-sun_dir, Vector3.UP, 1.0 / 1.333),
		"clear": clampf(sun_energy / 2.5, 0.0, 1.0) * smoothstep(0.02, 0.2, sun_dir.y),
	}
	return _env

static func _refract(i: Vector3, n: Vector3, eta: float) -> Vector3:
	var cosi := -n.dot(i)
	var k := 1.0 - eta * eta * (1.0 - cosi * cosi)
	if k < 0.0:
		return Vector3.DOWN
	return (i * eta + n * (eta * cosi - sqrt(k))).normalized()

# --- queries ---------------------------------------------------------------------------------------------

func contains(pos: Vector3) -> bool:
	if pos != _q_pos:
		_query(pos)
	return _q_in

func height_at(pos: Vector3) -> float:
	if pos != _q_pos:
		_query(pos)
	return _q_h

func normal_at(pos: Vector3) -> Vector3:
	if pos != _q_pos:
		_query(pos)
	return _q_n

func velocity_at(pos: Vector3) -> Vector3:
	if pos != _q_pos:
		_query(pos)
	return _q_v

## Surface/depth/current in XZ, independent of the caller's altitude (WATER2 water-info bake).
## Uses the same footprint/gap/flow logic as gameplay queries and invalidates the scratch cache afterwards.
func nearest_interaction_point(pos: Vector3) -> Dictionary:
	var xz := Vector2(pos.x,pos.z)
	var info := interaction_info_at(xz)
	if not info.is_empty():
		var point := Vector3(pos.x,info.height,pos.z)
		return {position=point,distance=pos.distance_to(point)}
	var q := _inv*pos
	var local := Vector2(q.x,q.z)
	var candidates := PackedVector2Array()
	if kind==Kind.LAKE:
		# Find actual polygon edges, including concave shores. A clamped AABB
		# corner is frequently dry and misses nearby land-side explosions.
		for i in _poly.size():
			var a := _poly[i]
			var b := _poly[(i+1)%_poly.size()]
			var edge := b-a
			if edge.length_squared()<0.000001: continue
			var t := clampf((local-a).dot(edge)/edge.length_squared(),0.001,0.999)
			var nearest := a+edge*t
			var inset := Vector2(-edge.y,edge.x).normalized()*0.02
			candidates.append(nearest+inset)
			candidates.append(nearest-inset)
	else:
		for i in maxi(0,_rp.size()-1):
			if _rok[i]==0: continue
			var a := Vector2(_rp[i].x,_rp[i].z)
			var b := Vector2(_rp[i+1].x,_rp[i+1].z)
			var edge := b-a
			var t := clampf((local-a).dot(edge)/maxf(edge.length_squared(),0.000001),0,1)
			var center := a.lerp(b,t)
			var offset := local-center
			candidates.append(center+offset.limit_length(maxf(0.0,lerpf(_rhw[i],_rhw[i+1],t)-0.02)))
	var best := {}
	var distance := INF
	for candidate in candidates:
		var world := _xf*Vector3(candidate.x,0,candidate.y)
		info=interaction_info_at(Vector2(world.x,world.z))
		if info.is_empty(): continue
		world.y=info.height
		var d := pos.distance_to(world)
		if d<distance:
			distance=d
			best={position=world,distance=d}
	return best

func interaction_info_at(xz: Vector2) -> Dictionary:
	var pos := Vector3(xz.x, level if kind == Kind.LAKE else world_box.get_center().y, xz.y)
	_query(pos)
	if not is_finite(_q_h):
		_q_pos = Vector3.INF
		return {}
	pos.y = _q_h
	_query(pos)
	var result := {}
	if _q_in:
		var dep := max_depth
		if kind == Kind.RIVER:
			var i := clampi(_rs.bsearch(_q_s)-1,0,_rs.size()-2)
			var t := clampf((_q_s-_rs[i])/maxf(_rs[i+1]-_rs[i],0.001),0,1)
			dep = lerpf(_rdep[i],_rdep[i+1],t)
		result = {height=_q_h, depth=dep, flow=_q_v}
	_q_pos = Vector3.INF
	return result

## Water depth at pos (m below the surface, negative above it).
func depth_at(pos: Vector3) -> float:
	return height_at(pos) - pos.y

## River: (arc length from the source of the nearest centre-line point, signed lateral offset; + = right bank looking
## downstream). Works anywhere near the river, not only on the water.
func river_progress(pos: Vector3) -> Vector2:
	if kind != Kind.RIVER or _rp.size() < 2:
		return Vector2.ZERO
	if pos != _q_pos:
		_query(pos)
	if _q_h > -INF:
		return Vector2(_q_s, _q_lat)
	var q := _inv * pos
	var k := _nearest_sample(q)
	if k < 0:
		return Vector2.ZERO
	var a := _ra[k]
	return Vector2(_rs[k], (q - _rp[k]).dot(Vector3(-a.y, 0.0, a.x)))

func river_length() -> float:
	return _rs[_rs.size() - 1] if _rs.size() > 0 else 0.0

## River: world position of the centre line at arc length s.
func river_point(s: float) -> Vector3:
	if _rs.is_empty():
		return global_position
	var k := clampi(_rs.bsearch(s) - 1, 0, maxi(_rs.size() - 2, 0))
	var t := clampf((s - _rs[k]) / maxf(_rs[k + 1] - _rs[k], 1e-4), 0.0, 1.0) if _rs.size() > 1 else 0.0
	return _xf * _rp[k].lerp(_rp[mini(k + 1, _rp.size() - 1)], t)

## River: how rough the water is at pos (0 calm .. 1 white water): steep stretches, the base of steps, below
## waterfalls, boulder wakes. Uses the nearest centre-line point, so it also answers on the bank (for audio).
## Lakes: 0.
func turbulence_at(pos: Vector3) -> float:
	if kind != Kind.RIVER or _rs.size() < 2:
		return 0.0
	var q := _inv * pos
	var k := _nearest_sample(q)
	if k < 0:
		return 0.0
	var a := _ra[k]
	var lat := clampf((q - _rp[k]).dot(Vector3(-a.y, 0.0, a.x)), -_rhw[k], _rhw[k])
	return clampf(_rwhite[k] * (1.0 - smoothstep(0.7, 1.0, absf(lat / _rhw[k]))) + _boulder_at(_rs[k], lat).x * 0.6, 0.0, 1.0)

## River: the roughest water within `radius` metres of pos. Returns {position: Vector3 (world, on the surface),
## strength: 0..1 (white water x how close), turbulence: 0..1, flow_speed: m/s, distance: m}, or {} when nothing
## rough is in range. Meant for audio emitters (place a rapids loop at `position`, scale it by `strength`).
func rapids_near(pos: Vector3, radius := 40.0) -> Dictionary:
	if kind != Kind.RIVER or _rs.size() < 2:
		return {}
	var q := _inv * pos
	var k0 := _nearest_sample(q)
	if k0 < 0:
		return {}
	var step := maxf(_rs[1] - _rs[0], 0.1)
	var span := int(radius / step) + 1
	var best := 0.0
	var bk := -1
	var bd := 0.0
	for k in range(maxi(k0 - span, 0), mini(k0 + span, _rp.size() - 1) + 1, 2):
		var w := _rwhite[k]
		if w < 0.05:
			continue
		var p := _rp[k]
		var d := Vector3(p.x - q.x, p.y - q.y, p.z - q.z).length()
		if d > radius:
			continue
		var sc := w * (1.0 - d / radius)
		if sc > best:
			best = sc
			bk = k
			bd = d
	if bk < 0:
		return {}
	return {"position": _xf * _rp[bk], "strength": best, "turbulence": _rwhite[bk], "flow_speed": _rspd[bk], "distance": bd}

## River: surface current speed (m/s) at the nearest centre-line point (lakes: 0).
func flow_speed_at(pos: Vector3) -> float:
	if kind != Kind.RIVER or _rs.size() < 2:
		return 0.0
	var k := _nearest_sample(_inv * pos)
	return _rspd[k] if k >= 0 else 0.0

## River: the stretches too steep to draw as a surface (gaps), which a Waterfall should bridge. Each entry:
## {top: Vector3, bottom: Vector3 (world, water surface at the lip and at the foot), path: PackedVector3Array (world
## centre line from the lip to the foot), width: m, drop: m, speed: m/s at the lip, s: arc length of the lip}.
func gap_spans(min_drop := -1.0) -> Array[Dictionary]:
	if min_drop < 0.0:
		min_drop = min_gap_drop
	var out: Array[Dictionary] = []
	var n := _rp.size()
	var k := 0
	while k < n - 1:
		if _rok[k] == 1:
			k += 1
			continue
		var k0 := k
		while k < n - 1 and _rok[k] == 0:
			k += 1
		var k1 := k # first sample after the gap
		var top := _rp[k0]
		var bot := _rp[k1]
		if top.y - bot.y >= min_drop:
			var path := PackedVector3Array()
			for j in range(k0, k1 + 1):
				path.append(_xf * _rp[j])
			var w := 0.0
			for j in range(k0, k1 + 1):
				w = maxf(w, _rhw[j] * 2.0)
			out.append({"top": _xf * top, "bottom": _xf * bot, "path": path, "width": w, "drop": top.y - bot.y,
				"speed": _rspd[maxi(k0 - 1, 0)], "s": _rs[k0]})
	return out

func _query(pos: Vector3) -> void:
	_q_pos = pos
	_q_in = false
	_q_v = Vector3.ZERO
	_q_n = Vector3.UP
	if kind == Kind.LAKE:
		_q_h = level
		var q := _inv * pos
		if q.x < _bmin.x or q.x > _bmax.x or q.z < _bmin.y or q.z > _bmax.y:
			return
		if pos.y > level + 2.0 or pos.y < level - max_depth - 2.0:
			return
		var cx := int((q.x - _g_origin.x) / _g_cell)
		var cz := int((q.z - _g_origin.y) / _g_cell)
		if cx < 0 or cz < 0 or cx >= _g_w or cz >= _g_h:
			return
		var st := _g_state[cz * _g_w + cx]
		if st == 0:
			return
		if st == 2 and not Geometry2D.is_point_in_polygon(Vector2(q.x, q.z), _poly):
			return
		_q_in = true
		# A slight wind drift at the surface (floating leaves and boats creep downwind).
		var d := level - pos.y
		if d > -0.5:
			var wv: Vector2 = _env.get("wind_vec", Vector2.ZERO)
			var k := 0.012 * exp(-maxf(d, 0.0) / 0.6)
			_q_v = Vector3(wv.x * k, 0.0, wv.y * k)
		return
	# River.
	_q_h = -INF
	var q := _inv * pos
	if q.x < _bmin.x or q.x > _bmax.x or q.z < _bmin.y or q.z > _bmax.y:
		return
	var cx := int((q.x - _g_origin.x) / _g_cell)
	var cz := int((q.z - _g_origin.y) / _g_cell)
	if cx < 0 or cz < 0 or cx >= _g_w or cz >= _g_h:
		return
	var c := cz * _g_w + cx
	var best := INF
	var bk := -1
	var bt := 0.0
	var btr := 0.0
	for i in range(_g_start[c], _g_start[c + 1]):
		var k := _g_items[i]
		var a := _Qp[k]
		var b := _Qp[k + 1]
		var dx := b.x - a.x
		var dz := b.z - a.z
		var tr := ((q.x - a.x) * dx + (q.z - a.z) * dz) * _Qinv2[k]
		var t := clampf(tr, 0.0, 1.0)
		var ex := a.x + dx * t - q.x
		var ez := a.z + dz * t - q.z
		var d2 := ex * ex + ez * ez
		if d2 < best:
			best = d2
			bk = k
			bt = t
			btr = tr
	if bk < 0:
		return
	var p0 := _Qp[bk]
	var p1 := _Qp[bk + 1]
	var h := lerpf(p0.y, p1.y, bt)
	var a2 := _Qa[bk].lerp(_Qa[bk + 1], bt).normalized()
	var px := lerpf(p0.x, p1.x, bt)
	var pz := lerpf(p0.z, p1.z, bt)
	var lat := (q.x - px) * -a2.y + (q.z - pz) * a2.x
	var hw := lerpf(_Qhw[bk], _Qhw[bk + 1], bt)
	var slope := lerpf(_Qsl[bk], _Qsl[bk + 1], bt)
	var dep := lerpf(_Qdep[bk], _Qdep[bk + 1], bt)
	var yoff := _xf.origin.y
	_q_h = h + yoff
	_q_s = lerpf(_Qs[bk], _Qs[bk + 1], bt)
	_q_lat = lat
	var basis := _xf.basis
	_q_n = basis * Vector3(a2.x * slope, 1.0, a2.y * slope).normalized()
	# Cut the ends square (no half-disc of water past the mouth or over a waterfall lip).
	var last := _Qp.size() - 2
	if btr < 0.0 and (bk == 0 or _Qok[bk - 1] == 0):
		return
	if btr > 1.0 and (bk == last or _Qok[bk + 1] == 0):
		return
	if _Qok[bk] == 0 or absf(lat) > hw:
		return
	var depth_below := _q_h - pos.y
	if depth_below < -2.0 or depth_below > dep + 3.0:
		return
	_q_in = true
	# Full-resolution sample (standing waves, boulders and the current profile are resolved per metre).
	var kf := clampi(_rs.bsearch(_q_s) - 1, 0, _rs.size() - 2)
	var tf := clampf((_q_s - _rs[kf]) / maxf(_rs[kf + 1] - _rs[kf], 1e-4), 0.0, 1.0)
	var kn := kf if tf < 0.5 else kf + 1
	_q_h += _wave_height(kf, tf, lat, _q_s, float(_env.get("time", 0.0)))
	depth_below = _q_h - pos.y
	var fall := clampf(1.0 - 0.6 * maxf(depth_below, 0.0) / maxf(dep, 0.5), 0.3, 1.0)
	var fl := _flow_at(kn, lat)
	var side3 := Vector3(-a2.y, 0.0, a2.x)
	_q_v = basis * ((Vector3(a2.x, -slope, a2.y).normalized() * fl.y + side3 * fl.x) * fall)

## Surface displacement (m) of the river mesh at sample kf (+ fraction tf), lateral x, arc s, time t: the standing
## waves and boulder pillows the shader draws (water_body.gdshader river_wave()). Evaluated at the point (the mesh
## interpolates it over ~1 m triangles: the drawn surface differs by a couple of centimetres at most).
func _wave_height(kf: int, tf: float, x: float, s: float, t: float) -> float:
	var hw := lerpf(_rhw[kf], _rhw[kf + 1], tf)
	var edge := 1.0 - smoothstep(0.7, 1.0, absf(x / hw))
	if edge <= 0.0:
		return 0.0
	var amp := lerpf(_ramp[kf], _ramp[kf + 1], tf)
	var ph := lerpf(_rphase[kf], _rphase[kf + 1], tf)
	var w := sin(ph + 2.2 * sin(0.35 * x + 0.09 * s)) * (0.55 + 0.45 * sin(0.7 * x + 0.2 * s + 1.7)) + 0.3 * sin(ph * 1.63 - 0.9 * x + t * 1.7)
	var bump := _boulder_at(s, x).z if not _boulders.is_empty() else 0.0
	return (amp * w + bump) * edge

func _nearest_sample(q: Vector3) -> int:
	var best := INF
	var bk := -1
	var n := _rp.size()
	var stride := 1 if n < 400 else 2
	for k in range(0, n, stride):
		var p := _rp[k]
		var d := (p.x - q.x) * (p.x - q.x) + (p.z - q.z) * (p.z - q.z)
		if d < best:
			best = d
			bk = k
	return bk

# --- lake ------------------------------------------------------------------------------------------------

func _lake_polygon() -> PackedVector2Array:
	if polygon.size() >= 3:
		return polygon
	var out := PackedVector2Array()
	var n := clampi(int(radius * 0.8), 24, 128)
	for i in n:
		var a := TAU * i / n
		out.append(Vector2(cos(a), sin(a)) * radius)
	return out

func _build_lake() -> void:
	_poly = _lake_polygon()
	var grown := _grow(_poly, bank_margin)
	var bb := Rect2(grown[0], Vector2.ZERO)
	for p in grown:
		bb = bb.expand(p)
	var pb := Rect2(_poly[0], Vector2.ZERO)
	for p in _poly:
		pb = pb.expand(p)
	_bmin = pb.position
	_bmax = pb.end
	_build_lake_grid(pb)
	_queue_meshes(_lake_mesh.bind(grown, bb))

## Lake surface mesh arrays (worker thread): a grid over the grown shoreline, boundary cells clipped exactly.
func _lake_mesh(grown: PackedVector2Array, bb: Rect2) -> Array:
	var sp := maxf(mesh_spacing, sqrt(bb.get_area() / 30000.0))
	var nx := int(ceil(bb.size.x / sp))
	var nz := int(ceil(bb.size.y / sp))
	var y := level - _xf.origin.y
	# Corner inside flags.
	var inside := PackedByteArray()
	inside.resize((nx + 1) * (nz + 1))
	for j in nz + 1:
		for i in nx + 1:
			inside[j * (nx + 1) + i] = 1 if Geometry2D.is_point_in_polygon(bb.position + Vector2(i, j) * sp, grown) else 0
	# Cells the shoreline passes through are clipped against it exactly.
	var boundary := PackedByteArray()
	boundary.resize(nx * nz)
	var n := grown.size()
	for e in n:
		var a := grown[e]
		var b := grown[(e + 1) % n]
		var steps := int(ceil(a.distance_to(b) / (sp * 0.25))) + 1
		for s in steps + 1:
			var p := a.lerp(b, float(s) / steps)
			var ci := clampi(int((p.x - bb.position.x) / sp), 0, nx - 1)
			var cj := clampi(int((p.y - bb.position.y) / sp), 0, nz - 1)
			for oj in range(-1, 2):
				for oi in range(-1, 2):
					var ii := ci + oi
					var jj := cj + oj
					if ii >= 0 and jj >= 0 and ii < nx and jj < nz:
						# Only neighbours the point is really close to (within a quarter cell).
						var cmin := bb.position + Vector2(ii, jj) * sp
						if p.x >= cmin.x - sp * 0.05 and p.x <= cmin.x + sp * 1.05 and p.y >= cmin.y - sp * 0.05 and p.y <= cmin.y + sp * 1.05:
							boundary[jj * nx + ii] = 1
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	var corner_vi := PackedInt32Array()
	corner_vi.resize((nx + 1) * (nz + 1))
	corner_vi.fill(-1)
	for j in nz:
		for i in nx:
			var cmin := bb.position + Vector2(i, j) * sp
			if boundary[j * nx + i]:
				var cell := PackedVector2Array([cmin, cmin + Vector2(sp, 0), cmin + Vector2(sp, sp), cmin + Vector2(0, sp)])
				for piece: PackedVector2Array in Geometry2D.intersect_polygons(cell, grown):
					var tri := Geometry2D.triangulate_polygon(piece)
					var base := verts.size()
					for p in piece:
						verts.append(Vector3(p.x, y, p.y))
					for t in tri:
						idx.append(base + t)
				continue
			var c00 := j * (nx + 1) + i
			var cs := [c00, c00 + 1, c00 + nx + 2, c00 + nx + 1]
			var all_in := true
			for c: int in cs:
				all_in = all_in and inside[c] == 1
			if not all_in:
				continue
			var vi: Array[int] = []
			for c: int in cs:
				if corner_vi[c] < 0:
					var ci := c % (nx + 1)
					var cj := floori(float(c) / (nx + 1))
					var p := bb.position + Vector2(ci, cj) * sp
					corner_vi[c] = verts.size()
					verts.append(Vector3(p.x, y, p.y))
				vi.append(corner_vi[c])
			idx.append_array([vi[0], vi[1], vi[2], vi[0], vi[2], vi[3]])
	if verts.is_empty():
		return []
	_fix_winding(verts, idx)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	var nv := verts.size()
	var normals := PackedVector3Array()
	normals.resize(nv)
	normals.fill(Vector3.UP)
	var colors := PackedColorArray()
	colors.resize(nv)
	colors.fill(Color(0.5, 1.0, 0.0, 1.0))
	var uv2 := PackedVector2Array()
	uv2.resize(nv)
	uv2.fill(Vector2.ZERO)
	# Tangents: (1, 0, 0, 1) per vertex, doubled up instead of appended one by one.
	var tangents := PackedFloat32Array([1.0, 0.0, 0.0, 1.0])
	while tangents.size() < nv * 4:
		tangents.append_array(tangents.slice(0, mini(tangents.size(), nv * 4 - tangents.size())))
	var uv := PackedVector2Array()
	uv.resize(nv)
	for i in nv:
		var v := verts[i]
		uv[i] = Vector2(v.x, v.z)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = idx
	return [["Surface", arrays, 0]]

static func _area(p: PackedVector2Array) -> float:
	var a := 0.0
	for i in p.size():
		var b := p[(i + 1) % p.size()]
		a += p[i].x * b.y - b.x * p[i].y
	return a * 0.5

## Offsets a polygon outward by d (whatever its winding), keeping the biggest piece.
static func _grow(p: PackedVector2Array, d: float) -> PackedVector2Array:
	if d <= 0.0:
		return p
	var best := p
	var best_a := absf(_area(p))
	for sgn in [1.0, -1.0]:
		for q: PackedVector2Array in Geometry2D.offset_polygon(p, d * sgn):
			var a := absf(_area(q))
			if a > best_a:
				best = q
				best_a = a
	return best

## Godot's front faces are clockwise seen from the front (+Y here): flip triangles that face down.
static func _fix_winding(verts: PackedVector3Array, idx: PackedInt32Array) -> void:
	for t in range(0, idx.size(), 3):
		var a := verts[idx[t]]
		var b := verts[idx[t + 1]]
		var c := verts[idx[t + 2]]
		var ny := (b - a).cross(c - a).y
		if ny > 0.0:
			var tmp := idx[t + 1]
			idx[t + 1] = idx[t + 2]
			idx[t + 2] = tmp

func _build_lake_grid(pb: Rect2) -> void:
	_g_cell = clampf(maxf(pb.size.x, pb.size.y) / 96.0, 2.0, 16.0)
	_g_origin = pb.position
	_g_w = int(ceil(pb.size.x / _g_cell)) + 1
	_g_h = int(ceil(pb.size.y / _g_cell)) + 1
	_g_state.resize(_g_w * _g_h)
	_g_state.fill(0)
	var n := _poly.size()
	# Distance from each cell centre to the shoreline decides: far inside / far outside / near the edge. Only the
	# cells around an edge's box can be within r of it, so each edge marks those (same result as testing every cell
	# against every edge, without the cells x edges loop).
	var half_diag := _g_cell * 0.7072
	var r2 := half_diag * half_diag * 1.05
	var r := sqrt(r2)
	for e in n:
		var a := _poly[e]
		var b := _poly[(e + 1) % n]
		var i0 := maxi(floori((minf(a.x, b.x) - r - _g_origin.x) / _g_cell - 0.5), 0)
		var i1 := mini(ceili((maxf(a.x, b.x) + r - _g_origin.x) / _g_cell - 0.5), _g_w - 1)
		var j0 := maxi(floori((minf(a.y, b.y) - r - _g_origin.y) / _g_cell - 0.5), 0)
		var j1 := mini(ceili((maxf(a.y, b.y) + r - _g_origin.y) / _g_cell - 0.5), _g_h - 1)
		for j in range(j0, j1 + 1):
			for i in range(i0, i1 + 1):
				var k := j * _g_w + i
				if _g_state[k] == 2:
					continue
				var c := _g_origin + Vector2(i + 0.5, j + 0.5) * _g_cell
				if Geometry2D.get_closest_point_to_segment(c, a, b).distance_squared_to(c) <= r2:
					_g_state[k] = 2
	for j in _g_h:
		for i in _g_w:
			var k := j * _g_w + i
			if _g_state[k] != 2:
				var c := _g_origin + Vector2(i + 0.5, j + 0.5) * _g_cell
				_g_state[k] = 1 if Geometry2D.is_point_in_polygon(c, _poly) else 0

# --- river -----------------------------------------------------------------------------------------------

func _build_river() -> void:
	_rp.clear(); _ra.clear(); _rhw.clear(); _rspd.clear(); _rdep.clear(); _rslope.clear(); _rs.clear(); _rok.clear(); _rinv2.clear()
	if curve == null or curve.point_count < 2:
		return
	var total := curve.get_baked_length()
	if total < 1.0:
		return
	# Arc length of every control point (per-point arrays interpolate between them).
	var cp_s := PackedFloat32Array()
	for i in curve.point_count:
		cp_s.append(curve.get_closest_offset(curve.get_point_position(i)))
	var step := clampf(mesh_spacing * 0.5, 0.75, 2.0)
	var n := int(ceil(total / step)) + 1
	for k in n:
		var s := minf(k * step, total)
		_rs.append(s)
		_rp.append(curve.sample_baked(s, true))
	for k in n:
		var a := _rp[maxi(k - 1, 0)]
		var b := _rp[mini(k + 1, n - 1)]
		var d := Vector2(b.x - a.x, b.z - a.z)
		_ra.append(d.normalized() if d.length_squared() > 1e-8 else (_ra[k - 1] if k > 0 else Vector2(0, 1)))
	# Slope (drop per horizontal metre), smoothed over a few metres; steep stretches are gaps (waterfalls).
	var raw := PackedFloat32Array()
	raw.resize(n)
	for k in n:
		var a := _rp[maxi(k - 1, 0)]
		var b := _rp[mini(k + 1, n - 1)]
		raw[k] = (a.y - b.y) / maxf(Vector2(b.x - a.x, b.z - a.z).length(), 0.05)
	var win := maxi(int(3.0 / step), 1)
	for k in n:
		var acc := 0.0
		var cnt := 0
		for o in range(-win, win + 1):
			var kk := clampi(k + o, 0, n - 1)
			if raw[kk] <= max_slope:
				acc += raw[kk]
				cnt += 1
		_rslope.append(maxf(acc / maxi(cnt, 1), 0.0) if raw[k] <= max_slope else raw[k])
	_rsteep.clear()
	var win2 := maxi(int(10.0 / step), 1)
	for k in n:
		var acc := 0.0
		var wsum := 0.0
		for o in range(-win2, win2 + 1):
			var kk := clampi(k + o, 0, n - 1)
			var w := 1.0 - absf(float(o)) / (win2 + 1)
			acc += minf(_rslope[kk], max_slope) * w
			wsum += w
		_rsteep.append(smoothstep(0.02, 0.17, acc / wsum))
	for k in n:
		var s := _rs[k]
		var u := s / total
		var w := _per_point(point_widths, cp_s, s, width) * (width_curve.sample(u) if width_curve else 1.0)
		var sl := minf(_rslope[k], max_slope)
		var f := _per_point(point_flows, cp_s, s, flow_speed) * (flow_curve.sample(u) if flow_curve else 1.0)
		f = minf(f * (1.0 + slope_speedup * sl), max_flow_speed)
		_rhw.append(maxf(w * 0.5, 0.25))
		_rspd.append(f)
		_rdep.append(_per_point(point_depths, cp_s, s, depth))
	for k in n - 1:
		var a := _rp[k]
		var b := _rp[k + 1]
		var h := Vector2(b.x - a.x, b.z - a.z).length()
		_rok.append(1 if (a.y - b.y) / maxf(h, 0.05) <= max_slope else 0)
		_rinv2.append(1.0 / maxf(h * h, 1e-6))
	_rok.append(0)
	_tidy_gaps()
	_analyse_river(step)
	_build_river_grid()
	_build_river_mesh(total)

## Gaps (stretches too steep to draw) get a Waterfall. Short bits of water between two gaps join the cascade (no 2 m
## puddles hanging on a cliff), and gaps that drop less than `min_gap_drop` are drawn as steep river instead of a hole.
func _tidy_gaps() -> void:
	var n := _rp.size()
	var runs: Array[Vector3i] = [] # (start, end exclusive, ok)
	var k := 0
	while k < n - 1:
		var ok := _rok[k]
		var k0 := k
		while k < n - 1 and _rok[k] == ok:
			k += 1
		runs.append(Vector3i(k0, k, ok))
	for i in range(1, runs.size() - 1):
		var r := runs[i]
		if r.z == 1 and _rs[r.y] - _rs[r.x] < 6.0:
			for j in range(r.x, r.y):
				_rok[j] = 0
	k = 0
	while k < n - 1:
		if _rok[k] == 1:
			k += 1
			continue
		var k0 := k
		while k < n - 1 and _rok[k] == 0:
			k += 1
		if _rp[k0].y - _rp[k].y < min_gap_drop:
			for j in range(k0, k):
				_rok[j] = 1

## Per-sample hydraulics for the look and the queries: bend curvature, eddies behind bends, white water on steep
## stretches, hydraulic jumps where the slope eases off (the base of every step), a glassy accelerating tongue before
## every drop, foam that persists downstream of all of these, standing waves (amplitude, wavelength 2 pi v^2 / g,
## integrated phase) and submerged boulders.
func _analyse_river(step: float) -> void:
	var n := _rp.size()
	_rkap.resize(n); _rwhite.resize(n); _rtrail.resize(n); _rjump.resize(n); _rlip.resize(n); _ramp.resize(n)
	_rphase.resize(n); _rkw.resize(n); _reddy.resize(n); _rdhw.resize(n)
	# Signed curvature (+ = bending towards the + lateral side), smoothed over about a channel width.
	var kraw := PackedFloat32Array()
	kraw.resize(n)
	for k in n:
		var ap := _ra[maxi(k - 2, 0)]
		var an := _ra[mini(k + 2, n - 1)]
		var ds := maxf(_rs[mini(k + 2, n - 1)] - _rs[maxi(k - 2, 0)], 0.1)
		kraw[k] = (ap.x * an.y - ap.y * an.x) / ds
	for k in n:
		var w := maxi(int(_rhw[k] / step), 1)
		var acc := 0.0
		for o in range(-w, w + 1):
			acc += kraw[clampi(k + o, 0, n - 1)]
		_rkap[k] = acc / (2 * w + 1)
	# Distance to the next gap (a waterfall or cascade) downstream, and whether a gap ended just upstream.
	var to_gap := PackedFloat32Array()
	to_gap.resize(n)
	var next_gap := _rs[n - 1] if end_lip else INF
	for k in range(n - 1, -1, -1):
		if k < n - 1 and _rok[k] == 0 and (k == 0 or _rok[k - 1] == 1):
			next_gap = _rs[k]
		to_gap[k] = next_gap - _rs[k]
	var since_gap := INF
	var sl := PackedFloat32Array()
	sl.resize(n)
	for k in n:
		sl[k] = minf(_rslope[k], max_slope) if (k < n - 1 and _rok[k] == 1) or (k > 0 and _rok[k - 1] == 1) else 0.0
	var w2 := maxi(int(2.5 / step), 1)
	# Mean depth over ~60 m (riffles are the shallow parts of a reach).
	var mean_dep := PackedFloat32Array()
	mean_dep.resize(n)
	var wd := maxi(int(30.0 / step), 1)
	var csum := PackedFloat64Array()
	csum.resize(n + 1)
	for k in n:
		csum[k + 1] = csum[k] + _rdep[k]
	for k in n:
		var a := maxi(k - wd, 0)
		var b := mini(k + wd + 1, n)
		mean_dep[k] = (csum[b] - csum[a]) / (b - a)
	var decay_eddy := 0.0
	var eddy_side := 1.0
	var trail := source_foam
	var phase := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(String(name)) ^ 0x51f0
	_boulders.clear()
	var next_boulder := rng.randf_range(4.0, 14.0)
	for k in n:
		var s := _rs[k]
		if k > 0 and _rok[k - 1] == 0 and _rok[k] == 1:
			since_gap = 0.0
		elif k > 0:
			since_gap += _rs[k] - _rs[k - 1]
		var up := sl[maxi(k - w2, 0)]
		var dn := sl[mini(k + w2, n - 1)]
		var steep := smoothstep(0.03, 0.22, sl[k])
		# Tongue: the slope is about to increase (or a drop is near): smooth, glassy, accelerating water.
		var lip := maxf(smoothstep(0.02, 0.15, dn - up) * (1.0 - smoothstep(0.1, 0.3, sl[k])), 1.0 - smoothstep(1.0, 7.0, to_gap[k]))
		# Hydraulic jump: the slope eases off (the base of a step), or just below a waterfall / cascade.
		var jump := maxf(smoothstep(0.03, 0.18, up - dn), 1.0 - smoothstep(2.0, 12.0 + _rhw[k], since_gap))
		var fast := smoothstep(2.2, 4.5, _rspd[k])
		# Riffles: where the bed is shallower than the reach around it the water breaks into choppy, flecked runs.
		var riffle := clampf(1.0 - _rdep[k] / maxf(mean_dep[k], 0.1), 0.0, 0.6) / 0.6
		var white := clampf(maxf(steep * (1.0 - lip * 0.8), jump) + fast * 0.25 + riffle * 0.28 * (1.0 - lip), 0.0, 1.0)
		_rwhite[k] = white
		_rjump[k] = jump
		_rlip[k] = lip
		# Foam carried downstream: decays over tens of metres (longer in fast water).
		var L := 18.0 + 9.0 * _rspd[k]
		trail = maxf(white, trail * exp(-step / L))
		_rtrail[k] = trail
		# Standing waves: wavelength of a wave that stands still in a current of speed v (c = v -> k = g / v^2).
		var v := maxf(_rspd[k], 0.3)
		var lam := clampf(TAU * v * v / 9.81, 3.0, 9.0)
		_rkw[k] = TAU / lam
		phase += TAU / lam * step
		_rphase[k] = phase
		var narrow := clampf(_rhw[k] / 3.0, 0.35, 1.0)
		_ramp[k] = (0.01 + 0.13 * steep * (1.0 - lip) + 0.1 * jump + 0.03 * fast + 0.03 * riffle) * narrow * waves
		# Eddies on the inner bank just downstream of a bend (the flow separates there and turns back).
		var b := _rkap[k] * _rhw[k]
		decay_eddy *= exp(-step / maxf(_rhw[k] * 3.0, 4.0))
		if absf(b) > decay_eddy:
			decay_eddy = absf(b)
			eddy_side = signf(b) if absf(b) > 0.02 else eddy_side
		_reddy[k] = clampf((decay_eddy - absf(b) * 0.7) * 5.0 - 0.2, 0.0, 1.0) * eddy_side
		var hn := _rhw[mini(k + 1, n - 1)]
		var hp := _rhw[maxi(k - 1, 0)]
		_rdhw[k] = (hn - hp) / maxf(_rs[mini(k + 1, n - 1)] - _rs[maxi(k - 1, 0)], 0.1)
		# Boulders under the surface: more of them on steep stretches; each one makes a pillow and a V of foam.
		if s >= next_boulder and _rok[mini(k, n - 2)] == 1 and boulders > 0.0:
			var r := rng.randf_range(0.3, 0.8) * clampf(_rhw[k] / 4.0, 0.5, 1.2)
			_boulders.append(Vector4(s, rng.randf_range(-0.75, 0.75) * _rhw[k], r, 0.4 + 0.6 * maxf(steep, rng.randf() * 0.5)))
			next_boulder = s + rng.randf_range(5.0, 30.0) * lerpf(1.0, 0.3, steep) / boulders

## (m/s across, m/s along, eddy weight) of the surface current at lateral offset x (m) of sample k (UV space: per metre of centre
## line), plus the eddy weight (0..1). Faster in the middle, slow at the banks, the core pushed to the outer bank in
## bends, a back-flow in the eddy on the inner bank below a bend, spreading / converging where the channel widens.
func _flow_at(k: int, x: float) -> Vector3:
	var hw := _rhw[k]
	var xn := clampf(x / hw, -1.2, 1.2)
	var b := _rkap[k] * hw
	var c := -clampf(b * 1.3, -0.45, 0.45)
	var d := (xn - c) / (1.0 + absf(c))
	var prof := clampf(1.0 - d * d, 0.0, 1.0)
	var spd := _rspd[k]
	var v := spd * (0.22 + 0.78 * sqrt(prof))
	var e := _reddy[k]
	var ew := absf(e) * smoothstep(0.25, 0.8, xn * signf(e))
	v *= 1.0 - 1.45 * ew
	var u := -signf(e) * ew * spd * 0.3 + xn * _rdhw[k] * v
	return Vector3(u, v, ew)

func _per_point(arr: PackedFloat32Array, cp_s: PackedFloat32Array, s: float, fallback: float) -> float:
	if arr.size() != cp_s.size() or arr.is_empty():
		return fallback
	var i := clampi(cp_s.bsearch(s) - 1, 0, arr.size() - 1)
	if i >= arr.size() - 1:
		return arr[arr.size() - 1]
	var t := clampf((s - cp_s[i]) / maxf(cp_s[i + 1] - cp_s[i], 1e-4), 0.0, 1.0)
	return lerpf(arr[i], arr[i + 1], t)

func _build_river_grid() -> void:
	# Decimate: ~4 m query segments (a smooth centre line bends < 5 cm between them), keeping every gap boundary.
	_Qp.clear(); _Qa.clear(); _Qhw.clear(); _Qspd.clear(); _Qdep.clear(); _Qsl.clear(); _Qs.clear(); _Qok.clear(); _Qinv2.clear()
	var n := _rp.size()
	var keep: Array[int] = [0]
	for k in range(1, n):
		if k == n - 1 or _rs[k] - _rs[keep[keep.size() - 1]] >= 4.0 or _rok[k] != _rok[k - 1]:
			keep.append(k)
	for k in keep:
		_Qp.append(_rp[k]); _Qa.append(_ra[k]); _Qhw.append(_rhw[k]); _Qspd.append(_rspd[k]); _Qdep.append(_rdep[k])
		_Qsl.append(_rslope[k]); _Qs.append(_rs[k])
	for i in keep.size() - 1:
		var ok := 1
		for k in range(keep[i], keep[i + 1]):
			ok = ok & _rok[k]
		_Qok.append(ok)
		var a := _Qp[i]
		var b := _Qp[i + 1]
		_Qinv2.append(1.0 / maxf((b.x - a.x) * (b.x - a.x) + (b.z - a.z) * (b.z - a.z), 1e-6))
	_Qok.append(0)
	var m := _Qp.size()
	var maxhw := 0.0
	var bb := Rect2(Vector2(_Qp[0].x, _Qp[0].z), Vector2.ZERO)
	for k in m:
		bb = bb.expand(Vector2(_Qp[k].x, _Qp[k].z))
		maxhw = maxf(maxhw, _Qhw[k])
	bb = bb.grow(maxhw + 1.0)
	_bmin = bb.position
	_bmax = bb.end
	_g_cell = clampf(maxhw * 0.8, 2.5, 10.0)
	_g_origin = bb.position
	_g_w = int(ceil(bb.size.x / _g_cell)) + 1
	_g_h = int(ceil(bb.size.y / _g_cell)) + 1
	var lists := {}
	for k in m - 1:
		var a := _Qp[k]
		var b := _Qp[k + 1]
		var r := maxf(_Qhw[k], _Qhw[k + 1]) + 0.5
		var i0 := int((minf(a.x, b.x) - r - _g_origin.x) / _g_cell)
		var i1 := int((maxf(a.x, b.x) + r - _g_origin.x) / _g_cell)
		var j0 := int((minf(a.z, b.z) - r - _g_origin.y) / _g_cell)
		var j1 := int((maxf(a.z, b.z) + r - _g_origin.y) / _g_cell)
		for j in range(maxi(j0, 0), mini(j1, _g_h - 1) + 1):
			for i in range(maxi(i0, 0), mini(i1, _g_w - 1) + 1):
				var c := j * _g_w + i
				if not lists.has(c):
					lists[c] = PackedInt32Array()
				var l: PackedInt32Array = lists[c]
				l.append(k)
				lists[c] = l
	# Prune each cell's list to the segments that can be the nearest one somewhere in the cell: a segment whose
	# closest possible distance exceeds another segment's farthest distance (over the cell) never wins.
	var half_diag := _g_cell * 0.7072
	_g_start.resize(_g_w * _g_h + 1)
	_g_items.clear()
	for c in _g_w * _g_h:
		_g_start[c] = _g_items.size()
		if not lists.has(c):
			continue
		var l: PackedInt32Array = lists[c]
		var cmin := _g_origin + Vector2(c % _g_w, floori(float(c) / _g_w)) * _g_cell
		var centre := cmin + Vector2(_g_cell, _g_cell) * 0.5
		var corners := [cmin, cmin + Vector2(_g_cell, 0), cmin + Vector2(0, _g_cell), cmin + Vector2(_g_cell, _g_cell)]
		var lo := PackedFloat32Array()
		var best_hi := INF
		for k in l:
			var a := Vector2(_Qp[k].x, _Qp[k].z)
			var b := Vector2(_Qp[k + 1].x, _Qp[k + 1].z)
			var hi := 0.0
			for cc: Vector2 in corners:
				hi = maxf(hi, Geometry2D.get_closest_point_to_segment(cc, a, b).distance_to(cc))
			best_hi = minf(best_hi, hi)
			lo.append(maxf(Geometry2D.get_closest_point_to_segment(centre, a, b).distance_to(centre) - half_diag, 0.0))
		for i in l.size():
			var k := l[i]
			if lo[i] <= best_hi + 0.01 and lo[i] <= maxf(_Qhw[k], _Qhw[k + 1]) + 0.5:
				_g_items.append(k)
	_g_start[_g_w * _g_h] = _g_items.size()

## Boulder influence at (arc s, lateral x): Vector3(white water, foam lines, surface bump in m).
func _boulder_at(s: float, x: float) -> Vector3:
	if _boulders.is_empty():
		return Vector3.ZERO
	var out := Vector3.ZERO
	# Boulders are sorted by s; the influence reaches ~2 r upstream and ~14 r downstream (r <= ~1 m).
	var i := _boulder_lo(s - 16.0)
	while i < _boulders.size():
		var bd := _boulders[i]
		i += 1
		if bd.x > s + 2.5:
			break
		var r := bd.z
		var along := s - bd.x
		var lat := absf(x - bd.y)
		if along < -2.5 * r or along > 16.0 * r or lat > r * 3.5 + along * 0.3:
			continue
		var pu := (along + 0.6 * r) / r
		var pl := lat / r
		var pillow := exp(-pu * pu - pl * pl)
		var white := pillow * 0.7
		var line := 0.0
		if along > 0.0:
			var hwk := r * (0.8 + along * 0.2)
			var lw := r * 0.35 + along * 0.06
			var dl := (lat - hwk) / lw
			line = exp(-dl * dl) * exp(-along / (9.0 * r))
			var cl := lat / (0.9 * r)
			white = maxf(white, exp(-cl * cl) * exp(-along / (3.5 * r)))
		out += Vector3(white, line, pillow * 0.09) * bd.w
	return out

func _boulder_lo(s: float) -> int:
	var lo := 0
	var hi := _boulders.size()
	while lo < hi:
		var m := (lo + hi) >> 1
		if _boulders[m].x < s:
			lo = m + 1
		else:
			hi = m
	return lo

func _build_river_mesh(total: float) -> void:
	var n := _rp.size()
	var maxw := 0.0
	for k in n:
		maxw = maxf(maxw, _rhw[k] * 2.0)
	var cols := clampi(int(maxw / 1.1), 6, 26) # water columns
	_mesh_cols = cols
	_queue_meshes(_river_mesh.bind(cols, total))

## River surface mesh arrays (worker thread), in chunks of 96 samples.
func _river_mesh(cols: int, total: float) -> Array:
	var n := _rp.size()
	var out := []
	var chunk := 96
	var k0 := 0
	var part := 0
	while k0 < n - 1:
		var k1 := mini(k0 + chunk, n - 1)
		var arrays := _river_chunk(k0, k1, cols, total)
		if not arrays.is_empty():
			out.append(["Surface%d" % part, arrays,
					(Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) | (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)])
		part += 1
		k0 = k1
	return out

func _river_chunk(k0: int, k1: int, cols: int, total: float) -> Array:
	var cnt := (k1 - k0 + 1) * (cols + 3)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var tangents := PackedFloat32Array()
	var colors := PackedColorArray()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var c0 := PackedFloat32Array()
	var c1 := PackedFloat32Array()
	verts.resize(cnt); normals.resize(cnt); colors.resize(cnt); uv.resize(cnt); uv2.resize(cnt)
	tangents.resize(cnt * 4); c0.resize(cnt * 4); c1.resize(cnt * 4)
	var idx := PackedInt32Array()
	var row := cols + 3 # bank, water columns (cols + 1 lines), bank
	var vi := 0
	for k in range(k0, k1 + 1):
		var p := _rp[k]
		var a := _ra[k]
		var side := Vector3(-a.y, 0.0, a.x)
		var hw := _rhw[k]
		var s := _rs[k]
		# Signed curvature: the inner bank can't reach past the centre of the bend (no folded triangles).
		var ap := _ra[maxi(k - 2, 0)]
		var an := _ra[mini(k + 2, _rp.size() - 1)]
		var ds := maxf(_rs[mini(k + 2, _rp.size() - 1)] - _rs[maxi(k - 2, 0)], 0.1)
		var kappa := (ap.x * an.y - ap.y * an.x) / ds
		var lim_pos := 0.85 / kappa if kappa > 1e-4 else INF
		var lim_neg := -0.85 / -kappa if kappa < -1e-4 else -INF
		var fade := 1.0
		if fade_in > 0.0:
			fade *= smoothstep(0.0, fade_in, s)
		if fade_out > 0.0:
			fade *= smoothstep(0.0, fade_out, total - s)
		var e := _reddy[k]
		var bend_c := -clampf(_rkap[k] * hw * 1.3, -0.45, 0.45)
		for c in row:
			var x: float
			if c == 0:
				x = -hw - bank_margin
			elif c == row - 1:
				x = hw + bank_margin
			else:
				x = lerpf(-hw, hw, float(c - 1) / cols)
			x = clampf(x, lim_neg, lim_pos)
			var v := p + side * x
			if c == 0 or c == row - 1:
				v.y -= 0.25
			var xn := x / hw
			var fl := _flow_at(k, x)
			var bo := _boulder_at(s, x)
			var edge := 1.0 - smoothstep(0.7, 1.0, absf(xn))
			# Foam lines: the eddy fence, the convergence line along the core, boulder wakes.
			var xs := xn * signf(e)
			var dl := (xs - 0.35) / 0.13
			var line := absf(e) * exp(-dl * dl) + bo.y
			var dc := (xn - bend_c) / 0.22
			line += _rtrail[k] * 0.45 * exp(-dc * dc)
			verts[vi] = v
			normals[vi] = Vector3.UP
			tangents[vi * 4] = a.x
			tangents[vi * 4 + 1] = 0.0
			tangents[vi * 4 + 2] = a.y
			tangents[vi * 4 + 3] = 1.0
			colors[vi] = Color(0.5 + 0.5 * clampf(xn, -1.0, 1.0), fade, clampf(_rwhite[k] * edge + bo.x, 0.0, 1.0), _rtrail[k])
			uv[vi] = Vector2(x, s)
			# UV space: along the inner side of a bend a metre of centre line is less than a metre of water.
			uv2[vi] = Vector2(fl.x, fl.y / clampf(1.0 - _rkap[k] * x, 0.3, 3.0))
			c0[vi * 4] = _ramp[k] * edge
			c0[vi * 4 + 1] = _rjump[k]
			c0[vi * 4 + 2] = _rlip[k]
			c0[vi * 4 + 3] = clampf(line, 0.0, 1.0)
			c1[vi * 4] = _rphase[k]
			c1[vi * 4 + 1] = _rkw[k]
			c1[vi * 4 + 2] = bo.z * edge
			c1[vi * 4 + 3] = fl.z
			vi += 1
	for k in range(k0, k1):
		if _rok[k] == 0:
			continue
		var r0 := (k - k0) * row
		var r1 := r0 + row
		for c in row - 1:
			idx.append_array([r0 + c, r1 + c, r1 + c + 1, r0 + c, r1 + c + 1, r0 + c + 1])
	if idx.is_empty():
		return []
	_fix_winding(verts, idx)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_CUSTOM0] = c0
	arrays[Mesh.ARRAY_CUSTOM1] = c1
	arrays[Mesh.ARRAY_INDEX] = idx
	return arrays

# --- builders from world layout dictionaries -------------------------------------------------------------

static func _vec3(a) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))

## Lake from a `lakes[]` entry of world_layout.json. The node sits at the lake centre (y = 0); outline is world x/z.
static func lake_from_dict(d: Dictionary) -> WaterBody:
	var b := WaterBody.new()
	b.kind = Kind.LAKE
	b.name = String(d.get("id", "Lake"))
	var c: Vector3 = _vec3(d.get("center", [0, 0, 0]))
	b.position = Vector3(c.x, 0.0, c.z)
	b.level = float(d.get("level", c.y))
	b.max_depth = float(d.get("max_depth", 10.0))
	b.radius = float(d.get("radius", 20.0))
	var poly := PackedVector2Array()
	for p: Array in d.get("outline", []):
		poly.append(Vector2(float(p[0]) - c.x, float(p[1]) - c.z))
	b.polygon = poly
	return b

## River from a `rivers[]` entry of world_layout.json (points world, y = surface; per-point width/depth/flow).
static func river_from_dict(d: Dictionary) -> WaterBody:
	var b := WaterBody.new()
	b.kind = Kind.RIVER
	b.name = String(d.get("id", "River"))
	var pts: Array = d.get("points", [])
	if pts.is_empty():
		return b
	var ws: Array = d.get("width", [])
	var fs: Array = d.get("flow", [])
	var ds: Array = d.get("depth", [])
	var into := String(d.get("into", ""))
	if into == "sea" and pts.size() > 3:
		# The ocean takes over where the river surface reaches sea level (a river surface under the sea would show
		# through it as a sunken ribbon). Keep one point just below the sea for the fade.
		var sea := float(d.get("sea_level", 0.0))
		var cut := pts.size()
		for i in range(1, pts.size()):
			if float(pts[i][1]) <= sea + 0.05:
				cut = mini(i + 1, pts.size())
				break
		if cut < pts.size():
			pts = pts.slice(0, cut)
			ws = ws.slice(0, cut) if ws.size() > cut else ws
			fs = fs.slice(0, cut) if fs.size() > cut else fs
			ds = ds.slice(0, cut) if ds.size() > cut else ds
	var o := _vec3(pts[0])
	b.position = Vector3(o.x, 0.0, o.z)
	var local: Array[Vector3] = []
	for p in pts:
		var v := _vec3(p)
		local.append(Vector3(v.x - o.x, v.y, v.z - o.z))
	var cv := Curve3D.new()
	cv.bake_interval = 0.5
	for i in local.size():
		var prev := local[maxi(i - 1, 0)]
		var next := local[mini(i + 1, local.size() - 1)]
		var tan := (next - prev) * 0.25
		# Keep handles flat where the water drops steeply (no overshoot above the lip).
		tan.y = 0.0
		cv.add_point(local[i], -tan if i > 0 else Vector3.ZERO, tan if i < local.size() - 1 else Vector3.ZERO)
	b.curve = cv
	if ws.size() == pts.size():
		b.point_widths = PackedFloat32Array(ws)
	elif ws.size() == 1:
		b.width = float(ws[0])
	if fs.size() == pts.size():
		b.point_flows = PackedFloat32Array(fs)
		b.slope_speedup = 0.0 # the layout's flow already includes the slope
	if ds.size() == pts.size():
		b.point_depths = PackedFloat32Array(ds)
	b.source_foam = float(d.get("source_foam", 0.0))
	var w0 := float(ws[ws.size() - 1]) if not ws.is_empty() else b.width
	b.fade_out = float(d.get("fade_out", clampf(w0, 4.0, 20.0) if into != "" else 0.0))
	b.fade_in = float(d.get("fade_in", 0.0))
	return b

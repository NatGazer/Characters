@icon("res://Components/Water/buoyancy_icon.svg")
class_name Buoyancy extends Node
## Makes its parent RigidBody3D float on any water (FFT ocean, lakes, rivers) through Water.*.
##
## The body's volume is split between probe points (auto-generated from the collision shapes' bounding box, or set
## by hand). Every physics tick each probe gets Archimedes' force for the part of its slice that is under the local
## wave surface, plus drag against the moving water (so waves and currents carry things), applied at the probe:
## heave, pitch and roll come out of that naturally. Also: angular drag, splashes, entered/left signals.
##
##   var b := Buoyancy.new(); body.add_child(b)                # defaults work for crates, barrels, props
##   b.volume = 2.0; b.probes = [Vector3(0,-0.5,1.5), ...]    # hand-tuned hull

signal entered_water(impact_speed: float)
signal left_water

## Probe points in the body's local space. Empty = generate a grid from the collision shapes' AABB.
@export var probes: Array[Vector3] = []
## Probe grid used when generating (x, y, z).
@export var probe_grid := Vector3i(3, 2, 3)
## Displaced volume when fully submerged (m^3). 0 = AABB volume x `fill`.
@export var volume := 0.0
## Share of the AABB that is solid when the volume is automatic (box 1.0, barrel 0.78, hull 0.5..0.65).
@export_range(0.05, 1.0) var fill := 0.8
@export var water_density := 1025.0
@export var buoyancy_scale := 1.0
## Linear drag per second (mass-normalised) against the water, scaled by how submerged each probe is.
@export var drag := 1.2
## Extra drag on vertical motion (damps bobbing).
@export var vertical_drag := 1.6
## Quadratic drag coefficient x area (per probe share), for fast bodies.
@export var quadratic_drag := 0.6
## Angular drag per second (mass-normalised).
@export var angular_drag := 1.2
## How much the water's own motion (waves, currents) drags the body along.
@export_range(0.0, 1.0) var current_coupling := 1.0
## Negative selects automatically: small props couple, hulls >=300 kg ignore their own wakes.
@export_range(-1.0, 1.0) var wake_coupling := -1.0
## Spawn splash effects + sounds when hitting the water fast.
@export var splash := true

var body: RigidBody3D
## 0..1 share of the volume under water.
var submerged := 0.0
var in_water := false
var _slice_h := 0.5
var _probe_vol := 0.0
var _size := Vector3.ONE
var _splash_cool := 0.0
var _air_time := 10.0
var _dry_check := 0.0

## Every active Buoyancy (for systems that disturb the water, e.g. wakes and bow waves).
static var instances: Array[Buoyancy] = []
## Per-probe state from the last physics tick (world positions, 0..1 submersion, velocity relative to the water).
var probe_positions := PackedVector3Array()
var probe_submersion := PackedFloat32Array()
var probe_velocities := PackedVector3Array()

func _enter_tree() -> void:
	instances.append(self)

func _exit_tree() -> void:
	instances.erase(self)

func _ready() -> void:
	body = get_parent() as RigidBody3D
	if body == null:
		push_warning("Buoyancy must be a child of a RigidBody3D (%s)" % get_path())
		set_physics_process(false)
		return
	_setup()

## Recomputes probes and volume (call after changing shapes / exports at runtime).
func _setup() -> void:
	var aabb := _shapes_aabb()
	_size = aabb.size
	if probes.is_empty():
		var g := Vector3i(maxi(probe_grid.x, 1), maxi(probe_grid.y, 1), maxi(probe_grid.z, 1))
		for iy in g.y:
			for iz in g.z:
				for ix in g.x:
					var f := Vector3((ix + 0.5) / g.x, (iy + 0.5) / g.y, (iz + 0.5) / g.z)
					probes.append(aabb.position + aabb.size * f)
		_slice_h = aabb.size.y / g.y
	else:
		var ys := {}
		for p in probes:
			ys[snappedf(p.y, 0.01)] = true
		_slice_h = aabb.size.y / maxf(ys.size(), 1)
	var vol := volume if volume > 0.0 else aabb.size.x * aabb.size.y * aabb.size.z * fill
	_probe_vol = vol / probes.size()

func _shapes_aabb() -> AABB:
	var out := AABB()
	var first := true
	for c in body.get_children():
		var cs := c as CollisionShape3D
		if cs == null or cs.shape == null or cs.disabled:
			continue
		var m := cs.shape.get_debug_mesh()
		if m == null:
			continue
		var a := cs.transform * m.get_aabb()
		out = a if first else out.merge(a)
		first = false
	if first:
		out = AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	return out

func _physics_process(delta: float) -> void:
	_splash_cool = maxf(_splash_cool - delta, 0.0)
	if body.freeze:
		return
	# Asleep on dry ground: nothing moves it, so only look for water (a wave washing up, a rising river) 4 times a second.
	if body.sleeping and not in_water:
		_dry_check -= delta
		if _dry_check > 0.0:
			return
		_dry_check = 0.25
	var xf := body.global_transform
	var com := xf * body.center_of_mass if body.center_of_mass_mode == RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM else xf.origin
	var g := body.get_gravity().length()
	if g <= 0.0:
		g = 9.81
	var lin := body.linear_velocity
	var ang := body.angular_velocity
	var m_probe := body.mass / probes.size()
	var total := 0.0
	var area := (_size.x * _size.z) / maxf(float(probes.size()) / maxf(probe_grid.y, 1), 1.0)
	var n := probes.size()
	var wake_weight := 0.0
	if WaterInteraction.enabled:
		wake_weight = (1.0 if body.mass < 300.0 else 0.0) if wake_coupling < 0.0 else wake_coupling
	var use_wakes := wake_weight > 0.0
	if probe_positions.size() != n:
		probe_positions.resize(n)
		probe_submersion.resize(n)
		probe_velocities.resize(n)
	for i in n:
		var p := probes[i]
		var wp := xf * p
		probe_positions[i] = wp
		probe_submersion[i] = 0.0
		var water_probe_id := get_instance_id()*4096+i
		var bundled: Dictionary = {}
		var h: float
		var wake: Vector4
		if Water._detail_layers.is_empty():
			# Preserve the original no-detail path, including height-only dry probes.
			h=Water.height_at(wp,water_probe_id)
			if use_wakes: wake=WaterInteraction.sample(wp)*wake_weight
		else:
			if use_wakes: wake=WaterInteraction.sample(wp)*wake_weight
			# Flow is needed only when the body slice has positive submersion
			# AFTER adding its separately weighted fine-wake height.
			bundled=Water.sample_at(wp,water_probe_id,wp.y-_slice_h*0.5-wake.y)
			h=bundled.height
		if use_wakes: h+=wake.y
		if h == -INF:
			continue
		var depth := h - wp.y
		var s := clampf(depth / _slice_h + 0.5, 0.0, 1.0)
		if s <= 0.0:
			continue
		total += s
		var r := wp - xf.origin
		var f := Vector3.UP * (water_density * g * _probe_vol * s * buoyancy_scale)
		# Drag against the moving water.
		var pv := lin + ang.cross(r)
		var wv: Vector3 = (Water.velocity_at(wp,water_probe_id) if bundled.is_empty() else bundled.velocity)*current_coupling
		if use_wakes:
			wv.y += wake.w * current_coupling
		var rel := pv - wv
		probe_submersion[i] = s
		probe_velocities[i] = rel
		var lin_drag := -rel * drag * m_probe * s
		lin_drag.y -= rel.y * vertical_drag * m_probe * s
		var quad := -rel * rel.length() * quadratic_drag * 0.5 * water_density * area * s * 0.01
		f += lin_drag + quad
		body.apply_force(f, wp - xf.origin)
	submerged = total / probes.size()
	if submerged > 0.0:
		var r2 := (_size.x * _size.x + _size.y * _size.y + _size.z * _size.z) / 12.0
		body.apply_torque(-ang * angular_drag * body.mass * r2 * submerged)
		if body.sleeping:
			body.sleeping = false
	var now_in := submerged > (0.02 if not in_water else 0.005)
	if not in_water:
		_air_time += delta
	if now_in != in_water:
		in_water = now_in
		if in_water:
			var speed := -lin.y
			entered_water.emit(speed)
			Water.notify_entered_water(body, speed)
			# Only real drops make a splash (not a float bobbing out of a wave crest and back).
			if splash and speed > 2.5 and _air_time > 0.35 and _splash_cool <= 0.0:
				_splash_cool = 1.0
				var splash_height := Water.height_at(com)
				if not is_finite(splash_height):
					# A raised wake may wet a lower probe before the centre enters
					# the freshwater query volume. Never place an effect at -INF.
					for wp in probe_positions:
						var probe_height := Water.height_at(wp)
						if is_finite(probe_height):
							splash_height=probe_height
							break
				if is_finite(splash_height):
					WaterSplash.spawn(body,Vector3(com.x,splash_height,com.z),clampf(speed*body.mass/400.0,0.3,3.0))
		else:
			_air_time = 0.0
			left_water.emit()

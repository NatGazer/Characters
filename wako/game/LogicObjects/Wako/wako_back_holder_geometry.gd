extends RefCounted
## Finite geometry-derived load for the permanent ancient back holder.
## Exactly 2 kg is authored uniformly over its CURRENT material mesh solids.
## This is an authored finite distribution, not real bronze/stone density.
## SeatedContact sensor proxies are excluded. Never count them as material.
## Owner calls setup after _build_holder and default h=.12 local geometry;
## calls rebuild only after _sync_root changes the holder's half-width.
## Root orientation changes need no rebuild: holder_load reads the live frame.

const MASS := 2.0
const MATERIAL_MESH_COUNT := 11
static var _mesh_moments: Dictionary = {}
var _holder: Node3D
var _parts: Array[MeshInstance3D] = []
var _valid := false
var _com := Vector3.ZERO
var _inertia := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
var _bounds := AABB()

func setup(holder: Node3D) -> bool:
	_holder = holder
	_parts.clear()
	if not is_instance_valid(_holder): return false
	for child: Node in _holder.get_children():
		if child is MeshInstance3D and child.mesh: _parts.append(child)
	return rebuild()

func rebuild() -> bool:
	_valid = false
	if not is_instance_valid(_holder) or _parts.size() != MATERIAL_MESH_COUNT: return false
	var entries: Array[Dictionary] = []
	var total_volume := 0.0
	var weighted := Vector3.ZERO
	var have_bounds := false
	var bounds := AABB()
	for part: MeshInstance3D in _parts:
		if not is_instance_valid(part) or not part.mesh or part.get_parent() != _holder: return false
		var moments := _moments(part.mesh)
		if moments.is_empty(): return false
		var local := part.transform # No global/tree access during initialization.
		var determinant := local.basis.determinant()
		if not local.origin.is_finite() or not _finite(local.basis) or not is_finite(determinant) or absf(determinant) <= 1e-12: return false
		var volume := float(moments.volume) * absf(determinant)
		var at: Vector3 = local * Vector3(moments.com)
		var covariance: Basis = local.basis * Basis(moments.covariance) * local.basis.transposed()
		if not at.is_finite() or not _finite(covariance) or volume <= 0.0: return false
		entries.append({"volume": volume, "at": at, "covariance": covariance})
		total_volume += volume
		weighted += volume * at
		var material_bounds: AABB = local * AABB(moments.bounds)
		bounds = bounds.merge(material_bounds) if have_bounds else material_bounds
		have_bounds = true
	if not is_finite(total_volume) or total_volume <= 1e-12: return false
	var centre := weighted / total_volume
	if not centre.is_finite() or not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.grow(.00001).has_point(centre): return false
	var inertia := _zero()
	for entry: Dictionary in entries:
		var mass := MASS * float(entry.volume) / total_volume
		var covariance: Basis = entry.covariance
		var arm: Vector3 = Vector3(entry.at) - centre
		var own := _sub(_diagonal(Vector3.ONE * _trace(covariance)), covariance)
		var parallel := _sub(_diagonal(Vector3.ONE * arm.length_squared()), _outer(arm, arm))
		inertia = _add(inertia, _scale(_add(own, parallel), mass))
	if not _positive(inertia): return false
	_com = centre
	_inertia = inertia # About holder COM, expressed in holder LOCAL axes.
	_bounds = bounds # Actual material envelope; sensor proxies excluded.
	_valid = true
	return true

func holder_load() -> Dictionary:
	# Only this accessor reads global state. Teardown/out-of-tree callers get
	# no stale world coordinates; permanent base-mass accounting remains 24 kg.
	if not _valid or not is_instance_valid(_holder) or not _holder.is_inside_tree(): return {}
	var frame := _holder.global_transform
	if not frame.origin.is_finite() or not _finite(frame.basis): return {}
	return {"mass": MASS, "world_point": frame * _com, "frame": frame,
		"local_com": _com, "local_inertia": _inertia, "box": _bounds}

static func _moments(mesh: Mesh) -> Dictionary:
	var key := mesh.get_rid()
	if _mesh_moments.has(key): return _mesh_moments[key]
	var bounds := mesh.get_aabb()
	if not bounds.position.is_finite() or not bounds.size.is_finite() or minf(bounds.size.x, minf(bounds.size.y, bounds.size.z)) <= 0.0: return {}
	var reference := bounds.get_center()
	var signed_volume := 0.0
	var first := Vector3.ZERO
	var second := _zero()
	for surface: int in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		if arrays.size() != Mesh.ARRAY_MAX or arrays[Mesh.ARRAY_VERTEX] == null: return {}
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count := indices.size() if not indices.is_empty() else vertices.size()
		if count == 0 or count % 3 != 0: return {}
		for offset: int in range(0, count, 3):
			var ia := indices[offset] if not indices.is_empty() else offset
			var ib := indices[offset + 1] if not indices.is_empty() else offset + 1
			var ic := indices[offset + 2] if not indices.is_empty() else offset + 2
			if mini(ia, mini(ib, ic)) < 0 or maxi(ia, maxi(ib, ic)) >= vertices.size(): return {}
			var a := vertices[ia] - reference
			var b := vertices[ib] - reference
			var c := vertices[ic] - reference
			if not a.is_finite() or not b.is_finite() or not c.is_finite(): return {}
			var volume := a.dot(b.cross(c)) / 6.0
			var sum := a + b + c
			signed_volume += volume
			first += volume * sum / 4.0
			var q := _add(_outer(sum, sum), _add(_outer(a, a), _add(_outer(b, b), _outer(c, c))))
			second = _add(second, _scale(q, volume / 20.0))
	# Godot's clockwise triangle winding gives a negative integral. Divide all
	# signed moments by the SAME total, then use abs(volume) for mass weights.
	# Taking abs per triangle would give wrong moments for a concave mesh.
	if not is_finite(signed_volume) or absf(signed_volume) <= 1e-12: return {}
	var relative_com := first / signed_volume
	var covariance := _sub(_scale(second, 1.0 / signed_volume), _outer(relative_com, relative_com))
	var com := reference + relative_com
	if not com.is_finite() or not bounds.grow(.00001).has_point(com) or not _positive(covariance): return {}
	var result := {"volume": absf(signed_volume), "com": com, "covariance": covariance, "bounds": bounds}
	_mesh_moments[key] = result
	return result

static func _zero() -> Basis:
	return Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)

static func _diagonal(value: Vector3) -> Basis:
	return Basis(Vector3(value.x, 0, 0), Vector3(0, value.y, 0), Vector3(0, 0, value.z))

static func _outer(a: Vector3, b: Vector3) -> Basis:
	return Basis(a * b.x, a * b.y, a * b.z)

static func _add(a: Basis, b: Basis) -> Basis:
	return Basis(a.x + b.x, a.y + b.y, a.z + b.z)

static func _sub(a: Basis, b: Basis) -> Basis:
	return Basis(a.x - b.x, a.y - b.y, a.z - b.z)

static func _scale(value: Basis, amount: float) -> Basis:
	return Basis(value.x * amount, value.y * amount, value.z * amount)

static func _trace(value: Basis) -> float:
	return value.x.x + value.y.y + value.z.z

static func _finite(value: Basis) -> bool:
	return value.x.is_finite() and value.y.is_finite() and value.z.is_finite()

static func _positive(value: Basis) -> bool:
	# These closed non-flat material solids have a strictly positive covariance
	# and inertia. Sylvester's criterion checks the symmetric full tensor.
	return _finite(value) and value.x.x > 0.0 and value.x.x * value.y.y - value.y.x * value.x.y > 0.0 and value.determinant() > 0.0

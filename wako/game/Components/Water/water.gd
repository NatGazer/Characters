class_name Water extends Object
## Global water queries (static). The FFT Ocean and every WaterBody (lakes, rivers) register themselves here.
##
##   Water.height_at(pos)      -> float   world height of the water surface above/below pos (-INF when there is no water)
##   Water.normal_at(pos)      -> Vector3 surface normal (UP when there is no water)
##   Water.velocity_at(pos)    -> Vector3 water velocity at pos: river current + wave orbital motion (fades with depth)
##   Water.sample_at(pos,id)   -> Dictionary {height,velocity}, one shared owner/detail query
##   Water.is_underwater(pos)  -> bool
##   Water.depth_at(pos)       -> float   how far pos is below the surface (m; 0 above it or where there is no water)
##   Water.body_at(pos)        -> Object  the Ocean or WaterBody that owns pos (null if none)
##   Water.ocean()             -> Ocean   the active ocean (or null)
##
## Lakes and rivers take priority over the ocean inside their footprint (their surface can be above sea level).

static var _ocean: Node = null
static var _bodies: Array[Node] = []
## World AABB per body (same order as _bodies): body_at() only asks bodies whose box holds the point. A body that has
## not published its box yet (set_body_bounds) gets an infinite one.
static var _bounds: Array[AABB] = []
## Optional fixed-depth detail proofs, registered against the exact water owner.
## Weak references avoid extending either owner or controller lifetime.
static var _detail_layers: Dictionary = {}
static var body_registry_revision := 0
const _ANYWHERE := AABB(Vector3(-1e9, -1e9, -1e9), Vector3(2e9, 2e9, 2e9))
## Callables (body: Node3D, impact_speed: float) called whenever a Buoyancy body enters the water.
static var entered_water_hooks: Array[Callable] = []

static func notify_entered_water(body: Node3D, speed: float) -> void:
	for c in entered_water_hooks:
		if c.is_valid():
			c.call(body, speed)

static func register_ocean(o: Node) -> void:
	_ocean = o
	body_registry_revision+=1

static func unregister_ocean(o: Node) -> void:
	_retire_detail_layer(o.get_instance_id())
	if _ocean == o:
		_ocean = null
		body_registry_revision+=1

static func register_body(b: Node) -> void:
	if not _bodies.has(b):
		_bodies.append(b)
		_bounds.append(_ANYWHERE)
		body_registry_revision+=1

static func unregister_body(b: Node) -> void:
	_retire_detail_layer(b.get_instance_id())
	var i := _bodies.find(b)
	if i >= 0:
		_bodies.remove_at(i)
		_bounds.remove_at(i)
		body_registry_revision+=1

## A body's world box: every point it may call its own (contains() == true) must be inside.
static func set_body_bounds(b: Node, box: AABB) -> void:
	var i := _bodies.find(b)
	if i >= 0 and _bounds[i]!=box:
		_bounds[i] = box
		body_registry_revision+=1

static func ocean() -> Node:
	return _ocean if is_instance_valid(_ocean) else null

## The water body whose footprint contains pos (a WaterBody first, then the ocean).
static func body_at(pos: Vector3) -> Object:
	for i in _bodies.size():
		if _bounds[i].has_point(pos):
			var b := _bodies[i]
			if is_instance_valid(b) and b.contains(pos):
				return b
	return ocean()

static func height_at(pos: Vector3, probe_id := 0) -> float:
	var b := body_at(pos)
	var height: float = b.height_at(pos) if b else -INF
	if not WaterInteraction.enabled: return height
	height=WaterInteraction.macro_height_at(pos,height,probe_id)
	if _detail_layers.is_empty(): return height
	var detail := _detail_sample(b,pos,probe_id)
	return height+float(detail.eta) if height>-INF and detail.get("valid",false) else height

## Ambient waves/current only. Hull force models must not integrate their own
## delayed GPU wake readback as an external source of slamming energy.
static func ambient_height_at(pos: Vector3) -> float:
	var b := body_at(pos)
	return b.height_at(pos) if b else -INF

static func ambient_velocity_at(pos: Vector3) -> Vector3:
	var b := body_at(pos)
	return b.velocity_at(pos) if b else Vector3.ZERO

static func sample_at(pos: Vector3, probe_id := 0, minimum_velocity_height := NAN) -> Dictionary:
	## One instantaneous owner/detail snapshot; independent query APIs remain
	## unchanged. Default always evaluates flow, even when height is -INF.
	## A supplied threshold is an explicit lazy contract: velocity is zero and
	## base Ocean/macro flow work is skipped unless final height > threshold.
	## Body-specific fine wakes are the caller's responsibility.
	var b := body_at(pos)
	var height: float = b.height_at(pos) if b else -INF
	var detail: Dictionary = {}
	if WaterInteraction.enabled:
		height=WaterInteraction.macro_height_at(pos,height,probe_id)
		if not _detail_layers.is_empty():
			detail=_detail_sample(b,pos,probe_id)
			if height>-INF and detail.get("valid",false): height+=float(detail.eta)
	if not is_nan(minimum_velocity_height) and not (height>minimum_velocity_height):
		return {height=height,velocity=Vector3.ZERO}
	var velocity: Vector3 = b.velocity_at(pos) if b else Vector3.ZERO
	if WaterInteraction.enabled:
		velocity+=WaterInteraction.macro_velocity_at(pos,probe_id)
		if detail.get("valid",false) and detail.get("velocity_valid",true) and pos.y>=float(detail.bottom) and pos.y<=float(detail.surface):
			var addition: Vector3 = detail.velocity
			if not detail.get("depth_velocity",false):
				addition.y*=clampf((pos.y-float(detail.bottom))/float(detail.reference_depth),0.0,1.0)
			velocity+=addition
	return {height=height,velocity=velocity}

static func normal_at(pos: Vector3, probe_id := 0) -> Vector3:
	var b := body_at(pos)
	var normal: Vector3 = b.normal_at(pos) if b else Vector3.UP
	if not WaterInteraction.enabled: return normal
	normal=WaterInteraction.macro_normal_at(pos,normal,probe_id)
	if _detail_layers.is_empty(): return normal
	var detail := _detail_sample(b,pos,probe_id)
	if detail.get("valid",false) and normal.y>0.0001:
		var slope: Vector2 = Vector2(-normal.x,-normal.z)/normal.y+detail.slope
		normal=Vector3(-slope.x,1.0,-slope.y).normalized()
	return normal

static func velocity_at(pos: Vector3, probe_id := 0) -> Vector3:
	var b := body_at(pos)
	var velocity: Vector3 = b.velocity_at(pos) if b else Vector3.ZERO
	if not WaterInteraction.enabled: return velocity
	velocity+=WaterInteraction.macro_velocity_at(pos,probe_id)
	if _detail_layers.is_empty(): return velocity
	var detail := _detail_sample(b,pos,probe_id)
	if detail.get("valid",false) and detail.get("velocity_valid",true) and pos.y>=float(detail.bottom) and pos.y<=float(detail.surface):
		var addition: Vector3 = detail.velocity
		# Linear fixed-H column: surface eta_t, zero vertical flow at the bed.
		# Dispersive layers already reconstruct the actual depth profile.
		if not detail.get("depth_velocity",false):
			addition.y*=clampf((pos.y-float(detail.bottom))/float(detail.reference_depth),0.0,1.0)
		velocity+=addition
	return velocity

static func register_detail_layer(owner: Node, layer: Node) -> bool:
	var id := owner.get_instance_id()
	if _detail_layers.has(id) and is_instance_valid(_detail_layers[id].get_ref()): return false
	_detail_layers[id]=weakref(layer)
	return true

static func unregister_detail_layer(owner_id: int, layer: Node) -> void:
	if _detail_layers.has(owner_id) and _detail_layers[owner_id].get_ref()==layer:
		_detail_layers.erase(owner_id)

static func _detail_sample(owner: Object, pos: Vector3, probe_id: int) -> Dictionary:
	if not WaterInteraction.enabled or not owner or not is_instance_valid(WaterInteraction.instance) or not WaterInteraction.instance.coupling: return {}
	var id := owner.get_instance_id()
	if not _detail_layers.has(id): return {}
	var layer: Node = _detail_layers[id].get_ref()
	if not is_instance_valid(layer): _detail_layers.erase(id); return {}
	if layer.has_method("sample_water_point"): return layer.sample_water_point(pos,probe_id)
	return layer.sample(Vector2(pos.x,pos.z),probe_id)

static func _retire_detail_layer(owner_id: int) -> void:
	if not _detail_layers.has(owner_id): return
	var layer: Node = _detail_layers[owner_id].get_ref()
	if is_instance_valid(layer): layer.stop()
	_detail_layers.erase(owner_id)

static func depth_at(pos: Vector3) -> float:
	var h := height_at(pos)
	return maxf(h - pos.y, 0.0) if h > -INF else 0.0

static func is_underwater(pos: Vector3) -> bool:
	return height_at(pos) > pos.y

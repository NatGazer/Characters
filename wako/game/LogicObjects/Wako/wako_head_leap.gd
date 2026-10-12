extends RefCounted
## Real native-body head approach and return. The upright capsule assist is
## suspended during the leap; pose, feet, tool and cargo follow that same body.
## The finite in-air force/torque correction is assisted animation physics.
## It never assigns a body transform, velocity or stock scale.
const HolderClearance := preload("res://LogicObjects/Wako/wako_head_holder_clearance.gd")
const LegGeometry := preload("res://Components/Contraptions/shared_leg_geometry.gd")
const Catalogue := preload("res://Components/Contraptions/part_catalog.gd")
const StockBounds := preload("res://Components/Contraptions/depot_stock_layout.gd")
const LoadGeometry := preload("res://Components/Contraptions/rolling_balance.gd")
const GRAVITY := 9.8
const CONTACT_GAP := .0001
const CONTACT_ERROR := .00075
const MAXIMUM_SPEED := 8.5
const MAXIMUM_ACCELERATION := GRAVITY * 2.0
const MAXIMUM_ANGULAR_ACCELERATION := 24.0
const CONTACT_QUERY_BIT := 1 << 30
# Admission keeps 10% of the 2 g force cap and 15% of the 24 rad/s² angular cap
# for measured tracking error; feed-forward plus PD can never exceed either cap.
const FORCE_BUDGET := .9
const ANGULAR_BUDGET := .85
# Centre-of-mass flight plan (seconds, metres above the higher COM end).
# Brisk candidates first; the original long timings/heights remain the
# fallbacks whenever the unchanged clearance admission rejects a short arc.
const SOLO_OUTBOUND := [[1.05,.40],[.95,.40],[1.15,.40],[1.05,.35],[1.3,.45],[1.15,.35]]
const CREW_OUTBOUND := [[1.45,.35],[1.3,.35],[1.6,.35],[1.45,.30],[1.8,.40],[1.6,.30]]
const LONG_OUTBOUND := [[1.6,.70],[2.0,.70],[2.0,1.0],[2.4,1.0],[2.4,1.35],[2.8,1.35],[3.0,1.35],[3.4,1.35]]
const SOLO_RETURN := [[.85,.30],[.80,.30],[.95,.30],[.85,.25],[.95,.35],[1.1,.40]]
const CREW_RETURN := [[1.3,.20],[1.15,.20],[1.0,.20],[1.3,.15],[1.5,.25],[1.15,.15]]
const LONG_RETURN := [[1.6,.70],[2.0,.90],[2.4,1.1],[2.55,1.1],[2.7,1.35],[2.85,1.35]]
const SOLO_TOUCHDOWN := -1.8
const CREW_TOUCHDOWN := -1.15
# The final tenth of the outbound is a pure head descent onto the roof plane:
# horizontal travel ends at .9 T, the half-turn at .86 T.
const HORIZONTAL_FRACTION := .9
const SPIN_FRACTION := .86
# The paired push-off seeds most of the half-turn (P0-3); the torque assist
# only shapes it. Return rotation still turns gently at touchdown.
const LAUNCH_SPIN := 5.5
const CREW_LAUNCH_SPIN := 4.0
const RETURN_SPIN := 4.5
const CREW_RETURN_SPIN := 3.5
const LANDING_SPIN := .8
const MAXIMUM_SPIN := 6.0
# Supported gather (P0-5): crouch, hold with a lean toward the stock, extend.
const GATHER := {"crouch":.13,"hold":.17,"extend":.24,"depth":.14,"lean":deg_to_rad(7.0),"launch_lean":deg_to_rad(3.0)}
const CREW_GATHER := {"crouch":.16,"hold":.21,"extend":.30,"depth":.16,"lean":deg_to_rad(6.0),"launch_lean":deg_to_rad(2.5)}
# Tuck (P0-4): deeper ankle lift, outbound/return curves, pointed feet in the
# tuck and flat soles before touchdown.
const TUCK_UP := .48
const TUCK_BACK := .14
const TUCK_CONTACT := .35
const TUCK_TOUCHDOWN := .2
const FOOT_POINT := deg_to_rad(48.0)
const TOE_CURL := deg_to_rad(22.0)
const FOOT_FLATTEN_SECONDS := .12
# Touchdown absorb (P0-6), scaled by the measured impact speed.
const ABSORB := {"in":.07,"hold":.03,"recover":.30}
const CREW_ABSORB := {"in":.10,"hold":.05,"recover":.45}
const ABSORB_ROCK := deg_to_rad(3.0)
const BRISK_ROOT_SPEED := 3.0
# A readable headstand beat: contact is reported only after the head has
# pressed on the roof this long (an extra gate; the geometric gates are unchanged).
const CONTACT_PRESS := .10

var worker: RigidBody3D
var part: RigidBody3D
var crew: Array = []
var state := ""
var reason := ""
var elapsed := 0.0
var contact_local := Vector3.ZERO
var contact_normal := Vector3.UP
var _crew_axis := Vector3.RIGHT
var contact_error := INF
var contact_surface_gap := INF
var contact_surface_penetration := .0
var contacted := false
var source_before_contact := Transform3D.IDENTITY
var source_after_contact := Transform3D.IDENTITY
var _source_start := Transform3D.IDENTITY
var _home := Transform3D.IDENTITY
var _root_local := Transform3D.IDENTITY
var _tool_local := Transform3D.IDENTITY
var _tool_bounds := AABB()
var _holder_bounds := AABB()
var _flight_start := Transform3D.IDENTITY
var _destination := Transform3D.IDENTITY
var _launch_velocity := Vector3.ZERO
var _flight_seconds := 1.3
var _bones: Array[Transform3D] = []
var _snapshot_ready := false
var _saved_damping := .0
var _saved_damping_mode := RigidBody3D.DAMP_MODE_COMBINE
var _saved_angular_damping := .0
var _saved_angular_damping_mode := RigidBody3D.DAMP_MODE_COMBINE
var _settled := 0.0
var _stock_bounds := AABB()
var _gun_head_geometry: Dictionary = {}
var _cargo_refusal_rows := 0
static var _contact_face_probe_rows: Dictionary={}
var _cargo_refusal_state_rows: Dictionary = {}
var _cargo_local := Transform3D.IDENTITY
var _release_watch: RigidBody3D
var _abort_requested := false
var _return_started := false
var _native_settings_saved := false
var _saved_angular_locks: Array[bool] = []
var _needs_angular_restore := false
var _planning_return := false
var _saved_source_layer := 0
var _leg_points: Array[Vector3] = []
var _saved_collision_shape: Shape3D
var _saved_collision_transform := Transform3D.IDENTITY
var _needs_collision_restore := false
var arc_failure := ""
var _launch_frame := -1
var _head_height := .338
var _roof_samples: Array[Vector3]=[]
var _head_touch_local:=Vector3(0,.338,0)
var _rotation_axis := Vector3.RIGHT
var _rotation_angle := .0
var evaluated_leg_bases: Array[Basis]=[]
var _stunt_forward := Vector3.FORWARD
var _impact_age := -1.0
var _stunt_grounded: Array[bool] = [false,false]
var _restart_leg_points: Array[Vector3] = []
var _restart_ankles: Array[Basis] = []
var _stunt_capacity := 1.0
var _stunt_clearance_rows := 0
var _holder_clearance := HolderClearance.new()
var _holder_inverse := Transform3D.IDENTITY
var _holder_capture_usec := 0
# Centre-of-mass plan: horizontal quintic (ends at _horizontal_seconds), vertical
# quintic (ends at _flight_seconds) and the half-turn angle quintic (ends at
# _spin_seconds). The body origin is derived: COM(t) - R(t)*_com_local.
var _com_local := Vector3.ZERO
var _com_horizontal: Array[PackedFloat64Array] = []
var _com_vertical := PackedFloat64Array()
var _horizontal_seconds := 1.0
var _spin := PackedFloat64Array()
var _spin_seconds := 1.0
var _spin_delay := 0.0
var _spin_hold := 0.0
var _spin_start := 0.0
var _bare_retry := 0.0
var _outbound_axis := Vector3.RIGHT
var _touchdown_velocity := Vector3.ZERO
var _launch_spin := Vector3.ZERO
var _plan_tier := ""
var _impact_speed := 0.0
var _absorb_depth := .0
var _contact_age := -1.0
var flight_stats: Dictionary = {}
static var _args: PackedStringArray = []

func setup(owner: RigidBody3D) -> void:
	worker = owner
	if _args.is_empty(): _args = OS.get_cmdline_user_args()

func active() -> bool:
	return state in ["prepare", "outbound", "contact", "return", "landing"]

func airborne_pose() -> bool:
	return state in ["outbound", "contact", "return"]

## Eye target for the face system: the real contact point while gathering and
## diving onto it, then the landing spot under the launch place on the way back.
func gaze_target() -> Variant:
	if state in ["prepare","outbound","contact"] and is_instance_valid(part):
		return part.global_transform*contact_local
	if state in ["return","landing"]:
		return _home.origin-_home.basis.y.normalized()*worker.ride_height
	return null

## Pose root position budget: brisk only for the gather and the touchdown absorb;
## every other head-owned blend keeps the original .9 m/s.
func root_speed_limit() -> float:
	if state=="prepare": return BRISK_ROOT_SPEED
	var absorb: Dictionary = _absorb_profile()
	if state=="landing" and _impact_age>=0.0 and _impact_age<float(absorb["in"])+float(absorb.hold)+.1: return BRISK_ROOT_SPEED
	return .9

static func begin_group(source: RigidBody3D, members: Array) -> String:
	if not is_instance_valid(source) or members.is_empty(): return "Reserved physical stock unavailable"
	# Compact .28/.12 depot displays cannot be expanded at head contact without
	# stretching a rigid body. Keep its actual pose and reject that old storage
	# representation until the depot has a full-size physical storage place.
	if not source.global_basis.get_scale().is_equal_approx(Vector3.ONE):
		return "Head pickup needs full-size physical stock; compact depot display remains in its original place"
	if is_instance_valid(source.carrier): return "Physical stock is already held"
	if source.linear_velocity.length() > .3 or source.angular_velocity.length() > .3:
		return "Wait for the original stock to settle before head pickup"
	var bounds: AABB = StockBounds.bounds(source)
	if bounds.size.length_squared() < .0001: return "Physical stock has no complete contact geometry"
	var world_bounds: AABB=source.global_transform*bounds
	var axis := 0 if world_bounds.size.x >= world_bounds.size.z else 2
	if members.size() > 1 and world_bounds.size[axis] < 1.18:
		return "This heavy stock needs a wider supported head contact face"
	for member: Node in members:
		# A failed landing can leave the temporary flight torso in use while
		# the original capsule is obstructed. Preserve that original shape:
		# another jump must not capture the temporary torso as its new default.
		if not member.head_leap.active():
			member.head_leap._restore_collision_when_safe()
			if member.head_leap._needs_collision_restore:
				return "Clear the original Wako body before another head-first jump"
		var back: Variant=member.back_tool if "back_tool" in member else null
		if back and (back.busy() or back.recovering()): return "Wait for the original foot/back tool transfer to settle before head pickup"
		if back and is_instance_valid(member.equipped_tool):
			if member.tool_foot_occupied(): return "Physically stow the original foot tool before the head-first jump"
			if not back.attached_tools().has(member.equipped_tool): return "Original tool has not reached genuine back custody"
			var keepouts: Array=back.local_keepouts()
			if keepouts.is_empty() or keepouts.any(func(item:Dictionary)->bool:return item.get("body")!=member.equipped_tool or not item.get("transform") is Transform3D or not item.get("box") is AABB):
				return "Secured original back tool has no complete measured body keepouts"
		if not member.head_leap._capture_mesh_roof(): return "The original Wako skin has no evaluated rigid head roof"
		if member.head_leap.active() or not member.on_ground or not member._pose.evaluated_valid:
			return "Wako need supported footing before their head-first jump"
		if not member._pose.evaluated_grounded.any(func(value: bool) -> bool: return value):
			return "Wako need a genuine planted launch sole"
		if member.linear_velocity.length() > .6: return "Wako are settling their launch footing"
	for index in members.size():
		var controller: RefCounted = members[index].head_leap
		controller._prepare(source, members, bounds, axis, index)
	members[0].head_leap._saved_source_layer=source.collision_layer
	# A query-only layer exposes the SAME frozen native stock shapes to a precise
	# head ray. No helper or world body has this bit in its physical collision mask.
	source.collision_layer |= CONTACT_QUERY_BIT
	var alternative_planned := false
	for member: Node in members:
		var controller: RefCounted = member.head_leap
		var face_reason: String = controller._observe_contact_face()
		# A solo approach can hit a curved rim or an open gap. Reuse the
		# existing bounded native-face/full-arc alternatives before giving up.
		if not face_reason.is_empty() and members.size()==1:
			face_reason=controller._plan_outbound_alternatives(face_reason)
			alternative_planned=face_reason.is_empty()
		if not face_reason.is_empty():
			for other: Node in members: other.head_leap.clear_before_launch()
			return face_reason
	var blocker: String = "" if alternative_planned else members[0].head_leap._plan_outbound()
	if not blocker.is_empty():
		for other: Node in members: other.head_leap.clear_before_launch()
		return blocker
	for member: Node in members:
		member.stop_navigation()
		# Keep the real walking/idle terrain solve during the supported preparation;
		# the airborne state owns pickup after the planted launch impulse.
		member.action = ""
		member.action_progress = 0.0
		member._grounded_heading_handoff = false
		member._animation.pause()
		member._tool.visible = false
		source.add_collision_exception_with(member)
	return ""

func _capture_mesh_roof() -> bool:
	if not _roof_samples.is_empty(): return true
	var mesh: MeshInstance3D=worker._skin_mesh
	var sk: Skeleton3D=worker._skeleton
	if not mesh or not mesh.skin or not sk: return false
	var root:=sk.find_bone("Bone")
	var triangles: Array[Vector3]=[]
	var roof_vertices: Array[Vector3]=[]
	_head_height=-INF
	for surface in mesh.mesh.get_surface_count():
		var arrays:=mesh.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array=arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array=arrays[Mesh.ARRAY_WEIGHTS]
		var indices: PackedInt32Array=arrays[Mesh.ARRAY_INDEX]
		if indices.is_empty():
			for index in vertices.size(): indices.append(index)
		var stride:=bones.size()/vertices.size()
		var points: Array[Vector3]=[]
		for index in vertices.size():
			var point:=Vector3.ZERO
			var root_weight:=.0
			for influence in stride:
				var weight:=weights[index*stride+influence]
				if weight<=.000001: continue
				var bind:=bones[index*stride+influence]
				var bone:=mesh.skin.get_bind_bone(bind)
				if bone<0: bone=sk.find_bone(mesh.skin.get_bind_name(bind))
				if bone!=root: continue
				point+=mesh.skin.get_bind_pose(bind)*vertices[index]*weight
				root_weight+=weight
			points.append(point if root_weight>.9999 else Vector3.INF)
			if root_weight>.9999:
				_head_height=maxf(_head_height,point.y)
				roof_vertices.append(point)
		for triangle in indices.size()/3:
			var a:=points[indices[triangle*3]]
			var b:=points[indices[triangle*3+1]]
			var c:=points[indices[triangle*3+2]]
			if not a.is_finite() or not b.is_finite() or not c.is_finite(): continue
			if absf((b-a).cross(c-a).normalized().y)>.95: triangles.append((a+b+c)/3.0)
	if not is_finite(_head_height) or absf(_head_height-worker.HEAD_OFFSET)>.01:
		print("HEAD_ROOF_BAD_HEIGHT ",_head_height," samples=",triangles.size())
		return false
	var roofs:=roof_vertices.filter(func(point: Vector3)->bool:return point.y>=_head_height-.015)
	if roofs.is_empty():
		print("HEAD_ROOF_NO_TRIANGLES height=",_head_height," candidates=",triangles)
		return false
	_head_touch_local=roof_vertices[0]
	for point: Vector3 in roof_vertices:
		if point.y>_head_touch_local.y+.000001 or (absf(point.y-_head_touch_local.y)<.000001 and Vector2(point.x,point.z).length_squared()<Vector2(_head_touch_local.x,_head_touch_local.z).length_squared()): _head_touch_local=point
	_roof_samples.append(_head_touch_local)
	# The faceted original roof is curved: its triangle centroids are below
	# its crown. Contact samples are actual weighted vertices on those indexed
	# triangles, including the genuine crown that first touches the material.
	for desired: Vector2 in [Vector2.ZERO,Vector2(-.25,-.25),Vector2(-.25,.25),Vector2(.25,-.25),Vector2(.25,.25)]:
		var best: Vector3=roofs[0]
		for point: Vector3 in roofs:
			if Vector2(point.x,point.z).distance_squared_to(desired)<Vector2(best.x,best.z).distance_squared_to(desired): best=point
		if not _roof_samples.has(best): _roof_samples.append(best)
	print("HEAD_ROOF_ORIGINAL height=",_head_height," touch=",_head_touch_local," vertices=",_roof_samples)
	return not _roof_samples.is_empty()

func _prepare(source: RigidBody3D, members: Array, bounds: AABB, axis: int, index: int) -> void:
	part = source
	crew = members.duplicate()
	state = "prepare"
	_impact_age = -1.0
	for side in 2: _stunt_grounded[side] = worker._pose.evaluated_grounded[side]
	reason = ""
	elapsed = 0.0
	contacted = false
	_abort_requested = false
	_return_started = false
	_native_settings_saved = false
	_planning_return = false
	_settled = 0.0
	_snapshot_ready = false
	_bones.clear()
	_restart_leg_points.clear()
	_restart_ankles.clear()
	_stunt_clearance_rows = 0
	_impact_speed = 0.0
	_absorb_depth = 0.0
	_contact_age = -1.0
	_bare_retry = 0.0
	_plan_tier = ""
	flight_stats = {"source":source.part_id if "part_id" in source else str(source.name),"crew":members.size()}
	_stock_bounds = bounds
	_capture_gun_head_constituents()
	_source_start = source.global_transform
	_home = worker.global_transform
	_stunt_forward = (worker.global_basis.inverse()*(-worker._model.global_basis.z)).normalized()
	_root_local = worker.global_transform.affine_inverse() * worker._pose.evaluated_root
	# The retained original tool can be on a toe or a genuinely caught back
	# holder. Clearance captures its actual body pose, never an assumed anchor.
	_tool_local = worker.global_transform.affine_inverse() * (worker.equipped_tool.global_transform if is_instance_valid(worker.equipped_tool) else worker.tool_anchor.global_transform)
	_tool_bounds=StockBounds.bounds(worker.equipped_tool) if is_instance_valid(worker.equipped_tool) else AABB()
	_capture_holder_bounds()
	_leg_points.clear()
	var inverse := worker.global_transform.affine_inverse()
	for side in 2:
		_leg_points.append(inverse*worker._pose.evaluated_hips[side])
		_leg_points.append(inverse*worker._pose.evaluated_knees[side])
		var ankle: Vector3=worker._pose.evaluated_soles[side]-worker._pose.evaluated_ankles[side]*Vector3(0,worker._pose._ankle_height[side],0)
		_leg_points.append(inverse*ankle)
	contact_normal=Vector3.UP
	_crew_axis=Vector3.RIGHT if axis==0 else Vector3.BACK
	var world_bounds: AABB=source.global_transform*bounds
	var approach := Vector3.ZERO
	for member: Node in members: approach+=member.global_position
	approach/=members.size()
	var point := world_bounds.get_center()
	point.y=world_bounds.end.y
	for lateral in [0,2]:
		var margin: float=minf(.38,world_bounds.size[lateral]*.45)
		if members.size()>1 and lateral==axis: margin=maxf(margin,.49+.03)
		point[lateral]=clampf(approach[lateral],world_bounds.position[lateral]+margin,world_bounds.end[lateral]-margin)
	if members.size()>1: point[axis]+=(float(index)-float(members.size()-1)*.5)*.98
	contact_local=source.global_transform.affine_inverse()*point

func _observe_contact_face() -> String:
	var point: Vector3 = part.global_transform*contact_local
	var depth: float=(part.global_transform*_stock_bounds).size.y+.4
	var query := PhysicsRayQueryParameters3D.create(point+contact_normal*.2,point-contact_normal*depth,CONTACT_QUERY_BIT)
	var hit := worker.get_world_3d().direct_space_state.intersect_ray(query)
	var args:=_args
	var original_wheel_probe: bool="--easy-island-removed-wheel-probe" in args and part.part_id=="stock_3" and worker.current_job_id=="salvage:stock_3"
	var original_gun_probe: bool="--easy-island-gun-controls" in args and part.part_id=="stock_16" and part.kind=="gun" and worker.current_job_id.begins_with("build:")
	if (original_wheel_probe or original_gun_probe) and (hit.is_empty() or hit.collider!=part or hit.normal.dot(Vector3.UP)<.8):
		_observe_original_contact_refusal(point,query,hit)
	if hit.is_empty() or hit.collider!=part: return "The actual stock has no native head contact face at this support point"
	if hit.normal.dot(Vector3.UP)<.8: return "The original stock has no sufficiently level head contact face"
	contact_local=part.global_transform.affine_inverse()*hit.position
	contact_normal=hit.normal
	return ""

func _observe_original_contact_refusal(point: Vector3,query: PhysicsRayQueryParameters3D,hit: Dictionary) -> void:
	# Capture the native ray which actually failed; no extra ray or admission.
	var key:=str(part.get_rid())
	var sample:=int(_contact_face_probe_rows.get(key,0))
	if sample>=8: return
	_contact_face_probe_rows[key]=sample+1
	var collider: Variant=hit.get("collider")
	var native:=PhysicsServer3D.body_get_direct_state(part.get_rid())
	var world_bounds: AABB=part.global_transform*_stock_bounds
	print("HEAD_CONTACT_FACE_REFUSAL ",JSON.stringify({"scope":"read-only actual failed native head-face ray",
		"worker":worker.worker_id,"job":worker.current_job_id,"tick":Engine.get_physics_frames(),"sample":sample+1,
		"source":part.part_id,"source_rid":str(part.get_rid()),"source_pose":part.encode_transform(part.global_transform),
		"source_native":part.encode_transform(native.transform) if native else null,
		"worker_pose":part.encode_transform(worker.global_transform),"saved_launch":part.encode_transform(_home),
		"source_world_bounds":[part.encode_vector(world_bounds.position),part.encode_vector(world_bounds.size)],
		"contact_local":part.encode_vector(contact_local),"proposal":part.encode_vector(point),
		"ray_from":part.encode_vector(query.from),"ray_to":part.encode_vector(query.to),"collision_mask":query.collision_mask,
		"hit_body":str(collider.get_path()) if is_instance_valid(collider) and collider is Node else str(collider),
		"hit_rid":str(hit.get("rid")),"hit_shape":hit.get("shape"),"same_source":collider==part,
		"hit_point":part.encode_vector(hit.position) if hit.has("position") else null,
		"hit_normal":part.encode_vector(hit.normal) if hit.has("normal") else null,
		"normal_up":hit.normal.dot(Vector3.UP) if hit.has("normal") else null,
		"unchanged_minimum_normal_up":.8,"roof_height":_head_height,"roof_samples":_roof_samples.size()}))

func _contact_destination() -> Transform3D:
	var y := -contact_normal
	var home_cube := _home.basis*_root_local.basis
	# A cooperative flip uses the same WORLD axis along both contact points.
	# Different visual launch yaws must not rotate the two roofs along different
	# axes and sweep the common stock through the partner's native head.
	# Head-first: the half-turn axis is lateral to the travel toward the stock
	# (UP x d), shared as one world axis by a crew. A pi turn about +/-axis is
	# the same pose; the signed branch is chosen explicitly by the planner.
	var flip_axis := _flip_axis().slide(contact_normal).normalized()
	if flip_axis.length_squared()<.5: flip_axis=home_cube.x.slide(contact_normal).normalized()
	var flipped := Basis(flip_axis,PI)*home_cube
	var x := flipped.x.slide(y).normalized()
	if x.length_squared() < .5: x = Vector3.RIGHT.slide(y).normalized()
	var cube := Basis(x,y,x.cross(y)).orthonormalized()
	var body := cube * _root_local.basis.orthonormalized().inverse()
	var point: Vector3 = part.global_transform * contact_local + contact_normal * CONTACT_GAP
	return Transform3D(body, point - cube*_head_touch_local - body*_root_local.origin)

func _travel_direction() -> Vector3:
	# Horizontal launch-to-contact direction; a crew shares the mean direction.
	var total := Vector3.ZERO
	for member: Node in crew:
		if not is_instance_valid(member): continue
		var leap: RefCounted=member.head_leap
		if not is_instance_valid(leap.part): continue
		var direction: Vector3=(leap.part.global_transform*leap.contact_local-leap._home.origin).slide(Vector3.UP)
		if direction.length_squared()<.0025: direction=(leap._home.basis*leap._stunt_forward).slide(Vector3.UP)
		if direction.length_squared()>.000001: total+=direction.normalized()
	if total.length_squared()<.000001: total=(_home.basis*_stunt_forward).slide(Vector3.UP)
	return total.normalized() if total.length_squared()>.000001 else Vector3.FORWARD

func _flip_axis() -> Vector3:
	# A positive turn about UP x d tips the head toward d: a head-first front
	# flip. A crew keeps its common world axis, signed to agree with that turn.
	var lateral := Vector3.UP.cross(_travel_direction()).normalized()
	if crew.size()>1: return _crew_axis if _crew_axis.dot(lateral)>=0.0 else -_crew_axis
	return lateral

func _native_com_local() -> Vector3:
	var native:=PhysicsServer3D.body_get_direct_state(worker.get_rid())
	return native.center_of_mass_local if native else worker.center_of_mass

func _loaded_com_local(source: RigidBody3D, share: float) -> Vector3:
	# Predict the native COM after the same source's share joins this body
	# (the helper's attached-payload rule), so the return is planned before
	# custody changes. _follow still tracks the actual COM it then measures.
	var com := _native_com_local()
	if share<=0.0 or not is_instance_valid(source): return com
	var cargo: Vector3=worker.global_transform.affine_inverse()*LoadGeometry.world_centre(source)
	return (com*worker.mass+cargo*share)/(worker.mass+share)

func _plan_outbound() -> String:
	var blocker := _plan_outbound_at_contact()
	if blocker.is_empty() or crew.size()!=1: return blocker
	return _plan_outbound_alternatives(blocker)

func _plan_outbound_alternatives(blocker: String) -> String:
	# Keep a clear original approach. A solo roof beside taller finite stock
	# can need another real contact within the same supported face margins.
	var first: Vector3=part.global_transform*contact_local
	var normal := contact_normal
	var world_bounds: AABB=part.global_transform*_stock_bounds
	var centre := world_bounds.get_center()
	centre.y=world_bounds.end.y
	for candidate: Vector3 in [centre,centre*2.0-first]:
		if candidate.is_equal_approx(first): continue
		candidate.y=world_bounds.end.y
		for lateral in [0,2]:
			var margin: float=minf(.38,world_bounds.size[lateral]*.45)
			candidate[lateral]=clampf(candidate[lateral],world_bounds.position[lateral]+margin,world_bounds.end[lateral]-margin)
		contact_local=part.global_transform.affine_inverse()*candidate
		contact_normal=normal
		if not _observe_contact_face().is_empty(): continue
		blocker=_plan_outbound_at_contact()
		if blocker.is_empty(): return ""
	# The small open horn's central tapered bell is not a supporting plane
	# for the complete head: its level driver stands above that facet. After
	# preserving the ordinary candidates, ray the real top driver connector.
	# Native face observation and the unchanged whole-source arc guard still
	# decide admission; the source retains its actual pose, shape and mass.
	if part.kind==Catalogue.SignalHorn.KIND:
		var top: Dictionary=Catalogue.socket(part.definition,"top")
		if not top.is_empty():
			var previous_contact:=contact_local
			var previous_normal:=contact_normal
			var driver: Vector3=part.global_transform*top.pos
			driver.y=world_bounds.end.y
			contact_local=part.global_transform.affine_inverse()*driver
			contact_normal=Vector3.UP
			if _observe_contact_face().is_empty(): blocker=_plan_outbound_at_contact()
			else:
				contact_local=previous_contact
				contact_normal=previous_normal
	return blocker

func _plan_outbound_at_contact() -> String:
	for member: Node in crew:
		var controller: RefCounted=member.head_leap
		controller._fit_stunt_tuck()
		controller._flight_start=member.global_transform
		controller._destination=controller._contact_destination()
		controller._outbound_axis=controller._flip_axis()
		# Explicit head-first branch: never the sign of a near-pi quaternion.
		controller._configure_rotation(controller._outbound_axis)
		controller._com_local=controller._native_com_local()
		if controller._flight_start.origin.distance_to(controller._destination.origin)>6.0: return "Actual stock is beyond a bounded head-first jump; clear a closer launch place"
	# Brisk ballistic candidates first, then the original long timings/heights.
	var tiers: Array=[[SOLO_OUTBOUND if _small_stock_timing() else CREW_OUTBOUND,"brisk"],[LONG_OUTBOUND,"long"]]
	for tier: Array in tiers:
		for candidate: Array in tier[0]:
			var shaped := true
			for member: Node in crew:
				if not member.head_leap._plan_flight(float(candidate[0]),float(candidate[1]),false,str(tier[1])):
					shaped=false
					arc_failure=member.head_leap.arc_failure
					break
			if not shaped: continue
			if crew.all(func(member: Node) -> bool: return member.head_leap._arc_clear(false)):
				for member: Node in crew: member.head_leap._record_plan("outbound")
				return ""
			for member: Node in crew:
				if not member.head_leap.arc_failure.is_empty(): arc_failure=member.head_leap.arc_failure
	return "No clear whole-body/head-first arc; "+arc_failure

func _small_stock_timing() -> bool:
	return crew.size()==1 and is_instance_valid(part) and part.mass<=35.0 and maxf(_stock_bounds.size.x,maxf(_stock_bounds.size.y,_stock_bounds.size.z))<=1.2

static func _quintic(p0: float, v0: float, a0: float, p1: float, v1: float, a1: float, seconds: float) -> PackedFloat64Array:
	# Position/velocity/acceleration at both ends, time-power coefficients.
	var t := maxf(seconds,.0001)
	var h := p1-(p0+v0*t+.5*a0*t*t)
	var dv := v1-(v0+a0*t)
	var da := a1-a0
	return PackedFloat64Array([p0,v0,.5*a0,(10.0*h-4.0*dv*t+.5*da*t*t)/(t*t*t),(-15.0*h+7.0*dv*t-da*t*t)/(t*t*t*t),(6.0*h-3.0*dv*t+.5*da*t*t)/(t*t*t*t*t)])

static func _quintic_at(c: PackedFloat64Array, time: float, order: int) -> float:
	if c.size()!=6: return 0.0
	if order==0: return c[0]+time*(c[1]+time*(c[2]+time*(c[3]+time*(c[4]+time*c[5]))))
	if order==1: return c[1]+time*(2.0*c[2]+time*(3.0*c[3]+time*(4.0*c[4]+time*5.0*c[5])))
	return 2.0*c[2]+time*(6.0*c[3]+time*(12.0*c[4]+time*20.0*c[5]))

static func _assist_minimising_velocity(p0: float, a0: float, p1: float, v1: float, a1: float, seconds: float) -> float:
	# The quintic acceleration is linear in its start velocity: a(t)=A(t)+B(t)v0.
	# Least squares on the horizontal assist gives the most ballistic push-off.
	var base := _quintic(p0,0.0,a0,p1,v1,a1,seconds)
	var unit := _quintic(0.0,1.0,0.0,0.0,0.0,0.0,seconds)
	var numerator := .0
	var denominator := .0
	for step in 41:
		var time := seconds*float(step)/40.0
		var b := _quintic_at(unit,time,2)
		numerator += _quintic_at(base,time,2)*b
		denominator += b*b
	return -numerator/denominator if denominator>.000001 else 0.0

func _plan_flight(seconds: float, apex: float, returning: bool, tier: String, start_velocity: Variant = null) -> bool:
	# Plan the CENTRE OF MASS. The push-off starts it in free fall (zero assist);
	# outbound ends at rest on the contact pose, the return touches down moving.
	# A fixed start velocity (interrupted flight) receives no new impulse.
	arc_failure = ""
	_flight_seconds = seconds
	_plan_tier = tier
	var bare := start_velocity is Vector3
	var crew_timing := not _small_stock_timing()
	_horizontal_seconds = seconds*(HORIZONTAL_FRACTION if not returning else 1.0)
	var start: Vector3 = _flight_start*_com_local
	var end: Vector3 = _destination*_com_local
	# An interrupted recovery beside the stock first lifts its head clear
	# (net upward start) while its existing spin decays, then turns.
	var beside_stock := bare and is_instance_valid(part) and (part.global_transform*_stock_bounds).grow(.3).has_point(_head_point())
	var start_acceleration := (5.0 if beside_stock else 0.0) if bare else -GRAVITY
	_touchdown_velocity = Vector3.UP*((CREW_TOUCHDOWN if crew_timing or bare else SOLO_TOUCHDOWN) if returning else 0.0)
	var end_acceleration := -GRAVITY if returning else 0.0
	var velocity := Vector3.ZERO
	if bare:
		velocity = start_velocity
	else:
		velocity.x = _assist_minimising_velocity(start.x,0.0,end.x,0.0,0.0,_horizontal_seconds)
		velocity.z = _assist_minimising_velocity(start.z,0.0,end.z,0.0,0.0,_horizontal_seconds)
		# Vertical push-off reaches the requested apex above the higher end.
		var ceiling := maxf(start.y,end.y)+apex
		var low := 0.0
		var high := MAXIMUM_SPEED
		for iteration in 24:
			var middle := (low+high)*.5
			var trial := _quintic(start.y,middle,start_acceleration,end.y,_touchdown_velocity.y,end_acceleration,seconds)
			var top := -INF
			for step in 33: top = maxf(top,_quintic_at(trial,seconds*float(step)/32.0,0))
			if top<ceiling: low=middle
			else: high=middle
		velocity.y = (low+high)*.5
		if velocity.length()>MAXIMUM_SPEED:
			arc_failure="push-off %.2fm/s exceeds %.1fm/s" % [velocity.length(),MAXIMUM_SPEED]
			return false
	_com_horizontal = [_quintic(start.x,velocity.x,0.0,end.x,0.0,0.0,_horizontal_seconds),_quintic(start.z,velocity.z,0.0,end.z,0.0,0.0,_horizontal_seconds)]
	_com_vertical = _quintic(start.y,velocity.y,start_acceleration,end.y,_touchdown_velocity.y,end_acceleration,seconds)
	_launch_velocity = velocity
	# Half-turn: the push-off seeds the spin, the turn is complete at .86 T
	# (outbound) so the head descends level; the return lands still turning gently.
	_spin_seconds = seconds*(SPIN_FRACTION if not returning else (.9 if bare else 1.0))
	_spin_delay = 0.0
	_spin_hold = 0.0
	_spin_start = 0.0
	var angle := _rotation_angle
	var omega0 := .0
	var omega1 := .0
	if bare:
		omega0 = clampf(worker.angular_velocity.dot(_rotation_axis),-MAXIMUM_SPIN,MAXIMUM_SPIN)
		if beside_stock:
			# Linear spin decay over the lift, then a rest-to-rest turn.
			_spin_delay = clampf(seconds*.18,absf(omega0)/18.0,.35)
			_spin_start = omega0
			_spin_hold = omega0*_spin_delay*.5
			_spin_seconds = seconds*.9-_spin_delay
			omega0 = 0.0
	elif returning:
		omega0 = minf(CREW_RETURN_SPIN if crew_timing else RETURN_SPIN,1.5*angle/_spin_seconds)
		omega1 = minf(LANDING_SPIN,.4*angle/_spin_seconds)
	else:
		omega0 = minf(CREW_LAUNCH_SPIN if crew_timing else LAUNCH_SPIN,1.6*angle/_spin_seconds)
	_spin = _quintic(_spin_hold,omega0,0.0,angle,omega1,0.0,_spin_seconds)
	_launch_spin = _rotation_axis*(omega0 if _spin_delay<=0.0 else _spin_start)
	var peak_alpha := absf(_spin_start/_spin_delay) if _spin_delay>0.0 else .0
	for step in 49:
		var time := _spin_seconds*float(step)/48.0
		peak_alpha = maxf(peak_alpha,absf(_quintic_at(_spin,time,2)))
		if _quintic_at(_spin,time,1)<-.25 and not bare:
			arc_failure="half-turn would reverse at %.3fs" % time
			return false
	# An interrupted recovery may use more of the unchanged 24 rad/s² cap: its
	# landing settle tolerates tracking error that a precise head contact cannot.
	if peak_alpha>MAXIMUM_ANGULAR_ACCELERATION*(.95 if bare else ANGULAR_BUDGET):
		arc_failure="angular budget %.1frad/s² at %.2fs half-turn" % [peak_alpha,_spin_seconds]
		return false
	return true

func _record_plan(label: String) -> void:
	# Admission facts for the probe/report: the exact admitted plan.
	var worst := .0
	var low := 0
	var samples := ceili(_flight_seconds*60.0)
	var apex := -INF
	for step in range(samples+1):
		var time := _flight_seconds*float(step)/samples
		var need := (_planned_com(time,2)+Vector3.UP*GRAVITY).length()
		worst = maxf(worst,need)
		if need<.3*GRAVITY: low+=1
		apex = maxf(apex,_planned_com(time,0).y)
	var peak_alpha := absf(_spin_start/_spin_delay) if _spin_delay>0.0 else .0
	for step in 49: peak_alpha=maxf(peak_alpha,absf(_quintic_at(_spin,_spin_seconds*float(step)/48.0,2)))
	flight_stats[label]={"tier":_plan_tier,"seconds":_flight_seconds,"horizontal_seconds":_horizontal_seconds,"spin_seconds":_spin_seconds,
		"push_off":_launch_velocity.length(),"push_off_velocity":[_launch_velocity.x,_launch_velocity.y,_launch_velocity.z],
		"launch_spin":_launch_spin.length(),"turn_deg":rad_to_deg(_rotation_angle),"axis":[_rotation_axis.x,_rotation_axis.y,_rotation_axis.z],
		"apex_above_start_com":apex-(_flight_start*_com_local).y,"apex_above_end_com":apex-(_destination*_com_local).y,
		"worst_assist":worst,"admission":MAXIMUM_ACCELERATION*FORCE_BUDGET,"admission_margin":MAXIMUM_ACCELERATION*FORCE_BUDGET-worst,
		"low_assist_fraction":float(low)/float(samples+1),"peak_alpha":peak_alpha,"alpha_admission":MAXIMUM_ANGULAR_ACCELERATION*ANGULAR_BUDGET,
		"touchdown_velocity":_touchdown_velocity.y,"com_local":[_com_local.x,_com_local.y,_com_local.z],
		"tuck_capacity":_stunt_capacity,"head_first":(_flight_start.basis.y.cross(_destination.origin-_flight_start.origin)).dot(_rotation_axis)>0.0 if label=="outbound" else null}

func capture_evaluated(sk: Skeleton3D) -> void:
	_capture_leg_bases(sk)
	if state in ["prepare","landing"]:
		for side in 2: _stunt_grounded[side] = worker._pose.evaluated_grounded[side]
	if state != "prepare": return
	_bones.clear()
	for bone in sk.get_bone_count(): _bones.append(sk.get_bone_pose(bone))
	_root_local = worker.global_transform.affine_inverse() * worker._pose.evaluated_root
	# The retained original tool can be on a toe or a genuinely caught back
	# holder. Clearance captures its actual body pose, never an assumed anchor.
	_tool_local = worker.global_transform.affine_inverse() * (worker.equipped_tool.global_transform if is_instance_valid(worker.equipped_tool) else worker.tool_anchor.global_transform)
	_leg_points.clear()
	var inverse := worker.global_transform.affine_inverse()
	for side in 2:
		_leg_points.append(inverse*worker._pose.evaluated_hips[side])
		_leg_points.append(inverse*worker._pose.evaluated_knees[side])
		var ankle: Vector3=worker._pose.evaluated_soles[side]-worker._pose.evaluated_ankles[side]*Vector3(0,worker._pose._ankle_height[side],0)
		_leg_points.append(inverse*ankle)
	_stunt_forward = (worker.global_basis.inverse()*(-worker._model.global_basis.z)).normalized()
	_capture_holder_bounds()
	_snapshot_ready = true

func advance(delta: float) -> void:
	_watch_release()
	if not active(): return
	# One leader-owned launch puts every cooperative body on the same tick.
	# A later helper callback in that tick must not advance only one arc.
	if state in ["outbound","return"] and _launch_frame==Engine.get_physics_frames(): return
	if not worker.is_available():
		abort("Head pickup interrupted by a native fall")
		_finish(false)
		return
	if not is_instance_valid(part) or not part.is_inside_tree():
		abort("Reserved physical stock removed during the head approach")
	elapsed += delta
	if state == "prepare":
		if _abort_requested:
			_finish(false)
			return
		worker._update_ground(delta)
		# The final published preparation pose already owns the launch parent.
		# Keep the original native ground force/reaction, without steering that
		# parent again between its complete snapshot and native arc admission.
		var gather: Dictionary = _gather_profile()
		worker._move_with_forces(delta,elapsed>=float(gather.crouch) and _snapshot_ready)
		# Launch at the end of the visible gather: crouch, lean, extend.
		if elapsed < float(gather.extend) or not _snapshot_ready: return
		if crew[0]!=worker: return
		if crew.any(func(member: Node) -> bool:return member.head_leap._abort_requested or member.head_leap.state=="failed"):
			for member: Node in crew: member.head_leap._finish(false)
			return
		if not crew.all(func(member: Node) -> bool: return member.head_leap.state=="prepare" and member.head_leap.elapsed>=float(gather.extend) and member.head_leap._snapshot_ready): return
		if not crew.all(func(member: Node) -> bool: return member.is_available() and member.on_ground and member._pose.evaluated_grounded.any(func(value: bool) -> bool:return value)):
			for member: Node in crew:
				member.head_leap.abort("Launch sole lost its native support")
				member.head_leap._finish(false)
			return
		var planning_started_usec := Time.get_ticks_usec()
		var blocker := _plan_outbound()
		if _args.has("--head-stunt-profile"):
			print("HEAD_STUNT_PREFLIGHT_USEC worker=",worker.worker_id," source=",part.part_id," total=",Time.get_ticks_usec()-planning_started_usec," holder_capture_max=",_holder_capture_usec," holder_rebuilds=",_holder_clearance.rebuilds," valid=",_holder_clearance.valid," meshes=",_holder_clearance.mesh_count," native=",_holder_clearance.native_count," seat_solids=",_holder_clearance.seat_prisms," blocker=",blocker)
		if not blocker.is_empty():
			for member: Node in crew:
				member.head_leap.abort(blocker)
				member.head_leap._finish(false)
			return
		for member: Node in crew:
			var controller: RefCounted=member.head_leap
			controller._save_native_settings()
			# One paired push-off: linear impulse plus the angular impulse that
			# seeds the planned half-turn, both reacting on the planted support.
			controller._launch(controller._launch_velocity,member._ground_body,member._ground_point,controller._launch_spin)
			member.action="pickup"
			controller.state="outbound"
			controller.elapsed=0.0
		return
	worker.on_ground = false
	worker.stance_valid = false
	worker.gait_speed = 0.0
	worker.turn_rate = 0.0
	if _abort_requested and state in ["outbound","contact"] and not _return_started:
		# Interrupted: recover bare. While no clear recovery exists during the
		# outbound (e.g. falling onto the stock), keep the admitted dive (custody
		# is impossible once aborted) and retry, then recover from the head pose.
		if crew[0]!=worker: pass
		elif state=="contact" or elapsed>=_bare_retry:
			if _begin_bare_group_return(state=="outbound" and elapsed<_flight_seconds): return
			_bare_retry = elapsed+.1
		if state=="contact":
			_follow(_contact_destination(),Vector3.ZERO)
			return
	if state == "outbound":
		if not _abort_requested and (part.global_position.distance_to(_source_start.origin) > .08 or part.global_basis.orthonormalized().get_rotation_quaternion().angle_to(_source_start.basis.orthonormalized().get_rotation_quaternion()) > .08):
			abort("The actual stock moved; head contact was not made")
			return
		_follow_plan(minf(elapsed,_flight_seconds))
		worker.action_progress = clampf(elapsed/_flight_seconds*.5,0.0,.5)
		if elapsed >= _flight_seconds:
			state = "contact"
			elapsed = 0.0
			_contact_age = 0.0
	elif state == "contact":
		_contact_age = elapsed
		_follow(_contact_destination(),Vector3.ZERO)
		contact_error = _head_point().distance_to(part.global_transform*contact_local+contact_normal*CONTACT_GAP)
		if elapsed > 1.6 and not contact_ready(): abort("Head approach missed the current physical stock face")
	elif state == "return":
		_follow_plan(minf(elapsed,_flight_seconds))
		worker.action_progress = .5+.4*clampf(elapsed/_flight_seconds,0.0,1.0)
		if elapsed >= _flight_seconds:
			state = "landing"
			elapsed = 0.0
			flight_stats.touchdown_plan_velocity = _touchdown_velocity.y
			flight_stats.touchdown_actual_velocity = _velocity(worker).y
			_seed_landing_release()
			worker.action=""
			worker._animation.play("wk_idle",.2)
	elif state == "landing":
		worker._update_ground(delta)
		if _impact_age < .0 and worker.on_ground:
			_impact_age = .0
			# The touchdown is a real impact: its measured speed scales the absorb.
			_impact_speed = maxf(0.0,-(_velocity(worker)-worker.ground_velocity).y)
			_absorb_depth = clampf(.05+.045*_impact_speed+(.03 if _absorb_profile()==CREW_ABSORB else 0.0),.08,.15)
			flight_stats.impact_speed = _impact_speed
			flight_stats.absorb_depth = _absorb_depth
			if _impact_speed>1.0: worker._play_sound(worker.FOOTSTEP,.62+.04*minf(_impact_speed,3.0))
		elif _impact_age >= .0: _impact_age += delta
		_follow(_home,Vector3.ZERO)
		var upright := worker.global_basis.orthonormalized().get_rotation_quaternion().angle_to(_home.basis.orthonormalized().get_rotation_quaternion())<.035
		var settled: bool = worker.on_ground and upright and worker._pose.evaluated_valid and worker._pose.evaluated_grounded.any(func(value: bool) -> bool: return value) and worker.global_position.distance_to(_home.origin)<.2 and _velocity(worker).length()<.5 and worker.angular_velocity.length()<.35
		_settled = _settled+delta if settled else 0.0
		# Hand back once the absorb has bottomed out and is visibly recovering.
		var absorb: Dictionary = _absorb_profile()
		var absorbed := float(absorb["in"])+float(absorb.hold)+.5*float(absorb.recover)
		if _settled >= .18 and (_impact_age < .0 or _impact_age >= absorbed): _finish(not _abort_requested)
		elif elapsed > 3.0:
			abort("Return landing needs clear supported ground")
			# The source is loose at its actual last carried pose. Native movement
			# and ordinary recovery continue; no original launch pose is restored.
			_finish(false)

func contact_ready() -> bool:
	if state != "contact" or _abort_requested or not is_instance_valid(part) or _contact_age<CONTACT_PRESS: return false
	var root := _actual_root()
	var head := root*_head_touch_local
	var point: Vector3 = part.global_transform*contact_local + contact_normal*CONTACT_GAP
	var tolerance := _contact_tolerance()
	contact_error = head.distance_to(point)
	if contact_error>maxf(CONTACT_ERROR,tolerance) or root.basis.y.normalized().dot(-contact_normal)<1.0-pow(tolerance/.43,2.0)*.5 or _velocity(worker).length()>.2 or worker.angular_velocity.length()>.15: return false
	# Test the evaluated actual upper head plane against this source's original
	# native surface, including its real roof footprint. An AABB proximity is
	# never an attachment event. Small stock can touch only part of that plane.
	contact_surface_gap=INF
	contact_surface_penetration=0.0
	for point_on_skin: Vector3 in _roof_samples:
		var surface := root*point_on_skin
		var query := PhysicsRayQueryParameters3D.create(surface+contact_normal*.025,surface-contact_normal*.025,CONTACT_QUERY_BIT)
		var hit := worker.get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty() or hit.collider!=part: continue
		var gap: float=hit.normal.dot(surface-hit.position)
		contact_surface_gap=minf(contact_surface_gap,gap)
		contact_surface_penetration=maxf(contact_surface_penetration,-gap)
	return contact_surface_gap<=tolerance and contact_surface_gap>=-tolerance and contact_surface_penetration<=tolerance and not _stock_support().is_empty()

func _contact_tolerance() -> float:
	# Four float32 coordinate units cover the native/mesh transform arithmetic
	# at Island distances; nearby focused play still needs a half-mm touch.
	var point: Vector3=part.global_position.abs()
	var magnitude := maxf(1.0,maxf(point.x,maxf(point.y,point.z)))
	var unit := pow(2.0,floor(log(magnitude)/log(2.0))-23.0)
	return maxf(.0005,unit*4.0)

func contact_frame() -> Transform3D:
	var root := _actual_root()
	root.origin += root.basis*_head_touch_local
	if crew.size()>1:
		var roots: Array[Transform3D]=[]
		for member: Node in crew: roots.append(member.head_leap._actual_root())
		root=_shared_head_frame(roots)
	return root

func _shared_head_frame(roots: Array[Transform3D]) -> Transform3D:
	var head:=roots[0]
	var centre:=Vector3.ZERO
	for index in roots.size(): centre+=roots[index]*crew[index].head_leap._head_touch_local
	centre/=roots.size()
	var normal:=head.basis.y.normalized()
	var extension:=.0
	# The common finite fixture follows the outer supporting roof, not the
	# average height which could sweep stock through the higher partner. This
	# maximum of continuous skin/body positions is itself continuous; contact
	# captures its current frame without changing the original source pose.
	for index in roots.size():
		for x: float in [-.38,.38]:
			for z: float in [-.38,.38]: extension=maxf(extension,normal.dot(roots[index]*Vector3(x,crew[index].head_leap._head_height,z)-centre))
	head.origin=centre+normal*extension
	return head

static func attach_group(source: RigidBody3D, members: Array) -> bool:
	if members.is_empty() or not members.all(func(member: Node) -> bool: return member.head_leap.part==source and member.head_leap.contact_ready()): return false
	var leader: Node = members[0]
	var before := source.global_transform
	var source_velocity := _velocity(source)
	var local: Transform3D = leader.head_leap.contact_frame().affine_inverse()*before
	var share: float = source.mass/members.size()
	# Plan every cooperative trajectory before changing any source custody.
	# Their shared fixture follows the evaluated midpoint and leader orientation;
	# each worker's real contact face stays beneath the same original body.
	for member: Node in members:
		var controller: RefCounted = member.head_leap
		controller._cargo_local = local
		controller._planning_return = true
		controller._flight_start = member.global_transform
		controller._destination = controller._home
		controller._com_local = controller._loaded_com_local(source,share)
	var heavy: bool = members.size()>1 or not leader.head_leap._small_stock_timing()
	var planned := false
	var failures: Array[String]=[]
	# Rewind about the outbound axis first: the head pushes off the stock and
	# the feet lead back toward the launch place. The opposite continuous
	# branch (load-upward-first) and the original long timings stay fallbacks.
	# All cooperative bodies select the same world axis branch.
	for tier: Array in [[CREW_RETURN if heavy else SOLO_RETURN,"brisk"],[LONG_RETURN,"long"]]:
		for direction: float in [-1.0,1.0]:
			for member: Node in members:
				var controller: RefCounted = member.head_leap
				controller._configure_rotation(controller._outbound_axis*direction)
			for candidate: Array in tier[0]:
				var shaped := true
				for member: Node in members:
					if not member.head_leap._plan_flight(float(candidate[0]),float(candidate[1]),true,str(tier[1])):
						shaped=false
						failures.append(member.worker_id+": "+member.head_leap.arc_failure)
						break
				if not shaped: continue
				if members.all(func(member: Node) -> bool: return member.head_leap._arc_clear(true)):
					planned=true
					break
				for member: Node in members:
					if not member.head_leap.arc_failure.is_empty(): failures.append(member.worker_id+": "+member.head_leap.arc_failure)
			if planned: break
		if planned: break
	if not planned: print("HEAD_RETURN_PREFLIGHT_REASONS ",failures.slice(0,8))

	for member: Node in members: member.head_leap._planning_return=false
	if not planned:
		for member: Node in members: member.head_leap.abort("No clear original-stock return arc; source remains at its actual head-contact pose: "+member.head_leap.arc_failure)
		return false
	var support: Dictionary = leader.head_leap._stock_support()
	# Transfer the SAME finite body's incoming momentum once. Source custody
	# changes at geometric head contact without relocating its pose or basis.
	leader.head_anchor.global_transform = leader.head_leap.contact_frame()
	source.set_carried_at_pose(leader.head_anchor)
	for member: Node in members:
		var old_velocity := _velocity(member)
		member.set_cargo(source.mass/members.size())
		member.apply_central_impulse((source_velocity-old_velocity)*(source.mass/members.size()))
		member.head_leap.contacted = true
		member.head_leap._cargo_local = local
		member.head_leap.source_before_contact = before
		member.head_leap.source_after_contact = source.global_transform
		member.head_leap.flight_stats.contact_dwell = member.head_leap._contact_age
		member.head_leap._record_plan("return")
	for member: Node in members:
		member.head_leap._return_started=true
		member.head_leap._launch(member.head_leap._launch_velocity,support.get("collider") as RigidBody3D,support.get("position",member.global_position),member.head_leap._launch_spin)
		member.head_leap.state="return"
		member.head_leap.elapsed=0.0
	return true

const PLAN_FIELDS := ["_flight_start","_destination","_launch_velocity","_flight_seconds","_horizontal_seconds","_com_local","_com_horizontal","_com_vertical",
	"_spin","_spin_seconds","_spin_delay","_spin_hold","_spin_start","_rotation_axis","_rotation_angle","_touchdown_velocity","_launch_spin","_plan_tier"]

func _plan_snapshot() -> Dictionary:
	var snapshot := {}
	for field: String in PLAN_FIELDS: snapshot[field] = get(field)
	return snapshot

func _restore_plan(snapshot: Dictionary) -> void:
	for field: String in snapshot: set(field,snapshot[field])

func _begin_bare_group_return(may_defer := false) -> bool:
	# Capture every actual interrupted source before any cooperative recovery
	# query. No impulse or velocity reset is needed while already airborne.
	# Returns false only when deferred: the admitted outbound plan is restored.
	var snapshots: Array[Dictionary]=[]
	for member: Node in crew:
		var controller: RefCounted=member.head_leap
		snapshots.append(controller._plan_snapshot())
		controller._planning_return=true
		# Restart from the last ACTUAL final published limbs. The same finite
		# interpolation feeds both preflight and posing, before any return force.
		var published: SkeletonModifier3D = member._pose
		var inverse: Transform3D = published.evaluated_worker.affine_inverse()
		controller._restart_leg_points.clear()
		controller._restart_ankles.clear()
		for side in 2:
			controller._restart_leg_points.append(inverse*published.evaluated_hips[side])
			controller._restart_leg_points.append(inverse*published.evaluated_knees[side])
			controller._restart_leg_points.append(inverse*(published.evaluated_soles[side]-published.evaluated_ankles[side]*Vector3(0,published._ankle_height[side],0)))
			controller._restart_ankles.append(published.evaluated_worker.basis.inverse()*published.evaluated_ankles[side])
		controller._flight_start=member.global_transform
		controller._destination=controller._home
		controller._com_local=controller._native_com_local()
	var planned := false
	# The current native COM velocity and spin continue (no impulse); the
	# assisted recovery only brakes and turns back to the supported home pose.
	var failures: Array[String]=[]
	# Either continuous branch back to upright: the shortest rewind, or carrying
	# the existing spin on round. A crew keeps one shared world axis.
	for branch: float in [1.0,-1.0]:
		for seconds: float in [.9,1.1,1.25,1.4,1.6,1.8,2.4,3.0]:
			var shaped := true
			for member: Node in crew:
				var controller: RefCounted=member.head_leap
				controller._configure_rotation(_crew_axis if crew.size()>1 else Vector3.ZERO,branch)
				if crew.size()>1 and branch<0.0: controller._configure_rotation(-_crew_axis)
				if not controller._plan_flight(seconds,0.0,true,"bare",_velocity(member)):
					shaped=false
					failures.append("%.2fs/%d %s" % [seconds,int(branch),controller.arc_failure])
			if shaped and crew.all(func(member: Node) -> bool:return member.head_leap._arc_clear(false)):
				planned=true
				break
			for member: Node in crew:
				if shaped and not member.head_leap.arc_failure.is_empty(): failures.append("%.2fs/%d %s" % [seconds,int(branch),member.head_leap.arc_failure])
		if planned: break
	if not planned and not may_defer: print("HEAD_BARE_RETURN_REASONS ",failures.slice(0,10))
	if not planned and may_defer:
		for index in crew.size():
			var controller: RefCounted=crew[index].head_leap
			controller._planning_return=false
			controller._restart_leg_points.clear()
			controller._restart_ankles.clear()
			controller._restore_plan(snapshots[index])
		return false
	for member: Node in crew:
		var controller: RefCounted=member.head_leap
		controller._planning_return=false
		if planned:
			controller._return_started=true
			controller._record_plan("bare_return")
			controller.state="return"
			controller.elapsed=0.0
			controller._launch_frame=Engine.get_physics_frames()
		else:
			controller._return_started=true
			controller._finish(false)
			if member.ragdoll and not member.ragdoll.is_down(): member.ragdoll.knock_down()
	return true

func _launch(velocity: Vector3, support: RigidBody3D, point: Vector3, spin := Vector3.ZERO) -> void:
	_launch_frame=Engine.get_physics_frames()
	var impulse := (velocity-_velocity(worker))*worker.mass
	impulse = impulse.limit_length(worker.mass*MAXIMUM_SPEED)
	worker.apply_central_impulse(impulse)
	if is_instance_valid(support): support.apply_impulse(-impulse,point-support.global_position)
	# The push is off-centre: its angular part seeds the planned spin. The same
	# finite angular impulse reacts on a movable support (paired, like the toss).
	var turn := (spin-worker.angular_velocity).limit_length(MAXIMUM_SPIN)
	var angular := Vector3.ZERO
	if turn.length_squared()>.000001:
		# Jolt's own inertia once the flight torso is live (the cargo share is
		# then included); the analytic flight box before the swap is applied.
		angular = (_inertia_world() if _native_settings_saved and state!="prepare" else _flight_inertia_world())*turn
		worker.apply_torque_impulse(angular)
		if is_instance_valid(support): support.apply_torque_impulse(-angular)
	flight_stats["launch_outbound" if state=="prepare" else "launch_return"]={"impulse":impulse.length(),"angular_impulse":angular.length(),"spin":turn.length()}
	worker.on_ground = false
	worker.stance_valid = false

func _configure_rotation(preferred_axis := Vector3.ZERO, branch := 1.0) -> void:
	var rotation := (_destination.basis.orthonormalized().get_rotation_quaternion()*_flight_start.basis.orthonormalized().get_rotation_quaternion().inverse()).normalized()
	if rotation.w<0.0: rotation=-rotation
	var vector := Vector3(rotation.x,rotation.y,rotation.z)
	_rotation_axis=vector.normalized() if vector.length_squared()>.000001 else (preferred_axis.normalized() if preferred_axis.length_squared()>.5 else Vector3.RIGHT)
	_rotation_angle=2.0*atan2(vector.length(),maxf(rotation.w,.000001))
	var alternative := _rotation_axis.dot(preferred_axis)<0.0 if preferred_axis.length_squared()>.5 else branch<0.0
	if alternative and _rotation_angle>.01:
		_rotation_axis=-_rotation_axis
		_rotation_angle=TAU-_rotation_angle

func _spin_angle(time: float, order: int) -> float:
	if _spin_delay>0.0 and time<_spin_delay:
		# Recovery lift: the existing spin decays linearly to rest.
		var t := maxf(time,0.0)
		if order==0: return _spin_start*(t-t*t/(2.0*_spin_delay))
		if order==1: return _spin_start*(1.0-t/_spin_delay)
		return -_spin_start/_spin_delay
	return _quintic_at(_spin,clampf(time-_spin_delay,0.0,_spin_seconds),order)

func _planned_com(time: float, order: int) -> Vector3:
	# Clamped evaluation holds each channel's end state (rest, or touchdown motion).
	var across := clampf(time,0.0,_horizontal_seconds)
	var up := clampf(time,0.0,_flight_seconds)
	if _com_horizontal.size()!=2: return _destination*_com_local if order==0 else Vector3.ZERO
	return Vector3(_quintic_at(_com_horizontal[0],across,order),_quintic_at(_com_vertical,up,order),_quintic_at(_com_horizontal[1],across,order))

func _planned_body(time: float) -> Transform3D:
	# Rotation about the planned centre of mass: the cube spins, it does not orbit.
	var basis := Basis(_rotation_axis,_spin_angle(time,0))*_flight_start.basis.orthonormalized()
	return Transform3D(basis,_planned_com(time,0)-basis*_com_local)

func _planned_group_head(time: float) -> Transform3D:
	var leader: RefCounted = crew[0].head_leap
	var head: Transform3D = leader._planned_body(time)*leader._root_local
	var roots: Array[Transform3D]=[]
	for member: Node in crew:
		var cube: Transform3D = member.head_leap._planned_body(time)*member.head_leap._root_local
		roots.append(cube)
	if crew.size()>1: return _shared_head_frame(roots)
	head.origin+=head.basis*leader._head_touch_local
	return head

func _planned_angular_velocity(time: float) -> Vector3:
	return _rotation_axis*_spin_angle(time,1)

func _planned_angular_acceleration(time: float) -> Vector3:
	return _rotation_axis*_spin_angle(time,2)

func _planned_com_acceleration_from_body(time: float,body: Transform3D,centre: Vector3) -> Vector3:
	# Acceleration of a body point `centre`; the planned COM itself needs no
	# rotational term because the turn is about it.
	var offset := body.basis*(centre-_com_local)
	var omega := _planned_angular_velocity(time)
	return _planned_com(time,2)+_planned_angular_acceleration(time).cross(offset)+omega.cross(omega.cross(offset))

func _follow_plan(time: float) -> void:
	# Jolt integrates semi-implicitly (velocity, then position). A body that
	# is on the plan at t carries the plan's mid-step velocity p'(t - dt/2);
	# with the p''(t) feed-forward the discrete flight then stays on the
	# continuous plan instead of drifting a*dt*t/2 behind it.
	var lag := maxf(time-.5/float(Engine.physics_ticks_per_second),0.0)
	_follow(_planned_body(time),_planned_com(lag,1),_planned_com(time,2),_planned_angular_velocity(lag),_planned_angular_acceleration(time))

func _flight_inertia_world() -> Basis:
	# Jolt's inertia of the swapped flight torso: a uniform box of the current
	# mass about its own centre (measured in Jolt: .087 m / .097 m / .086 m kg·m²).
	# Used for the launch impulse, before the native shape swap is applied.
	var size := Vector3(.76,_head_height*2.0,.76)
	var moments := Vector3(size.y*size.y+size.z*size.z,size.x*size.x+size.z*size.z,size.x*size.x+size.y*size.y)*worker.mass/12.0
	var frame := (worker.global_basis*_root_local.basis).orthonormalized()
	return frame*Basis.from_scale(moments)*frame.transposed()

func _inertia_world() -> Basis:
	var direct := PhysicsServer3D.body_get_direct_state(worker.get_rid())
	if direct:
		var inverse: Basis = direct.inverse_inertia_tensor
		if absf(inverse.determinant())>1e-9: return inverse.inverse()
	return _flight_inertia_world()

func _follow(goal: Transform3D, com_velocity: Vector3, com_acceleration := Vector3.ZERO, angular_velocity := Vector3.ZERO, angular_acceleration := Vector3.ZERO) -> void:
	var direct := PhysicsServer3D.body_get_direct_state(worker.get_rid())
	var com: Vector3=direct.center_of_mass_local if direct else _com_local
	# Track the ACTUAL native COM point of the planned body (cargo/torso swaps
	# move it slightly from the planned COM), with its exact rigid motion.
	var offset := goal.basis*(com-_com_local)
	var position_error := goal*com-worker.global_transform*com
	var wanted_velocity := com_velocity+angular_velocity.cross(offset)
	var wanted_acceleration := com_acceleration+angular_acceleration.cross(offset)+angular_velocity.cross(angular_velocity.cross(offset))
	# Supported landing uses the existing opposite leg/ground spring reaction.
	# In-air gravity assistance must not double that real support force.
	var gravity_assist := .0 if state=="landing" and worker.on_ground else GRAVITY
	var command := position_error*36.0+(wanted_velocity-_velocity(worker))*12.0+wanted_acceleration+Vector3.UP*gravity_assist
	var acceleration := command.limit_length(MAXIMUM_ACCELERATION)
	worker.apply_central_force(acceleration*worker.mass)
	var error := (goal.basis.orthonormalized().get_rotation_quaternion()*worker.global_basis.orthonormalized().get_rotation_quaternion().inverse()).normalized()
	if error.w<0.0: error=-error
	var axis := Vector3(error.x,error.y,error.z)
	var angle := 2.0*atan2(axis.length(),maxf(error.w,.000001))
	var rotation_error := axis.normalized()*angle if axis.length_squared()>.000001 else Vector3.ZERO
	# Angular-acceleration feed-forward removes the PD lag; the command is
	# capped at 24 rad/s² of the body's ACTUAL Jolt inertia (not an estimate).
	var alpha := (rotation_error*60.0+(angular_velocity-worker.angular_velocity)*12.0+angular_acceleration).limit_length(MAXIMUM_ANGULAR_ACCELERATION)
	var inertia := _inertia_world()
	worker.apply_torque(inertia*alpha)
	if state in ["outbound","contact","return"]:
		flight_stats.peak_force = maxf(float(flight_stats.get("peak_force",0.0)),acceleration.length()*worker.mass)
		flight_stats.force_cap = MAXIMUM_ACCELERATION*worker.mass
		flight_stats.peak_alpha = maxf(float(flight_stats.get("peak_alpha",0.0)),alpha.length())
		flight_stats.peak_torque = maxf(float(flight_stats.get("peak_torque",0.0)),(inertia*alpha).length())
		flight_stats.alpha_cap = MAXIMUM_ANGULAR_ACCELERATION
		if command.length()>MAXIMUM_ACCELERATION+.001: flight_stats.force_saturated_ticks = int(flight_stats.get("force_saturated_ticks",0))+1
		flight_stats.inertia_per_mass = (inertia.x.x+inertia.y.y+inertia.z.z)/(3.0*worker.mass)

func _arc_clear(with_cargo: bool) -> bool:
	arc_failure=""
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask = 1
	var exclusions: Array[RID]=worker.query_exclusions()
	for member: Node in crew: exclusions.append(member.get_rid())
	if is_instance_valid(part): exclusions.append(part.get_rid())
	query.exclude = exclusions
	var shape := BoxShape3D.new()
	shape.size = Vector3(.80,.70,.80)
	query.shape = shape
	var space := worker.get_world_3d().direct_space_state
	var source_query := PhysicsShapeQueryParameters3D.new()
	source_query.collision_mask=CONTACT_QUERY_BIT
	# The target remains an obstacle throughout the approach. Its exact native
	# material is queried separately from the inflated world-clearance proxies.
	# Only the true roof-plane endpoint may approach within the contact gap.
	source_query.exclude=worker.query_exclusions()
	var steps := ceili(_flight_seconds*30.0)
	# The world and actual native COM cannot advance inside this synchronous
	# admission. Reuse precisely the same computed finite frames/accelerations
	# in its second pass; all original samples and native queries still run.
	# The planned COM is the native COM this body has in that flight (the return
	# predicts the shared cargo); its admission is the unchanged |a + g| <= .9 2g.
	var centre: Vector3=_com_local
	var bodies: Array[Transform3D]=[]
	var accelerations:=PackedFloat64Array()
	for step in range(steps+1):
		var time := _flight_seconds*float(step)/steps
		var body := _planned_body(time)
		var acceleration := (_planned_com_acceleration_from_body(time,body,centre)+Vector3.UP*GRAVITY).length()
		bodies.append(body)
		accelerations.append(acceleration)
		if acceleration>MAXIMUM_ACCELERATION*FORCE_BUDGET:
			arc_failure="force budget at %.3fs: %.3fm/s²" % [time,acceleration]
			return false
	# One exact geometry validation per synchronous arc; samples reuse
	# its original source-local boxes without walking the scene again.
	var gun_head_boxes: Array[Dictionary] = []
	if with_cargo and _gun_head_geometry_current(): gun_head_boxes = _gun_head_geometry.boxes
	var limb_shape := SphereShape3D.new()
	limb_shape.radius=.085
	var torso := BoxShape3D.new()
	torso.size=Vector3(.76,_head_height*2.0,.76)
	var tool_shape := BoxShape3D.new()
	if is_instance_valid(worker.equipped_tool): tool_shape.size = _tool_bounds.size+Vector3.ONE*.025
	var holder_shape := BoxShape3D.new()
	if _holder_bounds.size.length_squared()>.000001: holder_shape.size=_holder_bounds.size+Vector3.ONE*.015
	var cargo_shape := BoxShape3D.new()
	cargo_shape.size = _stock_bounds.size+Vector3.ONE*.03
	for step in range(1,steps+1):
		var time := _flight_seconds*float(step)/steps
		# Leave force for measured tracking error instead of accepting an arc
		# whose analytic acceleration already saturates the native controller.
		if accelerations[step]>MAXIMUM_ACCELERATION*FORCE_BUDGET: return false
		var body: Transform3D=bodies[step]
		var cube := body*_root_local
		var legs := _planned_leg_points(time)
		if not _crew_clear(time,with_cargo,gun_head_boxes,body,legs): return false
		query.transform = cube
		if not space.intersect_shape(query,1).is_empty(): arc_failure="head obstruction at %.3fs centre %s" % [time,cube.origin]; return false
		query.shape=limb_shape
		for side in 2:
			for link in 2:
				var a: Vector3=body*legs[side*3+link]
				var b: Vector3=body*legs[side*3+link+1]
				for fraction: float in [.0,.25,.5,.75,1.0]:
					query.transform=Transform3D(Basis.IDENTITY,a.lerp(b,fraction))
					if not space.intersect_shape(query,1).is_empty(): arc_failure="leg %d/%d obstruction at %.3fs centre %s" % [side,link,time,query.transform.origin]; return false
		# Check the complete toe-held tool and finite flight torso.
		query.shape=torso
		query.transform=body*_root_local
		if not space.intersect_shape(query,1).is_empty(): arc_failure="torso obstruction at %.3fs" % time; return false
		if not with_cargo:
			source_query.shape=torso
			source_query.transform=query.transform
			if not space.intersect_shape(source_query,1).is_empty(): arc_failure="original stock intersects head/body before contact at %.3fs" % time; return false
			source_query.shape=limb_shape
			for side in 2:
				for link in 2:
					var a: Vector3=body*legs[side*3+link]
					var b: Vector3=body*legs[side*3+link+1]
					for fraction: float in [.0,.25,.5,.75,1.0]:
						source_query.transform=Transform3D(Basis.IDENTITY,a.lerp(b,fraction))
						if not space.intersect_shape(source_query,1).is_empty(): arc_failure="original stock intersects leg before contact at %.3fs" % time; return false
		if is_instance_valid(worker.equipped_tool):
			query.shape = tool_shape
			query.transform = body*_tool_local*Transform3D(Basis.IDENTITY,_tool_bounds.get_center())
			if not space.intersect_shape(query,1).is_empty(): arc_failure="tool obstruction at %.3fs" % time; return false
			if not with_cargo:
				source_query.shape=tool_shape
				source_query.transform=query.transform
				if not space.intersect_shape(source_query,1).is_empty(): arc_failure="original stock intersects retained tool before contact at %.3fs" % time; return false
		if _holder_bounds.size.length_squared()>.000001:
			query.shape=holder_shape
			query.transform=body*Transform3D(Basis.IDENTITY,_holder_bounds.get_center())
			if not space.intersect_shape(query,1).is_empty(): arc_failure="original back holder obstruction at %.3fs" % time; return false
			if not with_cargo:
				source_query.shape=holder_shape
				source_query.transform=query.transform
				if not space.intersect_shape(source_query,1).is_empty(): arc_failure="original stock intersects permanent back holder before head contact at %.3fs" % time; return false
		if with_cargo:
			var head := _planned_group_head(_flight_seconds*float(step)/steps)
			query.shape = cargo_shape
			query.transform = head*_cargo_local*Transform3D(Basis.IDENTITY,_stock_bounds.get_center())
			var stock_hits: Array=space.intersect_shape(query,1)
			if not stock_hits.is_empty():
				if "--easy-island-removed-wheel-probe" in _args:
					_observe_cargo_refusal(time,head*_cargo_local,query,stock_hits,space)
				# A wheel's empty rectangular corners are not physical cargo. Keep
				# the fast padded-box admission; only a rejection needs the exact
				# enabled original geometry, with the same 15 mm face clearance.
				if not _original_wheel_cargo_clear(head*_cargo_local,query,space):
					arc_failure="stock obstruction at %.3fs" % time
					return false
		query.shape = shape
	return true

static func _boxes_overlap(a: Transform3D, a_size: Vector3, b: Transform3D, b_size: Vector3) -> bool:
	var axes: Array[Vector3]=[a.basis.x,a.basis.y,a.basis.z,b.basis.x,b.basis.y,b.basis.z]
	for aa in 3:
		for bb in 3: axes.append(a.basis[aa].cross(b.basis[bb]))
	var apart := b.origin-a.origin
	for axis: Vector3 in axes:
		if axis.length_squared()<.000001: continue
		axis=axis.normalized()
		var radius_a := .0
		var radius_b := .0
		for index in 3:
			radius_a+=absf(axis.dot(a.basis[index]))*a_size[index]*.5
			radius_b+=absf(axis.dot(b.basis[index]))*b_size[index]*.5
		if absf(axis.dot(apart))>=radius_a+radius_b-.0005: return false
	return true

static func _segment_box(a: Vector3,b: Vector3,box: Transform3D,size: Vector3,radius: float) -> bool:
	# Conservative finite capsule versus full oriented box, covering the whole
	# link rather than leaving holes between joint/sample spheres.
	var inverse:=box.affine_inverse()
	var start: Vector3=inverse*a
	var direction: Vector3=inverse*b-start
	var half:=size*.5+Vector3.ONE*radius
	var low:=.0
	var high:=1.0
	for axis in 3:
		if absf(direction[axis])<.000001:
			if absf(start[axis])>half[axis]: return false
		else:
			var near:=(-half[axis]-start[axis])/direction[axis]
			var far:=(half[axis]-start[axis])/direction[axis]
			low=maxf(low,minf(near,far))
			high=minf(high,maxf(near,far))
			if low>high: return false
	return true

static func _segment_distance(a: Vector3,b: Vector3,c: Vector3,d: Vector3) -> float:
	var ab:=b-a
	var cd:=d-c
	var ac:=a-c
	var aa:=ab.length_squared()
	var cc:=cd.length_squared()
	var coupling:=ab.dot(cd)
	var e:=cd.dot(ac)
	var f:=ab.dot(ac)
	var denominator:=aa*cc-coupling*coupling
	var s:=clampf((coupling*e-cc*f)/denominator,0.0,1.0) if denominator>.000001 else .0
	var t:=clampf((coupling*s+e)/cc,0.0,1.0) if cc>.000001 else .0
	if aa>.000001: s=clampf((coupling*t-f)/aa,0.0,1.0)
	return (a+ab*s).distance_to(c+cd*t)

func _finite_wheel_shape(shape: Shape3D) -> bool:
	if shape is CylinderShape3D:
		return is_finite(shape.radius) and is_finite(shape.height) and shape.radius>0.0 and shape.height>0.0
	if shape is BoxShape3D:
		return shape.size.is_finite() and shape.size.x>0.0 and shape.size.y>0.0 and shape.size.z>0.0
	if shape is ConvexPolygonShape3D:
		if shape.points.size()<4: return false
		var bounds:=AABB(shape.points[0],Vector3.ZERO)
		for point: Vector3 in shape.points:
			if not point.is_finite(): return false
			bounds=bounds.expand(point)
		return bounds.size.x>0.0 and bounds.size.y>0.0 and bounds.size.z>0.0
	return false

func _original_wheel_cargo_clear(cargo_pose: Transform3D,box_query: PhysicsShapeQueryParameters3D,space: PhysicsDirectSpaceState3D) -> bool:
	if not is_instance_valid(part) or part.kind!="wheel" or not cargo_pose.is_finite(): return false
	var native_query:=PhysicsShapeQueryParameters3D.new()
	native_query.collision_mask=box_query.collision_mask
	native_query.exclude=box_query.exclude
	native_query.margin=.015
	var enabled:=0
	var source_rid: RID=part.get_rid()
	for index: int in PhysicsServer3D.body_get_shape_count(source_rid):
		var owner: int=part.shape_find_owner(index)
		if part.is_shape_owner_disabled(owner): continue
		var shape_rid: RID=PhysicsServer3D.body_get_shape(source_rid,index)
		if not shape_rid.is_valid(): return false
		var resource: Shape3D
		for owner_index: int in part.shape_owner_get_shape_count(owner):
			var candidate: Shape3D=part.shape_owner_get_shape(owner,owner_index)
			if candidate!=null and candidate.get_rid()==shape_rid:
				resource=candidate
				break
		if resource==null or not _finite_wheel_shape(resource): return false
		var local: Transform3D=PhysicsServer3D.body_get_shape_transform(source_rid,index)
		if not local.is_finite() or local.basis.determinant()<=0.0: return false
		native_query.shape_rid=shape_rid
		native_query.transform=cargo_pose*local
		if not native_query.transform.is_finite(): return false
		if not space.intersect_shape(native_query,1).is_empty(): return false
		enabled+=1
	return enabled>0

func _arc_hit_facts(hits: Array) -> Array[Dictionary]:
	var result: Array[Dictionary]=[]
	for hit: Dictionary in hits:
		var collider: Variant=hit.get("collider")
		result.append({"body":str(collider.get_path()) if is_instance_valid(collider) and collider is Node else str(collider),
			"rid":str(hit.get("rid")),"shape":hit.get("shape"),"part_id":str(collider.get("part_id")) if is_instance_valid(collider) else "",
			"stored":collider.get_meta(&"stored",false) if is_instance_valid(collider) else null})
	return result

func _observe_cargo_refusal(time: float,cargo_pose: Transform3D,query: PhysicsShapeQueryParameters3D,hits: Array,space: PhysicsDirectSpaceState3D) -> void:
	# Read-only causal comparison at the EXACT rejected original cargo pose.
	# Every production guard/admission result above remains unchanged.
	if not is_instance_valid(part) or not part.is_inside_tree() or _cargo_refusal_rows>=256: return
	var source_rid: RID=part.get_rid()
	var assembly_id: int=part.assembly.get_instance_id() if is_instance_valid(part.assembly) else 0
	var state_key: String=str([source_rid,bool(part.installed),assembly_id,bool(part.get_meta(&"stored",false))])
	var state_rows: int=int(_cargo_refusal_state_rows.get(state_key,0))
	if state_rows>=8: return
	_cargo_refusal_state_rows[state_key]=state_rows+1
	_cargo_refusal_rows+=1
	var native_samples: Array[Dictionary]=[]
	var native_query:=PhysicsShapeQueryParameters3D.new()
	native_query.collision_mask=query.collision_mask
	native_query.exclude=query.exclude
	# Same 15 mm face clearance as the production box's 30 mm total padding.
	# Use all ENABLED original native shapes without modifying any resource.
	native_query.margin=.015
	for shape_index: int in PhysicsServer3D.body_get_shape_count(source_rid):
		if part.is_shape_owner_disabled(part.shape_find_owner(shape_index)): continue
		var shape_rid: RID=PhysicsServer3D.body_get_shape(source_rid,shape_index)
		var local: Transform3D=PhysicsServer3D.body_get_shape_transform(source_rid,shape_index)
		native_query.shape_rid=shape_rid
		native_query.transform=cargo_pose*local
		var native_hits: Array=space.intersect_shape(native_query,1)
		native_samples.append({"index":shape_index,"shape_rid":str(shape_rid),"shape_type":PhysicsServer3D.shape_get_type(shape_rid),
			"local":part.encode_transform(local),"planned":part.encode_transform(native_query.transform),"margin":native_query.margin,
			"hits":_arc_hit_facts(native_hits)})
	var native:=PhysicsServer3D.body_get_direct_state(source_rid)
	print("HEAD_CARGO_REFUSAL ",JSON.stringify({"scope":"read-only same-pose comparison at the rejected padded cargo box",
		"worker":worker.worker_id,"job":worker.current_job_id,"source":part.part_id,"kind":part.kind,"source_instance":part.get_instance_id(),
		"source_installed":part.installed,"source_assembly_id":assembly_id,"source_stored":part.get_meta(&"stored",false),"source_state_sample":state_rows+1,
		"source_rid":str(source_rid),"source_mass":part.mass,"source_actual":part.encode_transform(part.global_transform),
		"source_native":part.encode_transform(native.transform) if native else null,"source_native_linear":part.encode_vector(native.linear_velocity) if native else null,
		"source_native_angular":part.encode_vector(native.angular_velocity) if native else null,"source_carrier":str(part.carrier),
		"worker_pose":part.encode_transform(worker.global_transform),"worker_ground":part.encode_vector(worker._ground_point),"worker_on_ground":worker.on_ground,
		"time":time,"flight_seconds":_flight_seconds,"rotation_axis":part.encode_vector(_rotation_axis),"rotation_angle":_rotation_angle,
		"cargo_pose":part.encode_transform(cargo_pose),"box_transform":part.encode_transform(query.transform),"box_size":part.encode_vector(_stock_bounds.size+Vector3.ONE*.03),
		"production_hits":_arc_hit_facts(hits),"native_shape_count":PhysicsServer3D.body_get_shape_count(source_rid),"enabled_native_samples":native_samples,
		"native_same_pose_all_clear":not native_samples.is_empty() and native_samples.all(func(row:Dictionary)->bool:return row.hits.is_empty())}))


static func _gun_constituent_box_valid(pose: Transform3D, size: Vector3, native: bool) -> bool:
	var determinant := pose.basis.determinant()
	if not pose.is_finite() or not is_finite(determinant) or determinant <= 0.0 or not size.is_finite(): return false
	if native:
		return size.x > 0.0 and size.y > 0.0 and size.z > 0.0 and pose.basis.is_equal_approx(pose.basis.orthonormalized())
	return size.x >= 0.0 and size.y >= 0.0 and size.z >= 0.0 \
		and absf(pose.basis.x.normalized().dot(pose.basis.y.normalized())) < .00001 \
		and absf(pose.basis.x.normalized().dot(pose.basis.z.normalized())) < .00001 \
		and absf(pose.basis.y.normalized().dot(pose.basis.z.normalized())) < .00001

func _capture_gun_head_constituents() -> void:
	_gun_head_geometry.clear()
	if crew.size() != 1 or part.kind != "gun" or not is_instance_valid(part.visual): return
	var source_rid: RID = part.get_rid()
	if not source_rid.is_valid(): return
	var native_shapes: Array[Dictionary] = []
	var boxes: Array[Dictionary] = []
	var enabled := 0
	for index: int in PhysicsServer3D.body_get_shape_count(source_rid):
		var owner: int = part.shape_find_owner(index)
		var disabled: bool = part.is_shape_owner_disabled(owner)
		var shape_rid: RID = PhysicsServer3D.body_get_shape(source_rid,index)
		var local: Transform3D = PhysicsServer3D.body_get_shape_transform(source_rid,index)
		var resource: Shape3D
		for owner_index: int in part.shape_owner_get_shape_count(owner):
			var candidate: Shape3D = part.shape_owner_get_shape(owner,owner_index)
			if candidate != null and candidate.get_rid() == shape_rid:
				resource = candidate
				break
		var box_shape := resource as BoxShape3D
		if not disabled:
			if not shape_rid.is_valid() or box_shape == null or not _gun_constituent_box_valid(local,box_shape.size,true) \
				or PhysicsServer3D.shape_get_type(shape_rid) != PhysicsServer3D.SHAPE_BOX \
				or PhysicsServer3D.shape_get_data(shape_rid) != box_shape.size*.5: return
			boxes.append({"pose":local,"size":box_shape.size})
			enabled += 1
		native_shapes.append({"owner":owner,"disabled":disabled,"rid":shape_rid,"local":local,
			"resource":resource,"size":box_shape.size if box_shape else Vector3.ZERO})
	if enabled == 0: return
	var nodes: Array[Dictionary] = []
	var meshes: Array[Dictionary] = []
	var pending: Array[Node] = [part.visual]
	var visual_count := 0
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		# Unknown MultiMesh envelopes keep the original refusal.
		if node is MultiMeshInstance3D: return
		nodes.append({"node":node,"parent":node.get_parent(),"children":node.get_child_count(true)})
		pending.append_array(node.get_children(true))
		if node is MeshInstance3D:
			var local: Transform3D = StockBounds._local_pose(part,node)
			var box: AABB = node.mesh.get_aabb() if node.mesh != null else AABB()
			meshes.append({"node":node,"resource":node.mesh,"local":local,"box":box})
			if node.mesh == null: continue
			var pose := local*Transform3D(Basis.IDENTITY,box.get_center())
			if not box.position.is_finite() or not _gun_constituent_box_valid(pose,box.size,false): return
			boxes.append({"pose":pose,"size":box.size})
			visual_count += 1
	if visual_count == 0: return
	_gun_head_geometry = {"source":part,"rid":source_rid,"visual":part.visual,
		"native":native_shapes,"nodes":nodes,"meshes":meshes,"boxes":boxes}

func _gun_head_geometry_current() -> bool:
	if _gun_head_geometry.is_empty() or not is_instance_valid(part) or crew.size() != 1 or part.kind != "gun": return false
	if part != _gun_head_geometry.source or part.get_rid() != _gun_head_geometry.rid \
		or not is_instance_valid(part.visual) or part.visual != _gun_head_geometry.visual \
		or not part.global_basis.get_scale().is_equal_approx(Vector3.ONE): return false
	var source_rid: RID = part.get_rid()
	if PhysicsServer3D.body_get_shape_count(source_rid) != _gun_head_geometry.native.size(): return false
	for index: int in _gun_head_geometry.native.size():
		var saved: Dictionary = _gun_head_geometry.native[index]
		if part.shape_find_owner(index) != saved.owner or part.is_shape_owner_disabled(saved.owner) != saved.disabled \
			or PhysicsServer3D.body_get_shape(source_rid,index) != saved.rid \
			or PhysicsServer3D.body_get_shape_transform(source_rid,index) != saved.local: return false
		if not saved.disabled:
			var resource: Variant = saved.resource
			if not is_instance_valid(resource) or not resource is BoxShape3D \
				or resource.get_rid() != saved.rid or resource.size != saved.size \
				or PhysicsServer3D.shape_get_type(saved.rid) != PhysicsServer3D.SHAPE_BOX \
				or PhysicsServer3D.shape_get_data(saved.rid) != saved.size*.5: return false
	for saved: Dictionary in _gun_head_geometry.nodes:
		var node: Variant = saved.node
		if not is_instance_valid(node) or not node.is_inside_tree() or node.get_parent() != saved.parent \
			or node.get_child_count(true) != saved.children: return false
	for saved: Dictionary in _gun_head_geometry.meshes:
		var node: Variant = saved.node
		if not is_instance_valid(node) or node.mesh != saved.resource \
			or StockBounds._local_pose(part,node) != saved.local: return false
		if node.mesh != null and node.mesh.get_aabb() != saved.box: return false
	return true

func _gun_head_constituents_clear(time: float, head: Transform3D, head_size: Vector3, boxes: Array[Dictionary]) -> bool:
	if boxes.is_empty() or not is_instance_valid(part) or crew.size() != 1 or part.kind != "gun": return false
	var source_pose := _planned_group_head(time)*_cargo_local
	if not source_pose.is_finite() or not is_finite(source_pose.basis.determinant()) or source_pose.basis.determinant() <= 0.0 \
		or not head.is_finite() or not is_finite(head.basis.determinant()) or head.basis.determinant() <= 0.0 \
		or not head_size.is_finite() or head_size.x <= 0.0 or head_size.y <= 0.0 or head_size.z <= 0.0: return false
	for box: Dictionary in boxes:
		if _boxes_overlap(source_pose*box.pose,box.size,head,head_size): return false
	return true

func _observe_original_gun_head_overlap(time: float,cargo: Transform3D,head: Transform3D,head_size: Vector3) -> void:
	# Observe the EXACT rejected union-box SAT. No extra space query or admission.
	if "--easy-island-gun-controls" not in _args or not is_instance_valid(part) \
		or part.part_id!="stock_16" or part.kind!="gun" or not worker.current_job_id.begins_with("build:"): return
	var source_rid: RID=part.get_rid()
	var key:=str(source_rid)+":head_overlap"
	var sample:=int(_contact_face_probe_rows.get(key,0))
	if sample>=8: return
	_contact_face_probe_rows[key]=sample+1
	var planned_head:=_planned_group_head(time)
	var source_pose:=planned_head*_cargo_local
	var live_head:=contact_frame()
	var source_native:=PhysicsServer3D.body_get_direct_state(source_rid)
	var worker_native:=PhysicsServer3D.body_get_direct_state(worker.get_rid())
	var native_shapes: Array[Dictionary]=[]
	var all_native_clear:=true
	for index: int in PhysicsServer3D.body_get_shape_count(source_rid):
		var owner: int=part.shape_find_owner(index)
		if part.is_shape_owner_disabled(owner): continue
		var shape_rid: RID=PhysicsServer3D.body_get_shape(source_rid,index)
		var resource: Shape3D
		for owner_index: int in part.shape_owner_get_shape_count(owner):
			var candidate: Shape3D=part.shape_owner_get_shape(owner,owner_index)
			if candidate!=null and candidate.get_rid()==shape_rid:
				resource=candidate
				break
		var box_shape:=resource as BoxShape3D
		var local: Transform3D=PhysicsServer3D.body_get_shape_transform(source_rid,index)
		var supported: bool=shape_rid.is_valid() and box_shape!=null and box_shape.size.is_finite() \
			and box_shape.size.x>0.0 and box_shape.size.y>0.0 and box_shape.size.z>0.0 \
			and local.is_finite() and local.basis.determinant()>0.0 and local.basis.is_equal_approx(local.basis.orthonormalized())
		var intersects: Variant=_boxes_overlap(source_pose*local,box_shape.size,head,head_size) if supported else null
		all_native_clear=all_native_clear and supported and intersects==false
		native_shapes.append({"index":index,"rid":str(shape_rid),"resource":resource.get_class() if resource else "missing", \
			"supported":supported,"size":part.encode_vector(box_shape.size) if box_shape!=null else null, \
			"pose":part.encode_transform(source_pose*local),"head_overlap":intersects})
	var visual_count:=0
	var all_visual_clear:=true
	var visual_hits: Array[Dictionary]=[]
	for node: MeshInstance3D in part.visual.find_children("*","MeshInstance3D",true,false):
		if node.mesh==null: continue
		var box: AABB=node.mesh.get_aabb()
		var pose:=source_pose*StockBounds._local_pose(part,node)*Transform3D(Basis.IDENTITY,box.get_center())
		var supported: bool=box.position.is_finite() and box.size.is_finite() and box.size.x>=0.0 and box.size.y>=0.0 and box.size.z>=0.0 \
			and pose.is_finite() and pose.basis.determinant()>0.0 \
			and absf(pose.basis.x.normalized().dot(pose.basis.y.normalized()))<.00001 \
			and absf(pose.basis.x.normalized().dot(pose.basis.z.normalized()))<.00001 \
			and absf(pose.basis.y.normalized().dot(pose.basis.z.normalized()))<.00001
		var intersects: Variant=_boxes_overlap(pose,box.size,head,head_size) if supported else null
		visual_count+=1
		all_visual_clear=all_visual_clear and supported and intersects==false
		if not supported or intersects==true:
			visual_hits.append({"node":str(node.get_path()),"supported":supported,"pose":part.encode_transform(pose),"size":part.encode_vector(box.size),"head_overlap":intersects})
	# The original bounds also include MultiMeshes. Do not claim clear coverage
	# if this particular source contains any; that case remains unsupported.
	var multi_meshes: Array=part.visual.find_children("*","MultiMeshInstance3D",true,false)
	print("HEAD_ORIGINAL_GUN_OVERLAP ",JSON.stringify({"source":part.part_id,"source_rid":str(source_rid),"worker":worker.worker_id, \
		"job":worker.current_job_id,"tick":Engine.get_physics_frames(),"sample":sample+1,"time":time, \
		"source_current_pose":part.encode_transform(part.global_transform),"planned_source_pose":part.encode_transform(source_pose), \
		"source_native_pose":part.encode_transform(source_native.transform) if source_native else null, \
		"worker_native_pose":part.encode_transform(worker_native.transform) if worker_native else null, \
		"live_contact_root_pose":part.encode_transform(_actual_root()),"live_contact_head_pose":part.encode_transform(live_head), \
		"planned_head_pose":part.encode_transform(planned_head),"captured_cargo_local":part.encode_transform(_cargo_local), \
		"saved_launch_pose":part.encode_transform(_home),"stock_bounds_position":part.encode_vector(_stock_bounds.position), \
		"union_pose":part.encode_transform(cargo),"union_size":part.encode_vector(_stock_bounds.size), \
		"head_pose":part.encode_transform(head),"head_size":part.encode_vector(head_size), \
		"contact_local":part.encode_vector(contact_local),"contact_normal":part.encode_vector(contact_normal), \
		"skin_gap":contact_surface_gap,"skin_penetration":contact_surface_penetration,"unchanged_tolerance":_contact_tolerance(), \
		"enabled_native_shapes":native_shapes,"all_native_boxes_clear":not native_shapes.is_empty() and all_native_clear, \
		"visual_mesh_count":visual_count,"visual_box_hits":visual_hits,"multi_mesh_count":multi_meshes.size(), \
		"all_visual_boxes_clear":visual_count>0 and all_visual_clear and multi_meshes.is_empty()}))




func _crew_clear(time: float, with_cargo: bool, gun_head_boxes: Array[Dictionary] = [], own_body:=Transform3D.IDENTITY, own_legs: Array[Vector3]=[]) -> bool:
	# The caller already computed this exact sample. Standalone diagnostics
	# retain their original private-call behavior; no admitted pose is skipped.
	if own_legs.is_empty():
		own_legs=_planned_leg_points(time)
		own_body=_planned_body(time)
	var own_cube := own_body*_root_local
	var cube_size := Vector3(.76,_head_height*2.0,.76)
	var cargo := _planned_group_head(time)*_cargo_local*Transform3D(Basis.IDENTITY,_stock_bounds.get_center()) if with_cargo else Transform3D.IDENTITY
	var holder:=own_body*Transform3D(Basis.IDENTITY,_holder_bounds.get_center())
	if with_cargo and _boxes_overlap(cargo,_stock_bounds.size,holder,_holder_bounds.size): arc_failure="shared stock crosses permanent back holder at %.3fs" % time; return false
	var has_tool:=is_instance_valid(worker.equipped_tool)
	var tool:=own_body*_tool_local*Transform3D(Basis.IDENTITY,_tool_bounds.get_center()) if has_tool else Transform3D.IDENTITY
	if with_cargo and has_tool and _boxes_overlap(cargo,_stock_bounds.size,tool,_tool_bounds.size): arc_failure="shared stock crosses retained tool at %.3fs" % time; return false
	# The tucked finite links must also clear the helper's own complete back
	# hardware/tool. A tuck is never just a visual pose outside preflight.
	for side in 2:
		for link in 2:
			var a: Vector3 = own_body*own_legs[side*3+link]
			var b: Vector3 = own_body*own_legs[side*3+link+1]
			if _own_holder_intersects(own_legs[side*3+link],own_legs[side*3+link+1]): arc_failure="tucked leg crosses original back holder at %.3fs" % time; return false
			if has_tool and _segment_box(a,b,tool,_tool_bounds.size,.085): arc_failure="tucked leg crosses original retained tool at %.3fs" % time; return false
			if link==1 and _segment_box(a,b,own_cube,cube_size,.085): arc_failure="tucked lower leg crosses own head at %.3fs" % time; _observe_stunt_clearance(time,side,own_legs); return false
	if with_cargo:
		if _boxes_overlap(cargo,_stock_bounds.size,own_cube,cube_size):
			_observe_original_gun_head_overlap(time,cargo,own_cube,cube_size)
			# A gun's combined bounds can enclose empty space. Only the
			# complete unchanged native AND visible constituents may recover
			# that rejection, against this same real head and SAT tolerance.
			if not _gun_head_constituents_clear(time,own_cube,cube_size,gun_head_boxes):
				arc_failure="stock crosses carrying head at %.3fs" % time
				return false
		for side in 2:
			for link in 2:
				if _segment_box(own_body*own_legs[side*3+link],own_body*own_legs[side*3+link+1],cargo,_stock_bounds.size,.085): arc_failure="stock crosses carrying leg at %.3fs" % time; return false
	for member: Node in crew:
		if member==worker: continue
		var other: RefCounted=member.head_leap
		var other_legs: Array[Vector3] = other._planned_leg_points(time)
		var other_body: Transform3D=other._planned_body(time)
		var other_cube: Transform3D=other_body*other._root_local
		if _boxes_overlap(own_cube,cube_size,other_cube,cube_size): arc_failure="cooperative heads/body cross at %.3fs" % time; return false
		if with_cargo and _boxes_overlap(cargo,_stock_bounds.size,other_cube,cube_size): arc_failure="shared stock crosses partner head at %.3fs" % time; return false
		var other_holder: Transform3D=other_body*Transform3D(Basis.IDENTITY,other._holder_bounds.get_center())
		if _boxes_overlap(holder,_holder_bounds.size,other_cube,cube_size) or _boxes_overlap(own_cube,cube_size,other_holder,other._holder_bounds.size): arc_failure="permanent back holder crosses partner head at %.3fs" % time; return false
		if _boxes_overlap(holder,_holder_bounds.size,other_holder,other._holder_bounds.size): arc_failure="cooperative back holders cross at %.3fs" % time; return false
		if with_cargo and _boxes_overlap(cargo,_stock_bounds.size,other_holder,other._holder_bounds.size): arc_failure="shared stock crosses partner back holder at %.3fs" % time; return false
		var other_has_tool:=is_instance_valid(member.equipped_tool)
		var other_tool: Transform3D=other_body*other._tool_local*Transform3D(Basis.IDENTITY,other._tool_bounds.get_center()) if other_has_tool else Transform3D.IDENTITY
		if with_cargo and other_has_tool and _boxes_overlap(cargo,_stock_bounds.size,other_tool,other._tool_bounds.size): arc_failure="shared stock crosses partner tool at %.3fs" % time; return false
		if has_tool:
			if _boxes_overlap(tool,_tool_bounds.size,other_cube,cube_size): arc_failure="retained tool crosses partner head at %.3fs" % time; return false
			if other_has_tool:
				if _boxes_overlap(tool,_tool_bounds.size,other_tool,other._tool_bounds.size): arc_failure="cooperative retained tools cross at %.3fs" % time; return false
		for side in 2:
			for link in 2:
				var a: Vector3=other_body*other_legs[side*3+link]
				var b: Vector3=other_body*other_legs[side*3+link+1]
				if _segment_box(a,b,holder,_holder_bounds.size,.085): arc_failure="partner leg crosses permanent back holder at %.3fs" % time; return false
				if _segment_box(a,b,own_cube,cube_size,.085): arc_failure="partner leg crosses head at %.3fs" % time; return false
				if with_cargo and _segment_box(a,b,cargo,_stock_bounds.size,.085): arc_failure="stock crosses partner leg at %.3fs" % time; return false
				if has_tool and _segment_box(a,b,tool,_tool_bounds.size,.085): arc_failure="tool crosses partner leg at %.3fs" % time; return false
				for own_side in 2:
					for own_link in 2:
						var c: Vector3=own_body*own_legs[own_side*3+own_link]
						var d: Vector3=own_body*own_legs[own_side*3+own_link+1]
						if _segment_distance(a,b,c,d)<.17: arc_failure="cooperative legs cross at %.3fs" % time; return false
	return true

func _gather_profile() -> Dictionary:
	return CREW_GATHER if crew.size()>1 else GATHER

func _absorb_profile() -> Dictionary:
	# Heavy shared loads absorb deeper and recover more slowly.
	return CREW_ABSORB if crew.size()>1 or not _small_stock_timing() else ABSORB

func grounded_stunt_root(pose: SkeletonModifier3D, sk: Skeleton3D, authored: Transform3D) -> Transform3D:
	# Gather into the real planted soles; only the original native controller
	# supplies lift. The touchdown absorb starts after actual landing support.
	var gather := .0
	var lean := .0
	var axis := _outbound_axis
	if state=="prepare":
		# Crouch while both soles support us, hold the coiled pose leaning toward
		# the stock, then extend briskly into the native push-off.
		var profile: Dictionary = _gather_profile()
		var extend := smoothstep(float(profile.hold),float(profile.extend),elapsed)
		gather = float(profile.depth)*smoothstep(.0,float(profile.crouch),elapsed)*(1.0-extend)
		lean = lerpf(float(profile.lean)*smoothstep(float(profile.crouch)*.5,float(profile.hold),elapsed),float(profile.launch_lean),extend)
	elif state=="landing" and _impact_age>=.0:
		# Absorb scaled by the measured impact, a short hold, slower recovery and
		# a small rock in the direction of travel (back toward the launch place).
		var absorb: Dictionary = _absorb_profile()
		var bottom := float(absorb["in"])+float(absorb.hold)
		var envelope := smoothstep(.0,float(absorb["in"]),_impact_age)*(1.0-smoothstep(bottom,bottom+float(absorb.recover),_impact_age))
		gather = _absorb_depth*envelope
		lean = ABSORB_ROCK*envelope
		axis = -_outbound_axis
	else: return authored
	if (gather<.00001 and lean<.0001) or not worker.on_ground or not pose.evaluated_valid or not _stunt_grounded[0] or not _stunt_grounded[1]: return authored
	var wanted := authored
	wanted.origin -= sk.global_basis.inverse()*worker.ground_normal*gather
	var local_axis: Vector3 = sk.global_basis.inverse()*axis.slide(worker.ground_normal)
	if lean>.0001 and local_axis.length_squared()>.000001:
		# Pitch about the hip line so the cube tips toward the stock over its feet.
		var pivot := Vector3.ZERO
		for side in 2: pivot += sk.get_bone_global_pose(pose._chains[side][0]).origin*.5
		pivot = wanted.origin+(pivot-authored.origin)
		var turn := Basis(local_axis.normalized(),lean)
		wanted.basis = turn*wanted.basis
		wanted.origin = pivot+turn*(wanted.origin-pivot)
	var native_rebase: Transform3D = worker.global_transform*pose.evaluated_worker.affine_inverse()
	# Reuse the unchanged true plant/reach reserve and complete stored-tool
	# admission. The caller still applies its finite position/6 rad/s caps.
	for side in 2:
		var hip: Vector3 = authored.affine_inverse()*sk.get_bone_global_pose(pose._chains[side][0]).origin
		var ankle: Vector3 = sk.global_transform.affine_inverse()*(native_rebase*(pose.evaluated_soles[side]-pose.evaluated_ankles[side]*Vector3(0,pose._ankle_height[side],0)))
		if (wanted*hip).distance_to(ankle)>worker._leg_lengths[side]-.012: return authored
	if worker.back_tool and is_instance_valid(worker.equipped_tool) and not worker.back_tool.travel_frame_clear(sk.global_transform*wanted*(native_rebase*pose.evaluated_root).affine_inverse()): return authored
	return wanted

func _return_phase() -> bool:
	return _planning_return or _return_started

func _stunt_tuck(time: float) -> float:
	# Outbound: toe push (legs long), brisk forward tuck, compact turn, then
	# opening to a frog/pike over the head. Return: head-push kick, re-tuck and
	# open to slightly bent landing legs. Contact and touchdown are curve
	# samples, so the preflight's last sample covers each held pose.
	var u := clampf(time/_flight_seconds,.0,1.0)
	if _return_phase():
		if u<.06: return lerpf(TUCK_CONTACT,0.0,smoothstep(.0,.06,u))
		if u<.25:
			var rise := (u-.06)/.19
			return 1.0-pow(1.0-rise,3.0)
		if u<.5: return 1.0
		return lerpf(1.0,TUCK_TOUCHDOWN,smoothstep(.5,.86,u))
	if u<.04: return 0.0
	if u<.16:
		var rise := (u-.04)/.12
		return 1.0-pow(1.0-rise,3.0)
	if u<.5: return 1.0
	return lerpf(1.0,TUCK_CONTACT,smoothstep(.5,.86,u))

func _planned_leg_points(time: float) -> Array[Vector3]:
	var restarting := _restart_leg_points.size()==6
	if restarting and time<=.000001: return _restart_leg_points.duplicate()
	var blend := smoothstep(.0,.25,clampf(time/_flight_seconds,.0,1.0)) if restarting else 1.0
	return _stunt_leg_points(_stunt_tuck(time),blend,_stunt_capacity)

func _stunt_leg_points(tuck: float, blend: float, capacity: float = 1.0) -> Array[Vector3]:
	var result: Array[Vector3] = _leg_points.duplicate()
	if result.size()!=6: return result
	var restarting := _restart_leg_points.size()==6
	if not restarting and tuck<.000001: return result
	for side in 2:
		var hip: Vector3 = _leg_points[side*3]
		var knee: Vector3 = _leg_points[side*3+1]
		var ankle: Vector3 = _leg_points[side*3+2]
		var upper := hip.distance_to(knee)
		var lower := knee.distance_to(ankle)
		# Deep tuck: heels toward the seat (about 130 degrees of knee flexion).
		var target := ankle+(_root_local.basis.y*TUCK_UP-_stunt_forward*TUCK_BACK)*tuck*capacity
		if restarting:
			target = _restart_leg_points[side*3+2].lerp(target,blend)
			knee = _restart_leg_points[side*3+1].lerp(knee,blend)
		var axis := (target-hip).normalized()
		var from := (knee-hip).slide(axis).normalized()
		var to := _stunt_forward.slide(axis).normalized()
		var signed_turn := atan2(axis.dot(from.cross(to)),clampf(from.dot(to),-1.0,1.0))
		var pole := from.rotated(axis,signed_turn*tuck)
		var solution := LegGeometry.two_link(hip,target,upper,lower,pole,.015,.012,_stunt_forward)
		result[side*3+1] = solution.knee
		result[side*3+2] = solution.foot
	return result

func _stunt_self_clear(points: Array[Vector3]) -> bool:
	var head_size := Vector3(.76,_head_height*2.0,.76)
	var has_tool := is_instance_valid(worker.equipped_tool)
	var tool := _tool_local*Transform3D(Basis.IDENTITY,_tool_bounds.get_center())
	for side in 2:
		for link in 2:
			var a: Vector3 = points[side*3+link]
			var b: Vector3 = points[side*3+link+1]
			if _own_holder_intersects(a,b): return false
			if has_tool and _segment_box(a,b,tool,_tool_bounds.size,.085): return false
			if link==1 and _segment_box(a,b,_root_local,head_size,.085): return false
	return true

func _stunt_capacity_clear(capacity: float) -> bool:
	for sample in range(1,33):
		if not _stunt_self_clear(_stunt_leg_points(float(sample)/32.0,1.0,capacity)): return false
	return true

func _fit_stunt_tuck() -> void:
	# Fit ankle lift BEFORE the original full arc/force admission, preserving
	# the forward knee pole. Capacity is fixed throughout the flight; no
	# per-frame clipping, length changes or visual
	# exception can conceal contact. Final preflight still checks every body,
	# stock, partner, holder/tool and link with the original finite envelopes.
	_stunt_capacity = 1.0
	if _leg_points.size()!=6 or not _stunt_self_clear(_leg_points): return
	if _stunt_capacity_clear(1.0): return
	var low := .0
	var high := 1.0
	for iteration in 8:
		var middle := (low+high)*.5
		if _stunt_capacity_clear(middle): low=middle
		else: high=middle
	_stunt_capacity = low*.95

func _observe_stunt_clearance(time: float, side: int, points: Array[Vector3]) -> void:
	if _stunt_clearance_rows>=2: return
	_stunt_clearance_rows += 1
	print("HEAD_STUNT_SELF_REFUSAL worker=",worker.worker_id," source=",part.part_id," state=",state," time=",time," side=",side," capacity=",_stunt_capacity," actual_launch_links=",_leg_points," proposed_links=",points," actual_root=",_root_local," forward=",_stunt_forward)

func _apply_stunt_legs(pose: SkeletonModifier3D, sk: Skeleton3D) -> void:
	var time := minf(elapsed,_flight_seconds) if state in ["outbound","return"] else _flight_seconds
	var points := _planned_leg_points(time)
	# Feet (visual only; not in any clearance set): pointed along the shin in
	# the tuck, flat to the launch sole frame for the last .12 s before touchdown.
	var point := clampf(_stunt_tuck(time)*1.25,0.0,1.0)
	if _return_phase(): point *= smoothstep(.0,FOOT_FLATTEN_SECONDS,_flight_seconds-time) if state=="return" else 0.0
	var local := sk.global_transform.affine_inverse()*worker.global_transform
	for side in 2:
		var chain: Array = pose._chains[side]
		var upper := sk.get_bone_global_pose(chain[0])
		var lower := sk.get_bone_global_pose(chain[1])
		var foot := sk.get_bone_global_pose(chain[2])
		var ankle_basis := foot.basis
		if _restart_ankles.size()==2: ankle_basis = local.basis*_restart_ankles[side]
		var knee: Vector3 = local*points[side*3+1]
		var ankle: Vector3 = local*points[side*3+2]
		upper.basis = Basis(Quaternion((lower.origin-upper.origin).normalized(),(knee-upper.origin).normalized()))*upper.basis
		sk.set_bone_global_pose(chain[0],upper)
		lower = sk.get_bone_global_pose(chain[1])
		foot = sk.get_bone_global_pose(chain[2])
		lower.basis = Basis(Quaternion((foot.origin-lower.origin).normalized(),(ankle-lower.origin).normalized()))*lower.basis
		sk.set_bone_global_pose(chain[1],lower)
		foot = sk.get_bone_global_pose(chain[2])
		foot.basis = ankle_basis
		sk.set_bone_global_pose(chain[2],foot)
		var toe: int = pose._toes[side] if side<pose._toes.size() else -1
		if point<.001 or toe<0: continue
		# Plantar flexion toward the shin line, read from the rig's own toe bone
		# so it follows whichever way the toes are authored.
		var shin: Vector3 = (foot.origin-lower.origin).normalized()
		var toe_pose := sk.get_bone_global_pose(toe)
		var toe_direction: Vector3 = (toe_pose.origin-foot.origin)
		var flex_axis := toe_direction.cross(shin)
		if toe_direction.length_squared()<.000001 or flex_axis.length_squared()<.000001: continue
		flex_axis = flex_axis.normalized()
		foot.basis = Basis(flex_axis,minf(FOOT_POINT,toe_direction.angle_to(shin))*point)*ankle_basis
		sk.set_bone_global_pose(chain[2],foot)
		toe_pose = sk.get_bone_global_pose(toe)
		toe_pose.basis = Basis(flex_axis,TOE_CURL*point)*toe_pose.basis
		sk.set_bone_global_pose(toe,toe_pose)

func evaluate_airborne(pose: SkeletonModifier3D, sk: Skeleton3D) -> bool:
	if not (airborne_pose() or (state=="landing" and not worker.on_ground)) or _bones.is_empty(): return false
	for bone in _bones.size(): sk.set_bone_pose(bone,_bones[bone])
	_apply_stunt_legs(pose,sk)
	pose.evaluated_grounded = [false,false]
	pose._target_valid = [false,false]
	pose._gait_rotations.clear()
	pose._head_gait_continuation = false
	pose._travel_pole_handoff=false
	pose._travel_tool_handoff=false
	pose._travel_tool_settle_time=0.0
	for side in 2:
		var chain: Array = pose._chains[side]
		pose.evaluated_hips[side] = sk.global_transform*sk.get_bone_global_pose(chain[0]).origin
		pose.evaluated_knees[side] = sk.global_transform*sk.get_bone_global_pose(chain[1]).origin
		pose.evaluated_ankles[side] = sk.global_basis*sk.get_bone_global_pose(chain[2]).basis
		pose.evaluated_soles[side] = sk.global_transform*(sk.get_bone_global_pose(chain[2])*Vector3(0,pose._ankle_height[side],0))
	pose.evaluated_root = sk.global_transform*sk.get_bone_global_pose(0)
	pose.evaluated_worker = worker.global_transform
	pose.evaluated_basis = sk.global_basis
	pose.evaluated_valid = true
	pose.evaluation_serial += 1
	_capture_leg_bases(sk)
	worker._update_work_tool(true)
	worker._update_head(pose.evaluated_root)
	if worker.ragdoll: worker.ragdoll.remember_pose()
	return true

func _seed_landing_release() -> void:
	var pose: SkeletonModifier3D=worker._pose
	if not pose.evaluated_valid: return
	# The returned real cube and its head-held material share the already
	# qualified grounded departure turn budget before normal routing resumes.
	worker._grounded_heading_handoff=true
	var rebase: Transform3D=worker.global_transform*pose.evaluated_worker.affine_inverse()
	var root: Transform3D=rebase*pose.evaluated_root
	var inverse := root.affine_inverse()
	var side: int=worker.tool_foot_side()
	var other: int=1-side
	pose._manipulation_snapshot.clear()
	pose._work_release={"side":side,"age":0.0,
		"sole":inverse*(rebase*pose.evaluated_soles[side]),"basis":root.basis.inverse()*rebase.basis*pose.evaluated_ankles[side],
		"support_sole":inverse*(rebase*pose.evaluated_soles[other]),"support_basis":root.basis.inverse()*rebase.basis*pose.evaluated_ankles[other]}
	pose._head_gait_continuation=false
	pose._head_gait_rotations.clear()
	pose._target_valid=[false,false]
	pose._walk_swing_phase=[-1.0,-1.0]
	pose._gait_handoff_active=false
	pose._gait_handoff_tail=0.0

func _stock_support() -> Dictionary:
	if not is_instance_valid(part): return {}
	var bounds: AABB = part.global_transform*_stock_bounds
	var point := Vector3(bounds.get_center().x,bounds.position.y,bounds.get_center().z)
	var query := PhysicsRayQueryParameters3D.create(point+Vector3.UP*.025,point-Vector3.UP*.05,1)
	var exclusions: Array[RID]=[part.get_rid()]
	for member: Node in crew: exclusions.append(member.get_rid())
	query.exclude = exclusions
	var hit := worker.get_world_3d().direct_space_state.intersect_ray(query)
	return hit if not hit.is_empty() and hit.normal.y>.65 else {}

func _actual_root() -> Transform3D:
	if worker._pose.evaluated_valid:
		return worker.global_transform*worker._pose.evaluated_worker.affine_inverse()*worker._pose.evaluated_root
	return worker.global_transform*_root_local

func _head_point() -> Vector3:
	return _actual_root()*_head_touch_local

func abort(message: String) -> void:
	# Finished work retains its contact history, but no longer owns installed
	# or loose stock, nor a former partner's newly started head leap.
	if not active():
		if not is_instance_valid(part) or not is_instance_valid(part.carrier): return
		var held_by_crew := crew.any(func(member: Node) -> bool: return is_instance_valid(member) and member.head_leap.part==part and member.head_leap.crew==crew and part.carrier==member.head_anchor)
		var staged: bool=contacted and part.has_meta(&"staged_target") and part.get_meta(&"staged_target")==part.carrier
		if not held_by_crew and not staged: return
	if reason.is_empty(): reason=message
	_abort_requested = true
	for member: Node in crew:
		if not is_instance_valid(member) or member.head_leap.part!=part or member.head_leap.crew!=crew: continue
		if member.head_leap.reason.is_empty(): member.head_leap.reason=message
		member.head_leap._abort_requested=true
	# A valid stock object may already have left the world when its carrier's
	# tree_exiting callback cancels the job. No physical release exists then.
	if crew.is_empty() or not is_instance_valid(part) or not part.is_inside_tree(): return
	if crew[0]!=worker:
		if is_instance_valid(crew[0]) and crew[0].head_leap.part==part and crew[0].head_leap.crew==crew:
			crew[0].head_leap.abort(message)
		return
	# Preserve precise source visibility through a bare recovery preflight.
	# The physical masks still ignore this query-only layer.
	if not is_instance_valid(part.carrier): part.collision_layer=_saved_source_layer|CONTACT_QUERY_BIT
	if part.carrier==worker.head_anchor or (contacted and part.has_meta(&"staged_target") and is_instance_valid(part.carrier)):
		# Prefer the source's measured native COM/angular motion directly. It
		# includes animated head motion and remains valid when crew are leaving.
		var stock_state := PhysicsServer3D.body_get_direct_state(part.get_rid())
		var velocity: Vector3=stock_state.linear_velocity if stock_state else part.linear_velocity
		var spin: Vector3=stock_state.angular_velocity if stock_state else part.angular_velocity
		if not stock_state and crew.all(func(member: Node) -> bool: return is_instance_valid(member) and member.is_inside_tree() and member.head_leap.part==part and member.head_leap.crew==crew):
			# Keep the ordinary point-motion fallback while the whole crew still
			# has a world frame; detached bodies retain their own cached motion.
			velocity=Vector3.ZERO
			for member: Node in crew:
				var direct := PhysicsServer3D.body_get_direct_state(member.get_rid())
				var com: Vector3=member.global_transform*direct.center_of_mass_local if direct else member.global_position
				velocity += _velocity(member)+member.angular_velocity.cross(member.head_leap._head_point()-com)
			velocity /= crew.size()
			velocity+=worker.angular_velocity.cross(part.global_position-contact_frame().origin)
			spin=worker.angular_velocity
		var target: Variant=part.get_meta(&"staged_target") if part.has_meta(&"staged_target") else null
		if is_instance_valid(target): target.visual.show()
		part.remove_meta(&"staged_target")
		part.set_carried(null)
		part.linear_velocity = velocity
		part.angular_velocity = spin
		part.set_meta(&"in_transit",false)
		for member: Node in crew:
			if not is_instance_valid(member) or member.head_leap.part!=part or member.head_leap.crew!=crew: continue
			if member.is_inside_tree():
				part.add_collision_exception_with(member)
				member.head_leap._release_watch = part
			else:
				part.remove_collision_exception_with(member)
			# A supported release can occur long after the landing converged.
			# This actual carried/staged body's cancellation must hand its current
			# WORLD legs to the interrupted clip before clearing the cargo share.
			# Airborne impacts retain their existing native fall/return ownership.
			var pose: SkeletonModifier3D = member._pose
			if member.is_inside_tree() and member.on_ground and is_instance_valid(pose) and pose.is_inside_tree() and pose.evaluated_valid:
				pose._head_landing_continuation = true
				pose._head_return_settle = 0.0
			member.set_cargo(0.0)
			member.head_leap._abort_requested = true

func _watch_release() -> void:
	_restore_collision_when_safe()
	if not is_instance_valid(_release_watch): return
	if not _release_watch.is_inside_tree():
		_release_watch.remove_collision_exception_with(worker)
		_release_watch=null
		return
	var bounds: AABB = _release_watch.global_transform*StockBounds.bounds(_release_watch)
	var cube: AABB = _actual_root()*AABB(Vector3(-.4,-.35,-.4),Vector3(.8,.7,.8))
	var collision: CollisionShape3D=worker.get_node("Collision")
	var native: AABB=collision.global_transform*collision.shape.get_debug_mesh().get_aabb()
	if not bounds.grow(.06).intersects(cube.merge(native)):
		_release_watch.remove_collision_exception_with(worker)
		_release_watch = null

func clear_before_launch() -> void:
	if state=="prepare":
		if is_instance_valid(part): part.remove_collision_exception_with(worker)
		if not crew.is_empty() and crew[0]==worker and is_instance_valid(part): part.collision_layer=_saved_source_layer
		state=""
		part=null

func _save_native_settings() -> void:
	_native_settings_saved=true
	if not _needs_angular_restore:
		_saved_angular_locks = [worker.axis_lock_angular_x, worker.axis_lock_angular_y, worker.axis_lock_angular_z]
	_needs_angular_restore = true
	var collision: CollisionShape3D=worker.get_node("Collision")
	_saved_collision_shape=collision.shape
	_saved_collision_transform=collision.transform
	# The old capsule extends 148 mm past this asset's real roof. During the
	# rotating head flight use its captured finite cube instead, so a genuine
	# thin-part touch does not require pushing that invisible capsule into floor.
	# Both legs retain their native reactive observers and finite skin geometry.
	var torso:=BoxShape3D.new()
	torso.size=Vector3(.76,_head_height*2.0,.76)
	collision.shape=torso
	collision.transform=_root_local
	_needs_collision_restore=true
	_saved_damping = worker.linear_damp
	_saved_damping_mode = worker.linear_damp_mode
	_saved_angular_damping = worker.angular_damp
	_saved_angular_damping_mode = worker.angular_damp_mode
	worker.linear_damp_mode=RigidBody3D.DAMP_MODE_REPLACE
	worker.linear_damp=0.0
	worker.angular_damp_mode=RigidBody3D.DAMP_MODE_REPLACE
	worker.angular_damp=0.0
	worker.axis_lock_angular_x=false
	worker.axis_lock_angular_y=false
	worker.axis_lock_angular_z=false

func _finish(success: bool) -> void:
	if _native_settings_saved:
		worker.linear_damp=_saved_damping
		worker.linear_damp_mode=_saved_damping_mode
		worker.angular_damp=_saved_angular_damping
		worker.angular_damp_mode=_saved_angular_damping_mode
	_restore_collision_when_safe()
	# Lock only after supported native angular settling. A failed recovery is
	# left for the existing reactive/ragdoll controller instead of snapping it.
	if _needs_angular_restore and (success or (worker.on_ground and worker.global_basis.y.dot(Vector3.UP)>.98 and worker.angular_velocity.length()<.35)):
		worker.axis_lock_angular_x = _saved_angular_locks[0]
		worker.axis_lock_angular_y = _saved_angular_locks[1]
		worker.axis_lock_angular_z = _saved_angular_locks[2]
		_needs_angular_restore = false
	state="done" if success else "failed"
	worker.action=""
	worker.action_progress=1.0
	worker._animation.play("wk_idle",.2)
	if is_instance_valid(part) and not is_instance_valid(_release_watch): part.remove_collision_exception_with(worker)
	if not crew.is_empty() and crew[0]==worker and is_instance_valid(part) and not is_instance_valid(part.carrier): part.collision_layer=_saved_source_layer
	if not success and worker.global_basis.y.dot(Vector3.UP)<.8 and worker.ragdoll and not worker.ragdoll.is_down(): worker.ragdoll.knock_down()

func take_recovery_angular_locks() -> Array[bool]:
	# The accepted native fall owns this pre-flight policy until supported recovery.
	var locks: Array[bool] = [worker.axis_lock_angular_x, worker.axis_lock_angular_y, worker.axis_lock_angular_z]
	if _needs_angular_restore:
		locks.assign(_saved_angular_locks)
		_needs_angular_restore = false
	return locks

func _restore_collision_when_safe() -> void:
	if not _needs_collision_restore: return
	var suspended: bool=worker.ragdoll and worker.ragdoll.is_down()
	var supported: bool=worker.on_ground and worker.global_basis.y.dot(Vector3.UP)>.98 and _velocity(worker).length()<.5 and worker.angular_velocity.length()<.35
	if supported and not suspended:
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape=_saved_collision_shape
		query.transform=worker.global_transform*_saved_collision_transform
		query.collision_mask=1
		query.exclude=worker.query_exclusions()
		if not worker.get_world_3d().direct_space_state.intersect_shape(query,1).is_empty(): return
	if supported or suspended:
		var collision: CollisionShape3D=worker.get_node("Collision")
		collision.shape=_saved_collision_shape
		collision.transform=_saved_collision_transform
		_needs_collision_restore=false

static func _velocity(body: RigidBody3D) -> Vector3:
	var direct := PhysicsServer3D.body_get_direct_state(body.get_rid())
	return direct.linear_velocity if direct else body.linear_velocity

func saved_physical_body() -> Dictionary:
	if not _native_settings_saved or not active() or not worker.ragdoll: return {}
	var visual: RefCounted=worker.ragdoll.visual
	if visual._remembered.size()!=worker._skeleton.get_bone_count(): return {}
	# Saving interrupts the assisted jump into existing native fall/recovery.
	# Each frame is the last actually evaluated rig carried by current native
	# motion; no authored upright pose or previous launch place is substituted.
	var native:=PhysicsServer3D.body_get_direct_state(worker.get_rid())
	var frame: Transform3D=native.transform if native else worker.global_transform
	var spin: Vector3=native.angular_velocity if native else worker.angular_velocity
	var velocity: Vector3=native.linear_velocity if native else worker.linear_velocity
	var com: Vector3=frame*native.center_of_mass_local if native else frame*worker.center_of_mass
	var rebase: Transform3D=frame*visual._remembered_worker.affine_inverse()
	var bodies: Array=[]
	for body in worker.ragdoll.rig.bodies:
		var pose: Transform3D=rebase*visual._remembered[body.bone]*body.b2b_inv
		pose.basis=pose.basis.orthonormalized()
		var point_motion:=velocity+spin.cross(pose.origin-com)
		bodies.append({"pose":[pose.basis.x.x,pose.basis.x.y,pose.basis.x.z,pose.basis.y.x,pose.basis.y.y,pose.basis.y.z,pose.basis.z.x,pose.basis.z.y,pose.basis.z.z,pose.origin.x,pose.origin.y,pose.origin.z],"linear":[point_motion.x,point_motion.y,point_motion.z],"angular":[spin.x,spin.y,spin.z]})
	return {"bodies":bodies,"clock":0.0,"origin_motion":true,"saved":{"layer":worker.collision_layer,"mask":worker.collision_mask,"freeze":worker.freeze,"freeze_mode":worker.freeze_mode,"angular_locks":_saved_angular_locks.duplicate()}}

func _capture_leg_bases(sk: Skeleton3D) -> void:
	evaluated_leg_bases.clear()
	for side in 2:
		var chain: Array=worker._pose._chains[side]
		for bone: int in [chain[1],chain[2]]: evaluated_leg_bases.append(sk.global_basis*sk.get_bone_global_pose(bone).basis)

func _capture_holder_bounds() -> void:
	_holder_bounds=AABB()
	if not worker.back_tool: return
	var found:=false
	var inverse:=worker.global_transform.affine_inverse()
	for node: Node in worker.back_tool.holder.get_children():
		if not node is MeshInstance3D or not node.mesh: continue
		var bounds: AABB=inverse*node.global_transform*node.get_aabb()
		_holder_bounds=_holder_bounds.merge(bounds) if found else bounds
		found=true
	# Preserve the ORIGINAL world/cargo/partner union. Only own-limb
	# admission resolves its empty cavities against every real constituent.
	var started_usec := Time.get_ticks_usec()
	var holder_frame: Transform3D=inverse*worker.back_tool.holder.global_transform
	_holder_inverse=holder_frame.affine_inverse()
	_holder_clearance.capture(worker.back_tool.holder)
	# Holder space must be rigid so the original 85mm radius is unchanged.
	if not holder_frame.basis.is_equal_approx(holder_frame.basis.orthonormalized()): _holder_clearance.valid=false
	_holder_capture_usec=maxi(_holder_capture_usec,Time.get_ticks_usec()-started_usec)


func _own_holder_intersects(a: Vector3,b: Vector3) -> bool:
	return _holder_clearance.intersects(_holder_inverse*a,_holder_inverse*b)

extends RefCounted
## Supported light-part grip, native foot toss and a bounded head catch.
## The leg cannot pass through the rigid cube to reach its top. The SAME reserved
## body therefore travels under gravity between real toe and head contact.
const Catalogue = preload("res://Components/Contraptions/part_catalog.gd")
const GRAVITY := 9.8
const MAXIMUM_IMPULSE := 40.0
# A brisk lob: lowest clear apex above the actual head first (flight about
# .65-.8 s); the original higher lobs remain fallbacks for the same admission.
const APEX_EXTRAS := [.35, .45, .55, .65, .8, 1.0, 1.2, 1.4, 1.6, 1.8, 2.0]
# The caught body keeps its exact contact pose, then settles onto the head
# seat (nearest quarter-turn yaw) over this finite time.
const SETTLE_SECONDS := .18
const SEAT_GAP := .03

var worker: RigidBody3D
var part: RigidBody3D
var state := ""
var reason := ""
var grip_point := Vector3.ZERO
var foot_anchor: Node3D
var _orientation := Basis.IDENTITY
var _flight_clock := 0.0
var _foot_offset := Vector3.ZERO
var launch_impulse := Vector3.ZERO
var launch_point := Vector3.ZERO
var catch_error := INF
var _saved_damping := .15
var _saved_damping_mode := RigidBody3D.DAMP_MODE_COMBINE
var _launched := false
var launch_before_momentum := Vector3.ZERO
var launch_after_momentum := Vector3.ZERO
var catch_before_momentum := Vector3.ZERO
var catch_after_momentum := Vector3.ZERO
var arc_blocker := {}
var launch_validation_usec := 0
var _evaluated_progress := -1.0
var catch_offset := Vector3.ZERO
var catch_yaw := 0.0
var _settle: RigidBody3D
var _settle_clock := 0.0
var _settle_anchor := Vector3.ZERO
var _settle_basis := Basis.IDENTITY
var _seat_anchor := Vector3.ZERO
var _seat_basis := Basis.IDENTITY

static func eligible(source: Node3D) -> bool:
	if not is_instance_valid(source) or source.get("definition") == null: return false
	var bounds: AABB = Catalogue.bounds_of(source.definition)
	return source.mass <= 5.0 and bounds.size[bounds.size.max_axis_index()] <= .4 and source.definition.get("category", "") != "tool" and source.get("assembly") == null

func setup(owner: RigidBody3D) -> void:
	worker = owner
	foot_anchor = Node3D.new()
	foot_anchor.name = "FootCargoGrip"
	worker.add_child(foot_anchor)

func begin(source: RigidBody3D) -> void:
	clear()
	part = source
	state = "reaching"
	_orientation = source.global_basis.orthonormalized()
	# Curl the toe onto the top edge, then lift the clamped block clear before
	# releasing it. Trying to put an upturned toe below a floor-level block
	# would require pushing its ankle through the ground.
	var bounds: AABB = source.global_transform * Catalogue.bounds_of(source.definition)
	grip_point = Vector3(bounds.get_center().x, bounds.end.y - .025, bounds.get_center().z)
	launch_impulse = Vector3.ZERO
	_launched = false
	arc_blocker.clear()
	catch_error = INF
	_evaluated_progress = -1.0

func manipulating() -> bool:
	return state in ["reaching", "held"] and is_instance_valid(part) and worker.action == "pickup"

func release_progress() -> float:
	return smoothstep(.035, .32, _flight_clock) if state == "flight" else 1.0

func target() -> Vector3:
	var lift := smoothstep(.56,.70,worker.action_progress) if state == "held" else 0.0
	var bounds: AABB = Catalogue.bounds_of(part.definition)
	var head_basis: Basis = worker._model.global_basis
	if worker._pose.evaluated_valid:
		head_basis = (worker.global_transform * worker._pose.evaluated_worker.affine_inverse() * worker._pose.evaluated_root).basis
	var footprint: AABB = Transform3D(head_basis.inverse()*_orientation,Vector3.ZERO)*bounds
	# A rotated recovered block has a wider silhouette toward the cube. Prepare
	# its real gripping foot farther out by that extra half-footprint; the same
	# finite leg solution and contact gate still decide whether it can reach.
	var extension := clampf((footprint.size.z-bounds.size.z)*.5,0.0,.06)
	return grip_point + (Vector3.UP*.12-worker._model.global_basis.z*(.28+extension))*lift

func contact_ready() -> bool:
	if not manipulating() or not worker.on_ground or not worker.stance_valid or not worker.foot_grip_valid: return false
	var grip: Transform3D = worker.foot_grip_transform
	return (grip.origin + grip.basis.y * .035).distance_to(target()) < .08

func grip() -> bool:
	if state != "reaching" or not contact_ready(): return false
	state = "held"
	_foot_offset = foot_anchor.to_local(part.global_position)
	part.set_carried(foot_anchor, _foot_offset)
	worker.set_cargo(part.mass)
	return true

func evaluate(grip: Transform3D) -> void:
	if not manipulating(): return
	_evaluated_progress = worker.action_progress
	foot_anchor.global_transform = Transform3D(_orientation, grip.origin + grip.basis.y * .035)
	if state == "held" and part.carrier == foot_anchor:
		# Frozen followers publish at physics cadence; update with the evaluated
		# toe too, as existing head/tool fixtures do, preserving actual contact.
		part.global_transform = Transform3D(_orientation, foot_anchor.to_global(_foot_offset))

func advance(delta: float) -> void:
	_advance_settle(delta)
	if state.is_empty() or state == "caught" or state == "failed": return
	if not is_instance_valid(part) or not part.is_inside_tree() or not worker.is_inside_tree():
		state = "failed"; reason = "Reserved light part unavailable"; return
	if state == "held" and worker.action_progress >= .72:
		if not worker.on_ground or not worker.stance_valid:
			state = "failed"; reason = "Lost supporting foot; light part set down"; return
		if worker.action != "pickup" or not worker.foot_grip_valid:
			state = "failed"; reason = "Lost gripping foot; recover the same light part"; return
		# The clock advances before the modifier. Launch only after the current
		# lifted toe and body have actually been evaluated, not a gait snapshot.
		if _evaluated_progress < .72: return
		var started := Time.get_ticks_usec()
		_launch()
		launch_validation_usec = Time.get_ticks_usec()-started
	if state != "flight": return
	_flight_clock += delta
	if not worker.on_ground:
		state = "failed"; reason = "Lost footing during catch; recover the loose part"; return
	var bounds: AABB = part.global_transform * Catalogue.bounds_of(part.definition)
	var bottom := Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z)
	var head: Vector3 = _head_point()
	var relative := _velocity(part) - _velocity(worker)
	catch_error = bottom.distance_to(head + Vector3.UP * .03)
	var gap := bottom.y-head.y
	var next_gap := gap + relative.y*delta - .5*GRAVITY*delta*delta
	# Sweep the descending bottom against the upper-face contact plane before
	# the next native step penetrates it. The existing assisted catch settles
	# at most one bounded tick plus 2.5cm onto the head fixture, not from afar.
	var crosses_head := gap >= .054 and gap <= .12 and next_gap <= .055
	if _flight_clock > .15 and relative.y < -.1 and relative.y > -7.5 and crosses_head and Vector2(bottom.x-head.x,bottom.z-head.z).length() < .16:
		# Catch impulse transfers the incoming body's momentum to the enlarged
		# carrier mass exactly once. This is the existing assisted head fixture.
		var momentum := part.mass * relative
		catch_before_momentum = worker.mass * _velocity(worker) + part.mass * _velocity(part)
		worker.set_cargo(part.mass)
		worker.apply_impulse(momentum, head - worker.global_position)
		catch_after_momentum = worker.mass * _velocity(worker)
		part.remove_collision_exception_with(worker)
		_restore_damping()
		# Custody starts at the body's exact contact pose (no snap); the same body
		# then settles onto the head seat over a finite time.
		part.set_carried_at_pose(worker.head_anchor)
		_begin_settle()
		state = "caught"
	elif _flight_clock > 2.0 or (_flight_clock > .3 and part.linear_velocity.y < 0.0 and bounds.end.y < head.y - .1):
		state = "failed"; reason = "Head catch missed; recovering the same loose part"

func _begin_settle() -> void:
	_settle = part
	_settle_clock = 0.0
	var local: Transform3D = part.carried_local_transform()
	_settle_anchor = local.origin
	_settle_basis = local.basis.orthonormalized()
	_seat_anchor = Vector3(0, float(part.definition.size.y) * .5 + SEAT_GAP, 0)
	# Nearest quarter-turn yaw about the head's up axis; tilt settles level.
	var forward := _settle_basis.z.slide(Vector3.UP)
	var yaw := atan2(forward.x, forward.z) if forward.length_squared() > .000001 else 0.0
	_seat_basis = Basis(Vector3.UP, roundf(yaw / (PI * .5)) * PI * .5)
	catch_offset = _settle_anchor - _seat_anchor
	catch_yaw = rad_to_deg(_settle_basis.get_rotation_quaternion().angle_to(_seat_basis.get_rotation_quaternion()))

func _advance_settle(delta: float) -> void:
	if not is_instance_valid(_settle): return
	if _settle.get("carrier") != worker.head_anchor or not _settle.is_inside_tree():
		_settle = null
		return
	_settle_clock += delta
	var blend := smoothstep(0.0, SETTLE_SECONDS, _settle_clock)
	var basis := Basis(_settle_basis.get_rotation_quaternion().slerp(_seat_basis.get_rotation_quaternion(), blend))
	_settle.set("_cargo_anchor", _settle_anchor.lerp(_seat_anchor, blend))
	_settle.set("_cargo_pose_basis", basis)
	if _settle_clock >= SETTLE_SECONDS: _settle = null

func settling() -> bool:
	return is_instance_valid(_settle)

func _launch() -> void:
	var origin := part.global_position
	# Aim at the head where it will be at the catch. The kick clip compresses
	# and leans the cube now, but returns it to neutral before the part comes
	# down (measured: the instantaneous head put the catch 15 cm off-centre,
	# the neutral head within 5 mm). The catch tests the live head plane only.
	var neutral: Transform3D = worker._skeleton.global_transform * worker._skeleton.get_bone_global_rest(0)
	var destination: Vector3 = neutral * Vector3(0, worker.HEAD_OFFSET + float(part.definition.size.y) * .5 + .055, 0)
	var velocity := Vector3.ZERO
	var valid_arc := false
	var before := _velocity(worker)
	for extra: float in APEX_EXTRAS:
		var vertical := sqrt(2.0 * GRAVITY * maxf(destination.y + extra - origin.y, .1))
		var flight := (vertical + sqrt(maxf(vertical * vertical - 2.0 * GRAVITY * (destination.y-origin.y), 0.0))) / GRAVITY
		velocity = (destination - origin).slide(Vector3.UP) / flight + Vector3.UP * vertical
		if (velocity-before).length() * part.mass > MAXIMUM_IMPULSE: continue
		if _arc_clear(origin, velocity, flight): valid_arc = true; break
	if not valid_arc:
		state = "failed"; reason = "No clear foot toss/head catch arc; clear overhead access"; return
	launch_point = foot_anchor.global_position
	launch_impulse = part.mass * (velocity-before)
	var twist := (launch_point - part.global_position).cross(launch_impulse)
	if twist.length() > 1.0:
		state = "failed"; reason = "Light part grip cannot release safely; clear foot access"; return
	launch_before_momentum = worker.mass * before
	worker.set_cargo(0.0)
	part.set_carried(null)
	part.add_collision_exception_with(worker)
	_saved_damping = part.linear_damp
	_saved_damping_mode = part.linear_damp_mode
	# Tiny bounded blocks have negligible drag over this one-second toss.
	# Native gravity/collisions remain active; normal part damping returns at catch/cancel.
	part.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	part.linear_damp = 0.0
	part.linear_velocity = before
	part.angular_velocity = Vector3.ZERO
	part.apply_impulse(launch_impulse, launch_point - part.global_position)
	worker.apply_impulse(-launch_impulse, launch_point - worker.global_position)
	# A short opposing toe twist keeps the released block level. Both impulses
	# are paired; upright capsule orientation remains the documented assist.
	part.apply_torque_impulse(-twist)
	worker.apply_torque_impulse(twist)
	launch_after_momentum = worker.mass * _velocity(worker) + part.mass * _velocity(part)
	_launched = true
	_flight_clock = 0.0
	state = "flight"

func _arc_clear(origin: Vector3, velocity: Vector3, seconds: float) -> bool:
	var root: Transform3D = worker.global_transform * worker._pose.evaluated_worker.affine_inverse() * worker._pose.evaluated_root
	var inverse := root.affine_inverse()
	var neutral: Transform3D = worker._skeleton.global_transform * worker._skeleton.get_bone_global_rest(0)
	var neutral_inverse := neutral.affine_inverse()
	# Leave room for the finite supported body settling/turning during release.
	# The continuous observed-flight assertion still uses the unchanged cube.
	var cube := AABB(Vector3(-.415,-.3,-.415),Vector3(.83,.68,.83))
	var bounds: AABB = Catalogue.bounds_of(part.definition)
	var query := PhysicsShapeQueryParameters3D.new()
	var box := BoxShape3D.new()
	box.size = bounds.size
	query.shape = box
	query.exclude = worker.query_exclusions()
	query.exclude.append(part.get_rid())
	query.collision_mask = 1
	var samples := ceili(seconds*120.0)
	for step in range(1,samples+1):
		var time := seconds * step / samples
		var position := origin + velocity * time - Vector3.UP * (.5 * GRAVITY * time * time)
		var pose := Transform3D(_orientation, position)
		if cube.intersects(inverse * pose * bounds) or cube.intersects(neutral_inverse * pose * bounds):
			arc_blocker = {"kind":"cube","step":step,"bounds":neutral_inverse*pose*bounds}
			return false
		query.transform = pose.translated_local(bounds.get_center())
		var hits := worker.get_world_3d().direct_space_state.intersect_shape(query,1)
		if not hits.is_empty():
			arc_blocker = {"kind":"obstacle","step":step,"body":str(hits[0].collider),"position":position}
			return false
	return true

func clear() -> void:
	# A finished pickup leaves an in-progress settle running on the same body.
	if is_instance_valid(part) and is_instance_valid(worker) and part.is_inside_tree() and worker.is_inside_tree():
		part.remove_collision_exception_with(worker)
		if _launched: _restore_damping()
	part = null
	state = ""
	reason = ""

func _restore_damping() -> void:
	part.linear_damp = _saved_damping
	part.linear_damp_mode = _saved_damping_mode

func _head_point() -> Vector3:
	if worker._pose.evaluated_valid:
		var root: Transform3D = worker.global_transform * worker._pose.evaluated_worker.affine_inverse() * worker._pose.evaluated_root
		return root * Vector3(0,worker.HEAD_OFFSET,0)
	return worker.head_anchor.global_position

func _velocity(body: RigidBody3D) -> Vector3:
	# Node getters publish at force integration. Impulses have already updated
	# Jolt here, so mass-transfer accounting needs its actual current velocity.
	var state := PhysicsServer3D.body_get_direct_state(body.get_rid())
	return state.linear_velocity if state else body.linear_velocity

extends Node3D
const GunControl := preload("res://Components/Contraptions/gun_control_point.gd")
## Existing foot-work IK supplies the lifted grip; the opposite evaluated sole
## and native spring foot provide support. No human arms or head gun fixture.
const GroundItem := preload("res://Components/Contraptions/gun_ground_item.gd")
var worker: RigidBody3D
var kind := "station"
var definition := {"size":Vector3(.08,.08,.08)}
var assembly: Node3D
var equipped: Node3D
var preparing: WeakRef
var desired_target := Vector3.INF
var actual_grip := Transform3D.IDENTITY
var grip_valid := false
var aim_valid := false
var contact_gap := INF
var reason := ""
var _held_weight := 0.0
var _grip_local := Transform3D.IDENTITY
var _bounds := AABB()
var _previous_pose := Transform3D.IDENTITY
var _velocity := Vector3.ZERO
var _spin := Vector3.ZERO
var _target_clock := 0.0
var _aim_commanded := false
var _trigger_command := false
var _saved_owned := {}
var _envelope := BoxShape3D.new()
var _shape_query := PhysicsShapeQueryParameters3D.new()
var _intended_target: WeakRef
var _native_gun_shape: CollisionShape3D
var _have_grip_orientation:=false
var _posture_shift:=Vector2.ZERO
var transport_body: WeakRef
var _custody_failure:=""
var _relative_velocity:=Vector3.ZERO
var _relative_spin:=Vector3.ZERO
var _previous_local_pose:=Transform3D.IDENTITY
var _recoil_recovery_left:=0.0
const RECOIL_RECOVERY_SECONDS:=1.0

func support_query_rids()->Array[RID]:
	var body: Node=transport_body.get_ref() if transport_body else null
	var owned: Array[RID] = []
	if body is RigidBody3D and is_instance_valid(body): owned.append(body.get_rid())
	return owned

func setup(helper: RigidBody3D) -> void:
	worker = helper
	name = "PortableToeGun"
	worker.add_child(self)
	worker.gun_anchor = Node3D.new()
	worker.gun_anchor.name = "EvaluatedToeGunGrip"
	worker.add_child(worker.gun_anchor)

func can_accept(item: Node3D) -> bool:
	if not is_instance_valid(worker) or not is_instance_valid(item) or not item.has_method("serialize_gun") or is_instance_valid(equipped): return false
	if worker.back_tool and worker.back_tool.busy(): return false
	var leap: Variant = worker.get("head_leap")
	if leap and leap.active(): return false
	if worker.paused or worker.fear_time>0.0 or not worker.on_ground or not worker.is_available() or worker.carrying or not worker.current_job_id.is_empty() or is_instance_valid(worker.station): return false
	if not worker.action.is_empty() and worker.work_target != self: return false
	if (worker.linear_velocity-worker.ground_velocity).length() > .35 or not worker.foot_grip_valid or not worker._pose.evaluated_valid: return false
	var support_side: int = 1-worker.control_foot_side()
	return worker._pose.evaluated_grounded[support_side]

func prepare(item: Node3D) -> bool:
	if not can_accept(item): return false
	preparing = weakref(item)
	_grip_local = _local_grip(item)
	_bounds = _model_bounds(item)
	_envelope.size = _bounds.size.max(Vector3(.012,.012,.012))
	worker.stop_navigation()
	worker.work_target = self
	worker.begin_action("operate")
	# Receive toward the exterior of the source, not an inherited idle look.
	# Ordinary supported turning and complete-stock clearance still admit it.
	var exterior: Vector3=(worker.global_position-item.global_position).slide(Vector3.UP)
	if exterior.length_squared()>.0001: worker.face_point(worker.global_position+exterior)
	worker.status_text = "Receiving gun with a foot"
	return true

func receiving_pose(item: Node3D) -> Transform3D:
	var grip := _grip_local if preparing or is_instance_valid(equipped) else _local_grip(item)
	if grip_valid: return actual_grip*grip.affine_inverse()
	var toe: Transform3D = worker.foot_grip_transform
	return Transform3D(toe.basis.orthonormalized(),toe.origin+toe.basis.y.normalized()*.035)*grip.affine_inverse()

func _rest_foot_control() -> Vector3:
	var side: int = worker.control_foot_side()
	var direction: Vector3 = -worker._model.global_basis.z
	var hip: Vector3 = worker.evaluated_hip(side)
	return hip+direction*.28-Vector3.UP*(.30+maxf(_bounds.end.y,0.0))

func foot_control_world(_side := 0) -> Vector3:
	return _rest_foot_control()+Vector3.UP*_posture_shift.x-worker._model.global_basis.z*_posture_shift.y

func _advance_grip_posture(delta: float) -> void:
	if not is_instance_valid(equipped) or not _have_grip_orientation: return
	var forward: Vector3=-worker._model.global_basis.z
	var wanted: Basis=Basis.looking_at(forward,Vector3.UP)*_grip_local.basis
	if desired_target.is_finite():
		var direction: Vector3=(desired_target-actual_grip.origin).normalized()
		if direction.length_squared()>.01 and absf(direction.dot(Vector3.UP))<.92:
			wanted=Basis.looking_at(direction,Vector3.UP)*_grip_local.basis
	var before: Quaternion=actual_grip.basis.orthonormalized().get_rotation_quaternion()
	var after: Quaternion=wanted.orthonormalized().get_rotation_quaternion()
	# Plan the same bounded next toe turn. Raising for the whole final angle
	# while the stock is still upright can crowd the cube.
	var next: Basis=Basis(before.slerp(after,minf(delta*2.0/maxf(before.angle_to(after),.000001),1.0))).orthonormalized()
	var rotations: Array[Basis]=[actual_grip.basis,next]
	var normal: Vector3=worker.ground_normal.normalized()
	if normal.dot(Vector3.UP)<.8: return
	var floor_point: Vector3=worker._ground_point
	var hip: Vector3=worker.evaluated_hip(worker.control_foot_side())
	var rest:=_rest_foot_control()
	var cube: Transform3D=worker.global_transform*worker._pose.evaluated_worker.affine_inverse()*worker._pose.evaluated_root
	var cube_inverse:=cube.affine_inverse()
	var cube_bounds:=AABB(Vector3(-.38,-.338,-.38),Vector3(.76,.676,.76))
	var half:=_bounds.size*.5
	var requested:=_posture_shift
	for advance_distance: float in [0.0,.015,.03,.045,.06,.075,.09,.105,.12,.135,.15,.165,.18,.195,.21,.225]:
		var base: Vector3=rest+forward*advance_distance
		var lift:=0.0
		for rotation: Basis in rotations:
			var gun_pose:=Transform3D(rotation,base)*_grip_local.affine_inverse()
			var radius:=0.0
			for axis in 3: radius+=absf(normal.dot(gun_pose.basis[axis]))*half[axis]
			var lowest: float=normal.dot(gun_pose*_bounds.get_center()-floor_point)-radius
			# Full rotating stock stays above the original native support plane;
			# the native complete-box query still checks every actual obstacle.
			lift=maxf(lift,(.06-lowest)/maxf(normal.dot(Vector3.UP),.001))
		var target: Vector3=base+Vector3.UP*maxf(0.0,lift)
		if target.distance_to(hip)>worker._leg_span(worker.control_foot_side())-.015: continue
		var clear_cube:=true
		for rotation: Basis in rotations:
			var gun_pose:=Transform3D(rotation,target)*_grip_local.affine_inverse()
			if worker._tool_box_intersects(cube_bounds,cube_inverse*gun_pose,_bounds): clear_cube=false; break
		if not clear_cube: continue
		var next_shift:=_posture_shift.move_toward(Vector2(maxf(0.0,lift),advance_distance),delta*.65)
		var next_origin: Vector3=rest+Vector3.UP*next_shift.x+forward*next_shift.y
		var retained_pose:=Transform3D(actual_grip.basis,next_origin)*_grip_local.affine_inverse()
		# Endpoints alone do not admit a translating stock beside the cube.
		if worker._tool_box_intersects(cube_bounds,cube_inverse*retained_pose,_bounds): continue
		requested=next_shift
		break
	# Request continuous ordinary IK, never write the part or body pose.
	# Original leg reach, opposite plant and full native envelope admit it.
	_posture_shift=requested

func accept(item: Node3D) -> bool:
	if not can_accept(item) or not receipt_ready(item): return false
	var target := receiving_pose(item)
	var relative: Quaternion=item.global_basis.get_rotation_quaternion().inverse()*target.basis.get_rotation_quaternion()
	var angle:=2.0*atan2(Vector3(relative.x,relative.y,relative.z).length(),absf(relative.w))
	if item.global_position.distance_to(target.origin)>.00001 or angle>.00001: return false
	if not item.unbind_carrier(): return false
	_grip_local = _local_grip(item)
	_bounds = _model_bounds(item)
	_envelope.size = _bounds.size.max(Vector3(.012,.012,.012))
	if _bounds.size.length()<.001: return false
	if item.get_parent(): item.reparent(worker.gun_anchor)
	else: worker.gun_anchor.add_child(item)
	equipped = item
	worker.equipped_gun = item
	item.is_equipped = false
	item.show()
	_held_weight = item.GunPhysics.mass_kg(item)
	worker.set_cargo(worker.cargo_mass)
	_native_gun_shape=CollisionShape3D.new()
	_native_gun_shape.name="ActualToeGunEnvelope"
	_native_gun_shape.shape=_envelope
	worker.add_child(_native_gun_shape)
	_sync_physical_payload(item.global_transform)
	preparing = null
	_custody_failure=""
	_relative_velocity=Vector3.ZERO
	_relative_spin=Vector3.ZERO
	_previous_pose = item.global_transform
	_previous_local_pose=worker.global_transform.affine_inverse()*item.global_transform
	_recoil_recovery_left=0.0
	item.fired.connect(_on_owned_gun_fired)
	worker.needs = ""
	worker.status_text = "Foot-held gun ready"
	return true

func _on_owned_gun_fired() -> void:
	# Only this owned gun's committed supported shot earns a bounded
	# custody recovery. The original firing admission still governs every shot.
	if is_instance_valid(equipped) and worker.equipped_gun==equipped \
		and equipped.get_parent()==worker.gun_anchor and equipped.firing_actor()==worker:
		_recoil_recovery_left=RECOIL_RECOVERY_SECONDS

func receipt_ready(item: Node3D) -> bool:
	return can_accept(item) and grip_valid and worker.stance_valid and worker.work_action_held and contact_gap<=.025 and _clear(receiving_pose(item),item)

func cancel_receive() -> void:
	if not is_instance_valid(equipped): _clear_pose()

func release_to(destination: Node3D) -> Node3D:
	if not is_instance_valid(equipped) or not is_instance_valid(destination) or not equipped.unbind_carrier(): return null
	var item := equipped
	item.drive_trigger(false)
	item.fired.disconnect(_on_owned_gun_fired)
	item.reparent(destination)
	equipped = null
	worker.equipped_gun = null
	_held_weight = 0.0
	_remove_physical_payload()
	worker.set_cargo(worker.cargo_mass)
	_clear_pose()
	return item

func payload_mass() -> float:
	return _held_weight

func custody_motion(pose: Transform3D)->Array[Vector3]:
	var native:=GroundItem.carrier_motion(worker,equipped,pose)
	var motion: Array[Vector3] = []
	if native.size()==2:
		motion.append(native[0]+_relative_velocity)
		motion.append(native[1]+_relative_spin)
	return motion

func payload_centre() -> Vector3:
	return equipped.global_transform*equipped.GunPhysics.center_local(equipped) if is_instance_valid(equipped) else worker.global_position

func idle_stance_claim() -> bool:
	var item: Node3D = preparing.get_ref() as Node3D if preparing else null
	var transported: Node=transport_body.get_ref() if transport_body else null
	return (is_instance_valid(equipped) or is_instance_valid(item) or is_instance_valid(transported)) and worker.on_ground and worker.fear_time<=0.0 and not worker.paused and worker.is_available() and worker.current_job_id.is_empty() and not is_instance_valid(worker.station)

func handoff_active() -> bool:
	var item: Node3D = preparing.get_ref() as Node3D if preparing else null
	var transported: Node=transport_body.get_ref() if transport_body else null
	return is_instance_valid(item) or is_instance_valid(equipped) or is_instance_valid(transported)

func transport_stance_claim() -> bool:
	var transported: Node=transport_body.get_ref() if transport_body else null
	return is_instance_valid(transported) and idle_stance_claim()

func busy() -> bool:
	return handoff_active()

func request_aim(target: Vector3, trigger := false, intended: Node3D = null) -> bool:
	if not is_instance_valid(equipped) or not target.is_finite(): return false
	desired_target = target
	_aim_commanded = true
	_trigger_command = trigger
	_intended_target=weakref(intended) if is_instance_valid(intended) else null
	return true

func defence_stance_ready() -> bool:
	# Read the same original gun and complete supported toe admission while it
	# turns toward a real threat. Cooldown never invents another gun or round.
	if not is_instance_valid(equipped) or not _supported_control_ready(equipped): return false
	var state: RefCounted = equipped.gun_state
	return state.initialized and state.ammo > 0 and state.condition > 0.0 and not state.jammed \
		and state.energy_wh >= equipped.shot_energy_wh

func control_ready(item: Node3D) -> bool:
	return aim_valid and _supported_control_ready(item)

func _supported_control_ready(item: Node3D) -> bool:
	if item != equipped or worker.equipped_gun != item or item.get_parent()!=worker.gun_anchor or worker.gun_anchor.get_parent()!=worker or not grip_valid: return false
	if worker.paused or worker.fear_time>0.0 or not worker.on_ground or not worker.stance_valid or not worker.is_available() or worker.carrying or not worker.current_job_id.is_empty() or is_instance_valid(worker.station): return false
	if worker.work_target!=self or worker.action!="operate" or not worker.work_action_held or not worker.foot_grip_valid or not worker._pose.evaluated_valid: return false
	if (worker.linear_velocity-worker.ground_velocity).length()>.25: return false
	var side: int = worker.work_foot_side
	if worker._pose.evaluated_balance_support_side != 1-side or not worker._pose.evaluated_grounded[1-side]: return false
	if contact_gap > .025 or not _clear(item.global_transform,item): return false
	var actual := item.global_transform*_grip_local
	var evaluated: Transform3D=worker.global_transform*worker._pose.evaluated_worker.affine_inverse()*actual_grip
	return actual.origin.distance_to(evaluated.origin)<.0001 and _basis_angle(actual.basis,evaluated.basis)<.0001

static func _basis_angle(a: Basis,b: Basis)->float:
	var turn:=a.orthonormalized().get_rotation_quaternion().normalized().inverse()*b.orthonormalized().get_rotation_quaternion().normalized()
	return 2.0*atan2(Vector3(turn.x,turn.y,turn.z).length(),absf(turn.w))

func advance(delta: float) -> void:
	if not is_instance_valid(worker): return
	_recoil_recovery_left=maxf(_recoil_recovery_left-delta,0.0)
	if not _saved_owned.is_empty() and not worker.get_tree().get_nodes_in_group(&"shared_gun_handoffs").is_empty():
		var pending := _saved_owned
		_saved_owned = {}
		_restore_owned_after_systems(pending)
	var preparing_item: Node3D = preparing.get_ref() as Node3D if preparing else null
	if not is_instance_valid(equipped) and not is_instance_valid(preparing_item): return
	if worker.paused or worker.fear_time>0.0 or not worker.is_available() or not worker.current_job_id.is_empty() or is_instance_valid(worker.station) or worker.carrying:
		interrupt("Useful work or danger interrupted the gun grip")
		return
	if is_instance_valid(equipped) and (not worker.on_ground or not _custody_failure.is_empty()):
		interrupt(_custody_failure if not _custody_failure.is_empty() else "Gun dropped when native ground support was lost")
		return
	if is_instance_valid(equipped):
		var support_side: int=1-worker.work_foot_side
		# Read the completed pose publication, including the final actual sole
		# distance test that follows this module's toe evaluation hook.
		if not worker._pose.evaluated_valid or (worker._pose.evaluated_balance_support_side!=support_side and worker._pose.evaluated_balance_support_side!=-1) or not worker.foot_grip_valid:
			interrupt("Gun dropped when its fully evaluated supported foot stance was lost")
			return
		if not worker.stance_valid or not worker._pose.evaluated_grounded[support_side] or worker._pose.evaluated_balance_support_side!=support_side:
			equipped.cancel_trigger()
			aim_valid=false
			# Native braking and the original sole release/replant remain in
			# charge, including its transient -1 balance publication.
			# Lost support never admits another shot during recovery.
			if _recoil_recovery_left<=0.0:
				interrupt("Gun dropped when its fully evaluated supported foot stance was lost")
				return
	worker.stop_navigation()
	worker.work_target = self
	if worker.action.is_empty(): worker.begin_action("operate")
	if worker.action=="operate" and worker.action_progress>=.50: worker.set_work_action_held(true)
	if not is_instance_valid(equipped): return
	_target_clock -= delta
	if _target_clock <= 0.0:
		_target_clock = .15
		if not _aim_commanded: desired_target = _nearest_threat()
	_advance_grip_posture(delta)
	if not desired_target.is_finite():
		aim_valid = false
		equipped.cancel_trigger()
		return
	# The receiving pose already earned its opposite planted sole. Aim the
	# real gun through the existing finite toe turn; rotating the whole rig
	# toward that second target releases the single support under custody.
	var tip: Node3D = equipped.local_muzzle()
	if not is_instance_valid(tip): return
	var direction := (desired_target-tip.global_position).normalized()
	aim_valid = (-tip.global_basis.z.normalized()).dot(direction)>=.997
	if control_ready(equipped):
		if equipped._gun_binding==null or equipped.firing_actor()!=worker:
			if not equipped.bind_carrier(worker,worker,tip,null,"wako",worker.query_exclusions()): return
		var query := PhysicsRayQueryParameters3D.create(tip.global_position,desired_target,1,worker.query_exclusions())
		var hit := worker.get_world_3d().direct_space_state.intersect_ray(query)
		var intended: Node = _intended_target.get_ref() if _intended_target else null
		var clear_line: bool = hit.is_empty() or hit.position.distance_to(desired_target)<.20 or is_instance_valid(intended) and hit.collider==intended
		var trigger: bool = _trigger_command if _aim_commanded else not equipped.autonomous_release_ready()
		if clear_line and aim_valid:
			equipped.drive_trigger(trigger,trigger and equipped._cooldown<=0.0)
		else: equipped.cancel_trigger()
		if trigger and clear_line and equipped.ammo==0 and equipped.reserve>0: equipped.reload()
	else:
		equipped.cancel_trigger()

func evaluate(sk: Skeleton3D, delta: float) -> void:
	grip_valid = false
	var item: Node3D = equipped
	if not is_instance_valid(item) and preparing: item=preparing.get_ref() as Node3D
	# A released gun has no pose to evaluate. Keep its actual interruption
	# reason available to the existing public readout until a new receipt.
	if not is_instance_valid(item): return
	if worker.work_target!=self or worker.action!="operate" or not worker.on_ground or not worker.is_available():
		reason="Toe evaluation awaiting actual gun and supported operating action"
		if is_instance_valid(equipped): _custody_failure="Gun dropped when its evaluated toe grip was lost"
		return
	var side: int = worker.work_foot_side
	if is_instance_valid(equipped) and (not worker.stance_valid or not worker._pose.evaluated_grounded[1-side]) and _recoil_recovery_left<=0.0:
		_custody_failure="Gun dropped when the opposite planted sole lost support"
		return
	var toe_id: int = worker._pose._toes[side]
	if toe_id<0:
		if is_instance_valid(equipped): _custody_failure="Gun dropped because its actual toe bone is unavailable"
		return
	var toe := sk.get_bone_global_pose(toe_id)
	var world := sk.global_transform*toe
	var contact_origin:=world.origin+world.basis.y.normalized()*.035
	var forward: Vector3=-worker._model.global_basis.z
	var desired_basis := Basis.looking_at(forward,Vector3.UP)*_grip_local.basis
	if desired_target.is_finite():
		var direction := (desired_target-(world.origin+world.basis.y*.035)).normalized()
		if direction.length_squared()>.01 and absf(direction.dot(Vector3.UP))<.92:
			desired_basis = Basis.looking_at(direction,Vector3.UP)*_grip_local.basis
	var previous: Basis = actual_grip.basis if _have_grip_orientation else world.basis
	var before := previous.orthonormalized().get_rotation_quaternion()
	var after := desired_basis.orthonormalized().get_rotation_quaternion()
	var stepped := Basis(before.slerp(after,minf(delta*2.0/maxf(before.angle_to(after),.000001),1.0))).orthonormalized()
	var origin := contact_origin
	var candidate := Transform3D(stepped,origin)*_grip_local.affine_inverse()
	if is_instance_valid(equipped) and not _clear(candidate,item):
		# Let the actual foot raise the rear stock before a requested turn.
		# Retain a verified orientation at this new toe; never turn through
		# the floor/cube or admit an unaligned bore.
		var retained:=Transform3D(previous.orthonormalized(),origin)*_grip_local.affine_inverse()
		if not _clear(retained,item):
			aim_valid = false
			if reason.is_empty(): reason = "Complete gun blocked beside the foot"
			_custody_failure="Gun dropped: "+reason
			return
		stepped=previous.orthonormalized()
		candidate=retained
		aim_valid=false
	if is_instance_valid(equipped) and origin.distance_to(foot_control_world(side))>.025:
		_custody_failure="Gun dropped when the actual toe could no longer reach its grip"
		return
	toe.basis = sk.global_basis.inverse()*stepped
	# Rotate the real rounded toe around its evaluated contact point. Keeping
	# its origin fixed instead displaced the grip by the toe-radius offset.
	toe.origin=sk.global_transform.affine_inverse()*(origin-stepped.y*.035)
	sk.set_bone_global_pose(toe_id,toe)
	actual_grip = Transform3D(stepped,origin)
	contact_gap = origin.distance_to(foot_control_world(side))
	grip_valid = true
	_have_grip_orientation=true
	reason=""
	worker.gun_anchor.global_transform = actual_grip
	if is_instance_valid(equipped):
		var target := actual_grip*_grip_local.affine_inverse()
		_velocity = (target.origin-_previous_pose.origin)/maxf(delta,.000001)
		var turn := _previous_pose.basis.orthonormalized().get_rotation_quaternion().inverse()*target.basis.get_rotation_quaternion()
		_spin = _previous_pose.basis*turn.get_axis()*turn.get_angle()/maxf(delta,.000001) if absf(turn.get_angle())>.000001 else Vector3.ZERO
		_velocity+=_spin.cross(target.basis*equipped.GunPhysics.center_local(equipped))
		var local:=worker.global_transform.affine_inverse()*target
		var center: Vector3=equipped.GunPhysics.center_local(equipped)
		_relative_velocity=worker.global_basis*((local*center-_previous_local_pose*center)/maxf(delta,.000001))
		var relative_turn:=_previous_local_pose.basis.orthonormalized().get_rotation_quaternion().inverse()*local.basis.orthonormalized().get_rotation_quaternion()
		if relative_turn.w<0.0: relative_turn=-relative_turn
		_relative_spin=worker.global_basis*(_previous_local_pose.basis*relative_turn.get_axis()*relative_turn.get_angle()/maxf(delta,.000001)) if absf(relative_turn.get_angle())>.000001 else Vector3.ZERO
		_previous_local_pose=local
		equipped.global_transform = target
		_sync_physical_payload(target)
		_previous_pose = target
		# Skeleton publication may follow advance(). Publish readiness from
		# this verified CURRENT muzzle, including a retained safe turn.
		# A blocked future turn is not a loss of an aligned actual grip.
		var tip: Node3D=equipped.local_muzzle()
		aim_valid=false
		if desired_target.is_finite() and is_instance_valid(tip):
			var aiming: Vector3=(desired_target-tip.global_position).normalized()
			aim_valid=(-tip.global_basis.z.normalized()).dot(aiming)>=.997

func sync_native() -> void:
	if not grip_valid or not is_instance_valid(equipped) or not worker._pose.evaluated_valid: return
	var rebase: Transform3D = worker.global_transform*worker._pose.evaluated_worker.affine_inverse()
	worker.gun_anchor.global_transform = rebase*actual_grip
	_sync_physical_payload(equipped.global_transform)

func _sync_physical_payload(pose: Transform3D) -> void:
	if not is_instance_valid(equipped) or not is_instance_valid(_native_gun_shape): return
	_native_gun_shape.transform=worker.global_transform.affine_inverse()*pose*Transform3D(Basis.IDENTITY,_bounds.get_center())
	# The holder and actual onboard tool/cargo retain their own measured COM.
	# This accessor is supplied by the finite holder integration.
	var attached: Dictionary = worker.attached_payload_centre()
	var gun_point: Vector3 = pose*equipped.GunPhysics.center_local(equipped)
	var total_mass: float = float(attached.mass)+_held_weight
	worker.center_of_mass_mode=RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	worker.center_of_mass=worker.to_local((Vector3(attached.point)*float(attached.mass)+gun_point*_held_weight)/maxf(total_mass,.001))

func _remove_physical_payload() -> void:
	if is_instance_valid(_native_gun_shape):
		_native_gun_shape.disabled=true
		_native_gun_shape.queue_free()
		_native_gun_shape=null
	worker._sync_attached_payload()

func interrupt(message: String) -> void:
	var transported: Node = transport_body.get_ref() if transport_body else null
	if is_instance_valid(transported):
		for service: Node in worker.get_tree().get_nodes_in_group(&"shared_gun_handoffs"):
			if service.busy() and service.passing == transported: service.cancel(message)
	if is_instance_valid(equipped):
		# Interruption cancels charging without committing a release-trigger shot.
		equipped.cancel_trigger()
		var services := worker.get_tree().get_nodes_in_group(&"shared_gun_handoffs")
		if services.is_empty(): equipped.drive_trigger(false); reason="Gun support lost; awaiting physical custody"; return
		var item := equipped
		var pose := item.global_transform
		var motion:=custody_motion(pose)
		if not item.unbind_carrier(): item.drive_trigger(false); return
		# Publish the existing interruption at the same real reparent event.
		# A refused physical drop retains its previous feedback.
		var previous_reason: String = reason
		reason = message
		if not services[0].drop(item,pose,motion[0] if motion.size()==2 else _velocity,motion[1] if motion.size()==2 else _spin):
			reason = previous_reason
			return
		item.fired.disconnect(_on_owned_gun_fired)
		equipped = null
		worker.equipped_gun = null
		_held_weight = 0.0
		_remove_physical_payload()
		worker.set_cargo(worker.cargo_mass)
		# Only our own former gun-ready captions become this real drop reason.
		# A useful job or danger controller retains its current status.
		if worker.status_text in ["Foot-held gun ready", "Supported foot-held gun"]:
			worker.status_text = message
	_clear_pose()
	reason = message

func _clear_pose() -> void:
	_recoil_recovery_left=0.0
	preparing = null
	_custody_failure=""
	_relative_velocity=Vector3.ZERO
	_relative_spin=Vector3.ZERO
	desired_target = Vector3.INF
	grip_valid = false
	_have_grip_orientation=false
	_posture_shift=Vector2.ZERO
	aim_valid = false
	_aim_commanded = false
	_trigger_command = false
	_intended_target=null
	if worker.work_target==self:
		worker.set_work_action_held(false)
		worker.work_target = null
		worker.action = ""

func _nearest_threat() -> Vector3:
	var closest := 25.0
	var result := Vector3.INF
	_intended_target=null
	for fauna: Node in worker.get_tree().get_nodes_in_group(&"machine_fauna"):
		# Use the existing live hostile brain/core policy. A rebuilt or tamed
		# same-body machine is no longer an autonomous foot-gun target.
		var core: Node3D = GunControl.live_hostile_core(fauna)
		if not is_instance_valid(core): continue
		var distance := worker.global_position.distance_to(core.global_position)
		if distance<closest: closest=distance; result=core.global_position; _intended_target=weakref(core)
	return result

func _clear(pose: Transform3D, item: Node3D) -> bool:
	var bounds := _bounds if _bounds.size.length()>.001 else _model_bounds(item)
	if bounds.size.length()<.001: return false
	var query := _shape_query
	query.shape = _envelope
	query.transform = pose*Transform3D(Basis.IDENTITY,bounds.get_center())
	query.collision_mask = 5
	var exclusions: Array[RID] = worker.query_exclusions()
	var ancestor: Node = item.get_parent()
	while is_instance_valid(ancestor) and ancestor!=worker:
		if ancestor is CollisionObject3D and ancestor.get_meta(&"loose_shared_gun",false): exclusions.append(ancestor.get_rid())
		ancestor=ancestor.get_parent()
	query.exclude=exclusions
	var cube: Transform3D = worker.global_transform*worker._pose.evaluated_worker.affine_inverse()*worker._pose.evaluated_root if worker._pose.evaluated_valid else worker._skeleton.global_transform*worker._skeleton.get_bone_global_pose(0)
	var relative: Transform3D = cube.affine_inverse()*pose
	# A tilted full-stock box has empty corners in its enclosing AABB.
	# Reuse the existing exact oriented contact test with the same padded
	# cube and full gun envelope; native floor/obstacle queries stay intact.
	if worker._tool_box_intersects(AABB(Vector3(-.38,-.338,-.38),Vector3(.76,.676,.76)),relative,bounds): reason="Gun envelope would touch Wako's cube"; return false
	var contacts:=worker.get_world_3d().direct_space_state.intersect_shape(query,1)
	if not contacts.is_empty(): reason="Gun envelope blocked by "+str(contacts[0].collider.get_path())
	return contacts.is_empty()

static func _relative(root: Node3D, node: Node3D) -> Transform3D:
	var frame := node.transform
	var ancestor: Node = node.get_parent()
	while is_instance_valid(ancestor) and ancestor!=root:
		if ancestor is Node3D: frame=(ancestor as Node3D).transform*frame
		ancestor=ancestor.get_parent()
	return frame

static func _local_grip(item: Node3D) -> Transform3D:
	var marker := item.find_child("Grip",true,false) as Node3D
	return _relative(item,marker) if is_instance_valid(marker) else Transform3D.IDENTITY

static func _model_bounds(item: Node3D) -> AABB:
	return item.GunPhysics.envelope_local(item)

func serialize_owned() -> Dictionary:
	if not is_instance_valid(equipped): return _saved_owned.duplicate(true)
	if equipped.get_parent() != worker.gun_anchor or worker.equipped_gun != equipped: return {}
	var pose := equipped.global_transform
	var q := pose.basis.orthonormalized().get_rotation_quaternion()
	var motion:=custody_motion(pose)
	var velocity: Vector3=motion[0] if motion.size()==2 else _velocity
	var spin: Vector3=motion[1] if motion.size()==2 else _spin
	return {"gun":equipped.serialize_gun(),"position":[pose.origin.x,pose.origin.y,pose.origin.z],
		"rotation":[q.x,q.y,q.z,q.w],"velocity":[velocity.x,velocity.y,velocity.z],"spin":[spin.x,spin.y,spin.z]}

func restore_owned(data: Dictionary) -> void:
	# Fresh worker restoration is normal. A live occupied toe keeps its actual
	# existing item; a second loaded record must not mint another payload.
	if is_instance_valid(equipped): reason="Release the existing toe gun before restoring another owner"; return
	_saved_owned = data.duplicate(true)

func _restore_owned_after_systems(data: Dictionary) -> void:
	# Restore into actual loose custody at the saved helper pose. A reloaded
	# game must earn supported toe contact again, rather than claim old IK.
	var services := worker.get_tree().get_nodes_in_group(&"shared_gun_handoffs")
	if services.is_empty(): return
	if not services[0].restore_loose_record(data, worker.linear_velocity): reason = "Saved toe gun record was refused: invalid stock or an existing owner."

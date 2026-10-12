extends RefCounted
## Wako's visible native bones and supported return. Native body transforms,
## joints, hit impulses and get-up admission remain the ragdoll's responsibility.
const RETURN_TIME := .25
var _remembered: Array[Transform3D] = []
var _remembered_worker := Transform3D.IDENTITY
var _return_bones: Array[Transform3D] = []
var _return_worker := Transform3D.IDENTITY
var _return_age := 0.0
var _desired: Array[Transform3D] = []
var _written: Array[Transform3D] = []
var _surface_query := PhysicsRayQueryParameters3D.new()

func remember(worker: RigidBody3D, skeleton: Skeleton3D) -> void:
	_remembered.resize(skeleton.get_bone_count())
	for bone in _remembered.size():
		_remembered[bone]=skeleton.global_transform*skeleton.get_bone_global_pose(bone)
	_remembered_worker=worker.global_transform

func restore_actual(worker: RigidBody3D, skeleton: Skeleton3D) -> void:
	if _remembered.size()!=skeleton.get_bone_count(): return
	# Cancellation seeks an authored interruption clip. Native capture must
	# instead retain the actual last visible rig, carried by current body motion.
	var rebase: Transform3D = worker.global_transform*_remembered_worker.affine_inverse()
	var inverse: Transform3D = skeleton.global_transform.affine_inverse()
	for bone in _remembered.size(): skeleton.set_bone_global_pose(bone,inverse*(rebase*_remembered[bone]))

func write(skeleton: Skeleton3D, bodies: Array, world_bones: Array[Transform3D], weights: PackedFloat32Array) -> void:
	var inverse: Transform3D = skeleton.global_transform.affine_inverse()
	for body in bodies:
		var weight: float = weights[body.index]
		if weight<=.0005: continue
		var desired: Transform3D = inverse*world_bones[body.index]
		if weight<.9995: desired=skeleton.get_bone_global_pose(body.bone).interpolate_with(desired,weight)
		# Godot bone poses are absolute parent-local TRS. This API converts from
		# skeleton globals; preserving only rotations loses Wako's evaluated IK
		# joint positions and native joint compliance during the fall.
		skeleton.set_bone_global_pose(body.bone,desired)
	_written.resize(bodies.size())
	for body in bodies: _written[body.index]=skeleton.global_transform*skeleton.get_bone_global_pose(body.bone)

func begin_return(worker: RigidBody3D, bodies: Array, current: Array[Transform3D]) -> void:
	_return_bones.resize(bodies.size())
	# The get-up gate runs on a newer native tick than the last rendered
	# modifier. Continue that actual last visible frame, including fast ankles,
	# while the original controller still restores its newest native velocity.
	for body in bodies: _return_bones[body.index]=_written[body.index] if _written.size()==bodies.size() else current[body.index]*body.b2b
	_return_worker=worker.global_transform
	_return_age=0.0

func is_returning() -> bool:
	return not _return_bones.is_empty()

func continue_return(worker: RigidBody3D, skeleton: Skeleton3D, bodies: Array, delta: float) -> void:
	if not is_returning(): return
	_return_age+=delta
	var fraction: float = smoothstep(0.0,RETURN_TIME,_return_age)
	var rebase: Transform3D = worker.global_transform*_return_worker.affine_inverse()
	var inverse: Transform3D = skeleton.global_transform.affine_inverse()
	_desired.resize(bodies.size())
	for body in bodies: _desired[body.index]=skeleton.global_transform*skeleton.get_bone_global_pose(body.bone)
	# Read all target globals before changing any parent. Otherwise children
	# inherit both the parent continuation and their own continuation.
	for body in bodies:
		var source: Transform3D = rebase*_return_bones[body.index]
		skeleton.set_bone_global_pose(body.bone,inverse*source.interpolate_with(_desired[body.index],fraction))
	var pose: SkeletonModifier3D = worker._pose
	pose.evaluated_root=skeleton.global_transform*skeleton.get_bone_global_pose(0)
	pose.evaluated_worker=worker.global_transform
	pose.evaluated_basis=skeleton.global_basis
	_surface_query.exclude=worker.query_exclusions()
	_surface_query.collision_mask=1
	for side in 2:
		var chain: Array = pose._chains[side]
		var foot: Transform3D = skeleton.get_bone_global_pose(chain[2])
		pose.evaluated_hips[side]=skeleton.global_transform*skeleton.get_bone_global_pose(chain[0]).origin
		pose.evaluated_knees[side]=skeleton.global_transform*skeleton.get_bone_global_pose(chain[1]).origin
		pose.evaluated_ankles[side]=skeleton.global_basis*foot.basis
		pose.evaluated_soles[side]=skeleton.global_transform*(foot*Vector3(0,pose._ankle_height[side],0))
		_surface_query.from=pose.evaluated_soles[side]
		_surface_query.from.y=maxf(pose.evaluated_soles[side].y+.5,worker.global_position.y+.12)
		_surface_query.to=pose.evaluated_soles[side]-Vector3.UP*.5
		var surface := worker.get_world_3d().direct_space_state.intersect_ray(_surface_query)
		pose.evaluated_grounded[side]=not surface.is_empty() and surface.normal.y>.6 and absf(surface.normal.dot(pose.evaluated_soles[side]-surface.position))<=.035
		pose._terrain_points[side]=Vector3.INF if surface.is_empty() else surface.position
		pose._sole_normals[side]=Vector3.UP if surface.is_empty() else surface.normal
		if not pose.evaluated_grounded[side]: pose._target_valid[side]=false
	pose.evaluated_visual_com=pose._posed_center_of_mass(skeleton)
	pose.evaluated_valid=true
	pose.evaluation_serial+=1
	worker._update_head(pose.evaluated_root)
	worker._update_work_tool(true)
	remember(worker,skeleton)
	if _return_age>=RETURN_TIME: _return_bones.clear()

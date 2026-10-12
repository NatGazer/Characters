extends RefCounted
## Authored grounded-hit variants on the existing armless rig.
## Contact observations select a pose; this module never applies native forces.
const DIRECTIONS := {"front":Vector3.FORWARD,"back":Vector3.BACK,"left":Vector3.LEFT,"right":Vector3.RIGHT}
const KEYS := [[0.0,0.0],[.12,.45],[.26,1.0],[.48,.55],[.72,.12],[1.0,0.0]]
static var _shared_library: AnimationLibrary
var worker: RigidBody3D
var last_direction := ""
var last_impulse := Vector3.ZERO
var last_point := Vector3.ZERO
var events := 0
var _cooldown := 0.0
var _damage_pending := false
var _damage_velocity_before := Vector3.ZERO
var _damage_point := Vector3.INF

func setup(owner: RigidBody3D) -> void:
	worker = owner
	if _shared_library:
		worker._animation.add_animation_library("recoil",_shared_library)
		return
	var library := AnimationLibrary.new()
	for direction: String in DIRECTIONS:
		for side: String in ["L","R"]:
			var source: Animation = worker._animation.get_animation("wk_interrupted_"+side)
			var clip := source.duplicate(true) as Animation
			clip.loop_mode = Animation.LOOP_NONE
			for track in range(clip.get_track_count()-1,-1,-1):
				if clip.track_get_type(track) == Animation.TYPE_METHOD:
					clip.remove_track(track)
				elif clip.track_get_type(track) == Animation.TYPE_ROTATION_3D and clip.track_get_path(track).get_subname(0) == "Bone":
					# The copied leg curves retain the original recoil timing. These
					# fixed cube keys give the actual impact a readable direction.
					var rotations: Array[Quaternion] = []
					for key: Array in KEYS: rotations.append(source.rotation_track_interpolate(track,float(key[0])*source.length))
					while clip.track_get_key_count(track)>0: clip.track_remove_key(track,0)
					var away: Vector3 = -DIRECTIONS[direction]
					var axis := Vector3.UP.cross(away).normalized()
					for key in KEYS.size():
						clip.rotation_track_insert_key(track,float(KEYS[key][0])*clip.length,Quaternion(axis,deg_to_rad(6.0)*float(KEYS[key][1]))*rotations[key])
			library.add_animation(direction+"_"+side,clip)
	_shared_library = library
	worker._animation.add_animation_library("recoil",library)

func observe_contacts(state: PhysicsDirectBodyState3D) -> void:
	_cooldown = maxf(_cooldown-state.step,0.0)
	if _damage_pending:
		_damage_pending = false
		# Core has already funded this native velocity change. Observe it once,
		# sharing the original damage/knockdown watch without adding an impulse.
		react((state.linear_velocity-_damage_velocity_before)*worker.mass,_damage_point)
	if _cooldown > 0.0 or not is_instance_valid(worker) or not worker.on_ground or not worker.is_available(): return
	var strongest := Vector3.ZERO
	var point := Vector3.ZERO
	for contact in state.get_contact_count():
		var impulse := state.get_contact_impulse(contact)
		if impulse.length_squared() > strongest.length_squared():
			strongest = impulse
			point = state.get_contact_collider_position(contact)
	# These are the existing native stumble and knockdown boundaries, not new
	# impact funding. Stronger hits retain the original ragdoll transition.
	var speed := strongest.length()/maxf(worker.mass,1.0)
	if speed > 2.5 and speed <= 3.5: react(strongest,point)

func watch_damage(velocity_before: Vector3, point: Vector3) -> void:
	if not velocity_before.is_finite(): return
	_damage_velocity_before = velocity_before
	_damage_point = point
	_damage_pending = true

func react(impulse: Vector3, point := Vector3.INF) -> bool:
	if _cooldown > 0.0 or not is_instance_valid(worker) or not worker.on_ground or not worker.is_available(): return false
	if not impulse.is_finite() or (not point.is_finite() and point != Vector3.INF): return false
	var speed := impulse.length()/maxf(worker.mass,1.0)
	if speed <= 2.5 or speed > 3.5: return false
	var incoming: Vector3 = point-worker.global_position if point.is_finite() else -impulse
	var local: Vector3 = (worker._model.global_basis.inverse()*incoming).slide(Vector3.UP)
	if local.length_squared() < .001: return false
	last_direction = ("right" if local.x > 0.0 else "left") if absf(local.x)>absf(local.z) else ("back" if local.z>0.0 else "front")
	last_impulse = impulse
	last_point = point
	events += 1
	_cooldown = .65
	worker.interrupt("Hit; recovering footing")
	var side: String = "L" if worker.work_foot_side == 0 else "R"
	var clip: String = "recoil/"+last_direction+"_"+side
	# A distinct hit can arrive after cooldown while the previous interrupted
	# action is still active. Its authored recovery owns a fresh action clock,
	# even though generic repeat interruptions intentionally do not restart it.
	worker._action_time = 0.0
	worker.action_progress = 0.0
	worker._action_length = worker._animation.get_animation(clip).length
	worker._animation.play(clip,.18)
	worker._animation.seek(0.0,false)
	return true

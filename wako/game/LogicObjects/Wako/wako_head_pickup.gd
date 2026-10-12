extends RefCounted
## Supported head pickup keeps the original work contact and duration.
## Idle limbs retain their real terrain IK; only the cube makes a small dip.
const LIBRARY := "head_pickup"
static var _shared_library: AnimationLibrary
const MAXIMUM_DIP := .04

static func install(worker: RigidBody3D) -> void:
	var player: AnimationPlayer = worker._animation
	if player.has_animation_library(LIBRARY): return
	if _shared_library:
		player.add_animation_library(LIBRARY,_shared_library)
		return
	var idle: Animation = player.get_animation("wk_idle")
	var library := AnimationLibrary.new()
	for side: String in ["L", "R"]:
		var original: Animation = player.get_animation("work/pickup_" + side)
		var clip := original.duplicate(true) as Animation
		var root_name: String = worker._skeleton.get_bone_name(0)
		var event_count := 0
		for track in clip.get_track_count():
			var type := clip.track_get_type(track)
			var path := clip.track_get_path(track)
			if type == Animation.TYPE_METHOD:
				for key in clip.track_get_key_count(track):
					var event: Dictionary = clip.track_get_key_value(track,key)
					if event.get("method") == "_work_contact" and event.get("args") == ["pickup"]:
						assert(absf(clip.track_get_key_time(track,key)-clip.length*.56)<.00001)
						event_count += 1
				continue
			if type not in [Animation.TYPE_POSITION_3D,Animation.TYPE_ROTATION_3D,Animation.TYPE_SCALE_3D]: continue
			var is_root := path.get_subname_count()>0 and String(path.get_subname(path.get_subname_count()-1))==root_name
			if not is_root:
				var idle_track := idle.find_track(path,type)
				assert(idle_track>=0, "Every authored limb track must have its existing idle counterpart")
				for key in clip.track_get_key_count(track):
					var idle_time := clip.track_get_key_time(track,key)/clip.length*idle.length
					var value: Variant
					if type == Animation.TYPE_POSITION_3D: value = idle.position_track_interpolate(idle_track,idle_time)
					elif type == Animation.TYPE_ROTATION_3D: value = idle.rotation_track_interpolate(idle_track,idle_time)
					else: value = idle.scale_track_interpolate(idle_track,idle_time)
					clip.track_set_key_value(track,key,value)
			elif type == Animation.TYPE_POSITION_3D:
				var base: Vector3 = clip.track_get_key_value(track,0)
				var original_dip := 0.0
				for key in clip.track_get_key_count(track):
					var position: Vector3 = clip.track_get_key_value(track,key)
					original_dip = maxf(original_dip,base.y-position.y)
				for key in clip.track_get_key_count(track):
					var position: Vector3 = clip.track_get_key_value(track,key)
					var offset := position-base
					offset.x *= .25
					offset.z *= .25
					offset.y *= minf(MAXIMUM_DIP/maxf(original_dip,.00001),1.0)
					clip.track_set_key_value(track,key,base+offset)
			elif type == Animation.TYPE_ROTATION_3D:
				var base: Quaternion = clip.track_get_key_value(track,0)
				for key in clip.track_get_key_count(track):
					var value: Quaternion = clip.track_get_key_value(track,key)
					clip.track_set_key_value(track,key,base.slerp(value,.35).normalized())
		assert(event_count==1 and is_equal_approx(clip.length,original.length))
		library.add_animation("pickup_"+side,clip)
	_shared_library = library
	player.add_animation_library(LIBRARY,library)

static func eligible(worker: RigidBody3D, kind: String) -> bool:
	if kind!="pickup" or not worker.pickup or not worker.pickup.state.is_empty(): return false
	if not worker.on_ground or worker.pickup.manipulating(): return false
	if not is_instance_valid(worker.coordinator): return false
	var entry: Dictionary = worker.coordinator.active_jobs.get(worker.current_job_id,{})
	if entry.is_empty() or entry.phase!="pickup" or entry.job.get("light_pickup",false): return false
	if entry.job.kind not in ["build","replace","salvage"] or not entry.crew.has(worker): return false
	var source: Node3D = entry.job.get("part")
	if not is_instance_valid(source) or not is_instance_valid(worker.work_target): return false
	# Heavy build assignment keeps the planned target bound throughout fetching;
	# only present_pickup for the excluded light branch binds the source itself.
	if worker.work_target!=entry.job.target: return false
	var reservation: Dictionary = worker.coordinator.yard._reservations.get(entry.job.id,{})
	return reservation.get("part_instance",0)==source.get_instance_id() and reservation.get("workers",[])==entry.crew.map(func(member:Node)->int:return member.get_instance_id())

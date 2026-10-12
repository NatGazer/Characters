extends Node3D
## The canonical standalone scene and raw source keep the same imported clips;
## helper contact tracks must not overwrite animations or assume seven bones.
const Source := preload("res://LogicObjects/Wako/Wako.blend")
const Worker := preload("res://LogicObjects/Wako/Wako.tscn")
const HolderVisual := preload("res://LogicObjects/Wako/wako_back_holder_visual.gd")
var failures := 0
var checks := 0

func _ready() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks += 1
	print("CONTRAPTION_WAKO_ASSET %s %s" % ["ok" if ok else "FAIL", label])
	if not ok: failures += 1

func _advance(ticks: int) -> void:
	for tick in ticks: await get_tree().physics_frame

func _run() -> void:
	var floor := StaticBody3D.new()
	add_child(floor)
	floor.position.y = -.5
	var collider := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(30, 1, 30)
	collider.shape = box
	floor.add_child(collider)
	var source := Source.instantiate()
	add_child(source)
	source.position.x = -1.2
	var animation: AnimationPlayer = source.get_node("AnimationPlayer")
	var skeleton := source.find_child("Skeleton3D", true, false) as Skeleton3D
	_check(skeleton.get_bone_count() == 9 and skeleton.get_bone_name(0) == "Bone"
		and skeleton.find_bone("toe.L") >= 0 and skeleton.find_bone("toe.R") >= 0,
		"raw canonical source has named nine-bone rig and retains its rigid head root")
	var skin := source.find_child("wakoMesh", true, false) as MeshInstance3D
	var foot_min := [Vector3.INF, Vector3.INF]
	var foot_max := [-Vector3.INF, -Vector3.INF]
	var toe_skin := [false, false]
	var bind_bones: Array[int] = []
	if skin.skin != null:
		for bind in skin.skin.get_bind_count():
			var name: StringName = skin.skin.get_bind_name(bind)
			bind_bones.append(skeleton.find_bone(name) if not name.is_empty() else skin.skin.get_bind_bone(bind))
	for surface in skin.mesh.get_surface_count():
		var arrays: Array = skin.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bindings: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var stride := bindings.size() / vertices.size()
		for index in vertices.size():
			# Imported vertex coordinates retain the authored source rest space.
			# The mesh node shares the armature offset; skin bind transforms cancel
			# that offset, so adding its node transform counts the offset twice.
			var point: Vector3 = vertices[index]
			if point.y > .14 or absf(point.x) < .05: continue
			var side := 0 if point.x < 0 else 1
			foot_min[side] = foot_min[side].min(point)
			foot_max[side] = foot_max[side].max(point)
			for influence in stride:
				var offset := index * stride + influence
				var bind := bindings[offset]
				var bone := bind_bones[bind] if bind >= 0 and bind < bind_bones.size() else -1
				if bone == skeleton.find_bone("toe.L" if side == 0 else "toe.R") and weights[offset] > .01:
					toe_skin[side] = true
	var rounded := true
	for side in 2:
		var extent: Vector3 = foot_max[side] - foot_min[side]
		rounded = rounded and extent.is_finite() and extent.x < .20 and extent.z < .22
		print("CONTRAPTION_WAKO_END side=%d extent=%s toe_skin=%s" % [side,extent,toe_skin[side]])
	_check(rounded and toe_skin.all(func(value: bool) -> bool: return value),
		"compact original leg endings replace boot pads and both finite toe grips deform their real skin")
	var clips: Array[StringName] = []
	var source_tracks := {}
	var valid_bindings := true
	var source_methods := 0
	var animation_root: Node = animation.get_node(animation.root_node)
	for name: StringName in animation.get_animation_list():
		if not String(name).begins_with("wk_"): continue
		clips.append(name)
		var clip := animation.get_animation(name)
		source_tracks[name] = clip.get_track_count()
		for index in clip.get_track_count():
			if clip.track_get_type(index) == Animation.TYPE_METHOD: source_methods += 1
			var path := clip.track_get_path(index)
			var target: Node = animation_root.get_node_or_null(NodePath(path.get_concatenated_names()))
			if target == null:
				valid_bindings = false
			elif target is Skeleton3D and path.get_subname_count() > 0:
				valid_bindings = valid_bindings and target.find_bone(path.get_subname(0)) >= 0
	_check(clips.size() == 33 and valid_bindings and source_methods == 0,
		"all 33 original clips bind to real named nodes/bones without duplicate work callbacks")
	var worker := Worker.instantiate()
	worker.worker_id = "standalone_asset"
	worker.paused = true
	add_child(worker)
	worker.position = Vector3(1.2, .85, 0)
	await _advance(120)
	var rounded_physics := true
	for name: String in ["Bone.005", "Bone.006", "toe.L", "toe.R"]:
		var body = worker.ragdoll.rig.by_name[name]
		rounded_physics = rounded_physics and body.shape is SphereShape3D and body.mass > 0.0 and body.inertia > 0.0
	_check(rounded_physics, "native foot and toe contacts have finite rounded shapes without invisible boot boxes")
	# Worn backpack: the plate is fitted to this rig's real skin (no floating
	# fallback), 1 mm off the back face, and the always-visible holder keeps its
	# eleven material meshes, two native tray sensors and finite 2 kg.
	var back: RefCounted = worker.back_tool
	var plate_meshes := 0
	var plate_sensors := 0
	for child: Node in back.holder.get_children():
		if child is MeshInstance3D: plate_meshes += 1
		elif child is CollisionShape3D and child.shape is BoxShape3D: plate_sensors += 1
	var measured: float = HolderVisual.measured_back(worker._skin_mesh, worker._skeleton)
	var seat: MeshInstance3D = back.holder.get_node_or_null("RootSeat")
	var plate_inner := INF
	var plate_outer := -INF
	if seat:
		for point: Vector3 in seat.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
			var z: float = (seat.transform * point).z
			plate_inner = minf(plate_inner, z)
			plate_outer = maxf(plate_outer, z)
	print("CONTRAPTION_WAKO_ASSET plate fitted=%s back=%.4f outer=%.4f seat_z=%.4f meshes=%d sensors=%d" % [HolderVisual._body_fitted, measured, plate_outer, back.seat_point().z, plate_meshes, plate_sensors])
	_check(HolderVisual._body_fitted and absf(plate_outer - (measured + HolderVisual.BODY_GAP + HolderVisual.SEAT_SIZE.z)) < .0015
		and absf(plate_outer - back.PLATE_BACK) < .0015 and back.seat_point().z - plate_outer < .07,
		"the back plate is fitted 1 mm off the real skin and the seat sits just behind it")
	_check(plate_meshes == 11 and plate_sensors == 2 and is_equal_approx(back.holder_mass(), 2.0) and back.holder.visible,
		"the always-visible holder keeps eleven meshes, two tray sensors and 2 kg")
	var unchanged := not animation.has_animation_library("work")
	for name: StringName in clips:
		unchanged = unchanged and animation.get_animation(name).get_track_count() == source_tracks[name]
		unchanged = unchanged and worker._animation.get_animation(name).get_track_count() == source_tracks[name]
	_check(unchanged, "helper contact libraries leave standalone imported animations unchanged")
	var timed_once := true
	for name: StringName in worker._animation.get_animation_list():
		if not String(name).begins_with("work/") or name in [&"work/carry", &"work/run"]: continue
		var clip: Animation = worker._animation.get_animation(name)
		var methods := 0
		for index in clip.get_track_count():
			if clip.track_get_type(index) == Animation.TYPE_METHOD:
				methods += clip.track_get_key_count(index)
				if clip.track_get_key_count(index) == 1:
					timed_once = timed_once and is_equal_approx(clip.track_get_key_time(index, 0), clip.length * .56)
		timed_once = timed_once and methods == (0 if String(name).begins_with("work/danger") or String(name).begins_with("work/interrupted") else 1)
	_check(timed_once, "work clones add exactly one synchronised contact event without duplicating imported callbacks")
	var finite_poses := true
	for name: StringName in clips:
		animation.play(name)
		animation.seek(animation.get_animation(name).length * .56, true)
		animation.advance(0)
		await _advance(1)
		for index in skeleton.get_bone_count():
			finite_poses = finite_poses and skeleton.get_bone_global_pose(index).is_finite()
	_check(finite_poses, "every raw source action evaluates a finite pose on the standalone rig")
	animation.play("wk_idle")
	await _advance(120)
	_check(worker.on_ground and worker.coordinator == null and worker.action.is_empty()
		and worker._animation.current_animation == "wk_idle" and worker.global_position.is_finite(),
		"canonical standalone Wako rests on actual ground without a yard or task coordinator")
	print("CONTRAPTION_WAKO_ASSET %s %d checks" % ["PASS" if failures == 0 else "FAIL (%d)" % failures, checks])
	Shortcuts.graceful_quit(0 if failures == 0 else 1)

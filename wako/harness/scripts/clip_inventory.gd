extends SceneTree
## Imported-clip inventory for the wk_* library (run headless):
##   $GODOT --headless --path <work> -s res://harness/scripts/clip_inventory.gd -- [--json=out.json]
## Prints every animation of res://LogicObjects/Wako/Wako.blend with length, frame count, loop
## mode and track count, the RESET presence, and the skeleton bone rests (to diff against a
## baseline: only toe.L / toe.R may change in the clip pipeline).

func _init() -> void:
	var out_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--json="):
			out_path = a.trim_prefix("--json=")
	var scene := load("res://LogicObjects/Wako/Wako.blend") as PackedScene
	var root := scene.instantiate()
	var player := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var sk := root.find_child("Skeleton3D", true, false) as Skeleton3D
	var report := {"animations": {}, "bones": {}, "skins": []}
	var names := player.get_animation_list()
	names.sort()
	for n in names:
		var anim := player.get_animation(n)
		var bones := {}
		for t in anim.get_track_count():
			var p := String(anim.track_get_path(t))
			bones[p.get_slice(":", 1)] = true
		report["animations"][n] = {"length": snappedf(anim.length, 0.0001), "frames": int(round(anim.length * 30.0)),
			"loop": anim.loop_mode, "tracks": anim.get_track_count(), "bones": bones.size()}
	for i in sk.get_bone_count():
		var r := sk.get_bone_rest(i)
		report["bones"][sk.get_bone_name(i)] = {"parent": sk.get_bone_parent(i),
			"origin": [snappedf(r.origin.x, 0.00001), snappedf(r.origin.y, 0.00001), snappedf(r.origin.z, 0.00001)],
			"basis_x": [snappedf(r.basis.x.x, 0.0001), snappedf(r.basis.x.y, 0.0001), snappedf(r.basis.x.z, 0.0001)],
			"basis_y": [snappedf(r.basis.y.x, 0.0001), snappedf(r.basis.y.y, 0.0001), snappedf(r.basis.y.z, 0.0001)]}
	# In-engine knee check: sample every source frame, pose the skeleton from the bone tracks and measure
	# the knee offset from the hip-ankle line against the model's forward (-Z), lifted toward +Y for legs
	# raised forward (same reference as the Blender pipeline report).
	var chains := [["Bone.001", "Bone.003", "Bone.005"], ["Bone.002", "Bone.004", "Bone.006"]]
	for n in names:
		if n == "RESET":
			continue
		var anim := player.get_animation(n)
		var tracks := {}
		for t in anim.get_track_count():
			var path := String(anim.track_get_path(t))
			tracks[[path.get_slice(":", 1), anim.track_get_type(t)]] = t
		var worst := 1.0
		var frames := int(round(anim.length * 30.0))
		for f in frames + 1:
			var time := f / 30.0
			# Global poses composed by hand (the skeleton is not in a tree, so its cache does not update).
			var glob: Array[Transform3D] = []
			for bi in sk.get_bone_count():
				var bn := sk.get_bone_name(bi)
				var local := sk.get_bone_rest(bi)
				var tp = tracks.get([bn, Animation.TYPE_POSITION_3D])
				var tr = tracks.get([bn, Animation.TYPE_ROTATION_3D])
				if tp != null:
					local.origin = anim.position_track_interpolate(tp, time)
				if tr != null:
					local.basis = Basis(anim.rotation_track_interpolate(tr, time))
				var par := sk.get_bone_parent(bi)
				glob.append(local if par < 0 else glob[par] * local)
			var root_pose: Transform3D = glob[0]
			var fwd := (root_pose.basis * sk.get_bone_rest(0).basis.inverse() * Vector3(0, 0, -1)).normalized()
			for c in chains:
				var hip: Vector3 = glob[sk.find_bone(c[0])].origin
				var knee: Vector3 = glob[sk.find_bone(c[1])].origin
				var ankle: Vector3 = glob[sk.find_bone(c[2])].origin
				var axis := (ankle - hip).normalized()
				var off := (knee - hip) - axis * (knee - hip).dot(axis)
				if off.length() < 0.01:
					continue
				var ref := (fwd + Vector3.UP * maxf(0.0, axis.dot(fwd) * 2.0)).normalized()
				worst = minf(worst, off.normalized().dot(ref))
		report["animations"][n]["knee_forward_min"] = snappedf(worst, 0.001)
	var line := "%-20s %8s %6s %5s %6s %6s" % ["animation", "length", "frames", "loop", "tracks", "kfwd"]
	print(line)
	for n in names:
		var a: Dictionary = report["animations"][n]
		print("%-20s %8.4f %6d %5d %6d %6.3f" % [n, a["length"], a["frames"], a["loop"], a["tracks"], a.get("knee_forward_min", 1.0)])
	print("count %d (RESET %s)" % [names.size(), "yes" if player.has_animation("RESET") else "NO"])
	for b in report["bones"]:
		print(b, " ", report["bones"][b])
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		f.store_string(JSON.stringify(report, " ", true))
	root.free()
	quit(0)

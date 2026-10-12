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
	var line := "%-20s %8s %6s %5s %6s" % ["animation", "length", "frames", "loop", "tracks"]
	print(line)
	for n in names:
		var a: Dictionary = report["animations"][n]
		print("%-20s %8.4f %6d %5d %6d" % [n, a["length"], a["frames"], a["loop"], a["tracks"]])
	print("count %d (RESET %s)" % [names.size(), "yes" if player.has_animation("RESET") else "NO"])
	for b in report["bones"]:
		print(b, " ", report["bones"][b])
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		f.store_string(JSON.stringify(report, " ", true))
	root.free()
	quit(0)

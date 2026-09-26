extends SceneTree
var w; var t := 0.0; var printed := false
func _init():
	var root := Node3D.new(); get_root().add_child(root)
	w = load("res://scenes/warrior.tscn").instantiate(); root.add_child(w)
func _process(delta):
	t += delta
	if t > 0.1 and not printed:
		printed = true
		w.play("combat_idle", 0.0)
		for s in w.springs: print(s.name, " settings=", s.setting_count, " active=", s.active, " influence=", s.influence, " cols=", s.get_child_count())
	if t > 2.0:
		var sk: Skeleton3D = w.skeleton
		for b in ["Skirt03_2", "Skirt03_4", "CapeL2_3", "Hair05_3"]:
			var i := sk.find_bone(b)
			var rest := sk.get_bone_global_rest(i).origin
			var pose := sk.get_bone_global_pose(i).origin
			print(b, " rest ", rest, " pose ", pose, " delta ", (pose - rest).length())
		quit()
	return false

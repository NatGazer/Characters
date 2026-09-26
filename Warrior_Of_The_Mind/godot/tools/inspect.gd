extends SceneTree
func _init():
	var ps: PackedScene = load("res://assets/warrior/warrior.gltf")
	var n := ps.instantiate()
	_print(n, 0)
	var ap: AnimationPlayer = n.find_child("AnimationPlayer", true, false)
	print("animations: ", ap.get_animation_list().size(), " ", ap.get_animation_list())
	var sk: Skeleton3D = n.find_child("Skeleton3D", true, false)
	print("bones: ", sk.get_bone_count(), " root pos ", sk.get_bone_rest(sk.find_bone("Hips")).origin)
	var a := ap.get_animation("walk")
	print("walk length ", a.length, " tracks ", a.get_track_count(), " track0 ", a.track_get_path(0))
	quit()
func _print(n: Node, d: int):
	if d < 3: print("  ".repeat(d), n.name, " <", n.get_class(), ">")
	for c in n.get_children(): _print(c, d + 1)

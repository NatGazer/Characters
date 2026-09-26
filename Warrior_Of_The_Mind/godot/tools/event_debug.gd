extends SceneTree
var w; var t := 0.0; var started := false
func _init():
	var root := Node3D.new(); get_root().add_child(root)
	w = load("res://scenes/warrior.tscn").instantiate(); root.add_child(w)
	w.anim_event.connect(func(c, e): print("EVENT ", c, " ", e, " t=", t, " scene children ", root.get_child_count()))
func _process(delta):
	t += delta
	if not started and t > 0.1:
		started = true; w.play("cast_blast", 0.0)
		print("clips has events: ", w.clips.get("cast_blast", {}))
	if t > 2.0: quit()
	return false

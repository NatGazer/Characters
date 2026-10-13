extends Node3D
# Usage: godot --path <proj> --resolution 640x360 bench.tscn  -> "BENCH_JSON {...}"
# Relative runtime cost of the skinned Wako mesh: N animated instances, average frame time.
const N := 64
var t0 := 0
var frames := 0
var times := []
var prims := 0
func _ready() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.look_at_from_position(Vector3(0, 9, 12), Vector3(0, 0, 0), Vector3.UP)
	cam.current = true
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	add_child(sun)
	sun.rotation_degrees = Vector3(-50, 30, 0)
	var ps: PackedScene = load("res://LogicObjects/Wako/Wako.blend")
	var flat := StandardMaterial3D.new()  # identical untextured material for both meshes
	for i in N:
		var w: Node3D = ps.instantiate()
		add_child(w)
		for m in w.find_children("*", "MeshInstance3D", true, false):
			(m as MeshInstance3D).material_override = flat
		w.position = Vector3((i % 8) * 1.2 - 4.2, 0, (i / 8) * 1.2 - 4.2)
		var ap: AnimationPlayer = w.find_children("*", "AnimationPlayer", true, false)[0]
		ap.play("wk_run")
		ap.seek(randf() * 0.5, true)
func _process(_dt: float) -> void:
	frames += 1
	var now := Time.get_ticks_usec()
	if frames > 40:
		times.append((now - t0) / 1000.0)
		prims = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	t0 = now
	if frames >= 240:
		times.sort()
		var s := 0.0
		for t in times: s += t
		print("BENCH_JSON ", JSON.stringify({"instances": N, "frames": times.size(), "mean_ms": s / times.size(), "median_ms": times[times.size() / 2], "primitives_in_frame": prims}))
		get_tree().quit()

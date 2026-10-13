extends "res://harness/scripts/stage.gd"
## Expression sheet: a grid of frozen Wako whose shared skin receives fixed
## per-instance face uniforms (no helper expression engine involved). Checks
## the shader alone: lids, tilt, wink, pupil, pop, mouth shapes, alarm.
const Props := preload("res://harness/scripts/face_props.gd")
const Closeups := preload("res://harness/scripts/face_closeups.gd")
# The same 24 shader presets as the close-up sheet, four per page.
var PRESETS: Array = Closeups.PRESETS
var wakos: Array[RigidBody3D] = []
var labels: Array[Label3D] = []

func setup() -> void:
	var cols := 4
	for i in PRESETS.size():
		var x := (float(i % cols) - 1.5) * 1.15
		var row := floori(float(i) / cols)
		var w := spawn_wako(Vector3(-x, .86, float(row) * 6.0), "shape_%d" % i)
		w.freeze = true
		w.set_physics_process(false)
		Props.bind_atlas(w)
		wakos.append(w)
		var l := Label3D.new()
		l.text = PRESETS[i][0]
		l.font_size = 40
		l.pixel_size = .004
		l.position = Vector3(0, .62, -.3)
		l.rotation_degrees.y = 180
		w.add_child(l)
	var page := 0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--page="): page = int(arg.trim_prefix("--page="))
	cam_target = Vector3(0, 1.02, page * 6.0)
	cam_offset = Vector3(0, .15, -2.75)
	for i in wakos.size():
		wakos[i].visible = floori(float(i) / cols) == page

func _process(delta: float) -> void:
	super(delta)
	for i in wakos.size():
		var mesh: MeshInstance3D = wakos[i]._skin_mesh
		for key: String in Closeups.DEFAULTS:
			mesh.set_instance_shader_parameter(key, PRESETS[i][1].get(key, Closeups.DEFAULTS[key]))
		mesh.set_instance_shader_parameter(&"eye_reactivity", 0.0)

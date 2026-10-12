extends "res://harness/scripts/stage.gd"
## Expression sheet: a grid of frozen Wako whose shared skin receives fixed
## per-instance face uniforms (no helper expression engine involved). Checks
## the shader alone: lids, tilt, wink, pupil, pop, mouth shapes, alarm.
const Props := preload("res://harness/scripts/face_props.gd")
const PRESETS := [
	["neutral", {"eye_lids": Vector4(.12, 0, 0, 0)}],
	["surprise", {"eye_lids": Vector4(-.3, 0, 0, 0), "eye_iris": Vector4(-.7, 0, 1, 0), "mouth_shape": Vector4(.6, -.4, -.7, 0)}],
	["effort", {"eye_lids": Vector4(.62, .42, .7, 0), "mouth_shape": Vector4(.12, -.45, .55, 0)}],
	["happy talk", {"eye_lids": Vector4(.1, 0, 0, 0), "eye_smile": 1.0, "eye_iris": Vector4(.4, 0, 0, 0), "mouth_shape": Vector4(.55, .9, .25, 0)}],
	["worried", {"eye_lids": Vector4(.18, .1, -.9, 0), "mouth_shape": Vector4(0, -.8, -.1, .2)}],
	["wink smirk", {"eye_lids": Vector4(.12, .1, .2, 1.0), "mouth_shape": Vector4(0, .5, .1, .8), "gaze_uv_offset": Vector2(.004, -.012)}],
	["alarm gasp", {"face_alarm": 1.0, "face_startle": 1.0, "eye_lids": Vector4(-.1, 0, 0, 0), "eye_iris": Vector4(-.6, 0, .5, 0)}],
	["sleepy", {"eye_lids": Vector4(.55, .15, -.2, 0), "eye_openness": .85, "eye_iris": Vector4(.3, 0, 0, 0), "mouth_shape": Vector4(.08, .2, -.2, 0)}],
	["look right", {"eye_lids": Vector4(.12, 0, 0, 0), "gaze_uv_offset": Vector2(0, -.019)}],
	["look up-left", {"eye_lids": Vector4(.05, 0, 0, 0), "gaze_uv_offset": Vector2(.014, .013)}],
	["look down", {"eye_lids": Vector4(.2, 0, 0, 0), "gaze_uv_offset": Vector2(-.019, 0)}],
	["cross (near)", {"eye_lids": Vector4(.1, 0, 0, 0), "gaze_uv_offset": Vector2(-.006, 0), "eye_iris": Vector4(.2, .007, 0, 0)}],
	["blink 50%", {"eye_lids": Vector4(.12, 0, 0, 0), "eye_openness": .5}],
	["blink closed", {"eye_lids": Vector4(.12, 0, 0, 0), "eye_openness": 0.0}],
	["O pucker", {"eye_lids": Vector4(0, 0, 0, 0), "eye_iris": Vector4(.5, 0, .3, 0), "mouth_shape": Vector4(.7, 0, -1, 0)}],
	["grin", {"eye_lids": Vector4(.2, .3, .1, 0), "eye_smile": .6, "mouth_shape": Vector4(.2, 1, 1, 0)}],
]
var wakos: Array[RigidBody3D] = []
var labels: Array[Label3D] = []

func setup() -> void:
	var cols := 4
	for i in PRESETS.size():
		var x := (float(i % cols) - 1.5) * 1.15
		var row := i / cols
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
		wakos[i].visible = i / cols == page

func _process(delta: float) -> void:
	super(delta)
	for i in wakos.size():
		var mesh: MeshInstance3D = wakos[i]._skin_mesh
		for key in ["eye_openness", "gaze_uv_offset", "eye_smile", "face_alarm", "face_startle", "eye_lids", "eye_iris", "mouth_shape"]:
			var defaults := {"eye_openness": 1.0, "gaze_uv_offset": Vector2.ZERO, "eye_smile": 0.0, "face_alarm": 0.0, "face_startle": 0.0, "eye_lids": Vector4.ZERO, "eye_iris": Vector4.ZERO, "mouth_shape": Vector4.ZERO}
			mesh.set_instance_shader_parameter(key, PRESETS[i][1].get(key, defaults[key]))
		mesh.set_instance_shader_parameter(&"eye_reactivity", 0.0)

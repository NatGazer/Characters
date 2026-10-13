extends "res://harness/scripts/stage.gd"
## Shader close-up sheet: one frozen Wako (no expression engine) shows one
## fixed uniform preset per pair of rendered frames, from a camera angle
## given on the command line (--yaw=deg --pitch=deg --dist=m). Used to judge
## lids, pupils, gaze reach, crease, mouth and gloss at every angle.
const Props := preload("res://harness/scripts/face_props.gd")
const PRESETS := [
	["neutral", {"eye_lids": Vector4(.06, 0, 0, 0)}],
	["look right max", {"eye_lids": Vector4(.06, 0, 0, 0), "gaze_uv_offset": Vector2(0, -.03)}],
	["look left max", {"eye_lids": Vector4(.06, 0, 0, 0), "gaze_uv_offset": Vector2(0, .03)}],
	["look up max", {"eye_lids": Vector4(.06, 0, 0, 0), "gaze_uv_offset": Vector2(.03, 0)}],
	["look down max", {"eye_lids": Vector4(.06, 0, 0, 0), "gaze_uv_offset": Vector2(-.03, 0)}],
	["look up-left", {"eye_lids": Vector4(.06, 0, 0, 0), "gaze_uv_offset": Vector2(.021, .021)}],
	["blink 25%", {"eye_lids": Vector4(.06, 0, 0, 0), "eye_openness": .75}],
	["blink 50%", {"eye_lids": Vector4(.06, 0, 0, 0), "eye_openness": .5}],
	["blink 80%", {"eye_lids": Vector4(.06, 0, 0, 0), "eye_openness": .2}],
	["blink closed", {"eye_lids": Vector4(.06, 0, 0, 0), "eye_openness": 0.0}],
	["sleepy", {"eye_lids": Vector4(.5, .12, -.15, 0), "eye_iris": Vector4(.3, 0, 0, 0), "mouth_shape": Vector4(.06, .2, -.2, 0)}],
	["effort draw", {"eye_lids": Vector4(.38, .36, .35, 0), "mouth_shape": Vector4(0, -.35, .3, 0)}],
	["effort strike", {"eye_lids": Vector4(.5, .45, .2, 0), "eye_iris": Vector4(0, 0, 0, 1), "mouth_shape": Vector4(.12, -.5, .55, 0)}],
	["surprise", {"eye_lids": Vector4(-.35, 0, 0, 0), "eye_iris": Vector4(-.25, 0, 1, 0), "mouth_shape": Vector4(.65, -.5, -.8, 0)}],
	["alarm (puppy)", {"face_alarm": 1.0, "eye_iris": Vector4(.3, 0, 0, 0)}],
	["worried", {"eye_lids": Vector4(.15, .1, -.9, 0), "mouth_shape": Vector4(0, -.75, -.1, 0)}],
	["determined", {"eye_lids": Vector4(.3, .2, .6, 0), "mouth_shape": Vector4(0, -.3, .2, 0)}],
	["happy smile", {"eye_smile": 1.0, "eye_iris": Vector4(.4, 0, 0, 0), "mouth_shape": Vector4(.38, .9, .3, 0)}],
	["wink", {"eye_lids": Vector4(.06, .1, .2, 1.0), "mouth_shape": Vector4(0, .5, .1, .8), "gaze_uv_offset": Vector2(.004, -.012)}],
	["curious", {"eye_lids": Vector4(-.06, 0, .2, 0), "eye_iris": Vector4(.3, 0, .1, 0), "mouth_shape": Vector4(.05, -.35, -.1, .7)}],
	["notice focus", {"eye_lids": Vector4(.18, .14, -.35, 0), "eye_iris": Vector4(-.2, 0, 0, 0)}],
	["half lid down", {"eye_lids": Vector4(.35, 0, 0, 0), "gaze_uv_offset": Vector2(-.02, .006)}],
	["O mouth", {"eye_lids": Vector4(0, 0, 0, 0), "eye_iris": Vector4(.5, 0, .3, 0), "mouth_shape": Vector4(.7, 0, -1, 0)}],
	["grin talk", {"eye_lids": Vector4(.1, .2, .1, 0), "eye_smile": .6, "mouth_shape": Vector4(.55, .9, .25, 0)}],
]
const DEFAULTS := {"eye_openness": 1.0, "gaze_uv_offset": Vector2.ZERO, "eye_smile": 0.0, "face_alarm": 0.0, "face_startle": 0.0, "eye_lids": Vector4.ZERO, "eye_iris": Vector4.ZERO, "mouth_shape": Vector4.ZERO}
var wako: RigidBody3D
var only := -1

func setup() -> void:
	wako = spawn_wako(Vector3(0, .86, 0), "closeup")
	wako.freeze = true
	wako.set_physics_process(false)
	Props.bind_atlas(wako)
	var yaw := 0.0
	var pitch := 0.0
	var dist := 1.35
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--yaw="): yaw = deg_to_rad(float(arg.trim_prefix("--yaw=")))
		if arg.begins_with("--pitch="): pitch = deg_to_rad(float(arg.trim_prefix("--pitch=")))
		if arg.begins_with("--dist="): dist = float(arg.trim_prefix("--dist="))
		if arg.begins_with("--only="): only = int(arg.trim_prefix("--only="))
	cam_target = Vector3(0, 1.15, -.2)
	cam_offset = Vector3(sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch)) * dist

func _process(delta: float) -> void:
	super(delta)
	var index := only if only >= 0 else mini(int(maxi(frame - 1, 0) * .5), PRESETS.size() - 1)
	var mesh: MeshInstance3D = wako._skin_mesh
	for key: String in DEFAULTS:
		mesh.set_instance_shader_parameter(key, PRESETS[index][1].get(key, DEFAULTS[key]))
	mesh.set_instance_shader_parameter(&"eye_reactivity", 0.0)
	caption("%d %s" % [index, PRESETS[index][0]])

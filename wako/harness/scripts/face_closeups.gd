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
	["strike squint (sq .26)", {"eye_lids": Vector4(.21, .36, .2, 0), "eye_iris": Vector4(0, 0, 0, .26), "mouth_shape": Vector4(.1, -.5, .55, 0)}],
	["squeeze 40%", {"eye_lids": Vector4(.21, .36, .2, 0), "eye_iris": Vector4(0, 0, 0, .4), "mouth_shape": Vector4(.1, -.5, .55, 0)}],
	["squeeze 55%", {"eye_lids": Vector4(.21, .36, .2, 0), "eye_iris": Vector4(0, 0, 0, .55), "mouth_shape": Vector4(.1, -.5, .55, 0)}],
	["squeeze 75%", {"eye_lids": Vector4(.21, .36, .2, 0), "eye_iris": Vector4(0, 0, 0, .75), "mouth_shape": Vector4(.1, -.5, .55, 0)}],
]
# --set=review: combined presets the engine really reaches (critic findings).
const REVIEW := [
	["worried + look side max", {"face_alarm": 1.0, "eye_lids": Vector4(.2, .14, 0, 0), "eye_iris": Vector4(.33, 0, 0, 0), "gaze_uv_offset": Vector2(-.005, .03)}],
	["worried + look other side", {"face_alarm": 1.0, "eye_lids": Vector4(.2, .14, 0, 0), "eye_iris": Vector4(.33, 0, 0, 0), "gaze_uv_offset": Vector2(-.005, -.03)}],
	["alarm only fwd", {"face_alarm": 1.0, "eye_lids": Vector4(.08, 0, 0, 0), "eye_iris": Vector4(.33, 0, 0, 0)}],
	["notice focus beat + side", {"face_alarm": .96, "face_startle": .6, "eye_lids": Vector4(.12, .14, -.35, 0), "eye_iris": Vector4(.24, 0, .21, 0), "mouth_shape": Vector4(.2, -.36, -.41, 0), "gaze_uv_offset": Vector2(-.0044, .0227)}],
	["worried tilt -1 + side", {"eye_lids": Vector4(.15, .1, -1.0, 0), "eye_iris": Vector4(.6, 0, 0, 0), "mouth_shape": Vector4(0, -.75, -.1, 0), "gaze_uv_offset": Vector2(0, -.03)}],
	["squeeze .30", {"eye_lids": Vector4(.21, .36, .2, 0), "eye_iris": Vector4(0, 0, 0, .30), "mouth_shape": Vector4(.1, -.5, .55, 0)}],
	["squeeze .40", {"eye_lids": Vector4(.21, .36, .2, 0), "eye_iris": Vector4(0, 0, 0, .40), "mouth_shape": Vector4(.1, -.5, .55, 0)}],
	["squeeze .46", {"eye_lids": Vector4(.21, .36, .2, 0), "eye_iris": Vector4(0, 0, 0, .46), "mouth_shape": Vector4(.1, -.5, .55, 0)}],
	["squeeze .52", {"eye_lids": Vector4(.21, .36, .2, 0), "eye_iris": Vector4(0, 0, 0, .52), "mouth_shape": Vector4(.1, -.5, .55, 0)}],
	["squeeze .58", {"eye_lids": Vector4(.21, .36, .2, 0), "eye_iris": Vector4(0, 0, 0, .58), "mouth_shape": Vector4(.1, -.5, .55, 0)}],
	["squeeze .65", {"eye_lids": Vector4(.21, .36, .2, 0), "eye_iris": Vector4(0, 0, 0, .65), "mouth_shape": Vector4(.1, -.5, .55, 0)}],
	["squeeze .75", {"eye_lids": Vector4(.21, .36, .2, 0), "eye_iris": Vector4(0, 0, 0, .75), "mouth_shape": Vector4(.1, -.5, .55, 0)}],
	["squeeze .90", {"eye_lids": Vector4(.21, .36, .2, 0), "eye_iris": Vector4(0, 0, 0, .9), "mouth_shape": Vector4(.1, -.5, .55, 0)}],
	["smile .30", {"eye_smile": .3, "eye_iris": Vector4(.2, 0, 0, 0), "mouth_shape": Vector4(0, .3, .05, 0)}],
	["smile .50", {"eye_smile": .5, "eye_iris": Vector4(.3, 0, 0, 0), "mouth_shape": Vector4(0, .5, .1, 0)}],
	["smile .70", {"eye_smile": .7, "eye_iris": Vector4(.35, 0, 0, 0), "mouth_shape": Vector4(0, .7, .2, 0)}],
	["smile + look side", {"eye_smile": 1.0, "eye_iris": Vector4(.4, 0, 0, 0), "mouth_shape": Vector4(.2, .9, .3, 0), "gaze_uv_offset": Vector2(0, .025)}],
	["focus squint + look down", {"eye_lids": Vector4(.46, .36, .35, 0), "mouth_shape": Vector4(0, -.35, .3, 0), "gaze_uv_offset": Vector2(-.022, .016)}],
	["effort draw", {"eye_lids": Vector4(.44, .36, .35, 0), "mouth_shape": Vector4(0, -.35, .3, 0), "gaze_uv_offset": Vector2(-.012, 0)}],
	["surprise + look up-side", {"eye_lids": Vector4(-.35, 0, 0, 0), "eye_iris": Vector4(-.25, 0, 1, 0), "mouth_shape": Vector4(.65, -.5, -.8, 0), "gaze_uv_offset": Vector2(.015, .022)}],
	["O mouth", {"eye_lids": Vector4(0, 0, 0, 0), "eye_iris": Vector4(.5, 0, .3, 0), "mouth_shape": Vector4(.7, 0, -1, 0)}],
	["uh-oh o (oops)", {"eye_lids": Vector4(-.1, 0, 0, 0), "eye_iris": Vector4(0, 0, .4, 0), "mouth_shape": Vector4(.45, -.35, -.6, 0)}],
	["talk open .6 warn", {"face_alarm": .6, "eye_lids": Vector4(.1, 0, 0, 0), "mouth_shape": Vector4(.6, -.6, -.4, 0)}],
	["neutral", {"eye_lids": Vector4(.06, 0, 0, 0)}],
	["determined + side", {"eye_lids": Vector4(.3, .2, .6, 0), "mouth_shape": Vector4(0, -.3, .2, 0), "gaze_uv_offset": Vector2(0, -.028)}],
	["sleepy + look down", {"eye_lids": Vector4(.55, .12, -.15, 0), "eye_iris": Vector4(.3, 0, 0, 0), "mouth_shape": Vector4(.06, .2, -.2, 0), "gaze_uv_offset": Vector2(-.02, 0)}],
	["blink 50 + side", {"eye_lids": Vector4(.06, 0, 0, 0), "eye_openness": .5, "gaze_uv_offset": Vector2(0, .028)}],
	["gun aim wink .45", {"eye_lids": Vector4(.26, 0, .35, .45), "mouth_shape": Vector4(0, -.2, 0, .4), "gaze_uv_offset": Vector2(0, -.01)}],
	["annoyed", {"eye_lids": Vector4(.28, .18, .5, 0), "mouth_shape": Vector4(0, -.35, .25, .35)}],
	["joy grin", {"eye_smile": 1.0, "eye_iris": Vector4(.45, 0, 0, 0), "mouth_shape": Vector4(.38, .9, .3, 0)}],
	["focus beat, clip state", {"face_alarm": 1.0, "face_startle": .6, "eye_lids": Vector4(.2, .14, -.35, 0), "eye_iris": Vector4(.38, 0, 0, 0), "mouth_shape": Vector4(.03, 0, 0, 0), "gaze_uv_offset": Vector2(-.0035, .0241)}],
]
# --set=r4: round-4 review (critic states: partial smiles, satisfied look
# down with the work cap and the proud lift, worried full tilt, side-eye
# watch vs the new half-range watch, the strike band).
const R4 := [
	["smile .15 (partner near)", {"eye_smile": .15, "eye_iris": Vector4(.1, 0, 0, 0), "mouth_shape": Vector4(0, .15, 0, 0)}],
	["smile .25", {"eye_smile": .25, "eye_iris": Vector4(.15, 0, 0, 0), "mouth_shape": Vector4(0, .25, 0, 0)}],
	["satisfied .34 lr.1", {"eye_smile": .34, "eye_lids": Vector4(.08, .1, 0, 0), "eye_iris": Vector4(.1, 0, 0, 0), "mouth_shape": Vector4(.05, .36, .08, 0)}],
	["satisfied .45 lr.1", {"eye_smile": .45, "eye_lids": Vector4(.08, .1, 0, 0), "eye_iris": Vector4(.12, 0, 0, 0), "mouth_shape": Vector4(.05, .45, .08, 0)}],
	["satisfied .34 look down (old clamp)", {"eye_smile": .34, "eye_lids": Vector4(.08, .1, 0, 0), "eye_iris": Vector4(.1, 0, 0, 0), "mouth_shape": Vector4(.05, .36, .08, 0), "gaze_uv_offset": Vector2(-.0215, .0215)}],
	["satisfied .34 look down (cap + lift)", {"eye_smile": .34, "eye_lids": Vector4(.08, .1, 0, 0), "eye_iris": Vector4(.1, 0, 0, 0), "mouth_shape": Vector4(.05, .36, .08, 0), "gaze_uv_offset": Vector2(-.0090, .0180)}],
	["smile .60", {"eye_smile": .6, "eye_iris": Vector4(.3, 0, 0, 0), "mouth_shape": Vector4(0, .6, .15, 0)}],
	["smile .80", {"eye_smile": .8, "eye_iris": Vector4(.35, 0, 0, 0), "mouth_shape": Vector4(.1, .8, .2, 0)}],
	["joy grin 1.0", {"eye_smile": 1.0, "eye_iris": Vector4(.45, 0, 0, 0), "mouth_shape": Vector4(.38, .9, .3, 0)}],
	["worried tilt -.8 alarm", {"face_alarm": 1.0, "eye_lids": Vector4(.08, .05, 0, 0), "eye_iris": Vector4(.33, 0, 0, 0)}],
	["worried full (uc .2, alarm+tilt)", {"face_alarm": 1.0, "eye_lids": Vector4(.2, .14, -.3, 0), "eye_iris": Vector4(.4, 0, 0, 0), "mouth_shape": Vector4(0, -.75, -.1, 0)}],
	["worried + look side max", {"face_alarm": 1.0, "eye_lids": Vector4(.2, .14, 0, 0), "eye_iris": Vector4(.33, 0, 0, 0), "gaze_uv_offset": Vector2(-.005, .03)}],
	["worried + other side", {"face_alarm": 1.0, "eye_lids": Vector4(.2, .14, 0, 0), "eye_iris": Vector4(.33, 0, 0, 0), "gaze_uv_offset": Vector2(-.005, -.03)}],
	["alarm watch 84% (old staging)", {"face_alarm": 1.0, "eye_lids": Vector4(.08, 0, 0, 0), "eye_iris": Vector4(.3, 0, 0, 0), "gaze_uv_offset": Vector2(-.0015, .0251)}],
	["alarm watch 46% (new staging)", {"face_alarm": 1.0, "eye_lids": Vector4(.08, 0, 0, 0), "eye_iris": Vector4(.3, 0, 0, 0), "gaze_uv_offset": Vector2(-.0015, .0138)}],
	["notice widen peak", {"face_alarm": .3, "face_startle": 1.0, "eye_lids": Vector4(-.28, 0, 0, 0), "eye_iris": Vector4(-.25, 0, .9, 0), "mouth_shape": Vector4(.55, 0, -.7, 0)}],
	["warn shout", {"face_alarm": .9, "face_startle": .6, "eye_lids": Vector4(-.03, .13, -.32, 0), "eye_iris": Vector4(.1, 0, .58, 0), "mouth_shape": Vector4(.98, -.58, -.84, 0), "gaze_uv_offset": Vector2(-.0007, .0225)}],
	["determined tilt +.6", {"eye_lids": Vector4(.3, .2, .6, 0), "mouth_shape": Vector4(0, -.3, .2, 0)}],
	["strike squeeze .44 (band low)", {"eye_lids": Vector4(.21, .36, .2, 0), "eye_iris": Vector4(0, 0, 0, .44), "mouth_shape": Vector4(.1, -.5, .55, 0)}],
	["strike squeeze .68 (band high)", {"eye_lids": Vector4(.21, .36, .2, 0), "eye_iris": Vector4(0, 0, 0, .68), "mouth_shape": Vector4(.1, -.5, .55, 0)}],
	["hello talk", {"eye_smile": .8, "eye_iris": Vector4(.3, 0, 0, 0), "mouth_shape": Vector4(.5, .75, .2, 0)}],
	["greeting silent", {"eye_smile": .9, "eye_iris": Vector4(.35, 0, 0, 0), "mouth_shape": Vector4(.06, .6, .1, 0)}],
	["relief smile 1 uc.21", {"eye_smile": 1.0, "eye_lids": Vector4(.21, .08, 0, 0), "eye_iris": Vector4(.3, 0, 0, 0), "mouth_shape": Vector4(.3, .9, 0, 0), "gaze_uv_offset": Vector2(-.0103, .0031)}],
	["neutral", {"eye_lids": Vector4(.06, 0, 0, 0)}],
]
const DEFAULTS := {"eye_openness": 1.0, "gaze_uv_offset": Vector2.ZERO, "eye_smile": 0.0, "face_alarm": 0.0, "face_startle": 0.0, "eye_lids": Vector4.ZERO, "eye_iris": Vector4.ZERO, "mouth_shape": Vector4.ZERO}
var wako: RigidBody3D
var only := -1
var presets: Array = PRESETS

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
		if arg == "--set=review": presets = REVIEW
		if arg == "--set=r4": presets = R4
	cam_target = Vector3(0, 1.15, -.2)
	cam_offset = Vector3(sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch)) * dist

func _process(delta: float) -> void:
	super(delta)
	var index := only if only >= 0 else mini(int(maxi(frame - 1, 0) * .5), presets.size() - 1)
	var mesh: MeshInstance3D = wako._skin_mesh
	for key: String in DEFAULTS:
		mesh.set_instance_shader_parameter(key, presets[index][1].get(key, DEFAULTS[key]))
	mesh.set_instance_shader_parameter(&"eye_reactivity", 0.0)
	caption("%d %s" % [index, presets[index][0]])

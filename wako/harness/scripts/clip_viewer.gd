extends Node3D
## Authored-clip viewer: the imported Wako.blend scene alone (no helper, no IK,
## no physics) on a measured ground grid, playing named clips frame-exactly
## with fixed cameras. Review tool for the wk_* action library.
##
## User args (after `--`):
##   --clip=wk_assemble_L[,wk_assemble_R,...]   clip(s) to play in sequence (default wk_idle)
##   --view=side|left|front|34|34l|back|top     fixed camera; a comma list makes side-by-side panes
##                                              (e.g. --view=side,34). side = from Wako's right.
##   --repeat=N        play each clip N times (loops wrap, one-shots replay) (default 1)
##   --hold=F          frames to hold the last pose of a one-shot clip (default 4)
##   --dist=D          camera distance override (m)
##   --water=H         show a water plane at height H (swim review)
##   --ty=Y            camera target height (default 0.64; ~0.35 frames the seated clips)
##   --nolabel         hide the caption / timeline overlay
## Each rendered frame (capture.sh uses --fixed-fps 30) shows exactly one source frame. The
## schedule (clip, first rendered frame, frame count) is printed as `schedule:` lines so contact
## sheets can be sliced per clip (harness/clip_sheet.sh).

const MODEL := preload("res://LogicObjects/Wako/Wako.blend")
const SKIN := preload("res://LogicObjects/Wako/snow_skin.gdshader")
const EYE_SKIN := preload("res://LogicObjects/Wako/snow_eye.gdshader")
const FPS := 30.0
# The Blender armature sits 1.0739 m above the model origin; rest soles are 1.085 m below it.
const SOLE_OFFSET := 0.0111
# Movie frames shown before the schedule starts (sub-viewports need one frame to warm up).
const LEAD := 2

var clips: PackedStringArray = ["wk_idle"]
var views: PackedStringArray = ["side"]
var repeat := 1
var hold := 4
var dist := -1.0
var water := -100.0
var target_y := 0.64
var show_label := true

var _player: AnimationPlayer
var _schedule: Array = []          # [{clip, start, count, frames, loop}]
var _total := 0
var _frame := 0
var _label: Label
var _bar: ColorRect
var _marker: ColorRect
var _contact: ColorRect

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		var k := kv[0]
		var v := kv[1] if kv.size() > 1 else ""
		match k:
			"clip", "clips": clips = v.split(",", false)
			"view", "views": views = v.split(",", false)
			"repeat": repeat = maxi(1, v.to_int())
			"hold": hold = maxi(0, v.to_int())
			"dist": dist = v.to_float()
			"water": water = v.to_float()
			"ty": target_y = v.to_float()
			"nolabel": show_label = false
	_build_world()
	var model := MODEL.instantiate() as Node3D
	model.position.y = SOLE_OFFSET
	add_child(model)
	_apply_skin(model)
	_player = model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var start := 0
	for c in clips:
		if not _player.has_animation(c):
			push_error("clip_viewer: no clip %s" % c)
			continue
		var anim := _player.get_animation(c)
		var frames := int(round(anim.length * FPS))
		var looped := anim.loop_mode != Animation.LOOP_NONE
		var count := frames * repeat if looped else (frames + 1 + hold) * repeat
		_schedule.append({"clip": c, "start": start, "count": count, "frames": frames, "loop": looped})
		print("schedule: %s %d %d frames=%d loop=%d tracks=%d" % [c, start + LEAD, count, frames, int(looped), anim.get_track_count()])
		start += count
	_total = start
	print("schedule_total: %d" % _total)
	_build_panes()
	_build_overlay()
	_show(0)

func _process(_delta: float) -> void:
	# Movie frame k (0-based) shows schedule frame k - LEAD.
	_show(maxi(0, _frame - LEAD))
	_frame += 1

func _show(i: int) -> void:
	if _schedule.is_empty():
		return
	i = i % maxi(1, _total)
	var e: Dictionary = _schedule[0]
	for s in _schedule:
		if i >= int(s["start"]) and i < int(s["start"]) + int(s["count"]):
			e = s
			break
	var local := i - int(e["start"])
	var n: int = e["frames"]
	var f := local % n if e["loop"] else mini(local % (n + 1 + hold), n)
	if _player.current_animation != e["clip"] or not _player.is_playing():
		_player.play(e["clip"])
	_player.seek(f / FPS, true)
	if show_label and _label:
		_label.text = "%s   f%02d / %d   (%.2f)" % [e["clip"], f, n, float(f) / maxf(1.0, n)]
		_marker.position.x = _bar.position.x + _bar.size.x * float(f) / maxf(1.0, n) - 1.5
		var c: String = e["clip"]
		_contact.visible = (c.ends_with("_L") or c.ends_with("_R")) and not c.begins_with("wk_interrupted")

func _apply_skin(model: Node) -> void:
	var mesh := model.find_child("wakoMesh", true, false) as MeshInstance3D
	if mesh == null:
		return
	var original := mesh.get_active_material(0) as BaseMaterial3D
	var skin := ShaderMaterial.new()
	skin.shader = SKIN
	var eye := ShaderMaterial.new()
	eye.shader = EYE_SKIN
	if original:
		skin.set_shader_parameter("albedo_texture", original.albedo_texture)
		eye.set_shader_parameter("albedo_texture", original.albedo_texture)
	skin.next_pass = eye
	mesh.set_surface_override_material(0, skin)

func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.58, 0.66, 0.74)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.78, 0.82, 0.88)
	e.ambient_light_energy = 0.7
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	e.ssao_enabled = true
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 30, 0)
	sun.light_energy = 2.2
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 12.0
	add_child(sun)
	# Ground with a world-space 10 cm grid (thicker every 50 cm; red axes) so planted soles can be judged.
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(12, 12)
	ground.mesh = plane
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
varying vec3 wp;
void vertex() { wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
float line(float c, float w) { float d = abs(fract(c - 0.5) - 0.5) / fwidth(c); return 1.0 - clamp(d - w, 0.0, 1.0); }
void fragment() {
	float minor = max(line(wp.x * 10.0, 0.2), line(wp.z * 10.0, 0.2));
	float major = max(line(wp.x * 2.0, 0.6), line(wp.z * 2.0, 0.6));
	vec3 base = vec3(0.50, 0.54, 0.47);
	base = mix(base, vec3(0.38, 0.41, 0.36), minor * 0.6);
	base = mix(base, vec3(0.22, 0.25, 0.22), major * 0.8);
	if (abs(wp.x) < 0.006 || abs(wp.z) < 0.006) base = vec3(0.7, 0.25, 0.2);
	ALBEDO = base;
	ROUGHNESS = 0.9;
}
"""
	var gm := ShaderMaterial.new()
	gm.shader = sh
	ground.material_override = gm
	add_child(ground)
	if water > -50.0:
		var w := MeshInstance3D.new()
		var wpm := PlaneMesh.new()
		wpm.size = Vector2(6, 6)
		w.mesh = wpm
		w.position.y = water
		var wm := StandardMaterial3D.new()
		wm.albedo_color = Color(0.2, 0.45, 0.7, 0.45)
		wm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		wm.cull_mode = BaseMaterial3D.CULL_DISABLED
		w.material_override = wm
		add_child(w)

func _camera_for(view: String, aspect: float) -> Camera3D:
	var cam := Camera3D.new()
	cam.fov = 30.0
	var target := Vector3(0.0, target_y, -0.12)
	var d := dist if dist > 0.0 else (3.7 if aspect < 1.2 else 4.2)
	var dir := Vector3(1, 0.12, 0)             # side: from Wako's right (+X)
	match view:
		"left": dir = Vector3(-1, 0.12, 0)
		"front": dir = Vector3(0, 0.14, -1)    # the face looks toward -Z
		"34": dir = Vector3(0.72, 0.28, -0.72)
		"34l": dir = Vector3(-0.72, 0.28, -0.72)
		"back": dir = Vector3(0, 0.18, 1)
		"top": dir = Vector3(0.0, 1.0, -0.35)
	cam.position = target + dir.normalized() * d
	cam.look_at_from_position(cam.position, target, Vector3.UP if view != "top" else Vector3(0, 0, -1))
	return cam

func _build_panes() -> void:
	if views.size() <= 1:
		var cam := _camera_for(views[0] if views.size() else "side", 16.0 / 9.0)
		cam.current = true
		add_child(cam)
		return
	var ui := CanvasLayer.new()
	ui.layer = -1
	add_child(ui)
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.size = Vector2(1280, 720)
	ui.add_child(box)
	var w := int((1280 - 2 * (views.size() - 1)) / views.size())
	for v in views:
		var cont := SubViewportContainer.new()
		cont.custom_minimum_size = Vector2(w, 720)
		cont.stretch = true
		box.add_child(cont)
		var vp := SubViewport.new()
		vp.size = Vector2i(w, 720)
		vp.world_3d = get_viewport().find_world_3d()
		vp.msaa_3d = Viewport.MSAA_2X
		cont.add_child(vp)
		var cam := _camera_for(v, float(w) / 720.0)
		cam.current = true
		vp.add_child(cam)
	# The main viewport still needs a camera; park it looking at nothing (it is covered).
	var dummy := Camera3D.new()
	dummy.position = Vector3(0, -50, 0)
	dummy.current = true
	add_child(dummy)

func _build_overlay() -> void:
	if not show_label:
		return
	var ui := CanvasLayer.new()
	ui.layer = 2
	add_child(ui)
	_label = Label.new()
	_label.position = Vector2(14, 8)
	_label.add_theme_font_size_override("font_size", 30)
	_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_label.add_theme_constant_override("outline_size", 8)
	ui.add_child(_label)
	_bar = ColorRect.new()
	_bar.position = Vector2(16, 694)
	_bar.size = Vector2(1248, 12)
	_bar.color = Color(0, 0, 0, 0.35)
	ui.add_child(_bar)
	_contact = ColorRect.new()
	_contact.size = Vector2(4, 22)
	_contact.position = Vector2(_bar.position.x + _bar.size.x * 0.56 - 2.0, 689)
	_contact.color = Color(0.95, 0.3, 0.2, 0.95)
	ui.add_child(_contact)
	_marker = ColorRect.new()
	_marker.size = Vector2(3, 26)
	_marker.position = Vector2(16, 687)
	_marker.color = Color(1, 1, 1)
	ui.add_child(_marker)

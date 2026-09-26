extends Node3D
## Showcase: every animation of the Warrior of the Mind on a lit arena, with spring-bone cloth & hair,
## the Jolt ragdoll death, VFX, and an orbiting cinematic camera.
##
## Keys: Left/Right = previous/next clip, Space = pause, R = ragdoll death, W = wind, F = free orbit,
##       Tab = playable controller scene.
## Command line (after `--`): --auto (sequence everything once and quit), --clip=<name>, --seconds=<n>

const WARRIOR := preload("res://scenes/warrior.tscn")

const DESCRIPTIONS := {
	"idle": "Heroic idle - weight shifts, breathing, look-arounds",
	"combat_idle": "Combat stance (reference 06) - coiled, clawed hands",
	"gesture": "Command gesture (reference 05)",
	"walk": "Walk (mocap)", "jog": "Jog (mocap)", "run": "Run (mocap)", "sprint": "Sprint",
	"run_start": "Run start", "run_stop": "Run - hard stop", "run_turn_left": "Run - sharp turn left",
	"run_turn_right": "Run - sharp turn right", "sidestep_left": "Run - cut left", "sidestep_right": "Run - cut right",
	"turn_left_90": "Turn in place 90 left", "turn_right_90": "Turn in place 90 right", "turn_180": "Turn in place 180",
	"dodge_left": "Dodge left", "dodge_right": "Dodge right", "dodge_back": "Back-step dodge", "dive_roll": "Dive roll",
	"jump": "Jump", "jump_forward": "Standing long jump", "run_jump": "Running jump", "fall": "Falling (loop)",
	"climb": "Climb (loop)", "climb_ladder": "Ladder climb",
	"cast_bolt": "Mind bolt (shoot)", "cast_blast": "Mind blast (two-handed)",
	"sword_summon": "Summon the sword", "sword_idle": "Sword guard", "sword_slash_1": "Sword - forehand cut",
	"sword_slash_2": "Sword - backhand cut", "sword_slash_3": "Sword - leaping smash", "sword_spin": "Sword - spinning cut",
	"hit_front": "Hit from the front", "hit_back": "Hit from behind",
	"death_backward": "Death - falls backward", "death_thrown": "Death - thrown forward",
	"get_up_front": "Get up (face down)", "get_up_back": "Get up (on the back)",
	"ragdoll": "Death - Jolt ragdoll",
}
const ORDER := ["idle", "gesture", "combat_idle", "walk", "jog", "run", "sprint", "run_start", "run_stop",
	"run_turn_left", "run_turn_right", "sidestep_left", "sidestep_right", "turn_left_90", "turn_right_90", "turn_180",
	"dodge_left", "dodge_right", "dodge_back", "dive_roll", "jump", "jump_forward", "run_jump", "fall",
	"climb", "climb_ladder", "cast_bolt", "cast_blast", "sword_summon", "sword_idle", "sword_slash_1",
	"sword_slash_2", "sword_slash_3", "sword_spin", "hit_front", "hit_back", "death_backward", "get_up_back",
	"death_thrown", "get_up_front", "ragdoll"]

var warrior: Node3D
var cam: Camera3D
var label: Label
var idx := 0
var auto := false
var clip_timer := 0.0
var clip_duration := 3.0
var orbit := 0.6
var orbit_speed := 0.12
var free_orbit := false
var cam_target := Vector3(0, 1.2, 0)
var cam_dist := 4.2
var paused := false
var seconds_override := 0.0
var only_clip := ""
var shot_path := ""
var shot_at := 1.5
var shot_orbit := -999.0
var _t_total := 0.0
var dist_override := 0.0
var height_override := -1.0

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--auto": auto = true
		elif a.begins_with("--clip="): only_clip = a.substr(7)
		elif a.begins_with("--seconds="): seconds_override = float(a.substr(10))
		elif a.begins_with("--shot="): shot_path = a.substr(7)
		elif a.begins_with("--at="): shot_at = float(a.substr(5))
		elif a.begins_with("--orbit="): shot_orbit = float(a.substr(8)); free_orbit = true
		elif a.begins_with("--dist="): dist_override = float(a.substr(7))
		elif a.begins_with("--height="): height_override = float(a.substr(9))
	EnvBuilder.build(self)
	warrior = WARRIOR.instantiate()
	add_child(warrior)
	cam = Camera3D.new(); cam.fov = 36.0; cam.near = 0.05
	add_child(cam)
	var ui := CanvasLayer.new(); add_child(ui)
	label = Label.new()
	label.position = Vector2(40, 30)
	label.add_theme_font_size_override("font_size", 30)
	label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.55))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	label.add_theme_constant_override("outline_size", 6)
	ui.add_child(label)
	var help := Label.new()
	help.text = "<- -> clips   Space pause   R ragdoll   W wind   F free camera   Tab play"
	help.position = Vector2(40, 1030)
	help.add_theme_color_override("font_color", Color(0.8, 0.75, 0.7, 0.8))
	ui.add_child(help)
	if only_clip != "": idx = max(ORDER.find(only_clip), 0)
	_start(idx)

func _start(i: int) -> void:
	idx = wrapi(i, 0, ORDER.size())
	var name: String = ORDER[idx]
	warrior.stop_ragdoll()
	warrior.global_transform = Transform3D()
	warrior.reset_springs()
	label.text = "%s\n%s" % [name, DESCRIPTIONS.get(name, "")]
	clip_timer = 0.0
	if name == "ragdoll":
		warrior.play("combat_idle", 0.0)
		clip_duration = 5.0
		get_tree().create_timer(1.0).timeout.connect(func():
			if ORDER[idx] == "ragdoll": warrior.die_ragdoll(warrior.forward() * -60.0 + Vector3.UP * 10.0))
	else:
		warrior.play(name, 0.0)
		var info: Dictionary = warrior.clips.get(name, {})
		var L: float = warrior.clip_length(name)
		clip_duration = max(L * (2.0 if info.get("loop", false) else 1.0) + (0.0 if info.get("loop", false) else 0.8), 2.5)
	if seconds_override > 0.0: clip_duration = seconds_override

func _process(delta: float) -> void:
	_t_total += delta
	if shot_path != "" and _t_total >= shot_at:
		get_viewport().get_texture().get_image().save_png(shot_path)
		get_tree().quit(); return
	if paused: return
	clip_timer += delta
	# root motion drives the character through the arena
	var rm: Transform3D = warrior.take_root_motion()
	warrior.global_transform = warrior.global_transform * rm
	if clip_timer >= clip_duration:
		if only_clip != "" and auto:
			get_tree().quit(); return
		if auto and idx == ORDER.size() - 1:
			get_tree().quit(); return
		_start(idx + 1)
	_update_camera(delta)

func _update_camera(delta: float) -> void:
	var hips: Vector3 = warrior.bone_global("Hips").origin
	var low: bool = hips.y < 0.7
	var tgt := Vector3(hips.x, clampf(hips.y - 0.02, 0.45, 2.4), hips.z)
	cam_target = cam_target.lerp(tgt, 1.0 - exp(-4.0 * delta))
	var want_dist := 3.0 if low else 4.1
	if dist_override > 0.0: want_dist = dist_override; cam_dist = dist_override
	if height_override >= 0.0: tgt.y = height_override; cam_target = tgt
	cam_dist = lerpf(cam_dist, want_dist, 1.0 - exp(-2.0 * delta))
	if shot_orbit > -900.0: orbit = shot_orbit
	elif not free_orbit: orbit += orbit_speed * delta
	var pos := cam_target + Vector3(sin(orbit) * cam_dist, 0.25 + (0.4 if low else 0.0), cos(orbit) * cam_dist)
	cam.global_position = pos
	cam.look_at(cam_target, Vector3.UP)

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_RIGHT: _start(idx + 1)
			KEY_LEFT: _start(idx - 1)
			KEY_SPACE:
				paused = not paused
				warrior.anim.speed_scale = 0.0 if paused else 1.0
			KEY_R: warrior.die_ragdoll(warrior.forward() * -60.0 + Vector3.UP * 10.0)
			KEY_W: warrior.wind_strength = 0.0 if warrior.wind_strength > 0.0 else 1.5
			KEY_F: free_orbit = not free_orbit
			KEY_TAB: get_tree().change_scene_to_file("res://scenes/playground.tscn")
	if e is InputEventMouseMotion and free_orbit and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		orbit -= e.relative.x * 0.01

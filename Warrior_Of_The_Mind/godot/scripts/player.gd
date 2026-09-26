extends CharacterBody3D
## Playable Warrior of the Mind (third person).
##
## Move: WASD (camera relative) | Shift sprint | Ctrl walk | Space jump | Mouse look (wheel = zoom)
## LMB: sword (summons it, then a 3-hit combo) | RMB: mind bolt | F: mind blast | G: gesture
## Q / E: dodge left / right | C: dive roll | X: combat stance | H: take a hit | K: ragdoll death
## Enter: get up / respawn | Esc: release the mouse | Tab: back to the showcase
## Climb: walk into the ladder and hold W (S to go down, Space to let go).

const WARRIOR := preload("res://scenes/warrior.tscn")

enum S { MOVE, AIR, ACTION, CLIMB, DEAD }

@export var walk_speed := 1.3
@export var run_speed := 4.5
@export var sprint_speed := 6.2
@export var accel := 14.0
@export var decel := 18.0
@export var turn_rate := 11.0
@export var jump_velocity := 6.8
@export var gravity := 18.0
@export var mouse_sens := 0.0025

var state := S.MOVE
var rig: Node3D                      # warrior_rig.gd
var lean: LeanModifier
var cam_pivot: Node3D
var spring: SpringArm3D
var cam: Camera3D
var yaw := 0.0
var pitch := -0.25
var facing := 0.0                    # visual yaw (radians); model faces +Z
var action := ""
var action_uses_root := false
var combo_step := 0
var combo_queued := false
var sword_out := false
var ladder: Area3D
var climb_speed := 0.9
var _prev_vel := Vector3.ZERO
var _prev_facing := 0.0
var _loco := ""
var _stance_combat := false
var _air_time := 0.0

func _ready() -> void:
	rig = WARRIOR.instantiate()
	add_child(rig)
	lean = LeanModifier.new(); lean.name = "Lean"
	rig.skeleton.add_child(lean); rig.skeleton.move_child(lean, 0)
	var shape := CollisionShape3D.new(); var cap := CapsuleShape3D.new()
	cap.radius = 0.36; cap.height = 1.95; shape.shape = cap; shape.position = Vector3(0, 0.975, 0)
	add_child(shape)
	cam_pivot = Node3D.new(); cam_pivot.position = Vector3(0, 1.55, 0); add_child(cam_pivot)
	spring = SpringArm3D.new(); spring.spring_length = 4.2; spring.margin = 0.2
	spring.add_excluded_object(get_rid())
	cam_pivot.add_child(spring)
	cam = Camera3D.new(); cam.fov = 55.0; cam.near = 0.05; spring.add_child(cam)
	cam.position = Vector3(0.45, 0, 0)
	cam.current = true
	rig.anim.animation_finished.connect(_on_anim_finished)
	rig.anim_event.connect(_on_anim_event)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_play_loco("idle")

# --------------------------------------------------------------------------- input
func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= e.relative.x * mouse_sens
		pitch = clampf(pitch - e.relative.y * mouse_sens, -1.2, 0.6)
	if e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP: spring.spring_length = maxf(1.6, spring.spring_length - 0.3)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN: spring.spring_length = minf(8.0, spring.spring_length + 0.3)
		elif e.button_index == MOUSE_BUTTON_LEFT: _attack()
		elif e.button_index == MOUSE_BUTTON_RIGHT: _start_action("cast_bolt", false)
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_ESCAPE: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
			KEY_SPACE:
				if state == S.CLIMB: _leave_ladder()
				else: _jump()
			KEY_F: _start_action("cast_blast", false)
			KEY_G: _start_action("gesture", false)
			KEY_Q: _start_action("dodge_left", true)
			KEY_E: _start_action("dodge_right", true)
			KEY_C: _start_action("dive_roll", true)
			KEY_X: _stance_combat = not _stance_combat
			KEY_H: _start_action("hit_front", true)
			KEY_K: _die()
			KEY_ENTER: _get_up()
			KEY_TAB: get_tree().change_scene_to_file("res://scenes/showcase.tscn")

func _input_dir() -> Vector3:
	var v := Vector2(
		float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)))
	if v.length() > 1.0: v = v.normalized()
	var b := Basis(Vector3.UP, yaw)
	return b * Vector3(v.x, 0, v.y)

# --------------------------------------------------------------------------- physics
func _physics_process(delta: float) -> void:
	cam_pivot.rotation = Vector3(pitch, yaw, 0)
	match state:
		S.MOVE: _move(delta)
		S.AIR: _air(delta)
		S.ACTION: _action(delta)
		S.CLIMB: _climb(delta)
		S.DEAD: pass
	_update_lean(delta)
	rig.rotation.y = facing
	_prev_vel = velocity

func _move(delta: float) -> void:
	var dir := _input_dir()
	var target := walk_speed if Input.is_key_pressed(KEY_CTRL) else (sprint_speed if Input.is_key_pressed(KEY_SHIFT) else run_speed)
	var hv := Vector3(velocity.x, 0, velocity.z)
	if dir.length() > 0.05:
		var want := dir * target
		# sharp direction change: brake harder, the lean modifier sells the weight shift
		var reversal := hv.length() > 2.0 and hv.normalized().dot(dir.normalized()) < -0.2
		hv = hv.move_toward(want, (decel * 1.4 if reversal else accel) * delta)
		var ty := atan2(dir.x, dir.z)
		facing = lerp_angle(facing, ty, 1.0 - exp(-turn_rate * delta))
	else:
		hv = hv.move_toward(Vector3.ZERO, decel * delta)
	velocity.x = hv.x; velocity.z = hv.z
	velocity.y = -2.0 if is_on_floor() else velocity.y - gravity * delta
	move_and_slide()
	if not is_on_floor():
		_air_time += delta
		if _air_time > 0.2: _enter_air(false)
		return
	_air_time = 0.0
	# ladder
	if ladder and Input.is_key_pressed(KEY_W) and _facing_ladder():
		_enter_ladder(); return
	# locomotion clip + playback rate matched to the ground speed (no foot sliding)
	var sp := hv.length()
	var clip := "idle"
	var rate := 1.0
	if sp < 0.25:
		clip = "sword_idle" if sword_out else ("combat_idle" if _stance_combat else "idle")
	elif sp < 2.4:
		clip = "walk"; rate = sp / float(rig.clips["walk"]["speed"])
	elif sp < 5.2:
		clip = "run"; rate = sp / float(rig.clips["run"]["speed"])
	else:
		clip = "sprint"; rate = sp / float(rig.clips["sprint"]["speed"])
	_play_loco(clip, clampf(rate, 0.6, 1.5))

func _play_loco(clip: String, rate := 1.0) -> void:
	if _loco != clip or rig.current != clip:
		rig.play(clip, 0.22)
		_loco = clip
	rig.anim.speed_scale = rate

func _jump() -> void:
	if state != S.MOVE or not is_on_floor(): return
	var running := Vector2(velocity.x, velocity.z).length() > 2.5
	velocity.y = jump_velocity
	_enter_air(true, running)

func _enter_air(jumped: bool, running := false) -> void:
	state = S.AIR
	_loco = ""
	rig.anim.speed_scale = 1.0
	if jumped:
		rig.play("run_jump" if running else "jump", 0.08)
		rig.anim.seek(0.35 if running else 0.42, true)
	else:
		rig.play("fall", 0.25)

func _air(delta: float) -> void:
	var dir := _input_dir()
	var hv := Vector3(velocity.x, 0, velocity.z).move_toward(dir * run_speed, 3.0 * delta)
	velocity.x = hv.x; velocity.z = hv.z
	velocity.y -= gravity * delta
	move_and_slide()
	if velocity.y < -1.0 and rig.current != "fall" and rig.current in ["jump", "run_jump"] and rig.anim.current_animation_position > 0.75:
		rig.play("fall", 0.3)
	if is_on_floor():
		state = S.MOVE
		var hard := _prev_vel.y < -9.0
		_start_action("jump", false, 1.05 if not hard else 1.0)     # landing part of the jump clip

func _attack() -> void:
	if state == S.ACTION and action.begins_with("sword_slash"):
		combo_queued = true; return
	if state != S.MOVE: return
	if not sword_out:
		sword_out = true
		_start_action("sword_summon", false); combo_step = 0; return
	combo_step = 1
	_start_action("sword_slash_1", true)

func _start_action(clip: String, root_motion: bool, seek := 0.0) -> void:
	if state == S.DEAD or state == S.CLIMB: return
	if clip.begins_with("cast") and sword_out: sword_out = false      # hands free: the sword dissolves
	state = S.ACTION
	action = clip
	action_uses_root = root_motion
	combo_queued = false
	_loco = ""
	rig.anim.speed_scale = 1.0
	rig.play(clip, 0.12)
	if seek > 0.0: rig.anim.seek(seek, true)
	if not root_motion: velocity.x *= 0.3; velocity.z *= 0.3

func _action(delta: float) -> void:
	var rm: Transform3D = rig.take_root_motion()
	if action_uses_root and delta > 0.0:
		var v := rm.origin / delta
		velocity.x = v.x; velocity.z = v.z
		facing += rm.basis.get_euler().y
	else:
		velocity.x = move_toward(velocity.x, 0, decel * delta)
		velocity.z = move_toward(velocity.z, 0, decel * delta)
	velocity.y = -2.0 if is_on_floor() else velocity.y - gravity * delta
	move_and_slide()
	# combo chaining inside the window
	var ev: Dictionary = rig.clips.get(action, {}).get("events", {})
	if combo_queued and ev.has("combo_window") and rig.anim.current_animation_position >= float(ev["combo_window"]):
		combo_step += 1
		combo_queued = false
		_start_action("sword_slash_%d" % mini(combo_step, 3), true)
	# steer attacks and casts toward the input direction a little
	var dir := _input_dir()
	if dir.length() > 0.1 and (action.begins_with("sword") or action.begins_with("cast")):
		facing = lerp_angle(facing, atan2(dir.x, dir.z), 1.0 - exp(-4.0 * delta))

func _on_anim_finished(clip: StringName) -> void:
	if state == S.ACTION and String(clip) == action:
		state = S.MOVE
		action = ""
		if String(clip) == "sword_slash_3": combo_step = 0
	elif state == S.DEAD and String(clip).begins_with("get_up"):
		state = S.MOVE

func _on_anim_event(clip: String, ev: String) -> void:
	if ev == "hit":
		for d in get_tree().get_nodes_in_group("dummies"):
			if d.global_position.distance_to(global_position + rig.forward() * 1.2) < 1.6:
				d.call("hit", rig.forward())

# --------------------------------------------------------------------------- climbing
func _facing_ladder() -> bool:
	var to := (ladder.global_position - global_position); to.y = 0
	return to.length() < 1.6 and rig.forward().dot(to.normalized()) > 0.3

func _enter_ladder() -> void:
	state = S.CLIMB
	velocity = Vector3.ZERO
	var n: Vector3 = -ladder.global_transform.basis.z
	facing = atan2(-n.x, -n.z)
	var p := ladder.global_position + n * 0.42
	global_position = Vector3(p.x, global_position.y, p.z)
	rig.play("climb", 0.25)
	climb_speed = float(rig.clips.get("climb", {}).get("speed", 0.5))

func _climb(delta: float) -> void:
	var up := float(Input.is_key_pressed(KEY_W)) - float(Input.is_key_pressed(KEY_S))
	rig.anim.speed_scale = up if absf(up) > 0.0 else 0.0
	velocity = Vector3(0, up * climb_speed * 1.35, 0)
	move_and_slide()
	var top: float = ladder.global_position.y + ladder.get_meta("height", 3.0) * 0.5
	if global_position.y > top - 0.2:
		# climb off the top: hop forward onto the ledge
		global_position += -(-ladder.global_transform.basis.z) * 0.9 + Vector3.UP * 0.4
		_leave_ladder()
	elif up < 0.0 and is_on_floor():
		_leave_ladder()

func _leave_ladder() -> void:
	state = S.MOVE
	rig.anim.speed_scale = 1.0
	_loco = ""

# --------------------------------------------------------------------------- death / hit
func _die() -> void:
	if state == S.DEAD: return
	state = S.DEAD
	velocity = Vector3.ZERO
	rig.die_ragdoll(-rig.forward() * 70.0 + Vector3.UP * 15.0)

func _get_up() -> void:
	if state != S.DEAD: return
	rig.stop_ragdoll()
	rig.play("get_up_back", 0.3)

# --------------------------------------------------------------------------- procedural lean
func _update_lean(delta: float) -> void:
	var hv := Vector3(velocity.x, 0, velocity.z)
	var ang_vel := wrapf(facing - _prev_facing, -PI, PI) / maxf(delta, 1e-4)
	_prev_facing = facing
	var acc := (hv - Vector3(_prev_vel.x, 0, _prev_vel.z)) / maxf(delta, 1e-4)
	var fwd := Vector3(sin(facing), 0, cos(facing))
	var target_roll := clampf(-ang_vel * hv.length() * 0.035, -0.45, 0.45) if state == S.MOVE else 0.0
	var target_pitch := clampf(acc.dot(fwd) * 0.025, -0.25, 0.3) if state == S.MOVE else 0.0
	var target_twist := clampf(ang_vel * 0.05, -0.3, 0.3) if state == S.MOVE else 0.0
	lean.roll = lerpf(lean.roll, target_roll, 1.0 - exp(-8.0 * delta))
	lean.pitch = lerpf(lean.pitch, target_pitch, 1.0 - exp(-6.0 * delta))
	lean.twist = lerpf(lean.twist, target_twist, 1.0 - exp(-8.0 * delta))

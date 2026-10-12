extends "res://harness/scripts/stage.gd"
## Free-feet locomotion check: idle, start, run, stop, 90° turn on flat ground.
var wako: RigidBody3D

func setup() -> void:
	wako = spawn_wako(Vector3(0, 1.0, 0))
	cam_follow = wako

func scenario(_delta: float) -> void:
	if clock < 1.5: caption("idle"); return
	if clock < 4.0:
		caption("walk to (0,0,-6)")
		wako.navigate_to(Vector3(0, 0, -6)); return
	if clock < 7.0:
		caption("turn and walk to (5,0,-6)")
		wako.navigate_to(Vector3(5, 0, -6)); return
	caption("stop")

var _last_print := -1
func _process(delta: float) -> void:
	super(delta)
	if int(clock * 2.0) != _last_print and is_instance_valid(wako):
		_last_print = int(clock * 2.0)
		print("t=%.1f pos=%s v=%.2f clip=%s ground=%s action=%s" % [clock, wako.global_position, wako.gait_speed, wako._animation.current_animation, wako.on_ground, wako.action])

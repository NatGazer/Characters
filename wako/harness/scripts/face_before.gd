extends "res://harness/scripts/stage.gd"
## Close-up of the face with only the pre-existing expression inputs:
## natural blinks, idle gaze toward a visible player, smile, real threat alarm.
const Props := preload("res://harness/scripts/face_props.gd")
var wako: RigidBody3D
var player: Node3D
var hostile: Node3D

func setup() -> void:
	wako = spawn_wako(Vector3(0, .86, 0), "face_before")
	Props.bind_atlas(wako)
	cam_target = Vector3(0, 1.1, -.2)
	cam_offset = Vector3(.35, .12, -1.45)
	player = Props.make_player(self, Vector3(-2.2, .5, -2.6))

func scenario(_delta: float) -> void:
	player.position.x = -2.2 + 4.4 * smoothstep(.6, 3.2, clock)
	if clock > 3.3 and not is_instance_valid(hostile):
		hostile = Props.make_hostile(self, Vector3(-5.5, 0, -4.0))
	caption("BEFORE  t=%.1f  player %s  threat %s" % [clock, "walks" if clock < 3.3 else "still", "visible" if is_instance_valid(hostile) else "-"])

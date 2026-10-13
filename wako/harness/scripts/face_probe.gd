extends "res://harness/scripts/stage.gd"
## Headless face diagnostics: prints the uploaded uniforms, gaze and eye
## engine counters while a player walks past and a hostile appears.
const Props := preload("res://harness/scripts/face_props.gd")
var wako: RigidBody3D
var player: Node3D
var hostile: Node3D
var _next := 0.0
var driver: Node

func setup() -> void:
	wako = Props.timed_wako(WAKO)
	wako.worker_id = "face_probe"
	wako.position = Vector3(0, .86, 0)
	add_child(wako)
	driver = Props.drive_faces(self, [wako])
	cam_target = Vector3(0, 1.1, -.2)
	cam_offset = Vector3(.35, .12, -1.45)
	player = Props.make_player(self, Vector3(-2.2, .5, -2.6))

func scenario(_delta: float) -> void:
	player.position.x = -2.2 + 4.4 * smoothstep(.6, 3.2, clock)
	if clock > 3.3 and not is_instance_valid(hostile):
		hostile = Props.make_hostile(self, Vector3(-5.5, 0, -4.0))
	if clock >= _next:
		_next += .25
		var m: MeshInstance3D = wako._skin_mesh
		var e: RefCounted = wako.eyes
		var p: RefCounted = wako.personality
		print("t=%.2f open=%.2f gaze=%s lids=%s iris=%s mouth=%s smile=%.2f alarm=%.2f | att=%s %s blinks=%d sacc=%d up=%d usec=%.1f lod=%d pers=%.1f play=%.1f" % [clock,
			m.get_instance_shader_parameter(&"eye_openness"), m.get_instance_shader_parameter(&"gaze_uv_offset"),
			m.get_instance_shader_parameter(&"eye_lids"), m.get_instance_shader_parameter(&"eye_iris"),
			m.get_instance_shader_parameter(&"mouth_shape"), m.get_instance_shader_parameter(&"eye_smile"),
			m.get_instance_shader_parameter(&"face_alarm"), p.attention.kind, p.attention.point,
			e.events.blink, e.events.saccade, e.uploads, driver.per_tick(wako), e._lod, float(p.profile_total_usec) / maxf(p.profile_ticks, 1), float(wako.idle_play.profile_total_usec) / maxf(wako.idle_play.profile_ticks, 1)])

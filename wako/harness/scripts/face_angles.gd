extends "res://harness/scripts/stage.gd"
## Camera-angle stress test for the face shader: the camera orbits from a
## grazing left view through the front to a grazing right view (and from
## below to above) while the real face engine blinks, squints and smiles.
## Look for doubled lids, streaks, tearing or a swimming catchlight.
const Props := preload("res://harness/scripts/face_props.gd")
var wako: RigidBody3D
var _beats := [[.4, &"squeeze"], [1.3, &"joy"], [2.4, &"surprise"], [3.3, &"worry"]]
var _next_beat := 0
var _blinks := [.9, 1.9, 2.9, 3.8]
var _next_blink := 0

func setup() -> void:
	wako = spawn_wako(Vector3(0, .86, 0), "face_angles")
	wako.paused = true
	Props.bind_atlas(wako)
	cam_target = Vector3(0, 1.17, -.2)

func scenario(_delta: float) -> void:
	if _next_beat < _beats.size() and clock > _beats[_next_beat][0]:
		wako.face_pulse(_beats[_next_beat][1], 1.0)
		_next_beat += 1
	if _next_blink < _blinks.size() and clock > _blinks[_next_blink]:
		wako.face_blink(false)
		_next_blink += 1

func _process(delta: float) -> void:
	var u := clampf(clock / 4.2, 0.0, 1.0)
	var yaw := lerpf(-1.35, 1.35, u)
	var pitch := .55 * sin(u * TAU)
	var dist := 1.35
	cam_offset = Vector3(sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch)) * dist
	caption("angle sweep yaw %+.0f deg pitch %+.0f deg" % [rad_to_deg(yaw), rad_to_deg(pitch)])
	super(delta)

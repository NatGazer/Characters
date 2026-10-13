extends Node
## Probe: head-flip face hooks drive the eye engine (gaze lead, cues, blink hold).
var lab: Node
var worker: RigidBody3D
var last_state := ""
var last_cue := &""
var gaze_led := 0
var gaze_ticks := 0
var blinks_in_hold := 0
var hold_ticks := 0
var cues: Array = []
var prev_blinks := 0
func _ready() -> void:
	lab = load("res://harness/scenes/head_leap_lab.tscn").instantiate()
	get_tree().root.add_child.call_deferred(lab)
func _physics_process(_d: float) -> void:
	if not is_instance_valid(worker):
		for n in get_tree().get_nodes_in_group(&"wako_helpers"): worker = n; break
		return
	var leap: RefCounted = worker.head_leap
	var eyes: RefCounted = worker.eyes
	if leap == null or eyes == null: return
	var lead: Variant = leap.gaze_target()
	if lead is Vector3:
		gaze_ticks += 1
		if eyes._want_point is Vector3 and eyes._want_point.is_finite() and (eyes._want_point - lead).length() < .05: gaze_led += 1
	var cue: StringName = leap.face_cue()
	if cue != last_cue:
		if cue != &"": cues.append("%s@%s" % [cue, leap.state])
		last_cue = cue
	var b: int = int(eyes.events.blink)
	if leap.blink_hold():
		hold_ticks += 1
		if b > prev_blinks: blinks_in_hold += 1
	prev_blinks = b
	if leap.state != last_state:
		if leap.state == "done": print("EYEWIRE gaze_led=%d/%d cues=%s hold_ticks=%d blinks_started_in_hold=%d pulses=%d" % [gaze_led, gaze_ticks, str(cues), hold_ticks, blinks_in_hold, int(eyes.events.pulse)])
		last_state = leap.state

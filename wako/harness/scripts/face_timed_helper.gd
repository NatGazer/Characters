extends "res://LogicObjects/Wako/wako_helper.gd"
## Harness-only profiling helper: the production face tick, timed in place
## (same call site, same order). Spawned through Props.timed_wako().
var face_usec := 0
var face_ticks := 0

func _update_expression(delta: float) -> void:
	var began := Time.get_ticks_usec()
	super(delta)
	face_usec += Time.get_ticks_usec() - began
	face_ticks += 1

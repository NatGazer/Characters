extends SceneTree
## Scripted input test of the playable controller: prints state / clip / position over time.
var scene; var p; var t := 0.0; var step := 0
var plan := [
	[0.5, "W", true], [2.0, "SHIFT", true], [3.2, "SHIFT", false], [3.4, "W", false],
	[3.6, "SPACE", true], [3.7, "SPACE", false],
	[5.0, "LMB", true], [6.4, "LMB", true], [6.9, "LMB", true], [7.3, "LMB", true],
	[9.5, "RMB", true], [11.0, "F", true], [12.8, "Q", true], [13.8, "C", true],
	[16.5, "K", true], [19.0, "ENTER", true],
]
func _init():
	scene = load("res://scenes/playground.tscn").instantiate(); get_root().add_child(scene)
func key(k: String, down: bool):
	if k in ["LMB", "RMB"]:
		var e := InputEventMouseButton.new(); e.button_index = MOUSE_BUTTON_LEFT if k == "LMB" else MOUSE_BUTTON_RIGHT; e.pressed = down
		Input.parse_input_event(e); return
	var e := InputEventKey.new(); e.pressed = down
	e.keycode = {"W": KEY_W, "SHIFT": KEY_SHIFT, "SPACE": KEY_SPACE, "F": KEY_F, "Q": KEY_Q, "C": KEY_C, "K": KEY_K, "ENTER": KEY_ENTER}[k]
	e.physical_keycode = e.keycode
	Input.parse_input_event(e)
var _last := ""
func _process(delta):
	t += delta
	if p == null:
		for c in scene.get_children(): if c is CharacterBody3D: p = c
		return false
	while step < plan.size() and t >= plan[step][0]:
		key(plan[step][1], plan[step][2]); step += 1
	var line := "%s %s" % [["MOVE", "AIR", "ACTION", "CLIMB", "DEAD"][p.state], p.rig.current]
	if line != _last:
		print("t=%.2f  %s  pos=%s  v=%.2f" % [t, line, str(p.global_position.snapped(Vector3.ONE * 0.01)), Vector2(p.velocity.x, p.velocity.z).length()])
		_last = line
	if t > 22.0: quit()
	return false

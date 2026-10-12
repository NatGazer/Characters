extends Node
## Harness stand-in for RaulsMod's Shortcuts autoload (quit handling only).
var quitting := false
var _quit_frames := -1
func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--auto-quit-frames="): _quit_frames = int(arg.get_slice("=", 1))
func _process(_delta: float) -> void:
	if _quit_frames < 0: return
	_quit_frames -= 1
	if _quit_frames <= 0: graceful_quit()
func graceful_quit() -> void:
	quitting = true
	get_tree().quit()

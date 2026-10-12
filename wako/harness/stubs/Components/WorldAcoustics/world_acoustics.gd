extends RefCounted
## Harness stub for RaulsMod world acoustics: plain 3D players.
static func create_player() -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.max_distance = 30.0
	return p

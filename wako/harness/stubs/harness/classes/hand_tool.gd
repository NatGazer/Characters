class_name HandTool extends Node3D
## Harness stub for RaulsMod's player hand-tool base class (only what Weapon reads).
var is_equipped := false
var crosshair_node: Control
func aim_camera() -> Camera3D: return Global.Camera
func aim_exclude() -> Array[RID]: return []

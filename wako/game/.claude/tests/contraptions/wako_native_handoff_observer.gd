extends SkeletonModifier3D
var worker: RigidBody3D
var fixture: Node

func _process_modification() -> void:
	fixture.capture_final(worker)

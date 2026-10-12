extends SkeletonModifier3D
## The ragdoll's skeleton modifier (WARRIOR REACT): it sits after AvatarPose and before the hair/cloth springs, so the
## springs always hang off the pose that is really shown. Each frame it hands the animated pose (the clips + AvatarPose)
## to the ragdoll as the tracking targets, then writes the physical pose over it, bone by bone with a weight (partial
## hits: only the loose region; knock-downs: all of it; get-ups: the ragdoll's last pose cross-faded into the clip).
## Inactive (skipped by the skeleton) while nothing is going on.

var rd : Object


func _process_modification_with_delta(delta : float) -> void:
	if rd != null:
		rd.call(&"modify", delta)

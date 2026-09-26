@tool
class_name LeanModifier
extends SkeletonModifier3D
## Procedural body lean on top of the animation: rolls the hips/spine into turns (centripetal lean)
## and pitches them with acceleration / braking, plus a head counter-rotation so the gaze stays level.
## Runs before the spring-bone simulators so the cloth and hair react to the lean.

@export var roll := 0.0          ## radians, + leans to the character's right
@export var pitch := 0.0         ## radians, + leans forward
@export var twist := 0.0         ## radians, upper body twist toward the turn

const CHAIN := [["Hips", 0.35, 0.0], ["Spine", 0.25, 0.3], ["Chest", 0.2, 0.35], ["UpperChest", 0.1, 0.35]]

func _process_modification() -> void:
	var sk := get_skeleton()
	if sk == null or (absf(roll) < 1e-4 and absf(pitch) < 1e-4 and absf(twist) < 1e-4): return
	for c in CHAIN:
		var i := sk.find_bone(c[0])
		if i < 0: continue
		var g := sk.get_bone_global_pose(i)
		# skeleton space: +Z forward, +Y up, +X is the character's left
		var q := Quaternion(Vector3(0, 0, 1), -roll * c[1]) * Quaternion(Vector3(1, 0, 0), pitch * c[1]) \
			* Quaternion(Vector3(0, 1, 0), twist * c[2])
		g.basis = Basis(q) * g.basis
		sk.set_bone_global_pose(i, g)
	# keep the head roughly level
	var h := sk.find_bone("Head")
	if h >= 0:
		var gh := sk.get_bone_global_pose(h)
		gh.basis = Basis(Quaternion(Vector3(0, 0, 1), roll * 0.6) * Quaternion(Vector3(1, 0, 0), -pitch * 0.5)) * gh.basis
		sk.set_bone_global_pose(h, gh)

extends RefCounted
## Samples one humanoid clip's pose in skeleton space without the AnimationTree (WARRIOR REACT): the get-up clips'
## first frame (to line the clip up with the body lying on the ground, and as the pose the ragdoll gathers into
## before it gets up) and every frame of the get-up (written over AvatarPose, so its look / lean / foot IK don't
## touch the get-up). The Root bone carries the clip's root motion and stays at its rest, as in the AnimationTree.

var anim : Animation
var sk : Skeleton3D
var length := 1.0
var ground := 0.0
## Bones in FK order (parents first)
var order := PackedInt32Array()
var _pos := {} # bone -> position track
var _rot := {} # bone -> rotation track
var _root := -1
var _ms := 1.0
var _prefix := ""
var _root_tracks : Array = []


func setup(a : Animation, skeleton : Skeleton3D, need : PackedInt32Array, prefix : String, clip_ground := 0.0) -> void:
	anim = a
	sk = skeleton
	length = a.length
	ground = clip_ground
	_ms = skeleton.motion_scale
	_prefix = prefix
	_root = skeleton.find_bone("Root")
	var want := {}
	for b in need:
		var i := b
		while i >= 0:
			want[i] = true
			i = skeleton.get_bone_parent(i)
	var list : Array = want.keys()
	list.sort_custom(func(x : int, y : int) -> bool: return _depth(x) < _depth(y))
	order = PackedInt32Array(list)
	for b in order:
		var path := NodePath(prefix + String(skeleton.get_bone_name(b)))
		var tp := a.find_track(path, Animation.TYPE_POSITION_3D)
		var tr := a.find_track(path, Animation.TYPE_ROTATION_3D)
		if tp >= 0:
			_pos[b] = tp
		if tr >= 0:
			_rot[b] = tr


func _depth(b : int) -> int:
	var d := 0
	var i := sk.get_bone_parent(b)
	while i >= 0:
		d += 1
		i = sk.get_bone_parent(i)
	return d


## The Root bone's transform at t (skeleton space): the clip's root motion.
func root_at(t : float) -> Transform3D:
	if _root < 0:
		return Transform3D()
	t = clampf(t, 0.0, length)
	var path := NodePath(_prefix + String(sk.get_bone_name(_root)))
	if _root_tracks.is_empty():
		_root_tracks = [anim.find_track(path, Animation.TYPE_POSITION_3D), anim.find_track(path, Animation.TYPE_ROTATION_3D)]
	var p : Vector3 = anim.position_track_interpolate(_root_tracks[0], t) * _ms if _root_tracks[0] >= 0 else Vector3.ZERO
	var q : Quaternion = anim.rotation_track_interpolate(_root_tracks[1], t) if _root_tracks[1] >= 0 else Quaternion.IDENTITY
	return Transform3D(Basis(q), p)


## bone -> [local Transform3D, global Transform3D] in skeleton space at clip time t.
func sample(t : float) -> Dictionary:
	t = clampf(t, 0.0, length)
	var out := {}
	for b in order:
		var rest := sk.get_bone_rest(b)
		var loc := rest
		if b != _root:
			var q : Quaternion = anim.rotation_track_interpolate(_rot[b], t) if _rot.has(b) else rest.basis.get_rotation_quaternion()
			var p : Vector3 = (anim.position_track_interpolate(_pos[b], t) * _ms) if _pos.has(b) else rest.origin
			loc = Transform3D(Basis(q).scaled(rest.basis.get_scale()), p)
		var par := sk.get_bone_parent(b)
		var g := loc
		if par >= 0 and out.has(par):
			g = (out[par][1] as Transform3D) * loc
		out[b] = [loc, g]
	return out

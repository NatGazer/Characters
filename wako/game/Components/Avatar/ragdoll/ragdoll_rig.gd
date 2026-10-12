extends RefCounted
## The physical body of an Avatar's ragdoll (WARRIOR REACT, R-WARRIOR-07): one RigidBody3D per entry of the profile's
## `ragdoll_bodies` ([bone, radius m, length scale, mass kg, joint (0 cone, 1 hinge), limit deg]) and a joint to its
## parent body, built once from the skeleton's rest pose and kept out of the physics space until a hit needs it.
##
## Shapes: the four torso segments (Hips, Spine, Chest, UpperChest) are boxes (a body lies flat on its back or front
## instead of rolling like a log), the limbs, neck and hands are capsules along their bones, the head a short capsule,
## the feet capsules from the heel to the toe tip.
## Joints: ConeTwistJoint3D (twist about the child bone), HingeJoint3D (knees; bending one way only) or a
## Generic6DOFJoint3D for the elbows (bending one way + the forearm's turn about its own axis). They
## are created with the bodies in a "neutral" pose, which is the centre of each cone: the arms hang forward and a
## little out, the thighs are flexed forward (a symmetric cone around the rest pose would let a knee bend backwards
## as far as forwards).
## Collision: layer 9 ("ragdoll"), mask world | vehicles | props | creatures | vegetation. It never touches the
## player's capsule (layer 2), which is out of the space anyway while the body is down. Neighbouring bodies that
## overlap in the rest pose (the torso stack, shoulders, hips and thighs) don't collide with each other.

const LAYER := 1 << 8 ## layer 9 "ragdoll"
const MASK := 1 | 4 | 8 | 16 | 64 ## world, vehicles, props, creatures, vegetation
const FAR := Vector3(0.0, -5000.0, 0.0) ## where the rig is built (out of sight; the bodies are disabled at once)
const TORSO : Array[StringName] = [&"Hips", &"Spine", &"Chest", &"UpperChest"]
## Chain child of each bone (the capsule runs from the bone to it)
const CHILD := {
	&"Neck": &"Head", &"LeftUpperArm": &"LeftLowerArm", &"RightUpperArm": &"RightLowerArm",
	&"LeftLowerArm": &"LeftHand", &"RightLowerArm": &"RightHand", &"LeftHand": &"LeftMiddleProximal",
	&"RightHand": &"RightMiddleProximal", &"LeftUpperLeg": &"LeftLowerLeg", &"RightUpperLeg": &"RightLowerLeg",
	&"LeftLowerLeg": &"LeftFoot", &"RightLowerLeg": &"RightFoot",
}
## Centre of each shoulder / hip cone (rest model space: +X left, +Y up, +Z forward; mirrored for the right side)
const NEUTRAL_ARM := Vector3(0.36, -0.75, 0.42)
const NEUTRAL_LEG := Vector3(0.1, -0.84, 0.42)
## Anatomical ranges (deg) that the profile's limits may not go below: [swing, twist]. The get-up clips' first
## frames (lying on the back / front) must fit inside them, or the body can't gather into them.
const MIN_RANGE := {&"Spine": [24.0, 14.0], &"Chest": [30.0, 14.0], &"UpperChest": [20.0, 14.0], &"Neck": [32.0, 30.0],
	&"Head": [42.0, 34.0], &"UpperArm": [80.0, 125.0], &"Hand": [45.0, 38.0], &"UpperLeg": [62.0, 55.0],
	&"Foot": [62.0, 20.0]}
## While a get-up gathers the body into a clip frame (set_getup_ranges): the chest and the head a little wider, so the
## get-up clips' lying and sitting-up frames fit (they curl the chest up to 44 and the head up to 65 deg); falls and
## hits keep MIN_RANGE
const GETUP_RANGE := {&"Chest": [44.0, 16.0], &"Head": [60.0, 34.0]}
## Forearm pronation / supination (deg each way): the elbow bends one way and the forearm turns about its own axis
## (the get-up clips' first frames need ~40 deg of it)
const FOREARM_TWIST := 80.0
## The elbow's play off its hinge (deg each way: the carrying angle; the get-up clips' elbows bend up to ~35 deg off the
## hinge axis the rest pose gives)
const ELBOW_OFF_AXIS := 32.0
## Engine convention (Godot / Jolt): a hinge's (and a 6DOF axis') limits bound the rotation of body A relative to B,
## i.e. minus the right-handed rotation of the child about the joint axis. So a joint that bends the child +0..limit
## (toward `bend`) gets [-limit, +3 deg]. (Before this the elbows and knees bent backwards and barely forwards;
## .claude/tests/_hinge_probe.gd shows the convention.)


class Body:
	var name : StringName
	var bone := -1
	var index := 0
	var parent := -1 ## body index
	var rb : RigidBody3D
	var rid : RID
	var shape : Shape3D
	## Bone frame in the body's frame (world units, keeps the model scale): bone_world = body_world * b2b
	var b2b := Transform3D()
	var b2b_inv := Transform3D()
	var region : StringName
	var mass := 1.0
	## Scalar moment of inertia about a transverse axis through the centre (kg m2)
	var inertia := 0.01
	var radius := 0.05
	var joint : Joint3D
	var hinge := false
	## Joint anchor in this body's frame and in the parent's (for the stretch check)
	var anchor_self := Vector3.ZERO
	var anchor_parent := Vector3.ZERO
	## Swing limit and twist limit (rad)
	var limit := 0.5
	var twist := 0.25
	## The same while a get-up gathers the body (GETUP_RANGE)
	var limit_getup := 0.5
	var twist_getup := 0.25
	## The joint's frame in the parent's and in this body's frame (for tests and the limit checks)
	var jframe_parent := Transform3D()
	var jframe_self := Transform3D()


var bodies : Array[Body] = []
var by_name := {}
var root : Node
var enabled := false
## Uniform scale from skeleton units to metres (model scale x the skeleton's own)
var unit := 1.0
var total_mass := 0.0
var _anatomy := {}
var _humanoid := false
var _collision_layer := LAYER
var _collision_mask := MASK


## Builds the bodies under `holder` (a plain Node, so they are free in world space). The avatar must be in the tree.
func build(av : Avatar, holder : Node, start_disabled := true) -> void:
	build_skeleton(av.skeleton, av.model, av.profile.ragdoll_bodies, holder, {"humanoid": true}, start_disabled)


## Shared native rig builder. Definitions retain the Avatar profile's six columns:
## [bone, radius metres, length scale, mass kg, 0 cone / 1 hinge, limit degrees].
## Definitions are ordered ancestors before children, as in existing profiles.
## Anatomy supplies explicit shapes, regions, joint ranges/axes, neutral directions
## and additional exclusion pairs. Only the Avatar adapter selects humanoid rules.
func build_skeleton(sk : Skeleton3D, model : Node3D, defs : Array, holder : Node,
		anatomy : Dictionary = {}, start_disabled := true) -> bool:
	if not sk or not model or not holder or not sk.is_inside_tree() or not model.is_inside_tree() or not holder.is_inside_tree():
		return false
	if defs.is_empty():
		return false
	if not bodies.is_empty():
		push_warning("RagdollRig: a rig must be freed before rebuilding")
		return false
	# The old Avatar adapter retains its missing-optional-bone handling. New
	# explicit profiles reject incomplete/misordered definitions before spawning.
	if not bool(anatomy.get("humanoid", false)) and not _valid_definitions(sk, defs):
		return false
	root = holder
	_anatomy = anatomy
	_humanoid = bool(anatomy.get("humanoid", false))
	_collision_layer = int(anatomy.get("collision_layer", LAYER))
	_collision_mask = int(anatomy.get("collision_mask", MASK))
	var skel_in_model := model.global_transform.affine_inverse() * sk.global_transform
	var F := Transform3D(Basis.from_scale(model.scale), FAR) * skel_in_model
	F.basis = Basis.from_scale(F.basis.get_scale()) # rest frame: model axes, only the scale
	unit = F.basis.get_scale().x
	var P := func(bn : StringName) -> Vector3:
		var i := sk.find_bone(bn)
		return F * sk.get_bone_global_rest(i).origin if i >= 0 else F.origin
	var mat := PhysicsMaterial.new()
	mat.friction = 0.85
	mat.bounce = 0.0
	mat.rough = true
	_mat = mat
	_slip_mat = PhysicsMaterial.new()
	_slip_mat.friction = 0.25
	_slip_mat.bounce = 0.0
	for d in defs:
		var b := Body.new()
		b.name = StringName(d[0])
		b.bone = sk.find_bone(b.name)
		if b.bone < 0:
			push_warning("AvatarRagdoll: no bone %s" % b.name)
			continue
		b.index = bodies.size()
		b.radius = float(d[1])
		b.mass = float(d[3])
		b.hinge = int(d[4]) == 1
		b.limit = deg_to_rad(float(d[5]))
		b.twist = b.limit * 0.5
		var key := StringName(String(b.name).trim_prefix("Left").trim_prefix("Right"))
		if _humanoid and MIN_RANGE.has(key) and not b.hinge:
			b.limit = maxf(b.limit, deg_to_rad(MIN_RANGE[key][0]))
			b.twist = deg_to_rad(MIN_RANGE[key][1])
		b.limit_getup = b.limit
		b.twist_getup = b.twist
		if _humanoid and GETUP_RANGE.has(key):
			b.limit_getup = maxf(b.limit, deg_to_rad(GETUP_RANGE[key][0]))
			b.twist_getup = maxf(b.twist, deg_to_rad(GETUP_RANGE[key][1]))
		var joint_definition : Dictionary = anatomy.get("joints", {}).get(b.name, {})
		if not joint_definition.is_empty():
			b.hinge = str(joint_definition.get("kind", "hinge" if b.hinge else "cone")) in ["hinge", "elbow"]
			b.limit = deg_to_rad(float(joint_definition.get("swing_deg", rad_to_deg(b.limit))))
			b.twist = deg_to_rad(float(joint_definition.get("twist_deg", rad_to_deg(b.twist))))
			b.limit_getup = deg_to_rad(float(joint_definition.get("getup_swing_deg", rad_to_deg(b.limit))))
			b.twist_getup = deg_to_rad(float(joint_definition.get("getup_twist_deg", rad_to_deg(b.twist))))
		b.region = StringName(anatomy.get("regions", {}).get(b.name, _region(b.name) if _humanoid else &"body"))
		# Nearest ragdoll ancestor
		var pb := sk.get_bone_parent(b.bone)
		while pb >= 0 and not by_name.has(sk.get_bone_name(pb)):
			pb = sk.get_bone_parent(pb)
		b.parent = (by_name[sk.get_bone_name(pb)] as Body).index if pb >= 0 else -1
		var xf := _shape_for(b, d, sk, P, F)
		var rb := RigidBody3D.new()
		rb.name = "RD_" + String(b.name)
		rb.mass = b.mass
		rb.physics_material_override = mat
		rb.collision_layer = _collision_layer
		rb.collision_mask = _collision_mask
		rb.linear_damp = 0.05
		rb.angular_damp = 0.8
		rb.can_sleep = true
		rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		var cs := CollisionShape3D.new()
		cs.shape = b.shape
		rb.add_child(cs)
		holder.add_child(rb)
		rb.global_transform = xf
		b.rb = rb
		b.rid = rb.get_rid()
		var bone_w := F * sk.get_bone_global_rest(b.bone)
		b.b2b = xf.affine_inverse() * bone_w
		b.b2b_inv = b.b2b.affine_inverse()
		bodies.append(b)
		by_name[b.name] = b
		total_mass += b.mass
	_pose_neutral(sk, F)
	for b in bodies:
		if b.parent >= 0:
			_make_joint(b, sk, F)
	_exceptions()
	if not start_disabled:
		enabled = true
		return true
	for b in bodies:
		b.rb.process_mode = Node.PROCESS_MODE_DISABLED
	enabled = false
	return true


func _valid_definitions(sk : Skeleton3D, defs : Array) -> bool:
	var selected := {}
	for definition in defs:
		if not definition is Array or definition.size() < 6 or sk.find_bone(StringName(definition[0])) < 0:
			push_warning("RagdollRig: invalid body definition or missing bone")
			return false
		for index in [1, 2, 3, 5]:
			var value := float(definition[index])
			if is_nan(value) or is_inf(value) or value < 0 or (index != 5 and value == 0):
				push_warning("RagdollRig: dimensions/mass must be finite and positive; limits finite and nonnegative")
				return false
		var bone_name := StringName(definition[0])
		if selected.has(bone_name):
			push_warning("RagdollRig: a bone may have only one physical body")
			return false
		selected[bone_name] = true
	var ancestors := {}
	for definition in defs:
		var bone_name := StringName(definition[0])
		var parent := sk.get_bone_parent(sk.find_bone(bone_name))
		while parent >= 0 and not selected.has(sk.get_bone_name(parent)):
			parent = sk.get_bone_parent(parent)
		if parent >= 0 and not ancestors.has(sk.get_bone_name(parent)):
			push_warning("RagdollRig: body definitions must put physical ancestors first")
			return false
		ancestors[bone_name] = true
	return true


static func _region(n : StringName) -> StringName:
	var s := String(n)
	if s == "Hips":
		return &"hips"
	if s in ["Spine", "Chest", "UpperChest"]:
		return &"torso"
	if s in ["Neck", "Head"]:
		return &"head"
	var side := "_l" if s.begins_with("Left") else "_r"
	if s.contains("Arm") or s.contains("Hand"):
		return StringName("arm" + side)
	return StringName("leg" + side)


## The body's shape and its rest transform (world, at FAR).
func _shape_for(b : Body, d : Array, sk : Skeleton3D, P : Callable, F : Transform3D) -> Transform3D:
	var descriptor : Dictionary = _anatomy.get("shapes", {}).get(b.name, {})
	if _humanoid and descriptor.is_empty():
		return _humanoid_shape_for(b, d, sk, P, F)
	var bone := F * sk.get_bone_global_rest(b.bone)
	# Dimensions/offsets are metres. Bone rest scale stays in b2b for the skin,
	# rather than scaling a native collider a second time.
	var frame := F.basis.orthonormalized() if str(descriptor.get("space", "bone")) == "model" else bone.basis.orthonormalized()
	var basis : Basis = frame * Basis(descriptor.get("basis", Basis.IDENTITY))
	var offset : Vector3 = frame * Vector3(descriptor.get("offset", Vector3.ZERO))
	var centre := bone.origin + offset
	match str(descriptor.get("kind", "capsule")):
		"box":
			var box := BoxShape3D.new()
			box.size = Vector3(descriptor.get("size", Vector3.ONE))
			b.shape = box
			b.inertia = b.mass * (box.size.x * box.size.x + box.size.y * box.size.y) / 12.0
		"sphere":
			var sphere := SphereShape3D.new()
			sphere.radius = float(descriptor.get("radius", b.radius))
			b.radius = sphere.radius
			b.shape = sphere
			b.inertia = .4 * b.mass * sphere.radius * sphere.radius
		_:
			var capsule := CapsuleShape3D.new()
			capsule.radius = float(descriptor.get("radius", b.radius))
			b.radius = capsule.radius
			var length := 0.0
			var child := sk.find_bone(StringName(descriptor.get("child", "")))
			if child < 0 and not descriptor.has("height"):
				var children := sk.get_bone_children(b.bone)
				if not children.is_empty():
					child = children[0]
			if child >= 0:
				# Subtract rest positions before adding FAR: thin limb lengths should
				# not lose precision to the disabled rig's distant build location.
				var direction := F.basis * (sk.get_bone_global_rest(child).origin - sk.get_bone_global_rest(b.bone).origin)
				length = direction.length() * float(d[2])
				if direction.length_squared() > .000001:
					var y := direction.normalized()
					var x := bone.basis.x.slide(y)
					if x.length_squared() < .000001:
						x = (Vector3.RIGHT if absf(y.x) < .9 else Vector3.UP).slide(y)
					x = x.normalized()
					basis = Basis(x, y, x.cross(y)) * Basis(descriptor.get("basis", Basis.IDENTITY))
				centre = bone.origin + direction * .5 + offset
			capsule.height = maxf(float(descriptor.get("height", length + capsule.radius)), 2.0 * capsule.radius + .01)
			b.shape = capsule
			b.inertia = b.mass * (capsule.height * capsule.height / 12.0 + capsule.radius * capsule.radius / 4.0)
	return Transform3D(basis.orthonormalized(), centre)


## The original player geometry remains unchanged behind its build adapter.
func _humanoid_shape_for(b : Body, d : Array, sk : Skeleton3D, P : Callable, F : Transform3D) -> Transform3D:
	var n := b.name
	var r := b.radius
	var ls := float(d[2])
	if n in TORSO:
		var legy : float = (P.call(&"LeftUpperLeg") as Vector3).y
		var legx : float = absf((P.call(&"LeftUpperLeg") as Vector3).x - F.origin.x)
		var armx : float = absf((P.call(&"LeftUpperArm") as Vector3).x - F.origin.x)
		var y0 : float
		var y1 : float
		var w : float
		var zc : float = (P.call(n) as Vector3).z
		match n:
			&"Hips":
				y0 = legy - 0.1
				y1 = (P.call(&"Spine") as Vector3).y + 0.02
				w = 2.0 * legx + 0.15
			&"Spine":
				y0 = (P.call(&"Spine") as Vector3).y - 0.02
				y1 = (P.call(&"Chest") as Vector3).y + 0.02
				w = lerpf(2.0 * legx + 0.12, 2.0 * armx, 0.3)
			&"Chest":
				y0 = (P.call(&"Chest") as Vector3).y - 0.02
				y1 = (P.call(&"UpperChest") as Vector3).y + 0.02
				w = lerpf(2.0 * legx + 0.12, 2.0 * armx, 0.55)
			_:
				y0 = (P.call(&"UpperChest") as Vector3).y - 0.02
				y1 = (P.call(&"Neck") as Vector3).y - 0.03
				w = 2.0 * armx * 0.98
				zc += 0.01
		var bx := BoxShape3D.new()
		bx.size = Vector3(w, maxf(y1 - y0, 0.05), 2.0 * r * 0.82)
		b.shape = bx
		var s := bx.size
		b.inertia = b.mass * (s.x * s.x + s.y * s.y) / 12.0
		return Transform3D(Basis(), Vector3((P.call(n) as Vector3).x, (y0 + y1) * 0.5, zc))
	var a : Vector3 = P.call(n)
	var e : Vector3
	var len_extra := r
	if n == &"Head":
		e = a + Vector3.UP * 0.2
		a = a + Vector3.FORWARD * -0.015 # a little forward (+Z is the model's front)
		e = e + Vector3.BACK * 0.015
		len_extra = 0.0
	elif String(n).ends_with("Foot"):
		var toe : Vector3 = P.call(StringName(String(n).replace("Foot", "Toes")))
		var ground := F.origin.y
		a = Vector3(a.x, ground + r, a.z - 0.07)
		e = Vector3(toe.x, ground + r, toe.z + 0.07)
		len_extra = 0.0
	elif String(n).ends_with("Hand"):
		var mid : Vector3 = P.call(CHILD[n])
		e = a + (mid - a) * 1.9
		len_extra = 0.0
	else:
		e = P.call(CHILD.get(n, n))
	var u := (e - a)
	var L := u.length() * ls
	u = u.normalized() if u.length() > 1e-5 else Vector3.UP
	var cap := CapsuleShape3D.new()
	cap.radius = r
	cap.height = maxf(L + len_extra, 2.0 * r + 0.01)
	b.shape = cap
	b.inertia = b.mass * (cap.height * cap.height / 12.0 + r * r / 4.0)
	# Frame: +Y along the capsule, +X from the bone's own X
	var bx_axis := sk.get_bone_global_rest(b.bone).basis.x.normalized()
	var x := bx_axis - u * bx_axis.dot(u)
	if x.length() < 1e-3:
		x = Vector3.RIGHT - u * u.x
	x = x.normalized()
	var z := x.cross(u).normalized()
	return Transform3D(Basis(x, u, z), (a + e) * 0.5)


## Turns the shoulders and hips to the centres of their cones (the pose the joints are built in).
func _pose_neutral(sk : Skeleton3D, F : Transform3D) -> void:
	for b in bodies:
		var s := String(b.name)
		var neutral := Vector3.ZERO
		if _humanoid and s.ends_with("UpperArm"):
			neutral = NEUTRAL_ARM
		elif _humanoid and s.ends_with("UpperLeg"):
			neutral = NEUTRAL_LEG
		if _humanoid and s.begins_with("Right"):
			neutral.x = -neutral.x
		neutral = _anatomy.get("neutral_directions", {}).get(b.name, neutral)
		if neutral.length_squared() < .000001:
			continue
		var anchor := F * sk.get_bone_global_rest(b.bone).origin
		var d0 := b.rb.global_transform.basis.y.normalized()
		var q := Quaternion(d0, neutral.normalized())
		var M := Transform3D(Basis(q), anchor) * Transform3D(Basis(), -anchor)
		for c in _subtree(b.index):
			c.rb.global_transform = M * c.rb.global_transform


func _subtree(i : int) -> Array[Body]:
	var out : Array[Body] = [bodies[i]]
	var k := 0
	while k < out.size():
		var cur := out[k]
		k += 1
		for b in bodies:
			if b.parent == cur.index:
				out.append(b)
	return out


func _make_joint(b : Body, sk : Skeleton3D, F : Transform3D) -> void:
	var pbody := bodies[b.parent]
	# Anchor: the child bone's origin, where it is now (neutral pose): bone = body * b2b
	var anchor := (b.rb.global_transform * b.b2b).origin
	var u := b.rb.global_transform.basis.y.normalized() # along the bone (capsules; torso boxes: up)
	if String(b.name).ends_with("Foot"):
		u = b.rb.global_transform.basis.y.normalized() # heel to toe
	var j : Joint3D
	var descriptor : Dictionary = _anatomy.get("joints", {}).get(b.name, {})
	var joint_axis := Vector3.ZERO
	if descriptor.has("axis"):
		# Primary rotation axis: hinge bend or cone twist, in the bone frame.
		joint_axis = ((b.rb.global_transform * b.b2b).basis.orthonormalized() * Vector3(descriptor.axis)).normalized()
		if not b.hinge:
			u = joint_axis
	if b.hinge:
		# Hinge about the axis that bends the child toward the front (elbow) or the back (knee)
		var fwd := Vector3.BACK # model forward is +Z
		var bend : Vector3 = descriptor.get("bend", fwd if String(b.name).contains("Arm") and _humanoid else -fwd)
		var k := u.cross(bend).normalized()
		if descriptor.has("axis"):
			k = joint_axis
		var z := k
		var x := u - z * u.dot(z)
		if x.length_squared() < .000001:
			x = (Vector3.RIGHT if absf(z.x) < .9 else Vector3.UP).slide(z)
		x = x.normalized()
		var y := z.cross(x).normalized()
		if (_humanoid and String(b.name).contains("Arm")) or str(descriptor.get("kind", "")) == "elbow":
			# Elbow: the bend (Z) one way, the forearm's turn about the bone (X), nothing about Y
			var g := Generic6DOFJoint3D.new()
			g.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
			g.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, deg_to_rad(-FOREARM_TWIST))
			g.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, deg_to_rad(FOREARM_TWIST))
			g.set_flag_y(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
			g.set_param_y(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, deg_to_rad(-ELBOW_OFF_AXIS))
			g.set_param_y(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, deg_to_rad(ELBOW_OFF_AXIS))
			g.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
			g.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, -b.limit)
			g.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, deg_to_rad(3.0))
			j = g
		else:
			var h := HingeJoint3D.new()
			h.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
			h.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, -b.limit)
			h.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, deg_to_rad(3.0))
			j = h
		j.transform = Transform3D(Basis(x, y, z), anchor)
	else:
		var ct := ConeTwistJoint3D.new()
		ct.set_param(ConeTwistJoint3D.PARAM_SWING_SPAN, b.limit)
		ct.set_param(ConeTwistJoint3D.PARAM_TWIST_SPAN, b.twist)
		j = ct
		# Twist axis (+X) along the child bone
		var x := u
		var y := Vector3.UP if absf(u.dot(Vector3.UP)) < 0.9 else Vector3.BACK
		y = (y - x * y.dot(x)).normalized()
		var z := x.cross(y).normalized()
		j.transform = Transform3D(Basis(x, y, z), anchor)
	j.name = "J_" + String(b.name)
	root.add_child(j)
	j.global_transform = j.transform
	j.node_a = j.get_path_to(pbody.rb)
	j.node_b = j.get_path_to(b.rb)
	j.exclude_nodes_from_collision = true
	b.joint = j
	b.anchor_self = b.rb.global_transform.affine_inverse() * anchor
	b.jframe_self = b.rb.global_transform.affine_inverse() * j.global_transform
	b.jframe_parent = pbody.rb.global_transform.affine_inverse() * j.global_transform
	b.anchor_parent = pbody.rb.global_transform.affine_inverse() * anchor


## Bodies that overlap in the rest pose don't collide with each other.
func _exceptions() -> void:
	var torso_like : Array[StringName] = [&"Hips", &"Spine", &"Chest", &"UpperChest", &"Neck", &"Head"]
	for i in bodies.size():
		for k in range(i + 1, bodies.size()):
			var a := bodies[i]
			var c := bodies[k]
			var skip := a.parent == c.index or c.parent == a.index
			if not skip and a.parent >= 0 and bodies[a.parent].parent == c.index:
				skip = true
			if not skip and c.parent >= 0 and bodies[c.parent].parent == a.index:
				skip = true
			if _humanoid and not skip and a.name in torso_like and c.name in torso_like:
				skip = true
			var an := String(a.name)
			var cn := String(c.name)
			if _humanoid and not skip and (an.ends_with("UpperArm") or cn.ends_with("UpperArm")):
				var other := cn if an.ends_with("UpperArm") else an
				skip = other in ["Spine", "Chest", "UpperChest", "Neck", "Head"]
			if _humanoid and not skip and (an.ends_with("UpperLeg") or cn.ends_with("UpperLeg")):
				var other2 := cn if an.ends_with("UpperLeg") else an
				skip = other2 in ["Hips", "Spine", "LeftUpperLeg", "RightUpperLeg"]
			if not skip:
				for pair : Array in _anatomy.get("exclude_pairs", []):
					if pair.size() == 2 and ((a.name == StringName(pair[0]) and c.name == StringName(pair[1])) or (a.name == StringName(pair[1]) and c.name == StringName(pair[0]))):
						skip = true
						break
			if skip:
				a.rb.add_collision_exception_with(c.rb)


var _loose_pairs : Array = []
var _getup_ranges := false

## The get-up's joint ranges on / off (GETUP_RANGE).
func set_getup_ranges(on : bool) -> void:
	if on == _getup_ranges:
		return
	_getup_ranges = on
	for b in bodies:
		var ct := b.joint as ConeTwistJoint3D
		if ct and (b.limit_getup != b.limit or b.twist_getup != b.twist):
			ct.set_param(ConeTwistJoint3D.PARAM_SWING_SPAN, b.limit_getup if on else b.limit)
			ct.set_param(ConeTwistJoint3D.PARAM_TWIST_SPAN, b.twist_getup if on else b.twist)

var _mat : PhysicsMaterial
var _slip_mat : PhysicsMaterial

## Collision between the limbs and the rest of the body on / off (off while a get-up gathers the body: an arm or a leg
## it lies on slides out from under the torso instead of being wedged against the ground). The pairs that never
## collide (_exceptions) are left alone.
func set_limb_collision(on : bool) -> void:
	if on:
		for pr in _loose_pairs:
			var a : Body = pr[0]
			var c : Body = pr[1]
			if is_instance_valid(a.rb) and is_instance_valid(c.rb):
				a.rb.remove_collision_exception_with(c.rb)
		_loose_pairs.clear()
		for b in bodies:
			if b.rb.physics_material_override != _mat:
				b.rb.physics_material_override = _mat
		return
	# ... and they slide over the ground into place instead of sticking where they lie
	for b in bodies:
		if b.region.begins_with("arm") or b.region.begins_with("leg"):
			b.rb.physics_material_override = _slip_mat
	if not _loose_pairs.is_empty():
		return
	for i in bodies.size():
		for k in range(i + 1, bodies.size()):
			var a := bodies[i]
			var c := bodies[k]
			var la := a.region.begins_with("arm") or a.region.begins_with("leg")
			var lc := c.region.begins_with("arm") or c.region.begins_with("leg")
			if not (la or lc) or a.region == c.region:
				continue
			if c.rb in a.rb.get_collision_exceptions():
				continue
			a.rb.add_collision_exception_with(c.rb)
			_loose_pairs.append([a, c])


## Puts the bodies in the space at `xforms` (world) with velocities. `lin`/`ang`: per body.
func enable(xforms : Array[Transform3D], lin : Array[Vector3], ang : Array[Vector3]) -> void:
	for b in bodies:
		b.rb.process_mode = Node.PROCESS_MODE_INHERIT
		b.rb.freeze = false
	for b in bodies:
		var t := xforms[b.index]
		b.rb.global_transform = t
		PhysicsServer3D.body_set_state(b.rid, PhysicsServer3D.BODY_STATE_TRANSFORM, t)
		PhysicsServer3D.body_set_state(b.rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, lin[b.index])
		PhysicsServer3D.body_set_state(b.rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, ang[b.index])
		PhysicsServer3D.body_set_state(b.rid, PhysicsServer3D.BODY_STATE_SLEEPING, false)
	enabled = true


## Takes the bodies out of the physics space (zero cost while idle).
func disable() -> void:
	set_limb_collision(true)
	set_getup_ranges(false)
	for b in bodies:
		b.rb.process_mode = Node.PROCESS_MODE_DISABLED
		b.rb.continuous_cd = false
	enabled = false


## Kinematic (moved along the animation, as heavy as the world for the joints) or simulated.
var dbg_no_kin := false
func set_kinematic(b : Body, on : bool) -> void:
	if dbg_no_kin:
		return
	if b.rb.freeze != on:
		b.rb.freeze = on


## Collision on/off per body (partial reactions: only the loose bodies touch anything).
func set_colliding(b : Body, on : bool) -> void:
	PhysicsServer3D.body_set_collision_layer(b.rid, _collision_layer if on else 0)
	PhysicsServer3D.body_set_collision_mask(b.rid, _collision_mask if on else 0)


## Body-world targets at the current animated skeleton pose. Supplying an output
## array lets an active controller reuse its storage without per-frame allocation.
func capture_pose(sk : Skeleton3D, out : Array[Transform3D] = [], skeleton_world : Variant = null) -> Array[Transform3D]:
	var S : Transform3D = skeleton_world if skeleton_world is Transform3D else sk.global_transform
	out.resize(bodies.size())
	for b in bodies:
		var bodyw := S * sk.get_bone_global_pose(b.bone) * b.b2b_inv
		bodyw.basis = bodyw.basis.orthonormalized()
		out[b.index] = bodyw
	return out


## Writes world BONE transforms, not body transforms. Root translation blends;
## other bones keep their rest lengths and blend only their local rotations.
## Avatar supplies its captured skeleton frame to retain its get-up ordering.
func write_pose(sk : Skeleton3D, world_bones : Array[Transform3D], weights : PackedFloat32Array,
		skeleton_world : Variant = null) -> void:
	var S : Transform3D = skeleton_world if skeleton_world is Transform3D else sk.global_transform
	var Sinv := S.affine_inverse()
	for b in bodies:
		var wi := weights[b.index]
		if wi <= 0.0005:
			continue
		var t := Sinv * world_bones[b.index]
		var tq := t.basis.orthonormalized().get_rotation_quaternion()
		if b.parent < 0:
			var g := sk.get_bone_global_pose(b.bone)
			var sc := g.basis.get_scale()
			var gq := g.basis.orthonormalized().get_rotation_quaternion()
			g = Transform3D(Basis(gq.slerp(tq, wi)).scaled(sc), g.origin.lerp(t.origin, wi))
			sk.set_bone_global_pose(b.bone, g)
		else:
			var par := sk.get_bone_global_pose(sk.get_bone_parent(b.bone))
			var lq := (par.basis.orthonormalized().get_rotation_quaternion().inverse() * tq).normalized()
			var cur := sk.get_bone_pose_rotation(b.bone)
			sk.set_bone_pose_rotation(b.bone, cur.slerp(lq, wi) if wi < 0.9995 else lq)


## Native joint-space muscle tone, shared with the player's existing controller.
## Equal/opposite impulses conserve momentum; they cannot lift an unsupported rig.
func apply_joint_tone(current_world : Array[Transform3D], relative_targets : Array[Quaternion],
		delta : float, hz : float, zeta : float, stiffness_scale : PackedFloat32Array = PackedFloat32Array(),
		torque_caps : PackedFloat32Array = PackedFloat32Array()) -> void:
	var om := TAU * hz
	for b in bodies:
		if b.parent < 0:
			continue
		var p := bodies[b.parent]
		var qp := current_world[p.index].basis.get_rotation_quaternion()
		var qc := current_world[b.index].basis.get_rotation_quaternion()
		var err := rotation_vector((qp * relative_targets[b.index]) * qc.inverse())
		var wc : Vector3 = PhysicsServer3D.body_get_state(b.rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
		var wp : Vector3 = PhysicsServer3D.body_get_state(p.rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
		var kp := om * om
		if stiffness_scale.size() > b.index:
			kp *= stiffness_scale[b.index]
		var dw := (err * kp - (wc - wp) * 2.0 * zeta * om) * delta
		var ie := b.inertia * p.inertia / (b.inertia + p.inertia)
		var impulse := dw * ie
		# Organic profiles can bound muscle strength in Nm without changing the
		# Avatar's existing default. Clamp the pair together to conserve momentum.
		if torque_caps.size() > b.index:
			impulse = impulse.limit_length(maxf(0.0, torque_caps[b.index]) * delta)
		PhysicsServer3D.body_apply_torque_impulse(b.rid, impulse)
		PhysicsServer3D.body_apply_torque_impulse(p.rid, -impulse)


static func rotation_vector(q : Quaternion) -> Vector3:
	q = q.normalized()
	if q.w < 0.0:
		q = -q
	var angle := 2.0 * acos(clampf(q.w, -1.0, 1.0))
	var s := sqrt(maxf(1.0 - q.w * q.w, 0.0))
	if s < 1e-6:
		return Vector3.ZERO
	return Vector3(q.x, q.y, q.z) / s * angle


## Where a pose (world body transforms) sits in each joint's range: [name, swing deg, twist deg, limit deg, hinge].
## Hinges: swing = the bend angle about the hinge axis (+ = the allowed way).
func joint_report(xf : Array[Transform3D]) -> Array:
	var out := []
	for b in bodies:
		if b.parent < 0:
			continue
		var fa := xf[b.parent] * b.jframe_parent
		var fb := xf[b.index] * b.jframe_self
		var rel := (fa.basis.orthonormalized().inverse() * fb.basis.orthonormalized())
		if b.hinge:
			# rotation about Z: angle of X in the XY plane
			var ang := atan2(rel.x.y, rel.x.x)
			var off := rad_to_deg(acos(clampf(rel.z.z, -1.0, 1.0)))
			out.append([b.name, rad_to_deg(ang), off, rad_to_deg(b.limit), true])
		else:
			var swing := rad_to_deg(acos(clampf(rel.x.x, -1.0, 1.0)))
			# twist: rotation about x after removing the swing
			var q := rel.get_rotation_quaternion()
			var tw := Quaternion(q.x, 0.0, 0.0, q.w).normalized()
			var twist := rad_to_deg(2.0 * atan2(tw.x, tw.w))
			out.append([b.name, swing, wrapf(twist, -180.0, 180.0), rad_to_deg(b.limit), false, rad_to_deg(b.twist)])
	return out


func free_all() -> void:
	for b in bodies:
		if is_instance_valid(b.joint):
			b.joint.queue_free()
		if is_instance_valid(b.rb):
			b.rb.queue_free()
	bodies.clear()
	by_name.clear()
	_loose_pairs.clear()
	_getup_ranges = false
	total_mass = 0.0
	enabled = false

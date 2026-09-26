@tool
extends Node3D
## Warrior of the Mind - runtime character setup.
##
## Put this on a Node3D that instances `assets/warrior/warrior.glb` as a child. On ready it:
##  * tunes the imported materials (hair alpha-to-coverage, cloth alpha scissor + double sided,
##    skin subsurface scattering, emissive gold / eyes),
##  * builds SpringBoneSimulator3D chains for the cape, robe skirt, tabards, stoles, hair, pendant and
##    daggers from `chains.json` (exported by the Blender pipeline) + collision capsules on the body,
##  * builds a PhysicalBoneSimulator3D ragdoll (Jolt) used by `die_ragdoll()`,
##  * adds a LookAtModifier3D for the head, eye glow lights, and a sword attachment on the right hand.
##
## Everything is procedural so re-exporting the GLB from the pipeline never breaks the scene.

signal ragdoll_started
signal anim_event(clip: String, event: String)

@export var chains_json: String = "res://assets/warrior/chains.json"
@export var enable_springs := true
@export var enable_ragdoll := true
@export var look_target: Node3D
@export_range(0.0, 3.0) var wind_strength := 0.0

var skeleton: Skeleton3D
var anim: AnimationPlayer
var springs: Array[SpringBoneSimulator3D] = []
var ragdoll: PhysicalBoneSimulator3D
var look_at: LookAtModifier3D
var _sword: Node3D
var _t := 0.0
var clips := {}                 # clips.json: loop, speed, events, seconds
var current := ""
var _pending_events: Array = []
var _clip_time := 0.0
const ROOT_TRACK := "Warrior/Skeleton3D:Root"

# spring parameters per chain group: stiffness, drag, gravity, radius
const GROUPS := {
	"cape":    {"stiffness": 0.55, "drag": 0.35, "gravity": 1.6, "radius": 0.030},
	"skirt":   {"stiffness": 1.10, "drag": 0.45, "gravity": 1.2, "radius": 0.035},
	"panel":   {"stiffness": 0.90, "drag": 0.40, "gravity": 1.4, "radius": 0.020},
	"stole":   {"stiffness": 0.70, "drag": 0.35, "gravity": 1.5, "radius": 0.020},
	"hair":    {"stiffness": 1.30, "drag": 0.30, "gravity": 0.9, "radius": 0.022},
	"pendant": {"stiffness": 0.25, "drag": 0.20, "gravity": 3.0, "radius": 0.010},
	"dagger":  {"stiffness": 3.00, "drag": 0.60, "gravity": 0.6, "radius": 0.015},
}
# which body colliders each group reacts to
const GROUP_COLLIDERS := {
	"cape": ["torso", "upperarm", "thigh", "shin", "hips"],
	"skirt": ["thigh", "shin", "hips"],
	"panel": ["thigh", "shin", "hips"],
	"stole": ["thigh", "shin", "torso", "hips"],
	"hair": ["head", "neck", "torso", "upperarm"],
	"pendant": ["thigh", "hips"],
	"dagger": ["thigh", "hips"],
}
# body collision capsules: name, bone, radius, height (along the bone), offset along the bone (0..1)
const COLLIDERS := [
	["hips", "Hips", 0.17, 0.30, 0.3],
	["torso", "Chest", 0.19, 0.42, 0.6],
	["head", "Head", 0.11, 0.24, 0.35],
	["neck", "Neck", 0.07, 0.14, 0.5],
	["thigh_l", "LeftUpperLeg", 0.13, 0.46, 0.5], ["thigh_r", "RightUpperLeg", 0.13, 0.46, 0.5],
	["shin_l", "LeftLowerLeg", 0.10, 0.50, 0.5], ["shin_r", "RightLowerLeg", 0.10, 0.50, 0.5],
	["upperarm_l", "LeftUpperArm", 0.075, 0.30, 0.5], ["upperarm_r", "RightUpperArm", 0.075, 0.30, 0.5],
]

func _ready() -> void:
	skeleton = _find(self, "Skeleton3D") as Skeleton3D
	anim = _find(self, "AnimationPlayer") as AnimationPlayer
	if skeleton == null:
		push_error("warrior_rig: no Skeleton3D found"); return
	_tune_materials()
	if enable_springs: _build_springs()
	if enable_ragdoll: _build_ragdoll()
	_build_look_at()
	_build_eye_glow()
	_setup_loops()
	if anim:
		anim.root_motion_track = NodePath(ROOT_TRACK)
		anim.playback_default_blend_time = 0.15

# --------------------------------------------------------------------------- playback + events
## Play a clip with a cross-fade; schedules its events (from clips.json) and the default VFX.
func play(clip: String, blend := 0.18, speed := 1.0) -> void:
	if anim == null or not anim.has_animation(clip): return
	anim.play(clip, blend, speed)
	current = clip
	_clip_time = 0.0
	_pending_events.clear()
	var ev: Dictionary = clips.get(clip, {}).get("events", {})
	for k in ev.keys(): _pending_events.append([float(ev[k]), String(k)])
	_pending_events.sort_custom(func(a, b): return a[0] < b[0])

func clip_length(clip: String) -> float:
	return anim.get_animation(clip).length if anim and anim.has_animation(clip) else 0.0

func _process(delta: float) -> void:
	if Engine.is_editor_hint() or anim == null: return
	if anim.current_animation == current: _clip_time = anim.current_animation_position
	while _pending_events.size() and _pending_events[0][0] <= _clip_time:
		var e: Array = _pending_events.pop_front()
		_fire(current, e[1])

func _fire(clip: String, ev: String) -> void:
	anim_event.emit(clip, ev)
	var world := get_tree().current_scene if get_tree().current_scene else get_parent()
	if clip == "cast_bolt" and ev == "release":
		var t := bone_global("RCastSocket")
		WarriorVFX.spawn_bolt(world, t.origin, forward())
	elif clip == "cast_blast" and ev == "release":
		var a := bone_global("RCastSocket").origin; var b := bone_global("LCastSocket").origin
		WarriorVFX.spawn_blast(world, (a + b) * 0.5, forward())
	elif clip == "sword_summon" and ev == "appear":
		var sock := _socket_node("SwordSocket")
		if sock: WarriorVFX.spawn_summon(sock)
	elif clip.begins_with("sword_") and ev == "hit":
		var tip := _socket_node("SwordSocket")
		if tip: WarriorVFX.slash_trail(tip)

## World transform of a bone.
func bone_global(bone: String) -> Transform3D:
	var i := skeleton.find_bone(bone)
	return skeleton.global_transform * skeleton.get_bone_global_pose(i) if i >= 0 else global_transform

## Character forward (the model faces +Z).
func forward() -> Vector3:
	return global_transform.basis.z.normalized()

var _sockets := {}
func _socket_node(bone: String) -> Node3D:
	if _sockets.has(bone): return _sockets[bone]
	var ba := BoneAttachment3D.new(); ba.bone_name = bone; ba.name = bone + "Attach"
	skeleton.add_child(ba)
	if bone == "SwordSocket":
		var tip := Node3D.new(); tip.position = Vector3(0, 0.9, 0); ba.add_child(tip)
		_sockets[bone] = tip
	else:
		_sockets[bone] = ba
	return _sockets[bone]

## Root motion accumulated by the AnimationPlayer since the last call, in world space.
func take_root_motion() -> Transform3D:
	if anim == null: return Transform3D()
	var p := anim.get_root_motion_position()
	var q := anim.get_root_motion_rotation()
	var sk_basis := skeleton.global_transform.basis
	return Transform3D(Basis(q), sk_basis * p)

func _find(n: Node, cls: String) -> Node:
	for c in n.get_children():
		if c.is_class(cls): return c
		var r := _find(c, cls)
		if r: return r
	return null

# --------------------------------------------------------------------------- materials
func _tune_materials() -> void:
	for mi in _all_meshes(self):
		for s in mi.mesh.get_surface_count():
			var m := mi.get_active_material(s) as StandardMaterial3D
			if m == null: continue
			m = m.duplicate()
			var n := m.resource_name.to_lower()
			if "hair" in n:
				m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				m.alpha_scissor_threshold = 0.35
				m.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE_AND_TO_ONE
				m.cull_mode = BaseMaterial3D.CULL_DISABLED
				m.roughness = 0.6
				m.metallic_specular = 0.3
				m.backlight_enabled = true; m.backlight = Color(0.12, 0.07, 0.04)
			elif "cloth" in n:
				m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				m.alpha_scissor_threshold = 0.45
				m.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE
				m.cull_mode = BaseMaterial3D.CULL_DISABLED
				m.backlight_enabled = true; m.backlight = Color(0.12, 0.01, 0.015)
				m.albedo_color = Color(0.82, 0.78, 0.78)
				m.emission_energy_multiplier = 1.2
			elif "body" in n:
				m.subsurf_scatter_enabled = true; m.subsurf_scatter_strength = 0.25
				m.subsurf_scatter_skin_mode = true
				m.emission_energy_multiplier = 1.0
			elif "armor" in n:
				m.emission_energy_multiplier = 1.4
			elif "eye" in n:
				m.emission_energy_multiplier = 1.1
				m.clearcoat_enabled = true; m.clearcoat = 1.0; m.clearcoat_roughness = 0.02
			mi.set_surface_override_material(s, m)

func _all_meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for c in n.get_children():
		if c is MeshInstance3D and c.mesh: out.append(c)
		out.append_array(_all_meshes(c))
	return out

# --------------------------------------------------------------------------- spring bones
func _load_chains() -> Array:
	if not FileAccess.file_exists(chains_json):
		push_warning("warrior_rig: missing " + chains_json); return []
	return JSON.parse_string(FileAccess.get_file_as_string(chains_json))

func _build_springs() -> void:
	var chains := _load_chains()
	# body colliders (shared by all simulators through paths)
	var colliders := {}
	var by_group := {}
	for c in chains:
		var g: String = c["params"]["group"]
		if not by_group.has(g): by_group[g] = []
		by_group[g].append(c)
	for g in by_group.keys():
		var sim := SpringBoneSimulator3D.new()
		sim.name = "Spring_" + g
		skeleton.add_child(sim)
		var p: Dictionary = GROUPS.get(g, GROUPS["panel"])
		var cols: Array = []
		for cdef in COLLIDERS:
			var key: String = cdef[0]
			var base := key.split("_")[0]
			if not (base in GROUP_COLLIDERS.get(g, [])): continue
			var cap := SpringBoneCollisionCapsule3D.new()
			cap.name = "Col_" + key
			cap.bone_name = cdef[1]
			cap.radius = cdef[2]; cap.height = cdef[3] + 2.0 * cdef[2]
			var bl := _bone_length(cdef[1])
			cap.position_offset = Vector3(0, bl * cdef[4], 0)
			sim.add_child(cap)
			cols.append(cap)
		sim.setting_count = by_group[g].size()
		for i in by_group[g].size():
			var c: Dictionary = by_group[g][i]
			var bones: Array = c["bones"]
			sim.set_root_bone_name(i, bones[0])
			sim.set_end_bone_name(i, bones[bones.size() - 1])
			sim.set_extend_end_bone(i, true)
			sim.set_end_bone_direction(i, SkeletonModifier3D.BONE_DIRECTION_PLUS_Y)
			sim.set_end_bone_length(i, 0.06)
			sim.set_stiffness(i, p["stiffness"])
			sim.set_drag(i, p["drag"])
			sim.set_gravity(i, p["gravity"])
			sim.set_radius(i, p["radius"])
			# softer toward the tips: stiffness falls off, drag stays
			if bones.size() > 1:
				var sc := Curve.new(); sc.add_point(Vector2(0, 1.0)); sc.add_point(Vector2(1, 0.45))
				sim.set_stiffness_damping_curve(i, sc)
			sim.set_enable_all_child_collisions(i, true)
		springs.append(sim)

func _bone_length(bone: String) -> float:
	var i := skeleton.find_bone(bone)
	if i < 0: return 0.1
	for c in skeleton.get_bone_children(i):
		return skeleton.get_bone_rest(c).origin.length()
	return 0.1

func reset_springs() -> void:
	for s in springs: s.reset()

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint(): return
	_t += delta
	if wind_strength > 0.0:
		var gust := sin(_t * 0.9) * 0.5 + sin(_t * 2.3 + 1.0) * 0.3 + 0.6
		var f := Vector3(0.4, 0, 1.0).normalized() * wind_strength * gust
		for s in springs:
			if s.name in ["Spring_cape", "Spring_hair", "Spring_stole", "Spring_panel", "Spring_skirt"]:
				s.external_force = f

# --------------------------------------------------------------------------- ragdoll (Jolt)
const RAGDOLL := [
	# bone, radius, length scale, mass, joint type (0 pin/cone, 1 hinge), limits deg
	["Hips", 0.15, 0.9, 12.0, 0, 20], ["Spine", 0.14, 1.0, 8.0, 0, 20], ["Chest", 0.16, 1.0, 10.0, 0, 20],
	["UpperChest", 0.17, 1.0, 10.0, 0, 15], ["Neck", 0.06, 1.0, 2.0, 0, 30], ["Head", 0.11, 0.9, 5.0, 0, 35],
	["LeftUpperArm", 0.065, 1.0, 3.0, 0, 70], ["RightUpperArm", 0.065, 1.0, 3.0, 0, 70],
	["LeftLowerArm", 0.055, 1.0, 2.0, 1, 130], ["RightLowerArm", 0.055, 1.0, 2.0, 1, 130],
	["LeftHand", 0.045, 1.0, 0.6, 0, 40], ["RightHand", 0.045, 1.0, 0.6, 0, 40],
	["LeftUpperLeg", 0.09, 1.0, 9.0, 0, 60], ["RightUpperLeg", 0.09, 1.0, 9.0, 0, 60],
	["LeftLowerLeg", 0.07, 1.0, 5.0, 1, 140], ["RightLowerLeg", 0.07, 1.0, 5.0, 1, 140],
	["LeftFoot", 0.05, 1.0, 1.2, 0, 30], ["RightFoot", 0.05, 1.0, 1.2, 0, 30],
]

func _build_ragdoll() -> void:
	ragdoll = PhysicalBoneSimulator3D.new()
	ragdoll.name = "Ragdoll"
	skeleton.add_child(ragdoll)
	for r in RAGDOLL:
		var bone: String = r[0]
		var bi := skeleton.find_bone(bone)
		if bi < 0: continue
		var pb := PhysicalBone3D.new()
		pb.name = "PB_" + bone
		pb.bone_name = bone
		pb.mass = r[3]
		pb.friction = 0.9
		pb.linear_damp = 0.15; pb.angular_damp = 1.2
		var L: float = _bone_length(bone) * float(r[2])
		var cs := CollisionShape3D.new()
		var cap := CapsuleShape3D.new(); cap.radius = r[1]; cap.height = max(L, r[1] * 2.1)
		cs.shape = cap
		pb.add_child(cs)
		# capsule along the bone's +Y, centred on the bone
		pb.body_offset = Transform3D(Basis(), Vector3(0, -L * 0.5, 0))
		if r[4] == 1:
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_HINGE
			pb.set("joint_constraints/angular_limit_enabled", true)
			pb.set("joint_constraints/angular_limit_upper", 0.0)
			pb.set("joint_constraints/angular_limit_lower", -float(r[5]))
		else:
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
			pb.set("joint_constraints/swing_span", float(r[5]))
			pb.set("joint_constraints/twist_span", float(r[5]) * 0.5)
		pb.joint_offset = Transform3D(Basis(), Vector3(0, L * 0.5, 0))
		ragdoll.add_child(pb)
	ragdoll.active = false

## Hand the body over to Jolt. Optional impulse (world space) applied to the chest.
func die_ragdoll(impulse := Vector3.ZERO, blend_time := 0.12) -> void:
	if ragdoll == null: return
	if anim: anim.pause()
	ragdoll.active = true
	ragdoll.physical_bones_start_simulation()
	ragdoll_started.emit()
	var tw := create_tween()
	ragdoll.influence = 0.0
	tw.tween_property(ragdoll, "influence", 1.0, blend_time)
	if impulse != Vector3.ZERO:
		for pb in ragdoll.get_children():
			if pb is PhysicalBone3D and pb.bone_name in ["UpperChest", "Chest"]:
				pb.apply_central_impulse(impulse)
	# cloth and hair keep simulating on top of the ragdoll

func stop_ragdoll() -> void:
	if ragdoll == null: return
	ragdoll.physical_bones_stop_simulation()
	ragdoll.active = false
	ragdoll.influence = 0.0
	if anim and anim.current_animation != "": anim.play()

# --------------------------------------------------------------------------- look-at, eyes, sword
func _build_look_at() -> void:
	look_at = LookAtModifier3D.new()
	look_at.name = "HeadLook"
	look_at.bone_name = "Head"
	look_at.forward_axis = SkeletonModifier3D.BONE_AXIS_MINUS_Z if false else SkeletonModifier3D.BONE_AXIS_PLUS_Z
	look_at.use_angle_limitation = true
	look_at.symmetry_limitation = true
	look_at.primary_limit_angle = deg_to_rad(120.0)
	look_at.secondary_limit_angle = deg_to_rad(60.0)
	look_at.duration = 0.35
	look_at.transition_type = Tween.TRANS_SINE
	look_at.ease_type = Tween.EASE_OUT
	look_at.relative = true
	look_at.influence = 0.0
	skeleton.add_child(look_at)
	if look_target: look_at.target_node = look_at.get_path_to(look_target)

func set_look_target(n: Node3D, amount := 0.8) -> void:
	look_target = n
	if look_at:
		look_at.target_node = look_at.get_path_to(n) if n else NodePath("")
		create_tween().tween_property(look_at, "influence", amount if n else 0.0, 0.4)

func _build_eye_glow() -> void:
	for side in ["LeftEye", "RightEye"]:
		var ba := BoneAttachment3D.new(); ba.bone_name = side; ba.name = side + "Glow"
		skeleton.add_child(ba)
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.62, 0.18); l.light_energy = 0.05; l.omni_range = 0.05
		l.position = Vector3(0, 0.02, 0)
		ba.add_child(l)

func _setup_loops() -> void:
	if anim == null: return
	var f := "res://assets/warrior/clips.json"
	if not FileAccess.file_exists(f): return
	clips = JSON.parse_string(FileAccess.get_file_as_string(f))
	for lib_name in anim.get_animation_library_list():
		var lib := anim.get_animation_library(lib_name)
		for a in lib.get_animation_list():
			var an := lib.get_animation(a)
			an.loop_mode = Animation.LOOP_LINEAR if clips.has(a) and clips[a].get("loop", false) else Animation.LOOP_NONE

class_name AvatarRagdoll
extends Node
## Hits and knock-downs of the player's body (WARRIOR REACT, R-WARRIOR-07). An active ragdoll: RigidBody3D bodies
## joined by cone / hinge joints (ragdoll_rig.gd, from the profile's `ragdoll_bodies`) that follow the animated pose
## when they have to, and take over when something hits hard. It replaces keyed hit clips and the old knock-down camera
## effect; CORE hurt (the overlay, heartbeat, control lag...) stays, and the player never dies.
##
## Partial hits (the player's impacted(dv), was_hurt(amount, kind) with where it came from, stumbled, hard landings):
##   the bodies wake up at the animated pose and track it (their velocities steered toward it every tick); the region
##   that was hit (head, upper body, an arm, a leg) goes loose, takes the hit as a velocity kick, swings, and its
##   tracking comes back over ~0.4-1 s, while the pose shown blends from the animation to the physics of that region
##   and back. Stumbles sway the upper body the same way. The rest of the body stays exactly on the animation.
## Knock-downs (a big dv, a big physical hit, a blast, a car, a long fall, the hurt plugin at the top of its range):
##   every body goes physical with the body's velocity and a spin from where the hit came from (a hit high topples
##   the body, a low one sweeps the legs), with a little muscle tone that braces through the fall (toward the fall
##   clip) and fades to a damped, limp body once it is down. The physics player is kept alive but frozen, out of the
##   collision space and movement_locked, and follows the hips (so the world keeps interacting with the body through
##   the ragdoll: blasts, cars, creatures; hurt reaches the player through the bodies' `damageable` meta).
##   While it settles, pose matching (ragdoll_match.gd) picks the get-up clip (get_up_back / get_up_front or their
##   mirrors), the frame to start from (the first 55 % of the clip) and the root yaw that fit the body lying there. A
##   pre-pose then moves the ragdoll physically into that frame (a roll onto the back or front first when it lies on
##   its side, the limbs by their joints), the clip starts at that frame with a short blend (~0.2 s) from the ragdoll's
##   pose; the clip's root motion moves the body (the player follows, no teleport), and control comes back as it stands.
## Views: third person frames the ragdoll (avatar.camera_pivot() asks pivot_override()). First person follows the
##   head with a steadied view, or pulls out to third person for the fall (gameplay/knockdown_camera; reduce motion
##   always pulls out); the held tool is put away while down.
## Cost: idle = nothing in the physics space and the skeleton modifier inactive.
## Collision layer 9 ("ragdoll"): collides with world, vehicles, props, creatures, vegetation; never the player.

const Rig := preload("res://Components/Avatar/ragdoll/ragdoll_rig.gd")
const PoseMod := preload("res://Components/Avatar/ragdoll/ragdoll_pose.gd")
const Clip := preload("res://Components/Avatar/ragdoll/ragdoll_clip.gd")
const RSettings := preload("res://Components/Avatar/ragdoll/ragdoll_settings.gd")
const Match := preload("res://Components/Avatar/ragdoll/ragdoll_match.gd")
const UP := Vector3.UP
const GROUND_MASK := 1 | 4 | 8 | 64

enum State { IDLE, PENDING, PARTIAL, FALL, GATHER, GETUP, RELEASE }

signal knocked_down(dv : Vector3)
signal got_up()
signal hit_reaction(region : StringName, strength : float)

## Weighted dv (m/s: horizontal + 0.6 x vertical) that knocks the body down (x the gameplay/knockdowns scale)
var knock_dv := 6.5
## Hurt points in one physical hit that knock it down
var knock_hurt := 42.0
## Landing speed (m/s) that knocks it down
var knock_fall := 15.5
## Smallest dv that rocks the body
var partial_dv := 0.9
var getup_speed := 1.3
## The blend from the ragdoll's pose into the get-up clip (s, a little longer for a bone further off)
var blend_time := 0.18
## Down for at least this long (s), settled or not, and at most fall_max (fall_hard_max while it still slides)
var down_min := 1.1
var fall_max := 4.0
var fall_hard_max := 9.0
## After getting up, no new knock-down for this long (s)
var knock_cooldown := 1.2

var av : Avatar
var player : RigidBody3D
var rig : Rig
var mod : SkeletonModifier3D
var state := State.IDLE
## Measurements for the harness (reset by begin_stats())
var stats := {}
var dbg_no_track := false
var dbg_no_tone := false
var dbg_no_limit := false
var dbg_print := false

var _n := 0
var _cur : Array[Transform3D] = []
var _prev : Array[Transform3D] = []
var _anim : Array[Transform3D] = [] # animated target per body, in the avatar root's space
var _anim_prev : Array[Transform3D] = []
var _anim_w : Array[Transform3D] = [] # the same in world space (this frame)
var _anim_dt := 1.0 / 60.0
var _loose := PackedFloat32Array()
var _hold := PackedFloat32Array()
var _rec := PackedFloat32Array()
var _disp := PackedFloat32Array()
var _kicks : Array = [] # [body index, dv] applied at activation
var _pending_mode := State.IDLE
var _knock := {} # the knock-down being started: dir, spin, hit_h, dv
var _t := 0.0 # time in the current state
var _now := 0.0
var _cool := 0.0
var _settle_t := 0.0
var _grounded_t := 0.0
var _hold_pose := false
var _hold_rel : Array[Quaternion] = []
var _gather_rel : Array[Quaternion] = []
var _tone_targets : Array[Quaternion] = []
var _tone_scale := PackedFloat32Array()
var _gather_tgt : Array[Transform3D] = [] # the matched frame per body (world, out of the ground), what the pre-pose steers to
var _gather_raw : Array[Transform3D] = [] # the same as the clip has it (the joints' relative poses)
var _g_start : Array[Transform3D] = [] # the bodies where the pre-pose started (the settled pose)
var _tw0 := PackedFloat32Array() # each joint's twist at the start of the pre-pose and in the matched frame (rad)
var _tw1 := PackedFloat32Array()
var _pre_T := 0.6 # how long the pre-pose's reference takes (s)
var _pre_best := INF # the pre-pose's smallest joint error since the reference got there (deg)
var _js : Array = [] # per body: its joint's way through the pre-pose (_joint_path)
var _arc := PackedFloat32Array() # per body: how high a limb is lifted on its way (m)
var _trap_lift := 0.0
var _fit_pos := Vector3.ZERO # the avatar root that lines the clip's first frame up with the body (the gather's goal)
var _fit_cost := 0.0
var _rig_bone := {} # skeleton bone index -> true for the rig's bones
var _pend := {}
var _pend_t := -1.0
var _clips := {}
var _clip : Clip
var _clip_name : StringName
var _clip_t0 := 0.0 # where the get-up clip starts (s: the pose-matched frame)
var _match : Match
var _gu_t := 0.0
var _gu_real := 0.0
var _gu_frames := 0
var _rm_t := 0.0
var _release_at := 0.0
var _fade := 0.0
var _snap : Array[Transform3D] = []
var _blend_T := PackedFloat32Array()
var _snap_pending := false
var _root_pos := Vector3.ZERO
var _root_yaw := 0.0
var _skel_in_av := Transform3D()
var _final := {} # bone name -> world Transform3D of the pose shown (after this modifier)
var _pivot := Vector3.ZERO
var _pivot_on := false
var _head_w := Transform3D()
var _saved := {}
var _frozen := false
var _view_owned := false
var _view_q := Quaternion.IDENTITY
var _view_blend := 0.0
var _view_eye := Vector3.ZERO
var _eye_fade := 0.0 # after the get-up: the eye glides from the head back to the body's eye point
var _eye_last := Vector3.ZERO
var _pulled_out := false
var _pull_from : StringName = &"first"
var _tools_hidden := false
var _prev_facing : StringName = &"move"
var _ray := PhysicsRayQueryParameters3D.new()
var _last_player_pos := Vector3.ZERO
var _b_hips := 0
var _b_head := 0
var _eye_off := Vector3(0.0, 0.07, 0.09)


## Builds the ragdoll for `avatar` and hooks it up (avatar.ragdoll = it). Called by the hurt plugin once the avatar exists.
static func attach(avatar : Avatar) -> AvatarRagdoll:
	var rd := AvatarRagdoll.new()
	if not rd.setup_on(avatar):
		rd.free()
		return null
	return rd


## Instance form of attach() (for callers that load the script by path): false = the avatar has no ragdoll.
func setup_on(avatar : Node) -> bool:
	var a := avatar as Avatar
	if a == null or a.profile == null or a.profile.ragdoll_bodies.is_empty() or not a.is_inside_tree():
		return false
	name = "Ragdoll"
	av = a
	a.add_child(self)
	return true


func _ready() -> void:
	RSettings.register()
	process_priority = -5 # before the player's _process writes the eye from eye_offset
	process_physics_priority = -5 # before the avatar samples the player's position
	player = av.player as RigidBody3D
	var holder := Node.new()
	holder.name = "Bodies"
	add_child(holder)
	rig = Rig.new()
	rig.build(av, holder)
	_n = rig.bodies.size()
	for b in rig.bodies:
		b.rb.set_meta(&"damageable", self)
		b.rb.set_meta(&"ragdoll_of", player)
		# The player's capsule (on the world layer) and the ragdoll never touch
		if player:
			b.rb.add_collision_exception_with(player)
	for a in [_cur, _prev, _anim, _anim_prev, _anim_w, _snap, _gather_tgt, _gather_raw, _g_start]:
		a.resize(_n)
	_hold_rel.resize(_n)
	_gather_rel.resize(_n)
	_tone_targets.resize(_n)
	_tone_scale.resize(_n)
	_loose.resize(_n)
	_hold.resize(_n)
	_rec.resize(_n)
	_disp.resize(_n)
	_blend_T.resize(_n)
	_tw0.resize(_n)
	_arc.resize(_n)
	_js.resize(_n)
	_tw1.resize(_n)
	_blend_T.fill(blend_time)
	_b_hips = (rig.by_name[&"Hips"] as Rig.Body).index
	_b_head = (rig.by_name[&"Head"] as Rig.Body).index
	var eyes : Array = av.profile.sockets.get("eyes", [])
	if eyes.size() == 2 and eyes[0] == "Head":
		_eye_off = (eyes[1] as Transform3D).origin
	_match = Match.new()
	_match.setup(self)
	mod = PoseMod.new()
	mod.name = "RagdollPose"
	mod.rd = self
	mod.active = false
	av.skeleton.add_child(mod)
	# Right after AvatarPose, before the hair / cloth simulators
	av.skeleton.move_child(mod, av.pose.get_index() + 1)
	_ray.collision_mask = GROUND_MASK
	_ray.hit_back_faces = false
	var ex : Array[RID] = []
	if player:
		ex.append(player.get_rid())
	for b in rig.bodies:
		ex.append(b.rid)
	_ray.exclude = ex
	if player and player.has_method(&"add_query_exclude"):
		var mine : Array[RID] = []
		for b in rig.bodies:
			mine.append(b.rid)
		player.call(&"add_query_exclude", mine)
	av.ragdoll = self
	if player:
		for s in [[&"impacted", _on_impacted], [&"was_hurt", _on_hurt], [&"stumbled", _on_stumbled],
				[&"landed", _on_landed], [&"just_deactivated", _on_deactivated]]:
			if player.has_signal(s[0]):
				player.connect(s[0], s[1])
	begin_stats()


func _exit_tree() -> void:
	# Teardown (the scene or the body going away): only let go of the player; the camera, the tool manager and the
	# avatar may already be leaving the tree too
	if _frozen and is_instance_valid(player) and player.is_inside_tree() and not player.is_queued_for_deletion():
		_give_player_back(Vector3.ZERO)
	_frozen = false
	if _view_owned and is_instance_valid(player) and player.is_inside_tree():
		player.release_view(self)
		player.eye_offset = Vector3.ZERO
	_view_owned = false
	_tools_hidden = false
	state = State.IDLE
	if av and av.ragdoll == self:
		av.ragdoll = null


# --- API --------------------------------------------------------------------------------------------------------------

## True from the moment a knock-down starts until control is back.
func is_down() -> bool:
	return state in [State.FALL, State.GATHER, State.GETUP, State.RELEASE] or (state == State.PENDING and _pending_mode == State.FALL)


## True while this owns the first-person view (the hurt plugin leaves eye_offset alone then).
func owns_view() -> bool:
	return _view_owned or _eye_fade > 0.0 or (is_down() and not _pulled_out)


## The third-person camera's pivot while down (null otherwise): avatar.camera_pivot() returns it.
func pivot_override() -> Variant:
	return _pivot if _pivot_on else null


## The head's centre while down (null otherwise): avatar.head_position() returns it.
func head_override() -> Variant:
	if not _pivot_on:
		return null
	return _head_w * Vector3(0.0, 0.09, 0.0)


## A hit on the body: `point` world (or INF), `dir` the push (world), `strength` m/s. Knocks down when it's big.
func hit(point : Vector3, dir : Vector3, strength : float, kind : StringName = &"hit") -> void:
	_queue({dv = dir.normalized() * strength, from = point - dir.normalized() * 0.5 if point != Vector3.INF else Vector3.INF,
		kind = kind, hurt = 0.0})


## Knocks the body down now (tests, scripted moments, the hurt plugin). dir: the push (world, any length = m/s).
func knock_down(dir : Vector3 = Vector3.ZERO, hit_height := -1.0) -> bool:
	if not _can_knock():
		return false
	_begin_knock(dir, hit_height, dir.length())
	return true


## The hurt plugin's knock-down (hurt at the top of its range): the body gives way, away from the last hit.
func knock_down_from_hurt(from : Vector3) -> bool:
	if not _can_knock():
		return false
	var d := Vector3.ZERO
	if from != Vector3.INF:
		d = (player.global_position - from)
		d.y = 0.0
	if d.length() < 0.01:
		d = -_facing_fwd()
	_begin_knock(d.normalized() * 1.6, 1.3, 1.6)
	return true


## Blasts, sword sweeps and other damage that finds the ragdoll's bodies while the body is down.
func take_damage(amount : float, point : Vector3, _source : Variant = null, kind : StringName = &"hit") -> void:
	if not is_down() or not is_instance_valid(player) or not player.has_method(&"hurt"):
		return
	player.call(&"hurt", amount, point, kind)


func begin_stats() -> void:
	stats = {knocks = 0, partials = 0, max_sep = 0.0, max_speed = 0.0, spikes = 0, max_dv_tick = 0.0,
		settle_t = -1.0, down_t = -1.0, getup_t = -1.0, control_t = -1.0, clip = &"", pose_err_max = -1.0,
		pose_err_mean = -1.0, pose_err_bone = &"", fit_err = -1.0, partial_peak = 0.0, partial_rec = -1.0,
		partial_region = &"", root_gap = 0.0}


# --- triggers ------------------------------------------------------------------------------------------------------------

func _on_impacted(dv : Vector3) -> void:
	# The player's own recoil (WeaponFX.recoil marks it) is not a blow
	if player.has_meta(&"self_push_msec") and Time.get_ticks_msec() - int(player.get_meta(&"self_push_msec")) < 150 			and dv.length() < knock_dv:
		return
	# Running (or jumping) into the ground, a slope or a wall stops the body: the change opposes its own motion and
	# is no bigger than it. That's the player's own bump (the player's stumble handles it), not a blow.
	var v_prev : Vector3 = player.linear_velocity - dv
	var bump := v_prev.length() > 0.5 and dv.dot(v_prev) < -0.6 * dv.length() * v_prev.length() 		and dv.length() <= v_prev.length() * 1.15
	_queue({dv = dv * (0.35 if bump else 1.0), bump = bump, cap = _contact_cap(dv)})


## How hard a contact can knock the body down (m/s of dv, INF = no limit): when the change came through a contact
## (not a script's impulse: blasts, bites, grabs), only what the other body brings toward the player counts, i.e. its
## own speed along the contact normal. A car or a rock sliding past the shoulder (a glancing bump) pushes along the
## normal with a small part of its speed and drags the rest by friction: that rocks the body, it doesn't floor it.
## Static things (walls, pillars) bring nothing (running into them is the player's own bump).
func _contact_cap(dv : Vector3) -> float:
	if not is_instance_valid(player) or dv.length() < 0.01:
		return INF
	var st := PhysicsServer3D.body_get_direct_state(player.get_rid())
	if st == null or st.get_contact_count() == 0:
		return INF
	var any := false
	var blow := 0.0
	var dn := dv.normalized()
	for i in st.get_contact_count():
		var n := st.get_contact_local_normal(i)
		if n.dot(dn) < 0.0:
			n = -n # toward where the player was pushed
		if n.y > 0.7:
			continue # the ground under the feet
		any = true
		var vc := st.get_contact_collider_velocity_at_position(i)
		blow = maxf(blow, vc.dot(n))
	if not any:
		return INF
	return blow * 1.3 + 1.0


func _on_hurt(amount : float, kind : StringName) -> void:
	var from : Vector3 = player.last_hurt_from if "last_hurt_from" in player else Vector3.INF
	_queue({hurt = amount, kind = kind, from = from})


func _on_stumbled(strength : float, dir : Vector3) -> void:
	_queue({stumble = strength, sdir = dir})


func _on_landed(speed : float) -> void:
	_queue({land = speed})


func _on_deactivated() -> void:
	if state != State.IDLE:
		_abort()


## Signals of one hit arrive over a tick or two (was_hurt now, impacted at the next physics step): collect them.
func _queue(d : Dictionary) -> void:
	if not is_instance_valid(player) or not bool(player.get(&"active")):
		return
	if _frozen:
		return # our own motion while down
	for k in d:
		match k:
			"dv":
				_pend["dv"] = (_pend.get("dv", Vector3.ZERO) as Vector3) + (d[k] as Vector3)
			"hurt":
				_pend["hurt"] = float(_pend.get("hurt", 0.0)) + float(d[k])
			"stumble", "land", "cap":
				_pend[k] = maxf(float(_pend.get(k, 0.0)), float(d[k]))
			_:
				if d[k] is Vector3 and d[k] == Vector3.INF and _pend.has(k):
					continue
				_pend[k] = d[k]
	if _pend_t < 0.0:
		_pend_t = 0.03


func _decide() -> void:
	var p := _pend
	_pend = {}
	_pend_t = -1.0
	if not is_instance_valid(player) or not bool(player.get(&"active")) or not av.visible:
		return
	var dv : Vector3 = p.get("dv", Vector3.ZERO)
	var hurt : float = p.get("hurt", 0.0)
	var kind : StringName = p.get("kind", &"")
	var from : Vector3 = p.get("from", Vector3.INF)
	var land : float = p.get("land", 0.0)
	var stumble : float = p.get("stumble", 0.0)
	var physical := kind != &"fire" and kind != &"burn" and kind != &"leg"
	var dvh := Vector3(dv.x, 0.0, dv.z)
	var eff := dvh.length() + 0.6 * absf(dv.y)
	var k := RSettings.knock_scale()
	var bump : bool = p.get("bump", false) and hurt <= 0.0
	# A contact knocks down by what the other body brought, not by a graze (see _contact_cap)
	var cap : float = p.get("cap", INF)
	var knock := minf(eff, cap) >= knock_dv * k and not bump
	knock = knock or (physical and hurt >= knock_hurt * k and eff >= 1.0)
	knock = knock or (kind == &"blast" and hurt >= 25.0 * k and eff >= 3.0)
	knock = knock or land >= knock_fall * k
	var hit_h := -1.0
	if from != Vector3.INF:
		hit_h = clampf(from.y - _feet_y(), 0.1, 1.8)
	if knock and _can_knock():
		var dir := dvh if dvh.length() > 0.3 else Vector3.ZERO
		if dir == Vector3.ZERO and from != Vector3.INF:
			dir = player.global_position - from
			dir.y = 0.0
			dir = dir.normalized() * maxf(eff, 2.0)
		if dir == Vector3.ZERO:
			# A landing (or a vertical blow): crumple, forward if moving
			var hv : Vector3 = player.linear_velocity
			hv.y = 0.0
			dir = hv.normalized() * 1.5 if hv.length() > 0.5 else _facing_fwd() * 1.2
		_begin_knock(dir, hit_h, maxf(eff, land * 0.3))
		return
	if state in [State.FALL, State.GATHER, State.GETUP, State.RELEASE]:
		return
	# Partial reactions
	if not physical and eff < partial_dv:
		return
	var dir2 := dv.normalized() if dv.length() > 0.05 else Vector3.ZERO
	if from != Vector3.INF:
		var away := player.global_position - from
		away.y *= 0.3
		if dir2 == Vector3.ZERO or dvh.length() < 1.5:
			dir2 = away.normalized()
	var strength := clampf(0.6 + eff * 0.8 + hurt / 22.0, 0.0, 6.0)
	if stumble > 0.0:
		var sd : Vector3 = p.get("sdir", Vector3.ZERO)
		if dir2 == Vector3.ZERO:
			dir2 = sd
		strength = maxf(strength, 1.0 + stumble * 3.0)
		_react(_chest_w() + dir2 * -0.2, dir2, strength, &"torso", 0.8 + stumble * 0.4)
		return
	if land > 6.5 and eff < partial_dv * 2.0:
		# Hard landing: the arms and head drop, the upper body folds a little
		var s := clampf((land - 6.5) / 6.0, 0.2, 1.0)
		_react(_chest_w(), Vector3.DOWN + _facing_fwd() * 0.3, 1.2 + 2.5 * s, &"torso", 0.5 + 0.4 * s)
		return
	if eff < partial_dv and hurt < 4.0:
		return
	if dir2 == Vector3.ZERO:
		return
	# Where it hit: from the source's height and side, else the chest
	var hp := _chest_w()
	if hit_h > 0.0:
		var side := -dir2
		side.y = 0.0
		hp = Vector3(hp.x, _feet_y() + hit_h, hp.z) + side.normalized() * 0.15
	_react(hp, dir2, strength, &"", clampf(0.45 + strength * 0.15, 0.45, 1.0))


func _can_knock() -> bool:
	if GameState.debug_freeroam:
		return false
	if RSettings.knock_scale() == INF or not is_instance_valid(player) or rig == null:
		return false
	if state in [State.FALL, State.GATHER] or _pending_mode == State.FALL:
		return false
	if _cool > 0.0 or not bool(player.get(&"active")) or not av.visible:
		return false
	if player.has_method(&"is_swimming") and player.is_swimming():
		return false
	if player.has_method(&"has_view_owner") and player.has_view_owner() and not _view_owned:
		return false # gliding
	# A movement handler (ladder, grapple swing) owns the body
	if player.has_method(&"is_active_mover") and not player.is_active_mover() and not _frozen:
		return false
	return true


# --- partial reactions ----------------------------------------------------------------------------------------------------

const REGIONS := {
	&"head": {&"Head": 1.0, &"Neck": 1.0, &"UpperChest": 0.35},
	&"torso": {&"Spine": 0.9, &"Chest": 1.0, &"UpperChest": 1.0, &"Neck": 0.9, &"Head": 0.9,
		&"LeftUpperArm": 0.7, &"LeftLowerArm": 0.75, &"LeftHand": 0.8, &"RightUpperArm": 0.7, &"RightLowerArm": 0.75,
		&"RightHand": 0.8},
	&"arm_l": {&"LeftUpperArm": 1.0, &"LeftLowerArm": 1.0, &"LeftHand": 1.0, &"UpperChest": 0.3, &"Head": 0.3},
	&"arm_r": {&"RightUpperArm": 1.0, &"RightLowerArm": 1.0, &"RightHand": 1.0, &"UpperChest": 0.3, &"Head": 0.3},
	&"leg_l": {&"LeftUpperLeg": 1.0, &"LeftLowerLeg": 1.0, &"LeftFoot": 1.0, &"Spine": 0.3, &"UpperChest": 0.3},
	&"leg_r": {&"RightUpperLeg": 1.0, &"RightLowerLeg": 1.0, &"RightFoot": 1.0, &"Spine": 0.3, &"UpperChest": 0.3},
}


## A region goes loose and takes the kick. region &"" = the body nearest to `point`.
func _react(point : Vector3, dir : Vector3, strength : float, region : StringName, amount : float) -> void:
	var hit_i := -1
	if region == &"":
		var best := INF
		for b in rig.bodies:
			var c := _body_now(b.index).origin
			var d := c.distance_squared_to(point)
			if d < best:
				best = d
				hit_i = b.index
		region = rig.bodies[hit_i].region
		if region == &"hips":
			region = &"torso"
	var held0 := _held_arms()
	if (region == &"arm_l" and held0[0]) or (region == &"arm_r" and held0[1]):
		region = &"torso" # the arm holds on: the shoulder and the upper body take it
		hit_i = -1
		amount *= 0.7
	var shares : Dictionary = REGIONS.get(region, REGIONS[&"torso"])
	if hit_i < 0:
		var nm : StringName = &"UpperChest" if region in [&"torso", &"head"] else shares.keys()[1]
		hit_i = (rig.by_name[nm] as Rig.Body).index
	var dirn := dir.normalized()
	var held := _held_arms()
	for nm in shares:
		var b : Rig.Body = rig.by_name.get(nm)
		if b == null:
			continue
		# An arm holding something (hand IK: a tool, a seat grip) stays on its IK; the rest of the body reacts
		if (b.region == &"arm_l" and held[0]) or (b.region == &"arm_r" and held[1]):
			continue
		var s : float = shares[nm]
		var i := b.index
		_loose[i] = maxf(_loose[i], clampf(amount * s, 0.0, 1.0))
		_hold[i] = maxf(_hold[i], 0.1 + 0.08 * amount)
		_rec[i] = 1.0 / (0.45 + 0.5 * amount)
		var k := strength * (1.0 if i == hit_i else 0.45 * s)
		_kicks.append([i, dirn * k])
	stats["partials"] = int(stats.get("partials", 0)) + 1
	stats["partial_region"] = region
	stats["partial_start"] = _now
	stats["partial_peak"] = 0.0
	stats["partial_rec"] = -1.0
	hit_reaction.emit(region, strength)
	if state == State.IDLE:
		_request(State.PARTIAL)
	elif state == State.PARTIAL:
		for bb in rig.bodies:
			if _loose[bb.index] > 0.0 and bb.rb.freeze:
				rig.set_kinematic(bb, false)
				rig.set_colliding(bb, true)
				PhysicsServer3D.body_set_state(bb.rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, player.linear_velocity)
		_apply_kicks()


## Which arms are on hand IK (holding a tool or a grip): [left, right].
func _held_arms() -> Array:
	var out := [false, false]
	var arms : Variant = av.pose.get(&"_arms") if av.pose else null
	if arms is Array and (arms as Array).size() == 2:
		for i in 2:
			var a : Variant = arms[i]
			if a is Dictionary:
				out[i] = float((a as Dictionary).get("w", 0.0)) > 0.5
	return out


func _apply_kicks() -> void:
	for kk in _kicks:
		var b : Rig.Body = rig.bodies[kk[0]]
		var v : Vector3 = PhysicsServer3D.body_get_state(b.rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
		PhysicsServer3D.body_set_state(b.rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, v + kk[1])
	_kicks.clear()


# --- knock-downs ------------------------------------------------------------------------------------------------------

func _begin_knock(dv : Vector3, hit_h : float, eff : float) -> void:
	var d := Vector3(dv.x, 0.0, dv.z)
	_knock = {dir = d.normalized() if d.length() > 0.01 else Vector3.ZERO, mag = d.length(), hit_h = hit_h, eff = eff}
	stats["knocks"] = int(stats.get("knocks", 0)) + 1
	stats["knock_start"] = _now
	for k in ["settle_t", "down_t", "getup_t", "control_t", "pose_err_max", "pose_err_mean", "fit_err"]:
		stats[k] = -1.0
	stats["max_sep"] = 0.0
	stats["max_speed"] = 0.0
	stats["spikes"] = 0
	stats["max_dv_tick"] = 0.0
	stats["root_gap"] = 0.0
	if state in [State.PARTIAL]:
		_start_fall()
	else:
		if state in [State.GETUP, State.RELEASE]:
			_end_getup_display()
		_request(State.FALL)
	knocked_down.emit(dv)
	Core.discover.call_deferred(&"hard_knocks")


func _request(mode : State) -> void:
	_pending_mode = mode
	# Keep the native capsule, or the existing bounded get-up, until a fresh evaluated pose is ready.
	if not (mode == State.FALL and _frozen and state in [State.GETUP, State.RELEASE]):
		state = State.PENDING
	mod.active = true


## Called by the modifier with a fresh capture of the animated pose.
func _activate() -> void:
	var lin : Array[Vector3] = []
	var ang : Array[Vector3] = []
	lin.resize(_n)
	ang.resize(_n)
	var v0 : Vector3 = player.linear_velocity if is_instance_valid(player) else Vector3.ZERO
	if _saved.has("v"):
		v0 = _saved["v"]
	for i in _n:
		lin[i] = v0
		ang[i] = Vector3.ZERO
		_cur[i] = _anim_w[i]
		_prev[i] = _anim_w[i]
	rig.enable(_anim_w, lin, ang)
	if _pending_mode == State.PARTIAL:
		state = State.PARTIAL
		_t = 0.0
		# A shoved body doesn't turn to face where it is thrown: hold the facing through the reaction
		_prev_facing = av.facing_mode
		av.set_facing_mode(&"locked")
		av.set_facing_yaw(av.facing_yaw)
		for b in rig.bodies:
			var loose := _loose[b.index] > 0.0
			rig.set_colliding(b, loose)
			rig.set_kinematic(b, not loose)
		_apply_kicks()
	else:
		_start_fall()
	_pending_mode = State.IDLE


func _start_fall() -> void:
	state = State.FALL
	_t = 0.0
	_settle_t = 0.0
	_grounded_t = 0.0
	_hold_pose = false
	_kicks.clear()
	for i in _n:
		_loose[i] = 0.0
		_disp[i] = 1.0
	# Spin: a high hit topples the body over its feet, a low one (a bumper) sweeps the legs from under it
	var dir : Vector3 = _knock.get("dir", Vector3.ZERO)
	var mag : float = _knock.get("mag", 0.0)
	var hit_h : float = _knock.get("hit_h", -1.0)
	var com := Vector3.ZERO
	for b in rig.bodies:
		com += _cur[b.index].origin * b.mass
	com /= rig.total_mass
	var w := Vector3.ZERO
	if dir != Vector3.ZERO:
		var sgn := -1.0 if (hit_h > 0.0 and hit_h < 0.75) else 1.0
		w = UP.cross(dir) * clampf(mag * 0.33, 0.9, 4.0) * sgn
		w += UP * randf_range(-0.8, 0.8) # a little twist
	var v_base : Vector3 = _saved.get("v", player.linear_velocity)
	_knock["v0"] = v_base.length()
	for b in rig.bodies:
		rig.set_colliding(b, true)
		var v : Vector3 = PhysicsServer3D.body_get_state(b.rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
		if b.rb.freeze:
			rig.set_kinematic(b, false)
			v = v_base
		v += w.cross(_cur[b.index].origin - com)
		PhysicsServer3D.body_set_state(b.rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, v)
		PhysicsServer3D.body_set_state(b.rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, w)
		b.rb.continuous_cd = true # (cheap for 18 bodies over a few seconds; no limb through the ground on a hard landing)
		b.rb.angular_damp = 0.8
	# All original bodies now own native collision and motion. Transfer the capsule only after that setup,
	# in this same callback; waiting for the skeleton must never leave both representations inactive.
	_take_player()
	# The animated pose may have its feet in the ground (a hard landing squats through it): lift the whole body out
	var lift := minf(_deepest_capsule(), 0.2)
	if lift > 0.005:
		for bb in rig.bodies:
			var t := _cur[bb.index]
			t.origin += UP * lift
			_cur[bb.index] = t
			_prev[bb.index] = t
			bb.rb.global_transform = t
			PhysicsServer3D.body_set_state(bb.rid, PhysicsServer3D.BODY_STATE_TRANSFORM, t)
	# Brace through the fall: the fall loop is what the muscle tone reaches for
	var again := av.has_pose_override()
	av.set_pose_override(self)
	av.play_action(&"fall", 0.15, 1.0, &"full")
	if not again:
		_prev_facing = av.facing_mode
		_root_yaw = av.facing_yaw
		_pivot = av.camera_pivot()
	av.set_facing_mode(&"locked")
	_pivot_on = true
	# (runs inside the skeleton's update: node changes wait for the end of the frame)
	_setup_view.call_deferred()
	_hide_tools.call_deferred(true)


## Freezes the physics player: out of the collision space, movement locked; it follows the ragdoll from now on.
func _take_player() -> void:
	if _frozen or not is_instance_valid(player):
		return
	_saved = {layer = player.collision_layer, mask = player.collision_mask, freeze = player.freeze,
		freeze_mode = player.freeze_mode, locked = player.movement_locked, v = player.linear_velocity}
	player.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	player.freeze = true
	player.collision_layer = 0
	player.collision_mask = 0
	player.movement_locked = true
	_frozen = true
	_last_player_pos = player.global_position


func _give_player_back(v : Vector3) -> void:
	if not _frozen or not is_instance_valid(player):
		_frozen = false
		return
	_frozen = false
	var pos := _free_spot(player.global_position)
	player.global_position = pos
	player.collision_layer = _saved.get("layer", 2)
	player.collision_mask = _saved.get("mask", 1)
	player.freeze = _saved.get("freeze", false)
	player.freeze_mode = _saved.get("freeze_mode", RigidBody3D.FREEZE_MODE_STATIC)
	player.linear_velocity = v
	player.movement_locked = _saved.get("locked", false)
	if player.has_method(&"reset_motion_tracking"):
		player.call(&"reset_motion_tracking")
	if player.has_method(&"reset_fall"):
		player.call(&"reset_fall")
	_saved = {}


## Where the capsule fits near `pos` (next to a wall the get-up may end with it poking into it).
func _free_spot(pos : Vector3) -> Vector3:
	var col := player.get_node_or_null(^"Collision") as CollisionShape3D
	if col == null or col.shape == null:
		return pos
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = col.shape
	q.collision_mask = int(_saved.get("mask", 1)) & (1 | 4 | 8)
	q.exclude = _ray.exclude
	var space := player.get_world_3d().direct_space_state
	var offs : Array[Vector3] = [Vector3.ZERO]
	for r in [0.12, 0.25, 0.4, 0.6]:
		for a in 8:
			offs.append(Vector3(cos(a * TAU / 8.0), 0.0, sin(a * TAU / 8.0)) * r)
	for o in offs:
		q.transform = Transform3D(Basis(), pos + o) * col.transform
		if space.intersect_shape(q, 1).is_empty():
			return pos + o
	return pos


# --- per tick -------------------------------------------------------------------------------------------------------------

func _physics_process(dt : float) -> void:
	_now += dt
	_cool = maxf(_cool - dt, 0.0)
	if _pend_t >= 0.0:
		_pend_t -= dt
		if _pend_t < 0.0:
			_decide()
	if state == State.IDLE or state == State.PENDING:
		return
	_t += dt
	if rig.enabled:
		for i in _n:
			_prev[i] = _cur[i]
			_cur[i] = rig.bodies[i].rb.global_transform
	match state:
		State.PARTIAL:
			_tick_partial(dt)
		State.FALL:
			_tick_fall(dt)
		State.GATHER:
			_tick_gather(dt)
		State.GETUP, State.RELEASE:
			_tick_getup(dt)


func _tick_partial(dt : float) -> void:
	var root := _root_now()
	var pv : Vector3 = player.linear_velocity
	var any := false
	var peak := 0.0
	for b in rig.bodies:
		var i := b.index
		if _hold[i] > 0.0:
			_hold[i] -= dt
		elif _loose[i] > 0.0:
			_loose[i] = maxf(_loose[i] - dt * _rec[i], 0.0)
		var target := root * _anim[i]
		# The rest of the body is kinematic on the animation: as heavy as the world for the joints, so a loose arm
		# swings from a shoulder that stays where the animation has it
		if _loose[i] <= 0.0:
			if not b.rb.freeze:
				rig.set_colliding(b, false)
				rig.set_kinematic(b, true)
			b.rb.global_transform = target
			_disp[i] = move_toward(_disp[i], 0.0, dt * 7.0)
			if _disp[i] > 0.0:
				any = true
			continue
		elif b.rb.freeze:
			rig.set_kinematic(b, false)
			rig.set_colliding(b, true)
		var tv := pv + root.basis * ((_anim[i].origin - _anim_prev[i].origin) / _anim_dt)
		var tw := root.basis * _rotvec(_anim[i].basis.get_rotation_quaternion() * _anim_prev[i].basis.get_rotation_quaternion().inverse()) / _anim_dt
		# Looseness -> how much of the tracking velocity is taken per tick (time constant 0 .. 0.6 s)
		var l := _loose[i]
		var s := 1.0 if l <= 0.0 else 1.0 - exp(-dt / (0.6 * pow(l, 1.5) + 1e-4))
		if not dbg_no_track:
			_track(b, target, tv, tw, s)
		_disp[i] = move_toward(_disp[i], minf(1.0, l * 5.0), dt * 7.0)
		if _disp[i] > 0.0 or l > 0.0:
			any = true
		if l > 0.0 or _disp[i] > 0.0:
			var dev := rad_to_deg((_cur[i].basis.get_rotation_quaternion() * target.basis.get_rotation_quaternion().inverse()).get_angle())
			peak = maxf(peak, absf(wrapf(dev, -180.0, 180.0)))
	stats["partial_peak"] = maxf(float(stats.get("partial_peak", 0.0)), peak)
	if not any:
		stats["partial_rec"] = _now - float(stats.get("partial_start", _now))
		_to_idle()


## Steers a body's velocities toward a world target (s = share per tick, 1 = on it).
func _track(b : Rig.Body, target : Transform3D, tv : Vector3, tw : Vector3, s : float) -> void:
	var x := _cur[b.index]
	var v : Vector3 = PhysicsServer3D.body_get_state(b.rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
	var w : Vector3 = PhysicsServer3D.body_get_state(b.rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
	var vt := tv + (target.origin - x.origin) * 40.0
	var err := _rotvec(target.basis.get_rotation_quaternion() * x.basis.get_rotation_quaternion().inverse())
	var wt := tw + err * 40.0
	PhysicsServer3D.body_set_state(b.rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, v.lerp(vt, s))
	PhysicsServer3D.body_set_state(b.rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, w.lerp(wt.limit_length(40.0), s))


func _tick_fall(dt : float) -> void:
	# Muscle tone: bracing toward the fall clip at first, then a damped, limp body once it lies
	var hips := _cur[_b_hips].origin
	var gy := _ground_y(hips, hips.y - 3.0)
	var low := hips.y - gy < 0.5
	_grounded_t = _grounded_t + dt if low else 0.0
	if not _hold_pose and _grounded_t > 0.25 and _t > 0.5:
		_hold_pose = true
	var hz := lerpf(3.0, 1.4, clampf(_t / 0.9, 0.0, 1.0))
	if _hold_pose:
		hz = 0.9
		for b in rig.bodies:
			if b.parent >= 0:
				_hold_rel[b.index] = _cur[b.parent].basis.get_rotation_quaternion().inverse() * _cur[b.index].basis.get_rotation_quaternion()
	if not dbg_no_tone:
		_tone(dt, hz, 0.9, 0 if not _hold_pose else 1)
	if not dbg_no_limit:
		_limit_speeds()
	_depenetrate()
	_follow_ragdoll()
	var vmax := _measure(dt)
	# Settled?
	var still := vmax < 0.35
	_settle_t = _settle_t + dt if still else 0.0
	# The pose-matching database fills in during the fall (a little per tick); the matching pass runs a few
	# candidates per tick while the body lies still (moving again restarts it)
	if _match.build_step():
		if still and _settle_t > 0.08:
			if not _match.pass_active():
				_match.begin_pass()
			elif not _match.pass_done():
				_match.pass_step()
		elif _match.pass_active():
			_match.cancel_pass()
	var done := _t >= down_min and _settle_t > 0.3
	done = done or (_t >= fall_max and vmax < 1.5)
	done = done or _t >= fall_hard_max
	if hips.y < -900.0 or is_nan(hips.y):
		_abort()
		return
	if done:
		stats["settle_t"] = _t
		stats["down_t"] = _now - float(stats.get("knock_start", _now))
		_start_gather()


## Joint-space PD: every joint pulls its child toward a target relative rotation, as equal and opposite torque
## impulses (momentum is kept: the body can't lift itself). mode 0: the animated pose; 1: hold the current pose (pure
## damping); 2: the get-up clip's first frame.
func _tone(dt : float, hz : float, zeta : float, mode : int) -> void:
	for b in rig.bodies:
		if b.parent < 0:
			continue
		var p := rig.bodies[b.parent]
		match mode:
			0:
				_tone_targets[b.index] = _anim[p.index].basis.get_rotation_quaternion().inverse() * _anim[b.index].basis.get_rotation_quaternion()
			1:
				_tone_targets[b.index] = _hold_rel[b.index]
			_:
				_tone_targets[b.index] = _gather_rel[b.index]
		_tone_scale[b.index] = .25 if mode == 2 and b.region == &"head" else 1.0
	rig.apply_joint_tone(_cur, _tone_targets, dt, hz, zeta, _tone_scale)


## Safety net against a crushed body gaining energy (squeezed between a moving machine and a wall): no body may go
## much faster than the whole body is going.
func _limit_speeds() -> void:
	var vh : Vector3 = PhysicsServer3D.body_get_state(rig.bodies[_b_hips].rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
	var cap := maxf(vh.length() * 1.6 + 8.0, float(_knock.get("v0", 0.0)) + 8.0)
	for b in rig.bodies:
		var v : Vector3 = PhysicsServer3D.body_get_state(b.rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
		if v.length() > cap:
			PhysicsServer3D.body_set_state(b.rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, v.limit_length(cap))
		var w : Vector3 = PhysicsServer3D.body_get_state(b.rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
		if w.length() > 30.0:
			PhysicsServer3D.body_set_state(b.rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, w.limit_length(30.0))


## How far the deepest capsule end reaches under the ground (m, 0 = none).
func _deepest_capsule() -> float:
	var space := av.get_world_3d().direct_space_state
	var worst := 0.0
	for b in rig.bodies:
		var cap := b.shape as CapsuleShape3D
		if cap == null:
			continue
		var hh := cap.height * 0.5 - cap.radius
		for e in [_cur[b.index] * Vector3(0, hh, 0), _cur[b.index] * Vector3(0, -hh, 0)]:
			_ray.from = e + UP * 0.6
			_ray.to = e - UP * 0.4
			var r := space.intersect_ray(_ray)
			if r and (r.normal as Vector3).y > 0.5:
				worst = maxf(worst, -(((e as Vector3) - (r.position as Vector3)).dot(r.normal) - cap.radius))
	return worst


## Jolt lets a light body (the head, a hand) get pressed a few cm into the ground when the heavier body leans on it
## through the joints; lift anything more than 2 cm under the ground back out at a gentle rate.
func _depenetrate() -> void:
	var space := av.get_world_3d().direct_space_state
	for b in rig.bodies:
		if b.region == &"torso" or b.region == &"hips":
			continue
		var x := _cur[b.index]
		var cap := b.shape as CapsuleShape3D
		if cap == null:
			continue
		var hh := cap.height * 0.5 - cap.radius
		var worst := 0.0
		var n := UP
		for e in [x * Vector3(0, hh, 0), x * Vector3(0, -hh, 0)]:
			_ray.from = e + UP * 0.5
			_ray.to = e - UP * 0.4
			var r := space.intersect_ray(_ray)
			if r and (r.normal as Vector3).y > 0.5:
				var d : float = ((e as Vector3) - (r.position as Vector3)).dot(r.normal) - cap.radius
				if -d > worst:
					worst = -d
					n = r.normal
		if worst > 0.02:
			var v : Vector3 = PhysicsServer3D.body_get_state(b.rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
			var out := minf((worst - 0.01) * 12.0, 1.5)
			if v.dot(n) < out:
				PhysicsServer3D.body_set_state(b.rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, v + n * (out - v.dot(n)))


## The frozen player (and the avatar's root) over the hips: on the ground under them, or a leg's length below them in
## the air.
func _follow_ragdoll() -> void:
	var hips := _cur[_b_hips].origin
	var ride := _ride()
	var gy := _ground_y(hips, hips.y - ride - 0.5)
	var root := Vector3(hips.x, maxf(gy, hips.y - ride), hips.z)
	_set_player_pos(root + UP * ride)


func _set_player_pos(p : Vector3) -> void:
	if not is_instance_valid(player):
		return
	# Someone else moved the player (a teleport, a respawn): let go
	if _frozen and player.global_position.distance_to(_last_player_pos) > 2.5:
		_abort()
		return
	player.global_position = p
	_last_player_pos = p


## Stretch, speed and spike checks (the harness reads them). Returns the fastest body's speed.
func _measure(dt : float) -> float:
	var vmax := 0.0
	var dvmax := 0.0
	for b in rig.bodies:
		var i := b.index
		var v := (_cur[i].origin - _prev[i].origin) / dt
		var sp := v.length()
		vmax = maxf(vmax, sp)
		if b.parent >= 0:
			var a1 := _cur[i] * b.anchor_self
			var a2 := _cur[b.parent] * b.anchor_parent
			stats["max_sep"] = maxf(float(stats["max_sep"]), a1.distance_to(a2))
		var lv : Vector3 = b.rb.get_meta(&"_lv", v)
		# An explosion is a body gaining speed out of nothing (a hard stop on the ground is not)
		var jump := v.length() - lv.length() - 9.81 * dt
		dvmax = maxf(dvmax, jump)
		if jump > 12.0 and _t > dt * 2.0:
			stats["spikes"] = int(stats["spikes"]) + 1
		b.rb.set_meta(&"_lv", v)
	stats["max_speed"] = maxf(float(stats["max_speed"]), vmax)
	if _t > dt * 2.0:
		stats["max_dv_tick"] = maxf(float(stats["max_dv_tick"]), dvmax)
	var hips := _cur[_b_hips].origin
	var pp := player.global_position
	stats["root_gap"] = maxf(float(stats["root_gap"]), Vector2(pp.x - hips.x, pp.z - hips.z).length())
	return vmax


# --- get up ---------------------------------------------------------------------------------------------------------

func _start_gather() -> void:
	state = State.GATHER
	_t = 0.0
	var fit := _choose_match()
	stats["clip"] = _clip_name
	stats["fit_err"] = fit
	# The matched frame, lined up with the body: what the pre-pose moves every body into (world space)
	_gather_targets()
	# An arm or a leg the body lies on: the torso lifts off it while it comes out (and the limbs don't catch on the
	# rest of the body meanwhile)
	_trap_setup()
	rig.set_limb_collision(false)
	rig.set_getup_ranges(true)
	stats["loose_pairs"] = rig._loose_pairs.size()
	# The pre-pose's reference runs from the pose it lies in to the matched frame: longer for a roll (the torso turning
	# over) and for limbs far from it
	var jm := 0.0
	for b in rig.bodies:
		_g_start[b.index] = _cur[b.index]
		if b.parent >= 0:
			_js[b.index] = _joint_path(b, _cur[b.parent].affine_inverse() * _cur[b.index],
				_gather_raw[b.parent].affine_inverse() * _gather_raw[b.index])
			jm += _local_err(_cur[b.parent], _cur[b.index], _gather_raw[b.parent], _gather_raw[b.index])
			_tw0[b.index] = _twist(b, _cur[b.index], _cur[b.parent])
			_tw1[b.index] = _twist(b, _gather_raw[b.index], _gather_raw[b.parent])
	jm /= maxf(_n - 1, 1)
	# How far each limb body travels relative to the hips: that much of an arc over the ground on the way
	var h0 := _g_start[_b_hips].affine_inverse()
	var h1 := _gather_raw[_b_hips].affine_inverse()
	for b in rig.bodies:
		var d := (h0 * _g_start[b.index].origin).distance_to(h1 * _gather_raw[b.index].origin)
		# (the forearms and hands; a leg lifted on the way reads as a kick)
		var limb := b.region.begins_with("arm") and not String(b.name).ends_with("UpperArm")
		_arc[b.index] = minf(0.5 * d, 0.15) if limb and d > 0.12 else 0.0
	var roll := _cur[_b_hips].basis.get_rotation_quaternion().angle_to(_gather_raw[_b_hips].basis.get_rotation_quaternion())
	_pre_T = clampf(0.3 + 0.5 * roll + 0.35 * jm, 0.45, 1.3)
	_pre_best = INF
	stats["pre_roll"] = rad_to_deg(roll)
	stats["pre_tick_us"] = 0
	stats["pre_T"] = _pre_T


## Angle (rad) between a joint's local rotation in two poses (child body relative to its parent body).
func _local_err(p0 : Transform3D, c0 : Transform3D, p1 : Transform3D, c1 : Transform3D) -> float:
	var q0 := p0.basis.get_rotation_quaternion().inverse() * c0.basis.get_rotation_quaternion()
	var q1 := p1.basis.get_rotation_quaternion().inverse() * c1.basis.get_rotation_quaternion()
	return q0.angle_to(q1)


## World transform of every body in the chosen clip's first frame, placed at the fitted root.
func _gather_targets() -> void:
	var t0 := _clip.sample(_clip_t0)
	var A := Transform3D(Basis(UP, _root_yaw), _fit_pos) * _skel_in_av
	# The clip lies on its mesh, the bodies are a little thicker: lift the whole frame until the torso is out of the
	# ground (one lift for all, so the joints keep the frame's pose)
	var lift := 0.0
	for b in rig.bodies:
		if b.region == &"torso" or b.region == &"hips":
			var x : Transform3D = A * (t0[b.bone][1] as Transform3D) * b.b2b_inv
			lift = maxf(lift, _fit_pos.y + 0.005 - Match.lowest(b, x))
	A.origin.y += lift
	stats["frame_lift"] = lift
	for b in rig.bodies:
		var x : Transform3D = A * (t0[b.bone][1] as Transform3D) * b.b2b_inv
		x.basis = x.basis.orthonormalized()
		_gather_raw[b.index] = x
		# The clip lies on flat ground: on a slope or rough ground keep each body's target out of the ground
		var gy := _ground_y(x.origin + UP * 0.5, -INF)
		if gy > -INF and x.origin.y - b.radius < gy + 0.01:
			x.origin.y = gy + 0.01 + b.radius
		_gather_tgt[b.index] = x


const _TORSO : Array[StringName] = [&"Hips", &"Spine", &"Chest", &"UpperChest"]
const _LIMBS := {
	&"arm_l": [&"LeftUpperArm", &"LeftLowerArm", &"LeftHand"],
	&"arm_r": [&"RightUpperArm", &"RightLowerArm", &"RightHand"],
	&"leg_l": [&"LeftLowerLeg", &"LeftFoot"],
	&"leg_r": [&"RightLowerLeg", &"RightFoot"],
}


## A limb is trapped when one of its bodies lies under the torso (below a torso body's centre, within its width): the
## torso lifts a little off it during the first part of the gather while the limb is pulled out (the bodies don't
## collide with each other, so it comes out from under it), as someone rolls off an arm they fell on.
func _trap_setup() -> void:
	_trap_lift = 0.0
	var n := 0
	for side in _LIMBS:
		var trapped := false
		for nm in _LIMBS[side]:
			var lb : Rig.Body = rig.by_name.get(nm)
			if lb == null:
				continue
			var lp := _cur[lb.index].origin
			for tn in _TORSO:
				var tb : Rig.Body = rig.by_name[tn]
				var tp := _cur[tb.index].origin
				var dh := Vector2(lp.x - tp.x, lp.z - tp.z).length()
				if lp.y < tp.y - 0.03 and dh < tb.radius + lb.radius + 0.06:
					trapped = true
					break
			if trapped:
				break
		if trapped:
			n += 1
	if n > 0:
		_trap_lift = 0.09
	stats["trapped"] = n


## The pre-pose (the gather): a reference pose runs smoothly from the pose the body lies in to the matched clip frame
## (the hips in world space: a roll onto the back or the front when it lies on its side; every joint by its local
## rotation, the twist about the bone the way the joint allows), and every body is steered (its velocities) toward it.
## The reference is carried by where the hips really are (with their motion as a feed-forward), so a torso that lags
## doesn't pull the limbs off their pose. Speeds are limited, the ground and the other bodies still push back, targets
## stay out of the ground, and the torso lifts off a trapped limb for the first part. It ends once the joints are within
## a few degrees of the frame (or at the latest 0.35 s after the reference got there).
func _tick_gather(dt : float) -> void:
	var us0 := Time.get_ticks_usec()
	# A roll turns the torso over first (lifted a little off the ground and the arm under it), the limbs follow
	var roll := clampf(float(stats.get("pre_roll", 0.0)) / 90.0, 0.0, 1.0)
	var u_h := smoothstep(0.0, _pre_T * lerpf(1.0, 0.75, roll), _t)
	var u := smoothstep(_pre_T * 0.2 * roll, _pre_T, _t)
	var gain := lerpf(6.0, 16.0, smoothstep(0.0, _pre_T * 0.7, _t)) # 1/s
	var s := 1.0 - exp(-dt / 0.03)
	var lift := _trap_lift * (1.0 - smoothstep(_pre_T * 0.45, _pre_T * 0.9, _t)) * smoothstep(0.0, 0.12, _t)
	lift = maxf(lift, 0.1 * roll * sin(PI * u_h))
	# The reference pose by FK: the hips in world space, every joint's local rotation interpolated
	var ref : Array[Transform3D] = []
	ref.resize(_n)
	for b in rig.bodies:
		var i := b.index
		if b.parent < 0:
			ref[i] = Transform3D(Basis(_roll_path(u_h)), _g_start[i].origin.lerp(_gather_tgt[i].origin, u_h))
		else:
			# (the legs turn over with the hips, the arms follow)
			var uj := u if b.region.begins_with("arm") else u_h
			var js : Array = _js[i]
			# (joint space: the swing by the shortest way, the twist about the bone linearly, the way the joint allows)
			var a := (js[2] as Quaternion).slerp(js[3], uj) * Quaternion(Vector3.RIGHT, lerpf(js[4], js[5], uj))
			var rq : Quaternion = (js[0] as Quaternion) * a * (js[1] as Quaternion)
			ref[i] = ref[b.parent] * Transform3D(Basis(rq), (js[6] as Vector3).lerp(js[7], uj))
	# ... carried by the hips as they are
	var hx := _cur[_b_hips]
	var carry := hx * ref[_b_hips].affine_inverse()
	var jerr := 0.0
	for b in rig.bodies:
		var i := b.index
		var x := _cur[i]
		var r := ref[i]
		if b.parent >= 0:
			# (the torso rolls over as one piece in world space; the limbs go with the hips as they are)
			if b.region != &"torso" and b.region != &"head":
				r = carry * r
			jerr += _local_err(_cur[b.parent], x, _gather_raw[b.parent], _gather_raw[i])
		if lift > 0.0 and (b.region == &"torso" or b.region == &"hips" or b.region == &"head"):
			r.origin += UP * lift
		elif _arc[i] > 0.0:
			# A limb that moves far is lifted over the ground on the way (not dragged through it)
			r.origin += UP * _arc[i] * sin(PI * u)
		# Out of the ground (the clip lies on flat ground; slopes, rough ground)
		var gy := _ground_y(r.origin + UP * 0.5, -INF)
		if gy > -INF and r.origin.y - b.radius < gy + 0.01:
			r.origin.y = gy + 0.01 + b.radius
		var v : Vector3 = PhysicsServer3D.body_get_state(b.rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
		var w : Vector3 = PhysicsServer3D.body_get_state(b.rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
		var vt := ((r.origin - x.origin) * gain).limit_length(3.0)
		var wt := _rotvec(r.basis.get_rotation_quaternion() * x.basis.get_rotation_quaternion().inverse()) * gain
		if b.parent >= 0:
			# The twist about the bone goes the way the joint allows: the shortest way round can cross the twist
			# limit (from +120 to -75 deg it would go through 180 and stop at the limit)
			var ax := (x * b.jframe_self).basis.x.normalized()
			var dtw := lerpf(_tw0[i], _tw1[i], u if b.region.begins_with("arm") else u_h) - _twist(b, x, _cur[b.parent])
			var wp : Vector3 = PhysicsServer3D.body_get_state(rig.bodies[b.parent].rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
			wt += ax * (wp.dot(ax) + dtw * maxf(gain, 8.0) - wt.dot(ax))
		wt = wt.limit_length(10.0)
		# (a body that settled may have gone to sleep: setting its velocity alone doesn't move it)
		PhysicsServer3D.body_set_state(b.rid, PhysicsServer3D.BODY_STATE_SLEEPING, false)
		PhysicsServer3D.body_set_state(b.rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, v.lerp(vt, s))
		PhysicsServer3D.body_set_state(b.rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, w.lerp(wt, s))
	jerr = rad_to_deg(jerr / maxf(_n - 1, 1))
	stats["pre_tick_us"] = maxi(int(stats.get("pre_tick_us", 0)), Time.get_ticks_usec() - us0)
	if dbg_print and int(_t / dt) % 24 == 0:
		var parts := []
		for b in rig.bodies:
			if b.parent >= 0:
				var rr := carry * ref[b.parent]
				var rc := carry * ref[b.index]
				parts.append("%s %.0f/%.0f" % [String(b.name).substr(0, 8), rad_to_deg(_local_err(_cur[b.parent], _cur[b.index], rr, rc)), rad_to_deg(_local_err(_cur[b.parent], _cur[b.index], _gather_raw[b.parent], _gather_raw[b.index]))])
		print("    pre t %.2f u %.2f track/final: %s" % [_t, u, ", ".join(parts)])
	_follow_ragdoll()
	_measure(dt)
	# Done once the reference is there and the joints are close, or stop getting closer
	var there := _t >= _pre_T
	if there:
		_pre_best = minf(_pre_best, jerr)
	if there and (jerr < 5.0 or jerr > _pre_best + 1.5 or _t >= _pre_T + 0.35):
		var pe := 0.0
		var ae := 0.0
		for b in rig.bodies:
			pe += _cur[b.index].origin.distance_to(_gather_tgt[b.index].origin)
			ae += rad_to_deg(_cur[b.index].basis.get_rotation_quaternion().angle_to(_gather_raw[b.index].basis.get_rotation_quaternion()))
		stats["gather_err"] = "%.3f m %.1f deg" % [pe / _n, ae / _n]
		stats["pre_time"] = _t
		# The clip starts where the body really is: its root lined up with the ragdoll's torso again
		_refit_root()
		_root_pos = _fit_pos
		_snap_pending = true
		_gu_frames = 0
		state = State.GETUP
		_t = 0.0


## A joint's way from one local pose (child body relative to its parent body) to another, in the joint's frame (X along
## the child bone): [P, J^-1, swing0, swing1, twist0, twist1, offset0, offset1], the local rotation at u being
## P * slerp(swing0, swing1, u) * twist(lerp(twist0, twist1, u)) * J^-1: the swing by the shortest way, the twist about
## the bone linearly between the two angles (the way the joint's range allows, never through the back of it).
func _joint_path(b : Rig.Body, r0 : Transform3D, r1 : Transform3D) -> Array:
	var J := b.jframe_self.basis.orthonormalized().get_rotation_quaternion()
	var P := b.jframe_parent.basis.orthonormalized().get_rotation_quaternion()
	var a0 := P.inverse() * r0.basis.get_rotation_quaternion() * J
	var a1 := P.inverse() * r1.basis.get_rotation_quaternion() * J
	var t0 := _twist_of(a0)
	var t1 := _twist_of(a1)
	var s0 := a0 * Quaternion(Vector3.RIGHT, t0).inverse()
	var s1 := a1 * Quaternion(Vector3.RIGHT, t1).inverse()
	if s0.dot(s1) < 0.0:
		s1 = -s1
	return [P, J.inverse(), s0, s1, t0, t1, r0.origin, r1.origin]


static func _twist_of(q : Quaternion) -> float:
	var tw := Quaternion(q.x, 0.0, 0.0, q.w)
	if tw.length_squared() < 1e-10:
		return 0.0
	tw = tw.normalized()
	return wrapf(2.0 * atan2(tw.x, tw.w), -PI, PI)


## The hips' orientation on the pre-pose's way at u: first of all a roll about the body's long axis (onto the back or
## the front), the rest (turning, tilting) by the shortest way at the same time. Rotating the whole difference by the
## shortest way instead can swing the legs up into the air.
func _roll_path(u : float) -> Quaternion:
	var q0 := _g_start[_b_hips].basis.get_rotation_quaternion()
	var q1 := _gather_raw[_b_hips].basis.get_rotation_quaternion()
	var d := q1 * q0.inverse()
	if d.w < 0.0:
		d = -d
	var ax := _g_start[_b_hips].basis.y.normalized() # the torso box's long axis (world)
	var p := ax * Vector3(d.x, d.y, d.z).dot(ax)
	var tw := Quaternion(p.x, p.y, p.z, d.w)
	if tw.length_squared() < 1e-10:
		return q0.slerp(q1, u)
	tw = tw.normalized()
	var sw := d * tw.inverse()
	return (Quaternion.IDENTITY.slerp(sw, u) * Quaternion.IDENTITY.slerp(tw, u) * q0).normalized()


## The clip's root (yaw about UP and position) lined up with where the ragdoll's torso is now, for the matched frame.
func _refit_root() -> void:
	var smp := _clip.sample(_clip_t0)
	var TR := _skel_in_av.basis.orthonormalized().get_rotation_quaternion()
	var qs := Quaternion(0, 0, 0, 0)
	for nm : StringName in [&"Hips", &"UpperChest"]:
		var b : Rig.Body = rig.by_name[nm]
		var qc := TR * (smp[b.bone][1] as Transform3D).basis.orthonormalized().get_rotation_quaternion()
		var qr := (_cur[b.index] * b.b2b).basis.orthonormalized().get_rotation_quaternion()
		var q := qr * qc.inverse()
		if qs.dot(q) < 0.0:
			q = -q
		qs += q
	if absf(qs.y) + absf(qs.w) > 1e-6:
		_root_yaw = 2.0 * atan2(qs.y, qs.w)
	var A0 := Transform3D(Basis(UP, _root_yaw), Vector3.ZERO) * _skel_in_av
	var acc := Vector3.ZERO
	var ws := 0.0
	for nm : StringName in [&"Hips", &"Spine", &"Chest", &"UpperChest"]:
		var b : Rig.Body = rig.by_name[nm]
		var w := 2.0 if nm == &"Hips" else 1.0
		acc += ((_cur[b.index] * b.b2b).origin - A0 * (smp[b.bone][1] as Transform3D).origin) * w
		ws += w
	var pos := acc / ws
	var hips := _cur[_b_hips].origin
	pos.y = _ground_y(Vector3(pos.x, hips.y, pos.z), hips.y - 2.0)
	_fit_pos = pos


## A joint's twist (rad, about the child bone: its joint frame's X) with the child at `xc` and the parent at `xp`.
func _twist(b : Rig.Body, xc : Transform3D, xp : Transform3D) -> float:
	var fa := xp * b.jframe_parent
	var fb := xc * b.jframe_self
	var q := (fa.basis.orthonormalized().inverse() * fb.basis.orthonormalized()).get_rotation_quaternion()
	var tw := Quaternion(q.x, 0.0, 0.0, q.w)
	if tw.length_squared() < 1e-10:
		return 0.0
	tw = tw.normalized()
	return wrapf(2.0 * atan2(tw.x, tw.w), -PI, PI)


## The clip (get_up_front / get_up_back) whose first frame fits the body lying there, and where to put the root
## (yaw + position) so it lines up. `pick`: try both clips and keep the one whose lined-up first frame is closest to the
## body (joint positions + the torso's orientation: a body on its side goes to whichever it is nearer); else refit the
## current one. Returns the fit's RMS error (m).
func _choose_clip(pick := true) -> float:
	if not pick and _clip != null:
		return _fit_clip(_clip_name)
	var best := INF
	var best_name : StringName = &"get_up_back"
	for cn : StringName in [&"get_up_back", &"get_up_front"]:
		_fit_clip(cn)
		var cost := _fit_cost
		if cost < best:
			best = cost
			best_name = cn
	return _fit_clip(best_name)


## Mean angle (rad) between the ragdoll's torso bodies and the current fit's clip first frame.
func _torso_mismatch() -> float:
	var t0 := _clip.sample(0.0)
	var A := Transform3D(Basis(UP, _root_yaw), _fit_pos) * _skel_in_av
	var tot := 0.0
	for tn in [&"Hips", &"Chest", &"UpperChest"]:
		var b : Rig.Body = rig.by_name[tn]
		var x : Transform3D = A * (t0[b.bone][1] as Transform3D) * b.b2b_inv
		tot += x.basis.orthonormalized().get_rotation_quaternion().angle_to(_cur[b.index].basis.get_rotation_quaternion())
	return tot / 3.0


func _fit_clip(cn : StringName) -> float:
	_clip_name = cn
	_clip = _get_clip(_clip_name)
	_clip_t0 = 0.0
	_skel_in_av = _skel_for(_clip)
	var t0 := _clip.sample(0.0)
	# 2D fit (xz) of the clip's joints onto the ragdoll's
	var names : Array[StringName] = [&"Hips", &"UpperChest", &"Head", &"LeftLowerLeg", &"RightLowerLeg", &"LeftFoot",
		&"RightFoot", &"LeftLowerArm", &"RightLowerArm"]
	var wts := [3.0, 2.0, 1.5, 1.0, 1.0, 1.0, 1.0, 0.5, 0.5]
	var cs : Array[Vector2] = []
	var rs : Array[Vector2] = []
	var cm := Vector2.ZERO
	var rm := Vector2.ZERO
	var ws := 0.0
	for k in names.size():
		var b : Rig.Body = rig.by_name[names[k]]
		var c : Vector3 = _skel_in_av * (t0[b.bone][1] as Transform3D).origin
		var r := (_cur[b.index] * b.b2b).origin
		cs.append(Vector2(c.x, c.z))
		rs.append(Vector2(r.x, r.z))
		cm += cs[k] * wts[k]
		rm += rs[k] * wts[k]
		ws += wts[k]
	cm /= ws
	rm /= ws
	var sxx := 0.0
	var sxy := 0.0
	for k in names.size():
		var a := cs[k] - cm
		var r := rs[k] - rm
		sxx += wts[k] * (a.x * r.x + a.y * r.y)
		sxy += wts[k] * (a.x * r.y - a.y * r.x)
	var ang := atan2(sxy, sxx) # rotation (in the xz plane, x -> z) taking clip onto ragdoll
	# Two candidate yaws: the joints' 2D fit (the avatar's yaw rotates about +Y: a rotation by `ang` from x toward z is
	# a yaw of -ang), and the torso's own heading (the twist about UP that turns the clip's hips + chest onto the
	# ragdoll's; the joints alone can fit a curled body back to front). Keep the one with the lower cost: the joints'
	# RMS distance + 0.6 m per radian of torso orientation difference.
	var cands : Array[float] = [-ang]
	var qsum := Quaternion(0, 0, 0, 0)
	for tn in [&"Hips", &"UpperChest"]:
		var tb : Rig.Body = rig.by_name[tn]
		var qc := (_skel_in_av * (t0[tb.bone][1] as Transform3D) * tb.b2b_inv).basis.orthonormalized().get_rotation_quaternion()
		var qrel := _cur[tb.index].basis.get_rotation_quaternion() * qc.inverse()
		if qsum.dot(qrel) < 0.0:
			qrel = -qrel
		qsum = qsum + qrel
	if absf(qsum.y) + absf(qsum.w) > 1e-4:
		cands.append(2.0 * atan2(qsum.y, qsum.w))
	var hips := _cur[_b_hips].origin
	var best_cost := INF
	var best_err := 0.0
	var best_yaw := 0.0
	var best_pos := hips
	for yaw in cands:
		var R := Basis(UP, yaw)
		var cm3 := R * Vector3(cm.x, 0.0, cm.y)
		var pos := Vector3(rm.x - cm3.x, 0.0, rm.y - cm3.z)
		pos.y = _ground_y(Vector3(pos.x, hips.y, pos.z), hips.y - 2.0)
		var err := 0.0
		for k in names.size():
			var c3 := R * Vector3(cs[k].x, 0.0, cs[k].y)
			err += wts[k] * (Vector2(pos.x + c3.x, pos.z + c3.z) - rs[k]).length_squared()
		err = sqrt(err / ws)
		_root_yaw = yaw
		_fit_pos = pos
		var cost := err + _torso_mismatch() * 0.6
		if cost < best_cost:
			best_cost = cost
			best_err = err
			best_yaw = yaw
			best_pos = pos
	_root_yaw = best_yaw
	_root_pos = best_pos
	_fit_pos = best_pos
	_fit_cost = best_cost
	return best_err


## The skeleton in the avatar's space, with the model lowered by the clip's ground offset as AvatarLocomotion will.
func _skel_for(c : Clip) -> Transform3D:
	var T := av.global_transform.affine_inverse() * av.skeleton.global_transform
	var hip_m := av.skeleton.motion_scale * av.profile.model_scale
	T.origin.y += -c.ground * hip_m - av.model.position.y
	return T


## The get-up by pose matching (ragdoll_match.gd): the clip (or its mirror), the frame to start from and the root
## yaw that fit the body lying there best; the root's position lines the clip's torso up with the ragdoll's. Returns
## the joints' 2D fit error (m, as the old frame-0 fit reported it).
func _choose_match() -> float:
	# The old choice (frame 0 of get_up_back / get_up_front by a 2D joint fit), for the harness' before / after
	var old_fit := _choose_clip(true)
	var f0 := _match.measure()
	var e_old := _match.score(f0, _clip_name, 0.0)
	var je_old := _match.joint_error(f0, e_old.entry)
	stats["old_clip"] = _clip_name
	stats["old_err_mean"] = je_old.x
	stats["old_err_max"] = je_old.y
	var t_us := Time.get_ticks_usec()
	if not _match.ready:
		_match.build_all()
		stats["match_build_sync"] = true
	var r := _match.finish()
	stats["match_us"] = Time.get_ticks_usec() - t_us
	stats["match_tick_us"] = _match.pass_max_tick_us
	stats["match_pass_us"] = _match.pass_us
	stats["match_build_ms"] = _match.build_us / 1000.0
	stats["match_n"] = _match.entries.size()
	if r.is_empty():
		return old_fit
	var e : Match.Entry = r["entry"]
	var je := _match.joint_error(r["feat"], e)
	stats["match_err_mean"] = je.x
	stats["match_err_max"] = je.y
	stats["match_t0"] = e.t
	stats["match_cost"] = rad_to_deg(float(r["cost"]))
	if dbg_print:
		var parts := []
		var fe : Match.Feat = r["feat"]
		for b in rig.bodies:
			if b.parent >= 0:
				var sk := av.skeleton
				var rr := (sk.get_bone_global_rest(rig.bodies[b.parent].bone).basis.orthonormalized().get_rotation_quaternion().inverse() * sk.get_bone_global_rest(b.bone).basis.orthonormalized().get_rotation_quaternion())
				parts.append("%s %.0f (rd %.0f clip %.0f)" % [b.name, rad_to_deg(2.0 * acos(minf(absf(fe.rel[b.index].dot(e.rel[b.index])), 1.0))),
					rad_to_deg(fe.rel[b.index].angle_to(rr)), rad_to_deg(e.rel[b.index].angle_to(rr))])
		print("   MATCH %s t %.2f yaw %.0f tilt %s h %.2f/%.2f joints: %s" % [e.clip, e.t, rad_to_deg(float(r["yaw"])), _match.tilt(fe, e, float(r["yaw"])), fe.h, e.h, ", ".join(parts)])
		# The best per clip variant (what the torso alone allows)
		var per := {}
		for en in _match.entries:
			var c := _match.cost(fe, en)
			var tl := _match.tilt(fe, en, c.y)
			var k := String(en.clip)
			if not per.has(k) or c.x < per[k][0]:
				per[k] = [c.x, en.t, tl, _match.joint_error(fe, en).x]
		for k in per:
			print("     best %s: cost %.0f t %.2f tilt %s joints %.0f" % [k, rad_to_deg(per[k][0]), per[k][1], per[k][2], per[k][3]])
	_clip_name = e.clip
	_clip = _get_clip(_clip_name)
	_clip_t0 = e.t
	_skel_in_av = _skel_for(_clip)
	_root_yaw = float(r["yaw"])
	# The root: the clip's torso on the ragdoll's (xz), on the ground under it
	var A0 := Transform3D(Basis(UP, _root_yaw), Vector3.ZERO) * _skel_in_av
	var smp := _clip.sample(_clip_t0)
	var acc := Vector3.ZERO
	var ws := 0.0
	for nm : StringName in [&"Hips", &"Spine", &"Chest", &"UpperChest"]:
		var b : Rig.Body = rig.by_name[nm]
		var w := 2.0 if nm == &"Hips" else 1.0
		acc += ((_cur[b.index] * b.b2b).origin - A0 * (smp[b.bone][1] as Transform3D).origin) * w
		ws += w
	var pos := acc / ws
	var hips := _cur[_b_hips].origin
	pos.y = _ground_y(Vector3(pos.x, hips.y, pos.z), hips.y - 2.0)
	_fit_pos = pos
	_root_pos = pos
	# The joints' 2D fit error (m) of this placement
	var err := 0.0
	var n := 0
	for nm : StringName in [&"Hips", &"UpperChest", &"Head", &"LeftLowerLeg", &"RightLowerLeg", &"LeftFoot", &"RightFoot",
			&"LeftLowerArm", &"RightLowerArm"]:
		var b : Rig.Body = rig.by_name[nm]
		var c := A0 * (smp[b.bone][1] as Transform3D).origin + pos
		var rr := (_cur[b.index] * b.b2b).origin
		err += Vector2(c.x - rr.x, c.z - rr.z).length_squared()
		n += 1
	return sqrt(err / n)


func _get_clip(n : StringName) -> Clip:
	if _clips.has(n):
		return _clips[n]
	var c := Clip.new()
	var need := PackedInt32Array()
	for b in rig.bodies:
		need.append(b.bone)
	var ground := float(av.profile.clip_meta().get(String(n), {}).get("ground", 0.0))
	c.setup(av.profile.library.get_animation(n), av.skeleton, need, "%" + String(av.profile.skeleton_name) + ":", ground)
	_clips[n] = c
	return c


## Bone -> body transform in skeleton space units (b2b carries the model scale; skeleton space has none).
func _b2b_sk_inv(b : Rig.Body) -> Transform3D:
	var t := b.b2b
	var s := rig.unit
	return Transform3D(t.basis.orthonormalized(), t.origin / s).affine_inverse()


func _tick_getup(dt : float) -> void:
	if not is_instance_valid(player):
		return
	if _frozen:
		_set_player_pos(_root_pos + UP * _ride())
	if state == State.RELEASE:
		return


## Snapshot of the pose shown, then the clip; called from modify() so the snapshot is exactly what was on screen.
func _begin_getup_display(S : Transform3D) -> void:
	_snap_pending = false
	var f := clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0)
	var errs := 0.0
	var emax := 0.0
	var ebone : StringName = &""
	var t0 := _clip.sample(_clip_t0)
	var Sinv := S.affine_inverse()
	for b in rig.bodies:
		var x := _prev[b.index].interpolate_with(_cur[b.index], f)
		_snap[b.index] = x * b.b2b
	# How far the ragdoll itself got into the matched frame (what the blend below covers)
	var pe := _pose_err(Sinv, t0)
	stats["phys_err_mean"] = pe[0]
	stats["phys_err_max"] = pe[1]
	if dbg_print:
		var parts := []
		for b in rig.bodies:
			var wt := _gather_tgt[b.index]
			var wa := rad_to_deg(_cur[b.index].basis.get_rotation_quaternion().angle_to(wt.basis.get_rotation_quaternion()))
			var loc := 0.0
			if b.parent >= 0:
				var ql := ((Sinv * _snap[b.parent]).basis.orthonormalized().inverse() * (Sinv * _snap[b.index]).basis.orthonormalized()).get_rotation_quaternion()
				var qc := ((t0[rig.bodies[b.parent].bone][1] as Transform3D).basis.orthonormalized().inverse() * (t0[b.bone][1] as Transform3D).basis.orthonormalized()).get_rotation_quaternion()
				loc = rad_to_deg(ql.angle_to(qc))
			parts.append("%s %.0f (world %.0f %.2fm)" % [b.name, loc, wa, _cur[b.index].origin.distance_to(wt.origin)])
		print("   GATHERED %s" % ", ".join(parts))
		var lim := []
		for r in rig.joint_report(_gather_raw):
			if r[4]:
				if r[1] > r[3] + 1.0 or r[1] < -4.0:
					lim.append("%s bend %.0f (limit %.0f)" % [r[0], r[1], r[3]])
			elif r[1] > r[3] + 1.0 or absf(r[2]) > r[5] + 1.0:
				lim.append("%s swing %.0f/%.0f twist %.0f/%.0f" % [r[0], r[1], r[3], r[2], r[5]])
		var now := []
		var rt := rig.joint_report(_gather_raw)
		var k := 0
		for r in rig.joint_report(_cur):
			now.append("%s %.0f/%.0f (want %.0f/%.0f)" % [String(r[0]).substr(0, 9), r[1], r[2], rt[k][1], rt[k][2]])
			k += 1
		print("   TARGET out of range: %s" % ", ".join(lim))
		var tws := []
		for b in rig.bodies:
			if b.parent >= 0:
				tws.append("%s %.0f->%.0f (want %.0f)" % [String(b.name).substr(0, 9), rad_to_deg(_tw0[b.index]), rad_to_deg(_twist(b, _cur[b.index], _cur[b.parent])), rad_to_deg(_tw1[b.index])])
		print("   TWIST %s" % ", ".join(tws))
		print("   NOW swing/twist: %s" % ", ".join(now))
	# Pose-matching error at the blend start: each bone's local rotation, ragdoll vs clip (deg)
	for b in rig.bodies:
		if b.parent < 0:
			continue
		var sp := Sinv * _snap[b.parent]
		var sc := Sinv * _snap[b.index]
		var ql := (sp.basis.orthonormalized().inverse() * sc.basis.orthonormalized()).get_rotation_quaternion()
		var cp : Transform3D = t0[rig.bodies[b.parent].bone][1]
		var cc : Transform3D = t0[b.bone][1]
		var qc := (cp.basis.orthonormalized().inverse() * cc.basis.orthonormalized()).get_rotation_quaternion()
		var e := rad_to_deg(ql.angle_to(qc))
		# A short blend from the ragdoll's pose into the clip; a limb further off takes a little longer (it reads as
		# moving it, not snapping)
		_blend_T[b.index] = clampf(blend_time + e / 60.0 * 0.12, blend_time, blend_time + 0.3)
		errs += e
		if e > emax:
			emax = e
			ebone = b.name
	stats["pose_err_max"] = emax
	stats["pose_err_mean"] = errs / maxf(_n - 1, 1)
	stats["pose_err_bone"] = ebone
	# The hips (world): the clip's root was lined up with the torso as it lies; what is left of the offset blends out
	# with it
	var A := Transform3D(Basis(UP, _root_yaw), _fit_pos) * _skel_in_av
	var hc : Transform3D = A * (t0[rig.bodies[_b_hips].bone][1] as Transform3D)
	var hs := _snap[_b_hips]
	var hd := hs.origin.distance_to(hc.origin)
	var ha := rad_to_deg(hs.basis.orthonormalized().get_rotation_quaternion().angle_to(hc.basis.orthonormalized().get_rotation_quaternion()))
	_blend_T[_b_hips] = clampf(blend_time + hd / 0.2 * 0.12 + ha / 60.0 * 0.12, blend_time, blend_time + 0.3)
	stats["hips_off"] = "%.2f m %.0f deg" % [hd, ha]
	rig.disable()
	_gu_t = _clip_t0
	_gu_real = 0.0
	_rm_t = _clip_t0
	var ln := _clip.length
	# Hand back while standing up: the clips end with a long settle
	_release_at = maxf(ln * (0.8 if String(_clip_name).begins_with("get_up_front") else 0.78), _clip_t0 + 0.5)
	av.play_action(_clip_name, 0.01, getup_speed, &"full", _clip_t0)
	stats["getup_t"] = _now - float(stats.get("knock_start", _now))


## Mean and max per-bone local rotation difference (deg) between _snap and the clip frame t0.
func _pose_err(Sinv : Transform3D, t0 : Dictionary) -> Array:
	var worst := []
	var tot := 0.0
	var mx := 0.0
	for b in rig.bodies:
		if b.parent < 0:
			continue
		var sp := Sinv * _snap[b.parent]
		var sc := Sinv * _snap[b.index]
		var ql := (sp.basis.orthonormalized().inverse() * sc.basis.orthonormalized()).get_rotation_quaternion()
		var cp : Transform3D = t0[rig.bodies[b.parent].bone][1]
		var cc : Transform3D = t0[b.bone][1]
		var qc := (cp.basis.orthonormalized().inverse() * cc.basis.orthonormalized()).get_rotation_quaternion()
		var e := rad_to_deg(ql.angle_to(qc))
		tot += e
		mx = maxf(mx, e)
		if e > 20.0:
			worst.append("%s %.0f" % [b.name, e])
	stats["phys_worst"] = ", ".join(worst)
	return [tot / maxf(_n - 1, 1), mx]


func _end_getup_display() -> void:
	_fade = 0.0


## The pose override (FALL..GETUP): places the avatar's root (the ragdoll's hips, then the clip's root motion) and
## keeps AvatarPose's look / aim off the body.
func avatar_pose(a : Avatar, delta : float) -> void:
	a.set_aim(a.look_direction(), 0.0)
	match state:
		State.FALL, State.GATHER, State.PENDING:
			if rig.enabled:
				var f := clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0)
				var hips := _prev[_b_hips].interpolate_with(_cur[_b_hips], f).origin
				var ride := _ride()
				var gy := _ground_y(hips, hips.y - ride - 0.5)
				_root_pos = Vector3(hips.x, maxf(gy, hips.y - ride), hips.z)
		State.GETUP:
			if _gu_frames >= 1:
				# The clip time of this frame (the AnimationTree's slot advances by the same amount)
				_gu_t += delta * getup_speed
				_gu_real += delta
				_root_motion(_rm_t, _gu_t)
				_rm_t = _gu_t
			_gu_frames += 1
	a.set_facing_yaw(_root_yaw)
	a.facing_yaw = _root_yaw
	a.global_transform = Transform3D(Basis(UP, _root_yaw), _root_pos)
	if state == State.GETUP:
		a.pose.leg_ik = false


## The clip's root motion from t0 to t1 (its Root bone, sampled; the AnimationTree only seeks) moves the avatar's
## root: avatar' = avatar * M * (Root(t0)^-1 * Root(t1)) * M^-1, M = the skeleton in the avatar's space.
func _root_motion(t0 : float, t1 : float) -> void:
	if t1 <= t0:
		return
	var delta := _clip.root_at(t0).affine_inverse() * _clip.root_at(t1)
	var dyaw := delta.basis.get_euler().y
	var mb := _skel_in_av.basis
	var d := Basis(UP, _root_yaw) * (mb * delta.origin)
	_root_yaw = wrapf(_root_yaw + dyaw, -PI, PI)
	d.y = 0.0
	# Don't walk the body into a wall
	if d.length() > 1e-5:
		var from := _root_pos + UP * 0.55
		var sp := SphereShape3D.new()
		sp.radius = 0.22
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = sp
		q.transform = Transform3D(Basis(), from)
		q.motion = d
		q.collision_mask = 1 | 4 | 8
		q.exclude = _ray.exclude
		var r := av.get_world_3d().direct_space_state.cast_motion(q)
		if r.size() == 2 and r[0] < 1.0:
			d *= r[0]
	var np := _root_pos + d
	var gy := _ground_y(np + UP * 0.8, np.y - 1.5)
	np.y = lerpf(np.y, gy, 0.35) if gy > -INF else np.y
	_root_pos = np


# --- the modifier ----------------------------------------------------------------------------------------------------

## Runs inside the skeleton's modifier pass (after AvatarPose): captures the animated pose as targets, then writes the
## physical / get-up pose.
func modify(delta : float) -> void:
	var sk := av.skeleton
	var S := sk.global_transform
	var root_inv := Transform3D(Basis(UP, av.facing_yaw), av.global_position).affine_inverse()
	if delta > 0.0:
		_anim_dt = maxf(delta, 1e-3)
	rig.capture_pose(sk, _anim_w, S)
	for b in rig.bodies:
		var bodyw := _anim_w[b.index]
		_anim_prev[b.index] = _anim[b.index] if state != State.PENDING else root_inv * bodyw
		_anim[b.index] = root_inv * bodyw
	if _pending_mode != State.IDLE:
		_activate()
	var f := clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0)
	match state:
		State.PARTIAL, State.FALL, State.GATHER:
			if _snap_pending:
				pass
			var src : Array[Transform3D] = []
			src.resize(_n)
			var w := PackedFloat32Array()
			w.resize(_n)
			for b in rig.bodies:
				src[b.index] = _prev[b.index].interpolate_with(_cur[b.index], f) * b.b2b
				w[b.index] = _disp[b.index] if state == State.PARTIAL else 1.0
			_write(S, src, w)
			# Arms on hand IK (a tool, a grip) stay out of partial reactions, but they hang off the torso that just
			# swayed: solve them again so the hands stay on what they hold
			if state == State.PARTIAL and av.pose and av.pose.has_method(&"resolve_arms"):
				var held := _held_arms()
				if held[0] or held[1]:
					av.pose.resolve_arms()
		State.GETUP, State.RELEASE:
			if _snap_pending:
				_begin_getup_display(S)
			_getup_frame(S, delta)
	_cache_final(S)


func _getup_frame(S : Transform3D, delta : float) -> void:
	if state == State.RELEASE:
		_gu_t += delta * getup_speed # (the pose override that advanced it is gone)
	var smp := _clip.sample(_gu_t)
	var src : Array[Transform3D] = []
	src.resize(_n)
	var w := PackedFloat32Array()
	w.resize(_n)
	var fade := 1.0
	if state == State.RELEASE:
		_fade = minf(_fade + delta / 0.35, 1.0)
		fade = 1.0 - smoothstep(0.0, 1.0, _fade)
	for b in rig.bodies:
		src[b.index] = S * (smp[b.bone][1] as Transform3D)
		w[b.index] = fade
	_write(S, src, w)
	if state == State.GETUP:
		var any := false
		for b in rig.bodies:
			var T : float = _blend_T[b.index]
			w[b.index] = 1.0 - smoothstep(0.0, T, _gu_real)
			any = any or w[b.index] > 0.0
		if any:
			_write(S, _snap, w)
		if _gu_t >= _release_at:
			state = State.RELEASE
			_fade = 0.0
			_release.call_deferred()
	elif _fade >= 1.0:
		_to_idle()


## Writes world-space bone transforms `src` over the pose with per-body weights: the hips by position and rotation,
## every other bone by its local rotation relative to the parent as it is now (bone lengths never change).
func _write(S : Transform3D, src : Array[Transform3D], w : PackedFloat32Array) -> void:
	rig.write_pose(av.skeleton, src, w, S)


func _cache_final(S : Transform3D) -> void:
	var sk := av.skeleton
	for nm in [&"UpperChest", &"Neck", &"Head", &"Hips"]:
		var b : Rig.Body = rig.by_name[nm]
		_final[nm] = S * sk.get_bone_global_pose(b.bone)
	_head_w = _final[&"Head"]


# --- release / abort ---------------------------------------------------------------------------------------------

func _release() -> void:
	if state != State.RELEASE:
		return
	av.stop_action(0.45)
	av.clear_pose_override(self)
	av.pose.leg_ik = true
	av.pose.reset()
	av.set_facing_yaw(_root_yaw)
	av.set_facing_mode(_prev_facing)
	_set_player_pos(_root_pos + UP * _ride())
	_give_player_back(Vector3.ZERO)
	_end_view(true)
	_hide_tools(false)
	_cool = knock_cooldown
	stats["control_t"] = _now - float(stats.get("knock_start", _now))
	got_up.emit()


func _to_idle() -> void:
	if state == State.PARTIAL and av.facing_mode == &"locked" and not av.has_pose_override():
		av.set_facing_mode(_prev_facing)
	if rig.enabled:
		rig.disable()
	for i in _n:
		_loose[i] = 0.0
		_disp[i] = 0.0
		_hold[i] = 0.0
	_kicks.clear()
	state = State.IDLE
	_pending_mode = State.IDLE
	mod.active = false
	_pivot_on = false


## Drops everything at once (the player got into a vehicle, was teleported, the scene is going away).
func _abort() -> void:
	var was_down := is_down()
	if rig and rig.enabled:
		rig.disable()
	if is_instance_valid(av):
		av.clear_pose_override(self)
		if av.pose:
			av.pose.leg_ik = true
			av.pose.reset()
		if was_down:
			av.stop_action(0.2)
			av.set_facing_mode(_prev_facing)
	if _frozen:
		_give_player_back(Vector3.ZERO)
	_end_view()
	_hide_tools(false)
	_snap_pending = false
	_to_idle()


# --- views ------------------------------------------------------------------------------------------------------------

func _setup_view() -> void:
	var cam : Node = Global.Camera if is_instance_valid(Global.Camera) else null
	var first := av.view_mode() == &"first"
	_pulled_out = false
	if not first:
		return
	if RSettings.pull_out() and cam and cam.has_method(&"set_view_mode"):
		_pulled_out = true
		_pull_from = StringName(cam.get(&"view_mode"))
		cam.call(&"set_view_mode", &"third", false, false) # temporary: not saved
		return
	if player.has_method(&"take_view") and not player.has_view_owner():
		player.take_view(self)
		_view_owned = true
		_view_q = player.cam_holder.global_basis.get_rotation_quaternion()
		_view_blend = 0.0
		_view_eye = player.cam_holder.global_position


func _end_view(smooth := false) -> void:
	if _view_owned and is_instance_valid(player):
		player.release_view(self)
		_eye_last = player.eye_offset
		if smooth and _eye_last.length() > 0.001:
			_eye_fade = 1.0
		else:
			player.eye_offset = Vector3.ZERO
	_view_owned = false
	if _pulled_out:
		_pulled_out = false
		var cam : Node = Global.Camera if is_instance_valid(Global.Camera) else null
		if cam and cam.has_method(&"set_view_mode"):
			cam.call(&"set_view_mode", _pull_from, false, false)


func _process(delta : float) -> void:
	if _eye_fade > 0.0 and is_instance_valid(player):
		_eye_fade = maxf(_eye_fade - delta / 0.4, 0.0)
		player.eye_offset = _eye_last * smoothstep(0.0, 1.0, _eye_fade)
	if not _pivot_on:
		return
	# Where the body is this frame (the ragdoll, interpolated; the get-up: the pose shown last frame)
	var uc : Transform3D
	var nk : Transform3D
	var hd : Transform3D
	if rig.enabled and state != State.PARTIAL:
		var f := clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0)
		uc = _prev_cur(&"UpperChest", f)
		nk = _prev_cur(&"Neck", f)
		hd = _prev_cur(&"Head", f)
		_head_w = hd
	elif not _final.is_empty():
		uc = _final[&"UpperChest"]
		nk = _final[&"Neck"]
		hd = _final[&"Head"]
	else:
		return
	var raw := uc.origin.lerp(nk.origin, 0.6)
	_pivot = _pivot.lerp(raw, 1.0 - exp(-delta * 14.0))
	if _view_owned:
		_update_fp_view(delta, hd)
	if state == State.IDLE:
		_pivot_on = false


func _prev_cur(nm : StringName, f : float) -> Transform3D:
	var b : Rig.Body = rig.by_name[nm]
	return _prev[b.index].interpolate_with(_cur[b.index], f) * b.b2b


## First person while down: the eye rides in the head, the view looks where the face points, steadied (slow to follow,
## mostly level, never faster than the head) so the fall reads without making anyone sick.
func _update_fp_view(delta : float, head : Transform3D) -> void:
	if not is_instance_valid(player):
		return
	var eye := head * _eye_off
	var hb := head.basis.orthonormalized()
	var fwd := hb.z.normalized()
	var hup := hb.y.normalized()
	# Never stare into the ground (face down) or straight up: keep the pitch between -30 and +55 degrees, the
	# heading from the face (or, lying flat, from the top of the head)
	var flat := Vector3(fwd.x, 0.0, fwd.z)
	if flat.length() < 0.35:
		var alt := Vector3(hup.x, 0.0, hup.z) * (1.0 if fwd.y < 0.0 else -1.0)
		flat = flat.lerp(alt, 1.0 - flat.length() / 0.35)
	if flat.length() < 0.01:
		flat = Vector3(-sin(_root_yaw), 0.0, -cos(_root_yaw))
	var pitch := clampf(asin(clampf(fwd.y, -1.0, 1.0)), deg_to_rad(-30.0), deg_to_rad(55.0))
	fwd = flat.normalized() * cos(pitch) + UP * sin(pitch)
	var up_ref := (UP * 0.85 + hup * 0.15).normalized()
	if absf(fwd.dot(up_ref)) > 0.95:
		up_ref = hup
	var target := Basis.looking_at(fwd, up_ref).get_rotation_quaternion()
	# The start: from the look to the head over 0.25 s
	_view_blend = minf(_view_blend + delta / 0.25, 1.0)
	var rate := 5.0
	if state == State.RELEASE or (state == State.GETUP and _gu_t > _release_at - 0.6):
		# Standing up: settle on a level look along the facing
		target = Basis.from_euler(Vector3(-0.1, _root_yaw, 0.0)).get_rotation_quaternion()
		rate = 4.0
	_view_q = _view_q.slerp(target, 1.0 - exp(-delta * rate))
	player.set_view_basis(Basis(_view_q))
	_view_eye = _view_eye.lerp(eye, 1.0 - exp(-delta * 18.0)) if _view_blend < 1.0 else eye
	var base : Vector3 = player.global_position + UP * (0.68 - 0.1 * float(player.get(&"crouch_amount")))
	player.eye_offset = _view_eye - base


## The held tool goes away while down (and its crosshair): the hand tool manager's own "player left" path.
func _hide_tools(hide : bool) -> void:
	if hide == _tools_hidden or not is_inside_tree():
		return
	var cam : Node = Global.Camera if is_instance_valid(Global.Camera) else null
	var mgr : Node = cam.get_node_or_null(^"HandToolManager") if cam else null
	if mgr == null or not mgr.is_inside_tree():
		_tools_hidden = false
		return
	if mgr.has_method(&"holster"):
		mgr.call(&"holster", hide)
	_tools_hidden = hide


# --- helpers ----------------------------------------------------------------------------------------------------------

func _ride() -> float:
	var r : Variant = player.get(&"ride_height") if is_instance_valid(player) else null
	return float(r) if r != null else 1.0


func _feet_y() -> float:
	return player.global_position.y - _ride() if is_instance_valid(player) else 0.0


func _facing_fwd() -> Vector3:
	return Vector3(-sin(av.facing_yaw), 0.0, -cos(av.facing_yaw))


func _chest_w() -> Vector3:
	return av.bone_global(&"UpperChest").origin


func _root_now() -> Transform3D:
	return Transform3D(Basis(UP, av.facing_yaw), player.global_position - UP * _ride())


func _body_now(i : int) -> Transform3D:
	if rig.enabled:
		return _cur[i]
	var b := rig.bodies[i]
	return av.bone_global(b.name) * b.b2b_inv


## Ground height under `p` (ray down), or `fallback`.
func _ground_y(p : Vector3, fallback : float) -> float:
	var space := av.get_world_3d().direct_space_state
	_ray.from = p + UP * 0.3
	_ray.to = p - UP * 4.0
	var r := space.intersect_ray(_ray)
	return (r.position as Vector3).y if r else fallback


static func _rotvec(q : Quaternion) -> Vector3:
	return Rig.rotation_vector(q)

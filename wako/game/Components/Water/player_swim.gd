extends Node
## Player plugin: swimming (instanced by Components/PlayerPlugins/swim.tscn under the player).
## Works on the player RigidBody3D (its parent, an ancestor, or Global.Player) through forces only:
##  * near-neutral buoyancy (a human floats just below the surface) plus "treading water" that keeps the eyes
##    above the waves when idle, so the head bobs with the swell
##  * swim along the camera look direction (move actions: W/A/S/D or the left stick, analog; look down + forward to
##    dive), jump (Space / A) = up / surface, crouch (C or Ctrl / B) = down, sprint (Shift / L3) = faster strokes
##  * water drag against the moving water: waves and currents carry you
##  * stroke splashes at the surface, bubbles under water, a splash when you jump in
## Input comes from the named actions (rebindable in Settings > Controls, pad included) and the player's
## get_move_local().

signal started_swimming
signal stopped_swimming

@export var swim_speed := 2.1
@export var sprint_speed := 3.4
@export var stroke_force := 5.5 ## acceleration gain (1/s)
@export var eye_height := 0.62 ## camera height above the body centre
@export var tread_eye_above := 0.2 ## how far the eyes float above the water when idle
@export var water_drag := 2.4
## Actions: swim up, swim down, faster strokes.
@export var action_up := &"jump"
@export var action_down := &"crouch"
@export var action_sprint := &"sprint"

var body: RigidBody3D
var swimming := false
var head_under := false
## 0..1 how much of the body is in the water.
var immersion := 0.0

var _audio_node: SwimAudio
var _was_falling_speed := 0.0
var _shore_cooldown := 0.0
var _shore_lift := 0.0
var _shore_scan := 0.0

func _ready() -> void:
	var n: Node = get_parent()
	while n and not (n is RigidBody3D):
		n = n.get_parent()
	body = n as RigidBody3D
	if body == null and Global.Player:
		body = Global.Player
	_audio_node = SwimAudio.new()
	_audio_node.name = "SwimAudio"
	add_child(_audio_node)

func _look_basis() -> Basis:
	var holder := body.get_node_or_null(^"cam_holder") as Node3D
	if holder:
		return holder.global_basis
	if Global.Camera:
		return Global.Camera.global_basis
	return body.global_basis

func _physics_process(delta: float) -> void:
	if body == null or not is_instance_valid(body) or body.freeze:
		return
	if body.has_meta(&"climbing_ladder"):
		_set_swimming(false)
		_audio_node.stop()
		return
	_shore_cooldown = maxf(_shore_cooldown - delta, 0.0)
	_shore_scan = maxf(_shore_scan - delta, 0.0)
	if _shore_lift > 0.0:
		_shore_lift -= delta
		# Let the shore hop clear the water without treading/drag braking it.
		_set_swimming(false)
		_audio_node.stop()
		return
	var pos := body.global_position
	var h := Water.height_at(pos,get_instance_id()*4096)
	var wake: Vector4
	if WaterInteraction.enabled:
		wake = WaterInteraction.sample(pos)
		h += wake.y
	if h == -INF:
		_set_swimming(false)
		_audio_node.stop()
		return
	var depth := h - pos.y # water above the body centre
	# Capsule ~1.8 m: immersion 0 at the feet, 1 with the head under.
	immersion = clampf((depth + 0.9) / 1.8, 0.0, 1.0)
	var eyes_depth := h - (pos.y + eye_height)
	head_under = eyes_depth > 0.05
	var grounded := _touching_ground()
	var now_swimming := depth > 0.25 or (depth > -0.1 and not grounded)
	if now_swimming and not swimming and _was_falling_speed > 4.0:
		WaterSplash.spawn(body, Vector3(pos.x, h, pos.z), clampf(_was_falling_speed / 6.0, 0.5, 2.0))
	_set_swimming(now_swimming)
	if swimming and not head_under and _try_shore_exit(h):
		return
	_was_falling_speed = -body.linear_velocity.y
	if immersion <= 0.0:
		_audio_node.stop()
		return
	var g := body.get_gravity().length()
	var m := body.mass
	# Buoyancy: nearly neutral when fully under (lungs full), grows with immersion.
	var f := Vector3.UP * m * g * immersion * 0.985
	# Drag against the moving water (waves carry you, currents push you).
	var water_motion := Water.velocity_at(pos,get_instance_id()*4096)
	if WaterInteraction.enabled:
		water_motion.y += wake.w
	var rel := body.linear_velocity - water_motion
	f += -rel * m * water_drag * immersion
	if swimming:
		var up_in := Input.get_action_strength(action_up)
		var down_in := Input.get_action_strength(action_down)
		var mv := _move_local()
		var lb := _look_basis()
		var dir := Vector3.ZERO
		if mv != Vector3.ZERO:
			dir = (lb * mv).normalized()
			# At the surface, strokes stay horizontal unless you look clearly down (a dive).
			if not head_under and dir.y > -0.45:
				dir.y = 0.0
				dir = dir.normalized()
			dir *= minf(mv.length(), 1.0) # a small push on the stick swims slowly
		dir.y += up_in - down_in
		var speed := sprint_speed if _fast() else swim_speed
		var target := dir.limit_length(1.0) * speed
		var water_v := Water.velocity_at(pos,get_instance_id()*4096)
		if WaterInteraction.enabled:
			water_v.y += wake.w
		var steer := (target - (body.linear_velocity - water_v)) * m * stroke_force
		if dir == Vector3.ZERO:
			steer = Vector3.ZERO
		f += steer.limit_length(m * 9.0)
		# Treading water: hold the eyes just above the surface when not diving.
		if down_in == 0.0 and not (head_under and dir.y < -0.2):
			# Follow the surface's own vertical motion (ride the swell) and correct the eye height on top.
			var err := -eyes_depth - tread_eye_above # < 0: eyes too low
			var rel_vy := body.linear_velocity.y - water_v.y
			if err < 0.08 or up_in > 0.0:
				f.y += clampf(-err * 16.0 - rel_vy * 4.0, -5.0, 9.0) * m
		_audio(delta, dir != Vector3.ZERO, h, water_v, lb)
	else:
		_audio_node.stop()
	body.apply_central_force(f)

## Holding forward climbs a reachable bank or ledge. Check the wall, a walkable
## top, and the entire standing capsule before adding the same kind of upward
## impulse as a jump; tall walls and submerged diving never trigger it.
func _try_shore_exit(surface_height: float) -> bool:
	if _shore_cooldown > 0.0 or _shore_scan > 0.0 or Input.is_action_pressed(action_down):
		return false
	var mv := _move_local()
	if mv.z >= -0.2:
		return false
	_shore_scan = 0.1
	var forward := _look_basis() * mv
	forward.y = 0.0
	forward = forward.normalized()
	var pos := body.global_position
	var space := body.get_world_3d().direct_space_state
	var wall_query := PhysicsRayQueryParameters3D.create(pos + Vector3.DOWN * 0.15,
		pos + Vector3.DOWN * 0.15 + forward * 0.85, body.collision_mask, [body.get_rid()])
	var wall := space.intersect_ray(wall_query)
	if wall.is_empty() or wall.normal.dot(-forward) < 0.2:
		return false
	if not preload("res://Components/Avatar/surface_response.gd").climbable(wall.collider):
		return false
	var ahead: Vector3 = wall.position + forward * 0.45
	var top_query := PhysicsRayQueryParameters3D.create(Vector3(ahead.x, surface_height + 1.25, ahead.z),
		Vector3(ahead.x, surface_height - 0.4, ahead.z), body.collision_mask, [body.get_rid()])
	var ledge := space.intersect_ray(top_query)
	if ledge.is_empty() or ledge.normal.y < 0.65 or ledge.position.y > surface_height + 1.05:
		return false
	var collision := body.get_node_or_null(^"Collision") as CollisionShape3D
	if collision == null or collision.shape == null:
		return false
	var ride := float(body.get("ride_height")) if "ride_height" in body else 1.0
	var target: Vector3 = ledge.position + Vector3.UP * (ride + 0.08)
	var clearance := PhysicsShapeQueryParameters3D.new()
	clearance.shape = collision.shape
	clearance.transform = Transform3D(body.global_basis, target) * collision.transform
	clearance.collision_mask = body.collision_mask
	clearance.exclude = [body.get_rid()]
	if not space.intersect_shape(clearance, 1).is_empty():
		return false
	var lift := target.y - pos.y
	if lift < 0.1 or lift > 2.2:
		return false
	var takeoff := sqrt(2.0 * maxf(body.get_gravity().length(), 9.81) * (lift + 0.15))
	body.apply_central_impulse((Vector3.UP * maxf(takeoff - body.linear_velocity.y, 0.0) + forward * 1.4) * body.mass)
	_shore_cooldown = 0.9
	_shore_lift = 0.4
	_set_swimming(false)
	_audio_node.stop()
	return true

## The horizontal move input in the view frame (x right, z back): the player's (analog on a pad), else the actions.
func _move_local() -> Vector3:
	if body.has_method(&"get_move_local"):
		var v: Vector3 = body.call(&"get_move_local", false)
		v.y = 0.0
		return v
	var v2 := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
	return Vector3(v2.x, 0.0, v2.y)


## Faster strokes: the sprint action held, or the player's pad run latch (stick click toggles running).
func _fast() -> bool:
	if Input.is_action_pressed(action_sprint):
		return true
	return InputHub.using_pad and body.has_method(&"wants_run") and bool(body.call(&"wants_run"))


func _touching_ground() -> bool:
	return "on_ground" in body and body.on_ground

func _set_swimming(v: bool) -> void:
	if v == swimming:
		return
	swimming = v
	if v:
		started_swimming.emit()
		OceanAlmanac.discover(self, &"swimming")
	else:
		stopped_swimming.emit()

func _audio(delta: float, moving: bool, h: float, water_v: Vector3, lb: Basis) -> void:
	var pos := body.global_position
	var speed := (body.linear_velocity - water_v).length()
	_audio_node.update(delta, true, moving, speed, _fast(), head_under,
			Vector3(pos.x, h, pos.z), pos + Vector3.UP * eye_height, -lb.z)

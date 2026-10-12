class_name Weapon
extends HandTool
## Base for guns. Handles the trigger (semi / auto), magazine and reserve, reloading, spread (rest + bloom + moving
## + hurt), recoil, the crosshair, and the diegetic ammo lights on the gun model.
##
## A gun extends Weapon and implements `_fire()` (spawn a projectile or call `hitscan()` + `apply_hit()`). The base
## calls it once per shot, after taking the round, so `_fire()` only does the shot itself.
##
## Ammo lights (`ammo_lights`): emissive meshes on the model (MeshInstance3D / GeometryInstance3D), ordered from the
## first to go out to the last. Each light stands for mag_size / lights rounds and dims as those rounds are spent.
## Low ammo turns them amber, an empty mag glows a slow red, and while reloading they fill up one by one with the
## next one blinking. The weapon gives each light its own emissive material (material_override), so the meshes only
## need their shape.
##
## Input: "Shoot" (hold for `auto`), "Reload" (R). An empty trigger pull clicks and starts a reload.

const GunState := preload("res://Components/HandTools/Weapon/gun_state.gd")
const GunBinding := preload("res://Components/HandTools/Weapon/gun_binding.gd")
const GunPhysics := preload("res://Components/HandTools/Weapon/gun_physics.gd")
static var _live_gun_owners: Dictionary = {}
static var _gun_restore_epoch := 0
var _gun_owner_epoch := 0
var gun_state = GunState.new()
var _gun_binding: RefCounted
var _binding_was_valid := false

signal fired
signal reloaded
signal reload_started
signal dry_fired

@export_group("Magazine")
@export var mag_size: int = 30
## Rounds outside the magazine; -1 = unlimited.
@export var reserve: int = -1:
	get: return gun_state.reserve
	set(value): gun_state.reserve = value
## Seconds between shots.
@export var fire_interval: float = 0.1
@export var reload_time: float = 1.8
## Hold the trigger to keep firing.
@export var auto: bool = true
## Start with a full magazine.
@export var start_loaded: bool = true

@export_group("Aim")
## Cone half-angle (degrees) standing still.
@export var spread: float = 0.35
## Extra degrees per shot (decays at `bloom_recovery` deg/s), capped at `max_bloom`.
@export var bloom_per_shot: float = 0.35
@export var max_bloom: float = 3.0
@export var bloom_recovery: float = 6.0
## Extra degrees while moving at run speed / in the air.
@export var move_spread: float = 1.2
## Extra degrees at full hurt (the player shakes).
@export var hurt_spread: float = 3.0
## View kick per shot (degrees of pitch; yaw gets a random share).
@export var recoil: float = 0.6
## Camera shake per shot (0..1 trauma).
@export var shake: float = 0.03

@export_group("Ammo lights")
@export var ammo_lights: Array[NodePath] = []
@export var light_color := Color(0.25, 0.85, 1.0)
@export var light_low_color := Color(1.0, 0.55, 0.1)
@export var light_empty_color := Color(1.0, 0.12, 0.08)
@export var light_energy: float = 3.5
## Brightest the indicator lights may get (HDR, brightest colour channel x energy). The lights are a few millimetres
## across and a hand's length from the eye: emission far above white (5x) blew them out to flat white blocks whose
## razor edge followed the temporal AA's sub-pixel jitter, so the edges shimmered every frame under TAA, FSR 2 and
## DLSS alike (a resolve can't settle an edge that is 5x over white). Just over white they read in their colour,
## still bloom a little, and the edge is an ordinary bright-on-dark edge the resolve keeps still.
const LIGHT_MAX_HDR := 1.5
## Below this fraction of the magazine the lights turn `light_low_color`.
@export_range(0.0, 1.0) var low_fraction: float = 0.25

var ammo: int:
	get: return gun_state.ammo
	set(value): gun_state.ammo = value
var reloading: bool:
	get: return gun_state.reloading
	set(value): gun_state.reloading = value
var reload_progress: float:
	get: return gun_state.reload_progress
	set(value): gun_state.reload_progress = value
var bloom: float:
	get: return gun_state.bloom
	set(value): gun_state.bloom = value

var _trigger_down := false
var _cooldown: float:
	get: return gun_state.cooldown
	set(value): gun_state.cooldown = value
var _light_mats: Array[StandardMaterial3D] = []
var _light_nodes: Array[GeometryInstance3D] = []
var _anim_t := 0.0


func _ready() -> void:
	gun_state.initialize(mag_size, start_loaded or (_gun_binding == null and GameState.debug_freeroam))
	_claim_gun_identity(gun_state.item_id)
	_setup_lights()
	set_ammo_lights()


# --- trigger ------------------------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not is_equipped:
		return
	if event.is_action_pressed("Shoot"):
		_trigger_down = true
		_try_fire(true)
	elif event.is_action_released("Shoot"):
		_trigger_down = false
	elif event.is_action_pressed("Reload"):
		reload()


func _on_unequip() -> void:
	_trigger_down = false


func _process(delta: float) -> void:
	_anim_t += delta
	gun_state.advance(delta, bloom_recovery, heat_cooling)
	var context_valid := firing_context_valid()
	if not context_valid and (_binding_was_valid or get("charging") == true):
		_on_unequip() # cancel the native held trigger/charge when its real controller is absent
	_binding_was_valid = context_valid
	if reloading:
		reload_progress += delta / maxf(reload_time, 0.01)
		if reload_progress >= 1.0:
			_finish_reload()
	if _trigger_down and auto and context_valid:
		_try_fire(false)
	_update_crosshair()
	set_ammo_lights()
	_weapon_process(delta)


## Virtual: per-frame work of the gun (aim animation, heat...). Called from the base _process.
func _weapon_process(_delta: float) -> void:
	pass


func can_fire() -> bool:
	return firing_context_valid() and (_gun_binding == null or _gun_binding.shot_valid()) and gun_state.ready(shot_energy_wh)


func _try_fire(pressed_now: bool) -> void:
	if not firing_context_valid() or (_gun_binding != null and not _gun_binding.shot_valid()) or reloading or _cooldown > 0.0 or gun_state.jammed or gun_state.condition <= 0.0 or gun_state.energy_wh < shot_energy_wh:
		return
	if _gun_binding == null and GameState.debug_freeroam:
		ammo = mag_size
	if ammo <= 0:
		if pressed_now:
			dry_fired.emit()
			_on_dry_fire()
			reload()
		return
	if not _prepare_fire(): return
	gun_state.consume(fire_interval, bloom_per_shot, max_bloom, heat_per_shot, shot_energy_wh, wear_per_shot)
	_apply_recoil()
	if crosshair_node and crosshair_node.has_method(&"kick"):
		crosshair_node.kick()
	_fire()
	# The real shot observes the spent round (rocket tube/model selection depends on it).
	# Refill after the shot so charges, fuel and every weapon keep their normal firing behavior.
	if _gun_binding == null and GameState.debug_freeroam:
		ammo = mag_size
	fired.emit()
	if not auto:
		_trigger_down = false


## Virtual: admit an outgoing shot before consuming its finite state or recoil.
func _prepare_fire() -> bool:
	return true


## Virtual: the shot itself (projectile, hitscan, effects).
func _fire() -> void:
	pass


## Virtual: empty trigger pull (play a click).
func _on_dry_fire() -> void:
	pass


# --- reload -------------------------------------------------------------------------------------------------

func reload() -> void:
	if _gun_binding == null and GameState.debug_freeroam:
		ammo = mag_size
		return
	if reloading or ammo >= mag_size or reserve == 0:
		return
	reloading = true
	reload_progress = 0.0
	_trigger_down = false
	reload_started.emit()
	_on_reload_start()


func _finish_reload() -> void:
	reloading = false
	reload_progress = 0.0
	var need := mag_size - ammo
	if reserve < 0:
		ammo = mag_size
	else:
		var take := mini(need, reserve)
		reserve -= take
		ammo += take
	reloaded.emit()
	_on_reload_done()


## Virtual.
func _on_reload_start() -> void:
	pass


## Virtual.
func _on_reload_done() -> void:
	pass


## Adds rounds to the reserve (pickups). Unlimited reserves stay unlimited.
func add_ammo(rounds: int) -> void:
	if reserve >= 0:
		reserve += rounds


# --- aim ----------------------------------------------------------------------------------------------------

## Current cone half-angle in degrees.
func current_spread() -> float:
	var s := spread + bloom
	var p := firing_carrier()
	if p:
		var v := p.linear_velocity.length()
		s += move_spread * clampf(v / 10.0, 0.0, 1.0)
		if "on_ground" in p and not p.on_ground:
			s += move_spread * 0.5
		if "hurt_level" in p:
			s += hurt_spread * p.hurt_level
	var cam := aim_camera()
	if cam and cam.get("zoom"):
		s *= 0.6
	return s


## Every gun carrier fires from its visible barrel. Non-gun utility tools keep camera rays.
func aim_origin() -> Vector3:
	var tip := firing_muzzle()
	if tip: return tip.global_position
	var cam := aim_camera()
	return cam.global_position if cam else global_position


## Aim direction with a random offset inside the spread cone (plus `extra_deg`).
func aim_direction(extra_deg: float = 0.0) -> Vector3:
	var cam := aim_camera()
	var tip := firing_muzzle()
	var b := tip.global_basis if _gun_binding != null and tip else cam.global_basis if cam else global_basis
	var fwd := -b.z
	if _gun_binding == null and is_instance_valid(cam) and is_instance_valid(tip):
		var query := PhysicsRayQueryParameters3D.create(cam.global_position, cam.global_position-b.z*aim_query_range(), 0xFFFFFFFF, aim_exclude())
		query.collide_with_areas = false
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		var target: Vector3 = hit.position if not hit.is_empty() else query.to
		if target.distance_to(tip.global_position) > .01: fwd = (target-tip.global_position).normalized()
	var cone := deg_to_rad(current_spread() + extra_deg)
	if cone <= 0.0:
		return fwd
	# Uniform in the cone's disc, biased to the centre a little (sqrt would be uniform; ^0.75 is tighter)
	var r := tan(cone) * pow(randf(), 0.75)
	var a := randf() * TAU
	return (fwd + b.x * cos(a) * r + b.y * sin(a) * r).normalized()


## Raycast from the camera along `dir` (default: aim_direction()). Returns the physics hit Dictionary
## (collider, position, normal, ...) plus "dir"; empty when nothing was hit within `range_m`.
func hitscan(range_m: float = 400.0, dir: Vector3 = Vector3.ZERO, mask: int = 0xFFFFFFFF) -> Dictionary:
	if dir == Vector3.ZERO:
		dir = aim_direction()
	var from := aim_origin()
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * range_m, mask, aim_exclude())
	q.collide_with_areas = false
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		hit["dir"] = dir
	return hit


## Standard bullet impact: pushes rigid bodies, damages whatever can take damage (Core.damage) and lets creatures
## know who shot them. Returns true when the hit object took damage.
func apply_hit(hit: Dictionary, damage: float, impulse: float, kind: StringName = &"bullet", source_override: Node = null, fixed_source := false) -> bool:
	if hit.is_empty():
		return false
	var col := hit.collider as Node
	if col == null:
		return false
	if col is RigidBody3D:
		(col as RigidBody3D).freeze = false
	if col is SoftBody3D:
		(col as SoftBody3D).apply_central_impulse(hit.dir * impulse)
	return Core.damage(col, damage, hit.position, source_override if fixed_source else firing_actor(), kind, impulse if col is RigidBody3D else 0.0, hit.dir)


func _apply_recoil() -> void:
	apply_carrier_recoil(native_recoil_impulse())
	if _gun_binding != null: return
	var p := Global.Player
	if is_instance_valid(p) and "cam_holder" in p and p.active:
		var kick := deg_to_rad(recoil) * randf_range(0.75, 1.0)
		p.cam_holder.rotation.x = clampf(p.cam_holder.rotation.x + kick, -PI / 2, PI / 2)
		p.cam_holder.rotation.y += deg_to_rad(recoil) * randf_range(-0.35, 0.35)
	var cam := aim_camera()
	if cam and cam.has_method(&"add_trauma") and shake > 0.0:
		cam.add_trauma(shake)


func _update_crosshair() -> void:
	var ch := crosshair_node
	if ch == null or not is_instance_valid(ch):
		return
	var cam := aim_camera()
	var px := 0.0
	if cam:
		# Cone half-angle to a screen radius: r = tan(a) / tan(fov/2) * half height
		var half_h := ch.size.y * 0.5
		px = tan(deg_to_rad(current_spread())) / tan(deg_to_rad(cam.fov * 0.5)) * half_h
	ch.set(&"spread_px", px)
	ch.set(&"reload", reload_progress if reloading else -1.0)
	ch.set(&"ammo_fraction", float(ammo) / maxf(mag_size, 1))



@export_group("Physical gun state")
## Optional stored cell energy; native charge-cell weapons continue to count cells as ammunition.
@export var shot_energy_wh := 0.0
@export var heat_per_shot := .05
@export var heat_cooling := .05
@export var wear_per_shot := .00004

func firing_context_valid() -> bool:
	if _gun_owner_epoch != _gun_restore_epoch: return false
	if _gun_binding != null: return _gun_binding.valid()
	return is_equipped and is_instance_valid(Global.Player) and bool(Global.Player.get("active"))

func firing_actor() -> Node:
	return _gun_binding.shooter() if _gun_binding != null else Core.player()

func firing_carrier() -> RigidBody3D:
	return _gun_binding.body() if _gun_binding != null else Core.player()

func carrier_velocity() -> Vector3:
	var body := firing_carrier()
	return body.linear_velocity if is_instance_valid(body) else Vector3.ZERO

func prepare_projectile(projectile: Node) -> void:
	projectile.set(&"shooter", firing_actor())
	projectile.set(&"launch_exclusions", aim_exclude())

func firing_muzzle() -> Node3D:
	if _gun_binding != null: return _gun_binding.bore()
	return local_muzzle()

func local_muzzle() -> Node3D:
	var path: Variant = get("muzzle_path")
	if path is NodePath: return get_node_or_null(path) as Node3D
	return find_child("GunTip", true, false) as Node3D

func aim_camera() -> Camera3D:
	return null if _gun_binding != null else super()

func aim_exclude() -> Array[RID]:
	return _gun_binding.excludes.duplicate() if _gun_binding != null else super()

## Target-acquisition distance, not a projectile lifetime or ballistic range.
## Hitscan guns retain their native configured range; native projectile aim
## convergence uses 1500m. Wind-up shells keep their actual gravity trajectory.
func aim_query_range() -> float:
	var native_range: Variant = get("shot_range")
	if native_range is float or native_range is int:
		var range_m := float(native_range)
		if is_finite(range_m) and range_m > 0.0: return minf(range_m, 10000.0)
	return 1500.0

func native_recoil_impulse() -> float:
	return 0.0

## A held launcher may commit its native shot on the real release edge.
func native_release_intent() -> bool:
	return false

func autonomous_release_ready() -> bool:
	return false

func release_admitted() -> bool:
	return firing_context_valid() and (_gun_binding == null or _gun_binding.shot_valid(false))

func cancel_trigger() -> void:
	_on_unequip()

func apply_carrier_recoil(impulse: float) -> void:
	var body := firing_carrier()
	var tip := firing_muzzle()
	if not is_instance_valid(body) or not is_instance_valid(tip) or not is_finite(impulse) or impulse <= 0.0: return
	# Exactly one native reaction, at the actual muzzle. No velocity/pose resets.
	body.apply_impulse(tip.global_basis.z.normalized() * impulse, tip.global_position - body.global_position)
	body.set_meta(&"self_push_msec", Time.get_ticks_msec())

func transfer_reason() -> String:
	if _gun_owner_epoch != _gun_restore_epoch: return "Saved gun owner is retiring"
	return "Wait for the current shot to finish" if get("charging") == true else ""

func bind_carrier(body: RigidBody3D, actor: Node, tip: Node3D, control: Node3D, role: String, excludes: Array[RID]) -> bool:
	if not transfer_reason().is_empty() or not is_instance_valid(body) or not is_instance_valid(actor) or not is_instance_valid(tip): return false
	var next = GunBinding.new()
	next.configure(self, body, actor, tip, control, role, excludes)
	if not next.valid(): return false
	_trigger_down = false
	_gun_binding = next
	_binding_was_valid = true
	is_equipped = false
	for geometry in find_children("*", "GeometryInstance3D", true, false): geometry.layers = 1
	return true

func unbind_carrier() -> bool:
	if not transfer_reason().is_empty(): return false
	_trigger_down = false
	_gun_binding = null
	_binding_was_valid = false
	return true

## Carrier adapters use the same trigger/reload/shot implementation as player input.
func drive_trigger(down: bool, pressed_now := false) -> void:
	_trigger_down = down and firing_context_valid()
	if _trigger_down and (auto or pressed_now): _try_fire(pressed_now)

func serialize_gun() -> Dictionary:
	var configuration := {}
	for key: String in ["mag_size", "fire_interval", "reload_time", "auto", "damage", "impulse", "shot_strength", "shot_range", "recoil_push", "recoil", "shot_energy_wh", "heat_per_shot", "heat_cooling", "wear_per_shot"]:
		var value: Variant = get(key)
		if value != null: configuration[key] = value
	return {"scene": scene_file_path, "state": gun_state.serialize(), "configuration": configuration, "mechanism": serialize_mechanism()}

func _validated_gun_record(data: Dictionary) -> Dictionary:
	var config: Variant = data.get("configuration", {})
	var saved: Variant = data.get("state", data)
	var mechanism: Variant = data.get("mechanism", {})
	if not config is Dictionary or not saved is Dictionary or not mechanism is Dictionary: return {}
	for value: Variant in mechanism.values():
		if not (value is bool or value is float or value is int): return {}
		if not value is bool and not is_finite(float(value)): return {}
	for key: String in config:
		if key not in ["mag_size", "fire_interval", "reload_time", "auto", "damage", "impulse", "shot_strength", "shot_range", "recoil_push", "recoil", "shot_energy_wh", "heat_per_shot", "heat_cooling", "wear_per_shot"]: return {}
		var value: Variant = config[key]
		if key == "auto":
			if not value is bool: return {}
		elif not (value is float or value is int) or not is_finite(float(value)) or float(value) < 0.0: return {}
		if key == "mag_size" and (float(value) < 1.0 or float(value) != floorf(float(value))): return {}
	var next = GunState.new()
	if not next.restore(saved, int(config.get("mag_size", mag_size))): return {}
	return {"state":next,"config":config,"mechanism":mechanism}

func restore_gun(data: Dictionary) -> bool:
	var record := _validated_gun_record(data)
	if record.is_empty(): return false
	var next = record.state
	var config: Dictionary = record.config
	var mechanism: Dictionary = record.mechanism
	# Pre-tree saved inventory/mounts also participate in actual ownership.
	if not _gun_identity_available(next.item_id): return false
	for key: String in config:
		if get(key) != null: set(key, config[key])
	var old_owner: WeakRef = _live_gun_owners.get(gun_state.item_id)
	if old_owner and old_owner.get_ref() == self: _live_gun_owners.erase(gun_state.item_id)
	gun_state = next
	_claim_gun_identity(gun_state.item_id)
	restore_mechanism(mechanism)
	return true

func _gun_identity_available(identity: String) -> bool:
	if identity.is_empty(): return false
	var owner := live_gun_owner(identity)
	return owner == null or owner == self

static func live_gun_owner(identity: String) -> Node:
	var reference: WeakRef = _live_gun_owners.get(identity)
	var owner: Node = reference.get_ref() if reference else null
	if not is_instance_valid(owner) or owner._gun_owner_epoch != _gun_restore_epoch or owner.gun_state.item_id != identity: return null
	var ancestor := owner
	while is_instance_valid(ancestor):
		if ancestor.is_queued_for_deletion(): return null
		ancestor = ancestor.get_parent()
	return owner

func _claim_gun_identity(identity: String) -> bool:
	if not _gun_identity_available(identity): return false
	_live_gun_owners[identity] = weakref(self)
	_gun_owner_epoch = _gun_restore_epoch
	return true

static func begin_saved_gun_restore() -> void:
	# World savers can retire prior bodies on the deferred frame. Old guns
	# become inert while new snapshot owners claim each identity once.
	_gun_restore_epoch += 1
	_live_gun_owners.clear()

func serialize_mechanism() -> Dictionary:
	return {}

func restore_mechanism(_data: Dictionary) -> void:
	pass

# --- ammo lights --------------------------------------------------------------------------------------------

func _setup_lights() -> void:
	_light_mats.clear()
	_light_nodes.clear()
	for p in ammo_lights:
		var g := get_node_or_null(p) as GeometryInstance3D
		if g == null:
			push_warning("%s: ammo light %s not found" % [name, p])
			continue
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.05, 0.05, 0.05)
		m.roughness = 0.35
		m.metallic_specular = 0.8
		m.emission_enabled = true
		m.emission = light_color
		m.emission_energy_multiplier = led_energy(light_color, light_energy)
		g.material_override = m
		g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_light_nodes.append(g)
		_light_mats.append(m)


## Updates the light meshes from ammo / reload state (called every frame; cheap).
func set_ammo_lights() -> void:
	var n := _light_mats.size()
	if n == 0:
		return
	var per := float(mag_size) / n
	var frac := float(ammo) / maxf(mag_size, 1)
	var base := light_color if frac > low_fraction else light_low_color
	for i in n:
		var m := _light_mats[i]
		var level := 0.0
		var col := base
		if reloading:
			# Fill one by one; the next one blinks
			var filled := reload_progress * n
			if i < floori(filled):
				level = 1.0
				col = light_color
			elif i == floori(filled):
				level = 0.25 + 0.75 * float(fmod(_anim_t * 6.0, 1.0) < 0.5)
				col = light_low_color
			else:
				level = 0.04
		elif ammo <= 0:
			level = 0.35 + 0.3 * sin(_anim_t * 3.0)
			col = light_empty_color
		else:
			# Light i holds rounds (i*per, (i+1)*per]; it dims as they're spent
			level = clampf((ammo - i * per) / per, 0.0, 1.0)
			if level > 0.0:
				level = 0.3 + 0.7 * level
			else:
				level = 0.03
		m.emission = col
		m.emission_energy_multiplier = led_energy(col, light_energy * level)
		m.albedo_color = col * (0.15 * level) + Color(0.04, 0.04, 0.045)


## Emission energy for an indicator light of colour `col`, capped at LIGHT_MAX_HDR (see there).
static func led_energy(col: Color, energy: float) -> float:
	return minf(energy, LIGHT_MAX_HDR / maxf(maxf(col.r, maxf(col.g, col.b)), 0.05))


## Caps every emissive surface of a held view model (glove trims, light strips, screens) at LIGHT_MAX_HDR, for the
## same reason as the indicator lights: a few pixels wide and far over white, their edges follow the temporal AA
## jitter every frame. Surfaces under the limit (and shader materials: flames, holograms) are left alone; the
## materials are copied, the imported ones stay untouched.
static func cap_view_model_emission(root: Node) -> void:
	if root == null:
		return
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		if mi.material_override is BaseMaterial3D:
			var capped := _capped_emission(mi.material_override as BaseMaterial3D)
			if capped:
				mi.material_override = capped
			continue
		for s in mi.mesh.get_surface_count():
			var capped := _capped_emission(mi.get_active_material(s) as BaseMaterial3D)
			if capped:
				mi.set_surface_override_material(s, capped)


static func _capped_emission(mat: BaseMaterial3D) -> BaseMaterial3D:
	if mat == null or not mat.emission_enabled:
		return null
	var e := led_energy(mat.emission, mat.emission_energy_multiplier)
	if e >= mat.emission_energy_multiplier - 0.001:
		return null
	var m := mat.duplicate() as BaseMaterial3D
	m.emission_energy_multiplier = e
	return m


## Key hints (HandTool.get_hints, shown by the shortcuts panel): the trigger and the reload.
func get_hints() -> Array[Dictionary]:
	var h: Array[Dictionary] = [{action = &"Shoot", label = "Fire (hold)" if auto else "Fire"}]
	if reserve != 0 and mag_size > 1:
		h.append({action = &"Reload", label = "Reload"})
	return h

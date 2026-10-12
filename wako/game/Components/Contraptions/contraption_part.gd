extends RigidBody3D
const ExcavatorStock := preload("res://Components/Contraptions/excavator_stock.gd")
const ExcavatorVisual := preload("res://Components/Contraptions/excavator_visual.gd")
const ExcavatorContact := preload("res://Components/Contraptions/excavator_contact.gd")
## Each recoverable component remains a finite-mass rigid body. The model primitives
## use an established stone/brass/energy palette; meshes can replace them without
## changing sockets, save data or worker tasks.

const Catalogue := preload("res://Components/Contraptions/part_catalog.gd")
const CaptiveBay := preload("res://Components/Contraptions/captive_bay_geometry.gd")
const WingPhysics := preload("res://Components/Contraptions/contraption_wing.gd")
const Propulsion := preload("res://Components/Contraptions/contraption_propulsion.gd")
const FanVisual := preload("res://Components/Contraptions/ducted_fan_visual.gd")
const TrackVisual := preload("res://Components/Contraptions/track_visual.gd")
const FlywheelVisual := preload("res://Components/Contraptions/flywheel_visual.gd")
const BrakeData := preload("res://Components/Contraptions/bearing_brake.gd")
const FreewheelStock := preload("res://Components/Contraptions/bearing_freewheel.gd")
const SolarCollector := preload("res://Components/Contraptions/solar_collector.gd")
const SolarVisual := preload("res://Components/Contraptions/solar_visual.gd")
const RecoveryBallProfile := preload("res://Components/Contraptions/recovery_ball_profile.gd")
const RecoveryStator := preload("res://Components/Contraptions/recovery_stator.gd")
const RecoveryBallVisual := preload("res://Components/Contraptions/recovery_ball_visual.gd")
const RecoveryBallDrive := preload("res://Components/Contraptions/recovery_ball_drive.gd")
const Universal := preload("res://Components/Contraptions/universal_joint.gd")
const QuickRelease := preload("res://Components/Contraptions/quick_release_coupler.gd")
const FuseStock := preload("res://Components/Contraptions/breakaway_fuse.gd")
const FuseController := preload("res://Components/Contraptions/breakaway_fuse_controller.gd")
const EyeLampVisual := preload("res://Components/Contraptions/eye_lamp_visual.gd")
const CurvedRib := preload("res://Components/Contraptions/curved_rib_geometry.gd")
const OpenGrille := preload("res://Components/Contraptions/open_grille_geometry.gd")
const StoneBallast := preload("res://Components/Contraptions/stone_ballast_geometry.gd")
const FixedStrut := preload("res://Components/Contraptions/fixed_strut_geometry.gd")
const BeaconGeometry := preload("res://Components/Contraptions/workshop_beacon_geometry.gd")
const BeaconVisual := preload("res://Components/Contraptions/workshop_beacon_visual.gd")
const HornGeometry := preload("res://Components/Contraptions/signal_horn_geometry.gd")
const SignalHorn := preload("res://Components/Contraptions/signal_horn.gd")
const PontoonHydro := preload("res://Components/Contraptions/pontoon_hydro.gd")
const ToolModel := preload("res://Components/Contraptions/worker_tool_model.gd")
const AncientVisual := preload("res://Components/Contraptions/ancient_machine_visual.gd")
const AncientPBR := preload("res://Components/Contraptions/ancient_pbr.gd")
const AncientJoint := preload("res://Components/Contraptions/ancient_joint_visual.gd")
const AncientBracket := preload("res://Components/Contraptions/ancient_bracket_visual.gd")
const LinearWinchVisual := preload("res://Components/Contraptions/ancient_linear_winch_visual.gd")
const GunControl := preload("res://Components/Contraptions/gun_control_point.gd")
const RaisedGunStock := preload("res://Components/Contraptions/raised_gun_station_stock.gd")
const DEFAULT_GUN_SCENE := "res://Components/HandTools/GunAssault/GunAssault.tscn"
# Node3D aiming axes store real_t values. Compare saved axes to those exact
# native representations of the authored stops, including their boundary bits.
const GUN_YAW_STOPS := Vector2(-2.6,2.6)
const GUN_PITCH_STOPS := Vector2(-.6,.85)
const GUN_SCENES := [DEFAULT_GUN_SCENE, "res://Components/HandTools/Pistol/Pistol.tscn", "res://Components/HandTools/Rifle/Rifle.tscn", "res://Components/HandTools/RocketLauncher/RocketLauncher.tscn", "res://Components/HandTools/BFG/BFG.tscn", "res://Components/HandTools/NukeLauncher/NukeLauncher.tscn"]
const BEAM_DURABILITY_KEY := "beam_durability_capacity"
static var _spring_mesh: ArrayMesh
static var _leg_joint_mesh: SphereMesh
signal damaged(amount: float, point: Vector3, source: Node, damage_kind: StringName)
signal condition_changed
signal salvaged

var kind := "bracket"
var part_id := ""
var id: String:
	get: return part_id
	set(value): part_id = value
var assembly: Node3D:
	set(value):
		assembly = value
		resume_idle_stock_callbacks()
var definition: Dictionary = {}
var installed := true
var planned := false
var health := 100.0
var wear := 0.0
var jammed := false
var salvage_locked := false
var reserved_by := ""
var build_progress := 0.0
var salvage_progress := 0.0
var carrier: Node3D:
	set(value):
		carrier = value
		resume_idle_stock_callbacks()
var parameters: Dictionary = {}
var stored_resources: Dictionary = {}
var cargo_mass := 0.0
var charge_wh := 0.0
var fuel := 600.0
var visual: Node3D
var lamp_material: StandardMaterial3D
var ancient_energy_inlay := false
var shell_material: StandardMaterial3D
var _shape: CollisionShape3D
var _outline_mesh: MeshInstance3D
var _outline_colliders: Array[CollisionShape3D] = []
var _beam_mesh: MeshInstance3D
var _beam_colliders: Array[CollisionShape3D] = []
var _collision_cooldown := 0.0
var _mechanism_phase := 0.0
var _cargo_anchor := Vector3.ZERO
var _cargo_pose_basis := Basis.IDENTITY
var _salvage_hit_pending := false
var _cargo_scan_clock := 0.0
var gun_turret: Node3D
var gun_barrel: Node3D
var gun_muzzle: Node3D
var gun_item: Weapon
var gun_control: Node3D
var _gun_shape: CollisionShape3D
var _gun_bearing_colliders: Array[CollisionShape3D] = []
var _saved_gun: Dictionary = {}
var _saved_gun_pose := Transform3D.IDENTITY
var _saved_gun_aim := Vector2.ZERO
var _gun_saved_empty := false
var foot_controls: Array[Marker3D] = []
var _coil_visual: MeshInstance3D
var _shock_top: MeshInstance3D
var _shock_shaft: MeshInstance3D
var propulsion: Node3D
var solar: Node3D
var hydro: Node
var eye_lamp: Node3D
var beacon: Node3D
var horn: Node3D
var _authored_material: RefCounted
var _authored_material_error := ""
var _idle_stock_parked := false
var _idle_stock_owner: WeakRef


# Only explicit successful Yard storage owns this callback lease. Native body
# processing and every child callback remain enabled. No sleep/freeze inference.
func park_idle_stock_callbacks(owner: Node) -> bool:
	if _idle_stock_parked: return _idle_stock_owner != null and _idle_stock_owner.get_ref()==owner
	if not is_inside_tree() or not is_physics_processing() or not is_instance_valid(owner) or not owner.is_in_group(&"contraption_yards"): return false
	if get_script().resource_path != "res://Components/Contraptions/contraption_part.gd": return false
	if not owner.loose_parts.has(self) or owner._part_reserved(self) or not get_meta(&"stored",false): return false
	if not freeze or not installed or planned or is_instance_valid(assembly) or is_instance_valid(carrier) or _collision_cooldown!=0: return false
	if kind in ["container","bearing",FuseStock.KIND,QuickRelease.KIND] or _authored_material: return false
	if not reserved_by.is_empty() or get_meta(&"in_transit",false) or get_meta(&"awaiting_setdown",false) or get_meta(&"player_carry",false) or not str(get_meta(&"equipped_worker","")).is_empty(): return false
	_idle_stock_owner = weakref(owner)
	_idle_stock_parked = true
	set_physics_process(false)
	return true

func resume_idle_stock_callbacks() -> void:
	if not _idle_stock_parked: return
	_idle_stock_parked = false
	_idle_stock_owner = null
	set_physics_process(true)

func _enter_tree() -> void:
	resume_idle_stock_callbacks()

func _exit_tree() -> void:
	resume_idle_stock_callbacks()

static func saved_material_error(stock: Dictionary) -> String:
	if str(stock.get("kind", "")) == "ball_joint":
		var carrier_parameters: Variant = stock.get("parameters", {})
		if not carrier_parameters is Dictionary: return "Ball carrier needs physical stock parameters."
		var carrier_error := RecoveryStator.error(carrier_parameters)
		if not carrier_error.is_empty(): return carrier_error
	if str(stock.get("kind", "")) == "gyro":
		var ball_parameters: Variant = stock.get("parameters", {})
		if not ball_parameters is Dictionary: return "Ball drive needs physical stock parameters."
		var ball_error := RecoveryBallProfile.error(ball_parameters)
		if not ball_error.is_empty(): return ball_error
		var recovery: Variant = stock.get("recovery_drive", {})
		if not recovery is Dictionary: return "Ball recovery observations need a saved dictionary."
		var recovery_error := RecoveryBallDrive.state_error(recovery)
		if not recovery_error.is_empty(): return recovery_error
	if str(stock.get("kind", "")) == "gun":
		var gun_parameters: Variant = stock.get("parameters", {})
		if not gun_parameters is Dictionary: return "Gun station needs physical stock parameters."
		var bearing_error := RaisedGunStock.error(gun_parameters)
		if not bearing_error.is_empty(): return bearing_error
		var gun_error := saved_gun_part_error(stock)
		if not gun_error.is_empty(): return gun_error
	if str(stock.get("kind", "")) == "beam":
		var nested: Variant = stock.get("data", {})
		var beam_data: Dictionary = nested if nested is Dictionary else {}
		var beam_parameters: Variant = stock.get("parameters", beam_data.get("parameters", {}))
		if not beam_parameters is Dictionary: return "Beam durability needs saved material parameters."
		var beam_error := beam_durability_error(beam_parameters)
		if not beam_error.is_empty(): return beam_error
		if beam_parameters.has(BEAM_DURABILITY_KEY):
			var beam_health: Variant = stock.get("health", beam_parameters[BEAM_DURABILITY_KEY])
			if not (beam_health is int or beam_health is float) or not is_finite(float(beam_health)) or float(beam_health) < 0.0 or float(beam_health) > float(beam_parameters[BEAM_DURABILITY_KEY]):
				return "Beam condition must remain within its conserved durability."
			if beam_data.has("health") and (not (beam_data.health is int or beam_data.health is float) \
				or not is_finite(float(beam_data.health)) or absf(float(beam_data.health)-float(beam_health)) > .000001):
				return "Saved beam body and custody must agree on conserved condition."
	if not stock.has("live_material"): return ""
	var material_script: GDScript = load("res://Components/Contraptions/live_material_member.gd")
	return material_script.saved_error(stock)

static func beam_durability_error(beam_parameters: Dictionary) -> String:
	# Missing lineage is existing earned stock, including older saved offcuts.
	if not beam_parameters.has(BEAM_DURABILITY_KEY): return ""
	var capacity: Variant = beam_parameters[BEAM_DURABILITY_KEY]
	var original_capacity: float = Catalogue.all().beam.health
	if not (capacity is int or capacity is float) or not is_finite(float(capacity)) or float(capacity) <= 0.0 or float(capacity) > original_capacity:
		return "Beam durability must be finite, positive and no greater than the original stock."
	return ""

func _apply_beam_durability_definition() -> void:
	if kind != "beam": return
	definition.health = float(Catalogue.all().beam.health)
	if parameters.has(BEAM_DURABILITY_KEY) and beam_durability_error(parameters).is_empty():
		definition.health = float(parameters[BEAM_DURABILITY_KEY])

static func saved_material_tree_error(value: Variant, gun_ids: Dictionary = {}) -> String:
	if value is Dictionary:
		if value.get("scene", "") in GUN_SCENES and value.has("state"):
			var gun_error := saved_gun_record_error(value)
			if not gun_error.is_empty(): return gun_error
			var identity: String = value.state.get("item_id", "")
			if not identity.is_empty():
				if gun_ids.has(identity): return "A saved gun identity cannot have two physical owners."
				gun_ids[identity] = true
		var error := saved_material_error(value)
		if not error.is_empty(): return error
		for child: Variant in value.values():
			error = saved_material_tree_error(child, gun_ids)
			if not error.is_empty(): return error
	elif value is Array:
		for child: Variant in value:
			var error := saved_material_tree_error(child, gun_ids)
			if not error.is_empty(): return error
	return ""

static func saved_gun_record_error(data: Dictionary) -> String:
	var scene: Variant = data.get("scene", DEFAULT_GUN_SCENE)
	if not scene is String or scene not in GUN_SCENES: return "Saved gun scene does not fit a shared weapon socket."
	var packed := load(scene) as PackedScene
	if not packed: return "Saved gun scene is unavailable."
	var item := packed.instantiate() as Weapon
	if not item: return "Saved weapon is not an interchangeable gun."
	var valid := not item._validated_gun_record(data).is_empty()
	item.free()
	return "" if valid else "Saved gun ammunition, condition or mechanism is invalid."

static func saved_gun_part_error(stock: Dictionary) -> String:
	var nested: Variant = stock.get("data", stock)
	if not nested is Dictionary: return "Saved gun custody must be a record."
	var pose: Variant = _decode_gun_pose(nested.get("gun_item_pose",RaisedGunStock.default_pose_record(stock.get("parameters",{}))))
	if pose == null: return "Saved gun must retain its actual socket pose."
	var angles: Variant = nested.get("gun_aim", [0.0,0.0])
	if not angles is Array or angles.size() != 2: return "Saved gun aiming must have two finite axes."
	for angle: Variant in angles:
		if not (angle is int or angle is float) or not is_finite(float(angle)): return "Saved gun aiming must have two finite axes."
	if float(angles[0]) < GUN_YAW_STOPS.x or float(angles[0]) > GUN_YAW_STOPS.y or float(angles[1]) < GUN_PITCH_STOPS.x or float(angles[1]) > GUN_PITCH_STOPS.y: return "Saved gun aiming exceeds its physical socket stops."
	var gun: Variant = nested.get("gun_item", {})
	if not gun is Dictionary: return "Saved socket weapon must be a record."
	return "" if gun.is_empty() else saved_gun_record_error(gun)

func apply_authored_material(payload: Dictionary) -> bool:
	var material_script: GDScript = load("res://Components/Contraptions/live_material_member.gd")
	var candidate: RefCounted = material_script.new()
	_authored_material_error = candidate.attach(self,payload)
	if not _authored_material_error.is_empty():
		# A rejected native shape commit may have invalidated an earlier explicit
		# tensor. Restore the currently owned authored state on the same body.
		if _authored_material: _authored_material.reapply()
		return false
	resume_idle_stock_callbacks()
	_authored_material = candidate
	_refresh_condition()
	condition_changed.emit()
	return true

func restore_authored_material() -> bool:
	return _authored_material.reapply() if _authored_material else false

func material_native_state() -> Dictionary:
	return _authored_material.native_state() if _authored_material else {}

func material_storage_reason() -> String:
	return "Weighted deformed stock cannot be compacted: container cargo does not yet account for its actual COM and full inertia." if _authored_material else ""

func material_replacement_reason() -> String:
	return "Replacing weighted deformed stock needs an explicit material/socket transfer; keep the current body and spare unreserved." if _authored_material else ""

func material_configuration_reason() -> String:
	return _authored_material_error

func stock_condition_reason() -> String:
	if kind == "container": return CaptiveBay.validate(parameters)
	if kind == "ball_joint": return RecoveryStator.error(parameters)
	if kind == "gyro": return RecoveryBallProfile.error(parameters)
	if kind in ExcavatorStock.KINDS: return ExcavatorStock.validate(kind,parameters)
	if kind == "beam":
		var beam_error := beam_durability_error(parameters)
		if not beam_error.is_empty(): return beam_error
		var capacity: float = parameters.get(BEAM_DURABILITY_KEY, Catalogue.all().beam.health)
		if not is_equal_approx(float(definition.health), capacity) or not is_finite(health) or health < 0.0 or health > capacity:
			return "Beam condition must remain within its conserved durability."
		return ""
	if kind == CurvedRib.KIND: return CurvedRib.validate(parameters)
	if kind == OpenGrille.KIND: return OpenGrille.validate(parameters)
	if kind == StoneBallast.KIND: return StoneBallast.validate(parameters)
	if kind == FixedStrut.KIND: return FixedStrut.validate(parameters)
	if kind == BeaconGeometry.KIND: return BeaconGeometry.validate(parameters)
	if kind == HornGeometry.KIND: return HornGeometry.validate(parameters)
	if kind != FuseStock.KIND: return ""
	var invalid := FuseStock.replacement_reason(parameters)
	if not invalid.is_empty(): return invalid
	return FuseStock.pending_reason(parameters)

func _enforce_stock_condition() -> void:
	# A saved spent/invalid cartridge remains finite scrap even if its health
	# field says otherwise. A valid pending break alone is not a spent verdict.
	if kind == FuseStock.KIND and not FuseStock.replacement_reason(parameters).is_empty():
		health = 0.0

func reset_unused_mount_condition() -> void:
	if kind != FuseStock.KIND or not stock_condition_reason().is_empty(): return
	for key: String in ["fuse_mount_condition", "fuse_overload_time", "fuse_last_observation_frame", "fuse_last_overloaded", "fuse_condition_error"]:
		parameters.erase(key)

func setup(new_kind: String, new_id: String, is_installed: bool = true, params: Dictionary = {}) -> void:
	resume_idle_stock_callbacks()
	kind = new_kind
	part_id = new_id
	installed = is_installed
	planned = not installed
	parameters = params.duplicate(true)
	if kind == "gun" and RaisedGunStock.applies(parameters): _saved_gun_pose = Transform3D(Basis.IDENTITY,RaisedGunStock.ITEM_SEAT)
	definition = Catalogue.get_def(kind, parameters)
	_apply_beam_durability_definition()
	health = float(definition.health)
	_enforce_stock_condition()
	mass = float(definition.mass)
	if kind == "ball_joint" and RecoveryStator.applies(parameters):
		center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
		center_of_mass = definition.centre
		inertia = definition.inertia
	elif kind == "armor":
		center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
		center_of_mass = definition.centre
	elif kind in [CurvedRib.KIND, OpenGrille.KIND, StoneBallast.KIND, FixedStrut.KIND, BeaconGeometry.KIND, HornGeometry.KIND]:
		center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
		center_of_mass = definition.centre
		inertia = definition.inertia
	charge_wh = float(definition.capacity) if installed and kind == "battery" else 0.0
	name = "%s_%s" % [kind, part_id]
	freeze = not installed
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	collision_layer = 1 if installed else 0
	collision_mask = 1 if installed else 0
	continuous_cd = true
	linear_damp = .15
	angular_damp = .25
	if kind in ["flywheel",ExcavatorStock.ROLLER]:
		angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
		angular_damp = 0.0 # Bearing drag belongs to the stator/rotor pair.
	contact_monitor = true
	# Island triangle seams can contribute duplicate contacts; four deepest
	# reports omit supported sole edges and strand diagonal gait admission.
	# Read more existing native foot contacts without changing their forces.
	max_contacts_reported = 16 if kind == "leg_foot" else 4
	can_sleep = true
	var surface := PhysicsMaterial.new()
	surface.friction = float(definition.friction)
	surface.bounce = .02
	physics_material_override = surface
	set_meta(&"contraption_part", self)
	set_meta(&"damageable", self)
	add_to_group(&"contraption_parts")

func resize_beam(length: float) -> void:
	if _authored_material:
		_authored_material_error = "Cutting deformed stock requires a conserved weighted material split."
		return
	if kind != "beam":
		return
	var previous: float = definition.size.z
	parameters.length = clampf(length, .3, 8.0)
	definition = Catalogue.get_def(kind, parameters)
	_apply_beam_durability_definition()
	mass = float(definition.mass)
	if is_instance_valid(_beam_mesh):
		_set_beam_geometry()
		condition_changed.emit()
		return
	if is_instance_valid(_shape) and _shape.shape is BoxShape3D:
		_shape.shape.size = definition.size
	if is_instance_valid(visual):
		visual.scale.z *= float(definition.size.z) / previous
	condition_changed.emit()

func beam_section_error(section_parameters: Dictionary, capacity: float, section_health: float) -> String:
	if kind != "beam": return "Only beam stock can supply a beam section."
	if _authored_material: return "Cutting deformed stock requires a conserved weighted material split."
	var stock_error := stock_condition_reason()
	if not stock_error.is_empty(): return stock_error
	var next_parameters := section_parameters.duplicate(true)
	next_parameters[BEAM_DURABILITY_KEY] = capacity
	var geometry_error := Catalogue.BeamGeometry.validate(next_parameters)
	if not geometry_error.is_empty(): return geometry_error
	var durability_error := beam_durability_error(next_parameters)
	if not durability_error.is_empty(): return durability_error
	if not is_finite(section_health) or section_health < 0.0 or section_health > capacity:
		return "Beam condition must remain within its conserved durability."
	if not Catalogue.BeamGeometry.same_profile(parameters, next_parameters): return "A beam section must retain its stock profile."
	if float(next_parameters.get("length", 2.0)) > float(definition.size.z) + .000001: return "A beam section cannot exceed its source length."
	if capacity > float(definition.health): return "A beam section cannot exceed its source durability."
	return ""

func apply_beam_section(section_parameters: Dictionary, capacity: float, section_health: float) -> bool:
	# The Yard supplies a conserved split of the original capacity/current health
	# from each section's actual material mass. Resizing previews keeps capacity.
	if not beam_section_error(section_parameters, capacity, section_health).is_empty(): return false
	var next_parameters := section_parameters.duplicate(true)
	next_parameters[BEAM_DURABILITY_KEY] = capacity
	parameters = next_parameters
	health = section_health
	resize_beam(float(parameters.get("length", 2.0)))
	_refresh_condition()
	return true

func _set_beam_geometry() -> void:
	_beam_mesh.mesh = Catalogue.BeamGeometry.mesh(parameters)
	var shapes := Catalogue.BeamGeometry.collision_shapes(parameters)
	while _beam_colliders.size() < shapes.size():
		var collider := CollisionShape3D.new()
		collider.name = "BeamPiece%d" % _beam_colliders.size()
		add_child(collider)
		_beam_colliders.append(collider)
	while _beam_colliders.size() > shapes.size():
		var collider := _beam_colliders.pop_back() as CollisionShape3D
		remove_child(collider)
		collider.queue_free()
	for i in shapes.size(): _beam_colliders[i].shape = shapes[i]

func cut_plate(outline: Dictionary) -> void:
	if kind != "armor" or not Catalogue.PlateGeometry.cut_error(parameters, outline).is_empty(): return
	var condition: float = health / float(definition.health)
	parameters.merge(Catalogue.PlateGeometry.normalize(outline), true)
	definition = Catalogue.get_def(kind, parameters)
	health = clampf(condition, 0, 1) * float(definition.health)
	mass = float(definition.mass)
	center_of_mass = definition.centre
	if is_instance_valid(_outline_mesh): _set_plate_geometry()
	condition_changed.emit()

func _set_plate_geometry() -> void:
	_outline_mesh.mesh = Catalogue.PlateGeometry.mesh(parameters)
	var shapes := Catalogue.PlateGeometry.collision_shapes(parameters)
	while _outline_colliders.size() < shapes.size():
		var collider := CollisionShape3D.new()
		collider.name = "PlatePiece%d" % _outline_colliders.size()
		add_child(collider)
		_outline_colliders.append(collider)
	while _outline_colliders.size() > shapes.size():
		var collider := _outline_colliders.pop_back() as CollisionShape3D
		remove_child(collider)
		collider.queue_free()
	for i in shapes.size(): _outline_colliders[i].shape = shapes[i]

func _ready() -> void:
	resume_idle_stock_callbacks()
	if definition.is_empty():
		setup(kind, part_id, installed, parameters)
	_make_model()
	if kind == "gun": _sync_gun_mass()
	if kind == "wing":
		var wing := WingPhysics.new()
		wing.name = "Aerodynamics"
		add_child(wing)
	elif kind == "thruster":
		propulsion = Propulsion.new()
		propulsion.name = "Propulsion"
		add_child(propulsion)
	elif kind == "solar":
		solar = SolarCollector.new()
		solar.name = "SolarCollector"
		add_child(solar)
	elif kind == "pontoon":
		hydro = PontoonHydro.new()
		hydro.name = "ExistingBuoyancy"
		add_child(hydro)
	body_entered.connect(_on_collision)

func _material(color: Color, roughness: float = .6, metal: float = .0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.set_meta(&"base_color", color)
	m.roughness = roughness
	m.metallic = metal
	if planned:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(.11, .74, .68, .10)
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m

func _mesh(mesh: Mesh, at: Vector3, material: Material, parent: Node3D = null) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = at
	instance.material_override = material
	(parent if parent else visual).add_child(instance)
	return instance

func _box(size: Vector3, at: Vector3, material: Material) -> MeshInstance3D:
	if material == shell_material and kind == "container" and size.y > .5:
		return _mesh(AncientVisual.wall_mesh(size),at,material)
	if material == shell_material and AncientVisual.stone_family(kind):
		return _mesh(AncientVisual.carved_box(size),at,material)
	return _mesh(AncientVisual.beveled_box(size),at,material)

func _collision_box(size: Vector3, at: Vector3) -> CollisionShape3D:
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = at
	add_child(shape)
	return shape

static func _coil_mesh() -> ArrayMesh:
	if _spring_mesh:
		return _spring_mesh
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	const SEGMENTS := 96
	const SIDES := 6
	for step in SEGMENTS + 1:
		var fraction := float(step) / SEGMENTS
		var angle := fraction * TAU * 6
		var radial := Vector3(cos(angle), 0, sin(angle))
		var tangent := Vector3(-sin(angle) * .12 * TAU * 6, .6, cos(angle) * .12 * TAU * 6).normalized()
		var binormal := tangent.cross(radial).normalized()
		var centre := radial * .12 + Vector3.UP * (fraction - .5) * .6
		for side in SIDES:
			var ring_angle := float(side) / SIDES * TAU
			var normal := radial * cos(ring_angle) + binormal * sin(ring_angle)
			vertices.append(centre + normal * .013)
			normals.append(normal)
	for step in SEGMENTS:
		for side in SIDES:
			var first := step * SIDES + side
			var next := step * SIDES + (side + 1) % SIDES
			indices.append_array(PackedInt32Array([first, first + SIDES, next, next, first + SIDES, next + SIDES]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	_spring_mesh = ArrayMesh.new()
	_spring_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return _spring_mesh

func _make_model() -> void:
	visual = Node3D.new()
	visual.name = "VisibleComponent"
	add_child(visual)
	shell_material = _material(AncientVisual.shell_color(kind,parameters,definition.color), .62, .06)
	var brass := _material(AncientVisual.BRONZE, .33, .76)
	AncientPBR.bronze(brass)
	if AncientVisual.stone_family(kind) or kind in ["bracket","solar"] or kind in ExcavatorStock.KINDS:
		AncientPBR.stone(shell_material)
	var dark := _material(Color("20272a"), .68, .02)
	AncientPBR.dark(dark, kind in ["wheel","track"])
	lamp_material = _material(Color("64b9af"), .2, .35)
	lamp_material.emission_enabled = true
	lamp_material.emission = Catalogue.ENERGY
	lamp_material.emission_energy_multiplier = 0.0
	var size: Vector3 = definition.size
	_shape = CollisionShape3D.new()
	_shape.name = "PhysicalShape"
	var box := BoxShape3D.new()
	box.size = size
	_shape.shape = box
	add_child(_shape)
	if definition.get("category", "") == "tool":
		ToolModel.add_model(visual, str(definition.get("tool_model", "sledgehammer")), size)
	elif kind in ExcavatorStock.KINDS:
		ExcavatorVisual.build(self,brass)
		var pieces := ExcavatorStock.collision_pieces(kind,parameters)
		_shape.shape = pieces[0].shape
		_shape.transform = pieces[0].pose
		for index: int in range(1,pieces.size()):
			var collider := CollisionShape3D.new()
			collider.name = "ExcavatorStockShape%d"%index
			collider.shape = pieces[index].shape
			collider.transform = pieces[index].pose
			add_child(collider)
		if kind == ExcavatorStock.ROLLER:
			var contact := ExcavatorContact.new()
			contact.name = "NativeToothContacts"
			add_child(contact)
			contact.configure(self)
	elif kind == "light":
		eye_lamp = EyeLampVisual.new()
		eye_lamp.name = "PoweredEyeLens"
		visual.add_child(eye_lamp)
		eye_lamp.build(self, brass, dark, lamp_material)
	elif kind == BeaconGeometry.KIND:
		beacon = BeaconVisual.new()
		beacon.name = "PoweredWorkshopBeacon"
		visual.add_child(beacon)
		beacon.build(self, brass, lamp_material)
		var beacon_shapes := BeaconGeometry.collision_shapes()
		var beacon_pieces := BeaconGeometry.pieces()
		_shape.shape = beacon_shapes[0]
		_shape.position = beacon_pieces[0].position
		for index: int in range(1, beacon_shapes.size()):
			var collider := CollisionShape3D.new()
			collider.name = "BeaconHousing%d" % index
			collider.shape = beacon_shapes[index]
			collider.position = beacon_pieces[index].position
			add_child(collider)
	elif kind == HornGeometry.KIND:
		horn = SignalHorn.new()
		horn.name = "NativeFundedSignalHorn"
		visual.add_child(horn)
		horn.build(self,brass,lamp_material)
		var horn_shapes := HornGeometry.collision_shapes()
		_shape.shape = horn_shapes[0]
		for index: int in range(1,horn_shapes.size()):
			var collider := CollisionShape3D.new()
			collider.name = "SignalHornMaterial%d" % index
			collider.shape = horn_shapes[index]
			add_child(collider)
	elif kind == "switch":
		AncientVisual.build_switch(self,shell_material,brass,dark)
	elif kind == "solar":
		SolarVisual.build(self, brass, shell_material)
	elif kind == "bracket":
		AncientBracket.build(self, shell_material, brass, dark)
	elif kind == StoneBallast.KIND:
		_mesh(StoneBallast.mesh(),Vector3.ZERO,shell_material)
		_shape.shape = StoneBallast.collision_shape()
	elif kind == FixedStrut.KIND:
		var strut_meshes := FixedStrut.material_meshes()
		_mesh(strut_meshes[0],Vector3.ZERO,shell_material)
		_mesh(strut_meshes[1],Vector3.ZERO,brass)
		var strut_shapes := FixedStrut.collision_shapes()
		var strut_pieces := FixedStrut.pieces()
		_shape.shape = strut_shapes[0]
		_shape.position = strut_pieces[0].position
		for index: int in range(1,strut_shapes.size()):
			var collider := CollisionShape3D.new()
			collider.name = "SupportStrutMaterial%d" % index
			collider.shape = strut_shapes[index]
			collider.position = strut_pieces[index].position
			add_child(collider)
	elif kind == "universal":
		Universal.build(self, shell_material, brass, dark, false)
		AncientJoint.build(self, shell_material, brass, dark)
	elif kind == "quick_release":
		var latch := QuickRelease.new()
		visual.add_child(latch)
		latch.build(self,shell_material,brass,dark)
	elif kind == FuseStock.KIND:
		var pieces:=FuseStock.geometry()
		var witness:=_material(Color("d0a568"),.35,.55)
		for index:int in pieces.size():
			var piece:Dictionary=pieces[index]
			_box(piece.size,piece.position,witness if index==2 else brass if index==3 else shell_material)
			if index==0:
				box.size=piece.size
				_shape.position=piece.position
			else: _collision_box(piece.size,piece.position)
		var fuse:=FuseController.new()
		fuse.name="BreakawayFuseMonitor"
		add_child(fuse)
		fuse.configure(self,witness)
	elif kind == "pontoon":
		_box(size, Vector3.ZERO, shell_material)
		# Keep every collar inside the same sealed contact envelope; fittings do
		# not enlarge stock bounds, displace extra water or obstruct its sockets.
		for z in [-1.1, 0.0, 1.1]:
			_box(Vector3(size.x, .035, .065), Vector3(0, size.y * .5 - .0175, z), brass)
		# Fitted ceramic is supplied by the existing carved seam layer below.
	elif kind == "beam" and definition.profile != "box":
		_beam_mesh = _mesh(Catalogue.BeamGeometry.mesh(parameters), Vector3.ZERO, shell_material)
		_beam_colliders.append(_shape)
		_set_beam_geometry()
	elif kind == CurvedRib.KIND:
		var rib_meshes := CurvedRib.material_meshes()
		_mesh(rib_meshes[0], Vector3.ZERO, shell_material)
		_mesh(rib_meshes[1], Vector3.ZERO, brass)
		var rib_shapes := CurvedRib.collision_shapes()
		_shape.shape = rib_shapes[0]
		for index: int in range(1, rib_shapes.size()):
			var rib_shape := CollisionShape3D.new()
			rib_shape.name = "RibSegment%d" % index
			rib_shape.shape = rib_shapes[index]
			add_child(rib_shape)
	elif kind == OpenGrille.KIND:
		var grille_meshes := OpenGrille.material_meshes()
		_mesh(grille_meshes[0], Vector3.ZERO, shell_material)
		_mesh(grille_meshes[1], Vector3.ZERO, brass)
		var grille_shapes := OpenGrille.collision_shapes()
		var grille_bars := OpenGrille.bars()
		_shape.shape = grille_shapes[0]
		_shape.position = grille_bars[0].position
		for index: int in range(1, grille_shapes.size()):
			var grille_shape := CollisionShape3D.new()
			grille_shape.name = "GrilleBar%d" % index
			grille_shape.shape = grille_shapes[index]
			grille_shape.position = grille_bars[index].position
			add_child(grille_shape)
	elif kind == "wing":
		_mesh(Catalogue.WingGeometry.mesh(parameters), Vector3.ZERO, shell_material)
		var wing_shapes := Catalogue.WingGeometry.collision_shapes(parameters)
		_shape.shape = wing_shapes[0]
		for i in range(1, wing_shapes.size()):
			var wing_shape := CollisionShape3D.new()
			wing_shape.name = "WingHalf%d" % i
			wing_shape.shape = wing_shapes[i]
			add_child(wing_shape)
	elif kind == "armor":
		_outline_mesh = _mesh(Catalogue.PlateGeometry.mesh(parameters), Vector3.ZERO, shell_material)
		_outline_colliders.append(_shape)
		_set_plate_geometry()
	elif kind == "flywheel":
		FlywheelVisual.build(self, brass, dark, lamp_material)
		var cylinder := CylinderShape3D.new()
		cylinder.radius = float(definition.radius)
		cylinder.height = size.x
		_shape.shape = cylinder
		_shape.rotation.z = PI / 2
	elif kind == "wheel" and definition.get("wheel_profile", "offroad") != "offroad":
		AncientPBR.tyre_rubber(dark)
		_mesh(Catalogue.WheelGeometry.material_mesh(parameters, &"rubber"), Vector3.ZERO, dark)
		_mesh(Catalogue.WheelGeometry.material_mesh(parameters, &"metal"), Vector3.ZERO, brass)
		_mesh(Catalogue.WheelGeometry.material_mesh(parameters, &"stone"), Vector3.ZERO, shell_material)
		_mesh(Catalogue.WheelGeometry.material_mesh(parameters, &"inlay"), Vector3.ZERO, lamp_material)
		ancient_energy_inlay = true
		var pieces := Catalogue.WheelGeometry.collision_entries(parameters)
		_shape.shape = pieces[0].shape
		_shape.transform = pieces[0].transform
		for index in range(1, pieces.size()):
			var collider := CollisionShape3D.new()
			collider.name = "WheelPiece%d" % index
			collider.shape = pieces[index].shape
			collider.transform = pieces[index].transform
			add_child(collider)
	elif kind == "wheel":
		AncientPBR.offroad_rubber(dark)
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = float(definition.radius)
		cylinder.bottom_radius = cylinder.top_radius
		cylinder.height = size.x
		cylinder.radial_segments = 20
		_mesh(AncientVisual.wheel_tire_mesh(), Vector3.ZERO, dark)
		var collision := CylinderShape3D.new()
		collision.radius = cylinder.top_radius
		collision.height = size.x
		_shape.shape = collision
		_shape.rotation.z = PI / 2
		_mesh(AncientVisual.wheel_stone_hub_mesh(),Vector3.ZERO,shell_material)
		var treads := MultiMesh.new()
		treads.transform_format = MultiMesh.TRANSFORM_3D
		treads.mesh = AncientVisual.wheel_tread_mesh()
		treads.instance_count = 24
		for i in 24:
			var a := float(i) * TAU / 24
			treads.set_instance_transform(i, Transform3D(Basis(Vector3.RIGHT, -a), Vector3.ZERO))
		var tread_batch := MultiMeshInstance3D.new()
		tread_batch.multimesh = treads
		tread_batch.material_override = AncientPBR.offroad_tread(dark)
		visual.add_child(tread_batch)
	elif kind == "gyro":
		if RecoveryBallProfile.applies(parameters):
			RecoveryBallVisual.build(self, shell_material, brass, lamp_material)
			var sphere_shape := SphereShape3D.new()
			sphere_shape.radius = RecoveryBallProfile.RADIUS
			_shape.shape = sphere_shape
		else:
			var sphere := SphereMesh.new()
			sphere.radius = .55
			sphere.height = 1.1
			_mesh(sphere, Vector3.ZERO, shell_material)
			var shape := SphereShape3D.new()
			shape.radius = .55
			_shape.shape = shape
			for axis in [Vector3.UP, Vector3.RIGHT, Vector3.FORWARD]:
				var band := TorusMesh.new()
				band.inner_radius = .53
				band.outer_radius = .558
				var ring := _mesh(band, Vector3.ZERO, brass)
				ring.basis = Basis(Quaternion(Vector3.UP, axis))
	elif kind == "ball_joint":
		if RecoveryStator.applies(parameters):
			RecoveryStator.build(self, shell_material, brass)
		else:
			AncientJoint.build(self, shell_material, brass, dark)
	elif kind == "remote_core":
		AncientVisual.build_remote_core(self,shell_material,brass,dark)
	elif kind == "mind":
		AncientVisual.build_mind(self,shell_material,brass,dark,lamp_material)
	elif kind == "chassis":
		AncientVisual.build_chassis(self,shell_material,brass)
	elif kind in ["battery","generator"]:
		AncientVisual.build_power(self,shell_material,brass,dark)
	elif kind in ["leg_upper", "leg_lower", "leg_foot"]:
		# The same native centered boxes remain the contact, mass and carrying
		# envelopes. Four cached PBR layers replace protruding decorative balls.
		# The patina map already colours the metal. A light warm multiplier and
		# its oxide fraction keep the seated hardware readable beside the stone.
		brass.albedo_color = Color("ead4a7")
		brass.set_meta(&"base_color", brass.albedo_color)
		brass.metallic = .78
		AncientPBR.bronze(dark)
		# Weathered actuator/shoe metal stays darker than the pivot retainers,
		# without multiplying the bronze map by the near-black generic tint.
		dark.albedo_color = Color("778187")
		dark.set_meta(&"base_color", dark.albedo_color)
		dark.metallic = .55
		AncientVisual.build_leg(self, shell_material, brass, dark)
	elif kind == "container" and CaptiveBay.applies(parameters):
		CaptiveBay.build(self,shell_material,brass,lamp_material)
	elif kind == "container":
		_mesh(AncientVisual.container_side_seats_mesh(size),Vector3.ZERO,brass)
		# Empty collision volume with floor and four walls, so stored parts sit inside.
		_shape.shape = null
		_shape.queue_free()
		for spec in [
			[Vector3(size.x, .1, size.z), Vector3(0, -size.y / 2 + .05, 0)],
			[Vector3(.08, size.y, size.z), Vector3(-size.x / 2 + .04, 0, 0)],
			[Vector3(.08, size.y, size.z), Vector3(size.x / 2 - .04, 0, 0)],
			[Vector3(size.x, size.y, .08), Vector3(0, 0, -size.z / 2 + .04)],
			[Vector3(size.x, size.y, .08), Vector3(0, 0, size.z / 2 - .04)]]:
			_box(spec[0], spec[1], shell_material)
			var wall := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = spec[0]
			wall.shape = shape
			wall.position = spec[1]
			add_child(wall)
		_box(Vector3(size.x * .75, .04, .04), Vector3(0, size.y / 2, -size.z / 2 - .045), brass)
		# Rear clips belong to the existing finite container shell. Secured tools
		# stay full size outside its walls, where a planted toe can reach the handle.
		for x: float in [-.3, .3]:
			_box(Vector3(.07, .14, .08), Vector3(x, -.055, size.z * .5), brass)
			_box(Vector3(.09, .035, .13), Vector3(x, -.12, size.z * .5 + .055), dark)
	elif kind == "suspension":
		_coil_visual = _mesh(_coil_mesh(), Vector3.ZERO, brass)
		var shaft := CylinderMesh.new()
		shaft.top_radius = .035
		shaft.bottom_radius = .035
		shaft.height = .64
		_shock_shaft = _mesh(shaft, Vector3.ZERO, dark)
		for side in [-1.0, 1.0]:
			var cap := CylinderMesh.new()
			cap.top_radius = .17
			cap.bottom_radius = .17
			cap.height = .06
			var mount := _mesh(cap, Vector3(0, side * .33, 0), shell_material)
			if side > 0:
				_shock_top = mount
	elif kind == "bearing":
		if FreewheelStock.direction(parameters)!=0:
			_shape.shape = FreewheelStock.collision_shape()
			_shape.rotation.z = PI/2
		AncientJoint.build(self, shell_material, brass, dark)
	elif LinearWinchVisual.handles(kind):
		LinearWinchVisual.build(self, shell_material, brass, dark)
	elif kind in ["hinge", "motor"]:
		AncientJoint.build(self, shell_material, brass, dark)
	elif kind in ["cockpit", "station"]:
		if kind == "station":
			AncientVisual.build_utility_station(self,shell_material,brass,dark)
		else:
			AncientVisual.build_cockpit(self,shell_material,brass,dark)
		if kind == "station":
			# Use the same joined stock for visible seats and native contacts.
			# Its original five solids are remolded at conserved box volume;
			# the catalogue still owns the same 12 kg body and resources.
			var pieces := AncientVisual.utility_station_pieces(size)
			box.size = pieces[0].size
			_shape.position = pieces[0].position
			for index: int in range(1,pieces.size()):
				_collision_box(pieces[index].size,pieces[index].position)
			_make_foot_controls(size, brass)
	elif kind == "gun":
		# The shared oxide map supplies the patina. A light warm multiplier keeps
		# recessed retainers readable beside the sandstone, as on the leg pivots.
		brass.albedo_color = Color("ead4a7")
		brass.set_meta(&"base_color", brass.albedo_color)
		brass.metallic = .78
		if RaisedGunStock.low_support(parameters):
			_shape.disabled = true # Only the explicit finite new pedestal/controls remain.
		else:
			AncientVisual.build_gun_station(self, shell_material, brass, dark)
			for piece: Dictionary in AncientVisual.gun_side_foot_pieces():
				_collision_box(piece.size,piece.position)
			box.size = Vector3(.55, .12, .6)
			_shape.position = Vector3(0, -.15, 0)
			_collision_box(Vector3(.45, .25, .4), Vector3.ZERO)
		gun_turret = Node3D.new()
		gun_turret.name = "TurretYaw"
		visual.add_child(gun_turret)
		gun_barrel = Node3D.new()
		gun_barrel.name = "BarrelElevation"
		gun_barrel.position = RaisedGunStock.PIVOT if RaisedGunStock.applies(parameters) else Vector3(0, .16, -.1)
		gun_turret.add_child(gun_barrel)
		gun_control = GunControl.new()
		gun_control.name = "GunControlPoint"
		gun_control.position = Vector3(0, -.065, size.z * .25)
		visual.add_child(gun_control)
		gun_control.configure(self)
		gun_turret.rotation.y = _saved_gun_aim.x
		gun_barrel.rotation.x = _saved_gun_aim.y
		if RaisedGunStock.applies(parameters): _build_raised_gun_bearing(shell_material,brass)
		if not planned and not _gun_saved_empty: _restore_gun_item(_saved_gun, false)
		_make_foot_controls(size, brass)
	elif kind == "track":
		var belt := TrackVisual.new()
		belt.name = "ContinuousTrackBelt"
		visual.add_child(belt)
		belt.build(self, brass, dark, shell_material)
	elif kind == "thruster":
		var fan := FanVisual.new()
		fan.name = "GuardedCounterrotors"
		visual.add_child(fan)
		fan.build(self, brass, dark, lamp_material)
	else:
		_box(size, Vector3.ZERO, shell_material)
		# Real shallow tile seams replace raised strips on the working top.
	if kind not in ["battery","generator","chassis","remote_core","bracket"] and kind not in ExcavatorStock.KINDS:
		AncientVisual.dress(self,brass)
	if kind == "wheel" and definition.get("wheel_profile","offroad") == "offroad":
		_mesh(AncientVisual.wheel_hub_mesh(),Vector3.ZERO,brass)
		_mesh(AncientVisual.wheel_inlay_mesh(),Vector3.ZERO,lamp_material)
		ancient_energy_inlay = true
	_refresh_condition()


func _build_raised_gun_bearing(stone: Material, bronze: Material) -> void:
	# Reveal the original upper .45/.25/.4 native support only on this variant.
	if not RaisedGunStock.low_support(parameters): _box(Vector3(.45,.25,.4),Vector3.ZERO,stone).name = "RaisedBearingOriginalSupport"
	for index: int in RaisedGunStock.pieces(parameters).size():
		var piece: Dictionary = RaisedGunStock.pieces(parameters)[index]
		var parent: Node3D = gun_barrel if piece.frame == "pitch" else gun_turret if piece.frame == "yaw" else visual
		var mesh := _mesh(RaisedGunStock.mesh(index,parameters),Vector3.ZERO,stone if piece.material == "stone" else bronze,parent)
		mesh.name = "RaisedGunBearingStock%d"%index
		mesh.transform = piece.pose
	for entry: Dictionary in RaisedGunStock.collision_entries(parameters):
		var shape := CollisionShape3D.new()
		shape.name = "RaisedGunBearingPiece%d"%_gun_bearing_colliders.size()
		shape.shape = entry.shape
		shape.transform = visual.transform*RaisedGunStock.frame_pose(entry.frame,gun_turret.transform,gun_barrel.transform)*entry.pose
		add_child(shape)
		_gun_bearing_colliders.append(shape)

func gun_receiving_pose() -> Transform3D:
	# The same continuous shared handoff targets the variant's physical seat.
	return gun_barrel.global_transform*Transform3D(Basis.IDENTITY,RaisedGunStock.ITEM_SEAT) if RaisedGunStock.applies(parameters) else gun_barrel.global_transform

func _restore_gun_item(data: Dictionary, legacy_save: bool) -> bool:
	if kind != "gun" or not is_instance_valid(gun_barrel) or not is_instance_valid(gun_control):
		_saved_gun = (data if not data.is_empty() or not legacy_save else {"ammo": 0, "reserve": 0}).duplicate(true)
		return true
	var scene := str(data.get("scene", DEFAULT_GUN_SCENE))
	if scene not in GUN_SCENES: return false
	if is_instance_valid(gun_item):
		if gun_item.scene_file_path == scene:
			if not gun_item.restore_gun(data if not data.is_empty() else {"ammo": 0, "reserve": 0}): return false
			gun_item.transform = _saved_gun_pose
			_sync_gun_mass()
			return true
	var item := (load(scene) as PackedScene).instantiate() as Weapon
	if not item: return false
	# A saved old mounted hitscan never recorded ammunition: migrate it empty.
	# Fresh physical stock receives only the native gun's loaded magazine, no reserve.
	item.reserve = 0
	if legacy_save or not data.is_empty():
		if not item.restore_gun(data if not data.is_empty() else {"ammo": 0, "reserve": 0}):
			item.free()
			return false
	# Admit the complete incoming record before retiring an existing gun.
	# A refused saved profile must leave its original finite owner intact.
	if is_instance_valid(gun_item):
		gun_control.unlink(gun_item)
		gun_item.queue_free()
		gun_item = null
		gun_muzzle = null
	gun_barrel.add_child(item)
	item.transform = _saved_gun_pose
	gun_item = item
	gun_muzzle = item.firing_muzzle()
	gun_control.link(item)
	for mi in item.find_children("*", "GeometryInstance3D", true, false): mi.layers = 1
	_sync_gun_mass()
	return true

func gun_contact_ready(item: Weapon) -> bool:
	if not is_instance_valid(item) or not is_instance_valid(gun_barrel) or not item.is_inside_tree() or not gun_barrel.is_inside_tree(): return false
	var actual := item.global_transform
	var socket := gun_receiving_pose()
	if actual.origin.distance_to(socket.origin) > .025: return false
	if absf(actual.basis.determinant() - 1.0) > .0001 or absf(actual.basis.x.length_squared() - 1.0) > .0001 or absf(actual.basis.y.length_squared() - 1.0) > .0001 or absf(actual.basis.z.length_squared() - 1.0) > .0001: return false
	var aligned := actual.basis.orthonormalized()
	var desired := socket.basis.orthonormalized()
	return aligned.x.dot(desired.x) >= .999 and aligned.y.dot(desired.y) >= .999 and aligned.z.dot(desired.z) >= .999 and gun_envelope_clear(item, actual)

static func _decode_gun_pose(data: Variant) -> Variant:
	if not data is Dictionary: return null
	if data.is_empty(): return Transform3D.IDENTITY
	var origin: Variant = data.get("origin")
	var rotation: Variant = data.get("rotation")
	if not origin is Array or origin.size() != 3 or not rotation is Array or rotation.size() != 4: return null
	for component: Variant in origin + rotation:
		if not (component is int or component is float) or not is_finite(float(component)): return null
	var position := Vector3(origin[0], origin[1], origin[2])
	var q := Quaternion(rotation[0], rotation[1], rotation[2], rotation[3])
	if position.length() > .025 or absf(q.length_squared() - 1.0) > .0001: return null
	var axes := Basis(q.normalized())
	if axes.x.x < .999 or axes.y.y < .999 or axes.z.z < .999: return null
	return Transform3D(axes, position)

func gun_envelope_clear(item: Weapon, actual: Transform3D) -> bool:
	if not is_instance_valid(item) or not is_inside_tree(): return false
	var bounds: AABB = item.GunPhysics.envelope_local(item)
	if not bounds.position.is_finite() or not bounds.size.is_finite() or bounds.size.length() <= .001: return false
	var shape := BoxShape3D.new()
	shape.size = bounds.size.max(Vector3(.012, .012, .012))
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = actual * Transform3D(Basis.IDENTITY, bounds.get_center())
	query.collision_mask = 5 # world stock and nearby actual Wako bodies
	query.collide_with_areas = false
	var excluded: Array[RID] = [get_rid()]
	var ancestor: Node = item.get_parent()
	while is_instance_valid(ancestor):
		if ancestor is CollisionObject3D: excluded.append(ancestor.get_rid())
		ancestor = ancestor.get_parent()
	query.exclude = excluded
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()

func adopt_gun(item: Weapon, during_install := false) -> bool:
	if kind != "gun" or (planned and not during_install) or is_instance_valid(gun_item) or not is_instance_valid(item) or not item.transfer_reason().is_empty() or not is_instance_valid(gun_control): return false
	if not gun_contact_ready(item): return false
	if item.scene_file_path not in GUN_SCENES or not gun_control.link(item): return false
	var actual_pose := item.global_transform
	item.unbind_carrier()
	if item.is_equipped: item.unequip()
	if item.get_parent(): item.reparent(gun_barrel)
	else: gun_barrel.add_child(item)
	item.global_transform = actual_pose
	gun_item = item
	gun_muzzle = item.firing_muzzle()
	_gun_saved_empty = false
	health = minf(health, float(definition.health) * item.gun_state.condition)
	wear = maxf(wear, item.gun_state.wear)
	jammed = jammed or item.gun_state.jammed
	for mi in item.find_children("*", "GeometryInstance3D", true, false): mi.layers = 1
	_sync_gun_mass()
	return true

func release_gun(destination: Node3D) -> Weapon:
	if not is_instance_valid(gun_item) or not is_instance_valid(destination) or not gun_item.transfer_reason().is_empty(): return null
	_sync_gun_condition()
	var item := gun_item
	if not item.unbind_carrier() or not gun_control.unlink(item): return null
	gun_item = null
	gun_muzzle = null
	_gun_saved_empty = true
	item.reparent(destination)
	_sync_gun_mass()
	return item

func _sync_gun_mass() -> void:
	if kind != "gun": return
	if not is_instance_valid(gun_item) and is_instance_valid(_gun_shape):
		_gun_shape.disabled = true
		_gun_shape.queue_free()
		_gun_shape = null
	# Catalogue mass34kg comprises the fixed30kg socket and authored4kg Assault.
	var support_mass := maxf(.1, float(definition.mass) - 4.0)
	var payload_mass: float = gun_item.GunPhysics.mass_kg(gun_item) if is_instance_valid(gun_item) else 0.0
	var support_centre := Vector3.ZERO
	var centre := Vector3.ZERO
	var native_inertia: Vector3 = Weapon.GunPhysics.box_inertia(support_mass, definition.size)
	if RaisedGunStock.applies(parameters):
		var support: Dictionary = RaisedGunStock.support_properties(gun_turret.transform,gun_barrel.transform,parameters)
		support_mass = support.mass
		support_centre = visual.transform*support.centre
		centre = support_centre
		native_inertia = Weapon.GunPhysics.rotated_diagonal(support.inertia,visual.basis)
		var entries := RaisedGunStock.collision_entries(parameters)
		for index: int in _gun_bearing_colliders.size():
			var entry: Dictionary = entries[index]
			_gun_bearing_colliders[index].transform = visual.transform*RaisedGunStock.frame_pose(entry.frame,gun_turret.transform,gun_barrel.transform)*entry.pose
	if payload_mass > 0.0:
		# Mount-local transforms remain unchanged when the native body moves.
		# A world-space round trip otherwise rebuilds its shape/joints on float noise.
		var pose: Transform3D = visual.transform * gun_turret.transform * gun_barrel.transform * gun_item.transform
		var bounds: AABB = gun_item.GunPhysics.envelope_local(gun_item)
		if not is_instance_valid(_gun_shape):
			_gun_shape = CollisionShape3D.new()
			_gun_shape.name = "ActualGunEnvelope"
			_gun_shape.shape = BoxShape3D.new()
			add_child(_gun_shape)
		(_gun_shape.shape as BoxShape3D).size = bounds.size.max(Vector3(.012, .012, .012))
		_gun_shape.transform = pose * Transform3D(Basis.IDENTITY, bounds.get_center())
		var payload_centre: Vector3 = pose * gun_item.GunPhysics.center_local(gun_item)
		centre = (support_centre*support_mass+payload_centre*payload_mass) / (support_mass + payload_mass) if RaisedGunStock.applies(parameters) else payload_centre * payload_mass / (support_mass + payload_mass)
		native_inertia += Weapon.GunPhysics.parallel_diagonal(support_mass, support_centre-centre if RaisedGunStock.applies(parameters) else centre)
		native_inertia += Weapon.GunPhysics.rotated_diagonal(gun_item.GunPhysics.inertia_local(gun_item), pose.basis.orthonormalized()) + Weapon.GunPhysics.parallel_diagonal(payload_mass, payload_centre - centre)
	if is_equal_approx(mass, support_mass + payload_mass) and center_of_mass.is_equal_approx(centre) and inertia.is_equal_approx(native_inertia): return
	mass = support_mass + payload_mass
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = centre
	inertia = native_inertia

func gun_controller() -> Node:
	if not is_instance_valid(gun_control) or not is_instance_valid(gun_item): return null
	var operator: Node = gun_control.live_controller()
	if operator: return operator
	for worker: Node in get_tree().get_nodes_in_group(&"wako_helpers"):
		if worker.get("station") == self and gun_control.claim(worker): return worker
	if is_instance_valid(assembly) and is_instance_valid(assembly.get("mind_host")) and gun_control.claim(assembly.mind_host): return assembly.mind_host
	return null

func _sync_gun_condition() -> void:
	if not is_instance_valid(gun_item): return
	gun_item.gun_state.condition = minf(gun_item.gun_state.condition, health / float(definition.health))
	gun_item.gun_state.wear = maxf(gun_item.gun_state.wear, wear)
	gun_item.gun_state.jammed = gun_item.gun_state.jammed or jammed

func _make_foot_controls(size: Vector3, material: Material) -> void:
	for side: float in [-1.0, 1.0]:
		var point := Vector3(side * .12, -.065, size.z * .25)
		if kind not in ["gun","station"]: _box(Vector3(.17, .04, .16), point - Vector3.UP * .025, material)
		if kind != "station" and (kind != "gun" or not RaisedGunStock.low_support(parameters)): _collision_box(Vector3(.17, .04, .16), point - Vector3.UP * .025)
		var marker := Marker3D.new()
		marker.name = "FootControlLeft" if side < 0 else "FootControlRight"
		visual.add_child(marker)
		marker.position = point
		foot_controls.append(marker)

func foot_control_world(side: int = 0) -> Vector3:
	if foot_controls.is_empty(): return global_position
	return foot_controls[clampi(side, 0, foot_controls.size() - 1)].global_position

func connector_world(socket_key: Variant) -> Transform3D:
	if _authored_material: return global_transform*_authored_material.socket_pose(socket_key)
	var socket := Catalogue.socket(definition, socket_key)
	if socket.is_empty():
		return global_transform
	return Transform3D(global_basis, to_global(socket.pos))

func connector_definition(socket_key: Variant) -> Dictionary:
	return Catalogue.socket(definition, socket_key)

func set_installed(value: bool) -> void:
	resume_idle_stock_callbacks()
	installed = value
	planned = not value
	freeze = not value
	collision_layer = 1 if value else 0
	collision_mask = 1 if value else 0
	if value and _authored_material: restore_authored_material()
	build_progress = 1.0 if value else build_progress
	_refresh_condition()
	condition_changed.emit()

func _refresh_condition() -> void:
	if not shell_material:
		return
	shell_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if planned else BaseMaterial3D.TRANSPARENCY_DISABLED
	shell_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED if planned else BaseMaterial3D.SHADING_MODE_PER_PIXEL
	# Future wheels and their nested tread meshes should remain a readable plan
	# without obscuring the crew working behind them. Active work grows clearer.
	var plan_color := Color(.11, .74, .68, .10 + build_progress * .18)
	shell_material.albedo_color = plan_color if planned else AncientVisual.shell_color(kind,parameters,definition.color).lerp(Color("473932"), 1.0 - health / float(definition.health))
	if lamp_material:
		var warning_health := 35.0 * float(definition.health) / float(Catalogue.all().beam.health) if kind == "beam" else 35.0
		lamp_material.emission = Color("ff6b52") if health < warning_health or jammed else Catalogue.ENERGY
		# Actual bus funding owns emission. Loose/planned/asleep stock is ceramic.
		lamp_material.emission_energy_multiplier = 0.0
	for mesh in visual.find_children("*", "GeometryInstance3D", true, false):
		if mesh is GeometryInstance3D and mesh.material_override is StandardMaterial3D:
			var mat := mesh.material_override as StandardMaterial3D
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if planned else BaseMaterial3D.TRANSPARENCY_DISABLED
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED if planned else BaseMaterial3D.SHADING_MODE_PER_PIXEL
			if planned:
				mat.albedo_color = plan_color
			else:
				if mat != shell_material:
					mat.albedo_color = mat.get_meta(&"base_color", Color.WHITE)
				mat.albedo_color.a = 1.0
	if is_instance_valid(eye_lamp): eye_lamp._refresh_light()
	if is_instance_valid(horn): horn.refresh_state()
	if is_instance_valid(beacon): beacon._refresh_light()

func set_finish(finish: String) -> bool:
	if not Catalogue.valid_finish(kind, finish) or salvage_locked: return false
	if finish == "original": parameters.erase("finish")
	else: parameters.finish = finish
	definition.color = Catalogue.finish_color(kind, parameters)
	_refresh_condition()
	return true

func take_damage(amount: float, point: Vector3 = Vector3.INF, source: Node = null, damage_kind: StringName = &"impact") -> void:
	if damage_kind == &"pickaxe" and _salvage_hit_pending:
		_salvage_hit_pending = false
		return # The existing pickaxe calls Core.damage after the salvage receiver.
	if planned or amount <= 0:
		return
	resume_idle_stock_callbacks()
	health = maxf(health - amount, 0.0)
	if kind == "battery":
		charge_wh = minf(charge_wh, float(definition.capacity) * health / float(definition.health))
	if health < 25 and kind in ["wheel", "hinge", "motor", "track", "piston", "flywheel",ExcavatorStock.PIVOT,ExcavatorStock.ROLLER]:
		jammed = true
	if point == Vector3.INF:
		point = global_position
	_sync_gun_condition()
	damaged.emit(amount, point, source, damage_kind)
	condition_changed.emit()
	_refresh_condition()

func repair(amount: float = 100) -> void:
	_enforce_stock_condition()
	if not stock_condition_reason().is_empty(): return
	resume_idle_stock_callbacks()
	health = minf(float(definition.health), health + amount)
	wear = maxf(0, wear - amount / 100.0)
	var clear_health := 35.0 * float(definition.health) / float(Catalogue.all().beam.health) if kind == "beam" else 35.0
	if health >= clear_health:
		jammed = false
	if is_instance_valid(gun_item):
		# Only the existing paid physical part repair may service the carried gun.
		gun_item.gun_state.condition = minf(1.0, gun_item.gun_state.condition + amount / float(definition.health))
		gun_item.gun_state.wear = maxf(0.0, gun_item.gun_state.wear - amount / 100.0)
		gun_item.gun_state.jammed = jammed
	_refresh_condition()
	condition_changed.emit()

func copy_condition_from(source: RigidBody3D) -> void:
	if kind == "gun" and source.kind == "gun" and is_instance_valid(source.gun_item) and not gun_contact_ready(source.gun_item): return
	# The resource is consumed by the yard once this state has been transferred.
	# Blueprint geometry and worker occupancy belong to the destination placement.
	if kind == FuseStock.KIND and FuseStock.spent(parameters):
		_enforce_stock_condition()
		return # Replacement transfers the real spare body; copying cannot renew scrap.
	if kind == "beam" and source.kind == "beam":
		if not source.stock_condition_reason().is_empty(): return
		if source.parameters.has(BEAM_DURABILITY_KEY): parameters[BEAM_DURABILITY_KEY] = source.parameters[BEAM_DURABILITY_KEY]
		else: parameters.erase(BEAM_DURABILITY_KEY)
		_apply_beam_durability_definition()
	health = clampf(float(source.health), 0, float(definition.health))
	if kind == "armor" and source.kind == "armor":
		health = clampf(float(source.health) / float(source.definition.health), 0, 1) * float(definition.health)
	wear = float(source.wear)
	jammed = bool(source.jammed)
	fuel = float(source.fuel)
	charge_wh = clampf(float(source.charge_wh), 0, float(definition.capacity) * health / float(definition.health))
	var shape_keys := Catalogue.design_keys(kind)
	for key: Variant in source.parameters:
		if str(key) != "operator" and str(key) not in shape_keys:
			parameters[key] = source.parameters[key]
	if kind == FuseStock.KIND and source.stock_condition_reason().is_empty():
		# The consumed unused stock's old mount and observation clock cannot
		# arm a different placement. The new real mount needs fresh admission.
		reset_unused_mount_condition()
	_enforce_stock_condition()
	if is_instance_valid(horn) and is_instance_valid(source.horn): horn.restore_state(source.horn.serialize_state())
	if kind == "gun" and source.kind == "gun" and is_instance_valid(source.gun_item):
		# Legacy copy path requires pre-admitted actual contact; same-body installation needs no gun handoff.
		if is_instance_valid(gun_item):
			gun_control.unlink(gun_item)
			gun_item.queue_free()
			gun_item = null
		var actual_item: Weapon = source.release_gun(gun_barrel)
		if actual_item: adopt_gun(actual_item, true)
	var aerodynamics := get_node_or_null("Aerodynamics")
	if aerodynamics:
		aerodynamics.refresh_configuration()
	_refresh_condition()
	condition_changed.emit()

func needs_repair() -> bool:
	var gun_fault: bool = is_instance_valid(gun_item) and (gun_item.gun_state.condition < .99 or gun_item.gun_state.wear > .2 or gun_item.gun_state.jammed)
	return installed and (health < float(definition.health) - 1.0 or wear > .2 or jammed or gun_fault)

func service_safety_reason() -> String:
	# Actual native spin, independent of power/intent: an empty cell still
	# leaves dangerous stored momentum. Ordinary moving-machine work is unchanged.
	# Ghosts and secured/head fixtures follow a moving support; their kinematic
	# world angular velocity is transport, not free rotor spin.
	if planned: return ""
	if kind == "bearing":
		var hot := BrakeData.hot_reason(self)
		if not hot.is_empty(): return hot
	if is_instance_valid(assembly) and is_instance_valid(assembly.bearing_brake):
		var hot: String = assembly.bearing_brake.service_reason(self)
		if not hot.is_empty(): return hot
	if get_meta(&"stored", false) or is_instance_valid(carrier): return ""
	if kind == ExcavatorStock.ROLLER:
		if is_instance_valid(assembly):
			for connection: Node3D in assembly.connections if assembly._topology_dirty else assembly._connections_by_part.get(part_id,[]):
				if connection.broken or connection.kind!="motor" or self not in [connection.a,connection.b]: continue
				var other: RigidBody3D = connection.b if connection.a==self else connection.a
				if absf((angular_velocity-other.angular_velocity).dot(connection.motor_world_axis(0)))>.2:
					return "Stop the spiky roller before carrying, dismantling or servicing it"
				return ""
		if angular_velocity.length()>.2: return "Let the loose spiky roller stop before handling it"
	if kind == "flywheel":
		if is_instance_valid(assembly):
			for connection: Node3D in assembly.connections if assembly._topology_dirty else assembly._connections_by_part.get(part_id, []):
				if connection.broken or connection.kind != "bearing" or self not in [connection.a, connection.b]: continue
				var other: RigidBody3D = connection.b if connection.a == self else connection.a
				if absf((angular_velocity - other.angular_velocity).dot(connection.motor_world_axis(0))) > .2:
					return "Stop the spinning rotor with motor or friction braking before work"
				return ""
		if angular_velocity.length() > .2:
			return "Let the loose spinning rotor stop before carrying or servicing it"
	elif kind == "bearing" and is_instance_valid(assembly):
		for connection: Node3D in assembly.connections if assembly._topology_dirty else assembly._connections_by_part.get(part_id, []):
			if self not in [connection.a, connection.b]: continue
			var other: RigidBody3D = connection.b if connection.a == self else connection.a
			if other.kind == "flywheel":
				var reason: String = other.service_safety_reason()
				if not reason.is_empty(): return reason
	return ""

func inspect_status() -> String:
	if planned:
		return "Plan: %s • %d%% built • %s" % [definition.title, build_progress * 100, get_meta(&"needs", "compatible stored part required")]
	if salvage_locked:
		return "%s • hostile remote core locks salvage" % definition.title
	var stock_reason := stock_condition_reason()
	if kind == FuseStock.KIND and not stock_reason.is_empty():
		return "%s • %.1f kg • %s" % [definition.title, mass, stock_reason]
	var unsafe := service_safety_reason()
	var details := "\n" + unsafe if not unsafe.is_empty() else ""
	if is_instance_valid(assembly):
		var channels: String = assembly.ancient_channel_readout(self)
		if not channels.is_empty(): details += "\n" + channels
	if kind in [ExcavatorStock.PIVOT,ExcavatorStock.ROLLER] and is_instance_valid(assembly) and is_instance_valid(assembly.excavator_drive):
		details += "\n"+assembly.excavator_drive.inspect_part(self)
	var device_power_readout := false
	if kind == "gun":
		details += "\nGun socket empty" if not is_instance_valid(gun_item) else "\n%s: %d / %s rounds; %.0f%% gun condition" % [gun_item.display_name, gun_item.ammo, "unlimited" if gun_item.reserve < 0 else str(gun_item.reserve), gun_item.gun_state.condition * 100]
		if not gun_controller(): details += "\nRequires its linked gun control point and a supported operator or compatible powered mind"
	if _authored_material:
		details += "\nDeformed recovered material"
	if kind == "flywheel" and is_instance_valid(assembly) and is_instance_valid(assembly.flywheel_drive):
		details += "\n" + assembly.flywheel_drive.inspect_part(self)
	elif kind in ["hinge", "motor"] and is_instance_valid(assembly) and is_instance_valid(assembly.ground_joint_program):
		details += "\n" + assembly.ground_joint_program.inspect_part(self)
	elif kind == "bearing" and is_instance_valid(assembly) and is_instance_valid(assembly.bearing_brake):
		details += "\n" + assembly.bearing_brake.inspect_part(self)
	elif kind == "solar" and is_instance_valid(solar):
		details += "\n" + solar.inspect_status()
	elif kind == "universal":
		details += "\nPassive Y/Z bend +/-45 degrees; X shaft transmits finite torsion"
	elif kind == CurvedRib.KIND:
		details += "\nFixed 1.8 m composite arch; open interior, 24 kg; two exposed end mounts"
	elif kind == OpenGrille.KIND:
		details += "\nFixed 1.2 m composite grille; four open holes, 69.7% open area, 8 kg"
	elif kind == StoneBallast.KIND:
		details += "\nPassive counterweight: place opposite the load; adds 70 kg"
	elif kind == FixedStrut.KIND:
		details += "\nFixed 0.9 m alloy support, 12 kg; two end plates and ordinary compliant mounts"
	elif kind == "light" and is_instance_valid(eye_lamp):
		device_power_readout = true
		if health > 0 and not jammed: details += "\n" + eye_lamp.inspect_status()
	elif kind == BeaconGeometry.KIND and is_instance_valid(beacon):
		device_power_readout = true
		if health > 0 and not jammed: details += "\n" + beacon.inspect_status()
	elif kind == HornGeometry.KIND and is_instance_valid(horn):
		device_power_readout = true
		if health > 0 and not jammed: details += "\n" + horn.inspect_status()
	elif kind == "quick_release":
		details += "\n"+QuickRelease.status(self)
	elif kind == FuseStock.KIND:
		details += "\n"+FuseController.status(self)
	elif kind == "pontoon" and is_instance_valid(hydro):
		details += "\n" + hydro.inspect_status()
	if pickaxe_can_break():
		return ("%s • salvage pickaxe: %d/3 fasteners loosened • %.1f kg" % [definition.title, roundi(salvage_progress * 3), mass]) + details
	if health <= 0:
		if kind==FuseStock.KIND and not stock_condition_reason().is_empty():
			return definition.title+" | 4kg scrap; unused replacement required"+details
		if device_power_readout:
			return ("%s • 0%% condition • %.1f kg • failed: replace or repair" % [definition.title, mass]) + details
		return ("%s • failed • replace or repair" % definition.title) + details
	if jammed:
		if device_power_readout:
			return ("%s • %d%% condition • %.1f kg • jammed: Wako can service" % [definition.title, health / float(definition.health) * 100, mass]) + details
		return ("%s • mechanism jammed • Wako can service" % definition.title) + details
	if kind == "gyro" and get_meta(&"drive_fault", "") != "":
		return "%s • %s" % [definition.title, get_meta(&"drive_fault")]
	if kind == "battery":
		return "%s • %.0f/%.0f Wh • %d%% condition • %.1f kg" % [definition.title, charge_wh,
			float(definition.capacity) * health / float(definition.health), health / float(definition.health) * 100, mass]
	if kind == "generator":
		return "%s • %.0f fuel • %d%% condition • %.1f kg" % [definition.title, fuel, health / float(definition.health) * 100, mass]
	if kind == "container":
		return "%s • %.0f/%.0f kg cargo • %d%% condition • %.1f kg total" % [definition.title, cargo_mass,
			float(definition.storage_kg), health / float(definition.health) * 100, mass]
	if not device_power_readout and assembly and float(definition.power) > 0 and not assembly.has_power(self):
		return ("%s • inactive: %s" % [definition.title, assembly.power_reason(self)]) + details
	var status := "%s • %d%% condition • %.1f kg%s" % [definition.title, health / float(definition.health) * 100, mass,
		" • maintenance due" if wear > .2 else ""]
	if kind in ["leg_upper", "leg_lower", "leg_foot"] and is_instance_valid(assembly) and is_instance_valid(assembly.leg_controller):
		status += "\n" + assembly.leg_controller.inspect_part(self)
	elif kind == "track" and is_instance_valid(assembly) and is_instance_valid(assembly.track_drive):
		status += "\n" + assembly.track_drive.inspect_part(self)
	elif kind == "wing":
		var aero := get_node_or_null("Aerodynamics")
		if aero: status += "\n" + aero.inspect_status()
	elif kind == "hinge" and is_instance_valid(assembly) and is_instance_valid(assembly.flight_hardware) and assembly.flight_hardware.owns_hinge(self):
		status += "\n" + assembly.flight_hardware.inspect_part(self)
	elif is_instance_valid(propulsion):
		status += "\n" + propulsion.inspect_status()
	return status + details

func detach() -> bool:
	if salvage_locked or not bool(definition.recoverable):
		return false
	resume_idle_stock_callbacks()
	if assembly:
		assembly.remove_part(part_id)
	assembly = null
	installed = true
	planned = false
	freeze = false
	collision_layer = 1
	collision_mask = 1
	add_to_group(&"salvage_parts")
	if _authored_material: restore_authored_material()
	salvaged.emit()
	return true

func pickaxe_can_break() -> bool:
	return installed and not salvage_locked and bool(definition.get("recoverable", false)) and is_instance_valid(assembly) and (assembly.get_meta(&"disabled_donor", false) or get_meta(&"salvageable", false))

func pickaxe_hit(_point: Vector3, _normal: Vector3, _dir: Vector3) -> StringName:
	if not pickaxe_can_break():
		return &"metal"
	_salvage_hit_pending = true
	salvage_progress = minf(1, salvage_progress + 1.0 / 3.0)
	var yard := get_tree().get_first_node_in_group(&"contraption_yards")
	if salvage_progress >= .99:
		if yard and yard.has_method(&"salvage_part") and yard.salvage_part(self):
			salvaged.emit()
			return &"break"
		elif not yard and detach():
			return &"break"
	elif yard:
		yard.last_message = "%s: %d/3 fasteners loosened. Keep striking to recover it." % [definition.title, roundi(salvage_progress * 3)]
	return &"metal"

func set_carried(new_carrier: Node3D, anchor: Vector3 = Vector3(0, 1.35, 0)) -> void:
	resume_idle_stock_callbacks()
	carrier = new_carrier
	_cargo_anchor = anchor
	_cargo_pose_basis = Basis.IDENTITY
	freeze = is_instance_valid(carrier)
	collision_layer = 0 if carrier else 1
	collision_mask = 0 if carrier else 1
	if carrier:
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
	elif _authored_material:
		restore_authored_material()

func set_carried_at_pose(new_carrier: Node3D) -> void:
	# A contact binding retains the original body pose, including its basis.
	# This setter never translates, rotates or scales the physical source.
	var current := global_transform
	set_carried(new_carrier, new_carrier.to_local(current.origin))
	_cargo_pose_basis = new_carrier.global_basis.inverse()*current.basis

func carried_world_transform() -> Transform3D:
	return Transform3D(carrier.global_basis.orthonormalized()*_cargo_pose_basis,carrier.to_global(_cargo_anchor)) if is_instance_valid(carrier) else global_transform

func carried_local_transform() -> Transform3D:
	return Transform3D(_cargo_pose_basis,_cargo_anchor)

func _physics_process(delta: float) -> void:
	if kind == "gun": _sync_gun_mass()
	_collision_cooldown = maxf(0, _collision_cooldown - delta)
	if kind == "container":
		_cargo_scan_clock += delta
		if _cargo_scan_clock > .25:
			_cargo_scan_clock = 0
			_update_secured_cargo()
	if is_instance_valid(carrier):
		global_transform = carried_world_transform()
	if kind == "suspension" and is_instance_valid(assembly) and is_instance_valid(_coil_visual):
		for connection: Node in assembly._connections_by_part.get(part_id, []):
			if connection.kind == "suspension":
				var stroke := clampf(float(connection.linear_travel), -.25, .25)
				_coil_visual.scale.y = 1 - stroke / .6
				_coil_visual.position.y = -stroke * .5
				_shock_shaft.scale.y = 1 - stroke / .64
				_shock_shaft.position.y = -stroke * .5
				_shock_top.position.y = .33 - stroke
				break
	if installed and not freeze and health > 0 and assembly and assembly.active:
		wear = minf(1, wear + delta * .000006 * (1 + absf(assembly.throttle)))
		if wear >= .98:
			jammed = true
	if kind == "bearing" and not planned and not is_instance_valid(assembly):
		BrakeData.cool(self, delta)

func _update_secured_cargo() -> void:
	# Rack cargo is mechanically secured to the container. Consolidate its physical
	# mass into the container while stored; release restores the original part body.
	var carried_mass := 0.0
	var open_bay := CaptiveBay.applies(parameters)
	var weighted_offset: Vector3 = float(definition.mass) * (definition.get("centre", Vector3.ZERO) as Vector3) if open_bay else Vector3.ZERO
	var resources := {}
	for child: Node in get_children():
		if child is RigidBody3D and (child.get_meta(&"stored", false) or child.get_meta(&"secured_payload", false)):
			var resource := child as RigidBody3D
			carried_mass += resource.mass
			if child.get_meta(&"stored", false):
				var resource_kind := str(resource.get("kind"))
				resources[resource_kind] = int(resources.get(resource_kind, 0)) + 1
			# Every full-size secured stock body contributes its actual offset.
			# Physical volume admission, rather than a COM clamp, bounds custody.
			var offset: Vector3=resource.position
			weighted_offset += offset * resource.mass
	var required_mass := float(definition.mass) + carried_mass
	var required_centre := weighted_offset / required_mass if carried_mass > 0 or open_bay else Vector3.ZERO
	stored_resources = resources
	if absf(mass - required_mass) < .01 and center_of_mass.distance_to(required_centre) < .001:
		return
	cargo_mass = carried_mass
	mass = required_mass
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = required_centre
	if carried_mass <= 0 and not open_bay:
		center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_AUTO
	if is_instance_valid(assembly):
		assembly._mark_dirty()
	condition_changed.emit()

func storage_available_kg() -> float:
	return maxf(0, float(definition.get("storage_kg", 0)) - cargo_mass)

func _on_collision(body: Node) -> void:
	if _collision_cooldown > 0 or planned or not assembly or assembly.parts.size() < 2:
		return
	if body is RigidBody3D and body.get("assembly") == assembly:
		return
	# Only normal closing motion supplies impact energy. Fast rolling/grazing
	# contact is not a crash, while an incoming moving body can hit a stopped part.
	# Read bounded reported native contacts only on this enter event.
	var direct := PhysicsServer3D.body_get_direct_state(get_rid())
	if not direct: return
	var speed := 0.0
	var point := global_position
	for index in direct.get_contact_count():
		if direct.get_contact_collider_id(index) != body.get_instance_id(): continue
		var normal := direct.get_contact_local_normal(index).normalized()
		var relative := direct.get_contact_local_velocity_at_position(index)-direct.get_contact_collider_velocity_at_position(index)
		var closing := maxf(-relative.dot(normal),0.0)
		if closing>speed:
			speed=closing
			point=direct.get_contact_local_position(index)
	if speed > 7:
		take_damage(minf(35, .025 * mass * (speed - 6) * (speed - 6)), point)
		_collision_cooldown = .35

func serialize() -> Dictionary:
	var recovery: RefCounted = get_meta(&"recovery_drive") if has_meta(&"recovery_drive") else null
	var result := {"kind": kind, "id": part_id, "transform": encode_transform(global_transform), "health": health,
		"wear": wear, "jammed": jammed, "installed": installed, "progress": build_progress,
		"parameters": parameters, "stored": stored_resources, "fuel": fuel, "salvage_locked": salvage_locked,
		"reserved_by": reserved_by, "salvage_progress": salvage_progress, "charge_wh": charge_wh,
		"velocity": encode_vector(linear_velocity), "angular_velocity": encode_vector(angular_velocity)}
	if _authored_material:
		result.live_material = _authored_material.serialized()
		var direct := PhysicsServer3D.body_get_direct_state(get_rid()) if is_inside_tree() else null
		if direct and not freeze:
			result.transform = encode_transform(direct.transform)
			result.velocity = encode_vector(direct.linear_velocity)
			result.angular_velocity = encode_vector(direct.angular_velocity)
	if is_instance_valid(carrier) and is_inside_tree():
		# Preserve actual frozen-follower motion on interrupted carry restoration.
		var native:=PhysicsServer3D.body_get_direct_state(get_rid())
		if native:
			result.velocity=encode_vector(native.linear_velocity)
			result.angular_velocity=encode_vector(native.angular_velocity)
	if is_instance_valid(horn): result.horn_state = horn.serialize_state()
	if kind == "gyro" and RecoveryBallProfile.applies(parameters):
		result.recovery_drive = recovery.serialize() if recovery else get_meta(&"recovery_drive_saved", {})
	if kind == "gun":
		_sync_gun_condition()
		result.gun_item = gun_item.serialize_gun() if is_instance_valid(gun_item) else {}
		if is_instance_valid(gun_turret) and is_instance_valid(gun_barrel): result.gun_aim = [gun_turret.rotation.y, gun_barrel.rotation.x]
		if is_instance_valid(gun_item):
			var at := gun_item.position
			var q := gun_item.basis.orthonormalized().get_rotation_quaternion()
			result.gun_item_pose = {"origin":[at.x,at.y,at.z], "rotation":[q.x,q.y,q.z,q.w]}
	return result

func restore_condition(data: Dictionary) -> bool:
	var material_error := saved_material_error(data)
	if not material_error.is_empty():
		_authored_material_error = material_error
		return false
	if kind == "gyro" and RecoveryBallProfile.applies(parameters):
		var recovery: Variant = data.get("recovery_drive", {})
		if not recovery is Dictionary: return false
		set_meta(&"recovery_drive_saved", recovery.duplicate(true))
	if kind == "beam":
		var saved_parameters: Variant = data.get("parameters", parameters)
		if not saved_parameters is Dictionary: return false
		if not beam_durability_error(saved_parameters).is_empty(): return false
		if saved_parameters.has(BEAM_DURABILITY_KEY):
			var saved_health: Variant = data.get("health", saved_parameters[BEAM_DURABILITY_KEY])
			if not (saved_health is int or saved_health is float) or not is_finite(float(saved_health)) or float(saved_health) < 0.0 or float(saved_health) > float(saved_parameters[BEAM_DURABILITY_KEY]): return false
		if saved_parameters.has(BEAM_DURABILITY_KEY): parameters[BEAM_DURABILITY_KEY] = saved_parameters[BEAM_DURABILITY_KEY]
		else: parameters.erase(BEAM_DURABILITY_KEY)
		_apply_beam_durability_definition()
	if data.has("live_material"):
		_authored_material_error = saved_material_error(data)
		if not _authored_material_error.is_empty(): return false
		if not apply_authored_material(data.live_material): return false
	health = clampf(float(data.get("health", definition.health)), 0, float(definition.health))
	_enforce_stock_condition()
	wear = float(data.get("wear", 0))
	jammed = bool(data.get("jammed", false))
	build_progress = float(data.get("progress", 0))
	stored_resources = data.get("stored", {}).duplicate(true)
	fuel = float(data.get("fuel", 600))
	salvage_locked = bool(data.get("salvage_locked", false))
	reserved_by = str(data.get("reserved_by", ""))
	salvage_progress = float(data.get("salvage_progress", 0))
	charge_wh = clampf(float(data.get("charge_wh", charge_wh)), 0, float(definition.capacity) * health / float(definition.health))
	linear_velocity = decode_vector(data.get("velocity", [0, 0, 0]))
	angular_velocity = decode_vector(data.get("angular_velocity", [0, 0, 0]))
	if is_instance_valid(horn): horn.restore_state(data.get("horn_state",{}))
	if kind == "gun":
		var pose: Variant = _decode_gun_pose(data.get("gun_item_pose",RaisedGunStock.default_pose_record(parameters)))
		if pose == null: return false
		_saved_gun_pose = pose
		var angles: Variant = data.get("gun_aim", [0.0,0.0])
		if not angles is Array or angles.size() != 2: return false
		for angle: Variant in angles:
			if not (angle is int or angle is float) or not is_finite(float(angle)): return false
		if float(angles[0]) < GUN_YAW_STOPS.x or float(angles[0]) > GUN_YAW_STOPS.y or float(angles[1]) < GUN_PITCH_STOPS.x or float(angles[1]) > GUN_PITCH_STOPS.y: return false
		_saved_gun_aim = Vector2(angles[0], angles[1])
		if is_instance_valid(gun_turret): gun_turret.rotation.y = _saved_gun_aim.x
		if is_instance_valid(gun_barrel): gun_barrel.rotation.x = _saved_gun_aim.y
		var saved: Variant = data.get("gun_item", {})
		if not saved is Dictionary: return false
		_gun_saved_empty = data.has("gun_item") and saved.is_empty()
		if _gun_saved_empty:
			if is_instance_valid(gun_item):
				gun_control.unlink(gun_item)
				gun_item.queue_free()
			gun_item = null
			gun_muzzle = null
		elif not _restore_gun_item(saved, not data.has("gun_item")): return false
	resume_idle_stock_callbacks()
	_refresh_condition()
	return true

static func encode_vector(v: Vector3) -> Array:
	return [v.x, v.y, v.z]

static func decode_vector(v: Variant) -> Vector3:
	if v is Vector3:
		return v
	return Vector3(float(v[0]), float(v[1]), float(v[2])) if v is Array and v.size() >= 3 else Vector3.ZERO

static func encode_transform(t: Transform3D) -> Array:
	return [encode_vector(t.origin), encode_vector(t.basis.x), encode_vector(t.basis.y), encode_vector(t.basis.z)]

static func decode_transform(t: Array) -> Transform3D:
	if t.size() < 4:
		return Transform3D.IDENTITY
	return Transform3D(Basis(decode_vector(t[1]), decode_vector(t[2]), decode_vector(t[3])).orthonormalized(), decode_vector(t[0]))

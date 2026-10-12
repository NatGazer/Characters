extends Node3D
const StockArrival := preload("res://Components/Contraptions/stock_arrival.gd")
const StockRelease := preload("res://Components/Contraptions/stock_release.gd")
var _stock_release := StockRelease.new()
const NativeHeadCustody := preload("res://Components/Contraptions/native_custody.gd")
## World-owned workshop. All resources are real bodies stored in containers;
## blueprints create ghost work sites. Workers transfer one reserved body per installation.

const Assembly := preload("res://Components/Contraptions/contraption_assembly.gd")
const Part := preload("res://Components/Contraptions/contraption_part.gd")
const Catalogue := preload("res://Components/Contraptions/part_catalog.gd")
const Plans := preload("res://Components/Contraptions/blueprints.gd")
const Coordinator := preload("res://Components/Contraptions/work_coordinator.gd")
const WorkerScene := preload("res://LogicObjects/Wako/Wako.tscn")
const Fauna := preload("res://Components/Contraptions/machine_fauna.gd")
const Builder := preload("res://Components/Contraptions/construction_ui.gd")
const ControlKeys := preload("res://Components/ShortcutsPanel/shortcut_keys.gd")
const Mount := preload("res://Components/Contraptions/contraption_vehicle.gd")
const ConstructionSite := preload("res://Components/Contraptions/construction_site.gd")
const ToolAccess := preload("res://Components/Contraptions/worker_tool_access.gd")
const FieldWorksite := preload("res://Components/Contraptions/native_worksite.gd")
const CrewTravel := preload("res://Components/Contraptions/native_crew_travel.gd")
const Companions := preload("res://Components/Contraptions/native_wako_companions.gd")
const CompanionControls := preload("res://Components/Contraptions/wako_follow_controls.gd")
const CrewRoutes := preload("res://Components/Contraptions/crew_travel_routes.gd")
const MastSupport := preload("res://Components/Contraptions/mast_construction_support.gd")
const RoofSupport := preload("res://Components/Contraptions/roof_construction_support.gd")
const PlanFit := preload("res://Components/Contraptions/construction_plan_fit.gd")
const DepotDisplay := preload("res://Components/Contraptions/depot_stock_layout.gd")
const MobileStock := preload("res://Components/Contraptions/mobile_stock_layout.gd")
const StorageCustody := preload("res://Components/Contraptions/storage_custody.gd")
const NativeCustody := preload("res://Components/Contraptions/native_custody.gd")
const BeamPreparation := preload("res://Components/Contraptions/beam_material_preparation.gd")

var assemblies: Array = []
var loose_parts: Array = []
var workers: Array = []
var enemies: Array = []
var storage: Node3D
var coordinator: Node
var builder: Node
var selected_assembly: Node3D
var work_paused := false
var last_message := "Salvage the disabled donor. Select a blueprint; Wako build and maintain automatically."
var learned_blueprints: Array = []
var _plans: Dictionary = {} # assembly instance id -> ordered component descriptors
var _reservations: Dictionary = {} # job id -> {part_id, workers}; coordinator owns execution
var _serial := 0
var _restoring := false
var _dismantling: Dictionary = {}
var _cradles: Dictionary = {}
var _construction_jigs: Dictionary = {} # assembly -> passive carrier -> finite native worksite support
var _ready_done := false
var _setdown_clock := 0.0
var maintenance_clock := 0.0
var _signs: Array[Label3D] = []
var _workshop_sign: Label3D
var _field_worksite:Dictionary = {}
var _field_observation:Dictionary = {}
var _field_observation_tick := -1
var _field_container_pose := Transform3D.IDENTITY
var _field_root_pose := Transform3D.IDENTITY
var _crew_travel := CrewTravel.new()
var _companions := Companions.new()

func select_assembly(identity: int) -> bool:
	# Picker entries retain object identity, never a changing array index.
	var candidate: Variant = instance_from_id(identity) if identity > 0 else null
	if not is_instance_valid(candidate) or not candidate is Node3D or candidate.is_queued_for_deletion() \
		or not assemblies.has(candidate) or candidate.get_meta(&"disabled_donor", false) or candidate.parts.is_empty():
		return false
	selected_assembly = candidate
	return true

func worker_follow_active(worker: Node) -> bool:
	return _companions.assigned(worker)

func worker_follow_parking(worker: RigidBody3D) -> Dictionary:
	return _companions.parking(worker)

func worker_follow_idle(worker: RigidBody3D) -> bool:
	return _companions.tick(worker)

func set_worker_follow(worker: RigidBody3D, follow: bool = true) -> bool:
	return set_worker_companion_mode(worker, "follow" if follow else "stay")

func set_worker_companion_mode(worker: RigidBody3D, mode: String) -> bool:
	if not is_instance_valid(worker) or not workers.has(worker) or mode not in ["work", "follow", "stay"]: return false
	if _crew_travel.assigned(worker):
		_crew_travel.cancel("Player selected companion travel; original crew route released at current native positions.")
		_crew_travel.state.active = false
	return _companions.set_mode(worker, mode)

func crew_travel_active() -> bool:
	return _crew_travel.active()

func crew_travel_worker(worker:Node) -> bool:
	return _crew_travel.assigned(worker)

func crew_travel_context() -> Dictionary:
	return _crew_travel.context()

func crew_travel_idle(worker:Node) -> bool:
	return _crew_travel.idle(worker)

func crew_travel_parking(worker:Node3D) -> Dictionary:
	return _crew_travel.parking(worker)

func crew_travel_start(anchor:RigidBody3D,points:Array[Vector3],goals:Array[Vector3],entries:Array=[]) -> bool:
	return _crew_travel.begin(anchor,workers.duplicate(),points,goals,entries)

func crew_travel_request(anchor:RigidBody3D) -> bool:
	var route:=CrewRoutes.make(self,anchor)
	if route.has("reason"): last_message=route.reason; return false
	return crew_travel_start(anchor,route.points,route.goals,route.get("entries",[]))

func crew_visit_water_request(point:Vector3) -> bool:
	var route:=CrewRoutes.water_shore(self,point)
	if route.has("reason"): last_message=route.reason; return false
	return _crew_travel.begin_water_shore(route.shore,route.wet,workers.duplicate(),route.points,route.goals,route.get("entries",[]))

func crew_return_water_request() -> bool:
	return _crew_travel.request_water_return()

func crew_travel_cancel(reason:String="Crew travel canceled; the original helpers remain here.") -> void:
	_crew_travel.cancel(reason)

func crew_travel_resume() -> bool:
	return _crew_travel.resume()

func worksite_active() -> bool:
	return not _field_worksite.is_empty()

func leave_field_worksite() -> bool:
	if not worksite_active(): return true
	var reason := _legacy_worksite_reason()
	if not reason.is_empty():
		last_message = reason
		return false
	_field_worksite.clear()
	_field_observation.clear()
	_field_observation_tick = -1
	return true

func _legacy_worksite_reason() -> String:
	if is_instance_valid(coordinator) and not coordinator.active_jobs.is_empty():
		return "Finish or cancel field work before returning to the original workshop."
	var assigned:Array = _field_worksite.get("crew",[])
	if assigned.is_empty(): assigned = workers.map(func(w:Node)->String:return w.worker_id)
	for worker_id:Variant in assigned:
		var matches:Array = workers.filter(func(w:Node)->bool:return is_instance_valid(w) and w.worker_id == worker_id)
		if matches.size()!=1:
			return "Bring the assigned real crew back before changing worksite."
		var worker:Node = matches[0]
		if worker.global_position.distance_to(global_position)>12 or not worker.on_ground or worker.linear_velocity.length()>.25 \
			or absf(worker._ground_point.y-global_position.y)>.16 or worker.paused or not worker.is_available() \
			or not worker.action.is_empty() or worker.carrying or is_instance_valid(worker.station):
			return "Return the original crew to supported ground within 12 m of the workshop and let them stop."
	return ""

func worksite_context(force:bool = false) -> Dictionary:
	if not worksite_active(): return {}
	var anchor:RigidBody3D = FieldWorksite.resolve_anchor(self,_field_worksite.get("anchor"))
	if not is_instance_valid(anchor): return {"reason":"The exact field container departed or disconnected.","crew_ids":_field_worksite.get("crew",[])}
	var root:RigidBody3D = anchor.assembly.root_part()
	# Reuse one native observation within this exact physics frame only. Motion,
	# topology/condition changes and explicit admission/contact checks invalidate
	# it; later frames always observe today's supporting terrain again.
	var current_tick := Engine.get_physics_frames()
	if not force and current_tick == _field_observation_tick and not anchor.assembly._topology_dirty \
		and anchor.global_transform == _field_container_pose and root.global_transform == _field_root_pose \
		and anchor.linear_velocity.length() <= .25 and anchor.angular_velocity.length() <= .1 \
		and root.linear_velocity.length() <= .25 and root.angular_velocity.length() <= .1 and anchor.health >= 20:
		return _field_observation.duplicate()
	_field_observation = FieldWorksite.anchor_frame(self,anchor)
	_field_observation.crew_ids = _field_worksite.get("crew",[]).duplicate()
	_field_observation_tick = current_tick
	_field_container_pose = anchor.global_transform
	_field_root_pose = root.global_transform
	return _field_observation.duplicate()

func worksite_worker(worker:Node) -> bool:
	if not worksite_active(): return true
	var context := worksite_context()
	return not context.has("reason") and is_instance_valid(worker) and workers.has(worker) and worker.is_inside_tree() \
		and not worker.is_queued_for_deletion() and context.crew_ids.has(worker.worker_id) \
		and worker.global_position.distance_to(context.anchor.global_position) <= 65

func worksite_unloading_context(job:Dictionary,crew:Array) -> Dictionary:
	# Read-only classification for the coordinator's bounded held-load pause.
	# Ordinary worksite_context/worker admission remains strictly stopped.
	if not worksite_active() or job.get("kind","") not in ["build","replace"] or crew.is_empty(): return {}
	var anchor:RigidBody3D = FieldWorksite.resolve_anchor(self,_field_worksite.get("anchor"))
	if not is_instance_valid(anchor): return {}
	var source:Node3D = job.get("part")
	var target:Node3D = job.get("target")
	var reservation:Dictionary = _reservations.get(job.get("id",""),{})
	if not is_instance_valid(source) or not loose_parts.has(source) or not source.get_meta(&"in_transit",false) \
		or source.get_meta(&"stored",false) or source.health<=0 or reservation.get("part_instance",0)!=source.get_instance_id() \
		or not is_instance_valid(target) or not _field_assembly(target.get("assembly"),anchor) \
		or source.global_position.distance_to(anchor.global_position)>65 or target.global_position.distance_to(anchor.global_position)>65:
		return {}
	var held := false
	var assigned:Array = _field_worksite.get("crew",[])
	var excluded:Array[RID] = []
	for worker:Node in workers:
		if is_instance_valid(worker): excluded.append(worker.get_rid())
	for worker:Node in crew:
		if not is_instance_valid(worker) or not workers.has(worker) or not worker.is_inside_tree() or worker.is_queued_for_deletion() \
			or not assigned.has(worker.worker_id) or not reservation.get("workers",[]).has(worker.get_instance_id()) \
			or worker.current_job_id!=job.id or worker.paused or worker.fear_time>0 or not worker.on_ground \
			or worker.global_position.distance_to(anchor.global_position)>65:
			return {}
		if is_instance_valid(source.carrier) and source.carrier==worker.head_anchor and worker.carrying: held=true
	if not held: return {}
	var context := FieldWorksite.unloading_frame(self,anchor)
	if context.has("reason"): return {}
	var space := get_world_3d().direct_space_state
	for worker:Node in crew:
		var ray := PhysicsRayQueryParameters3D.create(worker.global_position+Vector3.UP*.12,
			worker.global_position-Vector3.UP*(worker.ride_height+.3),1,excluded)
		var hit := space.intersect_ray(ray)
		if hit.is_empty() or hit.normal.y<.98 or absf(hit.position.y-context.floor)>.16: return {}
		if hit.collider is RigidBody3D and (hit.collider.linear_velocity.length()>.25 or hit.collider.angular_velocity.length()>.1): return {}
	context.crew_ids=assigned.duplicate()
	return context

func worksite_parking(worker:Node) -> Dictionary:
	var context := worksite_context()
	if context.has("reason"): return {"reason":context.reason}
	if not worksite_active() or not worksite_worker(worker): return {"reason":"The original helper is outside its assigned field worksite."}
	var slot:int = context.crew_ids.find(worker.worker_id)
	var space := get_world_3d().direct_space_state
	var excluded:Array[RID] = []
	for helper:Node in workers:
		if is_instance_valid(helper): excluded.append(helper.get_rid())
	var capsule := CapsuleShape3D.new()
	capsule.radius = .31
	capsule.height = 1.05
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.collision_mask = 1
	query.exclude = excluded
	for offset:Vector3 in [Vector3(-5+slot*1.3,0,4),Vector3(-5+slot*1.3,0,-4),Vector3(5-slot*1.3,0,4)]:
		var point:Vector3 = context.transform*offset
		var ray := PhysicsRayQueryParameters3D.create(point+Vector3.UP*.5,point-Vector3.UP*.35,1,excluded)
		var hit := space.intersect_ray(ray)
		if hit.is_empty() or hit.normal.y < .98 or absf(hit.position.y-context.floor)>.05: continue
		if hit.collider is RigidBody3D and (hit.collider.linear_velocity.length()>.25 or hit.collider.angular_velocity.length()>.1): continue
		query.transform = Transform3D(Basis.IDENTITY,hit.position+Vector3.UP*(worker.ride_height+.2))
		if not space.intersect_shape(query,1).is_empty(): continue
		return {"point":hit.position+Vector3.UP*worker.ride_height}
	return {"reason":"Clear supported local waiting places around the field container."}

func construction_ground_y(assembly:Node3D) -> float:
	if not is_instance_valid(assembly): return global_position.y
	if worksite_active():
		var context := worksite_context()
		if not context.has("reason") and context.anchor.assembly == assembly: return float(context.floor)
	if not assembly.has_meta(&"field_ground_y"): return global_position.y
	var owner:Node3D = _cradles.get(assembly.get_instance_id())
	if is_instance_valid(owner) and owner.get_meta(&"root_supports",false):
		return float(owner.get_meta(&"root_support_ground",assembly.get_meta(&"field_ground_y")))
	# Completed native machines can travel. Their service floor comes from the
	# current native ground beneath them, never yesterday's foundation height.
	var root:RigidBody3D = assembly.root_part()
	if not is_instance_valid(root): return float(assembly.get_meta(&"field_ground_y"))
	var excluded:Array[RID] = []
	for part:RigidBody3D in assembly.parts.values(): excluded.append(part.get_rid())
	for helper:Node in workers:
		if is_instance_valid(helper): excluded.append(helper.get_rid())
	var ray := PhysicsRayQueryParameters3D.create(root.global_position+Vector3.UP,root.global_position-Vector3.UP*6,1,excluded)
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	if hit.is_empty() or hit.normal.y < .98: return NAN
	if hit.collider is RigidBody3D and (hit.collider.linear_velocity.length()>.25 or hit.collider.angular_velocity.length()>.1): return NAN
	return float(hit.position.y)

func worksite_source(part:Node3D) -> bool:
	if not worksite_active(): return true
	var context := worksite_context()
	return not context.has("reason") and is_instance_valid(part) and loose_parts.has(part) \
		and part.get_meta(&"stored",false) and part.get_parent() == context.anchor

func _field_assembly(assembly:Node3D,anchor:RigidBody3D) -> bool:
	return is_instance_valid(assembly) and (assembly == anchor.assembly or assembly.get_meta(&"field_anchor",{}) == _field_worksite.get("anchor"))

func _field_job_reason(job:Dictionary) -> String:
	if not worksite_active(): return ""
	var context := worksite_context()
	if context.has("reason"): return context.reason
	var target:Node3D = job.get("target")
	var source:Node3D = job.get("part")
	if not is_instance_valid(target) or not is_instance_valid(source): return "Field work target or source departed."
	if target.global_position.distance_to(context.anchor.global_position)>65 or source.global_position.distance_to(context.anchor.global_position)>65:
		return "Use real local field stock and supported nearby work."
	if job.kind == "salvage":
		return "" if target == context.anchor and loose_parts.has(source) else "Return local salvage to the exact field container."
	if not _field_assembly(target.get("assembly"),context.anchor): return "This assembly belongs to the original workshop site."
	if not is_finite(construction_ground_y(target.get("assembly"))): return "Field work needs today's real level native ground."
	if job.kind in ["build","replace"]:
		var staged:bool = source.has_meta(&"staged_target") and source.get_meta(&"staged_target") == target
		var reservation:Dictionary = _reservations.get(job.id,{})
		var carried:bool = source.get_meta(&"in_transit",false) and reservation.get("part_instance",0) == source.get_instance_id() \
			and workers.any(func(w:Node)->bool:return worksite_worker(w) and reservation.get("workers",[]).has(w.get_instance_id()) \
				and w.current_job_id == job.id and ((is_instance_valid(source.carrier) and source.carrier == w.head_anchor and w.carrying) \
				or (job.get("light_pickup",false) and w.pickup.part == source and w.pickup.state in ["reaching","held","flight","caught"])))
		if not loose_parts.has(source) or not (worksite_source(source) or staged or carried): return "Store this real component in the exact field container first."
	return ""

func _physics_process(delta: float) -> void:
	_stock_release.advance()
	if not _restoring:
		_crew_travel.advance(delta)
		_companions.advance(delta)
	if not _restoring and not work_paused: maintenance_clock += delta
	_setdown_clock += delta
	if _setdown_clock < .5 or _restoring:
		return
	_setdown_clock = 0.0
	_update_sign_visibility()
	for a: Node3D in assemblies:
		if is_instance_valid(a) and _construction_jigs.get(a.get_instance_id(),{}).values().any(func(jig:Dictionary)->bool:return jig.get("mast_cuff",false) or jig.get("roof_shelf",false)):
			_refresh_construction_supports(a)
			_release_cradle_if_complete(a)
	for p: Variant in loose_parts:
		if is_instance_valid(p) and p.get_meta(&"awaiting_setdown", false):
			_release_staged_component(p, [])

func _ready() -> void:
	add_to_group(&"contraption_yards")
	_crew_travel.setup(self)
	_companions.setup(self)
	_build_storage()
	_create_donor()
	_seed_resources()
	coordinator = Coordinator.new()
	add_child(coordinator)
	coordinator.setup(self)
	for i in 3:
		spawn_worker(global_position + Vector3(-4 + i * 1.4, 1.1, 3))
	for i in 3:
		var e := Fauna.new()
		add_child(e)
		e.configure(self, ["dune_runner", "cliff_guard", "scavenger"][i], global_position + Vector3(18 + i * 5, 1.2, -16))
		enemies.append(e)
	builder = Builder.new()
	add_child(builder)
	builder.setup(self)
	var companion_controls := CompanionControls.new()
	add_child(companion_controls)
	companion_controls.setup(self)
	InputHub.device_changed.connect(_update_workshop_controls.unbind(1))
	InputHub.family_changed.connect(_update_workshop_controls.unbind(1))
	Settings.changed.connect(_workshop_binding_changed)
	_update_workshop_controls()
	_initialize_combat_effects.call_deferred()
	_ready_done = true
	GameState.register_saver(&"contraptions", serialize, restore)

func _initialize_combat_effects() -> void:
	# Reuse the world's shared pool before combat, including in the focused scene
	# where Island's normal WarmUp phase is absent.
	preload("res://Components/HandTools/WeaponFX/weapon_fx.gd").pool()

func _exit_tree() -> void:
	if is_instance_valid(GameState):
		GameState.unregister_saver(&"contraptions", self)

func _build_storage() -> void:
	storage = Node3D.new()
	storage.name = "SalvageContainer"
	add_child(storage)
	storage.position = Vector3(-7, 0, 0)
	var plinths: Array = []
	for row: Rect2 in DepotDisplay.rows():
		plinths.append([Vector3(row.get_center().x,.15,row.get_center().y),Vector3(row.size.x+.10,.30,row.size.y+.10)])
	# Original full-sized tool places remain on the native workshop ground;
	# the existing twelve-place hardware shelf retains its exact footprint.
	plinths.append([Vector3(0,.06,3.8),Vector3(6.7,.12,.55)])
	for data: Array in plinths:
		var body := StaticBody3D.new()
		storage.add_child(body)
		body.position = data[0]
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = data[1]
		shape.shape = box
		body.add_child(shape)
		var mesh := MeshInstance3D.new()
		var geom := BoxMesh.new()
		geom.size = data[1]
		mesh.mesh = geom
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(.30, .36, .36)
		material.metallic = .15
		material.roughness = .75
		mesh.material_override = material
		body.add_child(mesh)
	_label(storage, "SALVAGE DEPOT", Vector3(1.0,2.5,-2.0))
	_label(storage, "WORK TOOLS", Vector3(0,1.65,DepotDisplay.TOOL_ROW_Z+1.1))
	_workshop_sign = _label(self, "WORKSHOP", Vector3(0, 3, 0))

func _label(parent: Node3D, text: String, at: Vector3) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = preload("res://LogicObjects/Vehicles/UI/dash_style.gd").font("semi")
	l.font_size = 48
	l.pixel_size = .0025
	l.visibility_range_end = 28
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.alpha_cut = Label3D.ALPHA_CUT_DISABLED
	l.outline_size = 6
	l.outline_modulate = Color(.025, .04, .055, 1)
	l.modulate = Color(.87, .98, 1)
	parent.add_child(l)
	l.position = at
	_signs.append(l)
	return l

func _workshop_binding_changed(key: StringName, _value: Variant) -> void:
	if key in [&"controls/contraption_bench", &"controls/quick_menu", &"controls/pad_glyphs"]:
		_update_workshop_controls()

func _update_workshop_controls() -> void:
	if not is_instance_valid(_workshop_sign): return
	var prompt: String = "%s > Quick menu: Build" % InputGlyphs.text(ControlKeys.label_for(&"quick_menu")) if ControlKeys.pad_mode() else ControlKeys.label_for(&"contraption_bench")
	_workshop_sign.text = "WORKSHOP · " + prompt

func _update_sign_visibility() -> void:
	var camera := Core.camera()
	if not is_instance_valid(camera): return
	var size := camera.get_viewport().get_visible_rect().size
	for i in range(_signs.size() - 1, -1, -1):
		var sign := _signs[i]
		if not is_instance_valid(sign) or not sign.is_inside_tree():
			_signs.remove_at(i)
			continue
		if camera.is_position_behind(sign.global_position):
			sign.visible = false
			continue
		var point := camera.unproject_position(sign.global_position)
		var letter_height: float = sign.font.get_height(sign.font_size) * sign.pixel_size
		var top := camera.unproject_position(sign.global_position + camera.global_basis.y * letter_height)
		var pixels := point.distance_to(top)
		# Workshop headings should not clip at the screen edge or obscure the
		# native inspection HUD/shortcut panel. Subpixel distant glyphs also
		# shimmer under temporal upscaling; keep only readable world text.
		sign.visible = pixels >= 12 and point.x > 160 and point.x < size.x - 260 and point.y > 180 and point.y < size.y - 40
		var opacity := smoothstep(12.0, 16.0, pixels)
		sign.modulate.a = opacity
		# Label3D outlines have their own modulation. Fading just the glyph fill
		# left illegible black outlines floating over the distant machines.
		sign.outline_modulate.a = opacity

func _create_donor() -> void:
	var a := Assembly.new()
	a.name = "DisabledDonor"
	add_child(a)
	a.position = Vector3(7, 1.1, 0)
	a.set_meta(&"disabled_donor", true)
	assemblies.append(a)
	var bp := Plans.rover()
	for d: Dictionary in bp.parts:
		var p: Node = a.add_part(d.kind, Plans.transform_of(d), true, d.id)
		p.set_meta(&"salvageable", true)
		if d.id == "cell":
			p.health = float(p.definition.health) * .45
		if d.parent != "":
			a.connect_parts(d.parent, d.id, d.socket_a, d.socket_b, d.joint)
	_label(a.parts.frame, "DISABLED MACHINE\nPickaxe: three strikes · Grabber: Ctrl+E release", Vector3(0, 1.8, 0))

func _seed_resources() -> void:
	# Explicit yard stock; none is minted by blueprint selection.
	var stock := ["chassis", "wheel", "wheel", "wheel", "wheel", "battery", "cockpit",
		"container", "hinge", "beam", "station", "panel", "light", "bracket", "motor", "gun", "armor", "cable", "gyro", "ball_joint", "mind",
		"suspension", "suspension", "bearing", "assembly_tool", "assembly_tool", "assembly_tool", "salvage_tool", "salvage_tool", "access_ramp",
		"wing", "thruster", "hinge", "hinge", "track", "track", "flywheel", "solar", "solar"]
	for i in 4: stock.append_array(["leg_upper", "leg_lower", "leg_foot"])
	for kind: String in stock:
		var p := Part.new()
		p.kind = kind
		p.part_id = next_id("stock")
		add_child(p)
		loose_parts.append(p)
		store_part(p)
	var long_beam := Part.new()
	long_beam.setup("beam", next_id("stock"), true, {"length": 8.0})
	add_child(long_beam)
	loose_parts.append(long_beam)
	store_part(long_beam)
	for profile: String in ["i", "tube"]:
		var beam := Part.new()
		beam.setup("beam", next_id("stock"), true, {"length": 8.0, "profile": profile})
		add_child(beam)
		loose_parts.append(beam)
		store_part(beam)
	for profile: String in ["slick", "spiked", "paddle", "airless"]:
		var wheel := Part.new()
		wheel.setup("wheel", next_id("stock"), true, {"wheel_profile": profile})
		add_child(wheel)
		loose_parts.append(wheel)
		store_part(wheel)
	# New stock follows all established supplies, preserving their saved IDs.
	for i in 2:
		var universal := Part.new()
		universal.setup("universal", next_id("stock"), true)
		add_child(universal)
		loose_parts.append(universal)
		store_part(universal)
	# Append finite bay supplies after every existing resource so the original
	# identities and rack order remain stable. Selection never creates materials.
	var bay_stock: Array[String] = []
	for i in 6: bay_stock.append("bracket")
	for i in 13: bay_stock.append("panel")
	bay_stock.append_array(["shield", "shield", "access_ramp"])
	for kind: String in bay_stock:
		var part := Part.new()
		part.kind = kind
		part.part_id = next_id("stock")
		add_child(part)
		loose_parts.append(part)
		store_part(part)
	# New recoverable water stock follows all established and bay resource IDs.
	for i in 2:
		var pontoon := Part.new()
		pontoon.setup("pontoon",next_id("stock"),true)
		add_child(pontoon)
		loose_parts.append(pontoon)
		store_part(pontoon)
	# The protected canopy consumes more than the original eight-metre I blank.
	# A finite additional recovered blank follows every established stock ID;
	# helpers must reserve/cut it and retain its usable offcuts like other beams.
	var canopy_stock := Part.new()
	canopy_stock.setup("beam",next_id("stock"),true,{"length":5.0,"profile":"i"})
	add_child(canopy_stock)
	loose_parts.append(canopy_stock)
	store_part(canopy_stock)
	var truss_stock := Part.new()
	truss_stock.setup("beam",next_id("stock"),true,{"length":8.0,"profile":"truss","truss_phase":0.0})
	add_child(truss_stock)
	loose_parts.append(truss_stock)
	store_part(truss_stock)
	# Fixed recovered inserts follow every established stock ID. Choosing a plan
	# never turns an ordinary bearing into one-way hardware or changes its hand.
	for direction in [-1,1]:
		var stock_id := next_id("stock")
		if not Catalogue.BearingFreewheel.available(): continue
		var bearing := Part.new()
		bearing.setup("bearing",stock_id,true,{"freewheel_direction":direction})
		add_child(bearing)
		loose_parts.append(bearing)
		store_part(bearing)
	# One recovered fixed coupler follows every established resource ID.
	# Restoring a save rebuilds only its saved bodies and does not reseed stock.
	var coupler := Part.new()
	coupler.setup("quick_release",next_id("stock"),true)
	add_child(coupler)
	loose_parts.append(coupler)
	store_part(coupler)
	# Two original one-shot inserts follow every established resource identity.
	# Retirement keeps the full spent4kg body; replacement needs this finite spare.
	for index in 2:
		var fuse:=Part.new()
		fuse.setup("breakaway_fuse",next_id("stock"),true)
		add_child(fuse)
		loose_parts.append(fuse)
		store_part(fuse)
	# Two recovered fixed composite arches follow every established stock ID.
	# Ordinary restore reconstructs saved parts only; absent ribs are not seeded.
	for index in 2:
		var rib := Part.new()
		rib.setup(Catalogue.CurvedRib.KIND, next_id("stock"), true)
		add_child(rib)
		loose_parts.append(rib)
		store_part(rib)
	# Fixed open panels append identities; fullYard restores never reseed them.
	for index in 2:
		var grille := Part.new()
		grille.setup(Catalogue.OpenGrille.KIND, next_id("stock"), true)
		add_child(grille)
		loose_parts.append(grille)
		store_part(grille)
	# Two finite towers follow every established identity. Their 44 cm housing
	# uses the existing compact depot floor, leaving the twelve hardware places
	# unchanged. Restoring old saves reconstructs saved bodies without reseeding.
	for index in 2:
		var beacon := Part.new()
		beacon.setup(Catalogue.WorkshopBeacon.KIND,next_id("stock"),true,Catalogue.WorkshopBeacon.normalize())
		add_child(beacon)
		loose_parts.append(beacon)
		if not store_part(beacon): push_warning("Beacon stock could not be stored: "+last_message)
	# The .46 m bell uses the same compact floor layout, not another full-size
	# hardware place. These two finite bodies are created only in a fresh yard.
	for index in 2:
		var horn := Part.new()
		horn.setup(Catalogue.SignalHorn.KIND,next_id("stock"),true,Catalogue.SignalHorn.normalize())
		add_child(horn)
		loose_parts.append(horn)
		if not store_part(horn): push_warning("Horn stock could not be stored: "+last_message)
	# Dense stone uses the existing compact floor (70 kg is not small hardware).
	# Append two original identities only here; ordinary old saves never reseed.
	for index in 2:
		var ballast := Part.new()
		ballast.setup(Catalogue.StoneBallast.KIND,next_id("stock"),true,Catalogue.StoneBallast.normalize())
		add_child(ballast)
		loose_parts.append(ballast)
		if not store_part(ballast): push_warning("Ballast stock could not be stored: "+last_message)
	# Two fixed supports append fresh-only finite bodies. Old saves restore only
	# their own stock; the 90 cm member uses the existing compact depot floor.
	for index in 2:
		var member := Part.new()
		member.setup(Catalogue.FixedStrut.KIND,next_id("stock"),true,Catalogue.FixedStrut.normalize())
		add_child(member)
		loose_parts.append(member)
		if not store_part(member): push_warning("Support strut stock could not be stored: "+last_message)

func next_id(prefix: String = "part") -> String:
	_serial += 1
	return "%s_%d" % [prefix, _serial]

func spawn_worker(at: Vector3) -> Node:
	var w := WorkerScene.instantiate()
	return adopt_worker(w, at)

func adopt_worker(w: RigidBody3D, at: Vector3) -> Node:
	if w.get_parent() == null:
		add_child(w)
	elif w.get_parent() != self:
		w.reparent(self, true)
	w.global_position = at
	w.freeze = false
	w.collision_layer = 4
	w.collision_mask = 5
	w.paused = false
	w.set_physics_process(true)
	w.add_to_group(&"wako_helpers")
	if not workers.has(w):
		workers.append(w)
	if is_instance_valid(coordinator):
		w.configure(coordinator)
		coordinator.register_worker(w)
	return w


func _resume_cargo_callbacks(part: Node) -> void:
	if part.has_method(&"resume_idle_stock_callbacks"): part.resume_idle_stock_callbacks()
	for child: Node in part.get_children():
		if child is RigidBody3D and child.get_meta(&"stored",false): _resume_cargo_callbacks(child)

func add_loose_part(part: Node3D) -> void:
	_resume_cargo_callbacks(part)
	if not loose_parts.has(part):
		# Blueprint IDs are local to an assembly; recovered resources need unique IDs.
		for existing: Variant in loose_parts:
			if is_instance_valid(existing) and existing.part_id == part.part_id:
				part.part_id = next_id("salvage")
				break
		loose_parts.append(part)
	part.set_meta(&"stored", false)
	part.set_meta(&"salvageable", true)
	if part.get_parent() != self:
		part.reparent(self, true)

func register_wild_enemy(enemy: Node3D) -> void:
	# Streamed sites own live hostile persistence. The same registry still drives
	# crew safety; defeated loot and recruited workers are adopted by this yard.
	enemy.set_meta(&"wild_owned", true)
	enemy.yard = self
	if not enemies.has(enemy):
		enemies.append(enemy)

func unregister_wild_enemy(enemy: Node3D) -> void:
	enemies.erase(enemy)

func storage_plan(part: Node3D,bay: Node3D) -> Dictionary:
	return StorageCustody.plan(self,part,bay)

func reserve_storage_pose(part: Node3D,bay: Node3D,job_id: String) -> Dictionary:
	return StorageCustody.claim(self,part,bay,job_id)

func store_part_at_pose(part: RigidBody3D,bay: Node3D) -> bool:
	var admitted := StorageCustody.admit(self,part,bay)
	if admitted: part.remove_meta(&"returning_released_stock")
	return admitted

func store_part(part: Node3D, bay_override: Node3D = null) -> bool:
	if not is_instance_valid(part) or part.is_queued_for_deletion():
		return false
	var material_reason: String = part.material_storage_reason()
	if not material_reason.is_empty():
		last_message = material_reason
		return false
	if not loose_parts.has(part):
		loose_parts.append(part)
	var bay: Node3D = bay_override if bay_override else _storage_for_parts(part)
	if not is_instance_valid(bay):
		last_message = "Stop the exact field container and clear real capacity before storing this local component."
		return false
	var mobile_tool: bool = bay is RigidBody3D and part.definition.get("category", "") == "tool"
	if mobile_tool and not ToolAccess.has_space(part, bay, loose_parts):
		last_message = "Container tool clip occupied: clear its service tool or use the salvage depot."
		return false
	if bay is RigidBody3D and bay != part.get_parent():
		bay._update_secured_cargo()
		if bay.storage_available_kg() + .001 < part.mass:
			last_message = "Container full: %.0f kg required, %.0f kg available. Add a container or use the salvage depot." % [part.mass, bay.storage_available_kg()]
			return false
	var hardware_slot := -1
	var small_hardware: bool = bay == storage and _small_hardware(part)
	if small_hardware:
		var occupied: Dictionary = {}
		for other: Node3D in loose_parts:
			if other != part and is_instance_valid(other) and other.get_parent() == bay and other.get_meta(&"stored", false) and other.has_meta(&"hardware_slot"):
				occupied[int(other.get_meta(&"hardware_slot"))] = true
		var preferred: int = part.get_meta(&"hardware_slot", -1)
		if preferred >= 0 and preferred < 12 and not occupied.has(preferred): hardware_slot = preferred
		else:
			for slot in 12:
				if not occupied.has(slot): hardware_slot = slot; break
		if hardware_slot < 0:
			last_message = "Hardware shelf full: clear one of its twelve small-part places."
			return false
	var depot_display := {}
	var mobile_placement := {}
	var tool_placement := {}
	var depot_stock: bool = bay == storage and not small_hardware and part.definition.get("category", "") != "tool"
	if depot_stock:
		depot_display = DepotDisplay.plan(part,bay,loose_parts)
		if depot_display.has("reason"):
			last_message = depot_display.reason
			return false
	elif bay is RigidBody3D and not mobile_tool:
		mobile_placement = MobileStock.plan(part,bay,loose_parts)
		if mobile_placement.has("reason"):
			last_message = mobile_placement.reason
			return false
	elif bay==storage and part.definition.get("category","")=="tool":
		if _restoring:
			# Reconstruction secures the decoded original pose, including the
			# legacy tool floor. Only fresh stock or a real later return chooses
			# the separate bay; loading a save may not migrate native bodies.
			tool_placement={"placement":{"pose":bay.global_transform.affine_inverse()*part.global_transform}}
		else:
			tool_placement=StorageCustody.plan(self,part,bay)
		if tool_placement.has("reason"):
			last_message=tool_placement.reason
			return false
		DepotDisplay.prepare(part)
		MobileStock.prepare(part)
	else:
		DepotDisplay.prepare(part)
		MobileStock.prepare(part)
	part.set_carried(null)
	NativeCustody.reparent_preserving_native(part,bay)
	# A world depot secures real, queryable native stock on its floor plinths.
	# Inside-bin cargo is fully contained in the native shell and contributes
	# mass once through its existing custody scanner, at its actual offset.
	part.freeze = true
	part.collision_layer = 1 if bay == storage else 0
	part.collision_mask = 1 if bay == storage else 0
	if depot_stock:
		MobileStock.prepare(part)
		DepotDisplay.place(part,depot_display)
	elif not mobile_placement.is_empty():
		DepotDisplay.prepare(part)
		MobileStock.place(part,mobile_placement)
	part.remove_meta(&"hardware_slot")
	if small_hardware:
		# Preserve this body's real size and position before the grounded toe pickup;
		# no expanded rack part is presented overhead or moved closer to the worker.
		part.scale = Vector3.ONE
		part.rotation = Vector3.ZERO
		part.position = Vector3((hardware_slot - 5.5) * .55, .135 + float(part.definition.size.y) * .5, 3.8)
		part.set_meta(&"hardware_slot", hardware_slot)
	if part.definition.get("category", "") == "tool" and bay == storage:
		# Permanent ground places have clear full-size pickaxe heads. Reuse a
		# genuinely empty place rather than counting occupants into an overlap.
		part.transform=tool_placement.placement.pose
	if mobile_tool: ToolAccess.store(part, bay)
	else: part.remove_meta(&"stored_tool_rack")
	part.set_meta(&"stored", true)
	part.remove_meta(&"returning_released_stock")
	part.set_meta(&"rack_scale", false)
	# Successful native custody ends an interrupted carry/set-down. Failed
	# capacity or ownership admission returns above without changing those flags.
	part.set_meta(&"in_transit", false)
	part.remove_meta(&"awaiting_setdown")
	if bay is RigidBody3D:
		bay._update_secured_cargo()
	if part.has_method(&"park_idle_stock_callbacks"): part.park_idle_stock_callbacks(self)
	return true

func _storage_for_parts(incoming: Node3D = null) -> Node3D:
	if worksite_active():
		var field := worksite_context()
		if field.has("reason"): return null
		var bay:RigidBody3D = field.anchor
		if incoming and (incoming == bay or incoming.global_position.distance_to(bay.global_position)>65): return null
		if incoming and incoming.definition.get("category","") == "tool" and not ToolAccess.has_space(incoming,bay,loose_parts): return null
		bay._update_secured_cargo()
		return bay if bay.storage_available_kg() >= (float(incoming.mass) if incoming else 1.0) else null
	if is_instance_valid(selected_assembly):
		for p: Variant in selected_assembly.parts.values():
			if is_instance_valid(p) and p.kind == "container" and p.installed and p.health > float(p.definition.health) * .1:
				# An installed container in an unfinished assembly still shares that
				# worksite's incomplete access. Keep automatic salvage at the depot
				# until all its native components exist; manual storage stays available.
				if is_instance_valid(p.assembly) and p.assembly.parts.values().any(func(part:Node)->bool:return not part.installed): continue
				if incoming and incoming.definition.get("category", "") == "tool" and not ToolAccess.has_space(incoming, p, loose_parts): continue
				p._update_secured_cargo()
				if incoming != p and p.storage_available_kg() >= (float(incoming.mass) if incoming else 1.0):
					return p
	return storage

func prepare_cargo(part: Node3D) -> void:
	_resume_cargo_callbacks(part)
	var old_bay := part.get_parent()
	DepotDisplay.prepare(part)
	MobileStock.prepare(part)
	part.set_meta(&"rack_scale", false)
	part.set_meta(&"stored", false)
	part.remove_meta(&"stored_tool_rack")
	NativeCustody.reparent_preserving_native(part,self)
	if old_bay is RigidBody3D and old_bay.has_method(&"_update_secured_cargo"):
		old_bay._update_secured_cargo()

func release_stock_for_grabber(part: RigidBody3D) -> bool:
	if not is_instance_valid(part) or not part.get_meta(&"stored",false) or _part_reserved(part): return false
	# Owner notifications from an ordinary load must have reached the solver.
	# Refuse before custody instead of publishing a stale native frame as a move.
	if not StockArrival.arrived(part,part.global_transform): return false
	# A stopped depot or moving secured owner relinquishes the same material
	# at its actual native pose, with its measured COM/point motion.
	var motion: Dictionary=StockRelease.measured_motion(part,part.get_parent() as Node3D)
	prepare_cargo(part)
	_stock_release.release(part,[],motion)
	part.set_meta(&"player_carry",true)
	return true

func available_part(kind: String, parameters: Dictionary = {}) -> Node3D:
	var cuttable_stock: Node3D
	for p: Variant in loose_parts:
		if is_instance_valid(p) and not p.is_queued_for_deletion() and p.health > 0 and p.kind == kind and p.get_meta(&"stored", false) and not _part_reserved(p):
			if not worksite_source(p): continue
			if not material_matches(p, kind, parameters):
				continue
			if kind in ["beam", "armor"] and not Catalogue.same_shape(kind, p.parameters, parameters):
				if cuttable_stock == null or p.mass < cuttable_stock.mass:
					cuttable_stock = p
				continue
			return p
	return cuttable_stock

func material_matches(part: Node3D, kind: String, parameters: Dictionary = {}) -> bool:
	if part.kind != kind:
		return false
	if not part.stock_condition_reason().is_empty(): return false
	if not part.material_storage_reason().is_empty(): return false
	if kind == "wheel":
		return Catalogue.WheelGeometry.validate(parameters).is_empty() and Catalogue.WheelGeometry.same_shape(part.parameters, parameters)
	if kind == "wing":
		return Catalogue.WingGeometry.validate(parameters).is_empty() and Catalogue.WingGeometry.same_shape(part.parameters, parameters)
	if kind == Catalogue.CurvedRib.KIND:
		return Catalogue.CurvedRib.same_stock(part.parameters, parameters)
	if kind == Catalogue.OpenGrille.KIND:
		return Catalogue.OpenGrille.same_stock(part.parameters, parameters)
	if kind == Catalogue.StoneBallast.KIND:
		return Catalogue.StoneBallast.same_stock(part.parameters, parameters)
	if kind == Catalogue.FixedStrut.KIND:
		return Catalogue.FixedStrut.same_stock(part.parameters, parameters)
	if kind == Catalogue.WorkshopBeacon.KIND:
		return Catalogue.WorkshopBeacon.same_stock(part.parameters, parameters)
	if kind == Catalogue.SignalHorn.KIND:
		return Catalogue.SignalHorn.same_stock(part.parameters, parameters)
	if kind == "bearing":
		return Catalogue.BearingLimits.validate(parameters).is_empty() and Catalogue.BearingFreewheel.validate(parameters).is_empty() and Catalogue.BearingFreewheel.availability_error(parameters).is_empty() and Catalogue.same_shape(kind, part.parameters, parameters)
	if kind == "armor":
		return Catalogue.PlateGeometry.cut_error(part.parameters, parameters).is_empty()
	if kind != "beam":
		return true
	if not Catalogue.BeamGeometry.validate(parameters).is_empty() or not Catalogue.BeamGeometry.same_profile(part.parameters, parameters): return false
	if not Catalogue.BeamGeometry.matches_phase(part.parameters,parameters): return false
	var length := float(parameters.get("length", 2.0))
	if not is_finite(length) or length < .3 or length > 8:
		return false
	var remainder := float(part.definition.size.z) - length
	# A sub-minimum offcut cannot become a usable part. Keep the whole resource
	# instead of silently destroying mass or accepting an undersized beam.
	return is_equal_approx(remainder, 0.0) or remainder >= .3 - .00001

func _cut_beam(part: Node3D, length: float, crew: Array = []) -> bool:
	var design := Catalogue.design_parameters("beam", part.parameters)
	design.length = length
	return BeamPreparation.split(self, part, design, false, crew)

func _small_hardware(part: Node3D) -> bool:
	if part.definition.get("category", "") == "tool" or part.mass > 5.0: return false
	var size: Vector3 = Catalogue.bounds_of(part.definition).size
	return maxf(size.x, maxf(size.y, size.z)) <= .4

func _prepare_material(part: Node3D, parameters: Dictionary, crew: Array = []) -> bool:
	if not part.stock_condition_reason().is_empty(): return false
	if part.kind == "beam": return material_matches(part, "beam", parameters) and _cut_beam(part, float(parameters.get("length", 2.0)), crew)
	if part.kind != "armor": return true
	if not Catalogue.PlateGeometry.cut_error(part.parameters, parameters).is_empty(): return false
	var offcuts := Catalogue.PlateGeometry.offcuts(part.parameters, parameters)
	var original_native:=PhysicsServer3D.body_get_direct_state(part.get_rid())
	var original_com: Vector3=original_native.transform*original_native.center_of_mass_local if original_native else part.global_position
	var original_velocity: Vector3=original_native.linear_velocity if original_native else part.linear_velocity
	var original_spin: Vector3=original_native.angular_velocity if original_native else part.angular_velocity
	for outline: Dictionary in offcuts:
		var offcut := Part.new()
		offcut.setup("armor", next_id("offcut"), true, outline)
		add_child(offcut)
		offcut.global_transform = part.global_transform
		offcut.copy_condition_from(part)
		var cut_native:=PhysicsServer3D.body_get_direct_state(offcut.get_rid())
		var cut_com: Vector3=cut_native.transform*cut_native.center_of_mass_local if cut_native else offcut.global_position
		offcut.linear_velocity=original_velocity+original_spin.cross(cut_com-original_com)
		offcut.angular_velocity=original_spin
		loose_parts.append(offcut)
		# A cut leaves the conserved physical offcut at the actual cut pose.
		# Its normal salvage job later moves it to a reserved storage support.
		_stock_release.release(offcut,crew)
	part.cut_plate(parameters)
	var kept_native:=PhysicsServer3D.body_get_direct_state(part.get_rid())
	var kept_com: Vector3=kept_native.transform*kept_native.center_of_mass_local if kept_native else part.global_position
	part.linear_velocity=original_velocity+original_spin.cross(kept_com-original_com)
	part.angular_velocity=original_spin
	return true

func _part_reserved(part: Node) -> bool:
	if part.get_meta(&"awaiting_setdown", false) or not str(part.get_meta(&"equipped_worker", "")).is_empty():
		return true
	for r: Dictionary in _reservations.values():
		for instance_id: int in [int(r.get("part_instance", 0)), int(r.get("tool_instance", 0)), int(r.get("target_instance", 0))]:
			if instance_id == part.get_instance_id(): return true
			var leased: Object = instance_from_id(instance_id) if instance_id != 0 else null
			if is_instance_valid(leased) and leased is Node and (part.is_ancestor_of(leased) or leased.is_ancestor_of(part)):
				return true # A carried container and its secured contents share a lease.
	return false

func plan_blueprint(data: Dictionary, upgrade: bool = false, site_position: Variant = null, field_selection:Dictionary = {}) -> bool:
	data = data.duplicate(true)
	if site_position != null and not site_position is Vector3:
		last_message = "A build site needs a finite position."
		return false
	var error := Plans.validate(data, Catalogue.all(), selected_assembly.parts.keys() if upgrade and is_instance_valid(selected_assembly) else [])
	if error != "":
		last_message = error
		return false
	var field:Dictionary = {}
	var returning := false
	if not field_selection.is_empty():
		if upgrade or not site_position is Vector3 or field_selection.get("yard") != self:
			last_message = "A field plan needs this existing workshop owner and an exact new site."
			return false
		var anchor:RigidBody3D = FieldWorksite.resolve_anchor(self,field_selection.get("locator"))
		if not is_instance_valid(anchor) or anchor != field_selection.get("anchor"):
			last_message = "The exact selected field container departed or disconnected."
			return false
		field = FieldWorksite.assess(self,anchor)
		if field.has("reason"):
			last_message = field.reason
			return false
		if to_global(site_position).distance_to(anchor.global_position)>65:
			last_message = "Keep the new plan within 65 m of the stopped field container."
			return false
		field.locator = FieldWorksite.encode_anchor(self,anchor)
	elif worksite_active() and not upgrade:
		var return_reason := _legacy_worksite_reason()
		if not return_reason.is_empty():
			last_message = return_reason
			return false
		returning = true
	elif worksite_active() and upgrade:
		var context := worksite_context(true)
		if context.has("reason") or not _field_assembly(selected_assembly,context.anchor) \
			or not is_finite(construction_ground_y(selected_assembly)):
			last_message = context.get("reason","Choose a supported assembly at the exact field container before upgrading.")
			return false
	for piece: Dictionary in data.parts:
		if piece.kind=="beam": piece.parameters = _fresh_beam_parameters(piece.get("parameters",{}))
	if upgrade and is_instance_valid(selected_assembly):
		for d: Dictionary in data.parts:
			if not selected_assembly.parts.has(d.id) and selected_assembly.parts.has(d.parent):
				var parent: Node = selected_assembly.parts[d.parent]
				if not Catalogue.compatible(Catalogue.socket(parent.definition, d.socket_a), Catalogue.socket(Catalogue.get_def(d.kind), d.socket_b)):
					last_message = "Incompatible or missing existing mounting connector for " + String(d.id)
					return false
	var a: Node3D = selected_assembly if upgrade else null
	var new_vehicle: Node3D
	if upgrade and not is_instance_valid(a):
		last_message = "Build a rover before selecting its upgrade."
		return false
	if a == null:
		var sites := 0
		for existing: Variant in assemblies:
			if is_instance_valid(existing) and not existing.get_meta(&"disabled_donor", false): sites += 1
		var proposed := Vector3((sites % 3) * 6, float(data.get("build_height", 1.1)), -3 - (sites / 3) * 7)
		if site_position is Vector3: proposed = site_position
		var site:Dictionary = ConstructionSite.validate_at(self,data,proposed,field.transform) if not field.is_empty() \
			else ConstructionSite.validate_at(self,data,proposed) if site_position is Vector3 else ConstructionSite.find(self,data,proposed)
		if site.has("reason"):
			last_message = site.reason
			return false
		if not field.is_empty():
			# Persistent identity begins only after the complete native site has
			# passed. Read-only admission/rejected selections allocate nothing.
			if String(field.anchor.assembly.get_meta(&"worksite_identity","")).is_empty():
				field.anchor.assembly.set_meta(&"worksite_identity",next_id("field_anchor"))
			field.locator = FieldWorksite.encode_anchor(self,field.anchor)
		a = Assembly.new()
		a.name = next_id("Assembly")
		a.set_meta(&"blueprint_name", String(data.get("name", "Custom machine")))
		add_child(a)
		if not field.is_empty():
			a.global_transform = site.transform
			a.set_meta(&"field_ground_y",float(site.floor))
			a.set_meta(&"field_anchor",field.locator.duplicate(true))
		else: a.position = site.position
		assemblies.append(a)
		selected_assembly = a
		_plans[a.get_instance_id()] = []
		new_vehicle = Mount.new()
		a.add_child(new_vehicle)
	var ds: Array = _plans.get(a.get_instance_id(), [])
	for d: Dictionary in data.parts:
		if a.parts.has(d.id):
			continue
		var p: Node = a.add_part(d.kind, Plans.transform_of(d), false, d.id, d.get("parameters", {}))
		if upgrade and a.root_part():
			p.global_transform = a.root_part().global_transform * Plans.transform_of(d)
			a._planned_poses[d.id] = Plans.transform_of(d)
		p.set_meta(&"plan_parent", String(d.parent))
		p.set_meta(&"plan_progress", 0.0)
		ds.append(d.duplicate(true))
	_plans[a.get_instance_id()] = ds
	if new_vehicle:
		_create_cradle(a, a.global_position)
		new_vehicle.setup(a) # Bind only after the physical root placement exists.
	_refresh_construction_supports(a)
	a.set_meta(&"workshop_speed", float(data.get("speed", 2.2)))
	a.set_meta(&"workshop_build_height", float(data.get("build_height", 1.1)))
	a.target_speed = float(data.get("speed", 2.2))
	if not field.is_empty():
		_field_worksite = {"anchor":field.locator.duplicate(true),"crew":field.crew.map(func(w:Node)->String:return w.worker_id)}
		_field_observation_tick = -1
		_crew_travel.finish_at(field.anchor)
	elif returning:
		_field_worksite.clear()
		_field_observation.clear()
		_field_observation_tick = -1
	last_message = "Plan selected: %s. Wako reserve stock, fetch it, then install each component." % data.get("name", "Custom machine")
	return true

func _create_cradle(a: Node3D, frame_position: Vector3, require_safe: bool = false, saved: Dictionary = {}) -> bool:
	# These are visible external ground supports, not a massless chassis freeze.
	var owner: Node3D = _cradles.get(a.get_instance_id())
	var profile: String = "passive_carrier" if require_safe else str(saved.get("profile","ordinary"))
	if not require_safe and saved.is_empty() and _plans.get(a.get_instance_id(),[]).any(func(piece:Dictionary)->bool:return piece.get("construction_stops",false)):
		profile = "passive_carrier"
	var had_root: bool = is_instance_valid(owner) and owner.get_meta(&"root_supports",true)
	if had_root and (profile=="ordinary" or owner.get_meta(&"cradle_profile","ordinary")==profile): return true
	var foundation: RigidBody3D = a.root_part()
	if not foundation:
		for part: RigidBody3D in a.parts.values():
			if str(part.get_meta(&"plan_parent", "")).is_empty():
				foundation = part
				break
	var size: Vector3 = foundation.definition.size if foundation else Vector3(2.4, .38, 3.2)
	var basis: Basis = foundation.global_basis if foundation else Basis.IDENTITY
	var centre: Vector3 = foundation.global_position if foundation else frame_position
	if saved.has("pose"):
		var original: Transform3D = Part.decode_transform(saved.pose)
		basis = original.basis
		centre = original.origin
	var ground_y: float = float(saved.get("ground_y",construction_ground_y(a)))
	if require_safe and (not foundation or foundation.kind!="chassis" or basis.y.dot(Vector3.UP)<.999 or foundation.linear_velocity.length()>.25 or foundation.angular_velocity.length()>.1): return false
	var cradle_pose := Transform3D(Basis(Vector3.UP,atan2(basis.z.x,basis.z.z)),Vector3(centre.x,ground_y,centre.z))
	var half_height: float = (absf(basis.x.y) * size.x + absf(basis.y.y) * size.y + absf(basis.z.y) * size.z) * .5
	var height := maxf(.1, centre.y - ground_y - half_height)
	var slender := height > 1.3
	# Narrow beam foundations need support under their ends. The old chassis-only
	# spacing missed them entirely, dropping the frame and its unfinished sockets.
	var along_beam := size.x < .5 and size.z > .8
	var span := size.z if along_beam else size.x
	var separation := span * .42 if along_beam else minf(.55 if slender else .65, span * .27)
	var supports: Array[Vector3] = []
	for side: float in [-separation, separation]:
		if along_beam:
			supports.append(Vector3(0, height * .5, side))
		else:
			# Broad frames carry rear decks and canopies during construction. Two
			# short centre stands could tip on their narrow fore/aft support band.
			for end: float in [-1.0, 1.0]: supports.append(Vector3(side, height * .5, end * minf(.9, size.z * .3)))
	if require_safe:
		# Upgrades use the observed, stationary chassis pose. Each real stand must
		# meet level ground before any carrier jig is authored beside its sockets.
		var ray := PhysicsRayQueryParameters3D.new()
		ray.collision_mask = 1
		var excluded: Array[RID] = []
		for part: RigidBody3D in a.parts.values(): excluded.append(part.get_rid())
		ray.exclude = excluded
		for at: Vector3 in supports:
			var point: Vector3 = cradle_pose*at
			ray.from = Vector3(point.x,ground_y+.08,point.z)
			ray.to = Vector3(point.x,ground_y-.2,point.z)
			var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(ray)
			if hit.is_empty() or hit.normal.y<.98 or absf(hit.position.y-ground_y)>.05 or not _static_ground(hit): return false
	if not is_instance_valid(owner):
		owner = Node3D.new()
		add_child(owner)
		_cradles[a.get_instance_id()] = owner
	owner.set_meta(&"root_supports",true)
	owner.set_meta(&"cradle_profile",profile)
	owner.set_meta(&"root_support_pose",Transform3D(basis,centre))
	owner.set_meta(&"root_support_ground",ground_y)
	var cradle := Node3D.new()
	owner.add_child(cradle)
	cradle.global_transform = cradle_pose
	if not had_root:
		for at: Vector3 in supports:
			var support_size := Vector3(minf(.18, size.x * .8), height, minf(.24, span * .12)) if along_beam else Vector3(minf(.22 if slender else .32, size.x * .4), height, minf(.55, size.z * .7))
			_add_construction_support(cradle,support_size,cradle.global_transform*Transform3D(Basis.IDENTITY,at))
	if profile=="passive_carrier" and foundation and foundation.kind=="chassis":
		# Vertical stands support weight but cannot prevent real construction forces
		# sliding a wheeled chassis off its ground-fixed output jig. Four positive
		# end stops contact the lower chassis faces, clear of tyres and centre sockets.
		var material: AABB = Transform3D(cradle_pose.basis.inverse()*basis,Vector3(0,centre.y-ground_y,0))*Catalogue.bounds_of(foundation.definition)
		var stop_height: float = material.position.y+.12
		for side: float in [-separation,separation]:
			for end: float in [material.position.z-.023,material.end.z+.023]:
				_add_construction_support(cradle,Vector3(.22,stop_height,.04),cradle.global_transform*Transform3D(Basis.IDENTITY,Vector3(side,stop_height*.5,end)))
	var changed := _on_cradled_state.bind(a)
	if not a.state_changed.is_connected(changed): a.state_changed.connect(changed)
	return true

func _add_construction_support(owner: Node3D,size: Vector3,pose: Transform3D) -> void:
	# The same visible, finite solid ground fixture serves chassis stands and
	# passive-carrier assembly jigs. It never changes the supported body's pose.
	var body := StaticBody3D.new()
	owner.add_child(body)
	body.global_transform = pose
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	var mesh := MeshInstance3D.new()
	var geometry := BoxMesh.new()
	geometry.size = size
	mesh.mesh = geometry
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(.6,.39,.14)
	material.metallic = .7
	mesh.material_override = material
	body.add_child(mesh)

func _refresh_construction_supports(a: Node3D,saved: Array = []) -> void:
	var aid: int = a.get_instance_id()
	var descriptors: Array = _plans.get(aid,[])
	var jigs: Dictionary = _construction_jigs.get(aid,{})
	var needed: Dictionary = {}
	# A weld that existed and later broke is ordinary damage. Restoring a
	# finished travelling body must not materialise fresh ground jigs under it.
	var unfinished: bool = descriptors.any(func(piece:Dictionary)->bool:
		return a.parts.has(piece.id) and (not a.parts[piece.id].installed or piece.get("secondary_mounts",[]).any(func(mount:Dictionary)->bool:return not is_instance_valid(_secondary_connection(a,piece.id,mount)))))
	for descriptor: Dictionary in descriptors:
		if (descriptor.get("construction_mast_cuff",false) or descriptor.get("construction_roof_shelf",false) or descriptor.get("construction_roof_sheet_pad",false)) and a.parts.has(descriptor.id):
			var existing: Dictionary=jigs.get(descriptor.id,{})
			var restored: bool=saved.any(func(original:Dictionary)->bool:return original.get("id","")==descriptor.id)
			var closed: bool=_construction_cuffs_closed(a,descriptor,descriptors)
			if closed and not restored and (existing.is_empty() or MastSupport.crew_clear(self,existing.get("supports",[]))):
				a.parts[descriptor.id].remove_meta(&"construction_support_reason")
				continue
			if existing.is_empty() and not restored and not _construction_dependencies_ready(a,descriptor,descriptors): continue
			# A measured roof must bind its actual material pose before fixed
			# equipment is created. Existing saved equipment retains its frame.
			if (descriptor.get("construction_roof_shelf",false) or descriptor.get("construction_roof_sheet_pad",false)) and existing.is_empty() and not restored and not descriptor.get("construction_fit_bound",false): continue
			needed[descriptor.id]=true
			continue
		if descriptor.get("construction_pad",false) and unfinished and a.parts.has(descriptor.id):
			# A future ghost does not need physical columns yet. Delaying them
			# keeps lower connector approaches clear until its real supports are
			# installed and fastened; existing installed floors retain their jigs.
			if not a.parts[descriptor.id].installed and not _construction_dependencies_ready(a,descriptor,descriptors): continue
			needed[descriptor.id] = true
			continue
		if descriptor.kind != "universal" or not a.parts.has(descriptor.id): continue
		if descriptors.any(func(child:Dictionary)->bool:return child.parent==descriptor.id and a.parts.has(child.id) and not a.parts[child.id].installed):
			needed[descriptor.id] = true
		else: a.parts[descriptor.id].remove_meta(&"construction_support_reason")
	# Even a paused worksite loses its native equipment when the original
	# supporting ground disappears; validate before any cradle early return.
	for id: String in jigs:
		var existing: Dictionary=jigs[id]
		if not (existing.get("mast_cuff",false) or existing.get("roof_shelf",false)) or not is_instance_valid(existing.node): continue
		if not MastSupport.grounded(self,a,existing.supports,existing.ground_y,_cradles.get(aid)):
			existing.node.queue_free()
			existing.node=null
			if a.parts.has(id): a.parts[id].set_meta(&"construction_support_reason","Provide fixed level native ground below the original construction equipment")
	if not needed.is_empty() and not _create_cradle(a,a.global_position,true):
		for id: String in needed: a.parts[id].set_meta(&"construction_support_reason","Stop and level the chassis on solid ground before supporting its passive carrier output")
		return
	for id: String in jigs.keys():
		if not needed.has(id):
			if is_instance_valid(jigs[id].node): jigs[id].node.queue_free()
			jigs.erase(id)
	for id: String in needed:
		var part: RigidBody3D = a.parts[id]
		var descriptor: Dictionary={}
		for piece: Dictionary in descriptors:
			if piece.id==id: descriptor=piece; break
		var cuff: bool=descriptor.get("construction_mast_cuff",false)
		var shelf: bool=descriptor.get("construction_roof_shelf",false) or descriptor.get("construction_roof_sheet_pad",false)
		var fixed_equipment: bool=cuff or shelf
		if jigs.has(id) and is_instance_valid(jigs[id].node):
			if not fixed_equipment: continue
			if MastSupport.grounded(self,a,jigs[id].supports,jigs[id].ground_y,_cradles.get(aid)): continue
			jigs[id].node.queue_free()
			jigs[id].node=null
		var pose: Transform3D = part.global_transform
		var ground_y := construction_ground_y(a)
		var roof_layout := int(descriptor.get("construction_roof_layout",1))
		if fixed_equipment and jigs.has(id):
			pose=jigs[id].pose
			ground_y=jigs[id].ground_y
			roof_layout=int(jigs[id].get("roof_layout",1))
		for original: Dictionary in saved:
			if original.get("id","")==id:
				pose = MastSupport.decode_pose(original.pose) if fixed_equipment else Part.decode_transform(original.pose)
				ground_y = float(original.ground_y)
				roof_layout = int(original.get("roof_layout",1))
				break
		var supports: Array[Dictionary]
		if fixed_equipment:
			if cuff: supports=MastSupport.geometry(pose,ground_y,float(descriptor.get("construction_mast_side",0)),float(part.definition.size.z)) if part.kind=="beam" and part.parameters.get("profile","")=="i" else []
			elif descriptor.get("construction_roof_sheet_pad",false): supports=RoofSupport.sheet_geometry(pose,ground_y,part.definition.size,float(descriptor.get("construction_roof_sheet_side",0)),roof_layout) if part.kind=="panel" else []
			else: supports=RoofSupport.geometry(pose,ground_y,float(part.definition.size.z),roof_layout) if part.kind=="beam" and part.parameters.get("profile","")=="box" else []
			if not MastSupport.grounded(self,a,supports,ground_y,_cradles.get(aid)) or (shelf and (not RoofSupport.material_clear(self,a,supports,_cradles.get(aid)) or not MastSupport.crew_clear(self,supports))):
				# Keep the original frame after invalidation. A later valid ground
				# observation may restore it, but never follow a displaced body.
				jigs[id]={"node":null,"pose":pose,"ground_y":ground_y,"supports":supports,"mast_cuff":cuff,"roof_shelf":shelf,"roof_layout":roof_layout}
				part.set_meta(&"construction_support_reason","Clear the original fixed construction equipment and provide level native ground")
				continue
		else:
			supports = _panel_construction_supports(a,part,pose,ground_y) if part.kind in ["panel","beam","access_ramp"] else Catalogue.Universal.construction_supports(pose,ground_y)
		if supports.is_empty():
			part.set_meta(&"construction_support_reason","Provide a level grounded worksite for this passive carrier and its unfinished output")
			continue
		part.remove_meta(&"construction_support_reason")
		var owner: Node3D = _cradles.get(aid)
		if not is_instance_valid(owner):
			owner = Node3D.new()
			add_child(owner)
			owner.set_meta(&"root_supports",false)
			_cradles[aid] = owner
		var jig := Node3D.new()
		owner.add_child(jig)
		jig.name = "CarrierSupport_"+id
		for support: Dictionary in supports: _add_construction_support(jig,support.size,support.transform)
		jigs[id] = {"node":jig,"pose":pose,"ground_y":ground_y,"supports":supports,"mast_cuff":cuff,"roof_shelf":shelf,"roof_layout":roof_layout}
	if jigs.is_empty():
		_construction_jigs.erase(aid)
		var owner: Node3D = _cradles.get(aid)
		if is_instance_valid(owner) and not owner.get_meta(&"root_supports",true):
			_cradles.erase(aid)
			owner.queue_free()
	else: _construction_jigs[aid] = jigs

func _construction_cuffs_closed(a: Node3D,descriptor: Dictionary,descriptors: Array) -> bool:
	# Existing broken welds remain ordinary damage, rather than rematerialising
	# ground equipment below a finished travelling machine.
	for id: String in descriptor.get("construction_supports_until",[]):
		if not a.parts.has(id) or not a.parts[id].installed: return false
		for prior: Dictionary in descriptors:
			if prior.id!=id: continue
			for mount: Dictionary in prior.get("secondary_mounts",[]):
				if not is_instance_valid(_secondary_connection(a,id,mount)): return false
	return true

func _construction_dependencies_ready(a: Node3D,descriptor: Dictionary,descriptors: Array) -> bool:
	var required: Array = descriptor.get("requires",[]).duplicate()
	if not descriptor.parent.is_empty(): required.append(descriptor.parent)
	for id: String in required:
		if not a.parts.has(id) or not a.parts[id].installed: return false
		for prior: Dictionary in descriptors:
			if prior.id==id and _secondary_pending(a,prior): return false
	return true

func _static_ground(hit: Dictionary) -> bool:
	# Terrain3D owns native static bodies without a StaticBody3D scene node.
	# Anchor construction only to a real fixed physics body, including terrain.
	var rid: RID = hit.get("rid", RID())
	return rid.is_valid() and PhysicsServer3D.body_get_mode(rid) == PhysicsServer3D.BODY_MODE_STATIC

func _panel_construction_supports(a: Node3D,part: RigidBody3D,pose: Transform3D,ground_y: float) -> Array[Dictionary]:
	# Four finite visible ground columns meet the original floor underside. They
	# carry temporary construction weight through native contact, then leave with
	# the cradle. Saving retains their original pose rather than chasing drift.
	var ramp: bool = part.kind=="access_ramp"
	if pose.basis.y.dot(Vector3.UP)<(cos(deg_to_rad(32.1)) if ramp else .998): return []
	var size: Vector3 = part.definition.size
	var points: Array[Vector3] = []
	if ramp:
		for along: float in [-.35,0.0,.35]: points.append(Vector3(0,-size.y*.5,size.z*along))
	elif part.kind=="beam":
		# Carry the real lower flange near the unjoined far end, below the future
		# bracket. A pad at the bracket socket itself would penetrate the beam.
		points.append(Vector3(0,-size.y*.5,size.z*.5-.12))
	else:
		var descriptor: Dictionary = {}
		for piece: Dictionary in _plans.get(a.get_instance_id(),[]):
			if piece.id==part.part_id: descriptor = piece; break
		for offset: Array in descriptor.get("construction_pad_offsets",[[-.35,-.35],[-.35,.35],[.35,-.35],[.35,.35]]):
			points.append(Vector3(float(offset[0]),-size.y*.5,float(offset[1])))
	var ray := PhysicsRayQueryParameters3D.new()
	ray.collision_mask = 1
	var excluded: Array[RID] = []
	for body: RigidBody3D in a.parts.values(): excluded.append(body.get_rid())
	ray.exclude = excluded
	var result: Array[Dictionary] = []
	for point: Vector3 in points:
		var at := pose*point
		# An inclined ramp needs an equally inclined finite bearing cap. A flat
		# column intrudes into its low edge, while an unsupported long ramp rocks
		# under real head-carrying helpers and interrupts otherwise safe access.
		var cap_size := Vector3(minf(size.x-.1,.9),.018,.22)
		var cap_pose := pose*Transform3D(Basis.IDENTITY,point-Vector3.UP*.010)
		var cap_bounds: AABB = cap_pose*AABB(-cap_size*.5,cap_size)
		var height := (cap_bounds.position.y if ramp else at.y-.001)-ground_y
		if height<.1 or height>2.5: return []
		ray.from = Vector3(at.x,ground_y+.08,at.z)
		ray.to = Vector3(at.x,ground_y-.2,at.z)
		var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(ray)
		if hit.is_empty() or hit.normal.y<.98 or absf(hit.position.y-ground_y)>.05 or not _static_ground(hit): return []
		var level := Basis(Vector3.UP,atan2(pose.basis.z.x,pose.basis.z.z))
		result.append({"size":Vector3(.16,height,.16),"transform":Transform3D(level,Vector3(at.x,ground_y+height*.5,at.z))})
		if ramp: result.append({"size":cap_size,"transform":cap_pose})
	if part.kind=="beam" and part.parameters.get("profile","box")=="i":
		# Two real side cheeks restrain both flanges against yaw/roll before its
		# closing bracket arrives. They stop below the walking floor, and
		# sit inboard far enough to clear the future .30 m bracket's material.
		var centre := pose*Vector3(0,0,size.z*.5-.30)
		var height := centre.y+size.y*.5+.003-ground_y
		var level := Basis(Vector3.UP,atan2(pose.basis.z.x,pose.basis.z.z))
		for sign: float in [-1.0,1.0]:
			var at := centre+pose.basis.x*sign*(size.x*.5+.001+.012)
			ray.from = Vector3(at.x,ground_y+.08,at.z)
			ray.to = Vector3(at.x,ground_y-.2,at.z)
			var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(ray)
			if hit.is_empty() or hit.normal.y<.98 or absf(hit.position.y-ground_y)>.05 or not _static_ground(hit): return []
			result.append({"size":Vector3(.024,height,.16),"transform":Transform3D(level,Vector3(at.x,ground_y+height*.5,at.z))})
		# The visible cap restrains upward twisting through ordinary native contact;
		# neither the machine nor its stock is frozen or moved to meet the jig.
		var cap_pose := pose*Transform3D(Basis.IDENTITY,Vector3(0,size.y*.5+.010,size.z*.5-.30))
		result.append({"size":Vector3(size.x+.050,.018,.16),"transform":cap_pose})
	return result

func _saved_construction_supports(a: Node3D) -> Array:
	var saved: Array = []
	for id: String in _construction_jigs.get(a.get_instance_id(),{}):
		var jig: Dictionary = _construction_jigs[a.get_instance_id()][id]
		var entry := {"id":id,"pose":Part.encode_transform(jig.pose),"ground_y":jig.ground_y}
		if jig.get("roof_shelf",false): entry.roof_layout=int(jig.get("roof_layout",1))
		saved.append(entry)
	return saved

func _saved_root_support(a: Node3D) -> Dictionary:
	var owner: Node3D = _cradles.get(a.get_instance_id())
	if not is_instance_valid(owner) or not owner.get_meta(&"root_supports",true): return {}
	return {"profile":owner.get_meta(&"cradle_profile","ordinary"),
		"pose":Part.encode_transform(owner.get_meta(&"root_support_pose",a.global_transform)),
		"ground_y":owner.get_meta(&"root_support_ground",global_position.y)}

func _on_cradled_state(_state: String, a: Node3D) -> void:
	if is_instance_valid(a) and a.active: _release_cradle_if_complete(a)

func _release_cradle_if_complete(a: Node3D) -> void:
	if not _cradles.has(a.get_instance_id()):
		return
	for p: Node in a.parts.values():
		if not p.installed:
			return
	for descriptor: Dictionary in _plans.get(a.get_instance_id(),[]):
		if _secondary_pending(a,descriptor): return
	for jig: Dictionary in _construction_jigs.get(a.get_instance_id(),{}).values():
		if (jig.get("mast_cuff",false) or jig.get("roof_shelf",false)) and not MastSupport.crew_clear(self,jig.supports): return
	# A balanced roller or articulated walker needs power before its assembly
	# supports are removed. Building it must leave time to press Awaken safely.
	if not a.active and a.parts.values().any(func(p: Node) -> bool: return p.kind in ["gyro", "leg_upper"]):
		return
	var c: Node = _cradles[a.get_instance_id()]
	_cradles.erase(a.get_instance_id())
	_construction_jigs.erase(a.get_instance_id())
	c.queue_free()

func dismantle_selection_reason(assembly: Node3D) -> String:
	if not is_instance_valid(assembly) or assembly.is_queued_for_deletion() or not assemblies.has(assembly) \
		or assembly.get_meta(&"disabled_donor", false):
		return "Choose your own build from Your builds before dismantling."
	if not assembly.parts.values().any(func(part: Node) -> bool: return is_instance_valid(part) and part.installed):
		return "This plan has no installed parts. Choose Cancel unfinished to release its stock."
	for switching: Node in get_tree().get_nodes_in_group(&"machine_switching"):
		var machine: Node = switching.current_machine
		if not switching.controlling_player and is_instance_valid(machine) and machine.get("assembly") == assembly:
			return "Leave the selected machine's helm before dismantling."
	var player: Node = Core.player()
	for part: Node in assembly.parts.values():
		if is_instance_valid(player) and is_instance_valid(part) and part.installed and part.kind == "gun" \
			and is_instance_valid(part.gun_control) and part.gun_control.live_controller() == player:
			return "Leave the selected machine's gun controls before dismantling."
	return ""

func plan_dismantle() -> bool:
	var reason := dismantle_selection_reason(selected_assembly)
	if not reason.is_empty():
		last_message = reason
		return false
	# Use the existing cancellation/recovery path before the first removal;
	# pending plans must not keep stock leased behind the dismantle state.
	cancel_plan()
	var cancelled_resources: Array[String] = []
	coordinator.cancel_targets(selected_assembly.parts.values(), cancelled_resources, "Dismantling selected; useful work on this machine stopped safely")
	selected_assembly.activate(false)
	selected_assembly.set_control(0, 0, true)
	_dismantling[selected_assembly.get_instance_id()] = true
	last_message = "Dismantling selected. Wako return outer parts to storage before the chassis. Choose Stop dismantling to keep what remains."
	return true

func stop_dismantle() -> bool:
	if not is_instance_valid(selected_assembly) or not assemblies.has(selected_assembly) \
		or not _dismantling.has(selected_assembly.get_instance_id()): return false
	_dismantling.erase(selected_assembly.get_instance_id())
	var installed: Array = selected_assembly.parts.values().filter(func(part: Node) -> bool: return is_instance_valid(part) and part.installed)
	var part_ids: Array[String] = []
	for part: Node in installed: part_ids.append(String(part.part_id))
	var removal_kinds: Array[String] = ["dismantle"]
	coordinator.cancel_targets(installed, part_ids, "Dismantling stopped; installed parts stay and released stock returns safely", removal_kinds)
	last_message = "Dismantling stopped. Installed parts stay; released parts still return to storage. Movement stays off until you awaken the machine."
	return true

func cancel_plan() -> void:
	if not is_instance_valid(selected_assembly):
		return
	var targets: Array = selected_assembly.parts.values().filter(func(p: Node) -> bool: return not p.installed)
	for descriptor: Dictionary in _plans.get(selected_assembly.get_instance_id(),[]):
		if _secondary_pending(selected_assembly,descriptor) and selected_assembly.parts.has(descriptor.id):
			targets.append(selected_assembly.parts[descriptor.id])
	var staged: Array = loose_parts.filter(func(p: Node) -> bool:
		return is_instance_valid(p) and p.has_meta(&"staged_target") and targets.has(p.get_meta(&"staged_target")))
	var resource_ids: Array[String] = []
	for stock: Node in staged: resource_ids.append(stock.part_id)
	coordinator.cancel_targets(targets, resource_ids)
	# A paused restored fixture has no live lease yet. Release its same material
	# before deleting the placement; otherwise it stays frozen and in transit.
	for stock: Node3D in staged:
		if stock.has_meta(&"staged_target"):
			_release_staged_component(stock, [])
			stock.set_meta(&"in_transit", false)
			add_loose_part(stock)
	for id: String in selected_assembly.parts.keys():
		var p: Node = selected_assembly.parts[id]
		if not p.installed:
			selected_assembly.remove_part(id)
			p.queue_free()
	var ds: Array = _plans.get(selected_assembly.get_instance_id(), [])
	ds = ds.filter(func(d: Dictionary) -> bool: return selected_assembly.parts.has(d.id))
	# Completed physical welds remain; cancelled pending connector instructions
	# cannot keep an otherwise finished native frame on its construction supports.
	for descriptor: Dictionary in ds: descriptor.erase("secondary_mounts")
	_plans[selected_assembly.get_instance_id()] = ds
	_refresh_construction_supports(selected_assembly)
	_release_cradle_if_complete(selected_assembly)
	last_message = "Unfinished placements cancelled. Reserved cargo will be returned."

func _position_of(target: Node3D) -> Vector3:
	return target.global_position if is_instance_valid(target) else global_position

func work_jobs() -> Array[Dictionary]:
	var jobs: Array[Dictionary] = []
	var ready_placements: Array[Node3D] = []
	var missing_ready_placements: Array[Node3D] = []
	if work_paused or _restoring:
		return jobs
	for a: Variant in assemblies:
		if not is_instance_valid(a) or a.get_meta(&"disabled_donor", false):
			continue
		if worksite_active():
			var field_context := worksite_context()
			if field_context.has("reason") or not _field_assembly(a,field_context.anchor): continue
		var aid: int = a.get_instance_id()
		var ds: Array = _plans.get(aid, [])
		if ds.any(func(piece:Dictionary)->bool:return piece.get("construction_mast_cuff",false) or piece.get("construction_roof_shelf",false) or piece.get("construction_roof_sheet_pad",false)):
			_refresh_construction_supports(a)
			_release_cradle_if_complete(a)
		var closure_plans := {}
		for descriptor: Dictionary in ds:
			if not descriptor.get("secondary_mounts",[]).is_empty(): closure_plans[descriptor.id] = descriptor
		for d: Dictionary in ds:
			if not a.parts.has(d.id):
				continue
			var target: Node3D = a.parts[d.id]
			if not target.installed and not _dismantling.has(aid):
				if d.has("construction_fit") and not d.get("construction_fit_bound",false):
					# Bind only a fresh unreserved ghost. Once stock work starts, its
					# saved material/pose stays fixed through cancellation and JSON.
					var job_id := "build:%d:%s" % [aid,d.id]
					if _reservations.has(job_id) or loose_parts.any(func(source:Node)->bool:return is_instance_valid(source) and source.has_meta(&"staged_target") and source.get_meta(&"staged_target")==target): continue
					var fit: Dictionary=PlanFit.measure(self,a,d,ds)
					if fit.has("reason"): target.set_meta(&"needs",fit.reason); continue
					target.parameters=fit.parameters.duplicate(true)
					if target.kind=="beam": target.resize_beam(float(target.parameters.length))
					var local: Transform3D=a.root_part().global_transform.affine_inverse()*fit.pose
					var angles := local.basis.get_euler()
					d.pos=[local.origin.x,local.origin.y,local.origin.z]
					d.rot=[angles.x,angles.y,angles.z]
					d.parameters=target.parameters.duplicate(true)
					d.construction_fit_bound=true
					a._planned_poses[d.id]=local
					target.global_transform=fit.pose
					if d.get("construction_roof_shelf",false) or d.get("construction_roof_sheet_pad",false): _refresh_construction_supports(a)
				if target.kind=="bearing":
					var native_reason := Catalogue.BearingFreewheel.availability_error(target.parameters)
					if not native_reason.is_empty(): target.set_meta(&"needs",native_reason); continue
				var support_reason: String = target.get_meta(&"construction_support_reason","")
				if not support_reason.is_empty(): target.set_meta(&"needs",support_reason); continue
				if d.parent != "" and (not a.parts.has(d.parent) or not a.parts[d.parent].installed):
					target.set_meta(&"needs", "Waiting for mounting component " + String(d.parent))
					continue
				if closure_plans.has(d.parent) and _secondary_pending(a,closure_plans[d.parent]):
					target.set_meta(&"needs","Waiting for actual closing connector work on "+d.parent)
					continue
				var alignment_reason := _passive_connector_reason(a,d,target)
				if not alignment_reason.is_empty(): target.set_meta(&"needs",alignment_reason); continue
				var pending := ""
				for required: String in d.get("requires", []):
					if not a.parts.has(required) or not a.parts[required].installed: pending = required; break
					if closure_plans.has(required) and _secondary_pending(a,closure_plans[required]): pending = required; break
				if not pending.is_empty():
					target.set_meta(&"needs", "Waiting for supporting component " + pending)
					continue
				var mount_root: RigidBody3D = a.root_part()
				# A fresh plan has no installed root yet. Its actual unparented
				# native foundation still admits the same stopped-placement checks.
				if not is_instance_valid(mount_root) and d.parent == "":
					mount_root = target as RigidBody3D
				if target.service_safety_reason().is_empty() and not unsafe_at(target.global_position) \
					and is_instance_valid(mount_root) and mount_root.linear_velocity.length()<=.25 and mount_root.angular_velocity.length()<=.1:
					ready_placements.append(target)
				if _part_reserved(target):
					target.set_meta(&"needs", "Preparing this placement's actual grounded material")
					continue
				var supply: Node3D
				for candidate: Node3D in loose_parts:
					if is_instance_valid(candidate) and candidate.has_meta(&"staged_target") and candidate.get_meta(&"staged_target") == target:
						supply = candidate
						break
				if supply == null:
					supply = available_part(target.kind, target.parameters)
				if supply:
					target.remove_meta(&"needs")
					var build := _job("build:%d:%s" % [aid, d.id], "build", supply, target, 3.8, d)
					if ready_placements.has(target) and build.blocked.is_empty() and not unsafe_at(supply.global_position): build.priority = 90
					jobs.append(build)
				elif _reservations.has("build:%d:%s" % [aid, d.id]):
					target.set_meta(&"needs", "Reserved part being transported or installed")
				else:
					# Promote matching recovery only after existing stored, staged
					# and reserved build sources have all been ruled out above.
					if ready_placements.has(target): missing_ready_placements.append(target)
					var recovery_reason := _loose_stock_recovery_reason(target)
					if not recovery_reason.is_empty():
						target.set_meta(&"needs", recovery_reason)
						continue
					var requirement: String = "Missing stored " + str(target.kind)
					if target.kind == "beam":
						requirement += " (%s, %.2f m); matching longer stock must leave an offcut of at least 0.30 m." % [target.definition.title, float(target.definition.size.z)]
					elif target.kind == "wheel":
						requirement += ": matching " + String(target.definition.title).to_lower() + "."
					elif target.kind == "wing":
						requirement += ": matching " + Catalogue.WingGeometry.stock_description(target.parameters) + "."
					elif target.kind == "armor":
						requirement += ": intact stock containing %.3f m² of this outline; cuts must keep usable offcuts." % float(target.definition.area)
					target.set_meta(&"needs", requirement)
			elif target.installed and target.health>=float(target.definition.health)*.95 and target.wear<=.15 and not target.jammed and not _dismantling.has(aid) and _secondary_pending(a,d):
				for index in d.get("secondary_mounts",[]).size():
					var mount: Dictionary = d.secondary_mounts[index]
					if _secondary_connection(a,d.id,mount): continue # Existing broken welds use ordinary repair.
					var parent: Node3D = a.parts.get(mount.parent)
					if not is_instance_valid(parent) or not parent.installed: continue
					var join := _job("join:%d:%s:%d" % [aid,d.id,index],"join",target,target,3.0,mount)
					join.heavy = false # Securing installed sockets does not lift their bodies.
					jobs.append(join)
				target.set_meta(&"needs","Closing real structural connectors before applying child loads")
			elif target.installed and _dismantling.has(aid):
				var child := false
				for other: Dictionary in ds:
					var carries: bool = other.parent==d.id or other.get("secondary_mounts",[]).any(func(mount:Dictionary)->bool:return mount.parent==d.id)
					if carries and a.parts.has(other.id) and a.parts[other.id].installed:
						child = true
				if not child:
					var dismantle := _job("dismantle:%d:%s" % [aid, d.id], "dismantle", target, target, 2.8, d)
					# Selected stopped work must get its real pickaxe and crew before
					# unrelated cleanup claims every returning helper.
					if dismantle.blocked.is_empty() and not unsafe_at(target.global_position): dismantle.priority = 90
					jobs.append(dismantle)
			elif target.installed and target.health <= 0:
				var spare: Node3D
				for candidate: Node3D in loose_parts:
					if not is_instance_valid(candidate) or candidate.is_queued_for_deletion(): continue
					if not candidate.stock_condition_reason().is_empty(): continue
					if candidate.has_meta(&"staged_target") and candidate.get_meta(&"staged_target") == target:
						spare = candidate; break
					if candidate.get_meta(&"stored", false) and worksite_source(candidate) and not _part_reserved(candidate) and candidate.health > float(candidate.definition.health) * .15 and not candidate.jammed and material_matches(candidate, target.kind, target.parameters) and Catalogue.same_shape(target.kind, candidate.parameters, target.parameters):
						spare = candidate; break
				var replacement := _job("replace:%d:%s" % [aid, d.id], "replace", spare if spare else target, target, 4.8, d)
				if not spare: replacement.blocked = "Missing compatible working replacement " + target.kind
				jobs.append(replacement)
			elif target.installed and (target.health < float(target.definition.health) * .95 or target.wear > .15 or target.jammed):
				jobs.append(_job("repair:%d:%s" % [aid, d.id], "repair", target, target, 4.5))
			elif target.installed and target.kind in ["station", "gun"] and a.active and String(target.parameters.get("operator", "")) == "":
				jobs.append(_job("operate:%d:%s" % [aid, d.id], "operate", target, target, 1.8))
			elif target.installed and target.kind in ["wheel", "generator", "solar", "hinge", "slider", "motor", "gun", "container", "station", "bearing", "flywheel", "universal"]:
				if not target.parameters.has("maintenance_due"): target.parameters.maintenance_due = maintenance_clock + 90.0
				if maintenance_clock >= float(target.parameters.maintenance_due):
					jobs.append(_job("maintenance:%d:%s" % [aid, d.id], "maintenance", target, target, 2.6))
		for c: Variant in a.connections:
			if is_instance_valid(c) and (c.deformation.length() > .025 or c.broken):
				var target: Node3D = a.parts.values()[0] if not a.parts.is_empty() else null
				if target:
					var j := _job("unbend:%d" % c.get_instance_id(), "unbend", target, target, 5.5)
					j.connection = c
					var unsafe := job_service_reason(j)
					if not unsafe.is_empty(): j.blocked = unsafe
					jobs.append(j)
	for preparation: Dictionary in BeamPreparation.jobs(self, ready_placements):
		preparation.placement.set_meta(&"needs", "Preparing matching grounded material before head transport")
		jobs.append(preparation)
	var missing_work_tools := _missing_ready_work_tools(jobs,ready_placements)
	for p: Variant in loose_parts:
		if is_instance_valid(p) and not p.is_queued_for_deletion() and not p.get_meta(&"stored", false) and not p.get_meta(&"player_carry", false) and not p.get_meta(&"in_transit", false) and str(p.get_meta(&"equipped_worker", "")).is_empty():
			var bay:Node3D = _storage_for_parts(p)
			if not is_instance_valid(bay): continue
			var job := _job("salvage:"+p.part_id,"salvage",p,bay,1.8)
			if not worksite_active() or _field_job_reason(job).is_empty():
				if job.blocked.is_empty() and not unsafe_at(p.global_position):
					if _needed_ground_stock(p,missing_ready_placements) or _needed_ground_work_tool(p,missing_work_tools): job.priority = 90
					elif p.get_meta(&"returning_released_stock",false):
						# A deliberate removal returns its original body before incidental
						# fauna cleanup; ready construction and urgent service still win.
						job.priority = 85
				jobs.append(job)
	return jobs

func _loose_stock_recovery_reason(target: Node3D) -> String:
	# Explain existing physical stock without admitting it as stored material.
	var field := worksite_context() if worksite_active() else {}
	if field.has("reason"): return ""
	for source: Node3D in loose_parts:
		if not is_instance_valid(source) or source.is_queued_for_deletion() or source.get_meta(&"stored", false) or not source.health > 0: continue
		if not material_matches(source, target.kind, target.parameters): continue
		if field.has("anchor") and source.global_position.distance_to(field.anchor.global_position) > 65: continue
		var recovering := _reservations.has("salvage:" + source.part_id)
		if (_part_reserved(source) or source.get_meta(&"in_transit", false)) and not recovering: continue
		var title: String = source.definition.title
		return "Set down the matching %s for Wako recovery to storage." % title if source.get_meta(&"player_carry", false) \
			else "Matching %s awaits Wako recovery to storage when safe." % title
	return ""

func _missing_ready_work_tools(jobs: Array[Dictionary], placements: Array[Node3D]) -> Array[String]:
	# Ready construction and selected stopped removal already have real
	# material. Recover their actual missing tool before unrelated cleanup;
	# held/busy and stored tools remain existing supply.
	var missing: Array[String] = []
	var checked: Array[String] = []
	for job: Dictionary in jobs:
		var ready: bool = job.kind == "build" and placements.has(job.target)
		ready = ready or (job.kind == "dismantle" and int(job.get("priority",0)) >= 90)
		if not ready or not job.blocked.is_empty(): continue
		var capability := work_tool_capability(str(job.kind))
		if capability.is_empty() or checked.has(capability): continue
		checked.append(capability)
		var held: bool = workers.any(func(worker: Node) -> bool:
			return is_instance_valid(worker) and worksite_worker(worker) and tool_compatible(worker.equipped_tool,capability) \
				and worker_owns_work_tool(worker,worker.equipped_tool))
		if held: continue
		var stored: bool = loose_parts.any(func(tool: Node) -> bool:
			return is_instance_valid(tool) and not tool.is_queued_for_deletion() and tool.get_meta(&"stored",false) \
				and worksite_source(tool) and tool_compatible(tool,capability))
		if not stored: missing.append(capability)
	return missing

func _needed_ground_work_tool(source: Node3D, capabilities: Array[String]) -> bool:
	if not capabilities.any(func(capability: String) -> bool: return tool_compatible(source,capability)): return false
	return _settled_recovery_support(source)

func _needed_ground_stock(source: Node3D, placements: Array[Node3D]) -> bool:
	# Recover useful material before unrelated yard cleanup, then the ordinary
	# stored-only build job fetches it. This grants no custody, stock or tool work.
	if not source is RigidBody3D: return false
	var matching := false
	for target: Node3D in placements:
		# material_matches includes finite profile, phase, usable offcut and
		# outside-edge cutting eligibility, exactly as stored stock selection does.
		if material_matches(source,target.kind,target.parameters): matching=true; break
	if not matching: return false
	return _settled_recovery_support(source)

func _settled_recovery_support(source: Node3D) -> bool:
	if not source is RigidBody3D or source.health <= float(source.definition.health)*.15 or source.jammed \
		or _part_reserved(source) or is_instance_valid(source.carrier) or source.get_meta(&"awaiting_setdown",false) \
		or not source.global_transform.is_finite() or source.linear_velocity.length()>.25 or source.angular_velocity.length()>.1: return false
	var bounds: AABB = source.global_transform*Catalogue.bounds_of(source.definition)
	var point := Vector3(bounds.get_center().x,bounds.position.y,bounds.get_center().z)
	var exclude: Array[RID] = [source.get_rid()]
	for worker: RigidBody3D in workers: exclude.append(worker.get_rid())
	var query := PhysicsRayQueryParameters3D.create(point+Vector3.UP*.42,point-Vector3.UP*.42,1,exclude)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return not hit.is_empty() and hit.normal.y>=.65 and absf(hit.position.y-point.y)<=.16

func _job(id: String, kind: String, part: Node3D, target: Node3D, duration: float, descriptor: Dictionary = {}) -> Dictionary:
	var moving: bool = target is RigidBody3D and target.linear_velocity.length() > 1.8
	var job := {"id": id, "kind": kind, "part": part, "target": target, "position": target.global_position,
		"duration": duration, "heavy": part.mass > 35.0, "dependencies": [], "descriptor": descriptor,
		"priority": {"replace": 110, "repair": 100, "unbend": 95, "join":85, "salvage": 80, "dismantle": 70, "build": 60, "maintenance": 15}.get(kind, 20),
		"blocked": "Stop the machine for safe work" if moving else ""}
	var unsafe := job_service_reason(job)
	if not unsafe.is_empty(): job.blocked = unsafe
	return job

func _passive_connector_reason(a: Node3D,descriptor: Dictionary,target: Node3D) -> String:
	var parent: Node3D = a.parts.get(String(descriptor.get("parent","")))
	if not is_instance_valid(parent) or not parent.installed or (parent.kind != "universal" and not descriptor.get("contact_mount",false)): return ""
	var gap: float = parent.connector_world(descriptor.socket_a).origin.distance_to(target.connector_world(descriptor.socket_b).origin)
	if descriptor.get("contact_mount",false):
		if parent.linear_velocity.length()>.25 or parent.angular_velocity.length()>.1 or _connector_velocity(parent,descriptor.socket_a).length()>.25:
			return "Stop and support the actual mounting connector before installing its child"
		return "Mounting faces moved: align/support actual component connectors before installing (%.0f mm gap)" % (gap*1000) if gap>.015 else ""
	return "Passive carrier moved: align/support actual output connectors before installing (%.0f mm gap)" % (gap*1000) if gap>.015 else ""

func job_service_reason(job: Dictionary) -> String:
	if job.get("kind", "") == "dismantle":
		var target: Node = job.get("target")
		if not is_instance_valid(target): return "The original component is no longer available"
		# Stop guards removal of still-installed bodies. A successfully released
		# original body is loose stock; its existing recovery must remain admitted.
		if target.installed and (not is_instance_valid(target.get("assembly")) \
			or not _dismantling.has(target.assembly.get_instance_id())):
			return "Dismantling stopped; keep the remaining installed parts"
	var field_reason := _field_job_reason(job)
	if not field_reason.is_empty(): return field_reason
	if job.get("kind", "") == "prepare": return BeamPreparation.reason(self, job)
	if job.get("kind", "") in ["build", "replace", "repair", "maintenance"] and is_instance_valid(job.get("part")):
		var stock_reason: String = job.part.stock_condition_reason()
		if not stock_reason.is_empty(): return stock_reason
	if job.get("kind", "") in ["build", "join"] and is_instance_valid(job.get("target")):
		var stock_reason: String = job.target.stock_condition_reason()
		if not stock_reason.is_empty(): return stock_reason
	if job.get("kind","")=="salvage" and is_instance_valid(job.get("part")):
		var material_reason: String=job.part.material_storage_reason()
		if not material_reason.is_empty(): return material_reason
	if job.get("kind","")=="replace":
		for component: Variant in [job.get("part"),job.get("target")]:
			if not is_instance_valid(component): continue
			var material_reason: String=component.material_replacement_reason()
			if not material_reason.is_empty(): return material_reason
	if job.get("kind","") in ["build","join"] and is_instance_valid(job.get("target")):
		var support_reason: String=job.target.get_meta(&"construction_support_reason","")
		if not support_reason.is_empty(): return support_reason
	if job.get("kind","") in ["build","replace"] and is_instance_valid(job.get("target")) and job.target.kind=="bearing":
		var native_reason := Catalogue.BearingFreewheel.availability_error(job.target.parameters)
		if not native_reason.is_empty(): return native_reason
	if job.get("kind", "") == "operate": return ""
	if job.get("kind", "") == "unbend" and is_instance_valid(job.get("connection")):
		var reason: String = job.connection.broken_repair_reason()
		if not reason.is_empty(): return reason
	if job.get("kind", "") == "join":
		var own: Node3D = job.get("target")
		if not is_instance_valid(own) or not is_instance_valid(own.assembly) or not own.installed: return "Install both structural mounting bodies before securing their sockets"
		var mounting: Node3D = own.assembly.parts.get(job.descriptor.parent)
		if not is_instance_valid(mounting) or not mounting.installed: return "Install both structural mounting bodies before securing their sockets"
		if own.health<=0 or mounting.health<=0: return "Replace failed structural bodies before securing their sockets"
		if own.linear_velocity.length()>.25 or mounting.linear_velocity.length()>.25 or own.angular_velocity.length()>.1 or mounting.angular_velocity.length()>.1:
			return "Stop and support the actual structural sockets before securing their link"
		if _connector_velocity(own,job.descriptor.socket_b).length()>.25 or _connector_velocity(mounting,job.descriptor.socket_a).length()>.25:
			return "Stop and support the actual moving connector faces before securing their link"
		var gap: float = own.connector_world(job.descriptor.socket_b).origin.distance_to(mounting.connector_world(job.descriptor.socket_a).origin)
		if gap>.015: return "Structural sockets moved: align/support their real connectors (%.0f mm gap)" % (gap*1000)
	var points: Array = [job.get("part"), job.get("target")]
	var target: Node3D = job.get("target")
	var parent_id := str(job.get("descriptor", {}).get("parent", ""))
	if is_instance_valid(target) and is_instance_valid(target.get("assembly")) and not parent_id.is_empty():
		points.append(target.assembly.parts.get(parent_id))
	var connection: Node3D = job.get("connection")
	if is_instance_valid(connection): points.append_array([connection.a, connection.b])
	for point: Variant in points:
		if is_instance_valid(point) and point.has_method("service_safety_reason"):
			var reason: String = point.service_safety_reason()
			if not reason.is_empty(): return reason
	return ""

func reserve_job(job: Dictionary, crew: Array) -> bool:
	if work_paused or _reservations.has(job.id) or not is_instance_valid(job.get("part")):
		return false
	if not job_service_reason(job).is_empty(): return false
	if worksite_active() and not crew.all(func(w:Node)->bool:return worksite_worker(w)): return false
	var p: Node = job.part
	if job.kind == "prepare" and _part_reserved(job.placement): return false
	if _part_reserved(p) or (job.get("heavy", false) and crew.size() < 2):
		return false
	var supported_station := _supported_station_crew(job, crew)
	var guarded_gun: bool = supported_station and job.target.kind == "gun"
	if ((unsafe_at(p.global_position) or unsafe_at(job.target.global_position)) and not guarded_gun) or (job.get("blocked", "") != "" and not supported_station):
		return false
	var capability := work_tool_capability(str(job.kind))
	var tool: Node3D = tool_for_job(job, crew[0]) if not capability.is_empty() and not crew.is_empty() else null
	job.erase("_prospective_tool")
	if not capability.is_empty() and tool == null: return false
	if job.kind in ["build", "replace", "salvage"]:
		var capacity := 0.0
		for w: Node in crew:
			var equipped: Node = tool if w == crew[0] and tool else w.equipped_tool
			capacity += maxf(w.carry_capacity - (float(equipped.mass) if is_instance_valid(equipped) else 0.0), 0.0)
		if p.mass > capacity + .001: return false
	var material_target: Node3D = job.placement if job.kind == "prepare" else job.target
	if job.kind in ["build", "prepare"] and material_target.kind=="beam" and material_target.parameters.get("truss_phase_auto",false):
		if not material_matches(p,"beam",material_target.parameters): return false
		var target: Node3D = material_target
		target.parameters.truss_phase = Catalogue.BeamGeometry.normalize(p.parameters).truss_phase
		target.parameters.erase("truss_phase_auto")
		target.resize_beam(float(target.parameters.length))
		job.descriptor.parameters = target.parameters.duplicate(true)
		for descriptor: Dictionary in _plans.get(target.assembly.get_instance_id(),[]):
			if descriptor.id==target.part_id: descriptor.parameters = target.parameters.duplicate(true)
	if job.kind == "prepare": job.parameters = material_target.parameters.duplicate(true)
	_resume_cargo_callbacks(p)
	if is_instance_valid(tool): _resume_cargo_callbacks(tool)
	job.tool = tool
	_reservations[job.id] = {"part_id": p.part_id, "part_instance": p.get_instance_id(),
		"tool_instance": tool.get_instance_id() if tool else 0,
		"target_instance": job.placement.get_instance_id() if job.kind == "prepare" else job.target.get_instance_id() if job.kind == "replace" else 0, "workers": crew.map(func(w: Node) -> int: return w.get_instance_id())}
	if job.kind=="salvage":
		var destination:=reserve_storage_pose(p,job.target,job.id)
		if destination.has("reason"):
			_reservations.erase(job.id)
			last_message=destination.reason
			return false
		job.storage_destination=destination
	return true

func work_tool_capability(kind: String) -> String:
	return {"prepare": "build", "build": "build", "join":"build", "replace": "build", "repair": "repair", "unbend": "unbend", "dismantle": "dismantle", "maintenance": "maintenance"}.get(kind, "")

func tool_for_job(job: Dictionary, worker: Node, after_failed: Dictionary = {}) -> Node3D:
	var capability := work_tool_capability(str(job.kind))
	if capability.is_empty(): return null
	# Reservation must use this synchronous admission's original body or fail.
	if job.has("_prospective_tool"):
		var pin: Dictionary = job._prospective_tool
		if pin.worker != work_tool_worker_stamp(worker): return null
		var source: Dictionary = pin.source
		var tool := source.tool.get_ref() as Node3D
		if not work_tool_source_matches(tool, source) or not loose_parts.has(tool): return null
		return tool if _stored_work_tool_eligible(tool, capability) else null
	if is_instance_valid(worker.equipped_tool) and tool_compatible(worker.equipped_tool, capability): return worker.equipped_tool
	var cursor: Node3D
	if not after_failed.is_empty():
		cursor = after_failed.tool.get_ref() as Node3D
		if not work_tool_source_matches(cursor, after_failed): cursor = null
	var cursor_distance: float = worker.global_position.distance_squared_to(cursor.global_position) if is_instance_valid(cursor) else INF
	var cursor_seen := false
	var nearest: Node3D
	var distance := INF
	var successor: Node3D
	var successor_distance := INF
	# One ordinary stock scan; the cursor chooses another source, not a proof.
	for tool: Node3D in loose_parts:
		if not _stored_work_tool_eligible(tool, capability): continue
		var candidate: float = worker.global_position.distance_squared_to(tool.global_position)
		var identity: int = tool.get_instance_id()
		if candidate < distance or (is_instance_valid(nearest) and candidate == distance and identity < nearest.get_instance_id()):
			distance = candidate
			nearest = tool
		if not is_instance_valid(cursor): continue
		if tool == cursor: cursor_seen = true
		if candidate < cursor_distance or (candidate == cursor_distance and identity <= cursor.get_instance_id()): continue
		if candidate < successor_distance or (is_instance_valid(successor) and candidate == successor_distance and identity < successor.get_instance_id()):
			successor_distance = candidate
			successor = tool
	return successor if cursor_seen and is_instance_valid(successor) else nearest

func _stored_work_tool_eligible(tool: Node3D, capability: String) -> bool:
	return is_instance_valid(tool) and not tool.is_queued_for_deletion() and tool.get_meta(&"stored", false) \
		and not _part_reserved(tool) and tool_compatible(tool, capability) and worksite_source(tool)

func work_tool_source_stamp(tool: Node3D) -> Dictionary:
	return {"tool": weakref(tool), "state": _work_tool_source_state(tool)} if is_instance_valid(tool) else {}

func work_tool_source_matches(tool: Node3D, stamp: Dictionary) -> bool:
	return is_instance_valid(tool) and not tool.is_queued_for_deletion() and not stamp.is_empty() \
		and stamp.state == _work_tool_source_state(tool)

func _work_tool_source_state(tool: Node3D) -> Array:
	# Scene properties only: exact original identity, pose, condition and custody.
	var parent: Node = tool.get_parent()
	var carrier: Object = tool.get("carrier")
	return [tool.get_instance_id(), tool.get_rid(), parent.get_instance_id() if is_instance_valid(parent) else 0,
		tool.global_transform, tool.get_meta(&"stored", false), tool.get_meta(&"stored_tool_rack", false),
		tool.get_meta(&"in_transit", false), carrier.get_instance_id() if is_instance_valid(carrier) else 0,
		str(tool.get_meta(&"equipped_worker", "")), tool.health, tool.jammed, tool.freeze]

func work_tool_worker_stamp(worker: Node) -> Array:
	# A pin survives only this frame with unchanged cached worker/support state.
	var pose: Object = worker.get("_pose")
	var supports: Array = []
	for i in pose._support.size():
		var support_owner: Object = pose._support[i].get_ref()
		supports.append([support_owner.get_instance_id() if is_instance_valid(support_owner) else 0,
			support_owner.global_transform if support_owner is Node3D else Transform3D.IDENTITY, pose._support_rids[i]])
	var ground: Object = worker.get("_ground_body")
	return [Engine.get_physics_frames(), worker.get_instance_id(), worker.global_transform,
		worker.on_ground, worker._ground_point, worker.ground_normal, worker.work_foot_side, worker.tool_foot_side(),
		worker.equipped_tool, ground.get_instance_id() if is_instance_valid(ground) else 0,
		ground.global_transform if ground is Node3D else Transform3D.IDENTITY,
		pose.evaluation_serial, pose.evaluated_valid, supports]

func tool_compatible(tool: Node, capability: String) -> bool:
	return is_instance_valid(tool) and tool.health > float(tool.definition.health) * .15 and not tool.jammed and capability in tool.definition.get("work_capabilities", [])

func worker_owns_work_tool(worker: Node, tool: Node3D) -> bool:
	if not is_instance_valid(worker) or not is_instance_valid(tool) or worker.equipped_tool!=tool \
		or str(tool.get_meta(&"equipped_worker",""))!=worker.worker_id: return false
	if tool.carrier==worker.tool_anchor: return true
	var transfer: Variant=worker.back_tool
	if transfer==null: return false
	if tool.carrier==transfer.back_anchor: return transfer.phase in ["back","retrieve"]
	# Native toss flight retains the exact original ownership without a
	# carrier. A loose/released body no longer satisfies this custody check.
	return transfer.phase=="flight" and not is_instance_valid(tool.carrier) \
		and transfer._tool_id==tool.get_instance_id() and transfer._tool_rid==tool.get_rid()

func _equip_worker_tool(tool: Node3D, worker: Node) -> void:
	prepare_cargo(tool)
	tool.set_meta(&"equipped_worker", worker.worker_id)
	tool.set_carried_at_pose(worker.tool_anchor)
	worker.set_equipped_tool(tool)
	if worker.action == "tool_change": worker.tool_change_picked_up = true
	if worker.back_tool: worker.back_tool.fitting_acquired(tool)

func _abandon_worker_tool(tool: Node3D) -> void:
	if not is_instance_valid(tool) or tool.is_queued_for_deletion() or not is_inside_tree() or not tool.is_inside_tree(): return
	if is_instance_valid(tool.carrier) and not tool.carrier.is_inside_tree(): tool.carrier = null
	tool.remove_meta(&"equipped_worker")
	_release_staged_component(tool, [])
	add_loose_part(tool)

func _return_worker_tool(worker: Node, bay_override: Node3D = null) -> void:
	var old: Node3D = worker.equipped_tool
	worker.set_equipped_tool(null)
	if not is_instance_valid(old): return
	old.remove_meta(&"equipped_worker")
	# The departing original tool leaves its actual toe pose with native
	# point motion. Normal salvage reserves a real return place later; a
	# tool swap may not relocate it to a distant/occupied clip at contact.
	_release_staged_component(old,[worker])
	add_loose_part(old)

func _supported_station_crew(job: Dictionary, crew: Array) -> bool:
	if job.kind != "operate" or crew.is_empty() or not is_instance_valid(job.target) or job.target.kind not in ["gun", "station"]:
		return false
	return crew.all(func(w: Node) -> bool: return is_instance_valid(w) and not w.paused and w.fear_time <= 0 and w.supported_by(job.target.assembly) and w.can_reach_target(job.target))

func perform_work(job: Dictionary, progress: float, event: String, crew: Array) -> bool:
	var part: Variant = job.get("part")
	var target: Variant = job.get("target")
	if event == "cancel":
		if is_instance_valid(part) and part.get_meta(&"in_transit", false):
			if staged_job_valid(job,crew):
				# A released lease does not undo this original body's real arrival.
				# Normal discovery reserves the same source for unfinished foot work.
				part.set_meta(&"staged_work_progress",clampf(progress,0.0,.95))
				return false
			_release_staged_component(part, crew)
			part.set_meta(&"in_transit", false)
			add_loose_part(part)
		return false
	if not is_instance_valid(part) or not is_instance_valid(target) or not _reservations.has(job.id):
		return false
	if not job_service_reason(job).is_empty(): return false
	if worksite_active() and not crew.all(func(w:Node)->bool:return worksite_worker(w)): return false
	if event == "tool_pickup":
		var tool: Node3D = job.get("tool")
		if crew.is_empty() or not is_instance_valid(tool) or not tool_compatible(tool, work_tool_capability(str(job.kind))): return false
		var tool_bay := tool.get_parent() as Node3D
		# The reserved full-size tool frees its real clip before the retained tool
		# returns to that same bay. No swap creates stock or packs it inside a hull.
		prepare_cargo(tool)
		if is_instance_valid(crew[0].equipped_tool) and crew[0].equipped_tool != tool: _return_worker_tool(crew[0], tool_bay)
		_equip_worker_tool(tool, crew[0])
		return true
	var capability := work_tool_capability(str(job.kind))
	if event in ["tick", "complete"] and not capability.is_empty():
		var tool: Node3D=job.get("tool")
		if crew.is_empty() or not worker_owns_work_tool(crew[0],tool) \
			or not tool_compatible(tool,capability) or tool.carrier!=crew[0].tool_anchor: return false
	if job.kind == "prepare":
		if event == "tick": return true
		if event != "complete" or progress < 1.0 or not BeamPreparation.contact_ready(self, job, crew): return false
		if not BeamPreparation.split(self, part, job.parameters, true, crew): return false
		last_message = "Grounded beam section prepared; Wako recover the real pieces before installation."
		return true
	if event == "present_pickup" and job.kind in ["build","replace","salvage"] and job.get("light_pickup",false):
		# Expand this exact reserved rack body in place before the toe approaches.
		# Existing in-transit persistence/cancel paths recover it safely mid-action.
		prepare_cargo(part)
		part.set_meta(&"in_transit",true)
		part.freeze = true
		part.collision_layer = 0
		part.collision_mask = 0
		return true
	if event == "pickup" and job.kind in ["build", "replace", "salvage"]:
		if job.get("head_first_pickup",false):
			if crew.is_empty() or not crew.all(func(member: Node) -> bool: return member.head_leap.contact_ready()): return false
			# Remove only storage custody. prepare_cargo also changes depot basis
			# and scale; contact may never invoke that compact-display expansion.
			if not crew[0].HeadLeap.attach_group(part,crew): return false
			var old_bay: Node = part.get_parent()
			_resume_cargo_callbacks(part)
			NativeHeadCustody.reparent_preserving_native(part,self)
			part.set_meta(&"rack_scale",false)
			part.set_meta(&"stored",false)
			part.remove_meta(&"depot_display")
			part.set_meta(&"in_transit",true)
			if old_bay is RigidBody3D and old_bay.has_method(&"_update_secured_cargo"): old_bay._update_secured_cargo()
			return true
		if job.get("light_pickup",false):
			return not crew.is_empty() and crew[0].pickup.grip()
		prepare_cargo(part)
		part.set_meta(&"in_transit", true)
		if not crew.is_empty():
			part.set_carried(crew[0].head_anchor, Vector3(0, float(part.definition.size.y) * .5 + .03, 0))
		return true
	if event == "stage" and job.kind in ["build", "replace"]:
		if (target.installed and job.kind == "build") or (job.kind == "replace" and (not target.installed or target.health > 0)) or part.kind != target.kind:
			return false
		if not _placement_crew_clear(target): return false
		if not _prepare_material(part, target.parameters, crew):
			return false
		# A ghost may become visible only where the original physical stock
		# actually arrived through the finite assisted carrier path.
		if not _material_arrived(part,target.global_transform): return false
		_stage_component(part, target)
		return true
	if job.kind == "build":
		target.set_meta(&"plan_progress", progress)
		target.build_progress = progress
	if event != "complete":
		return true
	if unsafe_at(target.global_position) and not (_supported_station_crew(job, crew) and target.kind == "gun"):
		return false
	match String(job.kind):
		"join":
			if crew.is_empty() or not crew[0].foot_contact_ready() or crew[0].action!="assemble": return false
			var a: Node3D = target.assembly
			var d: Dictionary = job.descriptor
			if _secondary_connection(a,target.part_id,d): return false
			var connection: Node3D = a.connect_parts(d.parent,target.part_id,d.socket_a,d.socket_b,"rigid")
			if not is_instance_valid(connection) or connection.broken: return false
			target.remove_meta(&"needs")
			_refresh_construction_supports(a)
			_release_cradle_if_complete(a)
			last_message = "Real structural sockets secured by supported foot work."
		"replace":
			if not _material_arrived(part,target.global_transform): return false
			if target.health > 0 or not target.installed or not is_instance_valid(target.assembly): return false
			var previous: Node3D = StockArrival.replace(self,part,target)
			if not is_instance_valid(previous): return false
			loose_parts.erase(part)
			part.remove_meta(&"returning_released_stock")
			part.remove_meta(&"staged_target")
			part.remove_meta(&"staged_work_progress")
			part.set_meta(&"in_transit", false)
			part.visual.show()
			previous.visual.show()
			_release_staged_component(previous, crew)
			add_loose_part(previous)
			last_message = "%s replaced with a real stored component; failed part recovered as scrap." % part.kind.capitalize()
		"build":
			if not _material_arrived(part,target.global_transform): return false
			if target.installed or part.kind != target.kind or not is_instance_valid(target.assembly):
				return false
			if not _placement_crew_clear(target): return false
			var a: Node = target.assembly
			var d: Dictionary = job.descriptor
			if d.parent != "" and (not a.parts.has(d.parent) or not a.parts[d.parent].installed):
				return false
			var alignment_reason := _passive_connector_reason(a,d,target)
			if not alignment_reason.is_empty():
				target.set_meta(&"needs",alignment_reason)
				last_message = alignment_reason
				return false
			var arrived: RigidBody3D=StockArrival.install(self,part,target)
			if not is_instance_valid(arrived): return false
			job.target=arrived
			arrived.visual.show()
			part.remove_meta(&"staged_target")
			part.remove_meta(&"staged_work_progress")
			if d.parent != "":
				a.connect_parts(d.parent, arrived.part_id, d.socket_a, d.socket_b, d.joint)
			_refresh_construction_supports(a)
			_release_cradle_if_complete(a)
			loose_parts.erase(part)
			part.remove_meta(&"returning_released_stock")
			part.set_meta(&"stored",false)
			part.set_meta(&"in_transit",false)
			part.remove_meta(&"awaiting_setdown")
			last_message = "%s installed from its original physical stock." % arrived.definition.title
		"salvage":
			return store_part_at_pose(part,target)
		"repair":
			part.repair(float(part.definition.health))
			last_message = "%s repaired by Wako." % part.kind.capitalize()
		"maintenance":
			part.wear = maxf(part.wear - .05, 0.0)
			part.parameters.maintenance_due = maintenance_clock + 90.0
			part.condition_changed.emit()
			last_message = "%s inspected and lubricated by Wako." % part.kind.capitalize()
		"unbend":
			if not is_instance_valid(job.get("connection")):
				return false
			if not job.connection.repair(120.0): return false
			last_message = "Loaded joint straightened and reconnected."
		"dismantle":
			if not is_instance_valid(part.assembly):
				return false
			var a: Node = part.assembly
			a.remove_part(part.part_id)
			_refresh_construction_supports(a)
			add_loose_part(part)
			# Stop removal keeps this recovery intent, without retaining a job
			# lease or claiming unavailable space in the physical depot.
			part.set_meta(&"returning_released_stock",true)
		"operate":
			if crew.is_empty() or not target.installed or target.kind not in ["station", "gun"]:
				return false
			target.parameters.operator = crew[0].worker_id
			last_message = "Wako reached the %s and took its controls." % target.kind
	return true

func _material_arrived(part: RigidBody3D,expected: Transform3D) -> bool:
	return StockArrival.arrived(part,expected)

func _stage_component(part: Node3D, target: Node3D) -> void:
	# A visible assembly fixture holds the reserved resource in the unfinished
	# placement until the timed installation event replaces it with the joined body.
	if not part.has_meta(&"staged_target") or part.get_meta(&"staged_target")!=target: part.remove_meta(&"staged_work_progress")
	part.set_meta(&"staged_target", target)
	part.set_meta(&"in_transit", true)
	part.set_carried_at_pose(target)
	target.visual.hide()

func _release_staged_component(part: Node3D,crew: Array) -> void:
	if not is_instance_valid(part) or not part.is_inside_tree() or not is_inside_tree() or is_queued_for_deletion(): return
	var target: Variant=part.get_meta(&"staged_target") if part.has_meta(&"staged_target") else null
	if is_instance_valid(target): target.visual.show()
	part.remove_meta(&"staged_target")
	part.remove_meta(&"staged_work_progress")
	_resume_cargo_callbacks(part)
	_stock_release.release(part,crew)

func place_component(a: Node3D, kind: String, world_transform: Transform3D, parent_id: String, parent_socket: String, own_socket: String, direct: bool = false, parameters: Dictionary = {}) -> bool:
	parameters = _fresh_beam_parameters(parameters) if kind=="beam" else parameters.duplicate(true)
	if not is_instance_valid(a) or not a.parts.has(parent_id) or not Catalogue.all().has(kind) or kind == "remote_core":
		last_message = "Choose an existing mounting component and a recoverable part."
		return false
	var descriptor := Plans.piece("validate", kind, Vector3.ZERO, parent_id, parent_socket, own_socket)
	descriptor.parameters = parameters
	var invalid := Plans.validate({"parts": [descriptor]}, Catalogue.all(), a.parts.keys())
	if invalid != "":
		last_message = invalid
		return false
	var parent: Node = a.parts[parent_id]
	var definition := Catalogue.get_def(kind, parameters)
	if not parent.installed or not Catalogue.compatible(Catalogue.socket(parent.definition, parent_socket), Catalogue.socket(definition, own_socket)):
		last_message = "Install the supporting component and choose compatible connectors first."
		return false
	var supply: Node3D
	if direct:
		for p: Variant in loose_parts:
			if is_instance_valid(p) and material_matches(p, kind, parameters) and not p.get_meta(&"stored", false) and not _part_reserved(p) and p.global_position.distance_to(world_transform.origin) < 2.2:
				if supply==null: supply=p
				if Catalogue.same_shape(kind,p.parameters,parameters) and _material_arrived(p,world_transform):
					supply=p
					break
		if supply == null:
			last_message = "Bring a loose %s within 2.2 m of this connector using the grabber." % kind
			return false
		if kind=="beam" and parameters.get("truss_phase_auto",false):
			parameters.truss_phase = Catalogue.BeamGeometry.normalize(supply.parameters).truss_phase
			parameters.erase("truss_phase_auto")
		# A nearby grabber body is not an arrived physical placement. Refuse
		# before cutting/allocating rather than copying it to a distant ghost.
		if not Catalogue.same_shape(kind,supply.parameters,parameters) or not _material_arrived(supply,world_transform):
			last_message="Align the actual original stock with this preview before installing, or leave a plan for Wako preparation and transport."
			return false
		if not _material_arrived(parent,parent.global_transform) or parent.connector_world(parent_socket).origin.distance_to(supply.connector_world(own_socket).origin)>.015:
			last_message="Bring the original part's mounting face into contact with this supported connector, or let Wako install it."
			return false
	var id := next_id("custom")
	var root: RigidBody3D = a.root_part()
	var local := a.global_transform.affine_inverse() * world_transform
	var p: Node3D = a.add_part(kind, local, false, id, parameters)
	# add_part accepts assembly coordinates; the blueprint stores chassis coordinates.
	p.global_transform = world_transform
	if root:
		a._planned_poses[id] = root.global_transform.affine_inverse() * world_transform
	var plan_local := root.global_transform.affine_inverse() * world_transform if root else local
	var euler := plan_local.basis.get_euler()
	var joint := str(definition.get("preferred_joint", {"wheel": "axle", "hinge": "hinge", "motor": "motor", "slider": "slider", "piston": "slider"}.get(kind, "rigid")))
	if kind == "hinge" and Catalogue.FlightDesign.enabled(parameters):
		joint = "rigid" # The programmable servo housing mounts to its fixed base.
	elif kind in ["wing", "thruster"] and parent.kind == "hinge" and Catalogue.FlightDesign.enabled(parent.parameters):
		joint = "hinge" # Only its aerodynamic load rotates through the native servo.
	var d := Plans.piece(id, kind, plan_local.origin, parent_id, parent_socket, own_socket, joint)
	d.rot = [euler.x, euler.y, euler.z]
	if not parameters.is_empty():
		d.parameters = parameters.duplicate(true)
	var ds: Array = _plans.get(a.get_instance_id(), [])
	ds.append(d)
	_plans[a.get_instance_id()] = ds
	p.set_meta(&"plan_parent", parent_id)
	if direct:
		# Release the native grabber joint before consuming the physical supply.
		var player := Core.player()
		var manager := player.find_child("HandToolManager", true, false) if player else null
		if manager and manager.current_tool and "grabber" in manager.current_tool:
			var grabber: Node = manager.current_tool.grabber
			if grabber.get("grabbed_body") == supply:
				grabber._release()
		var arrived: RigidBody3D=StockArrival.install(self,supply,p)
		if not is_instance_valid(arrived):
			last_message="Original stock moved before native admission; the placement remains a Wako plan."
			return false
		a.connect_parts(parent_id,arrived.part_id,parent_socket,own_socket,joint)
		supply.set_meta(&"player_carry",false)
		supply.set_meta(&"in_transit",false)
		loose_parts.erase(supply)
	_refresh_construction_supports(a)
	return true

func _fresh_beam_parameters(parameters: Dictionary) -> Dictionary:
	var result := parameters.duplicate(true)
	if result.get("profile", "box")=="truss" and not result.has("truss_phase"):
		result.truss_phase_auto = true
	return result

func _placement_crew_clear(target: Node3D) -> bool:
	if target.kind not in ["panel","access_ramp"]: return true
	var material: AABB = target.global_transform*Catalogue.bounds_of(target.definition)
	for helper: RigidBody3D in workers:
		if not is_instance_valid(helper) or helper.is_queued_for_deletion(): continue
		var centre := helper.global_position+Vector3.UP*.2
		var body := AABB(centre-Vector3(.31,.525,.31),Vector3(.62,1.05,.62))
		if body.intersects(material):
			target.set_meta(&"needs","Keep the crew clear of the future floor before installing its material")
			return false
	return true

func _transfer_container_contents(source: Node3D, target: Node3D) -> void:
	if source.kind != "container" or target.kind != "container":
		return
	for cargo: Node in source.get_children():
		if cargo is RigidBody3D and cargo.get_meta(&"stored", false):
			cargo.reparent(target, false)
	target._update_secured_cargo()

func release_job(job: Dictionary) -> void:
	StorageCustody.release(job.get("part"))
	_reservations.erase(job.get("id", ""))

func _secondary_connection(a: Node3D,id: String,mount: Dictionary) -> Node3D:
	for connection: Node3D in a.connections:
		if connection.a_id==mount.parent and connection.b_id==id and connection.a_socket==mount.socket_a and connection.b_socket==mount.socket_b: return connection
		if connection.b_id==mount.parent and connection.a_id==id and connection.b_socket==mount.socket_a and connection.a_socket==mount.socket_b: return connection
	return null

func _secondary_pending(a: Node3D,descriptor: Dictionary) -> bool:
	for mount: Dictionary in descriptor.get("secondary_mounts",[]):
		var connection := _secondary_connection(a,descriptor.id,mount)
		if not is_instance_valid(connection) or connection.broken: return true
	return false

func _connector_velocity(part: RigidBody3D,socket: String) -> Vector3:
	var local: Vector3 = part.connector_definition(socket).pos
	var direct := PhysicsServer3D.body_get_direct_state(part.get_rid())
	if direct: return direct.get_velocity_at_local_position(part.global_basis*local)
	var centre := part.center_of_mass if part.center_of_mass_mode==RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM else Vector3.ZERO
	return part.linear_velocity+part.angular_velocity.cross(part.global_basis*(local-centre))

func unsafe_at(pos: Vector3) -> bool:
	for enemy: Variant in enemies:
		if is_instance_valid(enemy) and enemy.alive and enemy.assembly and not enemy.assembly.parts.is_empty():
			var p: Node3D = enemy.assembly.parts.values()[0]
			if pos.distance_to(p.global_position) < 11.0:
				return true
	return false

func discover_blueprint(data: Dictionary) -> void:
	if not learned_blueprints.has(data):
		learned_blueprints.append(data.duplicate(true))
	last_message = "Machine body studied. Blueprint added to the bench."

func enemy_defeated(_enemy: Node, blueprint: Dictionary) -> void:
	discover_blueprint(blueprint)

func salvage_part(part: Node3D) -> bool:
	if not is_instance_valid(part) or not part.installed or not is_instance_valid(part.assembly):
		return false
	var a: Node = part.assembly
	if not a.get_meta(&"disabled_donor", false) and not part.get_meta(&"salvageable", false):
		last_message = "Live connections: disable the remote core or select dismantling at the bench."
		return false
	a.remove_part(part.part_id)
	_refresh_construction_supports(a)
	add_loose_part(part)
	last_message = "Detached %s. Wako will head-carry it to a container." % part.kind
	return true

func activate_selected() -> void:
	if not is_instance_valid(selected_assembly):
		last_message = "Select and build a blueprint first."
		return
	if _dismantling.has(selected_assembly.get_instance_id()):
		last_message = "Choose Stop dismantling before awakening this machine."
		return
	var unbuilt := 0
	for p: Node in selected_assembly.parts.values():
		if not p.installed:
			unbuilt += 1
	if unbuilt > 0:
		last_message = "%d unfinished components. Inspect their needs or let Wako complete the plan." % unbuilt
		return
	for descriptor: Dictionary in _plans.get(selected_assembly.get_instance_id(),[]):
		if _secondary_pending(selected_assembly,descriptor):
			last_message = "Unsecured structural connectors. Let Wako finish their supported foot work before awakening."
			return
	selected_assembly.activate()
	_release_cradle_if_complete(selected_assembly)
	var has_helm: bool = selected_assembly.parts.values().any(func(part: Node) -> bool: return part.installed and part.kind == "cockpit")
	last_message = "Machine activated. Enter the helm to drive; its current state appears below." if has_helm \
		else "Assembly activated. Installed devices use their connected power sources."

func damage_selected() -> void:
	if is_instance_valid(selected_assembly):
		for p: Node in selected_assembly.parts.values():
			if p.installed and p.kind == "wheel":
				p.take_damage(55, p.global_position, null, &"hit")
				last_message = "Wheel damaged. The crew will inspect and repair it when safe."
				return

func inspect_selected() -> void:
	if not is_instance_valid(selected_assembly):
		last_message = "Select a blueprint or aim at a component to inspect it."
		return
	var lines: Array[String] = [selected_assembly.inspect_status()]
	for p: Node in selected_assembly.parts.values():
		if not p.installed or p.needs_repair():
			lines.append(p.inspect_status())
	last_message = with_construction_needs("\n".join(lines))

func construction_needs() -> String:
	if not is_instance_valid(selected_assembly):
		return ""
	var needs: Array[String] = []
	for p: Node in selected_assembly.parts.values():
		if not p.installed and p.has_meta(&"needs"):
			var need := String(p.get_meta(&"needs"))
			if not needs.has(need):
				needs.append(need)
	return "\n".join(needs)

func with_construction_needs(message: String) -> String:
	for need: String in construction_needs().split("\n", false):
		if not message.contains(need):
			message += "\n" + need
	return message

func blueprint_of(a: Node3D) -> Dictionary:
	var ds: Array = _plans.get(a.get_instance_id(), [])
	var design: Array = ds.duplicate(true)
	for d: Dictionary in design:
		var p: Node = a.parts.get(d.id)
		if p and not Catalogue.design_keys(p.kind).is_empty():
			d.parameters = Catalogue.design_parameters(p.kind, p.parameters)
	return {"name": "Saved contraption", "parts": design, "speed": a.get_meta(&"workshop_speed", 2.2),
		"build_height": a.get_meta(&"workshop_build_height", 1.1)}

func save_blueprint() -> Error:
	if not is_instance_valid(selected_assembly):
		return ERR_UNAVAILABLE
	var path := UserPaths.path("contraptions/blueprint.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if not f:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(blueprint_of(selected_assembly), "\t"))
	last_message = "Blueprint saved. Loading selects a plan; it requires stored components and Wako work."
	return OK

func load_blueprint() -> bool:
	var path := UserPaths.path("contraptions/blueprint.json")
	if not FileAccess.file_exists(path):
		last_message = "Save a blueprint at the bench first."
		return false
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	var error := Plans.validate(data, Catalogue.all())
	if error != "":
		last_message = error
		return false
	return plan_blueprint(data)

func serialize() -> Dictionary:
	var aa: Array = []
	for a: Variant in assemblies:
		if is_instance_valid(a):
			aa.append({"data": a.serialize(), "transform": Part.encode_transform(a.global_transform), "donor": a.get_meta(&"disabled_donor", false),
				"name": String(a.name), "blueprint_name": a.get_meta(&"blueprint_name", ""),
				"worksite_identity":a.get_meta(&"worksite_identity",""),
				"field": {"anchor":a.get_meta(&"field_anchor",{}),"ground_y":a.get_meta(&"field_ground_y",global_position.y)} if a.has_meta(&"field_ground_y") else {},
				"plan": _plans.get(a.get_instance_id(), []), "selected": a == selected_assembly,
				"build_height": a.get_meta(&"workshop_build_height", 1.1),
				"cradled": _cradles.has(a.get_instance_id()),
				"root_cradled": _cradles.has(a.get_instance_id()) and _cradles[a.get_instance_id()].get_meta(&"root_supports",true),
				"root_support": _saved_root_support(a),
				"construction_supports": _saved_construction_supports(a),
				"dismantle": _dismantling.has(a.get_instance_id())})
	var pp: Array = []
	for p: Variant in loose_parts:
		if is_instance_valid(p) and not p.is_queued_for_deletion():
			var bay: Array = []
			var staged: Array = []
			var staged_target: Variant = p.get_meta(&"staged_target") if p.has_meta(&"staged_target") else null
			for i in assemblies.size():
				var a: Variant = assemblies[i]
				if is_instance_valid(a) and a.parts.values().has(p.get_parent()):
					bay = [i, p.get_parent().part_id]
				if is_instance_valid(a) and is_instance_valid(staged_target) and a.parts.values().has(staged_target):
					staged = [i, staged_target.part_id]
			if bay.is_empty() and p.get_parent().get("kind") == "container":
				bay = [-1, p.get_parent().part_id]
			pp.append({"kind": p.kind, "id": p.part_id, "health": p.health, "wear": p.wear, "jammed": p.jammed,
				"position": [p.global_position.x, p.global_position.y, p.global_position.z], "stored": p.get_meta(&"stored", false), "bay": bay,
				"staged": staged,
				"staged_progress": float(p.get_meta(&"staged_work_progress",0.0)),
				"hardware_slot": int(p.get_meta(&"hardware_slot", -1)),
				"depot_display": DepotDisplay.serialized(p),
				"physical_bin_slot":MobileStock.serialized(p),
				"returning_released_stock": p.get_meta(&"returning_released_stock",false) and not p.get_meta(&"stored",false),
				"in_transit": p.get_meta(&"in_transit", false),
				"equipped_worker": str(p.get_meta(&"equipped_worker", "")),
				"awaiting_setdown": p.get_meta(&"awaiting_setdown", false),
				"data": p.serialize()})
	var ww: Array = []
	for w: Variant in workers:
		if is_instance_valid(w):
			ww.append(w.serialize_state())
	var ee: Array = []
	for e: Variant in enemies:
		if is_instance_valid(e) and not e.get_meta(&"wild_owned", false) and e.has_method(&"serialize"):
			ee.append(e.serialize())
	return {"version": 1, "serial": _serial, "maintenance_clock": maintenance_clock, "assemblies": aa, "parts": pp, "workers": ww,
		"enemies": ee, "paused": work_paused, "blueprints": learned_blueprints,
		"worksite":_field_worksite.duplicate(true),
		"crew_travel":_crew_travel.serialize(),
		"coordinator": coordinator.serialize_state() if is_instance_valid(coordinator) else {}}

func restore(data: Variant) -> void:
	if not data is Dictionary or int(data.get("version", 0)) != 1:
		last_message = "Contraption save version is unsupported."
		return
	var material_error := Part.saved_material_tree_error(data)
	if not material_error.is_empty():
		last_message = material_error
		return
	_restore_deferred.call_deferred(data)

func _restore_deferred(data: Dictionary) -> void:
	var material_error := Part.saved_material_tree_error(data)
	if not material_error.is_empty():
		last_message = material_error
		return
	for stock: Dictionary in data.get("parts",[]):
		if stock.get("stored",false) and not stock.get("bay",[]).is_empty() and stock.get("physical_bin_slot",{}).is_empty() and stock.kind not in ["assembly_tool","salvage_tool"]:
			last_message="This legacy mobile load needs full-size physical cargo-rack migration before restore. The current workshop remains unchanged."
			return
	_restoring = true
	if coordinator.has_method(&"cancel_all"):
		coordinator.cancel_all()
	var wild_enemies: Array = enemies.filter(func(e: Variant) -> bool: return is_instance_valid(e) and e.get_meta(&"wild_owned", false))
	for collection: Array in [assemblies, loose_parts, workers, enemies]:
		for n: Variant in collection:
			if is_instance_valid(n) and not wild_enemies.has(n):
				n.queue_free()
		collection.clear()
	enemies.append_array(wild_enemies)
	for c: Node in _cradles.values():
		c.queue_free()
	_cradles.clear()
	_construction_jigs.clear()
	await get_tree().process_frame
	_plans.clear()
	_reservations.clear()
	_dismantling.clear()
	selected_assembly = null
	_field_worksite.clear()
	_field_observation.clear()
	_field_observation_tick = -1
	_crew_travel.restore(data.get("crew_travel",{}))
	_companions.reset()
	var field_saved:Variant = data.get("worksite",{})
	if not field_saved is Dictionary: _field_worksite = {"invalid":true,"crew":[]}
	if field_saved is Dictionary and not field_saved.is_empty():
		var crew:Variant = field_saved.get("crew")
		_field_worksite = field_saved.duplicate(true) if field_saved.get("anchor") is Dictionary and crew is Array \
			and not crew.is_empty() and crew.all(func(id:Variant)->bool:return id is String and not id.is_empty()) else {"invalid":true,"crew":[]}
	_serial = int(data.get("serial", 0))
	maintenance_clock = maxf(float(data.get("maintenance_clock", 0.0)), 0.0)
	work_paused = bool(data.get("paused", false))
	learned_blueprints = data.get("blueprints", [])
	for entry: Dictionary in data.get("assemblies", []):
		var a := Assembly.new()
		if entry.get("name", "") is String and not String(entry.get("name", "")).is_empty():
			a.name = String(entry.name)
		if entry.get("blueprint_name", "") is String:
			a.set_meta(&"blueprint_name", String(entry.get("blueprint_name", "")))
		add_child(a)
		# Pre-root planned poses are local to this node. Installed bodies retain
		# their existing saved world transforms, including legacy records.
		if entry.has("transform"): a.global_transform = Part.decode_transform(entry.transform)
		if entry.get("worksite_identity","") is String and not String(entry.get("worksite_identity","")).is_empty():
			a.set_meta(&"worksite_identity",String(entry.worksite_identity))
		a.restore(entry.data)
		var field_plan:Variant = entry.get("field",{})
		if field_plan is Dictionary and not field_plan.is_empty():
			var floor_value:Variant = field_plan.get("ground_y")
			if field_plan.get("anchor") is Dictionary and (floor_value is int or floor_value is float) and is_finite(float(floor_value)):
				a.set_meta(&"field_anchor",field_plan.anchor.duplicate(true))
				a.set_meta(&"field_ground_y",float(floor_value))
			else: _field_worksite = {"invalid":true,"crew":[]}
		a.set_meta(&"disabled_donor", entry.get("donor", false))
		assemblies.append(a)
		_plans[a.get_instance_id()] = entry.get("plan", [])
		a.set_meta(&"workshop_build_height", float(entry.get("build_height", 1.1)))
		if entry.get("selected", false):
			selected_assembly = a
		if entry.get("dismantle", false):
			_dismantling[a.get_instance_id()] = true
		if not entry.get("donor", false):
			var mount := Mount.new()
			a.add_child(mount)
			mount.setup(a)
			if bool(entry.get("root_cradled", bool(entry.get("cradled", false)) or not a.parts.values().all(func(p: Node) -> bool: return p.installed))):
				# A carried first resource still leaves a planned foundation. The
				# existing cradle finds it before any physical root is installed.
				_create_cradle(a, a.global_position,false,entry.get("root_support",{}))
			_refresh_construction_supports(a,entry.get("construction_supports",[]))
	for d: Dictionary in data.get("parts", []):
		var p := Part.new()
		p.setup(d.kind, d.id, true, d.get("data", {}).get("parameters", {}))
		add_child(p)
		if d.has("data"):
			p.restore_condition(d.data)
		p.health = float(d.health)
		p.wear = float(d.wear)
		p.jammed = bool(d.jammed)
		if d.get("data", {}).has("transform"):
			p.global_transform = Part.decode_transform(d.data.transform)
		else:
			var v: Array = d.position
			p.global_position = Vector3(v[0], v[1], v[2])
		add_loose_part(p)
		if d.get("returning_released_stock",false) == true and not d.get("stored",false): p.set_meta(&"returning_released_stock",true)
		if int(d.get("hardware_slot", -1)) >= 0: p.set_meta(&"hardware_slot", int(d.hardware_slot))
		DepotDisplay.restore_display(p,d.get("depot_display",{}))
		MobileStock.restore_slot(p,d.get("physical_bin_slot",{}))
		var equipped_owner := str(d.get("equipped_worker", ""))
		if not equipped_owner.is_empty():
			p.set_meta(&"equipped_worker", equipped_owner)
			p.freeze = true
			p.collision_layer = 0
			p.collision_mask = 0
		if d.get("awaiting_setdown", false) or (d.get("in_transit", false) and d.get("staged", []).is_empty()):
			# Rebuilt worker IDs cannot own yesterday's carry fixture. Keep its
			# collider disabled until the same safe ground release can resume it.
			p.freeze = true
			p.collision_layer = 0
			p.collision_mask = 0
			p.set_meta(&"awaiting_setdown", true)
			if equipped_owner.is_empty():
				# Protected reconstruction must retain the saved native COM motion.
				p.set_meta(&"restored_cargo_motion",{"velocity":Part.decode_vector(d.get("data",{}).get("velocity",[0,0,0])),"spin":Part.decode_vector(d.get("data",{}).get("angular_velocity",[0,0,0]))})
	for d: Dictionary in data.get("parts", []):
		var p: Node3D
		for candidate: Node3D in loose_parts:
			if candidate.part_id == d.id: p = candidate; break
		if p == null:
			continue
		if d.get("stored",false):
			# Legacy compact geometry is converted once during ordinary offline
			# reconstruction, before this saved stock receives any live job. Never
			# expand or restore a previous basis at actual head/foot contact.
			p.global_basis=p.global_basis.orthonormalized()
			var bay: Node3D = storage
			var locator: Array = d.get("bay", [])
			var exact_bay := locator.is_empty()
			if locator.size() == 2 and int(locator[0]) >= 0 and int(locator[0]) < assemblies.size():
				bay = assemblies[int(locator[0])].parts.get(String(locator[1]))
				exact_bay = is_instance_valid(bay) and bay.kind == "container"
			elif locator.size() == 2 and int(locator[0]) == -1:
				for candidate: Node3D in loose_parts:
					if candidate != p and candidate.kind == "container" and candidate.part_id == String(locator[1]):
						bay = candidate
						exact_bay = true
						break
			if not worksite_active() and (not exact_bay or not is_instance_valid(bay)): bay = storage
			if worksite_active() and (not exact_bay or not is_instance_valid(bay)):
				# A corrupt/departed bay must not move field stock back to the
				# original depot. Keep its saved body nearby for safe set-down.
				prepare_cargo(p)
				_release_staged_component(p, [])
			elif not store_part(p, bay):
				if worksite_active():
					prepare_cargo(p)
					_release_staged_component(p, [])
				else: store_part(p, storage)
		var staged: Array = d.get("staged", [])
		if staged.size() == 2 and int(staged[0]) >= 0 and int(staged[0]) < assemblies.size():
			var target: Node = assemblies[int(staged[0])].parts.get(String(staged[1]))
			if is_instance_valid(target) and not target.installed:
				_stage_component(p, target)
				var paid: Variant=d.get("staged_progress",0.0)
				if (paid is float or paid is int) and is_finite(float(paid)): p.set_meta(&"staged_work_progress",clampf(float(paid),0.0,.95))
	for d: Dictionary in data.get("workers", []):
		var w := spawn_worker(global_position + Vector3(0, 1, 3))
		w.restore_state(d)
	for tool: Node3D in loose_parts:
		var owner := str(tool.get_meta(&"equipped_worker", ""))
		if owner.is_empty(): continue
		var crew: Array = workers.filter(func(w: Node) -> bool: return w.worker_id == owner)
		if not crew.is_empty():
			if not crew[0].back_tool or not crew[0].back_tool.bind_restored_item(tool): _equip_worker_tool(tool, crew[0])
		else:
			tool.remove_meta(&"equipped_worker")
			_release_staged_component(tool, [])
	for d: Dictionary in data.get("enemies", []):
		var e := Fauna.new()
		add_child(e)
		if e.has_method(&"restore"):
			e.restore(d, self)
			enemies.append(e)
		else:
			e.queue_free()
	# IDs referencing old runtime Nodes cannot safely resume. Physical cargo remains;
	# cancelled jobs are reclaimed atomically by fresh job discovery.
	coordinator.restore_state(data.get("coordinator", {}))
	# All saved worker/tool frames now exist. Resume interrupted loose cargo
	# at its exact saved pose and motion, with temporary crew collision safety,
	# instead of losing that motion during the half-second protected wait.
	for p: RigidBody3D in loose_parts:
		if not p.has_meta(&"restored_cargo_motion"): continue
		var motion: Dictionary=p.get_meta(&"restored_cargo_motion")
		p.remove_meta(&"restored_cargo_motion")
		if p.get_meta(&"awaiting_setdown",false) and not is_instance_valid(p.carrier):
			_resume_cargo_callbacks(p)
			_stock_release.release(p,workers,motion)
	_restoring = false
	last_message = "Workshop restored. Interrupted jobs recover from their remaining physical parts."

func staged_job_valid(job: Dictionary, _crew: Array=[]) -> bool:
	# Preserve only an actually admitted source on this exact live plan slot.
	# Plan removal and changed/unsupported native frames retain normal release.
	if job.get("kind","") not in ["build","replace"]: return false
	var source: RigidBody3D=job.get("part")
	var target: RigidBody3D=job.get("target")
	if not is_instance_valid(source) or not is_instance_valid(target) or source==target or not source.is_inside_tree() or not target.is_inside_tree() or source.is_queued_for_deletion() or target.is_queued_for_deletion(): return false
	if is_instance_valid(source.assembly) or not source.has_meta(&"staged_target") or source.get_meta(&"staged_target")!=target or source.carrier!=target or not source.freeze or not source.get_meta(&"in_transit",false): return false
	var assembly: Node3D=target.assembly
	if not is_instance_valid(assembly) or not assembly.is_inside_tree() or assembly.is_queued_for_deletion() or not assemblies.has(assembly) or assembly.parts.get(target.part_id)!=target: return false
	var same_plan:=false
	for descriptor: Dictionary in _plans.get(assembly.get_instance_id(),[]):
		if str(descriptor.get("id",""))==target.part_id and descriptor==job.get("descriptor",{}): same_plan=true; break
	if not same_plan or (job.kind=="build" and (target.installed or not target.planned)) or (job.kind=="replace" and (not target.installed or target.health>0.0)): return false
	if source.kind!=target.kind or not Catalogue.same_shape(source.kind,source.parameters,target.parameters) or not job_service_reason(job).is_empty() or not _material_arrived(source,target.global_transform): return false
	var root: RigidBody3D=assembly.root_part()
	if not is_instance_valid(root):
		# The first planned foundation has no installed root until paid work finishes.
		# Reuse its existing native ground cradle; never create support during validation.
		var cradle: Node3D=_cradles.get(assembly.get_instance_id())
		if job.kind!="build" or not is_instance_valid(cradle) or not cradle.is_inside_tree() or cradle.is_queued_for_deletion() or not cradle.get_meta(&"root_supports",false) or not cradle.has_meta(&"root_support_pose"): return false
		var foundation: RigidBody3D
		for candidate: RigidBody3D in assembly.parts.values():
			if str(candidate.get_meta(&"plan_parent","")).is_empty(): foundation=candidate; break
		if foundation!=target or not _material_arrived(source,cradle.get_meta(&"root_support_pose")): return false
		var supported:=false
		for support: StaticBody3D in cradle.find_children("*","StaticBody3D",true,false):
			if support.is_inside_tree() and not support.is_queued_for_deletion() and (support.collision_layer&1)!=0 and PhysicsServer3D.body_get_space(support.get_rid())==get_world_3d().space: supported=true; break
		if not supported: return false
		root=target
	if not is_instance_valid(root) or not root.is_inside_tree(): return false
	var native:=PhysicsServer3D.body_get_direct_state(root.get_rid())
	if not native or native.linear_velocity.length()>.25 or native.angular_velocity.length()>.1: return false
	# Admission already proved crew support before this source left their heads.
	# The same arrived target fixture now owns it independently of later foot work.
	return true

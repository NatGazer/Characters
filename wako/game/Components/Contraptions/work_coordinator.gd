extends Node
const PhysicalDepot := preload("res://Components/Contraptions/depot_stock_layout.gd")
## One scheduler per workshop. Reservations are atomic in the yard and never owned independently by helpers.
## Tasks are chosen automatically; control stations exclude every locomotion helm.

const Access = preload("res://Components/Contraptions/worker_access.gd")
const Catalogue = preload("res://Components/Contraptions/part_catalog.gd")
const Pickup = preload("res://LogicObjects/Wako/wako_pickup.gd")
const RampAnchor = preload("res://Components/Contraptions/ramp_work_anchor.gd")
const ToolAccess = preload("res://Components/Contraptions/worker_tool_access.gd")
const StorageAccess = preload("res://Components/Contraptions/worker_storage_access.gd")
const Egress = preload("res://Components/Contraptions/worker_ramp_egress.gd")
const FieldWorksite = preload("res://Components/Contraptions/worker_field_worksite.gd")
const UnloadingHold = preload("res://Components/Contraptions/worker_unloading_hold.gd")
const CrewTravel = preload("res://Components/Contraptions/worker_crew_travel.gd")
const BeamPreparation := preload("res://Components/Contraptions/beam_material_preparation.gd")

var yard: Node3D
var workers: Array = []
var active_jobs: Dictionary = {}
var completed: Dictionary = {}
var blocked: Dictionary = {}
var _retry_after: Dictionary = {}
var _retry_reasons: Dictionary = {}
var _head_return_reasons: Dictionary = {}
const HEAD_RETURN_FAILURE_PREFIX := "No clear original-stock return arc; source remains at its actual head-contact pose: "
var _clock := 0.0

# Opt-in diagnostic scalars only. Each inclusive subtree is reported separately;
# nested timings must never be added together. Disabled during ordinary play.
var source_budget_enabled := "--easy-island-source-budget" in OS.get_cmdline_user_args()
var source_budget: Dictionary = {}
var _refresh_clock := 0.0
var _pending_resume: Array = []
var _jobs: Array = []
var _routes: Dictionary = {}
# Only exact immutable coarse rectangles share corner-to-corner visibility.
# Native floor, capsule, cargo and next-waypoint checks still run live.
var _route_visibility_cache: Array[Dictionary] = []
var _depot_tool_admission_until: Dictionary = {}
var _depot_tool_admission_cursor: Dictionary = {}
var _work_area_wait: Dictionary = {}
var _field_routes: Dictionary = {}
var _field_work_debug := "--field-work-debug" in OS.get_cmdline_user_args()

func setup(service: Node3D) -> void:
	yard = service

func register_worker(worker: Node) -> void:
	if workers.has(worker): return
	workers.append(worker)
	worker.action_contact.connect(_on_contact.bind(worker))
	worker.action_finished.connect(_on_action_finished.bind(worker))
	worker.tree_exiting.connect(_on_worker_removed.bind(worker))
	worker.coordinator = self
	worker.current_job_id = ""

func _physics_process(delta: float) -> void:
	if not is_instance_valid(yard): return
	_clock += delta
	_refresh_clock += delta
	for id: String in active_jobs.keys():
		if active_jobs.has(id): _tick_job(active_jobs[id], delta)
	for worker: Node in workers:
		if is_instance_valid(worker) and worker.current_job_id.is_empty() and not worker.head_leap.active() and CrewTravel.eligible(yard,worker): _tick_station(worker, delta)
	if _refresh_clock >= .25:
		_refresh_clock = 0.0
		refresh_jobs()

func refresh_jobs() -> void:
	workers = workers.filter(func(w: Variant) -> bool: return is_instance_valid(w) and not w.is_queued_for_deletion())
	for worker: Node in workers:
		if CrewTravel.assigned(yard,worker) and is_instance_valid(worker.station):
			# Admission refuses occupied stations. Contradictory saved assignments
			# must release their ordinary binding before travel can retain the crew.
			_leave_station(worker)
			yard.crew_travel_cancel("Saved crew route conflicts with an occupied station; leave it and resume the route")
	_prune_head_return_feedback()
	if yard.work_paused:
		cancel_all("Work paused; cargo returned safely")
		# Only the explicit public shoreline trip may keep native idle travel
		# while useful work is paused. Its actual jobs/custody already recovered.
		if yard.crew_travel_active() and yard.crew_travel_context().get("purpose")=="water":
			for worker:Node in workers:
				if worker.current_job_id.is_empty() and worker.action.is_empty() and not worker.head_leap.active() and not worker.paused and worker.is_available(): CrewTravel.tick_idle(yard,worker)
		return
	_jobs = yard.work_jobs()
	if not _work_area_wait.is_empty():
		var pending := {}
		for job: Dictionary in _jobs:
			if _work_area_wait.has(job.get("id","")): pending[job.id] = _work_area_wait[job.id]
		_work_area_wait = pending
	_jobs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _job_priority(a) > _job_priority(b))
	blocked.clear()
	var gathering_priority := -1
	var gathering_reason := ""
	for job: Dictionary in _jobs:
		var id := str(job.get("id", ""))
		if id.is_empty() or active_jobs.has(id): continue
		if float(_retry_after.get(id, 0.0)) > _clock:
			blocked[id] = str(_retry_reasons.get(id, "Checking work access"))
			continue
		if not _nodes_valid(job): continue
		var reason := str(job.get("blocked", ""))
		var operating: bool = job.kind == "operate" and job.target.kind in ["gun", "station"]
		var supported_operator: bool = operating and workers.any(func(w: Node) -> bool: return CrewTravel.eligible(yard,w) and FieldWorksite.eligible(yard,w) and w.is_available() and w.current_job_id.is_empty() and _free_worker_return_ready(w) and w.supported_by(job.target.assembly) and w.can_reach_target(job.target))
		if operating:
			job.heavy = false # A control operator is not lifting the weapon or workstation.
			if supported_operator and reason == "Stop the machine for safe work":
				reason = ""
				job.blocked = ""
		if not reason.is_empty():
			blocked[id] = reason
			continue
		var deps: Array = job.get("dependencies", [])
		if deps.any(func(dep: Variant) -> bool: return not completed.has(str(dep))):
			blocked[id] = "Waiting for supporting components"
			continue
		if (yard.unsafe_at(job.part.global_position) or yard.unsafe_at(job.target.global_position)) and not (operating and job.target.kind == "gun" and supported_operator):
			blocked[id] = "Enemy nearby; waiting in shelter"
			continue
		# Workstations may automate a weapon/utility, never a motion cockpit.
		if job.kind == "operate" and str(job.target.get("kind")) in ["cockpit", "helm", "motion_cockpit"]: continue
		if gathering_priority>=0 and int(job.get("priority",0))<gathering_priority:
			blocked[id] = gathering_reason
			continue
		var crew := _available_crew(job)
		if crew.is_empty():
			if blocked.has(id): continue # Retain the precise prospective tool-route reason.
			if operating and job.target.linear_velocity.length() > .25:
				blocked[id] = "Machine moving; Wako need a supported control platform"
				continue
			var capacity := 60.0 if workers.is_empty() else float(workers[0].carry_capacity)
			var needed := _required_crew(job, capacity)
			var available := workers.filter(func(w: Node) -> bool: return CrewTravel.eligible(yard,w) and FieldWorksite.eligible(yard,w) and w.is_available() and w.current_job_id.is_empty() and _free_worker_return_ready(w) and not w.head_leap.active() and not w.paused and w.fear_time <= 0.0).size()
			if needed > available: blocked[id] = "%d Wako needed for %.0f kg load (%d available)" % [needed, job.part.mass, available]
			# Keep an idle partner for ready cooperative service or construction.
			# Let existing jobs finish; otherwise lower-priority solo cleanup
			# consumes each released helper and starves the ready shared job.
			if job.kind in ["repair","unbend","build","replace","dismantle"] and needed>available and available>0:
				var eligible: Array = workers.filter(func(w:Node)->bool:return CrewTravel.eligible(yard,w) and FieldWorksite.eligible(yard,w) and w.is_available() and not w.paused and w.fear_time<=0.0)
				var tool_ready: bool = eligible.any(func(w:Node)->bool:return w.current_job_id.is_empty() and _free_worker_return_ready(w) and not w.head_leap.active() and yard.tool_for_job(job,w)!=null)
				if eligible.size()>=needed and tool_ready:
					gathering_priority = int(job.get("priority",0))
					gathering_reason = "Gathering %d Wako for %s (%d ready)" % [needed,job.kind,available]
					blocked[id] = gathering_reason
			continue
		if job.get("heavy", false) and crew.size() < 2:
			blocked[id] = "Two Wako needed for this load"
			continue
		var capability: String = yard.work_tool_capability(str(job.kind))
		if not capability.is_empty() and yard.tool_for_job(job, crew[0]) == null:
			var healthy: bool = yard.loose_parts.any(func(tool: Node) -> bool: return is_instance_valid(tool) and (not FieldWorksite.active(yard) or yard.worksite_source(tool)) and yard.tool_compatible(tool, capability))
			blocked[id] = _unavailable_tool_reason(capability) if healthy else "Missing compatible %s tool; store a working mallet or fastener pickaxe" % capability
			continue
		var area_reason := _work_area_reason(job,crew)
		if not area_reason.is_empty():
			blocked[id] = area_reason
			if not _work_area_wait.has(id): _work_area_wait[id] = _clock
			continue
		_work_area_wait.erase(id)
		if not yard.reserve_job(job, crew): continue
		# Solo fetch of a light compatible part (wako_pickup.gd limits: <= 5 kg,
		# <= .4 m, on the worker's floor, not a tool or installed, no failed
		# toss yet) uses the toe toss and head catch.
		job.light_pickup = crew.size() == 1 and job.kind in ["build","replace","salvage"] and Pickup.eligible(job.part,crew[0])
		job.head_first_pickup = job.kind in ["build","replace","salvage"] and not job.light_pickup
		var entry := {"job": job, "crew": crew, "phase": "fetch" if job.kind in ["build", "replace", "salvage"] else "approach",
			"elapsed": 0.0, "progress": _resume_progress(job), "pickup": false, "contacts": 0, "complete": false}
		if yard.staged_job_valid(job,crew):
			entry.phase = "approach"
			entry.staged = true
			entry.pickup = true
		if job.kind in ["build", "replace", "salvage"] and job.part.get_meta(&"stored", false):
			if crew.size()>1: entry.storage_axis = _storage_crew_axis(job.part)
			entry.open_depot = job.head_first_pickup and job.part.get_parent() == yard.storage
			entry.phase = "fetch_outside"
			entry.exit_position = _storage_approach(job.part, true)
			var container := job.part.get_parent() as Node3D
			var half := Vector3(2.5, 0, 2.5)
			if container.get("kind") == "container":
				half = container.definition.size * .5
				var frame := _assembly_frame(container)
				if frame:
					container = frame
					half = frame.definition.size * .5
			var sign_x := 1.0 if job.target.global_position.x >= container.global_position.x else -1.0
			entry.outside_position = container.to_global(Vector3(sign_x * (half.x + 1.4), 0, half.z + 1.2))
			entry.outside_position.y = entry.exit_position.y
			var physical_aisle := PhysicalDepot.aisle(job.part,job.part.get_parent(),true)
			if not physical_aisle.is_empty():
				entry.outside_position=physical_aisle.point
				# Open native rows have no container entrance. Let the existing
				# whole-row obstacle router choose the shortest clear approach.
				# Loaded departure still uses the original exterior cargo lane.
				if entry.open_depot: entry.phase="fetch"
			elif crew.size()==1 and job.head_first_pickup and StorageAccess.depot_head_source(crew[0],job.part):
				# Compact native depot stock also has no container entrance. Walk
				# to its own admitted launch floor before the ordinary head leap.
				entry.phase="fetch"
		if is_instance_valid(job.get("tool")) and crew[0].equipped_tool != job.tool:
			entry.resume_phase = entry.phase
			entry.phase = "tool_route"
			if ToolAccess.depot_tool(crew[0],job.tool):
				# Reserve intent for the original finite fitting/stow sweep, not
				# a collider or teleport. Peers leave it through native walking.
				entry.tool_service_point=ToolAccess.pickup_point(job.tool)
				entry.tool_service_radius=_depot_tool_service_radius(crew[0],job.tool)
		active_jobs[id] = entry
		for crew_index in crew.size():
			var worker: Node = crew[crew_index]
			worker.task_label_owner = crew_index == 0
			_leave_station(worker)
			var idle_play: RefCounted = worker.get("idle_play")
			if idle_play: idle_play.cancel("Useful job reserved")
			worker.current_job_id = id
			_field_routes.erase(worker.get_instance_id())
			worker.needs = ""
			worker.progress = float(entry.progress)
			worker.work_target = job.connection.b if job.kind == "unbend" and is_instance_valid(job.get("connection")) else job.target
			worker.safe_position = _parking_position(worker)
			worker.status_text = "Fetching " + _part_title(job) if entry.phase == "fetch" else "Inspecting " + _part_title(job)
		# Eyes reach the next target as the lease is reserved, before departure.
		_publish_attention(entry)
	# Unclaimed helpers stay behind the workshop instead of roaming into combat.
	var blocked_reported := false
	for worker: Node in workers:
		if not worker.current_job_id.is_empty() or worker.paused or not worker.is_available() or worker.head_leap.active(): continue
		if is_instance_valid(worker.station): continue
		if worker.get("portable_gun") != null and worker.portable_gun.transport_stance_claim() and not yard.unsafe_at(worker.global_position):
			worker.stop_navigation()
			worker.needs = ""
			worker.status_text = "Passing the same gun"
			continue
		if CrewTravel.tick_idle(yard,worker): continue
		if FieldWorksite.tick_idle(yard,worker,_field_routes,_clock,blocked): continue
		worker.safe_position = _parking_position(worker)
		if _tool_service_yield_needed(worker) and not yard.unsafe_at(worker.global_position) and worker.fear_time<=0.0:
			# Idle play still keeps its native landing/recovery. A nearby tool
			# operation suppresses new antics until this real passage is free.
			if worker.idle_play: worker.idle_play.cancel("Clearing the original tool service passage")
			worker.needs="Giving the tool crew room to fit and stow"
			worker.status_text=worker.needs
			if _navigate(worker,worker.safe_position-Vector3.UP*worker.ride_height): worker.stop_navigation()
			continue
		var expression: RefCounted = worker.get("personality")
		if expression: worker.safe_position = expression.safe_retreat_position(worker.safe_position)
		if worker.get("portable_gun") != null and worker.portable_gun.defence_stance_ready():
			# Useful leases and companion/field duties above still take priority.
			# The real supported gun retains its own hostile aim, finite state,
			# full-stock clearance and interruption on a hit or lost plant.
			worker.stop_navigation()
			worker.needs = ""
			worker.status_text = "Supported foot-held gun"
		elif yard.unsafe_at(worker.global_position) or worker.fear_time > 0.0:
			worker.status_text = "Taking cover"
			worker.navigate_to(worker.safe_position - Vector3.UP * worker.ride_height)
		elif not blocked.is_empty():
			worker.status_text = str(blocked.values()[0])
			# One representative carries the shared blocked reason for the Build
			# panel; the rest stay free for play, greetings and eye smiles while
			# they wait. Per-helper refusals above still set their own needs.
			if not blocked_reported:
				blocked_reported = true
				worker.needs = worker.status_text
			else:
				worker.needs = ""
				var waiting_play: RefCounted = worker.get("idle_play")
				if waiting_play and waiting_play.idle_navigation_claim(): continue
			if _navigate(worker, worker.safe_position - Vector3.UP * worker.ride_height): worker.stop_navigation()
		elif worker.get("portable_gun") != null and worker.portable_gun.idle_stance_claim():
			worker.stop_navigation()
			worker.needs = ""
			worker.status_text = "Supported foot-held gun"
		else:
			var idle_play: RefCounted = worker.get("idle_play")
			if idle_play and idle_play.idle_navigation_claim(): continue
			if _navigate(worker, worker.safe_position - Vector3.UP * worker.ride_height): worker.stop_navigation()
			worker.needs = ""
			worker.status_text = "Watching for salvage and maintenance"

func _parking_position(worker: Node) -> Vector3:
	if CrewTravel.assigned(yard,worker): return CrewTravel.parking_position(yard,worker)
	if FieldWorksite.active(yard): return FieldWorksite.parking_position(yard,worker)
	var slot := maxi(workers.find(worker), 0)
	# Park behind the actual tool bay, outside its supported fitting and
	# complete-tool stow passage. Workers reach these places by native walking.
	var row_z := PhysicalDepot.TOOL_ROW_Z+2.5
	var ordinary: Vector3=yard.to_global(Vector3(-10.5 + (slot % 4) * 1.3, worker.ride_height, row_z + floori(slot / 4.0) * 1.3))
	# The nominal row can be inside a full Mallet's rear turn. Extend only
	# this parking intent; the unchanged route/floor solver owns movement.
	var tool_lanes: Array[Dictionary]=_tool_service_lanes()
	for step: int in 7:
		var candidate: Vector3=ordinary+yard.global_basis.z*(float(step)*.6)
		var clear:=true
		for lane: Dictionary in tool_lanes:
			if lane.owner==worker: continue
			# Native parking can stop .7m before its intent. Leave that same
			# arrival band outside the full tool passage, plus its .12m margin.
			if (candidate-Vector3(lane.point)).slide(Vector3.UP).length()<float(lane.radius)+.82: clear=false; break
		if clear: return candidate
	return ordinary

func _depot_tool_service_radius(worker: RigidBody3D,tool: Node3D) -> float:
	# Two original finite reaches cover grip-to-body fitting and the later
	# toe-to-cradle sweep. Include the entire actual tool and peer capsule.
	var body_reach:=0.0
	for side: int in 2:
		body_reach=maxf(body_reach,worker._hip_rest_offsets[side].slide(Vector3.UP).length()+worker._leg_span(side))
	var grip: Vector3=tool.to_local(ToolAccess.pickup_point(tool))
	var bounds: AABB=PhysicalDepot.bounds(tool)
	var tool_reach:=0.0
	for corner: int in 8: tool_reach=maxf(tool_reach,bounds.get_endpoint(corner).distance_to(grip))
	var capsule: CapsuleShape3D=worker.get_node("Collision").shape
	return body_reach*2.0+tool_reach+capsule.radius+.12

func _depot_tool_service_lane(entry: Dictionary) -> Dictionary:
	if not entry.has("tool_service_point") or entry.get("tool_service_departed",false) or entry.crew.is_empty(): return {}
	var owner: RigidBody3D=entry.crew[0]
	var tool: Node3D=entry.job.get("tool")
	if not is_instance_valid(owner) or not is_instance_valid(tool): return {}
	var owned: bool=owner.equipped_tool==tool and yard.worker_owns_work_tool(owner,tool)
	if not owned and not ToolAccess.depot_tool(owner,tool): return {}
	var point: Vector3=entry.tool_service_point
	var radius: float=entry.tool_service_radius
	# Release only after genuine same-body seated custody, sole recovery
	# and native departure. A still-stowing or nearby owner keeps the lane.
	if owned and owner.back_tool and owner.back_tool.phase=="back" and not owner.back_tool.busy() \
			and (owner.global_position-point).slide(Vector3.UP).length()>radius:
		entry.tool_service_departed=true
		return {}
	# After real fitting contact the same tool moves with its owner. A
	# stalled stow at the build must not reserve the now-empty depot bay.
	return {"owner":owner,"point":owner.global_position if owned else point,"radius":radius,"tool":tool,"crew":entry.crew}

func _tool_service_lanes() -> Array[Dictionary]:
	var lanes: Array[Dictionary]=[]
	for entry: Dictionary in active_jobs.values():
		var lane: Dictionary=_depot_tool_service_lane(entry)
		if not lane.is_empty(): lanes.append(lane)
	# Installation releases its lease before the original foot tool finishes
	# stowing. Retrieval can also belong to a job without a depot acquisition.
	# Keep the same real passage only while that actual transfer owns the tool.
	for owner: RigidBody3D in workers:
		if not is_instance_valid(owner) or not owner.back_tool \
				or not owner.back_tool.blocks_navigation(): continue
		var tool: Node3D=owner.equipped_tool
		if not yard.worker_owns_work_tool(owner,tool): continue
		lanes.append({"owner":owner,"point":owner.global_position,
			"radius":_depot_tool_service_radius(owner,tool),"tool":tool,"crew":[]})
	return lanes

func _tool_service_peers_clear(entry: Dictionary) -> bool:
	var lane: Dictionary=_depot_tool_service_lane(entry)
	if lane.is_empty(): return true
	for peer: Node3D in workers:
		if peer==lane.owner or not is_instance_valid(peer): continue
		if (peer.global_position-Vector3(lane.point)).slide(Vector3.UP).length()<float(lane.radius): return false
	return true

func _clear_tool_service_partners(entry: Dictionary) -> void:
	var depot_service: bool=entry.has("tool_service_point")
	for partner: Node in entry.crew:
		if partner==entry.crew[0]: continue
		partner.safe_position=_parking_position(partner)
		partner.status_text="Clearing the full work tool passage" if depot_service else "Waiting for the work tool"
		# These partners still own this useful lease, so the idle-yield branch
		# cannot move them. Use the same live supported depot route and exact
		# parking endpoint while the lead fetches and completes its fitting.
		var parking: Vector3=partner.safe_position-Vector3.UP*partner.ride_height
		if _navigate(partner,parking,.12 if depot_service else .7,false,yard.storage if depot_service else null) \
				and (not depot_service or (partner.global_position-parking).slide(Vector3.UP).length()<.12):
			partner.stop_navigation()

func _hold_owned_tool_service_peer(worker: RigidBody3D) -> bool:
	# An active head leap, foot action or another original tool transfer must
	# finish its own physical recovery; only ordinary fetching travel yields.
	if worker.carrying or worker.cargo_mass>0.0 or not worker.action.is_empty() \
			or worker.head_leap.active() or (worker.back_tool and worker.back_tool.blocks_navigation()): return false
	for lane: Dictionary in _tool_service_lanes():
		if lane.owner==worker: continue
		var owner: RigidBody3D=lane.owner
		if not owner.back_tool or not owner.back_tool.blocks_navigation() \
				or not yard.worker_owns_work_tool(owner,lane.tool): continue
		# Keep the acquisition partner parked for the whole real transfer.
		# Other fetching helpers yield before entering its full tool passage.
		if not lane.crew.has(worker) \
				and (worker.global_position-Vector3(lane.point)).slide(Vector3.UP).length()>=float(lane.radius)+.82: continue
		worker.safe_position=_parking_position(worker)
		worker.status_text="Clearing the owned tool's stow passage"
		var parking: Vector3=worker.safe_position-Vector3.UP*worker.ride_height
		if _navigate(worker,parking,.12,false,yard.storage) \
				and (worker.global_position-parking).slide(Vector3.UP).length()<.12:
			worker.stop_navigation()
		return true
	return false

func _tool_service_yield_needed(worker: Node3D) -> bool:
	for lane: Dictionary in _tool_service_lanes():
		if lane.owner==worker: continue
		# Original solo-play routes can extend 3.6m from parking. Finish a
		# native action safely, then keep the nearby passage for useful work.
		if (worker.global_position-Vector3(lane.point)).slide(Vector3.UP).length()<float(lane.radius)+3.6: return true
	return false

func _job_priority(job: Dictionary) -> float:
	var priority := float(job.get("priority",0))
	# Routine service eventually wins an opening between construction leases,
	# while urgent repair and structural closure retain their existing priority.
	if job.kind == "maintenance" and _work_area_wait.has(job.id):
		priority += minf((_clock-float(_work_area_wait[job.id]))*2.0,60.0)
	return priority

func _work_area_points(job: Dictionary, crew: Array, entry: Dictionary = {}) -> Array[Vector3]:
	var intent := job.duplicate()
	if not is_instance_valid(intent.get("tool")) and not yard.work_tool_capability(str(job.kind)).is_empty():
		intent.tool = yard.tool_for_job(job,crew[0])
	var point: Vector3 = entry.local_point if entry.has("local_point") else _work_position(intent,job.target,false)
	var axis := Vector3.RIGHT
	if entry.has("local_axis"): axis = entry.local_axis
	else:
		var frame := _assembly_frame(job.target)
		if frame:
			var radial := (point-frame.global_position).slide(Vector3.UP)
			var envelope := _assembly_bounds(job.target.assembly)
			axis = Vector3.FORWARD if absf(radial.x)/maxf(envelope.size.x,.1)>absf(radial.z)/maxf(envelope.size.y,.1) else Vector3.RIGHT
	var points: Array[Vector3] = []
	for i in crew.size(): points.append(point+axis*(i*2.0-1.0)*.49 if crew.size()>1 else point)
	return points

func _work_area_reason(job: Dictionary, crew: Array) -> String:
	var requested_tool: Node3D=job.get("tool")
	if not is_instance_valid(requested_tool) and not yard.work_tool_capability(str(job.kind)).is_empty(): requested_tool=yard.tool_for_job(job,crew[0])
	if is_instance_valid(requested_tool) and requested_tool!=crew[0].equipped_tool and ToolAccess.depot_tool(crew[0],requested_tool):
		var grip: Vector3=ToolAccess.pickup_point(requested_tool)
		var radius: float=_depot_tool_service_radius(crew[0],requested_tool)
		for active: Dictionary in active_jobs.values():
			var lane: Dictionary=_depot_tool_service_lane(active)
			if not lane.is_empty() and (grip-Vector3(lane.point)).slide(Vector3.UP).length()<radius+float(lane.radius):
				return "Waiting for the nearby tool crew to finish fitting and clear its cradle passage"
	var proposed := _work_area_points(job,crew)
	for active: Dictionary in active_jobs.values():
		var occupied := _work_area_points(active.job,active.crew,active)
		for point: Vector3 in proposed:
			for other: Vector3 in occupied:
				# Retain .85 m native peer avoidance plus both .12 m arrival bands.
				if (point-other).slide(Vector3.UP).length()<1.09:
					return "Waiting for the nearby work crew to clear its connector"
		for hauling: Dictionary in [{"job":job,"points":proposed},{"job":active.job,"points":occupied}]:
			if hauling.job.kind not in ["build","replace","salvage"]: continue
			var source: Node3D = hauling.job.part
			var size: Vector3 = Catalogue.bounds_of(source.definition).size
			var centre: Vector3 = (hauling.points[0]+hauling.points[-1])*.5
			var radius := Vector2(size.x,size.z).length()*.5+.31
			var others: Array[Vector3] = occupied if hauling.job==job else proposed
			for point: Vector3 in others:
				if absf(point.y-centre.y)<.5 and (point-centre).slide(Vector3.UP).length()<radius:
					return "Waiting for the nearby head-carry crew to clear its load"
	return ""

func _free_worker_return_ready(worker: Node) -> bool:
	# A completed contact releases its lease before the actual work clip and
	# finite foot/tool exit end. Keep that free helper out of new reservations
	# until its existing return has finished. Active leases remain unchanged;
	# a supported station duty can still yield to a new useful job.
	if not worker.action.is_empty() and not is_instance_valid(worker.station): return false
	if worker.back_tool and worker.back_tool.recovering(): return false
	var idle_play: RefCounted = worker.get("idle_play")
	if idle_play and idle_play.physical_recovery_pending(): return false
	return not worker._pose or worker._pose._work_release.is_empty()

func empty_tool_parking_departure_ready(worker: Node) -> bool:
	if not is_instance_valid(yard) or yard.work_paused: return false
	var route: Dictionary=_routes.get(worker.get_instance_id(),{})
	if not route.has("empty_tool_departure") or float(route.get("until",0.0))<_clock: return false
	var parking: Vector3=worker.safe_position-Vector3.UP*worker.ride_height
	return Vector3(route.goal).is_equal_approx(parking) \
		and Vector3(route.empty_tool_departure).is_equal_approx(worker.target_position) \
		and not yard.unsafe_at(worker.global_position) and not yard.unsafe_at(worker.target_position) \
		and not yard.unsafe_at(parking)

func _available_crew(job: Dictionary) -> Array:
	job.erase("_prospective_tool")
	var free: Array = workers.filter(func(w: Node) -> bool: return CrewTravel.eligible(yard,w) and FieldWorksite.eligible(yard,w) and w.current_job_id.is_empty() and w.is_available() and _free_worker_return_ready(w) and not w.head_leap.active() and not w.paused and w.fear_time <= 0.0)
	if job.kind == "operate":
		free = free.filter(func(w: Node) -> bool: return not is_instance_valid(w.station))
		if job.target.linear_velocity.length() > .25 or (job.target.kind == "gun" and yard.unsafe_at(job.target.global_position)):
			free = free.filter(func(w: Node) -> bool: return w.supported_by(job.target.assembly) and w.can_reach_target(job.target))
	var point: Vector3 = job.part.global_position
	var capability: String = yard.work_tool_capability(str(job.kind))
	free.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		# A reusable compatible tool already held by an idle helper is available;
		# selecting a nearer unequipped helper must not turn it into missing stock.
		var a_tool: bool = not capability.is_empty() and is_instance_valid(a.equipped_tool) and yard.tool_compatible(a.equipped_tool, capability)
		var b_tool: bool = not capability.is_empty() and is_instance_valid(b.equipped_tool) and yard.tool_compatible(b.equipped_tool, capability)
		return a_tool if a_tool != b_tool else a.global_position.distance_squared_to(point) < b.global_position.distance_squared_to(point))
	for saved: Dictionary in _pending_resume:
		if _saved_job_matches(job, saved):
			var saved_ids: Array = saved.get("workers", [])
			free.sort_custom(func(a: Node, b: Node) -> bool: return saved_ids.has(a.worker_id) and not saved_ids.has(b.worker_id))
			break
	var required := _required_crew(job, 60.0 if free.is_empty() else float(free[0].carry_capacity))
	if free.size() < required: return []
	if not capability.is_empty():
		var lead_index := -1
		var admitted_tool: Node3D
		for i in free.size():
			var candidate: RigidBody3D = free[i]
			var cursors: Dictionary = _depot_tool_admission_cursor.get(candidate.get_instance_id(), {})
			var tool: Node3D = yard.tool_for_job(job, candidate, cursors.get(capability, {}))
			# Only the lead fetches the work tool. Keep the other eligible helpers
			# available as load partners, and retain existing missing-stock feedback.
			if is_instance_valid(tool) and tool!=candidate.equipped_tool and ToolAccess.depot_tool(candidate,tool):
				if not _prospective_depot_tool_ready(candidate, tool, capability): continue
				admitted_tool = tool
			lead_index=i
			break
		if lead_index<0:
			blocked[str(job.id)]="No free Wako has a clear supported route to the depot tool; clear the path or wait for a returning helper"
			return []
		var lead: Node = free[lead_index]
		free.remove_at(lead_index)
		free.push_front(lead)
		required=_required_crew(job,float(lead.carry_capacity))
		if free.size()<required: return []
		if is_instance_valid(admitted_tool):
			job._prospective_tool = {"source": yard.work_tool_source_stamp(admitted_tool), "worker": yard.work_tool_worker_stamp(lead)}
	return free.slice(0, required)


func _unavailable_tool_reason(capability: String) -> String:
	var awaiting := ""
	for tool: Node3D in yard.loose_parts:
		if not is_instance_valid(tool) or tool.is_queued_for_deletion() or not yard.tool_compatible(tool,capability) \
			or not yard.worksite_source(tool) or tool.get_meta(&"stored",false) or not str(tool.get_meta(&"equipped_worker","")).is_empty(): continue
		var id: String = "salvage:" + str(tool.part_id)
		var recovery: Dictionary = active_jobs.get(id,{})
		if not recovery.is_empty() and recovery.job.kind == "salvage" and recovery.job.part == tool:
			return "Recovering %s to storage for %s work" % [tool.definition.title,capability]
		if awaiting.is_empty():
			awaiting = "%s awaits physical recovery to storage for %s work" % [tool.definition.title,capability]
			if float(_retry_after.get(id,0.0)) > _clock and not str(_retry_reasons.get(id,"")).is_empty():
				awaiting += ": " + str(_retry_reasons[id])
	return awaiting if not awaiting.is_empty() else "Compatible %s tools busy; waiting for a helper" % capability

func _prospective_depot_tool_ready(worker: RigidBody3D, tool: Node3D, capability: String) -> bool:
	if not worker.on_ground: return false
	var key: int=worker.get_instance_id()
	# Throttle repeated searches, including failures, at the ordinary route
	# cadence. Never cache a positive proof across movement/support updates;
	# a true result belongs only to this fresh synchronous admission query.
	if float(_depot_tool_admission_until.get(key,0.0))>_clock: return false
	_depot_tool_admission_until[key]=_clock+.6
	# Advance only when this interval permits a fresh original probe.
	var cursors: Dictionary = _depot_tool_admission_cursor.get(key, {})
	var source: Dictionary = yard.work_tool_source_stamp(tool)
	cursors[capability] = source
	_depot_tool_admission_cursor[key] = cursors
	# Prove the real first leg once. A helper stranded above the floor on a
	# loose wheel must not lease stock and spend eighty seconds failing here.
	var gate: Vector3=_storage_approach(tool,true)
	var route: Array[Vector3]=_supported_work_path(worker,yard.storage,worker._ground_point,gate,[gate],true)
	if route.is_empty():
		var planned: Array=_plan_route(worker._ground_point,gate,false,yard.storage,gate.y)
		route=_supported_work_path(worker,yard.storage,worker._ground_point,gate,planned,true)
	if route.is_empty(): return false
	# The endpoint still requires the original finite leg, capsule and opposite
	# sole. Reuse the proven gate; no coarse graph search per stance candidate.
	var stance: Dictionary=ToolAccess.fetch_stance(worker,tool,_prospective_depot_tool_stance_reachable.bind(worker,gate))
	if stance.is_empty() or not yard.work_tool_source_matches(tool, source): return false
	cursors.erase(capability)
	if cursors.is_empty(): _depot_tool_admission_cursor.erase(key)
	return true

func _prospective_depot_tool_stance_reachable(point: Vector3, _support: Object, worker: RigidBody3D, gate: Vector3) -> bool:
	return not _supported_work_path(worker,yard.storage,gate,point,[point],true).is_empty()

func _required_crew(job: Dictionary, capacity: float) -> int:
	var required := 2 if job.get("heavy", false) else 1
	# A supported repair does not ask workers to lift the machine or its secured cargo.
	if job.kind in ["build", "replace", "salvage"]:
		var tool_load := 5.0 if not yard.work_tool_capability(str(job.kind)).is_empty() else 0.0
		for w: Node in workers:
			if not CrewTravel.eligible(yard,w) or not FieldWorksite.eligible(yard,w): continue
			if is_instance_valid(w.equipped_tool): tool_load = maxf(tool_load, float(w.equipped_tool.mass))
		required = maxi(required, ceili(float(job.part.mass) / maxf(capacity - tool_load, 1.0)))
	return required

func _nodes_valid(job: Dictionary) -> bool:
	if job.get("kind", "") == "prepare" and (not is_instance_valid(job.get("placement")) or job.placement.is_queued_for_deletion()): return false
	return is_instance_valid(job.get("part")) and not job.part.is_queued_for_deletion() and is_instance_valid(job.get("target")) and not job.target.is_queued_for_deletion()

func _tick_job(entry: Dictionary, delta: float) -> void:
	var job: Dictionary = entry.job
	if not _nodes_valid(job):
		_cancel(entry, "Component removed; checking a new job")
		return
	_publish_attention(entry)
	var crew: Array = entry.crew
	if crew.any(func(w: Variant) -> bool: return not is_instance_valid(w) or w.paused):
		_cancel(entry, "Crew interrupted; load set down")
		return
	if crew.any(func(w:Node)->bool:return CrewTravel.assigned(yard,w)):
		_cancel(entry,"Crew route owns these original helpers; reserved load set down safely")
		for member: Node in crew: member.stop_navigation()
		return
	if yard.work_paused:
		_cancel(entry, "Work paused; load set down")
		return
	var capability: String = yard.work_tool_capability(str(job.kind))
	if not capability.is_empty():
		var tool: Node3D = job.get("tool")
		if not is_instance_valid(tool) or tool.is_queued_for_deletion():
			_cancel(entry, "Work tool removed; fetching a compatible replacement")
			return
		if not yard.tool_compatible(tool, capability):
			_cancel(entry, "Work tool failed; fetching a compatible replacement")
			return
		if _job_tool_custody_lost(entry):
			_cancel(entry, "Original work tool released; recover a compatible physical tool before continuing")
			return
	var unloading: String = UnloadingHold.tick(yard,entry,delta)
	if unloading == "held": return
	if unloading == "cancel":
		_cancel(entry,str(entry.get("unloading_hold_reason","Worksite changed while unloading; reserved load set down safely")))
		for member: Node in crew: member.stop_navigation()
		return
	if unloading == "resume":
		for member: Node in crew:
			_routes.erase(member.get_instance_id())
			member.needs = ""
	var service_reason: String = yard.job_service_reason(job)
	if not service_reason.is_empty():
		entry.retry_delay = 5.0
		_cancel(entry, service_reason)
		if FieldWorksite.active(yard):
			for member: Node in crew: member.stop_navigation()
		return
	if crew.any(func(w: Node) -> bool: return not FieldWorksite.eligible(yard,w)):
		_cancel(entry,"Field crew left its assigned worksite; load set down")
		for member: Node in crew: member.stop_navigation()
		return
	var guarded_operation: bool = job.kind == "operate" and job.target.kind == "gun" and crew.all(func(w: Node) -> bool: return w.supported_by(job.target.assembly) and w.can_reach_target(job.target))
	var dangerous: bool = yard.unsafe_at(job.target.global_position) and not guarded_operation
	for w: Node in crew:
		if w.fear_time > 0.0 or (yard.unsafe_at(w.global_position) and not guarded_operation): dangerous = true
	if dangerous:
		_cancel(entry, "Unsafe worksite; taking cover")
		return
	if job.target is RigidBody3D and job.target.linear_velocity.length() > 1.8 and job.kind in ["build", "replace", "repair", "unbend", "dismantle", "maintenance"]:
		_cancel(entry, "Machine moving too fast; waiting for safe maintenance")
		return
	entry.elapsed += delta
	if entry.get("light_started", false) and crew[0].pickup.state == "failed":
		# One failed toss: the same part is retried through the head-first flip.
		job.part.set_meta(&"toss_failed", true)
		entry.retry_delay = 4.0
		_cancel(entry, crew[0].pickup.reason)
		return
	if float(entry.elapsed) - float(entry.get("access_started_at", entry.get("transport_started_at", 0.0))) > 80.0:
		_cancel(entry, "Cannot reach connector; clear a safe access path")
		return
	if _hold_supported_tool_return(entry): return
	if job.kind == "prepare" and entry.phase in ["approach", "inspect", "work"]:
		BeamPreparation.tick(self, entry, delta, Access)
		return
	match String(entry.phase):
		"egress":
			_tick_egress(entry)
		"ground_service_approach":
			_tick_ground_service_approach(entry)
		"boarding_approach", "boarding":
			var all_ready := true
			var boarding_target: Node3D = entry.get("boarding_target", job.target)
			for w: Node in entry.get("boarding_crew", crew):
				var path: Dictionary = entry.access[w.worker_id]
				var ramp: RigidBody3D = path.ramp
				if not is_instance_valid(ramp) or not ramp.installed or ramp.linear_velocity.length() > .25 or ramp.health < 20:
					_cancel(entry, "Access ramp moved or failed; wait for secure boarding")
					return
				var points: Array = path.points
				if entry.phase == "boarding_approach":
					var approach: Vector3 = points[0] - (points[1] - points[0]).slide(Vector3.UP).normalized() * .55
					approach.y = points[0].y
					all_ready = _navigate(w, approach, .3) and w.on_ground and all_ready
				else:
					w.access_support = ramp
					var step: int = path.step
					var tagged_final: bool = step==points.size()-1 and Access.construction_work_point(job,boarding_target) is Vector3
					w.navigate_to(points[step])
					if w.at_target(.10 if tagged_final else .22) and w.on_ground:
						if step < points.size() - 1: path.step = step + 1
						else: w.stop_navigation()
					var reachable: bool = entry.has("boarding_resume") or w.can_reach_work()
					# Advancing the path index does not reach its new point. Test the
					# old step that actually supplied this native navigation goal;
					# otherwise arrival at the penultimate point starts work early.
					var ready: bool = step == points.size() - 1 and w.target_position==points[-1] \
						and w.at_target(.10 if tagged_final else .25) and w.on_ground and w.supported_by(boarding_target.assembly) and reachable
					if ready: w.stop_navigation()
					all_ready = ready and all_ready
				w.status_text = "Boarding the secured work ramp"
				if w.navigation_blocked():
					_cancel(entry, "Ramp path blocked; clear the access surface")
					return
			if all_ready:
				if entry.phase == "boarding_approach": entry.phase = "boarding"
				elif entry.has("boarding_resume"):
					entry.phase = entry.boarding_resume
					entry.erase("boarding_resume")
				else:
					# Reach admission predicts facing the work face. Finish the
					# ramp walk with the same target heading as an ordinary approach;
					# the helper's existing native yaw blend performs the turn.
					for w: Node in crew:
						if job.kind=="operate": w.face_point(w.global_position-boarding_target.global_basis.z)
						elif job.kind=="unbend" and is_instance_valid(w.work_target): w.face_point(w.work_target.global_position)
						else: w.face_point(_construction_heading(job,boarding_target))
					entry.phase = "staging" if entry.get("pickup", false) and job.kind in ["build", "replace"] and not entry.get("staged", false) else "inspect"
					if entry.phase == "staging": _begin_staging(entry)
					else:
						for w: Node in crew: w.begin_action("inspect")
		"tool_route", "tool_fetch":
			var lead: Node = crew[0]
			var tool: Node3D = job.get("tool")
			if not is_instance_valid(tool) or not tool.get_meta(&"stored", false):
				_cancel(entry, "Reserved tool unavailable; checking the rack")
				return
			var rack_reason: String = ToolAccess.motion_reason(tool)
			if not rack_reason.is_empty():
				entry.retry_delay = 5.0
				_cancel(entry, rack_reason)
				return
			var point := _storage_approach(tool, entry.phase == "tool_route")
			var tool_machine: Node3D
			var depot_tool: bool=ToolAccess.depot_tool(lead,tool) and entry.phase=="tool_fetch"
			# The outside gate also uses actual depot support. A worker between
			# padded tool envelopes must not bounce between artificial escapes.
			if ToolAccess.depot_tool(lead,tool): tool_machine=yard.storage
			if tool.get_meta(&"stored_tool_rack", false) or depot_tool:
				var stance := _tool_fetch_stance(entry, lead, tool)
				if stance.is_empty():
					entry.retry_delay = 20.0
					_cancel(entry, "Depot tool lacks clear supported foot access; clear its handle and opposite footing" if depot_tool else "Clipped tool lacks supported foot access; clear its rear platform")
					return
				point = stance.point
				var bay := tool.get_parent() as RigidBody3D
				if depot_tool: tool_machine=yard.storage
				elif point.y - lead._ground_point.y > .42 and not lead.supported_by(bay.assembly):
					if _begin_access(entry, bay, "tool_fetch"): return
					entry.retry_delay = 20.0
					_cancel(entry, str(entry.get("access_reason", "Provide a secured ramp to the clipped tool")))
					return
				if not depot_tool and lead.supported_by(bay.assembly): tool_machine = bay.assembly
			if entry.phase == "tool_fetch" and not depot_tool and tool.get_parent().get("kind") != "container":
				point.x = tool.global_position.x
				point.z = tool.global_position.z + .45
			lead.status_text = "Fetching " + str(tool.definition.title)
			_clear_tool_service_partners(entry)
			var arrival := .05 if tool.get_meta(&"stored_tool_rack", false) or depot_tool else .15 if entry.phase == "tool_fetch" else .55
			# An exterior route may clamp a blocked point; that endpoint is not
			# admission to fit the original stock at its actual supported stance.
			var exact_arrival: bool=entry.phase!="tool_fetch" or (lead.global_position-point).slide(Vector3.UP).length()<arrival
			var admitted: Dictionary=entry.get("tool_fit_stance",{})
			var observed_stance: Dictionary=entry.get("tool_stance",{})
			# A genuinely reached depot stance owns the stopped turn while its
			# same revalidated point/support and original .05m arrival remain.
			# Coarse envelope replanning must not restart walking during planting.
			var settling: bool=depot_tool and exact_arrival and not admitted.is_empty() \
				and admitted.point==point and admitted.support==observed_stance.get("support") \
				and is_instance_valid(admitted.support) and lead.on_ground
			var routed_arrival: bool=settling
			if settling: lead.stop_navigation()
			else:
				entry.erase("tool_fit_stance")
				routed_arrival=_navigate(lead,point,arrival,false,tool_machine)
			if routed_arrival and exact_arrival and lead.on_ground and lead.action.is_empty():
				if entry.phase == "tool_route": entry.phase = "tool_fetch"
				else:
					if depot_tool: entry.tool_fit_stance=observed_stance.duplicate()
					# Finish the native walk and turn before lifting one foot.
					# An extended walking heel can otherwise cross a shelf edge
					# while the fitting clip blends into its supported stance.
					lead.stop_navigation()
					lead.face_point(ToolAccess.pickup_point(tool))
					var planted: bool = lead._pose.evaluated_valid and lead._pose.evaluated_grounded[0] and lead._pose.evaluated_grounded[1]
					var settled: bool = planted and lead.gait_speed < .08 and absf(lead.turn_rate) < .15 and lead._animation.current_animation == "wk_idle" and lead._animation.current_animation_position >= .24
					if not settled:
						lead.status_text = "Planting feet to fit " + str(tool.definition.title)
						entry.tool_stance_wait = float(entry.get("tool_stance_wait",0.0))+delta
						if float(entry.tool_stance_wait) > 8.0: _cancel(entry,"Tool footing did not settle; clear the rack or provide supported access")
						return
					if depot_tool and not _tool_service_peers_clear(entry):
						# Reserving parking intent does not clear a moving native
						# peer. Wait for its actual body before lifting this foot.
						lead.status_text="Waiting for Wako to clear the full tool passage"
						entry.tool_stance_wait=float(entry.get("tool_stance_wait",0.0))+delta
						if float(entry.tool_stance_wait)>8.0: _cancel(entry,"Tool passage did not clear; give the fitting crew supported room")
						return
					entry.phase = "tool_change"
					if tool.get_meta(&"stored_tool_rack", false):
						entry.tool_rack = weakref(tool.get_parent())
						entry.tool_rack_point = ToolAccess.pickup_point(tool)
						entry.tool_rack_basis = tool.global_basis.orthonormalized()
					lead.work_target = tool
					lead.begin_action("tool_change")
		"tool_change":
			_clear_tool_service_partners(entry)
			var rack_reason: String = ToolAccess.motion_reason(job.tool) if not entry.get("tool_ready", false) else ""
			var rack: Object = entry.get("tool_rack", weakref(null)).get_ref()
			if rack is RigidBody3D: rack_reason = ToolAccess.rack_motion_reason(rack, entry.tool_rack_point)
			if rack is RigidBody3D and not entry.get("tool_ready", false):
				var rotated: float = entry.tool_rack_basis.get_rotation_quaternion().angle_to(job.tool.global_basis.orthonormalized().get_rotation_quaternion())
				if ToolAccess.pickup_point(job.tool).distance_to(entry.tool_rack_point) > .015 or rotated > .02:
					rack_reason = "Tool rack shifted; stop and support it before fitting"
			if not rack_reason.is_empty():
				_cancel(entry, rack_reason)
				return
			crew[0].status_text = "Fitting " + str(job.tool.definition.title)
		"fetch_outside", "fetch_route", "carry_exit", "carry_outside":
			var ready := true
			var routed: Vector3 = entry.outside_position if entry.phase in ["fetch_outside", "carry_outside"] else entry.exit_position
			for i in crew.size():
				var w: Node = crew[i]
				var offset: Vector3 = entry.get("storage_axis",Vector3.RIGHT)*(i*2.0-1.0)*.49 if crew.size()>1 else Vector3.ZERO
				var at_route := _navigate(w, routed + offset, .7, entry.get("open_depot",false) and entry.phase == "carry_exit")
				ready = ready and at_route and w.action.is_empty()
				w.status_text = "Reaching container entrance" if entry.phase == "fetch_route" else "Clearing the cargo bay"
			if ready: entry.phase = {"fetch_outside": "fetch_route", "fetch_route": "fetch", "carry_exit": "carry_outside", "carry_outside": "carry"}[entry.phase]
		"fetch", "approach", "carry":
			var fetching: bool = entry.phase == "fetch"
			if fetching and entry.get("head_launch_settling",false):
				_tick_head_launch(entry,delta)
				return
			var target: Node3D = job.part if fetching else job.target
			var point := _work_position(job, target, fetching)
			var local_machine: Node3D
			var source_stance: Dictionary={}
			if fetching and job.get("head_first_pickup",false) and crew.size()==1 and (StorageAccess.depot_head_source(crew[0],target) or StorageAccess.loose_head_source(crew[0],target)):
				source_stance=_head_source_stance(entry,crew[0],target)
				if source_stance.is_empty():
					entry.retry_delay=20.0
					_cancel(entry,"Original stock lacks clear supported launch access; clear its nearby floor and head space")
					return
				point=source_stance.point
				local_machine=yard.storage if StorageAccess.depot_head_source(crew[0],target) else yard
			if not fetching and job.kind in ["build","join","replace","repair","unbend","dismantle","maintenance"]:
				var supported_service: bool = job.kind in ["repair","unbend","dismantle","maintenance"] and crew[0].supported_by(target.assembly)
				var local := _local_work_stance(entry,point,supported_service)
				if not local.is_empty():
					point = local.point
					local_machine = target.assembly
				elif supported_service:
					if _begin_egress(entry): return
					entry.retry_delay = 20.0
					_cancel(entry,"No supported service stance; clear the work face or extend its platform")
					return
				elif _prefer_supported_access(entry, point):
					return
			if not fetching and job.kind == "operate":
				var pedal_access := _station_work_position(crew[0], target)
				if pedal_access.is_empty():
					entry.retry_delay = 20.0
					_cancel(entry, "No supported pedal access; provide a secured ramp/work platform")
					return
				point = pedal_access.point
			var target_assembly := target.get("assembly") as Node3D
			if not fetching and is_instance_valid(target_assembly) and point.y - crew[0]._ground_point.y > .42 and not crew[0].supported_by(target_assembly):
				if _begin_access(entry): return
				if job.kind == "operate":
					entry.retry_delay = 20.0
					_cancel(entry, str(entry.get("access_reason", "Connector out of reach; provide a secured ramp/work platform")))
					return
			var ready := true
			var crew_axis := Vector3.RIGHT
			if fetching:
				crew_axis=entry.get("storage_axis",Vector3.RIGHT)
				if job.get("head_first_pickup",false) and crew.size()>1:
					var stock: AABB=job.part.global_transform*Catalogue.bounds_of(job.part.definition)
					crew_axis=Vector3.RIGHT if stock.size.x>=stock.size.z else Vector3.BACK
			var frame := _assembly_frame(target)
			if not fetching and frame:
				var radial := (point - frame.global_position).slide(Vector3.UP)
				var envelope := _assembly_bounds(target.assembly)
				crew_axis = Vector3.FORWARD if absf(radial.x) / maxf(envelope.size.x, .1) > absf(radial.z) / maxf(envelope.size.y, .1) else Vector3.RIGHT
			if local_machine and not fetching: crew_axis = entry.local_axis
			var head_work: bool=entry.phase=="approach" and entry.get("staged",false) and job.get("head_first_pickup",false) and crew.size()>1 and not local_machine
			if head_work and not entry.has("head_work_spacing"):
				var spacing: Array[float]=[]
				for member: Node in crew:
					var tool: Node3D=member.equipped_tool
					if member==crew[0] and not is_instance_valid(tool): tool=job.get("tool")
					var radius:=.07
					if is_instance_valid(tool):
						var bounds: AABB=PhysicalDepot.bounds(tool)
						var toe: Vector3=Vector3(0,-.035-float(tool.definition.size.y)*.45,0)
						for corner in 8: radius=maxf(radius,bounds.get_endpoint(corner).distance_to(toe))
					spacing.append(maxf(.49,member._leg_span(member.tool_foot_side())-.012+radius))
				entry.head_work_spacing=spacing
			for i in crew.size():
				var w: Node = crew[i]
				if fetching and _hold_owned_tool_service_peer(w):
					ready=false
					continue
				var offset := crew_axis * (i * 2.0 - 1.0) * (float(entry.head_work_spacing[i]) if head_work else .49) if crew.size() > 1 else Vector3.ZERO
				if fetching and source_stance.is_empty() and crew.size() == 1 and target.get_meta(&"stored", false) and not job.get("light_pickup",false):
					offset.x = (absi(w.worker_id.hash()) % 3 - 1) * .65
				var arrival := .08 if not source_stance.is_empty() or (fetching and job.get("light_pickup",false)) else .7 if job.kind == "salvage" else .12 if is_instance_valid(job.get("tool")) else .3
				var at_local_stance: bool = not local_machine or (w.global_position-point-offset).slide(Vector3.UP).length()<=arrival
				var onboard: bool = not fetching and job.kind in ["build", "join", "replace", "repair", "unbend", "dismantle", "maintenance", "operate"] and w.supported_by(job.target.assembly) and w.can_reach_work() and at_local_stance
				var at_work := true if onboard else _navigate(w, point + offset, arrival, fetching and entry.get("open_depot",false),local_machine)
				if not fetching and job.kind == "operate" and w.supported_by(job.target.assembly):
					var standing := _station_work_position(w, target)
					if not standing.is_empty():
						w.navigate_to(standing.point)
						at_work = w.at_target(.05) and w._model.global_basis.z.dot(target.global_basis.z) > .995
						onboard = at_work
				if onboard: w.stop_navigation()
				if not fetching and job.kind == "operate": w.face_point(w.global_position - target.global_basis.z)
				elif not fetching and job.kind == "unbend" and is_instance_valid(w.work_target): w.face_point(w.work_target.global_position)
				else: w.face_point(target.global_position if fetching else _construction_heading(job,target))
				ready = ready and at_work and w.on_ground and w.action.is_empty()
				if w.navigation_blocked():
					_cancel(entry, "Blocked path; clear space around the connector")
					return
				w.status_text = "Carrying " + _part_title(job) if entry.phase == "carry" else "Fetching " + _part_title(job) if fetching else "Reaching structural fastener" if job.kind == "join" else "Reaching maintenance point"
			if crew.size() > 1 and entry.phase == "carry":
				var a: Node3D = crew[0]
				var b: Node3D = crew[1]
				if a.global_position.distance_to(b.global_position) > 2.6:
					# Both stop until a displaced carrier comes back underneath the load.
					a.navigate_to((a.global_position + b.global_position) * .5 - Vector3.UP * a.ride_height)
					b.navigate_to(a.target_position)
					ready = false
			if ready:
				if fetching and job.get("head_first_pickup",false):
					# Arrival is a routing radius, not a supported launch event.
					# Stop through the native controller and settle both actual soles
					# before the flight controller records its unchanged home pose.
					entry.head_launch_settling=true
					entry.launch_wait=0.0
					_tick_head_launch(entry,delta)
					return
				if fetching and job.get("light_pickup",false):
					if not yard.perform_work(job,float(entry.progress),"present_pickup",crew):
						_cancel(entry,"Light part unavailable at the pickup position")
						return
					crew[0].work_target = job.part
					crew[0].pickup.begin(job.part)
					entry.light_started = true
				if not fetching and job.kind in ["build", "join", "replace", "repair", "unbend", "dismantle", "maintenance", "operate"] and not crew[0].can_reach_work():
					if _begin_access(entry): return
					_cancel(entry, str(entry.get("access_reason", "Connector out of reach; provide a work platform/access")))
					return
				if not fetching and job.kind=="salvage":
					_begin_storage_staging(entry)
					return
				entry.phase = "pickup" if fetching else "inspect" if entry.phase == "approach" else "staging" if job.kind in ["build", "replace"] else "work"
				if not fetching and job.kind == "operate":
					entry.phase = "work"
					entry.last_clip_progress = entry.progress
					entry.contact_misses = 0
					entry.control_support = weakref(crew[0]._ground_body)
					entry.control_local = crew[0]._ground_body.to_local(crew[0].global_position - Vector3.UP * crew[0].ride_height)
				if entry.phase == "staging": _begin_staging(entry)
				else:
					for w: Node in crew:
						w.begin_action("pickup" if fetching else "inspect" if entry.phase == "inspect" else "brace" if w != crew[0] else _work_action(job))
		"work":
			if job.kind == "operate":
				var support: Object = entry.get("control_support", weakref(null)).get_ref()
				if support is Node3D:
					crew[0].navigate_to(support.to_global(entry.control_local))
				crew[0].face_point(crew[0].global_position - job.target.global_basis.z)
			if not crew[0].tool_pose_blocked.is_empty():
				entry.retry_delay = 20.0
				_cancel(entry, crew[0].tool_pose_blocked)
				return
			if crew.any(func(w: Node) -> bool: return not w.on_ground):
				_cancel(entry, "Lost planted footing; work paused safely")
				return
			if job.kind in ["build", "join", "replace", "repair", "unbend", "dismantle", "maintenance", "operate"] and not crew[0].can_reach_work():
				entry.retry_delay = 20.0
				_cancel(entry, "Connector out of reach; provide a work platform/access")
				return
			var speed := 1.0 / maxf(float(job.get("duration", 3.0)), 0.5)
			if float(entry.progress) < 1.0 and (not yard.work_tool_capability(str(job.kind)).is_empty() or job.kind == "operate"):
				if not crew[0].foot_contact_ready(): return
				speed /= .35 # Progress is accumulated only during the planted, real toe/tool contact window.
			entry.progress = minf(float(entry.progress) + delta * speed, 1.0)
			for w: Node in crew:
				w.progress = float(entry.progress)
				w.status_text = _work_label(job)
			if not yard.perform_work(job, float(entry.progress), "tick", crew):
				_cancel(entry, "Connection changed; checking the plan")
				return
			if float(entry.progress) >= 1.0 and crew[0].action.is_empty():
				if job.kind == "join":
					crew[0].begin_action("assemble") # Commit at the next actual socket tool contact.
					return
				if job.kind == "operate":
					crew[0].begin_action("operate") # Commit at its next real pedal-contact event.
					return
				entry.phase = "placing"
				for w: Node in crew: w.begin_action("place")
		"head_pickup":
			if crew.any(func(member: Node) -> bool: return not member.head_leap.reason.is_empty()):
				entry.retry_delay=20.0
				_cancel(entry,crew.filter(func(member: Node) -> bool: return not member.head_leap.reason.is_empty())[0].head_leap.reason)
				return
			if not entry.pickup and crew.all(func(member: Node) -> bool: return member.head_leap.contact_ready()):
				if not yard.perform_work(job,float(entry.progress),"pickup",crew):
					var reason: String=crew[0].head_leap.reason
					_cancel(entry,reason if not reason.is_empty() else "Current stock/head contact changed before attachment")
					return
				entry.pickup=true
				if job.kind in ["build","replace"]:
					_retry_reasons.erase(str(job.id))
					_head_return_reasons.erase(str(job.id))
				if crew.size()>1:
					crew[0].carry_partner=crew[1]
					for member: Node in crew:
						if member!=crew[0]: member.brace_leader=crew[0]; member.brace_load=job.part
			if entry.pickup and crew.all(func(member: Node) -> bool: return member.head_leap.state=="done"):
				_pickup_finished(entry)
				return
			for member: Node in crew: member.status_text=("Returning with " if entry.pickup else "Jumping head-first to ")+_part_title(job)
		"pickup_flight":
			crew[0].status_text = "Catching " + _part_title(job)
			if crew[0].pickup.state == "caught": _pickup_finished(entry)
		"storage_staging":
			if entry.get("arrival_pending",false) and _try_storage_admit(entry): return
			if crew.any(func(w:Node)->bool:return not w.on_ground):
				_cancel(entry,"Storage handover lost its real planted support")
				return
			for w: Node in crew: w.status_text="Positioning "+_part_title(job)+" on its reserved storage support"
		"pickup", "inspect", "placing", "staging":
			if entry.phase=="staging" and entry.get("arrival_pending",false): _try_stage_admit(entry)
			if entry.phase == "pickup":
				var blocker := _head_pickup_blocker(entry)
				if not blocker.is_empty():
					entry.retry_delay = 20.0
					_cancel(entry, blocker)
					return
			if entry.phase == "inspect" and not crew[0].tool_pose_blocked.is_empty() and not (crew[0].back_tool and crew[0].back_tool.supported_foot_return_pending()):
				entry.retry_delay = 20.0
				_cancel(entry, crew[0].tool_pose_blocked)
				return
			# Contact/finish signals advance the task at the animation event.
			var phase_label: String = {"pickup": "Lifting ", "inspect": "Inspecting ", "staging": "Positioning ", "placing": "Securing "}[entry.phase]
			for w: Node in crew: w.status_text = phase_label + _part_title(job)

func _begin_access(entry: Dictionary, access_target: Node3D = null, resume_phase := "") -> bool:
	var paths := {}
	var boarding_crew: Array = [entry.crew[0]] if access_target else entry.crew
	for w: Node in boarding_crew:
		var target: Node3D = access_target if access_target else w.work_target if entry.job.kind == "unbend" and is_instance_valid(w.work_target) else entry.job.target
		var path: Dictionary = Access.route(w, target, boarding_crew.size())
		if not path.has("points"):
			entry.access_reason = str(path.get("reason", "Connector out of reach; provide a secured ramp/work platform"))
			return false
		if _egress_ramp_claimed(entry,path.ramp):
			entry.access_reason="Waiting for the helper leaving this narrow ramp"
			return false
		if _ramp_occupied(entry,path.ramp):
			entry.access_reason="Waiting for the helper standing on this narrow ramp"
			return false
		path.step = 0
		paths[w.worker_id] = path
	entry.access = paths
	entry.boarding_crew = boarding_crew
	entry.boarding_target = access_target if access_target else entry.job.target
	if not resume_phase.is_empty(): entry.boarding_resume = resume_phase
	entry.phase = "boarding_approach"
	return true

func _egress_ramp_claimed(entry: Dictionary,ramp: RigidBody3D) -> bool:
	for other: Dictionary in active_jobs.values():
		if other==entry: continue
		var transit: Dictionary = other.get("egress",{})
		if transit.get("ramp")==ramp and transit.get("stage") in ["descent","landing"]: return true
	return false

func _ramp_occupied(entry: Dictionary,ramp: RigidBody3D) -> bool:
	for peer: Node in workers:
		if is_instance_valid(peer) and not entry.crew.has(peer) and (peer.access_support==ramp or peer._ground_body==ramp): return true
	return false

func _begin_egress(entry: Dictionary) -> bool:
	# The proven small ramp carries one helper at a time. Keep cooperative work
	# conservative until its distinct ground formation has a native access proof.
	if entry.crew.size()!=1 or entry.crew[0].carrying: return false
	var worker: RigidBody3D = entry.crew[0]
	var target: RigidBody3D = worker.work_target
	if not is_instance_valid(target) or not is_instance_valid(target.assembly): return false
	var path := Egress.plan(worker,target.assembly)
	if not path.has("points"): return false
	if _egress_ramp_claimed(entry,path.ramp): return false
	if _ramp_occupied(entry,path.ramp): return false
	for other: Dictionary in active_jobs.values():
		if other==entry or other.get("phase") not in ["boarding_approach","boarding"]: continue
		for access: Dictionary in other.get("access",{}).values():
			if access.get("ramp")==path.ramp: return false
	entry.egress = {"path":path,"step":0,"stage":"descent","target":target,"machine":target.assembly,"ramp":path.ramp}
	entry.phase="egress"
	entry.erase("local_point")
	entry.local_until=0.0
	_routes.erase(worker.get_instance_id())
	worker.stop_navigation()
	return true

func _tick_egress(entry: Dictionary) -> void:
	var worker: RigidBody3D = entry.crew[0]
	var access: Dictionary = entry.egress
	var path: Dictionary = access.path
	var target: RigidBody3D = access.target
	var machine: Node3D = access.machine
	var points: Array = path.points
	var step: int = access.step
	if not is_instance_valid(target) or not is_instance_valid(machine) or target.assembly!=machine:
		_cancel(entry,"Service target changed while leaving its platform")
		return
	if access.stage=="descent":
		if Egress.on_static_ground(worker,machine):
			# Displacement onto ground must not resume an old point on the ramp.
			# Prove a new ground continuation and retire the ramp path instead.
			var landing := Egress.static_ground_path(worker,machine,[worker._ground_point,path.ground])
			if landing.is_empty():
				_cancel(entry,"No clear ground continuation beyond the work ramp")
				return
			access.stage="landing"
			access.path={"points":landing}
			access.step=0
			points=landing
			step=0
		else:
			var reason := Egress.motion_reason(path)
			if not reason.is_empty():
				entry.retry_delay=5.0
				_cancel(entry,reason)
				return
			worker.access_support=path.ramp
	if access.stage!="descent":
		worker.access_support=null
		var root: RigidBody3D = machine.root_part()
		if not root or root.linear_velocity.length()>.25 or root.angular_velocity.length()>.1 or not target.service_safety_reason().is_empty() or Access.work_surface_velocity(worker,target).length()>.25:
			_cancel(entry,"Stop and support the work face before ground service")
			return
		if _clock>=float(access.get("ground_until",0.0)):
			var remaining: Array[Vector3] = [worker._ground_point]
			for index in range(step,points.size()): remaining.append(points[index])
			if Egress.static_ground_path(worker,machine,remaining).is_empty():
				_cancel(entry,"Ground service route changed; clear its supported aisle")
				return
			access.ground_until=_clock+.6
	worker.navigate_to(points[step])
	worker.status_text="Leaving the secured work ramp" if access.stage=="descent" else "Reaching ground service position"
	if worker.navigation_blocked():
		_cancel(entry,"Ground service path blocked; clear the ramp and work face")
		return
	var arrival := .22 if access.stage in ["descent","landing"] or step<points.size()-1 else .12
	if not worker.on_ground or not worker.at_target(arrival): return
	if step<points.size()-1:
		access.step=step+1
		return
	worker.stop_navigation()
	worker.access_support=null
	if not Egress.on_static_ground(worker,machine):
		_cancel(entry,"No supported ground landing beyond the work ramp")
		return
	if access.stage in ["descent","landing"]:
		var ground := Egress.ground_service_route(worker,target,entry.job)
		if not ground.has("points"):
			_cancel(entry,"No clear supported ground route to the service face")
			return
		access.stage="ground"
		access.path=ground
		access.step=0
	else:
		access.point=path.point
		entry.phase="ground_service_approach"
		_routes.erase(worker.get_instance_id())

func _tick_ground_service_approach(entry: Dictionary) -> void:
	# Retain the exact ground stance that passed the descent continuation. A
	# generic approach would recompute a different goal and could reboard.
	var worker: RigidBody3D = entry.crew[0]
	var access: Dictionary = entry.egress
	var target: RigidBody3D = access.target
	var machine: Node3D = access.machine
	var point: Vector3 = access.point
	if not is_instance_valid(target) or not is_instance_valid(machine) or target.assembly!=machine or not Egress.on_static_ground(worker,machine):
		_cancel(entry,"Ground service target or footing changed")
		return
	var root: RigidBody3D = machine.root_part()
	if not root or root.linear_velocity.length()>.25 or root.angular_velocity.length()>.1 or not target.service_safety_reason().is_empty() or Access.work_surface_velocity(worker,target).length()>.25 or not Access._reachable(worker,target,point,.12):
		_cancel(entry,"Ground service face moved or left the retained tool's reach")
		return
	if (worker._ground_point-point).slide(Vector3.UP).length()>.12 and Egress.static_ground_path(worker,machine,[worker._ground_point,point]).is_empty():
		_cancel(entry,"Ground service stance lost its clear supported continuation")
		return
	worker.navigate_to(point)
	worker.face_point(target.global_position)
	worker.status_text="Reaching ground service position"
	if worker.navigation_blocked():
		_cancel(entry,"Ground service stance blocked; clear the work face")
		return
	if not worker.at_target(.12) or not worker.action.is_empty(): return
	if not worker.can_reach_work():
		_cancel(entry,"Ground service face is outside the retained tool's reach")
		return
	worker.stop_navigation()
	entry.erase("egress")
	entry.phase="inspect"
	worker.begin_action("inspect")

func _tool_fetch_stance(entry: Dictionary, worker: RigidBody3D, tool: Node3D) -> Dictionary:
	# Native fitting/motion/contact checks still run every tick. Reuse only this
	# stopped rack's bounded stance search during the existing navigation cadence.
	var cached: Dictionary = entry.get("tool_stance", {})
	if entry.get("tool_stance_worker",0)!=worker.get_instance_id() or entry.get("tool_stance_source",0)!=tool.get_instance_id() \
		or entry.get("tool_stance_role",-1)!=worker.tool_foot_side(): cached={}
	if not cached.is_empty() and float(entry.get("tool_stance_until", 0.0)) > _clock:
		var old: Transform3D = entry.tool_stance_transform
		var support: Object = cached.support
		if is_instance_valid(support) and old.origin.distance_to(tool.global_position) < .015 and old.basis.get_rotation_quaternion().angle_to(tool.global_basis.get_rotation_quaternion()) < .01:
			return cached
	var depot_tool: bool=ToolAccess.depot_tool(worker,tool)
	var route_admission: Callable=_depot_tool_stance_reachable.bind(worker,entry) if depot_tool else Callable()
	var preferred: Dictionary={}
	if depot_tool and not cached.is_empty():
		var old: Transform3D=entry.tool_stance_transform
		if old.origin.distance_to(tool.global_position)<.015 and old.basis.get_rotation_quaternion().angle_to(tool.global_basis.get_rotation_quaternion())<.01:
			preferred=cached
	var stance: Dictionary = ToolAccess.fetch_stance(worker,tool,route_admission,preferred)
	if depot_tool and not cached.is_empty() and (stance.is_empty() or stance.point!=cached.point):
		# The bounded search found a different reachable endpoint. Its old
		# route/settling ownership cannot keep driving toward another stance.
		_routes.erase(worker.get_instance_id())
		entry.erase("tool_fit_stance")
	entry.tool_stance = stance
	entry.tool_stance_until = _clock + .25
	entry.tool_stance_transform = tool.global_transform
	entry.tool_stance_worker=worker.get_instance_id()
	entry.tool_stance_source=tool.get_instance_id()
	entry.tool_stance_role=worker.tool_foot_side()
	return stance

func _depot_tool_stance_reachable(point: Vector3, support: Object, worker: RigidBody3D, entry: Dictionary) -> bool:
	var admitted: Dictionary=entry.get("tool_fit_stance",{})
	# ToolAccess has just rechecked this exact endpoint's native capsule,
	# finite leg and opposite sole. An already reached same stance needs no
	# new coarse escape path while its stopped turn is being planted.
	var owns_stance: bool=not admitted.is_empty() and is_instance_valid(admitted.support) and worker.on_ground \
		and (worker.global_position-admitted.point).slide(Vector3.UP).length()<.05
	if owns_stance: return admitted.point==point and admitted.support==support
	var from: Vector3=worker._ground_point
	var planned: Array=_plan_route(from,point,false,yard.storage,point.y)
	return not _supported_work_path(worker,yard.storage,from,point,planned).is_empty()

func _prefer_supported_access(entry: Dictionary, ground: Vector3) -> bool:
	var lead: RigidBody3D = entry.crew[0]
	var target: RigidBody3D = lead.work_target
	if not is_instance_valid(target) or not is_instance_valid(target.assembly) or lead.supported_by(target.assembly): return false
	# A theoretically maximum-reach ground pose is a poor tool stance. Prefer
	# an already-proven real ramp rather than repeatedly failing inspection at
	# that boundary. This uses the existing conservative arrival margin.
	if Access._reachable(lead, target, ground, .12): return false
	if not target.service_safety_reason().is_empty() or Access.work_surface_velocity(lead, target).length() > .25: return false
	var frame: RigidBody3D = target.assembly.root_part()
	if frame and (frame.linear_velocity.length() > .25 or frame.angular_velocity.length() > .1): return false
	return _begin_access(entry)

func _local_work_stance(entry: Dictionary, proposed: Vector3, require_supported_service := false) -> Dictionary:
	var worker: RigidBody3D = entry.crew[0]
	# Unbending's job target is the root load; its actual foot work is on connection.b.
	var target: Node3D = worker.work_target
	if not is_instance_valid(target) or not is_instance_valid(target.assembly): return {}
	# Tool navigation legitimately stops within .12 m. A merely reachable centre
	# can be out of finite reach at that arrival offset, so search a supported local
	# stance in that borderline band. Candidate/final contact limits stay exact.
	var construction_point: Variant=Access.construction_work_point(entry.job,target)
	var precise_mount: bool = entry.job.kind == "join" or entry.job.get("descriptor", {}).get("contact_mount", false) or construction_point is Vector3
	var wider_ground_search: bool = not precise_mount and entry.job.kind in ["build","replace"]
	if not precise_mount and not require_supported_service and Access._reachable(worker,target,proposed,.12) and not entry.has("local_point"): return {}
	if float(entry.get("local_until",0.0))>_clock: return {"point":entry.local_point} if entry.has("local_point") else {}
	entry.local_until = _clock+.6 # Bounded search at the existing navigation cadence.
	entry.erase("local_point")
	var machine: Node3D = target.assembly
	var arrival_margin := .12 if precise_mount or wider_ground_search else 0.0
	# Central low components can sit between wide native track housings. A few
	# farther ground candidates leave their padded capsule clear while keeping
	# the same conservative retained-tool reach. Service/egress lists stay fixed.
	var extra_ground_gaps: Array[float] = []
	if wider_ground_search:
		for gap: float in [1.5,1.6,1.7]: extra_ground_gaps.append(gap)
	var candidates: Array[Vector3] = Access.local_stances(worker,target,arrival_margin,extra_ground_gaps)
	if wider_ground_search or construction_point is Vector3:
		# Snapshot the actual bearing hip and walking origin for this phase. A
		# closer viable work face leaves room for the authored counterlean; taking
		# the nearest walking point instead can exhaust reach during the stroke.
		# Explicit construction uses its actual fastening face for the same
		# ranking; its existing finite candidates and arrival margin stay fixed.
		# Repeated route checks retain this order while native pose stays stopped.
		var phase: String = entry.get("phase","approach")
		var ranked_pose: Transform3D = entry.get("local_rank_pose",target.global_transform)
		if entry.get("local_rank_phase","")!=phase or ranked_pose.origin.distance_to(target.global_position)>.015 \
			or ranked_pose.basis.get_rotation_quaternion().angle_to(target.global_basis.get_rotation_quaternion())>.01:
			entry.local_rank_phase=phase
			entry.local_rank_pose=target.global_transform
			entry.local_rank_origin=worker.global_position
			entry.local_rank_hip_offset=worker.evaluated_hip(worker.work_foot_side)-(worker.global_position-Vector3.UP*worker.ride_height)
		var scores := {}
		for candidate: Vector3 in candidates:
			var hip: Vector3 = candidate+entry.local_rank_hip_offset
			var face: Vector3 = construction_point if construction_point is Vector3 else target.to_global(Catalogue.closest_point(target.definition,target.to_local(hip)))
			scores[candidate]=hip.distance_squared_to(face)
		candidates.sort_custom(func(a:Vector3,b:Vector3)->bool:
			if absf(float(scores[a])-float(scores[b]))>.00001: return scores[a]<scores[b]
			return Vector3(entry.local_rank_origin).distance_squared_to(a)<Vector3(entry.local_rank_origin).distance_squared_to(b))
	for candidate: Vector3 in candidates:
		var face: Vector3=construction_point if construction_point is Vector3 else target.global_position
		var axis := (face-candidate).slide(Vector3.UP).cross(Vector3.UP).normalized()
		if axis.length_squared()<.01: axis=Vector3.RIGHT
		# Either side of a real stance may hold the bracer. A concave pocket can
		# have one clear lateral side while the other intersects the machine's arm.
		for shift: float in [.49,-.49] if entry.crew.size()>1 else [0.0]:
			var centre := candidate + axis*shift
			var safe := true
			for i in entry.crew.size():
				var member: RigidBody3D = entry.crew[i]
				var goal: Vector3 = centre + axis*(i*2.0-1.0)*.49 if entry.crew.size()>1 else centre
				if not Access._reachable(member,target,goal,arrival_margin): safe=false; break
				var from: Vector3 = member.global_position-Vector3.UP*member.ride_height
				var route: Array = _plan_route(from,goal,false,machine,goal.y)
				if _supported_work_path(member,machine,from,goal,route).is_empty(): safe=false; break
			if safe:
				entry.local_point = centre
				entry.local_axis = axis
				return {"point":centre}
	return {}

func _construction_heading(job: Dictionary, target: Node3D) -> Vector3:
	if job.get("kind","")=="join" and job.get("target")==target:
		var descriptor: Variant=job.get("descriptor")
		var definition: Variant=target.get("definition")
		var socket: Variant=descriptor.get("socket_b") if descriptor is Dictionary else null
		if socket is String and not socket.is_empty() and definition is Dictionary \
			and not Catalogue.socket(definition,socket).is_empty():
			# Closing work uses the same real fastener as helper.work_point and
			# Access reach prediction, including after the final boarding turn.
			var work_face: Vector3=target.connector_world(socket).origin
			if work_face.is_finite(): return work_face
	var point: Variant=Access.construction_work_point(job,target)
	return point if point is Vector3 else target.global_position

func _head_source_stance(entry: Dictionary,worker: RigidBody3D,source: RigidBody3D) -> Dictionary:
	var cached: Dictionary=entry.get("head_source_stance",{})
	var old: Transform3D=entry.get("head_source_transform",source.global_transform)
	var unchanged: bool=old.origin.distance_to(source.global_position)<.015 and old.basis.get_rotation_quaternion().angle_to(source.global_basis.get_rotation_quaternion())<.01
	if unchanged and not cached.is_empty() and is_instance_valid(cached.support) and float(entry.get("head_source_until",0.0))>_clock: return cached
	var machine: Node3D=yard.storage if StorageAccess.depot_head_source(worker,source) else yard
	var admission: Callable=_ground_head_source_reachable.bind(worker,machine)
	var stance: Dictionary=StorageAccess.head_launch_stance(worker,source,admission,cached if unchanged else {})
	if not cached.is_empty() and (stance.is_empty() or cached.point!=stance.point): _routes.erase(worker.get_instance_id())
	entry.head_source_stance=stance
	entry.head_source_transform=source.global_transform
	entry.head_source_until=_clock+.25
	return stance

func _ground_head_source_reachable(point: Vector3,_support: Object,worker: RigidBody3D,machine: Node3D) -> bool:
	# Endpoint native checks were just performed. A genuinely reached point
	# needs no new coarse escape route while the ordinary launch soles settle.
	if worker.on_ground and (worker._ground_point-point).slide(Vector3.UP).length()<.08: return true
	var from: Vector3=worker._ground_point
	var planned: Array=_plan_route(from,point,machine==yard.storage,machine,point.y)
	return not _supported_work_path(worker,machine,from,point,planned).is_empty()

func _tick_head_launch(entry: Dictionary,delta: float) -> void:
	entry.launch_wait=float(entry.get("launch_wait",0.0))+delta
	entry.tool_stow_wait=float(entry.get("tool_stow_wait",0.0))+delta
	var tool_settling:=false
	var settled:=true
	for member: RigidBody3D in entry.crew:
		member.stop_navigation()
		var back: Variant=member.back_tool if "back_tool" in member else null
		if back and not back.request_stow():
			# The same real tool must finish its finite transfer before this
			# job owns pickup/action. Readiness never implies a planted sole.
			member.status_text="Stowing original tool before head-first "+_part_title(entry.job)
			tool_settling=true
			settled=false
			continue
		if back and back.recovering():
			member.status_text="Recovering actual soles before head-first "+_part_title(entry.job)
			settled=false
			continue
		member.face_point(entry.job.part.global_position)
		member.status_text="Planting feet for head-first "+_part_title(entry.job)
		settled=settled and member.on_ground and member.action.is_empty() and member._pose.evaluated_valid and member._pose.evaluated_grounded.all(func(value:bool)->bool:return value) and member.linear_velocity.length()<.12 and member.angular_velocity.length()<.15 and member.gait_speed<.08 and absf(member.turn_rate)<.15 and member._animation.current_animation=="wk_idle" and member._animation.current_animation_position>=.24
	if tool_settling:
		entry.launch_wait=0.0
		if entry.tool_stow_wait>12.0:
			entry.retry_delay=20.0
			_cancel(entry,"Original tool did not reach safe back custody before the bounded head launch")
		return
	if not settled:
		if entry.launch_wait>8.0:
			entry.retry_delay=20.0
			_cancel(entry,"Head-first launch footing did not settle; clear the real launch soles")
		return
	var blocker: String=entry.crew[0].HeadLeap.begin_group(entry.job.part,entry.crew)
	if not blocker.is_empty():
		entry.retry_delay=20.0
		_cancel(entry,blocker)
		return
	entry.erase("head_launch_settling")
	entry.phase="head_pickup"

func _storage_destination_approach(job: Dictionary) -> Vector3:
	var destination: Dictionary=job.storage_destination
	var bay: Node3D=job.target
	var at: Vector3=bay.to_global(destination.placement.pose.origin)
	if destination.kind=="depot":
		var row: Rect2=PhysicalDepot.rows()[int(destination.placement.saved.row)]
		var bounds: AABB=destination.placement.pose*PhysicalDepot.bounds(job.part)
		var local:=Vector3(clampf(bounds.get_center().x,row.position.x+.95,row.end.x-.95),0,row.end.y+1.0)
		at=bay.to_global(local)
	else:
		at+=bay.global_basis.z*(float(bay.definition.size.z)*.5+1.0) if bay is RigidBody3D else Vector3(0,0,.95)
	var excluded: Array[RID]=[]
	for member: Node in workers: excluded.append(member.get_rid())
	excluded.append(job.part.get_rid())
	var ray:=PhysicsRayQueryParameters3D.create(at+Vector3.UP*1.5,at-Vector3.UP*2.0,1,excluded)
	var support:=yard.get_world_3d().direct_space_state.intersect_ray(ray)
	if not support.is_empty(): at.y=support.position.y
	return at

func _work_position(job: Dictionary, target: Node3D, fetching: bool) -> Vector3:
	if job.kind=="salvage" and not fetching and job.has("storage_destination"): return _storage_destination_approach(job)
	if job.kind == "prepare" and not fetching:
		var face: Variant = BeamPreparation.point(job, target)
		if face is Vector3:
			var proposed: Vector3 = face+target.global_basis.x*1.3
			var ray := PhysicsRayQueryParameters3D.create(proposed+Vector3.UP*1.5, proposed-Vector3.UP*2.0, 1, workers.map(func(w:Node)->RID:return w.get_rid()))
			var hit := yard.get_world_3d().direct_space_state.intersect_ray(ray)
			if not hit.is_empty(): proposed.y = hit.position.y
			return proposed
	if fetching and job.get("light_pickup",false):
		var point := target.global_position + Vector3(0,0,.42)
		var ray := PhysicsRayQueryParameters3D.create(point + Vector3.UP*1.5,point-Vector3.UP*3)
		ray.exclude = workers.map(func(w:Node)->RID:return w.get_rid())
		ray.exclude.append(target.get_rid())
		ray.collision_mask = 1
		var hit := yard.get_world_3d().direct_space_state.intersect_ray(ray)
		if not hit.is_empty(): point.y = hit.position.y
		return point
	if fetching and target.get_meta(&"stored", false): return _storage_approach(target, false)
	var under_frame := false
	var base: Vector3 = job.connection.global_position if job.kind == "unbend" and is_instance_valid(job.get("connection")) else target.global_position
	if not fetching:
		var construction_point: Variant=Access.construction_work_point(job,target)
		if construction_point is Vector3: base=construction_point
	if not fetching and job.kind=="join": base = target.connector_world(job.descriptor.socket_b).origin
	if not fetching and target.get("kind") == "access_ramp": base = RampAnchor.point(target)
	var offset := Vector3(0, 0, 1.1)
	if (job.kind == "salvage" and not fetching) or (fetching and target.get_meta(&"stored", false)):
		if fetching and target.get_parent() is Node3D:
			base = target.get_parent().global_position
		offset = Vector3(0, 0, 3.35)
		var container: Node3D = target.get_parent() if fetching else target
		if container.get("kind") == "container":
			offset.z = float(container.definition.size.z) * .5 + .9
			var frame := _assembly_frame(container)
			if frame:
				base = frame.global_position
				offset.z = float(frame.definition.size.z) * .5 + 1.05
	elif target.get("assembly") != null and is_instance_valid(target.get("assembly")):
		var assembly: Node3D = target.assembly
		var ground_y: float = FieldWorksite.ground_y(yard,assembly)
		# A pending wheel/panel is already real staged stock during work. Include
		# its footprint before selecting a stance, even before native installation.
		var gap := .77
		var world_bounds: AABB = target.global_transform * Catalogue.bounds_of(target.definition)
		if is_instance_valid(job.get("tool")) and world_bounds.position.y < ground_y + 1.2:
			# Low fasteners need the long handle in front of the cube, with its
			# wide head beyond the face. A shorter gap folds the grip behind the
			# hip and forces the cutter-clearance solver into a sideways posture.
			gap = maxf(gap, float(job.tool.definition.size.y) * .95 + .1)
		# Tool clearance is measured from its work face, not added again outside
		# the whole chassis. Central cockpits remain reachable from a side aisle.
		var bounds := _assembly_bounds(assembly, true).grow(.77).merge(_part_bounds(target).grow(gap))
		var foundation := assembly.root_part() as Node3D
		if foundation and (foundation.global_transform * Catalogue.bounds_of(foundation.definition)).position.y > ground_y + 1.56:
			# Tall walkers have usable gaps between their legs. Work beside this
			# component rather than treating every space inside the body as solid.
			bounds = _part_bounds(target).grow(.85)
			under_frame = true
		var aim := Vector2(base.x, base.z)
		# Approach a real exterior face directly. A radial corner wastes tool reach on central components.
		var candidates := [Vector2(bounds.position.x, clampf(aim.y, bounds.position.y, bounds.end.y)),
			Vector2(bounds.end.x, clampf(aim.y, bounds.position.y, bounds.end.y)),
			Vector2(clampf(aim.x, bounds.position.x, bounds.end.x), bounds.position.y),
			Vector2(clampf(aim.x, bounds.position.x, bounds.end.x), bounds.end.y)]
		candidates.sort_custom(func(a: Vector2, b: Vector2) -> bool: return aim.distance_squared_to(a) < aim.distance_squared_to(b))
		base.x = candidates[0].x
		base.z = candidates[0].y
		offset = Vector3.ZERO
	elif target is RigidBody3D and target.linear_velocity.length() > 0.1:
		offset = target.global_basis * offset
	var point := base + offset
	# Probe real terrain/deck every update; targets follow moving machinery rather than stale plan positions.
	var from := point + Vector3.UP * 2.2
	if under_frame: from.y = FieldWorksite.ground_y(yard,target.assembly) + 1.5
	var query := PhysicsRayQueryParameters3D.create(from, from - Vector3.UP * 6.7)
	var exclude: Array[RID] = []
	for w: Node in workers: exclude.append(w.get_rid())
	if fetching and target is CollisionObject3D: exclude.append(target.get_rid())
	query.exclude = exclude
	query.collision_mask = 1
	var hit := yard.get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty(): point.y = hit.position.y
	else: point.y = base.y - (0.7 if fetching else 0.0)
	return point

func _station_work_position(worker: Node3D, station: Node3D) -> Dictionary:
	# The toe reaches a real pedal from behind its housing. Require a real machine
	# deck below the capsule before replacing exterior routing with onboard motion.
	var side: int = worker.control_foot_side()
	worker.work_foot_side = side
	var point: Vector3 = station.foot_control_world(side)
	var local := station.to_local(point)
	var gap: float = float(station.definition.size.z) * .5 + .32 - local.z
	point += station.global_basis.z * gap
	# Stand with the chosen hip behind its matching pedal after facing the pod.
	# Using the current walking heading made this point chase the turning helper.
	point -= station.global_basis.x * worker._hip_rest_offsets[side].x
	var exclude: Array[RID] = worker.query_exclusions()
	for other: Node in workers:
		if other != worker: exclude.append(other.get_rid())
	var collider := worker.get_node("Collision") as CollisionShape3D
	var space := yard.get_world_3d().direct_space_state
	# A neighbouring cockpit may obstruct the matching rear stance. Look for a
	# supported side stance with the SAME finite leg reach instead of allowing
	# the capsule to be pushed up its housing and canceling contact mid-clip.
	for offset: Vector2 in [Vector2.ZERO, Vector2(.55,-.12), Vector2(-.55,-.12)]:
		var candidate := point + station.global_basis.x * offset.x + station.global_basis.z * offset.y
		var query := PhysicsRayQueryParameters3D.create(candidate + Vector3.UP * .6, candidate - Vector3.UP * 1.5)
		query.exclude = exclude.duplicate()
		query.exclude.append(station.get_rid())
		query.collision_mask = 1
		var hit := space.intersect_ray(query)
		if hit.is_empty() or hit.normal.y < .8 or hit.collider.get("assembly") != station.assembly: continue
		candidate.y = hit.position.y
		var heel: Vector3 = candidate + station.global_basis.x * worker._hip_rest_offsets[1-side].x
		var supported := true
		# Inspect the non-operating sole's footprint too. A small adjacent battery
		# can be clear of the capsule yet lift that supporting foot mid-clip.
		for front: float in [-.16, 0.0, .1]:
			var sample := heel + station.global_basis.z * front
			var ray := PhysicsRayQueryParameters3D.create(sample + Vector3.UP, sample - Vector3.UP * .25, 1, exclude)
			var sole_hit := space.intersect_ray(ray)
			if sole_hit.is_empty() or sole_hit.normal.y < .8 or sole_hit.collider.get("assembly") != station.assembly or absf(sole_hit.position.y-candidate.y) > .16:
				supported = false
				break
		if not supported: continue
		var body_pose := Transform3D(Basis.IDENTITY, candidate + Vector3.UP * worker.ride_height)
		var clearance := PhysicsShapeQueryParameters3D.new()
		clearance.shape = collider.shape
		clearance.transform = body_pose * collider.transform
		clearance.exclude = exclude
		clearance.collision_mask = 1
		if not space.intersect_shape(clearance, 1).is_empty(): continue
		var hip: Vector3 = body_pose.origin + station.global_basis * worker._hip_rest_offsets[side]
		if hip.distance_to(station.foot_control_world(side)) > worker._leg_span(side) + .07: continue
		return {"point": candidate}
	return {}

func _storage_crew_axis(part: Node3D) -> Vector3:
	# A stored cooperative load approaches side by side in its actual bay,
	# including after that bay has turned. Retain this native frame for the
	# lease's entrance/exit steps when the source is later head-carried.
	var bay := part.get_parent() as Node3D
	if is_instance_valid(bay):
		var axis := bay.global_basis.x.slide(Vector3.UP)
		if axis.is_finite() and axis.length_squared()>.0001: return axis.normalized()
	return Vector3.RIGHT

func _storage_approach(part: Node3D, outward: bool) -> Vector3:
	var aisle := PhysicalDepot.aisle(part,part.get_parent(),outward)
	if not aisle.is_empty():
		var at: Vector3=aisle.point
		var ray := PhysicsRayQueryParameters3D.create(at+Vector3.UP*1.0,at-Vector3.UP*.4,1,workers.map(func(w:Node)->RID:return w.get_rid()))
		var support:=yard.get_world_3d().direct_space_state.intersect_ray(ray)
		if not support.is_empty(): at.y=support.position.y
		return at
	var container := part.get_parent() as Node3D
	var z := 5.5 if outward else 3.35
	if container.get("kind") == "container":
		z = float(container.definition.size.z) * .5 + (1.8 if outward else .9)
		var frame := _assembly_frame(container)
		if frame:
			container = frame
			z = float(frame.definition.size.z) * .5 + (2.0 if outward else 1.05)
	var point := container.to_global(Vector3(0, 0, z))
	var query := PhysicsRayQueryParameters3D.create(point + Vector3.UP * 3, point - Vector3.UP * 5)
	query.collision_mask = 1
	query.exclude = workers.map(func(w: Node) -> RID: return w.get_rid())
	var hit := yard.get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty(): point.y = hit.position.y
	return point

func _assembly_frame(part: Node) -> Node3D:
	var assembly: Node = part.get("assembly")
	if is_instance_valid(assembly):
		for p: Node in assembly.parts.values():
			if p.kind == "chassis": return p
		return assembly.root_part()
	return null

func _navigate(worker: Node3D, destination: Vector3, arrival := .7, open_depot := false, local_machine: Node3D = null) -> bool:
	if not source_budget_enabled: return _navigate_observed(worker,destination,arrival,open_depot,local_machine)
	var started_usec := Time.get_ticks_usec()
	var result: bool = _navigate_observed(worker,destination,arrival,open_depot,local_machine)
	_record_source_budget("navigate_inclusive",started_usec)
	return result

func _navigate_observed(worker: Node3D, destination: Vector3, arrival := .7, open_depot := false, local_machine: Node3D = null) -> bool:
	var key: int = worker.get_instance_id()
	var route: Dictionary = _routes.get(key, {})
	var local_id: int = local_machine.get_instance_id() if is_instance_valid(local_machine) else 0
	var depot_route: bool=is_instance_valid(local_machine) and local_machine==yard.storage
	var ground_route: bool=depot_route or local_machine==yard
	if route.is_empty() or route.get("local_machine",0)!=local_id or route.get("open_depot",false) != open_depot or float(route.get("until", 0.0)) < _clock or destination.distance_to(route.goal) > .65:
		var xy := Vector2(worker.global_position.x, worker.global_position.z)
		var escaping := false
		for rect: Rect2 in _obstacle_bounds(open_depot,local_machine,destination.y): escaping = escaping or rect.has_point(xy)
		var from: Vector3 = worker._ground_point if ground_route else worker.global_position-Vector3.UP*worker.ride_height if local_machine else worker.global_position
		var planned: Array = _plan_route(from,destination,open_depot,local_machine,destination.y)
		if local_machine:
			planned = _supported_work_path(worker,local_machine,from,destination,planned)
			# A native-clear full path can enter a concave space inside the
			# coarse exterior bounds. It already proves the actual endpoint.
			if not planned.is_empty(): escaping = false
		if ground_route and worker.energetic_work_transit() and planned.size() > 2:
			# The native sampler has already proved these exact straight segments.
			# Retain every bend/rise and bound lookahead; remove only redundant
			# collinear samples once at this existing route regeneration boundary.
			var compacted: Array = [planned[0]]
			for i in range(1, planned.size() - 1):
				var segment: Vector3 = planned[i + 1] - compacted[-1]
				var previous: Vector3 = planned[i] - compacted[-1]
				var fraction: float = previous.dot(segment) / maxf(segment.length_squared(), .000001)
				if segment.length() <= 1.5 and fraction > 0.0 and fraction < 1.0 and previous.distance_squared_to(segment * fraction) < .00000004: continue
				compacted.append(planned[i])
			compacted.append(planned[-1])
			planned = compacted
		route = {"goal": destination, "until": _clock + .6, "points": planned, "escaping": escaping, "open_depot":open_depot,"local_machine":local_id}
		_routes[key] = route
	var points: Array = route.points
	if local_machine and points.is_empty(): worker.stop_navigation(); return false
	while points.size() > 1 and Vector2(points[0].x - worker.global_position.x, points[0].z - worker.global_position.z).length() < .55:
		if ground_route:
			# Dense native samples may turn around low stock. Pruning one may
			# only replace that bend with a freshly proved floor/body segment.
			var shortcut: Array[Vector3]=[worker._ground_point,points[1]]
			if Access.ground_path(worker,local_machine,shortcut).is_empty(): break
		points.pop_front()
	var next_point: Vector3 = points[0] if not points.is_empty() else destination
	# Routing may move an access point off a chassis edge. Probe its actual new support, not the old deck height.
	var query := PhysicsRayQueryParameters3D.create(next_point + Vector3.UP * 1.5, next_point - Vector3.UP * 4.0)
	query.exclude = workers.map(func(w: Node) -> RID: return w.get_rid())
	query.collision_mask = 1
	var hit := yard.get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty(): next_point.y = hit.position.y
	if ground_route and worker._ground_point.distance_squared_to(next_point)>.000001:
		# Avoidance or native support may have changed since route admission.
		var continuation: Array[Vector3]=[worker._ground_point,next_point]
		if Access.ground_path(worker,local_machine,continuation).is_empty():
			worker.stop_navigation()
			return false
	route.erase("empty_tool_departure")
	if worker.back_tool and worker.back_tool.loose_tool_support_recovery() and not open_depot and not local_machine \
		and destination.is_equal_approx(worker.safe_position-Vector3.UP*worker.ride_height):
		# Admit only this existing parking waypoint through the unchanged
		# native support/capsule sampler. Recheck with the ordinary route tick,
		# rather than querying the full path on every 120 Hz force tick.
		# The authorized parking goal must actually lie beyond the original
		# loose support, rather than being another point on the same mallet.
		query.from=destination+Vector3.UP*1.5
		query.to=destination-Vector3.UP*4.0
		var parking_hit:=yard.get_world_3d().direct_space_state.intersect_ray(query)
		var departure: Array[Vector3]=[worker._ground_point,next_point]
		if parking_hit.is_empty() or parking_hit.collider==worker._ground_body \
			or Access.ground_path(worker,null,departure).is_empty():
			worker.stop_navigation()
			return false
		route.empty_tool_departure=next_point
	worker.navigate_to(next_point, points.size() <= 1)
	# A nearby clear goal can already be inside the ordinary .7 m arrival
	# radius. Keep its original finite force until the central ray leaves the
	# loose support; ordinary arrival resumes as soon as that support changes.
	return not route.escaping and points.size() <= 1 and worker.at_target(arrival) \
		and not route.has("empty_tool_departure")

func _supported_work_path(worker: RigidBody3D, machine: Node3D, from: Vector3, to: Vector3, planned: Array, prospective_depot_tool := false) -> Array[Vector3]:
	var depot_tool_route: bool=prospective_depot_tool and machine==yard.storage
	if machine==yard.storage:
		var job: Dictionary=active_jobs.get(worker.current_job_id,{})
		depot_tool_route=depot_tool_route or job.get("phase","") in ["tool_route","tool_fetch"]
	if depot_tool_route:
		# The coarse padding is conservative intent, not a native obstacle.
		# Prefer a genuinely clear complete chord, retaining every ordinary
		# support, stored-body, motion, capsule and carried-load query.
		var direct: Array[Vector3]=[from,to]
		var checked: Array[Vector3]=Access.ground_path(worker,machine,direct)
		if not checked.is_empty(): return checked
	var points: Array[Vector3] = [from]
	for at: Vector3 in planned: points.append(at)
	# Exterior routing can clamp the goal or return a temporary escape. A
	# work stance is reachable only if its final segment also passes the same
	# native support, capsule and complete carried-load checks.
	if points[-1] != to: points.append(to)
	var sampled: Array[Vector3] = Access.ground_path(worker,machine,points)
	if not sampled.is_empty() or not (worker.carrying or depot_tool_route): return sampled
	# Construction pads can also block an empty-handed return to the depot.
	# Try the same two finite outside turns for tool acquisition; each still
	# proves the complete native support, body and any whole head load.
	for corner: Vector3 in [Vector3(to.x,from.y,from.z),Vector3(from.x,to.y,to.z)]:
		var bent: Array[Vector3] = [from,corner,to]
		sampled = Access.ground_path(worker,machine,bent)
		if not sampled.is_empty(): return sampled
	return []

func _assembly_bounds(assembly: Node3D, exclude_walkable := false) -> Rect2:
	var bounds := Rect2()
	var have := false
	for p: Node3D in assembly.parts.values():
		if p.is_queued_for_deletion() or not p.installed or (exclude_walkable and p.kind == "access_ramp"): continue
		var r := _part_bounds(p)
		bounds = bounds.merge(r) if have else r
		have = true
	if not have:
		var first: Node3D
		for p: Node3D in assembly.parts.values():
			if not first: first = p
			if p.kind == "chassis":
				first = p
				break
		if first:
			bounds = _part_bounds(first)
	return bounds

func _obstacle_bounds(open_depot := false, local_machine: Node3D = null, standing_height := 0.0, depot_out: Variant = null) -> Array[Rect2]:
	var obstacles: Array[Rect2] = []
	if is_instance_valid(yard.storage):
		# Each real narrow depot plinth is an obstacle; the actual two-metre
		# aisles and east-side lane remain reachable rather than a solid yard box.
		for row: Rect2 in PhysicalDepot.rows():
			var floor: AABB=yard.storage.global_transform*AABB(Vector3(row.position.x,0,row.position.y),Vector3(row.size.x,.3,row.size.y))
			obstacles.append(Rect2(Vector2(floor.position.x,floor.position.z),Vector2(floor.size.x,floor.size.z)).grow(.45))
		for stock: Node3D in yard.loose_parts:
			if not is_instance_valid(stock) or stock.is_queued_for_deletion() or stock.get_parent()!=yard.storage or not stock.get_meta(&"stored",false): continue
			var bounds: AABB=stock.global_transform*PhysicalDepot.bounds(stock)
			if bounds.end.y>standing_height+.05 and bounds.position.y<standing_height+1.65:
				obstacles.append(Rect2(Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.size.x,bounds.size.z)).grow(.45))
	# Only this exact ordered depot prefix shares corner visibility. Moving
	# machines and dropped tools are checked live against every clear edge.
	if depot_out is Array: depot_out.append_array(obstacles)
	if is_instance_valid(yard.storage) and local_machine==yard.storage:
		# Dropped original tools leave storage but remain finite native
		# obstacles. Include their full envelope in the depot detour search.
		for stock: Node3D in yard.loose_parts:
			if not is_instance_valid(stock) or stock.is_queued_for_deletion() or not stock.is_inside_tree(): continue
			var body:=stock as RigidBody3D
			if not body or (body.collision_layer & 1)==0 or body.get_meta(&"stored",false): continue
			var definition: Variant=body.get("definition")
			if not definition is Dictionary or definition.get("category","")!="tool": continue
			if is_instance_valid(body.get("carrier")) or is_instance_valid(body.get("assembly")): continue
			if body.get_meta(&"player_carry",false) or body.get_meta(&"in_transit",false) or not str(body.get_meta(&"equipped_worker","")).is_empty(): continue
			var pose:=body.global_transform
			var native:=PhysicsServer3D.body_get_direct_state(body.get_rid())
			if native: pose=native.transform
			var bounds: AABB=pose*PhysicalDepot.bounds(body)
			if bounds.end.y>standing_height+.05 and bounds.position.y<standing_height+1.65:
				obstacles.append(Rect2(Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.size.x,bounds.size.z)).grow(.45))
	for assembly: Node in yard.assemblies:
		if not is_instance_valid(assembly): continue
		if assembly == local_machine:
			# Only this validated service fallback enters concave spaces. Other
			# machines keep the original solid-envelope avoidance behavior.
			for part: Node3D in assembly.parts.values():
				if not part.installed or part.kind=="access_ramp": continue
				var bounds: AABB = part.global_transform*Catalogue.bounds_of(part.definition)
				if bounds.end.y>standing_height+.5 and bounds.position.y<standing_height+1.65: obstacles.append(_part_bounds(part).grow(.34))
			continue
		if assembly.parts.values().any(func(p: Node) -> bool: return p.installed and p.kind != "access_ramp"):
			var foundation: Node3D = assembly.root_part()
			var ground_y: float = FieldWorksite.ground_y(yard,assembly)
			if foundation and (foundation.global_transform * Catalogue.bounds_of(foundation.definition)).position.y > ground_y + 1.56:
				for p: Node3D in assembly.parts.values():
					if not p.installed or p.kind == "access_ramp": continue
					var world_bounds: AABB = p.global_transform * Catalogue.bounds_of(p.definition)
					if world_bounds.position.y < ground_y + 1.56 and world_bounds.end.y > ground_y + .54:
						obstacles.append(_part_bounds(p).grow(.45))
				continue
			obstacles.append(_assembly_bounds(assembly, true).grow(.65))
	# Fixed construction equipment is outside the assembly graph. Its real
	# columns must still participate in the same exterior route search.
	for jigs: Dictionary in yard._construction_jigs.values():
		for jig: Dictionary in jigs.values():
			var owner: Node3D = jig.get("node")
			if not is_instance_valid(owner) or owner.is_queued_for_deletion() or not owner.is_inside_tree(): continue
			for body: Node in owner.get_children():
				if not body is StaticBody3D or body.is_queued_for_deletion() or (body.collision_layer & 1)==0: continue
				for child: Node in body.get_children():
					if not child is CollisionShape3D or child.disabled or not child.shape is BoxShape3D: continue
					var size: Vector3 = child.shape.size
					var bounds: AABB = child.global_transform*AABB(-size*.5,size)
					if bounds.end.y<=standing_height+.02 or bounds.position.y>=standing_height+1.65: continue
					obstacles.append(Rect2(Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.size.x,bounds.size.z)).grow(.65))
	return obstacles

func _part_bounds(part: Node3D) -> Rect2:
	var bounds: AABB = part.global_transform * Catalogue.bounds_of(part.definition)
	return Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))

func _plan_route(from: Vector3, to: Vector3, open_depot := false, local_machine: Node3D = null, standing_height := 0.0) -> Array:
	if not source_budget_enabled: return _plan_route_observed(from,to,open_depot,local_machine,standing_height)
	var started_usec := Time.get_ticks_usec()
	var result: Array = _plan_route_observed(from,to,open_depot,local_machine,standing_height)
	_record_source_budget("plan_route_inclusive",started_usec)
	return result

func _plan_route_observed(from: Vector3, to: Vector3, open_depot := false, local_machine: Node3D = null, standing_height := 0.0) -> Array:
	var depot_obstacles: Array[Rect2] = []
	var obstacles := _obstacle_bounds(open_depot,local_machine,standing_height,depot_obstacles)
	var start := Vector2(from.x, from.z)
	var finish := Vector2(to.x, to.z)
	# A worker displaced into a machine envelope first steps out on the nearest accessible side.
	for rect: Rect2 in obstacles:
		if rect.has_point(start):
			var exits := [Vector2(rect.position.x - .4, start.y), Vector2(rect.end.x + .4, start.y),
				Vector2(start.x, rect.position.y - .4), Vector2(start.x, rect.end.y + .4)]
			exits.sort_custom(func(a: Vector2, b: Vector2) -> bool: return start.distance_squared_to(a) < start.distance_squared_to(b))
			return [Vector3(exits[0].x, to.y, exits[0].y)]
		if rect.has_point(finish):
			# Work positions stay outside solid frames; reaching a connector never requires walking through armour.
			var exits := [Vector2(rect.position.x - .12, finish.y), Vector2(rect.end.x + .12, finish.y),
				Vector2(finish.x, rect.position.y - .12), Vector2(finish.x, rect.end.y + .12)]
			exits.sort_custom(func(a: Vector2, b: Vector2) -> bool: return finish.distance_squared_to(a) < finish.distance_squared_to(b))
			finish = exits[0]
	var nodes: Array[Vector2] = [start, finish]
	for r: Rect2 in obstacles:
		for corner: Vector2 in [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]:
			nodes.append(corner + (corner - r.get_center()).normalized() * .15)
	var visibility: Dictionary = _corner_visibility_for(depot_obstacles)
	var depot_nodes: int = depot_obstacles.size()*4+2
	# One copy-on-write buffer per complete route, not per queried edge.
	var visibility_bits: PackedByteArray = visibility.get("bits",PackedByteArray())
	var distance: Array[float] = []
	var parents: Array[int] = []
	var visited: Array[bool] = []
	for i in nodes.size():
		distance.append(INF)
		parents.append(-1)
		visited.append(false)
	distance[0] = 0.0
	# Keep the original shortest-distance, lowest-index selection order.
	# A bounded indexed heap avoids rescanning every vertex after each visit;
	# unchanged relaxation still examines neighbours in original index order.
	var frontier: Array[int] = [0]
	var frontier_positions: Array[int] = []
	frontier_positions.resize(nodes.size())
	frontier_positions.fill(-1)
	frontier_positions[0] = 0
	while not frontier.is_empty():
		var nearest := _route_frontier_pop(frontier,frontier_positions,distance)
		if nearest == 1: break
		visited[nearest] = true
		var blocked_depot_edges := PackedInt32Array()
		# Keep original neighbour order while omitting only directed edges
		# already proved blocked by this exact unchanged depot geometry.
		for next: int in _route_neighbours(nearest,nodes.size(),depot_nodes,visibility):
			if visited[next] or next == nearest: continue
			# This edge cannot change the same strictly-shorter relaxation.
			# Keep the original vertex order and exact distance expression.
			var d := distance[nearest] + nodes[nearest].distance_to(nodes[next])
			if d >= distance[next]: continue
			# Start and destination are never cached. Ordered corner keys retain
			# the original directed clip arithmetic, including boundary rounding.
			var corner_edge: bool = nearest > 1 and next > 1 and nearest < depot_nodes and next < depot_nodes and not visibility_bits.is_empty()
			var edge_index: int = nearest*depot_nodes+next
			var edge_byte: int = edge_index >> 2
			var edge_shift: int = (edge_index & 3)*2
			var state: int = (visibility_bits[edge_byte] >> edge_shift) & 3 if corner_edge else 0
			# A known depot obstruction remains blocked regardless of the live tail.
			# Avoid rebuilding its chord envelope before the unchanged refusal.
			if state != 0 and state != 2:
				blocked_depot_edges.append(next)
				continue
			var visible := true
			var chord_min := nodes[nearest].min(nodes[next])
			var chord_max := nodes[nearest].max(nodes[next])
			if state != 0:
				visible = state == 2
			else:
				var tested: Array[Rect2] = depot_obstacles if corner_edge else obstacles
				for rect: Rect2 in tested:
					# Retain the original open-envelope rejection and clip test.
					var rect_end := rect.end
					if chord_max.x <= rect.position.x or chord_min.x >= rect_end.x: continue
					if chord_max.y <= rect.position.y or chord_min.y >= rect_end.y: continue
					if _segment_inside(nodes[nearest], nodes[next], rect):
						visible = false
						break
				if corner_edge:
					visibility_bits[edge_byte] |= (2 if visible else 1) << edge_shift
					if not visible: blocked_depot_edges.append(next)
			if visible and corner_edge:
				# Depot clearance alone never admits passage through a machine.
				# Its current envelope is tested even when the depot table is warm.
				for obstacle_index: int in range(depot_obstacles.size(),obstacles.size()):
					var rect: Rect2 = obstacles[obstacle_index]
					var rect_end := rect.end
					if chord_max.x <= rect.position.x or chord_min.x >= rect_end.x: continue
					if chord_max.y <= rect.position.y or chord_min.y >= rect_end.y: continue
					if _segment_inside(nodes[nearest],nodes[next],rect):
						visible = false
						break
			if not visible: continue
			if d < distance[next]:
				distance[next] = d
				parents[next] = nearest
				_route_frontier_update(frontier,frontier_positions,distance,next)
		if not blocked_depot_edges.is_empty(): _prune_route_neighbours(nearest,visibility,blocked_depot_edges)
	if not visibility_bits.is_empty(): visibility.bits = visibility_bits
	var result: Array = []
	var cursor := 1
	while cursor > 0 and parents[cursor] >= 0:
		result.push_front(Vector3(nodes[cursor].x, to.y, nodes[cursor].y))
		cursor = parents[cursor]
	if result.is_empty(): result = [to]
	return result

func _route_frontier_before(a: int, b: int, distance: Array[float]) -> bool:
	# Equal distances use the same first index as the original linear scan.
	return distance[a] < distance[b] or (distance[a] == distance[b] and a < b)

func _route_frontier_update(frontier: Array[int], positions: Array[int], distance: Array[float], node: int) -> void:
	var at: int = positions[node]
	if at < 0:
		at = frontier.size()
		frontier.append(node)
		positions[node] = at
	# Existing keys only decrease. Each unvisited vertex has at most one entry.
	while at > 0:
		var parent: int = (at-1) >> 1
		var previous: int = frontier[parent]
		if not _route_frontier_before(node,previous,distance): break
		frontier[at] = previous
		positions[previous] = at
		frontier[parent] = node
		positions[node] = parent
		at = parent

func _route_frontier_pop(frontier: Array[int], positions: Array[int], distance: Array[float]) -> int:
	var result: int = frontier[0]
	var last: int = frontier.pop_back()
	positions[result] = -1
	if frontier.is_empty(): return result
	frontier[0] = last
	positions[last] = 0
	var at := 0
	while at*2+1 < frontier.size():
		var child: int = at*2+1
		if child+1 < frontier.size() and _route_frontier_before(frontier[child+1],frontier[child],distance): child += 1
		var next: int = frontier[child]
		if not _route_frontier_before(next,last,distance): break
		frontier[at] = next
		positions[next] = at
		frontier[child] = last
		positions[last] = child
		at = child
	return result

func _corner_visibility_for(obstacles: Array[Rect2]) -> Dictionary:
	# Absolute rectangles and their order are compared exactly on every call.
	# A moved/removed body, different access envelope or standing height gets
	# its own geometry; no native result or route survives this comparison.
	var node_count: int = obstacles.size()*4+2
	# Four directed states per byte plus lazy packed neighbour rows,
	# <=1.1 MiB per geometry and four entries, usually much less.
	# Larger depot prefixes use the original uncached calculation without truncation.
	if node_count > 512: return {}
	for index: int in _route_visibility_cache.size():
		var cached: Dictionary = _route_visibility_cache[index]
		if cached.obstacles != obstacles: continue
		_route_visibility_cache.remove_at(index)
		_route_visibility_cache.append(cached)
		return cached
	if _route_visibility_cache.size() >= 4: _route_visibility_cache.pop_front()
	var bits := PackedByteArray()
	bits.resize((node_count*node_count+3) >> 2)
	bits.fill(0)
	var entry := {"obstacles":obstacles.duplicate(),"bits":bits,"nodes":node_count,"neighbours":{},"corners":PackedInt32Array(range(2,node_count))}
	_route_visibility_cache.append(entry)
	return entry

func _route_neighbours(nearest: int, node_count: int, depot_nodes: int, visibility: Dictionary) -> Variant:
	if nearest < 2 or nearest >= depot_nodes or visibility.is_empty():
		return node_count # Keep original integer iteration for endpoints/live nodes.
	var rows: Dictionary = visibility.neighbours
	# A first untouched row uses the original allocation-free iteration.
	# Only a newly proved depot obstruction needs its own sparse row.
	if not rows.has(nearest): return node_count
	# Endpoints and the moving-machine/dropped-tool tail are always present.
	# Unknown depot chords also remain until the original clip test proves them.
	var result := PackedInt32Array([0,1])
	result.append_array(rows[nearest])
	for index: int in range(depot_nodes,node_count): result.append(index)
	return result

func _prune_route_neighbours(nearest: int, visibility: Dictionary, blocked: PackedInt32Array) -> void:
	var rows: Dictionary = visibility.neighbours
	# Create an independent packed wrapper around the current/full row.
	# Its shared backing buffer detaches once on the first native removal.
	var retained := PackedInt32Array(rows.get(nearest,visibility.corners))
	# The route already observed these exact directed obstructions in ascending
	# neighbour order. Remove backwards using native packed-array operations,
	# instead of rescanning every retained/unknown edge's visibility bits.
	var index := blocked.size()-1
	while index >= 0:
		retained.remove_at(retained.bsearch(blocked[index]))
		index -= 1
	rows[nearest] = retained

func _segment_inside(a: Vector2, b: Vector2, rect: Rect2) -> bool:
	# Preserve the original Vector2 subtraction and directed/open clip arithmetic.
	# Explicit axes avoid interpreter loops and repeated Variant axis indexing.
	var d := b - a
	var rect_end := rect.end
	var enter := 0.0
	var leave := 1.0
	if absf(d.x) < .00001:
		if a.x <= rect.position.x or a.x >= rect_end.x: return false
	else:
		var t1 := (rect.position.x - a.x) / d.x
		var t2 := (rect_end.x - a.x) / d.x
		enter = maxf(enter,minf(t1,t2))
		leave = minf(leave,maxf(t1,t2))
		if enter >= leave: return false
	if absf(d.y) < .00001:
		if a.y <= rect.position.y or a.y >= rect_end.y: return false
	else:
		var t1 := (rect.position.y - a.y) / d.y
		var t2 := (rect_end.y - a.y) / d.y
		enter = maxf(enter,minf(t1,t2))
		leave = minf(leave,maxf(t1,t2))
		if enter >= leave: return false
	return leave > .01 and enter < .99

func _work_action(job: Dictionary) -> String:
	return {"prepare": "assemble", "build": "assemble", "join":"assemble", "replace": "assemble", "salvage": "place", "repair": "repair", "maintenance": "maintenance", "unbend": "unbend", "dismantle": "assemble", "operate": "operate"}.get(str(job.kind), "inspect")

func _work_label(job: Dictionary) -> String:
	if job.kind=="join": return "Securing connector on " + _part_title(job)
	return {"prepare": "Preparing grounded material · ", "build": "Installing ", "replace": "Replacing ", "salvage": "Stowing ", "repair": "Repairing ", "unbend": "Straightening joint · ",
		"maintenance": "Servicing ", "dismantle": "Releasing ", "operate": "Operating "}.get(str(job.kind), "Inspecting ") + _part_title(job)

func _part_title(job: Dictionary) -> String:
	var title: String = job.part.definition.get("title", "")
	return title if not title.is_empty() else String(job.part.kind).capitalize()

func _head_pickup_blocker(entry: Dictionary) -> String:
	# Small toe pickups have their own contact/launch guards. A head handover
	# must keep every crew member's retained tool clear, including the partner.
	if entry.job.get("light_pickup", false): return ""
	for member: Node in entry.crew:
		if not member.tool_pose_blocked.is_empty(): return member.tool_pose_blocked
	return ""

func _job_tool_custody_lost(entry: Dictionary) -> bool:
	if yard.work_tool_capability(str(entry.job.kind)).is_empty(): return false
	# Before pickup the lease owns reserved depot stock. After real fitting,
	# readiness follows current same-body foot/back/flight custody each time.
	var acquiring: bool=entry.phase in ["tool_route","tool_fetch","tool_change"] \
		or (entry.phase in ["boarding_approach","boarding"] and entry.get("boarding_resume","") in ["tool_route","tool_fetch"])
	if acquiring and not entry.get("tool_ready",false): return false
	return entry.crew.is_empty() or not yard.worker_owns_work_tool(entry.crew[0],entry.job.get("tool"))

func _on_contact(kind: String, worker: Node) -> void:
	var id: String = worker.current_job_id
	if not active_jobs.has(id): return
	var entry: Dictionary = active_jobs[id]
	if entry.get("unloading_held",false): return
	if entry.crew[0] != worker: return
	var job: Dictionary = entry.job
	if _job_tool_custody_lost(entry):
		_cancel(entry, "Original work tool released; recover a compatible physical tool before continuing")
		return
	if entry.phase == "tool_change" and kind == "tool_change":
		if not yard.perform_work(job, float(entry.progress), "tool_pickup", entry.crew):
			_cancel(entry, "Tool fitting interrupted; checking compatibility")
			return
		entry.tool_ready = true
	elif entry.phase == "work" and job.kind == "prepare" and kind == "assemble" and float(entry.progress) >= 1.0 and not entry.complete:
		entry.complete = true
		if yard.perform_work(job, 1.0, "complete", entry.crew): _finish(entry)
		else: _cancel(entry, "Grounded material or supported tool contact changed; original stock remains recoverable")
	elif entry.phase == "work" and job.kind == "operate" and kind == "operate" and float(entry.progress) >= 1.0 and not entry.complete:
		entry.complete = true
		if yard.perform_work(job, 1.0, "complete", entry.crew): _finish(entry)
		else: _cancel(entry, "Pedal support changed; checking the station")
	elif entry.phase=="work" and job.kind=="join" and kind=="assemble" and float(entry.progress)>=1.0 and not entry.complete:
		entry.complete = true
		if yard.perform_work(job,1.0,"complete",entry.crew): _finish(entry)
		else: _cancel(entry,"Structural sockets changed; preserve supported alignment before securing their link")
	elif entry.phase == "pickup" and kind == "pickup" and not entry.pickup:
		var blocker := _head_pickup_blocker(entry)
		if not blocker.is_empty():
			entry.retry_delay = 20.0
			_cancel(entry, blocker)
			return
		if not yard.perform_work(job, float(entry.progress), "pickup", entry.crew):
			_cancel(entry, "Part unavailable; checking another job")
			return
		entry.pickup = true
		if not job.get("light_pickup",false):
			var load_mass: float = job.part.mass / entry.crew.size()
			for w: Node in entry.crew: w.set_cargo(load_mass)
		if entry.crew.size() > 1:
			worker.carry_partner = entry.crew[1]
			for other: Node in entry.crew:
				if other != worker: other.brace_leader = worker; other.brace_load = job.part
	elif entry.phase == "inspect" and kind == "inspect":
		if _hold_supported_tool_return(entry) or not worker.foot_contact_ready(): return
		if not worker.tool_pose_blocked.is_empty() and not (worker.back_tool and worker.back_tool.supported_foot_return_pending()):
			entry.retry_delay = 20.0
			_cancel(entry, worker.tool_pose_blocked)
			return
		entry.inspected = true
	elif entry.phase=="storage_staging" and kind=="place":
		entry.arrival_pending=true
		_try_storage_admit(entry)

	elif entry.phase == "staging" and kind == "place":
		entry.arrival_pending=true
		_try_stage_admit(entry)

	elif entry.phase == "placing" and kind == "place" and not entry.complete:
		entry.complete = true # Never consume the same reserved physical resource twice.
		if yard.perform_work(job, 1.0, "complete", entry.crew):
			_finish(entry)
		else:
			_cancel(entry, "Installation interrupted; reserved cargo recovered")

func _try_storage_admit(entry: Dictionary) -> bool:
	if not entry.get("arrival_pending",false): return false
	var target: Node3D=entry.get("storage_target")
	if not is_instance_valid(target) or not yard._material_arrived(entry.job.part,target.global_transform): return false
	if not entry.crew.all(func(w:Node)->bool:return w.on_ground and w._pose.evaluated_valid and w._pose.evaluated_grounded.any(func(planted:bool)->bool:return planted)): return false
	if not yard.perform_work(entry.job,1.0,"complete",entry.crew): return false
	entry.complete=true
	_finish(entry)
	return true

func _try_stage_admit(entry: Dictionary) -> bool:
	if entry.get("staged",false): return true
	if not yard._material_arrived(entry.job.part,entry.job.target.global_transform): return false
	if not entry.crew.all(func(w:Node)->bool:return w.on_ground and w._pose.evaluated_valid and w._pose.evaluated_grounded.all(func(planted:bool)->bool:return planted)): return false
	if not yard.perform_work(entry.job,float(entry.progress),"stage",entry.crew): return false
	entry.staged=true
	# This exact native stock arrival completes the bounded carrying trip.
	# Give the separate supported foot-work access its own unchanged interval;
	# elapsed still records the whole lease for diagnostics.
	entry.access_started_at=float(entry.elapsed)
	entry.erase("arrival_pending")
	for w: Node in entry.crew:
		w.set_cargo(0.0)
		w.cargo_staging=false
		w.cargo_target=null
		w.carry_partner=null
		w.brace_leader=null
		w.brace_load=null
	return true

func _on_action_finished(_kind: String, worker: Node) -> void:
	var id: String = worker.current_job_id
	if not active_jobs.has(id):
		# A jobless helper just finished its post-commit tail: admit its next
		# useful lease on this tick instead of idling up to a refresh period.
		_refresh_clock = maxf(_refresh_clock, .25)
		return
	var entry: Dictionary = active_jobs[id]
	if entry.get("unloading_held",false): return
	if entry.crew[0] != worker:
		# A brace partner keeps holding through the whole shared phase rather
		# than dropping to idle between the lead's strokes. Contacts of
		# partners stay ignored; the lead's own re-begin remains a no-op.
		if _kind == "brace" and worker.action.is_empty() and String(entry.phase) in ["work","staging","storage_staging","placing"]:
			worker.begin_action("brace")
		return
	if _job_tool_custody_lost(entry):
		_cancel(entry, "Original work tool released; recover a compatible physical tool before continuing")
		return
	match String(entry.phase):
		"tool_change":
			var tool: Node3D=entry.job.get("tool")
			# B5: foot, seated or airborne-stow custody of the same body all count,
			# so the stow stunt may begin in the fitting tail.
			if not entry.get("tool_ready", false) or not is_instance_valid(tool) \
				or worker.equipped_tool!=tool or not yard.worker_owns_work_tool(worker, tool):
				_cancel(entry, "Tool change interrupted; recover the same original tool before continuing")
				return
			# A completed same-body fitting gives material transport its own bounded
			# interval. Never renew it on contact, stance polling or a repeated callback.
			if _kind == "tool_change" and entry.job.kind in ["build", "replace"] \
				and not entry.get("staged", false) and not entry.has("transport_started_at"):
				entry.transport_started_at = float(entry.elapsed)
			worker.work_target = entry.job.connection.b if entry.job.kind == "unbend" and is_instance_valid(entry.job.get("connection")) else entry.job.target
			entry.phase = entry.resume_phase
		"storage_staging":
			_cancel(entry,"Storage contact was not reached; original body released at its actual pose")
		"staging":
			if not entry.get("staged", false):
				_cancel(entry, "Placement interrupted; cargo recovered")
				return
			if entry.job.get("head_first_pickup",false) and entry.crew.size()>1:
				# The actual target fixture now owns the load. Route the original crew
				# to separate supported tool workspaces before any retrieval/inspection.
				entry.phase="approach"
				return
			entry.phase = "inspect"
			for w: Node in entry.crew: w.begin_action("inspect")
		"pickup":
			if not entry.pickup:
				entry.retry_delay = 20.0
				if entry.job.get("light_pickup",false): entry.job.part.set_meta(&"toss_failed", true)
				_cancel(entry, "Toe pickup out of reach; provide supported access to the part")
			elif entry.job.get("light_pickup",false) and worker.pickup.state != "caught": entry.phase = "pickup_flight"
			else: _pickup_finished(entry)
		"inspect":
			if not entry.get("inspected",false):
				entry.retry_delay = 20.0
				_cancel(entry,"Inspection probe cannot reach; clear the work face or provide a platform")
				return
			entry.phase = "work"
			entry.last_clip_progress = entry.progress
			entry.contact_misses = 0
			for w: Node in entry.crew: w.begin_action(_work_action(entry.job) if w == worker else "brace")
		"work":
			if float(entry.progress) < 1.0:
				entry.contact_misses = int(entry.get("contact_misses", 0)) + 1 if float(entry.progress) - float(entry.get("last_clip_progress", 0.0)) < .015 else 0
				entry.last_clip_progress = entry.progress
				if int(entry.contact_misses) >= 3:
					entry.retry_delay = 20.0
					_cancel(entry, "Foot/tool contact blocked; clear the work face or provide a platform")
					return
				for w: Node in entry.crew: w.begin_action(_work_action(entry.job) if w == worker else "brace")

func _pickup_finished(entry: Dictionary) -> void:
	entry.crew[0].pickup.clear()
	entry.crew[0].work_target = entry.job.target
	entry.phase = "carry_exit" if entry.has("exit_position") else "carry"

func _begin_storage_staging(entry: Dictionary) -> void:
	var destination: Dictionary=entry.job.storage_destination
	var target:=Node3D.new()
	target.name="ReservedStorageContact"
	entry.job.target.add_child(target)
	target.transform=destination.placement.pose
	entry.storage_target=target
	entry.phase="storage_staging"
	var lead: Node=entry.crew[0]
	for w: Node in entry.crew:
		w.cargo_target=target
		w.cargo_staging=true
		w.begin_action("place" if w==lead else "brace")
		if w!=lead:
			w._action_length=lead._action_length
			w._animation.speed_scale=w._animation.get_animation(w._animation.current_animation).length/w._action_length

func _clear_storage_target(entry: Dictionary) -> void:
	var target: Node3D=entry.get("storage_target")
	if is_instance_valid(target): target.queue_free()
	entry.erase("storage_target")

func _begin_staging(entry: Dictionary) -> void:
	var lead: Node = entry.crew[0]
	for w: Node in entry.crew:
		w.cargo_target = entry.job.target
		w.cargo_staging = true
		w.begin_action("place" if w == lead else "brace")
		if w != lead and w.action == "brace" and lead.action == "place":
			# Partners finish the shared staging with the lead instead of
			# idling for the remainder of its longer place clip.
			w._action_length = lead._action_length
			w._animation.speed_scale = w._animation.get_animation(w._animation.current_animation).length / w._action_length

# Gaze hint only (helper attention_point/attention_node): stock while fetching
# or flipping it onto the head, the tool while fetching/fitting it, otherwise
# the target. The node lets the eyes pursue a moving part instead of jumping
# between stale points, so a member is only written when its focus changes.
# work_target and every reach/admission contract stay untouched.
func _publish_attention(entry: Dictionary) -> void:
	var job: Dictionary = entry.job
	var phase := str(entry.get("phase", ""))
	var focus: Variant = job.get("target")
	if phase in ["tool_route", "tool_fetch", "tool_change"]: focus = job.get("tool")
	elif phase in ["fetch_outside", "fetch_route", "fetch", "head_pickup", "pickup", "pickup_flight"]: focus = job.get("part")
	if not is_instance_valid(focus) or not focus is Node3D: focus = job.get("target")
	var node: Node3D = focus if is_instance_valid(focus) and focus is Node3D else null
	for member: Variant in entry.crew:
		if is_instance_valid(member) and "attention_point" in member and member.attention_node!=node:
			# Positions are read only when a member's focus changes (and only
			# from a node inside the tree).
			member.attention_point = node.global_position if node and node.is_inside_tree() else Vector3.INF
			member.attention_node = node

func _clear_attention(entry: Dictionary) -> void:
	for member: Variant in entry.crew:
		if is_instance_valid(member) and "attention_point" in member:
			member.attention_point = Vector3.INF
			member.attention_node = null

func _finish(entry: Dictionary) -> void:
	# Freed crew is admitted to its next useful lease on the next tick.
	_refresh_clock = maxf(_refresh_clock, .25)
	_clear_storage_target(entry)
	UnloadingHold.clear(entry)
	_work_area_wait.erase(entry.job.id)
	completed[entry.job.id] = true
	if entry.job.kind in ["build","replace"]:
		_retry_reasons.erase(str(entry.job.id))
		_head_return_reasons.erase(str(entry.job.id))
	yard.release_job(entry.job)
	active_jobs.erase(entry.job.id)
	_clear_attention(entry)
	for w: Node in entry.crew:
		if not is_instance_valid(w): continue
		w.current_job_id = ""
		w.progress = 0.0
		w.needs = ""
		w.carry_partner = null
		w.brace_leader = null
		w.brace_load = null
		w.cargo_target = null
		w.cargo_staging = false
		w.pickup.clear()
		w.work_target = null
		w.access_support = null
		w.task_label_owner = true
		w.set_cargo(0.0)
		w.status_text = "Work complete"
		if entry.job.kind == "operate":
			w.station = entry.job.target
			# Keep the same live pedal through the job-to-duty handoff. Clearing
			# work_target for one tick made the free toe plant on the deck and
			# snap back when _tick_station restored the control on the next tick.
			w.work_target = w.station
			w.bind_station_support()
			w.status_text = "Manning " + str(entry.job.target.kind)
	# One lead owns the audible acknowledgement of this genuinely finished
	# shared job. All stock, contacts and scheduler transitions above precede it.
	if not entry.crew.is_empty() and is_instance_valid(entry.crew[0]) and entry.crew[0].personality:
		entry.crew[0].personality.work_completed(str(entry.job.kind),str(entry.job.id))

func _selected_head_return_target(job_id: String) -> Variant:
	# Read the original selected plan, not the ephemeral admission job list.
	# A paused build can still own its same unfinished native target.
	if not is_instance_valid(yard): return null
	var selected: Variant = yard.selected_assembly
	if not is_instance_valid(selected) or selected.is_queued_for_deletion() or not selected.is_inside_tree(): return null
	var kind := job_id.get_slice(":",0)
	var aid: int = selected.get_instance_id()
	if kind not in ["build","replace"] or int(job_id.get_slice(":",1)) != aid \
		or not yard._plans.has(aid) or yard._dismantling.has(aid): return null
	var part_id := job_id.get_slice(":",2)
	var target: Variant = selected.parts.get(part_id)
	if not is_instance_valid(target) or target.is_queued_for_deletion() or target.assembly != selected \
		or not yard._plans[aid].any(func(piece:Dictionary)->bool:return str(piece.get("id","")) == part_id): return null
	if kind == "build" and target.installed: return null
	if kind == "replace" and (not target.installed or target.health > 0.0): return null
	return target

func prior_head_return_reason(job_id: String) -> String:
	var saved: Dictionary = _head_return_reasons.get(job_id,{})
	var target: Variant = _selected_head_return_target(job_id)
	if saved.is_empty() or not is_instance_valid(target) or target.get_instance_id() != saved.target: return ""
	return str(saved.reason)

func _prune_head_return_feedback() -> void:
	# At most one carry-history entry per actual unfinished selected-plan part.
	# Later tool retries keep that history while current action/reason retains
	# its existing precedence. Admission retry clocks/reasons stay unchanged.
	for id: String in _head_return_reasons.keys():
		if prior_head_return_reason(id).is_empty(): _head_return_reasons.erase(id)
	for id: String in _retry_reasons.keys():
		if not id.begins_with("build:") and not id.begins_with("replace:"): continue
		var reason := str(_retry_reasons[id])
		if not reason.begins_with(HEAD_RETURN_FAILURE_PREFIX) or float(_retry_after.get(id,0.0)) > _clock: continue
		if not is_instance_valid(_selected_head_return_target(id)): _retry_reasons.erase(id)

func _cancel(entry: Dictionary, reason: String) -> void:
	var id: String = entry.job.id
	if not active_jobs.has(id): return
	_refresh_clock = maxf(_refresh_clock, .25)
	if reason == "Original work tool released; recover a compatible physical tool before continuing":
		var original_tool: Variant = entry.job.get("tool")
		if is_instance_valid(original_tool) and original_tool.get("definition") is Dictionary:
			reason = "Original work tool released (%s); recover and store it or a compatible working tool." % original_tool.definition.title
	if _field_work_debug:
		_trace_cancellation(entry,reason)
	UnloadingHold.clear(entry)
	_work_area_wait.erase(id)
	# Validate custody before an abort can release the actually staged source.
	var retain_stage: bool=yard.staged_job_valid(entry.job)
	for member: Node in entry.crew:
		if not retain_stage and is_instance_valid(member) and member.head_leap and (member.head_leap.active() or member.head_leap.part==entry.job.part and member.head_leap.contacted): member.head_leap.abort(reason)
	yard.perform_work(entry.job, float(entry.progress), "cancel", entry.crew)
	yard.release_job(entry.job)
	_clear_storage_target(entry)
	active_jobs.erase(id)
	_clear_attention(entry)
	_retry_after[id] = _clock + float(entry.get("retry_delay", 4.0))
	_retry_reasons[id] = reason
	if reason.begins_with(HEAD_RETURN_FAILURE_PREFIX):
		var selected_target: Variant = _selected_head_return_target(id)
		if is_instance_valid(selected_target) and selected_target == entry.job.target:
			_head_return_reasons[id] = {"target":selected_target.get_instance_id(),"reason":reason.trim_prefix(HEAD_RETURN_FAILURE_PREFIX)}
	for w: Variant in entry.crew:
		if not is_instance_valid(w): continue
		if entry.has("egress"): w.stop_navigation()
		w.current_job_id = ""
		w.progress = 0.0
		w.carry_partner = null
		w.brace_leader = null
		w.brace_load = null
		w.cargo_target = null
		w.cargo_staging = false
		w.pickup.clear()
		w.work_target = null
		w.access_support = null
		w.task_label_owner = true
		w.set_cargo(0.0)
		w.interrupt(reason)

func _trace_cancellation(entry: Dictionary, reason: String) -> void:
	if not is_instance_valid(yard) or not yard.is_inside_tree(): return
	var job: Dictionary = entry.job
	var source: Node3D = job.get("part")
	var target: Node3D = job.get("target")
	if (is_instance_valid(source) and not source.is_inside_tree()) or (is_instance_valid(target) and not target.is_inside_tree()): return
	var root: RigidBody3D = target.assembly.root_part() if is_instance_valid(target) and is_instance_valid(target.get("assembly")) else null
	if is_instance_valid(root) and not root.is_inside_tree(): root=null
	print("CONTRAPTION_FIELD_CANCEL id=",job.id," kind=",job.kind," phase=",entry.phase," reason=",reason,
		" elapsed=",entry.elapsed," progress=",entry.progress," retry=",entry.get("retry_delay",4.0),
		" source=",source.part_id if is_instance_valid(source) else "removed",
		" source_pose=",source.global_transform if is_instance_valid(source) else null,
		" target=",target.get("part_id") if is_instance_valid(target) and target.get("part_id") != null else (target.name if is_instance_valid(target) else "removed"),
		" target_pose=",target.global_transform if is_instance_valid(target) else null,
		" root_pose=",root.global_transform if is_instance_valid(root) else null,
		" root_velocity=",root.linear_velocity if is_instance_valid(root) else null,
		" root_angular=",root.angular_velocity if is_instance_valid(root) else null,
		" local_point=",entry.get("local_point")," hold=",entry.get("unloading_held",false),
		" hold_elapsed=",entry.get("unloading_hold_elapsed",0.0))
	var stage_receipt: bool=str(job.kind) in ["build","replace"] and str(entry.phase)=="staging"
	if stage_receipt and source is RigidBody3D and is_instance_valid(target):
		# The existing debug cancellation event observes the exact unchanged
		# arrival/support predicates before abort releases the same stock.
		var source_native:=PhysicsServer3D.body_get_direct_state(source.get_rid())
		print("CONTRAPTION_FIELD_CANCEL_STAGE id=",job.id," source_id=",source.part_id,
			" source_instance=",source.get_instance_id()," source_rid=",source.get_rid(),
			" source_scale=",source.global_basis.get_scale()," source_carrier=",source.carrier,
			" source_target_position_error=",source.global_position.distance_to(target.global_position),
			" source_target_angle_error=",source.global_basis.get_rotation_quaternion().angle_to(target.global_basis.get_rotation_quaternion()),
			" source_native_available=",source_native!=null,
			" source_native_pose=",source_native.transform if source_native else null,
			" source_native_position_error=",source_native.transform.origin.distance_to(source.global_position) if source_native else -1.0,
			" source_native_basis_matches=",source_native.transform.basis.is_equal_approx(source.global_basis) if source_native else false,
			" arrival_pending=",entry.get("arrival_pending",false)," staged=",entry.get("staged",false))
	for member: Node in entry.crew:
		if not is_instance_valid(member) or not member.is_inside_tree(): continue
		var point: Vector3 = member.work_point() if is_instance_valid(member.work_target) else Vector3.INF
		var tip: Vector3 = member.foot_grip_transform.origin+member.foot_grip_transform.basis.y.normalized()*(.035+member.foot_tool_span())
		print("CONTRAPTION_FIELD_CANCEL_CREW id=",member.worker_id," native=",member.global_transform,
			" navigation=",member.has_target," destination=",member.target_position," ground=",member.on_ground,
			" support=",member._ground_body," action=",member.action," action_progress=",member.action_progress,
			" work=",point," hip=",member._pose.evaluated_hips[member.work_foot_side] if member._pose.evaluated_valid else Vector3.INF,
			" tip=",tip," contact=",member.foot_contact_ready()," tool_blocked=",member.tool_pose_blocked)
		if stage_receipt:
			var held_tool: Variant=member.equipped_tool
			print("CONTRAPTION_FIELD_CANCEL_STAGE_CREW id=",member.worker_id," pose_valid=",member._pose.evaluated_valid,
				" grounded=",member._pose.evaluated_grounded," soles=",member._pose.evaluated_soles,
				" terrain=",member._pose._terrain_points," original_leg_span=",[member._leg_span(0),member._leg_span(1)],
				" action_time=",member._action_time," action_length=",member._action_length,
				" cargo_staging=",member.cargo_staging," cargo_stage_finish=",member._cargo_stage_body_finish,
				" captured_finish_current_target_gap=",member._cargo_stage_body_finish.origin.distance_to(target.global_position) if is_instance_valid(target) else -1.0,
				" captured_finish_current_target_angle=",member._cargo_stage_body_finish.basis.get_rotation_quaternion().angle_to(target.global_basis.get_rotation_quaternion()) if is_instance_valid(target) else -1.0,
				" actual_tool=",held_tool.part_id if is_instance_valid(held_tool) else "none",
				" actual_tool_carrier=",str(held_tool.carrier) if is_instance_valid(held_tool) else "none",
				" back_phase=",member.back_tool.phase if member.back_tool else "none")

func cancel_all(reason := "Saved assignments are being restored") -> void:
	for id: String in active_jobs.keys():
		if active_jobs.has(id): _cancel(active_jobs[id], reason)
	_retry_after.clear()
	_retry_reasons.clear()
	if reason != "Work paused; cargo returned safely": _head_return_reasons.clear()
	_work_area_wait.clear()

func cancel_targets(targets: Array, resource_ids: Array[String], reason := "Construction placement cancelled; stock recovered", kinds: Array[String] = []) -> void:
	for id: String in _head_return_reasons.keys():
		var target_id: int = int(_head_return_reasons[id].target)
		if (kinds.is_empty() or kinds.has(id.get_slice(":", 0))) and targets.any(func(target:Variant)->bool:return is_instance_valid(target) and target.get_instance_id() == target_id):
			_head_return_reasons.erase(id)
	for id: String in active_jobs.keys():
		if active_jobs.has(id) and targets.has(active_jobs[id].job.target) \
			and (kinds.is_empty() or kinds.has(String(active_jobs[id].job.kind))):
			_cancel(active_jobs[id], reason)
			_retry_reasons.erase(id)
	for job: Dictionary in _jobs:
		if targets.has(job.get("target")) and (kinds.is_empty() or kinds.has(String(job.kind))): _retry_reasons.erase(str(job.id))
	# Loaded jobs resolve through resource identities rather than yesterday's
	# runtime Nodes. Discard progress only for the cancelled staged stock.
	_pending_resume = _pending_resume.filter(func(saved: Dictionary) -> bool: return not resource_ids.has(str(saved.get("part_id", ""))) or not kinds.is_empty() and not kinds.has(String(saved.get("kind", ""))))

func interrupt_worker(worker: Node, reason: String) -> void:
	_routes.erase(worker.get_instance_id())
	_leave_station(worker)
	for id: String in active_jobs.keys():
		if active_jobs.has(id) and active_jobs[id].crew.has(worker): _cancel(active_jobs[id], reason)
	if is_instance_valid(worker.equipped_tool):
		var tool: Node3D = worker.equipped_tool
		worker.set_equipped_tool(null)
		yard._abandon_worker_tool(tool)
	worker.needs = reason
	worker.status_text = reason

func _on_worker_removed(worker: Node) -> void:
	_depot_tool_admission_until.erase(worker.get_instance_id())
	_depot_tool_admission_cursor.erase(worker.get_instance_id())
	_routes.erase(worker.get_instance_id())
	_field_routes.erase(worker.get_instance_id())
	_leave_station(worker)
	if is_instance_valid(worker.equipped_tool): yard._abandon_worker_tool.call_deferred(worker.equipped_tool)
	for id: String in active_jobs.keys():
		if active_jobs.has(id) and active_jobs[id].crew.has(worker): _cancel(active_jobs[id], "Carrier unavailable; finding another crew")
	workers.erase(worker)

func _leave_station(worker: Node) -> void:
	if is_instance_valid(worker.station):
		if str(worker.station.parameters.get("operator", "")) == worker.worker_id:
			worker.station.parameters.erase("operator")
	worker.station = null
	worker.station_support = null
	worker.station_reacquire_time = 0.0
	worker.work_target = null
	worker.stop_navigation()

func _tick_station(worker: Node, delta := 1.0 / 120.0) -> void:
	if not worker.is_available(): return
	if not is_instance_valid(worker.station): return
	var station: Node3D = worker.station
	if FieldWorksite.active(yard):
		var field_reason: String = yard.job_service_reason({"kind":"operate","part":station,"target":station})
		if not FieldWorksite.eligible(yard,worker) or not field_reason.is_empty():
			_leave_station(worker)
			worker.needs=field_reason if not field_reason.is_empty() else "The helper left its assigned field worksite"
			return
	worker.work_target = station
	worker.work_foot_side = worker.control_foot_side()
	if station.is_queued_for_deletion() or not station.installed or station.health <= 0.0 or worker.paused or yard.work_paused:
		_leave_station(worker)
		return
	worker.station_reacquire_time = maxf(worker.station_reacquire_time - delta, 0.0)
	if worker.station_reacquire_time > 0.0 and not worker.on_ground:
		station.parameters.erase("operator")
		worker.status_text = "Regaining station footing"
		return
	var onboard: bool = worker.supported_by(station.assembly)
	if onboard and not is_instance_valid(worker.station_support): worker.bind_station_support()
	if not onboard and (is_instance_valid(worker.station_support) or station.linear_velocity.length() > .25):
		_leave_station(worker)
		worker.interrupt("Lost station footing; provide a safe boarding route")
		return
	if not worker.can_reach_work() and worker.station_reacquire_time > 0.0 and onboard:
		station.parameters.erase("operator")
		var standing := _station_work_position(worker, station)
		if not standing.is_empty(): worker.navigate_to(standing.point)
		worker.face_point(station.global_position)
		worker.status_text = "Regaining pedal position"
		return
	if not worker.can_reach_work():
		_leave_station(worker)
		worker.interrupt("Lost pedal footing; provide a work platform/access")
		return
	var protected_gun: bool = station.kind == "gun" and station.health > 0.0 and onboard
	if (yard.unsafe_at(worker.global_position) and not protected_gun) or worker.fear_time > 0.0:
		_leave_station(worker)
		worker.interrupt("Station unsafe; taking cover")
		return
	var job := {"kind": "operate", "part": station, "target": station}
	var reached := false
	if onboard and is_instance_valid(worker.station_support):
		worker.navigate_to(worker.station_support.to_global(worker.station_support_local))
		reached = worker.at_target(.5)
	else: reached = _navigate(worker, _work_position(job, station, false), .3)
	worker.face_point(worker.global_position - station.global_basis.z)
	worker.status_text = "Manning gun station" if protected_gun else "Operating utility station"
	worker.needs = ""
	if float(station.definition.power) > 0.0 and not station.assembly.has_power(station):
		worker.status_text = "Station waiting for power"
		worker.needs = station.assembly.power_reason(station)
	if reached: station.parameters.operator = worker.worker_id
	else: station.parameters.erase("operator")
	if reached and worker.action.is_empty():
		if not worker.can_reach_work():
			_leave_station(worker)
			worker.interrupt("Connector out of reach; provide a work platform/access")
		else: worker.begin_action("operate")

func serialize_state() -> Dictionary:
	var jobs: Array = []
	for entry: Dictionary in active_jobs.values():
		if not _nodes_valid(entry.job): continue
		if entry.job.kind == "prepare" and entry.get("complete", false): continue # The complete split publishes both bodies before the lease closes.
		var saved := {"kind": entry.job.kind, "part_id": entry.job.part.part_id, "target_id": str(entry.job.target.get("part_id")),
			"progress": entry.progress, "phase": entry.phase, "workers": entry.crew.map(func(w: Node) -> String: return w.worker_id)}
		if entry.job.kind == "prepare":
			saved.placement_id = entry.job.placement.part_id
			saved.placement_assembly = yard.assemblies.find(entry.job.placement.assembly)
			saved.parameters = entry.job.parameters.duplicate(true)
			saved.source_parameters = entry.job.part.parameters.duplicate(true)
			saved.source_capacity = entry.job.part.definition.health
			saved.source_mass = entry.job.part.mass
			saved.source_health = entry.job.part.health
			saved.source_wear = entry.job.part.wear
			saved.source_jammed = entry.job.part.jammed
			var cut: Vector3 = entry.job.part.to_local(BeamPreparation.point(entry.job, entry.job.part))
			saved.cut_local = [cut.x, cut.y, cut.z]
		if entry.get("unloading_held",false):
			saved.unloading_hold = {"elapsed":entry.unloading_hold_elapsed,"phase":entry.unloading_hold_phase,
				"actions":entry.unloading_hold_actions.duplicate(true)}
		jobs.append(saved)
	return {"jobs": jobs, "completed": completed.keys()}

func restore_state(data: Dictionary) -> void:
	cancel_all()
	_field_routes.clear()
	_pending_resume = data.get("jobs", []).duplicate(true)
	# Node/assembly instance IDs change after load. Physical resources and worker IDs resolve fresh reservations.
	completed.clear()
	for id: Variant in data.get("completed", []): completed[str(id)] = true
	for w: Node in workers:
		w.current_job_id = ""
		w.status_text = "Resuming automatic work"
		if not w.saved_station_id.is_empty():
			var saved_assemblies: Array = yard.assemblies
			if w.saved_station_assembly >= 0 and w.saved_station_assembly < yard.assemblies.size():
				saved_assemblies = [yard.assemblies[w.saved_station_assembly]]
			for a: Node in saved_assemblies:
				if a.parts.has(w.saved_station_id):
					var part: Node3D = a.parts[w.saved_station_id]
					if part.kind in ["gun", "station"]:
						w.station = part
						w.station_support = a.parts.get(w.saved_station_support_id) if not w.saved_station_support_id.is_empty() else null
						part.parameters.operator = w.worker_id
						break
			w.saved_station_id = ""
	refresh_jobs()

func _saved_job_matches(job: Dictionary, saved: Dictionary) -> bool:
	if str(saved.get("kind", "")) != str(job.kind) or str(saved.get("part_id", "")) != str(job.part.part_id): return false
	return BeamPreparation.resume_matches(yard, job, saved) if job.kind == "prepare" else true

func _resume_progress(job: Dictionary) -> float:
	for i in _pending_resume.size():
		var saved: Dictionary = _pending_resume[i]
		if _saved_job_matches(job, saved):
			_pending_resume.remove_at(i)
			return clampf(float(saved.get("progress", 0.0)), 0.0, .95)
	if yard.staged_job_valid(job):
		return clampf(float(job.part.get_meta(&"staged_work_progress",0.0)),0.0,.95)
	return 0.0

func _hold_supported_tool_return(entry: Dictionary) -> bool:
	if entry.get("phase","") not in ["inspect","work"] or entry.crew.is_empty(): return false
	var worker: Node=entry.crew[0]
	var pending: bool=worker.back_tool and worker.back_tool.supported_foot_return_pending()
	# A currently safe retained frame has no motion controller of its own.
	# Only an actual Back transfer/recovery pauses the work animation; otherwise
	# the ordinary envelope must advance to its still-required real toe contact.
	if pending and (worker.back_tool.busy() or worker.back_tool.recovering()):
		entry.tool_return_pending=true
		worker.set_work_action_held(true)
		worker.status_text="Recovering the supported original tool before foot contact"
		return true
	if entry.get("tool_return_pending",false):
		entry.erase("tool_return_pending")
		worker.set_work_action_held(false)
	return false


func _record_source_budget(label: String, started_usec: int) -> void:
	var elapsed_usec := Time.get_ticks_usec()-started_usec
	var row: Dictionary = source_budget.get(label,{"calls":0,"total_usec":0,"max_usec":0,"last_usec":0,"last_tick":0,"last_frame":0,"max_tick":0,"max_frame":0})
	row.calls += 1
	row.total_usec += elapsed_usec
	if elapsed_usec > int(row.max_usec):
		row.max_usec = elapsed_usec
		row.max_tick = Engine.get_physics_frames()
		row.max_frame = Engine.get_process_frames()
	row.last_usec = elapsed_usec
	row.last_tick = Engine.get_physics_frames()
	row.last_frame = Engine.get_process_frames()
	source_budget[label] = row

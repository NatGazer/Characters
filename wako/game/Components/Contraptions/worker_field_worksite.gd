extends RefCounted
## Idle crew and height observations for one explicitly selected native worksite.
## The canonical yard, physical helpers and finite stock retain their owners.

const Egress := preload("res://Components/Contraptions/worker_ramp_egress.gd")

static func active(yard: Node3D) -> bool:
	return yard.has_method("worksite_active") and yard.worksite_active()

static func eligible(yard: Node3D, worker: Node) -> bool:
	return not active(yard) or yard.worksite_worker(worker)

static func ground_y(yard: Node3D, assembly: Node3D) -> float:
	return float(yard.construction_ground_y(assembly)) if yard.has_method("construction_ground_y") else yard.global_position.y

static func parking_position(yard: Node3D, worker: Node3D) -> Vector3:
	# An invalid selected worksite must hold its crew, never fall back to a
	# distant depot just because the original container temporarily disappeared.
	var parking: Dictionary = yard.worksite_parking(worker)
	return parking.point if parking.has("point") and Vector3(parking.point).is_finite() else worker.global_position

static func _hold(worker: Node3D, reason: String) -> void:
	worker.stop_navigation()
	worker.safe_position = worker.global_position
	worker.needs = reason
	worker.status_text = reason if not reason.is_empty() else "Watching for field salvage and maintenance"

static func tick_idle(yard: Node3D, worker: RigidBody3D, routes: Dictionary, clock: float, blocked: Dictionary) -> bool:
	if not active(yard): return false
	var water_play: RefCounted = worker.get("idle_play")
	if water_play and water_play.water_navigation_claim(): return true
	var key := worker.get_instance_id()
	var context: Dictionary = yard.worksite_context()
	if context.has("reason") or not eligible(yard,worker):
		routes.erase(key)
		_hold(worker,str(context.get("reason","The helper is outside its assigned field worksite")))
		return true
	# A helper already supported by a real machine can wait there. Idle parking
	# does not invent a descent or replace the qualified service-egress lease.
	var support: RigidBody3D = worker._ground_body
	if is_instance_valid(support) and is_instance_valid(support.get("assembly")) and yard.assemblies.has(support.assembly) and worker.supported_by(support.assembly):
		routes.erase(key)
		_hold(worker,"Waiting on the supported field deck")
		return true
	if not worker.on_ground:
		routes.erase(key)
		_hold(worker,"Regaining field footing")
		return true
	var parking: Dictionary = yard.worksite_parking(worker)
	if not parking.has("point") or not Vector3(parking.point).is_finite():
		routes.erase(key)
		_hold(worker,str(parking.get("reason","Clear a supported field waiting place")))
		return true
	var goal: Vector3 = parking.point-Vector3.UP*worker.ride_height
	worker.safe_position = parking.point
	var route: Dictionary = routes.get(key,{})
	if route.is_empty() or clock >= float(route.until) or goal.distance_to(route.goal)>.05:
		var from: Vector3 = worker._ground_point
		var machine: Node3D = context.anchor.assembly
		var planned: Array = yard.coordinator._plan_route(from,goal,false,machine,goal.y)
		var ordinary: Array[Vector3] = [from]
		ordinary.append_array(planned)
		var sampled: Array[Vector3] = []
		for proposal: Array in [ordinary,[from,Vector3(goal.x,from.y,from.z),goal],[from,Vector3(from.x,goal.y,goal.z),goal]]:
			var points: Array[Vector3] = []
			points.assign(proposal)
			if points.any(func(point: Vector3) -> bool: return point.distance_to(context.anchor.global_position)>65): continue
			sampled = Egress.static_ground_path(worker,machine,points)
			if not sampled.is_empty() and (sampled[-1]-goal).slide(Vector3.UP).length()<=.12: break
			sampled.clear()
		route = {"points":sampled,"goal":goal,"until":clock+.6}
		routes[key]=route
	var points: Array[Vector3] = route.points
	if points.is_empty():
		_hold(worker,"Clear a supported ground route to the field waiting place")
		return true
	while points.size()>1 and (points[0]-worker._ground_point).slide(Vector3.UP).length()<.22:
		points.pop_front()
	worker.navigate_to(points[0])
	if points.size()==1 and worker.at_target(.3): worker.stop_navigation()
	worker.needs = str(blocked.values()[0]) if not blocked.is_empty() else ""
	worker.status_text = worker.needs if not worker.needs.is_empty() else "Watching for field salvage and maintenance"
	if yard.unsafe_at(worker.global_position) or worker.fear_time>0.0: worker.status_text="Taking cover near the field container"
	return true

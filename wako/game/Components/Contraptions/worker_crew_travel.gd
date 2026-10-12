extends RefCounted
## Scheduler adapter for the Yard-owned original-crew travel observation.
## Travel itself proves and drives native walking; this only keeps leases and
## depot/field idle parking from overwriting that explicitly selected route.

static func assigned(yard: Node3D, worker: Node) -> bool:
	return (yard.has_method("worker_follow_active") and yard.worker_follow_active(worker)) or (yard.has_method("crew_travel_active") and yard.crew_travel_active() and yard.crew_travel_worker(worker))

static func eligible(yard: Node3D, worker: Node) -> bool:
	return not assigned(yard,worker)

static func parking_position(yard: Node3D, worker: Node3D) -> Vector3:
	if yard.has_method("worker_follow_active") and yard.worker_follow_active(worker):
		return yard.worker_follow_parking(worker).get("point", worker.global_position)
	var parking: Dictionary=yard.crew_travel_parking(worker)
	var point: Variant=parking.get("point")
	return point if point is Vector3 and point.is_finite() else worker.global_position

static func tick_idle(yard: Node3D, worker: RigidBody3D) -> bool:
	if not assigned(yard,worker): return false
	if yard.has_method("worker_follow_active") and yard.worker_follow_active(worker): return yard.worker_follow_idle(worker)
	var water_play: RefCounted = worker.get("idle_play")
	if water_play and water_play.water_navigation_claim(): return true
	# Keep ordinary danger/fear handling ahead of field parking and the travel
	# controller. Its only retreat anchor is a freshly supported local checkpoint.
	if yard.unsafe_at(worker.global_position) or worker.fear_time>0:
		var parking: Dictionary=yard.crew_travel_parking(worker)
		var point: Variant=parking.get("point")
		worker.status_text="Taking cover near the crew route"
		worker.needs=str(parking.get("reason",""))
		worker.safe_position=point if point is Vector3 and point.is_finite() else worker.global_position
		if point is Vector3 and point.is_finite(): worker.navigate_to(point-Vector3.UP*worker.ride_height)
		else: worker.stop_navigation()
		return true
	if yard.crew_travel_idle(worker): return true
	# Invalid/cancelled travel still owns its assigned original crew until an
	# explicit valid rendezvous or real depot return releases that assignment.
	worker.stop_navigation()
	worker.safe_position=parking_position(yard,worker)
	var context: Dictionary=yard.crew_travel_context()
	worker.needs=str(context.get("reason","Hold at the supported crew route checkpoint"))
	worker.status_text=worker.needs
	return true

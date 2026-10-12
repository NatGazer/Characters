extends RefCounted
## A finite descent over an existing stopped ramp, followed by real static ground.
## Uses the same native support, capsule, load, slope and height checks as boarding.

const Access := preload("res://Components/Contraptions/worker_access.gd")
const Catalogue := preload("res://Components/Contraptions/part_catalog.gd")

static func boarding_ground_route(worker: RigidBody3D, machine: Node3D, boarding: Dictionary) -> Array[Vector3]:
	# Reach the ramp's low end along the ground outside its raised side edges.
	# The capsule can clear an edge while the swinging sole still reaches it.
	var from: Vector3 = worker._ground_point
	var low: Vector3 = boarding.points[0]
	var outward: Vector3 = (low-boarding.points[1]).slide(Vector3.UP).normalized()
	var bounds: AABB = boarding.ramp.global_transform*Catalogue.bounds_of(boarding.ramp.definition)
	for distance: float in [.85,1.15]:
		var entrance := low+outward*distance
		var ray := PhysicsRayQueryParameters3D.create(entrance+Vector3.UP*(worker.ride_height+.12),entrance-Vector3.UP*.6,1,worker.query_exclusions())
		var hit := worker.get_world_3d().direct_space_state.intersect_ray(ray)
		if hit.is_empty(): continue
		entrance=hit.position
		if not _static_landing(worker,entrance): continue
		var outside: Array[float] = [bounds.position.x-.85,bounds.end.x+.85]
		outside.sort_custom(func(a:float,b:float)->bool:return absf(a-from.x)<absf(b-from.x))
		for x: float in outside:
			var first := Vector3(x,from.y,from.z)
			var last := Vector3(x,entrance.y,entrance.z)
			if not _static_landing(worker,first) or not _static_landing(worker,last): continue
			var points := static_ground_path(worker,machine,[from,first,last,entrance])
			if not points.is_empty(): return points
	return []

static func _static_landing(worker: RigidBody3D, point: Vector3) -> bool:
	# Leave space for both resting soles and the .22 m waypoint arrival band.
	# A ground-supported capsule alone can still curl a heel onto the ramp toe.
	for x: float in [-.65,0.0,.65]:
		for z: float in [-.65,0.0,.65]:
			var at := point+Vector3(x,0,z)
			var ray := PhysicsRayQueryParameters3D.create(at+Vector3.UP*(worker.ride_height+.12),at-Vector3.UP*.3,1,worker.query_exclusions())
			var hit := worker.get_world_3d().direct_space_state.intersect_ray(ray)
			if hit.is_empty() or hit.normal.y<.8 or absf(hit.position.y-point.y)>.16 or not hit.rid.is_valid() or PhysicsServer3D.body_get_mode(hit.rid)!=PhysicsServer3D.BODY_MODE_STATIC:
				if "--egress-debug" in OS.get_cmdline_user_args(): print("EGRESS_QUERY landing=",point," sample=",at," hit=",hit)
				return false
	return true

static func on_static_ground(worker: RigidBody3D, machine: Node3D) -> bool:
	if not worker.on_ground or worker.supported_by(machine): return false
	var point: Vector3 = worker._ground_point
	var ray := PhysicsRayQueryParameters3D.create(point + Vector3.UP * (worker.ride_height + .12), point - Vector3.UP * .3, 1, worker.query_exclusions())
	var hit := worker.get_world_3d().direct_space_state.intersect_ray(ray)
	return not hit.is_empty() and hit.normal.y >= .8 and absf(hit.position.y - point.y) <= .16 and hit.rid.is_valid() and PhysicsServer3D.body_get_mode(hit.rid) == PhysicsServer3D.BODY_MODE_STATIC

static func ground_service_route(worker: RigidBody3D, target: RigidBody3D, service_job: Dictionary = {}) -> Dictionary:
	# The ordinary exterior router may cut diagonally across the ramp toe. A
	# helper that has just left it needs a real ground aisle, not another boarding.
	if not is_instance_valid(target.assembly) or not on_static_ground(worker,target.assembly) or not is_instance_valid(worker.coordinator): return {}
	if not target.service_safety_reason().is_empty() or Access.work_surface_velocity(worker,target).length()>.25: return {}
	var root: RigidBody3D = target.assembly.root_part()
	if not root or root.linear_velocity.length()>.25 or root.angular_velocity.length()>.1: return {}
	var from: Vector3 = worker._ground_point
	var job: Dictionary = service_job.duplicate() if not service_job.is_empty() else {"kind":"maintenance","part":target,"target":target}
	job.tool=worker.equipped_tool
	var goals: Array[Vector3] = [worker.coordinator._work_position(job,target,false)]
	goals.append_array(Access.local_stances(worker,target))
	for goal: Vector3 in goals:
		if from.distance_to(goal)>12.0 or not Access._reachable(worker,target,goal,.12): continue
		var planned: Array = worker.coordinator._plan_route(from,goal,false,target.assembly,goal.y)
		var ordinary: Array[Vector3] = [from]
		ordinary.append_array(planned)
		for proposal: Array in [ordinary,[from,Vector3(goal.x,from.y,from.z),goal],[from,Vector3(from.x,goal.y,goal.z),goal]]:
			var points: Array[Vector3] = []
			points.assign(proposal)
			var sampled := static_ground_path(worker,target.assembly,points)
			if not sampled.is_empty() and (sampled[-1]-goal).slide(Vector3.UP).length()<=.12 and Access._reachable(worker,target,sampled[-1],.12):
				return {"point":sampled[-1],"points":sampled}
	return {}

static func static_ground_path(worker: RigidBody3D, machine: Node3D, points: Array[Vector3]) -> Array[Vector3]:
	var sampled := Access.ground_path(worker,machine,points)
	if sampled.is_empty() and "--egress-debug" in OS.get_cmdline_user_args():
		print("EGRESS_QUERY native_ground_empty points=",points)
		var capsule := CapsuleShape3D.new()
		capsule.radius=.31
		capsule.height=1.05
		var exclude: Array[RID] = worker.query_exclusions()
		for peer: RigidBody3D in worker.coordinator.workers:
			if peer!=worker: exclude.append(peer.get_rid())
		for segment in points.size()-1:
			var length: float = points[segment].distance_to(points[segment+1])
			var steps := maxi(ceili(length/.18),1)
			for step in steps+1:
				var at: Vector3 = points[segment].lerp(points[segment+1],float(step)/steps)
				var ray := PhysicsRayQueryParameters3D.create(at+Vector3.UP*(worker.ride_height+.12),at-Vector3.UP*.3,1,exclude)
				var hit := worker.get_world_3d().direct_space_state.intersect_ray(ray)
				if hit.is_empty() or hit.normal.y<.8 or absf(hit.position.y-at.y)>.16:
					print("EGRESS_QUERY first_ground_failure=",at," hit=",hit)
					return []
				var clearance := PhysicsShapeQueryParameters3D.new()
				clearance.shape=capsule
				clearance.transform.origin=hit.position+Vector3.UP*(worker.ride_height+.2)
				clearance.collision_mask=1
				clearance.exclude=exclude
				var bodies := worker.get_world_3d().direct_space_state.intersect_shape(clearance,1)
				if not bodies.is_empty():
					print("EGRESS_QUERY first_body_failure=",at," body=",bodies)
					return []
	for point: Vector3 in sampled:
		var ray := PhysicsRayQueryParameters3D.create(point+Vector3.UP*(worker.ride_height+.12),point-Vector3.UP*.3,1,worker.query_exclusions())
		var hit := worker.get_world_3d().direct_space_state.intersect_ray(ray)
		if hit.is_empty() or not hit.rid.is_valid() or PhysicsServer3D.body_get_mode(hit.rid)!=PhysicsServer3D.BODY_MODE_STATIC: return []
	return sampled

static func motion_reason(path: Dictionary) -> String:
	var ramp: RigidBody3D = path.get("ramp")
	var machine: Node3D = path.get("machine")
	if not is_instance_valid(ramp) or not is_instance_valid(machine) or ramp.assembly!=machine or not ramp.installed or ramp.health < 20:
		return "Secure a working ramp before leaving the work platform"
	var root: RigidBody3D = machine.root_part()
	if ramp.linear_velocity.length() > .25 or ramp.angular_velocity.length() > .1 or not root or root.linear_velocity.length() > .25 or root.angular_velocity.length() > .1:
		return "Stop the machine before leaving its work platform"
	if path.has("transform"):
		var original: Transform3D = path.transform
		if ramp.global_position.distance_to(original.origin) > .05 or ramp.global_basis.get_rotation_quaternion().angle_to(original.basis.get_rotation_quaternion()) > .02:
			return "Ramp moved; check the supported descent again"
	return ""

static func plan(worker: RigidBody3D, machine: Node3D) -> Dictionary:
	if not is_instance_valid(machine) or not worker.supported_by(machine): return {}
	var from: Vector3 = worker._ground_point
	var nearest := INF
	var result := {}
	for ramp: RigidBody3D in machine.parts.values():
		if ramp.kind != "access_ramp" or float(ramp.definition.get("walk_width", 0.0)) < .9: continue
		var path := {"machine": machine, "ramp": ramp}
		if not motion_reason(path).is_empty():
			if "--egress-debug" in OS.get_cmdline_user_args(): print("EGRESS_QUERY rejected=motion reason=",motion_reason(path)," ramp_velocity=",ramp.linear_velocity," spin=",ramp.angular_velocity)
			continue
		var points: Array[Vector3] = []
		var authored: Array = ramp.parameters.get("access_points", [])
		if authored.is_empty():
			var half: Vector3 = ramp.definition.size * .5
			points = [ramp.to_global(Vector3(0, half.y + .025, half.z - .08)), ramp.to_global(Vector3(0, half.y + .025, -half.z + .08))]
		else:
			for point: Array in authored: points.append(ramp.to_global(Vector3(point[0], point[1], point[2])))
		if points.size() < 2: continue
		if points[0].y < points[-1].y: points.reverse()
		var exclude: Array[RID] = worker.query_exclusions()
		if is_instance_valid(worker.coordinator):
			for peer: RigidBody3D in worker.coordinator.workers:
				if peer != worker: exclude.append(peer.get_rid())
		var descent := Access._sample_path(worker, machine, points, exclude, float(ramp.definition.get("max_slope", 32.0)), 1)
		if descent.is_empty():
			if "--egress-debug" in OS.get_cmdline_user_args():
				print("EGRESS_QUERY rejected=ramp_support points=",points," ground_allowed=",Access.ground_path(worker,machine,points).size())
				for point: Vector3 in points:
					var ray := PhysicsRayQueryParameters3D.create(point+Vector3.UP*(worker.ride_height+.12),point-Vector3.UP*.3,1,exclude)
					var hit := worker.get_world_3d().direct_space_state.intersect_ray(ray)
					print("EGRESS_QUERY ramp_point=",point," hit=",hit)
			continue
		# Resuming an interrupted descent need not walk back up the ramp. Trim
		# only when the actual native support is this ramp and its sampled centre
		# is nearby; the approach and every retained segment still pass below.
		if worker._ground_body == ramp:
			var index := 0
			var closest := from.distance_squared_to(descent[0])
			for sample in descent.size():
				var distance := from.distance_squared_to(descent[sample])
				if distance < closest: index = sample; closest = distance
			if closest < .16 and index < descent.size() - 1:
				var remainder: Array[Vector3] = []
				for sample in range(index, descent.size()): remainder.append(descent[sample])
				descent = remainder
		var upper: Vector3 = descent[0]
		var approaches: Array = [[from, upper], [from, Vector3(upper.x, from.y, from.z), upper], [from, Vector3(from.x, from.y, upper.z), upper]]
		var detours := 0
		for housing: RigidBody3D in machine.parts.values():
			if not housing.installed or housing.kind not in ["station", "gun"] or housing.global_position.distance_to(from) > 5: continue
			var bounds: AABB = housing.global_transform * Catalogue.bounds_of(housing.definition)
			for x: float in [bounds.position.x - .55, bounds.end.x + .55]:
				var rear := Vector3(x, from.y, bounds.end.z + .55)
				var front := Vector3(x, from.y, bounds.position.z - .55)
				approaches.append_array([[from, rear, front, upper], [from, front, rear, upper]])
			detours += 1
			if detours >= 4: break
		var approach: Array[Vector3] = []
		for proposal: Array in approaches:
			var candidate: Array[Vector3] = []
			candidate.assign(proposal)
			if from.distance_to(upper) > 6: continue
			approach = Access.ground_path(worker, machine, candidate)
			if not approach.is_empty(): break
		if approach.is_empty():
			if "--egress-debug" in OS.get_cmdline_user_args(): print("EGRESS_QUERY rejected=deck_approach from=",from," upper=",upper)
			continue
		var low: Vector3 = descent[-1]
		var outward := (low - descent[-2]).slide(Vector3.UP).normalized()
		if outward.length_squared() < .01: continue
		for distance: float in [.4, .6, .85, 1.15]:
			var destination := low + outward * distance
			var ray := PhysicsRayQueryParameters3D.create(destination + Vector3.UP * (worker.ride_height + .12), destination - Vector3.UP * .6, 1, exclude)
			var hit := worker.get_world_3d().direct_space_state.intersect_ray(ray)
			if hit.is_empty() or hit.normal.y < .8 or hit.collider.get("assembly") != null:
				if "--egress-debug" in OS.get_cmdline_user_args(): print("EGRESS_QUERY rejected=ground_hit distance=",distance," hit=",hit)
				continue
			if not hit.rid.is_valid() or PhysicsServer3D.body_get_mode(hit.rid) != PhysicsServer3D.BODY_MODE_STATIC: continue
			destination = hit.position
			if not _static_landing(worker,destination):
				if "--egress-debug" in OS.get_cmdline_user_args(): print("EGRESS_QUERY rejected=ground_footprint destination=",destination)
				continue
			var continuation := Access.ground_path(worker, machine, [low, destination])
			if continuation.is_empty():
				if "--egress-debug" in OS.get_cmdline_user_args(): print("EGRESS_QUERY rejected=ground_continuation low=",low," ground=",destination)
				continue
			var length := from.distance_squared_to(upper)
			if length >= nearest: continue
			nearest = length
			var full: Array[Vector3] = []
			full.append_array(approach)
			full.append_array(descent)
			full.append_array(continuation)
			result = {"machine": machine, "ramp": ramp, "points": full, "ground": destination, "transform": ramp.global_transform}
	return result

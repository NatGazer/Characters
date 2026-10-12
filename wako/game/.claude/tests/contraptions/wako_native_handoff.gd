## Actual original Wako impacts, final visible bones and both native/procedural seams.
extends Node3D
const Worker = preload("res://LogicObjects/Wako/Wako.tscn")
const FinalObserver = preload("res://.claude/tests/contraptions/wako_native_handoff_observer.gd")
var worker: RigidBody3D
var failures := 0
var previous := {}
var handoffs := {}
var native_samples := 0
var native_position_error := 0.0
var native_rotation_error := 0.0
var return_samples := 0
var return_tail := 0
var minimum_sole := INF
var minima := {"ordinary":INF,"native":INF,"return":INF}
var return_steps := {"samples":0,"root":0.0,"angle":0.0,"sole":0.0,"knee":0.0,"ankle":0.0}

func _ready() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition: failures+=1
	print("CONTRAPTION ","ok " if condition else "FAIL ",message)

func capture_final(helper: Node) -> void:
	if helper!=worker: return
	var sk: Skeleton3D = worker._skeleton
	if worker.ragdoll.visual.is_returning(): return_tail=2
	var root: Transform3D = sk.global_transform*sk.get_bone_global_pose(0)
	var soles: Array[Vector3] = []
	var knees: Array[Vector3] = []
	var ankles: Array[Quaternion] = []
	for side in 2:
		var chain: Array = worker._pose._chains[side]
		var foot: Transform3D = sk.get_bone_global_pose(chain[2])
		var sole: Vector3 = sk.global_transform*(foot*Vector3(0,worker._pose._ankle_height[side],0))
		soles.append(sole)
		minimum_sole=minf(minimum_sole,sole.y)
		var phase: String = "native" if worker.ragdoll.active else "return" if return_tail>0 else "ordinary"
		minima[phase]=minf(minima[phase],sole.y)
		knees.append((sk.global_basis*(sk.get_bone_global_pose(chain[1]).origin-sk.get_bone_global_pose(chain[0]).origin)).normalized())
		ankles.append((sk.global_basis*foot.basis).orthonormalized().get_rotation_quaternion())
	var current := {"native":worker.ragdoll.active,"root":root,"soles":soles,"knees":knees,"ankles":ankles}
	if not previous.is_empty() and (current.native!=previous.native or return_tail>0):
		var label := "enter" if current.native else "leave"
		var stats := {"root":root.origin.distance_to(previous.root.origin),"angle":rad_to_deg(root.basis.orthonormalized().get_rotation_quaternion().angle_to(previous.root.basis.orthonormalized().get_rotation_quaternion())),"sole":0.0,"knee":0.0,"ankle":0.0}
		for side in 2:
			stats.sole=maxf(stats.sole,soles[side].distance_to(previous.soles[side]))
			stats.knee=maxf(stats.knee,rad_to_deg(knees[side].angle_to(previous.knees[side])))
			stats.ankle=maxf(stats.ankle,rad_to_deg(ankles[side].angle_to(previous.ankles[side])))
		if current.native!=previous.native:
			handoffs[label]=stats
			print("NATIVE_WAKO_POSE handoff=",label," role=",worker.work_foot_side," stats=",stats)
		else:
			return_steps.samples+=1
			for key: String in stats: return_steps[key]=maxf(return_steps[key],stats[key])
	previous=current
	if current.native:
		native_samples+=1
		for body in worker.ragdoll.rig.bodies:
			var expected: Transform3D = PhysicsServer3D.body_get_state(body.rid,PhysicsServer3D.BODY_STATE_TRANSFORM)*body.b2b
			var actual: Transform3D = sk.global_transform*sk.get_bone_global_pose(body.bone)
			native_position_error=maxf(native_position_error,actual.origin.distance_to(expected.origin))
			native_rotation_error=maxf(native_rotation_error,rad_to_deg(actual.basis.orthonormalized().get_rotation_quaternion().angle_to(expected.basis.orthonormalized().get_rotation_quaternion())))
	elif return_tail>0: return_samples+=1
	if not worker.ragdoll.visual.is_returning(): return_tail=maxi(0,return_tail-1)

func _run() -> void:
	var floor := StaticBody3D.new()
	floor.position.y=-.5
	var shape := BoxShape3D.new()
	shape.size=Vector3(40,1,40)
	var collider := CollisionShape3D.new()
	collider.shape=shape
	floor.add_child(collider)
	add_child(floor)
	for role in 2:
		previous.clear()
		handoffs.clear()
		native_samples=0
		native_position_error=0.0
		native_rotation_error=0.0
		return_samples=0
		return_tail=0
		minimum_sole=INF
		minima={"ordinary":INF,"native":INF,"return":INF}
		return_steps={"samples":0,"root":0.0,"angle":0.0,"sole":0.0,"knee":0.0,"ankle":0.0}
		worker=Worker.instantiate()
		worker.worker_id="314673468603" if role==0 else "316720289077"
		worker.position.y=.85
		add_child(worker)
		var observer := FinalObserver.new()
		observer.worker=worker
		observer.fixture=self
		worker._skeleton.add_child(observer)
		for tick in 120: await get_tree().physics_frame
		check(worker.work_foot_side==role,"original ID retains its original foot role")
		worker.apply_hit(Vector3.LEFT*worker.mass*3.55)
		check(worker.ragdoll.is_down(),"original finite strong hit activates the unchanged native knockdown threshold")
		for tick in 3600:
			await get_tree().physics_frame
			if tick%240==239 and worker.ragdoll.active:
				var rd: RefCounted = worker.ragdoll
				var support: Dictionary = rd._ground_support()
				print("NATIVE_WAKO_POSE support role=",role," clock=",rd._clock," recovering=",rd.recovering," root=",rd._current[0]," velocity=",rd.rig.bodies[0].rb.linear_velocity," angular=",rd.rig.bodies[0].rb.angular_velocity," ground=",support," fit=",rd._capsule_fits(support) if not support.is_empty() else false," force=",rd.assistance_force," torque=",rd.assistance_torque," uprightclock=",rd._upright_time)
			if not worker.ragdoll.is_down() and handoffs.has("leave"): break
		for tick in 60: await get_tree().physics_frame
		check(not worker.ragdoll.is_down() and worker.ragdoll._cooldown>0.0,"unchanged native get-up restores capsule and original positive hit cooldown")
		for label: String in ["enter","leave"]:
			var stats: Dictionary = handoffs.get(label,{})
			check(not stats.is_empty() and stats.root<.025 and stats.angle<6.0 and stats.sole<.05 and stats.knee<12.0 and stats.ankle<18.0,"actual %s native/procedural seam meets original continuity bounds"%label)
		check(native_samples>125 and native_position_error<.0001 and native_rotation_error<.1,"visible bones reproduce actual original native body frames throughout physical fall")
		check(return_samples>20,"supported native get-up drives the actual captured pose into the authored idle blend")
		check(return_steps.samples>20 and return_steps.root<.025 and return_steps.angle<6.0 and return_steps.sole<.05 and return_steps.knee<12.0 and return_steps.ankle<18.0,"every actual native-to-authored continuation frame preserves the same motion bounds")
		print("NATIVE_WAKO_POSE role=",role," native_samples=",native_samples," actual_position_error=",native_position_error," actual_rotation_error=",native_rotation_error," return_samples=",return_samples," minimum_sole=",minimum_sole," phase_minima=",minima," return_steps=",return_steps," handoffs=",handoffs)
		worker.queue_free()
		worker=null
		await get_tree().physics_frame
	print("CONTRAPTION_NATIVE_WAKO_POSE ","PASS" if failures==0 else "FAIL", " failures=",failures)
	Shortcuts.graceful_quit(0 if failures==0 else 1)

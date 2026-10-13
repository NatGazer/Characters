extends RefCounted
## Face harness props: a visible stand-in player and a minimal live hostile
## that satisfies GunControl.live_hostile_core (group contraption_threats).

class FakeBrain extends RefCounted:
	var enabled := true

class FakeMind extends Node:
	var hostile := true
	var brain := FakeBrain.new()

class FakeAssembly extends Node3D:
	var active := true

class FakeCore extends Node3D:
	var installed := true
	var health := 100.0

## Minimal stand-in for the RaulsMod scheduler/yard (the real
## contraption_yard.gd does not compile without the full mod). It provides
## only what idle play, personality warnings and the helper read; it never
## leases work. With work_paused=false the REAL idle play director runs.
class FakeCrewTravel extends RefCounted:
	func water_notice_point(_w: Node) -> Vector3: return Vector3.INF

class FakeYard extends Node3D:
	var _crew_travel := FakeCrewTravel.new()
	var work_paused := false
	var last_message := ""
	var _reservations := {}
	func crew_travel_active() -> bool: return false
	func crew_travel_worker(_w: Node) -> bool: return false
	func crew_travel_context() -> Dictionary: return {}
	func worksite_active() -> bool: return false
	func worksite_worker(_w: Node) -> bool: return false
	func worksite_context() -> Dictionary: return {}
	func unsafe_at(_p: Vector3) -> bool: return false

class FakeCoordinator extends Node:
	var yard: Node3D
	var workers: Array = []
	var active_jobs := {}
	var _jobs := {}
	func register_worker(w: Node) -> void:
		if not workers.has(w): workers.append(w)
	func interrupt_worker(_w: Node, _message: String) -> void: pass
	func _parking_position(w: Node) -> Vector3: return w.safe_position
	func empty_tool_parking_departure_ready(_w: Node) -> bool: return true
	func _cancel(_entry: Dictionary, _reason: String) -> void: pass

static func make_coordinator(parent: Node, paused := false) -> Node:
	var yard := FakeYard.new()
	yard.name = "HarnessYard"
	yard.work_paused = paused
	parent.add_child(yard)
	var service := FakeCoordinator.new()
	service.name = "HarnessCoordinator"
	service.yard = yard
	parent.add_child(service)
	return service

class FakeHostile extends Node3D:
	var alive := true
	var _core: Node3D
	var assembly: Node3D
	var mind_host: Node

## The harness's bpy-shim import of Wako.blend loses the Player.png image link,
## so the shared skin would render with a white atlas (no painted eyes/mouth).
## Re-bind the real atlas on the shared skin material and its eye pass.
static func bind_atlas(wako: Node) -> void:
	var tex: Texture2D = load("res://LogicObjects/Wako/textures/Player.png")
	var mesh: MeshInstance3D = wako.get("_skin_mesh")
	if not mesh or not tex: return
	var mat := mesh.get_surface_override_material(0) as ShaderMaterial
	if not mat: return
	mat.set_shader_parameter("albedo_texture", tex)
	if mat.next_pass is ShaderMaterial: mat.next_pass.set_shader_parameter("albedo_texture", tex)

static func make_player(parent: Node, pos: Vector3) -> Node3D:
	var player := Node3D.new()
	player.name = "HarnessPlayer"
	player.position = pos
	var mesh := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = .22
	capsule.height = 1.2
	mesh.mesh = capsule
	mesh.position.y = .6
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(.85, .45, .25)
	mesh.material_override = mat
	player.add_child(mesh)
	parent.add_child(player)
	Global.Player = player
	return player

static func make_hostile(parent: Node, pos: Vector3) -> Node3D:
	var enemy := FakeHostile.new()
	enemy.name = "HarnessHostile"
	enemy.position = pos
	var assembly := FakeAssembly.new()
	enemy.add_child(assembly)
	enemy.assembly = assembly
	var mind := FakeMind.new()
	enemy.add_child(mind)
	enemy.mind_host = mind
	var core := FakeCore.new()
	core.position = Vector3(0, .8, 0)
	assembly.add_child(core)
	enemy._core = core
	core.set_meta(&"machine_fauna", enemy)
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = .45
	sphere.height = .9
	mesh.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(.55, .08, .06)
	mat.emission_enabled = true
	mat.emission = Color(.9, .1, .05)
	mat.emission_energy_multiplier = .6
	mesh.material_override = mat
	core.add_child(mesh)
	enemy.add_to_group(&"contraption_threats")
	parent.add_child(enemy)
	return enemy

static func kill_hostile(enemy: Node3D) -> void:
	if is_instance_valid(enemy): enemy.alive = false

## World position of the rendered (skinned) painted eye centres, found from
## the mesh UVs: the midpoint of atlas (.409,.715) and (.409,.914).
static func painted_eye_midpoint(wako: Node) -> Vector3:
	var mesh_instance: MeshInstance3D = wako.get("_skin_mesh")
	var skeleton: Skeleton3D = wako.get("_skeleton")
	var arrays := mesh_instance.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var index: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var stride := int(float(bones.size()) / float(verts.size()))
	var skin: Skin = mesh_instance.skin
	var sum := Vector3.ZERO
	var found := 0
	for uv: Vector2 in [Vector2(.409, .715), Vector2(.409, .914)]:
		for t in range(0, index.size(), 3):
			var a := uvs[index[t]]
			var e0 := uvs[index[t + 1]] - a
			var e1 := uvs[index[t + 2]] - a
			var p := uv - a
			var d := e0.x * e1.y - e1.x * e0.y
			if absf(d) < 1e-12: continue
			var l1 := (p.x * e1.y - e1.x * p.y) / d
			var l2 := (e0.x * p.y - p.x * e0.y) / d
			if l1 < -1e-5 or l2 < -1e-5 or 1.0 - l1 - l2 < -1e-5: continue
			var local := verts[index[t]] * (1.0 - l1 - l2) + verts[index[t + 1]] * l1 + verts[index[t + 2]] * l2
			var world := Vector3.ZERO
			var total := 0.0
			var v: int = index[t]
			for j in stride:
				var w := weights[v * stride + j]
				if w <= 0.0: continue
				var bind := bones[v * stride + j]
				var bone := skin.get_bind_bone(bind)
				if bone < 0: bone = skeleton.find_bone(skin.get_bind_name(bind))
				world += (skeleton.global_transform * skeleton.get_bone_global_pose(bone) * skin.get_bind_pose(bind) * local) * w
				total += w
			sum += world / maxf(total, 1e-6)
			found += 1
			break
	return sum / found if found == 2 else Vector3.INF

## Harness-only face profiler: helpers spawned with timed_wako() time their
## own production face tick (_update_expression) in place; the driver only
## collects those counters each physics tick.
## Usage: var w := Props.timed_wako(WAKO) ... Props.drive_faces(self, wakos).
const TIMED_HELPER := preload("res://harness/scripts/face_timed_helper.gd")

static func timed_wako(scene: PackedScene) -> RigidBody3D:
	var w: RigidBody3D = scene.instantiate()
	w.set_script(TIMED_HELPER)
	return w

class FaceDriver extends Node:
	var faces := {}
	var usec := {}
	var ticks := {}
	func _physics_process(_delta: float) -> void:
		for w: Node in faces:
			if not is_instance_valid(w): continue
			usec[w] = int(w.get("face_usec"))
			ticks[w] = int(w.get("face_ticks"))
	func per_tick(w: Node) -> float:
		return float(usec.get(w, 0)) / maxf(float(ticks.get(w, 0)), 1.0)

static func drive_faces(stage: Node, wakos: Array) -> FaceDriver:
	var driver := FaceDriver.new()
	driver.name = "FaceDriver"
	for w: Node in wakos:
		assert(w.get("face_usec") != null, "spawn profiled Wako with Props.timed_wako()")
		driver.faces[w] = w.get("eyes")
	stage.add_child(driver)
	return driver

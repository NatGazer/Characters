extends "res://.claude/tests/contraptions/wako_material_lease_cancel.gd"
## Camera/recording only. The actual ordinary lease and every final-pose
## observation still come from the unchanged native lifecycle fixture.
const MotionProbe := preload("res://.claude/tests/jitter/jitter_probe.gd")
var _render_out := ""
var _render_camera: Camera3D
var _render_probe: Node
var _render_markers: Array[Marker3D] = []

func _ready() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--material-lease-render-out="):
			_render_out=ProjectSettings.globalize_path(argument.get_slice("=",1))
	if not _render_out.is_empty():
		var world := WorldEnvironment.new()
		world.environment=Environment.new()
		world.environment.background_mode=Environment.BG_COLOR
		world.environment.background_color=Color(.12,.16,.22)
		world.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
		world.environment.ambient_light_color=Color(.85,.92,1)
		world.environment.ambient_light_energy=.65
		add_child(world)
		var sun:=DirectionalLight3D.new()
		sun.rotation_degrees=Vector3(-45,-25,0)
		sun.light_energy=1.6
		sun.shadow_enabled=true
		add_child(sun)
	super._ready()

func apply_material_setback(pose: SkeletonModifier3D,sk: Skeleton3D) -> bool:
	var accepted: bool=super.apply_material_setback(pose,sk)
	if not _render_out.is_empty() and not _live_case.is_empty() and not is_instance_valid(_render_probe):
		_start_render(_live_case.worker)
	return accepted

func _start_render(worker: RigidBody3D) -> void:
	_render_camera=Camera3D.new()
	_render_camera.fov=48
	add_child(_render_camera)
	var side: float=1.0 if worker.tool_foot_side()==1 else -1.0
	var centre: Vector3=worker.global_position+Vector3(0,.55,-.22)
	_render_camera.global_position=centre+Vector3(side*3.2,.15,2.6)
	_render_camera.look_at(centre)
	_render_camera.make_current()
	for label: String in ["EvaluatedCube","EvaluatedSoleLeft","EvaluatedSoleRight"]:
		var marker:=Marker3D.new()
		marker.name=label
		add_child(marker)
		marker.add_to_group("material_lease_motion")
		_render_markers.append(marker)
	for node: Node3D in [worker,worker.tool_anchor,worker.head_anchor,_live_case.tool,_live_case.source]:
		node.add_to_group("material_lease_motion")
	_render_probe=MotionProbe.new()
	_render_probe.out_dir=_render_out
	_render_probe.specs=PackedStringArray(["camera","group:material_lease_motion"])
	_render_probe.settle_s=0.0
	_render_probe.record_s=1.5
	_render_probe.capture_every=1
	_render_probe.capture_scale=1.0
	_render_probe.stay=true
	add_child(_render_probe)
	print("MATERIAL_LEASE_RENDER started tick=",_tick," worker=",worker.worker_id," role=",worker.tool_foot_side()," fixed_camera=",_render_camera.global_transform," actual_duration=",_render_probe.record_s," raw_head_anchor_included=true out=",_render_out)

func capture_final(worker: RigidBody3D) -> void:
	super.capture_final(worker)
	if _render_markers.is_empty() or _live_case.is_empty() or _live_case.worker!=worker or not worker._pose.evaluated_valid: return
	_render_markers[0].global_transform=worker._pose.evaluated_root
	for side in 2:
		_render_markers[side+1].global_transform=Transform3D(worker._pose.evaluated_ankles[side],worker._pose.evaluated_soles[side])

func _live_finish() -> void:
	if is_instance_valid(_render_probe) and _render_probe._phase!="done": return
	super._live_finish()

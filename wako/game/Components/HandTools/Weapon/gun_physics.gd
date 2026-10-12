extends RefCounted
## Authored physical stock, separate from GunBase's dimensionless view lag.
## Dry mass belongs to the same item through all custody roles. Ammunition
## remains the existing native gun mechanism; it never grants mass or rounds.
const MASS_KG := {&"pistol":1.1, &"rifle":4.3, &"gun_assault":4.0,
	&"rocket_launcher":9.0, &"bfg":12.0, &"nuke_launcher":14.0}
const PRINCIPAL_SIZE := {&"pistol":Vector3(.19,.2,.38), &"rifle":Vector3(.2,.23,1.0),
	&"gun_assault":Vector3(.24,.22,.86), &"rocket_launcher":Vector3(.32,.3,.95),
	&"bfg":Vector3(.5,.34,.8), &"nuke_launcher":Vector3(.48,.4,.95)}
const ENVELOPE_VERSION := 3

static func mass_kg(item: Node3D) -> float:
	return float(MASS_KG.get(item.get("tool_id"), 0.0)) if is_instance_valid(item) else 0.0

static func dimensions(item: Node3D) -> Vector3:
	return PRINCIPAL_SIZE.get(item.get("tool_id"), Vector3.ZERO)

## Visual effects have no solid stock. Hidden ammunition, slides, bolts and
## prongs remain physical; visibility and render layers never decide custody.
static func is_physical_mesh(mesh: MeshInstance3D, item: Node3D) -> bool:
	if not is_instance_valid(mesh) or not is_instance_valid(item) or not mesh.mesh or mesh.mesh.get_aabb().size.length() <= .001: return false
	var ancestor: Node = mesh
	while is_instance_valid(ancestor) and ancestor != item:
		if ancestor is MuzzleFlash: return false
		if ancestor is OmniLight3D and item.get("tool_id") == &"gun_assault" and ancestor == item.get_node_or_null("GunMesh/GunTip/MuzzleFlash"): return false
		if ancestor is Node3D and (ancestor as Node3D).top_level: return false
		var script: Script = ancestor.get_script()
		if script and script.resource_path == "res://Components/HandTools/BFG/bfg_bolts.gd": return false
		ancestor = ancestor.get_parent()
	return ancestor == item

static func envelope_local(item: Node3D) -> AABB:
	if not is_instance_valid(item): return AABB()
	# A player's last view-model pose stays on the same actual item during handoff.
	# Re-cache that fixed housing pose; native mechanism motion uses its full sweep.
	var model := item.get_node_or_null("Model") as Node3D
	var housing_pose := model.transform if model else Transform3D.IDENTITY
	# Old caches included muzzle sprites. Recompute those and a pre-ready cache
	# once the same actual item finishes constructing its native mechanism.
	if item.has_meta(&"gun_full_envelope") and item.get_meta(&"gun_full_envelope_version", 0) == ENVELOPE_VERSION and item.get_meta(&"gun_full_envelope_ready", false) == item.is_node_ready() and item.get_meta(&"gun_full_envelope_housing", Transform3D.IDENTITY) == housing_pose: return item.get_meta(&"gun_full_envelope")
	var result := AABB()
	var rest_bounds := AABB()
	var first := true
	for mesh: MeshInstance3D in item.find_children("*", "MeshInstance3D", true, false):
		if not is_physical_mesh(mesh, item): continue
		var piece: AABB = _rest_frame(mesh, item, item) * mesh.mesh.get_aabb()
		rest_bounds = piece if first else rest_bounds.merge(piece)
		result = piece if first else result.merge(piece)
		var ancestor: Node = mesh
		while is_instance_valid(ancestor) and ancestor != item:
			if ancestor is Node3D:
				var motion := _motion(item, ancestor)
				if motion.has("shift") or motion.has("angle_max"): result = result.merge(_swept_piece(mesh, item, ancestor, motion))
			ancestor = ancestor.get_parent()
		first = false
	if not first and result.position.is_finite() and result.size.is_finite():
		# One millimetre for finite transform/mesh rounding, never effect sprites.
		result = result.grow(.001)
		item.set_meta(&"gun_full_envelope", result)
		item.set_meta(&"gun_full_envelope_version", ENVELOPE_VERSION)
		item.set_meta(&"gun_full_envelope_ready", item.is_node_ready())
		item.set_meta(&"gun_full_envelope_housing", housing_pose)
		item.set_meta(&"gun_rest_center", rest_bounds.get_center())
	return result

static func center_local(item: Node3D) -> Vector3:
	# A collision sweep is empty clearance space, not additional dry stock mass.
	var bounds := envelope_local(item)
	return item.get_meta(&"gun_rest_center", bounds.get_center())

static func _rest(item: Node3D, part: Node3D, field: String) -> Transform3D:
	if item.is_node_ready():
		var value: Variant = item.get(field)
		if value is Transform3D: return value
		if value is Basis: return Transform3D(value, part.position)
		if value is Vector3: return Transform3D(part.basis, value)
	return part.transform

static func _motion(item: Node3D, part: Node3D) -> Dictionary:
	var kind: StringName = item.get("tool_id")
	var name := String(part.name)
	if kind == &"gun_assault" and name == "GunMesh": return {"rest":Transform3D(part.basis,Vector3.ZERO), "shift":Vector3(0,0,.08)}
	if kind == &"pistol":
		if name == "Slide": return {"rest":_rest(item,part,"_slide_rest"), "shift":Vector3(0,0,.032)}
		if name == "Magazine":
			var pose := _rest(item,part,"_mag_rest")
			return {"rest":pose, "shift":pose.basis*Vector3(0,-.14,.012)}
		if name == "Trigger": return {"rest":_rest(item,part,"_trigger_rest"), "axis":Vector3.RIGHT,"angle_min":deg_to_rad(-14),"angle_max":0.0}
	if kind == &"rifle":
		if name == "Magazine": return {"rest":_rest(item,part,"_mag_rest"),"shift":Vector3(0,-.16,-.02)}
		if name == "Bolt":
			var pose := _rest(item,part,"_bolt_rest")
			var travel := _model_axis(item,part)*float(item.get("bolt_travel"))
			var axis: Vector3 = item.get("_bolt_axis") if item.is_node_ready() else (pose.basis.inverse()*_model_axis(item,part)).normalized()
			return {"rest":pose,"axis":axis,"angle_min":0.0,"angle_max":deg_to_rad(float(item.get("bolt_lift_deg"))),"shift":travel}
		if name == "ZoomRing":
			var pose := _rest(item,part,"_ring_rest")
			var axis: Vector3 = item.get("_ring_axis") if item.is_node_ready() else (pose.basis.inverse()*_model_axis(item,part)).normalized()
			return {"rest":pose,"axis":axis,"angle_min":deg_to_rad(-110),"angle_max":0.0}
		if name == "Trigger": return {"rest":_rest(item,part,"_trigger_rest"),"axis":Vector3.RIGHT,"angle_min":deg_to_rad(-12),"angle_max":0.0}
	if kind == &"bfg":
		if name == "Coils":
			var pose := _rest(item,part,"_coils_rest")
			# Native coils rotate in their parent frame, before their imported basis.
			return {"rest":pose,"axis":(pose.basis.inverse()*Vector3.FORWARD).normalized(),"angle_min":0.0,"angle_max":TAU}
		if name in ["Prong0","Prong1","Prong2"]:
			var pose := part.transform
			var rests: Array = item.get("_prong_rest")
			var index := int(name.right(1))
			if item.is_node_ready() and index < rests.size(): pose = rests[index]
			return {"rest":pose,"axis":Vector3.RIGHT,"angle_min":-.115,"angle_max":maxf(float(item.get("prong_open")),float(item.get("prong_splay")))+.015}
	if kind == &"nuke_launcher":
		if name == "Shell":
			var pose := _rest(item,part,"_shell_rest")
			return {"rest":pose,"shift":pose.basis*Vector3(0,.04,-.4),"axis":Vector3.BACK,"angle_min":-.01,"angle_max":.01,"shift_second":pose.basis*Vector3(0,0,.035)}
		if name == "Lever": return {"rest":_rest(item,part,"_lever_rest"),"axis":Vector3.RIGHT,"angle_min":0.0,"angle_max":float(item.get("lever_released"))}
		if name == "GaugeNeedle":
			var zero := float(item.get("needle_zero"))
			var full := zero+(float(item.get("needle_full"))-zero)*1.012
			return {"rest":_rest(item,part,"_needle_rest"),"axis":Vector3.BACK,"angle_min":minf(zero,full),"angle_max":maxf(zero,full)}
	return {}

static func _model_axis(item: Node3D, part: Node3D) -> Vector3:
	var model := item.get_node_or_null("Model")
	if part.get_parent() == model: return Vector3.BACK
	return (_rest_frame(part.get_parent(),model,item).basis.inverse()*Vector3.BACK).normalized()

static func _rest_frame(node: Node, stop: Node, item: Node3D) -> Transform3D:
	var result := Transform3D.IDENTITY
	var ancestor := node
	while is_instance_valid(ancestor) and ancestor != stop:
		if ancestor is Node3D:
			var part := ancestor as Node3D
			var motion := _motion(item, part)
			var pose: Transform3D = motion.get("rest", part.transform)
			result = pose * result
		ancestor = ancestor.get_parent()
	return result

static func _trig_range(base: float, cosine: float, sine: float, lo: float, hi: float) -> Vector2:
	var first := base+cosine*cos(lo)+sine*sin(lo)
	var last := base+cosine*cos(hi)+sine*sin(hi)
	var result := Vector2(minf(first,last),maxf(first,last))
	var phase := atan2(sine,cosine)
	for extreme: float in [phase,phase+PI]:
		for turn in range(-2,3):
			var angle: float = extreme+turn*TAU
			if angle >= lo and angle <= hi:
				var value := base+cosine*cos(angle)+sine*sin(angle)
				result = Vector2(minf(result.x,value),maxf(result.y,value))
	return result

static func _swept_piece(mesh: MeshInstance3D, item: Node3D, joint: Node3D, motion: Dictionary) -> AABB:
	var parent_frame := _rest_frame(joint.get_parent(), item, item)
	var rest: Transform3D = motion.get("rest", joint.transform)
	var below := _rest_frame(mesh, joint, item)
	var rotate: Basis = parent_frame.basis*rest.basis
	var centre: Vector3 = parent_frame*rest.origin
	var axis: Vector3 = motion.get("axis", Vector3.RIGHT)
	axis = axis.normalized()
	var lo: float = motion.get("angle_min", 0.0)
	var hi: float = motion.get("angle_max", 0.0)
	var shift: Vector3 = parent_frame.basis*motion.get("shift", Vector3.ZERO)
	var second: Vector3 = parent_frame.basis*motion.get("shift_second", Vector3.ZERO)
	var box := mesh.mesh.get_aabb()
	var result := AABB()
	for corner in 8:
		var point: Vector3 = below*(box.position+box.size*Vector3(float(corner&1),float((corner>>1)&1),float((corner>>2)&1)))
		var parallel := axis*axis.dot(point)
		var base: Vector3 = centre+rotate*parallel
		var cosine: Vector3 = rotate*(point-parallel)
		var sine: Vector3 = rotate*axis.cross(point)
		var minimum := Vector3.ZERO
		var maximum := Vector3.ZERO
		for component in 3:
			var limits := _trig_range(base[component],cosine[component],sine[component],lo,hi)
			minimum[component] = limits.x+minf(0.0,shift[component])+minf(0.0,second[component])
			maximum[component] = limits.y+maxf(0.0,shift[component])+maxf(0.0,second[component])
		var swept := AABB(minimum,maximum-minimum)
		result = swept if corner == 0 else result.merge(swept)
	return result

static func box_inertia(mass: float, size: Vector3) -> Vector3:
	return mass / 12.0 * Vector3(size.y*size.y+size.z*size.z,
		size.x*size.x+size.z*size.z, size.x*size.x+size.y*size.y)

static func inertia_local(item: Node3D) -> Vector3:
	return box_inertia(mass_kg(item), dimensions(item))

static func parallel_diagonal(mass: float, offset: Vector3) -> Vector3:
	return mass * Vector3(offset.y*offset.y+offset.z*offset.z,
		offset.x*offset.x+offset.z*offset.z, offset.x*offset.x+offset.y*offset.y)

static func rotated_diagonal(diagonal: Vector3, orientation: Basis) -> Vector3:
	var tensor := orientation * Basis.from_scale(diagonal) * orientation.transposed()
	return Vector3(tensor.x.x, tensor.y.y, tensor.z.z)

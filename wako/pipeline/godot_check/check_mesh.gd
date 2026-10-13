extends SceneTree
# Usage: copy Wako.blend (+ textures/Player.png and the game's Wako.blend.import) into
#   <proj>/LogicObjects/Wako/ of a scratch Godot 4.7 project whose editor settings point
#   filesystem/import/blender/blender_path at Blender, then:
#   godot --headless --path <proj> --import && godot --headless --path <proj> -s check_mesh.gd
# Prints one line "CHECK_JSON {...}" (bone rests, animations, surfaces, skin, influences).
# Import check for the rebuilt Wako.blend: skeleton rests, animations, mesh/skin data.
func _init():
	var out := {}
	var ps: PackedScene = load("res://LogicObjects/Wako/Wako.blend")
	var root := ps.instantiate()
	var sk: Skeleton3D = root.find_children("*", "Skeleton3D", true, false)[0]
	out["skeleton_path"] = str(root.get_path_to(sk))
	var bones := []
	for i in sk.get_bone_count():
		var r := sk.get_bone_rest(i)
		var g := sk.get_bone_global_rest(i)
		bones.append({"index": i, "name": sk.get_bone_name(i), "parent": sk.get_bone_parent(i),
			"rest_origin": [r.origin.x, r.origin.y, r.origin.z],
			"rest_basis": [[r.basis.x.x, r.basis.x.y, r.basis.x.z], [r.basis.y.x, r.basis.y.y, r.basis.y.z], [r.basis.z.x, r.basis.z.y, r.basis.z.z]],
			"global_origin": [g.origin.x, g.origin.y, g.origin.z],
			"global_y_axis": [g.basis.y.x, g.basis.y.y, g.basis.y.z]})
	out["bones"] = bones
	var ap: AnimationPlayer = root.find_children("*", "AnimationPlayer", true, false)[0]
	out["animations"] = ap.get_animation_list().size()
	out["animation_names"] = Array(ap.get_animation_list())
	var meshes := []
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var mesh := mi.mesh as ArrayMesh
		var info := {"name": str(mi.name), "surfaces": mesh.get_surface_count(), "skin": mi.skin != null,
			"skeleton": str(mi.skeleton)}
		var arr := mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var bones_arr = arr[Mesh.ARRAY_BONES]
		var weights_arr = arr[Mesh.ARRAY_WEIGHTS]
		info["vertices_gpu"] = verts.size()
		info["triangles"] = idx.size() / 3
		info["has_tangents"] = arr[Mesh.ARRAY_TANGENT] != null
		info["has_uv"] = arr[Mesh.ARRAY_TEX_UV] != null
		var per := 0
		if weights_arr != null and verts.size() > 0:
			per = weights_arr.size() / verts.size()
		info["weights_per_vertex_slots"] = per
		var max_nz := 0
		var unweighted := 0
		var max_sum_err := 0.0
		var hist := {}
		for v in verts.size():
			var nz := 0
			var s := 0.0
			for k in per:
				var w: float = weights_arr[v * per + k]
				if w > 0.0001:
					nz += 1
				s += w
			max_nz = max(max_nz, nz)
			hist[nz] = hist.get(nz, 0) + 1
			if s < 0.001: unweighted += 1
			else: max_sum_err = max(max_sum_err, absf(s - 1.0))
		info["max_nonzero_influences"] = max_nz
		info["influence_histogram"] = hist
		info["unweighted"] = unweighted
		info["max_weight_sum_error"] = max_sum_err
		var mn := Vector3(INF, INF, INF)
		var mx := -mn
		for p in verts:
			mn = mn.min(p); mx = mx.max(p)
		info["aabb_min"] = [mn.x, mn.y, mn.z]
		info["aabb_max"] = [mx.x, mx.y, mx.z]
		var mat := mesh.surface_get_material(0)
		info["material"] = str(mat.resource_name) if mat else "none"
		info["material_has_albedo_texture"] = mat is StandardMaterial3D and (mat as StandardMaterial3D).albedo_texture != null
		if mi.skin:
			info["skin_binds"] = mi.skin.get_bind_count()
			var names := []
			for b in mi.skin.get_bind_count():
				names.append(mi.skin.get_bind_name(b))
			info["skin_bind_names"] = names
		meshes.append(info)
	out["meshes"] = meshes
	print("CHECK_JSON " + JSON.stringify(out))
	root.free()
	quit()

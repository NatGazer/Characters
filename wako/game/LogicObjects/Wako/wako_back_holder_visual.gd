extends RefCounted
## Body-fitted finish for the finite 2 kg back holder. Its mounting plate
## follows the actual root-weighted skin; the same eleven meshes account for
## all material. Existing native contact sensors and tool paths stay intact.
## Shallow engraving is normal relief: it adds no material or powered emitter.
const AncientVisual := preload("res://Components/Contraptions/ancient_machine_visual.gd")
const MAP_SIZE := Vector2i(256,128)
const SEAT_SIZE := Vector3(.50,.21,.055)
const SOCKET_SIZE := Vector3(.065,.19,.28)
static var _seat: ArrayMesh
static var _socket: ArrayMesh
static var _maps: Array[ImageTexture] = []
static var _body_fitted := false
static var _body_fit_area := 0.0
static var _body_fit_triangles := 0
const SEAT_ORIGIN := Vector3(0,-.13,.25)
const BODY_GAP := .001 # A seated one-millimetre interface, never skin penetration.

static func fit_to_body(skin_mesh: MeshInstance3D, skeleton: Skeleton3D) -> bool:
	if _body_fitted: return true
	if not skin_mesh or not skin_mesh.mesh or not skin_mesh.skin or not skeleton: return false
	var skin: Skin = skin_mesh.skin
	var root_bind := -1
	for bind: int in skin.get_bind_count():
		if skin.get_bind_bone(bind)==0 or skin.get_bind_name(bind)==skeleton.get_bone_name(0):
			root_bind=bind
			break
	if root_bind<0: return false
	# Bind matrices express skin vertices in the root bone's local axes. Undo
	# its imported 180-degree horizontal rest rotation, exactly as BackTool's
	# live mounting frame does. Every accepted triangle moves rigidly with it.
	var body_from_mesh := Transform3D(skeleton.get_bone_global_rest(0).basis,Vector3.ZERO)*skin.get_bind_pose(root_bind)
	var surfaces: Array[PackedVector3Array] = []
	var area := 0.0
	for surface: int in skin_mesh.mesh.get_surface_count():
		var arrays := skin_mesh.mesh.surface_get_arrays(surface)
		if arrays[Mesh.ARRAY_BONES]==null or arrays[Mesh.ARRAY_WEIGHTS]==null: continue
		var points: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var joints: PackedInt32Array=arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array=arrays[Mesh.ARRAY_WEIGHTS]
		var indices: PackedInt32Array=arrays[Mesh.ARRAY_INDEX]
		var stride := 8 if skin_mesh.mesh.surface_get_format(surface)&Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS else 4
		var rooted := PackedByteArray()
		rooted.resize(points.size())
		for index: int in points.size():
			var root_weight := 0.0
			for slot: int in stride:
				if joints[index*stride+slot]==root_bind: root_weight+=weights[index*stride+slot]
			rooted[index]=1 if root_weight>.999 else 0
		for offset: int in range(0,indices.size(),3):
			var a:=indices[offset]; var b:=indices[offset+1]; var c:=indices[offset+2]
			if rooted[a]==0 or rooted[b]==0 or rooted[c]==0: continue
			var poly: Array[Vector3]=[body_from_mesh*points[a],body_from_mesh*points[b],body_from_mesh*points[c]]
			# Godot's clockwise front faces have a negative geometric cross Z.
			if (poly[1]-poly[0]).cross(poly[2]-poly[0]).z>=-.000001 or minf(poly[0].z,minf(poly[1].z,poly[2].z))<.05: continue
			for edge: Vector3 in [Vector3(0,-.25,1),Vector3(0,.25,-1),Vector3(1,-.235,1),Vector3(1,-.025,-1)]:
				if poly.size()<3: break
				poly=_clip_mount(poly,int(edge.x),edge.y,edge.z)
			for triangle: int in range(1,poly.size()-1):
				var face:=PackedVector3Array([poly[0],poly[triangle],poly[triangle+1]])
				var projected:=absf((face[1]-face[0]).cross(face[2]-face[0]).z)*.5
				if projected<=.0000000001: continue
				area+=projected
				surfaces.append(face)
	# The complete plate footprint must be covered by real skin. A different
	# future rig falls back to the old clear mount rather than inventing a fit.
	if absf(area-SEAT_SIZE.x*SEAT_SIZE.y)>.000001: return false
	var vertices:=PackedVector3Array(); var normals:=PackedVector3Array()
	for face: PackedVector3Array in surfaces:
		var inner:=PackedVector3Array(); var outer:=PackedVector3Array()
		for point: Vector3 in face:
			inner.append(point+Vector3.BACK*BODY_GAP-SEAT_ORIGIN)
			outer.append(point+Vector3.BACK*(BODY_GAP+SEAT_SIZE.z)-SEAT_ORIGIN)
		_append_mount_triangle(vertices,normals,inner[2],inner[1],inner[0])
		_append_mount_triangle(vertices,normals,outer[0],outer[1],outer[2])
		for edge: int in 3:
			var next: int=(edge+1)%3
			_append_mount_triangle(vertices,normals,inner[edge],inner[next],outer[next])
			_append_mount_triangle(vertices,normals,inner[edge],outer[next],outer[edge])
	var arrays: Array=[]; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=vertices
	arrays[Mesh.ARRAY_NORMAL]=normals
	_seat=ArrayMesh.new()
	_finish_uv(arrays)
	_seat.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	_body_fit_area=area
	_body_fit_triangles=surfaces.size()
	_body_fitted=true
	return true

static func _clip_mount(poly: Array[Vector3], axis: int, boundary: float, direction: float) -> Array[Vector3]:
	var result: Array[Vector3]=[]
	for index: int in poly.size():
		var a: Vector3=poly[index]; var b: Vector3=poly[(index+1)%poly.size()]
		var inside_a: bool=direction*(a[axis]-boundary)>=0.0
		var inside_b: bool=direction*(b[axis]-boundary)>=0.0
		if inside_a: result.append(a)
		if inside_a!=inside_b: result.append(a+(b-a)*((boundary-a[axis])/(b[axis]-a[axis])))
	return result

static func _append_mount_triangle(vertices: PackedVector3Array, normals: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3) -> void:
	var normal:=-(b-a).cross(c-a).normalized()
	vertices.append_array(PackedVector3Array([a,b,c]))
	normals.append_array(PackedVector3Array([normal,normal,normal]))

static func socket_mesh() -> ArrayMesh:
	if _socket: return _socket
	# Clip the existing closed bevelled bronze stock into a convex gusset.
	# In holder axes the upper tongue starts at z=.22, y=-.09; its relieved
	# front reaches z=.45 at y=-.225. The full original outward face z=.50,
	# screws and cradle stay put. The captured foot-0 thigh failures
	# lie ahead of this relief instead of inside the former square column.
	var inward:=Vector3(0,.23/.135,1.0).normalized()
	var boundary:=inward.dot(Vector3(0,.040,-.140))
	var original: ArrayMesh=AncientVisual.beveled_box(SOCKET_SIZE)
	var vertices:=PackedVector3Array(); var normals:=PackedVector3Array()
	var cut: Array[Vector3]=[]
	for surface: int in original.get_surface_count():
		var arrays:=original.surface_get_arrays(surface)
		var points: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array=arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX]!=null else PackedInt32Array()
		var count:=indices.size() if not indices.is_empty() else points.size()
		for offset: int in range(0,count,3):
			var face: Array[Vector3]=[]
			for corner: int in 3: face.append(points[indices[offset+corner] if not indices.is_empty() else offset+corner])
			var clipped: Array[Vector3]=[]
			for edge: int in 3:
				var a:=face[edge]; var b:=face[(edge+1)%3]
				var da:=inward.dot(a)-boundary; var db:=inward.dot(b)-boundary
				if da>=0.0: clipped.append(a)
				if (da>=0.0)!=(db>=0.0):
					var point:=a+(b-a)*(da/(da-db))
					clipped.append(point)
					var duplicate:=false
					for prior: Vector3 in cut:
						if prior.distance_squared_to(point)<1e-14: duplicate=true; break
					if not duplicate: cut.append(point)
			for triangle: int in range(1,clipped.size()-1):
				_append_mount_triangle(vertices,normals,clipped[0],clipped[triangle],clipped[triangle+1])
	# Close the real cut surface with the same clockwise winding. This cap is
	# material and participates in the unchanged eleven-mesh 2 kg integral.
	var center:=Vector3.ZERO
	for point: Vector3 in cut: center+=point
	center/=cut.size()
	var outward:=-inward
	var u:=Vector3.RIGHT; var v:=outward.cross(u)
	cut.sort_custom(func(a: Vector3,b: Vector3) -> bool: return atan2((a-center).dot(v),(a-center).dot(u))<atan2((b-center).dot(v),(b-center).dot(u)))
	for edge: int in cut.size():
		_append_mount_triangle(vertices,normals,center,cut[(edge+1)%cut.size()],cut[edge])
	var arrays: Array=[]; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=vertices; arrays[Mesh.ARRAY_NORMAL]=normals
	_socket=ArrayMesh.new()
	_socket.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	return _socket

static func seat_mesh() -> ArrayMesh:
	if _seat: return _seat
	var original: ArrayMesh=AncientVisual.beveled_box(SEAT_SIZE)
	_seat=ArrayMesh.new()
	for surface: int in original.get_surface_count():
		var arrays:=original.surface_get_arrays(surface)
		_finish_uv(arrays)
		_seat.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	return _seat

static func _finish_uv(arrays: Array) -> void:
	var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array=arrays[Mesh.ARRAY_NORMAL]
	var uv:=PackedVector2Array()
	var tangents:=PackedFloat32Array()
	for index: int in vertices.size():
		var p: Vector3=vertices[index]
		var n: Vector3=normals[index]
		var u: Vector3
		var v: Vector3
		if absf(n.z)>=maxf(absf(n.x),absf(n.y)):
			uv.append(Vector2(p.x/SEAT_SIZE.x+.5,.5-p.y/SEAT_SIZE.y))
			u=Vector3.RIGHT; v=Vector3.DOWN
		elif absf(n.x)>=absf(n.y):
			uv.append(Vector2(.5-p.z/SEAT_SIZE.z,.5-p.y/SEAT_SIZE.y))
			u=Vector3.FORWARD; v=Vector3.DOWN
		else:
			uv.append(Vector2(p.x/SEAT_SIZE.x+.5,p.z/SEAT_SIZE.z+.5))
			u=Vector3.RIGHT; v=Vector3.BACK
		u=u.slide(n).normalized()
		tangents.append_array(PackedFloat32Array([u.x,u.y,u.z,signf(n.cross(u).dot(v))]))
	arrays[Mesh.ARRAY_TEX_UV]=uv
	arrays[Mesh.ARRAY_TANGENT]=tangents

static func finish_seat(material: StandardMaterial3D) -> void:
	if _maps.is_empty(): _build_maps()
	material.albedo_color=Color.WHITE
	material.albedo_texture=_maps[0]
	material.normal_texture=_maps[1]
	material.normal_scale=1.0
	material.roughness_texture=_maps[2]
	material.roughness_texture_channel=BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	material.ao_texture=_maps[2]
	material.ao_texture_channel=BaseMaterial3D.TEXTURE_CHANNEL_RED
	material.uv1_triplanar=false
	material.uv1_scale=Vector3.ONE
	material.texture_repeat=false
	material.texture_filter=BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

static func _build_maps() -> void:
	var albedo:=Image.create(MAP_SIZE.x,MAP_SIZE.y,false,Image.FORMAT_RGBA8)
	var normal:=Image.create(MAP_SIZE.x,MAP_SIZE.y,false,Image.FORMAT_RGBA8)
	var orm:=Image.create(MAP_SIZE.x,MAP_SIZE.y,false,Image.FORMAT_RGBA8)
	var step:=Vector2(SEAT_SIZE.x/MAP_SIZE.x,SEAT_SIZE.y/MAP_SIZE.y)
	var heights:=PackedFloat32Array()
	heights.resize(MAP_SIZE.x*MAP_SIZE.y)
	for y: int in MAP_SIZE.y:
		for x: int in MAP_SIZE.x:
			var p:=Vector2((float(x)+.5)/MAP_SIZE.x-.5,.5-(float(y)+.5)/MAP_SIZE.y)*Vector2(SEAT_SIZE.x,SEAT_SIZE.y)
			var distance:=_engraving_distance(p)
			var groove:=1.0-smoothstep(.0015,.0032,distance)
			var enamel:=1.0-smoothstep(.0006,.00155,distance)
			var grain:=sin(p.x*938.7+p.y*373.1)*sin(p.x*241.3-p.y*871.9)
			var weather:=sin(p.x*91.3+p.y*47.1)*sin(p.y*67.9-p.x*39.1)
			var border:=1.0-smoothstep(.0,.010,minf(.25-absf(p.x),.105-absf(p.y)))
			var sand:=Color("d8c9aa")*(.97+grain*.022+weather*.020+border*.045)
			var tint:=sand.lerp(Color("6d7162"),groove*.52).lerp(Color("709890"),enamel*.88)
			tint.a=1.0
			albedo.set_pixel(x,y,tint)
			heights[y*MAP_SIZE.x+x]=-.00065*groove+.000045*grain
			orm.set_pixel(x,y,Color(1.0-groove*.24,lerpf(.80+weather*.035,.38,enamel),0,1))
	# One shared finite height grid avoids re-evaluating every carved segment
	# four extra times per pixel when the first actual Wako creates its finish.
	for y: int in MAP_SIZE.y:
		for x: int in MAP_SIZE.x:
			var left:=maxi(x-1,0); var right:=mini(x+1,MAP_SIZE.x-1)
			var top:=maxi(y-1,0); var bottom:=mini(y+1,MAP_SIZE.y-1)
			var dx: float=(heights[y*MAP_SIZE.x+right]-heights[y*MAP_SIZE.x+left])/((right-left)*step.x)
			var dv: float=(heights[bottom*MAP_SIZE.x+x]-heights[top*MAP_SIZE.x+x])/((bottom-top)*step.y)
			var n:=Vector3(-dx,-dv,1.0).normalized()
			normal.set_pixel(x,y,Color(n.x*.5+.5,n.y*.5+.5,n.z*.5+.5,1))
	for map: Image in [albedo,normal,orm]:
		map.generate_mipmaps()
		_maps.append(ImageTexture.create_from_image(map))

static func _engraving_distance(p: Vector2) -> float:
	# Bevel-framed engraving passes beneath the seated side sockets; vitreous
	# fill is passive enamel, with no light, power or autonomous effects.
	var q:=p.abs()
	var ring:=absf(p.length()-.025)
	ring=minf(ring,absf(p.length()-.013))
	var border:=_segment(q,Vector2(.183,.071),Vector2(0,.071))
	border=minf(border,_segment(q,Vector2(.183,.071),Vector2(.211,.043)))
	border=minf(border,_segment(q,Vector2(.211,.043),Vector2(.211,0)))
	var path:=_segment(q,Vector2(.218,.029),Vector2(.087,.029))
	path=minf(path,_segment(q,Vector2(.087,.029),Vector2(.058,.0)))
	path=minf(path,_segment(q,Vector2(.058,0),Vector2(.025,0)))
	return minf(ring,minf(border,path))

static func _segment(p: Vector2,a: Vector2,b: Vector2) -> float:
	var span:=b-a
	return (p-a-span*clampf((p-a).dot(span)/span.length_squared(),0,1)).length()

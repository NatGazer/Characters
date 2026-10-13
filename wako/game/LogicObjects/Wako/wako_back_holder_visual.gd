extends RefCounted
## Body-fitted finish for the finite 2 kg back holder. Its mounting plate
## follows the actual root-weighted skin; the same eleven meshes account for
## all material. Existing native contact sensors and tool paths stay intact.
## Shallow engraving is normal relief: it adds no material or powered emitter.
const AncientVisual := preload("res://Components/Contraptions/ancient_machine_visual.gd")
const MAP_SIZE := Vector2i(256,128)
const SEAT_SIZE := Vector3(.50,.21,.055)
# Worn-pack hardware (holder/body frame, +Z back). Two bronze straps run up
# the back from the plate toward the roof edge; each rubber tray sits on a
# short bronze shelf with a tapered gusset bolted to the plate (or strap).
# Everything stays inside the body silhouette and above its bottom edge.
const SOCKET_SIZE := Vector3(.05,.045,.10)
const SHELF_SIZE := Vector3(.075,.018,.10)
const PAD_SIZE := Vector3(.09,.020,.12) # Rubber cradle: base slab (x along the shaft, y up, z across).
# Shallow U: lips along both sides of the shaft rise above the base's top.
const LIP_HEIGHT := .016
const LIP_WIDTH := .014
const TRAY_SENSOR_SIZE := Vector3(.09,.08,.11) # Deep below its top: a falling step cannot tunnel through.
const STRAP_SIZE := Vector3(.044,.33,.006)
const STRAP_X := .215
const STRAP_Y := .12 # Plate top edge (-.045, tucked under it) up to the roof bevel (.285).
const MEASURED_BACK := .1992 # Root-rigid skin back face of the current rig.
# Body-fitted straps: the skin's own section at the strap, BODY_GAP off it,
# from under the plate's top edge, up the back, over the roof bevel and onto
# the roof, where the strap ends under its rivet.
const STRAP_BOTTOM := -.045
const STRAP_END_Z := .11
const STRAP_CENTRE := Vector2(0.0,.10) # Section-plane ray origin (z, y) inside the body.
const STRAP_CHAMFER := .0025
static var _strap_meshes: Array = [null,null]
static var _strap_ends: Array = [Transform3D(),Transform3D()]
static var strap_fit_gap := Vector2(INF,-INF) # Inner face to skin, (min, max) over both edges and centre.
static var _seat: ArrayMesh
static var _socket: ArrayMesh
static var _cradle: ArrayMesh
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

## Strap solid fitted to the skin's section at x = side*STRAP_X: the outer
## envelope of the centre and both edge sections (polar rays in the y-z plane
## from STRAP_CENTRE), offset BODY_GAP along its own normal. Null when the
## rig cannot be sectioned there (the flat fallback strap is used instead).
static func strap_mesh(skin_mesh: MeshInstance3D, skeleton: Skeleton3D, side: float) -> ArrayMesh:
	var key := 0 if side < 0.0 else 1
	if _strap_meshes[key]: return _strap_meshes[key]
	var triangles := _rooted_back_triangles(skin_mesh,skeleton)
	if triangles.is_empty(): return null
	var centre_x := side*STRAP_X
	var half := STRAP_SIZE.x*.5
	var slices: Array = []
	for x: float in [centre_x-half,centre_x,centre_x+half]:
		var segments: Array[PackedVector2Array] = []
		for face: PackedVector3Array in triangles:
			var hits := PackedVector2Array()
			for edge: int in 3:
				var a: Vector3 = face[edge]; var b: Vector3 = face[(edge+1)%3]
				if (a.x-x)*(b.x-x) < 0.0:
					var hit := a.lerp(b,(x-a.x)/(b.x-a.x))
					hits.append(Vector2(hit.z,hit.y))
			if hits.size() == 2: segments.append(hits)
		slices.append(segments)
	# Stations every degree from the plate edge to the roof end.
	var points: Array[Vector2] = []
	var spread: Array[float] = []
	var angle := atan2(STRAP_BOTTOM-STRAP_CENTRE.y,.19-STRAP_CENTRE.x)
	while angle < PI*.5:
		var direction := Vector2(cos(angle),sin(angle))
		var reach: Array[float] = []
		for segments: Array in slices: reach.append(_section_ray(segments,direction))
		var far: float = reach.max()
		if far <= 0.0: return null
		var point := STRAP_CENTRE+direction*far
		if point.x <= STRAP_END_Z and not points.is_empty():
			# Interpolate the exact roof end between this and the last station.
			var last: Vector2 = points[-1]
			points.append(last.lerp(point,(last.x-STRAP_END_Z)/maxf(last.x-point.x,1e-6)))
			spread.append(far-reach.min())
			break
		points.append(point)
		spread.append(far-reach.min())
		angle += deg_to_rad(1.0)
	if points.size() < 8 or points[-1].x > STRAP_END_Z+.001: return null
	var normals: Array[Vector2] = []
	for index: int in points.size():
		var tangent: Vector2 = points[mini(index+1,points.size()-1)]-points[maxi(index-1,0)]
		var normal := Vector2(tangent.y,-tangent.x).normalized()
		if normal.dot(points[index]-STRAP_CENTRE) < 0.0: normal = -normal
		normals.append(normal)
	var vertices := PackedVector3Array(); var face_normals := PackedVector3Array()
	var rings: Array = []
	for index: int in points.size():
		var inner: Vector2 = points[index]+normals[index]*BODY_GAP
		var outer: Vector2 = points[index]+normals[index]*(BODY_GAP+STRAP_SIZE.z)
		rings.append([Vector3(centre_x-half,inner.y,inner.x),Vector3(centre_x+half,inner.y,inner.x),
			Vector3(centre_x+half-STRAP_CHAMFER,outer.y,outer.x),Vector3(centre_x-half+STRAP_CHAMFER,outer.y,outer.x)])
	for index: int in points.size()-1:
		var a: Array = rings[index]; var b: Array = rings[index+1]
		var n := Vector3(0,normals[index].y,normals[index].x)
		_append_outward_quad(vertices,face_normals,a[0],a[1],b[1],b[0],-n)
		_append_outward_quad(vertices,face_normals,a[3],a[2],b[2],b[3],n)
		_append_outward_quad(vertices,face_normals,a[1],a[2],b[2],b[1],Vector3.RIGHT)
		_append_outward_quad(vertices,face_normals,a[0],a[3],b[3],b[0],Vector3.LEFT)
	var first: Array = rings[0]; var last: Array = rings[-1]
	var start_out := points[0]-points[1]; var end_out := points[-1]-points[-2]
	_append_outward_quad(vertices,face_normals,first[0],first[1],first[2],first[3],Vector3(0,start_out.y,start_out.x))
	_append_outward_quad(vertices,face_normals,last[0],last[1],last[2],last[3],Vector3(0,end_out.y,end_out.x))
	var arrays: Array=[]; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=vertices; arrays[Mesh.ARRAY_NORMAL]=face_normals
	_strap_uv(arrays,centre_x)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	_strap_meshes[key] = mesh
	var end_normal := Vector3(0,normals[-1].y,normals[-1].x)
	var end_point: Vector2 = points[-1]-(points[-1]-points[-2]).normalized()*.018+normals[-1]*(BODY_GAP+STRAP_SIZE.z)
	_strap_ends[key] = Transform3D(Basis(Vector3.RIGHT,end_normal,Vector3.RIGHT.cross(end_normal)).orthonormalized(),Vector3(centre_x,end_point.y,end_point.x)+end_normal*.003)
	for gap: float in spread:
		strap_fit_gap.x = minf(strap_fit_gap.x,BODY_GAP)
		strap_fit_gap.y = maxf(strap_fit_gap.y,BODY_GAP+gap)
	return mesh

## Rivet pose at a fitted strap's roof end (cylinder axis = the roof normal).
static func strap_end(side: float) -> Transform3D:
	return _strap_ends[0 if side < 0.0 else 1]

static func _section_ray(segments: Array, direction: Vector2) -> float:
	var far := -1.0
	for segment: PackedVector2Array in segments:
		var a: Vector2 = segment[0]-STRAP_CENTRE
		var span: Vector2 = segment[1]-segment[0]
		var denominator := direction.cross(span)
		if absf(denominator) < 1e-12: continue
		var t := a.cross(span)/denominator
		var u := a.cross(direction)/denominator
		if t > 0.0 and u >= 0.0 and u <= 1.0: far = maxf(far,t)
	return far

static func _rooted_back_triangles(skin_mesh: MeshInstance3D, skeleton: Skeleton3D) -> Array[PackedVector3Array]:
	var result: Array[PackedVector3Array] = []
	if not skin_mesh or not skin_mesh.mesh or not skin_mesh.skin or not skeleton: return result
	var skin: Skin = skin_mesh.skin
	var root_bind := -1
	for bind: int in skin.get_bind_count():
		if skin.get_bind_bone(bind)==0 or skin.get_bind_name(bind)==skeleton.get_bone_name(0):
			root_bind=bind
			break
	if root_bind<0: return result
	var body_from_mesh := Transform3D(skeleton.get_bone_global_rest(0).basis,Vector3.ZERO)*skin.get_bind_pose(root_bind)
	for surface: int in skin_mesh.mesh.get_surface_count():
		var arrays := skin_mesh.mesh.surface_get_arrays(surface)
		if arrays[Mesh.ARRAY_BONES]==null or arrays[Mesh.ARRAY_WEIGHTS]==null: continue
		var points: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var joints: PackedInt32Array=arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array=arrays[Mesh.ARRAY_WEIGHTS]
		var indices: PackedInt32Array=arrays[Mesh.ARRAY_INDEX]
		var stride := 8 if skin_mesh.mesh.surface_get_format(surface)&Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS else 4
		for offset: int in range(0,indices.size(),3):
			var face := PackedVector3Array()
			var rooted := true
			for corner: int in 3:
				var index: int = indices[offset+corner]
				var root_weight := 0.0
				for slot: int in stride:
					if joints[index*stride+slot]==root_bind: root_weight+=weights[index*stride+slot]
				if root_weight<=.999: rooted=false
				face.append(body_from_mesh*points[index])
			# Root-rigid back and roof only: the strap moves rigidly with them.
			if rooted and maxf(face[0].z,maxf(face[1].z,face[2].z))>.05 and maxf(face[0].y,maxf(face[1].y,face[2].y))>STRAP_BOTTOM-.05: result.append(face)
	return result

static func _append_outward_quad(vertices: PackedVector3Array, normals: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3, outward: Vector3) -> void:
	# Clockwise seen from outside (negative signed volume), like every holder solid.
	if (b-a).cross(c-a).dot(outward) > 0.0:
		var swap := b; b = d; d = swap
	_append_mount_triangle(vertices,normals,a,b,c)
	_append_mount_triangle(vertices,normals,a,c,d)

static func _strap_uv(arrays: Array, centre_x: float) -> void:
	# U across the strap, V along its arc (angle about the section origin).
	var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array=arrays[Mesh.ARRAY_NORMAL]
	var uv:=PackedVector2Array()
	var tangents:=PackedFloat32Array()
	for index: int in vertices.size():
		var p: Vector3=vertices[index]
		var n: Vector3=normals[index]
		uv.append(Vector2((p.x-centre_x)/STRAP_SIZE.x+.5,atan2(p.y-STRAP_CENTRE.y,p.z-STRAP_CENTRE.x)*.25/STRAP_SIZE.x))
		var u:=Vector3.RIGHT.slide(n)
		if u.length_squared()<1e-6: u=Vector3.UP.slide(n)
		u=u.normalized()
		tangents.append_array(PackedFloat32Array([u.x,u.y,u.z,1.0]))
	arrays[Mesh.ARRAY_TEX_UV]=uv
	arrays[Mesh.ARRAY_TANGENT]=tangents

static func measured_back(skin_mesh: MeshInstance3D, skeleton: Skeleton3D) -> float:
	# Rear-most root-rigid skin inside the plate footprint, in holder axes. A
	# fallback plate then still sits BODY_GAP off the real back, never floats.
	if not skin_mesh or not skin_mesh.mesh or not skin_mesh.skin or not skeleton: return MEASURED_BACK
	var skin: Skin = skin_mesh.skin
	var root_bind := -1
	for bind: int in skin.get_bind_count():
		if skin.get_bind_bone(bind)==0 or skin.get_bind_name(bind)==skeleton.get_bone_name(0):
			root_bind=bind
			break
	if root_bind<0: return MEASURED_BACK
	var body_from_mesh := Transform3D(skeleton.get_bone_global_rest(0).basis,Vector3.ZERO)*skin.get_bind_pose(root_bind)
	var back := -INF
	for surface: int in skin_mesh.mesh.get_surface_count():
		var arrays := skin_mesh.mesh.surface_get_arrays(surface)
		if arrays[Mesh.ARRAY_BONES]==null or arrays[Mesh.ARRAY_WEIGHTS]==null: continue
		var points: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		for point: Vector3 in points:
			var local: Vector3 = body_from_mesh*point
			if absf(local.x)<=SEAT_SIZE.x*.5 and local.y>=SEAT_ORIGIN.y-SEAT_SIZE.y*.5 and local.y<=SEAT_ORIGIN.y+SEAT_SIZE.y*.5:
				back=maxf(back,local.z)
	return back if back>.05 and back<.40 else MEASURED_BACK

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
	# Clip the closed bevelled bronze stock into a tapered gusset: full depth
	# where it bears on the plate (local -Z), its underside rising toward the
	# shelf's free end (local +Z) so the bracket reads as a cantilever.
	var inward:=Vector3(0,SOCKET_SIZE.z*.75,-SOCKET_SIZE.y*.5).normalized()
	var boundary:=inward.dot(Vector3(0,-SOCKET_SIZE.y*.5,-SOCKET_SIZE.z*.25))
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

static func cradle_mesh() -> ArrayMesh:
	# Closed U-profile rubber cradle (one material solid): the base slab plus
	# two side lips, extruded along the shaft (local X). Clockwise front faces
	# like every other holder solid, so the 2 kg volume integral stays valid.
	if _cradle: return _cradle
	var hz := PAD_SIZE.z*.5
	var hy := PAD_SIZE.y*.5
	var inner := hz-LIP_WIDTH
	var top := hy+LIP_HEIGHT
	# Outline in (z, y), counter-clockwise seen from +X.
	var outline := PackedVector2Array([Vector2(-hz,-hy),Vector2(hz,-hy),Vector2(hz,top),Vector2(inner,top),
		Vector2(inner,hy),Vector2(-inner,hy),Vector2(-inner,top),Vector2(-hz,top)])
	var hx := PAD_SIZE.x*.5
	var vertices := PackedVector3Array(); var normals := PackedVector3Array()
	var caps := Geometry2D.triangulate_polygon(outline)
	for offset: int in range(0,caps.size(),3):
		var a: Vector2 = outline[caps[offset]]; var b: Vector2 = outline[caps[offset+1]]; var c: Vector2 = outline[caps[offset+2]]
		# Caps and sides wound clockwise seen from outside (negative signed volume).
		_append_mount_triangle(vertices,normals,Vector3(hx,a.y,a.x),Vector3(hx,b.y,b.x),Vector3(hx,c.y,c.x))
		_append_mount_triangle(vertices,normals,Vector3(-hx,c.y,c.x),Vector3(-hx,b.y,b.x),Vector3(-hx,a.y,a.x))
	for edge: int in outline.size():
		var p: Vector2 = outline[edge]; var q: Vector2 = outline[(edge+1)%outline.size()]
		var p0 := Vector3(-hx,p.y,p.x); var p1 := Vector3(hx,p.y,p.x)
		var q0 := Vector3(-hx,q.y,q.x); var q1 := Vector3(hx,q.y,q.x)
		_append_mount_triangle(vertices,normals,q1,p1,p0)
		_append_mount_triangle(vertices,normals,q0,q1,p0)
	var arrays: Array=[]; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=vertices; arrays[Mesh.ARRAY_NORMAL]=normals
	_cradle=ArrayMesh.new()
	_cradle.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	return _cradle

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

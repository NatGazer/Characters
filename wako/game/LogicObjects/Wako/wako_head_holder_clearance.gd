extends RefCounted
## Exact finite self clearance for the installed back cradle. The original
## union remains the broadphase; empty gaps between solids never reject a
## capsule. Current immutable meshes are cached by their actual identity.
const RADIUS := .085
const RADIUS_SQUARED := RADIUS*RADIUS
var valid := false
var mesh_count := 0
var native_count := 0
var seat_prisms := 0
var rebuilds := 0
var _signature: Array = []
var _mesh_data: Dictionary = {}
var _node_components: Dictionary = {}
var _components: Array[Dictionary] = []
var _broad := AABB()

func capture(holder: Node3D) -> void:
	var signature: Array = []
	for node: Node in holder.get_children():
		if node is MeshInstance3D and node.mesh:
			signature.append([node.get_instance_id(),node.mesh.get_instance_id(),node.transform])
	for node: Node in holder.find_children("*","CollisionShape3D",true,false):
		if node is CollisionShape3D and node.shape:
			signature.append([node.get_instance_id(),node.shape.get_instance_id(),node.transform,(node.shape as BoxShape3D).size if node.shape is BoxShape3D else Vector3.ZERO])
	if valid and signature==_signature: return
	_signature=signature
	valid=false
	_components.clear()
	mesh_count=0
	native_count=0
	seat_prisms=0
	for node: Node in holder.get_children():
		if not node is MeshInstance3D or not node.mesh: continue
		var identity: int=node.mesh.get_instance_id()
		if not _mesh_data.has(identity): _mesh_data[identity]=_mesh_solids(node.mesh,String(node.name)=="RootSeat")
		var originals: Array=_mesh_data[identity]
		if originals.is_empty(): return
		var component: Dictionary=_component(node.get_instance_id(),[identity,node.transform],originals,node.transform)
		if component.is_empty(): return
		_components.append(component)
		mesh_count+=1
		if String(node.name)=="RootSeat": seat_prisms=originals.size()
	for node: Node in holder.find_children("*","CollisionShape3D",true,false):
		if not node is CollisionShape3D or not node.shape: continue
		# These are the two actual finite native catch boxes. A future unknown
		# shape refuses admission rather than silently disappearing from it.
		if not node.shape is BoxShape3D: return
		var size: Vector3=(node.shape as BoxShape3D).size
		var component: Dictionary=_component(node.get_instance_id(),[node.shape.get_instance_id(),node.transform,size],[_box_faces(size)],node.transform)
		if component.is_empty(): return
		_components.append(component)
		native_count+=1
	if mesh_count!=11 or native_count!=2: return
	var union: AABB=_components[0].bounds
	for component: Dictionary in _components: union=union.merge(component.bounds)
	_broad=union.grow(RADIUS)
	rebuilds+=1
	valid=true

func _component(identity: int,signature: Array,originals: Array,frame: Transform3D) -> Dictionary:
	var prior: Dictionary=_node_components.get(identity,{})
	if not prior.is_empty() and prior.signature==signature: return prior.component
	var result: Dictionary=_freeze(originals,frame)
	_node_components[identity]={"signature":signature,"component":result}
	return result

func intersects(a: Vector3,b: Vector3) -> bool:
	if not valid or not a.is_finite() or not b.is_finite(): return true
	if _broad.intersects_segment(a,b)==null: return false
	for component: Dictionary in _components:
		var broad: AABB=component.broad
		if broad.intersects_segment(a,b)==null: continue
		for solid: Dictionary in component.solids:
			var bounds: AABB=solid.broad
			if bounds.intersects_segment(a,b)!=null and _capsule_hits_solid(a,b,solid): return true
	return false

static func _mesh_solids(mesh: Mesh,seat: bool) -> Array:
	var triangles:=PackedVector3Array()
	for surface: int in mesh.get_surface_count():
		var arrays: Array=mesh.surface_get_arrays(surface)
		var points: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array=arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX]!=null else PackedInt32Array()
		if points.is_empty(): return []
		if indices.is_empty(): triangles.append_array(points)
		else:
			for index: int in indices:
				if index<0 or index>=points.size(): return []
				triangles.append(points[index])
	if triangles.is_empty() or triangles.size()%3!=0: return []
	for point: Vector3 in triangles:
		if not point.is_finite(): return []
	# The body-fitted mesh is precisely 48 closed triangular prisms, each
	# authored as eight consecutive triangles. The original 44-triangle
	# fallback and every other holder mesh are individual closed convex solids.
	if seat and triangles.size()==48*24:
		var solids: Array=[]
		for offset: int in range(0,triangles.size(),24): solids.append(triangles.slice(offset,offset+24))
		return solids
	if seat and triangles.size()!=44*3: return []
	return [triangles]

static func _freeze(originals: Array,frame: Transform3D) -> Dictionary:
	if not frame.origin.is_finite() or not is_finite(frame.basis.determinant()) or frame.basis.determinant()<=.000001: return {}
	var solids: Array[Dictionary]=[]
	var aggregate:=AABB()
	var found:=false
	for original: PackedVector3Array in originals:
		var triangles:=PackedVector3Array()
		var centre:=Vector3.ZERO
		for point: Vector3 in original:
			var transformed: Vector3=frame*point
			triangles.append(transformed)
			centre+=transformed/float(original.size())
		var bounds:=AABB(triangles[0],Vector3.ZERO)
		for point: Vector3 in triangles: bounds=bounds.expand(point)
		var planes: Array[Plane]=[]
		for offset: int in range(0,triangles.size(),3):
			var a: Vector3=triangles[offset]
			var normal: Vector3=(triangles[offset+1]-a).cross(triangles[offset+2]-a)
			if normal.length_squared()<.00000000000000000001: continue
			normal=normal.normalized()
			if normal.dot(centre-a)>0.0: normal=-normal
			var plane:=Plane(normal,normal.dot(a))
			var duplicate:=false
			for existing: Plane in planes:
				if existing.normal.dot(normal)>.999999 and absf(existing.d-plane.d)<.000001:
					duplicate=true
					break
			if not duplicate: planes.append(plane)
		if planes.size()<4: return {}
		# Cached solids must truly be convex. All exact triangles remain for
		# the rounded capsule distance, including bevels and every plate prism.
		for plane: Plane in planes:
			for point: Vector3 in triangles:
				if plane.distance_to(point)>.000002: return {}
		solids.append({"triangles":triangles,"planes":planes,"broad":bounds.grow(RADIUS)})
		aggregate=aggregate.merge(bounds) if found else bounds
		found=true
	return {"bounds":aggregate,"broad":aggregate.grow(RADIUS),"solids":solids} if found else {}

static func _capsule_hits_solid(a: Vector3,b: Vector3,solid: Dictionary) -> bool:
	var entry:=0.0
	var exit:=1.0
	var centreline_hits:=true
	for plane: Plane in solid.planes:
		var first: float=plane.distance_to(a)
		var last: float=plane.distance_to(b)
		if minf(first,last)>RADIUS: return false
		if first>0.0 and last>0.0: centreline_hits=false
		elif first>0.0: entry=maxf(entry,first/(first-last))
		elif last>0.0: exit=minf(exit,first/(first-last))
	if centreline_hits and entry<=exit: return true
	var triangles: PackedVector3Array=solid.triangles
	for offset: int in range(0,triangles.size(),3):
		var x: Vector3=triangles[offset]
		var y: Vector3=triangles[offset+1]
		var z: Vector3=triangles[offset+2]
		if a.distance_squared_to(_closest_triangle(a,x,y,z))<=RADIUS_SQUARED or b.distance_squared_to(_closest_triangle(b,x,y,z))<=RADIUS_SQUARED: return true
		if _segment_distance_squared(a,b,x,y)<=RADIUS_SQUARED or _segment_distance_squared(a,b,y,z)<=RADIUS_SQUARED or _segment_distance_squared(a,b,z,x)<=RADIUS_SQUARED: return true
	return false

static func _closest_triangle(p: Vector3,a: Vector3,b: Vector3,c: Vector3) -> Vector3:
	var ab:=b-a; var ac:=c-a; var ap:=p-a
	var d1:=ab.dot(ap); var d2:=ac.dot(ap)
	if d1<=0.0 and d2<=0.0: return a
	var bp:=p-b; var d3:=ab.dot(bp); var d4:=ac.dot(bp)
	if d3>=0.0 and d4<=d3: return b
	var vc:=d1*d4-d3*d2
	if vc<=0.0 and d1>=0.0 and d3<=0.0: return a+ab*d1/(d1-d3)
	var cp:=p-c; var d5:=ab.dot(cp); var d6:=ac.dot(cp)
	if d6>=0.0 and d5<=d6: return c
	var vb:=d5*d2-d1*d6
	if vb<=0.0 and d2>=0.0 and d6<=0.0: return a+ac*d2/(d2-d6)
	var va:=d3*d6-d5*d4
	if va<=0.0 and d4-d3>=0.0 and d5-d6>=0.0: return b+(c-b)*(d4-d3)/((d4-d3)+(d5-d6))
	return a+ab*(vb/(va+vb+vc))+ac*(vc/(va+vb+vc))

static func _segment_distance_squared(a: Vector3,b: Vector3,c: Vector3,d: Vector3) -> float:
	var u:=b-a; var v:=d-c; var w:=a-c
	var aa:=u.length_squared(); var ee:=v.length_squared(); var ff:=v.dot(w)
	var s:=0.0; var t:=0.0
	if aa<.00000000000000000001 and ee<.00000000000000000001: return w.length_squared()
	if aa<.00000000000000000001: t=clampf(ff/ee,0.0,1.0)
	else:
		var cc:=u.dot(w)
		if ee<.00000000000000000001: s=clampf(-cc/aa,0.0,1.0)
		else:
			var bb:=u.dot(v); var denominator:=aa*ee-bb*bb
			if denominator>.00000000000000000001: s=clampf((bb*ff-cc*ee)/denominator,0.0,1.0)
			t=(bb*s+ff)/ee
			if t<0.0: t=0.0; s=clampf(-cc/aa,0.0,1.0)
			elif t>1.0: t=1.0; s=clampf((bb-cc)/aa,0.0,1.0)
	return (a+u*s).distance_squared_to(c+v*t)

static func _box_faces(size: Vector3) -> PackedVector3Array:
	var points:=PackedVector3Array()
	for x: float in [-.5,.5]:
		for y: float in [-.5,.5]:
			for z: float in [-.5,.5]: points.append(size*Vector3(x,y,z))
	var triangles:=PackedVector3Array()
	for face: Array in [[0,1,3,2],[4,6,7,5],[0,4,5,1],[2,3,7,6],[0,2,6,4],[1,5,7,3]]:
		for index: int in [face[0],face[1],face[2],face[0],face[2],face[3]]: triangles.append(points[index])
	return triangles

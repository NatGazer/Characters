"""Stage 1 of the game LOD: per-part weld + decimate + fresh UV atlas.
Avoids the photogrammetry UV-island problem by discarding the scan UVs entirely
(textures are re-baked from the full-res mesh in stage 2)."""
import bpy, bmesh, numpy as np, json, math
W = './work/'
OUT = '../'
bpy.ops.wm.open_mainfile(filepath=OUT + 'rhinoceros_beetle.blend')
D = np.load(W + 'final_geo.npz'); BJ = json.load(open(W + 'final_bones.json'))
V = D['V']; F = D['F']; VB = D['VB']; MAT = D['MAT']
bones = BJ['bones']
fb = VB[F[:, 0]]
BUDGET = {'body': 7000, 'pronotum': 9000, 'head': 7500, 'abdomen': 1800, 'elytron': 3200,
          'femur': 900, 'tibia': 800, 'tarsus1': 260, 'tarsus2': 240, 'claw': 220,
          'antenna': 220, 'antenna_club': 260, 'wing': 2600}
def budget(bn):
    base = bn.split('.')[0]
    if base in BUDGET: return BUDGET[base]
    return BUDGET[base.split('_')[-1]]
sc = bpy.context.scene
parts = []
for bi, bn in enumerate(bones):
    fm = fb == bi
    if not fm.any(): continue
    FF = F[fm]; v = np.unique(FF); rm = -np.ones(len(V), int); rm[v] = np.arange(len(v))
    me = bpy.data.meshes.new('lod_' + bn)
    me.from_pydata(V[v].tolist(), [], rm[FF].tolist())
    bm = bmesh.new(); bm.from_mesh(me)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new('lod_' + bn, me); sc.collection.objects.link(ob)
    n0 = len(me.polygons); tgt = budget(bn)
    if n0 > tgt:
        dm = ob.modifiers.new('dec', 'DECIMATE'); dm.ratio = tgt / n0; dm.use_collapse_triangulate = True
        bpy.context.view_layer.objects.active = ob
        with bpy.context.temp_override(object=ob, active_object=ob):
            bpy.ops.object.modifier_apply(modifier='dec')
    ob['bone'] = bn
    parts.append(ob)
    print(f'{bn:18s} {n0:7d} -> {len(ob.data.polygons):6d}')
# vertex groups (rigid) + wing smooth weights
S = 0.06; J = json.load(open(W + 'joints.json')); GZ = J['ground_z']
def T(p): p = np.asarray(p, float); return np.array([S * -p[1], S * (p[0] - 2.0), S * (p[2] - GZ)])
def ramp(x, a, b): return np.clip((x - a) / (b - a), 0, 1)
for ob in parts:
    bn = ob['bone']; n = len(ob.data.vertices)
    if bn.startswith('wing.'):
        s = bn[-1]; r = T(J['wing' + s]['root']); tp = T(J['wing' + s]['tip']); d = tp - r
        P = np.array([vv.co for vv in ob.data.vertices]); u = ((P - r) @ d) / (d @ d)
        w_root = 1 - ramp(u, 0.385, 0.455); w_mid = ramp(u, 0.385, 0.455) * (1 - ramp(u, 0.685, 0.755)); w_tip = ramp(u, 0.685, 0.755)
        for gname, w in (('wing.' + s, w_root), ('wing_mid.' + s, w_mid), ('wing_tip.' + s, w_tip)):
            g = ob.vertex_groups.new(name=gname)
            for i in np.where(w > 0)[0]: g.add([int(i)], float(w[i]), 'REPLACE')
    else:
        ob.vertex_groups.new(name=bn).add(list(range(n)), 1.0, 'REPLACE')
    ob.data.polygons.foreach_set('use_smooth', [True] * len(ob.data.polygons))
# join opaque parts / wings separately, UV unwrap each
def join(objs, name):
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs: o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join(); o = bpy.context.view_layer.objects.active; o.name = name; o.data.name = name
    return o
wl = [o for o in parts if o['bone'].startswith('wing.')]; ol = [o for o in parts if not o['bone'].startswith('wing.')]
opaque = join(ol, 'Beetle_Game_Body')
wings = join(wl, 'Beetle_Game_Wings')
for o, margin in ((opaque, 0.0015), (wings, 0.003)):
    bpy.ops.object.select_all(action='DESELECT'); o.select_set(True); bpy.context.view_layer.objects.active = o
    o.data.uv_layers.new(name='UVMap')
    bpy.ops.object.mode_set(mode='EDIT'); bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=margin, area_weight=0.0, correct_aspect=True, scale_to_bounds=True)
    try:
        bpy.ops.uv.pack_islands(rotate=True, margin=margin)
    except Exception as e: print('pack warn', e)
    bpy.ops.object.mode_set(mode='OBJECT')
    print(o.name, 'tris', len(o.data.polygons), 'verts', len(o.data.vertices))
bpy.ops.wm.save_as_mainfile(filepath=W + 'game_stage1.blend')

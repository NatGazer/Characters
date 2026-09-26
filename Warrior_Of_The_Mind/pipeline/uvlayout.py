"""UV layout: pack every material group into its own 0..1 atlas (texel density equalised by 3D area).

* Keeps the construction UVs (metric: metres along/around each piece) in a second UV layer 'pattern'
  used by the texture synthesis for scale-correct patterns.
* Right-side pieces ('.R', '_R_') share the left side's atlas region (mirrored geometry -> same texture).
Input work/model_raw.blend -> output work/model_uv.blend
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, bpy

HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, 'work')

GROUPS = {
    'armor': lambda o: o.name.split('.')[0] in ('vambrace', 'cuff', 'greave', 'lames', 'kneecop', 'lion', 'sabaton',
                                                'cuirass', 'collar', 'belt', 'fauld', 'pauldron', 'chest_medallion', 'chain', 'dagger', 'sword', 'gauntlet'),
    'cloth': lambda o: o.name.startswith(('robe', 'tabard', 'panel', 'stole', 'cape', 'wrap')),
}

def mirror_partner(name):
    if name.endswith('.R'): return name[:-2] + '.L'
    if '_R_' in name: return name.replace('_R_', '_L_')
    if name.endswith('_R'): return name[:-2] + '_L'
    return None

def select_only(objs):
    for o in bpy.context.view_layer.objects: o.select_set(False)
    for o in objs: o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]

SHARED = {  # material -> (size of the shared square in metric-like uv units)
    'gold': 0.05, 'gold_medallion': 0.16, 'armor_orb': 0.04, 'leather_sole': 0.10,
}

def collapse_shared(objs):
    """Faces of 'shared' materials get overlapping uvs in one small square (packed as one island)."""
    for o in objs:
        me = o.data; uv = me.uv_layers['UVMap']
        d = np.zeros(len(me.loops) * 2); uv.data.foreach_get('uv', d); d = d.reshape(-1, 2)
        for p in me.polygons:
            mname = me.materials[p.material_index].name if me.materials else ''
            key = next((k for k in SHARED if mname == k or mname.startswith(k + '.')), None)
            if key is None: continue
            sz = SHARED[key]
            for l in range(p.loop_start, p.loop_start + p.loop_total):
                u, v = d[l]
                if key == 'gold_medallion':
                    d[l] = (-1 + u * sz, v * sz)          # construction uvs are the unit disc
                else:
                    d[l] = (-2 + (u % 1.0) * sz, (v % 1.0) * sz)
        uv.data.foreach_set('uv', d.ravel())

def pack_group(objs, margin=0.004):
    collapse_shared(objs)
    # select only non-shared faces, equalise their texel density by 3D area
    for o in objs:
        me = o.data
        sel = [not any((me.materials[p.material_index].name if me.materials else '') == k or
                       (me.materials[p.material_index].name if me.materials else '').startswith(k + '.') for k in SHARED)
               for p in me.polygons]
        me.polygons.foreach_set('select', sel)
    select_only(objs)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.context.scene.tool_settings.use_uv_select_sync = True
    bpy.ops.uv.average_islands_scale()
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.select_all(action='SELECT')
    # shared islands keep their fixed size relative to the others
    bpy.ops.uv.pack_islands(rotate=True, margin=margin, shape_method='CONCAVE', merge_overlap=True, scale=True)
    bpy.ops.object.mode_set(mode='OBJECT')

def copy_uvs_by_vertex(src, dst, layer='UVMap'):
    """Copy per-corner uvs between meshes with identical vertex/face indexing but possibly reversed
    face winding (mirrored copies): corners are matched by vertex index within each face."""
    ms, md = src.data, dst.data
    if len(ms.polygons) != len(md.polygons) or len(ms.vertices) != len(md.vertices):
        print('WARNING: topology differs', src.name, dst.name); return False
    us = np.zeros(len(ms.loops) * 2); ms.uv_layers[layer].data.foreach_get('uv', us); us = us.reshape(-1, 2)
    vs = np.zeros(len(ms.loops), int); ms.loops.foreach_get('vertex_index', vs)
    vd = np.zeros(len(md.loops), int); md.loops.foreach_get('vertex_index', vd)
    ud = np.zeros((len(md.loops), 2))
    for ps, pd in zip(ms.polygons, md.polygons):
        m = {vs[l]: us[l] for l in range(ps.loop_start, ps.loop_start + ps.loop_total)}
        for l in range(pd.loop_start, pd.loop_start + pd.loop_total):
            ud[l] = m[vd[l]]
    md.uv_layers[layer].data.foreach_set('uv', ud.ravel())
    return True

def main():
    bpy.ops.wm.open_mainfile(filepath=os.path.join(W, 'model_raw.blend'))
    meshes = [o for o in bpy.data.objects if o.type == 'MESH']
    # keep construction uvs as 'pattern'
    for o in meshes:
        uv = o.data.uv_layers.get('UVMap')
        if uv is None: continue
        pat = o.data.uv_layers.new(name='pattern')
        data = np.zeros(len(o.data.loops) * 2); uv.data.foreach_get('uv', data); pat.data.foreach_set('uv', data)
        o.data.uv_layers.active = o.data.uv_layers['UVMap']
        o.data.uv_layers['UVMap'].active_render = True
    for g, sel in GROUPS.items():
        objs = [o for o in meshes if sel(o) and mirror_partner(o.name) is None]
        pack_group(objs)
        # right-side copies take the left atlas uvs
        for o in meshes:
            src = mirror_partner(o.name)
            if sel(o) and src and src in bpy.data.objects:
                copy_uvs_by_vertex(bpy.data.objects[src], o)
        print('packed', g, len(objs))
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(W, 'model_uv.blend'))

if __name__ == '__main__':
    main()

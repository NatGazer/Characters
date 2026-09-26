"""Rasterise geometry attributes into UV-atlas space ("G-buffer in texture space").

For every texel of a material group's atlas: world position P, smooth normal N, material id, object id,
pattern uv (construction metres), and the 3D distance to the piece's real outline (all boundary edges,
and separately to bottom/hem edges and top edges). Texture synthesis (tex_*.py) works on these maps.
Runs under bpy (reads work/model_uv.blend). Output: work/maps_<group>.npz
"""
import sys, os, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, bpy
from numba import njit
from scipy.spatial import cKDTree
import uvlayout, kit

HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, 'work')

@njit(cache=True)
def raster_tris(tuv, attr, out, zbuf, idbuf, tid_offset):
    H, Wd, C = out.shape
    for t in range(tuv.shape[0]):
        x0, y0 = tuv[t, 0]; x1, y1 = tuv[t, 1]; x2, y2 = tuv[t, 2]
        minx = max(int(np.floor(min(x0, x1, x2))), 0); maxx = min(int(np.ceil(max(x0, x1, x2))), Wd - 1)
        miny = max(int(np.floor(min(y0, y1, y2))), 0); maxy = min(int(np.ceil(max(y0, y1, y2))), H - 1)
        den = (y1 - y2) * (x0 - x2) + (x2 - x1) * (y0 - y2)
        if abs(den) < 1e-12: continue
        for y in range(miny, maxy + 1):
            py = y + 0.5
            for x in range(minx, maxx + 1):
                px = x + 0.5
                a = ((y1 - y2) * (px - x2) + (x2 - x1) * (py - y2)) / den
                b = ((y2 - y0) * (px - x2) + (x0 - x2) * (py - y2)) / den
                c = 1.0 - a - b
                # small tolerance so shared edges leave no cracks
                if a < -1e-4 or b < -1e-4 or c < -1e-4: continue
                for k in range(C):
                    out[y, x, k] = a * attr[t, 0, k] + b * attr[t, 1, k] + c * attr[t, 2, k]
                idbuf[y, x] = tid_offset + t
                zbuf[y, x] = 1.0

def mesh_arrays(ob):
    me = ob.data
    me.calc_loop_triangles() if hasattr(me, 'calc_loop_triangles') else None
    V = np.zeros(len(me.vertices) * 3); me.vertices.foreach_get('co', V); V = V.reshape(-1, 3)
    M = np.array(ob.matrix_world); V = V @ M[:3, :3].T + M[:3, 3]
    lt = me.loop_triangles
    tri_loops = np.zeros(len(lt) * 3, int); lt.foreach_get('loops', tri_loops); tri_loops = tri_loops.reshape(-1, 3)
    tri_poly = np.zeros(len(lt), int); lt.foreach_get('polygon_index', tri_poly)
    lv = np.zeros(len(me.loops), int); me.loops.foreach_get('vertex_index', lv)
    uv = np.zeros(len(me.loops) * 2); me.uv_layers['UVMap'].data.foreach_get('uv', uv); uv = uv.reshape(-1, 2)
    pat = np.zeros(len(me.loops) * 2)
    if 'pattern' in me.uv_layers: me.uv_layers['pattern'].data.foreach_get('uv', pat)
    pat = pat.reshape(-1, 2)
    ln = np.zeros(len(me.loops) * 3)
    try:
        me.corner_normals.foreach_get('vector', ln)
    except Exception:
        me.loops.foreach_get('normal', ln)
    ln = ln.reshape(-1, 3) @ M[:3, :3].T
    mi = np.zeros(len(me.polygons), int); me.polygons.foreach_get('material_index', mi)
    mats = [m.name.split('.')[0] for m in me.materials]
    return V, tri_loops, tri_poly, lv, uv, pat, ln, mi, mats

def boundary_points(ob, V, mats_ok, step=0.002):
    """Sample boundary edges (edges with one face among allowed-material faces); class by side."""
    me = ob.data
    mi = np.zeros(len(me.polygons), int); me.polygons.foreach_get('material_index', mi)
    edge_faces = {}
    cents = {}
    for p in me.polygons:
        if not mats_ok[mi[p.index]]: continue
        vs = list(p.vertices); cents[p.index] = V[vs].mean(0)
        for i in range(len(vs)):
            e = tuple(sorted((vs[i], vs[(i + 1) % len(vs)])))
            edge_faces.setdefault(e, []).append(p.index)
    pts, cls = [], []
    for e, fs in edge_faces.items():
        if len(fs) != 1: continue
        a, b = V[e[0]], V[e[1]]; mid = (a + b) / 2
        d = cents[fs[0]] - mid
        horiz = np.linalg.norm(d[:2])
        c = 1 if d[2] > 0.5 * horiz else (2 if d[2] < -0.5 * horiz else 0)   # 1 = bottom/hem edge, 2 = top edge
        n = max(int(np.linalg.norm(b - a) / step), 1)
        for t in np.linspace(0, 1, n + 1):
            pts.append(a + (b - a) * t); cls.append(c)
    return np.array(pts).reshape(-1, 3), np.array(cls)

def bake_group(group, res, objs_filter=None):
    sel = uvlayout.GROUPS.get(group)
    objs = [o for o in bpy.data.objects if o.type == 'MESH' and (sel(o) if sel else o.name in objs_filter)
            and uvlayout.mirror_partner(o.name) is None]
    C = 3 + 3 + 2          # P, N, pattern uv
    out = np.zeros((res, res, C), np.float32)
    cov = np.zeros((res, res), np.float32)
    tid = np.full((res, res), -1, np.int64)
    tri_obj, tri_mat, mat_names = [], [], []
    offset = 0
    t0 = time.time()
    for oi, ob in enumerate(objs):
        V, tl, tp, lv, uv, pat, ln, mi, mats = mesh_arrays(ob)
        P = V[lv[tl]]                           # (T,3,3)
        N = ln[tl]
        PU = pat[tl]
        tuv = np.stack([uv[tl][..., 0] * res, (1 - uv[tl][..., 1]) * res], -1)
        attr = np.concatenate([P, N, PU], -1).astype(np.float64)
        raster_tris(tuv.astype(np.float64), attr, out, cov, tid, offset)
        gm = []
        for m in mats:
            if m not in mat_names: mat_names.append(m)
            gm.append(mat_names.index(m))
        tri_obj.append(np.full(len(tl), oi)); tri_mat.append(np.array(gm)[mi[tp]])
        offset += len(tl)
    tri_obj = np.concatenate(tri_obj); tri_mat = np.concatenate(tri_mat)
    mask = tid >= 0
    obj_id = np.full((res, res), -1, np.int16); mat_id = np.full((res, res), -1, np.int16)
    obj_id[mask] = tri_obj[tid[mask]]; mat_id[mask] = tri_mat[tid[mask]]
    print(f'{group}: rasterised {offset} tris in {time.time() - t0:.1f}s, coverage {mask.mean():.3f}')
    # distances to outlines (per object, 3D)
    D = np.full((res, res, 3), 1.0, np.float32)   # all, hem, top
    for oi, ob in enumerate(objs):
        V, *_ = mesh_arrays(ob)
        mats = [m.name.split('.')[0] for m in ob.data.materials]
        ok = [m not in kit.SHARED_UV for m in mats]
        bp, bc = boundary_points(ob, V, ok)
        m = obj_id == oi
        if not m.any() or len(bp) == 0: continue
        q = out[m][:, :3]
        for k, cm in enumerate([None, 1, 2]):
            pts = bp if cm is None else bp[bc == cm]
            if len(pts) == 0: continue
            d, _ = cKDTree(pts).query(q, k=1, workers=4)
            D[m, k] = d
    print(f'{group}: distances done {time.time() - t0:.1f}s')
    np.savez_compressed(os.path.join(W, f'maps_{group}.npz'), P=out[..., :3], N=out[..., 3:6], pat=out[..., 6:8],
                        D=D, obj=obj_id, mat=mat_id, mask=mask, mat_names=np.array(mat_names),
                        obj_names=np.array([o.name for o in objs]))

if __name__ == '__main__':
    bpy.ops.wm.open_mainfile(filepath=os.path.join(W, 'model_uv.blend'))
    for g, r in [('armor', 4096), ('cloth', 4096)]:
        bake_group(g, r)

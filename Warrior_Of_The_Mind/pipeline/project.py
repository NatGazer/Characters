"""Project the (upscaled) reference images onto texels: visibility by BVH ray casts toward each
reference camera, weights by facing angle, per-view 2D alignment offsets. Runs under bpy."""
import os
import numpy as np, cv2
from mathutils import Vector
from mathutils.bvhtree import BVHTree
import bpy
import views, texlib as T

def scene_bvh(exclude=('hair',)):
    Vs, Fs, off = [], [], 0
    dg = bpy.context.evaluated_depsgraph_get()
    for ob in bpy.data.objects:
        if ob.type != 'MESH' or ob.name.startswith(exclude): continue
        oe = ob.evaluated_get(dg); me = oe.to_mesh()
        V = np.zeros(len(me.vertices) * 3); me.vertices.foreach_get('co', V); V = V.reshape(-1, 3)
        M = np.array(ob.matrix_world); V = V @ M[:3, :3].T + M[:3, 3]
        Vs.append(V); Fs.extend([[i + off for i in p.vertices] for p in me.polygons]); off += len(V)
        oe.to_mesh_clear()
    V = np.vstack(Vs)
    return BVHTree.FromPolygons([Vector(v) for v in V], Fs)

def visible(bvh, P, N, look, eps=0.0015):
    """True where the ray from P toward the camera (-look) is unobstructed."""
    out = np.zeros(len(P), bool)
    d = Vector((-look[0], -look[1], -look[2]))
    for i in range(len(P)):
        o = Vector(P[i] + N[i] * eps + (-np.asarray(look)) * 0.0005)
        h = bvh.ray_cast(o, d, 5.0)
        out[i] = h[0] is None
    return out

def project(P, N, bvh, view_list=('front', 'left', 'right', 'back'), offsets=None, power=3.0, stride=1, suffix='', warps=None):
    """Returns colour (n,3) float RGB 0..1 and total weight (n,). offsets: {view: (du, dv) ref px}."""
    offsets = offsets or {}
    n = len(P)
    acc = np.zeros((n, 3)); wsum = np.zeros(n)
    for v in view_list:
        look = np.array(views.LOOK[v], float)
        cosv = -(N @ look)
        cand = np.where(cosv > 0.08)[0]
        if len(cand) == 0: continue
        vis = visible(bvh, P[cand], N[cand], look)
        cand = cand[vis]
        uv, _ = views.project(v, P[cand])
        du, dv = offsets.get(v, (0.0, 0.0))
        if warps and v in warps:
            uv = warps[v](uv); du = dv = 0.0
        img = (views.ref_image(v, up=True) if not suffix else cv2.imread(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'work', 'up4', views.VIEWS[v][0] + suffix + '.png')))[..., ::-1].astype(np.float32) / 255
        c = T.sample(img, (uv[:, 0] + du) * 4, (uv[:, 1] + dv) * 4)
        w = np.clip(cosv[cand], 0, 1) ** power
        acc[cand] += c * w[:, None]; wsum[cand] += w
    col = acc / np.maximum(wsum, 1e-6)[:, None]
    return col, wsum

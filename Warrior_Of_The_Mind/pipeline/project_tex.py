"""Project the upscaled reference paintings onto the armour and cloth atlases.

For every atlas texel (maps_<group>.npz: world position P, normal N) and every orthographic reference
view (front, back, left, right):
  * visibility from a z-buffer of the whole model rendered in that view (numba rasteriser,
    same resolution as the 4x upscaled reference), so hair / arms / cape occlude correctly,
  * weight = facing^3, zero near the reference silhouette edge (eroded mask) and at grazing angles,
  * mirrored pieces share texture space: each texel also samples its mirror image (-x) so the left
    and right halves of the painting both contribute (symmetric result, better coverage).
Lighting is flattened with a very low-frequency luminance normalisation (the paintings are softly lit).
Output: work/proj_<group>.npz  (rgb (n,3) float, weight (n,), idx into the atlas)
Runs under bpy (reads the meshes of work/model_uv.blend).
"""
import sys, os, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2, bpy
from numba import njit
import views, texlib as T

HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, 'work')
UP = 4

@njit(cache=True)
def zbuffer(tri_uv, tri_d, H, Wd):
    zb = np.full((H, Wd), 1e9, np.float32)
    for t in range(tri_uv.shape[0]):
        x0, y0 = tri_uv[t, 0]; x1, y1 = tri_uv[t, 1]; x2, y2 = tri_uv[t, 2]
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
                if a < -1e-4 or b < -1e-4 or c < -1e-4: continue
                d = a * tri_d[t, 0] + b * tri_d[t, 1] + c * tri_d[t, 2]
                if d < zb[y, x]: zb[y, x] = d
    return zb

def scene_triangles():
    dg = bpy.context.evaluated_depsgraph_get()
    Ts = []
    for ob in bpy.data.objects:
        if ob.type != 'MESH': continue
        oe = ob.evaluated_get(dg); me = oe.to_mesh(); me.calc_loop_triangles()
        V = np.zeros(len(me.vertices) * 3); me.vertices.foreach_get('co', V); V = V.reshape(-1, 3)
        M = np.array(ob.matrix_world); V = V @ M[:3, :3].T + M[:3, 3]
        tv = np.zeros(len(me.loop_triangles) * 3, int); me.loop_triangles.foreach_get('vertices', tv)
        Ts.append(V[tv.reshape(-1, 3)])
        oe.to_mesh_clear()
    return np.concatenate(Ts)

def delit(view):
    img = views.ref_image(view, up=True).astype(np.float32) / 255
    m = cv2.resize(views.ref_mask(view).astype(np.float32), (img.shape[1], img.shape[0]), interpolation=cv2.INTER_NEAREST)
    lum = img @ np.array([0.11, 0.59, 0.3], np.float32)
    sg = 0.06 / (views.S / UP)                     # ~6 cm
    small = 0.125
    ls = cv2.resize(lum * m, None, fx=small, fy=small, interpolation=cv2.INTER_AREA)
    ms = cv2.resize(m, None, fx=small, fy=small, interpolation=cv2.INTER_AREA)
    low = cv2.GaussianBlur(ls, (0, 0), sg * small) / np.maximum(cv2.GaussianBlur(ms, (0, 0), sg * small), 1e-3)
    low = cv2.resize(low, (img.shape[1], img.shape[0]), interpolation=cv2.INTER_LINEAR)
    target = np.median(lum[m > 0.5])
    gain = np.clip((target / np.maximum(low, 0.03)) ** 0.45, 0.7, 1.6)
    return np.clip(img * gain[..., None], 0, 1)[..., ::-1], m      # RGB

def project_group(group, tris, view_list=('front', 'back', 'left', 'right')):
    d = np.load(os.path.join(W, f'maps_{group}.npz'))
    mask = d['mask']; idx = np.where(mask.ravel())[0]
    P = d['P'].reshape(-1, 3)[idx].astype(np.float64); N = d['N'].reshape(-1, 3)[idx].astype(np.float64)
    N /= np.linalg.norm(N, axis=1, keepdims=True) + 1e-9
    acc = np.zeros((len(idx), 3)); wsum = np.zeros(len(idx))
    for v in view_list:
        t0 = time.time()
        img, m = delit(v)
        H, Wd = m.shape
        me = cv2.erode((m > 0.5).astype(np.uint8), np.ones((9, 9), np.uint8)) > 0
        uv, dd = views.project(v, tris.reshape(-1, 3), scale=UP)
        zb = zbuffer(uv.reshape(-1, 3, 2).astype(np.float64), dd.reshape(-1, 3).astype(np.float64), H, Wd)
        look = np.array(views.LOOK[v], float)
        for mirror in (False, True):
            Pm = P * [-1, 1, 1] if mirror else P
            Nm = N * [-1, 1, 1] if mirror else N
            cosv = -(Nm @ look)
            uvp, dp = views.project(v, Pm, scale=UP)
            x = np.clip(uvp[:, 0], 0, Wd - 1.001); y = np.clip(uvp[:, 1], 0, H - 1.001)
            xi = x.astype(int); yi = y.astype(int)
            zref = np.minimum.reduce([zb[yi, xi], zb[np.minimum(yi + 1, H - 1), xi], zb[yi, np.minimum(xi + 1, Wd - 1)]])
            vis = (dp <= zref + 0.006) & (cosv > 0.2) & me[yi, xi]
            w = np.where(vis, np.clip(cosv, 0, 1) ** 3, 0.0) * (0.85 if mirror else 1.0)
            sel = w > 0
            c = T.sample(img, x[sel], y[sel])
            acc[sel] += c * w[sel, None]; wsum[sel] += w[sel]
        print(f'{group} {v}: {time.time() - t0:.1f}s  covered {np.mean(wsum > 0):.3f}')
    rgb = acc / np.maximum(wsum, 1e-6)[:, None]
    np.savez_compressed(os.path.join(W, f'proj_{group}.npz'), rgb=rgb.astype(np.float32), w=wsum.astype(np.float32), idx=idx)

if __name__ == '__main__':
    bpy.ops.wm.open_mainfile(filepath=os.path.join(W, 'model_uv.blend'))
    tris = scene_triangles()
    print('triangles', len(tris))
    for g in ('armor', 'cloth'):
        project_group(g, tris)

"""Dense face fit (replaces face_fit.py).

All 478 MediaPipe landmarks, three reference views:
  * front view  -> X and Z of every landmark
  * left / right profiles -> Y (depth) of the landmarks on the near side of the face (+ midline)
Model landmarks are found by rendering the current head with the same camera and running the same
detector; each landmark pixel is ray-cast onto the mesh (surface point). Each view gets a rigid 2D
alignment (the reference head is not exactly where the body fit puts it) so only *shape* is fitted.
Targets are symmetrised with landmark pairs found by mirroring the (symmetric) model's landmarks.
The head is deformed with a thin-plate spline (neck and back of the scalp anchored); 3 iterations.
Writes work/body.npz (from work/body_prefit.npz) and work/face_align.json (per-view 2D offsets, px).
"""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
from scipy.interpolate import RBFInterpolator
from scipy.spatial import cKDTree
import bl, views
from mathutils import Vector
from mathutils.bvhtree import BVHTree
import mediapipe as mp
from mediapipe.tasks import python as mpt
from mediapipe.tasks.python import vision

HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, 'work')
K = 4
DEPTH_W = 0.9
CROPS = {'front': (422, 40, 582, 200), 'left': (330, 40, 490, 200), 'right': (510, 40, 670, 200)}
face = vision.FaceLandmarker.create_from_options(vision.FaceLandmarkerOptions(
    base_options=mpt.BaseOptions(model_asset_path='/opt/assets/mp/face_landmarker.task'), num_faces=1))

def detect(bgr):
    r = face.detect(mp.Image(image_format=mp.ImageFormat.SRGB, data=cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)))
    if not r.face_landmarks: return None
    h, w = bgr.shape[:2]
    return np.array([[l.x * w, l.y * h, l.z * w] for l in r.face_landmarks[0]])

def ref_lm(view):
    up = views.ref_image(view, up=True)
    ua, va, ub, vb = CROPS[view]
    L = detect(up[va * 4:vb * 4, ua * 4:ub * 4])
    return None if L is None else np.c_[ua + L[:, 0] / 4, va + L[:, 1] / 4, L[:, 2] / 4]

def model_lm(V, F, view, tag):
    sc = bl.reset(); bl.mesh_from_np('body', V, F); bl.workbench(sc)
    sc.display.shading.single_color = (0.62, 0.45, 0.36)
    bl.ref_camera(view, crop=CROPS[view], res_scale=K)
    p = os.path.join(W, f'ff2_{tag}_{view}.png'); bl.render(p)
    L = detect(cv2.imread(p))
    if L is None: return None
    ua, va, _, _ = CROPS[view]
    return np.c_[ua + L[:, 0] / K, va + L[:, 1] / K, L[:, 2] / K]

def surface_points(V, F, view, L2):
    bvh = BVHTree.FromPolygons([Vector(v) for v in V], [list(map(int, f)) for f in F])
    look = np.array(views.LOOK[view], float)
    out = np.full((len(L2), 3), np.nan)
    for i, (u, v) in enumerate(L2[:, :2]):
        o = views.unproject(view, u, v, depth=-3.0)
        h = bvh.ray_cast(Vector(o), Vector(look), 6.0)
        if h[0] is not None: out[i] = np.array(h[0])
    return out

KEY = [33, 133, 159, 145, 362, 263, 386, 374, 1, 4, 2, 98, 327, 61, 291, 0, 17, 13, 14, 152, 10, 70, 105, 107, 336, 334, 300]

def fps(P, n, seed_idx):
    """Farthest-point sampling (keeps seed indices)."""
    chosen = list(seed_idx)
    d = np.min(np.linalg.norm(P[:, None] - P[chosen][None], axis=2), axis=1)
    while len(chosen) < n:
        i = int(np.argmax(d)); chosen.append(i)
        d = np.minimum(d, np.linalg.norm(P - P[i], axis=1))
    return np.array(chosen)

def sculpt(V, L3, head_ctr):
    """Anatomical sculpt on top of the landmark fit (the painting: lean, hollow cheeks under high
    cheekbones, angular jaw, strong forward chin). Gaussian displacements anchored on fitted landmarks."""
    D = np.zeros_like(V)
    def bump(center, direction, amp, radius):
        w = np.exp(-np.sum((V - center) ** 2, axis=1) / (2 * radius ** 2))
        D[:] += w[:, None] * direction * amp
    def outward(p):
        o = p - np.array([0.0, head_ctr[1] + 0.02, p[2]]); o[2] = 0
        return o / (np.linalg.norm(o) + 1e-9)
    for a, b in ((205, 425), (187, 411)):              # cheek hollows (buccal area), both sides
        for idx in (a, b):
            c = L3[idx].copy()
            bump(c, -outward(c), 0.0045 if idx in (205, 425) else 0.0030, 0.017)
    for idx in (116, 345, 123, 352):                   # zygomatic arch: lift and push out
        c = L3[idx]; bump(c, outward(c) + np.array([0, 0, 0.3]), 0.0022, 0.013)
    for idx in (172, 397):                             # jaw angle: sharper, a bit wider and lower
        c = L3[idx]; bump(c, outward(c) + np.array([0, 0.2, -0.6]), 0.0028, 0.014)
    c = L3[152]; bump(c, np.array([0, -1.0, -0.35]), 0.0055, 0.016)       # chin forward and down
    c = 0.5 * (L3[148] + L3[377]); bump(c, np.array([0, -1.0, 0]), 0.0025, 0.014)
    # (no nasal-bridge push: the reference nose is straight)
    # restrict to the face (not the neck / scalp)
    q = V - head_ctr
    mask = ((q[:, 1] < 0.02) & (V[:, 2] > L3[152, 2] - 0.05)).astype(float)
    V = V + D * mask[:, None]
    # carry the landmarks along
    from scipy.spatial import cKDTree
    _, nn = cKDTree(V - D * mask[:, None]).query(L3)
    L3 = L3 + (D * mask[:, None])[nn]
    print('sculpt: max displacement mm', round(float(np.abs(D * mask[:, None]).max()) * 1000, 2))
    return V, L3

def main():
    d = dict(np.load(os.path.join(W, 'body_prefit.npz')))
    V0 = d['V'].copy(); F = d['F']
    jn = json.loads(str(d['jn']))
    head_ctr = np.array(jn['head____head'])
    R = {v: ref_lm(v) for v in CROPS}
    Mf = model_lm(V0, F, 'front', 'neutral')
    S = surface_points(V0, F, 'front', Mf)
    ok = ~np.isnan(S).any(1)
    # pairs by mirroring the symmetric neutral model
    P0 = np.where(ok[:, None], S, 1e3); _, pair = cKDTree(P0).query(P0 * [-1, 1, 1])
    uvm, _ = views.project('front', S)
    align = {}
    shift = np.median(R['front'][ok, :2] - uvm[ok], axis=0); align['front'] = shift.tolist()
    T = S.copy()
    for i in np.where(ok)[0]:
        P = views.unproject('front', *(R['front'][i, :2] - shift)); T[i, 0] = P[0]; T[i, 2] = P[2]
    # depth: MediaPipe's relative landmark depth, calibrated on the model render (true depth known)
    zm = Mf[:, 2]; zr = R['front'][:, 2]
    X = np.c_[zm[ok], np.ones(ok.sum())]
    (kz, cz), *_ = np.linalg.lstsq(X, S[ok, 1], rcond=None)
    print('depth calibration: m per ref px', round(kz, 5), ' (expected ~', views.S, ')')
    dz = (zr - zm) * kz
    dz -= np.median(dz[ok])
    T[:, 1] = S[:, 1] + np.clip(dz, -0.02, 0.02) * DEPTH_W
    # symmetrise
    Tm = T.copy()
    for i in np.where(ok)[0]:
        j = pair[i]
        if ok[j]:
            Tm[i, 0] = 0.5 * (T[i, 0] - T[j, 0]); Tm[i, 1:] = 0.5 * (T[i, 1:] + T[j, 1:])
    T = Tm
    disp = T - S
    # the face oval is covered by beard/hair and its surface point is ill-defined: only X/Z there
    OVAL = [10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379, 378, 400, 377, 152,
            148, 176, 149, 150, 136, 172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109]
    disp[OVAL, 1] *= 0.3
    # outliers
    mag = np.linalg.norm(disp, axis=1); med = np.median(mag[ok]); mad = np.median(np.abs(mag[ok] - med)) + 1e-6
    good = ok & (mag < med + 5 * mad)
    print('landmarks ok', ok.sum(), 'kept', good.sum(), 'median disp mm', round(med * 1000, 2))
    # well-spread subset
    cand = np.where(good)[0]
    sub = fps(S[cand], 150, [np.where(cand == k)[0][0] for k in KEY if k in cand])
    idx = cand[sub]
    chin_z = S[152, 2]
    # ---- global step: anisotropic scale about the head centre + translation, whole head (smooth neck blend)
    G = idx
    A = S[G] - head_ctr; Bt = T[G] - head_ctr
    scl = np.ones(3); tr = np.zeros(3)
    for k in range(3):
        X = np.c_[A[:, k], np.ones(len(A))]
        (sk, tk), *_ = np.linalg.lstsq(X, Bt[:, k], rcond=None)
        scl[k] = np.clip(sk, 0.88, 1.12); tr[k] = tk
    scl[0] = np.clip(scl[0], 0.9, 1.08); scl[1] = 1.0; tr[1] = 0.0
    print('global head scale', np.round(scl, 3), 'shift mm', np.round(tr * 1000, 1))
    def glob(P):
        return head_ctr + (P - head_ctr) * scl + tr
    selg = np.where(V0[:, 2] > chin_z - 0.16)[0]
    tg = np.clip((V0[selg, 2] - (chin_z - 0.16)) / 0.10, 0, 1); wg = (tg * tg * (3 - 2 * tg))[:, None]
    V0 = V0.copy(); V0[selg] = V0[selg] * (1 - wg) + glob(V0[selg]) * wg
    S = glob(S); disp = T - S; disp[OVAL, 1] *= 0.3
    print('after global: mean disp mm', round(np.linalg.norm(disp[idx], axis=1).mean() * 1000, 2))
    USE_PROFILE_DEPTH = False
    Fh = F[((V0[F][:, :, 2] > chin_z - 0.12).all(1))]
    mid = np.where(ok & (np.abs(S[:, 0]) < 0.004) & (S[:, 1] < head_ctr[1] - 0.04))[0]
    lip_z = S[14, 2]
    dY = np.zeros(len(mid)); nv = 0
    for view, sgn in (('left', 1), ('right', -1)):
        ref = views.ref_mask(view)
        sil = views.raster(view, V0, Fh)
        side = 'min' if view == 'left' else 'max'
        def edge(m, r):
            xs = np.where(m[int(r)])[0]
            return np.nan if len(xs) == 0 else (xs.min() if side == 'min' else xs.max())
        zs = S[mid, 2]
        rows_m = np.array([views.project(view, np.array([0, 0, z]))[0][1] for z in zs])
        best = None
        for dv in range(-10, 11):
            em = np.array([edge(sil, r) for r in rows_m]); er = np.array([edge(ref, r + dv) for r in rows_m])
            okk = ~np.isnan(em) & ~np.isnan(er)
            du = np.median(er[okk] - em[okk]); e = np.mean(np.abs(er[okk] - em[okk] - du))
            if best is None or e < best[0]: best = (e, du, dv, er - em - du)
        e, du, dv, res = best
        print(view, 'profile align du,dv', du, dv, 'residual px', round(e, 2))
        align[view] = [float(du), float(dv)]      # silhouette-based alignment (robust)
        # u axis -> world y: left view u = u0 + y/S (sign +1), right view u = u0 - y/S
        dy = res * views.S * (1 if view == 'left' else -1)
        dY += np.nan_to_num(dy); nv += 1
    dY /= max(nv, 1)
    # the reference silhouette below the lower lip includes the beard (~7 mm at the chin, 3 mm mustache)
    beard = np.where(S[mid, 2] < lip_z, 0.007, np.where(S[mid, 2] < S[2, 2], 0.003, 0.0))
    dY = dY + beard           # the skin surface lies behind the beard silhouette (+y is backward)
    dY = np.clip(dY, -0.02, 0.02)
    if USE_PROFILE_DEPTH: disp[mid, 1] = dY
    print('midline depth corrections (mm):', np.round(dY * 1000, 1))
    # side landmarks: no depth target (keep what the TPS interpolates)
    side_mask = np.ones(len(S), bool); side_mask[mid] = False
    if USE_PROFILE_DEPTH: disp[side_mask, 1] = np.nan
    q = V0 - head_ctr
    anc = np.where(((V0[:, 2] < chin_z - 0.07) & (V0[:, 2] > chin_z - 0.16)) | ((q[:, 1] > 0.07) & (V0[:, 2] > chin_z)))[0]
    anc = anc[np.linspace(0, len(anc) - 1, min(400, len(anc))).astype(int)]
    idx = np.unique(np.r_[idx, mid])
    rbfs = []
    for k in range(3):
        fin = ~np.isnan(disp[idx, k])
        src = np.r_[S[idx][fin], V0[anc]]; dk = np.r_[disp[idx][fin, k], np.zeros(len(anc))]
        rbfs.append(RBFInterpolator(src, dk, kernel='thin_plate_spline', smoothing=1e-5, degree=1))
    rbf = lambda P: np.stack([r(P) for r in rbfs], 1)
    V = V0.copy()
    sel = np.where(V0[:, 2] > chin_z - 0.16)[0]
    t = np.clip((V0[sel, 2] - (chin_z - 0.16)) / 0.09, 0, 1); w = (t * t * (3 - 2 * t))[:, None]
    V[sel] += rbf(V0[sel]) * w
    # residual at the landmarks
    Sn = S[idx] + rbf(S[idx])
    print('residual xz mm: mean', round(np.linalg.norm((Sn - T[idx])[:, [0, 2]], axis=1).mean() * 1000, 2))
    L3 = S + rbf(S)
    V, L3 = sculpt(V, L3, head_ctr)
    np.save(os.path.join(W, 'face_landmarks3d.npy'), L3)
    # profile texture alignment from features that are reliable in profile
    L3g = S_all_final = None
    for view, ids in (('left', [263, 1, 2, 291, 152, 4]), ('right', [33, 1, 2, 61, 152, 4])):
        if R[view] is None: continue
        uvm, _ = views.project(view, L3[ids])
        off = np.median(R[view][ids, :2] - uvm, axis=0)
        print(view, 'feature alignment (px):', np.round(off, 1), 'spread', np.round(np.std(R[view][ids, :2] - uvm, axis=0), 1))
        align[view] = off.tolist()
    d['V'] = V
    np.savez(os.path.join(W, 'body.npz'), **d)
    json.dump(align, open(os.path.join(W, 'face_align.json'), 'w'), indent=1)
    ims = []
    for view in CROPS:
        sc = bl.reset(); bl.mesh_from_np('body', V, F); bl.workbench(sc)
        bl.ref_camera(view, crop=CROPS[view], res_scale=K); p = os.path.join(W, f'ff2_final_{view}.png'); bl.render(p)
        ua, va, ub, vb = CROPS[view]
        im = cv2.resize(views.ref_image(view, up=True)[va * 4:vb * 4, ua * 4:ub * 4], ((ub - ua) * K, (vb - va) * K))
        sh = np.array(align.get(view, (0, 0)))
        uvT, _ = views.project(view, T[idx])
        for pnt in uvT: cv2.circle(im, tuple(((pnt + sh - [ua, va]) * K).astype(int)), 3, (0, 255, 0), -1)
        ren = cv2.imread(p)
        # overlay the model silhouette edge onto the reference (shifted by the view alignment)
        ims.append(np.vstack([im, ren]))
    cv2.imwrite(os.path.join(W, 'face_fit2_debug.jpg'), cv2.resize(np.hstack(ims), None, fx=0.5, fy=0.5))

if __name__ == '__main__':
    main()

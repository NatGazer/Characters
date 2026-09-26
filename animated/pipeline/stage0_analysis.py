"""Stage 0: scan analysis (run with plain python3 + numpy/scipy).

Produces in work/:
  main_weld.npz / wb_weld.npz / ww_weld.npz   welded meshes (mm, Blender Z-up)
  gd_<leg>.npy, gd_A<L|R>.npy                  geodesic distance from claws / antenna tips
  wb_elytra_flab.npy                            elytra face labels on the wings-model body
  ely_icp.npy, ely_fit_<S>.npz, main_ely_mask_<S>.npy   elytra closed-pose fit
  wb_icp.npy, ww_X.npy, ww_comp.npy             wings-model registration + hindwings
"""
import numpy as np, os
import gl, geo, icp, nonrigid as nr
from scipy.spatial import cKDTree
from legs_def import LEGS
REPO = os.environ.get('BEETLE_REPO', '../..')
MAIN = REPO + '/cc0-74mm-rhinoceros-beetle-t-dichotom/source/QS1296-W05-1all-7.gltf'
WING = REPO + '/wings/source/QS1462-W24-1-1_alpha.gltf'
os.makedirs('work', exist_ok=True)

# ---- weld
M, _, _ = gl.load(MAIN); m = M[('QS1296-W01-1-1-updated', 0)]
U, FW, inv = gl.weld(m['P'], m['F']); np.savez('work/main_weld.npz', P=U * 1000, F=FW, inv=inv)
Wm, _, _ = gl.load(WING)
for key, fn in ((('body', 0), 'wb_weld'), (('body', 1), 'ww_weld')):
    b = Wm[key]; U2, F2, i2 = gl.weld(b['P'], b['F']); np.savez(f'work/{fn}.npz', P=U2 * 1000, F=F2, inv=i2)

# ---- geodesics
D = np.load('work/main_weld.npz'); P = D['P']; F = D['F']
A, _ = geo.graph(P, F)
for name, tips in LEGS.items(): np.save(f'work/gd_{name}.npy', geo.dist(A, tips))
for name, t in {'AL': 11798, 'AR': 10101}.items(): np.save(f'work/gd_{name}.npy', geo.dist(A, [t]))

# ---- elytra on the wings model (open pose): region + connectivity
W = np.load('work/wb_weld.npz'); PW = W['P']; FWb = W['F']
def comp_faces(mask_v, seedpt):
    fm = mask_v[FWb].all(1); FF = FWb[fm]; n, l = gl.components(FF, len(PW))
    s = np.argmin(np.linalg.norm(PW - seedpt, axis=1) + (~mask_v) * 1e9)
    keep = fm.copy(); keep[fm] = l[FF[:, 0]] == l[s]; return keep
fl = np.zeros(len(FWb), int)
for sg, c in ((1, 1), (-1, 2)):
    msk = (sg * PW[:, 1] > 8.5) & (PW[:, 2] > 0) & (PW[:, 0] > -16) & (PW[:, 0] < 10)
    fl[comp_faces(msk, np.array([-5, sg * 33, 15.0]))] = c
np.save('work/wb_elytra_flab.npy', fl)

# ---- closed-pose elytra: PCA-init rigid ICP -> symmetric similarity -> affine -> non-rigid
res = {}
NM = nr.vnormals(P, F)
for side, sg, c in (('R', 1, 1), ('L', -1, 2)):
    msk = (sg * P[:, 1] > 0.3) & (np.abs(P[:, 1]) < 15.5) & (P[:, 0] > -1) & (P[:, 2] > -7)
    Q = P[msk]; cell = np.floor(Q[:, :2] / 0.4).astype(int)
    key = cell[:, 0] * 100000 + cell[:, 1]; o = np.lexsort((-Q[:, 2], key)); first = np.r_[True, key[o][1:] != key[o][:-1]]
    dst = Q[o][first]; src = PW[np.unique(FWb[fl == c])][::3]
    best = None
    for R0, t0 in icp.pca_inits2(src, dst):
        s, R, t, e = icp.icp(src, dst, 1.0, R0, t0, iters=60, trim=0.8, scale=False)
        if best is None or e < best[3]: best = (s, R, t, e)
    s, R, t, e1, e2 = icp.icp_sym(src, dst, 1.0, best[1], best[2])
    res[side] = dict(s=s, R=R, t=t)
    ff = FWb[fl == c]; v = np.unique(ff); remap = -np.ones(len(PW), int); remap[v] = np.arange(len(v))
    X = s * PW[v] @ R.T + t; FF = remap[ff]
    Tq = cKDTree(X); d, _ = Tq.query(P)
    dst2 = P[(d < 2.5) & (P[:, 0] > -4.5) & (sg * P[:, 1] > -0.2)]
    Af, tf = nr.affine_icp(X, dst2, np.eye(3), np.zeros(3)); X1 = X @ Af.T + tf
    for it in range(4):
        d, _ = cKDTree(X1).query(P)
        tgt = (d < 1.5) & (P[:, 0] > -4.5) & (sg * P[:, 1] > -0.3)
        dstn = P[tgt]; Td = cKDTree(dstn); N1 = nr.vnormals(X1, FF)
        ctr = np.c_[X1[:, 0], np.zeros(len(X1)), np.full(len(X1), -8.0)]
        outer = np.einsum('ij,ij->i', N1, X1 - ctr) > 0
        dd, jj = Td.query(X1[outer]); disp = dstn[jj] - X1[outer]; ok = dd < 2.0
        field, _ = nr.smooth_field(X1[outer][ok], disp[ok], X1, sigma=[1.5, 1.0, 0.7, 0.5][it]); X1 = X1 + field * 0.9
    np.savez(f'work/ely_fit_{side}.npz', P=X1, F=FF, outer=outer)
    np.save(f'work/main_ely_mask_{side}.npy', tgt)
np.save('work/ely_icp.npy', res, allow_pickle=True)

# ---- wings-model body -> main body registration (rear thorax + abdomen, legs excluded)
emask = np.load('work/main_ely_mask_R.npy') | np.load('work/main_ely_mask_L.npy')
legm = np.zeros(len(P), bool)
for n, h in dict(FL=34.5, FR=34, ML=30.5, MR=30, HL=33, HR=33).items(): legm |= np.load(f'work/gd_{n}.npy') < h + 2
wely = np.zeros(len(PW), bool); wely[np.unique(FWb[fl > 0])] = True
tm = (~emask) & (~legm) & (P[:, 0] > -3) & (P[:, 0] < 31) & (np.abs(P[:, 1]) < 12)
sm = (~wely) & (PW[:, 0] > -3) & (PW[:, 0] < 31) & (np.abs(PW[:, 1]) < 11) & (PW[:, 2] > -11) & (PW[:, 2] < 3)
s, R, t, e = icp.icp(PW[sm][::2], P[tm], 1.0, np.eye(3), np.zeros(3), iters=80, trim=0.6, scale=False)
s, R, t, e1, e2 = icp.icp_sym(PW[sm][::2], P[tm], 1.0, R, t, iters=40, trim=0.6)
np.save('work/wb_icp.npy', dict(s=s, R=R, t=t), allow_pickle=True)
Ww = np.load('work/ww_weld.npz'); X = s * Ww['P'] @ R.T + t
n, l = gl.components(Ww['F'], len(X)); np.save('work/ww_X.npy', X); np.save('work/ww_comp.npy', l)
print('stage 0 done')

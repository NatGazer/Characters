"""Long curly hair as textured cards (runs under bpy).

1. Roots: area-weighted samples on the scalp (head vertices above a hairline).
2. Guide strands: position-based dynamics — gravity, root stiffness (volume at the roots),
   follow-the-leader length constraints, collision against the head/body/armour/cape (BVH),
   with a per-strand "volume" offset so the outer layers stand off (bushy look).
3. Curls: helical displacement growing from the root, varied period/phase per strand.
4. Cards: tapered ribbons facing outward, UVs into a procedural strand atlas (hair_tex.py).
Reference: dark brown, long, wavy-to-curly ringlets, mid-back length, centre-ish part, strands falling
in front of the shoulders at the sides.
"""
import os
import numpy as np
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree
import kit
from kit import unit

HEAD_C = np.array([0.0, 0.0, 1.875])
LOOSE_MASK = [None]

def scalp_mask(B):
    V = B.V
    head = B.w['head'] > 0.5
    q = V - HEAD_C
    az = np.arctan2(q[:, 0], -q[:, 1])                 # 0 = front, +-pi = back
    front = np.clip(np.cos(az), 0, 1) ** 1.5
    back = np.clip(-np.cos(az), 0, 1)
    side = np.abs(np.sin(az))
    hairline = 0.034 * front - 0.014 * side - 0.095 * back
    # keep the ears and the face out
    m = head & (q[:, 2] > hairline)
    ear = (np.abs(q[:, 0]) > 0.062) & (q[:, 2] < 0.015) & (q[:, 2] > -0.045) & (np.abs(q[:, 1]) < 0.035)
    return m & ~ear

def sample_roots(B, n, seed=0):
    rng = np.random.default_rng(seed)
    m = scalp_mask(B)
    F = B.F[m[B.F].all(1)]
    P = B.V[F]
    area = 0.5 * np.linalg.norm(np.cross(P[:, 1] - P[:, 0], P[:, 2] - P[:, 0]), axis=1) \
        + 0.5 * np.linalg.norm(np.cross(P[:, 2] - P[:, 0], P[:, 3] - P[:, 0]), axis=1)
    c = P.mean(1) - HEAD_C
    crown = 1 + 1.5 * np.exp(-(c[:, 0] / 0.025) ** 2) * (c[:, 2] > 0.04) + 1.5 * (c[:, 2] > 0.03) * (c[:, 1] < 0.03)
    wts = area * crown
    idx = rng.choice(len(F), n, p=wts / wts.sum())
    a, b = rng.uniform(size=(2, n))
    Q = P[idx]
    pts = (1 - a)[:, None] * ((1 - b)[:, None] * Q[:, 0] + b[:, None] * Q[:, 1]) + a[:, None] * ((1 - b)[:, None] * Q[:, 3] + b[:, None] * Q[:, 2])
    nrm = np.cross(Q[:, 1] - Q[:, 0], Q[:, 3] - Q[:, 0]); nrm = unit(nrm)
    out = unit(pts - HEAD_C)
    nrm = np.where((nrm * out).sum(1, keepdims=True) < 0, -nrm, nrm)
    return pts, nrm

def collider(objs):
    Vs, Fs, off = [], [], 0
    dg = bpy.context.evaluated_depsgraph_get()
    for ob in objs:
        oe = ob.evaluated_get(dg); me = oe.to_mesh()
        V = np.zeros(len(me.vertices) * 3); me.vertices.foreach_get('co', V); V = V.reshape(-1, 3)
        M = np.array(ob.matrix_world); V = V @ M[:3, :3].T + M[:3, 3]
        Vs.append(V); Fs.extend([[i + off for i in p.vertices] for p in me.polygons]); off += len(V)
        oe.to_mesh_clear()
    V = np.vstack(Vs)
    return BVHTree.FromPolygons([Vector(v) for v in V], Fs), V

LOOSE_FRAC = 0.0          # fraction of front-temple roots that become loose face-framing locks (none: all hair back)

def keep_behind(P):
    z = P[..., 2]
    ymin = np.interp(z, [1.73, 1.87, 1.90, 1.93], [0.05, -0.02, -0.06, -1.0])   # behind the ears; nothing on the forehead
    P = P.copy(); P[..., 1] = np.maximum(P[..., 1], ymin)
    xmax = np.interp(z, [1.40, 1.55, 1.72, 1.84, 1.90], [0.16, 0.14, 0.080, 0.105, 1.0])   # gathered behind the neck
    P[..., 0] = np.clip(P[..., 0], -xmax, xmax)
    return P

def simulate(roots, nrm, lengths, stand, bvh, npts=24, iters=140, seed=0):
    rng = np.random.default_rng(seed)
    n = len(roots)
    s = np.linspace(0, 1, npts)
    # comb direction: away from a (slightly off-centre) part line, back and down
    part_x = 0.008
    sidev = np.sign(roots[:, 0] - part_x + 1e-4)
    comb = unit(np.stack([sidev * 0.12, np.full(n, 1.0), np.full(n, -0.10)], 1))      # swept straight back off the forehead
    sides = np.abs(roots[:, 0]) > 0.05
    comb[sides] = unit(np.stack([sidev[sides] * 0.10, np.full(sides.sum(), 1.0), np.full(sides.sum(), -0.35)], 1))   # back over the ears
    backish = roots[:, 1] > 0.02
    comb[backish] = unit(np.stack([sidev[backish] * 0.18, np.full(backish.sum(), 0.55), np.full(backish.sum(), -1.0)], 1))
    front_root = (roots[:, 1] < HEAD_C[1] - 0.05) & (roots[:, 2] > HEAD_C[2] + 0.02)
    rng2 = np.random.default_rng(seed + 5)
    loose = front_root & (np.abs(roots[:, 0]) > 0.045) & (rng2.uniform(size=n) < LOOSE_FRAC)
    comb[loose] = unit(np.stack([sidev[loose] * 1.0, np.full(loose.sum(), -0.12), np.full(loose.sum(), -0.9)], 1))
    LOOSE_MASK[0] = loose
    d0 = unit(nrm * 0.45 + comb * 0.85)
    seg = lengths / (npts - 1)
    X = roots[:, None, :] + d0[:, None, :] * (s[None, :, None] * lengths[:, None, None]) * 0.35
    X[:, :, 2] -= (s[None, :] ** 2) * lengths[:, None] * 0.5
    g = np.array([0, 0, -0.004])
    for it in range(iters):
        X[:, 1:] += g
        # root stiffness: first ~20% of the strand keeps its combed direction (volume)
        k = np.clip(1 - s / 0.22, 0, 1) ** 2 * 0.6
        target = roots[:, None, :] + d0[:, None, :] * (s[None, :, None] * lengths[:, None, None])
        X = X + (target - X) * k[None, :, None]
        X[:, 0] = roots
        # follow-the-leader lengths
        for i in range(1, npts):
            d = X[:, i] - X[:, i - 1]
            X[:, i] = X[:, i - 1] + unit(d) * seg[:, None]
        # all hair falls behind the head: below the temples no strand may come forward of the ears,
        # and lower down it stays on the back (lower face and jaw left uncovered, nothing over the shoulders)
        X[:, 3:] = keep_behind(X[:, 3:])
        # collisions (every other iteration for speed)
        if it % 2 == 0 or it > iters - 10:
            for a in range(n):
                off = 0.006 + stand[a]
                for i in range(2, npts):
                    p = X[a, i]
                    h = bvh.find_nearest(Vector(p), 0.25)
                    if h[0] is None: continue
                    hp = np.array(h[0]); hn = np.array(h[1])
                    d = np.dot(p - hp, hn)
                    if d < off * (0.35 + 0.65 * min(i / 6, 1)):
                        X[a, i] = p + hn * (off * (0.35 + 0.65 * min(i / 6, 1)) - d)
    return X

def curl(X, rng, amp=0.010, period=(0.10, 0.16)):
    n, m, _ = X.shape
    out = X.copy()
    for a in range(n):
        P = X[a]
        T = unit(np.gradient(P, axis=0))
        u = np.cross(T[0], [0, 0, 1.0]); u = unit(u) if np.linalg.norm(u) > 1e-6 else np.array([1., 0, 0])
        U = [u]
        for i in range(1, m):
            v = U[-1] - np.dot(U[-1], T[i]) * T[i]; U.append(unit(v))
        U = np.array(U); Bn = np.cross(T, U)
        L = np.r_[0, np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))]
        per = rng.uniform(*period); ph = rng.uniform(0, 2 * np.pi)
        A = amp * rng.uniform(0.6, 1.3) * np.clip((L / L[-1] - 0.08) / 0.4, 0, 1) ** 1.2
        w = 2 * np.pi * L / per + ph
        out[a] = P + A[:, None] * (np.cos(w)[:, None] * U + np.sin(w)[:, None] * Bn)
    return out

def cards(S, widths, tiles, n_tiles, head_axis=True):
    """Ribbon per strand. S: (n, m, 3). widths (n,), tiles (n,) atlas tile index."""
    n, m, _ = S.shape
    Vs, Fs, UVs = [], [], []
    base = 0
    for a in range(n):
        P = S[a]
        T = unit(np.gradient(P, axis=0))
        c = np.c_[np.zeros(m), np.full(m, 0.02), np.clip(P[:, 2], 1.2, 1.9)] if head_axis else HEAD_C
        out = unit(P - np.where(P[:, 2:3] > 1.78, HEAD_C, c))
        Bn = unit(np.cross(T, out))
        s = np.linspace(0, 1, m)
        w = widths[a] * (1.0 - 0.45 * s ** 1.5) * np.clip(s / 0.04, 0.35, 1)
        L = P - Bn * (w / 2)[:, None]; R = P + Bn * (w / 2)[:, None]
        V = np.empty((2 * m, 3)); V[0::2] = L; V[1::2] = R
        u0 = tiles[a] / n_tiles; u1 = (tiles[a] + 1) / n_tiles
        UV = np.empty((2 * m, 2)); UV[0::2, 0] = u0; UV[1::2, 0] = u1; UV[0::2, 1] = 1 - s; UV[1::2, 1] = 1 - s
        for i in range(m - 1):
            Fs.append([base + 2 * i, base + 2 * i + 1, base + 2 * i + 3, base + 2 * i + 2])
        Vs.append(V); UVs.append(UV); base += 2 * m
    return np.vstack(Vs), Fs, np.vstack(UVs)

def _loose_for(n, roots, nrm, seed):
    rng2 = np.random.default_rng(seed + 5)
    front_root = (roots[:, 1] < HEAD_C[1] - 0.05) & (roots[:, 2] > HEAD_C[2] + 0.02)
    return front_root & (np.abs(roots[:, 0]) > 0.045) & (rng2.uniform(size=n) < LOOSE_FRAC)

def build_hair(B, collider_objs, n_main=1150, n_fly=0, seed=4, n_tiles=8):
    rng = np.random.default_rng(seed)
    bvh, _ = collider(collider_objs)
    roots, nrm = sample_roots(B, n_main + n_fly, seed)
    q = roots - HEAD_C
    back = np.clip(q[:, 1] / 0.09, -1, 1)          # +1 back of head, -1 front
    # length: longest at the back (mid-back), shorter toward the face-framing front strands
    lengths = 0.40 + 0.22 * (back + 1) / 2 + rng.normal(0, 0.035, len(roots))
    stand = rng.uniform(0.005, 0.026, len(roots))                  # layered volume: a full, thick mane
    crown = np.clip((q[:, 2] - 0.02) / 0.08, 0, 1)
    stand += 0.028 * crown * rng.uniform(0.5, 1.0, len(roots))     # volume on top of the head (ref)
    X = simulate(roots, nrm, lengths * np.where(_loose_for(len(roots), roots, nrm, seed), 0.55, 1.0), stand, bvh, seed=seed)
    X = curl(X, rng)
    widths = np.r_[rng.uniform(0.016, 0.026, n_main), rng.uniform(0.006, 0.010, n_fly)]
    widths *= 1.0 + 0.45 * np.clip(-q[:, 1] / 0.08, 0, 1)          # wider cards at the hairline: no scalp showing
    tiles = np.r_[rng.integers(0, n_tiles - 2, n_main), rng.integers(n_tiles - 2, n_tiles, n_fly)]
    V, F, UV = cards(X, widths, tiles, n_tiles)
    p = kit.Part('hair'); p.add(V, F, UV, mat='hair')
    ob = p.build(smooth=True)
    return ob, X


# ----------------------------------------------------------------------------- beard / brows
def _surface_sample(B, weight_fn, n, seed):
    """Area-and-weight-proportional samples on head skin faces: points, normals."""
    rng = np.random.default_rng(seed)
    head = (B.w['head'] + B.w['neck']) > 0.4
    F = B.F[head[B.F].all(1)]
    P = B.V[F]; C = P.mean(1)
    area = 0.5 * np.linalg.norm(np.cross(P[:, 2] - P[:, 0], P[:, 3] - P[:, 1]), axis=1)
    w = area * np.maximum(weight_fn(C), 0)
    idx = rng.choice(len(F), n, p=w / w.sum())
    a, b = rng.uniform(size=(2, n))
    Q = P[idx]
    pts = (1 - a)[:, None] * ((1 - b)[:, None] * Q[:, 0] + b[:, None] * Q[:, 1]) + a[:, None] * ((1 - b)[:, None] * Q[:, 3] + b[:, None] * Q[:, 2])
    nrm = unit(np.cross(Q[:, 1] - Q[:, 0], Q[:, 3] - Q[:, 0]))
    out = unit(pts - HEAD_C); nrm = np.where((nrm * out).sum(1, keepdims=True) < 0, -nrm, nrm)
    return pts, nrm, weight_fn(pts)

def _seg_dist(P, a, b):
    ab = b - a; t = np.clip(((P - a) @ ab) / (ab @ ab), 0, 1)
    return np.linalg.norm(P - (a + t[:, None] * ab), axis=1)

def beard_density(L):
    """Density field (0..1) for the beard from the fitted 3D face landmarks L (478,3)."""
    sub, ulip, llip, chin = L[2], L[0], L[17], L[152]
    mcL, mcR = L[291], L[61]
    jawL, jawR = L[454], L[234]           # cheek sides (ear level)
    cheekL, cheekR = L[345], L[116]
    lip_c = 0.5 * (L[13] + L[14])
    def f(P):
        P = np.atleast_2d(P)
        d_must = np.minimum(_seg_dist(P, 0.5 * (sub + ulip) + [0.0, 0, 0], mcL + [0.004, 0, 0.002]),
                            _seg_dist(P, 0.5 * (sub + ulip), mcR + [-0.004, 0, 0.002]))
        must = np.clip(1 - d_must / 0.0075, 0, 1) ** 0.7
        # goatee: from the lower lip down under the chin, ~4.5 cm wide
        d_goat = _seg_dist(P, llip + [0, 0, -0.004], chin + [0, 0.012, -0.012])
        goat = np.clip(1 - d_goat / 0.028, 0, 1) ** 0.9
        # jaw stubble: below the cheekbone line, in front of the ears, down onto the upper neck
        y_face = P[:, 2] < (0.5 * (cheekL[2] + ulip[2]) - 0.004)
        front = P[:, 1] < (jawL[1] + 0.012)
        below_chin = P[:, 2] > chin[2] - 0.045
        jaw = 0.55 * (y_face & front & below_chin)
        # keep the lips and the corners clear
        lips = np.clip(1 - np.abs(P[:, 2] - lip_c[2]) / 0.009, 0, 1) * (np.abs(P[:, 0]) < abs(mcL[0] - mcR[0]) / 2 + 0.002) \
            * (P[:, 1] < lip_c[1] + 0.02)
        dens = np.maximum.reduce([must, goat, jaw]) * (1 - lips)
        # thin toward the neck
        dens *= np.clip((P[:, 2] - (chin[2] - 0.05)) / 0.03, 0, 1)
        return dens
    return f

def build_beard(B, n=2600, seed=11, n_tiles=8):
    """Sparse fine hairs over the photo-projected stubble: short and flat on the jaw, longer on the
    goatee / mustache. Uses the sparse 'flyaway' atlas tiles so each card shows 1-3 thin hairs."""
    L = np.load(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'work', 'face_landmarks3d.npy'))
    f = beard_density(L)
    pts, nrm, dens = _surface_sample(B, f, n, seed)
    rng = np.random.default_rng(seed)
    down = np.array([0, 0, -1.0])
    tan = unit(down - (nrm @ down)[:, None] * nrm)
    side = np.sign(pts[:, 0])[:, None] * np.array([1.0, 0, 0])[None]
    must = (pts[:, 2] > L[0][2] - 0.004)
    tan = unit(tan + 0.35 * side * must[:, None])
    long_ = dens > 0.8
    length = np.where(long_, rng.uniform(0.006, 0.011, n), rng.uniform(0.0025, 0.0045, n))
    lift = np.where(long_, 0.25, 0.08)
    m = 3
    S = np.zeros((n, m, 3))
    for i in range(m):
        t = i / (m - 1)
        dirv = unit(tan * (1 - lift[:, None]) + nrm * lift[:, None])
        S[:, i] = pts + nrm * 0.0003 + dirv * (length * t)[:, None] + nrm * (0.0004 * np.sin(np.pi * t))
    widths = rng.uniform(0.0015, 0.0025, n)
    tiles = rng.integers(n_tiles - 2, n_tiles, n)           # sparse flyaway tiles
    V, F, UV = cards(S, widths, tiles, n_tiles, head_axis=False)
    UV[:, 1] = 1 - (1 - UV[:, 1]) * 0.25
    p = kit.Part('beard'); p.add(V, F, UV, mat='hair')
    return p.build(smooth=True)

def build_goatee(B, n=1200, seed=13, n_tiles=8):
    """Dense, defined goatee and mustache (the reference's pointed chin beard): longer hairs combed
    down and slightly converging to the chin point, mustache hairs down-and-out over the lip corners."""
    L = np.load(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'work', 'face_landmarks3d.npy'))
    base = beard_density(L)
    chin_z = L[152][2]
    f = lambda P: np.clip((base(P) - 0.55) / 0.45, 0, 1) * (np.atleast_2d(P)[:, 2] > chin_z - 0.006)
    pts, nrm, dens = _surface_sample(B, f, n, seed)
    rng = np.random.default_rng(seed)
    chin = L[152] + np.array([0, -0.002, -0.004])
    must = pts[:, 2] > L[0][2] - 0.006
    down = np.array([0, 0, -1.0])
    toward_chin = unit(chin - pts)
    dirv = np.where(must[:, None], unit(down + np.sign(pts[:, 0])[:, None] * [0.35, 0, 0]), unit(down + 0.35 * toward_chin))
    dirv = unit(dirv - (dirv * nrm).sum(1, keepdims=True) * nrm)          # lie along the skin
    length = np.where(must, rng.uniform(0.004, 0.007, n), rng.uniform(0.005, 0.009, n))
    m = 4; S = np.zeros((n, m, 3))
    for i in range(m):
        t = i / (m - 1)
        S[:, i] = pts + nrm * (0.0005 + 0.0010 * np.sin(np.pi * t * 0.8)) + dirv * (length * t)[:, None]
    V, F, UV = cards(S, rng.uniform(0.003, 0.0042, n), rng.integers(0, n_tiles - 2, n), n_tiles, head_axis=False)
    UV[:, 1] = 1 - (1 - UV[:, 1]) * 0.3
    p = kit.Part('beard_goatee'); p.add(V, F, UV, mat='hair')
    return p.build(smooth=True)

def build_brows(B, n=520, seed=12, n_tiles=8):
    L = np.load(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'work', 'face_landmarks3d.npy'))
    rng = np.random.default_rng(seed)
    parts = []
    for ids in ([55, 65, 52, 53, 46], [285, 295, 282, 283, 276]):     # inner -> outer, lower brow line
        up_ids = [107, 66, 105, 63, 70] if ids[0] == 55 else [336, 296, 334, 293, 300]
        lo = kit.catmull(L[ids], 6); hi = kit.catmull(L[up_ids], 6)
        k = rng.integers(0, len(lo), n // 2); t = rng.uniform(0, 1, n // 2)
        root = lo[k] * (1 - t[:, None]) + hi[k] * t[:, None]
        outward = unit(root - HEAD_C)
        root = root + outward * 0.0012
        along = unit(np.gradient(lo, axis=0))[k]
        along = along * np.sign(np.dot(along[:, 0], np.sign(lo[-1, 0] - lo[0, 0])))[:, None] if False else along
        u = kit.catmull(L[ids], 6)
        # hairs at the inner end point up, the rest point laterally along the brow
        frac = k / (len(lo) - 1)
        dirv = unit(along * (0.4 + 0.6 * frac)[:, None] + np.array([0, 0, 1.0]) * (1 - frac)[:, None] * 0.8)
        length = rng.uniform(0.006, 0.011, n // 2)
        m = 4; S = np.zeros((n // 2, m, 3))
        for i in range(m):
            tt = i / (m - 1)
            S[:, i] = root + dirv * (length * tt)[:, None] + outward * 0.0008 * tt
        V, F, UV = cards(S, rng.uniform(0.002, 0.003, n // 2), rng.integers(0, n_tiles - 2, n // 2), n_tiles, head_axis=False)
        UV[:, 1] = 1 - (1 - UV[:, 1]) * 0.1
        parts.append((V, F, UV))
    allp = kit.Part('brows')
    for V, F, UV in parts: allp.add(V, F, UV, mat='hair')
    return allp.build(smooth=True)

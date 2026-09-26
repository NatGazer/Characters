"""Clothing: robe layers, tabards/front panels, red stoles, the tiered cape. Runs under bpy.

Conventions (see kit.py): theta = 0 front, +pi/2 character's left (+X), pi back, -pi/2 character's right.
Silhouette numbers were read off the gridded references (1.34 mm/px):
  robe half-width  : 0.165 m at the belt -> 0.24 (knee) -> 0.33 (shin) -> 0.41 at the hem
  robe half-depth  : 0.13 -> 0.19 -> 0.23 -> 0.26
  cape hem reaches X = +-0.53 m (front/back views) and Y = +0.39 m (profile)
Cloth is single-sided (rendered double-sided). Folds are procedural (sum of sines with drifting
phase, amplitude growing toward the hem); hems are pointed "handkerchief" / tattered outlines whose
fine lace is carried by the alpha texture.
"""
import math
import numpy as np
import kit
from kit import Frame, ring_piece, peak, unit

RNG = np.random.default_rng(7)

def ellipse_r(th, a, b):
    return 1.0 / np.sqrt((np.sin(th) / a) ** 2 + (np.cos(th) / b) ** 2)

def interp_z(z, zs, vals):
    zs = np.asarray(zs); vals = np.asarray(vals)
    o = np.argsort(zs)
    return np.interp(z, zs[o], vals[o])

ROBE_Z = [1.285, 1.10, 0.90, 0.55, 0.25, 0.0]
ROBE_A = [0.150, 0.168, 0.195, 0.240, 0.275, 0.290]   # straight surcoat, little flare
ROBE_B = [0.120, 0.132, 0.152, 0.182, 0.202, 0.212]

class Folds:
    """Vertical cloth folds: r += sum_k A(z) * w_k * sin(n_k*theta + phase_k(z))."""
    def __init__(self, n=26, seed=1, amp=0.030, z_top=1.28, z_bot=0.15, power=1.4, drift=0.8):
        rng = np.random.default_rng(seed)
        self.ks = [(n, 1.0), (int(n * 0.55), 0.7), (int(n * 1.6), 0.35)]
        self.ph = rng.uniform(0, 2 * np.pi, (3, 2))
        self.amp, self.zt, self.zb, self.pw, self.drift = amp, z_top, z_bot, power, drift
    def __call__(self, th, z):
        s = np.clip((self.zt - z) / (self.zt - self.zb), 0, 1.2)
        A = self.amp * (0.12 + 0.88 * s ** self.pw)
        out = 0
        for (n, w), (p0, p1) in zip(self.ks, self.ph):
            out = out + w * np.sin(n * th + p0 + self.drift * np.sin(p1 + 3 * z))
        return A * out / 1.6

def hem_points(th, base, depth, n_pts, phase=0.0, sharp=1.6, jitter=0.25, seed=0):
    """Handkerchief hem: base height minus pointed drops (n_pts around the full circle)."""
    rng = np.random.default_rng(seed)
    x = (np.asarray(th) + phase) * n_pts / (2 * np.pi)
    f = x - np.floor(x)
    tri = 1 - np.abs(2 * f - 1)                       # 0 at edges, 1 at point centre
    idx = np.floor(x).astype(int) % n_pts
    dj = 1 + jitter * (rng.uniform(-1, 1, n_pts))[idx]
    return base - depth * dj * tri ** sharp

def robe_layer(name, th0, th1, z_top, hem_fn, off=0.0, folds=None, nth=120, nt=36, mat='cloth_dark', curl=None):
    fr = Frame((0, 0.02, 0.0), (0, 0, 1), 1)
    closed = False
    def r_over(TH, T):
        a = interp_z(T, ROBE_Z, ROBE_A) + off; b = interp_z(T, ROBE_Z, ROBE_B) + off
        r = ellipse_r(TH, a, b)
        if folds is not None: r = r + folds(TH, T)
        if curl is not None: r = r + curl(TH, T)
        return r
    V, F, FUV, info = ring_piece(fr, None, hem_fn, z_top, lambda th, t, r: 0 * r, nth=nth, nt=nt,
                                 th0=th0, th1=th1, closed=closed, r_override=r_over)
    p = kit.Part(name); p.add(V, F, FUV=FUV, mat=mat)
    return p, info

def robes():
    parts = []
    # inner robe: long, open at the front-right (the armoured right leg shows through)
    f1 = Folds(n=14, seed=3, amp=0.026, z_top=1.28, z_bot=0.15)       # few, heavy folds
    gap0, gap1 = -0.66, 0.34                           # split front: both armoured legs show when walking
    th0, th1 = gap1, gap0 + 2 * np.pi
    def hem1(th):
        return hem_points(th, 0.30, 0.09, 9, phase=0.3, seed=5, sharp=1.1) - 0.02 * np.cos(th)
    def curl1(TH, T):  # open edges roll outward a little, more toward the hem
        e = np.minimum(np.abs(TH - th0), np.abs(TH - th1))
        return 0.02 * np.exp(-e / 0.06) * np.clip((1.0 - T) / 0.8, 0, 1)
    p, _ = robe_layer('robe_inner', th0, th1, 1.29, hem1, off=0.0, folds=f1, curl=curl1)
    parts.append(p)
    # outer robe: higher hem with large handkerchief points, open at the front
    f2 = Folds(n=12, seed=11, amp=0.030, z_top=1.28, z_bot=0.35)
    th0, th1 = 0.34, 2 * np.pi - 0.34
    def hem2(th):
        return hem_points(th, 0.52, 0.15, 7, phase=0.9, seed=9, sharp=1.1) - 0.04 * np.cos(th)
    def curl2(TH, T):
        e = np.minimum(np.abs(TH - th0), np.abs(TH - th1))
        return 0.03 * np.exp(-e / 0.08) * np.clip((1.1 - T) / 0.8, 0, 1)
    p, _ = robe_layer('robe_outer', th0, th1, 1.28, hem2, off=0.022, folds=f2, curl=curl2)
    parts.append(p)
    return parts

def panel(name, center, half_w, z_top, z_tip, z_side, off, mat='cloth_tabard', folds_amp=0.004, nt=30, nth=14):
    """Flat hanging panel (tabard) following the robe surface, pointed bottom."""
    fr = Frame((0, 0.02, 0.0), (0, 0, 1), 1)
    r_mid = ellipse_r(center, interp_z(z_top, ROBE_Z, ROBE_A), interp_z(z_top, ROBE_Z, ROBE_B))
    dth = half_w / r_mid
    def bot(th):
        x = np.clip(np.abs(th - center) / dth, 0, 1)
        return z_tip + (z_side - z_tip) * x
    def r_over(TH, T):
        a = interp_z(T, ROBE_Z, ROBE_A) + off; b = interp_z(T, ROBE_Z, ROBE_B) + off
        # panels hang straight: blend toward the radius at the top (no flare) as they go down
        rt = ellipse_r(TH, interp_z(z_top, ROBE_Z, ROBE_A) + off, interp_z(z_top, ROBE_Z, ROBE_B) + off)
        r = 0.55 * ellipse_r(TH, a, b) + 0.45 * rt
        return r + folds_amp * np.sin(TH * 60)
    V, F, FUV, info = ring_piece(fr, None, bot, z_top, lambda th, t, r: 0 * r, nth=nth, nt=nt,
                                 th0=center - dth, th1=center + dth, closed=False, r_override=r_over)
    p = kit.Part(name); p.add(V, F, FUV=FUV, mat=mat)
    return p

def tabards():
    parts = []
    parts.append(panel('tabard_front', 0.0, 0.043, 1.28, 0.495, 0.56, 0.05))
    parts.append(panel('panel_front_L', 0.45, 0.085, 1.28, 0.78, 0.86, 0.042))
    parts.append(panel('panel_front_R', -0.40, 0.065, 1.28, 0.80, 0.90, 0.040))
    parts.append(panel('tabard_back', np.pi, 0.046, 1.28, 0.47, 0.54, 0.05))
    parts.append(panel('panel_back_L', np.pi - 0.42, 0.075, 1.28, 0.74, 0.84, 0.044))
    parts.append(panel('panel_back_R', -np.pi + 0.42, 0.075, 1.28, 0.74, 0.84, 0.044))
    return parts

# ----------------------------------------------------------------------------- stoles
def stoles(B, cuirass_info=None):
    """Red stoles: front and back bands from the shoulder (under the pauldron) to the hem."""
    import kit as K
    fr = Frame((0, 0.02, 0.0), (0, 0, 1), 1)
    bvh = B.bvh(['chest', 'belly'])
    parts = []
    width = 0.078
    for side in (1, -1):
        for where in ('front', 'back'):
            zs = np.linspace(1.64, 0.14 if where == 'back' else 0.20, 60)
            if where == 'front':
                # band centre x(z) measured on the front reference (red cloth beside the chest plate,
                # then outside the robe below the belt); converted to theta on the underlying surface
                xz = np.interp(zs, [0.2, 0.5, 0.8, 1.0, 1.2, 1.30, 1.45, 1.64], [0.265, 0.255, 0.225, 0.205, 0.19, 0.185, 0.16, 0.115])
                r_guess = np.where(zs > 1.29, 0.19, np.array([ellipse_r(0.9, interp_z(z, ROBE_Z, ROBE_A), interp_z(z, ROBE_Z, ROBE_B)) for z in zs]) + 0.045)
                th_c = side * np.arcsin(np.clip(xz / r_guess, 0, 0.98))
            else:
                th_c = side * (np.pi - np.interp(zs, [0.14, 0.6, 1.0, 1.3, 1.64], [0.42, 0.36, 0.30, 0.25, 0.30]))
            # underlying radius: torso (ray cast) above the belt, robe below
            r_under = np.zeros_like(zs)
            for i, (z, th) in enumerate(zip(zs, th_c)):
                if z > 1.29:
                    r = K.ray_radius(bvh, fr, np.array([th]), np.array([z]), 0.45)[0]
                    r_under[i] = (r if not np.isnan(r) else 0.16) + 0.034
                else:
                    r_under[i] = ellipse_r(th, interp_z(z, ROBE_Z, ROBE_A), interp_z(z, ROBE_Z, ROBE_B)) + 0.045
            r_under = np.convolve(np.pad(r_under, 3, mode='edge'), np.ones(7) / 7, mode='valid')
            nw = 8
            Vs = []
            for i, z in enumerate(zs):
                dth = width / r_under[i] / 2
                ths = th_c[i] + np.linspace(-dth, dth, nw)
                fold = 0.006 * np.sin(np.linspace(0, np.pi * 2, nw) + z * 9)
                P = fr.point(ths, np.full(nw, z), r_under[i] + fold)
                Vs.append(P)
            V = np.concatenate(Vs)
            F = kit.grid_faces(len(zs), nw)
            seg = np.r_[0, np.cumsum(np.linalg.norm(np.diff(np.array(Vs).mean(1), axis=0), axis=1))]
            UV = np.array([[j / (nw - 1) * width, seg[i]] for i in range(len(zs)) for j in range(nw)])
            p = kit.Part(f'stole_{where}_{"L" if side > 0 else "R"}')
            F = kit.orient_outward(V, F, lambda c: np.c_[np.zeros(len(c)), np.full(len(c), 0.02), c[:, 2]])
            p.add(V, F, UV, mat='cloth_red_stole')
            parts.append(p)
    return parts

# ----------------------------------------------------------------------------- cape
def cape_half(side=1, tiers=None):
    """One half of the split cape (side=+1 left). Surface from column curves (shoulder -> hem),
    three stacked tiers with diagonal tattered hems (outer tiers shorter)."""
    tiers = tiers or [  # (s0, s1, hem z at s0, hem z at s1, radial offset, points, depth)
        (0.00, 1.00, 0.16, 0.30, 0.000, 7, 0.20),
        (0.10, 1.00, 0.72, 0.58, 0.018, 5, 0.26),
        (0.28, 1.00, 1.08, 0.92, 0.034, 4, 0.24),
    ]
    parts = []
    ns, nv = 30, 44
    for ti, (s0, s1, h0, h1, roff, npts, dep) in enumerate(tiers):
        S = np.linspace(s0, s1, ns)
        cols = []
        for s in S:
            ctrl = np.array([
                [0.045 + 0.20 * s, 0.135 - 0.115 * s, 1.615 + 0.06 * s],          # top: upper back -> shoulder
                [0.050 + 0.22 * s, 0.150 - 0.060 * s, 1.500],                      # over the shoulder blade
                [0.055 + 0.22 * s, 0.165 - 0.010 * s, 1.300],                      # behind the arm (hidden in front view)
                [0.065 + 0.36 * s, 0.215 + 0.020 * s, 0.800],
                [0.075 + 0.46 * s, 0.290 + 0.050 * s * (1 - s) * 4 - 0.06 * s, 0.35],
                [0.080 + 0.48 * s, 0.330 - 0.07 * s, -0.10],
            ])
            ctrl[:, 0] *= side
            c = kit.catmull(ctrl, n_per=24)
            cols.append(c)
        cols = np.array(cols)                                  # (ns, m, 3)
        # hem height per column (diagonal) with tattered points, and cut each column there
        hz = h0 + (h1 - h0) * (S - s0) / max(s1 - s0, 1e-6)
        x = (S - s0) / max(s1 - s0, 1e-6) * npts
        f = x - np.floor(x); tri = 1 - np.abs(2 * f - 1)
        hz = hz - dep * tri ** 1.3
        grid = []
        for k in range(ns):
            c = cols[k]
            zc = c[:, 2]
            m = zc >= hz[k]
            cc = c[m]
            # add exact hem point
            j = m.sum()
            if j < len(c):
                a, b = c[j - 1], c[j]
                w = (a[2] - hz[k]) / max(a[2] - b[2], 1e-9)
                cc = np.vstack([cc, a + (b - a) * w])
            grid.append(kit.resample_polyline(cc, n=nv))
        G = np.array(grid)                                     # (ns, nv, 3)
        if ti > 0:
            # outer tiers start lower (sewn on under the shoulder line) and peel away smoothly
            z_start = 1.52 - 0.10 * ti
            G2 = []
            for k in range(ns):
                c = G[k]; m = c[:, 2] <= z_start
                cc = c[m] if m.sum() >= 2 else c[-2:]
                j = np.argmax(m)
                if j > 0:
                    a, b = c[j - 1], c[j]; w = (a[2] - z_start) / max(a[2] - b[2], 1e-9)
                    cc = np.vstack([a + (b - a) * w, cc])
                G2.append(kit.resample_polyline(cc, n=nv))
            G = np.array(G2)
        # folds + tier offset along the outward normal (away from the body axis)
        center = np.zeros_like(G); center[..., 1] = 0.03; center[..., 2] = G[..., 2]
        nrm = unit(G - center)
        vv = np.linspace(0, 1, nv)[None, :]
        ss = S[:, None]
        rng = np.random.default_rng(20 + ti + (0 if side > 0 else 100))
        ph = rng.uniform(0, 6.28, 3)
        fold = (0.004 + 0.034 * vv ** 1.2) * (np.sin(ss * 26 + ph[0] + 1.3 * vv) * 0.7 + 0.4 * np.sin(ss * 47 + ph[1] - 2 * vv)
                                              + 0.3 * np.sin(ss * 11 + ph[2]))
        ramp = np.clip(vv / 0.25, 0, 1) if ti > 0 else np.ones_like(vv)
        G = G + nrm * (fold + roff * (0.15 + 0.85 * ramp))[..., None]
        V = G.reshape(-1, 3)
        F = []
        for i in range(ns - 1):
            for j in range(nv - 1):
                F.append([i * nv + j, i * nv + j + 1, (i + 1) * nv + j + 1, (i + 1) * nv + j])
        F = np.array(F)
        F = kit.orient_outward(V, F, lambda c: np.c_[np.zeros(len(c)), np.full(len(c), 0.03), c[:, 2]])
        # uv: u = across (metres), v = down (metres)
        du = np.linalg.norm(np.diff(G, axis=0), axis=2).mean(1); u = np.r_[0, np.cumsum(du)]
        dv = np.linalg.norm(np.diff(G, axis=1), axis=2).mean(0); v = np.r_[0, np.cumsum(dv)]
        UV = np.stack(np.meshgrid(u, v, indexing='ij'), -1).reshape(-1, 2)
        p = kit.Part(f'cape_{"L" if side > 0 else "R"}_{ti}')
        p.add(V, F, UV, mat='cloth_red_cape')
        parts.append(p)
    return parts

def build_cloth(B, collection=None):
    objs = []
    for p in robes() + tabards() + stoles(B) + cape_half(1) + cape_half(-1):
        objs.append(p.build(collection))
    return objs

"""Cloth atlas textures from maps_cloth.npz -> textures/cloth_{albedo(RGBA),normal,orm,emission}.png

pattern uv = construction metres (u across / around, v down), with a per-component slot shift in u
(multiples of 4 m) that is removed here. D = 3D distance to outline (all / hem(bottom) / top edges).
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import texlib as T

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
W = os.path.join(HERE, 'work'); OUT = os.path.join(ROOT, 'textures')

CRIMSON = np.array([0.42, 0.030, 0.050]); CRIMSON_D = np.array([0.24, 0.012, 0.025])
BLACK = np.array([0.085, 0.074, 0.066]); GOLDT = np.array([0.78, 0.53, 0.22])
EMIT = np.array([1.0, 0.64, 0.26])

def star8(x, y, r_long, r_short, w=0.22):
    """8-point star mask from local offsets (same units as radii)."""
    r = np.sqrt(x * x + y * y) + 1e-9; a = np.arctan2(y, x)
    k = 8; aa = (a + np.pi / k) % (2 * np.pi / k) - np.pi / k
    longr = (np.round(a / (2 * np.pi / k)) % 2 == 0)
    L = np.where(longr, r_long, r_short)
    return ((np.abs(aa) * r < w * r_long * np.clip(1 - r / L, 0, 1)) & (r < L)).astype(np.float32)

def cell_star(u, v, period, r_long, jitter=0.35, seed=0, density=1.0):
    """Stars scattered on a jittered grid in the (u,v) plane (metres). Returns mask."""
    gi = np.floor(u / period); gj = np.floor(v / period)
    h = (gi.astype(np.int64) * 73856093 ^ gj.astype(np.int64) * 19349663 ^ seed * 83492791) % 10007 / 10007.0
    h2 = (gi.astype(np.int64) * 19349663 ^ gj.astype(np.int64) * 83492791 ^ seed * 73856093) % 10007 / 10007.0
    cx = (gi + 0.5 + (h - 0.5) * jitter) * period; cy = (gj + 0.5 + (h2 - 0.5) * jitter) * period
    on = h < density
    s = r_long * (0.7 + 0.6 * h2)
    return star8(u - cx, v - cy, s, s * 0.55) * on

def main():
    d = np.load(os.path.join(W, 'maps_cloth.npz'))
    P = d['P']; N = d['N']; pat = d['pat']; D = d['D']; obj = d['obj']; mat = d['mat']; mask = d['mask']
    mats = list(d['mat_names']); objs = list(d['obj_names'])
    R = P.shape[0]
    dp = np.linalg.norm(P[:, 1:] - P[:, :-1], axis=-1)
    ok = mask[:, 1:] & mask[:, :-1] & (obj[:, 1:] == obj[:, :-1])
    texel = float(np.median(dp[ok])); print('cloth texel mm', texel * 1000, mats)
    idx = np.where(mask.ravel())[0]
    Pm = P.reshape(-1, 3)[idx].astype(np.float64)
    M = mat.ravel()[idx]; Om = obj.ravel()[idx]
    pu = pat.reshape(-1, 2)[idx].astype(np.float64)
    u = pu[:, 0] - np.floor(pu[:, 0] / 4.0 + 1e-9) * 4.0; v = pu[:, 1]
    Dm = D.reshape(-1, 3)[idx]
    d_all, d_hem, d_top = Dm[:, 0], Dm[:, 1], Dm[:, 2]
    # distance to non-top edges (hem + open side edges): the belt/shoulder attachment edges get no border
    d_edge = np.where(d_top <= d_all + 1e-4, np.minimum(d_hem, 1.0), d_all)
    d_edge = np.minimum(d_edge, d_hem)
    near_hem = d_hem <= d_edge + 1e-4
    along = np.where(near_hem, u, v)
    n = len(idx)
    alb = np.zeros((n, 3), np.float32); alpha = np.ones(n, np.float32); rough = np.full(n, 0.85, np.float32)
    metal = np.zeros(n, np.float32); height = np.zeros(n, np.float32); emis = np.zeros(n, np.float32)
    ao = np.ones(n, np.float32)
    def is_(prefix): return np.isin(M, [i for i, m in enumerate(mats) if m.startswith(prefix)])
    nz = T.noise(Pm, 0.004, 5, 2); nlo = T.noise(Pm, 0.15, 6, 3)

    def lace(sel, d_h, al, depth=0.034, seed=0):
        """Tattered lace fringe along the hem: holes + scallops + torn threads (alpha)."""
        x = al[sel]; dh = d_h[sel]
        tear = 0.012 + 0.05 * (T.noise(np.c_[x * 6, np.zeros_like(x), np.full_like(x, seed)], 0.35, seed, 3) * 0.5 + 0.5) ** 1.5 * (depth / 0.036) * 0.6
        threads = (np.abs(np.sin(x * np.pi / 0.0045)) < 0.35) & (dh < tear + 0.012) & (dh > tear * 0.3)
        alpha_edge = (dh > tear) | threads
        # holes: staggered grid in (along, dh)
        row = np.floor(dh / 0.0075); colx = x / 0.0075 + 0.5 * (row % 2)
        fx = colx - np.floor(colx) - 0.5; fy = dh / 0.0075 - row - 0.5
        # jagged torn teeth of random height instead of a regular hole grid
        k = np.floor(x / 0.009); fr = x / 0.009 - k
        hk = (np.abs(np.sin(k * 12.9898 + seed * 78.233)) * 43758.5453) % 1.0
        tooth = (0.35 + 0.65 * hk) * depth * 0.8 * (1 - np.abs(2 * fr - 1)) ** 1.5
        cut = dh > (tear * 0.5 + depth * 0.8 - tooth)
        slits = (np.abs(np.sin(x * np.pi / 0.0031 + hk * 3)) < 0.18) & (dh < tear + depth * 0.5)
        return (alpha_edge & cut & ~slits).astype(np.float32), (dh < depth).astype(np.float32)

    # ------------------------------------------------------------ red: cape / stoles / wraps
    for key in ('cloth_red_cape', 'cloth_red_stole', 'cloth_red_wrap'):
        s = is_(key)
        if not s.any(): continue
        us, vs = u[s], v[s]
        # tonal damask: diamond lattice with a leaf/quatrefoil inside
        p = 0.055
        a1 = (us + vs) / p; a2 = (us - vs) / p
        f1 = np.abs(a1 - np.round(a1)); f2 = np.abs(a2 - np.round(a2))
        lattice = T.line_mask(np.minimum(f1, f2), 0.035, 0.03)
        cx = (us / p) - np.round(us / p); cy = (vs / p) - np.round(vs / p)
        rr = np.sqrt(cx * cx + cy * cy); ang = np.arctan2(cy, cx)
        leaf = T.line_mask(np.abs(rr - (0.22 + 0.08 * np.cos(4 * ang))), 0.035, 0.03)
        damask = np.clip(lattice * 0.8 + leaf, 0, 1)
        base = CRIMSON * (1 + 0.18 * damask[:, None] + 0.10 * nlo[s][:, None] + 0.06 * nz[s][:, None])
        base = base * (1 - 0.25 * (1 - damask[:, None]) * (np.abs(nz[s][:, None]) > 0.3))
        g = np.zeros(s.sum(), np.float32)
        if key == 'cloth_red_cape':
            g = np.maximum(g, cell_star(us, vs, 0.22, 0.030, seed=3, density=0.55))
            g = np.maximum(g, cell_star(us + 0.11, vs + 0.07, 0.13, 0.012, seed=4, density=0.35) * 0.9)
            dh = d_hem[s]
            dh = dh - 0.035
            band = (dh > 0.036) & (dh < 0.105)
            lines = T.line_mask(np.abs(dh - 0.040), 0.0008, texel) + T.line_mask(np.abs(dh - 0.100), 0.0008, texel)
            bx = us - np.round(us / 0.07) * 0.07
            bstar = star8(bx, dh - 0.073, 0.022, 0.012) * band
            arcs = T.line_mask(np.abs(np.sqrt(bx ** 2 + (dh - 0.073) ** 2) - 0.028), 0.0006, texel) * band * (dh > 0.052) * 0.7
            g = np.maximum.reduce([g, np.clip(lines, 0, 1), bstar, arcs * 0.9])
            a_, fringe = lace(s, d_hem, u, 0.045, seed=1)
            alpha[s] = a_
            base = base * (1 - 0.15 * fringe[:, None])
        elif key == 'cloth_red_stole':
            de = d_all[s]
            lines = T.line_mask(np.abs(de - 0.005), 0.0009, texel) + T.line_mask(np.abs(de - 0.010), 0.0005, texel)
            vs2 = vs - np.round(vs / 0.075) * 0.075
            st = star8(vs2, us - 0.039, 0.014, 0.008)
            zig = T.line_mask(np.abs((us - 0.039) - 0.010 * np.sin(vs / 0.0125 * np.pi)), 0.0008, texel) * (np.abs(vs2) > 0.02)
            g = np.clip(lines + st + zig, 0, 1)
            a_, fringe = lace(s, d_hem, u, 0.030, seed=2)
            alpha[s] = a_
        alb[s] = base * (1 - g[:, None]) + GOLDT * g[:, None]
        rough[s] = (0.78 - 0.18 * damask) * (1 - g) + 0.42 * g
        metal[s] = 0.35 * g
        height[s] = 0.00025 * damask + 0.00035 * g + 0.0001 * nz[s]
        emis[s] = 0.10 * g
    # ------------------------------------------------------------ dark robes
    s = is_('cloth_dark')
    if s.any():
        us, vs = u[s], v[s]
        p = 0.038
        a1 = (us + vs) / p; a2 = (us - vs) / p
        f1 = np.abs(a1 - np.round(a1)); f2 = np.abs(a2 - np.round(a2))
        quilt = T.line_mask(np.minimum(f1, f2), 0.03, 0.035)
        puff = np.clip(np.minimum(f1, f2) * 2, 0, 1)
        base = BLACK * (1 + 0.25 * puff[:, None] + 0.15 * nlo[s][:, None] + 0.08 * nz[s][:, None])
        de = d_edge[s]; al = along[s]
        band = (de > 0.007) & (de < 0.052)
        lines = T.line_mask(np.abs(de - 0.008), 0.0010, texel) + T.line_mask(np.abs(de - 0.040), 0.0010, texel) \
            + T.line_mask(np.abs(de - 0.013), 0.0005, texel) + T.line_mask(np.abs(de - 0.035), 0.0005, texel)
        x = (al / 0.032) - np.floor(al / 0.032); y = np.clip((de - 0.015) / 0.018, 0, 1)
        xs = T.line_mask(np.minimum(np.abs(x - y), np.abs(x + y - 1)) * 0.032, 0.0006, texel) * (de > 0.015) * (de < 0.033)
        dots = T.line_mask(np.sqrt(((x - 0.5) * 0.042) ** 2 + (de - 0.0295) ** 2), 0.0016, texel) * band * 0
        stars = cell_star(us, vs, 0.20, 0.018, seed=7, density=0.35) * (de > 0.06)
        gflecks = (T.noise(Pm[s], 0.003, 9, 1) > 0.75) * (de > 0.06) * 0.3
        g = np.clip(lines + xs + dots + stars + gflecks * 0.5, 0, 1)
        alb[s] = base * (1 - g[:, None]) + GOLDT * 0.95 * g[:, None]
        rough[s] = 0.85 * (1 - g) + 0.5 * g; metal[s] = 0.35 * g
        height[s] = 0.0006 * puff - 0.0003 * quilt + 0.00035 * g
        ao[s] = 1 - 0.3 * quilt
        emis[s] = 0.03 * g + 0.25 * stars
        # small dark lace at the robe hem
        dh = d_hem[s]
        tear = 0.004 + 0.010 * (T.noise(np.c_[us * 6, np.zeros_like(us), np.ones_like(us)], 0.3, 3, 3) * 0.5 + 0.5)
        alpha[s] = (dh > tear).astype(np.float32)
    # ------------------------------------------------------------ tabards & panels
    s = is_('cloth_tabard')
    if s.any():
        us, vs = u[s], v[s]
        oid = Om[s]
        # width of each panel: max u per object
        umax = np.zeros(oid.max() + 1)
        for o in np.unique(oid): umax[o] = us[oid == o].max()
        wdt = umax[oid]; cx = us - wdt / 2
        base = BLACK * 1.1 * (1 + 0.15 * nlo[s][:, None] + 0.06 * nz[s][:, None])
        de = d_all[s]
        border = T.line_mask(np.abs(de - 0.005), 0.0012, texel) + T.line_mask(np.abs(de - 0.011), 0.0008, texel) \
            + T.line_mask(np.abs(de - 0.016), 0.0005, texel)
        inner = de > 0.019
        p = 0.064
        k = vs / p
        f = k - np.floor(k) - 0.5
        loz = T.line_mask(np.abs(np.abs(cx) / (wdt / 2 - 0.02 + 1e-6) * 0.5 - np.abs(f)), 0.02, 0.02) * inner
        centre = T.line_mask(np.abs(cx), 0.0010, texel) * inner
        nodes = star8(cx, (f) * p, 0.017, 0.009) * inner
        diag = T.line_mask(np.minimum(np.abs(cx - f * p * 0.8), np.abs(cx + f * p * 0.8)), 0.0006, texel) * inner * (np.abs(cx) < wdt / 2 - 0.02)
        g = np.clip(border + loz * 0.9 + centre + nodes + diag * 0.8, 0, 1)
        alb[s] = base * (1 - g[:, None]) + GOLDT * g[:, None]
        rough[s] = 0.82 * (1 - g) + 0.5 * g; metal[s] = 0.35 * g
        height[s] = 0.0004 * g + 0.0001 * nz[s]
        glow = nodes * (T.pair_hash(np.floor(k), oid) < 0.6)
        emis[s] = 0.08 * g + 1.1 * glow
    # ------------------------------------------------------------ assemble
    def img(vv, ch):
        out = np.zeros((R * R, ch), np.float32); out[idx] = vv.reshape(n, ch); return out.reshape(R, R, ch)
    ALB = img(np.c_[alb, alpha], 4); ORM = img(np.c_[ao, rough, metal], 3)
    H = img(height, 1)[..., 0]; EM = img(emis, 1)[..., 0]
    T.apply_projection('cloth', W, mask, ALB, ORM, EM, H, fabric=True)
    NRM = T.height_to_normal(H, mask, texel, 1.0, island=obj)
    EMC = np.clip(EM[..., None] * EMIT, 0, 1)
    ALB[..., :3] = T.dilate(ALB[..., :3], mask); ALB[..., 3] = np.where(mask, ALB[..., 3], 0)
    ORM = T.dilate(ORM, mask); NRM = T.dilate(NRM, mask); EMC = T.dilate(EMC, mask)
    T.save_rgba(os.path.join(OUT, 'cloth_albedo.png'), np.clip(ALB, 0, 1))
    T.save_rgb(os.path.join(OUT, 'cloth_orm.png'), np.clip(ORM, 0, 1))
    cv2.imwrite(os.path.join(OUT, 'cloth_normal.png'), cv2.cvtColor(T.encode_normal(NRM), cv2.COLOR_RGB2BGR))
    T.save_rgb(os.path.join(OUT, 'cloth_emission.png'), EMC)
    print('cloth textures written')

if __name__ == '__main__':
    main()

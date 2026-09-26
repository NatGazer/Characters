"""Armour pieces (left side built, right side mirrored). Runs under bpy.

Every function returns kit.Part objects (or Blender objects) with material slots:
  armor  - dark gunmetal plate with gold kintsugi veins (procedural texture later)
  gold   - raised gold trims / medallions
  bronze - lion head
  leather, cloth_red, cloth_dark ...
Measurements come from the gridded references (see body_fit.py for the scale).
"""
import math
import numpy as np
import kit
from kit import Frame, ring_piece, peak, tube, catmull, unit

TAU = 2 * np.pi

def arm_frames(B, side='L'):
    S = B.joint('upperarm01.' + side); E = B.joint('lowerarm01.' + side); Wr = B.joint('wrist.' + side)
    sg = 1 if side == 'L' else -1
    return dict(S=S, E=E, Wr=Wr,
                uarm=Frame(S, E - S, sg), farm=Frame(E, Wr - E, sg), Lf=np.linalg.norm(Wr - E), Lu=np.linalg.norm(E - S))

def rim_along(V, grid_shape, row, radius=0.0035, lift=0.0, closed=True, n=4, fr=None):
    """Gold bead along one grid row (outline) of a ring piece."""
    nt, nth = grid_shape
    P = V.reshape(nt, nth, 3)[row]
    if closed: P = np.vstack([P, P[:1]])
    if fr is not None and lift:
        C = fr.O + np.dot(P - fr.O, fr.A)[:, None] * fr.A
        P = P + unit(P - C) * lift
    P = kit.catmull(P[:-1] if closed else P, n_per=1, closed=closed)
    Vt, Ft, UVt = tube(P, radius, n=n, closed=closed, cap=not closed)
    return Vt, Ft, UVt

def vambrace(B, side='L'):
    a = arm_frames(B, side); fr = a['farm']; L = a['Lf']
    bvh = B.bvh(['farm.' + side, 'hand.' + side])
    lat = np.pi / 2
    top = lambda th: 0.30 * L - 0.34 * L * peak(th, lat, 1.25, 1.25)        # gothic point over outer elbow
    bot = lambda th: 0.80 * L + 0.012 * np.cos(th - lat)                     # slightly angled lower edge
    off = lambda th, t, r: 0.012 + 0.016 * np.clip(1 - t / (0.8 * L), 0, 1) ** 1.3 \
        + 0.008 * peak(th, lat, 1.4, 2) * np.clip(1 - t / (0.5 * L), 0, 1)
    V, F, FUV, info = ring_piece(fr, bvh, top, bot, off, nth=52, nt=20)
    p = kit.Part('vambrace.' + side)
    p.add(V, F, FUV=FUV, mat='armor')
    for row in (0, info['shape'][0] - 1):
        Vt, Ft, UVt = rim_along(V, info['shape'], row, 0.0035, lift=0.001, fr=fr)
        p.add(Vt, Ft, UVt, mat='gold')
    # central raised spine ridge down the lateral side (the glowing line)
    th = np.full(20, lat); t = np.linspace(0.05 * L, 0.78 * L, 20)
    Rr = np.array([np.interp(tt, info['T'][:, 18], info['R'][:, 18]) for tt in t])
    return p, info

def wrist_cuff(B, side='L'):
    a = arm_frames(B, side); fr = a['farm']; L = a['Lf']
    bvh = B.bvh(['farm.' + side, 'hand.' + side])
    t0, t1 = 0.79 * L, 0.98 * L
    def off(th, t, r):
        s = (t - t0) / (t1 - t0)
        ridge = 0.004 * np.exp(-((s - 0.18) / 0.08) ** 2) + 0.004 * np.exp(-((s - 0.62) / 0.08) ** 2)
        return 0.012 + 0.004 * s + ridge
    V, F, FUV, info = ring_piece(fr, bvh, t0, t1, off, nth=44, nt=12)
    p = kit.Part('cuff.' + side); p.add(V, F, FUV=FUV, mat='armor')
    for row in (0, info['shape'][0] - 1):
        Vt, Ft, UVt = rim_along(V, info['shape'], row, 0.003, fr=fr)
        p.add(Vt, Ft, UVt, mat='gold')
    return p

def forearm_wrap(B, side='L'):
    """Red cloth wound around the forearm just below the elbow (5 rolled turns, helical)."""
    a = arm_frames(B, side); fr = a['farm']; L = a['Lf']
    bvh = B.bvh(['farm.' + side, 'uarm.' + side])
    t0, t1 = -0.02 * L, 0.34 * L
    def off(th, t, r):
        s = (t - t0) / (t1 - t0)
        ph = s * 5.2 + 0.18 * np.sin(th)                 # helical turns
        roll = 0.0055 * np.abs(np.sin(np.pi * ph)) ** 0.6
        return 0.006 + roll * 0.8 + 0.003 * s
    V, F, FUV, info = ring_piece(fr, bvh, t0, t1, off, nth=40, nt=32)
    p = kit.Part('wrap.' + side); p.add(V, F, FUV=FUV, mat='cloth_red_wrap')
    return p

def build_arms(B, collection=None, mirror=True):
    objs = []
    for fn in (vambrace, wrist_cuff, forearm_wrap, gauntlet):
        r = fn(B, 'L'); part = r[0] if isinstance(r, tuple) else r
        ob = part.build(collection); objs.append(ob)
        if mirror: objs.append(kit.mirror_object(ob, ob.name[:-2] + '.R'))
    return objs

# ============================================================================ legs
def leg_frames(B, side='L'):
    H = B.joint('upperleg01.' + side); K = B.joint('lowerleg01.' + side); An = B.joint('foot.' + side)
    sg = 1 if side == 'L' else -1
    return dict(H=H, K=K, An=An, thigh=Frame(H, K - H, sg), shin=Frame(K, An - K, sg),
                Lt=np.linalg.norm(K - H), Ls=np.linalg.norm(An - K))

def greave(B, side='L'):
    g = leg_frames(B, side); fr = g['shin']; L = g['Ls']
    bvh = B.bvh(['shin.' + side, 'foot.' + side, 'thigh.' + side])
    # top: V dipping at the front centre (under the knee cop); bottom: V pointing down at the front
    top = lambda th: -0.005 + 0.035 * peak(th, 0, 1.3, 1.0) + 0.02 * (1 - np.cos(th)) * 0.5
    bot = lambda th: 0.66 * L + 0.10 * L * peak(th, 0, 1.4, 1.3)
    def off(th, t, r):
        s = t / L
        calf = 0.012 + 0.005 * np.exp(-((s - 0.3) / 0.25) ** 2) + 0.004 * peak(th, 0, 1.2, 1.5)
        ridge = 0.006 * peak(th, 0, 0.35, 2)            # central keel down the shin
        return calf + ridge
    V, F, FUV, info = ring_piece(fr, bvh, top, bot, off, nth=52, nt=28, th0=-np.pi * 0.92, th1=np.pi * 0.92, closed=False)
    p = kit.Part('greave.' + side); p.add(V, F, FUV=FUV, mat='armor')
    nt, nth = info['shape']
    for row in (0, nt - 1):
        Vt, Ft, UVt = rim_along(V, info['shape'], row, 0.0035, closed=False, fr=fr, lift=0.001)
        p.add(Vt, Ft, UVt, mat='gold')
    return p, info

def ankle_lames(B, side='L', n=4):
    g = leg_frames(B, side); fr = g['shin']; L = g['Ls']
    bvh = B.bvh(['shin.' + side, 'foot.' + side])
    p = kit.Part('lames.' + side)
    t_start, t_end = 0.64 * L, 0.95 * L
    step = (t_end - t_start) / n
    for k in range(n):
        a = t_start + k * step
        top = lambda th, a=a: a + 0.022 * peak(th, 0, 1.2, 1.0)
        bot = lambda th, a=a: a + step * 1.35 + 0.030 * peak(th, 0, 1.2, 1.0)
        def off(th, t, r, k=k, a=a):
            s = np.clip((t - a) / (step * 1.35), 0, 1)
            return 0.015 + 0.003 * k + 0.007 * s        # each lame flares outward over the next
        V, F, FUV, info = ring_piece(fr, bvh, top, bot, off, nth=40, nt=6)
        p.add(V, F, FUV=FUV, mat='armor')
        Vt, Ft, UVt = rim_along(V, info['shape'], info['shape'][0] - 1, 0.003, fr=fr)
        p.add(Vt, Ft, UVt, mat='gold')
    return p

def knee_cop(B, side='L'):
    g = leg_frames(B, side); fr = g['shin']; L = g['Ls']
    bvh = B.bvh(['shin.' + side, 'thigh.' + side])
    # gothic-arch top above the knee, V bottom overlapping the greave
    top = lambda th: -0.150 + 0.11 * (1 - peak(th, 0, 1.35, 1.0))
    bot = lambda th: 0.040 - 0.035 * (1 - peak(th, 0, 1.35, 1.0))
    def off(th, t, r):
        dome = 0.012 * np.exp(-((t + 0.05) / 0.06) ** 2) * peak(th, 0, 1.4, 1.5)
        return 0.022 + dome
    V, F, FUV, info = ring_piece(fr, bvh, top, bot, off, nth=36, nt=22, th0=-np.pi * 0.66, th1=np.pi * 0.66, closed=False)
    p = kit.Part('kneecop.' + side); p.add(V, F, FUV=FUV, mat='armor')
    nt, nth = info['shape']
    # outline rim: all four borders
    Vg = V.reshape(nt, nth, 3)
    ring = np.vstack([Vg[0], Vg[1:, -1], Vg[-1, ::-1][1:], Vg[::-1, 0][1:-1]])
    Vt, Ft, UVt = tube(ring, 0.0035, n=4, closed=True, cap=False)
    p.add(Vt, Ft, UVt, mat='gold')
    return p, info

def lion_head(B, side='L'):
    """Bronze lion relief on the knee cop: sculpted head form (dome, brow, snout, mane) plus
    mid-frequency detail from the upscaled reference. Displaced patch on the knee-cop surface."""
    g = leg_frames(B, side); fr = g['shin']
    bvh = B.bvh(['shin.' + side, 'thigh.' + side])
    nth, nt = 50, 56
    th = np.linspace(-0.6, 0.6, nth); t = np.linspace(-0.118, 0.008, nt)
    TH, T = np.meshgrid(th, t)
    Rb = kit.ray_radius(bvh, fr, TH, T)
    Rb = kit.smooth_radius(kit.fill_nan(Rb, 0), 2, 2, wrap=False)
    base = Rb + 0.022 + 0.012 * np.exp(-((T + 0.05) / 0.06) ** 2) * peak(TH, 0, 1.4, 1.5)
    # local 2D coords on the patch: x across (-1..1), y down (-1..1)
    x = TH / 0.6; y = (T - (-0.055)) / 0.063
    rr = np.sqrt(x ** 2 + (y * 0.95) ** 2)
    mane = 0.010 * np.clip(1 - np.abs(rr - 0.82) / 0.2, 0, 1) * (1 + 0.35 * np.cos(np.arctan2(y, x) * 14))
    face = 0.017 * np.clip(1 - (x / 0.62) ** 2 - ((y + 0.02) / 0.75) ** 2, 0, 1) ** 0.6
    brow = 0.004 * np.exp(-((y + 0.28) / 0.08) ** 2) * np.clip(1 - np.abs(x) / 0.5, 0, 1)
    snout = 0.013 * np.clip(1 - (x / 0.3) ** 2 - ((y - 0.28) / 0.34) ** 2, 0, 1) ** 0.7
    eyes = -0.004 * (np.exp(-(((np.abs(x) - 0.2) / 0.08) ** 2 + ((y + 0.15) / 0.06) ** 2)))
    ears = 0.007 * np.exp(-(((np.abs(x) - 0.5) / 0.1) ** 2 + ((y + 0.6) / 0.12) ** 2))
    H = mane + face + brow + snout + eyes + ears
    D = lion_detail(nt, nth)
    if side == 'L': D = D[:, ::-1]
    R = base + H + D * np.clip(1.1 - rr, 0, 1)
    V = fr.point(TH, T, R).reshape(-1, 3)
    F = kit.grid_faces(nt, nth)
    UV = np.stack([(TH - th[0]) / (th[-1] - th[0]), 1 - (T - t[0]) / (t[-1] - t[0])], -1).reshape(-1, 2)
    if side == 'L': UV[:, 0] = 1 - UV[:, 0]
    p = kit.Part('lion.' + side); p.add(V, F, UV, mat='bronze_lion')
    return p

_LION = {}
def lion_detail(nt, nth):
    """Band-passed luminance of the reference lion (character's right knee) -> +-3 mm detail."""
    import cv2, views
    key = (nt, nth)
    if key in _LION: return _LION[key]
    im = views.ref_image('front', up=True)
    u0, u1, v0, v1 = 344, 444, 893, 1000
    c = im[v0 * 4:v1 * 4, u0 * 4:u1 * 4].astype(np.float32) / 255
    lum = cv2.cvtColor(c, cv2.COLOR_BGR2GRAY)
    lum = cv2.resize(lum, (nth * 4, nt * 4), interpolation=cv2.INTER_AREA)
    band = cv2.GaussianBlur(lum, (0, 0), 1.2) - cv2.GaussianBlur(lum, (0, 0), 8)
    h = cv2.resize(band, (nth, nt), interpolation=cv2.INTER_AREA) * 0.012
    _LION[key] = np.clip(h, -0.003, 0.003)
    return _LION[key]

def sabaton(B, side='L'):
    """Boot: radial surface around the heel->toe axis with a raised rounded toe box, lames across
    the instep, a 3 cm sole slab and a block heel."""
    g = leg_frames(B, side); sg = 1 if side == 'L' else -1
    An = g['An']
    toe = B.joint('toe3-1.' + side, 'tail')
    heel = np.array([An[0], An[1] + 0.075, 0.075])
    tip = np.array([toe[0] + 0.004 * sg, toe[1] - 0.062, 0.058])
    A = tip - heel; Lf = np.linalg.norm(A)
    fr = Frame(heel, A, sg, fwd=(0, 0, 1))                  # theta=0 points up
    bvh = B.bvh(['foot.' + side, 'shin.' + side])
    t0, t1 = 0.015, Lf
    def off(th, t, r):
        s = np.clip(t / Lf, 0, 1)
        lam = np.clip(s - 0.3, 0, 1) / 0.7
        lames = 0.003 * (np.sin(lam * np.pi * 4.5) > 0.2) * (s > 0.3)
        return 0.010 + 0.007 * np.clip((s - 0.55) / 0.3, 0, 1) + lames
    V, F, FUV, info = ring_piece(fr, bvh, t0, t1, off, nth=44, nt=30, rmax=0.3)
    nt, nth = info['shape']
    Vg = V.reshape(nt, nth, 3)
    for i in range(nt):
        s = i / (nt - 1)
        c = heel + A * (info['T'][i, 0] / Lf)
        k = 1 - 0.7 * np.clip((s - 0.8) / 0.2, 0, 1) ** 2.2   # rounded toe cap
        Vg[i] = c + (Vg[i] - c) * k
    Vg[..., 2] = np.maximum(Vg[..., 2], 0.028)
    V = Vg.reshape(-1, 3)
    p = kit.Part('sabaton.' + side); p.add(V, F, FUV=FUV, mat='armor')
    # sole: convex-ish outline of the boot footprint at z=0.028, extruded down to 0 (heel block 0..0.03)
    P = Vg[:, :, :2].reshape(-1, 2)
    import scipy.spatial as sps
    hull = P[sps.ConvexHull(P).vertices]
    c2 = hull.mean(0); ang = np.arctan2(hull[:, 1] - c2[1], hull[:, 0] - c2[0]); hull = hull[np.argsort(ang)]
    hull = kit.resample_polyline(np.c_[np.vstack([hull, hull[:1]]), np.zeros(len(hull) + 1)], n=64)[:-1, :2]
    hull = c2 + (hull - c2) * 1.03
    n = len(hull); Vs = np.vstack([np.c_[hull, np.full(n, 0.030)], np.c_[hull, np.zeros(n)]])
    Fs = [[i, (i + 1) % n, n + (i + 1) % n, n + i] for i in range(n)]
    Fs.append(list(range(n))[::-1]); Fs.append([n + i for i in range(n)])
    # orient: side faces outward
    UVs = np.c_[np.linspace(0, 1, 2 * n), np.r_[np.zeros(n), np.ones(n)]]
    Fs = [f[::-1] for f in Fs[:-2]] + [Fs[-2][::-1], Fs[-1][::-1]] if sg > 0 else Fs
    p.add(Vs, Fs, UVs, mat='leather_sole')
    return p, info

def build_legs(B, collection=None, mirror=True):
    objs = []
    for fn in (greave, ankle_lames, knee_cop, lion_head, sabaton):
        r = fn(B, 'L'); part = r[0] if isinstance(r, tuple) else r
        ob = part.build(collection); objs.append(ob)
        if mirror: objs.append(kit.mirror_object(ob, ob.name[:-2] + '.R'))
    return objs

# ============================================================================ torso
def torso_frame(B):
    return Frame((0, 0.035, 1.0), (0, 0, 1), 1)

def cuirass(B):
    """Chest + back plate: radial surface around a vertical axis, arm-holes cut by the outline."""
    fr = torso_frame(B); bvh = B.bvh(['chest', 'belly', 'neck'])
    z0 = 1.0
    top = lambda th: (1.700 - z0) - 0.20 * peak(th, np.pi / 2, 0.62, 1.2) - 0.20 * peak(th, -np.pi / 2, 0.62, 1.2) \
        - 0.030 * peak(th, 0, 0.6, 1.0)
    bot = lambda th: (1.275 - z0) + 0.0 * th
    def off(th, t, r):
        z = t + z0
        chest = 0.011 * np.exp(-((z - 1.52) / 0.09) ** 2) * np.clip(np.cos(th), 0, 1)
        return 0.013 + chest + 0.005 * np.clip((z - 1.35) / 0.2, 0, 1)
    V, F, FUV, info = ring_piece(fr, bvh, bot, top, off, nth=84, nt=34, smooth=(1.5, 1.5), rmax=0.45)
    p = kit.Part('cuirass'); p.add(V, F, FUV=FUV, mat='armor')
    for row in (0, info['shape'][0] - 1):
        Vt, Ft, UVt = rim_along(V, info['shape'], row, 0.0035, fr=fr, lift=0.001)
        p.add(Vt, Ft, UVt, mat='gold')
    return p, info

def collar(B):
    O = B.joint('neck01'); fr = Frame(O - np.array([0, 0, 0.03]), (0, 0.06, 1), 1)
    bvh = B.bvh(['neck', 'chest'])
    def off(th, t, r):
        return 0.013 + 0.010 * (t / 0.06)
    top = lambda th: 0.058 - 0.014 * peak(th, 0, 0.5, 1.0)
    V, F, FUV, info = ring_piece(fr, bvh, 0.0, top, off, nth=48, nt=6, rmax=0.25)
    p = kit.Part('collar'); p.add(V, F, FUV=FUV, mat='armor')
    for row in (0, info['shape'][0] - 1):
        Vt, Ft, UVt = rim_along(V, info['shape'], row, 0.0032, fr=fr)
        p.add(Vt, Ft, UVt, mat='gold')
    return p

def medallion(center, normal, up, R, depth=0.012, star=8, name_mat='gold', ring_w=0.18, nr=12, na=48):
    """Compass-star medallion: raised rim ring, sunken field with spokes, pyramidal N-point star.
    Built as a height-field disc (polar grid) in its own frame."""
    n = unit(normal); u = unit(np.asarray(up) - np.dot(up, n) * n); v = np.cross(n, u)
    rr = np.linspace(0, 1, nr); aa = np.linspace(0, 2 * np.pi, na, endpoint=False)
    Rg, Ag = np.meshgrid(rr, aa, indexing='ij')
    # height profile
    rim = np.clip(1 - np.abs(Rg - (1 - ring_w / 2)) / (ring_w / 2), 0, 1) ** 0.5
    edge_drop = np.clip((1 - Rg) / 0.04, 0, 1)
    k = star
    ang = (Ag + np.pi / k) % (2 * np.pi / k) - np.pi / k       # angle to nearest ray
    long_ray = (np.round((Ag) / (2 * np.pi / k)) % 2 == 0)
    ray_len = np.where(long_ray, 0.78, 0.55)
    star_w = 0.22 * (1 - Rg / ray_len)
    star_h = np.clip(1 - np.abs(np.sin(ang)) * Rg / np.maximum(star_w * Rg + 1e-3, 1e-3) * 0.25, 0, 1) * np.clip(1 - Rg / ray_len, 0, 1)
    spokes = 0.25 * np.clip(1 - np.abs(np.sin(Ag * 12)) * 12 * Rg, 0, 1) * (Rg > 0.3) * (Rg < 0.82)
    H = depth * (0.35 * rim + 0.9 * star_h + 0.15 * spokes + 0.25) * edge_drop
    H[0, :] = depth * 1.15
    P = center + (Rg * R)[..., None] * (np.cos(Ag)[..., None] * u + np.sin(Ag)[..., None] * v) + H[..., None] * n
    V = P.reshape(-1, 3)
    F = []
    for i in range(nr - 1):
        for j in range(na):
            j2 = (j + 1) % na
            F.append([i * na + j, i * na + j2, (i + 1) * na + j2, (i + 1) * na + j])
    # back cap
    c0 = len(V); V = np.vstack([V, center - n * 0.002])
    for j in range(na):
        F.append([c0, (nr - 1) * na + (j + 1) % na, (nr - 1) * na + j])
    UV = np.vstack([np.stack([0.5 + 0.5 * Rg * np.cos(Ag), 0.5 + 0.5 * Rg * np.sin(Ag)], -1).reshape(-1, 2), [[0.5, 0.5]]])
    return V, F, UV

def surface_point(bvh, P, D, rmax=0.4):
    """First hit of the body/armour BVH along -D from P + D*rmax: returns (point, normal)."""
    from mathutils import Vector
    o = np.asarray(P) + np.asarray(D) * rmax
    hit = bvh.ray_cast(Vector(o), Vector(-np.asarray(D)), rmax * 2)
    if hit[0] is None: return np.asarray(P), unit(D)
    return np.array(hit[0]), np.array(hit[1])

def pauldron(B, side='L'):
    """Domed shoulder cap with gothic points front/back, two medallions, and 3 lames down the arm."""
    a = arm_frames(B, side); S = a['S']; sg = 1 if side == 'L' else -1
    fr_u = a['uarm']; Lu = a['Lu']
    p = kit.Part('pauldron.' + side)
    # ---- cap: ellipsoid dome around pole n
    C = S + np.array([0.010 * sg, 0.004, -0.018])
    pole = unit(np.array([0.55 * sg, 0.0, 0.84]))
    fwd = np.array([0, -1.0, 0]); e1 = unit(fwd - np.dot(fwd, pole) * pole); e2 = np.cross(pole, e1)
    if np.dot(e2, [sg, 0, 0]) < 0: e2 = -e2      # e2 lateral-ish (down the arm side)
    nps, nw = 20, 64
    w = np.linspace(-np.pi, np.pi, nw, endpoint=False)
    # outline: polar extent psi_max(w). w=0 front, w=+-pi back, w=+pi/2 lateral(down arm), -pi/2 medial(neck)
    front_pt = peak(w, 0, 0.55, 1.2); back_pt = peak(w, np.pi, 0.55, 1.2)
    lateral = peak(w, np.pi / 2, 1.2, 1.0); medial = peak(w, -np.pi / 2, 1.1, 1.0)
    psi_max = 1.08 + 0.72 * front_pt + 0.66 * back_pt + 0.30 * lateral - 0.40 * medial
    s = np.linspace(0, 1, nps)[:, None]
    PSI = s * psi_max[None, :]
    Wg = np.broadcast_to(w[None, :], PSI.shape)
    rx, ry, rz = 0.120, 0.126, 0.082    # radii along e1 (front), e2 (lateral), pole
    dirv = (np.sin(PSI) * np.cos(Wg))[..., None] * e1 * rx + (np.sin(PSI) * np.sin(Wg))[..., None] * e2 * ry \
        + np.cos(PSI)[..., None] * pole * rz
    flare = 1 + 0.10 * np.clip((PSI - 1.0) / 0.8, 0, 1)
    P = C + dirv * flare[..., None]
    V = P.reshape(-1, 3)
    F = kit.grid_faces(nps, nw)
    F = np.vstack([F, [[i * nw + nw - 1, i * nw, (i + 1) * nw, (i + 1) * nw + nw - 1] for i in range(nps - 1)]])
    UV = np.stack([0.5 + 0.5 * s * np.cos(Wg) * np.ones_like(PSI), 0.5 + 0.5 * s * np.sin(Wg)], -1).reshape(-1, 2)
    F = kit.orient_outward(V, F, lambda c: np.broadcast_to(C, c.shape))
    p.add(V, F, UV, mat='armor')
    ring = P[-1]
    Vt, Ft, UVt = tube(ring, 0.0045, n=5, closed=True, cap=False)
    p.add(Vt, Ft, UVt, mat='gold')
    # decorative ridge ring (the inner gothic outline seen on the cap)
    ring2 = P[int(nps * 0.72)]
    Vt, Ft, UVt = tube(ring2, 0.0025, n=4, closed=True, cap=False)
    p.add(Vt, Ft, UVt, mat='gold')
    # medallions: on the top-front of the cap and on its lateral face
    def cap_point(psi, ww):
        d = (np.sin(psi) * np.cos(ww)) * e1 * rx + (np.sin(psi) * np.sin(ww)) * e2 * ry + np.cos(psi) * pole * rz
        f = 1 + 0.10 * np.clip((psi - 1.0) / 0.8, 0, 1)
        q = C + d * f
        nrm = unit((q - C) / np.array([1, 1, 1]))
        return q, nrm
    for (psi, ww, Rm) in [(0.55, -0.35, 0.030), (1.05, 1.35, 0.036)]:
        q, nrm = cap_point(psi, ww)
        Vm, Fm, UVm = medallion(q, nrm, (0, 0, 1) if abs(nrm[2]) < 0.8 else (0, -1, 0), Rm, depth=0.009)
        p.add(Vm, Fm, UVm, mat='gold_medallion')
    # ---- lames down the upper arm (lateral half), overlapping, flared
    bvh = B.bvh(['uarm.' + side])
    lat = np.pi / 2
    for k in range(3):
        t0 = 0.090 + 0.050 * k
        top = lambda th, t0=t0: t0 + 0.012 * (1 - peak(th, lat, 1.6, 1.0))
        bot = lambda th, t0=t0: t0 + 0.068 + 0.012 * peak(th, lat, 1.4, 1.0)
        def off(th, t, r, k=k, t0=t0):
            s_ = np.clip((t - t0) / 0.068, 0, 1)
            return 0.017 - 0.002 * k + 0.006 * s_
        V, F, FUV, info = ring_piece(fr_u, bvh, top, bot, off, nth=32, nt=6, th0=lat - 1.75, th1=lat + 1.75, closed=False)
        p.add(V, F, FUV=FUV, mat='armor')
        Vt, Ft, UVt = rim_along(V, info['shape'], info['shape'][0] - 1, 0.0035, closed=False, fr=fr_u)
        p.add(Vt, Ft, UVt, mat='gold')
    return p

def belt(B):
    fr = torso_frame(B); bvh = B.bvh(['belly', 'chest'])
    z0 = 1.0; zb0, zb1 = 1.283 - z0, 1.338 - z0
    off = lambda th, t, r: 0.020 + 0.004 * np.sin(np.pi * np.clip((t - zb0) / (zb1 - zb0), 0, 1))
    V, F, FUV, info = ring_piece(fr, bvh, zb0, zb1, off, nth=96, nt=8, rmax=0.45)
    p = kit.Part('belt'); p.add(V, F, FUV=FUV, mat='leather_belt')
    R = info['R']; T = info['T']; th = info['TH'][0]
    def belt_pt(theta, z, extra=0.0):
        j = np.argmin(np.abs(np.angle(np.exp(1j * (th - theta)))))
        i = np.argmin(np.abs(T[:, 0] - (z - z0)))
        r = R[i, j] + extra
        d = fr.dirs(theta)
        return fr.point(theta, z - z0, r), d
    # medallions: big front, two front-side, three at the back
    for theta, z, Rm, dep in [(0, 1.310, 0.047, 0.016), (0.62, 1.312, 0.030, 0.011), (-0.62, 1.312, 0.030, 0.011),
                              (np.pi, 1.310, 0.036, 0.013), (np.pi - 0.55, 1.312, 0.026, 0.010), (-np.pi + 0.55, 1.312, 0.026, 0.010)]:
        q, d = belt_pt(theta, z, 0.004)
        Vm, Fm, UVm = medallion(q, d, (0, 0, 1), Rm, depth=dep)
        p.add(Vm, Fm, UVm, mat='gold_medallion')
    # orbs under the belt (dark spheres with gold caps) at the front sides
    for theta in (0.38, -0.38):
        q, d = belt_pt(theta, 1.272, 0.012)
        Vs, Fs, UVs = sphere(q, 0.016)
        p.add(Vs, Fs, UVs, mat='armor_orb')
    return p, info

def sphere(c, r, nu=10, nv=14):
    u = np.linspace(0, np.pi, nu); v = np.linspace(0, 2 * np.pi, nv, endpoint=False)
    U, Vv = np.meshgrid(u, v, indexing='ij')
    P = np.stack([np.sin(U) * np.cos(Vv), np.sin(U) * np.sin(Vv), np.cos(U)], -1) * r + c
    V = P.reshape(-1, 3)
    F = []
    for i in range(nu - 1):
        for j in range(nv):
            j2 = (j + 1) % nv
            F.append([i * nv + j, (i + 1) * nv + j, (i + 1) * nv + j2, i * nv + j2])
    UV = np.stack([Vv / (2 * np.pi), U / np.pi], -1).reshape(-1, 2)
    return V, F, UV

def fauld_tabs(B):
    """Triangular armoured tabs hanging below the belt (front sides and back sides)."""
    fr = torso_frame(B); bvh = B.bvh(['belly', 'thigh.L', 'thigh.R'])
    z0 = 1.0
    p = kit.Part('fauld')
    for c in (0.45, -0.45, np.pi - 0.42, -np.pi + 0.42):
        wdt = 0.36
        top = lambda th: 1.285 - z0 + 0 * th
        bot = lambda th, c=c: 1.285 - z0 - 0.085 * peak(th, c, wdt, 1.0) - 0.004
        V, F, FUV, info = ring_piece(fr, bvh, bot, top, lambda th, t, r: 0.026 + 0 * t, nth=20, nt=10,
                                     th0=c - wdt, th1=c + wdt, closed=False, rmax=0.45)
        p.add(V, F, FUV=FUV, mat='armor')
        Vg = V.reshape(info['shape'] + (3,))
        # rim along the two slanted edges (bottom row = lowest t) -> row 0 is bot
        Vt, Ft, UVt = tube(Vg[0], 0.003, n=4, closed=False)
        p.add(Vt, Ft, UVt, mat='gold')
    return p

def build_torso(B, collection=None, mirror=True):
    objs = []
    for fn in (cuirass, collar, belt, fauld_tabs):
        r = fn(B); part = r[0] if isinstance(r, tuple) else r
        objs.append(part.build(collection))
    ob = pauldron(B, 'L').build(collection); objs.append(ob)
    if mirror: objs.append(kit.mirror_object(ob, 'pauldron.R'))
    return objs

# ============================================================================ details
def chest_medallion(B):
    """Large compass-star medallion on the upper chest (ref front: centre (512, 310), r ~ 35 px)."""
    fr = torso_frame(B); bvh = B.bvh(['chest'])
    z = 1.555
    r = kit.ray_radius(bvh, fr, np.array([0.0]), np.array([z - fr.O[2]]), 0.45)[0]
    q = fr.point(np.array(0.0), np.array(z - fr.O[2]), np.array(r + 0.026))
    p = kit.Part('chest_medallion')
    Vm, Fm, UVm = medallion(q, (0, -1, 0.12), (0, 0, 1), 0.046, depth=0.012)
    p.add(Vm, Fm, UVm, mat='gold_medallion')
    return p

def chain_pendant(B):
    """Chain from the belt medallion (character's right) with a gold ball, a ring and a pendant."""
    fr = torso_frame(B)
    p = kit.Part('chain')
    x0 = -0.028
    top = np.array([x0, -0.205, 1.262]); ball = np.array([x0 - 0.004, -0.225, 1.150])
    ring = np.array([x0 - 0.005, -0.232, 1.085]); pend = np.array([x0 - 0.006, -0.240, 0.985])
    path = kit.catmull([top, (top + ball) / 2 + [0, -0.004, 0], ball, ring, pend], n_per=10)
    path = kit.resample_polyline(path, step=0.011)
    # links: alternating tori oriented along the chain
    for i in range(len(path) - 1):
        a, b = path[i], path[i + 1]
        c = (a + b) / 2; d = unit(b - a)
        side = np.array([1.0, 0, 0]) if i % 2 == 0 else np.array([0, 1.0, 0])
        side = unit(side - np.dot(side, d) * d)
        ang = np.linspace(0, 2 * np.pi, 8, endpoint=False)
        loop = c + 0.0075 * np.cos(ang)[:, None] * d + 0.0045 * np.sin(ang)[:, None] * side
        Vt, Ft, UVt = tube(loop, 0.0014, n=4, closed=True, cap=False)
        p.add(Vt, Ft, UVt, mat='gold')
    Vs, Fs, UVs = sphere(ball, 0.0115); p.add(Vs, Fs, UVs, mat='gold')
    ang = np.linspace(0, 2 * np.pi, 28, endpoint=False)
    loop = ring + 0.018 * (np.cos(ang)[:, None] * np.array([1., 0, 0]) + np.sin(ang)[:, None] * np.array([0, 0, 1.]))
    Vt, Ft, UVt = tube(loop, 0.0025, n=6, closed=True, cap=False); p.add(Vt, Ft, UVt, mat='gold')
    Vm, Fm, UVm = medallion(pend - [0, 0, 0.026], (0, -1, 0), (0, 0, 1), 0.030, depth=0.007)
    p.add(Vm, Fm, UVm, mat='gold_medallion')
    return p

def dagger(B, side='L'):
    """Sheathed dagger hanging at the hip: dark sheath, gold chape/locket, grip, gold pommel."""
    sg = 1 if side == 'L' else -1
    top = np.array([0.175 * sg, -0.075, 1.285]); axis = unit(np.array([0.06 * sg, -0.12, -1.0]))
    p = kit.Part('dagger.' + side)
    L = 0.30
    pts = np.array([top + axis * t for t in np.linspace(0, L, 12)])
    r = np.interp(np.linspace(0, 1, 12), [0, 0.1, 0.9, 1], [0.018, 0.016, 0.012, 0.004])
    Vt, Ft, UVt = tube(pts, r, n=10); p.add(Vt, Ft, UVt, mat='leather_sheath')
    for t0 in (0.0, 0.26):
        seg = np.array([top + axis * t for t in np.linspace(t0, t0 + 0.035, 4)])
        Vt, Ft, UVt = tube(seg, np.interp(t0 + 0.02, [0, L], [0.019, 0.010]) + 0.002, n=10); p.add(Vt, Ft, UVt, mat='gold')
    grip = np.array([top - axis * t for t in np.linspace(0.0, 0.10, 6)])
    Vt, Ft, UVt = tube(grip, 0.011, n=8); p.add(Vt, Ft, UVt, mat='leather_grip')
    guard = np.array([top - axis * 0.004 + np.array([0, 1, 0]) * s for s in np.linspace(-0.035, 0.035, 5)])
    Vt, Ft, UVt = tube(guard, 0.006, n=8); p.add(Vt, Ft, UVt, mat='gold')
    Vs, Fs, UVs = sphere(top - axis * 0.112, 0.015); p.add(Vs, Fs, UVs, mat='gold')
    return p

def build_details(B, collection=None):
    objs = [chest_medallion(B).build(collection), chain_pendant(B).build(collection), sword().build(collection)]
    ob = dagger(B, 'L').build(collection); objs += [ob, kit.mirror_object(ob, 'dagger.R')]
    return objs

# ============================================================================ sword (prop, skinned to SwordSocket)
SWORD_LEN = 0.98      # blade length (m)

def sword():
    """Hand-and-a-half sword in the armour's style, in socket space: grip centre at the origin,
    blade along +Z, flat of the blade in the XZ plane (edges along +-X). Built at the world origin and
    moved onto the hand by the rig."""
    p = kit.Part('sword')
    # blade: diamond cross-section, fuller, tapering to a point
    n = 40
    z = np.linspace(0.105, 0.105 + SWORD_LEN, n)
    s = (z - z[0]) / SWORD_LEN
    half_w = 0.026 * (1 - 0.35 * s) * np.where(s > 0.86, np.sqrt(np.clip((1 - s) / 0.14, 0, 1)), 1.0)
    half_t = 0.0055 * (1 - 0.5 * s)
    prof = [(1, 0), (0.55, 0.55), (0.25, 0.8), (0, 0.72), (-0.25, 0.8), (-0.55, 0.55), (-1, 0),
            (-0.55, -0.55), (-0.25, -0.8), (0, -0.72), (0.25, -0.8), (0.55, -0.55)]
    m = len(prof)
    V = np.array([[px * half_w[i], py * half_t[i], z[i]] for i in range(n) for px, py in prof])
    V[-m:] = [0, 0, z[-1] + 0.02]
    F = [[i * m + j, i * m + (j + 1) % m, (i + 1) * m + (j + 1) % m, (i + 1) * m + j] for i in range(n - 1) for j in range(m)]
    UV = np.array([[j / m * 0.1, z[i]] for i in range(n) for j in range(m)])
    p.add(V, F, UV, mat='armor')
    # gold fuller inlay (thin raised strip both faces)
    for sgn in (1, -1):
        pts = np.array([[0, sgn * 0.0048 * (1 - 0.5 * t), zz] for zz, t in zip(z[:-6], s[:-6])])
        Vt, Ft, UVt = tube(pts, 0.0016, n=4)
        p.add(Vt, Ft, UVt, mat='gold')
    # crossguard: gothic arch shape, curved slightly toward the blade, star medallion centre
    g = np.linspace(-1, 1, 25)
    gp = np.c_[g * 0.125, np.zeros_like(g), 0.095 + 0.018 * g ** 2]
    r = 0.011 * (1 - 0.45 * np.abs(g)) + 0.004
    Vt, Ft, UVt = tube(gp, r, n=8)
    p.add(Vt, Ft, UVt, mat='armor')
    for sx in (-1, 1):
        Vs, Fs, UVs = sphere(np.array([sx * 0.128, 0, 0.113]), 0.010); p.add(Vs, Fs, UVs, mat='gold')
    for sgn in (1, -1):
        Vm, Fm, UVm = medallion(np.array([0, sgn * 0.012, 0.098]), (0, sgn, 0), (0, 0, 1), 0.026, depth=0.006)
        p.add(Vm, Fm, UVm, mat='gold_medallion')
    # grip: leather wrap with gold rings
    gz = np.linspace(-0.085, 0.085, 18)
    gr = 0.0145 + 0.0012 * np.sin(np.linspace(0, np.pi * 12, 18))
    Vt, Ft, UVt = tube(np.c_[np.zeros(18), np.zeros(18), gz], gr, n=10); p.add(Vt, Ft, UVt, mat='leather_grip')
    for zz in (-0.085, 0.0, 0.085):
        ring = np.c_[np.zeros(3), np.zeros(3), zz + np.array([-0.004, 0, 0.004])]
        Vt, Ft, UVt = tube(ring, 0.017, n=12); p.add(Vt, Ft, UVt, mat='gold')
    # pommel: star medallion disc
    for sgn in (1, -1):
        Vm, Fm, UVm = medallion(np.array([0, sgn * 0.006, -0.118]), (0, sgn, 0), (0, 0, 1), 0.030, depth=0.006)
        p.add(Vm, Fm, UVm, mat='gold_medallion')
    Vt, Ft, UVt = tube(np.array([[0, -0.006, -0.118], [0, 0.006, -0.118]]), 0.029, n=24); p.add(Vt, Ft, UVt, mat='armor')
    return p


# ============================================================================ gauntlet plates
FINGER_SEGS = [(f, j) for f in range(1, 6) for j in range(1, 4)]

def gauntlet(B, side='L'):
    """Articulated plate gauntlet: a dorsal shell over every phalanx (overlapping toward the tip) and a
    back-of-hand plate over the metacarpals, following the (fitted) MakeHuman hand."""
    sg = 1 if side == 'L' else -1
    bvh = B.bvh(['hand.' + side])
    W_ = B.joint('wrist.' + side); y = kit.unit(B.joint('finger3-1.' + side) - W_)
    across = kit.unit(B.joint('finger2-1.' + side) - B.joint('finger5-1.' + side))
    across = kit.unit(across - np.dot(across, y) * y)
    palm = kit.unit(np.cross(y, across))
    if np.dot(palm, [-sg, 0, 0]) < 0: palm = -palm
    dorsal = -palm
    p = kit.Part('gauntlet.' + side)
    for f, j in FINGER_SEGS:
        b = f'finger{f}-{j}.{side}'
        h = B.joint(b); t = B.joint(b, 'tail')
        L = np.linalg.norm(t - h)
        fr = Frame(h, t - h, sg, fwd=dorsal if f != 1 else kit.unit(dorsal + 0.6 * across))
        def off(th, tt, r, L=L):
            s_ = np.clip(tt / L, 0, 1)
            return 0.0022 + 0.0014 * np.sin(np.pi * s_) + 0.0012 * (s_ > 0.8)
        V, F, FUV, info = ring_piece(fr, bvh, -0.05 * L, 0.92 * L, off, nth=12, nt=5,
                                     th0=-1.75, th1=1.75, closed=False, rmax=0.05, smooth=(0.8, 1.0))
        p.add(V, F, FUV=FUV, mat='armor')
        Vt, Ft, UVt = rim_along(V, info['shape'], info['shape'][0] - 1, 0.0011, closed=False, n=3)
        p.add(Vt, Ft, UVt, mat='gold')
    # back-of-hand plate: over the metacarpals, from the wrist to the knuckles
    K = np.mean([B.joint(f'finger{f}-1.{side}') for f in (2, 3, 4, 5)], axis=0)
    fr = Frame(W_, K - W_, sg, fwd=dorsal)
    L = np.linalg.norm(K - W_)
    V, F, FUV, info = ring_piece(fr, bvh, 0.02 * L, 1.0 * L, lambda th, tt, r: 0.004 + 0.002 * np.cos(th),
                                 nth=16, nt=8, th0=-1.3, th1=1.3, closed=False, rmax=0.08, smooth=(1.0, 1.0))
    p.add(V, F, FUV=FUV, mat='armor')
    for row in (0, info['shape'][0] - 1):
        Vt, Ft, UVt = rim_along(V, info['shape'], row, 0.0015, closed=False, n=3)
        p.add(Vt, Ft, UVt, mat='gold')
    return p

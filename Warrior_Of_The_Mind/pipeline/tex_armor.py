"""Armour atlas textures from maps_armor.npz -> textures/armor_{albedo,normal,orm,emission}.png

Design language (from the upscaled references):
  * plates: near-black lacquered steel with a fine scale/crackle relief
  * kintsugi-like web of thin raised gold veins (3D Voronoi edges, pruned), a finer secondary web
  * double gold border lines running ~4.5 mm and ~8.5 mm inside every plate's outline
  * glowing star sparkles at web nodes + designed hero stars (chest, upper back, greaves, vambraces)
  * medallions: gold ring, dark field with spokes, 8-point star with a glowing core
  * lion knee: the reference lion (upscaled), toned to bronze
ORM = (AO, roughness, metallic). Emission is linear-ish colour * intensity (scaled in the material).
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
from scipy.spatial import cKDTree
import texlib as T, views

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
W = os.path.join(HERE, 'work'); OUT = os.path.join(ROOT, 'textures'); os.makedirs(OUT, exist_ok=True)

DARK = np.array([0.115, 0.104, 0.096])
GOLD = np.array([0.86, 0.58, 0.26])
GOLD_DEEP = np.array([0.78, 0.50, 0.20])
EMIT = np.array([1.0, 0.64, 0.26])
BRONZE_D = np.array([0.20, 0.13, 0.07]); BRONZE_L = np.array([0.80, 0.60, 0.36])
LEATHER = np.array([0.27, 0.15, 0.08])

HERO_STARS = [  # (3D point, radius m, intensity): placed at the nearest armour texel
    ((0.0, -0.20, 1.470), 0.030, 1.0),     # chest lower star (ref front y=390)
    ((0.0, -0.18, 1.405), 0.022, 0.8),
    ((0.0, 0.17, 1.550), 0.045, 1.0),      # upper back big star
    ((0.0, 0.18, 1.430), 0.020, 0.8),
    ((0.225, -0.04, 0.47), 0.030, 1.0),    # greave side stars (both sides by mirroring of the texture)
    ((0.10, -0.08, 0.47), 0.028, 1.0),
    ((0.37, 0.00, 1.33), 0.028, 1.0),      # vambrace upper star
    ((0.39, -0.05, 1.23), 0.020, 0.8),
    ((0.20, -0.10, 1.585), 0.020, 0.7),    # pauldron front
    ((0.17, -0.19, 1.52), 0.018, 0.7),     # chest upper-side stars
    ((0.09, -0.21, 1.585), 0.016, 0.6),
]

def polyline_dist(Q, poly):
    """Distance from points Q (n,3) to a 3D polyline."""
    poly = np.asarray(poly, float); best = np.full(len(Q), 1e9)
    for a, b in zip(poly[:-1], poly[1:]):
        ab = b - a; t = np.clip(((Q - a) @ ab) / max(ab @ ab, 1e-12), 0, 1)
        best = np.minimum(best, np.linalg.norm(Q - (a + t[:, None] * ab), axis=1))
    return best

def hero_lines():
    """Designed glowing gold lines from the reference (points are projected onto the surface via the
    nearest-texel distance, so they only need to lie close to the armour). (poly, half-width, glow)."""
    L = []
    # sternum line: collar -> chest medallion -> belt
    L.append(([(0, -0.17, 1.690), (0, -0.20, 1.60), (0, -0.215, 1.50), (0, -0.21, 1.40), (0, -0.19, 1.30)], 0.0011, 1.0))
    # arc under the pecs, lines radiating from the medallion
    arc = [(0.19 * np.sin(a), -0.20 + 0.06 * (1 - np.cos(a)), 1.47 - 0.07 * (1 - np.cos(a))) for a in np.linspace(-1.2, 1.2, 25)]
    L.append((arc, 0.0010, 0.8))
    for ang in np.linspace(-2.6, 2.6, 7):
        if abs(ang) < 0.1: continue
        L.append(([(0.03 * np.sin(ang), -0.215, 1.555 + 0.03 * np.cos(ang)), (0.16 * np.sin(ang), -0.20, 1.555 + 0.14 * np.cos(ang))], 0.0007, 0.6))
    # back: vertical spine line + radiating lines from the big star
    L.append(([(0, 0.15, 1.69), (0, 0.19, 1.55), (0, 0.17, 1.30)], 0.0011, 1.0))
    for ang in np.linspace(-2.4, 2.4, 6):
        L.append(([(0.03 * np.sin(ang), 0.19, 1.55 + 0.03 * np.cos(ang)), (0.17 * np.sin(ang), 0.17, 1.55 + 0.15 * np.cos(ang))], 0.0007, 0.6))
    for sx in (1, -1):
        # greave: glowing centre keel + V lines
        L.append(([(0.160 * sx, -0.075, 0.62), (0.170 * sx, -0.080, 0.45), (0.180 * sx, -0.070, 0.27)], 0.0012, 1.0))
        for side in (-1, 1):
            L.append(([(0.160 * sx + side * 0.055, -0.035, 0.62), (0.165 * sx, -0.080, 0.50)], 0.0009, 0.7))
            L.append(([(0.170 * sx + side * 0.06, -0.03, 0.30), (0.172 * sx, -0.078, 0.40), (0.175 * sx + side * 0.05, -0.04, 0.52)], 0.0007, 0.5))
        # vambrace: lateral glowing spine
        L.append(([(0.355 * sx, 0.005, 1.35), (0.385 * sx, -0.015, 1.25), (0.415 * sx, -0.035, 1.16)], 0.0011, 1.0))
    return L

def main(res_out=4096):
    d = np.load(os.path.join(W, 'maps_armor.npz'))
    P = d['P']; N = d['N']; pat = d['pat']; D = d['D']; obj = d['obj']; mat = d['mat']; mask = d['mask']
    mats = list(d['mat_names']); objs = list(d['obj_names'])
    R = P.shape[0]
    print('materials', mats)
    # texel size (m)
    dp = np.linalg.norm(P[:, 1:] - P[:, :-1], axis=-1)
    ok = mask[:, 1:] & mask[:, :-1] & (obj[:, 1:] == obj[:, :-1])
    texel = float(np.median(dp[ok])); print('texel size mm', texel * 1000)
    idx = np.where(mask.ravel())[0]
    Pm = P.reshape(-1, 3)[idx].astype(np.float64)
    M = mat.ravel()[idx]
    def is_(name): return M == (mats.index(name) if name in mats else -99)

    alb = np.zeros((len(idx), 3), np.float32); rough = np.full(len(idx), 0.5, np.float32)
    metal = np.zeros(len(idx), np.float32); ao = np.ones(len(idx), np.float32)
    height = np.zeros(len(idx), np.float32); emis = np.zeros(len(idx), np.float32)
    Dm = D.reshape(-1, 3)[idx]
    # ---------------------------------------------------------------- plates
    a = is_('armor')
    Pa = Pm[a]
    Na = N.reshape(-1, 3)[idx][a].astype(np.float64)
    Na /= np.linalg.norm(Na, axis=1, keepdims=True) + 1e-9
    v1 = T.voronoi_edge(Pa, Na, 0.046, 1)
    keep1 = (T.pair_hash(v1[:, 2], v1[:, 3]) < 0.50) * T.smoothstep(0.25, 0.45, v1[:, 1])
    w1 = 0.00035 + 0.00030 * (T.noise(Pa, 0.06, 11, 2) * 0.5 + 0.5)
    line1 = T.line_mask(v1[:, 0], w1, texel * 0.9) * keep1
    v2 = T.voronoi_edge(Pa, Na, 0.019, 2)
    keep2 = (T.pair_hash(v2[:, 2], v2[:, 3]) < 0.26) * T.smoothstep(0.25, 0.45, v2[:, 1])
    line2 = T.line_mask(v2[:, 0], 0.00020, texel * 0.8) * keep2 * 0.85
    v3 = T.voronoi_edge(Pa, Na, 0.0060, 3)
    groove = T.line_mask(v3[:, 0], 0.00018, texel * 0.8) * T.smoothstep(0.2, 0.4, v3[:, 1])
    v1 = np.c_[v1[:, :1], v1[:, :1], v1[:, :1], v1[:, 2:4]]    # keep ids at [3],[4] for glow selection
    dd = Dm[a, 0]
    border = np.maximum(T.line_mask(np.abs(dd - 0.0045), 0.00065, texel), T.line_mask(np.abs(dd - 0.0088), 0.00042, texel) * 0.9)
    recess = T.smoothstep(0.0050, 0.0056, dd) * (1 - T.smoothstep(0.0080, 0.0086, dd))
    v4 = T.voronoi(Pa, 0.022, 5)
    speck = (v4[:, 0] < 0.0005) & (T.pair_hash(v4[:, 3], v4[:, 3] + 7) < 0.15)
    gold = np.clip(np.maximum.reduce([line1, line2, border, speck.astype(np.float32) * 0.9]), 0, 1)
    n_lo = T.noise(Pa, 0.12, 21, 3); n_hi = T.noise(Pa, 0.012, 22, 2)
    base = DARK * (1 + 0.22 * n_lo[:, None] + 0.10 * n_hi[:, None])
    base = base * (1 - 0.35 * groove[:, None]) * (1 - 0.25 * recess[:, None])
    gcol = GOLD * (1 + 0.08 * n_hi[:, None]) * (1 - 0.25 * (1 - line1[:, None]) * line2[:, None])
    alb[a] = base * (1 - gold[:, None]) + gcol * gold[:, None]
    rough[a] = (0.46 + 0.07 * n_hi + 0.10 * groove) * (1 - gold) + 0.25 * gold
    metal[a] = 0.62 * (1 - gold) + 1.0 * gold
    ao[a] = 1 - 0.35 * groove - 0.2 * recess
    height[a] = 0.00032 * np.maximum(line1, line2) + 0.00040 * border - 0.00012 * groove - 0.00010 * recess \
        + 0.00006 * n_lo + 0.00025 * speck
    # designed hero lines (distance to 3D polylines)
    hl = np.zeros(a.sum(), np.float32); hg = np.zeros(a.sum(), np.float32)
    for poly, wdt, glow in hero_lines():
        dmin = polyline_dist(Pa, poly)
        m_ = T.line_mask(dmin, wdt, texel) * (dmin < 0.02)
        hl = np.maximum(hl, m_); hg = np.maximum(hg, m_ * glow)
    gold = np.maximum(gold, hl)
    alb[a] = alb[a] * (1 - hl[:, None]) + GOLD * 1.05 * hl[:, None]
    rough[a] = rough[a] * (1 - hl) + 0.22 * hl; metal[a] = np.maximum(metal[a], hl)
    height[a] += 0.0004 * hl
    # glowing veins: a subset of the main web carries light, strongest near the hero stars
    glow_sel = (T.pair_hash(v1[:, 3] + 3, v1[:, 4] + 5) < 0.42).astype(np.float32)
    emis[a] = 0.03 * gold + 0.12 * line1 * glow_sel + 1.3 * hg
    # ---------------------------------------------------------------- gold trims
    g = is_('gold')
    ng = T.noise(Pm[g], 0.01, 31, 2)
    alb[g] = GOLD * (1 + 0.07 * ng[:, None]); rough[g] = 0.24 + 0.05 * ng; metal[g] = 1.0; emis[g] = 0.12
    # ---------------------------------------------------------------- medallions (unit disc pattern uv)
    m_ = is_('gold_medallion')
    pu = pat.reshape(-1, 2)[idx][m_]
    dx = (pu[:, 0] - 0.5) * 2; dy = (pu[:, 1] - 0.5) * 2
    r = np.sqrt(dx * dx + dy * dy); ang = np.arctan2(dy, dx)
    ring = (r > 0.80).astype(np.float32)
    ring_groove = T.line_mask(np.abs(r - 0.86), 0.012, 0.01) + T.line_mask(np.abs(r - 0.965), 0.01, 0.01)
    spokes = T.line_mask(np.abs(np.sin(ang * 8)) * r, 0.018, 0.012) * (r > 0.30) * (r < 0.80)
    inner = T.line_mask(np.abs(r - 0.50), 0.012, 0.01)
    k = 8; aa = (ang + np.pi / k) % (2 * np.pi / k) - np.pi / k
    longr = (np.round(ang / (2 * np.pi / k)) % 2 == 0)
    L = np.where(longr, 0.78, 0.55)
    star = (np.abs(aa) * r < 0.20 * np.clip(1 - r / L, 0, 1)) & (r < L)
    medg = np.clip(ring * (1 - 0.8 * ring_groove) + spokes + inner + star, 0, 1)
    alb[m_] = DARK * 1.2 * (1 - medg[:, None]) + GOLD * medg[:, None]
    rough[m_] = 0.45 * (1 - medg) + 0.22 * medg; metal[m_] = 0.7 + 0.3 * medg
    emis[m_] = 0.15 * medg + 1.2 * star * np.clip(1 - r / 0.6, 0, 1) + 1.5 * np.exp(-r / 0.08)
    height[m_] = 0.0003 * medg
    # ---------------------------------------------------------------- lion (reference crop, bronze)
    l_ = is_('bronze_lion')
    if l_.any():
        up = views.ref_image('front', up=True)
        u0, u1, v0, v1 = 344, 444, 893, 1000
        crop = up[v0 * 4:v1 * 4, u0 * 4:u1 * 4][..., ::-1].astype(np.float32) / 255
        pu = pat.reshape(-1, 2)[idx][l_]
        # pattern uv holds the slot shift in u: take the fractional part within the slot
        uu = pu[:, 0] - np.floor(pu[:, 0] / 4.0) * 4.0
        xs = np.clip(uu, 0, 1) * (crop.shape[1] - 1); ys = (1 - np.clip(pu[:, 1], 0, 1)) * (crop.shape[0] - 1)
        c = T.sample(crop, xs, ys)
        lum = c @ np.array([0.3, 0.55, 0.15])
        l = np.clip((lum - 0.05) / 0.75, 0, 1) ** 0.9
        sat = c.max(1) - c.min(1)
        bronze = BRONZE_D * (1 - l[:, None]) + BRONZE_L * l[:, None]
        # keep the dark plate / gold lines around the lion as in the crop
        is_bronze = np.clip((l - 0.12) / 0.2, 0, 1) * np.clip(1 - (sat - 0.45) / 0.2, 0, 1)
        alb[l_] = bronze * is_bronze[:, None] + c * 0.9 * (1 - is_bronze[:, None])
        rough[l_] = 0.38; metal[l_] = 0.9; height[l_] = 0
        eye_glow = np.clip((c[:, 0] - c[:, 2] - 0.35) / 0.2, 0, 1) * (lum > 0.45)
        emis[l_] = 0.6 * eye_glow
    # ---------------------------------------------------------------- leathers, orb, sole
    for name, col, rgh in [('leather_belt', LEATHER, 0.62), ('leather_sheath', LEATHER * 0.55, 0.5),
                           ('leather_grip', LEATHER * 0.7, 0.7), ('leather_sole', LEATHER * 0.45, 0.8)]:
        s_ = is_(name)
        if not s_.any(): continue
        Pl = Pm[s_]; nl = T.noise(Pl, 0.03, 41, 4); nf = T.noise(Pl, 0.004, 42, 2)
        alb[s_] = col * (1 + 0.25 * nl[:, None] + 0.10 * nf[:, None]); rough[s_] = rgh + 0.08 * nf
        metal[s_] = 0; height[s_] = 0.00008 * nf
        if name == 'leather_belt':
            dd = Dm[s_, 0]
            pu = pat.reshape(-1, 2)[idx][s_]
            stitch = T.line_mask(np.abs(dd - 0.004), 0.0005, texel) * (np.sin(pu[:, 0] / 0.005 * np.pi) > 0)
            stud_pos = (np.abs(((pu[:, 0] % 0.03) / 0.03) - 0.5) * 0.03)
            stud = T.line_mask(np.sqrt(stud_pos ** 2 + np.maximum(0.0275 - dd, 0) ** 2 * 0), 0.0028, texel) * (dd > 0.0245)
            alb[s_] = alb[s_] * (1 - stitch[:, None] * 0.5) + GOLD * stud[:, None] - alb[s_] * stud[:, None]
            metal[s_] = stud; rough[s_] = rough[s_] * (1 - stud) + 0.25 * stud
            height[s_] += 0.0012 * np.sqrt(np.clip(1 - (stud_pos / 0.003) ** 2, 0, 1)) * (dd > 0.0245) - 0.0002 * stitch
    o_ = is_('armor_orb')
    alb[o_] = DARK * 0.8; rough[o_] = 0.18; metal[o_] = 1.0
    # ---------------------------------------------------------------- write back to the atlas
    def img(v, ch):
        out = np.zeros((R * R, ch), np.float32); out[idx] = v.reshape(len(idx), ch); return out.reshape(R, R, ch)
    ALB = img(alb, 3); ORM = img(np.c_[ao, rough, metal], 3); H = img(height, 1)[..., 0]; EM = img(emis, 1)[..., 0]
    # hero stars + random web-node sparkles
    atex = np.where(mask.ravel())[0]
    tree = cKDTree(Pm)
    ys_all, xs_all = np.divmod(idx, R)
    rng = np.random.default_rng(3)
    plate_idx = np.where(a)[0]
    area = len(plate_idx) * texel * texel
    n_rand = int(area / 0.02) * 0          # no random glitter: only the designed stars glow
    stars = [(Pm[plate_idx[i]], rng.uniform(0.010, 0.022), rng.uniform(0.45, 0.95)) for i in rng.choice(len(plate_idx), n_rand, replace=False)]
    for p3, rad, inten in HERO_STARS:
        for sx in (1, -1):
            q = np.array(p3) * [sx, 1, 1]
            dist, j = tree.query(q)
            if dist < 0.03: stars.append((Pm[j], rad, inten))
    GOLDM = np.zeros((R, R), np.float32)
    for p3, rad, inten in stars:
        dist, j = tree.query(p3)
        cy, cx = ys_all[j], xs_all[j]
        size = int(2 * rad / texel) | 1
        if size < 7: continue
        spr = T.star_sprite(size, rays=8 if rad > 0.018 else 4)
        isl = (obj == obj.ravel()[idx[j]]).astype(np.float32)
        T.splat(EM, cx, cy, spr, inten * 1.6, isl)
        T.splat(GOLDM, cx, cy, np.clip(spr * 1.4, 0, 1), 1.0, isl)
    ALB = ALB * (1 - GOLDM[..., None]) + GOLD[None, None] * 1.05 * GOLDM[..., None]
    ORM[..., 1] = ORM[..., 1] * (1 - GOLDM) + 0.25 * GOLDM; ORM[..., 2] = np.maximum(ORM[..., 2], GOLDM)
    H = H + 0.0003 * GOLDM
    trust = {mats.index(m): 0.0 for m in ('bronze_lion',) if m in mats}
    T.apply_projection('armor', W, mask, ALB, ORM, EM, H, mat, trust)
    NRM = T.height_to_normal(H, mask, texel, strength=1.0, island=obj)
    EMC = np.clip(EM[..., None] * EMIT[None, None], 0, 1)
    # padding for mips
    ALB = T.dilate(ALB, mask); ORM = T.dilate(ORM, mask); NRM = T.dilate(NRM, mask); EMC = T.dilate(EMC, mask)
    if res_out != R:
        f = lambda x: cv2.resize(x, (res_out, res_out), interpolation=cv2.INTER_AREA)
        ALB, ORM, NRM, EMC = f(ALB), f(ORM), f(NRM), f(EMC)
    T.save_rgb(os.path.join(OUT, 'armor_albedo.png'), np.clip(ALB, 0, 1))
    T.save_rgb(os.path.join(OUT, 'armor_orm.png'), np.clip(ORM, 0, 1))
    cv2.imwrite(os.path.join(OUT, 'armor_normal.png'), cv2.cvtColor(T.encode_normal(NRM), cv2.COLOR_RGB2BGR))
    T.save_rgb(os.path.join(OUT, 'armor_emission.png'), EMC)
    print('armor textures written', len(stars), 'stars')

if __name__ == '__main__':
    main()

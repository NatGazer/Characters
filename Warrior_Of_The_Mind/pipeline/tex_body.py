"""Body texture (MakeHuman UV layout) -> textures/body_{albedo,normal,orm,emission,sss}.png

* skin (head + neck): projected from the upscaled front / left / right references (per-view head
  alignment), filled with a matched skin tone + procedural pore/stubble detail where no view sees it,
  scalp painted as dark hair roots. Eye-slit region neutralised (the eyeballs carry the golden iris).
* undersuit: dark reptile-scale leather (3D Voronoi scales, raised centres).
* gauntlets: blackened steel finger plates with gold rims at the knuckle joints + kintsugi web.
Runs under bpy (ray casts for visibility).
"""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2, bpy
import texlib as T, project, views, kit, hair as H

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
W = os.path.join(HERE, 'work'); OUT = os.path.join(ROOT, 'textures')
GOLD = np.array([0.86, 0.58, 0.26]); DARK = np.array([0.10, 0.092, 0.085]); EMIT = np.array([1.0, 0.64, 0.26])
SKIN = np.array([0.72, 0.50, 0.40]); HAIRC = np.array([0.10, 0.065, 0.045])
SKIN_LIGHTEN, SKIN_SAT = 1.22, 0.92    # lighter complexion than the painting (user direction)

def load_warps():
    """2D thin-plate warps model-image -> painting per view (face_warp.py), fading to the median
    offset away from the face."""
    from scipy.interpolate import RBFInterpolator
    p = os.path.join(W, 'face_warp.npz')
    if not os.path.exists(p): return None
    d = np.load(p); out = {}
    for v in ('front', 'left', 'right'):
        if v + '_model' not in d: continue
        Mv, Rv = d[v + '_model'], d[v + '_ref']
        rbf = RBFInterpolator(Mv, Rv - Mv, kernel='thin_plate_spline', smoothing=2.0, degree=1)   # all landmarks: a local neighbour set leaves seams
        med = np.median(Rv - Mv, axis=0); c = Mv.mean(0); rad = np.linalg.norm(Mv - c, axis=1).max()
        def f(uv, rbf=rbf, med=med, c=c, rad=rad):
            dd = np.linalg.norm(uv - c, axis=1)
            w = np.clip(1 - (dd - rad) / (0.6 * rad), 0, 1)[:, None]
            out_ = np.empty_like(uv)
            for i in range(0, len(uv), 200000):
                sl = slice(i, i + 200000)
                out_[sl] = uv[sl] + w[sl] * rbf(uv[sl]) + (1 - w[sl]) * med
            return out_
        out[v] = f
    return out

def delight_refs(sigma_mm=11.0, strength=0.75):
    """Remove large-scale lighting from the (upscaled) references on the skin: divide by the
    normalised-convolution low-pass of skin luminance, keep pores / brows / beard / lips."""
    for v in ('front', 'left', 'right'):
        img = views.ref_image(v, up=True).astype(np.float32) / 255
        rgb = img[..., ::-1]
        lum = rgb @ np.array([0.3, 0.59, 0.11], np.float32)
        skin = ((rgb[..., 0] > rgb[..., 2] + 0.06) & (lum > 0.22) & (lum < 0.92) & (rgb[..., 0] > rgb[..., 1])).astype(np.float32)
        sg = sigma_mm / 1000 / (views.S / 4)
        # work at 1/4 res for speed
        sm = cv2.resize(skin, None, fx=0.25, fy=0.25, interpolation=cv2.INTER_AREA)
        lm = cv2.resize(lum * skin, None, fx=0.25, fy=0.25, interpolation=cv2.INTER_AREA)
        low = cv2.GaussianBlur(lm, (0, 0), sg / 4) / np.maximum(cv2.GaussianBlur(sm, (0, 0), sg / 4), 1e-3)
        low = cv2.resize(low, (img.shape[1], img.shape[0]), interpolation=cv2.INTER_LINEAR)
        target = np.median(lum[skin > 0.5])
        gain = (target / np.maximum(low, 0.05)) ** strength
        gain = np.clip(gain, 0.6, 1.8)
        out = np.clip(img * gain[..., None], 0, 1)
        cv2.imwrite(os.path.join(W, 'up4', views.VIEWS[v][0] + '_delit.png'), (out * 255).astype(np.uint8))

# face-landmark groups (MediaPipe indices, radius in mm) kept untouched when the painted strands are removed
PROTECT_PTS = {
    'brows': ([70, 63, 105, 66, 107, 336, 296, 334, 293, 300, 46, 53, 52, 65, 55, 276, 283, 282, 295, 285], 4.5),
    'eyes': ([33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246,
              362, 382, 381, 380, 374, 373, 390, 249, 263, 466, 388, 387, 386, 385, 384, 398], 4.0),
    'nose': ([1, 2, 4, 5, 98, 327, 94, 19, 48, 278, 64, 294, 129, 358], 3.0),
}
# lower face (moustache, lips, goatee, jaw stubble): the polygon under the nose along the jaw
# brows, eyes and nose bridge (front view): their natural shading must not be repainted; the cheeks are not included
CENTRAL_FACE = [70, 63, 105, 66, 107, 336, 296, 334, 293, 300, 46, 276, 33, 263, 130, 359, 6, 197, 195, 5, 4, 1]
LOWER_FACE = [234, 93, 132, 58, 172, 136, 150, 149, 176, 148, 152, 377, 400, 378, 379, 365, 397, 288, 361, 323, 454,
              366, 401, 435, 358, 327, 2, 98, 129, 215, 177, 137]

def clean_refs(kernel=61, thr=0.035):
    """The paintings have locks of hair falling across the face; the model's hair is swept back, so those
    painted strands would read as dirt on the skin. Thin dark lines (black-hat of luminance) on the face are
    repainted from the surrounding skin (inpainting) in the de-lit references, except on the brows, eyes,
    nose and the whole bearded lower face (from the painting's own landmarks).
    Writes work/up4/<name>_clean.png (projected instead of _delit)."""
    import face_fit as FF
    for v in ('front', 'left', 'right'):
        name = views.VIEWS[v][0]
        img = cv2.imread(os.path.join(W, 'up4', name + '_delit.png'))
        R = FF.ref_lm(v)
        if R is None:
            cv2.imwrite(os.path.join(W, 'up4', name + '_clean.png'), img); continue
        pts = R[:, :2] * 4.0                                   # reference px -> 4x upscaled px
        c0 = pts.min(0) - (pts.max(0) - pts.min(0)) * 0.45; c1 = pts.max(0) + (pts.max(0) - pts.min(0)) * 0.45
        x0, y0 = np.maximum(c0.astype(int), 0); x1, y1 = np.minimum(c1.astype(int), [img.shape[1], img.shape[0]])
        crop = img[y0:y1, x0:x1]
        lum = crop[..., ::-1].astype(np.float32) / 255 @ np.array([0.3, 0.59, 0.11], np.float32)
        bh = cv2.morphologyEx(lum, cv2.MORPH_BLACKHAT, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (kernel, kernel)))
        m = (bh > thr).astype(np.uint8)
        prot = np.zeros_like(m)
        P = pts - [x0, y0]
        for ids, r in PROTECT_PTS.values():
            for (u, w) in P[ids]:
                cv2.circle(prot, (int(u), int(w)), int(r / 1000 / (views.S / 4)), 1, -1)
        cv2.fillPoly(prot, [P[LOWER_FACE].astype(np.int32)], 1)
        if v == 'front':                                       # (in profile the hull would cover the whole cheek)
            cv2.fillPoly(prot, [cv2.convexHull(P[CENTRAL_FACE].astype(np.int32))], 1)
        prot = cv2.dilate(prot, np.ones((13, 13), np.uint8))
        m = cv2.dilate(m * (1 - prot), np.ones((9, 9), np.uint8))
        # only on the face and forehead skin (not the painted hair around it)
        hull = cv2.convexHull(P.astype(np.float32))[:, 0]; hc = hull.mean(0)
        face = np.zeros_like(m); cv2.fillPoly(face, [((hull - hc) * [1.12, 1.06] + hc).astype(np.int32)], 1)
        m *= face
        m[int(P[2, 1]):] = 0                                   # nothing below the nose: the stubble stays as painted
        for e in (234, 454):                                   # ears
            cv2.circle(m, (int(P[e, 0]), int(P[e, 1])), 30, 0, -1)
        out = img.copy()
        out[y0:y1, x0:x1] = cv2.inpaint(crop, m, 9, cv2.INPAINT_TELEA)
        cv2.imwrite(os.path.join(W, 'up4', name + '_clean.png'), out)
        print(f'{v}: painted strands repainted on {int(m.sum())} px')

def main(res=4096):
    import bake_maps
    bpy.ops.wm.open_mainfile(filepath=os.path.join(W, 'model_uv.blend'))
    bake_maps.bake_group('body', res, objs_filter=['body'])
    d = np.load(os.path.join(W, 'maps_body.npz'))
    P = d['P']; N = d['N']; mask = d['mask']; mat = d['mat']; mats = list(d['mat_names'])
    R = P.shape[0]
    idx = np.where(mask.ravel())[0]
    Pm = P.reshape(-1, 3)[idx].astype(np.float64); Nm = N.reshape(-1, 3)[idx].astype(np.float64)
    Nm /= np.linalg.norm(Nm, axis=1, keepdims=True) + 1e-9
    M = mat.ravel()[idx]
    dp = np.linalg.norm(P[:, 1:] - P[:, :-1], axis=-1); ok = mask[:, 1:] & mask[:, :-1]
    texel = float(np.median(dp[ok][dp[ok] < 0.01]))
    n = len(idx)
    alb = np.zeros((n, 3), np.float32); rough = np.full(n, 0.5, np.float32); metal = np.zeros(n, np.float32)
    height = np.zeros(n, np.float32); emis = np.zeros(n, np.float32); sss = np.zeros(n, np.float32)
    ao = np.ones(n, np.float32)
    isk = M == mats.index('skin'); ius = M == mats.index('undersuit'); ig = M == mats.index('gauntlet')
    # ---------------------------------------------------------------- skin
    off = json.load(open(os.path.join(W, 'face_align.json'))) if os.path.exists(os.path.join(W, 'face_align.json')) else {}
    delight_refs()
    clean_refs()
    warps = load_warps()
    bvh = project.scene_bvh(exclude=('hair', 'eyes'))
    Ps, Ns = Pm[isk], Nm[isk]
    col, wsum = project.project(Ps, Ns, bvh, ('front', 'left', 'right'), offsets=off, power=4.0, suffix='_clean', warps=warps)
    q = Ps - H.HEAD_C
    scalp = H.scalp_mask_points(Ps) if hasattr(H, 'scalp_mask_points') else None
    conf = np.clip(wsum / 0.25, 0, 1)
    # the reference face region reliable only where it is skin coloured (not hair / collar)
    lum = col @ np.array([0.3, 0.59, 0.11]); sat = col.max(1) - col.min(1)
    skinlike = (col[:, 0] > col[:, 2] + 0.05) & (lum > 0.18) & (lum < 0.9)
    tone = np.median(col[(conf > 0.8) & skinlike & (q[:, 2] > -0.06) & (q[:, 2] < 0.02)], axis=0) if (conf > 0.8).any() else SKIN
    print('skin tone', tone)
    # grey-white painted highlights under the jaw are not skin: drop them (filled from the skin tone)
    t_lum = tone @ np.array([0.3, 0.59, 0.11])
    conf = conf * ~((lum > 1.08 * t_lum) & (sat < 0.14) & (q[:, 2] < -0.04))
    npore = T.noise(Ps, 0.0012, 50, 2); nblot = T.noise(Ps, 0.03, 51, 3)
    fill = tone * (1 + 0.06 * nblot[:, None]) * np.array([1.0, 0.97, 0.95])
    # stubble zone (jaw/cheeks below the cheekbones, front half)
    az = np.arctan2(q[:, 0], -q[:, 1])
    beard = (T.smoothstep(-0.02, -0.05, q[:, 2]) * T.smoothstep(-0.14, -0.12, q[:, 2]) * (np.abs(az) < 1.9)).astype(np.float32)
    fill = fill * (1 - 0.35 * beard[:, None]) + HAIRC * 0.35 * beard[:, None]
    # scalp: hairline region -> dark hair roots
    front = np.clip(np.cos(az), 0, 1) ** 1.5; back = np.clip(-np.cos(az), 0, 1); side = np.abs(np.sin(az))
    hairline = H.HAIRLINE_FRONT * front - 0.014 * side - 0.095 * back
    scalp = T.smoothstep(hairline - 0.004, hairline + 0.012, q[:, 2])
    # goatee / mustache shadow on the skin under the goatee cards (follows the sculpted chin via the landmarks)
    L3f = os.path.join(W, 'face_landmarks3d.npy')
    goat = np.zeros(len(Ps))
    if os.path.exists(L3f):
        goat = np.clip((H.beard_density(np.load(L3f))(Ps) - 0.5) / 0.4, 0, 1)
    # de-light: the reference is already lit (key from the upper left); remove the large-scale shading
    DELIGHT = 0.92
    col = col * DELIGHT; fill = fill * DELIGHT
    base = col * conf[:, None] + fill * (1 - conf[:, None])
    hs = T.noise(np.c_[Ps[:, 0] * 8, Ps[:, 1], Ps[:, 2]], 0.004, 71, 3)       # combed strand streaks
    scalp_col = np.array([0.12, 0.075, 0.05]) * (0.8 + 0.5 * np.clip(hs, -1, 1)[:, None])
    base = base * (1 - scalp[:, None]) + scalp_col * scalp[:, None]
    base = base * (1 - 0.8 * goat[:, None]) + (HAIRC * 1.5) * 0.8 * goat[:, None]
    # eye slits: neutralise projected iris colour on the lids (eyeballs carry the iris)
    L3f = os.path.join(W, 'face_landmarks3d.npy')
    eyes = list(np.load(L3f)[[468, 473]]) if os.path.exists(L3f) and len(np.load(L3f)) > 473 else [np.array([sx * 0.033, -0.083, 1.853]) for sx in (1, -1)]
    de = np.min([np.linalg.norm(Ps - e, axis=1) for e in eyes], axis=0)
    lid = 1 - T.smoothstep(0.010, 0.016, de)
    darkened = np.minimum(base, fill * 0.55)
    base = base * (1 - lid[:, None]) + (base * 0.5 + darkened * 0.5) * lid[:, None]
    # compress painted specular highlights (the paintings are lit): cap luminance near the skin tone
    lum_b = base @ np.array([0.3, 0.59, 0.11]); cap = (tone @ np.array([0.3, 0.59, 0.11])) * 1.12
    over = np.clip(lum_b / np.maximum(cap, 1e-3), 1, None)
    base = base / (1 + (over[:, None] - 1) * 0.85)
    # lighter complexion: lift and slightly desaturate the bright skin only, so dark stubble, goatee and
    # brows keep their colour (by brightness, not by region: no seams). Scalp / hairline untouched.
    lum_s = base @ np.array([0.3, 0.59, 0.11])
    light = np.clip((lum_s[:, None] + (base - lum_s[:, None]) * SKIN_SAT) * SKIN_LIGHTEN, 0, 1)
    amt = (T.smoothstep(0.14, 0.30, lum_s) * (1 - scalp))[:, None]
    base = base * (1 - amt) + light * amt
    alb[isk] = np.clip(base * (1 + 0.04 * npore[:, None]), 0, 1)
    # bare facial skin that must stay clean (for the blob clean-up in texture space below)
    clean_face = np.zeros(n, bool)
    L3p = os.path.join(W, 'face_landmarks3d.npy')
    if os.path.exists(L3p):
        from scipy.spatial import cKDTree
        L3 = np.nan_to_num(np.load(L3p))
        prot = H.beard_density(L3)(Ps) > 0.12
        for ids, r in (([70, 63, 105, 66, 107, 336, 296, 334, 293, 300, 46, 53, 52, 65, 55, 276, 283, 282, 295, 285], 0.009),
                       (PROTECT_PTS['eyes'][0] + [468, 473], 0.006), ([1, 2, 4, 98, 327, 94, 19, 64, 294, 48, 278], 0.006),
                       ([13, 14, 61, 291, 0, 17, 37, 267, 84, 314, 78, 308], 0.008)):
            prot |= cKDTree(L3[ids]).query(Ps)[0] < r
        ear = (np.abs(q[:, 0]) > 0.058) & (np.abs(q[:, 1]) < 0.04)
        clean_face[np.where(isk)[0]] = (q[:, 1] < -0.01) & (q[:, 2] > -0.10) & (scalp < 0.05) & ~ear & ~prot
    rough[isk] = 0.52 + 0.08 * npore - 0.1 * (q[:, 2] > 0.0) * (1 - scalp) + 0.25 * scalp
    height[isk] = 0.00004 * npore
    sss[isk] = 1.0 * (1 - scalp)
    # ---------------------------------------------------------------- undersuit
    Pu = Pm[ius]; Nu = Nm[ius]
    v = T.voronoi(Pu, 0.0085, 61)
    f1 = v[:, 0] / 0.0085
    scale = np.clip(1 - f1 * 1.6, 0, 1) ** 0.6
    edge = T.line_mask((v[:, 1] - v[:, 0]) / 2, 0.00035, texel)
    nl = T.noise(Pu, 0.1, 62, 3)
    alb[ius] = DARK * 1.15 * (1 + 0.35 * scale[:, None] + 0.15 * nl[:, None]) * (1 - 0.4 * edge[:, None])
    rough[ius] = 0.55 - 0.15 * scale; metal[ius] = 0.1
    height[ius] = 0.0005 * scale - 0.0002 * edge
    ao[ius] = 1 - 0.35 * edge
    # ---------------------------------------------------------------- gauntlets
    Pg = Pm[ig]; Ng = Nm[ig]
    B = kit.Body()
    knuckles = []
    for side in ('L', 'R'):
        for f in range(1, 6):
            for j in range(1, 4):
                b = f'finger{f}-{j}.{side}'
                knuckles.append(B.joint(b))
        knuckles.append(B.joint('wrist.' + side))
        for f in range(1, 5): knuckles.append(B.joint(f'metacarpal{f}.' + side))
    knuckles = np.array(knuckles)
    from scipy.spatial import cKDTree
    dk, _ = cKDTree(knuckles).query(Pg)
    rims = T.line_mask(np.abs(dk - 0.011), 0.0007, texel)
    ve = T.voronoi_edge(Pg, Ng, 0.02, 63)
    web = T.line_mask(ve[:, 0], 0.00025, texel) * (T.pair_hash(ve[:, 2], ve[:, 3]) < 0.45) * T.smoothstep(0.3, 0.5, ve[:, 1])
    g = np.clip(rims + web * 0.8, 0, 1)
    ng = T.noise(Pg, 0.01, 64, 2)
    alb[ig] = DARK * (1 + 0.2 * ng[:, None]) * (1 - g[:, None]) + GOLD * g[:, None]
    rough[ig] = 0.38 * (1 - g) + 0.25 * g; metal[ig] = 0.8 + 0.2 * g
    height[ig] = 0.0003 * g - 0.0004 * T.line_mask(np.abs(dk - 0.0085), 0.0006, texel)
    emis[ig] = 0.12 * g
    # ---------------------------------------------------------------- assemble
    def img(vv, ch):
        out = np.zeros((R * R, ch), np.float32); out[idx] = vv.reshape(n, ch); return out.reshape(R, R, ch)
    ALB = img(alb, 3); ORM = img(np.c_[ao, rough, metal], 3); Hh = img(height, 1)[..., 0]
    # remaining dark blobs on bare facial skin (painted hair seen from views the face warp cannot align):
    # black-hat of luminance in texture space, inpainted from the surrounding skin
    CF = img(clean_face.astype(np.float32), 1)[..., 0] > 0.5
    if CF.any():
        lumA = ALB @ np.array([0.3, 0.59, 0.11], np.float32)
        kpx = int(0.012 / texel) | 1
        bh = cv2.morphologyEx(lumA, cv2.MORPH_BLACKHAT, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (kpx, kpx)))
        blob = ((bh > 0.035) & CF).astype(np.uint8)
        blob = cv2.dilate(blob, np.ones((5, 5), np.uint8)) & CF.astype(np.uint8)
        a8 = (np.clip(ALB, 0, 1) * 255).astype(np.uint8)
        ALB = np.where(blob[..., None] > 0, cv2.inpaint(a8, blob, 7, cv2.INPAINT_TELEA).astype(np.float32) / 255, ALB)
        print('face blobs cleaned on', int(blob.sum()), 'texels')
    EMC = np.clip(img(emis, 1) * EMIT, 0, 1); SSS = img(sss, 1)[..., 0]
    NRM = T.height_to_normal(Hh, mask, texel, 1.0)
    ALB = T.dilate(ALB, mask); ORM = T.dilate(ORM, mask); NRM = T.dilate(NRM, mask); EMC = T.dilate(EMC, mask)
    SSS = T.dilate(SSS, mask)
    T.save_rgb(os.path.join(OUT, 'body_albedo.png'), np.clip(ALB, 0, 1))
    T.save_rgb(os.path.join(OUT, 'body_orm.png'), np.clip(ORM, 0, 1))
    cv2.imwrite(os.path.join(OUT, 'body_normal.png'), cv2.cvtColor(T.encode_normal(NRM), cv2.COLOR_RGB2BGR))
    T.save_rgb(os.path.join(OUT, 'body_emission.png'), EMC)
    cv2.imwrite(os.path.join(OUT, 'body_sss.png'), T.to8(SSS))
    print('body textures written, texel mm', texel * 1000)

if __name__ == '__main__':
    main()

"""Hair strand atlas (8 tiles, RGBA) and golden glowing eye textures.

Hair: each tile is one card type (width ~2.5 cm across the tile, length ~0.5 m along it). Strands are
anti-aliased wavy polylines (curl period ~4-6 cm, like the reference ringlets), dark brown with warmer
highlights, denser and darker at the root (top of the tile), thinning out toward the tips.
Tiles 6-7 are sparse flyaway strands.
Eyes: MakeHuman eye texture; the iris is recoloured to molten gold/amber with a darker limbal ring and
a vertical-ish dark pupil, and an emission mask for the glow seen in the references.
"""
import os
import numpy as np, cv2
import texlib as T

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, 'textures'); MH = os.environ.get('MH_DATA', '/opt/assets/mh/makehuman/data')

def hair_atlas(tiles=8, tw=256, th=2048, ss=2, seed=3):
    """Ringlet clumps: every clump is ~18 strands following a shared helical-projected path
    (period 4-7 cm along a 50 cm card), strands converge on the curl crests; highlights where the curl
    turns toward the viewer. Tiles 6-7: sparse flyaway strands."""
    rng = np.random.default_rng(seed)
    Wt, H = tw * ss, th * ss
    col = np.zeros((H, tiles * Wt, 3), np.float32); cov = np.zeros((H, tiles * Wt), np.float32)
    ys_full = np.arange(H, dtype=np.float32)
    base_dark = np.array([0.11, 0.068, 0.045]); base_warm = np.array([0.42, 0.26, 0.14])
    for k in range(tiles):
        fly = k >= tiles - 2
        n_clumps = 2 if fly else int(rng.integers(3, 5))
        tile_col = np.zeros((H, Wt, 3), np.float32); tile_cov = np.zeros((H, Wt), np.float32)
        for c in range(n_clumps):
            cx = (c + 0.5) / n_clumps * Wt + rng.normal(0, 0.06) * Wt
            per = rng.uniform(0.05, 0.08) * H * (1.4 if fly else 1.0)          # tight curls (reference ringlets)
            amp = rng.uniform(0.05, 0.09) * Wt / (n_clumps / 3.0)
            ph = rng.uniform(0, 2 * np.pi)
            length = rng.uniform(0.75, 1.0)
            clump_w = rng.uniform(0.05, 0.09) * Wt
            ctone = rng.uniform(0.0, 1.0) ** 1.4
            ns = 5 if fly else 18
            for sidx in range(ns):
                layer = np.zeros((H, Wt), np.uint8)
                o = rng.normal(0, 0.5)
                t = np.linspace(0, length, 500); ys = t * H
                ang = 2 * np.pi * ys / per + ph
                # strands spread on the sides of the curl, converge at the crests (sin = +-1)
                spread = clump_w * o * (0.35 + 0.65 * np.abs(np.cos(ang)))
                xs = cx + amp * np.sin(ang) * np.clip(t / 0.08, 0, 1) + spread + rng.normal(0, 0.8, len(t)).cumsum() * 0.02
                pts = np.stack([xs, ys], 1).astype(np.int32)
                cv2.polylines(layer, [pts], False, 255, int(rng.integers(1, 3)), cv2.LINE_AA)
                a_ = layer.astype(np.float32) / 255
                fade = np.clip((length * H - ys_full) / (0.12 * H), 0, 1)[:, None]
                a_ *= fade * (0.85 if not fly else 0.9)
                # crest highlight: where the path turns (cos(ang) ~ 0 -> side walls are darker)
                yy = ys_full
                angf = 2 * np.pi * yy / per + ph
                light = (0.55 + 0.6 * np.clip(np.sin(angf + 0.6), 0, 1) ** 2)[:, None, None]
                cstr = base_dark * rng.uniform(0.8, 1.2) + base_warm * ctone * rng.uniform(0.6, 1.1)
                tile_col = tile_col * (1 - a_[..., None]) + (cstr[None, None] * light) * a_[..., None]
                tile_cov = 1 - (1 - tile_cov) * (1 - a_)
        sl = slice(k * Wt, (k + 1) * Wt)
        col[:, sl] = tile_col; cov[:, sl] = tile_cov
    rootshade = 0.6 + 0.4 * np.clip(np.linspace(0, 1, H) / 0.2, 0, 1)[:, None, None]
    col = col * rootshade
    Wd = tiles * tw
    col = cv2.resize(col, (Wd, th), interpolation=cv2.INTER_AREA)
    cov = cv2.resize(cov, (Wd, th), interpolation=cv2.INTER_AREA)
    rgb = col / np.maximum(cov[..., None], 1e-3)
    rgb = T.dilate(rgb, cov > 0.02, iters=24)
    xw = (np.arange(Wd) % tw) / (tw - 1)
    window = np.clip(np.sin(np.pi * xw) * 2.0, 0, 1)[None, :]
    rgba = np.dstack([np.clip(rgb, 0, 1), np.clip(cov * 1.15 * window, 0, 1)])
    T.save_rgba(os.path.join(OUT, 'hair_albedo.png'), rgba)
    print('hair atlas', rgba.shape)

def eyes():
    src = cv2.imread(os.path.join(MH, 'eyes', 'materials', 'brown_eye.png'), cv2.IMREAD_UNCHANGED)
    rgb = src[..., :3][..., ::-1].astype(np.float32) / 255
    # enlarge the irises by 1.3x (the reference eyes are dominated by the glowing iris)
    hsv0 = cv2.cvtColor(src[..., :3], cv2.COLOR_BGR2HSV)
    m0 = ((hsv0[..., 1] > 90) & (hsv0[..., 2] > 25)).astype(np.uint8)
    n_lab, lab, stats, cents = cv2.connectedComponentsWithStats(m0)
    H, Wd = m0.shape; yy, xx = np.mgrid[0:H, 0:Wd].astype(np.float32)
    mapx, mapy = xx.copy(), yy.copy()
    for k in range(1, n_lab):
        if stats[k, cv2.CC_STAT_AREA] < 2000: continue
        cx, cy = cents[k]; r0 = np.sqrt(stats[k, cv2.CC_STAT_AREA] / np.pi)
        dx, dy = xx - cx, yy - cy; r = np.sqrt(dx * dx + dy * dy) + 1e-6
        R1 = r0 * 1.3; R2 = r0 * 2.2
        rs = np.where(r < R1, r / 1.3, np.where(r < R2, r0 + (r - R1) * (R2 - r0) / (R2 - R1), r))
        sel = r < R2
        mapx[sel] = (cx + dx * rs / r)[sel]; mapy[sel] = (cy + dy * rs / r)[sel]
    src = cv2.remap(src, mapx, mapy, cv2.INTER_LINEAR)
    rgb = src[..., :3][..., ::-1].astype(np.float32) / 255
    hsv = cv2.cvtColor(np.ascontiguousarray(src[..., :3]), cv2.COLOR_BGR2HSV).astype(np.float32)
    # iris: saturated brown-red pixels; pupil: very dark
    iris = ((hsv[..., 1] > 90) & (hsv[..., 2] > 25)).astype(np.float32)
    pupil = (hsv[..., 2] < 40).astype(np.float32)
    iris = cv2.GaussianBlur(iris, (0, 0), 2); pupil = cv2.GaussianBlur(pupil, (0, 0), 1.5)
    lum = rgb.mean(2)
    fibre = np.clip((lum - lum[iris > 0.5].mean()) * 3 + 0.5, 0, 1) if (iris > 0.5).any() else lum
    gold = np.array([1.0, 0.72, 0.18]) * (0.75 + 0.5 * fibre[..., None]) * np.array([1, 0.95, 0.8])
    # limbal ring darkening: iris edge
    ring = np.clip(iris - cv2.GaussianBlur(cv2.erode(iris, np.ones((9, 9), np.uint8)), (0, 0), 3), 0, 1)
    out = rgb * (1 - iris[..., None]) + gold * iris[..., None]
    out = out * (1 - 0.6 * ring[..., None]) * (1 - 0.9 * pupil[..., None])
    sclera_warm = np.array([0.93, 0.86, 0.80])
    out = np.where(iris[..., None] > 0.05, out, rgb * sclera_warm * 0.58)
    T.save_rgb(os.path.join(OUT, 'eye_albedo.png'), np.clip(out, 0, 1))
    emis = np.clip(iris * (1 - pupil) * (0.6 + 0.6 * fibre), 0, 1)[..., None] * np.array([1.0, 0.62, 0.15])
    T.save_rgb(os.path.join(OUT, 'eye_emission.png'), np.clip(emis, 0, 1))
    print('eyes done')

if __name__ == '__main__':
    hair_atlas(); eyes()

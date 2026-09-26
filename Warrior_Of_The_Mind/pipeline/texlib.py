"""Procedural texture toolkit (numpy + numba), evaluated on texel-space attribute maps.

All patterns that should be seamless across UV islands are evaluated on the 3D position map.
"""
import numpy as np, cv2
from numba import njit, prange

# ----------------------------------------------------------------------------- hashing / noise
@njit(cache=True, inline='always')
def _hash3(i, j, k, s):
    h = (i * 374761393 + j * 668265263 + k * 2147483647 + s * 1274126177) & 0xFFFFFFFF
    h = (h ^ (h >> 13)) * 1274126177 & 0xFFFFFFFF
    h = h ^ (h >> 16)
    return h

@njit(cache=True, inline='always')
def _rnd(h, n):
    return ((h * (n * 2654435761 + 1)) & 0xFFFFFF) / 16777216.0

@njit(parallel=True, cache=True)
def voronoi3(P, cell, seed, out):
    """out[:, 0]=F1, 1=F2, 2=F3 distances (metres), 3=id of nearest, 4=id of 2nd nearest (as float)."""
    n = P.shape[0]
    for t in prange(n):
        x = P[t, 0] / cell; y = P[t, 1] / cell; z = P[t, 2] / cell
        xi = int(np.floor(x)); yi = int(np.floor(y)); zi = int(np.floor(z))
        f1 = 1e9; f2 = 1e9; f3 = 1e9; id1 = 0; id2 = 0
        for dx in range(-1, 2):
            for dy in range(-1, 2):
                for dz in range(-1, 2):
                    cx = xi + dx; cy = yi + dy; cz = zi + dz
                    h = _hash3(cx, cy, cz, seed)
                    fx = cx + _rnd(h, 1); fy = cy + _rnd(h, 2); fz = cz + _rnd(h, 3)
                    d = np.sqrt((fx - x) ** 2 + (fy - y) ** 2 + (fz - z) ** 2)
                    if d < f1:
                        f3 = f2; f2 = f1; id2 = id1; f1 = d; id1 = h
                    elif d < f2:
                        f3 = f2; f2 = d; id2 = h
                    elif d < f3:
                        f3 = d
        out[t, 0] = f1 * cell; out[t, 1] = f2 * cell; out[t, 2] = f3 * cell
        out[t, 3] = id1 % 100003; out[t, 4] = id2 % 100003

@njit(parallel=True, cache=True)
def voronoi_edge3(P, N, cell, seed, out):
    """In-surface distance to the nearest Voronoi bisector: out[:,0]=distance (m), 1=grazing factor
    (0 when the bisector plane is parallel to the surface), 2,3 = ids of the two nearest cells."""
    n = P.shape[0]
    for t in prange(n):
        x = P[t, 0] / cell; y = P[t, 1] / cell; z = P[t, 2] / cell
        xi = int(np.floor(x)); yi = int(np.floor(y)); zi = int(np.floor(z))
        f1 = 1e9; f2 = 1e9; id1 = 0; id2 = 0
        a1x = 0.0; a1y = 0.0; a1z = 0.0; a2x = 0.0; a2y = 0.0; a2z = 0.0
        for dx in range(-1, 2):
            for dy in range(-1, 2):
                for dz in range(-1, 2):
                    cx = xi + dx; cy = yi + dy; cz = zi + dz
                    h = _hash3(cx, cy, cz, seed)
                    fx = cx + _rnd(h, 1); fy = cy + _rnd(h, 2); fz = cz + _rnd(h, 3)
                    d = (fx - x) ** 2 + (fy - y) ** 2 + (fz - z) ** 2
                    if d < f1:
                        f2 = f1; id2 = id1; a2x = a1x; a2y = a1y; a2z = a1z
                        f1 = d; id1 = h; a1x = fx; a1y = fy; a1z = fz
                    elif d < f2:
                        f2 = d; id2 = h; a2x = fx; a2y = fy; a2z = fz
        ex = a2x - a1x; ey = a2y - a1y; ez = a2z - a1z
        el = np.sqrt(ex * ex + ey * ey + ez * ez) + 1e-9
        pd = (f2 - f1) / (2 * el)                     # distance to bisector plane (cell units)
        cn = (ex * N[t, 0] + ey * N[t, 1] + ez * N[t, 2]) / el
        g = np.sqrt(max(1.0 - cn * cn, 1e-6))
        out[t, 0] = pd / g * cell; out[t, 1] = g
        out[t, 2] = id1 % 100003; out[t, 3] = id2 % 100003

def voronoi_edge(P, N, cell, seed=0):
    out = np.zeros((len(P), 4), np.float64)
    voronoi_edge3(np.ascontiguousarray(P, np.float64), np.ascontiguousarray(N, np.float64), float(cell), int(seed), out)
    return out

@njit(cache=True, inline='always')
def _fade(t):
    return t * t * t * (t * (t * 6 - 15) + 10)

@njit(cache=True, inline='always')
def _grad(h, x, y, z):
    g = h & 15
    u = x if g < 8 else y
    v = y if g < 4 else (x if (g == 12 or g == 14) else z)
    return (u if (g & 1) == 0 else -u) + (v if (g & 2) == 0 else -v)

@njit(parallel=True, cache=True)
def perlin3(P, scale, seed, octaves, out):
    n = P.shape[0]
    for t in prange(n):
        amp = 1.0; freq = 1.0 / scale; tot = 0.0; norm = 0.0
        for o in range(octaves):
            x = P[t, 0] * freq + o * 17.1; y = P[t, 1] * freq + o * 31.7; z = P[t, 2] * freq + o * 7.3
            xi = int(np.floor(x)); yi = int(np.floor(y)); zi = int(np.floor(z))
            xf = x - xi; yf = y - yi; zf = z - zi
            u = _fade(xf); v = _fade(yf); w = _fade(zf)
            acc = 0.0
            for dx in range(2):
                for dy in range(2):
                    for dz in range(2):
                        h = _hash3(xi + dx, yi + dy, zi + dz, seed + o)
                        g = _grad(h, xf - dx, yf - dy, zf - dz)
                        wx = u if dx else 1 - u; wy = v if dy else 1 - v; wz = w if dz else 1 - w
                        acc += g * wx * wy * wz
            tot += acc * amp; norm += amp
            amp *= 0.5; freq *= 2.0
        out[t] = tot / norm

def noise(P, scale, seed=0, octaves=4):
    out = np.zeros(len(P), np.float32)
    perlin3(np.ascontiguousarray(P, np.float64), float(scale), int(seed), int(octaves), out)
    return out

def voronoi(P, cell, seed=0):
    out = np.zeros((len(P), 5), np.float64)
    voronoi3(np.ascontiguousarray(P, np.float64), float(cell), int(seed), out)
    return out

def pair_hash(a, b):
    lo = np.minimum(a, b).astype(np.int64); hi = np.maximum(a, b).astype(np.int64)
    h = (lo * 73856093) ^ (hi * 19349663)
    return (h % 1000) / 1000.0

def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)

def line_mask(dist, width, aa):
    """1 inside a line of half-width 'width' (same units as dist), anti-aliased over 'aa'."""
    return 1 - smoothstep(width, width + aa, dist)

# ----------------------------------------------------------------------------- image ops
def dilate(img, mask, iters=16):
    """Push texel colours outward from the covered region (mip/bilinear padding)."""
    img = img.copy(); m = mask.astype(np.float32)
    k = np.ones((3, 3), np.float32)
    for _ in range(iters):
        if m.min() > 0: break
        s = cv2.filter2D(img * m[..., None] if img.ndim == 3 else img * m, -1, k, borderType=cv2.BORDER_REPLICATE)
        c = cv2.filter2D(m, -1, k, borderType=cv2.BORDER_REPLICATE)
        new = (c > 0) & (m == 0)
        if img.ndim == 3:
            img[new] = (s[new] / c[new][:, None])
        else:
            img[new] = s[new] / c[new]
        m[new] = 1
    return img

def height_to_normal(H, mask, texel_m, strength=1.0, island=None):
    """Tangent-space (OpenGL, +Y up) normal map from a height map in metres."""
    Hp = H.astype(np.float32)
    dx = np.zeros_like(Hp); dy = np.zeros_like(Hp)
    same_x = mask[:, 2:] & mask[:, :-2]; same_y = mask[2:, :] & mask[:-2, :]
    if island is not None:
        same_x &= island[:, 2:] == island[:, :-2]; same_y &= island[2:, :] == island[:-2, :]
    dx[:, 1:-1] = np.where(same_x, (Hp[:, 2:] - Hp[:, :-2]) / (2 * texel_m), 0)
    dy[1:-1, :] = np.where(same_y, (Hp[2:, :] - Hp[:-2, :]) / (2 * texel_m), 0)
    n = np.stack([-dx * strength, dy * strength, np.ones_like(Hp)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return n

def encode_normal(n):
    return np.clip((n * 0.5 + 0.5) * 255 + 0.5, 0, 255).astype(np.uint8)

def to8(x):
    return np.clip(x * 255 + 0.5, 0, 255).astype(np.uint8)

def save_rgb(path, rgb):
    cv2.imwrite(path, cv2.cvtColor(to8(rgb) if rgb.dtype != np.uint8 else rgb, cv2.COLOR_RGB2BGR))

def save_rgba(path, rgba):
    x = to8(rgba) if rgba.dtype != np.uint8 else rgba
    cv2.imwrite(path, cv2.cvtColor(x, cv2.COLOR_RGBA2BGRA))

def star_sprite(size, rays=8, sharp=6.0, core=0.08):
    """Soft N-ray sparkle, values 0..1, size x size."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    c = (size - 1) / 2
    dx = (x - c) / c; dy = (y - c) / c
    r = np.sqrt(dx * dx + dy * dy) + 1e-6
    a = np.arctan2(dy, dx)
    main = np.abs(np.cos(a * rays / 2)) ** sharp
    minor = np.abs(np.cos(a * rays / 2 + np.pi / 2)) ** (sharp * 2) * 0.45
    rays_v = (main + minor * (rays >= 8)) * np.clip(1 - r, 0, 1) ** 1.5
    glow = np.exp(-r / core) + 0.35 * np.exp(-r / (core * 3.5))
    return np.clip(rays_v + glow, 0, 1.5) * (r < 1)

def splat(img, cx, cy, sprite, gain=1.0, mask=None):
    s = sprite.shape[0]; h = s // 2
    H, Wd = img.shape[:2]
    x0, y0 = int(cx) - h, int(cy) - h
    xa, ya = max(x0, 0), max(y0, 0); xb, yb = min(x0 + s, Wd), min(y0 + s, H)
    if xb <= xa or yb <= ya: return
    sp = sprite[ya - y0:yb - y0, xa - x0:xb - x0] * gain
    if mask is not None: sp = sp * mask[ya:yb, xa:xb]
    if img.ndim == 3: img[ya:yb, xa:xb] = np.maximum(img[ya:yb, xa:xb], sp[..., None] * np.ones(img.shape[2]))
    else: img[ya:yb, xa:xb] = np.maximum(img[ya:yb, xa:xb], sp)

def sample(img, xs, ys):
    """Bilinear sample img (H,W[,C]) at float pixel coords (any length)."""
    H, Wd = img.shape[:2]
    xs = np.clip(xs, 0, Wd - 1.001); ys = np.clip(ys, 0, H - 1.001)
    x0 = np.floor(xs).astype(int); y0 = np.floor(ys).astype(int); fx = xs - x0; fy = ys - y0
    if img.ndim == 3: fx = fx[:, None]; fy = fy[:, None]
    return (img[y0, x0] * (1 - fx) * (1 - fy) + img[y0, x0 + 1] * fx * (1 - fy)
            + img[y0 + 1, x0] * (1 - fx) * fy + img[y0 + 1, x0 + 1] * fx * fy)

def apply_projection(group, W, mask, ALB, ORM, EM, Hh, mat=None, trust=None, full=1.0):
    """Blend the reference-projected colour (work/proj_<group>.npz) into the atlas maps in place.
    ALB (R,R,3|4), ORM (R,R,3), EM (R,R) scalar emission, Hh (R,R) height (m). trust: per material id
    multiplier (dict id->0..1). Returns the confidence map C."""
    import os
    p = os.path.join(W, f'proj_{group}.npz')
    if not os.path.exists(p): return None
    d = np.load(p)
    R = mask.shape[0]
    C = np.zeros(R * R, np.float32); col = np.zeros((R * R, 3), np.float32)
    C[d['idx']] = np.clip(d['w'] / 0.35, 0, 1) * full; col[d['idx']] = d['rgb']
    C = C.reshape(R, R); col = col.reshape(R, R, 3)
    if trust is not None and mat is not None:
        tm = np.ones_like(C)
        for k, v in trust.items(): tm[mat == k] = v
        C *= tm
    # soften the confidence edge so seams to the procedural fill are invisible
    C = cv2.GaussianBlur(C, (0, 0), 3) * (C > 0)
    lum = col @ np.array([0.3, 0.59, 0.11], np.float32)
    gold = np.clip((col[..., 0] - col[..., 2] - 0.10) / 0.22, 0, 1) * np.clip((lum - 0.22) / 0.3, 0, 1)
    glow = smoothstep(0.66, 0.93, lum) * np.clip((col[..., 0] - col[..., 2]) / 0.3, 0, 1)
    c3 = C[..., None]
    ALB[..., :3] = ALB[..., :3] * (1 - c3) + col * c3
    ORM[..., 1] = ORM[..., 1] * (1 - C) + (0.52 - 0.28 * gold) * C
    ORM[..., 2] = ORM[..., 2] * (1 - C) + (0.35 + 0.65 * gold) * C
    EM[:] = EM * (1 - C) + (glow * 1.4) * C
    hp = cv2.GaussianBlur(lum, (0, 0), 1.0) - cv2.GaussianBlur(lum, (0, 0), 6.0)
    Hh[:] = Hh * (1 - 0.5 * C) + (0.0005 * hp + 0.00025 * gold) * C
    return C

"""Geometry kit for building the armour and clothing procedurally (runs under bpy).

Core idea: most pieces are *radial surfaces* around an axis (a limb bone, the spine, the neck):
    P(theta, t) = O + t*A + r(theta, t) * (cos(theta)*F + sin(theta)*L)
with theta = 0 pointing forward (anterior), theta = +pi/2 lateral (away from the body midline),
t along the axis. The radius comes from ray casts against the fitted body segment plus an offset,
smoothed, then shaped (flares, ridges). Outlines are functions t_lo(theta), t_hi(theta), so pointed
gothic edges come out as clean quad grids with exact (theta, t) UVs.
Left-side pieces are built once and mirrored for the right side.
"""
import math, json, os
import numpy as np
import bpy, bmesh
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from scipy.ndimage import gaussian_filter, gaussian_filter1d
import mh

HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, 'work')

def unit(v):
    v = np.asarray(v, float); n = np.linalg.norm(v, axis=-1, keepdims=True)
    return v / np.maximum(n, 1e-12)

# ----------------------------------------------------------------------------- body
SEGMENT_BONES = {
    'head': ['head', 'jaw', 'neck03'],
    'neck': ['neck01', 'neck02', 'neck03'],
    'chest': ['spine01', 'spine02', 'breast.L', 'breast.R', 'clavicle.L', 'clavicle.R'],
    'belly': ['spine03', 'spine04', 'spine05', 'root', 'pelvis.L', 'pelvis.R'],
    'uarm.L': ['shoulder01.L', 'upperarm01.L', 'upperarm02.L'],
    'farm.L': ['lowerarm01.L', 'lowerarm02.L'],
    'hand.L': ['wrist.L', 'metacarpal1.L', 'metacarpal2.L', 'metacarpal3.L', 'metacarpal4.L'] +
              [f'finger{i}-{j}.L' for i in range(1, 6) for j in range(1, 4)],
    'thigh.L': ['upperleg01.L', 'upperleg02.L'],
    'shin.L': ['lowerleg01.L', 'lowerleg02.L'],
    'foot.L': ['foot.L'] + [f'toe{i}-{j}.L' for i in range(1, 6) for j in range(1, 4)],
}

class Body:
    def __init__(self, path=os.path.join(W, 'body.npz')):
        d = np.load(path)
        self.V = d['V']; self.F = d['F']; self.FT = d['FT']; self.VT = d['VT']
        self.jn = {k: np.array(v) for k, v in json.loads(str(d['jn'])).items()}
        self.sk = mh.skeleton()
        wt = mh.weights()
        # head segment = the head bone and every descendant (jaw, eyes, lips, cheeks, tongue...)
        bones = self.sk['bones']
        def under_head(b):
            while b is not None:
                if b == 'head': return True
                b = bones[b]['parent']
            return False
        SEGMENT_BONES['head'] = [b for b in bones if under_head(b)] + ['neck03']
        self.w = {}
        for seg, bones in list(SEGMENT_BONES.items()):
            acc = np.zeros(len(self.V))
            for b in bones:
                for i, x in wt.get(b, []): acc[i] += x
            self.w[seg] = acc
            if seg.endswith('.L'):
                accr = np.zeros(len(self.V))
                for b in bones:
                    for i, x in wt.get(b[:-2] + '.R', []): accr[i] += x
                self.w[seg[:-2] + '.R'] = accr
        self._bvh = {}

    def joint(self, bone, end='head'):
        return self.jn[self.sk['bones'][bone][end]]

    def seg_faces(self, segs, thr=0.35):
        segs = [segs] if isinstance(segs, str) else segs
        wv = sum(self.w[s] for s in segs)
        fw = wv[self.F].mean(1)
        return self.F[fw > thr]

    def bvh(self, segs, thr=0.35):
        key = (tuple(segs) if not isinstance(segs, str) else (segs,), thr)
        if key not in self._bvh:
            F = self.seg_faces(segs, thr)
            self._bvh[key] = BVHTree.FromPolygons([Vector(v) for v in self.V], [list(map(int, f)) for f in F])
        return self._bvh[key]

    def bvh_all(self):
        if 'all' not in self._bvh:
            self._bvh['all'] = BVHTree.FromPolygons([Vector(v) for v in self.V], [list(map(int, f)) for f in self.F])
        return self._bvh['all']

# ----------------------------------------------------------------------------- frames
class Frame:
    """Axis frame. side=+1 for left (+X), -1 for right. F = forward (-Y), L = lateral (side*X)."""
    def __init__(self, O, A, side=1, fwd=(0, -1, 0)):
        self.O = np.asarray(O, float); self.A = unit(A); self.side = side
        f = np.asarray(fwd, float); f = unit(f - np.dot(f, self.A) * self.A)
        self.Fw = f
        l = np.cross(self.A, self.Fw)  # A x F
        lat = np.array([side, 0, 0], float)
        if np.dot(l, lat) < 0: l = -l
        self.L = unit(l)

    def dirs(self, th):
        th = np.asarray(th)[..., None]
        return np.cos(th) * self.Fw + np.sin(th) * self.L

    def point(self, th, t, r):
        return self.O + np.asarray(t)[..., None] * self.A + np.asarray(r)[..., None] * self.dirs(th)

def ray_radius(bvh, fr, th, t, rmax=0.35):
    """Distance from the axis to the body surface along each (theta, t) direction (cast inward)."""
    th = np.asarray(th, float); t = np.asarray(t, float)
    TH, T = np.broadcast_arrays(th, t)
    out = np.full(TH.shape, np.nan)
    D = fr.dirs(TH); C = fr.O + T[..., None] * fr.A
    for idx in np.ndindex(TH.shape):
        o = C[idx] + D[idx] * rmax
        hit = bvh.ray_cast(Vector(o), Vector(-D[idx]), rmax)
        if hit[0] is not None:
            out[idx] = rmax - hit[3]
    return out

def fill_nan(R, axis_wrap=1):
    """Fill NaNs by iterative neighbour averaging (theta wraps around)."""
    R = R.copy()
    for _ in range(500):
        m = np.isnan(R)
        if not m.any(): break
        P = np.pad(R, ((1, 1), (0, 0)), mode='edge')
        P = np.concatenate([P[:, -1:], P, P[:, :1]], 1) if axis_wrap else np.pad(P, ((0, 0), (1, 1)), mode='edge')
        nb = np.stack([P[:-2, 1:-1], P[2:, 1:-1], P[1:-1, :-2], P[1:-1, 2:]])
        val = np.nanmean(np.where(np.isnan(nb), np.nan, nb), 0)
        R[m] = val[m]
    return np.nan_to_num(R, nan=np.nanmean(R))

def smooth_radius(R, s_t=1.0, s_th=1.0, wrap=True):
    mode = ('nearest', 'wrap' if wrap else 'nearest')
    return gaussian_filter(R, (s_t, s_th), mode=mode)

# ----------------------------------------------------------------------------- mesh building
def grid_faces(nt, nth, wrap=False):
    F = []
    cols = nth if wrap else nth - 1
    for i in range(nt - 1):
        for j in range(cols):
            j2 = (j + 1) % nth
            F.append([i * nth + j, i * nth + j2, (i + 1) * nth + j2, (i + 1) * nth + j])
    return np.array(F)

def radial_piece(fr, th, T, R):
    """th: (nth,), T: (nt, nth) axis coords per vertex, R: (nt, nth) radius. Returns V, F."""
    nt, nth = T.shape
    TH = np.broadcast_to(th[None, :], (nt, nth))
    V = fr.point(TH, T, R).reshape(-1, 3)
    wrap = np.isclose((th[-1] - th[0]) % (2 * np.pi), 2 * np.pi - (th[1] - th[0]), atol=1e-6) and False
    F = grid_faces(nt, nth, wrap=False)
    return V, F

def orient_outward(V, F, center_fn):
    """Flip faces whose normal points toward center_fn(face centroid)."""
    F = np.array(F)
    P = V[F]; n = np.cross(P[:, 1] - P[:, 0], P[:, 2] - P[:, 0])
    c = P.mean(1); d = c - center_fn(c)
    flip = (n * d).sum(1) < 0
    F[flip] = F[flip][:, ::-1]
    return F

def mirror_x(V, F):
    V2 = V * np.array([-1, 1, 1.]); F2 = np.array(F)[:, ::-1]
    return V2, F2

def tube(points, radius, n=8, closed=False, cap=True, twist=0.0, ref=None):
    """Tube along a polyline with parallel-transport frames. radius: scalar or per-point."""
    P = np.asarray(points, float); m = len(P)
    r = np.broadcast_to(np.asarray(radius, float), (m,))
    Tg = np.gradient(P, axis=0) if m > 2 else np.repeat((P[1] - P[0])[None], m, 0)
    if closed: Tg = np.roll(P, -1, 0) - np.roll(P, 1, 0)
    Tg = unit(Tg)
    u = np.asarray(ref, float) if ref is not None else np.cross(Tg[0], [0, 0, 1.])
    if np.linalg.norm(u) < 1e-6: u = np.cross(Tg[0], [1., 0, 0])
    u = unit(u - np.dot(u, Tg[0]) * Tg[0])
    U = [u]
    for i in range(1, m):
        v = U[-1] - np.dot(U[-1], Tg[i]) * Tg[i]
        U.append(unit(v))
    U = np.array(U); Vb = np.cross(Tg, U)
    ang = np.linspace(0, 2 * np.pi, n, endpoint=False)
    V = []
    for i in range(m):
        a = ang + twist * i
        V.append(P[i] + r[i] * (np.cos(a)[:, None] * U[i] + np.sin(a)[:, None] * Vb[i]))
    V = np.concatenate(V)
    F = []
    rows = m if closed else m - 1
    for i in range(rows):
        i2 = (i + 1) % m
        for j in range(n):
            j2 = (j + 1) % n
            F.append([i * n + j, i * n + j2, i2 * n + j2, i2 * n + j])
    UV = np.array([[j / n, i / max(m - 1, 1)] for i in range(m) for j in range(n)])
    if cap and not closed:
        c0 = len(V); V = np.vstack([V, P[0], P[-1]])
        UV = np.vstack([UV, [0.5, 0], [0.5, 1]])
        for j in range(n):
            j2 = (j + 1) % n
            F.append([c0, j2, j]); F.append([c0 + 1, (m - 1) * n + j, (m - 1) * n + j2])
    return V, F, UV

def resample_polyline(P, step=None, n=None):
    P = np.asarray(P, float)
    seg = np.linalg.norm(np.diff(P, axis=0), axis=1); s = np.r_[0, np.cumsum(seg)]
    if n is None: n = max(int(math.ceil(s[-1] / step)) + 1, 2)
    q = np.linspace(0, s[-1], n)
    return np.stack([np.interp(q, s, P[:, k]) for k in range(3)], 1)

def catmull(P, n_per=8, closed=False):
    """Catmull-Rom spline through control points."""
    P = np.asarray(P, float)
    if closed: P = np.vstack([P[-1], P, P[0], P[1]])
    else: P = np.vstack([2 * P[0] - P[1], P, 2 * P[-1] - P[-2]])
    out = []
    for i in range(1, len(P) - 2):
        p0, p1, p2, p3 = P[i - 1], P[i], P[i + 1], P[i + 2]
        for t in np.linspace(0, 1, n_per, endpoint=False):
            t2, t3 = t * t, t * t * t
            out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3))
    if not closed: out.append(P[-2])
    return np.array(out)

# ----------------------------------------------------------------------------- blender objects
_UV_SLOT = [0]
SHARED_UV = ('gold', 'gold_medallion', 'armor_orb', 'leather_sole')

class Part:
    """Accumulates geometry (V, F, UV per face-corner, material index) before creating an object.
    Every non-shared component is shifted to its own UV slot (u += 4*k) so that islands never overlap
    before packing; shared-material components (gold trims, medallions...) deliberately overlap."""
    def __init__(self, name):
        self.name = name; self.V = []; self.F = []; self.UV = []; self.M = []; self.n = 0
        self.materials = []

    def mat(self, name):
        if name not in self.materials: self.materials.append(name)
        return self.materials.index(name)

    def add(self, V, F, UV=None, mat='default', FUV=None):
        """UV: per-vertex (nV,2), or FUV: per-face-corner list aligned with F."""
        V = np.asarray(V, float); F = [list(map(int, f)) for f in F]
        mi = self.mat(mat)
        if UV is None and FUV is None: UV = np.zeros((len(V), 2))
        if UV is not None: UV = np.asarray(UV, float)
        if mat not in SHARED_UV:
            _UV_SLOT[0] += 1
            sh = np.array([4.0 * _UV_SLOT[0], 0.0])
            if UV is not None: UV = UV + sh
            if FUV is not None: FUV = [[(a + sh[0], b) for a, b in f] for f in FUV]
        for k, f in enumerate(F):
            self.F.append([i + self.n for i in f]); self.M.append(mi)
            self.UV.append([tuple(x) for x in FUV[k]] if FUV is not None else [tuple(UV[i]) for i in f])
        self.V.append(V); self.n += len(V)

    def build(self, collection=None, smooth=True, auto_smooth=None):
        V = np.vstack(self.V) if self.V else np.zeros((0, 3))
        me = bpy.data.meshes.new(self.name)
        me.from_pydata([tuple(v) for v in V], [], self.F)
        uvl = me.uv_layers.new(name='UVMap')
        k = 0; data = []
        for f, uv in zip(self.F, self.UV):
            for c in range(len(f)): data.extend(uv[c] if uv is not None else (0, 0))
        uvl.data.foreach_set('uv', data)
        me.polygons.foreach_set('material_index', self.M)
        if smooth: me.polygons.foreach_set('use_smooth', [True] * len(me.polygons))
        me.update(); me.validate()
        ob = bpy.data.objects.new(self.name, me)
        (collection or bpy.context.scene.collection).objects.link(ob)
        for m in self.materials:
            mat = bpy.data.materials.get(m) or bpy.data.materials.new(m)
            ob.data.materials.append(mat)
        if auto_smooth is not None:
            mod = ob.modifiers.new('smooth', 'SMOOTH_BY_ANGLE') if hasattr(bpy.types, 'SmoothByAngleModifier') else None
        return ob

def solidify(ob, thickness, offset=-1.0, rim=True, apply=True):
    m = ob.modifiers.new('solid', 'SOLIDIFY')
    m.thickness = thickness; m.offset = offset; m.use_rim = rim; m.use_even_offset = True
    m.use_quality_normals = True
    if apply: apply_mods(ob)
    return ob

def bevel(ob, width, segments=2, angle=35, apply=True):
    m = ob.modifiers.new('bevel', 'BEVEL')
    m.width = width; m.segments = segments; m.limit_method = 'ANGLE'; m.angle_limit = math.radians(angle)
    m.harden_normals = False
    if apply: apply_mods(ob)
    return ob

def subdivide(ob, levels=1, apply=True):
    m = ob.modifiers.new('subd', 'SUBSURF'); m.levels = levels; m.render_levels = levels
    if apply: apply_mods(ob)
    return ob

def apply_mods(ob):
    dg = bpy.context.evaluated_depsgraph_get()
    ob_e = ob.evaluated_get(dg)
    me = bpy.data.meshes.new_from_object(ob_e)
    old = ob.data; ob.modifiers.clear(); ob.data = me
    bpy.data.meshes.remove(old)
    return ob

def join(objs, name):
    objs = [o for o in objs if o is not None]
    if not objs: return None
    ctx = bpy.context
    for o in ctx.scene.objects: o.select_set(False)
    for o in objs: o.select_set(True)
    ctx.view_layer.objects.active = objs[0]
    with ctx.temp_override(active_object=objs[0], selected_editable_objects=objs, selected_objects=objs):
        bpy.ops.object.join()
    objs[0].name = name
    return objs[0]

def mirror_object(ob, name):
    """Mirror a left-side object into a right-side copy (geometry mirrored, normals fixed)."""
    me = ob.data.copy(); me.name = name
    bm = bmesh.new(); bm.from_mesh(me)
    for v in bm.verts: v.co.x = -v.co.x
    bmesh.ops.reverse_faces(bm, faces=bm.faces[:], flip_multires=False)
    bm.to_mesh(me); bm.free()
    o2 = bpy.data.objects.new(name, me)
    ob.users_collection[0].objects.link(o2)
    return o2

def np_of(ob):
    me = ob.data
    V = np.zeros(len(me.vertices) * 3); me.vertices.foreach_get('co', V)
    return V.reshape(-1, 3), [list(p.vertices) for p in me.polygons]


def ring_piece(fr, bvh, t_lo, t_hi, offset, nth=64, nt=24, th0=-np.pi, th1=np.pi, closed=True,
               smooth=(1.5, 2.0), rmax=0.35, r_override=None):
    """Radial surface between outline curves t_lo(theta) .. t_hi(theta) (callables or floats, metres).
    offset(theta, t, r_body) -> added radius (vectorised). Returns V, F, FUV (u, v in metres), grid shape.
    """
    if closed:
        th = np.linspace(th0, th1, nth, endpoint=False)
    else:
        th = np.linspace(th0, th1, nth)
    lo = np.broadcast_to(np.asarray(t_lo(th) if callable(t_lo) else t_lo, float), th.shape)
    hi = np.broadcast_to(np.asarray(t_hi(th) if callable(t_hi) else t_hi, float), th.shape)
    s = np.linspace(0, 1, nt)[:, None]
    T = lo[None, :] + (hi - lo)[None, :] * s                     # (nt, nth)
    TH = np.broadcast_to(th[None, :], T.shape)
    if r_override is None:
        # body radius sampled on a regular t grid covering the piece, then interpolated
        tg = np.linspace(lo.min() - 0.01, hi.max() + 0.01, max(nt * 2, 16))
        Rg = ray_radius(bvh, fr, th[None, :], tg[:, None], rmax)
        Rg = fill_nan(Rg, axis_wrap=1 if closed else 0)
        Rg = smooth_radius(Rg, *smooth, wrap=closed)
        Rb = np.empty_like(T)
        for j in range(len(th)):
            Rb[:, j] = np.interp(T[:, j], tg, Rg[:, j])
    else:
        Rb = r_override(TH, T)
    R = Rb + offset(TH, T, Rb)
    V = fr.point(TH, T, R).reshape(-1, 3)
    # faces (+ wrap) and metric uvs
    Pg = V.reshape(T.shape + (3,))
    circ = np.linalg.norm(np.diff(np.concatenate([Pg, Pg[:, :1]], 1) if closed else Pg, axis=1), axis=2).mean(0)
    ucol = np.r_[0, np.cumsum(circ)]                              # u per column (len nth+1 if closed)
    vlen = np.linalg.norm(np.diff(Pg, axis=0), axis=2).mean(1); vrow = np.r_[0, np.cumsum(vlen)]
    F, FUV = [], []
    cols = nth if closed else nth - 1
    for i in range(nt - 1):
        for j in range(cols):
            j2 = (j + 1) % nth
            F.append([i * nth + j, i * nth + j2, (i + 1) * nth + j2, (i + 1) * nth + j])
            u0, u1 = ucol[j], ucol[j + 1]
            FUV.append([(u0, vrow[i]), (u1, vrow[i]), (u1, vrow[i + 1]), (u0, vrow[i + 1])])
    return V, np.array(F), FUV, dict(T=T, TH=TH, R=R, shape=T.shape, ulen=ucol[-1], vlen=vrow[-1])

def peak(th, center, width, power=2.0):
    """Smooth bump in theta (1 at center, 0 beyond +-width)."""
    d = np.angle(np.exp(1j * (np.asarray(th) - center)))
    x = np.clip(1 - np.abs(d) / width, 0, 1)
    return x ** power

def gothic(th, center, width):
    """Pointed-arch bump: straight-ish flanks meeting at a sharp tip."""
    d = np.abs(np.angle(np.exp(1j * (np.asarray(th) - center))))
    x = np.clip(1 - d / width, 0, 1)
    return 1 - np.sqrt(np.clip(1 - x * x, 0, 1)) * 0 - (1 - x) ** 1.6 * 0 if False else x ** 1.35

"""MakeHuman (CC0) base-mesh toolkit, pure numpy.

Loads the hm08 base mesh, applies macro/detail targets with MakeHuman's weighting rules, and
gives joint centres (from the helper joint cubes) and the default-rig skin weights.
Coordinates are returned in metres, Blender frame (Z up, character faces -Y).
MakeHuman data dir: $MH_DATA (default /opt/assets/mh/makehuman/data).
"""
import os, json, re
import numpy as np

MH = os.environ.get('MH_DATA', '/opt/assets/mh/makehuman/data')
DM = 0.1  # MakeHuman units are decimetres

def load_obj(path):
    V, VT, F, FT, G = [], [], [], [], []
    g = None
    for line in open(path):
        if line.startswith('v '): V.append([float(x) for x in line.split()[1:4]])
        elif line.startswith('vt '): VT.append([float(x) for x in line.split()[1:3]])
        elif line.startswith('g '): g = line.split()[1]
        elif line.startswith('f '):
            idx = [p.split('/') for p in line.split()[1:]]
            F.append([int(p[0]) - 1 for p in idx])
            FT.append([int(p[1]) - 1 if len(p) > 1 and p[1] else -1 for p in idx])
            G.append(g)
    return np.array(V), np.array(VT), F, FT, G

_cache = {}
def base():
    if 'base' not in _cache:
        _cache['base'] = load_obj(os.path.join(MH, '3dobjs', 'base.obj'))
    return _cache['base']

def load_target(rel):
    p = os.path.join(MH, 'targets', rel if rel.endswith('.target') else rel + '.target')
    idx, d = [], []
    for line in open(p):
        if not line.strip() or line.startswith('#'): continue
        s = line.split(); idx.append(int(s[0])); d.append([float(x) for x in s[1:4]])
    return np.array(idx, int), np.array(d).reshape(-1, 3)

def _tri(v, names):
    """MakeHuman 3-way split of a 0..1 slider around 0.5 -> weights for (min, average, max)."""
    if v < 0.5: return {names[0]: 1 - v / 0.5, names[1]: v / 0.5, names[2]: 0.0}
    return {names[0]: 0.0, names[1]: 1 - (v - 0.5) / 0.5, names[2]: (v - 0.5) / 0.5}

def macro_targets(gender=1.0, age=0.55, muscle=0.9, weight=0.55, height=1.0, proportions=1.0,
                  race=None):
    race = race or {'caucasian': 1.0}
    gw = {'female': 1 - gender, 'male': gender}
    if age < 0.1875: aw = {'baby': 1 - age / 0.1875, 'child': age / 0.1875}
    elif age < 0.5: aw = {'child': 1 - (age - 0.1875) / 0.3125, 'young': (age - 0.1875) / 0.3125}
    else: aw = {'young': 1 - (age - 0.5) / 0.5, 'old': (age - 0.5) / 0.5}
    mw = _tri(muscle, ['minmuscle', 'averagemuscle', 'maxmuscle'])
    ww = _tri(weight, ['minweight', 'averageweight', 'maxweight'])
    hw = {'minheight': max(0, (0.5 - height) * 2), 'maxheight': max(0, (height - 0.5) * 2)}
    pw = {'uncommonproportions': max(0, (0.5 - proportions) * 2), 'idealproportions': max(0, (proportions - 0.5) * 2)}
    out = []
    for g, a in [(g, a) for g in gw for a in aw]:
        base_w = gw[g] * aw[a]
        if base_w <= 1e-6: continue
        for r, rw in race.items():
            if rw > 0: out.append((f'macrodetails/{r}-{g}-{a}', base_w * rw))
        for m in mw:
            for w in ww:
                bw = base_w * mw[m] * ww[w]
                if bw <= 1e-6: continue
                out.append((f'macrodetails/universal-{g}-{a}-{m}-{w}', bw))
                for h, hv in hw.items():
                    if hv > 0: out.append((f'macrodetails/height/{g}-{a}-{m}-{w}-{h}', bw * hv))
                for p, pv in pw.items():
                    if pv > 0: out.append((f'macrodetails/proportions/{g}-{a}-{m}-{w}-{p}', bw * pv))
    return out

def apply(V, targets):
    V = V.copy()
    for rel, w in targets:
        if abs(w) < 1e-6: continue
        i, d = load_target(rel)
        V[i] += w * d
    return V

def to_blender(V):
    """MakeHuman (x right(left of char), y up, z forward, dm) -> Blender (m, Z up, faces -Y)."""
    V = np.asarray(V) * DM
    return np.stack([V[:, 0], -V[:, 2], V[:, 1]], 1)

def skeleton():
    return json.load(open(os.path.join(MH, 'rigs', 'default.mhskel')))

def joint_positions(Vb, skel=None):
    """Joint name -> position (Blender frame) from mhskel 'joints' vertex lists."""
    skel = skel or skeleton()
    return {k: Vb[np.array(v)].mean(0) for k, v in skel['joints'].items()}

def weights():
    return json.load(open(os.path.join(MH, 'rigs', 'default_weights.mhw')))['weights']

def body_faces():
    V, VT, F, FT, G = base()
    keep = [i for i, g in enumerate(G) if g == 'body']
    return [F[i] for i in keep], [FT[i] for i in keep]

def group_vertices(prefix):
    V, VT, F, FT, G = base()
    s = set()
    for f, g in zip(F, G):
        if g.startswith(prefix): s.update(f)
    return np.array(sorted(s))

def load_mhclo(path):
    """MakeHuman proxy (.mhclo): each proxy vertex = barycentric combo of 3 base verts + scaled offset."""
    refs, wts, offs = [], [], []; scales = {}; obj = None; in_verts = False
    for line in open(path):
        s = line.split()
        if not s or s[0].startswith('#'): continue
        if s[0] in ('x_scale', 'y_scale', 'z_scale'): scales[s[0][0]] = (int(s[1]), int(s[2]), float(s[3]))
        elif s[0] == 'obj_file': obj = os.path.join(os.path.dirname(path), s[1])
        elif s[0] == 'verts': in_verts = True
        elif in_verts and len(s) == 9:
            refs.append([int(x) for x in s[:3]]); wts.append([float(x) for x in s[3:6]]); offs.append([float(x) for x in s[6:9]])
        elif in_verts and len(s) == 1 and s[0].isdigit():
            refs.append([int(s[0])] * 3); wts.append([1, 0, 0]); offs.append([0, 0, 0])
        elif in_verts and s[0] in ('weights', 'delete_verts', 'faces'): in_verts = False
    return dict(refs=np.array(refs), wts=np.array(wts), offs=np.array(offs), scales=scales, obj=obj)

def fit_proxy(clo, Vb):
    """Proxy vertex positions (Blender frame, m) for a fitted base mesh Vb (Blender frame, m)."""
    r, w, o = clo['refs'], clo['wts'], clo['offs']
    P = (Vb[r] * w[..., None]).sum(1)
    sc = clo['scales']
    def ratio(key, axis):
        a, b, ref = sc[key]; return abs(Vb[a, axis] - Vb[b, axis]) / (ref * DM)
    sx, sy, sz = ratio('x', 0), ratio('y', 2), ratio('z', 1)
    off = np.stack([o[:, 0] * sx, -o[:, 2] * sz, o[:, 1] * sy], 1) * DM
    return P + off

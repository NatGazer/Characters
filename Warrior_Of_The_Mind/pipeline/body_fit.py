"""Fit the MakeHuman body to the skeleton measured on the reference images.

Target joints were read off the gridded references (front 01 + left profile 02) at
1.34 mm/px, sole = 0 (boots add 3 cm), X = character's left, -Y = forward.
The body is re-proportioned and posed in one linear-blend-skinning pass: each body segment gets an
anisotropic similarity (rotation + length scale along the bone + girth scale across it), blended
with MakeHuman's default skin weights. Output: work/body.npz (verts, faces, uvs, joints).
"""
import os, json
import numpy as np
import mh

HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, 'work')
SOLE = 0.03  # boot sole thickness: the bare foot stands 3 cm above ground

# measured targets (left side; right mirrored). Units m.
TGT = {
    'hip':      (0.100, -0.005, 1.080),
    'knee':     (0.150, -0.020, 0.655),
    'ankle':    (0.180,  0.005, 0.112),
    'shoulder': (0.198,  0.005, 1.630),
    'elbow':    (0.325,  0.030, 1.370),
    'wrist':    (0.415, -0.035, 1.125),
    'neck':     (0.000,  0.005, 1.705),   # neck01 head (C7 level)
    'headj':    (0.000, -0.010, 1.815),   # head bone head (atlas)
    'root':     (0.000,  0.035, 1.105),
}
HEAD_SCALE = 0.85
GIRTH = {'uarm': 0.90, 'farm': 0.90, 'thigh': 0.88, 'shin': 0.88, 'hand': 1.08, 'foot': 0.95}

SEG = {}  # MH bone -> segment name
def seg_of(b):
    side = '.L' if b.endswith('.L') else '.R' if b.endswith('.R') else ''
    n = b[:-2] if side else b
    if n in ('root', 'spine05', 'pelvis'): return 'pelvis'
    if n in ('spine04', 'spine03'): return 'spine_lo'
    if n in ('spine02', 'spine01', 'breast'): return 'spine_hi'
    if n.startswith('neck'): return 'neck'
    if n == 'clavicle': return 'clav' + side
    if n in ('shoulder01', 'upperarm01', 'upperarm02'): return 'uarm' + side
    if n in ('lowerarm01', 'lowerarm02'): return 'farm' + side
    if n in ('wrist',) or n.startswith('metacarpal') or n.startswith('finger'): return 'hand' + side
    if n in ('upperleg01', 'upperleg02'): return 'thigh' + side
    if n in ('lowerleg01', 'lowerleg02'): return 'shin' + side
    if n == 'foot' or n.startswith('toe'): return 'foot' + side
    return 'head'

def rot_between(a, b):
    a = a / np.linalg.norm(a); b = b / np.linalg.norm(b)
    v = np.cross(a, b); c = np.dot(a, b)
    if np.linalg.norm(v) < 1e-9: return np.eye(3)
    K = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + K + K @ K * (1 / (1 + c))

def seg_xform(h0, t0, h1, t1, girth=1.0, along=None):
    a = (t0 - h0); L0 = np.linalg.norm(a); a /= L0
    L1 = np.linalg.norm(t1 - h1)
    s = (L1 / L0) if along is None else along
    S = girth * np.eye(3) + (s - girth) * np.outer(a, a)
    M = rot_between(t0 - h0, t1 - h1) @ S
    return M, h1 - M @ h0  # v' = M v + c

def mirror(p): return np.array([-p[0], p[1], p[2]])

# facial character (MakeHuman detail targets, weights 0..1): a chiselled, heroic male face as in the refs
FACE_TARGETS = [
    ('eyebrows/eyebrows-trans-forward', 0.45), ('eyebrows/eyebrows-trans-down', 0.35), ('eyebrows/eyebrows-angle-down', 0.3),
    ('forehead/forehead-trans-backward', 0.08), ('forehead/forehead-temple-decr', 0.4),
    ('nose/nose-trans-forward', 0.12), ('nose/nose-scale-vert-incr', 0.3), ('nose/nose-hump-decr', 0.45),
    ('nose/nose-point-width-decr', 0.3), ('nose/nose-scale-depth-incr', 0.05), ('nose/nose-greek-decr', 0.2),
    ('chin/chin-prominent-incr', 0.45), ('chin/chin-width-incr', 0.35), ('chin/chin-bones-incr', 0.5), ('chin/chin-height-incr', 0.2),
    ('cheek/l-cheek-bones-incr', 0.55), ('cheek/r-cheek-bones-incr', 0.55),
    ('cheek/l-cheek-volume-decr', 0.5), ('cheek/r-cheek-volume-decr', 0.5),
    ('cheek/l-cheek-inner-decr', 0.4), ('cheek/r-cheek-inner-decr', 0.4),
    ('eyes/l-eye-push1-in', 0.35), ('eyes/r-eye-push1-in', 0.35), ('eyes/l-eye-bag-decr', 0.4), ('eyes/r-eye-bag-decr', 0.4),
    ('head/head-square', 0.35), ('mouth/mouth-scale-horiz-incr', 0.15), ('neck/neck-scale-horiz-decr', 0.35), ('neck/neck-scale-depth-decr', 0.2),
]

# athletic V-taper: narrower waist and hips, flatter stomach, lean chest
BODY_TARGETS = [
    ('measure/measure-waist-circ-decr', 0.6), ('measure/measure-hips-circ-decr', 0.35),
    ('stomach/stomach-pregnant-decr', 0.5), ('measure/measure-bust-circ-decr', 0.15),
    ('measure/measure-upperarm-circ-decr', 0.25), ('measure/measure-thigh-circ-decr', 0.3),
    ('head/head-age-decr', 0.35),
]

def fit(macro=None):
    V, VT, F, FT, G = mh.base()
    Vb = mh.to_blender(mh.apply(V, (macro or mh.macro_targets(age=0.47, muscle=0.78, weight=0.32, height=0.6)) + FACE_TARGETS + BODY_TARGETS))
    bf, bft = mh.body_faces(); used = np.unique(np.concatenate(bf))
    Vb[:, 2] -= Vb[used, 2].min()
    sk = mh.skeleton(); J = mh.joint_positions(Vb, sk)
    jh = lambda b: J[sk['bones'][b]['head']]; jt = lambda b: J[sk['bones'][b]['tail']]
    T = {k: np.array(v) for k, v in TGT.items()}
    for k in ('hip', 'knee', 'ankle'): T[k][2] += 0  # already includes sole
    X = {}
    for side, m in (('.L', lambda p: p), ('.R', mirror)):
        sh, el, wr = m(T['shoulder']), m(T['elbow']), m(T['wrist'])
        hp, kn, an = m(T['hip']), m(T['knee']), m(T['ankle'])
        X['uarm' + side] = seg_xform(jh('upperarm01' + side), jh('lowerarm01' + side), sh, el, GIRTH['uarm'])
        X['farm' + side] = seg_xform(jh('lowerarm01' + side), jh('wrist' + side), el, wr, GIRTH['farm'])
        # hand: rigid-ish, follow forearm direction
        Mf, cf = X['farm' + side]
        R = rot_between(jh('wrist' + side) - jh('lowerarm01' + side), wr - el)
        Mh = R * GIRTH['hand']; X['hand' + side] = (Mh, wr - Mh @ jh('wrist' + side))
        X['thigh' + side] = seg_xform(jh('upperleg01' + side), jh('lowerleg01' + side), hp, kn, GIRTH['thigh'])
        X['shin' + side] = seg_xform(jh('lowerleg01' + side), jh('foot' + side), kn, an, GIRTH['shin'])
        R = rot_between(jh('foot' + side) - jh('lowerleg01' + side), an - kn)
        # keep the foot flat: only yaw from the shin, no pitch
        R = np.eye(3)
        Mft = R * GIRTH['foot']; X['foot' + side] = (Mft, an - Mft @ jh('foot' + side))
        # clavicle: from its (mapped) root to the shoulder
        ch0 = jh('clavicle' + side)
        X['clav' + side] = seg_xform(ch0, jh('upperarm01' + side),
                                     np.array([ch0[0] * 0.95, ch0[1], T['neck'][2] - 0.035]), sh, 1.0)
    # trunk: vertical scale between root and neck, translate
    r0, n0 = jh('spine05'), jh('neck01')
    X['pelvis'] = seg_xform(r0, n0, T['root'], T['neck'], 1.0)
    X['spine_lo'] = X['pelvis']; X['spine_hi'] = X['pelvis']
    X['neck'] = seg_xform(n0, jh('head'), T['neck'], T['headj'], 1.0)
    Mh = np.eye(3) * HEAD_SCALE
    X['head'] = (Mh, T['headj'] - Mh @ jh('head'))
    # pelvis width: map hip joints
    # (hips are placed by the thigh segments; pelvis keeps MH width, scaled a bit)
    # LBS
    Wt = mh.weights()
    acc = np.zeros_like(Vb); wsum = np.zeros(len(Vb))
    for b, lst in Wt.items():
        s = seg_of(b)
        if s not in X: continue
        M, c = X[s]
        idx = np.array([i for i, _ in lst]); w = np.array([x for _, x in lst])
        acc[idx] += w[:, None] * (Vb[idx] @ M.T + c)
        wsum[idx] += w
    out = Vb.copy()
    ok = wsum > 1e-6
    out[ok] = acc[ok] / wsum[ok, None]
    Jn = {k: None for k in sk['joints']}
    Jn = mh.joint_positions(out, sk)
    return out, bf, bft, VT, Jn, sk

if __name__ == '__main__':
    out, bf, bft, VT, Jn, sk = fit()
    used = np.unique(np.concatenate(bf))
    print('height', out[used, 2].max(), 'bbox', out[used].min(0).round(3), out[used].max(0).round(3))
    for b in ['upperarm01.L', 'lowerarm01.L', 'wrist.L', 'upperleg01.L', 'lowerleg01.L', 'foot.L', 'neck01', 'head', 'eye.L']:
        print(b, np.round(Jn[sk['bones'][b]['head']], 3))
    for fn in ('body.npz', 'body_prefit.npz'):
        np.savez(os.path.join(W, fn), V=out, F=np.array(bf), FT=np.array(bft), VT=VT,
                 jn=json.dumps({k: v.tolist() for k, v in Jn.items()}))

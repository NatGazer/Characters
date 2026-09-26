"""Rig: humanoid skeleton (Godot SkeletonProfileHumanoid names) + dynamic chains + skinning.

Input : work/model_uv.blend (textured geometry), work/body.npz, work/hair_strands.npy
Output: work/model_rigged.blend and work/chains.json (dynamic chain definitions for Godot)

Meshes are merged per material (5 draw calls): Body, Armor, Cloth, Hair (hair+beard+brows), Eyes.
Skinning:
  * body      MakeHuman default weights, remapped from the 163 MH bones to the humanoid bones
  * armour    weight transfer from the nearest body surface, then per-piece rules (rigid plates
              follow one bone: vambraces, greaves, sabatons...), daggers / pendant on dynamic bones
  * cloth     dynamic chains (cape, robe skirt, tabards, stoles) blended with the body near the top
  * hair      dynamic chains from clustered guide strands; beard, brows, eyes on Head
"""
import sys, os, json, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, bpy
from mathutils import Vector, Matrix
from scipy.spatial import cKDTree
import kit, mh, materials, uvlayout

HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, 'work')

# ----------------------------------------------------------------------------- skeleton
SIDES = (('Left', '.L'), ('Right', '.R'))
FINGERS = [('Thumb', 1, ('Metacarpal', 'Proximal', 'Distal')), ('Index', 2, ('Proximal', 'Intermediate', 'Distal')),
           ('Middle', 3, ('Proximal', 'Intermediate', 'Distal')), ('Ring', 4, ('Proximal', 'Intermediate', 'Distal')),
           ('Little', 5, ('Proximal', 'Intermediate', 'Distal'))]

def mh_to_humanoid(b):
    """MakeHuman bone -> humanoid bone (for weights)."""
    side = 'Left' if b.endswith('.L') else 'Right' if b.endswith('.R') else ''
    n = b[:-2] if side else b
    if n in ('root', 'spine05', 'pelvis'): return 'Hips'
    if n == 'spine04': return 'Spine'
    if n == 'spine03': return 'Chest'
    if n in ('spine02', 'spine01', 'breast'): return 'UpperChest'
    if n.startswith('neck'): return 'Neck'
    if n == 'clavicle': return side + 'Shoulder'
    if n in ('shoulder01', 'upperarm01', 'upperarm02'): return side + 'UpperArm'
    if n in ('lowerarm01', 'lowerarm02'): return side + 'LowerArm'
    if n == 'wrist' or n.startswith('metacarpal'): return side + 'Hand'
    if n.startswith('finger'):
        f, j = int(n[6]), int(n[8])
        name, _, segs = FINGERS[f - 1]
        return side + name + segs[j - 1]
    if n in ('upperleg01', 'upperleg02'): return side + 'UpperLeg'
    if n in ('lowerleg01', 'lowerleg02'): return side + 'LowerLeg'
    if n == 'foot': return side + 'Foot'
    if n.startswith('toe'): return side + 'Toes'
    if n == 'jaw' or n.startswith('tongue'): return 'Jaw'
    if n == 'eye': return side + 'Eye'
    return 'Head'

def skeleton_def(B):
    """name -> (head, tail, parent) in Blender world coords."""
    J = lambda b, e='head': np.array(B.joint(b, e))
    S = {}
    hips = J('spine05')
    S['Root'] = (np.array([0, 0, 0.0]), np.array([0, -0.25, 0.0]), None)
    S['Hips'] = (hips, J('spine04'), 'Root')
    S['Spine'] = (J('spine04'), J('spine03'), 'Hips')
    S['Chest'] = (J('spine03'), J('spine02'), 'Spine')
    S['UpperChest'] = (J('spine02'), J('neck01'), 'Chest')
    S['Neck'] = (J('neck01'), J('head'), 'UpperChest')
    S['Head'] = (J('head'), J('head', 'tail'), 'Neck')
    S['Jaw'] = (J('jaw'), J('jaw', 'tail'), 'Head')
    for side, s in SIDES:
        S[side + 'Eye'] = (J('eye' + s), J('eye' + s, 'tail'), 'Head')
        S[side + 'Shoulder'] = (J('clavicle' + s), J('upperarm01' + s), 'UpperChest')
        S[side + 'UpperArm'] = (J('upperarm01' + s), J('lowerarm01' + s), side + 'Shoulder')
        S[side + 'LowerArm'] = (J('lowerarm01' + s), J('wrist' + s), side + 'UpperArm')
        S[side + 'Hand'] = (J('wrist' + s), J('finger3-1' + s), side + 'LowerArm')
        for name, f, segs in FINGERS:
            par = side + 'Hand'
            for j, sg in enumerate(segs):
                bn = f'finger{f}-{j + 1}{s}'
                S[side + name + sg] = (J(bn), J(bn, 'tail'), par); par = side + name + sg
        S[side + 'UpperLeg'] = (J('upperleg01' + s), J('lowerleg01' + s), 'Hips')
        S[side + 'LowerLeg'] = (J('lowerleg01' + s), J('foot' + s), side + 'UpperLeg')
        ball = J('toe3-1' + s); ball[2] = 0.035
        S[side + 'Foot'] = (J('foot' + s), ball, side + 'LowerLeg')
        tip = ball + np.array([0, -0.07, 0.0])
        S[side + 'Toes'] = (ball, tip, side + 'Foot')
    # sockets: sword grip in the right fist, cast points at both palms (non-deforming except the sword)
    for side, sg in (('Right', -1), ('Left', 1)):
        W_ = S[side + 'Hand'][0]; y = kit.unit(S[side + 'Hand'][1] - W_)
        across = kit.unit(S[side + 'IndexProximal'][0] - S[side + 'LittleProximal'][0])
        across = kit.unit(across - np.dot(across, y) * y)
        palm = kit.unit(np.cross(y, across))
        if np.dot(palm, [-sg, 0, 0]) < 0: palm = -palm          # palm faces the thigh (medial) at rest
        grip = W_ + y * 0.075 + palm * 0.022
        if side == 'Right':
            S['SwordSocket'] = (grip, grip + across * 0.12, 'RightHand')
            SOCKET_FRAMES['SwordSocket'] = dict(blade=across, edge=kit.unit(y - np.dot(y, across) * across), flat=palm, origin=grip)
        S[side[0] + 'CastSocket'] = (grip + palm * 0.02, grip + palm * 0.14, side + 'Hand')
        SOCKET_FRAMES[side[0] + 'CastSocket'] = dict(ref=y)
    return S

SOCKET_FRAMES = {}

def roll_ref(name):
    if name == 'SwordSocket': return Vector(SOCKET_FRAMES[name]['flat'])
    if name.endswith('CastSocket'): return Vector(SOCKET_FRAMES[name]['ref'])
    """Reference direction for the bone's local Z axis (Blender align_roll)."""
    if name.endswith('Foot') or name.endswith('Toes') or name == 'Root': return Vector((0, 0, 1))
    return Vector((0, -1, 0))

# ----------------------------------------------------------------------------- dynamic chains
def resample(P, n):
    return kit.resample_polyline(P, n=n)

def chain(name, pts, parent, radius=0.02, **params):
    return dict(name=name, points=np.asarray(pts).tolist(), parent=parent, radius=radius, params=params)

def cape_chains(objs):
    out = []
    for side in ('L', 'R'):
        ob = objs.get(f'cape_{side}_0')
        V = np.array([v.co for v in ob.data.vertices]); ns, nv = 30, 44
        G = V.reshape(ns, nv, 3)
        for k, col in enumerate([1, 8, 15, 22, 28]):
            c = G[col]
            # first joint just below the attachment line; 6 joints
            pts = resample(c, 7)
            out.append(chain(f'Cape{side}{k}', pts, 'UpperChest', radius=0.035, group='cape'))
    return out

def skirt_chains(n=12):
    """Radial chains hanging from the belt (robe skirt), in the robe ellipse (see cloth.py)."""
    import cloth
    out = []
    for k in range(n):
        th = -np.pi + 2 * np.pi * (k + 0.5) / n
        zs = np.array([1.12, 0.92, 0.70, 0.48, 0.26, 0.08])
        pts = []
        for z in zs:
            a = cloth.interp_z(z, cloth.ROBE_Z, cloth.ROBE_A) + 0.01; b = cloth.interp_z(z, cloth.ROBE_Z, cloth.ROBE_B) + 0.01
            r = cloth.ellipse_r(th, a, b)
            pts.append([r * np.sin(th), 0.02 - r * np.cos(th), z])
        out.append(chain(f'Skirt{k:02d}', pts, 'Hips', radius=0.03, group='skirt', theta=float(th)))
    return out

def panel_chains(objs):
    out = []
    for nm in ('tabard_front', 'tabard_back', 'panel_front_L', 'panel_front_R', 'panel_back_L', 'panel_back_R'):
        ob = objs.get(nm)
        if ob is None: continue
        V = np.array([v.co for v in ob.data.vertices])
        top = V[:, 2].max(); bot = V[:, 2].min()
        zs = np.linspace(min(top, 1.20), bot, 5)
        pts = [V[np.abs(V[:, 2] - z) < 0.03].mean(0) for z in zs]
        tag = ''.join(w[0].upper() + w[1:] for w in nm.split('_'))
        out.append(chain(tag, pts, 'Hips', radius=0.02, group='panel'))
    return out

def stole_chains(objs):
    out = []
    for nm in ('stole_front_L', 'stole_front_R', 'stole_back_L', 'stole_back_R'):
        ob = objs.get(nm)
        V = np.array([v.co for v in ob.data.vertices]).reshape(60, 8, 3).mean(1)
        V = V[V[:, 2] < 1.26]
        pts = resample(V, 6)
        tag = ''.join(w[0].upper() + w[1:] for w in nm.split('_'))
        out.append(chain(tag, pts, 'Hips', radius=0.02, group='stole'))
    return out

def hair_chains(X, k=16, seed=0):
    """Cluster guide strands (by their mid/lower path) into k chains parented to Head."""
    from scipy.cluster.vq import kmeans2
    n, m, _ = X.shape
    feat = X[:, m // 3:, :].reshape(n, -1)
    rng = np.random.default_rng(seed)
    cent, lab = kmeans2(feat, k, seed=seed, minit='++')
    out = []
    for c in range(k):
        S = X[lab == c]
        if len(S) < 3: continue
        mean = S.mean(0)
        pts = resample(mean[int(m * 0.18):], 5)
        out.append(chain(f'Hair{c:02d}', pts, 'Head', radius=0.03, group='hair'))
    return out, lab

def pendant_chain():
    pts = [[-0.028, -0.205, 1.262], [-0.031, -0.222, 1.150], [-0.033, -0.232, 1.085], [-0.034, -0.240, 0.985]]
    return [chain('Pendant', pts, 'Hips', radius=0.012, group='pendant')]

def dagger_chains():
    out = []
    for side, sg in (('L', 1), ('R', -1)):
        top = np.array([0.175 * sg, -0.075, 1.285]); axis = kit.unit(np.array([0.06 * sg, -0.12, -1.0]))
        out.append(chain(f'Dagger{side}', [top, top + axis * 0.30], 'Hips', radius=0.02, group='dagger'))
    return out

# ----------------------------------------------------------------------------- build
def make_armature(S, chains):
    arm = bpy.data.armatures.new('WarriorRig'); ob = bpy.data.objects.new('Warrior', arm)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.mode_set(mode='EDIT')
    eb = arm.edit_bones
    for name, (h, t, p) in S.items():
        b = eb.new(name); b.head = Vector(h); b.tail = Vector(t)
        b.align_roll(roll_ref(name))
    for name, (h, t, p) in S.items():
        if p: eb[name].parent = eb[p]
    for ch in chains:
        pts = np.array(ch['points']); par = eb[ch['parent']]
        ch['bones'] = []
        for i in range(len(pts) - 1):
            bn = f"{ch['name']}_{i}"
            b = eb.new(bn); b.head = Vector(pts[i]); b.tail = Vector(pts[i + 1])
            b.align_roll(Vector((0, -1, 0)) if abs(pts[i + 1][1] - pts[i][1]) < 0.9 * np.linalg.norm(pts[i + 1] - pts[i]) else Vector((0, 0, 1)))
            b.parent = par; b.use_connect = i > 0; par = b
            ch['bones'].append(bn)
    # deform flags
    for b in eb:
        b.use_deform = b.name not in ('Root', 'RCastSocket', 'LCastSocket')
    bpy.ops.object.mode_set(mode='OBJECT')
    return ob

def join_objects(objs, name):
    objs = [o for o in objs if o is not None]
    if not objs: return None
    for o in bpy.context.view_layer.objects: o.select_set(False)
    for o in objs: o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    objs[0].name = name; objs[0].data.name = name
    return objs[0]

def set_weights(ob, Wd):
    """Wd: dict bone -> (n,) weights for every vertex of ob. Normalised, top-4 limited."""
    names = list(Wd.keys()); M = np.stack([Wd[n] for n in names], 1)
    M = np.clip(M, 0, None)
    # keep 4 largest
    if M.shape[1] > 4:
        idx = np.argsort(-M, axis=1)[:, 4:]
        np.put_along_axis(M, idx, 0, axis=1)
    s = M.sum(1, keepdims=True); M = np.where(s > 1e-8, M / np.maximum(s, 1e-8), 0)
    for j, n in enumerate(names):
        nz = np.where(M[:, j] > 1e-4)[0]
        if len(nz) == 0: continue
        vg = ob.vertex_groups.get(n) or ob.vertex_groups.new(name=n)
        for w in np.unique(np.round(M[nz, j], 3)):
            sel = nz[np.round(M[nz, j], 3) == w]
            vg.add(sel.tolist(), float(w), 'REPLACE')

def body_weight_matrix(B, bones):
    wt = mh.weights()
    M = np.zeros((len(B.V), len(bones))); bi = {b: i for i, b in enumerate(bones)}
    for b, lst in wt.items():
        j = bi[mh_to_humanoid(b)]
        for i, w in lst: M[i, j] += w
    return M / np.maximum(M.sum(1, keepdims=True), 1e-8)

def transfer(Pq, B, Mb, k=6, smooth_body=None):
    used = np.unique(B.F.ravel())
    tree = cKDTree(B.V[used])
    d, i = tree.query(Pq, k=k)
    w = 1 / np.maximum(d, 1e-4) ** 2; w /= w.sum(1, keepdims=True)
    return np.einsum('nk,nkb->nb', w, Mb[used][i])

def smooth_on_mesh(ob, M, iters=10, lam=0.5):
    me = ob.data
    E = np.array([e.vertices for e in me.edges])
    n = len(me.vertices)
    for _ in range(iters):
        acc = np.zeros_like(M); cnt = np.zeros(n)
        np.add.at(acc, E[:, 0], M[E[:, 1]]); np.add.at(acc, E[:, 1], M[E[:, 0]])
        np.add.at(cnt, E[:, 0], 1); np.add.at(cnt, E[:, 1], 1)
        M = (1 - lam) * M + lam * acc / np.maximum(cnt, 1)[:, None]
    return M

def chain_weights(P, chains, bone_index, nb, theta_mode=False):
    """Weights for points on cloth from a set of chains: interpolate across the two nearest chains
    (by horizontal angle for skirts, by distance otherwise) and along each chain (by height)."""
    M = np.zeros((len(P), nb))
    if theta_mode:
        th_c = np.array([c['params']['theta'] for c in chains])
        th = np.arctan2(P[:, 0], -(P[:, 1] - 0.02))
        # two neighbouring chains
        order = np.argsort(th_c); th_s = th_c[order]
        k = np.searchsorted(th_s, th) % len(th_s); k0 = (k - 1) % len(th_s)
        a0 = th_s[k0]; a1 = th_s[k]
        span = (a1 - a0) % (2 * np.pi); t = ((th - a0) % (2 * np.pi)) / np.maximum(span, 1e-6)
        pairs = [(order[k0], 1 - t), (order[k], t)]
    else:
        C = np.array([np.array(c['points']).mean(0) for c in chains])
        d = np.linalg.norm(P[:, None, :] - C[None], axis=2)
        nn = np.argsort(d, axis=1)[:, :2]
        d0 = np.take_along_axis(d, nn[:, :1], 1)[:, 0]; d1 = np.take_along_axis(d, nn[:, 1:2], 1)[:, 0]
        t = d0 / np.maximum(d0 + d1, 1e-6)
        pairs = [(nn[:, 0], 1 - t), (nn[:, 1], t)]
    for ci, wgt in pairs:
        ci = np.broadcast_to(ci, (len(P),))
        for c_idx in np.unique(ci):
            sel = np.where(ci == c_idx)[0]
            c = chains[c_idx]; pts = np.array(c['points'])
            # parameter along the chain by nearest segment projection
            best_s = np.zeros(len(sel)); best_d = np.full(len(sel), 1e9)
            for s_i in range(len(pts) - 1):
                a, b = pts[s_i], pts[s_i + 1]; ab = b - a
                u = np.clip(((P[sel] - a) @ ab) / (ab @ ab), 0, 1)
                dd = np.linalg.norm(P[sel] - (a + u[:, None] * ab), axis=1)
                upd = dd < best_d; best_d[upd] = dd[upd]; best_s[upd] = s_i + u[upd]
            nbn = len(c['bones'])
            # bone j spans [j, j+1]; blend between bone j and j+1 around the joint
            f = np.clip(best_s - 0.5, 0, nbn - 1)
            j0 = np.floor(f).astype(int); j1 = np.minimum(j0 + 1, nbn - 1); ft = f - j0
            w_here = np.broadcast_to(wgt, (len(P),))[sel]
            np.add.at(M, (sel, [bone_index[c['bones'][j]] for j in j0]), w_here * (1 - ft))
            np.add.at(M, (sel, [bone_index[c['bones'][j]] for j in j1]), w_here * ft)
    return M

RIGID = {  # object name prefix -> bone(s) rule
    'vambrace': 'LowerArm', 'cuff': 'LowerArm', 'wrap': 'LowerArm', 'greave': 'LowerLeg', 'kneecop': 'LowerLeg',
    'lion': 'LowerLeg',
}

def main():
    bpy.ops.wm.open_mainfile(filepath=os.path.join(W, 'model_uv.blend'))
    materials.assign_all()
    B = kit.Body()
    S = skeleton_def(B)
    objs = {o.name: o for o in bpy.data.objects if o.type == 'MESH'}
    X = np.load(os.path.join(W, 'hair_strands.npy'))
    hc, hlab = hair_chains(X)
    chains = cape_chains(objs) + skirt_chains() + panel_chains(objs) + stole_chains(objs) + hc + pendant_chain() + dagger_chains()
    arm = make_armature(S, chains)
    bones = [b.name for b in arm.data.bones]
    bi = {b: i for i, b in enumerate(bones)}; nb = len(bones)
    humanoid = list(S.keys())
    Mb_h = body_weight_matrix(B, humanoid)
    Mb = np.zeros((len(B.V), nb)); Mb[:, [bi[h] for h in humanoid]] = Mb_h
    W_all = {}
    def world(ob):
        V = np.array([v.co for v in ob.data.vertices]); M = np.array(ob.matrix_world)
        return V @ M[:3, :3].T + M[:3, 3]
    if 'sword' in objs:
        f = SOCKET_FRAMES['SwordSocket']
        Mw = np.eye(4); Mw[:3, 0] = f['edge']; Mw[:3, 1] = f['flat']; Mw[:3, 2] = f['blade']; Mw[:3, 3] = f['origin']
        me = objs['sword'].data
        V = np.array([v.co for v in me.vertices]); V = V @ Mw[:3, :3].T + Mw[:3, 3]
        me.vertices.foreach_set('co', V.ravel()); me.update()
    for name, ob in objs.items():
        P = world(ob)
        side = 'Left' if (name.endswith('.L') or '_L' in name) else 'Right' if (name.endswith('.R') or '_R' in name) else ''
        base = name.split('.')[0]
        if name == 'body':
            M = Mb.copy()
        elif name == 'sword':
            M = np.zeros((len(P), nb)); M[:, bi['SwordSocket']] = 1
        elif name in ('eyes',) or name.startswith(('beard', 'brows')):
            M = np.zeros((len(P), nb)); M[:, bi['Head']] = 1
            if name == 'eyes':
                M[:] = 0; M[P[:, 0] > 0, bi['LeftEye']] = 1; M[P[:, 0] <= 0, bi['RightEye']] = 1
        elif name == 'hair':
            # each card: 2*m verts per strand (m points), strand -> chain, root part on Head
            n_str, m = X.shape[0], X.shape[1]
            M = np.zeros((len(P), nb))
            chain_of = {int(c['name'][4:]): c for c in hc}
            for s_i in range(n_str):
                c = chain_of.get(int(hlab[s_i]))
                vs = np.arange(s_i * 2 * m, (s_i + 1) * 2 * m)
                s_par = np.repeat(np.linspace(0, 1, m), 2)
                if c is None:
                    M[vs, bi['Head']] = 1; continue
                nbn = len(c['bones'])
                f = np.clip((s_par - 0.18) / 0.82, 0, 1) * nbn
                head_w = np.clip(1 - s_par / 0.18, 0, 1)
                j0 = np.clip(np.floor(f - 0.5).astype(int), 0, nbn - 1); j1 = np.clip(j0 + 1, 0, nbn - 1)
                ft = np.clip(f - 0.5 - np.floor(f - 0.5), 0, 1)
                for k, v in enumerate(vs):
                    M[v, bi['Head']] += head_w[k]
                    M[v, bi[c['bones'][j0[k]]]] += (1 - head_w[k]) * (1 - ft[k])
                    M[v, bi[c['bones'][j1[k]]]] += (1 - head_w[k]) * ft[k]
        elif uvlayout.GROUPS['cloth'](ob) and not base.startswith('wrap'):
            body_M = transfer(P, B, Mb)
            if base.startswith('cape'):
                cs = [c for c in chains if c['params'].get('group') == 'cape' and c['name'][4] == name[5]]
                chM = chain_weights(P, cs, bi, nb)
                top = np.clip((P[:, 2] - 1.45) / 0.12, 0, 1)[:, None]
                M = chM * (1 - top) + body_M * top
            elif base.startswith('robe'):
                cs = [c for c in chains if c['params'].get('group') == 'skirt']
                chM = chain_weights(P, cs, bi, nb, theta_mode=True)
                top = np.clip((P[:, 2] - 1.10) / 0.12, 0, 1)[:, None]
                hipM = np.zeros_like(chM); hipM[:, bi['Hips']] = 1
                M = chM * (1 - top) + hipM * top
            elif base.startswith(('tabard', 'panel')):
                tag = ''.join(w[0].upper() + w[1:] for w in name.split('_'))
                cs = [c for c in chains if c['name'] == tag]
                chM = chain_weights(P, cs * 2, bi, nb) if cs else body_M
                top = np.clip((P[:, 2] - 1.18) / 0.08, 0, 1)[:, None]
                hipM = np.zeros_like(chM); hipM[:, bi['Hips']] = 1
                M = chM * (1 - top) + hipM * top
            elif base.startswith('stole'):
                tag = ''.join(w[0].upper() + w[1:] for w in name.split('_'))
                cs = [c for c in chains if c['name'] == tag]
                chM = chain_weights(P, cs * 2, bi, nb)
                top = np.clip((P[:, 2] - 1.22) / 0.06, 0, 1)[:, None]
                M = chM * (1 - top) + body_M * top
            else:
                M = body_M
        else:
            M = transfer(P, B, Mb)
            rule = next((v for k, v in RIGID.items() if base.startswith(k)), None)
            sd = 'Left' if P[:, 0].mean() > 0 else 'Right'
            if rule:
                M = np.zeros((len(P), nb)); M[:, bi[sd + rule]] = 1
            elif base.startswith('lames'):
                M = np.zeros((len(P), nb))
                t = np.clip((0.16 - P[:, 2]) / 0.10, 0, 1)
                M[:, bi[sd + 'LowerLeg']] = 1 - t; M[:, bi[sd + 'Foot']] = t
            elif base.startswith('sabaton'):
                M = np.zeros((len(P), nb))
                ball_y = S[sd + 'Toes'][0][1]
                t = np.clip((ball_y + 0.01 - P[:, 1]) / 0.03, 0, 1)
                M[:, bi[sd + 'Foot']] = 1 - t; M[:, bi[sd + 'Toes']] = t
            elif base.startswith('pauldron'):
                # cap: mostly the upper arm with some shoulder so it rides the arm raise
                M = smooth_on_mesh(ob, M, 20)
                ua, sh = bi[sd + 'UpperArm'], bi[sd + 'Shoulder']
                capz = P[:, 2] > S[sd + 'UpperArm'][0][2] - 0.07
                Mc = np.zeros((len(P), nb)); Mc[:, ua] = 0.6; Mc[:, sh] = 0.4
                Ml = np.zeros((len(P), nb)); Ml[:, ua] = 1
                M = np.where(capz[:, None], Mc, Ml)
            elif base.startswith('chain'):
                cs = [c for c in chains if c['name'] == 'Pendant']
                M = chain_weights(P, cs * 2, bi, nb)
            elif base.startswith('dagger'):
                M = np.zeros((len(P), nb)); M[:, bi['Dagger' + sd[0] + '_0']] = 1
            elif base in ('belt', 'fauld'):
                M = np.zeros((len(P), nb)); M[:, bi['Hips']] = 1
            elif base in ('cuirass', 'collar', 'chest_medallion'):
                M = smooth_on_mesh(ob, M, 30, 0.6)
            else:
                M = smooth_on_mesh(ob, M, 10)
        W_all[name] = M
        for vg in list(ob.vertex_groups): ob.vertex_groups.remove(vg)
        set_weights(ob, {bones[j]: M[:, j] for j in range(nb) if M[:, j].max() > 1e-4})
    # merge by material
    groups = {}
    for name, ob in objs.items():
        if name == 'sword': continue
        groups.setdefault(ob.data.materials[0].name, []).append(ob)
    merged = {}
    for mname, lst in groups.items():
        nm = {'M_Body': 'Body', 'M_Armor': 'Armor', 'M_Cloth': 'Cloth', 'M_Hair': 'Hair', 'M_Eyes': 'Eyes'}[mname]
        merged[nm] = join_objects(lst, nm)
    if 'sword' in objs:
        merged['Sword'] = objs['sword']; objs['sword'].name = 'Sword'
    for nm, ob in merged.items():
        ob.parent = arm
        mod = ob.modifiers.new('Armature', 'ARMATURE'); mod.object = arm
        # keep only the 'UVMap' layer for export (pattern is for texture synthesis)
        if 'pattern' in ob.data.uv_layers: ob.data.uv_layers.remove(ob.data.uv_layers['pattern'])
    json.dump([{k: v for k, v in c.items()} for c in chains], open(os.path.join(W, 'chains.json'), 'w'), indent=1)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(W, 'model_rigged.blend'))
    tris = sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in merged.values())
    print('rig done: bones', nb, 'chains', len(chains), 'triangles', tris,
          {k: len(o.data.vertices) for k, o in merged.items()})

if __name__ == '__main__':
    main()

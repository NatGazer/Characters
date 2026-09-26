"""CMU motion capture (ASF skeleton + AMC motion) reader, pure numpy.

Returns, per frame, the global rotation matrix and the global joint positions of every ASF bone,
in Blender coordinates (metres, Z up). CMU data: Y up, lengths in (1/0.45) inches.
CMU Graphics Lab Motion Capture Database, http://mocap.cs.cmu.edu (free for all uses; please credit).
"""
import os
import numpy as np

CMU = os.environ.get('CMU_DIR', '/opt/assets/cmu/amc')

def rot(axis, deg):
    a = np.radians(deg); c, s = np.cos(a), np.sin(a)
    if axis == 'x': return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])
    if axis == 'y': return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])

def euler(vals, order):
    """Rotation applying angles in the listed order (first listed applied first)."""
    M = np.eye(3)
    for ax, v in zip(order, vals):
        M = rot(ax, v) @ M
    return M

class ASF:
    def __init__(self, path):
        self.bones = {}; self.children = {'root': []}; self.parent = {}
        lines = [l.strip() for l in open(path) if l.strip() and not l.strip().startswith('#')]
        i = 0; section = None; cur = None
        self.length_scale = 1.0; self.root_order = ['tx', 'ty', 'tz', 'rx', 'ry', 'rz']; self.root_axis = 'XYZ'
        self.root_orient = [0, 0, 0]; self.root_pos = [0, 0, 0]
        while i < len(lines):
            l = lines[i]
            if l.startswith(':'):
                section = l.split()[0]
                if section == ':units': pass
                i += 1; continue
            t = l.split()
            if section == ':units' and t[0] == 'length': self.length_scale = float(t[1])
            elif section == ':root':
                if t[0] == 'order': self.root_order = [x.lower() for x in t[1:]]
                elif t[0] == 'axis': self.root_axis = t[1]
                elif t[0] == 'orientation': self.root_orient = [float(x) for x in t[1:4]]
                elif t[0] == 'position': self.root_pos = [float(x) for x in t[1:4]]
            elif section == ':bonedata':
                if t[0] == 'begin': cur = {'dof': []}
                elif t[0] == 'end': self.bones[cur['name']] = cur; cur = None
                elif t[0] == 'name': cur['name'] = t[1]
                elif t[0] == 'direction': cur['dir'] = np.array([float(x) for x in t[1:4]])
                elif t[0] == 'length': cur['len'] = float(t[1])
                elif t[0] == 'axis': cur['axis'] = ([float(x) for x in t[1:4]], t[4])
                elif t[0] == 'dof': cur['dof'] = [x.lower() for x in t[1:]]
            elif section == ':hierarchy':
                if t[0] in ('begin', 'end'): pass
                else:
                    p = t[0]
                    for c in t[1:]:
                        self.children.setdefault(p, []).append(c); self.parent[c] = p
            i += 1
        self.unit = (1.0 / self.length_scale) * 0.0254   # metres per ASF length unit
        for b in self.bones.values():
            ang, order = b['axis']
            b['C'] = euler(ang, [c.lower() for c in order])
            b['Cinv'] = b['C'].T
        self.order = []
        def walk(n):
            for c in self.children.get(n, []):
                self.order.append(c); walk(c)
        walk('root')

def read_amc(path):
    frames = []; cur = None
    for l in open(path):
        l = l.strip()
        if not l or l.startswith('#') or l.startswith(':'): continue
        t = l.split()
        if len(t) == 1 and t[0].isdigit():
            cur = {}; frames.append(cur)
        elif cur is not None:
            cur[t[0]] = [float(x) for x in t[1:]]
    return frames

# CMU (x, y up, z) -> Blender (x, -z, y)
TO_BL = np.array([[1, 0, 0], [0, 0, -1], [0, 1, 0]], float)

def fk(asf, frames, step=1):
    """Global rotations (F,B,3,3) and bone-end positions (F,B,3), plus root position (F,3), Blender frame.
    Bone order = asf.order. Also returns rest (zero-pose) global directions (B,3)."""
    names = asf.order
    nF = len(frames[::step])
    R = np.zeros((nF, len(names), 3, 3)); P = np.zeros((nF, len(names), 3)); root = np.zeros((nF, 3))
    Rroot_all = np.zeros((nF, 3, 3))
    Cr = euler(asf.root_orient, [c.lower() for c in asf.root_axis])
    for fi, fr in enumerate(frames[::step]):
        vals = dict(zip(asf.root_order, fr['root']))
        pos = np.array([vals.get('tx', 0), vals.get('ty', 0), vals.get('tz', 0)]) * asf.unit
        rr = [vals.get('r' + c.lower(), 0) for c in asf.root_axis]
        Mroot = euler(rr, [c.lower() for c in asf.root_axis])
        G = {'root': Cr @ Mroot @ Cr.T @ np.eye(3)} if False else {'root': Mroot}
        E = {'root': pos}
        for bi, n in enumerate(names):
            b = asf.bones[n]; p = asf.parent[n]
            dv = fr.get(n, [0] * len(b['dof']))
            ang = {d: v for d, v in zip(b['dof'], dv)}
            M = euler([ang.get(d, 0) for d in b['dof']], [d[1] for d in b['dof']]) if b['dof'] else np.eye(3)
            L = b['C'] @ M @ b['Cinv']
            G[n] = G[p] @ L if p != 'root' else G['root'] @ L
            E[n] = E[p] + G[n] @ (b['dir'] * b['len'] * asf.unit)
            R[fi, bi] = TO_BL @ G[n] @ TO_BL.T
            P[fi, bi] = TO_BL @ E[n]
        root[fi] = TO_BL @ pos
        Rroot_all[fi] = TO_BL @ G['root'] @ TO_BL.T
    rest_dirs = np.array([TO_BL @ asf.bones[n]['dir'] for n in names])
    return dict(names=names, R=R, P=P, root=root, Rroot=Rroot_all, rest_dirs=rest_dirs,
                parent=[asf.parent[n] for n in names])

_FPS = None
def clip_fps(clip):
    """Capture rate from the CMU index (most clips 120 Hz, some 60 Hz)."""
    global _FPS
    if _FPS is None:
        _FPS = {}
        p = os.path.join(os.path.dirname(CMU), 'index.txt')
        if os.path.exists(p):
            for l in open(p):
                t = l.split('|')
                if len(t) > 1 and t[1].strip().isdigit(): _FPS[t[0]] = int(t[1])
    return _FPS.get(clip, 120)

def load(clip, step=1):
    subj = clip.split('_')[0]
    asf = ASF(os.path.join(CMU, f'{subj}.asf'))
    frames = read_amc(os.path.join(CMU, f'{clip}.amc'))
    d = fk(asf, frames, step)
    d['fps'] = clip_fps(clip) / step; d['src_fps'] = clip_fps(clip)
    return d

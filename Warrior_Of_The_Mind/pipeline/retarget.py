"""Retarget CMU mocap onto the Warrior rig (numpy; Blender only for rest data and writing actions).

Global rotation transfer with rest-pose correction:
    G_tgt(t) = G_src(t) * Swing(d_tgt_rest -> d_src_rest) * R_tgt_rest
so every target bone points exactly where the source bone points (T-pose vs A-pose rests handled),
with twist inherited from the source. Hips translation is scaled by the leg-length ratio.
Horizontal root motion and heading are moved to the Root bone (in-place variants strip them).
"""
import os, math
import numpy as np
import mocap

MAP = {  # humanoid bone -> CMU bone
    'Spine': 'lowerback', 'Chest': 'upperback', 'UpperChest': 'thorax', 'Neck': 'lowerneck', 'Head': 'head',
    'LeftShoulder': 'lclavicle', 'LeftUpperArm': 'lhumerus', 'LeftLowerArm': 'lradius', 'LeftHand': 'lwrist',
    'RightShoulder': 'rclavicle', 'RightUpperArm': 'rhumerus', 'RightLowerArm': 'rradius', 'RightHand': 'rwrist',
    'LeftUpperLeg': 'lfemur', 'LeftLowerLeg': 'ltibia', 'LeftFoot': 'lfoot', 'LeftToes': 'ltoes',
    'RightUpperLeg': 'rfemur', 'RightLowerLeg': 'rtibia', 'RightFoot': 'rfoot', 'RightToes': 'rtoes',
}

def unit(v):
    return v / np.maximum(np.linalg.norm(v, axis=-1, keepdims=True), 1e-12)

def swing(a, b):
    """Minimal rotation taking unit vector a to unit vector b."""
    a = unit(np.asarray(a, float)); b = unit(np.asarray(b, float))
    v = np.cross(a, b); c = float(np.dot(a, b))
    if np.linalg.norm(v) < 1e-9:
        if c > 0: return np.eye(3)
        p = unit(np.cross(a, [1, 0, 0]) if abs(a[0]) < 0.9 else np.cross(a, [0, 1, 0]))
        return 2 * np.outer(p, p) - np.eye(3)
    K = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + K + K @ K / (1 + c)

class Rig:
    """Rest data of the target armature: bone -> 4x4 rest matrix (armature space), parents, order."""
    def __init__(self, arm_obj):
        self.names = [b.name for b in arm_obj.data.bones]
        self.parent = {b.name: (b.parent.name if b.parent else None) for b in arm_obj.data.bones}
        self.rest = {b.name: np.array(b.matrix_local) for b in arm_obj.data.bones}
        self.length = {b.name: b.length for b in arm_obj.data.bones}

def ydir(M):
    return M[:3, 1] / np.linalg.norm(M[:3, 1])

def retarget(clip, rig, fps=30, step=None, frames=None):
    src_fps = mocap.clip_fps(clip)
    step = step or max(1, int(round(src_fps / fps)))
    d = mocap.load(clip, step=1)
    names = d['names']; ix = {n: i for i, n in enumerate(names)}
    R = d['R'][::step]; P = d['P'][::step]; root = d['root'][::step]; Rroot = d['Rroot'][::step]
    if frames is not None:
        a, b = frames
        a = int(a * fps / 30) // step if False else a // step; b = (b // step) if b is not None else len(R)
        R, P, root, Rroot = R[a:b], P[a:b], root[a:b], Rroot[a:b]
    nF = len(R)
    rest_dirs = d['rest_dirs']
    # leg-length scale
    src_leg = np.linalg.norm(P[0, ix['lfemur']] - P[0, ix['lhipjoint']]) + np.linalg.norm(P[0, ix['ltibia']] - P[0, ix['lfemur']])
    tgt_leg = rig.length['LeftUpperLeg'] + rig.length['LeftLowerLeg']
    scale = tgt_leg / src_leg
    G = {}
    # hips: root global rotation (rest = identity for CMU) applied to the target rest
    for t_name in ['Hips'] + list(MAP.keys()):
        Rt0 = rig.rest[t_name][:3, :3]
        if t_name == 'Hips':
            G[t_name] = Rroot @ Rt0
            continue
        s = ix[MAP[t_name]]
        ds0 = rest_dirs[s] / np.linalg.norm(rest_dirs[s])
        A = swing(ydir(rig.rest[t_name]), ds0)
        G[t_name] = R[:, s] @ (A @ Rt0)
    # hips position (armature space): source root position scaled, relative to the rest hips height
    hips_rest = rig.rest['Hips'][:3, 3]
    src_hip_rest_z = np.median(root[:, 2]) if False else None
    hp = root * scale
    # ground: CMU root height is measured from the floor, same as ours
    return dict(G=G, hips=hp, nF=nF, fps=fps, scale=scale, clip=clip)

def to_local(rig, G, hips_pos, root_xy=None, root_yaw=None):
    """Global rotations (per bone, (F,3,3)) -> Blender pose-basis quaternions and Hips location.
    Bones not in G keep rest (identity basis). Root bone gets root motion if given."""
    nF = len(hips_pos)
    out = {}
    glob = {}
    def mat4(Rm, t):
        M = np.tile(np.eye(4), (Rm.shape[0], 1, 1)); M[:, :3, :3] = Rm; M[:, :3, 3] = t; return M
    # Root
    if root_xy is not None:
        yawM = np.zeros((nF, 3, 3))
        c, s = np.cos(root_yaw), np.sin(root_yaw)
        yawM[:, 0, 0] = c; yawM[:, 0, 1] = -s; yawM[:, 1, 0] = s; yawM[:, 1, 1] = c; yawM[:, 2, 2] = 1
        glob['Root'] = mat4(yawM @ rig.rest['Root'][:3, :3], np.c_[root_xy, np.zeros(nF)])
    else:
        glob['Root'] = np.tile(rig.rest['Root'], (nF, 1, 1))
    for name in rig.names:
        if name == 'Root': continue
        par = rig.parent[name]
        PG = glob[par]
        rest_rel = np.linalg.inv(rig.rest[par]) @ rig.rest[name]
        if name in G:
            Rg = G[name]
            if name == 'Hips':
                Mg = mat4(Rg, hips_pos)
            else:
                # position follows the parent chain
                pos = (PG @ rest_rel)[:, :3, 3]
                Mg = mat4(Rg, pos)
        else:
            Mg = PG @ rest_rel
        glob[name] = Mg
        basis = np.linalg.inv(rest_rel)[None] @ np.linalg.inv(PG) @ Mg
        out[name] = basis
    out['Root'] = glob['Root'] @ np.linalg.inv(rig.rest['Root'])[None] if root_xy is not None else None
    return out, glob

def mat_to_quat(M):
    """(F,3,3) -> (F,4) w,x,y,z with sign continuity."""
    m = M
    tr = m[:, 0, 0] + m[:, 1, 1] + m[:, 2, 2]
    q = np.zeros((len(m), 4))
    for i in range(len(m)):
        a = m[i]
        if tr[i] > 0:
            s = math.sqrt(tr[i] + 1.0) * 2
            q[i] = [0.25 * s, (a[2, 1] - a[1, 2]) / s, (a[0, 2] - a[2, 0]) / s, (a[1, 0] - a[0, 1]) / s]
        elif a[0, 0] > a[1, 1] and a[0, 0] > a[2, 2]:
            s = math.sqrt(1.0 + a[0, 0] - a[1, 1] - a[2, 2]) * 2
            q[i] = [(a[2, 1] - a[1, 2]) / s, 0.25 * s, (a[0, 1] + a[1, 0]) / s, (a[0, 2] + a[2, 0]) / s]
        elif a[1, 1] > a[2, 2]:
            s = math.sqrt(1.0 + a[1, 1] - a[0, 0] - a[2, 2]) * 2
            q[i] = [(a[0, 2] - a[2, 0]) / s, (a[0, 1] + a[1, 0]) / s, 0.25 * s, (a[1, 2] + a[2, 1]) / s]
        else:
            s = math.sqrt(1.0 + a[2, 2] - a[0, 0] - a[1, 1]) * 2
            q[i] = [(a[1, 0] - a[0, 1]) / s, (a[0, 2] + a[2, 0]) / s, (a[1, 2] + a[2, 1]) / s, 0.25 * s]
    q /= np.linalg.norm(q, axis=1, keepdims=True)
    for i in range(1, len(q)):
        if np.dot(q[i], q[i - 1]) < 0: q[i] = -q[i]
    return q

def quat_to_mat(q):
    w, x, y, z = q[..., 0], q[..., 1], q[..., 2], q[..., 3]
    return np.stack([np.stack([1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)], -1),
                     np.stack([2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)], -1),
                     np.stack([2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)], -1)], -2)

def slerp(q0, q1, t):
    d = np.sum(q0 * q1, -1, keepdims=True)
    q1 = np.where(d < 0, -q1, q1); d = np.abs(d)
    t = np.asarray(t)[..., None] if np.ndim(t) else t
    lin = q0 + (q1 - q0) * t
    return lin / np.linalg.norm(lin, axis=-1, keepdims=True)

def heading(Rm):
    """Yaw of a rotation's forward (-Y) direction projected on the ground (radians)."""
    f = -Rm[..., :, 1]
    return np.arctan2(-f[..., 0], -f[..., 1]) * -1

"""Keyframe authoring DSL on top of animlib (runs under bpy).

Conventions (world axes, character faces -Y, Z up; rotations about the bone head in the rest frame,
composed down the hierarchy):
  spine/neck/head : +X leans/nods FORWARD, +Z turns toward the character's LEFT, +Y bends to the LEFT
  left arm        : -X raises forward, -Y abducts (out to the side), +Z rotates inward
  right arm       : mirror (use mirror_pose / R() helpers: ry and rz flip sign)
  forearm         : -X flexes the elbow (for a hanging arm)
  thigh           : -X raises the knee forward; knees/feet usually come from the leg IK

A key: dict(f=frame, pose={bone: (rx, ry, rz)}, ease='inout', hips=(dx, dy, dz) world offset,
            feet={'Left': (x, y, z, yaw_deg) world position of the ankle (absolute)}, root=(x, y, z, yaw_deg),
            fingers=('relaxed', 'fist')  # (left, right)
)
"""
import math
import numpy as np
import animlib as A
import retarget as RT

def mirror(p):
    """Left-side pose dict -> right side (and vice versa)."""
    out = {}
    for b, (rx, ry, rz) in p.items():
        nb = b.replace('Left', '#').replace('Right', 'Left').replace('#', 'Right')
        out[nb] = (rx, -ry, -rz)
    return out

def both(p):
    """Pose given for the left side, applied mirrored to the right as well."""
    q = dict(p); q.update(mirror(p)); return q

def merge(*ps):
    out = {}
    for p in ps:
        for b, v in p.items():
            out[b] = tuple(np.add(out.get(b, (0, 0, 0)), v))
    return out

class Clip:
    def __init__(self, rig, n, loop=False, fps=A.FPS):
        self.rig, self.n, self.loop, self.fps = rig, n, loop, fps
        self.keys = []

    def key(self, f, pose=None, ease='inout', hips=None, feet=None, root=None, fingers=None, hands=None):
        self.keys.append(dict(f=f, pose=pose or {}, ease=ease, hips=hips, feet=feet, root=root, fingers=fingers, hands=hands))
        return self

    # ------------------------------------------------------------------
    def build(self, overlap=None, lift=0.06, breathe=0.0, noise=None):
        rig, n = self.rig, self.n
        keys = sorted(self.keys, key=lambda k: k['f'])
        if self.loop and keys[-1]['f'] < n:          # loop: last key == first key at frame n
            k0 = dict(keys[0]); k0['f'] = n; keys.append(k0)
        frames = [k['f'] for k in keys]
        eases = [k['ease'] for k in keys]
        # carry forward unspecified values (hips/feet/root/fingers) from the previous key
        last = dict(hips=(0, 0, 0), root=(0, 0, 0, 0), fingers=('relaxed', 'relaxed'), feet={}, hands={})
        for k in keys:
            for fld in ('hips', 'root', 'fingers'):
                if k[fld] is None: k[fld] = last[fld]
                last[fld] = k[fld]
            ft = dict(last['feet']); ft.update(k['feet'] or {}); k['feet'] = ft; last['feet'] = ft
            hd = dict(last['hands']); hd.update(k['hands'] or {}); k['hands'] = {s_: v for s_, v in hd.items() if v}; last['hands'] = hd
        m = n + 1 if self.loop else n
        bones = set(); [bones.update(k['pose'].keys()) for k in keys]
        pose_keys = [(k['f'], {b: k['pose'].get(b, (0, 0, 0)) for b in bones}, k['ease'], k['hips'], None) for k in keys]
        c = A.pose_clip(rig, pose_keys, m, fps=self.fps, loop=self.loop)
        # root motion (world), yaw in degrees in the keys
        rk = np.array([[k['root'][0], k['root'][1], k['root'][2], math.radians(k['root'][3])] for k in keys])
        c['root'] = A._interp_vec(frames, rk, eases, m)
        # feet IK (world targets -> root space), with a lift arc while a foot travels
        for side in ('Left', 'Right'):
            if not any(side in k['feet'] for k in keys): continue
            rest = A.rest_ankle(rig, side)
            vals = np.array([k['feet'].get(side, (*rest, 0.0)) for k in keys], float)
            pos = A._interp_vec(frames, vals, eases, m)
            # lift: bump proportional to horizontal travel within each key segment
            i, t = A._seg(frames, m, eases)
            seg_d = np.linalg.norm(vals[i + 1, :2] - vals[i, :2], axis=1)
            pos[:, 2] += 4 * t * (1 - t) * np.clip(seg_d / 0.3, 0, 1) * lift
            yaw = np.radians(pos[:, 3])
            # world -> root space
            cr, sr = np.cos(-c['root'][:, 3]), np.sin(-c['root'][:, 3])
            dx = pos[:, 0] - c['root'][:, 0]; dy = pos[:, 1] - c['root'][:, 1]
            loc = np.stack([cr * dx - sr * dy, sr * dx + cr * dy, pos[:, 2] - c['root'][:, 2]], 1)
            c = A.leg_ik(rig, c, side, loc, foot_yaw=yaw - c['root'][:, 3])
        # hands (arm IK): per side dict(pos, across, palm, pole); keys without a side release it to FK
        for side in ('Left', 'Right'):
            if not any((k['hands'] or {}).get(side) for k in keys): continue
            has = np.array([bool((k['hands'] or {}).get(side)) for k in keys], float)
            def val(k, fld, default):
                h = (k['hands'] or {}).get(side)
                return np.asarray(h.get(fld, default) if h else default, float)
            sg = 1 if side == 'Left' else -1
            Gc = A.fk(rig, c)
            wr_fk = Gc[side + 'Hand'][:, :3, 3]
            pos = A._interp_vec(frames, np.array([val(k, 'pos', (0, 0, 0)) for k in keys]), eases, m)
            acr = A._interp_vec(frames, np.array([val(k, 'across', (0, -1, 0)) for k in keys]), eases, m)
            plm = A._interp_vec(frames, np.array([val(k, 'palm', (-sg, 0, 0)) for k in keys]), eases, m)
            pol = A._interp_vec(frames, np.array([val(k, 'pole', (0.5 * sg, 0.45, -0.6)) for k in keys]), eases, m)
            wgt = A._interp_vec(frames, has[:, None], eases, m)[:, 0]
            # world -> root space
            cr, sr = np.cos(-c['root'][:, 3]), np.sin(-c['root'][:, 3])
            def to_root(v, is_point):
                dx = v[:, 0] - (c['root'][:, 0] if is_point else 0); dy = v[:, 1] - (c['root'][:, 1] if is_point else 0)
                return np.stack([cr * dx - sr * dy, sr * dx + cr * dy, v[:, 2] - (c['root'][:, 2] if is_point else 0)], 1)
            # hand targets are body (root) relative: they travel and turn with the root motion
            pos_r = wr_fk * (1 - wgt[:, None]) + pos * wgt[:, None]
            before = {b: c['q'][b].copy() for b in (side + 'UpperArm', side + 'LowerArm', side + 'Hand')}
            c = A.arm_ik(rig, c, side, pos_r, acr, plm, pol)
            for b, q0 in before.items():     # blend IK <-> FK where keys release the hand
                c['q'][b] = A.qnorm(RT.slerp(q0, c['q'][b], wgt))
        # fingers
        fl = [k['fingers'][0] for k in keys]; fr = [k['fingers'][1] for k in keys]
        axes = A.finger_curl_axes(rig)
        for side, names in (('Left', fl), ('Right', fr)):
            i, t = A._seg(frames, m, eases)
            fq = None
            for a_name in set(names):
                pass
            # per-frame blend between the key's finger pose and the next one
            per = {}
            for kk in range(len(keys) - 1):
                sel = np.where(i == kk)[0]
                if len(sel) == 0: continue
                q = A.finger_pose(rig, ((names[kk], names[kk + 1]), t[sel]), side, len(sel), axes)
                for b, v in q.items():
                    per.setdefault(b, np.tile([1.0, 0, 0, 0], (m, 1)))[sel] = v
            for b, v in per.items():
                c['q'][b] = A.qnorm(A.qmul(c['q'][b], v))
        if breathe: A.breathing(rig, c, amp=breathe)
        if noise:
            for bone, amp_deg, period, seed in noise:
                t = np.arange(m) / self.fps
                for ax_i, ax in enumerate(((1, 0, 0), (0, 1, 0), (0, 0, 1))):
                    A.add_world_rot(rig, c, bone, ax, np.radians(amp_deg) * A.loop_noise(t, period, seed + ax_i))
        if overlap:
            for bone, lag, damping in overlap:
                spring_filter(c, bone, lag, damping, loop=self.loop)
        if self.loop:
            # drop the duplicated closing frame
            c['q'] = {b: q[:n] for b, q in c['q'].items()}
            c['hips'] = c['hips'][:n]; c['root'] = c['root'][:n]; c['n'] = n
        return c

def spring_filter(c, bone, lag_frames, damping=0.55, loop=False, substeps=8):
    """Second-order follow-through on a bone's local rotation: it lags the key poses and overshoots
    slightly (underdamped), like a limb carried by momentum. Semi-implicit Euler with substeps
    (unconditionally stable for these rates)."""
    q = c['q'][bone].copy(); n = len(q)
    w = 2 * math.pi / max(lag_frames * 2.5, 1.0)
    dt = 1.0 / substeps
    x = q[0].copy(); v = np.zeros(4)
    passes = 2 if loop else 1
    out = np.zeros_like(q)
    for p in range(passes):
        for i in range(n):
            for _ in range(substeps):
                a = w * w * (q[i] - x) - 2 * damping * w * v
                v = v + a * dt; x = x + v * dt
            out[i] = x / np.linalg.norm(x)
    c['q'][bone] = A.qnorm(out)
    return c

def hold(c, n_extra):
    """Append n_extra frames holding the last pose."""
    for b in c['q']: c['q'][b] = np.vstack([c['q'][b], np.repeat(c['q'][b][-1:], n_extra, 0)])
    c['hips'] = np.vstack([c['hips'], np.repeat(c['hips'][-1:], n_extra, 0)])
    c['root'] = np.vstack([c['root'], np.repeat(c['root'][-1:], n_extra, 0)])
    c['n'] += n_extra
    return c

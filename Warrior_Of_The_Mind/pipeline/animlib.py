"""Animation toolkit for the Warrior rig (runs under bpy).

A clip is a dict:  q[bone] -> (F,4) pose-basis quaternions (w,x,y,z); hips -> (F,3) Hips basis location;
root -> (F,4) [x, y, z, yaw] root motion (Root bone), fps, loop flag.
Mocap clips come from retarget.py; authored clips are built from key poses (bone -> Euler degrees in
the bone's *world-aligned* frame) with easing, overlap and noise; both get procedural layers
(fingers, breathing, eye/head micro motion). write_action() stores each clip as a Blender action
(layered-action API, bulk F-curve writes) stashed on an NLA track for glTF export.
"""
import math
import numpy as np
import bpy
from mathutils import Matrix, Quaternion, Euler
import retarget as RT

FPS = 30

# ----------------------------------------------------------------------------- math helpers
def qmul(a, b):
    w1, x1, y1, z1 = np.moveaxis(a, -1, 0); w2, x2, y2, z2 = np.moveaxis(b, -1, 0)
    return np.stack([w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2, w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2,
                     w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2, w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2], -1)

def qaxis(axis, ang):
    axis = np.asarray(axis, float); axis = axis / np.linalg.norm(axis)
    ang = np.asarray(ang, float)
    return np.concatenate([np.cos(ang / 2)[..., None], np.sin(ang / 2)[..., None] * axis], -1)

def qnorm(q):
    q = q / np.linalg.norm(q, axis=-1, keepdims=True)
    for i in range(1, len(q)):
        if np.dot(q[i], q[i - 1]) < 0: q[i] = -q[i]
    return q

def world_to_local_rot(rig, bone, Rw):
    """Rotation given in armature space (applied about the bone head, at rest) -> bone-local basis rot."""
    R0 = rig.rest[bone][:3, :3]
    return R0.T @ Rw @ R0

def ease(t, kind='inout'):
    t = np.clip(t, 0, 1)
    if kind == 'linear': return t
    if kind == 'in': return t * t * t
    if kind == 'out': return 1 - (1 - t) ** 3
    if kind == 'back': s = 1.7; t2 = t - 1; return 1 + t2 * t2 * ((s + 1) * t2 + s)       # overshoot
    return t * t * (3 - 2 * t) if kind == 'smooth' else np.where(t < 0.5, 4 * t ** 3, 1 - (-2 * t + 2) ** 3 / 2)

def loop_noise(t, period, seed, octaves=3):
    """Periodic smooth noise in [-1,1] (sum of sines with integer harmonics)."""
    rng = np.random.default_rng(seed); out = 0; amp = 1; tot = 0
    for o in range(octaves):
        k = rng.integers(1, 3) * (2 ** o); ph = rng.uniform(0, 2 * np.pi)
        out = out + amp * np.sin(2 * np.pi * k * t / period + ph); tot += amp; amp *= 0.5
    return out / tot

# ----------------------------------------------------------------------------- clips
def empty_clip(rig, n, loop=False, fps=FPS):
    q = {b: np.tile([1.0, 0, 0, 0], (n, 1)) for b in rig.names}
    return dict(q=q, hips=np.zeros((n, 3)), root=np.zeros((n, 4)), n=n, fps=fps, loop=loop)

def from_mocap(rig, clip, frames=None, fps=FPS, root_motion=True):
    r = RT.retarget(clip, rig, fps=fps, frames=frames)
    G = r['G']; hips = r['hips']; nF = r['nF']
    # heading of the hips -> root yaw; horizontal hips position -> root xy
    fwd = -G['Hips'][:, :3, :3] @ np.linalg.inv(rig.rest['Hips'][:3, :3])[None] @ np.array([0, 1.0, 0]) if False else None
    Rh = G['Hips'] @ np.linalg.inv(rig.rest['Hips'][:3, :3])[None]      # hips rotation relative to rest
    f = Rh @ np.array([0, -1.0, 0])
    yaw = np.unwrap(np.arctan2(f[:, 0], -f[:, 1]))                      # 0 = facing -Y; +yaw turns toward +X
    up = (Rh @ np.array([0, 0, 1.0]))[:, 2]
    good = up > 0.8                      # heading is only meaningful while the torso is upright
    if good.any() and not good.all():
        yaw = np.interp(np.arange(nF), np.where(good)[0], yaw[good])
    yaw = yaw - yaw[0]
    if root_motion:
        root_xy = hips[:, :2] - hips[0, :2]
        root_yaw = yaw      # rotation about +Z of the body heading (R_z(yaw) maps -Y onto the facing)
    else:
        root_xy = np.zeros((nF, 2)); root_yaw = np.zeros(nF)
    # remove the starting heading so every clip starts facing -Y at the origin
    y0 = math.atan2(-(Rh[0] @ [0, -1, 0])[0], -(Rh[0] @ [0, -1, 0])[1]) * -1
    c, s = math.cos(-y0), math.sin(-y0)
    Rz = np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])
    Rz0 = Rz
    for k in G: G[k] = Rz0[None] @ G[k]
    hips = (Rz0 @ (hips - np.r_[hips[0, :2], 0]).T).T
    root_xy = (Rz0[:2, :2] @ root_xy.T).T
    # hips relative to the root: remove root motion from the hips
    from scipy.ndimage import gaussian_filter1d
    if root_motion and nF > 8:
        root_yaw = gaussian_filter1d(root_yaw, 6, mode='nearest')
        root_xy = gaussian_filter1d(root_xy, 4, axis=0, mode='nearest')
    c = np.cos(-root_yaw); s = np.sin(-root_yaw)
    rel = hips.copy(); rel[:, :2] -= root_xy
    rel_x = c * rel[:, 0] - s * rel[:, 1]; rel_y = s * rel[:, 0] + c * rel[:, 1]
    rel[:, 0], rel[:, 1] = rel_x, rel_y
    Ryaw_inv = np.zeros((nF, 3, 3)); Ryaw_inv[:, 0, 0] = c; Ryaw_inv[:, 0, 1] = -s; Ryaw_inv[:, 1, 0] = s; Ryaw_inv[:, 1, 1] = c; Ryaw_inv[:, 2, 2] = 1
    Gl = {k: Ryaw_inv @ v for k, v in G.items()}
    basis, glob = RT.to_local(rig, Gl, rel + 0)
    clip_ = empty_clip(rig, nF, fps=fps)
    for b, M in basis.items():
        if b == 'Root' or M is None: continue
        clip_['q'][b] = RT.mat_to_quat(M[:, :3, :3])
        if b == 'Hips':
            clip_['hips'] = M[:, :3, 3]
    clip_['root'] = np.c_[root_xy, np.zeros(nF), root_yaw]
    clip_['src'] = clip
    return clip_

def trim(c, a, b):
    out = dict(c); out['q'] = {k: v[a:b] for k, v in c['q'].items()}
    out['hips'] = c['hips'][a:b]; out['root'] = c['root'][a:b] - np.r_[c['root'][a, :2], 0, c['root'][a, 3]] * [1, 1, 0, 1]
    out['n'] = b - a
    # rotate root motion so the clip starts facing forward
    return out

def pose_features(rig, c):
    """Per-frame feature vector (quats of main bones + hips height) for loop matching."""
    keys = ['Hips', 'Spine', 'Chest', 'LeftUpperLeg', 'LeftLowerLeg', 'RightUpperLeg', 'RightLowerLeg',
            'LeftUpperArm', 'RightUpperArm', 'LeftLowerArm', 'RightLowerArm', 'LeftFoot', 'RightFoot']
    F = [c['q'][k] * np.sign(c['q'][k][:, :1] + 1e-9) for k in keys] + [c['hips'][:, 2:3] * 4]
    return np.concatenate(F, 1)

def find_loop(rig, c, min_len, max_len, search=(0.15, 0.75)):
    f = pose_features(rig, c); n = c['n']
    v = np.gradient(f, axis=0)
    best = None
    for a in range(int(n * search[0]), int(n * search[1])):
        for L in range(min_len, max_len + 1):
            b = a + L
            if b >= n: break
            e = np.linalg.norm(f[a] - f[b]) + 0.5 * np.linalg.norm(v[a] - v[b]) * 5
            if best is None or e < best[0]: best = (e, a, b)
    return best

def make_loop(rig, c, a, b, blend=6):
    """Cut [a, b) and cross-fade the tail into the head so frame b-1 -> a is seamless.
    Root motion is converted to in-place (average velocity removed, stored in c['speed'])."""
    out = trim(c, a, b + blend)
    n = b - a
    for k in out['q']:
        q = out['q'][k]
        for i in range(blend):
            t = (i + 1) / (blend + 1); t = t * t * (3 - 2 * t)
            q[n - blend + i] = RT.slerp(q[n - blend + i][None], q[i][None] if i < n else q[0][None], t)[0] if False else \
                RT.slerp(q[n - blend + i][None], q[i - blend + blend][None], 0)[0]
    # simpler, robust: blend the last `blend` frames toward the first frames' continuation
    for k in out['q']:
        q = out['q'][k]
        head = q[n:n + blend]            # frames b..b+blend of the source ~ frames a..a+blend
        for i in range(blend):
            t = (i + 1) / (blend + 1); t = t * t * (3 - 2 * t)
            q[n - blend + i] = RT.slerp(q[n - blend + i][None], q[i][None], t)[0]
        out['q'][k] = qnorm(q[:n])
    hips = out['hips']
    for i in range(blend):
        t = (i + 1) / (blend + 1); t = t * t * (3 - 2 * t)
        hips[n - blend + i] = hips[n - blend + i] * (1 - t) + hips[i] * t
    out['hips'] = hips[:n]
    r = out['root'][:n + 1] if len(out['root']) > n else out['root']
    dist = out['root'][n, :2] - out['root'][0, :2] if len(out['root']) > n else out['root'][-1, :2] - out['root'][0, :2]
    dur = n / out['fps']
    out['speed'] = float(np.linalg.norm(dist) / dur)
    out['root'] = np.zeros((n, 4)); out['n'] = n; out['loop'] = True
    return out

# ----------------------------------------------------------------------------- procedural layers
def finger_curl_axes(rig):
    """World axis to flex each finger bone about its head (rest frame): the axis is parallel to the
    knuckle line, signed so a positive angle moves the fingertip toward the palm (d x palm).
    The thumb flexes across the palm toward the little finger."""
    axes = {}
    for side in ('Left', 'Right'):
        y0, a0, p0 = hand_rest_frame(rig, side)
        for f in ('Index', 'Middle', 'Ring', 'Little', 'Thumb'):
            for seg in ('Metacarpal', 'Proximal', 'Intermediate', 'Distal'):
                b = side + f + seg
                if b not in rig.rest: continue
                d = rig.rest[b][:3, 1]
                if f != 'Thumb':
                    ax = np.cross(d, p0)
                else:
                    tgt = kit_unit(-a0 * 0.8 + p0 * 0.6)          # toward the little finger, into the palm
                    ax = np.cross(d, tgt)
                ax /= np.linalg.norm(ax)
                axes[b] = ax
    return axes

def kit_unit(v):
    return v / np.linalg.norm(v)

FINGER_POSES = {  # degrees per segment (proximal, intermediate, distal), thumb (meta, prox, distal)
    'relaxed': dict(f=(9, 14, 9), spread=3, thumb=(6, 8, 10)),
    'fist': dict(f=(80, 95, 60), spread=0, thumb=(25, 35, 40)),
    'claw': dict(f=(8, 28, 32), spread=12, thumb=(-4, 12, 22)),      # the ref combat hands: hooked, spread
    'open': dict(f=(4, 4, 2), spread=12, thumb=(-5, 0, 0)),           # the ref gesture hand
    'grip': dict(f=(70, 80, 45), spread=0, thumb=(30, 30, 25)),       # sword grip
    'cast': dict(f=(-8, 5, 5), spread=16, thumb=(-10, 0, 5)),
}

def finger_pose(rig, name_or_weights, side, n, axes=None, jitter_seed=None):
    """Returns bone -> (n,4) quats for one hand. name_or_weights: pose name or (n,) array blend
    between two names given as ((nameA, nameB), w)."""
    axes = axes or finger_curl_axes(rig)
    if isinstance(name_or_weights, str):
        A = B = FINGER_POSES[name_or_weights]; w = np.zeros(n)
    else:
        (na, nb), w = name_or_weights; A, B = FINGER_POSES[na], FINGER_POSES[nb]
    out = {}
    fingers = ['Index', 'Middle', 'Ring', 'Little']
    y0, a0, p0 = hand_rest_frame(rig, side)
    spread_w = [1.0, 0.0, -1.0, -1.8]
    for fi, f in enumerate(fingers):
        for si, seg in enumerate(('Proximal', 'Intermediate', 'Distal')):
            b = side + f + seg
            deg = A['f'][si] * (1 - w) + B['f'][si] * w
            if seg == 'Proximal':
                sp = (A['spread'] * (1 - w) + B['spread'] * w) * spread_w[fi]
                d = rig.rest[b][:3, 1]; sax = np.cross(d, a0); sax /= np.linalg.norm(sax)
                Rs = [RT.quat_to_mat(qaxis(sax, math.radians(sp[k] if np.ndim(sp) else sp))) for k in range(n)]
            else:
                Rs = None
            deg = deg * (1 + 0.06 * fi)                   # little finger curls a bit more
            Rw = [RT.quat_to_mat(qaxis(axes[b], math.radians(1)))]  # placeholder for shape
            qs = []
            for k in range(n):
                q = qaxis(axes[b], math.radians(deg[k] if np.ndim(deg) else deg))
                Mw = RT.quat_to_mat(q)
                if Rs is not None: Mw = Mw @ Rs[k]
                Ml = world_to_local_rot(rig, b, Mw)
                qs.append(RT.mat_to_quat(Ml[None])[0])
            out[b] = np.array(qs)
    for si, seg in enumerate(('Metacarpal', 'Proximal', 'Distal')):
        b = side + 'Thumb' + seg
        deg = A['thumb'][si] * (1 - w) + B['thumb'][si] * w
        qs = []
        for k in range(n):
            Mw = RT.quat_to_mat(qaxis(axes[b], math.radians(deg[k] if np.ndim(deg) else deg)))
            qs.append(RT.mat_to_quat(world_to_local_rot(rig, b, Mw)[None])[0])
        out[b] = np.array(qs)
    return out

def apply_fingers(rig, c, left, right, axes=None):
    for side, spec in (('Left', left), ('Right', right)):
        for b, q in finger_pose(rig, spec, side, c['n'], axes).items():
            c['q'][b] = qnorm(qmul(c['q'][b], q))
    return c

def add_world_rot(rig, c, bone, axis_world, ang):
    """Post-multiply a rotation about a world axis (through the bone head, rest frame) onto a bone."""
    ang = np.broadcast_to(np.asarray(ang, float), (c['n'],))
    R0 = rig.rest[bone][:3, :3]
    ax_local = R0.T @ np.asarray(axis_world, float)
    c['q'][bone] = qnorm(qmul(c['q'][bone], qaxis(ax_local, ang)))
    return c

def breathing(rig, c, rate=0.23, amp=1.0):
    t = np.arange(c['n']) / c['fps']
    if c.get('loop'):
        dur = c['n'] / c['fps']; cycles = max(1, round(dur * rate)); rate = cycles / dur
    b = np.sin(2 * np.pi * rate * t)
    add_world_rot(rig, c, 'Chest', (1, 0, 0), np.radians(0.9 * amp) * b)
    add_world_rot(rig, c, 'UpperChest', (1, 0, 0), np.radians(1.2 * amp) * b)
    add_world_rot(rig, c, 'LeftShoulder', (0, 1, 0), np.radians(0.8 * amp) * b)
    add_world_rot(rig, c, 'RightShoulder', (0, 1, 0), np.radians(-0.8 * amp) * b)
    add_world_rot(rig, c, 'Neck', (1, 0, 0), np.radians(-0.6 * amp) * b)
    return c

# ----------------------------------------------------------------------------- authored poses
def pose_clip(rig, keys, n, fps=FPS, loop=False):
    """keys: list of (frame, {bone: (ax_deg, ay_deg, az_deg) world-axis rotations}, ease_kind, hips_offset, root)
    Rotations are world-axis XYZ Euler (applied about the bone head at rest), interpolated between keys."""
    c = empty_clip(rig, n, loop, fps)
    frames = [k[0] for k in keys]
    bones = set(); [bones.update(k[1].keys()) for k in keys]
    for b in bones:
        vals = np.array([k[1].get(b, (0, 0, 0)) for k in keys], float)
        c['q'][b] = _interp_rot(rig, b, frames, vals, [k[2] for k in keys], n)
    hk = np.array([k[3] if len(k) > 3 and k[3] is not None else (0, 0, 0) for k in keys], float)
    R0 = rig.rest['Hips'][:3, :3]
    c['hips'] = _interp_vec(frames, hk, [k[2] for k in keys], n) @ R0      # world offset -> Hips-local
    rk = np.array([k[4] if len(k) > 4 and k[4] is not None else (0, 0, 0, 0) for k in keys], float)
    c['root'] = _interp_vec(frames, rk, [k[2] for k in keys], n)
    return c

def _seg(frames, n, eases):
    """For each output frame: key index i, local t in [0,1] eased."""
    fr = np.arange(n)
    i = np.clip(np.searchsorted(frames, fr, side='right') - 1, 0, len(frames) - 2)
    a = np.array(frames)[i]; b = np.array(frames)[i + 1]
    t = np.clip((fr - a) / np.maximum(b - a, 1), 0, 1)
    te = np.array([ease(t[k], eases[i[k] + 1]) for k in range(n)])
    return i, te

def _interp_vec(frames, vals, eases, n):
    if len(frames) == 1: return np.tile(vals[0], (n, 1))
    i, t = _seg(frames, n, eases)
    return vals[i] * (1 - t[:, None]) + vals[i + 1] * t[:, None]

def euler_world(deg):
    rx, ry, rz = np.radians(deg)
    return RT.quat_to_mat(qaxis((0, 0, 1), rz)) @ RT.quat_to_mat(qaxis((0, 1, 0), ry)) @ RT.quat_to_mat(qaxis((1, 0, 0), rx))

def _interp_rot(rig, bone, frames, vals, eases, n):
    Q = np.array([RT.mat_to_quat(world_to_local_rot(rig, bone, euler_world(v))[None])[0] for v in vals])
    Q = qnorm(Q)
    if len(frames) == 1: return np.tile(Q[0], (n, 1))
    i, t = _seg(frames, n, eases)
    return qnorm(RT.slerp(Q[i], Q[i + 1], t))

def overlay(c, other, weight, bones=None):
    """Add `other`'s rotations on top of c (weight 0..1 per frame or scalar)."""
    w = np.broadcast_to(np.asarray(weight, float), (c['n'],))
    for b in (bones or other['q'].keys()):
        idq = np.tile([1.0, 0, 0, 0], (c['n'], 1))
        q = RT.slerp(idq, other['q'][b][:c['n']], w)
        c['q'][b] = qnorm(qmul(c['q'][b], q))
    return c

def blend(c1, c2, w, bones=None):
    """Per-frame blend c1 -> c2 (weight array)."""
    out = dict(c1); out['q'] = dict(c1['q'])
    w = np.broadcast_to(np.asarray(w, float), (c1['n'],))
    for b in (bones or c1['q'].keys()):
        out['q'][b] = qnorm(RT.slerp(c1['q'][b], c2['q'][b][:c1['n']], w))
    if bones is None:
        out['hips'] = c1['hips'] * (1 - w[:, None]) + c2['hips'][:c1['n']] * w[:, None]
    return out

def concat(clips, blend_frames=8):
    """Concatenate clips with pose cross-fades; root motion accumulated."""
    out = clips[0]
    for c in clips[1:]:
        n1, n2 = out['n'], c['n']; k = min(blend_frames, n1, n2)
        new = dict(out); new['q'] = {}
        for b in out['q']:
            a = out['q'][b]; bq = c['q'][b].copy()
            for i in range(k):
                t = (i + 1) / (k + 1); t = t * t * (3 - 2 * t)
                bq[i] = RT.slerp(a[n1 - k + i][None], bq[i][None], t)[0]
            new['q'][b] = qnorm(np.vstack([a[:n1 - k], bq]))
        h = c['hips'].copy()
        for i in range(k):
            t = (i + 1) / (k + 1); t = t * t * (3 - 2 * t); h[i] = out['hips'][n1 - k + i] * (1 - t) + h[i] * t
        new['hips'] = np.vstack([out['hips'][:n1 - k], h])
        # root: continue from the end of the first clip, rotated by its final yaw
        r0 = out['root'][n1 - k - 1] if n1 - k - 1 >= 0 else out['root'][0]
        cy, sy = math.cos(r0[3]), math.sin(r0[3])
        rr = c['root'].copy()
        x = cy * rr[:, 0] - sy * rr[:, 1]; y = sy * rr[:, 0] + cy * rr[:, 1]
        rr[:, 0] = x + r0[0]; rr[:, 1] = y + r0[1]; rr[:, 3] += r0[3]
        new['root'] = np.vstack([out['root'][:n1 - k], rr])
        new['n'] = len(new['hips'])
        out = new
    return out

# ----------------------------------------------------------------------------- writing actions
def write_action(arm, name, c, rig):
    act = bpy.data.actions.new(name); act.use_fake_user = True
    if arm.animation_data is None: arm.animation_data_create()
    slot = act.slots.new(id_type='OBJECT', name=arm.name)
    layer = act.layers.new('Layer'); strip = layer.strips.new(type='KEYFRAME')
    cb = strip.channelbag(slot, ensure=True)
    n = c['n']; frames = np.arange(1, n + 1, dtype=np.float64)
    def put(path, idx, vals, group):
        fc = cb.fcurves.new(path, index=idx, group_name=group)
        fc.keyframe_points.add(n)
        co = np.empty(2 * n); co[0::2] = frames; co[1::2] = vals
        fc.keyframe_points.foreach_set('co', co)
        fc.keyframe_points.foreach_set('interpolation', [1] * n)   # LINEAR
        fc.update()
    for b in rig.names:
        if b == 'Root': continue
        q = c['q'].get(b)
        if q is None: continue
        if np.allclose(q, [1, 0, 0, 0], atol=1e-6) and b not in ('Hips',): continue
        for i in range(4): put(f'pose.bones["{b}"].rotation_quaternion', i, q[:, i], b)
    for i in range(3): put('pose.bones["Hips"].location', i, c['hips'][:, i], 'Hips')
    # root motion: Root bone rest has Y along -world Y (head at origin, tail -0.25 y) -> set via matrices
    R = root_basis(rig, c['root'])
    for i in range(3): put('pose.bones["Root"].location', i, R[0][:, i], 'Root')
    for i in range(4): put('pose.bones["Root"].rotation_quaternion', i, R[1][:, i], 'Root')
    sw = c.get('sword_scale')
    if sw is None: sw = np.full(n, 1.0 if c.get('sword') else 0.001)
    if 'SwordSocket' in rig.names:
        for i in range(3): put('pose.bones["SwordSocket"].scale', i, np.asarray(sw, float), 'SwordSocket')
    act.frame_range = (1, n)
    try: act.use_frame_range = True; act.use_cyclic = bool(c.get('loop'))
    except Exception: pass
    arm.animation_data.action = act
    try: arm.animation_data.action_slot = slot
    except Exception: pass
    tr = arm.animation_data.nla_tracks.new(); tr.name = name
    st = tr.strips.new(name, 1, act); tr.mute = True
    arm.animation_data.action = None
    return act

def root_basis(rig, root):
    """Root motion (x, y, z, yaw) in armature space -> Root pose-basis location and quaternion."""
    R0 = rig.rest['Root']
    n = len(root)
    locs = np.zeros((n, 3)); quats = np.zeros((n, 4))
    for i in range(n):
        x, y, z, yaw = root[i]
        c, s = math.cos(yaw), math.sin(yaw)
        Mw = np.array([[c, -s, 0, x], [s, c, 0, y], [0, 0, 1, z], [0, 0, 0, 1]])
        Mg = Mw @ R0
        basis = np.linalg.inv(R0) @ Mg
        locs[i] = basis[:3, 3]; quats[i] = RT.mat_to_quat(basis[None, :3, :3])[0]
    return locs, qnorm(quats)

def hips_basis_from_world(rig, pos):
    """Hips armature-space position -> Hips basis location (Hips parent = Root at rest)."""
    rest_rel = np.linalg.inv(rig.rest['Root']) @ rig.rest['Hips']
    out = []
    for p in pos:
        M = np.eye(4); M[:3, 3] = p; M[:3, :3] = rig.rest['Hips'][:3, :3]
        b = np.linalg.inv(rest_rel) @ np.linalg.inv(rig.rest['Root']) @ M
        out.append(b[:3, 3])
    return np.array(out)

# ----------------------------------------------------------------------------- FK / IK
def fk(rig, c, with_root=False):
    """Armature-space 4x4 transforms per bone per frame from a clip."""
    n = c['n']
    G = {}
    if with_root:
        L, Q = root_basis(rig, c['root'])
        Mb = np.tile(np.eye(4), (n, 1, 1)); Mb[:, :3, :3] = RT.quat_to_mat(Q); Mb[:, :3, 3] = L
        G['Root'] = rig.rest['Root'][None] @ Mb
    else:
        G['Root'] = np.tile(rig.rest['Root'], (n, 1, 1))
    for b in rig.names:
        if b == 'Root': continue
        p = rig.parent[b]
        rest_rel = np.linalg.inv(rig.rest[p]) @ rig.rest[b]
        Mb = np.tile(np.eye(4), (n, 1, 1))
        Mb[:, :3, :3] = RT.quat_to_mat(c['q'][b])
        if b == 'Hips': Mb[:, :3, 3] = c['hips']
        G[b] = G[p] @ rest_rel[None] @ Mb
    return G

def set_global_rot(rig, c, G, bone, Rg):
    """Set a bone's armature-space rotation (F,3,3) given its parent's current globals G."""
    p = rig.parent[bone]
    rest_rel = np.linalg.inv(rig.rest[p]) @ rig.rest[bone]
    Rp = G[p][:, :3, :3]
    local = np.transpose(rest_rel[:3, :3])[None] @ np.transpose(Rp, (0, 2, 1)) @ Rg
    c['q'][bone] = qnorm(RT.mat_to_quat(local))
    Mb = np.tile(np.eye(4), (c['n'], 1, 1)); Mb[:, :3, :3] = local
    if bone == 'Hips': Mb[:, :3, 3] = c['hips']
    G[bone] = G[p] @ rest_rel[None] @ Mb

def _aim(rest_R, d_new, pole_new):
    """Rotation matrix for a bone whose rest frame is rest_R (y = bone axis): y -> d_new, with the
    bone's z axis turned toward pole_new (projected)."""
    y = d_new / np.linalg.norm(d_new, axis=-1, keepdims=True)
    z = pole_new - (pole_new * y).sum(-1, keepdims=True) * y
    z = z / np.linalg.norm(z, axis=-1, keepdims=True)
    x = np.cross(y, z)
    return np.stack([x, y, z], -1)

def leg_ik(rig, c, side, ankle_target, foot_yaw=None, knee_dir=None, foot_pitch=None):
    """Two-bone IK: place the ankle (LowerLeg tail / Foot head) at ankle_target (F,3) in armature
    space (no root motion), knee bending toward knee_dir (F,3) (default forward+out), foot kept flat
    with yaw foot_yaw (F,) radians (default: rest)."""
    n = c['n']
    G = fk(rig, c)
    ul, ll, ft = side + 'UpperLeg', side + 'LowerLeg', side + 'Foot'
    L1 = rig.length[ul]; L2 = rig.length[ll]
    H = G[ul][:, :3, 3]
    T = np.asarray(ankle_target, float).reshape(n, 3)
    D = T - H; d = np.linalg.norm(D, axis=1)
    d = np.clip(d, 1e-4, (L1 + L2) * 0.9995)
    Dn = D / np.linalg.norm(D, axis=1, keepdims=True)
    sg = 1 if side == 'Left' else -1
    if knee_dir is None: knee_dir = np.tile([0.12 * sg, -1.0, 0.0], (n, 1))
    kd = np.asarray(knee_dir, float).reshape(n, 3)
    # knee position: along the plane (Dn, kd_perp)
    kp = kd - (kd * Dn).sum(1, keepdims=True) * Dn; kp /= np.linalg.norm(kp, axis=1, keepdims=True)
    a = (L1 * L1 - L2 * L2 + d * d) / (2 * d)
    h = np.sqrt(np.clip(L1 * L1 - a * a, 0, None))
    K = H + Dn * a[:, None] + kp * h[:, None]
    # the bones' rest z axes point forward (align_roll(-Y)); use the knee plane normal for twist
    R_ul = _aim(rig.rest[ul][:3, :3], K - H, kp)
    set_global_rot(rig, c, G, ul, R_ul @ _rest_fix(rig, ul))
    R_ll = _aim(rig.rest[ll][:3, :3], T - K, kp)
    set_global_rot(rig, c, G, ll, R_ll @ _rest_fix(rig, ll))
    # foot: rest orientation rotated by yaw (and optional pitch) in world
    R0 = rig.rest[ft][:3, :3]
    yaw = np.zeros(n) if foot_yaw is None else np.asarray(foot_yaw, float)
    pit = np.zeros(n) if foot_pitch is None else np.asarray(foot_pitch, float)
    Rf = np.array([RT.quat_to_mat(qaxis((0, 0, 1), yaw[i])) @ RT.quat_to_mat(qaxis((1, 0, 0), pit[i])) @ R0 for i in range(n)])
    set_global_rot(rig, c, G, ft, Rf)
    return c

_FIX = {}
def _rest_fix(rig, bone):
    """Correction so that _aim(rest) reproduces the bone's rest rotation exactly."""
    if bone not in _FIX:
        R0 = rig.rest[bone][:3, :3]
        A = _aim(R0, R0[:, 1][None], R0[:, 2][None])[0]
        _FIX[bone] = A.T @ R0
    return _FIX[bone]

def rest_ankle(rig, side):
    return rig.rest[side + 'Foot'][:3, 3].copy()

def world_ankles(rig, c, side):
    return fk(rig, c)[side + 'Foot'][:, :3, 3]

def _frame(y, a):
    """Orthonormal frame with columns (y, a', y x a') from a primary y and secondary a."""
    y = y / np.linalg.norm(y, axis=-1, keepdims=True)
    a = a - (a * y).sum(-1, keepdims=True) * y; a = a / np.linalg.norm(a, axis=-1, keepdims=True)
    return np.stack([y, a, np.cross(y, a)], -1)

HAND_REST = {}
def hand_rest_frame(rig, side):
    """Rest (fingers y, across a = little->index, palm p) of a hand, in armature space."""
    if side not in HAND_REST:
        R0 = rig.rest[side + 'Hand']
        y = R0[:3, 1]
        a = rig.rest[side + 'IndexProximal'][:3, 3] - rig.rest[side + 'LittleProximal'][:3, 3]
        F = _frame(y[None], a[None])[0]
        sg = -1 if side == 'Right' else 1
        p = F[:, 2] if np.dot(F[:, 2], [-sg, 0, 0]) > 0 else -F[:, 2]     # palm faces the thigh at rest
        HAND_REST[side] = (F[:, 0], F[:, 1], p)
    return HAND_REST[side]

def arm_ik(rig, c, side, wrist_target, across=None, palm=None, pole=None):
    """Two-bone arm IK: wrist (Hand head) to wrist_target (F,3) in root space; elbow toward pole (F,3)
    (default: down/back/out); hand oriented so its 'across' axis (little->index knuckles, = sword blade
    in a fist) and palm normal match the given world directions (F,3) if provided."""
    n = c['n']
    G = fk(rig, c)
    ua, la, hd = side + 'UpperArm', side + 'LowerArm', side + 'Hand'
    L1 = rig.length[ua]; L2 = rig.length[la]
    S = G[ua][:, :3, 3]
    T = np.asarray(wrist_target, float).reshape(n, 3)
    D = T - S; d = np.clip(np.linalg.norm(D, axis=1), 1e-4, (L1 + L2) * 0.999)
    Dn = D / np.linalg.norm(D, axis=1, keepdims=True)
    sg = 1 if side == 'Left' else -1
    if pole is None: pole = np.tile([0.5 * sg, 0.45, -0.6], (n, 1))
    pd = np.asarray(pole, float).reshape(n, 3)
    kp = pd - (pd * Dn).sum(1, keepdims=True) * Dn; kp /= np.linalg.norm(kp, axis=1, keepdims=True)
    a = (L1 * L1 - L2 * L2 + d * d) / (2 * d); h = np.sqrt(np.clip(L1 * L1 - a * a, 0, None))
    E = S + Dn * a[:, None] + kp * h[:, None]
    # keep the upper-arm twist continuous: bone z toward the elbow bend plane normal
    nrm = np.cross(E - S, T - E); nrm /= np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-9)
    R_ua = _aim(None, E - S, np.cross(nrm, E - S))
    set_global_rot(rig, c, G, ua, R_ua @ _rest_fix_arm(rig, ua))
    R_la = _aim(None, T - E, np.cross(nrm, T - E))
    set_global_rot(rig, c, G, la, R_la @ _rest_fix_arm(rig, la))
    if across is not None and palm is not None:
        y0, a0, p0 = hand_rest_frame(rig, side)
        F0 = np.stack([np.cross(a0, p0), a0, p0], -1)            # (y', a, p) orthonormal rest frame
        ac = np.asarray(across, float).reshape(n, 3); pc = np.asarray(palm, float).reshape(n, 3)
        ac = ac / np.linalg.norm(ac, axis=1, keepdims=True)
        pc = pc - (pc * ac).sum(1, keepdims=True) * ac; pc /= np.linalg.norm(pc, axis=1, keepdims=True)
        F1 = np.stack([np.cross(ac, pc), ac, pc], -1)
        Rh = F1 @ np.transpose(F0)[None] @ rig.rest[hd][:3, :3][None]
        set_global_rot(rig, c, G, hd, Rh)
    return c

_FIXA = {}
def _rest_fix_arm(rig, bone):
    """Correction so the elbow-plane aim reproduces the rest pose for a straight-ish rest arm."""
    if bone not in _FIXA:
        side = 'Left' if bone.startswith('Left') else 'Right'
        S = rig.rest[side + 'UpperArm'][:3, 3]; E = rig.rest[side + 'LowerArm'][:3, 3]; T = rig.rest[side + 'Hand'][:3, 3]
        nrm = np.cross(E - S, T - E)
        if np.linalg.norm(nrm) < 1e-6: nrm = np.array([1.0, 0, 0])
        nrm = nrm / np.linalg.norm(nrm)
        seg = (E - S) if bone.endswith('UpperArm') else (T - E)
        A_ = _aim(None, seg[None], np.cross(nrm, seg)[None])[0]
        _FIXA[bone] = A_.T @ rig.rest[bone][:3, :3]
    return _FIXA[bone]

def rest_wrist(rig, side):
    return rig.rest[side + 'Hand'][:3, 3].copy()

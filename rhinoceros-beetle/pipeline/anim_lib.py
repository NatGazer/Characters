"""Procedural animation toolkit for the giant rhinoceros beetle rig.

All clip functions return, for a time t (seconds), a Pose: a dict of channels.
bake() converts poses to Blender keyframes on the BeetleRig armature.

Conventions (armature / world space, meters):
  forward = -Y, left = +X, up = +Z.
  pitch  + = nose up, yaw + = turn left, roll + = left side down.
"""
import bpy, math, json, random
from mathutils import Matrix, Vector, Quaternion, Euler

SCR = './work/'
FPS = 60
SIDES = ('L', 'R')
SG = {'L': -1.0, 'R': 1.0}          # mirror sign used for local-axis channels
LEGS = ('front', 'mid', 'hind')

ao = bpy.data.objects['BeetleRig']
arm = ao.data
PB = ao.pose.bones
REST = {b.name: b.matrix_local.copy() for b in arm.bones}
HEAD = {b.name: b.head_local.copy() for b in arm.bones}
WINGFOLD = json.load(open(SCR + 'wingfold.json'))
ELY_OPEN = {'R': 104.8, 'L': -100.1}

# ------------------------------------------------------------------ math helpers
def rad(d): return math.radians(d)
def clamp(x, a=0.0, b=1.0): return a if x < a else (b if x > b else x)
def lerp(a, b, t): return a + (b - a) * t
def smooth(t): t = clamp(t); return t * t * (3 - 2 * t)
def smoother(t): t = clamp(t); return t * t * t * (t * (t * 6 - 15) + 10)
def ease_out(t, p=3): t = clamp(t); return 1 - (1 - t) ** p
def ease_in(t, p=3): t = clamp(t); return t ** p
def ease_out_back(t, s=1.9):
    t = clamp(t); t -= 1; return t * t * ((s + 1) * t + s) + 1
def snap(t, s=2.4):
    """fast insect-like move with slight overshoot and settle"""
    return ease_out_back(t, s)
def window(t, a, b):
    """0 before a, ramps to 1 at b (smooth)"""
    return smooth((t - a) / (b - a)) if b != a else float(t >= a)
def pulse(t, a, b, c, d):
    """0 -> 1 between a,b ; hold ; 1 -> 0 between c,d"""
    return window(t, a, b) * (1 - window(t, c, d))
def damped(t, t0, freq, decay, amp=1.0):
    """damped oscillation starting at t0"""
    if t < t0: return 0.0
    x = t - t0
    return amp * math.exp(-decay * x) * math.sin(2 * math.pi * freq * x)

_rng_cache = {}
def lnoise(t, period, seed, kmax=5, falloff=1.2):
    """Loopable smooth noise in [-1,1]-ish with the given period."""
    key = (seed, kmax, falloff)
    if key not in _rng_cache:
        r = random.Random(seed)
        _rng_cache[key] = [(1.0 / (k ** falloff), r.uniform(0, 2 * math.pi)) for k in range(1, kmax + 1)]
    terms = _rng_cache[key]
    norm = sum(a for a, _ in terms)
    return sum(a * math.sin(2 * math.pi * (k + 1) * t / period + p) for k, (a, p) in enumerate(terms)) / norm * 1.6

def osc(t, period, k=1, phase=0.0):
    return math.sin(2 * math.pi * k * t / period + phase)

def keys(t, kf):
    """Piecewise interpolation. kf = [(time, value, ease_fn_into_this_key), ...]
    value may be float or tuple."""
    if t <= kf[0][0]: return kf[0][1]
    for i in range(1, len(kf)):
        t1 = kf[i][0]
        if t <= t1:
            t0, v0 = kf[i - 1][0], kf[i - 1][1]
            v1 = kf[i][1]; e = kf[i][2] if len(kf[i]) > 2 and kf[i][2] else smooth
            u = e((t - t0) / (t1 - t0)) if t1 > t0 else 1.0
            if isinstance(v0, (tuple, list)):
                return tuple(a + (b - a) * u for a, b in zip(v0, v1))
            return v0 + (v1 - v0) * u
    return kf[-1][1]

def vadd(*vs): return tuple(sum(c) for c in zip(*vs))
def vscale(v, s): return tuple(c * s for c in v)

def rot_pyr(p=0.0, y=0.0, r=0.0):
    return (Matrix.Rotation(rad(y), 4, 'Z') @ Matrix.Rotation(rad(-p), 4, 'X') @ Matrix.Rotation(rad(r), 4, 'Y'))

def about(point, M):
    return Matrix.Translation(point) @ M @ Matrix.Translation(-point)

def basis(bone, M):
    R = REST[bone]
    return R.inverted() @ M @ R

def local_rot(rx=0.0, ry=0.0, rz=0.0):
    return Euler((rad(rx), rad(ry), rad(rz)), 'XYZ').to_matrix().to_4x4()

# ------------------------------------------------------------------ stance / feet
REST_FOOT = {(l, s): HEAD[f'foot_ik.{l}.{s}'].copy() for l in LEGS for s in SIDES}
REST_ANKLE = {(l, s): HEAD[f'ankle_tgt.{l}.{s}'].copy() for l in LEGS for s in SIDES}
STANCE = {}
for l, (ax, ay, az) in {'front': (1.21, -1.60, 0.155), 'mid': (1.30, 0.62, 0.22), 'hind': (0.80, 1.90, 0.22)}.items():
    STANCE[(l, 'L')] = Vector((ax, ay, az))
    STANCE[(l, 'R')] = Vector((-ax, ay, az))

def peel_matrix(leg, side, angle):
    """rotation (about the claw joint) that lifts the ankle by `angle` degrees"""
    v = REST_ANKLE[(leg, side)] - REST_FOOT[(leg, side)]
    v.z = 0
    if v.length < 1e-6 or abs(angle) < 1e-6: return Matrix.Identity(4)
    k = Vector((0, 0, 1)).cross(v.normalized())
    return Matrix.Rotation(rad(-angle), 4, k)

# ------------------------------------------------------------------ pose container
def neutral():
    P = {
        'body_t': (0.0, 0.0, 0.0), 'body_r': (0.0, 0.0, 0.0),
        'pron_r': (0.0, 0.0, 0.0), 'head_r': (0.0, 0.0, 0.0), 'abd_r': (0.0, 0.0, 0.0),
        'feet_mode': 'world',
    }
    for s in SIDES:
        P['ant_' + s] = (0.0, 0.0, 0.0)       # local: up, forward sweep, twist
        P['club_' + s] = (0.0, 0.0, 0.0)
        P['ely_' + s] = 0.0                   # open fraction
        P['elyj_' + s] = (0.0, 0.0, 0.0)      # local jitter (deg)
        P['wfold_' + s] = (0.0, 0.0, 0.0)     # unfold stage root, mid, tip (0 folded .. 1 spread)
        P['flap_' + s] = (0.0, 0.0, 0.0)      # elevation, sweep(fwd), pitch(leading edge up)
        P['wbend_' + s] = (0.0, 0.0)          # mid, tip bend (deg, + = up)
        for l in LEGS:
            P[f'foot_{l}_{s}'] = STANCE[(l, s)].copy()
            P[f'peel_{l}_{s}'] = 0.0
    return P

# ------------------------------------------------------------------ pose -> bone basis matrices
def body_chain(P):
    """world delta matrices for body, pronotum, head (applied to rest)"""
    Mb = Matrix.Translation(Vector(P['body_t'])) @ about(HEAD['body'], rot_pyr(*P['body_r']))
    Mp = about(HEAD['pronotum'], rot_pyr(*P['pron_r']))
    Mh = about(HEAD['head'], rot_pyr(*P['head_r']))
    return Mb, Mp, Mh

def wing_basis(side, P):
    sg = SG[side]
    st = P['wfold_' + side]
    out = {}
    names = (f'wing.{side}', f'wing_mid.{side}', f'wing_tip.{side}')
    for i, bn in enumerate(names):
        f = WINGFOLD[side][bn]
        u = clamp(st[i])
        loc = Vector(f['loc']).lerp(Vector((0, 0, 0)), u)
        q = Quaternion(f['rot']).slerp(Quaternion((1, 0, 0, 0)), u)
        sc = Vector(f['scale']).lerp(Vector((1, 1, 1)), u)
        M = Matrix.Translation(loc) @ q.to_matrix().to_4x4() @ Matrix.Diagonal((*sc, 1))
        out[bn] = M
    g = smooth(clamp(st[0]))                    # flapping only once the wing is out
    el, sw, pi = (c * g for c in P['flap_' + side])
    el += P.get('wlift_' + side, 0.0)
    out[names[0]] = out[names[0]] @ local_rot(el, sg * pi, sg * sw)
    bm, bt = (c * g for c in P['wbend_' + side])
    out[names[1]] = out[names[1]] @ local_rot(bm, 0, 0)
    out[names[2]] = out[names[2]] @ local_rot(bt, 0, 0)
    return out

def pose_to_basis(P):
    B = {}
    Mb, Mp, Mh = body_chain(P)
    B['body'] = basis('body', Mb)
    B['pronotum'] = basis('pronotum', Mp)
    B['head'] = basis('head', Mh)
    B['abdomen'] = basis('abdomen', about(HEAD['abdomen'], rot_pyr(*P['abd_r'])))
    for s in SIDES:
        sg = SG[s]
        up, fw, tw = P['ant_' + s]
        B[f'antenna.{s}'] = local_rot(up, tw, sg * fw)
        up, fw, tw = P['club_' + s]
        B[f'antenna_club.{s}'] = local_rot(up, tw, sg * fw)
        jx, jy, jz = P['elyj_' + s]
        B[f'elytron.{s}'] = local_rot(jx, ELY_OPEN[s] * P['ely_' + s] + jy, jz)
        B.update(wing_basis(s, P))
        for l in LEGS:
            name = f'foot_ik.{l}.{s}'
            pos = Vector(P[f'foot_{l}_{s}'])
            if P['feet_mode'] == 'body':
                # foot position given in the rest frame; carried by body (and pronotum for front legs)
                M = Mb @ (Mp if l == 'front' else Matrix.Identity(4))
                wb = P.get('feet_body_w', 1.0)
                pos = pos.lerp(M @ pos, wb)
                R = Quaternion((1, 0, 0, 0)).slerp(M.to_quaternion(), wb).to_matrix().to_4x4()
            else:
                R = Matrix.Identity(4)
            pos = Vector((pos.x, pos.y, max(pos.z, REST_FOOT[(l, s)].z - 0.02)))   # never below the ground
            Mf = Matrix.Translation(pos) @ R @ peel_matrix(l, s, P[f'peel_{l}_{s}']) @ Matrix.Translation(-REST_FOOT[(l, s)])
            B[name] = basis(name, Mf)
    return B

# ------------------------------------------------------------------ baking
ANIM_BONES = None
def bake(name, fn, duration, loop=True, fps=FPS):
    """Sample fn(t)->Pose and write an Action named `name`."""
    nframes = int(round(duration * fps)) + (1 if not loop else 1)
    if ao.animation_data is None: ao.animation_data_create()
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    ao.animation_data.action = act
    prevq = {}
    for i in range(nframes):
        t = i / fps
        if loop: t = t % duration if i < nframes - 1 else duration  # last frame == first (seamless)
        P = fn(t)
        B = pose_to_basis(P)
        fr = i + 1
        for bn, M in B.items():
            pb = PB[bn]
            loc, q, sc = M.decompose()
            if bn in prevq and prevq[bn].dot(q) < 0: q = -q
            prevq[bn] = q
            pb.location = loc; pb.rotation_quaternion = q; pb.scale = sc
            pb.keyframe_insert('location', frame=fr, group=bn)
            pb.keyframe_insert('rotation_quaternion', frame=fr, group=bn)
            pb.keyframe_insert('scale', frame=fr, group=bn)
    act.frame_range = (1, nframes)
    try:
        act.use_frame_range = True
    except Exception:
        pass
    # linear interpolation (we key every frame)
    try:
        for fc in iter_fcurves(act):
            for kp in fc.keyframe_points: kp.interpolation = 'LINEAR'
    except Exception as e:
        print('interp warn', e)
    # stash in NLA so it is kept / exported
    tr = ao.animation_data.nla_tracks.new(); tr.name = name
    st = tr.strips.new(name, 1, act); tr.mute = True
    ao.animation_data.action = None
    return act

def iter_fcurves(act):
    if hasattr(act, 'fcurves') and len(getattr(act, 'fcurves', [])):
        yield from act.fcurves; return
    for layer in act.layers:
        for strip in layer.strips:
            for cb in strip.channelbags:
                yield from cb.fcurves

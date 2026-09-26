"""Clip definitions for the giant rhinoceros beetle."""
import math
from mathutils import Vector
from anim_lib import *

# ================================================================== shared layers
def antenna_life(P, t, T, intensity=1.0, base=(0, 0, 0), seed=0, twitch_times=()):
    """exploring antennae: slow sweeps + quick insect twitches; clubs fan open/closed"""
    for s in SIDES:
        sd = seed + (0 if s == 'L' else 17)
        up = base[0] + intensity * (9 * lnoise(t, T, sd + 1, 4) )
        fw = base[1] + intensity * (12 * lnoise(t, T, sd + 2, 4))
        tw = base[2] + intensity * 6 * lnoise(t, T, sd + 3, 3)
        for (tt, amp) in twitch_times:
            up += amp * damped(t, tt + (0.05 if s == 'R' else 0), 5.5, 7.0)
            fw += 0.6 * amp * damped(t, tt + 0.03, 4.0, 6.0)
        P['ant_' + s] = (up, fw, tw)
        P['club_' + s] = (intensity * 10 * lnoise(t, T, sd + 4, 3), intensity * 14 * lnoise(t, T, sd + 5, 3), 0)

def gait(P, t, T, phases, duty, stride, lift, peel=26, out=0.05, height_bias=None, stride_scale=None):
    """In-place gait: stance feet slide backwards (+Y), swing feet arc forward."""
    events = []
    for (l, s), ph in phases.items():
        u = ((t / T) - ph) % 1.0
        S = stride * (stride_scale[(l)] if stride_scale else 1.0)
        base = STANCE[(l, s)].copy()
        sw = 1.0 - duty
        if u < sw:                       # swing
            q = u / sw
            y = S / 2 - S * smoother(q)
            z = lift * math.sin(math.pi * clamp(q ** 0.85)) ** 1.1
            x = out * math.sin(math.pi * q) * (1 if s == 'L' else -1)
            pe = peel * math.sin(math.pi * clamp(q * 1.15))
        else:                            # stance
            q = (u - sw) / duty
            y = -S / 2 + S * q
            z = 0.0
            x = 0.0
            pe = 10 * smooth((q - 0.75) / 0.25)   # heel rises at push-off
        if height_bias: z += height_bias
        P[f'foot_{l}_{s}'] = base + Vector((x, y, z))
        P[f'peel_{l}_{s}'] = pe

def stance_offset(P, off):
    """move all planted feet by a world offset (e.g. bracing wider)"""
    for l in LEGS:
        for s in SIDES:
            o = off.get((l, s), off.get(l, (0, 0, 0)))
            if s == 'R' and (l in off): o = (-o[0], o[1], o[2])
            P[f'foot_{l}_{s}'] = P[f'foot_{l}_{s}'] + Vector(o)

def folded_wings(P):
    for s in SIDES: P['wfold_' + s] = (0.0, 0.0, 0.0)

def elytra_shiver(P, t, amp, freq=11.0, seed=3, D=None):
    if D: freq = max(1, round(freq * D)) / D
    for s in SIDES:
        sd = seed + (0 if s == 'L' else 5)
        P['elyj_' + s] = (amp * lnoise(t * freq, 1.0, sd, 3), amp * 0.6 * lnoise(t * freq, 1.0, sd + 1, 3), amp * 0.5 * lnoise(t * freq, 1.0, sd + 2, 3))

# ================================================================== IDLE (loop)
def idle(t):
    T = 8.0
    P = neutral()
    br = osc(t, T, 3)                                          # breathing, 3 per loop
    sway = lnoise(t, T, 11, 2)
    P['body_t'] = (0.025 * lnoise(t, T, 12, 2), 0.02 * lnoise(t, T, 13, 2), 0.012 * br - 0.01)
    P['body_r'] = (0.8 * br + 0.6 * lnoise(t, T, 14, 2), 2.2 * sway, 1.4 * lnoise(t, T, 15, 2))
    P['abd_r'] = (1.6 * osc(t, T, 3, -0.6), 0.8 * lnoise(t, T, 16, 2), 0)
    # head: insect-like look-arounds (quick turn, hold)
    hy = keys(t, [(0, 0), (0.9, 0), (1.15, 10, snap), (2.6, 10), (2.85, -7, snap), (4.3, -7), (4.55, 2, snap),
                  (6.2, 2), (6.5, 0, snap), (8.0, 0)])
    hp = keys(t, [(0, 0), (2.6, 0), (2.85, 5, snap), (4.3, 5), (4.55, -3, snap), (5.7, -3), (6.0, 6, snap), (6.5, 0, snap), (8, 0)])
    P['head_r'] = (hp + 0.6 * br, hy, 0.3 * hy)
    P['pron_r'] = (0.4 * br + 0.2 * hp, 0.35 * hy, 0)
    antenna_life(P, t, T, 1.0, base=(4, 6, 0), seed=21, twitch_times=((1.1, 18), (3.9, -14), (5.9, 22), (7.1, -10)))
    # legs: a mid-leg shuffle and a front-leg tap (life!)
    for (l, s, t0, dy, h) in (('mid', 'L', 3.2, -0.06, 0.14), ('front', 'R', 5.6, 0.0, 0.10), ('hind', 'R', 6.9, 0.04, 0.08)):
        q = (t - t0) / 0.45
        if 0 <= q <= 1:
            P[f'foot_{l}_{s}'] = P[f'foot_{l}_{s}'] + Vector((0, dy * math.sin(math.pi * q), h * math.sin(math.pi * q)))
            P[f'peel_{l}_{s}'] = 22 * math.sin(math.pi * q)
    # elytra settle-flick with shudder at 4.8s
    fl = pulse(t, 4.75, 4.85, 4.95, 5.25)
    for s in SIDES:
        P['ely_' + s] = 0.035 * fl
    elytra_shiver(P, t, 1.2 * math.exp(-max(0, t - 4.95) * 6) * (t > 4.9), 14)
    P['body_r'] = vadd(P['body_r'], (0.6 * damped(t, 4.95, 7, 6), 0, 0.8 * damped(t, 4.95, 9, 6)))
    return P

# ================================================================== WALK (metachronal wave gait, loop)
WAVE = {('hind', 'L'): 0.0, ('mid', 'L'): 0.333, ('front', 'L'): 0.667,
        ('hind', 'R'): 0.5, ('mid', 'R'): 0.833, ('front', 'R'): 0.167}
TRIPOD = {('front', 'L'): 0.0, ('mid', 'R'): 0.0, ('hind', 'L'): 0.0,
          ('front', 'R'): 0.5, ('mid', 'L'): 0.5, ('hind', 'R'): 0.5}

def walk(t):
    T = 1.6
    P = neutral()
    gait(P, t, T, WAVE, duty=0.70, stride=0.85, lift=0.24, peel=28)
    c = 2 * math.pi * t / T
    P['body_t'] = (0.035 * math.sin(c + 0.4), 0.02 * math.sin(2 * c), 0.018 * math.sin(6 * c + 1.0) + 0.012 * math.sin(2 * c))
    P['body_r'] = (-1.5 + 0.9 * math.sin(2 * c + 0.6), 2.6 * math.sin(c), 1.8 * math.sin(c + 0.9))
    P['pron_r'] = (0.6 * math.sin(2 * c + 1.2), -1.3 * math.sin(c - 0.5), -0.6 * math.sin(c + 0.4))
    P['head_r'] = (1.5 * math.sin(2 * c + 1.8) + 1.0, -1.8 * math.sin(c - 1.0), -0.8 * math.sin(c))
    P['abd_r'] = (1.2 * math.sin(2 * c - 0.6), -2.4 * math.sin(c - 1.1), 0.8 * math.sin(c))
    antenna_life(P, t, T, 0.8, base=(6, 14, 0), seed=31)
    for s in SIDES:
        a = P['ant_' + s]; P['ant_' + s] = (a[0] + 3 * math.sin(2 * c + (0 if s == 'L' else 1.5)), a[1], a[2])
    elytra_shiver(P, t, 0.35, 4.5, D=T)
    return P

# ================================================================== RUN (tripod, loop)
def run(t):
    T = 0.72
    P = neutral()
    gait(P, t, T, TRIPOD, duty=0.56, stride=1.02, lift=0.30, peel=34, out=0.08)
    c = 2 * math.pi * t / T
    P['body_t'] = (0.05 * math.sin(c + 0.3), 0.03 * math.sin(2 * c), -0.02 + 0.04 * math.sin(2 * c + 0.9))
    P['body_r'] = (-4.0 + 1.6 * math.sin(2 * c + 1.4), 3.4 * math.sin(c), 3.0 * math.sin(c + 0.8))
    P['pron_r'] = (1.2 * math.sin(2 * c + 2.0), -2.0 * math.sin(c - 0.6), -1.2 * math.sin(c + 0.3))
    P['head_r'] = (-2 + 2.0 * math.sin(2 * c + 2.6), -2.5 * math.sin(c - 1.2), -1.2 * math.sin(c))
    P['abd_r'] = (2.0 * math.sin(2 * c - 0.3), -3.5 * math.sin(c - 1.3), 1.2 * math.sin(c))
    for s in SIDES:
        k = 0 if s == 'L' else 1.3
        P['ant_' + s] = (12 + 5 * math.sin(2 * c + k), 22 + 5 * math.sin(c + k), 0)
        P['club_' + s] = (6 * math.sin(2 * c + k + 1), 8, 0)
    elytra_shiver(P, t, 0.9, 13, D=T)
    return P

# ================================================================== FLEE (panicked tripod run, loop)
def flee(t):
    T = 0.56
    P = neutral()
    gait(P, t, T, TRIPOD, duty=0.5, stride=1.12, lift=0.34, peel=40, out=0.1)
    c = 2 * math.pi * t / T
    L = T * 4  # jitter loop = 4 strides; clip length is 4*T
    jit = lnoise(t, L, 41, 6)
    P['body_t'] = (0.07 * math.sin(c + 0.3) + 0.04 * jit, 0.035 * math.sin(2 * c), -0.07 + 0.045 * math.sin(2 * c + 0.9))
    P['body_r'] = (-7.0 + 2.0 * math.sin(2 * c + 1.4), 4.5 * math.sin(c) + 4.0 * lnoise(t, L, 42, 5), 4.0 * math.sin(c + 0.8) + 2.0 * jit)
    P['pron_r'] = (-3 + 1.6 * math.sin(2 * c + 2.0) + 1.2 * lnoise(t * 3, L, 43, 4), -2.5 * math.sin(c - 0.6), -1.5 * math.sin(c + 0.3))
    P['head_r'] = (-9 + 2.5 * math.sin(2 * c + 2.6), -3 * math.sin(c - 1.2) + 5 * lnoise(t, L, 44, 5), -1.5 * math.sin(c))
    P['abd_r'] = (3.5 * math.sin(4 * c) , -4.5 * math.sin(c - 1.3), 1.6 * math.sin(c))
    for s in SIDES:
        k = 0 if s == 'L' else 1.3
        P['ant_' + s] = (-25 + 6 * math.sin(3 * c + k), -30 + 5 * math.sin(c + k), 0)   # pinned back & down
        P['club_' + s] = (-15, -10, 0)
        P['ely_' + s] = 0.06 + 0.035 * (0.5 + 0.5 * math.sin(8 * c + (0 if s == 'L' else 0.7)))  # panicky flutter
    elytra_shiver(P, t, 2.2, 16, D=L)
    return P

# ================================================================== ATTACK
READY = dict(body_t=(0, -0.10, -0.04), body_r=(-11.0, 0, 0), pron_r=(-3.0, 0, 0), head_r=(-8.0, 0, 0), abd_r=(6.0, 0, 0),
             ely=0.62, wing=(24.0, -30.0, 12.0))   # wings fully out, raised & swept back
BRACE = {'front': (0.14, -0.10, 0), 'mid': (0.18, 0.0, 0), 'hind': (0.12, 0.12, 0)}

def ready_layers(P, t, w=1.0):
    """threat display: forward tilt, elytra up, hindwings half-out & buzzing, horn feints"""
    P['body_t'] = vadd(P['body_t'], vscale(READY['body_t'], w))
    P['body_r'] = vadd(P['body_r'], vscale(READY['body_r'], w))
    P['pron_r'] = vadd(P['pron_r'], vscale(READY['pron_r'], w))
    P['head_r'] = vadd(P['head_r'], vscale(READY['head_r'], w))
    P['abd_r'] = vadd(P['abd_r'], vscale(READY['abd_r'], w))
    for s in SIDES:
        P['ely_' + s] = max(P['ely_' + s], READY['ely'] * w)
        if w > 0 and 'wing_u' not in P: set_unfold(P, s, w)
        # threatening display: wings raised & swept back, buzzing
        bz = 8 * w * math.sin(2 * math.pi * 9.0 * t + (0 if s == 'L' else 0.8))
        wr = READY['wing']
        P['flap_' + s] = vadd(P['flap_' + s], (wr[0] * w + bz, wr[1] * w + 0.4 * bz, wr[2] * w))
        P['wbend_' + s] = (6 * w * math.sin(2 * math.pi * 9.0 * t - 1.0), 5 * w * math.sin(2 * math.pi * 9.0 * t - 1.6))
    stance_offset(P, {k: vscale(v, w) for k, v in BRACE.items()})

def attack_ready(t):
    T = 2.0
    P = neutral()
    ready_layers(P, t, 1.0)
    c = 2 * math.pi * t / T
    # tracking sway and horn feints (quick jabs)
    P['body_r'] = vadd(P['body_r'], (1.2 * math.sin(2 * c), 5.0 * math.sin(c), 1.5 * math.sin(c + 0.5)))
    P['body_t'] = vadd(P['body_t'], (0.06 * math.sin(c + 0.3), 0.04 * math.sin(2 * c + 1), 0.015 * math.sin(4 * c)))
    feint = keys(t, [(0, 0), (0.35, 0), (0.45, -9, snap), (0.62, 5, snap), (0.85, 0), (1.35, 0), (1.43, -7, snap), (1.6, 4, snap), (1.85, 0), (2.0, 0)])
    P['head_r'] = vadd(P['head_r'], (feint + 1.5 * math.sin(3 * c), -3 * math.sin(c + 0.4), 2 * math.sin(c)))
    P['pron_r'] = vadd(P['pron_r'], (0.4 * feint, -2 * math.sin(c + 0.2), 0))
    P['abd_r'] = vadd(P['abd_r'], (3.0 * math.sin(2 * math.pi * 5 * t), 2 * math.sin(c), 0))   # stridulation pumping
    for s in SIDES:
        k = 0 if s == 'L' else 1.1
        P['ant_' + s] = (6 + 5 * math.sin(2 * c + k), 20 + 4 * math.sin(c + k), 0)
        P['club_' + s] = (10, 12 + 6 * math.sin(3 * c + k), 0)
    elytra_shiver(P, t, 1.4, 14, D=T)
    # restless front feet
    for s, ph in (('L', 0.0), ('R', 0.5)):
        q = ((t / T) - ph) % 1.0
        if q < 0.22:
            u = q / 0.22
            P[f'foot_front_{s}'] = P[f'foot_front_{s}'] + Vector((0, -0.05 * math.sin(math.pi * u), 0.12 * math.sin(math.pi * u)))
            P[f'peel_front_{s}'] = 18 * math.sin(math.pi * u)
    return P

def strike_layers(P, t, t0):
    """the strike itself, starting at t0 (from ready pose). ~1.9 s"""
    u = t - t0
    # body: coil back, lunge forward/down, then pry up & back, settle
    by = keys(u, [(0, 0), (0.25, 0.14), (0.45, -0.55, lambda x: ease_out(x, 4)), (0.8, -0.5), (1.05, -0.3), (1.9, 0)])
    bz = keys(u, [(0, 0), (0.25, 0.05), (0.45, -0.12, lambda x: ease_out(x, 4)), (0.75, -0.1), (0.95, 0.16, snap), (1.3, 0.08), (1.9, 0)])
    bp = keys(u, [(0, 0), (0.25, 6), (0.45, -12, lambda x: ease_out(x, 4)), (0.75, -12), (0.95, 9, snap), (1.3, 4), (1.9, 0)])
    hp = keys(u, [(0, 0), (0.25, 12), (0.45, -22, lambda x: ease_out(x, 4)), (0.72, -24), (0.9, 26, snap), (1.2, 18), (1.45, 6), (1.9, 0)])
    pp = keys(u, [(0, 0), (0.25, 4), (0.45, -5), (0.72, -5), (0.9, 10, snap), (1.3, 5), (1.9, 0)])
    hy = keys(u, [(0, 0), (1.2, 0), (1.3, 14, snap), (1.42, -12, snap), (1.55, 8, snap), (1.7, 0, snap), (1.9, 0)])
    P['body_t'] = vadd(P['body_t'], (0, by, bz))
    P['body_r'] = vadd(P['body_r'], (bp + 1.5 * damped(u, 0.45, 9, 7), 0.5 * hy, 0.3 * hy))
    P['head_r'] = vadd(P['head_r'], (hp, hy, 0.4 * hy))
    P['pron_r'] = vadd(P['pron_r'], (pp, 0.4 * hy, 0))
    # elytra flare wider on the lunge, wings blast
    fl = pulse(u, 0.2, 0.35, 1.2, 1.7)
    for s in SIDES:
        P['ely_' + s] = P['ely_' + s] + 0.2 * fl
        e = P['flap_' + s]; P['flap_' + s] = (e[0] + 18 * fl * math.sin(2 * math.pi * 7.5 * u), e[1], e[2])
        P['wbend_' + s] = vadd(P['wbend_' + s], (8 * fl * math.sin(2 * math.pi * 7.5 * u - 1.0), 6 * fl * math.sin(2 * math.pi * 7.5 * u - 1.6)))
    # front legs: push forward with the lunge then drag back
    for s in SIDES:
        for l, k in (('front', 1.0), ('mid', 0.8), ('hind', 0.62)):
            dy = keys(u, [(0, 0), (0.3, 0), (0.45, -0.35 * k, lambda x: ease_out(x, 3)), (1.3, -0.35 * k), (1.9, 0)])
            dz = keys(u, [(0, 0), (0.3, 0), (0.38, 0.18 * k), (0.47, 0), (1.3, 0), (1.55, 0.12 * k), (1.75, 0), (1.9, 0)])
            P[f'foot_{l}_{s}'] = P[f'foot_{l}_{s}'] + Vector((0, dy, dz))
            P[f'peel_{l}_{s}'] += 30 * pulse(u, 0.3, 0.38, 0.42, 0.47) * k
    elytra_shiver(P, t, 1.4 + 3.0 * pulse(u, 0.4, 0.45, 0.6, 1.1), 16)

def attack_strike(t):
    P = neutral(); ready_layers(P, t, 1.0)
    strike_layers(P, t, 0.0)
    P['abd_r'] = vadd(P['abd_r'], (3.0 * math.sin(2 * math.pi * 5 * t), 0, 0))
    for s in SIDES:
        P['ant_' + s] = (6, 20, 0); P['club_' + s] = (10, 12, 0)
        P['ant_' + s] = vadd(P['ant_' + s], (15 * damped(t, 0.45, 5, 6), 10 * damped(t, 0.9, 4, 5), 0))
    return P

def enter_weight(t, a, b): return snap((t - a) / (b - a), 1.6)

def attack(t):
    """complete attack from the idle stance: rear up & flare -> strike -> return to stance. 3.8 s"""
    P = neutral()
    w = keys(t, [(0, 0), (0.15, 0), (0.7, 1.0, lambda x: snap(x, 1.4)), (3.1, 1.0), (3.8, 0.0, smoother)])
    # startle-alert beat before rising
    P['body_t'] = (0, 0.05 * pulse(t, 0, 0.1, 0.2, 0.4), -0.05 * pulse(t, 0, 0.1, 0.2, 0.4))
    P['head_r'] = (-10 * pulse(t, 0, 0.12, 0.25, 0.5), 0, 0)
    # rearing threat (body lifts high before the forward tilt)
    rear = pulse(t, 0.2, 0.55, 0.7, 1.0)
    P['body_r'] = (16 * rear, 0, 0); P['body_t'] = vadd(P['body_t'], (0, 0.1 * rear, 0.22 * rear))
    P['pron_r'] = (8 * rear, 0, 0); P['head_r'] = vadd(P['head_r'], (18 * rear, 0, 0))
    ready_layers(P, t, w)
    # elytra snap open with overshoot
    for s in SIDES:
        P['ely_' + s] = READY['ely'] * keys(t, [(0, 0), (0.25, 0), (0.5, 1.0, lambda x: snap(x, 2.6)), (3.1, 1.0), (3.6, 0, smoother)])
        P['ely_' + s] += 0.06 * damped(t, 0.5, 6, 5)
        P['wing_u'] = 1; set_unfold(P, s, keys(t, [(0, 0), (0.3, 0), (1.0, 1.0, lambda x: x), (3.0, 1.0), (3.75, 0.0, lambda x: x)]))
    if t >= 1.0: strike_layers(P, t, 1.0)
    antenna_life(P, t, 3.8, 0.4, base=(8, 18, 0), seed=51, twitch_times=((0.05, 25), (1.45, 20)))
    elytra_shiver(P, t, 1.0 + 1.5 * w, 15)
    P['abd_r'] = vadd(P['abd_r'], (3.0 * w * math.sin(2 * math.pi * 5 * t), 0, 0))
    return P

def attack_enter(t):
    """idle stance -> ready (0.9 s)"""
    P = neutral()
    w = snap(t / 0.9, 1.5)
    ready_layers(P, t, w)
    for s in SIDES:
        P['ely_' + s] = READY['ely'] * snap(clamp((t - 0.05) / 0.35), 2.6) + 0.05 * damped(t, 0.4, 6, 6)
        P['wing_u'] = 1; set_unfold(P, s, (t - 0.1) / 0.75)
    for s in SIDES: P['ant_' + s] = (6 * w, 20 * w, 0); P['club_' + s] = (10 * w, 12 * w, 0)
    elytra_shiver(P, t, 1.4 * w, 14)
    return P

def attack_exit(t):
    """ready -> idle stance (0.9 s)"""
    P = neutral()
    w = 1 - smoother(t / 0.9)
    ready_layers(P, t, w)
    for s in SIDES:
        P['ely_' + s] = READY['ely'] * (1 - smoother((t - 0.35) / 0.5)) + 0.02 * damped(t, 0.85, 8, 8)
        P['wing_u'] = 1; set_unfold(P, s, 1 - t / 0.75)
        P['ant_' + s] = (6 * w, 20 * w, 0); P['club_' + s] = (10 * w, 12 * w, 0)
    elytra_shiver(P, t, 1.4 * w + 1.2 * damped(t, 0.85, 9, 6), 14)
    return P

# ================================================================== FRIGHTENED
def cower_layers(P, t, w, T=2.0):
    P['body_t'] = vadd(P['body_t'], (0, 0.14 * w, -0.19 * w))
    P['body_r'] = vadd(P['body_r'], (-5 * w, 0, 0))
    P['pron_r'] = vadd(P['pron_r'], (-9 * w, 0, 0))
    P['head_r'] = vadd(P['head_r'], (-22 * w, 0, 0))
    for s in SIDES:
        P['ant_' + s] = vadd(P['ant_' + s], (-42 * w, -38 * w, 0))
        P['club_' + s] = vadd(P['club_' + s], (-20 * w, -10 * w, 0))
    stance_offset(P, {'front': (-0.10 * w, 0.10 * w, 0), 'mid': (-0.12 * w, 0.0, 0), 'hind': (-0.08 * w, -0.08 * w, 0)})
    # trembling (fast, small, rigid) + stridulation squeak (abdomen pumping)
    tr = w * 1.35
    P['body_r'] = vadd(P['body_r'], (tr * 0.9 * lnoise(t * 13, 1, 61, 3), tr * 1.2 * lnoise(t * 11, 1, 62, 3), tr * 1.1 * lnoise(t * 12, 1, 63, 3)))
    P['pron_r'] = vadd(P['pron_r'], (tr * 1.3 * lnoise(t * 14, 1, 64, 3), tr * 1.2 * lnoise(t * 12, 1, 65, 3), 0))
    P['abd_r'] = vadd(P['abd_r'], (w * 4.5 * math.sin(2 * math.pi * 6.5 * t), 0, 0))
    elytra_shiver(P, t, 1.6 * w, 17, D=T)

RETREAT = 0.22

def frightened(t):
    """startle -> trembling retreat -> tense freeze (2.6 s); ends in the scared pose"""
    P = neutral()
    # startle flinch at t=0.05
    fl = keys(t, [(0, 0), (0.05, 0), (0.12, 1.0, lambda x: ease_out(x, 3)), (0.35, 0.7), (0.7, 1.0)])
    w = smooth((t - 0.05) / 0.3)
    P['body_t'] = (0, 0.0, 0.10 * pulse(t, 0.05, 0.1, 0.12, 0.3))   # jump-flinch up
    P['body_r'] = (6 * pulse(t, 0.05, 0.1, 0.15, 0.35), 0, 0)
    cower_layers(P, t, w * fl)
    # back away a little, with glances
    back = keys(t, [(0, 0), (0.4, 0), (1.4, RETREAT, smoother), (2.6, RETREAT)])
    P['body_t'] = vadd(P['body_t'], (0, back, 0))
    hy = keys(t, [(0, 0), (0.85, 0), (1.0, 14, snap), (1.45, 14), (1.63, -11, snap), (2.05, -11), (2.22, 0, snap), (2.6, 0)])
    P['head_r'] = vadd(P['head_r'], (0, hy, 0.3 * hy))
    P['pron_r'] = vadd(P['pron_r'], (0, 0.3 * hy, 0))
    # elytra flare-and-snap at the flinch (defensive)
    for s in SIDES:
        P['ely_' + s] = 0.12 * pulse(t, 0.05, 0.1, 0.16, 0.3) + 0.04 * w
    P['body_r'] = vadd(P['body_r'], (2.5 * damped(t, 0.12, 10, 5), 0, 3 * damped(t, 0.12, 12, 5)))
    # legs step back while retreating (staggered)
    for i, (l, s) in enumerate([('front', 'L'), ('mid', 'R'), ('hind', 'L'), ('front', 'R'), ('mid', 'L'), ('hind', 'R')]):
        t0 = 0.45 + 0.13 * i
        q = (t - t0) / 0.28
        step = RETREAT * smoother(q)
        P[f'foot_{l}_{s}'] = P[f'foot_{l}_{s}'] + Vector((0, step, 0.15 * math.sin(math.pi * clamp(q))))
        P[f'peel_{l}_{s}'] += 25 * math.sin(math.pi * clamp(q))
    # later feet stay at the stepped position; offset body retreat for planted feet
    return P

def scared(t):
    """loop: cowering, trembling, squeaking, quick glances (2.0 s)"""
    T = 2.0
    P = neutral()
    cower_layers(P, t, 1.0, T)
    P['body_t'] = vadd(P['body_t'], (0, 0.0, 0.01 * math.sin(2 * math.pi * 2 * t / T)))
    hy = keys(t, [(0, 0), (0.25, 0), (0.4, 12, snap), (0.85, 12), (1.02, -9, snap), (1.45, -9), (1.6, 0, snap), (2.0, 0)])
    P['head_r'] = vadd(P['head_r'], (0, hy, 0.3 * hy))
    P['pron_r'] = vadd(P['pron_r'], (0, 0.25 * hy, 0))
    P['body_t'] = vadd(P['body_t'], (0, RETREAT, 0))
    for l in LEGS:
        for s in SIDES: P[f'foot_{l}_{s}'] = P[f'foot_{l}_{s}'] + Vector((0, RETREAT, 0))
    for s in SIDES:
        P['ely_' + s] = 0.04 + 0.02 * math.sin(2 * math.pi * 6.5 * t / 1.0 + (0 if s == 'L' else 0.5))
        a = P['ant_' + s]; P['ant_' + s] = (a[0] + 6 * damped(t, 0.38, 6, 6), a[1], a[2])
    return P

# ================================================================== FLIGHT
FLY_H = 1.6          # body height above the clip root while airborne (m)
FLY_PITCH = 34.0     # body pitch in flight (nose up)
BEAT = 4.0           # wing beats per second (giant-scale: slower, heavier strokes)

def dangle_legs(P, t, w=1.0, T=1.0):
    """feet positions in the body frame: legs tucked/dangling during flight (w: 0 stance .. 1 flight)"""
    tuck = {'front': Vector((0.12, -0.36, 0.42)), 'mid': Vector((0.05, -0.10, 0.55)), 'hind': Vector((-0.12, 0.30, 0.50))}
    for l in LEGS:
        for s in SIDES:
            o = tuck[l].copy()
            if s == 'R': o.x = -o.x
            k = (0 if s == 'L' else 1.3) + LEGS.index(l)
            o += Vector((0.03 * math.sin(2 * math.pi * t / T + k), 0.05 * math.sin(2 * math.pi * t / T + k * 0.7), 0.04 * math.sin(2 * math.pi * 2 * t / T + k)))
            P[f'foot_{l}_{s}'] = STANCE[(l, s)] + o * w
            P[f'peel_{l}_{s}'] = 35 * w

def flap_values(ph, amp):
    el = amp * (20 + 54 * math.cos(ph))               # stroke elevation (bind pose droops ~16 deg)
    sw = amp * (20 * math.sin(ph))                    # fore/aft sweep -> figure-of-eight tip path
    pi = amp * (-34 * math.sin(ph))                   # feathering: pronate on downstroke, supinate on upstroke
    bend = (amp * 16 * math.sin(ph - 0.9), amp * 12 * math.sin(ph - 1.5))   # passive flex lag
    return (el, sw, pi), bend

def flap_layers(P, t, amp=1.0, freq=BEAT, phase=0.0):
    ph = 2 * math.pi * freq * t + phase
    for s in SIDES:
        P['flap_' + s], P['wbend_' + s] = flap_values(ph, amp)

def fly(t):
    T = 1.0
    P = neutral()
    P['feet_mode'] = 'body'
    c = 2 * math.pi * t / T
    beat = 2 * math.pi * BEAT * t
    P['body_t'] = (0.08 * math.sin(c), 0.06 * math.sin(c + 0.8), FLY_H + 0.05 * math.cos(beat + 0.6) + 0.06 * math.sin(c))
    P['body_r'] = (FLY_PITCH + 2.0 * math.cos(beat + 1.0) + 1.5 * math.sin(c), 3.0 * math.sin(c + 0.4), 4.0 * math.sin(c))
    P['pron_r'] = (-4 + 1.0 * math.cos(beat + 1.4), 0, 0)
    P['head_r'] = (-10 + 1.2 * math.cos(beat + 1.8), 2.0 * math.sin(c + 1), 0)
    P['abd_r'] = (-6 + 1.5 * math.cos(beat + 2.0), -1.5 * math.sin(c), 0)
    for s in SIDES:
        P['ely_' + s] = 0.93
        P['elyj_' + s] = (0, 2.5 * math.cos(beat + 0.3) * (1 if s == 'L' else -1), 1.5 * math.cos(beat))
        P['wfold_' + s] = (1.0, 1.0, 1.0)
        k = 0 if s == 'L' else 1.0
        P['ant_' + s] = (10 + 3 * math.sin(c + k), 25, 0); P['club_' + s] = (15, 20 + 5 * math.sin(2 * c + k), 0)
    flap_layers(P, t)
    dangle_legs(P, t, 1.0, T)
    return P

def unfold_stage(u):
    """progress u in [0,1] -> staged (root, mid, tip) unfolding + upward arc of the root"""
    r = smoother(u / 0.55); m = smoother((u - 0.2) / 0.6); tp = smoother((u - 0.35) / 0.65)
    return (r, m, tp), 50 * math.sin(math.pi * r) * (1 - 0.4 * r)

def set_unfold(P, s, u):
    P['wfold_' + s], P['wlift_' + s] = unfold_stage(clamp(u))

def unfold_wings(P, t, t0, dur=0.8):
    for s in SIDES:
        d = 0.05 if s == 'R' else 0.0
        set_unfold(P, s, (t - t0 - d) / dur)

def takeoff(t):
    """ground -> airborne (3.4 s). Ends matching fly(0)."""
    P = neutral()
    # 0-0.6 warm-up: pumping abdomen, antennae fan, body rises
    rise = smoother((t - 0.1) / 0.5)
    lift = smoother((t - 2.3) / 1.1)             # leaves the ground
    pitch = keys(t, [(0, 0), (0.6, 5), (1.6, 8), (2.3, 14), (3.4, FLY_PITCH, smoother)])
    P['body_t'] = (0, 0.0, 0.14 * rise + (FLY_H - 0.14) * ease_in(lift, 1.6) + 0.02 * math.sin(2 * math.pi * 3 * t) * (t < 2.3))
    P['body_r'] = (pitch, 0, 0)
    P['abd_r'] = (3.5 * math.sin(2 * math.pi * 3.0 * t) * (1 - lift) - 6 * lift, 0, 0)
    P['pron_r'] = (-4 * lift, 0, 0); P['head_r'] = (-10 * lift, 0, 0)
    # elytra open 0.6-1.0, wings unfold 0.9-1.8, flapping ramps up
    for s in SIDES:
        P['ely_' + s] = 0.93 * snap(clamp((t - 0.6) / 0.4), 1.8)
        k = 0 if s == 'L' else 1.0
        P['ant_' + s] = (10 * rise, 25 * rise, 0); P['club_' + s] = (15 * rise, 20 * rise, 0)
    unfold_wings(P, t, 0.9, 0.9)
    amp = smoother((t - 1.5) / 0.6)
    # frequency ramps 3 -> 5 Hz: integrate phase so the end phase matches fly()
    f0, f1, ta, tb = 3.0, BEAT, 1.5, 2.6
    def phase(tt):
        if tt < ta: return 2 * math.pi * f0 * tt
        if tt < tb:
            x = tt - ta; return 2 * math.pi * (f0 * ta + f0 * x + (f1 - f0) * x * x / (2 * (tb - ta)))
        return 2 * math.pi * (f0 * ta + (f0 + f1) / 2 * (tb - ta) + f1 * (tt - tb))
    end_phase = phase(3.4)
    ph = phase(t) - end_phase           # so that at t=3.4 phase == 0 == fly(0)
    ph_fly = 2 * math.pi * BEAT * 0
    for s in SIDES:
        P['flap_' + s], P['wbend_' + s] = flap_values(ph, amp)
        P['elyj_' + s] = (0, amp * 2.5 * math.cos(ph + 0.3) * (1 if s == 'L' else -1), amp * 1.5 * math.cos(ph))
    # legs: push off then tuck
    if t > 2.3:
        P['feet_mode'] = 'body'; P['feet_body_w'] = smoother((t - 2.3) / 0.6)
        dangle_legs(P, 0.0, smoother((t - 2.4) / 1.0), 1.0)
    else:
        for l in LEGS:
            for s in SIDES:
                P[f'peel_{l}_{s}'] = 20 * smooth((t - 1.8) / 0.5)
    return P

def land(t):
    """airborne -> touchdown -> fold wings & close elytra (3.2 s). Starts matching fly(0)."""
    P = neutral()
    touch = 1.35
    desc = smoother(t / touch)
    P['body_t'] = (0, 0, FLY_H * (1 - desc) + (-0.12 * pulse(t, touch, touch + 0.12, touch + 0.2, touch + 0.6) + 0.05 * damped(t, touch + 0.12, 3, 4)))
    pitch = keys(t, [(0, FLY_PITCH), (touch, 8, smoother), (touch + 0.5, 0, smoother), (3.2, 0)])
    P['body_r'] = (pitch + 3 * damped(t, touch, 5, 5), 0, 0)
    P['pron_r'] = (-4 * (1 - desc), 0, 0); P['head_r'] = (-10 * (1 - desc) - 6 * pulse(t, touch, touch + 0.1, touch + 0.2, touch + 0.6), 0, 0)
    P['abd_r'] = (-6 * (1 - desc), 0, 0)
    # flapping continues (braking) until touchdown, then decays
    amp = 1 - smoother((t - touch + 0.1) / 0.45)
    ph = 2 * math.pi * BEAT * t
    for s in SIDES:
        P['flap_' + s], P['wbend_' + s] = flap_values(ph, amp)
        # fold wings 1.6-2.4 (tip first), close elytra 2.4-2.8 with a snap and settle-shake
        d = 0.06 if s == 'R' else 0
        set_unfold(P, s, 1 - (t - 1.55 - d) / 0.85)
        P['ely_' + s] = 0.93 * (1 - smoother((t - 2.35) / 0.35)) + 0.015 * damped(t, 2.7, 8, 7)
        P['elyj_' + s] = (0, amp * 2.5 * math.cos(ph + 0.3) * (1 if s == 'L' else -1), amp * 1.5 * math.cos(ph))
        P['ant_' + s] = (10 * (1 - smooth((t - 2.0) / 1.0)), 25 * (1 - smooth((t - 2.0) / 1.0)), 0)
        P['club_' + s] = (15 * (1 - smooth((t - 2.0) / 1.0)), 20 * (1 - smooth((t - 2.0) / 1.0)), 0)
    # settle wiggle after closing (tucking the wings in)
    P['body_r'] = vadd(P['body_r'], (0, 2.5 * damped(t, 2.75, 3.5, 3.5), 2.0 * damped(t, 2.75, 4, 3.5)))
    P['abd_r'] = vadd(P['abd_r'], (4 * damped(t, 2.1, 3, 2.5), 3 * damped(t, 2.75, 4, 3.5), 0))
    # legs reach down before touchdown, then plant
    w = 1 - smoother((t - 0.5) / (touch - 0.5))
    if w > 0:
        P['feet_mode'] = 'body'; P['feet_body_w'] = smoother((touch - t) / 0.5)
        dangle_legs(P, 0.0, w, 1.0)
    return P

CLIPS = [
    # name, fn, duration, loop
    ('idle', idle, 8.0, True),
    ('walk', walk, 1.6, True),
    ('run', run, 0.72, True),
    ('attack', attack, 3.8, False),
    ('attack_enter', attack_enter, 0.9, False),
    ('attack_ready', attack_ready, 2.0, True),
    ('attack_strike', attack_strike, 1.9, False),
    ('attack_exit', attack_exit, 0.9, False),
    ('frightened', frightened, 2.6, False),
    ('scared_loop', scared, 2.0, True),
    ('flee', flee, 2.24, True),
    ('takeoff', takeoff, 3.4, False),
    ('fly', fly, 1.0, True),
    ('land', land, 3.2, False),
]

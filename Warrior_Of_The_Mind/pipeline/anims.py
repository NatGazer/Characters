"""All animation clips of the Warrior of the Mind (30 fps). Runs under bpy.

Mocap (CMU) is used for locomotion and acrobatics, retargeted with rest-pose correction, cleaned
(loops cut at the best pose match and cross-faded, root motion extracted and smoothed) and given a
heroic posture layer + finger poses. Combat, casting, stances and reactions are key-framed with the
authoring DSL (IK-planted feet, overlap springs, anticipation / follow-through timing).

usage: python anims.py [clip names...]   (default: all) -> work/model_anim.blend, work/clips.json
"""
import sys, os, json, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, bpy
import retarget as RT, animlib as A, authoring as AU
from authoring import mirror, both, merge

HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, 'work')
FPS = A.FPS
CLIPS = {}      # name -> (builder, meta)

def clip(name, loop=False, **meta):
    def deco(fn):
        CLIPS[name] = (fn, dict(loop=loop, **meta)); return fn
    return deco

# ----------------------------------------------------------------------------- shared posture
HERO = {'UpperChest': (-3, 0, 0), 'Chest': (-2, 0, 0), 'Neck': (-2, 0, 0), 'Head': (-1, 0, 0),
        'LeftShoulder': (0, 0, -2), 'RightShoulder': (0, 0, 2)}

def posture(rig, c, pose, w=1.0):
    """Add a static world-axis pose on top of a clip."""
    for b, (rx, ry, rz) in pose.items():
        R = A.euler_world((rx * w, ry * w, rz * w))
        q = RT.mat_to_quat(A.world_to_local_rot(rig, b, R)[None])[0]
        c['q'][b] = A.qnorm(A.qmul(c['q'][b], np.tile(q, (c['n'], 1))))
    return c

def fingers(rig, c, left, right):
    return A.apply_fingers(rig, c, left, right)

def mocap_loop(rig, src, window, cycle, fingers_lr=('relaxed', 'relaxed'), post=HERO, search=(0.1, 0.8)):
    fps_src = __import__('mocap').clip_fps(src)
    c = A.from_mocap(rig, src, frames=(int(window[0] * fps_src), int(window[1] * fps_src)))
    best = A.find_loop(rig, c, int(cycle[0] * FPS), int(cycle[1] * FPS), search)
    e, a, b = best
    c = A.make_loop(rig, c, a, b)
    c = posture(rig, c, post)
    c = fingers(rig, c, *fingers_lr)
    c['loop_err'] = float(e)
    return c

def mocap_once(rig, src, window, fingers_lr=('relaxed', 'relaxed'), post=HERO, root=True):
    fps_src = __import__('mocap').clip_fps(src)
    c = A.from_mocap(rig, src, frames=(int(window[0] * fps_src), int(window[1] * fps_src)), root_motion=root)
    c = posture(rig, c, post)
    return fingers(rig, c, *fingers_lr)

# ----------------------------------------------------------------------------- locomotion (mocap)
@clip('walk', loop=True)
def walk(rig): return mocap_loop(rig, '16_15', (0.3, 3.9), (0.9, 1.4))

@clip('run', loop=True)
def run(rig): return mocap_loop(rig, '127_06', (0.2, 1.5), (0.55, 0.85), ('relaxed', 'relaxed'), merge(HERO, {'UpperChest': (4, 0, 0)}))

def resample(c, factor):
    """Time-scale a looping clip by `factor` (>1 = faster) with quaternion slerp."""
    n = c['n']; m = max(4, int(round(n / factor)))
    t = np.arange(m) * n / m; i0 = np.floor(t).astype(int); i1 = (i0 + 1) % n; w = t - i0
    out = dict(c); out['q'] = {b: A.qnorm(RT.slerp(q[i0], q[i1], w)) for b, q in c['q'].items()}
    out['hips'] = c['hips'][i0] * (1 - w[:, None]) + c['hips'][i1] * w[:, None]
    out['root'] = np.zeros((m, 4)); out['n'] = m; out['speed'] = c.get('speed', 0) * factor
    return out

@clip('sprint', loop=True)
def sprint(rig):
    """Run capture at a higher cadence with a deeper forward lean, driving arms and open blade hands."""
    c = mocap_loop(rig, '127_06', (0.2, 1.5), (0.55, 0.85), ('open', 'open'),
                   merge(HERO, {'Spine': (5, 0, 0), 'UpperChest': (6, 0, 0), 'Head': (-6, 0, 0)}))
    c = resample(c, 1.22)
    c['speed'] *= 1.12      # longer stride from the deeper lean (documented speed for the controller)
    return c

@clip('jog', loop=True)
def jog(rig): return mocap_loop(rig, '16_35', (0.2, 1.4), (0.6, 0.9))

@clip('run_stop')
def run_stop(rig): return mocap_once(rig, '127_19', (0.55, 2.2))

@clip('run_start')
def run_start(rig): return mocap_once(rig, '127_19', (2.6, 3.7))

@clip('run_turn_left')
def run_turn_left(rig): return mocap_once(rig, '127_15', (0.1, 1.4))

@clip('run_turn_right')
def run_turn_right(rig): return mocap_once(rig, '127_16', (0.1, 1.6))

@clip('sidestep_left')
def sidestep_left(rig): return mocap_once(rig, '127_13', (0.1, 1.6))

@clip('sidestep_right')
def sidestep_right(rig): return mocap_once(rig, '127_14', (0.1, 1.3))

@clip('dive_roll')
def dive_roll(rig): return mocap_once(rig, '127_23', (0.25, 2.45), ('fist', 'fist'))

@clip('jump')
def jump(rig): return mocap_once(rig, '16_01', (0.45, 2.05), ('relaxed', 'relaxed'))

@clip('jump_forward')
def jump_forward(rig): return mocap_once(rig, '16_05', (0.55, 2.1), ('open', 'open'))

@clip('run_jump')
def run_jump(rig): return mocap_once(rig, '127_25', (0.2, 1.55), ('open', 'open'))

@clip('climb_ladder')
def climb_ladder(rig): return mocap_once(rig, '13_33', (1.7, 6.3), ('grip', 'grip'), post={})

@clip('climb', loop=True)
def climb(rig):
    c = A.from_mocap(rig, '13_33', frames=(int(2.3 * 120), int(5.9 * 120)))
    best = A.find_loop(rig, c, int(0.9 * FPS), int(1.9 * FPS), (0.05, 0.5))
    e, a, b = best
    rise = c['hips'][b] - c['hips'][a]
    c2 = A.make_loop(rig, c, a, b)
    # remove the net climb from the hips (in-place), store the climb speed
    n = c2['n']; ramp = np.linspace(0, 1, n, endpoint=False)[:, None]
    c2['hips'] = c2['hips'] - ramp * rise[None]
    c2['speed'] = float(np.linalg.norm(rise) / (n / FPS))
    c2['loop_err'] = float(e)
    return fingers(rig, c2, 'grip', 'grip')

@clip('death_backward')
def death_backward(rig): return mocap_once(rig, '90_18', (0.55, 2.6), ('relaxed', 'relaxed'), post={})

@clip('death_thrown')
def death_thrown(rig):
    """Thrown forward by a blow: launched off the feet, crash face-down (for the ragdoll death see Godot)."""
    return mocap_once(rig, '90_16', (2.4, 5.0), ('relaxed', 'relaxed'), post={})

@clip('get_up_front')
def get_up_front(rig): return mocap_once(rig, '140_01', (1.0, 5.2), ('relaxed', 'relaxed'), post={})

@clip('get_up_back')
def get_up_back(rig): return mocap_once(rig, '139_18', (1.0, 5.6), ('relaxed', 'relaxed'), post={})

# ----------------------------------------------------------------------------- authored: stances
def feet_rest(rig, spread=0.0, fwd_l=0.0, fwd_r=0.0, yaw_l=6, yaw_r=-6, lift=(0, 0)):
    L = A.rest_ankle(rig, 'Left'); R = A.rest_ankle(rig, 'Right')
    return {'Left': (L[0] + spread, L[1] - fwd_l, L[2] + lift[0], yaw_l),
            'Right': (R[0] - spread, R[1] - fwd_r, R[2] + lift[1], yaw_r)}

ARMS_RELAXED = merge(both({'LeftUpperArm': (-4, 13, 4), 'LeftLowerArm': (-14, 0, 0), 'LeftHand': (-4, 0, 6)}))

@clip('idle', loop=True)
def idle(rig):
    """Heroic idle: tall chest, weight shifts, slow breathing, look-arounds, hand fidget."""
    n = 6 * FPS
    k = AU.Clip(rig, n, loop=True)
    base = merge(HERO, ARMS_RELAXED)
    feet = feet_rest(rig, spread=0.035)
    k.key(0, merge(base, {'Hips': (0, -2, 0), 'Spine': (0, 1.5, 0), 'Head': (0, 0, 0)}), 'smooth', hips=(0.012, 0, -0.012), feet=feet)
    k.key(50, merge(base, {'Hips': (0, -1, 0), 'Spine': (0, 1, 0), 'Head': (2, 0, 14), 'Neck': (0, 0, 6)}), 'smooth', hips=(0.010, 0, -0.014))
    k.key(75, merge(base, {'Hips': (0, -1, 0), 'Spine': (0, 1, 0), 'Head': (2, 0, 16), 'Neck': (0, 0, 7)}), 'smooth', hips=(0.008, 0, -0.014))
    k.key(95, merge(base, {'Hips': (0, 2, 0), 'Spine': (0, -1.5, 0), 'Head': (1, 0, -3)}), 'smooth', hips=(-0.012, 0, -0.012),
          fingers=('relaxed', 'relaxed'))
    k.key(130, merge(base, {'Hips': (0, 2.5, 0), 'Spine': (0, -2, 0), 'Head': (-2, 0, -12), 'Neck': (0, 0, -5),
                            'RightLowerArm': (-22, 0, 0)}), 'smooth', hips=(-0.013, 0, -0.013), fingers=('relaxed', 'claw'))
    k.key(150, merge(base, {'Hips': (0, 2.5, 0), 'Spine': (0, -2, 0), 'Head': (-2, 0, -10), 'Neck': (0, 0, -4)}), 'smooth',
          hips=(-0.013, 0, -0.013), fingers=('relaxed', 'relaxed'))
    return k.build(overlap=[('Head', 4, 0.55), ('LeftHand', 3, 0.6), ('RightHand', 3, 0.6)], breathe=1.0,
                   noise=[('Head', 0.8, 6.0, 11), ('UpperChest', 0.4, 6.0, 12)])

COMBAT = merge({
    'Hips': (0, 0, 16), 'Spine': (7, 0, -7), 'Chest': (5, 0, -6), 'UpperChest': (2, 0, -3), 'Neck': (-4, 0, -2), 'Head': (-7, 0, 2),
    'LeftShoulder': (0, -3, 0), 'RightShoulder': (0, 3, 0)})
# hand targets (world): wrist position, 'across' (little->index knuckles) and palm normal, elbow pole
def H(pos, across, palm, pole=None):
    d = dict(pos=pos, across=across, palm=palm)
    if pole is not None: d['pole'] = pole
    return d
COMBAT_HANDS = {'Right': H((-0.47, -0.20, 1.08), (0.25, -0.9, 0.3), (0.2, 0.25, -0.95), (-0.8, 0.5, -0.2)),
                'Left': H((0.48, -0.02, 1.02), (-0.2, -0.9, 0.35), (-0.3, 0.2, -0.93), (0.8, 0.5, -0.2))}

def combat_feet(rig, spread=0.21, back=0.22, fwd=0.24):
    L = A.rest_ankle(rig, 'Left'); R = A.rest_ankle(rig, 'Right')
    return {'Left': (L[0] + spread, L[1] + back, L[2], 22), 'Right': (R[0] - spread, R[1] - fwd, R[2], -8)}

@clip('combat_idle', loop=True)
def combat_idle(rig):
    """Reference 06: wide, low, coiled stance with clawed hands; heavy breathing, predator sway."""
    n = int(2.4 * FPS)
    k = AU.Clip(rig, n, loop=True)
    ft = combat_feet(rig)
    k.key(0, COMBAT, 'smooth', hips=(0.02, 0.0, -0.15), feet=ft, fingers=('claw', 'claw'), hands=COMBAT_HANDS)
    h2 = {'Right': H((-0.48, -0.22, 1.05), (0.25, -0.9, 0.3), (0.2, 0.25, -0.95), (-0.8, 0.5, -0.2)),
          'Left': H((0.49, -0.0, 0.99), (-0.2, -0.9, 0.35), (-0.3, 0.2, -0.93), (0.8, 0.5, -0.2))}
    k.key(n // 2, merge(COMBAT, {'Spine': (1.5, 0, 2), 'Head': (0, 0, -2)}), 'smooth', hips=(0.035, -0.01, -0.165),
          fingers=('claw', 'claw'), hands=h2)
    return k.build(overlap=[('RightHand', 3, 0.5), ('LeftHand', 3, 0.5), ('Head', 3, 0.6)], breathe=2.2,
                   noise=[('Head', 0.8, 2.4, 21), ('RightHand', 1.5, 2.4, 22), ('LeftHand', 1.5, 2.4, 23)])

# ----------------------------------------------------------------------------- casting ("shooting")
@clip('cast_bolt', events={'release': 0.33})
def cast_bolt(rig):
    """Psychic bolt: coil (hand to the shoulder, torso twists away), snap thrust, recoil, settle."""
    n = 34
    k = AU.Clip(rig, n)
    ft = combat_feet(rig)
    k.key(0, COMBAT, 'smooth', hips=(0.02, 0.0, -0.15), feet=ft, fingers=('claw', 'claw'), hands=COMBAT_HANDS)
    coil = merge(COMBAT, {'Hips': (0, 0, -14), 'Spine': (0, 0, -10), 'Chest': (-3, 0, -10), 'Head': (0, 0, 14)})
    k.key(7, coil, 'out', hips=(0.0, 0.04, -0.16), fingers=('claw', 'cast'),
          hands={'Right': H((-0.26, 0.02, 1.42), (0.9, 0, 0.4), (0.3, -0.9, 0), (-0.7, 0.6, -0.3)),
                 'Left': H((0.30, -0.36, 1.25), (-0.3, -0.5, 0.8), (-0.9, 0, 0), (0.8, 0.3, -0.4))})
    thrust = merge(COMBAT, {'Hips': (0, 0, 20), 'Spine': (4, 0, 14), 'Chest': (4, 0, 10), 'Head': (-2, 0, -12),
                            'RightShoulder': (0, 0, 8)})
    k.key(10, thrust, 'in', hips=(0.0, -0.06, -0.17), fingers=('claw', 'cast'),
          hands={'Right': H((-0.10, -0.66, 1.42), (1, 0, 0.1), (0, -1, 0), (-0.6, 0.5, -0.5)),
                 'Left': H((0.40, 0.12, 1.08), (-0.2, -0.9, 0.3), (-0.3, 0.2, -0.9), (0.8, 0.5, -0.2))})
    recoil = merge(thrust, {'Spine': (-2, 0, 10), 'Chest': (-4, 0, 8), 'Head': (-5, 0, -8)})
    k.key(13, recoil, 'out', hips=(0.0, -0.02, -0.16),
          hands={'Right': H((-0.14, -0.52, 1.52), (1, 0, 0.35), (0, -0.9, 0.35), (-0.6, 0.5, -0.5))})
    k.key(20, merge(thrust, {'Spine': (2, 0, 8)}), 'smooth', hips=(0.01, -0.02, -0.155),
          hands={'Right': H((-0.2, -0.5, 1.40), (1, 0, 0.1), (0, -1, 0), (-0.6, 0.5, -0.5))})
    k.key(n - 1, COMBAT, 'smooth', hips=(0.02, 0.0, -0.15), fingers=('claw', 'claw'), hands=COMBAT_HANDS)
    return k.build(overlap=[('Head', 2, 0.5), ('LeftHand', 3, 0.5)], breathe=1.5)

@clip('cast_blast', events={'release': 0.5})
def cast_blast(rig):
    """Two-handed psychic blast: gather energy at the chest, explosive double push, shoulders thrown back."""
    n = 44
    k = AU.Clip(rig, n)
    ft = combat_feet(rig)
    k.key(0, COMBAT, 'smooth', hips=(0.02, 0.0, -0.15), feet=ft, fingers=('claw', 'claw'), hands=COMBAT_HANDS)
    gather = merge(COMBAT, {'Hips': (0, 0, 0), 'Spine': (-4, 0, 0), 'Chest': (-6, 0, 0), 'Head': (6, 0, 0)})
    k.key(12, gather, 'out', hips=(0.0, 0.05, -0.19), fingers=('cast', 'cast'),
          hands={'Right': H((-0.10, -0.22, 1.36), (0.5, 0, 0.85), (0.85, 0, -0.5), (-0.7, 0.5, -0.5)),
                 'Left': H((0.10, -0.22, 1.36), (-0.5, 0, 0.85), (-0.85, 0, -0.5), (0.7, 0.5, -0.5))})
    k.key(15, merge(gather, {'Chest': (-8, 0, 0)}), 'smooth', hips=(0.0, 0.06, -0.20))
    push = merge(COMBAT, {'Hips': (0, 0, 0), 'Spine': (8, 0, 0), 'Chest': (6, 0, 0), 'Head': (-8, 0, 0)})
    k.key(18, push, 'in', hips=(0.0, -0.08, -0.17),
          hands={'Right': H((-0.14, -0.64, 1.38), (0.95, 0, 0.3), (0, -1, 0), (-0.6, 0.5, -0.5)),
                 'Left': H((0.14, -0.64, 1.38), (-0.95, 0, 0.3), (0, -1, 0), (0.6, 0.5, -0.5))})
    k.key(23, merge(push, {'Spine': (-2, 0, 0), 'Chest': (-4, 0, 0)}), 'out', hips=(0.0, 0.0, -0.16),
          hands={'Right': H((-0.16, -0.52, 1.46), (0.95, 0, 0.4), (0, -0.95, 0.3), (-0.6, 0.5, -0.5)),
                 'Left': H((0.16, -0.52, 1.46), (-0.95, 0, 0.4), (0, -0.95, 0.3), (0.6, 0.5, -0.5))})
    k.key(n - 1, COMBAT, 'smooth', hips=(0.02, 0.0, -0.15), fingers=('claw', 'claw'), hands=COMBAT_HANDS)
    return k.build(overlap=[('Head', 3, 0.5)], breathe=1.5)

# ----------------------------------------------------------------------------- sword
SWORD_POSE = merge({'Hips': (0, 0, 12), 'Spine': (5, 0, -6), 'Chest': (3, 0, -5), 'Head': (-5, 0, 3)})
GUARD = {'Right': H((-0.18, -0.40, 1.16), (0.22, -0.45, 0.86), (0.95, 0.1, -0.1), (-0.8, 0.4, -0.4)),
         'Left': H((0.26, -0.24, 1.26), (-0.4, -0.6, 0.7), (-0.9, 0.2, 0.2), (0.7, 0.5, -0.4))}

def sword_feet(rig, dy=0.0, step=0.0):
    L = A.rest_ankle(rig, 'Left'); R = A.rest_ankle(rig, 'Right')
    return {'Left': (L[0] + 0.12, L[1] + 0.20 + dy, L[2], 24), 'Right': (R[0] - 0.10, R[1] - 0.22 + dy - step, R[2], -6)}

@clip('sword_summon', sword=True, events={'appear': 0.3})
def sword_summon(rig):
    """The blade materialises in the open right hand (socket scales in), the fist closes, guard."""
    n = 40
    k = AU.Clip(rig, n)
    k.key(0, COMBAT, 'smooth', hips=(0.02, 0.0, -0.15), feet=combat_feet(rig), fingers=('claw', 'claw'), hands=COMBAT_HANDS)
    k.key(10, merge(SWORD_POSE, {'Head': (4, 0, 10)}), 'out', hips=(0.02, 0.02, -0.14), fingers=('claw', 'cast'),
          hands={'Right': H((-0.30, -0.35, 1.02), (0.3, -0.6, 0.7), (0.3, 0.6, 0.7), (-0.8, 0.4, -0.3))})
    k.key(18, SWORD_POSE, 'in', fingers=('claw', 'grip'),
          hands={'Right': H((-0.22, -0.42, 1.10), (0.25, -0.6, 0.76), (0.95, 0.1, -0.1), (-0.8, 0.4, -0.4))})
    k.key(n - 1, SWORD_POSE, 'smooth', hips=(0.02, 0.0, -0.12), feet=sword_feet(rig), fingers=('claw', 'grip'), hands=GUARD)
    c = k.build(overlap=[('Head', 3, 0.5), ('RightHand', 2, 0.5)], breathe=1.2)
    t = np.arange(c['n'])
    c['sword_scale'] = np.clip((t - 8) / 8.0, 0.001, 1.0) ** 0.5
    return c

@clip('sword_idle', loop=True, sword=True)
def sword_idle(rig):
    n = int(2.0 * FPS)
    k = AU.Clip(rig, n, loop=True)
    k.key(0, SWORD_POSE, 'smooth', hips=(0.02, 0.0, -0.12), feet=sword_feet(rig), fingers=('claw', 'grip'), hands=GUARD)
    g2 = {'Right': H((-0.18, -0.41, 1.14), (0.24, -0.43, 0.87), (0.95, 0.1, -0.1), (-0.8, 0.4, -0.4)),
          'Left': H((0.26, -0.25, 1.24), (-0.4, -0.6, 0.7), (-0.9, 0.2, 0.2), (0.7, 0.5, -0.4))}
    k.key(n // 2, merge(SWORD_POSE, {'Chest': (1, 0, 1)}), 'smooth', hips=(0.03, -0.01, -0.135), hands=g2)
    return k.build(overlap=[('Head', 3, 0.6)], breathe=1.8, noise=[('Head', 0.6, 2.0, 31)])

def slash(rig, n, keys, root_end=(0, -0.25), step=0.30, overlap=None):
    """Common frame for sword strikes: guard -> keys -> guard, with a forward step (root motion)."""
    k = AU.Clip(rig, n)
    k.key(0, SWORD_POSE, 'smooth', hips=(0.02, 0.0, -0.12), feet=sword_feet(rig), fingers=('claw', 'grip'), hands=GUARD,
          root=(0, 0, 0, 0))
    for f, pose, ease, hips, hands, extra in keys:
        kw = dict(extra)
        k.key(f, merge(SWORD_POSE, pose), ease, hips=hips, hands=hands, **kw)
    k.key(n - 1, SWORD_POSE, 'smooth', hips=(0.02, 0.0, -0.12), hands=GUARD,
          feet=sword_feet(rig, dy=root_end[1]), root=(root_end[0], root_end[1], 0, 0))
    return k.build(overlap=overlap or [('Head', 3, 0.5), ('LeftHand', 3, 0.5), ('LeftLowerArm', 2, 0.6)], breathe=1.0)

@clip('sword_slash_1', sword=True, events={'hit': 0.37, 'combo_window': 0.6})
def sword_slash_1(rig):
    """Forehand diagonal: high wind-up over the right shoulder, cut down to the lower left."""
    L = A.rest_ankle(rig, 'Left'); R = A.rest_ankle(rig, 'Right')
    step_feet = {'Right': (R[0] - 0.08, R[1] - 0.58, R[2], -4), 'Left': (L[0] + 0.12, L[1] + 0.10, L[2], 26)}
    return slash(rig, 36, [
        (7, {'Hips': (0, 0, -12), 'Spine': (-2, 0, -14), 'Chest': (-4, 0, -12), 'Head': (0, 0, 18)}, 'out', (0.03, 0.05, -0.11),
         {'Right': H((-0.32, 0.02, 1.62), (0.2, 0.55, 0.8), (0.9, -0.3, 0.0), (-0.7, 0.5, 0.3)),
          'Left': H((0.34, -0.36, 1.30), (-0.3, -0.6, 0.7), (-0.9, 0.2, 0.2), (0.7, 0.4, -0.4))}, {}),
        (11, {'Hips': (0, 0, 14), 'Spine': (10, 0, 12), 'Chest': (6, 0, 10), 'Head': (-6, 0, -6)}, 'in', (0.0, -0.10, -0.16),
         {'Right': H((-0.06, -0.62, 1.20), (0.55, -0.72, -0.4), (0.3, 0.2, -0.93), (-0.7, 0.4, -0.3)),
          'Left': H((0.40, 0.05, 1.18), (-0.2, -0.9, 0.3), (-0.4, 0.2, -0.9), (0.8, 0.5, -0.2))}, dict(feet=step_feet, root=(0, -0.12, 0, 0))),
        (14, {'Hips': (0, 0, 26), 'Spine': (14, 0, 18), 'Chest': (8, 0, 14), 'Head': (-8, 0, -10)}, 'out', (0.0, -0.16, -0.19),
         {'Right': H((0.30, -0.42, 0.92), (0.55, 0.15, -0.8), (0.1, 0.9, -0.3), (-0.2, 0.6, -0.6)),
          'Left': H((0.46, 0.18, 1.20), (-0.2, -0.9, 0.3), (-0.4, 0.2, -0.9), (0.8, 0.5, -0.2))}, dict(root=(0, -0.2, 0, 0))),
        (20, {'Hips': (0, 0, 22), 'Spine': (12, 0, 15), 'Chest': (6, 0, 12), 'Head': (-8, 0, -8)}, 'smooth', (0.0, -0.15, -0.18),
         {'Right': H((0.26, -0.44, 0.96), (0.55, 0.2, -0.8), (0.1, 0.9, -0.3), (-0.2, 0.6, -0.6))}, {}),
    ], root_end=(0, -0.25), overlap=[('Head', 3, 0.5), ('LeftHand', 3, 0.45), ('LeftLowerArm', 2, 0.6), ('Chest', 1.5, 0.6)])

@clip('sword_slash_2', sword=True, events={'hit': 0.33, 'combo_window': 0.6})
def sword_slash_2(rig):
    """Backhand horizontal: blade cocked at the left hip, whips across at chest height to the right."""
    L = A.rest_ankle(rig, 'Left'); R = A.rest_ankle(rig, 'Right')
    step_feet = {'Left': (L[0] + 0.05, L[1] - 0.30, L[2], 10), 'Right': (R[0] - 0.14, R[1] - 0.05, R[2], -30)}
    return slash(rig, 34, [
        (7, {'Hips': (0, 0, 30), 'Spine': (6, 0, 22), 'Chest': (4, 0, 16), 'Head': (-4, 0, -24)}, 'out', (0.02, 0.0, -0.14),
         {'Right': H((0.24, -0.20, 1.12), (0.9, 0.3, 0.3), (0.0, -0.3, -0.95), (-0.3, 0.6, -0.6)),
          'Left': H((0.40, 0.10, 1.18), (-0.2, -0.9, 0.3), (-0.4, 0.2, -0.9), (0.8, 0.5, -0.2))}, dict(fingers=('open', 'grip'))),
        (10, {'Hips': (0, 0, 2), 'Spine': (6, 0, -4), 'Chest': (3, 0, -4), 'Head': (-4, 0, 4)}, 'in', (0.0, -0.08, -0.16),
         {'Right': H((-0.10, -0.62, 1.30), (-0.2, -0.98, 0.0), (0.0, 0.1, -1.0), (-0.6, 0.5, -0.5)),
          'Left': H((0.52, -0.05, 1.30), (-0.2, -0.9, 0.3), (-0.4, 0.2, -0.9), (0.8, 0.5, -0.2))}, dict(feet=step_feet, root=(0, -0.10, 0, 0))),
        (13, {'Hips': (0, 0, -22), 'Spine': (6, 0, -20), 'Chest': (3, 0, -14), 'Head': (-4, 0, 16)}, 'out', (0.0, -0.10, -0.17),
         {'Right': H((-0.56, -0.10, 1.30), (-0.95, 0.3, 0.0), (0.0, 0.2, -0.98), (-0.4, 0.7, -0.4))}, dict(root=(0, -0.16, 0, 0))),
        (19, {'Hips': (0, 0, -18), 'Spine': (4, 0, -16), 'Chest': (2, 0, -10), 'Head': (-4, 0, 12)}, 'smooth', (0.01, -0.08, -0.15),
         {'Right': H((-0.52, -0.14, 1.26), (-0.9, 0.35, 0.2), (0.0, 0.2, -0.98), (-0.4, 0.7, -0.4))}, dict(fingers=('claw', 'grip'))),
    ], root_end=(0, -0.2))

@clip('sword_slash_3', sword=True, events={'hit': 0.6})
def sword_slash_3(rig):
    """Heavy finisher: leaping overhead smash. Crouch, jump forward with the blade raised high behind the
    head, both knees driving, blade slammed down to the ground in front, heavy landing, rise."""
    L = A.rest_ankle(rig, 'Left'); R = A.rest_ankle(rig, 'Right')
    n = 52
    k = AU.Clip(rig, n)
    k.key(0, SWORD_POSE, 'smooth', hips=(0.02, 0.0, -0.12), feet=sword_feet(rig), fingers=('claw', 'grip'), hands=GUARD, root=(0, 0, 0, 0))
    k.key(8, merge(SWORD_POSE, {'Spine': (14, 0, 0), 'Chest': (8, 0, 0), 'Head': (-12, 0, 0)}), 'out', hips=(0.0, 0.02, -0.26),
          hands={'Right': H((-0.26, -0.10, 0.95), (0.2, 0.9, -0.2), (0.9, 0, 0.3), (-0.7, 0.3, -0.5)),
                 'Left': H((0.34, 0.08, 1.00), (-0.2, -0.9, 0.3), (-0.4, 0.2, -0.9), (0.8, 0.5, -0.2))})
    air = merge(SWORD_POSE, {'Hips': (-10, 0, 0), 'Spine': (-14, 0, 0), 'Chest': (-10, 0, 0), 'Head': (-4, 0, 0)})
    k.key(17, air, 'out', hips=(0.0, -0.10, 0.22), root=(0, -0.45, 0, 0),
          feet={'Left': (L[0] + 0.10, L[1] - 0.20, 0.42, 20), 'Right': (R[0] - 0.08, R[1] - 0.62, 0.36, -6)},
          hands={'Right': H((-0.14, 0.14, 1.95), (0.0, 0.55, 0.84), (1.0, 0.0, 0.0), (-0.7, -0.2, 0.7)),
                 'Left': H((0.40, -0.20, 1.80), (-0.3, -0.3, 0.9), (-0.9, 0.3, 0.2), (0.8, 0.2, 0.5))})
    k.key(22, merge(SWORD_POSE, {'Hips': (6, 0, 0), 'Spine': (20, 0, 0), 'Chest': (14, 0, 0), 'Head': (-16, 0, 0)}), 'in',
          hips=(0.0, -0.12, 0.05), root=(0, -0.70, 0, 0),
          hands={'Right': H((-0.10, -0.62, 1.15), (0.0, -0.75, -0.66), (1.0, 0.0, 0.0), (-0.7, 0.4, -0.5)),
                 'Left': H((0.36, 0.20, 1.40), (-0.3, -0.8, 0.5), (-0.6, 0.3, -0.7), (0.8, 0.5, -0.2))})
    land = merge(SWORD_POSE, {'Hips': (6, 0, 0), 'Spine': (14, 0, 0), 'Chest': (8, 0, 0), 'Head': (-14, 0, 0)})
    k.key(25, land, 'in', hips=(0.0, -0.10, -0.26), root=(0, -0.85, 0, 0),
          feet={'Left': (L[0] + 0.16, L[1] - 0.70, L[2], 24), 'Right': (R[0] - 0.12, R[1] - 1.20, R[2], -6)},
          hands={'Right': H((-0.10, -0.78, 0.55), (0.0, -0.5, -0.87), (1.0, 0.0, 0.0), (-0.7, 0.4, -0.5)),
                 'Left': H((0.44, 0.00, 1.05), (-0.2, -0.9, 0.3), (-0.4, 0.2, -0.9), (0.8, 0.5, -0.2))})
    k.key(31, merge(land, {'Spine': (12, 0, 0)}), 'out', hips=(0.0, -0.10, -0.24))
    k.key(n - 1, SWORD_POSE, 'smooth', hips=(0.02, 0.0, -0.12), root=(0, -0.85, 0, 0),
          feet={'Left': (L[0] + 0.12, L[1] + 0.20 - 0.85, L[2], 24), 'Right': (R[0] - 0.10, R[1] - 0.22 - 0.85, R[2], -6)}, hands=GUARD)
    return k.build(overlap=[('Head', 3, 0.5), ('LeftHand', 3, 0.45), ('LeftLowerArm', 2, 0.55), ('Chest', 1.5, 0.6)], lift=0.10)

@clip('sword_spin', sword=True, events={'hit': 0.4})
def sword_spin(rig):
    """360-degree spinning cut at waist height (root yaw turns a full circle)."""
    L = A.rest_ankle(rig, 'Left'); R = A.rest_ankle(rig, 'Right')
    n = 40
    k = AU.Clip(rig, n)
    k.key(0, SWORD_POSE, 'smooth', hips=(0.02, 0.0, -0.12), feet=sword_feet(rig), fingers=('claw', 'grip'), hands=GUARD, root=(0, 0, 0, 0))
    wide = {'Right': H((-0.62, -0.12, 1.22), (-0.95, 0.2, 0.1), (0.0, 0.1, -1.0), (-0.3, 0.6, -0.7)),
            'Left': H((0.55, 0.05, 1.25), (-0.2, -0.9, 0.3), (-0.4, 0.2, -0.9), (0.8, 0.5, -0.2))}
    k.key(7, merge(SWORD_POSE, {'Hips': (0, 0, 28), 'Spine': (6, 0, 20), 'Head': (0, 0, -20)}), 'out', hips=(0.0, 0.0, -0.20),
          hands={'Right': H((0.30, -0.18, 1.16), (0.9, 0.3, 0.2), (0.0, -0.3, -0.95), (-0.3, 0.6, -0.6)),
                 'Left': H((0.40, 0.10, 1.18), (-0.2, -0.9, 0.3), (-0.4, 0.2, -0.9), (0.8, 0.5, -0.2))})
    for i, (f, yaw) in enumerate([(12, -90), (16, -180), (20, -270), (24, -360)]):
        rad = math.radians(yaw)
        # feet pivot around the origin with the body
        def rot(p, a=rad): return (p[0] * math.cos(a) - p[1] * math.sin(a), p[0] * math.sin(a) + p[1] * math.cos(a))
        lx, ly = rot((L[0] + 0.12, L[1] + 0.2)); rx, ry = rot((R[0] - 0.10, R[1] - 0.22))
        hands_w = wide          # hands are body-relative and turn with the root
        k.key(f, merge(SWORD_POSE, {'Hips': (0, 0, -6), 'Spine': (6, 0, -10), 'Head': (0, 0, 8)}), 'linear' if i < 3 else 'out',
              hips=(0.0, 0.0, -0.18), root=(0, 0, 0, yaw),
              feet={'Left': (lx, ly, L[2], 24 + yaw), 'Right': (rx, ry, R[2], -6 + yaw)}, hands=hands_w)
    k.key(n - 1, SWORD_POSE, 'smooth', hips=(0.02, 0.0, -0.12), root=(0, 0, 0, -360), hands=GUARD,
          feet={'Left': (L[0] + 0.12, L[1] + 0.20, L[2], 24 - 360), 'Right': (R[0] - 0.10, R[1] - 0.22, R[2], -6 - 360)})
    return k.build(overlap=[('Head', 3, 0.5), ('LeftHand', 3, 0.45)], lift=0.05)

# ----------------------------------------------------------------------------- reactions
@clip('hit_front')
def hit_front(rig):
    """Struck in the chest: torso snaps back, head whips, arms fly out, stagger half a step back, recover."""
    n = 30
    k = AU.Clip(rig, n)
    ft = combat_feet(rig)
    k.key(0, COMBAT, 'smooth', hips=(0.02, 0.0, -0.15), feet=ft, fingers=('claw', 'claw'), hands=COMBAT_HANDS, root=(0, 0, 0, 0))
    k.key(3, merge(COMBAT, {'Spine': (-14, 0, 4), 'Chest': (-12, 0, 2), 'UpperChest': (-6, 0, 0), 'Head': (-16, 0, -6)}), 'out',
          hips=(0.0, 0.08, -0.12), fingers=('open', 'open'),
          hands={'Right': H((-0.56, 0.05, 1.30), (0.2, -0.9, 0.4), (0.3, 0.3, -0.9), (-0.8, 0.5, -0.2)),
                 'Left': H((0.56, 0.12, 1.26), (-0.2, -0.9, 0.4), (-0.3, 0.3, -0.9), (0.8, 0.5, -0.2))})
    L = A.rest_ankle(rig, 'Left'); R = A.rest_ankle(rig, 'Right')
    k.key(10, merge(COMBAT, {'Spine': (-4, 0, 0), 'Chest': (-3, 0, 0), 'Head': (-4, 0, 0)}), 'smooth', hips=(0.0, 0.12, -0.17),
          root=(0, 0.14, 0, 0), feet={'Right': (R[0] - 0.21, R[1] - 0.24 + 0.2, R[2], -8)}, fingers=('claw', 'claw'), hands=None)
    k.key(n - 1, COMBAT, 'smooth', hips=(0.02, 0.0, -0.15), root=(0, 0.14, 0, 0), hands=COMBAT_HANDS,
          feet={'Left': (L[0] + 0.21, L[1] + 0.22 + 0.14, L[2], 22), 'Right': (R[0] - 0.21, R[1] - 0.24 + 0.14, R[2], -8)})
    return k.build(overlap=[('Head', 3, 0.35), ('RightHand', 3, 0.4), ('LeftHand', 3, 0.4), ('Chest', 2, 0.5)])

@clip('hit_back')
def hit_back(rig):
    """Struck from behind: body jolts forward, head snaps, a catch step forward, turn back to guard."""
    n = 30
    k = AU.Clip(rig, n)
    ft = combat_feet(rig)
    L = A.rest_ankle(rig, 'Left'); R = A.rest_ankle(rig, 'Right')
    k.key(0, COMBAT, 'smooth', hips=(0.02, 0.0, -0.15), feet=ft, fingers=('claw', 'claw'), hands=COMBAT_HANDS, root=(0, 0, 0, 0))
    k.key(3, merge(COMBAT, {'Hips': (6, 0, 0), 'Spine': (16, 0, 0), 'Chest': (10, 0, 0), 'Head': (18, 0, 0)}), 'out',
          hips=(0.0, -0.10, -0.12), fingers=('open', 'open'),
          hands={'Right': H((-0.50, 0.25, 1.35), (0.2, -0.9, 0.4), (0.3, 0.3, -0.9), (-0.8, 0.5, -0.2)),
                 'Left': H((0.50, 0.28, 1.32), (-0.2, -0.9, 0.4), (-0.3, 0.3, -0.9), (0.8, 0.5, -0.2))})
    k.key(11, merge(COMBAT, {'Spine': (8, 0, 0), 'Head': (4, 0, 0)}), 'smooth', hips=(0.0, -0.16, -0.18), root=(0, -0.18, 0, 0),
          feet={'Left': (L[0] + 0.21, L[1] + 0.22 - 0.30, L[2], 22)}, fingers=('claw', 'claw'), hands=None)
    k.key(n - 1, COMBAT, 'smooth', hips=(0.02, 0.0, -0.15), root=(0, -0.18, 0, 0), hands=COMBAT_HANDS,
          feet={'Left': (L[0] + 0.21, L[1] + 0.22 - 0.18, L[2], 22), 'Right': (R[0] - 0.21, R[1] - 0.24 - 0.18, R[2], -8)})
    return k.build(overlap=[('Head', 3, 0.35), ('RightHand', 3, 0.4), ('LeftHand', 3, 0.4), ('Chest', 2, 0.5)])

# ----------------------------------------------------------------------------- dodges / turns
def _dodge(rig, dx, dy, n=24, crouch=0.18, lean=(0, 0, 0)):
    L = A.rest_ankle(rig, 'Left'); R = A.rest_ankle(rig, 'Right')
    ft0 = combat_feet(rig)
    k = AU.Clip(rig, n)
    k.key(0, COMBAT, 'smooth', hips=(0.02, 0.0, -0.15), feet=ft0, fingers=('claw', 'claw'), hands=COMBAT_HANDS, root=(0, 0, 0, 0))
    k.key(4, merge(COMBAT, {'Spine': (lean[0] * 0.5, lean[1] * 0.5, 0)}), 'out', hips=(0.0, 0.0, -0.15 - crouch))
    air = {s_: (p[0] + dx * 0.55, p[1] + dy * 0.55, p[2] + 0.12, p[3]) for s_, p in ft0.items()}
    k.key(10, merge(COMBAT, {'Spine': lean, 'Head': (-lean[0] * 0.5, -lean[1] * 0.6, 0)}), 'out', hips=(0.0, 0.0, -0.08),
          root=(dx * 0.6, dy * 0.6, 0, 0), feet=air)
    land = {s_: (p[0] + dx, p[1] + dy, p[2], p[3]) for s_, p in ft0.items()}
    k.key(15, merge(COMBAT, {'Spine': (lean[0] * 0.3, lean[1] * 0.3, 0)}), 'in', hips=(0.0, 0.0, -0.15 - crouch * 0.8),
          root=(dx, dy, 0, 0), feet=land)
    k.key(n - 1, COMBAT, 'smooth', hips=(0.02, 0.0, -0.15), root=(dx, dy, 0, 0))
    return k.build(overlap=[('Head', 3, 0.45), ('RightHand', 3, 0.45), ('LeftHand', 3, 0.45)], lift=0.02)

@clip('dodge_left')
def dodge_left(rig): return _dodge(rig, 1.3, 0.0, lean=(0, -14, 0))

@clip('dodge_right')
def dodge_right(rig): return _dodge(rig, -1.3, 0.0, lean=(0, 14, 0))

@clip('dodge_back')
def dodge_back(rig): return _dodge(rig, 0.0, 1.2, lean=(-10, 0, 0))

def _turn(rig, deg, n):
    """Turn in place from the idle stance with two pivot steps."""
    L = A.rest_ankle(rig, 'Left'); R = A.rest_ankle(rig, 'Right')
    k = AU.Clip(rig, n)
    base = merge(HERO, ARMS_RELAXED)
    f0 = feet_rest(rig, spread=0.035)
    k.key(0, base, 'smooth', feet=f0, root=(0, 0, 0, 0))
    def rot(p, a):
        a = math.radians(a); return (p[0] * math.cos(a) - p[1] * math.sin(a), p[0] * math.sin(a) + p[1] * math.cos(a))
    lead, trail = ('Left', 'Right') if deg > 0 else ('Right', 'Left')
    k.key(int(n * 0.15), merge(base, {'Head': (0, 0, deg * 0.35), 'Neck': (0, 0, deg * 0.1)}), 'out', hips=(0, 0, -0.02))
    mid = deg * 0.55
    lp = f0[lead]; x, y = rot(lp[:2], mid)
    k.key(int(n * 0.45), merge(base, {'Head': (0, 0, deg * 0.25), 'Spine': (0, 0, deg * 0.12)}), 'inout', hips=(0, 0, -0.03),
          root=(0, 0, 0, mid), feet={lead: (x, y, lp[2], lp[3] + mid)})
    tp = f0[trail]; x2, y2 = rot(tp[:2], deg); lx, ly = rot(lp[:2], deg)
    k.key(int(n * 0.75), merge(base, {'Head': (0, 0, -deg * 0.03)}), 'inout', hips=(0, 0, -0.02), root=(0, 0, 0, deg),
          feet={trail: (x2, y2, tp[2], tp[3] + deg), lead: (lx, ly, lp[2], lp[3] + deg)})
    k.key(n - 1, base, 'smooth', hips=(0, 0, 0), root=(0, 0, 0, deg))
    return k.build(overlap=[('Head', 3, 0.5), ('LeftHand', 3, 0.5), ('RightHand', 3, 0.5)], breathe=1.0)

@clip('turn_left_90')
def turn_left_90(rig): return _turn(rig, 90, 30)

@clip('turn_right_90')
def turn_right_90(rig): return _turn(rig, -90, 30)

@clip('turn_180')
def turn_180(rig): return _turn(rig, 180, 40)

# ----------------------------------------------------------------------------- air
@clip('fall', loop=True)
def fall(rig):
    """Airborne: knees tucked, arms out for balance, slight flailing."""
    n = 30
    k = AU.Clip(rig, n, loop=True)
    L = A.rest_ankle(rig, 'Left'); R = A.rest_ankle(rig, 'Right')
    pose = merge(HERO, {'Spine': (6, 0, 0), 'Head': (-8, 0, 0)})
    hands = {'Right': H((-0.62, -0.05, 1.45), (0.2, -0.9, 0.4), (0.3, 0.3, -0.9), (-0.8, 0.5, -0.2)),
             'Left': H((0.62, 0.0, 1.40), (-0.2, -0.9, 0.4), (-0.3, 0.3, -0.9), (0.8, 0.5, -0.2))}
    k.key(0, pose, 'smooth', hips=(0, 0, 0.0), fingers=('open', 'open'), hands=hands,
          feet={'Left': (L[0] + 0.06, L[1] + 0.12, 0.40, 10), 'Right': (R[0] - 0.05, R[1] - 0.18, 0.30, -10)})
    hands2 = {'Right': H((-0.60, -0.10, 1.52), (0.2, -0.9, 0.4), (0.3, 0.3, -0.9), (-0.8, 0.5, -0.2)),
              'Left': H((0.60, 0.05, 1.34), (-0.2, -0.9, 0.4), (-0.3, 0.3, -0.9), (0.8, 0.5, -0.2))}
    k.key(15, merge(pose, {'Spine': (4, 2, 0)}), 'smooth', hands=hands2,
          feet={'Left': (L[0] + 0.06, L[1] + 0.05, 0.34, 10), 'Right': (R[0] - 0.05, R[1] - 0.10, 0.38, -10)})
    return k.build(overlap=[('Head', 3, 0.5)])

GESTURE = merge({
    'Hips': (0, 3, -6), 'Spine': (-2, -2, 4), 'Chest': (-2, -2, 4), 'Head': (-3, 2, -6),
    'RightUpperArm': (-55, 50, 0), 'RightLowerArm': (-78, 0, 0), 'RightHand': (-25, 0, 20),
    'LeftUpperArm': (-8, 10, 6), 'LeftLowerArm': (-40, 0, 0), 'LeftHand': (0, 0, 10)})

@clip('gesture')
def gesture(rig):
    """Reference 05: the raised open hand - 'stand fast' / psychic command."""
    n = int(3.2 * FPS)
    k = AU.Clip(rig, n)
    ft = feet_rest(rig, spread=0.05, fwd_r=0.10, yaw_r=-12)
    base = merge(HERO, ARMS_RELAXED)
    k.key(0, base, 'smooth', feet=feet_rest(rig, spread=0.035), fingers=('relaxed', 'relaxed'))
    k.key(10, merge(base, {'RightUpperArm': (-10, 6, 0), 'RightLowerArm': (-30, 0, 0)}), 'in', feet=ft)
    k.key(20, merge(GESTURE, {'RightHand': (-40, 0, 12)}), 'back', hips=(-0.02, 0, -0.02), fingers=('relaxed', 'open'))
    k.key(70, merge(GESTURE, {'Head': (-4, 2, -8)}), 'smooth', fingers=('relaxed', 'open'))
    k.key(84, merge(base, {'RightLowerArm': (-25, 0, 0)}), 'inout', hips=(0, 0, 0), fingers=('relaxed', 'relaxed'))
    k.key(n - 1, base, 'smooth', feet=feet_rest(rig, spread=0.035))
    return k.build(overlap=[('RightHand', 3, 0.45), ('RightLowerArm', 2, 0.6), ('Head', 3, 0.6)], breathe=1.0)

# ----------------------------------------------------------------------------- export
def main(names=None):
    bpy.ops.wm.open_mainfile(filepath=os.path.join(W, 'model_rigged.blend'))
    arm = bpy.data.objects['Warrior']; rig = RT.Rig(arm)
    info = {}
    for name, (fn, meta) in CLIPS.items():
        if names and name not in names: continue
        c = fn(rig)
        c['loop'] = meta['loop']; c['sword'] = meta.get('sword', False)
        A.write_action(arm, name, c, rig)
        info[name] = dict(meta, frames=int(c['n']), seconds=round(c['n'] / FPS, 3),
                          speed=round(float(c.get('speed', 0.0)), 3),
                          root_distance=round(float(np.linalg.norm(c['root'][-1, :2] - c['root'][0, :2])), 3),
                          loop_err=round(float(c.get('loop_err', 0.0)), 4))
        print(f'{name:18s} {info[name]}')
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(W, 'model_anim.blend'))
    json.dump(info, open(os.path.join(W, 'clips.json'), 'w'), indent=1)

if __name__ == '__main__':
    main([a for a in sys.argv[1:] if a != '--'] or None)

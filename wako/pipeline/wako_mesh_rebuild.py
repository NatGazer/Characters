#!/usr/bin/env python3
"""Wako leg remesh + toe-bone flip -- reproducible Blender pipeline tool (revision 4).

Reads the ORIGINAL editable ``Wako.blend`` and writes a rebuilt copy.

Rig
    Both toe bones (``toe.L`` / ``toe.R``) are turned 180 degrees about world Z through
    their ankle line so they point FORWARD (Blender +Y, the side with the painted face).
    The new rest matrix is exactly ``Rz(pi) @ old`` (about the ankle line).  Every other
    bone keeps its rest head/tail/roll; no deform bone is added or removed; the 33
    ``wk_*`` actions are not touched.

Mesh (everything below the body's 8-vertex rim ring at z = 0.8044; the body is kept)
    * Hip -- ball and socket.  The hip pivot sits 11 cm above the body's leg opening, so
      any blended skin at the opening is dragged up into the body by deep flexion (the
      crater / slits of earlier builds).  Instead the thigh carries a SPHERE about the
      pivot (R 0.138) seated in a root-weighted socket inside the body: a short wall
      straight up from the rim, then a lining around the ball.  Any thigh rotation maps the
      sphere onto itself, so the opening always shows rigid ball surface -- no blended skin
      is ever in view, at any flexion, extension, spread or twist.  The root -> thigh
      weight change happens on a fold band at the ball's front-top, a cap that no pose in
      the range (flex -45..130, spread -15..40, yaw +-30, twist +-40) turns into the
      opening.  The leg's top loop follows the rim octagon (minus a 3 mm seam), so at rest
      the leg fills the opening like the original flange.  The lining is 8-sided where its
      clearance to the ball exceeds the chord sagitta; a rest self-intersection check
      (asserted) guarantees the hidden socket sits strictly between body skin and ball.
    * Legs: 16-sided lofted tubes (superellipse 2.1) following the ORIGINAL leg profile.
    * Knee: 7 fan loops around the hinge.  FRONT weights are a broad ramp over +11 / -9 cm
      (2D-optimised LBS front line: <= 1.95x stretch, ~18 deg turn at 145 deg); BACK weights
      step from thigh to shin across the hinge, so the backs of thigh and shin stay rigid
      and meet in a clean crease instead of collapsing.  The blend changes around the loop
      at the sides, where the skin lies on the hinge axis and hardly moves: no shear, and
      the back crease ends without a pinch.  Bisector depth 0.199-0.200 m at 60-90 deg.
    * Ankle: 5 near-level loops.  The FRONT (inner side of dorsiflexion) takes the foot
      weight high up, so in a flat-foot crouch the lower front stays with the foot and the
      turning shin lands on it in one clean crease (no curled lip / keyhole); the BACK
      (inner side of plantarflexion) blends broadly.  2D-optimised for zero overhang.
    * Foot: the original foot mirrored front-to-back (toe on the face side), rounded into
      the sole by 2 bevel loops plus a squarer inner sole rim, then a 4x4 sole patch.
    * Toe: the forefoot CAP (in front of the toe hinge line, below the dorsal crease), full
      width, outlined by one closed crease groove (front, sides and sole) and a slight toe
      spring, so it reads at rest and every toe bend folds into that groove.
    * Hygiene: closed manifold, consistent winding, no loose geometry, NO self-intersection
      at rest (all asserted).  Every body/head vertex, face and UV is kept bit-identical.
    * UVs: new islands (tube, sole, ball, socket lining) are packed inside plain grey
      (167/255) regions of Player.png that the original legs used; every new UV is sampled.

Weights
    Normalised, <= 4 influences (at most 2 used), no distant-bone influence, exact
    left/right mirror.  Body, rim and socket lining: root only.  Ball and thigh: thigh only.
    Knee / ankle: per loop, front / side / back blend.  Toe: a child share of the foot weight.

Usage (Blender 4.5 as a Python module, or ``blender -b --python``)::

    python wako_mesh_rebuild.py -- IN.blend OUT.blend [--stats STATS.json]
                                   [--texture //textures/Player.png]
                                   [--atlas PATH/TO/Player.png] [--params OVERRIDES.json]
    python wako_mesh_rebuild.py -- --stats-only IN.blend STATS.json

All geometry is authored in Blender WORLD space (Z up, armature object at z=1.0739, mesh
object at z=0.7022, both unrotated, scale 1) and converted to mesh-local space when
written.  The left leg (x < 0) is designed; the right leg is its exact mirror.
"""

import json
import math
import os
import struct
import sys
import zlib

import bpy  # noqa: E402  (bpy must be imported before bmesh/mathutils)
import bmesh
import numpy as np
from mathutils import Matrix, Vector
from mathutils.kdtree import KDTree

# --------------------------------------------------------------------------------------
# Contract constants
# --------------------------------------------------------------------------------------
ARMATURE_NAME = "wako_art"
MESH_NAME = "wakoMesh"
UV_NAME = "UVMap"
TOE_BONES = ("toe.L", "toe.R")
SIDE_GROUPS = {  # logical bone -> vertex group / bone name, per side (-1 = left, +1 = right)
    -1: {"root": "Bone", "thigh": "Bone.001", "shin": "Bone.003", "foot": "Bone.005", "toe": "toe.L"},
    +1: {"root": "Bone", "thigh": "Bone.002", "shin": "Bone.004", "foot": "Bone.006", "toe": "toe.R"},
}
MIRROR_GROUP = {"Bone": "Bone", "Bone.001": "Bone.002", "Bone.002": "Bone.001", "Bone.003": "Bone.004",
                "Bone.004": "Bone.003", "Bone.005": "Bone.006", "Bone.006": "Bone.005",
                "toe.L": "toe.R", "toe.R": "toe.L"}

CUT_Z = 0.78           # everything below this world height is the old leg and is rebuilt
BODY_MIN_Z = 0.80      # lowest body geometry: the body rim ring at z = 0.8044 (kept)
JUNCTION_Z = 0.8044
LEG_X = 0.237          # |x| of the leg bone chain (hip/knee/ankle line)
SIDES = 16             # leg tube resolution
# joints in world z (armature at 1.0739: hip -0.16, knee -0.57, ankle -0.969); the flipped
# toe head sits at (y 0.06, z 0.049), its grip point (+0.035 along the toe) at y 0.095.
HIP_Z = 0.914
KNEE_Z = 0.504
ANKLE_Z = 0.105
HIP_PIVOT = (-0.237, 0.0, 0.9139)   # left hip joint (Bone.001 head), world; checked against the rig
HIP_PIVOT_V = Vector(HIP_PIVOT)

# --------------------------------------------------------------------------------------
# Original leg profile (left leg, world space), measured from the old 8-sided rings:
#   z -> half-width (x), front line (y), back line (y).
# The original lower leg leaned back toward the sole and its toe was the BACK-bottom
# quarter of the foot.  Mirroring the foot front-to-back puts the toe on the face side.
# Rows marked (m) are the mirrored foot, blended into the unchanged shin rows.  The heel
# rows are rounded off a little (no separate heel bulge) so the foot continues the shin
# instead of reading as a cuff; the sole rim is rounded by the bevel rings (see P).
# --------------------------------------------------------------------------------------
PROFILE = [  # z, half_width, front_y, back_y
    (0.7497, 0.0951, 0.1099, -0.0971),
    (0.5997, 0.0928, 0.1311, -0.0728),
    (0.5006, 0.0928, 0.1385, -0.0653),
    (0.4015, 0.0928, 0.1460, -0.0579),
    (0.1640, 0.0924, 0.1246, -0.0786),
    (0.1262, 0.0921, 0.1185, -0.0835),
    (0.0884, 0.0917, 0.1140, -0.0885),   # (m)
    (0.0505, 0.0912, 0.1115, -0.0905),   # (m)
    (0.0200, 0.0905, 0.1110, -0.0915),   # (m) toe cap / heel
    (-0.0028, 0.0874, 0.1000, -0.0880),  # (m)
]
LEG_CX = -0.2365       # leg centre x (left)
TOE_PIVOT = (0.0600, 0.0489)   # (y, z) of the flipped toe head = the toe hinge axis (world)

# --------------------------------------------------------------------------------------
# Tunable design parameters (overridable with --params JSON for design iterations).
# --------------------------------------------------------------------------------------
P = {
    "exponent": 2.10,             # superellipse exponent of the leg sections
    # ---- hip: ball and socket ----------------------------------------------------------------
    # The hip pivot sits 11 cm above the body's leg opening, so ANY blended skin there is
    # dragged up into the body by deep flexion (the review's crater / slits).  Instead the
    # thigh carries a sphere about the pivot that is seated in a root-weighted lining inside
    # the body; the opening always shows rigid ball surface.  R is the largest sphere that
    # passes inside the opening's outer rim (|pivot - rim| = 0.1472 at the outer side).
    "ball_R": 0.138,
    "ball_fold_dir": [-0.14, 0.70, 0.70],   # fold cap centre (left leg): front-top, out of view
    "ball_fold_rho": 14.0,                  # fold cap radius (deg); free cap of the pose range: 22
    "ball_s": [0.05, 0.25, 0.45, 0.68],   # ball loops on the sphere between B1 and the fold
    "socket_throat_gap": 0.004,            # radial gap between the round socket throat and the ball (m)
    "socket_wall": 0.008,                   # height of the socket / leg-top walls above the rim (m)
    "socket_lip": 0.0015,                   # vertical lip from the body rim to the countersink (m)
    # lining loops: (s, gap to the ball, sides); the 8-sided loops clear their chord sagitta
    "lining": [[0.05, 0.010, 16], [0.28, 0.021, 8], [0.52, 0.026, 8], [0.76, 0.026, 8], [1.0, 0.020, 8]],
    # thigh loops between the leg's top loop T0 and the knee: name, z
    "thigh_rings": [["T2", 0.665]],
    "t0_inset": 0.0035,                      # seam between socket wall and leg top wall (m, perpendicular)
    # ---- knee: fan loops around the hinge axis ------------------------------------------
    # Loop k sits at s_k above (+) / below (-) the knee hinge on the FRONT line; around the
    # leg the offset is scaled by spread(t) = mix(front 1, side, back) so the loops open
    # like a fan over the kneecap (room for the 145 deg stretch) and close up toward the
    # back crease.  FRONT weights are a broad ramp (2D-optimised LBS front line: <= 1.95x
    # stretch and ~18 deg turn at 145 deg); BACK weights step from thigh to shin across the
    # hinge, so the back of the thigh and shin stay rigid and meet in a clean crease
    # instead of collapsing (bisector depth 0.199 / 0.200 m at 60 / 90 deg; the blended back
    # of the previous build thinned it to 0.180 / 0.169).  The weights cross over at the
    # sides, where the skin lies on the hinge axis and barely moves, so the change of blend
    # around the loop causes no shear and the back crease ends without a pinch.
    "knee_s": [0.110, 0.070, 0.038, 0.012, -0.016, -0.048, -0.088],
    "knee_w": [0.063, 0.204, 0.356, 0.511, 0.668, 0.820, 0.940],
    "knee_w_back": [0.0, 0.0, 0.03, 0.40, 0.97, 1.0, 1.0],
    "knee_spread_side": 0.90,
    "knee_spread_back": 0.60,
    "knee_spread_grow": 0.125,    # |s| at which a loop is level again (front == back)
    "kneecap": [0.0040, 0.500, 0.079],   # broad low front volume: amplitude, centre z, width
    "knee_back": [0.0020, 0.500, 0.035],  # a little crease room behind
    "shin_rings": [["S1", 0.340]],
    # ---- ankle: near-level loops around the ankle hinge (z 0.105) ------------------------
    # Dorsiflexion (crouch) folds the FRONT: there the foot weight rises steeply, so the
    # lower front stays with the flat foot and the turning shin front lands on it in one
    # clean crease (no curled lip / keyhole).  Plantarflexion folds the BACK (heel): there
    # the blend is broad.  Both profiles are 2D-optimised for zero notch / overhang depth
    # at 35-60 deg dorsiflexion and 35 deg plantarflexion.
    "ankle_s": [0.1091, 0.0740, 0.0403, -0.0060, -0.0338],
    "ankle_w": [0.0, 0.267, 0.536, 0.910, 0.953],
    "ankle_w_back": [0.114, 0.349, 0.520, 0.857, 0.893],
    "ankle_spread_side": 0.95,
    "ankle_spread_back": 0.94,
    "ankle_spread_grow": 0.2,
    # ---- foot, toe and sole -----------------------------------------------------------------
    # three loops down the toe front: two around the dorsal crease, one on the toe cap
    "foot_rings": [["F1", 0.060], ["F2", 0.048], ["F3", 0.031]],
    # bevel rings: name, z, radial inset (m), z at which the section shape is taken
    # [, superellipse exponent of an inner sole rim inset on both axes]
    "bevel_rings": [["E1", 0.0072, 0.0060, 0.012], ["E2", -0.0035, 0.0170, 0.008],
                    ["E3", -0.0062, 0.0360, 0.008, 3.0]],
    "sole_z_center": -0.0071,
    "sole_z_rim": -0.0066,
    "sole_rows_y": [0.057, 0.015, -0.035],   # lattice rows (front -> heel); row 1 = plantar crease
    "sole_rows_keep": 0.0,                   # share of the Coons-patch y kept (rows bow with the rim)
    # The toe is the forefoot CAP: the foot in front of the toe hinge line (sides and sole)
    # and below the dorsal crease (front face).  Its boundary is one closed crease line around
    # the forefoot, modelled as a shallow groove, so the toe reads at rest and every toe
    # bend folds into that groove: -45 lifts the cap with a soft dorsal crease, +45 rolls it
    # under with a plantar crease.  Full width (no lateral mask): no shear grooves, no 'W'.
    "toe_ramp_z": [0.070, 0.038],            # front face: no toe above / full toe below
    "toe_ramp_y": [0.040, 0.075],            # sides and sole: no toe behind / full toe in front
    "toe_lateral": None,                     # optional [|t| full, |t| zero] (deg) narrower toe
    "toe_groove": [0.006, 0.004],            # crease along the toe boundary: tube depth, sole lift
    "toe_pad": [0.0, 0.031, 0.021],          # forward bulge: amplitude, z centre, z width
    "toe_spring": [0.007, 0.06, 0.12, 0.03], # forefoot lift: amount, y start, y full, fade-out z
    "instep": [0.0, 0.10, 0.03],             # front recess above the toe: depth, z centre, z width
    "prune": 0.005,
}

# UV packing targets: plain grey (167/255) rectangles of Player.png (Blender UV, v up).
UV_RECTS = {
    (-1, "tube"): (0.8605, 0.3765, 0.9165, 0.7105),
    (+1, "tube"): (0.9255, 0.3765, 0.9815, 0.7105),
    (-1, "sole"): (0.0100, 0.6330, 0.0590, 0.6950),
    (+1, "sole"): (0.0840, 0.6330, 0.1340, 0.6950),
    (-1, "ball"): (0.7800, 0.4850, 0.8250, 0.7250),
    (+1, "ball"): (0.6870, 0.4870, 0.7320, 0.7240),
    (-1, "lining"): (0.3420, 0.3780, 0.3900, 0.7050),
    (+1, "lining"): (0.4330, 0.3780, 0.4800, 0.7050),
}
ATLAS_GREY = 167


# ======================================================================================
# Small helpers
# ======================================================================================
def log(*a):
    print("[wako_mesh_rebuild]", *a, flush=True)


def smoothstep(e0, e1, x):
    t = min(1.0, max(0.0, (x - e0) / (e1 - e0)))
    return t * t * (3.0 - 2.0 * t)


def pchip(points, x):
    """Monotone cubic (Fritsch-Carlson) interpolation through (x, y) points sorted by x."""
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    if x <= xs[0]:
        return ys[0]
    if x >= xs[-1]:
        return ys[-1]
    n = len(xs)
    h = [xs[i + 1] - xs[i] for i in range(n - 1)]
    d = [(ys[i + 1] - ys[i]) / h[i] for i in range(n - 1)]
    m = [0.0] * n
    m[0], m[-1] = d[0], d[-1]
    for i in range(1, n - 1):
        if d[i - 1] * d[i] <= 0:
            m[i] = 0.0
        else:
            w1, w2 = 2 * h[i] + h[i - 1], h[i] + 2 * h[i - 1]
            m[i] = (w1 + w2) / (w1 / d[i - 1] + w2 / d[i])
    i = max(k for k in range(n - 1) if xs[k] <= x)
    t = (x - xs[i]) / h[i]
    h00, h10 = 2 * t ** 3 - 3 * t ** 2 + 1, t ** 3 - 2 * t ** 2 + t
    h01, h11 = -2 * t ** 3 + 3 * t ** 2, t ** 3 - t ** 2
    return h00 * ys[i] + h10 * h[i] * m[i] + h01 * ys[i + 1] + h11 * h[i] * m[i + 1]


def profile(z):
    """(half_width, centre_y, half_depth) of the leg section at height z."""
    pts = sorted(PROFILE)
    hw = pchip([(p[0], p[1]) for p in pts], z)
    fy = pchip([(p[0], p[2]) for p in pts], z)
    by = pchip([(p[0], p[3]) for p in pts], z)
    return hw, 0.5 * (fy + by), 0.5 * (fy - by)


def superellipse_radius(rx, ry, p, t):
    """Polar radius of |x/rx|^p + |y/ry|^p = 1 in direction (sin t, cos t)."""
    s, c = abs(math.sin(t)), abs(math.cos(t))
    return 1.0 / ((s / rx) ** p + (c / ry) ** p) ** (1.0 / p)


def gauss(z, amp_center_width):
    a, c, w = amp_center_width
    return a * math.exp(-((z - c) / w) ** 2)


def wrap_pi(a):
    return (a + math.pi) % (2.0 * math.pi) - math.pi


def side_mix(t, fsb):
    """Blend a [front, side, back] triple around the leg (t measured from +Y toward +X):
    front value at t = 0, side value at +-90 deg, back value at 180 deg (smooth in cos t)."""
    f, s, b = fsb
    c = math.cos(t)
    k = abs(c) * abs(c) * (3.0 - 2.0 * abs(c))
    return s + ((f if c >= 0.0 else b) - s) * k


def fan_spread(t, s, side, back, grow):
    """Loop offset scale around the leg: 1 on the front line, `side`/`back` for the inner
    loops, growing back to 1 (level loop) as |s| approaches `grow`."""
    g = min(1.0, (abs(s) / grow) ** 2)
    return side_mix(t, [1.0, side + (1.0 - side) * g, back + (1.0 - back) * g])


def toe_field(y, z, t):
    """Toe weight (share of the foot weight) of a surface point of the left foot.

    The toe is the front-bottom "cap" of the foot: in front of the toe hinge line on the sides
    and the sole (ramp in y) and below the dorsal crease on the front face (ramp in z), so the
    toe boundary is one closed crease line around the forefoot."""
    wz = smoothstep(P["toe_ramp_z"][0], P["toe_ramp_z"][1], z)
    wy = smoothstep(P["toe_ramp_y"][0], P["toe_ramp_y"][1], y)
    lat = 1.0
    if P["toe_lateral"]:
        lat = 1.0 - smoothstep(math.radians(P["toe_lateral"][0]), math.radians(P["toe_lateral"][1]), abs(wrap_pi(t)))
    return wz * wy * lat


def toe_spring(y, z):
    """Upward offset of the forefoot bottom (a gentle toe spring / rocker that makes the toe
    cap read in profile), fading out above the sole rim."""
    lift, y0, y1, ztop = P["toe_spring"]
    if lift <= 0.0 or z > ztop:
        return 0.0
    return lift * smoothstep(y0, y1, y) * min(1.0, (ztop - z) / (ztop - P["sole_z_center"]))


# ======================================================================================
# PNG reader (stdlib only) for the atlas grey check
# ======================================================================================
def read_png_rgb(path):
    with open(path, "rb") as fh:
        data = fh.read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, w = 8, b"", None
    while pos < len(data):
        ln = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + ln]
        if tag == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
            assert depth == 8 and ctype in (2, 6), "unsupported PNG"
            ch = 3 if ctype == 2 else 4
        elif tag == b"IDAT":
            idat += body
        pos += 12 + ln
    raw = zlib.decompress(idat)
    stride = w * ch
    out = np.zeros((h, stride), np.uint8)
    prev = np.zeros(stride, np.int32)
    for r in range(h):
        f = raw[r * (stride + 1)]
        line = np.frombuffer(raw, np.uint8, stride, r * (stride + 1) + 1).astype(np.int32)
        if f == 0:
            cur = line
        elif f == 2:
            cur = (line + prev) & 255
        else:  # filters 1, 3, 4 need left neighbours: do them per byte
            cur = np.zeros(stride, np.int32)
            for i in range(stride):
                a = cur[i - ch] if i >= ch else 0
                b = prev[i]
                c = prev[i - ch] if i >= ch else 0
                if f == 1:
                    cur[i] = (line[i] + a) & 255
                elif f == 3:
                    cur[i] = (line[i] + ((a + b) >> 1)) & 255
                else:
                    pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                    pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                    cur[i] = (line[i] + pr) & 255
        out[r] = cur
        prev = cur
    return out.reshape(h, w, ch)[:, :, :3]


# ======================================================================================
# Rig: flip toes
# ======================================================================================
def bone_rest_table(arm):
    return {b.name: {"head": list(b.head_local), "tail": list(b.tail_local),
                     "matrix": [list(r) for r in b.matrix_local]} for b in arm.data.bones}


def flip_toe_bones(arm):
    """Rotate each toe bone 180 deg about world Z through its ankle line (x = bone x, y = 0)."""
    before = {n: arm.data.bones[n].matrix_local.copy() for n in TOE_BONES}
    rolls_before = {}
    bpy.context.view_layer.objects.active = arm
    arm.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    for eb in arm.data.edit_bones:
        rolls_before[eb.name] = (eb.head.copy(), eb.tail.copy(), eb.roll)
    for name in TOE_BONES:
        eb = arm.data.edit_bones[name]
        m = eb.matrix.copy()
        pivot = Matrix.Translation((m.translation.x, 0.0, 0.0))
        eb.matrix = pivot @ Matrix.Rotation(math.pi, 4, "Z") @ pivot.inverted() @ m
    untouched_dev = 0.0
    for eb in arm.data.edit_bones:
        if eb.name in TOE_BONES:
            continue
        h, t, r = rolls_before[eb.name]
        untouched_dev = max(untouched_dev, (eb.head - h).length, (eb.tail - t).length, abs(eb.roll - r))
    bpy.ops.object.mode_set(mode="OBJECT")
    report = {}
    for name in TOE_BONES:
        b = arm.data.bones[name]
        m0 = before[name]
        pivot = Matrix.Translation((m0.translation.x, 0.0, 0.0))
        expected = pivot @ Matrix.Rotation(math.pi, 4, "Z") @ pivot.inverted() @ m0
        err = max(abs(b.matrix_local[i][j] - expected[i][j]) for i in range(4) for j in range(4))
        report[name] = {
            "old_matrix": [[round(x, 6) for x in r] for r in m0],
            "new_matrix": [[round(x, 6) for x in r] for r in b.matrix_local],
            "old_head": [round(x, 6) for x in m0.translation],
            "new_head": [round(x, 6) for x in b.head_local],
            "new_tail": [round(x, 6) for x in b.tail_local],
            "max_error_vs_RzPI_premultiplied": err,
        }
        assert err < 1e-5, f"{name} flip mismatch {err}"
    report["edit_roundtrip_max_dev_untouched_bones"] = untouched_dev
    return report


# ======================================================================================
# Leg construction (left leg, world space)
# ======================================================================================
class LegDesign:
    """Positions, faces (with per-corner UV parameters) and logical weights of one leg.

    Vertex keys are strings; ``J0..J7`` refer to the kept body junction ring (ordered by
    angle from the front toward +x).  Faces are ``(keys, island)`` in outward winding for
    the left leg.  ``self.uvp[key]`` holds the (u, v) island parameters of every vertex.

    Path order of the loops, starting at the body:  J (body rim) -> L1..Ln (socket lining,
    climbing inside the body) -> fold band -> Bn..B1 (hip ball, coming back down) -> T0 (the
    ball's rim circle = first leg loop) -> thigh -> knee -> shin -> ankle -> foot -> sole.
    """

    def __init__(self, junction_world):
        self.pos, self.weights, self.faces = {}, {}, []
        self.angle, self.uvp = {}, {}
        self.junction = junction_world
        self.jc = sum(junction_world, Vector()) / 8.0
        self.jt = [math.atan2(p.x - self.jc.x, p.y - self.jc.y) for p in junction_world]
        self.ball = BallFrame()
        self.rings = self.ring_specs()
        self.ring_keys = {}
        self.build_socket()
        self.build_tube()
        self.build_sole()
        self.assign_weights()

    # ---------------------------------------------------------------- ring layout
    @staticmethod
    def ring_specs():
        """Top -> bottom list of the leg tube loops (T0 = the ball's rim circle)."""
        rings = [{"name": "T0", "kind": "top"}]
        for n, z in P["thigh_rings"]:
            rings.append({"name": n, "kind": "thigh", "z": z})
        for k, (s, w) in enumerate(zip(P["knee_s"], P["knee_w"])):
            rings.append({"name": f"K{k + 1}", "kind": "knee", "z": KNEE_Z + s, "s": s, "w": w, "k": k})
        for n, z in P["shin_rings"]:
            rings.append({"name": n, "kind": "shin", "z": z})
        for k, (s, w) in enumerate(zip(P["ankle_s"], P["ankle_w"])):
            rings.append({"name": f"A{k + 1}", "kind": "ankle", "z": ANKLE_Z + s, "s": s, "w": w, "k": k})
        for n, z in P["foot_rings"]:
            rings.append({"name": n, "kind": "foot", "z": z})
        for spec in P["bevel_rings"]:
            n, z, inset, zs = spec[:4]
            rings.append({"name": n, "kind": "bevel", "z": z, "inset": inset, "zshape": zs,
                          "exp": spec[4] if len(spec) > 4 else None})
        return rings

    def ring_z(self, ring, t):
        if ring["kind"] == "knee":
            return KNEE_Z + ring["s"] * fan_spread(t, ring["s"], P["knee_spread_side"],
                                                   P["knee_spread_back"], P["knee_spread_grow"])
        if ring["kind"] == "ankle":
            return ANKLE_Z + ring["s"] * fan_spread(t, ring["s"], P["ankle_spread_side"],
                                                    P["ankle_spread_back"], P["ankle_spread_grow"])
        return ring["z"]

    # ---------------------------------------------------------------- hip ball and socket
    def add_ring(self, name, points, angles, uvv):
        keys = []
        for j, (p, t) in enumerate(zip(points, angles)):
            key = f"{name}_{j}"
            self.pos[key] = p
            self.angle[key] = t
            self.uvp[key] = (t / (2.0 * math.pi), uvv)
            keys.append(key)
        self.ring_keys[name] = keys
        return keys

    def strip(self, a, b, island):
        n = len(a)
        for j in range(n):
            jn = (j + 1) % n
            self.faces.append(((a[j], a[jn], b[jn], b[j]), island))

    def build_socket(self):
        """Hip ball (thigh) seated in a socket (root) inside the body.

        The ball is a sphere about the hip pivot, so any thigh rotation maps it onto itself:
        the body's leg opening always shows rigid ball surface, at every hip angle, with no
        blended (collapsing) skin in view.  The root -> thigh weight change happens on the fold
        band at the front-top of the ball, a region that no hip pose in the range turns into
        the opening; the lining (root) and the band stay hidden inside the body.

        Profile per column j (rim point o_j = body octagon corner or edge midpoint):
          socket:  J (rim)  ->  L1, the socket throat straight above / inside o_j on the
                   sphere R + gap  ->  L2..Ln up the lining sphere to the fold ring
          leg:     T0 (o_j moved in by the seam, at the rim plane)  ->  B1 under the throat on
                   the ball sphere R (a wall parallel to the socket wall)  ->  B2.. the fold
        """
        bf = self.ball
        R = P["ball_R"]
        px, py = HIP_PIVOT[0], HIP_PIVOT[1]
        self.rim_pts = []
        for k in range(8):
            a, b = self.junction[k], self.junction[(k + 1) % 8]
            self.rim_pts += [a.copy(), (a + b) * 0.5]
        az = [math.atan2(o.x - px, o.y - py) % (2.0 * math.pi) for o in self.rim_pts]
        self.rim_az = az
        # The socket wall rises from the rim octagon to a round THROAT just outside the ball
        # (a countersink at the octagon corners, straight up where the octagon is closer), so
        # in any hip pose the ball fills the throat and only a narrow seam remains -- no dark
        # crescent in the corners.  The leg's top wall (T0 -> B1) runs parallel to it, one
        # seam (measured perpendicular to the wall) inside and below.
        zw = self.junction[0].z + P["socket_wall"]
        r_throat = math.sqrt(R * R - (HIP_PIVOT[2] - zw) ** 2) + P["socket_throat_gap"]
        g = P["t0_inset"]
        self.wall = []         # per column: (direction, L1 radius, T0 (r, z), B1 (r, z))
        for o in self.rim_pts:
            d = Vector((o.x - px, o.y - py))
            r_o = d.length
            d.normalize()
            r_l1 = min(r_o, r_throat)
            dr, dz = r_o - r_l1, zw - self.junction[0].z
            ln = math.hypot(dr, dz)
            nr, nz = -dz / ln, -dr / ln          # wall normal toward the leg (in and down)
            # leg wall: from the rim point (one seam in / down) to the ball sphere at the throat
            # height (a uniform circle, one throat gap inside the throat)
            r_b1 = min(r_l1 - P["socket_throat_gap"], r_throat - P["socket_throat_gap"])
            self.wall.append((d, r_l1, (r_o + g * nr, self.junction[0].z + g * nz), (r_b1, zw)))
        # base polar angle of the sphere sweeps: the direction of the throat, so both spheres
        # start above the walls and climb from there
        self.beta_l1 = [math.atan2(w[1], HIP_PIVOT[2] - zw) for w in self.wall]
        # ball: B1 (top of the leg wall), B2.. on the ball sphere, fold ring (s = 1)
        self.ball_keys = []
        b1 = [Vector((px + rb * d.x, py + rb * d.y, zb)) for d, _, _, (rb, zb) in self.wall]
        self.ball_keys.append(self.add_ring("B1", b1, az, 0.0))
        for k, s in enumerate(P["ball_s"] + [1.0]):
            pts = [HIP_PIVOT_V + bf.dir(b0, s, a) * R for a, b0 in zip(az, self.beta_l1)]
            self.ball_keys.append(self.add_ring(f"B{k + 2}", pts, az, s))
        # lining: L1 (top of the socket wall), then loops up the lining sphere (hidden; the
        # 8-sided ones keep a clearance to the ball larger than their chord sagitta)
        self.lining_keys = []
        # L0: the 16 rim points (octagon corners and edge midpoints) lifted a little, so the
        # countersink L0 -> L1 is a 16-column band matching the leg's wall T0 -> B1 one to one
        l0 = [Vector((o.x, o.y, o.z + P["socket_lip"])) for o in self.rim_pts]
        self.l0_keys = self.add_ring("L0", l0, az, -1.05)
        l1 = [Vector((px + rl * d.x, py + rl * d.y, zw)) for d, rl, _, _ in self.wall]
        self.lining_keys.append(self.add_ring("L1", l1, az, -1.0))
        for k, (s, gap, n) in enumerate(P["lining"]):
            step = SIDES // n
            pts = [HIP_PIVOT_V + bf.dir(b0, s, a) * (R + gap) for a, b0 in zip(az[::step], self.beta_l1[::step])]
            self.lining_keys.append(self.add_ring(f"L{k + 2}", pts, az[::step], -1.0 + s))
        # J (8) -> L1 (16): each body octagon edge splits 1 -> 2 (quad + triangle)
        for k in range(8):
            self.angle[f"J{k}"] = az[2 * k]
            self.uvp[f"J{k}"] = (az[2 * k] / (2.0 * math.pi), -1.1)
        self.fan(["J%d" % k for k in range(8)], self.l0_keys, "lining")
        # the walls and the bands leaving them are twisted and only a seam apart:
        # triangulate the socket and leg sides explicitly with matching diagonals so that
        # they cannot cross (the leg's T0 -> B1 wall is emitted in build_tube)
        L0, L1, L2 = self.l0_keys, self.lining_keys[0], self.lining_keys[1]
        B1, B2 = self.ball_keys[0], self.ball_keys[1]
        for j in range(SIDES):
            jn = (j + 1) % SIDES
            self.faces += [((L0[j], L0[jn], L1[jn]), "lining"), ((L0[j], L1[jn], L1[j]), "lining")]
            self.faces += [((L1[j], L1[jn], L2[jn]), "lining"), ((L1[j], L2[jn], L2[j]), "lining")]
        for a, b in zip(self.lining_keys[1:], self.lining_keys[2:]):
            if len(a) == len(b):
                self.strip(a, b, "lining")
            else:
                self.fan_down(a, b, "lining")
        self.fan(self.lining_keys[-1], self.ball_keys[-1], "lining")      # fold band (8 -> 16)
        for a, b in zip(self.ball_keys[::-1][:-2], self.ball_keys[::-1][1:-1]):
            self.strip(a, b, "ball")
        for j in range(SIDES):
            jn = (j + 1) % SIDES
            self.faces += [((B2[j], B2[jn], B1[j]), "ball"), ((B2[jn], B1[jn], B1[j]), "ball")]

    def fan(self, a, b, island):
        """Faces from loop a (n) to loop b (2n): each edge of a splits 1 -> 2."""
        n = len(a)
        for k in range(n):
            self.faces.append(((a[k], b[2 * k + 1], b[2 * k]), island))
            self.faces.append(((a[k], a[(k + 1) % n], b[(2 * k + 2) % (2 * n)], b[2 * k + 1]), island))

    def fan_down(self, a, b, island):
        """Faces from loop a (2n) to loop b (n): two edges of a merge into one."""
        n = len(b)
        for k in range(n):
            self.faces.append(((a[2 * k], a[2 * k + 1], b[k]), island))
            self.faces.append(((a[2 * k + 1], a[(2 * k + 2) % (2 * n)], b[(k + 1) % n], b[k]), island))

    # ---------------------------------------------------------------- tube
    def section_radius(self, name, z, t, toe=True):
        """Radius of the leg section at height z in direction t (from the section centre)."""
        hw, cy, hd = profile(z)
        r = superellipse_radius(hw, hd, P["exponent"], t)
        c = math.cos(t)
        front, back = max(c, 0.0) ** 2, max(-c, 0.0) ** 2
        r += gauss(z, P["kneecap"]) * front - gauss(z, P["knee_back"]) * back
        r -= gauss(z, P["instep"]) * front
        if toe and z < 0.13:
            # toe pad (front bulge) and the crease groove along the toe boundary (w = 0.5),
            # evaluated at the un-grooved surface point
            r += gauss(z, P["toe_pad"]) * front
            w = toe_field(cy + r * c, z, t)
            r -= P["toe_groove"][0] * 4.0 * w * (1.0 - w)
        return r, cy

    def section_point(self, name, z, t, inset=0.0, zshape=None, exp=None):
        zs = z if zshape is None else zshape
        if exp is not None:
            hw, cy, hd = profile(zs)
            r = superellipse_radius(hw - inset, hd - inset, exp, t)
            return LEG_CX + r * math.sin(t), cy + r * math.cos(t)
        r, cy = self.section_radius(name, zs, t)
        r -= inset
        return LEG_CX + r * math.sin(t), cy + r * math.cos(t)

    def build_tube(self):
        self.tube_keys = []
        for ring in self.rings:
            name = ring["name"]
            pts, angs = [], []
            for j in range(SIDES):
                t = 2.0 * math.pi * j / SIDES
                if ring["kind"] == "top":
                    # the foot of the leg's top wall: the body rim point, one seam in / down
                    d, _, (rt, zt), _ = self.wall[j]
                    p = Vector((HIP_PIVOT[0] + rt * d.x, HIP_PIVOT[1] + rt * d.y, zt))
                    t = self.rim_az[j]
                else:
                    z = self.ring_z(ring, t)
                    x, y = self.section_point(name, z, t, ring.get("inset", 0.0), ring.get("zshape"), ring.get("exp"))
                    p = Vector((x, y, z + toe_spring(y, z)))
                pts.append(p)
                angs.append(t)
            self.tube_keys.append(self.add_ring(name, pts, angs, 0.0))
        # tube v parameter: arc length down the ring centroids
        cents = [sum((self.pos[k] for k in keys), Vector()) / SIDES for keys in self.tube_keys]
        v = 0.0
        for i, keys in enumerate(self.tube_keys):
            if i:
                v += (cents[i] - cents[i - 1]).length
            for key in keys:
                self.uvp[key] = (self.uvp[key][0], v)
        self.tube_vmax = v
        # ball (B1) -> T0 (the leg's top wall, diagonals matching the socket wall), then the tube
        B1, T0 = self.ball_keys[0], self.tube_keys[0]
        for j in range(SIDES):
            jn = (j + 1) % SIDES
            self.faces += [((B1[j], B1[jn], T0[j]), "ball"), ((B1[jn], T0[jn], T0[j]), "ball")]
        for a, b in zip(self.tube_keys, self.tube_keys[1:]):
            self.strip(a, b, "tube")

    # ---------------------------------------------------------------- sole
    def lattice_key(self, a, b):
        """Key of sole lattice vertex (a, b); a -> +x, b -> back.  Border = bottom ring."""
        f = self.tube_keys[-1]
        if b == 0:
            return f[(14 + a) % SIDES]
        if a == 4:
            return f[2 + b]
        if b == 4:
            return f[6 + (4 - a)]
        if a == 0:
            return f[10 + (4 - b)]
        return f"L{a}{b}"

    def build_sole(self):
        """4x4 quad sole inside the last bevel ring: a Coons patch of that ring, flattened onto
        the contact plane.  Rows are biased forward so two of them cross the toe hinge."""
        def P_(a, b):
            return self.pos[self.lattice_key(a, b)]
        c00, c40, c04, c44 = P_(0, 0), P_(4, 0), P_(0, 4), P_(4, 4)
        for a in range(1, 4):
            for b in range(1, 4):
                s, t = a / 4.0, b / 4.0
                p = (1 - t) * P_(a, 0) + t * P_(a, 4) + (1 - s) * P_(0, b) + s * P_(4, b) \
                    - ((1 - s) * (1 - t) * c00 + s * (1 - t) * c40 + (1 - s) * t * c04 + s * t * c44)
                self.pos[f"L{a}{b}"] = Vector((p.x, p.y, 0.0))
        for b, ry in zip((1, 2, 3), P["sole_rows_y"]):
            for a in range(1, 4):
                q = self.pos[f"L{a}{b}"]
                q.y = ry + P["sole_rows_keep"] * (q.y - ry)
        cx = sum(self.pos[f"L2{b}"].x for b in (1, 2, 3)) / 3.0
        cy = sum(self.pos[f"L2{b}"].y for b in (1, 2, 3)) / 3.0
        hw = max(abs(self.pos[f"L{a}2"].x - cx) for a in (1, 3))
        for a in range(1, 4):
            for b in range(1, 4):
                q = self.pos[f"L{a}{b}"]
                rr = min(1.0, ((q.x - cx) / (hw * 1.6)) ** 2 + ((q.y - cy) / 0.13) ** 2)
                q.z = P["sole_z_center"] + (P["sole_z_rim"] - P["sole_z_center"]) * rr
                w = toe_field(q.y, q.z, math.atan2(q.x - LEG_CX, q.y - cy))
                q.z += P["toe_groove"][1] * 4.0 * w * (1.0 - w)      # plantar crease
                q.z += toe_spring(q.y, q.z)
                self.angle[f"L{a}{b}"] = math.atan2(q.x - LEG_CX, q.y - cy)
        for a in range(4):
            for b in range(4):
                ks = (self.lattice_key(a, b), self.lattice_key(a + 1, b),
                      self.lattice_key(a + 1, b + 1), self.lattice_key(a, b + 1))
                self.faces.append((ks, "sole"))

    # ---------------------------------------------------------------- weights
    def assign_weights(self):
        for k in range(8):
            self.weights[f"J{k}"] = {"root": 1.0}
        for keys in [self.l0_keys] + self.lining_keys:
            for key in keys:
                self.weights[key] = {"root": 1.0}
        for keys in self.ball_keys:
            for key in keys:
                self.weights[key] = {"thigh": 1.0}
        for ring, keys in zip(self.rings, self.tube_keys):
            for key in keys:
                self.weights[key] = self.chain_weights(ring, key)
        for a in range(1, 4):
            for b in range(1, 4):
                key = f"L{a}{b}"
                self.weights[key] = self.split_toe({"foot": 1.0}, key)

    def split_toe(self, w, key):
        """Hand the toe its share of the foot weight (toe = child of the foot)."""
        if "foot" not in w:
            return w
        p = self.pos[key]
        wt = toe_field(p.y, p.z, self.angle[key])
        if wt <= 0.0:
            return w
        f = w["foot"]
        out = dict(w)
        out["foot"] = f * (1.0 - wt)
        out["toe"] = f * wt
        return out

    def loop_weight(self, ring, key, joint):
        """Weight of a knee/ankle loop vertex: the loop's front value, optionally blended
        around the leg toward separate side / back values (P[joint + "_w_back"])."""
        wb = P.get(joint + "_w_back")
        if not wb:
            return ring["w"]
        k = ring["k"]
        ws = P.get(joint + "_w_side")
        side = ws[k] if ws else 0.5 * (ring["w"] + wb[k])
        return side_mix(self.angle[key], [ring["w"], side, wb[k]])

    def chain_weights(self, ring, key):
        kind = ring["kind"]
        if kind in ("top", "thigh"):
            return {"thigh": 1.0}
        if kind == "knee":
            w = self.loop_weight(ring, key, "knee")
            return {"thigh": 1.0 - w, "shin": w}
        if kind == "shin":
            return {"shin": 1.0}
        if kind == "ankle":
            w = self.loop_weight(ring, key, "ankle")
            return self.split_toe({"shin": 1.0 - w, "foot": w}, key)
        return self.split_toe({"foot": 1.0}, key)

    # ---------------------------------------------------------------- UV islands
    def island_uvs(self):
        """Per-face corner UVs in island-local space (u = angle around the leg, v = along)."""
        out = []
        for keys, island in self.faces:
            if island == "sole":
                out.append(tuple((self.pos[k].x, self.pos[k].y) for k in keys))
                continue
            us = [self.uvp[k][0] % 1.0 for k in keys]
            if max(us) - min(us) > 0.5:
                us = [u + 1.0 if u < 0.5 else u for u in us]
            vs = [self.uvp[k][1] for k in keys]
            if island == "tube":
                vs = [1.0 - v / self.tube_vmax for v in vs]
            out.append(tuple(zip(us, vs)))
        return out


class BallFrame:
    """Sweep frame of the hip ball / socket lining.

    Loop s (0 = the rim circle, 1 = the fold circle) is the circle of polar radius
    beta + (180 deg - rho - beta) * s about -Z, rotated by s * (angle from -Z to -fold)
    about the axis -Z x -fold.  The circles are nested (the radius grows faster than the
    centre moves), so the loops never cross; at s = 1 they become the small circle of radius
    rho about the fold direction (front-top, outside every hip pose's view).
    """

    def __init__(self):
        f = Vector(P["ball_fold_dir"]).normalized()
        a, b = Vector((0.0, 0.0, -1.0)), -f
        self.axis = a.cross(b).normalized()
        self.ang = a.angle(b)
        self.rho = math.radians(P["ball_fold_rho"])

    def dir(self, beta, s, az):
        r = beta + (math.pi - self.rho - beta) * s
        q = Matrix.Rotation(self.ang * s, 3, self.axis)
        sr = math.sin(r)
        return q @ Vector((sr * math.sin(az), sr * math.cos(az), -math.cos(r)))


# ======================================================================================
# Mesh rebuild
# ======================================================================================
def find_junction(bm, mw, side):
    ring = [v for v in bm.verts
            if abs((mw @ v.co).z - JUNCTION_Z) < 0.003 and (mw @ v.co).x * side > 0.05]
    assert len(ring) == 8, f"junction ring side {side}: {len(ring)} verts"
    for v in ring:  # it must now be an open boundary
        assert any(e.is_boundary for e in v.link_edges), "junction vertex not on boundary"
    world = [mw @ v.co for v in ring]
    c = sum(world, Vector()) / 8.0
    slots = [None] * 8
    for v, w in zip(ring, world):
        # angle from +Y toward the leg's "+x" (mirrored for the right leg); the ring is an
        # octagon with one vertex every 45 degrees starting at the front
        t = math.atan2(-side * (w.x - c.x), w.y - c.y)
        k = int(round(t / (math.pi / 4.0))) % 8
        assert abs(((t - k * math.pi / 4 + math.pi) % (2 * math.pi)) - math.pi) < 0.25, "junction angle"
        assert slots[k] is None, "junction slot collision"
        slots[k] = (v, w)
    return [s[0] for s in slots], [s[1] for s in slots]


def rebuild_mesh(ob, atlas_rgb):
    me = ob.data
    mw = ob.matrix_world.copy()
    mwi = mw.inverted()
    group_index = {g.name: g.index for g in ob.vertex_groups}

    bm = bmesh.new()
    bm.from_mesh(me)
    dl = bm.verts.layers.deform.verify()
    uvl = bm.loops.layers.uv[UV_NAME]

    # body UV winding convention (sign of UV area vs. face normal order)
    body_sign = 0.0
    for f in bm.faces:
        uv = [l[uvl].uv for l in f.loops]
        a = sum(uv[i].x * uv[(i + 1) % len(uv)].y - uv[(i + 1) % len(uv)].x * uv[i].y for i in range(len(uv)))
        body_sign += 1.0 if a > 0 else -1.0
    body_sign = 1.0 if body_sign >= 0 else -1.0

    old_leg = [v for v in bm.verts if (mw @ v.co).z < CUT_Z]
    log("deleting old leg vertices:", len(old_leg))
    bmesh.ops.delete(bm, geom=old_leg, context="VERTS")

    # the body is rigid: exact root weight (removes stray 0.005 thigh weights on the flange);
    # the junction ring gets its designed hip weights below
    for v in bm.verts:
        v[dl].clear()
        v[dl][group_index["Bone"]] = 1.0

    stats = {"uv_grey_samples": 0, "uv_grey_bad": 0}
    for side in (-1, +1):
        jverts, jworld = find_junction(bm, mw, side)
        # design in left-leg space: mirror the right junction into it
        jleft = [Vector((-w.x, w.y, w.z)) if side > 0 else w.copy() for w in jworld]
        design = LegDesign(jleft)
        groups = SIDE_GROUPS[side]
        keymap = {f"J{k}": jverts[k] for k in range(8)}
        for key in sorted(design.pos):  # deterministic order, identical for both sides
            p = design.pos[key].copy()
            if side > 0:
                p.x = -p.x
            keymap[key] = bm.verts.new(mwi @ p)
        bm.verts.ensure_lookup_table()
        # weights: prune tiny values, keep at most 4, renormalise
        for key, w in design.weights.items():
            v = keymap[key]
            v[dl].clear()
            w = sorted(((x, b) for b, x in w.items() if x > P["prune"]), reverse=True)[:4]
            s = sum(x for x, _ in w)
            for x, b in w:
                v[dl][group_index[groups[b]]] = x / s
        # faces + UVs
        local_uvs = design.island_uvs()
        islands = {}
        for (keys, island), luv in zip(design.faces, local_uvs):
            verts = [keymap[k] for k in keys]
            if side > 0:
                verts = verts[::-1]
                luv = tuple(luv[::-1])
            f = bm.faces.new(verts)
            f.smooth = True
            f.material_index = 0
            islands.setdefault(island, []).append((f, luv))
        for island, items in islands.items():
            x0, y0, x1, y1 = UV_RECTS[(side, island)]
            us = [u for _, luv in items for u, _ in luv]
            vs = [v for _, luv in items for _, v in luv]
            umin, umax, vmin, vmax = min(us), max(us), min(vs), max(vs)
            # orientation: mirror u if the island's winding disagrees with the body's
            area = 0.0
            for _, luv in items:
                n = len(luv)
                area += sum(luv[i][0] * luv[(i + 1) % n][1] - luv[(i + 1) % n][0] * luv[i][1] for i in range(n))
            flip = (1.0 if area > 0 else -1.0) != body_sign
            for f, luv in items:
                for loop, (u, v) in zip(f.loops, luv):
                    un = (u - umin) / (umax - umin)
                    if flip:
                        un = 1.0 - un
                    vn = (v - vmin) / (vmax - vmin)
                    loop[uvl].uv = (x0 + un * (x1 - x0), y0 + vn * (y1 - y0))
                    if atlas_rgb is not None:
                        H, W = atlas_rgb.shape[:2]
                        px = atlas_rgb[min(H - 1, int((1.0 - loop[uvl].uv.y) * H)),
                                       min(W - 1, int(loop[uvl].uv.x * W))]
                        stats["uv_grey_samples"] += 1
                        if np.abs(px.astype(int) - ATLAS_GREY).max() > 4:
                            stats["uv_grey_bad"] += 1
    bm.normal_update()

    # hygiene: no loose vertices or edges, closed manifold, consistent winding
    loose = [v for v in bm.verts if not v.link_faces]
    stats["loose_vertices"] = len(loose)
    assert not loose, f"{len(loose)} loose vertices"
    bm.verts.index_update()
    before = [tuple(v.index for v in f.verts) for f in bm.faces]
    bm2 = bm.copy()
    bmesh.ops.recalc_face_normals(bm2, faces=bm2.faces[:])
    bm2.faces.ensure_lookup_table()
    flipped = sum(1 for i, f in enumerate(bm2.faces) if tuple(v.index for v in f.verts) != before[i])
    bm2.free()
    stats["faces_flipped_by_recalc"] = flipped
    assert flipped == 0, f"{flipped} faces have inconsistent winding"
    stats["boundary_edges"] = sum(1 for e in bm.edges if e.is_boundary)
    stats["nonmanifold_edges"] = sum(1 for e in bm.edges if len(e.link_faces) != 2)
    assert stats["boundary_edges"] == 0 and stats["nonmanifold_edges"] == 0, "mesh is not closed manifold"
    stats["loose_edges"] = sum(1 for e in bm.edges if not e.link_faces)

    bm.to_mesh(me)
    bm.free()
    me.update()
    return stats


# ======================================================================================
# Statistics (works on any version of the file)
# ======================================================================================
def rest_checks(ob, body_idx):
    """Rest-pose hygiene of the rebuilt mesh: no self-intersection anywhere (the hidden hip
    socket must lie strictly between the body skin and the ball), plus the clearance of the
    hidden socket vertices (new vertices above the rim plane) to the body skin."""
    from mathutils.bvhtree import BVHTree
    me = ob.data
    mw = ob.matrix_world
    me.calc_loop_triangles()
    co = [mw @ v.co for v in me.vertices]
    tris = [tuple(t.vertices) for t in me.loop_triangles]
    bvh = BVHTree.FromPolygons(co, tris, all_triangles=True)
    pairs = sum(1 for a, b in bvh.overlap(bvh) if a < b and not (set(tris[a]) & set(tris[b])))
    body = set(body_idx)
    body_tris = [t for t in tris if all(v in body for v in t)]
    bvh_body = BVHTree.FromPolygons(co, body_tris, all_triangles=True)
    socket = [i for i in range(len(co)) if i not in body and co[i].z > JUNCTION_Z + 0.004]
    clear = min(bvh_body.find_nearest(co[i])[3] for i in socket)
    return {"rest_self_intersections": pairs, "socket_vertices": len(socket),
            "socket_min_clearance_to_body_skin_m": round(clear, 5)}


def mesh_stats(ob, arm=None, body_idx=None):
    """Mesh / weight statistics.  ``body_idx``: indices of the kept body vertices in a rebuilt
    file (the hidden hip socket also lies above the rim); without it the body is everything
    above the rim ring."""
    me = ob.data
    mw = ob.matrix_world
    gname = {g.index: g.name for g in ob.vertex_groups}
    infl = {}
    max_infl, unweighted, sum_err = 0, 0, 0.0
    weights = []
    for v in me.vertices:
        ws = {gname[g.group]: g.weight for g in v.groups if g.weight > 1e-6}
        n = len(ws)
        infl[n] = infl.get(n, 0) + 1
        max_infl = max(max_infl, n)
        s = sum(ws.values())
        if s < 1e-6:
            unweighted += 1
        else:
            sum_err = max(sum_err, abs(s - 1.0))
        weights.append(ws)
    pos = [mw @ v.co for v in me.vertices]
    kd = KDTree(len(pos))
    for i, p in enumerate(pos):
        kd.insert(p, i)
    kd.balance()
    sym_pos, sym_w, sym_leg = 0.0, 0.0, 0.0
    for i, p in enumerate(pos):
        q, j, d = kd.find(Vector((-p.x, p.y, p.z)))
        sym_pos = max(sym_pos, d)
        if p.z < BODY_MIN_Z:
            sym_leg = max(sym_leg, d)
        wi = weights[i]
        wj = {MIRROR_GROUP.get(b, b): x for b, x in weights[j].items()}
        for b in set(wi) | set(wj):
            sym_w = max(sym_w, abs(wi.get(b, 0.0) - wj.get(b, 0.0)))
    # distant-bone influence: the body above the junction ring must be root-only; legs below
    # the hip loops must not use the root; feet/toes must not reach the knee or body
    body_set = set(body_idx) if body_idx is not None else None
    is_body = [(i in body_set) if body_set is not None else (p.z >= 0.807) for i, p in enumerate(pos)]
    body_nonroot = sum(1 for b, w in zip(is_body, weights) if b and set(w) - {"Bone"})
    leg_root = sum(1 for p, w in zip(pos, weights) if p.z < 0.66 and w.get("Bone", 0.0) > 0)
    foot_in_body = sum(1 for p, w in zip(pos, weights)
                       if p.z > 0.30 and set(w) & {"Bone.005", "Bone.006", "toe.L", "toe.R"})
    toe_high = sum(1 for p, w in zip(pos, weights) if p.z > 0.12 and set(w) & {"toe.L", "toe.R"})
    linked = set()
    for poly in me.polygons:
        linked.update(poly.vertices)
    tris = sum(len(p.vertices) - 2 for p in me.polygons)
    sides = {}
    for p in me.polygons:
        sides[len(p.vertices)] = sides.get(len(p.vertices), 0) + 1
    zs = [p.z for p in pos]
    ys = [p.y for p in pos]
    xs = [p.x for p in pos]
    foot = [p for p in pos if p.z < 0.10 and p.x < 0]
    out = {
        "vertices": len(me.vertices), "polygons": len(me.polygons), "triangles": tris,
        "loose_vertices": len(me.vertices) - len(linked),
        "polygon_sides": {str(k): v for k, v in sorted(sides.items())},
        "materials": [m.name if m else None for m in me.materials],
        "uv_layers": [u.name for u in me.uv_layers],
        "smooth_polygons": sum(1 for p in me.polygons if p.use_smooth),
        "vertex_groups": len(ob.vertex_groups),
        "influence_histogram": {str(k): v for k, v in sorted(infl.items())},
        "max_influences": max_infl, "unweighted_vertices": unweighted,
        "max_weight_sum_error": sum_err,
        "symmetry_max_position_error_m": sym_pos, "symmetry_max_weight_error": sym_w,
        "symmetry_max_position_error_legs_m": sym_leg,
        "body_vertices_with_nonroot_weight": body_nonroot,
        "leg_vertices_below_0.66_with_root_weight": leg_root,
        "foot_or_toe_weight_above_z0.30": foot_in_body,
        "toe_weight_above_z0.12": toe_high,
        "left_foot_y_range_below_z0.10": [min(p.y for p in foot), max(p.y for p in foot)] if foot else None,
        "left_foot_length_below_z0.10_m": (max(p.y for p in foot) - min(p.y for p in foot)) if foot else None,
        "sole_bottom_z": min(zs),
        "world_bounds": {"x": [min(xs), max(xs)], "y": [min(ys), max(ys)], "z": [min(zs), max(zs)]},
        "modifiers": [(m.name, m.type) for m in ob.modifiers],
    }
    if arm is not None:
        out["bones"] = len(arm.data.bones)
        out["deform_bones"] = sum(1 for b in arm.data.bones if b.use_deform)
        out["actions"] = len(bpy.data.actions)
    return out


def leg_face_quality(ob):
    """Corner angles / edge ratios of the leg faces (z < BODY_MIN_Z)."""
    me = ob.data
    mw = ob.matrix_world
    pos = [mw @ v.co for v in me.vertices]
    angs, ratios, n3, n4 = [], [], 0, 0
    for p in me.polygons:
        pts = [pos[i] for i in p.vertices]
        if min(q.z for q in pts) >= BODY_MIN_Z - 1e-4 and max(q.z for q in pts) >= BODY_MIN_Z - 1e-4 \
                and all(q.z >= BODY_MIN_Z - 1e-4 for q in pts):
            continue
        n = len(pts)
        n3 += n == 3
        n4 += n == 4
        es = [(pts[(k + 1) % n] - pts[k]).length for k in range(n)]
        ratios.append(max(es) / max(min(es), 1e-9))
        for k in range(n):
            a, b = pts[k - 1] - pts[k], pts[(k + 1) % n] - pts[k]
            angs.append(math.degrees(a.angle(b, 0.0)))
    return {"leg_faces": n3 + n4, "leg_tris": n3, "leg_quads": n4,
            "min_corner_angle_deg": min(angs), "max_corner_angle_deg": max(angs),
            "max_edge_ratio": max(ratios), "p95_edge_ratio": float(np.percentile(ratios, 95))}


def snapshot_mesh(ob):
    """Copy of the vertex positions (world), faces and corner UVs before the rebuild."""
    me = ob.data
    uvl = me.uv_layers[UV_NAME].data
    return {"pos": [ob.matrix_world @ v.co for v in me.vertices],
            "faces": [[(me.loops[li].vertex_index, tuple(uvl[li].uv)) for li in p.loop_indices]
                      for p in me.polygons]}


def body_identity(snap, ob):
    """Compare body vertices/faces/UVs of the rebuilt mesh with the pre-rebuild snapshot."""
    cur_pos = [ob.matrix_world @ v.co for v in ob.data.vertices]
    uvl = ob.data.uv_layers[UV_NAME].data
    cur_faces = {}
    for p in ob.data.polygons:
        cur_faces[frozenset(p.vertices)] = {ob.data.loops[li].vertex_index: tuple(uvl[li].uv)
                                            for li in p.loop_indices}
    kd = KDTree(len(cur_pos))
    for i, p in enumerate(cur_pos):
        kd.insert(p, i)
    kd.balance()
    mapping, max_dev = {}, 0.0
    for i, w in enumerate(snap["pos"]):
        if w.z < BODY_MIN_Z:
            continue
        _, j, d = kd.find(w)
        mapping[i] = j
        max_dev = max(max_dev, d)
    faces_checked, missing, uv_dev = 0, 0, 0.0
    for corners in snap["faces"]:
        if not all(vi in mapping for vi, _ in corners):
            continue
        faces_checked += 1
        key = frozenset(mapping[vi] for vi, _ in corners)
        if key not in cur_faces:
            missing += 1
            continue
        cur = cur_faces[key]
        for vi, uv in corners:
            b = cur[mapping[vi]]
            uv_dev = max(uv_dev, abs(uv[0] - b[0]), abs(uv[1] - b[1]))
    keys = sorted(mapping)
    order_kept = all(mapping[a] < mapping[b] for a, b in zip(keys, keys[1:]))
    same_index = sum(1 for a in keys if mapping[a] == a)
    return {"body_vertices": len(mapping), "body_vertex_indices": sorted(mapping.values()),
            "body_vertex_max_position_dev_m": max_dev,
            "body_faces_checked": faces_checked, "body_faces_missing": missing,
            "body_face_uv_max_dev": uv_dev, "body_vertex_relative_order_kept": order_kept,
            "body_vertices_keeping_original_index": same_index}


# ======================================================================================
# Main
# ======================================================================================
def st_ok(st):
    """Weight / hygiene contract of the rebuilt mesh."""
    return (st["loose_vertices"] == 0 and st["unweighted_vertices"] == 0 and st["max_influences"] <= 4
            and st["symmetry_max_weight_error"] < 1e-5 and st["symmetry_max_position_error_legs_m"] < 1e-5
            and st["body_vertices_with_nonroot_weight"] == 0 and st["leg_vertices_below_0.66_with_root_weight"] == 0
            and st["foot_or_toe_weight_above_z0.30"] == 0 and st["toe_weight_above_z0.12"] == 0)


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    opts = {"stats": None, "texture": "//textures/Player.png", "atlas": None, "stats_only": False,
            "params": None}
    pos = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--stats", "--texture", "--atlas", "--params"):
            opts[a[2:]] = argv[i + 1]
            i += 2
        elif a == "--stats-only":
            opts["stats_only"] = True
            i += 1
        else:
            pos.append(a)
            i += 1
    return pos, opts


def main():
    pos, opts = parse_args()
    if opts["params"]:
        with open(opts["params"]) as fh:
            P.update(json.load(fh))
    if opts["stats_only"]:
        src, out = pos
        bpy.ops.wm.open_mainfile(filepath=os.path.abspath(src))
        ob = bpy.data.objects[MESH_NAME]
        st = mesh_stats(ob, bpy.data.objects[ARMATURE_NAME])
        st["leg_face_quality"] = leg_face_quality(ob)
        st["bone_rest"] = bone_rest_table(bpy.data.objects[ARMATURE_NAME])
        with open(out, "w") as fh:
            json.dump(st, fh, indent=1)
        log("stats written", out)
        return
    src, dst = (os.path.abspath(p) for p in pos[:2])
    with open(src, "rb") as fh:
        compressed = fh.read(4) == b"\x28\xb5\x2f\xfd"   # zstd magic -> compressed .blend
    bpy.ops.wm.open_mainfile(filepath=src)
    arm = bpy.data.objects[ARMATURE_NAME]
    ob = bpy.data.objects[MESH_NAME]
    actions_before = {a.name: [(fc.data_path, fc.array_index, tuple(tuple(k.co) for k in fc.keyframe_points))
                               for fc in a.fcurves] for a in bpy.data.actions}
    rest_before = bone_rest_table(arm)
    snap = snapshot_mesh(ob)

    atlas_path = opts["atlas"]
    if atlas_path is None:
        cand = os.path.join(os.path.dirname(src), "textures", "Player.png")
        atlas_path = cand if os.path.exists(cand) else None
    atlas = read_png_rgb(atlas_path) if atlas_path else None

    report = {"source": src, "output": dst, "source_compressed": compressed, "params": P}
    # the hip ball is built about the hip joints: they must be where the design assumes
    for name, sx in (("Bone.001", 1.0), ("Bone.002", -1.0)):
        h = arm.matrix_world @ arm.data.bones[name].head_local
        err = (h - Vector((sx * HIP_PIVOT[0], HIP_PIVOT[1], HIP_PIVOT[2]))).length
        assert err < 1e-4, f"{name} head {tuple(h)} is not the designed hip pivot ({err:.2e})"

    report["toe_flip"] = flip_toe_bones(arm)
    report["mesh_build"] = rebuild_mesh(ob, atlas)
    if atlas is not None:
        assert report["mesh_build"]["uv_grey_bad"] == 0, "new leg UVs leave the grey leg region"

    # rest of the rig must be untouched
    rest_after = bone_rest_table(arm)
    dev = 0.0
    for name, r in rest_before.items():
        if name in TOE_BONES:
            continue
        for key in ("head", "tail"):
            dev = max(dev, max(abs(a - b) for a, b in zip(r[key], rest_after[name][key])))
        dev = max(dev, max(abs(a - b) for ra, rb in zip(r["matrix"], rest_after[name]["matrix"])
                           for a, b in zip(ra, rb)))
    report["non_toe_bone_rest_max_dev"] = dev
    assert dev < 1e-6, f"non-toe bone rest changed by {dev}"
    actions_after = {a.name: [(fc.data_path, fc.array_index, tuple(tuple(k.co) for k in fc.keyframe_points))
                              for fc in a.fcurves] for a in bpy.data.actions}
    assert actions_after == actions_before, "actions changed"
    report["actions"] = len(actions_after)

    # texture path: relative to the saved file
    img = bpy.data.images.get("Player.png")
    if img is not None:
        img.filepath = opts["texture"]
    report["texture_path"] = img.filepath if img else None

    report["body_identity"] = body_identity(snap, ob)
    bi = report["body_identity"]
    body_idx = bi.pop("body_vertex_indices")
    report["stats"] = mesh_stats(ob, arm, body_idx)
    report["leg_face_quality"] = leg_face_quality(ob)
    report["rest_checks"] = rest_checks(ob, body_idx)
    rc = report["rest_checks"]
    log("rest checks", rc)
    # (WAKO_SKIP_REST_CHECK=1 only for design debugging: it saves a file that fails the check)
    assert os.environ.get("WAKO_SKIP_REST_CHECK") or (rc["rest_self_intersections"] == 0
                                                      and rc["socket_min_clearance_to_body_skin_m"] > 0.001), rc
    assert st_ok(report["stats"]), {k: v for k, v in report["stats"].items() if not isinstance(v, (dict, list))}
    assert bi["body_vertex_max_position_dev_m"] < 1e-6 and bi["body_faces_missing"] == 0 \
        and bi["body_face_uv_max_dev"] < 1e-6, f"body changed: {bi}"
    st = report["stats"]

    os.makedirs(os.path.dirname(dst), exist_ok=True)
    bpy.context.preferences.filepaths.save_version = 0   # no stray .blend1 backup next to the asset
    bpy.ops.wm.save_as_mainfile(filepath=dst, compress=compressed, relative_remap=False, copy=True)
    log("saved", dst, "compressed" if compressed else "uncompressed")
    if opts["stats"]:
        with open(opts["stats"], "w") as fh:
            json.dump(report, fh, indent=1)
    log(f"verts {st['vertices']} polys {st['polygons']} tris {st['triangles']} "
        f"influences {st['influence_histogram']} foot length {st['left_foot_length_below_z0.10_m']:.4f} "
        f"sole {st['sole_bottom_z']:.4f}")


if __name__ == "__main__":
    main()

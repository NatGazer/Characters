#!/usr/bin/env python3
"""Wako leg remesh + toe-bone flip -- reproducible Blender pipeline tool (revision 3).

Reads the ORIGINAL editable ``Wako.blend`` and writes a rebuilt copy.

Rig
    Both toe bones (``toe.L`` / ``toe.R``) are turned 180 degrees about world Z through
    their ankle line so they point FORWARD (Blender +Y, the side with the painted face).
    The new rest matrix is exactly ``Rz(pi) @ old`` (about the ankle line).  Every other
    bone keeps its rest head/tail/roll; no deform bone is added or removed; the 33
    ``wk_*`` actions are not touched.

Mesh (everything below the body's 8-vertex junction flange ring at z = 0.804)
    * Junction: an all-quad 8 -> 16 transition (side edges 1 -> 3, front/back 1 -> 1);
      the first leg loop lies on the body octagon, the next loops round it out.
    * Legs: 16-sided lofted tubes (superellipse 2.1) following the ORIGINAL leg profile.
    * Knee: 9 FAN loops around the hinge axis.  On the front line they are spread over
      +11.6 / -9.4 cm (room for the 145 deg stretch), toward the back they close up (60 %)
      for a compact crease; the outer loops are level again.  Weights are UNIFORM per
      loop, taken from a 2D optimisation of the LBS front line (no front vertex turns more
      than ~15-17 deg and no segment stretches more than ~1.9x at 145 deg).  A uniform
      loop is carried by one blended transform, so it stays a smooth closed curve: no
      circumferential shear, no side dimple.  A broad 4 mm kneecap volume sits at the hinge.
    * Ankle: 8 near-level loops from z 0.20 to 0.06 with a linear-ish shin -> foot blend
      (2D optimised): +-35 deg and 45-60 deg flat-sole dorsiflexion fold the front into a
      soft crease (the blend is wide enough that |dw/ds| < 1 / (d sin a), so the surface
      never folds back over itself); no waist, no heel bulge.
    * Foot: the original foot mirrored front-to-back (toe on the face side), rounded into
      the sole by 2 bevel loops plus a squarer inner sole rim, then a 4x4 sole patch.
    * Toe: a rounded front pad (7 mm) behind a soft dorsal crease, side grooves along the
      lateral weight boundary and a plantar crease row.  Toe weight = (front-face ramp) x
      (sole ramp) x (lateral mask), so 5 loops on the front face and 3 rows/rings under
      the sole share the toe bend: +45 rolls the pad under, -45 lifts it.
    * Hygiene: no loose vertices/edges, closed manifold, consistent winding (asserted).
    * Every body/head vertex, face and UV is kept bit-identical (and keeps its index).
    * UVs: new islands are packed inside the plain grey (167/255) leg region of
      Player.png that the original legs used; every new UV is sampled and must be grey.

Weights
    Progressive, normalised, <= 4 influences (at most 3 used), no distant-bone
    influence, exact left/right mirror.  Hip: root -> thigh over the flange ring, the
    transition row, four hip loops and the first thigh loop -- fast in front, slow behind
    (keeps the rear of the opening near the body plane in deep flexion).  Knee / ankle:
    uniform per fan loop.  Toe: a child share of the foot weight.

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
BODY_MIN_Z = 0.80      # lowest body geometry: the junction flange ring at z = 0.8044 (kept)
JUNCTION_Z = 0.804
LEG_X = 0.237          # |x| of the leg bone chain (hip/knee/ankle line)
SIDES = 16             # leg tube resolution
# joints in world z (armature at 1.0739: hip -0.16, knee -0.57, ankle -0.969); the flipped
# toe head sits at (y 0.06, z 0.049), its grip point (+0.035 along the toe) at y 0.095.
HIP_Z = 0.914
KNEE_Z = 0.504
ANKLE_Z = 0.105

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
    (0.0200, 0.0905, 0.1110, -0.0915),   # (m) toe pad / heel
    (-0.0028, 0.0874, 0.1000, -0.0880),  # (m)
]
LEG_CX = -0.2365       # leg centre x (left); the junction loops blend toward the body ring
TOE_PIVOT = (0.0600, 0.0489)   # (y, z) of the flipped toe head = the toe hinge axis (world)

# --------------------------------------------------------------------------------------
# Tunable design parameters (overridable with --params JSON for design iterations).
# --------------------------------------------------------------------------------------
P = {
    "exponent": 2.10,             # superellipse exponent of the leg sections
    # ---- hip junction (body octagon -> 16-sided leg) ----------------------------------
    "hip_rings": [["H0", 0.781], ["H1", 0.758], ["H2", 0.732], ["H3", 0.703]],
    "junction_I_frac": 0.35,      # interior transition row height between J and H0
    "junction_I_inset": 0.006,    # interior row pulled in toward the leg axis (m)
    "junction_I_spread": 1.0 / 3.0,
    "hip_shape": {"H0": 0.0, "H1": 0.55, "H2": 0.9, "H3": 1.0},
    "hip_angle": {"H0": 0.0, "H1": 0.45, "H2": 0.8, "H3": 1.0},
    "hip_scale": {"H0": 0.965, "H1": 0.945, "H2": 0.955, "H3": 0.975, "T1": 0.99},
    "hip_z_tilt": {},             # optional per-ring [front, back] z offsets (m)
    "thigh_rings": [["T1", 0.665]],
    # Hip weights: thigh weight per loop, [front, side, back].  The blend runs from the body
    # flange (J) over the interior transition row (I), the four hip loops and the first thigh
    # loop (~14 cm).  It is fast in front (where deep flexion folds the skin up under the
    # flange, out of sight) and slow behind: with the hip pivot 11 cm above the body bottom
    # every loop whose thigh weight exceeds ~0.3-0.55 (by depth) is carried up into the body
    # at 110 deg flexion, so the slow back keeps the rear of the opening near the body plane
    # (numpy socket depth from below-rear, hip 110 / knee 90: 1.1/3.1 cm -> 0.5/2.0 cm mean/p90;
    # none up to hip ~100).  The socket beyond that is a linear-blend limit of this rig.
    "w_J": [0.09, 0.05, 0.04],
    "w_I": [0.20, 0.13, 0.09],
    "w_hip": {"H0": [0.35, 0.22, 0.12], "H1": [0.55, 0.40, 0.24], "H2": [0.75, 0.60, 0.40],
              "H3": [0.89, 0.80, 0.58], "T1": [0.98, 0.94, 0.80]},
    # ---- knee: fan loops around the hinge axis ------------------------------------------
    # Loop k sits at s_k above (+) / below (-) the knee hinge on the FRONT line; around the
    # leg the offset is scaled by spread(t) = mix(front 1, side, back) so the loops open
    # like a fan over the kneecap (room for the 145 deg stretch) and close up toward the
    # back crease.  The inner loops are compressed most; the outer ones are almost level.
    # Weights are UNIFORM per loop (no shear around the circumference, no side dimple):
    # every loop is then carried by one blended transform and stays a smooth closed curve.
    # s/w come from a 2D optimisation of the front line (pipeline note in mesh_stats.json);
    # measured at 145 deg: front turn change <= 15 deg (absolute <= 19), stretch <= 1.9x.
    "knee_s": [0.116, 0.082, 0.056, 0.030, 0.010, -0.014, -0.037, -0.064, -0.094],
    "knee_w": [0.043, 0.155, 0.273, 0.412, 0.522, 0.658, 0.773, 0.880, 0.954],
    "knee_spread_side": 0.90,
    "knee_spread_back": 0.60,
    "knee_spread_grow": 0.125,    # |s| at which a loop is level again (front == back)
    "kneecap": [0.0040, 0.500, 0.079],   # broad low front volume: amplitude, centre z, width
    "knee_back": [0.0020, 0.500, 0.035],  # a little crease room behind
    "shin_rings": [["S1", 0.340]],
    # ---- ankle: near-level loops around the ankle hinge (z 0.105), uniform weights -------
    # A broad, almost linear shin -> foot blend over z 0.20 ... 0.06 (2D optimised) so that
    # +-35 deg and 45-60 deg flat-sole dorsiflexion fold the front into one rounded crease
    # (|dw/ds| < 1 / (d sin a) on the 11.5 cm-deep front: the surface never folds back).
    "ankle_s": [0.093, 0.079, 0.063, 0.044, 0.023, -0.007, -0.022, -0.046],
    "ankle_w": [0.162, 0.271, 0.369, 0.466, 0.552, 0.764, 0.797, 0.901],
    "ankle_spread_side": 0.95,
    "ankle_spread_back": 0.94,
    "ankle_spread_grow": 0.2,
    # ---- foot, toe and sole -----------------------------------------------------------------
    "foot_rings": [["F1", 0.034], ["F2", 0.019]],
    # bevel rings: name, z, radial inset (m), z at which the section shape is taken
    # [, superellipse exponent of an inner sole rim inset on both axes]
    "bevel_rings": [["E1", 0.0072, 0.0060, 0.012], ["E2", -0.0035, 0.0170, 0.008],
                    ["E3", -0.0062, 0.0360, 0.008, 3.0]],
    "sole_z_center": -0.0071,
    "sole_z_rim": -0.0066,
    "sole_rows_y": [0.040, 0.010, -0.030],   # lattice rows (front -> heel)
    "sole_rows_keep": 0.0,                   # share of the Coons-patch y kept (rows bow with the rim)
    # Toe weight field = ramp up the front face (z) x ramp along the sole (y) x lateral mask
    # (a child share of the foot weight).  The front-face ramp spans 5 loops, the sole ramp
    # the two front rim rings and two sole rows, so +45 rolls the pad under and -45 lifts it,
    # each with one soft crease: a 45 deg turn about an axis 5.5 cm behind the face and
    # 5.6 cm above the sole has to fold ~4 cm of skin somewhere.  Narrower sole ramps fold
    # the sole back on itself; wider ones lift the mid-sole into a pocket.
    "toe_ramp_z": [0.145, 0.055],            # front face: no toe above / full toe below
    "toe_ramp_y": [0.010, 0.085],             # sole: no toe behind / full toe in front
    "toe_lateral": [30.0, 70.0],             # |t| full, zero (deg around the leg axis)
    # toe shape: soft dorsal crease at the middle of the ramp, side grooves, a rounded front
    # pad, and the mid-sole row raised 2.2 mm (a shallow arch behind the plantar crease)
    "toe_crease": [0.0035, 0.068, 0.010],    # depth, z centre, z width
    "toe_plantar_lift": 0.0022,
    "toe_groove": [0.0080, 45.0, 9.0],       # depth, |t| centre, width (deg)
    "toe_pad": [0.0080, 0.031, 0.021],       # forward bulge: amplitude, z centre, z width
    "prune": 0.005,
}

# UV packing targets: plain grey (167/255) rectangles of Player.png (Blender UV, v up).
UV_RECTS = {
    (-1, "tube"): (0.8605, 0.3765, 0.9165, 0.7105),
    (+1, "tube"): (0.9255, 0.3765, 0.9815, 0.7105),
    (-1, "sole"): (0.0100, 0.6330, 0.0590, 0.6950),
    (+1, "sole"): (0.0840, 0.6330, 0.1340, 0.6950),
}
ATLAS_GREY = 167
ONE_TO_THREE = (1, 2, 5, 6)   # body octagon edges (front = edge 0..) that split 1 -> 3


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
    """(toe weight, top-crease factor, toe-region factor) of a surface point (left leg)."""
    wz = smoothstep(P["toe_ramp_z"][0], P["toe_ramp_z"][1], z)
    wy = smoothstep(P["toe_ramp_y"][0], P["toe_ramp_y"][1], y)
    lat = 1.0 - smoothstep(math.radians(P["toe_lateral"][0]), math.radians(P["toe_lateral"][1]), abs(wrap_pi(t)))
    region = wz * wy
    a, c, wd = P["toe_crease"]
    crease = math.exp(-((z - c) / wd) ** 2) * wy
    return region * lat, crease, region


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
    the left leg; ``self.angle`` holds the angle around the leg used for the UV u.
    """

    def __init__(self, junction_world):
        self.pos, self.weights, self.faces = {}, {}, []
        self.angle, self.ring_of = {}, {}
        self.junction = junction_world
        self.jc = sum(junction_world, Vector()) / 8.0
        self.jt = [math.atan2(p.x - self.jc.x, p.y - self.jc.y) for p in junction_world]
        self.rings = self.ring_specs()
        self.ring_names = [r["name"] for r in self.rings]
        self.ring_keys = []
        self.build_junction_angles()
        self.build_tube()
        self.build_junction_faces()
        self.build_sole()
        self.assign_weights()

    # ---------------------------------------------------------------- ring layout
    @staticmethod
    def ring_specs():
        """Top -> bottom list of loop specs: name, kind, z(t) function data, weights."""
        rings = []
        for n, z in P["hip_rings"]:
            rings.append({"name": n, "kind": "hip", "z": z})
        for n, z in P["thigh_rings"]:
            rings.append({"name": n, "kind": "thigh", "z": z})
        for k, (s, w) in enumerate(zip(P["knee_s"], P["knee_w"])):
            rings.append({"name": f"K{k + 1}", "kind": "knee", "z": KNEE_Z + s, "s": s, "w": w})
        for n, z in P["shin_rings"]:
            rings.append({"name": n, "kind": "shin", "z": z})
        for k, (s, w) in enumerate(zip(P["ankle_s"], P["ankle_w"])):
            rings.append({"name": f"A{k + 1}", "kind": "ankle", "z": ANKLE_Z + s, "s": s, "w": w})
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
        tilt = P["hip_z_tilt"].get(ring["name"])
        if tilt:
            c = math.cos(t)
            return ring["z"] + tilt[0] * max(c, 0.0) + tilt[1] * max(-c, 0.0)
        return ring["z"]

    # ---------------------------------------------------------------- junction angles
    def build_junction_angles(self):
        """Angles (and octagon points) of the 16 first-loop vertices: under the 8 body
        corners plus 1/3, 2/3 points of the four side edges (1 -> 3 pattern)."""
        self.h0_src = []   # (edge k, fraction) per H0 vertex
        for k in range(8):
            self.h0_src.append((k, 0.0))
            if k in ONE_TO_THREE:
                self.h0_src += [(k, 1.0 / 3.0), (k, 2.0 / 3.0)]
        assert len(self.h0_src) == SIDES
        self.h0_oct, self.h0_t = [], []
        for k, f in self.h0_src:
            a, b = self.junction[k], self.junction[(k + 1) % 8]
            p = a.lerp(b, f)
            self.h0_oct.append(Vector((p.x - self.jc.x, p.y - self.jc.y)))
            self.h0_t.append(math.atan2(p.x - self.jc.x, p.y - self.jc.y))

    def octagon_radius(self, t):
        """Distance from the junction centre to the body octagon along direction t."""
        d = Vector((math.sin(t), math.cos(t)))
        best = None
        for k in range(8):
            a = self.junction[k] - self.jc
            b = self.junction[(k + 1) % 8] - self.jc
            a2, b2 = Vector((a.x, a.y)), Vector((b.x, b.y))
            e = b2 - a2
            den = d.x * (-e.y) - d.y * (-e.x)
            if abs(den) < 1e-12:
                continue
            s = (a2.x * (-e.y) - a2.y * (-e.x)) / den
            u = (d.x * a2.y - d.y * a2.x) / den
            if s > 0 and -1e-9 <= u <= 1 + 1e-9:
                best = s if best is None else min(best, s)
        return best

    # ---------------------------------------------------------------- tube
    def section_radius(self, name, z, t, toe=True):
        """Radius of the leg section at height z in direction t (from the section centre)."""
        hw, cy, hd = profile(z)
        r = superellipse_radius(hw, hd, P["exponent"], t)
        c = math.cos(t)
        front, back = max(c, 0.0) ** 2, max(-c, 0.0) ** 2
        r += gauss(z, P["kneecap"]) * front - gauss(z, P["knee_back"]) * back
        if toe and z < 0.13:
            # toe pad (front bulge), then the dorsal crease and side grooves that follow the
            # toe weight boundary, evaluated at the un-grooved surface point
            lat = 1.0 - smoothstep(math.radians(P["toe_lateral"][0]), math.radians(P["toe_lateral"][1]),
                                   abs(wrap_pi(t)))
            r += gauss(z, P["toe_pad"]) * front * lat
            y0 = cy + r * c
            _, crease, region = toe_field(y0, z, t)
            r -= P["toe_crease"][0] * crease * lat
            g_depth, g_ang, g_w = P["toe_groove"]
            r -= g_depth * region * math.exp(-((abs(wrap_pi(t)) - math.radians(g_ang)) / math.radians(g_w)) ** 2)
        return r * P["hip_scale"].get(name, 1.0), cy

    def section_point(self, name, z, t, inset=0.0, zshape=None, exp=None):
        zs = z if zshape is None else zshape
        if exp is not None:
            # inner sole rim: a squarer outline (superellipse `exp`) inset on both axes, so
            # the 4x4 sole lattice inside it gets well-shaped corner cells
            hw, cy, hd = profile(zs)
            r = superellipse_radius(hw - inset, hd - inset, exp, t)
            return LEG_CX + r * math.sin(t), cy + r * math.cos(t)
        r, cy = self.section_radius(name, zs, t)
        r -= inset
        return LEG_CX + r * math.sin(t), cy + r * math.cos(t)

    def build_tube(self):
        for i, ring in enumerate(self.rings):
            name = ring["name"]
            keys = []
            for j in range(SIDES):
                tu = 2.0 * math.pi * j / SIDES
                a_ang = P["hip_angle"].get(name, 1.0)
                t = self.h0_t[j] + a_ang * wrap_pi(tu - self.h0_t[j])
                z = self.ring_z(ring, t)
                x, y = self.section_point(name, z, t, ring.get("inset", 0.0), ring.get("zshape"), ring.get("exp"))
                a_shape = P["hip_shape"].get(name, 1.0)
                if a_shape < 1.0:
                    # octagon-shaped point (scaled like the section) blended toward the section
                    ro = self.octagon_radius(t) * P["hip_scale"].get(name, 1.0)
                    ox, oy = self.jc.x + ro * math.sin(t), self.jc.y + ro * math.cos(t)
                    x, y = ox + a_shape * (x - ox), oy + a_shape * (y - oy)
                key = f"{name}_{j}"
                self.pos[key] = Vector((x, y, z))
                self.angle[key] = t
                self.ring_of[key] = (i, j)
                keys.append(key)
            self.ring_keys.append(keys)
        last = len(self.rings) - 1
        for i in range(last):
            top, bot = self.ring_keys[i], self.ring_keys[i + 1]
            for j in range(SIDES):
                jn = (j + 1) % SIDES
                self.faces.append(((top[j], top[jn], bot[jn], bot[j]), "tube"))

    # ---------------------------------------------------------------- junction band
    def build_junction_faces(self):
        h0 = self.ring_keys[0]
        z_j = self.junction[0].z
        z_h0 = self.rings[0]["z"]
        z_i = z_j + P["junction_I_frac"] * (z_h0 - z_j)
        for k in range(8):
            self.angle[f"J{k}"] = self.jt[k]
        idx = 0
        for k in range(8):
            ja, jb = f"J{k}", f"J{(k + 1) % 8}"
            if k not in ONE_TO_THREE:
                b0, b1 = h0[idx], h0[(idx + 1) % SIDES]
                self.faces.append(((ja, jb, b1, b0), "tube"))
                idx += 1
                continue
            b = [h0[(idx + m) % SIDES] for m in range(4)]
            ikeys = []
            fi = P["junction_I_spread"]
            for m, f in ((1, fi), (2, 1.0 - fi)):
                # interior row: above B1/B2, between the body edge and the first loop
                pj = self.junction[k].lerp(self.junction[(k + 1) % 8], f)
                ph = self.pos[b[m]]
                q = pj.lerp(ph, P["junction_I_frac"])
                d = Vector((q.x - self.jc.x, q.y - self.jc.y))
                if d.length > 1e-9:
                    d.normalize()
                    q.x -= d.x * P["junction_I_inset"]
                    q.y -= d.y * P["junction_I_inset"]
                q.z = z_i
                key = f"I{k}_{m}"
                self.pos[key] = q
                self.angle[key] = math.atan2(q.x - self.jc.x, q.y - self.jc.y)
                ikeys.append(key)
            i1, i2 = ikeys
            self.faces += [((ja, jb, i2, i1), "tube"), ((ja, i1, b[1], b[0]), "tube"),
                           ((i1, i2, b[2], b[1]), "tube"), ((i2, jb, b[3], b[2]), "tube")]
            idx += 3
        assert idx == SIDES

    # ---------------------------------------------------------------- sole
    def lattice_key(self, a, b):
        """Key of sole lattice vertex (a, b); a -> +x, b -> back.  Border = bottom ring."""
        f = self.ring_keys[-1]
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
                if b == 2:   # plantar crease under the toe hinge
                    q.z += P["toe_plantar_lift"] * (1.0 if a == 2 else 0.6)
                self.angle[f"L{a}{b}"] = math.atan2(q.x - LEG_CX, q.y - cy)
        for a in range(4):
            for b in range(4):
                ks = (self.lattice_key(a, b), self.lattice_key(a + 1, b),
                      self.lattice_key(a + 1, b + 1), self.lattice_key(a, b + 1))
                self.faces.append((ks, "sole"))

    # ---------------------------------------------------------------- weights
    def assign_weights(self):
        for k in range(8):
            w = side_mix(self.jt[k], P["w_J"])
            self.weights[f"J{k}"] = {"root": 1.0 - w, "thigh": w}
        for key in self.pos:
            if key.startswith("I"):
                w = side_mix(self.angle[key], P["w_I"])
                self.weights[key] = {"root": 1.0 - w, "thigh": w}
        for i, keys in enumerate(self.ring_keys):
            ring = self.rings[i]
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
        wt, _, _ = toe_field(p.y, p.z, self.angle[key])
        if wt <= 0.0:
            return w
        f = w["foot"]
        out = dict(w)
        out["foot"] = f * (1.0 - wt)
        out["toe"] = f * wt
        return out

    def chain_weights(self, ring, key):
        kind, name = ring["kind"], ring["name"]
        t = self.angle[key]
        if kind == "hip":
            w = side_mix(t, P["w_hip"][name])
            return {"root": 1.0 - w, "thigh": w}
        if kind == "thigh":
            w = P["w_hip"].get(name)
            if w:
                w = side_mix(t, w)
                return {"root": 1.0 - w, "thigh": w}
            return {"thigh": 1.0}
        if kind == "knee":
            return {"thigh": 1.0 - ring["w"], "shin": ring["w"]}
        if kind == "shin":
            return {"shin": 1.0}
        if kind == "ankle":
            return self.split_toe({"shin": 1.0 - ring["w"], "foot": ring["w"]}, key)
        return self.split_toe({"foot": 1.0}, key)

    # ---------------------------------------------------------------- UV islands
    def island_uvs(self):
        """Per-face corner UVs in island-local space (tube: angle x arc length)."""
        cents = [Vector((self.jc.x, self.jc.y, self.junction[0].z))]
        for keys in self.ring_keys:
            cents.append(sum((self.pos[k] for k in keys), Vector()) / len(keys))
        v_of_ring = [0.0]
        for a, b in zip(cents, cents[1:]):
            v_of_ring.append(v_of_ring[-1] + (b - a).length)
        vmax = v_of_ring[-1]
        z_j = self.junction[0].z
        z_i = z_j + P["junction_I_frac"] * (self.rings[0]["z"] - z_j)
        v_i = v_of_ring[1] * (z_j - z_i) / (z_j - self.rings[0]["z"])

        def v_of(key):
            if key.startswith("J"):
                return 0.0
            if key.startswith("I"):
                return v_i
            return v_of_ring[self.ring_of[key][0] + 1]

        out = []
        for keys, island in self.faces:
            if island == "sole":
                out.append(tuple((self.pos[k].x, self.pos[k].y) for k in keys))
                continue
            us = [((self.angle[k] / (2 * math.pi)) + 0.5) % 1.0 for k in keys]
            if max(us) - min(us) > 0.5:
                us = [u + 1.0 if u < 0.5 else u for u in us]
            out.append(tuple((u, 1.0 - v_of(k) / vmax) for u, k in zip(us, keys)))
        return out


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
def mesh_stats(ob, arm=None):
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
    body_nonroot = sum(1 for p, w in zip(pos, weights) if p.z >= 0.807 and set(w) - {"Bone"})
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
        "body_vertices_above_flange_with_nonroot_weight": body_nonroot,
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
    return {"body_vertices": len(mapping), "body_vertex_max_position_dev_m": max_dev,
            "body_faces_checked": faces_checked, "body_faces_missing": missing,
            "body_face_uv_max_dev": uv_dev, "body_vertex_relative_order_kept": order_kept,
            "body_vertices_keeping_original_index": same_index}


# ======================================================================================
# Main
# ======================================================================================
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

    report["stats"] = mesh_stats(ob, arm)
    report["leg_face_quality"] = leg_face_quality(ob)
    report["body_identity"] = body_identity(snap, ob)
    bi = report["body_identity"]
    assert bi["body_vertex_max_position_dev_m"] < 1e-6 and bi["body_faces_missing"] == 0 \
        and bi["body_face_uv_max_dev"] < 1e-6, f"body changed: {bi}"
    st = report["stats"]
    assert st["loose_vertices"] == 0 and st["unweighted_vertices"] == 0 and st["max_influences"] <= 4
    assert st["symmetry_max_weight_error"] < 1e-5 and st["symmetry_max_position_error_legs_m"] < 1e-5

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

#!/usr/bin/env python3
"""Wako leg remesh + toe-bone flip -- reproducible Blender pipeline tool.

Reads the ORIGINAL editable ``Wako.blend`` and writes a rebuilt copy:

* Rig: both toe bones (``toe.L`` / ``toe.R``) are turned 180 degrees about world Z
  through their ankle line so they point FORWARD (Blender +Y, the side with the
  painted face).  Every other bone keeps its rest head/tail/roll exactly; no deform
  bone is added or removed; the 33 ``wk_*`` actions are not touched.
* Mesh: the faceted octagonal legs below the body junction ring are deleted and
  rebuilt as lofted 16-sided tubes with organised loops (3 hip/junction loops,
  7 graded knee loops with a small front kneecap volume, 4 ankle loops), a rounded
  sole (4x4 quad grid with a soft bevel) and a small articulated toe on the face
  side (8-sided, 3 loops + domed tip).  Every body/head vertex, face and UV is
  kept bit-identical; the legs are bridged onto the existing 8-vertex junction
  ring with a symmetric 8->16 triangle fan that sits under the body flange.
* UVs: new leg islands are packed inside the plain grey (167/255) leg region of
  Player.png that the original legs used, so the Godot snow shader keeps the
  same leg tone.  Every new UV is sampled against the atlas and must be grey.
* Weights: progressive, normalised, <= 4 influences, no distant-bone influence,
  exact left/right mirror.  Knee blends are wider on the front (round knee) and
  narrower at the back (crease room); hip blends root->thigh over the junction
  loops; ankle blends shin->foot; the toe blends foot->toe over its root loop.

Usage (Blender 4.5 as a Python module, or ``blender -b --python``)::

    python wako_mesh_rebuild.py -- IN.blend OUT.blend [--stats STATS.json]
                                   [--texture //textures/Player.png]
                                   [--atlas PATH/TO/Player.png]
    python wako_mesh_rebuild.py -- --stats-only IN.blend STATS.json

All geometry is authored in Blender WORLD space (Z up, armature object at
z=1.0739, mesh object at z=0.7022, both unrotated, scale 1) and converted into
mesh-local space when written.  The left leg (x < 0) is designed; the right leg
is its exact mirror (x -> -x, reversed winding, mirrored bone names).
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

# Everything below this world height is the old leg and is rebuilt.  The body's
# lowest geometry is the 8-vertex junction flange ring at z = 0.804, which is kept.
CUT_Z = 0.78
BODY_MIN_Z = 0.80
JUNCTION_Z = 0.804
LEG_X = 0.237          # |x| of the leg bone chain (hip/knee/ankle line)
SIDES = 16             # leg tube resolution

# --------------------------------------------------------------------------------------
# Leg design (left leg, world space).  Radii measured from the original octagonal
# legs (they lie on a ~p=2.4 superellipse); p=2.25 keeps the slightly boxy read of
# the original while being smooth.  Rings are listed top -> bottom.
#   name, z, half-width (x), half-depth (y), superellipse exponent
# --------------------------------------------------------------------------------------
LEG_RINGS = [
    ("H1", 0.788, 0.1000, 0.1062, 2.40),   # hip / junction loops (root->thigh blend)
    ("H2", 0.764, 0.0970, 0.1042, 2.32),
    ("H3", 0.733, 0.0948, 0.1028, 2.26),
    ("T1", 0.690, 0.0935, 0.1022, 2.25),   # thigh
    ("T2", 0.645, 0.0928, 0.1020, 2.25),
    ("K1", 0.600, 0.0925, 0.1020, 2.25),   # knee: 7 graded loops around the joint at z=0.504
    ("K2", 0.566, 0.0925, 0.1020, 2.25),
    ("K3", 0.537, 0.0925, 0.1020, 2.25),
    ("K4", 0.508, 0.0925, 0.1020, 2.25),
    ("K5", 0.479, 0.0925, 0.1020, 2.25),
    ("K6", 0.450, 0.0925, 0.1020, 2.25),
    ("K7", 0.416, 0.0925, 0.1020, 2.25),
    ("S1", 0.362, 0.0925, 0.1020, 2.25),   # shin
    ("S2", 0.300, 0.0925, 0.1020, 2.25),
    ("S3", 0.240, 0.0924, 0.1018, 2.25),
    ("A1", 0.192, 0.0922, 0.1014, 2.25),   # ankle: 4 loops around the joint at z=0.105
    ("A2", 0.158, 0.0920, 0.1011, 2.25),
    ("A3", 0.128, 0.0918, 0.1008, 2.25),
    ("A4", 0.098, 0.0917, 0.1006, 2.25),
    ("F1", 0.062, 0.0915, 0.1004, 2.25),   # foot: toe-top level
    ("F2", 0.008, 0.0866, 0.0954, 2.20),   # sole bevel ring
]
# Leg centre-line forward offset (y) measured from the original ring centres: the
# original leg bows slightly toward the face around the knee; keep that profile.
CENTER_Y_PROFILE = [(-0.003, -0.0025), (0.051, 0.0055), (0.126, 0.017), (0.200, 0.029),
                    (0.400, 0.044), (0.450, 0.040), (0.500, 0.037), (0.550, 0.033),
                    (0.600, 0.029), (0.750, 0.0065)]
KNEE_Z = 0.504          # knee joint (Bone.001 tail) in world z
ANKLE_Z = 0.105         # ankle joint (Bone.005 head)
# Kneecap: a little extra front volume so the bent knee does not flatten (LBS loses
# volume on the outer side of a hinge); a little less at the back to leave crease room.
KNEECAP_FRONT = (0.0095, 0.506, 0.038)    # amplitude, centre z, gaussian width
KNEE_BACK_CUT = (0.0030, 0.508, 0.030)

# Sole: 4x4 quad grid inside the F2 ring.  Interior lattice at +-SOLE_GRID of the
# radius gives a flat contact patch with a soft bevel up to F2.
SOLE_GRID = 0.64
SOLE_Z_CENTER = -0.0070   # original sole bottom
SOLE_Z_RIM = -0.0050

# Toe (on the face side): 8-sided, root loop on the foot + 2 loops + tip loop + domed tip.
TOE_TIP_Y = 0.140         # tip loop (mid verts) world y
TOE_TIP_Z = 0.025
TOE_HALF_W = 0.035
TOE_HALF_H = 0.025
TOE_CORNER_K = 0.80       # corner pull-in of the rounded-rectangle sections
TOE_CORNER_BACK = 0.006   # corners sit slightly behind the mid verts (rounded tip edge)
TOE_NOSE_Y = 0.161        # domed tip (about 6 cm in front of the leg)
# (blend root->tip, outward fullness, dorsal crease drop): a slight neck with a crease on
# top right after the root, then a fuller pad toward the tip, so the toe reads as a digit.
TOE_SECTIONS = [(0.30, -0.0015, 0.0040), (0.66, 0.0040, 0.0)]

# --------------------------------------------------------------------------------------
# Weights (left leg logical bones; right leg mirrors).
# --------------------------------------------------------------------------------------
JUNCTION_THIGH = 0.06                              # body flange ring: nearly rigid with body
HIP_THIGH = {"H1": 0.36, "H2": 0.70, "H3": 0.92, "T1": 1.0}
KNEE_HALF_FRONT = 0.075                            # wide blend on the kneecap side
KNEE_HALF_BACK = 0.040                             # narrow blend in the crease
ANKLE_BLEND = (0.180, 0.060)                       # shin->foot blend between these z
TOE_W = {"root": 0.40, "TR1": 0.82, "TR2": 1.0, "TIP": 1.0, "near": 0.12}
PRUNE = 0.005

# --------------------------------------------------------------------------------------
# UV packing targets: plain grey (167/255) rectangles of Player.png (Blender UV, v up).
# --------------------------------------------------------------------------------------
UV_RECTS = {
    (-1, "tube"): (0.8605, 0.3765, 0.9165, 0.7105),
    (+1, "tube"): (0.9255, 0.3765, 0.9815, 0.7105),
    (-1, "sole"): (0.0100, 0.6330, 0.0590, 0.6950),
    (-1, "toe"): (0.0100, 0.7100, 0.0590, 0.8000),
    (-1, "tip"): (0.0100, 0.8150, 0.0590, 0.8650),
    (+1, "sole"): (0.0840, 0.6330, 0.1340, 0.6950),
    (+1, "toe"): (0.0840, 0.7100, 0.1340, 0.8000),
    (+1, "tip"): (0.0840, 0.8150, 0.1340, 0.8650),
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
    """Monotone cubic (Fritsch-Carlson) interpolation through sorted (x, y) points."""
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


def superellipse_radius(rx, ry, p, t):
    """Polar radius of |x/rx|^p + |y/ry|^p = 1 in direction (sin t, cos t)."""
    s, c = abs(math.sin(t)), abs(math.cos(t))
    return 1.0 / ((s / rx) ** p + (c / ry) ** p) ** (1.0 / p)


def gauss(z, amp_center_width):
    a, c, w = amp_center_width
    return a * math.exp(-((z - c) / w) ** 2)


def ring_angle(j):
    """Angle of tube vertex j, measured from +Y (front) toward +X."""
    return 2.0 * math.pi * j / SIDES


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
    """Positions, faces (with per-corner UVs) and logical weights of one (left) leg.

    Vertex keys are strings; ``J0..J7`` refer to the kept body junction ring.
    Faces are tuples ``(keys, uvs, island)`` in outward (CCW) winding for the left leg.
    """

    def __init__(self, junction_world):
        self.pos = {}
        self.weights = {}
        self.faces = []
        self.junction = junction_world      # list of 8 Vectors ordered by angle (front, then +x)
        jc = sum(junction_world, Vector()) / 8.0
        self.jc = jc
        self.ring_keys = []
        self.ring_centres = []
        self.build_tube()
        self.build_sole()
        self.build_toe()
        self.assign_weights()

    # ---------------------------------------------------------------- tube
    def ring_centre(self, idx, z):
        cy = pchip(CENTER_Y_PROFILE, z)
        cx = -LEG_X
        name = LEG_RINGS[idx][0]
        if name == "H1":
            cx, cy = 0.55 * cx + 0.45 * self.jc.x, 0.6 * cy + 0.4 * self.jc.y
        elif name == "H2":
            cx, cy = 0.85 * cx + 0.15 * self.jc.x, 0.88 * cy + 0.12 * self.jc.y
        return cx, cy

    def build_tube(self):
        for i, (name, z, rx, ry, p) in enumerate(LEG_RINGS):
            cx, cy = self.ring_centre(i, z)
            keys = []
            for j in range(SIDES):
                t = ring_angle(j)
                r = superellipse_radius(rx, ry, p, t)
                front = max(0.0, math.cos(t)) ** 2
                back = max(0.0, -math.cos(t)) ** 2
                r += gauss(z, KNEECAP_FRONT) * front - gauss(z, KNEE_BACK_CUT) * back
                key = f"{name}_{j}"
                self.pos[key] = Vector((cx + r * math.sin(t), cy + r * math.cos(t), z))
                keys.append(key)
            self.ring_keys.append(keys)
            self.ring_centres.append(Vector((cx, cy, z)))
        # UV parameters: u around (seam at the back, j=8), v = centre-line arc length.
        v_acc = [0.0]
        prev = self.jc
        for c in self.ring_centres:
            v_acc.append(v_acc[-1] + (c - prev).length)
            prev = c
        vmax = v_acc[-1]

        def u_of(j):
            return ((j + SIDES // 2) % SIDES) / SIDES

        def uv(j, k_ring, wrap_from=None):
            u = u_of(j)
            if wrap_from is not None and u < u_of(wrap_from):
                u += 1.0
            return (u, 1.0 - v_acc[k_ring] / vmax)

        # junction J (ring index 0 in v_acc) -> H1: symmetric 3-triangle fan per J edge
        h1 = self.ring_keys[0]
        for k in range(8):
            ja, jb = f"J{k}", f"J{(k + 1) % 8}"
            a, m, b = h1[2 * k], h1[2 * k + 1], h1[(2 * k + 2) % SIDES]
            ja_j, jb_j = 2 * k, (2 * k + 2) % SIDES
            self.faces.append(((ja, jb, m), (uv(ja_j, 0), uv(jb_j, 0, ja_j), uv(2 * k + 1, 1, ja_j)), "tube"))
            self.faces.append(((jb, b, m), (uv(jb_j, 0, ja_j), uv(jb_j, 1, ja_j), uv(2 * k + 1, 1, ja_j)), "tube"))
            self.faces.append(((ja, m, a), (uv(ja_j, 0), uv(2 * k + 1, 1, ja_j), uv(ja_j, 1)), "tube"))
        # ring bands; the F1->F2 band skips the two toe-patch faces (j = 15, 0)
        last = len(LEG_RINGS) - 1
        for i in range(last):
            top, bot = self.ring_keys[i], self.ring_keys[i + 1]
            for j in range(SIDES):
                jn = (j + 1) % SIDES
                if i == last - 1 and j in (15, 0):
                    continue
                self.faces.append(((top[j], top[jn], bot[jn], bot[j]),
                                   (uv(j, i + 1), uv(jn, i + 1, j), uv(jn, i + 2, j), uv(j, i + 2)), "tube"))

    # ---------------------------------------------------------------- sole
    def lattice_key(self, a, b):
        """Key of sole lattice vertex (a, b); a -> +x, b -> back.  Border = F2 ring."""
        f2 = self.ring_keys[-1]
        if b == 0:
            return f2[(14 + a) % SIDES]
        if a == 4:
            return f2[2 + b]
        if b == 4:
            return f2[6 + (4 - a)]
        if a == 0:
            return f2[10 + (4 - b)]
        return f"L{a}{b}"

    def build_sole(self):
        name, z2, rx, ry, p = LEG_RINGS[-1]
        c = self.ring_centres[-1]
        self.sole_centre = c
        for a in range(1, 4):
            for b in range(1, 4):
                u, v = (a - 2) * SOLE_GRID, (2 - b) * SOLE_GRID
                x = u * math.sqrt(1.0 - v * v / 2.0)
                y = v * math.sqrt(1.0 - u * u / 2.0)
                rr = (u * u + v * v) / (2.0 * SOLE_GRID ** 2)
                z = SOLE_Z_CENTER + (SOLE_Z_RIM - SOLE_Z_CENTER) * rr
                self.pos[f"L{a}{b}"] = Vector((c.x + x * rx, c.y + y * ry, z))
        for a in range(4):
            for b in range(4):
                if b == 0 and a in (1, 2):
                    continue  # toe patch
                ks = (self.lattice_key(a, b), self.lattice_key(a + 1, b),
                      self.lattice_key(a + 1, b + 1), self.lattice_key(a, b + 1))
                self.faces.append((ks, None, "sole"))

    # ---------------------------------------------------------------- toe
    def build_toe(self):
        f1, f2 = self.ring_keys[-2], self.ring_keys[-1]
        root = [f1[15], f1[0], f1[1], f2[1], "L31", "L21", "L11", f2[15]]
        cx = self.ring_centres[-1].x
        k, w, h = TOE_CORNER_K, TOE_HALF_W, TOE_HALF_H
        yb = TOE_TIP_Y - TOE_CORNER_BACK
        tip = [Vector((cx - k * w, yb, TOE_TIP_Z + k * h)), Vector((cx, TOE_TIP_Y, TOE_TIP_Z + h)),
               Vector((cx + k * w, yb, TOE_TIP_Z + k * h)), Vector((cx + w, TOE_TIP_Y, TOE_TIP_Z)),
               Vector((cx + k * w, yb, TOE_TIP_Z - k * h)), Vector((cx, TOE_TIP_Y, TOE_TIP_Z - h)),
               Vector((cx - k * w, yb, TOE_TIP_Z - k * h)), Vector((cx - w, TOE_TIP_Y, TOE_TIP_Z))]
        tip_c = sum(tip, Vector()) / 8.0
        rings = [root]
        for si, (s, bulge, crease) in enumerate(TOE_SECTIONS):
            keys = []
            for i in range(8):
                p = self.pos[root[i]].lerp(tip[i], s)
                out = tip[i] - tip_c
                out.y = 0.0
                if out.length > 1e-9:
                    p = p + out.normalized() * bulge
                if i in (0, 1, 2):          # top row: dorsal crease
                    p.z -= crease
                key = f"TR{si + 1}_{i}"
                self.pos[key] = p
                keys.append(key)
            rings.append(keys)
        tip_keys = []
        for i in range(8):
            key = f"TIP_{i}"
            self.pos[key] = tip[i]
            tip_keys.append(key)
        rings.append(tip_keys)
        self.pos["NOSE"] = Vector((cx, TOE_NOSE_Y, TOE_TIP_Z + 0.001))
        self.toe_rings = rings
        for r in range(len(rings) - 1):
            a, b = rings[r], rings[r + 1]
            for i in range(8):
                n = (i + 1) % 8
                self.faces.append(((a[i], a[n], b[n], b[i]), None, "toe"))
        m = {(0, 0): tip_keys[0], (0, 1): tip_keys[1], (0, 2): tip_keys[2], (1, 2): tip_keys[3],
             (2, 2): tip_keys[4], (2, 1): tip_keys[5], (2, 0): tip_keys[6], (1, 0): tip_keys[7],
             (1, 1): "NOSE"}
        for r in range(2):
            for c in range(2):
                self.faces.append(((m[(r, c)], m[(r, c + 1)], m[(r + 1, c + 1)], m[(r + 1, c)]), None, "tip"))

    # ---------------------------------------------------------------- weights
    def assign_weights(self):
        ring_names = [r[0] for r in LEG_RINGS]
        for k in range(8):
            self.weights[f"J{k}"] = {"root": 1.0 - JUNCTION_THIGH, "thigh": JUNCTION_THIGH}
        for i, keys in enumerate(self.ring_keys):
            name, z = ring_names[i], LEG_RINGS[i][1]
            for j, key in enumerate(keys):
                t = ring_angle(j)
                self.weights[key] = self.chain_weights(name, z, t)
        for key in self.pos:
            if key.startswith("L") and key not in self.weights:
                self.weights[key] = {"foot": 1.0}
        # toe: root loop / sections / tip, plus a soft collar on the surrounding foot
        f1, f2 = self.ring_keys[-2], self.ring_keys[-1]
        def add_toe(key, w):
            base = self.weights.get(key, {"foot": 1.0})
            out = {b: v * (1.0 - w) for b, v in base.items()}
            out["toe"] = out.get("toe", 0.0) + w
            self.weights[key] = out
        for key in self.toe_rings[0]:
            add_toe(key, TOE_W["root"])
        for key in self.toe_rings[1]:
            self.weights[key] = {"foot": 1.0 - TOE_W["TR1"], "toe": TOE_W["TR1"]}
        for key in self.toe_rings[2]:
            self.weights[key] = {"foot": 1.0 - TOE_W["TR2"], "toe": TOE_W["TR2"]}
        for key in self.toe_rings[3] + ["NOSE"]:
            self.weights[key] = {"toe": TOE_W["TIP"]}
        for key in (f1[14], f1[2], f2[14], f2[2], "L12", "L22", "L32"):
            add_toe(key, TOE_W["near"])

    @staticmethod
    def chain_weights(name, z, t):
        if name in HIP_THIGH:
            w = HIP_THIGH[name]
            return {"root": 1.0 - w, "thigh": w}
        if z > 0.30:
            # knee: blend half-width varies around the ring (front wide, back narrow)
            f = 0.5 * (1.0 + math.cos(t))
            half = KNEE_HALF_BACK + (KNEE_HALF_FRONT - KNEE_HALF_BACK) * f
            w = smoothstep(KNEE_Z + half, KNEE_Z - half, z)
            return {"thigh": 1.0 - w, "shin": w}
        w = smoothstep(ANKLE_BLEND[0], ANKLE_BLEND[1], z)
        return {"shin": 1.0 - w, "foot": w}

    # ---------------------------------------------------------------- UV islands
    def island_uvs(self):
        """Per-face corner UVs in island-local [0,1]^2 space for faces without explicit UVs."""
        out = []
        for keys, uvs, island in self.faces:
            if uvs is not None:
                out.append(uvs)
                continue
            if island == "sole":
                c = self.sole_centre
                rx, ry = LEG_RINGS[-1][2], LEG_RINGS[-1][3]
                out.append(tuple(((self.pos[k].x - c.x) / (2 * rx) + 0.5,
                                  (self.pos[k].y - c.y) / (2 * ry) + 0.5) for k in keys))
            elif island == "tip":
                cx = self.ring_centres[-1].x
                out.append(tuple(((self.pos[k].x - cx) / (2.4 * TOE_HALF_W) + 0.5,
                                  (self.pos[k].z - TOE_TIP_Z) / (2.4 * TOE_HALF_H) + 0.5) for k in keys))
            else:  # toe tube: u around (seam at bottom-mid), v along
                ring_of = {}
                for r, ring in enumerate(self.toe_rings):
                    for i, k in enumerate(ring):
                        ring_of[k] = (r, i)
                idx = [ring_of[k] for k in keys]
                base_i = idx[0][1]
                uv = []
                for r, i in idx:
                    u = ((i - 5) % 8) / 8.0
                    if u < ((base_i - 5) % 8) / 8.0:
                        u += 1.0
                    uv.append((u, 1.0 - r / 3.0))
                out.append(tuple(uv))
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

    # the body is rigid: exact root weight (removes stray 0.005 thigh weights on the flange)
    for v in bm.verts:
        v[dl].clear()
        v[dl][group_index["Bone"]] = 1.0

    stats = {"uv_grey_samples": 0, "uv_grey_bad": 0}
    leg_vertex_order = {}
    for side in (-1, +1):
        jverts, jworld = find_junction(bm, mw, side)
        # design in left-leg space: mirror the right junction into it
        jleft = [Vector((-w.x, w.y, w.z)) if side > 0 else w.copy() for w in jworld]
        design = LegDesign(jleft)
        groups = SIDE_GROUPS[side]
        keymap = {f"J{k}": jverts[k] for k in range(8)}
        order = []
        for key in sorted(k for k in design.pos):  # deterministic order, identical per side
            p = design.pos[key].copy()
            if side > 0:
                p.x = -p.x
            v = bm.verts.new(mwi @ p)
            keymap[key] = v
            order.append(key)
        leg_vertex_order[side] = order
        bm.verts.ensure_lookup_table()
        # weights
        for key, w in design.weights.items():
            v = keymap[key]
            v[dl].clear()
            w = {b: x for b, x in w.items() if x > PRUNE}
            s = sum(w.values())
            for b, x in w.items():
                v[dl][group_index[groups[b]]] = x / s
        # faces + UVs
        local_uvs = design.island_uvs()
        islands = {}
        for (keys, _, island), luv in zip(design.faces, local_uvs):
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

    # orientation check: a consistent recalc must not flip any face
    before = [tuple(v.index for v in f.verts) for f in bm.faces]
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
    sym_pos, sym_w = 0.0, 0.0
    for i, p in enumerate(pos):
        q, j, d = kd.find(Vector((-p.x, p.y, p.z)))
        sym_pos = max(sym_pos, d)
        wi = weights[i]
        wj = {MIRROR_GROUP.get(b, b): x for b, x in weights[j].items()}
        for b in set(wi) | set(wj):
            sym_w = max(sym_w, abs(wi.get(b, 0.0) - wj.get(b, 0.0)))
    # distant-bone influence: body verts must be root-only; legs below the junction must not use root
    body_nonroot = sum(1 for p, w in zip(pos, weights) if p.z >= 0.805 and set(w) - {"Bone"})
    leg_root = sum(1 for p, w in zip(pos, weights) if p.z < 0.70 and w.get("Bone", 0.0) > 0)
    foot_in_body = sum(1 for p, w in zip(pos, weights)
                       if p.z > 0.40 and set(w) & {"Bone.005", "Bone.006", "toe.L", "toe.R"})
    tris = sum(len(p.vertices) - 2 for p in me.polygons)
    sides = {}
    for p in me.polygons:
        sides[len(p.vertices)] = sides.get(len(p.vertices), 0) + 1
    zs = [p.z for p in pos]
    ys = [p.y for p in pos]
    xs = [p.x for p in pos]
    out = {
        "vertices": len(me.vertices), "polygons": len(me.polygons), "triangles": tris,
        "polygon_sides": {str(k): v for k, v in sorted(sides.items())},
        "materials": [m.name if m else None for m in me.materials],
        "uv_layers": [u.name for u in me.uv_layers],
        "smooth_polygons": sum(1 for p in me.polygons if p.use_smooth),
        "vertex_groups": len(ob.vertex_groups),
        "influence_histogram": {str(k): v for k, v in sorted(infl.items())},
        "max_influences": max_infl, "unweighted_vertices": unweighted,
        "max_weight_sum_error": sum_err,
        "symmetry_max_position_error_m": sym_pos, "symmetry_max_weight_error": sym_w,
        "body_vertices_with_nonroot_weight": body_nonroot,
        "leg_vertices_below_0.70_with_root_weight": leg_root,
        "foot_or_toe_weight_above_z0.40": foot_in_body,
        "world_bounds": {"x": [min(xs), max(xs)], "y": [min(ys), max(ys)], "z": [min(zs), max(zs)]},
        "modifiers": [(m.name, m.type) for m in ob.modifiers],
    }
    if arm is not None:
        out["bones"] = len(arm.data.bones)
        out["deform_bones"] = sum(1 for b in arm.data.bones if b.use_deform)
        out["actions"] = len(bpy.data.actions)
    return out


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
    faces_checked, missing, uv_dev, order_dev = 0, 0, 0.0, 0
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
    return {"body_vertices": len(mapping), "body_vertex_max_position_dev_m": max_dev,
            "body_faces_checked": faces_checked, "body_faces_missing": missing,
            "body_face_uv_max_dev": uv_dev, "body_vertex_relative_order_kept": order_kept}


# ======================================================================================
# Main
# ======================================================================================
def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    opts = {"stats": None, "texture": "//textures/Player.png", "atlas": None, "stats_only": False}
    pos = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--stats":
            opts["stats"] = argv[i + 1]; i += 2
        elif a == "--texture":
            opts["texture"] = argv[i + 1]; i += 2
        elif a == "--atlas":
            opts["atlas"] = argv[i + 1]; i += 2
        elif a == "--stats-only":
            opts["stats_only"] = True; i += 1
        else:
            pos.append(a); i += 1
    return pos, opts


def main():
    pos, opts = parse_args()
    if opts["stats_only"]:
        src, out = pos
        bpy.ops.wm.open_mainfile(filepath=os.path.abspath(src))
        st = mesh_stats(bpy.data.objects[MESH_NAME], bpy.data.objects[ARMATURE_NAME])
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
    actions_before = {a.name: sum(len(fc.keyframe_points) for fc in a.fcurves) for a in bpy.data.actions}
    rest_before = bone_rest_table(arm)
    snap = snapshot_mesh(ob)

    atlas_path = opts["atlas"]
    if atlas_path is None:
        cand = os.path.join(os.path.dirname(src), "textures", "Player.png")
        atlas_path = cand if os.path.exists(cand) else None
    atlas = read_png_rgb(atlas_path) if atlas_path else None

    report = {"source": src, "output": dst, "source_compressed": compressed}
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
    actions_after = {a.name: sum(len(fc.keyframe_points) for fc in a.fcurves) for a in bpy.data.actions}
    assert actions_after == actions_before, "actions changed"
    report["actions"] = len(actions_after)

    # texture path: relative to the saved file
    img = bpy.data.images.get("Player.png")
    if img is not None:
        img.filepath = opts["texture"]
    report["texture_path"] = img.filepath if img else None

    report["stats"] = mesh_stats(ob, arm)
    report["body_identity"] = body_identity(snap, ob)
    bi = report["body_identity"]
    assert bi["body_vertex_max_position_dev_m"] < 1e-6 and bi["body_faces_missing"] == 0 \
        and bi["body_face_uv_max_dev"] < 1e-6, f"body changed: {bi}"

    os.makedirs(os.path.dirname(dst), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=dst, compress=compressed, relative_remap=False, copy=True)
    log("saved", dst, "compressed" if compressed else "uncompressed")
    if opts["stats"]:
        with open(opts["stats"], "w") as fh:
            json.dump(report, fh, indent=1)
    st = report["stats"]
    log(f"verts {st['vertices']} polys {st['polygons']} tris {st['triangles']} "
        f"influences {st['influence_histogram']} symmetry {st['symmetry_max_position_error_m']:.2e}")


if __name__ == "__main__":
    main()

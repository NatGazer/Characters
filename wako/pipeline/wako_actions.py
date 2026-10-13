"""Wako action library -- reproducible, face-forward re-authoring pipeline.

Usage (Blender 4.5 as a Python module, or ``blender --background --python``)::

    python wako_actions.py -- in.blend out.blend [--only wk_idle,wk_assemble] [--report out.json]
                              [--pose-ref pose_ref.json]

What it does
------------
1. Asserts / applies the toe flip (idempotent): ``toe.L`` / ``toe.R`` rest matrices are pre-multiplied by a
   180 degree rotation about world Z through the ankle line, so the toes point to the face (+Y in Blender,
   model -Z in Godot).  Every other bone rest is left untouched (verified).
2. Deletes every ``wk_*`` action (and the NLA tracks that hold them) and builds the new library from the
   data-driven description in ``LIBRARY`` below: key poses with per-key tangents (anticipation, accelerating
   strokes, ballistic hops, holds <= 6 f, exponential ease-outs, overlap), procedural gait cycles for the
   locomotion loops, and additive layers (support weight envelope, breathing, effort tremor, dance stance).
3. Every frame is solved in ARMATURE space: root translation/rotation for body acting, analytic two-bone
   leg IK (hip -> knee -> ankle) with the knee plane derived from the body's sagittal plane (knees always
   bend toward the face, +Y, and turn upward for raised legs: no pole flips), explicit foot orientation
   (heel / ball pivots for grounded rolls), toe articulation, and a seated floor contact for the sit family
   (the bottom rests on the ground for the current pitch/roll).  The solved pose is converted to local bone
   channels (location + rotation_quaternion) relative to the CURRENT rest, so the library survives rest
   changes that keep the bone names.
4. Actions are written exportable for the glTF exporter used by Godot's .blend importer: one slot
   (OBJECT, ``OBwako_art``), bone-name data paths only, fake user, one muted NLA track per action (the
   structure of the original file), ``wk_idle`` active (re-assigned after the round-trip check), scene range
   starting at frame 0 so frame 0 is exported, image paths kept exactly as in the input
   (``relative_remap=False``).  No constraints, helper bones or control rigs are created.
5. Verification report (stdout + optional JSON): durations, loop flags, support-foot slip on planted
   frames, sole penetration, IK over-reach, knee direction, knee angle jumps, body clearance, loop seams,
   L/R mirror error, work-clip weight timing (shift accepted >= 3 f before the lift, held while airborne,
   released after the plant), fore-aft balance + downward acceleration + bottom touchdown speed for the
   unsided clips, the work foot's authored contact pose, the sit family's seat-descent curve, bone rests vs
   input.  ``--pose-ref`` writes every frame's bone heads (Godot skeleton space) for the Godot-side
   per-frame comparison (harness/scripts/clip_inventory.gd --ref=...).

Conventions (armature space, Blender): +Y = face (Godot model -Z = runtime forward), +Z = up,
+X = Wako's right.  Left leg = Bone.001 chain at x = -0.237.  Frames are 30 fps.

Runtime contract notes (for the integrator)
-------------------------------------------
* Names/durations/loops follow INTEGRATION_NOTES "Clip timing contract migration".  No method/event keys are
  authored; the runtime still adds the single 0.56 contact key to work/* clones.  Every work clip lands its
  visual contact (impact / touch / grip / give / press / plant) exactly at 0.56 * length, starts and ends in
  the shared neutral planted stance (wk_tool_change ends with the toe still curled -24 deg round the fetched
  handle -- the held-tool state -- everything else neutral), accepts the weight on the support leg >= 3 f
  before the work heel peels, holds it while the work foot is off the ground, and gives it back only after
  the work foot has planted (heel first) >= 4 f before the end.
* The Godot import must keep the AnimationPlayer key optimizer OFF (Wako.blend.import
  ``_subresources/nodes/PATH:AnimationPlayer/optimizer/enabled = false``): with it on, single-frame pops of
  up to 6 cm appear (cheer, dance landings); with it off every frame matches Blender within 0.001 mm.
* The report records ``contact_pose`` per work clip (work ankle, toe tip, toe direction, hip, in Godot MODEL
  space at the 0.56 event).  Retarget the authored stroke relative to it (target = contact +
  (authored - authored_contact) * w) instead of the old fixed .10-.43 / .78 envelope, otherwise the draw /
  rebound / ease-out are flattened into a hold.  WORK_TIMING in wako_pose.gd re-times assemble/inspect/repair;
  these clips already carry their timing, so that remap should become identity for them.
* Locomotion loops (walk 24 f, run 16 f, carry 20 f) put the LEFT contact at phase 0.0 and the RIGHT contact
  at 0.5, carry only subtle root bob/lean (the procedural gait owns it) and are in place (treadmill feet).
* wk_idle keeps its name (coordinator settle gate); its root acting (irregular breaths, weight shift each
  way, glances, curiosity lean) is what shows under the gait IK.
* wk_step ends with the root advanced 0.12 m; wk_sit_up ends advanced ~0.30 m over the pulled-in feet.
* Seat descent ownership: wk_sit_down / wk_sit_idle / wk_sit_up carry the FULL seat descent in root Z so they
  are complete on their own (bottom on the ground, ~-0.80 m).  The report's ``seat_descent_m`` is that curve
  per frame; it is built for a native spring to follow (one continuous descent, <= 1 g downward while the
  legs carry the body; rise with a <= 1 g deceleration).  Recommended: drive the native ``seat_drop`` from
  this curve and subtract the body's ACTUAL drop from the visual root (root keeps pitch/yaw/x/y), so the
  visual and physical bottoms agree; do not add a second descent on top.
* wk_sit_down: the heels skid forward on purpose while the bottom takes the weight (f25-32, bottom <= 14 cm
  up, reported as ``authored_slide`` instead of slip); the sumo squat and the rise put the knees up and out
  beside the body (knee-forward metric ~0.5: knees point up/out, never backward).
* wk_swim legs are authored in the BODY frame (they follow the 20 deg back-pitched body); the root stays at
  rest height (buoyancy owns the native body) apart from a 2.5 cm surge per stroke.
* wk_dance_a contains one 360 deg root-yaw spin (two ballistic hops landing on 7-and and beat 8) and ends at
  the start orientation.
"""

import argparse
import json
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

# ======================================================================================
# Rig constants (names are the runtime contract; geometry is read from the file)
# ======================================================================================
FPS = 30
ARMATURE = "wako_art"
ROOT = "Bone"
LEGS = {
    "L": ("Bone.001", "Bone.003", "Bone.005", "toe.L"),
    "R": ("Bone.002", "Bone.004", "Bone.006", "toe.R"),
}
SIDE_X = {"L": -1.0, "R": 1.0}          # sign of each hip's armature X
TOE_BONES = ("toe.L", "toe.R")
ANKLE_TO_SOLE = 0.116                   # runtime contract (wako_pose._ankle_height)
HEEL_Y, BALL_Y = -0.065, 0.075          # sole pivots relative to the ankle (forward = +Y)
SOLE_DROP = ANKLE_TO_SOLE

# Neutral stance shared by most clips (root offset from rest, degrees for angles)
Z0 = -0.026          # neutral root dip (knees ~28 deg)
P0 = 2.0             # neutral forward pitch (face slightly down / alert)
STANCE_O = 0.19      # neutral foot distance from the midline (hips are at 0.237)


# ======================================================================================
# Curves: per-key tangents, cubic Hermite, auto-clamped (no overshoot), periodic for loops
# ======================================================================================
def _tan_codes(spec):
    """Tangent spec -> (in, out).  'a' auto-clamped, 'f' flat, 'l' linear, 'h' half, a digit or number =
    multiple of the side's secant slope (e.g. '2f': accelerate into the key at 2x the secant, stop after it).
    A 2-tuple gives (in, out) codes explicitly, e.g. (2.4, 'f')."""
    if spec is None or spec == "":
        return "a", "a"
    if isinstance(spec, (tuple, list)):
        return spec[0], spec[1]
    if isinstance(spec, (int, float)):
        return spec, spec
    if len(spec) == 1:
        return spec, spec
    return spec[0], spec[1]


def _tan_value(code, delta_side, auto):
    if isinstance(code, (int, float)):
        return float(code) * delta_side
    if code == "a":
        return auto
    if code == "f":
        return 0.0
    if code == "l":
        return delta_side
    if code == "h":
        return 0.5 * delta_side
    if code.isdigit():
        return float(code) * delta_side
    raise ValueError("bad tangent code %r" % code)


class Spline:
    """Scalar channel.  keys: list of (t, value, tangent_spec).  period=N makes it cyclic on [0, N)."""

    def __init__(self, keys, period=None):
        ks = sorted(keys, key=lambda k: k[0])
        if period is not None:
            # drop a duplicate end key at t == period (must match t == 0 if both given)
            if len(ks) > 1 and abs(ks[-1][0] - period) < 1e-6:
                if abs(ks[0][0]) < 1e-6 and abs(ks[0][1] - ks[-1][1]) > 1e-6:
                    raise ValueError("loop channel end key differs from start key: %r vs %r" % (ks[0], ks[-1]))
                last = ks.pop()
                if abs(ks[0][0]) > 1e-6:
                    ks.insert(0, (0.0, last[1], last[2]))
        self.period = period
        self.t = [float(k[0]) for k in ks]
        self.v = [float(k[1]) for k in ks]
        self.codes = [_tan_codes(k[2] if len(k) > 2 else None) for k in ks]
        n = len(ks)
        self.mi = [0.0] * n
        self.mo = [0.0] * n
        if n == 1:
            return
        for i in range(n):
            tl, vl, tr, vr = self._neighbors(i)
            dl = None if tl is None else (self.v[i] - vl) / (self.t[i] - tl)
            dr = None if tr is None else (vr - self.v[i]) / (tr - self.t[i])
            if dl is None or dr is None:
                auto = 0.0
            elif dl * dr <= 0.0:
                auto = 0.0
            else:
                auto = (vr - vl) / (tr - tl)
                lim = 3.0 * min(abs(dl), abs(dr))
                auto = max(-lim, min(lim, auto))
            ci, co = self.codes[i]
            self.mi[i] = _tan_value(ci, dl if dl is not None else 0.0, auto)
            self.mo[i] = _tan_value(co, dr if dr is not None else 0.0, auto)

    def _neighbors(self, i):
        n = len(self.t)
        if self.period is None:
            tl = self.t[i - 1] if i > 0 else None
            vl = self.v[i - 1] if i > 0 else None
            tr = self.t[i + 1] if i < n - 1 else None
            vr = self.v[i + 1] if i < n - 1 else None
            return tl, vl, tr, vr
        P = self.period
        tl = self.t[i - 1] if i > 0 else self.t[-1] - P
        vl = self.v[i - 1]
        tr = self.t[i + 1] if i < n - 1 else self.t[0] + P
        vr = self.v[(i + 1) % n]
        return tl, vl, tr, vr

    def __call__(self, t):
        n = len(self.t)
        if n == 1:
            return self.v[0]
        if self.period is not None:
            P = self.period
            t = t % P
            if t < self.t[0]:
                t += P
            # segment search (with the wrap segment last -> first + P)
            for i in range(n):
                t0 = self.t[i]
                t1 = self.t[i + 1] if i < n - 1 else self.t[0] + P
                if t0 - 1e-9 <= t <= t1 + 1e-9:
                    j = (i + 1) % n
                    return _hermite(t, t0, self.v[i], self.mo[i], t1, self.v[j], self.mi[j])
            return self.v[0]
        if t <= self.t[0]:
            return self.v[0]
        if t >= self.t[-1]:
            return self.v[-1]
        lo, hi = 0, n - 1
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if self.t[mid] <= t:
                lo = mid
            else:
                hi = mid
        return _hermite(t, self.t[lo], self.v[lo], self.mo[lo], self.t[hi], self.v[hi], self.mi[hi])


def _hermite(t, t0, v0, m0, t1, v1, m1):
    h = t1 - t0
    u = (t - t0) / h
    u2 = u * u
    u3 = u2 * u
    return ((2 * u3 - 3 * u2 + 1) * v0 + (u3 - 2 * u2 + u) * h * m0 +
            (-2 * u3 + 3 * u2) * v1 + (u3 - u2) * h * m1)


def smooth(e0, e1, x):
    if e1 == e0:
        return 1.0 if x >= e1 else 0.0
    x = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return x * x * (3 - 2 * x)


def min_jerk(x):
    x = max(0.0, min(1.0, x))
    return x * x * x * (10 + x * (-15 + 6 * x))


def K(f, tan=None, **ch):
    """A key row: frame, optional tangent code for every channel in the row, channel values.
    A value may be a (value, tangent) tuple to override the row tangent for that channel."""
    return (f, tan, ch)


# ======================================================================================
# Rig and solver
# ======================================================================================
def _rot_root(pitch_fd, roll_r, yaw_r):
    """pitch + = face down; roll + = top tilts toward +X (Wako's right); yaw + = turns to Wako's right."""
    rz = Matrix.Rotation(math.radians(-yaw_r), 3, "Z")
    rx = Matrix.Rotation(math.radians(-pitch_fd), 3, "X")
    ry = Matrix.Rotation(math.radians(roll_r), 3, "Y")
    return rz @ rx @ ry


def _rot_foot(s, pitch_up, yaw_out, roll_out):
    """Foot frame: pitch + = toe up, yaw + = toe outward, roll + = outer edge up.  s = side sign."""
    rz = Matrix.Rotation(math.radians(-s * yaw_out), 3, "Z")
    rx = Matrix.Rotation(math.radians(pitch_up), 3, "X")
    ry = Matrix.Rotation(math.radians(-s * roll_out), 3, "Y")
    return rz @ rx @ ry


def _cols(a, b, c):
    return Matrix((a, b, c)).transposed()


class Rig:
    def __init__(self, arm):
        bones = arm.data.bones
        for name in [ROOT] + [b for s in "LR" for b in LEGS[s]]:
            if name not in bones:
                raise RuntimeError("missing bone %s" % name)
        self.arm = arm
        self.rest = {b.name: b.matrix_local.copy() for b in bones}
        self.rest_inv = {n: m.inverted() for n, m in self.rest.items()}
        self.parent = {b.name: (b.parent.name if b.parent else None) for b in bones}
        self.order = [ROOT]
        for s in "LR":
            self.order += list(LEGS[s])
        self.rest_rot4 = {n: m.to_3x3().to_4x4() for n, m in self.rest.items()}
        self.head0 = self.rest[ROOT].translation.copy()
        self.leg = {}
        for s in "LR":
            th, sh, an, toe = LEGS[s]
            hip = self.rest[th].translation.copy()
            knee = self.rest[sh].translation.copy()
            ankle = self.rest[an].translation.copy()
            a = (knee - hip).length
            b = (ankle - knee).length
            seg0 = (knee - hip).normalized()
            seg1 = (ankle - knee).normalized()
            if seg0.z > -0.999 or seg1.z > -0.999:
                raise RuntimeError("leg %s rest is not vertical; solver assumes straight vertical rest legs" % s)
            lat0 = Vector((1.0, 0.0, 0.0))
            frame0 = _cols(lat0, seg0, lat0.cross(seg0))
            self.leg[s] = dict(hip=hip, ankle=ankle, a=a, b=b, frame0_t=frame0.transposed(),
                               toe_rel=self.rest_inv[an] @ self.rest[toe])
        self.ankle_z = sum(self.leg[s]["ankle"].z for s in "LR") / 2.0
        self.ground_z = self.ankle_z - ANKLE_TO_SOLE

    # --------------------------------------------------------------------------------
    def solve(self, P, t=None, spin=None):
        """P: {'root': {...}, 'L': {...}, 'R': {...}} -> (pose matrices, diagnostics)."""
        rv = P["root"]
        R = _rot_root(rv["p"] + rv["p2"], rv["r"] + rv["r2"], rv["w"] + rv["w2"])
        pos = Vector((rv["x"], rv["y"], rv["z"] + rv["z2"]))
        root_pose = Matrix.Translation(self.head0 + pos) @ R.to_4x4() @ self.rest_rot4[ROOT]
        D = root_pose @ self.rest_inv[ROOT]
        poses = {ROOT: root_pose}
        diag = {"root": root_pose, "legs": {}}
        Rq = R.to_quaternion()
        for s in "LR":
            th, sh, an, toe = LEGS[s]
            L = self.leg[s]
            fv = P[s]
            sx = SIDE_X[s]
            H = D @ L["hip"]
            # foot frame and ankle target (world/armature frame)
            Rf = _rot_foot(sx, fv["p"], fv["w"], fv["r"])
            A = Vector((sx * fv["o"], fv["y"], self.ankle_z + fv["h"]))
            g = fv["g"]
            if g > 0.0 and abs(fv["p"]) > 1e-6:
                piv_y = BALL_Y if fv["p"] < 0.0 else HEEL_Y
                rel = Vector((0.0, -piv_y, SOLE_DROP))           # pivot -> ankle in the flat foot frame
                rflat = _rot_foot(sx, 0.0, fv["w"], 0.0)
                pivot = A - rflat @ rel
                A = A + g * ((pivot + Rf @ rel) - A)
            if spin is not None:
                ang, cx, cy = spin
                rs = Matrix.Rotation(math.radians(-ang), 3, "Z")
                c = Vector((cx, cy, 0.0))
                A = c + rs @ (A - c)
                Rf = rs @ Rf
            bw = fv["bw"]
            if bw > 0.0:
                Ab = D @ A
                Rb = R @ Rf
                A = A.lerp(Ab, bw)
                Rf = Rf.to_quaternion().slerp(Rb.to_quaternion(), bw).to_matrix()
            # knee pole: body sagittal plane, rotated 90 deg from the leg (forward for a hanging leg,
            # up for a leg raised forward, down-forward for a leg reaching behind) + outward splay
            dl = R.transposed() @ (A - H)
            ds = Vector((0.0, dl.y, dl.z))
            if ds.length < 1e-6:
                ds = Vector((0.0, 0.0, -1.0))
            ds.normalize()
            anat = Vector((0.0, -ds.z, ds.y))
            pole_l = anat + math.tan(math.radians(fv["k"])) * Vector((sx, 0.0, 0.0))
            pole = R @ pole_l
            K_, A2, over, dirv, pp = _two_bone(H, A, pole, L["a"], L["b"])
            lat = dirv.cross(pp).normalized()
            yt = (K_ - H).normalized()
            ys = (A2 - K_).normalized()
            Mt = _cols(lat, yt, lat.cross(yt)) @ L["frame0_t"]
            Ms = _cols(lat, ys, lat.cross(ys)) @ L["frame0_t"]
            poses[th] = Matrix.Translation(H) @ Mt.to_4x4() @ self.rest_rot4[th]
            poses[sh] = Matrix.Translation(K_) @ Ms.to_4x4() @ self.rest_rot4[sh]
            poses[an] = Matrix.Translation(A2) @ Rf.to_4x4() @ self.rest_rot4[an]
            poses[toe] = poses[an] @ L["toe_rel"] @ Matrix.Rotation(math.radians(fv["t"]), 4, "X")
            # diagnostics
            heel = A2 + Rf @ Vector((0.0, HEEL_Y, -SOLE_DROP))
            ball = A2 + Rf @ Vector((0.0, BALL_Y, -SOLE_DROP))
            line = (A2 - H).normalized()
            koff = (K_ - H) - line * (K_ - H).dot(line)
            flex = math.degrees(math.pi - math.acos(max(-1.0, min(1.0, (K_ - H).normalized().dot((K_ - A2).normalized())))))
            diag["legs"][s] = dict(H=H, K=K_, A=A2, over=over, heel=heel, ball=ball, koff=koff,
                                   fwd=R @ Vector((0.0, 1.0, 0.0)), pole=pole.normalized(), lat=lat, flex=flex,
                                   pitch=fv["p"], toe_tip=(poses[toe] @ Matrix.Translation((0.0, 0.13, 0.0))).translation)
        return poses, diag

    def seat_z(self, rv, eps=0.002):
        """Root z offset at which the lowest bottom corner of the body touches the ground (+eps)."""
        R = _rot_root(rv["p"] + rv["p2"], rv["r"] + rv["r2"], rv["w"] + rv["w2"])
        low = min((R @ Vector((sx * BODY_HALF[0], sy * BODY_HALF[1], BODY_Z[0]))).z
                  for sx in (-1, 1) for sy in (-1, 1))
        return self.ground_z + eps - self.head0.z - low

    def local_channels(self, poses):
        out = {}
        for name in self.order:
            par = self.parent[name]
            base = self.rest[name] if par is None else poses[par] @ self.rest_inv[par] @ self.rest[name]
            basis = base.inverted() @ poses[name]
            loc, rot, sca = basis.decompose()
            if abs(sca.x - 1) > 1e-3 or abs(sca.y - 1) > 1e-3 or abs(sca.z - 1) > 1e-3:
                raise RuntimeError("non-unit scale on %s: %r" % (name, sca))
            rot.normalize()
            out[name] = (loc, rot)
        return out


def _two_bone(H, A, pole, a, b):
    D = A - H
    d = D.length
    dirv = D.normalized() if d > 1e-9 else Vector((0.0, 0.0, -1.0))
    dmax = a + b - 1e-4
    dmin = abs(a - b) + 1e-3
    over = max(0.0, d - dmax)
    d = max(dmin, min(dmax, d))
    A2 = H + dirv * d
    ca = (a * a + d * d - b * b) / (2 * a * d)
    ca = max(-1.0, min(1.0, ca))
    sa = math.sqrt(max(0.0, 1 - ca * ca))
    pp = pole - dirv * pole.dot(dirv)
    if pp.length < 1e-6:
        pp = Vector((0.0, 1.0, 0.0)) - dirv * dirv.y
    pp.normalize()
    Kp = H + a * (ca * dirv + sa * pp)
    return Kp, A2, over, dirv, pp


# ======================================================================================
# Clip description
# ======================================================================================
ROOT_DEF = dict(x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0, z2=0.0, p2=0.0, r2=0.0, w2=0.0)
FOOT_DEF = dict(o=STANCE_O, y=0.0, h=0.0, p=0.0, w=5.0, r=0.0, t=0.0, k=6.0, bw=0.0, g=0.0)


class Clip:
    """One authored clip (or an L/R pair when sided).

    Rows are K(frame, tangent, **channels).  Root channels: x (unsided, + = Wako's right) or u (sided,
    + = toward the work side), y (+ forward), z (offset from rest), p (pitch, + face down), r (roll;
    unsided: + toward Wako's right; sided: + toward the support leg), w (yaw; unsided: + to Wako's right;
    sided: + toward the work side), and additive z2/p2/r2/w2 layers.
    Feet groups: unsided 'L'/'R', sided 'W' (work) / 'S' (support).  Foot channels: o (distance from the
    midline, + outward), y, h (ankle lift above standing height), p (foot pitch, + toe up), w (toe out),
    r (outer edge up), t (toe curl, + up / - grip), k (knee outward splay deg), g (0..1 heel/ball ground
    pivot for grounded rolls), bw (0..1 foot target follows the body frame: swimming, airborne tucks).
    """

    def __init__(self, name, seconds, loop=False, sided=False, contact=None, notes="", root=(), feet=None,
                 layers=None, proc=None, spin=None, slides=None, seat=None):
        self.name = name
        self.frames = int(round(seconds * FPS))
        assert abs(self.frames / FPS - seconds) < 0.02, name
        self.seconds = self.frames / FPS
        self.loop = loop
        self.sided = sided
        self.contact = contact
        self.notes = notes
        self.root_rows = list(root)
        self.feet_rows = feet or {}
        self.layers = layers or []
        self.proc = proc
        self.spin = Spline(spin) if spin else None   # feet rotation (deg, + = to Wako's right) about the root
        self.treadmill = None                         # expected stance-foot y step per frame (gait loops)
        # authored, UNWEIGHTED sole slides {leg: (f0, f1)} (e.g. the heels skidding forward while the bottom
        # takes the weight in the sit-down): excluded from the support-slip metric, reported separately
        self.slides = slides or {}
        # seated frames (t0, t1): the bottom is a floor contact there -- the root is raised just enough that the
        # lowest body corner rests on the ground for the current pitch/roll (rolls on its edges for free), while
        # authored lifts above it (settle bump) are kept
        self.seat = seat

    def variants(self):
        if self.sided:
            return [(self.name + "_L", "L"), (self.name + "_R", "R")]
        return [(self.name, None)]


def _build_splines(rows, period, label="", defaults=None):
    chans = {}
    for f, tan, ch in rows:
        for k, v in ch.items():
            if isinstance(v, tuple):
                val, tcode = v
            else:
                val, tcode = v, tan
            chans.setdefault(k, []).append((f, val, tcode))
    out = {}
    for k, keys in chans.items():
        ts = sorted(round(x[0], 6) for x in keys)
        dup = [a for a, b in zip(ts, ts[1:]) if abs(a - b) < 1e-6]
        if dup:
            raise ValueError("%s channel %s has duplicate keys at %r" % (label, k, dup))
        if period is None and defaults is not None:
            # a non-looping channel holds its first key's value before that key: it must either be keyed at
            # frame 0 or start from the default, otherwise frame 0 silently differs from the shared neutral
            k0 = min(keys, key=lambda x: x[0])
            if k0[0] > 1e-6 and abs(k0[1] - defaults.get(k, 0.0)) > 1e-6:
                raise ValueError("%s channel %s: first key at f%s (%r) but no frame-0 key and it differs from "
                                 "the default %r" % (label, k, k0[0], k0[1], defaults.get(k, 0.0)))
        out[k] = Spline(keys, period)
    return out


class Evaluator:
    def __init__(self, clip, side):
        self.clip = clip
        self.side = side                    # None (unsided) or 'L'/'R' (work foot)
        N = clip.frames
        period = N if clip.loop else None
        self.N = N
        self.root = _build_splines(clip.root_rows, period, clip.name + ".root", ROOT_DEF)
        if clip.sided:
            work, sup = side, ("R" if side == "L" else "L")
            self.feet = {work: _build_splines(clip.feet_rows.get("W", []), period, clip.name + ".W", FOOT_DEF),
                         sup: _build_splines(clip.feet_rows.get("S", []), period, clip.name + ".S", FOOT_DEF)}
            self.sigma = SIDE_X[side]
        else:
            self.feet = {s: _build_splines(clip.feet_rows.get(s, []), period, clip.name + "." + s, FOOT_DEF)
                         for s in "LR"}
            self.sigma = None

    def values(self, t):
        rv = dict(ROOT_DEF)
        for k, sp in self.root.items():
            rv[k] = sp(t)
        if self.sigma is not None:
            sg = self.sigma
            u = rv.pop("u", 0.0)
            rv["x"] = rv.get("x", 0.0) + sg * u
            rv["r"] = -sg * rv["r"]
            rv["r2"] = -sg * rv["r2"]
            rv["w"] = sg * rv["w"]
            rv["w2"] = sg * rv["w2"]
        P = {"root": rv}
        for s in "LR":
            fv = dict(FOOT_DEF)
            for k, sp in self.feet[s].items():
                fv[k] = sp(t)
            P[s] = fv
        for fn in self.clip.layers:
            fn(t, P, self)
        if self.clip.proc is not None:
            self.clip.proc(t, P, self)
        return P

    def spin_at(self, t, P):
        """Feet follow a turn only while airborne (keys flat on the ground between hops)."""
        if self.clip.spin is None:
            return None
        ang = self.clip.spin(t)
        if self.sigma is not None:
            ang *= self.sigma
        return (ang, P["root"]["x"], P["root"]["y"])


# --------------------------------------------------------------------------------------
# Layer helpers (additive)
# --------------------------------------------------------------------------------------
def tremor(chan, amp, period_f, t0, t1, ramp=3.0, phase=0.0):
    """Effort tremor on a root additive channel ('p2', 'r2', 'z2', 'w2'): sinusoid sampled cleanly
    at 30 fps (period in frames), faded in/out over `ramp` frames."""
    def fn(t, P, ev):
        env = smooth(t0, t0 + ramp, t) * (1.0 - smooth(t1 - ramp, t1, t))
        P["root"][chan] += amp * env * math.sin(2 * math.pi * (t / period_f) + phase)
    return fn


def foot_tremor(group, chan, amp, period_f, t0, t1, ramp=3.0, phase=0.0):
    def fn(t, P, ev):
        if ev.clip.sided:
            leg = ev.side if group == "W" else ("R" if ev.side == "L" else "L")
        else:
            leg = group
        env = smooth(t0, t0 + ramp, t) * (1.0 - smooth(t1 - ramp, t1, t))
        P[leg][chan] += amp * env * math.sin(2 * math.pi * (t / period_f) + phase)
    return fn


def weight_shift(t_full, lift, plant, end, u=-0.085, r=4.0, z=-0.018, over=0.10, ret_over=0.07, t0=0.0):
    """Support acceptance / release envelope for sided work clips (additive on the root).

    0 -> 1 (+overshoot) between t0 and t_full: the body slides over the support foot (u, + = toward the
    work side), rolls over it (r, + = toward the support) and the support knee dips (z).  The weight is HELD
    while the work foot is off the ground and released only after the work foot plants (plant -> end, with
    a small overshoot past neutral and a settle).  The work foot must lift >= 2 f after t_full (so the shift
    is visibly accepted >= 3 f before the lift) and plant >= 4 f before the end."""
    assert lift >= t_full + 1.5 and end - plant >= 3.5, (t_full, lift, plant, end)
    hold = min(t_full + 2.0, lift)
    sp = Spline([(t0, 0.0, "f"), (t_full, 1.0 + over, "f"), (hold, 1.0, "f"), (plant, 1.0, "f"),
                 (plant + 0.62 * (end - plant), -ret_over), (end, 0.0, "f")])

    def fn(t, P, ev):
        e = sp(t)
        rv = P["root"]
        sg = ev.sigma
        rv["x"] += sg * u * e
        rv["r"] += -sg * r * e
        rv["z"] += z * e
    fn.weight = dict(t_full=t_full, lift=lift, plant=plant, end=end, u=u, r=r, z=z)
    return fn


# ======================================================================================
# Locomotion cycles (procedural gait; left contact at phase 0, right at 0.5)
# ======================================================================================
def gait_proc(cfg):
    N = cfg["frames"]
    duty = cfg["duty"]
    yc, yt = cfg["yc"], cfg["yt"]
    lift = cfg["lift"]
    lift_exp = cfg.get("lift_exp", 0.8)

    def foot(p):
        if p < duty:
            q = p / duty
            y = yc - (yc + yt) * q
            pitch = cfg["heel"] * (1.0 - smooth(0.0, cfg.get("flat_at", 0.25), q)) \
                - cfg["push"] * smooth(cfg.get("push_from", 0.55), 1.0, q)
            toe = cfg["toe_push"] * smooth(0.6, 1.0, q)
            return dict(y=y, h=0.0, p=pitch, g=1.0, t=toe)
        q = (p - duty) / (1.0 - duty)
        s = min_jerk(q)
        reach = cfg.get("reach", 0.0) * math.sin(math.pi * min(1.0, q / 0.92)) * smooth(0.55, 0.85, q)
        y = -yt + (yc + yt) * s + reach
        h = lift * math.sin(math.pi * (q ** lift_exp)) ** 1.5
        pitch = (-cfg["push"] * (1.0 - smooth(0.0, 0.35, q))
                 + cfg["swing_up"] * math.sin(math.pi * smooth(0.25, 0.95, q)) * (1.0 - smooth(0.8, 1.0, q))
                 + cfg["heel"] * smooth(0.75, 1.0, q))
        g = (1.0 - smooth(0.0, 0.3, q)) + smooth(0.85, 1.0, q)
        toe = cfg["toe_push"] * (1.0 - smooth(0.0, 0.3, q)) + cfg["toe_swing"] * math.sin(math.pi * q)
        return dict(y=y, h=h, p=pitch, g=min(1.0, g), t=toe)

    def proc(t, P, ev):
        phi = (t / N) % 1.0
        for leg, off in (("L", 0.0), ("R", 0.5)):
            p = (phi - off) % 1.0
            v = foot(p)
            P[leg].update(v)
            P[leg]["o"] = cfg["o"]
            P[leg]["w"] = cfg.get("toe_out", 4.0)
            P[leg]["k"] = cfg.get("knee_out", 6.0)
        rv = P["root"]
        bp = cfg["bob_low"]
        rv["z"] = cfg["z0"] - cfg["bob"] * math.cos(2 * math.pi * 2 * (phi - bp))
        rv["p"] = cfg["pitch"] + cfg.get("pitch_amp", 0.0) * math.cos(2 * math.pi * 2 * (phi - bp))
        rv["r"] = -cfg["roll"] * math.cos(2 * math.pi * (phi - duty / 2.0))
        rv["w"] = cfg["yaw"] * math.cos(2 * math.pi * phi)
        rv["x"] = -cfg.get("sway", 0.0) * math.cos(2 * math.pi * (phi - duty / 2.0))
        rv["y"] = 0.0
    return proc


WALK = dict(frames=24, duty=0.60, yc=0.22, yt=0.22, lift=0.075, o=0.175, z0=-0.046, bob=0.006,
            bob_low=2.0 / 24.0, pitch=3.0, pitch_amp=0.4, roll=1.6, yaw=2.2, sway=0.008, heel=9.0,
            push=22.0, push_from=0.6, toe_push=14.0, toe_swing=-6.0, swing_up=10.0, reach=0.015,
            toe_out=4.0)
RUN = dict(frames=16, duty=0.34, yc=0.30, yt=0.315, lift=0.30, lift_exp=0.62, o=0.165, z0=-0.088,
           bob=0.012, bob_low=0.17, pitch=6.0, pitch_amp=1.0, roll=2.4, yaw=3.5, sway=0.010, heel=6.0,
           push=26.0, push_from=0.45, flat_at=0.2, toe_push=18.0, toe_swing=-10.0, swing_up=18.0, reach=0.02,
           toe_out=3.0)
CARRY = dict(frames=20, duty=0.52, yc=0.26, yt=0.26, lift=0.07, o=0.205, z0=-0.078, bob=0.005,
             bob_low=1.0 / 20.0, pitch=1.0, pitch_amp=0.25, roll=1.0, yaw=1.2, sway=0.006, heel=6.0,
             push=16.0, push_from=0.62, toe_push=10.0, toe_swing=-5.0, swing_up=8.0, reach=0.01,
             toe_out=6.0)


# ======================================================================================
# THE LIBRARY  (frames at 30 fps; C = contact frame = 0.56 * length for work clips)
# ======================================================================================
def C_of(seconds):
    return round(0.56 * seconds * FPS, 2)


LIBRARY = []


def clip(*a, **kw):
    c = Clip(*a, **kw)
    LIBRARY.append(c)
    return c


# ---------------------------------------------------------------- wk_idle (4.0 s loop)
clip("wk_idle", 4.0, loop=True, notes="alert idle: irregular breaths, one weight shift each way with "
     "overshoot, glances, a curiosity lean, an unweighted heel-lift fidget; feet planted, never symmetric",
     root=[
         K(0, x=0.012, z=-0.024, p=2.0, r=2.0, w=0.0),
         K(9, w=0.0),
         K(15, w=-4.2),                       # glance left: eyes lead (runtime), body follows
         K(26, z=-0.024),
         K(29, z=-0.0272),                    # micro settle (knee re-bend)
         K(33, z=-0.0245),
         K(37, x=0.012, r=2.0, w=-3.5),
         K(52, w=-3.1),
         K(57, x=-0.018, r=-2.7),             # weight onto the left leg, overshoot
         K(65, x=-0.015, r=-2.1, w=-0.6),
         K(70, p=2.0),
         K(80, p=4.6),                        # curiosity lean in
         K(88, x=-0.015, r=-2.1, w=0.8),
         K(92, p=4.2),
         K(99, w=3.1, p=2.6),                 # glance right
         K(107, x=0.015, r=2.5),              # weight back to the right leg, overshoot
         K(112, w=2.6),
         K(115, x=0.012, r=2.0),
     ] + [
         K(0, z2=0.0, p2=0.0), K(23, z2=0.0045, p2=-0.35), K(55, z2=-0.0005, p2=0.05),
         K(82, z2=0.0052, p2=-0.4), K(108, z2=0.0, p2=0.0),
     ],
     feet={
         "L": [K(0, o=0.175, y=0.045, w=9.0, g=1.0, t=0.0), K(18, t=0.0), K(21, t=10.0), K(25, t=-3.0),
               K(29, t=0.0)],
         "R": [K(0, o=0.19, y=-0.012, w=5.0, g=1.0, p=0.0, t=0.0), K(64, p=0.0, t=0.0),
               K(68, p=-13.0), K(71, p=-15.5, t=9.0), K(75, p=0.0, t=-4.0, tan="f"), K(80, t=0.0)],
     })

# ---------------------------------------------------------------- locomotion loops
def gait_clip(name, cfg, notes):
    c = clip(name, cfg["frames"] / 30.0, loop=True, notes=notes, proc=gait_proc(cfg))
    c.treadmill = -(cfg["yc"] + cfg["yt"]) / (cfg["duty"] * cfg["frames"])
    return c


gait_clip("wk_walkcycle", WALK, "springy bent-knee walk; heel strike -> flat -> toe roll; "
          "L contact at 0.0, R at 0.5; subtle root (gait owns bob/lean)")
gait_clip("wk_run", RUN, "job run 16 f: 5.4 f stance + 2.6 f flight per step, knee drive, "
          "trailing foot tucks high; L contact 0.0, R 0.5")
gait_clip("wk_carry", CARRY, "loaded grounded jog 20 f (no flight), level steady body, "
          "deeper knees, wider track; L contact 0.0, R 0.5")

# ---------------------------------------------------------------- wk_danger (1.0 s loop)
clip("wk_danger", 1.0, loop=True, notes="wary crouch on the balls of the feet, staggered stance; two DIFFERENT "
     "looks per loop (a 2 f snap right with overshoot and a short settle, then a slower 4-5 f smaller look left "
     "with a longer settle), ready bounces, a one-foot shuffle (weight onto R, the L heel lifts and re-grips), "
     "fear tremor",
     root=[
         K(0, x=0.0, y=-0.02, z=-0.096, p=-3.0, r=0.0, w=0.0),
         K(2, w=13.5, r=1.6, z=-0.101, tan="l"),          # snap right (2 f)
         K(3, w=15.2),                                    # overshoot
         K(5, w=13.0, z=-0.098),
         K(8, z=-0.090, w=12.6),                          # ready bounce
         K(10, z=-0.095, w=12.0),
         K(12.5, w=10.5, r=1.0),
         K(17, w=-7.0, r=-1.0, z=-0.100, x=0.0),          # slower, smaller look left (4.5 f)
         K(18.5, w=-8.2, x=0.020, r=1.6),                 # weight onto R ...
         K(21, z=-0.093),
         K(23.5, w=-6.8, x=0.022, r=1.8),                 # ... while the L heel re-grips
         K(25.5, x=0.004, r=0.4, z=-0.097),
         K(28, w=-2.0, r=0.0),
         K(30, x=0.0, y=-0.02, z=-0.096, p=-3.0, r=0.0, w=0.0),
     ],
     layers=[tremor("p2", 0.45, 4.0, -10, 40, ramp=0.1), tremor("r2", 0.3, 5.0, -10, 40, ramp=0.1, phase=1.0)],
     feet={
         "L": [K(0, o=0.25, y=0.07, w=12.0, g=1.0, t=-15.0, k=10.0, p=-6.0), K(6, p=-6.0), K(9, p=-10.0),
               K(12, p=-6.0, t=-15.0), K(18.5, p=-6.0, t=-15.0), K(21, p=-22.0, t=-28.0),
               K(23, p=-18.0, t=-22.0), K(25.5, p=-6.0, t=-15.0)],
         "R": [K(0, o=0.25, y=-0.07, w=10.0, g=1.0, t=-15.0, k=10.0, p=-6.0), K(6, p=-6.0), K(9, p=-9.0),
               K(12, p=-6.0), K(18, p=-6.0), K(21, p=-8.5), K(24, p=-6.0)],
     })


# ---------------------------------------------------------------- work clips (sided)
# Shared grammar (every L/R work clip):
#   * weight_shift(): the body slides/rolls over the support leg and the support knee dips, peaking with a
#     small overshoot >= 2 f before the work heel peels; the weight is HELD while the work foot is off the
#     ground and comes back only after the work foot has planted (heel first, then flat), >= 4 f before the
#     end, with a small overshoot and settle.
#   * root rows below are ACTING on top of that envelope (z relative to the neutral Z0, pitch, yaw, travel,
#     extra roll); the work foot peels heel-first over the ball (g = 1, p < 0) before it lifts and lands
#     heel-first (p > 0 about the heel) before it rolls flat.
SUPPORT = [K(0, o=0.175, y=-0.01, w=6.0, k=7.0)]      # support sole: planted, a touch under the body
NEUTRAL_W = dict(o=0.19, y=0.0, h=0.0, p=0.0, t=0.0, g=1.0)


def w_peel(lift, t=0.0, peel=1.5, p=-12.0, w=None):
    """Work foot: flat and planted, then the heel peels over the ball just before the lift key."""
    extra = {} if w is None else {"w": w}
    return [K(0, tan="f", **dict(NEUTRAL_W, **extra)),
            K(lift - peel, o=0.19, y=0.0, h=0.0, p=0.0, t=0.0, g=1.0, tan="f"),
            K(lift, o=0.19, y=0.0, h=0.0, p=p, t=t, g=1.0)]


def w_plant(plant, end, approach, t=0.0, roll=1.5):
    """Work foot lands heel first at `plant` (toe up 5 deg about the heel) and rolls flat; approach = row
    dict for the last airborne key ~1 f before the plant."""
    return [K(plant - 1.0, g=0.0, **approach),
            K(plant, o=0.19, h=0.0, y=0.0, p=5.0, t=t, g=1.0, tan="f"),
            K(plant + roll, p=0.0, g=1.0, tan="f"),
            K(end, tan="f", **NEUTRAL_W)]


def work_root0():
    return K(0, u=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0)


def work_root_end(n):
    return K(n, u=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0)


# A10 build / assembly with the mallet: draw f5-12, hang, 3 f strike, contact 0.56, rebound, ease-out
C = C_of(1.0)
clip("wk_assemble", 1.0, sided=True, contact=C, notes="mallet stroke: support accepts f0-3.5 (overshoot), "
     "heel peels f4-5.5, slow heavy draw to f12 (knee cocked high, toe up = mallet up/back, body counter-pitches "
     "back and rises 1 cm), 2 f hang, 2.8 f accelerating strike (ankle spacing ~13/38/49 %, foot arcs forward "
     "then down, body pitch lunges with the largest step into contact), contact at 0.56, 3 cm rebound + hold, "
     "exponential ease-out (~60 % back by f23), heel plants f26, then the weight returns",
     layers=[weight_shift(3.5, 5.5, 26.0, 30.0, u=-0.09, r=4.5, z=-0.018)],
     root=[
         work_root0(),
         K(1.5, p=2.6, w=2.0),
         K(3.5, p=3.0, w=5.0),
         K(7, z=Z0 + 0.004, p=0.0),
         K(12, z=Z0 + 0.009, p=-5.0, w=7.0, y=-0.012),
         K(14, z=Z0 + 0.010, p=-5.6, y=-0.014, tan="f"),
         K(C, z=Z0 - 0.018, p=11.0, y=0.022, w=6.0, tan=(2.0, "f")),
         K(C + 1.2, z=Z0 - 0.011, p=8.8, y=0.019),                  # 1 f shudder
         K(C + 3.0, z=Z0 - 0.013, p=9.6, y=0.020, tan=("f", 2.0)),
         K(23, z=Z0 - 0.006, p=4.6, y=0.007, w=3.5),
         K(26, z=Z0 - 0.004, p=2.8, y=0.002, w=1.2),
         K(28.5, z=Z0 + 0.002, p=1.4),
         work_root_end(30),
     ],
     feet={
         "S": SUPPORT,
         "W": w_peel(5.5, t=-6.0) + [
             K(7, h=0.07, y=0.05, p=10.0, t=-12.0, g=0.0),
             K(9, o=0.185, h=0.20, y=0.095, p=38.0, t=-22.0),
             K(12, o=0.18, h=0.30, y=0.085, p=60.0, t=-28.0, tan="f"),
             K(14, h=0.31, y=0.075, p=63.0, t=-28.0, tan="f"),
             # strike: y accelerates (2x), h later (3x) -> the ankle arcs forward then down
             K(C, o=0.175, h=(0.12, (3.0, "f")), y=(0.42, (2.0, "f")), p=(-40.0, (2.0, "f")), t=-12.0),
             K(C + 1.2, h=0.15, y=0.41, p=-34.0, t=-14.0),
             K(C + 3.0, h=0.14, y=0.415, p=-36.0, t=-15.0, tan=("f", 2.0)),
             K(22.8, o=0.185, h=0.13, y=0.13, p=-2.0, t=-7.0),      # exponential recovery: ~60 % back by f23
         ] + w_plant(26.0, 30, dict(h=0.025, y=0.025, p=8.0, t=-3.0)),
     })

# A9 inspect: look, lean (support first), lift, slow-in toe approach, touch 0.56, probe rubs, verdict, release
C = C_of(1.3)
clip("wk_inspect", 1.3, sided=True, contact=C, notes="curious probe: eyes/body orient, weight onto the support "
     "(f0-5), heel peel, lift with the toe leading, strong slow-in approach, light toe touch at 0.56, two rubs, "
     "nod + puzzled head tilt while the foot withdraws, heel plants f33.5, weight returns",
     layers=[weight_shift(5.0, 8.5, 33.5, 39.0, u=-0.08, r=4.0, z=-0.02)],
     root=[
         work_root0(),
         K(3, w=5.0, p=3.5),
         K(8, p=8.0, w=6.0, z=Z0 - 0.006),
         K(16, p=10.5, y=0.012, z=Z0 - 0.008),
         K(C, p=11.0, w=6.5, z=Z0 - 0.009, tan="f"),
         K(C + 2.5, w=3.0),
         K(C + 5.0, w=7.5),
         K(28, p=11.0, r=0.0, w=6.5),
         K(30.5, p=14.0, r=5.5),                                  # verdict: nod + puzzled tilt
         K(33.5, p=9.0, r=2.5, w=4.0, y=0.006),
         K(36, p=3.5, r=0.5, z=Z0 - 0.004, y=0.0),
         work_root_end(39),
     ],
     feet={
         "S": SUPPORT,
         "W": w_peel(8.5, t=8.0, w=5.0) + [
             K(10.5, h=0.05, y=0.06, p=12.0, t=12.0, g=0.0),
             K(14, h=0.11, y=0.17, p=-5.0, t=18.0, o=0.18),
             K(19, h=0.10, y=0.335, p=-30.0, t=10.0, o=0.17),
             K(C, h=0.088, y=0.36, p=-34.0, t=4.0, w=5.0, tan="f"),
             K(C + 1.5, y=0.375, t=-6.0, w=-2.0),
             K(C + 3.0, y=0.355, t=4.0, w=8.0),
             K(C + 4.5, y=0.372, t=-5.0, w=0.0),
             K(C + 6.0, y=0.36, t=3.0, w=5.0, h=0.09),
             K(30, h=0.11, y=0.30, p=-24.0, t=6.0),
         ] + w_plant(33.5, 39, dict(h=0.03, y=0.04, p=8.0, t=3.0)),
     })

# A12 precision repair: lean in, two feints, short draw, 2-3 f tap at 0.56, hold, inspect lift, nod
C = C_of(1.1)
clip("wk_repair", 1.1, sided=True, contact=C, notes="craftsman taps: still body (<0.5 deg f6-18), choked "
     "mallet feints 6 cm then 3.5 cm stopping 1 cm short, 11 cm draw, 2.9 f tap at 0.56, hold, 3 cm check "
     "lift, satisfied nod, heel plants f28.5, weight returns",
     layers=[weight_shift(3.5, 5.5, 28.5, 33.0, u=-0.08, r=4.0, z=-0.018)],
     root=[
         work_root0(),
         K(3, p=5.0, w=4.0, z=Z0 - 0.004),
         K(6, z=Z0 - 0.012, p=8.0, w=5.0, y=0.01),
         K(C, p=8.4, z=Z0 - 0.014, w=5.2),
         K(C + 2.0, p=8.1, z=Z0 - 0.013),
         K(22, w=2.5),
         K(24, w=6.5, p=8.6),
         K(26, p=11.5, w=5.0),                                    # satisfied nod
         K(28.5, p=5.5, z=Z0 - 0.004, w=2.0),
         work_root_end(33),
     ],
     feet={
         "S": SUPPORT,
         "W": w_peel(5.5, t=-4.0) + [
             K(6.8, h=0.09, y=0.13, p=6.0, t=-8.0, g=0.0),
             K(8.2, o=0.175, h=0.19, y=0.30, p=-14.0, t=-20.0),
             K(9.2, h=0.222, y=0.31, p=-6.0),
             K(10.4, h=0.158, y=0.33, p=-20.0, tan="f"),          # feint 1 stops 1 cm short
             K(11.6, h=0.192, y=0.325, p=-12.0),
             K(12.8, h=0.156, y=0.335, p=-20.0, tan="f"),         # feint 2
             K(15.6, h=0.265, y=0.31, p=4.0, tan="f"),            # short draw
             K(C, h=0.145, y=0.345, p=-25.0, t=-16.0, tan=(2.0, "f")),
             K(C + 1.0, h=0.153, y=0.344, p=-23.0),
             K(C + 2.0, h=0.148, y=0.345, p=-24.0, tan="f"),
             K(23, h=0.178, y=0.335, p=-18.0, t=-20.0),           # check lift
             K(25.5, h=0.10, y=0.18, p=-4.0, t=-8.0),
         ] + w_plant(28.5, 33, dict(h=0.03, y=0.03, p=7.0, t=-2.0)),
     })

# Maintenance: ratchet phrase -- foot twists the tool twice (second harder, click at 0.56), listens, returns
C = C_of(1.1)
clip("wk_maintenance", 1.1, sided=True, contact=C, notes="service ratchet: weight onto the support, foot sets "
     "on the fitting, quick twist + reset, harder twist with body counter-yaw clicking at 0.56, little shake, "
     "listen tilt (weight still held), heel plants f28.5, weight returns",
     layers=[weight_shift(3.5, 5.5, 28.5, 33.0, u=-0.08, r=4.0, z=-0.018)],
     root=[
         work_root0(),
         K(3, p=4.0, w=4.0),
         K(8, p=7.0, z=Z0 - 0.006, w=5.0),
         K(12, w=2.0, p=8.0),
         K(14, w=5.0, p=7.0),
         K(C, w=1.0, p=9.0, z=Z0 - 0.012, tan="f"),
         K(C + 1.5, w=2.2, p=8.0, z=Z0 - 0.008),
         K(23, r=4.5, w=5.0, p=6.0),                              # listen tilt
         K(26, r=2.0, p=5.0),
         K(28.5, r=0.5, p=3.5, w=2.0, z=Z0 - 0.004),
         work_root_end(33),
     ],
     feet={
         "S": SUPPORT,
         "W": w_peel(5.5, t=4.0) + [
             K(0, r=0.0), K(5.5, r=0.0),
             K(7.5, h=0.12, y=0.18, p=10.0, t=10.0, o=0.18, g=0.0),
             K(10, h=0.20, y=0.33, p=-14.0, t=-24.0, o=0.165, r=-6.0),
             K(11, r=-8.0),
             K(12.8, r=22.0, tan="2f"),
             K(14.6, r=-10.0),
             K(C, r=31.0, y=0.335, tan="2f"),
             K(C + 1.0, r=26.0),
             K(C + 2.0, r=29.0),
             K(C + 3.0, r=27.0, tan="f"),
             K(23.5, h=0.22, y=0.29, r=10.0, t=-18.0),
             K(26, h=0.10, y=0.13, p=0.0, r=0.0, t=-6.0),
         ] + w_plant(28.5, 33, dict(h=0.03, y=0.03, p=7.0, t=-2.0, r=0.0)),
     })

# A13 unbend: whole sole on the joint, brace, slow-in push with tremor, give at 0.56, lurch, relief
C = C_of(1.2)
clip("wk_unbend", 1.2, sided=True, contact=C, notes="sustained diagonal sole push: weight accepted over 5 f, "
     "sole settles low and far on the joint, brace, slow-in push along the diagonal with 7.5 Hz tremor (work "
     "knee extends ~65 -> ~35 deg), give at 0.56 (foot and body lurch 3-4 cm), support absorbs, exhale, "
     "heel plants f31, weight returns.  Silhouette: one long diagonal support foot -> body -> push leg",
     layers=[weight_shift(5.0, 7.0, 31.0, 36.0, u=-0.08, r=4.0, z=-0.02),
             tremor("p2", 0.6, 4.0, 13, C, ramp=3.0), tremor("z2", 0.0015, 4.0, 13, C, ramp=3.0, phase=1.3),
             foot_tremor("W", "y", 0.003, 4.0, 13, C, ramp=3.0, phase=0.6)],
     root=[
         work_root0(),
         K(3, p=4.0, w=2.0),
         K(7, z=Z0 - 0.008, p=7.0, w=3.0),
         K(10.5, z=Z0 - 0.016, p=12.0, y=0.006, w=3.5),          # brace
         K(C - 0.8, z=Z0 - 0.026, p=19.5, y=0.032, tan="f"),      # push, slow-in
         K(C + 1.4, z=Z0 - 0.032, p=22.5, y=0.068),               # give: lurch
         K(24, z=Z0 - 0.030, p=18.0, y=0.048),
         K(27, z=Z0 - 0.038, p=12.0, y=0.026),                    # exhale drop
         K(29.5, z=Z0 - 0.014, p=7.5, y=0.014),
         K(31, z=Z0 - 0.010, p=5.5, y=0.008),
         K(33.5, p=2.8, y=0.002),
         work_root_end(36),
     ],
     feet={
         "S": SUPPORT,
         "W": w_peel(7.0, t=2.0) + [
             K(9, h=0.10, y=0.16, p=10.0, t=4.0, g=0.0),
             K(11.5, o=0.175, h=0.16, y=0.33, p=30.0, t=4.0),
             K(13, h=0.15, y=0.35, p=34.0, t=2.0, tan="f"),       # whole sole set on the joint
             K(C - 0.8, h=0.125, y=0.40, p=36.0, t=2.0, tan="f"),
             K(C + 1.4, h=0.11, y=0.435, p=33.0, t=0.0),          # give
             K(24, h=0.115, y=0.425, p=34.0),
             K(27, h=0.16, y=0.36, p=20.0, t=4.0),
         ] + w_plant(31.0, 36, dict(h=0.035, y=0.05, p=8.0, t=2.0)),
     })

# Tool fetch & fit: empty-toe reach, slow-in, grip at 0.56, supported lift to the carry pose, plant with tool
C = C_of(1.2)
clip("wk_tool_change", 1.2, sided=True, contact=C, notes="tool fetch/fit: weight accepted over 5 f, open toe "
     "reaches the handle with slow-in, snaps closed at 0.56, pulls the tool up/back (toe up = tool upright) "
     "with a counter-lean for the 5 kg mallet, sets the foot down (heel f31) still gripping; ends in the "
     "neutral stance with the toe still curled -24 deg round the handle (held-tool state)",
     layers=[weight_shift(5.0, 7.0, 31.0, 36.0, u=-0.085, r=4.0, z=-0.018)],
     root=[
         work_root0(),
         K(3, p=4.0, w=3.0),
         K(10, p=8.0, z=Z0 - 0.008, w=6.0),
         K(C, p=9.5, z=Z0 - 0.012, tan="f"),
         K(C + 1.5, p=8.0, z=Z0 - 0.007),
         K(26, p=-3.5, z=Z0 + 0.004, w=3.0),                      # counter-lean under the lifted mallet
         K(29, p=-1.0, w=1.5),
         K(31, p=0.5, z=Z0 - 0.004),
         K(33.5, p=2.6),
         work_root_end(36),
     ],
     feet={
         "S": SUPPORT,
         "W": w_peel(7.0, t=14.0)[:2] + [
             K(7.0, o=0.19, y=0.0, h=0.0, p=-12.0, t=14.0, g=1.0),
             K(8.8, h=0.10, y=0.12, p=12.0, t=22.0, g=0.0),
             K(12, o=0.18, h=0.22, y=0.30, p=-8.0, t=26.0),
             K(17, h=0.212, y=0.37, p=-14.0, t=27.0),
             K(C, h=0.208, y=0.38, p=-15.0, t=26.0, tan="f"),
             K(C + 2.0, t=-34.0, p=-12.0, h=0.212),                # grip snaps closed
             K(25.5, h=0.16, y=0.20, p=26.0, t=-32.0, o=0.185),    # lift: toe up = tool upright
             K(28.5, h=0.07, y=0.07, p=12.0, t=-30.0),
             K(30.0, h=0.03, y=0.025, p=8.0, t=-30.0, g=0.0),
             K(31.0, o=0.19, h=0.0, y=0.0, p=5.0, t=-30.0, g=1.0, tan="f"),
             K(32.5, p=0.0, t=-28.0, g=1.0, tan="f"),
             K(36, o=0.19, y=0.0, h=0.0, p=0.0, t=-24.0, g=1.0, tan="f"),
         ],
     })

# Brace: sole set high against the shared load, sit into a strong low stance, sustained hold kept alive
C = C_of(1.4)
clip("wk_brace", 1.4, sided=True, contact=C, notes="brace (team load): weight accepted over 5 f, the foot "
     "rises to set its sole upright against the load at hip height (thigh near horizontal), the body sits back "
     "into a low strong stance, sustained hold kept alive by load pulses and effort tremor, re-press accent at "
     "0.56 (foot drives 1.5 cm, body pushes back), release, heel plants f37, weight returns",
     layers=[weight_shift(5.0, 7.5, 37.0, 42.0, u=-0.085, r=4.5, z=-0.026),
             tremor("p2", 0.35, 4.0, 14, 34, ramp=4.0), tremor("z2", 0.0018, 9.0, 14, 34, ramp=4.0, phase=0.7)],
     root=[
         work_root0(),
         K(3, p=3.0, w=2.0),
         K(8, p=4.0, z=Z0 - 0.010, w=3.0),
         K(12, p=0.0, z=Z0 - 0.025, y=-0.012),                    # sits back into the brace
         K(16, p=-1.0, z=Z0 - 0.030, y=-0.016),
         K(20, p=0.0, z=Z0 - 0.027, y=-0.014),
         K(C - 1.0, p=-0.5, z=Z0 - 0.029, y=-0.015),
         K(C + 1.0, p=-3.0, z=Z0 - 0.036, y=-0.024, tan="f"),     # re-press accent
         K(28, p=-0.5, z=Z0 - 0.028, y=-0.016),
         K(32, p=-1.2, z=Z0 - 0.031, y=-0.018),
         K(35, p=0.5, z=Z0 - 0.020, y=-0.010),
         K(37, p=2.5, z=Z0 - 0.012, y=-0.004),
         K(39.5, p=2.6),
         work_root_end(42),
     ],
     feet={
         "S": SUPPORT,
         "W": w_peel(7.5, t=4.0) + [
             K(9.5, h=0.12, y=0.12, p=18.0, t=8.0, g=0.0),
             K(11.5, o=0.18, h=0.24, y=0.28, p=58.0, t=6.0),
             K(13, h=0.255, y=0.30, p=68.0, t=2.0, tan="f"),      # sole upright against the load
             K(C - 1.0, h=0.255, y=0.30, tan="f"),
             K(C + 1.0, h=0.258, y=0.315, p=70.0, tan="f"),
             K(29, y=0.305),
             K(33, h=0.255, y=0.30, p=68.0, tan="f"),
             K(35, h=0.12, y=0.12, p=18.0, t=4.0),
         ] + w_plant(37.0, 42, dict(h=0.03, y=0.025, p=7.0, t=0.0)),
     })

# Push: low horizontal sole push with the body driving forward, shove at 0.56, follow-through, release
C = C_of(1.4)
clip("wk_push", 1.4, sided=True, contact=C, notes="push: weight accepted over 5 f, low vertical-sole contact, "
     "deep support knee, body drives forward with tremor, shove at 0.56 (foot extends 8 cm, body lurches "
     "forward), follow-through, release, heel plants f37, weight returns",
     layers=[weight_shift(5.0, 7.5, 37.0, 42.0, u=-0.07, r=3.5, z=-0.022),
             tremor("p2", 0.55, 4.0, 15, C, ramp=3.0), foot_tremor("W", "y", 0.003, 4.0, 15, C, ramp=3.0)],
     root=[
         work_root0(),
         K(3, p=4.0, w=1.0),
         K(8, p=6.0, z=Z0 - 0.006, w=2.0),
         K(11.5, z=Z0 - 0.018, p=12.0, y=0.025),
         K(15.5, z=Z0 - 0.024, p=14.5, y=0.035),
         K(C - 0.5, z=Z0 - 0.027, p=18.5, y=0.045, tan="f"),
         K(C + 1.5, z=Z0 - 0.030, p=21.0, y=0.075),               # shove lurch
         K(28, z=Z0 - 0.024, p=15.0, y=0.05),
         K(32, z=Z0 - 0.012, p=9.0, y=0.03),
         K(35, p=6.0, y=0.02),
         K(37, p=4.0, y=0.01, z=Z0 - 0.006),
         K(39.5, p=2.4, y=0.002),
         work_root_end(42),
     ],
     feet={
         "S": SUPPORT,
         "W": w_peel(7.5, t=4.0) + [
             K(9.5, h=0.09, y=0.10, p=18.0, t=8.0, g=0.0),
             K(11.5, o=0.17, h=0.125, y=0.27, p=56.0, t=10.0),
             K(13, h=0.12, y=0.29, p=58.0, tan="f"),
             K(C - 0.5, h=0.118, y=0.34, p=56.0, tan="f"),
             K(C + 1.5, h=0.112, y=0.42, p=50.0),
             K(28, h=0.118, y=0.40, p=52.0),
             K(32, h=0.13, y=0.24, p=26.0, t=4.0),
             K(35, h=0.05, y=0.07, p=9.0, t=2.0),
         ] + w_plant(37.0, 42, dict(h=0.015, y=0.015, p=6.0, t=0.0)),
     })

# Pull: toe hooks forward, body leans back, effortful draw, release snap at 0.56, lurch back, recover
C = C_of(1.4)
clip("wk_pull", 1.4, sided=True, contact=C, notes="pull: weight accepted over 5 f, toe hooks the object ahead, "
     "body sits back, trembling draw, release at 0.56 snaps the foot back and the body lurches back, recover, "
     "heel plants f37, weight returns",
     layers=[weight_shift(5.0, 7.5, 37.0, 42.0, u=-0.08, r=4.0, z=-0.02),
             tremor("p2", 0.6, 4.0, 15, C, ramp=3.0), foot_tremor("W", "y", 0.0035, 4.0, 15, C, ramp=3.0)],
     root=[
         work_root0(),
         K(3, p=4.0, w=2.0),
         K(10, p=7.0, z=Z0 - 0.006, y=0.01, w=3.0),
         K(14, p=-6.0, z=Z0 - 0.016, y=-0.025),
         K(C - 0.5, p=-12.0, z=Z0 - 0.022, y=-0.04, tan="f"),
         K(C + 1.5, p=-15.5, z=Z0 - 0.028, y=-0.075),             # lurch back
         K(28, p=-10.0, z=Z0 - 0.018, y=-0.05),
         K(32, p=-4.5, z=Z0 - 0.012, y=-0.025),
         K(35, p=-1.0, y=-0.012),
         K(37, p=0.5, z=Z0 - 0.006, y=-0.005),
         K(39.5, p=2.5, y=0.0),
         work_root_end(42),
     ],
     feet={
         "S": SUPPORT,
         "W": w_peel(7.5, t=8.0) + [
             K(9.5, h=0.12, y=0.16, p=10.0, t=15.0, g=0.0),
             K(11.5, o=0.175, h=0.17, y=0.40, p=-24.0, t=12.0),
             K(13, h=0.165, y=0.405, p=-26.0, t=-48.0, tan="f"),  # hook
             K(C - 0.5, h=0.16, y=0.345, p=-20.0, t=-50.0, tan="f"),
             K(C + 1.5, h=0.18, y=0.24, p=-6.0, t=-30.0),
             K(28, h=0.14, y=0.20, p=-2.0, t=-6.0),
             K(32, h=0.09, y=0.10, p=3.0, t=0.0),
         ] + w_plant(37.0, 42, dict(h=0.012, y=0.01, p=6.0, t=0.0)),
     })

# Operate: foot onto a pedal/control, gather, press bottoming at 0.56, second short pump, lift off
C = C_of(1.2)
clip("wk_operate", 1.2, sided=True, contact=C, notes="station duty: weight accepted over 5 f, foot hovers onto "
     "the pedal, small gather (body rises), decisive press bottoming at 0.56 with a body bounce, a shorter "
     "second pump, safe lift-off, heel plants f31, weight returns",
     layers=[weight_shift(5.0, 7.0, 31.0, 36.0, u=-0.075, r=3.5, z=-0.02)],
     root=[
         work_root0(),
         K(3, p=4.0, w=2.0),
         K(11, z=Z0 - 0.004, p=6.0, w=3.0),
         K(15, z=Z0 + 0.004, p=4.5),                              # gather
         K(C, z=Z0 - 0.020, p=8.0, tan="f"),                      # press bottoms out
         K(C + 2.0, z=Z0 - 0.014, p=7.0),
         K(24, z=Z0 - 0.002, p=5.0),
         K(26.5, z=Z0 - 0.013, p=6.8),                            # second pump
         K(29, z=Z0 - 0.006, p=5.0),
         K(31, z=Z0 - 0.004, p=4.0),
         K(33.5, p=2.6),
         work_root_end(36),
     ],
     feet={
         "S": SUPPORT,
         "W": w_peel(7.0, t=6.0) + [
             K(9, h=0.12, y=0.12, p=12.0, t=10.0, g=0.0),
             K(11.5, o=0.175, h=0.175, y=0.29, p=-4.0, t=8.0),
             K(14, h=0.15, y=0.30, p=-8.0, t=0.0, tan="f"),
             K(16.5, h=0.158, y=0.30, p=-6.0, tan="f"),
             K(C, h=0.075, y=0.305, p=-14.0, t=-8.0, tan="2f"),
             K(C + 2.0, h=0.082, y=0.305, p=-12.0),
             K(24, h=0.12, y=0.30, p=-8.0, t=0.0),
             K(26.5, h=0.08, y=0.305, p=-13.0, tan="2f"),         # second pump
             K(28.5, h=0.09, y=0.16, p=2.0, t=2.0),
         ] + w_plant(31.0, 36, dict(h=0.02, y=0.02, p=7.0, t=0.0)),
     })

# A8 install handoff: lower to present, foot guides the part, seat at 0.56, relief pop, sole recovery
C = C_of(1.1)
clip("wk_place", 1.1, sided=True, contact=C, notes="place/install: weight to support, lower 7 cm and tip the "
     "head cargo toward the socket while the work foot steadies the part, seat at 0.56, relief pop (rises "
     "faster than it lowered) with the weight still held, heel plants f28, weight returns",
     layers=[weight_shift(3.5, 5.5, 28.0, 33.0, u=-0.07, r=3.0, z=-0.016)],
     root=[
         work_root0(),
         K(3, p=4.0, w=4.0),
         K(9, z=Z0 - 0.030, p=9.0, y=0.02),
         K(15, z=Z0 - 0.058, p=12.5, y=0.032),
         K(C, z=Z0 - 0.072, p=15.0, y=0.036, tan="f"),
         K(C + 1.5, z=Z0 - 0.068, p=14.0),
         K(23, z=Z0 + 0.006, p=1.0, y=0.01, tan="f"),             # relief pop (4.5 f)
         K(25.5, z=Z0 - 0.006, p=2.5),
         K(28, z=Z0 - 0.002, p=2.2, y=0.003),
         work_root_end(33),
     ],
     feet={
         "S": SUPPORT,
         "W": w_peel(5.5, t=4.0) + [
             K(7.5, h=0.10, y=0.12, p=14.0, t=8.0, g=0.0),
             K(12, o=0.17, h=0.20, y=0.30, p=30.0, t=10.0),
             K(16, h=0.19, y=0.325, p=34.0, tan="f"),
             K(C, h=0.18, y=0.345, p=36.0, tan="2f"),
             K(C + 1.5, h=0.18, y=0.34, p=35.0),
             K(23, h=0.13, y=0.22, p=14.0, t=4.0),
         ] + w_plant(28.0, 33, dict(h=0.03, y=0.03, p=7.0, t=0.0)),
     })

# Small-part foot pickup: reach down, toe grips at 0.56, lift, upward flick toward the head, catch dip
C = C_of(1.2)
clip("wk_pickup", 1.2, sided=True, contact=C, notes="small-part pickup: weight accepted over 5 f, lean in, "
     "open toe reaches down, grips at 0.56, lifts the part, flicks it up toward the head (face tracks up), "
     "foot comes down while the body dips to catch it on the head, heel plants f32, weight returns",
     layers=[weight_shift(5.0, 7.0, 32.0, 36.0, u=-0.085, r=4.0, z=-0.018)],
     root=[
         work_root0(),
         K(3, p=4.0, w=3.0),
         K(10, p=10.0, z=Z0 - 0.020, w=5.0),
         K(C, p=12.0, z=Z0 - 0.032, tan="f"),
         K(C + 1.5, p=10.5, z=Z0 - 0.026),
         K(25, p=2.0, z=Z0 - 0.002),
         K(27.5, p=-8.0, z=Z0 + 0.008, tan="f"),                  # face up, watching the part fly
         K(29.5, p=-6.0, z=Z0 + 0.004),
         K(31.5, p=1.5, z=Z0 - 0.016),                            # catch dip
         K(33.5, p=3.0, z=Z0 - 0.006),
         work_root_end(36),
     ],
     feet={
         "S": SUPPORT,
         "W": w_peel(7.0, t=10.0) + [
             K(9, h=0.08, y=0.12, p=10.0, t=15.0, g=0.0),
             K(12, o=0.17, h=0.10, y=0.31, p=-14.0, t=28.0),
             K(16.5, h=0.062, y=0.355, p=-12.0, t=28.0),
             K(C, h=0.055, y=0.36, p=-12.0, t=26.0, tan="f"),
             K(C + 1.8, t=-42.0, h=0.06),
             K(24.5, h=0.24, y=0.32, p=14.0, t=-40.0, o=0.175),
             K(27, h=0.37, y=0.29, p=56.0, t=10.0, tan="2f"),     # flick / release toward the head
             K(28.8, h=0.30, y=0.24, p=38.0, t=6.0),
         ] + w_plant(32.0, 36, dict(h=0.04, y=0.04, p=9.0, t=2.0)),
     })

# Reposition step: support accepts, work foot swings forward with clearance, heel lands at 0.56, transfer
C = C_of(0.7)
clip("wk_step", 0.7, sided=True, contact=C, notes="reposition step: weight onto support (f0-3), heel peel, "
     "work foot swings forward 0.24 m with 8 cm clearance, heel lands at 0.56 and rolls flat, then the weight "
     "transfers over the new base (root advances 0.12 m)",
     layers=[weight_shift(3.0, 4.5, C, 18.0, u=-0.06, r=3.0, z=-0.014)],
     root=[
         work_root0(),
         K(3, p=3.0, w=1.5),
         K(8, p=5.0, y=0.02),
         K(C, z=Z0 - 0.006, p=4.0, y=0.05),
         K(C + 2.0, z=Z0 - 0.012, y=0.08),
         K(18, z=Z0 + 0.002, y=0.12, p=2.5, w=0.0),
         K(21, u=0.0, y=0.12, z=Z0, p=P0, r=0.0, w=0.0),
     ],
     feet={
         "S": [K(0, o=0.175, y=-0.01, w=6.0, k=7.0, g=1.0, p=0.0),
               K(14, p=0.0), K(18, p=-8.0), K(21, p=-3.0)],
         "W": w_peel(4.5, t=6.0) + [
             K(6, h=0.05, y=0.05, p=-4.0, t=4.0, g=0.2),
             K(8, h=0.085, y=0.13, p=6.0, t=-4.0, g=0.0, o=0.2),
             K(C - 1.5, h=0.03, y=0.235, p=10.0, t=4.0, g=0.6),
             K(C, h=0.0, y=0.24, p=8.0, t=0.0, g=1.0, o=0.2, tan="f"),
             K(C + 2.5, h=0.0, y=0.24, p=0.0, g=1.0, tan="f"),
             K(21, h=0.0, y=0.24, p=0.0, o=0.2)],
     })

# Interrupted (also the source of runtime recoil/* copies): flinch back, protective foot withdraw/replant
clip("wk_interrupted", 0.7, sided=True, notes="startle/interrupt: 2 f flinch (lean back, dip), work foot "
     "snaps up and replants under the hip, absorb, recover with a small forward overshoot, settle",
     root=[
         K(0, u=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0),
         K(2, y=-0.022, z=-0.042, p=-5.5, r=2.5, u=-0.02, tan="l"),
         K(3, p=-6.2, z=-0.046),
         K(7, y=-0.02, z=-0.055, p=-4.0, r=2.0),
         K(11, y=-0.012, z=-0.045, p=-1.0, r=1.0),
         K(15, y=0.0, z=-0.024, p=3.8, r=-0.5, u=0.0),
         K(18, z=-0.027, p=1.6),
         K(21, u=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0),
     ],
     feet={
         "S": [K(0, o=0.175, y=-0.01, w=6.0, k=7.0)],
         "W": [K(0, o=0.19, y=0.0, h=0.0, p=0.0, t=0.0, g=1.0, tan="f"),
               K(1, h=0.0, y=0.0, p=0.0, g=1.0, tan="f"),
               K(3, h=0.055, y=-0.01, p=8.0, t=-14.0, g=0.0),
               K(5, h=0.04, y=-0.03, p=4.0),
               K(7, h=0.0, y=-0.03, p=0.0, t=-6.0, g=1.0, tan="f"),
               K(12, t=0.0),
               K(21, h=0.0, y=-0.03, p=0.0, t=0.0)],
     })


# ---------------------------------------------------------------- V-leg sit family (unsided)
# Seat-descent ownership: the clips carry the FULL descent in root Z (-0.779 m seated) so they are complete
# on their own; the runtime should drive the native seat_drop FROM the authored curve (seat_drop(t) =
# -root_z(t), see the report's "seat_descent" table: <= 1 g downward everywhere, so the spring can track it)
# and subtract the native body's actual drop from the visual root.  Root pitch/yaw/x/y stay authored.
SEAT_Z = -0.810           # seated root target; the seat floor contact raises it until the bottom rests
SEAT_Y = -0.085
SEAT_P = -9.0
V_O, V_Y = 0.50, 0.77     # seated ankle reference (heel pivot moves the ankle ~0.11 back): knees ~0.25 m
V_P = 48.0                # foot rests on its heel, toe up
SQ_O, SQ_Y = 0.25, 0.20   # sumo-squat stance after the two wide steps (toes out, knees over the toes)
SL_O, SL_Y = 0.45, 0.66   # where the unweighted heels have skidded to when the bottom lands
GA_O, GA_Y = 0.50, 0.22   # rise: feet gathered back wide (the body rocks forward between the legs)

clip("wk_sit_down", 1.6, notes="supported lower into the V-sit: glance down, weight onto R and a wide forward "
     "L step, weight onto L and the R step (toes out), the body travels forward over the feet and sumo-squats "
     "(COM over the soles, counter-pitch +14 deg, knees over the toes), then rocks back: the unweighting heels "
     "skid forward (authored slide f25-32) as the bottom lands at <= 2 cm/f (one continuous descent, <= 1 g "
     "down), 1 cm settle bump, the feet lift-and-place into the V (L then R), lean back face up; root Z "
     "carries the full seat descent",
     slides={"L": (25, 32), "R": (25, 32)}, seat=(31.0, 48.0),
     root=[
         K(0, x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0),
         K(2.5, p=7.0, z=-0.032),                         # glance down at the spot
         K(3.5, x=0.032, r=2.6),                          # weight onto R
         K(6.5, x=0.026, y=0.03, z=-0.040),
         K(9, x=0.008, r=0.5),
         K(11, x=-0.030, r=-2.6, y=0.06, z=-0.058, tan=("a", "f")),   # weight onto L
         K(13.5, x=-0.024, r=-2.0),
         K(16, x=0.0, r=0.0, y=0.105, p=10.0),
         K(17, z=-0.20),
         K(20, y=0.145, p=13.0),
         K(22, z=-0.42),
         K(23, y=0.155, p=14.0),                          # deepest balanced squat (COM over the soles)
         K(26, z=-0.60, y=0.10, p=10.0),                  # rock back
         K(29, z=-0.725, y=0.0, p=4.0),
         K(32, z=-0.803, y=-0.085, p=-1.0, tan=(0.55, "f")),  # bottom touches (decelerated)
         K(33.5, z=-0.787),                               # settle bump
         K(35.5, z=-0.810, tan="f"),
         K(40, p=-4.0, r=1.5),
         K(44, p=-10.0, r=-1.0, w=2.0),
         K(48, x=0.0, y=SEAT_Y, z=SEAT_Z, p=SEAT_P, r=0.0, w=0.0),
     ],
     feet={g: [K(0, o=0.19, y=0.0, h=0.0, p=0.0, w=5.0, k=6.0, g=1.0, t=0.0, tan="f"),
               K(a, o=0.19, y=0.0, h=0.0, p=0.0, w=5.0, g=1.0, tan="f"),
               K(a + 1.5, o=0.19, y=0.0, h=0.0, p=-12.0, w=5.0, g=1.0),
               K(a + 3.3, h=0.07, o=0.23, y=0.11, p=4.0, g=0.0, w=10.0),
               K(a + 5.0, h=0.02, o=0.248, y=0.195, p=6.0, g=0.3),
               K(a + 6.0, o=SQ_O, y=SQ_Y, h=0.0, p=0.0, k=10.0, w=14.0, g=1.0, tan="f"),
               K(20, k=16.0),
               K(25, o=SQ_O, y=(SQ_Y, ("f", 1.6)), p=0.0, k=22.0, w=14.0, g=1.0, tan="f"),
               K(26.8, k=28.0), K(29.5, k=28.0),                                      # knees fall open as it sits
               K(32, o=SL_O, y=SL_Y, p=30.0, k=34.0, t=6.0, w=16.0, g=1.0, tan="f"),   # heels skid forward
               K(b, o=SL_O, y=SL_Y, h=0.0, p=30.0, k=26.0, w=16.0, g=1.0, tan="f"),
               K(b + 2.5, h=0.05, o=0.47, y=0.65, p=38.0, k=18.0, g=0.4, t=2.0),
               K(b + 5.0, o=V_O, y=V_Y, h=0.0, p=V_P, w=14.0, k=16.0, g=1.0, t=0.0, tan="f"),
               K(48, o=V_O, y=V_Y, h=0.0, p=V_P, w=14.0, k=16.0)]
           for g, a, b in (("L", 3.5, 34.0), ("R", 10.0, 37.5))},
     )


def _lift(t0, rise, hold, lower, amp, dy=-0.012, dp=5.0):
    """Seated foot lift: ease-out rise, short hold (with micro drift), ease-in-out lower."""
    t1, t2, t3 = t0 + rise, t0 + rise + hold, t0 + rise + hold + lower
    return [K(t0, h=0.0, y=V_Y, p=V_P, tan="f"),
            K(t1, h=amp, y=V_Y + dy, p=V_P + dp, tan="f"),
            K(t2, h=amp * 0.92, y=V_Y + dy * 0.9, p=V_P + dp * 0.9),
            K(t3, h=0.0, y=V_Y, p=V_P, tan="f")]


clip("wk_sit_idle", 4.8, loop=True, seat=(0.0, 144.0), notes="attentive V-sit: body pitched back, head forward/up, slow "
     "alternating 2-4 cm foot lifts with uneven gaps, toe wiggles, breathing, unhurried attention turns",
     root=[
         K(0, x=0.0, y=SEAT_Y, z=SEAT_Z, p=SEAT_P, r=0.0, w=0.0),
         K(18, w=0.0), K(28, w=-7.5, r=-0.8), K(46, w=-6.6, p=-11.0), K(56, p=-10.6),
         K(64, w=1.0, r=0.0), K(84, p=-8.4), K(96, w=1.5), K(106, w=8.5, r=0.9, p=-9.6),
         K(122, w=7.6), K(136, w=0.0, r=0.0, p=SEAT_P),
     ] + [
         K(0, z2=0.0, p2=0.0), K(34, z2=0.003, p2=-0.3), K(70, z2=-0.0005, p2=0.05),
         K(106, z2=0.0032, p2=-0.32),
     ],
     feet={
         "L": [K(0, o=V_O, y=V_Y, h=0.0, p=V_P, w=14.0, k=16.0, g=1.0, t=0.0)]
              + _lift(6, 11, 4, 16, 0.032) + _lift(80, 10, 4, 14, 0.022)
              + [K(58, t=0.0), K(61, t=18.0), K(64, t=-4.0), K(67, t=12.0), K(71, t=0.0)],
         "R": [K(0, o=V_O, y=V_Y, h=0.0, p=V_P, w=14.0, k=16.0, g=1.0, t=0.0)]
              + _lift(42, 10, 4, 14, 0.026) + _lift(112, 11, 4, 15, 0.036, dp=6.0)
              + [K(72, t=0.0), K(75.5, t=10.0), K(79, t=-2.0), K(86, t=0.0), K(89, t=14.0), K(93, t=-3.0),
                 K(97, t=0.0)],
     })

clip("wk_sit_up", 1.1, notes="supported rise: eyes snap (head lifts), feet pulled back wide beside the body (two "
     "placements, toes out, knees up and out), a small rock back, then the body throws itself forward rolling onto "
     "its front-bottom edge between the legs (pitch +31 deg) so the bottom lifts with the COM arriving over the "
     "soles; push up forward-first then up with an ease-out; weight onto R and the L closing step during the "
     "last of the rise, weight onto L and the R closing step after L has planted, dip and settle; root advances "
     "~0.30 m over the feet",
     seat=(0.0, 14.0),
     root=[
         K(0, x=0.0, y=SEAT_Y, z=SEAT_Z, p=SEAT_P, r=0.0, w=0.0),
         K(2, p=-6.5),                                     # eyes snap: head lifts
         K(5.5, p=-7.0),
         K(9.5, p=-11.0, y=-0.095),                        # small rock back (anticipation)
         K(11.5, p=0.0, y=-0.07, z=-0.83),
         K(13, p=18.0, y=0.0, z=-0.82),
         K(14.5, p=31.0, y=0.075, z=-0.746),               # on the front-bottom edge: the bottom lifts
         # explosive push (~3 g for 3 f), then a long <= 0.8 g deceleration: the ease-out of a rise
         K(15.5, z=-0.7298), K(16.5, z=-0.6811),
         K(17.5, p=26.0, y=0.165, z=-0.603),               # forward over the feet first ...
         K(19, x=0.004, r=0.4, z=-0.469),
         K(20.5, p=18.0, y=0.197, z=-0.354),               # ... then up (<= 0.8 g deceleration)
         K(21.5, x=0.034, r=2.8),                          # weight onto R for the L closing step
         K(22, z=-0.258),
         K(23.5, p=10.0, y=0.207, z=-0.180),
         K(25, p=6.0, y=0.212, z=-0.121),
         K(26, x=0.012, r=0.8),
         K(26.5, z=-0.081),
         K(27.5, x=-0.022, r=-2.2),                        # weight onto L for the R closing step
         K(28, z=-0.0588, p=3.0),
         K(29.2, z=-0.055, tan="f"),
         K(31.2, z=-0.050, p=3.2, x=-0.012, r=-1.4),       # R plants: absorb dip
         K(32, x=0.002, r=0.2),
         K(33, x=0.0, y=0.212, z=Z0, p=P0, r=0.0, w=0.0),
     ],
     feet={g: [K(0, o=V_O, y=V_Y, h=0.0, p=V_P, w=14.0, k=16.0, g=1.0, t=0.0, tan="f"),
               K(a, o=V_O, y=V_Y, h=0.0, p=V_P, w=14.0, k=16.0, g=1.0, tan="f"),
               K(a + 2.0, h=0.06, o=0.49, y=0.47, p=22.0, g=0.3, w=20.0),
               K(a + 4.0, o=go, y=GA_Y, h=0.0, p=0.0, w=24.0, k=40.0, g=1.0, tan="f"),
               K(16, k=40.0), K(20.5, k=18.0),
               K(c, o=go, y=GA_Y, h=0.0, p=0.0, t=0.0, w=24.0, g=1.0, tan="f"),
               K(c + 1.5, o=go, y=GA_Y, h=0.0, p=-6.0, w=24.0, g=1.0, k=12.0),
               K(c + 3.0, h=0.06, o=0.33, y=fy + 0.005, p=2.0, g=0.0, w=12.0),
               K(c + 4.5, o=fo, y=fy, h=0.0, p=0.0, w=6.0, k=7.0, g=1.0, tan="f"),
               K(33, o=fo, y=fy, h=0.0, p=0.0, w=6.0, k=7.0, g=1.0)]
           for g, a, c, fo, fy, go in (("L", 2.5, 21.5, 0.21, 0.25, GA_O), ("R", 5.0, 26.5, 0.22, 0.23, GA_O))},
     )


# ---------------------------------------------------------------- social / acting
# Airborne root segments use ballistic tangents: (.., 2) out of a take-off key and (2, ..) into a landing key
# with a flat apex reproduce a free-fall parabola exactly (cubic Hermite through a quadratic).
BAL_UP = (1.0, 2.0)       # take-off key: in = secant (push), out = parabola slope
BAL_DN = (2.0, 1.6)       # landing key: in = parabola slope, out = carries the fall into the absorb

clip("wk_greet", 1.6, notes="greeting: 'oh!' rise onto the toes, weight onto L and a small R adjust step back "
     "(feet end offset 7 cm, never twin posts), dip wind-up, bow-hop (~5 cm, ballistic) with a 12 deg nod at "
     "the apex and the R foot tucked higher, landing absorb, happy glow: weight on L with a 6-7 deg side-tilt, "
     "free R heel pops on the tiny bounce, eased release, R steps back to the stance",
     root=[
         K(0, x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0),
         K(2, z=Z0, p=P0),
         K(5.5, z=-0.010, p=-3.0, y=0.045, tan="f"),      # "oh!" up on the toes (body over the balls)
         K(9, z=-0.032, p=-0.5, x=-0.030, r=-2.0, y=0.006),   # weight onto L
         K(13.5, x=-0.030, r=-2.0, z=-0.036, y=0.0),
         K(15, z=-0.060, p=-3.0, x=-0.010, r=-0.5),
         K(16.5, z=-0.074, p=-4.0, x=-0.008, r=0.0, tan="f"),   # wind-up dip
         K(18.5, z=-0.012, p=3.0, tan=BAL_UP),            # take-off
         K(21.3, z=0.030, p=12.0, tan="f"),               # bow-hop apex: the nod
         K(24.2, z=-0.012, p=7.0, tan=BAL_DN),            # touch-down
         K(27.5, z=-0.074, p=2.0, x=-0.014, tan="f"),     # absorb
         K(31, z=-0.040, p=-2.5, x=-0.044, r=-4.5, w=-2.0),
         K(33, z=-0.036, r=-6.0),
         K(35, z=-0.052, r=-7.0, w=-4.0),                 # tiny bounce, aww tilt
         K(38, z=-0.042, r=-5.8, p=-3.0),
         K(41, r=-6.2, w=-3.0, z=-0.044, x=-0.044),
         K(43.5, x=-0.040, r=-3.0, p=0.0, z=-0.036),
         K(45.5, x=-0.018, r=-1.0),
         K(48, x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0),
     ],
     feet={
         "L": [K(0, o=0.19, y=0.0, h=0.0, p=0.0, w=6.0, g=1.0, t=0.0, tan="f"),
               K(2, h=0.0, p=0.0, t=0.0, g=1.0, tan="f"),
               K(5.5, h=0.0, p=-12.0, t=-4.0, g=1.0, tan="f"),
               K(9, h=0.0, p=0.0, t=0.0, g=1.0, tan="f"),
               K(16.5, h=0.0, p=0.0, y=0.0, g=1.0, tan="f"),
               K(18, h=0.0, y=0.0, o=0.19, p=-22.0, t=-8.0, g=1.0, tan="f"),     # push-off on the ball
               K(19.3, h=0.03, p=-14.0, t=-6.0, g=0.6),
               K(21.3, h=0.075, y=0.03, p=-2.0, t=-2.0, g=0.0),
               K(23.6, h=0.012, y=0.005, p=5.0, g=0.6),
               K(24.2, h=0.0, y=0.0, p=0.0, t=0.0, g=1.0, tan="f"),
               K(48, h=0.0, p=0.0, t=0.0)],
         "R": [K(0, o=0.19, y=-0.01, h=0.0, p=0.0, w=6.0, g=1.0, t=0.0, tan="f"),
               K(2, h=0.0, p=0.0, t=0.0, g=1.0, tan="f"),
               K(5.5, h=0.0, p=-12.0, t=-4.0, g=1.0, tan="f"),
               K(9, o=0.19, y=-0.01, h=0.0, p=0.0, t=0.0, g=1.0, tan="f"),
               K(10.5, o=0.19, y=-0.01, h=0.0, p=-12.0, g=1.0),        # adjust step back and out
               K(12, h=0.05, o=0.20, y=-0.045, p=2.0, g=0.0),
               K(13.5, o=0.21, y=-0.07, h=0.0, p=0.0, g=1.0, tan="f"),
               K(16.5, o=0.21, y=-0.07, h=0.0, p=0.0, g=1.0, tan="f"),
               K(18.3, h=0.0, y=-0.07, o=0.21, p=-22.0, t=-8.0, g=1.0, tan="f"),
               K(19.6, h=0.03, p=-12.0, t=-4.0, g=0.6),
               K(21.6, h=0.11, y=-0.085, p=10.0, t=6.0, g=0.0),        # tucked higher than L
               K(23.6, h=0.02, y=-0.072, p=6.0, g=0.6),
               K(24.4, h=0.0, y=-0.07, p=0.0, t=0.0, g=1.0, tan="f"),
               K(28.5, h=0.0, p=0.0, t=0.0, g=1.0, k=6.0, tan="f"),
               K(31, h=0.0, p=-14.0, t=-4.0, g=1.0, k=-10.0),          # unweighted: heel up, knee in (shy)
               K(33.8, h=0.0, p=-26.0, t=-12.0, g=1.0),                # free-foot heel pop on the bounce
               K(36.5, h=0.0, p=-12.0, t=-3.0, g=1.0),
               K(40, h=0.0, p=-14.0, t=-4.0, g=1.0, k=-10.0),
               K(42, o=0.21, y=-0.07, h=0.0, p=-6.0, g=1.0, k=4.0, tan="f"),
               K(43.5, o=0.21, y=-0.07, h=0.0, p=-12.0, g=1.0),        # step back into the stance
               K(44.8, h=0.04, o=0.20, y=-0.04, p=2.0, g=0.0),
               K(46, o=0.19, y=-0.01, h=0.0, p=0.0, g=1.0, tan="f"),
               K(48, o=0.19, y=-0.01, h=0.0, p=0.0, t=0.0)],
     })

clip("wk_cheer", 0.9, notes="completion cheer: quick dip, springy ballistic hop (~12 cm) with a real knee tuck "
     "(feet 13-16 cm up relative to the body, R a frame later and 3 cm higher), face up and a roll wiggle in "
     "the air, L lands a half frame before R, absorb, overshoot settle",
     root=[
         K(0, x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0),
         K(4.5, z=-0.085, p=-2.0, tan="f"),
         K(7.5, z=-0.012, p=-7.0, tan=BAL_UP),
         K(12.2, z=0.112, p=-12.0, r=5.0, tan="f"),
         K(14.5, r=-5.0),
         K(17, z=-0.022, p=-5.0, r=-1.0, tan=BAL_DN),
         K(20.5, z=-0.088, p=4.0, r=0.0, tan="f"),
         K(22.0, z=-0.062),
         K(23.3, z=-0.040, p=0.5),
         K(24.8, z=-0.029, p=1.0, tan="f"),
         K(25.8, p=2.4),
         K(27, x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0),
     ],
     feet={g: [K(0, o=0.19, y=0.0, h=0.0, p=0.0, w=5.0, g=1.0, t=0.0, tan="f"),
               K(4.5, h=0.0, p=0.0, t=0.0, y=0.0, o=0.19, g=1.0, tan="f"),
               K(7.5 + d, h=0.0, p=-22.0, t=-8.0, g=1.0, y=0.0, o=0.19, tan="f"),
               K(8.7 + d, h=0.06, p=-12.0, g=0.5),
               K(11.8 + d, h=0.26 + e, y=0.07, p=10.0 + 4 * e / 0.03, t=6.0, g=0.0, o=0.21),
               K(14.2 + d, h=0.18 + e, y=0.05, p=6.0),
               K(16.6 + d, h=0.015, p=3.0, y=0.0, o=0.19, g=0.6),
               K(17 + d, h=0.0, p=0.0, t=0.0, g=1.0, y=0.0, tan="f"),
               K(27, h=0.0, p=0.0)] for g, d, e in (("L", 0.0, 0.0), ("R", 0.5, 0.03))})


# ---------------------------------------------------------------- dances (120 BPM, beat = 15 f, 8 beats)
# Grammar: groove dips land ON the beat (2 f down, 5 f up), 5 cm deep with +/-7 deg rolls; hits on beats 1 and 5
# (and the phrase end) are asymmetric poses -- weight on one leg, knees out 18-24 deg, the other foot offset or
# pointed -- held 4-6 f with life; every hop is ballistic with a real tuck (feet >= 10 cm up relative to the body)
# and the two feet never move as twins (offset timing / height / placement).
HOP_G = 1.15 * 9.81       # slightly snappier than real gravity (quick, light character)


def dance_stance(dz=-0.022, dk=10.0, t_in=(0.0, 6.0), t_out=(112.0, 120.0)):
    """Dance base: a lower, springier stance (knees bent ~40 deg) with the knees splayed out, eased in over
    the first beat and out over the last, so the legs never read as straight posts between the accents."""
    def fn(t, P, ev):
        env = smooth(t_in[0], t_in[1], t) * (1.0 - smooth(t_out[0], t_out[1], t))
        P["root"]["z2"] += dz * env
        for leg in "LR":
            P[leg]["k"] += dk * env
    return fn


def _hop(t0, t1, z0):
    """Ballistic root hop rows (take-off, apex, landing at the same height): the apex height follows from the
    flight time, so every hop in the library falls at the same believable 1.15 g."""
    half = (t1 - t0) * 0.5 / FPS
    return [K(t0, z=(z0, BAL_UP)), K(t0 + (t1 - t0) * 0.5, z=(z0 + 0.5 * HOP_G * half * half, "f")),
            K(t1, z=(z0, BAL_DN))]


def _tuck(t0, t1, h, y=0.04, o=None, p_air=10.0, lead=0.0, settle=None, y0=0.0, o0=0.19, w0=5.0):
    """Foot rows for a hop: (planted at y0/o0/w0) push off the ball at t0, tuck to h at mid-flight, land flat
    at t1 (at o / settle).  The planted channels are pinned at the push-off so the sole cannot creep."""
    tm = t0 + (t1 - t0) * 0.5 + lead
    oo = {} if o is None else {"o": o}
    return [K(t0 - 1.5, h=0.0, p=0.0, g=1.0, tan="f"),
            K(t0, h=0.0, p=-22.0, t=-8.0, g=1.0, y=y0, o=o0, w=w0, tan="f"),
            K(t0 + 1.0, h=0.05, p=-10.0, g=0.5),
            K(tm, h=h, y=y, p=p_air, t=4.0, g=0.0),
            K(t1 - 0.6, h=0.02, p=4.0, g=0.6),
            K(t1, h=0.0, y=0.0 if settle is None else settle, p=0.0, t=0.0, g=1.0, tan="f", **oo)]


clip("wk_dance_a", 4.0, notes="phrase A: TA-DA jump-out hit (b1: wide asymmetric feet, knees out, roll 8), "
     "groove with a heel pop (b2), side-step R then L travelling 0.16 m with rolls into the steps (b3-4), "
     "forward kick hit 45 deg with pointed toe, weight on the L leg (b5), knee-pop groove (b6), wind-up and a "
     "two-hop 360 spin (slow-fast-slow) landing on the 8th grid (7-and = f97.5, beat 8 = f105) into a ta-da "
     "hold and a settle",
     layers=[dance_stance()],
     spin=[(0, 0.0, "f"), (93.5, 0.0, "f"), (97.5, 180.0, "f"), (99.5, 180.0, "f"), (105, 360.0, "f"),
           (120, 360.0, "f")],
     root=[
         K(0, x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0),
         K(1.0, z=-0.062, p=0.0, tan="f"),                       # dip
         K(5.0, r=6.0, p=-4.0, x=-0.010),                        # jump-out (ballistic 2 -> 5) ...
         K(7.5, z=-0.078, r=8.0, p=-5.0, x=-0.012, tan="f"),     # ... TA-DA hit (b1)
         K(9.5, z=-0.070),
         K(10, z=-0.082, r=8.6, p=-5.5),
         K(13.5, z=-0.050, r=1.0, p=1.0, x=0.0),
         K(15, z=(-0.05, "f")), K(17.5, z=(-0.096, (2.0, "f"))), K(17.5, r=-7.0, w=-8.0),                    # b2 groove
         K(22.5, z=(-0.052, "f")), K(25.0, z=(-0.097, (2.0, "f"))), K(22.5, w=4.0, r=-2.0), K(25, r=7.0, w=8.0),
         K(29, z=-0.055, r=2.0, w=0.0),
         K(30, z=(-0.052, "f"), x=0.0), K(32.5, z=(-0.092, (2.0, "f")), r=3.0),          # b3 step R
         K(34.5, x=0.075, r=7.5, z=-0.065),
         K(37.5, z=-0.098, tan="f"),
         K(40.5, x=0.14, r=4.0, z=-0.058),
         K(43, x=0.15, r=1.5),
         K(45, z=(-0.052, "f")), K(47.5, z=(-0.092, (2.0, "f")), r=-3.0),                # b4 step L
         K(49.5, x=0.075, r=-7.5, z=-0.065),
         K(52.5, z=-0.098, tan="f"),
         K(55, x=-0.03, r=-5.0, z=-0.058),
         K(57, x=-0.065, r=-7.0, z=-0.062, p=0.0),                                     # weight onto L
         K(58.5, z=-0.048, p=-5.0),
         K(60, z=-0.040, p=-9.0, r=-7.5, tan="f"),                                     # KICK hit (b5)
         K(62.5, z=-0.046, p=-8.0, r=-6.5),
         K(65, z=-0.042, p=-9.0, r=-7.2),
         K(68.5, z=-0.060, p=-2.0, x=-0.05, r=-4.0),
         K(72, z=-0.068, x=-0.01, r=-1.0, p=1.0),
         K(75, z=(-0.052, "f")), K(77.5, z=(-0.1, (2.0, "f"))), K(75, x=0.0, r=0.0), K(77.5, r=7.0, w=7.0),   # b6 knee pops
         K(82.5, z=(-0.054, "f")), K(85.0, z=(-0.1, (2.0, "f"))), K(82.5, w=-3.0, r=0.0), K(85, r=-7.0, w=-7.0),
         K(89, z=-0.06, r=0.0, w=0.0),
         K(90.5, w=0.0),
         K(91.5, w=-30.0, z=-0.074, p=4.0, tan="f"),                                     # wind-up dip (b7)
         K(95.5, w=70.0, p=-1.0),
         K(97.5, w=170.0, p=3.0),
         K(98.5, z=-0.052, w=186.0, tan="f"),                                           # 7-and: touch, re-bound
         K(102.25, w=290.0, p=-3.0),
         K(105, w=360.0, p=-4.0, x=0.0),                                                # beat 8: land ...
         K(107.5, z=-0.094, r=8.0, p=-5.5, tan="f"),                                    # ... TA-DA hit
         K(109.5, z=-0.082, r=8.6),
         K(111.5, z=-0.086, r=7.6, p=-4.5),
         K(115.5, z=-0.050, r=1.5, p=1.0),
         K(120, x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=360.0),
     ] + _hop(2.0, 5.0, -0.030) + _hop(93.5, 97.5, -0.032) + _hop(99.5, 105.0, -0.042),
     feet={
         "L": [K(0, o=0.19, y=0.0, h=0.0, p=0.0, w=5.0, g=1.0, t=0.0, k=6.0, tan="f"),
               K(2.0, h=0.0, o=0.19, y=0.0, p=-14.0, w=5.0, g=1.0, tan="f"), K(3.5, h=0.06, o=0.27, y=0.02, p=0.0, g=0.0),
               K(5.0, h=0.0, o=0.34, y=0.03, k=22.0, w=14.0, g=1.0, tan="f"),               # wide, toe out
               K(14, k=10.0), K(17, p=0.0, g=1.0, tan="f"), K(18.5, p=-18.0, g=1.0),   # heel pop (b2)
               K(21, p=0.0, g=1.0, tan="f"),
               K(37.5, o=0.34, y=0.03, h=0.0, tan="f"),                                # L closes (b3)
               K(39, h=0.05, o=0.27), K(40.5, o=0.19, y=0.02, h=0.0, tan="f"),
               K(45, o=0.19, y=0.02, h=0.0, tan="f"), K(47, h=0.06, o=0.27, y=0.0),          # L steps out (b4)
               K(49.5, o=0.34, y=-0.01, h=0.0, k=14.0, tan="f"),
               K(73, o=0.34, y=-0.01, h=0.0, p=0.0, g=1.0, k=14.0, tan="f"),
               K(75, h=0.0, p=0.0, g=1.0, k=20.0, tan="f"), K(77, p=-16.0, g=1.0),    # knee pop L (b6)
               K(80, p=0.0, g=1.0, k=10.0, tan="f"),
               K(86.5, o=0.34, y=-0.01, h=0.0, tan="f"), K(88, h=0.04, o=0.27),        # close for the spin
               K(89.5, o=0.21, y=0.0, h=0.0, w=5.0, tan="f"),
               ] + _tuck(93.5, 97.5, 0.15, y=0.05, o=0.21, lead=-0.3, o0=0.21)[1:] + _tuck(99.5, 105.0, 0.23, y=0.07, o=0.33, o0=0.21)[1:] + [
               K(105, k=22.0, w=14.0),
               K(112, o=0.33, y=0.0, h=0.0, p=0.0, g=1.0, k=18.0, tan="f"),
               K(113.5, h=0.04, o=0.27), K(115.5, o=0.19, y=0.0, h=0.0, k=6.0, w=5.0, tan="f"),
               K(120, o=0.19, y=0.0, h=0.0, k=6.0, w=5.0)],
         "R": [K(0, o=0.19, y=0.0, h=0.0, p=0.0, w=5.0, g=1.0, t=0.0, k=6.0, tan="f"),
               K(2.0, h=0.0, o=0.19, y=0.0, p=-14.0, w=5.0, g=1.0, tan="f"), K(3.6, h=0.05, o=0.25, y=-0.02, p=0.0, g=0.0),
               K(5.0, h=0.0, o=0.29, y=-0.05, k=18.0, w=8.0, g=1.0, tan="f"),
               K(14, k=10.0), K(24.5, p=0.0, g=1.0, tan="f"), K(26, p=-16.0, g=1.0),
               K(28.5, p=0.0, g=1.0, tan="f"),
               K(30, o=0.29, y=-0.05, h=0.0, tan="f"), K(32, h=0.06, o=0.37, y=-0.03),   # R steps out (b3)
               K(34.5, o=0.45, y=-0.02, h=0.0, k=14.0, tan="f"),
               K(52.5, o=0.45, y=-0.02, h=0.0, tan="f"), K(54, h=0.05, o=0.37),        # R closes (b4)
               K(55.5, o=0.29, y=0.0, h=0.0, tan="f"),
               K(56.5, h=0.0, y=0.0, p=0.0, t=0.0, o=0.29, g=1.0, tan="f"),
               K(58, h=0.12, y=0.12, p=20.0, t=4.0, o=0.26, g=0.0),                    # chamber
               K(60, h=0.31, y=0.50, p=-36.0, t=-14.0, o=0.24, tan="f"),              # KICK 45 deg, toe pointed
               K(62.5, h=0.30, y=0.49, p=-33.0, t=-12.0),
               K(65, h=0.31, y=0.505, p=-35.0, t=-14.0, tan="f"),
               K(68, h=0.12, y=0.14, p=8.0, t=0.0, o=0.28),
               K(70.5, h=0.0, y=0.0, p=0.0, o=0.30, g=1.0, k=14.0, tan="f"),
               K(82.5, h=0.0, p=0.0, g=1.0, k=20.0, tan="f"), K(84.5, p=-16.0, g=1.0),  # knee pop R (b6)
               K(87.5, p=0.0, g=1.0, k=10.0, tan="f"),
               K(89, o=0.30, y=0.0, h=0.0, tan="f"), K(90.5, h=0.04, o=0.25),
               K(92, o=0.20, y=0.0, h=0.0, w=5.0, tan="f"),
               ] + _tuck(93.5, 97.5, 0.18, y=0.04, o=0.20, lead=0.3, o0=0.20)[1:] + _tuck(99.5, 105.0, 0.25, y=0.05, o=0.28, settle=-0.05, o0=0.20)[1:] + [
               K(105, k=18.0, w=8.0),
               K(115, o=0.28, y=-0.05, h=0.0, p=0.0, g=1.0, k=18.0, tan="f"),
               K(116.5, h=0.04, o=0.24, y=-0.03), K(118.5, o=0.19, y=0.0, h=0.0, k=6.0, w=5.0, tan="f"),
               K(120, o=0.19, y=0.0, h=0.0, k=6.0, w=5.0)],
     })


def _taps():
    """Phrase B beats 1-4: alternating forward heel taps on the 8ths with yaw/roll wiggles."""
    L, R, root = [], [], []
    for i in range(8):
        f = i * 7.5
        leg = L if i % 2 == 0 else R
        if f > 0:
            leg.append(K(f, h=0.0, y=0.0, p=0.0, g=1.0, tan="f"))
        reach = 0.20 if i % 4 != 3 else 0.24                     # the 4th tap of each pair reaches further
        leg += [K(f + 2.0, h=0.045, y=0.10, p=8.0, g=0.0),
                K(f + 3.5, h=0.0, y=reach, p=24.0, g=1.0, tan="f"), K(f + 5.5, h=0.035, y=0.08, p=4.0, g=0.0),
                K(f + 7.0, h=0.0, y=0.0, p=0.0, g=1.0, tan="f")]
        sgn = -1.0 if i % 2 == 0 else 1.0
        if i > 0:
            root.append(K(f, w=-sgn * 10.0))
        root.append(K(f + 3.0, w=sgn * 13.0, r=sgn * 5.0, tan="f"))
    return L, R, root


_tL, _tR, _troot = _taps()
clip("wk_dance_b", 4.0, notes="phrase B: alternating heel taps on the 8ths with yaw/roll wiggles and 4.5 cm "
     "groove dips (b1-4), hop and hop (b5, b6: ballistic, feet tucked 9-12 cm above the body's lift, alternating "
     "which foot tucks higher), big gathered HOP with a 15 cm tuck (b7), pose hit on b8 with the weight on L and "
     "the R toe pointed out to the side, settle",
     layers=[dance_stance()],
     root=[K(0, x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0)] + _troot + [
         K(15, z=(-0.052, "f")), K(17.5, z=(-0.094, (2.0, "f"))), K(22, z=-0.055),
         K(30, z=(-0.052, "f")), K(32.5, z=(-0.094, (2.0, "f"))), K(37, z=-0.055),
         K(45, z=(-0.052, "f")), K(47.5, z=(-0.094, (2.0, "f"))), K(52, z=-0.055),
         K(57.5, w=0.0, r=0.0, z=(-0.050, "f")),
         K(60, z=(-0.090, (2.0, "f")), p=2.0),                                           # hop (b5)
         K(68, z=-0.070, p=3.0, r=2.0, tan="f"),
         K(72, z=-0.050, r=0.0),
         K(75, z=-0.090, p=2.0, tan="f"),                                               # hop (b6)
         K(83, z=-0.070, p=3.0, r=-2.0, tan="f"),
         K(88, z=-0.108, p=5.0, r=0.0, tan="f"),                                        # big gather
         K(95, p=-8.0, r=4.0),                                                          # HOP apex (b7)
         K(102.5, z=-0.105, p=4.0, r=0.0, tan="f"),
         K(105, z=-0.072, p=-5.0, r=-8.0, x=-0.05),                                    # pose hit (b8)
         K(107, z=-0.075, p=-6.0, r=-8.6),
         K(111, z=-0.064, p=-5.5, r=-8.0, x=-0.05),
         K(116, z=-0.034, p=1.5, r=0.0, x=0.0),
         K(120, x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0),
     ] + _hop(61.5, 67.0, -0.042) + _hop(76.5, 82.0, -0.042) + _hop(90.5, 100.0, -0.025),
     feet={
         "L": [K(0, o=0.19, y=0.0, h=0.0, p=0.0, w=5.0, g=1.0, t=0.0, tan="f")] + _tL + [
             K(58, h=0.0, y=0.0, p=0.0, tan="f")]
             + _tuck(61.5, 67.0, 0.14, y=0.05, lead=-0.3)[1:] + _tuck(76.5, 82.0, 0.11, y=0.03, lead=0.3)[1:]
             + _tuck(90.5, 100.0, 0.27, y=0.07, o=0.23, lead=-0.4)[1:] + [
             K(110, h=0.0, o=0.23, tan="f"), K(113, h=0.04, o=0.21), K(116, h=0.0, o=0.19, tan="f"),
             K(120, h=0.0, o=0.19)],
         "R": [K(0, o=0.19, y=0.0, h=0.0, p=0.0, w=5.0, g=1.0, t=0.0, tan="f")] + _tR + [
             K(60, h=0.0, p=0.0, t=0.0, g=1.0, tan="f")]
             + _tuck(61.5, 67.0, 0.11, y=0.02, lead=0.3)[1:] + _tuck(76.5, 82.0, 0.145, y=0.06, lead=-0.3)[1:]
             + _tuck(90.5, 100.0, 0.30, y=0.05, o=0.25, lead=0.4)[1:] + [
             K(102.5, h=0.0, o=0.25, y=0.0, p=0.0, g=1.0, tan="f"),
             K(104, h=0.03, o=0.33, y=0.03, p=-10.0, g=0.0),
             K(105, h=0.0, o=0.42, y=0.06, p=-34.0, t=-14.0, w=24.0, g=1.0, tan="f"),     # toe pointed out
             K(111, o=0.42, y=0.06, h=0.0, w=24.0, p=-32.0, t=-12.0, g=1.0, tan="f"),
             K(113, h=0.04, o=0.32, y=0.03, p=-6.0, t=0.0, g=0.0),
             K(116, h=0.0, o=0.22, y=0.0, p=0.0, w=5.0, g=1.0, tan="f"),
             K(117.5, h=0.03, o=0.20), K(119, h=0.0, o=0.19, tan="f"),
             K(120, h=0.0, o=0.19)],
     })

clip("wk_dance_c", 4.0, notes="phrase C: heel-toe taps with body counter-rolls (b1-2), double knee pops with "
     "the knees snapping out and alternating heel pops (b3), body wave (b4), FLAMINGO knee-up hit on the L "
     "leg with a balance wobble (b5), quick knee swap (b6), ballistic side hops R then L with tucks (b7), "
     "asymmetric ta-da (b8) and step back in",
     layers=[dance_stance()],
     root=[
         K(0, x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0),
         K(3, p=-4.0, r=6.0, z=-0.058, x=0.04), K(10, p=3.0, r=-3.0, z=-0.045),          # b1 heel / toe
         K(15, z=-0.045), K(18, p=-4.0, r=-6.0, z=-0.058, x=-0.04),
         K(25, p=3.0, r=3.0, z=-0.045, x=0.0),                                          # b2
         K(30, z=(-0.045, "f")), K(32.5, z=(-0.092, (2.0, "f"))), K(30, r=0.0), K(32.5, r=7.5), K(36, z=-0.050),   # b3 pops
         K(37.5, z=(-0.05, "f")), K(40.0, z=(-0.096, (2.0, "f"))), K(40, r=-7.5), K(44, z=-0.050, r=0.0),
         K(45, p=2.0, w=0.0), K(49, p=10.0, w=-9.0, z=-0.068), K(53, p=-8.0, w=5.0, z=-0.036),   # b4 wave
         K(57, p=4.0, w=9.0, z=-0.055, x=0.0),
         K(59, p=0.0, w=2.0, x=-0.07, r=-4.0, z=-0.055),
         K(62, p=-6.0, r=-8.5, w=0.0, z=-0.048, x=-0.088, tan="f"),                     # FLAMINGO (b5)
         K(64.5, r=-10.0), K(66.5, r=-7.4), K(68.5, r=-9.0),
         K(71, r=-2.0, p=0.0, x=-0.03, z=-0.056),
         K(73, z=-0.056, x=0.05, r=4.0),
         K(75, z=-0.052, x=0.085, r=8.5, p=-4.0, tan="f"),                             # b6 swap (R stands)
         K(79, r=7.0), K(82, r=8.4), K(85, z=-0.055, x=0.03, r=2.0, p=0.0),
         K(87.5, z=-0.060, x=0.0, r=0.0),
         K(88.5, z=-0.094, x=0.0, tan="f"),                                             # hop R (b7)
         K(93.5, x=0.06, r=4.0),
         K(97.5, z=-0.086, x=0.11, r=2.0, tan="f"),                                    # absorb, hop L
         K(101.25, x=0.05, r=-4.0),
         K(105.5, z=-0.096, r=-8.5, p=-5.5, x=-0.03, tan="f"),                         # TA-DA (b8) landing hit
         K(108, z=-0.078, r=-9.0, p=-6.0),
         K(111.5, z=-0.084, r=-8.4, p=-5.4),
         K(116, z=-0.042, r=0.0, p=1.0, x=0.0),
         K(120, x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0),
     ] + _hop(90.5, 96.5, -0.046) + _hop(98.5, 104.0, -0.046),
     feet={
         "L": [K(0, o=0.19, y=0.0, h=0.0, p=0.0, w=5.0, g=1.0, t=0.0, k=6.0, tan="f"),
               K(1.5, h=0.04, y=0.09, p=8.0, g=0.0), K(3.5, h=0.0, y=0.22, p=26.0, g=1.0, tan="f"),   # heel tap fwd
               K(6, h=0.04, y=0.06, p=0.0, g=0.0), K(7.7, h=0.015, y=-0.14, p=-28.0, g=1.0),
               K(8.5, h=0.0, y=-0.14, p=-28.0, t=-12.0, g=1.0, tan="f"),  # toe tap back
               K(9.3, h=0.0, y=-0.14, p=-28.0, g=1.0, tan="f"),
               K(10.5, h=0.035, y=-0.05, p=-6.0, t=-2.0, g=0.0), K(12.5, h=0.0, y=0.0, p=0.0, t=0.0, g=1.0, tan="f"),
               K(30, p=0.0, g=1.0, k=6.0, tan="f"), K(32, p=-18.0, g=1.0, k=22.0),            # knee pop L
               K(35, p=0.0, g=1.0, k=8.0, tan="f"), K(39.5, k=20.0), K(43, k=8.0),
               K(71, h=0.0, y=0.0, p=0.0, g=1.0, tan="f"),
               K(73, h=0.11, y=0.10, p=6.0, t=0.0, g=0.0), K(75, h=0.21, y=0.18, p=-18.0, t=-8.0, k=14.0, tan="f"),   # knee up L (b6)
               K(80, h=0.20, y=0.17, p=-16.0), K(83, h=0.21, y=0.18, tan="f"),
               K(86.5, h=0.0, y=0.0, p=0.0, t=0.0, g=1.0, k=6.0, tan="f"),
               K(89, h=0.0, o=0.19, y=0.0, w=5.0, p=0.0, g=1.0, tan="f"),
               ] + _tuck(90.5, 96.5, 0.13, y=0.04, o=0.08, lead=-0.3)[1:] + _tuck(98.5, 104.0, 0.16, y=0.05, o=0.32, lead=0.2, o0=0.08)[1:] + [
               K(104, k=20.0, w=14.0),
               K(113, h=0.0, o=0.32, y=0.0, tan="f"), K(115, h=0.035, o=0.25), K(117, h=0.0, o=0.19, y=0.0, k=6.0, w=5.0, tan="f"),
               K(120, h=0.0, o=0.19, y=0.0, k=6.0, w=5.0)],
         "R": [K(0, o=0.19, y=0.0, h=0.0, p=0.0, w=5.0, g=1.0, t=0.0, k=6.0, tan="f"),
               K(15, h=0.0, y=0.0, p=0.0, g=1.0, tan="f"),
               K(16.5, h=0.04, y=0.09, p=8.0, g=0.0), K(18.5, h=0.0, y=0.22, p=26.0, g=1.0, tan="f"),
               K(21, h=0.04, y=0.06, p=0.0, g=0.0), K(22.7, h=0.015, y=-0.14, p=-28.0, g=1.0),
               K(23.5, h=0.0, y=-0.14, p=-28.0, t=-12.0, g=1.0, tan="f"),
               K(24.3, h=0.0, y=-0.14, p=-28.0, g=1.0, tan="f"),
               K(25.5, h=0.035, y=-0.05, p=-6.0, t=-2.0, g=0.0), K(27.5, h=0.0, y=0.0, p=0.0, t=0.0, g=1.0, tan="f"),
               K(32, k=20.0), K(35, k=8.0),
               K(37.5, p=0.0, g=1.0, k=8.0, tan="f"), K(39.5, p=-18.0, g=1.0, k=22.0),         # knee pop R
               K(42.5, p=0.0, g=1.0, k=8.0, tan="f"),
               K(58, h=0.0, y=0.0, p=0.0, g=1.0, tan="f"),
               K(60, h=0.13, y=0.11, p=6.0, g=0.0), K(62, h=0.34, y=0.22, p=-22.0, t=-10.0, k=16.0, tan="f"),   # FLAMINGO knee
               K(65, h=0.33, y=0.21), K(68, h=0.34, y=0.22),
               K(70.5, h=0.10, y=0.07, p=0.0, t=0.0), K(72.5, h=0.0, y=0.0, p=0.0, g=1.0, k=6.0, tan="f"),
               K(72.5, w=5.0), K(89, h=0.0, o=0.19, y=0.0, w=5.0, p=0.0, g=1.0, tan="f"),
               ] + _tuck(90.5, 96.5, 0.15, y=0.05, o=0.30, lead=0.3)[1:] + _tuck(98.5, 104.0, 0.12, y=0.03, o=0.26, lead=-0.2, settle=-0.06, o0=0.30)[1:] + [
               K(104, k=16.0, w=8.0),
               K(115, h=0.0, o=0.26, y=-0.06, tan="f"), K(117, h=0.035, o=0.22, y=-0.03), K(119, h=0.0, o=0.19, y=0.0, k=6.0, w=5.0, tan="f"),
               K(120, h=0.0, o=0.19, y=0.0, k=6.0, w=5.0)],
     })


# ---------------------------------------------------------------- swim (1.0 s loop, body-frame legs)
def _paddle(off):
    """Dog-paddle leg in the BODY frame: 5 f power sweep down/back under the chest, 10 f recovery (knee draws
    up below the face, foot reaches forward).  Compact: the leg never straightens below the body (power end
    stays >= 10 cm up and >= 5 cm forward in the body frame)."""
    rows = []
    for c in (0.0, 15.0):
        f = (off + c) % 30.0

        def at(df):
            return (f + df) % 30.0
        rows += [K(at(0.0), o=0.20, y=0.31, h=0.25, p=8.0, t=-6.0),            # reach (power start)
                 K(at(2.5), o=0.215, y=0.17, h=0.15, p=-20.0, t=12.0),
                 K(at(5.0), o=0.225, y=0.06, h=0.11, p=-34.0, t=16.0),       # power end, under the chest
                 K(at(9.0), o=0.21, y=0.10, h=0.21, p=-8.0, t=-10.0),        # knee draws up
                 K(at(12.5), o=0.20, y=0.25, h=0.27, p=12.0, t=-8.0)]
    return sorted(rows, key=lambda k: k[0])


clip("wk_swim", 1.0, loop=True, notes="dog-paddle: body pitched back 20 deg (eyes above the waterline), "
     "alternating compact 15 f leg strokes under the chest (5 f power, 10 f recovery) in the body frame, a 2.5 cm "
     "forward surge + bob after every power stroke, roll in sync",
     root=[K(0, x=0.0, z=0.0, p=-20.0, r=0.0, w=0.0)] + [
         K(0, z2=0.0, p2=0.0, r2=1.6), K(4, z2=0.012, p2=-1.4), K(7.5, z2=0.0, p2=0.0, r2=-1.6),
         K(11.5, z2=0.012, p2=-1.4), K(15, z2=0.0, p2=0.0, r2=1.6), K(19, z2=0.012, p2=-1.4),
         K(22.5, z2=0.0, p2=0.0, r2=-1.6), K(26.5, z2=0.012, p2=-1.4),
     ] + [K(0, w2=1.5), K(15, w2=-1.5)]
       + [K(f, y=-0.012) for f in (0.5, 8.0, 15.5, 23.0)] + [K(f, y=0.014) for f in (5.0, 12.5, 20.0, 27.5)],
     feet={
         "L": [K(0, bw=1.0, k=8.0, w=4.0)] + _paddle(0.0),
         "R": [K(0, bw=1.0, k=8.0, w=4.0)] + _paddle(7.5),
     })


# ======================================================================================
# Bake + write
# ======================================================================================
def flip_toes_if_needed(arm):
    """Idempotent toe flip: rotate toe.L / toe.R 180 deg about world Z through their ankle line."""
    toes = {n: arm.data.bones[n] for n in TOE_BONES}
    needs = [n for n, b in toes.items() if (b.tail_local - b.head_local).y < 0.0]
    report = {"applied": bool(needs), "bones": {}}
    if needs and len(needs) != len(TOE_BONES):
        raise RuntimeError("only some toes point backward: %r" % needs)
    before = {b.name: (b.head_local.copy(), b.tail_local.copy(), b.matrix_local.copy()) for b in arm.data.bones}
    if needs:
        bpy.context.view_layer.objects.active = arm
        arm.select_set(True)
        bpy.ops.object.mode_set(mode="EDIT")
        for n in TOE_BONES:
            eb = arm.data.edit_bones[n]
            m = eb.matrix.copy()
            piv = Matrix.Translation((m.translation.x, 0.0, 0.0))
            eb.matrix = piv @ Matrix.Rotation(math.pi, 4, "Z") @ piv.inverted() @ m
        bpy.ops.object.mode_set(mode="OBJECT")
    worst_other = 0.0
    for b in arm.data.bones:
        h0, t0, m0 = before[b.name]
        if b.name in TOE_BONES:
            if needs:
                piv = Matrix.Translation((m0.translation.x, 0.0, 0.0))
                exp = piv @ Matrix.Rotation(math.pi, 4, "Z") @ piv.inverted() @ m0
                err = max(abs(b.matrix_local[i][j] - exp[i][j]) for i in range(4) for j in range(4))
                assert err < 1e-5, (b.name, err)
            report["bones"][b.name] = {"head": [round(x, 5) for x in b.head_local],
                                       "tail": [round(x, 5) for x in b.tail_local]}
            assert (b.tail_local - b.head_local).y > 0.0, b.name
        else:
            worst_other = max(worst_other, (b.head_local - h0).length, (b.tail_local - t0).length)
    report["other_bones_max_dev"] = worst_other
    assert worst_other < 1e-6
    return report


def remove_old_actions(arm):
    removed = []
    ad = arm.animation_data
    if ad:
        ad.action = None
        for tr in list(ad.nla_tracks):
            if any(s.action and s.action.name.startswith("wk_") for s in tr.strips) or tr.name.startswith("wk_"):
                ad.nla_tracks.remove(tr)
    for a in list(bpy.data.actions):
        if a.name.startswith("wk_"):
            removed.append(a.name)
            bpy.data.actions.remove(a)
    return removed


def bake_clip(rig, clip, side):
    ev = Evaluator(clip, side)
    N = clip.frames
    frames = []
    for f in range(N + 1):
        t = float(f % N) if clip.loop else float(f)
        P = ev.values(t)
        if clip.seat and clip.seat[0] - 1e-6 <= t <= clip.seat[1] + 1e-6:
            rv = P["root"]
            zc = rig.seat_z(rv)
            if rv["z"] + rv["z2"] < zc:
                rv["z"] = zc - rv["z2"]
        spin = ev.spin_at(t, P)
        poses, diag = rig.solve(P, t, spin)
        frames.append((P, poses, diag))
    return ev, frames


def write_action(arm, rig, name, frames, slot_name):
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    slot = act.slots.new(id_type="OBJECT", name=slot_name)
    layer = act.layers.new("Layer")
    strip = layer.strips.new(type="KEYFRAME")
    cb = strip.channelbag(slot, ensure=True)
    chans = {}
    prevq = {}
    for f, (P, poses, diag) in enumerate(frames):
        loc_rot = rig.local_channels(poses)
        for bone in rig.order:
            loc, q = loc_rot[bone]
            if bone in prevq and prevq[bone].dot(q) < 0.0:
                q = -q
            prevq[bone] = q
            for i in range(3):
                chans.setdefault((bone, "location", i), []).extend((float(f), float(loc[i])))
            for i in range(4):
                chans.setdefault((bone, "rotation_quaternion", i), []).extend((float(f), float(q[i])))
    groups = {}
    for (bone, prop, idx), co in chans.items():
        path = 'pose.bones["%s"].%s' % (bone, prop)
        fc = cb.fcurves.new(path, index=idx)
        if bone not in groups:
            groups[bone] = cb.groups.new(bone)
        fc.group = groups[bone]
        n = len(co) // 2
        fc.keyframe_points.add(n)
        fc.keyframe_points.foreach_set("co", co)
        fc.keyframe_points.foreach_set("interpolation", [1] * n)   # LINEAR between baked frames
        fc.update()
    return act, slot


def attach_actions(arm, actions, active_name="wk_idle"):
    if arm.animation_data is None:
        arm.animation_data_create()
    ad = arm.animation_data
    for act, slot in actions:
        tr = ad.nla_tracks.new()
        tr.name = act.name
        st = tr.strips.new(act.name, 0, act)
        try:
            st.action_slot = slot
        except Exception:
            pass
        tr.mute = True
    set_active(arm, actions, active_name)


def set_active(arm, actions, active_name):
    ad = arm.animation_data
    act, slot = [(a, s) for a, s in actions if a.name == active_name][0]
    ad.action = act
    try:
        ad.action_slot = slot
    except Exception:
        pass


# ======================================================================================
# Verification
# ======================================================================================
BODY_HALF = (0.424, 0.200)      # body/head cube half extents (x, y), root-local rest frame
BODY_Z = (-0.270, 0.338)        # cube bottom / top relative to the root bone head


def body_clearance(rig, diag):
    """Deepest intrusion (m, >0 = inside) of the legs (knee, distal thigh, shin, ankle; leg radius 6.5 cm)
    into the rigid body cube."""
    Dinv = (diag["root"] @ rig.rest_inv[ROOT]).inverted()
    worst = -1.0
    r = 0.06
    for s in "LR":
        d = diag["legs"][s]
        # the proximal thigh legitimately tucks under the cube edge (hip pivot is 11 cm inside the body);
        # test the knee and everything distal to it
        pts = [d["K"], d["K"].lerp(d["A"], 0.5), d["A"]]
        for pnt in pts:
            q = Dinv @ pnt
            depth = min(BODY_HALF[0] + r - abs(q.x), BODY_HALF[1] + r - abs(q.y), q.z - (BODY_Z[0] - r),
                        BODY_Z[1] - q.z)
            worst = max(worst, depth)
    return worst


def verify_clip(rig, clip, side, frames):
    N = clip.frames
    clip_depth = -1.0
    slip = {"L": 0.0, "R": 0.0}
    slide = {"L": 0.0, "R": 0.0}
    pen = 0.0
    over = 0.0
    knee_fwd_min = 1e9
    knee_pole_min = 1e9
    flex_jump = 0.0
    lat_jump = 0.0
    prev = None
    max_flex = 0.0
    for f, (P, poses, diag) in enumerate(frames):
        for s in "LR":
            d = diag["legs"][s]
            low = min(d["heel"].z, d["ball"].z) - rig.ground_z
            pen = min(pen, low)
            over = max(over, d["over"])
            kn = d["koff"].length
            if kn > 0.01:
                knee_pole_min = min(knee_pole_min, d["koff"].normalized().dot(d["pole"]))
                fw = d["fwd"]
                up = Vector((0.0, 0.0, 1.0))
                # 'forward' reference: body forward, blended toward up for raised legs (sit / kicks)
                ref = (fw + up * max(0.0, (d["A"] - d["H"]).normalized().dot(fw) * 2.0)).normalized()
                knee_fwd_min = min(knee_fwd_min, d["koff"].normalized().dot(ref))
            max_flex = max(max_flex, d["flex"])
            if prev is not None:
                p = prev["legs"][s]
                flex_jump = max(flex_jump, abs(d["flex"] - p["flex"]))
                lat_jump = max(lat_jump, math.degrees(d["lat"].angle(p["lat"], 0.0)))
                # support slip: both frames grounded flat-ish -> contact point must not move
                for key in ("heel", "ball"):
                    a = p[key]
                    b = d[key]
                    if a.z - rig.ground_z < 0.003 and b.z - rig.ground_z < 0.003:
                        dy = (b.y - a.y) - (clip.treadmill or 0.0)
                        mv = math.hypot(b.x - a.x, dy)
                        sl = clip.slides.get(s)
                        if sl and sl[0] <= f <= sl[1]:
                            slide[s] = max(slide[s], mv)
                        else:
                            slip[s] = max(slip[s], mv)
        clip_depth = max(clip_depth, body_clearance(rig, diag))
        prev = diag
    rep = dict(frames=N, seconds=round(clip.seconds, 4), loop=clip.loop,
               slip_mm={s: round(v * 1000, 2) for s, v in slip.items()},
               penetration_mm=round(pen * 1000, 2), overreach_mm=round(over * 1000, 2),
               knee_forward_min=round(knee_fwd_min, 3), knee_pole_min=round(knee_pole_min, 3),
               knee_flex_max_deg=round(max_flex, 1), knee_flex_jump_deg_per_f=round(flex_jump, 1),
               knee_plane_jump_deg_per_f=round(lat_jump, 1), body_clip_mm=round(max(0.0, clip_depth) * 1000, 1))
    if clip.slides:
        rep["authored_slide"] = {s: {"frames": list(clip.slides[s]), "max_mm_per_f": round(slide[s] * 1000, 1)}
                                 for s in clip.slides}
    if clip.loop:
        a = frames[0][1]
        b = frames[-1][1]
        rep["loop_seam"] = round(max((a[n].translation - b[n].translation).length for n in a), 6)
    return rep


def weight_metrics(rig, clip, side, frames):
    """Sided clips: does the body accept the weight over the support BEFORE the work foot lifts, hold it while
    the foot is off the ground and give it back only AFTER the foot plants?  shift = root lateral offset toward
    the support leg, normalised by its maximum."""
    sg = SIDE_X[side]
    shift = [-sg * (fr[2]["root"].translation.x - rig.head0.x) for fr in frames]
    smax = max(shift)
    low = [min(fr[2]["legs"][side]["heel"].z, fr[2]["legs"][side]["ball"].z) - rig.ground_z for fr in frames]
    air = [i for i, v in enumerate(low) if v > 0.003]
    if not air or smax < 1e-4:
        return None
    lift, land = air[0], air[-1] + 1
    n = lambda i: round(shift[max(0, min(len(shift) - 1, i))] / smax, 3)
    N = len(frames) - 1
    return {"shift_max_mm": round(smax * 1000, 1), "lift_frame": lift, "plant_frame": land,
            # for the runtime work-foot envelope: the authored foot is planted outside [lift_norm, plant_norm]
            "lift_norm": round(lift / N, 3), "plant_norm": round(land / N, 3),
            "shift_at_lift_minus3": n(lift - 3), "shift_min_airborne": round(min(shift[i] for i in air) / smax, 3),
            "shift_at_plant": n(land), "shift_at_plant_minus2": n(land - 2),
            "frames_after_plant": len(frames) - 1 - land}


def body_points(rig, diag):
    D = diag["root"] @ rig.rest_inv[ROOT]
    cs = [D @ (rig.head0 + Vector((sx * BODY_HALF[0], sy * BODY_HALF[1], z)))
          for sx in (-1, 1) for sy in (-1, 1) for z in BODY_Z]
    return cs, sum(cs, Vector()) / 8.0


def balance_metrics(rig, frames):
    """Unsided clips: fore-aft balance of the body centre over the grounded sole points while the bottom is
    off the ground, and the bottom touchdown speed (sit)."""
    worst, worst_f, bottoms, outside = 0.0, None, [], []
    for f, (P, poses, diag) in enumerate(frames):
        cs, cen = body_points(rig, diag)
        bottom = min(p.z for p in cs) - rig.ground_z
        bottoms.append(bottom)
        ys = []
        for s in "LR":
            d = diag["legs"][s]
            for key in ("heel", "ball", "toe_tip"):
                if d[key].z - rig.ground_z < 0.006:
                    ys.append(d[key].y)
        if bottom > 0.02 and ys:
            out = max(min(ys) - cen.y, cen.y - max(ys), 0.0)
            if out > 0.03:
                outside.append((f, round(bottom, 3), round(out * 1000)))
            if out > worst:
                worst, worst_f = out, f
    rep = {"com_outside_support_max_mm": round(worst * 1000, 1), "com_outside_support_frame": worst_f,
           # (frame, bottom height m, COM distance outside the grounded soles mm) for every frame > 30 mm
           "com_outside_frames": outside}
    # downward acceleration of the body while the LEGS carry it (bottom off the ground): legs can only push,
    # so anything well above 1 g reads as being yanked down (or a rise stopping dead)
    zs = [fr[2]["root"].translation.z for fr in frames]
    acc = [(-(zs[i + 1] - 2 * zs[i] + zs[i - 1]) * FPS * FPS / 9.81, i) for i in range(1, len(zs) - 1)
           if min(bottoms[i - 1:i + 2]) > 0.01]
    worst_acc = max(acc + [(0.0, None)])
    rep["root_down_accel_max_g"] = round(worst_acc[0], 2)
    rep["root_down_accel_frame"] = worst_acc[1]
    touch = [f for f in range(1, len(bottoms)) if bottoms[f] < 0.006 <= bottoms[f - 1]]
    if touch:
        f = touch[0]
        rep["bottom_touch_frame"] = f
        rep["bottom_touch_speed_cm_per_f"] = round((bottoms[f - 1] - bottoms[f]) * 100, 2)
        rep["bottom_speed_max_cm_per_f"] = round(max(abs(bottoms[i] - bottoms[i - 1]) for i in range(1, len(bottoms))) * 100, 2)
    return rep


def pose_reference(rig, frames):
    """Bone heads (+ leaf bone tails) per frame in Godot SKELETON space (x, z, -y of Blender armature space),
    for the per-frame Blender-vs-Godot comparison in harness/scripts/clip_inventory.gd."""
    out = []
    lengths = {b.name: b.length for b in rig.arm.data.bones}
    for P, poses, diag in frames:
        fr = {}
        for name in rig.order:
            m = poses[name]
            h = m.translation
            fr[name] = [round(h.x, 6), round(h.z, 6), round(-h.y, 6)]
            if name in TOE_BONES:
                t = (m @ Matrix.Translation((0.0, lengths[name], 0.0))).translation
                fr[name + ":tail"] = [round(t.x, 6), round(t.z, 6), round(-t.y, 6)]
        out.append(fr)
    return out


def contact_pose(rig, ev, clip, side):
    """Authored work-foot pose at the exact 0.56 event time, in Godot MODEL space (x right, y up, -z = face),
    so the runtime can retarget the authored stroke relative to the real contact point."""
    t = 0.56 * clip.frames
    P = ev.values(t)
    poses, diag = rig.solve(P, t, ev.spin_at(t, P))
    d = diag["legs"][side]
    arm_z = rig.arm.matrix_world.translation.z

    def model(v):
        return [round(v.x, 4), round(v.z + arm_z, 4), round(-v.y, 4)]
    toe_dir = (d["toe_tip"] - poses[LEGS[side][3]].translation).normalized()
    return {"frame": round(t, 2), "ankle": model(d["A"]), "toe_tip": model(d["toe_tip"]), "hip": model(d["H"]),
            "toe_dir": [round(toe_dir.x, 3), round(toe_dir.z, 3), round(-toe_dir.y, 3)],
            "foot_pitch_deg": round(P[side]["p"], 1)}


def roundtrip_check(arm, built, src):
    """Evaluate the WRITTEN actions in Blender and compare bone heads with the solver's targets."""
    ad = arm.animation_data
    sc = bpy.context.scene
    worst = 0.0
    for act, slot in built:
        n, diags, idx = src[act.name]
        ad.action = act
        try:
            ad.action_slot = slot
        except Exception:
            pass
        for f, d in zip(idx, diags):
            sc.frame_set(f)
            P = arm.pose.bones
            for s in "LR":
                th, sh, an, toe = LEGS[s]
                L = d["legs"][s]
                worst = max(worst, (P[th].head - L["H"]).length, (P[sh].head - L["K"]).length,
                            (P[an].head - L["A"]).length)
    return worst


def mirror_error(fl, fr):
    """Max distance between the L variant and the X-mirrored R variant (hips, knees, ankles, toe tips, root
    axes), i.e. the R clip is an exact armature-space mirror even though the bone rest axes differ."""
    worst = 0.0
    sw = {"L": "R", "R": "L"}
    for (_, _, dl), (_, _, dr) in zip(fl, fr):
        for s in "LR":
            a = dl["legs"][s]
            b = dr["legs"][sw[s]]
            for k in ("H", "K", "A", "toe_tip", "heel", "ball"):
                m = Vector((-b[k].x, b[k].y, b[k].z))
                worst = max(worst, (a[k] - m).length)
        ra, rb = dl["root"], dr["root"]
        for col in range(3):
            va = ra.col[col].to_3d()
            vb = rb.col[col].to_3d()
            mb = Vector((-vb.x, vb.y, vb.z))
            # mirrored rotation: axis vectors mirror with a sign flip on the mirrored axis column
            worst = max(worst, min((va - mb).length, (va + mb).length) * 0.3)
        worst = max(worst, (Vector((-rb.translation.x, rb.translation.y, rb.translation.z)) - ra.translation).length)
    return worst


def bone_rest_table(arm):
    return {b.name: (tuple(round(x, 6) for x in b.head_local), tuple(round(x, 6) for x in b.tail_local))
            for b in arm.data.bones}


# ======================================================================================
# Main
# ======================================================================================
def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("inp")
    ap.add_argument("out")
    ap.add_argument("--only", default="", help="comma separated base clip names (debug; still removes all wk_*)")
    ap.add_argument("--report", default="")
    ap.add_argument("--dump", default="", help="print per-frame armature-space samples of these variants")
    ap.add_argument("--issues", action="store_true", help="with --dump: only frames with slip/penetration/reach")
    ap.add_argument("--pose-ref", default="", help="write per-frame bone heads (Godot skeleton space) to this JSON "
                    "for harness/scripts/clip_inventory.gd --ref=")
    args = ap.parse_args(argv)

    bpy.ops.wm.open_mainfile(filepath=os.path.abspath(args.inp))
    arm = bpy.data.objects.get(ARMATURE)
    if arm is None or arm.type != "ARMATURE":
        raise RuntimeError("armature %s not found" % ARMATURE)
    rest_before = bone_rest_table(arm)
    toe_report = flip_toes_if_needed(arm)
    rest_after = bone_rest_table(arm)
    changed = sorted(n for n in rest_before if rest_before[n] != rest_after[n])
    assert set(changed) <= set(TOE_BONES), changed
    for pb in arm.pose.bones:
        if pb.constraints:
            raise RuntimeError("unexpected constraints on %s" % pb.name)
        pb.rotation_mode = "QUATERNION"
    removed = remove_old_actions(arm)
    rig = Rig(arm)

    only = set(x for x in args.only.split(",") if x)
    built = []
    report = {"input": os.path.abspath(args.inp), "output": os.path.abspath(args.out), "toe_flip": toe_report,
              "removed_actions": removed, "bones_changed": changed, "clips": {}}
    dump = set(x for x in args.dump.split(",") if x)
    roundtrip_src = {}
    pose_ref = {}
    slot_name = arm.name
    for c in LIBRARY:
        if only and c.name not in only:
            continue
        baked = {}
        for vname, side in c.variants():
            ev, frames = bake_clip(rig, c, side)
            baked[side] = frames
            act, slot = write_action(arm, rig, vname, frames, slot_name)
            built.append((act, slot))
            roundtrip_src[vname] = (c.frames, [frames[i][2] for i in sorted(set(
                [0, c.frames // 4, c.frames // 2, (3 * c.frames) // 4, c.frames]))],
                sorted(set([0, c.frames // 4, c.frames // 2, (3 * c.frames) // 4, c.frames])))
            rep = verify_clip(rig, c, side, frames)
            if side is not None:
                wm = weight_metrics(rig, c, side, frames)
                if wm:
                    rep["weight"] = wm
            else:
                rep["balance"] = balance_metrics(rig, frames)
            if c.seat:
                # authored seat descent per frame (m below the rest root height); the runtime can drive the
                # native seat_drop from this curve and subtract the body's actual drop from the visual root
                rep["seat_descent_m"] = [round(rig.head0.z - fr[2]["root"].translation.z, 4) for fr in frames]
            if args.pose_ref:
                pose_ref[vname] = pose_reference(rig, frames)
            rep["contact_normalized"] = 0.56 if c.contact is not None else None
            if c.contact is not None and side is not None:
                rep["contact_pose"] = contact_pose(rig, ev, c, side)
            rep["notes"] = c.notes
            report["clips"][vname] = rep
            if vname in dump or "all" in dump:
                _dump(rig, vname, frames, only_issues=args.issues, clip_tm=c.treadmill)
            if side == "R" and "L" in baked:
                rep["mirror_error_mm"] = round(mirror_error(baked["L"], baked["R"]) * 1000, 3)
    if not any(a.name == "wk_idle" for a, s in built):
        raise RuntimeError("wk_idle must be built (runtime settle gate)")
    attach_actions(arm, built)
    report["roundtrip_max_mm"] = round(roundtrip_check(arm, built, roundtrip_src) * 1000, 4)
    set_active(arm, built, "wk_idle")      # the round trip leaves its last clip assigned
    report["active_action"] = arm.animation_data.action.name
    sc = bpy.context.scene
    sc.render.fps = FPS
    sc.render.fps_base = 1.0
    sc.frame_start = 0
    sc.frame_end = max(250, max(c.frames for c in LIBRARY))
    sc.frame_set(0)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    # relative_remap=False: keep '//textures/...' image paths exactly as in the input, so out.blend can be
    # written anywhere and then copied next to the input / into game/LogicObjects/Wako
    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(args.out), compress=True, copy=False,
                                relative_remap=False)
    report["actions_written"] = len(built)
    if args.pose_ref:
        with open(args.pose_ref, "w") as fh:
            json.dump({"space": "godot_skeleton (x, z, -y of blender armature space)", "fps": FPS,
                       "rest": {b.name: [round(b.head_local.x, 6), round(b.head_local.z, 6), round(-b.head_local.y, 6)]
                                for b in arm.data.bones},
                       "rest_tail": {n: [round(arm.data.bones[n].tail_local.x, 6), round(arm.data.bones[n].tail_local.z, 6),
                                         round(-arm.data.bones[n].tail_local.y, 6)] for n in TOE_BONES},
                       "clips": pose_ref}, fh)
    _print_report(report)
    if args.report:
        with open(args.report, "w") as fh:
            json.dump(report, fh, indent=1, sort_keys=True)
    return report


def _dump(rig, name, frames, only_issues=False, clip_tm=None):
    print("== dump", name)
    prev = None
    for f, (P, poses, diag) in enumerate(frames):
        if only_issues:
            msgs = []
            for s in "LR":
                d = diag["legs"][s]
                low = min(d["heel"].z, d["ball"].z) - rig.ground_z
                if low < -0.002:
                    msgs.append("%s pen %.1fmm" % (s, low * 1000))
                if d["over"] > 0.002:
                    msgs.append("%s over %.1fmm" % (s, d["over"] * 1000))
                if prev is not None:
                    for key in ("heel", "ball"):
                        a, b = prev["legs"][s][key], d[key]
                        if a.z - rig.ground_z < 0.003 and b.z - rig.ground_z < 0.003:
                            mv = math.hypot(b.x - a.x, (b.y - a.y) - (clip_tm or 0.0))
                            if mv > 0.002:
                                msgs.append("%s %s slip %.1fmm" % (s, key, mv * 1000))
            prev = diag
            bc = body_clearance(rig, diag)
            if bc > 0.0:
                msgs.append("body clip %.0fmm" % (bc * 1000))
            if msgs:
                print("  f%3d %s" % (f, "; ".join(msgs)))
            continue
        r = diag["root"].translation
        parts = ["f%3d root(%+.3f %+.3f %+.3f)" % (f, r.x, r.y, r.z)]
        for s in "LR":
            d = diag["legs"][s]
            parts.append("%s A(%+.3f %+.3f %+.3f) K(%+.3f %+.3f %+.3f) flex %5.1f over %.3f low %+.3f" % (
                s, d["A"].x, d["A"].y, d["A"].z - rig.ground_z, d["K"].x, d["K"].y, d["K"].z - rig.ground_z,
                d["flex"], d["over"], min(d["heel"].z, d["ball"].z) - rig.ground_z))
        print("  ".join(parts))


def _print_report(rep):
    print("toe flip:", json.dumps(rep["toe_flip"]))
    print("removed %d old actions; wrote %d; written-action round trip max error %.4f mm; active %s" % (
        len(rep["removed_actions"]), rep["actions_written"], rep["roundtrip_max_mm"], rep.get("active_action")))
    hdr = "%-18s %4s %6s %4s %6s %6s %5s %5s %5s %6s %5s %5s | %s" % (
        "clip", "frm", "sec", "loop", "slipL", "slipR", "pen", "over", "kfwd", "flexmx", "dflex", "bclip",
        "weight: lift plant accept@-3f min-airborne at-plant frames-after | balance: COM-out max, down-accel g")
    print(hdr)
    for n, r in rep["clips"].items():
        extra = ""
        w = r.get("weight")
        if w:
            extra = "w %2d %2d %.2f %.2f %.2f %d" % (w["lift_frame"], w["plant_frame"], w["shift_at_lift_minus3"],
                                                    w["shift_min_airborne"], w["shift_at_plant"], w["frames_after_plant"])
        b = r.get("balance")
        if b:
            extra = "b %.0fmm %.2fg" % (b["com_outside_support_max_mm"], b["root_down_accel_max_g"])
            if "bottom_touch_frame" in b:
                extra += " touch f%d @%.1fcm/f" % (b["bottom_touch_frame"], b["bottom_touch_speed_cm_per_f"])
        if "loop_seam" in r:
            extra += "  seam %.5f" % r["loop_seam"]
        if "mirror_error_mm" in r:
            extra += "  mirror %.3fmm" % r["mirror_error_mm"]
        print("%-18s %4d %6.3f %4s %6.2f %6.2f %5.1f %5.1f %5.2f %6.1f %5.1f %5.1f | %s" % (
            n, r["frames"], r["seconds"], "Y" if r["loop"] else "-", r["slip_mm"]["L"], r["slip_mm"]["R"],
            r["penetration_mm"], r["overreach_mm"], r["knee_forward_min"], r["knee_flex_max_deg"],
            r["knee_flex_jump_deg_per_f"], r["body_clip_mm"], extra))


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    main(argv)

"""Wako action library -- reproducible, face-forward re-authoring pipeline.

Usage (Blender 4.5 as a Python module, or ``blender --background --python``)::

    python wako_actions.py -- in.blend out.blend [--only wk_idle,wk_assemble] [--report out.json]
                              [--pose-ref pose_ref.json] [--no-guards]

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
   (the bottom rests on the ground for the current pitch/roll).  Contacts are MESH-AWARE: the skinned mesh of
   the input file is read once (linear blend skinning in numpy, identical to Blender's armature modifier) and
   (a) the seat contact uses the rounded cube's real bottom, (b) a planted / pivoting sole whose verts would go
   below the floor raises its ankle just enough, (c) a curled toe pad conforms to the floor (the curl opens
   just enough, by at most TOE_CONFORM_MAX_DEG = 35 deg; a pad still below the floor at that cap is a guard failure,
   never 'fixed' by swinging the toe round), so nothing ever sinks into the ground -- authored poses are untouched
   wherever they are clear.  A mesh whose toe pad is still modelled BEHIND the ankle (the original pre-flip mesh:
   toe-weighted verts ~13 cm behind the forward toe head) is detected; the mesh toe conform and the toe-pad floor
   check are then disabled with a warning (authored curls written unchanged) -- run the pipeline on the rebuilt
   mesh for game use.
   The solved pose is converted to local bone
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
   unsided clips, the work foot's authored contact pose, the sit family's seat-descent / travel curves, bone
   rests vs input, and the mesh probe (lowest sole / toe-pad / body vertex vs the floor, knee / shin / foot
   vertices inside the cube, seat gap).  Strict knee direction: the knee apex (knee offset from the hip-ankle
   line) is measured in the BODY frame and must never point behind the body's up axis; upright legs on a body
   facing +Y must also bend toward +Y in armature space.  Also per clip: the largest per-frame LOCAL rotation step
   of every bone (catches single-frame flips such as a toe swinging round) and the longest dead hold (frames in a
   row where no tracked point moves 1 mm).  ``check_guards`` turns these into library-wide gates (knee apex, splay
   <= 30 deg, leg-into-body, nothing below the floor, toe conform resolved and <= 35 deg, slip, mirror, loop seams,
   bone rotation <= 45 deg/f except the whitelisted deliberate snaps): the pipeline aborts on any failure unless
   ``--no-guards``.  ``--pose-ref`` writes every frame's bone heads
   (Godot skeleton space) for the Godot-side per-frame comparison (harness/scripts/clip_inventory.gd --ref=...).

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
* wk_step ends with the root advanced 0.12 m.  The sit family is IN PLACE: root y 0 at both standing ends and
  while seated; only transients (wk_sit_down leans up to 13 cm forward over its feet in the squat and the sit-back
  brings it home; wk_sit_up rocks 4.5 cm forward) -- ``seat_travel_m`` in the report is that per-frame root y --
  so the native body never has to move horizontally and the hand-off sit_up -> wk_idle has no slide.
* Neutral stances: work clips start and end in the shared neutral (work foot o 0.19 / y 0, support foot o 0.175
  / y -0.01 -- the support sits 1.5 cm narrower and 1 cm back on each side, mirrored, so wk_*_L and wk_*_R do
  not share one identical neutral); wk_tool_change keeps its -24 deg toe curl (held tool); wk_interrupted ends
  with the work foot replanted 3 cm back under the hip (protective) and wk_step 0.12 m forward, by design.
* Work timing grammar: in the STROKE clips the action beat is the fastest work-foot motion of the clip (assemble
  strike 26 cm/f, repair tap 12, operate press 10, pickup flick 16); reaches and returns are slower (repair <= 8 cm/f
  against its tap, operate's lift-off under its press, pickup's lowering under its flick, assemble's 7 f ease-out
  under half its strike).  The LOAD clips (inspect, maintenance, unbend, tool_change, brace) act through contact,
  cranks and tremor instead; their fastest motion is the lift to / return from the work point (<= 12 cm/f, spread
  over >= 4 f, inspect's withdraw <= 9 cm/f).  The clips
  therefore already carry the assemble / inspect / repair re-timing -- set wako_pose.gd WORK_TIMING to identity for
  them or the strike is compressed twice.  Work knees bend toward the face: the manipulation path's default pole
  for pickup / tool_change / operate / maintenance / unbend / push / pull / step must become -model.z (face
  forward), not root +Z, or the knee sweeps through the side during the work-entry blend.
* Quaternion signs: the Blender curves are sign-continuous, but the glTF exporter canonicalises near-w=0
  rotation keys, so imported rotation tracks contain sign flips (also present in the baseline import).
  Godot's slerp / blending take the shortest path, so nothing is visible; code that reads keys and lerps
  quaternion components directly must align signs first.
* Seat descent ownership: wk_sit_down / wk_sit_idle / wk_sit_up carry the FULL seat descent in root Z so they
  are complete on their own (bottom on the ground, ~-0.80 m).  The report's ``seat_descent_m`` is that curve
  per frame; it is built for a native spring to follow (one continuous descent, <= 1 g downward while the
  legs carry the body; rise with a <= 1 g deceleration).  Recommended: drive the native ``seat_drop`` from
  this curve and subtract the body's ACTUAL drop from the visual root (root keeps pitch/yaw/x/y), so the
  visual and physical bottoms agree; do not add a second descent on top.
* wk_sit_down follows A18: two steps forward-and-wide, a supported knees-forward squat leaning over the feet
  (bottom ~0.25 m, COM over the heels), then a SIT-BACK -- the body rocks back onto its bottom while the heels skid
  forward under the braking legs (authored slide, reported) and it plops (~5 cm/f) with a 1 cm bounce; each foot
  is then placed into the V.  wk_sit_up cannot be the reverse (no arms, and with the bottom on the floor a bent
  knee only fits in front of the face or beside the cube): the feet slide back LOW (<= 3 cm) to a compact frog
  just ahead of the face's lower corners (+-0.56 m, knees forward), the body rocks forward over them, pushes up and
  closes the stance with a small hop.  Knee apex >= 0 in the body frame on every frame, no leg vertex inside the
  cube.  The seated hero pose is pitched back 16 deg (face up) on nearly straight V legs (knees ~0.21 m, thighs
  ~5 deg up) so the thighs leave the cube at its rounded bottom edge.  sit_up ends in the work neutral; blend
  4-6 f into wk_idle (its f0 is weight-shifted, 4.7 cm away).
* wk_swim legs are authored in the BODY frame (they follow the 20 deg back-pitched body); the root stays at
  rest height (buoyancy owns the native body) apart from a 2.5 cm surge per stroke.
* wk_dance_a contains one 360 deg root-yaw spin (two ballistic hops landing on 7-and and beat 8; the feet do not
  rotate while planted, the body turns <= 20 deg against them at the mid-spin touch) and ends at the start
  orientation.  Every hop in the library is an exact parabola at 1.15 g with velocity-continuous take-off and
  landing; groove dips start <= 1 g and land ON the beat.
* wk_danger: leans INTO the threat (pitch +5) up on the balls (heels 12 deg up) with two 2 cm ready bounces and a
  +/-1 deg tremor; the authored looks are small (+/-7 deg) -- the runtime gaze owns the big looks; give every Wako
  a random phase offset into this 1 s loop so groups do not bob in sync.
* Work-foot retargeting (prominent): during normalised .43-.78 the current runtime retargets the authored work
  foot to the contact hold (WORK_TIMING), which flattens the authored detail there (repair feints, maintenance
  cranks, inspect rubs, unbend give).  Adopt the per-clip ``contact_pose`` + ``weight`` lift / plant phases
  from the report (retarget relative to the authored contact pose) or that detail stays invisible in game.
"""

import argparse
import json
import math
import os
import sys

import bpy
import numpy as np
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
TOE_CONFORM_MAX_DEG = 35.0              # the mesh toe-pad conform may open an authored curl by at most this much
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
    if isinstance(spec, (int, float)):        # (Slope is a float: same code both sides)
        return spec, spec
    if len(spec) == 1:
        return spec, spec
    return spec[0], spec[1]


class Slope(float):
    """Absolute tangent (value per frame) for a key side, e.g. a take-off velocity."""


def _tan_value(code, delta_side, auto):
    if isinstance(code, Slope):
        return float(code)
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
        self.mesh = None

    # --------------------------------------------------------------------------------
    def solve(self, P, t=None, spin=None):
        """P: {'root': {...}, 'L': {...}, 'R': {...}} -> (pose matrices, diagnostics)."""
        rv = P["root"]
        R = _rot_root(rv["p"] + rv["p2"], rv["r"] + rv["r2"], rv["w"] + rv["w2"])
        pos = Vector((rv["x"], rv["y"], rv["z"] + rv["z2"]))
        root_pose = Matrix.Translation(self.head0 + pos) @ R.to_4x4() @ self.rest_rot4[ROOT]
        D = root_pose @ self.rest_inv[ROOT]
        poses = {ROOT: root_pose}
        diag = {"root": root_pose, "legs": {}, "R": R}
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
            # up for a leg raised forward, down-forward for a leg reaching behind) + outward splay (k) + a
            # body-forward bias (kf) that keeps the apex toward the face when the hip-ankle line runs sideways
            dl = R.transposed() @ (A - H)
            ds = Vector((0.0, dl.y, dl.z))
            sag = ds.length / max(dl.length, 1e-9)          # 1 = leg in the sagittal plane, 0 = sideways
            if ds.length < 1e-6:
                ds = Vector((0.0, 0.0, -1.0))
            ds.normalize()
            # sideways legs (wide frog gather) have no sagittal direction: their apex defaults to up
            anat = Vector((0.0, -ds.z, ds.y)) * sag + Vector((0.0, 0.0, 1.0)) * (1.0 - sag)
            pole_l = (anat + math.tan(math.radians(fv["k"])) * Vector((sx, 0.0, 0.0))).normalized()
            if fv["pw"] > 0.0:
                # explicit body-frame knee direction (frog crouch: forward-up-out), blended in by pw
                pa, pe = math.radians(fv["pa"]), math.radians(fv["pe"])
                pex = Vector((sx * math.sin(pa) * math.cos(pe), math.cos(pa) * math.cos(pe), math.sin(pe)))
                pole_l = pole_l.lerp(pex, min(1.0, fv["pw"]))
            pole = R @ pole_l
            leg = self._leg_pose(s, poses, H, A, Rf, pole, fv["t"])
            raise_, toe_fix, toe_ok = 0.0, 0.0, True
            if self.mesh is not None and fv["gc"] > 0.5:
                # ground contact: the sole/heel verts never go below the floor (raise the ankle target), the
                # toe pad conforms to the floor (the curl opens just enough) -- authored poses stay untouched
                # whenever they are clear of the ground
                for _ in range(4):
                    mats = self.mesh.leg_mats(s, poses)
                    zf = float(self.mesh.skin(self.mesh.parts[s]["foot"], mats)[:, 2].min())
                    deficit = self.ground_z - zf
                    if deficit <= 2e-5:
                        break
                    A = A + Vector((0.0, 0.0, deficit))
                    raise_ += deficit
                    leg = self._leg_pose(s, poses, H, A, Rf, pole, fv["t"])
                toe_ok = True
                if not self.mesh.toe_backward[s]:
                    tt, toe_ok = self._toe_conform(s, poses, fv["t"])
                    if tt != fv["t"]:
                        toe_fix = tt - fv["t"]
                        poses[toe] = poses[an] @ L["toe_rel"] @ Matrix.Rotation(math.radians(tt), 4, "X")
            K_, A2, over, dirv, pp, lat = leg
            # diagnostics
            heel = A2 + Rf @ Vector((0.0, HEEL_Y, -SOLE_DROP))
            ball = A2 + Rf @ Vector((0.0, BALL_Y, -SOLE_DROP))
            line = (A2 - H).normalized()
            koff = (K_ - H) - line * (K_ - H).dot(line)
            flex = math.degrees(math.pi - math.acos(max(-1.0, min(1.0, (K_ - H).normalized().dot((K_ - A2).normalized())))))
            diag["legs"][s] = dict(H=H, K=K_, A=A2, over=over, heel=heel, ball=ball, koff=koff,
                                   koff_body=R.transposed() @ koff,
                                   fwd=R @ Vector((0.0, 1.0, 0.0)), pole=pole.normalized(), lat=lat, flex=flex,
                                   pitch=fv["p"], raise_=raise_, toe_fix=toe_fix, toe_ok=toe_ok,
                                   toe_tip=(poses[toe] @ Matrix.Translation((0.0, 0.13, 0.0))).translation)
        return poses, diag

    def _leg_pose(self, s, poses, H, A, Rf, pole, t_deg):
        th, sh, an, toe = LEGS[s]
        L = self.leg[s]
        K_, A2, over, dirv, pp = _two_bone(H, A, pole, L["a"], L["b"])
        lat = dirv.cross(pp).normalized()
        yt = (K_ - H).normalized()
        ys = (A2 - K_).normalized()
        Mt = _cols(lat, yt, lat.cross(yt)) @ L["frame0_t"]
        Ms = _cols(lat, ys, lat.cross(ys)) @ L["frame0_t"]
        poses[th] = Matrix.Translation(H) @ Mt.to_4x4() @ self.rest_rot4[th]
        poses[sh] = Matrix.Translation(K_) @ Ms.to_4x4() @ self.rest_rot4[sh]
        poses[an] = Matrix.Translation(A2) @ Rf.to_4x4() @ self.rest_rot4[an]
        poses[toe] = poses[an] @ L["toe_rel"] @ Matrix.Rotation(math.radians(t_deg), 4, "X")
        return K_, A2, over, dirv, pp, lat

    def _toe_conform(self, s, poses, t_deg):
        """Smallest toe angle in [t_deg, t_deg + TOE_CONFORM_MAX_DEG] (deg, + = toe up) whose toe pad stays on or
        above the floor -> (angle, resolved).  Bounded: a pad still below the floor at the cap is reported
        (resolved False -> guard failure), never 'fixed' by swinging the toe round (a backward-modelled toe
        pad would otherwise demand ~150 deg)."""
        th, sh, an, toe = LEGS[s]
        mesh = self.mesh
        mats = mesh.leg_mats(s, poses)
        jt = mesh.names.index(toe)
        idx = mesh.parts[s]["toe"]
        base = np.array(poses[an] @ self.leg[s]["toe_rel"])

        def low(tt):
            mats[jt] = base @ np.array(Matrix.Rotation(math.radians(tt), 4, "X")) @ mesh.rest_inv[jt]
            return float(mesh.skin(idx, mats)[:, 2].min())
        if low(t_deg) >= self.ground_z - 2e-5:
            return t_deg, True
        lo, hi = t_deg, t_deg + TOE_CONFORM_MAX_DEG
        if low(hi) < self.ground_z - 2e-5:
            return t_deg, False
        for _ in range(24):
            mid = 0.5 * (lo + hi)
            if low(mid) < self.ground_z:
                lo = mid
            else:
                hi = mid
        return hi, True

    def seat_z(self, rv, eps=0.0005):
        """Root z offset at which the lowest point of the body (the skinned cube's rounded bottom when a mesh is
        present, else the box corners) touches the ground (+eps)."""
        R = _rot_root(rv["p"] + rv["p2"], rv["r"] + rv["r2"], rv["w"] + rv["w2"])
        if self.mesh is not None:
            low = self.mesh.body_min_z(R)
        else:
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


class MeshModel:
    """The skinned mesh as a contact / clearance probe.

    Linear blend skinning of the deform mesh (identical to Blender's armature modifier without preserve-volume:
    verified against the evaluated depsgraph mesh to 2e-7 m) restricted to vertex subsets:
      * body: pure root-weighted verts (the rounded cube) -> seated floor contact and body-vs-ground checks;
      * foot / toe (per leg): verts whose dominant weight is the ankle / toe bone -> sole and toe floor contact;
      * leg (per leg): shin-dominant verts plus thigh verts >= 0.15 m from the hip -> leg-into-body clearance.
    The geometry is read from the input blend, so contacts adapt to the mesh the pipeline runs on."""

    def __init__(self, arm, rig):
        meshes = [o for o in bpy.data.objects if o.type == "MESH" and any(
            m.type == "ARMATURE" and m.object == arm for m in o.modifiers)]
        if not meshes:
            raise RuntimeError("no mesh skinned to %s" % arm.name)
        for o in meshes:
            for m in o.modifiers:
                if m.type == "ARMATURE" and (m.use_deform_preserve_volume or not m.use_vertex_groups):
                    raise RuntimeError("%s: armature modifier must be plain LBS with vertex groups" % o.name)
        self.names = list(rig.order)
        nb = len(self.names)
        A2W_inv = arm.matrix_world.inverted()
        cos, Ws = [], []
        for o in meshes:
            M = A2W_inv @ o.matrix_world
            n = len(o.data.vertices)
            co = np.zeros(n * 3)
            o.data.vertices.foreach_get("co", co)
            co = co.reshape(-1, 3)
            Mn = np.array(M)
            cos.append(co @ Mn[:3, :3].T + Mn[:3, 3])
            W = np.zeros((n, nb))
            gi = {g.index: g.name for g in o.vertex_groups}
            for v in o.data.vertices:
                for g in v.groups:
                    nm = gi.get(g.group)
                    if nm in self.names:
                        W[v.index, self.names.index(nm)] = g.weight
            Ws.append(W)
        co = np.concatenate(cos)
        W = np.concatenate(Ws)
        s = W.sum(1)
        keep = s > 1e-6
        co, W = co[keep], W[keep] / s[keep][:, None]
        self.h = np.c_[co, np.ones(len(co))]                     # homogeneous rest verts (armature space)
        self.W = W
        self.rest_inv = [np.array(rig.rest_inv[n]) for n in self.names]
        dom = W.argmax(1)
        bi = {n: i for i, n in enumerate(self.names)}
        self.body = np.where(W[:, bi[ROOT]] >= 0.99)[0]
        self.head0 = np.array(rig.head0)
        rel = co[self.body] - self.head0
        self.body_rel = rel
        # rounded-box model of the cube (root-local, metres) for the leg clearance SDF
        hx, hy = np.abs(rel[:, 0]).max(), np.abs(rel[:, 1]).max()
        zlo, zhi = rel[:, 2].min(), rel[:, 2].max()
        flat = rel[rel[:, 2] < zlo + 0.003]
        bev = max(0.02, min(hx - np.abs(flat[:, 0]).max(), hy - np.abs(flat[:, 1]).max()))
        self.box = dict(c=np.array([0.0, 0.0, 0.5 * (zlo + zhi)]), b=np.array([hx, hy, 0.5 * (zhi - zlo)]), r=bev)
        self.parts = {}
        for s_ in "LR":
            th, sh, an, toe = LEGS[s_]
            hip = np.array(rig.leg[s_]["hip"])
            dist = np.linalg.norm(co - hip, axis=1)
            self.parts[s_] = {
                "foot": np.where(dom == bi[an])[0], "toe": np.where(dom == bi[toe])[0],
                # knee, shin and foot: must never enter the cube
                "leg": np.where((dom == bi[sh]) | (dom == bi[an]) | (dom == bi[toe]) | ((dom == bi[th]) & (dist >= 0.30)))[0],
                # proximal thigh 0.15-0.30 m from the hip: brushes the cube's bottom edge at deep hip flexion
                # (the hip pivot sits 11 cm inside the cube) -- reported, owned by the mesh junction
                "thigh": np.where((dom == bi[th]) & (dist >= 0.15) & (dist < 0.30))[0],
                "chain": [bi[ROOT], bi[th], bi[sh], bi[an], bi[toe]]}
        # toe pad orientation: the toe-dominant verts must lie AHEAD of the toe head in the toe bone's frame.  A mesh
        # whose toe pad is still modelled behind the ankle (the original pre-flip mesh) would swing 12-25 cm around
        # the forward toe pivot under any curl: the mesh toe conform and the toe-pad floor check are disabled for it
        # (authored toe curls are kept as written) and the report says so.
        self.toe_backward = {}
        self.toe_pad_y = {}
        for s_ in "LR":
            jt = bi[LEGS[s_][3]]
            idx = self.parts[s_]["toe"]
            ly = (self.h[idx] @ self.rest_inv[jt].T)[:, 1] if len(idx) else np.zeros(1)
            self.toe_pad_y[s_] = float(np.median(ly))
            self.toe_backward[s_] = bool(len(idx) == 0 or np.median(ly) < -0.02)
        self.rest_sole = min(co[self.parts[s_][k]][:, 2].min() for s_ in "LR" for k in ("foot", "toe"))
        self.rest_body_bottom = rel[:, 2].min()

    def skin(self, idx, mats, cols=None):
        """Deformed armature-space positions of verts idx; mats = {bone index: 4x4 numpy pose @ rest_inv}."""
        h = self.h[idx]
        W = self.W[idx]
        out = np.zeros((len(idx), 3))
        for j, M in mats.items():
            w = W[:, j]
            if cols is None and not w.any():
                continue
            out += w[:, None] * (h @ M[:3, :].T)
        return out

    def leg_mats(self, s, poses):
        out = {}
        for j in self.parts[s]["chain"]:
            out[j] = np.array(poses[self.names[j]]) @ self.rest_inv[j]
        return out

    def all_mats(self, poses):
        return {j: np.array(poses[n]) @ self.rest_inv[j] for j, n in enumerate(self.names)}

    def body_min_z(self, R):
        Rn = np.array(R)
        return float((self.body_rel @ Rn.T)[:, 2].min())

    def leg_into_body(self, poses, s, part="leg"):
        """Deepest leg vertex inside the rounded body cube (m, > 0 = inside)."""
        D = np.array(poses[ROOT]) @ self.rest_inv[0]
        Dinv = np.linalg.inv(D)
        p = self.skin(self.parts[s][part], self.leg_mats(s, poses))
        q = np.c_[p, np.ones(len(p))] @ Dinv.T                  # back into the rest (root-local) frame
        rel = q[:, :3] - self.head0
        bx = self.box
        d = np.abs(rel - bx["c"]) - (bx["b"] - bx["r"])
        out = np.linalg.norm(np.maximum(d, 0.0), axis=1) + np.minimum(d.max(1), 0.0) - bx["r"]
        return float(-out.min())


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
FOOT_DEF = dict(o=STANCE_O, y=0.0, h=0.0, p=0.0, w=5.0, r=0.0, t=0.0, k=6.0, pw=0.0, pa=30.0, pe=35.0, bw=0.0,
                g=0.0, gc=1.0)


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
        sgn = 1.0
        if ev.sigma is not None and chan in ("r2", "w2"):     # sided clips: mirror roll / yaw layers like keys
            sgn = -ev.sigma if chan == "r2" else ev.sigma
        P["root"][chan] += sgn * amp * env * math.sin(2 * math.pi * (t / period_f) + phase)
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
RUN = dict(frames=16, duty=0.34, yc=0.30, yt=0.315, lift=0.27, lift_exp=0.74, o=0.17, z0=-0.088,
           bob=0.012, bob_low=0.17, pitch=6.0, pitch_amp=1.0, roll=2.4, yaw=3.5, sway=0.010, heel=6.0,
           push=26.0, push_from=0.45, flat_at=0.2, toe_push=18.0, toe_swing=-8.0, swing_up=10.0, reach=0.02,
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
         K(4.5, w=1.1),                                   # micro glance: no span over 6 f without change
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
         K(84, p=4.0, w=-0.4),                # ... a little bob of interest
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
def _ready_bounce(t0, t1, z0, g=1.0 * 9.81):
    """A grounded ready bounce: the legs snap straight, the body rises and falls back on a 1 g parabola (no faster
    than gravity), so nothing is yanked down; apex (t1 - t0)^2 g / 8."""
    T = (t1 - t0) / FPS
    v0 = 0.5 * g * T
    za = z0 + g * T * T / 8.0
    return [K(t0, z=(z0, Slope(v0 / FPS))), K(0.5 * (t0 + t1), z=(za, "f")), K(t1, z=(z0, Slope(-v0 / FPS)))]


clip("wk_danger", 1.0, loop=True, notes="wary crouch leaning INTO the threat (pitch +5, COM over the balls), up on "
     "the balls of the feet (heels 12 deg up), staggered stance; two ready bounces (f8, f21: 2.5 cm up), two DIFFERENT "
     "small looks per loop (+/-7 deg: the runtime gaze owns the big looks; play with a random phase offset per Wako) "
     "(a 2 f snap right with overshoot and a short settle, then a slower 4-5 f smaller look left with a longer "
     "settle), a one-foot shuffle (weight onto R, the L heel lifts higher and re-grips), +/-1 deg fear tremor",
     root=[
         K(0, x=0.0, y=0.05, z=-0.092, p=5.0, r=0.0, w=0.0),     # leans into the threat, COM over the balls
         K(2, w=6.5, r=1.4, z=-0.096, tan="l"),           # snap right (2 f) -- small: runtime gaze owns the look
         K(3, w=7.4),                                     # overshoot
         K(5, w=6.2, z=-0.095),
         K(6.0, z=(-0.0985, "f"), p=5.6),                 # dips, then a ready bounce (ballistic, feet stay down)
         K(8.6, w=6.0, p=4.0),
         K(11.4, z=-0.095, w=5.4, p=5.2),
         K(12.5, w=4.8, r=0.8, p=5.8),
         K(17, w=-3.6, r=-0.8, z=-0.096, x=0.0),          # slower, smaller look left (4.5 f)
         K(18.5, w=-4.2, x=0.020, r=1.6),                 # weight onto R ...
         K(19.0, z=(-0.0985, "f"), p=5.6),
         K(21.6, p=4.2),                                  # ready bounce
         K(23.5, w=-3.4, x=0.022, r=1.8),                 # ... while the L heel re-grips
         K(24.6, z=-0.095),
         K(25.5, x=0.004, r=0.4, p=5.4),
         K(28, w=-1.0, r=0.0),
         K(30, x=0.0, y=0.05, z=-0.092, p=5.0, r=0.0, w=0.0),
     ] + _ready_bounce(6.6, 10.6, -0.0985) + _ready_bounce(19.6, 23.6, -0.0985),
     layers=[tremor("p2", 1.0, 4.0, -10, 40, ramp=0.1), tremor("r2", 0.6, 5.0, -10, 40, ramp=0.1, phase=1.0)],
     feet={
         "L": [K(0, o=0.25, y=0.07, w=12.0, g=1.0, t=-15.0, k=10.0, p=-12.0), K(6, p=-12.0), K(8, p=-16.0),
               K(10.5, p=-12.0, t=-15.0), K(18.5, p=-12.0, t=-15.0), K(21, p=-26.0, t=-28.0),
               K(23, p=-22.0, t=-22.0), K(25.5, p=-12.0, t=-15.0)],
         "R": [K(0, o=0.25, y=-0.07, w=10.0, g=1.0, t=-15.0, k=10.0, p=-12.0), K(6, p=-12.0), K(8, p=-15.0),
               K(10.5, p=-12.0), K(18, p=-12.0), K(21, p=-14.5), K(24, p=-12.0)],
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
    # the last airborne key comes down from (nearly) straight above: no horizontal skid into the heel strike
    approach = dict(approach, y=min(approach.get("y", 0.0), 0.008), h=max(approach.get("h", 0.0), 0.02))
    return [K(plant - 1.0, g=0.0, **approach),
            K(plant, o=0.19, h=0.0, y=0.0, p=5.0, t=t, g=1.0, tan="f"),
            K(plant + roll, p=0.0, g=1.0, tan="f"),
            K(end, tan="f", **NEUTRAL_W)]


def work_root0():
    return K(0, u=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0)


def work_root_end(n):
    return K(n, u=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0)


# A10 build / assembly with the mallet: draw f5-14, hang, 3 f strike, contact 0.56, rebound, long ease-out
C = C_of(1.0)
clip("wk_assemble", 1.0, sided=True, contact=C, notes="mallet stroke: support accepts f0-3.5 (overshoot), "
     "heel peels f4-5.5, slow heavy draw f5.5-12 UP AND BACK (foot behind the hip line, toe up = mallet up/back, body "
     "counter-pitches -8 and rises 1 cm: the draw C-curve), 2 f hang, 2.8 f accelerating strike (largest step into "
     "contact, the fastest beat of the clip), contact at 0.56, 3 cm rebound + hold, exponential ease-out f20-26.5 "
     "(peak under half the strike speed), heel plants f26.5, then the weight returns",
     layers=[weight_shift(3.5, 5.5, 26.5, 30.0, u=-0.09, r=4.5, z=-0.018)],
     root=[
         work_root0(),
         K(1.5, p=2.6, w=2.0),
         K(3.5, p=3.0, w=5.0),
         K(7, z=Z0 + 0.004, p=-1.5),
         K(12, z=Z0 + 0.010, p=-7.5, w=7.0, y=-0.016),
         K(14, z=Z0 + 0.011, p=-8.2, y=-0.019, tan="f"),
         K(C, z=Z0 - 0.018, p=11.0, y=0.022, w=6.0, tan=(2.0, "f")),
         K(C + 1.2, z=Z0 - 0.011, p=8.8, y=0.019),                  # 1 f shudder
         K(C + 3.0, z=Z0 - 0.013, p=9.6, y=0.020, tan=("f", 1.5)),
         K(22.5, z=Z0 - 0.007, p=5.6, y=0.010, w=3.5),
         K(26.5, z=Z0 - 0.004, p=2.8, y=0.002, w=1.2),
         K(28.5, z=Z0 + 0.002, p=1.4),
         work_root_end(30),
     ],
     feet={
         "S": SUPPORT,
         "W": w_peel(5.5, t=-6.0) + [
             K(7, h=0.07, y=0.04, p=12.0, t=-12.0, g=0.0),
             K(9, o=0.185, h=0.21, y=0.025, p=42.0, t=-22.0),
             K(12, o=0.18, h=0.33, y=-0.015, p=66.0, t=-28.0, tan="f"),     # up and BACK, toe up
             K(14, h=0.345, y=-0.025, p=70.0, t=-30.0, tan="f"),            # hang at the top
             # strike: y accelerates (2x), h later (3x) -> the ankle arcs forward then down
             K(C, o=0.175, h=(0.12, (3.0, "f")), y=(0.42, (2.0, "f")), p=(-38.0, ("l", "f")), t=-12.0),
             K(C + 1.2, h=0.15, y=0.41, p=-33.0, t=-14.0),
             K(C + 3.0, h=0.14, y=0.415, p=-35.0, t=-15.0, tan=("f", 1.6)),
             # exponential ease-out: ~55 % of the way back in the first 2 f, then a long settle
             K(21.8, o=0.185, h=0.12, y=0.25, p=-14.0, t=-9.0),
             K(24.2, h=0.06, y=0.09, p=2.0, t=-5.0),
         ] + w_plant(26.5, 30, dict(h=0.025, y=0.02, p=7.0, t=-3.0)),
     })

# A9 inspect: look, lean (support first), lift, slow-in toe approach, touch 0.56, probe rubs, verdict, release
C = C_of(1.3)
clip("wk_inspect", 1.3, sided=True, contact=C, notes="curious probe: eyes/body orient, weight onto the support "
     "(f0-5), heel peel, lift with the toe leading, strong slow-in approach, light toe touch at 0.56, two rubs, "
     "nod + puzzled head tilt while the foot withdraws -- gently: ease-in, f28-35, under ~9 cm/f -- "
     "heel plants f35, weight returns over 4 f",
     layers=[weight_shift(5.0, 8.5, 35.0, 39.0, u=-0.08, r=4.0, z=-0.02)],
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
         K(36.5, p=3.5, r=0.5, z=Z0 - 0.004, y=0.0),
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
             K(C + 6.0, y=0.36, t=3.0, w=5.0, h=0.09, tan="f"),
             # withdraw: eases in (the toe lingers), then a calm return
             K(29.5, h=0.10, y=0.33, p=-26.0, t=5.0),
             K(31.0, h=0.10, y=0.24, p=-16.0, t=6.0),
             K(32.3, h=0.085, y=0.135, p=-6.0, t=5.0),
             K(33.3, h=0.055, y=0.05, p=2.0, t=4.0),
         ] + w_plant(35.0, 39, dict(h=0.03, y=0.03, p=8.0, t=3.0)),
     })

# A12 precision repair: lean in, two feints, short draw, 2 f tap at 0.56, hold, inspect lift, nod
C = C_of(1.1)
clip("wk_repair", 1.1, sided=True, contact=C, notes="craftsman taps: weight accepted, the choked mallet (foot) "
     "travels unhurried to its aim (<= 8 cm/f) 1 cm above the joint (f11.3), feint 1 lifts 6 cm and stops dead 1 cm "
     "above (f11.3-13.3), feint 2 lifts 3 cm and stops (f13.3-14.7), a 12 cm draw with a slow-in hang at the top "
     "(f14.7-17.0), the 1.5 f tap accelerates into contact at 0.56 -- the clip's fastest beat -- a squeezed hold, a 3 cm "
     "check lift, satisfied nod, a calm return (<= 8 cm/f), heel plants f29.5, weight returns.  Body nearly still "
     "while aiming (<= 1 deg f10-18)",
     layers=[weight_shift(3.5, 5.5, 29.5, 33.0, u=-0.08, r=4.0, z=-0.018)],
     root=[
         work_root0(),
         K(3, p=5.0, w=4.0, z=Z0 - 0.004),
         K(7, z=Z0 - 0.012, p=8.0, w=5.0, y=0.01),                # lean in, focus
         K(10.5, p=8.3, z=Z0 - 0.013, w=5.1),
         K(14.7, p=8.4, z=Z0 - 0.013),
         K(16.7, p=7.7, z=Z0 - 0.011),                            # tiny counter-lean at the top of the draw
         K(C, p=8.7, z=Z0 - 0.015, w=5.2, tan=(2.0, "f")),        # tap: the body leads it by a hair
         K(C + 2.0, p=8.2, z=Z0 - 0.014),
         K(22, w=2.5),
         K(24, w=6.5, p=8.6),
         K(26, p=11.5, w=5.0),                                    # satisfied nod
         K(29.5, p=5.5, z=Z0 - 0.004, w=2.0),
         work_root_end(33),
     ],
     feet={
         "S": SUPPORT,
         "W": w_peel(5.5, t=-4.0) + [
             K(7.3, h=0.06, y=0.07, p=4.0, t=-8.0, g=0.0),
             K(9.3, h=0.125, y=0.195, p=-6.0, t=-12.0),
             K(11.3, o=0.175, h=0.155, y=0.30, p=-20.0, t=-18.0, tan="f"),       # aim: 1 cm above the joint
             K(12.3, h=0.215, y=0.293, p=-8.0, t=-16.0),                         # feint 1: 6 cm ...
             K(13.3, h=0.155, y=0.303, p=-21.0, t=-18.0, tan="f"),               # ... stops dead 1 cm short
             K(14.0, h=0.185, y=0.298, p=-13.0),                                 # feint 2: 3 cm
             K(14.7, h=0.155, y=0.304, p=-21.0, tan="f"),
             K(16.6, h=0.275, y=0.287, p=5.0, t=-14.0),                          # draw 12 cm (slow-in) ...
             K(17.0, h=0.278, y=0.286, p=6.0, tan="f"),                          # ... hang
             K(18.0, h=0.163, y=0.307, p=-21.0, tan=(2.0, "l")),                # TAP: the big step lands on f18 ...
             K(C, h=0.145, y=0.31, p=-25.0, t=-18.0, tan=("l", "f")),           # ... and it hits at 0.56
             K(19.6, h=0.148, y=0.31, p=-23.5),                                  # squeeze / micro rebound
             K(20.6, h=0.146, y=0.31, p=-24.0, tan="f"),
             K(21.8, h=0.176, y=0.305, p=-18.0, t=-20.0),                        # check lift 3 cm
             K(22.8, h=0.172, y=0.285, p=-15.0),
             K(24.8, h=0.14, y=0.205, p=-9.0, t=-12.0),                          # calm return
             K(26.7, h=0.09, y=0.115, p=-1.0, t=-6.0),
         ] + w_plant(29.5, 33, dict(h=0.03, y=0.03, p=7.0, t=-2.0)),
     })


def _crank(o_t, y_t, w, L=0.17):
    """Foot pose that keeps the toe tip on a fitting at plan position (o_t, y_t) while the foot yaws w deg
    (+ = toe out): the heel / ankle swings around the gripping toe like a wrench handle."""
    a = math.radians(w)
    return dict(o=o_t - L * math.sin(a), y=y_t - L * math.cos(a), w=w)


# Maintenance: ratchet phrase -- three wrench cranks the camera can read: the heel swings round the gripping toe, the
# knee travels out and back 7-12 cm, the body counter-yaws / counter-rolls each crank, click + body jolt at 0.56
C = C_of(1.1)
_FIT = (0.25, 0.47)            # fitting (toe tip) plan position: high and a little outward -- its own silhouette
clip("wk_maintenance", 1.1, sided=True, contact=C, notes="service ratchet on a fitting high and to the work side "
     "(body turned 9 deg toward it): weight onto the support, the toe clamps the fitting (f9.4), then three wrench "
     "cranks -- the heel swings out round the gripping toe (foot yaw 28/36/44 deg) and the knee travels out 7-12 cm "
     "and back, the body counter-yaws 9-10 deg and counter-rolls 5-6 deg each time, a quick open-toe reset between "
     "-- a small one, a bigger one, and the hardest one clicking at 0.56 (body jolts 3 cm down, 1 f shudder), a "
     "check wiggle, listen tilt, calm return, heel plants f28.5, weight returns",
     layers=[weight_shift(3.5, 5.5, 28.5, 33.0, u=-0.08, r=4.0, z=-0.018)],
     root=[
         work_root0(),
         K(3, p=4.0, w=4.0),
         K(9.4, p=5.0, z=Z0 - 0.004, w=9.0, r=1.0),               # turns to the fitting
         K(11.0, w=0.0, r=6.0, z=Z0 - 0.010, tan=(2.0, "f")),     # crank 1: counter-yaw 9 / counter-roll 5
         K(12.2, w=9.0, r=1.0, z=Z0 - 0.004),                     # reset
         K(14.6, w=-0.5, r=6.5, z=Z0 - 0.012, tan=(2.0, "f")),    # crank 2 (bigger)
         K(15.8, w=9.5, r=1.0, z=Z0 - 0.004),
         K(C, w=-1.0, r=7.0, z=Z0 - 0.040, p=7.0, tan=(2.0, "f")),# crank 3: CLICK -- the body jolts ~3 cm
         K(C + 1.0, z=Z0 - 0.024, w=0.8, r=5.8),                  # 1 f shudder
         K(C + 2.5, z=Z0 - 0.029, w=-0.5, r=6.6),
         K(23.0, r=1.5, w=6.0, p=4.0, z=Z0 - 0.010),              # listen tilt
         K(25.5, r=1.0, p=3.5, w=3.0),
         K(28.5, r=0.5, p=3.0, w=1.5, z=Z0 - 0.004),
         work_root_end(33),
     ],
     feet={
         "S": SUPPORT,
         "W": w_peel(5.5, t=4.0, w=5.0) + [
             K(7.1, h=0.09, y=0.12, p=8.0, t=10.0, o=0.20, g=0.0),
             K(8.3, h=0.18, y=0.22, p=-4.0, t=-10.0, o=0.24),
             K(9.4, h=0.235, p=-12.0, t=-26.0, k=6.0, tan="f", **_crank(*_FIT, 6.0)),   # toe clamps the fitting
             K(11.0, h=0.228, k=26.0, t=-30.0, tan=(2.0, "f"), **_crank(*_FIT, -22.0)), # crank 1: heel swings out
             K(12.1, h=0.24, k=0.0, t=-12.0, **_crank(*_FIT, 4.0)),                    # reset: toe opens
             K(12.8, k=1.0, t=-28.0, tan="f", **_crank(*_FIT, 6.0)),                   # re-grip
             K(14.6, h=0.226, k=30.0, t=-32.0, tan=(2.0, "f"), **_crank(*_FIT, -30.0)), # crank 2 (bigger)
             K(15.6, h=0.24, k=0.0, t=-12.0, **_crank(*_FIT, 4.0)),
             K(16.3, k=1.0, t=-30.0, tan="f", **_crank(*_FIT, 8.0)),                   # re-grip, wound back
             K(C, h=0.222, k=30.0, t=-34.0, tan=(2.5, "f"), **_crank(*_FIT, -36.0)),   # crank 3: CLICK
             K(C + 1.0, h=0.228, k=27.0),
             K(C + 2.0, k=24.0, **_crank(*_FIT, -31.0)),                               # check wiggle
             K(C + 3.0, k=26.0, tan="f", **_crank(*_FIT, -34.0)),
             K(23.0, h=0.25, k=12.0, t=-12.0, **_crank(*_FIT, -8.0)),                  # lets go
             K(25.0, h=0.17, y=0.20, o=0.21, p=-4.0, w=5.0, t=-8.0, k=6.0),
             K(26.8, h=0.075, y=0.085, p=2.0, t=-4.0),
         ] + w_plant(28.5, 33, dict(h=0.03, y=0.03, p=7.0, t=-2.0, w=5.0)),
     })

# A13 unbend: the whole sole settles ON TOP of a bent joint at knee height and presses it down-forward: slow-in load
# with tremor while the work knee extends, the joint gives at 0.56 (foot drops / slides 5 cm, body lurches), relief
C = C_of(1.2)
clip("wk_unbend", 1.2, sided=True, contact=C, notes="straighten a bent joint by pressing DOWN and AWAY on it: "
     "weight accepted over 5 f, the foot climbs and sets its whole sole flat on the joint at knee height (sole ~30 cm "
     "up), then the push builds: the support leg extends and the body rises into one long diagonal from the support "
     "foot through the body into the pushing leg, the work knee straightens ~95 -> ~65 deg as the joint yields 6 cm "
     "down-forward, pitch 8 -> 19 deg with an 8 Hz tremor, the joint gives at 0.56 (the foot drops / slides 5 cm, "
     "the body lurches down and forward 3 cm), the support absorbs, exhale, the foot steps down, weight returns.  "
     "Silhouette: high work leg pressing down-forward (push is low and horizontal, brace is an upright sole at hip "
     "height)",
     layers=[weight_shift(5.0, 7.0, 30.5, 36.0, u=-0.08, r=4.0, z=-0.02),
             tremor("p2", 0.8, 3.75, 13, C, ramp=3.0), tremor("z2", 0.0018, 3.75, 13, C, ramp=3.0, phase=1.3),
             foot_tremor("W", "h", 0.003, 3.75, 13, C, ramp=3.0, phase=0.6)],
     root=[
         work_root0(),
         K(3, p=4.0, w=2.0),
         K(8, z=Z0 - 0.002, p=6.0, w=3.0),
         K(11.5, z=Z0 + 0.008, p=8.0, y=0.006, w=3.5),           # rises over the joint
         K(C - 0.8, z=Z0 + 0.004, p=19.0, y=0.010, tan="f"),      # loads it: the support leg straightens (diagonal)
         K(C + 1.4, z=Z0 - 0.030, p=23.0, y=0.042),               # give: lurch down / forward
         K(24, z=Z0 - 0.034, p=18.0, y=0.040),
         K(27, z=Z0 - 0.042, p=12.0, y=0.024),                    # exhale drop
         K(29.5, z=Z0 - 0.016, p=7.5, y=0.014),
         K(31, z=Z0 - 0.010, p=5.5, y=0.008),
         K(33.5, p=2.8, y=0.002),
         work_root_end(36),
     ],
     feet={
         "S": SUPPORT,
         "W": w_peel(7.0, t=2.0) + [
             K(9, h=0.15, y=0.11, p=14.0, t=6.0, g=0.0),
             K(11.5, o=0.18, h=0.32, y=0.25, p=6.0, t=4.0),        # climbs onto the joint
             K(13, h=0.305, y=0.275, p=-2.0, t=0.0, tan="f"),      # whole sole set on top
             K(C - 0.8, h=0.262, y=0.335, p=-10.0, t=-5.0, tan="f"),  # presses down-forward: the joint yields 6 cm
             K(C + 1.4, h=0.215, y=0.36, p=-13.0, t=-7.0),         # GIVE: the foot drops / slides 5 cm
             K(24, h=0.22, y=0.355, p=-11.0),
             K(25.6, h=0.215, y=0.32, p=-6.0),
             K(27.3, h=0.16, y=0.21, p=2.0, t=2.0),
             K(28.6, h=0.085, y=0.10, p=6.0, t=2.0),
         ] + w_plant(30.5, 36, dict(h=0.035, y=0.04, p=8.0, t=2.0)),
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
         K(10, p=10.0, z=Z0 - 0.012, w=3.0),                      # reaches low and far: its own silhouette
         K(C, p=13.5, z=Z0 - 0.024, tan="f"),
         K(C + 1.5, p=12.0, z=Z0 - 0.018),
         K(26, p=-4.5, z=Z0 + 0.004, w=1.5),                      # counter-lean under the lifted mallet
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
             K(12, o=0.18, h=0.17, y=0.30, p=-10.0, t=26.0),
             K(17, h=0.122, y=0.40, p=-18.0, t=27.0),
             K(C, h=0.115, y=0.41, p=-19.0, t=26.0, tan="f"),    # the handle lies low and far
             K(C + 2.0, t=-34.0, p=-16.0, h=0.12),                 # grip snaps closed
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
     "into a low strong stance; the hold lives: an 8.6 Hz +/-1 deg effort tremor (pitch, roll, foot), load pulses, a "
     "support-foot re-grip (toes clench, heel lifts 1.5 cm and resets, f16-21), and a re-press ACCENT at 0.56 (the foot "
     "drives 2.5 cm, the body shoves back 2.5 cm and 4 deg, the support knee gives 2 cm); release eases over 5 f, "
     "heel plants f37.5, weight returns",
     layers=[weight_shift(5.0, 7.5, 37.5, 42.0, u=-0.085, r=4.5, z=-0.026),
             tremor("p2", 1.0, 3.5, 13, 33, ramp=3.0), tremor("r2", 0.5, 4.5, 13, 33, ramp=3.0, phase=0.9),
             tremor("z2", 0.0025, 9.0, 14, 33, ramp=4.0, phase=0.7),
             foot_tremor("W", "y", 0.004, 3.5, 13, 33, ramp=3.0, phase=0.4)],
     root=[
         work_root0(),
         K(3, p=3.0, w=2.0),
         K(8, p=4.0, z=Z0 - 0.010, w=3.0),
         K(12, p=0.0, z=Z0 - 0.025, y=-0.012),                    # sits back into the brace
         K(16, p=-1.0, z=Z0 - 0.030, y=-0.016),
         K(18.0, p=-0.2, z=Z0 - 0.036, y=-0.012, r=1.5),          # re-grip: weight rocks onto the support's ball
         K(20.5, p=-0.6, z=Z0 - 0.028, y=-0.015, r=0.0),
         K(C - 1.2, p=0.2, z=Z0 - 0.027, y=-0.012, tan="f"),      # gathers ...
         K(C + 1.0, p=-4.2, z=Z0 - 0.049, y=-0.038, tan="f"),     # ... ACCENT: shoves back, the support knee gives
         K(27.5, p=-1.0, z=Z0 - 0.031, y=-0.020),
         K(31, p=-1.6, z=Z0 - 0.033, y=-0.020),
         K(34, p=0.0, z=Z0 - 0.022, y=-0.012),
         K(37.5, p=2.5, z=Z0 - 0.012, y=-0.004),
         K(39.8, p=2.6),
         work_root_end(42),
     ],
     feet={
         "S": [K(0, o=0.175, y=-0.01, w=6.0, k=7.0, p=0.0, g=1.0, t=0.0),
               K(16, p=0.0, t=0.0, g=1.0, tan="f"),
               K(18.0, p=-7.0, t=-16.0, g=1.0),                     # re-grip: toes clench, heel lifts 1.5 cm
               K(20.0, p=0.0, t=-6.0, g=1.0, tan="f"),
               K(22, t=0.0)],
         "W": w_peel(7.5, t=4.0) + [
             K(9.5, h=0.12, y=0.12, p=18.0, t=8.0, g=0.0),
             K(11.5, o=0.18, h=0.24, y=0.28, p=58.0, t=6.0),
             K(13, h=0.255, y=0.30, p=68.0, t=2.0, tan="f"),      # sole upright against the load
             K(C - 1.2, h=0.255, y=0.298, tan="f"),
             K(C + 1.0, h=0.258, y=0.325, p=71.0, tan="f"),       # drives 2.5 cm
             K(28, y=0.31),
             K(32.0, h=0.255, y=0.30, p=68.0, tan="f"),
             # release eases over 5.5 f
             K(33.8, h=0.215, y=0.235, p=46.0, t=6.0),
             K(35.3, h=0.12, y=0.11, p=20.0, t=4.0),
         ] + w_plant(37.5, 42, dict(h=0.03, y=0.02, p=7.0, t=0.0)),
     })

# Push: LOW and HORIZONTAL: the sole stands vertical just off the floor, the body drives forward over a support leg
# that straightens into one long diagonal behind it, shove at 0.56, follow-through, release
C = C_of(1.4)
clip("wk_push", 1.4, sided=True, contact=C, notes="push: weight accepted over 5 f, the work foot sets its sole "
     "upright against the object just off the floor (ankle ~18 cm up), the body drives forward and down over "
     "it (+0.10 m, pitch 24 deg) so the support leg straightens into one long diagonal behind the body, a "
     "trembling effort hold, shove at 0.56 (the foot extends 9 cm, the body lurches forward), follow-through, "
     "release, heel plants, weight returns.  Silhouette: support foot -> body -> push foot is one low line",
     layers=[weight_shift(5.0, 7.5, 37.0, 42.0, u=-0.07, r=3.5, z=-0.010),
             tremor("p2", 0.55, 3.75, 15, C, ramp=3.0), foot_tremor("W", "y", 0.003, 3.75, 15, C, ramp=3.0)],
     root=[
         work_root0(),
         K(3, p=4.0, w=1.0),
         K(8, p=7.0, z=Z0 - 0.004, w=2.0),
         K(11.5, z=Z0 - 0.016, p=15.0, y=0.045),
         K(15.5, z=Z0 - 0.030, p=21.0, y=0.072),                  # drives in: support leg becomes the diagonal
         K(C - 0.5, z=Z0 - 0.036, p=23.5, y=0.082, tan="f"),
         K(C + 1.5, z=Z0 - 0.044, p=26.0, y=0.108),               # shove: lurch forward
         K(28, z=Z0 - 0.036, p=20.0, y=0.090),
         K(32, z=Z0 - 0.014, p=11.0, y=0.050),
         K(35, p=6.0, y=0.022),
         K(37, p=4.0, y=0.010, z=Z0 - 0.006),
         K(39.5, p=2.4, y=0.002),
         work_root_end(42),
     ],
     feet={
         "S": [K(0, o=0.175, y=-0.01, w=6.0, k=7.0, p=0.0, g=1.0, t=0.0),
               K(13, p=0.0, g=1.0), K(C, p=-7.0, g=1.0, t=8.0), K(28, p=-5.0, g=1.0),   # heel rises: drive
                         K(33, p=0.0, g=1.0, t=0.0, tan="f")],
         "W": w_peel(7.5, t=4.0) + [
             K(9.5, h=0.08, y=0.12, p=20.0, t=8.0, g=0.0),
             K(11.5, o=0.18, h=0.075, y=0.30, p=62.0, t=12.0),     # sole upright, low
             K(13, h=0.068, y=0.33, p=70.0, tan="f"),
             K(C - 0.5, h=0.066, y=0.35, p=72.0, tan="f"),
             K(C + 1.5, h=0.064, y=0.43, p=70.0),                  # shove: extends 8 cm
             K(28, h=0.066, y=0.41, p=68.0),
             K(32, h=0.09, y=0.26, p=30.0, t=4.0),
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
clip("wk_operate", 1.2, sided=True, contact=C, notes="station duty on a LOW pedal close in front (its own "
     "silhouette: body upright, rolled 6 deg over the support, the body bounces with each press): weight accepted "
     "over 5 f, the foot hovers onto the pedal, gathers (foot and body rise), a decisive press that ACCELERATES down "
     "into the bottom at 0.56 (the clip's fastest beat) with a 2.5 cm body bounce, a shorter second pump, an easy "
     "lift-off (<= 7 cm/f), heel plants f31, weight returns",
     layers=[weight_shift(5.0, 7.0, 31.0, 36.0, u=-0.075, r=6.0, z=-0.02)],
     root=[
         work_root0(),
         K(3, p=3.0, w=2.0),
         K(11, z=Z0 - 0.004, p=4.0, w=2.5),
         K(18.0, z=Z0 + 0.010, p=1.5, r=1.5, tan="f"),            # gather: rises with the foot
         K(C, z=Z0 - 0.026, p=6.0, r=0.0, tan=(2.0, "f")),        # press bottoms out: body bounces down
         K(C + 1.6, z=Z0 - 0.015, p=4.5),
         K(22.6, z=Z0 + 0.002, p=3.0),
         K(24.0, z=Z0 - 0.018, p=5.0, tan=(2.0, "f")),            # second pump
         K(27, z=Z0 - 0.006, p=3.5),
         K(31, z=Z0 - 0.004, p=3.0),
         K(33.5, p=2.6),
         work_root_end(36),
     ],
     feet={
         "S": SUPPORT,
         "W": w_peel(7.0, t=6.0) + [
             K(9, h=0.11, y=0.10, p=12.0, t=10.0, g=0.0),
             K(11.5, o=0.175, h=0.165, y=0.22, p=-4.0, t=8.0),
             K(14, h=0.15, y=0.26, p=-8.0, t=0.0, tan="f"),        # hovers on the pedal (low, close)
             K(18.0, h=0.215, y=0.258, p=-3.0, tan="f"),           # gather 6.5 cm
             K(C, h=0.065, y=0.262, p=-14.0, t=-8.0, tan=(2.6, "f")),   # PRESS: accelerates into the bottom
             K(C + 1.4, h=0.075, y=0.262, p=-12.0),
             K(22.6, h=0.13, y=0.26, p=-8.0, t=0.0),
             K(24.0, h=0.07, y=0.262, p=-13.0, tan=(2.0, "f")),   # second pump
             K(26.0, h=0.11, y=0.21, p=-2.0, t=2.0),               # easy lift-off
             K(28.0, h=0.08, y=0.11, p=4.0, t=2.0),
         ] + w_plant(31.0, 36, dict(h=0.025, y=0.02, p=7.0, t=0.0)),
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
         K(C + 1.5, z=(Z0 - 0.068, "f"), p=14.0),
         # relief pop over 5 f: quick push, then a <= 1 g ease into the top (rises faster than it lowered)
         K(C + 3.0, z=(Z0 - 0.068 + 0.0255, Slope(0.034)), p=9.5),
         K(C + 6.3, z=(Z0 + 0.006, "f"), p=1.0, y=0.01),
         K(C + 8.3, z=Z0 - 0.004, p=2.5),
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
             K(C + 3.5, h=0.17, y=0.30, p=28.0),                  # the foot lets go as the body pops
             K(24.5, h=0.10, y=0.16, p=10.0, t=4.0),
         ] + w_plant(28.0, 33, dict(h=0.03, y=0.03, p=7.0, t=0.0)),
     })

# Small-part foot pickup: reach down, toe grips at 0.56, lift, wind-up, SNAP flick toward the head, catch dip
C = C_of(1.2)
clip("wk_pickup", 1.2, sided=True, contact=C, notes="small-part pickup: weight accepted over 5 f, lean in, "
     "open toe reaches down, grips at 0.56, lifts the part, a small cocking dip, then the flick SNAPS up toward the "
     "head (2 f, the clip's fastest beat, toe opens = release), a 1 f hang at the top so the toss reads (face up "
     "tracking the part), the foot eases down over 5.7 f while the body dips to catch it on the head, heel "
     "plants f32.5, weight returns",
     layers=[weight_shift(5.0, 7.0, 32.5, 36.0, u=-0.085, r=4.0, z=-0.018)],
     root=[
         work_root0(),
         K(3, p=4.0, w=3.0),
         K(10, p=10.0, z=Z0 - 0.020, w=5.0),
         K(C, p=12.0, z=Z0 - 0.032, tan="f"),
         K(C + 1.5, p=10.5, z=Z0 - 0.026),
         K(24.0, p=5.0, z=Z0 - 0.012),                            # cocks with the foot
         K(26.2, p=-8.0, z=Z0 + 0.010, tan="f"),                  # face up, watching the part fly
         K(27.3, p=-8.6, z=Z0 + 0.011, tan="f"),                  # hang
         K(29.3, p=-5.0, z=Z0 + 0.004),
         K(31.8, p=1.5, z=Z0 - 0.016),                            # catch dip
         K(34.0, p=3.0, z=Z0 - 0.006),
         work_root_end(36),
     ],
     feet={
         "S": SUPPORT,
         "W": w_peel(7.0, t=10.0) + [
             K(9, h=0.08, y=0.12, p=10.0, t=15.0, g=0.0),
             K(12, o=0.17, h=0.10, y=0.31, p=-14.0, t=28.0),
             K(16.5, h=0.062, y=0.355, p=-12.0, t=28.0),
             K(C, h=0.055, y=0.36, p=-12.0, t=26.0, tan="f"),
             K(C + 2.0, t=-42.0, h=0.06),                          # grips
             K(24.0, h=0.10, y=0.32, p=-4.0, t=-42.0, o=0.175, tan=("a", "l")),   # lifts and cocks
             K(25.0, h=0.25, y=0.275, p=20.0, t=-14.0, tan="l"),   # FLICK: snaps up over 2 f, toe opens
             K(26.0, h=0.40, y=0.23, p=44.0, t=10.0, tan=("l", "f")),
             K(26.8, h=0.405, y=0.227, p=48.0, t=10.0, tan="f"),  # hang at the top: the toss reads
             K(28.5, h=0.33, y=0.18, p=38.0, t=6.0),              # eases down over 5.7 f
             K(29.9, h=0.20, y=0.11, p=20.0, t=4.0),
             K(31.0, h=0.10, y=0.05, p=12.0, t=3.0),
         ] + w_plant(32.5, 36, dict(h=0.04, y=0.02, p=9.0, t=2.0)),
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
clip("wk_interrupted", 0.7, sided=True, notes="startle/interrupt: 2 f flinch (lean back 9 deg, dip) with a 1 f hang, work foot "
     "snaps up and replants under the hip, absorb, recover with a small forward overshoot, settle",
     root=[
         K(0, u=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0),
         K(2, y=-0.026, z=-0.046, p=-8.6, r=3.0, u=-0.02, tan="l"),   # 2 f flinch ...
         K(3, p=-9.4, z=-0.050, tan="f"),                              # ... 1 f hang
         K(4, p=-9.0, z=-0.052),
         K(7, y=-0.022, z=-0.056, p=-5.0, r=2.0),
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


def retime_release(name, t_a, new_plant):
    """Plant the work foot earlier and spread the weight release: time-warp the work-foot and root keys
    piecewise linearly ([t_a, old plant] -> [t_a, new plant], [old plant, end] -> [new plant, end]) and rebuild
    the support envelope with the new plant, so the weight comes back over 5.5-7 f with its overshoot instead of
    snapping back in ~3 f."""
    c = [x for x in LIBRARY if x.name == name][0]
    lay = [fn for fn in c.layers if hasattr(fn, "weight")][0]
    wd = lay.weight
    old, end = wd["plant"], wd["end"]

    def warp(f):
        if f <= t_a + 1e-6 or f >= end - 1e-6:
            return f
        if f <= old:
            return t_a + (f - t_a) * (new_plant - t_a) / (old - t_a)
        return new_plant + (f - old) * (end - new_plant) / (end - old)
    c.feet_rows["W"] = [(round(warp(f), 4), tan, ch) for f, tan, ch in c.feet_rows["W"]]
    c.root_rows = [(round(warp(f), 4), tan, ch) for f, tan, ch in c.root_rows]
    c.layers[c.layers.index(lay)] = weight_shift(wd["t_full"], wd["lift"], new_plant, end, u=wd["u"], r=wd["r"],
                                                 z=wd["z"], **wd.get("extra", {}))
    c.notes += "; weight released over %.1f f after the heel plants at f%.1f" % (end - new_plant, new_plant)


# (assemble, inspect, repair, maintenance, unbend, brace, operate and pickup are authored with their release timing
# directly: their returns are deliberately slower than their action beats)
for _n, _ta, _np in (("wk_tool_change", C_of(1.2) + 2.0, 29.5), ("wk_push", 28.0, 35.5), ("wk_pull", 28.0, 35.5),
                     ("wk_place", C_of(1.1) + 3.5, 27.0)):
    retime_release(_n, _ta, _np)


# ---------------------------------------------------------------- V-leg sit family (unsided)
# Geometry that drives the staging: the hips sit 11 cm above the cube's bottom, 20 cm behind its face and 19 cm inside
# its side walls.  With the bottom near the floor a bent knee must be OUTSIDE the cube: in front of the face (feet
# >= ~0.65 m ahead of the hips: the V) or beside it (a frog).  A supported knees-forward squat (body over its feet)
# reaches a bottom height of ~0.25 m at knee flex <= 135 deg; below that legs with the feet in front cannot carry the
# body.  Hence:
#  * wk_sit_down (A18 line): two steps forward-and-wide (L then R), a supported knees-forward squat leaning over the
#    feet (pitch +9, COM over the heels, knees forward/up in front of the lower face), then a SIT-BACK: the body rocks
#    back onto its bottom while the heels skid forward under the braking legs (no frog, the feet never pass beside the
#    body), plop + 1 cm bounce, each foot lifts and places into the V, lean back, face up.
#  * wk_sit_up: getting UP needs the feet near the COM, which only a frog allows (a reverse plop would be levitation):
#    the feet slide back LOW (<= 3 cm) one at a time to a compact frog ahead of the face's lower corners (+-0.56 m,
#    10 cm forward; knees forward in front of the face corners), the body rocks forward over them and pushes up, a
#    closing hop brings the feet to the stance.
#  * Seated hero pose: pitched back 16 deg about the back-bottom edge (face up), nearly straight V legs (knees ~0.19 m,
#    thighs ~5 deg up, flex ~20 deg) so both thighs leave the cube at its rounded bottom edge, not through the face.
#  * Travel: in place -- the seat and both standing ends are at the clip origin (root y 0); the squat leans 11 cm
#    forward over the feet and the sit-back brings it home.  seat_travel_m / seat_descent_m are reported per frame.
# Seat-descent ownership: the clips carry the FULL descent in root Z (-0.79 m seated); the runtime can drive the
# native seat_drop FROM the authored curve and subtract the native body's actual drop from the visual root.
BAL_UP = (1.0, 2.0)       # take-off key: in = secant (push), out = parabola slope
BAL_DN = (2.0, 1.6)       # landing key: in = parabola slope, out = carries the fall into the absorb
HOP_G = 1.15 * 9.81       # every hop falls at the same believable, slightly snappy 1.15 g
SEAT_Z = -0.86            # below the seated contact: the seat clamp raises the root until the bottom rests on the floor
SEAT_REST = -0.801        # nominal seated root (bottom on the floor, pitch -5..-16); the clamp makes it exact
SEAT_P = -16.0            # seated pitch (face up), about the back-bottom edge
SEAT_Y = 0.0              # in place
V_O, V_Y = 0.49, SEAT_Y + 0.893   # seated ankle reference (the heel pivot moves the ankle ~0.09 back): knees ~0.21 m
V_P = 42.0                # foot rests on its heel, toe up
V_POLE = dict(pw=1.0, pa=20.0, pe=62.0)   # knee straight up (body frame 28 deg forward of up), 6 deg outward
V = dict(o=V_O, y=V_Y, h=0.0, p=V_P, w=14.0, k=12.0, g=1.0, **V_POLE)
# compact frog for the rise: feet just ahead of the face's lower corners, knees forward in front of them
FR = dict(o=0.56, y=0.10, h=0.0, p=0.0, w=22.0, k=0.0, pw=1.0, pa=20.0, pe=12.0, g=1.0, t=0.0)
FR_RISE_Z = -0.10         # highest root the frog stance allows (legs ~straight at +-0.56)
_RISE_PK = 17.0           # sit_up: end of the push phase (fastest rise)


def _hop_rows(t0, t1, z0, z1=None):
    """Ballistic root z rows between a take-off at t0 (height z0) and a landing at t1 (height z1, default z0):
    take-off / landing keys carry the exact flight velocities (absolute slopes), so the push flows into the
    parabola and the parabola into the absorb without a velocity kink."""
    z1 = z0 if z1 is None else z1
    T = (t1 - t0) / FPS
    v0 = (z1 - z0) / T + 0.5 * HOP_G * T                 # take-off speed for the given flight (m/s)
    ta = v0 / HOP_G                                      # time to the apex
    za = z0 + v0 * ta - 0.5 * HOP_G * ta * ta
    v1 = v0 - HOP_G * T
    return [K(t0, z=(z0, Slope(v0 / FPS))), K(round(t0 + ta * FPS, 4), z=(za, "f")), K(t1, z=(z1, Slope(v1 / FPS)))]


def _pivot_shift(p):
    """(dy, dz) of the ankle when a planted foot (g = 1) is pitched p deg about its heel (p > 0) or ball (p < 0),
    relative to its unpitched reference: airborne rows (g = 0) that start / end at a pitched planted pose must aim at
    the pivoted ankle, or the foot jumps when g switches."""
    if abs(p) < 1e-6:
        return 0.0, 0.0
    piv_y = BALL_Y if p < 0.0 else HEEL_Y
    a = math.radians(p)
    ry, rz = -piv_y, SOLE_DROP
    y2 = ry * math.cos(a) - rz * math.sin(a)
    z2 = ry * math.sin(a) + rz * math.cos(a)
    return y2 - ry, z2 - rz


def _slide(f0, f1, a, b, lift=0.025, n=5, pole0=None, pole1=None, pole_u=1.0):
    """Low airborne foot rows between two planted poses a -> b (dicts with o, y, p, w): the foot skims the floor
    (<= lift above the pivoted ankle path), position eased, pitch / toe-out / knee pole blended (pole0 -> pole1 =
    (pa, pe)).  The end points are the PIVOTED planted ankles (heel / ball pivots), so g can switch without a jump."""
    rows = []
    ay, az = _pivot_shift(a["p"])
    by, bz = _pivot_shift(b["p"])
    for i in range(1, n):
        u = i / n
        e = u * u * (3 - 2 * u)
        ch = dict(o=a["o"] + (b["o"] - a["o"]) * e, y=a["y"] + ay + (b["y"] + by - a["y"] - ay) * e,
                  h=az + (bz - az) * e + lift * math.sin(math.pi * u),
                  p=a["p"] + (b["p"] - a["p"]) * e, w=a["w"] + (b["w"] - a["w"]) * e, g=0.0)
        if pole0 is not None:
            pe_ = smooth(0.0, pole_u, u)
            ch.update(pw=1.0, pa=pole0[0] + (pole1[0] - pole0[0]) * pe_, pe=pole0[1] + (pole1[1] - pole0[1]) * pe_)
        rows.append(K(round(f0 + (f1 - f0) * u, 4), **ch))
    return rows


SQ = dict(o=0.36, y=0.18)        # squat stance of wk_sit_down: forward and wide
HALF_V = dict(o=0.46, y=0.74, p=36.0, w=13.0)    # where the skidding heels stop at the plop


SB_POLE = dict(pa=44.0, pe=28.0)   # sit-back knee pole: out to the face's lower corners (splay <= 30 deg) so the
                                   # distal thigh clears the cube's front-side edge on every mesh (>= 4 mm on the oldest)


def _sd_foot(g, d):
    """wk_sit_down foot rows (d = this foot's step delay: L steps first)."""
    s0 = 4.0 + d                 # heel peel
    land = s0 + 4.5
    rows = [K(0, o=0.19, y=0.0, h=0.0, p=0.0, w=5.0, k=6.0, pw=0.0, pa=V_POLE["pa"], pe=V_POLE["pe"], g=1.0, t=0.0,
              tan="f"),
            K(s0, o=0.19, y=0.0, h=0.0, p=0.0, g=1.0, tan="f"),
            K(s0 + 1.0, p=-12.0, t=-4.0, g=1.0),                                    # heel peels
            K(s0 + 2.5, h=0.065, o=0.27, y=0.10, p=4.0, t=-6.0, g=0.0),             # step forward and out
            K(land - 0.6, h=0.012, o=SQ["o"] - 0.006, y=SQ["y"] - 0.006, p=8.0, g=0.6),
            K(land, h=0.0, o=SQ["o"], y=SQ["y"], p=6.0, w=14.0, t=0.0, g=1.0, tan="f"),   # heel lands
            K(land + 1.2, p=0.0, g=1.0, tan="f"),
            K(24.5, o=SQ["o"], y=SQ["y"], h=0.0, p=0.0, w=14.0, g=1.0, pw=0.0, tan="f"),   # planted through the squat
            # sit-back: the loaded heels skid forward (toes coming up) while the body rocks back onto its bottom
            # (the legs shoot out early -- knees stay low and out at the face's corners instead of rising in front of it)
            K(26.0, o=0.38, y=0.30, h=0.0, p=12.0, g=1.0, pw=0.6, **SB_POLE),
            K(27.5, o=0.42, y=0.48, h=0.0, p=22.0, g=1.0, pw=1.0),
            K(29.5, o=0.45, y=0.64, h=0.0, p=31.0, g=1.0),
            K(32.0, o=HALF_V["o"], y=HALF_V["y"], h=0.0, p=HALF_V["p"], w=HALF_V["w"], g=1.0, pa=40.0, pe=35.0, tan="f"),
            K(33.2, h=0.018, p=HALF_V["p"] + 4.0, g=0.6),                          # legs bounce on the plop
            K(34.5, h=0.0, p=HALF_V["p"], g=1.0, tan="f")]
    pl = 35.0 + d * 0.5           # V placement: L f35, R f38 (6 f each)
    hv = dict(o=HALF_V["o"], y=HALF_V["y"], p=HALF_V["p"], w=HALF_V["w"])
    rows += [K(pl, o=HALF_V["o"], y=HALF_V["y"], h=0.0, p=HALF_V["p"], w=HALF_V["w"], g=1.0, pw=1.0, pa=40.0, pe=35.0,
               tan="f")]
    rows += _slide(pl, pl + 6.0, hv, V, lift=0.03, n=5, pole0=(40.0, 35.0), pole1=(V_POLE["pa"], V_POLE["pe"]))
    rows += [K(pl + 6.0, tan="f", **V), K(48, **V)]
    return rows


clip("wk_sit_down", 1.6, notes="lower into the V-sit (A18): glance down at the spot, the feet step forward and wide "
     "(L then R, the body shifting over the support foot each time), a supported knees-forward squat leaning over the "
     "feet (pitch +9, knees up in front of the lower face, COM over the heels), then the sit-back: the body rocks "
     "back onto its bottom while the heels skid forward under the braking legs (feet never beside the body), plop "
     "(touch ~5 cm/f over the last 6-8 cm) + 1 cm bounce with the legs bouncing too, each foot lifts and places into the V (L then R), "
     "lean back to -16 deg, face up; in place (root y 0 at both ends)",
     seat=(25.0, 48.0), slides={"L": (25, 33), "R": (25, 33)},
     root=[
         K(0, x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0),
         K(3.5, p=7.0, z=-0.034, x=0.014, r=1.4),            # glance down at the spot, weight drifts onto R
         K(5.5, x=0.065, r=4.2, y=0.014),                    # over R: L steps (quick, like a gait step)
         K(8.0, z=-0.044, y=0.034, x=0.035),
         K(10.5, x=-0.065, r=-4.2, y=0.060, z=-0.050),       # over L: R steps
         K(13.0, z=-0.066, y=0.080, x=-0.035),
         K(15.0, x=0.0, r=0.0, p=8.0, z=-0.090, y=0.095),
         # squat: accelerate <= 1 g, keep moving (no stop) into the sit-back; the body stays over the heels
         K(19.5, z=-0.255, y=0.118, p=9.0),
         K(24.0, z=-0.470, y=0.130, p=9.0),
         # sit-back: the body rocks back onto its bottom (pitch +9 -> -21, the face swings up out of the knees' way)
         # while the descent continues into the plop
         K(26.0, z=-0.545, y=0.112, p=-2.0),
         K(28.0, z=(-0.611, Slope(-0.038)), y=0.070, p=-12.5),            # falls back: legs brake, <= 0.5 g
         K(30.0, z=(-0.693, Slope(-0.046)), y=0.028, p=-15.0),
         K(32.0, z=(-0.792, Slope(-0.050)), y=0.0, p=-20.0),             # bottom touches (~4.5 cm/f): plop
         K(33.6, z=(SEAT_REST + 0.010, "f"), p=-19.0),                   # 1 cm bounce, rocks forward a touch
         K(35.6, z=(SEAT_Z, "f"), p=-15.5),
         K(38.5, p=-14.8, r=0.8),
         K(42.5, p=-17.6, r=-0.6, w=2.0),                                # lean back, face up (overshoot)
         K(45.5, p=-16.5, w=1.0),
         K(48, x=0.0, y=SEAT_Y, z=SEAT_Z, p=SEAT_P, r=0.0, w=0.0),
     ],
     feet={g: _sd_foot(g, d) for g, d in (("L", 0.0), ("R", 6.0))},
     )


def _lift(t0, rise, hold, lower, amp, dy=-0.012, dp=5.0):
    """Seated foot lift: ease-out rise, short hold (with micro drift), ease-in-out lower."""
    t1, t2, t3 = t0 + rise, t0 + rise + hold, t0 + rise + hold + lower
    return [K(t0, h=0.0, y=V_Y, p=V_P, tan="f"),
            K(t1, h=amp, y=V_Y + dy, p=V_P + dp, tan="f"),
            K(t2, h=amp * 0.92, y=V_Y + dy * 0.9, p=V_P + dp * 0.9),
            K(t3, h=0.0, y=V_Y, p=V_P, tan="f")]


clip("wk_sit_idle", 4.8, loop=True, seat=(0.0, 144.0), notes="attentive V-sit: body pitched back 16 deg, nearly "
     "straight V legs (knees ~0.19 m), slow alternating 2-4 cm foot lifts with uneven gaps, toe wiggles, breathing, "
     "unhurried attention turns and small settles (no span over 6 f without visible change)",
     root=[
         K(0, x=0.0, y=SEAT_Y, z=SEAT_Z, p=SEAT_P, r=0.0, w=0.0),
         K(12, w=0.4), K(18, w=-0.6), K(28, w=-5.2, r=-0.8), K(36, w=-4.4, p=-17.4), K(41, w=-5.0), K(46, w=-4.6, p=-18.0),
         K(56, p=-17.6), K(64, w=1.0, r=0.0), K(74, w=0.2), K(84, p=-15.0), K(96, w=1.5), K(106, w=5.6, r=0.9, p=-16.4),
         K(114, w=4.8), K(122, w=5.2), K(136, w=0.0, r=0.0, p=SEAT_P),
     ] + [
         K(0, z2=0.0, p2=0.0), K(34, z2=0.003, p2=-0.3), K(39, z2=0.0018, p2=-0.15), K(70, z2=-0.0005, p2=0.05),
         K(106, z2=0.0032, p2=-0.32),
     ],
     feet={
         "L": [K(0, **V)]
              + _lift(6, 11, 4, 16, 0.032) + _lift(80, 10, 4, 14, 0.022)
              + [K(58, t=0.0), K(61, t=18.0), K(64, t=-4.0), K(67, t=12.0), K(71, t=0.0)],
         "R": [K(0, **V)]
              + _lift(42, 10, 4, 14, 0.026) + _lift(112, 11, 4, 15, 0.036, dp=6.0)
              + [K(72, t=0.0), K(75.5, t=10.0), K(79, t=-2.0), K(86, t=0.0), K(89, t=14.0), K(93, t=-3.0),
                 K(97, t=0.0), K(128, t=0.0), K(131, t=9.0), K(135, t=0.0)],
     })


def _su_foot(g, a, d):
    """wk_sit_up foot rows: from the V the foot slides back low to the compact frog (a = start), then the closing hop
    (d = R lands half a frame later and tucks higher)."""
    hv = dict(o=V_O, y=V_Y, p=V_P, w=14.0)
    fr = dict(o=FR["o"], y=FR["y"], p=0.0, w=FR["w"])
    # the knee pole turns from 'up' (V) to 'forward, slightly up' within the first 40 % of the slide (while the leg
    # is still long): the knee folds forward-low in front of the face's lower half (it cannot pass beside the cube's
    # front corner without entering it), rather than rising across the eyes
    return ([K(0, tan="f", **dict(V, t=0.0)),
             K(a, tan="f", **V)]
            + _slide(a, a + 6.5, hv, fr, lift=0.03, n=6, pole0=(V_POLE["pa"], V_POLE["pe"]),
                     pole1=(FR["pa"], FR["pe"]), pole_u=0.4)
            + [K(a + 6.5, tan="f", **FR),                                               # planted ahead of the corner
               K(17.0, pa=FR["pa"]),
               K(22.0, tan="f", **dict(FR, pa=12.0)),
               K(23.0, o=FR["o"], y=FR["y"], h=0.0, p=-14.0, t=0.0, g=1.0, w=FR["w"], tan="f"),    # push-off
               K(24.2 + d, h=0.05 + 0.02 * d, o=0.44, y=0.05, p=-4.0, g=0.3),                    # R tucks higher
               K(25.8, h=0.03, o=0.25, y=0.01, p=3.0, g=0.0, w=8.0, k=6.0, pw=0.2),
               K(27.0, o=0.19, y=0.0, h=0.0, p=0.0, w=5.0, k=6.0, pw=0.0, g=1.0, tan="f"),
               K(33, o=0.19, y=0.0, h=0.0, p=0.0, w=5.0, k=6.0, pw=0.0, g=1.0)])


clip("wk_sit_up", 1.1, notes="supported rise (in place): eyes snap and the head lifts, the feet slide back LOW (<= 3 cm, "
     "L then R) to a compact frog just ahead of the face's lower corners (knees forward), the body rocks forward over "
     "the soles and pushes up (COM over the feet; ~1.4 g push, 1 g ease-out) into a small closing hop to the stance "
     "(L lands half a frame first), absorb and settle; ends at the clip origin (root y 0)",
     seat=(0.0, 33.0),
     root=[
         K(0, x=0.0, y=SEAT_Y, z=SEAT_Z, p=SEAT_P, r=0.0, w=0.0),
         K(1.5, p=-19.0),                                 # eyes snap: the head lifts
         K(4.0, p=-19.5),
         K(9.0, p=-14.0, z=SEAT_Z),
         K(12.0, z=(SEAT_REST, "f"), p=-3.0, y=0.03),     # rocks forward: weight onto the feet
         K(14.5, p=6.0, y=0.045),
         # push: ~1.4 g up, then a 1 g deceleration that carries straight into the hop-in take-off
         K(_RISE_PK, z=(SEAT_REST + 0.317, Slope(0.0997)), p=4.0, y=0.04),
         K(23.0, p=1.0, y=0.02),
     ] + _hop_rows(23.0, 27.0, FR_RISE_Z, -0.048) + [
         K(25.0, p=-3.0, r=1.0, y=0.0),                   # face up "ta!"
         K(27.0, p=1.5, r=0.0),
         K(29.0, z=Z0 - 0.026, p=4.0, tan="f"),           # absorb
         K(31.0, z=Z0 - 0.005, p=2.0),
         K(33, x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0),
     ],
     feet={g: _su_foot(g, a, d) for g, a, d in (("L", 1.5, 0.0), ("R", 4.5, 1.0))},
     )


# ---------------------------------------------------------------- social / acting
# Airborne root segments use ballistic tangents (BAL_UP / BAL_DN, defined with the sit family): (.., 2) out of a
# take-off key and (2, ..) into a landing key with a flat apex reproduce a free-fall parabola exactly.

clip("wk_greet", 1.6, notes="greeting (starts from the wk_idle frame-0 pose: weight on R, feet 5.7 cm offset, "
     "2 deg roll): 'oh!' rise onto the toes, weight onto L and a small R adjust step back "
     "(feet end offset 7 cm, never twin posts), dip wind-up, bow-hop (~5 cm, ballistic) with a 12 deg nod at "
     "the apex and the R foot tucked higher, landing absorb, happy glow: weight on L with a 6-7 deg side-tilt, "
     "free R heel pops on the tiny bounce, eased release, R steps back to the stance",
     root=[
         K(0, x=0.012, y=0.0, z=-0.024, p=2.0, r=2.0, w=0.0),   # = wk_idle f0 (weight on R, feet offset)
         K(2, z=-0.026, p=2.6, x=0.010, r=1.6),           # notices
         K(5.5, z=-0.010, p=-3.0, y=0.045, x=0.004, r=0.8, tan="f"),   # "oh!" up on the toes (body over the balls)
         K(9, z=-0.032, p=-0.5, x=-0.060, r=-3.0, y=0.006),   # weight well onto L before R moves
         K(13.5, x=-0.050, r=-2.6, z=-0.036, y=0.0),
         K(15, z=-0.060, p=-3.0, x=-0.010, r=-0.5),
         K(16.5, z=-0.074, p=-4.0, x=-0.008, r=0.0, tan="f"),   # wind-up dip
         K(18.5, z=-0.012, p=3.0, tan=BAL_UP),            # take-off
         K(21.3, z=0.030, p=12.0, tan="f"),               # bow-hop apex: the nod
         K(24.2, z=-0.012, p=7.0, tan=BAL_DN),            # touch-down
         K(27.5, z=-0.074, p=2.0, x=-0.014, tan="f"),     # absorb
         K(31, z=-0.040, p=-2.5, x=-0.044, r=-4.5, w=-2.0),
         K(33, z=-0.036, r=-6.0),
         K(35, z=-0.052, r=-7.0, w=-4.0),                 # tiny bounce, aww tilt
         K(37.5, z=-0.042, r=-5.8, p=-3.0),
         K(38.5, r=-4.6, w=-2.5, z=-0.042, x=-0.058),
         K(40.6, x=-0.062, r=-3.4, p=0.0, z=-0.036),           # over L while R steps home
         K(42.6, x=-0.046, r=-2.5),                            # recentres over 7.5 f as R lands ...
         K(44.6, x=-0.022, r=-1.0, z=-0.030),
         K(46.4, x=-0.006, r=-0.2, w=-0.4),
         K(48, x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0, tan="f"),   # ... and arrives with zero speed
     ],
     feet={
         "L": [K(0, o=0.175, y=0.045, h=0.0, p=0.0, w=9.0, g=1.0, t=0.0, tan="f"),   # = wk_idle f0
               K(2, h=0.0, p=0.0, t=0.0, g=1.0, tan="f"),
               K(5.5, h=0.0, p=-12.0, t=-4.0, g=1.0, tan="f"),
               K(9, h=0.0, p=0.0, t=0.0, g=1.0, tan="f"),
               K(16.5, h=0.0, p=0.0, y=0.045, g=1.0, tan="f"),
               K(18, h=0.0, y=0.045, o=0.175, p=-22.0, t=-8.0, g=1.0, tan="f"),     # push-off on the ball
               K(19.3, h=0.03, p=-14.0, t=-6.0, g=0.6),
               K(21.3, h=0.075, y=0.025, o=0.185, p=-2.0, t=-2.0, g=0.0),       # the hop brings L home
               K(23.6, h=0.012, y=0.003, p=5.0, g=0.6),
               K(24.2, h=0.0, y=0.0, o=0.19, p=0.0, t=0.0, g=1.0, tan="f"),
               K(48, h=0.0, y=0.0, o=0.19, p=0.0, t=0.0)],
         "R": [K(0, o=0.19, y=-0.012, h=0.0, p=0.0, w=5.0, g=1.0, t=0.0, tan="f"),   # = wk_idle f0
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
               K(37.5, h=0.0, p=-14.0, t=-4.0, g=1.0, k=-10.0),
               K(39.0, o=0.21, y=-0.07, h=0.0, p=-6.0, g=1.0, k=4.0, tan="f"),
               K(40.0, o=0.21, y=-0.07, h=0.0, p=-12.0, g=1.0),        # step back into the stance
               K(41.1, h=0.04, o=0.20, y=-0.04, p=2.0, g=0.0),
               K(42.2, o=0.19, y=-0.01, h=0.0, p=0.0, g=1.0, tan="f"),
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
               K(27, h=0.0, p=0.0)] for g, d, e in (("L", 0.0, 0.0), ("R", 0.3, 0.03))})


# ---------------------------------------------------------------- dances (120 BPM, beat = 15 f, 8 beats)
# Grammar: groove dips land ON the beat (2 f down, 5 f up), 5 cm deep with +/-7 deg rolls; hits on beats 1 and 5
# (and the phrase end) are asymmetric poses -- weight on one leg, knees out 18-24 deg, the other foot offset or
# pointed -- held 4-6 f with life; every hop is ballistic with a real tuck (feet >= 10 cm up relative to the body)
# and the two feet never move as twins (offset timing / height / placement).


def dance_stance(dz=-0.022, dk=3.0, t_in=(0.0, 6.0), t_out=(112.0, 120.0)):
    """Dance base: a lower, springier stance (knees bent ~40 deg) with the knees a touch out (base splay ~9 deg,
    5.1's bow-legged-cute range; the hits open them to ~20 deg), eased in over the first beat and out over the last,
    so the legs never read as straight posts between the accents."""
    def fn(t, P, ev):
        env = smooth(t_in[0], t_in[1], t) * (1.0 - smooth(t_out[0], t_out[1], t))
        P["root"]["z2"] += dz * env
        for leg in "LR":
            P[leg]["k"] += dk * env
    return fn


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


def _tuck_land(rows, f, **ch):
    """Replace the landing key of a _tuck() row list (e.g. land heel-first with the toe up)."""
    rows = list(rows)
    assert abs(rows[-1][0] - f) < 1e-6
    rows[-1] = K(f, tan="f", **ch)
    return rows


clip("wk_dance_a", 4.0, notes="phrase A: TA-DA jump-out hit (b1: wide asymmetric feet, knees out, roll 8), "
     "groove with a heel pop (b2), side-step R then L travelling 0.25 m each way with rolls into the steps (b3-4), "
     "a real forward KICK on b5 (2 f snap from the chamber to a near-straight leg at 45 deg, toe pointed, body leaning "
     "back over the L leg, held with life, re-chambered), knee-pop groove (b6), wind-up and a two-hop 360 spin "
     "(slow-fast-slow) landing on the 8th grid (7-and = f97.5, beat 8 = f105) into a DIFFERENT ta-da: weight on L, "
     "R heel dug in front with the toe up, leaning back -- and a settle",
     layers=[dance_stance()],
     spin=[(0, 0.0, "f"), (93.5, 0.0, "f"), (97.5, 180.0, "f"), (99.5, 180.0, "f"), (105, 360.0, "f"),
           (120, 360.0, "f")],
     root=[
         K(0, x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0),
         K(2.0, z=-0.050, p=0.0, tan="f"),                       # 2 f anticipation dip ...
         K(5.5, r=6.0, p=-4.0, x=-0.010),                        # ... jump-out (ballistic 3 -> 5.5) ...
         K(7.5, z=-0.078, r=8.0, p=-5.0, x=-0.012, tan="f"),     # ... TA-DA hit (b1)
         K(11, r=8.6, p=-5.5),
         # groove dips land ON the beat / the 'and' (2.5 f down at <= 1 g, then up)
         K(12.5, z=(-0.058, "f"), r=1.0, p=1.0, x=0.0),
         K(15, z=(-0.082, (2.0, "f")), r=-7.0, w=-8.0),                                  # b2 groove
         K(20, z=(-0.052, "f"), w=4.0, r=-2.0), K(22.5, z=(-0.084, (2.0, "f")), r=7.0, w=8.0),
         K(27, z=-0.055, r=2.0, w=0.0), K(57, w=0.0), K(70.5, w=0.0),
         K(27.5, z=(-0.052, "f"), x=0.0), K(30, z=(-0.084, (2.0, "f")), r=3.0),          # b3: travel R 0.25
         K(34.5, x=0.11, r=8.0, z=-0.065),
         K(37.5, z=-0.098, tan="f"),
         K(40.5, x=0.23, r=4.0, z=-0.058),
         K(43, x=0.25, r=1.5),
         K(42.5, z=(-0.052, "f")), K(45, z=(-0.084, (2.0, "f")), r=-3.0),                # b4: travel L back
         K(49.5, x=0.10, r=-8.0, z=-0.065),
         K(52.5, z=-0.090, tan="f"),
         K(55, x=-0.03, r=-5.0, z=-0.070),
         K(57, x=-0.065, r=-7.0, z=-0.062, p=0.0),                                     # weight onto L
         K(58.5, z=-0.048, p=-5.0),
         K(60, z=-0.040, p=-10.0, r=-7.5, tan="f"),                                    # KICK hit (b5): leans back
         K(62.5, z=-0.046, p=-9.0, r=-6.5),
         K(65, z=-0.042, p=-10.0, r=-7.2),
         K(68.5, z=-0.060, p=-2.0, x=-0.05, r=-4.0),
         K(70.5, z=-0.064, x=-0.01, r=-1.0, p=1.0),
         K(72.5, z=(-0.052, "f"), x=0.0, r=0.0), K(75, z=(-0.086, (2.0, "f")), r=7.0, w=7.0),   # b6 knee pops
         K(80, z=(-0.054, "f"), w=-3.0, r=0.0), K(82.5, z=(-0.086, (2.0, "f")), r=-7.0, w=-7.0),
         K(87, z=-0.06, r=0.0), K(88.5, w=0.0),
         K(91.0, w=-26.0),
         K(92.0, w=-30.0, z=-0.058, p=4.0, tan="f"),                                     # wind-up dip, 1 f hang (b7)
         K(95.5, w=70.0, p=-1.0),
         K(97.5, w=172.0, p=3.0),                                                       # 7-and: touch ...
         K(98.5, z=-0.052, tan="f"),                                                    # ... re-bound (feet planted:
         K(99.5, w=192.0),                                                              #  body turns only 20 deg)
         K(102.25, w=290.0, p=-3.0),
         K(105, w=360.0, p=-4.0, x=-0.02),                                              # beat 8: land ...
         K(107.5, z=-0.090, r=-6.0, p=-7.5, x=-0.050, tan="f"),                         # ... heel-dig TA-DA
         K(109.5, z=-0.080, r=-6.6, p=-8.0),
         K(111.5, z=-0.084, r=-5.6, p=-6.8, x=-0.046),
         K(115.5, z=-0.050, r=-1.0, p=1.0, x=-0.010),
         K(120, x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=360.0),
     ] + _hop_rows(3.0, 5.5, -0.038) + _hop_rows(93.5, 97.5, -0.032) + _hop_rows(99.5, 105.0, -0.042),
     feet={
         "L": [K(0, o=0.19, y=0.0, h=0.0, p=0.0, w=5.0, g=1.0, t=0.0, k=6.0, tan="f"),
               K(2.0, h=0.0, o=0.19, y=0.0, p=0.0, w=5.0, g=1.0, tan="f"),
               K(3.0, h=0.0, o=0.19, y=0.0, p=-14.0, w=5.0, g=1.0, tan="f"), K(4.3, h=0.06, o=0.27, y=0.02, p=0.0, g=0.0),
               K(5.5, h=0.0, o=0.34, y=0.03, k=18.0, w=14.0, g=1.0, tan="f"),               # wide, toe out
               K(12, k=6.0), K(13.5, p=0.0, g=1.0, tan="f"), K(15, p=-18.0, g=1.0),    # heel pop ON b2
               K(17.5, p=0.0, g=1.0, tan="f"),
               K(37.5, o=0.34, y=0.03, h=0.0, tan="f"),                                # L closes (b3) ...
               K(39, h=0.05, o=0.14), K(40.5, o=-0.06, y=0.02, h=0.0, tan="f"),        # ... under the travelled body
               K(45, o=-0.06, y=0.02, h=0.0, tan="f"), K(47, h=0.06, o=0.12, y=0.0),         # L steps out (b4)
               K(49.5, o=0.30, y=-0.01, h=0.0, k=6.0, tan="f"),
               K(72.5, o=0.30, y=-0.01, h=0.0, p=0.0, g=1.0, k=6.0, tan="f"),
               K(73.5, h=0.0, p=0.0, g=1.0, k=14.0, tan="f"), K(75, p=-16.0, g=1.0),  # knee pop L ON b6
               K(78, p=0.0, g=1.0, k=6.0, tan="f"),
               K(86.5, o=0.30, y=-0.01, h=0.0, tan="f"), K(88, h=0.04, o=0.26),        # close for the spin
               K(89.5, o=0.21, y=0.0, h=0.0, w=5.0, tan="f"),
               ] + _tuck(93.5, 97.5, 0.15, y=0.05, o=0.21, lead=-0.3, o0=0.21)[1:]
               + _tuck(99.5, 105.0, 0.23, y=0.05, o=0.23, settle=-0.03, o0=0.21)[1:] + [
               K(105, k=12.0, w=12.0),
               K(112, o=0.23, y=-0.03, h=0.0, p=0.0, g=1.0, k=12.0, tan="f"),
               K(116.5, o=0.23, y=-0.03, h=0.0, p=0.0, g=1.0, w=12.0, tan="f"),        # L adjusts last
               K(117.6, h=0.03, o=0.21, y=-0.015, p=2.0, g=0.0, w=8.0),
               K(118.8, o=0.19, y=0.0, h=0.0, p=0.0, k=6.0, w=5.0, g=1.0, tan="f"),
               K(120, o=0.19, y=0.0, h=0.0, k=6.0, w=5.0)],
         "R": [K(0, o=0.19, y=0.0, h=0.0, p=0.0, w=5.0, g=1.0, t=0.0, k=6.0, tan="f"),
               K(2.0, h=0.0, o=0.19, y=0.0, p=0.0, w=5.0, g=1.0, tan="f"),
               K(3.0, h=0.0, o=0.19, y=0.0, p=-14.0, w=5.0, g=1.0, tan="f"), K(4.4, h=0.05, o=0.25, y=-0.02, p=0.0, g=0.0),
               K(5.5, h=0.0, o=0.29, y=-0.05, k=18.0, w=8.0, g=1.0, tan="f"),
               K(12, k=6.0), K(21, p=0.0, g=1.0, tan="f"), K(22.5, p=-16.0, g=1.0),
               K(25, p=0.0, g=1.0, tan="f"),
               K(30, o=0.29, y=-0.05, h=0.0, tan="f"), K(32, h=0.07, o=0.41, y=-0.03),   # R steps out 0.25 (b3)
               K(34.5, o=0.54, y=-0.02, h=0.0, k=6.0, tan="f"),
               K(52.5, o=0.54, y=-0.02, h=0.0, tan="f"), K(54, h=0.05, o=0.42),        # R closes (b4)
               K(55.5, o=0.29, y=0.0, h=0.0, tan="f"),
               K(56.5, h=0.0, y=0.0, p=0.0, t=0.0, o=0.29, g=1.0, tan="f"),
               K(57.2, h=0.20, y=0.15, p=2.0, t=2.0, o=0.26, g=0.0),                   # chamber: knee up
               K(60, h=0.20, y=0.58, p=-38.0, t=-14.0, o=0.25, g=0.0, tan=("l", "f")),     # KICK: snaps out, 45 deg
               K(62.5, h=0.212, y=0.57, p=-35.0, t=-12.0, g=0.0),                      # held with life
               K(65, h=0.206, y=0.58, p=-39.0, t=-15.0, g=0.0, tan="f"),
               K(68, h=0.19, y=0.18, p=8.0, t=0.0, o=0.28, g=0.0),                     # re-chamber
               K(69.6, h=0.02, y=0.01, p=4.0, g=0.6),
               K(70.3, h=0.0, y=0.0, p=0.0, o=0.30, g=1.0, k=6.0, tan="f"),
               K(80.5, h=0.0, p=0.0, g=1.0, k=14.0, tan="f"), K(82.5, p=-16.0, g=1.0),  # knee pop R on the and
               K(85.5, p=0.0, g=1.0, k=6.0, tan="f"),
               K(90.0, o=0.30, y=0.0, h=0.0, tan="f"), K(91.0, h=0.04, o=0.25),
               K(92, o=0.20, y=0.0, h=0.0, w=5.0, tan="f"),
               ] + _tuck(93.5, 97.5, 0.18, y=0.04, o=0.20, lead=0.3, o0=0.20)[1:]
               + _tuck_land(_tuck(99.5, 105.0, 0.25, y=0.14, o=0.26, o0=0.20)[1:], 105.0,
                            h=0.0, y=0.21, o=0.26, p=22.0, t=6.0, w=10.0, g=1.0) + [   # lands heel-first, toe up
               K(109.5, p=26.0, t=10.0),
               K(112, o=0.26, y=0.21, h=0.0, p=24.0, g=1.0, tan="f"),
               K(113.5, h=0.035, o=0.23, y=0.11, p=6.0, g=0.0), K(115.5, o=0.19, y=0.0, h=0.0, p=0.0, k=6.0, w=5.0, g=1.0, tan="f"),
               K(120, o=0.19, y=0.0, h=0.0, k=6.0, w=5.0)],
     })


def _taps():
    """Phrase B beats 1-4: taps land ON the 8ths (f 7.5 ... 52.5) and change every beat so the groove never
    loops: forward heel taps (b1), diagonal-out heel taps (b2), toe taps behind with the roll reversed (b3), a
    beat-4 accent (deep dip + 2 f freeze) and a long forward heel tap.  The body sways over the support foot on
    every tap (no single support far from the COM), yaws toward the tap (away from it on back taps) and dips ON
    the beat (2 f down, 5 f up; 2 cm on the 'and's)."""
    kinds = ["fwd", "fwd", "diag", "diag", "back", "back", "far"]
    L, R, root = [], [], []
    for i, kind in enumerate(kinds):
        g = 7.5 * (i + 1)                                        # contact ON the 8th
        side = "L" if i % 2 == 0 else "R"
        leg = L if side == "L" else R
        sgn = -1.0 if side == "L" else 1.0                       # tapping side (x sign)
        tap = {"fwd": dict(y=0.25, o=0.22, p=28.0, w=6.0), "diag": dict(y=0.17, o=0.40, p=24.0, w=30.0),
               "back": dict(y=-0.17, o=0.26, p=-32.0, w=8.0, t=-16.0), "far": dict(y=0.31, o=0.20, p=30.0, w=8.0)}[kind]
        # (big readable taps: the knee lifts the foot 8 cm on the way, the diagonal taps go well out to the side)
        mid = dict(h=0.08, y=0.45 * tap["y"], o=0.5 * (0.19 + tap["o"]), p=0.3 * tap["p"], g=0.0)
        hold = 1.0 if i == 5 else 0.0                            # beat-4 freeze
        lift = 2.2 if i == 6 else 2.8
        leg += [K(g - lift, h=0.0, y=0.0, o=0.19, p=0.0, w=5.0, t=0.0, g=1.0, tan="f"),
                K(g - 0.5 * lift, **mid),
                K(g, h=0.0, g=1.0, tan="f", **tap),               # tap lands on the grid
                K(g + 1.5 + hold, h=0.0, g=1.0, tan="f", **tap),
                K(g + 2.9 + hold, h=0.035, y=0.15 * tap["y"], o=0.19 + 0.2 * (tap["o"] - 0.19),
                  p=0.2 * tap["p"], t=0.0, g=0.0),                    # comes home from above (no skid)
                K(g + 4.2 + hold, h=0.0, y=0.0, o=0.19, p=0.0, w=5.0, t=0.0, g=1.0, tan="f")]
        back = -1.0 if kind == "back" else 1.0
        root += [K(g - 3.0, x=0.0, r=0.0),
                 K(g, x=-sgn * 0.055, r=-sgn * 5.0 * back, w=sgn * 12.0 * back, tan="f"),   # over the support foot
                 K(g + 3.5 + (1.0 if i == 5 else 0.0), w=0.0)]
        beat = abs(g / 15.0 - round(g / 15.0)) < 1e-6
        depth = (-0.090 if i == 5 else -0.084) if beat else -0.068      # <= 1 g down: 3 cm in 2.5 f
        if i != 6:
            root += [K(g - (3.0 if i == 5 else 2.5), z=(-0.052, "f"))]
        root += [K(g, z=(depth, (2.0, "f")))]
        if i == 5:      # beat-4 accent: freeze in the dip, then a slow rise into the last tap
            root += [K(g + 2.0, z=(depth + 0.002, "f")), K(g + 3.5, z=-0.075)]
        elif i == 6:
            root += [K(g + 4.0, z=-0.055)]
        else:
            root += [K(g + 4.0, z=-0.055)]
    return L, R, root


_tL, _tR, _troot = _taps()
clip("wk_dance_b", 4.0, notes="phrase B: taps ON the 8ths that change every beat (forward heel taps, diagonal-out "
     "taps, toe taps behind with the roll reversed, a beat-4 accent dip + 2 f freeze, a long heel tap), the body "
     "sways over the support foot on each tap and dips ON the beat (b1-4), hop and hop (b5, b6: ballistic, feet tucked 9-12 cm above the body's lift, alternating "
     "which foot tucks higher), big gathered HOP with a 15 cm tuck (b7), pose hit on b8 with the weight on L and "
     "the R toe pointed out to the side, settle",
     layers=[dance_stance()],
     root=[K(0, x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0)] + _troot + [
         K(57.5, w=0.0, r=0.0, x=0.0, z=(-0.052, "f")),
         K(60, z=(-0.084, (2.0, "f")), p=2.0),                                           # hop (b5)
         K(68, z=-0.070, p=3.0, r=2.0, tan="f"),
         K(71.5, z=-0.054, r=0.0),
         K(74.5, z=-0.086, p=2.0, tan="f"),                                             # hop (b6)
         K(83, z=-0.070, p=3.0, r=-2.0, tan="f"),
         K(88, z=-0.108, p=5.0, r=0.0, tan="f"),                                        # big gather
         K(95, p=-8.0, r=4.0),                                                          # HOP apex (b7)
         K(102.5, z=-0.105, p=4.0, r=0.0, tan="f"),
         K(105, z=-0.072, p=-5.0, r=-8.0, x=-0.10),                                    # pose hit (b8): over L
         K(107, z=-0.075, p=-6.0, r=-8.6),
         K(111, z=-0.064, p=-5.5, r=-8.0, x=-0.10),
         K(115.5, z=-0.040, p=1.0, r=-1.5, x=-0.04),                                   # R steps home ...
         K(117.5, x=0.0, r=0.0),                                                       # ... then L adjusts
         K(120, x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0),
     ] + _hop_rows(61.5, 67.0, -0.042) + _hop_rows(76.5, 82.0, -0.042) + _hop_rows(90.5, 100.0, -0.025),
     feet={
         "L": [K(0, o=0.19, y=0.0, h=0.0, p=0.0, w=5.0, g=1.0, t=0.0, tan="f")] + _tL + [
             K(58, h=0.0, y=0.0, p=0.0, tan="f")]
             + _tuck(61.5, 67.0, 0.14, y=0.05, lead=-0.3)[1:] + _tuck(76.5, 82.0, 0.11, y=0.03, lead=0.3)[1:]
             + _tuck(90.5, 100.0, 0.31, y=0.08, o=0.23, lead=-0.4)[1:] + [
             K(115.5, h=0.0, o=0.23, tan="f"), K(117.3, h=0.035, o=0.21), K(119, h=0.0, o=0.19, tan="f"),
             K(120, h=0.0, o=0.19)],
         "R": [K(0, o=0.19, y=0.0, h=0.0, p=0.0, w=5.0, g=1.0, t=0.0, tan="f")] + _tR + [
             K(60, h=0.0, p=0.0, t=0.0, g=1.0, tan="f")]
             + _tuck(61.5, 67.0, 0.11, y=0.02, lead=0.3)[1:] + _tuck(76.5, 82.0, 0.145, y=0.06, lead=-0.3)[1:]
             + _tuck(90.5, 100.0, 0.34, y=0.06, o=0.25, lead=0.4)[1:] + [
             K(102.5, h=0.0, o=0.25, y=0.0, p=0.0, g=1.0, tan="f"),
             K(103.6, h=0.035, o=0.34, y=0.035, p=-14.0, w=12.0, g=0.0),
             K(104.4, h=0.012, o=0.40, y=0.055, p=-26.0, t=-4.0, w=20.0, g=0.4),
             K(105, h=0.0, o=0.42, y=0.06, p=-34.0, t=-6.0, w=24.0, g=1.0, tan="f"),      # toe pointed out
             K(111, o=0.42, y=0.06, h=0.0, w=24.0, p=-32.0, t=-5.0, g=1.0, tan="f"),
             K(113, h=0.04, o=0.30, y=0.03, p=-6.0, t=0.0, g=0.0),
             K(115.5, h=0.0, o=0.19, y=0.0, p=0.0, w=5.0, g=1.0, tan="f"),
             K(120, h=0.0, o=0.19)],
     })

clip("wk_dance_c", 4.0, notes="phrase C: big heel-toe taps out on the diagonals with body counter-rolls and "
     "counter-yaws (b1-2), double knee pops with the knees snapping out and alternating heel pops (b3), body wave "
     "(b4), FLAMINGO knee-up hit on the L leg with a balance wobble (b5), quick knee swap (b6), ballistic side hops "
     "R then L with tucks (b7), a SIDE-LUNGE ta-da (b8: weight dipped over L, R leg slid out straight to the side "
     "on a pointed toe, body rolled and turned over L) and step back in",
     layers=[dance_stance()],
     root=[
         K(0, x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0),
         K(3, p=-4.0, r=7.5, z=-0.058, x=0.05, w=-7.0), K(10, p=3.0, r=-3.5, z=-0.045, w=5.0),   # b1 heel / toe
         K(15, z=-0.045, w=0.0), K(18, p=-4.0, r=-7.5, z=-0.058, x=-0.05, w=7.0),
         K(25, p=3.0, r=3.5, z=-0.045, x=0.0, w=-4.0), K(29, w=0.0),                     # b2
         K(27.5, z=(-0.045, "f"), r=0.0), K(30, z=(-0.078, (2.0, "f")), r=7.5), K(34, z=-0.050),   # b3 pops ON the beat
         K(35, z=(-0.05, "f")), K(37.5, z=(-0.082, (2.0, "f")), r=-7.5), K(42, z=-0.050, r=0.0),
         K(45, p=2.0, w=0.0), K(49, p=10.0, w=-9.0, z=-0.068), K(53, p=-8.0, w=5.0, z=-0.036),   # b4 wave
         K(57, p=4.0, w=9.0, z=-0.055, x=0.0),
         K(59, p=0.0, w=2.0, x=-0.07, r=-4.0, z=-0.055),
         K(62, p=-6.0, r=-8.5, w=0.0, z=-0.048, x=-0.088, tan="f"),                     # FLAMINGO (b5)
         K(64.5, r=-10.0), K(66.5, r=-7.4), K(68.5, r=-9.0),
         K(71, r=-2.0, p=0.0, x=-0.03, z=-0.056),
         K(73, z=-0.056, x=0.05, r=4.0),
         K(75, z=-0.052, x=0.085, r=8.5, p=-4.0, tan="f"),                             # b6 swap (R stands)
         K(79, r=7.0), K(82, r=8.4), K(85, z=-0.055, x=0.03, r=2.0, p=0.0),
         K(86, z=-0.058, x=0.0, r=0.0),
         K(88.5, z=-0.086, x=0.0, tan="f"),                                             # hop R (b7)
         K(93.5, x=0.06, r=4.0),
         K(97.3, z=-0.068, x=0.11, r=2.0, tan="f"),                                    # absorb, hop L
         K(101.25, x=0.05, r=-4.0),
         K(103, w=0.0),
         K(105.5, z=-0.088, r=-9.0, p=-4.5, x=-0.065, w=-9.0),                          # SIDE-LUNGE TA-DA (b8) ...
         K(107.5, z=-0.100, r=-9.6, p=-5.5, w=-8.0, tan="f"),                          # ... sinks into it
         K(109.5, z=-0.092, r=-9.0),
         K(111.5, z=-0.098, r=-8.8, p=-4.8, w=-9.0, x=-0.062),
         K(114.5, z=-0.050, r=-2.0, p=1.0, x=-0.02, w=-2.0),
         K(117.5, x=0.0, r=0.0, w=0.0),
         K(120, x=0.0, y=0.0, z=Z0, p=P0, r=0.0, w=0.0),
     ] + _hop_rows(90.5, 96.0, -0.046) + _hop_rows(98.5, 104.0, -0.046),
     feet={
         "L": [K(0, o=0.19, y=0.0, h=0.0, p=0.0, w=5.0, g=1.0, t=0.0, k=6.0, tan="f"),
               K(1.5, h=0.07, y=0.10, o=0.21, p=8.0, g=0.0),
               K(3.5, h=0.0, y=0.27, o=0.25, p=30.0, g=1.0, tan="f"),                   # heel tap: forward and out
               K(6, h=0.06, y=0.06, o=0.22, p=0.0, g=0.0), K(7.7, h=0.015, y=-0.17, o=0.25, p=-30.0, g=1.0),
               K(8.5, h=0.0, y=-0.18, o=0.25, p=-30.0, t=-12.0, g=1.0, tan="f"),       # toe tap: back and out
               K(9.3, h=0.0, y=-0.18, o=0.25, p=-30.0, g=1.0, tan="f"),
               K(10.5, h=0.035, y=-0.04, o=0.20, p=-6.0, t=-2.0, g=0.0),
               K(12.5, h=0.0, y=0.0, o=0.19, p=0.0, t=0.0, g=1.0, tan="f"),
               K(28, p=0.0, g=1.0, k=6.0, tan="f"), K(30, p=-18.0, g=1.0, k=20.0),            # knee pop L ON b3
               K(33, p=0.0, g=1.0, k=8.0, tan="f"), K(37.5, k=18.0), K(41, k=8.0),
               K(71.5, h=0.0, y=0.0, p=0.0, g=1.0, tan="f"),
               K(73.3, h=0.11, y=0.10, p=6.0, t=0.0, g=0.0), K(75, h=0.21, y=0.18, p=-18.0, t=-8.0, k=14.0, tan="f"),   # knee up L (b6)
               K(80, h=0.20, y=0.17, p=-16.0), K(83, h=0.21, y=0.18, tan="f"),
               K(86.5, h=0.0, y=0.0, p=0.0, t=0.0, g=1.0, k=6.0, tan="f"),
               K(89, h=0.0, o=0.19, y=0.0, w=5.0, p=0.0, g=1.0, tan="f"),
               ] + _tuck(90.5, 96.0, 0.13, y=0.04, o=0.08, lead=-0.3)[1:] + _tuck(98.5, 104.0, 0.16, y=0.05, o=0.24, lead=0.2, o0=0.08)[1:] + [
               K(104, k=14.0, w=12.0),                                                   # the lunge's support
               K(116.0, h=0.0, o=0.24, y=0.0, p=0.0, g=1.0, k=8.0, tan="f"),
               K(117.2, h=0.025, o=0.21, g=0.0), K(118.4, h=0.0, o=0.19, y=0.0, k=6.0, w=5.0, g=1.0, tan="f"),
               K(120, h=0.0, o=0.19, y=0.0, k=6.0, w=5.0)],
         "R": [K(0, o=0.19, y=0.0, h=0.0, p=0.0, w=5.0, g=1.0, t=0.0, k=6.0, tan="f"),
               K(15, h=0.0, y=0.0, p=0.0, g=1.0, tan="f"),
               K(16.5, h=0.07, y=0.10, o=0.21, p=8.0, g=0.0),
               K(18.5, h=0.0, y=0.27, o=0.25, p=30.0, g=1.0, tan="f"),
               K(21, h=0.06, y=0.06, o=0.22, p=0.0, g=0.0), K(22.7, h=0.015, y=-0.17, o=0.25, p=-30.0, g=1.0),
               K(23.5, h=0.0, y=-0.18, o=0.25, p=-30.0, t=-12.0, g=1.0, tan="f"),
               K(24.3, h=0.0, y=-0.18, o=0.25, p=-30.0, g=1.0, tan="f"),
               K(25.5, h=0.035, y=-0.04, o=0.20, p=-6.0, t=-2.0, g=0.0),
               K(27.5, h=0.0, y=0.0, o=0.19, p=0.0, t=0.0, g=1.0, tan="f"),
               K(30, k=18.0), K(33, k=8.0),
               K(35.5, p=0.0, g=1.0, k=8.0, tan="f"), K(37.5, p=-18.0, g=1.0, k=20.0),         # knee pop R on the and
               K(40.5, p=0.0, g=1.0, k=8.0, tan="f"),
               K(58, h=0.0, y=0.0, p=0.0, g=1.0, tan="f"),
               K(60, h=0.13, y=0.11, p=6.0, g=0.0), K(62, h=0.34, y=0.22, p=-22.0, t=-10.0, k=16.0, tan="f"),   # FLAMINGO knee
               K(65, h=0.33, y=0.21), K(68, h=0.34, y=0.22),
               K(69.5, h=0.10, y=0.07, p=0.0, t=0.0), K(71.0, h=0.0, y=0.0, p=0.0, g=1.0, k=6.0, tan="f"),
               K(71.0, w=5.0), K(89, h=0.0, o=0.19, y=0.0, w=5.0, p=0.0, g=1.0, tan="f"),
               ] + _tuck(90.5, 96.0, 0.15, y=0.05, o=0.30, lead=0.3)[1:] + [
               # hop L: R pushes off, tucks, and reaches out to the side to land straight on a pointed toe
               K(98.5, h=0.0, p=-22.0, t=-8.0, g=1.0, y=0.0, o=0.30, w=5.0, tan="f"),
               K(99.5, h=0.05, p=-10.0, g=0.5),
               K(101.5, h=0.12, y=0.03, o=0.36, p=4.0, t=4.0, g=0.0),
               K(104.5, h=0.075, o=0.505, y=0.04, p=-26.0, t=-12.0, w=28.0, g=0.0, k=6.0),
               K(105.5, h=0.0, o=0.52, y=0.04, p=-30.0, t=-14.0, w=30.0, g=1.0, tan="f"),  # lands straight, toe pointed
               K(111.5, h=0.0, o=0.52, y=0.04, p=-30.0, t=-14.0, w=30.0, g=1.0, tan="f"),
               K(113, h=0.05, o=0.36, y=0.02, p=-6.0, t=0.0, g=0.0),
               K(115, h=0.0, o=0.19, y=0.0, p=0.0, w=5.0, k=6.0, g=1.0, tan="f"),
               K(120, h=0.0, o=0.19, y=0.0, k=6.0, w=5.0)],
     })


# ---------------------------------------------------------------- swim (1.0 s loop, body-frame legs)
def _paddle(off):
    """Dog-paddle leg in the BODY frame: 5 f power sweep down/back under the chest (the fast beat: 25 cm in 5 f),
    10 f recovery (knee draws up below the face, foot glides forward and up to the reach).  Compact: the leg never straightens below the body (power end
    stays >= 10 cm up and >= 5 cm forward in the body frame)."""
    rows = []
    for c in (0.0, 15.0):
        f = (off + c) % 30.0

        def at(df):
            return (f + df) % 30.0
        # (the recovering knee stays below the cube's bottom edge: eyes and mouth clear above the waterline)
        rows += [K(at(0.0), o=0.20, y=0.33, h=0.225, p=8.0, t=-6.0),           # reach: highest, most forward
                 K(at(2.5), o=0.215, y=0.18, h=0.12, p=-20.0, t=12.0),      # POWER: 5 f down/back sweep
                 K(at(5.0), o=0.225, y=0.06, h=0.08, p=-34.0, t=16.0),       # power end, under the chest
                 K(at(8.0), o=0.215, y=0.09, h=0.14, p=-12.0, t=-8.0),       # recovery (10 f): knee draws up
                 K(at(11.5), o=0.205, y=0.23, h=0.205, p=6.0, t=-10.0)]      # foot glides forward to the reach
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
        seated = False
        if clip.seat and clip.seat[0] - 1e-6 <= t <= clip.seat[1] + 1e-6:
            rv = P["root"]
            zc = rig.seat_z(rv)
            if rv["z"] + rv["z2"] < zc + 1e-4:
                rv["z"] = zc - rv["z2"]
                seated = True
        spin = ev.spin_at(t, P)
        poses, diag = rig.solve(P, t, spin)
        diag["seated"] = seated
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


def knee_metrics(diag, s):
    """Knee apex (offset of the knee from the hip-ankle line) in the BODY frame: forward angle (deg, + = toward
    the face, measured from the body's up axis: atan2(y, z)), outward splay (deg) and the raw armature-space
    forward component (m)."""
    d = diag["legs"][s]
    o = d["koff_body"]
    n = o.length
    if n < 1e-3:
        return None
    sx = SIDE_X[s]
    fwd = math.degrees(math.atan2(o.y, o.z))
    out = math.degrees(math.atan2(sx * o.x, math.hypot(o.y, o.z)))
    return dict(fwd_deg=fwd, y_body=o.y / n, out_deg=out, y_arm=d["koff"].y, len=n)


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
    flex_jump_f = None
    lat_jump = 0.0
    prev = None
    max_flex = 0.0
    kb_min, kb_min_f, ko_max, ko_max_f, karm_min, karm_min_f = 1e9, None, -1e9, None, 1e9, None
    arm_bad = []
    mesh = rig.mesh
    m_sole, m_sole_f, m_toe, m_toe_f, m_body, m_body_f = 1e9, None, 1e9, None, 1e9, None
    leg_in, leg_in_f, raise_max, toe_fix_max, toe_fix_n = -1e9, None, 0.0, 0.0, 0
    toe_bad = []
    # per-frame rotation step of every bone's LOCAL rotation (relative to its parent; the root relative to its
    # rest): catches single-frame flips / pops that position metrics miss (e.g. a toe swinging round)
    rot_step = {}
    prev_local = None
    thigh_in = -1e9
    seat_gap = []
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
            km = knee_metrics(diag, s)
            if km is not None:
                if km["y_body"] < kb_min:
                    kb_min, kb_min_f = km["y_body"], (f, s)
                if km["out_deg"] > ko_max:
                    ko_max, ko_max_f = km["out_deg"], (f, s)
                if km["y_arm"] < karm_min:
                    karm_min, karm_min_f = km["y_arm"], (f, s)
                # armature-space check where it is meaningful: an upright-ish leg (hip-ankle line > 45 deg from
                # horizontal) on a body facing +Y (|yaw| < 45 deg) must also bend toward +Y in armature space
                line = (d["A"] - d["H"]).normalized()
                yaw = math.degrees(math.atan2(-d["fwd"].x, d["fwd"].y))
                if abs(line.z) > 0.707 and abs(yaw) < 45.0 and km["y_arm"] < -0.003:
                    arm_bad.append((f, s, round(km["y_arm"] * 1000, 1)))
            max_flex = max(max_flex, d["flex"])
            raise_max = max(raise_max, d["raise_"])
            if abs(d["toe_fix"]) > 1e-6:
                toe_fix_n += 1
                toe_fix_max = max(toe_fix_max, d["toe_fix"])
            if not d.get("toe_ok", True):
                toe_bad.append((f, s))
            if prev is not None:
                p = prev["legs"][s]
                if abs(d["flex"] - p["flex"]) > flex_jump:
                    flex_jump, flex_jump_f = abs(d["flex"] - p["flex"]), (f, s)
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
        if mesh is not None:
            for s in "LR":
                mats = mesh.leg_mats(s, poses)
                zs = mesh.skin(mesh.parts[s]["foot"], mats)[:, 2].min() - rig.ground_z
                zt = mesh.skin(mesh.parts[s]["toe"], mats)[:, 2].min() - rig.ground_z
                if zs < m_sole:
                    m_sole, m_sole_f = zs, (f, s)
                if zt < m_toe:
                    m_toe, m_toe_f = zt, (f, s)
                li = mesh.leg_into_body(poses, s)
                if li > leg_in:
                    leg_in, leg_in_f = li, (f, s)
                thigh_in = max(thigh_in, mesh.leg_into_body(poses, s, "thigh"))
            zb = mesh.body_min_z(diag["R"]) + diag["root"].translation.z - rig.ground_z
            if zb < m_body:
                m_body, m_body_f = zb, f
            if diag.get("seated"):
                seat_gap.append(zb)
        clip_depth = max(clip_depth, body_clearance(rig, diag))
        prev = diag
        loc = {}
        for name in rig.order:
            par = rig.parent[name]
            base = rig.rest[name] if par is None else poses[par] @ rig.rest_inv[par] @ rig.rest[name]
            loc[name] = (base.inverted() @ poses[name]).to_quaternion()
        if prev_local is not None:
            for name, q in loc.items():
                ang = math.degrees(prev_local[name].rotation_difference(q).angle)
                ang = min(ang, 360.0 - ang)
                if ang > rot_step.get(name, (0.0, None))[0]:
                    rot_step[name] = (ang, f)
        prev_local = loc
    # dead holds: longest run of consecutive frame steps where no tracked point (root corners, knee / ankle heads,
    # toe tips) moves 1 mm or more -- the grammar allows at most 6 f without visible change (footage 4.3)
    pts = []
    for P, poses, diag in frames:
        D = diag["root"] @ rig.rest_inv[ROOT]
        q = [D @ (rig.head0 + Vector((sx * BODY_HALF[0], 0.0, 0.0))) for sx in (-1, 1)]
        for s in "LR":
            d = diag["legs"][s]
            q += [d["K"], d["A"], d["toe_tip"]]
        pts.append(q)
    run, hold_max, hold_at = 0, 0, None
    for f in range(1, len(pts)):
        mv = max((a - b).length for a, b in zip(pts[f], pts[f - 1]))
        run = run + 1 if mv < 0.001 else 0
        if run > hold_max:
            hold_max, hold_at = run, f - run
    rep = dict(frames=N, seconds=round(clip.seconds, 4), loop=clip.loop,
               slip_mm={s: round(v * 1000, 2) for s, v in slip.items()},
               penetration_mm=round(pen * 1000, 2), overreach_mm=round(over * 1000, 2),
               knee_forward_min=round(knee_fwd_min, 3), knee_pole_min=round(knee_pole_min, 3),
               # strict knee direction: the apex in the BODY frame must never point behind the body's up axis
               knee_apex_body_y_min=round(kb_min, 3), knee_apex_body_y_min_at=kb_min_f,
               knee_apex_out_max_deg=round(ko_max, 1), knee_apex_out_max_at=ko_max_f,
               knee_apex_arm_y_min_mm=round(karm_min * 1000, 1), knee_apex_arm_y_min_at=karm_min_f,
               knee_apex_arm_violations=arm_bad[:20],
               knee_flex_max_deg=round(max_flex, 1), knee_flex_jump_deg_per_f=round(flex_jump, 1),
               knee_flex_jump_at=flex_jump_f,
               knee_plane_jump_deg_per_f=round(lat_jump, 1), body_clip_mm=round(max(0.0, clip_depth) * 1000, 1),
               rot_step_max_deg={n: [round(v[0], 1), v[1]] for n, v in rot_step.items()},
               dead_hold_max_f=hold_max, dead_hold_at=hold_at)
    if mesh is not None:
        rep["mesh"] = {"sole_min_mm": round(m_sole * 1000, 1), "sole_min_at": m_sole_f,
                       "toe_min_mm": round(m_toe * 1000, 1), "toe_min_at": m_toe_f,
                       "body_min_mm": round(m_body * 1000, 1), "body_min_at": m_body_f,
                       "leg_into_body_mm": round(max(0.0, leg_in) * 1000, 1), "leg_into_body_at": leg_in_f,
                       "proximal_thigh_into_body_mm": round(max(0.0, thigh_in) * 1000, 1),
                       "contact_raise_max_mm": round(raise_max * 1000, 1),
                       "toe_conform_frames": toe_fix_n, "toe_conform_max_deg": round(toe_fix_max, 1),
                       "toe_conform_unresolved": toe_bad[:20],
                       "toe_pad_check": "skipped: toe pad modelled backward" if any(mesh.toe_backward.values())
                       else "mesh"}
        if seat_gap:
            # bottom-to-floor gap on the frames where the seat contact holds the body (min, max)
            rep["mesh"]["seat_gap_mm"] = [round(min(seat_gap) * 1000, 2), round(max(seat_gap) * 1000, 2)]
            rep["mesh"]["seated_frames"] = len(seat_gap)
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


def _hull(pts):
    pts = sorted(set((round(p[0], 6), round(p[1], 6)) for p in pts))
    if len(pts) <= 2:
        return pts

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lo, up = [], []
    for p in pts:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], p) <= 0:
            lo.pop()
        lo.append(p)
    for p in reversed(pts):
        while len(up) >= 2 and cross(up[-2], up[-1], p) <= 0:
            up.pop()
        up.append(p)
    return lo[:-1] + up[:-1]


def _outside(h, q):
    """Distance (m) of point q outside the convex polygon h (0 when inside)."""
    def seg(a, b):
        ax, ay = b[0] - a[0], b[1] - a[1]
        L2 = ax * ax + ay * ay
        t = 0.0 if L2 < 1e-12 else max(0.0, min(1.0, ((q[0] - a[0]) * ax + (q[1] - a[1]) * ay) / L2))
        return math.hypot(q[0] - a[0] - t * ax, q[1] - a[1] - t * ay)
    if len(h) == 1:
        return math.hypot(q[0] - h[0][0], q[1] - h[0][1])
    if len(h) == 2:
        return seg(h[0], h[1])
    inside = all((b[0] - a[0]) * (q[1] - a[1]) - (b[1] - a[1]) * (q[0] - a[0]) >= 0.0
                 for a, b in zip(h, h[1:] + h[:1]))
    if inside:
        return 0.0
    return min(seg(a, b) for a, b in zip(h, h[1:] + h[:1]))


def balance_metrics(rig, frames):
    """Unsided clips: balance of the body centre over the support polygon (convex hull of the skinned sole and
    toe-pad vertices within 6 mm of the floor) while the bottom is off the ground, both
    static (COM) and dynamic (extrapolated COM, XCoM = COM + v / omega0 with omega0 = sqrt(g / COM height):
    a body moving toward its support may be outside it as long as its XCoM is inside), plus the downward
    acceleration of the carried body and the bottom touchdown speed (sit)."""
    worst, worst_f, xworst, xworst_f, bottoms, outside, cens = 0.0, None, 0.0, None, [], [], []
    hulls = []
    for f, (P, poses, diag) in enumerate(frames):
        cs, cen = body_points(rig, diag)
        if rig.mesh is not None:
            bottom = rig.mesh.body_min_z(diag["R"]) + diag["root"].translation.z - rig.ground_z
        else:
            bottom = min(p.z for p in cs) - rig.ground_z
        bottoms.append(bottom)
        cens.append(cen)
        pts = []
        if rig.mesh is not None:
            # support polygon = the skinned sole / toe-pad vertices within 6 mm of the floor
            for s in "LR":
                mats = rig.mesh.leg_mats(s, poses)
                for part in ("foot", "toe"):
                    v = rig.mesh.skin(rig.mesh.parts[s][part], mats)
                    g = v[v[:, 2] < rig.ground_z + 0.006]
                    pts += [(float(x), float(y)) for x, y in g[:, :2]]
        else:
            for s in "LR":
                d = diag["legs"][s]
                for key in ("heel", "ball", "toe_tip"):
                    if d[key].z - rig.ground_z < 0.006:
                        for e in (-0.045, 0.045):
                            pts.append((d[key].x + e, d[key].y))
        hulls.append(_hull(pts) if pts else None)
    for f, cen in enumerate(cens):
        h = hulls[f]
        if bottoms[f] <= 0.02 or not h:
            continue
        out = _outside(h, (cen.x, cen.y))
        if out > 0.03:
            outside.append((f, round(bottoms[f], 3), round(out * 1000)))
        if out > worst:
            worst, worst_f = out, f
        a, b = cens[max(0, f - 1)], cens[min(len(cens) - 1, f + 1)]
        dt = (min(len(cens) - 1, f + 1) - max(0, f - 1)) / FPS
        v = (b - a) / dt if dt > 0 else Vector()
        w0 = math.sqrt(9.81 / max(0.15, cen.z - rig.ground_z))
        xo = _outside(h, (cen.x + v.x / w0, cen.y + v.y / w0))
        if xo > xworst:
            xworst, xworst_f = xo, f
    rep = {"com_outside_support_max_mm": round(worst * 1000, 1), "com_outside_support_frame": worst_f,
           "xcom_outside_support_max_mm": round(xworst * 1000, 1), "xcom_outside_support_frame": xworst_f,
           # (frame, bottom height m, COM distance outside the support polygon mm) for every frame > 30 mm
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
    ap.add_argument("--no-guards", action="store_true", help="write the file even when a quality guard fails (debug)")
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
    rig.mesh = MeshModel(arm, rig)
    mesh_probe = {"verts": int(len(rig.mesh.h)), "body_verts": int(len(rig.mesh.body)),
                  "rest_sole_above_contract_floor_mm": round((rig.mesh.rest_sole - rig.ground_z) * 1000, 2),
                  "rest_body_bottom_below_root_m": round(-float(rig.mesh.rest_body_bottom), 4),
                  "body_bevel_m": round(float(rig.mesh.box["r"]), 4),
                  "toe_pad_median_y_in_toe_frame_m": {s: round(v, 4) for s, v in rig.mesh.toe_pad_y.items()},
                  "toe_mesh_backward": any(rig.mesh.toe_backward.values())}
    if mesh_probe["toe_mesh_backward"]:
        print("WARNING: the toe pad of %s is modelled BEHIND the ankle (toe-frame median y %r) while the toe bones "
              "point forward: the mesh toe conform and the toe-pad floor check are disabled for this input (authored "
              "toe curls are written unchanged).  Run the pipeline on the rebuilt mesh for game use." % (
                  args.inp, mesh_probe["toe_pad_median_y_in_toe_frame_m"]))

    only = set(x for x in args.only.split(",") if x)
    built = []
    report = {"input": os.path.abspath(args.inp), "output": os.path.abspath(args.out), "toe_flip": toe_report,
              "mesh_probe": mesh_probe,
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
            elif c.treadmill is None:
                rep["balance"] = balance_metrics(rig, frames)
            if c.seat:
                # authored seat descent per frame (m below the rest root height); the runtime can drive the
                # native seat_drop from this curve and subtract the body's actual drop from the visual root
                rep["seat_descent_m"] = [round(rig.head0.z - fr[2]["root"].translation.z, 4) for fr in frames]
                # root travel along the face direction (m, + = forward of the clip origin) per frame: the sit
                # family is authored in place (0 at both standing ends), so the native body never has to move
                rep["seat_travel_m"] = [round(fr[2]["root"].translation.y - rig.head0.y, 4) for fr in frames]
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
    report["guards"] = check_guards(report)
    if report["guards"]["failures"] and not args.no_guards:
        _print_report(dict(report, actions_written=len(built), roundtrip_max_mm=float("nan")))
        raise RuntimeError("quality guards failed:\n  " + "\n  ".join(report["guards"]["failures"]))
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


# per-frame local rotation step limits (deg/frame) -- catches single-frame flips (a toe swinging round, a knee-plane
# pop).  Whitelisted, deliberate fast beats: the wk_dance_a 360 deg hop-spin (root yaw ~58 deg/f mid-flight) and b5
# kick snap (knee 80 -> 6 deg over 2.8 f), and the wk_assemble mallet strike (the knee whips ~65 deg/f and the ankle
# snaps the foot from cocked to struck).
ROT_STEP_MAX = 45.0
ROT_STEP_WHITELIST = {("wk_dance_a", ROOT): 60.0,
                      ("wk_dance_a", "Bone.004"): 55.0, ("wk_dance_a", "Bone.006"): 55.0,     # the b5 kick snap
                      ("wk_assemble_L", "Bone.003"): 70.0, ("wk_assemble_R", "Bone.004"): 70.0,
                      ("wk_assemble_L", "Bone.005"): 90.0, ("wk_assemble_R", "Bone.006"): 90.0}
GUARD = dict(knee_apex_body_y_min=-0.002,     # knee apex never behind the body's up axis (normalised component)
             knee_apex_out_max_deg=30.0,      # outward splay of the knee plane (A18 / 5.1)
             leg_into_body_mm=1.0,            # knee / shin / foot vertices inside the cube
             sole_min_mm=-1.0, toe_min_mm=-1.0, body_min_mm=-1.0,   # nothing below the floor
             slip_mm=5.0, mirror_error_mm=0.05, loop_seam=1e-4,
             toe_conform_max_deg=TOE_CONFORM_MAX_DEG, rot_step_max_deg=ROT_STEP_MAX)


def check_guards(report):
    """Library-wide quality gates; any failure aborts the pipeline (unless --no-guards)."""
    fails = []
    for n, r in report["clips"].items():
        if r["knee_apex_body_y_min"] < GUARD["knee_apex_body_y_min"]:
            fails.append("%s: knee apex behind the body (body-frame y %.3f at %s)" % (
                n, r["knee_apex_body_y_min"], r["knee_apex_body_y_min_at"]))
        if r["knee_apex_arm_violations"]:
            fails.append("%s: upright leg bends away from +Y in armature space %s" % (n, r["knee_apex_arm_violations"][:3]))
        if r["knee_apex_out_max_deg"] > GUARD["knee_apex_out_max_deg"]:
            fails.append("%s: knee splay %.1f deg at %s" % (n, r["knee_apex_out_max_deg"], r["knee_apex_out_max_at"]))
        m = r.get("mesh")
        if m:
            if m["leg_into_body_mm"] > GUARD["leg_into_body_mm"]:
                fails.append("%s: leg %.1f mm inside the body at %s" % (n, m["leg_into_body_mm"], m["leg_into_body_at"]))
            for k in ("sole_min_mm", "toe_min_mm", "body_min_mm"):
                if k == "toe_min_mm" and m.get("toe_pad_check", "mesh") != "mesh":
                    continue
                if m[k] < GUARD[k]:
                    fails.append("%s: %s %.1f below the floor" % (n, k, m[k]))
            if m.get("toe_conform_unresolved"):
                fails.append("%s: toe pad below the floor even at +%.0f deg conform %s" % (
                    n, TOE_CONFORM_MAX_DEG, m["toe_conform_unresolved"][:3]))
            if m.get("toe_conform_max_deg", 0.0) > GUARD["toe_conform_max_deg"] + 1e-6:
                fails.append("%s: toe conform %.1f deg" % (n, m["toe_conform_max_deg"]))
        for b, (ang, f) in r.get("rot_step_max_deg", {}).items():
            lim = ROT_STEP_WHITELIST.get((n, b), GUARD["rot_step_max_deg"])
            if ang > lim:
                fails.append("%s: %s rotates %.1f deg in one frame (f%s, limit %.0f)" % (n, b, ang, f, lim))
        if max(r["slip_mm"].values()) > GUARD["slip_mm"]:
            fails.append("%s: support slip %s" % (n, r["slip_mm"]))
        if r.get("mirror_error_mm", 0.0) > GUARD["mirror_error_mm"]:
            fails.append("%s: L/R mirror error %.3f mm" % (n, r["mirror_error_mm"]))
        if r.get("loop_seam", 0.0) > GUARD["loop_seam"]:
            fails.append("%s: loop seam %.6f" % (n, r["loop_seam"]))
    return {"limits": GUARD, "failures": fails}


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
    if "mesh_probe" in rep:
        print("mesh probe:", json.dumps(rep["mesh_probe"]))
    hdr = "%-18s %4s %6s %4s %5s %5s %5s %5s %5s %5s %6s %5s %5s | %-21s | %s" % (
        "clip", "frm", "sec", "loop", "slipL", "slipR", "over", "kbody", "kout", "karm", "flexmx", "dflex", "bclip",
        "mesh sole toe body leg", "weight: lift plant accept@-3f min-airborne at-plant frames-after | balance")
    print(hdr)
    for n, r in rep["clips"].items():
        extra = ""
        w = r.get("weight")
        if w:
            extra = "w %2d %2d %.2f %.2f %.2f %d" % (w["lift_frame"], w["plant_frame"], w["shift_at_lift_minus3"],
                                                    w["shift_min_airborne"], w["shift_at_plant"], w["frames_after_plant"])
        b = r.get("balance")
        if b:
            extra = "b %.0fmm x%.0fmm %.2fg" % (b["com_outside_support_max_mm"], b["xcom_outside_support_max_mm"],
                                               b["root_down_accel_max_g"])
            if "bottom_touch_frame" in b:
                extra += " touch f%d @%.1fcm/f" % (b["bottom_touch_frame"], b["bottom_touch_speed_cm_per_f"])
        if "loop_seam" in r:
            extra += "  seam %.5f" % r["loop_seam"]
        if "mirror_error_mm" in r:
            extra += "  mirror %.3fmm" % r["mirror_error_mm"]
        m = r.get("mesh", {})
        ms = "%5.1f %5.1f %5.1f %4.1f" % (m.get("sole_min_mm", 0), m.get("toe_min_mm", 0), m.get("body_min_mm", 0),
                                          m.get("leg_into_body_mm", 0)) if m else ""
        print("%-18s %4d %6.3f %4s %5.2f %5.2f %5.1f %5.2f %5.1f %5.0f %6.1f %5.1f %5.1f | %-21s | %s" % (
            n, r["frames"], r["seconds"], "Y" if r["loop"] else "-", r["slip_mm"]["L"], r["slip_mm"]["R"],
            r["overreach_mm"], r["knee_apex_body_y_min"], r["knee_apex_out_max_deg"], r["knee_apex_arm_y_min_mm"],
            r["knee_flex_max_deg"], r["knee_flex_jump_deg_per_f"], r["body_clip_mm"], ms, extra))


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    main(argv)

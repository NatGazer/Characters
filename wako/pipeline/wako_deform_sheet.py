#!/usr/bin/env python3
"""Wako deformation sheet renderer (Cycles CPU) -- pipeline QA tool.

Poses the Wako rig in a fixed battery of deformation-critical poses and renders

* MAIN sheets: every pose from the side, front and front 3/4 (two poses per sheet), and
* CLOSE-UP sheets: the problem areas up close -- hip junction from below / rear 3/4 in
  the deep-flexion poses (tuck, seated V, ground-seated V, run swing, work lift), the
  knee at 145 deg from the exact side, the ankle at ~60 deg dorsiflexion, the toe at
  +45 / -45 deg and a +-40 deg hip twist (six panels per sheet),

with a neutral white matte material and a faint wireframe, composed into labelled JPEG
sheets (<= 1280x720).  Side close-ups use an exactly horizontal camera so the far leg
(posed symmetrically) hides behind the near one instead of peeking out as a second
outline.

Poses are built robustly: desired armature-space joint frames are computed from
anatomical angles (knees always bend FORWARD toward Blender +Y, the face side) and
written with ``pose_bone.matrix`` in hierarchy order, so the oddly rolled thigh bones
and mirrored lower-leg axes never matter.  Resulting knee positions are printed.

Usage::

    <blender-python> wako_deform_sheet.py -- BLEND OUT_DIR PREFIX [--label TEXT]
                         [--samples N] [--poses name,...] [--closeups name,...|none]
                         [--main-only] [--keep-panels DIR] [--views side,front,...]
                         [--battery closeup|problem] [--nowire]
                         [--export-godot JOB.json [--no-render]]
    python3 wako_deform_sheet.py compose JOB.json      # (internal) PIL composition step
    python3 wako_deform_sheet.py godot-compose GODOT_JOB.json PANEL_DIR OUT_DIR PREFIX LABEL

``--battery problem`` swaps the close-up battery for the PROBLEMS list (the review's
problem shots: level exact-side knees, the hip opening from below, toes +-45 standing
and lifted with both legs posed alike, ankles +-35, flat-sole crouches, rest toe) and
``--nowire`` hides the wireframe overlay so shading artefacts are not confused with
wire bunching at grazing angles.

``--export-godot`` writes the exact armature-space bone matrices and camera framing of
every pose/view (main and close-up), so ``godot_check/render_sheet.tscn`` can pose the
imported Skeleton3D identically (Blender (x, y, z) -> Godot (x, z, -y)) and capture the
same panels with the real game shader; ``godot-compose`` turns those captures into sheets.

The render step runs inside Blender's Python.  Label composition needs Pillow; if the
Blender interpreter has none, the script re-invokes itself with ``$WAKO_PIL_PYTHON``
(default ``python3``) for the ``compose`` step.
"""

import json
import math
import os
import subprocess
import sys
import tempfile


# --------------------------------------------------------------------------------------
# Pose battery.  Per leg: flex = hip flexion (+ thigh forward), abd = hip abduction
# (+ outward, about the body's forward axis), yaw = thigh spread about vertical
# (+ outward), twist = rotation about the thigh's own axis (+ toe outward), knee = knee
# flexion (+ knee forward / shin folds back), ankle = ankle (+ dorsiflexion, toe up),
# toe = toe curl (+ grip/down), flat = keep sole level.
# --------------------------------------------------------------------------------------
def leg(flex=0.0, abd=0.0, yaw=0.0, knee=0.0, ankle=0.0, toe=0.0, flat=False, twist=0.0):
    return {"flex": flex, "abd": abd, "yaw": yaw, "knee": knee, "ankle": ankle, "toe": toe,
            "flat": flat, "twist": twist}


POSES = [
    ("neutral", "rest pose", leg(), leg()),
    ("crouch30", "shallow forward knee 30 (hip 15, sole flat)", leg(15, knee=30, flat=True), leg(15, knee=30, flat=True)),
    ("crouch90", "deep forward knee 90 (hip 45, sole flat)", leg(45, knee=90, flat=True), leg(45, knee=90, flat=True)),
    ("crouch120", "deep forward knee 120 (hip 60, sole flat ~ ankle 60)", leg(60, knee=120, flat=True), leg(60, knee=120, flat=True)),
    ("tuck", "flip tuck: hip 110, knee 145, ankle -20, toe 25", leg(110, knee=145, ankle=-20, toe=25), leg(110, knee=145, ankle=-20, toe=25)),
    ("seatedV", "seated V: hip 80, spread 30, knee 100", leg(80, yaw=30, knee=100, ankle=10), leg(80, yaw=30, knee=100, ankle=10)),
    ("wide", "wide support: abduction 25, knee 15, sole flat", leg(8, abd=25, knee=15, flat=True), leg(8, abd=25, knee=15, flat=True)),
    ("worklift", "work-foot lift: L hip 90 knee 60 / R support", leg(90, knee=60, ankle=10, toe=20), leg(10, knee=20, flat=True)),
    ("runswing", "run: L hip -35 knee 45 / R hip 55 knee 70", leg(-35, knee=45, ankle=-25), leg(55, knee=70, ankle=5)),
    ("ankle", "ankle: L dorsi +35 / R plantar -35", leg(ankle=35), leg(ankle=-35)),
    ("toecurl", "toe: L grip curl +45 / R lift -45", leg(toe=45), leg(toe=-45)),
    ("footrest", "close-up: left foot at rest", leg(), leg()),
    ("footclose", "close-up: L toe grip +45, ankle +15", leg(ankle=15, toe=45), leg(toe=-45)),
    # extra poses used by the close-up battery
    ("groundV", "ground-seated V: hip 120, spread 30, knee 85", leg(120, yaw=30, knee=85, ankle=-5), leg(120, yaw=30, knee=85, ankle=-5)),
    ("toegrip", "lifted foot: L toe curl +45 / R toe lift -45", leg(90, knee=60, ankle=10, toe=45), leg(90, knee=60, ankle=10, toe=-45)),
    ("twist40", "hip twist: L +40 / R -40 about the thigh", leg(twist=40), leg(twist=-40)),
    # problem-shot poses: both legs posed the same, so an exact side camera shows one leg
    ("toe+45stand", "both toes curl +45, standing", leg(toe=45), leg(toe=45)),
    ("toe-45stand", "both toes lift -45, standing", leg(toe=-45), leg(toe=-45)),
    ("toe+45lift", "lifted feet (hip 90, knee 60, ankle 10), toes +45", leg(90, knee=60, ankle=10, toe=45),
     leg(90, knee=60, ankle=10, toe=45)),
    ("toe-45lift", "lifted feet (hip 90, knee 60, ankle 10), toes -45", leg(90, knee=60, ankle=10, toe=-45),
     leg(90, knee=60, ankle=10, toe=-45)),
    ("dorsi35", "both ankles dorsiflexed +35", leg(ankle=35), leg(ankle=35)),
    ("plantar35", "both ankles plantarflexed -35", leg(ankle=-35), leg(ankle=-35)),
]
MAIN_POSES = ["neutral", "crouch30", "crouch90", "crouch120", "tuck", "seatedV", "wide", "worklift",
              "runswing", "ankle", "toecurl", "footrest", "footclose"]

VIEWS = [  # name, view direction (camera looks along it)
    ("side", (1.0, 0.0, -0.12)),
    ("front", (0.0, -1.0, -0.12)),
    ("3/4", (0.62, -0.72, -0.30)),
]
EXTRA_VIEWS = {"rear3/4": (0.62, 0.72, -0.30), "below": (0.25, 0.35, 0.9)}

# Close-ups: (pose, shot, target, view direction, ortho scale, note).  Targets: hipL
# (left hip head lowered 12 cm, i.e. the junction), kneeL, ankleL, toeL, toeR, full.
SIDE_FLAT = (1.0, 0.0, 0.0)          # exact side: the symmetric far leg hides behind
SIDE_FLAT_R = (-1.0, 0.0, 0.0)
BELOW_REAR = (0.35, 0.55, 0.75)      # looking up at the junction from below and behind
BELOW_FRONT = (0.35, -0.55, 0.75)
REAR34 = (0.60, 0.75, -0.25)
FRONT34 = (0.62, -0.72, -0.30)
CLOSEUPS = [
    ("tuck", "hip below-rear", "hipL", BELOW_REAR, 0.60, "junction from below/behind"),
    ("tuck", "hip rear 3/4", "hipL", REAR34, 0.70, "junction, rear 3/4"),
    ("tuck", "knee side 145", "kneeL", SIDE_FLAT, 0.45, "knee 145 deg, exact side"),
    ("seatedV", "hip below-rear", "hipL", BELOW_REAR, 0.70, "junction from below/behind"),
    ("seatedV", "hip rear 3/4", "hipL", REAR34, 0.80, "junction, rear 3/4"),
    ("seatedV", "knee rear 3/4", "kneeL", REAR34, 0.50, "knee 100 deg"),
    ("groundV", "hip below-front", "hipL", BELOW_FRONT, 0.70, "hip 120: junction from below/front"),
    ("groundV", "hip below-rear", "hipL", BELOW_REAR, 0.70, "hip 120: junction from below/behind"),
    ("groundV", "full side", "full", SIDE_FLAT, 1.25, "hip 120 / knee 85, exact side"),
    ("runswing", "hip rear 3/4", "hipL", REAR34, 0.60, "L hip -35 / R hip 55"),
    ("worklift", "hip rear 3/4", "hipL", REAR34, 0.70, "L hip 90, junction"),
    ("worklift", "hip below-rear", "hipL", BELOW_REAR, 0.70, "L hip 90, junction"),
    ("crouch120", "ankle side 60", "ankleL", SIDE_FLAT, 0.35, "flat sole: ~60 deg dorsiflexion"),
    ("crouch120", "knee below-rear", "kneeL", BELOW_REAR, 0.50, "knee 120, crease"),
    ("crouch90", "knee side 90", "kneeL", SIDE_FLAT, 0.55, "knee 90, exact side"),
    ("toegrip", "toe L +45 side", "toeL", SIDE_FLAT, 0.30, "toe grip curl +45"),
    ("toegrip", "toe R -45 side", "toeR", SIDE_FLAT_R, 0.30, "toe lift -45"),
    ("toegrip", "toe L +45 front3/4", "toeL", (0.2, -1.0, -0.2), 0.30, "toe grip curl +45"),
    ("twist40", "front", "full", (0.0, -1.0, -0.1), 1.0, "hip twist +-40"),
    ("twist40", "hip front 3/4", "hipL", FRONT34, 0.50, "hip twist +40 (left)"),
    ("neutral", "knee side", "kneeL", SIDE_FLAT, 0.55, "rest knee profile"),
    ("neutral", "foot side", "ankleL", SIDE_FLAT, 0.35, "rest foot: toe on the face side"),
    ("neutral", "foot front 3/4", "ankleL", FRONT34, 0.35, "rest foot / toe"),
    ("neutral", "junction 3/4", "hipL", (0.62, -0.72, -0.08), 0.45, "rest junction"),
]
# Problem shots (rendered WITHOUT wireframe, --battery problem): the specific views the
# review asked for -- level exact-side knees, the hip opening from below, toes +-45
# standing and lifted with both legs posed alike, ankles +-35 and flat-sole crouches.
BELOW = (0.05, 0.10, 1.0)
PROBLEMS = [
    ("tuck", "knee side 145", "kneeL", SIDE_FLAT, 0.42, "level exact side"),
    ("tuck", "knee front 3/4", "kneeL", FRONT34, 0.45, "knee 145"),
    ("crouch120", "knee side 120", "kneeL", SIDE_FLAT, 0.45, "level exact side"),
    ("crouch90", "knee side 90", "kneeL", SIDE_FLAT, 0.48, "level exact side"),
    ("crouch90", "knee front 3/4", "kneeL", FRONT34, 0.50, "knee 90"),
    ("crouch120", "ankle side 60", "ankleL", SIDE_FLAT, 0.32, "flat sole ~ 60 deg dorsiflexion"),
    ("crouch90", "ankle side 45", "ankleL", SIDE_FLAT, 0.32, "flat sole ~ 45 deg dorsiflexion"),
    ("dorsi35", "ankle side +35", "ankleL", SIDE_FLAT, 0.32, "dorsiflexion +35"),
    ("plantar35", "ankle side -35", "ankleL", SIDE_FLAT, 0.32, "plantarflexion -35"),
    ("dorsi35", "ankle front 3/4", "ankleL", FRONT34, 0.34, "dorsiflexion +35"),
    ("tuck", "hip below", "hipL", BELOW, 0.60, "hip 110 from below"),
    ("tuck", "hip below-rear", "hipL", BELOW_REAR, 0.60, "hip 110 from below/behind"),
    ("seatedV", "hip below", "hipL", BELOW, 0.70, "hip 80 from below"),
    ("seatedV", "hip below-rear", "hipL", BELOW_REAR, 0.70, "hip 80 from below/behind"),
    ("groundV", "hip below", "hipL", BELOW, 0.70, "hip 120 (stress) from below"),
    ("groundV", "hip below-rear", "hipL", BELOW_REAR, 0.70, "hip 120 (stress) from below/behind"),
    ("toe+45stand", "toe side", "toeL", SIDE_FLAT, 0.28, "toe +45 standing"),
    ("toe-45stand", "toe side", "toeL", SIDE_FLAT, 0.28, "toe -45 standing"),
    ("toe+45lift", "toe side", "toeL", SIDE_FLAT, 0.28, "toe +45 lifted"),
    ("toe-45lift", "toe side", "toeL", SIDE_FLAT, 0.28, "toe -45 lifted"),
    ("toe+45lift", "toe front 3/4", "toeL", (0.2, -1.0, -0.2), 0.30, "toe +45 lifted"),
    ("toe-45lift", "toe front 3/4", "toeL", (0.2, -1.0, -0.2), 0.30, "toe -45 lifted"),
    ("neutral", "foot front", "ankleL", (0.0, -1.0, -0.15), 0.32, "rest toe from the front"),
    ("neutral", "foot front 3/4", "ankleL", FRONT34, 0.34, "rest toe, 3/4"),
]
PANEL = (426, 360)


# ======================================================================================
# Composition (plain python3 + Pillow)
# ======================================================================================
def compose(job_path):
    from PIL import Image, ImageDraw, ImageFont
    job = json.load(open(job_path))

    def font(size, bold=False):
        f = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else \
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
        return ImageFont.truetype(f, size) if os.path.exists(f) else ImageFont.load_default()

    f1, f2 = font(15, True), font(12)
    pw, ph = job["panel"]
    for sheet in job["sheets"]:
        cols = max(len(r["panels"]) for r in sheet["rows"])
        img = Image.new("RGB", (pw * cols, ph * len(sheet["rows"])), (30, 31, 34))
        for r, row in enumerate(sheet["rows"]):
            for c, panel in enumerate(row["panels"]):
                im = Image.open(panel["file"]).convert("RGB").resize((pw, ph))
                img.paste(im, (c * pw, r * ph))
                d = ImageDraw.Draw(img, "RGBA")
                d.rectangle([c * pw, r * ph, c * pw + pw - 1, r * ph + 38], fill=(0, 0, 0, 120))
                d.text((c * pw + 8, r * ph + 4), panel["title"], font=f1, fill=(255, 255, 255))
                d.text((c * pw + 8, r * ph + 22), panel["subtitle"], font=f2, fill=(215, 222, 230))
                d.rectangle([c * pw, r * ph, c * pw + pw - 1, r * ph + ph - 1], outline=(70, 72, 78))
        img.save(sheet["out"], quality=90)
        print("[wako_deform_sheet] wrote", sheet["out"], img.size)


def sheet_layout(main_rows, close_panels, out_dir, prefix, close_tag="closeup"):
    """Main sheets: 2 poses x 3 views; close-up / problem sheets: 2 rows x 3 panels."""
    sheets = []
    for k in range(0, len(main_rows), 2):
        rows = main_rows[k:k + 2]
        sheets.append({"out": os.path.join(out_dir, f"{prefix}_{k // 2 + 1:02d}_{'_'.join(r['name'] for r in rows)}.jpg"),
                       "rows": rows})
    for k in range(0, len(close_panels), 6):
        chunk = close_panels[k:k + 6]
        rows = [{"name": "", "panels": chunk[i:i + 3]} for i in range(0, len(chunk), 3)]
        poses = []
        for p in chunk:
            if p["pose"] not in poses:
                poses.append(p["pose"])
        tag = "_".join(poses).replace("+", "p").replace("-", "m")
        stem = prefix if prefix.endswith("_" + close_tag) else f"{prefix}_{close_tag}"
        sheets.append({"out": os.path.join(out_dir, f"{stem}_{k // 6 + 1:02d}_{tag}.jpg"),
                       "rows": rows})
    return sheets


# ======================================================================================
# Rendering (Blender)
# ======================================================================================
def render_main(argv):
    import bpy
    from mathutils import Matrix, Vector

    blend, out_dir, prefix = argv[:3]
    opts = {"label": prefix.upper(), "samples": 24, "poses": None, "closeups": None, "keep": None,
            "godot": None, "no_render": False, "main_only": False, "nowire": False, "battery": "closeup"}
    i = 3
    while i < len(argv):
        k = argv[i]
        if k in ("--no-render", "--main-only", "--nowire"):
            opts[k[2:].replace("-", "_")] = True
            i += 1
            continue
        v = argv[i + 1]
        if k == "--label":
            opts["label"] = v
        elif k == "--samples":
            opts["samples"] = int(v)
        elif k == "--poses":
            opts["poses"] = v.split(",")
        elif k == "--closeups":
            opts["closeups"] = [] if v == "none" else v.split(",")
        elif k == "--battery":
            opts["battery"] = v
        elif k == "--keep-panels":
            opts["keep"] = v
        elif k == "--export-godot":
            opts["godot"] = v
        elif k == "--views":
            allv = dict(VIEWS, **EXTRA_VIEWS)
            VIEWS[:] = [(n, allv[n]) for n in v.split(",")]
        i += 2
    bpy.ops.wm.open_mainfile(filepath=os.path.abspath(blend))
    scn = bpy.context.scene
    arm = bpy.data.objects["wako_art"]
    ob = bpy.data.objects["wakoMesh"]
    # Animation would overwrite the pose on every depsgraph update: drop it (file not saved).
    arm.animation_data_clear()
    for pb in arm.pose.bones:
        pb.matrix_basis = Matrix.Identity(4)
    bpy.context.view_layer.update()

    # ---------------------------------------------------------------- look
    for o in list(scn.objects):
        if o.type in ("CAMERA", "LIGHT") or o.name.startswith("sheet_"):
            bpy.data.objects.remove(o)

    def matte(name, rgb, rough):
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        p = m.node_tree.nodes["Principled BSDF"]
        p.inputs["Base Color"].default_value = (*rgb, 1)
        p.inputs["Roughness"].default_value = rough
        return m

    # neutral white matte so the geometry reads; the real quad edges are drawn by a
    # copy of the skinned mesh with a Wireframe modifier after its Armature modifier
    white = matte("sheet_white", (0.80, 0.80, 0.80), 0.55)
    for slot in ob.material_slots:
        slot.link = "OBJECT"
        slot.material = white
    wire_ob = ob.copy()
    wire_ob.name = "sheet_wire"
    scn.collection.objects.link(wire_ob)
    wire_ob.hide_render = opts["nowire"]
    wire_mod = wire_ob.modifiers.new("sheet_wire", "WIREFRAME")
    wire_mod.offset = 1.0
    wire_mod.use_replace = True
    wire_mod.use_even_offset = True
    wire_ob.material_slots[0].link = "OBJECT"
    wire_ob.material_slots[0].material = matte("sheet_wire", (0.22, 0.25, 0.30), 0.8)
    ground_me = bpy.data.meshes.new("sheet_ground")
    s = 4.0
    ground_me.from_pydata([(-s, -s, 0), (s, -s, 0), (s, s, 0), (-s, s, 0)], [], [(0, 1, 2, 3)])
    ground = bpy.data.objects.new("sheet_ground", ground_me)
    ground.location.z = -0.0076
    scn.collection.objects.link(ground)
    gm = bpy.data.materials.new("sheet_ground")
    gm.use_nodes = True
    gm.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.20, 0.21, 0.23, 1)
    gm.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.9
    ground_me.materials.append(gm)

    def sun(name, toward, energy):
        ld = bpy.data.lights.new(name, "SUN")
        ld.energy = energy
        ld.angle = math.radians(8)
        lo = bpy.data.objects.new(name, ld)
        lo.rotation_euler = Vector(toward).normalized().to_track_quat("-Z", "Y").to_euler()
        scn.collection.objects.link(lo)
        return lo

    sun("sheet_key", (0.8, -1.0, -1.3), 3.2)
    sun("sheet_rim", (-0.6, 1.0, -0.5), 1.4)
    sun("sheet_fill", (-1.0, -0.3, -0.2), 0.6)
    under = sun("sheet_under", (0.2, 0.3, 1.0), 0.6)   # only for views from below
    scn.world = scn.world or bpy.data.worlds.new("sheet_world")
    scn.world.use_nodes = True
    bg = scn.world.node_tree.nodes.get("Background")
    bg.inputs[0].default_value = (0.42, 0.45, 0.50, 1)
    bg.inputs[1].default_value = 0.55
    cam_data = bpy.data.cameras.new("sheet_cam")
    cam_data.type = "ORTHO"
    cam = bpy.data.objects.new("sheet_cam", cam_data)
    scn.collection.objects.link(cam)
    scn.camera = cam
    scn.render.engine = "CYCLES"
    scn.cycles.device = "CPU"
    scn.cycles.samples = opts["samples"]
    scn.cycles.use_denoising = True
    try:
        scn.cycles.denoiser = "OPENIMAGEDENOISE"
    except TypeError:
        pass
    scn.cycles.max_bounces = 4
    scn.render.resolution_x, scn.render.resolution_y = PANEL
    scn.render.resolution_percentage = 100
    scn.render.film_transparent = False
    scn.view_settings.view_transform = "Standard"
    scn.render.image_settings.file_format = "PNG"

    # ---------------------------------------------------------------- posing
    bones = {b.name: b for b in arm.data.bones}
    chains = {-1: ("Bone.001", "Bone.003", "Bone.005", "toe.L"),
              +1: ("Bone.002", "Bone.004", "Bone.006", "toe.R")}

    def rx(d):
        return Matrix.Rotation(math.radians(d), 3, "X")

    def ry(d):
        return Matrix.Rotation(math.radians(d), 3, "Y")

    def rz(d):
        return Matrix.Rotation(math.radians(d), 3, "Z")

    # +toe curls the toe TIP down whichever way the toe bone points: the rebuilt rig's
    # toes point forward (+Y), the original rig's backward (-Y), so the sense flips.
    toe_dir = {side: 1.0 if (bones[chains[side][3]].tail_local - bones[chains[side][3]].head_local).y > 0 else -1.0
               for side in (-1, +1)}

    def leg_frames(side, p):
        out_sign = 1.0 if side < 0 else -1.0  # +abd/+yaw/+twist move the leg/toe outward
        r_leg = rz(out_sign * p["yaw"]) @ ry(out_sign * p["abd"]) @ rx(p["flex"]) @ rz(out_sign * p["twist"])
        r_shin = r_leg @ rx(-p["knee"])
        r_foot = Matrix.Identity(3) if p["flat"] else r_shin @ rx(p["ankle"])
        if p["flat"] and p["ankle"]:
            r_foot = rx(p["ankle"])
        r_toe = r_foot @ rx(-p["toe"] * toe_dir[side])
        return [r_leg, r_shin, r_foot, r_toe]

    def apply_pose(spec_l, spec_r):
        for pb in arm.pose.bones:
            pb.matrix_basis = Matrix.Identity(4)
        bpy.context.view_layer.update()
        knees = {}
        for side, spec in ((-1, spec_l), (+1, spec_r)):
            names = chains[side]
            frames = leg_frames(side, spec)
            rest = [bones[n].matrix_local for n in names]
            heads = [r.translation.copy() for r in rest]
            new_heads = [heads[0]]
            for k in range(1, 4):
                new_heads.append(new_heads[k - 1] + frames[k - 1] @ (heads[k] - heads[k - 1]))
            for k, n in enumerate(names):
                m = frames[k].to_4x4() @ rest[k].to_3x3().to_4x4()
                m.translation = new_heads[k]
                arm.pose.bones[n].matrix = m
                bpy.context.view_layer.update()
            knees[names[1]] = tuple(round(x, 3) for x in arm.pose.bones[names[1]].head)
        return knees

    def bone_world(name):
        return arm.matrix_world @ arm.pose.bones[name].head

    def target_point(tgt):
        if tgt == "hipL":
            return bone_world("Bone.001") + Vector((0, 0, -0.12))
        if tgt == "kneeL":
            return bone_world("Bone.003")
        if tgt == "ankleL":
            return bone_world("Bone.005") + Vector((0, 0.03, -0.03))
        if tgt == "toeL":
            return bone_world("toe.L")
        if tgt == "toeR":
            return bone_world("toe.R")
        pts = [bone_world(n) for n in ("Bone.001", "Bone.002", "Bone.003", "Bone.004", "Bone.005", "Bone.006")]
        return sum(pts, Vector()) / len(pts) + Vector((0, 0, 0.05))

    # ---------------------------------------------------------------- framing
    rest_world = [ob.matrix_world @ v.co for v in ob.data.vertices]
    frame_sets = {
        "full": [i for i, p in enumerate(rest_world) if p.z < 0.98],
        "left_foot": [i for i, p in enumerate(rest_world) if p.z < 0.24 and p.x < 0],
    }

    last_forward = [Vector((0, 0, -1))]

    def place_camera(view_dir, centre, scale):
        f = Vector(view_dir).normalized()
        last_forward[0] = f
        cam_data.ortho_scale = scale
        cam.location = centre - f * 6.0
        cam.rotation_euler = f.to_track_quat("-Z", "Y").to_euler()
        cam_data.clip_end = 20.0
        wire_mod.thickness = scale / PANEL[0] * 0.75
        ground.hide_render = f.z > 0.05          # looking up: the floor would block the view
        under.hide_render = f.z <= 0.05
        return f

    def frame(view_dir, set_name):
        dg = bpy.context.evaluated_depsgraph_get()
        oe = ob.evaluated_get(dg)
        me = oe.to_mesh()
        pts = [oe.matrix_world @ me.vertices[i].co for i in frame_sets[set_name]]
        oe.to_mesh_clear()
        f = Vector(view_dir).normalized()
        r = f.cross(Vector((0, 0, 1))).normalized()
        u = r.cross(f)
        xs = [p.dot(r) for p in pts]
        ys = [p.dot(u) for p in pts]
        cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
        w, h = max(xs) - min(xs), max(ys) - min(ys)
        aspect = PANEL[0] / PANEL[1]
        scale = max(w, h * aspect) * 1.14 + 0.04
        cy += scale / aspect * 0.07          # leave room for the label bar at the top
        place_camera(view_dir, r * cx + u * cy, scale)

    def shot(path):
        if not opts["no_render"]:
            scn.render.filepath = path
            bpy.ops.render.render(write_still=True)

    def godot_view(fname, vname):
        return {"file": fname, "view": vname, "location": list(cam.location),
                "forward": list(last_forward[0]),   # (cam.matrix_world is stale until a depsgraph update)
                "ortho_scale": cam_data.ortho_scale}

    # ---------------------------------------------------------------- render loop
    tmp = opts["keep"] or tempfile.mkdtemp(prefix="wako_sheet_")
    os.makedirs(tmp, exist_ok=True)
    os.makedirs(out_dir, exist_ok=True)
    pose_by_name = {p[0]: p for p in POSES}
    main = [pose_by_name[n] for n in MAIN_POSES if opts["poses"] is None or n in opts["poses"]]
    battery = PROBLEMS if opts["battery"] == "problem" else CLOSEUPS
    closeups = [] if opts["main_only"] else [c for c in battery
                                             if opts["closeups"] is None or c[0] in opts["closeups"]]
    main_rows, close_panels = [], []
    godot_job = {"poses": [], "battery": opts["battery"]}
    for name, desc, spec_l, spec_r in main:
        knees = apply_pose(spec_l, spec_r)
        print(f"[wako_deform_sheet] pose {name}: knee heads (armature space) {knees}", flush=True)
        panels = []
        gpose = {"name": name, "desc": desc, "views": [],
                 "bones": {pb.name: [list(r) for r in pb.matrix] for pb in arm.pose.bones}}
        for vname, vdir in VIEWS:
            frame(vdir, "left_foot" if name.startswith("foot") else "full")
            fname = f"{prefix}_{name}_{vname.replace('/', '')}.png"
            gpose["views"].append(godot_view(fname, vname))
            shot(os.path.join(tmp, fname))
            panels.append({"file": os.path.join(tmp, fname), "title": f"{opts['label']}  {name}  [{vname}]",
                           "subtitle": desc})
        main_rows.append({"name": name, "panels": panels})
        godot_job["poses"].append(gpose)
    for pname in dict.fromkeys(c[0] for c in closeups):
        _, desc, spec_l, spec_r = pose_by_name[pname]
        knees = apply_pose(spec_l, spec_r)
        print(f"[wako_deform_sheet] close-up pose {pname}: knee heads {knees}", flush=True)
        gpose = {"name": "cu_" + pname, "desc": desc, "views": [],
                 "bones": {pb.name: [list(r) for r in pb.matrix] for pb in arm.pose.bones}}
        for _, sname, tgt, vdir, scale, note in [c for c in closeups if c[0] == pname]:
            place_camera(vdir, target_point(tgt), scale)
            fname = f"{prefix}_cu_{pname}_{sname.replace(' ', '_').replace('/', '')}.png"
            gpose["views"].append(godot_view(fname, sname))
            shot(os.path.join(tmp, fname))
            close_panels.append({"file": os.path.join(tmp, fname), "pose": pname,
                                 "title": f"{opts['label']}  {pname}  [{sname}]", "subtitle": f"{note}; {desc}"})
        godot_job["poses"].append(gpose)
    if opts["godot"]:
        with open(opts["godot"], "w") as fh:
            json.dump(godot_job, fh)
    if opts["no_render"]:
        return
    tag = "problem" if opts["battery"] == "problem" else "closeup"
    job = {"panel": PANEL, "sheets": sheet_layout(main_rows, close_panels, out_dir, prefix, tag)}
    job_path = os.path.join(tmp, f"{prefix}_job.json")
    with open(job_path, "w") as fh:
        json.dump(job, fh, indent=1)
    try:
        import PIL  # noqa: F401
        compose(job_path)
    except ImportError:
        py = os.environ.get("WAKO_PIL_PYTHON", "python3")
        subprocess.run([py, os.path.abspath(__file__), "compose", job_path], check=True)


def godot_compose(job_path, panel_dir, out_dir, prefix, label):
    """Compose sheets from the PNGs written by the Godot render scene for an exported job."""
    gjob = json.load(open(job_path))
    os.makedirs(out_dir, exist_ok=True)
    main_rows, close_panels = [], []
    for p in gjob["poses"]:
        if p["name"].startswith("cu_"):
            for v in p["views"]:
                close_panels.append({"file": os.path.join(panel_dir, v["file"]), "pose": p["name"][3:],
                                     "title": f"{label}  {p['name'][3:]}  [{v['view']}]", "subtitle": p["desc"]})
        else:
            main_rows.append({"name": p["name"], "panels": [
                {"file": os.path.join(panel_dir, v["file"]), "title": f"{label}  {p['name']}  [{v['view']}]",
                 "subtitle": p["desc"]} for v in p["views"]]})
    tmp = os.path.join(panel_dir, f"{prefix}_compose.json")
    with open(tmp, "w") as fh:
        tag = "problem" if gjob.get("battery") == "problem" else "closeup"
        json.dump({"panel": PANEL, "sheets": sheet_layout(main_rows, close_panels, out_dir, prefix, tag)}, fh)
    compose(tmp)


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "compose":
        compose(sys.argv[2])
    elif len(sys.argv) > 2 and sys.argv[1] == "godot-compose":
        godot_compose(*sys.argv[2:7])
    else:
        args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
        render_main(args)

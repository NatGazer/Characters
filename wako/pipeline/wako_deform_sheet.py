#!/usr/bin/env python3
"""Wako deformation sheet renderer (Cycles CPU) -- pipeline QA tool.

Poses the Wako rig in a fixed battery of deformation-critical poses and renders each
pose from the side, front and front 3/4 with a neutral white matte material and a
faint wireframe, then composes labelled JPEG sheets (<= 1280x720, two poses per sheet).

Poses are built robustly: desired armature-space joint frames are computed from
anatomical angles (knees always bend FORWARD toward Blender +Y, the face side) and
written with ``pose_bone.matrix`` in hierarchy order, so the oddly rolled thigh bones
and mirrored lower-leg axes never matter.  Resulting knee positions are printed.

Usage::

    <blender-python> wako_deform_sheet.py -- BLEND OUT_DIR PREFIX [--label TEXT]
                         [--samples N] [--poses name,name,...] [--keep-panels DIR]
    python3 wako_deform_sheet.py compose JOB.json      # (internal) PIL composition step

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
# (+ outward), knee = knee flexion (+ knee forward / shin folds back), ankle = ankle
# (+ dorsiflexion, toe up), toe = toe curl (+ grip/down), flat = keep sole level.
# --------------------------------------------------------------------------------------
N = {}


def leg(flex=0.0, abd=0.0, yaw=0.0, knee=0.0, ankle=0.0, toe=0.0, flat=False):
    return {"flex": flex, "abd": abd, "yaw": yaw, "knee": knee, "ankle": ankle, "toe": toe, "flat": flat}


POSES = [
    ("neutral", "rest pose", leg(), leg()),
    ("crouch30", "shallow forward knee 30 (hip 15, sole flat)", leg(15, knee=30, flat=True), leg(15, knee=30, flat=True)),
    ("crouch90", "deep forward knee 90 (hip 45, sole flat)", leg(45, knee=90, flat=True), leg(45, knee=90, flat=True)),
    ("crouch120", "deep forward knee 120 (hip 60, sole flat)", leg(60, knee=120, flat=True), leg(60, knee=120, flat=True)),
    ("tuck", "flip tuck: hip 110, knee 145, ankle -20, toe 25", leg(110, knee=145, ankle=-20, toe=25), leg(110, knee=145, ankle=-20, toe=25)),
    ("seatedV", "seated V: hip 80, spread 30, knee 100", leg(80, yaw=30, knee=100, ankle=10), leg(80, yaw=30, knee=100, ankle=10)),
    ("wide", "wide support: abduction 25, knee 15, sole flat", leg(8, abd=25, knee=15, flat=True), leg(8, abd=25, knee=15, flat=True)),
    ("worklift", "work-foot lift: L hip 90 knee 60 / R support", leg(90, knee=60, ankle=10, toe=20), leg(10, knee=20, flat=True)),
    ("runswing", "run: L hip -35 knee 45 / R hip 55 knee 70", leg(-35, knee=45, ankle=-25), leg(55, knee=70, ankle=5)),
    ("ankle", "ankle: L dorsi +35 / R plantar -35", leg(ankle=35), leg(ankle=-35)),
    ("toecurl", "toe: L grip curl +45 / R lift -45", leg(toe=45), leg(toe=-45)),
    ("footclose", "close-up: L toe grip +45, ankle +15", leg(ankle=15, toe=45), leg(toe=-45)),
]

VIEWS = [  # name, view direction (camera looks along it)
    ("side", (1.0, 0.0, -0.12)),
    ("front", (0.0, -1.0, -0.12)),
    ("3/4", (0.62, -0.72, -0.30)),
]
PANEL = (426, 360)


# ======================================================================================
# Composition (plain python3 + Pillow)
# ======================================================================================
def compose(job_path):
    from PIL import Image, ImageDraw, ImageFont
    job = json.load(open(job_path))

    def font(size, bold=False):
        for f in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else
                  "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",):
            if os.path.exists(f):
                return ImageFont.truetype(f, size)
        return ImageFont.load_default()

    f1, f2 = font(15, True), font(12)
    pw, ph = job["panel"]
    for sheet in job["sheets"]:
        cols = len(sheet["rows"][0]["panels"])
        img = Image.new("RGB", (pw * cols, ph * len(sheet["rows"])), (30, 31, 34))
        for r, row in enumerate(sheet["rows"]):
            for c, panel in enumerate(row["panels"]):
                im = Image.open(panel["file"]).convert("RGB")
                img.paste(im, (c * pw, r * ph))
                d = ImageDraw.Draw(img, "RGBA")
                d.rectangle([c * pw, r * ph, c * pw + pw - 1, r * ph + 38], fill=(0, 0, 0, 120))
                d.text((c * pw + 8, r * ph + 4), panel["title"], font=f1, fill=(255, 255, 255))
                d.text((c * pw + 8, r * ph + 22), panel["subtitle"], font=f2, fill=(215, 222, 230))
                d.rectangle([c * pw, r * ph, c * pw + pw - 1, r * ph + ph - 1], outline=(70, 72, 78))
        img.save(sheet["out"], quality=90)
        print("[wako_deform_sheet] wrote", sheet["out"], img.size)


# ======================================================================================
# Rendering (Blender)
# ======================================================================================
def render_main(argv):
    import bpy
    from mathutils import Matrix, Vector

    blend, out_dir, prefix = argv[:3]
    opts = {"label": prefix.upper(), "samples": 24, "poses": None, "keep": None}
    i = 3
    while i < len(argv):
        k = argv[i]
        if k == "--label":
            opts["label"] = argv[i + 1]
        elif k == "--samples":
            opts["samples"] = int(argv[i + 1])
        elif k == "--poses":
            opts["poses"] = argv[i + 1].split(",")
        elif k == "--keep-panels":
            opts["keep"] = argv[i + 1]
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

    sun("sheet_key", (0.8, -1.0, -1.3), 3.2)
    sun("sheet_rim", (-0.6, 1.0, -0.5), 1.4)
    sun("sheet_fill", (-1.0, -0.3, -0.2), 0.6)
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

    def leg_frames(side, p):
        out_sign = 1.0 if side < 0 else -1.0  # +abd/+yaw moves the leg away from the midline
        r_leg = rz(out_sign * p["yaw"]) @ ry(out_sign * p["abd"]) @ rx(p["flex"])
        r_shin = r_leg @ rx(-p["knee"])
        r_foot = Matrix.Identity(3) if p["flat"] else r_shin @ rx(p["ankle"])
        if p["flat"] and p["ankle"]:
            r_foot = rx(p["ankle"])
        r_toe = r_foot @ rx(-p["toe"])
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
                parent_head_rest = heads[k - 1]
                new_heads.append(new_heads[k - 1] + frames[k - 1] @ (heads[k] - parent_head_rest))
            for k, n in enumerate(names):
                m = frames[k].to_4x4() @ rest[k].to_3x3().to_4x4()
                m.translation = new_heads[k]
                arm.pose.bones[n].matrix = m
                bpy.context.view_layer.update()
            knees[names[1]] = tuple(round(x, 3) for x in arm.pose.bones[names[1]].head)
        return knees

    # ---------------------------------------------------------------- framing
    rest_world = [ob.matrix_world @ v.co for v in ob.data.vertices]
    frame_sets = {
        "full": [i for i, p in enumerate(rest_world) if p.z < 0.98],
        "left_foot": [i for i, p in enumerate(rest_world) if p.z < 0.24 and p.x < 0],
    }

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
        cam_data.ortho_scale = max(w, h * aspect) * 1.14 + 0.04
        # leave room for the label bar at the top
        cy += cam_data.ortho_scale / aspect * 0.045
        centre = r * cx + u * cy
        cam.location = centre - f * 6.0
        cam.rotation_euler = f.to_track_quat("-Z", "Y").to_euler()
        cam_data.clip_end = 20.0
        wire_mod.thickness = cam_data.ortho_scale / PANEL[0] * 0.75

    # ---------------------------------------------------------------- render loop
    tmp = opts["keep"] or tempfile.mkdtemp(prefix="wako_sheet_")
    os.makedirs(tmp, exist_ok=True)
    os.makedirs(out_dir, exist_ok=True)
    poses = [p for p in POSES if opts["poses"] is None or p[0] in opts["poses"]]
    rendered = []
    for name, desc, spec_l, spec_r in poses:
        knees = apply_pose(spec_l, spec_r)
        print(f"[wako_deform_sheet] pose {name}: knee heads (armature space) {knees}", flush=True)
        panels = []
        for vname, vdir in VIEWS:
            frame(vdir, "left_foot" if name == "footclose" else "full")
            path = os.path.join(tmp, f"{prefix}_{name}_{vname.replace('/', '')}.png")
            scn.render.filepath = path
            bpy.ops.render.render(write_still=True)
            panels.append({"file": path, "title": f"{opts['label']}  {name}  [{vname}]", "subtitle": desc})
        rendered.append({"name": name, "panels": panels})
    sheets = []
    for k in range(0, len(rendered), 2):
        rows = rendered[k:k + 2]
        out_path = os.path.join(out_dir, f"{prefix}_{k // 2 + 1:02d}_{'_'.join(r['name'] for r in rows)}.jpg")
        sheets.append({"out": out_path, "rows": rows})
    job = {"panel": PANEL, "sheets": sheets}
    job_path = os.path.join(tmp, f"{prefix}_job.json")
    with open(job_path, "w") as fh:
        json.dump(job, fh, indent=1)
    try:
        import PIL  # noqa: F401
        compose(job_path)
    except ImportError:
        py = os.environ.get("WAKO_PIL_PYTHON", "python3")
        subprocess.run([py, os.path.abspath(__file__), "compose", job_path], check=True)


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "compose":
        compose(sys.argv[2])
    else:
        args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
        render_main(args)

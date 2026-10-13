"""Wako regional deformation metrics -- pipeline QA tool (Blender Python).

    <blender-python> wako_deform_metrics.py -- BLEND LABEL OUT.json [pose,...|all] [--detail]

Poses the rig exactly like wako_deform_sheet.py (knees forward, pose_bone.matrix in
hierarchy order; +toe curls the toe tip down on either rig) and reports, per pose and per
leg zone (junction z >= 0.66, knee 0.36-0.66, ankle 0.09-0.36, toe/foot < 0.09):

* dih_max / dih_n120 / dih_n90: worst angle between adjacent face normals (0 = flat; a
  fold-over approaches 180) and how many edges exceed 120 / 90 degrees,
* area_min / area_p2 / area_max: face area ratio posed / rest (collapse < ~0.25),
* body_inside_area_cm2 / maxdepth: leg faces whose centroid is > 1 cm inside the rigid
  body's convex hull, and the deepest leg vertex,
* ints: intersecting triangle pairs by DOMINANT bone (same convention as the review),
  body_leg_pairs / body_cut_leg_area_cm2: pairs between the rigid body surface and the leg
  surface by REST region, and the (tessellation independent) area of leg triangles that
  cut the body surface,
* floor_min_z: lowest leg vertex (sole plane at -0.0071),
* lines (left leg, sagittal polylines of the FRONT column |x + 0.237| < 0.012, y > 0.02 and
  the BACK column y < -0.02): per-vertex turn of the posed polyline in the YZ plane --
  ``turn_abs_max`` exactly as the review measured it (absolute turn of the posed line),
  ``turn_change_max`` relative to the rest line (so designed rest curvature, e.g. the
  rounded sole edge, is not counted) -- and segment stretch posed/rest (max, and min =
  compression).  Bands: knee (rest z 0.22-0.66), ankle (z 0.0-0.30), and the toe
  outline (front column below z 0.20 continued along the sole centre line).
"""
import bpy, bmesh, sys, math, json
import numpy as np
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

argv = sys.argv[sys.argv.index("--") + 1:]
blend, label, outp = argv[:3]
only = argv[3].split(",") if len(argv) > 3 and argv[3] != "all" else None
DETAIL = "--detail" in argv
bpy.ops.wm.open_mainfile(filepath=blend)
arm = bpy.data.objects["wako_art"]
ob = bpy.data.objects["wakoMesh"]
arm.animation_data_clear()
for pb in arm.pose.bones:
    pb.matrix_basis = Matrix.Identity(4)
bpy.context.view_layer.update()
bones = {b.name: b for b in arm.data.bones}
chains = {-1: ("Bone.001", "Bone.003", "Bone.005", "toe.L"), +1: ("Bone.002", "Bone.004", "Bone.006", "toe.R")}
TOE_DIR = {s_: 1.0 if (bones[chains[s_][3]].tail_local - bones[chains[s_][3]].head_local).y > 0 else -1.0 for s_ in (-1, 1)}


def rx(d): return Matrix.Rotation(math.radians(d), 3, "X")
def ry(d): return Matrix.Rotation(math.radians(d), 3, "Y")
def rz(d): return Matrix.Rotation(math.radians(d), 3, "Z")


def leg(flex=0.0, abd=0.0, yaw=0.0, twist=0.0, knee=0.0, ankle=0.0, toe=0.0, flat=False, ftwist=0.0):
    return dict(flex=flex, abd=abd, yaw=yaw, twist=twist, knee=knee, ankle=ankle, toe=toe, flat=flat, ftwist=ftwist)


def leg_frames(side, p):
    o = 1.0 if side < 0 else -1.0
    r_leg = rz(o * p["yaw"]) @ ry(o * p["abd"]) @ rx(p["flex"]) @ rz(o * p["twist"])
    r_shin = r_leg @ rx(-p["knee"])
    r_foot = Matrix.Identity(3) if p["flat"] else r_shin @ rx(p["ankle"]) @ rz(o * p["ftwist"])
    if p["flat"] and p["ankle"]:
        r_foot = rx(p["ankle"])
    r_toe = r_foot @ rx(-p["toe"] * TOE_DIR[side])   # +toe curls the tip down either rig
    return [r_leg, r_shin, r_foot, r_toe]


def apply_pose(sl, sr):
    for pb in arm.pose.bones:
        pb.matrix_basis = Matrix.Identity(4)
    bpy.context.view_layer.update()
    for side, spec in ((-1, sl), (+1, sr)):
        names = chains[side]
        fr = leg_frames(side, spec)
        rs = [bones[n].matrix_local for n in names]
        hs = [r.translation.copy() for r in rs]
        nh = [hs[0]]
        for k in range(1, 4):
            nh.append(nh[k - 1] + fr[k - 1] @ (hs[k] - hs[k - 1]))
        for k, n in enumerate(names):
            m = fr[k].to_4x4() @ rs[k].to_3x3().to_4x4()
            m.translation = nh[k]
            arm.pose.bones[n].matrix = m
            bpy.context.view_layer.update()


me0 = ob.data
vg = {g.index: g.name for g in ob.vertex_groups}
nv = len(me0.vertices)
rest = np.array([tuple(ob.matrix_world @ v.co) for v in me0.vertices])
dom = []
for v in me0.vertices:
    gs = sorted(((g.weight, vg[g.group]) for g in v.groups), reverse=True)
    dom.append(gs[0][1] if gs else "none")
REG = {"Bone": "body", "Bone.001": "thigh", "Bone.002": "thigh", "Bone.003": "shin", "Bone.004": "shin",
       "Bone.005": "foot", "Bone.006": "foot", "toe.L": "toe", "toe.R": "toe"}
side = np.where(rest[:, 0] < -0.01, "L", np.where(rest[:, 0] > 0.01, "R", "C"))
is_body = rest[:, 2] >= 0.806   # junction ring (0.8044) counts as leg/junction


def zone(z):
    if z >= 0.66:
        return "junc"
    if z >= 0.36:
        return "knee"
    if z >= 0.09:
        return "ankle"
    return "toe"


polys = [list(p.vertices) for p in me0.polygons]
tris = []
tri_poly = []
for pi_, vs in enumerate(polys):
    for k in range(1, len(vs) - 1):
        tris.append((vs[0], vs[k], vs[k + 1]))
        tri_poly.append(pi_)
tris = np.array(tris)
poly_leg = np.array([not all(is_body[v] for v in vs) for vs in polys])
poly_zone = [zone(rest[vs].mean(0)[2]) for vs in polys]
poly_side = [side[vs[0]] if side[vs[0]] != "C" else side[vs[1]] for vs in polys]

# edges -> two faces
bm = bmesh.new(); bm.from_mesh(me0); bm.edges.ensure_lookup_table(); bm.faces.ensure_lookup_table()
edge_faces = [(e.link_faces[0].index, e.link_faces[1].index, e.verts[0].index, e.verts[1].index)
              for e in bm.edges if len(e.link_faces) == 2]
bm.free()
edge_zone = [zone(0.5 * (rest[a][2] + rest[b][2])) for _, _, a, b in edge_faces]
edge_leg = np.array([not (is_body[a] and is_body[b]) for _, _, a, b in edge_faces])

# body hull planes (rest; the root is never posed here)
bmh = bmesh.new()
for p in rest[rest[:, 2] >= 0.80]:
    bmh.verts.new(p)
res = bmesh.ops.convex_hull(bmh, input=bmh.verts[:])
bmh.normal_update()
planes = []
for f in bmh.faces:
    n = f.normal.normalized()
    planes.append((np.array(n), float(n.dot(f.verts[0].co))))
bmh.free()
PN = np.array([p[0] for p in planes]); PD = np.array([p[1] for p in planes])


def hull_depth(pts):
    # positive inside: min over planes of (d - n.p)
    return (PD[None, :] - pts @ PN.T).min(1)


def posed():
    dg = bpy.context.evaluated_depsgraph_get()
    oe = ob.evaluated_get(dg)
    m = oe.to_mesh()
    co = np.array([tuple(oe.matrix_world @ v.co) for v in m.vertices])
    oe.to_mesh_clear()
    return co


def poly_normals_areas(co):
    ns, ar = [], []
    for vs in polys:
        p = co[vs]
        n = np.zeros(3)
        for k in range(len(vs)):
            n += np.cross(p[k], p[(k + 1) % len(vs)])
        a = np.linalg.norm(n) * 0.5
        ns.append(n / max(2 * a, 1e-12)); ar.append(a)
    return np.array(ns), np.array(ar)


N0, A0 = poly_normals_areas(rest)
D0 = np.array([math.degrees(math.acos(np.clip(N0[f1] @ N0[f2], -1, 1))) for f1, f2, _, _ in edge_faces])


tri_body = np.array([all(is_body[v] for v in t) for t in tris])


def body_leg_pairs(co):
    """Intersecting (rigid body surface, leg surface) triangle pairs by REST region (body =
    rest z >= 0.806), not by dominant bone, plus the leg area (cm2) whose triangles cut the body."""
    bvh = BVHTree.FromPolygons([tuple(x) for x in co], [tuple(t) for t in tris], all_triangles=True)
    n, legtris = 0, set()
    for i, j in bvh.overlap(bvh):
        if i >= j or set(tris[i]) & set(tris[j]):
            continue
        if tri_body[i] != tri_body[j]:
            n += 1
            legtris.add(j if tri_body[i] else i)
    a, b, c = co[tris[:, 0]], co[tris[:, 1]], co[tris[:, 2]]
    ar = 0.5 * np.linalg.norm(np.cross(b - a, c - a), axis=1)
    return n, float(sum(ar[k] for k in legtris) * 1e4)


def intersections(co):
    bvh = BVHTree.FromPolygons([tuple(x) for x in co], [tuple(t) for t in tris], all_triangles=True)
    out = {}
    for i, j in bvh.overlap(bvh):
        if i >= j or set(tris[i]) & set(tris[j]):
            continue
        a, b = tris[i][0], tris[j][0]
        ri = REG[dom[a]] + side[a]
        rj = REG[dom[b]] + side[b]
        k = "-".join(sorted([ri, rj]))
        out[k] = out.get(k, 0) + 1
    return out


POSES = {
    "neutral": (leg(), leg()),
    "crouch30": (leg(15, knee=30, flat=True), leg(15, knee=30, flat=True)),
    "crouch90": (leg(45, knee=90, flat=True), leg(45, knee=90, flat=True)),
    "crouch120": (leg(60, knee=120, flat=True), leg(60, knee=120, flat=True)),
    "tuck": (leg(110, knee=145, ankle=-20, toe=25), leg(110, knee=145, ankle=-20, toe=25)),
    "seatedV": (leg(80, yaw=30, knee=100, ankle=10), leg(80, yaw=30, knee=100, ankle=10)),
    "groundV": (leg(120, yaw=30, knee=85, ankle=-5), leg(120, yaw=30, knee=85, ankle=-5)),
    "wide": (leg(8, abd=25, knee=15, flat=True), leg(8, abd=25, knee=15, flat=True)),
    "worklift": (leg(90, knee=60, ankle=10, toe=20), leg(10, knee=20, flat=True)),
    "runswing": (leg(-35, knee=45, ankle=-25), leg(55, knee=70, ankle=5)),
    "ankle": (leg(ankle=35), leg(ankle=-35)),
    "toegrip": (leg(90, knee=60, ankle=10, toe=45), leg(90, knee=60, ankle=10, toe=-45)),
    "toestand": (leg(toe=45), leg(toe=-45)),
    "twist40": (leg(twist=40), leg(twist=-40)),
    "ftwist30": (leg(30, knee=40, ftwist=30), leg(30, knee=40, ftwist=-30)),
    # symmetric poses for the profile-line checks
    "knee60": (leg(36, knee=60), leg(36, knee=60)),
    "dorsi35": (leg(ankle=35), leg(ankle=35)),
    "plantar35": (leg(ankle=-35), leg(ankle=-35)),
    "toe+45stand": (leg(toe=45), leg(toe=45)),
    "toe-45stand": (leg(toe=-45), leg(toe=-45)),
    "toe+45lift": (leg(90, knee=60, ankle=10, toe=45), leg(90, knee=60, ankle=10, toe=45)),
    "toe-45lift": (leg(90, knee=60, ankle=10, toe=-45), leg(90, knee=60, ankle=10, toe=-45)),
}
LINE_BANDS = {  # pose -> line bands to report
    "knee60": ("knee",), "crouch30": ("knee", "ankle"), "crouch90": ("knee", "ankle"), "crouch120": ("knee", "ankle"),
    "tuck": ("knee", "ankle", "toe"), "seatedV": ("knee",), "groundV": ("knee",), "worklift": ("knee", "toe"),
    "runswing": ("knee", "ankle"), "wide": ("ankle",), "ankle": ("ankle",), "dorsi35": ("ankle",),
    "plantar35": ("ankle",), "toe+45stand": ("toe",), "toe-45stand": ("toe",), "toe+45lift": ("toe",),
    "toe-45lift": ("toe",), "toegrip": ("toe",), "toestand": ("toe",),
}
_col = [i for i in range(nv) if abs(rest[i, 0] + 0.237) < 0.012 and not is_body[i]]
FRONT = sorted([i for i in _col if rest[i, 1] > 0.02 and rest[i, 2] > 0.0], key=lambda i: -rest[i, 2])
BACK = sorted([i for i in _col if rest[i, 1] < -0.02 and rest[i, 2] > 0.0], key=lambda i: -rest[i, 2])
SOLE = sorted([i for i in _col if rest[i, 2] <= 0.0], key=lambda i: -rest[i, 1])
LINES = {
    "knee": {"front": [i for i in FRONT if 0.22 < rest[i, 2] < 0.66], "back": [i for i in BACK if 0.22 < rest[i, 2] < 0.66]},
    "ankle": {"front": [i for i in FRONT if 0.0 < rest[i, 2] < 0.30], "back": [i for i in BACK if 0.0 < rest[i, 2] < 0.30]},
    # the toe outline runs down the face the toe is on (front on the rebuilt rig, back on
    # the original one, whose toe pointed -Y) and on along the sole, toe tip first
    "toe": {"outline": [i for i in FRONT if rest[i, 2] < 0.20] + SOLE if TOE_DIR[-1] > 0
            else [i for i in BACK if rest[i, 2] < 0.20] + SOLE[::-1]},
}


def line_metrics(co, idx):
    p, p0 = co[idx][:, 1:], rest[idx][:, 1:]
    s, s0 = np.diff(p, axis=0), np.diff(p0, axis=0)

    def turns(v):
        a, b = v[:-1], v[1:]
        return np.degrees(np.arctan2(a[:, 0] * b[:, 1] - a[:, 1] * b[:, 0], (a * b).sum(1)))
    t, t0 = turns(s), turns(s0)
    st = np.linalg.norm(s, axis=1) / np.maximum(np.linalg.norm(s0, axis=1), 1e-12)
    return {"vertices": len(idx), "turn_abs_max": round(float(np.abs(t).max()), 1),
            "turn_change_max": round(float(np.abs(t - t0).max()), 1),
            "stretch_max": round(float(st.max()), 2), "stretch_min": round(float(st.min()), 2)}
apply_pose(leg(), leg())
co_n = posed()
res = {"_label": label}
zones = ["junc", "knee", "ankle", "toe"]
for name, (sl, sr) in POSES.items():
    if only and name not in only:
        continue
    apply_pose(sl, sr)
    co = posed()
    N, A = poly_normals_areas(co)
    ratio = A / np.maximum(A0, 1e-12)
    D = np.array([math.degrees(math.acos(np.clip(N[f1] @ N[f2], -1, 1))) for f1, f2, _, _ in edge_faces])
    r = {}
    for zname in zones:
        pm = np.array([poly_leg[i] and poly_zone[i] == zname for i in range(len(polys))])
        em = np.array([edge_leg[i] and edge_zone[i] == zname for i in range(len(edge_faces))])
        r[zname] = {"dih_max": round(float(D[em].max()), 1), "dih_n120": int((D[em] > 120).sum()),
                    "dih_n90": int((D[em] > 90).sum()),
                    "area_min": round(float(ratio[pm].min()), 3), "area_p2": round(float(np.percentile(ratio[pm], 2)), 3),
                    "area_max": round(float(ratio[pm].max()), 2)}
    # body hull penetration of leg faces (centroids), and leg vertex depth
    cen = np.array([co[vs].mean(0) for vs in polys])
    dep = hull_depth(cen)
    legm = poly_leg & (np.array(poly_zone) != "junc") | (poly_leg & (dep > 0.0))
    inside = poly_leg & (dep > 0.01)
    vdep = hull_depth(co)
    r["body_inside_area_cm2"] = round(float(A[inside].sum() * 1e4), 1)
    r["body_inside_maxdepth_cm"] = round(float(max(0.0, vdep[~is_body].max()) * 100), 2)
    r["ints"] = intersections(co)
    r["body_leg_pairs"], r["body_cut_leg_area_cm2"] = body_leg_pairs(co)
    r["floor_min_z"] = round(float(co[~is_body][:, 2].min()), 4)
    r["lines"] = {band: {k: line_metrics(co, idx) for k, idx in LINES[band].items() if len(idx) > 2}
                  for band in LINE_BANDS.get(name, ())}
    if DETAIL:
        for zname in zones:
            em = [i for i in range(len(edge_faces)) if edge_leg[i] and edge_zone[i] == zname and D[i] > 100]
            em.sort(key=lambda i: -D[i])
            for i in em[:6]:
                f1, f2, a, b = edge_faces[i]
                mid = 0.5 * (rest[a] + rest[b])
                cx = -0.2365 if mid[0] < 0 else 0.2365
                ang = math.degrees(math.atan2(abs(mid[0] - cx) * (1 if (mid[0] - cx) * (-1 if mid[0] < 0 else 1) > 0 else -1), mid[1] - 0.02))
                print(f"      {zname} dih {D[i]:.0f} rest {np.round(mid, 3)} ang~{ang:.0f} (outer+) side {side[a]} areas {ratio[f1]:.2f}/{ratio[f2]:.2f}")
    knees = {}
    res[name] = r
    z = r
    print(f"[{label}] {name:9s} " + " | ".join(
        f"{zn}: dih {z[zn]['dih_max']:5.1f} n120 {z[zn]['dih_n120']:2d} amin {z[zn]['area_min']:.2f}" for zn in zones)
        + f" | inBody {r['body_inside_area_cm2']}cm2 d{r['body_inside_maxdepth_cm']} floor {r['floor_min_z']}", flush=True)
    print(f"      ints {r['ints']}  body/leg pairs {r['body_leg_pairs']} cut-leg-area {r['body_cut_leg_area_cm2']:.1f}cm2", flush=True)
    for band, ls in r["lines"].items():
        print(f"      line {band}: " + " | ".join(f"{k} turn {v['turn_abs_max']}/{v['turn_change_max']} stretch {v['stretch_max']}/{v['stretch_min']}"
                                              for k, v in ls.items()), flush=True)
json.dump(res, open(outp, "w"), indent=1)

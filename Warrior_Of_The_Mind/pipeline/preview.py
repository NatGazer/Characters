"""Quick Workbench previews of the current scene from the four reference cameras, composed next to
the references (and a silhouette-overlap image). Used after every modelling change."""
import os
import numpy as np, cv2, bpy
import bl, views

HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, 'work')

PREVIEW_COLORS = {
    'skin': (0.72, 0.52, 0.42), 'armor': (0.10, 0.09, 0.09), 'gold': (0.85, 0.62, 0.22),
    'cloth_red': (0.45, 0.05, 0.08), 'cloth_dark': (0.07, 0.06, 0.06), 'cloth_tabard': (0.12, 0.09, 0.06), 'leather': (0.25, 0.14, 0.08),
    'bronze': (0.55, 0.40, 0.22), 'hair': (0.12, 0.07, 0.04), 'eye': (1.0, 0.7, 0.1), 'default': (0.6, 0.6, 0.6),
}

def color_materials():
    for m in bpy.data.materials:
        key = next((k for k in PREVIEW_COLORS if m.name.startswith(k)), None)
        c = PREVIEW_COLORS.get(key or 'default')
        m.diffuse_color = (*c, 1.0)

def box_crop(view, bmin, bmax, pad=12):
    C = np.array([[x, y, z] for x in (bmin[0], bmax[0]) for y in (bmin[1], bmax[1]) for z in (bmin[2], bmax[2])])
    uv, _ = views.project(view, C)
    u0, v0 = np.floor(uv.min(0)) - pad; u1, v1 = np.ceil(uv.max(0)) + pad
    return (int(max(u0, 0)), int(max(v0, 0)), int(min(u1, 1024)), int(min(v1, 1536)))

def render_views(tag, views_list=('front', 'left', 'back', 'right'), crop=None, scale=0.5, side_by_side=True, box=None, height=None):
    sc = bpy.context.scene
    bl.workbench(sc)
    sc.display.shading.color_type = 'MATERIAL'
    sc.display.shading.light = 'STUDIO'
    sc.render.film_transparent = True
    color_materials()
    outs = []
    for v in views_list:
        if box is not None:
            crop = box_crop(v, *box)
            if height: scale = height / (crop[3] - crop[1])
        cam = bl.ref_camera(v, crop=crop, res_scale=scale)
        p = os.path.join(W, f'pv_{tag}_{v}.png')
        bl.render(p)
        bpy.data.objects.remove(cam, do_unlink=True)
        r = cv2.imread(p, cv2.IMREAD_UNCHANGED)
        ref = views.ref_image(v)
        if crop: ref = ref[crop[1]:crop[3], crop[0]:crop[2]]
        ref = cv2.resize(ref, (r.shape[1], r.shape[0]), interpolation=cv2.INTER_AREA)
        a = r[..., 3:4].astype(np.float32) / 255
        comp = (r[..., :3] * a + ref * (1 - a) * 0.55 + 0.45 * 255 * (1 - a)).astype(np.uint8)
        # overlay: reference with model silhouette outline
        edge = cv2.morphologyEx((a[..., 0] > 0.5).astype(np.uint8), cv2.MORPH_GRADIENT, np.ones((3, 3), np.uint8)) > 0
        ov = ref.copy(); ov[edge] = (0, 0, 255)
        outs.append(np.vstack([comp, ov]) if side_by_side else comp)
    hmax = max(o.shape[0] for o in outs)
    outs = [np.pad(o, ((0, hmax - o.shape[0]), (0, 4), (0, 0))) for o in outs]
    img = np.hstack(outs)
    cv2.imwrite(os.path.join(W, f'pv_{tag}.jpg'), img, [cv2.IMWRITE_JPEG_QUALITY, 88])
    return img

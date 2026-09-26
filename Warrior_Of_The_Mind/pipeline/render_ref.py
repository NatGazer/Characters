"""Cycles renders of the textured model from the reference cameras (studio lighting like the refs),
with a simple bloom in post, composed side by side with the references.

usage: python render_ref.py [views...] [--res 0.5] [--samples 48] [--blend work/model_uv.blend] [--tag name]
"""
import sys, os, argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2, bpy
import bl, views, materials

HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, 'work')

def studio(sc):
    world = bpy.data.worlds.new('studio'); sc.world = world; world.use_nodes = True
    bg = world.node_tree.nodes['Background']; bg.inputs[0].default_value = (0.62, 0.63, 0.66, 1); bg.inputs[1].default_value = 0.75
    def area(name, loc, rot, size, energy, col=(1, 1, 1)):
        L = bpy.data.lights.new(name, 'AREA'); L.size = size; L.energy = energy; L.color = col
        o = bpy.data.objects.new(name, L); sc.collection.objects.link(o); o.location = loc; o.rotation_euler = rot
        return o
    import math
    area('key', (-2.2, -3.0, 3.0), (math.radians(55), 0, math.radians(-35)), 3.0, 190)
    area('fill', (2.8, -2.6, 1.6), (math.radians(70), 0, math.radians(45)), 4.0, 130, (0.95, 0.97, 1.0))
    area('rim', (0.5, 3.2, 2.8), (math.radians(-60), 0, math.radians(175)), 2.5, 260)
    area('top', (0, 0, 4.2), (0, 0, 0), 3.0, 60)

def bloom(img, thr=0.82, strength=0.55):
    x = img.astype(np.float32) / 255
    lum = x.max(2)
    hi = x * np.clip((lum - thr) / (1 - thr), 0, 1)[..., None]
    b = sum(cv2.GaussianBlur(hi, (0, 0), s) * w for s, w in [(2, 0.5), (6, 0.35), (16, 0.25)])
    return np.clip((x + b * strength) * 255, 0, 255).astype(np.uint8)

def portrait(sc, tag):
    """Perspective head shots (85 mm) front / three-quarter / profile, next to reference crops."""
    import math
    from mathutils import Vector
    head = Vector((0, -0.04, 1.83))
    outs = []
    for name, az, ref in (('front', 0, ('front', (437, 50, 567, 205))), ('q34', -35, ('front', (437, 50, 567, 205))),
                          ('prof', 90, ('left', (345, 50, 475, 205)))):
        cam = bpy.data.objects.new('pc', bpy.data.cameras.new('pc')); sc.collection.objects.link(cam)
        cam.data.lens = 85; cam.data.sensor_width = 36
        d = 0.62; a_ = math.radians(az)
        cam.location = head + Vector((-math.sin(a_) * d, -math.cos(a_) * d, 0.03))
        cam.rotation_euler = (head - cam.location).to_track_quat('-Z', 'Y').to_euler()
        sc.camera = cam; sc.render.resolution_x = 600; sc.render.resolution_y = 720
        p = os.path.join(W, f'p_{tag}_{name}.png'); bl.render(p)
        bpy.data.objects.remove(cam, do_unlink=True)
        r = bloom(cv2.imread(p), 0.9, 0.3)
        v, c = ref
        rim = views.ref_image(v, up=True)[c[1] * 4:c[3] * 4, c[0] * 4:c[2] * 4]
        rim = cv2.resize(rim, (int(720 * rim.shape[1] / rim.shape[0]), 720), interpolation=cv2.INTER_AREA)
        outs.append(r)
        if name != 'q34': outs.append(rim)
    cv2.imwrite(os.path.join(W, f'p_{tag}.jpg'), np.hstack(outs), [cv2.IMWRITE_JPEG_QUALITY, 90])

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('views', nargs='*', default=['front', 'left', 'back', 'right'])
    ap.add_argument('--res', type=float, default=0.5); ap.add_argument('--samples', type=int, default=48)
    ap.add_argument('--blend', default=os.path.join(W, 'model_uv.blend')); ap.add_argument('--tag', default='cyc')
    ap.add_argument('--crop', default=None)
    ap.add_argument('--portrait', action='store_true')
    a = ap.parse_args([x for x in sys.argv[1:] if x != '--'])
    bpy.ops.wm.open_mainfile(filepath=a.blend)
    materials.assign_all()
    for o in bpy.data.objects:
        if o.name.lower() == 'sword': o.hide_render = True
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'; sc.cycles.samples = a.samples; sc.cycles.use_denoising = True
    try: sc.cycles.denoiser = 'OPENIMAGEDENOISE'
    except Exception: pass
    sc.cycles.max_bounces = 6; sc.cycles.transparent_max_bounces = 24
    sc.view_settings.view_transform = 'Khronos PBR Neutral'; sc.view_settings.look = 'None'; sc.view_settings.exposure = 0.0
    sc.render.film_transparent = False
    studio(sc)
    if a.portrait:
        portrait(sc, a.tag); return
    crop = tuple(int(x) for x in a.crop.split(',')) if a.crop else None
    outs = []
    for v in a.views:
        cam = bl.ref_camera(v, crop=crop, res_scale=a.res)
        p = os.path.join(W, f'r_{a.tag}_{v}.png'); bl.render(p)
        bpy.data.objects.remove(cam, do_unlink=True)
        r = bloom(cv2.imread(p))
        cv2.imwrite(p, r)
        ref = views.ref_image(v)
        if crop: ref = ref[crop[1]:crop[3], crop[0]:crop[2]]
        ref = cv2.resize(ref, (r.shape[1], r.shape[0]), interpolation=cv2.INTER_AREA)
        outs.append(np.hstack([r, ref]))
    img = np.vstack(outs) if len(outs) > 1 and outs[0].shape[1] > outs[0].shape[0] else np.hstack(outs)
    cv2.imwrite(os.path.join(W, f'r_{a.tag}.jpg'), img, [cv2.IMWRITE_JPEG_QUALITY, 90])

if __name__ == '__main__':
    main()

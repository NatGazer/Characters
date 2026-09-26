"""Contact sheets of many actions (workbench): one row per clip, n frames, camera follows the hips.
usage: python anim_sheet.py <blend> <out_prefix> [clip ...]"""
import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2, bpy
from mathutils import Vector
import bl, preview

def main(blend, out, names=None, n=6, view=(4.2, -4.2, 0.4), res=(220, 320), per_sheet=8, hide=('Hair',)):
    bpy.ops.wm.open_mainfile(filepath=blend)
    arm = bpy.data.objects['Warrior']
    for h in hide:
        if h in bpy.data.objects: bpy.data.objects[h].hide_render = True
    sc = bpy.context.scene
    bl.workbench(sc); sc.display.shading.color_type = 'MATERIAL'
    cols = {'M_Body': (0.55, 0.42, 0.36), 'M_Armor': (0.20, 0.18, 0.16), 'M_Cloth': (0.45, 0.06, 0.08), 'M_Hair': (0.15, 0.09, 0.05), 'M_Eyes': (1, 0.7, 0.2)}
    for m in bpy.data.materials:
        if m.name in cols: m.diffuse_color = (*cols[m.name], 1)
    sc.render.resolution_x, sc.render.resolution_y = res
    cam = bpy.data.objects.new('c', bpy.data.cameras.new('c')); sc.collection.objects.link(cam); sc.camera = cam
    cam.data.type = 'ORTHO'; cam.data.ortho_scale = 2.9
    bpy.ops.mesh.primitive_plane_add(size=30, location=(0, 0, 0))
    acts = [a for a in bpy.data.actions if (names is None or a.name in names)]
    rows = []
    for act in acts:
        arm.animation_data.action = act
        try: arm.animation_data.action_slot = act.slots[0]
        except Exception: pass
        f0, f1 = act.frame_range
        ims = []
        for f in np.linspace(f0, f1, n).round().astype(int):
            sc.frame_set(int(f))
            hips = arm.matrix_world @ arm.pose.bones['Hips'].head
            c = Vector((hips.x, hips.y, 1.0)); d = Vector(view)
            cam.location = c + d; cam.rotation_euler = (-d).to_track_quat('-Z', 'Y').to_euler()
            p = '/tmp/sheet_f.png'; bl.render(p); im = cv2.imread(p)
            cv2.putText(im, f'{act.name} {f}', (3, 14), 0, 0.4, (0, 255, 255), 1); ims.append(im)
        rows.append(np.hstack(ims))
    for i in range(0, len(rows), per_sheet):
        cv2.imwrite(f'{out}_{i // per_sheet}.jpg', np.vstack(rows[i:i + per_sheet]), [cv2.IMWRITE_JPEG_QUALITY, 85])
    print('sheets', (len(rows) + per_sheet - 1) // per_sheet)

if __name__ == '__main__':
    a = [x for x in sys.argv[1:] if x != '--']
    main(a[0], a[1], a[2:] or None)

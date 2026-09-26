"""Render a strip of frames of an action (Workbench, fast) for checking animation + skinning.
usage: python anim_preview.py <blend> <action> [n_frames] [view:side|front|q34] [out]"""
import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2, bpy
from mathutils import Vector
import bl, preview

def strip(blend, action, n=8, view='side', out=None, res=(300, 520), follow=True, frames=None, hide=()):
    bpy.ops.wm.open_mainfile(filepath=blend)
    for h in hide:
        if h in bpy.data.objects: bpy.data.objects[h].hide_render = True
    arm = bpy.data.objects['Warrior']
    act = bpy.data.actions[action]
    arm.animation_data.action = act
    try: arm.animation_data.action_slot = act.slots[0]
    except Exception: pass
    for tr in arm.animation_data.nla_tracks: tr.mute = True
    sc = bpy.context.scene
    bl.workbench(sc); sc.display.shading.color_type = 'MATERIAL'; preview.color_materials()
    for m in bpy.data.materials:
        if m.name == 'M_Body': m.diffuse_color = (0.55, 0.42, 0.36, 1)
        if m.name == 'M_Armor': m.diffuse_color = (0.16, 0.14, 0.13, 1)
        if m.name == 'M_Cloth': m.diffuse_color = (0.45, 0.06, 0.08, 1)
        if m.name == 'M_Hair': m.diffuse_color = (0.15, 0.09, 0.05, 1)
    sc.render.resolution_x, sc.render.resolution_y = res
    cam = bpy.data.objects.new('c', bpy.data.cameras.new('c')); sc.collection.objects.link(cam); sc.camera = cam
    cam.data.type = 'ORTHO'; cam.data.ortho_scale = 2.6
    f0, f1 = act.frame_range
    frames = frames or np.linspace(f0, f1, n).round().astype(int)
    imgs = []
    # ground grid plane for reference
    bpy.ops.mesh.primitive_plane_add(size=20, location=(0, 0, 0))
    for f in frames:
        sc.frame_set(int(f))
        hips = arm.matrix_world @ arm.pose.bones['Hips'].head
        c = Vector((hips.x, hips.y, 1.05)) if follow else Vector((0, 0, 1.05))
        d = {'side': Vector((6, 0, 0)), 'front': Vector((0, -6, 0)), 'q34': Vector((4.2, -4.2, 0))}[view]
        cam.location = c + d
        cam.rotation_euler = (-d).to_track_quat('-Z', 'Y').to_euler()
        p = f'/tmp/strip_{f}.png'; bl.render(p)
        im = cv2.imread(p); cv2.putText(im, str(f), (5, 20), 0, 0.6, (0, 0, 255), 2); imgs.append(im)
    cv2.imwrite(out or f'work/strip_{action}_{view}.jpg', np.hstack(imgs))

if __name__ == '__main__':
    a = [x for x in sys.argv[1:] if x != '--']
    strip(a[0], a[1], int(a[2]) if len(a) > 2 else 8, a[3] if len(a) > 3 else 'side', a[4] if len(a) > 4 else None)

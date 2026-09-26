"""Export the rigged + animated character for Godot 4.7 (glTF 2.0, separate WebP textures) and save the
final .blend. Copies the rig metadata (chains.json, clips.json) next to the glTF.
Input: work/model_anim.blend"""
import sys, os, json, shutil, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
W = os.path.join(HERE, 'work'); GD = os.path.join(ROOT, 'godot', 'assets', 'warrior')

def main():
    bpy.ops.wm.open_mainfile(filepath=os.path.join(W, 'model_anim.blend'))
    arm = bpy.data.objects['Warrior']
    arm.animation_data.action = None
    for tr in arm.animation_data.nla_tracks: tr.mute = False
    for pb in arm.pose.bones:
        pb.location = (0, 0, 0); pb.rotation_quaternion = (1, 0, 0, 0); pb.scale = (1, 1, 1)
    bpy.context.scene.render.fps = 30
    # final .blend next to the character (textures referenced from ../textures)
    bpy.ops.file.make_paths_relative()
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(ROOT, 'warrior_of_the_mind.blend'))
    os.makedirs(GD, exist_ok=True)
    t0 = time.time()
    bpy.ops.export_scene.gltf(
        filepath=os.path.join(GD, 'warrior.gltf'), export_format='GLTF_SEPARATE', export_texture_dir='textures',
        export_image_format='WEBP', export_image_quality=92,
        export_animations=True, export_animation_mode='ACTIONS', export_force_sampling=True,
        export_optimize_animation_size=True, export_anim_slide_to_zero=True, export_def_bones=False,
        export_skins=True, export_influence_nb=4, export_reset_pose_bones=True, export_rest_position_armature=True,
        export_yup=True, export_apply=False, export_extras=True, export_frame_step=1, export_tangents=True)
    print('exported', round(time.time() - t0, 1), 's')
    for f in ('chains.json', 'clips.json'):
        shutil.copy(os.path.join(W, f), os.path.join(GD, f))

if __name__ == '__main__':
    main()

import bpy, sys, time
a=sys.argv[sys.argv.index('--')+1:]
bpy.ops.wm.open_mainfile(filepath=a[0]); out=a[1]
ao=bpy.data.objects['BeetleRig']
ao.animation_data.action=None
for tr in ao.animation_data.nla_tracks: tr.mute=False
for pb in ao.pose.bones: pb.location=(0,0,0); pb.rotation_quaternion=(1,0,0,0); pb.scale=(1,1,1)
bpy.context.scene.render.fps=60
t0=time.time()
bpy.ops.export_scene.gltf(filepath=out, export_format='GLB', export_image_format='AUTO',
    export_animations=True, export_animation_mode='ACTIONS', export_force_sampling=True,
    export_def_bones=True, export_optimize_animation_size=True, export_anim_slide_to_zero=True,
    export_skins=True, export_influence_nb=4, export_reset_pose_bones=True, export_rest_position_armature=True,
    export_yup=True, export_apply=False, export_extras=False, export_nla_strips=True, export_frame_step=1)
print('exported',out,round(time.time()-t0,1),'s')

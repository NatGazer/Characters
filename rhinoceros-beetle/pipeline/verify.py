import bpy, sys
bpy.ops.wm.open_mainfile(filepath='../rhinoceros_beetle.blend')
ao=bpy.data.objects['BeetleRig']; bpy.data.objects['Beetle'].modifiers['Armature'].show_viewport=False
sc=bpy.context.scene
for tr in ao.animation_data.nla_tracks: tr.mute=True
legs=[(l,s) for l in ('front','mid','hind') for s in 'LR']
for act in bpy.data.actions:
    ao.animation_data.action=act
    try: ao.animation_data.action_slot=act.slots[0]
    except: pass
    f0,f1=int(act.frame_range[0]),int(act.frame_range[1])
    worst_reach=(0,None); worst_pen=(0,None); body_min=9
    for f in range(f0,f1+1):
        sc.frame_set(f)
        for l,s in legs:
            tib=ao.pose.bones[f'{l}_tibia.{s}']; tgt=ao.pose.bones[f'ankle_tgt.{l}.{s}']
            d=(tib.tail-tgt.head).length
            if d>worst_reach[0]: worst_reach=(d,(f,l,s))
            tip=ao.pose.bones[f'{l}_claw.{s}'].tail.z
            if -tip>worst_pen[0]: worst_pen=(-tip,(f,l,s))
    print(f'{act.name:14s} worst IK miss {worst_reach[0]*100:5.1f} cm {worst_reach[1]}   worst claw below ground {worst_pen[0]*100:5.1f} cm {worst_pen[1]}')

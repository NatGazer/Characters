import bpy, math, json
bpy.ops.wm.open_mainfile(filepath='../rhinoceros_beetle.blend')
ao=bpy.data.objects['BeetleRig']; me=bpy.data.objects['Beetle']
me.modifiers['Armature'].show_viewport=False
def err(leg):
    e=0
    for seg in ('femur','tibia'):
        pb=ao.pose.bones[f'{leg}_{seg}']
        e+=math.degrees(pb.bone.matrix_local.to_quaternion().rotation_difference(pb.matrix.to_quaternion()).angle)
    return e
res={}
for s in 'LR':
    for leg in ('front','mid','hind'):
        c=ao.pose.bones[f'{leg}_tibia.{s}'].constraints['IK']
        best=(1e9,0)
        for step,rng in ((5,range(-180,181,5)),(1,None),(0.1,None)):
            if rng is None: rng=[best[1]+k*step for k in range(-6,7)]
            for a in rng:
                c.pole_angle=math.radians(a); bpy.context.view_layer.update()
                e=err(f'{leg}_%s.{s}'.replace('%s','{}').format) if False else None
                e=0
                for seg in ('femur','tibia'):
                    pb=ao.pose.bones[f'{leg}_{seg}.{s}']
                    e+=math.degrees(pb.bone.matrix_local.to_quaternion().rotation_difference(pb.matrix.to_quaternion()).angle)
                if e<best[0]: best=(e,a)
        c.pole_angle=math.radians(best[1]); res[f'{leg}.{s}']=best
        print(leg,s,'pole angle',round(best[1],1),'residual deg',round(best[0],3))
me.modifiers['Armature'].show_viewport=True
bpy.context.view_layer.update()
worst=[]
for pb in ao.pose.bones:
    if not pb.bone.use_deform: continue
    R=pb.bone.matrix_local; P=pb.matrix
    worst.append((math.degrees(R.to_quaternion().rotation_difference(P.to_quaternion()).angle),(R.translation-P.translation).length,pb.name))
worst.sort(reverse=True)
for w in worst[:5]: print('%-22s rot %.3f deg pos %.5f'%(w[2],w[0],w[1]))
json.dump({k:v[1] for k,v in res.items()},open('work/pole_angles.json','w'))
bpy.ops.wm.save_mainfile()

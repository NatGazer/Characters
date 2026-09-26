import bpy, sys, math
sys.path.insert(0,'.')
bpy.ops.wm.open_mainfile(filepath='../rhinoceros_beetle.blend')
import anim_lib, clips
from mathutils import Quaternion
loops={n:l for n,f,d,l in clips.CLIPS}
for act in bpy.data.actions:
    fcs={}
    for fc in anim_lib.iter_fcurves(act):
        fcs[(fc.data_path,fc.array_index)]=fc
    bones=sorted({dp.split('"')[1] for dp,i in fcs if 'rotation_quaternion' in dp})
    f0,f1=int(act.frame_range[0]),int(act.frame_range[1])
    worst=(0,None); seam=(0,None)
    for b in bones:
        dp=f'pose.bones["{b}"].rotation_quaternion'
        qs=[Quaternion([fcs[(dp,i)].evaluate(f) for i in range(4)]) for f in range(f0,f1+1)]
        for k in range(1,len(qs)):
            a=math.degrees(qs[k-1].rotation_difference(qs[k]).angle)
            if a>180: a=360-a
            if a>worst[0]: worst=(a,(b,k+f0))
        if loops[act.name]:
            a=math.degrees(qs[0].rotation_difference(qs[-1]).angle); a=min(a,360-a)
            if a>seam[0]: seam=(a,b)
    print(f'{act.name:14s} max step {worst[0]:6.1f} deg/frame at {worst[1]}   loop seam {seam[0]:.3f} deg {seam[1] if loops[act.name] else "(one-shot)"}')

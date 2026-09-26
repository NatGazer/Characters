import bpy, sys, time, importlib
sys.path.insert(0,'.')
a=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
src='../rhinoceros_beetle.blend'
bpy.ops.wm.open_mainfile(filepath=src)
# drop old actions / NLA
ao=bpy.data.objects['BeetleRig']
if ao.animation_data:
    for tr in list(ao.animation_data.nla_tracks): ao.animation_data.nla_tracks.remove(tr)
    ao.animation_data.action=None
for act in list(bpy.data.actions): bpy.data.actions.remove(act)
import anim_lib, clips
only=set(a[0].split(',')) if a and a[0]!='all' else None
bpy.context.scene.render.fps=anim_lib.FPS
for name,fn,dur,loop in clips.CLIPS:
    if only and name not in only: continue
    t0=time.time(); anim_lib.bake(name,fn,dur,loop); print('baked',name,round(time.time()-t0,1),'s')
# reset pose to rest
for pb in ao.pose.bones:
    pb.location=(0,0,0); pb.rotation_quaternion=(1,0,0,0); pb.scale=(1,1,1)
out=a[1] if len(a)>1 else src
bpy.ops.wm.save_as_mainfile(filepath=out)
print('saved',out)

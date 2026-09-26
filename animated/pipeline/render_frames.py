# python3 render_frames.py -- blend out_prefix "[(clip,frame,campos,target,lens),...]" samples [res]
import bpy, sys, time
sys.path.insert(0,'.')
import rsetup
a=sys.argv[sys.argv.index('--')+1:]
bpy.ops.wm.open_mainfile(filepath=a[0]); out=a[1]; shots=eval(a[2]); samples=int(a[3]); res=eval(a[4]) if len(a)>4 else (1280,720)
co=rsetup.setup(samples=samples,res=res)
ao=bpy.data.objects['BeetleRig']; sc=bpy.context.scene
for tr in ao.animation_data.nla_tracks: tr.mute=True
for clip,fr,p,t,lens in shots:
    act=bpy.data.actions[clip]; ao.animation_data.action=act
    try: ao.animation_data.action_slot=act.slots[0]
    except: pass
    sc.frame_set(fr); rsetup.look(co,p,t,lens)
    sc.render.filepath=f'{out}_{clip}_{fr:04d}.png'; t0=time.time(); bpy.ops.render.render(write_still=True); print('render',clip,fr,round(time.time()-t0,1))

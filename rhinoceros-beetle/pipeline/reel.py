# python3 reel.py -- blend outdir "[(clip,reps,campos,target,lens),...]" res samples [blur]
import bpy, sys, time, math, os, json
sys.path.insert(0,'.')
import rsetup
a=sys.argv[sys.argv.index('--')+1:]
bpy.ops.wm.open_mainfile(filepath=a[0]); outd=a[1]; plan=eval(a[2]); res=eval(a[3]); samples=int(a[4]); blur=len(a)>5 and a[5]=='1'
os.makedirs(outd,exist_ok=True)
co=rsetup.setup(samples=samples,res=res); sc=bpy.context.scene; sc.render.fps=60
sc.render.use_motion_blur=blur; sc.render.motion_blur_shutter=0.45
ao=bpy.data.objects['BeetleRig']
for tr in ao.animation_data.nla_tracks: tr.mute=True
idx=0; manifest=[]
for clip,reps,p,t,lens in plan:
    act=bpy.data.actions[clip]; ao.animation_data.action=act
    try: ao.animation_data.action_slot=act.slots[0]
    except: pass
    f0,f1=act.frame_range; dur=(f1-f0)/60.0
    rsetup.look(co,p,t,lens)
    n=int(round(dur*30*reps))
    for i in range(n):
        tt=(i/30.0)%dur if reps>1 else min(i/30.0,dur)
        fr=f0+tt*60; fi=int(math.floor(fr)); sc.frame_set(fi,subframe=fr-fi)
        fn=f'{outd}/f{idx:05d}.png'
        if not os.path.exists(fn):
            sc.render.filepath=fn; bpy.ops.render.render(write_still=True)
        manifest.append((fn,clip)); idx+=1
    print('clip done',clip,n,flush=True)
    json.dump(manifest,open(outd+'/manifest.json','w'))

import bpy, sys, math, json, numpy as np
sys.path.insert(0,'.')
import rsetup
from mathutils import Vector, Matrix, Quaternion, Euler
a=sys.argv[sys.argv.index('--')+1:]
P=json.loads(a[0]); out=a[1]; hide_ely=a[2]=='1'; shots=eval(a[3])
bpy.ops.wm.open_mainfile(filepath='../rhinoceros_beetle.blend')
ao=bpy.data.objects['BeetleRig']; PB=ao.pose.bones
S=0.06; J=json.load(open('work/joints.json')); GZ=J['ground_z']
def T(p): p=np.asarray(p,float); return Vector((S*-p[1], S*(p[0]-2.0), S*(p[2]-GZ)))
def TV(v): return Vector((-v[1],v[0],v[2]))
res={}
for s in 'LR':
    sg=1 if s=='R' else -1
    H=T((P['hx'],sg*P['hy'],P['hz']))
    span=TV((1.0,-sg*P['inward'],-P['slope'])).normalized()
    up=TV((0,sg*math.sin(math.radians(P['bank'])),math.cos(math.radians(P['bank']))))
    z=(up-span*up.dot(span)).normalized(); x=span.cross(z)
    M=Matrix((x*P['sx'],span*P['sy'],z*P.get('sz',1))).transposed().to_4x4(); M.translation=H
    pb=PB['wing.'+s]; pb.matrix=M; bpy.context.view_layer.update()
    PB['wing_mid.'+s].rotation_quaternion=Euler((math.radians(P['mid']*sg),0,0)).to_quaternion()
    PB['wing_tip.'+s].rotation_quaternion=Euler((math.radians(P['tip']*sg),0,0)).to_quaternion()
    bpy.context.view_layer.update()
    res[s]={b:{'loc':list(PB[b].location),'rot':list(PB[b].rotation_quaternion),'scale':list(PB[b].scale)} for b in ('wing.'+s,'wing_mid.'+s,'wing_tip.'+s)}
json.dump(res,open('work/wingfold.json','w'),indent=1)
if hide_ely:
    for s in 'LR': PB['elytron.'+s].scale=(0.001,0.001,0.001)
bpy.context.view_layer.update()
if len(a)>4 and a[4]=='wingonly':
    import bmesh
    ob=bpy.data.objects['Beetle']; me=ob.data; bm=bmesh.new(); bm.from_mesh(me)
    bmesh.ops.delete(bm,geom=[f for f in bm.faces if f.material_index!=2 and not (a[5:] and f.material_index==1)],context='FACES'); bm.to_mesh(me); bm.free()
    for bn in ('wing.R','wing.L'):
        pb=PB[bn]; print(bn,'head',tuple(round(x,2) for x in (ao.matrix_world@pb.head)),'tail',tuple(round(x,2) for x in (ao.matrix_world@pb.tail)))
    for bn in ('wing_mid.R','wing_tip.R'):
        pb=PB[bn]; print(bn,'head',tuple(round(x,2) for x in pb.head),'tail',tuple(round(x,2) for x in pb.tail))
sc=bpy.context.scene
cols={'Beetle_Body':(0.7,0.7,0.7,1),'Beetle_Elytra':(0.3,0.45,0.95,1),'Beetle_HindWing':(0.95,0.85,0.2,1),'Beetle_Membrane':(0.1,0.9,0.2,1)}
for m in bpy.data.materials:
    if m.name in cols: m.diffuse_color=cols[m.name]
sc.render.engine='BLENDER_WORKBENCH'; sh=sc.display.shading; sh.light='STUDIO'; sh.color_type='MATERIAL'; sh.show_backface_culling=False
sc.render.resolution_x=900; sc.render.resolution_y=640
cam=bpy.data.cameras.new('c'); co=bpy.data.objects.new('c',cam); sc.collection.objects.link(co); sc.camera=co; sc.world=bpy.data.worlds.new('w')
for n,p,t,lens in shots:
    rsetup.look(co,p,t,lens); sc.render.filepath=f'{out}_{n}.png'; bpy.ops.render.render(write_still=True)

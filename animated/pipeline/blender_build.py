import bpy, numpy as np, json, math, sys, os
from mathutils import Vector, Matrix
W='./work/'
OUT='../'
S=0.06; J=json.load(open(W+'joints.json')); GZ=J['ground_z']; XSHIFT=2.0
def T(p): p=np.asarray(p,float); return Vector((S*-p[1], S*(p[0]-XSHIFT), S*(p[2]-GZ)))
def TV(v): v=np.asarray(v,float); return Vector((-v[1],v[0],v[2]))
D=np.load(W+'final_geo.npz'); BJ=json.load(open(W+'final_bones.json'))
bpy.ops.wm.read_factory_settings(use_empty=True)
sc=bpy.context.scene; sc.unit_settings.system='METRIC'
# ---------------- materials
def img(name,fn,alpha=False,colorspace='sRGB'):
    im=bpy.data.images.load(OUT+'textures/'+fn); im.name=name
    im.filepath='//textures/'+fn
    return im
def mat_tex(name,im,rough,coat=0.0,alpha=False):
    m=bpy.data.materials.new(name); m.use_nodes=True; nt=m.node_tree
    b=nt.nodes['Principled BSDF']; t=nt.nodes.new('ShaderNodeTexImage'); t.image=im; t.location=(-400,200)
    nt.links.new(t.outputs['Color'],b.inputs['Base Color'])
    b.inputs['Roughness'].default_value=rough
    b.inputs['Coat Weight'].default_value=coat; b.inputs['Coat Roughness'].default_value=0.18
    b.inputs['Specular IOR Level'].default_value=0.5
    if alpha:
        nt.links.new(t.outputs['Alpha'],b.inputs['Alpha'])
        m.surface_render_method='BLENDED' if hasattr(m,'surface_render_method') else None
        m.use_backface_culling=False
    return m
m0=mat_tex('Beetle_Body',img('beetle_body','beetle_body.jpg'),0.42,0.3)
m1=mat_tex('Beetle_Elytra',img('beetle_elytra','beetle_elytra.jpg'),0.4,0.35)
m2=mat_tex('Beetle_HindWing',img('beetle_hindwing','beetle_hindwing.png'),0.45,0.0,alpha=True)
m3=bpy.data.materials.new('Beetle_Membrane'); m3.use_nodes=True
b=m3.node_tree.nodes['Principled BSDF']; b.inputs['Base Color'].default_value=(0.035,0.018,0.012,1); b.inputs['Roughness'].default_value=0.55
# ---------------- mesh
V=D['V']; F=D['F']; UV=D['UV'].copy(); UV[:,1]=1-UV[:,1]
me=bpy.data.meshes.new('Beetle')
me.vertices.add(len(V)); me.vertices.foreach_set('co',V.astype(np.float32).ravel())
me.loops.add(len(F)*3); me.loops.foreach_set('vertex_index',F.astype(np.int32).ravel())
me.polygons.add(len(F)); me.polygons.foreach_set('loop_start',np.arange(0,len(F)*3,3,dtype=np.int32)); me.polygons.foreach_set('loop_total',np.full(len(F),3,np.int32))
me.polygons.foreach_set('material_index',D['MAT'].astype(np.int32))
uv=me.uv_layers.new(name='UVMap'); uv.data.foreach_set('uv',UV[F.ravel()].astype(np.float32).ravel())
me.polygons.foreach_set('use_smooth',np.ones(len(F),bool))
me.update(calc_edges=True)
for m in (m0,m1,m2,m3): me.materials.append(m)
ob=bpy.data.objects.new('Beetle',me); sc.collection.objects.link(ob)
# ---------------- armature
arm=bpy.data.armatures.new('BeetleRig'); ao=bpy.data.objects.new('BeetleRig',arm); sc.collection.objects.link(ao)
arm.display_type='STICK'
bpy.context.view_layer.objects.active=ao; ao.select_set(True)
bpy.ops.object.mode_set(mode='EDIT')
E=arm.edit_bones
def nb(name,h,t,parent=None,deform=True,up=(0,0,1),connect=False):
    e=E.new(name); e.head=h; e.tail=t
    if parent: e.parent=E[parent]; e.use_connect=connect
    e.use_deform=deform
    e.align_roll(Vector(up)); return e
nb('root',Vector((0,0,0)),Vector((0,-0.9,0)),up=(0,0,1))
nb('body',T((2,0,-2)),T((-5,0,1)),'root')
nb('pronotum',T((-5,0,1)),T((-19.5,0,2.5)),'body')
nb('head',T((-19.5,0,2.5)),T((-27,0,3.5)),'pronotum')
nb('abdomen',T((ABD:=16.4,0,-3.5)),T((27,0,-4.5)),'body')
for s in 'LR':
    a=J['A'+s]
    nb('antenna.'+s,T(a['base']),T(a['mid']),'head')
    nb('antenna_club.'+s,T(a['mid']),T(a['tip']),'antenna.'+s)
    e=J['ely'+s]; p=T(e['pivot']); ax=TV(e['axis']).normalized()
    lat=Vector((1 if s=='L' else -1,0,0))
    nb('elytron.'+s,p,p+ax*0.45,'body',up=lat)
    w=J['wing'+s]; r=T(w['root']); tp=T(w['tip']); d=tp-r
    wv=V[D['VB']==BJ['bones'].index('wing.'+s)]; rr=np.array(r); dd=np.array(d); uu=((wv-rr)@dd)/(dd@dd)
    def wnormal(lo,hi):
        Q=wv[(uu>=lo)&(uu<hi)]; _,_,vt=np.linalg.svd(Q-Q.mean(0),full_matrices=False); n=vt[2]
        return Vector(n if n[2]>0 else -n)
    nb('wing.'+s,r,r+d*0.42,'body',up=wnormal(0,0.42))
    nb('wing_mid.'+s,r+d*0.42,r+d*0.72,'wing.'+s,up=wnormal(0.42,0.72),connect=True)
    nb('wing_tip.'+s,r+d*0.72,tp,'wing_mid.'+s,up=wnormal(0.72,1.01),connect=True)
    for L,leg in (('F','front'),('M','mid'),('H','hind')):
        j=J[L+s]; par='pronotum' if leg=='front' else 'body'
        chain=[('femur','hip','knee'),('tibia','knee','ankle'),('tarsus1','ankle','t2'),('tarsus2','t2','claw'),('claw','claw','tip')]
        prev=par
        for seg,a0,a1 in chain:
            nb(f'{leg}_{seg}.{s}',T(j[a0]),T(j[a1]),prev,connect=(prev!=par)); prev=f'{leg}_{seg}.{s}'
        # controls
        c=T(j['claw']); 
        nb(f'foot_ik.{leg}.{s}',c,c+Vector((0,0,0.35)),'root',deform=False,up=(0,-1,0))
        for tn,key in (('ankle_tgt','ankle'),('t2_tgt','t2'),('claw_tgt','claw'),('tip_tgt','tip')):
            p=T(j[key]); nb(f'{tn}.{leg}.{s}',p,p+Vector((0,0,0.12)),f'foot_ik.{leg}.{s}',deform=False)
        kn=T(j['knee']); out=Vector((1 if s=='L' else -1,0,0))
        nb(f'pole.{leg}.{s}',kn+out*0.9+Vector((0,0,0.9)),kn+out*0.9+Vector((0,0,1.1)),'body',deform=False)
bpy.ops.object.mode_set(mode='POSE')
def signed_angle(u,v,n):
    a=u.angle(v); 
    if u.cross(v).angle(n)<1: a=-a
    return a
def pole_angle(base,ik,pole):
    pn=(ik.tail-base.head).cross(pole-base.head); proj=pn.cross(base.tail-base.head)
    return signed_angle(base.x_axis,proj,base.tail-base.head)
PB=ao.pose.bones
for s in 'LR':
    for leg in ('front','mid','hind'):
        tib=PB[f'{leg}_tibia.{s}']; c=tib.constraints.new('IK'); c.target=ao; c.subtarget=f'ankle_tgt.{leg}.{s}'
        c.chain_count=2; c.pole_target=ao; c.pole_subtarget=f'pole.{leg}.{s}'
        c.pole_angle=pole_angle(arm.bones[f'{leg}_femur.{s}'],arm.bones[f'{leg}_tibia.{s}'],arm.bones[f'pole.{leg}.{s}'].head_local)
        for seg,tg in (('tarsus1','t2_tgt'),('tarsus2','claw_tgt'),('claw','tip_tgt')):
            d=PB[f'{leg}_{seg}.{s}'].constraints.new('DAMPED_TRACK'); d.target=ao; d.subtarget=f'{tg}.{leg}.{s}'
for pb in PB: pb.rotation_mode='QUATERNION'
bpy.ops.object.mode_set(mode='OBJECT')
# ---------------- weights
bones=BJ['bones']; VB=D['VB']
groups={}
def grp(n):
    if n not in groups: groups[n]=ob.vertex_groups.new(name=n)
    return groups[n]
wingmask=np.zeros(len(V),bool)
for bi,bn in enumerate(bones):
    idx=np.where(VB==bi)[0]
    if bn.startswith('wing.'):
        s=bn[-1]; wingmask[idx]=True
        r=np.array(T(J['wing'+s]['root'])); tp=np.array(T(J['wing'+s]['tip'])); d=tp-r
        u=((V[idx]-r)@d)/(d@d)
        def ramp(x,a,b): return np.clip((x-a)/(b-a),0,1)
        w_mid=ramp(u,0.385,0.455)*(1-ramp(u,0.685,0.755)); w_tip=ramp(u,0.685,0.755); w_root=1-ramp(u,0.385,0.455)
        for gname,w in (('wing.'+s,w_root),('wing_mid.'+s,w_mid),('wing_tip.'+s,w_tip)):
            g=grp(gname)
            for val in np.unique(np.round(w,3)):
                if val<=0: continue
                sel=idx[np.round(w,3)==val]; g.add(sel.tolist(),float(val),'REPLACE')
    else:
        grp(bn).add(idx.tolist(),1.0,'REPLACE')
mod=ob.modifiers.new('Armature','ARMATURE'); mod.object=ao
ob.parent=ao
bpy.ops.wm.save_as_mainfile(filepath=OUT+'rhinoceros_beetle.blend',relative_remap=True)
print('saved; bones',len(arm.bones))

import bpy, math
from mathutils import Vector, Matrix
def setup(engine='CYCLES',samples=32,res=(1280,720),ground=True):
    sc=bpy.context.scene
    sc.render.engine=engine
    if engine=='CYCLES':
        sc.cycles.device='CPU'; sc.cycles.samples=samples; sc.cycles.use_denoising=True
        sc.cycles.max_bounces=4; sc.cycles.transparent_max_bounces=16
        try: sc.cycles.denoiser='OPENIMAGEDENOISE'
        except: pass
    sc.render.resolution_x,sc.render.resolution_y=res
    sc.view_settings.view_transform='AgX'; sc.view_settings.look='AgX - Medium High Contrast'
    w=bpy.data.worlds.new('Sky'); sc.world=w; w.use_nodes=True; nt=w.node_tree
    bg=nt.nodes['Background']; sky=nt.nodes.new('ShaderNodeTexSky')
    try: sky.sky_type='NISHITA'
    except: pass
    try:
        sky.sun_elevation=math.radians(38); sky.sun_rotation=math.radians(140); sky.air_density=1.2; sky.sun_disc=False
    except: pass
    nt.links.new(sky.outputs['Color'],bg.inputs['Color']); bg.inputs['Strength'].default_value=0.06
    sun=bpy.data.lights.new('Sun','SUN'); sun.energy=3.2; sun.angle=math.radians(2.5); sun.color=(1,0.96,0.9)
    so=bpy.data.objects.new('Sun',sun); sc.collection.objects.link(so); so.rotation_euler=(math.radians(52),0,math.radians(140))
    fill=bpy.data.lights.new('Fill','AREA'); fill.energy=600; fill.size=6; fill.color=(0.75,0.85,1.0)
    fo=bpy.data.objects.new('Fill',fill); sc.collection.objects.link(fo); fo.location=(-7,-6,5); fo.rotation_euler=Vector((7,6,-4)).to_track_quat('Z','Y').to_euler()
    rim=bpy.data.lights.new('Rim','AREA'); rim.energy=900; rim.size=4; rim.color=(1,0.9,0.8)
    ro=bpy.data.objects.new('Rim',rim); sc.collection.objects.link(ro); ro.location=(4,9,6); ro.rotation_euler=Vector((-4,-9,-5)).to_track_quat('Z','Y').to_euler()
    if ground:
        me=bpy.data.meshes.new('Ground'); s=60
        me.from_pydata([(-s,-s,0),(s,-s,0),(s,s,0),(-s,s,0)],[],[(0,1,2,3)])
        g=bpy.data.objects.new('Ground',me); sc.collection.objects.link(g)
        m=bpy.data.materials.new('Ground'); m.use_nodes=True; nt=m.node_tree; b=nt.nodes['Principled BSDF']
        n=nt.nodes.new('ShaderNodeTexNoise'); n.inputs['Scale'].default_value=2.5; n.inputs['Detail'].default_value=12
        cr=nt.nodes.new('ShaderNodeValToRGB'); cr.color_ramp.elements[0].color=(0.16,0.13,0.10,1); cr.color_ramp.elements[1].color=(0.34,0.29,0.22,1)
        nt.links.new(n.outputs['Fac'],cr.inputs['Fac']); nt.links.new(cr.outputs['Color'],b.inputs['Base Color'])
        bm=nt.nodes.new('ShaderNodeBump'); n2=nt.nodes.new('ShaderNodeTexNoise'); n2.inputs['Scale'].default_value=18; n2.inputs['Detail'].default_value=8
        nt.links.new(n2.outputs['Fac'],bm.inputs['Height']); bm.inputs['Strength'].default_value=0.35; nt.links.new(bm.outputs['Normal'],b.inputs['Normal'])
        b.inputs['Roughness'].default_value=0.9; g.data.materials.append(m)
    cam=bpy.data.cameras.new('Cam'); co=bpy.data.objects.new('Cam',cam); sc.collection.objects.link(co); sc.camera=co
    cam.lens=40; cam.clip_start=0.05; cam.clip_end=500
    return co
def look(co,pos,target,lens=None):
    co.location=Vector(pos); d=(Vector(target)-Vector(pos)).normalized()
    co.rotation_euler=d.to_track_quat('-Z','Y').to_euler()
    if lens: co.data.lens=lens

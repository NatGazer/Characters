import bpy, os
W='./work/'
OUT='../'
bpy.ops.wm.open_mainfile(filepath=W+'game_stage1.blend')
for n in ('Beetle',):
    bpy.data.objects.remove(bpy.data.objects[n])
for m in list(bpy.data.materials): bpy.data.materials.remove(m)
for im in list(bpy.data.images): bpy.data.images.remove(im)
def img(fn,noncolor=False):
    im=bpy.data.images.load(os.path.abspath(OUT+'textures/game/'+fn)); im.reload()
    if noncolor: im.colorspace_settings.name='Non-Color'
    return im
ao=bpy.data.objects['BeetleRig']
m=bpy.data.materials.new('Beetle_Game'); m.use_nodes=True; nt=m.node_tree; b=nt.nodes['Principled BSDF']
t=nt.nodes.new('ShaderNodeTexImage'); t.image=img('beetle_game_albedo.jpg'); nt.links.new(t.outputs['Color'],b.inputs['Base Color'])
tn=nt.nodes.new('ShaderNodeTexImage'); tn.image=img('beetle_game_normal.png',True); nm=nt.nodes.new('ShaderNodeNormalMap')
nt.links.new(tn.outputs['Color'],nm.inputs['Color']); nt.links.new(nm.outputs['Normal'],b.inputs['Normal'])
b.inputs['Roughness'].default_value=0.4; b.inputs['Coat Weight'].default_value=0.3; b.inputs['Coat Roughness'].default_value=0.18
mw=bpy.data.materials.new('Beetle_Game_Wings'); mw.use_nodes=True; nt=mw.node_tree; b=nt.nodes['Principled BSDF']
t=nt.nodes.new('ShaderNodeTexImage'); t.image=img('beetle_game_wing.png'); nt.links.new(t.outputs['Color'],b.inputs['Base Color']); nt.links.new(t.outputs['Alpha'],b.inputs['Alpha'])
b.inputs['Roughness'].default_value=0.45; mw.use_backface_culling=False
try: mw.surface_render_method='BLENDED'
except: pass
for name,mat in (('Beetle_Game_Body',m),('Beetle_Game_Wings',mw)):
    o=bpy.data.objects[name]; print(name,'invalid fixed:',o.data.validate(verbose=False)); o.data.materials.clear(); o.data.materials.append(mat)
    for md in list(o.modifiers): o.modifiers.remove(md)
    md=o.modifiers.new('Armature','ARMATURE'); md.object=ao; o.parent=ao
bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(OUT+'rhinoceros_beetle_game.blend'),relative_remap=True)
# store texture paths relative to the .blend so the file is portable
for im in bpy.data.images:
    if im.filepath: im.filepath = bpy.path.relpath(bpy.path.abspath(im.filepath))
bpy.ops.wm.save_mainfile()
print('saved game blend')

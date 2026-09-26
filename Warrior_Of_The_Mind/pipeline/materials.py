"""Blender materials from the generated textures (for previews/renders and glTF export).

Five materials: M_Armor, M_Cloth (alpha clip, double-sided), M_Body (skin SSS + undersuit + gauntlets),
M_Hair (alpha, anisotropic-ish), M_Eyes (emissive iris). Every object's slots collapse to one material.
"""
import os
import bpy
import uvlayout

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
TEX = os.path.join(ROOT, 'textures')
EMISSION_STRENGTH = {'M_Armor': 4.0, 'M_Cloth': 3.0, 'M_Body': 3.0, 'M_Eyes': 1.2, 'M_Hair': 0.0}

def img(name, colorspace='sRGB'):
    p = os.path.join(TEX, name)
    im = bpy.data.images.get(name) or bpy.data.images.load(p, check_existing=True)
    im.colorspace_settings.name = colorspace
    return im

def pbr(name, prefix, alpha=False, sss=False, emission=True):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree; nt.nodes.clear()
    out = nt.nodes.new('ShaderNodeOutputMaterial'); bs = nt.nodes.new('ShaderNodeBsdfPrincipled')
    nt.links.new(bs.outputs[0], out.inputs[0])
    uv = nt.nodes.new('ShaderNodeUVMap'); uv.uv_map = 'UVMap'
    def tex(file, cs='sRGB'):
        t = nt.nodes.new('ShaderNodeTexImage'); t.image = img(file, cs); nt.links.new(uv.outputs[0], t.inputs[0]); return t
    a = tex(f'{prefix}_albedo.png')
    nt.links.new(a.outputs['Color'], bs.inputs['Base Color'])
    if alpha:
        nt.links.new(a.outputs['Alpha'], bs.inputs['Alpha'])
        m.blend_method = 'CLIP' if hasattr(m, 'blend_method') else None
        try: m.surface_render_method = 'DITHERED'
        except Exception: pass
    if os.path.exists(os.path.join(TEX, f'{prefix}_orm.png')):
        o = tex(f'{prefix}_orm.png', 'Non-Color')
        sep = nt.nodes.new('ShaderNodeSeparateColor'); nt.links.new(o.outputs['Color'], sep.inputs[0])
        nt.links.new(sep.outputs[1], bs.inputs['Roughness']); nt.links.new(sep.outputs[2], bs.inputs['Metallic'])
    if os.path.exists(os.path.join(TEX, f'{prefix}_normal.png')):
        n = tex(f'{prefix}_normal.png', 'Non-Color')
        nm = nt.nodes.new('ShaderNodeNormalMap'); nm.uv_map = 'UVMap'
        nt.links.new(n.outputs['Color'], nm.inputs['Color']); nt.links.new(nm.outputs[0], bs.inputs['Normal'])
    if emission and os.path.exists(os.path.join(TEX, f'{prefix}_emission.png')):
        e = tex(f'{prefix}_emission.png')
        nt.links.new(e.outputs['Color'], bs.inputs['Emission Color'])
        bs.inputs['Emission Strength'].default_value = EMISSION_STRENGTH.get(name, 3.0)
    if sss and os.path.exists(os.path.join(TEX, f'{prefix}_sss.png')):
        s = tex(f'{prefix}_sss.png', 'Non-Color')
        mul = nt.nodes.new('ShaderNodeMath'); mul.operation = 'MULTIPLY'; mul.inputs[1].default_value = 0.12
        nt.links.new(s.outputs['Color'], mul.inputs[0]); nt.links.new(mul.outputs[0], bs.inputs['Subsurface Weight'])
        bs.inputs['Subsurface Radius'].default_value = (1.0, 0.35, 0.2)
        bs.inputs['Subsurface Scale'].default_value = 0.006
    return m

def hair_material():
    m = pbr('M_Hair', 'hair', alpha=True, emission=False)
    bs = m.node_tree.nodes['Principled BSDF']
    bs.inputs['Roughness'].default_value = 0.42
    bs.inputs['Specular IOR Level'].default_value = 0.6
    try:
        bs.inputs['Anisotropic'].default_value = 0.7
    except Exception: pass
    return m

def eyes_material():
    m = pbr('M_Eyes', 'eye', emission=True)
    m.node_tree.nodes['Principled BSDF'].inputs['Roughness'].default_value = 0.05
    m.node_tree.nodes['Principled BSDF'].inputs['Coat Weight'].default_value = 1.0
    return m

def assign_all():
    mats = {'armor': pbr('M_Armor', 'armor'), 'cloth': pbr('M_Cloth', 'cloth', alpha=True),
            'body': pbr('M_Body', 'body', sss=True), 'hair': hair_material(), 'eyes': eyes_material()}
    for ob in bpy.data.objects:
        if ob.type != 'MESH': continue
        if ob.name == 'body': key = 'body'
        elif ob.name == 'eyes': key = 'eyes'
        elif ob.name.startswith(('hair', 'beard', 'brows')): key = 'hair'
        elif uvlayout.GROUPS['cloth'](ob): key = 'cloth'
        elif uvlayout.GROUPS['armor'](ob): key = 'armor'
        else: continue
        ob.data.materials.clear(); ob.data.materials.append(mats[key])
        ob.data.polygons.foreach_set('material_index', [0] * len(ob.data.polygons))
    return mats

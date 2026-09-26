"""Stage 2 of the game LOD: bake albedo / normal / wing alpha from the full-res scan."""
import bpy, bmesh, time, os
W = './work/'
OUT = '../'
TEX = OUT + 'textures/game/'
os.makedirs(TEX, exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=W + 'game_stage1.blend')
sc = bpy.context.scene
sc.render.engine = 'CYCLES'; sc.cycles.device = 'CPU'; sc.cycles.samples = 4
hi = bpy.data.objects['Beetle']; hi.modifiers['Armature'].show_render = False; hi.modifiers['Armature'].show_viewport = False
body = bpy.data.objects['Beetle_Game_Body']; wings = bpy.data.objects['Beetle_Game_Wings']
for o in (body, wings): o.data.materials.clear()

def split_hi(keep_wings):
    me = hi.data.copy(); o = bpy.data.objects.new('hi_' + ('w' if keep_wings else 'b'), me); sc.collection.objects.link(o)
    bm = bmesh.new(); bm.from_mesh(me)
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if (f.material_index == 2) != keep_wings], context='FACES')
    bm.to_mesh(me); bm.free(); return o
hi_b = split_hi(False); hi_w = split_hi(True)
hi.hide_render = True

def target_mat(obj, name, img):
    m = bpy.data.materials.new(name); m.use_nodes = True; nt = m.node_tree
    t = nt.nodes.new('ShaderNodeTexImage'); t.image = img; nt.nodes.active = t
    obj.data.materials.clear(); obj.data.materials.append(m)
    return m, t

def bake(src, dst, img, btype, **kw):
    m, t = target_mat(dst, 'bake_tmp', img)
    bpy.ops.object.select_all(action='DESELECT'); src.select_set(True); dst.select_set(True); bpy.context.view_layer.objects.active = dst
    t0 = time.time()
    bpy.ops.object.bake(type=btype, use_selected_to_active=True, cage_extrusion=0.035, max_ray_distance=0.12,
                        margin=12, margin_type='EXTEND', use_clear=True, **kw)
    print('baked', img.name, btype, round(time.time() - t0, 1), 's')
    bpy.data.materials.remove(m)

def newimg(name, res, alpha=False, noncolor=False):
    im = bpy.data.images.new(name, res, res, alpha=alpha, float_buffer=False)
    if noncolor: im.colorspace_settings.name = 'Non-Color'
    return im

alb = newimg('beetle_game_albedo', 4096)
bake(hi_b, body, alb, 'DIFFUSE', pass_filter={'COLOR'})
nrm = newimg('beetle_game_normal', 4096, noncolor=True)
bake(hi_b, body, nrm, 'NORMAL', normal_space='TANGENT')
walb = newimg('beetle_game_wing_albedo', 2048, alpha=True)
bake(hi_w, wings, walb, 'DIFFUSE', pass_filter={'COLOR'})
# wing alpha: temporarily make the hi-res wing material emit its alpha
wm = bpy.data.materials['Beetle_HindWing']; nt = wm.node_tree
tex = [n for n in nt.nodes if n.type == 'TEX_IMAGE'][0]; outn = [n for n in nt.nodes if n.type == 'OUTPUT_MATERIAL'][0]
em = nt.nodes.new('ShaderNodeEmission'); nt.links.new(tex.outputs['Alpha'], em.inputs['Color'])
old = outn.inputs['Surface'].links[0].from_socket; nt.links.new(em.outputs['Emission'], outn.inputs['Surface'])
wa = newimg('beetle_game_wing_alpha', 2048)
bake(hi_w, wings, wa, 'EMIT')
nt.links.new(old, outn.inputs['Surface'])
for im in (alb, nrm, walb, wa):
    im.filepath_raw = W + im.name + '.png'; im.file_format = 'PNG'; im.save()
print('saved raw bakes')

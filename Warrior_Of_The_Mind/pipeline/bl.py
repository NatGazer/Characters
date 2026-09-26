"""Blender (bpy) helpers shared by the build scripts."""
import os, math
import numpy as np
import bpy, bmesh
from mathutils import Vector, Matrix
import views

def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.unit_settings.system = 'METRIC'
    return sc

def mesh_from_np(name, V, F, uv=None, FT=None, collection=None, smooth=True):
    me = bpy.data.meshes.new(name)
    F = [list(map(int, f)) for f in F]
    me.from_pydata([tuple(map(float, v)) for v in V], [], F)
    if uv is not None:
        uvl = me.uv_layers.new(name='UVMap')
        if FT is None:  # per-vertex uv
            loops = np.zeros(len(me.loops), int); me.loops.foreach_get('vertex_index', loops)
            uvl.data.foreach_set('uv', np.asarray(uv)[loops].ravel())
        else:
            ft = np.concatenate([np.asarray(f) for f in FT])
            uvl.data.foreach_set('uv', np.asarray(uv)[ft].ravel())
    me.update()
    if smooth:
        me.polygons.foreach_set('use_smooth', [True] * len(me.polygons))
    ob = bpy.data.objects.new(name, me)
    (collection or bpy.context.scene.collection).objects.link(ob)
    return ob

def mesh_to_np(ob, world=True, evaluated=False):
    if evaluated:
        dg = bpy.context.evaluated_depsgraph_get(); ob_e = ob.evaluated_get(dg); me = ob_e.to_mesh()
    else:
        me = ob.data
    V = np.zeros(len(me.vertices) * 3); me.vertices.foreach_get('co', V); V = V.reshape(-1, 3)
    if world:
        M = np.array(ob.matrix_world); V = V @ M[:3, :3].T + M[:3, 3]
    F = [list(p.vertices) for p in me.polygons]
    if evaluated: ob_e.to_mesh_clear()
    return V, F

def ref_camera(view, name=None, crop=None, res_scale=1.0):
    """Orthographic camera reproducing a reference view. crop=(u0,v0,u1,v1) in ref pixels."""
    img, sole, u0, ax, sg = views.VIEWS[view]
    sc = bpy.context.scene
    cam = bpy.data.objects.new(name or f'cam_{view}', bpy.data.cameras.new(name or f'cam_{view}'))
    sc.collection.objects.link(cam)
    cam.data.type = 'ORTHO'
    ua, va, ub, vb = crop or (0, 0, 1024, 1536)
    w, h = ub - ua, vb - va
    cam.data.ortho_scale = max(w, h) * views.S
    cu, cv = (ua + ub) / 2, (va + vb) / 2
    look = Vector(views.LOOK[view])
    P = Vector(views.unproject(view, cu, cv, 0.0)) - look * 10
    cam.location = P
    cam.rotation_euler = look.to_track_quat('-Z', 'Y').to_euler()
    cam.data.clip_start = 0.1; cam.data.clip_end = 30
    sc.render.resolution_x = int(round(w * res_scale)); sc.render.resolution_y = int(round(h * res_scale))
    sc.render.pixel_aspect_x = sc.render.pixel_aspect_y = 1
    sc.camera = cam
    return cam

def workbench(sc, studio=True, color=(0.8, 0.6, 0.5)):
    sc.render.engine = 'BLENDER_WORKBENCH'
    sh = sc.display.shading
    sh.light = 'STUDIO' if studio else 'FLAT'
    sh.color_type = 'SINGLE'; sh.single_color = color
    sh.show_cavity = True; sh.cavity_type = 'BOTH'
    sc.display.render_aa = '8'
    sc.render.film_transparent = False
    sc.view_settings.view_transform = 'Standard'

def render(path):
    sc = bpy.context.scene
    sc.render.filepath = path
    sc.render.image_settings.file_format = 'PNG'
    bpy.ops.render.render(write_still=True)

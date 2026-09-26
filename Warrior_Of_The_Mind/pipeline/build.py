"""Assemble the full-resolution Warrior of the Mind model (geometry only) -> work/model_raw.blend.

Order: body (MakeHuman, fitted) -> eyes -> armour -> details -> cloth -> hair (collides with the rest).
Material slot names encode the texture class used by bake_textures.py.
"""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, bpy
import bl, kit, armor, cloth, hair, mh

HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, 'work')

def body_object(B):
    ob = bl.mesh_from_np('body', B.V, B.F, uv=B.VT, FT=B.FT)
    # regions: skin (head+neck), gauntlet (hands), undersuit (rest)
    mats = ['skin', 'undersuit', 'gauntlet']
    for m in mats: ob.data.materials.append(bpy.data.materials.get(m) or bpy.data.materials.new(m))
    fw = lambda seg: B.w[seg][B.F].mean(1)
    head = fw('head') + fw('neck')
    hands = fw('hand.L') + fw('hand.R')
    idx = np.ones(len(B.F), int)
    idx[head > 0.5] = 0
    # the neck above the collar is skin; below it is undersuit
    zc = B.V[B.F].mean(1)[:, 2]
    idx[(head > 0.3) & (zc > 1.735)] = 0
    idx[(idx == 0) & (zc < 1.705)] = 1
    idx[hands > 0.5] = 2
    ob.data.polygons.foreach_set('material_index', idx.tolist())
    ob.data.update()
    return ob

def eyes_object(B):
    clo = mh.load_mhclo(os.path.join(mh.MH, 'eyes', 'high-poly', 'high-poly.mhclo'))
    V, VT, F, FT, G = mh.load_obj(clo['obj'])
    P = mh.fit_proxy(clo, B.V)
    # drop the cornea shell (its uvs sit on the transparent disc in the texture corner)
    keep = [i for i, ft in enumerate(FT) if np.hypot(*(VT[ft].mean(0) - [0.935, 0.07])) > 0.075]
    F = [F[i] for i in keep]; FT = [FT[i] for i in keep]
    ob = bl.mesh_from_np('eyes', P, F, uv=VT, FT=FT)
    ob.data.materials.append(bpy.data.materials.get('eye') or bpy.data.materials.new('eye'))
    return ob

def build(save=True):
    sc = bl.reset()
    B = kit.Body()
    body = body_object(B)
    eyes = eyes_object(B)
    tor = armor.build_torso(B); arms = armor.build_arms(B); legs = armor.build_legs(B)
    det = armor.build_details(B)
    cl = cloth.build_cloth(B)
    cols = [body] + tor + [o for o in cl if o.name.startswith(('cape', 'stole'))]
    hob, X = hair.build_hair(B, cols)
    np.save(os.path.join(W, 'hair_strands.npy'), X)
    hair.build_beard(B); hair.build_goatee(B)
    if save:
        bpy.ops.wm.save_as_mainfile(filepath=os.path.join(W, 'model_raw.blend'))
    tris = sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in bpy.data.objects if o.type == 'MESH')
    print('objects', len([o for o in bpy.data.objects if o.type == 'MESH']), 'triangles', tris)
    return B

if __name__ == '__main__':
    build()

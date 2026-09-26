import bpy, numpy as np
from mathutils.bvhtree import BVHTree
from mathutils import Vector
D=np.load('work/main_weld.npz'); P=D['P']; F=D['F']
bvh=BVHTree.FromPolygons([Vector(p) for p in P],F.tolist())
vis=np.zeros(len(P),bool); dn=Vector((0,0,-1))
for i in np.where((P[:,2]<4)&(np.abs(P[:,1])<21)&(P[:,0]>-14)&(P[:,0]<22))[0]:
    loc,n,idx,dist=bvh.ray_cast(Vector(P[i])+dn*0.03,dn,60)
    vis[i]= idx is None
np.save('work/downvis.npy',vis); print(vis.sum())

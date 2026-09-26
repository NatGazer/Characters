import bpy
import numpy as np, lab, gl
from mathutils.bvhtree import BVHTree
from mathutils import Vector
W=np.load('work/wb_weld.npz'); PW=W['P']; FW=W['F']; fl=np.load('work/wb_elytra_flab.npy')
r=np.load('work/wb_icp.npy',allow_pickle=True).item(); X=r['s']*PW@r['R'].T+r['t']
E=[np.load(f'work/ely_fit_{s}.npz') for s in 'RL']
EP=np.r_[E[0]['P'],E[1]['P']]; EF=np.r_[E[0]['F'],E[1]['F']+len(E[0]['P'])]
bodyF=FW[fl==0]
CP=np.r_[X,EP]; CF=np.r_[bodyF,EF+len(X)]
bvh=BVHTree.FromPolygons([Vector(p) for p in CP],CF.tolist())
nb=len(bodyF)
used=np.zeros(len(X),bool); used[np.unique(bodyF)]=True
top=np.zeros(len(X),bool); gap=np.full(len(X),np.nan)
up=Vector((0,0,1))
for i in np.where(used&(X[:,0]>-8))[0]:
    o=Vector(X[i])+up*0.02
    loc,n,idx,dist=bvh.ray_cast(o,up,40)
    if idx is not None and idx>=nb: top[i]=True; gap[i]=dist
print('top verts',top.sum())
np.save('work/wb_top.npy',top); np.save('work/wb_gap.npy',gap); np.save('work/wb_X.npy',X)
g=gap[top]; print('gap to elytra: min',np.nanmin(g).round(2),'median',np.nanmedian(g).round(2),'p5',np.nanquantile(g,.05).round(2))
fm=top[bodyF].all(1)
L=np.zeros(len(bodyF),int); L[fm]=3
lab.save('work/patch_view.npz',X,bodyF,L)

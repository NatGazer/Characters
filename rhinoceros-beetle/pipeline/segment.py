import numpy as np, json
from segparams import *
D=np.load('work/main_weld.npz'); P=D['P']; F=D['F']
em=np.load('work/main_ely_mask_R.npy')|np.load('work/main_ely_mask_L.npy')
names=['body','pronotum','head']
vl=np.zeros(len(P),int)
X,Y,Z=P.T
# pronotum vs body: tilted plane
pro=X < (-3.3+(Z-11)*(2.2/17))
vl[pro]=1
# head: in front of saddle->ventral plane
n=np.array([10.4,0,2.8]); n/=np.linalg.norm(n); s=np.array([-21.3,0,8.9])
head=((P-s)@n<0)&((np.abs(Y)<6.5)|(X<-27))
vl[head]=2
# antennae
for a,(b1,b2) in ANTBP.items():
    d=np.load(f'work/gd_{a}.npy')
    for k,(lo,hi,nm) in enumerate([(0,b1,a+'_club'),(b1,b2,a+'_stalk')]):
        names.append(nm); vl[(d>=lo)&(d<hi)]=len(names)-1
# legs
for leg,bp in LEGBP.items():
    d=np.load(f'work/gd_{leg}.npy'); lo=0
    for seg,hi in zip(SEGS,bp):
        names.append(leg+'_'+seg); vl[(d>=lo)&(d<hi)]=len(names)-1; lo=hi
vis=np.load('work/downvis.npy')
for leg,(a,b,hw) in FEMBAND.items():
    a=np.array(a);b=np.array(b); ab=b-a; t=np.clip(((P[:,:2]-a)@ab)/(ab@ab),0,1)
    dxy=np.linalg.norm(P[:,:2]-(a+t[:,None]*ab),axis=1)
    sel=(dxy<hw)&vis&(vl<=1)&(Z<2)
    vl[sel]=names.index(leg+'_femur')
vl[em]=-1
np.save('work/vlab.npy',vl); json.dump(names,open('work/names.json','w'))
# face labels: majority of vertex labels
fl=vl[F]; 
m=np.where((fl[:,0]==fl[:,1])|(fl[:,0]==fl[:,2]),fl[:,0],fl[:,1])
np.save('work/flab.npy',m)
print({nm:int((m==i).sum()) for i,nm in enumerate(names)}, 'removed',int((m==-1).sum()))

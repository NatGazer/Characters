import numpy as np, json
from segparams import *
D=np.load('work/main_weld.npz'); P=D['P']; F=D['F']
fl=np.load('work/flab_clean.npy'); names=json.load(open('work/names.json'))
vlab=-np.ones(len(P),int); vlab[F.ravel()]=np.repeat(fl,3)
J={}
def ring(d,x,w=0.5):
    m=np.abs(d-x)<w/2; return P[m].mean(0)
for leg,bp in LEGBP.items():
    d=np.load(f'work/gd_{leg}.npy')
    tips=[p for p in P[d<0.3]]; tip=np.mean(tips,0)
    J[leg]={'tip':tip,'claw':ring(d,bp[0]),'t2':ring(d,bp[1]),'ankle':ring(d,bp[2]),'knee':ring(d,bp[3])}
    fv=P[vlab==names.index(leg+'_femur')]
    if leg in FEMBAND:
        b=np.array(FEMBAND[leg][1]); near=fv[np.linalg.norm(fv[:,:2]-b,axis=1)<2.0]
        hip=np.r_[b, near[:,2].mean()+1.0]
    J[leg]['hip']=hip
for a,(b1,b2) in ANTBP.items():
    d=np.load(f'work/gd_{a}.npy'); J[a]={'tip':P[d<0.3].mean(0),'mid':ring(d,b1,0.4),'base':ring(d,b2,0.4)}
# elytra hinge
res=np.load('work/ely_icp.npy',allow_pickle=True).item()
for s in 'RL':
    R=res[s]['R']; t=res[s]['t']; w,v=np.linalg.eig(R); ax=np.real(v[:,np.argmin(np.abs(w-1))])
    if ax[2]<0: ax=-ax
    A=np.eye(3)-R; p=np.linalg.lstsq(np.r_[A,ax[None]],np.r_[t,0],rcond=None)[0]
    base=np.array([-3.3,8.0 if s=='R' else -8.0,5.0]); p=p+ax*((base-p)@ax)
    ang=np.degrees(np.arccos(np.clip((np.trace(R)-1)/2,-1,1)))
    # sign of rotation from closed->open around ax: open = R^T; angle about ax
    sgn=np.sign(ax@np.array([R[2,1]-R[1,2],R[0,2]-R[2,0],R[1,0]-R[0,1]]))
    J['ely'+s]={'pivot':p,'axis':ax,'open_angle':-sgn*ang}
# hindwing roots
X=np.load('work/ww_X.npy'); l=np.load('work/ww_comp.npy')
for k in (0,1):
    Q=X[l==k]; s='R' if Q[:,1].mean()>0 else 'L'; sg=1 if s=='R' else -1
    ay=np.abs(Q[:,1]); root=Q[ay<ay.min()+1.5].mean(0)
    far=Q[np.argmax(ay)]
    J['wing'+s]={'root':root,'tip':far}
J['head']={'pivot':np.array([-19.5,0,2.5])}
J['pronotum']={'pivot':np.array([-5.0,0,1.0])}
J['ground_z']=float(min(J[l]['tip'][2] for l in LEGBP))
def conv(o):
    if isinstance(o,dict): return {k:conv(v) for k,v in o.items()}
    if isinstance(o,np.ndarray): return [round(float(x),3) for x in o]
    return o
json.dump(conv(J),open('work/joints.json','w'),indent=1)
for k,v in conv(J).items(): print(k,v)

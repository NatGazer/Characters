import numpy as np, nonrigid as nr
from scipy.spatial import cKDTree
W0=np.load('work/main_weld.npz'); P=W0['P']; F=W0['F']; fl=np.load('work/flab_clean.npy')
rv=np.unique(F[fl==-1]); RP=P[rv]
for side,sg in (('R',1),('L',-1)):
    E=np.load(f'work/ely_fit_{side}.npz'); X=E['P'].copy(); FF=E['F']; outer=E['outer']
    tgt=RP[sg*RP[:,1]>-0.3]
    for it in range(6):
        O=np.where(outer)[0]; To=cKDTree(X[O]); Tt=cKDTree(tgt)
        acc=np.zeros((len(O),3)); cnt=np.zeros(len(O))
        d,j=Tt.query(X[O]); ok=d<2.0; acc[ok]+=tgt[j[ok]]-X[O][ok]; cnt[ok]+=1
        d2,j2=To.query(tgt); ok2=d2<3.0
        np.add.at(acc,j2[ok2],tgt[ok2]-X[O][j2[ok2]]); np.add.at(cnt,j2[ok2],1)
        has=cnt>0; disp=acc[has]/cnt[has][:,None]
        sig=[1.2,1.0,0.8,0.6,0.5,0.45][it]
        field,w=nr.smooth_field(X[O][has],disp,X,sigma=sig)
        X+=field*0.85
        d,_=To.query(tgt); dd,_=cKDTree(X[O]).query(tgt)
        print(side,it,'uncovered(>0.4)',(dd>0.4).sum(),'of',len(tgt),'mean',dd.mean().round(3))
    np.savez(f'work/ely_fit2_{side}.npz',P=X,F=FF,outer=outer)

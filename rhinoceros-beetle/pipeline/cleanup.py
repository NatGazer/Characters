import numpy as np, scipy.sparse as sp, scipy.sparse.csgraph as cg, json
D=np.load('work/main_weld.npz'); P=D['P']; F=D['F']; fl=np.load('work/flab.npy').copy()
names=json.load(open('work/names.json'))
nf=len(F)
# face adjacency through shared edges
E=np.concatenate([F[:,[0,1]],F[:,[1,2]],F[:,[2,0]]]); E=np.sort(E,1); fid=np.tile(np.arange(nf),3)
key=E[:,0].astype(np.int64)*len(P)+E[:,1]; o=np.argsort(key); ks=key[o]; fs=fid[o]
same=ks[1:]==ks[:-1]; a=fs[:-1][same]; b=fs[1:][same]
Adj=sp.coo_matrix((np.ones(len(a)),(a,b)),shape=(nf,nf)); Adj=(Adj+Adj.T).tocsr()
np.savez('work/faceadj.npz',a=a,b=b)
def neighbors_major(mask,lab):
    # for faces in mask, return most common neighbor label not in mask set
    pass
for it in range(6):
    changed=0
    # 1) majority smoothing (only among non-removed)
    for s in range(2 if it<2 else 0):
        rows=np.r_[a,b]; cols=np.r_[b,a]
        L=fl.copy(); nl=L[cols]
        # count votes per (row,label)
        K=len(names)+1
        M=sp.coo_matrix((np.ones(len(rows)),(rows,nl+1)),shape=(nf,K)).toarray()
        best=M.argmax(1)-1; strong=M.max(1)>=2
        upd=(fl>=0)&(best>=0)&strong&(best!=fl)&(M[np.arange(nf),fl+1]<=1)
        fl[upd]=best[upd]; changed+=upd.sum()
    # 2) islands
    for l in range(len(names)):
        idx=np.where(fl==l)[0]
        if len(idx)==0: continue
        sub=Adj[idx][:,idx]; n,c=cg.connected_components(sub,directed=False)
        if n<=1: continue
        big=np.bincount(c).argmax()
        for ci in range(n):
            if ci==big: continue
            if (c==ci).sum()>max(400,0.08*len(idx)): continue
            fi=idx[c==ci]
            nb=Adj[fi].indices; nb=nb[(fl[nb]!=l)&(fl[nb]>=0)]
            if len(nb)==0: continue
            fl[fi]=np.bincount(fl[nb]).argmax(); changed+=len(fi)
    print('iter',it,'changed',changed)
    if changed==0: break
np.save('work/flab_clean.npy',fl)
print({nm:int((fl==i).sum()) for i,nm in enumerate(names)})

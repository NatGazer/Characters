import numpy as np, scipy.sparse as sp, scipy.sparse.csgraph as cg
def graph(P,F):
    e=np.concatenate([F[:,[0,1]],F[:,[1,2]],F[:,[2,0]]]); e=np.unique(np.sort(e,1),axis=0)
    w=np.linalg.norm(P[e[:,0]]-P[e[:,1]],axis=1)
    n=len(P); A=sp.coo_matrix((np.r_[w,w],(np.r_[e[:,0],e[:,1]],np.r_[e[:,1],e[:,0]])),shape=(n,n)).tocsr()
    return A,e
def dist(A,src): return cg.dijkstra(A,indices=src,min_only=True)

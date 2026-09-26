import numpy as np
from scipy.spatial import cKDTree
def affine_icp(src,dst,A,t,iters=40,trim=0.85):
    Td=cKDTree(dst)
    for i in range(iters):
        X=src@A.T+t; Tx=cKDTree(X)
        d1,j1=Td.query(X); k1=d1<=np.quantile(d1,trim)
        d2,j2=Tx.query(dst); k2=d2<=np.quantile(d2,trim)
        S=np.r_[src[k1],src[j2[k2]]]; B=np.r_[dst[j1[k1]],dst[k2]]
        H=np.c_[S,np.ones(len(S))]; sol,*_=np.linalg.lstsq(H,B,rcond=None)
        A=sol[:3].T; t=sol[3]
    return A,t
def vnormals(P,F):
    n=np.cross(P[F[:,1]]-P[F[:,0]],P[F[:,2]]-P[F[:,0]]); N=np.zeros_like(P)
    for k in range(3): np.add.at(N,F[:,k],n)
    return N/np.maximum(np.linalg.norm(N,axis=1,keepdims=True),1e-12)
def smooth_field(pts,vals,query,sigma):
    T=cKDTree(pts); out=np.zeros((len(query),vals.shape[1])); w=np.zeros(len(query))
    nb=T.query_ball_point(query,3*sigma)
    for i,js in enumerate(nb):
        if not js: continue
        js=np.array(js); ww=np.exp(-np.sum((pts[js]-query[i])**2,1)/(2*sigma**2))
        out[i]=ww@vals[js]; w[i]=ww.sum()
    return out/np.maximum(w,1e-12)[:,None], w

import numpy as np
from scipy.spatial import cKDTree
def umeyama(A,B,scale=True):
    ma,mb=A.mean(0),B.mean(0); A0,B0=A-ma,B-mb
    H=A0.T@B0/len(A); U,S,Vt=np.linalg.svd(H); d=np.sign(np.linalg.det(Vt.T@U.T))
    Dm=np.diag([1,1,d]); R=Vt.T@Dm@U.T
    s=(S*np.diag(Dm)).sum()/((A0**2).sum()/len(A)) if scale else 1.0
    t=mb-s*R@ma; return s,R,t
def icp(src,dst,s=1,R=np.eye(3),t=np.zeros(3),iters=60,trim=0.85,scale=True,Tdst=None):
    T=Tdst or cKDTree(dst)
    for i in range(iters):
        X=s*src@R.T+t; d,j=T.query(X)
        k=d<=np.quantile(d,trim)
        s,R,t=umeyama(src[k],dst[j[k]],scale)
    X=s*src@R.T+t; d,j=T.query(X)
    return s,R,t,np.sqrt((np.sort(d)[:int(len(d)*trim)]**2).mean())
def pca_inits(src,dst):
    ms,md=src.mean(0),dst.mean(0)
    _,_,Vs=np.linalg.svd(src-ms,full_matrices=False); _,_,Vd=np.linalg.svd(dst-md,full_matrices=False)
    out=[]
    for sx in (1,-1):
        for sy in (1,-1):
            S=np.diag([sx,sy,sx*sy]) 
            R=Vd.T@S@Vs
            if np.linalg.det(R)<0: continue
            out.append((R, md-R@ms))
    return out
def pca_inits2(src,dst):
    ms,md=src.mean(0),dst.mean(0)
    _,_,Vs=np.linalg.svd(src-ms,full_matrices=False); _,_,Vd=np.linalg.svd(dst-md,full_matrices=False)
    out=[]
    for sx in (1,-1):
        for sy in (1,-1):
            for sz in (1,-1):
                R=Vd.T@np.diag([sx,sy,sz])@Vs
                if np.linalg.det(R)>0: out.append((R,md-R@ms))
    return out
def icp_sym(src,dst,s,R,t,iters=40,trim=0.8):
    Ts=None; Td=cKDTree(dst)
    for i in range(iters):
        X=s*src@R.T+t; Tx=cKDTree(X)
        d1,j1=Td.query(X); k1=d1<=np.quantile(d1,trim)
        d2,j2=Tx.query(dst); k2=d2<=np.quantile(d2,trim)
        A=np.r_[src[k1],src[j2[k2]]]; B=np.r_[dst[j1[k1]],dst[k2]]
        s,R,t=umeyama(A,B,True)
    X=s*src@R.T+t; d1,_=Td.query(X); d2,_=cKDTree(X).query(dst)
    return s,R,t,np.sqrt((np.sort(d1)[:int(len(d1)*trim)]**2).mean()),np.sqrt((np.sort(d2)[:int(len(d2)*trim)]**2).mean())

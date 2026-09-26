import json, base64, numpy as np
def load(path):
    d=json.load(open(path)); buf=base64.b64decode(d['buffers'][0]['uri'].split(',',1)[1])
    def acc(i):
        a=d['accessors'][i]; bv=d['bufferViews'][a['bufferView']]
        n={'SCALAR':1,'VEC2':2,'VEC3':3}[a['type']]
        dt={5126:np.float32,5125:np.uint32,5123:np.uint16}[a['componentType']]
        off=bv.get('byteOffset',0)+a.get('byteOffset',0)
        return np.frombuffer(buf,dtype=dt,count=a['count']*n,offset=off).reshape(-1,n) if n>1 else np.frombuffer(buf,dtype=dt,count=a['count'],offset=off)
    out={}
    for m in d['meshes']:
        for k,p in enumerate(m['primitives']):
            P=acc(p['attributes']['POSITION']).astype(np.float64)
            P=np.stack([P[:,0],-P[:,2],P[:,1]],1)  # to blender z-up
            out[(m['name'],k)]=dict(P=P,UV=acc(p['attributes']['TEXCOORD_0']),F=acc(p['indices']).reshape(-1,3).astype(np.int64),mat=p.get('material'))
    return out,d,buf
def components(F,nv):
    import scipy.sparse as sp, scipy.sparse.csgraph as cg
    r=np.concatenate([F[:,0],F[:,1],F[:,2]]); c=np.concatenate([F[:,1],F[:,2],F[:,0]])
    A=sp.coo_matrix((np.ones(len(r)),(r,c)),shape=(nv,nv))
    return cg.connected_components(A,directed=False)
def weld(P,F,dec=7):
    u,inv=np.unique(np.round(P,dec),axis=0,return_inverse=True)
    return u, inv.reshape(-1)[F], inv.reshape(-1)

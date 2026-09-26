import numpy as np, json, gl, nonrigid as nr
import scipy.sparse as sp, scipy.sparse.csgraph as cg
from scipy.spatial import cKDTree
S=0.06; J=json.load(open('work/joints.json')); GZ=J['ground_z']; XSHIFT=2.0
def T(p): p=np.asarray(p,float); return S*np.stack([-p[...,1],p[...,0]-XSHIFT,p[...,2]-GZ],-1)
names=json.load(open('work/names.json'))
# ---------------- main mesh
Mm,_,_=gl.load("../../cc0-74mm-rhinoceros-beetle-t-dichotom/source/QS1296-W05-1all-7.gltf")
m=Mm[('QS1296-W01-1-1-updated',0)]; MP=m['P']*1000; MUV=m['UV']; MF=m['F']
W0=np.load('work/main_weld.npz'); WP=W0['P']; WF=W0['F']
fl=np.load('work/flab_clean.npy').copy()
ABD_X=16.4
names=names+['abdomen']; iabd=len(names)-1
cen=WP[WF].mean(1)
fl[(fl==0)&(cen[:,0]>ABD_X)]=iabd
# part label -> bone name
def bone_of(nm):
    if nm in('body','pronotum','head','abdomen'): return nm
    side='L' if nm[1]=='L' else 'R'
    if nm[0]=='A': return ('antenna_club.' if 'club' in nm else 'antenna.')+side
    leg={'F':'front','M':'mid','H':'hind'}[nm[0]]; seg=nm.split('_')[1]
    return f'{leg}_{seg}.{side}'
BONES_PART=[bone_of(n) for n in names]
# ---------------- wing model body
Wm,_,_=gl.load("../../wings/source/QS1462-W24-1-1_alpha.gltf")
wb=Wm[('body',0)]; WBUV=wb['UV']; WBF=wb['F']
Wb=np.load('work/wb_weld.npz'); WBP=Wb['P']; WBFw=Wb['F']; winv=Wb['inv']
efl=np.load('work/wb_elytra_flab.npy')
r=np.load('work/wb_icp.npy',allow_pickle=True).item(); WBX=r['s']*WBP@r['R'].T+r['t']   # welded, aligned
# elytra fitted positions (welded idx)
ELYP=WBX.copy()
for s,c in (('R',1),('L',2)):
    v=np.unique(WBFw[efl==c]); E=np.load(f'work/ely_fit2_{s}.npz'); ELYP[v]=E['P']
# --- straighten elytra base cut & extend base forward under pronotum
res_e=np.load('work/ely_icp.npy',allow_pickle=True).item()
Ewb0=np.concatenate([WBFw[:,[0,1]],WBFw[:,[1,2]],WBFw[:,[2,0]]]); fid0=np.tile(np.arange(len(WBFw)),3)
k0=np.sort(Ewb0,1); key0=k0[:,0].astype(np.int64)*len(WBP)+k0[:,1]; o0=np.argsort(key0); kk=key0[o0]
opp0=-np.ones(len(Ewb0),int); sm0=np.where(kk[1:]==kk[:-1])[0]; opp0[o0[sm0]]=fid0[o0[sm0+1]]; opp0[o0[sm0+1]]=fid0[o0[sm0]]
for s_,c_ in (('R',1),('L',2)):
    sg=1 if s_=='R' else -1
    bnd=(efl[fid0]==c_)&(opp0>=0)&(efl[np.maximum(opp0,0)]==0)
    bv=np.unique(Ewb0[bnd]); delta=np.zeros((len(bv),3)); delta[:,1]=sg*8.5-WBP[bv,1]
    rr=res_e[s_]; ELYP[bv]+=rr['s']*delta@rr['R'].T
    v=np.unique(WBFw[efl==c_]); xmin=np.quantile(ELYP[v,0],0.002)
    w=np.exp(-((ELYP[v,0]-xmin)/2.5)**2); ELYP[v,0]-=1.3*w; ELYP[v,2]-=0.25*w
# remnants of main elytra not covered by transplant -> ride with elytron
from scipy.spatial import cKDTree as _KD
ev=np.unique(WBFw[efl>0]); dR,_=_KD(ELYP[ev]).query(WP)
names+=['elyremR','elyremL']; iremR=len(names)-2; iremL=len(names)-1
BONES_PART+=['elytron.R','elytron.L']
unc=(fl==-1)&(dR[WF]>0.35).any(1)
cy=WP[WF].mean(1)[:,1]
fl[unc&(cy>=0)]=iremR; fl[unc&(cy<0)]=iremL
print('remnant faces',unc.sum())
# patch faces on wing body
top=np.load('work/wb_top.npy')
nfw=len(WBFw)
def face_adj(F,nv):
    E=np.concatenate([F[:,[0,1]],F[:,[1,2]],F[:,[2,0]]]); E=np.sort(E,1); fid=np.tile(np.arange(len(F)),3)
    key=E[:,0].astype(np.int64)*nv+E[:,1]; o=np.argsort(key); ks=key[o]; fs=fid[o]
    same=ks[1:]==ks[:-1]; a=fs[:-1][same]; b=fs[1:][same]
    A=sp.coo_matrix((np.ones(len(a)),(a,b)),shape=(len(F),len(F))); return (A+A.T).tocsr()
WA=face_adj(WBFw,len(WBP))
pm=(efl==0)&top[WBFw].all(1)
idx=np.where(pm)[0]; n,c=cg.connected_components(WA[idx][:,idx],directed=False); pm[:]=False; pm[idx[c==np.bincount(c).argmax()]]=True
# fill holes: complement comps among body faces that are small
comp=np.where((efl==0)&~pm)[0]; n,c=cg.connected_components(WA[comp][:,comp],directed=False); cnt=np.bincount(c)
for k in np.where(cnt<1500)[0]:
    fi=comp[c==k]; nb=WA[fi].indices
    if pm[nb].mean()>0.5 or True:
        # only if its neighbours are all patch (enclosed)
        nbl=nb[~np.isin(nb,fi)]
        if len(nbl) and pm[nbl].all(): pm[fi]=True
print('patch faces',pm.sum())
# snap patch rim to main body rim
MA=face_adj(WF,len(WP))
def boundary_edges(F,mask):
    FF=F[mask]; E=np.concatenate([FF[:,[0,1]],FF[:,[1,2]],FF[:,[2,0]]]); Es=np.sort(E,1)
    u,inv,cnt=np.unique(Es,axis=0,return_inverse=True,return_counts=True)
    return E[cnt[inv.ravel()]==1]
bodyish=np.isin(fl,[0,iabd])
# rim = body boundary edges adjacent to removed faces: take body boundary verts near removed verts
remv=np.zeros(len(WP),bool); remv[WF[np.isin(fl,[-1,iremR,iremL])].ravel()]=True
be=boundary_edges(WF,bodyish); rimv=np.unique(be[remv[be].all(1)])
print('rim verts',len(rimv))
pbe=boundary_edges(WBFw,pm); pbv=np.unique(pbe)
Tr=cKDTree(WP[rimv]); d,j=Tr.query(WBX[pbv])
ok=d<3.0; disp=np.zeros((len(pbv),3)); disp[ok]=WP[rimv][j[ok]]-WBX[pbv][ok]
pv=np.unique(WBFw[pm])
field,w=nr.smooth_field(WBX[pbv],disp,WBX[pv],sigma=1.2)
dB,_=cKDTree(WBX[pbv]).query(WBX[pv]); fall=np.exp(-(dB**2)/(2*1.5**2))
PATCHP=WBX.copy(); PATCHP[pv]+=field*fall[:,None]
# exact snap on boundary
PATCHP[pbv[ok]]=WP[rimv][j[ok]]
print('snapped',ok.sum(),'of',len(pbv))
# ---------------- hindwings
hw=Wm[('body',1)]; HWP=hw['P']*1000; HWUV=hw['UV']; HWF=hw['F']
HWX=r['s']*HWP@r['R'].T+r['t']
# ---------------- assemble parts
V=[];UV=[];Fs=[];MAT=[];VB=[]  # VB: bone name per vertex
bone_list=[]
def bidx(b):
    if b not in bone_list: bone_list.append(b)
    return bone_list.index(b)
off=0
def add(P,U,F,mat,bones):
    global off
    V.append(P);UV.append(U);Fs.append(F+off);MAT.append(np.full(len(F),mat));VB.append(bones); off+=len(P)
# main parts: per-face label -> vertices may be shared across labels at seams? main unwelded verts are per-UV-island;
# split by duplicating vertices per label
for li,nm in enumerate(names):
    fm=fl==li
    if not fm.any(): continue
    FF=MF[fm]; v=np.unique(FF); rm=-np.ones(len(MP),int); rm[v]=np.arange(len(v))
    add(MP[v],MUV[v],rm[FF],0,np.full(len(v),bidx(BONES_PART[li])))
# elytra (wing-body unwelded verts, positions via weld map)
for s,c in (('R',1),('L',2)):
    fm=efl==c; FF=WBF[fm]; v=np.unique(FF); rm=-np.ones(len(WBUV),int); rm[v]=np.arange(len(v))
    add(ELYP[winv[v]],WBUV[v],rm[FF],1,np.full(len(v),bidx('elytron.'+s)))
# patch split into body/abdomen
pc=PATCHP[WBFw].mean(1)
for bn,sel in (('body',pm&(pc[:,0]<=ABD_X)),('abdomen',pm&(pc[:,0]>ABD_X))):
    FF=WBF[sel]; v=np.unique(FF); rm=-np.ones(len(WBUV),int); rm[v]=np.arange(len(v))
    add(PATCHP[winv[v]],WBUV[v],rm[FF],1,np.full(len(v),bidx(bn)))
# hindwings: bones assigned later by span weights; store side
Wc=np.load('work/ww_comp.npy'); Ww=np.load('work/ww_weld.npz'); hinv=Ww['inv']
for k in (0,1):
    fm=Wc[hinv[HWF[:,0]]]==k
    # keep a single (dorsal) membrane layer: the scan has two layers ~0.1 mm apart
    A_=HWX[HWF[:,0]];B_=HWX[HWF[:,1]];C_=HWX[HWF[:,2]]; fn=np.cross(B_-A_,C_-A_); fn/=np.maximum(np.linalg.norm(fn,axis=1,keepdims=True),1e-12)
    cc=((A_+B_+C_)/3)[fm]; _,_,vt=np.linalg.svd(cc-cc.mean(0),full_matrices=False); wn=vt[2]*np.sign(vt[2][2])
    fm=fm&((fn@wn)>-0.3)
    FF=HWF[fm]; v=np.unique(FF); rm=-np.ones(len(HWP),int); rm[v]=np.arange(len(v))
    s='R' if HWX[v][:,1].mean()>0 else 'L'
    add(HWX[v],HWUV[v],rm[FF],2,np.full(len(v),bidx('wing.'+s)))
# ---------------- caps (welded topology)
def chains(E):
    # E: directed boundary edges (a->b) consistent with face winding; walk
    nxt={}
    for a,b in E: nxt.setdefault(a,[]).append(b)
    used=set(); out=[]
    starts=set(nxt.keys())-set(b for a,b in E)  # open chain starts
    order=list(starts)+list(nxt.keys())
    for s0 in order:
        if s0 in used or s0 not in nxt: continue
        ch=[s0]; used.add(s0); cur=s0
        while cur in nxt:
            cand=[b for b in nxt[cur] if b not in used]
            if not cand:
                if ch[0] in nxt[cur]: ch.append(ch[0])
                break
            cur=cand[0]; ch.append(cur); used.add(cur)
        if len(ch)>=4: out.append(ch)
    return out
PARENT={'pronotum':'body','head':'pronotum','abdomen':'body'}
for b in bone_list:
    if '.' in b:
        base,side=b.split('.')
        pr={'antenna':'head','antenna_club':'antenna'}.get(base)
        if pr: PARENT[b]=pr+'.'+side if pr!='head' else 'head'
        for leg in('front','mid','hind'):
            if base.startswith(leg):
                seg=base.split('_')[1]; ch=['femur','tibia','tarsus1','tarsus2','claw']
                PARENT[b]='pronotum' if (seg=='femur' and leg=='front') else ('body' if seg=='femur' else f'{leg}_{ch[ch.index(seg)-1]}.{side}')
capV=[];capF=[];capB=[]
import mapbox_earcut as earcut
def _earcut(L2):
    try: return np.asarray(earcut.triangulate_float64(L2.astype(np.float64),np.array([len(L2)],np.uint32))).reshape(-1,3)
    except Exception: return np.zeros((0,3),int)
def make_cap(P,loop,centroid_part,outward,bone,toward=None):
    L=P[loop]; closed=loop[0]==loop[-1]
    if closed: L=L[:-1]
    if len(L)<3: return
    c=L.mean(0); poly=np.r_[L,L[:1]]
    nrm=np.sum(np.cross(poly[:-1]-c,poly[1:]-c),0)
    if np.linalg.norm(nrm)<1e-9: return
    nrm/=np.linalg.norm(nrm)
    if toward is not None:
        if (toward-c)@nrm<0: nrm=-nrm       # nrm points toward the neighbouring part
    elif (c-centroid_part)@nrm<0: nrm=-nrm      # nrm points away from own part
    u=np.cross(nrm,[1,0,0] if abs(nrm[0])<0.9 else [0,1,0]); u/=np.linalg.norm(u); v=np.cross(nrm,u)
    rad=np.linalg.norm(L-c,axis=1).mean(); k=len(L)
    base=sum(len(x) for x in capV)
    if outward:
        # two-ring dome bulging toward the parent
        ring1=c+0.72*(L-c)+nrm*0.20*rad; ring2=c+0.38*(L-c)+nrm*0.34*rad
        VV=np.r_[L,ring1,ring2]; tris=[]
        for a0,a1 in ((0,k),(k,2*k)):
            for i in range(k if closed else k-1):
                i1=(i+1)%k; tris+= [(a0+i,a0+i1,a1+i1),(a0+i,a1+i1,a1+i)]
        L2=np.c_[(ring2-c)@u,(ring2-c)@v]; T2=_earcut(L2)+2*k
    else:
        VV=L.copy(); tris=[]
        L2=np.c_[(L-c)@u,(L-c)@v]; T2=_earcut(L2)
    T2=[tuple(t) for t in T2]
    TT=np.array(tris+T2,int) if (tris or T2) else np.zeros((0,3),int)
    if len(TT)==0: return
    # orient: cap normal should face away from own part (outward) => along nrm
    a,b_,cc=VV[TT[:,0]],VV[TT[:,1]],VV[TT[:,2]]; fn=np.cross(b_-a,cc-a)
    flip=(fn@nrm)<0; TT[flip]=TT[flip][:,[0,2,1]]
    capV.append(VV); capF.append(TT+base); capB.append(np.full(len(VV),bidx(bone)))
lab_bone=np.array([bidx(BONES_PART[li]) for li in range(len(names))])
fb=np.where(fl>=0,lab_bone[np.maximum(fl,0)],-1)
Ew=np.concatenate([WF[:,[0,1]],WF[:,[1,2]],WF[:,[2,0]]]); fid=np.tile(np.arange(len(WF)),3)
Es=np.sort(Ew,1); key=Es[:,0].astype(np.int64)*len(WP)+Es[:,1]
o=np.argsort(key); ks=key[o]
# map each half-edge to opposite face
opp=-np.ones(len(Ew),int)
same=np.where(ks[1:]==ks[:-1])[0]
opp[o[same]]=fid[o[same+1]]; opp[o[same+1]]=fid[o[same]]
ncap=0; capinfo=[]
for bi,b in enumerate(bone_list):
    if b.startswith(('elytron','wing')): continue
    myf=fb[fid]==bi
    oppb=np.where(opp>=0,fb[np.maximum(opp,0)],-2)
    bnd=myf&(oppb!=bi)&(oppb!=-2)   # -2: true scan boundary -> skip
    if not bnd.any(): continue
    cpart=WP[np.unique(WF[fb==bi])].mean(0)
    for ob in np.unique(oppb[bnd]):
        obn_=bone_list[ob] if ob>=0 else ''
        if (ob==-1 or obn_.startswith('elytron')) and b in('body','abdomen'): continue   # elytra rim -> patched
        E=Ew[bnd&(oppb==ob)][:,::-1]
        obn=bone_list[ob] if ob>=0 else None
        outward = (obn is not None and PARENT.get(b)==obn)
        tw=WP[np.unique(WF[fb==ob])].mean(0) if ob>=0 else None
        for ch in chains([tuple(e) for e in E]):
            make_cap(WP,np.array(ch),cpart,outward,b,tw); capinfo.append((b,obn,len(ch))); ncap+=1
# elytra base caps: boundary edges of elytron faces whose opposite wing face is body
Ewb=np.concatenate([WBFw[:,[0,1]],WBFw[:,[1,2]],WBFw[:,[2,0]]]); fidw=np.tile(np.arange(nfw),3)
Esb=np.sort(Ewb,1); keyb=Esb[:,0].astype(np.int64)*len(WBP)+Esb[:,1]; ob_=np.argsort(keyb); ksb=keyb[ob_]
oppw=-np.ones(len(Ewb),int); sm=np.where(ksb[1:]==ksb[:-1])[0]; oppw[ob_[sm]]=fidw[ob_[sm+1]]; oppw[ob_[sm+1]]=fidw[ob_[sm]]
for s,c in (('R',1),('L',2)):
    bnd=(efl[fidw]==c)&(oppw>=0)&(efl[np.maximum(oppw,0)]==0)
    E=Ewb[bnd][:,::-1]; cpart=ELYP[np.unique(WBFw[efl==c])].mean(0)
    for ch in chains([tuple(e) for e in E]): make_cap(ELYP,np.array(ch),cpart,False,'elytron.'+s); ncap+=1
print('caps',ncap)
np.savez('work/caps_dbg.npz',CV=np.concatenate(capV)*1,CF=np.concatenate(capF),CB=np.concatenate(capB))
CV=np.concatenate(capV); CF=np.concatenate(capF); CB=np.concatenate(capB)
add(CV,np.zeros((len(CV),2)),CF-0,3,CB)
V=np.concatenate(V); UV=np.concatenate(UV); F=np.concatenate(Fs); MAT=np.concatenate(MAT); VB=np.concatenate(VB)
Vt=T(V)
np.savez('work/final_geo.npz',V=Vt,UV=UV,F=F,MAT=MAT,VB=VB,Vmm=V)
json.dump({'bones':bone_list,'parent':PARENT},open('work/final_bones.json','w'),indent=1)
print('verts',len(Vt),'faces',len(F),'bones',bone_list)

import numpy as np
PAL0=np.array([[.75,.75,.75],[.9,.2,.2],[.2,.7,.2],[.2,.3,.9],[.9,.8,.1],[.8,.2,.8],[.1,.8,.8],[.95,.5,.1],[.5,.3,.1],[.4,.9,.4],[.6,.6,1],[1,.6,.7],[.3,.5,.3],[.7,.4,.9],[.9,.9,.6],[.2,.2,.5],[.6,.1,.1],[.1,.4,.6],[.8,.6,.3],[.5,.8,.1]])
def save(path,P,F,flab):
    # per-face labels -> split verts so colors are crisp
    FF=np.arange(len(F)*3).reshape(-1,3)
    PP=P[F.ravel()]; C=PAL[flab%len(PAL)].repeat(3,0)
    np.savez(path,P=PP,F=FF,C=C)

import colorsys
PAL=np.array([[.72,.72,.72]]+[colorsys.hsv_to_rgb((i*0.618034)%1,0.55+0.35*((i*7)%3)/2,0.95-0.25*((i*5)%2)) for i in range(1,64)])

"""Texture-side face alignment (the head geometry is kept as built by body_fit.py).

The model head is rendered with each reference camera (front, left, right) and MediaPipe finds the
478 face landmarks on the render and on the reference painting. The landmark pairs define a 2D
thin-plate-spline warp per view: model image position -> painting position. tex_body.py samples the
painting through this warp, so eyes, brows, nose, mouth and beard land exactly on the head's own
features without deforming the head.
Also writes the 3D landmark positions on the head (work/face_landmarks3d.npy, used for the beard).
Output: work/face_warp.npz
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import face_fit as FF

HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, 'work')

def main():
    d = np.load(os.path.join(W, 'body.npz'))
    V, F = d['V'], d['F']
    out = {}
    L3 = None
    for view in ('front', 'left', 'right'):
        Rv = FF.ref_lm(view)
        Mv = FF.model_lm(V, F, view, 'warp')
        if Rv is None or Mv is None:
            print(view, 'landmarks missing'); continue
        out[view + '_model'] = Mv[:, :2]; out[view + '_ref'] = Rv[:, :2]
        if view == 'front':
            L3 = FF.surface_points(V, F, 'front', Mv[:, :2])
        err = np.linalg.norm(Rv[:, :2] - Mv[:, :2], axis=1)
        print(f'{view}: landmark offset before warp: median {np.median(err):.1f} px, max {err.max():.1f} px')
    np.savez(os.path.join(W, 'face_warp.npz'), **out)
    ok = ~np.isnan(L3).any(1)
    L3[~ok] = np.nanmean(L3, axis=0)
    np.save(os.path.join(W, 'face_landmarks3d.npy'), L3)

if __name__ == '__main__':
    main()

"""Stronger chin on the chosen head (reference: a prominent, squared chin under the goatee).

Reads work/body_base.npz (the approved head, a copy of body_fit.py's body.npz) and writes work/body.npz
with the chin pushed forward and slightly down by a smooth local displacement. The lips, jaw corners
and neck are untouched. Idempotent: always starts from body_base.npz.
Run after body_fit.py (copy its body.npz to body_base.npz) and before face_warp.py.
"""
import os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, 'work')

CHIN_TIP = np.array([-0.0028, -0.1018, 1.7478])   # MediaPipe landmark 152 on the base head
FORWARD, DOWN = 0.014, 0.006                       # displacement at the centre (m); the head faces -Y
RADIUS = 0.026                                     # gaussian falloff
LIP_Z = (1.767, 1.777)                             # fades out between these heights (below the lower lip)

def smooth(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)

def sculpt(V):
    C = CHIN_TIP + np.array([0.0, 0.006, 0.010])    # inside the chin, a little above the tip
    d = np.linalg.norm((V - C) * [0.85, 1.0, 1.0], axis=1)   # slightly wider than tall: a square chin
    w = np.exp(-(d / RADIUS) ** 2)
    w *= 1.0 - smooth(*LIP_Z, V[:, 2])             # keep the lips
    w *= 1.0 - smooth(-0.075, -0.055, V[:, 1])      # front of the face only
    return V + w[:, None] * np.array([0.0, -FORWARD, -DOWN]), w

def main():
    d = dict(np.load(os.path.join(W, 'body_base.npz'), allow_pickle=True))
    d['V'], w = sculpt(d['V'])
    np.savez(os.path.join(W, 'body.npz'), **d)
    print(f'chin sculpt: {np.sum(w > 0.05)} vertices moved, max {np.max(w) * np.hypot(FORWARD, DOWN) * 1000:.1f} mm')

if __name__ == '__main__':
    main()

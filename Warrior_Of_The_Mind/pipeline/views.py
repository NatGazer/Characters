"""Reference-view calibration: maps Blender world (m) <-> reference image pixels.

All four turnaround views are treated as orthographic at S metres/pixel, aligned at the boot soles
and boot heel/toe extents (measured on the masks in stage0_segment)."""
import os
import numpy as np, cv2

S = 0.00134          # metres per reference pixel
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
REF = os.path.join(ROOT, 'Reference-Images'); MASKS = os.path.join(HERE, 'work', 'masks')

# name: (image, sole_v, u0, horizontal axis ('x' or 'y'), sign)   u = u0 + sign * coord / S
VIEWS = {
    'front': ('01_front_neutral', 1486, 502.0, 0, +1),
    'left':  ('02_left_profile_neutral', 1481, 500.0, 1, +1),
    'back':  ('03_back_neutral', 1489, 505.7, 0, -1),
    'right': ('04_right_profile_neutral', 1489, 522.0, 1, -1),
}
# camera look direction (unit vector from camera toward the character), for depth ordering
LOOK = {'front': (0, 1, 0), 'left': (-1, 0, 0), 'back': (0, -1, 0), 'right': (1, 0, 0)}

def project(view, P, scale=1.0):
    img, sole, u0, ax, sg = VIEWS[view]
    P = np.asarray(P)
    u = (u0 + sg * P[..., ax] / S) * scale
    v = (sole - P[..., 2] / S) * scale
    d = P @ np.array(LOOK[view], float)
    return np.stack([u, v], -1), d

def unproject(view, u, v, depth=0.0):
    img, sole, u0, ax, sg = VIEWS[view]
    P = np.zeros(3); P[ax] = (u - u0) / sg * S; P[2] = (sole - v) * S
    L = np.array(LOOK[view], float); P = P + L * depth
    return P

def ref_image(view, up=False):
    name = VIEWS[view][0]
    p = os.path.join(HERE, 'work', 'up4', name + '.png') if up else os.path.join(REF, name + '.png')
    return cv2.imread(p)

def ref_mask(view):
    return cv2.imread(os.path.join(MASKS, VIEWS[view][0] + '.png'), 0) > 0

def raster(view, V, F, shape=(1536, 1024), scale=1.0):
    """Silhouette of a triangle/quad mesh in a reference view."""
    uv, _ = project(view, V, scale)
    m = np.zeros((int(shape[0] * scale), int(shape[1] * scale)), np.uint8)
    for f in F:
        cv2.fillConvexPoly(m, np.round(uv[np.asarray(f)] * 4).astype(np.int32), 255, lineType=cv2.LINE_8, shift=2)
    return m > 0

def iou(a, b):
    return (a & b).sum() / max((a | b).sum(), 1)

def overlay(view, sil, color=(0, 0, 255), alpha=0.45, img=None):
    im = ref_image(view) if img is None else img.copy()
    edge = cv2.morphologyEx(sil.astype(np.uint8), cv2.MORPH_GRADIENT, np.ones((3, 3), np.uint8)) > 0
    out = im.copy()
    out[sil] = (out[sil] * (1 - alpha) + np.array(color) * alpha).astype(np.uint8)
    out[edge] = color
    return out

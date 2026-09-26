"""Contact sheet of a CMU clip: side-view stick figures every N frames + hips height / speed plot."""
import sys, os
import numpy as np, cv2
import mocap

EDGES = [('lhipjoint', 'lfemur'), ('lfemur', 'ltibia'), ('ltibia', 'lfoot'), ('lfoot', 'ltoes'),
         ('rhipjoint', 'rfemur'), ('rfemur', 'rtibia'), ('rtibia', 'rfoot'), ('rfoot', 'rtoes'),
         ('lowerback', 'upperback'), ('upperback', 'thorax'), ('thorax', 'lowerneck'), ('lowerneck', 'upperneck'), ('upperneck', 'head'),
         ('lclavicle', 'lhumerus'), ('lhumerus', 'lradius'), ('lradius', 'lwrist'),
         ('rclavicle', 'rhumerus'), ('rhumerus', 'rradius'), ('rradius', 'rwrist')]

def sheet(clip, every=24, cols=14, out=None):
    d = mocap.load(clip); P = d['P']; n = d['names']; ix = {k: i for i, k in enumerate(n)}
    F = len(P); idx = list(range(0, F, every))
    rows = (len(idx) + cols - 1) // cols
    cw, ch = 110, 170
    img = np.full((rows * ch + 150, cols * cw, 3), 255, np.uint8)
    for k, f in enumerate(idx):
        r, c = divmod(k, cols); ox, oy = c * cw + cw // 2, r * ch + ch - 10
        root = d['root'][f]
        for view, col in ((1, (200, 60, 60)), (0, (60, 60, 200))):  # side (y) red, front (x) blue
            for a, b in EDGES:
                pa = P[f, ix[a]] - root; pb = P[f, ix[b]] - root
                pa[2] += root[2]; pb[2] += root[2]
                ua = (int(ox + pa[view] * 70), int(oy - pa[2] * 70)); ub = (int(ox + pb[view] * 70), int(oy - pb[2] * 70))
                cv2.line(img, ua, ub, col, 1, cv2.LINE_AA)
        cv2.putText(img, str(f), (c * cw + 3, r * ch + 12), 0, 0.35, (0, 0, 0), 1)
    # plots
    y0 = rows * ch + 10
    hz = d['root'][:, 2]; sp = np.r_[0, np.linalg.norm(np.diff(d['root'][:, :2], axis=0), axis=1) * d['fps']]
    for arr, col, sc in ((hz, (0, 120, 0), 60), (sp, (0, 0, 200), 12)):
        pts = np.c_[np.linspace(0, img.shape[1] - 1, F), y0 + 130 - np.clip(arr, 0, 2.2) * sc].astype(np.int32)
        cv2.polylines(img, [pts], False, col, 1)
    cv2.putText(img, f'{clip}: {F} frames @120  green=hips z  blue=speed', (5, y0 + 145), 0, 0.4, (0, 0, 0), 1)
    cv2.imwrite(out or f'work/sheet_{clip}.png', img)

if __name__ == '__main__':
    for c in sys.argv[1:]: sheet(c)

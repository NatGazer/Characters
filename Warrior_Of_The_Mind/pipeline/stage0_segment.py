"""Stage 0: segment the reference images from their grey gradient background.

Output: pipeline/work/masks/<name>.png (255 = character) and a debug overlay.
Method: fit a smooth (quadratic) background model to the border pixels, threshold the
colour distance to it, then refine with GrabCut and fill holes.
"""
import glob, os
import numpy as np, cv2
from scipy import ndimage as ndi

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(HERE, 'work', 'masks'); os.makedirs(OUT, exist_ok=True)

def bg_model(im):
    h, w, _ = im.shape
    yy, xx = np.mgrid[0:h, 0:w]
    b = np.zeros((h, w), bool); m = 40
    b[:m] = b[-m:] = True; b[:, :m] = b[:, -m:] = True
    X = np.stack([np.ones(h * w), xx.ravel() / w, yy.ravel() / h, (xx.ravel() / w) ** 2,
                  (yy.ravel() / h) ** 2, xx.ravel() * yy.ravel() / (w * h)], 1)
    sel = b.ravel()
    coef, *_ = np.linalg.lstsq(X[sel], im.reshape(-1, 3)[sel], rcond=None)
    return (X @ coef).reshape(h, w, 3)

def bg_smooth(im):
    """Normalised-convolution background estimate from low-saturation bright pixels."""
    sat = im.max(2) - im.min(2); lum = im.mean(2)
    cand = ((sat < 14) & (lum > 135)).astype(np.float32)
    cand = ndi.binary_erosion(cand, iterations=3).astype(np.float32)
    w = cv2.GaussianBlur(cand, (0, 0), 40)
    bg = np.stack([cv2.GaussianBlur(im[..., c] * cand, (0, 0), 40) for c in range(3)], 2) / np.maximum(w, 1e-4)[..., None]
    # far from any candidate: fall back to global quadratic model
    q = bg_model(im)
    a = np.clip(w / 0.05, 0, 1)[..., None]
    return bg * a + q * (1 - a)

def segment(path):
    bgr = cv2.imread(path)
    im = bgr[..., ::-1].astype(np.float32)
    bg = bg_smooth(im)
    d = np.linalg.norm(im - bg, axis=2)
    sat = im.max(2) - im.min(2)
    fg = (d > 26) | (sat > 30)
    fg = ndi.binary_opening(fg, iterations=1)
    lab, n = ndi.label(fg)
    sizes = ndi.sum(fg, lab, range(1, n + 1))
    keep = np.isin(lab, 1 + np.where(sizes > 400)[0])
    # GrabCut refinement
    gc = np.full(fg.shape, cv2.GC_PR_BGD, np.uint8)
    gc[keep] = cv2.GC_PR_FGD
    gc[ndi.binary_erosion(keep, iterations=6)] = cv2.GC_FGD
    gc[~ndi.binary_dilation(keep, iterations=3)] = cv2.GC_BGD
    bgdm = np.zeros((1, 65), np.float64); fgdm = np.zeros((1, 65), np.float64)
    cv2.grabCut(bgr, gc, None, bgdm, fgdm, 4, cv2.GC_INIT_WITH_MASK)
    m = (gc == cv2.GC_FGD) | (gc == cv2.GC_PR_FGD)
    # floor shadow and bright grey background leaking through: low saturation and bright
    lum = im.mean(2)
    greyish = (sat < 13) & (lum > 118) & (np.abs(lum - bg.mean(2)) < 60)
    greyish = ndi.binary_opening(greyish, iterations=2)
    m &= ~greyish
    # fill only small holes (keep the gaps between legs / arms open)
    holes = ndi.binary_fill_holes(m) & ~m
    hl, hn = ndi.label(holes)
    hs = ndi.sum(holes, hl, range(1, hn + 1))
    m |= np.isin(hl, 1 + np.where(hs < 800)[0])
    m = ndi.binary_opening(m, iterations=1)
    lab, n = ndi.label(m)
    sizes = ndi.sum(m, lab, range(1, n + 1))
    m = np.isin(lab, 1 + np.where(sizes > 300)[0])
    return m

if __name__ == '__main__':
    for f in sorted(glob.glob(os.path.join(ROOT, 'Reference-Images', '*.png'))):
        name = os.path.splitext(os.path.basename(f))[0]
        m = segment(f)
        cv2.imwrite(os.path.join(OUT, name + '.png'), (m * 255).astype(np.uint8))
        im = cv2.imread(f)
        ov = im.copy(); ov[~m] = (ov[~m] * 0.25 + np.array([0, 180, 0]) * 0.75).astype(np.uint8)
        cv2.imwrite(os.path.join(OUT, name + '_overlay.jpg'), ov)
        ys, xs = np.where(m)
        print(name, 'bbox x', xs.min(), xs.max(), 'y', ys.min(), ys.max(), 'area', m.sum())

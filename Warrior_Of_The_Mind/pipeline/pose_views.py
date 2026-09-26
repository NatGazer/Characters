"""Render one frame of an action from front / side / three-quarter (workbench), sword hidden optionally."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import anim_preview as P

def views3(blend, action, frame, out, hide=('Sword',), res=(360, 520), refs=None):
    ims = []
    for v in ('front', 'side', 'q34'):
        P.strip(blend, action, 1, v, '/tmp/pv.jpg', res=res, frames=[frame], hide=hide, follow=True)
        ims.append(cv2.imread('/tmp/pv.jpg'))
    img = np.hstack(ims)
    if refs:
        r = [cv2.resize(cv2.imread(x), (int(res[1] * 1024 / 1536), res[1])) for x in refs]
        img = np.hstack([img] + r)
    cv2.imwrite(out, img)

if __name__ == '__main__':
    a = [x for x in sys.argv[1:] if x != '--']
    views3(a[0], a[1], int(a[2]), a[3], refs=a[4:] or None)

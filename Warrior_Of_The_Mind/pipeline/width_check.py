"""Row-by-row silhouette width comparison (model vs reference mask) in the front and side views.
Reports the width of the connected run containing the body centre line at each height."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, bpy, cv2
import views

def run_width(mask, row, cu):
    r = mask[row]; cu = int(round(cu))
    if not r[cu]:
        xs = np.where(r)[0]
        if len(xs) == 0: return 0
        cu = xs[np.argmin(np.abs(xs - cu))]
    a = cu
    while a > 0 and r[a - 1]: a -= 1
    b = cu
    while b < len(r) - 1 and r[b + 1]: b += 1
    return b - a + 1

def main(blend='work/model_uv.blend', exclude=('hair', 'beard', 'brows')):
    bpy.ops.wm.open_mainfile(filepath=blend)
    Vs, Fs, off = [], [], 0
    for o in bpy.data.objects:
        if o.type != 'MESH' or o.name.lower().startswith(exclude) or o.name.lower() == 'sword': continue
        V = np.array([v.co for v in o.data.vertices]); M = np.array(o.matrix_world); V = V @ M[:3, :3].T + M[:3, 3]
        Fs += [[i + off for i in p.vertices] for p in o.data.polygons]; Vs.append(V); off += len(V)
    V = np.vstack(Vs)
    for view, cu_z in (('front', 0.0), ('left', 0.02)):
        sil = views.raster(view, V, Fs); ref = views.ref_mask(view)
        print(f'== {view}  (m)   height : model  ref  diff')
        for z in (1.72, 1.62, 1.55, 1.45, 1.35, 1.28, 1.18, 1.05, 0.90, 0.70, 0.50, 0.30, 0.12):
            uv, _ = views.project(view, np.array([[0.0, cu_z, z]]))
            row = int(round(uv[0, 1])); cu = uv[0, 0]
            wm = run_width(sil, row, cu) * views.S; wr = run_width(ref, row, cu) * views.S
            print(f'   {z:5.2f} : {wm:5.3f} {wr:5.3f} {wm - wr:+.3f}')

if __name__ == '__main__':
    main(*[a for a in sys.argv[1:] if a != '--'])

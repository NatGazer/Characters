"""Extract the embedded scan textures and build the hindwing alpha (vein-aware, single-layer compensated)."""
import json, base64, io, os, numpy as np
from PIL import Image, ImageFilter; Image.MAX_IMAGE_PIXELS = None
REPO = os.environ.get('BEETLE_REPO', '../..'); T = REPO + '/animated/textures/'
os.makedirs(T, exist_ok=True)
def emb(path, view):
    d = json.load(open(path)); buf = base64.b64decode(d['buffers'][0]['uri'].split(',', 1)[1])
    bv = d['bufferViews'][view]; o = bv.get('byteOffset', 0); return buf[o:o + bv['byteLength']]
open(T + 'beetle_body.jpg', 'wb').write(emb(REPO + '/cc0-74mm-rhinoceros-beetle-t-dichotom/source/QS1296-W05-1all-7.gltf', 7))
W = REPO + '/wings/source/QS1462-W24-1-1_alpha.gltf'
open(T + 'beetle_elytra.jpg', 'wb').write(emb(W, 7))
im = Image.open(io.BytesIO(emb(W, 11))).convert('RGBA').resize((4096, 4096), Image.LANCZOS)
a = np.asarray(im).astype(np.float32) / 255; C = a[..., :3]; L = C @ np.array([0.3, 0.59, 0.11])
Lb = np.asarray(Image.fromarray((L * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(24))).astype(np.float32) / 255
A = np.clip(0.42 + 0.45 * np.clip((Lb - L) * 6, 0, 1) + 0.25 * np.clip((0.22 - L) * 3, 0, 1), 0.35, 0.92)
A = 1 - (1 - A) ** 2          # single membrane layer kept -> compensate opacity of the removed second layer
Image.fromarray((np.dstack([C, A]) * 255 + 0.5).astype(np.uint8), 'RGBA').save(T + 'beetle_hindwing.png', optimize=True)
print('textures written')

"""4x upscale of the reference images with Real-ESRGAN (x4plus, RRDBNet), tiled, CPU.
Usage: python upscale.py [names...]  -> pipeline/work/up4/<name>.png
Weights: RealESRGAN_x4plus.pth (BSD-3, xinntao/Real-ESRGAN) in $ESRGAN (default /opt/assets/esrgan)."""
import os, sys, glob
import numpy as np, cv2, torch
import torch.nn as nn, torch.nn.functional as F

class RDB(nn.Module):
    def __init__(s, nf=64, gc=32):
        super().__init__()
        s.conv1 = nn.Conv2d(nf, gc, 3, 1, 1); s.conv2 = nn.Conv2d(nf + gc, gc, 3, 1, 1)
        s.conv3 = nn.Conv2d(nf + 2 * gc, gc, 3, 1, 1); s.conv4 = nn.Conv2d(nf + 3 * gc, gc, 3, 1, 1)
        s.conv5 = nn.Conv2d(nf + 4 * gc, nf, 3, 1, 1); s.lrelu = nn.LeakyReLU(0.2, True)
    def forward(s, x):
        x1 = s.lrelu(s.conv1(x)); x2 = s.lrelu(s.conv2(torch.cat((x, x1), 1)))
        x3 = s.lrelu(s.conv3(torch.cat((x, x1, x2), 1))); x4 = s.lrelu(s.conv4(torch.cat((x, x1, x2, x3), 1)))
        return s.conv5(torch.cat((x, x1, x2, x3, x4), 1)) * 0.2 + x

class RRDB(nn.Module):
    def __init__(s, nf, gc):
        super().__init__(); s.rdb1 = RDB(nf, gc); s.rdb2 = RDB(nf, gc); s.rdb3 = RDB(nf, gc)
    def forward(s, x): return s.rdb3(s.rdb2(s.rdb1(x))) * 0.2 + x

class RRDBNet(nn.Module):
    def __init__(s, nf=64, nb=23, gc=32):
        super().__init__()
        s.conv_first = nn.Conv2d(3, nf, 3, 1, 1)
        s.body = nn.Sequential(*[RRDB(nf, gc) for _ in range(nb)])
        s.conv_body = nn.Conv2d(nf, nf, 3, 1, 1)
        s.conv_up1 = nn.Conv2d(nf, nf, 3, 1, 1); s.conv_up2 = nn.Conv2d(nf, nf, 3, 1, 1)
        s.conv_hr = nn.Conv2d(nf, nf, 3, 1, 1); s.conv_last = nn.Conv2d(nf, 3, 3, 1, 1)
        s.lrelu = nn.LeakyReLU(0.2, True)
    def forward(s, x):
        f = s.conv_first(x); f = f + s.conv_body(s.body(f))
        f = s.lrelu(s.conv_up1(F.interpolate(f, scale_factor=2, mode='nearest')))
        f = s.lrelu(s.conv_up2(F.interpolate(f, scale_factor=2, mode='nearest')))
        return s.conv_last(s.lrelu(s.conv_hr(f)))

def load():
    net = RRDBNet()
    sd = torch.load(os.path.join(os.environ.get('ESRGAN', '/opt/assets/esrgan'), 'RealESRGAN_x4plus.pth'), map_location='cpu')
    net.load_state_dict(sd.get('params_ema', sd.get('params', sd)), strict=True)
    return net.eval()

@torch.no_grad()
def upscale(net, img, tile=256, pad=12):
    h, w, _ = img.shape
    x = torch.from_numpy(img[..., ::-1].astype(np.float32) / 255.).permute(2, 0, 1)[None]
    out = torch.zeros(1, 3, h * 4, w * 4)
    for y0 in range(0, h, tile):
        for x0 in range(0, w, tile):
            ya, yb = max(y0 - pad, 0), min(y0 + tile + pad, h); xa, xb = max(x0 - pad, 0), min(x0 + tile + pad, w)
            o = net(x[..., ya:yb, xa:xb])
            oy, ox = (y0 - ya) * 4, (x0 - xa) * 4
            th, tw = min(tile, h - y0) * 4, min(tile, w - x0) * 4
            out[..., y0 * 4:y0 * 4 + th, x0 * 4:x0 * 4 + tw] = o[..., oy:oy + th, ox:ox + tw]
    o = (out[0].clamp(0, 1).permute(1, 2, 0).numpy()[..., ::-1] * 255 + 0.5).astype(np.uint8)
    return o

if __name__ == '__main__':
    HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
    out = os.path.join(HERE, 'work', 'up4'); os.makedirs(out, exist_ok=True)
    torch.set_num_threads(4)
    net = load()
    files = sorted(glob.glob(os.path.join(ROOT, 'Reference-Images', '*.png')))
    if len(sys.argv) > 1: files = [f for f in files if any(a in f for a in sys.argv[1:])]
    for f in files:
        dst = os.path.join(out, os.path.basename(f))
        if os.path.exists(dst): continue
        cv2.imwrite(dst, upscale(net, cv2.imread(f)))
        print('done', dst, flush=True)

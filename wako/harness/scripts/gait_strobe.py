#!/usr/bin/env python3
"""Stroboscopic side-view of logged gait poses (POSE lines from gait_metrics.gd
run with user arg dump=<label prefix>). World frame: footprints stay put, swing
arcs and knee directions are visible; planted legs are drawn darker.

Usage: gait_strobe.py LOG OUT.png [every_n_ticks=3] [axis=z|x] [sign=-1] [t0] [t1]
"""
import sys
from PIL import Image, ImageDraw

def parse(path):
    rows = []
    for line in open(path, errors="replace"):
        if not line.startswith("POSE "):
            continue
        p = line.split()
        t = float(p[1])
        vec = lambda s: tuple(float(c) for c in s.split(","))
        root, up = vec(p[2]), vec(p[3])
        legs = []
        for i in range(2):
            o = 4 + i * 5
            legs.append((p[o] == "1", vec(p[o + 1]), vec(p[o + 2]), vec(p[o + 3]), vec(p[o + 4])))
        rows.append((t, root, up, legs))
    return rows

def main():
    log, out = sys.argv[1], sys.argv[2]
    every = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    axis = sys.argv[4] if len(sys.argv) > 4 else "z"
    sign = float(sys.argv[5]) if len(sys.argv) > 5 else -1.0
    t0 = float(sys.argv[6]) if len(sys.argv) > 6 else -1e9
    t1 = float(sys.argv[7]) if len(sys.argv) > 7 else 1e9
    rows = [r for r in parse(log) if t0 <= r[0] <= t1][::every]
    if not rows:
        print("no POSE rows"); return 1
    a = 2 if axis == "z" else 0
    xs = [sign * r[1][a] for r in rows]
    x0, x1 = min(xs) - .6, max(xs) + .6
    scale = 260.0
    w = int((x1 - x0) * scale) + 40
    h = int(1.6 * scale) + 40
    img = Image.new("RGB", (w, h), (246, 246, 242))
    d = ImageDraw.Draw(img)
    to = lambda p: (20 + (sign * p[a] - x0) * scale, h - 20 - p[1] * scale)
    ground_y = h - 20
    d.line([(0, ground_y), (w, ground_y)], fill=(120, 120, 110), width=2)
    n = len(rows)
    for k, (t, root, up, legs) in enumerate(rows):
        fade = 80 + int(150 * k / max(n - 1, 1))
        for side, (g, hip, knee, ankle, sole) in enumerate(legs):
            col = (40, 40, 160) if side == 0 else (170, 50, 40)
            if not g:
                col = tuple(min(255, c + 70) for c in col)
            d.line([to(hip), to(knee), to(ankle), to(sole)], fill=col, width=2)
            d.ellipse([to(knee)[0] - 2, to(knee)[1] - 2, to(knee)[0] + 2, to(knee)[1] + 2], fill=col)
        r = to(root)
        tip = to((root[0] + up[0] * .3, root[1] + up[1] * .3, root[2] + up[2] * .3))
        d.line([r, tip], fill=(60, 140, 60), width=2)
    img.save(out)
    print("wrote", out, w, h, n)

if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Contact sheets from a clip_viewer capture.

    python3 harness/clip_sheet.py <capture.mp4> <outdir> [--every 2] [--cols 6] [--width 640]

Reads the `schedule:` lines that clip_viewer.gd printed into <capture>.log (capture.sh copies the
Godot log next to the mp4), and writes one PNG per clip: every Nth source frame of the clip's
first pass, tiled, each tile labelled with its source frame (f) and normalized phase.
"""
import argparse
import os
import re
import subprocess
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mp4")
    ap.add_argument("outdir")
    ap.add_argument("--every", type=int, default=2)
    ap.add_argument("--cols", type=int, default=6)
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    log = a.mp4[:-4] + ".log"
    sched = []
    for line in open(log, errors="replace"):
        m = re.match(r"schedule: (\S+) (\d+) (\d+) frames=(\d+) loop=(\d)", line.strip())
        if m:
            sched.append((m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5))))
    if not sched:
        sys.exit("no schedule lines in %s" % log)
    os.makedirs(a.outdir, exist_ok=True)
    only = set(x for x in a.only.split(",") if x)
    for name, start, count, frames, loop in sched:
        if only and name not in only:
            continue
        last = frames - 1 if loop else frames
        picks = list(range(0, last + 1, a.every))
        if picks[-1] != last:
            picks.append(last)
        rows = (len(picks) + a.cols - 1) // a.cols
        sel = "+".join("eq(n\\,%d)" % (start + p) for p in picks)
        h = int(a.width * 9 / 16)
        # every tile carries the viewer's own caption (clip, source frame, phase) and timeline marker
        vf = "select='%s',scale=%d:%d,tile=%dx%d:padding=2:color=black" % (sel, a.width, h, a.cols, rows)
        out = os.path.join(a.outdir, "%s.png" % name)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", a.mp4, "-vf", vf, "-frames:v", "1", "-vsync", "0", out],
                       check=True)
        print("wrote", out, "(%d tiles, frames 0..%d every %d)" % (len(picks), last, a.every))


if __name__ == "__main__":
    main()

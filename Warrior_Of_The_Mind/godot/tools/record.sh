#!/bin/bash
# Record showcase clips from Godot (deterministic --write-movie at 30 fps) and encode MP4s.
# usage: tools/record.sh OUT_DIR [clip ...]      (no clips = whole showcase in one reel)
# Needs a display: runs under xvfb-run when DISPLAY is unset.
set -e
cd "$(dirname "$0")/.."
OUT=${1:-renders}; shift || true
mkdir -p "$OUT"
RUN="godot"
[ -z "$DISPLAY" ] && RUN="xvfb-run -a -s '-screen 0 1920x1080x24' godot"
RES=${RES:-1280x720}
if [ $# -eq 0 ]; then
  eval $RUN --path . --rendering-driver vulkan --resolution $RES --fixed-fps 30 --write-movie /tmp/reel.avi res://scenes/showcase.tscn -- --auto >/dev/null 2>&1 || true
  ffmpeg -y -loglevel error -i /tmp/reel.avi -c:v libx264 -pix_fmt yuv420p -crf 20 -preset slow "$OUT/showreel.mp4"
  exit 0
fi
for c in "$@"; do
  eval $RUN --path . --rendering-driver vulkan --resolution $RES --fixed-fps 30 --write-movie /tmp/clip_$c.avi res://scenes/showcase.tscn -- --auto --clip=$c >/dev/null 2>&1 || true
  ffmpeg -y -loglevel error -i /tmp/clip_$c.avi -c:v libx264 -pix_fmt yuv420p -crf 21 -preset slow "$OUT/$c.mp4"
  rm -f /tmp/clip_$c.avi
  echo "recorded $c"
done

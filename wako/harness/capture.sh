#!/usr/bin/env bash
# Render a harness scene to a compact 720p30 H.264 clip with the real game sound.
# Usage: harness/capture.sh <res://scene.tscn> <out.mp4> <seconds> [extra user args...]
# Runs Godot's movie maker on software Vulkan (lavapipe) under Xvfb; timing is
# deterministic (fixed 30 fps game frames, 120 Hz physics).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCENE="$1"; OUT="$2"; SECS="$3"; shift 3
GODOT="${GODOT:-/tmp/claude-0/-home-user-Characters/933fde2e-3927-555f-ac1f-2179166bd9f0/scratchpad/tools/Godot_v4.7.1-stable_linux.x86_64}"
WORK="${WORK:-$HERE/work}"
FRAMES=$(python3 -c "print(int(round($SECS*30)))")
TMP="$(mktemp -d)"
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json
timeout 3600 xvfb-run -a -s "-screen 0 1280x720x24" "$GODOT" --path "$WORK" --resolution 1280x720 \
  --write-movie "$TMP/movie.avi" --fixed-fps 30 --quit-after "$FRAMES" "$SCENE" -- "$@" > "$TMP/log.txt" 2>&1 || true
grep -E "^(ERROR|SCRIPT ERROR)" "$TMP/log.txt" | grep -v "leaked\|still in use\|PagedAllocator" | sort | uniq -c | head -10 || true
mkdir -p "$(dirname "$OUT")"
ffmpeg -v error -y -i "$TMP/movie.avi" -c:v libx264 -preset slow -crf 27 -pix_fmt yuv420p -movflags +faststart \
  -c:a aac -b:a 64k "$OUT"
cp "$TMP/log.txt" "${OUT%.mp4}.log"
rm -rf "$TMP"
echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"

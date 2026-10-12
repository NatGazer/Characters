#!/usr/bin/env bash
# Render authored wk_* clips with the clip viewer and make per-clip contact sheets.
# Usage: [VIEWER_ARGS="--ty=0.35"] harness/clip_review.sh <work_dir> <test.blend> <pipeline_report.json> <out_dir> <tag> <views> <every> clip [clip...]
#   work_dir  harness project built by build.sh (the test blend is copied over its Wako.blend and re-imported
#             when it changed)
#   views     viewer --view value, e.g. "left,34l" (two side-by-side panes)
#   every     contact sheet stride in source frames
# Writes <out_dir>/<tag>.mp4 (+ .log) and <out_dir>/sheets/<clip>.png
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$1"; BLEND="$2"; REPORT="$3"; OUT="$4"; TAG="$5"; VIEWS="$6"; EVERY="$7"; shift 7
GODOT="${GODOT:-/tmp/claude-0/-home-user-Characters/933fde2e-3927-555f-ac1f-2179166bd9f0/scratchpad/tools/Godot_v4.7.1-stable_linux.x86_64}"
DEST="$WORK/LogicObjects/Wako/Wako.blend"
mkdir -p "$WORK/harness/scenes" "$WORK/harness/scripts" "$OUT/sheets"
cp "$HERE/scenes/clip_viewer.tscn" "$WORK/harness/scenes/"
cp "$HERE/scripts/clip_viewer.gd" "$HERE/scripts/clip_inventory.gd" "$WORK/harness/scripts/"
if ! cmp -s "$BLEND" "$DEST"; then
  cp "$BLEND" "$DEST"
  timeout 900 "$GODOT" --headless --import --path "$WORK" > "$OUT/import_$TAG.log" 2>&1 || true
fi
CLIPS="$(IFS=,; echo "$*")"
SECS=$(python3 -I - "$REPORT" "$CLIPS" <<'EOF'
import json, sys
rep = json.load(open(sys.argv[1]))["clips"]
total = 2
for c in sys.argv[2].split(","):
    r = rep[c]
    total += r["frames"] if r["loop"] else r["frames"] + 1 + 4
print("%.4f" % (total / 30.0))
EOF
)
WORK="$WORK" "$HERE/capture.sh" res://harness/scenes/clip_viewer.tscn "$OUT/$TAG.mp4" "$SECS" --clip="$CLIPS" --view="$VIEWS" ${VIEWER_ARGS:-}
python3 -I "$HERE/clip_sheet.py" "$OUT/$TAG.mp4" "$OUT/sheets" --every "$EVERY" --cols 4 --width 640

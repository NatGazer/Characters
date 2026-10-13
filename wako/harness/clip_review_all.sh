#!/usr/bin/env bash
# Render every wk_* clip family with the clip viewer and write per-clip contact sheets.
# Usage: harness/clip_review_all.sh <work_dir> <test.blend> <pipeline_report.json> <out_dir>
#   work_dir: harness project from build.sh; the test blend is copied over its Wako.blend and re-imported.
# Sheets are every source frame (30 fps) except the long loops/phrases noted below.
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
W="$1"; B="$2"; R="$3"; O="$4"
mkdir -p "$O"
VIEWER_ARGS="--ty=0.42" "$H/clip_review.sh" "$W" "$B" "$R" "$O" sit "34,side" 1 wk_sit_down wk_sit_up
"$H/clip_review.sh" "$W" "$B" "$R" "$O" workR_a "side,34" 1 wk_assemble_R wk_inspect_R wk_repair_R wk_maintenance_R wk_unbend_R wk_tool_change_R wk_brace_R
"$H/clip_review.sh" "$W" "$B" "$R" "$O" workR_b "side,34" 1 wk_push_R wk_pull_R wk_operate_R wk_place_R wk_pickup_R wk_step_R wk_interrupted_R
"$H/clip_review.sh" "$W" "$B" "$R" "$O" workL "left,34l" 1 wk_assemble_L wk_maintenance_L wk_repair_L wk_unbend_L wk_place_L
"$H/clip_review.sh" "$W" "$B" "$R" "$O" social "front,34" 1 wk_greet wk_cheer
"$H/clip_review.sh" "$W" "$B" "$R" "$O" dance "front,34" 1 wk_dance_a wk_dance_b wk_dance_c
VIEWER_ARGS="--water=1.0" "$H/clip_review.sh" "$W" "$B" "$R" "$O" swim "side,front" 1 wk_swim
"$H/clip_review.sh" "$W" "$B" "$R" "$O" idle "side,front" 2 wk_idle wk_danger
VIEWER_ARGS="--ty=0.42" "$H/clip_review.sh" "$W" "$B" "$R" "$O" sitidle "34,front" 3 wk_sit_idle
"$H/clip_review.sh" "$W" "$B" "$R" "$O" loco "side,34" 1 wk_walkcycle wk_run wk_carry
echo ALLDONE

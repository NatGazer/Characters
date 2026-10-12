#!/usr/bin/env bash
# Run every scene in Scenes/ (plus the main scene) and print a per-scene error summary.
# Usage: .claude/scripts/run_all.sh [frames=900] [--headless] [other engine arguments...]
cd "$(dirname "$0")/../.." || exit 1
FRAMES=900
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then FRAMES="$1"; shift; fi
bad=0
.claude/scripts/run_scene.sh "" "$FRAMES" "$@" || bad=$((bad + 1))
for f in Scenes/*.tscn Scenes/*.scn; do
  LOG=".godot/run_$(basename "${f%.*}").log" .claude/scripts/run_scene.sh "res://$f" "$FRAMES" "$@" || bad=$((bad + 1))
done
echo "run_all failed_checks=$bad"
[ "$bad" -eq 0 ]

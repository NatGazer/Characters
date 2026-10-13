#!/usr/bin/env bash
# Packaged back-tool regression scenarios (headless, 120 Hz, harness workdir).
# Usage: harness/run_back_checks.sh [workdir] [parallel]
# One PASS/FAIL line per scenario; logs in <workdir>/logs/back_*.log.
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$HERE/work}"
PAR="${2:-3}"
GODOT="${GODOT:-/tmp/claude-0/-home-user-Characters/933fde2e-3927-555f-ac1f-2179166bd9f0/scratchpad/tools/Godot_v4.7.1-stable_linux.x86_64}"
mkdir -p "$WORK/logs"
SCENARIOS=(
  "mallet_L --tool=assembly_tool --side=0"
  "mallet_R --tool=assembly_tool --side=1"
  "pickaxe_L --tool=salvage_tool --side=0"
  "pickaxe_R --tool=salvage_tool --side=1"
  "walk_run --tool=assembly_tool --side=1 --walk --walk_speed=3.4"
  "walk_pickaxe --tool=salvage_tool --side=1 --walk"
  "interrupt_kick --tool=assembly_tool --side=0 --interrupt=kick"
  "interrupt_apex --tool=assembly_tool --side=0 --interrupt=apex"
  "interrupt_late --tool=salvage_tool --side=1 --interrupt=late"
  "interrupt_contact --tool=assembly_tool --side=0 --interrupt=contact"
  "interrupt_reach --tool=assembly_tool --side=0 --interrupt=reach"
  "save_flight --tool=assembly_tool --side=0 --save=flight"
  "save_back_v2 --tool=assembly_tool --side=0 --save=back_v2"
  "ceiling_185_pickaxe --tool=salvage_tool --side=1 --ceiling=1.85"
  "ceiling_150 --tool=assembly_tool --side=0 --ceiling=1.50"
  "knock_back --tool=assembly_tool --side=0 --knock=back"
)
run_one() {
  local label="$1"; shift
  timeout 600 "$GODOT" --headless --path "$WORK" --fixed-fps 120 --quit-after 7200 \
    res://harness/scenes/back_stunt.tscn -- --quit --assert "$@" > "$WORK/logs/back_$label.log" 2>&1
  echo "$label :: $(grep -E '^BACK_STUNT (PASS|FAIL)' "$WORK/logs/back_$label.log" | tail -1) $(grep -c '^SCRIPT ERROR' "$WORK/logs/back_$label.log") script errors"
}
export -f run_one
export GODOT WORK
printf '%s\n' "${SCENARIOS[@]}" | xargs -P "$PAR" -L 1 bash -c 'run_one "$@"' _

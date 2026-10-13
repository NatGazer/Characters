#!/usr/bin/env bash
# Packaged back-tool regression scenarios (headless, 120 Hz, harness workdir).
# Usage: harness/run_back_checks.sh [workdir] [parallel]
# One PASS/FAIL line per scenario; logs in <workdir>/logs/back_*.log.
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$HERE/work}"
PAR="${2:-4}"
GODOT="${GODOT:-/tmp/claude-0/-home-user-Characters/933fde2e-3927-555f-ac1f-2179166bd9f0/scratchpad/tools/Godot_v4.7.1-stable_linux.x86_64}"
mkdir -p "$WORK/logs"
SCENARIOS=(
  "mallet_L --tool=assembly_tool --side=0"
  "mallet_R --tool=assembly_tool --side=1"
  "pickaxe_L --tool=salvage_tool --side=0"
  "pickaxe_R --tool=salvage_tool --side=1"
  "walk_run --tool=assembly_tool --side=1 --walk --walk_speed=3.4"
  "walk_pickaxe --tool=salvage_tool --side=1 --walk"
  "interrupt_gather --tool=assembly_tool --side=0 --interrupt=gather"
  "interrupt_hold --tool=salvage_tool --side=1 --interrupt=hold"
  "interrupt_kick --tool=assembly_tool --side=0 --interrupt=kick"
  "interrupt_apex --tool=assembly_tool --side=0 --interrupt=apex"
  "interrupt_late --tool=salvage_tool --side=1 --interrupt=late"
  "interrupt_contact --tool=assembly_tool --side=0 --interrupt=contact"
  "interrupt_reach --tool=assembly_tool --side=0 --interrupt=reach"
  "interrupt_home --tool=salvage_tool --side=0 --interrupt=home"
  "fear_early --tool=assembly_tool --side=0 --fear=age --fear_age=.15"
  "hit_rising --tool=salvage_tool --side=1 --fear=rising --hit"
  "recoil_apex --tool=salvage_tool --side=1 --fear=apex --hit --hit_speed=3.0"
  "recoil_falling --tool=assembly_tool --side=0 --fear=falling --hit --hit_speed=3.0"
  "save_flight --tool=assembly_tool --side=0 --save=flight"
  "save_flight_late --tool=salvage_tool --side=1 --save=flight_late"
  "save_back_v2 --tool=assembly_tool --side=0 --save=back_v2"
  "save_return --tool=assembly_tool --side=1 --save=return"
  "ceiling_185_pickaxe --tool=salvage_tool --side=1 --ceiling=1.85"
  "ceiling_150 --tool=assembly_tool --side=0 --ceiling=1.50"
  "knock_back --tool=assembly_tool --side=0 --knock=back"
  "depart_mallet_L --tool=assembly_tool --side=0 --depart"
  "depart_mallet_R --tool=assembly_tool --side=1 --depart"
  "depart_pickaxe_L --tool=salvage_tool --side=0 --depart"
  "depart_pickaxe_R --tool=salvage_tool --side=1 --depart"
  "interrupt_kick_pickaxe --tool=salvage_tool --side=0 --interrupt=kick"
  "hit_kick_mallet_L --tool=assembly_tool --side=0 --hit_kick_rel=6 --hit_speed=3.0"
  "hit_release_mallet_R --tool=assembly_tool --side=1 --hit_kick_rel=10 --hit_speed=3.0"
  "hit_release_pickaxe_L --tool=salvage_tool --side=0 --hit_kick_rel=10 --hit_speed=3.0"
  "hit_release_mallet_L --tool=assembly_tool --side=0 --hit_kick_rel=11 --hit_speed=3.0"
  "hit_kick_pickaxe_R --tool=salvage_tool --side=1 --hit_kick_rel=6 --hit_speed=3.0"
  "slope_up_mallet_R --tool=assembly_tool --side=1 --slope=8"
  "slope_down_pickaxe_R --tool=salvage_tool --side=1 --slope=-8"
  "knock_draw_pickaxe --tool=salvage_tool --side=0 --knock=draw"
  "save_back_old_seat_pickaxe --tool=salvage_tool --side=1 --save=back --back-tool-seat=15,.16,-.10,0 --reseat_on_restore"
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

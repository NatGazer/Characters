#!/usr/bin/env bash
# Run the package's Wako regression tests in the harness (headless, fixed 120 fps).
# Usage: harness/run_tests.sh [workdir] [test names...]   (default: the harness-runnable set)
# Prints one PASS/FAIL summary line per test; full logs in <workdir>/logs/.
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$HERE/work}"; shift || true
GODOT="${GODOT:-/tmp/claude-0/-home-user-Characters/933fde2e-3927-555f-ac1f-2179166bd9f0/scratchpad/tools/Godot_v4.7.1-stable_linux.x86_64}"
TESTS=("$@")
[ ${#TESTS[@]} -eq 0 ] && TESTS=(wako_asset wako_native_handoff wako_support wako_balance wako_gait wako_steps wako_recoil wako_physics)
mkdir -p "$WORK/logs"
for t in "${TESTS[@]}"; do
  timeout 1500 "$GODOT" --headless --path "$WORK" --fixed-fps 120 --quit-after "${FRAMES:-30000}" \
    "res://.claude/tests/contraptions/$t.tscn" ${EXTRA_ARGS:-} > "$WORK/logs/$t.log" 2>&1
  code=$?
  verdict=$(grep -E "PASS|FAIL" "$WORK/logs/$t.log" | tail -1 | cut -c1-160)
  fails=$(grep -c "FAIL" "$WORK/logs/$t.log")
  errs=$(grep -cE "^(SCRIPT ERROR|ERROR)" "$WORK/logs/$t.log")
  echo "$t exit=$code fails=$fails errors=$errs :: $verdict"
done

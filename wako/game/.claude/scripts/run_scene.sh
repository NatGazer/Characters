#!/usr/bin/env bash
# Run the game (or a specific scene) for N frames and summarize errors/warnings.
# Usage: .claude/scripts/run_scene.sh [res://Scenes/X.tscn] [frames=1200] [--headless]
# Full log is written to $LOG (default: .godot/claude_run.log, gitignored with .godot).
# GODOT=<path> overrides the binary (e.g. the custom build, see CLAUDE.md "Custom engine").
GODOT="${GODOT:-/d/Everything/GodotSource/bin/godot.windows.editor.x86_64.llvm.console.exe}"
cd "$(dirname "$0")/../.." || exit 1
SCENE="${1:-}"; FRAMES="${2:-1200}"; EXTRA=("${@:3}")
LOG="${LOG:-.godot/claude_run.log}"
# --auto-quit-frames is handled by Autoload/shortcuts.gd (graceful quit); --quit-after is a hard fallback
timeout 600 "$GODOT" --path . "${EXTRA[@]}" --quit-after $((FRAMES + 600)) $SCENE -- --auto-quit-frames="$FRAMES" > "$LOG" 2>&1
code=$?
echo "exit=$code scene=${SCENE:-<main>} frames=$FRAMES log=$LOG"
# Group each ERROR/WARNING with its following "at:" line, dedupe, count.
awk '/^(ERROR|WARNING|SCRIPT ERROR|USER ERROR|USER WARNING|SHADER ERROR)/{msg=$0; getline nxt; if (nxt ~ /^ +at:/) msg=msg " || " nxt; print msg}' "$LOG" \
  | sed -E 's/  */ /g; s/-?[0-9]+\.[0-9]+(e-?[0-9]+)?/N/g' | sort | uniq -c | sort -rn | cut -c1-400
# Godot can return zero after script/runtime errors. Treat unexpected diagnostics
# as a failed check while retaining the actual process status printed above.
if [ "$code" -eq 0 ] && grep -E '^(ERROR|WARNING|SCRIPT ERROR|USER ERROR|USER WARNING|SHADER ERROR)' "$LOG" \
  | grep -v 'instance_reset_physics_interpolation() is deprecated' | grep -q .; then
  echo "check failed: unexpected diagnostics in $LOG"
  exit 1
fi
exit "$code"

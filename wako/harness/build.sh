#!/usr/bin/env bash
# Assemble a runnable Godot 4.7 validation project from the real game files
# (../game, copied so engine-side .import rewrites never touch the source) plus
# minimal stubs for the parts of RaulsMod that are not in this package.
# Usage: harness/build.sh [workdir=harness/work]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GAME="$HERE/../game"
WORK="${1:-$HERE/work}"
mkdir -p "$WORK"
rsync -a --delete --exclude '.godot' --exclude '.claude' --exclude 'tools' \
  --exclude 'stubs_overlay' --exclude 'harness' \
  --exclude '*.md' --exclude 'PLAYTEST.txt' \
  "$GAME/" "$WORK/" --filter 'P .godot' --filter 'P *.import' --filter 'P harness' --filter 'P project.godot' --filter 'P stubs_overlay'
# Stubs only fill paths the package does not provide; never shadow real game files.
python3 -I "$HERE/gen_stubs.py" >/dev/null
for SRC in "$HERE/stubs" "$HERE/stubs_auto"; do
  ( cd "$SRC" && find . -type f ) | while read -r f; do
    rel="${f#./}"; dest="$WORK/$rel"
    # Hand-written stubs win over generated ones; neither may shadow a real game file.
    if [ -e "$GAME/$rel" ]; then continue; fi
    if [ "$SRC" = "$HERE/stubs_auto" ] && [ -e "$HERE/stubs/$rel" ]; then continue; fi
    mkdir -p "$(dirname "$dest")"; cp "$SRC/$rel" "$dest"
  done
done
# The package's own regression tests run from their original res:// location.
mkdir -p "$WORK/.claude/tests"
rsync -a --delete "$GAME/.claude/tests/" "$WORK/.claude/tests/"
mkdir -p "$WORK/harness"
rsync -a --delete "$HERE/scenes/" "$WORK/harness/scenes/"
rsync -a --delete "$HERE/scripts/" "$WORK/harness/scripts/"
cp "$HERE/project.godot" "$WORK/project.godot"
GODOT="${GODOT:-/tmp/claude-0/-home-user-Characters/933fde2e-3927-555f-ac1f-2179166bd9f0/scratchpad/tools/Godot_v4.7.1-stable_linux.x86_64}"
# Import new/changed assets (including Wako.blend through the Blender importer).
timeout 600 "$GODOT" --headless --import --path "$WORK" >"$WORK/.import.log" 2>&1 || true
grep -E "^(ERROR|SCRIPT ERROR)" "$WORK/.import.log" | grep -v "leaked\|resources still in use\|PagedAllocator" | sort | uniq -c | head -20 || true
echo "harness ready: $WORK"

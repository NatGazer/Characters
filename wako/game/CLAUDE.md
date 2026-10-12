# Raul's Mod (Godot 4.7, Forward+)

3D physics sandbox game. What to work on is in `goals.md`. Research findings from earlier work are in `.claude/RESEARCH.md`.

## How to work
- While the long-horizon goal is active, keep six specialists on distinct productive tasks. Give each a narrow
  feature scope and use a fresh agent when the subject changes substantially. The primary agent integrates
  changes, runs shared checks and keeps the slots filled; do not spend slots on repeated readiness audits.
- Deliver changes to the game, not process. A task is done when the change is in the game, you checked it by
  running the scene, and it is committed. Then tick it off in `goals.md` in the same commit.
- Commit when you finish a task, on the current branch, without asking. Don't push. Stage only your own files
  (`git add <paths>`, never `git add -A`).
- No judge/review/seal/gate rounds, checkpoint files, handoff notes or dated evidence folders. A quick self-check
  (clean `run_scene.sh` output plus a screenshot or a short play) is enough.
- Temporary output (logs, screenshots, captures) goes to `.claude/tmp/` (gitignored). Delete it when done.
- If something has blocked you for more than ~30 minutes (tooling, flaky harness), simplify the approach or ask the user.
- When you report, say what changed in the game and what is still missing.
- After finishing and successfully checking a visual feature or mechanic, add a clearly named picture or short video to `FeatureGallery/` using `tools/feature_gallery.py`. Use actual game captures: images at most 1280x720, clips at 30 fps and normally 3–10 seconds. Keep files compact. Include individual part appearance and operation, Wako construction/dismantling, and enemy behavior/combat where relevant. Label model-only previews, focused-yard checks and Island gameplay accurately; a camera orbit does not prove a mechanism works. Rebuild the gallery index after adding media.

## Engine
- Custom build (Godot 4.7.2 + patches: contact shadows, DLSS/Reflex, Jolt 5.6, TAA resolve from PR #123844, perf fixes):
  `D:/Everything/GodotSource/bin/godot.windows.editor.x86_64.llvm.exe` (editor) and `...llvm.console.exe` (use this one to capture output).
  Stock fallback: `C:/Program Files/Godot/Godot_v4.7.1-stable_win64_console.exe`. Every script takes `GODOT=<path>`.
- Patches: `.claude/engine/patches.txt` + `.claude/engine/patches/`. Rebuild:
  `powershell -ExecutionPolicy Bypass -File .claude/scripts/build_godot.ps1` (`-NoReset -Targets editor` for incremental).
- Set contact-shadow/DLSS properties from code or `Settings`, not in shared scenes, so stock 4.7.1 still loads them.

## Running and checking
- `.claude/scripts/run_scene.sh [res://Scenes/X.tscn] [frames] [--verbose]` runs a scene and prints deduped
  errors/warnings (full log: `.godot/claude_run.log`). Empty output after `exit=` means clean.
- `.claude/scripts/run_all.sh [frames]` runs every scene. `/godot-check` skill: sweep and fix errors.
- Feature test harnesses: `.claude/tests/run_*.sh` (read the header of the one you need).
- For motion, camera, physics or flicker changes, self-check with `.claude/tests/jitter/run_jitter.sh` (see `.claude/tests/jitter/README.md`); use `--jitter-capture=1 --jitter-hold-camera` for flicker.
- The editor is usually closed. If it is open, it locks `addons/terrain_3d/bin/*.dll` and can overwrite scenes you edit.

## Scene flow
`Scenes/Boot.tscn` (main) -> `Scenes/MainMenu.tscn` -> `Scenes/Island.tscn` (main world). Menus need input, so test
gameplay by running scenes directly (`-- --spawn=<poi>`, `-- --spawn-at=x,y,z`). Island.tscn, Roads.tscn and the terrain
data are generated: change `tools/worldgen/` and regenerate (see `World/README.md`), never hand-edit them.

## Bug reports
The user files reports in-game with F12: `.claude/feedback/inbox/<id>/` (report.md, report.json, screenshot.png).
Move a report to `in_progress/` while working on it, and delete the folder once it's fixed and committed.

## Code gotchas
- Many gameplay scripts are built-in scripts inside `.tscn` (`script/source = "..."`, quotes escaped `\"`, no `class_name`).
  Error line numbers count from the `extends` line = 1.
- Autoloads: `Global`, `Utils`, `Shortcuts`, `Settings`, `InputHub`, `GameUI`, `Vegetation`, ...
- Read input as actions (`InputHub`), never raw keys. New keys need a shortcut provider (group `shortcut_providers`).
- Don't keep instantiated nodes outside the tree (they leak at exit).
- Lerped `Basis` values must stay right-handed (det +1).
- Never block the main thread on a thread that may be inside `ResourceLoader.load()` (deadlock). Hand it to
  `ThreadReaper.release(t)`. Don't use `load_threaded_request()` (its token leaks at exit).
- Quit through `Shortcuts.graceful_quit()`; run scripts use `-- --auto-quit-frames=N`.
- New `class_name` scripts need `godot --headless --path . --import` before command-line runs see them.
- Physics runs at 120 Hz; a tick over ~4 ms spirals.

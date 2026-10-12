# Jitter and flicker checks

Screenshots can't show shaking, wobbling, stutter or flicker. This tool records motion and frames from any scene and
turns them into numbers, plots and image strips an agent can read.

```
.claude/tests/jitter/run_jitter.sh selftest                       # proves the tool works (~1 min)
.claude/tests/jitter/run_jitter.sh <res://scene.tscn> <out_dir> [scene args] [probe args]
```

## Motion jitter (shaking, wobble, stutter)

```
run_jitter.sh res://Scenes/Island.tscn .claude/tmp/jitter/walk --spawn-at=-579,26.03,-126.46 --yaw=50 \
    --jitter-track="camera;player;group:jitter_focus" --jitter-act=move_forward@0:5 --jitter-act=sprint@2.5:5
```

- `--jitter-track` (`;`-separated): `camera`, `player`, `path:<NodePath>`, `group:<name>` (re-read every frame, so
  something grabbed mid-run shows up), `bodies:<n>[:<radius>]` (nearest rigid bodies on screen).
- Inputs: `--jitter-act=<InputMap action>@<t0>:<t1>` (on foot: `move_forward`, `sprint`, `jump`, `crouch`, ...;
  `left_click`, `Shoot`, `Interact`), `--jitter-mouse=dx,dy@t0:t1` (px per frame). Times are seconds from the start
  of recording; negative times press during the settle.
- Timing: real time by default (what a player sees). `--jitter-fps=144` or `--jitter-fps=unsteady` expose physics
  (120 Hz) vs frame timing problems. `--jitter-settle=<s>` (default 4) and `--jitter-seconds=<s>` (default 4).
- Output per track: `JITTER track=... screen=0.81px rot=... world=10.5mm tick=11.1mm ... -> VISIBLE (source)`.
  Verdict on the worst px number: ok < 0.2, slight < 0.5, visible < 1.5, strong. Source tells where to look:
  `camera` (the thing is steady, the view shakes), `sampling` (smooth per physics tick, uneven per rendered frame:
  missing interpolation), `motion` (it really shakes: script, solver, springs).
- Look at `trace_<track>.png` (residual vs time, frames vs ticks, frame dt). With `--jitter-capture=1`, also
  `strip_<track>.png`: crops centred on where the thing should be (magenta cross); shake shows as it moving off it.

## Flicker (blinking, shimmer, z-fighting, popping)

```
run_jitter.sh res://Scenes/Island.tscn .claude/tmp/jitter/rocks --spawn-at=95.82,1.47,1206.76 --yaw=-51 \
    --pitch=-25.7 --jitter-capture=1 --jitter-hold-camera --jitter-seconds=3
```

- `--jitter-capture=1` saves every frame (the script then runs at a fixed 60 fps, so game time is exact).
- `--jitter-hold-camera` freezes the view (a copy of the active camera takes over 0.5 s before recording, so
  TAA/FSR/DLSS history settles first). `--jitter-pan=<deg/s>` and `--jitter-dolly=x,y,z` move it smoothly (for
  motion-blur bugs); then frames are motion-compensated with optical flow, which is less exact than a still view.
- Output: `FLICKER #1 box=x,y,w,h events=... frames=.../179 persistent|transient|moving peak=f...`. Open
  `flicker_heat.png` (where), `flicker_region<N>.png` (top: the frames around the peak, bottom: change x4; a flicker
  reads as A B A), `flicker_series.png` (when). `moving` regions are things passing by, or shaking while they move:
  track those instead. Small transient regions with tens of events are usually leaves, petals and particles.

## Notes

- Windowed runs take the `windowed1` lock. `HEADLESS=1` for trace-only runs without a window.
  `SIZE=WxH` (default 1280x720), `GODOT=<exe>`, `FPS=<n>`.
- Re-analyse without re-running: `python .claude/tests/jitter/jitter_analyze.py <out_dir> [--window=0.1 --thr=0.05]`.
- The probe sits under `/root` and needs no change to the scene (`jitter_run.tscn` adds it, then switches scenes).
- Island runs at ~16 fps on this laptop in the test profile; the report warns below 30 fps, since jitter numbers
  depend on the frame rate.
- Files: `jitter_probe.gd` (recorder), `jitter_run.*` (wrapper scene), `jitter_analyze.py` (analysis),
  `jitter_fixture.*` (self-test scene with known smooth, noisy, wobbly, tick-only, blinking and shimmering objects).

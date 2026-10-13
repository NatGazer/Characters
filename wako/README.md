# Wako: animation, rig and interaction rebuild

Wako is the armless cube helper from RaulsMod (Godot 4.7, Forward+, Jolt at 120 Hz). This folder holds the rebuilt
character: mesh and rig, a re-authored clip library, and new runtime motion code. That code covers the gait and IK,
the head-first pickup, the backpack tool toss, and the face/eyes/attention. It also has the harness used to check
and render all of it. The brief is in [`source/WAKO_ANIMATION_REBUILD.md`](source/WAKO_ANIMATION_REBUILD.md).

```
wako/
├── source/     the uploaded package: brief, reference media notes, exports (unmodified)
├── game/       the RaulsMod files that changed, at their game paths (drop-in over the mod)
├── pipeline/   Blender scripts that rebuild the mesh/rig and author the clip library
├── harness/    stand-alone Godot harness: stubs, labs, capture and test runners
└── renders/    videos/ (one video per animation + runtime interactions), deformation and clip sheets
```

## Videos

Every video was rendered by the real engine (Godot 4.7.1 movie maker, 720p30) with the shipped shaders and scripts.

* **[`renders/videos/clips/`](renders/videos/clips/)** has one video per authored animation, played frame-exact in
  the clip viewer from two fixed cameras. `_L` clips are shown; each `_R` clip is its mirror.
  * Locomotion: `wk_idle`, `wk_walkcycle`, `wk_run`, `wk_carry`, `wk_danger`, `wk_step_L`.
  * Work strokes: `wk_assemble_L`, `wk_inspect_L`, `wk_repair_L`, `wk_maintenance_L`, `wk_operate_L`,
    `wk_push_L`, `wk_pull_L`, `wk_unbend_L`, `wk_brace_L`, `wk_pickup_L`, `wk_place_L`, `wk_tool_change_L`,
    `wk_interrupted_L`.
  * Social and personality: `wk_greet`, `wk_cheer`, `wk_dance_a`, `wk_dance_b`, `wk_dance_c`.
  * Sitting and water: `wk_sit_down`, `wk_sit_idle`, `wk_sit_up`, `wk_swim`.
* **[`renders/videos/runtime/`](renders/videos/runtime/)** shows the procedural systems driving the real Wako
  scripts in harness scenes:
  * Gait: walk → jog → run → stop → turns, uneven terrain, and running with head cargo.
  * Head-first pickup: solo, crew, and the toss and catch.
  * Backpack tool toss: stow and catch, then stowing on departure while running.
  * Face: idle life and work, greeting and bump, and a threat's notice → alarm → relief.
* [`renders/clips/`](renders/clips/) holds per-frame contact sheets and review videos of each clip family.
  [`renders/deformation/`](renders/deformation/) holds before/after deformation sheets from Blender and from Godot.

## What changed

### Mesh, skeleton and weights (`pipeline/wako_mesh_rebuild.py`)
* Only the legs were remeshed; the body, head, UVs and material are untouched. The new legs have a ball-and-socket
  hip junction, a 7-loop knee with a rigid back crease, a 5-loop ankle that holds up in a crouch, and a forefoot toe
  cap. The mesh went from 557 to 1389 vertices (1110 to 2774 triangles), with at most 2 influences per vertex and
  no unweighted vertices. See `pipeline/mesh_stats.json`.
* The toes now point forward. Face = model −Z = runtime forward, and knees bend toward the face. The `toe.L` and
  `toe.R` rests were rotated 180° about Z; no other bone changed. Every runtime consumer of the toe frame was
  checked. The ragdoll knee hinge was flipped to match (`wako_ragdoll.gd`, `axis = Vector3.RIGHT`), so a
  knock-down no longer snaps the knees.

### Clip library (`pipeline/wako_actions.py` → `game/LogicObjects/Wako/Wako.blend`)
* There are now 42 face-forward `wk_` clips: the original 33, re-timed with real anticipation, contact and
  follow-through, plus 9 new ones. The new clips are sit down, sit idle and sit up (an attentive V-leg sit), greet,
  cheer, three 120 BPM dances, and swim.
* Each clip is checked by mesh-aware guards: sole and toe ground contact, knee direction and pole, knee/body
  clearance, per-frame rotation jumps and dead holds. The pipeline reports zero guard failures. Godot imports 43
  animations with the contracted loops and lengths.
* The timing contract (durations, contact event at 0.56, locomotion phase L=0.0 / R=0.5) is described under
  "Clip timing contract migration" below.

### Gait and IK (`wako_gait.gd`, `wako_pose.gd`, `wako_helper.gd`)
* Phase is locked to distance travelled, so the feet no longer lag the body. Stride and duty adapt to speed, with a
  flight phase above about 1.8 m/s, so Wako really runs between jobs.
* Stops are planned, with settle steps. Stance soles are held in the support-local frame, so they stay planted on
  moving decks and slopes.
* Turning uses a capped torsion pivot with a body-yaw lag. The body acts with bob, lean, bank and a run tuck.
  Knees always bend forward, and terrain IK conforms the soles and toes to the ground under them.

### Head-first pickup (`wako_head_leap.gd`, `wako_pickup.gd`)
* Wako flips head-first onto the stock with a real ballistic arc and rotation. It pushes off, tucks its legs in a
  zero-splay pike, makes the impact with squash and recoil, then makes a near-ballistic return with landing
  absorption.
* Crew lifts twin the arcs of two Wakos. Wako can also toss the stock and catch it on its head.
* Interrupts continue the arc instead of turning around mid-air. The item stays the same finite part at all times.

### Backpack tool toss (`wako_back_tool.gd`, `wako_back_holder_visual.gd`)
* Tool changes are now a stunt. A hip-driven kick throws the tool up with about one turn of spin. The body steps
  forward under it, and the tool is caught by contact only on both rubber trays, with a felt weight dip and a proud
  bounce.
* The backpack is body-fitted: a 1 mm plate on the back and bronze straps that follow the skin over the roof edge.
* Retrieval reaches back, draws the tool and brings it home. Interrupts, fear, knock-downs and saves are handled at
  every phase.

### Face, eyes and attention (`wako_eyes.gd`, `wako_attention.gd`, `snow_skin_surface.gdshaderinc`, personality/voice/threat)
* The eye shader has almond lids, crisp pupils, a catchlight, worried slanted lids, a happy lower lid and an O mouth.
* The eye engine does saccades, blinks timed to events, squeeze and relief, and threat darting. Gaze follows
  stunts, cargo and the player, and gazes in a crowd are desynchronised.
* A warning runs as notice → alarm → body turn → relief. The greeting smile and the work-stroke squints are driven
  by real events from the gait, head flip and backpack code.

### Job flow (`Components/Contraptions/work_coordinator.gd`)
* The re-plan clock is refreshed after every finish and cancel. Only one idle Wako reports a blocked "needs" flag.
  Brace partners re-brace and share the lead's staging clock.
* The coordinator also hands light pickups to the head flip (`Pickup.eligible`), publishes attention points for the
  face, and chains tool fitting into the backpack throw.

## Integrating into RaulsMod

1. Copy `game/` over the mod root. Paths match the mod.
2. Run `godot --headless --path . --import` so the new `class_name` scripts and the 43 imported animations
   register.
3. Line endings: many mod scripts use CRLF. The files here keep the line endings of the original files, so diffs
   contain only real changes.
4. **Clip timing contract migration:**
   * New durations at 30 fps:
     * Loops: `wk_idle` 4.0 s, `wk_walkcycle` 0.8 s, `wk_run` 0.533 s, `wk_carry` 0.667 s, `wk_danger` 1.0 s.
     * Work strokes: `wk_inspect` 1.3, `wk_assemble` 1.0, `wk_repair` 1.1, `wk_maintenance` 1.1, `wk_unbend` 1.2,
       `wk_tool_change` 1.2, `wk_brace` 1.4, `wk_push` and `wk_pull` 1.4, `wk_operate` 1.2, `wk_place` 1.1,
       `wk_pickup` 1.2, `wk_step` 0.7, `wk_interrupted` 0.7.
   * The work contact event stays at normalized 0.56. Locomotion phase: the left foot contacts at 0.0, the right
     at 0.5.
   * New clips: `wk_sit_down` 1.6, `wk_sit_idle` 4.8 (loop), `wk_sit_up` 1.1, `wk_greet` 1.6, `wk_cheer` 0.9,
     `wk_dance_a`, `wk_dance_b` and `wk_dance_c` 4.0 each, `wk_swim` 1.0 (loop). The coordinator still uses the name
     `wk_idle` as its settle gate, so don't rename it.
5. The package tests in `game/.claude/tests/contraptions/` were updated where the contract changed:
   * Mass assertions now include the 2 kg backpack (`back_tool.holder_mass()`).
   * The asset check accepts the extended 42-clip library and still requires every track to bind to a real
     node or bone.

## Harness

The harness runs the real Wako scripts outside the full game. It copies `game/` into a work directory and adds
stubs for the systems it doesn't ship: core, tools, terrain, avatar and game state. Hand stubs win over the
generated `stubs_auto`.

```bash
harness/build.sh <workdir>                         # copy game + stubs + tests, import
harness/run_tests.sh <workdir> wako_asset wako_gait ...   # package tests, one PASS/FAIL line each
harness/run_back_checks.sh <workdir> 2             # 39 backpack stunt scenarios
WORK=<workdir> harness/capture.sh res://harness/scenes/clip_viewer.tscn out.mp4 4 --clip=wk_run --view=side,34
WORK=<workdir> harness/capture.sh res://harness/scenes/gait_lab.tscn out.mp4 15 scenario=showcase cam=q34
```

These are the available scenes. Each script's header lists its arguments.
* `clip_viewer`: authored clips.
* `gait_lab`: 40+ gait scenarios.
* `head_leap_lab`: `--case=solo|medium|crew|toss|...`.
* `back_stunt`: `--tool --side --depart --interrupt --knock --save ...`.
* `face_lab`, `face_checks*`, `face_closeups`, `face_crowd`: the face.

Software rendering uses lavapipe under Xvfb.

## Verification (final build, this branch)

| Area | Result |
|---|---|
| Package tests | `wako_asset`, `wako_native_handoff`, `wako_support` and `wako_gait` PASS. See "Known gaps" for `wako_balance`, `wako_steps` and `wako_recoil`. |
| Clip pipeline | 42 clips, 0 guard failures. Godot imports 43 animations with the right loops and lengths. |
| Head-first pickup | Solo done in 2.66 s, medium done in 2.61 s, toss caught. |
| Backpack stunt | 35/39 scenarios pass. The 4 misses are one aesthetic gate on the pickaxe-right kick (below). |
| Face | `face_checks` a, b, c and d: all pass, 0 failures. |
| Gait lab | Flat 14 ok, carry 6 ok, terrain 3 ok. One shared gate miss (below). |

## Known gaps

* **Crew head-flip:** with the backpack installed, the two-Wako crew lift fails its return check ("stock crosses
  carrying head") and ends as a failed pickup. The previous clip library fails the same way, so the clips aren't
  the cause. The interaction between the 2 kg backpack and the shared-stock return arc needs another pass.
* **`wako_balance` (assemble only):** the new, bigger mallet stroke moves the support ankle point 10.4 cm against
  a 7.5 cm gate. The clip keeps the support toe exactly planted (0 mm); the drift is the heel pivot under the
  higher draw. Inspect and loaded variants pass.
* **`wako_steps`:** the largest sole step on stairs is 5.1 cm against a 5.0 cm gate.
* **`wako_recoil`:** 5 checks fail. Two are timing: the test's second hit lands after the shorter new recovery has
  already finished. The others are the knee hand-off into the danger clip, and head cargo following one tick late
  on impact.
* **Backpack stunt, pickaxe right:** the kick adds 13.4° of thigh flexion against a 15° gate. The stroke still
  travels 0.26 m at 4.3 m/s.
* **Gait:** one ≥33 ms both-feet-up moment at low speed in the idle phase (`air_slow=1`). On the terrain course, one
  9.5° knee step on a riser. Stair crouch and steep slopes are still weaker than flat ground.
* **Not wired at runtime yet:** the new clips exist and import, but these behaviours don't play them yet:
  * the attentive V-leg sit state;
  * dance, high-five, balance and upside-down play;
  * the water dive;
  * work-stroke rate per job kind.
* **`wako_physics`:** this test needs the full contraption yard (Settings, InputGlyphs, UserPaths, weapon FX), which
  the harness doesn't stub. Run it in the mod.

## Rebuilding the character

```bash
python wako_mesh_rebuild.py  -- source.blend  mesh.blend      # legs + toe flip (bpy 4.5)
python wako_actions.py       -- mesh.blend    Wako.blend --report report.json
```

Both scripts run on the `bpy` 4.5 module, so no Blender UI is needed. For Godot to import `.blend` files, it needs a
`blender` on PATH; the harness uses a small shim around `bpy`.

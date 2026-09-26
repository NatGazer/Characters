# Giant Rhinoceros Beetle: rigged and animated

A rigged, animated Japanese rhinoceros beetle (*Trypoxylus dichotomus*) at giant-creature scale. It's built from
the two photogrammetry scans in this repository:

| Source | Used for |
|---|---|
| `cc0-74mm-rhinoceros-beetle-t-dichotom` (wings hidden) | **Base model**: head and horn, pronotum and thoracic horn, legs, underside |
| `wings` (wings open) | **Hindwings**, **elytra** (with their real underside) and the **dorsal abdomen** that is exposed when the elytra open |

![showcase](renders/showcase.jpg)

**Previews:** [`renders/videos/showreel.mp4`](renders/videos/showreel.mp4) (all behaviours, Cycles with motion blur) and one
MP4 per clip in `renders/videos/`. Hi-res stills: `renders/hero_*.jpg`.

## Files

| File | What it is |
|---|---|
| `rhinoceros_beetle.glb` | **Full-resolution version** (original scan detail, ~432k verts, original 7k/7k/4k textures), 14 animations |
| `rhinoceros_beetle_game.glb` | **Game-optimised version** (~52k triangles, 1 opaque atlas + 1 wing atlas, baked normal map), same skeleton and animations |
| `rhinoceros_beetle.blend` / `rhinoceros_beetle_game.blend` | Blender 5.0 source files with the full control rig (leg IK, poles, foot controls) and all actions |
| `textures/` | Scan textures (full-res) and `textures/game/` (baked albedo 4096, normal 2048, wing RGBA 2048) |
| `renders/` | Showreel + per-clip videos (`videos/`) and hi-res stills |
| `pipeline/` | The complete, scripted pipeline that produced everything (see below) |

## Scale and orientation

* **1 mm of the real beetle equals 6 cm.** The creature is **~4.6 m long**, the head-horn tip is **~2.6 m** above the ground, and the wingspan is **~6.5 m**.
  To change the size, scale the root node in your engine. Every animation is scale-independent.
* glTF standard orientation: **+Y up, faces +Z** (Blender: faces −Y, Z up). Feet rest on the ground plane (y = 0).
* The root bone stays at the origin in every clip (**in-place animation**). Locomotion speeds that match the foot contacts:

| Clip | Ground speed |
|---|---|
| `walk` | 0.76 m/s |
| `run` | 2.53 m/s |
| `flee` | 4.0 m/s |

## Animations (60 fps)

| Clip | Length | Type | What happens |
|---|---|---|---|
| `idle` | 8.0 s | loop | Breathing (abdomen pumping), weight shifts, insect-like look-arounds with holds, exploring antennae with twitches, a mid-leg shuffle, a front-leg tap, and an elytra settle-flick with shudder |
| `walk` | 1.6 s | loop | Metachronal wave gait (hind→mid→front per side). Body bob, roll and yaw sway, counter-rotating pronotum, lagging abdomen, antennae sampling |
| `run` | 0.72 s | loop | Alternating tripod gait, forward lean, stronger sway, elytra jitter |
| `attack` | 3.8 s | once | Complete attack from the stance: alert, **rears up with horn raised**, elytra snap open, hindwings spread, then **tilts forward**, lunges with the horn scooping low, **pries/flips the horn up**, shakes its head, and returns to the stance |
| `attack_enter` | 0.9 s | once | Stance → combat-ready |
| `attack_ready` | 2.0 s | loop | **Combat-ready threat display**: body tilted forward, elytra open, hindwings raised and buzzing, horn feints, tracking sway, restless front feet, stridulation pumping |
| `attack_strike` | 1.9 s | once | Strike from the ready pose back to the ready pose (coil, lunge, pry-flip, head shake) |
| `attack_exit` | 0.9 s | once | Combat-ready → stance (wings fold, elytra close with a snap) |
| `frightened` | 2.6 s | once | Startle flinch, elytra flare-and-snap, head retracts, antennae pinned back, trembling retreat with nervous glances. Ends in the `scared_loop` pose |
| `scared_loop` | 2.0 s | loop | Cowering, fast trembling, squeaking (abdomen stridulation), quick glances |
| `flee` | 2.24 s | loop | Panicked tripod run: low and leaning, erratic yaw, head down, antennae pinned, fluttering elytra |
| `takeoff` | 3.4 s | once | Warm-up pumping, elytra open, hindwings unfold (root → fold → tip), wing beat ramps up, push-off, climbs to flight pose. Ends in `fly` |
| `fly` | 1.0 s | loop | 4 Hz wing beat (figure-of-eight tip path, feathering, passive flex), elytra held up and vibrating, body pitched 34°, legs dangling. Body is **1.6 m above the root** |
| `land` | 3.2 s | once | Descends from `fly`, legs reach down, touchdown compression, wings fold, elytra close with a snap, settle wiggle |

Clips designed to chain (end/start poses match closely; a short 0.1–0.2 s cross-fade hides the remaining secondary motion):
`takeoff`→`fly`→`land`, `attack_enter`→`attack_ready`↔`attack_strike`→`attack_exit`, `frightened`→`scared_loop`.
`idle`, `walk`, `run`, `flee`, `attack` start and end in (or oscillate around) the neutral stance.

## Skeleton (47 bones, all exported)

```
root
└ body                          (thorax + abdomen base, centre of mass)
  ├ pronotum                    (thoracic horn)
  │ ├ head                      (head horn)
  │ │ ├ antenna.L/R → antenna_club.L/R
  │ ├ front_femur.L/R → front_tibia → front_tarsus1 → front_tarsus2 → front_claw
  ├ abdomen                     (pygidium / breathing / stridulation)
  ├ elytron.L/R                 (hinge axis = bone Y, derived from the real open/closed scans)
  ├ wing.L/R → wing_mid → wing_tip   (hindwing root, fold line, apex)
  ├ mid_femur.L/R  → tibia → tarsus1 → tarsus2 → claw
  └ hind_femur.L/R → tibia → tarsus1 → tarsus2 → claw
```

**Hard shell, rigid motion.** Every exoskeleton part is weighted **100% to a single bone**, so the parts move as
separate rigid plates, like a real beetle. No part deforms smoothly. Each cut between parts is sealed with a
dark joint membrane: a dome on the child side and a socket on the parent side. The membrane only shows when a
joint opens, and then it reads as intersegmental membrane.
The only soft weights are on the hindwing membrane (`wing` / `wing_mid` / `wing_tip`), so the wings can bend and fold.

### Leg IK in your engine

The legs are fully animated in every clip, so the clips work stand-alone. To drive the legs with your own IK:

* **IK chain:** `*_femur` → `*_tibia`, with the end effector at the tibia tail (the "ankle").
* **Foot:** `*_tarsus1` → `*_tarsus2` → `*_claw` lie on the ground. Treat the whole tarsus as the foot: orient it to the ground or leave it animated.
* **Knees** point up and outwards.
* **Hips:** the front legs hang from the **pronotum** (they move with it when the pronotum tilts). The mid and hind legs hang from the **body**.
* With the legs overridden by IK, the body / pronotum / head / abdomen / elytra / wings / antennae animation still carries all the character.

The `.blend` files contain the original control rig: `foot_ik.*` controls, `pole.*` knee targets, and IK and damped-track constraints on every leg. Tweak or re-author in Blender and re-export.

## Game version

* ~47k triangles for the body and ~5k for the wings. The original UV layout (thousands of photogrammetry UV islands) was **not decimated**. Instead:
  1. Each rigid part was welded and decimated on its own with its joint caps, so the parts stay closed and rigid.
  2. The result was UV-unwrapped fresh into one atlas (plus one wing atlas).
  3. Albedo and a tangent-space normal map were **baked from the full-resolution scan**, so the fine surface relief is kept.
* Hindwings use a single double-sided alpha-blended layer (the scan had two membrane layers 0.1 mm apart, which causes alpha-sorting trouble in real-time engines). The full-res version uses the same single layer.
* Same skeleton, bone names and animations as the full-res version, so the two can be swapped or used as LODs.

## Pipeline (reproducible)

`pipeline/run_all.sh` rebuilds everything from the two raw scans (Python 3.11 + `bpy==5.0.1`, numpy, scipy, pillow, mapbox-earcut):

1. **Scan analysis:** weld the UV-split vertices, compute geodesic distance fields from the claws, and find leg joints from centerline ring radius and bend.
2. **Segmentation** of the single fused scan into 40 rigid parts:
   * Legs are split by geodesic intervals.
   * Femurs that lie against the underside are found by ventral-visibility ray casts.
   * Head, pronotum and abdomen are split by anatomical cut planes.
   * Labels are then cleaned up.
3. **Elytra transplant:** the open elytra from the wings scan are registered onto the closed shell of the base scan (PCA-initialised ICP, then symmetric similarity, then affine, then a symmetric non-rigid fit). The fit gives both the closed pose and the **hinge axis**: the open↔closed motion is a nearly pure ~100–105° rotation.
4. **Dorsal abdomen patch** from the wings scan (upward ray casts under the elytra), with its rim snapped onto the base body.
5. **Hindwings** registered with the body, and a **folded pose** designed to fit the 1–3 mm cavity under the elytra (a Z-fold: root, fold line, apex).
6. **Rig:** bones at the measured joints, IK pole angles solved numerically so the bind pose is exact.
7. **Procedural animation:** loop-safe noise, key poses with insect-like snap/overshoot easing, gait generators, a wing fold/flap model, and overlapping action. Baked at 60 fps.
8. **Automatic checks:** IK reach, ground contact, loop seams (all 0.000°), and per-frame rotation jumps.
9. glTF export (full-res), then the game LOD bake and export.

## Notes and limitations

* The two scans are different individuals. The transplanted elytra and dorsal abdomen were non-rigidly fitted to the base body, and the thin elytra margins from the base scan move with the elytra.
* Hindwing folding under the elytra is approximated with a 3-segment Z-fold plus chord compression. A real beetle's folding pattern is more intricate, but the wing is hidden under the closed elytra.
* The source scans are CC0 (ffish.asia / floraZia.com).

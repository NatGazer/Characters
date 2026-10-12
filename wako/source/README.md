# Wako animation rebuild package

Start with **WAKO_ANIMATION_REBUILD.md**. It defines the character, the requested animation/interaction matrix, the IK/rig/topology work, integration contracts and acceptance.

- **LogicObjects/Wako/Wako.blend** is the current editable Blender source: `wako_art` armature, `wakoMesh`, 9 deform bones, 557 source vertices / 1,110 triangles, 33 authored actions.
- **LogicObjects/Wako/textures/Player.png** is the current 1024×1024 painted skin/face atlas. Preserve its facial UV mapping or update the supplied shaders.
- **Exports/Wako_rigged_current.glb** is a portable rigged exchange export with the same 9 joints, 33 actions, embedded texture and normalized skin weights.
- **Exports/** also contains the exact current Godot animation libraries, bone/rest/action inventory, and actual generated backpack, 5 kg Mechanical mallet and 3 kg Fastener pickaxe visual models. These auxiliary models are reference geometry, not replacement gameplay bodies.
- **LogicObjects/Wako/** contains the current runtime animation, IK, skin/eyes, tool/head handling, personality and interaction code. **Components/** supplies relevant scheduler/tool/part/gun/water/ragdoll context; **.claude/tests/** supplies existing regression coverage.
- **ReferenceMedia/** and **REFERENCE_MEDIA.md** contain 18 compact actual game clips with their original captions. These show the current baseline, including unfinished quality; they are not a detached target animation reel.
- **CONTENTS.json** lists files and checksums for the snapshot.

## Import and scope

Open the `.blend` to edit topology, rig, weights and authored actions. Import the GLB in another DCC if convenient. In Godot use the supplied original importer settings and the matching full RaulsMod project.

Custom Godot snow/cornea/expression shaders and procedural/native IK cannot be baked faithfully into ordinary GLB material/animation data. Their source is included. Runtime contact/event callbacks are preserved in the supplied Godot `.tres` libraries and scripts, rather than being silently turned into timers.

This is an asset and readable integration snapshot, not the full runnable game: engine binaries, `.godot` cache, generated Island terrain and unrelated assets are intentionally excluded. The project-relative source references assume the matching full project. Do not import the whole source snapshot as a standalone Godot game.

## Baseline status

Preserve forward knees, same-item contact-only attachment, supported tool use, physically continuous head flips, saved item state and useful-job priority. Current work travel runs at 3.4 m/s when the feet are free; heavy/loaded handling remains controlled. The latest saved-Island Pickaxe removal has a continuous knee handoff and returns both original Lamp parts to storage. Full multi-worker Rover construction remains incomplete (latest original 180-second check reached 5/7 parts); installed-wheel tool-stow access and the wider gameplay loop still need work. Requested forward-body-advance backpack stunts, complete natural personality/water integration and the V-legged seated state are not declared finished.

The animation agent may improve bones, weights, IK and local topology substantially. Preserve identity and actual game semantics; migrate names/references explicitly, and prove the complete interaction in rendered play.

## Runtime libraries in this export

- authored: 34 entries
- head_pickup: 2 entries
- recoil: 8 entries
- work: 32 entries

The 34 authored entries are the 33 `wk_*` actions plus `RESET`; the 76 total entries also include runtime work, recoil and head-pickup libraries.

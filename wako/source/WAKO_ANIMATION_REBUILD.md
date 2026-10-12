# Wako animation, rig and interaction rebuild

## The assignment

Recreate Wako's animation and interaction presentation so the creature feels alive, cute, quick, capable and physically believable. Improve the IK system, skeleton and skin weights, and remesh bendable regions if that is needed for convincing deformation. Improve the actual playable character, not only an animation showcase.

The user's most important complaints and requests are:

- Walking feels wrong: legs lag behind, knees must bend forward, and terrain IK must respond properly.
- Wako should usually RUN between useful jobs, with intense energy during building and dismantling. Work should have brisk anticipation, fast strokes, satisfying ease-outs and continuous transitions.
- Picking up a part must be a convincing head-first acrobatic flip, with real rotation and leg tuck. A part must never simply translate or instantly appear on its head.
- Wako has NO ARMS. Feet manipulate tools, parts and gun controls; cargo normally travels on the head.
- Tool changes should be a stunt: throw the actual item upward, move the body slightly forward, and let the item fall accurately into the backpack. Catch only at actual contact.
- The backpack must touch and sit convincingly against the body.
- Wako should show personality: smile with its eyes, watch points of interest, warn about real enemies, flee when appropriate, make funny working sounds, dance, run, jump and play with other Wako.
- Play includes jumping foot high-fives, balancing together and one Wako becoming upside down on another. Wako should like water, become excited, run to it and dive.
- Add the attentive seated V-leg waiting pose described below.
- Every real item must remain the same finite item through the interaction. Preserve mass, ammunition, condition, wear, stored charge, ownership and save/load state.

Treat the current model and scripts as a starting point with valuable gameplay contracts. Existing checked features are baselines to preserve, not a declaration that the animation quality is finished.

## Package use and source map

Paths in this brief are project-relative. The archive README describes the enclosing archive directory. A source snapshot is not a standalone runnable Godot project; use the matching full RaulsMod project to integrate and test it.

| Path | Why it matters |
|---|---|
| LogicObjects/Wako/Wako.blend | Editable character mesh, armature, skin weights and authored action library. This is the primary DCC source. |
| Exports/Wako_rigged_current.glb | Current rigged exchange export with authored actions and skin bindings. Custom Godot snow/eye shaders are supplied separately and are not fully represented by GLB materials. |
| LogicObjects/Wako/Wako.blend1 | Blender backup, if included. Historical fallback, not an additional active character. |
| LogicObjects/Wako/textures/Player.png | Existing painted face/skin atlas. |
| LogicObjects/Wako/Wako.blend.import | Godot importer settings, named skin import and clip loop settings. |
| LogicObjects/Wako/Wako.tscn | Current playable RigidBody3D wrapper and physical capsule. |
| LogicObjects/Wako/snow_skin.gdshader | Main skin shader. |
| LogicObjects/Wako/snow_skin_surface.gdshaderinc | Snowy PBR skin, cornea, eyelids, smile, gaze and alarm implementation. |
| LogicObjects/Wako/snow_eye.gdshader | Temporal/reactive eye next pass; does not supply a separate eye mesh or eye bitmap. |
| LogicObjects/Wako/wako_helper.gd | Animation setup, locomotion, action clock, head/toe anchors, cargo, tools, expressions and contact events. |
| LogicObjects/Wako/wako_pose.gd | Final terrain/work IK, support balance, forward knee planes and pose continuity caches. |
| LogicObjects/Wako/wako_head_leap.gd | Native force-assisted head-first pickup flip, geometric contact, loaded return and landing. |
| LogicObjects/Wako/wako_head_pickup.gd | Supported non-airborne head-pickup variant derived from authored clips. |
| LogicObjects/Wako/wako_pickup.gd | Small-part free-toe grip, native toss and assisted head catch. |
| LogicObjects/Wako/wako_back_tool.gd | Same-item foot-to-back throw, native flight/catch, retrieval, clearance, interruption and persistence. |
| LogicObjects/Wako/wako_back_holder_geometry.gd and wako_back_holder_visual.gd | Physical and visual back holder. Geometry must remain consistent with its appearance. |
| LogicObjects/Wako/wako_tool_return.gd and wako_guarded_rollback.gd | Continuous supported tool/cancellation recovery. |
| LogicObjects/Wako/wako_portable_gun.gd | Receiving, supported foot grip, aiming, firing custody and same-gun return. |
| LogicObjects/Wako/wako_recoil.gd | Directional grounded hit presentation; observes the already funded native impact. |
| LogicObjects/Wako/wako_ragdoll.gd and wako_native_pose.gd | Native limb/body collisions, ragdoll and finite supported recovery. |
| LogicObjects/Wako/wako_personality.gd, wako_personality_voice.gd and wako_voice_bank.res | World perception, greetings, warning/flee intentions and creature voices. |
| LogicObjects/Wako/wako_threat.gd | Brief armless visual notice/warning phrase and escape presentation. |
| LogicObjects/Wako/wako_idle_play.gd and wako_idle_play_pose.gd | Optional idle intentions, authored/procedural dance, running, hops and water behavior. |
| LogicObjects/Wako/wako_paired_foot_pose.gd | Partner foot contact/high-five presentation. |
| LogicObjects/Wako/wako_paired_balance.gd and wako_paired_balance_pose.gd | Two-Wako balancing interaction. |
| LogicObjects/Wako/wako_upside_down_play.gd | Native upside-down partner stunt and safe recovery. |
| Components/Contraptions/work_coordinator.gd | Authoritative automatic jobs, cooperative crew, action transitions and work/contact admission. |
| Components/Contraptions/worker_access.gd, worker_tool_access.gd and worker_storage_access.gd | Actual reachable/supported work and finite tool/stock access. |
| Components/Contraptions/part_catalog.gd and contraption_part.gd | Part masses, dimensions, capabilities, stock identities, installed state and physical carrier behavior. |
| Components/Contraptions/gun_control_point.gd | Shared mounted gun control contract; Wako are weapon/utility operators, not motion-cockpit drivers. |
| Components/Avatar/ragdoll/ | Shared native ragdoll machinery used by Wako. |
| Components/Water/buoyancy.gd | Existing water forces reused by Wako water play. |
| goals.md and CLAUDE.md | Current requirements and project run/integration instructions. |
| FeatureGallery/gallery.json | Actual-game media captions and provenance; distinguish Island play from focused tests/model previews. |

The package may include useful neighboring source and tool models. Keep their project-relative references intact. Inspect the archive manifest instead of assuming an imported cache or compiled game is a replacement for the editable source.

## Character identity and visual direction

Wako is a small armless creature with a rounded cuboid snowy-white head/body, expressive glossy eyes and two articulated legs with compact rounded endings. Preserve its recognizable silhouette, friendly face and proportions. The character is charming and unusually capable; avoid generic human mocap, imaginary hand poses, robotic sliding, sluggish work or exaggerated squash that makes its body appear weightless.

The current snowy material includes a restrained white-blue tint, small stable reflective facets and glossy corneal highlights. Sparkle comes from real lit normal/roughness variation, not blinking emissive dots. Expressions are per mesh instance so different Wako can behave independently while sharing materials.

The face is painted into the existing atlas. Shader eye centers are approximately UV (0.409, 0.715) and (0.409, 0.914); the mouth patch is around (0.323, 0.815). Atlas U runs vertically on the face and V across it. Preserve these islands when changing topology, or update the shader masks and verify blinks, smiles, gaze, alarm and mouth presentation at every camera angle. New eyelid geometry or blend shapes are welcome if they improve quality, but must replace or cooperate with the current expression system without doubled lids, tearing, eye swimming or extra material work per Wako.

The original square foot blocks were removed. Keep rounded foot endings with a readable real gripping toe and believable contact patch; do not restore invisible broad boot colliders to hide IK errors.

## Existing rig and import contract

Current runtime expects nine named deform bones:

| Bone | Role |
|---|---|
| Bone | Rigid head/body root; bone index 0 in existing runtime. |
| Bone.001 | Left upper leg / hip chain. |
| Bone.003 | Left lower leg / knee chain. |
| Bone.005 | Left ankle / rounded foot. |
| toe.L | Left manipulation toe. |
| Bone.002 | Right upper leg / hip chain. |
| Bone.004 | Right lower leg / knee chain. |
| Bone.006 | Right ankle / rounded foot. |
| toe.R | Right manipulation toe. |

The effective runtime chains are Bone.001 -> Bone.003 -> Bone.005 -> toe.L and Bone.002 -> Bone.004 -> Bone.006 -> toe.R, under the body root. The skin mesh node is named wakoMesh; runtime finds Skeleton3D and AnimationPlayer in the imported Wako scene.

The current editable Blender file was inspected read-only in Blender 4.5.4 LTS. Its armature object is wako_art; the mesh object is wakoMesh (mesh datablock Cube.002), with one Armature modifier, UVMap, 557 vertices, 744 polygons and 1,110 triangulated faces. It has nine matching vertex groups/deform bones. Reported Blender world dimensions are about 0.849 x 0.398 x 1.390 m; Blender is Z-up, so do not read those dimensions as Godot Y-up bounds. The external Player.png atlas is 1024 x 1024. The inventory JSON in the package supplies exact bone head/tail positions, hierarchy, source action names, frame ranges and durations. The GLB is a useful exchange copy; retain Wako.blend as the editable authority and validate material/deformation parity after import.

Preserve names, rest frames, skin binding and action paths by default. If a better rig requires changes, supply an explicit old-to-new bone mapping and update all IK, ragdoll, grip, clearance, support, animation and save restoration consumers together. Merely renaming to friendly names breaks real gameplay. Additional nondeforming DCC controls are fine; do not export accidental duplicate animated roots, IK targets or constraint rigs as competing runtime skeletons.

Godot import currently uses named skins, root scale 1.0, tangents, LOD generation, 30 fps sampled authored animation and imported rest as RESET. The game evaluates physics and skeleton modifiers at 120 Hz. Animation source sampling at 30 fps does not authorize stepping the playable pose at 30 Hz.

Runtime forward is -worker._model.global_basis.z. Determine the Blender-to-Godot basis from the actual imported rest transforms; do not assume Blender Euler signs equal world-forward signs. Lower-bone rest axes are mirrored. The native knee hinge currently flexes about bone -X, with a one-way forward range. Use a stable forward bending plane in the character-facing/world frame and retain it through near-straight knees, turns and pose-owner changes.

Current physical wrapper: 22 kg native body, 0.29 m capsule radius, 1.02 m capsule height, ride height 0.85 m. Cargo and back-holder loads contribute to real load/mass accounting. These values explain the current motion envelope; do not silently change them to make the character appear easier to animate. Rest-scale or geometry changes require an explicit collision, sole, reach, head-roof and mass audit.

## Rig weights, topology and remeshing

Begin with a deformation audit in the source file and in the imported game. Inspect neutral, shallow/deep forward knee bend, wide support stance, high work-foot lift, toe grip, run swing, tucked flip, seated V pose and both-foot variants. A attractive neutral mesh is insufficient.

1. Identify the actual bend regions and any pinching, collapsing volume, candy-wrapper twist, faceting or skinny joint necks.
2. Keep the body/head rigid unless a deliberate and controlled expression treatment improves it. Do not blur root weights into the eyes or distort the face while walking.
3. Use organized loops around knee and ankle bends, with sufficient front/back thickness and smooth longitudinal flow into both adjacent segments. Avoid stars, stretched triangles or long thin polygons on the most compressed crease.
4. Remesh locally where topology is the cause. Preserve the existing proportions, UV face islands and recognizable silhouette. A dense whole-body remesh that increases cost without better deformation is not the goal.
5. Paint normalized weights with progressive transitions across upper/lower and ankle/toe regions. Remove unintended distant-bone influence, unweighted vertices and asymmetrical discontinuities. Mirror intentionally, then inspect each side because imported rest axes differ.
6. Preserve readable compact toe articulation and its grip orientation. Toe skin must actually deform; moving only a hidden toe bone while the visible end remains rigid is inadequate.
7. Add twist/deformation bones or corrective shapes only when demonstrably useful. Update runtime mapping and native shape assumptions if deform bones or proportions change.
8. Check the exported/imported result, not only Blender's pose preview. Preserve tangent quality, smooth normals, UVs, bind matrices and scale. Test any corrective shapes under the engine's actual modifier order.
9. Supply a compact deformation sheet and short real-game clips with the before/after comparison. Report triangles, vertices, material/surface count, bones, influences and measured runtime cost.

Aim for deformation that stays soft and readable without making the legs rubber tubes. Do not conceal weight problems by keeping all animations nearly straight-legged.

## Animation style, timing and movement

Every important action should have a readable intention: look at the object, choose support, gather briefly, execute quickly, let the result affect the body, and settle. Pose silhouette and timing matter more than simply increasing amplitude.

Use short anticipation, deliberate acceleration, fast useful motion and a satisfying deceleration/ease-out. Favor strong action contrasts over uniformly slow sine motion. Preserve a believable center of mass and use overlap in gaze, body, legs, tool and backpack. A supporting leg should visibly accept weight before the other leg works. Head cargo should react to support rhythm without sliding off its actual attachment or wobbling independently of the native load.

Animation must follow actual displacement. Playback cadence, step length and turn poses should reflect ground-relative native velocity. Do not speed up a walk loop while the native body remains stationary, leave a leg trailing after the body accelerates, or allow planted feet to skate through a stop.

Useful-job free-foot travel currently targets 3.4 m/s, with approximately 0.13 s supported departure acceleration and arrival braking. Controlled head-carry travel targets 2.2 m/s; genuinely heavy/cooperative loads and moving-deck travel remain controlled. Preserve this distinction. Energetic work does not mean sprinting a 500 kg shared load or walking with an unsafe dangling pickaxe.

Blend from the last evaluated pose and support state, not from a rest pose or an unevaluated animation cache. Preserve angular/positional continuity when action owners switch, including work -> place/brace, work -> gait, tool fitting -> back throw, flip landing -> carry, gun recoil -> replant and optional play -> useful work.

## Current authored clips and action integration

There are 33 imported authored wk_* clips:

The package also includes the exact current Godot runtime libraries in Exports/: Authored_imported.tres (33 clips plus RESET), Runtime_work.tres (32 entries), Runtime_recoil.tres (8 entries) and Runtime_head_pickup.tres (2 entries). Godot_runtime_inventory.json records all 76 current entries and the actual imported bone rest transforms. These runtime libraries preserve callbacks and procedural variants that ordinary GLB animation data cannot represent.

- wk_idle, wk_walkcycle, wk_run and wk_carry.
- wk_danger.
- Paired _L and _R clips for: wk_pickup, wk_place, wk_inspect, wk_assemble, wk_repair, wk_maintenance, wk_unbend, wk_tool_change, wk_brace, wk_push, wk_pull, wk_operate, wk_step and wk_interrupted.

Current source durations at the authored 30 fps are listed here for integration. L/R pairs have the same range and length. These are present-day values, not an instruction to retain poor timing.

| Source clip family | Frames | Seconds |
|---|---|---|
| wk_idle | 0-48 | 1.600 |
| wk_walkcycle | 0-24 | 0.800 |
| wk_run | 0-18 | 0.600 |
| wk_carry | 0-27 | 0.900 |
| wk_danger | 0-33 | 1.100 |
| wk_pickup_L/R | 0-46 | 1.533 |
| wk_place_L/R | 0-45 | 1.500 |
| wk_inspect_L/R | 0-57 | 1.900 |
| wk_assemble_L/R | 0-63 | 2.100 |
| wk_repair_L/R | 0-64 | 2.133 |
| wk_maintenance_L/R | 0-63 | 2.100 |
| wk_unbend_L/R | 0-70 | 2.333 |
| wk_tool_change_L/R | 0-50 | 1.667 |
| wk_brace_L/R | 0-54 | 1.800 |
| wk_push_L/R and wk_pull_L/R | 0-51 | 1.700 |
| wk_operate_L/R | 0-45 | 1.500 |
| wk_step_L/R | 0-30 | 1.000 |
| wk_interrupted_L/R | 0-27 | 0.900 |

The runtime clones these into a shared work/ AnimationLibrary. work/carry and work/run are reused locomotion loops. danger_L and danger_R are runtime aliases of the one authored danger source. Other work variants are nonlooping. Action/contact events are deliberately absent from the raw imported clips: runtime adds exactly one method event at normalized phase 0.56 for eligible actions, and none for danger/interrupted.

wako_helper.gd owns begin_action, action, action_progress, the actual action clock and action_contact/action_finished signals. Standard work entry currently blends over 0.18 s. Existing inspect/assemble/repair IK timing remaps retain the same true 0.56 contact event; do not put a second event in Blender, change a visual ease curve so the tool misses that event, or claim success solely because the timer elapsed.

A work event is admitted only when the matching current action is active, the helper is supported, and the actual toe/tool/control contact passes its existing checks. Build/dismantle effects, sounds, sparks and wear must follow admitted contact. Physical head pickup has its own geometry/contact owner; it must not also fire an ordinary pickup event.

If you change an action duration or event timing, update the coordinator, hold/resume logic, pose remapping, tool manipulation, effects and tests coherently. Existing durations are compatibility facts, not a reason to keep poor pacing. Preserve once-only completion and safe interruption. Document any intentional contract migration.

## Required animation and interaction matrix

P0 is the core enjoyable construction loop. P1 makes Wako alive during normal play and combat. P2 completes richer social/world behavior. Priorities order implementation; every row is still required. L/R means either foot role must work, not merely a mirrored film.

| Priority | Animation / state | Loop, entry and exit | Required contact, expression and world behavior |
|---|---|---|---|
| P0 | Neutral alert idle | Quiet loop with varied breathing/weight shifts; enter from real settled feet. | Stable support, independent blinks/gaze, no perpetual oscillation or synchronized clone crowd. |
| P0 | Walk | Speed-matched loop; clean start, stop and turn variants. | Terrain plants, forward knees, compact toe roll, no lagging legs/skating. |
| P0 | Energetic useful-job run | Brisk start -> run loop -> readable brake/settle. | Native 3.4 m/s free-foot travel; eyes lead destination, body lean follows paid acceleration. |
| P0 | Pivot, short reposition and sidestep | Small one-shot steps with a retained supporting sole. | Real reachable footholds, no rotating both feet through the floor. |
| P0 | Step up/down and uneven terrain | Anticipated swing and supported landing; recover smoothly. | Actual obstacle/terrain heights, correct ankle normals and whole-tool clearance. |
| P0 | Approach a part/work target | Run/controlled travel -> stop -> orient -> support transfer. | Stop at actual reachable stance; look toward real stock/socket/tool. |
| P0 | Head-first pickup flip | Supported gather -> push-off -> continuous outbound rotation/tuck -> contact -> loaded return -> landing. | Actual head roof touches actual part; same part attaches without pose jump; native launch reaction and finite tracking assistance. |
| P0 | Head-first cooperative heavy pickup | Synchronized supported launch/contacts/return; remain one shared job. | Both actual heads and source contact geometry, conserved original load, no duplicated cargo. |
| P0 | Small-part foot pickup | Free-toe reach -> actual grip -> lift -> bounded toss -> head catch -> settle. | Retain opposite toe-held tool; native flight, same stock, no instant transfer. |
| P0 | Loaded head carry | Load-aware gait loop with braking/turn variants. | Real load and support, cargo/holder/terrain clearance; 2.2 m/s light solo intent and controlled heavy crews. |
| P0 | Position/place/install cargo | Approach -> align -> supported pose -> socket/contact -> release -> sole recovery. | Existing source continuity, real connector compatibility and closing work; part does not appear at final target. |
| P0 | Inspect L/R | Brief look/preparation -> deliberate probe -> eased release. | Real point and actual toe/tool contact; supporting leg accepts load before the lift. |
| P0 | Assembly/build L/R | Brief draw -> fast mallet stroke -> impact/reaction -> eased recovery; repeat as real work requests. | Same mallet, real fastener contact at admitted event; sparks/sound/wear at impact, no empty-air hits. |
| P0 | Dismantle L/R | Readable pickaxe hook/loosening stroke -> release -> retrieve/recover original part. | Use same salvage tool and installed stock; support and full shaft clearance, continuous work -> place handoff. |
| P0 | Precision repair L/R | Distinct careful preparation/probe/tap and recovery. | Real damaged component/condition improvement; energetic but precise, not a copied large hammer swing. |
| P0 | Maintenance L/R | Service-specific short phrase, repeat with real job demand. | Native safe work access, actual compatible tool, interruption if the platform becomes unsafe. |
| P0 | Straighten/unbend L/R | Gather against support -> sustained visible pressure -> release. | Real compliant joint and reaction, different silhouette from inspection or hammering. |
| P0 | Tool fetch and fit L/R | Approach actual tool -> empty-toe reach -> grip/contact -> supported lift/recovery. | Same finite tool leaves actual rack/container; preserve binding/pose and opposite sole. |
| P0 | Upward back-pack tool stunt | Foot gather -> upward release -> small supported body advance -> falling item -> real seated catch -> settle. | Same native item, gravity, throw reaction, actual holder contact; body/backpack never teleports to meet it. |
| P0 | Back tool retrieval L/R | Look/shift -> reach actual seated item -> real toe contact -> pull clear -> return to work pose. | Preserve full tool bounds, current evaluated hip/toe/binding, finite reach and opposite support. |
| P0 | Work completion / departure | Satisfied accent -> continuous tool/sole recovery -> safe stow -> fast departure. | No arbitrary wait after a clear safe transition; do not run while a blocking foot tool is still unsafe. |
| P0 | Pause/cancel/target loss | Interrupt from every phase; preserve current pose and physical payload. | Finish safe release/landing/replant; recover same loose item if needed; no stale work event. |
| P0 | Cargo/tool obstruction | Visible hesitation/reposition/recovery with plain reason. | Real obstruction and bounded recovery; neither clip through an installed machine nor abandon ownership. |
| P0 | Push/pull/brace L/R | Plant -> lean/load -> sustained force -> eased release. | Real reachable object, opposite support, meaningful reaction; no simulated object translation. |
| P0 | Utility station operation L/R | Enter supported stance -> real pedal/control contact -> duty loop -> safe exit. | Operate utilities/weapons; Wako never drives a motion cockpit. Preserve moving station support. |
| P1 | Gun receiving / lend | Supported preparation -> actual toe grip -> acknowledged ready pose. | Same shared player gun, unchanged magazine/reserve/condition, actual transfer contact. |
| P1 | Foot gun aim / ready | Stable supported stance and bounded tracking. | Real visible hostile target, clear muzzle/whole gun, no forehead gun or invented arms. |
| P1 | Foot gun fire/recoil/replant | Trigger at actual funded shot -> directional recoil -> balance correction -> replant. | Real gun impulse already funded once; no second decorative force or infinite-ammo proxy. |
| P1 | Gun return / take / holster | Continuous supported item transfer or safe native release. | Same gun node/state returns; armed travel and backpack transitions need genuine full-gun clearance. |
| P1 | Mounted gun control | Foot reach/control -> actual contact -> operate -> withdraw. | Shared gun system and real contraption control point; real aim, ammo, power and recoil. |
| P1 | Nearby player greeting | Eyes look/smile first -> brief supported tilt/nod -> ease to idle. | Real visible player; arriving foot plants settle before body greeting; useful work interrupts promptly. |
| P1 | Natural blink, smile, interest gaze | Sparse independent overlays on valid states. | Stable eyelids and wet eyes; expression respects effort, warning and actual attention. |
| P1 | Threat notice / warn | Quick attention -> short warning phrase/call -> watch/escape. | Observe a real live hostile core; no warning after it dies, is tamed or loses hostile control. |
| P1 | Flee / take cover / look back | Paid departure -> fast escape gait -> brief glance -> supported cover settle. | Preserve cargo/tool/job cancellation recovery and actual navigable cover. |
| P1 | Grounded small hit / stumble | Directional recoil from actual native hit -> replant/recover. | Impact direction and strength readable; strong hits transition to genuine ragdoll. |
| P1 | Native fall / ragdoll / get-up | Actual body/limb fall -> supported gather -> finite assisted rise -> stable feet. | No scripted upright reset, infinite torque or floating get-up; load/tool safely recovered. |
| P1 | Follow player / regroup / stay | Natural starts/stops/turns, fast safe regroup, relaxed stay. | Same recruited Wako, actual player position, safe terrain, useful-job priorities and danger response. |
| P1 | Captive / rescued / recruited reaction | Readable guarded waiting -> relief/acknowledgement -> accompany. | Rescue follows genuine guard defeat; retain same actor/identity across camp streaming/save. |
| P1 | Working voices and completion | Sparse short varied calls between impacts; pleased completion accent. | Actual admitted work, nearby turn-taking, danger suppression and fast pause fade; avoid a constant loop. |
| P1 | Attentive V-leg sitting | Supported lower -> seated idle/alternating subtle legs -> supported rise. | Exact requested pose below; head follows a genuine point of interest and interrupts safely. |
| P1 | Idle dance | Distinct authored phrases with musical timing/accents; finish on a phrase and settle. | Actual supported feet, limited frequency, real useful-job interruption; no endless random oscillation. |
| P1 | Playful solo run/jump | Interested glance -> short local run/hop -> actual landing -> idle. | Ground impulse and safe route, landing absorption, no optional play stealing cargo/work. |
| P2 | Jumping foot high-five | Invite -> mutual approach -> launch -> real foot contact -> recoil -> supported landing. | Feet, not hands; both watch partner and smile after real contact, free foot recovers beneath body. |
| P2 | Partner grab/balance | Invite/support selection -> actual foot/head/body contact -> balance phrase -> release. | Native supported contact with safe finite forces; no welded duplicate or hidden prop supporting actors. |
| P2 | Upside-down-on-partner stunt | Mutual setup -> real launch/rotation -> head/body support -> amusing balance -> release/land. | Actual lower support and upper native bodies; interruptions preserve ongoing motion and safe recovery. |
| P2 | Water noticing/excitement | Genuine water attention -> excited eyes/call/gather -> supported departure. | Actual water volume/shore, safe depth and route; no interest in arbitrary blue scenery. |
| P2 | Water approach and dive | Quick run -> supported launch -> tucked/head-first dive -> real water entry. | Existing water forces, honest splash at surface contact, proper heading and immersion. |
| P2 | Water play / swim / emerge | Varied short play -> surface breath/look -> swim/exit -> shore replant. | Finite buoyancy/drag, actual head/skin immersion, safe exit and useful-job interruption. |
| P2 | Unexpected world reaction | Curious object glances, surprised small recoveries and occasional crew fun. | Tied to actual world/partner events and personality variation; never blocks meaningful player work. |

### The requested attentive seated pose

Wako sits on the ground with its legs spread into a V. Knees point upward but remain near the ground; lower legs are roughly parallel and lift/lower slightly in alternating rhythm. The head/body points forward and a little upward, watching real points of interest.

The sit must lower and rise through believable supported motion. Plan clearance for the body, legs, backpack and any retained item. Keep the seated motion subtle and relaxed; it is a attentive waiting pose, not a fast exercise loop. Blend from current planted soles, and use actual finite ground forces/contact when the body changes height. A new job or danger should lead into a safe supported rise. Do not teleport back to standing or preserve a fictional standing capsule through the ground.

## Item and tool semantics

The current catalogue has two main physical work tools:

- assembly_tool: Mechanical mallet, 5 kg, approximately (0.24, 1.05, 0.13) m; build, repair, unbend and maintenance capabilities.
- salvage_tool: Fastener pickaxe, 3 kg, approximately (0.61, 1.05, 0.18) m; dismantle capability.

Treat the entire tool as real geometry, including the crossbar, head and shaft. A clear gripping toe does not prove the rest of the tool clears the floor, body, cargo, installed chassis or nearby worker.

Dismantle currently maps to the assemble action clock, with the pickaxe and different actual work target/caption. Give it a recognizable loosening/hook action without breaking the genuine contact/completion contract. Building should visibly fasten the connection; repair should improve the actual damaged part; unbend should apply sustained controlled work to the actual deformed joint.

Wako foot role can change. Work, control and support feet are not always the same side. A retained tool can occupy one toe while the other operates a station or receives a small part. Test both feet, both tools, bare feet, back-stowed items and cargo combinations.

Back tool states currently include foot, prepare, flight, back, retrieve and return. The native toss flight is approximately 0.56 s; toe movement/turn, reach, full-tool clearance, ballistic arc and geometric catch all have finite limits. Improve presentation without loosening these guards to force an impossible throw. The user's desired slight forward body movement is still a separate unfinished enhancement, not proof supplied by the existence of the current back toss.

Parts used for building, salvage or storage usually use the real head-first pickup controller. Small compatible parts can use the separate free-toe toss/head-catch branch. Preserve both interactions; do not replace every load with one convenient canned pickup animation.

Portable player/Wako/mounted guns are one shared system. Preserve the exact weapon, GunPhysics mass/inertia, ammunition, reserve magazines, cooldown, condition and state when lending, mounting, taking, returning or saving. A cartoon recoil pose may amplify readability but cannot create another shot impulse or remove the actual funded recoil.

## IK and physical interaction architecture

The game combines authored AnimationPlayer poses, SkeletonModifier3D IK and actual native bodies. A successful redesign should simplify and clarify those responsibilities instead of adding another competing pose writer.

- Run on the physics clock, currently 120 Hz. Keep one authoritative final supported pose publication and explicit transient pose owners.
- Solve from actual rest lengths and current evaluated hips. Keep a stable forward knee pole near full extension; avoid left/right branch flips or root-frame discontinuities.
- During stance, retain the sole in the support body's LOCAL frame and derive its current world frame each tick. Moving/rotating platforms must carry a planted foot without slipping or trailing.
- During swing, plan ahead using real ground-relative motion and anticipated obstacles, with deliberate lift and landing. React promptly to start/stop/turn; excessive smoothing causes the reported lagging legs.
- Separate visual pose smoothing from collision/support admission. Smooth transitions must not grant nonexistent ground contact, extra reach or a safe path through an obstacle.
- Shift/tilt the body toward the actual planted support before lifting a work foot. Account for cargo and holder mass/geometry; retain alignment of the head load.
- Track ankle and toe orientations, not only positions. A tool with a continuously correct toe point can still rotate its full shaft through the floor.
- Transport the last evaluated world knee planes, soles, ankle frames and native attachment pose into a new state. Explicitly handle work -> place/brace, cancelled work -> gait and retrieval -> work.
- Use final evaluated poses/caches after skeleton modifier evaluation. Godot can restore authored skeleton poses after evaluation; a late plain get_bone_global_pose query can describe the wrong visual frame.
- Preserve right-handed bases, normalized quaternions and finite transforms. Do not interpolate matrices into reflected/skewed frames.
- Cache reusable geometry and queries. Reuse the existing support observations; do not scan all world objects or build mesh bounds on every helper tick.

Current head flip is explicitly assisted animation physics. It applies a supported native launch impulse and finite in-air force/torque tracking, with source/tool/holder/leg/crew clearance. It does not obtain convincing physics by assigning a prescribed body transform every tick. Existing limits include 8.5 m/s maximum planned speed, 2g acceleration and 24 rad/s² angular acceleration. Preserve or transparently justify physical changes; do not remove collisions or inflate limits just to make a prettier film.

Attachments may change carrier ownership only after real geometric contact. Preserve the item's world pose across the binding change and include its momentum/reaction in the existing accounting. On missed contact, obstruction or interruption, retain/release and recover the original body at its actual current state. A save during an airborne toss must restore an airborne/loose item safely, not manufacture a successful catch.

Use native ragdoll bodies for actual hard falls. Existing native limb masses/shapes and supported get-up assistance are part of the real system. Do not animate a perfectly upright visual Wako while its native body is sideways, or show a full tool safely stowed while the actual tool remains attached to a foot.

## World and scheduler interaction

Wako choose useful jobs automatically. The coordinator owns reservation, priority, dependencies, crew size, original stock and completion. Animation communicates and supports that work; it does not create or secretly finish it.

The full loop must be pleasurable to watch: discover salvage -> select/build a plan -> useful crew rapidly approach -> fetch the right tool -> collect original stock -> carry -> fit -> visibly work -> complete a usable mechanism -> repair/extend/dismantle -> recover and store the same parts.

Priorities include safe cancellation, urgent repair/closure, finite stock dependencies, tool compatibility, stations and cooperative heavy jobs. Clear actual blocked states must remain actionable. Useful work and danger interrupt optional fun; an airborne stunt cannot be cancelled by teleporting, so its safe physical recovery may outlast the intention change.

Helpers operate utility and weapon stations. Players control locomotion; Wako do not drive motion cockpits. Rescued Wako can Follow/Stay/Useful work, with the same identity and ownership through territory unloading and save/load.

Present actual intent and completion. Looking at an enemy, water or another Wako must use a real currently relevant target. Do not keep a warning gaze after enemy death, play a success cheer after a blocked build or show water excitement without a viable shore.

## What the current project proves, and what remains open

Read current goals.md and actual gallery captions before making broad completion claims. The package reflects a moving project, not a frozen claim that every goal is finished.

Existing verified baseline pieces include:

- Named nine-bone source, 33 imported clips, rounded weighted foot endings and snowy/glossy appearance.
- Terrain IK with forward knees, actual supported walking/start/stop/turn and load-reactive support.
- Continuous same-part head-first flip, small-part toe toss, cargo carry/install and finite cooperative handling.
- Real back-tool toss/catch/retrieval and a seated back cradle; retrieval begins from current evaluated hips/toe/binding.
- Supported foot-only work/control and genuine same-gun receiving, shots, recoil/replant and return.
- Greeting/eye smile, bounded threat presentation, authored dance phrase ending and directed foot high-five contact/landing.
- Actual free-foot useful-job travel at 3.4 m/s and fast supported tool strokes. A saved Island Lamp removal clip verifies actual pickaxe contact and continuous forward-knee work -> place handoff.
- Work impact sound at admitted contact and sparse creature voices that fade on interruption.

These checks preserve important invariants. They do not prove the complete animation direction is delightful, the whole crew finishes every blueprint, or every spontaneous/social/water state works well in normal Island play.

Open quality and integration work includes the complete brisk building/dismantling rhythm, full construction ease, all interruption/traffic contexts, the upward throw plus forward body advance, attentive sitting, broad spontaneous personality/social/water behavior, whole-loop combat/armed travel and final graphical/animation polish.

Known failure patterns to actively inspect:

- Stale/rest-space IK or bone reading makes legs lag and breaks attachments at state entry.
- Knee pole ownership can flip abruptly at work -> place/brace despite a nearly fixed sole/tool. A prior real dismantle capture showed a roughly 73-degree one-evaluation knee jump; a continuity fix is now in source. Preserve it and test every neighboring transition, not only the originally fixed case.
- Tool fetching, foot fitting and stowing can crowd a depot or hit the installed chassis. Full original rover construction previously stopped short of all seven installed parts despite the running improvement. Do not disguise this as an animation-only success or enlarge timeouts.
- First-contact fitting, supported sole recovery, low floor clearance and full pickaxe shaft clearance are sensitive. A visually plausible toe pose can still violate actual support or native tool clearance.
- A separate attentive sit candidate exists in the project worktree but is unreferenced/unverified and excluded from this package runtime baseline. Implement and validate the requested feature deliberately rather than assuming the file is active.
- Focused-yard success, a model orbit, or one clean three-second work excerpt does not prove a complete Island build/recovery session.

## Concrete deliverables for the rebuilding agent

1. Editable updated Wako.blend, with organized armature/control rig, documented rest pose and action names.
2. Updated skinned mesh, corrected normalized weights and any justified local remeshing/corrective shapes.
3. Godot-compatible exported/imported result with unchanged or explicitly migrated names, scale, bindings and clip semantics.
4. Reworked authored action library and runtime IK/state-transition integration. Implement the full matrix; preserve the actual game's finite stock and job system.
5. Improved eye/body expressions and optional personality interactions that coexist with useful jobs and danger.
6. Compact actual-game rendered media for the important delivered states, with honest scene labels and clear file names.
7. A short integration/change note listing altered bones, topology/material costs, action/event changes, intentional assistance and remaining issues. Do not deliver only a proposed plan or a detached Blender animation reel.

## Validation and acceptance

Start with close full-character and deformation views, then verify the actual mechanics on terrain and moving support, then complete the real Island loop. Tests are regression evidence; rendered observation determines whether the motion feels alive and physically convincing.

Use the existing project scenes/scripts, including .claude/tests/contraptions/wako_asset.tscn, wako_gait.tscn, wako_support.tscn, wako_steps.tscn, wako_balance.tscn, wako_pickup.tscn, wako_pickup_load.tscn, wako_native_handoff.tscn, wako_native_carry.tscn, wako_tool_return.tscn, wako_repair.tscn, wako_recoil.tscn, wako_threat.tscn, wako_cooperative_carry.tscn, wako_cooperative_yard.tscn, mobile_tools.tscn and tools.tscn. Inspect their actual coverage before trusting them. Some newer specialized checks live in temporary folders and may not be included in this archive; use the matching full project rather than inventing a pass result.

Required acceptance cases:

- Idle, walk and run in both camera modes: start, accelerate, stop, 90/180-degree turn, reverse/reposition, uneven terrain, step up/down, slopes and moving/rotating platforms.
- Either foot as working/control foot; bare, mallet, pickaxe, back-stowed tool, portable gun, head cargo and cooperative heavy load.
- Whole head-first pickup from anticipation through actual contact, attachment, return, landing, carry and installation. Track same source identity/native body/mass/condition and inspect body/leg rotation continuity.
- Complete upward tool stunt with the requested actual body advance, real ballistic fall, geometric backpack catch and continuous retrieval. Check all tools, a gun where supported, interruption at every phase, blocked arc and save/load during motion.
- Real build, inspect, repair, maintenance, unbend, dismantle and store. Actual effects require actual admitted contact; no duplicate events and no action completion from a timer alone.
- Continuous current evaluated knee/sole/ankle/tool frames at action ownership changes. Watch frame by frame around contact, release, place/brace and gait entry; aggregate average smoothness can hide a single severe pop.
- Actual portable and mounted gun receiving/aim/fire/recoil/replant/return, same ammunition and state, real live-hostile target filtering and no repeat recoil funding.
- Jobs/danger interrupt greetings, sitting, dance, pair play and water safely. A real launched body retains momentum until supported recovery.
- Real captive rescue followed by Follow/Stay/Useful work, territory unload/reload and save/load without replacement actors.
- Natural occurrence of personality, high-fives, partner balance/upside-down antics and actual water dive/play/exit in ordinary Island play. Directed fixtures alone do not close natural frequency or integration.
- Real multi-worker construction/extension/cancel/dismantle loop: crew traffic, finite tool access, actual materials, useful energy and recovery. Repeat with an installed chassis and moving/stopped work platforms; do not teleport workers or stock to bypass access.
- Profile normal and crowded play at the actual 120 Hz physics rate. The project targets roughly a 4 ms physics tick budget before spiraling. Measure costs and spikes honestly; reduce repeated work rather than skipping force/contact ticks.

Record pictures at no more than 1280x720 and videos normally 3-10 s, 720p30, compact compressed files. Show each feature's whole relevant phase, including anticipation and recovery; close-ups alone cannot prove support, and an orbit cannot prove mechanics. Add delivered features to FeatureGallery through tools/feature_gallery.py with precise labels. Include real game sound when useful and keep original timing.

The finished Wako should be immediately readable: a little creature sees a real problem, eagerly runs to it, chooses a convincing support pose, performs fast skilled foot/head work, visibly feels the result, and smoothly returns to the world. That quality must hold while the same physical parts, tools, guns and jobs continue to work.

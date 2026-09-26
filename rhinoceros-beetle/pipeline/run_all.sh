#!/bin/bash
# Rebuilds everything in rhinoceros-beetle/ from the two raw scans in rhinoceros-beetle/source/.
# Requirements: python3.11 with  bpy==5.0.1 numpy scipy pillow mapbox-earcut  (pip install ...)
# Headless Blender rendering/baking needs Mesa EGL (libegl1 libgl1-mesa-dri) for Workbench; Cycles runs on CPU.
set -e
cd "$(dirname "$0")"
mkdir -p work
step(){ echo "== $*"; }
step "0  scan analysis (weld, geodesics, elytra fit, wing-model registration)"; python3 stage0_analysis.py
step "1  ventral visibility + segmentation";  python3 downvis.py; python3 segment.py >/dev/null; python3 cleanup.py | tail -1
step "2  joints";                             python3 joints.py >/dev/null
step "3  dorsal patch + elytra refinement";   python3 raycast_patch.py; python3 refine_ely.py | tail -2
step "4  textures";                           python3 textures.py
step "5  assemble parts + caps";              python3 prep.py | grep -E "caps|remnant"
step "6  Blender scene, rig, weights";        python3 blender_build.py | grep saved; python3 fixpoles.py | grep "pole angle"
step "7  hindwing fold pose";                 python3 wingfold.py -- "$(cat wingfold_params.json)" work/wf 0 "[]" >/dev/null
step "8  animations";                         python3 bake_all.py -- all | grep -E "baked|saved"
step "9  checks";                             python3 verify.py | grep worst; python3 seamcheck.py | grep "max step"
step "10 export full-res GLB";                python3 export_glb.py -- ../rhinoceros_beetle.blend ../rhinoceros_beetle.glb | grep exported
step "11 game LOD";                           python3 game_geo.py | grep Game_; python3 game_bake.py | grep baked; python3 game_textures.py
python3 game_final.py | grep saved;           python3 export_glb.py -- ../rhinoceros_beetle_game.blend ../rhinoceros_beetle_game.glb | grep exported
rm -f ../*.blend1

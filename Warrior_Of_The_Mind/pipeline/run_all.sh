#!/bin/bash
# Rebuild the Warrior of the Mind from the reference images (see README for requirements).
set -e
cd "$(dirname "$0")"
python3 stage0_segment.py          # masks of the references
python3 upscale.py                 # 4x Real-ESRGAN upscales (cached)
python3 body_fit.py                # MakeHuman body fitted to the measured skeleton
cp work/body.npz work/body_base.npz   # chin_sculpt.py (in run_model.sh) starts from this
python3 face_warp.py              # painting -> head landmark warp (head geometry kept)
./run_model.sh                     # geometry, uv, texel maps, textures, rig
python3 anims.py                   # all animation clips
python3 export_godot.py            # glTF + WebP textures for Godot, final .blend

#!/bin/bash
# Rebuild the Warrior of the Mind from the reference images (see README for requirements).
set -e
cd "$(dirname "$0")"
python3 stage0_segment.py          # masks of the references
python3 upscale.py                 # 4x Real-ESRGAN upscales (cached)
python3 body_fit.py                # MakeHuman body fitted to the measured skeleton
python3 face_fit.py                # dense landmark face fit (front + profile silhouettes)
./run_model.sh                     # geometry, uv, texel maps, textures, rig
python3 anims.py                   # all animation clips
python3 export_godot.py            # glTF + WebP textures for Godot, final .blend

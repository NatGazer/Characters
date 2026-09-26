#!/bin/bash
# Rebuild geometry -> uv layout -> texel maps -> textures
set -e
cd "$(dirname "$0")"
python3 chin_sculpt.py
python3 face_warp.py
python3 build.py
python3 uvlayout.py
python3 bake_maps.py
python3 project_tex.py
python3 tex_armor.py
python3 tex_cloth.py
python3 tex_body.py
python3 tex_hair_eyes.py
python3 rig.py

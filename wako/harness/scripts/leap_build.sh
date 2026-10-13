#!/usr/bin/env bash
# Build a harness workdir for the head-leap lab: the shared build.sh plus the
# harness-only StockBounds overlay (real catalogue bounds instead of a fixed box).
# Usage: harness/scripts/leap_build.sh <workdir>
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:?workdir}"
"$HERE/build.sh" "$WORK"
DEST="$WORK/Components/Contraptions/depot_stock_layout.gd"
if [ ! -e "$HERE/../game/Components/Contraptions/depot_stock_layout.gd" ]; then
  cp "$HERE/scripts/leap_overlay/depot_stock_layout.gd" "$DEST"
  echo "leap overlay: real catalogue StockBounds.bounds installed"
fi

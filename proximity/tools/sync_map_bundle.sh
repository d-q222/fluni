#!/bin/bash
# Copy the heat map team's offline user map into the FlUni app bundle folder.
# Build it first:  node heatmap/tools/build_app_bundle.mjs sim/runs/<run> --out heatmap/out/app-bundle
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../heatmap/out/app-bundle/"
dst="$here/../FlUni/Resources/app-bundle/"
[ -f "$src/index.html" ] || { echo "No bundle at $src (run build_app_bundle.mjs first)" >&2; exit 1; }
mkdir -p "$dst"
rsync -a --delete "$src" "$dst"
echo "Synced app-bundle: $(du -sh "$dst" | cut -f1), $(find "$dst" -type f | wc -l | tr -d ' ') files"

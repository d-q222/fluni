#!/bin/bash
# One command that rebuilds everything FlUni bundles from the heat map pipeline, so the app's building numbers are
# always the ones the heat map shows (the same model, the same run):
#   - FlUni/Resources/app-bundle/      the Map tab (heatmap/tools/build_app_bundle.mjs -> heatmap/out/app-bundle)
#   - FlUni/Resources/building_heat.csv the walk-in warning (heatmap/tools/precompute.mjs -> heatmap/out/<run>/,
#                                       also the file the phone's live refresh fetches from the laptop)
#   - FlUni/Resources/building_rooms.csv the phone's room per building (tools/make_building_rooms.py)
# The heat map's P(sick) is the mean-field in model/out/<run>/meanfield.csv; precompute.mjs quietly falls back to
# infer.js without it, so this script stops instead.
#
# Run from anywhere:  proximity/tools/sync_map_bundle.sh [run_id]   (default: the app's default run)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
res="$here/../FlUni/Resources"
run="${1:-$(sed -n 's/.*static let defaultRunID = "\([^"]*\)".*/\1/p' "$here/../FlUni/PSickLoader.swift")}"
[ -n "$run" ] && [ -d "$repo/sim/runs/$run" ] || { echo "No run sim/runs/$run" >&2; exit 1; }
[ -f "$repo/model/out/$run/meanfield.csv" ] || { echo "No model/out/$run/meanfield.csv: run node model/meanfield-cli.mjs sim/runs/$run first" >&2; exit 1; }
cd "$repo"

node --max-old-space-size=8000 heatmap/tools/precompute.mjs "sim/runs/$run" --out "heatmap/out/$run" | grep -E "^(totals|building_heat|backtest)"
# p_sick.csv (infer.js) belongs in model/out/<run>/ (heatmap/README.md "Big runs"); keep it only if it changed there.
if cmp -s "heatmap/out/$run/p_sick.csv" "model/out/$run/p_sick.csv"; then rm "heatmap/out/$run/p_sick.csv"
else echo "Note: heatmap/out/$run/p_sick.csv differs from model/out/$run/p_sick.csv (left in place)" >&2; fi
rm -f "heatmap/out/$run/timeline_changes.csv.gz"  # the presenter reads the run's own copy in sim/runs/<run>/

node --max-old-space-size=8000 heatmap/tools/build_app_bundle.mjs "sim/runs/$run" --out heatmap/out/app-bundle
mkdir -p "$res/app-bundle"
rsync -a --delete heatmap/out/app-bundle/ "$res/app-bundle/"
cp "heatmap/out/$run/building_heat.csv" "$res/building_heat.csv"
python3 "$here/make_building_rooms.py" "sim/runs/$run"
echo "Synced run $run: app-bundle $(du -sh "$res/app-bundle" | cut -f1), building_heat.csv $(($(wc -l < "$res/building_heat.csv") - 1)) rows"

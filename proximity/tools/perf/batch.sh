#!/bin/bash
# batch.sh <before.app> <after.app> <outdir>: the perf before/after set on one phone (~35 min). See README.md.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; BEFORE="$1"; AFTER="$2"; OUT="$3"; mkdir -p "$OUT"; cd "$OUT"
DEV=${DEV:-00008150-001E213A0C80401C}; export DEV
for T in before after; do
  APP=$BEFORE; [ $T = after ] && APP=$AFTER
  xcrun devicectl device install app --device $DEV "$APP" >/dev/null 2>&1 && echo "installed $T" || { echo "INSTALL FAILED $T"; exit 1; }
  "$HERE/rec.sh" 'Time Profiler' tp_idle_$T.trace 20
  "$HERE/rec.sh" 'Time Profiler' tp_demo_$T.trace 20 -demoPeer contagious@0.5
  "$HERE/rec.sh" 'Time Profiler' tp_tour_$T.trace 45 -demoPeer contagious@0.5 -perfTour YES
  for i in 1 2; do "$HERE/rec.sh" 'Animation Hitches' ah_tour_${T}_$i.trace 45 -demoPeer contagious@0.5 -perfTour YES; done
  for i in 1 2 3; do "$HERE/rec.sh" 'App Launch' launch_${T}_$i.trace 6; done
  "$HERE/rec.sh" 'Activity Monitor' am_tour_$T.trace 30 -perfTour YES
  "$HERE/rec.sh" 'Time Profiler' tp_warmstart_$T.trace 5; "$HERE/warm.sh" 'Animation Hitches' ah_warm_$T.trace
  "$HERE/rec.sh" 'Power Profiler' pp_idle_$T.trace 60
done
for T in before after; do
  echo "== $T"
  for k in idle demo; do echo "  $k: $(python3 "$HERE/an.py" tp_${k}_$T.trace --from 5 --to 19.5 | grep -E 'tick|steady' | tr -s ' ' | tr '\n' ';')"; done
  echo "  tour: $(python3 "$HERE/an.py" tp_tour_$T.trace | grep -E 'tabs on|intro done|map load|map drawn' | tr -s ' ' | tr '\n' ';')"
  for i in 1 2; do echo "  hitches $i: $(python3 "$HERE/hitch.py" ah_tour_${T}_$i.trace -tour | tr -s ' ' | tr '\n' ';')"; done
  echo "  warm-open hitches: $(python3 "$HERE/hitch.py" ah_warm_$T.trace | head -1)"
done
echo "App Launch, Activity Monitor (WebContent memory) and Power Profiler traces: open them in Instruments."

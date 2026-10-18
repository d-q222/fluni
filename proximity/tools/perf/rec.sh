#!/bin/bash
# rec.sh <template> <out.trace> <seconds> [app args...]: cold-launch FlUni on $DEV under an Instruments template.
# Always a test launch (-skipOnboarding YES: the owner's saved data is neither read nor written) with -keepAwake YES.
# Retries up to 3 times if FlUni exits before the time limit.
DEV=${DEV:-00008150-001E213A0C80401C}
T="$1"; O="$2"; S="$3"; shift 3
for try in 1 2 3; do
  PID=$(xcrun devicectl device info processes --device $DEV 2>/dev/null | grep 'FlUni.app/FlUni' | awk '{print $1}' | head -1)
  [ -n "$PID" ] && xcrun devicectl device process terminate --device $DEV --pid $PID >/dev/null 2>&1
  sleep 2; rm -rf "$O"
  xcrun xctrace record --template "$T" --device $DEV --time-limit ${S}s --output "$O" \
    --launch -- com.fluni.app -skipOnboarding YES -keepAwake YES "$@" > /dev/null 2>&1
  d=$(xcrun xctrace export --input "$O" --toc 2>/dev/null | grep -o '<duration>[0-9.]*' | cut -d'>' -f2)
  echo "$O try=$try duration=${d:-none}"
  python3 -c "import sys; sys.exit(0 if float('${d:-0}')>=$S-1 else 1)" && break
done

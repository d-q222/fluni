#!/bin/bash
# warm.sh <template> <out.trace>: FlUni must already be running. Records while it goes to the background (Settings
# opens) and comes back 3 times, so the intro plays on warm opens.
DEV=${DEV:-00008150-001E213A0C80401C}
T="$1"; O="$2"; rm -rf "$O"
PID=$(xcrun devicectl device info processes --device $DEV 2>/dev/null | grep 'FlUni.app/FlUni' | awk '{print $1}' | head -1)
xcrun xctrace record --template "$T" --device $DEV --time-limit 22s --output "$O" --attach $PID >/dev/null 2>&1 &
sleep 4
for i in 1 2 3; do
  xcrun devicectl device process launch --device $DEV com.apple.Preferences >/dev/null 2>&1; sleep 2.5
  xcrun devicectl device process launch --device $DEV com.fluni.app >/dev/null 2>&1; sleep 3.5
done
wait

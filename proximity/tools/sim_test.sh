#!/bin/bash
# Two-simulator test on the Mac, before touching real phones. Simulators have no Bluetooth, and
# their UWB is fake (always 0 m), so the cases listen on GPS only and move the simulators with
# simulated locations. Tests the peer link, status exchange, GPS ranging, fusion, exposure and alerts.
#
#   tools/sim_test.sh <case> [seconds]
#   cases: together | apart | walkaway | control
#
# Uses simulators named "Fluni A" and "Fluni B" (create them with any iPhone type your runtime has).
set -euo pipefail
cd "$(dirname "$0")/.."

CASE=${1:-together}
SECS=${2:-45}
BUNDLE=com.fluni.proxtest
QUAD=37.42750,-122.16970   # Main Quad
NEARBY=37.42751,-122.16970 # ~1 m away
FAR=37.43650,-122.16970    # ~1 km away

udid() { xcrun simctl list devices | grep -m1 "$1 (" | grep -oE '[0-9A-F-]{36}'; }
A=$(udid "Fluni A"); B=$(udid "Fluni B")
[[ -n "$A" && -n "$B" ]] || { echo "create simulators 'Fluni A' and 'Fluni B' first" >&2; exit 1; }

if [[ -z "${SKIP_BUILD:-}" ]]; then
  xcodebuild build -project FluniProx.xcodeproj -scheme FluniProx -destination "id=$A" \
    -derivedDataPath build/sim CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | grep -E "error:" || true
  for d in $A $B; do
    xcrun simctl boot "$d" 2>/dev/null || true
    xcrun simctl install "$d" build/sim/Build/Products/Debug-iphonesimulator/FluniProx.app
    xcrun simctl privacy "$d" grant location $BUNDLE
  done
fi

A_RISK=contagious; A_LOC=$NEARBY
case $CASE in
  together) ;;
  apart)    A_LOC=$FAR ;;
  walkaway) ;;
  control)  A_RISK=none ;;
  *) echo "unknown case $CASE" >&2; exit 1 ;;
esac
xcrun simctl location "$A" set "$A_LOC"
xcrun simctl location "$B" set "$QUAD"

echo "[test] case=$CASE A risk=$A_RISK at $A_LOC, B listens on GPS at $QUAD, ${SECS}s"
launch() {  # udid label args...
  local d=$1 label=$2; shift 2
  xcrun simctl launch --console-pty --terminate-running-process "$d" $BUNDLE "$@" 2>&1 \
    | grep --line-buffered '\[fluni\]' | sed -u "s/^/[$label] /"
}
launch "$A" A -risk $A_RISK -speed 60 -sources GPS &
launch "$B" B -risk none -speed 60 -sources GPS &
if [[ $CASE == walkaway ]]; then
  sleep 25
  echo "[test] A walks 1 km away"
  xcrun simctl location "$A" set "$FAR"
  sleep $((SECS - 25))
else
  sleep "$SECS"
fi
kill $(jobs -p) 2>/dev/null || true
echo "[test] done case=$CASE"

#!/bin/bash
# Builds, installs and launches Fluni Prox on 2-3 connected iPhones, streaming every console
# with a phone prefix. Phone A is the "sick" one; B (and C) listen.
#
#   tools/pair_test.sh <case> [seconds]
#   cases: fused | uwb | ble | gps | control
#
# Phones: set PHONES="udidA udidB [udidC]", or every paired, connected iPhone is used (max 3).
# Needs FLUNI_TEAM (your Apple development team ID) for signing.
set -euo pipefail
cd "$(dirname "$0")/.."

CASE=${1:-fused}
SECS=${2:-60}
BUNDLE=com.fluni.proxtest

if [[ -z "${PHONES:-}" ]]; then
  J=$(mktemp)
  xcrun devicectl list devices --json-output "$J" >/dev/null
  PHONES=$(python3 -c '
import json,sys
ds=json.load(open(sys.argv[1]))["result"]["devices"]
ok=[d["hardwareProperties"]["udid"] for d in ds
    if d["hardwareProperties"].get("deviceType")=="iPhone"
    and d["hardwareProperties"].get("reality")!="simulated"
    and d["connectionProperties"].get("pairingState")=="paired"
    and d["connectionProperties"].get("tunnelState")!="unavailable"]
print(*ok[:3])' "$J")
  rm -f "$J"
fi
read -r -a P <<< "$PHONES"
(( ${#P[@]} >= 2 )) || { echo "need at least two connected iPhones" >&2; exit 1; }

case $CASE in
  fused)   B_SOURCES=UWB,BLE,GPS; A_RISK=contagious ;;
  uwb)     B_SOURCES=UWB;         A_RISK=contagious ;;
  ble)     B_SOURCES=BLE;         A_RISK=contagious ;;
  gps)     B_SOURCES=GPS;         A_RISK=contagious ;;
  control) B_SOURCES=UWB,BLE,GPS; A_RISK=none ;;
  *) echo "unknown case $CASE" >&2; exit 1 ;;
esac

if [[ -z "${SKIP_BUILD:-}" ]]; then
  FLUNI_TEAM=${FLUNI_TEAM:?set FLUNI_TEAM} xcodegen generate -q
  xcodebuild build -project FluniProx.xcodeproj -scheme FluniProx -destination generic/platform=iOS \
    -derivedDataPath build/dd -allowProvisioningUpdates -quiet 2>&1 | grep -v DVTDevice || true
  APP=build/dd/Build/Products/Debug-iphoneos/FluniProx.app
  for d in "${P[@]}"; do xcrun devicectl device install app --device "$d" "$APP" >/dev/null; done
fi

echo "[test] case=$CASE A=${P[0]} risk=$A_RISK  listeners=${P[*]:1} sources=$B_SOURCES  for ${SECS}s"
launch() {  # phone label args...
  local p=$1 label=$2; shift 2
  xcrun devicectl device process launch --device "$p" --console --terminate-existing "$BUNDLE" "$@" 2>&1 \
    | grep --line-buffered '\[fluni\]' | sed -u "s/^/[$label] /"
}
launch "${P[0]}" A -risk "$A_RISK" -speed 60 &
L=(B C)
for i in $(seq 1 $((${#P[@]} - 1))); do
  launch "${P[$i]}" "${L[$((i - 1))]}" -risk none -speed 60 -sources "$B_SOURCES" &
done
sleep "$SECS"
kill $(jobs -p) 2>/dev/null || true
echo "[test] done case=$CASE"

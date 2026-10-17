#!/usr/bin/env bash
# Two-simulator test on the Mac, before touching real phones. Simulators have no Bluetooth, and
# their UWB is fake (always 0 m), so the cases listen on GPS only and move the simulators with
# simulated locations. Tests the peer link, status exchange, GPS ranging, fusion, exposure and alerts.
#
#   tools/sim_test.sh <case> [seconds]
#   cases: together | apart | walkaway | control
#
# Uses two normal-iPhone simulators named "Fluni Prox A" / "Fluni Prox B" (iPhone 17 Pro by default;
# override with SIM_TYPE="iPhone 17"). They are created if missing, on any installed runtime that
# supports that device type. The "iPhone Duo" type is never used. Exit status is non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."

CASE=${1:-together}
SECS=${2:-45}
BUNDLE=com.fluni.proxtest
SIM_TYPE=${SIM_TYPE:-iPhone 17 Pro}
QUAD=37.42750,-122.16970   # Main Quad
NEARBY=37.42751,-122.16970 # ~1 m away
FAR=37.43650,-122.16970    # ~1 km away
PIDS=()

die() { echo "[test] ERROR: $*" >&2; exit 1; }
[[ $SIM_TYPE != *Duo* ]] || die "iPhone Duo is not allowed; pick a normal iPhone in SIM_TYPE"

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  set +e
  local p
  for p in "${PIDS[@]:+${PIDS[@]}}"; do kill -TERM -- "-$p" 2>/dev/null; done
  sleep 1
  for p in "${PIDS[@]:+${PIDS[@]}}"; do kill -KILL -- "-$p" 2>/dev/null; done
  wait 2>/dev/null
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
set -m

case $CASE in
  together|apart|walkaway|control) ;;
  *) die "unknown case $CASE (together|apart|walkaway|control)" ;;
esac

# Prints "<udid>" of a usable simulator named $1, creating it on a suitable runtime if needed.
# Existing sims of the Duo type, or on a runtime that does not support $SIM_TYPE, are ignored.
find_or_create() {
  local name=$1 out
  out=$(python3 - "$name" "$SIM_TYPE" <<'PY'
import json, subprocess, sys
name, typ = sys.argv[1:3]
sh = lambda *a: json.loads(subprocess.run(["xcrun", "simctl", "list", "-j", *a], capture_output=True, text=True, check=True).stdout)
types = {t["name"]: t["identifier"] for t in sh("devicetypes")["devicetypes"] if "Duo" not in t["name"]}
tid = types.get(typ)
if not tid:
    print("NOTYPE"); sys.exit()
ok = [r for r in sh("runtimes")["runtimes"] if r.get("isAvailable") and r.get("platform") == "iOS"
      and any(d["identifier"] == tid for d in r.get("supportedDeviceTypes", []))]
if not ok:
    print("NORUNTIME"); sys.exit()
rt = sorted(ok, key=lambda r: [int(x) for x in r["version"].split(".")])[-1]["identifier"]
for d in sh("devices")["devices"].get(rt, []):
    if d["name"] == name and d.get("isAvailable") and d.get("deviceTypeIdentifier") == tid:
        print("FOUND", d["udid"]); sys.exit()
print("CREATE", tid, rt)
PY
)
  case $out in
    FOUND*) echo "${out#FOUND }" ;;
    CREATE*) read -r _ tid rt <<< "$out"; xcrun simctl create "$name" "$tid" "$rt" ;;
    *) echo "[test] no installed iOS simulator runtime supports '$SIM_TYPE'." >&2
       echo "[test] download a standard iOS simulator runtime: xcodebuild -downloadPlatform iOS" >&2
       exit 1 ;;
  esac
}
A=$(find_or_create "Fluni Prox A")
B=$(find_or_create "Fluni Prox B")
[[ -n "$A" && -n "$B" ]] || die "could not set up simulators"

if [[ -z "${SKIP_BUILD:-}" ]]; then
  LOG=$(mktemp)
  if ! xcodebuild build -project FluniProx.xcodeproj -scheme FluniProx -destination "id=$A" \
      -derivedDataPath build/sim CODE_SIGNING_ALLOWED=NO -quiet >"$LOG" 2>&1; then
    grep -E "error:" "$LOG" | head -20 >&2 || true
    rm -f "$LOG"; die "build failed (run xcodegen generate first if FluniProx.xcodeproj is missing)"
  fi
  rm -f "$LOG"
  for d in $A $B; do
    xcrun simctl boot "$d" 2>/dev/null || true
    xcrun simctl bootstatus "$d" -b >/dev/null 2>&1 || die "simulator $d did not finish booting"
    xcrun simctl install "$d" build/sim/Build/Products/Debug-iphonesimulator/FluniProx.app
    xcrun simctl privacy "$d" grant location $BUNDLE
  done
fi

A_RISK=contagious; A_LOC=$NEARBY
case $CASE in
  apart)   A_LOC=$FAR ;;
  control) A_RISK=none ;;
esac
xcrun simctl location "$A" set "$A_LOC"
xcrun simctl location "$B" set "$QUAD"

echo "[test] case=$CASE A risk=$A_RISK at $A_LOC, B listens on GPS at $QUAD, ${SECS}s"
launch() {  # udid label args...   (background job = own process group)
  local d=$1 label=$2; shift 2
  xcrun simctl launch --console-pty --terminate-running-process "$d" $BUNDLE "$@" 2>&1 \
    | grep --line-buffered '\[fluni\]' | sed -u "s/^/[$label] /" || true
}
launch "$A" A -risk $A_RISK -speed 60 -sources GPS & PIDS+=($!)
launch "$B" B -risk none -speed 60 -sources GPS & PIDS+=($!)
for ((t = 0; t < SECS; t++)); do
  sleep 1
  if [[ $CASE == walkaway && $t == 25 ]]; then
    echo "[test] A walks 1 km away"
    xcrun simctl location "$A" set "$FAR"
  fi
  for p in "${PIDS[@]}"; do
    kill -0 "$p" 2>/dev/null || die "a simulator console stopped after ${t}s"
  done
done
echo "[test] done case=$CASE"

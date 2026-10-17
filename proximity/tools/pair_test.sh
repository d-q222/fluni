#!/usr/bin/env bash
# Builds, installs and launches Fluni Prox on 2-3 connected iPhones, streaming every console
# with a phone prefix. Phone A is the "sick" one; B (and C) listen.
#
#   tools/pair_test.sh <case> [seconds]
#   cases: fused | uwb | ble | gps | control
#
# Phones: set PHONES="udidA udidB [udidC]", or every ready, connected iPhone is used (max 3).
# Needs FLUNI_TEAM (your Apple development team ID) for signing; tools/doctor.sh shows a hint.
# SKIP_BUILD=1 reuses the installed build. Exit status: 0 = ran to completion, non-zero = a phone
# was not ready, build/install failed, or a console died early (the reason is printed).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE/.."

CASE=${1:-fused}
SECS=${2:-60}
BUNDLE=com.fluni.proxtest
TMP=$(mktemp -d)
PIDS=()

die() { echo "[test] ERROR: $*" >&2; exit 1; }

# Each console runs in its own process group (set -m), so killing the group takes devicectl,
# grep and sed down together. Safe to run more than once.
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  set +e
  local p
  for p in "${PIDS[@]:+${PIDS[@]}}"; do kill -TERM -- "-$p" 2>/dev/null; done
  sleep 1
  for p in "${PIDS[@]:+${PIDS[@]}}"; do kill -KILL -- "-$p" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
set -m

case $CASE in
  fused)   B_SOURCES=UWB,BLE,GPS; A_RISK=contagious ;;
  uwb)     B_SOURCES=UWB;         A_RISK=contagious ;;
  ble)     B_SOURCES=BLE;         A_RISK=contagious ;;
  gps)     B_SOURCES=GPS;         A_RISK=contagious ;;
  control) B_SOURCES=UWB,BLE,GPS; A_RISK=none ;;
  *) die "unknown case $CASE (fused|uwb|ble|gps|control)" ;;
esac

# --- find phones and check each is ready (paired, Developer Mode on, tunnel up, unlocked) ---
if [[ -n "${PHONES:-}" ]]; then
  read -r -a WANT <<< "$PHONES"
  PROBE=$(python3 "$HERE/devices.py" --lock "${WANT[@]}") || die "cannot query devices (is Xcode set up?)"
else
  PROBE=$(python3 "$HERE/devices.py" --lock) || die "cannot query devices (is Xcode set up?)"
fi
P=(); BAD=()
while IFS=$'\t' read -r udid name model problem; do
  [[ -n "$udid" ]] || continue
  if [[ $problem == ok ]]; then P+=("$udid"); else BAD+=("  $name ($model, $udid): $problem"); fi
done <<< "$PROBE"
if [[ -n "${PHONES:-}" ]]; then
  (( ${#BAD[@]} == 0 )) || { printf '%s\n' "${BAD[@]}" >&2; die "phone(s) not ready"; }
  (( ${#P[@]} == ${#WANT[@]} )) || die "PHONES lists ${#WANT[@]} udid(s) but only ${#P[@]} were found by devicectl"
fi
P=("${P[@]:0:3}")
if (( ${#P[@]} < 2 )); then
  [[ ${#BAD[@]} -eq 0 ]] || { echo "[test] phones that are not ready:" >&2; printf '%s\n' "${BAD[@]}" >&2; }
  die "need at least two ready iPhones, found ${#P[@]}"
fi

# --- build + install ---
if [[ -z "${SKIP_BUILD:-}" ]]; then
  [[ -n "${FLUNI_TEAM:-}" ]] || die "set FLUNI_TEAM to your Apple development team ID (see tools/doctor.sh)"
  command -v xcodegen >/dev/null || die "xcodegen not installed: brew install xcodegen"
  FLUNI_TEAM=$FLUNI_TEAM xcodegen generate -q || die "xcodegen failed"
  if ! xcodebuild build -project FluniProx.xcodeproj -scheme FluniProx -destination generic/platform=iOS \
      -derivedDataPath build/dd -allowProvisioningUpdates -quiet >"$TMP/build.log" 2>&1; then
    grep -E "error:" "$TMP/build.log" | grep -v DVTDevice | head -20 >&2 || true
    die "build failed (tail of log above; FLUNI_TEAM=$FLUNI_TEAM)"
  fi
  APP=build/dd/Build/Products/Debug-iphoneos/FluniProx.app
  for d in "${P[@]}"; do
    xcrun devicectl device install app --device "$d" "$APP" >"$TMP/install.log" 2>&1 \
      || { tail -8 "$TMP/install.log" >&2; die "install failed on $d"; }
  done
fi

# --- launch ---
diagnose() {  # raw-log -> prints a one-line reason
  local f=$1
  if grep -qi "profile has not been explicitly trusted\|not been explicitly trusted" "$f"; then
    echo "developer profile not trusted: on the phone, Settings > General > VPN & Device Management > trust your developer app"
  elif grep -qi "locked" "$f"; then
    echo "phone is locked: unlock it and keep the screen on"
  elif grep -qi "developer mode" "$f"; then
    echo "Developer Mode is off: Settings > Privacy & Security > Developer Mode"
  elif grep -qi "not paired\|pairing" "$f"; then
    echo "phone is not paired: reconnect by cable and tap Trust"
  else
    echo "console exited early; last lines: $(grep -v '^$' "$f" | tail -3 | tr '\n' '|')"
  fi
}
launch() {  # phone label args...   (runs as a background job = its own process group)
  local p=$1 label=$2; shift 2
  xcrun devicectl device process launch --device "$p" --console --terminate-existing "$BUNDLE" -- "$@" 2>&1 \
    | tee "$TMP/$label.raw" | grep --line-buffered '\[fluni\]' | sed -u "s/^/[$label] /" || true
}

echo "[test] case=$CASE A=${P[0]} risk=$A_RISK  listeners=${P[*]:1} sources=$B_SOURCES  for ${SECS}s"
LABELS=(A B C)
launch "${P[0]}" A -risk "$A_RISK" -speed 60 & PIDS+=($!)
for i in $(seq 1 $((${#P[@]} - 1))); do
  launch "${P[$i]}" "${LABELS[$i]}" -risk none -speed 60 -sources "$B_SOURCES" & PIDS+=($!)
done

for ((t = 0; t < SECS; t++)); do
  sleep 1
  for i in "${!PIDS[@]}"; do
    if ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
      die "phone ${LABELS[$i]} (${P[$i]}) stopped after ${t}s: $(diagnose "$TMP/${LABELS[$i]}.raw")"
    fi
  done
done
echo "[test] done case=$CASE"

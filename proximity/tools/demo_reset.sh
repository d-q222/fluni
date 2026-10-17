#!/usr/bin/env bash
# Resets the demo phones to a fresh install: uninstalls FlUni (which deletes its data: status, onboarding
# flag, map address, persona, demo speed), then installs the latest build. WITH_HARNESS=1 also does
# the test harness (com.fluni.proxtest).
#
#   tools/demo_reset.sh
#
# Phones: PHONES="udidA udidB udidC", or every ready, unlocked iPhone is used (max 3).
# FLUNI_TEAM (Apple team ID) is needed to build; SKIP_BUILD=1 reuses the last build in build/dd.
# DRY_RUN=1 only prints what would run (it still queries devices, read-only).
# Exit status: 0 = every selected phone reset, 1 = a phone was skipped or failed, 2 = nothing to do.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE/.."

APP_ID=com.fluni.app
HARNESS_ID=com.fluni.proxtest
DRY=${DRY_RUN:-}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say()  { echo "[reset] $*"; }
die()  { echo "[reset] ERROR: $*" >&2; exit 1; }
# run: print the command in dry-run, otherwise execute it with output kept in $TMP/last.log.
run() {
  if [[ -n $DRY ]]; then echo "  (dry run) $*"; return 0; fi
  "$@" >"$TMP/last.log" 2>&1
}

# --- which phones ---
if [[ -n "${PHONES:-}" ]]; then
  read -r -a WANT <<< "$PHONES"
  PROBE=$(python3 "$HERE/devices.py" --lock "${WANT[@]}") || die "cannot query devices (is Xcode set up?)"
else
  WANT=()
  PROBE=$(python3 "$HERE/devices.py" --lock) || die "cannot query devices (is Xcode set up?)"
fi
READY=(); NAMES=(); SKIPPED=()
while IFS=$'\t' read -r udid name model problem; do
  [[ -n $udid ]] || continue
  if [[ $problem == ok ]]; then READY+=("$udid"); NAMES+=("$name")
  else SKIPPED+=("$name ($model): $problem"); fi
done <<< "$PROBE"
if (( ${#WANT[@]} > 0 && ${#READY[@]} + ${#SKIPPED[@]} != ${#WANT[@]} )); then
  die "PHONES lists ${#WANT[@]} udid(s) but devicectl found ${#READY[@]} + ${#SKIPPED[@]}"
fi
if (( ${#READY[@]} > 3 )); then READY=("${READY[@]:0:3}"); NAMES=("${NAMES[@]:0:3}"); fi
for s in "${SKIPPED[@]:+${SKIPPED[@]}}"; do say "SKIP  $s"; done
(( ${#READY[@]} > 0 )) || { echo "[reset] no phone is ready: nothing to do" >&2; exit 2; }
say "phones: ${NAMES[*]}${DRY:+  (DRY RUN: nothing will be changed)}"

# --- build ---
APP=build/dd/Build/Products/Debug-iphoneos/FlUni.app
PROX=build/dd/Build/Products/Debug-iphoneos/FluniProx.app
if [[ -n ${SKIP_BUILD:-} ]]; then
  say "SKIP_BUILD=1: reusing $APP"
  if [[ -z $DRY ]]; then
    [[ -d $APP ]] || die "no build at proximity/$APP; run without SKIP_BUILD"
    [[ -z ${WITH_HARNESS:-} || -d $PROX ]] || die "no harness build at proximity/$PROX; run without SKIP_BUILD"
  fi
else
  [[ -n ${FLUNI_TEAM:-} ]] || die "set FLUNI_TEAM to your Apple development team ID (tools/doctor.sh shows a hint), or SKIP_BUILD=1"
  command -v xcodegen >/dev/null || die "xcodegen not installed: brew install xcodegen"
  say "building FlUni${WITH_HARNESS:+ and FluniProx}"
  run env FLUNI_TEAM="$FLUNI_TEAM" xcodegen generate -q || die "xcodegen failed"
  SCHEMES=(FlUni); [[ -z ${WITH_HARNESS:-} ]] || SCHEMES+=(FluniProx)
  for sch in "${SCHEMES[@]}"; do
    if ! run xcodebuild build -project FluniProx.xcodeproj -scheme "$sch" -destination generic/platform=iOS \
        -derivedDataPath build/dd -allowProvisioningUpdates -quiet; then
      grep -E "error:" "$TMP/last.log" | grep -v DVTDevice | head -20 >&2 || true
      die "build of $sch failed (FLUNI_TEAM=$FLUNI_TEAM)"
    fi
  done
fi

# --- per phone: uninstall (wipes data), then install ---
BUNDLES=("$APP_ID:$APP"); [[ -z ${WITH_HARNESS:-} ]] || BUNDLES+=("$HARNESS_ID:$PROX")
FAILED=0
for i in "${!READY[@]}"; do
  udid=${READY[$i]}; name=${NAMES[$i]}; ok=1
  for b in "${BUNDLES[@]}"; do
    id=${b%%:*}; path=${b#*:}
    # Uninstall fails harmlessly when the app isn't there; say so instead of stopping.
    run xcrun devicectl device uninstall app --device "$udid" "$id" \
      || say "$name: $id was not installed (or uninstall failed): continuing"
    if run xcrun devicectl device install app --device "$udid" "$path"; then
      say "$name: $id ${DRY:+would be }reinstalled"
    else
      ok=0
      if [[ -f $TMP/last.log ]] && grep -qi "locked" "$TMP/last.log"; then why="phone locked: unlock it"
      elif [[ -f $TMP/last.log ]] && grep -qi "not been explicitly trusted" "$TMP/last.log"; then why="developer cert not trusted"
      else why=$(grep -v '^$' "$TMP/last.log" 2>/dev/null | tail -2 | tr '\n' '|'); fi
      say "$name: FAILED to install $id: $why"
    fi
  done
  (( ok )) || FAILED=$((FAILED + 1))
done

echo
if [[ -n $DRY ]]; then say "dry run finished; no phone was touched"; exit 0; fi
say "${#READY[@]} phone(s) attempted, $FAILED failed, ${#SKIPPED[@]} skipped."
say "Each phone is now a fresh install: onboarding, permissions, map address, demo speed and status all start over (see DEMO.md, Before the demo)."
(( FAILED == 0 && ${#SKIPPED[@]} == 0 )) || exit 1

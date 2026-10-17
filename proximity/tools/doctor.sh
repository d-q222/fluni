#!/usr/bin/env bash
# Read-only readiness report for the Mac-side test tooling. Changes nothing.   tools/doctor.sh
# Exit status: 0 = ready for pair_test.sh, 1 = something blocks it (see FAIL lines).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BUNDLE=com.fluni.proxtest
FAILS=0
ok()   { echo "  ok    $*"; }
warn() { echo "  WARN  $*"; }
bad()  { echo "  FAIL  $*"; FAILS=$((FAILS + 1)); }

echo "Tools"
if command -v xcodegen >/dev/null; then ok "xcodegen $(xcodegen --version 2>&1 | head -1)"; else bad "xcodegen missing: brew install xcodegen"; fi
if command -v xcodebuild >/dev/null; then ok "$(xcodebuild -version 2>/dev/null | head -1)"; else bad "Xcode not found"; fi
if command -v shellcheck >/dev/null; then ok "shellcheck present"; else warn "shellcheck not installed (optional)"; fi

echo "Signing team"
if [[ -n "${FLUNI_TEAM:-}" ]]; then
  ok "FLUNI_TEAM is set (${#FLUNI_TEAM} chars)"
else
  TEAMS=$(defaults export com.apple.dt.Xcode - 2>/dev/null | python3 -c '
import plistlib,sys
try: d=plistlib.loads(sys.stdin.buffer.read()).get("IDEProvisioningTeamByIdentifier",{})
except Exception: d={}
for v in d.values():
    for t in v: print(t.get("teamID","?"), "-", t.get("teamType","?"))' 2>/dev/null || true)
  if [[ -n $TEAMS ]]; then
    while read -r line; do warn "FLUNI_TEAM not set; Xcode knows team: $line  ->  export FLUNI_TEAM=<id>"; done <<< "$TEAMS"
  else
    warn "FLUNI_TEAM not set and no team found in Xcode prefs (Xcode > Settings > Accounts)"
  fi
fi

echo "iPhones (need 2 'ok' for pair_test.sh)"
READY=0
PROBE=$(python3 "$HERE/devices.py" --lock --installed "$BUNDLE" 2>&1) || { bad "devicectl query failed: $PROBE"; PROBE=""; }
while IFS=$'\t' read -r udid name model problem inst; do
  [[ -n "$udid" ]] || continue
  if [[ $problem == ok ]]; then
    READY=$((READY + 1)); ok "$name ($model): paired, Developer Mode on, tunnel up, unlocked; $BUNDLE $inst"
  else
    warn "$name ($model): $problem"
  fi
done <<< "$PROBE"
if (( READY >= 2 )); then ok "$READY phones ready"; else bad "only $READY phone(s) ready"; fi

echo "Simulators (standard iPhone, never iPhone Duo)"
SIMS=$(python3 -c '
import json,subprocess
sh=lambda *a: json.loads(subprocess.run(["xcrun","simctl","list","-j",*a],capture_output=True,text=True).stdout)
std={t["identifier"] for t in sh("devicetypes")["devicetypes"] if "iPhone" in t["name"] and "Duo" not in t["name"]}
for r in sh("runtimes")["runtimes"]:
    if r.get("isAvailable") and r.get("platform")=="iOS":
        n=[d["name"] for d in r.get("supportedDeviceTypes",[]) if d["identifier"] in std]
        print(r["name"], "|", ",".join(n) if n else "")' 2>/dev/null || true)
STD=0
while IFS='|' read -r rt types; do
  [[ -n $rt ]] || continue
  if [[ -n "${types// /}" ]]; then STD=1; ok "$rt supports: $types"; else warn "$rt only supports iPhone Duo (not usable)"; fi
done <<< "$SIMS"
(( STD )) || warn "no standard iPhone simulator runtime: xcodebuild -downloadPlatform iOS   (sim_test.sh will refuse to run)"

echo "GitHub"
if nc -z -G 5 github.com 22 >/dev/null 2>&1; then
  ok "github.com:22 (SSH) reachable"
else
  warn "github.com:22 blocked. Use HTTPS: gh auth login (choose HTTPS), gh auth setup-git, then git remote set-url origin https://github.com/<owner>/<repo>.git"
fi

echo
if (( FAILS == 0 )); then echo "Ready."; else echo "$FAILS blocking problem(s)."; fi
exit $(( FAILS > 0 ))

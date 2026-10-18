#!/usr/bin/env bash
# One command for the live demo: serve the repo root (if nothing is serving yet), open the heat map in
# your default browser, print the shortcuts. Safe to run twice; it never kills anything.
#
#   heatmap/tools/demo.sh [--run <run id>] [--port <n>] [--no-open]
#
# Run ids are folders in sim/runs/. Without --run the page opens its default run.
set -euo pipefail

port=8766 run="" open_it=1
while [ $# -gt 0 ]; do
  case "$1" in
    --run)     run="${2:?--run needs a run id}"; shift 2 ;;
    --port)    port="${2:?--port needs a number}"; shift 2 ;;
    --no-open) open_it=0; shift ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done
case "$port" in ''|*[!0-9]*) echo "--port must be a number" >&2; exit 2 ;; esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ -n "$run" ] && [ ! -d "$root/sim/runs/$run" ]; then
  echo "No such run: sim/runs/$run" >&2
  echo "Available:" >&2; ls "$root/sim/runs" | sed 's/^/  /' >&2
  exit 1
fi

url="http://localhost:$port/heatmap/index.html${run:+?run=$run}"
page="http://localhost:$port/heatmap/index.html"
up() { [ "$(curl -s -o /dev/null -m 2 -w '%{http_code}' "$page" 2>/dev/null)" = 200 ]; }

if up; then
  echo "Already serving on port $port; reusing it."
elif (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
  echo "Port $port is taken by something that is not serving the heat map. Pick another with --port <n>." >&2
  exit 1
else
  log="${TMPDIR:-/tmp}/fluni-demo-$port.log"
  # serve.py changes to the repo root itself; nohup so closing this terminal doesn't stop it.
  nohup python3 "$root/heatmap/tools/serve.py" "$port" >"$log" 2>&1 &
  pid=$!
  for _ in $(seq 1 50); do up && break; sleep 0.1; done
  up || { echo "Server did not come up; see $log" >&2; exit 1; }
  echo "Started server on port $port (pid $pid, log $log). Stop it later with: kill $pid"
fi

[ "$open_it" = 1 ] && open "$url"
cat <<EOS

FlUni heat map: $url

  Space  play / pause          J  Jump to...  (peak, hottest building, first report, first close-contact alert)
  <- ->  back / forward 10 min  [ ]  slower / faster       ?  help       Esc  close the phone
  Reload (Cmd-R) resets to the opening moment. Offline? It still works; the map just loses street names.
  Full run-of-show: heatmap/DEMO.md
EOS

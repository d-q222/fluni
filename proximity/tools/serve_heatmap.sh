#!/usr/bin/env bash
# Serves the fluni REPO ROOT (the heat map page fetches ../sim and ../model) and prints the URLs
# to type into the app's Heat map tab. Ctrl-C to stop.   tools/serve_heatmap.sh [port]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PORT=${1:-8000}
HOST=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT is already in use (is a server already running?). Pass another port: $0 8001" >&2
  exit 1
fi
echo "Serving $ROOT"
echo "Phone URL:  http://$HOST.local:$PORT/heatmap/?embed=app"
[[ -z $IP ]] || echo "By IP:      http://$IP:$PORT/heatmap/?embed=app"
echo "(phone and Mac must be on the same Wi-Fi; Ctrl-C to stop)"
cd "$ROOT"
exec python3 -m http.server "$PORT"

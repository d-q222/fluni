"""Serve the repo root with caching off, so a reload always runs the latest heat map code.

    python3 heatmap/tools/serve.py [port]    # default 8000, then open http://localhost:8000/heatmap/
"""
import http.server, os, sys

class NoCache(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
http.server.ThreadingHTTPServer(('', port), NoCache).serve_forever()

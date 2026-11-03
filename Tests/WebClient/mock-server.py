#!/usr/bin/env python3
"""Serve the real web client with isolated WebRTC and API fixtures."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WEB = ROOT / "Sources/RemoteServer/Web"
TESTS = ROOT / "Tests/WebClient"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        route = self.path.split("?", 1)[0]
        routes = {
            "/": (WEB / "index.html", "text/html"),
            "/app.js": (WEB / "app.js", "text/javascript"),
            "/i18n.js": (WEB / "i18n.js", "text/javascript"),
            "/client-core.js": (WEB / "client-core.js", "text/javascript"),
            "/style.css": (WEB / "style.css", "text/css"),
            "/locales/zh-Hans.json": (WEB / "locales/zh-Hans.json", "application/json"),
            "/fixture.js": (TESTS / "mock-session.js", "text/javascript"),
            "/session-tests.js": (TESTS / "private-session.browser.js", "text/javascript"),
            "/touch-tests.js": (TESTS / "touch-gestures.browser.js", "text/javascript"),
            "/language-tests.js": (TESTS / "localization.browser.js", "text/javascript"),
        }
        if route not in routes:
            self.send_error(404)
            return
        path, mime = routes[route]
        data = path.read_bytes()
        if route == "/":
            data = data.replace(b'<script src="/i18n.js"', b'<script src="/fixture.js"></script><script src="/i18n.js"')
        self.send_response(200)
        self.send_header("Content-Type", mime + "; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8769)
    args = parser.parse_args()
    print(f"Vela mock client: http://127.0.0.1:{args.port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()

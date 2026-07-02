"""Web workload against a local page. Skipped when Playwright/Chromium
is not installed (CI/dev boxes); runs on the Pi image where both are pinned."""
from __future__ import annotations

import http.server
import socketserver
import threading

import pytest

playwright = pytest.importorskip("playwright.sync_api")

from probe.workloads import web  # noqa: E402

PAGE = b"<html><head><title>ref</title></head><body><h1>reference page</h1></body></html>"


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *_):
        pass


def test_web_navigation_timing():
    try:
        with playwright.sync_playwright() as p:
            p.chromium.launch(headless=True).close()
    except Exception:
        pytest.skip("Chromium browser not installed (run: playwright install chromium)")

    with socketserver.TCPServer(("127.0.0.1", 0), _Handler) as srv:
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        port = srv.server_address[1]
        result = web.run(f"http://127.0.0.1:{port}/")
        srv.shutdown()

    assert set(result) == {"dns_ms", "connect_ms", "ttfb_ms", "load_ms"}
    assert result["load_ms"] > 0
    assert result["ttfb_ms"] >= 0

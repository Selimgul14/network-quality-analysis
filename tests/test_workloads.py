"""Unit tests for the video, path, email and context modules.

Web (Playwright) is exercised in test_web.py and skipped where Chromium
is not installed.
"""
from __future__ import annotations

import http.server
import shutil
import socketserver
import subprocess
import threading
from pathlib import Path

import pytest

from probe import context
from probe.workloads import email, path, video

# --- helpers ---------------------------------------------------------------


class _FileHandler(http.server.BaseHTTPRequestHandler):
    payload: bytes = b""

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(len(self.payload)))
        self.end_headers()
        self.wfile.write(self.payload)

    def log_message(self, *_):
        pass


def _serve(payload: bytes):
    """Serve one payload on an ephemeral port; return (server, port)."""
    handler = type("H", (_FileHandler,), {"payload": payload})
    srv = socketserver.TCPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_address[1]


# --- video -------------------------------------------------------------------

ffmpeg_missing = shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None


@pytest.mark.skipif(ffmpeg_missing, reason="ffmpeg/ffprobe not installed")
def test_video_startup_and_rebuffer(tmp_path: Path):
    # 3 s synthetic clip, same recipe as the reference image.
    clip = tmp_path / "clip.mp4"
    subprocess.run(
        ["ffmpeg", "-v", "error", "-f", "lavfi", "-i",
         "testsrc=duration=3:size=320x240:rate=15",
         "-c:v", "libx264", "-preset", "ultrafast", "-movflags", "+faststart",
         str(clip)],
        check=True,
    )
    srv, port = _serve(clip.read_bytes())
    result = video.run(f"http://127.0.0.1:{port}/clip.mp4")
    srv.shutdown()

    assert result["startup_ms"] > 0
    assert result["rebuffer_count"] >= 0
    assert result["rebuffer_ms"] >= 0


# --- path --------------------------------------------------------------------


@pytest.mark.skipif(shutil.which("mtr") is None, reason="mtr not installed")
def test_path_localhost():
    result = path.run("127.0.0.1")
    assert result["hops"] >= 1
    assert result["dest_loss_pct"] <= 100
    assert path.last_raw is not None  # full JSON kept for Blob upload


# --- email -------------------------------------------------------------------


def test_email_requires_credentials(monkeypatch):
    monkeypatch.setattr(email.settings, "real_imap_user", "")
    with pytest.raises(RuntimeError, match="not set"):
        email.run("imap.example.com")


def test_email_timings_with_fake_imap(monkeypatch):
    class FakeIMAP:
        def __init__(self, *a, **k): ...
        def login(self, *a): return "OK", []
        def select(self, *a, **k): return "OK", []
        def search(self, *a): return "OK", [b"1 2 3"]
        def fetch(self, *a): return "OK", [b"..."]
        def logout(self): return "BYE", []

    monkeypatch.setattr(email.settings, "real_imap_user", "u")
    monkeypatch.setattr(email.settings, "real_imap_pass", "p")
    monkeypatch.setattr(email.imaplib, "IMAP4_SSL", FakeIMAP)

    result = email.run("imap.example.com")
    assert set(result) == {"connect_ms", "login_ms", "fetch_ms"}
    assert all(v >= 0 for v in result.values())


# --- context -----------------------------------------------------------------


def test_context_snapshot_never_raises():
    snap = context.snapshot()
    assert set(snap) == {"wifi_channel", "rssi_dbm", "cpu_temp_c"}

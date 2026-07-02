"""Video streaming workload: startup delay and rebuffering.

ffprobe reads the media's duration and bitrate, then the stream is
downloaded while simulating a player: playback starts once STARTUP_BUFFER_S
of media is buffered, and any time the buffer runs dry counts as a rebuffer
event (cf. Dobrian et al.). For non-direct URLs (e.g. a YouTube page on the
"real" endpoint) yt-dlp resolves the actual media URL first.
"""
from __future__ import annotations

import json
import subprocess
import time

import httpx

STARTUP_BUFFER_S = 2.0  # media seconds buffered before "playback" starts
MAX_WATCH_S = 30.0      # cap how much of the stream one run consumes

DIRECT_SUFFIXES = (".mp4", ".webm", ".mkv", ".m4v")


def _resolve(target: str) -> str:
    """Return a direct media URL, using yt-dlp for page URLs."""
    if target.lower().split("?")[0].endswith(DIRECT_SUFFIXES):
        return target
    import yt_dlp  # only needed for the "real" endpoint

    opts = {"quiet": True, "no_warnings": True, "format": "best[protocol^=http]"}
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(target, download=False)
    return info["url"]


def _ffprobe(url: str) -> dict:
    out = subprocess.run(
        ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", url],
        capture_output=True, text=True, timeout=30, check=True,
    ).stdout
    return json.loads(out)["format"]


def run(target: str) -> dict[str, float]:
    url = _resolve(target)
    fmt = _ffprobe(url)
    bitrate_bps = float(fmt.get("bit_rate", 0)) or 2_000_000  # fallback 2 Mbps
    duration_s = min(float(fmt.get("duration", MAX_WATCH_S)), MAX_WATCH_S)

    # Simulated player: buffer fills at download rate, drains at 1x playback.
    start = time.perf_counter()
    startup_ms: float | None = None
    play_start = 0.0
    stalled_since: float | None = None
    rebuffer_count, rebuffer_ms = 0, 0.0
    bytes_dl = 0

    with httpx.stream("GET", url, timeout=30.0, follow_redirects=True) as r:
        r.raise_for_status()
        for chunk in r.iter_bytes():
            bytes_dl += len(chunk)
            now = time.perf_counter()
            buffered_s = (bytes_dl * 8) / bitrate_bps

            if startup_ms is None:
                if buffered_s >= STARTUP_BUFFER_S:
                    startup_ms = (now - start) * 1000
                    play_start = now
                continue

            # Playback position advances with wall clock, minus stall time.
            played_s = (now - play_start) - (rebuffer_ms / 1000)
            if buffered_s <= played_s:
                if stalled_since is None:  # buffer just ran dry
                    stalled_since = now
                    rebuffer_count += 1
            elif stalled_since is not None:  # recovered
                rebuffer_ms += (now - stalled_since) * 1000
                stalled_since = None

            if played_s >= duration_s or buffered_s >= duration_s:
                break  # watched enough

    if stalled_since is not None:  # stream ended mid-stall
        rebuffer_ms += (time.perf_counter() - stalled_since) * 1000

    return {
        "startup_ms": round(startup_ms or (time.perf_counter() - start) * 1000, 2),
        "rebuffer_count": float(rebuffer_count),
        "rebuffer_ms": round(rebuffer_ms, 2),
    }

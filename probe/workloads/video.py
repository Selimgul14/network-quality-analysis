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

# Rebuffering only happens when delivery falls below the media bitrate, so
# on a healthy link with a modest clip it is always zero: a true statement
# about the network, but one that carries no information until something
# breaks. The headroom below is the continuous version of the same
# question, "how much harder could this link be pushed before playback
# stalls", and it stays informative every run.
#
# Tiers are the published minimum sustained rates for each resolution
# (Netflix and YouTube guidance, rounded up to the nearer round number).
QUALITY_TIERS = ((25.0, "4K"), (8.0, "1080p"), (5.0, "720p"), (3.0, "480p"))

DIRECT_SUFFIXES = (".mp4", ".webm", ".mkv", ".m4v")

# Some CDNs 403 non-browser clients (ffmpeg's default UA). Present a normal
# browser UA so the video leg is not blocked by hotlink protection.
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"


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
        ["ffprobe", "-v", "quiet", "-user_agent", UA,
         "-print_format", "json", "-show_format", url],
        capture_output=True, text=True, timeout=30, check=True,
    ).stdout
    return json.loads(out)["format"]


def _tier(mbps: float) -> str:
    """Highest standard streaming quality this delivery rate sustains."""
    for need, name in QUALITY_TIERS:
        if mbps >= need:
            return name
    return "below-480p"


def run(target: str) -> dict[str, float | str]:
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

    with httpx.stream("GET", url, timeout=30.0, follow_redirects=True,
                      headers={"User-Agent": UA}) as r:
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

    # Delivery rate actually achieved while fetching the media. Small clips
    # spend part of the transfer in TCP slow start, so this is a lower
    # bound on what the link can sustain.
    elapsed = time.perf_counter() - start
    stream_mbps = (bytes_dl * 8) / elapsed / 1_000_000 if elapsed > 0 else 0.0
    bitrate_mbps = bitrate_bps / 1_000_000

    return {
        "startup_ms": round(startup_ms or elapsed * 1000, 2),
        "rebuffer_count": float(rebuffer_count),
        "rebuffer_ms": round(rebuffer_ms, 2),
        "stream_mbps": round(stream_mbps, 2),
        "bitrate_mbps": round(bitrate_mbps, 2),
        # How many times faster than real time the media arrived: 1.0 means
        # playback is on the edge of stalling.
        "headroom_x": round(stream_mbps / bitrate_mbps, 2) if bitrate_mbps else 0.0,
        "quality_tier": _tier(stream_mbps),
    }

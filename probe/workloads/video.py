"""Video streaming workload: startup delay and rebuffering.

Fetches the stream with yt-dlp and inspects it with ffprobe. Startup delay
is time to first playable data; rebuffering is estimated from stalls
against the media's declared bitrate (cf. Dobrian et al.).
"""
from __future__ import annotations


def run(target: str) -> dict[str, float]:
    # TODO: use yt-dlp to fetch, ffprobe to read duration/bitrate, and
    # measure startup_ms, rebuffer_count, rebuffer_ms. Pin both versions.
    raise NotImplementedError("video workload: implement with yt-dlp + ffprobe")

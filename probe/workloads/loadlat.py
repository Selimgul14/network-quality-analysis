"""Latency under load (bufferbloat): what the link does when it is busy.

Idle latency flatters a network. What users actually feel is latency while
something else is downloading: the video call stutters when a file is
copying. This workload measures both and reports the difference.

Method: sample TCP handshake RTT to a reference anchor, saturate the link
with a download, sample RTT again during the transfer, and report the
inflation. RTT is measured with a TCP connect rather than ping so it works
on networks that block ICMP.

A large inflation localises to a buffer: paired with `path`'s
`first_hop_rtt_ms`, a jump concentrated at hop 1 means the WiFi link or
router is the bloated buffer, while a jump further out means the ISP
access link (cf. Sundaresan et al. 2011).
"""
from __future__ import annotations

import socket
import statistics
import threading
import time

import httpx

RTT_HOST = "1.1.1.1"   # anycast, always listening on 443, not the loaded host
RTT_PORT = 443
IDLE_SAMPLES = 5
LOAD_SECONDS = 8.0     # how long to hold the link saturated
SAMPLE_GAP_S = 0.4


def _tcp_rtt(timeout: float = 3.0) -> float | None:
    """One TCP handshake RTT in ms, or None if it failed."""
    start = time.perf_counter()
    try:
        with socket.create_connection((RTT_HOST, RTT_PORT), timeout=timeout):
            return (time.perf_counter() - start) * 1000
    except OSError:
        return None


def _sample(n: int, gap: float) -> list[float]:
    out = []
    for _ in range(n):
        rtt = _tcp_rtt()
        if rtt is not None:
            out.append(rtt)
        time.sleep(gap)
    return out


def run(target: str) -> dict[str, float]:
    """`target` is a URL large enough to saturate the link for LOAD_SECONDS."""
    idle = _sample(IDLE_SAMPLES, 0.2)
    if not idle:
        raise RuntimeError("loadlat: could not measure idle RTT")

    stop = threading.Event()
    transferred = {"bytes": 0, "seconds": 0.0}

    def _saturate() -> None:
        start = time.perf_counter()
        total = 0
        try:
            with httpx.stream("GET", target, timeout=30.0, follow_redirects=True) as r:
                r.raise_for_status()
                for chunk in r.iter_bytes():
                    total += len(chunk)
                    if stop.is_set():
                        break
        except Exception:
            pass  # a partial transfer still loaded the link
        transferred["bytes"] = total
        transferred["seconds"] = time.perf_counter() - start

    worker = threading.Thread(target=_saturate, daemon=True)
    worker.start()
    time.sleep(1.0)  # let TCP ramp up before sampling

    loaded: list[float] = []
    deadline = time.perf_counter() + LOAD_SECONDS
    while time.perf_counter() < deadline and worker.is_alive():
        rtt = _tcp_rtt()
        if rtt is not None:
            loaded.append(rtt)
        time.sleep(SAMPLE_GAP_S)

    stop.set()
    worker.join(timeout=30)

    if not loaded:
        raise RuntimeError("loadlat: could not measure RTT under load")

    idle_ms = statistics.median(idle)
    loaded_ms = statistics.median(loaded)
    secs = transferred["seconds"]
    mbps = (transferred["bytes"] * 8) / secs / 1_000_000 if secs > 0 else 0.0

    return {
        "idle_rtt_ms": round(idle_ms, 2),
        "loaded_rtt_ms": round(loaded_ms, 2),
        # The headline: how much latency the load added.
        "bloat_ms": round(max(0.0, loaded_ms - idle_ms), 2),
        "loaded_rtt_max_ms": round(max(loaded), 2),
        "load_mbps": round(mbps, 2),
    }

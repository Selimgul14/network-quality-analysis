"""Continuous baseline probes: DNS resolve time, RTT, jitter, loss.

Cheap signal that runs on a tight schedule between heavy workloads.
"""
from __future__ import annotations

import socket
import subprocess
import time


def _dns_ms(host: str) -> float:
    start = time.perf_counter()
    socket.getaddrinfo(host, None)
    return round((time.perf_counter() - start) * 1000, 2)


def _ping(host: str, count: int = 5) -> dict[str, float]:
    # Parse `ping` for avg RTT and loss. Jitter approximated as mdev.
    out = subprocess.run(
        ["ping", "-c", str(count), "-w", "5", host],
        capture_output=True, text=True,
    ).stdout
    rtt_ms = jitter_ms = loss_pct = 0.0
    for line in out.splitlines():
        if "packet loss" in line:
            loss_pct = float(line.split("%")[0].split()[-1])
        if line.startswith(("rtt", "round-trip")):
            # rtt min/avg/max/mdev = a/b/c/d ms
            stats = line.split("=")[1].split()[0].split("/")
            rtt_ms, jitter_ms = float(stats[1]), float(stats[3])
    return {"rtt_ms": rtt_ms, "jitter_ms": jitter_ms, "loss_pct": loss_pct}


def run(target: str) -> dict[str, float]:
    """`target` is a public anchor host, e.g. 1.1.1.1."""
    return {"dns_ms": _dns_ms(target), **_ping(target)}

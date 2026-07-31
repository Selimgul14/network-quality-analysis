"""Continuous baseline probes: DNS resolve time, RTT, jitter, loss.

Cheap signal that runs on a tight schedule between heavy workloads.
Probes several destination classes (gateway, cloud reference, CDN, public
anchors) so loss can be compared across them: loss at the gateway means
the WiFi link, loss to a single distant target means that path.
"""
from __future__ import annotations

import socket
import statistics
import subprocess
import time


def _dns_ms(host: str) -> float:
    start = time.perf_counter()
    socket.getaddrinfo(host, None)
    return round((time.perf_counter() - start) * 1000, 2)


def _ping(host: str, count: int = 5) -> dict[str, float]:
    # Parse `ping` for avg RTT and loss. Jitter approximated as mdev.
    # -w must exceed count seconds: packets go out at 1/s, so the last
    # reply arrives at ~(count-1)s + RTT. A tight deadline clips that reply
    # and reports it as loss, which showed up as a constant, suspiciously
    # exact 20% (1 of 5). -W bounds each individual reply instead.
    out = subprocess.run(
        ["ping", "-c", str(count), "-W", "2", "-w", str(count * 2), host],
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


def _tcp_ping(host: str, port: int = 443, count: int = 5, gap: float = 0.3) -> dict[str, float]:
    """TCP-handshake RTT for hosts that do not answer ICMP echo (e.g.
    Azure App Service). Same output shape as `_ping`, plus a marker."""
    # Resolve once so DNS time is not folded into the RTT samples.
    ip = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)[0][4][0]
    rtts: list[float] = []
    for _ in range(count):
        start = time.perf_counter()
        try:
            with socket.create_connection((ip, port), timeout=2):
                rtts.append((time.perf_counter() - start) * 1000)
        except OSError:
            pass  # a failed handshake counts as a lost packet
        time.sleep(gap)
    return {
        "rtt_ms": round(sum(rtts) / len(rtts), 2) if rtts else 0.0,
        "jitter_ms": round(statistics.pstdev(rtts), 2) if len(rtts) > 1 else 0.0,
        "loss_pct": round((count - len(rtts)) / count * 100, 1),
        "tcp_mode": 1,
    }


# Default gateway, cached: it only changes when the network does.
_GW_TTL_S = 300.0
_gw_cache: tuple[float, str | None] = (0.0, None)


def gateway_ip() -> str | None:
    """IP of the default gateway (the router), or None if there is none."""
    global _gw_cache
    now = time.monotonic()
    if _gw_cache[1] is not None and now - _gw_cache[0] < _GW_TTL_S:
        return _gw_cache[1]
    gw = None
    out = subprocess.run(
        ["ip", "route", "show", "default"], capture_output=True, text=True
    ).stdout
    for line in out.splitlines():
        toks = line.split()
        if "via" in toks:  # "default via 192.168.1.1 dev wlan0 ..."
            gw = toks[toks.index("via") + 1]
            break
    _gw_cache = (now, gw)
    return gw


def run(target: str, method: str = "icmp") -> dict[str, float]:
    """`target` is a host to probe, e.g. 1.1.1.1. `method` is "icmp" or
    "tcp" (for hosts that drop ICMP echo)."""
    dns = _dns_ms(target)
    probe = _tcp_ping(target) if method == "tcp" else _ping(target)
    return {"dns_ms": dns, **probe}

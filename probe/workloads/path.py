"""Hop-by-hop path probing via mtr (per-hop latency decomposition).

Runs once per heavy cycle. Summary numbers plus one metric per hop go into
the time series; the full per-hop JSON is kept in `last_raw` for the caller
to ship to Blob Storage (Measurement.raw_ref).

Two things make the per-hop data useful rather than decorative:

* Hop 1 is the router, reached over the WiFi link, so `first_hop_rtt_ms`
  measures WiFi-link latency without needing a local reference server.
* The RTT increase from one hop to the next attributes latency to a
  specific segment, so `bottleneck_hop` says where the path degrades.

TCP mode (the default) sends TCP SYN instead of ICMP echo, which gets
through networks that block ping (eduroam and many public venues). The
intermediate hops still answer with ICMP time-exceeded, so a network that
blocks that too will only resolve the final hop.
"""
from __future__ import annotations

import json
import subprocess

from ..config import settings

# Full JSON of the most recent run, for the raw payload path.
last_raw: bytes | None = None

MAX_HOPS = 20  # cap per-hop metrics so one record cannot balloon


def _cmd(target: str) -> list[str]:
    cmd = ["mtr", "--report", "--json", "-c", "3"]
    if settings.mtr_tcp:
        # TCP SYN to a port that is virtually never filtered.
        cmd += ["--tcp", "-P", str(settings.mtr_port)]
    cmd.append(target)
    return cmd


def _hop_metrics(hubs: list[dict]) -> dict[str, float]:
    """Per-hop RTT/loss, plus which segment really adds the most latency.

    Raw per-hop RTT is noisy in a way that misleads: routers deprioritise
    the ICMP time-exceeded replies that traceroute depends on, so a hop can
    report a large RTT while forwarding transit traffic perfectly. The
    giveaway is that the spike does not persist at later hops.

    Delay that is genuinely on the path must be paid by every hop beyond
    it, so we smooth with a suffix minimum (each hop's RTT is capped by the
    smallest RTT seen at or after it) before looking for the largest jump.
    That discards transient spikes and keeps real, persistent increases.
    """
    out: dict[str, float] = {}
    responsive: list[tuple[int, float]] = []

    for hub in hubs:
        idx = int(hub.get("count", 0) or 0)
        rtt = float(hub.get("Avg", 0.0) or 0.0)
        loss = float(hub.get("Loss%", 0.0) or 0.0)

        if 0 < idx <= MAX_HOPS:
            out[f"hop_{idx:02d}_rtt_ms"] = round(rtt, 2)
            if loss:
                out[f"hop_{idx:02d}_loss_pct"] = round(loss, 2)

        if rtt > 0:  # unresponsive hops report 0; they tell us nothing
            responsive.append((idx, rtt))

    if not responsive:
        return out

    # Suffix minimum: the persistent cost of reaching each hop.
    persistent = [0.0] * len(responsive)
    running = float("inf")
    for i in range(len(responsive) - 1, -1, -1):
        running = min(running, responsive[i][1])
        persistent[i] = running

    worst_delta, worst_idx = 0.0, 0
    prev = 0.0
    for (idx, _), value in zip(responsive, persistent):
        delta = value - prev
        if delta > worst_delta:
            worst_delta, worst_idx = delta, idx
        prev = value

    if worst_idx:
        out["bottleneck_hop"] = float(worst_idx)
        out["bottleneck_delta_ms"] = round(worst_delta, 2)
    return out


def run(target: str) -> dict[str, float]:
    global last_raw
    out = subprocess.run(
        _cmd(target), capture_output=True, text=True, timeout=60, check=True,
    ).stdout
    last_raw = out.encode()

    hubs = json.loads(out)["report"]["hubs"]
    if not hubs:
        raise RuntimeError("path workload: mtr returned no hops")

    dest = hubs[-1]  # final hop = destination
    metrics: dict[str, float] = {
        "hops": float(len(hubs)),
        "dest_rtt_ms": float(dest.get("Avg", 0.0) or 0.0),
        "dest_loss_pct": float(dest.get("Loss%", 0.0) or 0.0),
        "worst_rtt_ms": max(float(h.get("Avg", 0.0) or 0.0) for h in hubs),
    }

    # Hop 1 is the local router: this is the WiFi link's own latency.
    first = next((h for h in hubs if int(h.get("count", 0) or 0) == 1), None)
    if first and float(first.get("Avg", 0.0) or 0.0) > 0:
        metrics["first_hop_rtt_ms"] = round(float(first["Avg"]), 2)

    metrics.update(_hop_metrics(hubs))
    return metrics

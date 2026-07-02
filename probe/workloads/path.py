"""Hop-by-hop path probing via mtr (Paris-traceroute style).

Runs once per heavy cycle. Summary numbers go into the time series; the
full per-hop JSON is kept in `last_raw` for the caller to ship to Blob
Storage (Measurement.raw_ref).
"""
from __future__ import annotations

import json
import subprocess

# Full JSON of the most recent run, for the raw payload path.
last_raw: bytes | None = None


def run(target: str) -> dict[str, float]:
    global last_raw
    out = subprocess.run(
        ["mtr", "--report", "--json", "-c", "3", target],
        capture_output=True, text=True, timeout=60, check=True,
    ).stdout
    last_raw = out.encode()

    hubs = json.loads(out)["report"]["hubs"]
    if not hubs:
        raise RuntimeError("path workload: mtr returned no hops")
    dest = hubs[-1]  # final hop = destination
    return {
        "hops": float(len(hubs)),
        "dest_rtt_ms": float(dest.get("Avg", 0.0)),
        "dest_loss_pct": float(dest.get("Loss%", 0.0)),
        "worst_rtt_ms": max(float(h.get("Avg", 0.0)) for h in hubs),
    }

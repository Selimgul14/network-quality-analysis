"""File download workload: average throughput against a fixed-size file.

Worked example. Use it as the template for the other workload modules:
take a target, measure, return a flat dict of numbers, raise on failure.
"""
from __future__ import annotations

import time

import httpx


def run(target: str) -> dict[str, float]:
    """Download `target` and return throughput in Mbps plus byte count."""
    start = time.perf_counter()
    total = 0
    with httpx.stream("GET", target, timeout=30.0, follow_redirects=True) as r:
        r.raise_for_status()
        for chunk in r.iter_bytes():
            total += len(chunk)
    elapsed = time.perf_counter() - start
    mbps = (total * 8) / elapsed / 1_000_000 if elapsed > 0 else 0.0
    return {"throughput_mbps": round(mbps, 2), "bytes": total}

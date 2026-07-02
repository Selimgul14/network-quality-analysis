"""Hop-by-hop path probing via mtr (Paris-traceroute style).

Runs once per heavy workload. The full JSON goes to Blob Storage; only the
hop count and the Blob key are kept in the time series.
"""
from __future__ import annotations


def run(target: str) -> dict[str, float]:
    # TODO: subprocess `mtr --report --json target`, return {"hops": n};
    # caller stores the full JSON via the uploader's raw payload path.
    raise NotImplementedError("path workload: implement with mtr")

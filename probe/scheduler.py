"""Builds each measurement record and runs the cadences.

Baseline probes run every PROBE_BASELINE_INTERVAL_S; heavy workloads run
every PROBE_HEAVY_INTERVAL_S against all three endpoints, with one path
snapshot per heavy run.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from .buffer import Buffer
from .config import settings
from .context import snapshot
from .endpoints import targets_for
from .uploader import flush
from .workloads import baseline, download, email, path, video, web

HEAVY = {"web": web, "video": video, "email": email, "download": download}


def _record(workload: str, endpoint: str, target: str, run_id: str) -> dict:
    """Run one workload against one target and shape it into a record."""
    base = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "probe_id": settings.probe_id,
        "run_id": run_id,
        "workload": workload,
        "endpoint": endpoint,
        "target": target,
        "context": snapshot(),
        "raw_ref": None,
        "net_hash": None,
    }
    try:
        module = HEAVY[workload] if workload in HEAVY else baseline
        base["metrics"] = module.run(target)
        base["ok"], base["error"] = True, None
    except Exception as exc:  # a failed run is still a data point
        base["metrics"], base["ok"], base["error"] = {}, False, str(exc)
    return base


def run_baseline(buffer: Buffer) -> None:
    run_id = uuid.uuid4().hex
    for anchor in settings.dns_anchors:
        buffer.add(_record("baseline", "real", anchor, run_id))
    flush(buffer)


def run_heavy(buffer: Buffer) -> None:
    run_id = uuid.uuid4().hex
    for workload in HEAVY:
        for ep in targets_for(workload):
            if ep.label:
                buffer.add(_record(workload, ep.name, ep.label, run_id))
    # one path snapshot per heavy cycle
    buffer.add(_record("path", "real", settings.dns_anchors[0], run_id))
    flush(buffer)

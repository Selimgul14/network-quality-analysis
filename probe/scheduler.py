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
from .endpoints import REF_PATHS, targets_for
from .netid import net_hash
from .uploader import flush
from .workloads import baseline, download, email, loadlat, path, video, web

# Every workload module, keyed by its contract name. Anything missing here
# would silently fall back to another module, so keep it exhaustive.
WORKLOADS = {
    "web": web,
    "video": video,
    "email": email,
    "download": download,
    "baseline": baseline,
    "path": path,
    "loadlat": loadlat,
}
# The ones that run against all three endpoints each heavy cycle.
HEAVY = ("web", "video", "email", "download")


def _record(workload: str, endpoint: str, target: str, run_id: str) -> dict:
    """Run one workload against one target and shape it into a record."""
    ctx = snapshot()
    base = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "probe_id": settings.probe_id,
        # Explicit label wins; otherwise self-label by the network we are on.
        "site": settings.site or ctx.get("ssid") or None,
        "run_id": run_id,
        "workload": workload,
        "endpoint": endpoint,
        "target": target,
        "context": ctx,
        "raw_ref": None,
        "net_hash": net_hash(),
    }
    try:
        module = WORKLOADS[workload]
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
    # one path snapshot per heavy cycle; ship the full mtr JSON as a raw
    # payload ("_raw" is stripped by the uploader, never hits the schema)
    rec = _record("path", "real", settings.dns_anchors[0], run_id)
    if rec["ok"] and path.last_raw:
        rec["raw_ref"] = f"{settings.probe_id}/{run_id}-path.json"
        rec["_raw"] = path.last_raw.decode()
    buffer.add(rec)

    # Latency under load: needs a target big enough to saturate the link.
    load_target = settings.real_download or (
        settings.cloud_base + REF_PATHS["download"]
    )
    buffer.add(_record("loadlat", "real", load_target, run_id))
    flush(buffer)

"""The "where is the slowness" attribution logic.

Every heavy workload runs against three endpoints. Comparing medians over
the window locates the bottleneck:

  local slow                -> WiFi link (router to probe)
  local ok, cloud slow      -> Internet path (router upstream)
  cloud ok, real slow       -> third-party service

Pure functions over row dicts so the logic is unit-testable without a DB.
"""
from __future__ import annotations

from statistics import median
from typing import Any

# Per-workload headline metric and thresholds: (metric, good, poor, unit).
# For throughput higher is better; for times lower is better.
WORKLOAD_METRIC = {
    "web": ("load_ms", 2000, 5000, "ms"),
    "video": ("startup_ms", 3000, 8000, "ms"),
    "email": ("fetch_ms", 1000, 3000, "ms"),
    "download": ("throughput_mbps", 20, 5, "Mbps"),
}
LOWER_IS_BETTER = {"web", "video", "email"}

SEGMENT_LABELS = {
    "wifi_link": "WiFi link",
    "internet_path": "Internet path",
    "third_party": "Third-party service",
}


def _median_metric(rows: list[dict], workload: str, endpoint: str) -> float | None:
    metric = WORKLOAD_METRIC[workload][0]
    vals = [
        r["metrics"][metric]
        for r in rows
        if r["workload"] == workload and r["endpoint"] == endpoint
        and r["ok"] and metric in (r["metrics"] or {})
    ]
    return round(median(vals), 2) if vals else None


def _status(workload: str, value: float | None) -> str:
    """good | degraded | poor | no_data for one median value."""
    if value is None:
        return "no_data"
    _, good, poor, _ = WORKLOAD_METRIC[workload]
    if workload in LOWER_IS_BETTER:
        return "good" if value <= good else ("degraded" if value <= poor else "poor")
    return "good" if value >= good else ("degraded" if value >= poor else "poor")


def _attribute(per_endpoint: dict[str, str]) -> str | None:
    """Map the three endpoint statuses to the segment at fault, if any."""
    bad = {"degraded", "poor"}
    if per_endpoint.get("local") in bad:
        return "wifi_link"
    if per_endpoint.get("cloud") in bad:
        return "internet_path"
    if per_endpoint.get("real") in bad:
        return "third_party"
    return None


def compute_summary(rows: list[dict], hours: int) -> dict[str, Any]:
    workloads: dict[str, Any] = {}
    suspects: list[str] = []

    for w in WORKLOAD_METRIC:
        metric, _, _, unit = WORKLOAD_METRIC[w]
        values = {ep: _median_metric(rows, w, ep) for ep in ("local", "cloud", "real")}
        statuses = {ep: _status(w, v) for ep, v in values.items()}
        cause = _attribute(statuses)
        if cause:
            suspects.append(cause)
        # Headline value: the user-facing number is the real-world one,
        # falling back to cloud/local when real has no data.
        headline = values["real"] or values["cloud"] or values["local"]
        workloads[w] = {
            "metric": metric,
            "unit": unit,
            "value": headline,
            "status": _status(w, headline),
            "per_endpoint": values,
            "endpoint_status": statuses,
            "likely_cause": cause,
        }

    # Segment view: a segment is suspect if any workload points at it.
    segments = {s: ("suspect" if s in suspects else "ok") for s in SEGMENT_LABELS}
    likely = max(set(suspects), key=suspects.count) if suspects else None

    statuses = [w["status"] for w in workloads.values() if w["status"] != "no_data"]
    overall = (
        "no_data" if not statuses
        else "poor" if "poor" in statuses
        else "slow" if "degraded" in statuses
        else "good"
    )

    degraded = [w for w, d in workloads.items() if d["status"] in ("degraded", "poor")]
    if overall == "good":
        headline_text = "Everything looks fine"
    elif overall == "no_data":
        headline_text = "No measurements yet"
    else:
        headline_text = f"Mostly fine, {' and '.join(degraded)} slow" if len(
            degraded) < 3 else "Your network is struggling"

    return {
        "window_hours": hours,
        "overall": overall,
        "headline": headline_text,
        "segments": segments,
        "likely_cause": likely,
        "workloads": workloads,
    }

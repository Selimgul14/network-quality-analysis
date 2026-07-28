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

# Per-endpoint overrides. The local/cloud reference page is a small static
# file; a real news site pulls megabytes across dozens of requests, so it
# is legitimately slower and cannot be judged against the same line. The
# question for the "real" endpoint is not "is it fast" but "is it slower
# than this service normally is".
ENDPOINT_THRESHOLDS = {
    ("web", "real"): (4000, 8000),
    ("video", "real"): (4000, 10000),
}

# The WiFi link can be judged from hop 1 of the path (the router over the
# air) when no local reference server is available. Latency only.
WIFI_LINK_GOOD_MS = 10.0
WIFI_LINK_POOR_MS = 30.0

SEGMENT_LABELS = {
    "wifi_link": "WiFi link",
    "internet_path": "Internet path",
    "third_party": "Third-party service",
}

# Which endpoint's data tells us about each segment.
SEGMENT_ENDPOINT = {"wifi_link": "local", "internet_path": "cloud", "third_party": "real"}


def _median_metric(rows: list[dict], workload: str, endpoint: str) -> float | None:
    metric = WORKLOAD_METRIC[workload][0]
    vals = [
        r["metrics"][metric]
        for r in rows
        if r["workload"] == workload and r["endpoint"] == endpoint
        and r["ok"] and metric in (r["metrics"] or {})
    ]
    return round(median(vals), 2) if vals else None


def _thresholds(workload: str, endpoint: str | None = None) -> tuple[float, float]:
    """(good, poor) for a workload, honouring any per-endpoint override."""
    _, good, poor, _ = WORKLOAD_METRIC[workload]
    return ENDPOINT_THRESHOLDS.get((workload, endpoint), (good, poor))


def _status(workload: str, value: float | None, endpoint: str | None = None) -> str:
    """good | degraded | poor | no_data for one median value."""
    if value is None:
        return "no_data"
    good, poor = _thresholds(workload, endpoint)
    if workload in LOWER_IS_BETTER:
        return "good" if value <= good else ("degraded" if value <= poor else "poor")
    return "good" if value >= good else ("degraded" if value >= poor else "poor")


def _first_hop_rtt(rows: list[dict]) -> float | None:
    """Median hop-1 RTT from the path workload: WiFi-link latency."""
    vals = [
        r["metrics"]["first_hop_rtt_ms"]
        for r in rows
        if r["workload"] == "path" and r["ok"]
        and "first_hop_rtt_ms" in (r["metrics"] or {})
    ]
    return round(median(vals), 2) if vals else None


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
    endpoint_has_data = {"local": False, "cloud": False, "real": False}

    for w in WORKLOAD_METRIC:
        metric, good, poor, unit = WORKLOAD_METRIC[w]
        values = {ep: _median_metric(rows, w, ep) for ep in ("local", "cloud", "real")}
        for ep, v in values.items():
            if v is not None:
                endpoint_has_data[ep] = True
        statuses = {ep: _status(w, v, ep) for ep, v in values.items()}
        cause = _attribute(statuses)
        if cause:
            suspects.append(cause)
        # Headline value: the user-facing number is the real-world one,
        # falling back to cloud/local when real has no data. The threshold
        # shown must match whichever endpoint that value came from.
        headline_ep = next((ep for ep in ("real", "cloud", "local") if values[ep]), None)
        headline = values[headline_ep] if headline_ep else None
        good, poor = _thresholds(w, headline_ep)
        workloads[w] = {
            "metric": metric,
            "unit": unit,
            "good": good,
            "poor": poor,
            "lower_is_better": w in LOWER_IS_BETTER,
            "value": headline,
            "status": _status(w, headline, headline_ep),
            "per_endpoint": values,
            "endpoint_status": statuses,
            "likely_cause": cause,
        }

    # Segment view: no_data if its endpoint reported nothing, else suspect
    # if any workload points at it, else ok. Avoids a false "OK" for a
    # segment (e.g. WiFi link) that was never actually measured.
    segments = {
        s: (
            "no_data" if not endpoint_has_data[SEGMENT_ENDPOINT[s]]
            else "suspect" if s in suspects
            else "ok"
        )
        for s in SEGMENT_LABELS
    }

    # Without a local reference server the WiFi link would read "not
    # measured". Hop 1 of the path is the router reached over the air, so
    # it still gives a real (latency-only) verdict on the link.
    first_hop = _first_hop_rtt(rows)
    wifi_from_path = False
    if segments["wifi_link"] == "no_data" and first_hop is not None:
        wifi_from_path = True
        segments["wifi_link"] = "ok" if first_hop <= WIFI_LINK_GOOD_MS else "suspect"
        if first_hop > WIFI_LINK_GOOD_MS:
            suspects.append("wifi_link")

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
        # WiFi-link latency from hop 1, and whether the segment verdict
        # came from it rather than from a local reference server.
        "wifi_link_rtt_ms": first_hop,
        "wifi_link_from_path": wifi_from_path,
    }

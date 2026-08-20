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

# --- Composite health score --------------------------------------------------
# One 0-100 figure over the workloads, weighted by how much each shapes
# user experience. Every weight is tied to a source rather than invented:
#   video 0.35          rebuffering has the largest impact on engagement of
#                       any quality metric (Dobrian et al., SIGCOMM 2011),
#                       and video is the majority of downstream traffic
#                       (Sandvine Global Internet Phenomena 2024: 54%).
#   responsiveness 0.25 latency under load + packet loss: what interactive
#                       use (calls, gaming, typing) feels. Bufferbloat in
#                       the home gateway dominates interactive latency
#                       (Sundaresan et al., SIGCOMM 2011).
#   web 0.25            waiting time drives web QoE (ITU-T G.1030).
#   download 0.10       bulk transfer: elastic, tolerant (ITU-T G.1010
#   email 0.05          "background" class; email tolerates minutes).
HEALTH_WEIGHTS = {
    "video": 0.35,
    "responsiveness": 0.25,
    "web": 0.25,
    "download": 0.10,
    "email": 0.05,
}
# Responsiveness inputs: added latency under load (the common bufferbloat
# grading bands put A under ~30 ms) and baseline loss (interactive audio
# degrades past ~1% and badly past ~5%, cf. ITU-T G.1010 / G.107).
BLOAT_GOOD_MS, BLOAT_POOR_MS = 30.0, 100.0
LOSS_GOOD_PCT, LOSS_POOR_PCT = 1.0, 5.0

# A median can only describe runs that produced a number, so it is blind
# to runs that failed outright. A window straddling an outage therefore
# scored 93 "excellent" while its own segments read "not responding".
# Availability is the missing dimension: of the application-level tasks
# attempted, how many completed at all. The quality score describes how
# good the service was while it worked; multiplying by availability gives
# the quality actually experienced across the window, which is zero for
# the time the network was unusable.
AVAILABILITY_WORKLOADS = ("web", "video", "email", "download")
# Below this share of failures a segment is unstable rather than down.
UNSTABLE_FAIL_PCT = 10.0


def _attempts(rows: list[dict], workload: str, endpoint: str) -> tuple[int, int]:
    """(attempted, failed) runs for one workload/endpoint in the window.

    A run that was tried and failed is evidence of a problem; a run that
    never happened is evidence of nothing. Before this distinction existed
    a total outage looked identical to an idle probe, and the page said
    "No measurements yet" during the 18 August uplink failure.
    """
    tried = [r for r in rows if r["workload"] == workload and r["endpoint"] == endpoint]
    return len(tried), sum(1 for r in tried if not r["ok"])


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


def _status(workload: str, value: float | None, endpoint: str | None = None,
            attempts: tuple[int, int] | None = None) -> str:
    """good | degraded | poor | unstable | failed | no_data.

    `attempts` is (tried, failed). Every attempt failing means the target
    was unreachable ("failed"), a much stronger statement than "no_data".
    Some attempts failing means it was reachable only part of the time
    ("unstable"), which the median alone would hide entirely.
    """
    if attempts:
        tried, failed = attempts
        if tried and failed == tried:
            return "failed"
        if tried and failed / tried * 100 >= UNSTABLE_FAIL_PCT:
            return "unstable"
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


def _interp(v: float, x0: float, x1: float, y0: float, y1: float) -> float:
    return y0 + (v - x0) * (y1 - y0) / (x1 - x0)


def _quality(value: float | None, good: float, poor: float, lower: bool = True) -> float | None:
    """Map one metric to a 0-100 quality index anchored on the MOS scale
    (ITU-T P.800 ACR, MOS m -> (m-1)*25): the good threshold sits at
    MOS 4 (75), poor at MOS 2 (25), saturating at twice-good/twice-poor."""
    if value is None:
        return None
    if lower:
        if value <= 0:
            return 100.0
        if value <= good:
            return round(_interp(value, 0, good, 100, 75), 1)
        if value <= poor:
            return round(_interp(value, good, poor, 75, 25), 1)
        if value <= 2 * poor:
            return round(_interp(value, poor, 2 * poor, 25, 0), 1)
        return 0.0
    if value >= 2 * good:
        return 100.0
    if value >= good:
        return round(_interp(value, good, 2 * good, 75, 100), 1)
    if value >= poor:
        return round(_interp(value, poor, good, 25, 75), 1)
    if value >= poor / 2:
        return round(_interp(value, poor / 2, poor, 0, 25), 1)
    return 0.0


def _responsiveness(rows: list[dict]) -> float | None:
    """Interactive feel: median added latency under load (loadlat) and
    median baseline loss, each mapped to quality and averaged."""
    bloat = [
        r["metrics"]["bloat_ms"] for r in rows
        if r["workload"] == "loadlat" and r["ok"] and "bloat_ms" in (r["metrics"] or {})
    ]
    loss = [
        r["metrics"]["loss_pct"] for r in rows
        if r["workload"] == "baseline" and r["ok"] and "loss_pct" in (r["metrics"] or {})
    ]
    parts = [
        q for q in (
            _quality(median(bloat), BLOAT_GOOD_MS, BLOAT_POOR_MS) if bloat else None,
            _quality(median(loss), LOSS_GOOD_PCT, LOSS_POOR_PCT) if loss else None,
        ) if q is not None
    ]
    return round(sum(parts) / len(parts), 1) if parts else None


def _health(workloads: dict[str, Any], rows: list[dict]) -> dict[str, Any]:
    """Weighted composite over the available components. Weights of
    missing components are renormalised away rather than counted as 0."""
    components: dict[str, float | None] = {
        w: _quality(d["value"], d["good"], d["poor"], d["lower_is_better"])
        for w, d in workloads.items()
    }
    components["responsiveness"] = _responsiveness(rows)
    have = {k: v for k, v in components.items() if v is not None}
    if have:
        wsum = sum(HEALTH_WEIGHTS[k] for k in have)
        quality = round(sum(HEALTH_WEIGHTS[k] * v for k, v in have.items()) / wsum, 1)
    else:
        quality = None

    # Quality describes the runs that worked. Scaling by availability
    # gives the quality actually experienced: a service that was down for
    # a third of the window delivered nothing for that third.
    availability = _availability(rows)
    score = quality
    if quality is not None and availability["pct"] is not None:
        score = round(quality * availability["pct"] / 100, 1)

    label = (
        "no_data" if score is None
        else "excellent" if score >= 90
        else "good" if score >= 75   # MOS 4 anchor
        else "fair" if score >= 50   # MOS 3
        else "poor" if score >= 25   # MOS 2
        else "bad"
    )
    return {
        "score": score,
        "label": label,
        # kept separate so the page can say "good when it worked, but it
        # only worked 67% of the time"
        "quality": quality,
        "availability": availability,
        "components": components,
        "weights": HEALTH_WEIGHTS,
    }


def _availability(rows: list[dict]) -> dict[str, Any]:
    """How much of the window the network actually carried a user task.

    Counted over the application-level workloads only: a failed web or
    video run is a task the user could not complete. Baseline pings are
    excluded because they succeed (reporting 100% loss) even when nothing
    else works, so counting them would understate an outage.
    """
    tried = [r for r in rows if r["workload"] in AVAILABILITY_WORKLOADS]
    failed = [r for r in tried if not r["ok"]]
    pct = round((len(tried) - len(failed)) / len(tried) * 100, 1) if tried else None
    return {
        "pct": pct,
        "attempted": len(tried),
        "failed": len(failed),
    }


def _attribute(per_endpoint: dict[str, str]) -> str | None:
    """Map the three endpoint statuses to the segment at fault, if any."""
    bad = {"degraded", "poor", "failed", "unstable"}
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

    endpoint_all_failed = {"local": False, "cloud": False, "real": False}
    endpoint_unstable = {"local": False, "cloud": False, "real": False}

    for w in WORKLOAD_METRIC:
        metric, good, poor, unit = WORKLOAD_METRIC[w]
        values = {ep: _median_metric(rows, w, ep) for ep in ("local", "cloud", "real")}
        tries = {ep: _attempts(rows, w, ep) for ep in ("local", "cloud", "real")}
        for ep, v in values.items():
            if v is not None:
                endpoint_has_data[ep] = True
        statuses = {ep: _status(w, v, ep, tries[ep]) for ep, v in values.items()}
        for ep, st in statuses.items():
            if st == "failed":
                endpoint_all_failed[ep] = True
            elif st == "unstable":
                endpoint_unstable[ep] = True
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
            "status": _status(w, headline, headline_ep,
                              tries[headline_ep] if headline_ep else
                              # nothing produced a number: if every endpoint
                              # that was tried failed, say so
                              tuple(map(sum, zip(*tries.values())))),
            "per_endpoint": values,
            "endpoint_status": statuses,
            "likely_cause": cause,
        }

    # Segment view: no_data if its endpoint reported nothing, else suspect
    # if any workload points at it, else ok. Avoids a false "OK" for a
    # segment (e.g. WiFi link) that was never actually measured.
    # "down" outranks the rest: every run against that endpoint was tried
    # and failed, so the segment is not merely slow, it is unreachable.
    segments = {
        s: (
            "down" if endpoint_all_failed[SEGMENT_ENDPOINT[s]]
            else "unstable" if endpoint_unstable[SEGMENT_ENDPOINT[s]]
            else "no_data" if not endpoint_has_data[SEGMENT_ENDPOINT[s]]
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
    if segments["wifi_link"] in ("no_data", "down", "unstable") and first_hop is not None:
        # The gateway answering over the air proves the link is alive even
        # when every off-site workload failed: that is the whole point of
        # measuring the local leg separately.
        wifi_from_path = True
        segments["wifi_link"] = "ok" if first_hop <= WIFI_LINK_GOOD_MS else "suspect"
        if first_hop > WIFI_LINK_GOOD_MS:
            suspects.append("wifi_link")

    likely = max(set(suspects), key=suspects.count) if suspects else None

    statuses = [w["status"] for w in workloads.values() if w["status"] != "no_data"]
    down = [s for s, v in segments.items() if v == "down"]
    unstable = [s for s, v in segments.items() if v == "unstable"]
    health = _health(workloads, rows)
    avail = health["availability"]
    overall = (
        "down" if down
        else "unstable" if unstable
        else "no_data" if not statuses
        else "poor" if "poor" in statuses
        else "slow" if "degraded" in statuses
        else "good"
    )

    degraded = [w for w, d in workloads.items() if d["status"] in ("degraded", "poor")]
    if overall == "down":
        # Name the segment in plain English: during the 18 August uplink
        # failure the WiFi link was fine and everything beyond it was not,
        # which is exactly what a user needs told.
        if segments["wifi_link"] == "ok" and "internet_path" in down:
            headline_text = "Your WiFi is fine, but the internet connection is down"
        elif "wifi_link" in down:
            headline_text = "Your WiFi link is down"
        else:
            headline_text = f"{SEGMENT_LABELS[down[0]]} is not responding"
    elif overall == "unstable":
        # Part of the window worked and part did not: say so, rather than
        # reporting the median of the half that worked.
        pct = avail["pct"]
        where = ("Your WiFi is fine, but the internet connection"
                 if segments["wifi_link"] == "ok" and "internet_path" in unstable
                 else "Your WiFi link" if "wifi_link" in unstable
                 else SEGMENT_LABELS[unstable[0]])
        headline_text = f"{where} dropped out: {pct}% of tasks completed"
    elif overall == "good":
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
        # Composite 0-100 health over all components, weights documented
        # at HEALTH_WEIGHTS (each tied to a cited source), scaled by the
        # share of user tasks that completed at all.
        "health": health,
        "segments": segments,
        "likely_cause": likely,
        "workloads": workloads,
        # WiFi-link latency from hop 1, and whether the segment verdict
        # came from it rather than from a local reference server.
        "wifi_link_rtt_ms": first_hop,
        "wifi_link_from_path": wifi_from_path,
    }

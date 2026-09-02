"""Attribution logic: each fault pattern maps to the right segment."""
from __future__ import annotations

from cloud.app.summary import compute_summary


def _row(workload: str, endpoint: str, **metrics) -> dict:
    return {"workload": workload, "endpoint": endpoint, "ok": True, "metrics": metrics}


def _web_rows(local_ms: float, cloud_ms: float, real_ms: float) -> list[dict]:
    return [
        _row("web", "local", load_ms=local_ms),
        _row("web", "cloud", load_ms=cloud_ms),
        _row("web", "real", load_ms=real_ms),
    ]


def test_all_healthy():
    s = compute_summary(_web_rows(300, 800, 1200), hours=24)
    assert s["overall"] == "good"
    assert s["likely_cause"] is None
    assert s["workloads"]["web"]["status"] == "good"


def test_slow_local_blames_wifi_link():
    # Slow even to the LAN reference: the WiFi link is at fault.
    s = compute_summary(_web_rows(4000, 4500, 5000), hours=24)
    assert s["likely_cause"] == "wifi_link"
    assert s["segments"]["wifi_link"] == "suspect"


def test_slow_cloud_blames_internet_path():
    # LAN fine, controlled cloud slow: upstream path.
    s = compute_summary(_web_rows(300, 4500, 5000), hours=24)
    assert s["likely_cause"] == "internet_path"
    assert s["segments"]["wifi_link"] == "ok"


def test_slow_real_blames_third_party():
    # LAN and cloud fine, only the real service slow. Real sites are judged
    # against their own threshold (4 s good / 8 s poor), so this is poor.
    s = compute_summary(_web_rows(300, 800, 9000), hours=24)
    assert s["likely_cause"] == "third_party"
    assert s["workloads"]["web"]["status"] == "poor"


def test_real_web_uses_its_own_threshold():
    """A full news site is heavier than the reference page, so the same
    load time is fine for 'real' but slow for the small cloud page."""
    s = compute_summary(_web_rows(300, 800, 3600), hours=24)
    assert s["workloads"]["web"]["endpoint_status"]["real"] == "good"
    assert s["workloads"]["web"]["good"] == 4000  # threshold shown matches
    assert s["likely_cause"] is None

    slow_cloud = compute_summary(_web_rows(300, 3600, 800), hours=24)
    assert slow_cloud["workloads"]["web"]["endpoint_status"]["cloud"] == "degraded"


def test_wifi_link_falls_back_to_first_hop():
    """With no local server, hop 1 still gives a latency verdict."""
    rows = [
        _row("web", "cloud", load_ms=300),
        _row("web", "real", load_ms=900),
        _row("path", "real", first_hop_rtt_ms=4.9),
    ]
    s = compute_summary(rows, hours=24)
    assert s["segments"]["wifi_link"] == "ok"
    assert s["wifi_link_from_path"] is True
    assert s["wifi_link_rtt_ms"] == 4.9


def test_slow_first_hop_makes_wifi_link_suspect():
    rows = [
        _row("web", "cloud", load_ms=300),
        _row("path", "real", first_hop_rtt_ms=45.0),  # congested air link
    ]
    s = compute_summary(rows, hours=24)
    assert s["segments"]["wifi_link"] == "suspect"


def test_local_data_wins_over_first_hop():
    """A real local server is the better evidence; keep using it."""
    rows = _web_rows(300, 800, 900) + [_row("path", "real", first_hop_rtt_ms=99.0)]
    s = compute_summary(rows, hours=24)
    assert s["wifi_link_from_path"] is False
    assert s["segments"]["wifi_link"] == "ok"


def test_download_higher_is_better():
    rows = [
        _row("download", "local", throughput_mbps=90),
        _row("download", "cloud", throughput_mbps=45),
        _row("download", "real", throughput_mbps=3),  # below poor threshold
    ]
    s = compute_summary(rows, hours=24)
    assert s["workloads"]["download"]["status"] == "poor"
    assert s["likely_cause"] == "third_party"


def test_failed_runs_are_excluded():
    rows = _web_rows(300, 800, 1200)
    rows.append({"workload": "web", "endpoint": "real", "ok": False, "metrics": {}})
    s = compute_summary(rows, hours=24)
    assert s["workloads"]["web"]["per_endpoint"]["real"] == 1200


def _fail(workload: str, endpoint: str, error: str = "name resolution") -> dict:
    return {"workload": workload, "endpoint": endpoint, "ok": False,
            "metrics": {}, "error": error}


def test_no_data():
    s = compute_summary([], hours=24)
    assert s["overall"] == "no_data"
    assert s["likely_cause"] is None


# --- outage vs no data -------------------------------------------------------
# Modelled on the real uplink failure of 18 August 2026, 23:23-00:03 UTC:
# the gateway answered with 0% loss throughout while every off-site
# destination lost 100%. Before this distinction existed the page reported
# "No measurements yet" during the outage.


def test_total_outage_is_reported_as_down_not_no_data():
    rows = [_fail(w, ep) for w in ("web", "video", "download") for ep in ("cloud", "real")]
    rows += [_fail("email", "real")]
    rows += [_row("path", "real", first_hop_rtt_ms=4.9)]  # the link still answers
    s = compute_summary(rows, hours=1)
    assert s["overall"] == "down"
    assert s["headline"] == "Your WiFi is fine, but the internet connection is down"
    assert s["segments"]["internet_path"] == "down"
    assert s["segments"]["wifi_link"] == "ok"      # gateway proves the link is alive
    assert s["likely_cause"] == "internet_path"


def test_failed_runs_are_not_confused_with_absent_runs():
    """Nothing attempted is no_data; everything attempted and failed is not."""
    assert compute_summary([], hours=1)["overall"] == "no_data"
    attempted = compute_summary([_fail("web", "cloud"), _fail("web", "real")], hours=1)
    assert attempted["workloads"]["web"]["endpoint_status"]["cloud"] == "failed"
    assert attempted["workloads"]["web"]["endpoint_status"]["local"] == "no_data"
    assert attempted["overall"] == "down"


def test_partial_failure_reads_as_unstable_not_good():
    """Half the runs failed. The median of the surviving half says 1200 ms
    and looks healthy, which is exactly the blindness availability fixes."""
    rows = [_row("web", "real", load_ms=1200), _fail("web", "real")]
    s = compute_summary(rows, hours=1)
    assert s["workloads"]["web"]["endpoint_status"]["real"] == "unstable"
    assert s["overall"] == "unstable"
    assert s["overall"] != "down"          # it did work some of the time
    assert s["health"]["availability"]["pct"] == 50.0
    # quality describes the runs that worked; score is what was experienced
    assert s["health"]["quality"] > s["health"]["score"]


def test_a_single_blip_does_not_flip_the_verdict():
    """One failure in a long healthy window is noise, not instability."""
    rows = [_row("web", "real", load_ms=1200) for _ in range(50)] + [_fail("web", "real")]
    s = compute_summary(rows, hours=24)
    assert s["workloads"]["web"]["endpoint_status"]["real"] == "good"
    assert s["overall"] == "good"
    assert s["health"]["availability"]["pct"] >= 98


def test_availability_scales_the_health_score():
    """A window that was down a third of the time cannot score excellent."""
    good = [_row(w, "real", **m) for w, m in (
        ("web", {"load_ms": 1000}), ("video", {"startup_ms": 200}),
        ("email", {"fetch_ms": 500}), ("download", {"throughput_mbps": 60}))]
    healthy = compute_summary(good * 2, hours=1)["health"]
    assert healthy["availability"]["pct"] == 100.0
    assert healthy["score"] == healthy["quality"]

    # same quality of service, but a third of the attempts failed outright
    patchy = compute_summary(good * 2 + [_fail("web", "real")] * 4, hours=1)["health"]
    assert patchy["availability"]["pct"] < 70
    assert patchy["score"] < patchy["quality"]
    assert patchy["label"] in ("fair", "poor", "bad")


# --- defects found by fault injection ----------------------------------------


def test_tie_break_is_deterministic_and_upstream_first():
    """Scenario 04 produced one vote for each segment. The old rule,
    max() over a set, returned whichever the set iterated first, so the
    same measurements could be blamed differently after a restart."""
    from cloud.app.summary import _most_likely
    for _ in range(20):
        assert _most_likely(["third_party", "internet_path", "wifi_link"]) == "wifi_link"
        assert _most_likely(["third_party", "internet_path"]) == "internet_path"
    # a clear majority still wins regardless of order
    assert _most_likely(["third_party", "third_party", "wifi_link"]) == "third_party"
    assert _most_likely([]) is None


def test_gateway_probe_beats_traceroute_hop1():
    """Scenario 05: 150 ms injected against every destination except the
    gateway. The direct gateway probe read 2.31 ms; the traceroute first
    hop read 153.25 ms, because a TTL-limited probe is addressed to the
    destination and shares its fate. The direct measurement must win."""
    rows = [
        {"workload": "baseline", "endpoint": "local", "ok": True,
         "metrics": {"rtt_ms": 2.31}} for _ in range(10)
    ]
    rows += [_row("path", "real", first_hop_rtt_ms=153.25)]
    rows += [_row("web", "cloud", load_ms=827.0), _row("web", "real", load_ms=4693.45)]
    s = compute_summary(rows, hours=1)
    assert s["wifi_link_rtt_ms"] == 2.31
    assert s["segments"]["wifi_link"] == "ok"      # the link is exonerated


def test_traceroute_hop1_is_the_fallback():
    """Where the gateway does not answer at all, hop 1 is still used."""
    rows = [_row("path", "real", first_hop_rtt_ms=4.9),
            _row("web", "cloud", load_ms=300)]
    s = compute_summary(rows, hours=1)
    assert s["wifi_link_rtt_ms"] == 4.9
    assert s["wifi_link_from_path"] is True


def test_loss_is_averaged_not_medianed():
    """Scenario 03: 5% loss injected, but 69% of ten-packet runs lose
    nothing, so the median is 0 and hides it. The mean is 3.76% and does
    not. Aggregating loss by the median made the score blind."""
    # 279 clean runs and 125 lossy ones, the shape scenario 03 produced
    rows = [{"workload": "baseline", "endpoint": "real", "ok": True,
             "metrics": {"loss_pct": 0.0}} for _ in range(279)]
    rows += [{"workload": "baseline", "endpoint": "real", "ok": True,
              "metrics": {"loss_pct": 12.0}} for _ in range(125)]
    s = compute_summary(rows, hours=1)
    resp = s["health"]["components"]["responsiveness"]
    # the mean here is ~3.7%, comfortably past the 1% good threshold
    assert resp is not None and resp < 60, f"loss went unnoticed: {resp}"


def test_wifi_link_down_when_even_the_local_leg_fails():
    rows = [_fail("web", "local"), _fail("web", "cloud"), _fail("web", "real")]
    s = compute_summary(rows, hours=1)
    assert s["segments"]["wifi_link"] == "down"
    assert s["headline"] == "Your WiFi link is down"
    assert s["health"]["score"] is None
    assert s["health"]["label"] == "no_data"


# --- composite health score --------------------------------------------------


def test_quality_mos_anchors():
    """good threshold -> 75 (MOS 4), poor -> 25 (MOS 2), saturating."""
    from cloud.app.summary import _quality

    assert _quality(2000, 2000, 5000) == 75.0
    assert _quality(5000, 2000, 5000) == 25.0
    assert _quality(20000, 2000, 5000) == 0.0
    assert _quality(0, 2000, 5000) == 100.0
    # higher-is-better mirrors: good -> 75, 2x good -> 100
    assert _quality(20, 20, 5, lower=False) == 75.0
    assert _quality(40, 20, 5, lower=False) == 100.0
    assert _quality(5, 20, 5, lower=False) == 25.0


def test_health_score_healthy_network():
    """A network good on every component scores in the good band."""
    rows = _web_rows(300, 800, 1200) + [
        _row("video", "real", startup_ms=300),
        _row("email", "real", fetch_ms=550),
        _row("download", "real", throughput_mbps=55),
        _row("loadlat", "real", bloat_ms=15.0),
        _row("baseline", "real", loss_pct=0.0),
    ]
    s = compute_summary(rows, hours=24)
    h = s["health"]
    assert h["score"] >= 75
    assert h["label"] in ("good", "excellent")
    assert h["components"]["responsiveness"] is not None


def test_health_score_weights_missing_components():
    """Missing components drop out; weights renormalise, no 0 counted."""
    rows = _web_rows(300, 800, 1200)  # only web has data
    s = compute_summary(rows, hours=24)
    h = s["health"]
    assert h["components"]["video"] is None
    assert h["components"]["responsiveness"] is None
    # score equals the web component alone, not dragged down by missing
    assert h["score"] == h["components"]["web"]


def test_health_score_bad_video_dominates():
    """Video carries the largest weight (Dobrian: rebuffering dominates
    engagement), so bad video pulls the composite hardest."""
    good_video = compute_summary(
        _web_rows(300, 800, 1200) + [_row("video", "real", startup_ms=300)], hours=24
    )["health"]["score"]
    bad_video = compute_summary(
        _web_rows(300, 800, 1200) + [_row("video", "real", startup_ms=25000)], hours=24
    )["health"]["score"]
    assert bad_video < good_video
    assert good_video - bad_video > 30  # video weight is heavy


def test_health_score_bufferbloat_hurts():
    rows = _web_rows(300, 800, 1200) + [_row("loadlat", "real", bloat_ms=250.0)]
    s = compute_summary(rows, hours=24)
    assert s["health"]["components"]["responsiveness"] == 0.0

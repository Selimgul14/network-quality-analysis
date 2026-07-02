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
    # LAN and cloud fine, only the real service slow.
    s = compute_summary(_web_rows(300, 800, 6000), hours=24)
    assert s["likely_cause"] == "third_party"
    assert s["workloads"]["web"]["status"] == "poor"  # 6000 > poor threshold


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


def test_no_data():
    s = compute_summary([], hours=24)
    assert s["overall"] == "no_data"
    assert s["likely_cause"] is None

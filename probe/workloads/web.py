"""Web page load workload: per-phase timing through a real browser.

Drives headless Chromium via Playwright and reads the Navigation Timing
API so rendering/script time is captured, not just network time
(cf. Wang et al., WProf).
"""
from __future__ import annotations


def run(target: str) -> dict[str, float]:
    # TODO: launch Playwright Chromium, navigate(target), read
    # performance.timing / PerformanceNavigationTiming and derive:
    #   dns_ms, connect_ms, ttfb_ms, load_ms
    # Pin the Chromium version in the Docker image.
    raise NotImplementedError("web workload: implement with Playwright")

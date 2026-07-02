"""Web page load workload: per-phase timing through a real browser.

Drives headless Chromium via Playwright and reads the Navigation Timing
API so rendering/script time is captured, not just network time
(cf. Wang et al., WProf).
"""
from __future__ import annotations

import json

NAV_TIMING_JS = "JSON.stringify(performance.getEntriesByType('navigation')[0].toJSON())"


def run(target: str) -> dict[str, float]:
    # Imported here so probes that never run the web workload (and unit
    # tests on hosts without Chromium) don't need Playwright installed.
    from playwright.sync_api import sync_playwright

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        try:
            page = browser.new_page()
            page.goto(target, wait_until="load", timeout=60_000)
            entry = json.loads(page.evaluate(NAV_TIMING_JS))
        finally:
            browser.close()

    # PerformanceNavigationTiming: values are ms relative to startTime.
    return {
        "dns_ms": round(entry["domainLookupEnd"] - entry["domainLookupStart"], 2),
        "connect_ms": round(entry["connectEnd"] - entry["connectStart"], 2),
        "ttfb_ms": round(entry["responseStart"] - entry["requestStart"], 2),
        "load_ms": round(entry["loadEventEnd"] - entry["startTime"], 2),
    }

"""Detect a click-through captive portal and accept it automatically.

A headless probe cannot click "I agree", so this drives the Chromium that
Playwright already installs for the web workload. Safe to run on a timer:
it exits immediately when the network is already open, and only launches a
browser when a portal is actually in the way. That also re-authenticates
by itself when the portal session expires mid-deployment, which is the
usual reason an unattended run dies after 24 h.

Usage:
    python -m probe.captive_portal          # accept if needed
    python -m probe.captive_portal --dump   # always dump the page, for tuning
"""
from __future__ import annotations

import logging
import re
import sys
import time
from pathlib import Path

import httpx

# A bare 204 means clean internet. Anything else (200, 302, ...) means
# something intercepted the request, which is what a portal does.
CHECK_URL = "http://connectivitycheck.gstatic.com/generate_204"
DEBUG_DIR = Path(__file__).resolve().parent.parent / "portal-debug"

# Text on the element that completes the portal, roughly by likelihood.
ACTION_TEXT = re.compile(
    r"connect|accept|agree|continue|log ?in|sign ?in|submit|start|get online|free|proceed",
    re.I,
)

log = logging.getLogger("captive_portal")


def online(timeout: float = 6.0) -> bool:
    """True when the network is open (no portal in the way)."""
    try:
        r = httpx.get(CHECK_URL, timeout=timeout, follow_redirects=False)
        return r.status_code == 204
    except Exception:
        return False


def _tick_boxes(scope) -> int:
    """Tick every visible checkbox (the 'I accept the terms' box)."""
    ticked = 0
    boxes = scope.locator("input[type=checkbox]")
    for i in range(boxes.count()):
        box = boxes.nth(i)
        try:
            if box.is_visible() and not box.is_checked():
                box.check(timeout=3000)
                ticked += 1
        except Exception:
            continue  # hidden, disabled, or detached: not our checkbox
    return ticked


def _click_action(scope) -> bool:
    """Click the button/link that submits the portal form."""
    candidates = [
        scope.get_by_role("button", name=ACTION_TEXT),
        scope.get_by_role("link", name=ACTION_TEXT),
        scope.locator("input[type=submit]"),
        scope.locator("button"),          # last resort: the only button present
    ]
    for loc in candidates:
        try:
            count = loc.count()
        except Exception:
            continue
        for i in range(count):
            el = loc.nth(i)
            try:
                if not el.is_visible():
                    continue
                el.click(timeout=5000)
                log.info("clicked: %r", (el.inner_text() or "").strip()[:40])
                return True
            except Exception:
                continue
    return False


def _dump(page, tag: str) -> None:
    """Save the page so the selectors can be tuned against the real portal."""
    DEBUG_DIR.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    try:
        (DEBUG_DIR / f"{stamp}-{tag}.html").write_text(page.content())
        page.screenshot(path=str(DEBUG_DIR / f"{stamp}-{tag}.png"), full_page=True)
        log.info("dumped page to %s", DEBUG_DIR)
    except Exception as exc:
        log.warning("could not dump page: %s", exc)


def accept_portal(dump: bool = False) -> bool:
    """Open the portal, accept it, and report whether we got online."""
    from playwright.sync_api import sync_playwright

    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        # Portals often present a self-signed cert on the redirect.
        ctx = browser.new_context(ignore_https_errors=True)
        page = ctx.new_page()
        try:
            page.goto(CHECK_URL, wait_until="domcontentloaded", timeout=30_000)
            page.wait_for_timeout(1500)  # let any JS-built form render
            log.info("portal page: %s", page.url)
            if dump:
                _dump(page, "before")

            # The form may live in an iframe, so try the page and each frame.
            for scope in [page, *page.frames]:
                ticked = _tick_boxes(scope)
                if ticked:
                    log.info("ticked %d checkbox(es)", ticked)
                if _click_action(scope):
                    break
            else:
                log.warning("no clickable action found")
                _dump(page, "no-action")

            page.wait_for_timeout(4000)  # allow the redirect back out
        except Exception as exc:
            log.error("portal interaction failed: %s", exc)
            _dump(page, "error")
        finally:
            browser.close()

    return online()


def main() -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
    )
    dump = "--dump" in sys.argv

    if online() and not dump:
        log.info("already online, nothing to do")
        return 0

    log.warning("no internet: a captive portal is likely in the way")
    for attempt in (1, 2):
        if accept_portal(dump=dump):
            log.info("portal accepted, internet is up (attempt %d)", attempt)
            return 0
        log.warning("attempt %d did not get us online", attempt)
        time.sleep(5)

    log.error("could not pass the portal; see %s", DEBUG_DIR)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

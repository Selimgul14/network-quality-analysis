#!/usr/bin/env python3
"""Score the fault-injection matrix against its pre-registered expectations.

Each scenario ran under its own site label, so its window is queryable on
its own. This asks the live API what the dashboard said during each one
and compares that to what was written down beforehand, in
EXPECTATIONS, before any scenario was run.

    python3 analyse.py --user wifi --password <pw>
    python3 analyse.py --base http://localhost:8000 --markdown

Prints a table for the evaluation chapter: what was injected, what the
tool said, and whether that is correct.
"""
from __future__ import annotations

import argparse
import base64
import json
import sys
import urllib.error
import urllib.request

BASE = "https://comp702-api.azurewebsites.net"

# Written before running anything. A scenario passes when the segment the
# tool blames is the segment that was actually broken.
#
# `cause` is the expected `likely_cause`; `overall` a set of acceptable
# verdicts; `note` what the scenario is really testing.
EXPECTATIONS: dict[str, dict] = {
    "01": {
        "injected": "nothing (control)",
        "cause": None,
        "overall": {"good"},
        "segments": {"wifi_link": "ok", "internet_path": "ok", "third_party": "ok"},
        "note": "a healthy network must not be blamed for anything",
    },
    "02": {
        "injected": "+80 ms on every packet leaving the Pi",
        "cause": "wifi_link",
        "overall": {"slow", "poor"},
        "segments": {"wifi_link": "suspect"},
        "note": "delay on the local leg must land on the WiFi link, "
                "and hop 1 RTT must rise by roughly the injected amount",
    },
    "03": {
        "injected": "5% packet loss on everything",
        "cause": "wifi_link",
        "overall": {"slow", "poor", "unstable"},
        "segments": {"wifi_link": "suspect"},
        "note": "loss at the gateway is the signature of a bad link",
    },
    "04": {
        "injected": "inbound throttled to 5 Mbit",
        "cause": "wifi_link",
        "overall": {"slow", "poor"},
        "segments": {},
        "note": "throughput collapse on every endpoint at once is local",
    },
    "05": {
        "injected": "+150 ms to everything except the gateway",
        "cause": "internet_path",
        "overall": {"slow", "poor"},
        "segments": {"wifi_link": "ok", "internet_path": "suspect"},
        "note": "THE KEY TEST: the gateway stays fast while the world "
                "slows, so the WiFi link must be exonerated",
    },
    "06": {
        "injected": "+400 ms to the real services only",
        "cause": "third_party",
        "overall": {"slow", "poor"},
        "segments": {"wifi_link": "ok", "internet_path": "ok",
                     "third_party": "suspect"},
        "note": "the controlled cloud reference is untouched, so only the "
                "third party can be at fault",
    },
    "07": {
        "injected": "all off-site traffic dropped",
        "cause": "internet_path",
        "overall": {"down"},
        "segments": {"wifi_link": "ok", "internet_path": "down"},
        "note": "reproduces the real outage of 18 August on demand",
    },
    "08": {
        "injected": "20 Mbit inbound with a 500 ms queue",
        "cause": None,
        "overall": {"good", "slow", "poor"},
        "segments": {},
        "note": "bufferbloat: bloat_ms must rise sharply even though idle "
                "latency is unchanged",
    },
}


def fetch(base: str, path: str, auth: tuple[str, str] | None) -> dict:
    req = urllib.request.Request(base.rstrip("/") + path)
    if auth:
        token = base64.b64encode(f"{auth[0]}:{auth[1]}".encode()).decode()
        req.add_header("Authorization", f"Basic {token}")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def evidence(summary: dict, scenario: str) -> str:
    """One supporting number per scenario, for the results table."""
    h = summary.get("health") or {}
    w = summary.get("workloads") or {}
    avail = (h.get("availability") or {}).get("pct")
    if scenario in ("02", "05"):
        rtt = summary.get("wifi_link_rtt_ms")
        return f"hop 1 RTT {rtt} ms"
    if scenario == "03":
        return f"responsiveness {h.get('components', {}).get('responsiveness')}"
    if scenario in ("04", "08"):
        dl = (w.get("download") or {}).get("value")
        return f"download {dl} Mbps"
    if scenario == "06":
        web = (w.get("web") or {}).get("per_endpoint", {})
        return f"web cloud {web.get('cloud')} vs real {web.get('real')} ms"
    if scenario == "07":
        return f"availability {avail}%"
    return f"score {h.get('score')}"


def check(scenario: str, s: dict) -> tuple[bool, list[str]]:
    exp = EXPECTATIONS[scenario]
    fails: list[str] = []
    if s.get("overall") not in exp["overall"]:
        fails.append(f"overall={s.get('overall')} not in {sorted(exp['overall'])}")
    if s.get("likely_cause") != exp["cause"]:
        fails.append(f"cause={s.get('likely_cause')} expected {exp['cause']}")
    for seg, want in exp["segments"].items():
        got = (s.get("segments") or {}).get(seg)
        if got != want:
            fails.append(f"{seg}={got} expected {want}")
    return (not fails), fails


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=BASE)
    ap.add_argument("--user", default="wifi")
    ap.add_argument("--password")
    ap.add_argument("--hours", type=int, default=2,
                    help="window per scenario; must cover its run")
    ap.add_argument("--markdown", action="store_true",
                    help="emit a LaTeX-friendly markdown table")
    args = ap.parse_args()
    auth = (args.user, args.password) if args.password else None

    rows, passed = [], 0
    for scenario in sorted(EXPECTATIONS):
        site = f"faultinj-{scenario}"
        try:
            s = fetch(args.base,
                      f"/summary?hours={args.hours}&site={site}", auth)
        except urllib.error.HTTPError as e:
            print(f"{scenario}: HTTP {e.code} (is the password right?)",
                  file=sys.stderr)
            return 1
        except Exception as e:  # noqa: BLE001
            print(f"{scenario}: {e}", file=sys.stderr)
            continue

        if s.get("overall") == "no_data":
            rows.append((scenario, "NOT RUN", "-", "-", "-", False))
            continue

        ok, fails = check(scenario, s)
        passed += ok
        rows.append((
            scenario,
            EXPECTATIONS[scenario]["injected"],
            s.get("likely_cause") or "none",
            s.get("overall"),
            evidence(s, scenario),
            ok,
        ))
        if not ok:
            print(f"scenario {scenario} MISMATCH: {'; '.join(fails)}",
                  file=sys.stderr)

    if args.markdown:
        print("| # | Injected | Expected | Reported | Verdict | Evidence | Result |")
        print("|---|---|---|---|---|---|---|")
        for sc, inj, cause, overall, ev, ok in rows:
            exp = EXPECTATIONS[sc]["cause"] or "none"
            print(f"| {sc} | {inj} | {exp} | {cause} | {overall} | {ev} | "
                  f"{'pass' if ok else 'FAIL'} |")
    else:
        print(f"{'#':<4}{'reported':<16}{'expected':<16}{'overall':<10}"
              f"{'evidence':<34}result")
        for sc, inj, cause, overall, ev, ok in rows:
            exp = EXPECTATIONS[sc]["cause"] or "none"
            print(f"{sc:<4}{cause:<16}{exp:<16}{overall:<10}{ev:<34}"
                  f"{'pass' if ok else 'FAIL'}")

    print(f"\n{passed}/{len(rows)} scenarios attributed correctly")
    return 0 if passed == len(rows) else 2


if __name__ == "__main__":
    raise SystemExit(main())

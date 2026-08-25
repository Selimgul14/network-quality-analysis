#!/usr/bin/env python3
"""Deployment analysis for the dissertation's results chapter.

Walks the whole deployment backwards in windows (the query API caps a
single request at 336 hours and 50,000 rows), aggregates as it goes, and
discards the raw rows. Aggregates are cached to disk so a second run only
fetches what it has not seen, which matters because the dataset is around
700,000 records.

    python3 deployment.py --password <pw> --days 40
    python3 deployment.py --password <pw> --report        # from cache only

Produces: dataset shape, latency decomposition by destination class,
diurnal patterns, loss and bufferbloat distributions, availability, and
an automatic scan for connectivity incidents.
"""
from __future__ import annotations

import argparse
import base64
import json
import random
import statistics as st
import sys
import time
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

BASE = "https://comp702-api.azurewebsites.net"
SITE = "true student"
CACHE = Path(__file__).with_name("deployment-cache.json")

# Application-level workloads: a failure here is a user task that did not
# complete, which is what availability counts.
APP_WORKLOADS = ("web", "video", "email", "download")
BUCKET_CAP = 2_000           # reservoir cap per bucket: 2k keeps p50/p95
                             # accurate while leaving the cache small enough
                             # to rewrite between windows
WINDOW_H = 24                # fetch size; per endpoint this stays under the
                             # 50,000-row cap even for the busiest leg


def fetch(base: str, path: str, auth: tuple[str, str] | None, retries: int = 3):
    req = urllib.request.Request(base.rstrip("/") + path)
    if auth:
        tok = base64.b64encode(f"{auth[0]}:{auth[1]}".encode()).decode()
        req.add_header("Authorization", f"Basic {tok}")
    last = None
    for _ in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.load(r)
        except Exception as e:  # noqa: BLE001
            last = e
    raise RuntimeError(f"GET {path}: {last}")


class Reservoir:
    """Bounded random sample, so percentiles stay accurate without holding
    a million floats per bucket."""

    def __init__(self) -> None:
        self.vals: list[float] = []
        self.n = 0

    def add(self, v: float) -> None:
        self.n += 1
        if len(self.vals) < BUCKET_CAP:
            self.vals.append(v)
        else:
            j = random.randrange(self.n)
            if j < BUCKET_CAP:
                self.vals[j] = v

    def pct(self, p: float) -> float | None:
        if not self.vals:
            return None
        s = sorted(self.vals)
        k = max(0, min(len(s) - 1, int(round(p / 100 * (len(s) - 1)))))
        return round(s[k], 2)

    def to_json(self) -> dict:
        return {"n": self.n, "vals": self.vals}

    @classmethod
    def from_json(cls, d: dict) -> "Reservoir":
        r = cls()
        r.n, r.vals = d["n"], d["vals"]
        return r


def new_state() -> dict:
    return {
        "windows_done": [],
        "counts": defaultdict(int),          # workload -> rows
        "fails": defaultdict(int),           # workload -> failed rows
        "days": defaultdict(int),            # date -> rows
        "rtt": defaultdict(Reservoir),       # target -> rtt samples
        "loss": defaultdict(lambda: [0, 0]), # target -> [lost, sent] (10 per run)
        "rtt_hour": defaultdict(Reservoir),  # "target|HH" -> rtt
        "app_hour": defaultdict(lambda: [0, 0]),   # HH -> [ok, total]
        "dl_hour": defaultdict(Reservoir),   # HH -> throughput
        "web_hour": defaultdict(Reservoir),  # HH -> load_ms (real)
        "bloat": Reservoir(),
        "bloat_hour": defaultdict(Reservoir),
        "hop1": Reservoir(),
        "incidents": [],                     # detected connectivity failures
        "first_ts": None,
        "last_ts": None,
    }


def scan_incidents(rows: list[dict], state: dict) -> None:
    """Find windows where the gateway answered but nothing off-site did.

    That signature, a healthy local link with every remote destination
    unreachable, is exactly the 18 August uplink failure. Scanning for it
    automatically turns one anecdote into a count.
    """
    buckets: dict[str, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    for r in rows:
        if r["workload"] != "baseline" or not r["ok"]:
            continue
        loss = (r["metrics"] or {}).get("loss_pct")
        if loss is None:
            continue
        minute = r["ts"][:16]
        kind = "gateway" if r["endpoint"] == "local" else "offsite"
        buckets[minute][kind].append(loss)

    for minute in sorted(buckets):
        gw, off = buckets[minute].get("gateway", []), buckets[minute].get("offsite", [])
        if not gw or not off:
            continue
        if st.mean(gw) <= 5 and st.mean(off) >= 90:
            state["incidents"].append(minute)


def absorb(rows: list[dict], state: dict) -> None:
    for r in rows:
        ts, w, m = r["ts"], r["workload"], (r["metrics"] or {})
        state["counts"][w] += 1
        state["days"][ts[:10]] += 1
        if not r["ok"]:
            state["fails"][w] += 1
        if state["first_ts"] is None or ts < state["first_ts"]:
            state["first_ts"] = ts
        if state["last_ts"] is None or ts > state["last_ts"]:
            state["last_ts"] = ts

        hh = ts[11:13]
        if w in APP_WORKLOADS:
            slot = state["app_hour"][hh]
            slot[1] += 1
            slot[0] += 1 if r["ok"] else 0

        if not r["ok"]:
            continue

        if w == "baseline":
            tgt = r["target"]
            if (rtt := m.get("rtt_ms")):
                state["rtt"][tgt].add(rtt)
                state["rtt_hour"][f"{tgt}|{hh}"].add(rtt)
            if (loss := m.get("loss_pct")) is not None:
                # 10 packets per run since 18 Aug, 5 before; loss_pct is the
                # share either way, so accumulate as a weighted rate
                acc = state["loss"][tgt]
                acc[0] += loss
                acc[1] += 100
        elif w == "download" and (t := m.get("throughput_mbps")):
            state["dl_hour"][hh].add(t)
        elif w == "web" and r["endpoint"] == "real" and (l := m.get("load_ms")):
            state["web_hour"][hh].add(l)
        elif w == "loadlat" and (b := m.get("bloat_ms")) is not None:
            state["bloat"].add(b)
            state["bloat_hour"][hh].add(b)
        elif w == "path" and (h := m.get("first_hop_rtt_ms")):
            state["hop1"].add(h)


def save(state: dict) -> None:
    out = {
        "windows_done": state["windows_done"],
        "counts": dict(state["counts"]),
        "fails": dict(state["fails"]),
        "days": dict(state["days"]),
        "rtt": {k: v.to_json() for k, v in state["rtt"].items()},
        "loss": {k: v for k, v in state["loss"].items()},
        "rtt_hour": {k: v.to_json() for k, v in state["rtt_hour"].items()},
        "app_hour": dict(state["app_hour"]),
        "dl_hour": {k: v.to_json() for k, v in state["dl_hour"].items()},
        "web_hour": {k: v.to_json() for k, v in state["web_hour"].items()},
        "bloat": state["bloat"].to_json(),
        "bloat_hour": {k: v.to_json() for k, v in state["bloat_hour"].items()},
        "hop1": state["hop1"].to_json(),
        "incidents": sorted(set(state["incidents"])),
        "first_ts": state["first_ts"],
        "last_ts": state["last_ts"],
    }
    CACHE.write_text(json.dumps(out))


def load() -> dict:
    state = new_state()
    if not CACHE.exists():
        return state
    d = json.loads(CACHE.read_text())
    state["windows_done"] = d["windows_done"]
    for k in ("counts", "fails", "days"):
        state[k].update(d[k])
    for k in ("rtt", "rtt_hour", "dl_hour", "web_hour", "bloat_hour"):
        for name, v in d[k].items():
            state[k][name] = Reservoir.from_json(v)
    state["loss"].update({k: list(v) for k, v in d["loss"].items()})
    state["app_hour"].update({k: list(v) for k, v in d["app_hour"].items()})
    state["bloat"] = Reservoir.from_json(d["bloat"])
    state["hop1"] = Reservoir.from_json(d["hop1"])
    state["incidents"] = d["incidents"]
    state["first_ts"], state["last_ts"] = d["first_ts"], d["last_ts"]
    return state


def collect(args, state: dict) -> None:
    started = time.monotonic()
    auth = (args.user, args.password) if args.password else None
    now = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    done = set(state["windows_done"])

    for i in range(int(args.days * 24 / WINDOW_H)):
        end = now - timedelta(hours=i * WINDOW_H)
        key = end.strftime("%Y-%m-%dT%H")
        if key in done:
            continue
        at = urllib.parse.quote(end.strftime("%Y-%m-%dT%H:%M:%SZ"))
        site = urllib.parse.quote(SITE)
        got = 0
        loss_rows: list[dict] = []
        # Split by endpoint: baseline alone would otherwise blow the row cap
        for ep in ("local", "cloud", "real"):
            rows = fetch(args.base,
                         f"/measurements?site={site}&endpoint={ep}"
                         f"&hours={WINDOW_H}&limit=50000&at={at}", auth)
            if len(rows) >= 50000:
                print(f"  warning: {key}/{ep} hit the row cap", file=sys.stderr)
            absorb(rows, state)
            # The incident scan compares the gateway against the off-site
            # targets, so it needs all three endpoints together: scanning
            # each fetch separately could never match.
            loss_rows.extend(r for r in rows if r["workload"] == "baseline")
            got += len(rows)
        scan_incidents(loss_rows, state)
        state["windows_done"].append(key)
        save(state)   # cheap, and makes an interrupted run resume exactly
        print(f"{key}  {got:>6} rows", flush=True)
        if args.budget and time.monotonic() - started > args.budget:
            print("budget reached; run again to continue", flush=True)
            return


def report(state: dict) -> None:
    R = lambda r: (r.pct(50), r.pct(95))  # noqa: E731

    print("\n" + "=" * 68)
    print("DEPLOYMENT ANALYSIS")
    print("=" * 68)

    total = sum(state["counts"].values())
    print(f"\nWindow: {state['first_ts'][:16]} to {state['last_ts'][:16]} UTC")
    days = len(state["days"])
    print(f"Days covered: {days}   Records analysed: {total:,}")

    print("\n--- records by workload ---")
    for w, n in sorted(state["counts"].items(), key=lambda kv: -kv[1]):
        f = state["fails"].get(w, 0)
        print(f"  {w:<10} {n:>8,}   failed {f:>5} ({f / n * 100:.2f}%)")

    print("\n--- latency by destination class (ms) ---")
    print(f"  {'target':<34}{'p50':>8}{'p95':>8}{'p99':>8}{'samples':>10}")
    for tgt, res in sorted(state["rtt"].items(), key=lambda kv: kv[1].pct(50) or 0):
        print(f"  {tgt:<34}{res.pct(50):>8}{res.pct(95):>8}"
              f"{res.pct(99):>8}{res.n:>10,}")

    print("\n--- packet loss by destination class ---")
    for tgt, (lost, sent) in sorted(state["loss"].items()):
        if sent:
            print(f"  {tgt:<34}{lost / sent * 100:>7.3f}%   over {sent // 100:,} runs")

    if state["hop1"].n:
        p50, p95 = R(state["hop1"])
        print(f"\n--- WiFi link (hop 1) --- p50 {p50} ms   p95 {p95} ms"
              f"   n={state['hop1'].n:,}")

    if state["bloat"].n:
        b = state["bloat"]
        print(f"\n--- bufferbloat (added latency under load, ms) ---")
        print(f"  p50 {b.pct(50)}   p90 {b.pct(90)}   p95 {b.pct(95)}"
              f"   max {b.pct(100)}   n={b.n:,}")

    print("\n--- diurnal pattern (UTC hour) ---")
    print(f"  {'hh':<5}{'anchor p50':>12}{'anchor p95':>12}{'download':>11}"
          f"{'web real':>11}{'bloat p50':>11}{'app ok':>9}")
    for hh in [f"{h:02d}" for h in range(24)]:
        anchor = state["rtt_hour"].get(f"1.1.1.1|{hh}")
        dl, web = state["dl_hour"].get(hh), state["web_hour"].get(hh)
        bl = state["bloat_hour"].get(hh)
        ok, tot = state["app_hour"].get(hh, [0, 0])
        print(f"  {hh:<5}"
              f"{(anchor.pct(50) if anchor else '-'):>12}"
              f"{(anchor.pct(95) if anchor else '-'):>12}"
              f"{(dl.pct(50) if dl else '-'):>11}"
              f"{(web.pct(50) if web else '-'):>11}"
              f"{(bl.pct(50) if bl else '-'):>11}"
              f"{(f'{ok / tot * 100:.1f}%' if tot else '-'):>9}")

    ok = sum(v[0] for v in state["app_hour"].values())
    tot = sum(v[1] for v in state["app_hour"].values())
    if tot:
        print(f"\n--- availability --- {ok / tot * 100:.3f}% "
              f"({tot - ok} of {tot:,} user tasks failed)")

    inc = state["incidents"]
    print(f"\n--- connectivity incidents detected --- {len(inc)} minute(s) where "
          f"the gateway answered and nothing off-site did")
    if inc:
        runs, start, prev = [], inc[0], inc[0]
        for m in inc[1:]:
            a = datetime.fromisoformat(prev + ":00+00:00")
            b = datetime.fromisoformat(m + ":00+00:00")
            if (b - a).total_seconds() > 300:
                runs.append((start, prev))
                start = m
            prev = m
        runs.append((start, prev))
        for s, e in runs:
            mins = int((datetime.fromisoformat(e + ":00+00:00")
                        - datetime.fromisoformat(s + ":00+00:00")).total_seconds() / 60) + 1
            print(f"    {s} to {e} UTC  ({mins} min)")

    print("\n--- daily record counts (gaps show outages) ---")
    for d in sorted(state["days"]):
        n = state["days"][d]
        bar = "#" * int(n / 800)
        print(f"  {d}  {n:>7,}  {bar}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=BASE)
    ap.add_argument("--user", default="wifi")
    ap.add_argument("--password")
    ap.add_argument("--days", type=float, default=40)
    ap.add_argument("--report", action="store_true", help="skip fetching")
    ap.add_argument("--budget", type=float, default=0,
                    help="stop fetching after N seconds; rerun to continue")
    args = ap.parse_args()

    state = load()
    if not args.report:
        collect(args, state)
        save(state)
    if state["first_ts"] is None:
        print("no data in cache; run without --report first", file=sys.stderr)
        return 1
    report(state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

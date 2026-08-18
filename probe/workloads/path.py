"""Hop-by-hop path probing via mtr (per-hop latency decomposition).

Runs once per heavy cycle. Summary numbers plus one metric per hop go into
the time series; the full per-hop JSON is kept in `last_raw` for the caller
to ship to Blob Storage (Measurement.raw_ref).

Two things make the per-hop data useful rather than decorative:

* Hop 1 is the router, reached over the WiFi link, so `first_hop_rtt_ms`
  measures WiFi-link latency without needing a local reference server.
* The RTT increase from one hop to the next attributes latency to a
  specific segment, so `bottleneck_hop` says where the path degrades.

TCP mode (the default) sends TCP SYN instead of ICMP echo, which gets
through networks that block ping (eduroam and many public venues). The
intermediate hops still answer with ICMP time-exceeded, so a network that
blocks that too will only resolve the final hop.
"""
from __future__ import annotations

import ipaddress
import json
import re
import subprocess

import httpx

from ..config import settings

# Full JSON of the most recent run, for the raw payload path.
last_raw: bytes | None = None

MAX_HOPS = 20  # cap per-hop metrics so one record cannot balloon


def _cmd(target: str) -> list[str]:
    # -z: per-hop ASN lookup (Team Cymru); -b: keep IPs next to rDNS
    # names. Both feed the hop-identity labels.
    cmd = ["mtr", "--report", "--json", "-c", "3", "-z", "-b"]
    if settings.mtr_tcp:
        # TCP SYN to a port that is virtually never filtered.
        cmd += ["--tcp", "-P", str(settings.mtr_port)]
    cmd.append(target)
    return cmd


def _hop_metrics(hubs: list[dict]) -> dict[str, float]:
    """Per-hop RTT/loss, plus which segment really adds the most latency.

    Raw per-hop RTT is noisy in a way that misleads: routers deprioritise
    the ICMP time-exceeded replies that traceroute depends on, so a hop can
    report a large RTT while forwarding transit traffic perfectly. The
    giveaway is that the spike does not persist at later hops.

    Delay that is genuinely on the path must be paid by every hop beyond
    it, so we smooth with a suffix minimum (each hop's RTT is capped by the
    smallest RTT seen at or after it) before looking for the largest jump.
    That discards transient spikes and keeps real, persistent increases.
    """
    out: dict[str, float] = {}
    responsive: list[tuple[int, float]] = []

    for hub in hubs:
        idx = int(hub.get("count", 0) or 0)
        rtt = float(hub.get("Avg", 0.0) or 0.0)
        loss = float(hub.get("Loss%", 0.0) or 0.0)

        if 0 < idx <= MAX_HOPS:
            out[f"hop_{idx:02d}_rtt_ms"] = round(rtt, 2)
            if loss:
                out[f"hop_{idx:02d}_loss_pct"] = round(loss, 2)

        if rtt > 0:  # unresponsive hops report 0; they tell us nothing
            responsive.append((idx, rtt))

    if not responsive:
        return out

    # Suffix minimum: the persistent cost of reaching each hop.
    persistent = [0.0] * len(responsive)
    running = float("inf")
    for i in range(len(responsive) - 1, -1, -1):
        running = min(running, responsive[i][1])
        persistent[i] = running

    worst_delta, worst_idx = 0.0, 0
    prev = 0.0
    for (idx, _), value in zip(responsive, persistent):
        delta = value - prev
        if delta > worst_delta:
            worst_delta, worst_idx = delta, idx
        prev = value

    if worst_idx:
        out["bottleneck_hop"] = float(worst_idx)
        out["bottleneck_delta_ms"] = round(worst_delta, 2)
    return out


def _hop_ip(hub: dict) -> str | None:
    """Best-effort IP for a hub: the -b 'ip' field, or host if it is one."""
    for key in ("ip", "host"):
        v = hub.get(key)
        if v:
            try:
                ipaddress.ip_address(str(v))
                return str(v)
            except ValueError:
                continue
    return None


def _asn(hub: dict) -> int | None:
    """Numeric ASN from mtr -z ('AS15169' -> 15169), None if unknown."""
    m = re.match(r"AS(\d+)$", str(hub.get("ASN", "")))
    return int(m.group(1)) if m else None


# ASN -> operator name, e.g. 5607 -> "SKY-UK-LIMITED". An AS number tells a
# reader nothing; the operator's name is what makes a hop meaningful ("your
# ISP" becomes "Sky"). Looked up once per ASN and cached for the life of the
# process: a path crosses a handful of networks and they rarely change.
_ORG_CACHE: dict[int, str] = {}
ORG_LOOKUP_URL = "https://stat.ripe.net/data/as-overview/data.json"


def _org_name(asn: int) -> str | None:
    """Operator name for an ASN, or None if it cannot be resolved.

    Runs after mtr has finished so it cannot perturb the measurement, and
    fails quietly: a missing name only costs a nicer label.
    """
    if asn in _ORG_CACHE:
        return _ORG_CACHE[asn] or None
    name = ""
    try:
        r = httpx.get(ORG_LOOKUP_URL, params={"resource": f"AS{asn}"}, timeout=3.0)
        r.raise_for_status()
        holder = r.json()["data"]["holder"]  # e.g. "SKY-UK-LIMITED, GB"
        name = str(holder).split(",")[0].strip()
    except Exception:
        pass  # cached as "" so a dead lookup is not retried every run
    _ORG_CACHE[asn] = name
    return name or None


def _identity(hubs: list[dict]) -> dict[str, float | str]:
    """Name and role per hop, so the dashboard can say 'your ISP's edge
    router' instead of 'hop 4'.

    Roles come from the ASN sequence plus address type: private hops
    before the first public one are the home network; the first public
    ASN is the ISP (its first hop is the access, the rest its core);
    the final hop's ASN is the destination provider; anything else
    between is peering/transit. CGNAT (100.64/10) counts as ISP access.
    """
    out: dict[str, float | str] = {}

    responsive = [
        h for h in hubs
        if 0 < int(h.get("count", 0) or 0) <= MAX_HOPS
        and str(h.get("host", "???")) != "???"
    ]
    if not responsive:
        return out

    # The ISP is the first public ASN on the path; the destination is the
    # last hop's ASN.
    asns = [_asn(h) for h in responsive]
    isp_asn = next((a for a in asns if a is not None), None)
    dest_asn = asns[-1]

    seen_isp = False
    for hub, asn in zip(responsive, asns):
        idx = int(hub["count"])
        ip = _hop_ip(hub)
        priv = False
        cgnat = False
        if ip:
            addr = ipaddress.ip_address(ip)
            priv = addr.is_private and not addr in ipaddress.ip_network("100.64.0.0/10")
            cgnat = addr in ipaddress.ip_network("100.64.0.0/10")

        if idx == 1 or (priv and not seen_isp):
            role = "home"
        elif cgnat:
            role = "isp-access"
        elif priv:
            # RFC1918 inside the path, past the first public hop: a carrier
            # numbering its own backbone privately, not the home network.
            role = "isp-core"
            seen_isp = True
        elif asn is not None and asn == isp_asn:
            role = "isp-core" if seen_isp else "isp-access"
            seen_isp = True
        elif asn is not None and asn == dest_asn:
            role = "destination"
        elif asn is not None:
            role = "transit"
        else:
            role = "unknown"

        prefix = f"hop_{idx:02d}"
        out[f"{prefix}_host"] = str(hub.get("host"))
        out[f"{prefix}_role"] = role
        if asn is not None:
            out[f"{prefix}_asn"] = float(asn)
            org = _org_name(asn)
            if org:
                out[f"{prefix}_org"] = org

    if isp_asn is not None:
        out["isp_asn"] = float(isp_asn)
        if _org_name(isp_asn):
            out["isp_org"] = _org_name(isp_asn)  # cached, no second lookup
    if dest_asn is not None:
        out["dest_asn"] = float(dest_asn)
    return out


def run(target: str) -> dict[str, float | str]:
    global last_raw
    out = subprocess.run(
        _cmd(target), capture_output=True, text=True, timeout=60, check=True,
    ).stdout
    last_raw = out.encode()

    hubs = json.loads(out)["report"]["hubs"]
    if not hubs:
        raise RuntimeError("path workload: mtr returned no hops")

    dest = hubs[-1]  # final hop = destination
    metrics: dict[str, float | str] = {
        "hops": float(len(hubs)),
        "dest_rtt_ms": float(dest.get("Avg", 0.0) or 0.0),
        "dest_loss_pct": float(dest.get("Loss%", 0.0) or 0.0),
        "worst_rtt_ms": max(float(h.get("Avg", 0.0) or 0.0) for h in hubs),
    }

    # Hop 1 is the local router: this is the WiFi link's own latency.
    first = next((h for h in hubs if int(h.get("count", 0) or 0) == 1), None)
    if first and float(first.get("Avg", 0.0) or 0.0) > 0:
        metrics["first_hop_rtt_ms"] = round(float(first["Avg"]), 2)

    metrics.update(_hop_metrics(hubs))
    metrics.update(_identity(hubs))
    return metrics

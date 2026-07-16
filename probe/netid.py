"""Egress network fingerprint.

The public IP is a strong network identifier but is personal/locating, so
per the ethics stance we never store it raw: only a truncated SHA-256.
Resolved at most once per TTL and cached, so a heavy cycle does one lookup.
"""
from __future__ import annotations

import hashlib
import time

import httpx

_TTL_S = 600.0                 # re-resolve at most every 10 minutes
_cache: dict[str, object] = {"hash": None, "at": 0.0}


def net_hash() -> str | None:
    """Return a stable, non-reversible fingerprint of the current egress
    network (truncated hash of the public IP), or None if unavailable."""
    now = time.monotonic()
    if _cache["hash"] is not None and now - float(_cache["at"]) < _TTL_S:
        return _cache["hash"]  # type: ignore[return-value]
    try:
        ip = httpx.get("https://api.ipify.org", timeout=5.0).text.strip()
        h = hashlib.sha256(ip.encode()).hexdigest()[:12]
    except Exception:
        return _cache["hash"]  # type: ignore[return-value]  # keep last good value
    _cache["hash"], _cache["at"] = h, now
    return h

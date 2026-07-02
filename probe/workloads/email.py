"""Email workload: IMAP fetch time against a controlled mailbox.

Times connect (TLS handshake included), login, and fetching the most
recent message. Credentials come from PROBE_REAL_IMAP_USER / _PASS in the
environment, never committed.
"""
from __future__ import annotations

import imaplib
import time

from ..config import settings


def run(target: str) -> dict[str, float]:
    """`target` is the IMAP hostname (implicit TLS, port 993)."""
    if not settings.real_imap_user or not settings.real_imap_pass:
        raise RuntimeError("email workload: PROBE_REAL_IMAP_USER/_PASS not set")

    t0 = time.perf_counter()
    conn = imaplib.IMAP4_SSL(target, 993, timeout=30)
    connect_ms = (time.perf_counter() - t0) * 1000
    try:
        t1 = time.perf_counter()
        conn.login(settings.real_imap_user, settings.real_imap_pass)
        login_ms = (time.perf_counter() - t1) * 1000

        t2 = time.perf_counter()
        conn.select("INBOX", readonly=True)
        _, data = conn.search(None, "ALL")
        ids = data[0].split()
        if not ids:
            raise RuntimeError("email workload: INBOX is empty")
        conn.fetch(ids[-1], "(RFC822)")  # newest message, full body
        fetch_ms = (time.perf_counter() - t2) * 1000
    finally:
        try:
            conn.logout()
        except imaplib.IMAP4.error:
            pass

    return {
        "connect_ms": round(connect_ms, 2),
        "login_ms": round(login_ms, 2),
        "fetch_ms": round(fetch_ms, 2),
    }

"""Email workload: IMAP fetch time against a controlled mailbox."""
from __future__ import annotations


def run(target: str) -> dict[str, float]:
    # TODO: imaplib login to `target`, SELECT INBOX, FETCH a fixed message,
    # time the fetch, LOGOUT. Return fetch_ms. Credentials via env, never
    # committed.
    raise NotImplementedError("email workload: implement with imaplib")

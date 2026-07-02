"""Drains the local buffer to the cloud backend over HTTPS with retry."""
from __future__ import annotations

import httpx

from .buffer import Buffer
from .config import settings


def flush(buffer: Buffer) -> int:
    """Upload pending records. Returns how many were accepted."""
    headers = {"Authorization": f"Bearer {settings.ingest_token}"}
    sent = 0
    with httpx.Client(timeout=15.0) as client:
        for rid, record in buffer.take():
            try:
                resp = client.post(settings.ingest_url, json=record, headers=headers)
                resp.raise_for_status()
            except httpx.HTTPError:
                break  # backend unreachable; keep the record, try next cycle
            buffer.ack([rid])
            sent += 1
    return sent

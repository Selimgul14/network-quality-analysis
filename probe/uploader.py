"""Drains the local buffer to the cloud backend over HTTPS with retry."""
from __future__ import annotations

import httpx

from .buffer import Buffer
from .config import settings


def _ship_raw(client: httpx.Client, record: dict, headers: dict) -> None:
    """Upload the attached raw payload first; clear raw_ref if Blob is off."""
    raw = record.pop("_raw")
    resp = client.post(
        f"{settings.ingest_url}/raw",
        params={"key": record["raw_ref"]},
        content=raw.encode(),
        headers=headers,
    )
    resp.raise_for_status()
    if resp.json().get("key") is None:  # Blob not configured on the backend
        record["raw_ref"] = None


def flush(buffer: Buffer) -> int:
    """Upload pending records. Returns how many were accepted."""
    headers = {"Authorization": f"Bearer {settings.ingest_token}"}
    sent = 0
    with httpx.Client(timeout=15.0) as client:
        for rid, record in buffer.take():
            try:
                if "_raw" in record:
                    _ship_raw(client, record, headers)
                resp = client.post(settings.ingest_url, json=record, headers=headers)
                resp.raise_for_status()
            except httpx.HTTPError:
                break  # backend unreachable; keep the record, try next cycle
            buffer.ack([rid])
            sent += 1
    return sent

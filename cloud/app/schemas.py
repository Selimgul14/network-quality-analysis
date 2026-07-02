"""Pydantic models mirroring contracts/measurement.schema.json.

Keep these in sync with the JSON schema (it is the source of truth).
"""
from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel

Workload = Literal["web", "video", "email", "download", "baseline", "path"]
EndpointName = Literal["local", "cloud", "real"]


class Context(BaseModel):
    wifi_channel: int | None = None
    rssi_dbm: float | None = None
    cpu_temp_c: float | None = None


class Measurement(BaseModel):
    ts: datetime
    probe_id: str
    run_id: str
    workload: Workload
    endpoint: EndpointName
    target: str
    ok: bool
    error: str | None = None
    metrics: dict[str, float] = {}
    context: Context | None = None
    raw_ref: str | None = None
    net_hash: str | None = None

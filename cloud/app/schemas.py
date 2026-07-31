"""Pydantic models mirroring contracts/measurement.schema.json.

Keep these in sync with the JSON schema (it is the source of truth).
"""
from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel

Workload = Literal["web", "video", "email", "download", "baseline", "path", "loadlat"]
EndpointName = Literal["local", "cloud", "real"]


class Context(BaseModel):
    wifi_channel: int | None = None
    rssi_dbm: float | None = None
    cpu_temp_c: float | None = None
    ssid: str | None = None
    bssid: str | None = None


class Measurement(BaseModel):
    ts: datetime
    probe_id: str
    site: str | None = None
    run_id: str
    workload: Workload
    endpoint: EndpointName
    target: str
    ok: bool
    error: str | None = None
    # numeric results, plus string identity labels (e.g. hop_NN_host/_role)
    metrics: dict[str, float | str] = {}
    context: Context | None = None
    raw_ref: str | None = None
    net_hash: str | None = None

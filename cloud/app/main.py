"""API surface: POST /ingest, GET /measurements, GET /health.

Auth is a static bearer token on /ingest (matches the probe). The query
endpoints feed both the Grafana board and the custom summary page.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from fastapi import Depends, FastAPI, Header, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from cloud.db import models
from cloud.db.session import get_db

from .config import settings
from .schemas import Measurement

app = FastAPI(title="Remote WiFi Performance Tool API")


def require_token(authorization: str = Header(default="")) -> None:
    if authorization != f"Bearer {settings.ingest_token}":
        raise HTTPException(status_code=401, detail="bad token")


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/ingest", status_code=201, dependencies=[Depends(require_token)])
def ingest(m: Measurement, db: Session = Depends(get_db)) -> dict[str, str]:
    # Raw payloads (m.raw_ref) are uploaded to Blob by the probe separately;
    # only the key travels in the record.
    row = models.Measurement(
        ts=m.ts,
        probe_id=m.probe_id,
        run_id=m.run_id,
        workload=m.workload,
        endpoint=m.endpoint,
        target=m.target,
        ok=m.ok,
        error=m.error,
        metrics=m.metrics,
        context=m.context.model_dump() if m.context else None,
        raw_ref=m.raw_ref,
        net_hash=m.net_hash,
    )
    db.add(row)
    try:
        db.commit()
    except IntegrityError:
        # Duplicate PK: the probe retried an upload that already landed.
        # Idempotent success so the buffer can safely mark it sent.
        db.rollback()
        return {"status": "duplicate", "run_id": m.run_id}
    return {"status": "accepted", "run_id": m.run_id}


@app.get("/measurements")
def measurements(
    workload: str | None = None,
    endpoint: str | None = None,
    hours: int = Query(default=24, ge=1, le=336),
    limit: int = Query(default=5000, ge=1, le=50000),
    db: Session = Depends(get_db),
) -> list[dict]:
    since = datetime.now(timezone.utc) - timedelta(hours=hours)
    q = select(models.Measurement).where(models.Measurement.ts >= since)
    if workload:
        q = q.where(models.Measurement.workload == workload)
    if endpoint:
        q = q.where(models.Measurement.endpoint == endpoint)
    q = q.order_by(models.Measurement.ts.desc()).limit(limit)
    rows = db.scalars(q).all()
    return [
        {
            "ts": r.ts.isoformat(),
            "probe_id": r.probe_id,
            "run_id": r.run_id,
            "workload": r.workload,
            "endpoint": r.endpoint,
            "target": r.target,
            "ok": r.ok,
            "error": r.error,
            "metrics": r.metrics,
            "context": r.context,
            "raw_ref": r.raw_ref,
        }
        for r in rows
    ]

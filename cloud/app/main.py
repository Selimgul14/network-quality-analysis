"""API surface: POST /ingest, GET /measurements, GET /health.

Auth is a static bearer token on /ingest (matches the probe). The query
endpoints feed both the Grafana board and the custom summary page.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import secrets

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import FileResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from cloud.db import models
from cloud.db.session import get_db

from .config import settings
from cloud.blob import upload_raw

from .schemas import Measurement
from .summary import compute_summary

app = FastAPI(title="Remote WiFi Performance Tool API")

# dashboard/summary/index.html, copied into the image next to cloud/
SUMMARY_PAGE = Path(__file__).resolve().parents[2] / "dashboard" / "summary" / "index.html"
# The simple public view: one score, one sentence, three lights.
OVERVIEW_PAGE = SUMMARY_PAGE.parent / "overview.html"


def require_token(authorization: str = Header(default="")) -> None:
    if authorization != f"Bearer {settings.ingest_token}":
        raise HTTPException(status_code=401, detail="bad token")


_basic = HTTPBasic(auto_error=False)


def require_dash_auth(
    credentials: HTTPBasicCredentials | None = Depends(_basic),
) -> None:
    """HTTP Basic on the dashboard endpoints. Disabled while API_DASH_PASS
    is unset (local dev); the browser prompts for credentials otherwise."""
    if not settings.dash_pass:
        return
    ok = credentials is not None and (
        secrets.compare_digest(credentials.username, settings.dash_user)
        and secrets.compare_digest(credentials.password, settings.dash_pass)
    )
    if not ok:
        raise HTTPException(
            status_code=401,
            detail="authentication required",
            headers={"WWW-Authenticate": "Basic"},
        )


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
        site=m.site,
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


@app.post("/ingest/raw", status_code=201, dependencies=[Depends(require_token)])
async def ingest_raw(key: str, request: Request) -> dict:
    """Store a large raw payload (e.g. full mtr JSON) in Blob Storage.

    Returns {"key": null} when Blob is not configured (local dev): the
    probe then sends its record with raw_ref unset.
    """
    body = await request.body()
    return {"key": upload_raw(key, body)}


def _rows_since(db: Session, hours: int, site: str | None = None) -> list[models.Measurement]:
    since = datetime.now(timezone.utc) - timedelta(hours=hours)
    q = select(models.Measurement).where(models.Measurement.ts >= since)
    if site:
        q = q.where(models.Measurement.site == site)
    return list(db.scalars(q))


@app.get("/summary", dependencies=[Depends(require_dash_auth)])
def summary(
    hours: int = Query(default=24, ge=1, le=336),
    site: str | None = None,
    db: Session = Depends(get_db),
) -> dict:
    """End-user summary: per-workload status + where-is-the-slowness.

    Pass `site` to scope the summary to one deployment (network/location).
    """
    rows = [
        {"workload": r.workload, "endpoint": r.endpoint, "ok": r.ok, "metrics": r.metrics}
        for r in _rows_since(db, hours, site)
    ]
    return compute_summary(rows, hours)


@app.get("/sites", dependencies=[Depends(require_dash_auth)])
def sites(db: Session = Depends(get_db)) -> list[dict]:
    """Distinct deployment sites with a record count and last-seen time,
    for the dashboard's site picker."""
    rows = db.execute(
        select(models.Measurement.site, func.count(), func.max(models.Measurement.ts))
        .group_by(models.Measurement.site)
        .order_by(func.max(models.Measurement.ts).desc())
    ).all()
    return [
        {"site": site or "unlabelled", "count": n, "last_seen": ts.isoformat() if ts else None}
        for site, n, ts in rows
    ]


@app.get("/", dependencies=[Depends(require_dash_auth)])
def summary_page() -> FileResponse:
    return FileResponse(SUMMARY_PAGE, media_type="text/html")


@app.get("/overview", dependencies=[Depends(require_dash_auth)])
def overview_page() -> FileResponse:
    """At-a-glance health for end users; the detailed view stays at /."""
    return FileResponse(OVERVIEW_PAGE, media_type="text/html")


@app.get("/measurements", dependencies=[Depends(require_dash_auth)])
def measurements(
    workload: str | None = None,
    endpoint: str | None = None,
    site: str | None = None,
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
    if site:
        q = q.where(models.Measurement.site == site)
    q = q.order_by(models.Measurement.ts.desc()).limit(limit)
    rows = db.scalars(q).all()
    return [
        {
            "ts": r.ts.isoformat(),
            "probe_id": r.probe_id,
            "site": r.site,
            "net_hash": r.net_hash,
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

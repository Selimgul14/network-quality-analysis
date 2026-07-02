"""API surface: POST /ingest, GET /measurements, GET /health.

Auth is a static bearer token on /ingest (matches the probe). The query
endpoints feed both the Grafana board and the custom summary page.
"""
from __future__ import annotations

from fastapi import Depends, FastAPI, Header, HTTPException, Query

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
def ingest(m: Measurement) -> dict[str, str]:
    # TODO: persist via db.models into the Timescale hypertable; if
    # m.raw_ref is set, the probe uploads the payload separately to Blob.
    return {"status": "accepted", "run_id": m.run_id}


@app.get("/measurements")
def measurements(
    workload: str | None = None,
    endpoint: str | None = None,
    hours: int = Query(default=24, ge=1, le=336),
) -> list[dict]:
    # TODO: query the hypertable filtered by workload/endpoint over the
    # last `hours` and return rows for the dashboard.
    return []

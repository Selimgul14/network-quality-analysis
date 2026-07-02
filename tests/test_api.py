"""Ingest + query round-trip against an in-memory SQLite DB.

The Timescale hypertable conversion is Postgres-only and covered by the
compose stack; here we test the API logic itself.
"""
from __future__ import annotations

from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from cloud.app.config import settings
from cloud.app.main import app
from cloud.db import models
from cloud.db.session import get_db

AUTH = {"Authorization": f"Bearer {settings.ingest_token}"}


@pytest.fixture()
def client():
    # Shared in-memory SQLite so all sessions see the same tables.
    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool
    )
    models.Base.metadata.create_all(engine)
    TestSession = sessionmaker(bind=engine, expire_on_commit=False)

    def override_get_db():
        db = TestSession()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
    yield TestClient(app)
    app.dependency_overrides.clear()


def sample_record() -> dict:
    return {
        "ts": datetime.now(timezone.utc).isoformat(),
        "probe_id": "probe-01",
        "run_id": "run-123",
        "workload": "download",
        "endpoint": "local",
        "target": "http://reference.local/files/testfile.bin",
        "ok": True,
        "metrics": {"throughput_mbps": 94.2},
        "context": {"wifi_channel": 36, "rssi_dbm": -52.0, "cpu_temp_c": 48.1},
    }


def test_ingest_requires_token(client):
    assert client.post("/ingest", json=sample_record()).status_code == 401


def test_ingest_and_query_roundtrip(client):
    r = client.post("/ingest", json=sample_record(), headers=AUTH)
    assert r.status_code == 201
    assert r.json()["status"] == "accepted"

    rows = client.get("/measurements", params={"workload": "download"}).json()
    assert len(rows) == 1
    assert rows[0]["metrics"]["throughput_mbps"] == 94.2
    assert rows[0]["endpoint"] == "local"

    # Endpoint filter that matches nothing.
    assert client.get("/measurements", params={"endpoint": "cloud"}).json() == []


def test_duplicate_upload_is_idempotent(client):
    rec = sample_record()
    assert client.post("/ingest", json=rec, headers=AUTH).status_code == 201
    r = client.post("/ingest", json=rec, headers=AUTH)
    assert r.status_code == 201
    assert r.json()["status"] == "duplicate"
    assert len(client.get("/measurements").json()) == 1


def test_ingest_rejects_bad_workload(client):
    rec = sample_record()
    rec["workload"] = "bittorrent"
    assert client.post("/ingest", json=rec, headers=AUTH).status_code == 422

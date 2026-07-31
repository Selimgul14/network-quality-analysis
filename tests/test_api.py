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


def test_ingest_raw_without_blob_returns_null_key(client):
    r = client.post(
        "/ingest/raw", params={"key": "probe-01/run-1-path.json"},
        content=b'{"report": {}}', headers=AUTH,
    )
    assert r.status_code == 201
    assert r.json()["key"] is None  # Blob not configured in tests


def test_ingest_rejects_bad_workload(client):
    rec = sample_record()
    rec["workload"] = "bittorrent"
    assert client.post("/ingest", json=rec, headers=AUTH).status_code == 422


def test_dash_auth_when_password_set(client, monkeypatch):
    monkeypatch.setattr(settings, "dash_pass", "s3cret")
    assert client.get("/measurements").status_code == 401
    assert client.get("/summary", auth=("wifi", "wrong")).status_code == 401
    assert client.get("/summary", auth=("wifi", "s3cret")).status_code == 200
    assert client.get("/measurements", auth=("wifi", "s3cret")).status_code == 200


def test_overview_page_served(client):
    r = client.get("/overview")
    assert r.status_code == 200
    assert "How is the WiFi doing?" in r.text


def test_ingest_accepts_string_identity_metrics(client):
    """Hop identity labels (host/role) are strings inside metrics."""
    rec = sample_record()
    rec["workload"] = "path"
    rec["metrics"] = {
        "hops": 6.0, "hop_04_rtt_ms": 14.8,
        "hop_04_host": "core.isp.net", "hop_04_role": "isp-core",
        "hop_04_asn": 5089.0,
    }
    assert client.post("/ingest", json=rec, headers=AUTH).status_code == 201
    rows = client.get("/measurements", params={"workload": "path"}).json()
    assert rows[0]["metrics"]["hop_04_role"] == "isp-core"

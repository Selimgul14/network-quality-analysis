# src: Remote WiFi Performance Tool

Implementation for the COMP702 MSc project. See `../CLAUDE.md` (Build plan
section) for the full task breakdown and definition of done per component.

## Layout

- `contracts/` measurement JSON schema, shared by all components (source of truth)
- `probe/` Raspberry Pi measurement client (workloads, scheduler, buffer, uploader)
- `reference/` nginx reference content (same image for local server and cloud endpoint)
- `cloud/` FastAPI backend (ingest + query API, Timescale models, Blob upload)
- `dashboard/` Grafana provisioning + custom end-user summary page
- `infra/` Bicep templates for the Azure resources
- `tests/` unit + integration tests

## Quick start (local dev, no Pi or Azure)

```
cp .env.example .env
pip install -e ".[dev]"
playwright install chromium          # for the web workload
docker compose up                    # reference + timescale + api + grafana
pytest                               # run the tests
```

Run the probe against the local stack:

```
python -m probe.main
```

## Status

Done: data contract, reference content (video + 25 MiB file generated in
the image build), backend persistence (Alembic hypertable migration, ingest,
query endpoint, Blob upload), all six workloads (web, video, email,
download, baseline, path), WiFi/thermal context capture, tests.

Remaining: Grafana dashboard JSON + summary-page attribution logic (build
step 6), Azure provisioning (step 3), raw-payload upload wiring in the
scheduler, then integration/fault injection (step 7).

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

Build steps 1-6 complete and deployed (7 July 2026). The full pipeline is
live: probe (dev Mac, Pi pending) -> Azure API -> Timescale -> summary
page with three-way attribution + Grafana, all cloud-hosted (see
infra/README.md for hostnames). Dashboard endpoints sit behind HTTP Basic
auth; raw mtr JSON ships to Blob via /ingest/raw.

Remaining: Pi bring-up (hardware/pi-setup.md), threshold tuning in
cloud/app/summary.py after a 24 h soak, email mailbox + real video URL
config, credential rotation, fault injection (step 7), then the pilot and
site deployment (step 8).

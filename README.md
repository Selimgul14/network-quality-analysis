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

Scaffold. The download workload and the baseline probe are implemented;
web/video/email/path workloads, backend persistence, Blob upload and the
summary-page attribution logic are stubs marked with `TODO` /
`NotImplementedError`. Fill them in following the build order in CLAUDE.md.

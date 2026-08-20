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

## Query API

All dashboard endpoints sit behind HTTP Basic auth (user `wifi`).

| Endpoint | Purpose |
|---|---|
| `POST /ingest` | one measurement record, bearer token, validated against the contract |
| `POST /ingest/raw` | large payload (full mtr JSON) to Blob, returns the key |
| `GET /summary` | verdict, health score, segment attribution |
| `GET /measurements` | raw records, filterable by workload/endpoint/site |
| `GET /sites` | deployment labels with counts and last-seen |
| `GET /` , `GET /overview` | detailed and simple dashboards |
| `GET /health` | liveness, no auth |

`/summary` and `/measurements` share three parameters:

- `hours` (1-336): length of the trailing window.
- `site`: scope to one deployment label.
- `at`: ISO 8601 instant. The window *ends* here instead of at now, so a
  past incident can be inspected after it is over. The verdict is a
  median over a trailing window, which means a finished outage is
  invisible from the present: `?at=2026-08-18T23:45Z&hours=1` replays
  the uplink failure of 18 August. `/summary` then returns `as_of` and
  `historic: true`, and both pages show a banner saying so.

### What `/summary` reports

`overall` is one of `good`, `slow`, `poor`, `unstable`, `down`,
`no_data`. `unstable` means some attempted tasks failed, `down` means
all of them did.

`health` carries `score`, `quality`, `availability` and the per-component
breakdown. `quality` is the MOS-anchored weighted mean over the workloads
that produced numbers; `availability` is the share of application-level
tasks (web, video, email, download) that completed at all; and
`score = quality x availability`. The split matters because a median can
only describe runs that produced a number, so without availability a
window straddling an outage scored "excellent" while its own segments
read "not responding". Baseline pings are excluded from availability:
they succeed while reporting 100% loss, which would understate an outage.

## Status

Build steps 1-6 complete, deployed and running continuously at the halls
site since late July 2026: Pi 4 `pi-maple-01` -> Azure API -> Timescale
-> summary page, overview page and Grafana, all cloud-hosted (see
infra/README.md for hostnames and the redeploy path). Raw mtr JSON ships
to Blob via `/ingest/raw`.

Remaining: fault injection (step 7), threshold tuning after a soak,
credential rotation, and probe liveness monitoring (a crash loop went
unnoticed for 24 h on 17-18 August; see ../hardware/pi-setup.md).

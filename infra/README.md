# Azure provisioning

One command up, one command down (build step 3). Needs the Azure CLI and a
subscription (student credit). All tiers are the cheapest that work:
B1ms Postgres, B1 App Service plan, LRS storage; roughly £25-30/month, so
stand it up for the deployment window and tear it down after.

## 1. Push the two images

App Service pulls from a registry. Docker Hub free tier is enough:

```
docker login
docker build -t <user>/wifi-ref:latest reference/
docker build -t <user>/wifi-api:latest -f cloud/Dockerfile .
docker build -t <user>/wifi-grafana:latest dashboard/grafana/
docker push <user>/wifi-ref:latest
docker push <user>/wifi-api:latest
docker push <user>/wifi-grafana:latest
```

(Images must be linux/amd64: on Apple Silicon add `--platform linux/amd64`.)

## 2. Deploy

```
az group create -n comp702-rg -l uksouth
az deployment group create -g comp702-rg -f infra/main.bicep \
  -p adminPassword=<strong-pw> ingestToken=<random-token> dashPassword=<dash-pw> \
     registry=docker.io/<user> clientIp=<your-home-ip>
```

Outputs give the api / ref hostnames and the Postgres FQDN. The api
container runs the Alembic migration on start, which creates the
Timescale hypertable (the extension is preloaded by the template).

## 3. Point the probe at it

In the probe's `.env`:

```
PROBE_INGEST_URL=https://comp702-api.azurewebsites.net/ingest
PROBE_INGEST_TOKEN=<the same token>
PROBE_CLOUD_BASE=https://comp702-ref.azurewebsites.net
```

## 3b. Redeploy after a code change

The stack is already provisioned, so shipping a change means rebuilding
the affected image and making App Service pull it again. Bicep is only
needed when infrastructure changes.

Which image holds what:

| Changed | Image | Rebuild |
|---|---|---|
| `cloud/`, `dashboard/summary/`, `contracts/` | `wifi-api` | yes |
| `dashboard/grafana/` | `wifi-grafana` | yes |
| `reference/content/`, `reference/Dockerfile` | `wifi-ref` | yes |
| `probe/` | none | Pi pulls from git |

One command per image: `./infra/deploy.sh api grafana` (or `all`). It
detects the Docker Hub namespace from what is deployed, builds, pushes,
forces the pull and restarts. The equivalent by hand:

```
# build + push (add --platform linux/amd64 on Apple Silicon)
docker build -t <user>/wifi-api:latest -f cloud/Dockerfile .
docker push <user>/wifi-api:latest

# App Service caches the image, so force a fresh pull, then restart
az webapp config container set -g comp702-rg -n comp702-api \
  --docker-custom-image-name docker.io/<user>/wifi-api:latest
az webapp restart -g comp702-rg -n comp702-api
```

Same three commands for `comp702-grafana` / `wifi-grafana` and
`comp702-ref` / `wifi-ref`. Give App Service a minute, then check:

```
curl -s https://comp702-api.azurewebsites.net/health
curl -s -u wifi:<dash-pw> https://comp702-api.azurewebsites.net/summary | head -c 300
```

**Architecture gotcha:** a build on Apple Silicon produces an arm64
image, which App Service pulls and then fails to start with "Pull image
... failed with unexpected exception". The name is fine in that case, the
platform is not. Always `--platform linux/amd64` (deploy.sh does), and
verify before restarting:

```
docker manifest inspect <user>/wifi-api:latest | grep architecture   # want amd64
```

Nothing on Azure needs changing to recover: rebuild with the flag, push,
and `az webapp restart`.

**zsh gotcha:** always quote or brace the image name.
`--docker-custom-image-name docker.io/$DH/wifi-$app:latest` in zsh parses
`$app:l` as the lowercase modifier and produces `wifi-apiatest`, which
App Service accepts and then fails to pull ("image was not found"). Use
`"docker.io/$DH/wifi-${app}:latest"`. Recover with a corrected
`container set` plus `az webapp restart`; no rebuild is needed because
the pushed images were tagged correctly.

**Ordering rule:** deploy the backend before the probe pulls a change
that alters the record shape. The ingest endpoint validates against the
contract, so a probe running ahead of its backend gets 422s and the
records are lost (the buffer retries, but only for as long as it holds).

Grafana on Azure is stateless: the provisioned JSON in git is the source
of truth, so a redeploy replaces the panels wholesale. Export any UI
edits back into `dashboard/grafana/dashboards/` first or they are gone.

## 4. Tear down

```
az group delete -n comp702-rg
```

## Notes

- Postgres restarts once after deploy (shared_preload_libraries); the api
  container's migration retry loop rides that out.
- `clientIp` opens Postgres to your home IP only, for running the local
  Grafana against the cloud DB (`DB_SSLMODE=require`).
- Dual-region reference (stretch goal): redeploy `wifi-ref` in a second
  resource group in another region; nothing else changes.

## Deployed state (7 July 2026)

Live in `comp702-rg`, all resources in `norwayeast`: the student
subscription's region policy only allows norwayeast, francecentral,
germanywestcentral, switzerlandnorth and italynorth, and App Service
capacity (France) / Postgres offer restrictions (Germany) ruled others
out. Docker Hub namespace `selimgul14`. Hostnames: `comp702-api.azurewebsites.net` (summary page at `/`,
HTTP Basic, user `wifi`), `comp702-ref.azurewebsites.net`,
`comp702-grafana.azurewebsites.net` (Grafana login, user `wifi`),
`comp702-pg.postgres.database.azure.com`.

Notes: the "cloud" endpoint is Oslo, not the UK (dissertation method
detail). `shared_preload_libraries` needed a manual Postgres restart
before the Timescale migration could run: if the api container loops on
startup after a fresh deploy, restart pg then the api webapp. Azure
Grafana is stateless (panels live in git; export JSON back into
dashboard/grafana/dashboards/ after UI edits). The `allow-client`
firewall rule (home IP) is only for direct psql/local Grafana; the
hosted dashboards work from anywhere.

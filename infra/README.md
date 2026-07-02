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
docker push <user>/wifi-ref:latest
docker push <user>/wifi-api:latest
```

(Images must be linux/amd64: on Apple Silicon add `--platform linux/amd64`.)

## 2. Deploy

```
az group create -n comp702-rg -l uksouth
az deployment group create -g comp702-rg -f infra/main.bicep \
  -p adminPassword=<strong-pw> ingestToken=<random-token> \
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

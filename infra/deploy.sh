#!/usr/bin/env bash
# NOTE: always brace variables before a colon (${t}:latest). In zsh, "$t:l"
# is the lowercase modifier, so "wifi-$t:latest" silently becomes
# "wifi-apiatest" and App Service then fails to pull a nonexistent image.
# Rebuild and redeploy the cloud images onto the already-provisioned stack.
#
#   ./infra/deploy.sh api            # just the backend + dashboard pages
#   ./infra/deploy.sh grafana        # just the engineering board
#   ./infra/deploy.sh api grafana    # both
#   ./infra/deploy.sh all            # api, grafana and the reference server
#
# Run from the src/ directory. Needs docker login and az login.
# Infrastructure changes still go through Bicep (see README.md).
set -euo pipefail

RG=comp702-rg
DH=${DH:-}                       # Docker Hub namespace; discovered if unset
PLATFORM=${PLATFORM:-linux/amd64} # App Service will not run arm64

[[ $# -gt 0 ]] || { echo "usage: $0 [api|grafana|ref|all]..."; exit 1; }
[[ -f cloud/Dockerfile ]] || { echo "run me from src/"; exit 1; }

if [[ -z "$DH" ]]; then
  # Read the namespace off whatever is deployed, e.g. docker.io/foo/wifi-api:latest
  img=$(az webapp config container show -g "$RG" -n comp702-api \
        --query "[?name=='DOCKER_CUSTOM_IMAGE_NAME'].value" -o tsv 2>/dev/null || true)
  DH=$(sed -E 's#^docker\.io/##; s#/wifi-.*$##' <<<"$img")
  [[ -n "$DH" ]] || { echo "could not detect Docker Hub user; set DH=<user>"; exit 1; }
  echo "using Docker Hub namespace: $DH"
fi

# image name -> (build context, dockerfile) and the web app it feeds
build_one() {
  case "$1" in
    api)     docker build --platform "$PLATFORM" -t "$DH/wifi-api:latest" -f cloud/Dockerfile . ;;
    grafana) docker build --platform "$PLATFORM" -t "$DH/wifi-grafana:latest" dashboard/grafana/ ;;
    ref)     docker build --platform "$PLATFORM" -t "$DH/wifi-ref:latest" reference/ ;;
    *) echo "unknown target: $1"; exit 1 ;;
  esac
}

targets=()
for t in "$@"; do [[ $t == all ]] && targets+=(api grafana ref) || targets+=("$t"); done

for t in "${targets[@]}"; do
  echo "==> building wifi-$t"
  build_one "$t"
  docker push "${DH}/wifi-${t}:latest"
  # App Service is amd64: an arm64 image pulls fine then dies on start,
  # so refuse to deploy one rather than leave the site erroring.
  arch=$(docker manifest inspect "${DH}/wifi-${t}:latest" 2>/dev/null \
         | grep -o '"architecture": *"[^"]*"' | grep -v unknown | head -1)
  case "$arch" in
    *amd64*) : ;;
    "")      echo "warning: could not read the manifest architecture" ;;
    *)       echo "ERROR: ${DH}/wifi-${t}:latest is $arch, App Service needs amd64."
             echo "       rebuild with --platform linux/amd64"; exit 1 ;;
  esac
  # App Service caches the image, so re-set the tag to force a fresh pull
  az webapp config container set -g "$RG" -n "comp702-$t" \
    --docker-custom-image-name "docker.io/${DH}/wifi-${t}:latest" >/dev/null
  az webapp restart -g "$RG" -n "comp702-$t"
  echo "==> comp702-$t restarting"
done

echo
echo "give it a minute, then check:"
echo "  curl -s https://comp702-api.azurewebsites.net/health"
echo "  curl -s -u wifi:<pw> https://comp702-api.azurewebsites.net/ | grep -c tidyOrg"

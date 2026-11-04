#!/usr/bin/env bash
# Build all images locally and load them into both kind clusters with the same
# GHCR names/tags the overlays use. For offline rehearsal, or before the GHCR
# release workflow has run. Usage: scripts/build-local.sh [tag]
source "$(dirname "$0")/lib.sh"
need docker kind
TAG=${1:-$BASE_TAG}
R=ghcr.io/${IMAGE_OWNER}
for app in payment inventory loadgen; do
  say "build $R/scn-$app:$TAG"
  docker build -q --build-arg APP=$app -t "$R/scn-$app:$TAG" "$ROOT/apps" >/dev/null
  for c in staging prod; do kind load docker-image "$R/scn-$app:$TAG" --name "$c" >/dev/null; done
done
say "build $R/scn-ai-sre:$TAG"
docker build -q -t "$R/scn-ai-sre:$TAG" "$ROOT/ai-sre" >/dev/null
kind load docker-image "$R/scn-ai-sre:$TAG" --name staging >/dev/null
ok "images loaded"

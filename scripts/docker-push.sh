#!/usr/bin/env sh
# Build and push the 9Router images to Docker Hub.
#
# Usage:
#   DOCKERHUB_USER=herlangga72 scripts/docker-push.sh [TAG]
#
# TAG defaults to `latest`. Also pushes the all-in-one Headroom variant as
# `<user>/9router:<tag>-headroom`.
#
# Requires: docker logged in (`docker login`).
set -eu

USER="${DOCKERHUB_USER:-herlangga72}"
TAG="${1:-latest}"
REPO="${USER}/9router"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"

echo "==> Building ${REPO}:${TAG} (${PLATFORMS})"
docker buildx build \
  --platform "${PLATFORMS}" \
  --target runner \
  -t "${REPO}:${TAG}" \
  -t "${REPO}:latest" \
  --push .

echo "==> Building ${REPO}:${TAG}-headroom (${PLATFORMS})"
docker buildx build \
  --platform "${PLATFORMS}" \
  --target headroom \
  -t "${REPO}:${TAG}-headroom" \
  -t "${REPO}:headroom" \
  --push .

echo "==> Done"
echo "  docker run -d -p 20128:20128 -v 9router-data:/app/data ${REPO}:${TAG}"

#!/bin/sh
# Rebuild and restart 9Router locally.
#
#   ./start.sh              # smallest image (default)
#   TARGET=headroom ./start.sh
#   IMAGE=my/9router:dev TARGET=headroom ./start.sh
set -eu

IMAGE="${IMAGE:-9router}"
TARGET="${TARGET:-runner}"
PORT="${PORT:-20128}"

docker stop 9router 2>/dev/null || true
docker rm 9router 2>/dev/null || true

docker build --target "$TARGET" -t "$IMAGE" .

ENV_FILE=""
[ -f .env ] && ENV_FILE="--env-file .env"

# shellcheck disable=SC2086
docker run -d --name 9router \
  -p "${PORT}:20128" \
  -e DATA_DIR=/app/data \
  $ENV_FILE \
  -v 9router-data:/app/data \
  "$IMAGE"

echo "9router listening on http://localhost:${PORT}"

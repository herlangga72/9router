#!/bin/sh
# 9Router container entrypoint.
# Fixes ownership of mounted volumes, then drops privileges to the app user.
# Alpine ships su-exec; Debian ships gosu.
set -e

mkdir -p /app/data /app/data-home 2>/dev/null || true
chown -R bun:bun /app/data /app/data-home 2>/dev/null || true

if command -v su-exec >/dev/null 2>&1; then
  exec su-exec bun "$@"
elif command -v gosu >/dev/null 2>&1; then
  exec gosu bun "$@"
fi

exec "$@"

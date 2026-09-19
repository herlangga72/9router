# syntax=docker/dockerfile:1.7

# ---------------------------------------------------------------------------
# 9Router — Bun/Alpine image, optimized for size.
#
# Build targets:
#   runner   (default)  Minimal 9Router. No Python, smallest image.
#   headroom            runner + Python 3 + headroom-ai[proxy]. The dashboard's
#                       Token Saver can then install/start/stop Headroom inside
#                       this container, so no sidecar is required.
#
#   docker build -t <user>/9router:latest .
#   docker build --target headroom -t <user>/9router:latest-headroom .
# ---------------------------------------------------------------------------

ARG BUN_IMAGE=oven/bun:1-alpine
# Override to use a mirror, e.g. https://registry.npmmirror.com
ARG BUN_REGISTRY=https://registry.npmjs.org
# Override for private/mirrored PyPI indexes (used by the headroom target).
ARG PIP_INDEX_URL=https://pypi.org/simple

# ------------------------------- base --------------------------------------
FROM ${BUN_IMAGE} AS base
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1

# ------------------------------- deps --------------------------------------
FROM base AS deps
ARG BUN_REGISTRY
COPY package.json ./
RUN --mount=type=cache,target=/root/.bun/install/cache \
    bun install --registry "${BUN_REGISTRY}"
# `better-sqlite3` is an optional native addon. Bun never builds/loads it (the
# runtime uses the built-in `bun:sqlite` driver), but `next build` still tries to
# resolve the static import in its adapter. Drop in a placeholder so the build
# succeeds; it is never executed under Bun.
RUN if [ ! -d node_modules/better-sqlite3 ]; then \
      mkdir -p node_modules/better-sqlite3; \
      printf '%s\n' '{"name":"better-sqlite3","version":"0.0.0-placeholder","main":"index.js"}' \
        > node_modules/better-sqlite3/package.json; \
      printf '%s\n' \
        '// Build-time placeholder only. Bun uses the built-in bun:sqlite driver,' \
        '// so this module is never imported at runtime.' \
        'module.exports = function betterSqlite3Unavailable() {' \
        '  throw new Error("better-sqlite3 is not available in this Bun image");' \
        '};' \
        > node_modules/better-sqlite3/index.js; \
    fi

# ------------------------------ builder ------------------------------------
FROM base AS builder
# `bun --bun` runs Next under the Bun runtime (no Node in the image).
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN bun --bun next build --webpack \
 && bun scripts/copy-standalone-assets.mjs

# ------------------------------- payload -----------------------------------
# Assemble the exact runtime tree as ONE directory, so the final image is a
# single COPY layer. (Deleting files in a later layer would not shrink the
# image: Docker layers are additive.)
FROM builder AS payload
RUN <<'EOF'
set -eux
cd /app/.next/standalone

# Runtime files Next's file tracing cannot see:
#  - node-forge / node-machine-id are createRequire'd at runtime
cp -a /app/node_modules/node-forge node_modules/node-forge
cp -a /app/node_modules/node-machine-id node_modules/node-machine-id
#  - sql.js loads dist/sql-wasm.wasm by path, so tracing only picked up the JS
mkdir -p node_modules/sql.js/dist
cp -a /app/node_modules/sql.js/package.json node_modules/sql.js/package.json
cp -a /app/node_modules/sql.js/dist/sql-wasm.js node_modules/sql.js/dist/sql-wasm.js
cp -a /app/node_modules/sql.js/dist/sql-wasm.wasm node_modules/sql.js/dist/sql-wasm.wasm
#  - src/mitm is started as a separate process (server.js), so it is not traced
mkdir -p src && cp -a /app/src/mitm src/mitm

# Unused payloads tracing still copies in:
#  - @img/sharp: image optimization is off (images.unoptimized) and 9Router
#    proxies image requests instead of resizing them
#  - caniuse-lite: browserslist data, build-time only
#  - Next's bundled build-only compilers: the standalone server compiles nothing
rm -rf node_modules/@img node_modules/sharp node_modules/caniuse-lite
rm -rf node_modules/next/dist/compiled/babel \
       node_modules/next/dist/compiled/babel-packages \
       node_modules/next/dist/compiled/postcss-preset-env \
       node_modules/next/dist/compiled/cssnano-simple \
       node_modules/next/dist/compiled/schema-utils3
EOF

# ------------------------------ runtime ------------------------------------
FROM base AS runtime
LABEL org.opencontainers.image.title="9router" \
      org.opencontainers.image.description="Self-hosted AI router dashboard (Bun/Alpine)" \
      org.opencontainers.image.source="https://github.com/herlangga72/9router" \
      org.opencontainers.image.url="https://9router.com" \
      org.opencontainers.image.licenses="MIT"

ENV NODE_ENV=production \
    PORT=20128 \
    HOSTNAME=0.0.0.0 \
    NEXT_TELEMETRY_DISABLED=1 \
    DATA_DIR=/app/data \
    HOME=/home/bun

# su-exec lets the entrypoint fix volume ownership then drop root.
RUN apk add --no-cache su-exec

# Single layer: standalone output already contains .next/static, public/ and
# custom-server.js (copy-standalone-assets.mjs puts them there).
COPY --from=payload --chown=bun:bun /app/.next/standalone ./

RUN <<'EOF'
set -eux
cat > /entrypoint.sh <<'ENTRY'
#!/bin/sh
set -e
# Mounted volumes arrive root-owned; make them writable by the app user.
chown -R bun:bun /app/data /app/data-home 2>/dev/null || true
exec su-exec bun "$@"
ENTRY
chmod +x /entrypoint.sh
mkdir -p /app/data /app/data-home
chown -R bun:bun /app/data /app/data-home
EOF

EXPOSE 20128
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bun", "custom-server.js"]

# --------------------------- headroom (optional) ---------------------------
# Same image plus Python + the Headroom proxy, preinstalled and managed by the
# dashboard (Endpoint -> Token Saver -> Headroom). Adds a few hundred MB; skip
# it if you run Headroom as a sidecar and only need the small `runner` image.
FROM runtime AS headroom
ARG PIP_INDEX_URL
RUN <<'EOF'
set -eux
apk add --no-cache python3 py3-pip
python3 -m venv /opt/headroom
/opt/headroom/bin/pip install --no-cache-dir --index-url "${PIP_INDEX_URL}" "headroom-ai[proxy]"
# App runs as `bun`; it installs optional extras and spawns the proxy itself.
chown -R bun:bun /opt/headroom
EOF
# Puts `headroom` + its matching `python3` on PATH so 9Router auto-detects both.
ENV PATH="/opt/headroom/bin:${PATH}" \
    HEADROOM_URL=http://127.0.0.1:8787

# --------------------------- runner (default) ------------------------------
# Declared last so a plain `docker build .` produces the smallest image.
FROM runtime AS runner

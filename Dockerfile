# syntax=docker/dockerfile:1.7

# ---------------------------------------------------------------------------
# 9Router — Bun image optimized for size, with an optional bundled Headroom.
#
# Build targets:
#   runner   (default)  Minimal 9Router on Alpine/musl. Smallest image.
#   headroom            Same app on Debian/glibc + Python 3 + headroom-ai.
#                       The dashboard's Token Saver can then install/start/stop
#                       Headroom inside the container, no sidecar required.
#
#   docker build -t <user>/9router:latest .
#   docker build --target headroom -t <user>/9router:latest-headroom .
#
# The headroom variant uses a glibc base because headroom-ai depends on
# packages (e.g. ast-grep-cli) that publish no musl wheels.
# ---------------------------------------------------------------------------

ARG BUN_IMAGE=oven/bun:1-alpine
ARG BUN_GLIBC_IMAGE=oven/bun:1-slim
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
# image: Docker layers are additive.) The tree is pure JS/wasm, so it is
# portable between the musl and glibc runtimes.
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

# --------------------------- app (glibc, shared) ----------------------------
# Runtime setup shared by the glibc images. Kept separate from the app COPY so
# both the headroom image and any future glibc target reuse it.
FROM ${BUN_GLIBC_IMAGE} AS app-glibc
WORKDIR /app
ENV NODE_ENV=production \
    PORT=20128 \
    HOSTNAME=0.0.0.0 \
    NEXT_TELEMETRY_DISABLED=1 \
    DATA_DIR=/app/data \
    HOME=/home/bun
RUN apt-get update \
 && apt-get install -y --no-install-recommends gosu ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
COPY --from=payload --chown=bun:bun /app/.next/standalone ./
RUN mkdir -p /app/data /app/data-home && chown -R bun:bun /app/data /app/data-home
EXPOSE 20128
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bun", "custom-server.js"]

# --------------------------- headroom (optional) ---------------------------
# Same app plus Python + the Headroom proxy, preinstalled and managed by the
# dashboard (Endpoint -> Token Saver -> Headroom). Adds a few hundred MB; skip
# it if you run Headroom as a sidecar and only need the small `runner` image.
FROM app-glibc AS headroom
ARG PIP_INDEX_URL
LABEL org.opencontainers.image.title="9router-headroom" \
      org.opencontainers.image.description="9Router with bundled Headroom token saver (Bun/Debian)" \
      org.opencontainers.image.source="https://github.com/herlangga72/9router" \
      org.opencontainers.image.url="https://9router.com" \
      org.opencontainers.image.licenses="MIT"
RUN --mount=type=cache,target=/root/.cache/pip <<'EOF'
set -eux
apt-get update
apt-get install -y --no-install-recommends python3 python3-venv python3-pip
rm -rf /var/lib/apt/lists/*
python3 -m venv /opt/headroom
/opt/headroom/bin/pip install --index-url "$PIP_INDEX_URL" "headroom-ai[proxy]"
# Bytecode caches are regenerated on first import and are ~20% of the venv.
# *.dist-info is kept: the dashboard's `pip list` probe reads its metadata.
find /opt/headroom -type d -name __pycache__ -prune -exec rm -rf {} +
find /opt/headroom -name '*.pyc' -delete
# App runs as `bun`; it installs optional extras and spawns the proxy itself.
chown -R bun:bun /opt/headroom
EOF
# Puts `headroom` + its matching `python3` on PATH so 9Router auto-detects both.
ENV PATH="/opt/headroom/bin:${PATH}" \
    HEADROOM_URL=http://127.0.0.1:8787

# --------------------------- runner (default) ------------------------------
# Minimal Alpine/musl image. Declared last so a plain `docker build .` produces
# the smallest variant.
FROM base AS runner
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

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Single layer: standalone output already contains .next/static, public/ and
# custom-server.js (copy-standalone-assets.mjs puts them there).
COPY --from=payload --chown=bun:bun /app/.next/standalone ./
RUN mkdir -p /app/data /app/data-home && chown -R bun:bun /app/data /app/data-home

EXPOSE 20128
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bun", "custom-server.js"]

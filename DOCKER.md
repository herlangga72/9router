# Docker

Run 9Router in a container. This fork builds a **Bun + Alpine** image with two
variants:

| Image | Contents | Use it when |
| --- | --- | --- |
| `<user>/9router:latest` | 9Router only (no Python). Smallest. | You want the lean image, with or without an external Headroom sidecar. |
| `<user>/9router:latest-headroom` | 9Router **+** Python **+** `headroom-ai[proxy]` (Debian/glibc). | You want Headroom bundled and managed from the dashboard, no sidecar. |

`<user>` is your Docker Hub namespace (default in CI: `herlangga72`).

---

# 👤 For Users

## Quick start (small image)

```bash
docker run -d \
  -p 20128:20128 \
  -v "$HOME/.9router:/app/data" \
  -e DATA_DIR=/app/data \
  --name 9router \
  herlangga72/9router:latest
```

App listens on port `20128`. Open <http://localhost:20128>.

## Manage container

```bash
docker logs -f 9router        # view logs
docker stop 9router           # stop
docker start 9router          # start again
docker rm -f 9router          # remove
```

## Data persistence

```bash
-v "$HOME/.9router:/app/data" -e DATA_DIR=/app/data
```

Without `DATA_DIR`, the app falls back to `~/.9router/` (macOS/Linux) or
`%APPDATA%\9router\` (Windows). In the container `DATA_DIR=/app/data` makes the
bind mount work. The entrypoint fixes volume ownership on start.

Data layout under `$DATA_DIR/`:

```text
$DATA_DIR/
├── db/
│   ├── data.sqlite       # main SQLite database
│   └── backups/          # auto backups
└── ...                   # certs, logs, runtime configs
```

## Optional env vars

```bash
docker run -d \
  -p 20128:20128 \
  -v "$HOME/.9router:/app/data" \
  -e DATA_DIR=/app/data \
  -e PORT=20128 \
  -e HOSTNAME=0.0.0.0 \
  -e DEBUG=true \
  --name 9router \
  herlangga72/9router:latest
```

## Headroom (token saver)

Headroom compresses prompts/tool output before they reach the provider.
9Router calls its `/v1/compress` endpoint and fails open if it is unavailable.
There are two ways to run it. Headroom pulls in Python plus transformers,
onnxruntime and friends, so bundling it costs a few hundred MB. The sidecar
keeps the 9Router image at ~53 MiB.

### Option A: bundled in one image (recommended for single-container hosts)

```bash
docker run -d \
  -p 20128:20128 -p 8787:8787 \
  -v "$HOME/.9router:/app/data" \
  -e DATA_DIR=/app/data \
  -e HEADROOM_URL=http://127.0.0.1:8787 \
  --name 9router \
  herlangga72/9router:latest-headroom
```

Or with Compose:

```bash
docker compose -f docker-compose.headroom.yml up -d --build
```

Then open **Dashboard → Endpoint → Token Saver → Headroom**. The URL is already
`http://127.0.0.1:8787`; recheck status, optionally install the `code`/`ml`
compression extras, start the proxy, and enable Headroom.

Because the image ships `headroom` and a matching `python3` on `PATH`, the
dashboard can install extras and start/stop the proxy inside the container.

### Option B: sidecar container (keeps the app image small)

```bash
docker compose --profile sidecar up -d
# then add to the 9router service environment:
#   HEADROOM_URL: http://headroom:8787
```

If Headroom runs on the Docker host instead, use
`http://host.docker.internal:8787`; on Linux add
`--add-host=host.docker.internal:host-gateway`.

---

# 🛠 For Developers

## Build locally

```bash
# Smallest image (default target)
docker build -t 9router:latest .

# All-in-one with Headroom
docker build --target headroom -t 9router:latest-headroom .
```

Build args (all optional):

| Arg | Default | Purpose |
| --- | --- | --- |
| `BUN_IMAGE` | `oven/bun:1-alpine` | Base image. |
| `BUN_REGISTRY` | `https://registry.npmjs.org` | npm registry mirror, e.g. `https://registry.npmmirror.com`. |
| `PIP_INDEX_URL` | `https://pypi.org/simple` | PyPI index for the `headroom` target. |

Example with mirrors:

```bash
docker build \
  --build-arg BUN_REGISTRY=https://registry.npmmirror.com \
  --build-arg PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple \
  --target headroom -t 9router:headroom .
```

## Publish to Docker Hub

Automatic (GitHub Actions): push a tag `v*` (or run the workflow manually).
The workflow builds `linux/amd64` + `linux/arm64` for both variants and pushes:

- `<DOCKERHUB_USERNAME>/9router:latest` and `:latest-headroom`
- `ghcr.io/<owner>/9router:latest` and `:latest-headroom`
- version tags, e.g. `:0.5.81` and `:0.5.81-headroom`

Repository secrets to configure once:

| Secret | Value |
| --- | --- |
| `DOCKERHUB_USERNAME` | Docker Hub username (also used as the image namespace). |
| `DOCKERHUB_TOKEN` | Docker Hub access token with Read & Write. |

Optionally set a repository variable `DOCKERHUB_USERNAME` to control the
namespace without editing the workflow. Create the Docker Hub repository
`<username>/9router` once (it can be private or public); the token pushes to it.
If `DOCKERHUB_TOKEN` is not set, the workflow publishes to GHCR only instead of
failing.

Manual push:

```bash
docker login
DOCKERHUB_USER=herlangga72 scripts/docker-push.sh 0.5.81
```

## Image size notes

| Variant | Compressed (pull size) | Uncompressed |
| --- | --- | --- |
| `runner` (default) | ~53 MiB | ~128 MiB |
| `headroom` | ~252 MiB | ~748 MiB |

For reference, the upstream Node-based image is ~216 MiB compressed, and the
standalone Headroom image is ~173 MiB compressed on its own.

- Base is `oven/bun:1-alpine`; the runtime uses Bun's built-in `bun:sqlite`, so
  no native build toolchain is shipped. Bun itself is ~70 MiB of the
  uncompressed size.
- Only Next's traced standalone output plus the few files tracing cannot see
  (`src/mitm`, `node-forge`, `node-machine-id`, `sql.js`) are copied into the
  runtime layer.
- The `better-sqlite3` optional native addon is not installed (Bun does not use
  it); a build-time placeholder satisfies Next's resolver.
- The `headroom` variant uses a **Debian/glibc** base (`oven/bun:1-slim`)
  because `headroom-ai` depends on packages such as `ast-grep-cli` that publish
  no musl wheels. It adds Python 3 plus `headroom-ai[proxy]`, which is
  inherently large. Use the default image plus a sidecar if size matters.

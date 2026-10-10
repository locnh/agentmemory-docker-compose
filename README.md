# agentmemory-docker

Packages [`@agentmemory/agentmemory`](https://www.npmjs.com/package/@agentmemory/agentmemory) running on [iii](https://github.com/iiidev/iii), deployed with Docker Compose. The server exposes 2 ports:

- `3111` — Main HTTP API / MCP server (agentmemory)
- `3113` — Viewer (web UI)

## Quick Start

### 1. Create `.env` from `.env.example`

```bash
cp .env.example .env
```

Open `.env` and set `OPENAI_API_KEY` to a real API key (agentmemory uses this key to call the LLM for graph extraction, compression, etc.):

```env
OPENAI_API_KEY=sk-XXXX
```

The other variables in `.env.example` (base URL, model, embedding model...) keep their default values unless you have your own LLM/embedding endpoint.

### 2. Create the `service_main` Docker network

`docker-compose.yaml` declares the `service_main` network as `external`, so it must be created before `up`:

```bash
docker network create service_main
```

> If the network already exists (created by another service), skip this step.

### 3. Run Docker Compose

```bash
docker compose up -d
```

This builds the image (if it doesn't exist yet) and starts the `agentmemory` container with a healthcheck on `http://127.0.0.1:3111/agentmemory/livez`.

### 4. Get `AGENTMEMORY_SECRET` from the container log

On first startup, the entrypoint generates a random HMAC secret and **prints it to the log only once**:

```bash
docker logs -f agentmemory
```

Look for a block like this:

```
================================================================
agentmemory: generated HMAC secret on first boot
AGENTMEMORY_SECRET=<secret_value>
Copy this value now. It will not be printed again.
Stored at: /data/.hmac (chmod 600)
To rotate: delete /data/.hmac on the persistent volume and restart.
================================================================
```

**Copy the `AGENTMEMORY_SECRET` value immediately.** It is not printed again on later restarts (it is stored at `./data/.hmac` on the volume, chmod 600). This value is used to authenticate clients (opencode, MCP clients...) that connect to agentmemory.

> To rotate the secret: delete the `./data/.hmac` file and restart the container (`docker compose restart agentmemory`). A new secret will be generated and printed to the log.

### 5. Set environment variables before starting opencode

Before running opencode (or any MCP client that connects to agentmemory), export these two variables in your shell/session:

```bash
export AGENTMEMORY_SECRET=<secret_value_from_step_4>
export NTMEMORY_URL=http://127.0.0.1:3111
```

Then start opencode as usual — it will connect to agentmemory through these variables.

## Commands

| Command | Description |
|---|---|
| `docker compose up -d` | Build (if needed) and start the container in the background |
| `docker compose up -d --build` | Force a rebuild of the image, then start |
| `docker logs -f agentmemory` | Follow the logs; used to get the secret on first boot |
| `docker compose restart agentmemory` | Restart the container (used to rotate the secret after deleting `.hmac`) |
| `docker compose down` | Stop and remove the container (data in `./data` is kept) |
| `curl http://127.0.0.1:3111/agentmemory/livez` | Check the healthcheck |

## Architecture

- **Dockerfile**: base image `node:22-trixie-slim`, copies the `iii` binary from the `iiidev/iii` image, and installs `@agentmemory/agentmemory` via npm into a dedicated prefix (`/opt/agentmemory`) to pin the correct `iii-sdk` version (see the comments in the Dockerfile).
- **entrypoint.sh**: runs as root to (1) overwrite `iii-config.yaml` to bind `0.0.0.0` and use the absolute path `/data`, (2) `chown` the `/data` volume for the `node` user, (3) generate and persist the HMAC secret to `/data/.hmac` on first boot, then exec the `agentmemory` CLI as the `node` user via `gosu`.
- **docker-compose.yaml**: mounts `./data` to `/data` (persists state, stream store, secret), attaches to the external `service_main` network, and runs a healthcheck via the `livez` endpoint.
- **Data**: all state (KV store, stream store, HMAC secret) lives in `./data` on the host. Deleting this directory resets agentmemory completely (including the secret, which must then be retrieved from the log on the next boot).

## Redis Backend (DragonflyDB)

Since **v0.9.30**, agentmemory supports an opt-in Redis state backend (`AGENTMEMORY_STATE_BACKEND=redis`). This stack uses [DragonflyDB](https://www.dragonflydb.io/) (a Redis-compatible server) as that backend:

- `dragonfly` service: `docker.dragonflydb.io/dragonflydb/dragonfly`, snapshots to `./data-dragonfly` every 15 minutes (`--snapshot_cron`).
- `agentmemory` service: `AGENTMEMORY_STATE_BACKEND=redis` and `AGENTMEMORY_REDIS_URL=redis://dragonfly:6379`.
- `agentmemory` starts only after the Dragonfly healthcheck (`redis-cli PING`) passes.

Notes:

- The KV state now lives in Dragonfly, not only in `./data`. Back up `./data-dragonfly` as well as `./data`.
- `./data` still holds the HMAC secret (`/data/.hmac`) and the stream store.

## Upgrading agentmemory

The agentmemory version is controlled by two build args in `Dockerfile`:

```dockerfile
ARG AGENTMEMORY_SOURCE_COMMIT=v0.9.30   # agentmemory git tag/commit to build from
ARG III_VERSION=0.22.1                  # iii engine version (image tag + iii-sdk version)
```

`docker-compose.yaml` also sets `III_VERSION: "0.22.1"` under `services.agentmemory.build.args`. Keep it in sync with the `Dockerfile` default.

Steps:

1. Check the target release on GitHub (`rohitg00/agentmemory`) and read its `package.json`. Note the `iii-sdk` version.
2. Set `III_VERSION` in both `Dockerfile` and `docker-compose.yaml` to that `iii-sdk` version. If it does not match, the build fails at the `iii-sdk` check in the builder stage (this is intentional).
3. Set `AGENTMEMORY_SOURCE_COMMIT` to the new tag (for example `v0.9.31`).
4. Rebuild and restart:

   ```bash
   docker compose up -d --build
   docker compose logs -f agentmemory
   curl http://127.0.0.1:3111/agentmemory/livez
   ```

5. Back up `./data` and `./data-dragonfly` before upgrading.

### Breaking changes in v0.9.30

- **REST API auth is on by default.** If `AGENTMEMORY_SECRET` is unset, a secret is generated into `~/.agentmemory/secret`. Hand-written HTTP requests to `:3111` need `Authorization: Bearer <secret>`. Our entrypoint also creates a secret at `/data/.hmac`. Check which one the server uses after upgrading, and use that value in your clients.
- Writes need `Content-Type: application/json`. A present `Origin` header must be loopback, the viewer, or listed in `VIEWER_ALLOWED_ORIGINS`.
- Import and export paths are restricted to the data directory, `~/.agentmemory`, or `AGENTMEMORY_IMPORT_ROOT`.
- Stores load unchanged, and one-time migrations run automatically on first start.

## Notes

- `.env` and `data/` are gitignored — do not commit secrets/API keys or real data.
- The secret is printed to the log **only once**, when `/data/.hmac` does not exist. If you miss it, delete the `.hmac` file and restart to regenerate it (the old secret is lost, and clients using it will lose auth).

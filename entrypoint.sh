#!/bin/sh
# agentmemory first-boot entrypoint.
#
# Runs as root so it can:
#   1. Overwrite the npm-bundled iii-config.yaml (which binds 127.0.0.1
#      and uses relative ./data paths) with a deploy-tuned version that
#      binds 0.0.0.0 and uses absolute /data paths.
#   2. chown the platform-mounted /data volume to the runtime user
#      (managed platforms mount volumes root-owned 755 by default).
#   3. Generate the HMAC secret on first boot and persist it to
#      /data/.hmac (chmod 600) so the secret survives restarts.
#
# Then it execs the agentmemory CLI under gosu as the unprivileged
# `node` user.
#
# AGENTMEMORY_STATE_BACKEND=redis (built from agentmemory main branch,
# not yet in a published release) swaps the iii-state / iii-stream
# adapters from the file-based KV store to the redis adapter, pointed
# at AGENTMEMORY_REDIS_URL. This is written by hand here rather than
# relying on the CLI's own renderEngineConfig — that path only fires
# on native (non-Docker) starts; see src/cli.ts's
# warnIfDockerIgnoresStateBackend in the agentmemory source for why.
#
# allowed_origins below MUST stay flow-style ([...] on one line), not
# block-style (- "..." sub-items). The CLI's setManagedCorsOrigins (in
# agentmemory's src/cli/engine-config.ts) finds the "allowed_origins:"
# line and replaces that ONE line with a flow-style rewrite — it never
# deletes block-style sub-items below it. Block-style here produced a
# duplicate-looking "allowed_origins:" mapping (the rewritten flow-style
# line immediately followed by the original dash sub-items) that the
# YAML parser in iii-engine rejected with "did not find expected key".

set -eu

DATA_DIR="${AGENTMEMORY_DATA_DIR:-/data}"
HMAC_FILE="${AGENTMEMORY_HMAC_FILE:-/data/.hmac}"
RUN_AS="node:node"
III_CONFIG="/opt/agentmemory/node_modules/@agentmemory/agentmemory/dist/iii-config.yaml"

mkdir -p "$DATA_DIR"
chown -R "$RUN_AS" "$DATA_DIR"

STATE_BACKEND="${AGENTMEMORY_STATE_BACKEND:-file}"
if [ "$STATE_BACKEND" = "redis" ] && [ -z "${AGENTMEMORY_REDIS_URL:-}" ]; then
  echo "AGENTMEMORY_STATE_BACKEND=redis requires AGENTMEMORY_REDIS_URL to be set (e.g. redis://dragonfly:6379)." >&2
  exit 1
fi

if [ "$STATE_BACKEND" = "redis" ]; then
  STATE_ADAPTER_BLOCK="      adapter:
        name: redis
        config:
          redis_url: '\${AGENTMEMORY_REDIS_URL}'"
  STREAM_ADAPTER_BLOCK="      adapter:
        name: redis
        config:
          redis_url: '\${AGENTMEMORY_REDIS_URL}'"
else
  STATE_ADAPTER_BLOCK="      adapter:
        name: kv
        config:
          store_method: file_based
          file_path: /data/state_store.db"
  STREAM_ADAPTER_BLOCK="      adapter:
        name: kv
        config:
          store_method: file_based
          file_path: /data/stream_store"
fi

cat > "$III_CONFIG" <<EOF
workers:
  - name: iii-http
    config:
      port: 3111
      host: 0.0.0.0
      default_timeout: 180000
      cors:
        allowed_origins: ["http://localhost:3111", "http://localhost:3113", "http://127.0.0.1:3111", "http://127.0.0.1:3113"]
        allowed_methods: [GET, POST, PUT, DELETE, OPTIONS]
  - name: iii-state
    config:
$STATE_ADAPTER_BLOCK
  - name: iii-queue
    config:
      adapter:
        name: builtin
  - name: iii-pubsub
    config:
      adapter:
        name: local
  - name: iii-cron
    config:
      adapter:
        name: kv
  - name: iii-stream
    config:
      port: 3112
      host: 0.0.0.0
$STREAM_ADAPTER_BLOCK
  - name: iii-observability
    config:
      enabled: true
      service_name: agentmemory
      exporter: memory
      sampling_ratio: 1.0
      metrics_enabled: true
      logs_enabled: true
      logs_console_output: true
EOF
chown "$RUN_AS" "$III_CONFIG"

if [ ! -s "$HMAC_FILE" ]; then
  SECRET="$(openssl rand -hex 32)"
  umask 077
  printf '%s\n' "$SECRET" > "$HMAC_FILE"
  chmod 600 "$HMAC_FILE"
  chown "$RUN_AS" "$HMAC_FILE"
  echo "================================================================"
  echo "agentmemory: generated HMAC secret on first boot"
  echo "AGENTMEMORY_SECRET=$SECRET"
  echo "Copy this value now. It will not be printed again."
  echo "Stored at: $HMAC_FILE (chmod 600)"
  echo "To rotate: delete $HMAC_FILE on the persistent volume and restart."
  echo "================================================================"
fi

AGENTMEMORY_SECRET="$(cat "$HMAC_FILE")"
export AGENTMEMORY_SECRET

exec gosu "$RUN_AS" agentmemory "$@"

#!/usr/bin/env bash
# Stop background Hyperion Nest process and tear down Hyperion compose
# (Postgres), including named volumes.
#
# Usage:
#   ./scripts/hyperion/down.sh
#   just hyperion down
#
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

COMPOSE_FILE="${REPO_ROOT}/docker/hyperion-compose.yaml"
PID_FILE="${RUNTIME_ROOT}/hyperion.pid"

if [[ -f "$PID_FILE" ]]; then
  old="$(tr -d '[:space:]' <"$PID_FILE" || true)"
  if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
    log "stopping Hyperion pid ${old}"
    kill "$old" 2>/dev/null || true
    sleep 1
    kill -9 "$old" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
else
  log "no Hyperion pid file at ${PID_FILE#"$REPO_ROOT"/}"
fi

if [[ -f "$COMPOSE_FILE" ]]; then
  log "docker compose down -v (${COMPOSE_FILE#"$REPO_ROOT"/})"
  FCSS_HYPERION_PG_HOST_PORT="${FCSS_HYPERION_PG_HOST_PORT}" \
    docker compose -f "$COMPOSE_FILE" down -v || true
fi

log "hyperion down complete"

#!/usr/bin/env bash
# Stop background CDP Nest process and tear down CDP compose (Postgres + DMOB).
#
# Usage:
#   ./scripts/cdp/down.sh
#   just cdp down
#
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

COMPOSE_FILE="${REPO_ROOT}/docker/cdp-compose.yaml"
PID_FILE="${RUNTIME_ROOT}/cdp.pid"

if [[ -f "$PID_FILE" ]]; then
  old="$(tr -d '[:space:]' <"$PID_FILE" || true)"
  if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
    log "stopping CDP pid ${old}"
    kill "$old" 2>/dev/null || true
    sleep 1
    kill -9 "$old" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
else
  log "no CDP pid file at ${PID_FILE#"$REPO_ROOT"/}"
fi

if [[ -f "$COMPOSE_FILE" ]]; then
  log "docker compose down (${COMPOSE_FILE#"$REPO_ROOT"/})"
  FCSS_CDP_PG_HOST_PORT="${FCSS_CDP_PG_HOST_PORT}" \
  FCSS_CDP_DMOB_PG_HOST_PORT="${FCSS_CDP_DMOB_PG_HOST_PORT}" \
    docker compose -f "$COMPOSE_FILE" down || true
fi

# Allow re-seed after volume wipe on next up.
rm -f "${RUNTIME_ROOT}/cdp-dmob-seeded"

log "cdp down complete"

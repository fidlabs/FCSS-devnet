#!/usr/bin/env bash
# Tear down oracle Postgres compose and remove its volume.
#
# Usage:
#   ./scripts/oracle/down.sh
#   just oracle down
#
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

COMPOSE_FILE="${ORACLE_DIR}/docker-compose.yml"
COMPOSE_PORTS_OVERRIDE="${REPO_ROOT}/docker/oracle-compose.ports.yaml"

if [[ -f "$COMPOSE_FILE" ]]; then
  log "docker compose down -v (oracle Postgres)"
  docker compose \
    -f "$COMPOSE_FILE" \
    -f "$COMPOSE_PORTS_OVERRIDE" \
    down -v || true
fi

log "oracle down complete"

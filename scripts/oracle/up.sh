#!/usr/bin/env bash
# Start filecoin-oracle-service Postgres (docker compose) and apply Prisma schema.
#
# Prerequisites:
#   - just oracle init (writes .env with DATABASE_URL)
#   - Node.js 24+ and npm on PATH
#
# Usage:
#   ./scripts/oracle/up.sh
#   just oracle up

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

: "${ORACLE_DIR:=${REPO_ROOT}/extern/filecoin-oracle-service}"
COMPOSE_FILE="${ORACLE_DIR}/docker-compose.yml"
ENV_FILE="${ORACLE_DIR}/.env"

[[ -d "$ORACLE_DIR" ]] || die "oracle submodule missing at ${ORACLE_DIR}"
require_file "$COMPOSE_FILE"
require_file "$ENV_FILE"
require_cmd docker

log "starting oracle-service-db (docker compose)"
docker compose -f "$COMPOSE_FILE" up -d

log "waiting for Postgres to accept connections"
ready=false
for _ in $(seq 1 60); do
  if docker compose -f "$COMPOSE_FILE" exec -T oracle-service-db pg_isready -U postgres >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
[[ "$ready" == true ]] || die "oracle-service-db did not become ready (pg_isready)"

log "applying Prisma schema"
"${SCRIPT_DIR}/db-schema.sh"

log "Postgres ready on localhost:8038"

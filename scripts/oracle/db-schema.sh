#!/usr/bin/env bash
# npm ci (if needed) + prisma generate + prisma db push for filecoin-oracle-service.
#
# Prerequisites:
#   - just oracle init (.env with DATABASE_URL)
#   - Postgres up (just oracle up, or docker compose in the submodule)
#
# Usage:
#   ./scripts/oracle/db-schema.sh
#   (also invoked by scripts/oracle/up.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

: "${ORACLE_DIR:=${REPO_ROOT}/extern/filecoin-oracle-service}"
ENV_FILE="${ORACLE_DIR}/.env"
SCHEMA="${ORACLE_DIR}/prisma/schema.prisma"
PRISMA_CONFIG="${ORACLE_DIR}/prisma/prisma.config.ts"

[[ -d "$ORACLE_DIR" ]] || die "oracle submodule missing at ${ORACLE_DIR}"
require_file "$ENV_FILE"
require_file "$SCHEMA"
require_file "$PRISMA_CONFIG"
require_cmd npm
require_cmd npx

cd "$ORACLE_DIR"

if [[ ! -d node_modules ]]; then
  log "npm ci (no node_modules yet)"
  npm ci
elif [[ ! -d node_modules/prisma ]] || [[ ! -d node_modules/@prisma/client ]]; then
  log "npm ci (prisma packages missing)"
  npm ci
fi

log "prisma generate"
npm run prisma:generate

log "prisma db push"
npx prisma db push --schema prisma/schema.prisma --config prisma/prisma.config.ts

log "done — schema applied"

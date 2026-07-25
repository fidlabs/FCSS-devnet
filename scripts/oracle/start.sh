#!/usr/bin/env bash
# Run filecoin-oracle-service via `npm run start`.
#
# Prerequisites:
#   - just oracle init (.env + npm ci + npm run build)
#   - Postgres up (scripts/oracle/up.sh)
#   - Node.js 24+ and npm on PATH
#
# Usage:
#   ./scripts/oracle/start.sh
#   just oracle start

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

: "${ORACLE_DIR:=${REPO_ROOT}/extern/filecoin-oracle-service}"
ENV_FILE="${ORACLE_DIR}/.env"

[[ -d "$ORACLE_DIR" ]] || die "oracle submodule missing at ${ORACLE_DIR}"
require_file "$ENV_FILE"
require_file "${ORACLE_DIR}/dist/index.js"
require_cmd npm

cd "$ORACLE_DIR"
log "npm run start"
exec npm run start

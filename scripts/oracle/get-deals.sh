#!/usr/bin/env bash
# List deals from the local filecoin-oracle-service HTTP API (GET /deals).
#
# Prerequisites:
#   - oracle app running (just oracle up)
#
# Usage:
#   ./scripts/oracle/get-deals.sh
#   ./scripts/oracle/get-deals.sh --state Active
#   ./scripts/oracle/get-deals.sh --page 1 --limit 50
#   just oracle get-deals --state Accepted
#
# Env:
#   ORACLE_URL   base URL (default: http://127.0.0.1:<APP_PORT from .env or 23100>)
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/envfile.sh
source "${SCRIPT_DIR}/../lib/envfile.sh"

: "${ORACLE_DIR:=${REPO_ROOT}/extern/filecoin-oracle-service}"
ENV_FILE="${ORACLE_DIR}/.env"

STATE=""
PAGE=""
LIMIT=""

usage() {
  cat <<'EOF'
Usage: get-deals.sh [options]

GET /deals from the running oracle HTTP API.

Options:
  --state STATE   Filter: None, Proposed, Accepted, Active, Finalized,
                  Rejected, Expired, Terminated
  --page N        Page number
  --limit N       Page size
  -h, --help      Show this help

Env:
  ORACLE_URL      Override base URL (default http://127.0.0.1:$APP_PORT)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state) STATE="$2"; shift 2 ;;
    --page) PAGE="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

require_cmd curl

if [[ -z "${ORACLE_URL:-}" ]]; then
  port="${FCSS_ORACLE_APP_HOST_PORT}"
  if [[ -f "$ENV_FILE" ]]; then
    port="$(env_get APP_PORT "$ENV_FILE" 2>/dev/null || printf '%s' "$port")"
  fi
  ORACLE_URL="http://${FCSS_HOST}:${port}"
fi

query=""
append_q() {
  local key="$1" val="$2"
  [[ -n "$val" ]] || return 0
  if [[ -n "$query" ]]; then
    query="${query}&${key}=${val}"
  else
    query="${key}=${val}"
  fi
}

append_q state "$STATE"
append_q page "$PAGE"
append_q limit "$LIMIT"

url="${ORACLE_URL%/}/deals"
[[ -n "$query" ]] && url="${url}?${query}"

log "GET ${url}"
body="$(curl -fsS --max-time 30 "$url")" || die "request failed (is the oracle running on ${ORACLE_URL}?)"

if command -v jq >/dev/null 2>&1; then
  printf '%s\n' "$body" | jq .
else
  printf '%s\n' "$body"
fi

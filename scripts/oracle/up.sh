#!/usr/bin/env bash
# Bring up filecoin-oracle-service for the local Curio + PoRep Market V2 stack:
#   1. Apply patches, write .env from latest.json, npm ci/build
#   2. docker compose Postgres + Prisma schema
#   3. npm run start (foreground)
#
# Prerequisites:
#   - just porep-market deploy (deployments/devnet/latest.json)
#   - Curio deployer.private-key
#   - Node.js 24+, npm, docker
#
# Usage:
#   ./scripts/oracle/up.sh
#   ./scripts/oracle/up.sh --force
#   just oracle up
#
# Cron schedule overrides (highest wins):
#   1. Env var when invoking (e.g. TRIGGER_SYNC_DEALS_JOB_INTERVAL_CRON='* * * * *')
#   2. Existing value in .env (survives rewrite / --force)
#   3. Local-friendly defaults below
#
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/envfile.sh
source "${SCRIPT_DIR}/../lib/envfile.sh"

FORCE=false
OUT_FILE=""

usage() {
  cat <<'EOF'
Usage: up.sh [options]

Write filecoin-oracle-service/.env, start Postgres + Prisma, then npm run start.

Options:
  --force           Overwrite existing .env without backup
  --out FILE        .env path (default: <ORACLE_DIR>/.env)
  -h, --help        Show this help

Cron vars (optional env overrides; else keep existing .env; else defaults):
  TRIGGER_SYNC_DEALS_JOB_INTERVAL_CRON
  TRIGGER_SLI_JOB_INTERVAL_CRON
  TRIGGER_CLAIMS_TRACKING_JOB_INTERVAL_CRON
  TRIGGER_SETTLEMENT_BOT_JOB_INTERVAL_CRON
  TRIGGER_TERMINATE_DEAL_JOB_INTERVAL_CRON
  TRIGGER_END_EPOCH_DEAL_JOB_INTERVAL_CRON
  TRIGGER_REJECT_EXPIRED_DEAL_INTERVAL_CRON
  TRIGGER_REFRESH_EVIDENCE_STATUS_INTERVAL_CRON
  SYNC_URL_FINDER_SLI_TARGETS_JOB_INTERVAL_CRON
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

: "${ORACLE_DIR:=${REPO_ROOT}/extern/filecoin-oracle-service}"
DEPLOYMENT_JSON="${POREP_MARKET_DIR}/deployments/devnet/latest.json"
DEPLOYER_KEY_FILE="${CONTRACTS_DIR}/deployer.private-key"
OUT_FILE="${OUT_FILE:-${ORACLE_DIR}/.env}"
COMPOSE_FILE="${ORACLE_DIR}/docker-compose.yml"

[[ -d "$ORACLE_DIR" ]] || die "oracle submodule missing at ${ORACLE_DIR} (run: git submodule update --init --recursive)"

# ---------------------------------------------------------------------------
# 1) Patches + .env + build
# ---------------------------------------------------------------------------

"${SCRIPT_DIR}/patch.sh"

require_file "$DEPLOYMENT_JSON"
require_file "$DEPLOYER_KEY_FILE"
require_cmd jq
require_cmd cast
require_cmd npm
require_cmd docker

proxy_addr() {
  local name="$1"
  local addr
  addr="$(jq -r --arg n "$name" '.contracts[$n].proxy // empty' "$DEPLOYMENT_JSON")"
  [[ -n "$addr" && "$addr" != "null" ]] || die "missing contracts.${name}.proxy in ${DEPLOYMENT_JSON}"
  printf '%s\n' "$addr"
}

# Prefer .address, then .proxy (ViewHelper is a plain contract; market is a proxy).
contract_addr() {
  local name="$1"
  local addr
  addr="$(jq -r --arg n "$name" '.contracts[$n].address // .contracts[$n].proxy // empty' "$DEPLOYMENT_JSON")"
  [[ -n "$addr" && "$addr" != "null" ]] || die "missing contracts.${name} address/proxy in ${DEPLOYMENT_JSON}"
  printf '%s\n' "$addr"
}

ext_addr() {
  local name="$1"
  local addr
  addr="$(jq -r --arg n "$name" '.externalDependencies[$n] // empty' "$DEPLOYMENT_JSON")"
  [[ -n "$addr" && "$addr" != "null" ]] || die "missing externalDependencies.${name} in ${DEPLOYMENT_JSON}"
  printf '%s\n' "$addr"
}

POREP_MARKET="$(proxy_addr PoRepMarket)"
POREP_MARKET_VIEW_HELPER="$(contract_addr PoRepMarketViewHelper)"
SP_REGISTRY="$(proxy_addr SPRegistry)"
SLI_ORACLE="$(proxy_addr SLIOracle)"
SLI_SCORER="$(proxy_addr SLIScorer)"
DATACAP_ADAPTER="$(proxy_addr DataCapEvidenceAdapter)"
FILECOIN_PAY="$(ext_addr FilecoinPay)"

PRIVATE_KEY="$(tr -d '[:space:]' < "$DEPLOYER_KEY_FILE")"
[[ "$PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "invalid deployer private key in ${DEPLOYER_KEY_FILE}"

CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null | tr -d '[:space:]' || true)"
if [[ -z "$CHAIN_ID" ]]; then
  CHAIN_ID=31415926
  log "cast chain-id failed; using default local Curio CHAIN_ID=${CHAIN_ID}"
fi

# Helpers are deployed by scripts/porep-market/deploy.sh (not Deploy.s.sol).
CLAIM_INSPECTOR="${CLAIM_INSPECTOR_CONTRACT_ADDRESS:-}"
if [[ -z "$CLAIM_INSPECTOR" ]]; then
  CLAIM_INSPECTOR="$(jq -r '.contracts.PoRepMarketClaimInspector.address // empty' "$DEPLOYMENT_JSON")"
fi
SECTOR_STATUS_INSPECTOR="${SECTOR_STATUS_INSPECTOR_CONTRACT_ADDRESS:-}"
if [[ -z "$SECTOR_STATUS_INSPECTOR" ]]; then
  SECTOR_STATUS_INSPECTOR="$(jq -r '.contracts.PoRepMarketSectorStatusInspector.address // empty' "$DEPLOYMENT_JSON")"
fi

JOB_TRIGGER_AUTH_TOKEN="${JOB_TRIGGER_AUTH_TOKEN:-}"
if [[ -z "$JOB_TRIGGER_AUTH_TOKEN" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    JOB_TRIGGER_AUTH_TOKEN="$(openssl rand -hex 16)"
  else
    JOB_TRIGGER_AUTH_TOKEN="local-dev-$(date +%s)"
  fi
fi

# CDP / URL Finder are external; empty disables those integrations until set.
CDP_SERVICE_URL="${CDP_SERVICE_URL:-}"
URL_FINDER_SERVICE_URL="${URL_FINDER_SERVICE_URL:-}"
URL_FINDER_AUTH_TOKEN="${URL_FINDER_AUTH_TOKEN:-}"

# Resolve cron: process env > existing .env > default (service requires non-empty).
# Values must contain a space (standard 5-field cron); space-stripped leftovers from
# an older env_get bug are ignored so --force can heal .env.
cron_resolve() {
  local key="$1"
  local default="$2"
  local from_env from_file
  from_env="$(printenv "$key" 2>/dev/null || true)"
  if [[ -n "$from_env" && "$from_env" == *" "* ]]; then
    printf '%s\n' "$from_env"
    return 0
  fi
  if [[ -f "$OUT_FILE" ]]; then
    from_file="$(env_get "$key" "$OUT_FILE" 2>/dev/null || true)"
    if [[ -n "$from_file" && "$from_file" == *" "* ]]; then
      printf '%s\n' "$from_file"
      return 0
    fi
  fi
  printf '%s\n' "$default"
}

CRON_SYNC="$(cron_resolve TRIGGER_SYNC_DEALS_JOB_INTERVAL_CRON '*/2 * * * *')"
CRON_SLI="$(cron_resolve TRIGGER_SLI_JOB_INTERVAL_CRON '*/10 * * * *')"
CRON_CLAIMS="$(cron_resolve TRIGGER_CLAIMS_TRACKING_JOB_INTERVAL_CRON '*/10 * * * *')"
CRON_SETTLE="$(cron_resolve TRIGGER_SETTLEMENT_BOT_JOB_INTERVAL_CRON '*/15 * * * *')"
CRON_TERM="$(cron_resolve TRIGGER_TERMINATE_DEAL_JOB_INTERVAL_CRON '0 * * * *')"
CRON_END="$(cron_resolve TRIGGER_END_EPOCH_DEAL_JOB_INTERVAL_CRON '0 * * * *')"
CRON_REJECT="$(cron_resolve TRIGGER_REJECT_EXPIRED_DEAL_INTERVAL_CRON '*/30 * * * *')"
CRON_REFRESH="$(cron_resolve TRIGGER_REFRESH_EVIDENCE_STATUS_INTERVAL_CRON '0 */6 * * *')"
CRON_URL_FINDER="$(cron_resolve SYNC_URL_FINDER_SLI_TARGETS_JOB_INTERVAL_CRON '0 */6 * * *')"

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:postgres@localhost:8038/postgres}"
# Curio indexer publishes host 3000-3003; keep oracle off that range.
APP_PORT="${APP_PORT:-3100}"
LOG_LEVEL="${LOG_LEVEL:-info}"
EVIDENCE_BATCH_SIZE="${EVIDENCE_BATCH_SIZE:-1000}"

if [[ -e "$OUT_FILE" && "$FORCE" != true ]]; then
  backup="${OUT_FILE}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  cp "$OUT_FILE" "$backup"
  log "backed up existing ${OUT_FILE#"$REPO_ROOT"/} -> ${backup#"$REPO_ROOT"/}"
fi

umask 077
cat >"$OUT_FILE" <<EOF
# Generated by scripts/oracle/up.sh for local Curio + PoRep Market V2
# Source: ${DEPLOYMENT_JSON#"$REPO_ROOT"/}
# CHAIN_ID=${CHAIN_ID} RPC_URL=${RPC_URL}
#
# Role wallets: local Deploy.s.sol grants ORACLE / POREP_SERVICE / TERMINATION_ORACLE /
# OPERATOR to the Curio deployer EOA — all *_WALLET_PK use deployer.private-key.
# Claim/Sector inspectors are deployed by scripts/porep-market/deploy.sh.

LOG_LEVEL=${LOG_LEVEL}
RPC_URL=${RPC_URL}
CHAIN_ID=${CHAIN_ID}
APP_PORT=${APP_PORT}
CDP_SERVICE_URL=${CDP_SERVICE_URL}
URL_FINDER_SERVICE_URL=${URL_FINDER_SERVICE_URL}
URL_FINDER_AUTH_TOKEN=${URL_FINDER_AUTH_TOKEN}
EVIDENCE_BATCH_SIZE=${EVIDENCE_BATCH_SIZE}

POREP_SERVICE_ROLE_WALLET_PK=${PRIVATE_KEY}
ORACLE_ROLE_WALLET_PK=${PRIVATE_KEY}
TERMINATION_ORACLE_ROLE_WALLET_PK=${PRIVATE_KEY}
FILECOIN_PAY_ROLE_WALLET_PK=${PRIVATE_KEY}

JOB_TRIGGER_AUTH_TOKEN=${JOB_TRIGGER_AUTH_TOKEN}

TRIGGER_SLI_JOB_INTERVAL_CRON="${CRON_SLI}"
TRIGGER_CLAIMS_TRACKING_JOB_INTERVAL_CRON="${CRON_CLAIMS}"
TRIGGER_SETTLEMENT_BOT_JOB_INTERVAL_CRON="${CRON_SETTLE}"
TRIGGER_TERMINATE_DEAL_JOB_INTERVAL_CRON="${CRON_TERM}"
TRIGGER_SYNC_DEALS_JOB_INTERVAL_CRON="${CRON_SYNC}"
SYNC_URL_FINDER_SLI_TARGETS_JOB_INTERVAL_CRON="${CRON_URL_FINDER}"
TRIGGER_END_EPOCH_DEAL_JOB_INTERVAL_CRON="${CRON_END}"
TRIGGER_REJECT_EXPIRED_DEAL_INTERVAL_CRON="${CRON_REJECT}"
TRIGGER_REFRESH_EVIDENCE_STATUS_INTERVAL_CRON="${CRON_REFRESH}"

SLI_ORACLE_CONTRACT_ADDRESS=${SLI_ORACLE}
DATACAP_EVIDENCE_ADAPTER_CONTRACT_ADDRESS=${DATACAP_ADAPTER}
POREP_MARKET_CONTRACT_ADDRESS=${POREP_MARKET}
POREP_MARKET_VIEW_HELPER_CONTRACT_ADDRESS=${POREP_MARKET_VIEW_HELPER}
SP_REGISTRY_CONTRACT_ADDRESS=${SP_REGISTRY}
FILECOIN_PAY_CONTRACT_ADDRESS=${FILECOIN_PAY}
SLI_SCORER_CONTRACT_ADDRESS=${SLI_SCORER}
CLAIM_INSPECTOR_CONTRACT_ADDRESS=${CLAIM_INSPECTOR}
SECTOR_STATUS_INSPECTOR_CONTRACT_ADDRESS=${SECTOR_STATUS_INSPECTOR}

DATABASE_URL=${DATABASE_URL}
EOF

log "wrote ${OUT_FILE#"$REPO_ROOT"/}"
log "  POREP_MARKET=${POREP_MARKET}"
log "  POREP_MARKET_VIEW_HELPER=${POREP_MARKET_VIEW_HELPER}"
log "  DATACAP_EVIDENCE_ADAPTER=${DATACAP_ADAPTER}"
log "  FILECOIN_PAY=${FILECOIN_PAY}"
log "  CHAIN_ID=${CHAIN_ID}"

cd "$ORACLE_DIR"
if [[ ! -d node_modules ]]; then
  log "npm ci"
  npm ci
fi
log "npm run build"
npm run build

# ---------------------------------------------------------------------------
# 2) Postgres + Prisma
# ---------------------------------------------------------------------------

require_file "$COMPOSE_FILE"
require_file "$OUT_FILE"

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

# ---------------------------------------------------------------------------
# 3) App (foreground)
# ---------------------------------------------------------------------------

require_file "${ORACLE_DIR}/dist/index.js"
cd "$ORACLE_DIR"
log "npm run start"
exec npm run start

#!/usr/bin/env bash
# Destructive FCSS-devnet reset: wipe chain/DB/envs, preserve records/images/patches,
# then bring the stack back up (just up).
#
# Wipe:
#   - Curio docker data (via just curio down)
#   - Oracle Postgres compose
#   - extern/porep-market/.deployment/
#   - Generated .env files (backed up to .env.bak.<ts>)
#   - Prune .runtime/failures (keep last 10)
#
# Preserve:
#   - Submodule checkouts + patches + versions.lock.yaml
#   - Docker images / proof params
#   - deployments/devnet/records/ (immutable history)
#
# Usage:
#   ./scripts/reset.sh
#   just reset
#
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"

backup_env() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  local bak="${f}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$f" "$bak"
  log "moved ${f#"$REPO_ROOT"/} → ${bak#"$REPO_ROOT"/}"
}

log "FCSS reset: tearing down oracle + cdp + curio (wipes Curio docker/data)"
(
  cd "$REPO_ROOT"
  just oracle down || true
  just cdp down || true
  just curio down
)

log "removing porep-market .deployment scratch"
rm -rf "${POREP_MARKET_DIR}/.deployment"

log "backing up generated env files"
backup_env "${POREP_MARKET_DIR}/.env"
backup_env "${TOOLING_DIR}/.env"
backup_env "${ORACLE_DIR}/.env"
backup_env "${CDP_DIR}/.env"

log "pruning old .runtime/failures (keep 10)"
runtime_prune_failures 10

log "bringing stack back up (just up)"
(
  cd "$REPO_ROOT"
  just up
)

log "reset complete"

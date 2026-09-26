#!/usr/bin/env bash
# Destructive FCSS-devnet reset: wipe runtime + generated envs, preserve
# records/images/patches, then bring the stack back up (just up).
#
# Wipe (via just down / scripts/down.sh):
#   - Curio docker data
#   - Oracle / Hyperion Postgres volumes
#   - .runtime/ and porep-market .deployment/
#
# Additionally:
#   - Generated .env files (backed up to .env.bak.<ts>)
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

backup_env() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  local bak="${f}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$f" "$bak"
  log "moved ${f#"$REPO_ROOT"/} → ${bak#"$REPO_ROOT"/}"
}

log "FCSS reset: just down (services + runtime data)"
(
  cd "$REPO_ROOT"
  just down || true
)

log "backing up generated env files"
backup_env "${POREP_MARKET_DIR}/.env"
backup_env "${TOOLING_DIR}/.env"
backup_env "${ORACLE_DIR}/.env"
backup_env "${HYPERION_DIR}/.env"

log "bringing stack back up (just up)"
(
  cd "$REPO_ROOT"
  just up
)

log "reset complete"

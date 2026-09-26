#!/usr/bin/env bash
# Tear down the FCSS stack and wipe all runtime data.
#
# Stops:
#   - seed-deals HTTP (manifest) + Singularity content-provider container
#   - oracle Postgres (compose down -v)
#   - Hyperion Nest + Postgres (compose down -v)
#   - Curio devnet (also rm -rf extern/curio/docker/data)
#
# Removes:
#   - .runtime/ (logs, pids, seed-deals, tooling onboard/logs, failure dumps)
#   - extern/porep-market/.deployment/ (forge scratch)
#
# Preserves:
#   - Generated .env files (backed up by just reset)
#   - Submodule checkouts, patches, versions.lock.yaml
#   - Docker images / proof params
#   - deployments/devnet/records/ (immutable history)
#
# Usage:
#   ./scripts/down.sh
#   just down
#
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SINGULARITY_CP_NAME="${SINGULARITY_CP_NAME:-fcss-seed-singularity-cp}"

stop_seed_servers() {
  local pid_file pid
  pid_file="${RUNTIME_ROOT}/seed-deals/manifest-http.pid"
  if [[ -f "$pid_file" ]]; then
    pid="$(tr -d '[:space:]' <"$pid_file" || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      log "stopping seed manifest HTTP pid ${pid}"
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  fi

  if docker inspect "$SINGULARITY_CP_NAME" >/dev/null 2>&1; then
    log "removing docker container ${SINGULARITY_CP_NAME}"
    docker rm -f "$SINGULARITY_CP_NAME" >/dev/null 2>&1 || true
  fi
}

log "FCSS down: stopping seed helpers"
stop_seed_servers

log "FCSS down: oracle"
"${SCRIPT_DIR}/oracle/down.sh" || true

log "FCSS down: hyperion"
"${SCRIPT_DIR}/hyperion/down.sh" || true

log "FCSS down: curio (wipes extern/curio/docker/data)"
(
  cd "$REPO_ROOT"
  just curio down
)

log "removing porep-market .deployment scratch"
rm -rf "${POREP_MARKET_DIR}/.deployment"

log "removing .runtime/ (includes .runtime/tooling/)"
rm -rf "$RUNTIME_ROOT"

log "down complete"

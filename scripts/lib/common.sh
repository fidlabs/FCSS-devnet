# Shared path defaults and helpers for porep-curio-devnet scripts.
# Source from a script under scripts/:  source "${SCRIPT_DIR}/lib/common.sh"
#
# Safe to source multiple times. Does not enable set -e (caller owns that).
# Compatible with macOS /bin/bash 3.2.

_POREP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_POREP_SCRIPTS_DIR="$(cd "${_POREP_LIB_DIR}/.." && pwd)"

: "${SCRIPT_DIR:=${_POREP_SCRIPTS_DIR}}"
: "${REPO_ROOT:=$(cd "${_POREP_SCRIPTS_DIR}/.." && pwd)}"

: "${CURIO_DIR:=${REPO_ROOT}/extern/curio}"
: "${POREP_MARKET_DIR:=${REPO_ROOT}/extern/porep-market}"
: "${TOOLING_DIR:=${REPO_ROOT}/extern/filecoin-porep-market-tooling}"
: "${CURIO_DOCKER_DIR:=${CURIO_DIR}/docker}"
: "${CONTRACTS_DIR:=${CURIO_CONTRACTS_DIR:-${CURIO_DOCKER_DIR}/data/contracts}}"
: "${CURIO_CONTRACTS_DIR:=${CONTRACTS_DIR}}"

# Prefer RPC_URL; accept legacy aliases.
: "${RPC_URL:=${RPC:-${CURIO_RPC_URL:-${PAY_RPC_URL:-http://127.0.0.1:1234/rpc/v1}}}}"
: "${RPC:=${RPC_URL}}"
: "${PAY_RPC_URL:=${RPC_URL}}"
: "${CURIO_RPC_URL:=${RPC_URL}}"

: "${LOTUS_CONTAINER:=lotus}"
: "${LOTUS_MINER_CONTAINER:=lotus-miner}"
: "${CURIO_CONTAINER:=curio}"
: "${CURIO_COMPOSE_DIR:=${CURIO_DOCKER_DIR}}"
: "${CURIO_COMPOSE_PROJECT:=curio-devnet}"
: "${CURIO_COMPOSE_SERVICE:=curio}"
: "${ENV_FILE:=${TOOLING_DIR}/.env}"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_file() {
  [[ -f "$1" ]] || die "missing required file: $1"
}

require_container() {
  docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -qx true \
    || die "docker container '$1' is not running"
}

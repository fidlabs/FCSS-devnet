# Shared path defaults and helpers for porep-curio-devnet scripts.
# Source from a script under scripts/<mod>/:
#   source "${SCRIPT_DIR}/../lib/common.sh"
#
# Safe to source multiple times. Does not enable set -e (caller owns that).
# Compatible with macOS /bin/bash 3.2.
# REPO_ROOT / SCRIPTS_DIR are derived from this file's location (not the caller).

_POREP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_POREP_SCRIPTS_DIR="$(cd "${_POREP_LIB_DIR}/.." && pwd)"

: "${SCRIPTS_DIR:=${_POREP_SCRIPTS_DIR}}"
: "${REPO_ROOT:=$(cd "${_POREP_SCRIPTS_DIR}/.." && pwd)}"
# Caller may set SCRIPT_DIR to its own directory; default to scripts/.
: "${SCRIPT_DIR:=${_POREP_SCRIPTS_DIR}}"

: "${CURIO_DIR:=${REPO_ROOT}/extern/curio}"
: "${POREP_MARKET_DIR:=${REPO_ROOT}/extern/porep-market}"
: "${TOOLING_DIR:=${REPO_ROOT}/extern/filecoin-porep-market-tooling}"
: "${HYPERION_DIR:=${REPO_ROOT}/extern/hyperion}"
: "${CURIO_DOCKER_DIR:=${CURIO_DIR}/docker}"
: "${CONTRACTS_DIR:=${CURIO_CONTRACTS_DIR:-${CURIO_DOCKER_DIR}/data/contracts}}"
: "${CURIO_CONTRACTS_DIR:=${CONTRACTS_DIR}}"
: "${CURIO_CLI:=${SCRIPTS_DIR}/curio/cli.sh}"

# Host port map + default RPC/API URLs (FCSS isolated ports).
# shellcheck source=ports.sh
source "${_POREP_LIB_DIR}/ports.sh"

# Prefer RPC_URL; accept legacy aliases (ports.sh already set a default).
: "${RPC_URL:=${RPC:-${CURIO_RPC_URL:-${RPC_URL}}}}"
: "${RPC:=${RPC_URL}}"
: "${CURIO_RPC_URL:=${RPC_URL}}"

# shellcheck source=runtime.sh
source "${_POREP_LIB_DIR}/runtime.sh"
# shellcheck source=deployment.sh
source "${_POREP_LIB_DIR}/deployment.sh"

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

# Prefer DIR/.nvmrc (else $2) via nvm when the active Node is outside engines.
# Usage: ensure_node_version DIR [fallback_version]
ensure_node_version() {
  local dir="$1"
  local fallback="${2:-}"
  local wanted nvm_sh
  require_cmd node

  if [[ -f "${dir}/.nvmrc" ]]; then
    wanted="$(tr -d '[:space:]v' <"${dir}/.nvmrc")"
  else
    wanted="$(tr -d '[:space:]v' <<<"${fallback}")"
  fi
  [[ -n "$wanted" ]] || die "ensure_node_version: no .nvmrc in ${dir} and no fallback version"

  if node -e "
    const want = process.argv[1].split('.').map(Number);
    const have = process.versions.node.split('.').map(Number);
    for (let i = 0; i < 3; i++) {
      const w = want[i] || 0, h = have[i] || 0;
      if (h > w) process.exit(0);
      if (h < w) process.exit(1);
    }
    process.exit(0);
  " "$wanted" 2>/dev/null; then
    return 0
  fi

  nvm_sh="${NVM_DIR:-${HOME}/.nvm}/nvm.sh"
  [[ -s "$nvm_sh" ]] || die "need Node ${wanted}+ (have $(node -v)); install with nvm: nvm install ${wanted} && nvm use ${wanted}"

  log "Node $(node -v) is below ${wanted}; switching via nvm"
  # shellcheck disable=SC1090
  source "$nvm_sh"
  nvm use "$wanted" >/dev/null || die "nvm use ${wanted} failed (try: nvm install ${wanted})"
  log "using Node $(node -v) / npm $(npm -v 2>/dev/null || echo '?')"
}

require_container() {
  docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -qx true \
    || die "docker container '$1' is not running"
}

# Reset a submodule working tree to the gitlink commit and apply *.patch files.
# Usage: apply_patches TARGET_DIR PATCH_DIR LABEL [git_clean_extra_args...]
# Extra args are passed to `git clean -fd` (e.g. -e .env -e node_modules).
apply_patches() {
  local target_dir="$1" patch_dir="$2" label="$3"
  local patches patch
  shift 3

  [[ -d "$target_dir" ]] || die "${label} submodule missing at ${target_dir}"
  [[ -d "$patch_dir" ]] || die "missing patch dir ${patch_dir}"

  log "resetting ${label} working tree to pinned submodule commit"
  git -C "$target_dir" reset --hard HEAD
  git -C "$target_dir" clean -fd "$@"
  # Nested submodule working trees (e.g. curio/extern/filecoin-ffi) are not
  # reset by the parent reset --hard; dirty nested files break patches that
  # edit them. Sync nested checkouts to the gitlink commits, then hard-reset.
  if [[ -f "$target_dir/.gitmodules" ]]; then
    git -C "$target_dir" submodule sync --recursive >/dev/null
    git -C "$target_dir" submodule update --init --recursive
    git -C "$target_dir" submodule foreach --recursive 'git reset --hard HEAD && git clean -fd' >/dev/null
  fi

  log "applying ${label} patches from ${patch_dir#"$REPO_ROOT"/}"
  shopt -s nullglob
  patches=("$patch_dir"/*.patch)
  [[ ${#patches[@]} -gt 0 ]] || die "no *.patch files in ${patch_dir}"
  for patch in "${patches[@]}"; do
    log "  $(basename "$patch")"
    git -C "$target_dir" apply --whitespace=nowarn "$patch" \
      || die "failed to apply ${patch#"$REPO_ROOT"/}"
  done
  shopt -u nullglob

  log "${label} local diff after patches:"
  git -C "$target_dir" --no-pager diff --stat
}

#!/usr/bin/env bash
# Apply Curio patches, prepare contracts-bootstrap local-src, build docker/devnet images.
#
# When Curio is itself a submodule, `.git` is a gitdir pointer into the
# superproject. Inside the image that path does not exist, so any
# `git submodule update` during `docker/devnet` fails. Working-tree fixes
# live in patches/curio/.
#
# Usage (from repo root):
#   ./scripts/curio/init.sh
#   just curio init
#
# Env:
#   CURIO_DIR / SKIP_DOCKER=1
#
# Idempotent: resets Curio to pinned commit, re-applies patches,
# ensures local-src checkouts, then rebuilds images unless SKIP_DOCKER=1.
# Run `git submodule update --init --recursive` first (just init does this).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

CURIO_PATCH_DIR="${CURIO_PATCH_DIR:-${REPO_ROOT}/patches/curio}"
SKIP_DOCKER="${SKIP_DOCKER:-0}"

# From extern/curio/docker/local-src/README.md — needed when CONTRACT_SOURCE_MODE=local.
prepare_curio_local_src() {
  local local_src="${CURIO_DIR}/docker/local-src"
  mkdir -p "$local_src"

  log "preparing Curio docker/local-src (contracts-bootstrap mounts)"

  if [[ -d "${local_src}/filecoin-services/service_contracts" ]]; then
    log "  filecoin-services already present"
  else
    log "  cloning filecoin-services @ v1.1.0"
    rm -rf "${local_src}/filecoin-services"
    git clone --branch v1.1.0 --depth 1 \
      https://github.com/FilOzone/filecoin-services.git \
      "${local_src}/filecoin-services"
    git -C "${local_src}/filecoin-services" submodule update --init --recursive
  fi

  if [[ -d "${local_src}/multicall3/.git" ]]; then
    log "  multicall3 already present"
  else
    log "  cloning multicall3"
    rm -rf "${local_src}/multicall3"
    git clone --depth 1 \
      https://github.com/mds1/multicall3.git \
      "${local_src}/multicall3"
    git -C "${local_src}/multicall3" submodule update --init --recursive
  fi

  [[ -d "${local_src}/filecoin-services/service_contracts" ]] \
    || die "filecoin-services missing service_contracts after clone"
}

cd "$REPO_ROOT"

[[ -d "$CURIO_DIR" ]] || die "Curio submodule missing at ${CURIO_DIR} (run: git submodule update --init --recursive)"

# Discard prior local patches so re-runs are deterministic.
# Do not use `git clean -x` on Curio — that would wipe docker/local-src mounts.
apply_patches "$CURIO_DIR" "$CURIO_PATCH_DIR" "Curio"

prepare_curio_local_src

[[ -d "${CURIO_DIR}/extern/filecoin-ffi" ]] \
  || die "curio/extern/filecoin-ffi missing after submodule update"

log "Curio submodule ready"

if [[ "$SKIP_DOCKER" == "1" ]]; then
  log "SKIP_DOCKER=1 — not running make docker/devnet"
  exit 0
fi

require_cmd make
require_cmd docker

log "make docker/devnet (in ${CURIO_DIR#"$REPO_ROOT"/})"
make -C "$CURIO_DIR" docker/devnet

log "done — Curio docker/devnet images built"

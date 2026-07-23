#!/usr/bin/env bash
# Initialize all git submodules, apply local patches, prepare Curio
# contracts-bootstrap local-src, then build Curio docker/devnet images.
#
# When Curio is itself a submodule, `.git` is a gitdir pointer into the
# superproject. Inside the image that path does not exist, so any
# `git submodule update` during `docker/devnet` fails. Working-tree fixes
# live in patches/curio/ and patches/filecoin-porep-market-tooling/.
#
# Usage (from repo root):
#   ./scripts/init.sh
#   just init
#
# Env:
#   CURIO_DIR / TOOLING_DIR / SKIP_DOCKER=1
#
# Idempotent: resets Curio/tooling to pinned commits, re-applies patches,
# ensures local-src checkouts, then rebuilds images unless SKIP_DOCKER=1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

CURIO_PATCH_DIR="${CURIO_PATCH_DIR:-${REPO_ROOT}/patches/curio}"
TOOLING_PATCH_DIR="${TOOLING_PATCH_DIR:-${REPO_ROOT}/patches/filecoin-porep-market-tooling}"
SKIP_DOCKER="${SKIP_DOCKER:-0}"

# Reset a submodule working tree to the gitlink commit and apply *.patch files.
apply_patches() {
  local target_dir="$1" patch_dir="$2" label="$3"
  local patches patch

  [[ -d "$target_dir" ]] || die "${label} submodule missing at ${target_dir}"
  [[ -d "$patch_dir" ]] || die "missing patch dir ${patch_dir}"

  log "resetting ${label} working tree to pinned submodule commit"
  git -C "$target_dir" reset --hard HEAD
  git -C "$target_dir" clean -fd

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

[[ -f .gitmodules ]] || die "no .gitmodules in ${REPO_ROOT} (run from this repo)"

log "git submodule update --init --recursive"
git submodule update --init --recursive

# Discard prior local patches so re-runs are deterministic.
# Do not use `git clean -x` on Curio — that would wipe docker/local-src mounts.
apply_patches "$CURIO_DIR" "$CURIO_PATCH_DIR" "Curio"
apply_patches "$TOOLING_DIR" "$TOOLING_PATCH_DIR" "filecoin-porep-market-tooling"

prepare_curio_local_src

[[ -d "${CURIO_DIR}/extern/filecoin-ffi" ]] \
  || die "curio/extern/filecoin-ffi missing after submodule update"

log "submodules ready"
git submodule status --recursive

if [[ "$SKIP_DOCKER" == "1" ]]; then
  log "SKIP_DOCKER=1 — not running make docker/devnet"
  exit 0
fi

require_cmd make
require_cmd docker

log "make docker/devnet (in ${CURIO_DIR#"$REPO_ROOT"/})"
make -C "$CURIO_DIR" docker/devnet

log "done — Curio docker/devnet images built"

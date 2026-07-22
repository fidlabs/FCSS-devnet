#!/usr/bin/env bash
# Initialize all git submodules, apply local Curio patches for nested-submodule
# docker/devnet, prepare contracts-bootstrap local-src, then build Curio
# docker/devnet images.
#
# When Curio is itself a submodule, `.git` is a gitdir pointer into the
# superproject. Inside the image that path does not exist, so any
# `git submodule update` during `docker/devnet` fails. Working-tree fixes
# (compose host.docker.internal, IPNI null-head, Dockerfile/deps skips)
# live in patches/curio/ and are applied here after a clean Curio checkout.
#
# Also clones Curio docker/local-src/{filecoin-services,multicall3} as documented
# in extern/curio/docker/local-src/README.md (CONTRACT_SOURCE_MODE=local).
#
# Usage (from repo root):
#   ./scripts/setup-submodules.sh
#
# Env:
#   CURIO_DIR   Path to curio submodule (default: ./extern/curio)
#   SKIP_DOCKER If set to 1, skip `make docker/devnet`
#
# Idempotent: resets Curio to the pinned submodule commit, re-applies patches,
# ensures local-src checkouts, then rebuilds images unless SKIP_DOCKER=1.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly CURIO_DIR="${CURIO_DIR:-${REPO_ROOT}/extern/curio}"
readonly PATCH_DIR="${PATCH_DIR:-${REPO_ROOT}/patches/curio}"
readonly SKIP_DOCKER="${SKIP_DOCKER:-0}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

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
[[ -d "$PATCH_DIR" ]] || die "missing patch dir ${PATCH_DIR}"

log "git submodule update --init --recursive"
git submodule update --init --recursive

[[ -d "$CURIO_DIR" ]] || die "curio submodule missing at ${CURIO_DIR}"

# Discard prior local Curio patches so re-runs are deterministic.
# Do not use `git clean -x` — that would wipe docker/local-src mounts.
log "resetting Curio working tree to pinned submodule commit"
git -C "$CURIO_DIR" reset --hard HEAD
git -C "$CURIO_DIR" clean -fd

log "applying Curio patches from ${PATCH_DIR#"$REPO_ROOT"/}"
shopt -s nullglob
patches=("$PATCH_DIR"/*.patch)
[[ ${#patches[@]} -gt 0 ]] || die "no *.patch files in ${PATCH_DIR}"
for patch in "${patches[@]}"; do
  log "  $(basename "$patch")"
  git -C "$CURIO_DIR" apply --whitespace=nowarn "$patch" \
    || die "failed to apply ${patch#"$REPO_ROOT"/}"
done
shopt -u nullglob

prepare_curio_local_src

# Sanity: nested sources needed by the Curio image build must exist on the host.
[[ -d "${CURIO_DIR}/extern/filecoin-ffi" ]] \
  || die "curio/extern/filecoin-ffi missing after submodule update"

log "submodules ready"
git submodule status --recursive
log "Curio local diff after patches:"
git -C "$CURIO_DIR" --no-pager diff --stat

if [[ "$SKIP_DOCKER" == "1" ]]; then
  log "SKIP_DOCKER=1 — not running make docker/devnet"
  exit 0
fi

command -v make >/dev/null 2>&1 || die "missing required command: make"
command -v docker >/dev/null 2>&1 || die "missing required command: docker"

log "make docker/devnet (in ${CURIO_DIR#"$REPO_ROOT"/})"
make -C "$CURIO_DIR" docker/devnet

log "done — Curio docker/devnet images built"

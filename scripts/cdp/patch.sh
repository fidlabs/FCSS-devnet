#!/usr/bin/env bash
# Reset compliance-data-platform to the pinned submodule commit and apply
# patches/cdp/*.patch (Curio local chain + genesis origin + PORT).
#
# Usage:
#   ./scripts/cdp/patch.sh
#   just cdp patch
#
# Preserves .env, node_modules, and dist across reset/clean.
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

: "${CDP_DIR:=${REPO_ROOT}/extern/compliance-data-platform}"
CDP_PATCH_DIR="${CDP_PATCH_DIR:-${REPO_ROOT}/patches/cdp}"

cd "$REPO_ROOT"

apply_patches "$CDP_DIR" "$CDP_PATCH_DIR" "cdp" \
  -e .env \
  -e node_modules \
  -e dist \
  -e prisma/generated \
  -e prismaDmob/generated

log "cdp patches applied"

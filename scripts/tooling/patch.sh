#!/usr/bin/env bash
# Reset filecoin-porep-market-tooling to the pinned submodule commit and apply
# patches/tooling/*.patch (local V2 FEVM / submit-evidence helpers).
#
# Usage:
#   ./scripts/tooling/patch.sh
#   just tooling patch
#
# Preserves .env, .venv, and .env.bak* across reset/clean.
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

: "${TOOLING_DIR:=${REPO_ROOT}/extern/filecoin-porep-market-tooling}"
TOOLING_PATCH_DIR="${TOOLING_PATCH_DIR:-${REPO_ROOT}/patches/tooling}"

cd "$REPO_ROOT"

apply_patches "$TOOLING_DIR" "$TOOLING_PATCH_DIR" "tooling" \
  -e .env \
  -e .venv \
  -e '.env.bak*'

log "tooling patches applied"

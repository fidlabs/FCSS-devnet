#!/usr/bin/env bash
# Reset hyperion to the pinned submodule commit and apply
# patches/hyperion/*.patch (Curio local chain + genesis origin + PORT).
#
# Usage:
#   ./scripts/hyperion/patch.sh
#   just hyperion patch
#
# Preserves .env, .env.bak*, node_modules, and dist across reset/clean.
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

: "${HYPERION_DIR:=${REPO_ROOT}/extern/hyperion}"
HYPERION_PATCH_DIR="${HYPERION_PATCH_DIR:-${REPO_ROOT}/patches/hyperion}"

cd "$REPO_ROOT"

apply_patches "$HYPERION_DIR" "$HYPERION_PATCH_DIR" "hyperion" \
  -e .env \
  -e '.env.bak*' \
  -e node_modules \
  -e dist \
  -e src/generated \
  -e src/db/auto-generated \
  -e prisma/generated

log "hyperion patches applied"

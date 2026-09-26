#!/usr/bin/env bash
# Reset filecoin-oracle-service to the pinned submodule commit and apply
# patches/oracle/*.patch (local Curio chain + enable cron schedules).
#
# Usage:
#   ./scripts/oracle/patch.sh
#   just oracle patch
#
# Preserves .env, node_modules, dist, and prisma/generated across reset/clean.
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

: "${ORACLE_DIR:=${REPO_ROOT}/extern/filecoin-oracle-service}"
ORACLE_PATCH_DIR="${ORACLE_PATCH_DIR:-${REPO_ROOT}/patches/oracle}"

cd "$REPO_ROOT"

apply_patches "$ORACLE_DIR" "$ORACLE_PATCH_DIR" "oracle" \
  -e .env \
  -e node_modules \
  -e dist \
  -e prisma/generated

log "oracle patches applied"

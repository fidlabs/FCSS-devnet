#!/usr/bin/env bash
# Point ACTIVE at an existing immutable deployment record and mirror latest.json.
# Does not change on-chain state.
#
# Usage:
#   ./scripts/porep-market/use-deployment.sh deployment-20260729T180000Z-b1c728e
#   just porep-market use-deployment deployment-...
#
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/deployment.sh
source "${SCRIPT_DIR}/../lib/deployment.sh"

usage() {
  cat <<EOF
Usage: use-deployment.sh <record-name>

Record dirs live under:
  ${DEPLOYMENT_RECORDS_DIR#"$REPO_ROOT"/}/

List with: ls ${DEPLOYMENT_RECORDS_DIR#"$REPO_ROOT"/}
EOF
}

[[ $# -ge 1 ]] || { usage; exit 2; }
case "$1" in
  -h|--help) usage; exit 0 ;;
esac

use_deployment_record "$1"
log "done — consumers should refresh envs (just porep-market up / just hyperion up --force)"

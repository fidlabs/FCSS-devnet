#!/usr/bin/env bash
# Ensure the filecoin-porep-market-tooling Python venv is ready.
#
# Usage (from repo root):
#   ./scripts/tooling/init.sh
#   just tooling init
#
# Env:
#   TOOLING_DIR / SKIP_VENV=1
#
# Idempotent: creates .venv and pip-installs requirements unless SKIP_VENV=1.
# Run `git submodule update --init --recursive` first (just init does this).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

SKIP_VENV="${SKIP_VENV:-0}"

cd "$REPO_ROOT"

[[ -d "$TOOLING_DIR" ]] || die "tooling submodule missing at ${TOOLING_DIR} (run: git submodule update --init --recursive)"
[[ -f "${TOOLING_DIR}/porep_tooling_cli.py" ]] || die "porep_tooling_cli.py missing in ${TOOLING_DIR}"

log "tooling submodule ready at ${TOOLING_DIR#"$REPO_ROOT"/}"

if [[ "$SKIP_VENV" == "1" ]]; then
  log "SKIP_VENV=1 — not creating/updating Python venv"
  exit 0
fi

require_cmd python3

if [[ ! -x "${TOOLING_DIR}/.venv/bin/python" ]]; then
  log "creating ${TOOLING_DIR#"$REPO_ROOT"/}/.venv"
  python3 -m venv "${TOOLING_DIR}/.venv"
fi

require_file "${TOOLING_DIR}/requirements.txt"
log "pip install -r ${TOOLING_DIR#"$REPO_ROOT"/}/requirements.txt"
"${TOOLING_DIR}/.venv/bin/pip" install -r "${TOOLING_DIR}/requirements.txt"

log "done — tooling venv ready"

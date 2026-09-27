#!/usr/bin/env bash
# Print a one-shot status of the local FCSS-devnet stack.
#
# Usage:
#   ./scripts/status.sh
#   just status
#
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/deployment.sh
source "${SCRIPT_DIR}/lib/deployment.sh"

ok() { printf 'OK   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }

check_rpc() {
  local out
  if out="$(curl -sf -m 5 -X POST "$RPC_URL" \
      -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","method":"Filecoin.ChainHead","params":[],"id":1}' 2>/dev/null)"; then
    local h
    h="$(printf '%s' "$out" | jq -r '.result.Height // empty' 2>/dev/null || true)"
    ok "Lotus RPC ${RPC_URL} (height=${h:-?})"
  else
    bad "Lotus RPC ${RPC_URL}"
  fi
}

check_http() {
  local name="$1" url="$2"
  if curl -sf -m 5 -o /dev/null "$url" 2>/dev/null; then
    ok "${name} ${url}"
  else
    bad "${name} ${url}"
  fi
}

check_tcp() {
  local name="$1" host="$2" port="$3"
  if (echo >/dev/tcp/"$host"/"$port") >/dev/null 2>&1; then
    ok "${name} ${host}:${port}"
  else
    # /dev/tcp may be unavailable; fall back to nc or curl.
    if command -v nc >/dev/null 2>&1 && nc -z -G 2 "$host" "$port" >/dev/null 2>&1; then
      ok "${name} ${host}:${port}"
    else
      bad "${name} ${host}:${port}"
    fi
  fi
}

printf 'FCSS-devnet status\n'
printf 'RPC_URL=%s\n' "$RPC_URL"
printf '\n'

check_rpc
check_http "Curio market" "${CURIO_MARKET_URL}/"
check_http "Curio UI" "${CURIO_UI_URL}/" || true
check_tcp "Curio API" "$FCSS_HOST" "$FCSS_CURIO_API_HOST_PORT"
check_tcp "Hyperion Postgres" "$FCSS_HOST" "$FCSS_HYPERION_PG_HOST_PORT"
check_http "Hyperion app" "${HYPERION_APP_URL}/" || check_tcp "Hyperion app" "$FCSS_HOST" "$FCSS_HYPERION_APP_HOST_PORT"

printf '\n'
if active="$(active_latest_json 2>/dev/null)"; then
  ok "deployment manifest ${active#"$REPO_ROOT"/}"
  if [[ -f "$DEPLOYMENT_ACTIVE_FILE" ]]; then
    ok "ACTIVE=$(tr -d '[:space:]' <"$DEPLOYMENT_ACTIVE_FILE")"
  else
    warn "ACTIVE pointer missing (using latest.json only)"
  fi
else
  bad "no deployment manifest (ACTIVE/latest.json)"
fi

printf '\n'
if "${SCRIPT_DIR}/pins/verify.sh" >/tmp/fcss-pin-verify.out 2>&1; then
  ok "pin-verify"
else
  warn "pin-verify failed (non-fatal for status):"
  sed 's/^/  /' /tmp/fcss-pin-verify.out | tail -n 20 || true
fi

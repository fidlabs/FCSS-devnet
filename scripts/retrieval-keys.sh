#!/usr/bin/env bash
# Extract CLIENT_PRIVATE_KEY / SP_PRIVATE_KEY from tooling .env into key files
# for retrieval-client and sp-proxy.
#
# Usage (from repo root):
#   ./scripts/retrieval-keys.sh
#
# Overrides:
#   ENV_FILE     path to .env (default ./extern/filecoin-porep-market-tooling/.env)
#   CLIENT_KEY   output path (default ../large-paid-retrievals/client.key)
#   SP_KEY       output path (default ../large-paid-retrievals/sp.key)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/envfile.sh
source "${SCRIPT_DIR}/lib/envfile.sh"

CLIENT_KEY="${CLIENT_KEY:-${REPO_ROOT}/../large-paid-retrievals/client.key}"
SP_KEY="${SP_KEY:-${REPO_ROOT}/../large-paid-retrievals/sp.key}"

require_file "$ENV_FILE"

write_key() {
  local out="$1" hex="$2"
  umask 077
  printf '%s\n' "$hex" >"$out"
  chmod 600 "$out"
}

CLIENT_RAW="$(env_get CLIENT_PRIVATE_KEY)" || die "missing CLIENT_PRIVATE_KEY in ${ENV_FILE}"
SP_RAW="$(env_get SP_PRIVATE_KEY)" || die "missing SP_PRIVATE_KEY in ${ENV_FILE}"
CLIENT_HEX="$(normalize_hex_key "$CLIENT_RAW")"
SP_HEX="$(normalize_hex_key "$SP_RAW")"

write_key "$CLIENT_KEY" "$CLIENT_HEX"
write_key "$SP_KEY" "$SP_HEX"

if command -v cast >/dev/null 2>&1; then
  echo "wrote $CLIENT_KEY  ($(cast wallet address --private-key "0x$CLIENT_HEX"))"
  echo "wrote $SP_KEY      ($(cast wallet address --private-key "0x$SP_HEX"))"
else
  echo "wrote $CLIENT_KEY"
  echo "wrote $SP_KEY"
fi

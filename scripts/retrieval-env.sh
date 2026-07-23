# Source this file to export Curio / PoRep Market env for local sp-proxy + retrieval-client.
#
# Usage (from repo root):
#   source ./scripts/retrieval-env.sh
#
# Then e.g.:
#   ../large-paid-retrievals/bin/sp-proxy ... --pay-payments-address "$PAYMENTS" --pay-token-address "$USDFC" \
#     --porep-market-address "$POREP_MARKET" --porep-provider-id "$POREP_PROVIDER_ID"
#
# Overrides (set before sourcing):
#   CONTRACTS_DIR / POREP_ENV_FILE / PAY_RPC_URL (or RPC_URL)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "source this script: source ${BASH_SOURCE[0]}" >&2
  exit 1
fi

_retrieval_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${_retrieval_script_dir}/lib/common.sh"
# When sourced, die must not exit the interactive shell.
die() { printf 'retrieval-env: %s\n' "$*" >&2; return 1; }
# shellcheck source=lib/envfile.sh
source "${_retrieval_script_dir}/lib/envfile.sh"

_retrieval_porep_env="${POREP_ENV_FILE:-${ENV_FILE}}"
_retrieval_contracts_json="${CONTRACTS_DIR}/contract_addresses.json"

_retrieval_piece_cid() {
  local provider_id="$1" rpc="$2" provider resp
  provider="f0${provider_id}"
  resp="$(curl -sS -X POST "$rpc" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"Filecoin.StateGetClaims\",\"params\":[\"${provider}\", null]}")" || return 1
  if jq -e '.error' >/dev/null 2>&1 <<<"$resp"; then
    echo "retrieval-env: StateGetClaims(${provider}): $(jq -r '.error.message // .error' <<<"$resp")" >&2
    return 1
  fi
  jq -r '
    .result
    | to_entries
    | sort_by(.key | tonumber)
    | .[].value.Data["/"]
    | select(. != null and . != "")
  ' <<<"$resp" | head -n1
}

command -v jq >/dev/null 2>&1 || { die "jq is required"; return 1; }
command -v curl >/dev/null 2>&1 || { die "curl is required"; return 1; }
[[ -f "$_retrieval_contracts_json" ]] || { die "missing $_retrieval_contracts_json"; return 1; }
[[ -f "$_retrieval_porep_env" ]] || { die "missing $_retrieval_porep_env"; return 1; }

export PAYMENTS
export USDFC
export POREP_MARKET
export POREP_PROVIDER_ID
export PIECE_CID
export PAY_RPC_URL="${PAY_RPC_URL:-$RPC_URL}"

PAYMENTS="$(jq -r '.contracts.filecoin_pay_v1 // empty' "$_retrieval_contracts_json")"
USDFC="$(jq -r '.contracts.usdfc // empty' "$_retrieval_contracts_json")"
POREP_MARKET="$(ENV_FILE="$_retrieval_porep_env" env_get POREP_MARKET)" || { die "POREP_MARKET missing in $_retrieval_porep_env"; return 1; }

_miner_id="$(ENV_FILE="$_retrieval_porep_env" env_get CURIO_MINER_ID)" || { die "CURIO_MINER_ID missing in $_retrieval_porep_env"; return 1; }
if [[ "$_miner_id" =~ ^[tTfF]0*([0-9]+)$ ]]; then
  POREP_PROVIDER_ID=$((10#${BASH_REMATCH[1]}))
elif [[ "$_miner_id" =~ ^([0-9]+)$ ]]; then
  POREP_PROVIDER_ID=$((10#${BASH_REMATCH[1]}))
else
  die "could not parse provider id from CURIO_MINER_ID=$_miner_id"
  return 1
fi
[[ "$POREP_PROVIDER_ID" -gt 0 ]] || { die "invalid provider id from CURIO_MINER_ID=$_miner_id"; return 1; }

[[ "$PAYMENTS" =~ ^0x[0-9a-fA-F]{40}$ ]] || { die "invalid filecoin_pay_v1: $PAYMENTS"; return 1; }
[[ "$USDFC" =~ ^0x[0-9a-fA-F]{40}$ ]] || { die "invalid usdfc: $USDFC"; return 1; }
[[ "$POREP_MARKET" =~ ^0x[0-9a-fA-F]{40}$ ]] || { die "invalid POREP_MARKET: $POREP_MARKET"; return 1; }

PIECE_CID="$(_retrieval_piece_cid "$POREP_PROVIDER_ID" "$PAY_RPC_URL")" || true
[[ -n "${PIECE_CID:-}" ]] || { die "no VerifReg claim piece CID for provider $POREP_PROVIDER_ID (has a deal been claimed?)"; return 1; }

export SP_PROXY_PAY_PAYMENTS_ADDRESS="$PAYMENTS"
export SP_PROXY_PAY_TOKEN_ADDRESS="$USDFC"
export SP_PROXY_PAY_RPC_URL="$PAY_RPC_URL"
export SP_PROXY_POREP_MARKET_ADDRESS="$POREP_MARKET"
export SP_PROXY_POREP_PROVIDER_ID="$POREP_PROVIDER_ID"

echo "PAYMENTS=$PAYMENTS"
echo "USDFC=$USDFC"
echo "POREP_MARKET=$POREP_MARKET"
echo "POREP_PROVIDER_ID=$POREP_PROVIDER_ID"
echo "PIECE_CID=$PIECE_CID"
echo "PAY_RPC_URL=$PAY_RPC_URL"

unset -f _retrieval_piece_cid
unset _retrieval_script_dir _retrieval_porep_env _retrieval_contracts_json _miner_id

# Source this file to export Curio / PoRep Market env for local sp-proxy + retrieval-client.
#
# Usage (from repo root):
#   source ./scripts/devnet-env.sh
#
# Then e.g.:
#   ../large-paid-retrievals/bin/sp-proxy ... --pay-payments-address "$PAYMENTS" --pay-token-address "$USDFC" \
#     --porep-market-address "$POREP_MARKET" --porep-provider-id "$POREP_PROVIDER_ID"
#   ../large-paid-retrievals/bin/retrieval-client fetch ... --cid "$PIECE_CID" --pay-payments-address "$PAYMENTS" ...
#
# Overrides (set before sourcing):
#   CONTRACTS_DIR   Curio contracts dir (default ../curio/docker/data/contracts)
#   POREP_ENV_FILE  market-tooling .env (default ../filecoin-porep-market-tooling/.env)
#   PAY_RPC_URL     Lotus FEVM RPC (default http://127.0.0.1:1234/rpc/v1)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "source this script: source ${BASH_SOURCE[0]}" >&2
  exit 1
fi

_devnet_env_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_devnet_contracts_dir="${CONTRACTS_DIR:-$_devnet_env_root/../curio/docker/data/contracts}"
_devnet_porep_env="${POREP_ENV_FILE:-$_devnet_env_root/../filecoin-porep-market-tooling/.env}"
_devnet_contracts_json="$_devnet_contracts_dir/contract_addresses.json"

_devnet_env_fail() {
  echo "devnet-env: $*" >&2
  unset -f _devnet_env_fail _devnet_env_get _devnet_env_piece_cid
  unset _devnet_env_root _devnet_contracts_dir _devnet_porep_env _devnet_contracts_json _miner_id
  return 1
}

_devnet_env_get() {
  local key="$1" file="$2" line val
  line="$(grep -E "^${key}=" "$file" | tail -n1 || true)"
  [[ -n "$line" ]] || return 1
  val="${line#*=}"
  if [[ "$val" =~ ^\".*\"$ ]]; then
    val="${val:1:${#val}-2}"
  elif [[ "$val" =~ ^\'.*\'$ ]]; then
    val="${val:1:${#val}-2}"
  fi
  printf '%s' "$(printf '%s' "$val" | tr -d ' \t\r\n')"
}

# First VerifReg claim piece CID for this provider (on-chain deal piece).
_devnet_env_piece_cid() {
  local provider_id="$1" rpc="$2" provider resp
  provider="f0${provider_id}"
  resp="$(curl -sS -X POST "$rpc" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"Filecoin.StateGetClaims\",\"params\":[\"${provider}\", null]}")" || return 1
  if jq -e '.error' >/dev/null 2>&1 <<<"$resp"; then
    echo "devnet-env: StateGetClaims(${provider}): $(jq -r '.error.message // .error' <<<"$resp")" >&2
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

command -v jq >/dev/null 2>&1 || { _devnet_env_fail "jq is required"; return 1; }
command -v curl >/dev/null 2>&1 || { _devnet_env_fail "curl is required"; return 1; }
[[ -f "$_devnet_contracts_json" ]] || { _devnet_env_fail "missing $_devnet_contracts_json"; return 1; }
[[ -f "$_devnet_porep_env" ]] || { _devnet_env_fail "missing $_devnet_porep_env"; return 1; }

export PAYMENTS
export USDFC
export POREP_MARKET
export POREP_PROVIDER_ID
export PIECE_CID
export PAY_RPC_URL="${PAY_RPC_URL:-http://127.0.0.1:1234/rpc/v1}"

PAYMENTS="$(jq -r '.contracts.filecoin_pay_v1 // empty' "$_devnet_contracts_json")"
USDFC="$(jq -r '.contracts.usdfc // empty' "$_devnet_contracts_json")"
POREP_MARKET="$(_devnet_env_get POREP_MARKET "$_devnet_porep_env")" || { _devnet_env_fail "POREP_MARKET missing in $_devnet_porep_env"; return 1; }

_miner_id="$(_devnet_env_get CURIO_MINER_ID "$_devnet_porep_env")" || { _devnet_env_fail "CURIO_MINER_ID missing in $_devnet_porep_env"; return 1; }
# t01003 / f01003 → 1003
if [[ "$_miner_id" =~ ^[tTfF]0*([0-9]+)$ ]]; then
  POREP_PROVIDER_ID=$((10#${BASH_REMATCH[1]}))
elif [[ "$_miner_id" =~ ^([0-9]+)$ ]]; then
  POREP_PROVIDER_ID=$((10#${BASH_REMATCH[1]}))
else
  _devnet_env_fail "could not parse provider id from CURIO_MINER_ID=$_miner_id"
  return 1
fi
[[ "$POREP_PROVIDER_ID" -gt 0 ]] || { _devnet_env_fail "invalid provider id from CURIO_MINER_ID=$_miner_id"; return 1; }

[[ "$PAYMENTS" =~ ^0x[0-9a-fA-F]{40}$ ]] || { _devnet_env_fail "invalid filecoin_pay_v1: $PAYMENTS"; return 1; }
[[ "$USDFC" =~ ^0x[0-9a-fA-F]{40}$ ]] || { _devnet_env_fail "invalid usdfc: $USDFC"; return 1; }
[[ "$POREP_MARKET" =~ ^0x[0-9a-fA-F]{40}$ ]] || { _devnet_env_fail "invalid POREP_MARKET: $POREP_MARKET"; return 1; }

PIECE_CID="$(_devnet_env_piece_cid "$POREP_PROVIDER_ID" "$PAY_RPC_URL")" || true
[[ -n "${PIECE_CID:-}" ]] || { _devnet_env_fail "no VerifReg claim piece CID for provider $POREP_PROVIDER_ID (has a deal been claimed?)"; return 1; }

# Also export names sp-proxy reads via getenv when flags are omitted.
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

unset -f _devnet_env_fail _devnet_env_get _devnet_env_piece_cid
unset _devnet_env_root _devnet_contracts_dir _devnet_porep_env _devnet_contracts_json _miner_id

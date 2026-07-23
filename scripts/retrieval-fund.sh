#!/usr/bin/env bash
# Fund retrieval-client / sp-proxy wallets on a local Curio docker-devnet after a chain reset.
#
# Prerequisites: lotus + yugabyte/curio stack running; cast + jq; client.key + sp.key present.
#
# Usage (from repo root):
#   ./scripts/retrieval-fund.sh
#
# Overrides:
#   CLIENT_KEY / SP_KEY, CONTRACTS_DIR, RPC_URL (or RPC), LOTUS_CONTAINER,
#   FIL_AMOUNT, USDFC_AMOUNT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/lotus.sh
source "${SCRIPT_DIR}/lib/lotus.sh"

CLIENT_KEY="${CLIENT_KEY:-${REPO_ROOT}/../large-paid-retrievals/client.key}"
SP_KEY="${SP_KEY:-${REPO_ROOT}/../large-paid-retrievals/sp.key}"
FIL_AMOUNT="${FIL_AMOUNT:-100}"
USDFC_AMOUNT="${USDFC_AMOUNT:-1000}"

require_cmd cast
require_cmd jq
require_cmd docker

require_file "$CLIENT_KEY"
require_file "$SP_KEY"
require_file "$CONTRACTS_DIR/contract_addresses.json"
require_file "$CONTRACTS_DIR/deployer.private-key"

hex_key() {
  tr -d ' \n\r\t' <"$1" | sed 's/^0x//'
}

pk_client="0x$(hex_key "$CLIENT_KEY")"
pk_sp="0x$(hex_key "$SP_KEY")"
CLIENT="$(cast wallet address --private-key "$pk_client")"
SP="$(cast wallet address --private-key "$pk_sp")"
USDFC="$(jq -r '.contracts.usdfc // empty' "$CONTRACTS_DIR/contract_addresses.json")"
DEPLOYER_KEY="$(tr -d '\n\r' <"$CONTRACTS_DIR/deployer.private-key")"

[[ "$USDFC" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "invalid usdfc in contract_addresses.json: $USDFC"
[[ "$DEPLOYER_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "invalid deployer.private-key"

log "client=$CLIENT"
log "sp=$SP"
log "usdfc=$USDFC"
log "rpc=$RPC_URL"

log "sending ${FIL_AMOUNT} FIL to client and sp..."
CID_C="$(lotus send "$CLIENT" "$FIL_AMOUNT" | awk '/^bafy|^bafk/{print $1; exit}')"
CID_S="$(lotus send "$SP" "$FIL_AMOUNT" | awk '/^bafy|^bafk/{print $1; exit}')"
wait_msg_required "$CID_C"
wait_msg_required "$CID_S"

log "client FIL: $(cast balance --ether --rpc-url "$RPC_URL" "$CLIENT")"
log "sp FIL:     $(cast balance --ether --rpc-url "$RPC_URL" "$SP")"

USDFC_BASE_UNITS="$(cast to-wei "$USDFC_AMOUNT" ether)"
log "transferring ${USDFC_AMOUNT} USDFC to client..."
cast send "$USDFC" "transfer(address,uint256)" "$CLIENT" "$USDFC_BASE_UNITS" \
  --rpc-url "$RPC_URL" \
  --private-key "$DEPLOYER_KEY" \
  >/dev/null

BAL="$(cast call "$USDFC" "balanceOf(address)(uint256)" "$CLIENT" --rpc-url "$RPC_URL")"
log "client USDFC (base units): $BAL"
log "done"

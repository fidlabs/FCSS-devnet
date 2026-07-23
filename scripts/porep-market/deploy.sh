#!/usr/bin/env bash
# Deploy PoRep Market contracts on a local Curio docker-devnet:
#   1. write porep-market .env from Curio contract artifacts (gen-env.sh)
#   2. deploy NoOp MetaAllocator (Client.transfer needs a contract, not an EOA)
#   3. just devnet_deploy in porep-market
#
# Prerequisites: docker lotus up, cast, jq, just, forge
#
# Usage:
#   ./scripts/porep-market/deploy.sh
#   just porep-market deploy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/envfile.sh
source "${SCRIPT_DIR}/../lib/envfile.sh"

readonly NOOP_META_ALLOCATOR_ARTIFACT="${REPO_ROOT}/contracts/allocator/NoOpMetaAllocator.json"

contract_codesize() {
  local addr="$1"
  cast codesize "$addr" --rpc-url "$RPC_URL" 2>/dev/null | tr -d '[:space:]'
}

deploy_noop_meta_allocator() {
  local pk="$1"
  local bytecode deployed out
  require_file "$NOOP_META_ALLOCATOR_ARTIFACT"
  bytecode="$(jq -r '.bytecode.object // .bytecode // empty' "$NOOP_META_ALLOCATOR_ARTIFACT")"
  [[ "$bytecode" =~ ^0x[0-9a-fA-F]+$ ]] || die "invalid bytecode in ${NOOP_META_ALLOCATOR_ARTIFACT}"

  # Logs must go to stderr: callers capture stdout as the contract address.
  log "deploying NoOpMetaAllocator for META_ALLOCATOR" >&2
  # cast 1.x: wallet/rpc options must precede the `--create` subcommand.
  # Bump FEVM gas above Lotus defaults so a retry can replace-by-fee if a prior
  # deploy attempt is still sitting in mpool (common after a partial deploy).
  out="$(
    cast send \
      --private-key "$pk" \
      --rpc-url "$RPC_URL" \
      --priority-gas-price 200000 \
      --gas-price 1000000000 \
      --json \
      --create "$bytecode" 2>&1
  )" || die "NoOpMetaAllocator deploy failed: ${out}"

  deployed="$(printf '%s\n' "$out" | jq -r '.contractAddress // empty' | tr -d '[:space:]')"
  if [[ -z "$deployed" || "$deployed" == "null" ]]; then
    deployed="$(printf '%s\n' "$out" | awk '/contractAddress/{print $NF; exit}' | tr -d '[:space:]\",')"
  fi
  [[ "$deployed" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "could not parse NoOpMetaAllocator address from: ${out}"
  [[ "$(contract_codesize "$deployed")" -gt 0 ]] || die "NoOpMetaAllocator at ${deployed} has no code"
  printf '%s\n' "$deployed"
}

require_cmd docker
require_cmd cast
require_cmd jq
require_cmd just
require_container "$LOTUS_CONTAINER"

CURIO_DIR="$(cd "$CURIO_DIR" && pwd)"
POREP_MARKET_DIR="$(cd "$POREP_MARKET_DIR" && pwd)"

CONTRACTS_DIR="${CURIO_DIR}/docker/data/contracts"
DEPLOYER_KEY_FILE="${CONTRACTS_DIR}/deployer.private-key"

log "checking Lotus RPC at ${RPC_URL}"
curl -sf -m 5 -X POST "$RPC_URL" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"Filecoin.ChainHead","params":[],"id":1}' \
  >/dev/null || die "Lotus RPC not reachable at ${RPC_URL}"

require_file "$DEPLOYER_KEY_FILE"
ADMIN_PRIVATE_KEY="$(tr -d '[:space:]' < "$DEPLOYER_KEY_FILE")"
[[ "$ADMIN_PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "invalid deployer private key in ${DEPLOYER_KEY_FILE}"

POREP_MARKET_DIR="$POREP_MARKET_DIR" "${SCRIPT_DIR}/gen-env.sh" --out "${POREP_MARKET_DIR}/.env"
require_file "${POREP_MARKET_DIR}/.env"

# gen-env defaults META_ALLOCATOR to the deployer EOA (no code). Client.transfer
# calls addVerifiedClient on that address and reverts on FEVM. Point it at a NoOp contract.
META_ALLOCATOR="$(deploy_noop_meta_allocator "$ADMIN_PRIVATE_KEY" | tr -d '[:space:]')"
[[ "$META_ALLOCATOR" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "invalid META_ALLOCATOR from deploy: '${META_ALLOCATOR}'"
log "setting META_ALLOCATOR=${META_ALLOCATOR} in ${POREP_MARKET_DIR}/.env"
set_env_key "${POREP_MARKET_DIR}/.env" META_ALLOCATOR "$META_ALLOCATOR"

log "deploying porep-market contracts (just devnet_deploy)"
(cd "$POREP_MARKET_DIR" && just devnet_deploy)

DEPLOYMENT_JSON="${POREP_MARKET_DIR}/deployments/devnet/latest.json"
require_file "$DEPLOYMENT_JSON"
log "done — porep-market deployed (${DEPLOYMENT_JSON})"

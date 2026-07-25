#!/usr/bin/env bash
# Deploy PoRep Market V2 contracts on a local Curio docker-devnet:
#   1. write porep-market .env from Curio contract artifacts (gen-env.sh)
#   2. deploy NoOp MetaAllocator (DataCapEvidenceAdapter.transfer needs a contract)
#   3. forge script Deploy.s.sol → deployments/devnet/latest.json
#   4. deploy PoRepMarketViewHelper(market) and record it in latest.json
#
# porep-market main only ships calibnet/mainnet via `just deploy`; local FEVM uses
# the same Deploy.s.sol entrypoint with unprefixed env vars (see gen-env.sh).
# ViewHelper is not part of Deploy.s.sol — oracle getDealViews needs it separately.
#
# Prerequisites: docker lotus up, cast, jq, forge
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

# Deploy plain PoRepMarketViewHelper(market). Logs to stderr; prints address on stdout.
deploy_porep_market_view_helper() {
  local pk="$1"
  local market="$2"
  local rpc="$3"
  local out deployed

  log "deploying PoRepMarketViewHelper(poRepMarket=${market})" >&2
  out="$(
    cd "$POREP_MARKET_DIR"
    # --constructor-args must be last: forge treats following tokens as ctor args.
    forge create src/helpers/PoRepMarketViewHelper.sol:PoRepMarketViewHelper \
      --broadcast \
      --rpc-url "$rpc" \
      --private-key "$pk" \
      --priority-gas-price 200000 \
      --gas-price 1000000000 \
      --json \
      --constructor-args "$market" 2>&1
  )" || die "PoRepMarketViewHelper deploy failed: ${out}"

  deployed="$(printf '%s\n' "$out" | jq -r 'if type=="array" then .[-1].deployedTo // .[-1].contractAddress // empty else .deployedTo // .contractAddress // empty end' 2>/dev/null | tr -d '[:space:]')"
  if [[ -z "$deployed" || "$deployed" == "null" ]]; then
    deployed="$(printf '%s\n' "$out" | awk '/Deployed to:/{print $NF; exit}' | tr -d '[:space:]')"
  fi
  if [[ -z "$deployed" || "$deployed" == "null" ]]; then
    deployed="$(printf '%s\n' "$out" | jq -r '.. | objects | .deployedTo // .contractAddress // empty' 2>/dev/null | grep -E '^0x[0-9a-fA-F]{40}$' | tail -n1 || true)"
  fi
  [[ "$deployed" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "could not parse PoRepMarketViewHelper address from: ${out}"
  [[ "$(contract_codesize "$deployed")" -gt 0 ]] || die "PoRepMarketViewHelper at ${deployed} has no code"
  printf '%s\n' "$deployed"
}

# Deploy PoRepMarketClaimInspector(adapter, market).
deploy_porep_market_claim_inspector() {
  local pk="$1"
  local adapter="$2"
  local market="$3"
  local rpc="$4"
  local out deployed

  log "deploying PoRepMarketClaimInspector(adapter=${adapter}, market=${market})" >&2
  out="$(
    cd "$POREP_MARKET_DIR"
    forge create src/helpers/PoRepMarketClaimInspector.sol:PoRepMarketClaimInspector \
      --broadcast \
      --rpc-url "$rpc" \
      --private-key "$pk" \
      --priority-gas-price 200000 \
      --gas-price 1000000000 \
      --json \
      --constructor-args "$adapter" "$market" 2>&1
  )" || die "PoRepMarketClaimInspector deploy failed: ${out}"

  deployed="$(printf '%s\n' "$out" | jq -r 'if type=="array" then .[-1].deployedTo // .[-1].contractAddress // empty else .deployedTo // .contractAddress // empty end' 2>/dev/null | tr -d '[:space:]')"
  if [[ -z "$deployed" || "$deployed" == "null" ]]; then
    deployed="$(printf '%s\n' "$out" | awk '/Deployed to:/{print $NF; exit}' | tr -d '[:space:]')"
  fi
  if [[ -z "$deployed" || "$deployed" == "null" ]]; then
    deployed="$(printf '%s\n' "$out" | jq -r '.. | objects | .deployedTo // .contractAddress // empty' 2>/dev/null | grep -E '^0x[0-9a-fA-F]{40}$' | tail -n1 || true)"
  fi
  [[ "$deployed" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "could not parse PoRepMarketClaimInspector address from: ${out}"
  [[ "$(contract_codesize "$deployed")" -gt 0 ]] || die "PoRepMarketClaimInspector at ${deployed} has no code"
  printf '%s\n' "$deployed"
}

# Deploy PoRepMarketSectorStatusInspector(market).
deploy_porep_market_sector_status_inspector() {
  local pk="$1"
  local market="$2"
  local rpc="$3"
  local out deployed

  log "deploying PoRepMarketSectorStatusInspector(poRepMarket=${market})" >&2
  out="$(
    cd "$POREP_MARKET_DIR"
    forge create src/helpers/PoRepMarketSectorStatusInspector.sol:PoRepMarketSectorStatusInspector \
      --broadcast \
      --rpc-url "$rpc" \
      --private-key "$pk" \
      --priority-gas-price 200000 \
      --gas-price 1000000000 \
      --json \
      --constructor-args "$market" 2>&1
  )" || die "PoRepMarketSectorStatusInspector deploy failed: ${out}"

  deployed="$(printf '%s\n' "$out" | jq -r 'if type=="array" then .[-1].deployedTo // .[-1].contractAddress // empty else .deployedTo // .contractAddress // empty end' 2>/dev/null | tr -d '[:space:]')"
  if [[ -z "$deployed" || "$deployed" == "null" ]]; then
    deployed="$(printf '%s\n' "$out" | awk '/Deployed to:/{print $NF; exit}' | tr -d '[:space:]')"
  fi
  if [[ -z "$deployed" || "$deployed" == "null" ]]; then
    deployed="$(printf '%s\n' "$out" | jq -r '.. | objects | .deployedTo // .contractAddress // empty' 2>/dev/null | grep -E '^0x[0-9a-fA-F]{40}$' | tail -n1 || true)"
  fi
  [[ "$deployed" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "could not parse PoRepMarketSectorStatusInspector address from: ${out}"
  [[ "$(contract_codesize "$deployed")" -gt 0 ]] || die "PoRepMarketSectorStatusInspector at ${deployed} has no code"
  printf '%s\n' "$deployed"
}

env_get_file() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '
    $1 == k {
      sub(/^[^=]*=/, "")
      gsub(/\r/, "")
      print
      exit
    }
  ' "$file"
}

record_helper_in_manifest() {
  local name="$1"
  local artifact="$2"
  local addr="$3"
  local tmp
  tmp="$(mktemp)"
  jq --arg name "$name" --arg artifact "$artifact" --arg addr "$addr" '
    .contracts[$name] = {
      artifact: $artifact,
      address: $addr,
      kind: "implementation"
    }
  ' "$DEPLOYMENT_JSON" >"$tmp"
  mv "$tmp" "$DEPLOYMENT_JSON"
}

# Deploy ViewHelper + ClaimInspector + SectorStatusInspector; update latest.json.
deploy_and_record_helpers() {
  local pk="$1"
  local market="$2"
  local adapter="$3"
  local rpc="$4"
  local view_helper claim_inspector sector_inspector

  view_helper="$(deploy_porep_market_view_helper "$pk" "$market" "$rpc" | tr -d '[:space:]')"
  [[ "$view_helper" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "invalid PoRepMarketViewHelper: '${view_helper}'"
  record_helper_in_manifest PoRepMarketViewHelper \
    "src/helpers/PoRepMarketViewHelper.sol:PoRepMarketViewHelper" "$view_helper"
  log "PoRepMarketViewHelper=${view_helper}"

  claim_inspector="$(deploy_porep_market_claim_inspector "$pk" "$adapter" "$market" "$rpc" | tr -d '[:space:]')"
  [[ "$claim_inspector" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "invalid PoRepMarketClaimInspector: '${claim_inspector}'"
  record_helper_in_manifest PoRepMarketClaimInspector \
    "src/helpers/PoRepMarketClaimInspector.sol:PoRepMarketClaimInspector" "$claim_inspector"
  log "PoRepMarketClaimInspector=${claim_inspector}"

  sector_inspector="$(deploy_porep_market_sector_status_inspector "$pk" "$market" "$rpc" | tr -d '[:space:]')"
  [[ "$sector_inspector" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "invalid PoRepMarketSectorStatusInspector: '${sector_inspector}'"
  record_helper_in_manifest PoRepMarketSectorStatusInspector \
    "src/helpers/PoRepMarketSectorStatusInspector.sol:PoRepMarketSectorStatusInspector" "$sector_inspector"
  log "PoRepMarketSectorStatusInspector=${sector_inspector}"
}

HELPERS_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --view-helper-only|--helpers-only) HELPERS_ONLY=true; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: deploy.sh [--helpers-only]

  (default)          Full V2 deploy + ViewHelper + ClaimInspector + SectorStatusInspector
  --helpers-only     Deploy helpers against existing latest.json market/adapter only
                     (alias: --view-helper-only)
EOF
      exit 0
      ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

require_cmd docker
require_cmd cast
require_cmd jq
require_cmd forge
require_container "$LOTUS_CONTAINER"

CURIO_DIR="$(cd "$CURIO_DIR" && pwd)"
POREP_MARKET_DIR="$(cd "$POREP_MARKET_DIR" && pwd)"

CONTRACTS_DIR="${CURIO_DIR}/docker/data/contracts"
DEPLOYER_KEY_FILE="${CONTRACTS_DIR}/deployer.private-key"
DEPLOYMENT_DIR="${POREP_MARKET_DIR}/deployments/devnet"
DEPLOYMENT_JSON="${DEPLOYMENT_DIR}/latest.json"

[[ -f "${POREP_MARKET_DIR}/lib/fvm-solidity/src/FVMSector.sol" ]] \
  || die "porep-market forge libs missing (lib/fvm-solidity); run: just init"

log "checking Lotus RPC at ${RPC_URL}"
curl -sf -m 5 -X POST "$RPC_URL" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"Filecoin.ChainHead","params":[],"id":1}' \
  >/dev/null || die "Lotus RPC not reachable at ${RPC_URL}"

require_file "$DEPLOYER_KEY_FILE"
ADMIN_PRIVATE_KEY="$(tr -d '[:space:]' < "$DEPLOYER_KEY_FILE")"
[[ "$ADMIN_PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "invalid deployer private key in ${DEPLOYER_KEY_FILE}"

if [[ "$HELPERS_ONLY" == true ]]; then
  require_file "$DEPLOYMENT_JSON"
  require_file "${POREP_MARKET_DIR}/.env"
  PRIVATE_KEY_TEST="$(env_get_file "${POREP_MARKET_DIR}/.env" PRIVATE_KEY_TEST)"
  RPC_TEST="$(env_get_file "${POREP_MARKET_DIR}/.env" RPC_TEST)"
  [[ "$RPC_TEST" =~ ^https?:// ]] || RPC_TEST="$RPC_URL"
  [[ -n "$PRIVATE_KEY_TEST" ]] || PRIVATE_KEY_TEST="$ADMIN_PRIVATE_KEY"

  POREP_MARKET_PROXY="$(jq -r '.contracts.PoRepMarket.proxy // empty' "$DEPLOYMENT_JSON")"
  DATACAP_ADAPTER="$(jq -r '.contracts.DataCapEvidenceAdapter.proxy // empty' "$DEPLOYMENT_JSON")"
  [[ "$POREP_MARKET_PROXY" =~ ^0x[0-9a-fA-F]{40}$ ]] \
    || die "missing contracts.PoRepMarket.proxy in ${DEPLOYMENT_JSON}"
  [[ "$DATACAP_ADAPTER" =~ ^0x[0-9a-fA-F]{40}$ ]] \
    || die "missing contracts.DataCapEvidenceAdapter.proxy in ${DEPLOYMENT_JSON}"

  deploy_and_record_helpers "$PRIVATE_KEY_TEST" "$POREP_MARKET_PROXY" "$DATACAP_ADAPTER" "$RPC_TEST"
  log "done — helpers recorded in ${DEPLOYMENT_JSON}"
  exit 0
fi

POREP_MARKET_DIR="$POREP_MARKET_DIR" "${SCRIPT_DIR}/gen-env.sh" --out "${POREP_MARKET_DIR}/.env"
require_file "${POREP_MARKET_DIR}/.env"

# gen-env defaults META_ALLOCATOR to the deployer EOA (no code). DataCapEvidenceAdapter
# calls addVerifiedClient on that address and reverts on FEVM. Point it at a NoOp contract.
META_ALLOCATOR="$(deploy_noop_meta_allocator "$ADMIN_PRIVATE_KEY" | tr -d '[:space:]')"
[[ "$META_ALLOCATOR" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "invalid META_ALLOCATOR from deploy: '${META_ALLOCATOR}'"
log "setting META_ALLOCATOR=${META_ALLOCATOR} in ${POREP_MARKET_DIR}/.env"
set_env_key "${POREP_MARKET_DIR}/.env" META_ALLOCATOR "$META_ALLOCATOR"

FILECOIN_PAY="$(env_get_file "${POREP_MARKET_DIR}/.env" FILECOIN_PAY)"
TERMINATION_ORACLE="$(env_get_file "${POREP_MARKET_DIR}/.env" TERMINATION_ORACLE)"
ORACLE="$(env_get_file "${POREP_MARKET_DIR}/.env" ORACLE)"
POREP_SERVICE="$(env_get_file "${POREP_MARKET_DIR}/.env" POREP_SERVICE)"
OPERATOR_ADDR="$(env_get_file "${POREP_MARKET_DIR}/.env" OPERATOR_ADDR)"
PRIVATE_KEY_TEST="$(env_get_file "${POREP_MARKET_DIR}/.env" PRIVATE_KEY_TEST)"
RPC_TEST="$(env_get_file "${POREP_MARKET_DIR}/.env" RPC_TEST)"
[[ "$RPC_TEST" =~ ^https?:// ]] || RPC_TEST="$RPC_URL"

for var in FILECOIN_PAY TERMINATION_ORACLE ORACLE POREP_SERVICE META_ALLOCATOR OPERATOR_ADDR PRIVATE_KEY_TEST; do
  [[ -n "${!var}" ]] || die "${var} missing from ${POREP_MARKET_DIR}/.env"
done

mkdir -p "$DEPLOYMENT_DIR"
PENDING_DIR="${POREP_MARKET_DIR}/.deployment/devnet"
mkdir -p "$PENDING_DIR"
PENDING="${PENDING_DIR}/pending-deploy.json"
# Deploy.s.sol writes via vm.writeJson; foundry.toml only allows ./.deployment/
printf '{}\n' >"$PENDING"

# Local-only placeholder; Deploy.s.sol embeds this in the pending manifest.
BUILD_INFO_SHA256="0x$(printf '0%.0s' {1..64})"

log "deploying porep-market contracts (forge script Deploy.s.sol → ${DEPLOYMENT_JSON})"
(
  cd "$POREP_MARKET_DIR"
  PRIVATE_KEY="$PRIVATE_KEY_TEST" \
    RPC_URL="$RPC_TEST" \
    DEPLOYMENT_OUTPUT="$PENDING" \
    BUILD_INFO_SHA256="$BUILD_INFO_SHA256" \
    FILECOIN_PAY="$FILECOIN_PAY" \
    TERMINATION_ORACLE="$TERMINATION_ORACLE" \
    ORACLE="$ORACLE" \
    POREP_SERVICE="$POREP_SERVICE" \
    META_ALLOCATOR="$META_ALLOCATOR" \
    OPERATOR_ADDR="$OPERATOR_ADDR" \
    forge script script/Deploy.s.sol:Deploy \
      --broadcast \
      --rpc-url "$RPC_TEST" \
      --private-key "$PRIVATE_KEY_TEST" \
      --gas-estimate-multiplier 100000 \
      --slow
)

jq -e '.result.contracts | type=="object" and length>0' "$PENDING" >/dev/null \
  || die "Deploy.s.sol did not write contracts into ${PENDING}"

jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '.result | .status="finalized" | .finalizedAt=$at' "$PENDING" >"$DEPLOYMENT_JSON"

require_file "$DEPLOYMENT_JSON"

POREP_MARKET_PROXY="$(jq -r '.contracts.PoRepMarket.proxy // empty' "$DEPLOYMENT_JSON")"
DATACAP_ADAPTER="$(jq -r '.contracts.DataCapEvidenceAdapter.proxy // empty' "$DEPLOYMENT_JSON")"
[[ "$POREP_MARKET_PROXY" =~ ^0x[0-9a-fA-F]{40}$ ]] \
  || die "missing contracts.PoRepMarket.proxy in ${DEPLOYMENT_JSON}"
[[ "$DATACAP_ADAPTER" =~ ^0x[0-9a-fA-F]{40}$ ]] \
  || die "missing contracts.DataCapEvidenceAdapter.proxy in ${DEPLOYMENT_JSON}"

deploy_and_record_helpers "$PRIVATE_KEY_TEST" "$POREP_MARKET_PROXY" "$DATACAP_ADAPTER" "$RPC_TEST"

log "done — porep-market deployed (${DEPLOYMENT_JSON})"

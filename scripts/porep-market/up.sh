#!/usr/bin/env bash
# Wire filecoin-porep-market-tooling to a local Curio docker devnet:
#   1. create a funded SP organization wallet
#   2. write .env from Curio + porep-market deployment artifacts
#   3. register local miners under that org (new SPRegistry ABI via cast)
#   4. add the org wallet as an *additional* miner control address (keep BLS worker as post)
#   5. grant DataCap to DataCapEvidenceAdapter (needed for make-allocations)
#
# Deploy contracts first with: ./scripts/porep-market/deploy.sh (or just porep-market deploy)
#
# IMPORTANT: never replace WindowPoSt (post) with the eth/f410 org wallet. Eth accounts
# cannot sign native SubmitWindowedPoSt; on a single-miner 2k net that faults the only
# power at deadline close (~epoch 718) and freezes the chain via slash-filter.
#
# Compatible with macOS /bin/bash 3.2 (no mapfile).
#
# Prerequisites: docker (lotus, lotus-miner, curio up), cast, jq;
#   porep-market deployments/devnet/latest.json from deploy.sh
#
# Usage:
#   ./scripts/porep-market/up.sh
#   ./scripts/porep-market/up.sh --from-env
#   just porep-market up
#   just up

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/envfile.sh
source "${SCRIPT_DIR}/../lib/envfile.sh"
# shellcheck source=../lib/lotus.sh
source "${SCRIPT_DIR}/../lib/lotus.sh"

ORG_FUND_AMOUNT="${ORG_FUND_AMOUNT:-1000}"
AVAILABLE_BYTES="${AVAILABLE_BYTES:-10995116277760}" # 10 TiB
DATACAP_GRANT_BYTES="${DATACAP_GRANT_BYTES:-1000000000}" # 1 GiB, same as Curio mk12 bootstrap
# V2 offer: 6–60 months (EPOCHS_IN_DAY=2880); price must be >= token min (contract enforces >= 1).
OFFER_MIN_DURATION_EPOCHS="${OFFER_MIN_DURATION_EPOCHS:-$((6 * 30 * 2880))}"
OFFER_MAX_DURATION_EPOCHS="${OFFER_MAX_DURATION_EPOCHS:-$((60 * 30 * 2880))}"
OFFER_PRICE_PER_32GIB_PER_MONTH="${OFFER_PRICE_PER_32GIB_PER_MONTH:-1}"
ENV_FILE="${ENV_FILE:-${TOOLING_DIR}/.env}"

SKIP_REGISTER=false
SKIP_CONTROL=false
SKIP_DATACAP=false
FROM_ENV=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --from-env        Resume using existing .env SP wallets; refresh ADMIN + contract addrs
  --skip-register   Skip SPRegistry registerProviderFor calls
  --skip-control    Skip miner control-address updates
  --skip-datacap    Skip granting DataCap to DataCapEvidenceAdapter
  -h, --help        Show this help

Deploy contracts with: ./scripts/porep-market/deploy.sh

Environment:
  CURIO_DIR              Path to curio checkout (default: ./extern/curio)
  POREP_MARKET_DIR       Path to porep-market checkout (default: ./extern/porep-market)
  TOOLING_DIR            Path to tooling (default: ./extern/filecoin-porep-market-tooling)
  RPC_URL                Lotus FEVM RPC (default: http://127.0.0.1:2234/rpc/v1)
  LOTUS_CONTAINER        Docker container name (default: lotus)
  LOTUS_MINER_CONTAINER  Docker container name (default: lotus-miner)
  CURIO_CONTAINER        Docker container name (default: curio)
  ORG_FUND_AMOUNT        FIL to send new org/client wallets (default: 1000)
  AVAILABLE_BYTES        Capacity to register (default: 10995116277760)
  DATACAP_GRANT_BYTES    DataCap to grant DataCapEvidenceAdapter (default: 1000000000)
  REGISTER_LOTUS_MINER   Register lotus-miner in SPRegistry (default: false)
  ENV_FILE               Output .env path (default: <tooling>/.env)
EOF
}

extract_msg_cid() {
  # Prefer "Message CID: <cid>", else last bafy… token in the text.
  local text="$1"
  local cid
  cid="$(printf '%s\n' "$text" | awk '/Message CID:/{print $NF; exit}' | tr -d '[:space:]')"
  if [[ -z "$cid" ]]; then
    cid="$(printf '%s\n' "$text" | grep -Eo 'bafy[a-z0-9]+' | tail -n1 || true)"
  fi
  printf '%s\n' "$cid"
}

is_authorized_for_provider() {
  # cast against FEVM can fail with "refusing explicit call due to state fork"
  # on busy localnets; treat that as unknown (empty) so callers can retry.
  local pid="$1"
  local attempts="${2:-8}"
  local i out rc
  for i in $(seq 1 "$attempts"); do
    set +e
    out="$(
      cast call "$SP_REGISTRY" "isAuthorizedForProvider(address,uint64)(bool)" \
        "$SP_ORGANIZATION" "$pid" --rpc-url "$RPC_URL" 2>&1
    )"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      printf '%s\n' "$(printf '%s' "$out" | tr -d '[:space:]')"
      return 0
    fi
    if printf '%s\n' "$out" | grep -qiE 'state fork|refusing explicit call'; then
      log "transient lotus tipset/fork on isAuthorizedForProvider(${pid}) (${i}/${attempts}); retrying" >&2
      sleep 2
      continue
    fi
    die "isAuthorizedForProvider(${SP_ORGANIZATION}, ${pid}) failed: ${out}"
  done
  log "isAuthorizedForProvider(${pid}) still failing after tipset/fork retries" >&2
  return 1
}

wait_until_authorized() {
  local pid="$1"
  local timeout_s="${POREP_AUTHORIZE_TIMEOUT_S:-300}"
  local deadline=$((SECONDS + timeout_s))
  local auth
  while (( SECONDS < deadline )); do
    set +e
    auth="$(is_authorized_for_provider "$pid" 3)"
    set -e
    if [[ "$auth" == "true" ]]; then
      log "isAuthorizedForProvider(${SP_ORGANIZATION}, ${pid}) = true"
      return 0
    fi
    sleep 2
  done
  runtime_dump_stack porep-authorize "provider=${pid}" "timeout=${timeout_s}s" >/dev/null || true
  die "org ${SP_ORGANIZATION} is not authorized for provider ${pid} after control set (timeout ${timeout_s}s)"
}

miner_id_num() {
  # t01000 / f01000 -> 1000
  local addr="$1"
  echo "${addr}" | sed -E 's/^[tf]0*//'
}

# Worker (or current post) key that must remain the WindowPoSt sender — never an f410/eth addr.
# Must use --verbose: default control list truncates keys to "t3xxxx..." which is not parseable.
miner_post_key() {
  local miner="$1"
  local list key
  if [[ -n "$LOTUS_MINER_ID" && "$miner" == "$LOTUS_MINER_ID" ]]; then
    list="$(docker exec "$LOTUS_MINER_CONTAINER" lotus-miner actor control list --verbose 2>/dev/null || true)"
  else
    list="$(docker exec "$CURIO_CONTAINER" sptool --actor "$miner" actor control list --verbose 2>/dev/null || true)"
  fi
  key="$(
    printf '%s\n' "$list" | awk '
      $1=="worker" && $3 ~ /^[tf][0-9a-z]+$/ && $3 !~ /\.\.\./ { print $3; exit }
    '
  )"
  if [[ -z "$key" ]]; then
    key="$(
      printf '%s\n' "$list" | awk '
        $1 ~ /^control/ && $3 ~ /^[tf][0-9a-z]+$/ && $3 !~ /^[tf]410/ && $3 !~ /\.\.\./ { print $3; exit }
        $1=="owner" && $3 ~ /^[tf][0-9a-z]+$/ && $3 !~ /^[tf]410/ && $3 !~ /\.\.\./ { print $3; exit }
      '
    )"
  fi
  printf '%s\n' "$key"
}

eth_to_filecoin() {
  local eth="$1"
  curl -sf -m 10 -X POST "$RPC_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"Filecoin.EthAddressToFilecoinAddress\",\"params\":[\"${eth}\"],\"id\":1}" \
    | jq -r '.result // empty'
}

# True if Lotus knows this address as an on-chain actor.
fil_actor_exists() {
  local addr="$1"
  lotus state get-actor "$addr" >/dev/null 2>&1
}

# Ensure a Filecoin address exists (create via funding if missing). Needed after
# chain reset when --from-env reuses an SP org eth key whose t410 actor is gone.
ensure_fil_actor_funded() {
  local addr="$1"
  local amount="${2:-$ORG_FUND_AMOUNT}"
  local default_wallet fund_out fund_cid
  if fil_actor_exists "$addr"; then
    log "Filecoin actor ${addr} already exists"
    return 0
  fi
  default_wallet="$(lotus wallet default | tr -d '[:space:]')"
  log "Filecoin actor ${addr} missing — funding ${amount} FIL from ${default_wallet} to create it"
  fund_out="$(lotus send --from "$default_wallet" "$addr" "$amount")"
  fund_cid="$(printf '%s\n' "$fund_out" | awk '/^bafy/{print $1}' | tail -n1 | tr -d '[:space:]')"
  [[ -n "$fund_cid" ]] || fund_cid="$(printf '%s\n' "$fund_out" | tail -n1 | tr -d '[:space:]')"
  wait_msg_required "$fund_cid"
  fil_actor_exists "$addr" || die "actor ${addr} still missing after funding"
}

# Returns remaining DataCap bytes, or empty if not a verified client.
client_datacap_bytes() {
  local addr="$1"
  local out
  out="$(lotus filplus check-client-datacap "$addr" 2>/dev/null || true)"
  # Avoid pipefail/SIGPIPE from `grep | head`; take first integer token.
  printf '%s\n' "$out" | awk '/[0-9]/{ match($0, /[0-9]+/); if (RSTART) { print substr($0, RSTART, RLENGTH); exit } }'
}

pick_notary() {
  # Prefer a notary with remaining allowance > 0 (matches Curio piece-server bootstrap).
  lotus filplus list-notaries 2>/dev/null \
    | awk -F: '$2+0 > 0 { gsub(/[[:space:]]/, "", $1); print $1; exit }'
}

contract_codesize() {
  local addr="$1"
  cast codesize "$addr" --rpc-url "$RPC_URL" 2>/dev/null | tr -d '[:space:]'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-env) FROM_ENV=true; shift ;;
    --skip-register) SKIP_REGISTER=true; shift ;;
    --skip-control) SKIP_CONTROL=true; shift ;;
    --skip-datacap) SKIP_DATACAP=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

require_cmd docker
require_cmd cast
require_cmd jq
require_container "$LOTUS_CONTAINER"

CURIO_DIR="$(cd "$CURIO_DIR" && pwd)"
POREP_MARKET_DIR="$(cd "$POREP_MARKET_DIR" && pwd)"

CONTRACTS_DIR="${CURIO_DIR}/docker/data/contracts"
DEPLOYMENT_JSON="$(active_latest_json 2>/dev/null || true)"
DEPLOYMENT_JSON="${DEPLOYMENT_JSON:-${POREP_MARKET_DIR}/deployments/devnet/latest.json}"
DEPLOYER_KEY_FILE="${CONTRACTS_DIR}/deployer.private-key"
CONTRACT_ADDRESSES_JSON="${CONTRACTS_DIR}/contract_addresses.json"
DEVNET_INFO_JSON="${CONTRACTS_DIR}/devnet-info.json"

log "checking Lotus RPC at ${RPC_URL}"
curl -sf -m 5 -X POST "$RPC_URL" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"Filecoin.ChainHead","params":[],"id":1}' \
  >/dev/null || die "Lotus RPC not reachable at ${RPC_URL}"

require_file "$DEPLOYMENT_JSON"

# V2 manifest: contracts.* and externalDependencies.* (see Deploy.s.sol)
POREP_MARKET="$(jq -r '.contracts.PoRepMarket.proxy // empty' "$DEPLOYMENT_JSON")"
FILECOIN_PAY="$(jq -r '.externalDependencies.FilecoinPay // empty' "$DEPLOYMENT_JSON")"
SP_REGISTRY="$(jq -r '.contracts.SPRegistry.proxy // empty' "$DEPLOYMENT_JSON")"
EVIDENCE_ADAPTER="$(jq -r '.contracts.DataCapEvidenceAdapter.proxy // empty' "$DEPLOYMENT_JSON")"
META_ALLOCATOR="$(jq -r '.externalDependencies.MetaAllocator // empty' "$DEPLOYMENT_JSON")"
[[ -n "$POREP_MARKET" && "$POREP_MARKET" != null ]] || die "contracts.PoRepMarket.proxy missing from ${DEPLOYMENT_JSON}"
[[ -n "$FILECOIN_PAY" && "$FILECOIN_PAY" != null ]] || die "externalDependencies.FilecoinPay missing from ${DEPLOYMENT_JSON}"
[[ -n "$SP_REGISTRY" && "$SP_REGISTRY" != null ]] || die "contracts.SPRegistry.proxy missing from ${DEPLOYMENT_JSON}"
[[ -n "$EVIDENCE_ADAPTER" && "$EVIDENCE_ADAPTER" != null ]] || die "contracts.DataCapEvidenceAdapter.proxy missing from ${DEPLOYMENT_JSON}"
[[ -n "$META_ALLOCATOR" && "$META_ALLOCATOR" != null ]] || die "externalDependencies.MetaAllocator missing from ${DEPLOYMENT_JSON}"
if [[ "$(contract_codesize "$META_ALLOCATOR")" -eq 0 ]]; then
  die "MetaAllocator ${META_ALLOCATOR} has no code (deployer EOA stub). Run just porep-market deploy first (NoOpMetaAllocator)."
fi
EVIDENCE_ADAPTER_T410="$(eth_to_filecoin "$EVIDENCE_ADAPTER")"
[[ -n "$EVIDENCE_ADAPTER_T410" ]] || die "could not resolve Filecoin address for DataCapEvidenceAdapter ${EVIDENCE_ADAPTER}"
log "DataCapEvidenceAdapter evm=${EVIDENCE_ADAPTER} fil=${EVIDENCE_ADAPTER_T410}"
log "MetaAllocator ${META_ALLOCATOR} (codesize $(contract_codesize "$META_ALLOCATOR"))"

if [[ "$FROM_ENV" == true ]]; then
  require_file "$ENV_FILE"
  require_file "$DEPLOYER_KEY_FILE"
  require_file "$CONTRACT_ADDRESSES_JSON"
  log "resuming from existing ${ENV_FILE}"
  RPC_URL="$(env_get RPC_URL || printf '%s' "$RPC_URL")"
  # Always use Curio deployer as ADMIN — it owns DEFAULT_ADMIN_ROLE on freshly
  # deployed contracts. A stale ADMIN_PRIVATE_KEY from an older .env often has no
  # FEVM actor / FIL and fails cast send with "actor not found".
  ADMIN_PRIVATE_KEY="$(tr -d '[:space:]' < "$DEPLOYER_KEY_FILE")"
  [[ "$ADMIN_PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "invalid deployer private key in ${DEPLOYER_KEY_FILE}"
  ORG_PRIVATE_KEY="$(env_get SP_PRIVATE_KEY)"
  SP_ORGANIZATION="$(env_get SP_ORGANIZATION)"
  [[ "$ORG_PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "SP_PRIVATE_KEY missing/invalid in ${ENV_FILE}"
  [[ "$SP_ORGANIZATION" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "SP_ORGANIZATION missing/invalid in ${ENV_FILE}"
  ORG_T410="$(eth_to_filecoin "$SP_ORGANIZATION")"
  [[ -n "$ORG_T410" ]] || die "could not resolve Filecoin address for ${SP_ORGANIZATION}"
  log "org t410=${ORG_T410} evm=${SP_ORGANIZATION}"
  ensure_fil_actor_funded "$ORG_T410"

  require_file "$DEVNET_INFO_JSON"
  CLIENT_PRIVATE_KEY="$(jq -r '.info.users[0].private_key_hex // empty' "$DEVNET_INFO_JSON")"
  CLIENT_ADDRESS="$(jq -r '.info.users[0].evm_addr // empty' "$DEVNET_INFO_JSON")"
  [[ -n "$CLIENT_PRIVATE_KEY" && "$CLIENT_PRIVATE_KEY" != null ]] || die "USER_1 private key missing from ${DEVNET_INFO_JSON}"
  [[ -n "$CLIENT_ADDRESS" && "$CLIENT_ADDRESS" != null ]] || die "USER_1 evm_addr missing from ${DEVNET_INFO_JSON}"
  CLIENT_T410="$(eth_to_filecoin "$CLIENT_ADDRESS")"
  [[ -n "$CLIENT_T410" ]] || die "could not resolve Filecoin address for CLIENT ${CLIENT_ADDRESS}"
  ensure_fil_actor_funded "$CLIENT_T410"

  USDC_TOKEN="$(jq -r '.contracts.usdfc // empty' "$CONTRACT_ADDRESSES_JSON")"
  [[ -n "$USDC_TOKEN" && "$USDC_TOKEN" != null ]] || die "contracts.usdfc missing from ${CONTRACT_ADDRESSES_JSON}"
  # Keep SP wallets; refresh admin/client + contract addresses after a re-deploy / chain reset.
  set_env_key "$ENV_FILE" ADMIN_PRIVATE_KEY "$ADMIN_PRIVATE_KEY"
  set_env_key "$ENV_FILE" CLIENT_PRIVATE_KEY "$CLIENT_PRIVATE_KEY"
  set_env_key "$ENV_FILE" CLIENT_ADDRESS "$CLIENT_ADDRESS"
  set_env_key "$ENV_FILE" POREP_MARKET "$POREP_MARKET"
  set_env_key "$ENV_FILE" FILECOIN_PAY "$FILECOIN_PAY"
  set_env_key "$ENV_FILE" USDC_TOKEN "$USDC_TOKEN"
  log "synced ADMIN/CLIENT, POREP_MARKET=${POREP_MARKET}, FILECOIN_PAY=${FILECOIN_PAY}, USDC_TOKEN=${USDC_TOKEN}"
else
  require_file "$DEPLOYER_KEY_FILE"
  require_file "$CONTRACT_ADDRESSES_JSON"
  require_file "$DEVNET_INFO_JSON"

  ADMIN_PRIVATE_KEY="$(tr -d '[:space:]' < "$DEPLOYER_KEY_FILE")"
  [[ "$ADMIN_PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "invalid deployer private key in ${DEPLOYER_KEY_FILE}"

  USDC_TOKEN="$(jq -r '.contracts.usdfc // empty' "$CONTRACT_ADDRESSES_JSON")"
  CLIENT_PRIVATE_KEY="$(jq -r '.info.users[0].private_key_hex // empty' "$DEVNET_INFO_JSON")"
  CLIENT_ADDRESS="$(jq -r '.info.users[0].evm_addr // empty' "$DEVNET_INFO_JSON")"

  [[ -n "$USDC_TOKEN" && "$USDC_TOKEN" != null ]] || die "contracts.usdfc missing from ${CONTRACT_ADDRESSES_JSON}"
  [[ -n "$CLIENT_PRIVATE_KEY" && "$CLIENT_PRIVATE_KEY" != null ]] || die "USER_1 private key missing from ${DEVNET_INFO_JSON}"
  [[ -n "$CLIENT_ADDRESS" && "$CLIENT_ADDRESS" != null ]] || die "USER_1 evm_addr missing from ${DEVNET_INFO_JSON}"

  log "creating SP organization delegated wallet"
  ORG_T410="$(lotus wallet new delegated | tr -d '[:space:]')"
  [[ "$ORG_T410" == t410* || "$ORG_T410" == f410* ]] || die "expected delegated t410/f410 wallet, got: ${ORG_T410}"

  DEFAULT_WALLET="$(lotus wallet default | tr -d '[:space:]')"
  log "funding ${ORG_T410} with ${ORG_FUND_AMOUNT} FIL from ${DEFAULT_WALLET}"
  FUND_OUT="$(lotus send --from "$DEFAULT_WALLET" "$ORG_T410" "$ORG_FUND_AMOUNT")"
  FUND_CID="$(printf '%s\n' "$FUND_OUT" | awk '/^bafy/{print $1}' | tail -n1 | tr -d '[:space:]')"
  [[ -n "$FUND_CID" ]] || FUND_CID="$(printf '%s\n' "$FUND_OUT" | tail -n1 | tr -d '[:space:]')"
  wait_msg_required "$FUND_CID"

  log "exporting org private key"
  ORG_PRIVATE_KEY="$(
    docker exec "$LOTUS_CONTAINER" bash -lc "
      lotus wallet export '${ORG_T410}' \
        | xxd -r -p \
        | jq -r '.PrivateKey' \
        | base64 -d \
        | xxd -p -c 32 \
        | sed 's/^/0x/'
    " | tr -d '[:space:]'
  )"
  [[ "$ORG_PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "failed to export org private key"

  SP_ORGANIZATION="$(cast wallet address --private-key "$ORG_PRIVATE_KEY" | tr -d '[:space:]')"
  log "org t410=${ORG_T410} evm=${SP_ORGANIZATION}"

  if [[ -f "$ENV_FILE" ]]; then
    backup="${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$ENV_FILE" "$backup"
    log "backed up existing .env to ${backup}"
  fi

  log "writing ${ENV_FILE}"
  cat > "$ENV_FILE" <<EOF
DEBUG=false

# Needed for sp onboard-data command, path for aria2c binary, leave empty to use PATH lookup
ARIA2C_PATH=

# Needed for sp claim-allocations curio command.
# Default: docker wrapper (Curio runs in container on this setup).
CURIO_PATH=${CURIO_CLI}

# Needed for sp claim-allocations boost command, path for boostd binary, leave empty to use PATH lookup
BOOSTD_PATH=

# Enables dry-run mode, which only simulates transactions without broadcasting them to the network
DRY_RUN=false

# SPRegistry database connection string used for admin operations
SP_REGISTRY_DATABASE_URL=

# Local Curio Devnet Lotus RPC (chain id 31415926)
RPC_URL=${RPC_URL}

# Funded USER_1 from curio/docker/data/contracts/devnet-info.json
CLIENT_PRIVATE_KEY=${CLIENT_PRIVATE_KEY}
CLIENT_LOTUS_WALLET=
CLIENT_LOTUS_TOKEN=
CLIENT_ADDRESS=${CLIENT_ADDRESS}

# Deployer from curio/docker/data/contracts/deployer.private-key
ADMIN_PRIVATE_KEY=${ADMIN_PRIVATE_KEY}
ADMIN_LOTUS_WALLET=
ADMIN_LOTUS_TOKEN=

# Fresh SP organization created by scripts/porep-market/up.sh
# Native Lotus address: ${ORG_T410}
SP_PRIVATE_KEY=${ORG_PRIVATE_KEY}
SP_LOTUS_WALLET=
SP_LOTUS_TOKEN=
SP_ORGANIZATION=${SP_ORGANIZATION}

# From porep-market/deployments/devnet/latest.json
POREP_MARKET=${POREP_MARKET}
FILECOIN_PAY=${FILECOIN_PAY}

# USDFC from curio/docker/data/contracts/contract_addresses.json
USDC_TOKEN=${USDC_TOKEN}
EOF
  chmod 600 "$ENV_FILE"
fi

# Bash 3.2 (macOS /bin/bash) has no mapfile.
MINERS=()
while IFS= read -r miner; do
  miner="$(printf '%s' "$miner" | tr -d '[:space:]')"
  [[ -n "$miner" ]] || continue
  [[ "$miner" =~ ^[tf]0 ]] || continue
  MINERS+=("$miner")
done < <(lotus state list-miners || true)
[[ ${#MINERS[@]} -gt 0 ]] || die "no miners found via 'lotus state list-miners'"
log "found miners: ${MINERS[*]}"

LOTUS_MINER_ID=""
CURIO_MINER_ID=""
if docker inspect -f '{{.State.Running}}' "$LOTUS_MINER_CONTAINER" 2>/dev/null | grep -qx true; then
  # Avoid pipefail/SIGPIPE when awk exits early on long lotus-miner info output.
  LOTUS_MINER_ID="$(
    set +o pipefail
    docker exec "$LOTUS_MINER_CONTAINER" lotus-miner info 2>/dev/null \
      | awk '/^Miner:/{print $2; exit}' \
      | tr -d '[:space:]'
  )"
  log "lotus-miner actor: ${LOTUS_MINER_ID:-unknown}"
fi

# PoRepMarket.getProviderForDeal picks the eligible SP with lowest pendingBytes and
# breaks on the first zero-pending match (registration order). lotus-miner is usually
# listed first and is NOT in Curio's MinerAddresses — do not register it for Curio
# tooling (override with REGISTER_LOTUS_MINER=true if you need lotus-miner deals).
REGISTER_LOTUS_MINER="${REGISTER_LOTUS_MINER:-false}"
REGISTER_MINERS=()
for miner in "${MINERS[@]}"; do
  if [[ -n "$LOTUS_MINER_ID" && "$miner" == "$LOTUS_MINER_ID" && "$REGISTER_LOTUS_MINER" != true ]]; then
    log "skipping lotus-miner ${miner} registration (set REGISTER_LOTUS_MINER=true to include)"
    continue
  fi
  REGISTER_MINERS+=("$miner")
done

if [[ "$SKIP_REGISTER" != true ]]; then
  # V2 ABI: registerProviderFor(provider, organization, availableBytes, payee)
  [[ ${#REGISTER_MINERS[@]} -gt 0 ]] || die "no miners left to register (found ${MINERS[*]}; lotus-miner skipped?)"
  log "registering miners on SPRegistry ${SP_REGISTRY} (V2 registerProviderFor ABI)"
  for miner in "${REGISTER_MINERS[@]}"; do
    pid="$(miner_id_num "$miner")"
    already="$(cast call "$SP_REGISTRY" "isProviderRegistered(uint64)(bool)" "$pid" --rpc-url "$RPC_URL" | tr -d '[:space:]')"
    if [[ "$already" == "true" ]]; then
      log "provider ${pid} (${miner}) already registered — skipping"
      continue
    fi
    log "registerProviderFor provider=${pid} org=${SP_ORGANIZATION}"
    cast send "$SP_REGISTRY" \
      "registerProviderFor(uint64,address,uint256,address)" \
      "$pid" "$SP_ORGANIZATION" "$AVAILABLE_BYTES" "$SP_ORGANIZATION" \
      --private-key "$ADMIN_PRIVATE_KEY" \
      --rpc-url "$RPC_URL" >/dev/null
  done

  # V2 matching needs an allowed payment token + at least one active offer.
  token_allowed="$(
    cast call "$SP_REGISTRY" "getPaymentTokenConfig(address)((bool,uint256))" "$USDC_TOKEN" \
      --rpc-url "$RPC_URL" 2>/dev/null | awk -F'[, ]+' '{gsub(/[()]/,""); print $1; exit}'
  )"
  if [[ "$token_allowed" != "true" ]]; then
    log "setPaymentToken ${USDC_TOKEN} allowed=true minPrice=0"
    cast send "$SP_REGISTRY" \
      "setPaymentToken(address,bool,uint256)" \
      "$USDC_TOKEN" true 0 \
      --private-key "$ADMIN_PRIVATE_KEY" \
      --rpc-url "$RPC_URL" >/dev/null
  else
    log "payment token ${USDC_TOKEN} already allowed — skipping"
  fi

  for miner in "${REGISTER_MINERS[@]}"; do
    pid="$(miner_id_num "$miner")"
    offer_count="$(
      cast call "$SP_REGISTRY" "getOffersByProvider(uint64)(uint256[])" "$pid" \
        --rpc-url "$RPC_URL" 2>/dev/null | tr -d '[][:space:]'
    )"
    if [[ -n "$offer_count" ]]; then
      log "provider ${pid} already has offer(s) — skipping createOffer"
      continue
    fi
    log "createOffer provider=${pid} durationEpochs=${OFFER_MIN_DURATION_EPOCHS}..${OFFER_MAX_DURATION_EPOCHS} price=${OFFER_PRICE_PER_32GIB_PER_MONTH}"
    # terms: (minSize, maxSize, minDurationEpochs, maxDurationEpochs); slis all 0 = don't-care
    cast send "$SP_REGISTRY" \
      "createOffer(uint64,(uint256,uint256,uint64,uint64),(uint16,uint64,uint16,uint8),(address,bool,uint256)[])" \
      "$pid" \
      "(0,0,${OFFER_MIN_DURATION_EPOCHS},${OFFER_MAX_DURATION_EPOCHS})" \
      "(0,0,0,0)" \
      "[(${USDC_TOKEN},true,${OFFER_PRICE_PER_32GIB_PER_MONTH})]" \
      --private-key "$ADMIN_PRIVATE_KEY" \
      --rpc-url "$RPC_URL" >/dev/null
  done
else
  log "skipping provider registration"
fi

# If lotus-miner was registered on an earlier run, pause it so proposeDeal matches Curio.
# pauseProvider is idempotent (just sets paused=true).
if [[ -n "$LOTUS_MINER_ID" ]]; then
  lotus_pid="$(miner_id_num "$LOTUS_MINER_ID")"
  already="$(cast call "$SP_REGISTRY" "isProviderRegistered(uint64)(bool)" "$lotus_pid" --rpc-url "$RPC_URL" | tr -d '[:space:]')"
  if [[ "$already" == "true" ]]; then
    log "pausing lotus-miner provider ${lotus_pid} (${LOTUS_MINER_ID}) so proposeDeal matches Curio miner"
    cast send "$SP_REGISTRY" "pauseProvider(uint64)" "$lotus_pid" \
      --private-key "$ADMIN_PRIVATE_KEY" \
      --rpc-url "$RPC_URL" >/dev/null || log "warning: pauseProvider failed (chain stuck?); pause manually when chain advances"
  fi
fi

CURIO_MINER_ID=""
for miner in "${MINERS[@]}"; do
  if [[ -z "$LOTUS_MINER_ID" || "$miner" != "$LOTUS_MINER_ID" ]]; then
    CURIO_MINER_ID="$miner"
    break
  fi
done
if [[ -n "$CURIO_MINER_ID" ]]; then
  if grep -qE '^CURIO_MINER_ID=' "$ENV_FILE"; then
    sed -i.bak "s|^CURIO_MINER_ID=.*|CURIO_MINER_ID=${CURIO_MINER_ID}|" "$ENV_FILE"
    rm -f "${ENV_FILE}.bak"
  else
    printf 'CURIO_MINER_ID=%s\n' "$CURIO_MINER_ID" >>"$ENV_FILE"
  fi
  log "CURIO_MINER_ID=${CURIO_MINER_ID} written to ${ENV_FILE}"
fi

if [[ "$SKIP_CONTROL" != true ]]; then
  log "adding org wallet as extra miner control address (${ORG_T410}); keeping BLS worker as WindowPoSt sender"
  for miner in "${MINERS[@]}"; do
    pid="$(miner_id_num "$miner")"

    # lotus-miner is consensus-only here (not registered for deals). Touching its
    # post control with an eth key faults 100% network power at WPoSt deadline close.
    if [[ -n "$LOTUS_MINER_ID" && "$miner" == "$LOTUS_MINER_ID" && "$REGISTER_LOTUS_MINER" != true ]]; then
      log "skipping control set on lotus-miner ${miner} (consensus miner; set REGISTER_LOTUS_MINER=true to include)"
      continue
    fi

    set +e
    auth="$(is_authorized_for_provider "$pid")"
    set -e
    if [[ "$auth" == "true" ]]; then
      log "org already authorized for provider ${pid} (${miner}) — skipping control set"
      continue
    fi

    POST_KEY="$(miner_post_key "$miner")"
    [[ -n "$POST_KEY" ]] || die "could not resolve non-eth worker/post key for ${miner} (try: sptool --actor ${miner} actor control list --verbose)"
    if [[ "$POST_KEY" == t410* || "$POST_KEY" == f410* || "$POST_KEY" == *...* ]] || ! [[ "$POST_KEY" =~ ^[tf][0-9a-z]+$ ]]; then
      die "refusing control set on ${miner}: invalid post/worker key '${POST_KEY}' (need full BLS/secp address from control list --verbose)"
    fi

    CONTROL_OUT=""
    if [[ -n "$LOTUS_MINER_ID" && "$miner" == "$LOTUS_MINER_ID" ]]; then
      require_container "$LOTUS_MINER_CONTAINER"
      log "lotus-miner actor control set ${miner} (post=${POST_KEY}, org=${ORG_T410})"
      CONTROL_OUT="$(
        docker exec "$LOTUS_MINER_CONTAINER" \
          lotus-miner actor control set --really-do-it "$POST_KEY" "$ORG_T410" 2>&1
      )" || die "lotus-miner actor control set failed for ${miner}: ${CONTROL_OUT}"
    else
      require_container "$CURIO_CONTAINER"
      log "sptool --actor ${miner} actor control set (post=${POST_KEY}, org=${ORG_T410})"
      CONTROL_OUT="$(
        docker exec "$CURIO_CONTAINER" \
          sptool --actor "$miner" actor control set --really-do-it "$POST_KEY" "$ORG_T410" 2>&1
      )" || die "sptool actor control set failed for ${miner}: ${CONTROL_OUT}"
    fi
    printf '%s\n' "$CONTROL_OUT"

    CONTROL_CID="$(extract_msg_cid "$CONTROL_OUT")"
    if [[ -n "$CONTROL_CID" ]]; then
      if ! wait_msg "$CONTROL_CID"; then
        log "wait-msg timed out for ${CONTROL_CID}; polling isAuthorizedForProvider instead"
      fi
    else
      log "no message cid in control-set output; polling isAuthorizedForProvider"
    fi
    wait_until_authorized "$pid"
  done
else
  log "skipping miner control-address updates"
fi

if [[ "$SKIP_DATACAP" != true ]]; then
  existing_dc="$(client_datacap_bytes "$EVIDENCE_ADAPTER_T410")"
  if [[ -n "$existing_dc" && "$existing_dc" -gt 0 ]]; then
    log "DataCapEvidenceAdapter already has DataCap (${existing_dc} bytes) — skipping grant"
  else
    NOTARY="$(pick_notary)"
    [[ -n "$NOTARY" ]] || die "no notary with allowance found (lotus filplus list-notaries)"
    log "granting ${DATACAP_GRANT_BYTES} DataCap bytes to DataCapEvidenceAdapter ${EVIDENCE_ADAPTER_T410} from notary ${NOTARY}"
    GRANT_OUT="$(lotus filplus grant-datacap --from "$NOTARY" "$EVIDENCE_ADAPTER_T410" "$DATACAP_GRANT_BYTES" 2>&1)" \
      || die "grant-datacap failed: ${GRANT_OUT}"
    printf '%s\n' "$GRANT_OUT"
    GRANT_CID="$(extract_msg_cid "$GRANT_OUT")"
    if [[ -n "$GRANT_CID" ]]; then
      if ! wait_msg "$GRANT_CID"; then
        log "wait-msg timed out for ${GRANT_CID}; checking DataCap directly"
      fi
    fi
    existing_dc="$(client_datacap_bytes "$EVIDENCE_ADAPTER_T410")"
    [[ -n "$existing_dc" && "$existing_dc" -gt 0 ]] \
      || die "DataCapEvidenceAdapter still has no DataCap after grant (${EVIDENCE_ADAPTER_T410})"
    log "DataCapEvidenceAdapter DataCap now ${existing_dc} bytes"
  fi
else
  log "skipping DataCapEvidenceAdapter DataCap grant"
fi

cat <<EOF

Setup complete.

  .env                 ${ENV_FILE}
  SP org (t410)        ${ORG_T410}
  SP org (0x)          ${SP_ORGANIZATION}
  PoRepMarket          ${POREP_MARKET}
  SPRegistry           ${SP_REGISTRY}
  Evidence adapter     ${EVIDENCE_ADAPTER} (${EVIDENCE_ADAPTER_T410})
  MetaAllocator        ${META_ALLOCATOR}
  miners registered    ${REGISTER_MINERS[*]}
  all miners seen      ${MINERS[*]}
  lotus-miner          ${LOTUS_MINER_ID:-n/a} (skipped unless REGISTER_LOTUS_MINER=true; paused if already registered)
  Curio miner          ${CURIO_MINER_ID:-n/a}

Notes:
  - Control addresses were waited on and isAuthorizedForProvider checked (unless --skip-control).
  - DataCapEvidenceAdapter DataCap was granted for make-allocations (unless --skip-datacap).
  - MetaAllocator must be a contract (NoOpMetaAllocator from deploy.sh); EOA stubs break transfer.
  - Only Curio miners are registered by default so proposeDeal does not pick lotus-miner.
  - Org wallet is an *extra* control address; BLS worker stays WindowPoSt sender (eth-as-post freezes the chain at ~718).
  - lotus-miner control is not touched unless REGISTER_LOTUS_MINER=true.
EOF

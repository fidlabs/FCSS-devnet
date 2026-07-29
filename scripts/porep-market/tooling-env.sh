#!/usr/bin/env bash
# Emit public shell exports for tooling / external clients from ACTIVE deployment.
# Never prints private keys.
#
# Usage:
#   eval "$(./scripts/porep-market/tooling-env.sh)"
#   just porep-market tooling-env
#
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/deployment.sh
source "${SCRIPT_DIR}/../lib/deployment.sh"

require_cmd jq

manifest="$(active_latest_json)" || die "no ACTIVE/latest.json — run just porep-market deploy"
require_file "$manifest"

jq_addr() {
  local expr="$1"
  jq -r "$expr // empty" "$manifest" | tr -d '[:space:]'
}

POREP_MARKET="$(jq_addr '.contracts.PoRepMarket.proxy')"
SP_REGISTRY="$(jq_addr '.contracts.SPRegistry.proxy // .contracts.SPRegistry.address')"
DATACAP_EVIDENCE_ADAPTER="$(jq_addr '.contracts.DataCapEvidenceAdapter.proxy')"
FILECOIN_PAY="$(jq_addr '.externalDependencies.FilecoinPay // .contracts.FilecoinPay.proxy // .contracts.FilecoinPay.address')"
USDC_TOKEN="$(jq_addr '.contracts.USDC.proxy // .contracts.USDC.address // .externalDependencies.USDC')"
VIEW_HELPER="$(jq_addr '.contracts.PoRepMarketViewHelper.address // .contracts.PoRepMarketViewHelper.proxy')"
CLAIM_INSPECTOR="$(jq_addr '.contracts.PoRepMarketClaimInspector.address // .contracts.PoRepMarketClaimInspector.proxy')"
SECTOR_INSPECTOR="$(jq_addr '.contracts.PoRepMarketSectorStatusInspector.address // .contracts.PoRepMarketSectorStatusInspector.proxy')"
META_ALLOCATOR="$(jq_addr '.externalDependencies.MetaAllocator // .metaAllocator // .contracts.NoOpMetaAllocator.address')"
CHAIN_ID="$(jq -r '.chainId // .chain_id // empty' "$manifest" | tr -d '[:space:]')"
: "${CHAIN_ID:=31415926}"

# Prefer lockfile / ports defaults for RPC.
cat <<EOF
export RPC_URL='${RPC_URL}'
export CHAIN_ID='${CHAIN_ID}'
export POREP_MARKET='${POREP_MARKET}'
export SP_REGISTRY='${SP_REGISTRY}'
export DATACAP_EVIDENCE_ADAPTER='${DATACAP_EVIDENCE_ADAPTER}'
export FILECOIN_PAY='${FILECOIN_PAY}'
export USDC_TOKEN='${USDC_TOKEN}'
export POREP_MARKET_VIEW_HELPER='${VIEW_HELPER}'
export POREP_MARKET_CLAIM_INSPECTOR='${CLAIM_INSPECTOR}'
export POREP_MARKET_SECTOR_STATUS_INSPECTOR='${SECTOR_INSPECTOR}'
export META_ALLOCATOR='${META_ALLOCATOR}'
EOF

#!/usr/bin/env bash
# Propose → accept → init → allocate → onboard-data → claim-allocations (curio) → add-url
# for a Singularity manifest already served locally
# (default: http://127.0.0.1:8080/manifest.json).
#
# Exits once every unclaimed allocation has a Curio piece URL. On-chain claims /
# sealing are left to Curio; poll with `sp get-claims` / `--wait-claims` if needed.
#
# Prerequisites:
#   - scripts/up-porep.sh completed (Curio SP registered, control addr, DataCap, MetaAllocator)
#   - lotus-miner should NOT be the matched provider (setup skips/pauses it; make-deal re-checks)
#   - Singularity pieces prepared; manifest JSON reachable on MANIFEST_URL
#   - .env configured (CLIENT_*, SP_*, POREP_MARKET, FILECOIN_PAY, USDC_TOKEN)
#   - aria2c on PATH (or ARIA2C_PATH) for sp onboard-data
#   - CURIO_PATH pointing at scripts/curio-cli.sh (or a local curio binary) for claim
#
# Compatible with macOS /bin/bash 3.2 (no mapfile).
#
# Usage:
#   ./scripts/make-deal.sh
#   just make-deal
#   ./scripts/make-deal.sh --manifest-url http://127.0.0.1:8080/manifest.json
#   ./scripts/make-deal.sh --deal-id 1          # resume incomplete deal
#   ./scripts/make-deal.sh --wait-claims        # also poll until on-chain claims finish
#   ./scripts/make-deal.sh --skip-onboard       # stop after make-allocations
#   ./scripts/make-deal.sh --skip-claim         # onboard cars but do not claim into Curio
#
# Without --deal-id, resumes an incomplete deal for MANIFEST_URL if present; otherwise proposes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/envfile.sh
source "${SCRIPT_DIR}/lib/envfile.sh"

ENV_FILE="${ENV_FILE:-${TOOLING_DIR}/.env}"

if [[ -x "${TOOLING_DIR}/.venv/bin/python" ]]; then
  PYTHON="${TOOLING_DIR}/.venv/bin/python"
else
  PYTHON="${PYTHON:-python3}"
fi
CLI=("$PYTHON" "${TOOLING_DIR}/porep_tooling_cli.py")

MANIFEST_URL="${MANIFEST_URL:-http://127.0.0.1:8080/manifest.json}"
PRICE_PER_SECTOR_PER_MONTH="${PRICE_PER_SECTOR_PER_MONTH:-2000000000000000000}" # 2 USDFC
DURATION_MONTHS="${DURATION_MONTHS:-6}"
RETRIEVABILITY_BPS="${RETRIEVABILITY_BPS:-0}"
BANDWIDTH_MBPS="${BANDWIDTH_MBPS:-0}"
LATENCY_MS="${LATENCY_MS:-0}"
INDEXING_PCT="${INDEXING_PCT:-0}"
ONBOARD_DIR="${ONBOARD_DIR:-}"
DEAL_ID="${DEAL_ID:-}"
# URL Curio uses to fetch offline piece CARs (must be reachable from the curio container).
# Singularity content-provider is typically published on the host as :7777 — use
# host.docker.internal so Curio (compose) can reach it. piece-server:7777 is WRONG
# (piece-server only exposes :12320 and does not serve these CARs).
PIECE_BASE_URL="${PIECE_BASE_URL:-http://host.docker.internal:7777/piece}"
YUGABYTE_CONTAINER="${YUGABYTE_CONTAINER:-yugabyte}"
SKIP_ONBOARD=false
SKIP_CLAIM=false
# Default: exit after Curio piece URLs are attached. Opt in with --wait-claims.
WAIT_CLAIMS=false
YES=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --manifest-url URL              Manifest URL (default: ${MANIFEST_URL})
  --price-per-sector-per-month N  Wei-equivalent USDFC / sector / month (default: ${PRICE_PER_SECTOR_PER_MONTH})
  --duration-months N             Deal duration in months, min 6 (default: ${DURATION_MONTHS})
  --deal-id N                     Skip propose; resume from this deal id
  --onboard-dir DIR               Directory for sp onboard-data (default: ./deal-<id>)
  --piece-base-url URL            Piece CAR base URL for Curio add-url (default: ${PIECE_BASE_URL})
  --skip-onboard                  Stop after make-allocations
  --skip-claim                    Skip claim-allocations / add-url (still onboard unless --skip-onboard)
  --wait-claims                   Also poll until on-chain claims finish (default: exit after URLs)
  --no-wait-claims                Explicit default: exit after add-url
  --wait-claims-timeout N         Seconds to wait when --wait-claims (default: ${WAIT_CLAIMS_TIMEOUT:-1800})
  --interactive                   Do not pipe 'yes' into CLI confirms
  -h, --help                      Show this help

Without --deal-id, resumes an incomplete deal for MANIFEST_URL if one exists; otherwise proposes a new deal.
Environment overrides match the option names (MANIFEST_URL, PIECE_BASE_URL, WAIT_CLAIMS, WAIT_CLAIMS_TIMEOUT, …).
EOF
}

resolve_aria2c() {
  local path
  path="$(env_get ARIA2C_PATH 2>/dev/null || true)"
  if [[ -n "$path" && -x "$path" ]]; then
    printf '%s\n' "$path"
    return 0
  fi
  if command -v aria2c >/dev/null 2>&1; then
    command -v aria2c
    return 0
  fi
  return 1
}

ensure_aria2c() {
  local path
  if path="$(resolve_aria2c)"; then
    export ARIA2C_PATH="$path"
    if [[ "$(env_get ARIA2C_PATH 2>/dev/null || true)" != "$path" ]]; then
      set_env_key ARIA2C_PATH "$path"
    fi
    log "using aria2c at ${path}"
    return 0
  fi
  die "aria2c not found (needed for onboard-data). Install with: brew install aria2"
}

ensure_curio() {
  local path wrapper
  wrapper="${SCRIPT_DIR}/curio-cli.sh"
  path="$(env_get CURIO_PATH 2>/dev/null || true)"
  if [[ -z "$path" || ! -x "$path" ]]; then
    if [[ -x "$wrapper" ]]; then
      path="$wrapper"
    elif command -v curio >/dev/null 2>&1; then
      path="$(command -v curio)"
    else
      die "curio not found (needed for claim-allocations). Set CURIO_PATH or use scripts/curio-cli.sh"
    fi
    set_env_key CURIO_PATH "$path"
  fi
  export CURIO_PATH="$path"
  # Smoke-check (docker wrapper talks to compose curio service).
  if ! "$path" --version >/dev/null 2>&1; then
    die "CURIO_PATH=${path} failed '--version' (is the curio compose service running?)"
  fi
  log "using curio at ${path}"
}

miner_id_num() {
  # t01000 / f01000 / f01003 -> 1000 / 1003
  echo "$1" | sed -E 's/^[tf]0*//'
}

provider_num_from_deal() {
  cli_json_retry client get-deal "$1" | jq -r '.provider_id' | sed -E 's/^[tf]0*//'
}

resolve_lotus_miner_id() {
  local id
  id="$(env_get LOTUS_MINER_ID 2>/dev/null || true)"
  if [[ -n "$id" ]]; then
    printf '%s\n' "$id"
    return 0
  fi
  if docker inspect -f '{{.State.Running}}' "${LOTUS_MINER_CONTAINER:-lotus-miner}" 2>/dev/null | grep -qx true; then
    set +o pipefail
    id="$(
      docker exec "${LOTUS_MINER_CONTAINER:-lotus-miner}" lotus-miner info 2>/dev/null \
        | awk '/^Miner:/{print $2; exit}' \
        | tr -d '[:space:]'
    )"
    set -o pipefail
    [[ -n "$id" ]] && printf '%s\n' "$id"
  fi
}

resolve_curio_miner_id() {
  local id
  id="$(env_get CURIO_MINER_ID 2>/dev/null || true)"
  if [[ -n "$id" ]]; then
    printf '%s\n' "$id"
    return 0
  fi
  # Curio base config MinerAddresses (from Yugabyte harmony_config).
  id="$(
    docker exec "${YUGABYTE_CONTAINER}" bash -lc \
      "ysqlsh -h yugabyte -p 5433 -U yugabyte -At -c \"SET search_path TO curio; SELECT config FROM harmony_config WHERE title='base' LIMIT 1;\"" \
      2>/dev/null \
      | grep -oE 'MinerAddresses[[:space:]]*=[[:space:]]*\[[^]]*\]' \
      | grep -oE '[tf]0[0-9]+' \
      | head -n1 \
      | tr -d '[:space:]'
  )"
  [[ -n "$id" ]] && printf '%s\n' "$id"
}

# Pause lotus-miner in SPRegistry so getProviderForDeal selects Curio's miner.
# Deal 1 went to t01000 because both SPs had pending=0 and lotus-miner is first.
ensure_lotus_miner_paused() {
  local lotus_id lotus_pid sp_registry rpc pk already
  lotus_id="$(resolve_lotus_miner_id || true)"
  [[ -n "$lotus_id" ]] || {
    log "lotus-miner id unknown — skipping pause (set LOTUS_MINER_ID if needed)"
    return 0
  }
  lotus_pid="$(miner_id_num "$lotus_id")"
  sp_registry="$(
    cast call "$(env_get POREP_MARKET)" "getSPRegistryContract()(address)" \
      --rpc-url "$(env_get RPC_URL)" | tr -d '[:space:]'
  )"
  rpc="$(env_get RPC_URL)"
  pk="$(env_get ADMIN_PRIVATE_KEY)"
  already="$(cast call "$sp_registry" "isProviderRegistered(uint64)(bool)" "$lotus_pid" --rpc-url "$rpc" | tr -d '[:space:]')"
  if [[ "$already" != "true" ]]; then
    log "lotus-miner ${lotus_id} not registered — nothing to pause"
    return 0
  fi
  log "pausing lotus-miner provider ${lotus_pid} (${lotus_id}) so proposeDeal matches Curio"
  cast send "$sp_registry" "pauseProvider(uint64)" "$lotus_pid" \
    --private-key "$pk" \
    --rpc-url "$rpc" >/dev/null
}

assert_deal_provider_is_curio() {
  local deal_id="$1"
  local provider_num curio_id curio_num lotus_id lotus_num
  provider_num="$(provider_num_from_deal "$deal_id")"
  curio_id="$(resolve_curio_miner_id || true)"
  lotus_id="$(resolve_lotus_miner_id || true)"
  [[ -n "$provider_num" ]] || die "could not resolve provider for deal ${deal_id}"

  if [[ -n "$lotus_id" ]]; then
    lotus_num="$(miner_id_num "$lotus_id")"
    if [[ "$provider_num" == "$lotus_num" ]]; then
      die "deal ${deal_id} matched lotus-miner t0${lotus_num} (not in Curio MinerAddresses). Pause it (setup/make-deal does this) and propose a new deal."
    fi
  fi
  if [[ -n "$curio_id" ]]; then
    curio_num="$(miner_id_num "$curio_id")"
    if [[ "$provider_num" != "$curio_num" ]]; then
      die "deal ${deal_id} provider t0${provider_num} != Curio miner ${curio_id}. Aborting before claim."
    fi
  fi
  log "deal ${deal_id} provider t0${provider_num} matches Curio miner — OK"
}

deal_claim_count() {
  local deal_id="$1"
  cli_json_retry sp get-claims "$deal_id" | jq 'length'
}

deal_allocation_count() {
  local deal_id="$1"
  cli_json_retry sp get-allocations "$deal_id" | jq 'length'
}

# Attach HTTP piece URLs to existing Curio offline DDOs so the seal pipeline can start.
# claim-allocations / `curio market ddo` only inserts DB rows; without PieceLocator hits or
# add-url, deals stay started=false forever.
#
# Hardening: snapshot all currently-unclaimed allocations, retry DDO/pipeline lookup + add-url,
# then refuse to exit cleanly if any still lack a URL / started flag.
attach_curio_piece_urls() {
  local deal_id="$1"
  local provider_num piece_cid file_size alloc_id uuid url started url_len
  local tmp i rc missing line
  ensure_curio

  local manifest_file="${ONBOARD_DIR}/manifest_${deal_id}.json"
  if [[ ! -f "$manifest_file" ]]; then
    die "manifest not found at ${manifest_file}; run onboard-data first"
  fi

  provider_num="$(
    cli_json_retry client get-deal "$deal_id" | jq -r '.provider_id' | sed -E 's/^[tf]0*//'
  )"
  [[ -n "$provider_num" ]] || die "could not resolve provider id for deal ${deal_id}"

  tmp="$(mktemp)"
  # Drop blank lines so wc -l matches real allocations (blank lines previously caused
  # silent skips and a false "2 to attach" while only alloc 2 was processed).
  cli_json_retry sp get-allocations "$deal_id" \
    | jq -r 'to_entries[] | select(.key != null and .value.Data["/"] != null)
             | "\(.key)\t\(.value.Data["/"])"' \
    | grep -E '^[0-9]+[[:space:]]+baga' >"$tmp" || true
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    log "no unclaimed allocations left for deal ${deal_id} — nothing to add-url"
    return 0
  fi

  log "attaching piece URLs for Curio offline DDOs (provider=${provider_num}, base ${PIECE_BASE_URL})"
  log "unclaimed allocations to attach: $(wc -l <"$tmp" | tr -d '[:space:]')"
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '  %s\n' "$line" >&2
  done <"$tmp"

  # Use FD 3 for the alloc list — curio-cli.sh / docker compose exec inherit
  # stdin and would otherwise consume remaining lines after the first add-url.
  while IFS=$'\t' read -r alloc_id piece_cid <&3 || [[ -n "$alloc_id" ]]; do
    alloc_id="$(printf '%s' "$alloc_id" | tr -d '[:space:]')"
    piece_cid="$(printf '%s' "$piece_cid" | tr -d '[:space:]')"
    if [[ -z "$alloc_id" || -z "$piece_cid" ]]; then
      log "skipping malformed allocation line (alloc_id='${alloc_id}' piece_cid='${piece_cid}')"
      continue
    fi

    log "processing allocation ${alloc_id} piece=${piece_cid}"

    file_size="$(
      jq -r --arg cid "$piece_cid" '
        [.[].pieces[]? | select(.pieceCid == $cid) | .fileSize] | first // empty
      ' "$manifest_file"
    )"
    [[ -n "$file_size" ]] || die "fileSize missing in manifest for piece ${piece_cid}"

    uuid=""
    for i in $(seq 1 30); do
      uuid="$(
        docker exec "$YUGABYTE_CONTAINER" bash -lc \
          "ysqlsh -h yugabyte -p 5433 -U yugabyte -At -c \"SET search_path TO curio; SELECT uuid FROM market_direct_deals WHERE sp_id=${provider_num} AND allocation_id=${alloc_id} ORDER BY created_at DESC LIMIT 1;\"" \
          </dev/null 2>/dev/null | tr -d '[:space:]'
      )"
      # Wait until the mk12 pipeline row exists too (DDO insert can race ahead of pipeline).
      if [[ -n "$uuid" ]]; then
        started="$(
          docker exec "$YUGABYTE_CONTAINER" bash -lc \
            "ysqlsh -h yugabyte -p 5433 -U yugabyte -At -c \"SET search_path TO curio; SELECT started FROM market_mk12_deal_pipeline WHERE uuid='${uuid}';\"" \
            </dev/null 2>/dev/null | tr -d '[:space:]'
        )"
        # Empty started means no pipeline row yet (SELECT returns no rows).
        if [[ -n "$started" ]]; then
          break
        fi
      fi
      log "waiting for Curio DDO+pipeline row allocation_id=${alloc_id} (${i}/30)"
      sleep 2
    done
    if [[ -z "$uuid" || -z "$started" ]]; then
      log "no Curio DDO/pipeline row for allocation_id=${alloc_id} after retries"
      rm -f "$tmp"
      return 1
    fi

    url_len="$(
      docker exec "$YUGABYTE_CONTAINER" bash -lc \
        "ysqlsh -h yugabyte -p 5433 -U yugabyte -At -c \"SET search_path TO curio; SELECT COALESCE(length(url),0) FROM market_mk12_deal_pipeline WHERE uuid='${uuid}';\"" \
        </dev/null 2>/dev/null | tr -d '[:space:]'
    )"
    if [[ "$started" == "t" || "$started" == "true" ]] && [[ -n "$url_len" && "$url_len" -gt 0 ]]; then
      log "allocation ${alloc_id} uuid=${uuid} already started with url — skipping add-url"
      continue
    fi
    # If started without URL, or not started, always (re)attach URL.
    if [[ "$started" == "t" || "$started" == "true" ]] && [[ -z "$url_len" || "$url_len" -eq 0 ]]; then
      log "allocation ${alloc_id} started=true but url empty — attaching URL anyway"
    fi

    url="${PIECE_BASE_URL%/}/${piece_cid}"
    rc=1
    for i in $(seq 1 5); do
      log "curio market add-url allocation=${alloc_id} uuid=${uuid} raw_size=${file_size} url=${url} (try ${i}/5)"
      set +e
      "$CURIO_PATH" market add-url --url "$url" "$uuid" "$file_size" </dev/null
      rc=$?
      set -e
      if [[ $rc -eq 0 ]]; then
        break
      fi
      log "add-url failed for allocation ${alloc_id} (rc=${rc}); retrying"
      sleep 3
    done
    if [[ $rc -ne 0 ]]; then
      log "curio market add-url failed for allocation ${alloc_id} uuid=${uuid} after retries"
      rm -f "$tmp"
      return 1
    fi

    url_len=0
    for i in $(seq 1 20); do
      url_len="$(
        docker exec "$YUGABYTE_CONTAINER" bash -lc \
          "ysqlsh -h yugabyte -p 5433 -U yugabyte -At -c \"SET search_path TO curio; SELECT COALESCE(length(url),0) FROM market_mk12_deal_pipeline WHERE uuid='${uuid}';\"" \
          </dev/null 2>/dev/null | tr -d '[:space:]'
      )"
      [[ -n "$url_len" && "$url_len" -gt 0 ]] && break
      sleep 1
    done
    if [[ -z "$url_len" || "$url_len" -eq 0 ]]; then
      log "add-url returned OK for allocation ${alloc_id} but pipeline url is still empty (uuid=${uuid})"
      rm -f "$tmp"
      return 1
    fi
    log "allocation ${alloc_id} url attached (${url_len} chars)"
  done 3<"$tmp"
  rm -f "$tmp"

  # Final gate + last-chance add-url for anything still missing.
  missing=0
  while IFS=$'\t' read -r alloc_id piece_cid || [[ -n "$alloc_id" ]]; do
    alloc_id="$(printf '%s' "$alloc_id" | tr -d '[:space:]')"
    piece_cid="$(printf '%s' "$piece_cid" | tr -d '[:space:]')"
    [[ -n "$alloc_id" && -n "$piece_cid" ]] || continue
    uuid="$(
      docker exec "$YUGABYTE_CONTAINER" bash -lc \
        "ysqlsh -h yugabyte -p 5433 -U yugabyte -At -c \"SET search_path TO curio; SELECT uuid FROM market_direct_deals WHERE sp_id=${provider_num} AND allocation_id=${alloc_id} ORDER BY created_at DESC LIMIT 1;\"" \
        2>/dev/null | tr -d '[:space:]'
    )"
    started="$(
      docker exec "$YUGABYTE_CONTAINER" bash -lc \
        "ysqlsh -h yugabyte -p 5433 -U yugabyte -At -c \"SET search_path TO curio; SELECT started FROM market_mk12_deal_pipeline WHERE uuid='${uuid}';\"" \
        2>/dev/null | tr -d '[:space:]'
    )"
    url_len="$(
      docker exec "$YUGABYTE_CONTAINER" bash -lc \
        "ysqlsh -h yugabyte -p 5433 -U yugabyte -At -c \"SET search_path TO curio; SELECT COALESCE(length(url),0) FROM market_mk12_deal_pipeline WHERE uuid='${uuid}';\"" \
        2>/dev/null | tr -d '[:space:]'
    )"
    if [[ "$started" == "t" || "$started" == "true" ]] && [[ -n "$url_len" && "$url_len" -gt 0 ]]; then
      continue
    fi

    file_size="$(
      jq -r --arg cid "$piece_cid" '
        [.[].pieces[]? | select(.pieceCid == $cid) | .fileSize] | first // empty
      ' "$manifest_file"
    )"
    if [[ -n "$uuid" && -n "$file_size" ]]; then
      url="${PIECE_BASE_URL%/}/${piece_cid}"
      log "last-chance add-url allocation=${alloc_id} uuid=${uuid}"
      set +e
      "$CURIO_PATH" market add-url --url "$url" "$uuid" "$file_size" </dev/null
      set -e
      url_len=0
      for i in $(seq 1 20); do
        url_len="$(
          docker exec "$YUGABYTE_CONTAINER" bash -lc \
            "ysqlsh -h yugabyte -p 5433 -U yugabyte -At -c \"SET search_path TO curio; SELECT COALESCE(length(url),0) FROM market_mk12_deal_pipeline WHERE uuid='${uuid}';\"" \
            </dev/null 2>/dev/null | tr -d '[:space:]'
        )"
        [[ -n "$url_len" && "$url_len" -gt 0 ]] && break
        sleep 1
      done
    fi
    if [[ -z "$url_len" || "$url_len" -eq 0 ]]; then
      log "MISSING piece URL for allocation ${alloc_id} uuid=${uuid:-none} piece=${piece_cid}"
      missing=$((missing + 1))
    fi
  done < <(
    cli_json_retry sp get-allocations "$deal_id" \
      | jq -r 'to_entries[] | select(.value.Data["/"] != null) | "\(.key)\t\(.value.Data["/"])"' \
      | grep -E '^[0-9]+[[:space:]]+baga' || true
  )
  if [[ "$missing" -ne 0 ]]; then
    log "${missing} unclaimed allocation(s) still lack Curio piece URLs"
    return 1
  fi
  log "all unclaimed allocations have Curio piece URLs (or are already started)"
  return 0
}

# Feed CLI confirms. 'y' is accepted as short for 'yes' by cli.utils.confirm_str.
run_cli() {
  if [[ "$YES" == true ]]; then
    # `yes` gets SIGPIPE when the CLI exits; don't let pipefail abort on that.
    set +o pipefail
    yes | "${CLI[@]}" "$@"
    local rc=${PIPESTATUS[1]:-0}
    set -o pipefail
    return "$rc"
  else
    "${CLI[@]}" "$@"
  fi
}

# Retry mutating CLI calls across Lotus tipset/fork races and transient FEVM errors.
run_cli_retry() {
  local attempts="${CLI_MUTATE_ATTEMPTS:-8}"
  local sleep_s="${CLI_MUTATE_SLEEP:-5}"
  local i rc
  for i in $(seq 1 "$attempts"); do
    set +e
    run_cli "$@"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      return 0
    fi
    log "CLI '$*' failed (rc=${rc}, attempt ${i}/${attempts}); retrying in ${sleep_s}s"
    sleep "$sleep_s"
  done
  die "CLI command failed after ${attempts} attempts: $*"
}

cli_json() {
  # Read-only CLI helpers (no confirms).
  "${CLI[@]}" "$@"
}

# Lotus FEVM often returns "refusing explicit call due to state fork at epoch"
# right after a reset / tipset race. Retry read-only CLI until JSON parses.
# Only stdout is returned (so callers can pipe to jq). Progress logs go to stderr.
cli_json_retry() {
  local attempts="${CLI_RETRY_ATTEMPTS:-40}"
  local sleep_s="${CLI_RETRY_SLEEP:-3}"
  local i out err rc errf
  for i in $(seq 1 "$attempts"); do
    errf="$(mktemp)"
    set +e
    out="$("${CLI[@]}" "$@" 2>"$errf")"
    rc=$?
    set -e
    err="$(cat "$errf" 2>/dev/null || true)"
    rm -f "$errf"

    if [[ $rc -eq 0 ]] && printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
      printf '%s\n' "$out"
      return 0
    fi
    if printf '%s\n%s' "$out" "$err" | grep -qiE 'state fork|refusing explicit call|BadFunctionCallOutput|Could not transact'; then
      log "transient Lotus/FEVM read error (${i}/${attempts}); retrying"
      sleep "$sleep_s"
      continue
    fi
    if [[ $rc -ne 0 ]]; then
      [[ -n "$err" ]] && printf '%s\n' "$err" >&2
      [[ -n "$out" ]] && printf '%s\n' "$out" >&2
      return "$rc"
    fi
    # Non-JSON success (shouldn't happen for get-deal/get-deals) — retry briefly.
    log "CLI returned non-JSON (${i}/${attempts}); retrying"
    sleep "$sleep_s"
  done
  [[ -n "$err" ]] && printf '%s\n' "$err" >&2
  [[ -n "$out" ]] && printf '%s\n' "$out" >&2
  die "CLI read failed after ${attempts} attempts: $*"
}

wait_deal_state() {
  local deal_id="$1"
  local want="$2"
  local attempts="${3:-60}"
  local i state
  for i in $(seq 1 "$attempts"); do
    state="$(cli_json_retry client get-deal "$deal_id" | jq -r '.state')"
    if [[ "$state" == "$want" ]]; then
      log "deal ${deal_id} state=${state}"
      return 0
    fi
    sleep 2
  done
  die "deal ${deal_id} did not reach ${want} (last state=${state:-unknown})"
}

latest_deal_id_for_manifest() {
  local manifest="$1"
  local state="${2:-}"
  local args=(client get-deals)
  [[ -n "$state" ]] && args+=("$state")
  cli_json_retry "${args[@]}" | jq -r --arg m "$manifest" '
    [.[] | select(.manifest_location == $m)]
    | if length == 0 then empty else max_by(.deal_id) | .deal_id end
  '
}

# Poll until get-deals can see the just-proposed deal (tipset fork races after reset).
wait_deal_id_for_manifest() {
  local manifest="$1"
  local attempts="${2:-40}"
  local i deal_id
  for i in $(seq 1 "$attempts"); do
    deal_id="$(latest_deal_id_for_manifest "$manifest" proposed 2>/dev/null || true)"
    if [[ -z "$deal_id" ]]; then
      deal_id="$(latest_deal_id_for_manifest "$manifest" 2>/dev/null || true)"
    fi
    if [[ -n "$deal_id" ]]; then
      printf '%s\n' "$deal_id"
      return 0
    fi
    log "waiting for proposed deal to appear in get-deals (${i}/${attempts})"
    sleep 3
  done
  return 1
}

# Prefer dealId from DealProposalCreated (indexed topic[1]) on the propose tx.
deal_id_from_propose_tx() {
  local tx_hash="$1"
  local topic rpc market
  [[ "$tx_hash" =~ ^0x[0-9a-fA-F]{64}$ ]] || return 1
  rpc="$(env_get RPC_URL)"
  market="$(env_get POREP_MARKET | tr '[:upper:]' '[:lower:]')"
  topic="$(
    cast receipt "$tx_hash" --rpc-url "$rpc" --json 2>/dev/null \
      | jq -r --arg m "$market" '
          .logs[]
          | select((.address | ascii_downcase) == $m)
          | .topics[1] // empty
        ' \
      | head -n1
  )"
  # Older jq without ascii_downcase: fall back to any log whose address matches ignoring case via bash.
  if [[ -z "$topic" || "$topic" == "null" ]]; then
    topic="$(
      cast receipt "$tx_hash" --rpc-url "$rpc" --json 2>/dev/null \
        | jq -r '.logs[] | [.address, .topics[1]] | @tsv' \
        | while IFS=$'\t' read -r addr t; do
            if [[ "$(printf '%s' "$addr" | tr '[:upper:]' '[:lower:]')" == "$market" ]]; then
              printf '%s\n' "$t"
              break
            fi
          done
    )"
  fi
  [[ -n "$topic" && "$topic" != "null" ]] || return 1
  # strip 0x and leading zeros
  printf '%s\n' "$topic" | sed -E 's/^0x//; s/^0+//; s/^$/0/'
}

# Curio USDFC has no EIP-2612 permit. After validator deploy, approve operator via cast.
ensure_filecoinpay_operator() {
  local deal_id="$1"
  local validator client filecoin_pay usdc pk max already
  validator="$(cli_json_retry client get-deal "$deal_id" | jq -r '.validator_address')"
  [[ -n "$validator" && "$validator" != "null" ]] || return 0
  if [[ "$validator" == "0x0000000000000000000000000000000000000000" ]]; then
    return 0
  fi

  client="$(env_get CLIENT_ADDRESS)"
  filecoin_pay="$(env_get FILECOIN_PAY)"
  usdc="$(env_get USDC_TOKEN)"
  pk="$(env_get CLIENT_PRIVATE_KEY)"
  max="$(python3 -c 'print((1<<256)-1)')"

  already="$(
    cast call "$filecoin_pay" \
      "operatorApprovals(address,address,address)(bool,uint256,uint256,uint256,uint256,uint256)" \
      "$usdc" "$client" "$validator" \
      --rpc-url "$(env_get RPC_URL)" 2>/dev/null | awk 'NR==1{print $1; exit}'
  )"
  if [[ "$already" == "true" ]]; then
    log "FileCoinPay operator already approved for validator ${validator}"
    return 0
  fi

  log "approving FileCoinPay operator ${validator} (Curio USDFC has no permit)"
  cast send "$filecoin_pay" \
    "setOperatorApproval(address,address,bool,uint256,uint256,uint256)" \
    "$usdc" "$validator" true "$max" "$max" "$max" \
    --private-key "$pk" \
    --rpc-url "$(env_get RPC_URL)" >/dev/null
}

init_deal() {
  local deal_id="$1"
  local rail attempts="${INIT_ATTEMPTS:-6}" i

  for i in $(seq 1 "$attempts"); do
    rail="$(cli_json_retry client get-deal "$deal_id" | jq -r '.rail_id')"
    if [[ "$rail" != "0" && -n "$rail" && "$rail" != "null" ]]; then
      log "rail already initialized (rail_id=${rail})"
      return 0
    fi

    log "client init-accepted-deals ${deal_id} (attempt ${i}/${attempts})"
    # First pass may deploy validator then fail on USDFC permit; recover via cast approval.
    # Do not use run_cli_retry here — permit revert is expected and must not abort the script.
    set +e
    run_cli client init-accepted-deals "$deal_id"
    set -e

    rail="$(cli_json_retry client get-deal "$deal_id" | jq -r '.rail_id')"
    if [[ "$rail" != "0" && -n "$rail" && "$rail" != "null" ]]; then
      log "rail initialized (rail_id=${rail})"
      return 0
    fi

    ensure_filecoinpay_operator "$deal_id"
    sleep 2
  done

  rail="$(cli_json_retry client get-deal "$deal_id" | jq -r '.rail_id')"
  [[ "$rail" != "0" && -n "$rail" && "$rail" != "null" ]] \
    || die "init-accepted-deals left rail_id=0 for deal ${deal_id} after ${attempts} attempts"
}

# Total pieces for a deal = still-unclaimed allocations + on-chain claims.
deal_expected_piece_count() {
  local deal_id="$1"
  local unclaimed claimed
  unclaimed="$(deal_allocation_count "$deal_id")"
  claimed="$(deal_claim_count "$deal_id")"
  echo $((unclaimed + claimed))
}

deal_is_fully_claimed() {
  local deal_id="$1"
  local unclaimed claimed
  unclaimed="$(deal_allocation_count "$deal_id")"
  claimed="$(deal_claim_count "$deal_id")"
  [[ "$unclaimed" -eq 0 && "$claimed" -gt 0 ]]
}

# Resume an incomplete deal for this manifest instead of proposing a duplicate.
find_resumable_deal_for_manifest() {
  local manifest="$1"
  local deal_id state
  deal_id="$(
    cli_json_retry client get-deals 2>/dev/null | jq -r --arg m "$manifest" '
      [.[] | select(.manifest_location == $m)]
      | if length == 0 then empty else max_by(.deal_id) | .deal_id end
    ' 2>/dev/null || true
  )"
  [[ -n "$deal_id" ]] || return 1
  state="$(cli_json_retry client get-deal "$deal_id" | jq -r '.state')"
  case "$state" in
    PROPOSED|ACCEPTED)
      printf '%s\n' "$deal_id"
      return 0
      ;;
    COMPLETED)
      if deal_is_fully_claimed "$deal_id"; then
        return 1
      fi
      printf '%s\n' "$deal_id"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

persist_deal_id() {
  local deal_id="$1"
  printf '%s\n' "$deal_id" >"${REPO_ROOT}/.make-deal-last-id"
}

onboard_cars_present() {
  local deal_id="$1"
  local dir="$2"
  local manifest_file n cars
  manifest_file="${dir}/manifest_${deal_id}.json"
  [[ -f "$manifest_file" ]] || return 1
  n="$(jq '[.[].pieces[]?] | length' "$manifest_file")"
  cars="$(find "$dir" -maxdepth 1 -name '*.car' 2>/dev/null | wc -l | tr -d '[:space:]')"
  [[ -n "$n" && "$n" -gt 0 && "$cars" -ge "$n" ]]
}

# Ensure Curio has DDO rows + piece URLs for every still-unclaimed allocation.
ensure_curio_ddos_and_urls() {
  local deal_id="$1"
  local attempts="${2:-8}" i unclaimed

  ensure_curio
  for i in $(seq 1 "$attempts"); do
    unclaimed="$(deal_allocation_count "$deal_id")"
    if [[ "$unclaimed" -eq 0 ]]; then
      log "no unclaimed allocations — Curio DDO/add-url not needed"
      return 0
    fi
    log "sp claim-allocations curio ${deal_id} (${unclaimed} unclaimed, attempt ${i}/${attempts})"
    set +e
    run_cli_retry sp claim-allocations curio "$deal_id"
    set -e
    set +e
    attach_curio_piece_urls "$deal_id"
    local arc=$?
    set -e
    if [[ $arc -eq 0 ]]; then
      return 0
    fi
    log "attach_curio_piece_urls incomplete (rc=${arc}); retrying claim+attach"
    sleep 5
  done
  die "failed to attach Curio piece URLs for all unclaimed allocations of deal ${deal_id}"
}

# Poll until every deal piece has an on-chain claim (Curio seal + claim finished).
wait_until_all_claimed() {
  local deal_id="$1"
  local expected="$2"
  local timeout_s="${3:-${WAIT_CLAIMS_TIMEOUT:-1800}}"
  local poll_s="${WAIT_CLAIMS_POLL:-15}"
  local elapsed=0 claims unclaimed

  [[ "$expected" -gt 0 ]] || die "expected piece count is 0 for deal ${deal_id}"
  log "waiting up to ${timeout_s}s for ${expected} on-chain claim(s) on deal ${deal_id}"

  while [[ "$elapsed" -lt "$timeout_s" ]]; do
    claims="$(deal_claim_count "$deal_id")"
    unclaimed="$(deal_allocation_count "$deal_id")"
    log "deal ${deal_id}: claims=${claims}/${expected} unclaimed=${unclaimed} (${elapsed}s/${timeout_s}s)"

    if [[ "$claims" -ge "$expected" && "$unclaimed" -eq 0 ]]; then
      log "all ${expected} piece(s) claimed on-chain for deal ${deal_id}"
      return 0
    fi

    # Heal stuck offline DDOs while we wait (idempotent).
    if [[ "$unclaimed" -gt 0 ]]; then
      set +e
      ensure_curio_ddos_and_urls "$deal_id" 2
      set -e
    fi

    sleep "$poll_s"
    elapsed=$((elapsed + poll_s))
  done

  claims="$(deal_claim_count "$deal_id")"
  unclaimed="$(deal_allocation_count "$deal_id")"
  die "timed out waiting for claims on deal ${deal_id}: claims=${claims}/${expected} unclaimed=${unclaimed}. Re-run: ./scripts/make-deal.sh --deal-id ${deal_id}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest-url) MANIFEST_URL="$2"; shift 2 ;;
    --price-per-sector-per-month) PRICE_PER_SECTOR_PER_MONTH="$2"; shift 2 ;;
    --duration-months) DURATION_MONTHS="$2"; shift 2 ;;
    --deal-id) DEAL_ID="$2"; shift 2 ;;
    --onboard-dir) ONBOARD_DIR="$2"; shift 2 ;;
    --piece-base-url) PIECE_BASE_URL="$2"; shift 2 ;;
    --skip-onboard) SKIP_ONBOARD=true; shift ;;
    --skip-claim) SKIP_CLAIM=true; shift ;;
    --wait-claims) WAIT_CLAIMS=true; shift ;;
    --no-wait-claims) WAIT_CLAIMS=false; shift ;;
    --wait-claims-timeout) WAIT_CLAIMS_TIMEOUT="$2"; shift 2 ;;
    --interactive) YES=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# Allow WAIT_CLAIMS=true|false from the environment when flags are omitted.
case "${WAIT_CLAIMS}" in
  true|false) ;;
  1|yes|YES) WAIT_CLAIMS=true ;;
  0|no|NO) WAIT_CLAIMS=false ;;
esac

WAIT_CLAIMS_TIMEOUT="${WAIT_CLAIMS_TIMEOUT:-1800}"

require_cmd jq
require_cmd cast
require_cmd curl
require_file() { [[ -f "$1" ]] || die "missing required file: $1"; }
require_file "$ENV_FILE"
[[ -f "${TOOLING_DIR}/porep_tooling_cli.py" ]] || die "porep_tooling_cli.py not found in ${TOOLING_DIR}"

log "checking manifest at ${MANIFEST_URL}"
curl -sf -m 10 -o /dev/null "$MANIFEST_URL" || die "manifest not reachable at ${MANIFEST_URL}"

# Avoid matching lotus-miner (not in Curio MinerAddresses).
ensure_lotus_miner_paused

if [[ -z "$DEAL_ID" ]]; then
  if DEAL_ID="$(find_resumable_deal_for_manifest "$MANIFEST_URL" || true)" && [[ -n "$DEAL_ID" ]]; then
    log "resuming incomplete deal_id=${DEAL_ID} for ${MANIFEST_URL}"
  else
    DEAL_ID=""
  fi
fi

if [[ -z "$DEAL_ID" ]]; then
  log "proposing deal from ${MANIFEST_URL}"
  # IMPORTANT: do not capture CLI stdout via $() while feeding confirms with `yes`.
  # Large prompts (full manifest dump) fill the pipe buffer → classic deadlock
  # (CLI blocked on stdout write, never reads stdin). Tee to a file instead.
  propose_log="$(mktemp)"
  set +e
  set +o pipefail
  run_cli client propose-deal-from-manifest "$MANIFEST_URL" \
    --retrievability-bps "$RETRIEVABILITY_BPS" \
    --bandwidth-mbps "$BANDWIDTH_MBPS" \
    --price-per-sector-per-month "$PRICE_PER_SECTOR_PER_MONTH" \
    --duration-months "$DURATION_MONTHS" \
    --latency-ms "$LATENCY_MS" \
    --indexing-pct "$INDEXING_PCT" 2>&1 | tee "$propose_log"
  propose_rc=${PIPESTATUS[0]:-1}
  set -o pipefail
  set -e

  propose_tx="$(
    grep -Eo '0x[0-9a-fA-F]{64}' "$propose_log" 2>/dev/null | tail -n1 || true
  )"
  rm -f "$propose_log"

  if [[ $propose_rc -ne 0 && -z "$propose_tx" ]]; then
    # Tipset races: retry a few times without capturing output.
    for i in $(seq 1 "${CLI_MUTATE_ATTEMPTS:-5}"); do
      log "propose failed (rc=${propose_rc}); retry ${i}"
      set +e
      run_cli client propose-deal-from-manifest "$MANIFEST_URL" \
        --retrievability-bps "$RETRIEVABILITY_BPS" \
        --bandwidth-mbps "$BANDWIDTH_MBPS" \
        --price-per-sector-per-month "$PRICE_PER_SECTOR_PER_MONTH" \
        --duration-months "$DURATION_MONTHS" \
        --latency-ms "$LATENCY_MS" \
        --indexing-pct "$INDEXING_PCT"
      propose_rc=$?
      set -e
      if [[ $propose_rc -eq 0 ]]; then
        break
      fi
      sleep 5
    done
  fi

  if [[ -n "$propose_tx" ]]; then
    log "propose tx ${propose_tx}; resolving deal id (retries tipset/fork races)"
    for _ in $(seq 1 40); do
      if cast receipt "$propose_tx" --rpc-url "$(env_get RPC_URL)" >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
    DEAL_ID="$(deal_id_from_propose_tx "$propose_tx" || true)"
  fi

  if [[ -z "$DEAL_ID" ]]; then
    DEAL_ID="$(wait_deal_id_for_manifest "$MANIFEST_URL" || true)"
  fi
  [[ -n "$DEAL_ID" ]] || die "could not find proposed deal for manifest ${MANIFEST_URL} (chain stuck? height may not be advancing)"
  log "proposed deal_id=${DEAL_ID}"
else
  log "resuming with deal_id=${DEAL_ID}"
fi

persist_deal_id "$DEAL_ID"
assert_deal_provider_is_curio "$DEAL_ID"

state="$(cli_json_retry client get-deal "$DEAL_ID" | jq -r '.state')"
log "deal ${DEAL_ID} current state=${state}"

if [[ "$state" == "PROPOSED" ]]; then
  log "sp accept-deal ${DEAL_ID}"
  run_cli_retry sp accept-deal "$DEAL_ID"
  wait_deal_state "$DEAL_ID" ACCEPTED
  state=ACCEPTED
fi

if [[ "$state" == "ACCEPTED" ]]; then
  rail="$(cli_json_retry client get-deal "$DEAL_ID" | jq -r '.rail_id')"
  if [[ "$rail" == "0" || -z "$rail" || "$rail" == "null" ]]; then
    init_deal "$DEAL_ID"
  else
    log "skipping init (rail_id=${rail})"
  fi

  # make-allocations may need a few passes across tipset races.
  for _ in $(seq 1 6); do
    state="$(cli_json_retry client get-deal "$DEAL_ID" | jq -r '.state')"
    [[ "$state" == "COMPLETED" ]] && break
    log "client make-allocations ${DEAL_ID} (state=${state})"
    set +e
    run_cli_retry client make-allocations "$DEAL_ID"
    set -e
    state="$(cli_json_retry client get-deal "$DEAL_ID" | jq -r '.state')"
    [[ "$state" == "COMPLETED" ]] && break
    sleep 3
  done
  wait_deal_state "$DEAL_ID" COMPLETED 90
  state=COMPLETED
fi

if [[ "$state" != "COMPLETED" ]]; then
  die "deal ${DEAL_ID} is ${state}; expected COMPLETED to continue onboarding"
fi

EXPECTED_PIECES="$(deal_expected_piece_count "$DEAL_ID")"
ALLOC_COUNT="$(deal_allocation_count "$DEAL_ID")"
CLAIM_COUNT="$(deal_claim_count "$DEAL_ID")"
log "deal ${DEAL_ID} COMPLETED: ${ALLOC_COUNT} unclaimed allocation(s), ${CLAIM_COUNT} claim(s), expected pieces=${EXPECTED_PIECES}"

if [[ "$SKIP_ONBOARD" == true ]]; then
  log "skipping onboard/claim (--skip-onboard)"
  log "done. deal_id=${DEAL_ID} state=COMPLETED"
  exit 0
fi

if [[ -z "$ONBOARD_DIR" ]]; then
  ONBOARD_DIR="${REPO_ROOT}/deal-${DEAL_ID}"
fi
mkdir -p "$ONBOARD_DIR"

# --- SP onboard-data: download piece CARs (aria2c) ---
ensure_aria2c
if onboard_cars_present "$DEAL_ID" "$ONBOARD_DIR"; then
  log "piece CARs already present in ${ONBOARD_DIR} — skipping onboard-data"
else
  log "sp onboard-data ${DEAL_ID} --output-dir ${ONBOARD_DIR}"
  run_cli_retry sp onboard-data "$DEAL_ID" --output-dir "$ONBOARD_DIR"
fi

if [[ "$SKIP_CLAIM" == true ]]; then
  log "skipping claim-allocations (--skip-claim)"
  log "done. deal_id=${DEAL_ID} cars in ${ONBOARD_DIR}"
  exit 0
fi

# --- SP claim-allocations curio + add-url (retried until all unclaimed have URLs) ---
ensure_curio_ddos_and_urls "$DEAL_ID"

EXPECTED_PIECES="$(deal_expected_piece_count "$DEAL_ID")"
CLAIM_COUNT="$(deal_claim_count "$DEAL_ID")"
ALLOC_COUNT="$(deal_allocation_count "$DEAL_ID")"

if [[ "$WAIT_CLAIMS" == true ]]; then
  if [[ "$EXPECTED_PIECES" -eq 0 ]]; then
    # Fully claimed already (unclaimed=0 and we had claims), or empty deal.
    [[ "$CLAIM_COUNT" -gt 0 ]] || die "deal ${DEAL_ID} has no allocations or claims"
    EXPECTED_PIECES="$CLAIM_COUNT"
  fi
  wait_until_all_claimed "$DEAL_ID" "$EXPECTED_PIECES" "$WAIT_CLAIMS_TIMEOUT"
  CLAIM_COUNT="$(deal_claim_count "$DEAL_ID")"
  log "on-chain claims:"
  cli_json_retry sp get-claims "$DEAL_ID" | jq .
  log "done. deal_id=${DEAL_ID} state=COMPLETED claims=${CLAIM_COUNT}/${EXPECTED_PIECES} onboard_dir=${ONBOARD_DIR}"
else
  log "all unclaimed allocations have Curio piece URLs — not waiting for on-chain claims"
  log "poll later: ${CLI[*]} sp get-claims ${DEAL_ID}"
  log "or re-run: ./scripts/make-deal.sh --deal-id ${DEAL_ID} --wait-claims"
  log "done. deal_id=${DEAL_ID} state=COMPLETED unclaimed=${ALLOC_COUNT} claims=${CLAIM_COUNT} onboard_dir=${ONBOARD_DIR}"
fi
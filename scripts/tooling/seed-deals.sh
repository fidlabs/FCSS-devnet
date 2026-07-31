#!/usr/bin/env bash
# Seed 3 clients × private/public (6 deals), each with unique Singularity piece CIDs.
#
# Default path:
#   1. Ensure C1=USER_1 + C2/C3 cast wallets; fund FIL + USDFC
#   2. Prep 6 unique tiny datasets via Singularity → manifests under .runtime/seed-deals/
#   3. Serve manifests (:18080) + CARs (:17777)
#   4. Full make-deal pipeline per (client, dealType) with unique --manifest-url
#   5. Restore tooling .env CLIENT_* to USER_1
#
# Prerequisites: just porep-market up, docker, cast, jq, lotus (docker), tooling venv.
# Singularity runs via Docker image (default:
#   ghcr.io/data-preservation-programs/singularity:main).
#
# Compatible with macOS /bin/bash 3.2.
#
# Usage:
#   ./scripts/tooling/seed-deals.sh
#   just seed-deals
#   ./scripts/tooling/seed-deals.sh --prep-only
#   ./scripts/tooling/seed-deals.sh --deals-only
#   ./scripts/tooling/seed-deals.sh --manifests-file path.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/envfile.sh
source "${SCRIPT_DIR}/../lib/envfile.sh"
# shellcheck source=../lib/lotus.sh
source "${SCRIPT_DIR}/../lib/lotus.sh"

ENV_FILE="${ENV_FILE:-${TOOLING_DIR}/.env}"
SEED_ROOT="${SEED_ROOT:-${RUNTIME_ROOT}/seed-deals}"
CLIENTS_JSON="${CLIENTS_JSON:-${SEED_ROOT}/clients.json}"
SING_ROOT="${SEED_ROOT}/singularity"
CARS_DIR="${SING_ROOT}/cars"
HTTP_ROOT="${SEED_ROOT}/http"
# Host paths under SEED_ROOT are mounted at /work inside the Singularity container.
SING_WORK="/work"
SING_CARS_CTR="${SING_WORK}/singularity/cars"
SINGULARITY_IMAGE="${SINGULARITY_IMAGE:-ghcr.io/data-preservation-programs/singularity:main}"
SINGULARITY_CP_NAME="${SINGULARITY_CP_NAME:-fcss-seed-singularity-cp}"
MANIFESTS_FILE=""
PREP_ONLY=false
DEALS_ONLY=false
SKIP_FUND=false
ORG_FUND_AMOUNT="${ORG_FUND_AMOUNT:-1000}"
# 1000 USDFC (18 decimals) — enough for two small deals per client.
USDFC_FUND_WEI="${USDFC_FUND_WEI:-1000000000000000000000}"
DEPLOYER_KEY_FILE="${CONTRACTS_DIR}/deployer.private-key"
CONTRACT_ADDRESSES_JSON="${CONTRACTS_DIR}/contract_addresses.json"
MAKE_DEAL_EXTRA=()

SLOTS=(
  "c1:private"
  "c1:public"
  "c2:private"
  "c2:public"
  "c3:private"
  "c3:public"
)

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [-- make-deal flags…]

Seed 3 clients × private/public with unique piece CIDs (full make-deal pipeline).

Options:
  --prep-only           Only prepare Singularity manifests/CARs + start HTTP servers
  --deals-only          Skip Singularity prep; use existing manifests (or --manifests-file)
  --manifests-file F    JSON array of {client,dealType,manifestUrl} (skips Singularity)
  --skip-fund           Do not fund FIL/USDFC (wallets must already be ready)
  -h, --help            Show this help

Env:
  SEED_ROOT, SINGULARITY_IMAGE (default ${SINGULARITY_IMAGE}),
  FCSS_SEED_MANIFEST_HOST_PORT (default ${FCSS_SEED_MANIFEST_HOST_PORT}),
  FCSS_SEED_PIECE_HOST_PORT (default ${FCSS_SEED_PIECE_HOST_PORT}),
  USDFC_FUND_WEI, ORG_FUND_AMOUNT
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prep-only) PREP_ONLY=true; shift ;;
    --deals-only) DEALS_ONLY=true; shift ;;
    --manifests-file) MANIFESTS_FILE="$2"; shift 2 ;;
    --skip-fund) SKIP_FUND=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; MAKE_DEAL_EXTRA=("$@"); break ;;
    *)
      # Pass unknown flags through to make-deal
      MAKE_DEAL_EXTRA+=("$1")
      shift
      ;;
  esac
done

[[ "$PREP_ONLY" == true && "$DEALS_ONLY" == true ]] && die "use only one of --prep-only / --deals-only"

require_cmd jq
require_cmd cast
require_cmd curl
require_cmd python3
require_cmd docker
require_file "$ENV_FILE"

runtime_ensure_dirs
mkdir -p "$SEED_ROOT" "$SING_ROOT" "$CARS_DIR" "$HTTP_ROOT/seed" \
  "${SEED_ROOT}/data" "${SEED_ROOT}/logs"

ORIGINAL_CLIENT_KEY="$(env_get CLIENT_PRIVATE_KEY "$ENV_FILE")"
ORIGINAL_CLIENT_ADDR="$(env_get CLIENT_ADDRESS "$ENV_FILE")"
[[ -n "$ORIGINAL_CLIENT_KEY" && -n "$ORIGINAL_CLIENT_ADDR" ]] || \
  die "CLIENT_* missing in ${ENV_FILE} — run: just porep-market up"

ADMIN_PRIVATE_KEY="$(env_get ADMIN_PRIVATE_KEY "$ENV_FILE" 2>/dev/null || true)"
if [[ -z "$ADMIN_PRIVATE_KEY" && -f "$DEPLOYER_KEY_FILE" ]]; then
  ADMIN_PRIVATE_KEY="$(tr -d '[:space:]' < "$DEPLOYER_KEY_FILE")"
fi
[[ "$ADMIN_PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "ADMIN/deployer private key missing"

USDC_TOKEN="$(env_get USDC_TOKEN "$ENV_FILE" 2>/dev/null || true)"
if [[ -z "$USDC_TOKEN" && -f "$CONTRACT_ADDRESSES_JSON" ]]; then
  USDC_TOKEN="$(jq -r '.contracts.usdfc // empty' "$CONTRACT_ADDRESSES_JSON")"
fi
[[ -n "$USDC_TOKEN" && "$USDC_TOKEN" != null ]] || die "USDC_TOKEN / contracts.usdfc missing"

eth_to_filecoin() {
  local eth="$1"
  curl -sf -m 10 -X POST "$RPC_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"Filecoin.EthAddressToFilecoinAddress\",\"params\":[\"${eth}\"],\"id\":1}" \
    | jq -r '.result // empty'
}

fil_actor_exists() {
  local addr="$1"
  lotus state get-actor "$addr" >/dev/null 2>&1
}

ensure_fil_actor_funded() {
  local addr="$1"
  local amount="${2:-$ORG_FUND_AMOUNT}"
  local default_wallet fund_out fund_cid
  if fil_actor_exists "$addr"; then
    log "Filecoin actor ${addr} already exists"
    return 0
  fi
  default_wallet="$(lotus wallet default | tr -d '[:space:]')"
  log "funding ${addr} with ${amount} FIL from ${default_wallet}"
  fund_out="$(lotus send --from "$default_wallet" "$addr" "$amount")"
  fund_cid="$(printf '%s\n' "$fund_out" | awk '/^bafy/{print $1}' | tail -n1 | tr -d '[:space:]')"
  [[ -n "$fund_cid" ]] || fund_cid="$(printf '%s\n' "$fund_out" | tail -n1 | tr -d '[:space:]')"
  wait_msg_required "$fund_cid"
  fil_actor_exists "$addr" || die "actor ${addr} still missing after funding"
}

ensure_usdfc() {
  local addr="$1"
  local bal
  # cast may print "0 [0]" or "1e21" suffixes — keep the leading integer token.
  bal="$(cast call "$USDC_TOKEN" "balanceOf(address)(uint256)" "$addr" --rpc-url "$RPC_URL" \
    | tr -d '\r\n' | awk '{print $1; exit}')"
  if [[ -z "$bal" || "$bal" == "0" || "$bal" =~ ^0+$ ]]; then
    log "funding ${addr} with USDFC ${USDFC_FUND_WEI}"
    cast send "$USDC_TOKEN" "transfer(address,uint256)" "$addr" "$USDFC_FUND_WEI" \
      --private-key "$ADMIN_PRIVATE_KEY" --rpc-url "$RPC_URL" >/dev/null
  else
    log "USDFC balance ok for ${addr}"
  fi
}

port_listening() {
  local port="$1"
  curl -sf -m 1 "http://127.0.0.1:${port}/" >/dev/null 2>&1 && return 0
  # content-provider may 404 on / but still bind
  python3 - "$port" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket()
s.settimeout(0.5)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
    sys.exit(0)
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

require_singularity() {
  ensure_singularity_image
}

ensure_singularity_image() {
  if docker image inspect "$SINGULARITY_IMAGE" >/dev/null 2>&1; then
    return 0
  fi
  log "pulling Singularity image ${SINGULARITY_IMAGE}"
  docker pull "$SINGULARITY_IMAGE" || die "failed to pull ${SINGULARITY_IMAGE}"
}

# Run singularity CLI in Docker with SEED_ROOT mounted at /work (cwd=/work/singularity).
run_singularity() {
  ensure_singularity_image
  docker run --rm \
    -v "${SEED_ROOT}:/work" \
    -w /work/singularity \
    "$SINGULARITY_IMAGE" \
    "$@"
}

storage_exists() {
  local name="$1"
  run_singularity storage list 2>/dev/null | awk -v n="$name" '$2==n || $1==n {found=1} END{exit !found}'
}

prep_exists() {
  local name="$1"
  [[ -f "${SING_ROOT}/singularity.db" ]] || return 1
  run_singularity prep list 2>/dev/null | awk -v n="$name" '$2==n || $1==n {found=1} END{exit !found}'
}

init_clients_json() {
  if [[ -f "$CLIENTS_JSON" ]]; then
    log "reusing clients at ${CLIENTS_JSON#"$REPO_ROOT"/}"
    return 0
  fi
  log "creating C2/C3 wallets → ${CLIENTS_JSON#"$REPO_ROOT"/}"
  local c2_json="" c3_json="" c2_key="" c2_addr="" c3_key="" c3_addr="" c2_txt="" c3_txt=""

  # cast wallet new --json returns [{address, private_key}, ...]
  parse_cast_wallet_json() {
    printf '%s' "$1" | jq -r '
      (if type == "array" then .[0] else . end)
      | (.private_key // .PrivateKey // empty),
        (.address // .Address // empty)
    '
  }

  c2_json="$(cast wallet new --json 2>/dev/null || true)"
  c3_json="$(cast wallet new --json 2>/dev/null || true)"
  if [[ -n "$c2_json" && "$c2_json" != *"error"* ]]; then
    c2_key="$(parse_cast_wallet_json "$c2_json" | sed -n '1p')"
    c2_addr="$(parse_cast_wallet_json "$c2_json" | sed -n '2p')"
    c3_key="$(parse_cast_wallet_json "$c3_json" | sed -n '1p')"
    c3_addr="$(parse_cast_wallet_json "$c3_json" | sed -n '2p')"
  fi
  if [[ ! "$c2_key" =~ ^0x || ! "$c2_addr" =~ ^0x ]]; then
    c2_txt="$(cast wallet new)"
    c2_addr="$(printf '%s\n' "$c2_txt" | awk '/Address/{print $NF}' | tr -d '[:space:]')"
    c2_key="$(printf '%s\n' "$c2_txt" | awk '/Private key/{print $NF}' | tr -d '[:space:]')"
  fi
  if [[ ! "$c3_key" =~ ^0x || ! "$c3_addr" =~ ^0x ]]; then
    c3_txt="$(cast wallet new)"
    c3_addr="$(printf '%s\n' "$c3_txt" | awk '/Address/{print $NF}' | tr -d '[:space:]')"
    c3_key="$(printf '%s\n' "$c3_txt" | awk '/Private key/{print $NF}' | tr -d '[:space:]')"
  fi
  [[ "$c2_key" =~ ^0x && "$c2_addr" =~ ^0x ]] || die "cast wallet new failed for C2"
  [[ "$c3_key" =~ ^0x && "$c3_addr" =~ ^0x ]] || die "cast wallet new failed for C3"
  jq -n \
    --arg c1k "$ORIGINAL_CLIENT_KEY" --arg c1a "$ORIGINAL_CLIENT_ADDR" \
    --arg c2k "$c2_key" --arg c2a "$c2_addr" \
    --arg c3k "$c3_key" --arg c3a "$c3_addr" \
    '{
      c1: {private_key: $c1k, address: $c1a, source: "tooling.env.USER_1"},
      c2: {private_key: $c2k, address: $c2a, source: "cast.wallet.new"},
      c3: {private_key: $c3k, address: $c3a, source: "cast.wallet.new"}
    }' >"$CLIENTS_JSON"
}

client_field() {
  local client_id="$1" field="$2"
  jq -r --arg id "$client_id" --arg f "$field" '.[$id][$f] // empty' "$CLIENTS_JSON"
}

fund_clients() {
  local client_id addr t410
  for client_id in c1 c2 c3; do
    addr="$(client_field "$client_id" address)"
    [[ -n "$addr" ]] || die "missing address for ${client_id}"
    t410="$(eth_to_filecoin "$addr")"
    [[ -n "$t410" ]] || die "EthAddressToFilecoinAddress failed for ${addr}"
    ensure_fil_actor_funded "$t410"
    ensure_usdfc "$addr"
  done
}

slot_id() {
  # c1:private → c1-private
  printf '%s\n' "$1" | tr ':' '-'
}

slot_client() {
  printf '%s\n' "${1%%:*}"
}

slot_type() {
  printf '%s\n' "${1#*:}"
}

export_manifest_for_prep() {
  local prep_name="$1" out_file="$2"
  (
    cd "$SING_ROOT"
    PREP_NAME="$prep_name" OUT_FILE="$out_file" python3 <<'PY'
import json, os, sqlite3, sys
prep = os.environ["PREP_NAME"]
out = os.environ["OUT_FILE"]
conn = sqlite3.connect("singularity.db")
conn.row_factory = sqlite3.Row
rows = conn.execute(
    """
    SELECT c.piece_type, c.piece_size, c.file_size,
           c.preparation_id, c.attachment_id, c.storage_path
    FROM cars c
    JOIN preparations p ON p.id = c.preparation_id
    WHERE p.name = ?
    ORDER BY c.id
    """,
    (prep,),
).fetchall()
if not rows:
    sys.exit(f"no cars for preparation {prep!r}")
pieces = []
for r in rows:
    path = r["storage_path"]
    if not path.endswith(".car"):
        sys.exit(f"unexpected storage_path: {path}")
    pieces.append({
        "pieceCid": path[: -len(".car")],
        "pieceType": r["piece_type"],
        "pieceSize": int(r["piece_size"]),
        "fileSize": int(r["file_size"]),
        "preparationId": str(r["preparation_id"]),
        "attachmentId": str(r["attachment_id"]),
        "storagePath": path,
    })
types = [p["pieceType"] for p in pieces]
if types.count("dag") != 1 or "data" not in types:
    sys.exit(f"expected ≥1 data + exactly 1 dag for {prep}, got {types}")
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w", encoding="utf-8") as f:
    json.dump([{"pieces": pieces}], f, indent=2)
    f.write("\n")
print(f"wrote {len(pieces)} pieces → {out}", file=sys.stderr)
PY
  )
}

prepare_slot() {
  local slot="$1"
  local sid client dtype data_dir data_ctr prep_name src_name out_name manifest_http
  sid="$(slot_id "$slot")"
  client="$(slot_client "$slot")"
  dtype="$(slot_type "$slot")"
  data_dir="${SEED_ROOT}/data/${sid}"
  data_ctr="${SING_WORK}/data/${sid}"
  prep_name="seed-${sid}"
  src_name="seed-${sid}-src"
  out_name="seed-cars"
  manifest_http="${HTTP_ROOT}/seed/${sid}/manifest.json"

  if [[ -f "$manifest_http" ]]; then
    log "slot ${sid}: manifest exists — skip Singularity prep"
    return 0
  fi

  require_singularity
  mkdir -p "$data_dir"
  # ~3 MiB unique payload → distinct CommP per slot
  python3 - "$data_dir/payload.bin" "$sid" <<'PY'
import os, sys
path, sid = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(path), exist_ok=True)
data = (sid.encode() + b"\0" + os.urandom(64)) * ((2500 * 1024) // 80 + 1)
open(path, "wb").write(data[: 2500 * 1024])
PY

  if [[ ! -f "${SING_ROOT}/singularity.db" ]]; then
    log "singularity admin init (docker) in ${SING_ROOT#"$REPO_ROOT"/}"
    run_singularity admin init
  fi

  if ! storage_exists "$out_name"; then
    run_singularity storage create local --name "$out_name" --path "$SING_CARS_CTR"
  fi
  if ! storage_exists "$src_name"; then
    run_singularity storage create local --name "$src_name" --path "$data_ctr"
  fi
  if ! prep_exists "$prep_name"; then
    log "creating prep ${prep_name}"
    run_singularity prep create \
      --name "$prep_name" \
      --source "$src_name" \
      --output "$out_name" \
      --max-size 3MiB \
      --piece-size 4MiB \
      --min-piece-size 1MiB
  fi

  log "scanning + packing ${prep_name}"
  run_singularity prep start-scan "$prep_name" "$src_name" || true
  run_singularity run dataset-worker --exit-on-error --exit-on-complete

  if ! run_singularity prep list-pieces "$prep_name" 2>/dev/null | grep -qi dag; then
    log "daggen ${prep_name} (source ${src_name})"
    run_singularity prep start-daggen "$prep_name" "$src_name"
    run_singularity run dataset-worker --exit-on-error --exit-on-complete
  fi

  export_manifest_for_prep "$prep_name" "$manifest_http"
  log "slot ${sid} (${client}/${dtype}): $(jq -r '.[0].pieces | map(.pieceCid) | join(", ")' "$manifest_http")"
}

prepare_all_slots() {
  local slot
  for slot in "${SLOTS[@]}"; do
    prepare_slot "$slot"
  done
}

start_http_servers() {
  local manifest_pid_file
  manifest_pid_file="${SEED_ROOT}/manifest-http.pid"

  if ! port_listening "$FCSS_SEED_MANIFEST_HOST_PORT"; then
    log "serving manifests on :${FCSS_SEED_MANIFEST_HOST_PORT} from ${HTTP_ROOT#"$REPO_ROOT"/}"
    (
      cd "$HTTP_ROOT"
      nohup python3 -m http.server "$FCSS_SEED_MANIFEST_HOST_PORT" --bind 127.0.0.1 \
        >"${SEED_ROOT}/logs/manifest-http.log" 2>&1 &
      echo $! >"$manifest_pid_file"
    )
    sleep 1
    port_listening "$FCSS_SEED_MANIFEST_HOST_PORT" || die "manifest HTTP server failed to bind :${FCSS_SEED_MANIFEST_HOST_PORT}"
  else
    log "manifest port ${FCSS_SEED_MANIFEST_HOST_PORT} already listening"
  fi

  if ! port_listening "$FCSS_SEED_PIECE_HOST_PORT"; then
    require_singularity
    log "serving CARs on :${FCSS_SEED_PIECE_HOST_PORT} (docker ${SINGULARITY_CP_NAME})"
    docker rm -f "$SINGULARITY_CP_NAME" >/dev/null 2>&1 || true
    docker run -d --name "$SINGULARITY_CP_NAME" \
      -v "${SEED_ROOT}:/work" \
      -w /work/singularity \
      -p "${FCSS_SEED_PIECE_HOST_PORT}:7777" \
      "$SINGULARITY_IMAGE" \
      run content-provider --http-bind 0.0.0.0:7777 \
      >"${SEED_ROOT}/logs/piece-http.log" 2>&1 \
      || die "failed to start ${SINGULARITY_CP_NAME} — see ${SEED_ROOT}/logs/piece-http.log"
    sleep 2
    port_listening "$FCSS_SEED_PIECE_HOST_PORT" || {
      docker logs "$SINGULARITY_CP_NAME" >>"${SEED_ROOT}/logs/piece-http.log" 2>&1 || true
      die "content-provider failed — see ${SEED_ROOT}/logs/piece-http.log"
    }
  else
    log "piece port ${FCSS_SEED_PIECE_HOST_PORT} already listening"
  fi
}

manifest_url_for_slot() {
  local sid="$1"
  printf 'http://%s:%s/seed/%s/manifest.json\n' \
    "$FCSS_HOST" "$FCSS_SEED_MANIFEST_HOST_PORT" "$sid"
}

piece_base_url() {
  printf 'http://host.docker.internal:%s/piece\n' "$FCSS_SEED_PIECE_HOST_PORT"
}

load_plan_from_manifests_file() {
  # Writes ${SEED_ROOT}/plan.json as [{client,dealType,manifestUrl,slot}]
  local f="$1"
  require_file "$f"
  jq -e 'type=="array" and length==6' "$f" >/dev/null || \
    die "--manifests-file must be a JSON array of 6 {client,dealType,manifestUrl} objects"
  cp "$f" "${SEED_ROOT}/plan.json"
}

build_default_plan() {
  local slot sid client dtype url
  local tmp="${SEED_ROOT}/plan.json.tmp"
  : >"$tmp"
  for slot in "${SLOTS[@]}"; do
    sid="$(slot_id "$slot")"
    client="$(slot_client "$slot")"
    dtype="$(slot_type "$slot")"
    url="$(manifest_url_for_slot "$sid")"
    [[ -f "${HTTP_ROOT}/seed/${sid}/manifest.json" ]] || \
      die "missing manifest for ${sid} — run without --deals-only first"
    jq -n --arg c "$client" --arg t "$dtype" --arg u "$url" --arg s "$sid" \
      '{client:$c, dealType:$t, manifestUrl:$u, slot:$s}' >>"$tmp"
  done
  jq -s '.' "$tmp" >"${SEED_ROOT}/plan.json"
  rm -f "$tmp"
}

set_client_env() {
  local client_id="$1"
  local key addr
  key="$(client_field "$client_id" private_key)"
  addr="$(client_field "$client_id" address)"
  [[ -n "$key" && -n "$addr" ]] || die "client ${client_id} incomplete in ${CLIENTS_JSON}"
  set_env_key "$ENV_FILE" CLIENT_PRIVATE_KEY "$key"
  set_env_key "$ENV_FILE" CLIENT_ADDRESS "$addr"
  export CLIENT_PRIVATE_KEY="$key"
  export CLIENT_ADDRESS="$addr"
  log "CLIENT_ADDRESS=${addr} (${client_id})"
}

restore_client_env() {
  set_env_key "$ENV_FILE" CLIENT_PRIVATE_KEY "$ORIGINAL_CLIENT_KEY"
  set_env_key "$ENV_FILE" CLIENT_ADDRESS "$ORIGINAL_CLIENT_ADDR"
  export CLIENT_PRIVATE_KEY="$ORIGINAL_CLIENT_KEY"
  export CLIENT_ADDRESS="$ORIGINAL_CLIENT_ADDR"
  log "restored CLIENT_* to USER_1 ${ORIGINAL_CLIENT_ADDR}"
}

run_deals() {
  local n i client dtype url make_args
  n="$(jq 'length' "${SEED_ROOT}/plan.json")"
  for i in $(seq 0 $((n - 1))); do
    client="$(jq -r --argjson i "$i" '.[$i].client' "${SEED_ROOT}/plan.json")"
    dtype="$(jq -r --argjson i "$i" '.[$i].dealType' "${SEED_ROOT}/plan.json")"
    url="$(jq -r --argjson i "$i" '.[$i].manifestUrl' "${SEED_ROOT}/plan.json")"
    log "======== deal $((i + 1))/${n}: ${client} / ${dtype} ========"
    set_client_env "$client"
    curl -sf -m 10 -o /dev/null "$url" || die "manifest not reachable: ${url}"
    make_args=(
      --manifest-url "$url"
      --deal-type "$dtype"
      --piece-base-url "$(piece_base_url)"
    )
    if [[ ${#MAKE_DEAL_EXTRA[@]} -gt 0 ]]; then
      make_args+=("${MAKE_DEAL_EXTRA[@]}")
    fi
    "${SCRIPT_DIR}/make-deal.sh" "${make_args[@]}"
  done
}

# Resolve deal id whose onboarded manifest contains this piece CID
# (.runtime/tooling/deal-N/manifest_N.json).
deal_id_for_piece_cid() {
  local cid="$1"
  local f base
  shopt -s nullglob 2>/dev/null || true
  for f in "${RUNTIME_TOOLING}"/deal-*/manifest_*.json; do
    [[ -f "$f" ]] || continue
    if jq -e --arg cid "$cid" '[.[].pieces[]? | select(.pieceCid == $cid)] | length > 0' "$f" >/dev/null 2>&1; then
      base="$(basename "$f")"
      # manifest_12.json → 12
      printf '%s\n' "${base#manifest_}" | sed 's/\.json$//'
      shopt -u nullglob 2>/dev/null || true
      return 0
    fi
  done
  shopt -u nullglob 2>/dev/null || true
  return 1
}

print_summary() {
  local client_id addr key plan slot dtype url manifest_path deal_id first_cid
  local summary_json="${SEED_ROOT}/summary.json"
  local tmp="${SEED_ROOT}/summary.json.tmp"

  [[ -f "${SEED_ROOT}/plan.json" ]] || {
    log "no plan.json — skipping summary"
    return 0
  }

  log "seed-deals summary (deals + piece CIDs per wallet)"
  : >"$tmp"

  for client_id in c1 c2 c3; do
    addr="$(client_field "$client_id" address)"
    key="$(client_field "$client_id" private_key)"
    printf '\n%s\n' "${client_id}"
    printf '  address:     %s\n' "$addr"
    printf '  private_key: %s\n' "$key"

    jq -c --arg c "$client_id" '.[] | select(.client == $c)' "${SEED_ROOT}/plan.json" | while IFS= read -r plan || [[ -n "$plan" ]]; do
      slot="$(printf '%s' "$plan" | jq -r '.slot // empty')"
      dtype="$(printf '%s' "$plan" | jq -r '.dealType')"
      url="$(printf '%s' "$plan" | jq -r '.manifestUrl')"
      if [[ -n "$slot" && -f "${HTTP_ROOT}/seed/${slot}/manifest.json" ]]; then
        manifest_path="${HTTP_ROOT}/seed/${slot}/manifest.json"
      else
        manifest_path="$(mktemp)"
        curl -sf -m 15 -o "$manifest_path" "$url" || {
          printf '  deal: %s (%s) — manifest unreachable: %s\n' "${slot:-?}" "$dtype" "$url"
          rm -f "$manifest_path"
          continue
        }
      fi

      first_cid="$(jq -r '.[0].pieces[0].pieceCid // empty' "$manifest_path")"
      deal_id=""
      if [[ -n "$first_cid" ]]; then
        deal_id="$(deal_id_for_piece_cid "$first_cid" || true)"
      fi

      printf '  deal_id=%s  type=%s  slot=%s\n' "${deal_id:-?}" "$dtype" "${slot:-}"
      printf '  manifest: %s\n' "$url"
      jq -r '.[0].pieces[]? | "    \(.pieceCid)  (\(.pieceType))"' "$manifest_path"

      jq -n \
        --arg client "$client_id" \
        --arg address "$addr" \
        --arg private_key "$key" \
        --argjson deal_id "${deal_id:-null}" \
        --arg deal_type "$dtype" \
        --arg slot "${slot:-}" \
        --arg manifest_url "$url" \
        --argjson pieces "$(jq '.[0].pieces | map({pieceCid, pieceType, pieceSize, fileSize})' "$manifest_path")" \
        '{client:$client, address:$address, private_key:$private_key, deal_id:$deal_id, deal_type:$deal_type, slot:$slot, manifest_url:$manifest_url, pieces:$pieces}' \
        >>"$tmp"

      [[ "$manifest_path" == "${HTTP_ROOT}/seed/"* ]] || rm -f "$manifest_path"
    done
  done

  jq -s '.' "$tmp" >"$summary_json"
  rm -f "$tmp"
  printf '\n'
  log "wrote ${summary_json#"$REPO_ROOT"/}"
}

# --- main ---

init_clients_json

if [[ "$SKIP_FUND" != true ]]; then
  fund_clients
else
  log "SKIP_FUND=1 — not funding clients"
fi

if [[ -n "$MANIFESTS_FILE" ]]; then
  load_plan_from_manifests_file "$MANIFESTS_FILE"
elif [[ "$DEALS_ONLY" != true ]]; then
  prepare_all_slots
  start_http_servers
  build_default_plan
else
  start_http_servers
  build_default_plan
fi

if [[ "$PREP_ONLY" == true ]]; then
  log "prep-only done. Manifests: http://${FCSS_HOST}:${FCSS_SEED_MANIFEST_HOST_PORT}/seed/<slot>/manifest.json"
  log "Pieces: $(piece_base_url)/<pieceCid>"
  exit 0
fi

trap restore_client_env EXIT
run_deals
restore_client_env
trap - EXIT
print_summary
log "done — 6 deals seeded (3 clients × private/public, unique piece CIDs)"

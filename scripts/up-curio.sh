#!/usr/bin/env bash
# Post-bootstrap Curio config for local PoRep deals: SSRF off, IPNI announce,
# disable WinningPoSt, miner control, escrow funding.
#
# Usage (from repo root):
#   ./scripts/up-curio.sh
#   just up   # runs this after compose up
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Set or add a key in a TOML section.
# Updates within the target section only; removes stale copies elsewhere.
set_toml_value() {
  local file="$1" section="$2" key="$3" value="$4"
  awk -v section="$section" -v key="$key" -v value="$value" '
    function trim_section(line,    s) {
      s = line
      sub(/^[[:space:]]*/, "", s)
      sub(/[[:space:]]*$/, "", s)
      return s
    }
    function is_section_header(line) {
      return line ~ /^[[:space:]]*\[/
    }
    function section_name(line) {
      return trim_section(line)
    }
    function key_pattern() {
      return "^[[:space:]]*" key "[[:space:]]*="
    }
    BEGIN {
      target = "[" section "]"
      in_target = 0
      inserted = 0
      found_target = 0
      section_indent = ""
    }
    {
      line = $0
      if (is_section_header(line)) {
        if (in_target && !inserted) {
          print section_indent "  " key " = " value
          inserted = 1
        }
        current = section_name(line)
        in_target = (current == target)
        if (in_target) {
          found_target = 1
          match(line, /^[[:space:]]*/)
          section_indent = substr(line, 1, RLENGTH)
        }
        print
        next
      }
      if (line ~ key_pattern()) {
        if (in_target) {
          print section_indent "  " key " = " value
          inserted = 1
        }
        next
      }
      print
    }
    END {
      if (!inserted) {
        if (found_target) {
          print section_indent "  " key " = " value
        } else {
          print ""
          print target
          print "  " key " = " value
        }
      }
    }
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

ysql() {
  # yugabyted binds YSQL to the container advertise address, not 127.0.0.1.
  docker compose exec -T yugabyte env PGPASSWORD=yugabyte \
    ysqlsh -h yugabyte -p 5433 -U yugabyte -d yugabyte -Atc "$1" | tr -d '\r\n'
}

curio_machine() {
  local ip
  ip="$(docker compose exec -T curio sh -c 'getent hosts curio | awk "{print \$1; exit}"' | tr -d '\r\n')"
  if [[ -z "$ip" ]]; then
    ip="$(ysql "SELECT split_part(host_and_port, ':', 1) FROM curio.harmony_machines ORDER BY id LIMIT 1")"
  fi
  if [[ -z "$ip" ]]; then
    echo "Unable to resolve Curio machine address" >&2
    return 1
  fi
  echo "${ip}:12300"
}

owned_task_count() {
  local machine="$1"
  ysql "SELECT COUNT(*) FROM curio.harmony_task WHERE owner_id = (SELECT id FROM curio.harmony_machines WHERE host_and_port = '${machine}')"
}

register_wallet_name() {
  local wallet="$1" name="$2"
  ysql "INSERT INTO curio.wallet_names (wallet, name) VALUES ('${wallet}', '${name}') ON CONFLICT (wallet) DO UPDATE SET name = EXCLUDED.name"
}

# True once the steady-state Curio process is up.
# First-boot entrypoint briefly runs a temporary `curio run` (no --name) for
# storage attach / PDP, then kills it and starts `curio run --name devnet`.
# Checking --help or wait-api alone can race that temporary process.
curio_is_steady_state() {
  docker compose exec -T curio sh -c '
    for c in /proc/[0-9]*/cmdline; do
      [ -r "$c" ] || continue
      args=$(tr "\0" " " < "$c")
      case "$args" in
        *"curio run"*"--name devnet"*) exit 0 ;;
      esac
    done
    exit 1
  ' >/dev/null 2>&1
}

curio_container_running() {
  docker compose ps --status running --services 2>/dev/null | grep -qx curio
}

curio_container_started_at() {
  docker inspect -f '{{.State.StartedAt}}' curio 2>/dev/null || true
}

# Wait until Curio has finished first-boot init, the steady-state process is
# running, wait-api + config stay healthy across container restarts, and
# piece-server has written contracts/devnet-info.json (needs provider.ready).
# Env overrides:
#   CURIO_READY_TIMEOUT_S          overall timeout (default 1800)
#   CURIO_READY_STABLE_CHECKS      consecutive successes required (default 4)
#   CURIO_READY_POLL_INTERVAL_S    delay between polls (default 3)
wait_for_curio_ready() {
  local timeout_s="${CURIO_READY_TIMEOUT_S:-1800}"
  local stable_needed="${CURIO_READY_STABLE_CHECKS:-4}"
  local interval_s="${CURIO_READY_POLL_INTERVAL_S:-3}"
  local deadline=$((SECONDS + timeout_s))
  local marker="${CURIO_DOCKER_DIR}/data/curio/.init.curio"
  local provider_ready="${CURIO_DOCKER_DIR}/data/curio/provider.ready"
  local devnet_info="${CURIO_DOCKER_DIR}/data/contracts/devnet-info.json"
  local stable=0
  local last_started=""
  local started machine reason

  echo "Waiting for Curio steady-state API + devnet-info.json (timeout ${timeout_s}s, ${stable_needed} consecutive checks)..."

  while (( SECONDS < deadline )); do
    reason=""
    if [[ ! -f "$marker" ]]; then
      reason="waiting for first-boot marker $(basename "$marker")"
    elif ! curio_container_running; then
      reason="curio container not running (may be restarting)"
    elif ! curio_is_steady_state; then
      reason="waiting for steady-state process (curio run --name devnet)"
    elif [[ ! -f "$provider_ready" ]]; then
      reason="waiting for $(basename "$provider_ready") (Curio PDP provider bootstrap)"
    elif [[ ! -f "$devnet_info" ]]; then
      reason="waiting for contracts/$(basename "$devnet_info") (piece-server client bootstrap)"
    else
      started="$(curio_container_started_at)"
      if [[ -z "$started" ]]; then
        reason="unable to read curio StartedAt"
      elif [[ -n "$last_started" && "$started" != "$last_started" ]]; then
        reason="curio container restarted; resetting readiness"
        stable=0
        last_started="$started"
      else
        last_started="$started"
        machine="$(curio_machine 2>/dev/null || true)"
        if [[ -z "$machine" ]]; then
          reason="waiting for curio machine address"
        elif ! docker compose exec -T curio curio cli --machine "$machine" wait-api --timeout 5s >/dev/null 2>&1; then
          reason="waiting for curio API on ${machine}"
        elif ! docker compose exec -T curio curio config get base >/dev/null 2>&1; then
          reason="waiting for curio config store"
        else
          stable=$((stable + 1))
          echo "  ready check ${stable}/${stable_needed} (api ${machine}, devnet-info present)"
          if (( stable >= stable_needed )); then
            echo "Curio is ready (${devnet_info} present)."
            return 0
          fi
          sleep "$interval_s"
          continue
        fi
      fi
    fi

    stable=0
    echo "  ${reason}..."
    sleep "$interval_s"
  done

  echo "error: timed out waiting for Curio after ${timeout_s}s" >&2
  echo "  marker=${marker} present=$([[ -f $marker ]] && echo yes || echo no)" >&2
  echo "  provider.ready present=$([[ -f $provider_ready ]] && echo yes || echo no)" >&2
  echo "  devnet-info present=$([[ -f $devnet_info ]] && echo yes || echo no)" >&2
  return 1
}

restart_curio_node() {
  local machine
  machine="$(curio_machine)"

  echo "Cordoning Curio node ${machine}..."
  docker compose exec -T curio curio cli --machine "$machine" cordon

  echo "Waiting for Curio to quiesce (no owned running tasks)..."
  while true; do
    local count
    count="$(owned_task_count "$machine")"
    if [[ "${count:-}" == "0" ]]; then
      break
    fi
    echo "  ${count} task(s) still running..."
    sleep 2
  done

  echo "Restarting Curio container (recreate to pick up compose env)..."
  docker compose up -d --force-recreate curio

  wait_for_curio_ready

  echo "Uncordoning Curio node..."
  machine="$(curio_machine)"
  docker compose exec -T curio curio cli --machine "$machine" uncordon
  echo "Curio cluster node restarted."
}

cd "$CURIO_DOCKER_DIR"
wait_for_curio_ready

echo "Automating Curio Loopback IP allowance..."
# Export current layer, update the flag, and re-import it
docker compose exec -T curio curio config get base > /tmp/base.toml
set_toml_value /tmp/base.toml Ingest DisableSSRFProtection true
cat /tmp/base.toml | docker compose exec -T curio curio config set --title base

docker compose exec -T curio curio config get market > /tmp/market.toml
set_toml_value /tmp/market.toml Ingest DisableSSRFProtection true
# Keep DomainName as a DNS label (not an IP). Host-reachable IPNI ads come from
# DEV_CURIO_EXTERNAL_URL=http://host.docker.internal:12310 in docker-compose.yaml.
set_toml_value /tmp/market.toml Market.StorageMarketConfig.IPNI DirectAnnounceURLs '["http://indexer:3001"]'
set_toml_value /tmp/market.toml Market.StorageMarketConfig.IPNI ServiceURL '["http://indexer:3000"]'
cat /tmp/market.toml | docker compose exec -T curio curio config set --title market
echo "Curio successfully updated. Loopback IPs are now allowed."
echo "IPNI announce URL override: DEV_CURIO_EXTERNAL_URL (host.docker.internal:12310)."

echo "Recreating indexer so it can resolve host.docker.internal for ad sync..."
docker compose up -d --force-recreate indexer

echo "Disable curio Winning Post..."

docker compose exec -T curio curio config get post > /tmp/post.toml
set_toml_value /tmp/post.toml Subsystems EnableWinningPost false
cat /tmp/post.toml | docker compose exec -T curio curio config set --title post
echo "Curio successfully updated. CurioWinningPost is now disabled."

restart_curio_node
sleep 5

echo "Registering default wallet in Curio wallet management..."
DEFAULT_WALLET="$(docker exec lotus lotus wallet default | tr -d '\r\n')"
register_wallet_name "$DEFAULT_WALLET" "default"
echo "Registered ${DEFAULT_WALLET} as \"default\"."

# WindowPoSt (and other default control uses) pick on-chain ControlAddresses first.
# An ETH/delegated org wallet there makes SendMessage try to sign Filecoin miner
# methods as an eth tx and fail. Point post control at the secp/BLS worker key
# Curio/lotus can actually sign with (owner/worker path used at miner create).
echo "Pointing miner post control at worker/owner wallet ${DEFAULT_WALLET}..."
CURIO_MINER="$(docker exec lotus lotus state list-miners | tr -d '\r' | grep -v '^t01000$' | head -n1)"
if [[ -z "${CURIO_MINER}" ]]; then
  echo "Unable to resolve Curio miner actor (expected non-t01000 miner)" >&2
  exit 1
fi
echo "Curio miner is ${CURIO_MINER}"

CONTROL_OUT="$(docker compose exec -T curio sptool --actor "${CURIO_MINER}" actor control set --really-do-it "${DEFAULT_WALLET}")"
echo "${CONTROL_OUT}"
CONTROL_MSG="$(printf '%s\n' "${CONTROL_OUT}" | awk '/Message CID:/{print $NF; exit}' | tr -d '\r\n')"
if [[ -z "${CONTROL_MSG}" ]]; then
  echo "Failed to submit actor control set message" >&2
  exit 1
fi
echo "Waiting for control-set message ${CONTROL_MSG}..."
docker exec lotus lotus state wait-msg "${CONTROL_MSG}" >/dev/null
echo "Miner control addresses after update:"
docker compose exec -T curio sptool --actor "${CURIO_MINER}" actor control list --verbose || true

echo "Fund escrow wallets..."
# Provider = Curio miner. Also fund common client ID when present (mk12 client).
for role in "${CURIO_MINER}" t01004
do
  docker exec lotus lotus send --from "${DEFAULT_WALLET}" \
    --method 2 --params-json "\"${role}\"" t05 100

  sleep 5
  docker exec lotus lotus state market balance "$role"
done
# Runtime diagnostics under .runtime/. Sourced after common.sh.
# Compatible with macOS /bin/bash 3.2.

: "${RUNTIME_ROOT:=${REPO_ROOT}/.runtime}"
: "${RUNTIME_FAILURES:=${RUNTIME_ROOT}/failures}"
: "${RUNTIME_TOOLING:=${RUNTIME_ROOT}/tooling}"
: "${RUNTIME_TOOLING_LOGS:=${RUNTIME_TOOLING}/logs}"

runtime_ensure_dirs() {
  mkdir -p "$RUNTIME_FAILURES" "$RUNTIME_TOOLING_LOGS"
}

# Point tooling CLI file logs under .runtime/tooling/logs (porep_tooling_cli.py).
runtime_export_tooling_logs() {
  runtime_ensure_dirs
  export _LOG_FILE="${RUNTIME_TOOLING_LOGS}/logs.log"
  export _ERROR_LOG_FILE="${RUNTIME_TOOLING_LOGS}/error.logs"
}

# Create .runtime/failures/<UTC>-<label>/ and print its path.
runtime_failure_dir() {
  local label="${1:-fail}"
  local ts safe dir
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  safe="$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-64)"
  runtime_ensure_dirs
  dir="${RUNTIME_FAILURES}/${ts}-${safe}"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# Dump compose/RPC/deploy pointers into a failure dir. Args: label [extra notes…]
runtime_dump_stack() {
  local label="${1:-stack}"
  shift || true
  local dir
  dir="$(runtime_failure_dir "$label")"
  {
    printf 'label=%s\n' "$label"
    printf 'time=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'rpc_url=%s\n' "${RPC_URL:-}"
    printf 'repo=%s\n' "$REPO_ROOT"
    for note in "$@"; do
      printf 'note=%s\n' "$note"
    done
  } >"${dir}/meta.txt"

  if [[ -d "${CURIO_DOCKER_DIR:-}" ]]; then
    (
      cd "$CURIO_DOCKER_DIR"
      docker compose ps >"${dir}/curio-compose-ps.txt" 2>&1 || true
      docker compose logs --tail=200 lotus >"${dir}/lotus.log" 2>&1 || true
      docker compose logs --tail=200 curio >"${dir}/curio.log" 2>&1 || true
      docker compose logs --tail=100 indexer >"${dir}/indexer.log" 2>&1 || true
    ) || true
  fi

  if [[ -n "${RPC_URL:-}" ]]; then
    curl -sS -m 5 -X POST "$RPC_URL" \
      -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","method":"Filecoin.ChainHead","params":[],"id":1}' \
      >"${dir}/chain-head.json" 2>"${dir}/chain-head.err" || true
  fi

  if [[ -f "${POREP_MARKET_DIR}/deployments/devnet/ACTIVE" ]]; then
    cp "${POREP_MARKET_DIR}/deployments/devnet/ACTIVE" "${dir}/ACTIVE" 2>/dev/null || true
  fi
  if [[ -f "${POREP_MARKET_DIR}/deployments/devnet/latest.json" ]]; then
    cp "${POREP_MARKET_DIR}/deployments/devnet/latest.json" "${dir}/latest.json" 2>/dev/null || true
  fi

  log "runtime dump written to ${dir#"$REPO_ROOT"/}" >&2
  printf '%s\n' "$dir"
}

# Prune old failure dirs; keep the newest N (default 10).
runtime_prune_failures() {
  local keep="${1:-10}"
  local i=0 d
  runtime_ensure_dirs
  # Newest first by name (UTC timestamps sort lexicographically).
  # Avoid empty "${array[@]}" under bash 3.2 + set -u.
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    i=$((i + 1))
    if [[ "$i" -gt "$keep" ]]; then
      rm -rf "$d"
    fi
  done < <(ls -1d "${RUNTIME_FAILURES}"/*/ 2>/dev/null | sort -r || true)
}

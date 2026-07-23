# Lotus docker helpers. Requires common.sh (log, die, LOTUS_CONTAINER).
# Compatible with macOS /bin/bash 3.2.

lotus() {
  docker exec "$LOTUS_CONTAINER" lotus "$@"
}

# Wait for a message to land. Retries transient Lotus tipset/fork errors.
# Returns 0 on success, 1 on timeout (does not exit on timeout).
wait_msg() {
  local cid="$1"
  local attempts="${2:-40}"
  local i out rc
  [[ -n "$cid" ]] || die "empty message cid"
  log "waiting for message ${cid}"
  for i in $(seq 1 "$attempts"); do
    set +e
    out="$(lotus state wait-msg "$cid" 2>&1)"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      return 0
    fi
    if printf '%s\n' "$out" | grep -qiE 'state fork|refusing explicit call'; then
      log "transient lotus tipset/fork error (${i}/${attempts}); retrying"
      sleep 3
      continue
    fi
    die "waiting for message ${cid} failed: ${out}"
  done
  log "timed out waiting for message ${cid} after ${attempts} attempts"
  return 1
}

wait_msg_required() {
  wait_msg "$@" || die "required message did not land: $1"
}

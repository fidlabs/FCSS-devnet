# Deployment record helpers. Sourced after common.sh.
# Compatible with macOS /bin/bash 3.2.

: "${DEPLOYMENTS_DEVNET_DIR:=${POREP_MARKET_DIR}/deployments/devnet}"
: "${DEPLOYMENT_RECORDS_DIR:=${DEPLOYMENTS_DEVNET_DIR}/records}"
: "${DEPLOYMENT_ACTIVE_FILE:=${DEPLOYMENTS_DEVNET_DIR}/ACTIVE}"
: "${DEPLOYMENT_LATEST_JSON:=${DEPLOYMENTS_DEVNET_DIR}/latest.json}"

# Resolve the active deployment manifest path (ACTIVE record → latest.json).
active_latest_json() {
  local name record
  if [[ -f "$DEPLOYMENT_ACTIVE_FILE" ]]; then
    name="$(tr -d '[:space:]' <"$DEPLOYMENT_ACTIVE_FILE")"
    if [[ -n "$name" ]]; then
      record="${DEPLOYMENT_RECORDS_DIR}/${name}/latest.json"
      if [[ -f "$record" ]]; then
        printf '%s\n' "$record"
        return 0
      fi
    fi
  fi
  if [[ -f "$DEPLOYMENT_LATEST_JSON" ]]; then
    printf '%s\n' "$DEPLOYMENT_LATEST_JSON"
    return 0
  fi
  return 1
}

# Copy finalized latest.json into an immutable record and point ACTIVE at it.
# Also rewrites deployments/devnet/latest.json as a mirror of the record.
# Usage: publish_deployment_record <path-to-finalized-latest.json>
publish_deployment_record() {
  local src="$1"
  local ts short name dest
  require_file "$src"
  require_cmd jq
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  short="$(git -C "$POREP_MARKET_DIR" rev-parse --short HEAD 2>/dev/null || printf 'nogit')"
  name="deployment-${ts}-${short}"
  dest="${DEPLOYMENT_RECORDS_DIR}/${name}"
  mkdir -p "$dest"
  cp "$src" "${dest}/latest.json"
  # Mirror for backward compatibility.
  mkdir -p "$DEPLOYMENTS_DEVNET_DIR"
  cp "${dest}/latest.json" "$DEPLOYMENT_LATEST_JSON"
  printf '%s\n' "$name" >"$DEPLOYMENT_ACTIVE_FILE"
  log "deployment record ${name} (ACTIVE + latest.json mirror)"
  printf '%s\n' "$name"
}

# Point ACTIVE at an existing record and refresh latest.json mirror.
# Usage: use_deployment_record <record-dir-name>
use_deployment_record() {
  local name="$1"
  local record="${DEPLOYMENT_RECORDS_DIR}/${name}/latest.json"
  [[ -n "$name" ]] || die "use_deployment_record: empty name"
  require_file "$record"
  printf '%s\n' "$name" >"$DEPLOYMENT_ACTIVE_FILE"
  cp "$record" "$DEPLOYMENT_LATEST_JSON"
  log "ACTIVE → ${name}; mirrored ${DEPLOYMENT_LATEST_JSON#"$REPO_ROOT"/}"
}

#!/usr/bin/env bash
# Forward curio CLI invocations into the Curio docker compose service.
# Use with: CURIO_PATH=/path/to/scripts/curio-docker.sh
#
# Defaults match curio/docker (project curio-devnet, service curio).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CURIO_DIR="${CURIO_DIR:-${REPO_ROOT}/extern/curio}"
CURIO_COMPOSE_DIR="${CURIO_COMPOSE_DIR:-${CURIO_DIR}/docker}"
CURIO_COMPOSE_PROJECT="${CURIO_COMPOSE_PROJECT:-curio-devnet}"
CURIO_COMPOSE_SERVICE="${CURIO_COMPOSE_SERVICE:-curio}"

compose() {
  docker compose -p "$CURIO_COMPOSE_PROJECT" "$@"
}

if [[ ! -f "${CURIO_COMPOSE_DIR}/docker-compose.yaml" && ! -f "${CURIO_COMPOSE_DIR}/docker-compose.yml" ]]; then
  printf 'error: compose file not found under %s (set CURIO_DIR or CURIO_COMPOSE_DIR)\n' "$CURIO_COMPOSE_DIR" >&2
  exit 127
fi

cd "$CURIO_COMPOSE_DIR"

if ! compose ps --status running --services 2>/dev/null | grep -qx "$CURIO_COMPOSE_SERVICE"; then
  printf 'error: compose service "%s" is not running in project %s (%s)\n' \
    "$CURIO_COMPOSE_SERVICE" "$CURIO_COMPOSE_PROJECT" "$CURIO_COMPOSE_DIR" >&2
  printf 'start it with: (cd %s && docker compose -p %s up -d %s)\n' \
    "$CURIO_COMPOSE_DIR" "$CURIO_COMPOSE_PROJECT" "$CURIO_COMPOSE_SERVICE" >&2
  exit 127
fi

exec docker compose -p "$CURIO_COMPOSE_PROJECT" exec -T "$CURIO_COMPOSE_SERVICE" curio "$@"

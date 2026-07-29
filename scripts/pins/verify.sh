#!/usr/bin/env bash
# Verify versions.lock.yaml against submodule HEADs, parent gitlinks, and local patches.
#
# Usage:
#   ./scripts/pins/verify.sh
#   just pin-verify
#
# Exit 0 on success; non-zero with a clear bump/refresh message on failure.
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/pins.sh
source "${SCRIPT_DIR}/../lib/pins.sh"

require_cmd git
require_cmd python3

fail=0
note() { printf 'pin-verify: %s\n' "$*"; }
err() { printf 'pin-verify: ERROR: %s\n' "$*" >&2; fail=1; }

parent_gitlink() {
  local relpath="$1"
  git -C "$REPO_ROOT" ls-tree HEAD -- "$relpath" | awk '{print $3}'
}

verify_submodule() {
  local key="$1"
  local path commit gitlink head wt
  path="$(pin_lock_field "$key" path)"
  commit="$(pin_lock_field "$key" commit)"

  [[ -d "${REPO_ROOT}/${path}/.git" || -f "${REPO_ROOT}/${path}/.git" ]] \
    || { err "${key}: missing checkout at ${path} (run: git submodule update --init --recursive)"; return 0; }

  head="$(git -C "${REPO_ROOT}/${path}" rev-parse HEAD)"
  if [[ "$head" != "$commit" ]]; then
    err "${key}: HEAD ${head} != lock ${commit} (checkout lock commit or bump versions.lock.yaml)"
  else
    note "${key}: HEAD matches lock (${commit:0:12})"
  fi

  gitlink="$(parent_gitlink "$path")"
  if [[ -z "$gitlink" ]]; then
    err "${key}: no gitlink in parent HEAD for ${path}"
  elif [[ "$gitlink" != "$commit" ]]; then
    err "${key}: parent gitlink ${gitlink} != lock ${commit} (commit the submodule tip or bump lock)"
  else
    note "${key}: parent gitlink matches lock"
  fi
}

# Map lock key → patches/<dir> (empty = no patches).
patch_dir_for_key() {
  case "$1" in
    curio) echo curio ;;
    filecoin-porep-market-tooling) echo tooling ;;
    filecoin-oracle-service) echo oracle ;;
    *) echo "" ;;
  esac
}

verify_patches() {
  local key="$1"
  local patch_dir path commit wt patches p
  patch_dir="$(patch_dir_for_key "$key")"
  [[ -n "$patch_dir" ]] || return 0
  path="$(pin_lock_field "$key" path)"
  commit="$(pin_lock_field "$key" commit)"

  patches=()
  # shellcheck disable=SC2012
  while IFS= read -r p; do
    [[ -n "$p" ]] && patches+=("$p")
  done < <(ls "${REPO_ROOT}/patches/${patch_dir}"/*.patch 2>/dev/null | sort || true)

  if [[ ${#patches[@]} -eq 0 ]]; then
    note "${key}: no patches under patches/${patch_dir}"
    return 0
  fi

  wt="$(mktemp -d "${TMPDIR:-/tmp}/fcss-pin-XXXXXX")"
  if ! git -C "${REPO_ROOT}/${path}" worktree add --detach "$wt" "$commit" >/dev/null 2>&1; then
    err "${key}: could not create worktree at ${commit} for patch --check"
    rm -rf "$wt"
    return 0
  fi

  for p in "${patches[@]}"; do
    if git -C "$wt" apply --check "$p" >/dev/null 2>&1; then
      if ! git -C "$wt" apply "$p" >/dev/null 2>&1; then
        err "${key}: patch applies with --check but failed to apply: ${p#"$REPO_ROOT"/}"
        break
      fi
      note "${key}: ok ${p#"$REPO_ROOT"/}"
    else
      err "${key}: patch does not apply on ${commit:0:12}: ${p#"$REPO_ROOT"/}"
      err "  bump lock or refresh patches/${patch_dir}/"
      break
    fi
  done

  git -C "${REPO_ROOT}/${path}" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
}

note "lockfile ${VERSIONS_LOCK#"$REPO_ROOT"/}"

while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  verify_submodule "$key"
  verify_patches "$key"
done < <(pin_lock_keys)

if [[ "$fail" -ne 0 ]]; then
  err "pin-verify failed — update submodule gitlinks and/or refresh patches, then rewrite versions.lock.yaml"
  exit 1
fi

note "all pins and patches OK"
exit 0

# filecoin-porep-market-tooling submodule tasks
set working-directory := ".."

[private]
default:
    @just --list tooling

# Reset tooling submodule and apply patches/tooling/*.patch
patch:
    ./scripts/tooling/patch.sh

# Apply patches, then ensure Python venv
init:
    ./scripts/tooling/init.sh

make-deal *args:
    #!/usr/bin/env bash
    set -euo pipefail
    venv="extern/filecoin-porep-market-tooling/.venv"
    [[ -f "${venv}/bin/activate" ]] || {
      echo "error: missing ${venv} — run just init (or just tooling init)" >&2
      exit 1
    }
    # shellcheck disable=SC1091
    source "${venv}/bin/activate"
    ./scripts/tooling/make-deal.sh {{args}}

# 3 clients × (2 private + 1 public), unique piece CIDs (Singularity via Docker)
seed-deals *args:
    #!/usr/bin/env bash
    set -euo pipefail
    venv="extern/filecoin-porep-market-tooling/.venv"
    [[ -f "${venv}/bin/activate" ]] || {
      echo "error: missing ${venv} — run just init (or just tooling init)" >&2
      exit 1
    }
    # shellcheck disable=SC1091
    source "${venv}/bin/activate"
    ./scripts/tooling/seed-deals.sh {{args}}

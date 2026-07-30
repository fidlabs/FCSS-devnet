# Curio PoRep / FCSS-devnet task runner
# Run `just` to see all available commands.
# Submodule tasks: just curio … / porep-market … / tooling … / oracle … / cdp …

mod curio 'just/curio.just'
mod porep-market 'just/porep-market.just'
mod tooling 'just/tooling.just'
mod oracle 'just/oracle.just'
mod cdp 'just/cdp.just'

default:
    @just --list

# Submodules + Curio patches/images + tooling + oracle/cdp patches + pin-verify
init:
    git submodule update --init --recursive
    just curio init
    just tooling init
    just oracle patch
    just cdp patch
    just pin-verify

# Assert versions.lock.yaml matches submodule HEADs/gitlinks and patches apply
pin-verify:
    ./scripts/pins/verify.sh

# Compose up + Curio config + porep deploy + SP wiring + CDP + oracle
up:
    just curio up
    just porep-market deploy
    just porep-market up
    just cdp up
    just oracle up

down:
    just oracle down
    just cdp down
    just curio down

# Probe RPC / Curio / CDP / oracle / ACTIVE / pins (non-fatal pin warn)
status:
    ./scripts/status.sh

# Wipe chain/DB/envs (preserve records/images/patches), then just up
reset:
    ./scripts/reset.sh

# Flags go straight to the script. Example: just make-deal --deal-id 1
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

# 3 clients × private/public, unique piece CIDs (Singularity via Docker)
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

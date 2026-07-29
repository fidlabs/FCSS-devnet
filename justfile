# Curio PoRep / FCSS-devnet task runner
# Run `just` to see all available commands.
# Submodule tasks: just curio … / porep-market … / tooling … / oracle …

mod curio 'just/curio.just'
mod porep-market 'just/porep-market.just'
mod tooling 'just/tooling.just'
mod oracle 'just/oracle.just'

default:
    @just --list

# Submodules + Curio patches/images + tooling patches/venv + oracle patches
init:
    git submodule update --init --recursive
    just curio init
    just tooling init
    just oracle patch

# Compose up + Curio config + porep deploy + SP wiring + oracle (init/DB/start)
up:
    just curio up
    just porep-market deploy
    just porep-market up
    just oracle up

down:
    just oracle down
    just curio down

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

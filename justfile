# Curio PoRep devnet task runner
# Run `just` to see all available commands.
# Submodule tasks: just curio … / porep-market … / tooling …

mod curio 'just/curio.just'
mod porep-market 'just/porep-market.just'
mod tooling 'just/tooling.just'

default:
    @just --list

# Submodules + Curio patches/images + tooling patches/venv
init:
    git submodule update --init --recursive
    just curio init
    just tooling init

# Compose up + Curio config + porep deploy + SP wiring
up:
    just curio up
    just porep-market deploy
    just porep-market up

logs:
    just curio logs

down:
    just curio down

make-deal *args:
    just tooling make-deal {{args}}

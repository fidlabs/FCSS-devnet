# porep-market submodule tasks
set working-directory := ".."

[private]
default:
    @just --list porep-market

gen-env *args:
    ./scripts/porep-market/gen-env.sh {{args}}

deploy *args:
    ./scripts/porep-market/deploy.sh {{args}}

up *args:
    ./scripts/porep-market/up.sh {{args}}

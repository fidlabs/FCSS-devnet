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

# Public shell exports from ACTIVE deployment (no private keys)
tooling-env:
    ./scripts/porep-market/tooling-env.sh

# Point ACTIVE at an existing records/ dir and mirror latest.json
use-deployment name:
    ./scripts/porep-market/use-deployment.sh {{name}}

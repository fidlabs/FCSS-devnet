# porep-market submodule tasks
set working-directory := ".."

gen-env *args:
    ./scripts/porep-market/gen-env.sh {{args}}

deploy:
    ./scripts/porep-market/deploy.sh

up *args:
    ./scripts/porep-market/up.sh {{args}}

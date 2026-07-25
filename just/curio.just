# Curio submodule tasks
# Module recipes run with cwd = just/; keep repo root as working directory.
set working-directory := ".."

[private]
default:
    @just --list curio

init:
    ./scripts/curio/init.sh

up:
    make -C extern/curio devnet/up
    @echo 'Devnet started. Run `just curio logs` to follow container logs.'
    ./scripts/curio/up.sh

logs:
    docker compose -f extern/curio/docker/docker-compose.yaml logs -f

down:
    make -C extern/curio devnet/down

cli *args:
    ./scripts/curio/cli.sh {{args}}

# Curio PoRep devnet task runner
# Run `just` to see all available commands

default:
    @just --list

init:
    @./scripts/setup-submodules.sh

[private]
_curio-up:
    make -C extern/curio devnet/up
    @echo 'Devnet started. Run `just logs` to follow container logs.'
    @./scripts/init-curio.sh

[private]
_porep-deploy:
    @./scripts/setup-curio-devnet.sh --deploy

up: _curio-up _porep-deploy

logs:
    docker compose -f extern/curio/docker/docker-compose.yaml logs -f

down:
    make -C extern/curio devnet/down

make-deal:
    @./scripts/make-deal.sh

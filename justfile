# Curio PoRep devnet task runner
# Run `just` to see all available commands

default:
    @just --list

init:
    @./scripts/init.sh
    @just _tooling-venv

[private]
_tooling-venv:
    #!/usr/bin/env bash
    set -euo pipefail
    dir="extern/filecoin-porep-market-tooling"
    [[ -d "$dir" ]] || { echo "error: missing ${dir} (run submodule init first)" >&2; exit 1; }
    if [[ ! -x "${dir}/.venv/bin/python" ]]; then
      echo "==> creating ${dir}/.venv"
      python3 -m venv "${dir}/.venv"
    fi
    echo "==> pip install -r ${dir}/requirements.txt"
    "${dir}/.venv/bin/pip" install -r "${dir}/requirements.txt"

[private]
_curio-up:
    make -C extern/curio devnet/up
    @echo 'Devnet started. Run `just logs` to follow container logs.'
    @./scripts/up-curio.sh

[private]
_porep-deploy:
    @./scripts/up-porep.sh --deploy

up: _curio-up _porep-deploy

logs:
    docker compose -f extern/curio/docker/docker-compose.yaml logs -f

down:
    make -C extern/curio devnet/down

make-deal:
    #!/usr/bin/env bash
    set -euo pipefail
    venv="extern/filecoin-porep-market-tooling/.venv"
    [[ -f "${venv}/bin/activate" ]] || {
      echo "error: missing ${venv} — run just init (or just _tooling-venv)" >&2
      exit 1
    }
    # shellcheck disable=SC1091
    source "${venv}/bin/activate"
    ./scripts/make-deal.sh

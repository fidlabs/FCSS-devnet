# filecoin-porep-market-tooling submodule tasks
set working-directory := ".."

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

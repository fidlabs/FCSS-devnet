# Hyperion (PoRep indexer + REST API) submodule tasks
set working-directory := ".."

[private]
default:
    @just --list hyperion

# Reset Hyperion submodule and apply patches/hyperion/*.patch
patch:
    ./scripts/hyperion/patch.sh

# Patches + .env + Postgres + prisma + Nest (background by default).
# Pass flags through (e.g. just hyperion up --force --foreground).
up *args:
    ./scripts/hyperion/up.sh --force {{args}}

logs:
    #!/usr/bin/env bash
    set -euo pipefail
    f=".runtime/hyperion.log"
    [[ -f "$f" ]] || { echo "no ${f} yet — start with just hyperion up" >&2; exit 1; }
    tail -f "$f"

down:
    ./scripts/hyperion/down.sh

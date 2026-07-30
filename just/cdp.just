# compliance-data-platform (CDP) submodule tasks
set working-directory := ".."

[private]
default:
    @just --list cdp

# Reset CDP submodule and apply patches/cdp/*.patch
patch:
    ./scripts/cdp/patch.sh

# Patches + .env + Postgres/DMOB + prisma + Nest (background by default).
# Pass flags through (e.g. just cdp up --force --foreground).
up *args:
    ./scripts/cdp/up.sh --force {{args}}

logs:
    #!/usr/bin/env bash
    set -euo pipefail
    f=".runtime/cdp.log"
    [[ -f "$f" ]] || { echo "no ${f} yet — start with just cdp up" >&2; exit 1; }
    tail -f "$f"

down:
    ./scripts/cdp/down.sh

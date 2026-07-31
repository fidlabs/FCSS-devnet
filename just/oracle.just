# filecoin-oracle-service submodule tasks
set working-directory := ".."

[private]
default:
    @just --list oracle

# Reset oracle submodule and apply patches/oracle/*.patch
patch:
    ./scripts/oracle/patch.sh

# Patches + .env/build + Postgres/Prisma + npm run start (foreground).
# Pass flags through (e.g. just oracle up --force).
up *args:
    ./scripts/oracle/up.sh --force {{args}}

# GET /deals from the running oracle API (optional: --state --page --limit).
get-deals *args:
    ./scripts/oracle/get-deals.sh {{args}}

logs:
    docker compose -f extern/filecoin-oracle-service/docker-compose.yml -f docker/oracle-compose.ports.yaml logs -f

down:
    ./scripts/oracle/down.sh

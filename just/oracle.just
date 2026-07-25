# filecoin-oracle-service submodule tasks
set working-directory := ".."

[private]
default:
    @just --list oracle

# Reset oracle submodule and apply patches/oracle/*.patch
patch:
    ./scripts/oracle/patch.sh

# Write .env from Curio + porep-market V2 deployment (requires just porep-market deploy).
init *args:
    ./scripts/oracle/init.sh {{args}}

# docker compose up (Postgres) + prisma schema, then npm run start (foreground).
up:
    ./scripts/oracle/up.sh
    ./scripts/oracle/start.sh

# Build if needed and run `npm run start` (foreground).
start:
    ./scripts/oracle/start.sh

# GET /deals from the running oracle API (optional: --state --page --limit).
get-deals *args:
    ./scripts/oracle/get-deals.sh {{args}}

logs:
    docker compose -f extern/filecoin-oracle-service/docker-compose.yml logs -f

down:
    docker compose -f extern/filecoin-oracle-service/docker-compose.yml down

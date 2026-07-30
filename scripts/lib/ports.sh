# FCSS-devnet host port map (isolated from stock Curio 123x defaults).
# Container-internal ports stay Curio/Lotus defaults; only host publish changes.
# Sourced from common.sh. Compatible with macOS /bin/bash 3.2.

# Lotus / FEVM
: "${FCSS_LOTUS_RPC_HOST_PORT:=2234}"
: "${FCSS_LOTUS_LIBP2P_HOST_PORT:=29090}"
: "${FCSS_LOTUS_MINER_HOST_PORT:=22345}"

# Curio
: "${FCSS_CURIO_API_HOST_PORT:=22300}"
: "${FCSS_CURIO_UI_HOST_PORT:=24701}"
: "${FCSS_CURIO_MARKET_HOST_PORT:=22310}"
: "${FCSS_PIECE_SERVER_HOST_PORT:=22320}"

# Yugabyte (host publish only; in-compose ysql still uses 5433)
: "${FCSS_YUGABYTE_YSQL_HOST_PORT:=25433}"
: "${FCSS_YUGABYTE_YCQL_HOST_PORT:=29042}"
: "${FCSS_YUGABYTE_UI_HOST_PORT:=25432}"

# Indexer
: "${FCSS_INDEXER_HOST_PORT_0:=23000}"
: "${FCSS_INDEXER_HOST_PORT_1:=23001}"
: "${FCSS_INDEXER_HOST_PORT_2:=23002}"
: "${FCSS_INDEXER_HOST_PORT_3:=23003}"

# Oracle
: "${FCSS_ORACLE_PG_HOST_PORT:=28038}"
: "${FCSS_ORACLE_APP_HOST_PORT:=23100}"

# Compliance Data Platform (CDP)
: "${FCSS_CDP_PG_HOST_PORT:=28037}"
: "${FCSS_CDP_DMOB_PG_HOST_PORT:=28039}"
: "${FCSS_CDP_APP_HOST_PORT:=23300}"

# Seed-deals fixture (unique manifests + CARs; avoids colliding with ad-hoc :8080/:7777)
: "${FCSS_SEED_MANIFEST_HOST_PORT:=18080}"
: "${FCSS_SEED_PIECE_HOST_PORT:=17777}"

: "${FCSS_HOST:=127.0.0.1}"

: "${RPC_URL:=http://${FCSS_HOST}:${FCSS_LOTUS_RPC_HOST_PORT}/rpc/v1}"
: "${CURIO_API_URL:=http://${FCSS_HOST}:${FCSS_CURIO_API_HOST_PORT}}"
: "${CURIO_MARKET_URL:=http://${FCSS_HOST}:${FCSS_CURIO_MARKET_HOST_PORT}}"
: "${CURIO_UI_URL:=http://${FCSS_HOST}:${FCSS_CURIO_UI_HOST_PORT}}"
: "${ORACLE_DATABASE_URL:=postgresql://postgres:postgres@${FCSS_HOST}:${FCSS_ORACLE_PG_HOST_PORT}/postgres}"
: "${ORACLE_APP_URL:=http://${FCSS_HOST}:${FCSS_ORACLE_APP_HOST_PORT}}"
: "${CDP_DATABASE_URL:=postgresql://postgres:postgres@${FCSS_HOST}:${FCSS_CDP_PG_HOST_PORT}/postgres?schema=public&connection_limit=50}"
: "${CDP_DMOB_DATABASE_URL:=postgresql://postgres:postgres@${FCSS_HOST}:${FCSS_CDP_DMOB_PG_HOST_PORT}/postgres?schema=public&connection_limit=50}"
: "${CDP_APP_URL:=http://${FCSS_HOST}:${FCSS_CDP_APP_HOST_PORT}}"
: "${CDP_SERVICE_URL:=${CDP_APP_URL}}"
: "${SEED_MANIFEST_BASE_URL:=http://${FCSS_HOST}:${FCSS_SEED_MANIFEST_HOST_PORT}}"
: "${SEED_PIECE_BASE_URL:=http://host.docker.internal:${FCSS_SEED_PIECE_HOST_PORT}/piece}"
: "${DEV_CURIO_EXTERNAL_URL:=http://host.docker.internal:${FCSS_CURIO_MARKET_HOST_PORT}}"
